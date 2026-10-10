#!/bin/bash
# Host test of the script of the setup page (tsx-setupd with the plugin of
# tsx-ha). It runs the real page script in node, against a small fake DOM
# that this test builds from the real page HTML, and a fake fetch. The test
# covers:
#  - a checkbox shows the stored state at load time: checked and unchecked
#  - each field shows the stored value, also an empty one
#  - a save sends only the fields that the user changed, and the revision
#  - a disabled field (a setting that the panel cannot use) is never sent
#  - the refresh every 20 s reads only /setup/api/status and never changes a
#    field, also a field that the user changed and did not save
#  - a new revision in the refresh, or a 409 reply, shows the reload notice
#  - a panel with no kiosk hides the page URL and the blank timeout, and the
#    first save sends the time zone
# It needs node. Without node it prints SKIPPED.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/tests/lib/paths.sh"
. "$HERE/tests/lib/board.sh"
SETUPD=$(P usr/local/sbin/tsx-setupd)
PLUGINS=$(dirname "$(P usr/local/share/tsx/setup.d/ha.py)")
command -v node >/dev/null 2>&1 || { echo "SKIPPED test-setup-page: no node on this host"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIPPED test-setup-page: no python3 on this host"; exit 0; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# The page as tsx-setupd serves it, as a tree (tree.json) and its script
# (page.js). Importing tsx-setupd starts no server.
TSX_SETUP_CONF="$T/none.conf" TSX_RUN_DIR="$T/run" TSX_SETUP_NO_ZEROCONF=1 TSX_SETUP_PLUGIN_DIR="$PLUGINS" \
python3 - "$SETUPD" "$T" <<'PYEOF' || { echo "FAIL: could not build the page"; exit 1; }
import importlib.machinery, json, sys
from html.parser import HTMLParser
d = importlib.machinery.SourceFileLoader("setupd", sys.argv[1]).load_module()
out = sys.argv[2]
assert d.PLUGINS, "the plugin of tsx-ha did not load"
VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}

class Tree(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = {"tag": "#root", "attrs": {}, "text": "", "children": []}
        self.stack = [self.root]
        self.script, self.skip = [], None

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"):
            self.skip = tag
            return
        el = {"tag": tag, "attrs": {k: (v if v is not None else "") for k, v in attrs}, "text": "", "children": []}
        self.stack[-1]["children"].append(el)
        if tag not in VOID:
            self.stack.append(el)

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self.skip = None
            return
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i]["tag"] == tag:
                del self.stack[i:]
                break

    def handle_data(self, data):
        if self.skip == "script":
            self.script.append(data)
        elif self.skip is None:
            self.stack[-1]["text"] += data

t = Tree()
t.feed(d.PAGE)
json.dump(t.root, open(out + "/tree.json", "w"))
open(out + "/page.js", "w").write("".join(t.script))
PYEOF

cat > "$T/harness.js" <<'JSEOF'
"use strict";
const fs = require("fs");
const TREE = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const SCRIPT = fs.readFileSync(process.argv[3], "utf8");
let N = 0, F = 0;
function ok(cond, what) {
  if (cond) { N++; console.log("  ok: " + what); } else { F++; console.log("  FAIL: " + what); }
}

// ---- a small fake DOM: only what the page script uses ----
let ROOT = null;
class El {
  constructor(tag, attrs, text) {
    this.tag = tag; this.tagName = tag.toUpperCase();
    this.attrs = Object.assign({}, attrs || {});
    this._text = text || ""; this.children = []; this.parentElement = null;
    this.style = {}; this.listeners = {};
    this.id = this.attrs.id || ""; this.className = this.attrs.class || ""; this.name = this.attrs.name || "";
    this.type = (this.attrs.type || (tag === "select" ? "select-one" : tag)).toLowerCase();
    this.disabled = "disabled" in this.attrs;
    this._checked = "checked" in this.attrs;
    this.selected = "selected" in this.attrs;
    this.placeholder = this.attrs.placeholder || "";
    this._value = tag === "textarea" ? this._text : (this.attrs.value !== undefined ? this.attrs.value : "");
    this._noMatch = false;
  }
  get textContent() { return this._text + this.children.map(c => c.textContent).join(""); }
  set textContent(v) { this._text = String(v); this.children = []; }
  set innerHTML(v) { this._text = ""; this.children = []; this._noMatch = false; }
  optValue() { return this._valueSet ? this._value : (this.attrs.value !== undefined ? this.attrs.value : this.textContent); }
  options() { return this.descendants().filter(e => e.tag === "option"); }
  get value() {
    if (this.tag === "select") {
      const sel = this.options().filter(o => o.selected);
      if (sel.length) return sel[sel.length - 1].optValue();
      if (this._noMatch) return "";
      const o = this.options();
      return o.length ? o[0].optValue() : "";
    }
    if (this.tag === "option") return this.optValue();
    return this._value;
  }
  set value(v) {
    v = String(v);
    if (this.tag === "select") {
      let found = false;
      for (const o of this.options()) { o.selected = !found && o.optValue() === v; found = found || o.selected; }
      this._noMatch = !found;
      return;
    }
    this._value = v; this._valueSet = true;
  }
  get checked() { return this._checked; }
  set checked(v) {
    v = !!v;
    if (v && this.type === "radio" && this.name && ROOT) {
      for (const e of ROOT.querySelectorAll("input[name=" + this.name + "]")) if (e !== this) e._checked = false;
    }
    this._checked = v;
  }
  descendants() {
    const out = [];
    const walk = (e) => { for (const c of e.children) { out.push(c); walk(c); } };
    walk(this);
    return out;
  }
  appendChild(c) { c.parentElement = this; this.children.push(c); this._noMatch = false; return c; }
  addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); }
  fire(type) {
    const ev = { target: this, preventDefault() {} };
    for (const fn of this.listeners[type] || []) fn(ev);
  }
  matches(sel) { return matches(this, sel); }
  closest(sel) { for (let e = this; e; e = e.parentElement) if (e.tag !== "#root" && matches(e, sel)) return e; return null; }
  querySelectorAll(sel) { return this.descendants().filter(e => matches(e, sel)); }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
  scrollIntoView() {}
  focus() {}
}
// Compound selectors only (no combinators): tag, #id, .class, [attr], [attr=v], [attr="v"], :checked
function matches(e, sel) {
  let s = sel.trim(), m;
  while (s.length) {
    if ((m = s.match(/^[a-z][a-z0-9]*/))) { if (e.tag !== m[0]) return false; }
    else if ((m = s.match(/^#([\w-]+)/))) { if (e.id !== m[1]) return false; }
    else if ((m = s.match(/^\.([\w-]+)/))) { if (!e.className.split(/\s+/).includes(m[1])) return false; }
    else if ((m = s.match(/^\[([\w-]+)(?:=(?:"([^"]*)"|([^\]]*)))?\]/))) {
      if (!(m[1] in e.attrs)) return false;
      const want = m[2] !== undefined ? m[2] : m[3];
      if (want !== undefined && e.attrs[m[1]] !== want) return false;
    }
    else if ((m = s.match(/^:checked/))) { if (!(e.checked || e.selected)) return false; }
    else throw new Error("selector not supported by the fake DOM: " + sel);
    s = s.slice(m[0].length);
  }
  return true;
}
function build(node) {
  const e = new El(node.tag, node.attrs, node.text);
  for (const c of node.children) e.appendChild(build(c));
  return e;
}

// ---- one page load: a new DOM, a fake server, the real page script ----
function load(server) {
  ROOT = build(TREE);
  const root = ROOT;
  const calls = [];
  let tick = null, reloads = 0;
  const document = {
    getElementById: id => root.descendants().find(e => e.id === id) || null,
    querySelector: sel => root.querySelector(sel),
    querySelectorAll: sel => root.querySelectorAll(sel),
    createElement: tag => new El(tag, {}, ""),
  };
  const fetch = (path, opts) => {
    const body = opts && opts.body ? JSON.parse(opts.body) : undefined;
    calls.push({ path, method: (opts && opts.method) || "GET", body });
    let r = { status: 404, body: {} };
    if (path === "/setup/api/state") r = { status: 200, body: server.state };
    else if (path === "/setup/api/status") r = { status: 200, body: server.status };
    else if (path === "/setup/api/submit") r = server.submit || { status: 400, body: { errors: {} } };
    const copy = JSON.parse(JSON.stringify(r.body));
    return Promise.resolve({ status: r.status, json: () => Promise.resolve(copy) });
  };
  const setInterval = (fn, ms) => { if (ms === 20000) tick = fn; return 1; };
  const location = { reload: () => { reloads++; } };
  new Function("document", "fetch", "setInterval", "location", SCRIPT)(document, fetch, setInterval, location);
  const $ = id => document.getElementById(id);
  return {
    $, calls, server,
    tick: () => tick(),
    reloads: () => reloads,
    submit: () => { $("form").fire("submit"); },
    lastSubmit: () => { const c = calls.filter(c => c.path === "/setup/api/submit"); return c.length ? c[c.length - 1].body : null; },
  };
}
const settle = () => new Promise(r => setTimeout(r, 0));
async function flush() { for (let i = 0; i < 5; i++) await settle(); }
// equal as JSON, with the keys of each object in sorted order
const canon = v => Array.isArray(v) ? v.map(canon) : (v && typeof v === "object")
  ? Object.keys(v).sort().reduce((o, k) => { o[k] = canon(v[k]); return o; }, {}) : v;
const same = (a, b) => JSON.stringify(canon(a)) === JSON.stringify(canon(b));

function stateWith(fields, extra) {
  return Object.assign({
    need_pairing: false, configured: true, loopback: true, lan_allowed: false, window_seconds: 900,
    revision: "rev-1", fields: fields, tz_list: ["UTC", "America/Denver", "America/New_York"], unavailable: {},
    pairing_code: "111111", pairing_code_remaining: 800,
  }, extra || {});
}
const STORED = {
  KIOSK_URL: "https://ha.example.org", PANEL_NAME: "panel-b", TZ_NAME: "America/Denver", VOICE: "off",
  WAKE_WORD: "okay_nabu", BT_PROXY: "on", BLANK_TIMEOUT: "300", KERNEL_FLAVOR: "stable",
  HA_LOGIN_METHOD: "token", HA_TOKEN: null, HA_TOKEN__set: true, MQTT_HOST: "mq.example",
};

(async () => {
  console.log("== load: each field shows the stored value, the voice switch is off ==");
  let p = load({ state: stateWith(STORED), status: { need_pairing: false, revision: "rev-1", pairing_code: "111111", pairing_code_remaining: 800 } });
  await flush();
  const $ = p.$;
  ok($("form").style.display === "block", "the form shows");
  ok($("f-voice").checked === false, "VOICE=off: the voice checkbox is not checked");
  ok($("wake-wrap").style.display === "none", "VOICE=off: the wake word is hidden");
  ok($("f-url").value === "https://ha.example.org" && $("f-name").value === "panel-b", "the URL and the panel name show");
  ok($("f-blank").value === "300", "the blank timeout shows (300)");
  ok($("f-orient").value === "landscape", "no ORIENTATION: landscape shows");
  ok($("f-kernel").value === "stable" && $("f-tz").value === "America/Denver", "the kernel flavor and the time zone show");
  ok($("f-btproxy").value === "on", "BT_PROXY shows");
  ok($("f-mqtt-host").value === "mq.example" && $("f-mqtt-port").value === "", "MQTT host shows, the empty MQTT port is empty");
  ok(p.$("token-wrap").style.display === "block" && p.server && document_checked(p, "token"), "the token login method is checked");

  console.log("== save: only the changed fields and the revision ==");
  p.submit(); await flush();
  ok(same(p.lastSubmit(), { revision: "rev-1", fields: {} }), "no change: the page sends no field, only the revision: " + JSON.stringify(p.lastSubmit()));
  $("f-blank").value = "600";
  p.submit(); await flush();
  ok(same(p.lastSubmit().fields, { BLANK_TIMEOUT: "600" }), "one changed field: only BLANK_TIMEOUT is sent: " + JSON.stringify(p.lastSubmit().fields));
  $("f-voice").checked = true; $("f-voice").fire("change");
  p.submit(); await flush();
  ok(same(p.lastSubmit().fields, { BLANK_TIMEOUT: "600", VOICE: "on" }), "the voice switch turned on: VOICE=on is sent too: " + JSON.stringify(p.lastSubmit().fields));
  ok($("wake-wrap").style.display === "block", "the wake word shows when the switch is on");
  $("f-voice").checked = false; $("f-voice").fire("change");
  p.submit(); await flush();
  ok(same(p.lastSubmit().fields, { BLANK_TIMEOUT: "600" }), "the switch back to its stored state: VOICE is not sent");
  $("f-blank").value = "300";
  p.submit(); await flush();
  ok(same(p.lastSubmit().fields, {}), "a field changed back to the stored value is not sent");

  console.log("== the 20 s refresh: only the status, no field changes ==");
  $("f-blank").value = "450";                       // an edit that the user did not save
  p.server.state = stateWith(Object.assign({}, STORED, { BLANK_TIMEOUT: "999", VOICE: "on", PANEL_NAME: "other" }), { revision: "rev-1" });
  p.server.status = { need_pairing: false, revision: "rev-1", pairing_code: "222222", pairing_code_remaining: 700 };
  const before = p.calls.length;
  p.tick(); await flush();
  const paths = p.calls.slice(before).map(c => c.path);
  ok(same(paths, ["/setup/api/status"]), "the refresh asks only /setup/api/status: " + JSON.stringify(paths));
  ok($("f-blank").value === "450", "the unsaved edit of the blank timeout stays (450)");
  ok($("f-voice").checked === false && $("f-name").value === "panel-b", "the other fields keep their values");
  ok($("code-value").textContent === "222222", "the refresh shows the new pairing code");
  ok($("stale").style.display !== "block", "same revision: no reload notice");
  p.server.status = { need_pairing: false, revision: "rev-2", pairing_code: "222222", pairing_code_remaining: 680 };
  p.tick(); await flush();
  ok($("stale").style.display === "block", "a new revision in the refresh shows the reload notice");
  ok($("f-blank").value === "450" && $("f-voice").checked === false, "the fields still keep their values");
  p.submit(); await flush();
  ok(same(p.lastSubmit(), { revision: "rev-1", fields: { BLANK_TIMEOUT: "450" } }), "a save still sends the revision of the load (the server refuses it)");

  console.log("== a 409 reply shows the reload notice and the reload button works ==");
  p.server.submit = { status: 409, body: { stale: true, errors: { _revision: "The settings changed. Reload the page." } } };
  p.submit(); await flush();
  ok($("stale").style.display === "block" && $("stale-text").textContent === "The settings changed. Reload the page.", "409: the notice shows the text of the server");
  ok($("form").style.display === "block", "409: the form stays, with the edits of the user");
  $("reload-btn").fire("click");
  ok(p.reloads() === 1, "the reload button reloads the page");

  console.log("== a successful save: the form closes, the refresh stops ==");
  p.server.submit = { status: 200, body: { ok: true, changed: [], applied: false } };
  p.submit(); await flush();
  ok($("done").style.display === "block" && $("form").style.display === "none", "200: the done card shows");
  ok($("done-note").textContent === "No setting changed.", "200 with no change: the page says so");
  const n = p.calls.length; p.tick(); await flush();
  ok(p.calls.length === n, "after the save the refresh asks nothing");

  console.log("== VOICE=on: the checkbox is checked at load time ==");
  p = load({ state: stateWith(Object.assign({}, STORED, { VOICE: "on" })), status: {} });
  await flush();
  ok(p.$("f-voice").checked === true && p.$("wake-wrap").style.display === "block", "VOICE=on: checked, the wake word shows");
  ok(p.$("f-wake").value === "okay_nabu", "the wake word shows");
  p.submit(); await flush();
  ok(same(p.lastSubmit().fields, {}), "no change: no field is sent");

  console.log("== a setting that the panel cannot use is never sent ==");
  p = load({ state: stateWith(STORED, { unavailable: { VOICE: "no microphone on this panel", AUTO_BRIGHTNESS: "no ambient light sensor on this panel" } }), status: {} });
  await flush();
  ok(p.$("f-voice").disabled && p.$("f-wake").disabled && p.$("f-autobri").disabled, "VOICE, WAKE_WORD and AUTO_BRIGHTNESS are disabled");
  p.$("f-wake").value = "hey_jarvis"; p.$("f-autobri").value = "off";
  p.submit(); await flush();
  ok(same(p.lastSubmit().fields, {}), "changed values in disabled fields are not sent: " + JSON.stringify(p.lastSubmit().fields));

  console.log("== a new panel: the URL that the user types is sent, the login form is the default ==");
  p = load({ state: stateWith({}, { configured: false, revision: "rev-new" }), status: {} });
  await flush();
  ok(p.$("f-url").value === "" && document_checked(p, "form"), "empty URL, the login form is checked");
  ok(p.$("f-btproxy").value === "", "BT_PROXY shows the board default");
  p.$("f-url").value = "https://ha.example.org ";
  p.$("f-rootpw").value = "a-long-password";
  p.submit(); await flush();
  ok(same(p.lastSubmit(), { revision: "rev-new", fields: { KIOSK_URL: "https://ha.example.org", ROOT_PASSWORD: "a-long-password" } }), "only the URL and the root password are sent: " + JSON.stringify(p.lastSubmit()));

  console.log("== the login method: a change sends the method, a token alone sends the token ==");
  p = load({ state: stateWith(STORED), status: {} });
  await flush();
  p.$("f-token").value = "abcdefghijklmnopqrstuvwxyz0123";
  p.submit(); await flush();
  ok(same(p.lastSubmit().fields, { HA_TOKEN: "abcdefghijklmnopqrstuvwxyz0123" }), "a new token alone: only HA_TOKEN");
  p.$("f-token").value = "";
  p.$("form").querySelector('input[name=HA_LOGIN_METHOD][value="trusted"]').checked = true;
  p.submit(); await flush();
  ok(same(p.lastSubmit().fields, { HA_LOGIN_METHOD: "trusted" }), "another login method: only HA_LOGIN_METHOD");

  console.log("== a page that waits for the pairing loads its fields once ==");
  p = load({ state: { need_pairing: true, window_seconds: 900 }, status: {} });
  await flush();
  ok(p.$("gate").style.display === "block" && p.$("form").style.display !== "block", "need_pairing: the gate shows");
  p.server.state = stateWith(STORED, { loopback: false });
  p.tick(); await flush();
  ok(p.$("form").style.display === "block" && p.$("f-blank").value === "300", "after the pairing the refresh loads the fields");
  p.$("f-blank").value = "42";
  let k = p.calls.length; p.tick(); await flush();
  ok(same(p.calls.slice(k).map(c => c.path), ["/setup/api/status"]) && p.$("f-blank").value === "42", "then the refresh asks only the status and keeps the edit");

  console.log("== a panel with no kiosk: no page URL, no blank timeout, the first save sends the time zone ==");
  const bz = Intl.DateTimeFormat().resolvedOptions().timeZone;
  const zones = ["UTC", "America/Denver", "America/New_York", bz];
  p = load({ state: stateWith({}, { kiosk: false, configured: false, revision: "rev-nk", tz_list: zones }), status: {} });
  await flush();
  ok(p.$("url-card").style.display === "none" && p.$("blank-wrap").style.display === "none", "the page URL card and the blank timeout are hidden");
  ok(p.$("f-url").disabled && p.$("f-blank").disabled, "their fields are disabled, so a save does not send them");
  ok(p.$("login-wrap").style.display === "none" && p.$("f-token").disabled, "the login method of the browser is hidden and disabled (plugin of tsx-ha)");
  ok(p.$("f-tz").value === bz, "the time zone shows the zone of this browser: " + p.$("f-tz").value);
  p.$("f-url").value = "https://example.org"; p.$("f-blank").value = "99";
  p.submit(); await flush();
  ok(same(p.lastSubmit(), { revision: "rev-nk", fields: { TZ_NAME: bz } }), "an unconfigured save sends TZ_NAME although it did not change: " + JSON.stringify(p.lastSubmit()));
  p = load({ state: stateWith({ TZ_NAME: "America/Denver" }, { kiosk: false, configured: true, tz_list: zones }), status: {} });
  await flush();
  ok(p.$("f-tz").value === "America/Denver", "a stored time zone shows");
  p.submit(); await flush();
  ok(same(p.lastSubmit().fields, {}), "a configured panel sends only changed fields: " + JSON.stringify(p.lastSubmit().fields));
  p = load({ state: stateWith({}, { kiosk: false, configured: false, tz_list: ["Etc/Foo"] }), status: {} });
  await flush();
  ok(p.$("f-tz").value === "", "no UTC and no zone of the browser in the list: the field stays empty");
  p = load({ state: stateWith(STORED, { kiosk: true }), status: {} });
  await flush();
  ok(p.$("url-card").style.display === "block" && !p.$("f-url").disabled && p.$("login-wrap").style.display === "block", "with a kiosk the URL card and the login method show");

  console.log("== " + N + " ok, " + F + " failed ==");
  process.exit(F ? 1 : 0);
})().catch(e => { console.log("  FAIL: " + (e && e.stack || e)); process.exit(1); });

function document_checked(p, value) {
  const r = p.$("form").querySelector("input[name=HA_LOGIN_METHOD]:checked");
  return !!r && r.attrs.value === value;
}
JSEOF

node "$T/harness.js" "$T/tree.json" "$T/page.js"
rc=$?
[ "$rc" = 0 ] && echo PASS test-setup-page || echo FAIL test-setup-page
exit "$rc"
