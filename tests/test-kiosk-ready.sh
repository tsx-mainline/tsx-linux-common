#!/bin/bash
# Host test for the ready signal /run/tsx/kiosk.ready of tsx-kiosk-reveal.
# A fake swaymsg stands in for sway. The test checks that every reveal path
# writes the file (a page that never paints, and a browser with no DevTools),
# that --mark-ready writes it, that the write follows a link into another
# folder (as on the panel), and that no temporary file stays. It also checks
# the stale-file removal and the no-reveal marking in kiosk-session.
# Usage: tests/test-kiosk-ready.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib/paths.sh"
TOOL=$(P usr/local/bin/tsx-kiosk-reveal)
SESSION=$(P usr/local/bin/kiosk-session)
INIT=$(P etc/init.d/kiosk)
T=$(mktemp -d); trap 'rm -rf $T' EXIT
mkdir -p $T/bin $T/run $T/run/kiosk-ready.d
printf '#!/bin/sh\nexit 0\n' > $T/bin/swaymsg; chmod +x $T/bin/swaymsg
export PATH=$T/bin:$PATH TSX_KIOSK_READY=$T/run/kiosk.ready
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "ok: $*"; }
ln -s kiosk-ready.d/ready $T/run/kiosk.ready
R=$T/run/kiosk-ready.d/ready
check() {   # check REGEX WHAT
	[ -e $TSX_KIOSK_READY ] || fail "$2: no ready file"
	grep -Eq "^revealed $1 uptime [0-9.]+\$" $R || fail "$2: content '$(cat $R)'"
	[ "$(stat -c %a $R)" = 644 ] || fail "$2: mode $(stat -c %a $R)"
	[ "$(ls $T/run/kiosk-ready.d | wc -l)" = 1 ] || fail "$2: a temporary file stays: $(ls $T/run/kiosk-ready.d)"
	ok "$2: $(cat $R)"
}

[ ! -e $TSX_KIOSK_READY ] || fail "a dangling link counts as ready"
ok "a link with no file is not ready"

"$TOOL" http://x.example.org --devtools 0 --timeout 0 --delay 0 2>$T/err || fail "no DevTools: exit $?"
check 'no DevTools' "reveal without DevTools"
rm -f $R

TSX_REVEAL_DEVTOOLS=127.0.0.1:1 "$TOOL" http://x.example.org --devtools 1 --timeout 0 2>$T/err || fail "timeout: exit $?"
grep -q 'revealed: timeout' $T/err || fail "timeout: log '$(cat $T/err)'"
check 'timeout' "reveal after the timeout"
rm -f $R

"$TOOL" --mark-ready "no reveal, browser started" || fail "mark-ready: exit $?"
check 'no reveal, browser started' "--mark-ready"

# a plain file in a folder that the user can write (no link)
rm -f $TSX_KIOSK_READY $R
"$TOOL" --mark-ready x
[ -f $TSX_KIOSK_READY ] && [ ! -L $TSX_KIOSK_READY ] || fail "plain path: not a file"
ok "without a link, the file is written in place"

# kiosk-session removes the stale file of an older session, and marks ready
# when no reveal runs. The init script makes the link.
grep -q 'rm -f "\$_ready"' $SESSION || fail "kiosk-session does not remove a stale kiosk.ready"
grep -q 'readlink -f' $SESSION || fail "kiosk-session does not follow the link"
[ "$(grep -c 'mark_ready_soon$' $SESSION)" = 2 ] || fail "kiosk-session: want the no-reveal marking in the cage path and the else branch"
grep -q 'ln -sfn kiosk-ready.d/ready /run/tsx/kiosk.ready' $INIT || fail "the init script does not make the link"
ok "kiosk-session removes a stale file and marks ready when no reveal runs. The init script makes the link"
echo "PASS test-kiosk-ready"
