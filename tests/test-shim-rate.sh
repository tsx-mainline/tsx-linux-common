#!/bin/sh
# Host test of the sensor rate of the ESPHome shim (tsx_panel/throttle.py,
# entities.py, device.py) and of the sensor "Last boot":
#  - Throttle: the first value, the deadband (absolute and relative), the
#    interval of 60 s, the heartbeat after 15 min, "no value" as a change, a
#    slow drift, the comparison with the last state that went out
#  - a SensorEntity with a Throttle: the poll sends a state only when the
#    Throttle says so, a subscriber gets the reading, a heartbeat resends
#  - the entities of the device: CPU temperature, illuminance and distance
#    have a Throttle with the constants of throttle.py. Presence, touched
#    recently, the screen and the others have none.
#  - Last boot: a UTC timestamp from the clock and /proc/uptime, no jitter of
#    a second, a new value after a reboot and after a step of the clock
#  - the sensor Uptime is gone
# Small stand-ins replace aioesphomeapi, protobuf and linux_voice_assistant,
# so the test needs no network and no libmpv.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/run" "$T/state" "$T/bl" "$T/pc" "$T/stub/aioesphomeapi" "$T/stub/google/protobuf" "$T/stub/linux_voice_assistant"
export PYTHONDONTWRITEBYTECODE=1
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
        self.effects_list = list(effects) if effects else []
        self.is_on, self.brightness, self.red, self.green, self.blue, self.effect = False, 1.0, 1.0, 1.0, 1.0, ""

    def update_on_changed(self, on_changed):
        self._on_changed = on_changed
PY
# the fake tsx-panelctl: `get NAME` prints the file $T/pc/NAME, and fails without it. `has` says no.
cat > "$T/panelctl" <<EOF
#!/bin/sh
echo "\$*" >> "$T/pc-calls"
[ "\$1" = get ] && [ -r "$T/pc/\$2" ] && exec cat "$T/pc/\$2"
exit 1
EOF
chmod 755 "$T/panelctl"
mkfifo "$T/fifo"
python3 - "$HERE/ha/voice/shim" "$T" <<'PY'
import json, os, sys, time
shim, t = sys.argv[1:3]
sys.path[:0] = [t + "/stub", shim]
os.environ.update(TSX_RUN_DIR=t + "/run", TSX_STATE_DIR=t + "/state", TSX_BACKLIGHT_DIR=t + "/bl",
                  TSX_KIOSK_CONF=t + "/none", TSX_BUTTONS_CONF=t + "/none", TSX_BUTTONS_BOARD_CONF=t + "/none",
                  TSX_ALS_CONF=t + "/none", TSX_ASOUND_DIR=t + "/none", TSX_IDLED_STATE=t + "/none",
                  TSX_THERMAL_ZONE=t + "/none", TSX_PANELCTL_BIN=t + "/panelctl", TSX_PANELCTL=t + "/fifo",
                  TSX_AUTOUPDATE_CONF=t + "/au.conf", TSX_AUTOUPDATE_OVERRIDE=t + "/au-override.conf",
                  TSX_SENDSPIN_VOLUME_FILE=t + "/vol")
from aioesphomeapi import api_pb2 as pb
from tsx_panel.backend import PanelBackend
from tsx_panel import device as dev
from tsx_panel.keys import stable_key
from tsx_panel import entities, throttle
import re, random
from datetime import datetime, timezone
t_dir = t

fails = 0
def check(name, got, want):
    global fails
    if got == want:
        print("ok  ", name)
    else:
        print("FAIL", name, "got", repr(got), "want", repr(want)); fails += 1

# the reading end of the FIFO: the backend opens it without blocking and needs a reader
fifo = os.open(t + "/fifo", os.O_RDONLY | os.O_NONBLOCK)
def sent():
    """The lines that the backend wrote to the FIFO since the last call."""
    try:
        return os.read(fifo, 65536).decode().splitlines()
    except BlockingIOError:
        return []

def pc(name, value=None):
    """What `tsx-panelctl get NAME` prints. None: no answer. The backend keeps an
    answer until a settings file of tsx-autoupdate changes, so a new value also
    changes the settings file (the real tsx-panelctl reads the files)."""
    path = f"{t}/pc/{name}"
    if value is None:
        if os.path.exists(path):
            os.remove(path)
    else:
        open(path, "w").write(value + "\n")
    open(t + "/au.conf", "a").write("# " + name + " " + str(value) + "\n")

def calls(word):
    """How many times the fake tsx-panelctl was called with WORD (for example "get update-mode")."""
    try:
        return sum(1 for line in open(t + "/pc-calls") if line.strip() == word)
    except OSError:
        return 0

def state_file(**kw):
    base = {"installed_version": "0.3.5", "latest_version": "0.3.6", "title": "TSX HOST packages",
            "release_summary": "restart needed after install", "in_progress": False}
    base.update(kw)
    open(t + "/run/update-ha-state.json", "w").write(json.dumps(base) + "\n")

def info(entity):
    return list(entity.handle_message(pb.ListEntitiesRequest()))[0]

class Clock:
    def __init__(self, t=1000.0):
        self.t = t
    def __call__(self):
        return self.t
    def advance(self, s):
        self.t += s

TH = throttle
check("the constants: 60 s, 15 min, 1 degree, 5 lux and 10 %, 50 mm",
      (TH.MIN_INTERVAL, TH.HEARTBEAT, TH.CPU_TEMP_DEADBAND, TH.ILLUMINANCE_DEADBAND, TH.ILLUMINANCE_RELATIVE, TH.DISTANCE_DEADBAND),
      (60.0, 900.0, 1.0, 5.0, 0.10, 50.0))

# ---- Throttle -----------------------------------------------------------------------------
c = Clock()
t = TH.Throttle(deadband=1.0, clock=c)
check("the first value goes out", t.check(40.0), TH.Throttle.PUBLISH)
check("the same value, no time: nothing", t.check(40.0), None)
c.advance(10); check("a big change after 10 s: held (the interval)", t.check(45.0), None)
c.advance(49); check("still held at 59 s", t.check(45.0), None)
c.advance(1); check("the big change goes out at 60 s", t.check(45.0), TH.Throttle.PUBLISH)
c.advance(61); check("a change of exactly the deadband is no change", t.check(46.0), None)
c.advance(1); check("more than the deadband goes out", t.check(46.1), TH.Throttle.PUBLISH)
c.advance(120); check("a small change is held", t.check(46.5), None)
c.advance(100); check("a drift counts against the last state that went out, not the last reading", t.check(47.2), TH.Throttle.PUBLISH)
c.advance(899); check("899 s with no change: nothing", t.check(47.2), None)
c.advance(1); check("900 s: the heartbeat", t.check(47.2), TH.Throttle.REPEAT)
c.advance(899); check("the heartbeat restarts the 900 s", t.check(47.2), None)
c.advance(1); check("the next heartbeat", t.check(47.3), TH.Throttle.REPEAT)
c.advance(30); check("a heartbeat is no new value: a real change is held 60 s after it", t.check(60.0), None)
c.advance(30); check("the real change goes out", t.check(60.0), TH.Throttle.PUBLISH)
# the heartbeat repeats the last state that went out
c = Clock(); t = TH.Throttle(deadband=1.0, clock=c)
t.check(10.0); c.advance(61); t.check(10.4)
c.advance(900); check("a heartbeat while the reading moves inside the deadband", t.check(10.4), TH.Throttle.REPEAT)

# the relative part: the larger of 5 lux and 10 % of the last state
c = Clock(); t = TH.Throttle(deadband=TH.ILLUMINANCE_DEADBAND, relative=TH.ILLUMINANCE_RELATIVE, clock=c)
t.check(100.0); c.advance(61)
check("lux: +10 is not more than 10 % of 100", t.check(110.0), None)
check("lux: +10.5 is more", t.check(110.5), TH.Throttle.PUBLISH)
c.advance(61); check("lux: 10 % of 110.5 is 11.05, +11 is inside", t.check(121.5), None)
c.advance(1); check("lux: +11.1 is outside", t.check(121.6), TH.Throttle.PUBLISH)
c = Clock(); t = TH.Throttle(deadband=5.0, relative=0.10, clock=c)
t.check(0.0); c.advance(61)
check("lux: at 0 the floor is 5 lux: 5 is inside", t.check(5.0), None)
check("lux: 5.5 is outside", t.check(5.5), TH.Throttle.PUBLISH)
c.advance(61); check("lux: a fall to 0 is a change of 5.5 (floor 5)", t.check(0.0), TH.Throttle.PUBLISH)

# "no value" (the distance with no target)
c = Clock(); t = TH.Throttle(deadband=50.0, clock=c)
check("distance: the first value is none", t.check(None), TH.Throttle.PUBLISH)
c.advance(10); check("distance: a target 10 s later is held", t.check(800.0), None)
c.advance(50); check("distance: the target goes out at 60 s", t.check(800.0), TH.Throttle.PUBLISH)
c.advance(61); check("distance: +40 mm is inside", t.check(840.0), None)
c.advance(1); check("distance: +60 mm is outside", t.check(860.0), TH.Throttle.PUBLISH)
c.advance(61); check("distance: the target is gone: none goes out", t.check(None), TH.Throttle.PUBLISH)
c.advance(901); check("distance: none is repeated by the heartbeat", t.check(None), TH.Throttle.REPEAT)
t.reset(500.0); c.advance(10); check("reset counts a value as sent", t.check(700.0), None)

# ---- a SensorEntity with a Throttle ---------------------------------------------------
c = Clock()
reading = [20.0]
ent = entities.SensorEntity(None, 77, "Test", "test", get_state=lambda: reading[0], unit="x",
                            throttle=TH.Throttle(deadband=1.0, clock=c))
def poll_msgs():
    """What dev.poll does with one entity: the message, when a state goes out."""
    before = ent._state
    msg = ent.poll()
    resend = ent._resend
    ent._resend = False
    return [msg.state] if (ent._state != before or resend) else []
check("entity: the first poll sends the reading", poll_msgs(), [20.0])
reading[0] = 20.4; c.advance(61)
check("entity: a change inside the deadband sends nothing", poll_msgs(), [])
reading[0] = 22.0
c.advance(1); check("entity: a change beyond the deadband sends the new value", poll_msgs(), [22.0])
reading[0] = 25.0; c.advance(5)
check("entity: held for 60 s", poll_msgs(), [])
check("entity: a subscriber gets the reading at once", [m.state for m in ent.handle_message(pb.SubscribeHomeAssistantStatesRequest())], [25.0])
c.advance(10); check("entity: the subscriber answer counts as sent, so no state follows it", poll_msgs(), [])
c.advance(901)
check("entity: the heartbeat sends the same state again", poll_msgs(), [25.0])
check("entity: the heartbeat flag is cleared", ent._resend, False)
reading[0] = None; c.advance(61)
check("entity: no value goes out as missing_state", [getattr(m, "missing_state", None) for m in [ent.poll()]], [True])
def broken():
    raise OSError("no sensor")
ent._get_state = broken
c.advance(61); m = ent.poll()
check("entity: a failed read keeps the last state", getattr(m, "missing_state", None), True)
# without a Throttle every change goes out, as before
plain = entities.SensorEntity(None, 78, "Plain", "plain", get_state=lambda: reading[0])
reading[0] = 1.0; before = plain._state; plain.poll()
check("entity: no Throttle, a change goes out at once", plain._state != before, True)

# ---- the entities of the device -----------------------------------------------------------------
os.makedirs(t_dir + "/run", exist_ok=True)
open(t_dir + "/run/als.state", "w").write("report 10\nauto on\n")
open(t_dir + "/run/presence.state", "w").write("present on\ndistance 700\n")
open(t_dir + "/run/hw.conf", "w").write("PRESENCE=tof\n")
open(t_dir + "/none-als", "w").write("")
os.environ["TSX_ALS_CONF"] = t_dir + "/none-als"
open(t_dir + "/thermal", "w").write("42000\n")
os.environ["TSX_THERMAL_ZONE"] = t_dir + "/thermal"
b = PanelBackend()
d = dev.build_entities(None, b)
thr = lambda e: e is not None and e._throttle is not None
check("device: the CPU temperature, the illuminance and the distance have a Throttle",
      (thr(d.cpu_temp), thr(d.illuminance), thr(d.distance)), (True, True, True))
check("device: the deadbands are the constants of throttle.py",
      (d.cpu_temp._throttle.deadband, d.illuminance._throttle.deadband, d.illuminance._throttle.relative, d.distance._throttle.deadband),
      (TH.CPU_TEMP_DEADBAND, TH.ILLUMINANCE_DEADBAND, TH.ILLUMINANCE_RELATIVE, TH.DISTANCE_DEADBAND))
check("device: every Throttle has the interval and the heartbeat of throttle.py",
      {(e._throttle.min_interval, e._throttle.heartbeat) for e in (d.cpu_temp, d.illuminance, d.distance)}, {(TH.MIN_INTERVAL, TH.HEARTBEAT)})
fast = [d.presence, d.touched_recently, d.screen, d.volume, d.backlight, d.blank_timeout, d.update, d.restart_required,
        d.update_mode, d.auto_restart, d.verbose_boot, d.ip_address, d.last_boot]
check("device: the entities that must stay fast have no Throttle", [getattr(e, "_throttle", None) for e in fast if e is not None], [None] * len([e for e in fast if e is not None]))
ids = [e.object_id for e in d.entities if hasattr(e, "object_id")]
check("device: no entity with the object id uptime", "uptime" in ids, False)
lbi = list(d.last_boot.handle_message(pb.ListEntitiesRequest()))[0]
check("device: Last boot", (lbi.object_id, lbi.name, lbi.device_class, lbi.icon, d.last_boot.key),
      ("last_boot", "Last boot", "timestamp", "mdi:restart", stable_key("last_boot")))

# a CPU temperature that moves by 0.1 degree every second sends a few states in a day
class Tclock(Clock):
    pass
c = Clock(); d.cpu_temp._throttle._clock = c
temps = [42.0]
d.cpu_temp._get_state = lambda: temps[0]
sent_states = 0
import random
rnd = random.Random(5)
msgs = []
for second in range(24 * 3600):
    c.advance(1)
    temps[0] = 42.0 + 0.8 * ((second // 7200) % 3) + rnd.uniform(-0.3, 0.3)
    before = d.cpu_temp._state
    d.cpu_temp.poll()
    if d.cpu_temp._state != before or d.cpu_temp._resend:
        sent_states += 1
        d.cpu_temp._resend = False
check("device: a CPU temperature read once a second sends at most 200 states in 24 h (96 are heartbeats. HA recorded 67451 before)", sent_states <= 200, True)
print("states of the CPU temperature in 24 h:", sent_states)

# ---- Last boot ----------------------------------------------------------------------------------------
open(t_dir + "/uptime", "w").write("1000.40 3000.00\n")
os.environ["TSX_PROC_UPTIME"] = t_dir + "/uptime"
b = PanelBackend()
wall = [1800001000.0]
b._wall_clock = lambda: wall[0]
iso = lambda e: datetime.fromtimestamp(e, tz=timezone.utc).isoformat(timespec="seconds")
first = b.get_last_boot()
check("last boot: the clock minus the uptime, as ISO 8601 in UTC", first, iso(1800000000 - 0.4 + 0.4))
check("last boot: the format", re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\+00:00", first) is not None, True)
out = set()
for i in range(300):
    wall[0] = 1800001000.0 + i * 0.37
    open(t_dir + "/uptime", "w").write("%.2f 0\n" % (1000.40 + i * 0.37 + random.Random(i).uniform(-0.6, 0.6)))
    out.add(b.get_last_boot())
check("last boot: 300 reports with 0.6 s of jitter give one text", out, {first})
wall[0] = 1800001500.0; open(t_dir + "/uptime", "w").write("1500.00 0\n")
check("last boot: a jitter of 0.4 s after the boot is no change", b.get_last_boot(), first)
wall[0] = 1800001500.0 + 400; open(t_dir + "/uptime", "w").write("1500.00 0\n")
check("last boot: a step of the clock (NTP) by 400 s gives a new value", b.get_last_boot(), iso(1800000400))
wall[0] = 1800002000.0; open(t_dir + "/uptime", "w").write("8.00 0\n")
check("last boot: a reboot gives a new value", b.get_last_boot(), iso(1800001992))
open(t_dir + "/uptime", "w").write("garbage\n")
check("last boot: an unreadable /proc/uptime keeps the last value", b.get_last_boot(), iso(1800001992))
b2 = PanelBackend(); b2._wall_clock = lambda: 1800000000.0
open(t_dir + "/uptime", "w").write("garbage\n")
check("last boot: no value yet and no uptime: empty text", b2.get_last_boot(), "")

sys.exit(1 if fails else 0)
PY
echo "PASS test-shim-rate"
