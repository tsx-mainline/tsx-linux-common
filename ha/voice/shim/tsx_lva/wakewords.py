"""Custom wake word models for the voice satellite.

linux-voice-assistant (LVA) 1.1.15 reads its wake word list one time, at
the start (wake_word.find_available_wake_words). It reads each *.json file
of each --wake-word-dir with json.load and without error handling, so one
bad file stops the satellite. Home Assistant then gets the list in the
VoiceAssistantConfigurationResponse (satellite.py).

Home Assistant (esphome/assist_satellite.py, 2026.9) asks for that
configuration only in two cases: when its assist_satellite entity is added,
and after it sets the active wake words itself. The integration removes
the assist_satellite platform at each disconnect and adds it again at each
connect (esphome/manager.py on_disconnect and _on_connect). The wake word
select (esphome/select.py) takes its options from that configuration. So
only a new connection shows a new list in Home Assistant.

This module:

- checks each model before LVA sees it (check_model) and skips a bad one
  with a log line (scan),
- watches the custom folder (TSX_VOICE_WAKEWORDS) with inotify, or with a
  stat poll when inotify is not available (Watcher, Debouncer),
- puts the new list into the running satellite (Custom.apply): it reloads a
  changed active model, and it goes back to the default wake word when the
  active one is gone,
- closes the ESPHome API connection when the satellite is idle. Home
  Assistant connects again at once (an unexpected disconnect has no
  reconnect delay in aioesphomeapi) and reads the new list.

After a fallback to the default wake word, one connection is not enough.
The wake word select of Home Assistant keeps its option over a reconnect.
When that option is gone, the select shows "no wake word". Only a select
that shows "no wake word" takes the one active wake word of the device
(select.py async_satellite_config_updated). So after a fallback, the
satellite closes the connection a second time, after Home Assistant has
read the list.

The LVA parts (AvailableWakeWord, load_wake_models) come in as arguments, so
the host tests run this module without LVA.
"""

import asyncio
import ctypes
import json
import logging
import os
import re
import select
import stat
import struct
import threading
import time
from pathlib import Path

_LOGGER = logging.getLogger("tsx_lva.wakewords")

TYPES = ("micro", "openWakeWord")
MAX_JSON = 64 * 1024
MIN_TFLITE = 16
MAX_TFLITE = 8 * 1024 * 1024
MAX_PHRASE = 64
ID_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$")
QUIET = 3.0  # seconds without a change before the satellite reads the folder
POLL = 10.0  # seconds between two stat polls when inotify is not available
IDLE_RETRY = 5.0  # seconds between two idle checks before the reconnect
BAD_FILE = "wakeword-bad.json"

# inotify(7)
IN_MODIFY, IN_ATTRIB, IN_CLOSE_WRITE = 0x2, 0x4, 0x8
IN_MOVED_FROM, IN_MOVED_TO, IN_CREATE, IN_DELETE = 0x40, 0x80, 0x100, 0x200
IN_DELETE_SELF, IN_MOVE_SELF, IN_UNMOUNT, IN_IGNORED = 0x400, 0x800, 0x2000, 0x8000
IN_ONLYDIR = 0x01000000
WATCH_MASK = (IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO | IN_CREATE
              | IN_DELETE | IN_DELETE_SELF | IN_MOVE_SELF | IN_ONLYDIR)
WATCH_LOST = IN_DELETE_SELF | IN_MOVE_SELF | IN_UNMOUNT | IN_IGNORED


def _number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def check_model(json_path):
    """Check one model: the .json file and the .tflite file that it names.

    Returns (info, None) for a good model and (None, reason) for a bad one.
    info has the keys id, type, wake_word, trained_languages, json_path,
    model_path, probability_cutoff and sig (sizes and times of both files).
    The checks cover everything that makes LVA or Home Assistant fail on the
    model: the JSON, the fields that LVA reads, a model name that LVA can
    activate, and the size and header of the model file.
    """
    path = Path(json_path)
    wid = path.stem
    if not ID_RE.match(wid):
        return None, "the file name may use only letters, digits, '_', '.' and '-' (at most 64)"
    try:
        jst = path.stat()
    except OSError as err:
        return None, f"cannot read the .json file ({err.strerror})"
    if not stat.S_ISREG(jst.st_mode):
        return None, "the .json file is not a regular file"
    if jst.st_size > MAX_JSON:
        return None, f"the .json file has more than {MAX_JSON} bytes"
    try:
        with open(path, "r", encoding="utf-8") as fobj:
            cfg = json.load(fobj)
    except OSError as err:
        return None, f"cannot read the .json file ({err.strerror})"
    except ValueError as err:  # also UnicodeDecodeError
        return None, f"the .json file is not valid JSON ({err})"
    if not isinstance(cfg, dict):
        return None, "the .json file must hold one JSON object"
    mtype = cfg.get("type")
    if mtype not in TYPES:
        return None, f'"type" must be "micro" or "openWakeWord", not {mtype!r}'
    phrase = cfg.get("wake_word")
    if not isinstance(phrase, str) or not phrase.strip() or len(phrase) > MAX_PHRASE:
        return None, f'"wake_word" must be a text of 1 to {MAX_PHRASE} characters'
    langs = cfg.get("trained_languages", [])
    if not isinstance(langs, list) or not all(isinstance(lang, str) for lang in langs):
        return None, '"trained_languages" must be a list of texts'
    model = cfg.get("model")
    # LVA activates a model by the name of its .tflite file (the model id of
    # pymicro-wakeword and pyopen-wakeword) and lists it by the name of its
    # .json file. Different names give a model that never activates.
    if model != f"{wid}.tflite":
        return None, f'"model" must be "{wid}.tflite" (the name of the .json file), not {model!r}'
    section = cfg.get(mtype, {})
    if not isinstance(section, dict):
        return None, f'"{mtype}" must be a JSON object'
    if mtype == "micro":
        for key in ("probability_cutoff", "sliding_window_size"):
            if key not in section:
                return None, f'the "micro" object has no "{key}"'
        window = section["sliding_window_size"]
        if not isinstance(window, int) or isinstance(window, bool) or not 1 <= window <= 1000:
            return None, '"sliding_window_size" must be a whole number from 1 to 1000'
    cutoff = section.get("probability_cutoff", 0.7)
    if not _number(cutoff) or not 0 < cutoff <= 1:
        return None, '"probability_cutoff" must be a number above 0 and at most 1'
    tflite = path.parent / model
    try:
        tst = tflite.stat()
    except OSError:
        return None, f"the model file {model} is missing"
    if not stat.S_ISREG(tst.st_mode):
        return None, f"{model} is not a regular file"
    if not MIN_TFLITE <= tst.st_size <= MAX_TFLITE:
        return None, f"{model} has {tst.st_size} bytes. A model has {MIN_TFLITE} to {MAX_TFLITE} bytes"
    try:
        with open(tflite, "rb") as fobj:
            head = fobj.read(8)
    except OSError as err:
        return None, f"cannot read {model} ({err.strerror})"
    # A TensorFlow Lite model is a FlatBuffer: the offset of the root table,
    # then the file identifier "TFL3".
    if len(head) < 8 or head[4:8] != b"TFL3" or struct.unpack_from("<I", head)[0] >= tst.st_size:
        return None, f"{model} is not a TensorFlow Lite model"
    return {
        "id": wid,
        "type": mtype,
        "wake_word": phrase,
        "trained_languages": list(langs),
        "json_path": path,
        "model_path": tflite,
        "probability_cutoff": float(cutoff),
        "sig": [jst.st_size, jst.st_mtime_ns, tst.st_size, tst.st_mtime_ns],
    }, None


def model_sig(folder, wid):
    """The sig of check_model for the files of wid in folder, or None."""
    try:
        jst = os.stat(os.path.join(folder, wid + ".json"))
        tst = os.stat(os.path.join(folder, wid + ".tflite"))
    except OSError:
        return None
    return [jst.st_size, jst.st_mtime_ns, tst.st_size, tst.st_mtime_ns]


def dir_signature(folder):
    """Names, sizes, times and modes of the .json and .tflite files in folder.
    None when the folder cannot be read. Two equal values mean no change."""
    try:
        names = sorted(os.listdir(folder))
    except OSError:
        return None
    out = []
    for name in names:
        if name.endswith((".json", ".tflite")):
            try:
                fst = os.stat(os.path.join(folder, name))
            except OSError:
                continue
            out.append((name, fst.st_size, fst.st_mtime_ns, fst.st_mode))
    return tuple(out)


def _same_dir(one, two):
    try:
        return os.path.realpath(one) == os.path.realpath(two)
    except (OSError, TypeError, ValueError):
        return False


def _file_key(path):
    try:
        fst = os.stat(path)
        return (fst.st_size, fst.st_mtime_ns)
    except OSError:
        return None


def scan(dirs, stop_id, custom=None, bad=None, reported=None):
    """The checked wake word list of dirs, as LVA would build it.

    Returns {id: info} (see check_model) in the order of dirs. LVA skips the
    stop word model (stop_id), and so does this scan. A model of the custom
    folder replaces a built-in model with the same id. bad is {id: sig} of
    custom models that did not load: the scan skips them until their files
    change. reported is a set that the caller keeps between two scans: the
    scan then logs a problem only one time, until its file changes.
    """
    notes = []

    def note(level, path, msg, *args):
        notes.append((level, (msg % args, _file_key(path) if path else None), msg, args))

    found, customs = {}, {}
    for folder in dirs:
        folder = Path(folder)
        is_custom = custom is not None and _same_dir(folder, custom)
        try:
            names = sorted(name for name in os.listdir(folder) if name.endswith(".json"))
        except OSError as err:
            if is_custom and os.path.exists(folder):
                note(logging.WARNING, None, "custom wake words: cannot read %s (%s)", folder, err.strerror)
            continue
        for name in names:
            wid = name[:-len(".json")]
            path = folder / name
            if wid == stop_id:
                if is_custom:
                    note(logging.WARNING, path, "custom wake word %s skipped: %s is the name of the stop word model",
                         path, stop_id)
                continue
            info, why = check_model(path)
            if why:
                note(logging.WARNING, path, "wake word %s skipped: %s", path, why)
                continue
            if is_custom and bad and bad.get(wid) == info["sig"]:
                note(logging.WARNING, path, "custom wake word %s skipped: it did not load before. "
                     "Copy the two files again to try again", path)
                continue
            (customs if is_custom else found)[wid] = info
    for wid, info in customs.items():
        if wid in found:
            note(logging.INFO, info["json_path"], "custom wake word %s replaces the built-in model %s",
                 info["json_path"], wid)
        found[wid] = info
    by_phrase = {}
    for wid, info in found.items():
        by_phrase.setdefault(info["wake_word"].strip().lower(), []).append(wid)
    for ids in by_phrase.values():
        if len(ids) > 1:
            note(logging.WARNING, None, "the wake words %s have the same text %r. Home Assistant shows only one of them",
                 ", ".join(ids), found[ids[0]]["wake_word"])
    keys = set()
    for level, key, msg, args in notes:
        keys.add(key)
        if reported is None or key not in reported:
            _LOGGER.log(level, msg, *args)
    if reported is not None:
        reported.clear()
        reported.update(keys)
    return found


class Debouncer:
    """One update after a burst of changes: due QUIET seconds after the last
    change. The caller gives the time, so a test can step it."""

    def __init__(self, quiet=QUIET):
        self.quiet = quiet
        self.due_at = None
        self.forced = False

    @property
    def pending(self):
        return self.due_at is not None

    def event(self, now, forced=False):
        self.due_at = now + self.quiet
        self.forced = self.forced or forced

    def due(self, now):
        return self.due_at is not None and now >= self.due_at

    def take(self):
        """Clear the pending update. Returns True when it was forced."""
        forced, self.due_at, self.forced = self.forced, None, False
        return forced


class Watcher(threading.Thread):
    """Calls fire(forced) one time after each burst of changes in folder.

    It uses inotify (through ctypes and the C library) when it can, else a
    stat poll every POLL seconds. When the folder goes away, it polls until
    the folder is back. kick() asks for one update, also without a change.
    """

    def __init__(self, folder, fire, quiet=QUIET, poll=POLL, use_inotify=True):
        super().__init__(name="tsx-wakewords", daemon=True)
        self.folder = str(folder)
        self.fire = fire
        self.poll = poll
        self.use_inotify = use_inotify
        self.deb = Debouncer(quiet)
        self.seen = dir_signature(self.folder)
        self.mode = None
        self._fd = None
        self._libc = None
        self._rd, self._wr = os.pipe()

    def kick(self):
        try:
            os.write(self._wr, b"k")
        except OSError:
            pass

    def _say(self, mode, detail=""):
        if mode != self.mode:
            self.mode = mode
            _LOGGER.info("custom wake words: watching %s (%s%s)", self.folder, mode, detail)

    def _start_inotify(self):
        if not os.path.isdir(self.folder):
            return
        try:
            if self._libc is None:
                self._libc = ctypes.CDLL(None, use_errno=True)
            fd = self._libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
            if fd < 0:
                raise OSError(ctypes.get_errno(), "inotify_init1")
            wd = self._libc.inotify_add_watch(fd, os.fsencode(self.folder), WATCH_MASK)
            if wd < 0:
                err = ctypes.get_errno()
                os.close(fd)
                raise OSError(err, "inotify_add_watch")
        except (OSError, AttributeError) as err:
            self.use_inotify = False
            self._say("poll", f" every {self.poll:g} s, no inotify: {err}")
            return
        self._fd = fd
        self._say("inotify")
        # A change between the last poll and the new watch
        sig = dir_signature(self.folder)
        if sig != self.seen:
            self.seen = sig
            self.deb.event(time.monotonic())

    def _stop_inotify(self):
        if self._fd is not None:
            try:
                os.close(self._fd)
            except OSError:
                pass
            self._fd = None
        self._say("poll", f" every {self.poll:g} s until the folder is back")

    def _drain(self):
        """Read the pending events. Returns True when the watch is gone."""
        lost = False
        while True:
            try:
                buf = os.read(self._fd, 65536)
            except BlockingIOError:
                break
            except OSError:
                return True
            if not buf:
                break
            off = 0
            while off + 16 <= len(buf):
                _wd, mask, _cookie, length = struct.unpack_from("iIII", buf, off)
                off += 16 + length
                if mask & WATCH_LOST:
                    lost = True
        return lost

    def step(self):
        """One wait and one check. run() calls it in a loop."""
        if self._fd is None and self.use_inotify:
            self._start_inotify()
        if self._fd is None and self.mode is None:
            self._say("poll", f" every {self.poll:g} s")
        now = time.monotonic()
        timeout = None if self._fd is not None else self.poll
        if self.deb.pending:
            wait = max(0.0, self.deb.due_at - now)
            timeout = wait if timeout is None else min(timeout, wait)
        fds = [self._rd] + ([self._fd] if self._fd is not None else [])
        ready, _, _ = select.select(fds, [], [], timeout)
        now = time.monotonic()
        if self._rd in ready:
            os.read(self._rd, 512)
            self.deb.event(now, forced=True)
        if self._fd is not None and self._fd in ready:
            lost = self._drain()
            self.deb.event(now)
            if lost:
                self._stop_inotify()
        if self._fd is None:
            sig = dir_signature(self.folder)
            if sig != self.seen:
                self.seen = sig
                self.deb.event(now)
        if self.deb.due(now):
            forced = self.deb.take()
            self.seen = dir_signature(self.folder)
            self.fire(forced)

    def run(self):
        while True:
            try:
                self.step()
            except Exception:  # noqa: BLE001 - the watcher must not die
                _LOGGER.warning("custom wake words: watcher error", exc_info=True)
                time.sleep(self.poll)


def busy(state):
    """Why the satellite is not idle (a conversation, a timer, a playback),
    or None. A closed connection would end any of these."""
    sat = getattr(state, "satellite", None)
    if sat is not None:
        if getattr(sat, "_pipeline_active", False) or getattr(sat, "_is_streaming_audio", False):
            return "conversation"
        if getattr(sat, "_timer_finished", False):
            return "timer"
    for name in ("tts_player", "music_player"):
        player = getattr(state, name, None)
        try:
            if player is not None and player.is_playing:
                return "playback"
        except Exception:  # noqa: BLE001 - a player without a state is idle
            pass
    return None


def ha_view(available):
    """What Home Assistant gets of the list: id, text and languages."""
    return sorted((w.id, w.wake_word, tuple(w.trained_languages)) for w in available.values())


class Custom:
    """The custom wake word folder in the running satellite.

    make(info) builds an LVA AvailableWakeWord. load_models is the LVA
    function load_wake_models (for the fallback to the default wake word).
    """

    def __init__(self, folder=None, run_dir=None, make=None, load_models=None,
                 quiet=QUIET, poll=POLL, use_inotify=True):
        self.folder = folder or None
        self.run_dir = Path(run_dir) if run_dir else None
        self.make = make
        self.load_models = load_models
        self.quiet, self.poll, self.use_inotify = quiet, poll, use_inotify
        self.dirs = None
        self.stop_id = "stop"
        self.default_id = "okay_nabu"
        self.preferred_type = None
        self.sigs = {}
        self.state = None
        self.loop = None
        self.watcher = None
        self.last_dir_sig = None
        self._kick_early = False
        self._bad_lock = threading.Lock()
        self._second_refresh = False
        self._reported = set()
        self._refresh_pending = False
        self._wait_logged = False
        self._retry = None

    # --- the list -----------------------------------------------------------
    def is_custom(self, path):
        return self.folder is not None and path is not None and _same_dir(Path(path).parent, self.folder)

    def _bad_path(self):
        return self.run_dir / BAD_FILE if self.run_dir else None

    def read_bad(self):
        path = self._bad_path()
        if path is None:
            return {}
        try:
            with open(path, "r", encoding="utf-8") as fobj:
                data = json.load(fobj)
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def _write_bad(self, bad):
        path = self._bad_path()
        if path is None:
            return
        try:
            if bad:
                tmp = path.with_name(path.name + ".tmp")
                with open(tmp, "w", encoding="utf-8") as fobj:
                    json.dump(bad, fobj)
                os.replace(tmp, path)
            else:
                path.unlink(missing_ok=True)
        except OSError as err:
            _LOGGER.debug("custom wake words: cannot write %s: %s", path, err)

    def scan(self):
        """The checked list for self.dirs: ({id: AvailableWakeWord}, {id: sig})."""
        with self._bad_lock:
            bad = self.read_bad()
            if bad and self.folder:
                # Forget the entries whose files changed or went away
                keep = {wid: sig for wid, sig in bad.items() if model_sig(self.folder, wid) == sig}
                if keep != bad:
                    self._write_bad(keep)
                bad = keep
        found = scan(self.dirs, self.stop_id, self.folder, bad, self._reported)
        return {wid: self.make(info) for wid, info in found.items()}, {wid: info["sig"] for wid, info in found.items()}

    def startup_scan(self, dirs, stop_id):
        """Stands in for LVA find_available_wake_words at the start."""
        self.dirs = [Path(d) for d in dirs]
        self.stop_id = stop_id
        if self.folder:
            self.last_dir_sig = dir_signature(self.folder)
            names = [str(d) for d in self.dirs]
            _LOGGER.info("custom wake words: folder %s (%s)", self.folder,
                         "in the list" if any(_same_dir(d, self.folder) for d in self.dirs) else
                         "NOT in the --wake-word-dir list " + ", ".join(names))
        available, self.sigs = self.scan()
        _LOGGER.info("wake words: %s", ", ".join(sorted(available)) or "none")
        return available

    # --- the guard for a model that stops the satellite ---------------------
    def guarded_load(self, orig, model):
        """Load model with orig(model). For a custom model, a record in
        BAD_FILE (in /run, kept over a restart of the service) covers the
        load. When the load stops the process (a crash in TensorFlow Lite)
        or fails, the record stays, and the next scan skips the model until
        its files change. This prevents a loop of crashes and restarts."""
        if not self.is_custom(getattr(model, "wake_word_path", None)):
            return orig(model)
        sig = model_sig(self.folder, model.id)
        if sig is None:
            return orig(model)
        with self._bad_lock:
            bad = self.read_bad()
            bad[model.id] = sig
            self._write_bad(bad)
        try:
            loaded = orig(model)
        except Exception as err:
            _LOGGER.error("custom wake word %s did not load (%s). It leaves the list", model.id, err)
            self.request_rescan()
            raise
        with self._bad_lock:
            bad = self.read_bad()
            bad.pop(model.id, None)
            self._write_bad(bad)
        return loaded

    def startup_models(self, available, active_ids, default_id, preferred_type, result):
        """Called after LVA load_wake_models at the start, with its result."""
        self.default_id, self.preferred_type = default_id, preferred_type
        missing = [wid for wid in active_ids or [] if wid and wid not in available]
        if missing:
            _LOGGER.warning("the saved wake word %s is gone: active now %s", ", ".join(missing),
                            ", ".join(sorted(result[1])) or "none")
            # The select of Home Assistant can still show the gone wake word
            self._second_refresh = True

    def config_sent(self):
        """Event loop: the satellite answered a configuration request."""
        if self._second_refresh and self.loop is not None:
            self._second_refresh = False
            self.loop.call_later(2.0, self._refresh)

    def _refresh(self):
        self._refresh_pending = True
        if self._retry is None:  # else the waiting retry does it
            self._try_refresh()

    def request_rescan(self):
        if self.watcher is not None:
            self.watcher.kick()
        else:
            self._kick_early = True

    # --- the running satellite ----------------------------------------------
    def attach(self, state):
        """Called with the ServerState of LVA. Starts the watcher."""
        self.state = state
        try:
            self.loop = asyncio.get_running_loop()
        except RuntimeError:
            self.loop = None
        if not self.folder or self.dirs is None or self.loop is None or self.watcher is not None:
            return
        self.watcher = Watcher(self.folder, self._on_change, quiet=self.quiet, poll=self.poll,
                               use_inotify=self.use_inotify)
        # A change between the start scan and now
        if dir_signature(self.folder) != self.last_dir_sig or self._kick_early:
            self.watcher.kick()
        self.watcher.start()

    def _on_change(self, forced):
        """Watcher thread: read the folder and hand the list to the loop."""
        sig = dir_signature(self.folder)
        if sig == self.last_dir_sig and not forced:
            return
        self.last_dir_sig = sig
        available, sigs = self.scan()
        self.loop.call_soon_threadsafe(self.apply, available, sigs)

    def apply(self, available, sigs):
        """Event loop: put a new list into the satellite."""
        state = self.state
        old = state.available_wake_words
        changed = {wid for wid in set(old) | set(available)
                   if (wid in old) != (wid in available) or self.sigs.get(wid) != sigs.get(wid)
                   or (wid in old and wid in available
                       and (old[wid].wake_word_path, old[wid].type) != (available[wid].wake_word_path, available[wid].type))}
        if not changed:
            return
        stop_id = getattr(state.stop_word, "id", self.stop_id)
        was_active = set(state.active_wake_words) - {stop_id}
        # A new object, not a change in place: the audio thread can read the
        # old dict at this time.
        state.available_wake_words = available
        self.sigs = sigs
        loaded = dict(state.wake_words)
        reload = []
        for wid in list(loaded):
            if wid in changed:
                loaded.pop(wid)
                if wid in was_active and wid in available:
                    reload.append(wid)
        active = {wid for wid in was_active if wid in available}
        for wid in reload:
            try:
                loaded[wid] = available[wid].load()
                _LOGGER.info("wake word %s: the model changed and is loaded again", wid)
            except Exception as err:  # noqa: BLE001
                _LOGGER.error("wake word %s: the changed model did not load (%s)", wid, err)
                active.discard(wid)
        for wid in sorted(was_active - active):
            _LOGGER.warning("the active wake word %s is gone", wid)
        fallback = set()
        if was_active and not active:
            try:
                models, fallback, _used = self.load_models(available, [], self.default_id,
                                                           preferred_type=self.preferred_type)
                loaded.update(models)
                _LOGGER.warning("no active wake word is left: back to the default %s", ", ".join(sorted(fallback)))
                self._second_refresh = True
            except Exception as err:  # noqa: BLE001
                _LOGGER.error("no active wake word is left, and the default did not load (%s)", err)
            active |= fallback
        state.wake_words = loaded
        if active != was_active:
            state.active_wake_words.difference_update(was_active - active)
            state.active_wake_words.update(active - was_active)
            self._save_preferences(active, fallback)
        state.wake_words_changed = True
        added = sorted(set(available) - set(old))
        removed = sorted(set(old) - set(available))
        _LOGGER.info("wake words: the list changed (added: %s, removed: %s, changed: %s)",
                     ", ".join(added) or "none", ", ".join(removed) or "none",
                     ", ".join(sorted(changed - set(added) - set(removed))) or "none")
        if ha_view(old) != ha_view(available) or active != was_active:
            self._refresh()

    def _save_preferences(self, active, fallback):
        prefs = self.state.preferences
        slots = (list(prefs.active_wake_words or []) + [None, None])[:2]
        new = [wid if wid in active else None for wid in slots]
        for wid in sorted(fallback):
            if wid not in new and None in new:
                new[new.index(None)] = wid
        if new != slots:
            prefs.active_wake_words = new
            try:
                self.state.save_preferences()
            except OSError as err:
                _LOGGER.warning("wake words: cannot save the preferences (%s)", err)

    def _try_refresh(self):
        self._retry = None
        if not self._refresh_pending:
            return
        state = self.state
        conns = [conn for conn in list(state.connections) if getattr(conn, "_transport", None) is not None]
        if not conns:
            self._refresh_pending = False
            _LOGGER.info("wake words: Home Assistant is not connected. It reads the new list when it connects")
            return
        why = busy(state)
        if why:
            if not self._wait_logged:
                self._wait_logged = True
                _LOGGER.info("wake words: Home Assistant gets the new list after the %s", why)
            self._retry = self.loop.call_later(IDLE_RETRY, self._try_refresh)
            return
        self._refresh_pending = False
        self._wait_logged = False
        _LOGGER.info("wake words: closing the ESPHome API connection. Home Assistant connects again "
                     "and reads the new list")
        for conn in conns:
            transport = getattr(conn, "_transport", None)
            if transport is not None:
                transport.close()
