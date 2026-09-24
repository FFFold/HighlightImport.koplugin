-- An imported highlight must not reuse a datetime that another annotation in
-- the document already has: BookOrbit treats a duplicate datetime as the same
-- annotation and collapses whole imports into one entry per second.
local Document = require("services.Document")

return function(H)
    G_reader_settings = {
        readSetting = function() return nil end,
    }

    local annotations = {}
    local add_calls, save_calls = 0, 0
    local ui = {
        annotation = {
            annotations = annotations,
            addItem = function(self, item)
                add_calls = add_calls + 1
                table.insert(annotations, item)
                return #annotations
            end,
            onSaveSettings = function()
                save_calls = save_calls + 1
            end,
        },
        rolling = true,
        view = { highlight = { saved_color = "yellow" } },
    }

    local function fmt(t)
        return os.date("%Y-%m-%d %H:%M:%S", t)
    end
    -- Cover the next ten minutes so the assertion is independent of how long
    -- the test itself takes: without the fix the created datetime always lands
    -- inside this window.
    local now = os.time()
    for i = 0, 600 do
        annotations[#annotations + 1] = { datetime = fmt(now + i), text = "seed " .. i }
    end

    local doc = Document:new{ ui = ui }
    doc:CreateHighlightFromXPointer("/body/DocFragment[3]/body/p[1]/text().0",
        "/body/DocFragment[3]/body/p[1]/text().5", "text", nil)

    H.expect(add_calls, 1, "addItem is called once")
    H.expect(save_calls, 1, "the sidecar is saved once")

    local created = annotations[#annotations]
    local used = {}
    for i = 1, #annotations - 1 do
        used[annotations[i].datetime] = true
    end
    H.ok(created.datetime ~= nil, "the created annotation has a datetime")
    H.ok(not used[created.datetime], "the created datetime is unique in the document")
    H.ok(created.datetime:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$") ~= nil,
        "the created datetime uses the device datetime format")
    H.expect(created.pos0, "/body/DocFragment[3]/body/p[1]/text().0", "pos0 is stored")
    H.expect(created.pos1, "/body/DocFragment[3]/body/p[1]/text().5", "pos1 is stored")
    H.expect(created.page, created.pos0, "page mirrors pos0 for rolling documents")
    H.expect(created.drawer, "lighten", "the drawer is lighten")
end
