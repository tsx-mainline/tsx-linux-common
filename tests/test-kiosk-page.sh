#!/bin/bash
# Host test for tsx-kiosk-page. A fake Chromium DevTools endpoint (fakesrv.py)
# logs the command that the tool sends. The tool must send Page.reload for
# reload, and Page.navigate for home and navigate. It must refuse a URL that
# is not http or https, and it must fail with a message when DevTools is off.
# Usage: tests/test-kiosk-page.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib/paths.sh"
TOOL=$(P usr/local/bin/tsx-kiosk-page)
T=$(mktemp -d); PIDS=
trap 'for p in $PIDS; do kill $p 2>/dev/null || true; done; rm -rf $T' EXIT
HA_PORT=$((20000 + RANDOM % 10000)); CDP_PORT=$((HA_PORT + 1))
mkdir -p $T/log $T/run
python3 $HERE/fakesrv.py $HA_PORT $CDP_PORT $T/log & PIDS="$PIDS $!"
printf 'KIOSK_URL="https://ha.example.org/lovelace/0"\n' > $T/kiosk.conf
export TSX_DEVTOOLS=127.0.0.1:$CDP_PORT TSX_KIOSK_CONF=$T/kiosk.conf TSX_RUN_DIR=$T/run
sleep 0.5
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "ok: $*"; }
last() { tail -n 1 $T/log/cdp.log; }
lines() { if [ -f $T/log/cdp.log ]; then wc -l < $T/log/cdp.log; else echo 0; fi; }

"$TOOL" reload || fail "reload: exit $?"
[ "$(last)" = '{"id": 1, "method": "Page.reload", "params": {"ignoreCache": false}}' ] || fail "reload: sent '$(last)'"
ok "reload -> Page.reload on the first page target (not the service worker)"

"$TOOL" navigate https://ha.example.org/dashboard-x/y?z=1 || fail "navigate: exit $?"
[ "$(last)" = '{"id": 1, "method": "Page.navigate", "params": {"url": "https://ha.example.org/dashboard-x/y?z=1"}}' ] || fail "navigate: sent '$(last)'"
ok "navigate URL -> Page.navigate with that URL"

"$TOOL" navigate /lovelace/lights || fail "navigate path: exit $?"
[ "$(last)" = '{"id": 1, "method": "Page.navigate", "params": {"url": "https://ha.example.org/lovelace/lights"}}' ] || fail "navigate path: sent '$(last)'"
ok "navigate /path -> the origin of KIOSK_URL plus the path"

"$TOOL" home || fail "home: exit $?"
[ "$(last)" = '{"id": 1, "method": "Page.navigate", "params": {"url": "https://ha.example.org/lovelace/0"}}' ] || fail "home: sent '$(last)'"
echo 'KIOSK_URL="https://panel.example.org/start"' > $T/run/kiosk.conf
"$TOOL" home || fail "home with override: exit $?"
[ "$(last)" = '{"id": 1, "method": "Page.navigate", "params": {"url": "https://panel.example.org/start"}}' ] || fail "home with override: sent '$(last)'"
ok "home -> KIOSK_URL. The panel.conf override in the run directory wins"

n=$(lines)
for bad in 'javascript:alert(1)' 'file:///etc/passwd' 'ha.example.org' '//evil.example.org/x' ''; do
	if "$TOOL" navigate "$bad" 2>$T/err; then fail "navigate '$bad': accepted"; fi
done
[ "$(lines)" = "$n" ] || fail "a refused URL reached the browser"
ok "navigate refuses javascript:, file:, a name with no scheme, //host and an empty URL"

rm -f $T/kiosk.conf $T/run/kiosk.conf
if "$TOOL" home 2>$T/err; then fail "home without KIOSK_URL: exit 0"; fi
grep -q 'no KIOSK_URL' $T/err || fail "home without KIOSK_URL: message '$(cat $T/err)'"
if "$TOOL" navigate /path 2>$T/err; then fail "navigate /path without KIOSK_URL: exit 0"; fi
ok "home and navigate /path without KIOSK_URL: exit 1 and a message"

TSX_DEVTOOLS=127.0.0.1:1 "$TOOL" reload 2>$T/err && fail "no DevTools: exit 0"
grep -q 'DevTools not reachable at 127.0.0.1:1' $T/err || fail "no DevTools: message '$(cat $T/err)'"
ok "DevTools off: exit 1 and a message"

for args in "" "bogus" "reload extra" "navigate" "home extra"; do
	set +e; "$TOOL" $args 2>/dev/null; rc=$?; set -e
	[ $rc = 2 ] || fail "arguments '$args': exit $rc, want 2"
done
ok "a wrong command line: exit 2"
echo "PASS test-kiosk-page"
