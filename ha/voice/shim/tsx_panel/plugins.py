"""Plugins for the ESPHome device of the panel: the folder esphome.d.

A board package can add entities and API messages to the ESPHome device. It
ships one Python file in /usr/local/share/tsx/esphome.d. Both front ends load
the files: tsx-esphome (root, VOICE=off) and the voice satellite (user kiosk,
VOICE=on). Each front end loads each file once, when it starts, in name
order. docs/esphome.md "Plugins" has the contract.

A plugin file can define these names. All are optional:

  entities(server, key_for)   Returns a list of entities (ESPHomeEntity
                              objects, see entities.py). key_for(object_id)
                              gives the fixed key of an entity.
                              key_for.action(name) gives the key of a
                              user-defined action (keys.py). Use a new object
                              id for each entity.
  handle_message(conn, msg)   Called for each API message of a client, after
                              the Bluetooth proxy. Return True when the
                              plugin took the message. Take only a message
                              that no other code handles, for example the
                              request for an entity type that only the plugin
                              knows. To answer, call
                              conn.send_messages(msgs).
  connection_lost(conn)       Called when a client connection closes.

device.py adds the entities to the entity list. In each poll, it calls poll()
of each entity that has this method, as it does for its own sensors. An entity
sends its state when its _state attribute changed.

Trust: root owns the folder and each file, and the group and others cannot
write them. A file that fails this check is not loaded. A link is not loaded.
The voice satellite runs as user kiosk. A file that this user can write would
run as this user in every start of the satellite, and as root in every start
of tsx-esphome.

A plugin that fails to load gives one log line, and the device starts without
it. An error in a function of a plugin gives one log line. The first line of
a function has the details. The device keeps running.

Test hooks: TSX_ESPHOME_PLUGIN_DIR (the folder) and TSX_PLUGIN_OWNER_UID (the
user id that must own the folder and the files, default 0).
"""

import logging
import os
import re
import stat
import sys
import types

_LOGGER = logging.getLogger("tsx_panel.plugins")

DEFAULT_DIR = "/usr/local/share/tsx/esphome.d"

_LOADED = None      # the list of plugin modules, after the first load
_REPORTED = set()   # (plugin, function) pairs with a logged error


class _Refused(Exception):
    """A file or a folder that fails the trust check."""


def plugin_dir() -> str:
    return os.environ.get("TSX_ESPHOME_PLUGIN_DIR", DEFAULT_DIR)


def owner_uid() -> int:
    try:
        return int(os.environ.get("TSX_PLUGIN_OWNER_UID", "0"))
    except ValueError:
        return 0


def _check_owner(info, what: str, uid: int) -> None:
    if info.st_uid != uid:
        raise _Refused("%s is not owned by user %d" % (what, uid))
    if info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise _Refused("%s can be changed by its group or by others" % what)


def _read_trusted(path: str, uid: int) -> bytes:
    """The content of a plugin file. Opens the file once and checks the open
    file, so the file cannot change between the check and the read."""
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        fdesc = os.open(path, flags)
    except OSError as err:
        raise _Refused("cannot open it (%s)" % (err.strerror or err)) from err
    try:
        info = os.fstat(fdesc)
        if not stat.S_ISREG(info.st_mode):
            raise _Refused("it is not a regular file")
        _check_owner(info, "the file", uid)
        chunks = []
        while True:
            chunk = os.read(fdesc, 65536)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(fdesc)


def _run_module(stem: str, path: str, source: bytes):
    name = "tsx_esphome_plugin_" + re.sub(r"\W", "_", stem)
    mod = types.ModuleType(name)
    mod.__file__ = path
    sys.modules[name] = mod
    try:
        exec(compile(source, path, "exec"), mod.__dict__)  # pylint: disable=exec-used
    except BaseException:
        sys.modules.pop(name, None)
        raise
    return mod


def load(path=None) -> list:
    """Load the plugin files of the folder. Returns the modules. A missing
    folder gives no plugin and no log line."""
    path = path or plugin_dir()
    uid = owner_uid()
    try:
        info = os.stat(path)
    except FileNotFoundError:
        return []
    except OSError as err:
        _LOGGER.warning("esphome.d: no plugin loaded: cannot read %s: %s", path, err)
        return []
    try:
        if not stat.S_ISDIR(info.st_mode):
            raise _Refused("it is not a folder")
        _check_owner(info, "the folder", uid)
        names = sorted(n for n in os.listdir(path) if n.endswith(".py") and not n.startswith(("_", ".")))
    except (_Refused, OSError) as err:
        _LOGGER.warning("esphome.d: no plugin loaded: %s: %s", path, err)
        return []
    found = []
    for name in names:
        full = os.path.join(path, name)
        try:
            found.append(_run_module(name[:-3], full, _read_trusted(full, uid)))
        except (Exception, SystemExit) as err:  # noqa: BLE001 - a broken plugin must not stop the device
            _LOGGER.warning("esphome.d: plugin %s skipped: %s", name, err)
    return found


def loaded() -> list:
    """The plugin modules of this process. The first call loads them."""
    global _LOADED  # pylint: disable=global-statement
    if _LOADED is None:
        _LOADED = load()
        if _LOADED:
            _LOGGER.info("esphome.d: %s", ", ".join(names()))
    return _LOADED


def names() -> list:
    """The file names of the loaded plugins."""
    return [os.path.basename(getattr(m, "__file__", m.__name__)) for m in loaded()]


def reset() -> None:
    """Forget the loaded plugins, so that the next call loads them again. For
    tests."""
    global _LOADED  # pylint: disable=global-statement
    _LOADED = None
    _REPORTED.clear()


def _failed(mod, func: str) -> None:
    key = (mod.__name__, func)
    first = key not in _REPORTED
    _REPORTED.add(key)
    _LOGGER.warning("esphome.d: %s() of %s failed", func, getattr(mod, "__file__", mod.__name__), exc_info=first)


def entities(server, key_for) -> list:
    """The entities of all plugins, for build_entities() of device.py."""
    out = []
    for mod in loaded():
        func = getattr(mod, "entities", None)
        if not callable(func):
            continue
        try:
            got = list(func(server, key_for) or [])
        except Exception:  # noqa: BLE001 - one broken plugin must not stop the device
            _failed(mod, "entities")
            continue
        for entity in got:
            if hasattr(entity, "key") and callable(getattr(entity, "handle_message", None)):
                out.append(entity)
            else:
                _LOGGER.warning("esphome.d: %s gave an object that is no entity: %r", mod.__name__, entity)
    return out


def poll(entities_list) -> list:
    """The state messages of the plugin entities whose state changed. An
    entity without a poll() method is not polled."""
    msgs = []
    for entity in entities_list:
        func = getattr(entity, "poll", None)
        if not callable(func):
            continue
        before = getattr(entity, "_state", None)
        try:
            msg = func()
        except Exception:  # noqa: BLE001
            _LOGGER.warning("esphome.d: poll() of %s failed", getattr(entity, "object_id", entity), exc_info=True)
            continue
        if msg is not None and getattr(entity, "_state", None) != before:
            msgs.append(msg)
    return msgs


def handle_message(conn, msg) -> bool:
    """True when a plugin took the message."""
    for mod in loaded():
        func = getattr(mod, "handle_message", None)
        if not callable(func):
            continue
        try:
            if func(conn, msg):
                return True
        except Exception:  # noqa: BLE001
            _failed(mod, "handle_message")
    return False


def connection_lost(conn) -> None:
    for mod in loaded():
        func = getattr(mod, "connection_lost", None)
        if not callable(func):
            continue
        try:
            func(conn)
        except Exception:  # noqa: BLE001
            _failed(mod, "connection_lost")
