#!/usr/bin/env bash
# Mutation-adequacy oracle for the detector.
#
# WHY THIS EXISTS. Round 3 added credential fixtures and declared the detector
# tested. Round 4 applied seven single-line mutations to detect.py and four of
# them — including reverting BOTH of the original root causes and deleting
# homoglyph normalisation entirely — left the suite at "39 passed, 0 failed".
# One of them (min_entropy 3.0 -> 4.6) made the tool miss real credentials with
# the suite fully green.
#
# A green suite is only evidence if it can go red. This flips each load-bearing
# constant and asserts the corpus notices. Any SURVIVED line is a hole in the
# fixtures, not a pass.
#
#   tools/mutate.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$HERE/.."

BACKUP=$(mktemp)
cp detect.py "$BACKUP"
restore() { cp "$BACKUP" detect.py; }
trap restore EXIT INT TERM

killed=0; survived=0; expected=0
mutate() {
  local name="$1" py="$2"
  restore
  python3 - "$py" <<'PY'
import sys
src = open("detect.py").read()
old, new = sys.argv[1].split("|||")
if old not in src:
    print(f"ANCHOR-MISSING: {old[:50]}", file=sys.stderr)
    raise SystemExit(9)
open("detect.py", "w").write(src.replace(old, new, 1))
PY
  if [ $? = 9 ]; then
    printf '  \033[33mSKIP  \033[0m %-46s anchor not found\n' "$name"
    return
  fi
  if python3 tools/corpus_check.py >/dev/null 2>&1; then
    printf '  \033[31mSURVIVED\033[0m %-44s corpus stayed green\n' "$name"
    survived=$((survived+1))
  else
    printf '  \033[32mkilled\033[0m   %-44s corpus went red\n' "$name"
    killed=$((killed+1))
  fi
}

expect_survive() {
  local name="$1" py="$2"
  restore
  python3 - "$py" <<'PY'
import sys
src = open("detect.py").read()
old, new = sys.argv[1].split("|||")
if old not in src:
    raise SystemExit(9)
open("detect.py", "w").write(src.replace(old, new, 1))
PY
  if python3 tools/corpus_check.py >/dev/null 2>&1; then
    printf '  \033[36mexpected\033[0m %-44s survives (redundant guard)\n' "$name"
    expected=$((expected+1))
  else
    printf '  \033[32mkilled\033[0m   %-44s went red (guard is load-bearing)\n' "$name"
    killed=$((killed+1))
  fi
}

echo "Mutation testing detect.py against tools/corpus_check.py"
echo

mutate "letter-boundary lookaheads -> \\b (R1 cause #1)" \
  '_L = r"(?<![A-Za-z])"|||_L = r"\b"'
mutate "class floor back to 3 always (R1 cause #2)" \
  'mixed = _classes(core) >= (2 if after_label else 3)|||mixed = _classes(core) >= 3'
mutate "raise min_entropy 3.0 -> 4.6" \
  'def shape_hits(text, min_len=20, min_entropy=3.0):|||def shape_hits(text, min_len=20, min_entropy=4.6):'
mutate "raise unlabelled min_len 20 -> 34" \
  'def shape_hits(text, min_len=20, min_entropy=3.0):|||def shape_hits(text, min_len=34, min_entropy=3.0):'
mutate "disable homoglyph normalisation" \
  'out = "".join(_HOMOGLYPHS.get(ch, ch) for ch in s)|||out = s'
mutate "drop the long-hex branch" \
  'if _HEXY.match(core) and len(core) >= (24 if after_label else 32):|||if False:'
mutate "raise the opaque-segment floor 20 -> 44" \
  'if len(seg) < min_len:|||if len(seg) < 44:'
mutate "raise the opaque-segment entropy 3.4 -> 4.8" \
  'return entropy(seg) >= 3.4 and _classes(seg) >= 2|||return entropy(seg) >= 4.8 and _classes(seg) >= 2'
mutate "widen the run regex floor 12 -> 46" \
  'for run in re.findall(r"[^\s'"'"'\"`,;()\[\]{}<>]{12,}", text):|||for run in re.findall(r"[^\s'"'"'\"`,;()\[\]{}<>]{46,}", text):'
mutate "treat every run as benign (precision-only mutant)" \
  'def _is_benign(core):|||def _is_benign(core):\n    return True'
# EXPECTED SURVIVOR, recorded rather than hidden. Removing the _TIMESTAMPY
# exemption does NOT reintroduce the bug, because the segment decomposition
# added alongside it already refuses "2026-07-26T01:20:31Z" (every piece is
# short or numeric). The guard is defence-in-depth, so no fixture can kill this
# mutant without also being killed by the decomposition. Listing it as expected
# keeps the survivor count honest instead of deleting an inconvenient test.
expect_survive "removing _TIMESTAMPY (redundant with segment decomposition)" \
  'if _UUID.match(core) or _TIMESTAMPY.match(core):|||if _UUID.match(core):'

restore
echo
echo "$killed killed, $survived survived, $expected expected-survivor(s)"
if [ "$survived" != 0 ]; then
  echo "A surviving mutant means the corpus cannot detect that defect class." >&2
  echo "Add a fixture at that threshold rather than lowering the bar." >&2
  exit 1
fi
echo "corpus is mutation-adequate for every load-bearing constant"
