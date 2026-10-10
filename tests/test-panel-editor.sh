#!/bin/bash
# Host test for the setup page of a panel with no kiosk, and for the layout
# editor of the panel app (docs/panel-app.md, docs/layout.md). The test starts
# the real tsx-setup-helper and the real tsx-setupd on a free port, with
# temporary folders and fake helper binaries. It never uses the panel, a
# container or root. The test covers:
#  - the mode with no kiosk (TSX_SETUP_KIOSK): no page URL, no blank timeout,
#    the first save needs no KIOSK_URL, a save restarts no kiosk
#  - screen.json, the pairing code for a native screen: the keys, mode 600,
#    the refresh, and the removal when the LAN window closes or the process ends
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1   # the test imports tsx-setupd: no .pyc next to it
. "$(dirname "$0")/lib/board.sh"
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/tests/lib/paths.sh"
SETUPD=$(P usr/local/sbin/tsx-setupd)
HELPER=$(P usr/local/sbin/tsx-setup-helper)
TSXCONFIG=$(P usr/local/sbin/tsx-config)
HAPLUGIN=$(P usr/local/share/tsx/setup.d/ha.py)
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED test-panel-editor: no busybox on this host"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIPPED test-panel-editor: no python3 on this host"; exit 0; }

T=$(mktemp -d)
SETUPD_PID= HELPER_PID=
cleanup() {
	[ -n "$SETUPD_PID" ] && kill "$SETUPD_PID" 2>/dev/null
	[ -n "$HELPER_PID" ] && kill "$HELPER_PID" 2>/dev/null
	[ -n "${KEEP:-}" ] && echo "kept $T" || rm -rf "$T"
}
trap cleanup EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N + 1)); }
bad() { echo "  FAIL: $*"; F=$((F + 1)); }

# ---- fixtures -------------------------------------------------------------
mkdir -p "$T/run/tsx" "$T/bin" "$T/zoneinfo/America" "$T/plugins" "$T/state"
touch "$T/zoneinfo/UTC" "$T/zoneinfo/America/New_York" "$T/zoneinfo/America/Denver"
CONF="$T/panel.conf"
RUNBASE="$T/run"; RUNDIR="$T/run/tsx"
cat > "$T/bin/tsx-config" <<EOF
#!/bin/sh
exec busybox sh "$TSXCONFIG" "\$@"
EOF
cat > "$T/bin/rc-service" <<EOF
#!/bin/sh
echo "rc-service \$*" >> "$T/rc-service.log"
case "\$2" in status) exit 1;; *) exit 0;; esac
EOF
chmod +x "$T/bin/tsx-config" "$T/bin/rc-service"
ln -s "$HAPLUGIN" "$T/plugins/ha.py"
cat > "$T/setup.conf" <<EOF
TSX_SETUP_PORT=0
TSX_SETUP_LAN=on
TSX_SETUP_WINDOW=8
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

# The same client as tests/test-setup.sh: it prints the status, the cookie and
# the body. --source connects from a local address that is not loopback.
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
	# Retry a request that the server did not get (a rebind of the listening
	# socket). Never retry a request that the server got.
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
jget() {  # jget PATH <<< "$body"   PATH is a dotted path into the JSON object
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
rev_now() { body_of "$(call GET /setup/api/state)" | jget revision; }
# submit FIELDS_JSON [REVISION]: a save as the page sends it
submit() {
	local rev
	if [ $# -ge 2 ]; then rev=$2; else rev=$(rev_now); fi
	call POST /setup/api/submit --data "$(python3 -c 'import json, sys
print(json.dumps({"revision": sys.argv[2] or None, "fields": json.loads(sys.argv[1])}))' "$1" "$rev")"
}
tcfg() { TSX_CONF="$CONF" busybox sh "$TSXCONFIG" "$@" >/dev/null 2>&1; }
# wait_for SECONDS COMMAND...: run the command every 0.2 s until it succeeds
wait_for() { local n=$(($1 * 5)); shift; while [ "$n" -gt 0 ]; do "$@" && return 0; n=$((n - 1)); sleep 0.2; done; return 1; }
listens_on() { ss -ltn 2>/dev/null | grep -q "$1:$PORT"; }
has_file() { [ -e "$1" ]; }
no_file() { [ ! -e "$1" ]; }
LANIP=$(python3 -c "
import socket
try:
	s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
	s.connect(('192.0.2.1', 80))
	print(s.getsockname()[0])
except Exception:
	print('')
" 2>/dev/null)
[ "$LANIP" != 127.0.0.1 ] || LANIP=

# ---- the helper (root side) and the daemon ------------------------------------
start_helper() {
	local log=$1 n
	n=$(grep -c "listening on" "$log" 2>/dev/null); n=${n:-0}
	PATH="$T/bin:$PATH" TSX_CONFIG_BIN="$T/bin/tsx-config" TSX_CONF="$CONF" \
	TSX_RUN="$RUNBASE" TSX_RUN_DIR="$RUNDIR" TSX_APPLY_ALLOW_NONROOT=1 \
	TSX_APPLY_PREFIX="$T/prefix" TSX_STATE_DIR="$T/tsx-state" \
	TSX_RCSERVICE_BIN="$T/bin/rc-service" TSX_SETUP_STATE_DIR="$T/state" \
		busybox sh "$HELPER" >> "$log" 2>&1 &
	HELPER_PID=$!
	for _ in $(seq 1 100); do
		[ "$(grep -c "listening on" "$log" 2>/dev/null)" -gt "$n" ] 2>/dev/null && return 0
		sleep 0.1
	done
	return 1
}
# start_setupd LOG [VAR=value...]: tsx-setupd on PORT; the variables after LOG
# are set for it
start_setupd() {
	local log=$1; shift
	env TSX_CONFIG_BIN="$T/bin/tsx-config" TSX_RUN_DIR="$RUNDIR" TSX_ZONEINFO_DIR="$T/zoneinfo" \
		TSX_SETUP_CONF="$T/setup.conf" TSX_SETUP_NO_ZEROCONF=1 TSX_KIOSK_CONF="$T/kiosk.conf" \
		TSX_SETUP_STATE_DIR="$T/state" TSX_SETUP_PLUGIN_DIR="$T/plugins" \
		TSX_VOICE_SERVICE="$T/voice-service" "$@" \
		python3 "$SETUPD" > "$log" 2>&1 &
	SETUPD_PID=$!
	for _ in $(seq 1 50); do grep -q "listening on" "$log" 2>/dev/null && return 0; sleep 0.1; done
	return 1
}
stop_setupd() { kill "$SETUPD_PID" 2>/dev/null; wait "$SETUPD_PID" 2>/dev/null; SETUPD_PID=; }
start_helper "$T/helper.log" || { echo "FAIL: tsx-setup-helper did not start"; cat "$T/helper.log"; exit 1; }
: > "$T/voice-service"

# ==== 1. a panel with no kiosk =================================================
echo "== no kiosk (TSX_SETUP_KIOSK=off): the state, the page and the first save =="
start_setupd "$T/setupd.log" TSX_SETUP_KIOSK=off || { echo "FAIL: tsx-setupd did not start"; cat "$T/setupd.log"; exit 1; }
out=$(call GET /setup/api/state); body=$(body_of "$out")
[ "$(jget kiosk <<<"$body")" = False ] && ok "the state says: no kiosk" || bad "state kiosk: $body"
[ "$(jget configured <<<"$body")" = False ] && ok "an empty panel.conf is not configured" || bad "configured: $body"
CODE=$(jget pairing_code <<<"$body")
printf '%s' "$CODE" | grep -Eq '^[0-9]{6}$' && ok "loopback still gets the pairing code from the state API" || bad "pairing code: '$CODE'"
out=$(call GET /setup); page=$(body_of "$out")
[ "$(status_of "$out")" = 200 ] && ok "GET /setup 200" || bad "GET /setup: $(status_of "$out")"
case "$page" in *'id="url-card"'*'id="blank-wrap"'*'function applyKiosk(on, s)'*) ok "the page has the blocks that the script hides with no kiosk";; *) bad "the page lacks the kiosk blocks";; esac
case "$page" in *'id="submit-btn" type="submit">Save</button>'*) ok "the save button says Save, not the words of a plugin for a kiosk";; *) bad "the save button text: $(printf '%s' "$page" | grep -o 'id="submit-btn"[^<]*')";; esac
case "$page" in *'Saved. The settings are in use now.'*) ok "the text after a save does not say that the panel loads a page";; *) bad "done text";; esac
case "$page" in *'$("login-wrap").style.display = on'*) ok "the login method of the browser is hidden too (the plugin names its keys)";; *) bad "no login-wrap hide";; esac
if [ -n "$LANIP" ]; then
	out=$(call GET /setup/api/state --source "$LANIP"); body=$(body_of "$out")
	[ "$(jget need_pairing <<<"$body")" = True ] && [ "$(jget pairing_code <<<"$body")" = "" ] \
		&& ok "a LAN client still has to pair, and never sees the code" || bad "LAN state: $body"
fi

echo "== screen.json: the pairing code for a native screen =="
SJ="$T/state/screen.json"
wait_for 10 has_file "$SJ" && ok "screen.json exists while the LAN window is open" || bad "no screen.json"
[ "$(stat -c %a "$SJ" 2>/dev/null)" = 600 ] && ok "screen.json has mode 600" || bad "screen.json mode: $(stat -c %a "$SJ" 2>&1)"
python3 - "$SJ" "$CODE" "$PORT" 8 <<'PYEOF' && ok "screen.json: the keys, the code, the port, the path, the addresses, remaining and uptime" || bad "screen.json content: $(cat "$SJ")"
import ipaddress, json, sys
d = json.load(open(sys.argv[1]))
assert sorted(d) == ["addresses", "code", "path", "port", "remaining", "uptime"], sorted(d)
assert d["code"] == sys.argv[2], d
assert d["port"] == int(sys.argv[3]) and d["path"] == "/setup", d
assert isinstance(d["addresses"], list)
for a in d["addresses"]:
    assert ipaddress.IPv4Address(a) and not a.startswith("127."), a
assert isinstance(d["remaining"], int) and 0 <= d["remaining"] <= int(sys.argv[4]), d
up = int(float(open("/proc/uptime").read().split()[0]))
assert isinstance(d["uptime"], int) and 0 <= up - d["uptime"] < 30, (d, up)
PYEOF
U1=$(jget uptime < "$SJ"); R1=$(jget remaining < "$SJ")
sleep 3.2
U2=$(jget uptime < "$SJ")
[ "$U2" -gt "$U1" ] && ok "the file is written again (uptime $U1 -> $U2) in less than 5 s" || bad "screen.json not refreshed: $U1 / $U2"
ls "$T/state" | grep -q 'tmp' && bad "a temporary file stays in the state folder: $(ls -a "$T/state")" || ok "no temporary file stays in the state folder"

echo "== the first save needs no KIOSK_URL =="
tcfg set BLANK_TIMEOUT 120   # a key that no service of this panel reads; this makes panel.conf non-empty
tcfg unset BLANK_TIMEOUT
out=$(call GET /setup/api/state); body=$(body_of "$out")
[ "$(jget configured <<<"$body")" = False ] && ok "a panel.conf with no key is still not configured" || bad "configured after unset: $body"
out=$(submit '{}'); body=$(body_of "$out")
[ "$(status_of "$out")" = 200 ] && [ "$(jget changed <<<"$body")" = "[]" ] && ok "a save with no change and no URL is accepted" || bad "empty save: $out"
! grep -qv '^#' "$CONF" 2>/dev/null && ok "the save with no change wrote no key" || bad "panel.conf has keys: $(cat "$CONF")"
KR0=$(grep -c 'kiosk-restart' "$T/helper.log" 2>/dev/null || true)
out=$(submit '{"TZ_NAME":"America/Denver","KIOSK_URL":"https://example.org/x","BLANK_TIMEOUT":"90"}'); body=$(body_of "$out")
[ "$(status_of "$out")" = 200 ] && grep -q '^TZ_NAME="America/Denver"$' "$CONF" && ok "the first save with TZ_NAME makes panel.conf" || bad "first save: $out / $(cat "$CONF" 2>&1)"
grep -Eq '^(KIOSK_URL|BLANK_TIMEOUT)=' "$CONF" && bad "KIOSK_URL or BLANK_TIMEOUT were written: $(cat "$CONF")" || ok "KIOSK_URL and BLANK_TIMEOUT from a client are ignored"
[ "$(jget changed <<<"$body")" = "['TZ_NAME']" ] && ok "the save reports TZ_NAME only" || bad "changed: $body"
[ "$(grep -c 'kiosk-restart' "$T/helper.log" 2>/dev/null || true)" = "$KR0" ] && ok "a save restarts no kiosk" || bad "the save asked for a kiosk restart"
out=$(call GET /setup/api/state); body=$(body_of "$out")
[ "$(jget configured <<<"$body")" = True ] && ok "the panel is configured now" || bad "configured: $body"
wait_for 15 no_file "$SJ" && ok "screen.json is removed when the first save closes the LAN window" || bad "screen.json stays after the save"
wait_for 15 listens_on 127.0.0.1 && ! listens_on 0.0.0.0 && ok "the listener is on loopback only" || bad "listeners: $(ss -ltn | grep ":$PORT")"
tcfg set BLANK_TIMEOUT 120
body=$(body_of "$(call GET /setup/api/state)")
[ "$(jget fields.BLANK_TIMEOUT <<<"$body")" = "" ] && [ "$(jget fields.TZ_NAME <<<"$body")" = "America/Denver" ] \
	&& ok "the state has no BLANK_TIMEOUT (only tsx-idled reads it) but has the other keys" || bad "state fields: $(jget fields <<<"$body")"

echo "== the window of tsx-config setup writes screen.json again, and its end removes it =="
PATH="$T/bin:$PATH" TSX_CONF="$CONF" TSX_RUN="$RUNBASE" TSX_APPLY_ALLOW_NONROOT=1 busybox sh "$TSXCONFIG" setup >/dev/null 2>&1
wait_for 15 has_file "$SJ" && ok "a reopened window writes screen.json" || bad "no screen.json after tsx-config setup"
# The daemon makes a new code when the code is older than the window (8 s
# here). On a slow host the file and the state API can fall on both sides of
# that change. The file follows the new code at its next write (every 2 s).
same_code() {
	CODE2=$(jget code < "$SJ" 2>/dev/null)
	[ -n "$CODE2" ] && [ "$CODE2" = "$(body_of "$(call GET /setup/api/state)" | jget pairing_code)" ]
}
wait_for 10 same_code && ok "the file and the state API give the same code" || bad "code differs: $CODE2"
KR1=$(grep -c 'kiosk-restart' "$T/helper.log" 2>/dev/null || true)
wait_for 30 no_file "$SJ" && ok "screen.json is removed when the window expires" || bad "screen.json stays after the window"
[ "$(grep -c 'kiosk-restart' "$T/helper.log" 2>/dev/null || true)" = "$KR1" ] && ok "the end of the window restarts no kiosk" || bad "kiosk restart at the end of the window"

echo "== screen.json is removed when the process ends =="
PATH="$T/bin:$PATH" TSX_CONF="$CONF" TSX_RUN="$RUNBASE" TSX_APPLY_ALLOW_NONROOT=1 busybox sh "$TSXCONFIG" setup >/dev/null 2>&1
wait_for 15 has_file "$SJ" && ok "the window is open again" || bad "no screen.json"
stop_setupd
no_file "$SJ" && ok "SIGTERM removes screen.json" || bad "screen.json stays after SIGTERM"
printf '{"stale": true}\n' > "$SJ"
start_setupd "$T/setupd2.log" TSX_SETUP_KIOSK=off
sleep 1.5
[ "$(jget stale < "$SJ" 2>/dev/null)" = "" ] || [ ! -e "$SJ" ] && ok "the start removes a file of an earlier run" || bad "stale screen.json: $(cat "$SJ")"
rm -f "$RUNDIR/setup-open"

echo "== the mode: auto looks for the kiosk.conf, on and off set it =="
mode() {  # mode CONF_VALUE ENV_VALUE KIOSK_CONF_EXISTS -> True/False
	printf 'TSX_SETUP_KIOSK=%s\n' "$1" > "$T/mode.conf"
	rm -f "$T/mode-kiosk.conf"; [ "$3" = yes ] && : > "$T/mode-kiosk.conf"
	env -u TSX_SETUP_KIOSK ${2:+TSX_SETUP_KIOSK=$2} TSX_SETUP_CONF="$T/mode.conf" TSX_RUN_DIR="$T/ic-run" TSX_KIOSK_CONF="$T/mode-kiosk.conf" \
		TSX_SETUP_PLUGIN_DIR="$T/none" python3 -c 'import sys, importlib.machinery as m
d = m.SourceFileLoader("setupd", sys.argv[1]).load_module()
print(d.kiosk_enabled())' "$SETUPD" 2>/dev/null
}
[ "$(mode auto "" yes)" = True ] && [ "$(mode auto "" no)" = False ] && ok "auto: on when kiosk.conf exists, off when it does not" || bad "auto mode"
[ "$(mode "" "" yes)" = True ] && [ "$(mode "" "" no)" = False ] && ok "no setting is auto" || bad "default mode"
[ "$(mode on "" no)" = True ] && [ "$(mode off "" yes)" = False ] && ok "on and off in setup.conf win over the file" || bad "on/off mode"
[ "$(mode off on yes)" = True ] && ok "the environment replaces the setup.conf key" || bad "env mode"
# configured, with no kiosk: panel.conf has a key
conf_with() {  # conf_with SHOWN_JSON KIOSK -> True/False
	env TSX_SETUP_KIOSK="$2" TSX_SETUP_CONF="$T/setup.conf" TSX_RUN_DIR="$T/ic-run" TSX_KIOSK_CONF="$T/none.conf" TSX_SETUP_PLUGIN_DIR="$T/none" \
		python3 -c 'import sys, json, importlib.machinery as m
d = m.SourceFileLoader("setupd", sys.argv[1]).load_module()
d.tcfg_show = lambda: json.loads(sys.argv[2])
print(d.is_configured())' "$SETUPD" "$1" 2>/dev/null
}
[ "$(conf_with '{}' off)" = False ] && [ "$(conf_with '{"TZ_NAME": "UTC"}' off)" = True ] && ok "no kiosk: configured = panel.conf has a key" || bad "configured, no kiosk"
[ "$(conf_with '{"# WARNING: x y z": "1"}' off)" = False ] && ok "no kiosk: a comment line of tsx-config is no key" || bad "comment line counts"
[ "$(conf_with '{"TZ_NAME": "UTC"}' on)" = False ] && [ "$(conf_with '{"KIOSK_URL": "https://example.org"}' on)" = True ] && ok "with a kiosk: configured = a page URL (as before)" || bad "configured, kiosk"

echo "== $N ok, $F failed =="
[ "$F" = 0 ] && echo PASS test-panel-editor || echo FAIL test-panel-editor
exit "$F"
