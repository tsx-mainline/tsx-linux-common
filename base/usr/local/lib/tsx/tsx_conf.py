"""tsx_conf: read the layers of a settings file such as kiosk.conf.

The package ships the defaults in /usr/local/share/tsx/defaults (the folder
TSX_DEFAULTS_DIR replaces it). The user file in /etc holds only the keys that
the user changed. Package updates replace the defaults and never touch the
user file. The layers, a later one wins:

  1. the defaults file of the package
  2. the board file (when the setting has one)
  3. the user file
  4. the runtime file in /run/tsx (when the setting has one)

The shell version is conf.sh in the same folder, the C version is the header
tsx-conf.h. Keep all three the same. A file that is missing is not an error.

  layers(name, user, board=None, run=None)  -> the list of paths, in order
  load(name, user, board=None, run=None)    -> dict of KEY -> value
  get(name, key, user, board=None, run=None, default="")
  defaults_path(name)                       -> the path of the defaults file
  has_defaults(name)                        -> True when the package is there
  parse_file(path)                          -> dict of KEY -> value
  set_key(user, key, value)                 -> write KEY=value to the user
                                               file only
"""

import os
import re

_KEY = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def defaults_dir():
    return os.environ.get("TSX_DEFAULTS_DIR") or "/usr/local/share/tsx/defaults"


def defaults_path(name):
    return os.path.join(defaults_dir(), name)


def has_defaults(name):
    return os.path.exists(defaults_path(name))


def layers(name, user, board=None, run=None):
    return [p for p in (defaults_path(name), board, user, run) if p]


def _value(raw):
    """The value of a KEY=value line as the shell reads it: a quoted word
    loses the quotes, a trailing " #comment" goes away."""
    v = raw.strip()
    if v[:1] in ("'", '"'):
        end = v.find(v[0], 1)
        if end > 0:
            return v[1:end]
    cut = re.search(r"\s#", v)
    if cut:
        v = v[:cut.start()]
    return v.strip()


def parse_file(path):
    cfg = {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k = k.strip()
                if _KEY.match(k):
                    cfg[k] = _value(v)
    except OSError:
        pass
    return cfg


def load(name, user, board=None, run=None):
    cfg = {}
    for path in layers(name, user, board, run):
        cfg.update(parse_file(path))
    return cfg


def get(name, key, user, board=None, run=None, default=""):
    return load(name, user, board, run).get(key, default)


def set_key(user, key, value):
    """Set KEY=value in the user file. Make the file when it is missing and
    add the key when it is not there. Never copy the defaults into it."""
    if not _KEY.match(key):
        raise ValueError("bad key %r" % key)
    try:
        with open(user, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        mode = os.stat(user).st_mode & 0o7777
    except OSError:
        lines, mode = [], 0o644
    out, done = [], False
    for line in lines:
        if line.startswith(key + "="):
            if not done:
                out.append("%s=%s" % (key, value))
            done = True
        else:
            out.append(line)
    if not done:
        out.append("%s=%s" % (key, value))
    tmp = "%s.tmp.%d" % (user, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    os.chmod(tmp, mode)
    os.replace(tmp, user)
