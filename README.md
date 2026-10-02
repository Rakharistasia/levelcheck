# LevelCheck

Finds gear your characters could no longer wear if they dropped to a lower level - useful on servers with a delevel mechanic (written for EQ Might, works on any EQEmu server with MacroQuest).

It scans worn gear, bags, bank and shared bank, including augments socketed in items, and lists every item with a Required Level or Recommended Level. Anything above your target level is flagged:

- **Unwearable** (red) - required level is above the target
- **Reduced stats** (amber) - only the recommended level is above the target

## Install

Put `init.lua` in `<MacroQuest>/lua/levelcheck/`.

## Use

```
/lua run levelcheck          scan this character and open the window
/lua run levelcheck scan     scan this character, save, and exit (no window)
/levelcheck scan             rescan this character
/levelcheck scanall          ask every DanNet box to scan
/levelcheck scanzone         ask DanNet boxes in your zone to scan
/levelcheck quit             close
```

Set **Delevel to** in the window (default 51). Each character saves its results to `config/LevelCheck_<server>_<name>.lua`, so the window shows every character ever scanned, online or not. Click a character in the summary to filter to them; click an item to inspect it.

## Requirements

- MacroQuest (MQNext) with Lua and ImGui
- MQ2DanNet for the "all boxes" / "zone" rescans (optional)

## Notes

- Bank contents are read from the client; if a bank slot shows nothing, open your bank once and rescan.
- Read-only: the script never moves items.
