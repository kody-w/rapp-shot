#!/usr/bin/env python3
"""Assert the detector survives what Vision actually does to secrets.

Vision substitutes homoglyphs inside high-entropy runs, because random characters
give its language model nothing to correct against. The first fixture in this
suite passed BY LUCK — its corruption landed one character past the {16,}
threshold — while the real tool shipped an image with a legible GitHub PAT. These
cases use the exact substitutions observed on real captures, so a threshold can
no longer hide the failure.
"""
import sys

sys.path.insert(0, sys.argv[1] if len(sys.argv) > 1 else ".")
import detect  # noqa: E402

MANGLED = [
    ("cyrillic ZE inside a PAT",
     "GITHUB_TOKEN=" + "gh" + "p_9zQ7LmN4bV2cD8fH1jK\u0417pR5sT6uWQyA2bC4"),
    ("cyrillic A and X inside an API key",
     "OPENAI_\u0410PI_KEY=sk-proj4Hn8Kq2Lm9Pz7\u0425vW3Bw6Ty1Rd5FgQJs8Ac"),
    ("multiplication sign and slashed O mid-run",
     "token: aB3\u00d79zQ\u00d8Lm4bV2cD8fH1jK5pR"),
    ("pipe substituted for lowercase L",
     "api_key: aB3x9zQ|Lm4bV2cD8fH1jK5pRs"),
]
BENIGN = [
    "the quarterly report is attached",
    "https://github.com/kody-w/rapp-shot",
    "meeting notes for the pricing review",
    "/Users/someone/Documents/project/readme.md",
]

bad = 0
for label, text in MANGLED:
    hits = detect.find(text)
    print(("       ok   " if hits else "       MISS ") + label
          + (f"  -> {hits[0][1]}" if hits else ""))
    bad += 0 if hits else 1
for text in BENIGN:
    hits = detect.find(text)
    if hits:
        print(f"       FALSE POSITIVE on {text[:44]!r} -> {hits}")
        bad += 1
    else:
        print(f"       ok   left alone: {text[:44]}")
sys.exit(1 if bad else 0)
