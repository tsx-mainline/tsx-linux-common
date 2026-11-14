#!/bin/sh
# autoupdate-offline-inner.sh OUT [BIN]: the part of tests/test-autoupdate-offline.sh
# that runs in the Alpine container (root, busybox sh, the real apk). It writes
# OUT/result.txt (the lines, then PASS or FAIL) and OUT/autoupdate.log.
set -u
OUT=$1; BIN=${2:-/src/autoupdate/usr/local/sbin/tsx-autoupdate}
R=$OUT/result.txt; : > "$R"
fail=0
say() { echo "$*" >> "$R"; }
bad() { say "FAIL: $*"; fail=1; }
up() { cut -d' ' -f1 /proc/uptime; }
secs() { echo "$2 $1" | awk '{ printf "%d", $1 - $2 }'; }

# No way out: a default route over a dummy link (it drops every packet). The
# names resolve from /etc/hosts (documentation addresses, one per host).
ip link add d0 type dummy && ip addr add 198.51.100.2/24 dev d0 && ip link set d0 up &&
	ip route add default via 198.51.100.1 dev d0 || { bad "no dummy link (NET_ADMIN, module dummy)"; exit 1; }
echo 'nameserver 127.0.0.1' > /etc/resolv.conf
echo '203.0.113.10 dl-cdn.alpinelinux.org' >> /etc/hosts
echo '203.0.113.11 tsx-aports.example.org' >> /etc/hosts
cat > /etc/apk/repositories <<EOF
https://tsx-aports.example.org/v3.24/common
https://tsx-aports.example.org/v3.24/fake
https://dl-cdn.alpinelinux.org/alpine/v3.24/main
https://dl-cdn.alpinelinux.org/alpine/v3.24/community
EOF
rm -rf /var/cache/apk/* /etc/apk/cache 2>/dev/null
say "apk: $(apk --version 2>&1 | head -n 1); $(uname -m)"
say "tsx-autoupdate: $(sha256sum "$BIN" | cut -c1-16)"

# The panel's tools: the real flock, sha256sum, sed, awk of busybox; stubs for
# the parts that would act on the host.
T=/tmp/t; mkdir -p "$T/bin" "$T/initd"
for c in reboot rc-service curl; do printf '#!/bin/sh\necho "CALL %s $*" >> %s/calls\nexit 0\n' "$c" "$T" > "$T/bin/$c"; chmod +x "$T/bin/$c"; done
printf 'MODE=auto\nWINDOW=00:00-23:59\nAUTO_RESTART=on\n' > "$T/autoupdate.conf"
echo blank > "$T/idled"
run() {
	PATH="$T/bin:$PATH" TSX_BOARD_CONF=/src/tests/boards/fake/board.sh TSX_CONF_SH=/src/base/usr/local/lib/tsx/conf.sh \
	TSX_DEFAULTS_DIR=/src/autoupdate/usr/local/share/tsx/defaults \
	TSX_AUTOUPDATE_CONF="$T/autoupdate.conf" TSX_RUN_DIR="$T/run" TSX_STATE_DIR="$T/state" \
	TSX_LOG="$OUT/autoupdate.log" TSX_IDLED_STATE="$T/idled" TSX_INITD="$T/initd" \
	TSX_BUILD_ID_FILE="$T/build-id" TSX_RUNLEVELS="$T/runlevels" sh "$BIN" "$@"
}

# 1. The boot: no network call (apk info -v --no-network).
t0=$(up); run boot >/dev/null 2>&1; t1=$(up); b=$(secs "$t0" "$t1")
say "boot: $b s"
[ "$b" -le 20 ] || bad "the boot took $b s with no network (bound 20 s)"
grep -q '^running_version ' "$T/state/fields" 2>/dev/null || bad "the boot recorded no release"

# 2. The scheduled run. The test does not touch the run lock (a look with flock
# could make the tick skip, and docker shows no /proc/locks). It times the
# locked part from the log: the tick writes its first log line only once it
# holds the run lock (the apk update before it writes no log), so the time
# from the first log write to the end bounds how long the run lock was held.
# The old script logs "apk update" right after it took the lock.
cp "$OUT/autoupdate.log" "$OUT/autoupdate-boot.log" 2>/dev/null; : > "$OUT/autoupdate.log"
t0=$(up); run >/dev/null 2>&1 & P=$!
tl=
while kill -0 "$P" 2>/dev/null; do
	[ -z "$tl" ] && [ -s "$OUT/autoupdate.log" ] && tl=$(up)
	sleep 0.5
done
wait "$P"; t1=$(up); k=$(secs "$t0" "$t1")
[ -n "$tl" ] || tl=$t1
h=$(secs "$tl" "$t1")
say "tick: $k s; the run lock was held at most about $h s (from the first log write to the end)"
[ "$k" -le 140 ] || bad "the tick took $k s with no network (bound 4 x 20 s + 60 s)"
[ "$h" -le 15 ] || bad "the run lock was held about $h s (the network part holds it)"
grep -q '^repo_blocked 1$' "$T/state/fields" 2>/dev/null || bad "the status does not say that a repository is unreachable"
c=$(grep -c 'APKINDEX.tar.gz: Operation timed out' "$OUT/autoupdate.log")
say "timed-out repositories in the log: $c"
[ "$c" -ge 4 ] || bad "apk update did not report the 4 repositories as timed out"
grep -q '^CALL reboot' "$T/calls" 2>/dev/null && bad "a restart"
[ $fail = 0 ] && say "PASS tsx-autoupdate offline (real apk): boot ${b}s, tick ${k}s, run lock held at most about ${h}s" || say "FAIL tsx-autoupdate offline"
exit $fail
