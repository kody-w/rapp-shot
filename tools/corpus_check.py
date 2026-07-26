#!/usr/bin/env python3
"""Two-directional detector corpus: what MUST be caught, and what MUST be left alone.

Round 4 proved the detector was tuned in one direction only. Every fixture in the
suite was a credential, so nothing could ever measure over-redaction — and
`redact --auto` on a screenshot of an ordinary log erased six lines out of seven
and printed "verified". Redaction is per OCR line, so one false positive costs
the whole line; a detector that is loud in both directions is not a nice-to-have.

Run directly:  python3 tools/corpus_check.py [-v]
Exit 0 only when both directions are perfect.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
import detect  # noqa: E402

HEX32 = "0123456789abcdef" * 2
HEX40 = "a3f5" * 10
B64 = "aHVudGVyMmh1bnRlcjJodW50ZXJ5b3VjYW50c2VlbWU="

# ---- MUST BE DETECTED ---------------------------------------------------
SECRETS = [
    "TWILIO_AUTH_" + "TOKEN=" + HEX32,
    "AWS_SECRET_ACCESS_" + "KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    "key: " + HEX32,
    "api_key = '" + HEX32 + "'",
    '{"client_' + 'secret": "' + HEX32 + '"}',
    "password: " + B64,
    "https://api.example.com/v1/x?access_" + "token=" + HEX32,
    HEX40.upper(),
    # assembled from fragments so this file does not itself carry a
    # credential-SHAPED literal — the repo's own publishing gate rejects one,
    # and a project that teaches you to bypass that gate has lost the plot
    "Authorization: Bearer " + "ey" + "JhbGciOiJIUzI1NiJ9" + "."
    + "eyJzdWIiOiIxMjM0NTY3ODkwIn0" + "." + "abcdefghijklmno",
    "postgres://admin:" + "s3cr3tP" + "assw0rd@db.example.com:5432/prod",
    "DefaultEndpointsProtocol=https;AccountName=x;AccountKey=" + B64 + ";",
    "-----" + "BEGIN RSA PRIVATE KEY" + "-----",
    "xoxb-" + "123456789012-1234567890123-" + "AbCdEfGhIjKlMnOpQrStUvWx",
    "sk_live_" + "51H8xKfL2mNpQrStUvWxYz01",
    "/var/run/secrets/" + HEX32,
    "AZURE_CLIENT_" + "SECRET=" + "8Q~" + HEX32[:31],
    # THRESHOLD CASES. Round 4 showed a one-character change to min_entropy
    # (3.0 -> 4.6) made the detector miss real credentials while the whole suite
    # stayed green — every fixture sat far from every threshold, so no constant
    # was actually under test. These sit just inside the boundaries.
    "user=root pass=" + "Tq7vNs2wLd9xRb4mHc6yKf3zPa8uJe5g",      # entropy just over 3.0
    "Authorization: Basic " + B64,                                # bare base64 after a label
    "auth_token: " + HEX32[:24],                                  # 24 hex, the labelled floor
    "GITHUB_" + "TOKEN=gh" + "p_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6",
    # DISCRIMINATING FIXTURES. Each of these is reachable through exactly ONE
    # mechanism, so a mutation to that mechanism cannot hide behind a redundant
    # pattern. Round 4 showed five mutants surviving precisely because every
    # fixture was catchable three different ways.
    #
    # only via SECRET_LABEL's letter-boundary (a label after `_`, with the value
    # not adjacent, so no `[:=]` pattern can fire) AND the 14-char labelled floor
    "AWS_SECRET rotated to Xk7Qz2Rw9Tb4Vn5Lm",
    # only via the labelled 2-class relaxation: lowercase+digits, non-hex
    "AWS_SECRET rotated to xk7qz2rw9tb4vn5lmz8p",
    # only via the unlabelled shape rule at min_len=20 / min_entropy=3.0
    "Xk7Qz2Rw9Tb4Vn5Lm8Pj3Cd",
]

# Fixtures that must be recognised AS A SPECIFIC THING. Detection alone is not
# enough here: a homoglyph-mangled PAT is still caught as a generic
# "high-entropy run" with normalisation disabled, so asserting only "something
# was found" let the homoglyph mutant survive. The LABEL is the assertion.
LABELLED = [
    ("gh" + "p_9zQ7LmN4bV2cD8fH1jKЗpR5sT6uW0xY2aB", "github token"),
    ("sk" + "-abcdefghijklmnopqrstuvwx" + "×" + "0123", "openai-style key"),
    ("AK" + "IA" + "IOSFODNN7" + "EXAMPLE", "aws access key"),
    ("postgres://admin:" + "s3cr3tP" + "assw0rd@db.example.com:5432/prod",
     "credentials in a connection URL"),
]

# ---- MUST BE LEFT ALONE -------------------------------------------------
BENIGN = [
    # timestamps: the single most common thing on a developer's screen
    "2026-07-26T01:20:31Z INFO  boot: loading configuration",
    "2026-07-26 01:20:33.481 WARN  db: retrying connection",
    "2026-07-26T01:20:35.123456Z ERROR api: order 88214 failed",
    # paths
    "/var/folders/kx/8vv6qk1n0dq2rb_3xyzq7c400000gn/T/build.log",
    "/Users/someone/Library/Application Support/Example/cache",
    "~/Documents/GitHub/rapp-tower/work/2026-07-18-tower-blindspot-r2/HANDOFF.md",
    "/Users/x/Library/Containers/3f2504e0-4f89-11d3-9a0c-0305e82c3301/Data",
    "/opt/homebrew/Cellar/python@3.14/3.14.4_1/Frameworks/Python.framework",
    # identifiers that look scary and are not
    "run id 3f2504e0-4f89-11d3-9a0c-0305e82c3301 is not a secret",
    "com.example.internal.service.AuthenticationTokenProvider",
    "org.apache.commons.configuration2.PropertiesConfiguration",
    # ordinary commands and prose
    "kubectl get pods -n production --field-selector=status.phase=Running",
    "docker compose -f docker-compose.production.yml up --detach",
    "the quarterly report is attached and the pricing review is Thursday",
    "https://github.com/kody-w/rapp-shot/blob/main/README.md",
    "npm install --save-dev @typescript-eslint/eslint-plugin",
    "summary: 3 warnings, 1 error, deploy blocked",
    "git checkout -b feature/redaction-false-positives",
]

# Content-addressed digests are deliberately NOT in either list: a git SHA and a
# real 40-hex API key are indistinguishable by shape, and this tool's stated bias
# is that a false redaction costs a re-shot while a missed credential costs a
# rotation. They are reported separately so the trade-off stays visible.
POLICY = [
    "commit 9f8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c",
    "sha256:" + HEX32 + HEX32,
]


def main():
    verbose = "-v" in sys.argv
    missed, over = [], []
    for s in SECRETS:
        if not detect.find(s):
            missed.append(s)
        elif verbose:
            print(f"  detect  {detect.find(s)[0][1]:<28} {s[:56]}")
    for s in BENIGN:
        hits = detect.find(s)
        if hits:
            over.append((s, hits))

    mislabelled = []
    for text, want in LABELLED:
        labels = [lab for _run, lab in detect.find(text)]
        if want not in labels:
            mislabelled.append((text, want, labels))
        elif verbose:
            print(f"  label   {want:<28} {text[:56]}")

    print(f"\ndetection   {len(SECRETS) - len(missed)}/{len(SECRETS)} credentials found")
    for s in missed:
        print(f"  MISSED    {s[:78]}")
    print(f"precision   {len(BENIGN) - len(over)}/{len(BENIGN)} benign lines left alone")
    for s, hits in over:
        print(f"  FALSE POS {s[:60]}")
        for run, label in hits[:2]:
            print(f"              -> {label}: {run[:52]}")

    print(f"labelling   {len(LABELLED) - len(mislabelled)}/{len(LABELLED)} "
          f"recognised as the right KIND of secret")
    for text, want, got in mislabelled:
        print(f"  WRONG     {text[:52]}")
        print(f"              wanted {want!r}, got {got or 'nothing'}")

    flagged = sum(1 for s in POLICY if detect.find(s))
    print(f"policy      {flagged}/{len(POLICY)} content digests flagged "
          f"(expected — shape-identical to real keys)")

    if missed or over or mislabelled:
        print("\nCORPUS FAILED")
        return 1
    print("\ncorpus clean in both directions")
    return 0


if __name__ == "__main__":
    sys.exit(main())
