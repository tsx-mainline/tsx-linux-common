#!/bin/sh
# Host test of the plugins of the ESPHome device: the folder esphome.d
# (tsx_panel/plugins.py, docs/esphome.md "Plugins"). The test uses the fake
# plugin of the made-up board (tests/boards/fake/esphome.d/fakeent.py) and
# some broken plugins that the test writes. It checks:
#  - the loader: the trust rules (owner and write bits), the order, the files
#    that it skips, and a plugin that fails to load
#  - the entities of the plugins in build_entities() and in the poll
#  - both front ends with the same plugin: tsx-esphome (esphome_server.py) and
#    the voice satellite (tsx_lva): the entity list, an API message that only
#    the plugin handles, the closed connection, and one load for each process
#  - a plugin function that fails does not stop the device
# Small stand-ins replace aioesphomeapi, protobuf and linux_voice_assistant.
# The test needs no network and no hardware.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/run" "$T/state" "$T/bl" "$T/pd" "$T/stub/aioesphomeapi" "$T/stub/google/protobuf" "$T/stub/linux_voice_assistant" "$T/stub/getmac"
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
cat > "$T/stub/aioesphomeapi/model.py" <<'PY'
class VoiceAssistantFeature:
    VOICE_ASSISTANT = 1
PY
: > "$T/stub/google/__init__.py"; : > "$T/stub/google/protobuf/__init__.py"
echo "class Message: pass" > "$T/stub/google/protobuf/message.py"
echo "def get_mac_address(interface=None): return '02:00:00:00:00:01'" > "$T/stub/getmac/__init__.py"
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
        self.is_on, self.brightness, self.red, self.green, self.blue, self.effect = False, 1.0, 1.0, 1.0, 1.0, ""

    def update_on_changed(self, on_changed):
        self._on_changed = on_changed
PY
cat > "$T/stub/linux_voice_assistant/api_server.py" <<'PY'
class APIServer:
    """One client connection. send_messages() keeps what the server sends."""
    def __init__(self, name):
        self.name, self.sent = name, []

    def connection_made(self, transport):
        self._tsx_denied = False

    def connection_lost(self, exc):
        pass

    def send_messages(self, msgs):
        self.sent.extend(msgs)
PY
cat > "$T/stub/linux_voice_assistant/util.py" <<'PY'
def get_default_interface(): return "lo"
def get_default_ipv4(iface): return "127.0.0.1"
PY
echo "class HomeAssistantZeroconf: pass" > "$T/stub/linux_voice_assistant/zeroconf.py"
cat > "$T/stub/linux_voice_assistant/satellite.py" <<'PY'
from aioesphomeapi import api_pb2 as pb

class VoiceSatelliteProtocol:
    """The satellite of linux-voice-assistant, reduced to what tsx_lva patches."""
    def __init__(self, state):
        self.state, self.sent = state, []

    def handle_message(self, msg):
        if isinstance(msg, pb.ListEntitiesRequest):
            for entity in self.state.entities:
                yield from entity.handle_message(msg)

    def connection_lost(self, exc):
        pass

    def send_messages(self, msgs):
        self.sent.extend(msgs)

class ServerState:
    def __init__(self):
        self.entities = []
        self.connections = []

    def broadcast(self, msgs):
        pass
PY

# the plugin folders: copies with fixed modes, so that a checkout with another umask does not matter
mkdir "$T/pd/good"
cp "$HERE/tests/boards/fake/esphome.d/fakeent.py" "$T/pd/good/"
chmod 755 "$T/pd/good"; chmod 644 "$T/pd/good/fakeent.py"

python3 - "$HERE/ha/voice/shim" "$T" <<'PY'
import contextlib, io, logging, os, stat, sys, types
shim, t = sys.argv[1:3]
sys.path[:0] = [t + "/stub", shim]
me = os.getuid()
os.environ.update(TSX_RUN_DIR=t + "/run", TSX_STATE_DIR=t + "/state", TSX_BACKLIGHT_DIR=t + "/bl",
                  TSX_KIOSK_CONF=t + "/none", TSX_BUTTONS_CONF=t + "/none", TSX_ALS_CONF=t + "/none",
                  TSX_ASOUND_DIR=t + "/none", TSX_IDLED_STATE=t + "/none", TSX_PANELCTL_BIN="/nonexistent",
                  TSX_THERMAL_ZONE=t + "/none", TSX_HA_TRANSPORT="esphome", TSX_PLUGIN_OWNER_UID=str(me))
os.environ.pop("TSX_ESPHOME_PLUGIN_DIR", None)

# tsx-esphome needs the encryption module, which needs the cryptography package: a stand-in for security
import tsx_panel
security = types.ModuleType("tsx_panel.security")
security.enforce, security.encryption_enabled = (lambda: None), (lambda: False)
sys.modules["tsx_panel.security"] = tsx_panel.security = security

from aioesphomeapi import api_pb2 as pb
from tsx_panel import device as dev
from tsx_panel import esphome_server, plugins
from tsx_panel.backend import PanelBackend
from tsx_panel import backend as backend_mod
from tsx_panel.keys import stable_key

fails = 0
def check(name, got, want):
    global fails
    if got == want:
        print("ok  ", name)
    else:
        print("FAIL", name, "got", repr(got), "want", repr(want)); fails += 1

class Cap(logging.Handler):
    """The log lines of the loader, so that a test can read them."""
    def __init__(self):
        super().__init__()
        self.records = []
    def emit(self, record):
        self.records.append(record)

cap = Cap()
log = logging.getLogger("tsx_panel.plugins")
log.addHandler(cap); log.setLevel(logging.INFO); log.propagate = False

def warnings():
    out = [r for r in cap.records if r.levelno >= logging.WARNING]
    cap.records.clear()
    return out

def texts(records):
    return [r.getMessage() for r in records]

def make_dir(name, files, dir_mode=0o755, file_mode=0o644):
    path = os.path.join(t, "pd", name)
    os.makedirs(path)
    for fname, text in files.items():
        with open(os.path.join(path, fname), "w") as fobj:
            fobj.write(text)
        os.chmod(os.path.join(path, fname), file_mode)
    os.chmod(path, dir_mode)
    return path

class Backend(PanelBackend):
    def _panelctl(self, *args, timeout=5):
        return False, ""

def names(path):
    return [os.path.basename(m.__file__) for m in plugins.load(path)]

GOOD = t + "/pd/good"
FAKE = open(GOOD + "/fakeent.py").read()

# ---- the loader -----------------------------------------------------------------------
check("the fake plugin loads", names(GOOD), ["fakeent.py"])
check("a good plugin gives no warning", texts(warnings()), [])
check("a missing folder: no plugin, no log line", (names(t + "/pd/none"), texts(warnings())), ([], []))
check("the default folder", plugins.plugin_dir(), "/usr/local/share/tsx/esphome.d")
check("the default owner is root", (os.environ.pop("TSX_PLUGIN_OWNER_UID"), plugins.owner_uid())[1], 0)
os.environ["TSX_PLUGIN_OWNER_UID"] = str(me)
check("a bad owner id counts as root", (os.environ.__setitem__("TSX_PLUGIN_OWNER_UID", "x"), plugins.owner_uid())[1], 0)
os.environ["TSX_PLUGIN_OWNER_UID"] = str(me)

d = make_dir("order", {"b.py": "X = 1\n", "a.py": "X = 1\n", "_skip.py": "X = 1\n", ".hidden.py": "X = 1\n",
                        "notes.txt": "x\n", "c.pyc": "x\n"})
check("the files load in name order. Other names are no plugin", names(d), ["a.py", "b.py"])
check("an unused name gives no warning", texts(warnings()), [])

# who owns the folder and the files
os.environ["TSX_PLUGIN_OWNER_UID"] = str(me + 1)
check("another owner id: nothing loads", names(GOOD), [])
w = texts(warnings())
check("another owner id: one line for the folder", (len(w), "is not owned by user %d" % (me + 1) in w[0]), (1, True))
os.environ.pop("TSX_PLUGIN_OWNER_UID")
if me != 0:
    check("the default owner is root: a file of another user does not load", names(GOOD), [])
    check("... and the log line says why", ["is not owned by user 0" in x for x in texts(warnings())], [True])
os.environ["TSX_PLUGIN_OWNER_UID"] = str(me)

for label, mode in (("group", 0o775), ("others", 0o757)):
    d = make_dir("dir-" + label, {"p.py": "X = 1\n"}, dir_mode=mode)
    check("a folder that the %s can write: no plugin" % label, names(d), [])
    w = texts(warnings())
    check("... one log line", (len(w), "can be changed by its group or by others" in w[0]), (1, True))
for label, mode in (("group", 0o664), ("others", 0o646)):
    d = make_dir("file-" + label, {"bad.py": "X = 1\n", "ok.py": "X = 1\n"})
    os.chmod(d + "/bad.py", mode)
    check("a file that the %s can write is skipped. The other file loads" % label, names(d), ["ok.py"])
    w = texts(warnings())
    check("... one log line", (len(w), "bad.py" in w[0] and "changed by its group or by others" in w[0]), (1, True))
d = make_dir("link", {"real.py": "X = 1\n"})
os.symlink(GOOD + "/fakeent.py", d + "/link.py")
check("a link is skipped", names(d), ["real.py"])
w = texts(warnings())
check("... one log line", (len(w), "link.py" in w[0]), (1, True))
os.makedirs(t + "/pd/file-is-folder/folder.py")
check("a folder named like a plugin is skipped", names(t + "/pd/file-is-folder"), [])
check("... one log line", len(warnings()), 1)
with open(t + "/pd/afile", "w") as fobj:
    fobj.write("x\n")
check("a plugin folder that is a file: no plugin", names(t + "/pd/afile"), [])
check("... one log line", len(warnings()), 1)

# a plugin that fails to load
d = make_dir("broken", {"a_syntax.py": "def (:\n", "b_raise.py": "raise RuntimeError('no luck')\n",
                        "c_exit.py": "import sys\nsys.exit(3)\n", "d_import.py": "import no_such_module_tsx\n",
                        "e_good.py": "X = 1\n"})
check("a plugin that fails to load is skipped. A later plugin loads", names(d), ["e_good.py"])
w = texts(warnings())
check("... one log line for each", [("%s skipped" % n) in x for x, n in zip(w, ("a_syntax.py", "b_raise.py", "c_exit.py", "d_import.py"))], [True] * 4)
check("... and nothing else", len(w), 4)
check("a plugin that failed leaves no module behind", [n for n in sys.modules if n.startswith("tsx_esphome_plugin_b_raise")], [])

# ---- the entities of the plugins -------------------------------------------------------
os.environ["TSX_ESPHOME_PLUGIN_DIR"] = t + "/pd/none"
plugins.reset()
base = dev.build_entities(None, Backend())
base_ids = [e.object_id for e in base.entities]
check("no folder: no plugin entity", (base.plugin_entities, plugins.names()), ([], []))

os.environ["TSX_ESPHOME_PLUGIN_DIR"] = GOOD
plugins.reset()
d = dev.build_entities(None, Backend())
ids = [e.object_id for e in d.entities]
check("the plugin entities come after the entities of the device", ids, base_ids + ["fake_frame", "fake_press", "fake_stamp"])
check("... and are in plugin_entities", [e.object_id for e in d.plugin_entities], ["fake_frame", "fake_press", "fake_stamp"])
check("each plugin entity has the fixed key of its object id", [e.key for e in d.plugin_entities],
      [stable_key(i) for i in ("fake_frame", "fake_press", "fake_stamp")])
check("all keys are different", len({e.key for e in d.entities}), len(d.entities))
check("the plugin is loaded once", (plugins.loaded() is plugins.loaded(), plugins.names()), (True, ["fakeent.py"]))
mod = plugins.loaded()[0]
check("... as a module of its own", sys.modules.get("tsx_esphome_plugin_fakeent") is mod, True)

sent = []
def broadcast(msgs):
    sent.extend(msgs)

dev.poll(d, broadcast)
stamp = d.plugin_entities[2]
check("poll: the first poll sends the state of a sensor with a getter",
      [(type(m).__name__, m.key, m.state) for m in sent if m.key == stamp.key], [("TextSensorStateResponse", stamp.key, "none")])
sent.clear()
dev.poll(d, broadcast)
check("poll: no new message when the state is the same", [m for m in sent if getattr(m, "key", None) == stamp.key], [])
button = d.plugin_entities[1]
list(button.handle_message(pb.ButtonCommandRequest(key=button.key)))
check("the button of the plugin runs its function", mod.STATE["presses"], 1)
dev.poll(d, broadcast)
check("poll: a new state goes out once", [m.state for m in sent if getattr(m, "key", None) == stamp.key], ["press 1"])
check("poll: an entity without poll() is not polled",
      plugins.poll([d.plugin_entities[0], d.plugin_entities[1]]), [])

# ---- tsx-esphome (VOICE=off) -------------------------------------------------------------
class Transport:
    def get_extra_info(self, name):
        return ("192.0.2.9", 40000)

esphome_server.PanelAPIServer.device = d
srv = esphome_server.PanelAPIServer()
srv.connection_made(Transport())
listed = list(srv.handle_message(pb.ListEntitiesRequest()))
check("tsx-esphome: the entity list holds the plugin entities (the camera shape, button, text sensor)",
      [(type(m).__name__, m.object_id) for m in listed if hasattr(m, "object_id")][-3:],
      [("ListEntitiesCameraResponse", "fake_frame"), ("ListEntitiesButtonResponse", "fake_press"),
       ("ListEntitiesTextSensorResponse", "fake_stamp")])
check("tsx-esphome: the list ends with the done message", type(listed[-1]).__name__, "ListEntitiesDoneResponse")
out = list(srv.handle_message(pb.SubscribeLogsRequest(level=1)))
check("tsx-esphome: a message that only the plugin handles. The plugin answers on the connection",
      (out, [(type(m).__name__, m.message) for m in srv.sent], mod.STATE["requests"]),
      ([], [("SubscribeLogsResponse", b"fake log line")], 1))
srv.sent.clear()
states = list(srv.handle_message(pb.SubscribeStatesRequest()))
check("tsx-esphome: a message of the device still works", [m.state for m in states if getattr(m, "key", None) == stamp.key],
      ["press 1"])
srv.connection_lost(None)
check("tsx-esphome: the plugin sees the closed connection", mod.STATE["lost"], [srv])
mod.STATE["lost"].clear()

# ---- the voice satellite (VOICE=on) ---------------------------------------------------------
import tsx_lva
from linux_voice_assistant import satellite as lva
backend_mod.PanelBackend = Backend
plugins.reset()
before = set(sys.modules)
err = io.StringIO()
with contextlib.redirect_stderr(err):
    tsx_lva._patch_panel()
check("voice: the patch loads the plugins and says so", "tsx_lva: ESPHome plugins fakeent.py" in err.getvalue(), True)
mod2 = plugins.loaded()[0]
check("voice: the plugin is loaded once", (len(plugins.loaded()), sys.modules["tsx_esphome_plugin_fakeent"] is mod2), (1, True))
state = lva.ServerState()
sat = lva.VoiceSatelliteProtocol(state)
check("voice: the entities of the plugin join the device",
      [e.object_id for e in state.entities][-3:], ["fake_frame", "fake_press", "fake_stamp"])
listed = list(sat.handle_message(pb.ListEntitiesRequest()))
check("voice: the entity list holds them", [m.object_id for m in listed if hasattr(m, "object_id")][-3:],
      ["fake_frame", "fake_press", "fake_stamp"])
requests = mod2.STATE["requests"]
out = list(sat.handle_message(pb.SubscribeLogsRequest(level=1)))
check("voice: a message that only the plugin handles. The plugin answers on the connection",
      (out, [(type(m).__name__, m.message) for m in sat.sent], mod2.STATE["requests"] - requests),
      ([], [("SubscribeLogsResponse", b"fake log line")], 1))
sat.connection_lost(None)
check("voice: the plugin sees the closed connection", mod2.STATE["lost"], [sat])
mod2.STATE["lost"].clear()
err = io.StringIO()
with contextlib.redirect_stderr(err):
    state2 = lva.ServerState()
    lva.VoiceSatelliteProtocol(state2)
check("voice: a second connection state loads no plugin again", (sys.modules["tsx_esphome_plugin_fakeent"] is mod2, err.getvalue()), (True, ""))

# ---- a plugin that fails at run time does not stop the device ---------------------------------
BAD = '''
import logging
from tsx_panel.entities import TextSensorEntity

def entities(server, key_for):
    raise RuntimeError("entities failed")

def handle_message(conn, msg):
    raise RuntimeError("handle_message failed")

def connection_lost(conn):
    raise RuntimeError("connection_lost failed")
'''
NOT_ENTITY = '''
def entities(server, key_for):
    return [object(), "text"]
'''
POLL = '''
from tsx_panel.entities import TextSensorEntity
class Sensor(TextSensorEntity):
    def poll(self):
        raise RuntimeError("poll failed")
def entities(server, key_for):
    return [Sensor(server, key_for("poll_fail"), "Poll fail", "poll_fail", get_state=lambda: "x")]
'''
d = make_dir("runtime", {"a_bad.py": BAD, "b_notentity.py": NOT_ENTITY, "c_poll.py": POLL, "d_fake.py": FAKE})
os.environ["TSX_ESPHOME_PLUGIN_DIR"] = d
plugins.reset()
cap.records.clear()
d3 = dev.build_entities(None, Backend())
check("run time: a failing entities() is skipped. The other plugins add their entities",
      [e.object_id for e in d3.plugin_entities], ["poll_fail", "fake_frame", "fake_press", "fake_stamp"])
w = warnings()
check("run time: one log line for entities(), two for objects that are no entity",
      (len(w), "entities() of" in w[0].getMessage(), bool(w[0].exc_info), sum("no entity" in x.getMessage() for x in w)), (3, True, True, 2))
srv = esphome_server.PanelAPIServer()
for _ in range(3):
    out = list(srv.handle_message(pb.SubscribeLogsRequest(level=1)))
check("run time: a plugin that fails in handle_message does not stop the next plugin",
      [type(m).__name__ for m in srv.sent], ["SubscribeLogsResponse"] * 3)
w = warnings()
check("run time: the error is logged once with its details, then without", [(x.getMessage().split("()")[0], bool(x.exc_info)) for x in w][:1], [("esphome.d: handle_message", True)])
check("run time: ... three calls, one line with details", (len(w), sum(bool(x.exc_info) for x in w)), (3, 1))
srv.connection_lost(None)
check("run time: a plugin that fails in connection_lost does not stop the others", srv in sys.modules["tsx_esphome_plugin_d_fake"].STATE["lost"], True)
sent.clear()
dev.poll(d3, broadcast)
check("run time: a poll() that fails does not stop the poll",
      sorted(getattr(m, "key", 0) for m in sent if getattr(m, "key", 0) in {e.key for e in d3.plugin_entities}),
      sorted(e.key for e in d3.plugin_entities if e.object_id == "fake_stamp"))
check("run time: ... and the failed poll is logged", any("poll() of poll_fail failed" in x.getMessage() for x in warnings()), True)

sys.exit(1 if fails else 0)
PY
echo "PASS test-shim-plugins"
