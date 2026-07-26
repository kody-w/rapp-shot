# RAPP Shot

Capture, annotate, read and **redact** screenshots — entirely on your own machine.

Capture is macOS `screencapture`. Text recognition is Apple's Vision framework.
Annotation is CoreGraphics. There is no account, no upload, no share link and no
retention policy: a shot is a PNG in `~/.rappshot/shots/` and nowhere else.

## The reason to have this

```bash
shot capture --auto-redact --copy
```

It OCRs the capture, finds credentials in the **pixels**, and paints them out
**before** the image reaches your clipboard. Proven on a fixture containing five
classes of secret:

```
would redact 5 region(s):
  email            contact: alice.smith@example.com
  github token     GITHUB_TOKEN=gh••_A1b2C3d4E5f6G7h8…
  aws access key   AWS key AK••IOSFODNN7EXAMPLE
  openai-style key api_key: sk••abcdefghijklmnopqrstuv…
  card-like number card 4111 •••• •••• 1111
```

Re-reading the redacted image returns only the harmless lines. The secrets are
gone from the image, not covered up.

### Why anchored regexes were not enough

The first detector matched patterns like `\bgh[pousr]_[A-Za-z0-9]{16,}\b` straight
against OCR output. That fails on exactly the strings it most needs to catch —
Vision substitutes homoglyphs inside high-entropy runs, because random characters
give its language model no context to correct against:

```
rendered   GITHUB_TOKEN=gh•_9zQ7LmN4bV2cD8fH1jK3pR5sT6uW…
Vision     GITHUB_ТOКЕN=gh•_9zQ7LmN4bV2cD8fH1jKЗpR5sT6uW…
                 ^^^                          ^ Cyrillic ZE (U+0417)
                 Cyrillic Т К Е
```

`[A-Za-z0-9]` breaks there, the token is missed, and the tool then reports
*"2 region(s) painted out, opaque and irreversible"* — which reads as an all-clear
and invites you to share an image with a live token in it. That is worse than
finding nothing, because it manufactures confidence.

Detection now normalises homoglyphs to ASCII first, and additionally matches on
**shape** — a long, mixed-class, space-free run is a credential whether or not it
survived OCR intact, doubly so after a `token`/`key`/`secret` label.

### It verifies by re-reading, not by asserting

After painting, the output is OCR'd again and every detected secret is searched
for in the result. If any survives, you get a non-zero exit and:

```
NOT SAFE TO SHARE — 1 detected secret(s) are STILL readable after redaction
```

"Painted out" is a claim about pixels, so it is checked against the pixels.

### Redaction is opaque, and that is not a style choice

`redact` paints a solid rectangle. Blur and pixelation are reversible often
enough to have leaked real credentials in public, so they are not offered as
redaction. `pixelate` exists separately, documented as cosmetic.

A test asserts the difference: a redacted region collapses to **1–2 distinct
pixel values**; the same region pixelated keeps 16, and the original had 142.

## Install

```bash
git clone https://github.com/kody-w/rapp-shot.git
cd rapp-shot
./install.sh --hotkeys
```

Compiles four small Swift shims with the toolchain already on macOS. No Xcode
project, no dependencies. Needs Screen Recording permission.

`--hotkeys` registers Hammerspoon bindings. If your `init.lua` is a symlink into
another app's repo, the installer **materialises a real file** rather than
appending through the link — writing into another project's tracked source is a
bug, not an install step.

| Hotkey | Action |
|---|---|
| ⌘⇧6 | pick a region → copy |
| ⌘⇧7 | pick a region → **auto-redact** → copy |
| ⌘⇧8 | pick a region → copy its **text** |

## Use

```bash
shot capture --mode region --copy      # region | window | screen
shot capture --auto-redact --copy      # the one worth remembering
shot ocr --copy                        # text of the most recent shot
shot redact --auto --dry-run           # what WOULD be painted out
shot redact --box 40,30,600,50         # manual region
shot annotate --box 40,30,600,50 --arrow 900,400,700,80 \
              --text 60,450,"look here" --crop 0,0,700,300
shot list
```

Commands with no image argument act on your most recent shot.

## Annotation ops

`box` · `arrow` · `text` · `highlight` · `pixelate` · `redact` · `crop`

All coordinates are top-left pixel origin — the same space the OCR shim reports
boxes in, so you can feed OCR output straight back in as annotation targets.

## Custom redaction patterns

`~/.rappshot/redact-patterns.txt`, one regex per line. The built-ins cover
emails, GitHub/OpenAI/AWS keys, JWTs, bearer tokens, labelled secrets
(`api_key: …`), card-like and SSN-like numbers.

The sample output above is masked, and the test fixture assembles its fake
credentials at runtime from fragments — a repository that ships secret-shaped
literals trips every scanner downstream, and a gate that cries wolf teaches
people to bypass it. Add your own:

```
INTERNAL-[0-9]{4}
```

The built-ins are deliberately conservative on the generic patterns: a false
redaction costs a re-shot, a missed credential costs a rotation.

## Tests

```bash
./tools/dryrun.sh
```

23 assertions against a throwaway `SHOT_HOME`. The fixture is **rendered**, not
captured — deterministic, and your desktop never ends up in a test file. It
asserts that every secret class is detected, that none survives redaction, that
the harmless line does, and that the redacted region is genuinely flat.

## What it does not do

- **No scrolling capture.** Real limitation versus the paid tools.
- **No cloud link.** By design; that is the part you are taking back.
- **OCR is per-line.** A secret split across two rendered lines may only be
  partly caught — check `--dry-run` before sharing anything sensitive.
- **English-tuned patterns.** The regexes are format-based, not language-based,
  but the labelled-secret pattern assumes English keywords.

MIT.
