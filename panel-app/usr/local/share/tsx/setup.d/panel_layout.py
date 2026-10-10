"""The layout editor of the panel app, as a plugin of the setup page
(package of the panel app).

tsx-setupd loads every *.py file in /usr/local/share/tsx/setup.d. This file
follows the contract that ha/usr/local/share/tsx/setup.d/ha.py describes. It
adds three things to the setup page:

  * A link to the editor page, GET /setup/layout. The page is the file
    layout-editor.html in ../panel-app (one HTML file with its CSS and its
    script, no external file).
  * The field "API encryption key" (the panel.conf key HA_API_KEY), with a
    button that makes a new key in the browser. The state API reports only
    that the key is set. The page never gets the stored key. This plugin owns
    the key only when no other plugin of the folder names it.
  * The API of the editor (all paths need the same authorization as the setup
    page: loopback, or a paired LAN session while the LAN window is open):

      GET  /setup/api/layout            the current layout and what the editor needs
      GET  /setup/api/layout/entities   the entities that the editor can suggest
      POST /setup/api/layout/check      {"layout": object} -> errors, warnings, placed cards
      POST /setup/api/layout/save       {"layout": object, "revision": text}
      POST /setup/api/layout/ha-token   {"url": text, "token": text}
      POST /setup/api/layout/ha-token-clear
      POST /setup/api/layout/ha-entities

GET /setup/api/layout answers:

  {"layout": object or null, "source": "user" | "board" | "none",
   "text": the raw text when the file does not parse (else absent),
   "icons": [names of icons.txt], "types": [...], "domains": {...},
   "type_keys": {...}, "theme_keys": [...], "limits": {...}, "defaults": {...},
   "entities": [{"entity_id", "name", "state", "source"}], "ha_token_set": bool,
   "revision": sha256 of the bytes of the file of the user, or ""}

The layout is the file of the user (/var/lib/tsx/panel-layout.json). Without
it, the layout is the default of the board (/etc/tsx/panel-layout.json), and
else the example layout of the panel app (source "none"). A save writes the
layout (JSON, 2 spaces, the key order of the editor) to layout.new in the
state folder of tsx-setupd and asks tsx-setup-helper to run
`tsx-layout-check --install`. The helper command is layout-save. A save is
refused (409) when the file of the user changed after the page loaded.

The entity picker has three sources, all without a general access to Home
Assistant: the entities of the layout; the entities that the panel app knows
(entities.json, which the app writes); and the optional full list from Home
Assistant (ha-entities.json, which `tsx-ha-entities` writes after the user
stored a URL and a long-lived access token with ha-token). tsx-setup-helper
keeps the token. The editor never gets it back.

Env overrides for host tests: TSX_PANEL_LAYOUT_FILE, TSX_PANEL_LAYOUT_BOARD,
TSX_PANEL_LAYOUT_EXAMPLE, TSX_LAYOUT_EDITOR_HTML, TSX_LAYOUT_CHECK_BIN,
TSX_ICON_FILE, TSX_PANEL_APP_ENTITIES, TSX_HA_ENTITIES_FILE, TSX_HA_TOKEN_FILE,
TSX_SETUP_STATE_DIR.
"""
import hashlib
import importlib.machinery
import importlib.util
import json
import os
import re
import threading

NAME = "panel_layout"

_HERE = os.path.dirname(os.path.abspath(__file__))
# The files of the panel app are in ../panel-app of the folder of the real file
_SHARE = os.path.normpath(os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "panel-app"))
LAYOUT_FILE = os.environ.get("TSX_PANEL_LAYOUT_FILE", "/var/lib/tsx/panel-layout.json")
BOARD_FILE = os.environ.get("TSX_PANEL_LAYOUT_BOARD", "/etc/tsx/panel-layout.json")
EXAMPLE_FILE = os.environ.get("TSX_PANEL_LAYOUT_EXAMPLE", os.path.join(_SHARE, "example-layout.json"))
EDITOR_HTML = os.environ.get("TSX_LAYOUT_EDITOR_HTML", os.path.join(_SHARE, "layout-editor.html"))
CHECK_BIN = os.environ.get("TSX_LAYOUT_CHECK_BIN", "/usr/local/bin/tsx-layout-check")
APP_ENTITIES_FILE = os.environ.get("TSX_PANEL_APP_ENTITIES", "/run/tsx/panel-app/entities.json")
HA_ENTITIES_FILE = os.environ.get("TSX_HA_ENTITIES_FILE", "/run/tsx/panel-app/ha-entities.json")
HA_TOKEN_FILE = os.environ.get("TSX_HA_TOKEN_FILE", "/var/lib/tsx/panel-app/ha-token")
STATE_DIR = os.environ.get("TSX_SETUP_STATE_DIR", "/run/tsx-setup")

MAX_FILE = 65536            # the largest layout file that the app and the helper accept
MAX_READ = 1048576          # the largest file that this plugin reads
MAX_ENTITIES = 5000
ENTITY_RE = re.compile(r"[a-z0-9_]+\.[a-z0-9_]+")
URL_RE = re.compile(r"https?://[^\s\"'\\]{1,300}")
TOKEN_RE = re.compile(r"[A-Za-z0-9._~+/=-]{10,2048}")
# The colors of the app when the theme has no value (layout.h of the component)
DEFAULT_THEME = {"background": "#101418", "card": "#2a3038", "card_on": "#c88a1e",
                 "text": "#f0f0f0", "text_dim": "#9aa4b0"}

_ctx = None
_save_lock = threading.Lock()
_checker_mod = None


def init(ctx):
    global _ctx
    _ctx = ctx


def _other_plugin_names(key):
    """Does another plugin of this folder name the panel.conf key? Then that
    plugin owns the field and this one adds none."""
    me = os.path.basename(__file__)
    try:
        names = sorted(os.listdir(_HERE))
    except OSError:
        return False
    for n in names:
        if n == me or not n.endswith(".py") or n.startswith("_"):
            continue
        try:
            with open(os.path.join(_HERE, n), encoding="utf-8", errors="replace") as f:
                if re.search(r"""["']%s["']""" % re.escape(key), f.read()):
                    return True
        except OSError:
            continue
    return False


_OWN_KEY = not _other_plugin_names("HA_API_KEY")
SIMPLE_KEYS = ["HA_API_KEY"] if _OWN_KEY else []
STATE_KEYS = SIMPLE_KEYS

_LINK = """
    <h2>Panel layout</h2>
    <div class="card">
      <a href="/setup/layout" style="display:block;text-align:center;text-decoration:none;box-sizing:border-box;
         min-height:52px;line-height:32px;font-size:1.05rem;padding:10px 20px;border-radius:10px;
         background:var(--accent);color:var(--accent-fg);font-weight:600">Edit the layout of the screen</a>
      <div class="hint">Choose the pages and the cards that the panel shows. Save the other settings of this page first: the editor is a page of its own.</div>
    </div>
"""
_KEY = """
    <div class="card">
      <label for="f-apikey">API encryption key</label>
      <div class="row">
        <input id="f-apikey" name="HA_API_KEY" type="text" autocomplete="off" spellcheck="false"
               style="flex:1;min-width:200px" placeholder="(the panel has no key)">
        <button type="button" class="secondary" id="apikey-new">Make a new key</button>
      </div>
      <div class="hint" id="apikey-note"></div>
      <div class="hint">Home Assistant needs the same key. In Home Assistant, open Settings, then Devices &amp; services.
      Open the ESPHome device of this panel and enter this key as the encryption key. Leave the field blank to keep the present key.</div>
    </div>
"""
HTML = {"details": _LINK + (_KEY if _OWN_KEY else "")}
JS = {}
if _OWN_KEY:
    JS = {
        "apply": """
    $("f-apikey").value = "";
    $("f-apikey").placeholder = fields.HA_API_KEY__set ? "(a key is set; leave blank to keep it)" : "(the panel has no key)";
    $("apikey-note").textContent = fields.HA_API_KEY__set ? "A key is set. The page never shows it." : "No key is set. The API of the panel is open without a key.";
""",
        "init": """
  $("apikey-new").addEventListener("click", function(){
    var bytes = new Uint8Array(32);
    crypto.getRandomValues(bytes);
    var raw = "";
    for (var i = 0; i < bytes.length; i++) raw += String.fromCharCode(bytes[i]);
    $("f-apikey").value = btoa(raw);
    $("f-apikey").focus();
    if ($("f-apikey").select) $("f-apikey").select();
  });
""",
    }


# ---- the layout checker (tsx-layout-check, a Python file with no .py suffix) ----

def _checker():
    """The module of tsx-layout-check, or None when it is not installed."""
    global _checker_mod
    if _checker_mod is None:
        try:
            loader = importlib.machinery.SourceFileLoader("tsx_layout_check", CHECK_BIN)
            spec = importlib.util.spec_from_loader("tsx_layout_check", loader)
            mod = importlib.util.module_from_spec(spec)
            loader.exec_module(mod)
            _checker_mod = mod
        except (OSError, ImportError, SyntaxError):
            return None
    return _checker_mod


def _icons(chk):
    path = os.environ.get("TSX_ICON_FILE", getattr(chk, "ICON_FILE", ""))
    names = chk.read_icons(path) if path else None
    return names


def _read(path, cap=MAX_READ):
    try:
        with open(path, "rb") as f:
            data = f.read(cap + 1)
    except OSError:
        return None
    return data if len(data) <= cap else None


def _json_file(path):
    raw = _read(path)
    if raw is None:
        return None
    try:
        return json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None


def _user_revision():
    raw = _read(LAYOUT_FILE)
    return hashlib.sha256(raw).hexdigest() if raw is not None else ""


def _current():
    """(layout or None, source, raw text or None, revision)."""
    for path, source in ((LAYOUT_FILE, "user"), (BOARD_FILE, "board"), (EXAMPLE_FILE, "none")):
        raw = _read(path)
        if raw is None:
            continue
        rev = hashlib.sha256(raw).hexdigest() if source == "user" else ""
        text = raw.decode("utf-8", errors="replace")
        try:
            layout = json.loads(text)
        except ValueError:
            layout = None
        if not isinstance(layout, dict):
            return None, source, text, rev
        return layout, source, None, rev
    return None, "none", None, ""


# ---- the entities that the editor suggests --------------------------------------

def _clean_entity(e, source):
    if not isinstance(e, dict):
        return None
    eid = e.get("entity_id")
    if not isinstance(eid, str) or not ENTITY_RE.fullmatch(eid):
        return None
    name, state = e.get("name"), e.get("state")
    return {"entity_id": eid,
            "name": name[:100] if isinstance(name, str) else "",
            "state": state[:100] if isinstance(state, str) else "",
            "source": source}


def _layout_entity_ids(layout):
    ids = []
    if isinstance(layout, dict) and isinstance(layout.get("pages"), list):
        for p in layout["pages"]:
            for c in (p.get("cards") if isinstance(p, dict) and isinstance(p.get("cards"), list) else []):
                e = c.get("entity_id") if isinstance(c, dict) else None
                if isinstance(e, str) and ENTITY_RE.fullmatch(e) and e not in ids:
                    ids.append(e)
    return ids


def _entities(layout):
    """The entities of the layout, of the panel app and of the full list from
    Home Assistant. The state of the app is the most recent one. The result
    is sorted by entity id and has at most MAX_ENTITIES entries."""
    found = {}
    ha = _json_file(HA_ENTITIES_FILE)
    for e in (ha if isinstance(ha, list) else []):
        c = _clean_entity(e, "ha")
        if c:
            found[c["entity_id"]] = c
    app = _json_file(APP_ENTITIES_FILE)
    for e in (app.get("entities", []) if isinstance(app, dict) and isinstance(app.get("entities"), list) else []):
        c = _clean_entity(e, "app")
        if not c:
            continue
        old = found.get(c["entity_id"])
        if old and not c["name"]:
            c["name"] = old["name"]
        found[c["entity_id"]] = c
    for eid in _layout_entity_ids(layout):
        found.setdefault(eid, {"entity_id": eid, "name": "", "state": "", "source": "layout"})
    return [found[k] for k in sorted(found)][:MAX_ENTITIES]


def _ha_token_set():
    return os.path.exists(HA_TOKEN_FILE)


# ---- the routes -------------------------------------------------------------------

def _gate(h, need_pairing_ok=False):
    """True when the request may go on. Else this function has answered."""
    if not h._loopback() and not _ctx.lan_allowed():
        h._send_json(403, {"error": "setup is not reachable over the network right now"})
        return False
    if not h._authorized():
        if need_pairing_ok:
            h._send_json(200, {"need_pairing": True})
        else:
            h._send_json(403, {"error": "not authorized"})
        return False
    return True


def _api_page(h):
    if not h._loopback() and not _ctx.lan_allowed():
        h._send_html(403, "<!doctype html><meta charset=utf-8><title>Panel layout</title>"
                          "<p>Setup is not available over the network right now. "
                          "Open the setup page on the panel first.</p>")
        return
    raw = _read(EDITOR_HTML, 4 * MAX_READ)
    if raw is None:
        h._send_html(500, "<!doctype html><meta charset=utf-8><p>The editor page is not installed.</p>")
        return
    h._send_html(200, raw.decode("utf-8"))


def _limits(chk):
    return {"max_pages": getattr(chk, "MAX_PAGES", 16), "max_cards": getattr(chk, "MAX_CARDS", 48),
            "max_grid": getattr(chk, "MAX_GRID", 12), "max_gap": 40, "max_precision": 6,
            "max_file_bytes": MAX_FILE}


def _api_layout(h):
    if not _gate(h, need_pairing_ok=True):
        return
    chk = _checker()
    layout, source, text, rev = _current()
    resp = {"layout": layout, "source": source, "revision": rev,
            "icons": [], "types": ["light", "switch", "scene", "script", "sensor", "weather", "clock"],
            "domains": {"light": "light", "scene": "scene", "script": "script", "weather": "weather"},
            "type_keys": {"sensor": ["attribute", "unit", "precision"], "clock": ["format", "date_format"]},
            "theme_keys": ["background", "card", "card_on", "text", "text_dim"],
            "limits": _limits(chk), "defaults": {"theme": DEFAULT_THEME, "grid": {"columns": 4, "rows": 3, "gap": 10}},
            "entities": _entities(layout), "ha_token_set": _ha_token_set(), "checker": chk is not None}
    if text is not None:
        resp["text"] = text
    if chk is not None:
        icons = _icons(chk)
        resp["icons"] = sorted(icons) if icons else []
        resp["types"] = list(chk.TYPES)
        resp["domains"] = dict(chk.NEEDS_DOMAIN)
        resp["type_keys"] = {k: sorted(v) for k, v in chk.TYPE_KEYS.items()}
        resp["theme_keys"] = list(chk.THEME_KEYS)
    h._send_json(200, resp)


def _api_entities(h):
    if not _gate(h):
        return
    layout, _source, _text, _rev = _current()
    h._send_json(200, {"entities": _entities(layout), "ha_token_set": _ha_token_set()})


def _placed(layout_in, layout_out, errors):
    """The cells of the cards as the app places them. The checker leaves out a
    card with an error, so this maps each card that is left to its place in
    the list of the layout (index, from 0)."""
    if layout_out is None:
        return []
    failed = set()
    for e in errors:
        m = re.match(r"page (\d+) card (\d+):", e)
        if m:
            failed.add((int(m.group(1)), int(m.group(2))))
    out = []
    pages_in = layout_in.get("pages", [])
    for pn, page in enumerate(layout_out["pages"], 1):
        cards_in = pages_in[pn - 1].get("cards", []) if isinstance(pages_in[pn - 1], dict) else []
        alive = [i for i in range(len(cards_in)) if (pn, i + 1) not in failed]
        cards = []
        if len(alive) == len(page["cards"]):
            for i, c in zip(alive, page["cards"]):
                cards.append({"index": i, "x": c["x"], "y": c["y"], "w": c["w"], "h": c["h"]})
        out.append({"name": page["name"], "columns": page["columns"], "rows": page["rows"], "cards": cards})
    return out


def _api_check(h, data):
    if not _gate(h):
        return
    layout = data.get("layout")
    if not isinstance(layout, dict):
        h._send_json(400, {"error": "the request has no layout object"})
        return
    chk = _checker()
    if chk is None:
        h._send_json(503, {"error": "no panel app on this panel"})
        return
    out, errors, warnings = chk.check_text(json.dumps(layout, ensure_ascii=False), _icons(chk))
    h._send_json(200, {"ok": not errors, "errors": errors, "warnings": warnings,
                       "placed": _placed(layout, out, errors)})


def _write_new(data):
    """layout.new in the state folder, mode 600, atomic."""
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    tmp = os.path.join(STATE_DIR, ".layout.new.tmp.%d" % os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.fchmod(fd, 0o600)
        os.write(fd, data)
    finally:
        os.close(fd)
    os.rename(tmp, os.path.join(STATE_DIR, "layout.new"))


def _api_save(h, data):
    if not _gate(h):
        return
    layout, revision = data.get("layout"), data.get("revision")
    if not isinstance(layout, dict) or not isinstance(revision, str):
        h._send_json(400, {"error": "the request needs a layout object and a revision"})
        return
    chk = _checker()
    if chk is None:
        h._send_json(503, {"error": "no panel app on this panel"})
        return
    with _save_lock:
        if revision != _user_revision():
            h._send_json(409, {"stale": True, "error": "The layout changed after this page loaded. "
                                                         "Nothing is saved. Reload the layout, then make your changes again."})
            return
        body = (json.dumps(layout, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
        if len(body) > MAX_FILE:
            h._send_json(400, {"errors": ["the layout file is larger than %d bytes" % MAX_FILE], "warnings": []})
            return
        _out, errors, warnings = chk.check_text(body.decode("utf-8"), _icons(chk))
        if errors:
            h._send_json(400, {"errors": errors, "warnings": warnings})
            return
        try:
            _write_new(body)
        except OSError as e:
            h._send_json(500, {"error": "could not write the layout: %s" % e.strerror})
            return
        ok, text = _ctx.helper_call("layout-save", 60)
        if not ok:
            try:
                os.unlink(os.path.join(STATE_DIR, "layout.new"))
            except OSError:
                pass
            h._send_json(502, {"error": text or "could not save the layout"})
            return
        h._send_json(200, {"ok": True, "warnings": warnings, "revision": _user_revision()})


def _api_ha_token(h, data):
    if not _gate(h):
        return
    url, token = data.get("url"), data.get("token")
    if not isinstance(url, str) or not URL_RE.fullmatch(url.strip()):
        h._send_json(400, {"error": "the Home Assistant URL must start with http:// or https:// and have no spaces"})
        return
    if not isinstance(token, str) or not TOKEN_RE.fullmatch(token.strip()):
        h._send_json(400, {"error": "that does not look like a long-lived access token"})
        return
    # The token goes only into the request line of the helper. This process
    # never logs it and never answers with it.
    ok, text = _ctx.helper_call("ha-token-set %s %s" % (url.strip().rstrip("/"), token.strip()))
    if not ok:
        h._send_json(502, {"error": "could not store the token"})
        return
    h._send_json(200, {"ok": True, "ha_token_set": True})


def _api_ha_token_clear(h, data):
    if not _gate(h):
        return
    ok, text = _ctx.helper_call("ha-token-clear")
    if not ok:
        h._send_json(502, {"error": text or "could not remove the token"})
        return
    h._send_json(200, {"ok": True, "ha_token_set": _ha_token_set()})


def _api_ha_entities(h, data):
    if not _gate(h):
        return
    ok, text = _ctx.helper_call("ha-entities", 30)
    if not ok:
        h._send_json(502, {"error": text or "could not read the entity list"})
        return
    try:
        count = int(text.split()[0])
    except (ValueError, IndexError):
        count = 0
    h._send_json(200, {"ok": True, "count": count})


GET_ROUTES = {
    "/setup/layout": _api_page,
    "/setup/api/layout": _api_layout,
    "/setup/api/layout/entities": _api_entities,
}
POST_ROUTES = {
    "/setup/api/layout/check": _api_check,
    "/setup/api/layout/save": _api_save,
    "/setup/api/layout/ha-token": _api_ha_token,
    "/setup/api/layout/ha-token-clear": _api_ha_token_clear,
    "/setup/api/layout/ha-entities": _api_ha_entities,
}
