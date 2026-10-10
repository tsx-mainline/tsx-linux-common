#!/bin/bash
# Run the host tests of this repo, one by one, and print a summary.
#   tests/run-all.sh          the tests that need no compiler (they run anywhere)
#   tests/run-all.sh --c      also the tests that compile C (gcc or CC). Run
#                             these only on a build host or in CI.
#   tests/run-all.sh --net    also the tests that need network access (pip)
# The lists are explicit. A new test goes into one of them.
set -u
cd "$(dirname "$0")/.."
PLAIN="test-brightness-learn test-autoupdate-logic test-autoupdate-flow test-board-fake test-bt test-clock test-confont test-ledbard test-panel-board
test-panelctl test-rescue-backlight test-rescue-login test-rescue-screen test-root-login test-setup test-setup-page test-shim-keypad test-shim-keys test-shim-ledbar test-shim-sensors test-shim-wakewords
test-tsx-config test-tsx-config-apply test-tsx-data test-tsx-setup-mac test-kiosk-page test-missing-parts
test-voice-esphome-run mqtt-dry mqtt-ledbar-live mqtt-stop-timeout
test-config-plugins test-shim-plugins test-generic-gate test-panel-layout"
CTESTS="ledbar-host-test test-buttons test-idled test-idled-als test-idled-display test-idled-ramp test-idled-runtime test-level test-orientation test-overlay-max test-splash"
NET="test-esphome test-esphome-ledbar test-esphome-wakewords"
list=$PLAIN
for a in "$@"; do
	case "$a" in
	--c) list="$list $CTESTS";;
	--net) list="$list $NET";;
	*) echo "usage: $0 [--c] [--net]" >&2; exit 2;;
	esac
done
# The panel scripts run under busybox ash. The sh of Debian and Ubuntu is dash.
# It has no read -t and other parts that the scripts use, so test-rescue-screen
# and mqtt-stop-timeout fail under it. Put an sh that runs busybox sh at the
# front of PATH, so that every test runs the scripts as the panel does.
if command -v busybox >/dev/null 2>&1; then
	SHDIR=$(mktemp -d)
	trap 'rm -rf "$SHDIR"' EXIT
	printf '#!/bin/sh\nexec busybox sh "$@"\n' > "$SHDIR/sh"
	chmod 755 "$SHDIR/sh"
	if "$SHDIR/sh" -c 'exit 0'; then
		PATH=$SHDIR:$PATH
		echo "sh for the tests: busybox sh ($SHDIR/sh)"
	else
		echo "sh for the tests: $(command -v sh) (the busybox sh wrapper does not run in $SHDIR)"
	fi
else
	echo "sh for the tests: $(command -v sh) (no busybox on this host)"
fi
pass=0 failed=
for t in $list; do
	echo "=== $t"
	if bash "tests/$t.sh" > "${TSX_TEST_LOGDIR:-/tmp}/tsx-$t.log" 2>&1; then
		pass=$((pass + 1)); tail -n 1 "${TSX_TEST_LOGDIR:-/tmp}/tsx-$t.log"
	else
		failed="$failed $t"; tail -n 15 "${TSX_TEST_LOGDIR:-/tmp}/tsx-$t.log"
	fi
done
echo "== $pass passed, failed:${failed:- none}"
[ -z "$failed" ]
