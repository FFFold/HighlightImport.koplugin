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

    -- Real Boox exports use U+00A0 (NBSP) around the header and date pipes;
    -- Lua's %s does not match NBSP, so this must be normalised explicitly.
    local tmp = os.tmpname()
    local fh = io.open(tmp, "w")
    fh:write("读书笔记\xc2\xa0|\xc2\xa0<<宽空格之书>>作者甲\n"
        .. "2026-01-02 03:04\xc2\xa0|\xc2\xa0页码：7\n"
        .. "带 NBSP 的高亮内容。\n"
        .. "-------------------\n")
    fh:close()
    local nbsp = parser:parseFile(tmp, "")
    H.ok(nbsp["宽空格之书"] ~= nil, "nbsp: header recognised")
    H.expect(nbsp["宽空格之书"] and #nbsp["宽空格之书"], 1, "nbsp: entry parsed")
    local nb_entry = nbsp["宽空格之书"] and nbsp["宽空格之书"][1] and nbsp["宽空格之书"][1][1]
    H.expect(nb_entry and nb_entry.page, "7", "nbsp: page parsed")
    H.expect(nb_entry and nb_entry.text, "带 NBSP 的高亮内容。", "nbsp: text parsed")
    os.remove(tmp)

    -- header-only file: recognised format, empty result, no fall-through to
    -- the old parser (the header line must not become a book key)
    local tmp2 = os.tmpname()
    local fh2 = io.open(tmp2, "w")
    fh2:write("读书笔记 | <<空书>>作者\n-------------------\n")
    fh2:close()
    local empty = parser:parseFile(tmp2, "")
    H.ok(empty["空书"] ~= nil, "empty boox: header book key present")
    H.expect(empty["空书"] and #empty["空书"], 0, "empty boox: no entries")
    H.isNil(empty["读书笔记 | <<空书>>作者"], "empty boox: no fall-through to old parser")
    os.remove(tmp2)

    -- only lines beginning exactly with 【批注】 are notes; marker-like prose
    -- (mid-line marker, other markers at line start) stays part of the text
    local tmp3 = os.tmpname()
    local fh3 = io.open(tmp3, "w")
    fh3:write("读书笔记 | <<标记之书>>作者\n"
        .. "2026-01-02 03:04  |  页码：3\n"
        .. "正文里提到【批注】这两个字，但不在行首。\n"
        .. "【注释】这是另一种标记，不算笔记。\n"
        .. "【批注】真正的笔记\n"
        .. "-------------------\n")
    fh3:close()
    local marked = parser:parseFile(tmp3, "")
    local me = marked["标记之书"] and marked["标记之书"][1] and marked["标记之书"][1][1]
    H.expect(me and me.text, "正文里提到【批注】这两个字，但不在行首。\n【注释】这是另一种标记，不算笔记。", "marker: prose stays text")
    H.expect(me and me.note, "真正的笔记", "marker: only exact 批注 marker becomes note")
    os.remove(tmp3)
end
