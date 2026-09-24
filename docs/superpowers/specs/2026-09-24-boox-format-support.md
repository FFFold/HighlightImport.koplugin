# Boox "读书笔记" Export Support — Design Spec

Date: 2026-09-24
Branch: `feat/boox-format-support`
Status: approved for implementation (scope A first, then scope B)

## Context

The plugin imports Kindle `My Clippings.txt` into KOReader. The requester uses a
Boox e-reader instead of a Kindle; Boox exports one annotation file per book
(filename suffix `-annotation-YYYY-MM-DD_HH_MM_SS.txt`). The layout is similar
in spirit to My Clippings but shares no delimiters with either parser currently
in `services/MyClipping.lua`, so Boox files silently produce zero targets today
(verified by running the real parser under LuaJIT against actual exports).

## Boox format (Chinese UI, observed)

```
读书笔记 | <<Title>>Author1,Author2      <- mandatory header (first line)
[Chapter heading]                        <- optional, appears before the date line
YYYY-MM-DD HH:MM  |  页码：N              <- entry start; minute resolution
highlight text line(s)                   <- continuation lines possible
【批注】note first line                   <- optional user note, only the first line has the prefix
note continuation line(s)                <- unprefixed, until the separator
-------------------                      <- separator (a run of "-")
```

Observed properties across 4 real exports / 2 books:

- no BOM, no U+3000 (full-width space), no blank lines, no `==========`
- one book per file; header title may be romanized or Chinese and does not
  necessarily match the EPUB title (`玩乐关系 03` vs `玩乐关系 第3卷`); the
  plugin's "use all clippings" fuzzy fallback handles that because a file only
  ever contains one book
- highlight text lines may carry leading spaces; a clipping that spans an EPUB
  paragraph junction can contain an inserted space (`…。 姐姐。…`)
- notes are always attached to a highlight; no standalone notes/bookmarks observed
- scope excludes non-Chinese UI exports and other date formats (personal use)

## Investigation findings that drive the design

1. `ParseClippings` never reads `entry[1].note`; notes only arrive via time+page
   pairing of separate `sort = "note"` entries. Probing showed:
   - inline `note` on a highlight entry is dropped in both automatic and manual modes
   - separate note entries need `time`; Boox timestamps have no seconds, so
     `getTime` returns nil and the note would be dropped
   - even with a time, two highlights on the same page/minute (a real case:
     three highlights at page 286, 23:37) would mis-pair the note
   => The Boox parser must bind notes inline, and `ParseClippings` must prefer
   `item.note` (two small edits).

2. Offline simulation of the `adaptive` fallback chain over the two real books:
   all targets import (0 failures), but ~45% end up with a shorter visual range
   than the stored annotation text because:
   - the search query is truncated to 150 bytes (`utf8Sub(annotation, 150)`),
     which is ~50 CJK characters (3 bytes per character)
   - fallback prefixes (80/50/40 bytes) and single-line retries highlight only
     one fragment
   - `ReaderAnnotation:addItem()` stores the `text` as given and does not
     re-extract it from `pos0/pos1`, so the mismatch is user-visible

3. `CreDocument:compareXPointers(a, b)` (1 = ordered, -1 = not, 0 = same, nil =
   invalid) and `CreDocument:getTextFromXPointers(pos0, pos1, draw_selection)`
   exist in KOReader v2026.07.1 and make scope B feasible.

## Scope A — Boox parser + inline notes

- New `MyClipping:parseBooxFormat(content, clippings, book_filter)` registered in
  `parseFile` before the existing new/old format dispatch.
- Entries carry `note` inline; `ParseClippings` uses
  `note = item.note or note_for_text[item.text]` in both target-building loops.
- No `getTime` changes, no title-matching changes.
- Known limitation: visual ranges may remain partial (scope B addresses it).

## Scope B — endpoint extension for partial matches

- New testable module `services/MatchingStrategies/endpoint.lua`:
  - builds head/tail probes from the annotation (first/last line, 60-byte
    utf8-safe truncations, whitespace-stripped variants)
  - searches candidates via `search:searchFromCurrent`
  - accepts the pair whose extracted span, with whitespace stripped, equals the
    whitespace-stripped annotation (covers paragraph-junction spaces); picks the
    pair closest to the original match when several verify
  - returns the original pointers unchanged when nothing verifies (no regression)
- `adaptive.lua` calls it only when `query ~= target.annotation`, only for
  rolling/CreDocument documents, before duplicate-xpointer bookkeeping so that
  two different long annotations sharing a truncated prefix no longer collapse.
- `exact_legacy` is untouched (it has no fallback chain to extend).

## Test strategy

- `tests/run_tests.lua` + `tests/harness.lua` + KOReader module stubs, runnable
  with LuaJIT/Lua 5.1 outside KOReader: `luajit tests/run_tests.lua`.
- Synthetic fixtures only (no real book text committed).
- Endpoint logic is unit-tested against a fake document/search with byte-offset
  xpointers.
- Real-sample regression stays a manual, uncommitted step (files in `.temp/`,
  which is added to `.gitignore`).
