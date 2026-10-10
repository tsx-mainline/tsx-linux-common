#!/usr/bin/env python3
"""compare.py APP CHECK: compare the outputs of parity.cpp and parity.py.
The warnings compare as a multiset, the cards in order. The text of a JSON
syntax error differs between the two parsers, so only its start counts."""
import sys


def load(path):
    warn, err, cards = [], [], []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f.read().splitlines():
            if line.startswith("warning: "):
                warn.append(line)
            elif line.startswith("error: "):
                err.append("error: not valid JSON" if line.startswith("error: not valid JSON") else line)
            elif line.startswith("card "):
                cards.append(line)
            elif line.strip():
                err.append("other: " + line)
    return sorted(warn), err, cards


a, b = load(sys.argv[1]), load(sys.argv[2])
if a == b:
    sys.exit(0)
for name, x, y in zip(("warnings", "errors", "cards"), a, b):
    if x != y:
        print(f"{name}: app {x}")
        print(f"{name}: checker {y}")
sys.exit(1)
