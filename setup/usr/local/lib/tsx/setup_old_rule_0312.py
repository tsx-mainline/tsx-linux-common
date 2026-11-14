"""setup_old_rule_0312: the rule of "configured" of tsx-setupd from
tsx-linux-common v0.3.0 to v0.3.12 (the stable channel before 0.3.13), kept
only for the move to the marker /data/tsx/setup-done (setup_old_rule.py asks
it next to the rule of 7aafeb2).

v0.3.0 ... v0.3.12 have the same code here. It differs from 7aafeb2 in two
places: in the mode "auto" the kiosk is on when /etc/kiosk.conf exists (not
the defaults file of tsx-kiosk), and the page URL comes from /etc/kiosk.conf
only (no layers). The code below is the code of v0.3.12, unchanged:
CONF_PATH, KIOSK_CONF_PATH, load_conf, _conf, KIOSK_MODE, kiosk_enabled,
has_url and is_configured_from. Do not change it (tests/test-setup-done.sh
compares it with the tag v0.3.12).
"""
import os
import re

CONF_PATH = os.environ.get("TSX_SETUP_CONF", "/etc/tsx/setup.conf")
KIOSK_CONF_PATH = os.environ.get("TSX_KIOSK_CONF", "/etc/kiosk.conf")


def load_conf(path):
    cfg = {}
    try:
        with open(path, "r", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k, v = k.strip(), v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                    v = v[1:-1]
                cfg[k] = v
    except OSError:
        pass
    return cfg


_conf = load_conf(CONF_PATH)
KIOSK_MODE = (os.environ.get("TSX_SETUP_KIOSK") or _conf.get("TSX_SETUP_KIOSK") or "auto").strip().lower()
if KIOSK_MODE not in ("auto", "on", "off"):
    KIOSK_MODE = "auto"


def kiosk_enabled():
    """True when the panel runs the browser kiosk: TSX_SETUP_KIOSK=on, or
    "auto" and /etc/kiosk.conf (the file of tsx-kiosk) exists."""
    if KIOSK_MODE == "auto":
        return os.path.exists(KIOSK_CONF_PATH)
    return KIOSK_MODE == "on"


def has_url(shown):
    """True if the kiosk has a URL: KIOSK_URL of panel.conf (shown is the
    output of tcfg_show), else the image default that the kiosk falls back
    to (kiosk-session: /etc/kiosk.conf, then the panel.conf override). An
    install with --kiosk-url and no panel.conf sets the URL only there."""
    v = shown.get("KIOSK_URL")
    if not (v and v.strip()):
        v = load_conf(KIOSK_CONF_PATH).get("KIOSK_URL")
    return bool(v and v.strip())


def is_configured_from(shown):
    """Is the panel configured? shown is the output of tcfg_show. With a
    kiosk, it needs a page URL. With no kiosk, panel.conf needs at least one
    key (a line of tcfg_show that is not a comment of tsx-config)."""
    if kiosk_enabled():
        return has_url(shown)
    return any(re.fullmatch(r"[A-Z][A-Z0-9_]*", k) for k in shown)
