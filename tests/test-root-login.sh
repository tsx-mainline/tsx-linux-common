#!/bin/sh
# Host test for the root login (see tsx-rootpw). It needs no panel,
# no compiler and no container.
#   - first boot: tsx-config apply puts ROOT_PASSWORD_HASH and the SSH key in
#     place, and a password that a person sets later survives the next boot
#   - no password (key only): the root field stays locked, never empty,
#     tsx-rootpw, and the banner that says which case applies (password set,
#     key only, nothing at all)
#   - the console login never asks for a new password (no empty-password state)
# The installer prompt and the image build step have their tests in the family repos.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
CONFIG=$HERE/base/usr/local/sbin/tsx-config
RPW=$HERE/base/usr/local/bin/tsx-rootpw
PROF=$HERE/base/etc/profile.d/tsx.sh
BAN=$HERE/base/usr/local/sbin/tsx-banner
ART=$HERE/base/etc/tsx/banner.art
SSHD=$HERE/base/etc/ssh/sshd_config.d/tsx.conf
. "$HERE/tests/lib/board.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
HASH='$6$abcdefgh$somehashvalueherelongenough'
HASH2='$6$ijklmnop$anotherhashvalueherelongenough'
root_field() { awk -F: '$1 == "root" { print $2 }' "$1"; }

echo "== syntax =="
for f in "$RPW" "$PROF" "$BAN"; do busybox sh -n "$f" && ok "${f##*/} passes busybox sh -n" || bad "${f##*/}: busybox sh -n"; done

echo "== first boot: tsx-config apply =="
CFG=$T/panel.conf; FX=$T/fx; mkdir -p "$FX/etc" "$FX/root" "$FX/var/lib/kiosk"
reset_fx() { rm -rf "$FX/var/lib/tsx" "$FX/root/.ssh"; printf 'root:*:19000:0:99999:7:::\nbin:!:19000:0:99999:7:::\n' > "$FX/etc/shadow"; }
apply_() { env TSX_CONF="$CFG" TSX_RUN="$FX/run" TSX_STATE_DIR="$FX/var/lib/tsx" TSX_APPLY_PREFIX="$FX" TSX_APPLY_ALLOW_NONROOT=1 busybox sh "$CONFIG" apply >/dev/null 2>&1; }
set_() { TSX_CONF="$CFG" busybox sh "$CONFIG" set "$@" >/dev/null; }
unset_() { TSX_CONF="$CFG" busybox sh "$CONFIG" unset "$@" >/dev/null; }
KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI test@host'
reset_fx; : > "$CFG"
apply_
eq "$(root_field "$FX/etc/shadow")" "*" "no ROOT_PASSWORD_HASH: the field stays locked"
[ ! -e "$FX/root/.ssh/authorized_keys" ] && ok "no key in panel.conf: no authorized_keys" || bad "authorized_keys without a key"
set_ ROOT_PASSWORD_HASH "$HASH"; set_ SSH_AUTHORIZED_KEY "$KEY"
apply_
eq "$(root_field "$FX/etc/shadow")" "$HASH" "first boot: the hash from panel.conf is in /etc/shadow"
grep -qxF "$KEY" "$FX/root/.ssh/authorized_keys" 2>/dev/null && ok "first boot: the SSH key is in authorized_keys" || bad "first boot: no SSH key"
eq "$(sed -n '2p' "$FX/etc/shadow")" "bin:!:19000:0:99999:7:::" "the other accounts are not touched"
grep -q 'abcdefgh\|somehash' "$FX/var/lib/tsx/.root-hash-applied" 2>/dev/null && bad "the state file holds the hash" || ok "the state file holds a checksum, not the hash"
# a person sets a new password on the console: the next boot keeps it
sed -i "s|^root:[^:]*:|root:\$6\$localset\$typedonconsolevaluehere:|" "$FX/etc/shadow"
cur=$(root_field "$FX/etc/shadow"); apply_
eq "$(root_field "$FX/etc/shadow")" "$cur" "a password set on the console survives the next boot"
# a new hash in panel.conf (setup page, installer) is applied once
set_ ROOT_PASSWORD_HASH "$HASH2"; apply_
eq "$(root_field "$FX/etc/shadow")" "$HASH2" "a changed ROOT_PASSWORD_HASH is applied"
# a reinstall: the same panel.conf on /data, a new image with an empty field
printf 'root:*:19000:0:99999:7:::\nbin:!:19000:0:99999:7:::\n' > "$FX/etc/shadow"; rm -rf "$FX/root/.ssh"; apply_
eq "$(root_field "$FX/etc/shadow")" "$HASH2" "reinstall: the hash is applied again to the locked field"
grep -qxF "$KEY" "$FX/root/.ssh/authorized_keys" 2>/dev/null && ok "reinstall: the key is applied again" || bad "reinstall: no key"
# a locked field (a build of another kind)
printf 'root:*::0:::::\n' > "$FX/etc/shadow"; apply_
eq "$(root_field "$FX/etc/shadow")" "$HASH2" "a locked field gets the hash too"
# key only: the password stays locked, the key is in place
unset_ ROOT_PASSWORD_HASH; reset_fx; apply_
eq "$(root_field "$FX/etc/shadow")" "*" "key only: the root password stays locked"
grep -qxF "$KEY" "$FX/root/.ssh/authorized_keys" 2>/dev/null && ok "key only: ssh gets the key" || bad "key only: no key"
# an empty field (a broken image) is locked, never left open
printf 'root::19000:0:99999:7:::\nbin:!:19000:0:99999:7:::\n' > "$FX/etc/shadow"; apply_
eq "$(root_field "$FX/etc/shadow")" "*" "an empty root field is locked at the first boot"
eq "$(sed -n '2p' "$FX/etc/shadow")" "bin:!:19000:0:99999:7:::" "the lock leaves the other accounts alone"
unset_ SSH_AUTHORIZED_KEY

echo "== no password: tsx-rootpw =="
SH=$T/shadow AK=$T/authorized_keys
rp() { env TSX_SHADOW_FILE="$SH" TSX_AUTH_KEYS_FILE="$AK" busybox sh "$RPW" "$@"; }
printf 'root::19000:0:::::\n' > "$SH";             eq "$(rp state)" "empty" "empty field: state empty (an error state)"
printf 'root:!:19000:0:::::\n' > "$SH";            eq "$(rp state)" "locked" "field !: state locked"
printf 'root:*::0:::::\n' > "$SH";                 eq "$(rp state)" "locked" "field *: state locked"
printf 'root:%s:19000:0:::::\n' "$HASH" > "$SH";   eq "$(rp state)" "set" "a hash: state set"
printf 'bin:!:19000:0:::::\n' > "$SH";             eq "$(rp state)" "locked" "no root line: not a usable password"
eq "$(env TSX_SHADOW_FILE="$T/none" busybox sh "$RPW" state)" "" "a shadow file that cannot be read: no answer (not root)"
rp login >/dev/null 2>&1 && bad "tsx-rootpw still has a login mode" || ok "tsx-rootpw has no login mode (no forced password change)"
grep -q 'passwd root\|PASSWD' "$RPW" && bad "tsx-rootpw still calls passwd" || ok "tsx-rootpw never runs passwd"
echo "$KEY" > "$AK"
printf 'root:*::0:::::\n' > "$SH"
rp note | grep -q 'no password is set' && rp note | grep -q 'over SSH with your key' && ok "note (key only): says no password, log in over SSH with the key" || bad "note (key only) wrong"
printf 'root:%s:19000:0:::::\n' "$HASH" > "$SH"; rp note | grep -q 'password is set' && ok "note (password set)" || bad "note (set) wrong"
: > "$AK"; printf 'root:*::0:::::\n' > "$SH"
rp note | grep -q 'Nobody can log in' && ok "note (locked, no key): says nobody can log in" || bad "note (no key) wrong"
printf 'root::19000:0:::::\n' > "$SH"; rp note | grep -q 'WARNING' && ok "note (empty field): warns" || bad "note (empty) wrong"

echo "== /etc/profile.d/tsx.sh: the console login never forces a password =="
grep -q 'tsx-rootpw login' "$PROF" && bad "tsx.sh still forces a password change" || ok "tsx.sh has no forced password change"
grep -q '/dev/tty' "$PROF" && bad "tsx.sh still checks the console terminal" || ok "tsx.sh does not look at the terminal"

echo "== ssh takes the key until a password is set =="
grep -q '^PermitEmptyPasswords no$' "$SSHD" && ok "sshd: PermitEmptyPasswords no" || bad "sshd: no PermitEmptyPasswords no"
grep -q '^PermitRootLogin yes$' "$SSHD" && grep -q '^PubkeyAuthentication yes$' "$SSHD" && ok "sshd: root may log in with a key or a password" || bad "sshd policy changed"

echo "== the banner says which case applies =="
mkdir -p "$T/run"; echo FAKE-100 > "$T/run/model"
ban() { env TSX_BANNER_ART="$ART" TSX_ISSUE_FILE="$T/issue" TSX_MOTD_FILE="$T/motd" TSX_RUN="$T/run" TSX_IP=192.0.2.10 TSX_NO_RESPAWN=1 TSX_ROOTPW_BIN="$RPW" TSX_SHADOW_FILE="$SH" TSX_AUTH_KEYS_FILE="$AK" sh "$BAN"; }
printf 'root:*::0:::::\n' > "$SH"; echo "$KEY" > "$AK"; ban
for f in issue motd; do
	grep -q 'no password is set' "$T/$f" && grep -q 'over SSH with your key' "$T/$f" && grep -q 'run passwd' "$T/$f" && ok "$f (key only): says the console login opens after passwd over SSH" || bad "$f (key only) wrong"
done
printf 'root:%s:19000:0:::::\n' "$HASH" > "$SH"; ban
for f in issue motd; do grep -q 'password is set' "$T/$f" && ok "$f (password set): says so" || bad "$f (set) wrong"; done
printf 'root:*::0:::::\n' > "$SH"; : > "$AK"; ban
grep -q 'Nobody can log in' "$T/issue" && ok "issue (no password, no key): says nobody can log in" || bad "issue (nothing) wrong"

echo "== the banner follows passwd while the panel runs (tsx-banner check) =="
cban() { env TSX_BANNER_ART="$ART" TSX_ISSUE_FILE="$T/issue" TSX_MOTD_FILE="$T/motd" TSX_RUN="$T/run" TSX_IP=192.0.2.10 TSX_NO_RESPAWN=1 TSX_ROOTPW_BIN="$RPW" TSX_SHADOW_FILE="$SH" TSX_AUTH_KEYS_FILE="$AK" sh "$BAN" check; }
printf 'root:*::0:::::\n' > "$SH"; echo "$KEY" > "$AK"; ban
touch -d '2026-01-01 00:00:00' "$SH"; ban
grep -q 'no password is set' "$T/issue" || bad "setup of the check test failed"
cp "$T/issue" "$T/issue.1"; cban
cmp -s "$T/issue" "$T/issue.1" && ok "check: no change in the files, no rewrite" || bad "check rewrote the banner with no change"
printf 'root:%s:19000:0:::::\n' "$HASH" > "$SH"; touch -d '2026-02-01 00:00:00' "$SH"; cban
for f in issue motd; do grep -q 'password is set' "$T/$f" && ! grep -q 'login on this screen is off' "$T/$f" && ok "check: $f says the password is set after passwd" || bad "check: $f stays stale after passwd"; done
printf 'root:*::0:::::\n' > "$SH"; touch -d '2026-03-01 00:00:00' "$SH"; cban
grep -q 'no password is set' "$T/issue" && ok "check: the password removed, the banner follows" || bad "check: banner stays at password set"
busybox sh -n "$BAN" && ok "tsx-banner passes busybox sh -n" || bad "tsx-banner: busybox sh -n"

echo "== tsx-banner watch: inotify events, no polling =="
# The panel busybox has inotifyd. A host busybox often has not (Debian): then
# a stand-in polls the folders five times a second and runs the program as
# inotifyd does ("PROG EVENTS FOLDER FILE"). A stat in front of PATH counts
# the checks of tsx-banner (each check runs stat once).
W=$T/watch; mkdir -p "$W/etc" "$W/root/.ssh" "$W/run" "$W/bin"; echo FAKE-100 > "$W/run/model"
WSH=$W/etc/shadow WAK=$W/root/.ssh/authorized_keys
REAL_STAT=$(command -v stat)
printf '#!/bin/sh\necho x >> "%s/stat.calls"\nexec "%s" "$@"\n' "$W" "$REAL_STAT" > "$W/bin/stat"; chmod 755 "$W/bin/stat"
cat > "$W/inotifyd" <<'STUB'
#!/bin/sh
# The program runs from this shell (not from a pipe), so its parent is this
# process, as with inotifyd.
prog=$1; shift
tmp=$(mktemp -d); trap 'rm -rf "$tmp"; exit 0' TERM INT
snap() { for a in "$@"; do d=${a%%:*}; [ -d "$d" ] && find "$d" -mindepth 1 -maxdepth 1 -printf "%h %f %T@ %s %i\n"; done | sort; }
snap "$@" > "$tmp/old"
while sleep 0.2; do
	snap "$@" > "$tmp/new"
	grep -vxF -f "$tmp/old" "$tmp/new" > "$tmp/ev"
	mv "$tmp/new" "$tmp/old"
	while read -r d f _; do "$prog" y "$d" "$f"; done < "$tmp/ev"
done
STUB
chmod 755 "$W/inotifyd"
if busybox inotifyd 2>&1 | grep -q 'Usage: inotifyd'; then INOTIFYD="busybox inotifyd"; echo "  (real busybox inotifyd)"
else INOTIFYD=$W/inotifyd; echo "  (no inotifyd in the host busybox: the polling stand-in)"; fi
# wenv replaces its shell: call it in a subshell, so $! of "( wenv ... ) &" is the watch itself.
wenv() { exec env PATH="$W/bin:$PATH" TSX_BANNER_ART="$ART" TSX_ISSUE_FILE="$W/issue" TSX_MOTD_FILE="$W/motd" TSX_RUN="$W/run" TSX_IP=192.0.2.10 TSX_NO_RESPAWN=1 TSX_ROOTPW_BIN="$RPW" TSX_SHADOW_FILE="$WSH" TSX_AUTH_KEYS_FILE="$WAK" "$@"; }
# wait_for TEXT SECONDS: the issue file has TEXT within SECONDS
wait_for() { i=0; while [ $i -lt $(($2 * 10)) ]; do grep -q "$1" "$W/issue" 2>/dev/null && return 0; sleep 0.1; i=$((i + 1)); done; return 1; }
calls() { wc -l < "$W/stat.calls" 2>/dev/null | tr -d ' ' || echo 0; }
printf 'root:*::0:::::\n' > "$WSH"; : > "$WAK"
( wenv TSX_INOTIFYD="$INOTIFYD" TSX_WATCH_SEC=300 sh "$BAN" watch ) >/dev/null 2>&1 &
WPID=$!
wait_for 'Nobody can log in' 5 && ok "watch: the first check writes the banner" || bad "watch: no banner at start"
sleep 1; c0=$(calls); sleep 3
eq "$(calls)" "$c0" "watch: no check while nothing changes (3 s)"
# passwd writes a new file and renames it over /etc/shadow
printf 'root:%s:19000:0:::::\n' "$HASH" > "$WSH.new"; mv "$WSH.new" "$WSH"
wait_for 'password is set' 3 && ok "watch: the banner follows passwd (a rename) at once" || bad "watch: no update after the rename of shadow"
printf 'root:*::0:::::\n' > "$WSH.new"; mv "$WSH.new" "$WSH"
wait_for 'Nobody can log in' 3 && ok "watch: the password removed, the banner follows" || bad "watch: no update after the second rename"
echo "$KEY" >> "$WAK"
wait_for 'over SSH with your key' 3 && ok "watch: the banner follows a new key at once" || bad "watch: no update after a new key"
c1=$(calls); touch -d '2026-05-01 00:00:00' "$WAK"; sleep 1.5
[ "$(calls)" -gt "$c1" ] && ok "watch: a new time on the key file (touch) runs a check" || bad "watch: no check after touch"
c1=$(calls); echo x > "$W/etc/other"; echo y > "$W/root/.ssh/known_hosts"; sleep 1.5
eq "$(calls)" "$c1" "watch: a change of another file in the folders runs no check"
left() { ps -eo pid,args | grep -F -e "$BAN" -e "$W/" | grep -v grep; }
stop_watch() { kill "$WPID"; sleep 1; l=$(left); [ -z "$l" ] && ok "watch: TERM ends the watch, the timer and inotifyd ($1)" || bad "watch: processes left after TERM ($1): $l"; }
stop_watch "events"

echo "== tsx-banner watch: a key folder that comes later, no inotifyd =="
rm -rf "$W/root/.ssh" "$W/issue"; printf 'root:*::0:::::\n' > "$WSH"
( wenv TSX_INOTIFYD="$INOTIFYD" TSX_WATCH_SEC=300 sh "$BAN" watch ) >/dev/null 2>&1 &
WPID=$!
wait_for 'Nobody can log in' 5 || bad "watch (no key folder): no banner at start"
mkdir "$W/root/.ssh"; sleep 0.5; echo "$KEY" > "$WAK"
wait_for 'over SSH with your key' 15 && ok "watch: a new key folder starts the watch again, the key shows" || bad "watch: the key in a new key folder is not seen"
sleep 1
echo "$KEY" > "$WAK.2"; mv "$WAK.2" "$WAK"; printf 'root:%s:19000:0:::::\n' "$HASH" > "$WSH.new"; mv "$WSH.new" "$WSH"
wait_for 'password is set' 3 && ok "watch: the new watch sees passwd at once" || bad "watch: no update after the new watch"
stop_watch "new key folder"
printf 'root:*::0:::::\n' > "$WSH"; rm -f "$W/issue"
( wenv TSX_INOTIFYD="$W/no-such-inotifyd" TSX_WATCH_SEC=1 sh "$BAN" watch ) >/dev/null 2>&1 &
WPID=$!
wait_for 'over SSH with your key' 5 || bad "watch (no inotifyd): no banner at start"
printf 'root:%s:19000:0:::::\n' "$HASH" > "$WSH"; touch -d '2026-04-01 00:00:00' "$WSH"
wait_for 'password is set' 4 && ok "watch: with no inotifyd the slow timer still runs the check" || bad "watch: no update with no inotifyd"
stop_watch "no inotifyd"
c2=$(calls); ( TSX_BANNER_EVENT=1 wenv sh "$BAN" w "$W/etc" other ); eq "$(calls)" "$c2" "an event of another file ends at once, with no check"
grep -q 'tsx-banner watch' "$HERE/base/etc/local.d/tsx-banner.start" && ok "the boot hook starts the watch" || bad "boot hook does not start the watch"

echo "== no package file is changed by a boot script (securetty, motd) =="
# A script that changes a file of a package makes apk write a .apk-new file at
# each upgrade of that package. So no package of tsx-linux-common ships
# /etc/securetty (the board package ships it, with the serial console of the
# board) or /etc/motd (tsx-banner writes it), and no boot script edits them.
SER=$HERE/base/usr/local/lib/tsx/serial.sh
INIT=$HERE/base/etc/init.d/tsx-config
busybox sh -n "$SER" && ok "serial.sh passes busybox sh -n" || bad "serial.sh: busybox sh -n"
busybox sh -n "$INIT" && ok "the tsx-config init script passes busybox sh -n" || bad "tsx-config init script: busybox sh -n"
eq "$(sh -c ". '$TSX_BOARD_CONF'; echo \"\$TSX_SERIAL_CONSOLE\"")" "ttyFAKE0" "the made-up board names ttyFAKE0"
for f in etc/securetty etc/motd; do
	found=$(find "$HERE" -path "$HERE/.git" -prune -o -path "$HERE/tests" -prune -o -path "*/$f" -print | tr '\n' ' ')
	eq "$found" "" "no package ships /$f"
done
grep -q 'tsx_serial_allow_root' "$SER" "$INIT" "$HERE/base/usr/local/sbin/tsx-config" && bad "a script still edits securetty (tsx_serial_allow_root)" || ok "no script has tsx_serial_allow_root"
grep -rn 'securetty' "$HERE/base" "$HERE/kiosk" "$HERE/ha" "$HERE/setup" "$HERE/rescue" 2>/dev/null | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' | grep -q . && bad "a script or file in a package names securetty outside a comment" || ok "no package code touches securetty"
# The init script: start() leaves /etc/securetty and /etc/motd as they are. The test moves the
# absolute tool paths into a temporary folder and stubs the OpenRC helpers.
mkdir -p "$T/bin"
for tool in tsx-hw tsx-emmc-state tsx-config; do printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n' "$tool" "$T" > "$T/bin/$tool"; chmod 755 "$T/bin/$tool"; done
sed -e "s|/usr/local/sbin/|$T/bin/|g" "$INIT" > "$T/init.sh"
OPENRC='. "$1"; checkpath() { :; }; ebegin() { :; }; eend() { :; }; ewarn() { echo "ewarn: $*"; }; start'
printf 'console\ntty1\n' > "$T/securetty.init"; cp "$T/securetty.init" "$T/securetty.before"
: > "$T/calls"
out=$(env TSX_BOARD_CONF="$TSX_BOARD_CONF" TSX_SECURETTY="$T/securetty.init" busybox sh -c "$OPENRC" sh "$T/init.sh" 2>&1); rc=$?
[ $rc = 0 ] && [ -z "$out" ] && ok "start() of the tsx-config service runs with no warning" || bad "init start: rc $rc, out '$out'"
cmp -s "$T/securetty.init" "$T/securetty.before" && ok "start() does not change a securetty file (also with a board console set)" || bad "start() changed securetty: $(cat "$T/securetty.init")"
grep -q '^tsx-hw detect' "$T/calls" && grep -q '^tsx-config apply' "$T/calls" && ok "start() still runs tsx-hw detect and tsx-config apply" || bad "init start calls: $(cat "$T/calls")"

echo "$N passed, $F failed"
[ "$F" = 0 ]
