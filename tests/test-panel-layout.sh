#!/bin/sh
# Host test for the layout files of the panel app (docs/panel-app.md). The
# test checks:
#  - icons.h and icon-glyphs.yaml agree with icons.txt (mkicons.py --check)
#  - the example layout and the schema
#  - tsx-layout-check: errors, warnings, exit codes and the placement of the
#    cards (the same rules as the C++ component)
#  - tsx-layout-check --install: it refuses a link, a file that is too big and
#    a layout with an error, and leaves the destination as it was. It installs
#    a good layout with mode 644, byte for byte
# The test runs under busybox or dash sh and needs python3, no compiler.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
PA=$HERE/panel-app
CHECK=$PA/usr/local/bin/tsx-layout-check
export TSX_ICON_FILE=$PA/usr/local/share/tsx/panel-app/icons.txt
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }

echo "== icons =="
python3 "$PA/esphome/mkicons.py" --check && ok "icons.h and icon-glyphs.yaml are up to date" || bad "mkicons.py --check"
grep -q '{"lightbulb", 0xF0335}' "$PA/esphome/components/tsx_cards/icons.h" && ok "icons.h has lightbulb" || bad "no lightbulb in icons.h"

echo "== example layout and schema =="
python3 "$CHECK" "$PA/usr/local/share/tsx/panel-app/example-layout.json" > "$T/out" && ok "example layout passes" || bad "example layout: $(cat "$T/out")"
grep -q 'warning' "$T/out" && bad "example layout has warnings: $(cat "$T/out")" || ok "example layout has no warning"
python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$PA/usr/local/share/tsx/panel-app/layout.schema.json" && ok "schema is JSON" || bad "schema is not JSON"

# run NAME EXPECTED_EXIT PATTERN JSON: check JSON, the exit code and that
# the output has PATTERN.
run() {
	printf '%s\n' "$4" > "$T/$1.json"
	rc=0
	python3 "$CHECK" "$T/$1.json" > "$T/$1.out" 2>&1 || rc=$?
	if [ "$rc" = "$2" ] && grep -q -- "$3" "$T/$1.out"; then
		ok "$1"
	else
		bad "$1: exit $rc, output: $(cat "$T/$1.out")"
	fi
}

echo "== file errors =="
run bad-json 1 'error: not valid JSON' '{"version": 1,'
run not-object 1 'top level must be an object' '[1]'
run version 1 '"version" must be 1' '{"version": 2, "pages": [{}]}'
run no-pages 1 '"pages" must be a list' '{"version": 1, "pages": []}'
run bad-grid 1 'columns and rows must be 1 to 12' '{"version": 1, "grid": {"columns": 13}, "pages": [{}]}'
run bad-color 1 'must be a color' '{"version": 1, "theme": {"card": "red"}, "pages": [{}]}'
run bad-key 1 'key "home": unknown action "page:0"' '{"version": 1, "keys": {"home": "page:0"}, "pages": [{}]}'
run key-default 1 'unknown action "default"' '{"version": 1, "keys": {"home": "default"}, "pages": [{}]}'

echo "== card errors =="
run no-type 1 'page 1 card 1: no "type"' '{"version": 1, "pages": [{"cards": [{"entity_id": "light.a"}]}]}'
run bad-type 1 'unknown type "fan"' '{"version": 1, "pages": [{"cards": [{"type": "fan", "entity_id": "fan.a"}]}]}'
run no-entity 1 'no valid "entity_id"' '{"version": 1, "pages": [{"cards": [{"type": "sensor"}]}]}'
run bad-entity 1 'no valid "entity_id"' '{"version": 1, "pages": [{"cards": [{"type": "sensor", "entity_id": "Sensor.A"}]}]}'
run wrong-domain 1 'a light card needs a light entity' '{"version": 1, "pages": [{"cards": [{"type": "light", "entity_id": "switch.a"}]}]}'
run bad-icon 1 '"icon" must be "mdi:name"' '{"version": 1, "pages": [{"cards": [{"type": "light", "entity_id": "light.a", "icon": "lightbulb"}]}]}'
run too-wide 1 '"w" must be 1 to the columns' '{"version": 1, "pages": [{"cards": [{"type": "clock", "w": 5}]}]}'
run x-only 1 'give both "x" and "y"' '{"version": 1, "pages": [{"cards": [{"type": "clock", "x": 1}]}]}'
run past-edge 1 'goes past the edge' '{"version": 1, "pages": [{"cards": [{"type": "clock", "x": 3, "y": 0, "w": 2}]}]}'
run bad-precision 1 '"precision" must be 0 to 6' '{"version": 1, "pages": [{"cards": [{"type": "sensor", "entity_id": "sensor.a", "precision": 7}]}]}'
run bad-tap 1 '"tap": an action object needs' '{"version": 1, "pages": [{"cards": [{"type": "light", "entity_id": "light.a", "tap": {"data": {}}}]}]}'
run tap-page 1 '"tap": unknown action "next_page"' '{"version": 1, "pages": [{"cards": [{"type": "light", "entity_id": "light.a", "tap": "next_page"}]}]}'
run bad-data 1 'data "x" of an action' '{"version": 1, "pages": [{"cards": [{"type": "light", "entity_id": "light.a", "tap": {"action": "light.turn_on", "data": {"x": [1]}}}]}]}'
run overlap 1 'page 1 card 2: overlaps an earlier card' '{"version": 1, "pages": [{"cards": [{"type": "clock", "x": 0, "y": 0, "w": 2}, {"type": "clock", "x": 1, "y": 0}]}]}'
run no-room 1 'page 1 card 3: no free place' '{"version": 1, "pages": [{"columns": 2, "rows": 1, "cards": [{"type": "clock"}, {"type": "clock"}, {"type": "clock"}]}]}'

echo "== warnings =="
run unknown-key 0 'warning: page 1 card 1: unknown key "colour"' '{"version": 1, "pages": [{"cards": [{"type": "clock", "colour": 1}]}]}'
run unknown-icon 0 'icon mdi:no-such-icon is not in the icon font' '{"version": 1, "pages": [{"cards": [{"type": "light", "entity_id": "light.a", "icon": "mdi:no-such-icon"}]}]}'
run clock-entity 0 'a clock card has no entity_id' '{"version": 1, "pages": [{"cards": [{"type": "clock", "entity_id": "sensor.a"}]}]}'
run key-setup 0 'OK, 1 pages' '{"version": 1, "keys": {"power": "setup"}, "pages": [{}]}'
run tap-setup 1 '"tap": unknown action "setup"' '{"version": 1, "pages": [{"cards": [{"type": "light", "entity_id": "light.a", "tap": "setup"}]}]}'
run ok-actions 0 'OK, 1 pages, 1 cards' '{"version": 1, "keys": {"power": "none", "home": "page:16", "up": {"action": "light.toggle", "data": {"entity_id": "light.a"}}}, "pages": [{"cards": [{"type": "light", "entity_id": "light.a", "tap": {"action": "light.turn_on", "data": {"brightness_pct": 50, "transition": 1.5, "flash": false}}}]}]}'

echo "== placement =="
# Fixed cards first, then the others row by row in the first free cell.
printf '%s\n' '{"version": 1, "pages": [{"columns": 3, "rows": 2, "cards": [
 {"type": "clock", "w": 2},
 {"type": "clock", "x": 0, "y": 1},
 {"type": "clock", "h": 2},
 {"type": "clock"}]}]}' > "$T/place.json"
python3 "$CHECK" --placed "$T/place.json" > "$T/place.out"
got=$(sed -n '/^{/,$p' "$T/place.out" | python3 -c 'import json, sys; print(" ".join("%d,%d" % (c["x"], c["y"]) for c in json.load(sys.stdin)["pages"][0]["cards"]))')
[ "$got" = "0,0 0,1 2,0 1,1" ] && ok "placement 0,0 0,1 2,0 1,1" || bad "placement: $got"

echo "== --install =="
GOOD='{"version": 1, "pages": [{"name": "A", "cards": [{"type": "clock"}]}]}'
printf '%s\n' "$GOOD" > "$T/good.json"
printf '{"version": 1, "pages": [{"cards": [{"type": "fan"}]}]}\n' > "$T/bad.json"
# an old destination, to see that a refusal leaves it as it was
mkdir -p "$T/dest"; printf 'OLD\n' > "$T/dest/layout.json"
inst() { rc=0; python3 "$CHECK" --install "$@" > "$T/inst.out" 2>&1 || rc=$?; }
inst "$T/good.json" "$T/dest/layout.json"
[ "$rc" = 0 ] && cmp -s "$T/good.json" "$T/dest/layout.json" && ok "install: a good layout is installed byte for byte" || bad "install good: $rc $(cat "$T/inst.out")"
[ "$(stat -c %a "$T/dest/layout.json")" = 644 ] && ok "install: mode 644" || bad "install mode: $(stat -c %a "$T/dest/layout.json")"
ls "$T/dest" | grep -q 'tmp' && bad "install: a temporary file stays: $(ls "$T/dest")" || ok "install: no temporary file stays"
# the bytes stay as they are, also when another serialization is shorter
printf '{\n  "version": 1,\n  "pages": [ {"cards": []} ]\n}\n' > "$T/spaced.json"
inst "$T/spaced.json" "$T/dest/layout.json"
cmp -s "$T/spaced.json" "$T/dest/layout.json" && ok "install: the bytes that were checked are the bytes that are installed" || bad "install spaced: $(cat "$T/dest/layout.json")"
chmod 600 "$T/dest/layout.json"
inst "$T/good.json" "$T/dest/layout.json"
[ "$(stat -c %a "$T/dest/layout.json")" = 644 ] && ok "install: an older file with mode 600 gets mode 644" || bad "install mode over an old file"
printf 'OLD\n' > "$T/dest/layout.json"
inst "$T/bad.json" "$T/dest/layout.json"
[ "$rc" = 1 ] && grep -q 'page 1 card 1: unknown type "fan"' "$T/inst.out" && [ "$(cat "$T/dest/layout.json")" = OLD ] && ok "install: a layout with an error is refused, the errors are printed, the destination stays" || bad "install bad: $rc $(cat "$T/inst.out")"
ln -s "$T/good.json" "$T/link.json"
inst "$T/link.json" "$T/dest/layout.json"
[ "$rc" = 1 ] && [ "$(cat "$T/dest/layout.json")" = OLD ] && ok "install: a symbolic link as the source is refused" || bad "install link: $rc $(cat "$T/inst.out")"
python3 -c 'import sys; sys.stdout.write("{\"version\": 1, \"pages\": [{\"name\": \"" + "a" * 70000 + "\"}]}")' > "$T/big.json"
inst "$T/big.json" "$T/dest/layout.json"
[ "$rc" = 1 ] && grep -q 'larger than 65536' "$T/inst.out" && [ "$(cat "$T/dest/layout.json")" = OLD ] && ok "install: a file of more than 65536 bytes is refused" || bad "install big: $rc $(cat "$T/inst.out")"
python3 -c 'import sys; sys.stdout.write("{\"version\": 1, \"pages\": [{\"name\": \"" + "a" * 65400 + "\"}]}")' > "$T/limit.json"
inst "$T/limit.json" "$T/dest/layout.json"
[ "$rc" = 0 ] && ok "install: a file just under 65536 bytes is accepted" || bad "install limit: $rc $(cat "$T/inst.out")"
printf 'OLD\n' > "$T/dest/layout.json"
mkdir "$T/adir"
inst "$T/adir" "$T/dest/layout.json"
[ "$rc" = 1 ] && grep -q 'not a regular file' "$T/inst.out" && ok "install: a folder as the source is refused" || bad "install folder: $rc $(cat "$T/inst.out")"
inst /dev/null "$T/dest/layout.json"
[ "$rc" = 1 ] && grep -q 'not a regular file' "$T/inst.out" && ok "install: a device as the source is refused" || bad "install device: $rc $(cat "$T/inst.out")"
mkfifo "$T/fifo.json"
inst "$T/fifo.json" "$T/dest/layout.json"
[ "$rc" = 1 ] && ok "install: a FIFO as the source is refused, and the tool does not wait" || bad "install fifo: $rc"
inst "$T/missing.json" "$T/dest/layout.json"
[ "$rc" = 1 ] && [ "$(cat "$T/dest/layout.json")" = OLD ] && ok "install: a missing source is refused" || bad "install missing: $rc"
printf '\377\376{"version": 1}' > "$T/utf.json"
inst "$T/utf.json" "$T/dest/layout.json"
[ "$rc" = 1 ] && grep -q 'not UTF-8' "$T/inst.out" && ok "install: text that is not UTF-8 is refused" || bad "install utf: $rc $(cat "$T/inst.out")"
printf '{"version": 1, "pages": [{"cards": [{"type": "clock"}]}]}' > "$T/new.json"
inst "$T/new.json" "$T/newdir/sub/layout.json"
[ "$rc" = 0 ] && [ "$(stat -c %a "$T/newdir/sub")" = 755 ] && cmp -s "$T/new.json" "$T/newdir/sub/layout.json" && ok "install: a missing folder is made with mode 755" || bad "install folder make: $rc $(cat "$T/inst.out")"
inst "$T/good.json"
[ "$rc" = 2 ] && ok "install: a missing destination is a usage error (exit 2)" || bad "install usage: $rc"

echo "== usage =="
rc=0; python3 "$CHECK" > /dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && ok "no file: exit 2" || bad "no file: exit $rc"

echo "== $N ok, $F failed =="
[ "$F" = 0 ]
