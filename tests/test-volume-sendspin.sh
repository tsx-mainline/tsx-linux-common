#!/bin/bash
# Host test for one volume on a panel with the Sendspin player
# (docs/sendspin.md, "Audio and volume"). A fake player (tests/fake-sendspin.py)
# has a control socket and writes the volume file, as sendspin-cli 0.3.0-r1.
#  - tsx-panelctl get volume / get mute / state read the volume file
#  - the FIFO commands "volume N" and "mute on|off" go to the control socket
#    (player-vol, player-mute) and never to the mixer
#  - a change of Music Assistant (the fake player) shows in get volume
#  - bad lines are refused, a player that does not answer is a log line
#  - without the volume file: the mixer (TSX_VOLUME_CMD), no mute
#  - the service tsx-sendspin: --volume-file only for a sendspin-cli that
#    has it, the fixed level of the board (TSX_VOLUME_FIXED_CMD), stop_post
#    removes the file
set -uo pipefail
export TSX_VOLUME_CMD="tsx-audio volume"
. "$(dirname "$0")/lib/board.sh"
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../base/usr/local/sbin/tsx-panelctl"
INIT="$HERE/../sendspin/etc/init.d/tsx-sendspin"
FAKE="$HERE/fake-sendspin.py"
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED test-volume-sendspin: no busybox on this host"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIPPED test-volume-sendspin: no python3 on this host"; exit 0; }
T=$(mktemp -d); PID= SPID=
trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null; [ -n "$SPID" ] && kill "$SPID" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/run" "$T/bin" "$T/ss" "$T/asound/FakeCard"
N=0 F=0
ok() { echo "  ok: $*"; N=$((N + 1)); }
bad() { echo "  FAIL: $*"; F=$((F + 1)); }

for b in tsx-audio amixer; do
	printf '#!/bin/sh\necho "%s $*" >> "%s/cmds.log"\n' "$b" "$T" > "$T/bin/$b"
	chmod +x "$T/bin/$b"
done
printf '#!/bin/sh\nexec python3 "%s" "$@"\n' "$FAKE" > "$T/bin/sendspin-cli"
chmod +x "$T/bin/sendspin-cli"
: > "$T/cmds.log"
SOCK=$T/ss/control.sock VOL=$T/ss/volume
export PATH="$T/bin:$PATH" TSX_RUN_DIR="$T/run" TSX_ASOUND_DIR="$T/asound" \
	TSX_SENDSPIN_BIN="$T/bin/sendspin-cli" TSX_SENDSPIN_SOCKET="$SOCK" TSX_SENDSPIN_VOLUME_FILE="$VOL"
pctl() { busybox sh "$SCRIPT" "$@"; }
player() { "$T/bin/sendspin-cli" "$@" --control-socket "$SOCK" >/dev/null; }
# wait_vol N: up to 3 s for "volume = N" in the volume file
wait_vol() { for _ in $(seq 1 30); do grep -qx "volume = $1" "$VOL" 2>/dev/null && return 0; sleep 0.1; done; return 1; }
wait_muted() { for _ in $(seq 1 30); do grep -qx "muted = $1" "$VOL" 2>/dev/null && return 0; sleep 0.1; done; return 1; }

python3 "$FAKE" serve "$SOCK" "$VOL" 55 false &
SPID=$!
for _ in $(seq 1 30); do [ -S "$SOCK" ] && [ -f "$VOL" ] && break; sleep 0.1; done
[ -S "$SOCK" ] || { echo "FAIL: the fake player did not start"; exit 1; }

echo "== get and state read the volume file of the player =="
[ "$(pctl get volume)" = 55 ] && ok "get volume: 55 (the player volume)" || bad "get volume: $(pctl get volume 2>&1)"
[ "$(pctl get mute)" = off ] && ok "get mute: off" || bad "get mute: $(pctl get mute 2>&1)"
st=$(pctl state)
printf '%s\n' "$st" | grep -qx 'volume 55' && printf '%s\n' "$st" | grep -qx 'mute off' && ok "state: volume 55, mute off" || bad "state: $st"
[ ! -s "$T/cmds.log" ] && ok "no mixer read while the player owns the volume" || bad "mixer read: $(cat "$T/cmds.log")"

echo "== the daemon: volume and mute go to the player =="
busybox sh "$SCRIPT" > "$T/panelctl.log" 2>&1 &
PID=$!
for _ in $(seq 1 20); do grep -q "listening on" "$T/panelctl.log" 2>/dev/null && break; sleep 0.1; done
grep -q "listening on" "$T/panelctl.log" || { echo "FAIL: tsx-panelctl did not start"; cat "$T/panelctl.log"; exit 1; }
send() { echo "$1" > "$T/run/panelctl"; }
send "volume 40"
wait_vol 40 && ok "volume 40 -> player-vol 40, the file says 40" || bad "volume 40: $(cat "$VOL") $(cat "$T/panelctl.log")"
[ "$(pctl get volume)" = 40 ] && ok "get volume: 40" || bad "get volume after the set: $(pctl get volume 2>&1)"
grep -qx 'player-vol 40' "$SOCK.log" && ok "the player got 'player-vol 40'" || bad "socket log: $(cat "$SOCK.log")"
grep -q 'volume 40 (Sendspin player)' "$T/panelctl.log" && ok "log line: volume 40 (Sendspin player)" || bad "log: $(cat "$T/panelctl.log")"
send "mute on"
wait_muted true && [ "$(pctl get mute)" = on ] && ok "mute on -> player-mute on, get mute: on" || bad "mute on: $(cat "$VOL")"
send "mute off"
wait_muted false && ok "mute off -> player-mute off" || bad "mute off: $(cat "$VOL")"
for v in 0 100; do send "volume $v"; wait_vol "$v" && ok "volume $v reaches the player" || bad "volume $v: $(cat "$VOL")"; done
[ ! -s "$T/cmds.log" ] && ok "the mixer was never set (no tsx-audio, no amixer)" || bad "mixer touched: $(cat "$T/cmds.log")"

echo "== a change of Music Assistant shows on the panel =="
player server-vol 70
[ "$(pctl get volume)" = 70 ] && ok "Music Assistant sets 70: get volume 70" || bad "get volume after the server change: $(pctl get volume 2>&1)"
player server-mute on
pctl state | grep -qx 'mute on' && ok "Music Assistant mutes: state says mute on" || bad "state: $(pctl state)"
player server-mute off

echo "== bad lines are refused =="
n=$(wc -l < "$SOCK.log")
for line in "mute maybe" "mute on x" "mute" "volume 101" "volume -1" "volume 4O"; do send "$line"; done
sleep 0.5
[ "$(wc -l < "$SOCK.log")" = "$n" ] && ok "no refused line reached the player" || bad "socket log: $(tail -n 3 "$SOCK.log")"
[ "$(grep -c 'rejected: \(mute\|volume\)' "$T/panelctl.log")" = 6 ] && ok "six lines rejected" || bad "rejections: $(grep rejected "$T/panelctl.log")"
grep -qx 'volume = 70' "$VOL" && ok "the volume stays 70" || bad "volume: $(cat "$VOL")"

echo "== a player that does not answer =="
player quit; wait "$SPID" 2>/dev/null; SPID=
send "volume 30"
for _ in $(seq 1 30); do grep -q 'player-vol 30: sendspin-cli failed (exit 3)' "$T/panelctl.log" && break; sleep 0.1; done
grep -q 'player-vol 30: sendspin-cli failed (exit 3)' "$T/panelctl.log" && ok "no socket: a log line" || bad "log: $(tail -n 3 "$T/panelctl.log")"
kill -0 "$PID" 2>/dev/null && ok "the daemon still runs" || bad "the daemon stopped"

echo "== without the volume file: the mixer, no mute =="
rm -f "$VOL"
send "volume 25"
for _ in $(seq 1 30); do grep -q 'tsx-audio volume 25' "$T/cmds.log" && break; sleep 0.1; done
grep -qx 'tsx-audio volume 25' "$T/cmds.log" && ok "volume 25 -> tsx-audio volume 25 (TSX_VOLUME_CMD)" || bad "mixer: $(cat "$T/cmds.log")"
send "mute on"
for _ in $(seq 1 30); do grep -q 'rejected: mute on (the Sendspin player does not run' "$T/panelctl.log" && break; sleep 0.1; done
grep -q 'rejected: mute on (the Sendspin player does not run: no mute)' "$T/panelctl.log" && ok "mute on is refused: no mute" || bad "mute without player: $(tail -n 2 "$T/panelctl.log")"
pctl get mute >/dev/null 2>&1 && bad "get mute without the player gave a value" || ok "get mute fails without the player"
pctl state | grep -q '^mute' && bad "state has a mute line without the player" || ok "state: no mute line"
kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; PID=

echo "== the service tsx-sendspin =="
mkdir -p "$T/ssrun"
for kind in new old; do
	if [ $kind = new ]; then help='  --volume-file <path>'; else help='  --state-dir <dir>'; fi
	printf '#!/bin/sh\n[ "$1" = --help ] && echo "%s"\nexit 0\n' "$help" > "$T/bin/sendspin-cli-$kind"
	chmod +x "$T/bin/sendspin-cli-$kind"
done
printf '#!/bin/sh\necho "fixed $*" >> "%s/cmds.log"\n' "$T" > "$T/bin/fixed"; chmod +x "$T/bin/fixed"
printf '. "%s"\nTSX_SOUND_CARD=\nTSX_VOLUME_FIXED_CMD="%s/bin/fixed"\n' "$TSX_BOARD_CONF" "$T" > "$T/board-ss.sh"
# run_init KIND FUNCTION: the function of the service with the OpenRC helpers faked
run_init() {
	cat > "$T/h.sh" <<EOF
checkpath() { :; }
chown() { :; }
getent() { return 0; }
ewarn() { echo "WARN \$*"; }
eerror() { echo "ERR \$*"; }
. "$INIT"
command="$T/bin/sendspin-cli-$1"
$2; echo "rc \$?"
echo "ARGS \$command_args"
EOF
	TSX_SENDSPIN_RUN="$T/ssrun" TSX_BOARD_CONF="$T/board-ss.sh" busybox sh "$T/h.sh" 2>&1
}
: > "$T/cmds.log"; echo "volume = 1" > "$T/ssrun/volume"
out=$(run_init new start_pre)
printf '%s\n' "$out" | grep -q "^ARGS .*--control-socket $T/ssrun/control.sock .*--volume-file $T/ssrun/volume" && ok "start_pre: --volume-file for a sendspin-cli that has it" || bad "args: $out"
grep -q '^fixed' "$T/cmds.log" && ok "start_pre: the board sets its fixed level (TSX_VOLUME_FIXED_CMD)" || bad "fixed: $(cat "$T/cmds.log")"
[ ! -e "$T/ssrun/volume" ] && ok "start_pre: an old volume file is gone" || bad "the old volume file stays"
: > "$T/cmds.log"
out=$(run_init old start_pre)
printf '%s\n' "$out" | grep -q '^ARGS .*--volume-file' && bad "an old sendspin-cli got --volume-file" || ok "an old sendspin-cli: no --volume-file"
printf '%s\n' "$out" | grep -q 'WARN .*has no --volume-file: the mixer stays the volume of the panel' && ok "an old sendspin-cli: a warning" || bad "warning: $out"
[ ! -s "$T/cmds.log" ] && ok "an old sendspin-cli: the mixer level is not changed" || bad "fixed ran: $(cat "$T/cmds.log")"
echo "volume = 1" > "$T/ssrun/volume"
run_init new stop_post >/dev/null
[ ! -e "$T/ssrun/volume" ] && ok "stop_post removes the volume file" || bad "stop_post left the file"

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo PASS test-volume-sendspin || echo FAIL test-volume-sendspin
exit $F
