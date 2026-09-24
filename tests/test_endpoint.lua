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
