# RAPP Shot

Capture, annotate, read and **redact** screenshots — entirely on your own machine.

The native **RAPP Shot 1.3.0** app uses SwiftUI/AppKit and ScreenCaptureKit.
Text recognition is Apple's Vision framework; annotation is CoreGraphics.
There is no account, upload, share link, or cloud processing. The original
`shot` CLI remains available, using macOS `screencapture` and its existing shims.

## Native app — macOS 14 or later

Download **[RAPP Shot v1.3.0](https://github.com/kody-w/rapp-shot/releases/tag/v1.3.0)**:

- [Apple Silicon (arm64 ZIP)](https://github.com/kody-w/rapp-shot/releases/download/v1.3.0/rapp_shot-1.3.0-arm64.zip)
- [Intel (x86_64 ZIP)](https://github.com/kody-w/rapp-shot/releases/download/v1.3.0/rapp_shot-1.3.0-x86_64.zip)

In Finder, double-click the ZIP, move **RAPPShot.app** to `/Applications` (or
`~/Applications`), then open the app normally. No terminal installer is required.
The app's display name is **RAPP Shot**, bundle identifier `io.rapp.shot`.
End users need **no compiler, Python, Homebrew, Hammerspoon, or helper server**.
The released apps are Developer ID signed, notarized and stapled. Architecture-
specific publisher reports are attached to the release; exact archive and
content-addressed report hashes are recorded in `rapp_shot/manifest.json`.
These are publisher release reports, not independent Apple authentication or
RAPP/1 acceptance by a catalog. Do not disable Gatekeeper or reset TCC to install.
An unsigned local developer build is not equivalent to the released build.

1. Nothing is captured at startup. **Open Image** works without screen permission.
2. For capture, click **Enable Screen Recording** and grant it to **RAPP Shot**,
   not Terminal. If macOS asks, quit and reopen the app after granting permission.
   **Refresh Sources** lists displays/windows but does not capture pixels.
3. Select **Display**, **Window**, or **Region**, then click **Capture**.
   Region selection uses a native overlay on the chosen display; drag and release,
   or press Escape to cancel. Cancel also discards late capture/processing results.
   A disconnected display or closed window is an error, never permission to
   capture a substitute source.
4. Edit boxes, arrows, text, highlights, opaque redactions, or cosmetic pixelation.
   Select an annotation to move it, edit its coordinates/color/text, or delete it.
   Crop by dragging or editing exact bounds. Crop is non-destructive; Reset Crop
   and Undo/Redo preserve source pixels and correctly rebase annotation coordinates.
5. Click **Prepare Export / OCR Preview**. Automatic credential redaction is on
   by default. It analyzes the edited/cropped image, paints detected lines opaque
   black, and re-OCRs the rendered output before enabling a preview.
6. Inspect the final PNG (including at 100%) and its OCR text, acknowledge the
   limitations, then **Copy PNG**, **Copy Preview Text**, or **Export PNG**.
   All three use the same immutable reviewed result. They never fall back to the
   original image when redaction/verification fails, and edits invalidate review.

Automatic export is blocked if OCR reads zero input lines, either OCR pass fails,
custom rules cannot be loaded, or a credential remains detectable after rendering.
No matches is **not an all-clear**. To redact an unreadable image manually, turn
automatic detection off, draw opaque redactions, and review the explicitly
unverified edited preview. Pixelation is cosmetic and is never called redaction.

Captures and editable originals stay in memory until export. PNG exports contain
flattened pixels, not hidden source layers or copied source metadata. Existing
images are never overwritten; choose a new filename. The save panel initially
offers `~/Library/Application Support/io.rapp.shot/Exports/`, but you can choose
another folder. Existing `~/.rappshot/shots/`, sidecars, custom rules, and
Hammerspoon configuration are left intact. **Open Latest Legacy Shot** reads the
old history without migrating or changing it.

### Native menus and shortcuts

The Capture menu, menu-bar camera icon, and app shortcuts need no Hammerspoon:

| Native shortcut | Action |
|---|---|
| ⌘⇧6 | region → editor |
| ⌘⇧7 | region → redacted preview |
| ⌘⇧8 | region → OCR preview of the redacted result |
| ⌘⇧E | prepare export/OCR preview of the current image |

Enable optional **system-wide** ⌘⇧6/7/8 in Settings while the app runs.
Registration uses native hotkeys, not keyboard monitoring or Accessibility access.
They start disabled each launch; conflicts with other apps/Hammerspoon are
reported. Unlike the legacy hotkeys, native shortcuts never copy without review.

### Agent compatibility

Singleton and twin adapters keep `doctor`, `capture`, `ocr`, `redact`, `annotate`,
and `list`. They discover `RAPPShot.app` / `RAPP Shot.app` in `/Applications` or
`~/Applications`, or an explicit `RAPP_SHOT_APP` path, checking its bundle ID.
An explicit `SHOT_CLI` keeps the legacy CLI backend; otherwise the CLI remains the
fallback when no native app is installed.

Native `doctor` is a read-only diagnostic (no permission prompt or capture), and
`list` lists existing native/legacy PNGs. Capture/edit/OCR/redaction actions open a
bounded `rappshot://action/...` request for **Review & Apply**. They do not report
a completed capture, return newly extracted text, or silently copy/export: those
steps require the native user's confirmation. Region/window requests therefore
work interactively with the native app, while legacy CLI headless limitations
remain. No new RAPP wire fields or network service are introduced.

### Native development and verification

The Swift package separates `RAPPShotCore` from the executable `RAPPShot`;
`native/project.yml` generates a real application target from those same sources.
Developer builds require Xcode 15+ and XcodeGen. The shared `RAPPDesktopSupport`
package is fetched from `https://github.com/kody-w/rapp-tools.git`, pinned in both
build definitions to `f0bc616c2aed34f2a88888806ed056ec7bafba61`. SwiftPM and Xcode
resolved pins are committed; no sibling checkout is required. RAPP Shot uses its
app-support-directory API and has no runtime helper executable dependencies.

```bash
cd native
mkdir -p .build/scratch
export TMPDIR="$PWD/.build/scratch"
swift test -j 2
swift build -c release -j 2
xcodegen generate --spec project.yml
xcodebuild -workspace RAPPShot.xcodeproj/project.xcworkspace -scheme RAPPShot \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build -jobs 2 CODE_SIGNING_ALLOWED=NO \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build

build/Build/Products/Release/RAPPShot.app/Contents/MacOS/RAPPShot --diagnose
build/Build/Products/Release/RAPPShot.app/Contents/MacOS/RAPPShot --ui-smoke-test
cd ..
python3 tools/native_parity.py
python3 tools/test_native_adapters.py
```

The generated workspace is the entry point used for Xcode build verification
above. Its revision lock is
`native/RAPPShot.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`;
other generated project files remain ignored. SwiftPM's separate lock is
`native/Package.resolved`.

`--ui-smoke-test` briefly opens the real native window, asserts idle/no-image/no
source-enumeration/no-permission-request startup, emits JSON, and exits.
`--detect-lines` accepts bounded synthetic JSON on stdin and emits detector labels
only; it cannot capture, copy, export, or bypass permissions. The parity check
compares every original corpus fixture plus all 4,000 seeded trial strings against
`detect.py`, including exact labels and the detector's known miss behavior.

Native unit tests render their own images: Vision coordinates, Retina/fractional
scales, crop/arrow offsets, opaque pixel fills, all annotation types, EXIF
orientation, original detector regressions, OCR failure/zero-line/survivor
handling, immutable preview authorization, and no-overwrite export are covered.
Tests do not capture your desktop, modify TCC, or write your clipboard/history.
Live display/window/region capture and the grant/deny/relaunch permission UX still
require an explicit human test on each supported macOS/device configuration.

### Same-repository native CI

`.github/workflows/native.yml` runs on **macos-latest** and **macos-15-intel** for
pushes, pull requests, and manual dispatch. Both jobs use the same local command:

```bash
python3 tools/native_ci.py
```

Developer prerequisites are macOS, Xcode/Swift, Python 3, and XcodeGen. The runner
uses owned project-local build/fixture directories and verifies the immutable
shared-package locks. It runs `swift test -j 2`, a release Swift build, adapter
tests, runner-safety tests, detector parity, the legacy synthetic/mutation suite,
and an unsigned native Xcode workspace build with `-jobs 2`. Legacy image
generation and pixel inspection use a test-only CoreGraphics helper, not ffmpeg.

Safe noninteractive native verification entrypoints are:

```bash
RAPPShot.app/Contents/MacOS/RAPPShot --diagnose
RAPPShot.app/Contents/MacOS/RAPPShot --ui-smoke-test
```

The second briefly opens the native window, checks idle startup and zero capture,
permission-request, source-enumeration, and clipboard activity, then exits.
Neither entrypoint captures pixels or requests permission. CI never runs
`install.sh`, live `shot capture`, plain legacy `shot doctor`, TCC modification, or
signing/notarization commands. No signing credentials are required.

Logs and `rapp-shot-ci/1.0` reports remain under `.test-artifacts/native-ci-*/`;
owned build/cache/fixture trees are removed afterward. These reports are
**verification only, not Apple release evidence**. The workflow has read-only
repository permission and no publishing step. For release-source binding, the
parent must obtain a successful public push/dispatch Actions run at the exact
native-build commit; CI checks that its clean checkout equals `GITHUB_SHA`.
Local results alone do not claim that a public Actions run has succeeded.

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

## Legacy CLI install

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

45 assertions against an isolated project-local `SHOT_HOME`. The fixture is **rendered**, not
captured — deterministic, and your desktop never ends up in a test file. It
asserts that every secret class is detected, that none survives redaction, that
the harmless line does, and that the redacted region is genuinely flat.
Shims and mutation tests operate on isolated copies under `.test-artifacts/` and
clean up their owned workspace. The suite requires the developer Swift toolchain
and Python 3, with only Apple frameworks for fixture images; these are not
native-app runtime requirements.
Use `shot doctor --no-capture` for automation: plain legacy `shot doctor` still
performs its original live capture probe.

## What it does not do

- **No scrolling capture.** Real limitation versus the paid tools.
- **No cloud link.** By design; that is the part you are taking back.
- **OCR is per-line.** A secret split across two rendered lines may only be
  partly caught — check `--dry-run` before sharing anything sensitive.
- **English-tuned patterns.** The regexes are format-based, not language-based,
  but the labelled-secret pattern assumes English keywords.
- **Not a credential guarantee.** OCR can misread, omit, or rotate text; even a
  successful verification pass checks detected text only. Long digests can be
  over-redacted because their shape is indistinguishable from credentials.
- **Native custom regex syntax uses ICU.** Existing ordinary patterns are reused
  from `~/.rappshot/redact-patterns.txt` (`SHOT_HOME` is honored); Python-only regex
  extensions may need adaptation. Invalid rules block automatic native export
  rather than being silently ignored.
- **Native capture excludes RAPP Shot itself** from display/region captures and
  does not capture system-protected windows. No scrolling capture, background
  recording, microphone, or camera capture is implemented.

MIT.
