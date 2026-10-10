#!/bin/sh
# Host test: the tsx-config plugin of the panel app
# (panel-app/usr/local/lib/tsx/config.d/panel_app.sh, docs/panel-app.md
# "Screen"). It runs tsx-config under busybox sh against a throwaway
# panel.conf and checks:
#  - DIM_TIMEOUT and DIM_LEVEL: set, get, the limits, unset
#  - apply: $RUN/dim-timeout, $RUN/dim-level and $RUN/blank-timeout, mode 644,
#    and their removal when the key is not set
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/tests/lib/board.sh"
SCRIPT=$HERE/base/usr/local/sbin/tsx-config
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED test-panel-app-config: no busybox on this host"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
ME=$(id -u)
CFG=$W/panel.conf
FX=$W/fixture
RUNDIR=$FX/run/tsx
mkdir -p "$FX/etc" "$FX/root" "$RUNDIR" "$W/pd"
echo 'root:!:19000:0:99999:7:::' > "$FX/etc/shadow"
chmod 755 "$W/pd"
cp "$HERE/panel-app/usr/local/lib/tsx/config.d/panel_app.sh" "$W/pd/"
chmod 644 "$W/pd/panel_app.sh"
: > "$W/hw.conf"
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }

run() { env TSX_CONF="$CFG" TSX_CONFIG_PLUGIN_DIR="$W/pd" TSX_PLUGIN_OWNER_UID="$ME" TSX_HW_CONF="$W/hw.conf" busybox sh "$SCRIPT" "$@"; }
apply_() { env TSX_CONF="$CFG" TSX_RUN="$FX/run" TSX_STATE_DIR="$FX/var/lib/tsx" TSX_APPLY_PREFIX="$FX" TSX_APPLY_ALLOW_NONROOT=1 \
	TSX_CONFIG_PLUGIN_DIR="$W/pd" TSX_PLUGIN_OWNER_UID="$ME" TSX_HW_CONF="$W/hw.conf" busybox sh "$SCRIPT" apply >"$W/apply.log" 2>&1; }

echo "== keys =="
run set DIM_TIMEOUT 30 2>/dev/null && ok "set DIM_TIMEOUT 30" || bad "set DIM_TIMEOUT 30"
[ "$(run get DIM_TIMEOUT)" = 30 ] && ok "get DIM_TIMEOUT" || bad "get DIM_TIMEOUT: $(run get DIM_TIMEOUT)"
run set DIM_LEVEL 25 2>/dev/null && ok "set DIM_LEVEL 25" || bad "set DIM_LEVEL 25"
run set BLANK_TIMEOUT 120 2>/dev/null && ok "set BLANK_TIMEOUT 120" || bad "set BLANK_TIMEOUT 120"
for v in -1 86401 abc 1.5 ""; do
	run validate DIM_TIMEOUT "$v" 2>/dev/null && bad "DIM_TIMEOUT '$v' passes" || ok "DIM_TIMEOUT '$v' is refused"
done
for v in 0 101 x; do
	run validate DIM_LEVEL "$v" 2>/dev/null && bad "DIM_LEVEL '$v' passes" || ok "DIM_LEVEL '$v' is refused"
done
run validate DIM_TIMEOUT 0 2>/dev/null && ok "DIM_TIMEOUT 0 (never) passes" || bad "DIM_TIMEOUT 0 is refused"
run validate DIM_LEVEL 100 2>/dev/null && ok "DIM_LEVEL 100 passes" || bad "DIM_LEVEL 100 is refused"

echo "== apply =="
apply_ && ok "apply" || bad "apply: $(cat "$W/apply.log")"
[ "$(cat "$RUNDIR/dim-timeout" 2>/dev/null)" = 30 ] && ok "dim-timeout is 30" || bad "dim-timeout: $(cat "$RUNDIR/dim-timeout" 2>&1)"
[ "$(cat "$RUNDIR/dim-level" 2>/dev/null)" = 25 ] && ok "dim-level is 25" || bad "dim-level: $(cat "$RUNDIR/dim-level" 2>&1)"
[ "$(cat "$RUNDIR/blank-timeout" 2>/dev/null)" = 120 ] && ok "blank-timeout is 120" || bad "blank-timeout: $(cat "$RUNDIR/blank-timeout" 2>&1)"
m=$(stat -c %a "$RUNDIR/dim-timeout" 2>/dev/null)
[ "$m" = 644 ] && ok "dim-timeout has mode 644" || bad "dim-timeout mode $m"
grep -qi 'plugin\|dim' "$W/apply.log" && bad "apply warns about the plugin: $(cat "$W/apply.log")" || ok "apply has no line about the plugin"
run unset DIM_TIMEOUT 2>/dev/null && run unset DIM_LEVEL 2>/dev/null && apply_
[ ! -e "$RUNDIR/dim-timeout" ] && [ ! -e "$RUNDIR/dim-level" ] && ok "unset keys remove their files" || bad "files left: $(ls "$RUNDIR")"

echo "== test-panel-app-config: $N ok, $F failed =="
[ "$F" = 0 ]
