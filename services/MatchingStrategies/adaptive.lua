local _ = require("gettext")
local logger = require("logger")
local ITargetStatus = require("interfaces.ITargetStatus")
local UIManager = require("ui/uimanager")

local useRecreateStatusPopup = require("composables.useRecreateStatusPopup")
local Document = require("services.Document")
local Endpoint = require("services.MatchingStrategies.endpoint")

return function (instance)

    local doc = Document:new(instance)

    logger.dbg(string.format("HighlightImport: Local matching starting. Targets: %d", #instance.targets))

    if not doc:IsDocReady() then return end
    if not instance.ui then error("No ReaderUI instance running") end

    local search = instance.ui.search
    local has_pages = instance.ui.document.info.has_pages

    -- Build set of existing highlight texts to skip duplicates on re-import
    local existing = {}
    if instance.ui.annotation and instance.ui.annotation.annotations then
        for _, ann in ipairs(instance.ui.annotation.annotations) do
            if ann.text then existing[ann.text] = true end
        end
    end

    -- Sort by page ascending. Extract first number from range strings like "42-43".
    table.sort(instance.targets, function(a, b)
        local pa = tonumber(tostring(a.page or ""):match("^(%d+)")) or 0
        local pb = tonumber(tostring(b.page or ""):match("^(%d+)")) or 0
        return pa < pb
    end)

    -- Log file for debugging (written next to the clippings file)
    local log_dir = instance.file_path:match("(.*/)")
    local log_path = log_dir and (log_dir .. "highlight_import.log") or nil
    local log_file = log_path and io.open(log_path, "w") or nil
    local function log(msg)
        local ts = os.date("%H:%M:%S")
        local line = string.format("[%s] %s", ts, msg)
        logger.dbg("HighlightImport: " .. line)
        if log_file then log_file:write(line .. "\n") end
    end

    local n_existing = 0
    for _ in pairs(existing) do n_existing = n_existing + 1 end
    log(string.format("Starting import. Targets: %d, Existing highlights: %d",
        #instance.targets, n_existing))

    -- Normalize curly/smart typography to ASCII equivalents.
    -- Used as a fallback when the exact text fails to match, which happens when
    -- the Kindle edition used smart quotes/dashes but the EPUB uses plain ASCII.
    local function normalize_typography(s)
        s = s:gsub("\xe2\x80\x98", "'")   -- U+2018 left single quote
        s = s:gsub("\xe2\x80\x99", "'")   -- U+2019 right single quote / apostrophe
        s = s:gsub("\xe2\x80\x9c", '"')   -- U+201C left double quote
        s = s:gsub("\xe2\x80\x9d", '"')   -- U+201D right double quote
        s = s:gsub("\xe2\x80\x93", " - ")  -- U+2013 en-dash  (common in "word – word" spacing)
        s = s:gsub("\xe2\x80\x94", " - ") -- U+2014 em-dash  (common in "word—word" or "word — word")
        s = s:gsub("\xe2\x80\xa6", "...") -- U+2026 ellipsis
        s = s:gsub("%s%s+", " ")          -- collapse double-spaces left by "word – word" → "word  -  word"
        return s
    end

    -- Remove em/en-dashes and surrounding spaces used for dialogue attribution.
    -- Portuguese Kindle books use " — Palavra" (space + em-dash + space) at the
    -- start of dialogue lines. Some EPUB editions represent the same text differently.
    -- This produces a version with dashes stripped so the search can find the
    -- underlying prose without the typographic dash character.
    local function strip_dashes(s)
        -- Remove leading "— " or "– " patterns (dialogue openers)
        s = s:gsub("^\xe2\x80\x94%s*", "")  -- leading em-dash + optional space
        s = s:gsub("^\xe2\x80\x93%s*", "")  -- leading en-dash + optional space
        -- Remove inline " — " and " – " patterns
        s = s:gsub("%s*\xe2\x80\x94%s*", " ")
        s = s:gsub("%s*\xe2\x80\x93%s*", " ")
        s = s:gsub("%s+", " ")
        return s:match("^%s*(.-)%s*$") or s
    end

    instance.cancel_import = false

    local ctx = {
        file_path = instance.file_path,
        targets = instance.targets,
        finished = false,
        cancelFunc = function()
            instance.cancel_import = true
        end,
    }
    ctx.popup = useRecreateStatusPopup(ctx)

    -- Track xpointers already used this run to avoid duplicate highlights
    -- from different full-length annotations that share the same truncated query.
    local used_xpointers = {}

    -- Record the first successfully matched xpointer pair for use as an anchor
    -- when creating an in-book note (option B).  Targets are sorted by page, so
    -- the first match is near the beginning of the book.
    local first_xp_start, first_xp_end

    for idx, target in ipairs(instance.targets) do
        -- Check cancellation before each target
        if instance.cancel_import then
            instance.targets[idx].status = ITargetStatus.CANCELLED
            -- Mark all remaining SELECTED targets as cancelled too
            for i = idx + 1, #instance.targets do
                if instance.targets[i].status == ITargetStatus.SELECTED then
                    instance.targets[i].status = ITargetStatus.CANCELLED
                end
            end
            log("Import cancelled by user")
            break
        end

        if target.status ~= ITargetStatus.SELECTED then goto continue end

        if idx % 10 == 0 then
            useRecreateStatusPopup(ctx)
            UIManager:forceRePaint()
        end

        -- Skip if this highlight already exists in the document
        if existing[target.annotation] then
            log(string.format("[SKIP existing] %s", target.annotation))
            instance.targets[idx].status = ITargetStatus.SKIPPED
            goto continue
        end

        -- Navigate to the target page so searchFromCurrent finds the right occurrence
        if target.page and has_pages then
            instance.ui.paging:gotoPage(tonumber(target.page))
        end

        -- Truncate very long highlights to avoid search engine memory pressure.
        -- Use Endpoint.utf8Sub to avoid splitting multi-byte characters (á, ã, ê, —, etc.)
        -- which would produce invalid UTF-8 that the search engine silently rejects.
        local query = Endpoint.utf8Sub(target.annotation, 150)
        log(string.format("[SEARCH p.%s] %s", tostring(target.page), query))
        local res = search:searchFromCurrent(query, 0, false, true)

        -- Fallback: if exact match failed, retry with ASCII-normalized typography.
        -- Handles the common case where Kindle used smart quotes/dashes but EPUB uses plain ones.
        local query_norm = normalize_typography(query)
        if (not res or #res == 0) and query_norm ~= query then
            log("[RETRY normalized]")
            res = search:searchFromCurrent(query_norm, 0, false, true)
        end

        -- The exact query stays in every later retry: the document may itself
        -- contain the smart typography that normalize_typography rewrites (CJK
        -- books use "……", curly quotes, ...), and once only the normalized form
        -- is searched those retries can never match. The exact form also matters
        -- for the backward direction, the only one that reaches text before the
        -- reading cursor.
        local query_variants = { query }
        if query_norm ~= query then
            query_variants[#query_variants + 1] = query_norm
        end

        -- Probes every variant of a generated needle until one hits.
        local function probe_variants(make_probe, direction)
            for _, variant in ipairs(query_variants) do
                local probe = make_probe(variant)
                if probe and #probe > 0 then
                    local hit = search:searchFromCurrent(probe, direction, false, true)
                    if hit and #hit > 0 then return hit end
                end
            end
        end

        -- Fallback: progressive prefix shortening for edition differences.
        -- When mobi and EPUB have slightly different wording in the tail of a passage,
        -- a shorter prefix is more likely to match exactly.
        -- We try 80 chars then 50 chars, for the exact and the normalized form.
        -- Only fires when the full-length attempts above all failed.
        if not res or #res == 0 then
            for _, len in ipairs({ 80, 50 }) do
                if not res or #res == 0 then
                    log(string.format("[RETRY prefix-%d]", len))
                    res = probe_variants(function(base)
                        local prefix = Endpoint.utf8Sub(base, len)
                        return #prefix < #base and prefix or nil
                    end, 0)
                end
            end
        end

        -- Fallback: backward search (direction=1).
        -- A forward search only covers text after the reading cursor, so a
        -- highlight behind it can only be found backward. The exact query must
        -- be tried here before its normalized form: the document may contain the
        -- smart typography that normalization rewrites (e.g. "……").
        if not res or #res == 0 then
            log("[RETRY backward]")
            res = probe_variants(function(base) return base end, 1)
            if not res or #res == 0 then
                res = probe_variants(function(base)
                    local p80 = Endpoint.utf8Sub(base, 80)
                    return #p80 < #base and p80 or nil
                end, 1)
            end
            if not res or #res == 0 then
                res = probe_variants(function(base)
                    local p50 = Endpoint.utf8Sub(base, 50)
                    return #p50 < #base and p50 or nil
                end, 1)
            end
        end

        -- Fallback: strip em/en-dashes and retry.
        -- Dialogue lines in Portuguese Kindle books often start with "— Palavra"
        -- (U+2014 + space). Some EPUB editions omit the dash entirely or use a
        -- different encoding, causing all dash-containing highlights to fail.
        if not res or #res == 0 then
            for _, variant in ipairs(query_variants) do
                if not res or #res == 0 then
                    local stripped = strip_dashes(variant)
                    if stripped ~= variant and #stripped >= 10 then
                        log("[RETRY strip-dashes]")
                        res = search:searchFromCurrent(stripped, 0, false, true)
                        if not res or #res == 0 then
                            local p80 = Endpoint.utf8Sub(stripped, 80)
                            if #p80 < #stripped then res = search:searchFromCurrent(p80, 0, false, true) end
                        end
                        if not res or #res == 0 then
                            local p50 = Endpoint.utf8Sub(stripped, 50)
                            if #p50 < #stripped then res = search:searchFromCurrent(p50, 0, false, true) end
                        end
                        -- Also try backward
                        if not res or #res == 0 then
                            res = search:searchFromCurrent(stripped, 1, false, true)
                        end
                    end
                end
            end
        end

        -- Fallback: try the text segment at/after the first em/en-dash.
        -- Kindle clippings sometimes capture text from the end of one paragraph
        -- joined to the start of the next (e.g. "claro. — Então às cinco").
        -- The EPUB has these as separate paragraphs: the second paragraph often
        -- STARTS with the dash ("— Então às cinco"), so we must search for the
        -- dash-inclusive version AND the dash-stripped version.
        if not res or #res == 0 then
            local raw_dash_pos = query:find("\xe2\x80\x94", 1, true)
                              or query:find("\xe2\x80\x93", 1, true)
            if raw_dash_pos then
                -- 1) Include the dash: "— Então às cinco, e de sobrecasaca."
                --    This matches EPUBs where the paragraph starts with the dash.
                local with_dash = query:sub(raw_dash_pos):match("^%s*(.-)%s*$")
                -- 2) Exclude the dash (skip the 3-byte sequence + space)
                local after_raw = query:sub(raw_dash_pos + 3):match("^%s*(.-)%s*$")
                for _, probe in ipairs({ with_dash, after_raw }) do
                    if probe and #probe >= 10 and (not res or #res == 0) then
                        log(string.format("[RETRY around-dash] %s", Endpoint.utf8Sub(probe, 60)))
                        res = search:searchFromCurrent(probe, 0, false, true)
                        if not res or #res == 0 then
                            res = search:searchFromCurrent(probe, 1, false, true)
                        end
                        -- also try shorter prefix of this probe
                        if not res or #res == 0 then
                            local p80 = Endpoint.utf8Sub(probe, 80)
                            if #p80 < #probe then
                                res = search:searchFromCurrent(p80, 0, false, true)
                                if not res or #res == 0 then
                                    res = search:searchFromCurrent(p80, 1, false, true)
                                end
                            end
                        end
                    end
                end
            end
            -- Also try via the normalized form (dash replaced with " - ")
            if not res or #res == 0 then
                local dash_start = query_norm:find(" - ", 1, true)
                if dash_start then
                    -- normalized "- " prefix version
                    local with_dash_norm = query_norm:sub(dash_start + 1):match("^%s*(.-)%s*$")
                    local after_dash_norm = query_norm:sub(dash_start + 3):match("^%s*(.-)%s*$")
                    for _, probe in ipairs({ with_dash_norm, after_dash_norm }) do
                        if probe and #probe >= 10 and (not res or #res == 0) then
                            log(string.format("[RETRY norm-dash] %s", Endpoint.utf8Sub(probe, 60)))
                            res = search:searchFromCurrent(probe, 0, false, true)
                            if not res or #res == 0 then
                                res = search:searchFromCurrent(probe, 1, false, true)
                            end
                        end
                    end
                end
            end
        end

        -- Fallback: split annotation by newline and try each line independently.
        -- The Kindle stores multi-paragraph selections joined with literal \n characters.
        -- KOReader's search engine works within individual EPUB paragraph elements, so
        -- a query containing \n will NEVER match across paragraphs.
        -- Strategy: try each non-empty line as a standalone query (forward + backward).
        -- This is the primary fix for cross-paragraph highlights like:
        --   "claro.\n— Então às cinco, e de sobrecasaca."
        -- where "claro." is one paragraph and "— Então às cinco..." is another.
        if (not res or #res == 0) and target.annotation:find("\n", 1, true) then
            local lines_list = {}
            for ln in (target.annotation .. "\n"):gmatch("([^\n]*)\n") do
                ln = ln:match("^%s*(.-)%s*$") or ""
                if #ln >= 15 then
                    lines_list[#lines_list + 1] = ln
                end
            end
            for _, ln in ipairs(lines_list) do
                local ln_variants = { ln }
                local ln_norm = normalize_typography(ln)
                if ln_norm ~= ln then
                    ln_variants[#ln_variants + 1] = ln_norm
                end
                for _, ln_form in ipairs(ln_variants) do
                    if not res or #res == 0 then
                        log(string.format("[RETRY newline-split] %s", Endpoint.utf8Sub(ln_form, 60)))
                        res = search:searchFromCurrent(ln_form, 0, false, true)
                        if not res or #res == 0 then
                            res = search:searchFromCurrent(ln_form, 1, false, true)
                        end
                        -- also try shorter prefixes of this line
                        if not res or #res == 0 then
                            local p80 = Endpoint.utf8Sub(ln_form, 80)
                            if #p80 < #ln_form then
                                res = search:searchFromCurrent(p80, 0, false, true)
                                if not res or #res == 0 then
                                    res = search:searchFromCurrent(p80, 1, false, true)
                                end
                            end
                        end
                        if not res or #res == 0 then
                            local p50 = Endpoint.utf8Sub(ln_form, 50)
                            if #p50 < #ln_form then
                                res = search:searchFromCurrent(p50, 0, false, true)
                                if not res or #res == 0 then
                                    res = search:searchFromCurrent(p50, 1, false, true)
                                end
                            end
                        end
                        -- also try strip-dashes variant of this line
                        if not res or #res == 0 then
                            local ln_stripped = strip_dashes(ln_form)
                            if ln_stripped ~= ln_form and #ln_stripped >= 10 then
                                res = search:searchFromCurrent(ln_stripped, 0, false, true)
                                if not res or #res == 0 then
                                    res = search:searchFromCurrent(ln_stripped, 1, false, true)
                                end
                            end
                        end
                    end
                end
            end
        end

        -- Fallback: short prefix (first ~40 bytes) to handle cross-paragraph clippings.
        -- The Kindle records multi-paragraph selections as a single joined string.
        -- The KOReader search engine operates within individual EPUB paragraph elements,
        -- so a string that spans two paragraphs will NEVER match as a whole.
        -- Searching for only the first portion (which lives entirely in the first paragraph)
        -- works around this fundamental limitation.
        -- This fires regardless of whether dashes are involved.
        if not res or #res == 0 then
            -- Build the probes for the exact and the normalized form, exact
            -- first. First probe: everything before the first sentence-ending
            -- punctuation followed by a space (captures "claro." from
            -- "claro. — Então..."). Second probe: the first 40 UTF-8-safe bytes.
            local probes, seen_probes = {}, {}
            for _, variant in ipairs(query_variants) do
                local first_sentence = variant:match("^(.+[%.!%?])[%s%-]") or
                                       variant:match("^(.+[%.!%?])$")
                if first_sentence then
                    first_sentence = first_sentence:match("^%s*(.-)%s*$") or first_sentence
                end
                for _, probe in ipairs({ first_sentence, Endpoint.utf8Sub(variant, 40) }) do
                    -- Use the shorter of the two as long as it's meaningful (≥ 10 chars)
                    if probe and #probe >= 10 and not seen_probes[probe] then
                        seen_probes[probe] = true
                        probes[#probes + 1] = probe
                    end
                end
            end
            for _, probe in ipairs(probes) do
                if not res or #res == 0 then
                    log(string.format("[RETRY short-prefix] %s", probe))
                    res = search:searchFromCurrent(probe, 0, false, true)
                    if not res or #res == 0 then
                        res = search:searchFromCurrent(probe, 1, false, true)
                    end
                end
            end
        end

        -- Fallback: strip wrapping quotation marks and retry with prefixes.
        -- Kindle mobi often wraps blockquotes/phrases in curly quotes that the EPUB omits.
        -- e.g. '\u201cAll desire is a desire for being,\u201d' → 'All desire is a desire for being,'
        -- After typography normalization the leading char is a plain " or '.
        if not res or #res == 0 then
            local first = query_norm:sub(1, 1)
            if first == '"' or first == "'" then
                -- strip leading quote; strip trailing quote (and optional . or ,) if present
                local inner = query_norm:sub(2):gsub('["\']%s*[.,]?%s*$', ""):match("^%s*(.-)%s*$")
                if inner and #inner >= 20 then
                    log("[RETRY no-outer-quote]")
                    res = search:searchFromCurrent(inner, 0, false, true)
                    if not res or #res == 0 then
                        local p80 = Endpoint.utf8Sub(inner, 80)
                        if #p80 < #inner then res = search:searchFromCurrent(p80, 0, false, true) end
                    end
                    if not res or #res == 0 then
                        local p50 = Endpoint.utf8Sub(inner, 50)
                        if #p50 < #inner then res = search:searchFromCurrent(p50, 0, false, true) end
                    end
                end
            end
        end

        if not res or #res == 0 then
            local note_flag = target.note and " [had note]" or ""
            log(string.format("[FAIL%s] no match in document for: %s", note_flag, target.annotation))
            instance.targets[idx].status = ITargetStatus.FAILED
            goto continue
        end

        local xpointer_start = res[1].start
        local xpointer_end = res[1]["end"]

        -- Try to recover the full annotation range before creating the
        -- highlight. Endpoint.extend returns the pointers unchanged when the
        -- matched range already covers the whole annotation, and it is what
        -- fixes short multi-line clippings whose full query can never match
        -- (the old `query ~= annotation` gate skipped those entirely).
        -- Rolling documents only: PDF positions are page numbers.
        if not has_pages then
            local ext_start, ext_end = Endpoint.extend(
                instance.ui.document, xpointer_start, xpointer_end, target.annotation)
            if ext_start ~= xpointer_start or ext_end ~= xpointer_end then
                log(string.format("[EXTEND] %s → %s", tostring(ext_start), tostring(ext_end)))
                xpointer_start, xpointer_end = ext_start, ext_end
            end
        end

        local xp_key = xpointer_start .. "|" .. xpointer_end

        -- Skip if a previous (longer) annotation already claimed this exact location
        if used_xpointers[xp_key] then
            log(string.format("[SKIP dup xpointer] %s", target.annotation))
            instance.targets[idx].status = ITargetStatus.SKIPPED
            goto continue
        end
        used_xpointers[xp_key] = true

        log(string.format("[OK] %s → %s", xpointer_start, xpointer_end))

        if not first_xp_start then
            first_xp_start = xpointer_start
            first_xp_end   = xpointer_end
        end

        doc:CreateHighlightFromXPointer(xpointer_start, xpointer_end, target.annotation, target.note)
        instance.targets[idx].status = ITargetStatus.ALGORITHM_RESOLVED

        

        ::continue::
    end

    -- Collect failed targets for post-processing (options A and B).
    local failed = {}
    for _, t in ipairs(instance.targets) do
        if t.status == ITargetStatus.FAILED then failed[#failed + 1] = t end
    end

    -- Option A: save unmatched highlights to a text file next to the clippings file.
    if G_reader_settings:isTrue("highlight_import_save_unmatched_file")
            and #failed > 0 and log_dir then
        local up = log_dir .. "highlight_import_unmatched.txt"
        local uf = io.open(up, "w")
        if uf then
            uf:write(string.format("Unmatched highlights (%d) — %s\n", #failed, os.date("%Y-%m-%d %H:%M")))
            uf:write(string.rep("-", 60) .. "\n\n")
            for _, t in ipairs(failed) do
                uf:write(string.format("[p.%s]\n%s\n", tostring(t.page), t.annotation))
                if t.note then uf:write(string.format("  Note: %s\n", t.note)) end
                uf:write("\n")
            end
            uf:close()
            ctx.unmatched_path = up
            log(string.format("Unmatched file written to %s", up))
        end
    end

    -- Option B: create an in-book annotation near the start of the book with all
    -- unmatched items as a note.
    --
    -- We need a fresh xpointer (not reused from an imported highlight, which KOReader
    -- would silently reject as a duplicate position).  Strategy:
    --   Paged (PDF): jump to page 1 then search forward for a very common word.
    --   EPUB: the import loop leaves the cursor near the last searched page (end of book).
    --         A forward search wraps around and lands near the beginning of the book.
    if G_reader_settings:isTrue("highlight_import_note_in_book") and #failed > 0 then
        if has_pages then instance.ui.paging:gotoPage(1) end
        -- Try progressively shorter/simpler strings until we get a valid anchor.
        local anchor_res
        for _, probe in ipairs({ "the ", "and ", "a ", "I " }) do
            anchor_res = search:searchFromCurrent(probe, 0, false, false)
            if anchor_res and #anchor_res > 0 then break end
        end
        local axp_start = anchor_res and #anchor_res > 0 and anchor_res[1].start
        local axp_end   = anchor_res and #anchor_res > 0 and anchor_res[1]["end"]
        -- Last resort: fall back to the first successfully matched xpointer.
        if not axp_start then axp_start = first_xp_start; axp_end = first_xp_end end
        if axp_start then
            local lines = { string.format("Unmatched highlights (%d):", #failed) }
            for _, t in ipairs(failed) do
                lines[#lines + 1] = string.format("[p.%s] %s", tostring(t.page), t.annotation)
                if t.note then lines[#lines + 1] = "  Note: " .. t.note end
            end
            local label = string.format("[Unmatched: %d — see note]", #failed)
            doc:CreateHighlightFromXPointer(axp_start, axp_end, label, table.concat(lines, "\n"))
            log(string.format("In-book unmatched note created at %s", axp_start))
        else
            log("[WARN] Option B: could not find a valid anchor — note not created")
        end
    end

    -- Final status popup (must come after A/B so unmatched_path is set before display).
    ctx.finished = true
    useRecreateStatusPopup(ctx)
    UIManager:forceRePaint()

    log(string.format("Import finished. Log written to %s", log_path or "(none)"))
    if log_file then log_file:close(); log_file = nil end
end
