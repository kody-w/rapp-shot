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

The `rapp-shot` CLI and its on-device engines. See https://github.com/kody-w/rapp-shot

Nothing is uploaded.

MIT.
