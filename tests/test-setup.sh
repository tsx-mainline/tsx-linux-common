#!/bin/bash
# Host test for the on-panel setup page (see
# docs/rootfs.md "Setup page"). The test covers these parts:
#  - tsx-kiosk-url (which URL the kiosk loads)
#  - the `validate` and `setup` subcommands of tsx-config
#  - tsx-setup-helper (the one root process that privileged writes go through)
#  - tsx-setupd itself
# All scripts are real. They run as real processes against fixture files and
# fake helper binaries. The test never uses the panel, docker or root.
# tsx-setupd and tsx-setup-helper run as the uid of this test.
# TSX_APPLY_ALLOW_NONROOT replaces the root check that tsx-config apply and
# setup would otherwise require.
#
# The test covers:
#  - the trigger (unconfigured -> setup page)
#  - form validation through the same tsx-config regex table. This includes a
#    shell-metacharacter payload that must round-trip literally and never run.
#  - the LAN pairing code: not needed on localhost, required and rate-limited
#    from a simulated LAN client
#  - tsx-setupd listens on loopback ONLY once configured. It must not just
#    refuse at the HTTP layer: a simulated LAN connection must fail to connect.
#  - tsx-setup-helper rejects anything outside its fixed command set. It never
#    runs the fake tsx-config or chpasswd for a bad line.
#  - the setup-open window is monotonic. A broken or wrong `date` does not
#    affect it, because none of this code calls date.
#  - a save lands in a temp panel.conf
#  - a save writes only the fields that the page sent (the changed ones), and
#    refuses a page with an old revision of panel.conf
#  - the revision stays the same over a restart of tsx-setup-helper, and
#    tsx-setupd reads only the reply with the tag of its own request
#  - the refresh endpoint (/setup/api/status) carries no field value
#  - no secret ever appears in a JSON response or in the log of either daemon
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1   # the test imports tsx-setupd: no .pyc next to it
# The board file (tests/boards/xx60/board.sh) for the scripts that read it.
export TSX_BOARD_CONF=$(cd "$(dirname "$0")/.." && pwd)/tests/boards/xx60/board.sh
export TSX_BOARD_BIN=$(cd "$(dirname "$0")/.." && pwd)/base/usr/local/bin/tsx-board
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/tests/lib/paths.sh"
SETUPD=$(P usr/local/sbin/tsx-setupd)
HELPER=$(P usr/local/sbin/tsx-setup-helper)
TSXCONFIG=$(P usr/local/sbin/tsx-config)
KIOSKURL=$(P usr/local/bin/tsx-kiosk-url)
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED test-setup: no busybox on this host"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIPPED test-setup: no python3 on this host"; exit 0; }

T=$(mktemp -d)
SETUPD_PID= HELPER_PID= HELPER2_PID=
cleanup() {
	[ -n "$SETUPD_PID" ] && kill "$SETUPD_PID" 2>/dev/null
	[ -n "$HELPER_PID" ] && kill "$HELPER_PID" 2>/dev/null
	[ -n "$HELPER2_PID" ] && kill "$HELPER2_PID" 2>/dev/null
	[ -n "${KEEP:-}" ] && echo "kept $T" || rm -rf "$T"
}
trap cleanup EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N + 1)); }
bad() { echo "  FAIL: $*"; F=$((F + 1)); }

# ---- 0. syntax ----------------------------------------------------------
echo "== syntax =="
busybox sh -n "$TSXCONFIG" && ok "busybox sh -n tsx-config" || bad "busybox sh -n tsx-config"
busybox sh -n "$KIOSKURL" && ok "busybox sh -n tsx-kiosk-url" || bad "busybox sh -n tsx-kiosk-url"
busybox sh -n "$HERE/kiosk/usr/local/bin/kiosk-session" && ok "busybox sh -n kiosk-session" || bad "busybox sh -n kiosk-session"
busybox sh -n "$HELPER" && ok "busybox sh -n tsx-setup-helper" || bad "busybox sh -n tsx-setup-helper"
busybox sh -n "$HERE/setup/etc/init.d/tsx-setupd" && ok "busybox sh -n init.d/tsx-setupd" || bad "busybox sh -n init.d/tsx-setupd"
busybox sh -n "$HERE/setup/etc/init.d/tsx-setup-helper" && ok "busybox sh -n init.d/tsx-setup-helper" || bad "busybox sh -n init.d/tsx-setup-helper"
busybox sh -n "$(P usr/local/sbin/tsx-panelctl)" && ok "busybox sh -n tsx-panelctl" || bad "busybox sh -n tsx-panelctl"
# py_compile writes next to the source by default, and another test that
# reads the overlay at the same time sees the stray file. Write to $T.
python3 -c 'import py_compile, sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' "$SETUPD" "$T/setupd.pyc" \
	&& ok "python3 -m py_compile tsx-setupd" || bad "py_compile tsx-setupd"

echo "== tsx-setupd runs as an unprivileged user, not root =="
grep -q '^command_user="tsx-setup:tsx-setup"$' "$HERE/setup/etc/init.d/tsx-setupd" \
	&& ok "init.d/tsx-setupd sets command_user to tsx-setup, not root" \
	|| bad "init.d/tsx-setupd does not run as the unprivileged tsx-setup user"
grep -q 'checkpath -f -o tsx-setup:tsx-setup .*/var/log/tsx-setupd.log' "$HERE/setup/etc/init.d/tsx-setupd" \
	&& ok "init.d/tsx-setupd gives tsx-setup its own log file (supervise-daemon opens it as that user)" \
	|| bad "init.d/tsx-setupd: no tsx-setup-owned /var/log/tsx-setupd.log (the daemon exits 1 on the panel)"
for k in $(sed -n 's/^\([A-Z_]*\)=.*/\1/p' "$HERE/setup/etc/tsx/setup.conf"); do
	grep -q "\"$k\"" "$SETUPD" \
		&& ok "setup.conf key $k is read by tsx-setupd" \
		|| bad "setup.conf key $k is not read by tsx-setupd (a dead knob)"
done

# ---- fixtures -------------------------------------------------------------
mkdir -p "$T/run" "$T/bin" "$T/zoneinfo/America"
CONF="$T/panel.conf"
cat > "$T/bin/tsx-config" <<EOF
#!/bin/sh
exec busybox sh "$TSXCONFIG" "\$@"
EOF
chmod +x "$T/bin/tsx-config"
cat > "$T/bin/chpasswd" <<'EOF'
#!/bin/sh
# stands in for the real chpasswd. It logs what it gets on stdin, so the
# test can check that the password arrives there and never as a shell
# argument. Then it rewrites the fixture shadow file as the real tool does,
# so the follow-up read of tsx-setup-helper is realistic.
echo "chpasswd $*" >> "$FAKE_CMD_LOG"
cat > "$FAKE_CHPASSWD_LOG"
printf 'root:$6$faketestfixturesalt$abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN.:19000:0:99999:7:::\n' > "$TSX_SHADOW_FILE"
exit 0
EOF
chmod +x "$T/bin/chpasswd"
cat > "$T/bin/rc-service" <<EOF
#!/bin/sh
echo "rc-service \$*" >> "$T/rc-service.log"
case "\$2" in status) exit 1;; *) exit 0;; esac
EOF
chmod +x "$T/bin/rc-service"
cat > "$T/bin/tsx-panelctl" <<EOF
#!/bin/sh
echo "tsx-panelctl \$*" >> "$T/panelctl-cmds.log"
EOF
chmod +x "$T/bin/tsx-panelctl"
# A deliberately broken `date`, early on PATH. tsx-config setup and
# tsx-kiosk-url must not be affected AT ALL. They read /proc/uptime and never
# call date +%s (docs/rootfs.md "Setup page"). This proves that the setup
# window is monotonic and not wall-clock. The test does not need to step the
# system clock, which a host test cannot do safely. The log() of
# tsx-setup-helper DOES call date, for cosmetic timestamps only. It must keep
# working and must not crash. It only writes a silly-looking log line.
cat > "$T/bin/date" <<'EOF'
#!/bin/sh
echo "2099-01-01 00:00:00 (FAKE_BROKEN_DATE: not real wall-clock time)"
EOF
chmod +x "$T/bin/date"
touch "$T/zoneinfo/UTC" "$T/zoneinfo/America/New_York" "$T/zoneinfo/America/Denver"
cat > "$T/shadow" <<'EOF'
root:$oldhash$oldoldoldoldoldoldoldoldoldoldold:19000:0:99999:7:::
EOF
cat > "$T/setup.conf" <<EOF
TSX_SETUP_PORT=0
TSX_SETUP_LAN=on
TSX_SETUP_WINDOW=6
EOF

get_free_port() { python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(('0.0.0.0', 0))
print(s.getsockname()[1])
s.close()
"; }
PORT=$(get_free_port)
sed -i "s/TSX_SETUP_PORT=0/TSX_SETUP_PORT=$PORT/" "$T/setup.conf"

# --source connects FROM that local address and not from the address the OS
# would pick. The server then sees a non-loopback peer, although both ends
# are this test host. CI has no real second LAN host. The connect timeout is
# short: after tsx-setupd binds to loopback only, a LAN attempt must fail
# fast (connection refused) and must not hang. The wait for the answer is
# long: a request goes through tsx-setup-helper and tsx-config, which take
# seconds on a busy host. A client error prints status 0. The body says
# "retry": true only when the server did not get the request (refused, or a
# reset before an answer: a connection in the backlog of a closed socket).
cat > "$T/client.py" <<'PYEOF'
import argparse, http.client, json, sys
p = argparse.ArgumentParser()
p.add_argument("method"); p.add_argument("path")
p.add_argument("--port", type=int, required=True)
p.add_argument("--source", default=None)
p.add_argument("--cookie", default=None)
p.add_argument("--data", default=None)
a = p.parse_args()
kwargs = {"timeout": 3}
if a.source:
	kwargs["source_address"] = (a.source, 0)
conn = http.client.HTTPConnection(a.source or "127.0.0.1", a.port, **kwargs)
headers = {}
body = None
if a.data is not None:
	body = a.data.encode()
	headers["Content-Type"] = "application/json"
if a.cookie:
	headers["Cookie"] = "tsxsetup=" + a.cookie
def fail(e, retry):
	print(0); print("")
	print(json.dumps({"_client_error": str(e), "retry": retry}))
	sys.exit(0)
try:
	conn.connect()
except Exception as e:
	fail(e, isinstance(e, (ConnectionRefusedError, ConnectionResetError)))
conn.sock.settimeout(120)
try:
	conn.request(a.method, a.path, body=body, headers=headers)
	resp = conn.getresponse()
	raw = resp.read()
	status = resp.status
	setcookie = resp.getheader("Set-Cookie") or ""
except (ConnectionResetError, BrokenPipeError) as e:
	fail(e, True)
except Exception as e:
	fail(e, False)
token = ""
if setcookie.startswith("tsxsetup="):
	token = setcookie.split(";")[0][len("tsxsetup="):]
print(status)
print(token)
sys.stdout.write(raw.decode(errors="replace"))
PYEOF

call() {
	# ServerManager (tsx-setupd) can be in the middle of a rebind for a few
	# milliseconds. It closes one listening socket and opens another, for
	# example right after a save flips lan_allowed(). A request that arrives
	# in that window gets a connection reset or refused, not a real answer.
	# Retry a few times before the test counts this as a failure. A real
	# client (the kiosk, a browser tab) also retries after the first reset.
	# Retry only a request that the server did not get. A second copy of a
	# save that the server did get is refused as stale (409).
	local out status tries=0
	while :; do
		out=$(python3 "$T/client.py" "$@" --port "$PORT")
		status=$(printf '%s\n' "$out" | sed -n '1p')
		[ "$status" != 0 ] && break
		printf '%s\n' "$out" | sed -n '3p' | grep -q '"retry": true' || break
		tries=$((tries + 1))
		[ "$tries" -ge 3 ] && break
		sleep 0.2
	done
	printf '%s\n' "$out"
}
status_of() { printf '%s\n' "$1" | sed -n '1p'; }
cookie_of() { printf '%s\n' "$1" | sed -n '2p'; }
body_of() { printf '%s\n' "$1" | sed -n '3,$p'; }
jget() {  # jget PATH <<< "$body"   PATH is a dotted path into the JSON object.
	# A numeric segment indexes a list, e.g. tz_list.0
	python3 -c "
import json, sys
d = json.load(sys.stdin)
v = d
for k in '$1'.split('.'):
	if isinstance(v, dict):
		v = v.get(k)
	elif isinstance(v, list) and k.lstrip('-').isdigit() and -len(v) <= int(k) < len(v):
		v = v[int(k)]
	else:
		v = None
print('' if v is None else v)
"
}

jkeys() { python3 -c 'import json, sys; print(" ".join(sorted(json.load(sys.stdin))))'; }
# rev_now: the revision of panel.conf, as the page gets it at load time
rev_now() { body_of "$(call GET /setup/api/state)" | jget revision; }
# submit FIELDS_JSON [REVISION]: a save as the page sends it, the changed
# fields and the revision of the page. Without REVISION: the current one.
# An empty REVISION sends none.
submit() {
	local rev
	if [ $# -ge 2 ]; then rev=$2; else rev=$(rev_now); fi
	call POST /setup/api/submit --data "$(python3 -c 'import json, sys
print(json.dumps({"revision": sys.argv[2] or None, "fields": json.loads(sys.argv[1])}))' "$1" "$rev")"
}
# the requests that tsx-setup-helper logged after line MARK of its log
hlog_mark() { wc -l < "$T/helper.log"; }
hlog_since() { tail -n +"$(($1 + 1))" "$T/helper.log" | sed -n 's/^.* tsx-setup-helper: //p'; }
hlog_writes() { hlog_since "$1" | grep -E '^(set|unset|rootpw|apply)( |$)' | tr '\n' ' ' | sed 's/ $//'; }
# conf_except KEY...: panel.conf without the lines of these keys
conf_except() { local re; re=$(printf '%s|' "$@"); grep -Ev "^(${re%|})=" "$CONF"; }

# find a local, non-loopback source address to stand in for a LAN client
# (there is no real second host in CI): connecting a UDP socket never sends
# a packet, it only asks the kernel to pick the route/source address.
LANIP=$(python3 -c "
import socket
try:
	s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
	s.connect(('192.0.2.1', 80))
	print(s.getsockname()[0])
except Exception:
	print('')
" 2>/dev/null)
[ -n "$LANIP" ] && [ "$LANIP" != 127.0.0.1 ] || LANIP=

# ---- start tsx-setup-helper (the root side) + tsx-setupd (unprivileged) --
# tsx-config itself reads TSX_RUN, a base dir. It appends /tsx internally.
# tsx-setup-helper/tsx-setupd/tsx-kiosk-url read TSX_RUN_DIR (the tsx dir
# itself, like tsx-panelctl's TSX_RUN_DIR) -- both must resolve to the same
# physical directory.
RUNBASE="$T/run"; RUNDIR="$T/run/tsx"
FAKE_CHPASSWD_LOG="$T/chpasswd-stdin.log"
FAKE_CMD_LOG="$T/fake-cmd.log"
export FAKE_CHPASSWD_LOG FAKE_CMD_LOG

# start_helper LOG [REQ RESP]: start a tsx-setup-helper on the run directory
# of this test, with its output appended to LOG, and wait until it listens.
# Without REQ and RESP it uses the FIFOs of the run directory, the ones that
# tsx-setupd uses. HPID is the process.
start_helper() {
	local log=$1 n
	n=$(grep -c "listening on" "$log" 2>/dev/null); n=${n:-0}
	PATH="$T/bin:$PATH" TSX_CONFIG_BIN="$T/bin/tsx-config" TSX_CONF="$CONF" \
	TSX_RUN="$RUNBASE" TSX_RUN_DIR="$RUNDIR" TSX_APPLY_ALLOW_NONROOT=1 \
	TSX_APPLY_PREFIX="$T/prefix" TSX_STATE_DIR="$T/state" \
	TSX_SETUP_HELPER_REQ="${2:-$RUNDIR/setup-helper}" TSX_SETUP_HELPER_RESP="${3:-$RUNDIR/setup-helper.resp}" \
	TSX_CHPASSWD_BIN="$T/bin/chpasswd" TSX_SHADOW_FILE="$T/shadow" TSX_RCSERVICE_BIN="$T/bin/rc-service" TSX_PANELCTL_BIN="$T/bin/tsx-panelctl" \
		busybox sh "$HELPER" >> "$log" 2>&1 &
	HPID=$!
	for _ in $(seq 1 100); do
		[ "$(grep -c "listening on" "$log" 2>/dev/null)" -gt "$n" ] 2>/dev/null && return 0
		sleep 0.1
	done
	return 1
}
start_helper "$T/helper.log" || { echo "FAIL: tsx-setup-helper did not start"; cat "$T/helper.log"; exit 1; }
HELPER_PID=$HPID

: > "$T/voice-service"   # a panel with a voice service
TSX_CONFIG_BIN="$T/bin/tsx-config" TSX_RUN_DIR="$RUNDIR" TSX_ZONEINFO_DIR="$T/zoneinfo" \
TSX_SETUP_CONF="$T/setup.conf" TSX_SETUP_NO_ZEROCONF=1 TSX_KIOSK_CONF="$T/kiosk.conf" \
TSX_VOICE_SERVICE="$T/voice-service" TSX_SETUP_PLUGIN_DIR="$(dirname "$(P usr/local/share/tsx/setup.d/ha.py)")" \
	python3 "$SETUPD" > "$T/setupd.log" 2>&1 &
SETUPD_PID=$!
for _ in $(seq 1 50); do grep -q "listening on" "$T/setupd.log" 2>/dev/null && break; sleep 0.1; done
grep -q "listening on" "$T/setupd.log" 2>/dev/null || { echo "FAIL: tsx-setupd did not start"; cat "$T/setupd.log"; exit 1; }

# ---- 1. unconfigured: loopback sees the page, a fresh pairing code, no secret fields set
echo "== unconfigured, loopback =="
out=$(call GET /setup/api/state); body=$(body_of "$out")
[ "$(status_of "$out")" = 200 ] && ok "GET state 200" || bad "GET state: $(status_of "$out")"
[ "$(jget need_pairing <<<"$body")" = False ] && ok "loopback needs no pairing" || bad "loopback need_pairing: $body"
[ "$(jget configured <<<"$body")" = False ] && ok "reports unconfigured" || bad "configured should be false: $body"
CODE=$(jget pairing_code <<<"$body")
printf '%s' "$CODE" | grep -Eq '^[0-9]{6}$' && ok "pairing code is 6 digits ($CODE)" || bad "bad pairing code: '$CODE'"
[ "$(jget fields.HA_TOKEN__set <<<"$body")" != True ] && ok "no HA_TOKEN set yet" || bad "HA_TOKEN__set should be unset"
[ "$(jget tz_list.0 <<<"$body")" != "" ] && ok "tz_list is non-empty" || bad "tz_list empty"

out=$(call GET /setup); [ "$(status_of "$out")" = 200 ] && ok "GET /setup 200 on loopback" || bad "GET /setup: $(status_of "$out")"
printf '%s' "$(jget revision <<<"$body")" | grep -Eq '^[0-9a-f]{64}$' && ok "the state has the revision of panel.conf" || bad "no revision in the state: $body"

echo "== the refresh endpoint (/setup/api/status) has the pairing code and the revision, no field =="
out=$(call GET /setup/api/status); sbody=$(body_of "$out")
[ "$(status_of "$out")" = 200 ] && ok "GET status 200" || bad "GET status: $(status_of "$out")"
[ "$(jkeys <<<"$sbody")" = "need_pairing pairing_code pairing_code_remaining revision" ] \
	&& ok "loopback status has only need_pairing, the pairing code and the revision" || bad "loopback status keys: $(jkeys <<<"$sbody")"
[ "$(jget pairing_code <<<"$sbody")" = "$CODE" ] && ok "status gives the same pairing code" || bad "status code: $sbody"
[ "$(jget revision <<<"$sbody")" = "$(jget revision <<<"$body")" ] && ok "status gives the same revision as the state" || bad "status revision: $sbody"

echo "== unconfigured: tsx-setupd listens on 0.0.0.0 (LAN allowed) =="
ss -ltn 2>/dev/null | grep -q "0\.0\.0\.0:$PORT" \
	&& ok "bound to 0.0.0.0 while unconfigured" \
	|| bad "not bound to 0.0.0.0 while unconfigured: $(ss -ltn 2>/dev/null | grep ":$PORT" || echo none)"

# ---- 2. LAN policy while unconfigured: reachable, but needs the code, and never sees it
if [ -n "$LANIP" ]; then
	echo "== unconfigured, simulated LAN ($LANIP) =="
	out=$(call GET /setup --source "$LANIP"); [ "$(status_of "$out")" = 200 ] && ok "LAN GET /setup reachable while unconfigured" || bad "LAN /setup: $(status_of "$out")"
	out=$(call GET /setup/api/state --source "$LANIP"); body=$(body_of "$out")
	[ "$(jget need_pairing <<<"$body")" = True ] && ok "LAN client is asked to pair" || bad "LAN need_pairing: $body"
	[ "$(jget pairing_code <<<"$body")" = "" ] && ok "LAN state never carries the pairing code" || bad "LAN state leaked the code: $body"
	out=$(call GET /setup/api/status --source "$LANIP"); sbody=$(body_of "$out")
	[ "$(jkeys <<<"$sbody")" = "need_pairing" ] && [ "$(jget need_pairing <<<"$sbody")" = True ] \
		&& ok "LAN status before pairing: need_pairing only (no code, no revision)" || bad "LAN status before pairing: $sbody"

	echo "== pairing =="
	out=$(call POST /setup/api/pair --source "$LANIP" --data '{"code":"000000"}')
	if [ "$CODE" = 000000 ]; then bad "test code collided with the real one, rerun"; else
		[ "$(status_of "$out")" = 403 ] && ok "wrong pairing code rejected" || bad "wrong code: $(status_of "$out")"
	fi
	out=$(call POST /setup/api/pair --source "$LANIP" --data "{\"code\":\"$CODE\"}")
	[ "$(status_of "$out")" = 200 ] && ok "correct pairing code accepted" || bad "pair failed: $out"
	TOKEN=$(cookie_of "$out")
	[ -n "$TOKEN" ] && ok "pairing issued a session token" || bad "no session token issued"
	out=$(call GET /setup/api/state --source "$LANIP" --cookie="$TOKEN"); body=$(body_of "$out")
	[ "$(jget need_pairing <<<"$body")" = False ] && ok "paired LAN session no longer needs pairing" || bad "still need_pairing after pairing: $body"
	[ "$(jget pairing_code <<<"$body")" = "" ] && ok "paired LAN session still never sees the code" || bad "paired LAN state leaked the code: $body"
	out=$(call GET /setup/api/status --source "$LANIP" --cookie="$TOKEN"); sbody=$(body_of "$out")
	[ "$(jkeys <<<"$sbody")" = "need_pairing revision" ] && ok "paired LAN status: the revision, never the code" || bad "paired LAN status: $sbody"

	echo "== pairing rate limit =="
	f=0
	for i in $(seq 1 12); do
		out=$(call POST /setup/api/pair --source "$LANIP" --data '{"code":"999999"}')
		[ "$(status_of "$out")" = 429 ] && f=1 && break
	done
	[ "$f" = 1 ] && ok "repeated wrong codes eventually get rate-limited (429)" || bad "no rate limit seen after 12 wrong attempts"
else
	echo "SKIPPED: no non-loopback local address available to simulate a LAN client"
fi

# ---- 3. tsx-setup-helper: strict allowlist, nothing outside it ever runs
echo "== tsx-setup-helper rejects anything outside its command set =="
# These requests go to a second tsx-setup-helper with its own FIFOs. The
# FIFOs of the first one belong to tsx-setupd, which asks the helper every
# few seconds: two readers on one reply FIFO can each get the reply of the
# other.
mkdir -p "$T/h2"
start_helper "$T/helper2.log" "$T/h2/req" "$T/h2/resp" || bad "a second tsx-setup-helper did not start: $(cat "$T/helper2.log")"
HELPER2_PID=$HPID
: > "$FAKE_CMD_LOG"
helper_send() { printf '%s\n' "$1" > "$T/h2/req"; timeout 10 head -1 "$T/h2/resp"; }
r=$(helper_send "frobnicate --evil"); echo "$r" | grep -q '^err' && ok "unknown command rejected: $r" || bad "unknown command not rejected: $r"
r=$(helper_send "unset BAD KEY"); echo "$r" | grep -q '^err' && ok "unset with a spaced key rejected: $r" || bad "bad unset accepted: $r"
r=$(helper_send "; rm -rf /"); echo "$r" | grep -q '^err' && ok "a shell-metacharacter command name rejected: $r" || bad "metacharacter command accepted: $r"
r=$(helper_send "rootpw short"); echo "$r" | grep -q '^err' && ok "a too-short root password rejected: $r" || bad "short root password accepted: $r"
[ ! -s "$FAKE_CMD_LOG" ] && ok "none of the rejected lines ever ran the fake chpasswd" || { bad "a rejected line reached a real command"; cat "$FAKE_CMD_LOG"; }
grep -q '^ok' <(helper_send "show") && ok "the allowed 'show' command still works after the rejected batch" || bad "helper stopped answering after rejections"
r=$(helper_send "rev"); echo "$r" | grep -Eq '^ok [0-9a-f]{64}$' && ok "rev gives a sha256 revision: $r" || bad "rev: $r"
[ "${r#ok }" = "$(rev_now)" ] && ok "two helper processes give the same revision (the salt is in the run directory)" || bad "the second helper gives another revision: $r / $(rev_now)"
[ "$(stat -c %a "$RUNDIR/setup-helper.salt" 2>/dev/null)" = 600 ] && ok "the salt file has mode 600" || bad "salt file: $(ls -l "$RUNDIR/setup-helper.salt" 2>&1)"
r=$(helper_send "rev now"); echo "$r" | grep -q '^err' && ok "rev with an argument is refused" || bad "rev with an argument: $r"
grep -q 'tsx-setup-helper: rev' "$T/helper.log" "$T/helper2.log" && bad "rev writes a log line (the page asks every 20 s)" || ok "rev writes no log line"
r=$(helper_send "#t1 rev"); echo "$r" | grep -Eq '^#t1 ok [0-9a-f]{64}$' && ok "a tagged request gets a reply with the same tag" || bad "tagged rev: $r"
r=$(helper_send "#t2 frobnicate"); [ "$r" = "#t2 err unknown command" ] && ok "a tagged unknown command is refused with the tag" || bad "tagged unknown command: $r"
r=$(helper_send "#t-3 rev"); [ "$r" = "err bad tag" ] && ok "a tag with a character other than a letter or a digit is refused" || bad "bad tag: $r"
r=$(helper_send "brightness-learn-reset"); [ "$r" = ok ] && grep -qxF 'tsx-panelctl send brightness-learn-reset' "$T/panelctl-cmds.log" && ok "brightness-learn-reset asks tsx-panelctl to forget the learned brightness" || bad "learn reset: '$r' $(cat "$T/panelctl-cmds.log" 2>/dev/null)"
r=$(helper_send "brightness-learn-reset now"); echo "$r" | grep -q '^err' && ok "brightness-learn-reset with an argument is refused" || bad "learn reset with an argument: $r"
kill "$HELPER2_PID" 2>/dev/null; wait "$HELPER2_PID" 2>/dev/null; HELPER2_PID=
out=$(call POST /setup/api/brightness-learn-reset --data '{}')
[ "$(status_of "$out")" = 200 ] && [ "$(grep -c 'send brightness-learn-reset' "$T/panelctl-cmds.log")" = 2 ] && ok "the setup page button (POST brightness-learn-reset) reaches the helper" || bad "page reset: $out"

# ---- 4. form validation: bad URL, bad TZ, overlong field, shell metacharacters
echo "== form validation =="
out=$(submit '{}'); body=$(body_of "$out")
[ "$(status_of "$out")" = 400 ] && ok "empty submit rejected (400)" || bad "empty submit: $(status_of "$out")"
[ "$(jget errors.KIOSK_URL <<<"$body")" != "" ] && ok "missing KIOSK_URL flagged" || bad "no KIOSK_URL error: $body"
[ "$(jget errors.HA_LOGIN_METHOD <<<"$body")" = "" ] && ok "an unchanged login method is not an error (the page sends only changed fields)" || bad "HA_LOGIN_METHOD flagged in an empty submit: $body"

out=$(submit '{"KIOSK_URL":"not a url","HA_LOGIN_METHOD":"form"}')
[ "$(status_of "$out")" = 400 ] && ok "bad URL rejected" || bad "bad URL accepted: $out"

LONG=$(python3 -c "print('a'*70)")
out=$(submit "{\"KIOSK_URL\":\"https://ha.example.org\",\"HA_LOGIN_METHOD\":\"form\",\"PANEL_NAME\":\"$LONG\"}")
body=$(body_of "$out")
[ "$(jget errors.PANEL_NAME <<<"$body")" != "" ] && ok "overlong PANEL_NAME rejected" || bad "overlong PANEL_NAME accepted: $out"

out=$(submit '{"KIOSK_URL":"https://ha.example.org","HA_LOGIN_METHOD":"form","TZ_NAME":"Not A Zone!"}')
body=$(body_of "$out")
[ "$(jget errors.TZ_NAME <<<"$body")" != "" ] && ok "malformed TZ_NAME rejected" || bad "malformed TZ_NAME accepted: $out"

out=$(submit '{"KIOSK_URL":"https://ha.example.org","HA_LOGIN_METHOD":"form","ORIENTATION":"sideways"}')
body=$(body_of "$out")
[ "$(jget errors.ORIENTATION <<<"$body")" != "" ] && ok "unknown ORIENTATION rejected" || bad "ORIENTATION sideways accepted: $out"

# Shell metacharacters. MQTT_PASSWORD has no character restriction in the
# val_ok of tsx-config, so tsx-config must accept it. The password must also
# be stored and passed through literally, and never executed. The code uses
# only subprocess argv lists and the argv-shaped FIFO protocol of the helper,
# and never builds a shell string from form input.
rm -f "$T/PWNED"
PAYLOAD='$(touch '"$T"'/PWNED); `touch '"$T"'/PWNED2`; ;rm -rf /'
printf '%s' "$PAYLOAD" > "$T/payload.txt"
JSONBODY=$(python3 -c "
import json
print(json.dumps({'KIOSK_URL':'https://ha.example.org','HA_LOGIN_METHOD':'form','MQTT_HOST':'mq.example','MQTT_PASSWORD': open('$T/payload.txt').read()}))
")
out=$(submit "$JSONBODY")
[ "$(status_of "$out")" = 200 ] && ok "a value with shell metacharacters is accepted (MQTT_PASSWORD has no charset restriction)" || bad "metacharacter payload rejected unexpectedly: $out"
[ ! -e "$T/PWNED" ] && [ ! -e "$T/PWNED2" ] && ok "the metacharacter payload was never executed by a shell" || bad "the payload WAS executed -- a shell was built from form input"
STORED=$(TSX_CONF="$CONF" busybox sh "$TSXCONFIG" get MQTT_PASSWORD)
[ "$STORED" = "$PAYLOAD" ] && ok "the payload round-trips byte-for-byte through panel.conf" || bad "stored value differs: got [$STORED]"
grep -qF 'PWNED' "$T/setupd.log" && bad "the payload leaked into tsx-setupd's own log" || ok "the payload is not in tsx-setupd's log"
grep -qF 'PWNED' "$T/helper.log" && bad "the payload leaked into tsx-setup-helper's own log" || ok "the payload is not in tsx-setup-helper's log"

# ---- 5. a real submit: writes land in panel.conf, secrets never echoed back
echo "== full submit (token login + root password + ssh key) =="
TOKEN_VAL="abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGH"
SSHKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGVoZHRlc3RrZXl0ZXN0a2V5dGVzdGtleXRlc3Rr test@laptop"
ROOTPW="a-fairly-long-test-password-123"
SUBMIT=$(python3 -c "
import json
print(json.dumps({
	'KIOSK_URL': 'https://ha.example.org/lovelace/0',
	'HA_LOGIN_METHOD': 'token', 'HA_TOKEN': '$TOKEN_VAL',
	'PANEL_NAME': 'test-panel-1', 'TZ_NAME': 'America/Denver', 'VOICE': 'on', 'WAKE_WORD': 'okay_nabu',
	'ORIENTATION': 'portrait', 'AUTO_BRIGHTNESS': 'off', 'ALS_SCALE': '2.5',
	'ROOT_PASSWORD': '$ROOTPW', 'SSH_AUTHORIZED_KEY': '$SSHKEY',
	# fields that the user emptied
	'MQTT_HOST': '', 'MQTT_PORT': '', 'MQTT_USER': '', 'MQTT_PASSWORD': '', 'BT_PROXY': 'off',
	'KERNEL_FLAVOR': '', 'BLANK_TIMEOUT': ''
}))
")
out=$(submit "$SUBMIT")
[ "$(status_of "$out")" = 200 ] && ok "full submit accepted" || { bad "full submit failed: $out"; }
grep -q '^KIOSK_URL="https://ha.example.org/lovelace/0"$' "$CONF" && ok "KIOSK_URL landed in the temp panel.conf" || bad "KIOSK_URL missing from $CONF"
grep -q '^PANEL_NAME="test-panel-1"$' "$CONF" && ok "PANEL_NAME landed in panel.conf" || bad "PANEL_NAME missing"
grep -q '^ORIENTATION="portrait"$' "$CONF" && ok "ORIENTATION landed in panel.conf" || bad "ORIENTATION missing"
grep -q '^AUTO_BRIGHTNESS="off"$' "$CONF" && grep -q '^ALS_SCALE="2.5"$' "$CONF" && ok "AUTO_BRIGHTNESS and ALS_SCALE landed in panel.conf" || bad "AUTO_BRIGHTNESS or ALS_SCALE missing"
grep -q '^ALS_AUTO="0"$' "$T/prefix/run/tsx/als.panel" "$RUNDIR/als.panel" 2>/dev/null && ok "apply wrote ALS_AUTO to als.panel" || echo "  (als.panel not checked: apply run dir differs)"
[ "$(cat "$T/prefix/etc/tsx/orientation" 2>/dev/null)" = portrait ] && ok "apply left /etc/tsx/orientation (portrait) in the prefix" || bad "no orientation file after apply"
grep -q '^BT_PROXY="off"$' "$CONF" && ok "BT_PROXY landed in panel.conf" || bad "BT_PROXY missing from panel.conf"
grep -q '^HA_TOKEN=' "$CONF" && ok "HA_TOKEN was written" || bad "HA_TOKEN missing"
grep -Eq '^MQTT_(HOST|PORT|USER)=' "$CONF" && bad "cleared MQTT fields were written as KEY=\"\" instead of removed" || ok "cleared MQTT host/port/user are removed from panel.conf"
[ "$(TSX_CONF="$CONF" busybox sh "$TSXCONFIG" get MQTT_PASSWORD)" = "$PAYLOAD" ] && ok "an empty MQTT password field keeps the stored one (leave blank to keep)" || bad "an empty MQTT password field changed the stored password"
[ -s "$FAKE_CHPASSWD_LOG" ] && grep -qF "root:$ROOTPW" "$FAKE_CHPASSWD_LOG" && ok "chpasswd received the new root password over stdin" || bad "chpasswd did not get the password"
grep -q '^ROOT_PASSWORD_HASH=' "$CONF" && ok "the resulting hash was mirrored into panel.conf (ROOT_PASSWORD_HASH)" || bad "ROOT_PASSWORD_HASH missing from panel.conf"
grep -qF "$ROOTPW" "$CONF" && bad "the plaintext root password ended up in panel.conf" || ok "panel.conf holds the hash, not the plaintext password"
grep -qF "$ROOTPW" "$T/setupd.log" && bad "the root password leaked into tsx-setupd's log" || ok "the root password is not in tsx-setupd's log"
grep -qF "$ROOTPW" "$T/helper.log" && bad "the root password leaked into tsx-setup-helper's log" || ok "the root password is not in tsx-setup-helper's log"
grep -qF "$TOKEN_VAL" "$T/setupd.log" && bad "the HA token leaked into tsx-setupd's log" || ok "the HA token is not in tsx-setupd's log"
grep -qF "$TOKEN_VAL" "$T/helper.log" && bad "the HA token leaked into tsx-setup-helper's log" || ok "the HA token is not in tsx-setup-helper's log"

echo "== state after submit never echoes secrets, but reports them set =="
out=$(call GET /setup/api/state); body=$(body_of "$out")
printf '%s' "$body" | grep -qF "$TOKEN_VAL" && bad "state response echoed the HA token back" || ok "state response never echoes HA_TOKEN"
[ "$(jget fields.HA_TOKEN <<<"$body")" = "" ] && ok "HA_TOKEN value itself is null/empty in the response" || bad "HA_TOKEN value leaked: $body"
[ "$(jget fields.HA_TOKEN__set <<<"$body")" = True ] && ok "HA_TOKEN__set is reported true" || bad "HA_TOKEN__set missing: $body"
[ "$(jget fields.SSH_AUTHORIZED_KEY__set <<<"$body")" = True ] && ok "SSH_AUTHORIZED_KEY__set is reported true" || bad "SSH_AUTHORIZED_KEY__set missing: $body"
[ "$(jget configured <<<"$body")" = True ] && ok "panel now reports configured" || bad "still reports unconfigured: $body"

# rc-service kiosk restart must have been attempted after a successful save
grep -q 'rc-service kiosk status' "$T/rc-service.log" 2>/dev/null && ok "kiosk restart was attempted after saving" || bad "kiosk was never poked after saving"

# ---- 5c. a save writes only the fields that the user changed --------------
echo "== a save writes only the changed fields =="
tcfg() { TSX_CONF="$CONF" busybox sh "$TSXCONFIG" "$@" >/dev/null 2>&1; }
R=$(rev_now)
[ "$R" != "$(sha256sum < "$CONF" | cut -d' ' -f1)" ] && ok "the revision is not the plain sha256 of panel.conf (the helper adds a salt)" || bad "the revision is the plain hash of panel.conf"
cp "$CONF" "$T/conf.before"; M=$(hlog_mark)
out=$(submit '{"BLANK_TIMEOUT":"123"}' "$R"); body=$(body_of "$out")
[ "$(status_of "$out")" = 200 ] && [ "$(jget changed <<<"$body")" = "['BLANK_TIMEOUT']" ] && [ "$(jget applied <<<"$body")" = True ] \
	&& ok "a save of one changed field reports that one key, and apply ran" || bad "one-field save: $out"
grep -q '^BLANK_TIMEOUT="123"$' "$CONF" && [ "$(grep -v '^BLANK_TIMEOUT=' "$T/conf.before")" = "$(conf_except BLANK_TIMEOUT)" ] \
	&& ok "panel.conf: only the BLANK_TIMEOUT line changed" || bad "panel.conf changed more than BLANK_TIMEOUT: $(diff "$T/conf.before" "$CONF")"
[ "$(hlog_writes "$M")" = "set BLANK_TIMEOUT apply" ] && ok "the helper got one set and one apply" || bad "helper writes: $(hlog_writes "$M")"

R=$(rev_now); cp "$CONF" "$T/conf.before"; M=$(hlog_mark)
out=$(submit '{}' "$R"); body=$(body_of "$out")
[ "$(status_of "$out")" = 200 ] && [ "$(jget changed <<<"$body")" = "[]" ] && [ "$(jget applied <<<"$body")" = False ] \
	&& ok "a save with no changed field is accepted and reports no change" || bad "empty save: $out"
cmp -s "$T/conf.before" "$CONF" && [ -z "$(hlog_writes "$M")" ] && ok "a save with no change writes nothing and runs no apply" || bad "empty save wrote: $(hlog_writes "$M")"
hlog_since "$M" | grep -qx kiosk-restart && ok "a save with no change still restarts the kiosk (the user is done)" || bad "empty save: no kiosk restart"
M=$(hlog_mark)
out=$(submit '{"BLANK_TIMEOUT":"123","ORIENTATION":"portrait"}' "$R"); body=$(body_of "$out")
[ "$(status_of "$out")" = 200 ] && [ "$(jget changed <<<"$body")" = "[]" ] && cmp -s "$T/conf.before" "$CONF" && [ -z "$(hlog_writes "$M")" ] \
	&& ok "a value that panel.conf already has is not written again, and apply does not run" || bad "same-value save: $out / $(hlog_writes "$M")"

echo "== a field that the user did not change keeps a value changed elsewhere =="
tcfg set PANEL_NAME changed-elsewhere
R=$(rev_now)
out=$(submit '{"ORIENTATION":"landscape"}' "$R")
[ "$(status_of "$out")" = 200 ] && grep -q '^PANEL_NAME="changed-elsewhere"$' "$CONF" && grep -q '^ORIENTATION="landscape"$' "$CONF" \
	&& ok "the save changed ORIENTATION and kept PANEL_NAME from tsx-config" || bad "PANEL_NAME after save: $(grep '^PANEL_NAME=' "$CONF") / $out"

echo "== a page with an old revision is refused, and nothing changes =="
R=$(rev_now)
tcfg set BLANK_TIMEOUT 77   # a change elsewhere: tsx-config, Home Assistant, another browser
R2=$(rev_now)
[ -n "$R2" ] && [ "$R2" != "$R" ] && ok "a change elsewhere gives a new revision" || bad "the revision did not change: $R / $R2"
cp "$CONF" "$T/conf.before"; M=$(hlog_mark)
out=$(submit '{"PANEL_NAME":"from-the-page","BLANK_TIMEOUT":"300"}' "$R"); body=$(body_of "$out")
[ "$(status_of "$out")" = 409 ] && [ "$(jget stale <<<"$body")" = True ] && ok "a save with the old revision is refused (409, stale)" || bad "stale save: $out"
case "$(jget errors._revision <<<"$body")" in *"changed after this page loaded"*"Reload the page"*) ok "the refusal tells the user to reload the page";; *) bad "stale message: $body";; esac
cmp -s "$T/conf.before" "$CONF" && grep -q '^BLANK_TIMEOUT="77"$' "$CONF" && ok "the refused save changed nothing (BLANK_TIMEOUT stays 77)" || bad "the refused save changed panel.conf: $(diff "$T/conf.before" "$CONF")"
[ -z "$(hlog_writes "$M")" ] && ! hlog_since "$M" | grep -qx kiosk-restart && ok "the refused save sent no write, no apply and no kiosk restart" || bad "refused save: $(hlog_since "$M" | tr '\n' ' ')"
out=$(submit '{"PANEL_NAME":"from-the-page"}' "")
[ "$(status_of "$out")" = 409 ] && cmp -s "$T/conf.before" "$CONF" && ok "a save with fields and no revision is refused" || bad "save without a revision: $out"
out=$(call POST /setup/api/submit --data '{"PANEL_NAME":"from-the-page"}'); body=$(body_of "$out")
[ "$(status_of "$out")" = 400 ] && [ "$(jget errors._request <<<"$body")" != "" ] && cmp -s "$T/conf.before" "$CONF" \
	&& ok "a request in the old form (no fields object) is refused and changes nothing" || bad "old-form request: $out"
out=$(submit '{"PANEL_NAME":"from-the-page"}' "$R2")
[ "$(status_of "$out")" = 200 ] && grep -q '^PANEL_NAME="from-the-page"$' "$CONF" && grep -q '^BLANK_TIMEOUT="77"$' "$CONF" \
	&& ok "after a reload (the new revision) the save works and keeps BLANK_TIMEOUT=77" || bad "save after reload: $out"

echo "== a restart of tsx-setup-helper keeps the revision =="
R=$(rev_now)
kill "$HELPER_PID" 2>/dev/null; wait "$HELPER_PID" 2>/dev/null
start_helper "$T/helper.log" || bad "tsx-setup-helper did not start again: $(tail -n 3 "$T/helper.log")"
HELPER_PID=$HPID
[ -n "$R" ] && [ "$(rev_now)" = "$R" ] && ok "the revision is the same after a restart of tsx-setup-helper" || bad "the revision changed with a restart: $R / $(rev_now)"
out=$(submit '{"BLANK_TIMEOUT":"301"}' "$R")
[ "$(status_of "$out")" = 200 ] && grep -q '^BLANK_TIMEOUT="301"$' "$CONF" \
	&& ok "a page that loaded before the restart can save" || bad "save after a restart of the helper: $out"

echo "== tsx-setupd reads only the reply to its own request =="
R=$(rev_now)
# A request that tsx-setupd did not send (no tag): the helper needs about a
# second for show, so its reply comes while tsx-setupd waits for the reply
# to its own request.
printf 'show\n' > "$RUNDIR/setup-helper"
out=$(call GET /setup/api/status)
[ "$(status_of "$out")" = 200 ] && [ "$(body_of "$out" | jget revision)" = "$R" ] \
	&& ok "a late reply to another request is skipped (the revision is right)" || bad "late reply: $out (want $R)"
[ "$(rev_now)" = "$R" ] && ok "the next request gets its own reply too" || bad "the next request: $(rev_now) (want $R)"

echo "== the revision follows a change of a secret too =="
R=$(rev_now); F1=$(body_of "$(call GET /setup/api/state)" | jget fields)
tcfg set MQTT_PASSWORD another-secret
R2=$(rev_now); F2=$(body_of "$(call GET /setup/api/state)" | jget fields)
[ "$F1" = "$F2" ] && [ "$R" != "$R2" ] && ok "a new MQTT_PASSWORD (masked in the state) gives a new revision" || bad "secret change: same fields $([ "$F1" = "$F2" ] && echo yes), $R / $R2"

echo "== the plugin of tsx-ha: only the changed fields =="
tcfg set VOICE off; tcfg set BT_PROXY on; tcfg set MQTT_HOST mq.example; tcfg set MQTT_PORT 1884
out=$(call GET /setup/api/state); body=$(body_of "$out")
[ "$(jget fields.VOICE <<<"$body")" = off ] && ok "the state reports VOICE=off (the page unchecks the box)" || bad "state VOICE: $(jget fields.VOICE <<<"$body")"
R=$(jget revision <<<"$body"); cp "$CONF" "$T/conf.before"; M=$(hlog_mark)
out=$(submit '{"VOICE":"on"}' "$R"); body=$(body_of "$out")
[ "$(status_of "$out")" = 200 ] && [ "$(jget changed <<<"$body")" = "['VOICE']" ] && grep -q '^VOICE="on"$' "$CONF" \
	&& [ "$(grep -v '^VOICE=' "$T/conf.before")" = "$(conf_except VOICE)" ] \
	&& ok "a save of the voice switch writes VOICE only (BT_PROXY, WAKE_WORD, MQTT stay)" || bad "VOICE save: $out / $(diff "$T/conf.before" "$CONF")"
[ "$(hlog_writes "$M")" = "set VOICE apply" ] && ok "the helper got set VOICE and apply only" || bad "helper writes: $(hlog_writes "$M")"
R=$(rev_now); cp "$CONF" "$T/conf.before"
out=$(submit '{"VOICE":"off"}' "$R")
[ "$(status_of "$out")" = 200 ] && grep -q '^VOICE="off"$' "$CONF" && [ "$(grep -v '^VOICE=' "$T/conf.before")" = "$(conf_except VOICE)" ] \
	&& ok "a save of the switch turned off writes VOICE=off only" || bad "VOICE off save: $out"
R=$(rev_now); cp "$CONF" "$T/conf.before"
out=$(submit '{"WAKE_WORD":"hey_jarvis","MQTT_PORT":""}' "$R"); body=$(body_of "$out")
[ "$(status_of "$out")" = 200 ] && [ "$(jget changed <<<"$body")" = "['MQTT_PORT', 'WAKE_WORD']" ] && grep -q '^WAKE_WORD="hey_jarvis"$' "$CONF" && ! grep -q '^MQTT_PORT=' "$CONF" \
	&& [ "$(grep -Ev '^(WAKE_WORD|MQTT_PORT)=' "$T/conf.before")" = "$(conf_except WAKE_WORD MQTT_PORT)" ] \
	&& ok "WAKE_WORD set and a cleared MQTT_PORT removed, MQTT_HOST stays" || bad "WAKE_WORD and MQTT_PORT save: $out"
NEWTOK="zyxwvutsrqponmlkjihgfedcba9876543210ZYXWVU"
R=$(rev_now); cp "$CONF" "$T/conf.before"
out=$(submit "{\"HA_TOKEN\":\"$NEWTOK\"}" "$R"); body=$(body_of "$out")
[ "$(status_of "$out")" = 200 ] && [ "$(jget changed <<<"$body")" = "['HA_TOKEN']" ] && grep -q '^HA_LOGIN_METHOD="token"$' "$CONF" \
	&& [ "$(TSX_CONF="$CONF" busybox sh "$TSXCONFIG" get HA_TOKEN)" = "$NEWTOK" ] && ok "a new token alone keeps the login method" || bad "token-only save: $out"
R=$(rev_now)
out=$(submit '{"HA_LOGIN_METHOD":"form"}' "$R"); body=$(body_of "$out")
[ "$(status_of "$out")" = 200 ] && [ "$(jget changed <<<"$body")" = "['HA_LOGIN_METHOD', 'HA_TOKEN']" ] && ! grep -Eq '^HA_(LOGIN_METHOD|TOKEN)=' "$CONF" \
	&& ok "the login form removes the method and the token" || bad "form save: $out"
out=$(submit '{"HA_LOGIN_METHOD":"token"}')
[ "$(status_of "$out")" = 400 ] && [ "$(jget errors.HA_TOKEN <<<"$(body_of "$out")")" != "" ] && ok "the token method with no token is refused" || bad "token without token: $out"
out=$(submit "{\"HA_LOGIN_METHOD\":\"token\",\"HA_TOKEN\":\"$TOKEN_VAL\"}")
[ "$(status_of "$out")" = 200 ] && grep -q '^HA_LOGIN_METHOD="token"$' "$CONF" && ok "the token method with a token is saved" || bad "token save: $out"
R=$(rev_now)
tcfg set WAKE_WORD okay_nabu   # a change elsewhere
cp "$CONF" "$T/conf.before"
out=$(submit '{"VOICE":"on"}' "$R")
[ "$(status_of "$out")" = 409 ] && cmp -s "$T/conf.before" "$CONF" && ok "a plugin field with an old revision is refused too, nothing changes" || bad "stale plugin save: $out"
# back to the values that the later sections expect
tcfg set VOICE on; tcfg set BT_PROXY off; tcfg unset MQTT_HOST

echo "== the page script: the form is filled once, the refresh reads only the status =="
out=$(call GET /setup); page=$(body_of "$out")
printf '%s' "$page" > "$T/page.html"
python3 - "$T/page.html" <<'PYEOF' && ok "the 20 s refresh calls loadState only before the first load, then refreshStatus, which sets no field" || bad "page refresh logic"
import re, sys
page = open(sys.argv[1]).read()
def body(name):
    m = re.search(r"function %s\(\)\{\n(.*?)\n  \}\n" % name, page, re.S)
    assert m, name
    return m.group(1)
refresh = body("refreshStatus")
assert '"/setup/api/status"' in refresh
assert "applyFields" not in refresh and ".value" not in refresh and ".checked" not in refresh, refresh
load = body("loadState")
assert "if (loaded) return;" in load and load.index("if (loaded) return;") < load.index("applyFields(")
m = re.search(r"setInterval\(function\(\)\{\n(.*?)\n  \}, 20000\);", page, re.S)
assert m
assert m.group(1).strip().splitlines()[0].strip().startswith("if (!loaded) { loadState(); return; }"), m.group(1)
assert "refreshStatus()" in m.group(1)
PYEOF
case "$page" in *'$("f-voice").checked = fields.VOICE === "on";'*) ok "the page sets the voice checkbox from VOICE both ways (checked and unchecked)";; *) bad "the page sets the voice checkbox only to checked";; esac
case "$page" in *'{revision: state && state.revision, fields: payload}'*'var payload = changedFields();'*|*'var payload = changedFields();'*'{revision: state && state.revision, fields: payload}'*) ok "the page sends the changed fields and the revision";; *) bad "the page does not send changed fields with the revision";; esac

# ---- 6. disabled once configured: not just a 403, no listening LAN socket at all
echo "== configured + no setup-open flag: not even reachable over the network =="
rm -f "$RUNDIR/setup-open"
# is_configured() is cached for a few seconds (tsx-setupd) and the bind is
# reconciled on a poll of its own: give both a moment.
ok_bind=0
for _ in $(seq 1 20); do
	ss -ltn 2>/dev/null | grep -q "127\.0\.0\.1:$PORT" && { ok_bind=1; break; }
	sleep 0.5
done
[ "$ok_bind" = 1 ] && ok "rebound to loopback-only once configured" || bad "still listening on more than loopback once configured: $(ss -ltn 2>/dev/null | grep ":$PORT" || echo none)"
! ss -ltn 2>/dev/null | grep -q "0\.0\.0\.0:$PORT" && ok "no longer bound to 0.0.0.0" || bad "still bound to 0.0.0.0 once configured"
out=$(call GET /setup/api/state); [ "$(status_of "$out")" = 200 ] && ok "loopback still reachable once configured" || bad "loopback blocked once configured"
if [ -n "$LANIP" ]; then
	out=$(call GET /setup --source "$LANIP")
	[ "$(status_of "$out")" = 0 ] && ok "a simulated LAN client cannot even connect once configured (no listening socket there)" \
		|| bad "LAN connection unexpectedly succeeded once configured: status $(status_of "$out")"
fi

# ---- 7. tsx-config setup re-opens it for one window, then it expires ---
# (fake broken `date` is on PATH for all of this: proves the window uses
# /proc/uptime, not wall-clock time -- docs/rootfs.md "Setup page")
echo "== tsx-config setup (monotonic window, PATH has a deliberately broken date) =="
BEFORE_UPTIME=$(awk '{print int($1)}' /proc/uptime)
KR0=$(grep -c 'kiosk-restart' "$T/helper.log" 2>/dev/null || true)
PATH="$T/bin:$PATH" TSX_CONF="$CONF" TSX_RUN="$RUNBASE" TSX_APPLY_ALLOW_NONROOT=1 \
	busybox sh "$TSXCONFIG" setup >/dev/null 2>&1
[ -s "$RUNDIR/setup-open" ] && ok "tsx-config setup wrote /run/tsx/setup-open" || bad "setup-open flag missing"
FLAG_VAL=$(cat "$RUNDIR/setup-open")
printf '%s' "$FLAG_VAL" | grep -Eq '^[0-9]+$' && [ "$FLAG_VAL" -ge "$BEFORE_UPTIME" ] \
	&& ok "the flag holds a real /proc/uptime value ($FLAG_VAL), not something derived from the broken date" \
	|| bad "setup-open does not look like /proc/uptime: '$FLAG_VAL' (uptime was ~$BEFORE_UPTIME)"
for _ in $(seq 1 20); do
	ss -ltn 2>/dev/null | grep -q "0\.0\.0\.0:$PORT" && break
	sleep 0.2
done
RESOLVED=$(PATH="$T/bin:$PATH" TSX_SETUP_CONF="$T/setup.conf" TSX_RUN_DIR="$RUNDIR" busybox sh "$KIOSKURL" "https://ha.example.org/lovelace/0")
[ "$RESOLVED" = "http://127.0.0.1:$PORT/setup" ] && ok "tsx-kiosk-url shows the setup page again after tsx-config setup" || bad "tsx-kiosk-url did not reopen setup: $RESOLVED"
if [ -n "$LANIP" ]; then
	out=$(call GET /setup --source "$LANIP")
	[ "$(status_of "$out")" = 200 ] && ok "LAN reachable again during the reopened window" || bad "LAN still refused during the reopened window: $(status_of "$out")"
fi
# The window is 6 s of whole seconds and the daemon polls once a second.
# Wait for the expiry, not a fixed time, so a slow host does not fail here.
for _ in $(seq 1 100); do
	[ "$(grep -c 'kiosk-restart' "$T/helper.log" 2>/dev/null || true)" -gt "$KR0" ] && [ ! -e "$RUNDIR/setup-open" ] && break
	sleep 0.2
done
KR1=$(grep -c 'kiosk-restart' "$T/helper.log" 2>/dev/null || true)
[ "$KR1" -gt "$KR0" ] && ok "the expired window asks the helper to restart the kiosk (back to Home Assistant)" || bad "window expired but the kiosk was not restarted (setup page stays up): $KR0 -> $KR1"
[ ! -e "$RUNDIR/setup-open" ] && ok "the expired window's flag is removed" || bad "setup-open left behind after expiry"
RESOLVED2=$(PATH="$T/bin:$PATH" TSX_SETUP_CONF="$T/setup.conf" TSX_RUN_DIR="$RUNDIR" busybox sh "$KIOSKURL" "https://ha.example.org/lovelace/0")
[ "$RESOLVED2" = "https://ha.example.org/lovelace/0" ] && ok "the reopened window expires (tsx-kiosk-url), unaffected by the broken date the whole time" || bad "window did not expire: $RESOLVED2"
for _ in $(seq 1 20); do
	ss -ltn 2>/dev/null | grep -q "127\.0\.0\.1:$PORT" && ! ss -ltn 2>/dev/null | grep -q "0\.0\.0\.0:$PORT" && break
	sleep 0.5
done
if [ -n "$LANIP" ]; then
	out=$(call GET /setup --source "$LANIP")
	[ "$(status_of "$out")" = 0 ] && ok "LAN cannot connect again once the reopened window expired" || bad "LAN still reachable after the window expired: $(status_of "$out")"
fi

# ---- 5b. a panel without a microphone or a Bluetooth module (hw.conf, REASON)
echo "== no microphone, no Bluetooth module (hw.conf): the page says why =="
out=$(call GET /setup/api/state); body=$(body_of "$out")
[ "$(jget unavailable <<<"$body")" = "{}" ] && ok "no hw.conf: nothing is marked not available" || bad "no hw.conf: unavailable = $(jget unavailable <<<"$body")"
printf 'MIC=no\nBT=no\nREASON=FAKE-100 NC variant\n' > "$RUNDIR/hw.conf"
out=$(call GET /setup/api/state); body=$(body_of "$out")
[ "$(jget unavailable.VOICE <<<"$body")" = "no microphone on this panel (FAKE-100 NC variant)" ] \
	&& [ "$(jget unavailable.BT_PROXY <<<"$body")" = "no Bluetooth module on this panel (FAKE-100 NC variant)" ] \
	&& ok "state: VOICE and BT_PROXY not available, with the REASON text of hw.conf" || bad "state unavailable: $(jget unavailable <<<"$body")"
out=$(call GET /setup); page=$(body_of "$out")
case "$page" in *'id="hw-hint"'*"function applyUnavailable"*) ok "the page has the not-available hint and disables the voice switch";; *) bad "the page has no not-available hint";; esac
GSUBMIT='{"KIOSK_URL":"https://ha.example.org/lovelace/0","HA_LOGIN_METHOD":"token","VOICE":"off","WAKE_WORD":"hey_jarvis","BT_PROXY":"on"}'
out=$(submit "$GSUBMIT")
[ "$(status_of "$out")" = 200 ] && grep -q '^VOICE="on"$' "$CONF" && grep -q '^WAKE_WORD="okay_nabu"$' "$CONF" \
	&& grep -q '^BT_PROXY="off"$' "$CONF" \
	&& ok "a submit leaves VOICE, WAKE_WORD and BT_PROXY as they are (a panel.conf from another panel keeps them)" \
	|| bad "submit on a panel without the parts: $(status_of "$out"), $(grep -E '^(VOICE|WAKE_WORD|BT_PROXY)=' "$CONF" | tr '\n' ' ')"
case "$page" in *'name="BT_PROXY"'*'id="bt-wrap"'*|*'id="bt-wrap"'*'name="BT_PROXY"'*) ok "the page has the Bluetooth proxy field and hides it when unavailable";; *) bad "the page has no Bluetooth proxy field";; esac
case "$page" in *'(default: off)'*) ok "the Bluetooth proxy field names the default of the board (off)";; *) bad "the Bluetooth proxy field does not name the board default";; esac
case "$page" in *'if (el.disabled) return;'*) ok "the page sends no disabled field";; *) bad "the page sends disabled fields";; esac
rm -f "$RUNDIR/hw.conf"

echo "== a panel with no REASON in hw.conf, and a missing voice service =="
printf 'MIC=no\nBT=no\nPRESENCE=yes\nLIGHT=yes\n' > "$RUNDIR/hw.conf"
out=$(call GET /setup/api/state); body=$(body_of "$out")
[ "$(jget unavailable.VOICE <<<"$body")" = "no microphone on this panel" ] \
	&& [ "$(jget unavailable.BT_PROXY <<<"$body")" = "no Bluetooth module on this panel" ] \
	&& ok "no REASON: the reasons are the short texts" || bad "no REASON: $(jget unavailable <<<"$body")"
printf 'MIC=yes\nBT=yes\n' > "$RUNDIR/hw.conf"
rm -f "$T/voice-service"
out=$(call GET /setup/api/state); body=$(body_of "$out")
[ "$(jget unavailable.VOICE <<<"$body")" = "the voice service is not installed" ] && [ "$(jget unavailable.BT_PROXY <<<"$body")" = "" ] \
	&& ok "no voice service: only the voice fields are not available" || bad "no voice service: $(jget unavailable <<<"$body")"
: > "$T/voice-service"
rm -f "$RUNDIR/hw.conf"

echo "== settings that the page sends for the light sensor =="
out=$(call GET /setup); page=$(body_of "$out")
case "$page" in *'id="sensors-wrap"'*'name="AUTO_BRIGHTNESS"'*'name="ALS_SCALE"'*) ok "the page has the Sensors section with AUTO_BRIGHTNESS and ALS_SCALE";; *) bad "no Sensors section";; esac
out=$(submit '{"KIOSK_URL":"https://ha.example.org/lovelace/0","HA_LOGIN_METHOD":"token","ALS_SCALE":"abc"}')
[ "$(jget errors.ALS_SCALE <<<"$(body_of "$out")")" != "" ] && ok "a bad ALS_SCALE is rejected" || bad "ALS_SCALE abc accepted: $out"
out=$(submit '{"KIOSK_URL":"https://ha.example.org/lovelace/0","HA_LOGIN_METHOD":"token","AUTO_BRIGHTNESS":"maybe"}')
[ "$(jget errors.AUTO_BRIGHTNESS <<<"$(body_of "$out")")" != "" ] && ok "a bad AUTO_BRIGHTNESS is rejected" || bad "AUTO_BRIGHTNESS maybe accepted"
out=$(submit '{"KIOSK_URL":"https://ha.example.org/lovelace/0","HA_LOGIN_METHOD":"token","AUTO_BRIGHTNESS":"","ALS_SCALE":""}')
! grep -Eq '^(AUTO_BRIGHTNESS|ALS_SCALE)=' "$CONF" && ok "empty fields remove both keys (back to the defaults)" || bad "empty fields left keys: $(grep -E '^(AUTO_BRIGHTNESS|ALS_SCALE)=' "$CONF")"
echo "== ALS=no (hw.conf): the light sensor settings are not available =="
printf 'MIC=yes\nBT=yes\nALS=no\n' > "$RUNDIR/hw.conf"
TSX_CONF="$CONF" busybox sh "$TSXCONFIG" set AUTO_BRIGHTNESS on >/dev/null 2>&1; TSX_CONF="$CONF" busybox sh "$TSXCONFIG" set ALS_SCALE 3 >/dev/null 2>&1
out=$(call GET /setup/api/state); body=$(body_of "$out")
[ "$(jget unavailable.AUTO_BRIGHTNESS <<<"$body")" = "no ambient light sensor on this panel" ] && ok "state: AUTO_BRIGHTNESS not available, with the reason" || bad "ALS=no state: $(jget unavailable <<<"$body")"
out=$(call GET /setup); page=$(body_of "$out")
case "$page" in *'Not available on this panel: '*) ok "the page has the Not available on this panel text";; *) bad "no Not available text for the sensor";; esac
out=$(submit '{"KIOSK_URL":"https://ha.example.org/lovelace/0","HA_LOGIN_METHOD":"token","AUTO_BRIGHTNESS":"off","ALS_SCALE":"7"}')
grep -q '^AUTO_BRIGHTNESS="on"$' "$CONF" && grep -q '^ALS_SCALE="3"$' "$CONF" && ok "a submit leaves the light sensor keys as they are" || bad "ALS=no submit changed them: $(grep -E '^(AUTO_BRIGHTNESS|ALS_SCALE)=' "$CONF" | tr '\n' ' ')"
rm -f "$RUNDIR/hw.conf"

echo "== PRESENCE (hw.conf): the presence fields show with yes and hide with no =="
out=$(call GET /setup); page=$(body_of "$out")
case "$page" in *'id="presence-wrap"'*'name="PRESENCE_WAKE"'*'name="PRESENCE_DISTANCE_MM"'*'name="PRESENCE_HOLD_S"'*'$("presence-wrap").style.display = "none"'*) ok "the page has the three presence fields in one block that the page script can hide";; *) bad "no presence block in the page";; esac
printf 'MIC=yes\nBT=yes\nPRESENCE=yes\n' > "$RUNDIR/hw.conf"
out=$(call GET /setup/api/state); body=$(body_of "$out")
[ "$(jget unavailable.PRESENCE_WAKE <<<"$body")" = "" ] && ok "PRESENCE=yes: the presence fields are available" || bad "PRESENCE=yes: unavailable = $(jget unavailable <<<"$body")"
printf 'MIC=yes\nBT=yes\nPRESENCE=no\nREASON=\n' > "$RUNDIR/hw.conf"
TSX_CONF="$CONF" busybox sh "$TSXCONFIG" set PRESENCE_WAKE on >/dev/null 2>&1; TSX_CONF="$CONF" busybox sh "$TSXCONFIG" set PRESENCE_HOLD_S 45 >/dev/null 2>&1
out=$(call GET /setup/api/state); body=$(body_of "$out")
[ "$(jget unavailable.PRESENCE_WAKE <<<"$body")" = "no distance sensor on this panel" ] && ok "PRESENCE=no: the presence fields are not available, with the reason" || bad "PRESENCE=no: unavailable = $(jget unavailable <<<"$body")"
[ "$(jget unavailable.AUTO_BRIGHTNESS <<<"$body")" = "" ] && ok "PRESENCE=no: the light sensor fields are not touched" || bad "PRESENCE=no hides the light sensor: $(jget unavailable <<<"$body")"
out=$(submit '{"KIOSK_URL":"https://ha.example.org/lovelace/0","HA_LOGIN_METHOD":"token","PRESENCE_WAKE":"off","PRESENCE_HOLD_S":"90"}')
grep -q '^PRESENCE_WAKE="on"$' "$CONF" && grep -q '^PRESENCE_HOLD_S="45"$' "$CONF" && ok "PRESENCE=no: a submit leaves the presence keys as they are" || bad "PRESENCE=no submit changed them: $(grep -E '^PRESENCE_' "$CONF" | tr '\n' ' ')"
rm -f "$RUNDIR/hw.conf"

# ---- 8. unconfigured trigger, from tsx-kiosk-url's own point of view ----
echo "== tsx-kiosk-url: unconfigured always shows setup =="
R=$(TSX_SETUP_CONF="$T/setup.conf" TSX_RUN_DIR="$RUNDIR" busybox sh "$KIOSKURL" "")
[ "$R" = "http://127.0.0.1:$PORT/setup" ] && ok "empty KIOSK_URL -> setup page" || bad "empty KIOSK_URL did not trigger setup: $R"

# ---- 9. a URL only in /etc/kiosk.conf (install --kiosk-url, no panel.conf) is configured too
echo "== is_configured: panel.conf KIOSK_URL, else /etc/kiosk.conf's =="
isconf() {  # isconf PANEL_CONF_URL KIOSK_CONF_TEXT -> True/False
	printf '%s\n' "$2" > "$T/kiosk-ic.conf"
	TSX_KIOSK_CONF="$T/kiosk-ic.conf" TSX_SETUP_CONF="$T/setup.conf" TSX_RUN_DIR="$T/ic-run" TSX_SETUP_NO_ZEROCONF=1 \
		python3 -c 'import sys, importlib.machinery as m
d = m.SourceFileLoader("setupd", sys.argv[1]).load_module()
d.tcfg_show = lambda: {"KIOSK_URL": sys.argv[2]} if sys.argv[2] else {}
print(d.is_configured())' "$SETUPD" "$1" 2>/dev/null
}
[ "$(isconf "" 'KIOSK_URL=""')" = False ] && ok "no URL anywhere: unconfigured" || bad "no URL anywhere should be unconfigured"
[ "$(isconf "" 'KIOSK_URL="https://ha.example.org"')" = True ] && ok "URL only in /etc/kiosk.conf: configured (LAN setup closed)" || bad "a kiosk.conf URL left the panel unconfigured (LAN setup open while the kiosk shows HA)"
[ "$(isconf "https://ha.example.org" '# KIOSK_URL="https://x.example.org"')" = True ] && ok "panel.conf URL: configured" || bad "panel.conf URL should be configured"

# ---- 10. the fields per package: the base page, and the plugin of tsx-ha -------
echo "== the setup page of the base has no Home Assistant, MQTT or voice field =="
# Both instances share the one response channel of tsx-setup-helper, so only
# one runs at a time. The first one stops here and starts again below.
kill "$SETUPD_PID" 2>/dev/null; wait "$SETUPD_PID" 2>/dev/null; SETUPD_PID=
PORT2=$(get_free_port)
sed "s/TSX_SETUP_PORT=.*/TSX_SETUP_PORT=$PORT2/" "$T/setup.conf" > "$T/setup2.conf"
mkdir -p "$T/noplugins"
TSX_CONFIG_BIN="$T/bin/tsx-config" TSX_RUN_DIR="$RUNDIR" TSX_ZONEINFO_DIR="$T/zoneinfo" \
TSX_SETUP_CONF="$T/setup2.conf" TSX_SETUP_NO_ZEROCONF=1 TSX_KIOSK_CONF="$T/kiosk.conf" TSX_SETUP_PLUGIN_DIR="$T/noplugins" \
	python3 "$SETUPD" > "$T/setupd2.log" 2>&1 &
SETUPD2_PID=$!
for _ in $(seq 1 50); do grep -q "listening on" "$T/setupd2.log" 2>/dev/null && break; sleep 0.1; done
PORT_HA=$PORT; PORT=$PORT2
out=$(call GET /setup); page=$(body_of "$out")
[ "$(status_of "$out")" = 200 ] && ok "base page: GET /setup 200" || bad "base page: $(status_of "$out")"
for want in 'name="KIOSK_URL"' 'name="PANEL_NAME"' 'name="TZ_NAME"' 'name="ORIENTATION"' 'name="BLANK_TIMEOUT"' 'name="AUTO_BRIGHTNESS"' 'name="ALS_SCALE"' 'name="ROOT_PASSWORD"' 'name="SSH_AUTHORIZED_KEY"' 'name="KERNEL_FLAVOR"' '<h2>Network</h2>' '<h2>Display</h2>' '<summary>Updates</summary>'; do
	case "$page" in *"$want"*) ok "base page has $want";; *) bad "base page lacks $want";; esac
done
for nope in HA_LOGIN_METHOD HA_TOKEN '"VOICE"' WAKE_WORD MQTT_ 'Home Assistant' homeassistant 'Voice assistant' 'discover' 'check-url' '@@' 'SLOT'; do
	case "$page" in *"$nope"*) bad "base page has $nope";; *) ok "base page has no $nope";; esac
done
case "$page" in *'id="submit-btn" type="submit">Save</button>'*) ok "base page: the button says Save";; *) bad "base page: button text";; esac
out=$(call GET /setup/api/state); body=$(body_of "$out")
[ "$(jget fields.KIOSK_URL <<<"$body")" != "" ] && ok "base state: reports KIOSK_URL" || bad "base state lacks KIOSK_URL"
TSX_CONF="$CONF" busybox sh "$TSXCONFIG" set MQTT_HOST 192.0.2.7 >/dev/null 2>&1; TSX_CONF="$CONF" busybox sh "$TSXCONFIG" set VOICE on >/dev/null 2>&1
out=$(call GET /setup/api/state); body=$(body_of "$out")
[ "$(jget fields.MQTT_HOST <<<"$body")" = "" ] && [ "$(jget fields.VOICE <<<"$body")" = "" ] && ok "base state: reports no MQTT or voice key" || bad "base state shows HA keys: $body"
out=$(call GET /setup/api/discover); [ "$(status_of "$out")" = 404 ] && ok "base: no /setup/api/discover" || bad "base: discover exists: $(status_of "$out")"
out=$(call POST /setup/api/check-url --data '{"url":"https://ha.example.org"}'); [ "$(status_of "$out")" = 404 ] && ok "base: no /setup/api/check-url" || bad "base: check-url exists: $(status_of "$out")"
# a submit with no login method works, and the HA keys that a client sends are ignored
HAKEYS_BEFORE=$(grep -E '^(HA_LOGIN_METHOD|HA_TOKEN|MQTT_HOST|MQTT_PORT|VOICE|WAKE_WORD)=' "$CONF")
out=$(submit '{"KIOSK_URL":"https://example.org/page","PANEL_NAME":"BASE-PANEL","HA_LOGIN_METHOD":"trusted","MQTT_HOST":"198.51.100.9","VOICE":"off"}')
[ "$(status_of "$out")" = 200 ] && ok "base: a submit without a login method is saved" || bad "base submit: $out"
grep -q '^KIOSK_URL="https://example.org/page"$' "$CONF" && grep -q '^PANEL_NAME="BASE-PANEL"$' "$CONF" && ok "base: the page URL and the panel name are saved" || bad "base submit did not save: $(grep -E '^(KIOSK_URL|PANEL_NAME)=' "$CONF" | tr '\n' ' ')"
HAKEYS_AFTER=$(grep -E '^(HA_LOGIN_METHOD|HA_TOKEN|MQTT_HOST|MQTT_PORT|VOICE|WAKE_WORD)=' "$CONF")
[ "$HAKEYS_BEFORE" = "$HAKEYS_AFTER" ] && grep -q '^MQTT_HOST="192.0.2.7"$' "$CONF" && ok "base: the keys of the Home Assistant layer are not written or changed" || bad "base submit touched HA keys: $HAKEYS_AFTER"
out=$(submit '{"KIOSK_URL":""}')
[ "$(jget errors.KIOSK_URL <<<"$(body_of "$out")")" = "the page URL is required" ] && ok "base: the URL message does not name Home Assistant" || bad "base URL message: $(body_of "$out")"
kill "$SETUPD2_PID" 2>/dev/null; wait "$SETUPD2_PID" 2>/dev/null
PORT=$PORT_HA
TSX_CONFIG_BIN="$T/bin/tsx-config" TSX_RUN_DIR="$RUNDIR" TSX_ZONEINFO_DIR="$T/zoneinfo" \
TSX_SETUP_CONF="$T/setup.conf" TSX_SETUP_NO_ZEROCONF=1 TSX_KIOSK_CONF="$T/kiosk.conf" \
TSX_VOICE_SERVICE="$T/voice-service" TSX_SETUP_PLUGIN_DIR="$(dirname "$(P usr/local/share/tsx/setup.d/ha.py)")" \
	python3 "$SETUPD" > "$T/setupd3.log" 2>&1 &
SETUPD_PID=$!
for _ in $(seq 1 50); do grep -q "listening on" "$T/setupd3.log" 2>/dev/null && break; sleep 0.1; done

echo "== the page with the plugin of tsx-ha has the Home Assistant fields too =="
out=$(call GET /setup); page=$(body_of "$out")
for want in 'name="HA_LOGIN_METHOD"' 'name="HA_TOKEN"' 'name="VOICE"' 'name="WAKE_WORD"' 'name="MQTT_HOST"' 'name="MQTT_PASSWORD"' 'id="discover-btn"' 'Save and open Home Assistant' 'name="PANEL_NAME"' 'name="KERNEL_FLAVOR"'; do
	case "$page" in *"$want"*) ok "ha page has $want";; *) bad "ha page lacks $want";; esac
done
case "$page" in *'@@'*|*'SLOT'*) bad "ha page has a slot left";; *) ok "ha page: every slot is filled";; esac
out=$(submit '{"KIOSK_URL":"https://ha.example.org/x","HA_LOGIN_METHOD":"bogus"}')
[ "$(jget errors.HA_LOGIN_METHOD <<<"$(body_of "$out")")" = "choose a login method" ] && ok "ha: an unknown login method is refused" || bad "ha: login method bogus: $out"
out=$(call GET /setup/api/discover); [ "$(status_of "$out")" = 200 ] && ok "ha: /setup/api/discover exists" || bad "ha: no discover"
out=$(call POST /setup/api/check-url --data '{"url":"ftp://x"}'); [ "$(jget kind <<<"$(body_of "$out")")" = invalid ] && ok "ha: /setup/api/check-url exists" || bad "ha: no check-url: $out"
# a broken plugin is skipped
mkdir -p "$T/badplug"; printf 'raise RuntimeError("boom")\n' > "$T/badplug/bad.py"
n=$(TSX_SETUP_PLUGIN_DIR="$T/badplug" TSX_SETUP_CONF="$T/setup.conf" TSX_RUN_DIR="$T/ic-run" python3 -c 'import sys, importlib.machinery as m
d = m.SourceFileLoader("setupd", sys.argv[1]).load_module()
print(len(d.PLUGINS), "boom" in d.PAGE)' "$SETUPD" 2>"$T/badplug.err")
[ "$n" = "0 False" ] && grep -q 'plugin bad.py skipped' "$T/badplug.err" && ok "a plugin that fails to load is skipped, the page still builds" || bad "broken plugin: $n $(cat "$T/badplug.err")"

echo "== $N ok, $F failed =="
[ "$F" = 0 ] && echo PASS test-setup || echo FAIL test-setup
exit "$F"
