#!/bin/sh
# Host test of the custom wake word models (ha/voice/shim/tsx_lva/wakewords.py)
# and of the folder option of tsx-voice-run:
#   - the folder: tsx-voice-run gives CUSTOM_WAKE_WORDS to LVA as one more
#     --wake-word-dir (default /data/wakewords, empty = off)
#   - the model check: good microWakeWord and openWakeWord models pass, each
#     kind of bad model fails with a reason
#   - the scan: the order of the folders, a custom model that replaces a
#     built-in one, the stop word, the skipped models, the models that did
#     not load before
#   - the debounce: a copy of a .json and its .tflite gives one update, with
#     inotify and with the stat poll, and the watcher survives a removed folder
#   - the update of the running satellite: the new list, the reload of a
#     changed model, the fallback to the default wake word, the reconnect of
#     Home Assistant (after the satellite is idle, two times after a fallback)
# The test needs no LVA, no network and no compiler. test-esphome-wakewords.sh
# runs the same code in the real LVA with a real ESPHome client.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/paths.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export PYTHONDONTWRITEBYTECODE=1
fail=0

# ---- the folder option of tsx-voice-run ------------------------------------
mkdir -p "$T/run"
printf 'PORT=6053\n' > "$T/voice.conf"
out=$(TSX_VOICE_CONF="$T/voice.conf" TSX_VOICE_RUN_CONF="$T/run/voice.conf" sh "$(P usr/local/bin/tsx-voice-run)" --print)
case " $out " in
*" --wake-word-dir /data/wakewords "*"TSX_VOICE_WAKEWORDS"*|*"TSX_VOICE_WAKEWORDS=/data/wakewords "*" --wake-word-dir /data/wakewords "*)
	echo "ok   tsx-voice-run: default folder /data/wakewords";;
*) echo "FAIL tsx-voice-run: no default folder: $out"; fail=1;;
esac
printf 'PORT=6053\nCUSTOM_WAKE_WORDS=/srv/ww\n' > "$T/voice.conf"
out=$(TSX_VOICE_CONF="$T/voice.conf" TSX_VOICE_RUN_CONF="$T/run/voice.conf" sh "$(P usr/local/bin/tsx-voice-run)" --print)
case " $out " in
*"TSX_VOICE_WAKEWORDS=/srv/ww "*" --wake-word-dir /srv/ww "*) echo "ok   tsx-voice-run: CUSTOM_WAKE_WORDS=/srv/ww";;
*) echo "FAIL tsx-voice-run: CUSTOM_WAKE_WORDS=/srv/ww: $out"; fail=1;;
esac
printf 'PORT=6053\nCUSTOM_WAKE_WORDS=\n' > "$T/voice.conf"
out=$(TSX_VOICE_WAKEWORDS=/inherited TSX_VOICE_CONF="$T/voice.conf" TSX_VOICE_RUN_CONF="$T/run/voice.conf" \
	sh "$(P usr/local/bin/tsx-voice-run)" --print)
case " $out " in
*"--wake-word-dir"*|*"/inherited"*) echo "FAIL tsx-voice-run: CUSTOM_WAKE_WORDS= still gives a folder: $out"; fail=1;;
*) echo "ok   tsx-voice-run: CUSTOM_WAKE_WORDS= turns the folder off";;
esac
grep -q 'checkpath -d -m 0755 -o root:root "$CUSTOM_WAKE_WORDS"' "$(P etc/init.d/tsx-voice)" \
	&& echo "ok   tsx-voice: makes the folder (root:root 0755)" || { echo "FAIL tsx-voice: no checkpath for the folder"; fail=1; }

# ---- the module --------------------------------------------------------------
python3 - "$HERE/ha/voice/shim" "$T" <<'PY' || fail=1
import json, logging, os, struct, sys, threading, time
shim, t = sys.argv[1:3]
sys.path.insert(0, shim)


class Capture(logging.Handler):
    def __init__(self):
        super().__init__()
        self.lines = []

    def emit(self, record):
        self.lines.append(record.getMessage())

    def has(self, text):
        return any(text in line for line in self.lines)


cap = Capture()
logging.getLogger("tsx_lva").addHandler(cap)
logging.getLogger("tsx_lva").setLevel(logging.DEBUG)
logging.getLogger("tsx_lva").propagate = False

from tsx_lva import wakewords as ww  # noqa: E402

fails = 0


def check(name, ok, detail=""):
    global fails
    if ok:
        print("ok  ", name)
    else:
        print("FAIL", name, detail)
        fails += 1


def tflite(size=200, offset=28, magic=b"TFL3"):
    return struct.pack("<I", offset) + magic + b"\0" * (size - 8)


def model(folder, wid, cfg=None, data=None, phrase=None, mtype="micro"):
    os.makedirs(folder, exist_ok=True)
    if cfg is None:
        cfg = {"type": mtype, "wake_word": phrase or wid.replace("_", " ").title(), "model": wid + ".tflite"}
        if mtype == "micro":
            cfg["micro"] = {"probability_cutoff": 0.85, "sliding_window_size": 5, "feature_step_size": 10}
        else:
            cfg["openWakeWord"] = {"probability_cutoff": 0.7}
    with open(os.path.join(folder, wid + ".json"), "w") as fobj:
        fobj.write(cfg if isinstance(cfg, str) else json.dumps(cfg))
    if data is not False:
        with open(os.path.join(folder, wid + ".tflite"), "wb") as fobj:
            fobj.write(data if data is not None else tflite())


# --- the model check -----------------------------------------------------
d = t + "/check"
# the two kinds of the stock models of LVA 1.1.15 (okay_nabu.json, openWakeWord/alexa_v0.1.json)
model(d, "okay_nabu", """{
  "type": "micro", "wake_word": "Okay Nabu", "author": "Kevin Ahrendt",
  "website": "https://www.kevinahrendt.com/", "model": "okay_nabu.tflite",
  "trained_languages": ["en","nl","fr","de","it","es","sv"], "version": 2,
  "micro": {"probability_cutoff": 0.85, "feature_step_size": 10, "sliding_window_size": 5,
            "tensor_arena_size": 37000, "minimum_esphome_version": "2024.7.0"}}""")
model(d, "alexa_v0.1", """{"type": "openWakeWord", "wake_word": "Alexa (OWW)",
  "model": "alexa_v0.1.tflite", "openWakeWord": {"probability_cutoff": 0.7}}""")
info, why = ww.check_model(d + "/okay_nabu.json")
check("check: stock microWakeWord model passes", why is None and info["type"] == "micro"
      and info["probability_cutoff"] == 0.85 and info["trained_languages"][0] == "en", why)
info, why = ww.check_model(d + "/alexa_v0.1.json")
check("check: stock openWakeWord model passes", why is None and info["type"] == "openWakeWord"
      and info["model_path"].name == "alexa_v0.1.tflite", why)

micro_ok = {"type": "micro", "wake_word": "X", "model": "x.tflite",
            "micro": {"probability_cutoff": 0.9, "sliding_window_size": 5}}
BAD = [
    ("invalid JSON", '{"type": "micro",', None, "not valid JSON"),
    ("not UTF-8", b"\xff\xfe".decode("latin-1"), None, None),
    ("a list, not an object", "[1, 2]", None, "one JSON object"),
    ("no type", dict(micro_ok, type=None), None, '"type" must be'),
    ("unknown type", dict(micro_ok, type="snowboy"), None, '"type" must be'),
    ("no wake_word", {k: v for k, v in micro_ok.items() if k != "wake_word"}, None, '"wake_word"'),
    ("empty wake_word", dict(micro_ok, wake_word="  "), None, '"wake_word"'),
    ("trained_languages not a list", dict(micro_ok, trained_languages="en"), None, "trained_languages"),
    ("model with another name", dict(micro_ok, model="y.tflite"), None, '"model" must be "x.tflite"'),
    ("model in another folder", dict(micro_ok, model="../x.tflite"), None, '"model" must be'),
    ("no micro object", {k: v for k, v in micro_ok.items() if k != "micro"}, None, 'no "probability_cutoff"'),
    ("no sliding_window_size", dict(micro_ok, micro={"probability_cutoff": 0.9}), None, "sliding_window_size"),
    ("sliding_window_size true", dict(micro_ok, micro={"probability_cutoff": 0.9, "sliding_window_size": True}),
     None, "sliding_window_size"),
    ("probability_cutoff 0", dict(micro_ok, micro={"probability_cutoff": 0, "sliding_window_size": 5}), None,
     "probability_cutoff"),
    ("probability_cutoff text", dict(micro_ok, micro={"probability_cutoff": "high", "sliding_window_size": 5}),
     None, "probability_cutoff"),
    ("model file missing", micro_ok, False, "x.tflite is missing"),
    ("model file too small", micro_ok, b"\0" * 8, "bytes. A model has"),
    ("no TFL3 header", micro_ok, tflite(magic=b"ABCD"), "not a TensorFlow Lite model"),
    ("root offset after the end", micro_ok, tflite(offset=10_000), "not a TensorFlow Lite model"),
]
for name, cfg, data, want in BAD:
    folder = f"{t}/bad-{BAD.index((name, cfg, data, want))}"
    if name == "not UTF-8":
        os.makedirs(folder)
        open(folder + "/x.json", "wb").write(b'{"type": "\xff"}')
        open(folder + "/x.tflite", "wb").write(tflite())
    else:
        model(folder, "x", cfg, data)
    info, why = ww.check_model(folder + "/x.json")
    check(f"check: {name} fails", info is None and why and (want is None or want in why), why)
model(t + "/big", "x", micro_ok, b"")
with open(t + "/big/x.tflite", "wb") as fobj:
    fobj.write(tflite())
    fobj.truncate(ww.MAX_TFLITE + 1)
info, why = ww.check_model(t + "/big/x.json")
check("check: model file above 8 MiB fails", info is None and "bytes" in why, why)
model(t + "/name", "my word", dict(micro_ok, model="my word.tflite"))
info, why = ww.check_model(t + "/name/my word.json")
check("check: a space in the file name fails", info is None and "file name" in why, why)
os.makedirs(t + "/dirjson/x.json")
info, why = ww.check_model(t + "/dirjson/x.json")
check("check: a folder named x.json fails", info is None and "regular file" in why, why)
if os.getuid() != 0:
    model(t + "/perm", "x", micro_ok)
    os.chmod(t + "/perm/x.json", 0)
    info, why = ww.check_model(t + "/perm/x.json")
    check("check: an unreadable .json fails", info is None and "cannot read" in why, why)

# --- the scan --------------------------------------------------------------
B, C, O = t + "/builtin", t + "/custom", t + "/builtin/openWakeWord"
model(B, "okay_nabu", phrase="Okay Nabu")
model(B, "hey_jarvis", phrase="Hey Jarvis")
model(B, "stop", phrase="Stop")
model(O, "hey_jarvis_v0.1", mtype="openWakeWord", phrase="Hey Jarvis (OWW)")
model(C, "my_word", phrase="My Word")
model(C, "hey_jarvis", phrase="Hey Jarvis Custom")
model(C, "stop", phrase="Stop")
model(C, "broken", '{"type": ')
model(C, "same_text", phrase="okay nabu")
cap.lines.clear()
found = ww.scan([B, C, O, t + "/missing"], "stop", C)
check("scan: the ids", sorted(found) == ["hey_jarvis", "hey_jarvis_v0.1", "my_word", "okay_nabu", "same_text"],
      sorted(found))
check("scan: a custom model replaces a built-in one", found["hey_jarvis"]["wake_word"] == "Hey Jarvis Custom"
      and cap.has("replaces the built-in model hey_jarvis"))
check("scan: no stop word, a log line for the custom stop.json", "stop" not in found
      and cap.has("is the name of the stop word model"))
check("scan: the bad model is skipped with a reason", cap.has("broken.json skipped: the .json file is not valid JSON"))
check("scan: a warning for the same text", cap.has("have the same text"))
check("scan: no log line for a missing folder", not cap.has("missing"))
reported = set()
ww.scan([B, C, O], "stop", C, reported=reported)
cap.lines.clear()
ww.scan([B, C, O], "stop", C, reported=reported)
check("scan: a kept set of reported problems: no second log line", not cap.has("broken.json"), cap.lines)
model(C, "broken", '{"type": "micr')
ww.scan([B, C, O], "stop", C, reported=reported)
check("scan: ... until the file changes", cap.has("broken.json skipped"), cap.lines)
sig = found["my_word"]["sig"]
found = ww.scan([B, C], "stop", C, bad={"my_word": sig})
check("scan: a model that did not load is skipped", "my_word" not in found and cap.has("did not load before"))
found = ww.scan([B, C], "stop", C, bad={"my_word": [1, 2, 3, 4]})
check("scan: ... until its files change", "my_word" in found)

# --- the debounce --------------------------------------------------------
deb = ww.Debouncer(3.0)
deb.event(0.0)
deb.event(1.0)
deb.event(2.0)
check("debounce: not due 2.9 s after the last change", not deb.due(4.9))
check("debounce: due 3 s after the last change", deb.due(5.0) and deb.take() is False and not deb.pending)
deb.event(10.0, forced=True)
deb.event(11.0)
check("debounce: a forced update stays forced", deb.due(14.0) and deb.take() is True)


def watch_test(label, use_inotify):
    folder = f"{t}/watch-{label}"
    os.makedirs(folder)
    fired = []
    w = ww.Watcher(folder, lambda forced: fired.append((time.monotonic(), forced)), quiet=0.5, poll=0.2,
                   use_inotify=use_inotify)
    stop = threading.Event()

    def loop():
        while not stop.is_set():
            w.step()

    threading.Thread(target=loop, daemon=True).start()
    time.sleep(0.3)
    check(f"watch ({label}): mode", w.mode == ("inotify" if use_inotify else "poll"), w.mode)

    def wait_fires(count, timeout=4.0):
        end = time.monotonic() + timeout
        while time.monotonic() < end and len(fired) < count:
            time.sleep(0.05)
        time.sleep(1.2)  # no second update after the first one
        return len(fired)

    # scp writes the .json, then the .tflite in parts
    with open(folder + "/new_word.json", "w") as fobj:
        json.dump(dict(micro_ok, model="new_word.tflite"), fobj)
    time.sleep(0.1)
    with open(folder + "/new_word.tflite", "wb") as fobj:
        for _ in range(3):
            fobj.write(b"\0" * 1000)
            fobj.flush()
            time.sleep(0.1)
    check(f"watch ({label}): a copy of two files gives one update", wait_fires(1) == 1, fired)
    os.remove(folder + "/new_word.json")
    os.remove(folder + "/new_word.tflite")
    check(f"watch ({label}): a removal of two files gives one update", wait_fires(2) == 2, fired)
    w.kick()
    check(f"watch ({label}): kick gives one forced update", wait_fires(3) == 3 and fired[-1][1] is True, fired)
    os.rmdir(folder)
    wait_fires(4)
    os.makedirs(folder)
    model(folder, "back")
    n = wait_fires(5)
    check(f"watch ({label}): a removed and new folder gives updates", n == 5, fired)
    if use_inotify:
        model(folder, "back2")
        check(f"watch ({label}): inotify is back after the new folder", wait_fires(6) == 6 and w.mode == "inotify",
              (w.mode, fired))
    stop.set()
    w.kick()


try:
    import ctypes
    have_inotify = hasattr(ctypes.CDLL(None), "inotify_init1")
except (OSError, AttributeError):
    have_inotify = False
if have_inotify:
    watch_test("inotify", True)
else:
    print("skip  watch (inotify): no inotify on this host")
watch_test("poll", False)

# --- the update of the running satellite -----------------------------------


class Loaded:
    def __init__(self, wid, gen):
        self.id, self.gen = wid, gen


class Avail:
    loads = []
    fail = set()

    def __init__(self, info):
        self.id, self.type, self.wake_word = info["id"], info["type"], info["wake_word"]
        self.trained_languages = info["trained_languages"]
        self.wake_word_path = info["json_path"] if info["type"] == "micro" else info["model_path"]
        self.probability_cutoff = info["probability_cutoff"]

    def load(self):
        return CUSTOM.guarded_load(Avail._load, self)

    @staticmethod
    def _load(self):
        Avail.loads.append(self.id)
        if self.id in Avail.fail:
            raise ValueError("bad model")
        return Loaded(self.id, len(Avail.loads))


def load_models(available, active_ids, default_id, preferred_type=None):
    """The fallback of LVA load_wake_models for an empty active list."""
    for wid in (default_id, "okay_nabu"):
        if wid in available:
            return {wid: available[wid].load()}, {wid}, True
    wid = next(iter(available))
    return {wid: available[wid].load()}, {wid}, True


class Transport:
    def __init__(self, conn):
        self.conn = conn

    def close(self):
        CLOSED.append(self.conn.name)
        self.conn._transport = None
        STATE.connections.remove(self.conn)


class Conn:
    def __init__(self, name):
        self.name = name
        self._transport = Transport(self)


class Player:
    is_playing = False


class Prefs:
    def __init__(self, ids):
        self.active_wake_words = ids


class State:
    def __init__(self):
        self.available_wake_words = {}
        self.wake_words = {}
        self.active_wake_words = set()
        self.stop_word = Loaded("stop", 0)
        self.preferences = Prefs([])
        self.saved = []
        self.connections = [Conn("ha")]
        self.satellite = type("Sat", (), {})()
        self.tts_player, self.music_player = Player(), Player()
        self.wake_words_changed = False

    def save_preferences(self):
        self.saved.append(list(self.preferences.active_wake_words))


class Loop:
    def __init__(self):
        self.later = []

    def call_soon_threadsafe(self, func, *args):
        func(*args)

    def call_later(self, delay, func, *args):
        self.later.append((delay, func, args))
        return object()  # the handle

    def run_later(self):
        jobs, self.later = self.later, []
        for _delay, func, args in jobs:
            func(*args)


CLOSED = []
B2, C2, R2 = t + "/b2", t + "/c2", t + "/run2"
os.makedirs(R2)
model(B2, "okay_nabu", phrase="Okay Nabu")
model(B2, "hey_jarvis", phrase="Hey Jarvis")
model(B2, "stop", phrase="Stop")
os.makedirs(C2)
CUSTOM = ww.Custom(folder=C2, run_dir=R2, make=Avail, load_models=load_models)
STATE = State()
STATE.available_wake_words = CUSTOM.startup_scan([B2, C2], "stop")
loaded, active, used = load_models(STATE.available_wake_words, [], "hey_jarvis")
CUSTOM.startup_models(STATE.available_wake_words, [], "hey_jarvis", None, (loaded, active, used))
STATE.wake_words, STATE.active_wake_words = loaded, set(active)
STATE.preferences.active_wake_words = ["hey_jarvis"]
LOOP = Loop()
CUSTOM.loop, CUSTOM.state = LOOP, STATE  # what attach() does, without the watcher thread
check("start: two wake words, the default hey_jarvis is active",
      sorted(STATE.available_wake_words) == ["hey_jarvis", "okay_nabu"] and STATE.active_wake_words == {"hey_jarvis"})


def change(forced=False):
    CUSTOM._on_change(forced)


# a bad model: the list does not change, no reconnect
model(C2, "broken", '{"type": "micro"')
change()
check("update: a bad model gives no reconnect", CLOSED == [] and "broken" not in STATE.available_wake_words)
# a new model: a new list, one reconnect
model(C2, "my_word", phrase="My Word")
change()
check("update: a new model is in the list", "my_word" in STATE.available_wake_words)
check("update: a new model gives one reconnect", CLOSED == ["ha"], CLOSED)
check("update: no second reconnect without a fallback", not CUSTOM._second_refresh)
STATE.connections = [Conn("ha")]
# Home Assistant selects it (what satellite.py does for VoiceAssistantSetConfiguration)
STATE.wake_words["my_word"] = STATE.available_wake_words["my_word"].load()
STATE.active_wake_words = {"my_word", "stop"}  # "stop" is active while a reply plays
STATE.preferences.active_wake_words = ["my_word", None]
check("load: no record is left after a good load", not os.path.exists(R2 + "/" + ww.BAD_FILE))
# the same model with new files: loaded again, no reconnect
time.sleep(0.01)
model(C2, "my_word", phrase="My Word", data=tflite(300))
gen = STATE.wake_words["my_word"].gen
change()
check("update: a changed active model is loaded again", STATE.wake_words["my_word"].gen != gen
      and STATE.active_wake_words == {"my_word", "stop"} and STATE.wake_words_changed)
check("update: a changed model with the same text gives no reconnect", CLOSED == ["ha"], CLOSED)
# the active model goes away: back to the default (WAKE_WORD=hey_jarvis)
STATE.satellite._pipeline_active = True
os.remove(C2 + "/my_word.json")
os.remove(C2 + "/my_word.tflite")
change()
check("fallback: back to WAKE_WORD", STATE.active_wake_words == {"hey_jarvis", "stop"}
      and "my_word" not in STATE.wake_words and "hey_jarvis" in STATE.wake_words, STATE.active_wake_words)
check("fallback: saved in the preferences", STATE.saved[-1] == ["hey_jarvis", None], STATE.saved)
check("fallback: logged", cap.has("the active wake word my_word is gone") and cap.has("back to the default hey_jarvis"))
check("busy: no reconnect during a conversation", CLOSED == ["ha"] and LOOP.later
      and cap.has("after the conversation"), CLOSED)
CUSTOM._refresh()
check("busy: a second change while busy adds no second timer", len(LOOP.later) == 1, LOOP.later)
STATE.satellite._pipeline_active = False
STATE.music_player.is_playing = True
LOOP.run_later()
check("busy: no reconnect during a playback", CLOSED == ["ha"] and len(LOOP.later) == 1, CLOSED)
STATE.music_player.is_playing = False
LOOP.run_later()
check("busy: the reconnect comes when the satellite is idle", CLOSED == ["ha", "ha"], CLOSED)
STATE.connections = [Conn("ha")]
CUSTOM.config_sent()
check("fallback: a second reconnect after Home Assistant read the list", LOOP.later and LOOP.later[0][0] == 2.0)
LOOP.run_later()
check("fallback: the second reconnect", CLOSED == ["ha", "ha", "ha"], CLOSED)
STATE.connections = [Conn("ha")]
CUSTOM.config_sent()
check("fallback: only two reconnects", not LOOP.later)
# two active models, one goes away: no fallback
model(C2, "word_a", phrase="Word A")
model(C2, "word_b", phrase="Word B")
change()
STATE.connections = [Conn("ha")]
for wid in ("word_a", "word_b"):
    STATE.wake_words[wid] = STATE.available_wake_words[wid].load()
STATE.active_wake_words = {"word_a", "word_b"}
STATE.preferences.active_wake_words = ["word_a", "word_b"]
os.remove(C2 + "/word_a.json")
change()
check("two active, one gone: the other stays, no fallback", STATE.active_wake_words == {"word_b"}
      and STATE.saved[-1] == [None, "word_b"] and not CUSTOM._second_refresh, (STATE.active_wake_words, STATE.saved))
# WAKE_WORD is gone too: okay_nabu
STATE.connections = [Conn("ha")]
CUSTOM.default_id = "my_word"
os.remove(C2 + "/word_b.json")
change()
check("fallback: okay_nabu when WAKE_WORD is gone too", STATE.active_wake_words == {"okay_nabu"}, STATE.active_wake_words)
# no connection: no reconnect, Home Assistant reads the list at its next connect
STATE.connections = []
n = len(CLOSED)
model(C2, "offline", phrase="Offline")
change()
check("no connection: no reconnect", len(CLOSED) == n and cap.has("It reads the new list when it connects"))
# a model that does not load: it leaves the list, a forced update
STATE.connections = [Conn("ha")]
model(C2, "fails", phrase="Fails")
change()
Avail.fail.add("fails")
CUSTOM.watcher = type("W", (), {"kick": lambda self: KICKS.append(1)})()
KICKS = []
try:
    STATE.available_wake_words["fails"].load()
    raised = False
except ValueError:
    raised = True
bad = json.load(open(R2 + "/" + ww.BAD_FILE))
check("load failure: the error goes on, the record stays, a forced update", raised and "fails" in bad and KICKS == [1])
change(forced=True)
check("load failure: the model leaves the list", "fails" not in STATE.available_wake_words
      and cap.has("fails.json skipped: it did not load before"))
# a crash during the load (the record stays): the next start skips the model
model(C2, "crash", phrase="Crash")
bad = json.load(open(R2 + "/" + ww.BAD_FILE))
bad["crash"] = ww.model_sig(C2, "crash")  # what guarded_load writes before the load
with open(R2 + "/" + ww.BAD_FILE, "w") as fobj:
    json.dump(bad, fobj)
c2 = ww.Custom(folder=C2, run_dir=R2, make=Avail, load_models=load_models)
start = c2.startup_scan([B2, C2], "stop")
check("crash: the next start skips the model", "crash" not in start and "fails" not in start)
time.sleep(0.01)
model(C2, "crash", phrase="Crash")  # copied again: new times
start = c2.startup_scan([B2, C2], "stop")
check("crash: a new copy of the files is tried again", "crash" in start)
check("crash: the record of the new copy is gone", "crash" not in c2.read_bad() and "fails" in c2.read_bad())
# the start with a saved wake word that is gone: a second reconnect after the first configuration
c3 = ww.Custom(folder=C2, run_dir=R2, make=Avail, load_models=load_models)
av = c3.startup_scan([B2, C2], "stop")
c3.startup_models(av, ["gone_word", None], "okay_nabu", None, ({}, {"okay_nabu"}, True))
c3.loop = Loop()
check("start: a saved wake word that is gone is logged", cap.has("the saved wake word gone_word is gone"))
c3.config_sent()
check("start: one reconnect after the first configuration", len(c3.loop.later) == 1)
print(f"{'PASS' if fails == 0 else 'FAIL'} test-shim-wakewords python ({fails} failed)")
sys.exit(1 if fails else 0)
PY

[ $fail = 0 ] && echo "PASS test-shim-wakewords" || echo "FAIL test-shim-wakewords"
exit $fail
