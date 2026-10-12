#!/bin/sh
# End-to-end host test of tsx-autoupdate. Two fakes drive the real check,
# install, status and healthcheck code against temp dirs:
#  - a fake apk with canned output for "update", "upgrade --simulate" and
#    "info -v". It logs every call.
#  - a fake date with a fixed "now" and real day-math (-d passthrough)
# A fake backlight class folder ($T/bl) and a fake panel app state file
# ($T/run/panel-app.state) stand in for the screen and the panel app.
# The test touches nothing on the host. rc-service, curl and reboot are all
# stubs under $T/bin. The made-up board of tests/boards/fake gives the family
# and the repository category.
set -u
# The made-up board for the scripts that read a board file.
. "$(dirname "$0")/lib/board.sh"
HERE=$(cd "$(dirname "$0")" && pwd); BIN=$HERE/../autoupdate/usr/local/sbin/tsx-autoupdate
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
fail=0
REALDATE=$(command -v date)

cat > "$T/bin/apk" <<EOF
#!/bin/sh
echo "APK \$*" >> "$T/apk.calls"
case "\$1 \${2:-}" in
"update ") cat "$T/update.txt" 2>/dev/null; exit "\${APK_UPDATE_RC:-0}";;
"upgrade --simulate") cat "$T/sim.txt" 2>/dev/null; exit 0;;
"upgrade "|"upgrade --force-missing-repositories")
	# The state that Home Assistant sees while apk runs.
	cp "$T/run/update-ha-state.json" "$T/during.json" 2>/dev/null; cp "$T/run/update.state" "$T/during.state" 2>/dev/null
	# A good install makes the next board version the installed one.
	if [ "\${APK_UPGRADE_RC:-0}" = 0 ] && [ -f "$T/board.next" ]; then mv "$T/board.next" "$T/board.ver"; fi
	exit "\${APK_UPGRADE_RC:-0}";;
"info -v") printf 'libfoo-%s-r0\nmusl-1.2.5-r0\ntsx-base-%s-r0\n' "\${LIBFOO_INSTALLED:-1.0.0}" "\$(cat "$T/base.ver")"
	# the board package and one of its subpackages (a digit must follow the name)
	[ -f "$T/board.ver" ] && printf 'tsx-fake-board-%s-r2\ntsx-fake-board-ha-9.9.9-r0\n' "\$(cat "$T/board.ver")"
	exit 0;;
esac
exit 0
EOF
cat > "$T/bin/date" <<EOF
#!/bin/sh
if [ "\$1" = -d ]; then shift; exec "$REALDATE" -d "\$@"; fi
case "\$1" in
'+%F') echo "\${NOWDATE:-2026-01-01}";;
'+%H:%M') echo "\${NOWHHMM:-04:00}";;
'+%Y-%m-%dT%H:%M:%S') echo "\${NOWDATE:-2026-01-01}T\${NOWHHMM:-04:00}:00";;
*) exec "$REALDATE" "\$@";;
esac
EOF
for c in rc-service curl reboot hostname; do
	printf '#!/bin/sh\necho "CALL %s $*" >> "%s/calls"\nexit "${%s_RC:-0}"\n' "$c" "$T" "$(echo "$c" | tr 'a-z-' 'A-Z_')" > "$T/bin/$c"
done
chmod +x "$T/bin"/*

: > "$T/sim.txt"; : > "$T/calls"; : > "$T/apk.calls"
echo 0.3.5 > "$T/board.ver"; echo 0.3.5 > "$T/base.ver"
echo boot-1 > "$T/bootid"
conf() {  # conf MODE AUTO_RESTART: the settings file
	printf 'MODE=%s\nWINDOW=03:00-05:00\nAUTO_RESTART=%s\n' "$1" "$2" > "$T/autoupdate.conf"
}
conf auto on
echo blank > "$T/idled"
echo 'KIOSK_URL="https://ha.example.org"' > "$T/kiosk.conf"
mkdir -p "$T/initd"; : > "$T/initd/kiosk"   # the kiosk service exists (the kiosk and ha profiles)

run() {  # run SUBCOMMAND  (env NOWDATE/NOWHHMM/APK_UPGRADE_RC/etc already exported)
	PATH="$T/bin:$PATH" \
	TSX_AUTOUPDATE_CONF="$T/autoupdate.conf" TSX_BOOT_ID_FILE="$T/bootid" TSX_RUN_DIR="$T/run" TSX_STATE_DIR="$T/state" \
	TSX_LOG="$T/tsx-autoupdate.log" TSX_IDLED_STATE="$T/idled" TSX_KIOSK_CONF="$T/kiosk.conf" \
	TSX_BUILD_ID_FILE="$T/buildid" TSX_INITD="$T/initd" TSX_BACKLIGHT_CLASS="$T/bl" TSX_HEALTH_POLL=1 \
	TSX_RUNLEVELS="$T/runlevels" sh "$BIN" "$@"
}
jf() { jq -r "$2" "$1"; }   # jf FILE .jqfilter
chk() { [ "$1" = "$2" ] || { echo "FAIL: $3: got '$1', want '$2'"; fail=1; }; }
reset_calls() { : > "$T/calls"; : > "$T/apk.calls"; }

# ---- 1: nothing pending: no-op ----------------------------------------------
NOWDATE=2026-01-01 NOWHHMM=04:00 run >/dev/null
chk "$(jf "$T/run/update.json" .pending_count)" 0 "1: nothing pending"
chk "$(jf "$T/run/update.json" .reboot_pending)" false "1: no reboot pending"
grep -q '^APK upgrade$' "$T/apk.calls" && { echo "FAIL: 1: installed with nothing pending"; fail=1; }
# The versions are release numbers (the board package), not the package hash.
chk "$(jf "$T/run/update-ha-state.json" .installed_version)/$(jf "$T/run/update-ha-state.json" .latest_version)" 0.3.5/0.3.5 "1: release numbers, nothing pending"
chk "$(jf "$T/run/update-ha-state.json" .release_summary)" "up to date" "1: summary"
chk "$(jf "$T/run/update-ha-state.json" '[.restart_required, .mode, .auto_restart] | join(" ")')" "false auto true" "1: restart_required, mode, auto_restart"
chk "$(cat "$T/run/update.state")" "installed 0.3.5
latest 0.3.5
title TSX tsx packages
summary up to date
in-progress no
restart-required no
mode auto
auto-restart on" "1: update.state"
# The Chromium patch logic is not part of this tool: no Chromium field in the status.
chk "$(jq -r '[keys[] | select(startswith("chromium"))] | length' "$T/run/update.json")" 0 "1: update.json has no chromium field"
chk "$(grep -c chromium "$T/state/fields")" 0 "1: the status file has no chromium field"

# ---- 2: a restart-needing package pending, in window + idle: installs and restarts
printf '(1/2) Upgrading musl (1.2.5-r0 -> 1.2.5-r1)\n(2/2) Upgrading libfoo (1.0-r0 -> 1.1-r0)\n' > "$T/sim.txt"
reset_calls
NOWDATE=2026-01-01 NOWHHMM=12:00 run check >/dev/null
chk "$(jf "$T/run/update.json" .pending_count)" 2 "2: two pending packages"
chk "$(jf "$T/run/update.json" .reboot_pending)" true "2: musl -> restart needed after the install"
# only other packages are pending: the latest version is the installed release plus a note
chk "$(jf "$T/run/update-ha-state.json" .installed_version)/$(jf "$T/run/update-ha-state.json" .latest_version)" "0.3.5/0.3.5 + 2 packages" "2: latest with only other packages pending"
chk "$(jf "$T/run/update-ha-state.json" .release_summary)" "Packages to install:

- musl (1.2.5-r0 -> 1.2.5-r1)
- libfoo (1.0-r0 -> 1.1-r0)

Restart needed after install." "2: the summary is a Markdown list, one package on each line, the restart note on its own line"
chk "$(sed -n 's/^summary //p' "$T/run/update.state")" 'Packages to install:\n\n- musl (1.2.5-r0 -> 1.2.5-r1)\n- libfoo (1.0-r0 -> 1.1-r0)\n\nRestart needed after install.' "2: update.state: the summary on one line, with \\n"
chk "$(wc -l < "$T/run/update.state")" 8 "2: update.state has 8 lines (no raw newline in the summary)"
grep -c 'Packages to install' "$T/run/update-ha-state.json" | grep -qx 1 && [ "$(wc -l < "$T/run/update-ha-state.json")" = 1 ] || { echo "FAIL: 2: update-ha-state.json is not one line"; fail=1; }
chk "$(jf "$T/run/update-ha-state.json" .title)" "TSX tsx packages" "2: title, nothing installed yet"
chk "$(jf "$T/run/update-ha-state.json" .restart_required)" false "2: nothing installed yet"
NOWDATE=2026-01-01 NOWHHMM=04:00 run >/dev/null
grep -q '^APK upgrade$' "$T/apk.calls" || { echo "FAIL: 2: apk upgrade not run"; fail=1; }
grep -q '^CALL reboot' "$T/calls" || { echo "FAIL: 2: reboot not called inside the window"; fail=1; }
[ -e "$T/state/reboot-marker" ] || { echo "FAIL: 2: reboot-marker not written"; fail=1; }
chk "$(jf "$T/run/update.json" .last_result)" ok "2: last_result ok"
chk "$(jf "$T/run/update.json" .pending_count)/$(jf "$T/run/update.json" .restart_required)" 0/true "2: installed: nothing pending, restart required"

# ---- 2a: only a tsx-* package is pending (a new common release): the services keep the old code, so a restart
rm -f "$T/state/reboot-marker"
echo boot-2 > "$T/bootid"   # the panel restarted: a new boot
printf '(1/1) Upgrading tsx-ha (0.2.1-r0 -> 0.2.2-r0)\n' > "$T/sim.txt"
reset_calls
NOWDATE=2026-01-01 NOWHHMM=12:00 run check >/dev/null
chk "$(jf "$T/run/update.json" .restart_required)" false "2a: a new boot ended the state restart required"
chk "$(jf "$T/run/update.json" .reboot_pending)" true "2a: a tsx-ha upgrade needs a restart"
NOWDATE=2026-01-01 NOWHHMM=04:00 run >/dev/null
grep -q '^APK upgrade$' "$T/apk.calls" || { echo "FAIL: 2a: apk upgrade not run"; fail=1; }
grep -q '^CALL reboot' "$T/calls" || { echo "FAIL: 2a: no reboot after a tsx-ha install inside the window"; fail=1; }
[ -e "$T/state/reboot-marker" ] || { echo "FAIL: 2a: reboot-marker not written (no health check after the reboot)"; fail=1; }
rm -f "$T/state/reboot-marker"
# the same upgrade with AUTO_RESTART=off: installed, no restart, "restart required" stays
echo boot-3 > "$T/bootid"
conf auto off
reset_calls
NOWDATE=2026-01-01 NOWHHMM=04:00 run >/dev/null
grep -q '^APK upgrade$' "$T/apk.calls" || { echo "FAIL: 2a: AUTO_RESTART=off: not installed"; fail=1; }
grep -q '^CALL reboot' "$T/calls" && { echo "FAIL: 2a: restarted with AUTO_RESTART=off"; fail=1; }
chk "$(jf "$T/run/update.json" .restart_required)" true "2a: AUTO_RESTART=off: restart required stays"
conf auto on
# AUTO_RESTART comes on later: the next scheduled run restarts (in the window, screen idle)
reset_calls
NOWDATE=2026-01-01 NOWHHMM=04:15 run >/dev/null
grep -q '^CALL reboot' "$T/calls" || { echo "FAIL: 2a: AUTO_RESTART on later: no restart"; fail=1; }
rm -f "$T/state/reboot-marker"; echo boot-4 > "$T/bootid"
# tsx-keys is a public key: no restart
printf '(1/1) Upgrading tsx-keys (1-r0 -> 1-r1)\n' > "$T/sim.txt"
reset_calls
NOWDATE=2026-01-01 NOWHHMM=04:00 run >/dev/null
chk "$(jf "$T/run/update.json" .restart_required)" false "2a: a tsx-keys upgrade needs no restart"
grep -q '^CALL reboot' "$T/calls" && { echo "FAIL: 2a: restarted for tsx-keys"; fail=1; }
printf '(1/2) Upgrading musl (1.2.5-r0 -> 1.2.5-r1)\n(2/2) Upgrading libfoo (1.0-r0 -> 1.1-r0)\n' > "$T/sim.txt"

# ---- 3: same pending list, outside the window: must not install -----------
rm -f "$T/state/reboot-marker"
reset_calls
NOWDATE=2026-01-01 NOWHHMM=12:00 run >/dev/null
grep -q '^APK upgrade$' "$T/apk.calls" && { echo "FAIL: 3: installed outside the window"; fail=1; }
grep -q 'not installing now' "$T/tsx-autoupdate.log" || { echo "FAIL: 3: no 'not installing' log line"; fail=1; }

# ---- 4: in window but the screen is not idle: must not install ------------
echo "on 17" > "$T/idled"
reset_calls
NOWDATE=2026-01-01 NOWHHMM=04:00 run >/dev/null
grep -q '^APK upgrade$' "$T/apk.calls" && { echo "FAIL: 4: installed while not idle"; fail=1; }
echo blank > "$T/idled"

# ---- 8: status --------------------------------------------------------------
out=$(run status); rc=$?
chk "$rc" 0 "8: status exits 0"
echo "$out" | grep -q '^pending:' || { echo "FAIL: 8: status missing 'pending:'"; fail=1; }
echo "$out" | grep -q '^chromium' && { echo "FAIL: 8: status has a chromium line"; fail=1; }

# ---- 8a: status of a panel that never ran an install or a health check -------
# (the health field and the last install have no value: the lines must say so, not stay blank)
mkdir -p "$T/state-new"; printf 'installed_hash abc123\npending_count 0\n' > "$T/state-new/fields"
out=$(PATH="$T/bin:$PATH" TSX_AUTOUPDATE_CONF="$T/autoupdate.conf" TSX_RUN_DIR="$T/run-new" TSX_STATE_DIR="$T/state-new" \
	TSX_LOG="$T/tsx-autoupdate-new.log" TSX_IDLED_STATE="$T/idled" TSX_KIOSK_CONF="$T/kiosk.conf" TSX_BUILD_ID_FILE="$T/buildid" TSX_INITD="$T/initd" \
	sh "$BIN" status)
echo "$out" | grep -q '^health: *none yet' || { echo "FAIL: 8a: status health line is blank or wrong: $(echo "$out" | grep '^health')"; fail=1; }
echo "$out" | grep -q '^last install: *never$' || { echo "FAIL: 8a: status last install line: $(echo "$out" | grep '^last install')"; fail=1; }

# ---- 9: post-reboot health check, OK then FAILED ---------------------------
: > "$T/state/reboot-marker"
cat > "$T/bin/curl" <<EOF
#!/bin/sh
echo "CALL curl \$*" >> "$T/calls"
echo "\${CURL_CODE:-200}"
EOF
chmod +x "$T/bin/curl"
NOWDATE=2026-01-09 NOWHHMM=04:00 CURL_CODE=200 run healthcheck >/dev/null
chk "$(jf "$T/run/update.json" .health)" OK "9: healthy after reboot"
run status | grep -q '^health: *OK$' || { echo "FAIL: 9: status does not show the health result: $(run status | grep '^health')"; fail=1; }
[ -e "$T/state/reboot-marker" ] && { echo "FAIL: 9: reboot-marker not cleared"; fail=1; }

: > "$T/state/reboot-marker"
NOWDATE=2026-01-09 NOWHHMM=04:00 CURL_CODE=000 RC_SERVICE_RC=1 run healthcheck >/dev/null
h=$(jf "$T/run/update.json" .health)
case $h in FAILED*) : ;; *) echo "FAIL: 9: expected a FAILED health after a bad reboot, got '$h'"; fail=1;; esac

# ---- 9a: the console profile has no kiosk service: no check of it, no page
rm -f "$T/initd/kiosk"; reset_calls
: > "$T/state/reboot-marker"
NOWDATE=2026-01-09 NOWHHMM=04:00 CURL_CODE=000 RC_SERVICE_RC=1 run healthcheck >/dev/null
chk "$(jf "$T/run/update.json" .health)" OK "9a: no kiosk service: healthy without it"
grep -q '^CALL rc-service kiosk status' "$T/calls" && { echo "FAIL: 9a: asked for a kiosk service that the profile lacks"; fail=1; }
grep -q '^CALL curl' "$T/calls" && { echo "FAIL: 9a: reached for a page without a kiosk"; fail=1; }
: > "$T/initd/kiosk"; reset_calls

# ---- 9b: panel.conf override (/run/tsx/kiosk.conf) wins over KIOSK_CONF for
# the health-check URL, same precedence as kiosk-session
: > "$T/state/reboot-marker"; : > "$T/calls"
echo 'KIOSK_URL="https://panel.example.net/lovelace/0"' > "$T/run/kiosk.conf"
NOWDATE=2026-01-09 NOWHHMM=04:00 CURL_CODE=200 run healthcheck >/dev/null
grep -q 'CALL curl.*https://panel.example.net/lovelace/0' "$T/calls" || { echo "FAIL: 9b: health check did not use /run/tsx/kiosk.conf's KIOSK_URL override"; fail=1; }
rm -f "$T/run/kiosk.conf"

# ---- 10: this project's repository unreachable: warning, Alpine still installs
rm -f "$T/state/reboot-marker"
cat > "$T/update.txt" <<'U'
WARNING: updating and opening https://tsx-aports.example.org/v3.24/common/armv7/APKINDEX.tar.gz: DNS: name does not exist
WARNING: updating and opening https://tsx-aports.example.org/v3.24/fake/armv7/APKINDEX.tar.gz: DNS: name does not exist
v3.24.2-50-g2d91fef52d8 [https://dl-cdn.alpinelinux.org/alpine/v3.24/main]
2 unavailable, 0 stale; 6093 distinct packages available
U
printf '(1/1) Upgrading libfoo (1.1-r0 -> 1.2-r0)\n' > "$T/sim.txt"
reset_calls
NOWDATE=2026-01-10 NOWHHMM=04:00 APK_UPDATE_RC=2 run >/dev/null
rw=$(jf "$T/run/update.json" .repo_warning)
case $rw in "tsx-aports repository unreachable (https://tsx-aports.example.org/v3.24/common, https://tsx-aports.example.org/v3.24/fake)"*) :;; *) echo "FAIL: 10: repo_warning '$rw'"; fail=1;; esac
grep -q '^APK upgrade --simulate --force-missing-repositories$' "$T/apk.calls" || { echo "FAIL: 10: check did not force past our missing repositories"; fail=1; }
grep -q '^APK upgrade --force-missing-repositories$' "$T/apk.calls" || { echo "FAIL: 10: Alpine updates not installed while our repository is unreachable"; fail=1; }
chk "$(jf "$T/run/update.json" .last_result)" ok "10: Alpine update installed"
jf "$T/run/update-ha-state.json" .release_summary | grep -q 'WARNING: tsx-aports repository unreachable' || { echo "FAIL: 10: HA summary lacks the repository warning"; fail=1; }
run status | grep -q '^repositories:   tsx-aports repository unreachable' || { echo "FAIL: 10: status lacks the repository warning"; fail=1; }

# ---- 11: an Alpine repository unreachable: check only, no install -------------
printf 'WARNING: updating and opening https://dl-cdn.alpinelinux.org/alpine/v3.24/main/armv7/APKINDEX.tar.gz: Connection refused\n' > "$T/update.txt"
reset_calls
NOWDATE=2026-01-10 NOWHHMM=04:00 APK_UPDATE_RC=1 run >/dev/null
grep -E '^APK upgrade( --force-missing-repositories)?$' "$T/apk.calls" && { echo "FAIL: 11: installed while an Alpine repository is unreachable"; fail=1; }
chk "$(jf "$T/run/update.json" .repo_warning | grep -c 'not installing until it is back')" 1 "11: Alpine repository warning"

# ---- 12: all repositories fine again: warning cleared ---------------------------
: > "$T/update.txt"; : > "$T/sim.txt"
NOWDATE=2026-01-10 NOWHHMM=12:00 run check >/dev/null
chk "$(jf "$T/run/update.json" .repo_warning)" "" "12: warning cleared once reachable"
run status | grep -q '^repositories:   ok$' || { echo "FAIL: 12: status does not say repositories ok"; fail=1; }

# ---- 13: a package of the kernel of the board needs a reboot --------------------
printf '(1/1) Upgrading tsx-fake-kernel-lts (6.18.54_git20260928-r1 -> 6.18.55_git20261005-r0)\n' > "$T/sim.txt"
reset_calls
NOWDATE=2026-01-11 NOWHHMM=12:00 run check >/dev/null
chk "$(jf "$T/run/update.json" .reboot_pending)" true "13: the kernel package of the board needs a reboot"
printf '(1/1) Upgrading tsx-other-kernel-lts (6.18.54_git20260928-r1 -> 6.18.55_git20261005-r0)\n' > "$T/sim.txt"
NOWDATE=2026-01-11 NOWHHMM=12:01 run check >/dev/null
chk "$(jf "$T/run/update.json" .reboot_pending)" false "13: the kernel package of another family does not"

# ---- 15: a new package (a new dependency) counts as pending; a new tsx-* package needs a reboot
printf '(1/2) Installing tsx-newsvc (0.3.2-r0)\n(2/2) Upgrading libfoo (1.1-r0 -> 1.2-r0)\n' > "$T/sim.txt"
reset_calls
NOWDATE=2026-01-12 NOWHHMM=12:00 run check >/dev/null
chk "$(jf "$T/run/update.json" .pending_count)" 2 "15: the new package is pending"
chk "$(jf "$T/run/update.json" '.pending[0]')" "tsx-newsvc (none -> 0.3.2-r0)" "15: the new package in the list"
chk "$(jf "$T/run/update.json" .reboot_pending)" true "15: a new tsx-* package needs a reboot"
printf '(1/1) Installing libbar (2.0-r0)\n' > "$T/sim.txt"
NOWDATE=2026-01-12 NOWHHMM=12:01 run check >/dev/null
chk "$(jf "$T/run/update.json" .pending_count)/$(jf "$T/run/update.json" .reboot_pending)" 1/false "15: a new library needs no reboot"
printf '(1/1) Installing tsx-fake-kernel-lts (6.18.55_git20261005-r0)\n' > "$T/sim.txt"
NOWDATE=2026-01-12 NOWHHMM=12:02 run check >/dev/null
chk "$(jf "$T/run/update.json" .reboot_pending)" true "15: a new kernel package of the board needs a reboot"
printf '(1/1) Downgrading tsx-base (0.3.1-r0 -> 0.3.0-r0)\n' > "$T/sim.txt"
NOWDATE=2026-01-12 NOWHHMM=12:03 run check >/dev/null
chk "$(jf "$T/run/update.json" .pending_count)/$(jf "$T/run/update.json" .reboot_pending)" 1/true "15: a downgrade of a tsx-* package counts and needs a reboot"

# ---- 16: no screen state file (an older panel app): the backlight decides ------
printf '(1/1) Upgrading libfoo (1.2-r0 -> 1.3-r0)\n' > "$T/sim.txt"
mv "$T/idled" "$T/idled.saved"
mkdir -p "$T/bl/lcd"; echo 40 > "$T/bl/lcd/brightness"
reset_calls
NOWDATE=2026-01-13 NOWHHMM=04:00 run >/dev/null
grep -q '^APK upgrade$' "$T/apk.calls" && { echo "FAIL: 16: installed with no state file and the backlight on"; fail=1; }
grep -q 'not installing now (in_window=1 idle=0)' "$T/tsx-autoupdate.log" || { echo "FAIL: 16: no idle=0 log line"; fail=1; }
echo 0 > "$T/bl/lcd/brightness"; reset_calls
NOWDATE=2026-01-13 NOWHHMM=04:15 run >/dev/null
grep -q '^APK upgrade$' "$T/apk.calls" || { echo "FAIL: 16: no install with no state file and the backlight at 0"; fail=1; }
mkdir -p "$T/bl/second"; echo 3 > "$T/bl/second/brightness"; reset_calls
NOWDATE=2026-01-13 NOWHHMM=04:30 run >/dev/null
grep -q '^APK upgrade$' "$T/apk.calls" && { echo "FAIL: 16: installed while a second backlight is on"; fail=1; }
rm -rf "$T/bl"; reset_calls
NOWDATE=2026-01-13 NOWHHMM=04:45 run >/dev/null
grep -q '^APK upgrade$' "$T/apk.calls" && { echo "FAIL: 16: installed with no state file and no backlight"; fail=1; }
# A state file wins over the backlight: "on" with a dark backlight is not idle.
mkdir -p "$T/bl/lcd"; echo 0 > "$T/bl/lcd/brightness"; echo "on 12" > "$T/idled"; reset_calls
NOWDATE=2026-01-13 NOWHHMM=04:50 run >/dev/null
grep -q '^APK upgrade$' "$T/apk.calls" && { echo "FAIL: 16: the backlight won over the state file"; fail=1; }
mv "$T/idled.saved" "$T/idled"; rm -rf "$T/bl"

# ---- 17: the reboot marker keeps the Home Assistant state of the panel app ------
mkdir -p "$T/run"
printf 'pid 1\nstarted 100\nfirst_frame 101\nha_connected 110\nha on\n' > "$T/run/panel-app.state"
printf '(1/1) Upgrading tsx-fake-board (0.3.1-r0 -> 0.3.2-r0)\n' > "$T/sim.txt"
rm -f "$T/state/reboot-marker"; reset_calls
NOWDATE=2026-01-14 NOWHHMM=04:00 run >/dev/null
grep -q '^CALL reboot' "$T/calls" || { echo "FAIL: 17: no reboot for the board package"; fail=1; }
chk "$(cat "$T/state/reboot-marker" 2>/dev/null)" "panel_app_ha on" "17: marker with the Home Assistant state"
printf 'pid 1\nstarted 100\nfirst_frame 101\nha_connected 0\nha off\n' > "$T/run/panel-app.state"
rm -f "$T/state/reboot-marker"; reset_calls
NOWDATE=2026-01-14 NOWHHMM=04:15 run >/dev/null
chk "$(cat "$T/state/reboot-marker" 2>/dev/null)" "panel_app_ha off" "17: marker of a panel app with no Home Assistant"
rm -f "$T/state/reboot-marker" "$T/run/panel-app.state"
: > "$T/sim.txt"

# ---- 18: health check of a panel with the panel app and no kiosk ---------------
rm -f "$T/initd/kiosk"; : > "$T/initd/tsx-panel-app"
mkdir -p "$T/runlevels/default"; ln -sf "$T/initd/tsx-panel-app" "$T/runlevels/default/tsx-panel-app"
sleep 300 & APP=$!
DEAD=$(sh -c 'echo $$')
app_state() {  # app_state PID FIRST_FRAME HA_CONNECTED HA
	printf 'pid %s\nstarted 1000\nfirst_frame %s\nha_connected %s\nha %s\n' "$1" "$2" "$3" "$4" > "$T/run/panel-app.state"
}
hc() {  # hc MARKER-HA TIMEOUT [env...]: one health check after an update reboot
	printf 'panel_app_ha %s\n' "$1" > "$T/state/reboot-marker"
	printf 'ENABLED=1\nWINDOW=03:00-05:00\nREBOOT=auto\nHEALTH_TIMEOUT=%s\n' "$2" > "$T/autoupdate.conf"
	shift 2
	( for kv in "$@"; do export "$kv"; done
	  NOWDATE=2026-01-15 NOWHHMM=04:00 run healthcheck ) >/dev/null 2>&1
	jf "$T/run/update.json" .health
}
reset_calls
app_state "$APP" 1001 1012 on
chk "$(hc on 0)" OK "18: app runs, first frame, Home Assistant again: OK"
grep -q '^CALL rc-service tsx-panel-app status' "$T/calls" || { echo "FAIL: 18: the service of the panel app not checked"; fail=1; }
grep -q '^CALL curl' "$T/calls" && { echo "FAIL: 18: reached for a kiosk page with no kiosk"; fail=1; }
grep -q 'panel app: running, first frame drawn, Home Assistant connected' "$T/tsx-autoupdate.log" || { echo "FAIL: 18: no log line of the app check"; fail=1; }
app_state "$APP" 0 0 off
chk "$(hc on 0)" "FAILED: panel app drew no frame (after 0 s)" "18: no first frame"
app_state "$APP" 1001 0 off
chk "$(hc on 0)" "FAILED: panel app not connected to Home Assistant (after 0 s)" "18: Home Assistant before the update, none after"
chk "$(hc off 0)" OK "18: no Home Assistant before the update: not needed after"
app_state "$DEAD" 1001 1012 on
chk "$(hc on 0)" "FAILED: panel app process $DEAD not running (after 0 s)" "18: the process of the state file is gone"
rm -f "$T/run/panel-app.state"
chk "$(hc off 0)" "FAILED: panel app wrote no state (after 0 s)" "18: no state file"
app_state "$APP" 1001 1012 on
chk "$(hc on 0 RC_SERVICE_RC=1)" "FAILED: panel app service not running (after 0 s)" "18: the service is stopped"
[ -e "$T/state/reboot-marker" ] && { echo "FAIL: 18: reboot-marker not cleared"; fail=1; }
# The check waits for the app: the first frame comes 2 s after the start of the check.
app_state "$APP" 0 0 off
( sleep 2; app_state "$APP" 1003 1012 on ) &
t0=$(date +%s)
chk "$(hc on 20)" OK "18: the check waits for the first frame and Home Assistant"
t1=$(date +%s)
[ $((t1 - t0)) -lt 15 ] || { echo "FAIL: 18: the check did not end when the app was fine ($((t1 - t0)) s)"; fail=1; }
# An empty marker (an older tsx-autoupdate rebooted the panel): no Home Assistant needed.
app_state "$APP" 1001 0 off
: > "$T/state/reboot-marker"
printf 'ENABLED=1\nWINDOW=03:00-05:00\nREBOOT=auto\nHEALTH_TIMEOUT=0\n' > "$T/autoupdate.conf"
NOWDATE=2026-01-15 NOWHHMM=04:00 run healthcheck >/dev/null 2>&1
chk "$(jf "$T/run/update.json" .health)" OK "18: an empty marker needs no Home Assistant"
# A kiosk and the panel app: both are checked.
: > "$T/initd/kiosk"; app_state "$APP" 1001 1012 on
h=$(hc on 0 CURL_CODE=000)
case $h in "FAILED: page not reachable"*) :;; *) echo "FAIL: 18: kiosk page failure lost with the panel app: '$h'"; fail=1;; esac
app_state "$APP" 0 0 off
h=$(hc on 0 CURL_CODE=200)
chk "$h" "FAILED: panel app drew no frame (after 0 s)" "18: kiosk fine, app without a frame"
# ---- 19: the package is there, but the service is in no runlevel (a kiosk
# panel with tsx-panel-app installed): the app is not checked, no wait.
rm -f "$T/runlevels/default/tsx-panel-app"; reset_calls
app_state "$APP" 0 0 off
t0=$(date +%s)
h=$(hc on 20 CURL_CODE=200)
t1=$(date +%s)
chk "$h" OK "19: the panel app service is in no runlevel: not checked"
[ $((t1 - t0)) -lt 10 ] || { echo "FAIL: 19: the check waited for an app that the boot does not start ($((t1 - t0)) s)"; fail=1; }
grep -q '^CALL rc-service tsx-panel-app' "$T/calls" && { echo "FAIL: 19: the panel app service was checked"; fail=1; }
# In another runlevel (boot): checked again.
mkdir -p "$T/runlevels/boot"; ln -sf "$T/initd/tsx-panel-app" "$T/runlevels/boot/tsx-panel-app"
chk "$(hc on 0 CURL_CODE=200)" "FAILED: panel app drew no frame (after 0 s)" "19: the service in the boot runlevel is checked"
rm -f "$T/runlevels/boot/tsx-panel-app"
kill "$APP" 2>/dev/null; wait "$APP" 2>/dev/null
rm -f "$T/initd/tsx-panel-app" "$T/run/panel-app.state"
printf 'ENABLED=1\nWINDOW=03:00-05:00\nREBOOT=auto\n' > "$T/autoupdate.conf"

# ---- 20: modes, install now, versions and "restart required" across a boot ----
reset_state() {  # a panel that booted with the board 0.3.5, nothing pending
	rm -rf "$T/state" "$T/run" "$T/state/reboot-marker"; : > "$T/sim.txt"; : > "$T/update.txt"
	echo 0.3.5 > "$T/board.ver"; rm -f "$T/board.next"; echo 0.3.5 > "$T/base.ver"
	echo "boot-$1" > "$T/bootid"; echo blank > "$T/idled"; reset_calls
}
SIM_BOARD='(1/2) Upgrading tsx-fake-board (0.3.5-r2 -> 0.3.6-r0)\n(2/2) Upgrading tsx-base (0.3.5-r0 -> 0.3.6-r0)\n'
ha() { jf "$T/run/update-ha-state.json" "$1"; }

# 20a: the release of the board package, the latest release, the summary
reset_state 20
printf "$SIM_BOARD" > "$T/sim.txt"
NOWDATE=2026-02-01 NOWHHMM=12:00 run check >/dev/null
chk "$(ha .installed_version)/$(ha .latest_version)" 0.3.5/0.3.6 "20a: board package: installed 0.3.5, latest 0.3.6 (a subpackage and tsx-base do not count)"
chk "$(ha .release_summary)" "Packages to install:

- tsx-fake-board (0.3.5-r2 -> 0.3.6-r0)
- tsx-base (0.3.5-r0 -> 0.3.6-r0)

Restart needed after install." "20a: summary: a Markdown list, one package on each line"
chk "$(sed -n 's/^summary //p' "$T/run/update.state" | sed 's/\\n/\
/g')" "$(ha .release_summary)" "20a: update.state has the same summary (\\n for a newline)"
# one pending package that is not the board package
printf '(1/1) Upgrading libfoo (1.0-r0 -> 1.1-r0)\n' > "$T/sim.txt"
NOWDATE=2026-02-01 NOWHHMM=12:01 run check >/dev/null
chk "$(ha .latest_version)" "0.3.5 + 1 package" "20a: one other package pending"
# a panel with no board package: tsx-base carries the release
rm -f "$T/board.ver"; printf '(1/1) Upgrading tsx-base (0.3.5-r0 -> 0.3.6-r0)\n' > "$T/sim.txt"
NOWDATE=2026-02-01 NOWHHMM=12:02 run check >/dev/null
chk "$(ha .installed_version)/$(ha .latest_version)" 0.3.5/0.3.6 "20a: no board package: tsx-base gives the release"
echo 0.3.5 > "$T/board.ver"

# 20b: manual mode checks on the schedule and never installs by itself
reset_state 21
printf "$SIM_BOARD" > "$T/sim.txt"; echo 0.3.6 > "$T/board.next"
conf manual on
NOWDATE=2026-02-02 NOWHHMM=04:00 run >/dev/null
chk "$(jf "$T/run/update.json" .pending_count)" 2 "20b: manual: the schedule checks"
chk "$(ha .latest_version)" 0.3.6 "20b: manual: Home Assistant sees the update"
grep -q '^APK upgrade$' "$T/apk.calls" && { echo "FAIL: 20b: manual mode installed by itself"; fail=1; }
grep -q 'manual mode: not installing' "$T/tsx-autoupdate.log" || { echo "FAIL: 20b: no log line of the manual mode"; fail=1; }
chk "$(ha '[.mode, .auto_restart] | join(" ")')" "manual true" "20b: mode in the status"

# 20c: install from Home Assistant in manual mode: at once, screen on, outside the window; AUTO_RESTART=off
echo "on 40" > "$T/idled"; conf manual off; reset_calls
NOWDATE=2026-02-02 NOWHHMM=12:00 run now >/dev/null
grep -q '^APK upgrade$' "$T/apk.calls" || { echo "FAIL: 20c: install now did not install"; fail=1; }
grep -q '^CALL reboot' "$T/calls" && { echo "FAIL: 20c: restarted with AUTO_RESTART=off"; fail=1; }
chk "$(ha .installed_version)/$(ha .latest_version)" "0.3.5/0.3.6 (restart required)" "20c: installed stays the running release, latest is the new one and says restart required"
chk "$(ha .release_summary)" "Installed. Restart the panel to finish the update.

Press Install, or the Restart button, to restart the panel now." "20c: summary: starts with the installed note"
chk "$(ha .title)" "Restart required to finish 0.3.6" "20c: the title says restart required"
chk "$(sed -n 's/^title //p' "$T/run/update.state")" "Restart required to finish 0.3.6" "20c: update.state: the title"
chk "$(sed -n 's/^summary //p' "$T/run/update.state")" 'Installed. Restart the panel to finish the update.\n\nPress Install, or the Restart button, to restart the panel now.' "20c: update.state: the summary"
# while apk ran, Home Assistant saw the install in progress (a spinner)
chk "$(jf "$T/during.json" '[.in_progress, .title, .latest_version] | join("|")')" "true|TSX tsx packages|0.3.6" "20c: during the install: in_progress, the old title"
grep -q '^in-progress yes$' "$T/during.state" || { echo "FAIL: 20c: update.state had no in-progress yes during the install"; fail=1; }
jf "$T/during.json" .release_summary | head -1 | grep -qx 'Installing the packages. Do not switch the panel off.' || { echo "FAIL: 20c: the summary does not say Installing while apk runs"; fail=1; }
chk "$(ha .in_progress)" false "20c: in_progress ends"
chk "$(ha .restart_required)" true "20c: restart required"
chk "$(grep -c '^restart-required yes$' "$T/run/update.state")" 1 "20c: update.state: restart required"
chk "$(jf "$T/run/update.json" .pending_count)" 0 "20c: nothing pending after the install"
# the next scheduled check keeps the state (the packages are installed, the board is 0.3.6 now)
: > "$T/sim.txt"; NOWDATE=2026-02-02 NOWHHMM=12:15 run check >/dev/null
chk "$(ha .installed_version)/$(ha .latest_version)/$(ha .restart_required)" "0.3.5/0.3.6 (restart required)/true" "20c: a later check keeps the state"
chk "$(ha .title)" "Restart required to finish 0.3.6" "20c: a later check keeps the title"
# auto mode with AUTO_RESTART=off: the schedule restarts nothing
conf auto off; echo blank > "$T/idled"; reset_calls
NOWDATE=2026-02-02 NOWHHMM=04:00 run >/dev/null
grep -q '^CALL reboot' "$T/calls" && { echo "FAIL: 20c: the schedule restarted with AUTO_RESTART=off"; fail=1; }
# Install on the entry "restart required": it restarts the panel (any mode, any time)
echo "on 40" > "$T/idled"; reset_calls
NOWDATE=2026-02-02 NOWHHMM=12:30 run now >/dev/null
grep -q '^APK upgrade$' "$T/apk.calls" && { echo "FAIL: 20c: install on a restart entry ran apk upgrade"; fail=1; }
grep -q '^CALL reboot' "$T/calls" || { echo "FAIL: 20c: install on the restart entry did not restart"; fail=1; }
[ -e "$T/state/reboot-marker" ] || { echo "FAIL: 20c: no reboot-marker for the health check"; fail=1; }

# 20d: the fake boot: the running release is the installed release, the state is gone
echo boot-22 > "$T/bootid"; rm -f "$T/state/reboot-marker"
NOWDATE=2026-02-02 NOWHHMM=12:40 run boot >/dev/null
chk "$(ha .installed_version)/$(ha .latest_version)/$(ha .restart_required)/$(ha .release_summary)/$(ha .title)" "0.3.6/0.3.6/false/up to date/TSX tsx packages" "20d: after the boot: the normal title and notes"
chk "$(grep -c '^restart-required no$' "$T/run/update.state")" 1 "20d: update.state after the boot"
# the same boot id again changes nothing
NOWDATE=2026-02-02 NOWHHMM=12:41 run boot >/dev/null
chk "$(ha .installed_version)" 0.3.6 "20d: the same boot: no new record"

# 20e: install from Home Assistant with AUTO_RESTART=on: restarts right after, outside the window, in manual mode
reset_state 23
printf "$SIM_BOARD" > "$T/sim.txt"; echo 0.3.6 > "$T/board.next"
conf manual on; echo "on 40" > "$T/idled"
NOWDATE=2026-02-03 NOWHHMM=12:00 run now >/dev/null
grep -q '^APK upgrade$' "$T/apk.calls" || { echo "FAIL: 20e: install now did not install"; fail=1; }
grep -q '^CALL reboot' "$T/calls" || { echo "FAIL: 20e: no restart after install now with AUTO_RESTART=on"; fail=1; }
chk "$(cat "$T/state/reboot-marker" 2>/dev/null)" "panel_app_ha " "20e: marker for the health check"
# an automatic install outside the window does not happen, in auto mode
reset_state 24
printf "$SIM_BOARD" > "$T/sim.txt"; conf auto on
NOWDATE=2026-02-03 NOWHHMM=12:00 run >/dev/null
grep -q '^APK upgrade$' "$T/apk.calls" && { echo "FAIL: 20e: auto mode installed outside the window"; fail=1; }
# a failed apk upgrade: no restart, no restart required
reset_state 25
printf "$SIM_BOARD" > "$T/sim.txt"; conf auto on
NOWDATE=2026-02-03 NOWHHMM=04:00 APK_UPGRADE_RC=3 run >/dev/null
grep -q '^CALL reboot' "$T/calls" && { echo "FAIL: 20e: restarted after a failed install"; fail=1; }
chk "$(ha .restart_required)/$(jf "$T/run/update.json" .last_result)" "false/apk upgrade rc=3" "20e: failed install"
chk "$(ha .latest_version)" 0.3.6 "20e: the update is still offered"

# 20f: the settings: new keys, old keys, the override of panel.conf, bad values
cfg() { printf '%s' "$1" > "$T/autoupdate.conf"; }
get() { PATH="$T/bin:$PATH" TSX_AUTOUPDATE_CONF="$T/autoupdate.conf" TSX_AUTOUPDATE_OVERRIDE="$T/override.conf" TSX_LOG="$T/get.log" sh "$BIN" get "$1"; }
rm -f "$T/override.conf"
cfg 'ENABLED=1
REBOOT=auto
'; chk "$(get mode)/$(get auto-restart)" auto/on "20f: old keys, defaults"
cfg 'ENABLED=0
REBOOT=never
'; chk "$(get mode)/$(get auto-restart)" manual/off "20f: old keys: ENABLED=0 is manual, REBOOT=never is off"
cfg 'ENABLED=0
REBOOT=never
MODE=auto
AUTO_RESTART=on
'; chk "$(get mode)/$(get auto-restart)" auto/on "20f: the new keys win over the old keys"
cfg ''; chk "$(get mode)/$(get auto-restart)" auto/on "20f: an empty file: auto, on"
cfg 'MODE=auto
AUTO_RESTART=on
'; printf 'MODE="manual"\nAUTO_RESTART="off"\n' > "$T/override.conf"
chk "$(get mode)/$(get auto-restart)" manual/off "20f: the override of panel.conf wins"
cfg 'MODE=bogus
AUTO_RESTART=maybe
'; rm -f "$T/override.conf"
chk "$(get mode)/$(get auto-restart)" auto/on "20f: bad values: auto, on"
PATH="$T/bin:$PATH" TSX_AUTOUPDATE_CONF="$T/autoupdate.conf" sh "$BIN" get nothing >/dev/null 2>&1; chk $? 2 "20f: get of an unknown name"
conf auto on
# refresh writes the status again after a change of the settings, with no apk call
reset_state 26
NOWDATE=2026-02-04 NOWHHMM=12:00 run check >/dev/null
printf 'MODE="manual"\nAUTO_RESTART="off"\n' > "$T/run/autoupdate.conf"; reset_calls
NOWDATE=2026-02-04 NOWHHMM=12:01 TSX_AUTOUPDATE_OVERRIDE="$T/run/autoupdate.conf" run refresh >/dev/null
chk "$(grep -E '^(mode|auto-restart) ' "$T/run/update.state" | tr '\n' ' ')" "mode manual auto-restart off " "20f: refresh: update.state"
chk "$(ha '[.mode, .auto_restart] | join(" ")')" "manual false" "20f: refresh: JSON"
chk "$(wc -l < "$T/apk.calls")" 0 "20f: refresh calls no apk"
rm -f "$T/run/autoupdate.conf"
out=$(run status); echo "$out" | grep -q '^mode: *auto (automatic restart on)$' || { echo "FAIL: 20f: status mode line: $(echo "$out" | grep '^mode')"; fail=1; }
echo "$out" | grep -q '^installed: *0.3.5' || { echo "FAIL: 20f: status installed line"; fail=1; }
conf auto on

# 20g: an install that leaves the release number as it is (only tsx-base changes): the title and latest still say restart required
reset_state 27
printf '(1/1) Upgrading tsx-base (0.3.5-r0 -> 0.3.5-r1)\n' > "$T/sim.txt"
conf manual off; echo "on 40" > "$T/idled"
NOWDATE=2026-02-05 NOWHHMM=12:00 run now >/dev/null
chk "$(ha '[.installed_version, .latest_version, .title, .restart_required] | join("|")')" "0.3.5|0.3.5 (restart required)|Restart required to finish the update|true" "20g: same release: installed, latest and title"
chk "$(ha .release_summary | head -1)" "Installed. Restart the panel to finish the update." "20g: the notes start with the installed note"
# 20h: a restart is required and another package waits: both are in the notes
printf '(1/1) Upgrading libfoo (1.0-r0 -> 1.1-r0)\n' > "$T/sim.txt"
NOWDATE=2026-02-05 NOWHHMM=12:10 run check >/dev/null
chk "$(ha .release_summary)" "Installed. Restart the panel to finish the update.

Also pending:

- libfoo (1.0-r0 -> 1.1-r0)" "20h: restart required and one package pending" 
chk "$(ha '[.latest_version, .title] | join("|")')" "0.3.5 + 1 package|Restart required to finish the update" "20h: latest and title"
# 20i: a repository warning is its own paragraph
printf 'WARNING: updating and opening https://x.example/tsx/common/x86/APKINDEX.tar.gz: temporary error\n' > "$T/update.txt"
: > "$T/sim.txt"
NOWDATE=2026-02-05 NOWHHMM=12:20 run check >/dev/null
ha .release_summary | tail -1 | grep -q '^WARNING: tsx-aports repository unreachable' || { echo "FAIL: 20i: the warning is not the last line of the notes"; fail=1; }
ha .release_summary | sed -n 4p | grep -q '^$' || { echo "FAIL: 20i: no blank line before the warning"; fail=1; }
: > "$T/update.txt"
conf auto on

# ---- 14: no Chromium call at all ------------------------------------------------
grep -qi chromium "$T/apk.calls" "$T/calls" "$T/tsx-autoupdate.log" && { echo "FAIL: 14: a Chromium call or log line"; fail=1; }

[ $fail = 0 ] && echo "PASS tsx-autoupdate flow (check/install/window/idle/status/healthcheck/repositories/kernel/new packages/panel app)"
exit $fail
