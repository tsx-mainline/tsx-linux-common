#!/bin/sh
# Host test of the LED bar light of tsx_panel (backend.py and device.py): the
# effects of the bar firmware TSX-LEDBAR, and the stock firmware without them.
# With TSX-LEDBAR 0.1.3 (the 16 LEDs): the zone effects of the light and the
# user-defined actions (the list, the decode of a call, the argument checks).
# Small stand-ins replace aioesphomeapi, protobuf and linux_voice_assistant,
# so the test needs no network and no libmpv. A fake tsx-panelctl answers
# "has" and records the commands.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/run" "$T/state" "$T/bl" "$T/stub/aioesphomeapi" "$T/stub/google/protobuf" "$T/stub/linux_voice_assistant"
export PYTHONDONTWRITEBYTECODE=1
# the stand-ins: every protobuf name is a class that keeps its keyword arguments
cat > "$T/stub/aioesphomeapi/__init__.py" <<'PY'
PY
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
        self.is_on, self.brightness = False, 0.66
        self.red, self.green, self.blue = 0.094, 0.733, 0.949
        self.effect = self.effects_list[0] if self.effects_list else ""

    def update_on_changed(self, on_changed):
        self._on_changed = on_changed

    def command(self, **kw):
        """A LightCommandRequest of Home Assistant."""
        for k, v in kw.items():
            if k == "effect" and v not in self.effects_list:
                continue
            setattr(self, k, v)
        self._on_changed()

    def _state_response(self):
        return ("light", self.object_id, self.is_on, round(self.brightness, 3), self.effect)
PY
python3 - "$HERE/ha/voice/shim" "$T" <<'PY'
import os, sys
shim, t = sys.argv[1:3]
sys.path[:0] = [t + "/stub", shim]
os.environ.update(TSX_RUN_DIR=t + "/run", TSX_STATE_DIR=t + "/state", TSX_BACKLIGHT_DIR=t + "/bl",
                  TSX_KIOSK_CONF=t + "/none", TSX_BUTTONS_CONF=t + "/none", TSX_ALS_CONF=t + "/none",
                  TSX_ASOUND_DIR=t + "/none", TSX_IDLED_STATE=t + "/none", TSX_PANELCTL_BIN="/nonexistent",
                  TSX_THERMAL_ZONE=t + "/none")
from tsx_panel.backend import PanelBackend
from tsx_panel import device as dev

fails = 0
def check(name, got, want):
    global fails
    if got == want:
        print("ok  ", name)
    else:
        print("FAIL", name, "got", repr(got), "want", repr(want)); fails += 1

class Backend(PanelBackend):
    """The real backend. The fake tsx-panelctl answers "has" and records each command."""
    fx_firmware = False
    leds_firmware = False
    listening = True
    def __init__(self):
        super().__init__()
        self.sent = []
    def _panelctl(self, *args, timeout=5):
        if args == ("has", "ledbar"):
            return True, ""
        if args == ("has", "ledbar-fx"):
            return self.fx_firmware, ""
        if args == ("has", "ledbar-leds"):
            return self.leds_firmware, ""
        return False, ""
    def _ctl(self, *words):
        if not self.listening:
            return False
        self.sent.append(" ".join(words))
        return True

def state(text):
    with open(t + "/run/ledbar.state", "w") as f:
        f.write(text)

def light_msgs(msgs):
    return [m for m in msgs if isinstance(m, tuple) and m[0] == "light"]

# ---- the stock firmware: as before, no bar effect --------------------------
state("want 0 0 0\nfx breathe 0 0 80 4000\n")   # a stale record changes nothing
b = Backend()
d = dev.build_entities(None, b)
check("stock: effects", d.ledbar.effects_list, ["None", "Pulse"])
check("stock: effect", d.ledbar.effect, "None")
d.ledbar.command(is_on=True, brightness=1.0, red=1.0, green=0.0, blue=0.0)
check("stock: color", b.sent, ["ledbar set 100 0 0"])
b.sent.clear(); d.ledbar.command(effect="Breathe")
check("stock: Breathe is no effect here", (d.ledbar.effect, b.sent), ("None", ["ledbar set 100 0 0"]))
b.sent.clear(); d.ledbar.command(is_on=False)
check("stock: off", b.sent, ["ledbar off"])
state("want 0 0 80\nfx breathe 0 0 80 4000\n")
out = []; dev.poll(d, out.extend)
check("stock: poll keeps the effect", (d.ledbar.effect, d.ledbar.is_on), ("None", True))
d.ledbar.effect = "Pulse"; d.ledbar.is_on = True; b.sent.clear()
dev.poll(d, out.extend)
check("stock: Pulse is the software effect", len(b.sent) == 1 and b.sent[0].startswith("ledbar set "), True)

# ---- the bar firmware TSX-LEDBAR ---------------------------------------------
state("want 0 0 80\nfx breathe 0 0 80 4000\n")
b = Backend(); b.fx_firmware = True
d = dev.build_entities(None, b)
check("tsx: effects", d.ledbar.effects_list, ["None", "Pulse", "Breathe", "Blink", "Rainbow"])
check("tsx: effect at the start", d.ledbar.effect, "Breathe")
d.ledbar.command(is_on=True, brightness=1.0, red=1.0, green=0.0, blue=0.0, effect="Breathe")
check("tsx: Breathe", b.sent, ["ledbar fx breathe 100 0 0 4000"])
b.sent.clear(); d.ledbar.command(effect="Blink", brightness=0.5)
check("tsx: Blink", b.sent, ["ledbar fx blink 50 0 0 500 500"])
b.sent.clear(); d.ledbar.command(effect="Rainbow", brightness=102 / 255)
check("tsx: Rainbow", b.sent, ["ledbar fx rainbow 10000 40"])
b.sent.clear(); d.ledbar.command(effect="None", brightness=1.0)
check("tsx: None is a color", b.sent, ["ledbar set 100 0 0"])
b.sent.clear(); d.ledbar.command(effect="Breathe"); d.ledbar.command(is_on=False)
check("tsx: off", b.sent[-1], "ledbar off")
# the poll reads the effect of the bar back
d.ledbar.is_on = True
state("want 40 40 40\nfx rainbow 10000 40\n")
d.ledbar.red, d.ledbar.green, d.ledbar.blue = 1.0, 0.0, 0.0
out = []; dev.poll(d, out.extend)
check("tsx poll: Rainbow", d.ledbar.effect, "Rainbow")
check("tsx poll: Rainbow keeps the color", (d.ledbar.red, d.ledbar.green, d.ledbar.blue), (1.0, 0.0, 0.0))
check("tsx poll: one state message", len(light_msgs(out)), 1)
out = []; dev.poll(d, out.extend)
check("tsx poll: no change, no message", light_msgs(out), [])
state("want 5 6 7\nfx none\n")      # a front key set a color: the effect ended
out = []; dev.poll(d, out.extend)
check("tsx poll: the effect ended", (d.ledbar.effect, len(light_msgs(out))), ("None", 1))
state("want 0 0 80\nfx blink 0 0 80 500 500\n")
dev.poll(d, out.extend)
check("tsx poll: Blink", d.ledbar.effect, "Blink")
state("want 100 0 0\nfx fade 100 0 0 1000\n")   # an effect without a name in Home Assistant
dev.poll(d, out.extend)
check("tsx poll: fade shows as None", d.ledbar.effect, "None")
# effect None ends the effect and the bar goes back to the color from before it
def bar_color(b):
    on, bri, r, g, b_ = b.get_ledbar(True)
    return round(bri / 255.0, 3), round(r / 255.0, 3), round(g / 255.0, 3), round(b_ / 255.0, 3)
def ha_color(d):
    return round(d.ledbar.brightness, 3), round(d.ledbar.red, 3), round(d.ledbar.green, 3), round(d.ledbar.blue, 3)
state("want 10 20 30\nfx none\n")
d.ledbar.is_on = True; out = []; dev.poll(d, out.extend)
check("fxoff: the color before the effect", ha_color(d), bar_color(b))
d.ledbar.command(effect="Breathe", red=0.0, green=0.0, blue=1.0, brightness=0.8)
check("fxoff: Breathe sent", b.sent[-1], "ledbar fx breathe 0 0 80 4000")
state("want 10 20 30\nfx breathe 0 0 80 4000\n")   # the wanted color stays
out = []; dev.poll(d, out.extend)
check("fxoff: during Breathe the light shows the effect color", (d.ledbar.effect, ha_color(d)[1:]), ("Breathe", (0.0, 0.0, 1.0)))
check("fxoff: get_ledbar shows the effect color", bar_color(b)[1:], (0.0, 0.0, 1.0))
b.sent.clear(); d.ledbar.command(effect="None")
check("fxoff: None sends fx off", b.sent, ["ledbar fx off"])
state("want 10 20 30\nfx none\n")                   # the bar went back
out = []; dev.poll(d, out.extend)
check("fxoff: effect None", d.ledbar.effect, "None")
check("fxoff: HA reports the color before the effect", ha_color(d), (0.302, 0.333, 0.667, 1.0))
check("fxoff: HA matches the bar", ha_color(d), bar_color(b))
check("fxoff: one state message", len(light_msgs(out)), 1)
# Rainbow: the color of Home Assistant is not the bar color
d.ledbar.command(effect="Rainbow", red=1.0, green=0.0, blue=0.0, brightness=0.5)
check("fxoff: Rainbow sent", b.sent[-1], "ledbar fx rainbow 10000 50")
state("want 10 20 30\nfx rainbow 10000 50\n")
out = []; dev.poll(d, out.extend)
b.sent.clear(); d.ledbar.command(effect="None")
check("fxoff: None after Rainbow sends fx off", b.sent, ["ledbar fx off"])
state("want 10 20 30\nfx none\n")
out = []; dev.poll(d, out.extend)
check("fxoff: after Rainbow HA matches the bar", (d.ledbar.effect, ha_color(d)), ("None", bar_color(b)))
# a new color with effect None still ends the effect with that color
d.ledbar.command(effect="Blink", red=0.0, green=1.0, blue=0.0, brightness=0.5)
state("want 10 20 30\nfx blink 0 50 0 500 500\n")
out = []; dev.poll(d, out.extend)
b.sent.clear(); d.ledbar.command(effect="None", red=1.0, green=0.0, blue=0.0, brightness=1.0)
check("fxoff: a new color is a color", b.sent, ["ledbar set 100 0 0"])
# off during an effect
d.ledbar.command(effect="Breathe", red=0.0, green=0.0, blue=1.0, brightness=0.8)
b.sent.clear(); d.ledbar.command(is_on=False)
check("fxoff: off during an effect", b.sent, ["ledbar off"])
# ---- TSX-LEDBAR 0.1.2: effects, but no zone effects and no actions ------------
from tsx_panel import entities as ent
from aioesphomeapi import api_pb2
def services(d):
    out = []
    for e in d.entities:
        if isinstance(e, ent.ESPHomeEntity) and type(e).__name__ != "LEDLightEntity":   # the stand-in light has no handle_message
            out.extend(m for m in e.handle_message(ent.ListEntitiesRequest()) if isinstance(m, ent.ListEntitiesServicesResponse))
    return out
state("want 10 20 30\nfx none\n")
b = Backend(); b.fx_firmware = True
d = dev.build_entities(None, b)
check("0.1.2: effects", d.ledbar.effects_list, ["None", "Pulse", "Breathe", "Blink", "Rainbow"])
check("0.1.2: no actions", (d.ledbar_actions, services(d)), (None, []))
d.ledbar.command(is_on=True, brightness=1.0, red=1.0, green=0.0, blue=0.0, effect="Chase")
check("0.1.2: Chase is no effect here", b.sent[-1], "ledbar set 100 0 0")
# a firmware with the 16 LEDs but the stock name never happens: leds needs fx
b = Backend(); b.leds_firmware = True
check("stock name, leds16: no zone effects", dev.build_entities(None, b).ledbar.effects_list, ["None", "Pulse"])

# ---- TSX-LEDBAR 0.1.3: the zone effects --------------------------------------
state("want 10 20 30\nfx none\n")
b = Backend(); b.fx_firmware = True; b.leds_firmware = True
d = dev.build_entities(None, b)
check("0.1.3: effects", d.ledbar.effects_list, ["None", "Pulse", "Breathe", "Blink", "Rainbow", "Chase", "Fill", "Spectrum"])
d.ledbar.command(is_on=True, brightness=0.8, red=1.0, green=0.0, blue=0.0, effect="Chase")
check("0.1.3: Chase uses the light color", b.sent[-1], "ledbar fx chase 80 0 0 1500")
d.ledbar.command(effect="Fill", brightness=0.5, red=0.0, green=1.0, blue=0.5)
check("0.1.3: Fill: the color at full level, the brightness is the height", b.sent[-1], "ledbar fx fill 0 100 50 50")
d.ledbar.command(effect="Spectrum", brightness=102 / 255)
check("0.1.3: Spectrum at the brightness", b.sent[-1], "ledbar fx spectrum 10000 40")
# the poll reads the zone effects back
state("want 10 20 30\nfx fill 0 100 50 25\n")
out = []; dev.poll(d, out.extend)
check("0.1.3 poll: Fill", (d.ledbar.effect, d.ledbar.is_on), ("Fill", True))
check("0.1.3 poll: Fill height is the brightness", ha_color(d), (0.251, 0.0, 1.0, 0.522))
state("want 10 20 30\nfx chase 0 0 60 1500\n")
dev.poll(d, out.extend)
check("0.1.3 poll: Chase color", (d.ledbar.effect, ha_color(d)), ("Chase", (0.6, 0.0, 0.0, 1.0)))
d.ledbar.red, d.ledbar.green, d.ledbar.blue = 1.0, 0.0, 0.0
state("want 10 20 30\nfx spectrum 10000 40\n")
dev.poll(d, out.extend)
check("0.1.3 poll: Spectrum keeps the color", (d.ledbar.effect, ha_color(d)[1:]), ("Spectrum", (1.0, 0.0, 0.0)))
state("want 10 20 30\nfx spectrum 10000 60 rows\n")   # the layout word of the firmware
dev.poll(d, out.extend)
check("0.1.3 poll: Spectrum rows, the level is the brightness", (d.ledbar.effect, ha_color(d)[0]), ("Spectrum", 0.6))
state("want 10 20 30\nfx split 100 0 0 0 0 100\n")   # split: an action, no effect of the light
dev.poll(d, out.extend)
check("0.1.3 poll: split shows as None", d.ledbar.effect, "None")
# effect None with the color of the running zone effect: fx off
d.ledbar.command(effect="Chase", red=0.0, green=0.0, blue=1.0, brightness=0.6)
state("want 10 20 30\nfx chase 0 0 60 1500\n")
out = []; dev.poll(d, out.extend)
b.sent.clear(); d.ledbar.command(effect="None")
check("0.1.3: None after Chase sends fx off", b.sent, ["ledbar fx off"])
d.ledbar.command(effect="Fill", red=0.0, green=1.0, blue=0.0, brightness=0.3)
state("want 10 20 30\nfx fill 0 100 0 30\n")
out = []; dev.poll(d, out.extend)
b.sent.clear(); d.ledbar.command(effect="None")
check("0.1.3: None after Fill sends fx off", b.sent, ["ledbar fx off"])

# ---- the actions ---------------------------------------------------------------
svc = services(d)
check("actions: names", [m.name for m in svc], ["ledbar_set_led", "ledbar_set_side", "ledbar_fill", "ledbar_split", "ledbar_clear"])
check("actions: argument names and types", [[(a.name, a.type) for a in m.args] for m in svc], [
    [("led", 3), ("red", 1), ("green", 1), ("blue", 1)],
    [("side", 3), ("red", 1), ("green", 1), ("blue", 1)],
    [("percent", 1), ("red", 1), ("green", 1), ("blue", 1)],
    [("right_red", 1), ("right_green", 1), ("right_blue", 1), ("left_red", 1), ("left_green", 1), ("left_blue", 1)],
    []])
check("actions: Home Assistant waits for the status", {m.supports_response for m in svc}, {100})
keys = [m.key for m in svc]
entity_keys = [e.key for e in d.entities if hasattr(e, "key")]
check("actions: own keys after the entity keys", (len(set(keys)), min(keys) > max(entity_keys)), (5, True))
check("actions: the light keeps its key", d.ledbar.key, 0)
by_name = {m.name: m.key for m in svc}

def arg(**kw):
    a = api_pb2.ExecuteServiceArgument()
    a.bool_, a.legacy_int, a.float_, a.string_, a.int_ = False, 0, 0.0, "", 0
    a.__dict__.update(kw)
    return a

def call(name, *args, call_id=7):
    req = ent.ExecuteServiceRequest(key=by_name[name], args=list(args), call_id=call_id)
    out = []
    for e in d.entities:
        if req.key in getattr(e, "service_keys", ()):
            out.extend(e.handle_message(req))
    return [(m.call_id, m.success, m.error_message) for m in out]

def ints(*v):
    return [arg(int_=x) for x in v]

b.sent.clear()
check("ledbar_set_led R3: response", call("ledbar_set_led", arg(string_="r3"), *ints(100, 0, 0)), [(7, True, "")])
call("ledbar_set_led", arg(string_="R1-R4"), *ints(1, 2, 3))
call("ledbar_set_led", arg(string_=" all "), *ints(1, 2, 3))
call("ledbar_set_led", arg(string_="15"), *ints(0, 0, 0))
call("ledbar_set_side", arg(string_="left"), *ints(0, 0, 50))
call("ledbar_set_side", arg(string_="R"), *ints(0, 50, 0))
call("ledbar_fill", *ints(60, 0, 100, 0))
call("ledbar_split", *ints(100, 0, 0, 0, 0, 100))
call("ledbar_clear")
check("actions: the commands", b.sent, ["ledbar led R3 100 0 0", "ledbar led R1-R4 1 2 3", "ledbar led ALL 1 2 3",
                                        "ledbar led 15 0 0 0", "ledbar side L 0 0 50", "ledbar side R 0 50 0",
                                        "ledbar fx fill 0 100 0 60", "ledbar fx split 100 0 0 0 0 100", "ledbar clear"])
b.sent.clear()
check("actions: legacy_int of an old client", (call("ledbar_fill", *[arg(legacy_int=x) for x in (5, 6, 7, 8)]), b.sent),
      ([(7, True, "")], ["ledbar fx fill 6 7 8 5"]))
b.sent.clear()
check("actions: no call_id, no response", (call("ledbar_clear", call_id=0), b.sent), ([], ["ledbar clear"]))
b.sent.clear()
bad = [
    ("ledbar_set_led", [arg(string_="R9")] + ints(1, 2, 3), "'R9' is not a LED"),
    ("ledbar_set_led", [arg(string_="R1-R2-R3")] + ints(1, 2, 3), "is not a LED"),
    ("ledbar_set_led", [arg(string_="R1;reboot")] + ints(1, 2, 3), "is not a LED"),
    ("ledbar_set_led", [arg(string_="16")] + ints(1, 2, 3), "is not a LED"),
    ("ledbar_set_led", [arg(string_="R3")] + ints(101, 2, 3), "101 is not a level from 0 to 100"),
    ("ledbar_set_led", [arg(string_="R3")] + ints(-1, 2, 3), "-1 is not a level"),
    ("ledbar_set_led", [arg(string_="R3")] + ints(1, 2), "takes 4 arguments, not 3"),
    ("ledbar_set_side", [arg(string_="X")] + ints(1, 2, 3), "'X' is not a side"),
    ("ledbar_fill", ints(101, 1, 2, 3), "101 is not a level"),
    ("ledbar_split", ints(1, 2, 3, 4, 5, 200), "200 is not a level"),
    ("ledbar_clear", ints(1), "takes 0 arguments, not 1"),
]
for name, args, msg in bad:
    res = call(name, *args)
    check(f"actions: {name} refuses ({msg})", (len(res), res[0][1], msg in res[0][2]), (1, False, True))
check("actions: a refused call sends nothing", b.sent, [])
b.listening = False
check("actions: no tsx-panelctl", call("ledbar_clear"), [(7, False, "tsx-panelctl does not listen")])
b.listening = True
check("get_ledbar_effect without a state file", (os.remove(t + "/run/ledbar.state"), b.get_ledbar_effect())[1], "None")
if fails:
    sys.exit(1)
print("PASS test-shim-ledbar")
PY
