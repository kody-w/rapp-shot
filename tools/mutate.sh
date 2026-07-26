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
    # A rotted anchor is a mutant that never ran. Treating it as SKIP and still
    # printing "mutation-adequate" is how a cosmetic refactor of detect.py once
    # reduced this to 3 killed with a green all-clear.
    printf '  \033[31mNO-ANCHOR\033[0m %-43s mutation never applied\n' "$name"
    survived=$((survived+1))
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

mutate "camel lookbehind removed (interior labels)" \
  '_CAMEL_L = r"(?:(?<![A-Za-z])|(?<=[a-z0-9]))"|||_CAMEL_L = r"(?<![A-Za-z])"' 
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
# Round 5 mutants. The shipped set only tried 20 -> 44 for the segment floor;
# the real boundary is 33, so a 6-character tightening of the exact constant
# round 4 introduced was invisible to all 44 suite assertions.
mutate "SEG_FLOOR 20 -> 26 (the boundary round 4 missed)" \
  'SEG_FLOOR = 20|||SEG_FLOOR = 26'
mutate "SEG_FLOOR_LABELLED 14 -> 20" \
  'SEG_FLOOR_LABELLED = 14|||SEG_FLOOR_LABELLED = 20'
mutate "drop the joined-run acceptor (R5 recall hole)" \
  'by_joined = _joined_is_opaque(core, seg_floor)|||by_joined = False'
mutate "drop the uniform-groups acceptor (licence keys)" \
  'by_groups = _uniform_groups(core)|||by_groups = False'

# Round 6 mutants. Three of _uniform_groups' four guards survived an
# independent sweep — loosening the group-length range would eat MAC addresses
# and nothing would notice — and the two constants added for the base64 recall
# hole had no coverage at all.
mutate "greedy word split (the AWS SecretAccessKey hole)" \
  'parts = re.findall(r"[A-Z][a-z]*|[a-z]+", seg)|||parts = re.findall(r"[A-Z]+[a-z]*|[a-z]+", seg)'
mutate "WORDLIKE_SHARE 0.30 -> 0.01 (veto on any word)" \
  'WORDLIKE_SHARE = 0.30|||WORDLIKE_SHARE = 0.01'
mutate "WORDLIKE_SHARE 0.30 -> 0.95 (almost never veto)" \
  'WORDLIKE_SHARE = 0.30|||WORDLIKE_SHARE = 0.95'
mutate "_WORDLIKE_MAX 30 -> 200 (a whole key can be a word)" \
  '_WORDLIKE_MAX = 30|||_WORDLIKE_MAX = 200'
mutate "uniform-group length range 4..8 -> 2..16 (eats MACs)" \
  'if not 4 <= n <= 8 or any(len(g) != n for g in segs):|||if not 2 <= n <= 16 or any(len(g) != n for g in segs):'
# Redundant against every benign string we have: a uniform run of 3+ equal-length
# alphanumeric groups with no digit anywhere is not something that shows up on a
# screen. Recorded rather than deleted so the claim stays checkable.
expect_survive "uniform groups no longer need a digit" \
  'if not any(c.isdigit() for c in core):|||if not any(True for c in core):'
mutate "uniform groups: 3 -> 2 minimum" \
  '    if len(segs) < 3:|||    if len(segs) < 2:'
mutate "all-letter keys need a 3rd class again" \
  'floor = 2 if (after_label or long_opaque) else 3|||floor = 2 if after_label else 3'
mutate "drop the IPv6 exemption" \
  'if _UUID.match(core) or _TIMESTAMPY.match(core) or _IPV6.match(core):|||if _UUID.match(core) or _TIMESTAMPY.match(core):'

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
