#!/usr/bin/env python3
"""mkicons.py: write the icon table of the panel app from the icon list.

  mkicons.py           write components/tsx_cards/icons.h and icon-glyphs.yaml
  mkicons.py --check   exit with 1 when one of the two files is not up to date

The list is panel-app/usr/local/share/tsx/panel-app/icons.txt: one icon on
each line, the MDI name and the code point in hex. icons.h is a table sorted
by name (the app looks up a name with a binary search). icon-glyphs.yaml is
the glyph list of the ESPHome icon font. The font holds only these glyphs, so
the two files must agree.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "usr", "local", "share", "tsx", "panel-app", "icons.txt")
OUT_H = os.path.join(HERE, "components", "tsx_cards", "icons.h")
OUT_YAML = os.path.join(HERE, "icon-glyphs.yaml")


def read_icons(path):
    icons = {}
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            m = re.fullmatch(r"([a-z0-9-]+)\s+F([0-9A-F]{4})", line)
            if not m:
                sys.exit(f"{path}:{n}: bad line: {line}")
            if m.group(1) in icons:
                sys.exit(f"{path}:{n}: icon {m.group(1)} is listed twice")
            icons[m.group(1)] = int("F" + m.group(2), 16)
    return dict(sorted(icons.items()))


def render_h(icons):
    out = [
        "// icons.h: written by mkicons.py from icons.txt. Do not edit.",
        "// The MDI icons of the panel app, sorted by name.",
        "#pragma once",
        "#include <cstdint>",
        "",
        "namespace esphome {",
        "namespace tsx_cards {",
        "",
        "struct IconEntry {",
        "  const char *name;",
        "  uint32_t code;",
        "};",
        "",
        "static const IconEntry ICONS[] = {",
    ]
    out += [f'    {{"{name}", 0x{code:05X}}},' for name, code in icons.items()]
    out += [
        "};",
        "",
        "}  // namespace tsx_cards",
        "}  // namespace esphome",
        "",
    ]
    return "\n".join(out)


def render_yaml(icons):
    out = ["# icon-glyphs.yaml: written by mkicons.py from icons.txt. Do not edit."]
    out += [f'- "\\U{code:08X}"  # {name}' for name, code in icons.items()]
    return "\n".join(out) + "\n"


def main():
    icons = read_icons(SRC)
    want = {OUT_H: render_h(icons), OUT_YAML: render_yaml(icons)}
    if sys.argv[1:] == ["--check"]:
        bad = 0
        for path, text in want.items():
            try:
                with open(path, encoding="utf-8") as f:
                    same = f.read() == text
            except OSError:
                same = False
            if not same:
                print(f"{os.path.relpath(path, HERE)} is not up to date: run mkicons.py")
                bad = 1
        sys.exit(bad)
    if sys.argv[1:]:
        sys.exit(__doc__)
    for path, text in want.items():
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
    print(f"{len(icons)} icons")


if __name__ == "__main__":
    main()
