#!/bin/bash
# Host test: `tsx-config apply` (docs/rootfs.md "Panel configuration")
# against a fixture directory standing in for the panel's root, via
# TSX_APPLY_PREFIX/TSX_RUN/TSX_STATE_DIR/TSX_APPLY_ALLOW_NONROOT. No docker,
# no real /etc/shadow or /root/.ssh is ever touched.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$HERE/overlay/usr/local/sbin/tsx-config"
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED test-tsx-config-apply: no busybox on this host"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
CFG="$W/panel.conf"
FX="$W/fixture"
mkdir -p "$FX/etc" "$FX/root" "$FX/var/lib/kiosk"
echo 'root:!:19000:0:99999:7:::' > "$FX/etc/shadow"
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }
set_() { TSX_CONF="$CFG" busybox sh "$SCRIPT" set "$@"; }
apply_() { env TSX_CONF="$CFG" TSX_RUN="$FX/run" TSX_STATE_DIR="$FX/var/lib/tsx" TSX_APPLY_PREFIX="$FX" TSX_APPLY_ALLOW_NONROOT=1 busybox sh "$SCRIPT" apply; }

echo "== apply with no panel.conf at all is a no-op (never fails) =="
env TSX_CONF="$W/nope/panel.conf" TSX_RUN="$FX/run" TSX_STATE_DIR="$FX/var/lib/tsx" TSX_APPLY_PREFIX="$FX" TSX_APPLY_ALLOW_NONROOT=1 busybox sh "$SCRIPT" apply >/dev/null 2>&1
[ $? = 0 ] && ok "apply with no config exits 0" || bad "apply with no config failed"
[ ! -e "$FX/run/tsx/kiosk.conf" ] && ok "no /run/tsx/kiosk.conf written" || bad "kiosk.conf written with nothing to apply"

echo "== apply requires root unless TSX_APPLY_ALLOW_NONROOT=1 =="
set_ PANEL_NAME TSS-10-AABBCC >/dev/null
env TSX_CONF="$CFG" TSX_RUN="$FX/run" busybox sh "$SCRIPT" apply >/dev/null 2>&1 && bad "apply ran without root and without the test override" || ok "apply refuses non-root without the override"

echo "== build a full panel.conf and apply it =="
set_ KIOSK_URL "https://ha.example.org/lovelace/default_view" >/dev/null
set_ TZ_NAME "America/Denver" >/dev/null
set_ MQTT_HOST "192.0.2.5" >/dev/null
set_ MQTT_PORT "1883" >/dev/null
set_ MQTT_USER "tss10" >/dev/null
set_ MQTT_PASSWORD "hunter2" >/dev/null
set_ HA_LOGIN_METHOD token >/dev/null
set_ HA_TOKEN "abcdefghijklmnopqrstuvwxyz0123456789ABCDEF" >/dev/null
set_ ROOT_PASSWORD_HASH '$6$abcdefgh$somehashvalueherelongenough' >/dev/null
set_ SSH_AUTHORIZED_KEY "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI test@host" >/dev/null
set_ WAKE_WORD hey_jarvis >/dev/null
apply_ >/dev/null 2>&1
[ $? = 0 ] && ok "apply exits 0" || bad "apply failed"

[ "$(cat "$FX/run/tsx/panel-name" 2>/dev/null)" = TSS-10-AABBCC ] && ok "panel-name written" || bad "panel-name missing/wrong"
grep -q '^SENDSPIN_NAME="TSS-10-AABBCC"$' "$FX/run/tsx/sendspin.conf" 2>/dev/null && ok "sendspin.conf override has SENDSPIN_NAME" || bad "sendspin.conf override wrong"
grep -q '^NAME="TSS-10-AABBCC"$' "$FX/run/tsx/voice.conf" 2>/dev/null && ok "voice.conf override has NAME" || bad "voice.conf override wrong (NAME)"
grep -q '^WAKE_WORD="hey_jarvis"$' "$FX/run/tsx/voice.conf" 2>/dev/null && ok "voice.conf override has WAKE_WORD" || bad "voice.conf override wrong (WAKE_WORD)"
grep -q '^KIOSK_URL="https://ha.example.org/lovelace/default_view"$' "$FX/run/tsx/kiosk.conf" 2>/dev/null && ok "kiosk.conf override has KIOSK_URL" || bad "kiosk.conf override wrong"
grep -q '^TZ_NAME="America/Denver"$' "$FX/run/tsx/kiosk.conf" 2>/dev/null && ok "kiosk.conf override has TZ_NAME" || bad "kiosk.conf override missing TZ_NAME"
[ "$(stat -c '%a' "$FX/run/tsx/kiosk.conf" 2>/dev/null)" = 644 ] && ok "kiosk.conf override is mode 644 (kiosk-session reads it as the kiosk user)" || bad "kiosk.conf override not readable by the kiosk user"
grep -q '^BROKER="192.0.2.5"$' "$FX/run/tsx/mqtt.conf" 2>/dev/null && ok "mqtt.conf override has BROKER" || bad "mqtt.conf override wrong"
[ "$(stat -c '%a' "$FX/run/tsx/mqtt.conf" 2>/dev/null)" = 600 ] && ok "mqtt.conf override is mode 600 (carries MQTT_PASSWORD)" || bad "mqtt.conf override not mode 600"

echo "== the generated overrides are valid, safely sourceable shell =="
busybox sh -c '. "'"$FX"'/run/tsx/mqtt.conf"; [ "$PASSWORD" = "hunter2" ]' && ok "mqtt.conf sources back to the original password" || bad "mqtt.conf did not source back correctly"

echo "== HA token staged for the kiosk, root shadow hash updated, ssh key added =="
[ "$(cat "$FX/var/lib/kiosk/pending-token" 2>/dev/null)" = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEF" ] && ok "pending-token staged" || bad "pending-token missing/wrong"
grep -q '^root:\$6\$abcdefgh\$somehashvalueherelongenough:' "$FX/etc/shadow" && ok "root shadow hash updated" || bad "root shadow hash not updated"
grep -qxF "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI test@host" "$FX/root/.ssh/authorized_keys" && ok "ssh key present" || bad "ssh key missing"
[ "$(stat -c '%a' "$FX/root/.ssh/authorized_keys" 2>/dev/null)" = 600 ] && ok "authorized_keys mode 600" || bad "authorized_keys mode wrong"

echo "== re-apply is idempotent: no duplicate key line, shadow untouched again =="
SHADOW_BEFORE=$(cat "$FX/etc/shadow")
apply_ >/dev/null 2>&1
[ "$(cat "$FX/etc/shadow")" = "$SHADOW_BEFORE" ] && ok "shadow unchanged on re-apply" || bad "shadow changed on a no-op re-apply"
[ "$(wc -l < "$FX/root/.ssh/authorized_keys")" = 1 ] && ok "authorized_keys still has exactly one line" || bad "authorized_keys grew a duplicate"

echo "== a manually-added extra ssh key survives apply (panel.conf never removes a key) =="
echo "ssh-ed25519 AAAAOTHERKEY someone@elsewhere" >> "$FX/root/.ssh/authorized_keys"
apply_ >/dev/null 2>&1
[ "$(wc -l < "$FX/root/.ssh/authorized_keys")" = 2 ] && ok "both keys present after another apply" || bad "an existing key was lost"

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo PASS test-tsx-config-apply || echo FAIL test-tsx-config-apply
exit $F
