#!/bin/bash
# Host test of base/etc/init.d/tsx-data (move_one): the first
# move to /data, and the bind mount on a new root file system that does not
# have the directory. mount and mountpoint are stubs; everything happens
# under a temporary directory (TSX_DATA_ROOT).
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok() { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }

einfo() { :; }; eerror() { echo "eerror: $*" >> "$T/calls"; }; ebegin() { :; }; eend() { :; }
mountpoint() { return 1; }
mount() { echo "mount $*" >> "$T/calls"; [ -d "${@: -1}" ]; }
export TSX_DATA_ROOT=$T/root TSX_DATA_LOG=$T/tsx-data.log
# shellcheck source=/dev/null
. "$HERE/base/etc/init.d/tsx-data"

echo "== first move"
mkdir -p "$T/root/var/lib/tsx" "$T/root/data"
echo keep > "$T/root/var/lib/tsx/state"
: > "$T/calls"
move_one var/lib/tsx; rc=$?
[ $rc = 0 ] && [ "$(cat "$T/root/data/var/lib/tsx/state")" = keep ] && [ -e "$T/root/data/var/lib/tsx/.tsx-moved" ] &&
	[ -z "$(ls -A "$T/root/var/lib/tsx")" ] && ok "moved to /data, marker written, rootfs copy cleared" || bad "first move (rc $rc)"
grep -q "mount --bind $T/root/data/var/lib/tsx $T/root/var/lib/tsx" "$T/calls" && ok "bind mount" || bad "no bind mount: $(cat "$T/calls")"

echo "== a new root file system without the directory"
rm -rf "$T/root/var/lib/tsx"
: > "$T/calls"
move_one var/lib/tsx; rc=$?
[ $rc = 0 ] && [ -d "$T/root/var/lib/tsx" ] && grep -q "mount --bind $T/root/data/var/lib/tsx $T/root/var/lib/tsx" "$T/calls" &&
	! grep -q eerror "$T/calls" && ok "mount point made, bind mount done" || bad "new rootfs (rc $rc): $(cat "$T/calls")"
[ "$(cat "$T/root/data/var/lib/tsx/state")" = keep ] && ok "the data stays" || bad "data lost"

echo "$N ok, $F failed"
[ "$F" -eq 0 ]
