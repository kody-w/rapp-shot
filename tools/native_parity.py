#!/usr/bin/env python3
"""Compare the compiled native detector with the original, including its seeded trial.

Only generated text is sent to a local diagnostic executable. No screen capture,
clipboard access, user state, or network service is involved.
"""
import base64
import json
from pathlib import Path
import random
import subprocess
import sys

import corpus_check as corpus


def main():
    root = Path(__file__).resolve().parent.parent
    executable = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "native/.build/debug/RAPPShot"
    fixtures = list(corpus.SECRETS) + list(corpus.BENIGN) + list(corpus.POLICY)
    fixtures += [text for text, _ in corpus.LABELLED]
    rng = random.Random(corpus.TRIAL_SEED)
    frames = [
        lambda key: key,
        lambda key: '    "SecretAccessKey": "%s",' % key,
        lambda key: "SecretAccessKey    %s" % key,
        lambda key: "AWS_SECRET_ACCESS_KEY=%s" % key,
    ]
    for frame in frames:
        for _ in range(corpus.TRIAL_N):
            key = base64.b64encode(bytes(rng.getrandbits(8) for _ in range(30))).decode()[:40]
            fixtures.append(frame(key))
    result = subprocess.run([str(executable), "--detect-lines"], input=json.dumps(fixtures),
                            text=True, capture_output=True, timeout=60)
    if result.returncode:
        print(result.stderr, file=sys.stderr)
        return result.returncode
    responses = json.loads(result.stdout)
    if len(responses) != len(fixtures):
        raise AssertionError("Native diagnostic omitted fixture results")
    mismatches = []
    for index, (text, response) in enumerate(zip(fixtures, responses)):
        expected = sorted({label for _, label in corpus.detect.find(text)})
        if response.get("labels") != expected:
            mismatches.append((index, expected, response.get("labels")))
    for index, expected, actual in mismatches[:20]:
        print(f"Fixture {index}: expected labels {expected}, got {actual}", file=sys.stderr)
    if mismatches:
        print(f"FAIL: {len(mismatches)} detector parity mismatches", file=sys.stderr)
        return 1
    print(f"PASS: {len(fixtures)}/{len(fixtures)} native/Python fixture label sets match exactly")
    return 0


if __name__ == "__main__":
    sys.exit(main())
