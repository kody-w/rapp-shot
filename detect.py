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

# NOT \b. `\b` does not fire between `_` and a letter, so it never matched a
# SCREAMING_SNAKE env var — TWILIO_AUTH_TOKEN, AWS_SECRET_ACCESS_KEY — which is
# the single most common way a credential appears on a developer's screen. That
# made the whole relaxed "labelled" branch below dead code in practice.
# Letter-boundaries instead, so `_`, `-`, `.` and `=` all count as separators.
_L = r"(?<![A-Za-z])"
_R = r"(?![A-Za-z])"
SECRET_LABEL = re.compile(
    r"(?i)" + _L + r"(api[\s_.-]?key|secret|password|passwd|passphrase|token|"
    r"bearer|credential|auth|key|private[\s_.-]?key|access[\s_.-]?key|"
    r"client[\s_.-]?secret|conn(ection)?[\s_.-]?str(ing)?)" + _R)

# Canonical UUID: a well-known NON-secret shape. Excluded explicitly so the
# shape rule stops destroying run ids while missing the key beside them.
_UUID = re.compile(
    r"(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
_HEXY = re.compile(r"(?i)^[0-9a-f]{24,}$")

# Runs that are plainly not credentials, so shape-matching does not flag them.
# Paths matter here beyond the leading character: a whitespace-split run can start
# mid-path ("Support/com.example.App/cache"), so anything containing a separator
# whose segments are all ordinary words is treated as a path, not a secret.
_BENIGN = re.compile(
    r"(?i)^(https?://|/|~|\.{1,2}/|[a-z]+\.(com|org|net|io|dev|ai)$)")
_PATHY = re.compile(r"^[A-Za-z0-9._~-]+(/[A-Za-z0-9._~-]+)+/?$")
_REV_DNS = re.compile(r"^[a-z]{2,}(\.[A-Za-z0-9-]{2,}){2,}$")


def _hidden_secret_segment(core):
    """A credential-shaped segment inside a path or URL. `/var/run/secrets/<hex>`
    is a path AND a leak; the path check must not short-circuit past it."""
    for seg in re.split(r"[/.?&=]", core):
        seg = seg.strip()
        if len(seg) >= 24 and (_HEXY.match(seg) or entropy(seg) >= 3.4):
            return seg
    return None


def _is_benign(core):
    """True when the run is a path, URL or reverse-DNS identifier AND carries no
    credential-shaped segment of its own."""
    if _UUID.match(core):
        return True
    if not (_BENIGN.match(core) or _PATHY.match(core) or _REV_DNS.match(core)):
        return False
    return _hidden_secret_segment(core) is None

PATTERNS = [
    (r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b", "email"),
    (r"\bgh[pousr]_[A-Za-z0-9]{16,}\b", "github token"),
    (r"\bsk-[A-Za-z0-9-]{20,}\b", "openai-style key"),
    (r"(?i)\b(sk|pk|rk)_(live|test)_[A-Za-z0-9]{10,}\b", "stripe-style key"),
    (r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b", "slack token"),
    (r"(?i)\b(SG|AC|SK)[0-9a-f]{20,}\b", "vendor id/secret"),
    (r"-----BEGIN [A-Z ]*PRIVATE KEY-----", "private key block"),
    # a credential carried in a URL query parameter
    (r"(?i)[?&](access_token|api_key|apikey|token|key|password|sig|signature)"
     r"=[A-Za-z0-9._~+/%-]{8,}", "token in a URL"),
    # LABEL = <long opaque value>, including SCREAMING_SNAKE env-var form
    (r"(?i)(?<![A-Za-z])(api[\s_.-]?key|secret|password|passwd|token|bearer|"
     r"credential|auth[\s_.-]?token|access[\s_.-]?key|key)(?![A-Za-z])"
     r"\s*[:=]\s*[\"\']?([A-Za-z0-9._~+/=-]{12,})", "labelled credential value"),
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
    """Credential-SHAPED runs, independent of charset.

    The class floor used to be 3 unconditionally, which STRUCTURALLY excluded
    hex: a hex token is lower+digit or upper+digit, never three classes. Every
    32- and 40-character hex API key, Twilio auth token and HMAC secret was
    therefore invisible. Hex of respectable length is now its own case.
    """
    hits = []
    labelled = bool(SECRET_LABEL.search(text))
    for run in re.findall(r"[^\s'\"`,;()\[\]{}<>]{12,}", text):
        core = run.strip(".,:;=")
        if len(core) < 12 or _is_benign(core):
            continue
        # a path that hides a credential: flag the segment, not the whole path
        hidden = _hidden_secret_segment(core) if (
            _BENIGN.match(core) or _PATHY.match(core)) else None
        if hidden:
            hits.append((hidden, "credential inside a path"))
            continue
        before = text[:text.find(run)]
        after_label = labelled and SECRET_LABEL.search(before) is not None

        # long hex is a credential shape in its own right, labelled or not
        if _HEXY.match(core) and len(core) >= (24 if after_label else 32):
            hits.append((core, "hex credential" if after_label
                         else "long hex run"))
            continue

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
