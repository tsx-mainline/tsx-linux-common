"""The hardware facts of the panel: /run/tsx/hw.conf, written at boot by
the tsx-hw of the board (see the "Panel parts" docs of the board repository).
A missing file or key means that the part is there.

Test hooks: TSX_HW_CONF, else TSX_RUN_DIR/hw.conf.
"""

import os
import sys

# tsx_presence (tsx-base): the one rule that maps PRESENCE to a sensor kind.
# On the panel it is in /usr/local/lib/tsx. A checkout has it in base/.
for _lib in (os.environ.get("TSX_BASE_LIB_DIR", "/usr/local/lib/tsx"),
             os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "..", "..", "..",
                          "base", "usr", "local", "lib", "tsx")):
    if _lib not in sys.path:
        sys.path.append(_lib)
try:
    import tsx_presence  # noqa: E402  pylint: disable=wrong-import-position
except ImportError:  # a rootfs without the helper file keeps no, pir and tof (no warning)
    class tsx_presence:  # noqa: N801  pylint: disable=invalid-name,too-few-public-methods
        @staticmethod
        def kind(raw, warn=True):  # pylint: disable=unused-argument
            raw = (raw or "").strip()
            return raw if raw in ("no", "pir") else "tof"


def conf_path():
    return os.environ.get("TSX_HW_CONF", os.path.join(os.environ.get("TSX_RUN_DIR", "/run/tsx"), "hw.conf"))


def get(key, path=None):
    """The value of KEY in hw.conf, or "" if the file or the key is missing."""
    value = ""
    try:
        with open(path or conf_path(), "r", encoding="utf-8") as fobj:
            for line in fobj:
                line = line.strip()
                if line.startswith(key + "="):
                    value = line.split("=", 1)[1].strip()
    except OSError:
        pass
    return value


def present(part, path=None):
    """False only when hw.conf says PART=no (for example MIC or BT)."""
    return get(part, path) != "no"


def reason(path=None):
    return get("REASON", path) or "unknown reason"


def reason_tail(path=None):
    """The REASON text of hw.conf as " (TEXT)" for the end of a message about
    a missing part. A panel with no REASON gets "" (a short message)."""
    text = get("REASON", path)
    return " (%s)" % text if text else ""


def presence_kind(path=None):
    """The kind of the presence sensor: "no", "tof" or "pir" (PRESENCE of
    hw.conf, see tsx_presence). A missing key is "tof"."""
    return tsx_presence.kind(get("PRESENCE", path))
