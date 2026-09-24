# Boox Format Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import Boox "读书笔记" annotation exports (with inline notes) into KOReader, and make `adaptive` highlights cover the full clipping when only a shortened query matched.

**Architecture:** Scope A adds a third format parser (`parseBooxFormat`) to `services/MyClipping.lua` and teaches `utils/ParseClippings.lua` to honour an inline `note` field. Scope B extracts a small, unit-testable `services/MatchingStrategies/endpoint.lua` module that re-locates the head and tail of an annotation and verifies the span before extending `pos0/pos1`; `adaptive.lua` calls it only for shortened queries on rolling documents.

**Tech Stack:** Lua 5.1/LuaJIT (KOReader runtime), plain Lua test harness run with `luajit tests/run_tests.lua`, KOReader v2026.07.1 APIs (`compareXPointers`, `getTextFromXPointers`, `findAllText`).

**Spec:** `docs/superpowers/specs/2026-09-24-boox-format-support.md`

## Global Constraints

- Lua 5.1 / LuaJIT compatible syntax only (no `goto` in new code, no 5.2+ features).
- Never commit real book text; all fixtures are synthetic. `.temp/` stays untracked.
- Existing Kindle legacy/CJK parsing and note pairing must not regress (tested).
- Scope B runs only for rolling/CreDocument documents (`not has_pages`) and only when `query ~= target.annotation`.
- Extension is accepted only when `stripWs(span) == stripWs(annotation)`; otherwise original pointers are returned unchanged.
- Test/lint loop: `luajit tests/run_tests.lua` from the repo root (LuaJIT installed at `C:\Users\Fold\AppData\Local\Programs\LuaJIT\bin\luajit.exe` on this machine).

## Review Focus

- Boox file with a valid header but zero entries / trailing separator only: must return an empty result without crashing and without falling through to the old parser.
- A highlight line whose text starts with `【批注】`-like markers inside prose: only lines beginning exactly with `【批注】` become notes.
- Very common tail phrases (short dialogue lines) in a big book: verification must reject wrong spans; candidate caps must keep runtime bounded.
- PDF/paging documents: scope B must not touch them (`getTextFromXPointers`/`compareXPointers` are CreDocument APIs).
- Annotations spanning multiple EPUB paragraphs: extended `pos0/pos1` must be ordered (`compareXPointers(...) == 1`) or the extension is rejected.

---

### Task 1: Test harness, stubs, fixtures, ignore rules

**Files:**
- Create: `tests/run_tests.lua`
- Create: `tests/harness.lua`
- Create: `tests/stubs/gettext.lua`
- Create: `tests/stubs/logger.lua`
- Create: `tests/stubs/ui/widget/booklist.lua`
- Create: `tests/stubs/document/documentregistry.lua`
- Create: `tests/stubs/ffi/sha2.lua`
- Create: `tests/stubs/ffi/util.lua`
- Create: `tests/fixtures/boox_basic.txt`
- Create: `tests/fixtures/kindle_legacy.txt`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: `H.expect(actual, expected, label)`, `H.ok(cond, label)`, `H.isNil(v, label)`, `H.report()`, `H.root` (repo root path); `tests/run_tests.lua` exit code 0 on success.

- [ ] **Step 1: Write the runner and harness**

`tests/harness.lua`:

```lua
local H = { passed = 0, failed = 0, failures = {} }

local function fmt(v)
    if v == nil then return "nil" end
    if type(v) == "string" then return string.format("%q", v) end
    return tostring(v)
end

function H.expect(actual, expected, label)
    if actual == expected then
        H.passed = H.passed + 1
    else
        H.failed = H.failed + 1
        H.failures[#H.failures + 1] = string.format("%s: expected %s, got %s",
            label or "?", fmt(expected), fmt(actual))
    end
end

function H.ok(cond, label)
    if cond then
        H.passed = H.passed + 1
    else
        H.failed = H.failed + 1
        H.failures[#H.failures + 1] = (label or "?") .. ": condition failed"
    end
end

function H.isNil(v, label)
    H.expect(v, nil, label)
end

function H.report()
    for _, f in ipairs(H.failures) do
        print("FAIL: " .. f)
    end
    print(string.format("%d passed, %d failed", H.passed, H.failed))
    os.exit(H.failed == 0 and 0 or 1)
end

return H
```

`tests/run_tests.lua`:

```lua
-- Run with: luajit tests/run_tests.lua   (from the repo root)
local script = (arg and arg[0]) or "tests/run_tests.lua"
local root = script:match("^(.*)[/\\]tests[/\\][^/\\]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/tests/stubs/?.lua;" .. package.path

local H = require("tests.harness")
H.root = root

local test_modules = {
    "tests.test_parse_boox",
    "tests.test_parse_clippings_notes",
    "tests.test_endpoint",
}

for _, name in ipairs(test_modules) do
    local ok, err = pcall(require, name)
    if ok and type(err) == "function" then
        local ran, run_err = pcall(err, H)
        if not ran then
            H.failed = H.failed + 1
            H.failures[#H.failures + 1] = name .. ": " .. tostring(run_err)
        end
    elseif not ok then
        -- module intentionally absent until its task lands
        print("SKIP (not implemented yet): " .. name)
    end
end

H.report()
```

- [ ] **Step 2: Write the KOReader stubs**

`tests/stubs/gettext.lua`:

```lua
return function(s) return s end
```

`tests/stubs/logger.lua`:

```lua
return {
    dbg = function() end,
    info = function() end,
    warn = function() end,
    err = function() end,
}
```

`tests/stubs/ui/widget/booklist.lua`:

```lua
return {}
```

`tests/stubs/document/documentregistry.lua`:

```lua
return {}
```

`tests/stubs/ffi/sha2.lua`:

```lua
return { md5 = function() return "" end }
```

`tests/stubs/ffi/util.lua`:

```lua
return {
    template = function(fmt, ...)
        local args = { ... }
        return (fmt:gsub("%%(%d)", function(n)
            return tostring(args[tonumber(n)] or "")
        end))
    end,
}
```

- [ ] **Step 3: Write the synthetic fixtures**

`tests/fixtures/boox_basic.txt`:

```
读书笔记 | <<测试之书>>测试作者,第二作者
第一章
2026-01-02 03:04  |  页码：12
第一行高亮内容，包含一些标点。
第二行继续的内容，前面有缩进。
【批注】这是第一条笔记
笔记的续行内容
-------------------
第二章
2026-01-02 03:05  |  页码：13
第二条高亮，没有笔记。
-------------------
```

`tests/fixtures/kindle_legacy.txt`:

```
测试之书 (测试作者)
- Your Highlight on page 5 | Location 100-101 | Added on Monday, April 21, 2014 10:08:07 PM

第一条英文高亮文本。
==========
测试之书 (测试作者)
- Your Note on page 5 | Location 100 | Added on Monday, April 21, 2014 10:09:07 PM

这条是笔记
==========
```

- [ ] **Step 4: Ignore the personal samples**

`.gitignore` becomes:

```
stuff
.temp/
```

- [ ] **Step 5: Run the harness (no tests implemented yet)**

Run: `luajit tests/run_tests.lua` (or the full path
`& "C:\Users\Fold\AppData\Local\Programs\LuaJIT\bin\luajit.exe" tests/run_tests.lua`)
Expected: `SKIP (not implemented yet): tests.test_parse_boox` (×3) and `0 passed, 0 failed`, exit code 0.

- [ ] **Step 6: Commit**

```powershell
git add .gitignore tests
git commit -m "test: add LuaJIT test harness, stubs and synthetic fixtures"
```

---

### Task 2: `parseBooxFormat` in `services/MyClipping.lua`

**Files:**
- Create: `tests/test_parse_boox.lua`
- Modify: `services/MyClipping.lua` (add parser before `parseNewFormat`; extend `parseFile` dispatch)

**Interfaces:**
- Consumes: `MyClipping:new{}`, `parser:parseFile(path, book_filter)`, `bare(title)` (module-local).
- Produces: `MyClipping:parseBooxFormat(content, clippings, book_filter) -> boolean` (true when the header is recognised). Entries are `{ page = "<digits>", sort = "highlight", text = "...", note = "..."|nil, chapter = "..."|nil }` inserted as `{ entry }`.

- [ ] **Step 1: Write the failing test**

`tests/test_parse_boox.lua`:

```lua
return function(H)
    local MyClipping = require("services.MyClipping")
    local parser = MyClipping:new{}
    local path = H.root .. "/tests/fixtures/boox_basic.txt"

    local clippings = parser:parseFile(path, "")
    local book = clippings["测试之书"]
    H.ok(book ~= nil, "boox: book key present")
    H.expect(book and book.author, "测试作者,第二作者", "boox: author")
    H.expect(book and #book, 2, "boox: entry count")

    local e1 = book and book[1] and book[1][1]
    H.expect(e1 and e1.page, "12", "boox: entry1 page")
    H.expect(e1 and e1.sort, "highlight", "boox: entry1 sort")
    H.expect(e1 and e1.text, "第一行高亮内容，包含一些标点。\n第二行继续的内容，前面有缩进。", "boox: entry1 text")
    H.expect(e1 and e1.note, "这是第一条笔记\n笔记的续行内容", "boox: entry1 note")
    H.expect(e1 and e1.chapter, "第一章", "boox: entry1 chapter")

    local e2 = book and book[2] and book[2][1]
    H.expect(e2 and e2.page, "13", "boox: entry2 page")
    H.isNil(e2 and e2.note, "boox: entry2 has no note")

    -- book_filter mismatch: header recognised, no book emitted (caller does fuzzy fallback)
    local filtered = parser:parseFile(path, "别的书名")
    H.isNil(filtered["测试之书"], "boox: filter mismatch skips book")

    -- legacy Kindle files must still be parsed by the old parser
    local legacy = parser:parseFile(H.root .. "/tests/fixtures/kindle_legacy.txt", "")
    H.ok(legacy["测试之书"] ~= nil, "legacy: book parsed")
    H.expect(legacy["测试之书"][1][1].sort, "highlight", "legacy: sort kept")
    H.expect(legacy["测试之书"][1][1].text, "第一条英文高亮文本。", "legacy: text kept")
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `luajit tests/run_tests.lua`
Expected: failures like `boox: book key present: condition failed`, exit code 1.

- [ ] **Step 3: Implement the parser**

In `services/MyClipping.lua`, add after `parseNewFormat` (or next to it):

```lua
-- Boox (Chinese UI) "读书笔记" export format:
--   读书笔记 | <<Title>>Author1,Author2
--   [Chapter]
--   YYYY-MM-DD HH:MM  |  页码：N
--   highlight text lines
--   【批注】note first line
--   note continuation lines
--   -------------------
function MyClipping:parseBooxFormat(content, clippings, book_filter)
    -- The header is mandatory and unique to this format.
    local header = content:match("^([^\r\n]*)")
    local title, author = header and header:match("^%s*读书笔记%s*|%s*<<(.-)>>%s*(.-)%s*$")
    if not title or title == "" then
        return false
    end

    local skip_book = book_filter and book_filter ~= "" and bare(title) ~= book_filter
    if not skip_book then
        clippings[title] = clippings[title] or {
            title = title,
            author = (author ~= nil and author ~= "") and author or _("Unknown Author"),
        }
    end

    local chapter = nil
    local current = nil

    local function flush()
        if current and current.text ~= "" and not skip_book then
            table.insert(clippings[title], { current })
        end
        current = nil
    end

    local is_header = true
    for line in content:gmatch("[^\r\n]+") do
        if is_header then
            is_header = false
        else
            local s = self:getText(line)
            if s:match("^%-%-%-+$") then
                flush()
            elseif s:match("^【批注】") then
                if current then
                    current.note = s:match("^【批注】%s*(.-)%s*$") or ""
                end
            elseif current and current.note ~= nil then
                current.note = (current.note == "") and s or (current.note .. "\n" .. s)
            elseif current then
                current.text = (current.text == "") and s or (current.text .. "\n" .. s)
            else
                local page = s:match("^%d%d%d%d%-%d%d%-%d%d%s+%d%d:%d%d%s*|%s*页码：%s*(%d+)")
                if page then
                    current = {
                        page = page,
                        sort = "highlight",
                        text = "",
                        chapter = chapter,
                    }
                elseif s ~= "" then
                    chapter = s
                end
            end
        end
    end
    flush()

    return true
end
```

Update `parseFile`'s dispatch:

```lua
function MyClipping:parseFile(file_path, book_filter)
    local file = io.open(file_path, "r")
    local clippings = {}
    if file then
        local content = file:read("*a")
        file:close()
        if not self:parseBooxFormat(content, clippings, book_filter)
                and not self:parseNewFormat(content, clippings, book_filter) then
            self:parseOldFormat(content, clippings, book_filter)
        end
        content = nil  -- allow GC of the large string
    end
    return clippings
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `luajit tests/run_tests.lua`
Expected: `PASS`-style summary (`0 failed`); `tests.test_parse_clippings_notes` and `tests.test_endpoint` still SKIP.

- [ ] **Step 5: Commit**

```powershell
git add services/MyClipping.lua tests/test_parse_boox.lua
git commit -m "feat: parse Boox 读书笔记 exports (highlights, chapters, inline notes)"
```

---

### Task 3: Inline note binding in `utils/ParseClippings.lua`

**Files:**
- Create: `tests/test_parse_clippings_notes.lua`
- Modify: `utils/ParseClippings.lua` (two target-building loops)

**Interfaces:**
- Consumes: parsed clippings from Task 2; the existing `note_for_text` time/page pairing.
- Produces: targets with `note = item.note or note_for_text[item.text]`.

- [ ] **Step 1: Write the failing test**

`tests/test_parse_clippings_notes.lua`:

```lua
return function(H)
    local MyClipping = require("services.MyClipping")
    local ParseClippings = require("utils.ParseClippings")
    local parser = MyClipping:new{}

    -- Boox fixture: title does not match the open document, so the fuzzy
    -- fallback ("use all clippings") must still yield both targets and keep
    -- the inline note on the first one.
    local instance = {
        parser = parser,
        file_path = H.root .. "/tests/fixtures/boox_basic.txt",
        targets = {},
        ui = {
            document = { file = "/books/whatever.epub" },
            doc_props = { title = "不匹配的书名", authors = "" },
        },
    }
    local targets = ParseClippings(instance)
    H.expect(#targets, 2, "clippings: two targets")
    H.expect(targets[1] and targets[1].note, "这是第一条笔记\n笔记的续行内容", "clippings: inline note bound")
    H.isNil(targets[2] and targets[2].note, "clippings: second target has no note")
    H.expect(targets[1] and targets[1].page, "12", "clippings: page preserved")

    -- Legacy Kindle pairing (separate sort="note" entry) must not regress.
    local instance2 = {
        parser = parser,
        file_path = H.root .. "/tests/fixtures/kindle_legacy.txt",
        targets = {},
        ui = {
            document = { file = "/books/whatever.epub" },
            doc_props = { title = "测试之书", authors = "测试作者" },
        },
    }
    local targets2 = ParseClippings(instance2)
    H.expect(#targets2, 1, "legacy: one target")
    H.expect(targets2[1] and targets2[1].note, "这条是笔记", "legacy: paired note still works")
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `luajit tests/run_tests.lua`
Expected: `clippings: inline note bound` fails (got `nil`); the legacy pairing assertion already passes.

- [ ] **Step 3: Implement the note fallback**

In `utils/ParseClippings.lua`, in the manual-selection target loop AND the automatic target loop, change:

```lua
                    note       = note_for_text[item.text],
```

to:

```lua
                    note       = item.note or note_for_text[item.text],
```

(Both loops contain this exact line; `replaceAll` is safe.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `luajit tests/run_tests.lua`
Expected: all three test modules run; `0 failed`.

- [ ] **Step 5: Commit**

```powershell
git add utils/ParseClippings.lua tests/test_parse_clippings_notes.lua
git commit -m "fix: bind inline clipping notes to their highlight in ParseClippings"
```

---

### Task 4: Endpoint extension module (scope B)

**Files:**
- Create: `services/MatchingStrategies/endpoint.lua`
- Create: `tests/test_endpoint.lua`

**Interfaces:**
- Consumes: a CreDocument-like object with `findAllText(pattern, case_insensitive, nb_context_words, max_hits, regex)`, `getPageFromXPointer(xp)`, `getTextFromXPointers(pos0, pos1)`, `compareXPointers(a, b)`.
- Produces:
  - `Endpoint.stripWs(s) -> string`
  - `Endpoint.utf8Sub(s, max_bytes) -> string`
  - `Endpoint.utf8Suffix(s, max_bytes) -> string`
  - `Endpoint.buildProbes(annotation) -> heads, tails` (lists of probe strings)
  - `Endpoint.extend(document, start_xp, end_xp, annotation) -> extended_start, extended_end`

- [ ] **Step 1: Write the failing tests**

`tests/test_endpoint.lua`:

```lua
-- Fake CreDocument over a byte string. "XPointers" are integer byte offsets:
-- an xpointer N marks the position before byte N, so getText(a, b) is the
-- half-open byte range (a, b].
local function makeDoc(text)
    return {
        text = text,
        compareXPointers = function(self, a, b)
            if type(a) ~= "number" or type(b) ~= "number" then return nil end
            if a == b then return 0 end
            return a < b and 1 or -1
        end,
        getPageFromXPointer = function(self, xp)
            return math.floor(xp / 100) + 1
        end,
        getTextFromXPointers = function(self, a, b)
            if type(a) ~= "number" or type(b) ~= "number" or b < a then return nil end
            return self.text:sub(a + 1, b)
        end,
        findAllText = function(self, pattern)
            local res = {}
            local init = 0
            while true do
                local s, e = self.text:find(pattern, init + 1, true)
                if not s then break end
                res[#res + 1] = { start = s - 1, ["end"] = e }
                init = e
            end
            return res
        end,
    }
end

local function at(text, needle)
    local s = text:find(needle, 1, true)
    return s - 1, s - 1 + #needle
end

return function(H)
    local Endpoint = require("services.MatchingStrategies.endpoint")

    -- utf8-safe helpers
    H.expect(Endpoint.utf8Sub("一二三四五", 4), "一", "utf8Sub cuts at char boundary")
    H.expect(Endpoint.utf8Suffix("一二三四五", 4), "五", "utf8Suffix cuts at char boundary")
    H.expect(Endpoint.stripWs("甲 乙\n丙\t丁"), "甲乙丙丁", "stripWs removes ASCII whitespace")

    -- probes exist for both ends of a single-line annotation (regression:
    -- head and tail dedup must not remove the tail list)
    local heads, tails = Endpoint.buildProbes("这是一条单行的高亮内容，足够长。")
    H.ok(#heads > 0, "probes: heads non-empty")
    H.ok(#tails > 0, "probes: tails non-empty for single-line annotation")

    -- multi-line clipping whose first line has a junction space the EPUB lacks
    local doc_text = "开头。「……内衣呢？」「没穿哦？」「从什么时候开始的？」「洗完澡之后」结尾。"
    local h0, _ = at(doc_text, "「……内衣呢？」")
    local l2, l2e = at(doc_text, "「没穿哦？」")
    local _, te = at(doc_text, "「洗完澡之后」")
    local annotation = "「…… 内衣呢？」\n「没穿哦？」\n「从什么时候开始的？」\n「洗完澡之后」"
    local doc = makeDoc(doc_text)
    local s, e = Endpoint.extend(doc, l2, l2e, annotation)
    H.expect(s, h0, "extend: head recovered")
    H.expect(e, te, "extend: tail recovered")

    -- middle-line match and duplicate tail occurrences (before and after the
    -- true one) must not fool the verifier
    local doc_text2 = "前言。丙段内容七八九。甲段内容一二三。乙段内容四五六。丙段内容七八九。尾。丙段内容七八九。后记。"
    local a0, _ = at(doc_text2, "甲段内容一二三。")
    local b0, b1 = at(doc_text2, "乙段内容四五六。")
    local _, true_te = at(doc_text2, "丙段内容七八九。尾。")
    true_te = true_te - #"尾。"
    local doc2 = makeDoc(doc_text2)
    local ann2 = "甲段内容一二三。\n乙段内容四五六。\n丙段内容七八九。"
    local s2, e2 = Endpoint.extend(doc2, b0, b1, ann2)
    H.expect(s2, a0, "extend: start repaired from middle-line match")
    H.expect(e2, true_te, "extend: correct tail chosen among duplicates")

    -- no verification possible -> original pointers unchanged
    local doc_text3 = "只有一段内容。"
    local x0, x1 = at(doc_text3, "只有一段内容。")
    local doc3 = makeDoc(doc_text3)
    local s3, e3 = Endpoint.extend(doc3, x0, x1, "完全不同的内容一。\n完全不同的内容二。")
    H.expect(s3, x0, "extend: unchanged start when nothing verifies")
    H.expect(e3, x1, "extend: unchanged end when nothing verifies")

    -- already full coverage -> unchanged
    local doc_text4 = "这是一条完整覆盖的高亮内容，足够长。"
    local y0, y1 = at(doc_text4, doc_text4)
    local doc4 = makeDoc(doc_text4)
    local s4, e4 = Endpoint.extend(doc4, y0, y1, doc_text4)
    H.expect(s4, y0, "extend: full coverage keeps start")
    H.expect(e4, y1, "extend: full coverage keeps end")
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `luajit tests/run_tests.lua`
Expected: `tests.test_endpoint` fails with a module-not-found error (counted as a failure).

- [ ] **Step 3: Implement `services/MatchingStrategies/endpoint.lua`**

```lua
-- Recover the full range of a partially matched annotation.
--
-- `adaptive` may match a highlight with a shortened query (150-byte
-- truncation, 80/50-byte prefixes, a single line of a multi-line clipping).
-- The stored annotation text is then longer than the highlighted range.
-- This module re-locates the head and the tail of the annotation and accepts
-- an extension only when the text between them equals the annotation with all
-- ASCII whitespace removed (which also covers paragraph-junction spaces
-- inserted by e-reader exports).
local Endpoint = { MAX_CANDIDATES = 30 }

local WS_CLASS = "[ \t\r\n\v\f]+"

function Endpoint.stripWs(s)
    return (s or ""):gsub(WS_CLASS, "")
end

-- Truncate a string safely at a UTF-8 character boundary (byte-based).
function Endpoint.utf8Sub(s, max_bytes)
    if #s <= max_bytes then return s end
    local i = max_bytes
    while i > 0 and s:byte(i) >= 0x80 and s:byte(i) <= 0xBF do
        i = i - 1
    end
    if i > 0 and s:byte(i) >= 0x80 then i = i - 1 end
    return s:sub(1, i)
end

-- UTF-8 safe suffix of at most max_bytes bytes.
function Endpoint.utf8Suffix(s, max_bytes)
    if #s <= max_bytes then return s end
    local i = #s - max_bytes + 1
    while i <= #s and s:byte(i) >= 0x80 and s:byte(i) <= 0xBF do
        i = i + 1
    end
    return s:sub(i)
end

local function trim(s)
    return (s or ""):match("^%s*(.-)%s*$") or ""
end

-- Build probe lists ordered from least to most destructive: raw line,
-- byte truncation, whitespace-stripped variants.
function Endpoint.buildProbes(annotation)
    local heads, tails = {}, {}
    local seen = { [heads] = {}, [tails] = {} }
    local function add(list, s)
        s = trim(s)
        if #s < 12 or seen[list][s] then return end
        seen[list][s] = true
        list[#list + 1] = s
    end
    local ann = annotation or ""
    local first = ann:match("^([^\r\n]*)") or ""
    local last = ann:match("([^\r\n]*)$") or ""
    add(heads, first)
    add(heads, Endpoint.utf8Sub(first, 60))
    add(heads, Endpoint.stripWs(first))
    add(heads, Endpoint.stripWs(Endpoint.utf8Sub(first, 60)))
    add(tails, last)
    add(tails, Endpoint.utf8Sub(last, 60))
    add(tails, Endpoint.utf8Suffix(ann, 60))
    add(tails, Endpoint.stripWs(last))
    add(tails, Endpoint.stripWs(Endpoint.utf8Sub(last, 60)))
    add(tails, Endpoint.stripWs(Endpoint.utf8Suffix(ann, 60)))
    return heads, tails
end

function Endpoint.findCandidates(document, probe)
    local candidates = {}
    local res = document:findAllText(probe, true, 5, 2048, false)
    for _, r in ipairs(res or {}) do
        if r and r.start and r["end"] then
            candidates[#candidates + 1] = { start = r.start, ["end"] = r["end"] }
        end
    end
    return candidates
end

local function pageOf(document, xp)
    return document:getPageFromXPointer(xp) or 1
end

function Endpoint.extend(document, start_xp, end_xp, annotation)
    local plain_ann = Endpoint.stripWs(annotation)
    if #plain_ann < 12 then return start_xp, end_xp end

    local covered = document:getTextFromXPointers(start_xp, end_xp)
    if covered and Endpoint.stripWs(covered) == plain_ann then
        return start_xp, end_xp
    end

    local heads, tails = Endpoint.buildProbes(annotation)
    local base_page = pageOf(document, start_xp)
    -- A page holds a few hundred CJK characters; annotations never span many.
    local span_pages = math.max(1, math.ceil(#plain_ann / 500))

    local function collect(probes)
        local out, seen = {}, {}
        for _, probe in ipairs(probes) do
            for _, c in ipairs(Endpoint.findCandidates(document, probe)) do
                local p = document:getPageFromXPointer(c.start)
                if (not p) or (p >= base_page - 1 and p <= base_page + span_pages + 2) then
                    local key = tostring(c.start) .. "|" .. tostring(c["end"])
                    if not seen[key] then
                        seen[key] = true
                        if #out < Endpoint.MAX_CANDIDATES then
                            out[#out + 1] = c
                        end
                    end
                end
            end
        end
        return out
    end

    local head_hits = collect(heads)
    local tail_hits = collect(tails)
    if #head_hits == 0 or #tail_hits == 0 then
        return start_xp, end_xp
    end

    local best_start, best_end, best_score
    for _, h in ipairs(head_hits) do
        for _, t in ipairs(tail_hits) do
            if document:compareXPointers(h.start, t["end"]) == 1 then
                local span = document:getTextFromXPointers(h.start, t["end"])
                if span and Endpoint.stripWs(span) == plain_ann then
                    local score = math.abs(pageOf(document, h.start) - base_page)
                                  + math.abs(pageOf(document, t["end"]) - pageOf(document, end_xp))
                    if not best_score or score < best_score then
                        best_start, best_end, best_score = h.start, t["end"], score
                    end
                end
            end
        end
    end

    if best_start then
        return best_start, best_end
    end
    return start_xp, end_xp
end

return Endpoint
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `luajit tests/run_tests.lua`
Expected: `0 failed`.

- [ ] **Step 5: Commit**

```powershell
git add services/MatchingStrategies/endpoint.lua tests/test_endpoint.lua
git commit -m "feat: add endpoint extension module for partially matched highlights"
```

---

### Task 5: Wire endpoint extension into `adaptive`, docs, verification

**Files:**
- Modify: `services/MatchingStrategies/adaptive.lua`
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-09-24-boox-format-support.md` (status only, optional)

**Interfaces:**
- Consumes: `Endpoint.extend(document, start_xp, end_xp, annotation)` from Task 4.
- Produces: imports with full visual ranges when endpoints can be verified.

- [ ] **Step 1: Use `Endpoint.utf8Sub` in adaptive (DRY)**

Replace the local `utf8_sub` definition (lines ~52-67) and all `utf8_sub(` call sites with `Endpoint.utf8Sub(`, and add at the top:

```lua
local Endpoint = require("services.MatchingStrategies.endpoint")
```

- [ ] **Step 2: Extend the match before duplicate bookkeeping**

Replace the block that starts at `local xpointer_start = res[1].start` with:

```lua
        local xpointer_start = res[1].start
        local xpointer_end = res[1]["end"]

        -- When the winning query was shortened (truncation/prefix/split-line),
        -- try to recover the full annotation range before creating the
        -- highlight. Rolling documents only: PDF positions are page numbers.
        if not has_pages and query ~= target.annotation then
            local ext_start, ext_end = Endpoint.extend(
                instance.ui.document, xpointer_start, xpointer_end, target.annotation)
            if ext_start ~= xpointer_start or ext_end ~= xpointer_end then
                log(string.format("[EXTEND] %s → %s", tostring(ext_start), tostring(ext_end)))
                xpointer_start, xpointer_end = ext_start, ext_end
            end
        end

        local xp_key = xpointer_start .. "|" .. xpointer_end
```

(The `used_xpointers` check stays immediately after, now keyed on the extended range.)

- [ ] **Step 3: Run the unit test suite**

Run: `luajit tests/run_tests.lua`
Expected: `0 failed` (Task 4 tests cover the extension logic; adaptive has no unit tests).

- [ ] **Step 4: Manual real-sample regression (not committed)**

Run the parser-only harness against the personal samples in `.temp/` and check
that all entries parse with notes attached:

```powershell
& "C:\Users\Fold\AppData\Local\Programs\LuaJIT\bin\luajit.exe" "C:\Users\Fold\AppData\Local\Temp\opencode\hi-test\run.lua"
```

Expected (after updating that harness path to the current samples): book key
present, entries = 20 / 35, notes = 2 / 0, `ParseClippings` targets = 20 / 35.

- [ ] **Step 5: Update README features**

Add under `## Features`:

```markdown
- Import Boox (Chinese UI) "读书笔记" exports, including inline notes from 批注
- Adaptive range extension: long or multi-paragraph highlights are highlighted in full when the endpoints can be located
```

- [ ] **Step 6: Commit**

```powershell
git add services/MatchingStrategies/adaptive.lua README.md
git commit -m "feat: extend adaptive highlights to the full clipping range (Boox/EPUB)"
```

---

## Self-Review Notes

- Spec coverage: parser + inline notes (Tasks 2-3), endpoint extension (Tasks 4-5), tests and `.temp/` hygiene (Task 1); non-goals (other languages, date variants, exact_legacy) intentionally absent.
- The `parseBooxFormat` header match is the format detector, so it returns `true` even when `book_filter` skips the book; the caller's fuzzy fallback re-parses without a filter (existing behaviour).
- `Endpoint` caps candidates and filters by page window to bound worst-case cost; verification is exact, so a rejected candidate can only mean "keep the original partial range", never a wrong highlight.
- Interface names used across tasks: `Endpoint.stripWs`, `Endpoint.utf8Sub`, `Endpoint.utf8Suffix`, `Endpoint.buildProbes`, `Endpoint.findCandidates`, `Endpoint.extend`; test helpers `H.expect`, `H.ok`, `H.isNil`, `H.root`.
