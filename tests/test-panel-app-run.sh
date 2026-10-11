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

echo "== the user of the program (--user) =="
ME=$(id -un); MG=$(id -gn)
mkdir -p "$T/net/eth9"; echo "a0:b1:c2:d3:e4:f5" > "$T/net/eth9/address"
printf '#!/bin/sh\n# TSX_PANEL_APP_OUT_DIR\nenv | grep -E "^(TSX_PANEL_APP_|ESPHOME_PREFDIR)" | sort\n' > "$T/bin/app"
printf '#!/bin/sh\necho old\n' > "$T/bin/old"; chmod 755 "$T/bin/app" "$T/bin/old"
sed -i "s#^PANEL_APP_BIN=.*#PANEL_APP_BIN=$T/bin/app#" "$T/panel-app.conf"
user_of() { env "$@" TSX_HOSTNAME=h sh "$RUNNER" --user 2>"$T/user.err"; }
[ "$(user_of PANEL_APP_USER=)" = root ] || [ "$(id -u tsx-panel-app 2>/dev/null)" ] && ok "empty PANEL_APP_USER with no user tsx-panel-app: root" || bad "empty PANEL_APP_USER: $(user_of PANEL_APP_USER=)"
echo "PANEL_APP_USER=$ME" >> "$T/panel-app.conf"
[ "$(user_of)" = "$ME" ] && ok "PANEL_APP_USER names a user that exists: that user" || bad "PANEL_APP_USER=$ME: $(user_of)"
sed -i "s#^PANEL_APP_BIN=.*#PANEL_APP_BIN=$T/bin/old#" "$T/panel-app.conf"
[ "$(user_of)" = root ] && grep -q 'older build' "$T/user.err" && ok "a program without TSX_PANEL_APP_OUT_DIR runs as root" || bad "old program: $(user_of) $(cat "$T/user.err")"
sed -i "s#^PANEL_APP_BIN=.*#PANEL_APP_BIN=$T/bin/app#" "$T/panel-app.conf"
sed -i "s#^PANEL_APP_USER=.*#PANEL_APP_USER=tsx-no-such-user#" "$T/panel-app.conf"
[ "$(user_of)" = root ] && grep -q 'no user tsx-no-such-user' "$T/user.err" && ok "a missing user: root, with a message" || bad "missing user: $(user_of)"
sed -i "s#^PANEL_APP_USER=.*#PANEL_APP_USER=root#" "$T/panel-app.conf"
[ "$(user_of)" = root ] && ok "PANEL_APP_USER=root: root" || bad "root: $(user_of)"

echo "== --prepare: folders, links and sysfs files for the user =="
sed -i "s#^PANEL_APP_USER=.*#PANEL_APP_USER=$ME#" "$T/panel-app.conf"
echo 'PANEL_APP_LEDS="rgb:bar-*"' >> "$T/panel-app.conf"
mkdir -p "$T/prefs" "$T/cpufreq/policy0" "$T/leds/rgb:bar-left" "$T/leds/mmc0::" "$T/rt"
echo 80 > "$T/prefs/backlight"; echo p > "$T/prefs/dev.prefs"; echo t > "$T/prefs/ha-token"; chmod 600 "$T/prefs/ha-token"
for f in "$T/cpufreq/policy0/scaling_min_freq" "$T/cpufreq/policy0/scaling_max_freq" "$T/leds/rgb:bar-left/brightness" \
	"$T/leds/rgb:bar-left/multi_intensity" "$T/leds/mmc0::/brightness"; do echo 0 > "$f"; chmod 644 "$f"; done
echo "on 5" > "$T/idled.state"
export TSX_RUN_DIR="$T/rt/tsx" TSX_IDLED_STATE="$T/idled.state" TSX_SYS_CPUFREQ="$T/cpufreq" TSX_SYS_LEDS="$T/leds"
printf 'TSX_SOUND_CARD=FakeCard\n' > "$T/board.sh"; export TSX_BOARD_CONF="$T/board.sh"
TSX_PANEL_APP_PREPARE_NONROOT=1 TSX_HOSTNAME=h sh "$RUNNER" --prepare > "$T/prep.out" 2>&1 \
	&& grep -q "prepared for the user $ME" "$T/prep.out" && ok "--prepare runs" || bad "--prepare: $(cat "$T/prep.out")"
[ "$(stat -c %a "$T/prefs")" = 711 ] && [ "$(stat -c %a "$T/prefs/app")" = 700 ] && ok "preferences: the folder 711, app/ 700" || bad "preference modes"
[ -f "$T/prefs/app/backlight" ] && [ -f "$T/prefs/app/dev.prefs" ] && [ ! -e "$T/prefs/backlight" ] && [ -f "$T/prefs/ha-token" ] \
	&& ok "the preferences move into app/, the token stays" || bad "preference move: $(ls -R "$T/prefs")"
R=$T/rt/tsx/panel-app
[ "$(stat -c %a "$R")" = 755 ] && [ "$(stat -c '%U %a' "$R/app")" = "$ME 755" ] && [ "$(stat -c '%U' "$R/control.d")" = "$ME" ] \
	&& ok "run folders: panel-app 755, app/ and control.d/ of the user" || bad "run folders: $(ls -la "$R")"
[ "$(readlink "$T/idled.state")" = "$R/app/idled.state" ] && ok "the idle state file is a link into app/" || bad "idled link: $(ls -l "$T/idled.state")"
[ "$(readlink "$T/rt/tsx/panel-app.state")" = "$R/app/panel-app.state" ] && [ "$(readlink "$R/screen.state")" = "$R/app/screen.state" ] \
	&& [ "$(readlink "$R/entities.json")" = "$R/app/entities.json" ] && ok "panel-app.state, screen.state and entities.json are links into app/" || bad "links: $(ls -la "$R")"
for f in cpufreq/policy0/scaling_min_freq cpufreq/policy0/scaling_max_freq leds/rgb:bar-left/brightness leds/rgb:bar-left/multi_intensity; do
	[ "$(stat -c '%G %a' "$T/$f")" = "$MG 664" ] && ok "group write: $f" || bad "group write $f: $(stat -c '%G %a' "$T/$f")"
done
[ "$(stat -c %a "$T/leds/mmc0::/brightness")" = 644 ] && ok "a LED that the board does not name stays as it is" || bad "mmc0 LED changed"
TSX_PANEL_APP_PREPARE_NONROOT=1 TSX_HOSTNAME=h sh "$RUNNER" --prepare > "$T/prep2.out" 2>&1 && ! grep -q 'failed' "$T/prep2.out" \
	&& ok "a second --prepare changes nothing and fails nothing" || bad "second --prepare: $(cat "$T/prep2.out")"
( unset TSX_PANEL_APP_PREPARE_NONROOT; sh "$RUNNER" --prepare ) > "$T/prep3.out" 2>&1 && bad "--prepare as a user ran" || ok "--prepare as a user who is not root refuses"

echo "== the start as the user: the environment of the program =="
TSX_HOSTNAME=h sh "$RUNNER" > "$T/out8" 2>&1
grep -qx "ESPHOME_PREFDIR=$T/prefs/app" "$T/out8" && ok "ESPHOME_PREFDIR: the app/ folder" || bad "prefdir: $(cat "$T/out8")"
grep -qx "TSX_PANEL_APP_OUT_DIR=$R/app" "$T/out8" && ok "TSX_PANEL_APP_OUT_DIR" || bad "out dir: $(cat "$T/out8")"
if [ "$(id -u)" != 0 ]; then
	grep -qx "TSX_PANEL_APP_PANELCTL=$T/rt/tsx/panelctl" "$T/out8" && ok "TSX_PANEL_APP_PANELCTL (not root)" || bad "panelctl: $(cat "$T/out8")"
fi
grep -qx "TSX_PANEL_APP_SOUND_CARD=FakeCard" "$T/out8" && ok "TSX_PANEL_APP_SOUND_CARD from board.sh" || bad "sound card: $(cat "$T/out8")"

echo "== $N passed, $F failed"
[ "$F" = 0 ]
