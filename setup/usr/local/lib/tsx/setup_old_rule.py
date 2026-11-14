"""setup_old_rule: the rules of "configured" of the earlier releases, kept
only for the move to the marker /data/tsx/setup-done (setup-state.sh of
tsx-base).

Up to tsx-linux-common 0.3.13_pre20261111 (commit 7aafeb2), tsx-setupd called
a panel configured by is_configured_from() below: with a kiosk, a page URL
(KIOSK_URL of panel.conf, else of the layers of kiosk.conf); with no kiosk, at
least one key in panel.conf. The functions below are that code, unchanged
(kiosk_conf_get, kiosk_enabled, has_url, is_configured_from, the read of
KIOSK_MODE, and the parse of `tsx-config show` of tcfg_show). Do not change
them: the migration must give the answer that the old code gave.

v0.3.0 to v0.3.12 (the stable channel before 0.3.13) had a rule that differs
in rare cases (setup_old_rule_0312.py, the code of v0.3.12, unchanged). A
panel can update from such a release straight to this one. So the answer is
"configured" when EITHER rule says configured: both can only add the marker,
and the stamp keeps a new /data of an installer out of the migration.

tsx-setup-helper runs it once per /data, as root, while the stamp
/data/tsx/setup-v2 is missing:

    tsx-config show 2>&1 | python3 -I setup_old_rule.py

stdin is the output of `tsx-config show`, stderr included (the helper gave
tsx-setupd the same text). The answer is one line on stdout with exit 0:
"configured" or "unconfigured" (the old rules). Anything else (an error, an
exception, a missing tsx_conf) is no answer, and the helper writes nothing.

Env (as tsx-setupd): TSX_SETUP_CONF, TSX_KIOSK_CONF, TSX_SETUP_KIOSK,
TSX_DEFAULTS_DIR (tsx_conf), TSX_BASE_LIB_DIR (the folder of tsx_conf.py).
"""
import os
import re
import sys

# tsx_conf (tsx-base): the layers of the settings files. On the panel it is in
# /usr/local/lib/tsx, next to this file. A checkout has it in base/. With
# python3 -I the folder of this file is not on sys.path: add it.
_here = os.path.dirname(os.path.realpath(__file__))
for _lib in (os.environ.get("TSX_BASE_LIB_DIR", "/usr/local/lib/tsx"), _here,
             os.path.join(_here, "..", "..", "..", "..", "..", "base", "usr", "local", "lib", "tsx")):
    if _lib not in sys.path:
        sys.path.append(_lib)
import tsx_conf  # noqa: E402
import setup_old_rule_0312  # noqa: E402

CONF_PATH = os.environ.get("TSX_SETUP_CONF", "/etc/tsx/setup.conf")
KIOSK_CONF_PATH = os.environ.get("TSX_KIOSK_CONF", "/etc/kiosk.conf")
_conf = tsx_conf.load("setup.conf", CONF_PATH)
KIOSK_MODE = (os.environ.get("TSX_SETUP_KIOSK") or _conf.get("TSX_SETUP_KIOSK") or "auto").strip().lower()
if KIOSK_MODE not in ("auto", "on", "off"):
    KIOSK_MODE = "auto"


# ---- the code of tsx-setupd at 7aafeb2, unchanged ----------------------------

def kiosk_conf_get(key):
    """KEY from the layers of kiosk.conf (the defaults and /etc/kiosk.conf), or None."""
    return tsx_conf.get("kiosk.conf", key, KIOSK_CONF_PATH, default=None)


def kiosk_enabled():
    """True when the panel runs the browser kiosk: TSX_SETUP_KIOSK=on, or
    "auto" and the defaults file of kiosk.conf (the package tsx-kiosk installs
    it) exists. The user file /etc/kiosk.conf can be missing or can stay behind."""
    if KIOSK_MODE == "auto":
        return tsx_conf.has_defaults("kiosk.conf")
    return KIOSK_MODE == "on"


def has_url(shown):
    """True if the kiosk has a URL: KIOSK_URL of panel.conf (shown is the
    output of tcfg_show), else the image default that the kiosk falls back
    to (kiosk-session: the defaults, /etc/kiosk.conf, then the panel.conf override). An
    install with --kiosk-url and no panel.conf sets the URL only there."""
    v = shown.get("KIOSK_URL")
    if not (v and v.strip()):
        v = kiosk_conf_get("KIOSK_URL")
    return bool(v and v.strip())


def is_configured_from(shown):
    """Is the panel configured? shown is the output of tcfg_show. With a
    kiosk, it needs a page URL. With no kiosk, panel.conf needs at least one
    key (a line of tcfg_show that is not a comment of tsx-config)."""
    if kiosk_enabled():
        return has_url(shown)
    return any(re.fullmatch(r"[A-Z][A-Z0-9_]*", k) for k in shown)


def fields_of_show(text):
    """The parse of tcfg_show: text is the reply of tsx-setup-helper "show"
    (the lines of `tsx-config show 2>&1`, joined with \\1)."""
    fields = {}
    for line in text.replace("\x01", "\n").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            fields[k] = v
    return fields


def main():
    # The helper sent `printf '%s' "$(tsx-config show 2>&1)"` (no final
    # newline), and tsx-setupd took the text after "ok" with lstrip().
    raw = sys.stdin.buffer.read().decode(errors="replace")
    shown = fields_of_show(raw.rstrip("\n").lstrip())
    # the rule of 7aafeb2, or the rule of v0.3.0 ... v0.3.12 (the parse of
    # tcfg_show is the same in both)
    configured = is_configured_from(shown) or setup_old_rule_0312.is_configured_from(shown)
    sys.stdout.write("configured\n" if configured else "unconfigured\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
