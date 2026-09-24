-- Regression test: retries must keep the exact query.
--
-- crengine's findText() with origin 0 only searches forward from the current
-- page (it never wraps to earlier content), so a highlight before the reading
-- cursor can only be found by a backward search. adaptive.lua used to replace
-- the exact query with its ASCII-normalized form ("……" -> "...") after the
-- first attempt, which made every later probe unmatchable for documents that
-- contain the smart typography themselves: the exact query was never tried
-- again, and every ellipsis highlight behind the cursor failed to import.
--
-- The cases below are the real annotations from one import run whose text was
-- verified byte-for-byte against the EPUB.

package.loaded["ui/uimanager"] = {
    forceRePaint = function() end,
    setDirty = function() end,
    show = function() end,
    close = function() end,
}
package.loaded["composables.useRecreateStatusPopup"] = function() end

G_reader_settings = {
    readSetting = function() return nil end,
    isTrue = function() return false end,
}

local ITargetStatus = require("interfaces.ITargetStatus")
local Endpoint = require("services.MatchingStrategies.endpoint")
local adaptive = require("services.MatchingStrategies.adaptive")

return function(H)
    local cases = {
        {
            text = "（这是什么表情。害羞…… 还有，生气？还是对着宇佐君？但，这是为什么？）",
            start_xp = "/body/DocFragment[3]/body/section/p[54]/text().0",
        },
        {
            text = "「…… 是我的心上人数字啦。」",
            start_xp = "/body/DocFragment[3]/body/section/p[64]/text().0",
        },
        {
            text = "「（这个…… 明显是小鸟游在玩虚张声势系游戏时会有的表情啊。）」",
            start_xp = "/body/DocFragment[3]/body/section/p[160]/text().0",
        },
        {
            text = "「（嗯？怎么回事…… 这位歌方月乃小姐，好像有点像谁……？）」",
            start_xp = "/body/DocFragment[3]/body/section/p[167]/text().0",
        },
        {
            text = "「柠檬糖和，可乐糖……」",
            start_xp = "/body/DocFragment[3]/body/section/p[266]/text().0",
        },
        {
            text = "…… 真是敏锐的家伙啊。这种直觉敏锐的地方，总感觉会让人回想起稍早前还常来光顾的那位女性呢。为什么呢。这两个人明明完全没有相似的地方呀……。…………。…… 没有，吗？",
            start_xp = "/body/DocFragment[6]/body/section/p[309]/text().0",
        },
        {
            text = "「…… 从这么不肖的哥哥以及嫂子那边都听到耳朵起茧子了当然知道了……」",
            start_xp = "/body/DocFragment[6]/body/section/p[352]/text().0",
        },
        {
            text = "辣妹不知为何笑得十分害羞…… 啊，我要是有 NTR 属性的话，这场景该兴奋了吧。可惜我没有，所以只有心碎的份…… 好想喝酒。",
            start_xp = "/body/DocFragment[6]/body/section/p[437]/text().0",
        },
        -- Edition difference ahead of the cursor: the document carries only a
        -- prefix, so the exact prefix (not the normalized one) has to match.
        {
            text = "「常盘！那、那个，之前在剧本杀里让小鸟游同学把你杀掉的那件事我道歉还不行吗……！」",
            start_xp = "/body/DocFragment[5]/body/section/p[247]/text().0",
            document_prefix_bytes = 80,
        },
    }

    for i, case in ipairs(cases) do
        case.query = Endpoint.utf8Sub(case.text, 150)
        case.doc_text = case.document_prefix_bytes
            and Endpoint.utf8Sub(case.text, case.document_prefix_bytes)
            or case.text
        case.end_xp = case.start_xp:gsub("%.0$", "." .. #case.text)
    end

    -- Emulates crengine: the reading cursor sits after every highlight, so a
    -- forward search only matches the shortened document form and the exact
    -- query is reachable only backward.
    local search
    search = {
        calls = {},
        searchFromCurrent = function(self, pattern, direction)
            table.insert(self.calls, { pattern = pattern, direction = direction })
            for _, case in ipairs(cases) do
                if direction == 1 and not case.document_prefix_bytes and pattern == case.query then
                    return { { start = case.start_xp, ["end"] = case.end_xp } }
                end
                if direction == 0 and case.document_prefix_bytes and pattern == case.doc_text then
                    return { { start = case.start_xp, ["end"] = case.end_xp } }
                end
            end
            return {}
        end,
    }

    local texts_by_start = {}
    for _, case in ipairs(cases) do
        texts_by_start[case.start_xp] = case.doc_text
    end

    local document = {
        info = { has_pages = false },
        getTextFromXPointers = function(_, start_xp)
            return texts_by_start[start_xp] or ""
        end,
        getPageFromXPointer = function() return 54 end,
        compareXPointers = function() return 1 end,
        findAllText = function() return {} end,
    }

    local created = {}
    local annotations = {}
    local ui = {
        search = search,
        document = document,
        paging = { gotoPage = function() end },
        annotation = {
            annotations = annotations,
            addItem = function(_, item)
                table.insert(annotations, item)
                created[item.text] = item
                return #annotations
            end,
            onSaveSettings = function() end,
        },
        view = { highlight = { saved_color = "yellow" } },
    }

    local targets = {}
    for _, case in ipairs(cases) do
        targets[#targets + 1] = {
            annotation = case.text,
            note = nil,
            page = "54",
            status = ITargetStatus.SELECTED,
        }
    end

    local instance = {
        ui = ui,
        document = document,
        file_path = "",
        targets = targets,
        cancel_import = false,
    }

    adaptive(instance)

    local imported = 0
    for i, case in ipairs(cases) do
        if targets[i].status == ITargetStatus.ALGORITHM_RESOLVED then
            imported = imported + 1
        end
    end
    H.expect(imported, #cases, "every highlight behind the cursor is imported")
    H.ok(created[cases[1].text] ~= nil, "the first failing annotation is created")
    H.ok(created[cases[6].text] ~= nil, "a truncated ellipsis annotation is created")
    H.ok(created[cases[9].text] ~= nil, "a prefix-only annotation is created")
    H.expect(created[cases[1].text] and created[cases[1].text].pos0, cases[1].start_xp,
        "the created highlight uses the matched range")

    -- The exact form must have been searched backward, not just its
    -- normalized "..." form.
    local exact_backward = false
    for _, call in ipairs(search.calls) do
        if call.direction == 1 and call.pattern == cases[1].query then
            exact_backward = true
        end
    end
    H.ok(exact_backward, "the exact query is retried in the backward direction")
end
