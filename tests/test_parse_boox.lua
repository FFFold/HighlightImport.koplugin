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
