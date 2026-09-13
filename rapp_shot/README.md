# RAPP Shot

Capture, annotate and redact screenshots entirely on-device. Finds credentials in the pixels with Apple's Vision OCR and paints them out opaquely BEFORE the image is shared. Redaction is a solid fill, never a blur, because blur and pixelation are reversible often enough to have leaked real credentials.

A `runtime: "twin"` rapplication: it hatches into its own brainstem on port 7093 carrying only its own agent, and the host brainstem reaches it over twin-chat.

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

Nothing is uploaded.

MIT.
