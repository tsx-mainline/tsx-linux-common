#!/bin/sh
# Host test of the kind of the presence sensor: PRESENCE in hw.conf is no, tof
# or pir. yes is the old name of tof. A missing key is tof. An unknown value is
# no, with a warning. The test covers:
#  - the helper (presence-kind.sh and tsx_presence.py)
#  - tsx-config: the warning for a key the kind does not use, and sensors.conf
#  - the setup page: the fields that the page hides
#  - the ESPHome entities (the keys do not change)
#  - the MQTT discovery and the state topics
set -u
. "$(dirname "$0")/lib/board.sh"
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/tests/lib/paths.sh"
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED test-presence-kind: no busybox on this host"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export PYTHONDONTWRITEBYTECODE=1
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }
is() { [ "$2" = "$3" ] && ok "$1" || bad "$1: got '$2', want '$3'"; }
BASELIB=$HERE/base/usr/local/lib/tsx
# value -> kind: the table of the rule
RULE="no:no tof:tof pir:pir yes:tof empty:tof bogus:no"
raw_of() { case $1 in empty) echo;; *) echo "$1";; esac; }

echo "== the helper in shell =="
. "$BASELIB/presence-kind.sh"
for pair in $RULE; do
	v=${pair%%:*}; want=${pair#*:}
	is "presence_kind '$v'" "$(presence_kind "$(raw_of "$v")" 2>/dev/null)" "$want"
done
is "presence_kind with no argument" "$(presence_kind 2>/dev/null)" tof
is "an unknown value warns on stderr" "$(presence_kind bogus 2>&1 >/dev/null | grep -c '^WARNING: PRESENCE=bogus in hw.conf is ')" 1
is "-q turns the warning off" "$(presence_kind -q bogus 2>&1)" no
is "a known value does not warn" "$(presence_kind pir 2>&1 >/dev/null)" ""

echo "== the helper in Python =="
python3 -I - "$BASELIB" <<'PY' && ok "tsx_presence.kind, has_presence, has_distance" || bad "tsx_presence"
import logging, sys
sys.path.insert(0, sys.argv[1])
import tsx_presence as p
logging.basicConfig(level=logging.CRITICAL)
for raw, want in (("no", "no"), ("tof", "tof"), ("pir", "pir"), ("yes", "tof"), ("", "tof"), (None, "tof"), (" pir ", "pir"),
                  ("bogus", "no"), ("TOF", "no")):
    assert p.kind(raw, warn=False) == want, (raw, p.kind(raw, warn=False))
assert [p.has_presence(k) for k in ("no", "tof", "pir")] == [False, True, True]
assert [p.has_distance(k) for k in ("no", "tof", "pir")] == [False, True, False]
class H(logging.Handler):
    n = 0
    def emit(self, record): H.n += 1
logging.getLogger("tsx.presence").addHandler(H())
logging.getLogger("tsx.presence").setLevel(logging.WARNING)
logging.getLogger("tsx.presence").propagate = False
p.kind("bogus"); p.kind("pir"); p.kind("bogus", warn=False)
assert H.n == 1, H.n
PY

echo "== tsx-config: the keys that a kind uses =="
SCRIPT=$HERE/base/usr/local/sbin/tsx-config
FX=$T/fx; mkdir -p "$FX/etc" "$FX/root" "$FX/var/lib/kiosk" "$FX/run/tsx"
echo 'root:!:19000:0:99999:7:::' > "$FX/etc/shadow"
CFG=$T/panel.conf
cfg() { env TSX_CONF="$CFG" TSX_HW_CONF="$FX/hw.conf" TSX_RUN="$FX/run" TSX_STATE_DIR="$FX/var/lib/tsx" TSX_APPLY_PREFIX="$FX" TSX_APPLY_ALLOW_NONROOT=1 busybox sh "$SCRIPT" "$@"; }
: > "$CFG"
cfg set PRESENCE_WAKE on >/dev/null; cfg set PRESENCE_HOLD_S 20 >/dev/null; cfg set PRESENCE_DISTANCE_MM 600 >/dev/null; cfg set PRESENCE_MIN_MM 100 >/dev/null
keys_of() { sed -n 's/^\(PRESENCE_[A-Z_]*\)=.*/\1/p' "$FX/run/tsx/sensors.conf" 2>/dev/null | tr '\n' ' '; }
for pair in $RULE; do
	v=${pair%%:*}; kind=${pair#*:}
	case $v in empty) rm -f "$FX/hw.conf"; printf 'MIC=yes\n' > "$FX/hw.conf";; *) printf 'MIC=yes\nPRESENCE=%s\nREASON=\n' "$v" > "$FX/hw.conf";; esac
	cfg apply >"$T/apply.log" 2>&1
	case $kind in
	tof) want="PRESENCE_WAKE PRESENCE_DISTANCE_MM PRESENCE_MIN_MM PRESENCE_HOLD_S ";;
	pir) want="PRESENCE_WAKE PRESENCE_HOLD_S ";;
	no) want="";;
	esac
	# the order of sensors.conf: WAKE, DISTANCE, MIN, HOLD
	is "apply, PRESENCE=$v ($kind): sensors.conf keys" "$(keys_of)" "$want"
	nwarn=$(grep -c 'WARNING: PRESENCE_.*apply leaves it out' "$T/apply.log")
	case $kind in tof) w=0;; pir) w=2;; no) w=4;; esac
	is "apply, PRESENCE=$v ($kind): warnings for keys the kind does not use" "$nwarn" "$w"
	if [ "$v" = bogus ]; then grep -q 'WARNING: PRESENCE=bogus in hw.conf' "$T/apply.log" && ok "apply logs the unknown value" || bad "no warning for PRESENCE=bogus"; fi
	[ "$v" = bogus ] || ! grep -q 'WARNING: PRESENCE=' "$T/apply.log" && ok "apply, PRESENCE=$v: no warning about the value" || bad "apply warns about PRESENCE=$v"
done
printf 'PRESENCE=pir\n' > "$FX/hw.conf"
is "set PRESENCE_DISTANCE_MM with pir: the warning" "$(cfg set PRESENCE_DISTANCE_MM 700 2>&1 | grep -c 'no distance sensor')" 1
is "set PRESENCE_WAKE with pir: no warning" "$(cfg set PRESENCE_WAKE off 2>&1 | grep -c WARNING)" 0
is "set PRESENCE_HOLD_S with pir: no warning" "$(cfg set PRESENCE_HOLD_S 30 2>&1 | grep -c WARNING)" 0
printf 'PRESENCE=no\n' > "$FX/hw.conf"
is "set PRESENCE_WAKE with no: the warning" "$(cfg set PRESENCE_WAKE on 2>&1 | grep -c 'no distance sensor')" 1
printf 'PRESENCE=tof\n' > "$FX/hw.conf"
is "set PRESENCE_DISTANCE_MM with tof: no warning" "$(cfg set PRESENCE_DISTANCE_MM 700 2>&1 | grep -c WARNING)" 0
# a copy of tsx-config without the helper (the installer stages the script alone) keeps no, pir and tof
mkdir -p "$T/alone"; cp "$SCRIPT" "$T/alone/tsx-config"
for pair in no:no pir:pir yes:tof; do
	printf 'PRESENCE=%s\n' "${pair%%:*}" > "$FX/hw.conf"
	n=$(env TSX_CONF="$CFG" TSX_HW_CONF="$FX/hw.conf" busybox sh "$T/alone/tsx-config" set PRESENCE_DISTANCE_MM 500 2>&1 | grep -c 'no distance sensor')
	case ${pair#*:} in tof) w=0;; *) w=1;; esac
	is "without the helper file, PRESENCE=${pair%%:*}: PRESENCE_DISTANCE_MM warning" "$n" "$w"
done

echo "== the setup page: fields =="
for pair in $RULE; do
	v=${pair%%:*}; kind=${pair#*:}
	case $v in empty) printf 'MIC=yes\n' > "$T/hw.conf";; *) printf 'MIC=yes\nPRESENCE=%s\n' "$v" > "$T/hw.conf";; esac
	got=$(TSX_HW_CONF="$T/hw.conf" TSX_RUN_DIR="$T/rundir" TSX_SETUP_PLUGIN_DIR="$T/noplug" python3 -I -c '
import sys, importlib.machinery as m
d = m.SourceFileLoader("setupd", sys.argv[1]).load_module()
u = d.hw_unavailable()
print(" ".join(k for k in sorted(u) if k.startswith("PRESENCE")))
gone = set()
for n in u:
    gone.add(n); gone.update(d.UNAVAILABLE_DROPS.get(n, ()))
print(" ".join(sorted(gone)))' "$(P usr/local/sbin/tsx-setupd)" 2>/dev/null)
	case $kind in
	tof) a=""; b="";;
	pir) a="PRESENCE_DISTANCE_MM"; b="PRESENCE_DISTANCE_MM";;
	no) a="PRESENCE_WAKE"; b="PRESENCE_DISTANCE_MM PRESENCE_HOLD_S PRESENCE_WAKE";;
	esac
	is "PRESENCE=$v ($kind): unavailable fields" "$(echo "$got" | sed -n 1p)" "$a"
	is "PRESENCE=$v ($kind): fields that a save leaves alone" "$(echo "$got" | sed -n 2p)" "$b"
done
page=$(TSX_HW_CONF="$T/hw.conf" python3 -I -c '
import sys, importlib.machinery as m
d = m.SourceFileLoader("setupd", sys.argv[1]).load_module()
print(d.PAGE if hasattr(d, "PAGE") else "")' "$(P usr/local/sbin/tsx-setupd)" 2>/dev/null)
case "$page" in
*'id="presence-dist-wrap"'*'name="PRESENCE_DISTANCE_MM"'*'$("presence-dist-wrap").style.display = "none"'*) ok "the page script can hide the distance field alone";;
*) bad "no distance block in the page";;
esac

echo "== the ESPHome entities =="
mkdir -p "$T/stub/aioesphomeapi" "$T/stub/google/protobuf" "$T/stub/linux_voice_assistant" "$T/run" "$T/state" "$T/bl"
: > "$T/stub/aioesphomeapi/__init__.py"
cat > "$T/stub/aioesphomeapi/api_pb2.py" <<'PY'
_classes = {}
class UpdateCommand:
    UPDATE_COMMAND_NONE = 0
    UPDATE_COMMAND_UPDATE = 1
    UPDATE_COMMAND_CHECK = 2
def __getattr__(name):
    if name.startswith("__"):
        raise AttributeError(name)
    if name == "UpdateCommand":
        return UpdateCommand
    if name not in _classes:
        _classes[name] = type(name, (), {"__init__": lambda self, **kw: self.__dict__.update(kw)})
    return _classes[name]
PY
: > "$T/stub/google/__init__.py"; : > "$T/stub/google/protobuf/__init__.py"
echo "class Message: pass" > "$T/stub/google/protobuf/message.py"
: > "$T/stub/linux_voice_assistant/__init__.py"
cat > "$T/stub/linux_voice_assistant/entity.py" <<'PY'
class ESPHomeEntity:
    def __init__(self, server):
        self.server = server
class LEDLightEntity(ESPHomeEntity):
    def __init__(self, server, key, name, object_id, effects=None, supports_rgb=True,
                 supports_brightness=True, on_changed=None, icon=""):
        ESPHomeEntity.__init__(self, server)
        self.key, self.name, self.object_id = key, name, object_id
    def update_on_changed(self, on_changed):
        self._on_changed = on_changed
PY
printf 'present on\ndistance 700\n' > "$T/run/presence.state"
cat > "$T/ent.py" <<'PY'
import os, sys
shim, t, raw = sys.argv[1:4]
sys.path.insert(0, t + "/stub"); sys.path.insert(0, shim)
os.environ.update(TSX_RUN_DIR=t + "/run", TSX_BACKLIGHT_DIR=t + "/bl", TSX_KIOSK_CONF=t + "/none", TSX_PANELCTL_BIN="/nonexistent",
                  TSX_HW_CONF=t + "/hw-esphome.conf", TSX_ESPHOME_PLUGIN_DIR=t + "/noplug", TSX_ALS_CONF=t + "/none")
with open(t + "/hw-esphome.conf", "w") as f:
    f.write("MIC=yes\n" + ("PRESENCE=" + raw + "\n" if raw != "empty" else ""))
from tsx_panel import device as dev, keys
from tsx_panel.backend import PanelBackend
d = dev.build_entities(None, PanelBackend())
ids = []
for e in d.entities:
    for m in e.handle_message(sys.modules["aioesphomeapi.api_pb2"].ListEntitiesRequest()):
        if getattr(m, "object_id", "") in ("presence", "distance"):
            assert m.key == keys.stable_key(m.object_id), (m.object_id, m.key)
            ids.append(m.object_id)
print(" ".join(ids))
PY
for pair in $RULE; do
	v=${pair%%:*}; kind=${pair#*:}
	got=$(python3 -I "$T/ent.py" "$HERE/ha/voice/shim" "$T" "$v" 2>"$T/ent.err") || { bad "entities, PRESENCE=$v: $(tail -n 3 "$T/ent.err")"; continue; }
	case $kind in tof) w="presence distance";; pir) w="presence";; no) w="";; esac
	is "ESPHome entities, PRESENCE=$v ($kind), the keys are the fixed keys" "$got" "$w"
done
rm -f "$T/run/presence.state"
python3 -I "$T/ent.py" "$HERE/ha/voice/shim" "$T" tof >"$T/o" 2>&1 && is "no presence.state: no presence entity, also with tof" "$(cat "$T/o")" "" || bad "entities without presence.state"
printf 'present on\ndistance 700\n' > "$T/run/presence.state"

echo "== MQTT announcements and states =="
mkdir -p "$T/bin" "$T/mrun"
printf '#!/bin/sh\ncase "$1" in has) exit 1;; get) exit 1;; esac\n' > "$T/bin/tsx-panelctl"; chmod +x "$T/bin/tsx-panelctl"
printf 'NODE_ID=tsx-kiosk\nDEVICE_NAME=TSX test\n' > "$T/mqtt.conf"
printf 'present on\ndistance 700\n' > "$T/mrun/presence.state"
echo "on 17" > "$T/idled"
mq() {  # mq RAW  -> $T/mout
	case $1 in empty) printf 'MIC=yes\n' > "$T/mrun/hw.conf";; *) printf 'MIC=yes\nPRESENCE=%s\n' "$1" > "$T/mrun/hw.conf";; esac
	printf '%s\n' 'tsx/tsx-kiosk/screen/set ON' |
	PATH=$T/bin:$PATH TSX_MQTT_DRY=1 TSX_MQTT_CONF=$T/mqtt.conf TSX_RUN_DIR=$T/mrun TSX_IDLED_STATE=$T/idled \
		TSX_BUTTONS_CONF=$T/none TSX_BUTTONS_BOARD_CONF=$T/none TSX_KIOSK_CONF=$(P etc/kiosk.conf) TSX_BACKLIGHT_DIR=$T/bl \
		TSX_PANEL_BOARD_CONF=$TSX_BOARD_DIR/panel-board.conf sh "${MQBIN:-$(P usr/local/sbin/tsx-mqtt)}" > "$T/mout" 2>&1
}
for pair in $RULE; do
	v=${pair%%:*}; kind=${pair#*:}
	mq "$v"
	p=$(grep -cF 'PUB (retained) homeassistant/binary_sensor/tsx-kiosk/presence/config {' "$T/mout")
	d=$(grep -cF 'PUB (retained) homeassistant/sensor/tsx-kiosk/distance/config {' "$T/mout")
	c=$(grep -cx 'PUB (retained) homeassistant/sensor/tsx-kiosk/distance/config ' "$T/mout")
	ps=$(grep -cF 'PUB (retained) tsx/tsx-kiosk/presence/state ON' "$T/mout")
	ds=$(grep -cF 'PUB (retained) tsx/tsx-kiosk/presence/distance 700' "$T/mout")
	case $kind in tof) w="1 1 0 1 1";; pir) w="1 0 1 1 0";; no) w="0 0 0 0 0";; esac
	is "MQTT, PRESENCE=$v ($kind): presence config, distance config, distance cleared, presence state, distance state" "$p $d $c $ps $ds" "$w"
	if [ "$v" = bogus ]; then grep -q 'WARNING: PRESENCE=bogus in hw.conf' "$T/mout" && ok "MQTT logs the unknown value" || bad "MQTT: no warning for PRESENCE=bogus"; fi
done
# a rootfs without the helper file: no, pir and tof still work
mkdir -p "$T/alone2/usr/local/sbin"; cp "$(P usr/local/sbin/tsx-mqtt)" "$T/alone2/usr/local/sbin/tsx-mqtt"; MQBIN=$T/alone2/usr/local/sbin/tsx-mqtt
for pair in pir:1:0 tof:1:1 no:0:0 yes:1:1; do
	IFS=: read -r v p d <<EOT
$pair
EOT
	mq "$v"
	is "MQTT without the helper file, PRESENCE=$v: presence and distance configs" "$(grep -cF 'homeassistant/binary_sensor/tsx-kiosk/presence/config {' "$T/mout") $(grep -cF 'homeassistant/sensor/tsx-kiosk/distance/config {' "$T/mout")" "$p $d"
done
unset MQBIN
grep '/config {' "$T/mout" | sed 's/^[^{]*//' | while read -r j; do echo "$j" | jq -e . >/dev/null || exit 1; done && ok "MQTT: the JSON of the discovery topics is valid" || bad "MQTT: bad JSON"

echo "== $N ok, $F failed =="
[ "$F" = 0 ] && echo "PASS test-presence-kind"
[ "$F" = 0 ]
