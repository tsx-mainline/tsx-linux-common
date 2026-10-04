#!/bin/sh
# Host test of the key LED parts of tsx_panel (backend.py and device.py): the
# Key LEDs light and the number "Key LEDs screen-off level".
#  - The light shows the level while the screen is awake (buttons.state
#    "led_awake"). It does not change at a blank or a wake. An older
#    tsx-buttons without that line: the level now ("led").
#  - Off and on go to tsx-panelctl as "keypad led off" and "keypad led N".
#  - The number reads "led_blank" (else LED_BLANK of buttons.conf), sends
#    "keypad led-blank N" (0 to 255) and shows a value that it just set until
#    tsx-buttons has it.
#  - Without front keys, neither entity exists.
# Small stand-ins replace aioesphomeapi, protobuf and linux_voice_assistant,
# so the test needs no network and no libmpv.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/run" "$T/state" "$T/bl" "$T/stub/aioesphomeapi" "$T/stub/google/protobuf" "$T/stub/linux_voice_assistant"
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
class ESPHomeEntity:
    def __init__(self, server):
        self.server = server

class LEDLightEntity(ESPHomeEntity):
    """The parts of the real class that tsx_panel uses."""
    def __init__(self, server, key, name, object_id, effects=None, supports_rgb=True,
                 supports_brightness=True, on_changed=None, icon=""):
        ESPHomeEntity.__init__(self, server)
        self.key, self.name, self.object_id = key, name, object_id
        self.effects_list = list(effects) if effects else []
        self._on_changed = on_changed
        self.is_on, self.brightness, self.red, self.green, self.blue, self.effect = False, 1.0, 1.0, 1.0, 1.0, ""

    def update_on_changed(self, on_changed):
        self._on_changed = on_changed

    def command(self, **kw):
        """A LightCommandRequest of Home Assistant."""
        for k, v in kw.items():
            setattr(self, k, v)
        self._on_changed()

    def _state_response(self):
        return _Response(("light", self.object_id, self.is_on, round(self.brightness, 3)))

class _Response(tuple):
    pass
PY
cat > "$T/buttons.conf" <<'C'
button power KEY_F13 led=1
button home  KEY_F14 led=2
LED_DAY=128
LED_NIGHT=24
LED_BLANK=17
C
python3 - "$HERE/ha/voice/shim" "$T" <<'PY'
import os, sys, time
shim, t = sys.argv[1:3]
sys.path[:0] = [t + "/stub", shim]
os.environ.update(TSX_RUN_DIR=t + "/run", TSX_STATE_DIR=t + "/state", TSX_BACKLIGHT_DIR=t + "/bl",
                  TSX_KIOSK_CONF=t + "/none", TSX_BUTTONS_CONF=t + "/buttons.conf", TSX_ALS_CONF=t + "/none",
                  TSX_ASOUND_DIR=t + "/none", TSX_IDLED_STATE=t + "/none", TSX_PANELCTL_BIN="/nonexistent",
                  TSX_THERMAL_ZONE=t + "/none")
from aioesphomeapi import api_pb2 as pb
from tsx_panel.backend import PanelBackend
from tsx_panel import device as dev
from tsx_panel.keys import stable_key

fails = 0
def check(name, got, want):
    global fails
    if got == want:
        print("ok  ", name)
    else:
        print("FAIL", name, "got", repr(got), "want", repr(want)); fails += 1

class Backend(PanelBackend):
    """The real backend. The fake tsx-panelctl records each command."""
    def __init__(self):
        super().__init__()
        self.sent = []
    def _panelctl(self, *args, timeout=5):
        return False, ""
    def _ctl(self, *words):
        self.sent.append(" ".join(words))
        return True

def state(text):
    with open(t + "/run/buttons.state", "w") as f:
        f.write(text)

AWAKE = "screen awake\nled 128 day\nled_awake 128 day\nled_blank 24\nkey_leds 1 1 1 1 1\n"
BLANK = "screen blank\nled 24 blank\nled_awake 128 day\nled_blank 24\nkey_leds 1 1 1 1 1\n"
OFF_BLANK = "screen blank\nled 0 override\nled_awake 0 override\nled_blank 24\nkey_leds 0 0 0 0 0\n"

# ---- the backend ------------------------------------------------------------
b = Backend()
state(AWAKE)
check("light: the awake level", b.get_keypad(), (True, 128))
state(BLANK)
check("light: a blank screen keeps the awake level (no jump to the screen-off level)", b.get_keypad(), (True, 128))
state(OFF_BLANK)
check("light: off on a blank screen", b.get_keypad(), (False, 0))
state("screen blank\nled 24 blank\n")
check("light: an older tsx-buttons (no led_awake): the level now", b.get_keypad(), (True, 24))
os.remove(t + "/run/buttons.state")
check("light: no state file", b.get_keypad(), (False, 0))
b.set_keypad(False, 200); b.set_keypad(True, 0); b.set_keypad(True, 300); b.set_keypad(True, 77)
check("light: off and on to tsx-panelctl", b.sent, ["keypad led off", "keypad led 1", "keypad led 255", "keypad led 77"])

b = Backend()
check("number: no state file: LED_BLANK of buttons.conf", b.get_key_led_blank(), 17)
state(AWAKE)
check("number: led_blank of buttons.state", b.get_key_led_blank(), 24)
b.set_key_led_blank(40.4)
check("number: set sends keypad led-blank N", b.sent, ["keypad led-blank 40"])
check("number: a value just set shows until tsx-buttons has it", b.get_key_led_blank(), 40)
state(AWAKE.replace("led_blank 24", "led_blank 40"))
check("number: tsx-buttons has it", (b.get_key_led_blank(), b._key_led_blank_pending), (40, None))
b.set_key_led_blank(10)
b._key_led_blank_pending = (10, time.monotonic() - 11)
check("number: after 10 s the state file wins", b.get_key_led_blank(), 40)
b.sent.clear(); b.set_key_led_blank(300); b.set_key_led_blank(-5); b.set_key_led_blank(0)
check("number: clamped to 0 to 255", b.sent, ["keypad led-blank 255", "keypad led-blank 0", "keypad led-blank 0"])
check("number: a new backend has no pending value", Backend()._key_led_blank_pending, None)

# ---- the entities -------------------------------------------------------------
state(AWAKE)
b = Backend()
d = dev.build_entities(None, b)
num = d.key_led_blank
info = list(num.handle_message(pb.ListEntitiesRequest()))[0]
check("entity: the number of the screen-off level",
      (info.name, info.object_id, info.min_value, info.max_value, info.step, info.unit_of_measurement),
      ("Key LEDs screen-off level", "key_led_blank", 0, 255, 1, ""))
check("entity: the fixed key of key_led_blank", num.key, stable_key("key_led_blank"))
check("entity: the light", (d.keypad.object_id, d.keypad.is_on, round(d.keypad.brightness * 255)), ("keypad", True, 128))
check("entity: the number after the light", d.entities.index(num), d.entities.index(d.keypad) + 1)
reply = list(num.handle_message(pb.NumberCommandRequest(key=num.key, state=12.0)))
check("entity: a number command from Home Assistant", (b.sent, reply[0].state), (["keypad led-blank 12"], 12.0))
d.keypad.command(is_on=False)
d.keypad.command(is_on=True, brightness=0.5)
check("entity: light off and on", b.sent[1:], ["keypad led off", "keypad led 128"])

def mine(msgs):
    """The messages of the two key LED entities (uptime and others also move)."""
    out = []
    for m in msgs:
        if isinstance(m, tuple) and m[1] == "keypad":
            out.append(tuple(m))
        elif getattr(m, "key", None) == num.key:
            out.append(("number", m.state))
    return out

msgs = []
state(AWAKE.replace("led_blank 24", "led_blank 12"))
dev.poll(d, msgs.extend)
msgs.clear()
state(BLANK.replace("led_blank 24", "led_blank 12"))
dev.poll(d, msgs.extend)
check("poll: a blank screen changes neither entity", mine(msgs), [])
state(OFF_BLANK.replace("led_blank 24", "led_blank 12"))
dev.poll(d, msgs.extend)
check("poll: an off on a blank screen reaches the light at once", mine(msgs), [("light", "keypad", False, 0.0)])
msgs.clear()
state(OFF_BLANK.replace("led_blank 24", "led_blank 30"))
dev.poll(d, msgs.extend)
check("poll: a new screen-off level reaches the number", mine(msgs), [("number", 30.0)])

# ---- a panel without front keys -------------------------------------------------
os.environ["TSX_BUTTONS_CONF"] = t + "/none"
d = dev.build_entities(None, Backend())
check("no front keys: no light and no number", (d.keypad, d.key_led_blank), (None, None))
check("no front keys: no key_led_blank in the list",
      [e for e in d.entities if getattr(e, "object_id", "") in ("keypad", "key_led_blank")], [])
dev.poll(d, lambda m: None)
if fails:
    sys.exit(1)
print("PASS test-shim-keypad")
PY
