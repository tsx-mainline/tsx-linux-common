#!/bin/bash
# Host test of the texts about a missing part (no microphone, no Bluetooth
# module, no camera) outside tsx-config and the setup page. They end with the
# REASON text of hw.conf in brackets. A panel with no REASON gets the short
# text with no brackets. The files are:
#   - ha/usr/local/bin/tsx-voice (status)
#   - ha/etc/init.d/tsx-voice (start_pre)
#   - ha/voice/shim/tsx_panel/hw.py (reason_tail, used by tsx_lva)
# No network and no hardware.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
VOICE_BIN=$HERE/ha/usr/local/bin/tsx-voice
VOICE_INIT=$HERE/ha/etc/init.d/tsx-voice
mkdir -p "$T/run"
hw() { printf '%b' "$1" > "$T/run/hw.conf"; }

echo "== syntax =="
busybox sh -n "$VOICE_BIN" && ok "tsx-voice passes busybox sh -n" || bad "tsx-voice: busybox sh -n"
busybox sh -n "$VOICE_INIT" && ok "the tsx-voice init script passes busybox sh -n" || bad "tsx-voice init script: busybox sh -n"

echo "== tsx-voice status =="
status() { env TSX_HW_CONF="$T/run/hw.conf" TSX_VOICE_RUN="$T/run/voice" busybox sh "$VOICE_BIN" status 2>/dev/null | head -n 1; }
hw 'MIC=no\nREASON=FAKE-100 NC variant\n'
eq "$(status)" "voice: not available. No microphone on this panel (FAKE-100 NC variant)" "REASON in brackets"
hw 'MIC=no\nREASON=\n'
eq "$(status)" "voice: not available. No microphone on this panel" "an empty REASON: the short text"
hw 'MIC=no\n'
eq "$(status)" "voice: not available. No microphone on this panel" "no REASON line: the short text"

echo "== the init script of tsx-voice =="
sed -e "s|/run/tsx/hw.conf|$T/run/hw.conf|g" "$VOICE_INIT" > "$T/voice.init"
start_pre() { busybox sh -c '. "$1"; eerror() { echo "$*"; }; einfo() { :; }; start_pre' sh "$T/voice.init" 2>&1; }
hw 'MIC=no\nREASON=FAKE-100 NC variant\n'
eq "$(start_pre)" "No microphone on this panel (FAKE-100 NC variant). The voice satellite does not start" "start_pre: REASON in brackets"
hw 'MIC=no\nREASON=\n'
eq "$(start_pre)" "No microphone on this panel. The voice satellite does not start" "start_pre: an empty REASON gives the short text"
hw 'MIC=no\n'
eq "$(start_pre)" "No microphone on this panel. The voice satellite does not start" "start_pre: no REASON line gives the short text"

echo "== hw.py =="
python3 - "$HERE/ha/voice/shim" "$T/run/hw.conf" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
from tsx_panel import hw
p = sys.argv[2]
def put(text):
    open(p, "w").write(text)
put("MIC=no\nREASON=FAKE-100 NC variant\n")
assert hw.reason_tail(p) == " (FAKE-100 NC variant)", hw.reason_tail(p)
assert hw.reason(p) == "FAKE-100 NC variant"
put("MIC=no\nREASON=\n")
assert hw.reason_tail(p) == "", hw.reason_tail(p)
put("MIC=no\n")
assert hw.reason_tail(p) == ""
os.unlink(p)
assert hw.reason_tail(p) == "", "a missing hw.conf gives no tail"
print("OK")
PY
[ $? = 0 ] && ok "reason_tail: REASON in brackets, else an empty string" || bad "hw.py reason_tail"
grep -q 'reason_tail' "$HERE/ha/voice/shim/tsx_lva/__init__.py" && ok "the voice satellite uses reason_tail" || bad "tsx_lva does not use reason_tail"

echo "== $N ok, $F failed =="
[ "$F" = 0 ] && echo "PASS missing parts" || { echo "FAIL missing parts"; exit 1; }
