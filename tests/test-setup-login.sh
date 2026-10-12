#!/bin/bash
# Host test for "Log in with Home Assistant" and the Panel section of the
# setup page (tsx-setupd, docs/setup.md). The scripts are real: tsx-setupd,
# tsx-setup-helper, tsx-config. Home Assistant is tests/fake-ha.py (its auth
# API and its websocket API), tsx-panelctl is a fake that logs. The test
# covers:
#  - the HA URL: none (the pairing code only), the origin of KIOSK_URL, and
#    HA_URL (it wins); the page is on the LAN with no pairing window
#  - the login: the redirect to Home Assistant (client_id = the origin of
#    the page, redirect_uri on the same host), the return, the exchange of
#    the code, the admin check over the websocket API, the revoke of the
#    refresh token, the session cookie (HttpOnly, SameSite=Strict)
#  - a user who is not an administrator is refused, a canceled login, a
#    replayed or foreign return
#  - CSRF: a POST without the token, with a wrong token, from another
#    Origin, from another site, or not as JSON is refused (also on loopback)
#  - a remote save does not restart the kiosk
#  - the list of the sessions, a revoke of one session and of all, a logout
#  - the expiry of a session (idle and absolute)
#  - the rate limit of the login
#  - the Panel section: the controls of `tsx-panelctl state`, each change,
#    the times and the update settings through tsx-config, a panel with no
#    update lines in the state, and the allowlist of the helper command
# No token of Home Assistant may appear in a log or an answer.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
export TSX_SETUP_KIOSK=on
. "$(dirname "$0")/lib/board.sh"
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/tests/lib/paths.sh"
SETUPD=$(P usr/local/sbin/tsx-setupd)
HELPER=$(P usr/local/sbin/tsx-setup-helper)
TSXCONFIG=$(P usr/local/sbin/tsx-config)
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED test-setup-login: no busybox on this host"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIPPED test-setup-login: no python3 on this host"; exit 0; }
LANIP=$(python3 -c "
import socket
try:
	s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
	s.connect(('192.0.2.1', 80))
	print(s.getsockname()[0])
except Exception:
	print('')
" 2>/dev/null)
[ -n "$LANIP" ] && [ "$LANIP" != 127.0.0.1 ] || { echo "SKIPPED test-setup-login: no non-loopback local address"; exit 0; }

T=$(mktemp -d)
PIDS=
cleanup() {
	for p in $PIDS; do kill "$p" 2>/dev/null; done
	[ -n "${KEEP:-}" ] && echo "kept $T" || rm -rf "$T"
}
trap cleanup EXIT
free_port() { python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(('0.0.0.0', 0))
print(s.getsockname()[1])
s.close()
"; }

mkdir -p "$T/run/tsx" "$T/bin" "$T/zoneinfo" "$T/h2" "$T/h3"
CONF="$T/panel.conf"
touch "$T/zoneinfo/UTC"
cat > "$T/bin/tsx-config" <<EOF
#!/bin/sh
exec busybox sh "$TSXCONFIG" "\$@"
EOF
cat > "$T/bin/rc-service" <<EOF
#!/bin/sh
echo "rc-service \$*" >> "$T/rc-service.log"
case "\$2" in status) exit 1;; *) exit 0;; esac
EOF
# tsx-panelctl: "state" prints the controls of a kiosk panel with the
# lights of a panel app, "send" logs the command. The two update lines
# show only when the file update.lines exists.
cat > "$T/bin/tsx-panelctl" <<EOF
#!/bin/sh
case "\$1" in
state) printf 'owner kiosk\nscreen on\nbacklight-pct 40\nblank-timeout 300\nvolume 55\nmute off\nledbar 100 50 0\nkeypad-led 128 unknown\nlights off 40 1 2 3\n'; [ ! -f "$T/update.lines" ] || cat "$T/update.lines";;
send) shift; echo "send \$*" >> "$T/panelctl.log";;
*) exit 2;;
esac
EOF
chmod +x "$T/bin/"*

PORT=$(free_port); PORT2=$(free_port); HAPORT=$(free_port)
printf 'TSX_SETUP_PORT=%s\nTSX_SETUP_LAN=on\nTSX_SETUP_WINDOW=900\n' "$PORT" > "$T/setup.conf"
printf 'TSX_SETUP_PORT=%s\nTSX_SETUP_LAN=on\nTSX_SETUP_WINDOW=900\n' "$PORT2" > "$T/setup2.conf"

start_helper() {  # LOG REQ RESP
	PATH="$T/bin:$PATH" TSX_CONFIG_BIN="$T/bin/tsx-config" TSX_CONF="$CONF" \
	TSX_RUN="$T/run" TSX_RUN_DIR="$T/run/tsx" TSX_APPLY_ALLOW_NONROOT=1 \
	TSX_APPLY_PREFIX="$T/prefix" TSX_STATE_DIR="$T/state" \
	TSX_SETUP_HELPER_REQ="$2" TSX_SETUP_HELPER_RESP="$3" \
	TSX_RCSERVICE_BIN="$T/bin/rc-service" TSX_PANELCTL_BIN="$T/bin/tsx-panelctl" \
		busybox sh "$HELPER" >> "$1" 2>&1 &
	PIDS="$PIDS $!"
	for _ in $(seq 1 100); do grep -q "listening on" "$1" 2>/dev/null && return 0; sleep 0.1; done
	return 1
}
start_setupd() {  # LOG CONF REQ RESP [ENV...]
	local log=$1 conf=$2 req=$3 resp=$4; shift 4
	env "$@" TSX_CONFIG_BIN="$T/bin/tsx-config" TSX_RUN_DIR="$T/run/tsx" TSX_ZONEINFO_DIR="$T/zoneinfo" \
		TSX_SETUP_CONF="$conf" TSX_SETUP_NO_ZEROCONF=1 TSX_KIOSK_CONF="$T/kiosk.conf" TSX_SETUP_STATE_DIR="$T/state-$PORT" \
		TSX_SETUP_HELPER_REQ="$req" TSX_SETUP_HELPER_RESP="$resp" \
		TSX_SETUP_PLUGIN_DIR="$(dirname "$(P usr/local/share/tsx/setup.d/ha.py)")" \
		python3 "$SETUPD" > "$log" 2>&1 &
	PIDS="$PIDS $!"
	for _ in $(seq 1 100); do grep -q "listening on" "$log" 2>/dev/null && return 0; sleep 0.1; done
	return 1
}
start_helper "$T/helper.log" "$T/run/tsx/setup-helper" "$T/run/tsx/setup-helper.resp" || { echo "FAIL: helper"; cat "$T/helper.log"; exit 1; }
start_helper "$T/helper2.log" "$T/h2/req" "$T/h2/resp" || { echo "FAIL: helper 2"; exit 1; }
start_helper "$T/helper3.log" "$T/h3/req" "$T/h3/resp" || { echo "FAIL: helper 3"; exit 1; }
python3 "$HERE/tests/fake-ha.py" "$HAPORT" "$T/ha.log" > "$T/fake-ha.out" 2>&1 &
PIDS="$PIDS $!"
for _ in $(seq 1 50); do grep -q listening "$T/fake-ha.out" 2>/dev/null && break; sleep 0.1; done
start_setupd "$T/setupd.log" "$T/setup.conf" "$T/run/tsx/setup-helper" "$T/run/tsx/setup-helper.resp" \
	TSX_SETUP_SESSION=600 TSX_SETUP_IDLE=600 || { echo "FAIL: tsx-setupd"; cat "$T/setupd.log"; exit 1; }
start_setupd "$T/setupd2.log" "$T/setup2.conf" "$T/h3/req" "$T/h3/resp" \
	TSX_SETUP_SESSION=9 TSX_SETUP_IDLE=5 || { echo "FAIL: tsx-setupd 2"; cat "$T/setupd2.log"; exit 1; }

export T PORT PORT2 HAPORT LANIP CONF
PATH="$T/bin:$PATH" python3 - <<'PYEOF'
import hashlib, http.client, json, os, re, subprocess, sys, time, urllib.parse
T, PORT, PORT2, HAPORT, LANIP, CONF = (os.environ[k] for k in ("T", "PORT", "PORT2", "HAPORT", "LANIP", "CONF"))
PORT, PORT2, HAPORT = int(PORT), int(PORT2), int(HAPORT)
N = F = 0
def ok(cond, text):
    global N, F
    if cond:
        N += 1; print("  ok: " + text)
    else:
        F += 1; print("  FAIL: " + text)

class R:
    def __init__(self, status, headers, body):
        self.status, self.headers, self.body = status, headers, body
        self.cookies = [v for k, v in headers if k.lower() == "set-cookie"]
        self.location = next((v for k, v in headers if k.lower() == "location"), "")
    def json(self):
        try:
            return json.loads(self.body)
        except ValueError:
            return {}
    def cookie(self, name):
        for c in self.cookies:
            if c.startswith(name + "="):
                return c.split(";")[0][len(name) + 1:], c
        return None, None

def req(method, path, port=PORT, source=LANIP, cookies=None, data=None, headers=None, host=None, ctype="application/json"):
    for attempt in range(3):
        try:
            conn = http.client.HTTPConnection(source, port, timeout=120, source_address=(source, 0))
            h = {"Host": host or "%s:%d" % (source, port)}
            if cookies:
                h["Cookie"] = "; ".join("%s=%s" % kv for kv in cookies.items())
            body = None
            if data is not None:
                body = json.dumps(data).encode()
                if ctype:
                    h["Content-Type"] = ctype
            h.update(headers or {})
            conn.request(method, path, body=body, headers=h)
            resp = conn.getresponse()
            r = R(resp.status, resp.getheaders(), resp.read().decode(errors="replace"))
            conn.close()
            return r
        except (ConnectionRefusedError, ConnectionResetError):
            time.sleep(0.3)
    return R(0, [], "")

def tcfg_set(key, val):
    env = dict(os.environ, TSX_CONF=CONF, TSX_RUN=T + "/run", TSX_APPLY_ALLOW_NONROOT="1")
    subprocess.run(["tsx-config", "set", key, val], env=env, check=True, capture_output=True)

def ha_events():
    try:
        return [json.loads(l) for l in open(T + "/ha.log")]
    except OSError:
        return []

def wait_state(pred, port=PORT, cookies=None, limit=15):
    end = time.time() + limit
    while True:
        s = req("GET", "/setup/api/state", port=port, cookies=cookies).json()
        if pred(s) or time.time() > end:
            return s
        time.sleep(0.5)

def listens_lan(port):
    out = subprocess.run(["sh", "-c", "ss -ltn 2>/dev/null"], capture_output=True, text=True).stdout
    return re.search(r"0\.0\.0\.0:%d\b" % port, out) is not None

def login(user="admin", port=PORT, extra=""):
    """The whole flow as a browser does it. Returns (callback response, session cookies)."""
    r = req("GET", "/setup/login", port=port)
    st, _ = r.cookie("tsxlogin")
    if r.status != 302 or not st:
        return r, {}
    u = urllib.parse.urlsplit(r.location)
    c = http.client.HTTPConnection("127.0.0.1", HAPORT, timeout=30)
    c.request("GET", u.path + "?" + u.query + "&user=" + user + extra)
    hr = c.getresponse(); hr.read()
    back = urllib.parse.urlsplit(hr.getheader("Location") or "")
    cb = req("GET", back.path + "?" + back.query, port=port, cookies={"tsxlogin": st})
    cb.path, cb.state = back.path + "?" + back.query, st
    jar = {}
    for name in ("tsxsetup", "tsxcsrf"):
        v, _ = cb.cookie(name)
        if v:
            jar[name] = v
    return cb, jar

def post(path, data, jar, port=PORT, extra_headers=None, source=LANIP):
    h = {"X-TSX-CSRF": jar.get("tsxcsrf", "")}
    h.update(extra_headers or {})
    return req("POST", path, port=port, cookies=jar, data=data, headers=h, source=source)

print("== no Home Assistant URL yet: the pairing code only ==")
s = req("GET", "/setup/api/state").json()
ok(s.get("need_pairing") is True and s.get("login") is False and s.get("pairing") is True, "unconfigured, no URL: login false, pairing true: %s" % s)

print("== the origin of KIOSK_URL is the Home Assistant URL ==")
tcfg_set("KIOSK_URL", "http://127.0.0.1:%d/lovelace/0" % HAPORT)
s = wait_state(lambda s: s.get("login") is True)
ok(s.get("login") is True and s.get("pairing") is False and s.get("ha_host") == "127.0.0.1:%d" % HAPORT,
   "configured, window closed: login true, pairing false, the host of KIOSK_URL: %s" % s)
ok(listens_lan(PORT), "the page stays on the LAN (0.0.0.0) with no pairing window")
r = req("GET", "/setup")
ok(r.status == 200 and "Log in with Home Assistant" in r.body, "GET /setup from the LAN shows the page with the login button")
r = req("POST", "/setup/api/pair", data={"code": "123456"})
ok(r.status == 403, "the pairing code is refused outside the window (%d)" % r.status)

print("== HA_URL wins over KIOSK_URL ==")
tcfg_set("HA_URL", "http://localhost:%d" % HAPORT)
s = wait_state(lambda s: s.get("ha_host") == "localhost:%d" % HAPORT)
ok(s.get("ha_host") == "localhost:%d" % HAPORT, "ha_host is the host of HA_URL: %s" % s.get("ha_host"))

print("== the login: redirect, return, code, admin check, revoke, session ==")
r = req("GET", "/setup/login")
q = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(r.location).query))
ok(r.status == 302 and r.location.startswith("http://localhost:%d/auth/authorize?" % HAPORT), "302 to /auth/authorize of Home Assistant")
cid = "http://%s:%d/" % (LANIP, PORT)
ok(q.get("response_type") == "code" and q.get("client_id") == cid and q.get("redirect_uri") == cid + "setup/auth/callback",
   "client_id is the origin of the page, redirect_uri the callback on the same host: %s" % q)
st, raw = r.cookie("tsxlogin")
ok(st == q.get("state") and "HttpOnly" in raw and "SameSite=Lax" in raw and "Path=/setup/auth" in raw,
   "the login state is in a cookie (HttpOnly, SameSite=Lax, Path=/setup/auth): %s" % raw)
lr = req("GET", "/setup/login", source="127.0.0.1")
ok(lr.status == 302 and lr.location == "/setup", "loopback needs no login: /setup/login goes back to /setup")
before = len(ha_events())
cb, A = login("admin")
ev = ha_events()[before:]
names = [(e["event"], e.get("user")) for e in ev]
ok(cb.status == 200 and "location.replace(\"/setup\")" in cb.body, "the return gives a page that opens /setup (%d)" % cb.status)
ok(("token", "admin") in names and ("current_user", "admin") in names and any(e["event"] == "revoke" and e.get("known") for e in ev),
   "the panel exchanged the code, asked auth/current_user and revoked the refresh token: %s" % names)
ok(any(e["event"] == "ws-pong" and e.get("ok") for e in ev), "the websocket client answered a ping and took a fragmented message")
_, sc = cb.cookie("tsxsetup")
ok(sc and "HttpOnly" in sc and "SameSite=Strict" in sc and "Path=/setup" in sc and "Max-Age=600" in sc,
   "the session cookie: HttpOnly, SameSite=Strict, Path=/setup, Max-Age of the session: %s" % sc)
_, cc = cb.cookie("tsxcsrf")
ok(cc and "HttpOnly" not in cc and "SameSite=Strict" in cc, "the CSRF cookie is readable by the page script: %s" % cc)
s = req("GET", "/setup/api/state", cookies=A).json()
ok(s.get("need_pairing") is False and s.get("session") == {"kind": "ha", "user": "Admin"} and s.get("csrf") == A.get("tsxcsrf"),
   "the session works: kind ha, user Admin, the CSRF token of the cookie")
ok("pairing_code" not in s, "a LAN session never gets the pairing code")

print("== CSRF ==")
rev = s.get("revision")
body = {"revision": rev, "fields": {}}
r = req("POST", "/setup/api/submit", cookies=A, data=body)
ok(r.status == 403, "no token: 403 (%d)" % r.status)
r = req("POST", "/setup/api/submit", cookies=A, data=body, headers={"X-TSX-CSRF": "wrong"})
ok(r.status == 403, "a wrong token: 403 (%d)" % r.status)
r = post("/setup/api/submit", body, A, extra_headers={"Origin": "http://evil.example"})
ok(r.status == 403, "another Origin: 403 (%d)" % r.status)
r = post("/setup/api/submit", body, A, extra_headers={"Sec-Fetch-Site": "cross-site"})
ok(r.status == 403, "Sec-Fetch-Site cross-site: 403 (%d)" % r.status)
r = req("POST", "/setup/api/submit", cookies=A, data=body, headers={"X-TSX-CSRF": A["tsxcsrf"]}, ctype="text/plain")
ok(r.status == 415, "a form body (text/plain): 415 (%d)" % r.status)
mark = open(T + "/helper.log").read().count("kiosk-restart")
r = post("/setup/api/submit", {"revision": rev, "fields": {"MQTT_HOST": "mq.example"}}, A,
         extra_headers={"Origin": "http://%s:%d" % (LANIP, PORT), "Sec-Fetch-Site": "same-origin"})
ok(r.status == 200 and r.json().get("kiosk_restarted") is False, "the right token, the same Origin: the save works and does not restart the kiosk: %s" % r.body)
ok(open(T + "/helper.log").read().count("kiosk-restart") == mark, "no kiosk-restart for a remote save")
ok('MQTT_HOST="mq.example"' in open(CONF).read(), "the remote save landed in panel.conf")
r = req("POST", "/setup/api/submit", source="127.0.0.1", data={"revision": None, "fields": {}})
ok(r.status == 403, "loopback without the token: 403 (%d)" % r.status)
ls = req("GET", "/setup/api/state", source="127.0.0.1").json()
r = req("POST", "/setup/api/submit", source="127.0.0.1", data={"revision": ls.get("revision"), "fields": {}},
        headers={"X-TSX-CSRF": ls.get("csrf") or ""})
ok(ls.get("csrf") and ls.get("csrf") != A["tsxcsrf"] and r.status == 200, "loopback with its own token: 200 (%d)" % r.status)
r = req("POST", "/setup/api/pair", data={"code": "1"}, headers={"Origin": "http://evil.example"})
ok(r.status == 403, "/setup/api/pair from another Origin: 403")

print("== a return that is replayed, foreign or canceled ==")
r = req("GET", "/setup/login"); st, _ = r.cookie("tsxlogin")
u = urllib.parse.urlsplit(r.location)
c = http.client.HTTPConnection("127.0.0.1", HAPORT); c.request("GET", u.path + "?" + u.query + "&user=admin")
back = urllib.parse.urlsplit(c.getresponse().getheader("Location"))
cbpath = back.path + "?" + back.query
n0 = len([e for e in ha_events() if e["event"] == "token"])
r = req("GET", cbpath)
ok(r.status == 400 and not r.cookie("tsxsetup")[0], "a return without the login cookie (another browser): 400, no session")
ok(len([e for e in ha_events() if e["event"] == "token"]) == n0, "it did not exchange the code")
first, F1 = login("admin")
post("/setup/api/logout", {}, F1)
n0 = len([e for e in ha_events() if e["event"] == "token"])
r = req("GET", first.path, cookies={"tsxlogin": first.state})
ok(first.status == 200 and r.status == 400, "a return that worked, sent again: the state is used up: 400 (%d)" % r.status)
ok(len([e for e in ha_events() if e["event"] == "token"]) == n0, "the replay did not exchange the code again")
r = req("GET", cbpath.replace("state=", "state=x"), cookies={"tsxlogin": "x" + st})
ok(r.status == 400, "an unknown state: 400")
cb, jar = login("admin", extra="&deny=1")
ok(cb.status == 403 and "canceled" in cb.body and not jar.get("tsxsetup"), "a canceled login: 403, no session")

print("== a user who is not an administrator ==")
before = len(ha_events())
cb, G = login("guest")
ev = ha_events()[before:]
ok(cb.status == 403 and "not an administrator" in cb.body and not G.get("tsxsetup"), "guest: 403, not an administrator, no session cookie")
ok(any(e["event"] == "revoke" and e.get("user") == "guest" and e.get("known") for e in ev), "the refresh token of the guest is revoked too")

print("== sessions: the list, a revoke of one, a logout, a revoke of all ==")
cb, B = login("admin")
lst = req("GET", "/setup/api/sessions", cookies=A).json().get("sessions", [])
mine = [x for x in lst if x["current"]]
other = [x for x in lst if not x["current"]]
ok(len(lst) == 2 and len(mine) == 1 and all(x["kind"] == "ha" and x["user"] == "Admin" for x in lst), "two sessions, one is this browser: %s" % lst)
ok(all("csrf" not in x and "token" not in json.dumps(x).lower() for x in lst), "the list has no token")
r = post("/setup/api/sessions/revoke", {"id": other[0]["id"]}, A)
ok(r.status == 200 and req("GET", "/setup/api/state", cookies=B).json().get("need_pairing") is True, "a revoked session is refused at once")
ok(req("GET", "/setup/api/state", cookies=A).json().get("need_pairing") is False, "the other session still works")
r = post("/setup/api/logout", {}, A)
ok(r.status == 200 and any(c.startswith("tsxsetup=;") and "Max-Age=0" in c for c in r.cookies), "logout clears the cookie")
ok(req("GET", "/setup/api/state", cookies=A).json().get("need_pairing") is True, "after the logout the old cookie is refused")
_, C = login("admin"); _, D = login("admin")
r = post("/setup/api/sessions/revoke", {"all": True}, C)
ok(r.status == 200 and r.json().get("revoked") == 2, "revoke all: 2 sessions")
ok(all(req("GET", "/setup/api/state", cookies=j).json().get("need_pairing") is True for j in (C, D)), "both are refused")

print("== the Panel section ==")
_, E = login("admin")
p = req("GET", "/setup/api/panel", cookies=E).json()
c = p.get("controls", {})
ok(p.get("owner") == "kiosk" and c.get("screen") == {"on": True} and c.get("backlight") == {"value": 40} and c.get("volume") == {"value": 55, "muted": False},
   "the screen, the brightness, the volume and the mute of the Sendspin player: %s" % c)
ok(c.get("ledbar") == {"on": True, "brightness": 100, "color": "#ff8000"} and c.get("key_leds") == {"on": True, "level": 128},
   "the LED bar (R G B 0..100 as a color and a brightness) and the key LEDs: %s %s" % (c.get("ledbar"), c.get("key_leds")))
ok(c.get("lights") == {"on": False, "brightness": 40, "color": "#010203"} and "dim_timeout" not in c, "the lights of the panel app; no dim time: %s" % c.get("lights"))
ok("update_mode" not in c and "auto_restart" not in c, "a panel without the update lines of the state has no update controls: %s" % c)
ok(req("GET", "/setup/api/panel").status == 403, "without a session: 403")
open(T + "/update.lines", "w").write("update-mode manual\nauto-restart off\n")
c = req("GET", "/setup/api/panel", cookies=E).json().get("controls", {})
ok(c.get("update_mode") == {"value": "manual"} and c.get("auto_restart") == {"on": False}, "the update mode and the automatic restart from the state: %s %s" % (c.get("update_mode"), c.get("auto_restart")))
open(T + "/update.lines", "w").write("update-mode auto\nauto-restart on\n")
c = req("GET", "/setup/api/panel", cookies=E).json().get("controls", {})
ok(c.get("update_mode") == {"value": "auto"} and c.get("auto_restart") == {"on": True}, "auto and on: %s %s" % (c.get("update_mode"), c.get("auto_restart")))
open(T + "/update.lines", "w").write("update-mode sometimes\nauto-restart maybe\n")
c = req("GET", "/setup/api/panel", cookies=E).json().get("controls", {})
ok("update_mode" not in c and "auto_restart" not in c, "a value outside the list hides the control: %s" % c)
open(T + "/panelctl.log", "w").close()
for control, value, want in (("backlight", 70, "send brightness-pct 70"), ("screen", False, "send blank on"), ("screen", True, "send blank off"),
                             ("volume", 0, "send volume 0"), ("mute", True, "send mute on"), ("mute", False, "send mute off"),
                             ("ledbar", {"on": True, "brightness": 50, "color": "#ff8000"}, "send ledbar set 50 25 0"),
                             ("ledbar", {"on": False}, "send ledbar off"),
                             ("lights", {"on": True, "brightness": 40, "color": "#0a141e"}, "send lights set 40 10 20 30"),
                             ("key_leds", {"on": True, "level": 128}, "send keypad led 128"), ("key_leds", {"on": False}, "send keypad led off")):
    r = post("/setup/api/panel", {"control": control, "value": value}, E)
    last = open(T + "/panelctl.log").read().strip().split("\n")[-1]
    ok(r.status == 200 and last == want, "%s %s -> tsx-panelctl %s" % (control, json.dumps(value), last))
n = open(T + "/panelctl.log").read().count("send")
for control, value in (("backlight", 0), ("backlight", 101), ("backlight", True), ("volume", "50"), ("mute", "on"), ("mute", 1), ("screen", "on"),
                       ("ledbar", {"on": True, "brightness": 50, "color": "red"}), ("key_leds", {"on": True, "level": 300}),
                       ("dim_level", 0), ("blank_timeout", 86401), ("reboot", 1)):
    r = post("/setup/api/panel", {"control": control, "value": value}, E)
    ok(r.status == 400, "refused: %s %s (%d)" % (control, json.dumps(value), r.status))
ok(open(T + "/panelctl.log").read().count("send") == n, "no refused change reached tsx-panelctl")
s = req("GET", "/setup/api/state", cookies=E).json()
r = post("/setup/api/panel", {"control": "blank_timeout", "value": 120}, E)
j = r.json()
ok(r.status == 200 and j.get("revision_before") == s.get("revision") and j.get("revision") != j.get("revision_before"),
   "a time goes to panel.conf and gives the new revision: %s" % r.body)
ok('BLANK_TIMEOUT="120"' in open(CONF).read(), "BLANK_TIMEOUT=120 in panel.conf")
for control, value, want in (("update_mode", "manual", 'UPDATE_MODE="manual"'), ("update_mode", "auto", 'UPDATE_MODE="auto"'),
                             ("auto_restart", False, 'UPDATE_AUTO_RESTART="off"'), ("auto_restart", True, 'UPDATE_AUTO_RESTART="on"')):
    s = req("GET", "/setup/api/state", cookies=E).json()
    r = post("/setup/api/panel", {"control": control, "value": value}, E)
    j = r.json()
    ok(r.status == 200 and j.get("revision_before") == s.get("revision") and j.get("revision") != j.get("revision_before"),
       "%s %s: 200, the revision moves: %s" % (control, json.dumps(value), r.body))
    ok(want in open(CONF).read().split("\n"), "%s in panel.conf" % want)
conf = open(CONF).read()
ok("autoupdate" not in open(T + "/panelctl.log").read(), "the update settings do not go through tsx-panelctl send")
for control, value in (("update_mode", "sometimes"), ("update_mode", "Auto"), ("update_mode", ""), ("update_mode", True), ("update_mode", 1),
                       ("update_mode", None), ("auto_restart", "on"), ("auto_restart", "off"), ("auto_restart", 1), ("auto_restart", 0),
                       ("auto_restart", None), ("auto_restart", {"on": True})):
    r = post("/setup/api/panel", {"control": control, "value": value}, E)
    ok(r.status == 400, "refused: %s %s (%d)" % (control, json.dumps(value), r.status))
ok(open(CONF).read() == conf, "the refused update values changed nothing in panel.conf")

print("== the helper command panel: the allowlist ==")
def helper2(line):
    with open(T + "/h2/req", "w") as f:
        f.write(line + "\n")
    out = subprocess.run(["timeout", "10", "head", "-1", T + "/h2/resp"], capture_output=True, text=True).stdout.strip()
    return out
open(T + "/panelctl.log", "w").close()
for line in ("panel reboot", "panel blank on; rm -rf /", "panel ledbar set 1 2", "panel brightness-pct 1000", "panel volume -5",
             "panel lights set 1 2 3 4 5", "panel blank  on", "panel keypad led auto", "panel setup", "panel config-url http://x",
             "panel mute maybe", "panel mute on off", "panel mute"):
    ok(helper2(line).startswith("err"), "the helper refuses '%s'" % line)
ok(open(T + "/panelctl.log").read() == "", "no refused line reached tsx-panelctl")
ok(helper2("panel volume 50") == "ok" and open(T + "/panelctl.log").read().strip() == "send volume 50", "the helper passes 'panel volume 50'")
open(T + "/panelctl.log", "w").close()
ok(helper2("panel mute on") == "ok" and open(T + "/panelctl.log").read().strip() == "send mute on", "the helper passes 'panel mute on'")
r = helper2("panel-state")
ok(r.startswith("ok owner kiosk\x01screen on"), "panel-state gives the lines of tsx-panelctl state")

print("== the expiry of a session (second server: 5 s idle, 9 s in all) ==")
_, X = login("admin", port=PORT2)
ok(req("GET", "/setup/api/state", port=PORT2, cookies=X).json().get("need_pairing") is False, "a new session works")
time.sleep(6)
ok(req("GET", "/setup/api/state", port=PORT2, cookies=X).json().get("need_pairing") is True, "after 6 s without a request: expired (idle)")
_, Y = login("admin", port=PORT2)
t0 = time.time(); alive = True
while time.time() - t0 < 7:
    alive = alive and req("GET", "/setup/api/state", port=PORT2, cookies=Y).json().get("need_pairing") is False
    time.sleep(1.5)
ok(alive, "a session in use stays valid")
while time.time() - t0 < 10:
    time.sleep(0.5)
ok(req("GET", "/setup/api/state", port=PORT2, cookies=Y).json().get("need_pairing") is True, "after 10 s: expired (absolute), although in use")

print("== the rate limit of the login ==")
codes = [req("GET", "/setup/login").status for _ in range(22)]
ok(429 in codes, "too many logins from one address: 429 (%s)" % codes[-3:])

print("== no token in a log or an answer ==")
logs = "".join(open(T + "/" + f).read() for f in os.listdir(T) if f.endswith(".log") and f != "ha.log")
ok(not re.search(r"\b(AT|RT)[0-9a-f]{32}\b", logs), "no access or refresh token in the logs of the panel")
ok("callback?..." in open(T + "/setupd.log").read() and "code=" not in open(T + "/setupd.log").read(), "the request log hides the code of the return")

print("== %d ok, %d failed ==" % (N, F))
sys.exit(1 if F else 0)
PYEOF
rc=$?
[ "$rc" = 0 ] && echo PASS test-setup-login || { echo FAIL test-setup-login; tail -20 "$T/setupd.log"; }
exit $rc
