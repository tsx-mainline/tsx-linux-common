#!/bin/bash
# Host test for panel-app/esphome/components/tsx_cards/control.h: the control
# interface of the panel app (docs/panel-app.md, "Control from the panel").
#  - the command lines that tsx-panelctl writes to control.d: the exact forms
#    pass, every other line is refused
#  - the files of control.d: the order of the names, the removal, no
#    temporary file, no link or large file
#  - the text of screen.state, which tsx-panelctl get and state read
#  - the SHA-256 of the "Layout hash" sensor, against sha256sum
#  - end to end with the real tsx-panelctl: the files that the daemon writes
#    are the commands that the app runs
# It compiles C++, so run it only on a build host or in CI.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC=$HERE/panel-app/esphome/components/tsx_cards
PANELCTL=$HERE/base/usr/local/sbin/tsx-panelctl
. "$HERE/tests/lib/board.sh"
CXX=${CXX:-c++}
command -v "$CXX" >/dev/null 2>&1 || { echo "SKIPPED test-panel-app-control: no $CXX"; exit 0; }
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED test-panel-app-control: no busybox"; exit 0; }
T=$(mktemp -d)
PID=
trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }

cat > "$T/main.cpp" <<'C'
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include "control.h"
using namespace esphome::tsx_cards;
// ct parse LINE | ct take DIR | ct text S BL DIM BLANK DL LIGHTS BRI R G B | ct sha FILE
// ct cfg KEY VALUE | ct lres FILE ID | ct fifo PATH LINE
int main(int argc, char **argv) {
  if (argc == 4 && !strcmp(argv[1], "cfg")) {
    puts(panelctl_config_line(argv[2], argv[3]).c_str());
    return 0;
  }
  if (argc == 4 && !strcmp(argv[1], "lres")) {
    std::ifstream f(argv[2], std::ios::binary);
    std::stringstream ss;
    ss << f.rdbuf();
    int rc = -1;
    std::string first;
    if (!parse_layout_result(ss.str(), atoi(argv[3]), rc, first)) { puts("no"); return 1; }
    printf("%d|%s\n", rc, first.c_str());
    return 0;
  }
  if (argc == 4 && !strcmp(argv[1], "fifo")) {
    std::string err;
    if (fifo_send_line(argv[2], argv[3], err)) { puts("sent"); return 0; }
    printf("err %s\n", err.c_str());
    return 1;
  }
  if (argc == 3 && !strcmp(argv[1], "parse")) {
    ControlCmd c;
    if (!parse_control_line(argv[2], c)) { puts("refused"); return 1; }
    printf("%d %d %d %d %d %d\n", (int) c.kind, (int) c.on, c.value, c.r, c.g, c.b);
    return 0;
  }
  if (argc == 3 && !strcmp(argv[1], "take")) {
    for (const auto &l : take_control_lines(argv[2])) fputs(l.c_str(), stdout);
    return 0;
  }
  if (argc == 12 && !strcmp(argv[1], "text")) {
    int v[10];
    for (int i = 0; i < 10; i++) v[i] = atoi(argv[i + 2]);
    fputs(screen_state_text(v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9]).c_str(), stdout);
    return 0;
  }
  if (argc == 3 && !strcmp(argv[1], "sha")) {
    std::ifstream f(argv[2], std::ios::binary);
    std::stringstream ss;
    ss << f.rdbuf();
    puts(sha256_hex(ss.str()).c_str());
    return 0;
  }
  return 2;
}
C
"$CXX" -std=gnu++20 -O1 -Wall -Werror -I"$SRC" -o "$T/ct" "$T/main.cpp" || { echo "FAIL: compile"; exit 1; }

echo "== command lines =="
for pair in "screen on|1 1 0 0 0 0" "screen off|1 0 0 0 0 0" "backlight 1|2 0 1 0 0 0" "backlight 100|2 0 100 0 0 0" \
	"lights on|3 1 0 0 0 0" "lights off|3 0 0 0 0 0" "lights 50 255 0 7|4 1 50 255 0 7"; do
	line=${pair%%|*} want=${pair#*|}
	[ "$("$T/ct" parse "$line")" = "$want" ] && ok "'$line' -> $want" || bad "'$line': $("$T/ct" parse "$line")"
done
for line in "screen" "screen dim" "screen on now" "backlight 0" "backlight 101" "backlight 0050" "backlight -5" \
	"backlight 5x" "lights 0 1 2 3" "lights 50 256 0 0" "lights 50 1 2" "lights maybe" "reboot" "" \
	"$(printf 'screen\001 on')" "SCREEN ON"; do
	"$T/ct" parse "$line" > /dev/null && bad "accepted: '$line'" || ok "refused: '$(printf '%s' "$line" | tr -d '\001')'"
done

echo "== the files of control.d =="
D=$T/control.d; mkdir -p "$D"
printf 'screen off\n' > "$D/0000000001.000002"
printf 'backlight 40\n' > "$D/0000000001.000001"
printf 'lights on\n' > "$D/0000000002.000001"
printf 'not done\n' > "$D/.tmp.123"
head -c 400 /dev/zero | tr '\0' 'x' > "$D/0000000003.000001"
ln -s /etc/passwd "$D/0000000004.000001"
got=$("$T/ct" take "$D")
[ "$got" = "$(printf 'backlight 40\nscreen off\nlights on\n(not a small regular file)(not a small regular file)')" ] \
	&& ok "the lines in the order of the names; a large file and a link give no line of their own" || bad "take: $got"
[ "$(ls -A "$D")" = ".tmp.123" ] && ok "every file is removed, only the temporary file stays" || bad "left: $(ls -A "$D")"
[ -z "$("$T/ct" take "$T/no-such-dir")" ] && ok "a missing folder gives no line" || bad "missing folder"

echo "== screen.state =="
want=$(printf 'screen dim\nbacklight 64\ndim-timeout 60\nblank-timeout 300\ndim-level 20\nlights on 80 255 128 0')
[ "$("$T/ct" text 1 64 60 300 20 1 80 255 128 0)" = "$want" ] && ok "with lights" || bad "text: $("$T/ct" text 1 64 60 300 20 1 80 255 128 0)"
"$T/ct" text 2 64 60 300 20 -1 0 0 0 0 | grep -q '^lights' && bad "lights line without lights" || ok "no lights line without lights"
[ "$("$T/ct" text 2 64 60 300 20 -1 0 0 0 0 | sed -n 1p)" = "screen off" ] && ok "screen off" || bad "screen off"

echo "== SHA-256 =="
printf '' > "$T/e"; printf 'abc' > "$T/a"; head -c 200000 /dev/urandom > "$T/r"; printf '%s' "$(printf 'x%.0s' $(seq 1 56))" > "$T/b56"
for f in e a r b56; do
	[ "$("$T/ct" sha "$T/$f")" = "$(sha256sum "$T/$f" | cut -d' ' -f1)" ] && ok "sha256 of $f matches sha256sum" || bad "sha256 of $f"
done

echo "== end to end: tsx-panelctl writes, the app takes =="
mkdir -p "$T/run/panel-app" "$T/proc/777"
printf 'pid 777\n' > "$T/run/panel-app.state"
TSX_RUN_DIR="$T/run" TSX_PROC_DIR="$T/proc" TSX_IDLED_STATE="$T/idled.state" busybox sh "$PANELCTL" > "$T/pc.log" 2>&1 &
PID=$!
for _ in $(seq 1 20); do grep -q "listening on" "$T/pc.log" 2>/dev/null && break; sleep 0.1; done
for l in "brightness-pct 33" "blank on" "lights set 20 1 2 3" "blank off"; do echo "$l" > "$T/run/panelctl"; sleep 0.15; done
got=$("$T/ct" take "$T/run/panel-app/control.d")
[ "$got" = "$(printf 'backlight 33\nscreen off\nlights 20 1 2 3\nscreen on')" ] && ok "the app gets the four commands in order" || bad "end to end: $got"
bad_lines=0
for l in $(printf '%s\n' "$got" | tr ' ' '_'); do "$T/ct" parse "$(printf '%s' "$l" | tr '_' ' ')" > /dev/null || bad_lines=$((bad_lines + 1)); done
[ "$bad_lines" = 0 ] && ok "every line that tsx-panelctl writes passes the parser of the app" || bad "$bad_lines lines refused by the app"

echo "== the lines for tsx-panelctl (an app that does not run as root) =="
[ "$("$T/ct" cfg BLANK_TIMEOUT 300)" = "blank-timeout 300" ] && [ "$("$T/ct" cfg DIM_TIMEOUT 0)" = "dim-timeout 0" ] \
	&& [ "$("$T/ct" cfg DIM_LEVEL 25)" = "dim-level 25" ] && ok "BLANK_TIMEOUT, DIM_TIMEOUT, DIM_LEVEL -> the commands" || bad "cfg lines"
for kv in "KIOSK_URL http" "BLANK_TIMEOUT 3x" "BLANK_TIMEOUT -1" "DIM_LEVEL 1234567" "BLANK_TIMEOUT "; do
	[ -z "$("$T/ct" cfg ${kv% *} "${kv#* }")" ] && ok "no line for '$kv'" || bad "a line for '$kv'"
done
printf 'id 17\nrc 0\n' > "$T/lr"
[ "$("$T/ct" lres "$T/lr" 17)" = "0|" ] && ok "layout.result: id 17 rc 0" || bad "lres 17"
"$T/ct" lres "$T/lr" 18 > /dev/null && bad "the result of another id counts" || ok "the result of another id does not count"
printf 'id 18\nrc 1\ncard 3: no entity_id\nmore\n' > "$T/lr"
[ "$("$T/ct" lres "$T/lr" 18)" = "1|card 3: no entity_id" ] && ok "layout.result: rc 1 and the first line" || bad "lres rc 1: $("$T/ct" lres "$T/lr" 18)"
printf 'rc 0\n' > "$T/lr"; "$T/ct" lres "$T/lr" 0 > /dev/null && bad "a file with no id counts" || ok "a file with no id does not count"
: > "$T/lr"; "$T/ct" lres "$T/lr" 0 > /dev/null && bad "an empty file counts" || ok "an empty file does not count"
mkfifo "$T/ff"
case "$("$T/ct" fifo "$T/ff" "reboot")" in "err cannot open"*) true;; *) false;; esac && ok "no reader on the FIFO: the send fails at once" || bad "send with no reader"
( exec 3<>"$T/ff"; "$T/ct" fifo "$T/ff" "layout-install 5" > "$T/ffout"; head -n 1 <&3 > "$T/ffread" )
[ "$(cat "$T/ffout")" = sent ] && [ "$(cat "$T/ffread")" = "layout-install 5" ] && ok "the line reaches the reader of the FIFO" || bad "fifo: $(cat "$T/ffout") / $(cat "$T/ffread")"
case "$("$T/ct" fifo "$T/lr" "reboot")" in "err no FIFO"*) true;; *) false;; esac && ok "a regular file is not a FIFO: refused" || bad "regular file"
case "$("$T/ct" fifo "$T/ff" "")" in "err bad"*) true;; *) false;; esac && ok "an empty line is refused" || bad "empty line"

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo PASS test-panel-app-control || echo FAIL test-panel-app-control
exit $F
