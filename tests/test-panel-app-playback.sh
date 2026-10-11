#!/bin/bash
# Host test for panel-app/esphome/components/tsx_cards/playback.h: the check
# that keeps the full CPU range while a sound card plays and the screen is
# off (docs/panel-app.md, "CPU speed"). It builds fake /proc/asound trees:
#  - no folder, no card, a closed stream: no audio
#  - a playback stream in the state RUNNING or DRAINING: audio
#  - PREPARED, PAUSED, SETUP or XRUN: no audio
#  - a running capture stream (pcm*c): no audio
#  - the second card, the second substream: audio
#  - a stream that starts and stops: the answer follows
# It compiles C++, so run it only on a build host or in CI.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC=$HERE/panel-app/esphome/components/tsx_cards
CXX=${CXX:-c++}
command -v "$CXX" >/dev/null 2>&1 || { echo "SKIPPED test-panel-app-playback: no $CXX"; exit 0; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }

cat > "$T/main.cpp" <<'C'
#include <cstdio>
#include "playback.h"
int main(int argc, char **argv) {
  if (argc != 2)
    return 2;
  puts(esphome::tsx_cards::audio_playing(argv[1]) ? "playing" : "silent");
  return 0;
}
C
"$CXX" -std=gnu++17 -Wall -Wextra -Werror -O1 -I"$SRC" -o "$T/pb" "$T/main.cpp" || { echo "FAIL: compile"; exit 1; }

A=$T/asound
# stream CARD PCM SUB TEXT: write the status file of one substream
stream() { mkdir -p "$A/card$1/$2/sub$3"; printf '%b' "$4" > "$A/card$1/$2/sub$3/status"; }
check() { got=$("$T/pb" "$A"); [ "$got" = "$1" ] && ok "$2" || bad "$2: $got"; }
RUN='state: RUNNING\nowner_pid   : 1234\ntrigger_time: 100.1\n'

check silent "no /proc/asound folder"
mkdir -p "$A"
check silent "no sound card"
stream 0 pcm0p 0 'closed\n'
check silent "a closed playback stream"
for st in PREPARED PAUSED SETUP XRUN OPEN; do
	stream 0 pcm0p 0 "state: $st\nowner_pid   : 1\n"
	check silent "a playback stream in the state $st"
done
stream 0 pcm0p 0 "$RUN"
check playing "a running playback stream"
stream 0 pcm0p 0 'state: DRAINING\n'
check playing "a draining playback stream"
stream 0 pcm0p 0 'closed\n'
stream 0 pcm0c 0 "$RUN"
check silent "a running capture stream (the microphone) is no audio"
stream 1 pcm3p 1 "$RUN"
check playing "the second substream of a second card"
stream 1 pcm3p 1 'state:\tRUNNING\n'
check playing "a tab after state:"
stream 1 pcm3p 1 'closed\n'
check silent "the stream stops: no audio again"
stream 0 pcm0p 0 'owner_pid: 1\nstate: RUNNING\n'
check playing "the state line after another line"
chmod 000 "$A/card0/pcm0p/sub0/status"
if [ "$(id -u)" != 0 ]; then
	check silent "a status file that cannot be read is no audio"
fi
chmod 644 "$A/card0/pcm0p/sub0/status"

echo "== test-panel-app-playback: $N ok, $F failed =="
[ "$F" = 0 ]
