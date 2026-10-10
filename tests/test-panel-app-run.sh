#!/bin/sh
# Host test for tsx-panel-app-run, the start script of the panel app
# (docs/panel-app.md, "Service"). The test checks:
#  - the identity from the host name and the MAC of the interface (the
#    locally administered bit set, the multicast bit clear)
#  - the first start keeps the identity in the file of the panel, and a later
#    host name does not change it
#  - the values of the file of the panel win; a bad name falls back
#  - the board file sets the environment and the device files
#  - the script runs the program with that environment
# It runs under busybox or dash sh and needs no compiler.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
RUNNER=$HERE/panel-app/usr/local/sbin/tsx-panel-app-run
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }

mkdir -p "$T/net/eth9" "$T/state" "$T/bin"
echo "a0:b1:c2:d3:e4:f5" > "$T/net/eth9/address"
cat > "$T/panel-app.conf" <<EOC
PANEL_APP_BIN=$T/bin/app
PANEL_APP_PREFDIR=$T/prefs
PANEL_APP_NET_IF=eth9
PANEL_APP_WAIT=1
EOC
cat > "$T/board.conf" <<EOC
PANEL_APP_ENV="FAKE_DRIVER=one FAKE_INDEX=2"
PANEL_APP_DEVICES="$T/dev-present"
PANEL_APP_DIRS="$T/run-dir"
EOC
: > "$T/dev-present"
# The fake program prints its environment.
printf '#!/bin/sh\nenv | grep -E "^(TSX_PANEL_APP_|FAKE_|ESPHOME_PREFDIR)" | sort\n' > "$T/bin/app"
chmod 755 "$T/bin/app"
export TSX_PANEL_APP_CONF="$T/panel-app.conf" TSX_PANEL_APP_BOARD_CONF="$T/board.conf"
export TSX_PANEL_APP_STATE_CONF="$T/state/panel-app.conf" TSX_SYS_NET="$T/net"

echo "== first start =="
TSX_HOSTNAME="Fake-Model-A0B1C2D3E4F5" sh "$RUNNER" > "$T/out1" 2>&1 || bad "first start failed: $(cat "$T/out1")"
grep -qx 'TSX_PANEL_APP_NAME=fake-model-a0b1c2d3e4f5' "$T/out1" && ok "name from the host name" || bad "name: $(cat "$T/out1")"
grep -qx 'TSX_PANEL_APP_FRIENDLY_NAME=Fake-Model-A0B1C2D3E4F5' "$T/out1" && ok "friendly name" || bad "friendly name"
grep -qx 'TSX_PANEL_APP_MAC=A2:B1:C2:D3:E4:F5' "$T/out1" && ok "MAC: locally administered, not multicast" || bad "MAC: $(grep MAC "$T/out1")"
grep -qx 'FAKE_DRIVER=one' "$T/out1" && grep -qx 'FAKE_INDEX=2' "$T/out1" && ok "board environment" || bad "board environment"
grep -qx "ESPHOME_PREFDIR=$T/prefs" "$T/out1" && [ -d "$T/prefs" ] && ok "preferences folder" || bad "preferences folder"
[ "$(stat -c %a "$T/run-dir" 2>/dev/null)" = 700 ] && ok "PANEL_APP_DIRS made with mode 700" || bad "PANEL_APP_DIRS"
grep -q '^NAME="fake-model-a0b1c2d3e4f5"$' "$T/state/panel-app.conf" && ok "identity saved" || bad "state file: $(cat "$T/state/panel-app.conf" 2>&1)"
[ "$(stat -c %a "$T/state/panel-app.conf")" = 644 ] && ok "state file mode 644" || bad "state file mode"

echo "== later start with another host name =="
TSX_HOSTNAME="renamed" sh "$RUNNER" > "$T/out2" 2>&1 || bad "second start failed"
grep -qx 'TSX_PANEL_APP_NAME=fake-model-a0b1c2d3e4f5' "$T/out2" && ok "the saved name stays" || bad "name changed: $(cat "$T/out2")"

echo "== values of the panel win =="
printf 'NAME="my-panel"\nFRIENDLY_NAME="My Panel"\nMAC="02:00:00:00:00:01"\n' > "$T/state/panel-app.conf"
TSX_HOSTNAME="x" sh "$RUNNER" --print > "$T/out3" 2>&1
grep -qx 'NAME=my-panel' "$T/out3" && grep -qx 'FRIENDLY_NAME=My Panel' "$T/out3" && grep -qx 'MAC=02:00:00:00:00:01' "$T/out3" \
	&& ok "state file values" || bad "state file values: $(cat "$T/out3")"
printf 'NAME="Bad_Name"\nMAC="02:00:00:00:00:01"\n' > "$T/state/panel-app.conf"
TSX_HOSTNAME="Host-1" sh "$RUNNER" --print > "$T/out4" 2>&1
grep -qx 'NAME=host-1' "$T/out4" && ok "a bad name falls back to the host name" || bad "bad name: $(cat "$T/out4")"
grep -q 'Bad_Name' "$T/state/panel-app.conf" && ok "--print writes nothing" || bad "--print changed the state file"

echo "== no program, a missing device =="
rm -f "$T/state/panel-app.conf" "$T/dev-present"
TSX_HOSTNAME="h" sh "$RUNNER" > "$T/out5" 2>&1 && grep -q 'missing after 1s' "$T/out5" && ok "missing device: waits, then starts" || bad "missing device: $(cat "$T/out5")"
sed -i "s#^PANEL_APP_BIN=.*#PANEL_APP_BIN=$T/bin/none#" "$T/panel-app.conf"
if TSX_HOSTNAME="h" sh "$RUNNER" > "$T/out6" 2>&1; then bad "no program: exit 0"; else grep -q 'no program' "$T/out6" && ok "no program: exit 1" || bad "no program: $(cat "$T/out6")"; fi
rm -rf "$T/net/eth9" "$T/state/panel-app.conf"
TSX_HOSTNAME="h" sh "$RUNNER" --print > "$T/out7" 2>&1
grep -qx 'MAC=' "$T/out7" && ok "no interface: no MAC" || bad "no interface: $(cat "$T/out7")"

echo "== $N passed, $F failed"
[ "$F" = 0 ]
