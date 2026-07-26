#!/bin/bash
# RAPP Shot test suite.
#
# Runs against a throwaway SHOT_HOME so your real shots are untouched, and uses a
# SYNTHETIC fixture rendered by the annotate shim rather than capturing your
# actual screen — deterministic, and it never puts your desktop in a test file.
set -uo pipefail


# Homebrew prefix differs by architecture (/opt/homebrew on Apple Silicon,
# /usr/local on Intel). Resolve rather than hardcode, or this file is a no-op
# on half the Macs it targets.
brewbin() { for p in "/opt/homebrew/bin/$1" "/usr/local/bin/$1"; do
    [ -x "$p" ] && { echo "$p"; return; }; done
  command -v "$1" 2>/dev/null || echo "/opt/homebrew/bin/$1"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHOT="$HERE/../shot"
SRC="$HERE/../src"
export SHOT_HOME=/tmp/shot-test
rm -rf "$SHOT_HOME"; mkdir -p "$SHOT_HOME/shots"
FIX="$SHOT_HOME/shots/fixture.png"
FIX2="$SHOT_HOME/fixture2.png"

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
info() { printf '       %s\n' "$*"; }
head_(){ printf '\n\033[1;36m%s\033[0m\n' "$*"; }

head_ "0. Environment"
doc=$("$SHOT" doctor 2>&1); docrc=$?
# Assert the POSITIVE, and assert the command survived. The old form was
#   grep -q "MISS.*$need" && bad || ok
# which reports PASS when `shot doctor` crashes: a traceback contains no "MISS",
# so the grep fails and the || branch calls ok. A suite that goes green on a
# total crash is worse than no suite.
if [ "$docrc" != 0 ]; then
  bad "shot doctor exited $docrc — every check below is meaningless: $doc"
else
  for need in "OCR shim" "annotate shim" "clipboard shim" "screencapture"; do
    if echo "$doc" | grep -q "^  ok   $need"; then ok "$need"
    elif echo "$doc" | grep -q "$need"; then bad "$need present but not ok"
    else bad "$need absent from doctor output entirely"; fi
  done
fi

head_ "1. Fixture — render text, then read it back"
$(brewbin ffmpeg) -hide_banner -loglevel error -f lavfi -i color=c=white:s=1400x520 \
  -frames:v 1 -y "$SHOT_HOME/blank.png"
python3 - <<PY
import json,subprocess,sys
# Assembled at runtime from fragments ON PURPOSE. These are fake (AWS's own
# documentation key, the standard test card), but committing secret-SHAPED
# literals trips every credential scanner downstream — including this project's
# own publishing gate — and a gate that cries wolf teaches people to bypass it.
import string
tok = "gh" + "p_" + ("A1b2C3d4E5f6G7h8" + "I9j0K1l2M3n4O5p6")
aws = "AK" + "IA" + "IOSFODNN7" + "EXAMPLE"
oai = "sk" + "-" + string.ascii_lowercase + "012345"
card = " ".join(["4111"] + ["1111"] * 3)
lines=["Deployment notes for the release",
 "contact: alice.smith@example.com",
 "GITHUB_TOKEN=" + tok,
 "AWS key " + aws,
 "api_key: " + oai,
 "card " + card,
 "normal line that must survive untouched"]
ops=[{"op":"text","x":40,"y":30+i*66,"t":t,"size":30,"color":"#111111"} for i,t in enumerate(lines)]
json.dump({"in":"$SHOT_HOME/blank.png","out":"$FIX","ops":ops}, open("$SHOT_HOME/mk.json","w"))
r=subprocess.run(["$SRC/annotate","$SHOT_HOME/mk.json"],capture_output=True,text=True)
sys.exit(0 if r.returncode==0 else 1)
PY
[ -f "$FIX" ] && ok "annotate rendered a fixture" || bad "annotate failed to render"
txt=$("$SHOT" ocr "$FIX" 2>/dev/null)
n=$(echo "$txt" | grep -c .)
info "OCR read $n line(s) back"
echo "$txt" | grep -q "alice.smith@example.com" && ok "OCR round-trips rendered text" \
  || bad "OCR could not read the fixture back"

head_ "2. Auto-redaction finds every class of secret"
dry=$("$SHOT" redact "$FIX" --auto --dry-run 2>&1)
for want in "email" "github token" "aws access key" "openai-style key" "card-like number"; do
  echo "$dry" | grep -q "$want" && ok "detects $want" || bad "MISSED $want"
done
# positive-first: if `dry` were empty because the command crashed, the old
# `grep && bad || ok` form scored that as "leaves the harmless line alone".
if [ -z "$dry" ]; then bad "dry-run produced no output at all"
elif echo "$dry" | grep -q "normal line that must survive"; then
  bad "would redact a harmless line"
else ok "leaves the harmless line alone"; fi

head_ "2b. The formats that got through review twice"

# WHY A SECOND FIXTURE. Section 2 only ever contained gh*_, AK*IA, sk-* and a
# test card — four prefix-anchored patterns. That suite was green while the
# detector missed every hex credential and every SCREAMING_SNAKE env var,
# because none of those shapes were representable in it. A suite that CANNOT
# fail on a defect is not evidence about that defect. These are the exact
# formats an adversarial review proved survived `redact --auto` with rc=0 and
# "nothing matched - image unchanged", which reads as an all-clear.
$(brewbin ffmpeg) -hide_banner -loglevel error -f lavfi -i color=c=white:s=1400x520 \
  -frames:v 1 -y "$SHOT_HOME/blank2.png" 2>/dev/null
python3 - <<FIXTURE2
import json, subprocess, sys
# fake, and assembled from fragments so the repo never carries a secret-shaped
# literal - same reasoning as the fixture above
hex32 = "0123456789abcdef" * 2
hexup = "FEDCBA9876543210" * 2
lines = ["Second fixture: shapes with no distinctive prefix",
         "TWILIO_AUTH_" + "TOKEN=" + hex32,
         "key: " + hex32,
         "https://api.example.com/v1/t?access_" + "token=" + hex32,
         hexup,
         "run id 3f2504e0-4f89-11d3-9a0c-0305e82c3301 is not a secret",
         "/Users/someone/Library/Application Support/Ex/cache is not either"]
ops = [{"op": "text", "x": 40, "y": 30 + i * 66, "t": t, "size": 26,
        "color": "#111111"} for i, t in enumerate(lines)]
json.dump({"in": "$SHOT_HOME/blank2.png", "out": "$FIX2", "ops": ops},
          open("$SHOT_HOME/mk2.json", "w"))
r = subprocess.run(["$SRC/annotate", "$SHOT_HOME/mk2.json"],
                   capture_output=True, text=True)
sys.exit(0 if r.returncode == 0 else 1)
FIXTURE2
[ -f "$FIX2" ] && ok "second fixture rendered" || bad "could not render second fixture"

dry2=$("$SHOT" redact "$FIX2" --auto --dry-run 2>&1)
if echo "$dry2" | grep -qi "nothing matched"; then
  bad "REGRESSION: reports 'nothing matched' on an image full of credentials"
else
  ok "does not report an all-clear on a credential-bearing image"
fi
# Assert on LABELS, not on the value: the dry-run masks matched text now, and
# a suite that greps for the credential is asserting the leak it should prevent.
for want in "labelled credential value" "token in a URL" "long hex run"; do
  if echo "$dry2" | grep -qi "$want"; then ok "detects: $want"
  else bad "MISSED the detection class: $want"; fi
done
n2=$(echo "$dry2" | grep -cE "^  [a-z]" || true)
[ "${n2:-0}" -ge 4 ] && ok "$n2 credential-bearing lines flagged" \
  || bad "only ${n2:-0} lines flagged on a fixture with 4 credentials"
if echo "$dry2" | grep -qE "0123456789abcdef0123|FEDCBA9876543210FEDC"; then
  bad "the dry-run PRINTED a credential value — it must be masked"
else
  ok "matched values are masked in the report"
fi
if echo "$dry2" | grep -q "3f2504e0-4f89-11d3"; then bad "flagged a canonical UUID"
else ok "leaves a canonical UUID alone"; fi
if echo "$dry2" | grep -q "Application Support"; then bad "flagged an ordinary file path"
else ok "leaves an ordinary file path alone"; fi

# End to end: destroy the pixels, then re-read the image and prove it is gone.
"$SHOT" redact "$FIX2" --auto --out "$SHOT_HOME/red2.png" >/dev/null 2>&1
rc2=$?
if [ ! -f "$SHOT_HOME/red2.png" ]; then
  bad "no output for the second fixture"
elif [ "$rc2" != "0" ]; then
  # rc was captured and then only interpolated into the PASS text. A mutant that
  # reports a survivor on EVERY redaction (rc 4 always) sailed through.
  bad "a clean redaction exited $rc2, expected 0 — rc 4 means it thinks a secret survived"
else
  ok "second fixture redacted cleanly (rc=0)"
fi
after2=$("$SHOT" ocr "$SHOT_HOME/red2.png" 2>/dev/null)
leak2=0
for s in "0123456789abcdef0123" "FEDCBA9876543210FEDC"; do
  if echo "$after2" | grep -qi "$s"; then bad "SECRET SURVIVED redaction: ${s:0:12}"; leak2=1; fi
done
[ "$leak2" = "0" ] && ok "no hex credential is readable after redaction"
if echo "$after2" | grep -qi "not a secret"; then ok "benign lines survive redaction"
else info "benign line unreadable after redaction (over-redaction, not a leak)"; fi

head_ "2c. Detector corpus — both directions, and mutation-adequate"
# Round 4 found the detector destroyed 6 of 7 lines on a screenshot with no
# secrets in it, and that four single-line mutations to detect.py left the
# suite fully green. Precision and mutation-adequacy are now assertions.
if python3 tools/corpus_check.py > "$SHOT_HOME/corpus.txt" 2>&1; then
  ok "corpus: $(grep -oE '[0-9]+/[0-9]+ credentials found' "$SHOT_HOME/corpus.txt")"
  ok "corpus: $(grep -oE '[0-9]+/[0-9]+ benign lines left alone' "$SHOT_HOME/corpus.txt")"
  ok "corpus: $(grep -oE '[0-9]+/[0-9]+ recognised as the right KIND' "$SHOT_HOME/corpus.txt")"
else
  bad "detector corpus FAILED"
  sed -n '1,14p' "$SHOT_HOME/corpus.txt" | sed 's/^/       /'
fi
if bash tools/mutate.sh > "$SHOT_HOME/mutate.txt" 2>&1; then
  ok "mutation: $(grep -oE '[0-9]+ killed, [0-9]+ survived.*' "$SHOT_HOME/mutate.txt")"
else
  bad "surviving mutant — the corpus cannot detect that defect class"
  grep SURVIVED "$SHOT_HOME/mutate.txt" | sed 's/^/       /'
fi

head_ "3. Redaction actually destroys the pixels"
"$SHOT" redact "$FIX" --auto --out "$SHOT_HOME/red.png" >/dev/null 2>&1
[ -f "$SHOT_HOME/red.png" ] && ok "redacted image written" || bad "no output"
after=$("$SHOT" ocr "$SHOT_HOME/red.png" 2>/dev/null)
leaked=0
for s in "alice.smith" "gh""p_" "AK""IA" "sk""-abcdef" "4111"; do
  echo "$after" | grep -qi "$s" && { bad "SECRET SURVIVED: $s"; leaked=1; }
done
[ "$leaked" = "0" ] && ok "no secret is readable after redaction"
echo "$after" | grep -q "normal line that must survive" \
  && ok "the harmless line still reads back" || bad "redaction destroyed innocent content"
# an opaque fill must collapse to a single value, unlike a blur
flat=$($(brewbin ffmpeg) -hide_banner -loglevel error -i "$SHOT_HOME/red.png" \
  -vf "crop=600:40:40:100,format=gray" -f rawvideo - 2>/dev/null | python3 -c "
import sys; d=sys.stdin.buffer.read(); print(len(set(d)) if d else 999)")
[ "${flat:-999}" -le 2 ] && ok "redacted region is a flat fill (distinct=$flat) — irreversible" \
  || bad "redacted region still has $flat distinct values — reversible!"

head_ "3b. Homoglyph-mangled secrets (the class that shipped a legible token)"
# The old fixture passed BY LUCK: Vision corrupted it at character 17, one past
# the {16,} threshold. These assert on detect.py directly with the exact
# substitutions Vision was observed to make, so the threshold cannot hide it.
python3 "$HERE/homoglyph_check.py" "$HERE/.."
[ $? -eq 0 ] && ok "homoglyph-mangled secrets are detected, prose is not" \
  || bad "a mangled secret slipped through — this is the shipping-a-token bug"

head_ "3c. Redaction is verified by re-reading, not asserted"
grep -q "still_present" "$SHOT" && ok "redact re-OCRs its own output before claiming success" \
  || bad "redact claims 'painted out' without checking the pixels"
# still_present compares AFTER normalisation on purpose: an OCR that mangles the
# survivor differently the second time must not read as a successful redaction.
# That property had no test, so dropping normalisation from it — a false
# all-clear on exactly the homoglyph case section 3b exists for — was invisible.
sp=$(python3 - <<'SP'
import sys
sys.path.insert(0, ".")
import detect
tok = "gh" + "p_9zQ3LmN4bV2cD8fH1jK3pR5sT6uW0xY2aB"
# The mangling must land INSIDE the probe window (still_present compares the
# first max(12, len/2) characters). Mangling only a late character let the
# "drop normalisation" mutant survive: the probe matched before reaching it.
mangled = tok.replace("3", "З", 1).replace("O", "О")   # what Vision returns
same = detect.still_present(tok, f"noise {tok} noise")
mang = detect.still_present(tok, f"noise {mangled} noise")
gone = detect.still_present(tok, "noise ---------- noise")
print("OK" if (same and mang and not gone) else f"BAD same={same} mangled={mang} gone={gone}")
SP
)
[ "$sp" = "OK" ] && ok "still_present sees a survivor even when OCR re-mangles it" \
  || bad "still_present: $sp"

# EXERCISE the survivor path rather than grepping for its message. Substituting
# an annotate shim that copies the image through without painting anything
# reproduces exactly the failure that matters: ops were "applied", the pixels
# did not change, and the credential is still legible.
cp "$SRC/annotate" "$SHOT_HOME/annotate.real"
cat > "$SRC/annotate" <<'NOOP'
#!/usr/bin/env python3
import json, shutil, sys
spec = json.load(open(sys.argv[1]))
shutil.copy(spec["in"], spec["out"])          # deliberately paint nothing
print(json.dumps({"ok": True, "ops": len(spec.get("ops", []))}))
NOOP
chmod +x "$SRC/annotate"
surv_out=$("$SHOT" redact "$FIX2" --auto --out "$SHOT_HOME/surv.png" 2>"$SHOT_HOME/surv.err")
survrc=$?
surv_err=$(cat "$SHOT_HOME/surv.err")
cp "$SHOT_HOME/annotate.real" "$SRC/annotate"; chmod +x "$SRC/annotate"

[ "$survrc" = "4" ] && ok "a failed redaction exits 4 (got $survrc)" \
  || bad "a failed redaction exited $survrc, not 4 — a script would treat it as success"
echo "$surv_err" | grep -q "NOT SAFE TO SHARE" \
  && ok "reports loudly when a secret survives" \
  || bad "no NOT-SAFE warning — a partial redaction would look like a success"
# R9: stdout is what gets pasted into a ticket. It must not carry the reassuring
# half of a contradiction while stderr says the opposite.
if echo "$surv_out" | grep -q "opaque and irreversible"; then
  bad "stdout still claims 'opaque and irreversible' while the secret survived"
else
  ok "stdout does not claim irreversibility when the secret survived"
fi

head_ "4. Annotation ops render"
"$SHOT" annotate "$FIX" --box 40,30,600,50 --arrow 900,400,700,80 \
  --highlight 40,200,500,40 --text 60,450,"annotated" \
  --out "$SHOT_HOME/ann.png" >/dev/null 2>&1
[ -f "$SHOT_HOME/ann.png" ] && ok "box/arrow/highlight/text rendered" || bad "annotate failed"
d1=$(python3 -c "import subprocess;p=subprocess.run(['sips','-g','pixelWidth','$FIX'],capture_output=True,text=True);print(p.stdout.strip().split(':')[-1].strip())")
"$SHOT" annotate "$FIX" --crop 0,0,700,300 --out "$SHOT_HOME/crop.png" >/dev/null 2>&1
d2=$(python3 -c "import subprocess;p=subprocess.run(['sips','-g','pixelWidth','$SHOT_HOME/crop.png'],capture_output=True,text=True);print(p.stdout.strip().split(':')[-1].strip())")
[ "$d2" = "700" ] && ok "crop changed dimensions ($d1 -> $d2)" || bad "crop gave width $d2, wanted 700"

head_ "5. Custom patterns are honoured"
printf 'INTERNAL-[0-9]{4}\n' > "$SHOT_HOME/redact-patterns.txt"
python3 - <<PY
import json,subprocess
ops=[{"op":"text","x":40,"y":40,"t":"ticket INTERNAL-7788 is closed","size":30,"color":"#111111"}]
json.dump({"in":"$SHOT_HOME/blank.png","out":"$SHOT_HOME/custom.png","ops":ops}, open("$SHOT_HOME/c.json","w"))
subprocess.run(["$SRC/annotate","$SHOT_HOME/c.json"],capture_output=True)
PY
cust=$("$SHOT" redact "$SHOT_HOME/custom.png" --auto --dry-run 2>&1)
echo "$cust" | grep -q custom && ok "custom pattern matched" || bad "custom pattern ignored: $cust"

head_ "6. Manual box redaction"
man=$("$SHOT" redact "$FIX" --box 40,30,600,50 --out "$SHOT_HOME/man.png" 2>&1)
echo "$man" | grep -q "1 region" && ok "manual --box redacts" || bad "manual box failed: $man"
# Require the SPECIFIC usage exit and the diagnostic, not merely "nonzero" —
# an unhandled traceback is also nonzero and used to pass this as a rejection.
mb=$("$SHOT" redact "$FIX" --box bogus --out /dev/null 2>&1); mbrc=$?
if [ "$mbrc" = 0 ]; then bad "accepted a malformed --box"
elif echo "$mb" | grep -q "Traceback"; then bad "crashed on malformed --box: $mb"
elif echo "$mb" | grep -q "expected x,y,w,h"; then ok "rejects a malformed --box (rc=$mbrc)"
else bad "rejected --box but without a usable message: $mb"; fi

head_ "7. Nothing here talks to the network"
net=$(grep -nE 'urllib|requests|http://|https://|socket|curl' "$SHOT" | grep -vE '^\s*#|"""' | wc -l | tr -d ' ')
[ "$net" = "0" ] && ok "no network calls in the tool" || bad "$net network reference(s) — must stay offline"
swiftnet=$(grep -lE 'URLSession|NSURLConnection' "$SRC"/*.swift 2>/dev/null | wc -l | tr -d ' ')
[ "$swiftnet" = "0" ] && ok "no network calls in the Swift shims" || bad "a shim can reach the network"

rm -rf "$SHOT_HOME"
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
