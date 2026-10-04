#!/bin/sh
# Host test of the fixed entity keys of the ESPHome device (tsx_panel/keys.py).
# Home Assistant pairs a listed entity with a known entity by its key when the
# unique id does not decide. So an entity must keep its key:
#  - in tsx-esphome (VOICE=off) and in the voice satellite (VOICE=on)
#  - with each set of optional entities (LED bar, key LEDs, sensors, front
#    keys, camera modes, Bluetooth proxy on or off) and in each order
#  - for the own entities of the satellite, also when a new version of
#    linux-voice-assistant adds entities or changes their order
# No two known entities can have the same key, and the key values never change
# (fixed values below). Small stand-ins replace aioesphomeapi, protobuf and
# linux_voice_assistant. The stand-in satellite counts its keys from 0 like
# linux-voice-assistant 1.1.15. The test needs no network and no libmpv.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/run" "$T/state" "$T/stub/aioesphomeapi" "$T/stub/google/protobuf" "$T/stub/linux_voice_assistant"
export PYTHONDONTWRITEBYTECODE=1
# the stand-ins: every protobuf name is a class that keeps its keyword arguments
: > "$T/stub/aioesphomeapi/__init__.py"
cat > "$T/stub/aioesphomeapi/api_pb2.py" <<'PY'
_classes = {}
def __getattr__(name):
    if name.startswith("__"):
        raise AttributeError(name)
    if name not in _classes:
        _classes[name] = type(name, (), {"__init__": lambda self, **kw: self.__dict__.update(kw)})
    return _classes[name]
PY
: > "$T/stub/google/__init__.py"; : > "$T/stub/google/protobuf/__init__.py"
echo "class Message: pass" > "$T/stub/google/protobuf/message.py"
: > "$T/stub/linux_voice_assistant/__init__.py"
cat > "$T/stub/linux_voice_assistant/entity.py" <<'PY'
from aioesphomeapi import api_pb2 as pb

class ESPHomeEntity:
    def __init__(self, server):
        self.server = server

class SatelliteEntity(ESPHomeEntity):
    """An own entity of the satellite (media player, mute, ...)."""
    def __init__(self, server, key, name, object_id):
        ESPHomeEntity.__init__(self, server)
        self.key, self.name, self.object_id = key, name, object_id

    def handle_message(self, msg):
        if isinstance(msg, pb.ListEntitiesRequest):
            yield pb.ListEntitiesSwitchResponse(key=self.key, object_id=self.object_id, name=self.name)

class LEDLightEntity(SatelliteEntity):
    def __init__(self, server, key, name, object_id, effects=None, supports_rgb=True,
                 supports_brightness=True, on_changed=None, icon=""):
        SatelliteEntity.__init__(self, server, key, name, object_id)
        self.effects_list = list(effects) if effects else []
        self.is_on, self.brightness, self.red, self.green, self.blue, self.effect = False, 1.0, 1.0, 1.0, 1.0, ""

    def update_on_changed(self, on_changed):
        self._on_changed = on_changed

    def _state_response(self):
        return pb.LightStateResponse(key=self.key)
PY
cat > "$T/stub/linux_voice_assistant/satellite.py" <<'PY'
from aioesphomeapi import api_pb2 as pb
from .entity import LEDLightEntity, SatelliteEntity

# The own entities of linux-voice-assistant 1.1.15 (satellite.py), in its order
LVA_ENTITIES = [("Media Player", "linux_voice_assistant_media_player"), ("Mute", "mute"),
                ("Thinking Sound", "thinking_sound"), ("Wake Word 1 Sensitivity", "wake_word_1_sensitivity"),
                ("Wake Word 2 Sensitivity", "wake_word_2_sensitivity"), ("Stop Word Sensitivity", "stop_word_sensitivity"),
                ("Mic Auto Gain", "mic_gain"), ("Mic Noise Suppression", "mic_noise"), ("Mic Volume", "mic_volume")]

class VoiceSatelliteProtocol:
    """Gives each new entity key=len(state.entities), like linux-voice-assistant."""
    def __init__(self, state):
        self.state = state
        have = {getattr(e, "object_id", None) for e in state.entities}
        for name, object_id in state.lva_entities:
            if object_id not in have:
                state.entities.append(SatelliteEntity(self, len(state.entities), name, object_id))
        self.register_pending_lights()
        self.register_pending_button()

    def register_pending_lights(self):
        have = {getattr(e, "object_id", None) for e in self.state.entities}
        for object_id in self.state.pending_lights:
            if object_id not in have:
                self.state.entities.append(LEDLightEntity(self, len(self.state.entities), object_id, object_id))

    def register_pending_button(self):
        if self.state.pending_button and "button_press_event" not in {getattr(e, "object_id", None) for e in self.state.entities}:
            self.state.entities.append(SatelliteEntity(self, len(self.state.entities), "Button Press",
                                                       "button_press_event"))

    def handle_message(self, msg):
        if isinstance(msg, pb.ListEntitiesRequest):
            for entity in self.state.entities:
                yield from entity.handle_message(msg)

    def connection_lost(self, exc):
        pass

class ServerState:
    def __init__(self, lva_entities=LVA_ENTITIES):
        self.entities, self.lva_entities = [], list(lva_entities)
        self.pending_lights, self.pending_button = [], False

    def broadcast(self, msgs):
        pass
PY
python3 - "$HERE/ha/voice/shim" "$T" "$HERE/tests/boards/fake/buttons-board.conf" <<'PY'
import itertools, logging, os, random, sys
shim, t, board_keys = sys.argv[1:4]
sys.path[:0] = [t + "/stub", shim]
os.environ.update(TSX_RUN_DIR=t + "/run", TSX_STATE_DIR=t + "/state", TSX_HA_TRANSPORT="esphome",
                  TSX_PANELCTL_BIN="/nonexistent")
logging.basicConfig(level=logging.ERROR)
from aioesphomeapi import api_pb2 as pb
from linux_voice_assistant import satellite as lva
from tsx_panel import backend as backend_mod, bluetooth, camera, device as dev, keys

fails = 0
def check(name, got, want):
    global fails
    if got == want:
        print("ok   " + name)
    else:
        fails += 1
        print(f"FAIL {name} got {got!r} want {want!r}")

# ---- the hash: FNV-1a, 32 bit, and the fixed values ---------------------------------
check("FNV-1a test vectors", [keys.fnv1a32(s) for s in ("", "a", "foobar")], [0x811C9DC5, 0xE40C292C, 0xBF9CF968])
# These values are in the entity registry of each Home Assistant. Never change them.
check("fixed values", [keys.stable_key("screen"), keys.stable_key("backlight"), keys.stable_key("ledbar"),
                       keys.stable_key("action:ledbar_fill"), keys.stable_key("thinking_sound", keys.SATELLITE)],
      [keys.fnv1a32("tsx:screen"), keys.fnv1a32("tsx:backlight"), keys.fnv1a32("tsx:ledbar"),
       keys.fnv1a32("tsx:action:ledbar_fill"), keys.fnv1a32("lva:thinking_sound")])
# the key LEDs: the object ids since the rename (the old ids keypad and key_led_blank are gone)
check("fixed values (key LEDs)", [keys.stable_key("key_leds"), keys.stable_key("key_leds_screen_off")],
      [keys.fnv1a32("tsx:key_leds"), keys.fnv1a32("tsx:key_leds_screen_off")])
check("fixed values (numbers)", [hex(keys.stable_key(i)) for i in ("screen", "ledbar")], ["0xb2ffb04a", "0x72592420"])

# ---- the rules of Keys: no key below MIN_KEY (so never 0), collisions move ----------
low = next(s for s in (f"x{i}" for i in range(2000000)) if keys.fnv1a32(s) < keys.MIN_KEY)
first = next(keys.candidates(low))
check("a hash below MIN_KEY is not a key", (first >= keys.MIN_KEY, first == keys.fnv1a32(low + "#1")), (True, True))
k = keys.Keys(taken=[keys.stable_key("screen")])
check("a taken key moves to the hash of <text>#1", k("screen"), keys.fnv1a32("tsx:screen#1"))
check("the same identity keeps its key", k("screen"), keys.fnv1a32("tsx:screen#1"))
idents = ["screen", "backlight", "volume", "camera", "key_prog2", "action:ledbar_clear"]
orders = set()
for seed in range(20):
    random.Random(seed).shuffle(idents)
    k = keys.Keys()
    orders.add(tuple(sorted((i, k(i)) for i in idents)))
check("the keys do not depend on the order", len(orders), 1)

# ---- a stand-in backend: each optional part on or off ----------------------------------
KEY_NAMES = [line.split()[1] for line in open(board_keys) if line.startswith("button ")]
check("the keys of the board layer of the made-up board", KEY_NAMES,
      ["prog1", "prog2", "prog3", "prog4", "extra1", "extra2", "extra3"])
PARTS = ("ledbar", "ledbar_fx", "ledbar_leds", "key_leds", "als", "sound_card", "presence", "lightbar",
         "usb_power", "poe", "emmc", "nfc")

class Backend:
    ORIENTATIONS = backend_mod.PanelBackend.ORIENTATIONS
    parts = dict.fromkeys(PARTS, True)
    keys = KEY_NAMES

    def __getattr__(self, name):
        if name.endswith("_present"):
            return lambda: self.parts[name[:-len("_present")]]
        values = {"get_ledbar": (False, 255, 255, 255, 255), "get_lightbar": (False, 255, 255, 255, 255),
                  "get_keypad": (False, 0), "get_screen": (True, 10), "get_backlight_max": 255,
                  "get_orientation": "landscape", "get_ledbar_effect": "None", "key_names": list(self.keys),
                  "get_update_status": {}, "poll_key_event": None, "poll_nfc_tag": None}
        return lambda *args, **kwargs: values.get(name, 0)

class Camera:
    """camera.service() in a mode: off, live or snapshot."""
    def __init__(self, mode):
        self.mode, self.key = mode, None
    def enabled(self):
        return self.mode != "off"
    def why_off(self):
        return "" if self.enabled() else "off in the test"
    def press(self):
        pass
    def last_snapshot_time(self):
        return None
    def request(self, *args, **kwargs):
        pass
    def connection_lost(self, conn):
        pass

def set_camera(mode):
    svc = Camera(mode)
    camera.service = lambda: svc

def set_bt(on):
    open(t + "/run/hw.conf", "w").write("BT=yes\n" if on else "BT=no\n")
    open(t + "/run/bt.conf", "w").write("PROXY=on\n" if on else "PROXY=off\n")

def listed(entities):
    """{object_id or action name: key} of the ListEntities responses."""
    out = {}
    for e in entities:
        for m in e.handle_message(pb.ListEntitiesRequest()):
            ident = m.object_id if hasattr(m, "object_id") else "action:" + m.name
            check_unique(out, ident)
            out[ident] = m.key
    return out

def check_unique(out, ident):
    if ident in out:
        check("one entity per object id: " + ident, True, False)

def standalone(parts, mode="snapshot", key_names=KEY_NAMES):
    Backend.parts, Backend.keys = dict(parts), key_names
    set_camera(mode)
    return dev.build_entities(None, Backend())

# ---- standalone: all parts on, the reference ---------------------------------------
set_bt(False)
ALL = dict.fromkeys(PARTS, True)
d = standalone(ALL)
REF = listed(d.entities)
check("all parts: the entity count (with the actions)", len(REF), 42)
check("all parts: the key LED entities have the new ids, the old ids are gone",
      sorted(i for i in REF if "key_leds" in i or i in ("keypad", "key_led_blank")),
      ["key_leds", "key_leds_screen_off"])
check("all parts: an event entity for each key", sorted(i for i in REF if i.startswith("key_") and "leds" not in i),
      sorted("key_" + n for n in KEY_NAMES))
check("all parts: each key is the fixed key of its identity",
      {i: k for i, k in REF.items() if k != keys.stable_key(i)}, {})

# ---- each set of optional parts: the same key for the same entity ------------------
def part_sets():
    """Each set of parts. The bar effects need the bar (ledbar_fx) and the 16
    LEDs need the effects. NFC adds no entity."""
    for bar in ((False, False, False), (True, False, False), (True, True, False), (True, True, True)):
        for bits in itertools.product((False, True), repeat=len(PARTS) - 4):
            yield dict(zip(PARTS, bar + bits + (True,)))

moved, sets = {}, 0
for parts in part_sets():
    for mode in ("off", "live", "snapshot"):
        for names in (KEY_NAMES, [], KEY_NAMES[::-1]):
            sets += 1
            for ident, key in listed(standalone(parts, mode, names).entities).items():
                if key != REF[ident]:
                    moved[ident] = key
check(f"{sets} sets of optional entities: no key moves", moved, {})
check("all parts off: only the fixed entities",
      sorted(listed(standalone(dict.fromkeys(PARTS, False), "off", []).entities).items()),
      sorted((i, REF[i]) for i in ("screen", "backlight", "blank_timeout", "orientation", "verbose_boot", "kiosk_url",
                                   "reload_page", "reboot", "cpu_temp", "uptime", "ip_address", "touched_recently",
                                   "update")))
set_bt(True)
check("Bluetooth proxy on: the same keys", (bluetooth.PROXY.enabled(), listed(standalone(ALL).entities)), (True, REF))

# ---- no collisions: the panel, the actions and the satellite of linux-voice-assistant --
LVA_IDS = [oid for _, oid in lva.LVA_ENTITIES] + ["button_press_event"]
universe = {f"tsx:{i}": k for i, k in REF.items()}
universe.update({f"lva:{oid}": keys.stable_key(oid, keys.SATELLITE) for oid in LVA_IDS})
check("no collision", len(set(universe.values())), len(universe))
check("no collision: each key is the first hash of its text",
      {t_: k for t_, k in universe.items() if k != keys.fnv1a32(t_)}, {})
check("no key below MIN_KEY", [t_ for t_, k in universe.items() if k < keys.MIN_KEY], [])

# ---- the voice satellite (tsx_lva): the same keys as standalone ---------------------------
backend_mod.PanelBackend = Backend
set_bt(False)
import tsx_lva
tsx_lva._patch_keys()
# HA_TRANSPORT=mqtt: _patch_panel() adds nothing, the satellite keys are fixed
state = lva.ServerState()
lva.VoiceSatelliteProtocol(state)
check("satellite alone (HA_TRANSPORT=mqtt): the fixed keys", {e.object_id: e.key for e in state.entities},
      {oid: keys.stable_key(oid, keys.SATELLITE) for _, oid in lva.LVA_ENTITIES})
tsx_lva._patch_panel()

def voice(parts, mode="snapshot", lva_entities=lva.LVA_ENTITIES, lights=(), button=False):
    Backend.parts, Backend.keys = dict(parts), KEY_NAMES
    set_camera(mode)
    state = lva.ServerState(lva_entities)
    state.pending_lights, state.pending_button = list(lights), button
    sat = lva.VoiceSatelliteProtocol(state)
    return state, sat

def voice_list(sat):
    out = {}
    for m in sat.handle_message(pb.ListEntitiesRequest()):
        ident = m.object_id if hasattr(m, "object_id") else "action:" + m.name
        check_unique(out, ident)
        out[ident] = m.key
    return out

LVA_REF = {oid: keys.stable_key(oid, keys.SATELLITE) for oid in LVA_IDS}
state, sat = voice(ALL)
got = voice_list(sat)
check("voice: the panel entities have the keys of standalone", {i: got.get(i) for i in REF}, REF)
check("voice: the satellite entities have their fixed keys",
      {i: k for i, k in got.items() if i not in REF}, {oid: LVA_REF[oid] for _, oid in lva.LVA_ENTITIES})
check("voice: all keys differ", len(set(got.values())), len(got))
sat2 = lva.VoiceSatelliteProtocol(state)    # Home Assistant connects again
check("voice: a new connection keeps the keys", voice_list(sat2), got)
state.pending_lights, state.pending_button = ["ring"], True     # a peripheral registers a light and a button
sat2.register_pending_lights()
sat2.register_pending_button()
late = {e.object_id: e.key for e in state.entities if hasattr(e, "object_id")}
check("voice: a light and a button that come later get fixed keys",
      (late["ring"], late["button_press_event"]),
      (keys.stable_key("ring", keys.SATELLITE), LVA_REF["button_press_event"]))
entity_got = {i: k for i, k in got.items() if not i.startswith("action:")}
check("voice: the old keys stay", {i: late[i] for i in entity_got}, entity_got)

# another version of linux-voice-assistant: a new entity first, the others reversed
other = [("New Thing", "new_thing")] + lva.LVA_ENTITIES[::-1]
state, sat = voice(ALL, lva_entities=other, lights=["ring"], button=True)
got2 = voice_list(sat)
check("another satellite version: the same keys for the same entities", {i: got2[i] for i in got}, got)
check("another satellite version: the new entity has its fixed key", got2["new_thing"],
      keys.stable_key("new_thing", keys.SATELLITE))

moved = {}
for parts in part_sets():
    for mode in ("off", "live", "snapshot"):
        for bt in (False, True):
            set_bt(bt)
            for ident, key in voice_list(voice(parts, mode)[1]).items():
                if key != {**REF, **LVA_REF}[ident]:
                    moved[ident] = key
check("voice, each set of optional entities, Bluetooth on and off: no key moves", moved, {})
check("voice: the panel light is no satellite entity, a light of a peripheral is one",
      {e.object_id: keys.is_satellite_entity(e) for e in state.entities
       if getattr(e, "object_id", None) in ("ledbar", "ring", "mute")},
      {"ledbar": False, "ring": True, "mute": True})
print(("FAIL" if fails else "PASS") + " test-shim-keys")
sys.exit(1 if fails else 0)
PY
