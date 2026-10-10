#!/bin/sh
# Host test: the layout parser of the app (panel-app/esphome/components/
# tsx_cards/layout.cpp) and tsx-layout-check give the same result. The test
# compiles layout.cpp with a small main (tests/layout-parity/parity.cpp) and
# runs both on each layout of the corpus: the JSON of each case of
# test-panel-layout.sh (LAYOUT_CORPUS) and the example layout. It compares the file error, the warnings (a card that the checker
# refuses is a warning "(left out)" in the app) and the placed cards.
#
# Needs a C++ compiler (c++) and the ArduinoJson 7 headers: set
# ARDUINOJSON_DIR to the folder with ArduinoJson.h (for example the
# .pio/libdeps folder of an ESPHome build). Without them the test is skipped.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
P=$HERE/tests/layout-parity
SRC=$HERE/panel-app/esphome/components/tsx_cards
[ -n "${ARDUINOJSON_DIR:-}" ] && [ -f "$ARDUINOJSON_DIR/ArduinoJson.h" ] || { echo "SKIPPED test-layout-parity: set ARDUINOJSON_DIR"; exit 0; }
command -v c++ >/dev/null 2>&1 || { echo "SKIPPED test-layout-parity: no c++"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
c++ -std=gnu++20 -O1 -I"$SRC" -I"$ARDUINOJSON_DIR" -o "$T/parity" "$P/parity.cpp" "$SRC/layout.cpp" || { echo "FAIL: compile"; exit 1; }
mkdir "$T/corpus"
LAYOUT_CORPUS=$T/corpus sh "$HERE/tests/test-panel-layout.sh" > "$T/layout-test.out" 2>&1 || { echo "FAIL: test-panel-layout.sh"; tail -5 "$T/layout-test.out"; exit 1; }
echo "corpus: $(ls "$T/corpus" | wc -l) layouts of test-panel-layout.sh"
cp "$HERE/panel-app/usr/local/share/tsx/panel-app/example-layout.json" "$T/corpus/example.json"
N=0 F=0
for f in "$T"/corpus/*.json; do
	"$T/parity" "$f" > "$T/app.out" 2>&1
	python3 "$P/parity.py" "$f" > "$T/check.out" 2>&1
	if python3 "$P/compare.py" "$T/app.out" "$T/check.out" > "$T/diff"; then
		N=$((N + 1))
	else
		F=$((F + 1))
		echo "  FAIL: $(basename "$f")"
		sed 's/^/    /' "$T/diff"
	fi
done
echo "== test-layout-parity: $N layouts agree, $F differ =="
[ "$F" = 0 ]
