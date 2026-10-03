#!/bin/bash
# End-to-end host test of the custom wake word models: the real
# linux-voice-assistant 1.1.15 with the tsx_lva patches
# (esphome-lva-harness.py, TSX_HARNESS_WAKEWORDS=1) and a real ESPHome client
# (aioesphomeapi, the version of Home Assistant 2026.9) that connects and
# reads the wake word list the way Home Assistant does
# (esphome-wakeword-check.py). The check adds a model, selects it, adds a bad
# model and removes the active model. Stub engines stand in for
# pymicro-wakeword and pyopen-wakeword. HA_TRANSPORT=mqtt leaves out the
# panel entities, so the test needs no tsx-panelctl.
# The test needs the network only to fetch pinned, public packages (as
# test-esphome.sh, also the system libmpv). The test compiles nothing.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SHIM=$HERE/../ha/voice/shim
T=$(mktemp -d)
: > "$T/libtflite.so"
PIDS=
trap 'for p in $PIDS; do kill "$p" 2>/dev/null || true; done; [ -n "${KEEP:-}" ] && echo "kept $T" || rm -rf "$T"' EXIT

LVA=1.1.15
LVA_SHA256=077696e60b57ae3a98aca3d49d1b9f9971ffd36d62f5c23b8603ccc4c9fcdbd8
CACHE=${TSX_TEST_CACHE:-/tmp/tsx-esphome-test-cache}
mkdir -p "$CACHE"
[ -s "$CACHE/lva-$LVA.tar.gz" ] || curl -fsSL -o "$CACHE/lva-$LVA.tar.gz" "https://github.com/OHF-Voice/linux-voice-assistant/archive/refs/tags/v$LVA.tar.gz"
echo "$LVA_SHA256  $CACHE/lva-$LVA.tar.gz" | sha256sum -c - >/dev/null
tar -C "$T" -xzf "$CACHE/lva-$LVA.tar.gz"
LVA_SRC=$T/linux-voice-assistant-$LVA
python3 -m venv "$T/venv"
"$T/venv/bin/pip" -q install --disable-pip-version-check --only-binary :all: \
	"aioesphomeapi==46.2.0" getmac netifaces2 zeroconf "websockets==12.0" python-mpv

mkdir -p "$T/custom" "$T/run" "$T/hw"
PORT=$((20000 + RANDOM % 5000))
env PYTHONPATH="$SHIM:$LVA_SRC" \
	TSX_HARNESS_WAKEWORDS=1 TSX_VOICE_WAKEWORDS="$T/custom" TSX_VOICE_RUN_DIR="$T/run" \
	TSX_HA_TRANSPORT=mqtt TSX_TFLITE_SO="$T/libtflite.so" TSX_PANEL_NAME=tsx-wakeword-test \
	TSX_ESPHOME_RUN_CONF="$T/esphome.conf.missing" TSX_ESPHOME_KEY_FILE="$T/esphome.key.missing" \
	TSX_HW_CONF="$T/hw/hw.conf.missing" TSX_RUN_DIR="$T/hw" \
	"$T/venv/bin/python3" "$HERE/esphome-lva-harness.py" "$PORT" > "$T/voice.log" 2>&1 &
PIDS="$PIDS $!"
for _ in $(seq 1 80); do grep -q "listening on" "$T/voice.log" 2>/dev/null && break; sleep 0.25; done
grep -q "listening on" "$T/voice.log" || { echo "FAIL: the harness did not start"; cat "$T/voice.log"; exit 1; }

rc=0
"$T/venv/bin/python3" "$HERE/esphome-wakeword-check.py" "$PORT" "$T/custom" "$LVA_SRC/wakewords" || rc=1
want() {  # want TEXT LABEL
	if grep -q -- "$1" "$T/voice.log"; then echo "OK: log: $2"; else echo "FAIL: log: $2 (no '$1')"; rc=1; fi
}
want "tsx_lva: custom wake words in $T/custom" "the custom folder"
want "custom wake words: watching $T/custom (inotify)" "the watcher uses inotify"
want "broken.json skipped: the .json file is not valid JSON" "the bad model is skipped with the reason"
want "the active wake word my_word is gone" "the gone active wake word"
want "back to the default okay_nabu" "the fallback"
want "closing the ESPHome API connection" "the reconnect"
if grep -q "Traceback" "$T/voice.log"; then echo "FAIL: a traceback in the log"; rc=1; fi
[ $rc = 0 ] || { echo "--- voice.log"; tail -n 60 "$T/voice.log"; }
[ $rc = 0 ] && echo "PASS test-esphome-wakewords" || echo "FAIL test-esphome-wakewords"
exit $rc
