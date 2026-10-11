#!/bin/bash
# Host test for the package tsx-sendspin (sendspin/, docs/sendspin.md):
#  - the plugin sendspin.sh of tsx-config: the key SENDSPIN, apply on and
#    off (the runlevel and the start, faked), no change without the key, the
#    boot apply inside an OpenRC service, a panel with no sound card
#  - the service runs as the user tsx-sendspin, not as kiosk
set -uo pipefail
. "$(dirname "$0")/lib/board.sh"
HERE=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$HERE/base/usr/local/sbin/tsx-config"
PLUGIN="$HERE/sendspin/usr/local/lib/tsx/config.d/sendspin.sh"
INIT="$HERE/sendspin/etc/init.d/tsx-sendspin"
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED test-sendspin: no busybox on this host"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }

mkdir -p "$W/pd" "$W/fx/etc" "$W/fx/run" "$W/rl" "$W/bin"
cp "$PLUGIN" "$W/pd/"; chmod 755 "$W/pd"; chmod 644 "$W/pd/sendspin.sh"
echo 'root:!:19000:0:99999:7:::' > "$W/fx/etc/shadow"
# Fake rc-update and rc-service: they log the call. rc-update add/del also
# makes or removes the runlevel entry.
cat > "$W/bin/rc-update" <<EOS
#!/bin/sh
echo "rc-update \$*" >> "$W/rc.log"
case "\$1" in add) : > "$W/rl/\$2";; del) rm -f "$W/rl/\$2";; esac
EOS
printf '#!/bin/sh\necho "rc-service $*" >> "%s/rc.log"\n' "$W" > "$W/bin/rc-service"
chmod 755 "$W/bin/rc-update" "$W/bin/rc-service"
CFG="$W/panel.conf"
run() { env TSX_CONF="$CFG" TSX_CONFIG_PLUGIN_DIR="$W/pd" TSX_PLUGIN_OWNER_UID="$(id -u)" busybox sh "$SCRIPT" "$@"; }
apply_() { env "$@" PATH="$W/bin:$PATH" TSX_CONF="$CFG" TSX_RUN="$W/fx/run" TSX_STATE_DIR="$W/fx/var/lib/tsx" TSX_APPLY_PREFIX="$W/fx" \
	TSX_APPLY_ALLOW_NONROOT=1 TSX_CONFIG_PLUGIN_DIR="$W/pd" TSX_PLUGIN_OWNER_UID="$(id -u)" TSX_RUNLEVEL_DIR="$W/rl" \
	TSX_RC_UPDATE_BIN="$W/bin/rc-update" TSX_RC_SERVICE_BIN="$W/bin/rc-service" busybox sh "$SCRIPT" apply 2>&1; }

busybox sh -n "$PLUGIN" && ok "busybox sh -n of the plugin" || bad "busybox sh -n of the plugin"
busybox sh -n "$INIT" && ok "busybox sh -n of the service" || bad "busybox sh -n of the service"

echo "== the key SENDSPIN =="
for v in on off; do run validate SENDSPIN "$v" && ok "SENDSPIN=$v is valid" || bad "SENDSPIN=$v rejected"; done
for v in "" yes 1 ON; do run validate SENDSPIN "$v" 2>/dev/null && bad "SENDSPIN='$v' accepted" || ok "SENDSPIN='$v' is invalid"; done

echo "== apply without the key: no change of the runlevel =="
: > "$W/rc.log"; apply_ TSX_SOUND_CARD=FakeCard > "$W/a0.log"
grep -q 'tsx-sendspin' "$W/rc.log" && bad "apply without SENDSPIN touched the player: $(cat "$W/rc.log")" || ok "no rc-update and no rc-service for the player"

echo "== SENDSPIN=on =="
run set SENDSPIN on >/dev/null 2>&1
: > "$W/rc.log"; apply_ TSX_SOUND_CARD=FakeCard > "$W/a1.log"
for s in dbus avahi-daemon tsx-sendspin; do
	grep -qx "rc-update add $s default" "$W/rc.log" && grep -qx "rc-service -q $s start" "$W/rc.log" && ok "$s: added and started" || bad "$s: $(cat "$W/rc.log")"
done
grep -q 'SENDSPIN=on: tsx-sendspin added' "$W/a1.log" && ok "apply logs the change" || bad "log: $(cat "$W/a1.log")"
: > "$W/rc.log"; apply_ TSX_SOUND_CARD=FakeCard > "$W/a2.log"
grep -q 'added to the default runlevel' "$W/a2.log" && bad "a second apply logs again" || ok "a second apply logs nothing new"
echo "== the boot apply (RC_SVCNAME set): only the runlevel =="
rm -f "$W/rl/tsx-sendspin"; : > "$W/rc.log"; apply_ TSX_SOUND_CARD=FakeCard RC_SVCNAME=tsx-config > /dev/null
grep -qx "rc-update add tsx-sendspin default" "$W/rc.log" && ! grep -q '^rc-service' "$W/rc.log" && ok "added, nothing started" || bad "boot apply: $(cat "$W/rc.log")"

echo "== SENDSPIN=off =="
run set SENDSPIN off >/dev/null 2>&1
: > "$W/rc.log"; apply_ TSX_SOUND_CARD=FakeCard > "$W/a3.log"
grep -qx "rc-service -q tsx-sendspin stop" "$W/rc.log" && grep -qx "rc-update del tsx-sendspin default" "$W/rc.log" && ok "stopped and taken out of the runlevel" || bad "off: $(cat "$W/rc.log")"
grep -q 'dbus\|avahi' "$W/rc.log" && bad "off touched dbus or avahi-daemon" || ok "dbus and avahi-daemon stay"
: > "$W/rc.log"; apply_ TSX_SOUND_CARD=FakeCard > /dev/null
[ ! -s "$W/rc.log" ] && ok "off again: nothing to do" || bad "off again: $(cat "$W/rc.log")"

echo "== a panel with no sound card =="
run set SENDSPIN on >/dev/null 2>&1
printf '. "%s"\nTSX_SOUND_CARD=\n' "$TSX_BOARD_CONF" > "$W/board-nosound.sh"
: > "$W/rc.log"; apply_ TSX_BOARD_CONF="$W/board-nosound.sh" > "$W/a4.log"
grep -q 'add tsx-sendspin' "$W/rc.log" && bad "no sound card: the player was enabled" || ok "no sound card: the player stays off"
grep -q 'WARNING: SENDSPIN=on is set, but this panel has no sound card' "$W/a4.log" && ok "no sound card: a warning" || bad "warning: $(cat "$W/a4.log")"

echo "== the service =="
grep -q '^SENDSPIN_USER=tsx-sendspin$' "$INIT" && grep -q 'command_user="$SENDSPIN_USER:audio"' "$INIT" && ok "the player runs as tsx-sendspin in the group audio" || bad "the user of the service"
grep -n 'kiosk' "$INIT" | grep -v '^[0-9]*:[[:space:]]*#' | grep -q . && bad "the service still names kiosk outside a comment" || ok "the service needs no kiosk"

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo PASS test-sendspin || echo FAIL test-sendspin
exit $F
