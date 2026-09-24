-- Unit tests for utils/DateTime.lua: imported annotations must carry a unique
-- creation datetime because KOReader only stores second resolution and a batch
-- import creates many annotations within one second.
local DateTime = require("utils.DateTime")

return function(H)
    local function fmt(t)
        return os.date("%Y-%m-%d %H:%M:%S", t)
    end
    local now = os.time({ year = 2026, month = 9, day = 24, hour = 19, minute = 36, second = 24 })

    local fresh = DateTime.nextUnique({}, now)
    H.expect(fresh, fmt(now), "an empty list keeps the current second")
    H.ok(fresh:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$") ~= nil,
        "datetime uses the device datetime format")

    H.expect(DateTime.nextUnique({ { datetime = fmt(now) } }, now), fmt(now + 1),
        "a used second is skipped")

    local run = {}
    for i = 0, 4 do run[#run + 1] = { datetime = fmt(now + i) } end
    H.expect(DateTime.nextUnique(run, now), fmt(now + 5), "a run of used seconds is skipped")

    H.expect(DateTime.nextUnique({ { text = "no datetime" }, { datetime = 42 } }, now), fmt(now),
        "non-string datetimes are ignored")

    local new_year = os.time({ year = 2026, month = 12, day = 31, hour = 23, minute = 59, second = 59 })
    H.expect(DateTime.nextUnique({ { datetime = fmt(new_year) } }, new_year), fmt(new_year + 1),
        "crossing midnight stays formatted")

    H.expect(DateTime.nextUnique(nil, now), fmt(now), "a nil list still returns a datetime")
end
