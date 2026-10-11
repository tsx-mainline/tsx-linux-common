#!/bin/sh
# Host test for the backup and the restore of the panel data in the rescue
# system (rescue/usr/sbin/tsx-data-backup, tsx-data-restore). No panel, no
# root, no compiler: findfs, mount and umount are fakes. A fake ext4 mount
# is a link to a fixture directory. A fake bind mount copies the directory
# and the fake umount copies it back.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
DB=$HERE/rescue/usr/sbin/tsx-data-backup
DR=$HERE/rescue/usr/sbin/tsx-data-restore
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }

echo "== syntax =="
for s in "$DB" "$DR"; do busybox sh -n "$s" && ok "$(basename "$s") passes busybox sh -n" || bad "$(basename "$s"): busybox sh -n"; done

mkdir -p "$T/bin"
cat > "$T/bin/findfs" <<'FAKE'
#!/bin/sh
case $1 in
LABEL=tsxdata) [ -e "$FAKE_T/nodata" ] && exit 1; echo /dev/fakedata;;
LABEL=tsxroot) echo /dev/fakeroot;;
*) exit 1;;
esac
FAKE
cat > "$T/bin/mount" <<'FAKE'
#!/bin/sh
echo "mount $*" >> "$FAKE_T/mountlog"
if [ "$1" = --bind ]; then
	cp -a "$2"/. "$3"/
	echo "$3 $2" >> "$FAKE_T/binds"
	exit 0
fi
for last; do :; done
case " $* " in *" /dev/fakedata "*) src=$FAKE_T/data;; *) src=$FAKE_T/rootfs;; esac
rmdir "$last" && ln -s "$src" "$last"
FAKE
cat > "$T/bin/umount" <<'FAKE'
#!/bin/sh
echo "umount $*" >> "$FAKE_T/mountlog"
src=$(awk -v d="$1" '$1 == d { print $2 }' "$FAKE_T/binds" 2>/dev/null | tail -n 1)
if [ -n "$src" ]; then
	cp -a "$1"/. "$src"/
	awk -v d="$1" '$1 != d' "$FAKE_T/binds" > "$FAKE_T/binds.n"; mv "$FAKE_T/binds.n" "$FAKE_T/binds"
	exit 0
fi
[ -L "$1" ] && rm -f "$1"
exit 0
FAKE
chmod 755 "$T/bin"/*
export FAKE_T=$T

fixtures() {
	rm -rf "$T/data" "$T/rootfs" "$T/run" "$T/nodata" "$T/mountlog" "$T/binds"
	mkdir -p "$T/data/tsx" "$T/data/var/lib/tsx" "$T/data/root/.ssh" "$T/data/lost+found" "$T/run"
	echo 'KIOSK_URL=https://ha.example.org/' > "$T/data/tsx/panel.conf"
	echo x > "$T/data/var/lib/tsx/x"
	echo key > "$T/data/root/.ssh/k"
	mkdir -p "$T/rootfs/data/tsx" "$T/rootfs/var/lib/tsx" "$T/rootfs/var/log" "$T/rootfs/root" "$T/rootfs/etc" "$T/rootfs/lost+found"
	echo 'LAYOUT=root' > "$T/rootfs/data/tsx/panel.conf"
	echo y > "$T/rootfs/var/lib/tsx/y"
	echo log > "$T/rootfs/var/log/messages"
	echo prof > "$T/rootfs/root/.profile"
	echo 'root:x:0:0' > "$T/rootfs/etc/passwd"
	: > "$T/mounts"
}
db() {  # db ARGS...: run tsx-data-backup with the fakes
	env PATH="$T/bin:$PATH" TSX_DATA_RUN="$T/run" TSX_DATA_MOUNTS="$T/mounts" \
	    TSX_DATA_FINDFS="$T/bin/findfs" TSX_DATA_MOUNT="$T/bin/mount" TSX_DATA_UMOUNT="$T/bin/umount" \
	    busybox sh "$DB" "$@"
}
dr() {
	env PATH="$T/bin:$PATH" TSX_DATA_RUN="$T/run" TSX_DATA_MOUNTS="$T/mounts" \
	    TSX_DATA_FINDFS="$T/bin/findfs" TSX_DATA_MOUNT="$T/bin/mount" TSX_DATA_UMOUNT="$T/bin/umount" \
	    busybox sh "$DR" "$@"
}
list() { tar -tzf "$1" | sed 's|^\./||' | grep -v '/$' | sort | tr '\n' ' '; }

echo "== backup of a data partition =="
fixtures
db "$T/b-data.tgz" 2>"$T/err" && ok "backup ends with 0" || bad "backup failed: $(cat "$T/err")"
l=$(list "$T/b-data.tgz")
[ "$l" = "root/.ssh/k tsx/panel.conf var/lib/tsx/x " ] && ok "the archive holds the data partition" || bad "archive: $l"
case $(tar -tzf "$T/b-data.tgz") in *lost+found*) bad "lost+found is in the archive";; *) ok "no lost+found";; esac
grep -q 'mount -t ext4 -o ro /dev/fakedata' "$T/mountlog" && ok "the backup mounts read only" || bad "mount: $(cat "$T/mountlog")"
[ ! -L "$T/run/tsx-data-fs" ] && ok "unmounted at the end" || bad "still mounted"

echo "== backup of a card with no data partition (root file system) =="
fixtures; : > "$T/nodata"
db - > "$T/b-root.tgz" 2>"$T/err" && ok "backup to stdout ends with 0" || bad "backup failed: $(cat "$T/err")"
l=$(list "$T/b-root.tgz")
[ "$l" = "root/.profile tsx/panel.conf var/lib/tsx/y var/log/messages " ] && ok "the archive has the data layout (data/tsx is tsx/)" || bad "archive: $l"
case $l in *passwd*) bad "etc/passwd is in the archive";; *) ok "no other part of the root file system";; esac

echo "== restore a root-fs backup into a data partition =="
fixtures; rm -rf "$T/data"/*; mkdir -p "$T/data/lost+found"
dr "$T/b-root.tgz" 2>"$T/err" && ok "restore ends with 0" || bad "restore failed: $(cat "$T/err")"
[ "$(cat "$T/data/tsx/panel.conf" 2>/dev/null)" = LAYOUT=root ] && ok "panel.conf is in tsx/" || bad "no tsx/panel.conf"
[ "$(cat "$T/data/var/log/messages" 2>/dev/null)" = log ] && ok "var/log is restored" || bad "no var/log/messages"
grep -q 'mount -t ext4 -o rw /dev/fakedata' "$T/mountlog" && ok "the restore mounts read-write" || bad "mount: $(cat "$T/mountlog")"

echo "== restore a data backup into a root file system (stdin) =="
fixtures; : > "$T/nodata"; rm -rf "$T/rootfs/data/tsx"
dr - < "$T/b-data.tgz" 2>"$T/err" && ok "restore from stdin ends with 0" || bad "restore failed: $(cat "$T/err")"
[ "$(cat "$T/rootfs/data/tsx/panel.conf" 2>/dev/null)" = 'KIOSK_URL=https://ha.example.org/' ] && ok "tsx/ goes to /data/tsx" || bad "no data/tsx/panel.conf"
[ "$(cat "$T/rootfs/var/lib/tsx/x" 2>/dev/null)" = x ] && ok "var/lib/tsx goes to the root file system" || bad "no var/lib/tsx/x"
[ "$(cat "$T/rootfs/root/.ssh/k" 2>/dev/null)" = key ] && ok "root/ goes to /root" || bad "no root/.ssh/k"
[ "$(cat "$T/rootfs/var/lib/tsx/y" 2>/dev/null)" = y ] && ok "without --clean the old files stay" || bad "an old file was deleted"
[ ! -e "$T/run/tsx-data-in.tar.gz" ] && ok "the stdin copy is deleted" || bad "the stdin copy stays in RAM"

echo "== restore --clean into a root file system =="
fixtures; : > "$T/nodata"
dr --clean "$T/b-data.tgz" 2>"$T/err" && ok "restore --clean ends with 0" || bad "restore --clean failed: $(cat "$T/err")"
[ ! -e "$T/rootfs/var/lib/tsx/y" ] && ok "--clean deletes the old panel data" || bad "the old var/lib/tsx/y stays"
[ ! -e "$T/rootfs/var/log/messages" ] && ok "--clean empties var/log" || bad "var/log/messages stays"
[ -e "$T/rootfs/etc/passwd" ] && ok "--clean keeps the rest of the root file system" || bad "etc/passwd is gone"
[ "$(cat "$T/rootfs/var/lib/tsx/x" 2>/dev/null)" = x ] && ok "the backup is in place after --clean" || bad "no var/lib/tsx/x"

echo "== refusals =="
fixtures; echo "/dev/fakedata /data ext4 rw 0 0" > "$T/mounts"
db "$T/x.tgz" 2>"$T/err" && bad "a mounted file system is accepted" || { grep -q 'is mounted' "$T/err" && ok "a mounted file system is refused" || bad "message: $(cat "$T/err")"; }
fixtures
db --clean "$T/x.tgz" 2>/dev/null && bad "--clean for a backup is accepted" || ok "--clean is for the restore only"
db 2>/dev/null && bad "no argument is accepted" || ok "no argument: refused"
echo junk > "$T/junk.tgz"
dr "$T/junk.tgz" 2>/dev/null && bad "a file that is not a gzip tar is accepted" || ok "a file that is not a gzip tar is refused"

echo "$N passed, $F failed"
[ "$F" = 0 ]
