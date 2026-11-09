#!/bin/bash
# Host test for tsx-conf-migrate: the old full user file becomes a file with
# only the changed lines. It checks the trim, the lines that are not KEY=value
# (buttons.conf), the comments, a rerun (the result must not change), the
# leftover .apk-new, the copy in the backup folder, an empty result, a file
# with no defaults, a value on more than one line and --init.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/tests/lib/paths.sh"
command -v busybox >/dev/null 2>&1 && SH="busybox sh" || SH=sh
TOOL=$(P usr/local/sbin/tsx-conf-migrate)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
export TSX_DEFAULTS_DIR=$T/defaults TSX_ETC_DIR=$T/etc
BAK=$T/bak
mkdir -p "$T/defaults" "$T/etc/tsx" "$BAK"
mig() { $SH "$TOOL" "$@" 2>"$T/err"; }
body() { grep -v '^#' "$1" | grep -v '^$'; }   # the file without the header and the comments
cp "$HERE/kiosk/usr/local/share/tsx/defaults/kiosk.conf" "$HERE/buttons/usr/local/share/tsx/defaults/buttons.conf" "$T/defaults/"

echo "== a full old copy is trimmed =="
cp "$T/defaults/kiosk.conf" "$T/etc/kiosk.conf"
sed -i 's|^KIOSK_URL=""|KIOSK_URL="https://ha.example.org/x"|; s|^BLANK_TIMEOUT=300|BLANK_TIMEOUT=600|; s|^KIOSK_DARK=off|KIOSK_DARK=on|' "$T/etc/kiosk.conf"
printf 'BACKLIGHT_MAX=20\nKIOSK_SCALE=1.0\n' >> "$T/etc/kiosk.conf"
touch "$T/etc/kiosk.conf.apk-new"
mig kiosk.conf && ok "tsx-conf-migrate exits 0" || bad "exit status $?"
eq "$(body "$T/etc/kiosk.conf" | tr '\n' '|')" 'KIOSK_URL="https://ha.example.org/x"|KIOSK_DARK=on|BLANK_TIMEOUT=600|BACKLIGHT_MAX=20|' "only the changed keys stay, and a new key"
[ -e "$T/etc/kiosk.conf.apk-new" ] && bad "the .apk-new file stays" || ok "the .apk-new file is gone"
[ -e "$T/etc/kiosk.conf.pre-split" ] && bad "a .pre-split file for a file with no added comment" || ok "no .pre-split file when no comment was added"
head -n 1 "$T/etc/kiosk.conf" | grep -q "^# $T/etc/kiosk.conf: " && grep -q "$T/defaults/kiosk.conf" "$T/etc/kiosk.conf" && ok "the header names the file and the defaults file" || bad "no header"
# the result gives the same values as the old file, with the defaults under it
vals() { env -i PATH="$PATH" TSX_DEFAULTS_DIR="$T/defaults" sh -c ". '$(P usr/local/lib/tsx/conf.sh)'; tsx_conf_load kiosk.conf '$1'; echo \"\$KIOSK_URL|\$BLANK_TIMEOUT|\$KIOSK_DARK|\$BACKLIGHT_MAX|\$KIOSK_SCALE|\$KIOSK_GPU\""; }
cp "$T/defaults/kiosk.conf" "$T/old.conf"; sed -i 's|^KIOSK_URL=""|KIOSK_URL="https://ha.example.org/x"|; s|^BLANK_TIMEOUT=300|BLANK_TIMEOUT=600|; s|^KIOSK_DARK=off|KIOSK_DARK=on|' "$T/old.conf"; printf 'BACKLIGHT_MAX=20\nKIOSK_SCALE=1.0\n' >> "$T/old.conf"
eq "$(vals "$T/etc/kiosk.conf")" "$(env -i PATH="$PATH" sh -c ". '$T/old.conf'; echo \"\$KIOSK_URL|\$BLANK_TIMEOUT|\$KIOSK_DARK|\$BACKLIGHT_MAX|\$KIOSK_SCALE|\$KIOSK_GPU\"")" "the layers of the new file give the values of the old file"
echo "== a rerun =="
cp "$T/etc/kiosk.conf" "$T/first.conf"
mig kiosk.conf; cmp -s "$T/first.conf" "$T/etc/kiosk.conf" && ok "a second run gives the same file" || bad "a second run changed the file"
mig kiosk.conf; cmp -s "$T/first.conf" "$T/etc/kiosk.conf" && ok "a third run gives the same file" || bad "a third run changed the file"

echo "== comments =="
cp "$T/defaults/kiosk.conf" "$T/etc/kiosk.conf"
{ printf '# my note about the screen\nBLANK_TIMEOUT=900\n\n# a lost note\n\n'; printf 'KIOSK_SCALE=1.2\n'; } >> "$T/etc/kiosk.conf"
sed -i 's|^KIOSK_RESTART_AT=.*|KIOSK_RESTART_AT="05:00"  # later|' "$T/etc/kiosk.conf"
mig kiosk.conf
grep -qx '# my note about the screen' "$T/etc/kiosk.conf" && ok "a comment above a kept line stays" || bad "the added comment is gone"
grep -q 'a lost note' "$T/etc/kiosk.conf" && bad "a comment that is apart from a kept line stays" || ok "a comment that is apart from a kept line goes"
grep -qx 'KIOSK_RESTART_AT="05:00"  # later' "$T/etc/kiosk.conf" && ok "a comment at the end of a kept line stays" || bad "the end-of-line comment is gone"
[ -s "$T/etc/kiosk.conf.pre-split" ] && grep -q 'a lost note' "$T/etc/kiosk.conf.pre-split" && ok "the old file is saved as .pre-split" || bad "no .pre-split with the old file"
cp "$T/etc/kiosk.conf" "$T/c1.conf"; mig kiosk.conf
cmp -s "$T/c1.conf" "$T/etc/kiosk.conf" && ok "a rerun with comments gives the same file" || bad "a rerun with comments changed the file"
rm -f "$T/etc/kiosk.conf.pre-split"

echo "== the same key twice =="
cp "$T/defaults/kiosk.conf" "$T/etc/kiosk.conf"
printf 'BLANK_TIMEOUT=500\nBLANK_TIMEOUT=300\nKIOSK_SCALE=2\nKIOSK_SCALE=1.5\n' >> "$T/etc/kiosk.conf"
mig kiosk.conf
eq "$(body "$T/etc/kiosk.conf" | tr '\n' '|')" "KIOSK_SCALE=1.5|" "the last value counts: back to the default is no line, the other key keeps the last value"

echo "== a value with a variable stays =="
cp "$T/defaults/kiosk.conf" "$T/etc/kiosk.conf"
printf 'BASE=https://ha.example.org\nKIOSK_URL="$BASE/x"\n' >> "$T/etc/kiosk.conf"
mig kiosk.conf
eq "$(body "$T/etc/kiosk.conf" | tr '\n' '|')" 'BASE=https://ha.example.org|KIOSK_URL="$BASE/x"|' "a value with a variable stays as it is, in the order of the old file"
cp "$T/defaults/kiosk.conf" "$T/etc/kiosk.conf"
printf 'KIOSK_EXTRA_FLAGS="$KIOSK_EXTRA_FLAGS --more"\n' >> "$T/etc/kiosk.conf"
mig kiosk.conf
eq "$(body "$T/etc/kiosk.conf" | wc -l)" "2" "a value that uses the earlier value of its own key keeps the earlier line too"

echo "== nothing changed: the short file =="
cp "$T/defaults/kiosk.conf" "$T/etc/kiosk.conf"
mig kiosk.conf
eq "$(body "$T/etc/kiosk.conf" | wc -l)" "0" "no line besides the header"
eq "$(wc -l < "$T/etc/kiosk.conf")" "3" "the header has 3 lines"
grep -q "$T/defaults/kiosk.conf" "$T/etc/kiosk.conf" && ok "the header points to the defaults file" || bad "the header does not name the defaults file"
cp "$T/etc/kiosk.conf" "$T/e1.conf"; mig kiosk.conf; cmp -s "$T/e1.conf" "$T/etc/kiosk.conf" && ok "a rerun on the short file gives the same file" || bad "a rerun changed the short file"

echo "== buttons.conf: button and on lines =="
cp "$T/defaults/buttons.conf" "$T/etc/tsx/buttons.conf"
sed -i 's|^LED_DAY=128|LED_DAY=200|' "$T/etc/tsx/buttons.conf"
printf 'button prog KEY_PROG1 led=1\non prog short exec tsx-blank\non prog long overlay full\n' >> "$T/etc/tsx/buttons.conf"
mig buttons.conf
eq "$(body "$T/etc/tsx/buttons.conf" | tr '\n' '|')" "LED_DAY=200|button prog KEY_PROG1 led=1|on prog short exec tsx-blank|on prog long overlay full|" "setting changes and the button and on lines stay, in order"
cp "$T/etc/tsx/buttons.conf" "$T/b1.conf"; mig buttons.conf; cmp -s "$T/b1.conf" "$T/etc/tsx/buttons.conf" && ok "a rerun gives the same file" || bad "a rerun changed buttons.conf"
printf 'on prog short exec same\n' >> "$T/defaults/buttons.conf"
cp "$T/defaults/buttons.conf" "$T/etc/tsx/buttons.conf"; printf 'on prog short exec mine\n' >> "$T/etc/tsx/buttons.conf"
mig buttons.conf
eq "$(body "$T/etc/tsx/buttons.conf" | tr '\n' '|')" "on prog short exec mine|" "a line that the defaults have too goes away, another one stays"
cp "$HERE/buttons/usr/local/share/tsx/defaults/buttons.conf" "$T/defaults/buttons.conf"

echo "== the copy in the backup folder =="
rm -f "$T/etc/kiosk.conf"
cp "$T/defaults/kiosk.conf" "$BAK/kiosk.conf"; sed -i 's|^KIOSK_SCALE=1.0|KIOSK_SCALE=1.3|' "$BAK/kiosk.conf"
touch "$T/etc/kiosk.conf.apk-new"
mig --backup-dir "$BAK" kiosk.conf
eq "$(body "$T/etc/kiosk.conf" | tr '\n' '|')" "KIOSK_SCALE=1.3|" "the user file is made from the copy when apk deleted the old file"
[ -e "$BAK/kiosk.conf" ] && bad "the copy stays in the backup folder" || ok "the copy in the backup folder is gone"
[ -e "$T/etc/kiosk.conf.apk-new" ] && bad ".apk-new stays" || ok ".apk-new is gone"
# apk kept an edited file, and the folder has a copy: the copy counts
cp "$T/defaults/kiosk.conf" "$T/etc/kiosk.conf"; sed -i 's|^KIOSK_SCALE=1.0|KIOSK_SCALE=1.9|' "$T/etc/kiosk.conf"
cp "$T/defaults/kiosk.conf" "$BAK/kiosk.conf"; sed -i 's|^KIOSK_SCALE=1.0|KIOSK_SCALE=1.4|' "$BAK/kiosk.conf"
mig --backup-dir "$BAK" kiosk.conf
eq "$(body "$T/etc/kiosk.conf" | tr '\n' '|')" "KIOSK_SCALE=1.4|" "the copy of the old package wins over the file in /etc"
rm -f "$T/etc/kiosk.conf.pre-split"

echo "== two names in one call, and a name with no file =="
rm -f "$T/etc/kiosk.conf" "$T/etc/tsx/buttons.conf"
mig kiosk.conf buttons.conf
[ -s "$T/etc/kiosk.conf" ] && [ -s "$T/etc/tsx/buttons.conf" ] && ok "no file and no copy: the short file for each name" || bad "short files missing"
eq "$(body "$T/etc/kiosk.conf" | wc -l)" "0" "the short file has no setting"

echo "== --init =="
rm -f "$T/etc/tsx/buttons.conf"
mig --init buttons.conf
[ -s "$T/etc/tsx/buttons.conf" ] && [ "$(body "$T/etc/tsx/buttons.conf" | wc -l)" = 0 ] && ok "--init writes the short file when the user file is missing" || bad "--init did not write the file"
printf 'LED_DAY=1\n' > "$T/etc/tsx/buttons.conf"
mig --init buttons.conf
eq "$(cat "$T/etc/tsx/buttons.conf")" "LED_DAY=1" "--init leaves an existing user file as it is"

echo "== a defaults file that is missing =="
printf 'KIOSK_SCALE=7\n' > "$T/etc/tsx/ledbar.conf"
mig ledbar.conf; rc=$?
eq "$(cat "$T/etc/tsx/ledbar.conf")" "KIOSK_SCALE=7" "no defaults file: the user file stays as it is"
[ "$rc" != 0 ] && ok "exit status is not 0" || bad "exit status 0 with no defaults file"

echo "== a value on more than one line =="
cp "$T/defaults/kiosk.conf" "$T/etc/kiosk.conf"; printf 'KIOSK_EXTRA_FLAGS="--a\n --b"\n' >> "$T/etc/kiosk.conf"
cp "$T/etc/kiosk.conf" "$T/ml.conf"
mig kiosk.conf
cmp -s "$T/ml.conf" "$T/etc/kiosk.conf" && ok "the file stays as it is" || bad "the file with a multi-line value changed"

echo "== a bad call =="
mig; [ $? = 2 ] && ok "no name: exit 2" || bad "no name"
mig ../etc/passwd; [ $? = 2 ] && ok "a path is no name: exit 2" || bad "path as name"
echo "== $N ok, $F failed =="
[ "$F" = 0 ]
