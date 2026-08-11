# densestats.koplugin

**English** · [简体中文](README.zh-CN.md)

A dense reading-statistics screensaver for [KOReader](https://github.com/koreader/koreader).

It takes over KOReader's built-in `readingprogress` screensaver type — the one
`frontend/ui/screensaver.lua` reaches through `Screensaver.getReaderProgress()`. Keep
choosing "Show reading progress on the sleep screen" in the settings; what gets drawn is
this plugin's version instead.

The plugin only **reads** the statistics plugin's `statistics.sqlite3`, never writes to it.
**The statistics plugin must stay enabled** — `screensaver.lua` checks for `ui.statistics`
and falls back to a random image if it isn't there.

> Heads up for contributors: the source comments are written in Chinese. The code itself
> reads fine without them, but the reasoning behind the layout decisions does not.

## What it shows

Top to bottom:

- **Two rows of figures** — time read today / this week / this month / this year; then
  streak, lifetime total, pages today, pages this week
- **A 30-day bar chart** with a dashed reference line at your active daily average
  (labelled to the left of the plot), so you can see at a glance which days beat it
- **Currently reading** — title, progress bar, percentage / page / time spent on that book
- **Finished** — books in reverse date order, the month printed only on its first row
- **Footer** — date, time, battery

### The type sizes adapt to the screen

Three tiers (emphasis / body / auxiliary) start from KOReader's own named design sizes
of 25 / 20 / 15, then get multiplied by a factor. Rendering tries 1.30 first and steps
down until the layout fits: no cell in the four-column rows may be truncated, and the
finished list must still have room for two entries. If nothing fits, the smallest step
wins — small type beats pushing the footer off the screen.

This is how KOReader itself handles fill-the-screen widgets (see `calendarview.lua`,
`keyvaluepage.lua`, `menu.lua`), and it beats hardcoding numbers that happen to look
right on one device. It assumes nothing about the hardware; it only asks whether the
content fits *this* screen at *this* scale factor. Resolution, aspect ratio, orientation,
a user-set "Screen DPI" override, and content length are all absorbed automatically.

Set `DENSESTATS_DEBUG=1` to log the chosen factor, how many passes it took, and the
layout time.

## Layout

```
densestats.koplugin/
  main.lua       rendering and plugin wiring (the only file touching KOReader widgets)
  stats.lua      duration formatting + time-series derivation (pure Lua, unit-tested)
  finished.lua   scans sidecars to count finished books (pure Lua, unit-tested)
  layout.lua     layout arithmetic: slack allocation, step-down search (pure Lua, tested)
sql/queries.sql  standalone SQL for cross-checking the figures
test/            unit tests, run directly with the luajit KOReader ships
dev.sh           development script
```

## Working on it

### 1. The SQL layer

Start here — it has nothing to do with KOReader:

```
sqlite3 -header -column /path/to/statistics.sqlite3 < sql/queries.sql
```

Pay attention to section 3, "finished-book detection". It is a heuristic and it
definitely gets some books wrong.

### 2. On macOS

The macOS build of KOReader is **not in Releases**; download the arm64 artifact from a
GitHub Actions run (see the wiki page "Installation on MacOS"). On macOS 15.7 and later,
Gatekeeper blocks the first launch — approve it under System Settings → Privacy &
Security, at the bottom.

Then:

```
./dev.sh link                                  # symlink the plugin into KOReader.app
./dev.sh db ~/Downloads/statistics.sqlite3     # load real data
./dev.sh run                                   # launch
```

**Desktop builds have no sleep screen**, so the hook never fires. Use the plugin's own
entry point: main menu → More tools → "预览：密集统计屏" (Preview). Tap to dismiss.

Building from source with `./kodev build` is not worth it for UI work — compiling
koreader-base from scratch on macOS arm64 takes hours.

### 3. On a device

Copy the plugin folder into `koreader/plugins/` and restart. Logs land in
`koreader/crash.log` (`logger.warn` output goes there). KOReader's bundled SSH plugin
lets you tail it remotely.

## KOReader behaviour worth knowing

These started as open questions and were settled by reading the source. Recorded here so
nobody has to look them up again (line numbers are from KOReader 2026.07):

- **`Screen:scaleBySize(px)` scales by the screen's *short edge*, and by default ignores
  DPI entirely** (`ffi/framebuffer.lua:414-425`): `size_scale = min(w, h) / 600`. DPI
  only enters the formula when the user has overridden "Screen DPI" by hand. So the
  usual worry — "will a hardcoded number break on another resolution?" — is misplaced;
  it scales by the same factor on every device.
- **The second argument to `Font:getFace(name, size)` is an *unscaled* design size**; the
  function still runs it through `scaleBySize` internally (`frontend/ui/font.lua:269-277`).
- **`FrameContainer`'s `width` / `height` are ignored by `getSize()`**
  (`framecontainer.lua:53-66`; only `paintTo` uses them, at lines 116-117, to draw the
  background and border). This plugin depends on that: `getSize()` returns content height
  plus padding, which is what lets the outer `CenterContainer` compute a zero offset.
- **The `readingprogress` mode is not forced into portrait** — `screensaver.lua:330-335`
  explicitly excludes it from `modeExpectsPortrait()`. Every size here is therefore
  derived from the short edge or the content height, never from `getWidth()` /
  `getHeight()`. **Landscape has not been verified on hardware, though.**
- **A `TextWidget`'s height depends only on the face, not on the text**
  (`textwidget.lua:112-113`), so any string in the right tier works as a probe for
  measuring row height.
- **Plugin load order**: plugins are instantiated in directory-name order, so `densestats`
  comes before `statistics` and `self.ui.statistics` does not exist yet during `init()` —
  the hook has to go in `onReaderReady`. KOReader 2026.07 also wraps plugin `onXxx`
  handlers in *callable tables* (a metatable with `__call`), so checking
  `type == "function"` is not enough.

## Known limitations

- **Landscape is unverified.** The orientation-independent sizing is in place, but it has
  never been run sideways on real hardware.
- **No fallback if even the smallest type step overflows.** Unreachable in portrait at
  normal DPI, but content would be clipped if it happened. The fix would be dropping a
  whole section, not shrinking type further.
- **Finished-book detection is a heuristic** — see the notes below.

All rendering is wrapped in `pcall`; on failure it falls back to the built-in page, so a
bug here can never keep the device awake.

## How the figures are defined

- **Per-page duration is capped.** Raw durations include "forgot to close the book" noise,
  so each is capped at `CFG.max_sec = 120`, matching what the statistics plugin does
  itself. The lifetime total is therefore lower than `book.total_read_time`.
- **Finished detection.** Completion status lives in the sidecar next to the book, not in
  the database. This uses `MAX(page/total_pages) >= 0.97` plus the month of the last read
  session — an estimate.
- **Time zones.** `start_time` is in UTC seconds; the offset is computed in Lua and passed
  into SQL rather than relying on SQLite's `localtime` modifier, because Kindles usually
  run with the system time zone set to UTC.
- **Streaks.** Not having read *today* does not break the streak; counting starts from
  yesterday.

## Licence

[AGPL-3.0](LICENSE), matching KOReader upstream.
