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
# A label may also be an INTERIOR camelCase word — `SecretAccessKey`, `apiKey`,
# `AccountKey` — which is how credentials are named in almost all JSON and YAML.
# Letter-boundaries alone excluded every one of them, so the relaxed "labelled"
# thresholds never applied to the most common config format there is.
_CAMEL_L = r"(?:(?<![A-Za-z])|(?<=[a-z0-9]))"
_CAMEL_R = r"(?:(?![A-Za-z])|(?=[A-Z]))"
SECRET_LABEL = re.compile(
    r"(?i)" + _CAMEL_L + r"(api[\s_.-]?key|secret|password|passwd|passphrase|"
    r"token|bearer|credential|auth|key|private[\s_.-]?key|access[\s_.-]?key|"
    r"client[\s_.-]?secret|conn(ection)?[\s_.-]?str(ing)?)" + _CAMEL_R)

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


# An ISO-8601 timestamp is 20+ characters, three character classes and high
# entropy — indistinguishable from a credential by shape, and the single most
# common string on a developer's screen. Redaction is per OCR LINE, so one of
# these false positives erases the whole log line; a screenshot of an ordinary
# log lost six lines out of seven before this existed.
_TIMESTAMPY = re.compile(
    r"^\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2})?([.,]\d+)?(Z|[+-]\d{2}:?\d{2})?)?$")
_DATEY = re.compile(r"^\d{4}-\d{2}-\d{2}")

# An IPv6 address is long, hex-ish and colon-separated — credential-shaped by
# every rule here. A screenshot of `ifconfig` or `netstat` is a thing people
# share constantly, and losing those lines is the over-redaction this detector
# was corrected for. Zone index and CIDR suffix included.
_IPV6 = re.compile(
    r"(?i)^(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}(%[A-Za-z0-9]+)?(/\d{1,3})?$")

# Separators that structure an identifier. A credential is OPAQUE: its entropy
# lives in one unbroken run. A path, a flag, a dotted class name and a date slug
# all decompose into short or wordlike pieces, and that is what tells them apart
# from a secret — not their overall length or entropy, which are the same.
_SEP = re.compile(r"[/._\-=:?&@+~,;|\\]+")


def _segments(core):
    return [seg for seg in _SEP.split(core) if seg]


# One constant, used everywhere. These were duplicated as a default and a
# call-site literal, so a mutation to either left the other path intact and the
# corpus green — the boundary looked tested and was not.
SEG_FLOOR = 20            # an unlabelled piece must carry the entropy alone
SEG_FLOOR_LABELLED = 14   # next to `secret`/`token`/`key`, the word is evidence


def _segment_is_opaque(seg, min_len=SEG_FLOOR):
    """Is this ONE piece, on its own, credential-shaped?

    min_len drops to 14 next to an explicit `secret`/`token`/`key` label: the
    word is the evidence, so the string does not have to carry it alone. Without
    that relaxation the whole labelled branch below is unreachable for values
    shorter than 20 — which is most human-chosen passwords.
    """
    if len(seg) < min_len:
        return False            # too short to carry a secret's worth of entropy
    if _UUID.match(seg):
        return False
    if _looks_like_a_word(seg):
        # AuthenticationTokenProvider, PropertiesConfiguration — but NOT a
        # 40-character all-letter run, which `seg.isalpha()` used to exempt
        # outright. Two independent rules both had to be wrong for the AWS key
        # to survive; this was the second one.
        return False
    if seg.isdigit():
        return False
    if _HEXY.match(seg):
        return True             # long hex: the R1 class
    return entropy(seg) >= 3.4 and _classes(seg) >= 2


_WORDY = re.compile(r"^[A-Za-z]{2,}$")


# The longest plausible camelCase identifier. `AuthenticationTokenProvider` is
# 27. A 40-character run that happens to alternate case is a base64 key, not a
# name someone typed, and treating it as a word is how an AWS secret survived.
_WORDLIKE_MAX = 30

# What share of a run's characters must sit inside recognisable words before the
# run counts as structured text rather than a credential. Measured: at 0.30, a
# 40-char base64 key is missed 0.2% of the time (from 4.95%) and no path, dotted
# identifier, flag, package-lock line or URL in the corpus is flagged.
WORDLIKE_SHARE = 0.30


def _looks_like_a_word(seg):
    """A piece a human would recognise: `folders`, `Application`, `phase`,
    `Running`, `tower`. Uniform case, or camelCase that splits into real words.
    A run containing one of these is structured text, not an opaque secret.

    Two bugs lived here, and together they let `redact --auto` report "nothing
    matched" on a legible AWS SecretAccessKey:

      * `[A-Z]+[a-z]*` is greedy, so it glued a capitals run onto the following
        lowercase — `ZLTUsjeAc` parsed as one part, the `>= 3 consecutive
        capitals` guard never fired, and a random base64 fragment was scored as
        English. Splitting at EVERY capital makes `Z`,`L`,`T` their own parts,
        and the `len >= 2` rule rejects them, so the guard is now redundant.
      * length was unbounded, so a whole 40-character key could pass as one
        long camelCase name.
    """
    if not seg.isalpha():
        return False
    if seg.islower() or seg.isupper() or seg.istitle():
        return 2 <= len(seg) <= _WORDLIKE_MAX
    if len(seg) > _WORDLIKE_MAX:
        return False
    parts = re.findall(r"[A-Z][a-z]*|[a-z]+", seg)
    return all(len(p) >= 2 for p in parts) and len(parts) >= 2


def _joined_is_opaque(core, floor):
    """Judge the run with its separators removed.

    `wJalrXUtnFEMI/M3ucXiI8+bPxRfiCYEXAMPLEKEY` is one credential that happens
    to contain base64's `/` and `+`; splitting it hid it. Joining is only safe
    when nothing in the run reads as a word — otherwise `/var/folders/...` and
    `com.example.Service` would join into long opaque-looking strings too."""
    segs = _segments(core)
    if len(segs) < 2:
        return False
    # Veto PROPORTIONALLY, not on the first hit. A single accidental two-letter
    # fragment inside a 40-character base64 key — `LP`, `EzYb`, `ijmj` — used to
    # veto the whole run, which is how ~2% of AWS secret keys still slipped past
    # after the greedy-regex fix. A path is mostly words; a key is mostly not.
    wordlike_chars = sum(len(g) for g in segs if _looks_like_a_word(g))
    total = sum(len(g) for g in segs) or 1
    if wordlike_chars / total >= WORDLIKE_SHARE:
        return False
    joined = "".join(segs)
    if len(joined) < floor:
        return False
    if _HEXY.match(joined):
        # hex joined from pieces is only interesting at real key length, or a
        # git SHA split across a dash would qualify
        return len(joined) >= 32
    return entropy(joined) >= 3.4 and _classes(joined) >= 2


def _uniform_groups(core):
    """The licence-key / grouped-token shape: XXXX-XXXX-XXXX-XXXX.

    Several separator-separated groups of the SAME length, alphanumeric, with a
    digit somewhere. A date slug (`2026-07-18-tower-blindspot-r2`) and a dotted
    class name are never uniform, so this cannot readmit them."""
    segs = _segments(core)
    if len(segs) < 3:
        return False
    n = len(segs[0])
    if not 4 <= n <= 8 or any(len(g) != n for g in segs):
        return False
    if not all(g.isalnum() for g in segs):
        return False
    if not any(c.isdigit() for c in core):
        return False
    return entropy("".join(segs)) >= 3.4


def _hidden_secret_segment(core):
    """A credential-shaped segment inside a path or URL. `/var/run/secrets/<hex>`
    is a path AND a leak, so the path check must not short-circuit past it — but
    `/var/folders/kx/8vv6qk1n0dq2rb_3xyzq7c400000gn/T/` is only a path, and the
    old rule (any 24-char segment with entropy >= 3.4) could not tell them apart
    because it split on fewer separators than actually structure a path."""
    for seg in _segments(core):
        if _segment_is_opaque(seg):
            return seg
    # `//registry.npmjs.org/:_authToken=npm_<token>` is a path AND a credential
    if _joined_is_opaque(core, 24) or _uniform_groups(core):
        return core
    return None


def _is_benign(core):
    """True when the run is a timestamp, path, URL or dotted identifier AND
    carries no credential-shaped segment of its own."""
    if _UUID.match(core) or _TIMESTAMPY.match(core) or _IPV6.match(core):
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
    # scheme://user:password@host — the password is short and wordlike, so no
    # shape rule will ever see it; the STRUCTURE is what gives it away.
    (r"(?i)\b[a-z][a-z0-9+.-]*://[^\s:/@]+:[^\s:/@]{4,}@[^\s/]+",
     "credentials in a connection URL"),
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
            _BENIGN.match(core) or _PATHY.match(core)
            or _REV_DNS.match(core)) else None
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

        # A run only counts as a credential if some SINGLE piece of it is
        # opaque. Without this, `--field-selector=status.phase=Running`,
        # `com.example.service.AuthenticationTokenProvider` and every dated
        # path slug scored as high-entropy runs and were painted out.
        # Judge the PIECES, never the whole run: a separator-joined string is
        # long and mixed-class by construction, so testing `core` itself let
        # `--field-selector=status.phase=Running` back in through the same door
        # the decomposition was built to close. _segments() of a run with no
        # separator is [run], so a bare opaque token is still caught.
        seg_floor = SEG_FLOOR_LABELLED if after_label else SEG_FLOOR
        by_segment = any(_segment_is_opaque(g, seg_floor) for g in _segments(core))
        by_joined = _joined_is_opaque(core, seg_floor)
        by_groups = _uniform_groups(core)
        if not (by_segment or by_joined or by_groups):
            continue
        # A uniform grouped key is a recognised SHAPE, so it does not have to
        # clear the generic length floor as well. `A1B2-C3D4-E5F6-G7H8` is 19
        # characters — _uniform_groups returned True for the docstring's own
        # example and find() still returned nothing.
        long_enough = (len(core) >= (14 if after_label else min_len)
                       or (by_groups and len(core) >= 15))
        # An all-LETTER credential can only ever be 2 classes, exactly like hex
        # — the same structural exclusion that hid every hex key in round 1. A
        # 40-character opaque run does not need a third class to be a secret.
        long_opaque = any(len(g) >= 32 and _segment_is_opaque(g)
                          for g in _segments(core))
        floor = 2 if (after_label or long_opaque) else 3
        mixed = _classes(core) >= floor
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
