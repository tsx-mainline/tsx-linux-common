#!/bin/sh
# Host test of tsx-autoupdate's pure decision logic: the night window and the
# reboot-needed check on an apk upgrade package list. Both take every input as
# a plain argument (no apk/date stubbing needed here. See
# test-autoupdate-flow.sh for the end-to-end check/install/status/healthcheck
# flow with a stubbed apk/date).
set -u
# The made-up board for the scripts that read a board file.
. "$(dirname "$0")/lib/board.sh"
HERE=$(cd "$(dirname "$0")" && pwd); BIN=$HERE/../autoupdate/usr/local/sbin/tsx-autoupdate
fail=0
chk() { [ "$1" = "$2" ] || { echo "FAIL: $3: got '$1', want '$2'"; fail=1; }; }

# ---- in_window (HH:MM, HH:MM-HH:MM, end exclusive, may cross midnight) -----
sh "$BIN" __in_window 04:00 03:00-05:00; chk $? 0 "04:00 in 03:00-05:00"
sh "$BIN" __in_window 02:59 03:00-05:00; chk $? 1 "02:59 not yet in 03:00-05:00"
sh "$BIN" __in_window 05:00 03:00-05:00; chk $? 1 "05:00 not in 03:00-05:00 (end exclusive)"
sh "$BIN" __in_window 03:00 03:00-05:00; chk $? 0 "03:00 in 03:00-05:00 (start inclusive)"
sh "$BIN" __in_window 00:30 23:00-01:00; chk $? 0 "00:30 in a window crossing midnight"
sh "$BIN" __in_window 12:00 23:00-01:00; chk $? 1 "noon not in a window crossing midnight"
sh "$BIN" __in_window 08:05 08:00-08:10; chk $? 0 "leading-zero hour/minute (08:05) parses as decimal, not octal"

# ---- needs_reboot (kernel, musl, openrc, busybox/init only) ----------------
sh "$BIN" __needs_reboot "chromium sway squeekboard"; chk $? 1 "no kernel/musl/openrc/busybox package: no reboot"
sh "$BIN" __needs_reboot "musl chromium"; chk $? 0 "musl upgrade needs a reboot"
sh "$BIN" __needs_reboot "linux-lts"; chk $? 0 "kernel package needs a reboot"
sh "$BIN" __needs_reboot "openrc"; chk $? 0 "openrc (init system) needs a reboot"
sh "$BIN" __needs_reboot "busybox-openrc"; chk $? 0 "busybox-openrc needs a reboot"
sh "$BIN" __needs_reboot ""; chk $? 1 "empty list: no reboot"

# ---- the kernel package of the board needs a reboot, another family's does not
sh "$BIN" __needs_reboot "tsx-fake-kernel-lts"; chk $? 0 "the kernel package of the board needs a reboot"
sh "$BIN" __needs_reboot "tsx-fake-kernel-stable"; chk $? 0 "the stable kernel package of the board needs a reboot"
sh "$BIN" __needs_reboot "tsx-other-kernel-lts"; chk $? 1 "the kernel package of another family needs none"

# ---- the Chromium logic is not part of the tool --------------------------------
sh "$BIN" __chromium_decision 2.0-r0 1.0-r0 1 '' 7 2026-01-08 >/dev/null 2>&1; chk $? 2 "no __chromium_decision command"

[ $fail = 0 ] && echo "PASS tsx-autoupdate logic (window, reboot-needed)"
exit $fail
