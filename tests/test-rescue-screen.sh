#!/bin/sh
# Host test for the rescue screen (rescue/usr/sbin/tsx-rescue-status),
# no panel needed:
#   - idle: the banner and "rescue", no "reason for rescue" or "status" rows,
#     the model without the firmware/tsid suffix, and the Enter line. An
#     operation section appears ONLY while an install or restore runs (name,
#     step, progress bar, do-not-power-off warning). The test also covers the
#     failed, done, stopped and stale-progress cases.
#   - no line is longer than the console (80 on 1280x800, 85 on 1024x600),
#     and there are at most 24 rows.
#   - no power-cycle advice on any rescue path.
#   - Enter on the keyboard tty opens the shell (the fake tty is a file). No
#     Enter does not. The shell banner warns while an operation runs.
#   - the state files that the tools write (tsx-install-state, tsx-op).
#   - the network line before rcS has set the MAC: "starting" and the MAC from
#     the board, never the random kernel MAC or "no address yet".
#   - the screen gets every board fact (model, firmware, unit id, MAC, extra
#     line) from the board file. It sources no other helper file.
# The test runs under busybox or dash sh and needs no compiler. The board is
# the made-up board of tests/boards/fake. Its MAC comes from a plain file.
set -eu
. "$(dirname "$0")/lib/board.sh"
HERE=$(cd "$(dirname "$0")/.." && pwd)
RS=$HERE/rescue/usr/sbin/tsx-rescue-status
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }

mkdir -p "$T/run" "$T/sbin"
printf '#!/bin/sh\n[ -e "%s/noip" ] || echo "2: eth0    inet 192.0.2.10/24 brd 192.0.2.255 scope global eth0"\n' "$T" > "$T/sbin/ip"
printf '#!/bin/sh\necho 7.2.8-00116-gb5862166389d\n' > "$T/sbin/uname"
chmod 755 "$T/sbin/ip" "$T/sbin/uname"
echo "02:fa:ce:00:00:01" > "$T/mac"
export TSX_MAC_DEV=$T/board-mac
echo "02:fa:ce:00:00:01" > "$TSX_MAC_DEV"
echo "built 2026-09-29, kernel flavor stable" > "$T/rver"
echo "quiet console=tty0" > "$T/cmdline"
echo "rescue image active" > "$T/run/rescue-reason"
echo fakefile > "$T/run/tsx-eth0-mac-src"
touch "$T/rescue-image"
sed -e "s|/proc/cmdline|$T/cmdline|g; s|/etc/tsx/rescue-image|$T/rescue-image|g" \
    -e "s|ip -4 -o addr show eth0|$T/sbin/ip|g; s|uname -r|$T/sbin/uname|; s|/sys/class/net/eth0/address|$T/mac|" \
    -e 's|> /dev/kmsg|> /dev/null|; s|> "\$TTY"|>> "$TTY"|' "$RS" > "$T/rs.sh"
export TSX_RUN=$T/run TSX_STATUS_TTY=$T/frame.raw TSX_VERFILE=$T/rver TSX_STATUS_IN=$T/keys TSX_STATUS_WAIT=1

# render [COLS]: one frame, escape codes stripped
render() {
	: > "$T/frame.raw"
	TSX_STATUS_COLS=${1:-80} sh "$T/rs.sh" once
	sed 's/\x1b\[[0-9?;]*[A-Za-z]//g' "$T/frame.raw" > "$T/frame"
}
has() { grep -q -- "$1" "$T/frame"; }
want()    { if has "$1"; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
wantnot() { if has "$1"; then bad "$2 (found: $1)"; else ok "$2"; fi; }
fit() { # COLS
	rows=$(wc -l < "$T/frame"); cols=$(awk '{ if (length > m) m = length } END { print m + 0 }' "$T/frame")
	[ "$cols" -le "$1" ] && ok "widest line $cols <= $1 columns" || bad "widest line $cols > $1 columns"
	[ "$rows" -le 24 ] && ok "$rows rows (+ the cursor row <= 25)" || bad "$rows rows"
}
clear_op() { rm -f "$T/run/tsx-install-state" "$T/run/tsx-op" "$T/run/tsx-progress"; }
running() { echo "$$ install" > "$T/run/tsx-op"; echo "$1" > "$T/run/tsx-install-state"; }

echo "== idle =="
clear_op; render
want '^\\___)=(___/   rescue$' "the line under the banner is just \"rescue\""
wantnot 'mainline rescue' "no \"mainline rescue -- MODEL ...\" line"
wantnot 'reason for rescue' "no reason row"
wantnot '^status' "no status row"
wantnot 'idle: waiting' "no idle status text"
want '^model        : FAKE-100   stock fw v7.3.1   unit fake-0001$' "model, firmware and unit id come from the board file"
want '^board line   : fake$' "the extra line of the board is on the screen"
want '^rescue       : built 2026-09-29, kernel flavor stable$' "rescue version + flavor"
want '^kernel       : 7.2.8-00116-gb5862166389d$' "kernel"
want '^network      : eth0 192.0.2.10 (dhcp, MAC 02:fa:ce:00:00:01, fakefile)$' "network"
want '^repair shell : ssh root@192.0.2.10$' "repair shell"
wantnot 'password: tsx' "no fixed password on the screen"
want '^login        : starting$' "login line before tsx-rescue-login has run"
echo panel > "$T/run/tsx-rescue-login"; render
want '^login        : the root password or SSH key of this panel$' "login line: the panel's own login"
wantnot 'one-time' "panel login: no one-time password on the screen"
echo onetime > "$T/run/tsx-rescue-login"; echo k7m2x9pq4r > "$T/run/tsx-rescue-otp"; render
want '^login        : root, one-time password k7m2x9pq4r$' "login line: the one-time password is on the screen"
fit 80
echo none > "$T/run/tsx-rescue-login"; rm -f "$T/run/tsx-rescue-otp"; render
want '^login        : NONE' "login line: no login at all is said plainly"
echo onetime > "$T/run/tsx-rescue-login"; echo k7m2x9pq4r > "$T/run/tsx-rescue-otp"; render
want '^Press Enter for a rescue shell$' "Enter line"
wantnot 'DO NOT power off' "no warning while idle"
wantnot '^install' "no operation section while idle"
wantnot 'Power-cycle' "rescue image: no power-cycle advice"
fit 80
render 85; fit 85

echo "== network before rcS has set the MAC =="
# rcS has not written tsx-eth0-mac-src yet: eth0 has the random kernel MAC and no address.
rm -f "$T/run/tsx-eth0-mac-src"; touch "$T/noip"; echo "02:5a:11:22:33:44" > "$T/mac"; render
want '^network      : eth0 (starting) (dhcp, MAC 02:fa:ce:00:00:01, fakefile)$' "starting: the MAC from the board"
wantnot '02:5a:11:22:33:44' "starting: no random kernel MAC"
wantnot 'no address yet' "starting: no \"no address yet\""
export TSX_FAKE_NO_MAC=1; render
want '^network      : eth0 (starting) (dhcp)$' "starting, the board has no MAC: no MAC"
wantnot '02:5a:11:22:33:44' "starting, the board has no MAC: no random kernel MAC"
unset TSX_FAKE_NO_MAC
echo random > "$T/run/tsx-eth0-mac-src"; render
want '^network      : eth0 (no address yet) (dhcp, MAC 02:5a:11:22:33:44, random)$' "rcS done, DHCP runs: the MAC that eth0 has"
echo fakefile > "$T/run/tsx-eth0-mac-src"; rm -f "$T/noip"; echo "02:fa:ce:00:00:01" > "$T/mac"; render
want '^network      : eth0 192.0.2.10 (dhcp, MAC 02:fa:ce:00:00:01, fakefile)$' "address assigned"

echo "== install running =="
running "writing eMMC root (p8)"
echo "314572800 0 838860800 eMMC root" > "$T/run/tsx-progress"
render
want '^install: writing eMMC root (p8)$' "operation name and step"
want '^  \[###############-*\]  38%  300 of 800 MiB$' "progress bar with MiB and percent"
want '^DO NOT power off the system\.$' "warning while running"
want '^Press Enter for a rescue shell$' "Enter line while running"
wantnot 'Power-cycle' "no power-cycle advice while running"
wantnot 'reason for rescue' "still no reason row"
fit 80
render 85; fit 85
bar=$(sed -n 's/^  \[\(.*\)\].*/\1/p' "$T/frame"); [ ${#bar} -eq 40 ] && ok "bar is 40 cells" || bad "bar is ${#bar} cells"
echo "838860800 0 838860800 eMMC root" > "$T/run/tsx-progress"; render
want '\[########################################\] 100%  800 of 800 MiB' "100% bar"
echo "5000000 0 0 unknown length" > "$T/run/tsx-progress"; render
want '^  5 MiB written$' "unknown length: MiB written, no bar"
# progress from an earlier step (file older than 2 minutes) is not shown
echo "314572800 0 838860800 eMMC root" > "$T/run/tsx-progress"; touch -d '2020-01-01 00:00:00' "$T/run/tsx-progress"; render
wantnot '\[#' "stale progress file ignored"
want '^install: writing eMMC root (p8)$' "step still shown"
rm -f "$T/run/tsx-progress"
echo "factory restore" > /dev/null; echo "$$ factory restore" > "$T/run/tsx-op"; echo "2/5 writing region p2" > "$T/run/tsx-install-state"; render
want '^factory restore: 2/5 writing region p2$' "another tool's name"
running "verifying"
sh -c 'exit 0' & dead=$!; wait $dead
echo "$dead install" > "$T/run/tsx-op"; render
want 'install stopped' "dead tool pid: stopped, not running"
wantnot 'DO NOT power off' "no power-off warning for a stopped tool"
echo "failed: no root partition found on /dev/mmcblk1 and this text goes on and on and on past the width" > "$T/run/tsx-install-state"; echo "$$ install" > "$T/run/tsx-op"; render
want '^install FAILED: failed: no root' "failed operation shown"
fit 80
echo "done, rebooting" > "$T/run/tsx-install-state"; render
want '^install: done, rebooting$' "done shown"
echo "checked OK" > "$T/run/tsx-install-state"; render
wantnot '^install' "a finished check is not an operation"
echo "idle: waiting" > "$T/run/tsx-install-state"; render
wantnot '^install' "idle state file is not an operation"

echo "== rescue paths =="
clear_op
rm -f "$T/rescue-image"; export TSX_VERFILE=$T/none; render
wantnot 'Power-cycle' "initramfs rescue: no power-cycle advice"
wantnot 'stock Android' "initramfs rescue: no stock Android claim"
want '^rescue       : initramfs rescue' "initramfs rescue: no version file needed"
echo "quiet tsx.rescue console=tty0" > "$T/cmdline"; render
wantnot 'Power-cycle' "tsx.rescue on the command line: no power-cycle advice"
echo "quiet tsx.ip=192.0.2.9/24,192.0.2.1" > "$T/cmdline"; touch "$T/rescue-image"; export TSX_VERFILE=$T/rver; render
want '(static, MAC' "static network"

echo "== Enter opens the shell =="
clear_op
printf '#!/bin/sh\necho "$$ shell" >> "%s/shell.calls"\nexit 0\n' "$T" > "$T/shell-stub"; chmod 755 "$T/shell-stub"
export TSX_STATUS_SHELL=$T/shell-stub TSX_STATUS_LOOPS=2
: > "$T/keys"; : > "$T/frame.raw"; rm -f "$T/shell.calls"
sh "$T/rs.sh" loop
[ ! -e "$T/shell.calls" ] && ok "no Enter: no shell" || bad "shell started without Enter"
echo > "$T/keys"; : > "$T/frame.raw"
sh "$T/rs.sh" loop
[ "$(wc -l < "$T/shell.calls" 2>/dev/null || echo 0)" -eq 1 ] && ok "Enter: one shell" || bad "Enter: shell calls: $(cat "$T/shell.calls" 2>/dev/null)"
sed 's/\x1b\[[0-9?;]*[A-Za-z]//g' "$T/frame.raw" > "$T/frame"
want "Rescue shell on this console (no password)" "shell banner on the screen"
want "Why this rescue: rescue image active" "shell banner says why"
wantnot 'WARNING' "no warning while idle"
want '^Press Enter for a rescue shell$' "the screen is drawn again after exit"
n=$(grep -c '^\\___)=(___/   rescue$' "$T/frame"); [ "$n" -ge 2 ] && ok "frame before and after the shell" || bad "frame drawn $n times"
running "writing eMMC root (p8)"; echo > "$T/keys"; : > "$T/frame.raw"
sh "$T/rs.sh" loop
sed 's/\x1b\[[0-9?;]*[A-Za-z]//g' "$T/frame.raw" > "$T/frame"
want '^WARNING: install is running (writing eMMC root (p8)). DO NOT power off the system\.$' "shell banner warns while an install runs"
: > "$T/keys"; : > "$T/frame.raw"; rm -f "$T/shell.calls"
sh "$T/rs.sh" loop && ok "loop exits with its round limit" || bad "loop"

echo "== a board file with only some functions =="
# A board can leave out the functions that it does not need. The screen must
# draw the frame and exit 0 then.
NOLIB_BOARD=$T/board-small.sh
cat > "$NOLIB_BOARD" <<'EOB'
tsx_board_probe() { return 0; }
tsx_board_model() { echo FAKE-100; }
tsx_board_stock_fw() { :; }
tsx_board_unit_id() { :; }
tsx_board_mac() { :; }
tsx_board_mac_source() { :; }
tsx_board_rescue_extra() { :; }
EOB
SH=sh; command -v busybox >/dev/null 2>&1 && SH="busybox sh"
: > "$T/frame.raw"
rc=0; TSX_BOARD_CONF=$NOLIB_BOARD $SH "$T/rs.sh" once || rc=$?
sed 's/\x1b\[[0-9?;]*[A-Za-z]//g' "$T/frame.raw" > "$T/frame"
[ "$rc" -eq 0 ] && ok "a small board file: exit 0 ($SH)" || bad "a small board file: exit $rc ($SH)"
want '^Press Enter for a rescue shell$' "a small board file: the frame is drawn"
want '^model        : FAKE-100$' "a small board file: the model line"

echo "== the screen sources only the board file =="
# A board that needs a helper file sources it from its own board file.
grep -n 'tsx-lib\|TSX_LIB' "$RS" > "$T/helper-refs" || true
[ ! -s "$T/helper-refs" ] && ok "tsx-rescue-status names no helper file of a board" || { bad "tsx-rescue-status names a helper file:"; cat "$T/helper-refs"; }
[ "$(grep -c '^\. ' "$RS")" = 1 ] && grep -q '^\. "${TSX_BOARD_CONF:-/usr/local/lib/tsx/board.sh}"$' "$RS" && ok "the only file it sources is the board file" || bad "tsx-rescue-status sources other files"
# The board file sets the helper functions before the screen calls the board.
HELPER_BOARD=$T/board-helper.sh
printf 'echo helper-loaded > "%s/helper.seen"\n' "$T" > "$T/helper.sh"
printf '. "%s/helper.sh"\ntsx_board_probe() { return 0; }\ntsx_board_model() { echo FAKE-100; }\ntsx_board_stock_fw() { :; }\ntsx_board_unit_id() { :; }\ntsx_board_mac() { :; }\ntsx_board_mac_source() { :; }\ntsx_board_rescue_extra() { :; }\n' "$T" > "$HELPER_BOARD"
rm -f "$T/helper.seen"; : > "$T/frame.raw"
TSX_BOARD_CONF=$HELPER_BOARD $SH "$T/rs.sh" once
[ "$(cat "$T/helper.seen" 2>/dev/null)" = helper-loaded ] && ok "a helper file that the board file sources is loaded once" || bad "the helper file was not loaded"

echo "== wiring =="
[ -x "$RS" ] && ok "screen script executable" || bad "not executable"
# The inittab, the initramfs build and the rescue image build are board glue.
# The family repos check them.

echo "$N ok, $F failed"
[ "$F" -eq 0 ]
