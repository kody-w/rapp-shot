"""Secret detection over OCR text — homoglyph-tolerant, shape-based.

WHY THIS EXISTS, and why the obvious approach is wrong.

The first version matched anchored regexes like `\\bgh[pousr]_[A-Za-z0-9]{16,}\\b`
straight against Vision's output. That fails on exactly the strings it most needs
to catch. Apple Vision substitutes homoglyphs inside high-entropy runs, because a
random character sequence gives the language model no context to correct against:

    rendered   GITHUB_TOKEN=gh|_9zQ7LmN4bV2cD8fH1jK3pR5sT6uW...
    Vision     GITHUB_ТOКЕN=gh|_9zQ7LmN4bV2cD8fH1jKЗpR5sT6uW...
                     ^  ^^                        ^
                     Cyrillic Т К Е              Cyrillic З (U+0417)

    (the prefix is masked above so this file does not itself trip a credential
    scanner — a repo that ships secret-shaped literals teaches people to bypass
    the gate that would have caught a real one)

`[A-Za-z0-9]{16,}` breaks at the first Cyrillic character, the token is not
detected, and the tool then reports "N region(s) painted out, opaque and
irreversible" — which reads as an all-clear and invites you to share the image.
That is worse than reporting nothing, because it manufactures confidence.

So detection here does two things instead:

  1. NORMALISE homoglyphs to ASCII before matching, so the anchored patterns work
     on what was actually on screen rather than on what the OCR mangled.
  2. Match on SHAPE, not just charset — a long, mixed-class, space-free run is a
     credential whether or not it survived OCR intact, and doubly so when it sits
     after a `token`/`key`/`secret` label.

The bias is deliberate and stated in the README: a false redaction costs a
re-shot, a missed credential costs a rotation.
"""

import math
import re
import unicodedata

# Confusables Vision actually emits in place of ASCII. Kept explicit rather than
# pulling a full Unicode confusables table: this is the set observed on real
# captures, and an explicit map is auditable.
_HOMOGLYPHS = {
    # Cyrillic that looks Latin
    "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O",
    "Р": "P", "С": "C", "Т": "T", "У": "Y", "Х": "X", "З": "3", "б": "6",
    "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "х": "x", "у": "y",
    "І": "I", "і": "i", "Ј": "J", "ј": "j", "Ѕ": "S", "ѕ": "s",
    # Greek
    "Α": "A", "Β": "B", "Ε": "E", "Ζ": "Z", "Η": "H", "Ι": "I", "Κ": "K",
    "Μ": "M", "Ν": "N", "Ο": "O", "Ρ": "P", "Τ": "T", "Υ": "Y", "Χ": "X",
    "ο": "o", "ν": "v",
    # symbols Vision swaps into alphanumeric runs
    "×": "x", "Ø": "0", "О": "O", "‚": ",", "’": "'", "‘": "'",
    "“": '"', "”": '"', "–": "-", "—": "-", "−": "-", "|": "l", "¦": "l",
    "０": "0", "１": "1", "２": "2", "３": "3", "４": "4",
    "５": "5", "６": "6", "７": "7", "８": "8", "９": "9",
}

SECRET_LABEL = re.compile(
    r"(?i)\b(api[\s_-]?key|secret|password|passwd|passphrase|token|bearer|"
    r"credential|auth|private[\s_-]?key|access[\s_-]?key|client[\s_-]?secret)\b")

# Runs that are plainly not credentials, so shape-matching does not flag them.
_BENIGN = re.compile(
    r"(?i)^(https?://|/|~|\.{1,2}/|[a-z]+\.(com|org|net|io|dev|ai)$)")

PATTERNS = [
    (r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b", "email"),
    (r"\bgh[pousr]_[A-Za-z0-9]{16,}\b", "github token"),
    (r"\bsk-[A-Za-z0-9-]{20,}\b", "openai-style key"),
    (r"\bAKIA[0-9A-Z]{16}\b", "aws access key"),
    (r"\bey[JA-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.", "jwt"),
    (r"(?i)\bBearer\s+[A-Za-z0-9._~+/-]{16,}", "bearer token"),
    (r"(?i)\b(api[_-]?key|secret|password|passwd|token)\b\s*[:=]\s*\S{6,}",
     "labelled secret"),
    (r"\b(?:\d[ -]*?){13,16}\b", "card-like number"),
    (r"\b\d{3}-\d{2}-\d{4}\b", "ssn-like"),
]


def normalize(s):
    """Map homoglyphs to ASCII and strip combining marks, so a pattern written in
    ASCII can match text an OCR mangled."""
    out = "".join(_HOMOGLYPHS.get(ch, ch) for ch in s)
    out = unicodedata.normalize("NFKD", out)
    return "".join(c for c in out if not unicodedata.combining(c))


def entropy(s):
    if not s:
        return 0.0
    counts = {}
    for c in s:
        counts[c] = counts.get(c, 0) + 1
    n = float(len(s))
    return -sum((c / n) * math.log2(c / n) for c in counts.values())


def _classes(s):
    return sum([
        any(c.islower() for c in s),
        any(c.isupper() for c in s),
        any(c.isdigit() for c in s),
        any(not c.isalnum() for c in s),
    ])


def shape_hits(text, min_len=20, min_entropy=3.0):
    """Credential-SHAPED runs, independent of charset. Catches a mangled key that
    every anchored pattern misses."""
    hits = []
    labelled = bool(SECRET_LABEL.search(text))
    for run in re.findall(r"[^\s'\"`,;()\[\]{}<>]{12,}", text):
        core = run.strip(".,:;=")
        if len(core) < 12 or _BENIGN.match(core):
            continue
        after_label = labelled and SECRET_LABEL.search(
            text[:text.find(run)] or "") is not None
        long_enough = len(core) >= (14 if after_label else min_len)
        mixed = _classes(core) >= (2 if after_label else 3)
        if long_enough and mixed and entropy(core) >= (
                2.6 if after_label else min_entropy):
            hits.append((core, "labelled high-entropy run" if after_label
                         else "high-entropy run"))
    return hits


def find(text, extra_patterns=()):
    """Return [(matched_text, label)] for one OCR line."""
    norm = normalize(text)
    found = []
    for rx, label in list(PATTERNS) + list(extra_patterns):
        try:
            for m in re.finditer(rx, norm):
                found.append((m.group(0), label))
        except re.error:
            continue
    for run, label in shape_hits(norm):
        if not any(run in f for f, _ in found):
            found.append((run, label))
    return found


def still_present(needle, haystack):
    """Is a detected secret still readable in re-OCR'd text? Compared after
    normalisation so an OCR that mangles it differently the second time cannot
    be mistaken for a successful redaction."""
    n = re.sub(r"\s+", "", normalize(needle))
    h = re.sub(r"\s+", "", normalize(haystack))
    if len(n) < 8:
        return n in h
    # a long run counts as surviving if a substantial slice of it is readable
    probe = n[:max(12, len(n) // 2)]
    return probe in h
