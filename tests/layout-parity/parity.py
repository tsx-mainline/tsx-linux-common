#!/usr/bin/env python3
"""parity.py: run tsx-layout-check (check_text) on a file and print the
result in the form of parity.cpp: the warnings, the card errors as warnings
with "(left out)", the file error, and the placed cards."""
import importlib.machinery
import importlib.util
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
path = os.path.join(here, "..", "..", "panel-app", "usr", "local", "bin", "tsx-layout-check")
loader = importlib.machinery.SourceFileLoader("tsx_layout_check", path)
spec = importlib.util.spec_from_loader("tsx_layout_check", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)

with open(sys.argv[1], encoding="utf-8", errors="replace") as f:
    text = f.read()
# No icon list: the app does not check icons against the font when it parses.
layout, errors, warnings = mod.check_text(text, icons=set())
lines = []
for w in warnings:
    if "is not in the icon font" in w:
        continue
    lines.append("warning: " + w)
if layout is None:
    for e in errors:
        lines.append("error: " + e)
else:
    for e in errors:
        lines.append("warning: " + e + " (left out)")
    for p, page in enumerate(layout["pages"], 1):
        for c in page["cards"]:
            lines.append("card %d %s %d %d %d %d" % (p, c["type"], c["x"], c["y"], c.get("w", 1), c.get("h", 1)))
print("\n".join(lines))
