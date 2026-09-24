# HighlightImport Plugin for KOReader

Import your e-reader highlights into KOReader as native highlights.

Supported sources:

- **Kindle** — the classic `My Clippings.txt`
- **Boox (Chinese UI)** — the per-book `读书笔记` annotation exports, including inline `【批注】` notes

## Features

- **Kindle "My Clippings.txt"** — old and new TXT layouts, multi-line highlights, and separately listed notes
- **Boox "读书笔记" exports** — files named `<Title>-annotation-YYYY-MM-DD_HH_MM_SS.txt`, with inline notes and chapter headings
- **Adaptive matching** that finds highlights when the clipping and the book text differ:
  - smart-typography normalization (curly quotes, en/em dashes, ellipses)
  - every retry searches the exact clipping text before its normalized form, in both search directions
  - progressive prefix shortening for wording differences between editions
  - newline splitting for multi-paragraph selections
  - full-range extension: a partial match is expanded to the whole clipping when the endpoints can be verified
- **Safe re-imports** — highlights whose text already exists in the open book are skipped
- **Review before import** — choose all or selected highlights, cancel mid-run, follow progress in the status popup
- **Failure handling** — view failed highlights from the status popup, optionally save them to `highlight_import_unmatched.txt`, or add them as a single in-book note
- **Manual source-book selection** — pick which book in the clippings file to use when its title does not match the open book
- **Native output** — imports become standard KOReader annotations (`datetime`, `drawer`, `color`, `pos0`/`pos1`), so KOReader-compatible sync tools (e.g. BookOrbit) see them like hand-made highlights; every imported highlight gets its own datetime so batch imports are not merged by tools that treat datetime as an identity

## Tested Platforms

- **Android (Boox)**: KOReader v2026.07.x — Boox export import, adaptive matching and full-range extension verified on real books
- **KDE neon User Edition 24.04 (Noble)**: KOReader v2025.08

The plugin should work on any platform that supports KOReader, including Linux desktop, e-ink readers (Kindle, Kobo, ...), and Android devices.

## Installation

### Method 1: Manual Installation (Recommended)

1. **Locate your KOReader plugins directory**:
   - **Linux**: `~/.config/koreader/plugins/` or `~/.var/app/rocks.koreader.KOReader/config/koreader/plugins/`
   - **Android**: `/sdcard/koreader/plugins/`
   - **E-ink devices**: Usually in the KOReader installation folder

2. **Clone the plugin**:
   ```bash
   cd ~/.config/koreader/plugins/   # or the path for your platform
   git clone https://github.com/FFFold/HighlightImport.koplugin.git
   ```

3. **Restart KOReader** to load the plugin

4. **Verify installation**:
   - Open any book in KOReader
   - Tap the top menu → **Typesetting** (or **Tools**)
   - You should see **Highlight Import** in the menu

### Method 2: Download ZIP

1. Download the plugin as a ZIP file from the [releases page](https://github.com/FFFold/HighlightImport.koplugin/releases)
2. Extract the ZIP file
3. Copy the `HighlightImport.koplugin` folder to your KOReader plugins directory
4. Restart KOReader

## Usage

### Step 1: Prepare Your Highlights

- **Kindle**: connect the device, copy `documents/My Clippings.txt` somewhere KOReader can read it
- **Boox**: export the book's reading notes (读书笔记) from the notes app. Each export is one book, named like `Book Title-annotation-2026-09-24_20_54_26.txt`; copy it to the device KOReader runs on

### Step 2: Open Your Book

1. Open the book in KOReader that matches the highlights
2. For very large books, paging through once before importing can help the search engine lay out the whole document

### Step 3: Access the Plugin Menu

1. Tap the **top menu** to open the main menu
2. Navigate to **Typesetting** (the icon with lines)
3. Find and tap **Highlight Import**

![Menu navigation - Typesetting](screenshots/menu1.png)

![Highlight Import menu location](screenshots/menu2.png)

### Step 4: Select the Clippings File

1. In the Highlight Import menu, tap **Select file**
2. Navigate to your `My Clippings.txt` / `-annotation-*.txt` file
3. **Long press** on the file to select it

![File chooser dialog](screenshots/file_chooser.png)

If the file contains several books, you can tap **Select source book** to pick the right one manually when automatic title matching would choose the wrong book.

### Step 5: Import Highlights

1. Open the **Highlight Import** menu again and tap **>Import<**
2. Review the parsed highlights and tap **Import all** or **Import selected**

![Imports view](screenshots/import.png)

3. Wait for the import process to complete; the status popup shows progress and a **Cancel** button

![Status popup](screenshots/status.png)

### Step 6: View Your Highlights

1. Tap the **top menu**, then the **Bookmarks** icon
2. Imported highlights appear next to any existing KOReader highlights

![Viewing imported bookmarks/highlights](screenshots/bookmarks.png)

You can also inspect the parsed highlights without importing them: **Highlight Import → Browse file highlights**.

![Browse file highlights](screenshots/annotation_list.png)

![Highlight preview](screenshots/annotation_preview.png)

## Menu Reference

| Menu item | What it does |
|---|---|
| Select file | Choose the clippings / annotation export file (long press) |
| Select source book | Manually choose which book to import when several are in the file |
| Import | Review and import the parsed highlights |
| Status | Show the last import summary |
| Browse file highlights | Preview the parsed highlights without importing |
| Settings | Matching algorithm and failure handling (see below) |
| About | Plugin information |

## Settings

- **Matching algorithm**
  - **Adaptive search** (default) — normalization, exact-first retries in both directions, prefix shortening, newline splitting and range extension
  - **Legacy (exact)** — the original direct search only
- **On fail: save unmatched to file** — writes `highlight_import_unmatched.txt` next to the selected clippings file
- **On fail: add note in book** — creates one annotation near the start of the book listing the unmatched highlights

## File Formats

### Kindle `My Clippings.txt`

```
Book Title (Author Name)
- Your Highlight on Location 123-456 | Added on Wednesday, July 9, 2025 10:43:50 AM

Highlight text content
==========
```

### Boox `读书笔记` export (Chinese UI)

```
读书笔记 | <<Title>>Author1,Author2
[Chapter heading]
YYYY-MM-DD HH:MM  |  页码：N
highlight text line(s)
【批注】note first line
note continuation line(s)
-------------------
```

One book per file. Notes are attached to the highlight directly above them.

## How Matching Works

For each clipping the plugin searches the open book for the text. When the exact text is not found, it retries with typography normalization, shorter prefixes, backward searches and line-by-line probes; a partial match is extended to the full clipping range and accepted only when the extracted text verifies against the document. Matches become native KOReader annotations using the current highlight color and the `lighten` drawer.

A diagnostic log is written next to the selected clippings file as `highlight_import.log` on every import.

## Troubleshooting

### No highlights imported

1. **Check the file format** — the file must be a Kindle `My Clippings.txt` or a Boox `读书笔记` export
2. **Check the failed list** — the status popup has a **View failed** button listing every highlight that could not be matched
3. **Check the log** — `highlight_import.log` next to the clippings file records every search attempt
4. **Enable failure handling** — *Settings → On fail: save unmatched to file* to get an `highlight_import_unmatched.txt` copy

### Some highlights fail

- The clipping text may not exist in this edition of the book. Try the option above to save or collect the failures
- If the file contains several books, set **Select source book** explicitly
- Re-importing is safe: highlights already present in the book are skipped by text

## Development

### Repository layout

```
main.lua                 plugin entry point and menu registration
services/                parsing and matching (MyClipping, MatchingStrategies, Document)
views/                   menu, import, settings and annotation dialogs
components/              shared widgets (modals, popups, file selector)
utils/                   ParseClippings, DateTime helpers
interfaces/              shared status constants
tests/                   LuaJIT test harness, stubs and fixtures
docs/superpowers/        design specs and implementation plans
```

### Running the tests

```bash
luajit tests/run_tests.lua
```

The suite runs with LuaJIT or Lua 5.1, uses only synthetic fixtures, and must end with `0 failed`. New matching or parsing logic is expected to come with a test.

### Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Credits

**Original author**: [nojux-official](https://github.com/nojux-official/HighlightImport.koplugin)

This fork adds Boox `读书笔记` support, adaptive full-range extension, exact-first search retries, unique import datetimes, and the LuaJIT test suite.

**Acknowledgments**:
- Built on [KOReader](https://github.com/koreader/koreader)'s plugin architecture
- `clip.lua` parser adapted from KOReader's [exporter.koplugin](https://github.com/koreader/koreader/tree/master/plugins/exporter.koplugin)
- Inspired by the KOReader community's need for highlight import functionality

## Support

- **Issues**: [GitHub Issues](https://github.com/FFFold/HighlightImport.koplugin/issues)
