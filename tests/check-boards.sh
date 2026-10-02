#!/bin/bash
# Check that the board fixtures of tests/boards are the files that the family
# repos ship. The fixtures are copies, so the tests run without the family
# repos. Run this check when a family changes its board files, and in the CI
# of a family repo that checks out tsx-linux-common.
#   tests/check-boards.sh xx60=PATH [FAMILY=PATH ...]
# PATH is the top of a family checkout (the directory that has rootfs/).
# The script prints each difference and exits 1 if there is any.
set -u
cd "$(dirname "$0")/.."
[ $# -ge 1 ] || { sed -n '2,9p' "$0" >&2; exit 2; }
fail=0
# fixture file in tests/boards/FAMILY, file in the family repo below rootfs/overlay
FILES="board.sh=usr/local/lib/tsx/board.sh panel-board.conf=etc/tsx/panel-board.conf motd.board=etc/tsx/motd.board"
check() { # FAMILY ROOT FIXTURE SOURCE
	local fx=tests/boards/$1/$3 src=$2/rootfs/overlay/$4
	if [ ! -e "$src" ]; then echo "FAIL: $1: $src is missing"; fail=1; return; fi
	if [ ! -e "$fx" ]; then echo "FAIL: $1: fixture $fx is missing"; fail=1; return; fi
	if diff -u "$fx" "$src" > /dev/null; then echo "ok: $1 $3"; else
		echo "FAIL: $1 $3 differs from the family file:"; diff -u "$fx" "$src" | head -n 30; fail=1; fi
}
for arg in "$@"; do
	fam=${arg%%=*} root=${arg#*=}
	[ -d "tests/boards/$fam" ] && [ -d "$root" ] || { echo "usage error: $arg"; exit 2; }
	for pair in $FILES; do check "$fam" "$root" "${pair%%=*}" "${pair#*=}"; done
	[ -e "tests/boards/$fam/conf.d-tsx-config" ] && check "$fam" "$root" conf.d-tsx-config etc/conf.d/tsx-config
done
[ $fail = 0 ] && echo "board fixtures match" || echo "board fixtures differ: copy the family files into tests/boards"
exit $fail
