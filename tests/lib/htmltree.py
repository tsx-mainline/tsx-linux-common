#!/usr/bin/env python3
"""htmltree.py: split a page into a tree and its script, for the node tests.

  htmltree.py OUTDIR --file PAGE.html
  htmltree.py OUTDIR --setupd TSX-SETUPD PLUGIN-DIR

It writes OUTDIR/tree.json (the elements, without script and style) and
OUTDIR/page.js (the text of the script). With --setupd, the page is the setup
page that tsx-setupd builds with the plugins of PLUGIN-DIR. Importing
tsx-setupd starts no server. The caller sets TSX_SETUP_CONF, TSX_RUN_DIR and
the other variables of tsx-setupd.
"""
import importlib.machinery
import json
import sys
from html.parser import HTMLParser

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


def main(argv):
    out = argv[1]
    if argv[2] == "--file":
        html = open(argv[3], encoding="utf-8").read()
    elif argv[2] == "--setupd":
        import os
        os.environ["TSX_SETUP_PLUGIN_DIR"] = argv[4]
        d = importlib.machinery.SourceFileLoader("setupd", argv[3]).load_module()
        assert d.PLUGINS, "no plugin loaded from " + argv[4]
        html = d.PAGE
    else:
        sys.exit("usage: see the docstring")
    t = Tree()
    t.feed(html)
    json.dump(t.root, open(out + "/tree.json", "w"))
    open(out + "/page.js", "w").write("".join(t.script))


if __name__ == "__main__":
    main(sys.argv)
