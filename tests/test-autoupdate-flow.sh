#!/bin/sh
# End-to-end host test of tsx-autoupdate. Two fakes drive the real check,
# install, status and healthcheck code against temp dirs:
#  - a fake apk with canned output for "update", "upgrade --simulate" and
#    "info -v". It logs every call.
#  - a fake date with a fixed "now" and real day-math (-d passthrough)
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
"upgrade ") exit "\${APK_UPGRADE_RC:-0}";;
"upgrade --force-missing-repositories") exit "\${APK_UPGRADE_RC:-0}";;
"info -v") printf 'libfoo-%s-r0\nmusl-1.2.5-r0\n' "\${LIBFOO_INSTALLED:-1.0.0}"; exit 0;;
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
printf 'ENABLED=1\nWINDOW=03:00-05:00\nREBOOT=auto\n' > "$T/autoupdate.conf"
echo blank > "$T/idled"
echo 'KIOSK_URL="https://ha.example.org"' > "$T/kiosk.conf"
mkdir -p "$T/initd"; : > "$T/initd/kiosk"   # the kiosk service exists (the kiosk and ha profiles)

run() {  # run SUBCOMMAND  (env NOWDATE/NOWHHMM/APK_UPGRADE_RC/etc already exported)
	PATH="$T/bin:$PATH" \
	TSX_AUTOUPDATE_CONF="$T/autoupdate.conf" TSX_RUN_DIR="$T/run" TSX_STATE_DIR="$T/state" \
	TSX_LOG="$T/tsx-autoupdate.log" TSX_IDLED_STATE="$T/idled" TSX_KIOSK_CONF="$T/kiosk.conf" \
	TSX_BUILD_ID_FILE="$T/buildid" TSX_INITD="$T/initd" \
	sh "$BIN" "$@"
}
jf() { jq -r "$2" "$1"; }   # jf FILE .jqfilter
chk() { [ "$1" = "$2" ] || { echo "FAIL: $3: got '$1', want '$2'"; fail=1; }; }
reset_calls() { : > "$T/calls"; : > "$T/apk.calls"; }

# ---- 1: nothing pending: no-op ----------------------------------------------
NOWDATE=2026-01-01 NOWHHMM=04:00 run >/dev/null
chk "$(jf "$T/run/update.json" .pending_count)" 0 "1: nothing pending"
chk "$(jf "$T/run/update.json" .reboot_pending)" false "1: no reboot pending"
grep -q '^APK upgrade$' "$T/apk.calls" && { echo "FAIL: 1: installed with nothing pending"; fail=1; }
# The Chromium patch logic is not part of this tool: no Chromium field in the status.
chk "$(jq -r '[keys[] | select(startswith("chromium"))] | length' "$T/run/update.json")" 0 "1: update.json has no chromium field"
chk "$(grep -c chromium "$T/state/fields")" 0 "1: the status file has no chromium field"

# ---- 2: a reboot-needing package pending, in window + idle: installs and reboots
printf '(1/2) Upgrading musl (1.2.5-r0 -> 1.2.5-r1)\n(2/2) Upgrading libfoo (1.0-r0 -> 1.1-r0)\n' > "$T/sim.txt"
reset_calls
NOWDATE=2026-01-01 NOWHHMM=04:00 run >/dev/null
chk "$(jf "$T/run/update.json" .pending_count)" 2 "2: two pending packages"
chk "$(jf "$T/run/update.json" .reboot_pending)" true "2: musl -> reboot needed"
grep -q '^APK upgrade$' "$T/apk.calls" || { echo "FAIL: 2: apk upgrade not run"; fail=1; }
grep -q '^CALL reboot' "$T/calls" || { echo "FAIL: 2: reboot not called inside the window"; fail=1; }
[ -e "$T/state/reboot-marker" ] || { echo "FAIL: 2: reboot-marker not written"; fail=1; }
chk "$(jf "$T/run/update.json" .last_result)" ok "2: last_result ok"

# ---- 2a: only a tsx-* package is pending (a new common release): the services keep the old code, so reboot
rm -f "$T/state/reboot-marker"
printf '(1/1) Upgrading tsx-ha (0.2.1-r0 -> 0.2.2-r0)\n' > "$T/sim.txt"
reset_calls
NOWDATE=2026-01-01 NOWHHMM=04:00 run >/dev/null
chk "$(jf "$T/run/update.json" .reboot_pending)" true "2a: a tsx-ha upgrade needs a reboot"
grep -q '^APK upgrade$' "$T/apk.calls" || { echo "FAIL: 2a: apk upgrade not run"; fail=1; }
grep -q '^CALL reboot' "$T/calls" || { echo "FAIL: 2a: no reboot after a tsx-ha install inside the window"; fail=1; }
[ -e "$T/state/reboot-marker" ] || { echo "FAIL: 2a: reboot-marker not written (no health check after the reboot)"; fail=1; }
rm -f "$T/state/reboot-marker"
# the same upgrade with REBOOT=never: installed, no reboot, the reboot stays pending
printf 'ENABLED=1\nWINDOW=03:00-05:00\nREBOOT=never\n' > "$T/autoupdate.conf"
reset_calls
NOWDATE=2026-01-01 NOWHHMM=04:00 run >/dev/null
grep -q '^CALL reboot' "$T/calls" && { echo "FAIL: 2a: rebooted with REBOOT=never"; fail=1; }
chk "$(jf "$T/run/update.json" .reboot_pending)" true "2a: REBOOT=never: the reboot stays pending"
printf 'ENABLED=1\nWINDOW=03:00-05:00\nREBOOT=auto\n' > "$T/autoupdate.conf"
rm -f "$T/state/reboot-marker"
# tsx-keys is a public key: no reboot
printf '(1/1) Upgrading tsx-keys (1-r0 -> 1-r1)\n' > "$T/sim.txt"
reset_calls
NOWDATE=2026-01-01 NOWHHMM=04:00 run >/dev/null
chk "$(jf "$T/run/update.json" .reboot_pending)" false "2a: a tsx-keys upgrade needs no reboot"
grep -q '^CALL reboot' "$T/calls" && { echo "FAIL: 2a: rebooted for tsx-keys"; fail=1; }
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
chk "$(jf "$T/run/update.json" .pending_count)" 1 "10: Alpine update still counted"
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

# ---- 14: no Chromium call at all ------------------------------------------------
grep -qi chromium "$T/apk.calls" "$T/calls" "$T/tsx-autoupdate.log" && { echo "FAIL: 14: a Chromium call or log line"; fail=1; }

[ $fail = 0 ] && echo "PASS tsx-autoupdate flow (check/install/window/idle/status/healthcheck/repositories/kernel)"
exit $fail
