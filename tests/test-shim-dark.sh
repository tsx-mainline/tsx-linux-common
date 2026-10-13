#!/bin/sh
# Host test of the Dark mode entity of tsx_panel (backend.py and device.py):
#  - The switch "Dark mode" (object id dark_mode) exists only where the panel
#    runs the kiosk browser (`tsx-panelctl has dark-mode`).
#  - The value comes from `tsx-panelctl get dark-mode` (here a small fake
#    script). It is cached until /etc/kiosk.conf or the override
#    /run/tsx/kiosk.conf changes, so a poll starts no process.
#  - A command goes to the FIFO of tsx-panelctl as "dark-mode on|off".
#  - A value that Home Assistant just set stays for 10 seconds, until
#    tsx-panelctl reports it. A poll does not flip it back.
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
# the fake tsx-panelctl: `get NAME` prints the file $T/pc/NAME, and fails without it.
# `has dark-mode` says yes while the file $T/pc/has-dark-mode exists.
cat > "$T/panelctl" <<EOF
#!/bin/sh
echo "\$*" >> "$T/pc-calls"
[ "\$1" = get ] && [ -r "$T/pc/\$2" ] && exec cat "$T/pc/\$2"
[ "\$1 \$2" = "has dark-mode" ] && [ -e "$T/pc/has-dark-mode" ] && exit 0
exit 1
EOF
chmod 755 "$T/panelctl"
mkfifo "$T/fifo"
python3 - "$HERE/ha/voice/shim" "$T" <<'PY'
import json, os, sys, time
shim, t = sys.argv[1:3]
sys.path[:0] = [t + "/stub", shim]
os.environ.update(TSX_RUN_DIR=t + "/run", TSX_STATE_DIR=t + "/state", TSX_BACKLIGHT_DIR=t + "/bl",
                  TSX_KIOSK_CONF=t + "/kiosk.conf", TSX_BUTTONS_CONF=t + "/none", TSX_BUTTONS_BOARD_CONF=t + "/none",
                  TSX_ALS_CONF=t + "/none", TSX_ASOUND_DIR=t + "/none", TSX_IDLED_STATE=t + "/none",
                  TSX_THERMAL_ZONE=t + "/none", TSX_PANELCTL_BIN=t + "/panelctl", TSX_PANELCTL=t + "/fifo",
                  TSX_AUTOUPDATE_CONF=t + "/au.conf", TSX_AUTOUPDATE_OVERRIDE=t + "/au-override.conf",
                  TSX_SENDSPIN_VOLUME_FILE=t + "/vol")
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

def conf_changed():
    """Touch the kiosk files, as tsx-config apply and an edit of /etc/kiosk.conf do."""
    open(t + "/kiosk.conf", "a").write("# change\n")
    open(t + "/run/kiosk.conf", "a").write("# change\n")

def dark(value=None):
    pc("dark-mode", value)
    conf_changed()

# ---- no kiosk browser: no entity ---------------------------------------------------------
b = PanelBackend()
check("no kiosk browser: dark_mode_present is false", b.dark_mode_present(), False)
check("no answer: dark mode off", b.get_dark_mode(), False)
d = dev.build_entities(None, b)
ids = [e.object_id for e in d.entities if hasattr(e, "object_id")]
check("no kiosk browser: no Dark mode entity", ("dark_mode" in ids, d.dark_mode), (False, None))

# ---- the kiosk browser: the entity ----------------------------------------------------------
open(t + "/pc/has-dark-mode", "w").close()
dark("off")
b = PanelBackend()
check("kiosk browser: dark_mode_present is true", b.dark_mode_present(), True)
d = dev.build_entities(None, b)
dm = info(d.dark_mode)
check("entity: Dark mode", (dm.object_id, dm.name, dm.icon, d.dark_mode.key),
      ("dark_mode", "Dark mode", "mdi:theme-light-dark", stable_key("dark_mode")))
ids = [e.object_id for e in d.entities if hasattr(e, "object_id")]
check("entity: each object id once", len(ids), len(set(ids)))
check("entity: the initial value is off", d.dark_mode._state, False)

# ---- the backend: values, cache, commands --------------------------------------------------
dark("on")
check("tsx-panelctl says on: dark mode on", b.get_dark_mode(), True)
dark("off")
check("tsx-panelctl says off: dark mode off", b.get_dark_mode(), False)
dark("maybe")
check("a word other than on counts as off", b.get_dark_mode(), False)
dark("on")
b.get_dark_mode()
n0 = calls("get dark-mode")
for _ in range(20):
    b.get_dark_mode()
check("20 polls with no change: no call of tsx-panelctl", calls("get dark-mode") - n0, 0)
conf_changed()
b.get_dark_mode()
check("a changed kiosk.conf: one call", calls("get dark-mode") - n0, 1)
sent()
b.set_dark_mode(True); b.set_dark_mode(False)
check("commands: dark-mode on, dark-mode off", sent(), ["dark-mode on", "dark-mode off"])

# ---- a value just set is held --------------------------------------------------------------
b = PanelBackend()
dark("off")
b.set_dark_mode(True)
check("held: on while tsx-panelctl still says off", b.get_dark_mode(), True)
check("held: the hold stays while the values differ", b._dark_mode_pending is not None, True)
dark("on")
check("held: tsx-panelctl has the new value", b.get_dark_mode(), True)
check("held: the hold ends", b._dark_mode_pending, None)
dark("off")
check("held: a later change of tsx-panelctl shows", b.get_dark_mode(), False)
b.set_dark_mode(True)
b._dark_mode_pending = (True, time.monotonic() - 11)
check("held: after 10 s tsx-panelctl wins", b.get_dark_mode(), False)
check("held: a new backend has no hold", PanelBackend()._dark_mode_pending, None)
sent()

# ---- the entity: commands and polls ----------------------------------------------------------
dark("off")
b = PanelBackend()
d = dev.build_entities(None, b)
reply = list(d.dark_mode.handle_message(pb.SwitchCommandRequest(key=d.dark_mode.key, state=True)))
check("command: Dark mode on", (sent(), reply[0].state), (["dark-mode on"], True))
reply = list(d.dark_mode.handle_message(pb.SwitchCommandRequest(key=d.dark_mode.key, state=False)))
check("command: Dark mode off", (sent(), reply[0].state), (["dark-mode off"], False))

def mine(msgs):
    return [m.state for m in msgs if getattr(m, "key", None) == d.dark_mode.key]

msgs = []
dev.poll(d, msgs.extend)
msgs.clear()
list(d.dark_mode.handle_message(pb.SwitchCommandRequest(key=d.dark_mode.key, state=True)))
dev.poll(d, msgs.extend)
check("poll: a value just set is not flipped back", (mine(msgs), d.dark_mode._state), ([], True))
dark("on")
dev.poll(d, msgs.extend)
check("poll: tsx-panelctl has the value: no change", (mine(msgs), d.dark_mode._state), ([], True))
dark("off")
b._dark_mode_pending = None
dev.poll(d, msgs.extend)
check("poll: a change from elsewhere (the setup page) reaches Home Assistant", (mine(msgs), d.dark_mode._state), ([False], False))
msgs.clear()
dev.poll(d, msgs.extend)
check("poll: no change, no message", mine(msgs), [])

sys.exit(1 if fails else 0)
PY
echo "PASS test-shim-dark"
