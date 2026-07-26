-- rappshot.lua — hotkeys for RAPP Shot. Load from ~/.hammerspoon/init.lua with:
--   require("rappshot")
local M = {}

local CONFIG = {
  shot = os.getenv("HOME") .. "/Documents/Fable5/rapp-shot/shot",
  -- Cmd+Shift+5 is taken by macOS; these sit next to it.
  region       = { { "cmd", "shift" }, "6" },  -- pick a region, copy it
  regionRedact = { { "cmd", "shift" }, "7" },  -- pick a region, AUTO-REDACT, copy
  ocrToClip    = { { "cmd", "shift" }, "8" },  -- pick a region, copy its TEXT
}

local function run(args, note)
  hs.task.new(CONFIG.shot, function(code, out, err)
    if code == 0 then
      hs.alert.show(note, 1.2)
    else
      hs.alert.show("RAPP Shot failed: " .. ((err or out or ""):sub(1, 90)), 3)
    end
  end, args):start()
end

hs.hotkey.bind(CONFIG.region[1], CONFIG.region[2], function()
  run({ "capture", "--mode", "region", "--copy" }, "copied")
end)

-- The one worth having: capture, find secrets with OCR, paint them out
-- opaquely, and only then put it on the clipboard.
hs.hotkey.bind(CONFIG.regionRedact[1], CONFIG.regionRedact[2], function()
  run({ "capture", "--mode", "region", "--auto-redact", "--copy" }, "redacted + copied")
end)

hs.hotkey.bind(CONFIG.ocrToClip[1], CONFIG.ocrToClip[2], function()
  hs.task.new(CONFIG.shot, function(code)
    if code ~= 0 then return hs.alert.show("capture cancelled", 1) end
    hs.timer.doAfter(0.2, function()
      run({ "ocr", "--copy" }, "text copied")
    end)
  end, { "capture", "--mode", "region" }):start()
end)

hs.alert.show("RAPP Shot: ⌘⇧6 copy · ⌘⇧7 redact+copy · ⌘⇧8 text", 2)
return M
