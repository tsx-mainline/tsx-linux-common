#!/bin/bash
# Offline test of tsx-autoupdate with the real apk-tools 3 of Alpine. It needs
# docker and an Alpine 3.24 image, and makes a dummy network link in the
# container (--cap-add NET_ADMIN), so it runs on a build host:
#   tests/run-all.sh --docker      or      bash tests/test-autoupdate-offline.sh
# Settings (environment):
#   TSX_OFFLINE_IMAGE   the image (default alpine:3.24; arm64v8/alpine:3.24
#                       runs the apk of the panels under qemu)
#   TSX_OFFLINE_BIN     another tsx-autoupdate to run in place of the one of
#                       this repo (a comparison with an older one; it then
#                       fails the bounds below)
# The container has no route out except a dummy link that drops every packet
# (as a WAN block of the panel: the names resolve, nothing answers). It lists
# the four repositories of a panel (two hosts, one address each) and has no
# index in the cache. apk-tools 3 then waits 60 s for each repository in
# apk update and in apk info -v. The test checks the bounds of the fix:
#   - tsx-autoupdate boot (the init script runs it before the default
#     runlevel goes on) makes no network call: it ends in seconds;
#   - the scheduled run: apk update ends by its --timeout (4 x 20 s), the run
#     lock /run/tsx/autoupdate.lock is held only for the part after it (read
#     from /proc without taking the lock, and timed from the log), /var/log
#     does not change before the run lock, and the status says that the
#     repositories are unreachable.
# The inner part is tests/lib/autoupdate-offline-inner.sh (busybox sh).
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/.." && pwd)
IMG=${TSX_OFFLINE_IMAGE:-alpine:3.24}
command -v docker >/dev/null 2>&1 || { echo "SKIP: no docker"; exit 0; }
docker image inspect "$IMG" >/dev/null 2>&1 || { echo "FAIL: no image $IMG (docker pull $IMG on a host with network)"; exit 1; }
O=$(mktemp -d); trap 'rm -rf "$O"' EXIT
binarg=
if [ -n "${TSX_OFFLINE_BIN:-}" ]; then cp "$TSX_OFFLINE_BIN" "$O/tsx-autoupdate"; binarg=/out/tsx-autoupdate; fi
docker run --rm --network none --cap-add NET_ADMIN -v "$ROOT:/src:ro" -v "$O:/out" "$IMG" \
	sh /src/tests/lib/autoupdate-offline-inner.sh /out $binarg
rc=$?
cat "$O/result.txt" 2>/dev/null
[ $rc = 0 ] && grep -q '^PASS' "$O/result.txt" 2>/dev/null
