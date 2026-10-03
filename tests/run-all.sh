#!/bin/bash
# Run the host tests of this repo, one by one, and print a summary.
#   tests/run-all.sh          the tests that need no compiler (they run anywhere)
#   tests/run-all.sh --c      also the tests that compile C (gcc or CC). Run
#                             these only on a build host or in CI.
#   tests/run-all.sh --net    also the tests that need network access (pip)
# The lists are explicit. A new test goes into one of them.
set -u
cd "$(dirname "$0")/.."
PLAIN="test-brightness-learn test-autoupdate-logic test-autoupdate-flow test-board-fake test-bt test-clock test-confont test-panel-board
test-panelctl test-rescue-backlight test-rescue-login test-rescue-screen test-root-login test-setup test-shim-camera test-shim-keys test-shim-ledbar test-shim-sensors
test-tsx-config test-tsx-config-apply test-tsx-data test-tsx-setup-mac
test-voice-esphome-run mqtt-dry mqtt-stop-timeout"
CTESTS="test-buttons test-idled test-idled-als test-idled-display test-idled-ramp test-idled-runtime test-level test-orientation test-splash"
NET="test-esphome test-esphome-ledbar"
list=$PLAIN
for a in "$@"; do
	case "$a" in
	--c) list="$list $CTESTS";;
	--net) list="$list $NET";;
	*) echo "usage: $0 [--c] [--net]" >&2; exit 2;;
	esac
done
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
