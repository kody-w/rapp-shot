#!/bin/bash
# RAPP Shot test suite.
#
# Runs against a throwaway SHOT_HOME so your real shots are untouched, and uses a
# SYNTHETIC fixture rendered by the annotate shim rather than capturing your
# actual screen — deterministic, and it never puts your desktop in a test file.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHOT="$HERE/../shot"
SRC="$HERE/../src"
export SHOT_HOME=/tmp/shot-test
rm -rf "$SHOT_HOME"; mkdir -p "$SHOT_HOME/shots"
FIX="$SHOT_HOME/shots/fixture.png"

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
info() { printf '       %s\n' "$*"; }
head_(){ printf '\n\033[1;36m%s\033[0m\n' "$*"; }

head_ "0. Environment"
doc=$("$SHOT" doctor 2>&1)
for need in "OCR shim" "annotate shim" "clipboard shim" "screencapture"; do
  echo "$doc" | grep -q "MISS.*$need" && bad "$need missing" || ok "$need"
done

head_ "1. Fixture — render text, then read it back"
/opt/homebrew/bin/ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=white:s=1400x520 \
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
echo "$dry" | grep -q "normal line that must survive" && bad "would redact a harmless line" \
  || ok "leaves the harmless line alone"

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
flat=$(/opt/homebrew/bin/ffmpeg -hide_banner -loglevel error -i "$SHOT_HOME/red.png" \
  -vf "crop=600:40:40:100,format=gray" -f rawvideo - 2>/dev/null | python3 -c "
import sys; d=sys.stdin.buffer.read(); print(len(set(d)) if d else 999)")
[ "${flat:-999}" -le 2 ] && ok "redacted region is a flat fill (distinct=$flat) — irreversible" \
  || bad "redacted region still has $flat distinct values — reversible!"

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
"$SHOT" redact "$FIX" --box bogus --out /dev/null >/dev/null 2>&1 \
  && bad "accepted a malformed --box" || ok "rejects a malformed --box"

head_ "7. Nothing here talks to the network"
net=$(grep -nE 'urllib|requests|http://|https://|socket|curl' "$SHOT" | grep -vE '^\s*#|"""' | wc -l | tr -d ' ')
[ "$net" = "0" ] && ok "no network calls in the tool" || bad "$net network reference(s) — must stay offline"
swiftnet=$(grep -lE 'URLSession|NSURLConnection' "$SRC"/*.swift 2>/dev/null | wc -l | tr -d ' ')
[ "$swiftnet" = "0" ] && ok "no network calls in the Swift shims" || bad "a shim can reach the network"

rm -rf "$SHOT_HOME"
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
