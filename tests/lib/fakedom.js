"use strict";
// A small fake DOM for the tests that run the script of a page in node. It
// has what the pages of this repo use: elements with properties, children,
// events, forms of a page and a few selectors. It is not a browser.
//
//   const { createDom } = require("./fakedom.js");
//   const dom = createDom(tree);          // tree: {tag, attrs, text, children}
//   dom.document.getElementById("save")   // the elements of the tree
//
// Selectors: tag, #id, .class, [attr], [attr=v], [attr="v"], :checked, and a
// space between such parts for a descendant.

function createDom(tree) {
  let ROOT = null;

  class El {
    constructor(tag, attrs, text) {
      this.tag = tag;
      this.tagName = tag.toUpperCase();
      this.attrs = Object.assign({}, attrs || {});
      this._text = text || "";
      this.children = [];
      this.parentElement = null;
      this.style = {};
      this.listeners = {};
      this.id = this.attrs.id || "";
      this.className = this.attrs.class || "";
      this.name = this.attrs.name || "";
      this.type = (this.attrs.type || (tag === "select" ? "select-one" : tag)).toLowerCase();
      this.disabled = "disabled" in this.attrs;
      this._checked = "checked" in this.attrs;
      this.selected = "selected" in this.attrs;
      this.placeholder = this.attrs.placeholder || "";
      this._value = tag === "textarea" ? this._text : (this.attrs.value !== undefined ? this.attrs.value : "");
      this._valueSet = false;
      this._noMatch = false;
    }
    get textContent() { return this._text + this.children.map(c => c.textContent).join(""); }
    set textContent(v) { this._text = String(v); this.children = []; }
    set innerHTML(v) { this._text = ""; this.children = []; this._noMatch = false; }
    get innerHTML() { return ""; }
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
    setAttribute(k, v) { this.attrs[k] = String(v); }
    getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
    addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); }
    fire(type, extra) {
      const ev = Object.assign({ type, target: this, preventDefault() {} }, extra || {});
      for (const fn of this.listeners[type] || []) fn(ev);
    }
    matches(sel) { return matches(this, sel); }
    closest(sel) { for (let e = this; e; e = e.parentElement) if (e.tag !== "#root" && matches(e, sel)) return e; return null; }
    querySelectorAll(sel) { return this.descendants().filter(e => matches(e, sel)); }
    querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
    scrollIntoView() {}
    focus() { this.focused = true; }
    select() { this.selectedText = true; }
  }

  // the value of an attribute or of the property of the same name
  function attrOf(e, k) {
    if (k in e.attrs) return e.attrs[k];
    if (k === "name") return e.name || undefined;
    if (k === "type") return e.type;
    if (k === "id") return e.id || undefined;
    return undefined;
  }
  function matchesOne(e, sel) {
    let s = sel.trim(), m;
    while (s.length) {
      if ((m = s.match(/^[a-z][a-z0-9]*/))) { if (e.tag !== m[0]) return false; }
      else if ((m = s.match(/^#([\w-]+)/))) { if (e.id !== m[1]) return false; }
      else if ((m = s.match(/^\.([\w-]+)/))) { if (!String(e.className).split(/\s+/).includes(m[1])) return false; }
      else if ((m = s.match(/^\[([\w-]+)(?:=(?:"([^"]*)"|([^\]]*)))?\]/))) {
        const have = attrOf(e, m[1]);
        if (have === undefined) return false;
        const want = m[2] !== undefined ? m[2] : m[3];
        if (want !== undefined && have !== want) return false;
      }
      else if ((m = s.match(/^:checked/))) { if (!(e.checked || e.selected)) return false; }
      else throw new Error("selector not supported by the fake DOM: " + sel);
      s = s.slice(m[0].length);
    }
    return true;
  }
  function matches(e, sel) {
    const parts = sel.trim().split(/\s+/);
    if (!matchesOne(e, parts.pop())) return false;
    let p = e.parentElement;
    while (parts.length) {
      while (p && !matchesOne(p, parts[parts.length - 1])) p = p.parentElement;
      if (!p) return false;
      parts.pop(); p = p.parentElement;
    }
    return true;
  }
  function build(node) {
    const e = new El(node.tag, node.attrs, node.text);
    for (const c of node.children) e.appendChild(build(c));
    return e;
  }

  ROOT = build(tree);
  const document = {
    getElementById: id => ROOT.descendants().find(e => e.id === id) || null,
    querySelector: sel => ROOT.querySelector(sel),
    querySelectorAll: sel => ROOT.querySelectorAll(sel),
    createElement: tag => new El(tag, {}, ""),
    createTextNode: text => { const e = new El("#text", {}, String(text)); return e; },
  };
  return { root: ROOT, document, El };
}

module.exports = { createDom };
