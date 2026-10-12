#!/bin/sh
# Host test of the update entities of tsx_panel (backend.py and device.py):
#  - The entity list: Update, Restart required (binary sensor), Restart
#    (button, object id reboot), Update mode (select: auto, manual) and
#    Automatic restart (switch), with their names, icons and fixed keys.
#  - The values come from `tsx-panelctl get update-mode|auto-restart` (here a
#    small fake script). Without an answer they come from the update state
#    file, then from the defaults. "Restart required" comes from the key
#    restart_required of update-ha-state.json.
#  - Commands go to the FIFO of tsx-panelctl (here a real FIFO that the test
#    reads): reboot, update-install, update-mode V, auto-restart on|off.
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

# ---- the backend: no answer, no file --------------------------------------------------
b = PanelBackend()
status = b.get_update_status()
check("default status: restart_required, mode and auto_restart",
      (status["restart_required"], status["mode"], status["auto_restart"]), (False, "auto", True))
check("no answer, no file: restart not required", b.get_restart_required(), False)
check("no answer, no file: mode auto", b.get_update_mode(), "auto")
check("no answer, no file: automatic restart on", b.get_auto_restart(), True)

# ---- the backend: the update state file -------------------------------------------------
state_file(restart_required=True, mode="manual", auto_restart=False)
check("state file: restart required", b.get_restart_required(), True)
check("state file: mode manual", b.get_update_mode(), "manual")
check("state file: automatic restart off", b.get_auto_restart(), False)
state_file(restart_required=False)
check("state file: restart not required", b.get_restart_required(), False)
check("state file without mode and auto_restart: the defaults", (b.get_update_mode(), b.get_auto_restart()), ("auto", True))

# ---- the backend: tsx-panelctl wins over the state file ----------------------------------
pc("update-mode", "auto"); pc("auto-restart", "off")
state_file(mode="manual", auto_restart=True)
check("tsx-panelctl: mode", b.get_update_mode(), "auto")
check("tsx-panelctl: automatic restart", b.get_auto_restart(), False)
pc("update-mode", "weekly"); pc("auto-restart", "maybe")
check("tsx-panelctl: a bad answer falls back to the state file", (b.get_update_mode(), b.get_auto_restart()), ("manual", True))
pc("update-mode"); pc("auto-restart")

# ---- the backend: the settings are asked for once, not at every poll ----------------------
pc("update-mode", "manual"); pc("auto-restart", "on")
b = PanelBackend()
n0, n1 = calls("get update-mode"), calls("get auto-restart")
for _ in range(20):
    b.get_update_mode(); b.get_auto_restart()
check("20 polls with no change: one call for each setting", (calls("get update-mode") - n0, calls("get auto-restart") - n1), (1, 1))
check("the cached values are right", (b.get_update_mode(), b.get_auto_restart()), ("manual", True))
pc("update-mode", "auto")
check("a changed settings file: the next poll asks again and shows the new value", b.get_update_mode(), "auto")
check("only the changed file costs a call for each setting", (calls("get update-mode") - n0, calls("get auto-restart") - n1), (2, 1))
open(t + "/au-override.conf", "w").write("MODE=manual\n")   # the override file of tsx-config apply appears
check("a new override file: asked again", (b.get_update_mode(), calls("get update-mode") - n0), ("auto", 3))
pc("update-mode")   # no answer: not kept
n2 = calls("get update-mode")
for _ in range(3):
    b.get_update_mode()
check("a failed call is not kept: asked at each poll", calls("get update-mode") - n2, 3)
pc("update-mode", "manual")
check("after a failure the answer comes back at once", b.get_update_mode(), "manual")
os.remove(t + "/au-override.conf")
pc("update-mode"); pc("auto-restart")

# ---- the backend: the volume from the file of the Sendspin player -------------------------
b = PanelBackend()
vol_calls = lambda: calls("get volume")
pc("volume", "33")
check("no player file: the volume comes from tsx-panelctl", (b.get_volume(), vol_calls()), (33.0, 1))
open(t + "/vol", "w").write("# Written by sendspin-cli. Edits are overwritten.\nvolume = 42\nmuted = false\n")
check("player file: volume = 42", (b.get_volume(), vol_calls()), (42.0, 1))
open(t + "/vol", "w").write("muted = false\nvolume=7\n")
check("player file without spaces around =", b.get_volume(), 7.0)
open(t + "/vol", "w").write("volume = 101\n")
check("player file: 101 is no volume (0, as tsx-panelctl)", (b.get_volume(), vol_calls()), (0.0, 1))
open(t + "/vol", "w").write("volume = abc\n")
check("player file: a word is no volume", b.get_volume(), 0.0)
open(t + "/vol", "w").write("muted = true\n")
check("player file without a volume line", (b.get_volume(), vol_calls()), (0.0, 1))
os.remove(t + "/vol")
check("the player file is gone: tsx-panelctl again", (b.get_volume(), vol_calls()), (33.0, 2))
pc("volume")

# ---- the backend: commands to the FIFO ---------------------------------------------------
sent()
b.reboot(); b.install_update()
b.set_update_mode("manual"); b.set_update_mode("auto"); b.set_update_mode("sometimes")
b.set_auto_restart(False); b.set_auto_restart(True)
check("commands: reboot, update-install, update-mode V, auto-restart on|off (a bad mode is refused)", sent(),
      ["reboot", "update-install", "update-mode manual", "update-mode auto", "auto-restart off", "auto-restart on"])

# ---- the backend: a value just set is held -----------------------------------------------
b = PanelBackend()
pc("update-mode", "auto"); pc("auto-restart", "on")
b.set_update_mode("manual"); b.set_auto_restart(False)
check("held: mode and automatic restart while tsx-panelctl has the old values", (b.get_update_mode(), b.get_auto_restart()), ("manual", False))
check("held: the hold stays while the values differ", (b._update_mode_pending is not None, b._auto_restart_pending is not None), (True, True))
pc("update-mode", "manual"); pc("auto-restart", "off")
check("held: tsx-panelctl has the new values", (b.get_update_mode(), b.get_auto_restart()), ("manual", False))
check("held: the hold ends", (b._update_mode_pending, b._auto_restart_pending), (None, None))
pc("update-mode", "auto"); pc("auto-restart", "on")
check("held: a later change of tsx-panelctl shows", (b.get_update_mode(), b.get_auto_restart()), ("auto", True))
b.set_update_mode("manual"); b.set_auto_restart(False)
b._update_mode_pending = ("manual", time.monotonic() - 11)
b._auto_restart_pending = (False, time.monotonic() - 11)
check("held: after 10 s tsx-panelctl wins", (b.get_update_mode(), b.get_auto_restart()), ("auto", True))
check("held: a new backend has no hold", (PanelBackend()._update_mode_pending, PanelBackend()._auto_restart_pending), (None, None))
sent()

# ---- the entities ----------------------------------------------------------------------------
pc("update-mode", "auto"); pc("auto-restart", "on")
state_file(restart_required=False, mode="auto", auto_restart=True)
b = PanelBackend()
d = dev.build_entities(None, b)
check("entity: Update", (info(d.update).object_id, info(d.update).name, info(d.update).icon),
      ("update", "Update", "mdi:package-up"))
rr = info(d.restart_required)
check("entity: Restart required", (rr.object_id, rr.name, rr.icon, d.restart_required.key),
      ("restart_required", "Restart required", "mdi:restart-alert", stable_key("restart_required")))
rb = info(d.reboot_button)
check("entity: Restart button keeps the object id reboot", (rb.object_id, rb.name, rb.icon, d.reboot_button.key),
      ("reboot", "Restart", "mdi:restart", stable_key("reboot")))
um = info(d.update_mode)
check("entity: Update mode", (um.object_id, um.name, um.icon, list(um.options), d.update_mode.key),
      ("update_mode", "Update mode", "mdi:update", ["auto", "manual"], stable_key("update_mode")))
ar = info(d.auto_restart)
check("entity: Automatic restart", (ar.object_id, ar.name, ar.icon, d.auto_restart.key),
      ("auto_restart", "Automatic restart", "mdi:restart", stable_key("auto_restart")))
ids = [e.object_id for e in d.entities if hasattr(e, "object_id")]
check("entity: each object id once", len(ids), len(set(ids)))
check("entity: no entity with the object id restart (the button is reboot)", "restart" in ids, False)
check("entity: the initial values", (d.update_mode._state, d.auto_restart._state, d.restart_required._state),
      ("auto", True, False))

# commands from Home Assistant
sent()
list(d.reboot_button.handle_message(pb.ButtonCommandRequest(key=d.reboot_button.key)))
check("command: the Restart button sends reboot", sent(), ["reboot"])
list(d.update.handle_message(pb.UpdateCommandRequest(key=d.update.key, command=pb.UpdateCommand.UPDATE_COMMAND_UPDATE)))
check("command: Install sends update-install", sent(), ["update-install"])
list(d.update.handle_message(pb.UpdateCommandRequest(key=d.update.key, command=pb.UpdateCommand.UPDATE_COMMAND_CHECK)))
check("command: Check sends nothing", sent(), [])
reply = list(d.update_mode.handle_message(pb.SelectCommandRequest(key=d.update_mode.key, state="manual")))
check("command: Update mode manual", (sent(), reply[0].state), (["update-mode manual"], "manual"))
reply = list(d.update_mode.handle_message(pb.SelectCommandRequest(key=d.update_mode.key, state="weekly")))
check("command: a bad Update mode is refused and the state stays", (sent(), reply[0].state), ([], "manual"))
reply = list(d.auto_restart.handle_message(pb.SwitchCommandRequest(key=d.auto_restart.key, state=False)))
check("command: Automatic restart off", (sent(), reply[0].state), (["auto-restart off"], False))
reply = list(d.auto_restart.handle_message(pb.SwitchCommandRequest(key=d.auto_restart.key, state=True)))
check("command: Automatic restart on", (sent(), reply[0].state), (["auto-restart on"], True))

# polls
def mine(msgs):
    names = {d.restart_required.key: "restart_required", d.update_mode.key: "update_mode",
             d.auto_restart.key: "auto_restart", d.update.key: "update"}
    return [(names[m.key], getattr(m, "state", None)) for m in msgs if getattr(m, "key", None) in names
            and names[m.key] != "update"]

msgs = []
dev.poll(d, msgs.extend)
msgs.clear()
# the values were just set (manual, on). tsx-panelctl still says auto and on: the poll shows the held value
list(d.update_mode.handle_message(pb.SelectCommandRequest(key=d.update_mode.key, state="manual")))
list(d.auto_restart.handle_message(pb.SwitchCommandRequest(key=d.auto_restart.key, state=False)))
dev.poll(d, msgs.extend)
check("poll: a value just set is not flipped back", (mine(msgs), d.update_mode._state, d.auto_restart._state),
      ([], "manual", False))
pc("update-mode", "manual"); pc("auto-restart", "off")
dev.poll(d, msgs.extend)
check("poll: tsx-panelctl has the values: no change", (mine(msgs), d.update_mode._state, d.auto_restart._state),
      ([], "manual", False))
# a change from elsewhere (the setup page) reaches Home Assistant
pc("update-mode", "auto"); pc("auto-restart", "on")
dev.poll(d, msgs.extend)
check("poll: a change from elsewhere", sorted(mine(msgs)), [("auto_restart", True), ("update_mode", "auto")])
msgs.clear()
# restart required comes from the state file
state_file(restart_required=True, in_progress=False, release_summary="installed, restart required")
dev.poll(d, msgs.extend)
check("poll: restart required on", mine(msgs), [("restart_required", True)])
msgs.clear()
dev.poll(d, msgs.extend)
check("poll: no change, no message", mine(msgs), [])
state_file(restart_required=False)
dev.poll(d, msgs.extend)
check("poll: restart required off", mine(msgs), [("restart_required", False)])

# ---- the Update entity after an install that needs a restart ----------------------------
# The versions stay as they are. Home Assistant writes a new state only when the title, the latest
# version or in_progress change, so the shim must push these. The notes are Markdown with newlines.
def upd(msgs):
    return [m for m in msgs if getattr(m, "key", None) == d.update.key]

LIST_NOTES = "Packages to install:\n\n- tsx-base (0.3.5-r0 -> 0.3.6-r0)\n- tsx-setup (0.3.5-r0 -> 0.3.6-r0)\n\nRestart needed after install."
DONE_NOTES = ("Installed. Restart the panel to finish the update.\n\n"
              "Press Install, or the Restart button, to restart the panel now.")
state_file(restart_required=False, in_progress=False, release_summary=LIST_NOTES, latest_version="0.3.6")
msgs = []; dev.poll(d, msgs.extend); msgs.clear()
m = d.update._state_msg()
check("update: the list as release notes, newlines kept", m.release_summary, LIST_NOTES)
check("update: the list has one package on each line", m.release_summary.count("\n- "), 2)
check("update: before the install: title, latest, in_progress",
      (m.title, m.latest_version, m.in_progress), ("TSX HOST packages", "0.3.6", False))
state_file(restart_required=False, in_progress=True, release_summary="Installing the packages. Do not switch the panel off.\n\n" + LIST_NOTES)
dev.poll(d, msgs.extend)
check("update: apk runs: pushes in_progress", [(m.in_progress, m.current_version) for m in upd(msgs)], [(True, "0.3.5")])
msgs.clear()
state_file(restart_required=True, in_progress=False, release_summary=DONE_NOTES,
           latest_version="0.3.6 (restart required)", title="Restart required to finish 0.3.6")
dev.poll(d, msgs.extend)
got = upd(msgs)
check("update: after the install the shim pushes a new state", len(got), 1)
m = got[0]
check("update: after the install: the versions stay, the latest says restart required",
      (m.current_version, m.latest_version, m.in_progress), ("0.3.5", "0.3.6 (restart required)", False))
check("update: after the install: title and notes", (m.title, m.release_summary),
      ("Restart required to finish 0.3.6", DONE_NOTES))
check("update: the notes start with the installed note", m.release_summary.splitlines()[0],
      "Installed. Restart the panel to finish the update.")
msgs.clear()
dev.poll(d, msgs.extend)
check("update: no change, no push", upd(msgs), [])
# after the restart
state_file(installed_version="0.3.6", latest_version="0.3.6", restart_required=False, release_summary="up to date",
           title="TSX HOST packages")
dev.poll(d, msgs.extend)
m = upd(msgs)[0]
check("update: after the restart", (m.current_version, m.latest_version, m.release_summary, m.title),
      ("0.3.6", "0.3.6", "up to date", "TSX HOST packages"))
sys.exit(1 if fails else 0)
PY
echo "PASS test-shim-update"
