#!/bin/bash
# Host test for the layout file of tsx-overlay (kiosk/src/tsx-overlay-config.h):
# a valid file, a file with no grid, broken files (not JSON, a wrong version,
# no widgets, a grid out of range, a widget with no type, a bad x) and a
# missing file. A bad or missing file must give the built-in layout. Also the
# order of the files, and that the shipped default file equals the built-in
# layout. It compiles C with cJSON (libcjson-dev), so run it on a build host or
# in CI. Without the cJSON header it prints SKIPPED.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CC=${CC:-gcc}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
if ! echo '#include <cjson/cJSON.h>' | $CC -E -x c - >/dev/null 2>&1; then
	echo "SKIPPED test-overlay-config: no cJSON header (libcjson-dev)"; exit 0
fi
mkdir "$T/d"
cat > "$T/d/valid.json" <<'J'
{"version": 1, "timeout": 120, "grid": {"columns": 3, "rows": 2, "gap": 8, "tile": 120},
 "widgets": [{"type": "clock", "w": 2}, {"type": "reboot", "x": 2, "y": 1, "label": "Restart now"},
             {"type": "volume", "x": 1}, {"type": "no_such_widget"}]}
J
echo '{"version": 1, "widgets": [{"type": "close"}]}' > "$T/d/defaults.json"
echo '{"version": 1, "widgets": [' > "$T/d/invalid.json"
echo '{"version": 2, "widgets": [{"type": "close"}]}' > "$T/d/badversion.json"
echo '{"version": 1, "widgets": []}' > "$T/d/nowidgets.json"
echo '{"version": 1, "grid": {"columns": 13}, "widgets": [{"type": "close"}]}' > "$T/d/badgrid.json"
echo '{"version": 1, "widgets": [{"label": "x"}]}' > "$T/d/badtype.json"
echo '{"version": 1, "widgets": [{"type": "close", "x": -1, "y": 0}]}' > "$T/d/badx.json"
echo '{"version": 1, "timeout": -5, "widgets": [{"type": "close"}]}' > "$T/d/badtimeout.json"
: > "$T/d/empty.json"
$CC -O2 -Wall -Wextra -Werror -o "$T/check" "$HERE/overlay-config-check.c" -lcjson
"$T/check" "$T/d" "$HERE/../kiosk/usr/local/share/tsx/overlay.json"
echo "PASS test-overlay-config"
