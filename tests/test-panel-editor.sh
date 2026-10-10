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
#  - the layout editor, a plugin of the setup page: the page, the API (the
#    layout of the user, of the board or the example; check; save through the
#    helper; the pairing rule), the API encryption key field, the entities
#  - the commands of tsx-setup-helper for the layout editor: layout-save,
#    ha-token-set, ha-token-clear and ha-entities
#  - tsx-ha-entities against a small fake Home Assistant: the request, the
#    list file, the errors, the time limit and the redirect rule
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1   # the test imports tsx-setupd: no .pyc next to it
. "$(dirname "$0")/lib/board.sh"
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/tests/lib/paths.sh"
SETUPD=$(P usr/local/sbin/tsx-setupd)
HELPER=$(P usr/local/sbin/tsx-setup-helper)
TSXCONFIG=$(P usr/local/sbin/tsx-config)
HAPLUGIN=$(P usr/local/share/tsx/setup.d/ha.py)
CHECK=$(P usr/local/bin/tsx-layout-check)
HAENT=$(P usr/local/bin/tsx-ha-entities)
ICONS=$(P usr/local/share/tsx/panel-app/icons.txt)
EXAMPLE=$(P usr/local/share/tsx/panel-app/example-layout.json)
PLUGIN=$(P usr/local/share/tsx/setup.d/panel_layout.py)
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED test-panel-editor: no busybox on this host"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIPPED test-panel-editor: no python3 on this host"; exit 0; }

T=$(mktemp -d)
SETUPD_PID= HELPER_PID= FAKEHA_PID=
cleanup() {
	[ -n "$FAKEHA_PID" ] && kill "$FAKEHA_PID" 2>/dev/null
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
cat > "$T/bin/tsx-layout-check" <<EOF
#!/bin/sh
TSX_ICON_FILE="$ICONS" exec python3 "$CHECK" "\$@"
EOF
chmod +x "$T/bin/tsx-config" "$T/bin/rc-service" "$T/bin/tsx-layout-check"
ln -s "$HAPLUGIN" "$T/plugins/ha.py"
ln -s "$PLUGIN" "$T/plugins/panel_layout.py"
# the files of the layout editor (all in temporary folders)
EV="$T/e2e"
LAYOUT_USER="$EV/var/panel-layout.json"; LAYOUT_BOARD="$EV/etc/panel-layout.json"
APP_ENT="$EV/run/entities.json"; HA_ENT="$EV/run/ha-entities.json"; HA_TOKEN="$EV/var/panel-app/ha-token"
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
	TSX_PANEL_LAYOUT_FILE="$LAYOUT_USER" TSX_LAYOUT_CHECK_BIN="$T/bin/tsx-layout-check" \
	TSX_HA_TOKEN_FILE="$HA_TOKEN" TSX_HA_ENTITIES_FILE="$HA_ENT" TSX_HA_ENTITIES_BIN="$HAENT" \
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
		TSX_PANEL_LAYOUT_FILE="$LAYOUT_USER" TSX_PANEL_LAYOUT_BOARD="$LAYOUT_BOARD" TSX_PANEL_LAYOUT_EXAMPLE="$EXAMPLE" \
		TSX_LAYOUT_CHECK_BIN="$CHECK" TSX_ICON_FILE="$ICONS" TSX_PANEL_APP_ENTITIES="$APP_ENT" \
		TSX_HA_ENTITIES_FILE="$HA_ENT" TSX_HA_TOKEN_FILE="$HA_TOKEN" \
		TSX_VOICE_SERVICE="$T/voice-service" "$@" \
		python3 "$SETUPD" > "$log" 2>&1 &
	SETUPD_PID=$!
	for _ in $(seq 1 50); do grep -q "listening on" "$log" 2>/dev/null && return 0; sleep 0.1; done
	return 1
}
stop_setupd() { kill "$SETUPD_PID" 2>/dev/null; wait "$SETUPD_PID" 2>/dev/null; SETUPD_PID=; }
loopback_only() { listens_on 127.0.0.1 && ! listens_on 0.0.0.0; }
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

# ==== 2. tsx-setup-helper: layout-save =============================================
# A helper that handles one request, with its own FIFOs and its own folders.
#   hcall [VAR=value...] -- LINE    prints the reply
hcall() {
	local d envs=() line
	d=$(mktemp -d -p "$T" hcall.XXXXXX)
	while [ "$1" != -- ]; do envs+=("$1"); shift; done
	shift; line=$1
	env "${envs[@]}" PATH="$T/bin:$PATH" TSX_RUN_DIR="$d" TSX_SETUP_HELPER_REQ="$d/req" TSX_SETUP_HELPER_RESP="$d/resp" \
		TSX_CONFIG_BIN="$T/bin/tsx-config" TSX_CONF="$CONF" TSX_SETUP_HELPER_ONESHOT=1 \
		busybox sh "$HELPER" > "$d/log" 2>&1 &
	local pid=$!
	for _ in $(seq 1 100); do grep -q 'listening on' "$d/log" 2>/dev/null && break; sleep 0.05; done
	# A FIFO loses its data when the last process closes it, and a helper in
	# the mode ONESHOT exits at once. So this shell holds the reply FIFO open.
	local reply=
	exec 9<>"$d/resp"
	printf '%s\n' "$line" > "$d/req"
	IFS= read -r -t 30 reply <&9
	exec 9<&-
	printf '%s\n' "$reply"
	wait "$pid" 2>/dev/null
	cat "$d/log" >> "$T/hcall.log"
}
GOODLAYOUT='{"version": 1, "pages": [{"name": "A", "cards": [{"type": "clock"}]}]}'
LV="$T/var/panel-layout.json"
HV=(TSX_SETUP_STATE_DIR="$T/state2" TSX_PANEL_LAYOUT_FILE="$LV" TSX_LAYOUT_CHECK_BIN="$T/bin/tsx-layout-check")
mkdir -p "$T/state2"
echo "== tsx-setup-helper: layout-save =="
printf '%s\n' "$GOODLAYOUT" > "$T/state2/layout.new"
r=$(hcall "${HV[@]}" -- "layout-save")
[ "$r" = ok ] && [ "$(cat "$LV")" = "$GOODLAYOUT" ] && ok "layout-save installs a good layout" || bad "layout-save: '$r' / $(cat "$LV" 2>&1)"
[ "$(stat -c %a "$LV")" = 644 ] && ok "the installed layout has mode 644" || bad "layout mode"
[ ! -e "$T/state2/layout.new" ] && ok "layout-save removes layout.new" || bad "layout.new stays"
printf '{"version": 1, "pages": [{"cards": [{"type": "fan"}]}]}\n' > "$T/state2/layout.new"
r=$(hcall "${HV[@]}" -- "layout-save")
[ "$r" = 'err page 1 card 1: unknown type "fan"' ] && [ "$(cat "$LV")" = "$GOODLAYOUT" ] && ok "a layout with an error: err with the first error line, the layout stays" || bad "bad layout: '$r'"
ln -sf "$T/panel.conf" "$T/state2/layout.new"
r=$(hcall "${HV[@]}" -- "layout-save")
case "$r" in err*) [ "$(cat "$LV")" = "$GOODLAYOUT" ] && ok "a link as layout.new is refused: $r";; *) bad "link: '$r'";; esac
rm -f "$T/state2/layout.new"
r=$(hcall "${HV[@]}" -- "layout-save")
case "$r" in err*) ok "no layout.new: $r";; *) bad "no layout.new: '$r'";; esac
r=$(hcall "${HV[@]}" TSX_LAYOUT_CHECK_BIN="$T/bin/not-installed" -- "layout-save")
[ "$r" = "err no panel app on this panel" ] && ok "no tsx-layout-check: err no panel app on this panel" || bad "no checker: '$r'"
r=$(hcall "${HV[@]}" -- "layout-save now")
case "$r" in err*) ok "layout-save with an argument is refused";; *) bad "argument: '$r'";; esac
r=$(hcall "${HV[@]}" -- "#t5 layout-save")
case "$r" in "#t5 err"*) ok "a tagged request gets a tagged reply";; *) bad "tag: '$r'";; esac

# ==== 3. a fake Home Assistant, the token commands, tsx-ha-entities =================
cat > "$T/fakeha.py" <<'PYEOF'
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
TOKEN = sys.argv[2]
STATES = [
    {"entity_id": "light.kitchen", "state": "on", "attributes": {"friendly_name": "Kitchen", "brightness": 200}},
    {"entity_id": "sensor.temp", "state": "21.5", "attributes": {"friendly_name": "Temperature", "unit_of_measurement": "C"}},
    {"entity_id": "switch.plain", "state": "off", "attributes": {}},
    {"entity_id": "Bad Id", "state": "x", "attributes": {}},
    "not a state",
]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, body, extra=None):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        for k, v in (extra or {}).items(): self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        try:
            self.end_headers(); self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass    # the client gave up (the test of the time limit)
    def do_GET(self):
        auth = self.headers.get("Authorization", "")
        with open(sys.argv[3], "a") as f: f.write("%s %s\n" % (self.path, "token" if auth == "Bearer " + TOKEN else "no-token"))
        base = self.path[:-len("/api/states")] if self.path.endswith("/api/states") else None
        if base is None: return self._send(404, {})
        port = self.server.server_address[1]
        if base == "/redir":    return self._send(302, b"", {"Location": "http://127.0.0.1:%d/api/states" % port})
        if base == "/evil":     return self._send(302, b"", {"Location": "http://localhost:%d/api/states" % port})
        if base == "/scheme":   return self._send(302, b"", {"Location": "https://127.0.0.1:%d/api/states" % port})
        if base == "/slow":     time.sleep(4); return self._send(200, STATES)
        if base == "/broken":   return self._send(200, b"this is not json")
        if base == "/error":    return self._send(500, {})
        if auth != "Bearer " + TOKEN: return self._send(401, {"message": "401: Unauthorized"})
        return self._send(200, STATES)
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_address[1]))
srv.serve_forever()
PYEOF
HATOKEN="eyJhbGciOiJIUzI1NiJ9.TESTtokenTESTtoken0123456789.sig_part-end"
python3 "$T/fakeha.py" "$T/fakeha.port" "$HATOKEN" "$T/fakeha.log" &
FAKEHA_PID=$!
for _ in $(seq 1 50); do [ -s "$T/fakeha.port" ] && break; sleep 0.1; done
HAPORT=$(cat "$T/fakeha.port")
HAURL="http://127.0.0.1:$HAPORT"
TF="$T/lib/panel-app/ha-token"
EF="$T/run/panel-app/ha-entities.json"
HH=(TSX_HA_TOKEN_FILE="$TF" TSX_HA_ENTITIES_FILE="$EF" TSX_HA_ENTITIES_BIN="$HAENT")
echo "== tsx-setup-helper: ha-token-set, ha-entities, ha-token-clear =="
r=$(hcall "${HH[@]}" -- "ha-entities")
[ "$r" = "err no token is stored" ] && ok "ha-entities with no token: err no token is stored" || bad "no token: '$r'"
r=$(hcall "${HH[@]}" -- "ha-token-set ftp://x $HATOKEN"); case "$r" in err*) ok "a URL that is not http or https is refused";; *) bad "ftp URL: '$r'";; esac
r=$(hcall "${HH[@]}" -- "ha-token-set $HAURL short"); case "$r" in err*) ok "a token that is too short is refused";; *) bad "short token: '$r'";; esac
r=$(hcall "${HH[@]}" -- 'ha-token-set '"$HAURL"' bad$(id)token12345'); case "$r" in err*) ok "a token with a shell character is refused";; *) bad "shell token: '$r'";; esac
r=$(hcall "${HH[@]}" -- "ha-token-set $HAURL"); case "$r" in err*) ok "a request with no token is refused";; *) bad "no token word: '$r'";; esac
[ ! -e "$TF" ] && ok "none of the refused requests wrote the token file" || bad "token file exists"
r=$(hcall "${HH[@]}" -- "ha-token-set $HAURL $HATOKEN")
[ "$r" = ok ] && ok "ha-token-set stores the URL and the token" || bad "ha-token-set: '$r'"
[ "$(stat -c %a "$TF")" = 600 ] && [ "$(sed -n 1p "$TF")" = "$HAURL" ] && [ "$(sed -n 2p "$TF")" = "$HATOKEN" ] && [ "$(wc -l < "$TF")" = 2 ] \
	&& ok "the file has mode 600 and two lines: the URL, the token" || bad "token file: $(stat -c %a "$TF") $(wc -l < "$TF")"
ls "$T/lib/panel-app" | grep -q tmp && bad "a temporary file stays" || ok "no temporary file stays"
grep -qF "$HATOKEN" "$T/hcall.log" && bad "the token is in the log of the helper" || ok "the token is not in the log of the helper"
case "$r" in *"$HATOKEN"*) bad "the token is in the reply";; *) ok "the token is not in the reply";; esac
r=$(hcall "${HH[@]}" -- "ha-entities")
[ "$r" = "ok 3" ] && ok "ha-entities reads the list from Home Assistant: ok 3" || bad "ha-entities: '$r'"
[ "$(stat -c %a "$EF")" = 640 ] && ok "ha-entities.json has mode 640" || bad "list mode: $(stat -c %a "$EF")"
python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
assert d == [{"entity_id": "light.kitchen", "name": "Kitchen", "state": "on"},
             {"entity_id": "sensor.temp", "name": "Temperature", "state": "21.5"},
             {"entity_id": "switch.plain", "name": "", "state": "off"}], d' "$EF" && ok "the list has entity_id, name and state, sorted, and leaves out a bad entry" || bad "list content: $(cat "$EF")"
grep -qF "$HATOKEN" "$EF" && bad "the token is in the list file" || ok "the token is not in the list file"
grep -qF "$HATOKEN" "$T/hcall.log" && bad "the token is in the log of the helper after ha-entities" || ok "the token is still not in the log of the helper"
grep -q '^/api/states token$' "$T/fakeha.log" && ok "Home Assistant got GET /api/states with the bearer token" || bad "fake HA log: $(cat "$T/fakeha.log")"
r=$(hcall "${HH[@]}" TSX_HA_ENTITIES_BIN="$T/bin/not-installed" -- "ha-entities"); [ "$r" = "err no panel app on this panel" ] && ok "no tsx-ha-entities: err no panel app on this panel" || bad "no tool: '$r'"
r=$(hcall "${HH[@]}" -- "ha-token-clear")
[ "$r" = ok ] && [ ! -e "$TF" ] && [ ! -e "$EF" ] && ok "ha-token-clear removes the token and the list" || bad "clear: '$r'"
r=$(hcall "${HH[@]}" -- "ha-token-clear now"); case "$r" in err*) ok "ha-token-clear with an argument is refused";; *) bad "clear arg: '$r'";; esac
r=$(hcall "${HH[@]}" -- "ha-token-set $HAURL wrongtoken_wrongtoken"); r=$(hcall "${HH[@]}" -- "ha-entities")
[ "$r" = "err Home Assistant refused the token (HTTP 401)" ] && ok "a token that Home Assistant refuses: err Home Assistant refused the token (HTTP 401)" || bad "401: '$r'"
[ ! -e "$EF" ] && ok "a failed read leaves no list file" || bad "list file after 401"
r=$(hcall "${HH[@]}" -- "ha-token-clear")

echo "== tsx-ha-entities =="
run_ent() {  # run_ent PATH [VAR=value...]: the tool with the URL HAURL+PATH
	local path=$1; shift
	printf '%s%s\n%s\n' "$HAURL" "$path" "$HATOKEN" > "$T/tok"
	env TSX_HA_TOKEN_FILE="$T/tok" TSX_HA_ENTITIES_FILE="$T/out/list.json" "$@" python3 "$HAENT" 2>&1
}
rm -rf "$T/out"
out=$(run_ent ""); [ "$out" = 3 ] && [ -s "$T/out/list.json" ] && ok "the tool prints the count and makes the folder of the list" || bad "tool: '$out'"
rm -f "$T/out/list.json"
out=$(run_ent "/redir"); [ "$out" = 3 ] && ok "a redirect to the same scheme, host and port is followed" || bad "redirect same origin: '$out'"
rm -f "$T/out/list.json"
: > "$T/fakeha.log"
out=$(run_ent "/evil"); case "$out" in *"redirect"*) ok "a redirect to another host is refused: $out";; *) bad "redirect other host: '$out'";; esac
out=$(run_ent "/scheme"); case "$out" in *"redirect"*) ok "a redirect to another scheme is refused: $out";; *) bad "redirect other scheme: '$out'";; esac
grep -q '^/api/states ' "$T/fakeha.log" && bad "the token went to the target of a redirect" || ok "the target of a refused redirect never got a request"
[ ! -e "$T/out/list.json" ] && ok "a refused request leaves no list" || bad "list after refusal"
out=$(run_ent "/slow" TSX_HA_ENTITIES_TIMEOUT=1); case "$out" in *"did not answer"*) ok "a slow Home Assistant: $out";; *) bad "timeout: '$out'";; esac
out=$(run_ent "/broken"); case "$out" in "cannot read the list"*) ok "an answer that is not JSON: $out";; *) bad "broken: '$out'";; esac
out=$(run_ent "/error"); [ "$out" = "Home Assistant answered HTTP 500" ] && ok "HTTP 500: $out" || bad "500: '$out'"
printf 'http://127.0.0.1:1\n%s\n' "$HATOKEN" > "$T/tok"
out=$(env TSX_HA_TOKEN_FILE="$T/tok" TSX_HA_ENTITIES_FILE="$T/out/list.json" python3 "$HAENT" 2>&1); case "$out" in *"connection refused"*) ok "nothing at the address: $out";; *) bad "refused: '$out'";; esac
rm -f "$T/tok"
out=$(env TSX_HA_TOKEN_FILE="$T/tok" TSX_HA_ENTITIES_FILE="$T/out/list.json" python3 "$HAENT" 2>&1); [ "$out" = "no URL and token are stored" ] && ok "no token file: $out" || bad "no file: '$out'"
MYGROUP=$(id -gn)
out=$(run_ent "" TSX_SETUP_GROUP="$MYGROUP"); [ "$(stat -c %G "$T/out/list.json")" = "$MYGROUP" ] && ok "the list file gets the group TSX_SETUP_GROUP" || bad "group: $(stat -c %G "$T/out/list.json")"
python3 "$HAENT" extra >/dev/null 2>&1; [ $? = 2 ] && ok "an argument is a usage error (exit 2)" || bad "usage"

# ==== 4. the editor: the plugin, the page and the API ===============================
# pyok FILE EXPRESSION: true when the expression is true for d, the JSON of FILE
pyok() { python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); sys.exit(0 if eval(sys.argv[2]) else 1)' "$@" 2>/dev/null; }
# apipost PATH JSON [--source IP --cookie C]: prints the status; the body is in $T/r.json
api() {
	local out; out=$(call "$@"); body_of "$out" > "$T/r.json"; status_of "$out"
}
sha_of() { sha256sum "$1" | cut -d' ' -f1; }
echo "== the editor plugin: the link, the API encryption key, the page =="
stop_setupd
start_setupd "$T/setupd4.log" TSX_SETUP_KIOSK=off || { echo "FAIL: tsx-setupd did not start"; cat "$T/setupd4.log"; exit 1; }
page=$(body_of "$(call GET /setup)")
case "$page" in *'href="/setup/layout"'*) ok "the setup page has the link to the editor";; *) bad "no link to the editor";; esac
case "$page" in *'name="HA_API_KEY"'*'id="apikey-new"'*) ok "the setup page has the API encryption key field and the button to make a key";; *) bad "no API key field";; esac
case "$page" in *'@@'*|*'SLOT'*) bad "a slot is left";; *) ok "every slot is filled";; esac
APIKEY=$(python3 -c 'import base64, os; print(base64.b64encode(os.urandom(32)).decode())')
out=$(submit "{\"HA_API_KEY\":\"$APIKEY\"}")
[ "$(status_of "$out")" = 200 ] && [ "$(TSX_CONF="$CONF" busybox sh "$TSXCONFIG" get HA_API_KEY)" = "$APIKEY" ] && ok "a save writes HA_API_KEY to panel.conf" || bad "HA_API_KEY save: $out"
out=$(call GET /setup/api/state); body=$(body_of "$out")
[ "$(jget fields.HA_API_KEY__set <<<"$body")" = True ] && [ "$(jget fields.HA_API_KEY <<<"$body")" = "" ] && ok "the state API says that the key is set and gives no value" || bad "state HA_API_KEY: $(jget fields <<<"$body")"
printf '%s' "$body" | grep -qF "$APIKEY" && bad "the state API gives the key" || ok "the key is not in the state API"
grep -qF "$APIKEY" "$T/setupd4.log" "$T/helper.log" && bad "the key is in a log" || ok "the key is in no log"
out=$(submit '{"HA_API_KEY":"not a key"}')
[ "$(status_of "$out")" = 400 ] && [ "$(jget errors.HA_API_KEY <<<"$(body_of "$out")")" != "" ] && ok "a key with a wrong format is refused" || bad "bad key: $out"
out=$(submit '{"HA_API_KEY":""}')
[ "$(status_of "$out")" = 200 ] && [ "$(TSX_CONF="$CONF" busybox sh "$TSXCONFIG" get HA_API_KEY)" = "$APIKEY" ] && ok "an empty field keeps the key" || bad "empty key: $out"
mkdir -p "$T/plugins-other"
printf 'NAME = "other"\nSIMPLE_KEYS = ["HA_API_KEY"]\nHTML = {"panel": "<input name=\\"HA_API_KEY\\">"}\n' > "$T/plugins-other/other.py"
ln -s "$(dirname "$(P usr/local/share/tsx/setup.d/panel_layout.py)")/panel_layout.py" "$T/plugins-other/panel_layout.py"
r=$(env TSX_SETUP_PLUGIN_DIR="$T/plugins-other" TSX_SETUP_CONF="$T/setup.conf" TSX_RUN_DIR="$T/ic-run" python3 -c 'import sys, importlib.machinery as m
d = m.SourceFileLoader("setupd", sys.argv[1]).load_module()
print(d.SIMPLE_KEYS.count("HA_API_KEY"), "apikey-new" in d.PAGE, "/setup/layout" in d.PAGE)' "$SETUPD" 2>&1)
[ "$r" = "1 False True" ] && ok "another plugin that names HA_API_KEY keeps the key: the editor plugin adds the link only" || bad "key owner: $r"

echo "== the editor page =="
out=$(call GET /setup/layout); page=$(body_of "$out")
[ "$(status_of "$out")" = 200 ] && ok "GET /setup/layout 200 on loopback" || bad "editor page: $(status_of "$out")"
case "$page" in *'<title>Panel layout</title>'*'function load()'*) ok "it is the editor page with its script";; *) bad "editor page content";; esac
printf '%s' "$page" | grep -Eq '(src|href|action)="(https?:)?//|@import|url\(' && bad "the editor page loads something from outside: $(printf '%s' "$page" | grep -Eo '(src|href|action)="(https?:)?//[^"]*' | head -3)" || ok "the editor page has no external file, font or script"
case "$page" in *'name="viewport"'*'max-width:420px'*) ok "the page has the viewport tag and a rule for a phone";; *) bad "no viewport rule";; esac

echo "== GET /setup/api/layout: user, board and none =="
rm -f "$LAYOUT_USER" "$LAYOUT_BOARD" "$APP_ENT" "$HA_ENT"
mkdir -p "$EV/var" "$EV/etc" "$EV/run"
st=$(api GET /setup/api/layout)
[ "$st" = 200 ] && pyok "$T/r.json" 'd["source"] == "none" and d["revision"] == "" and d["layout"] == json.load(open(sys.argv[3]))' "$EXAMPLE" && ok "no file: the example layout, source none, no revision" || bad "none: $st $(head -c 300 "$T/r.json")"
pyok "$T/r.json" 'sorted(d) == sorted("layout source revision icons types domains type_keys theme_keys limits defaults entities ha_token_set checker".split())' && ok "the answer has the layout and what the editor needs" || bad "keys of the answer: $(jkeys < "$T/r.json")"
python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
names = [l.split()[0] for l in open(sys.argv[2]) if l.strip() and not l.startswith("#")]
assert d["icons"] == sorted(names), d["icons"]
assert d["types"] == ["light", "switch", "scene", "script", "sensor", "weather", "clock"]
assert d["domains"]["light"] == "light" and "switch" not in d["domains"]
assert d["limits"]["max_pages"] == 16 and d["limits"]["max_cards"] == 48 and d["limits"]["max_file_bytes"] == 65536
assert d["theme_keys"] == ["background", "card", "card_on", "text", "text_dim"]
assert d["defaults"]["grid"] == {"columns": 4, "rows": 3, "gap": 10} and d["checker"] is True and d["ha_token_set"] is False' "$T/r.json" "$ICONS" && ok "icons.txt, the types, the limits and the defaults are in the answer" || bad "answer details"
echo '{"version": 1, "pages": [{"name": "Board", "cards": []}]}' > "$LAYOUT_BOARD"
st=$(api GET /setup/api/layout)
pyok "$T/r.json" 'd["source"] == "board" and d["revision"] == "" and d["layout"]["pages"][0]["name"] == "Board"' && ok "the default layout of the board: source board, no revision" || bad "board: $(head -c 300 "$T/r.json")"
printf '%s\n' '{"version": 1, "pages": [{"name": "Mine", "cards": [{"type": "switch", "entity_id": "switch.coffee"}]}]}' > "$LAYOUT_USER"
st=$(api GET /setup/api/layout)
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d["source"] == "user" and d["layout"]["pages"][0]["name"] == "Mine" and d["revision"] == sys.argv[2]' "$T/r.json" "$(sha_of "$LAYOUT_USER")" && ok "the file of the user wins: source user, the revision is the sha256 of the bytes" || bad "user: $(head -c 300 "$T/r.json")"
printf '{"version": 1, "pages": [' > "$LAYOUT_USER"
st=$(api GET /setup/api/layout)
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d["layout"] is None and d["source"] == "user" and d["text"] == "{\"version\": 1, \"pages\": [" and d["revision"] == sys.argv[2]' "$T/r.json" "$(sha_of "$LAYOUT_USER")" && ok "a file that does not parse: layout null, the raw text, the revision of the bytes" || bad "broken: $(head -c 300 "$T/r.json")"
printf '[1, 2]' > "$LAYOUT_USER"
st=$(api GET /setup/api/layout)
pyok "$T/r.json" 'd["layout"] is None and d["text"] == "[1, 2]"' && ok "JSON that is not an object: layout null, the text" || bad "array: $(head -c 300 "$T/r.json")"

echo "== the entities for the picker =="
printf '%s\n' '{"version": 1, "pages": [{"cards": [{"type": "switch", "entity_id": "switch.coffee"}, {"type": "light", "entity_id": "light.kitchen"}]}]}' > "$LAYOUT_USER"
st=$(api GET /setup/api/layout)
pyok "$T/r.json" '[e["entity_id"] for e in d["entities"]] == ["light.kitchen", "switch.coffee"] and all(e["source"] == "layout" for e in d["entities"])' && ok "no list of the app: the entities of the layout" || bad "entities (layout): $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["entities"])' "$T/r.json")"
printf '%s\n' '{"uptime": 12, "entities": [{"entity_id": "light.kitchen", "name": "Kitchen", "state": "on"}, {"entity_id": "BAD ID", "name": "x", "state": "y"}, {"entity_id": "sensor.t", "name": "Temp", "state": "21"}]}' > "$APP_ENT"
printf '%s\n' '[{"entity_id": "light.kitchen", "name": "Kitchen (HA)", "state": "off"}, {"entity_id": "sensor.t", "name": "", "state": "20"}, {"entity_id": "fan.bedroom", "name": "Fan", "state": "on"}, 5]' > "$HA_ENT"
st=$(api GET /setup/api/layout/entities)
python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
e = {x["entity_id"]: x for x in d["entities"]}
assert sorted(e) == ["fan.bedroom", "light.kitchen", "sensor.t", "switch.coffee"], sorted(e)
assert e["light.kitchen"] == {"entity_id": "light.kitchen", "name": "Kitchen", "state": "on", "source": "app"}, e["light.kitchen"]
assert e["sensor.t"]["name"] == "Temp" and e["sensor.t"]["state"] == "21" and e["sensor.t"]["source"] == "app"
assert e["fan.bedroom"]["source"] == "ha" and e["switch.coffee"]["source"] == "layout"
assert [x["entity_id"] for x in d["entities"]] == sorted(e)
assert d["ha_token_set"] is False' "$T/r.json" && ok "the lists merge: the app wins the state, the full list adds entities, a bad entry is left out" || bad "entities (merge): $(cat "$T/r.json")"
rm -f "$APP_ENT"
st=$(api GET /setup/api/layout/entities)
pyok "$T/r.json" '{e["entity_id"]: e["source"] for e in d["entities"]}["light.kitchen"] == "ha"' && ok "without the list of the app, the full list gives the entity" || bad "entities (ha): $(cat "$T/r.json")"
rm -f "$HA_ENT"

echo "== POST /setup/api/layout/check =="
st=$(api POST /setup/api/layout/check --data "{\"layout\": $(cat "$EXAMPLE")}")
python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
assert d["ok"] is True and d["errors"] == [] and d["warnings"] == [], d
p = d["placed"]
assert [x["name"] for x in p] == ["Home", "Outside"] and p[0]["columns"] == 4 and p[1]["columns"] == 3 and p[1]["rows"] == 2
assert p[0]["cards"][0] == {"index": 0, "x": 0, "y": 0, "w": 2, "h": 1}, p[0]["cards"][0]
assert len(p[0]["cards"]) == 10 and p[1]["cards"][3] == {"index": 3, "x": 0, "y": 1, "w": 3, "h": 1}, p[1]["cards"]' "$T/r.json" && ok "a good layout: ok, no error, and the cells of the cards as the app places them" || bad "check (good): $st $(head -c 400 "$T/r.json")"
BADL='{"version": 1, "pages": [{"cards": [{"type": "clock"}, {"type": "light", "entity_id": "switch.a"}, {"type": "clock", "colour": 1}, {"type": "light", "entity_id": "light.a", "icon": "mdi:no-such-icon"}]}]}'
st=$(api POST /setup/api/layout/check --data "{\"layout\": $BADL}")
python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
assert d["ok"] is False and any(e.startswith("page 1 card 2:") and "needs a light entity" in e for e in d["errors"]), d["errors"]
assert any("unknown key" in w for w in d["warnings"]) and any("icon mdi:no-such-icon" in w for w in d["warnings"]), d["warnings"]
assert [c["index"] for c in d["placed"][0]["cards"]] == [0, 2, 3], d["placed"]
assert [(c["x"], c["y"]) for c in d["placed"][0]["cards"]] == [(0, 0), (1, 0), (2, 0)], d["placed"]' "$T/r.json" && ok "a bad layout: the errors, the warnings, and the places of the cards that are left (the index follows the list)" || bad "check (bad): $(cat "$T/r.json")"
st=$(api POST /setup/api/layout/check --data '{"layout": {"version": 2}}')
pyok "$T/r.json" 'd["ok"] is False and d["placed"] == [] and "version" in d["errors"][0]' && ok "a layout that cannot be used: the error, no places" || bad "check (version): $(cat "$T/r.json")"
st=$(api POST /setup/api/layout/check --data '{"layout": [1]}'); [ "$st" = 400 ] && ok "a layout that is not an object: 400" || bad "check (array): $st"
st=$(api POST /setup/api/layout/check --data '{}'); [ "$st" = 400 ] && ok "no layout: 400" || bad "check (none): $st"

echo "== POST /setup/api/layout/save =="
rm -f "$LAYOUT_USER"
REV0=$(body_of "$(call GET /setup/api/layout)" | jget revision)
[ -z "$REV0" ] && ok "no file of the user: the revision is empty" || bad "revision without a file: $REV0"
L1='{"pages": [{"name": "Zed", "cards": [{"entity_id": "light.a", "type": "light", "label": "Ünï"}]}], "version": 1, "keys": {"up": "next_page", "home": "setup"}}'
st=$(api POST /setup/api/layout/save --data "{\"layout\": $L1, \"revision\": \"$REV0\"}")
[ "$st" = 200 ] && python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d["ok"] is True and d["revision"] == sys.argv[2], d' "$T/r.json" "$(sha_of "$LAYOUT_USER")" && ok "a save through the helper: ok, and the new revision is the sha256 of the file" || bad "save: $st $(cat "$T/r.json")"
python3 - "$LAYOUT_USER" "$L1" <<'PYEOF' && ok "the file is the JSON with 2 spaces, UTF-8, in the order of the editor, with a final newline" || bad "layout file: $(cat "$LAYOUT_USER")"
import json, sys
text = open(sys.argv[1], encoding="utf-8").read()
want = json.dumps(json.loads(sys.argv[2]), indent=2, ensure_ascii=False) + "\n"
assert text == want, text
assert text.index('"pages"') < text.index('"version"') and text.index('"up"') < text.index('"home"')
assert "Ünï" in text
PYEOF
[ "$(stat -c %a "$LAYOUT_USER")" = 644 ] && ok "the installed file has mode 644" || bad "layout mode: $(stat -c %a "$LAYOUT_USER")"
[ ! -e "$T/state/layout.new" ] && ls -a "$T/state" | grep -q 'layout' && bad "a layout file stays in the state folder: $(ls -a "$T/state")" || ok "no layout.new stays in the state folder"
REV1=$(sha_of "$LAYOUT_USER"); cp "$LAYOUT_USER" "$T/layout.before"
st=$(api POST /setup/api/layout/save --data "{\"layout\": $(cat "$EXAMPLE"), \"revision\": \"$REV0\"}")
[ "$st" = 409 ] && pyok "$T/r.json" 'd["stale"] is True and "Reload" in d["error"]' && cmp -s "$T/layout.before" "$LAYOUT_USER" && ok "a stale revision: 409, the file stays" || bad "stale: $st $(cat "$T/r.json")"
st=$(api POST /setup/api/layout/save --data "{\"layout\": $BADL, \"revision\": \"$REV1\"}")
pyok "$T/r.json" 'any("needs a light entity" in e for e in d["errors"])' && [ "$st" = 400 ] && cmp -s "$T/layout.before" "$LAYOUT_USER" && ok "a layout with an error: 400 with the errors, the file stays" || bad "save (bad): $st $(cat "$T/r.json")"
st=$(api POST /setup/api/layout/save --data "{\"layout\": $L1}"); [ "$st" = 400 ] && ok "a save with no revision: 400" || bad "no revision: $st"
st=$(api POST /setup/api/layout/save --data "{\"revision\": \"$REV1\"}"); [ "$st" = 400 ] && ok "a save with no layout: 400" || bad "no layout: $st"
python3 -c 'import json; print(json.dumps({"layout": {"version": 1, "pages": [{"name": "a" * 70000}]}, "revision": ""}))' > "$T/big.json"
st=$(api POST /setup/api/layout/save --data "$(cat "$T/big.json")"); [ "$st" = 413 ] && cmp -s "$T/layout.before" "$LAYOUT_USER" && ok "a body of more than 64 KB: 413, the file stays" || bad "big body: $st"
st=$(api POST /setup/api/layout/save --data "{\"layout\": $(cat "$EXAMPLE"), \"revision\": \"$REV1\"}")
[ "$st" = 200 ] && ok "a save with the current revision works" || bad "save 2: $st $(cat "$T/r.json")"
st=$(api GET /setup/api/layout)
[ "$st" = 200 ] && python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d["source"] == "user" and d["layout"]["pages"][0]["name"] == "Home" and d["revision"] == sys.argv[2]' "$T/r.json" "$(sha_of "$LAYOUT_USER")" && ok "the editor reads the saved layout back" || bad "read back"
grep -c 'layout-save' "$T/helper.log" | grep -q '^2$' && ok "each good save asked the helper once (layout-save)" || bad "layout-save count: $(grep -c 'layout-save' "$T/helper.log")"

echo "== the editor needs the same authorization as the setup page =="
if [ -n "$LANIP" ]; then
	PATH="$T/bin:$PATH" TSX_CONF="$CONF" TSX_RUN="$RUNBASE" TSX_APPLY_ALLOW_NONROOT=1 busybox sh "$TSXCONFIG" setup >/dev/null 2>&1
	wait_for 15 listens_on 0.0.0.0 || bad "no LAN listener for the window"
	cp "$LAYOUT_USER" "$T/layout.before"
	out=$(call GET /setup/layout --source "$LANIP"); [ "$(status_of "$out")" = 200 ] && ok "a LAN client gets the editor page (the page shows the pairing gate)" || bad "LAN page: $(status_of "$out")"
	out=$(call GET /setup/api/layout --source "$LANIP"); body=$(body_of "$out")
	[ "$(status_of "$out")" = 200 ] && [ "$(jget need_pairing <<<"$body")" = True ] && [ "$(jkeys <<<"$body")" = need_pairing ] && ok "without pairing the layout API says need_pairing and nothing else" || bad "LAN layout: $out"
	for ep in "POST /setup/api/layout/check" "POST /setup/api/layout/save" "POST /setup/api/layout/ha-token" "POST /setup/api/layout/ha-token-clear" "POST /setup/api/layout/ha-entities" "GET /setup/api/layout/entities"; do
		set -- $ep
		out=$(call "$1" "$2" --source "$LANIP" --data '{"layout": {"version": 1, "pages": [{}]}, "revision": "x", "url": "http://a.b", "token": "abcdefghijklmnop"}')
		[ "$(status_of "$out")" = 403 ] && ok "$ep needs the pairing (403)" || bad "$ep without pairing: $(status_of "$out")"
	done
	cmp -s "$T/layout.before" "$LAYOUT_USER" && ok "nothing was written without the pairing" || bad "layout changed without the pairing"
	CODE=$(body_of "$(call GET /setup/api/state)" | jget pairing_code)
	out=$(call POST /setup/api/pair --source "$LANIP" --data "{\"code\":\"$CODE\"}"); TOKEN=$(cookie_of "$out")
	[ -n "$TOKEN" ] && ok "pairing works" || bad "pairing: $out"
	out=$(call GET /setup/api/layout --source "$LANIP" --cookie="$TOKEN"); body=$(body_of "$out")
	[ "$(jget source <<<"$body")" = user ] && ok "a paired LAN session reads the layout" || bad "paired layout: $out"
	REVP=$(jget revision <<<"$body")
	out=$(call POST /setup/api/layout/save --source "$LANIP" --cookie="$TOKEN" --data "{\"layout\": $L1, \"revision\": \"$REVP\"}")
	[ "$(status_of "$out")" = 200 ] && ok "a paired LAN session saves" || bad "paired save: $out"
	rm -f "$RUNDIR/setup-open"
	wait_for 20 loopback_only
	out=$(call GET /setup/layout --source "$LANIP"); [ "$(status_of "$out")" = 0 ] && ok "after the window the LAN client cannot connect" || bad "LAN after the window: $(status_of "$out")"
else
	echo "SKIPPED: no non-loopback local address available to simulate a LAN client"
fi

echo "== the list of Home Assistant entities through the editor: the token stays on the panel =="
st=$(api POST /setup/api/layout/ha-entities --data '{}')
[ "$st" = 502 ] && pyok "$T/r.json" 'd["error"] == "no token is stored"' && ok "no token: 502 and the message" || bad "no token: $st $(cat "$T/r.json")"
st=$(api POST /setup/api/layout/ha-token --data "{\"url\": \"ftp://x\", \"token\": \"$HATOKEN\"}"); [ "$st" = 400 ] && ok "a URL that is not http or https: 400" || bad "ftp: $st"
st=$(api POST /setup/api/layout/ha-token --data "{\"url\": \"$HAURL\", \"token\": \"short\"}"); [ "$st" = 400 ] && ok "a token that is too short: 400" || bad "short: $st"
st=$(api POST /setup/api/layout/ha-token --data "{\"url\": \"$HAURL\", \"token\": \"has space in it ok\"}"); [ "$st" = 400 ] && ok "a token with a space: 400" || bad "space: $st"
[ ! -e "$HA_TOKEN" ] && ok "the refused requests stored nothing" || bad "token file after refusals"
: > "$T/fakeha.log"
st=$(api POST /setup/api/layout/ha-token --data "{\"url\": \"$HAURL/\", \"token\": \"$HATOKEN\"}")
[ "$st" = 200 ] && pyok "$T/r.json" 'd == {"ok": True, "ha_token_set": True}' && ok "the token is stored" || bad "ha-token: $st $(cat "$T/r.json")"
grep -qF "$HATOKEN" "$T/r.json" && bad "the answer has the token" || ok "the answer never has the token"
[ "$(sed -n 1p "$HA_TOKEN")" = "$HAURL" ] && [ "$(sed -n 2p "$HA_TOKEN")" = "$HATOKEN" ] && [ "$(stat -c %a "$HA_TOKEN")" = 600 ] && ok "the helper wrote the file: URL without the last slash, token, mode 600" || bad "token file: $(cat "$HA_TOKEN")"
st=$(api POST /setup/api/layout/ha-entities --data '{}')
[ "$st" = 200 ] && pyok "$T/r.json" 'd == {"ok": True, "count": 3}' && ok "the list is read: 3 entities" || bad "ha-entities: $st $(cat "$T/r.json")"
st=$(api GET /setup/api/layout/entities)
python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
e = {x["entity_id"]: x for x in d["entities"]}
assert "light.kitchen" in e and e["light.kitchen"]["name"] == "Kitchen" and e["light.kitchen"]["source"] == "ha", d
assert d["ha_token_set"] is True' "$T/r.json" && ok "the editor gets the entities, and only the fact that a token is stored" || bad "entities after: $(cat "$T/r.json")"
for f in "$T/r.json" "$T/setupd4.log" "$T/helper.log"; do grep -qF "$HATOKEN" "$f" && bad "the token is in $f"; done; ok "the token is in no answer and in no log (checked: the last answer, the logs of both daemons)"
body_of "$(call GET /setup/api/layout)" > "$T/r.json"
pyok "$T/r.json" 'd["ha_token_set"] is True' && ! grep -qF "$HATOKEN" "$T/r.json" && ok "the layout API says: a token is stored" || bad "ha_token_set in layout API"
st=$(api POST /setup/api/layout/ha-token-clear --data '{}')
[ "$st" = 200 ] && pyok "$T/r.json" 'd["ha_token_set"] is False' && [ ! -e "$HA_TOKEN" ] && [ ! -e "$HA_ENT" ] && ok "Remove the token: the token and the list are gone" || bad "clear: $st $(cat "$T/r.json")"

echo "== the plugin without tsx-layout-check =="
stop_setupd
start_setupd "$T/setupd5.log" TSX_SETUP_KIOSK=off TSX_LAYOUT_CHECK_BIN="$T/bin/not-installed" || bad "tsx-setupd did not start"
st=$(api GET /setup/api/layout)
pyok "$T/r.json" 'd["checker"] is False and d["icons"] == [] and d["layout"] is not None' && ok "the layout API still answers, with no checker and no icons" || bad "no checker answer: $(head -c 300 "$T/r.json")"
st=$(api POST /setup/api/layout/check --data '{"layout": {"version": 1, "pages": [{}]}}'); [ "$st" = 503 ] && ok "check: 503" || bad "check without checker: $st"
st=$(api POST /setup/api/layout/save --data "{\"layout\": {\"version\": 1, \"pages\": [{}]}, \"revision\": \"$(sha_of "$LAYOUT_USER")\"}"); [ "$st" = 503 ] && ok "save: 503" || bad "save without checker: $st"

echo "== $N ok, $F failed =="
[ "$F" = 0 ] && echo PASS test-panel-editor || echo FAIL test-panel-editor
exit "$F"
