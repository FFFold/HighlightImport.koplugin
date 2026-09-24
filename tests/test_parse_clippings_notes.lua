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
