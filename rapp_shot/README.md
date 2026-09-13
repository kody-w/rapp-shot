# RAPP Shot

RAPP Shot 1.3.1 is a native macOS capture/editor with local Vision OCR and opaque
credential redaction. Automatic detection can miss secrets; inspect the final
preview before copying or exporting. Pixelation is cosmetic, not redaction.

This folder supplies **optional secondary integration**: Python singleton/twin
adapters and a browser UI for a compatible RAPP host. The existing twin
configuration uses port 7093. A Python drop or browser UI is not a native app
installer, and no retired hatch artifact is needed to install RAPP Shot.

## Native installation in Finder

1. Download the [v1.3.1 release](https://github.com/kody-w/rapp-shot/releases/tag/v1.3.1)
   ZIP for Apple Silicon (`arm64`) or Intel (`x86_64`).
2. Double-click the ZIP in Finder and drag `RAPPShot.app` to `/Applications` or
   `~/Applications`. The released app is Developer ID signed, notarized and
   stapled; do not disable Gatekeeper or reset TCC.
3. Open the app normally. No capture starts on launch. Importing an image needs
   no screen permission.
4. For display/window/region capture, click Enable Screen Recording and grant
   it to **RAPP Shot itself** in System Settings. Quit/reopen only if macOS asks.
   The native app does not request microphone, camera or Accessibility access.
5. Capture or import, edit locally, prepare the final preview, then review it
   before copy/export.

The manifest pins native source
`3310780e800da97c6c9cf4b1e3c489158de0e2ed`, the final ZIP hashes, and immutable
content-addressed publisher evidence reports:

- [arm64 evidence](https://github.com/kody-w/rapp-shot/releases/download/v1.3.1/rapp_shot-1.3.1-arm64.zip.evidence.38ed2c96f1bfd6217ec8034c4901f3386a01a5d8592f1e5413912d035d2e3686.json)
  · [provenance](https://github.com/kody-w/rapp-shot/releases/download/v1.3.1/rapp_shot-1.3.1-arm64.release-result.json)
- [x86_64 evidence](https://github.com/kody-w/rapp-shot/releases/download/v1.3.1/rapp_shot-1.3.1-x86_64.zip.evidence.e37f64f6199ec55975bcb0db90dc7b4aa45ac7bbc9017dc83d5827b49943fbbe.json)
  · [provenance](https://github.com/kody-w/rapp-shot/releases/download/v1.3.1/rapp_shot-1.3.1-x86_64.release-result.json)

Those reports are not independent Apple authentication or RAPP/1 acceptance by
the Store. The later metadata-only commit does not change the native source.

## Actions

- `doctor`
- `capture`
- `ocr`
- `redact`
- `annotate`
- `list`

## Requires

**Native:** macOS 14+ and `RAPPShot.app` in `/Applications` or `~/Applications`
(the spaced `RAPP Shot.app` name is also recognized). `RAPP_SHOT_APP` can select
another explicit application path. The app uses ScreenCaptureKit, local Vision
OCR, and a real SwiftUI/AppKit editor; no end-user compiler or Hammerspoon is needed.

**Compatibility:** the existing `shot` CLI and its on-device engines remain the
fallback. Set `SHOT_CLI` to explicitly keep that backend even when the native app
is installed. See https://github.com/kody-w/rapp-shot for developer installation.

## Native action behavior

`doctor` runs a no-capture diagnostic; `list` reads existing PNGs (1–100 rows).
`capture`, `ocr`, `redact`, and `annotate` stage a native request for **Review &
Apply**, using the existing action fields. Capture still requires clicking
Capture; copy and export still require reviewing the final flattened preview.
The adapter reports that it staged a request, not that an unperformed capture,
OCR result, or export succeeded. For scripted CLI results, explicitly use
`SHOT_CLI` and the legacy backend.

The app never captures on launch. Grant Screen Recording to RAPP Shot itself.
Detection is per OCR line and can miss split or unreadable secrets. Inspect the
preview; successful re-OCR is not an all-clear. Automatic redacted exports fail
closed on zero-line OCR, recognition errors, invalid custom rules, or surviving
credentials. The clipboard never falls back to the unredacted original.

English-tuned credential labels can miss other formats; long content digests may
be over-redacted. Disabling automatic detection explicitly selects an unverified
manual-edit preview. Native captures remain in memory until export; the default
folder is `~/Library/Application Support/io.rapp.shot/Exports/`. Existing images,
`~/.rappshot` history, custom rules and Hammerspoon settings are preserved.

Capture, OCR and editing stay local. RAPP Shot does not upload screenshots or
text; clipboard/synced-folder behavior outside the app follows the user's macOS
settings. Native `doctor` reports current-process preflight, not proof of the
normally launched GUI's permission.

MIT.
