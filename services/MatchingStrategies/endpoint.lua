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
