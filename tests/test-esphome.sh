#!/bin/bash
# Host test for tsx-esphome (the standalone ESPHome native API server used
# when VOICE=off; see rootfs/voice/shim/tsx_panel/ and PLAN.md section 18):
# fake sysfs/state-file fixtures + a fake Chromium DevTools endpoint, the
# real tsx_panel code, and a real Home Assistant ESPHome client
# (aioesphomeapi) checking the entity list, a light toggle, a text (kiosk
# URL) set and a front-key press event -- exactly the "one HA device" this
# feature adds. Only needs network to fetch pinned, public packages (same
# ones rootfs/voice/install-lva.sh fetches for the panel image); nothing here
# compiles anything.
#
# tsx_panel reuses linux_voice_assistant.entity.LEDLightEntity (the LED bar
# and key-LED lights), which imports python-mpv even though this test never
# plays audio -- so a system libmpv is a real, if easy to miss, dependency;
# see ci/lint.sh / .github/workflows/tests.yml for the apt-get package name.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SHIM=$HERE/../voice/shim
T=$(mktemp -d)
PIDS=
trap 'for p in $PIDS; do kill "$p" 2>/dev/null || true; done; [ -n "${KEEP:-}" ] && echo "kept $T" || rm -rf "$T"' EXIT

# ---- pinned linux-voice-assistant source (same as install-lva.sh; we only
# need the linux_voice_assistant/ package tree, not its wake-word/audio deps)
LVA=1.1.15
LVA_SHA256=077696e60b57ae3a98aca3d49d1b9f9971ffd36d62f5c23b8603ccc4c9fcdbd8
CACHE=${TSX_TEST_CACHE:-/tmp/tsx-esphome-test-cache}
mkdir -p "$CACHE"
if [ ! -s "$CACHE/lva-$LVA.tar.gz" ]; then
	curl -fsSL -o "$CACHE/lva-$LVA.tar.gz" "https://github.com/OHF-Voice/linux-voice-assistant/archive/refs/tags/v$LVA.tar.gz"
fi
echo "$LVA_SHA256  $CACHE/lva-$LVA.tar.gz" | sha256sum -c - >/dev/null
tar -C "$T" -xzf "$CACHE/lva-$LVA.tar.gz"
LVA_SRC=$T/linux-voice-assistant-$LVA

# ---- python venv with the (loosely-versioned; this is a host test, not the
# panel image) client + server dependencies -----------------------------
python3 -m venv "$T/venv"
"$T/venv/bin/pip" -q install --disable-pip-version-check \
	aioesphomeapi getmac netifaces2 zeroconf "websockets==12.0" python-mpv

# ---- fixtures ------------------------------------------------------------
F=$T/fixture
mkdir -p "$F/run/tsx" "$F/etc/tsx" "$F/sys/thermal" "$F/proc/asound" "$F/bin"
echo "want 50 60 70" > "$F/run/tsx/ledbar.state"
printf 'led 128 unknown\nlast power short\n' > "$F/run/tsx/buttons.state"
echo "on 17" > "$F/run/tsx-idled.state"
cat > "$F/etc/kiosk.conf" <<'EOF'
BACKLIGHT_MAX=23
KIOSK_URL="https://ha.example.org/default"
EOF
# tsx-config's override wins; the fake DevTools page shows yet another URL
# (https://ha.example.org/), which the Kiosk URL entity must NOT report
echo 'KIOSK_URL="https://ha.example.org/configured"' > "$F/run/tsx/kiosk.conf"
cat > "$F/etc/tsx/buttons.conf" <<'EOF'
button power  KEY_F13 led=1
button home   KEY_F14 led=2
EOF
echo 40000 > "$F/sys/thermal/temp"
for b in tsx-ledbar tsx-keypad tsx-blank tsx-config tsx-als; do
	cat > "$F/bin/$b" <<EOF
#!/bin/sh
echo "$b \$*" >> "$F/cmds.log"
EOF
	chmod +x "$F/bin/$b"
done

DT_HTTP=$((20000 + RANDOM % 5000)); DT_WS=$((DT_HTTP + 1)); API_PORT=$((DT_HTTP + 2))

"$T/venv/bin/python3" "$HERE/esphome-fake-devtools.py" "$DT_HTTP" "$DT_WS" > "$T/devtools.log" 2>&1 &
PIDS="$PIDS $!"

PATH="$F/bin:$PATH" \
PYTHONPATH="$SHIM:$LVA_SRC" \
TSX_RUN_DIR="$F/run/tsx" TSX_IDLED_STATE="$F/run/tsx-idled.state" \
TSX_BUTTONS_CONF="$F/etc/tsx/buttons.conf" TSX_KIOSK_CONF="$F/etc/kiosk.conf" \
TSX_ALS_CONF="$F/etc/tsx/als.conf.missing" TSX_ASOUND_DIR="$F/proc/asound" \
TSX_THERMAL_ZONE="$F/sys/thermal/temp" TSX_DEVTOOLS="127.0.0.1:$DT_HTTP" \
TSX_PANEL_DIRECT=1 \
"$T/venv/bin/python3" -m tsx_panel.esphome_server --name test-panel --port "$API_PORT" --host 127.0.0.1 \
	> "$T/server.log" 2>&1 &
PIDS="$PIDS $!"

for _ in $(seq 1 40); do
	grep -q "listening on" "$T/server.log" 2>/dev/null && break
	sleep 0.25
done
grep -q "listening on" "$T/server.log" || { echo "FAIL: tsx-esphome did not start"; cat "$T/server.log"; exit 1; }

# simulate a front-key long-press partway through the client check (which
# polls for it for up to 10 s)
( sleep 3; printf 'led 128 unknown\nlast home long\n' > "$F/run/tsx/buttons.state" ) &
PIDS="$PIDS $!"

"$T/venv/bin/python3" "$HERE/esphome-check.py" "$API_PORT"
rc=$?

echo "-- backend commands issued --"
cat "$F/cmds.log" 2>/dev/null || echo "(none)"
grep -q '^tsx-ledbar set 100 0 0$' "$F/cmds.log" 2>/dev/null && echo "OK: ledbar command reached the backend" || { echo "FAIL: ledbar command missing/wrong"; rc=1; }
grep -q '^tsx-config set KIOSK_URL https://ha.example.org/lovelace/0$' "$F/cmds.log" 2>/dev/null && echo "OK: kiosk URL persisted through tsx-config" || { echo "FAIL: tsx-config set KIOSK_URL missing"; rc=1; }
[ "$(cat "$F/run/tsx/brightness" 2>/dev/null)" = 5 ] && echo "OK: backlight written as an integer (5)" || { echo "FAIL: brightness file is '$(cat "$F/run/tsx/brightness" 2>/dev/null)', want 5"; rc=1; }
grep -q 'Page.navigate' "$T/devtools.log" 2>/dev/null && echo "OK: kiosk URL navigated live via DevTools" || { echo "FAIL: no Page.navigate seen"; rc=1; }

# ---- HA_ALLOW_FROM: an allowed peer connects, a denied one is closed ------
# (rootfs/voice/shim/tsx_panel/security.py; the API itself has no
# encryption/password, so this is the only access control it has)
ALLOW_PORT=$((API_PORT + 10)); DENY_PORT=$((API_PORT + 11))
PATH="$F/bin:$PATH" PYTHONPATH="$SHIM:$LVA_SRC" \
TSX_RUN_DIR="$F/run/tsx" TSX_DEVTOOLS="127.0.0.1:$DT_HTTP" TSX_PANEL_DIRECT=1 \
TSX_HA_ALLOW_FROM="127.0.0.1/32,10.0.0.0/8" \
"$T/venv/bin/python3" -m tsx_panel.esphome_server --name allow-test --port "$ALLOW_PORT" --host 127.0.0.1 \
	> "$T/server-allow.log" 2>&1 &
PIDS="$PIDS $!"
PATH="$F/bin:$PATH" PYTHONPATH="$SHIM:$LVA_SRC" \
TSX_RUN_DIR="$F/run/tsx" TSX_DEVTOOLS="127.0.0.1:$DT_HTTP" TSX_PANEL_DIRECT=1 \
TSX_HA_ALLOW_FROM="10.0.0.99" \
"$T/venv/bin/python3" -m tsx_panel.esphome_server --name deny-test --port "$DENY_PORT" --host 127.0.0.1 \
	> "$T/server-deny.log" 2>&1 &
PIDS="$PIDS $!"
for _ in $(seq 1 40); do
	grep -q "listening on" "$T/server-allow.log" 2>/dev/null && grep -q "listening on" "$T/server-deny.log" 2>/dev/null && break
	sleep 0.25
done

"$T/venv/bin/python3" "$HERE/esphome-allowlist-check.py" "$ALLOW_PORT" allow || rc=1
"$T/venv/bin/python3" "$HERE/esphome-allowlist-check.py" "$DENY_PORT" deny || rc=1
grep -q 'closing connection from 127.0.0.1' "$T/server-deny.log" 2>/dev/null && echo "OK: denial was logged" || { echo "FAIL: no denial logged"; rc=1; }

exit "$rc"
