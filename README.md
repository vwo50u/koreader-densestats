# densestats.koplugin

**English** · [简体中文](README.zh-CN.md)

A dense reading-statistics screensaver for [KOReader](https://github.com/koreader/koreader).

It takes over KOReader's built-in `readingprogress` screensaver type: in that mode
`frontend/ui/screensaver.lua` asks the statistics plugin for a widget through
`ui.statistics:onShowReaderProgress(true)`, and this plugin wraps that method. Keep
choosing "Show reading progress on the sleep screen" in the settings; what gets drawn is
this plugin's version instead.

The plugin only **reads** the statistics plugin's `statistics.sqlite3`, never writes to it.
**The statistics plugin must stay enabled** — `screensaver.lua` checks for `ui.statistics`
and falls back to a random image if it isn't there.

> Heads up for contributors: the source comments are written in Chinese. The code itself
> reads fine without them, but the reasoning behind the layout decisions does not.

## What it shows

Top to bottom:

- **Time read today** — the one large figure on the screen, written as `1:20`.
  Nothing read yet today falls back to yesterday, then to this week, with the label changed
- **One small line** — streak · lifetime total · books finished; zero values are omitted
- **A 30-day chart** — thin dark-grey bars with gaps, empty where nothing was read;
  no title, no numbers. Today's bar is light grey, since the day is usually unfinished
- **Currently reading** — title (subtitle dropped if it does not fit on one line),
  author · percentage (rounded down) · estimated time left (this book's own pace,
  pages read in the current pagination only), the current chapter with the pages left
  in it (only when the screen locks from the reader, since the table of contents
  belongs to the open document), and a hairline progress bar ticked at 25/50/75%
  (black for what is read, light grey for the rest)
- **Battery** — tiny grey text in the bottom-right corner. No clock: a sleep screen
  is rendered once and then freezes, and a frozen clock only misleads

### Layout principles

Minimal, generous white space, left-aligned. Three rules:

- three type sizes only, and the large one goes to a single figure;
- three ink levels (black / dark grey / light grey), with black reserved for today's
  time and the book title;
- sections are separated by space, never by rules.

Sizes are KOReader "design sizes": `Font:getFace` scales them by short edge / 600, so
they hold across resolutions. The content is fixed and fits in both orientations, so
there is no fit-to-screen loop; spacing is a fraction of screen height and tightens
in landscape.

## Layout

```
densestats.koplugin/
  main.lua       rendering and plugin wiring (the only file touching KOReader widgets)
  stats.lua      duration formatting + time-series derivation (pure Lua, unit-tested)
  finished.lua   scans sidecars to count finished books (pure Lua, unit-tested)
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

The finished-book count cannot be checked there: it comes from the sidecars, not from
the database (see "How the figures are defined").

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

**Desktop builds have no sleep screen**, so the hook never fires. Start with
`DENSESTATS_AUTOSHOW=1` instead and the same widget pops up after six seconds;
`DENSESTATS_SHOT=/path/to/shot.png` saves it as a PNG two seconds later. On a device,
just lock the screen.

Building from source with `./kodev build` is not worth it for UI work — compiling
koreader-base from scratch on macOS arm64 takes hours.

### 3. On a device

With the device mounted over USB, `./dev.sh install` copies the plugin into the right
place (`koreader/plugins/` on a Kindle, `.adds/koreader/plugins/` on a Kobo) and diffs
the result; INSTALL.md covers doing it by hand. Restart KOReader afterwards. Logs land
in `koreader/crash.log` (`logger.warn` output goes there); every sleep writes a
`densestats build:` line with the SQL and layout times, the database size and the
time-zone offset in use. KOReader's bundled SSH plugin lets you tail it remotely.

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
  comes before `statistics` and `self.ui.statistics` does not exist yet during `init()`.
  The hook is installed from `registerPostInitCallback`, which both ReaderUI and the
  file manager run once every module is registered; `onReaderReady` exists only in
  ReaderUI and is kept as a fallback. KOReader 2026.07 also wraps plugin `onXxx`
  handlers in *callable tables* (a metatable with `__call`), so checking
  `type == "function"` is not enough.

## Status

Verified in portrait on a Kindle Paperwhite 3 (1072×1448). Everything below is what
remains open.

## Known limitations

- **Landscape is unverified.** The orientation-independent sizing is in place, but it has
  never been run sideways on real hardware.
- **Content taller than the screen only eats the top margin.** The content is fixed and
  fits in both orientations at normal DPI, so this should not happen; if it did, the fix
  would be dropping a section, not shrinking type.
- **Only books marked finished in KOReader are counted** — see the notes below.

All rendering is wrapped in `pcall`; on failure it falls back to the built-in page, so a
bug here can never keep the device awake.

## How the figures are defined

- **Per-page duration is capped.** Raw durations include "forgot to close the book" noise,
  so the per-day figures cap each page at the statistics plugin's own "max time per page"
  setting (`CFG.max_sec = 120` is only the fallback when that setting is absent).
- **The lifetime total is KOReader's own.** It is the sum of `book.total_read_time`, the
  same figure the statistics plugin shows, rather than a recount from the page table, so
  the two never disagree.
- **Finished books** are the sidecars whose `summary.status` is `complete`, i.e. books
  marked finished in KOReader. The library and the docsettings directories are scanned
  in a subprocess at most every 12 hours and the count is cached; "Rescan finished
  books" in the menu (also bindable as a gesture) forces it.
- **Time zones.** `start_time` is in UTC seconds. Days are cut at local midnight using
  the process time zone, which is what the statistics plugin's `localtime` grouping does
  too; on a Kindle, whose system zone is UTC, the offset is 0. The value in use is
  printed as `tz=` in the build log line; `DENSESTATS_TZ_OFFSET` overrides it for reading
  a device's database on another machine.
- **Streaks.** Not having read *today* does not break the streak; counting starts from
  yesterday.

## Licence

[AGPL-3.0](LICENSE), matching KOReader upstream.
