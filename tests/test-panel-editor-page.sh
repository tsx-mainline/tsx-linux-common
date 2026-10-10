#!/bin/bash
# Host test of the script of the layout editor (layout-editor.html of the panel
# app) and of the API key field that the plugin adds to the setup page. It
# runs the real page scripts in node, against the fake DOM of tests/lib/fakedom.js
# and a fake server. The test covers:
#  - a layout goes through the editor model with no change and comes out as
#    the same JSON, with the same order of the keys, and the save payload
#  - the placement of the cards in the preview (the same rules as
#    tsx-layout-check --placed, also with cards that the app leaves out)
#  - pages: add, rename, move, remove (the keys that show a page follow)
#  - cards: add, remove, move, the type keys, the entity id, the icon picker,
#    the tap action and the entity suggestions
#  - the theme, the keys (also the action "setup"), the raw JSON view
#  - the errors of the check, a refused save, a stale revision, the pairing gate
#  - the list of Home Assistant entities: the token never comes back
#  - the API key field of the setup page: "Make a new key" and the save payload
# It needs node. Without node it prints SKIPPED.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/tests/lib/paths.sh"
. "$HERE/tests/lib/board.sh"
SETUPD=$(P usr/local/sbin/tsx-setupd)
CHECK=$(P usr/local/bin/tsx-layout-check)
EDITOR=$(P usr/local/share/tsx/panel-app/layout-editor.html)
EXAMPLE=$(P usr/local/share/tsx/panel-app/example-layout.json)
ICONS=$(P usr/local/share/tsx/panel-app/icons.txt)
PLUGINS_SRC=$(dirname "$(P usr/local/share/tsx/setup.d/panel_layout.py)")
HAPLUGIN=$(P usr/local/share/tsx/setup.d/ha.py)
command -v node >/dev/null 2>&1 || { echo "SKIPPED test-panel-editor-page: no node on this host"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIPPED test-panel-editor-page: no python3 on this host"; exit 0; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/editor" "$T/setup" "$T/plugins"

python3 "$HERE/tests/lib/htmltree.py" "$T/editor" --file "$EDITOR" || { echo "FAIL: could not read the editor page"; exit 1; }
ln -s "$HAPLUGIN" "$T/plugins/ha.py"
ln -s "$PLUGINS_SRC/panel_layout.py" "$T/plugins/panel_layout.py"
TSX_SETUP_CONF="$T/none.conf" TSX_RUN_DIR="$T/run" TSX_SETUP_NO_ZEROCONF=1 \
	python3 "$HERE/tests/lib/htmltree.py" "$T/setup" --setupd "$SETUPD" "$T/plugins" || { echo "FAIL: could not build the setup page"; exit 1; }

# The cells that tsx-layout-check --placed gives, for the layouts below.
cat > "$T/tricky.json" <<'JSEOF'
{"version": 1, "grid": {"columns": 4, "rows": 3}, "pages": [
 {"cards": [{"type": "clock", "w": 2}, {"type": "light", "entity_id": "switch.bad"}, {"type": "clock", "x": 0, "y": 1, "w": 2, "h": 2},
            {"type": "clock", "h": 3}, {"type": "clock", "x": 1, "y": 1}, {"type": "clock", "w": 4}, {"type": "clock"}]},
 {"columns": 2, "rows": 2, "cards": [{"type": "clock", "w": 3}, {"type": "sensor", "entity_id": "sensor.a", "precision": 9},
            {"type": "weather", "entity_id": "weather.x", "x": 1, "y": 1}, {"type": "clock", "tap": "default"},
            {"type": "clock", "tap": {"action": "light.toggle", "data": {"a": [1]}}}, {"type": "scene", "entity_id": "scene.s", "h": 2}]}]}
JSEOF
for n in example tricky; do
	src="$T/tricky.json"; [ "$n" = example ] && src=$EXAMPLE
	TSX_ICON_FILE="$ICONS" python3 "$CHECK" --placed "$src" | sed -n '/^{/,$p' | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(json.dumps([[[c["x"], c["y"], c["w"], c["h"]] for c in p["cards"]] for p in d["pages"]]))' > "$T/placed-$n.json"
done

cat > "$T/harness.js" <<'JSEOF'
"use strict";
const fs = require("fs");
const { createDom } = require(process.argv[2]);
const read = (p) => fs.readFileSync(p, "utf8");
const ED_TREE = JSON.parse(read(process.argv[3])), ED_SCRIPT = read(process.argv[4]);
const EXAMPLE = JSON.parse(read(process.argv[5]));
const ICONS = read(process.argv[6]).split("\n").filter(l => l && !l.startsWith("#")).map(l => l.split(/\s+/)[0]).sort();
const PLACED = { example: JSON.parse(read(process.argv[7])), tricky: JSON.parse(read(process.argv[8])) };
const TRICKY = JSON.parse(read(process.argv[9]));
const SET_TREE = JSON.parse(read(process.argv[10])), SET_SCRIPT = read(process.argv[11]);

let N = 0, F = 0;
function ok(cond, what) { if (cond) { N++; console.log("  ok: " + what); } else { F++; console.log("  FAIL: " + what); } }
const clone = (v) => JSON.parse(JSON.stringify(v));
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const settle = () => new Promise(r => setTimeout(r, 0));
async function flush() { for (let i = 0; i < 6; i++) await settle(); }

const ENTITIES = [
  { entity_id: "light.kitchen", name: "Kitchen", state: "on", source: "app" },
  { entity_id: "light.porch", name: "Porch", state: "off", source: "ha" },
  { entity_id: "sensor.temp", name: "Temperature", state: "21.5", source: "ha" },
  { entity_id: "switch.coffee_maker", name: "", state: "off", source: "layout" },
];
const BASE = {
  icons: ICONS, types: ["light", "switch", "scene", "script", "sensor", "weather", "clock"],
  domains: { light: "light", scene: "scene", script: "script", weather: "weather" },
  type_keys: { sensor: ["attribute", "precision", "unit"], clock: ["date_format", "format"] },
  theme_keys: ["background", "card", "card_on", "text", "text_dim"],
  limits: { max_pages: 16, max_cards: 48, max_grid: 12, max_gap: 40, max_precision: 6, max_file_bytes: 65536 },
  defaults: { theme: { background: "#101418", card: "#2a3038", card_on: "#c88a1e", text: "#f0f0f0", text_dim: "#9aa4b0" }, grid: { columns: 4, rows: 3, gap: 10 } },
  checker: true,
};

// ---- the editor page, with a fake server ----
function loadEditor(over) {
  const server = Object.assign({
    layout: clone(EXAMPLE), source: "user", revision: "rev1", entities: clone(ENTITIES), haToken: false, text: undefined,
    check: { status: 200, body: { ok: true, errors: [], warnings: [], placed: null } },
    save: { status: 200, body: { ok: true, warnings: [], revision: "rev2" } },
    first: null, calls: [],
  }, over || {});
  const dom = createDom(ED_TREE);
  const timers = [];
  const document = dom.document;
  const fetch = (path, opts) => {
    const method = (opts && opts.method) || "GET";
    const body = opts && opts.body ? JSON.parse(opts.body) : undefined;
    server.calls.push({ method, path, body });
    let r = { status: 404, body: {} };
    if (method === "GET" && path === "/setup/api/layout") {
      if (server.first) { r = server.first; server.first = null; }
      else r = { status: 200, body: Object.assign({ layout: server.layout, source: server.source, revision: server.revision, entities: server.entities,
        ha_token_set: server.haToken, text: server.text }, BASE) };
    } else if (path === "/setup/api/layout/check") r = server.check;
    else if (path === "/setup/api/layout/save") r = server.save;
    else if (path === "/setup/api/pair") r = server.pair || { status: 200, body: { ok: true } };
    else if (path === "/setup/api/layout/ha-token") r = { status: 200, body: { ok: true, ha_token_set: true } };
    else if (path === "/setup/api/layout/ha-token-clear") r = { status: 200, body: { ok: true, ha_token_set: false } };
    else if (path === "/setup/api/layout/ha-entities") r = server.haList || { status: 200, body: { ok: true, count: 2 } };
    else if (path === "/setup/api/layout/entities") r = { status: 200, body: { entities: server.entities.concat([{ entity_id: "fan.bedroom", name: "Fan", state: "on", source: "ha" }]), ha_token_set: true } };
    const copy = JSON.parse(JSON.stringify(r.body));
    return Promise.resolve({ status: r.status, json: () => Promise.resolve(copy) });
  };
  const setTimeoutF = (fn) => { timers.push(fn); return timers.length; };
  const clearTimeoutF = (id) => { if (id) timers[id - 1] = null; };
  new Function("document", "fetch", "setTimeout", "clearTimeout", ED_SCRIPT)(document, fetch, setTimeoutF, clearTimeoutF);
  const $ = (id) => document.getElementById(id);
  const p = {
    $, document, server, root: dom.root,
    runTimers: async () => { while (timers.length) { const f = timers.shift(); if (f) f(); } await flush(); },
    saves: () => server.calls.filter(c => c.path === "/setup/api/layout/save"),
    lastSave: () => { const s = p.saves(); return s.length ? s[s.length - 1].body : null; },
    click: (el) => el.fire("click"),
    type: (el, v) => { el.value = v; el.fire("input"); },
    pick: (el, v) => { el.value = v; el.fire("change"); },
    save: async () => { p.click($("save-btn")); await flush(); },
    pcards: () => $("preview").children.filter(c => c.className.indexOf("pcard") >= 0),
    cells: () => $("preview").children.filter(c => c.className === "cell"),
    cardRows: () => $("card-list").children,
    pageRows: () => $("page-list").children,
    cardEdit: (sel) => $("card-edit").querySelector(sel),
    selectPage: (i) => p.click(p.pageRows()[i].children[0]),
    selectCard: (i) => p.click(p.cardRows()[i].children[1].children[0]),
    rowButton: (row, text) => row.descendants().find(c => c.tag === "button" && c.textContent === text),
  };
  return p;
}
const cellOf = (c) => { // "2 / span 3" -> [col, span]
  const col = c.style.gridColumn.split(" / span "), row = c.style.gridRow.split(" / span ");
  return [Number(col[0]) - 1, Number(row[0]) - 1, Number(col[1]), Number(row[1])];
};

(async () => {
  console.log("== load: the pages, the raw JSON, the first look ==");
  let p = loadEditor();
  await flush();
  ok(p.$("main").style.display === "block" && p.$("gate").style.display === "none", "the editor shows");
  ok(p.pageRows().length === 2 && p.pageRows()[0].children[1].value === "Home" && p.pageRows()[1].children[1].value === "Outside", "the two pages show with their names");
  ok(p.$("page-title").textContent === "Home", "the title says the page");
  ok(p.$("raw-text").value === JSON.stringify(EXAMPLE, null, 2), "the raw JSON is the layout");
  ok(p.$("source-note").textContent === "", "the layout of the user needs no note");
  ok(p.cardRows().length === 10, "the card list has 10 cards");
  ok(p.$("gr-columns").value === "4" && p.$("gr-gap").value === "10", "the grid defaults show");
  ok(p.$("card-add-type").children.length === 7, "the card type list has 7 types");

  console.log("== a save with no change sends the same JSON ==");
  await p.save();
  ok(p.lastSave() && JSON.stringify(p.lastSave().layout) === JSON.stringify(EXAMPLE), "the layout of the save is the same JSON as the loaded one, key order too");
  ok(p.lastSave().revision === "rev1", "the save sends the revision of the load");
  ok(p.$("bar-text").textContent.indexOf("Saved") === 0, "the bar says: Saved");
  await p.save();
  ok(p.lastSave().revision === "rev2", "the next save sends the new revision");

  console.log("== the preview: the cards as the app places them ==");
  p = loadEditor();
  await flush();
  let got = p.pcards().map(cellOf);
  ok(same(got, PLACED.example[0]), "page 1 of the example: " + JSON.stringify(got));
  ok(p.cells().length === 12, "the grid of page 1 has 12 cells");
  p.selectPage(1); got = p.pcards().map(cellOf);
  ok(same(got, PLACED.example[1]) && p.cells().length === 6, "page 2 (3 columns, 2 rows): " + JSON.stringify(got));
  ok(p.$("preview").style.gridTemplateColumns === "repeat(3, 1fr)", "the columns of the page set the grid");
  ok(p.$("page-title").textContent === "Outside", "the title follows the page");
  p = loadEditor({ layout: clone(TRICKY) });
  await flush();
  got = p.pcards().map(cellOf);
  ok(same(got, PLACED.tricky[0]), "a page with a card that the app leaves out: " + JSON.stringify(got) + " (tsx-layout-check: " + JSON.stringify(PLACED.tricky[0]) + ")");
  ok(p.$("chips").children.length >= 2, "the cards that are not shown are listed under the preview");
  p.selectPage(1); got = p.pcards().map(cellOf);
  ok(same(got, PLACED.tricky[1]), "a page with cards that have bad values: " + JSON.stringify(got) + " (tsx-layout-check: " + JSON.stringify(PLACED.tricky[1]) + ")");

  console.log("== the preview uses the places of the check when it matches the layout ==");
  p = loadEditor({ check: { status: 200, body: { ok: true, errors: [], warnings: [], placed: [{ name: "Home", columns: 4, rows: 3, cards: [{ index: 0, x: 1, y: 1, w: 1, h: 1 }] }, { name: "Outside", columns: 3, rows: 2, cards: [] }] } } });
  await flush(); await p.runTimers();
  ok(same(p.pcards().map(cellOf), [[1, 1, 1, 1]]), "the preview shows the places of the server");
  p.type(p.pageRows()[0].children[1], "Home 2");
  ok(same(p.pcards().map(cellOf), PLACED.example[0]), "after an edit, until the next check, the preview uses the local rules");

  console.log("== pages: rename, add, move, remove (the keys that show a page follow) ==");
  p = loadEditor();
  await flush();
  p.type(p.pageRows()[0].children[1], "Kitchen");
  ok(p.$("page-title").textContent === "Kitchen", "a new name shows in the title");
  p.type(p.pageRows()[0].children[1], "");
  ok(p.$("page-title").textContent === "Page 1" && p.$("raw-text").value.indexOf('"name": "Home"') < 0, "an empty name removes the key (the app says Page 1)");
  p.type(p.pageRows()[0].children[1], "Home");
  p.click(p.$("page-add"));
  ok(p.pageRows().length === 3 && p.$("page-title").textContent === "Page 3", "Add a page selects the new page");
  p.type(p.$("pg-cols"), "3");
  p.click(p.rowButton(p.pageRows()[2], "Up"));
  ok(p.pageRows()[1].children[1].value === "Page 3" && p.pageRows()[1].className.indexOf("sel") >= 0, "Up moves the page, and it stays selected");
  await p.save();
  const pg = p.lastSave().layout.pages;
  ok(pg.length === 3 && pg[0].name === "Home" && pg[1].name === "Page 3" && pg[1].columns === 3 && pg[2].name === "Outside", "the payload has the three pages in the new order with the columns");
  ok(p.lastSave().layout.keys.home === "page:1", "the key that shows page 1 stays");
  p = loadEditor();
  await flush();
  p.$("keys-form").querySelectorAll("select")[0].value = "page:2"; p.$("keys-form").querySelectorAll("select")[0].fire("change");
  p.click(p.rowButton(p.pageRows()[0], "Down"));
  await p.save();
  ok(p.lastSave().layout.keys.home === "page:1" && p.lastSave().layout.pages[0].name === "Outside", "the page moved down: the key that showed page 2 now shows page 1");
  p.click(p.rowButton(p.pageRows()[0], "Remove"));
  await p.save();
  ok(p.lastSave().layout.pages.length === 1 && p.lastSave().layout.keys.home === undefined, "a removed page: the key that showed it is removed too");
  ok(p.rowButton(p.pageRows()[0], "Remove").disabled, "the last page cannot be removed");

  console.log("== grid defaults ==");
  p = loadEditor({ layout: { version: 1, pages: [{ cards: [] }] } });
  await flush();
  ok(p.$("gr-columns").value === "" && p.$("gr-columns").placeholder === "4", "no grid: the fields are empty with the defaults as the hint");
  p.type(p.$("gr-columns"), "6"); await p.save();
  ok(same(p.lastSave().layout.grid, { columns: 6 }), "a value makes the grid object");
  p.type(p.$("gr-columns"), ""); await p.save();
  ok(p.lastSave().layout.grid === undefined, "an empty value removes the key, and the empty grid object");

  console.log("== cards: add, edit, the type keys, the entity id ==");
  p = loadEditor();
  await flush();
  p.$("card-add-type").value = "sensor";
  p.click(p.$("card-add"));
  ok(p.cardRows().length === 11 && p.cardEdit("[name=entity_id]") !== null, "Add a card adds a card and shows its form");
  ok(p.cardEdit("[name=entity_id]").focused === true, "the entity field gets the focus");
  p.type(p.cardEdit("[name=entity_id]"), "light.kitchen");
  ok(p.$("card-edit").textContent.indexOf("A sensor card") < 0, "a sensor card takes any domain");
  p.type(p.cardEdit("[name=entity_id]"), "sensor.temp");
  ok(p.$("card-edit").textContent.indexOf("Temperature · 21.5") >= 0, "the entity id shows the name and the state: " + p.$("card-edit").textContent.slice(0, 120));
  p.type(p.cardEdit("[name=precision]"), "2"); p.type(p.cardEdit("[name=unit]"), "C"); p.type(p.cardEdit("[name=attribute]"), "");
  p.type(p.cardEdit("[name=label]"), "Temp");
  p.type(p.cardEdit("[name=w]"), "2");
  await p.save();
  let last = p.lastSave().layout.pages[0].cards.slice(-1)[0];
  ok(same(last, { type: "sensor", entity_id: "sensor.temp", precision: 2, unit: "C", label: "Temp", w: 2 }), "the payload has the new card: " + JSON.stringify(last));
  p.type(p.cardEdit("[name=w]"), ""); p.type(p.cardEdit("[name=label]"), ""); p.type(p.cardEdit("[name=precision]"), "");
  await p.save();
  last = p.lastSave().layout.pages[0].cards.slice(-1)[0];
  ok(same(last, { type: "sensor", entity_id: "sensor.temp", unit: "C" }), "an empty field removes its key");
  p.pick(p.$("c-type"), "light");
  ok(p.cardEdit("[name=precision]") === null && p.$("card-edit").textContent.indexOf("A light card needs a light entity") >= 0, "a new type: the keys of the old type go, the domain is checked");
  await p.save();
  last = p.lastSave().layout.pages[0].cards.slice(-1)[0];
  ok(same(last, { type: "light", entity_id: "sensor.temp" }), "the type keys of the old type are removed from the payload: " + JSON.stringify(last));
  p.pick(p.$("c-type"), "clock");
  await p.save();
  last = p.lastSave().layout.pages[0].cards.slice(-1)[0];
  ok(same(last, { type: "clock" }), "a clock card has no entity_id");
  p.type(p.cardEdit("[name=format]"), "%H:%M:%S");
  const nd = p.cardEdit("[name=no_date]"); nd.checked = true; nd.fire("change");
  await p.save();
  last = p.lastSave().layout.pages[0].cards.slice(-1)[0];
  ok(same(last, { type: "clock", format: "%H:%M:%S", date_format: "" }), "Show no date sets date_format to an empty text: " + JSON.stringify(last));
  ok(p.cardEdit("[name=date_format]").disabled === true, "the date format field is off then");
  nd.checked = false; nd.fire("change");
  await p.save();
  ok(p.lastSave().layout.pages[0].cards.slice(-1)[0].date_format === undefined, "Show no date off removes date_format");
  ok(p.$("entity-list").children.length === 4, "the suggestions for a clock card list all entities: " + p.$("entity-list").children.length);
  p.pick(p.$("c-type"), "light");
  ok(p.$("entity-list").children.length === 2, "the suggestions for a light card list the light entities only");
  ok(p.$("entity-list").children[0].value === "light.kitchen" && p.$("entity-list").children[0].label === "Kitchen (on)", "an option has the id as its value and the name and state as its label");
  p.type(p.cardEdit("[name=entity_id]"), "Light.Kitchen!");
  ok(p.$("card-edit").textContent.indexOf("looks like domain.name") >= 0, "a bad entity id gets a message at once");

  console.log("== cards: the list (select, move, remove) ==");
  p = loadEditor();
  await flush();
  p.selectCard(2);
  ok(p.cardRows()[2].className.indexOf("sel") >= 0 && p.cardEdit("[name=entity_id]").value === "light.kitchen", "a tap on a card of the list selects it and shows its form");
  p.click(p.rowButton(p.cardRows()[2], "Down"));
  ok(p.cardRows()[3].className.indexOf("sel") >= 0, "Down moves the card, and the selection follows");
  p.click(p.rowButton(p.cardRows()[0], "Remove"));
  await p.save();
  const c0 = p.lastSave().layout.pages[0].cards;
  ok(c0.length === 9 && c0[0].type === "weather" && c0[1].entity_id === "light.living_room" && c0[2].entity_id === "light.kitchen", "remove and move are in the payload");
  p.selectPage(1); p.selectCard(0);
  p.click(p.cells()[5]);
  ok(same(p.pcards().map(cellOf)[0], [2, 1, 1, 1]), "a tap on an empty cell moves the selected card there");
  await p.save();
  const o0 = p.lastSave().layout.pages[1].cards[0];
  ok(o0.x === 2 && o0.y === 1, "the card has the cell that was tapped: " + JSON.stringify([o0.x, o0.y]));

  console.log("== the icon picker ==");
  p = loadEditor();
  await flush();
  p.selectCard(2);
  const ic = p.cardEdit("[name=icon]");
  p.type(ic, "cof");
  const names = p.cardEdit(".icons").children.map(b => b.textContent);
  ok(same(names, ICONS.filter(n => n.indexOf("cof") >= 0)) && names.length >= 1, "the list shows the icons that match the search: " + names.join(","));
  p.click(p.cardEdit(".icons").children[0]);
  await p.save();
  ok(p.lastSave().layout.pages[0].cards[2].icon === "mdi:coffee", "a tap on an icon sets mdi:name");
  p.type(ic, "");
  await p.save();
  ok(p.lastSave().layout.pages[0].cards[2].icon === undefined, "an empty search field removes the icon (the default)");
  ok(p.cardEdit("[name=icon]").value === "", "the field is empty");
  p.type(ic, "mdi:no-such-icon");
  ok(p.cardEdit(".icons").children[0].textContent === "No icon of the font has this text.", "a name that is not in the font: the list says so");
  await p.save();
  ok(p.lastSave().layout.pages[0].cards[2].icon === "mdi:no-such-icon", "the name is kept (the check gives a warning, the app shows the default icon)");

  console.log("== the tap action ==");
  p = loadEditor();
  await flush();
  p.selectCard(2);
  const tapSel = () => p.$("card-edit").querySelectorAll("select").slice(-1)[0];
  ok(tapSel().value === "default", "no tap: the default shows");
  p.pick(tapSel(), "custom");
  ok(p.cardEdit("[name=action]").value === "light.turn_on", "custom: the action is a guess from the entity");
  p.type(p.cardEdit("[name=action]"), "light.turn_on");
  p.click(p.$("card-edit").querySelectorAll("button").find(b => b.textContent === "Add a value"));
  const lines = p.$("card-edit").querySelectorAll(".sub-form .item");
  p.type(lines[0].children[0], "brightness_pct"); p.type(lines[0].children[1], "50");
  p.click(p.$("card-edit").querySelectorAll("button").find(b => b.textContent === "Add a value"));
  const lines2 = p.$("card-edit").querySelectorAll(".sub-form .item");
  p.type(lines2[1].children[0], "flash"); p.type(lines2[1].children[1], "true");
  p.click(p.$("card-edit").querySelectorAll("button").find(b => b.textContent === "Add a value"));
  const lines3 = p.$("card-edit").querySelectorAll(".sub-form .item");
  p.type(lines3[2].children[0], "effect"); p.type(lines3[2].children[1], "colorloop");
  await p.save();
  ok(same(p.lastSave().layout.pages[0].cards[2].tap, { action: "light.turn_on", data: { brightness_pct: 50, flash: true, effect: "colorloop" } }),
    "the tap action with typed values: " + JSON.stringify(p.lastSave().layout.pages[0].cards[2].tap));
  p.click(lines3[2].children[2]);
  await p.save();
  ok(same(Object.keys(p.lastSave().layout.pages[0].cards[2].tap.data), ["brightness_pct", "flash"]), "Remove drops a value");
  p.pick(tapSel(), "none");
  await p.save();
  ok(p.lastSave().layout.pages[0].cards[2].tap === "none", "none");
  p.pick(tapSel(), "default");
  await p.save();
  ok(p.lastSave().layout.pages[0].cards[2].tap === undefined, "default removes the key");

  console.log("== the theme ==");
  p = loadEditor();
  await flush();
  ok(p.$("thd-card").checked === true && p.$("th-card").disabled === true, "no theme: every color is the default");
  p.$("thd-card").checked = false; p.$("thd-card").fire("change");
  await p.save();
  ok(same(p.lastSave().layout.theme, { card: "#2a3038" }), "Default off makes the key with the color of the default");
  p.$("th-card").value = "#112233"; p.$("th-card").fire("input");
  await p.save();
  ok(p.lastSave().layout.theme.card === "#112233", "a color is in the payload");
  ok(p.pcards()[0].style.background === "#112233", "the preview uses the card color");
  p.$("thd-card").checked = true; p.$("thd-card").fire("change");
  await p.save();
  ok(p.lastSave().layout.theme === undefined, "Default on removes the key, and the empty theme object");

  console.log("== the keys, with the action setup ==");
  p = loadEditor();
  await flush();
  const rows = () => p.$("keys-form").children.filter(c => c.className === "keyrow");
  ok(same(rows().map(r => r.children[0].textContent), ["home", "up", "down", "power", "lights"]), "the rows: home, up, down, power, lights");
  const sel = (name) => rows().find(r => r.children[0].textContent === name).querySelector("select");
  ok(sel("home").value === "page:1" && sel("up").value === "prev_page" && sel("power").value === "default", "the stored actions show");
  ok(sel("power").children.some(o => o.value === "setup"), "setup is a choice for a key");
  ok(sel("power").children.some(o => o.value === "page:2" && o.textContent.indexOf("Outside") >= 0), "a page is a choice, with its name");
  p.pick(sel("power"), "setup");
  await p.save();
  ok(p.lastSave().layout.keys.power === "setup", "the key power opens the setup window");
  p.pick(sel("lights"), "page:2");
  p.pick(sel("down"), "none");
  await p.save();
  ok(same(p.lastSave().layout.keys, { home: "page:1", up: "prev_page", down: "none", power: "setup", lights: "page:2" }), "page:2 and none: " + JSON.stringify(p.lastSave().layout.keys));
  p.pick(sel("lights"), "custom");
  const lr = rows().find(r => r.children[0].textContent === "lights");
  p.type(lr.querySelector("[name=action]"), "scene.turn_on");
  p.click(lr.querySelectorAll("button").find(b => b.textContent === "Add a value"));
  p.type(lr.querySelectorAll(".item")[0].children[0], "entity_id"); p.type(lr.querySelectorAll(".item")[0].children[1], "scene.movie_night");
  await p.save();
  ok(same(p.lastSave().layout.keys.lights, { action: "scene.turn_on", data: { entity_id: "scene.movie_night" } }), "a custom action for a key");
  p.pick(sel("power"), "default"); p.pick(sel("lights"), "default"); p.pick(sel("down"), "default"); p.pick(sel("up"), "default"); p.pick(sel("home"), "default");
  await p.save();
  ok(p.lastSave().layout.keys === undefined, "default removes the key, and the empty keys object");
  p.type(rows()[0].parentElement.querySelector("[name=new_key]"), "volume");
  p.click(p.$("keys-form").querySelectorAll("button").find(b => b.textContent === "Add a key"));
  await p.save();
  ok(p.lastSave().layout.keys.volume === "none" && rows().length === 6, "a free key name: the key is added with the action none");
  p = loadEditor({ layout: { version: 1, keys: { home: "page:5" }, pages: [{ cards: [] }] } });
  await flush();
  ok(sel("home").value === "page:5" && sel("home").children.some(o => o.textContent.indexOf("no such page") >= 0), "a key that shows a page that does not exist is still shown");

  console.log("== the check: problems, marks, notes ==");
  p = loadEditor({ check: { status: 200, body: { ok: false, errors: ['page 1 card 2: no valid "entity_id" (domain.object_id)'], warnings: ['page 1 card 3: unknown key "colour" (ignored)'], placed: null } } });
  await flush(); await p.runTimers();
  ok(p.$("problems").style.display === "block" && p.$("problems").querySelectorAll("li").length === 2, "the problems card lists the errors and the warnings");
  ok(p.cardRows()[1].className.indexOf("bad") >= 0 && p.cardRows()[0].className.indexOf("bad") < 0, "the card with an error is marked in the list");
  ok(p.$("bar-text").textContent.indexOf("1 error") === 0, "the bar counts the errors");
  p.click(p.$("problems").querySelectorAll("li")[0]);
  ok(p.cardRows()[1].className.indexOf("sel") >= 0, "a tap on a problem selects its card");
  p.type(p.cardEdit("[name=label]"), "x");
  ok(p.$("problems").className.indexOf("old") >= 0, "after an edit the old list is dimmed until the next check");

  console.log("== a refused save, a stale revision ==");
  p = loadEditor({ save: { status: 400, body: { errors: ["page 1 card 1: unknown type \"fan\""], warnings: [] } } });
  await flush(); await p.save();
  ok(p.$("problems").style.display === "block" && p.$("problems").textContent.indexOf("unknown type") >= 0, "the errors of the server show");
  ok(p.$("bar-text").textContent.indexOf("Saved") < 0, "the bar does not say Saved");
  p = loadEditor({ save: { status: 409, body: { stale: true, error: "The layout changed after this page loaded." } } });
  await flush(); await p.save();
  ok(p.$("stale").style.display === "block" && p.$("stale-text").textContent === "The layout changed after this page loaded.", "a 409 shows the stale notice");
  const before = p.server.calls.filter(c => c.path === "/setup/api/layout" && c.method === "GET").length;
  p.click(p.$("reload-btn")); await flush();
  ok(p.server.calls.filter(c => c.path === "/setup/api/layout" && c.method === "GET").length === before + 1 && p.$("stale").style.display === "none", "Reload the layout reads the layout again");
  p = loadEditor({ save: { status: 500, body: { error: "tsx-setup-helper did not answer in time" } } });
  await flush(); await p.save();
  ok(p.$("bar-text").textContent === "tsx-setup-helper did not answer in time", "another error shows its text");

  console.log("== revert ==");
  p = loadEditor();
  await flush();
  p.type(p.pageRows()[0].children[1], "Changed");
  ok(p.$("bar-text").textContent === "Not saved", "an edit: Not saved");
  p.click(p.$("revert-btn"));
  ok(p.$("revert-btn").textContent === "Drop my changes" && p.pageRows()[0].children[1].value === "Changed", "the first tap asks again");
  p.click(p.$("revert-btn")); await flush();
  ok(p.pageRows()[0].children[1].value === "Home" && p.$("bar-text").textContent === "", "the second tap loads the layout again");

  console.log("== the layout of the board, the example, a file with an error ==");
  p = loadEditor({ source: "board", revision: "" });
  await flush();
  ok(p.$("source-note").textContent.indexOf("default layout of the board") >= 0, "the board layout has a note");
  await p.save();
  ok(p.lastSave().revision === "", "the save of a first layout sends an empty revision");
  p = loadEditor({ source: "none", revision: "" });
  await flush();
  ok(p.$("source-note").textContent.indexOf("example layout") >= 0, "the example has a note");
  p = loadEditor({ layout: null, text: '{"version": 1, "pages": [', source: "user" });
  await flush();
  ok(p.$("broken").style.display === "block" && p.$("sections").style.display === "none", "a file that does not parse: the notice shows and the sections do not");
  ok(p.$("raw-text").value === '{"version": 1, "pages": [', "the raw view has the text of the file");
  p.click(p.$("new-btn"));
  ok(p.$("sections").style.display === "block" && p.pageRows().length === 1, "Start a new layout makes one empty page");
  await p.save();
  ok(same(p.lastSave().layout, { version: 1, pages: [{ name: "Home", cards: [] }] }), "and it saves");
  p = loadEditor({ layout: { version: 1, pages: "no" }, source: "user" });
  await flush();
  ok(p.$("broken").style.display === "block", "a layout with no list of pages is shown as a broken file");

  console.log("== the raw JSON ==");
  p = loadEditor();
  await flush();
  const raw = JSON.parse(p.$("raw-text").value); raw.pages[0].name = "Raw"; raw.pages.push({ name: "Third", cards: [] });
  p.$("raw-text").value = JSON.stringify(raw, null, 2); p.$("raw-text").fire("input");
  p.click(p.$("raw-apply"));
  ok(p.pageRows().length === 3 && p.pageRows()[0].children[1].value === "Raw" && p.$("raw-status").className.indexOf("ok") >= 0, "Use this JSON replaces the layout");
  await p.save();
  ok(same(p.lastSave().layout, raw), "the payload is the pasted layout");
  p.$("raw-text").value = "{ not json"; p.$("raw-text").fire("input");
  p.click(p.$("raw-apply"));
  ok(p.$("raw-status").className.indexOf("bad") >= 0 && p.pageRows().length === 3, "JSON that does not parse is refused and the layout stays");
  p.$("raw-text").value = '{"version": 1}'; p.click(p.$("raw-apply"));
  ok(p.$("raw-status").className.indexOf("bad") >= 0, "an object with no pages is refused");
  p.click(p.$("raw-refresh"));
  ok(p.$("raw-text").value === JSON.stringify(raw, null, 2), "Show the layout again writes the layout back");

  console.log("== the pairing gate and the other answers of the server ==");
  p = loadEditor({ first: { status: 200, body: { need_pairing: true } } });
  await flush();
  ok(p.$("gate").style.display === "block" && p.$("main").style.display === "none", "the pairing gate shows");
  p.$("pair-code").value = "123456"; p.click(p.$("pair-go")); await flush();
  const pair = p.server.calls.find(c => c.path === "/setup/api/pair");
  ok(pair && pair.body.code === "123456", "the code goes to /setup/api/pair");
  ok(p.$("main").style.display === "block" && p.$("gate").style.display === "none", "after the pairing the editor loads");
  p = loadEditor({ first: { status: 403, body: { error: "setup is not reachable over the network right now" } } });
  await flush();
  ok(p.$("unavail").style.display === "block" && p.$("main").style.display === "none", "403: the page says that setup is not available");
  p = loadEditor({ first: { status: 200, body: { need_pairing: true } }, pair: { status: 403, body: { error: "wrong or expired pairing code" } } });
  await flush(); p.$("pair-code").value = "1"; p.click(p.$("pair-go")); await flush();
  ok(p.$("pair-status").textContent === "wrong or expired pairing code" && p.$("main").style.display === "none", "a wrong code shows the message");

  console.log("== the Home Assistant entity list: the token never comes back ==");
  p = loadEditor();
  await flush();
  ok(p.$("ha-form").textContent.indexOf("No token is stored") >= 0 && p.$("ha-token").type === "password", "no token: the form asks for the URL and the token (a password field)");
  const SECRET = "eyJhbGciOiJIUzI1NiJ9.TESTtoken0123456789.sig";
  p.$("ha-url").value = "https://ha.example.org:8123"; p.$("ha-token").value = SECRET;
  p.click(p.$("ha-form").querySelectorAll("button")[0]); await flush();
  const tokCall = p.server.calls.find(c => c.path === "/setup/api/layout/ha-token");
  ok(tokCall && tokCall.body.url === "https://ha.example.org:8123" && tokCall.body.token === SECRET, "the token goes to /setup/api/layout/ha-token once");
  ok(p.server.calls.some(c => c.path === "/setup/api/layout/ha-entities") && p.server.calls.some(c => c.path === "/setup/api/layout/entities"), "then the page asks for the list and reads it");
  ok(p.$("ha-token").value === "" && p.$("ha-form").textContent.indexOf(SECRET) < 0 && p.$("ha-form").textContent.indexOf("A token is stored.") >= 0, "the token field is empty, the page shows only: a token is stored");
  ok(p.$("ha-status").textContent === "The list has 2 entities.", "the status says how many entities: " + p.$("ha-status").textContent);
  p.selectCard(2);
  p.pick(p.$("c-type"), "switch");
  ok(p.$("entity-list").children.some(o => o.value === "fan.bedroom"), "the suggestions have the entities of the full list");
  p.click(p.$("ha-form").querySelectorAll("button").find(b => b.textContent === "Remove the token")); await flush();
  ok(p.server.calls.some(c => c.path === "/setup/api/layout/ha-token-clear") && p.$("ha-form").textContent.indexOf("No token is stored") >= 0, "Remove the token clears it");
  ok(JSON.stringify(p.server.calls).split(SECRET).length === 2, "the token is in one request only");

  console.log("== the API key field of the setup page ==");
  const dom = createDom(SET_TREE);
  const calls = [];
  const state = { need_pairing: false, configured: true, kiosk: false, loopback: true, lan_allowed: false, window_seconds: 900, revision: "r1",
    fields: { TZ_NAME: "UTC", HA_API_KEY: null, HA_API_KEY__set: true }, tz_list: ["UTC"], unavailable: {}, pairing_code: "111111", pairing_code_remaining: 800 };
  const sfetch = (path, opts) => {
    calls.push({ path, body: opts && opts.body ? JSON.parse(opts.body) : undefined });
    const r = path === "/setup/api/state" ? { status: 200, body: state } : path === "/setup/api/submit" ? { status: 200, body: { ok: true, changed: [] } } : { status: 200, body: {} };
    return Promise.resolve({ status: r.status, json: () => Promise.resolve(JSON.parse(JSON.stringify(r.body))) });
  };
  new Function("document", "fetch", "setInterval", "location", SET_SCRIPT)(dom.document, sfetch, () => 1, { reload() {} });
  await flush();
  const $ = (id) => dom.document.getElementById(id);
  ok(dom.root.querySelector('a[href="/setup/layout"]') !== null, "the setup page has the link to the editor");
  ok($("f-apikey").value === "" && $("f-apikey").placeholder === "(a key is set; leave blank to keep it)", "the key field is empty with a hint that a key is set");
  ok($("apikey-note").textContent === "A key is set. The page never shows it.", "the note says that a key is set");
  const submitted = () => calls.filter(c => c.path === "/setup/api/submit").slice(-1)[0].body.fields;
  $("form").fire("submit"); await flush();
  ok(same(submitted(), {}), "no change: the key is not sent");
  $("apikey-new").fire("click");
  const k1 = $("f-apikey").value;
  ok(/^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$/.test(k1), "Make a new key: 32 random bytes as base64 text: " + k1);
  $("apikey-new").fire("click");
  ok($("f-apikey").value !== k1 && /^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$/.test($("f-apikey").value), "another tap makes another key");
  $("form").fire("submit"); await flush();
  ok(same(submitted(), { HA_API_KEY: $("f-apikey").value }), "the save sends the key");
  ok(dom.root.querySelectorAll("[name=KIOSK_URL]").length === 1 && $("url-card").style.display === "none", "with no kiosk the page URL stays hidden");

  console.log("== " + N + " ok, " + F + " failed ==");
  process.exit(F ? 1 : 0);
})().catch(e => { console.log("  FAIL: " + (e && e.stack || e)); process.exit(1); });
JSEOF

node "$T/harness.js" "$HERE/tests/lib/fakedom.js" "$T/editor/tree.json" "$T/editor/page.js" "$EXAMPLE" "$ICONS" "$T/placed-example.json" "$T/placed-tricky.json" "$T/tricky.json" "$T/setup/tree.json" "$T/setup/page.js"
rc=$?
[ "$rc" = 0 ] && echo PASS test-panel-editor-page || echo FAIL test-panel-editor-page
exit "$rc"
