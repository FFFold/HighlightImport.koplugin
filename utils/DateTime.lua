-- Unique annotation datetimes for imported highlights.
--
-- KOReader stores creation datetimes with second resolution
-- (os.date("%Y-%m-%d %H:%M:%S")). A batch import creates dozens of annotations
-- inside the same second, which downstream sync consumers treat as one entry:
-- BookOrbit keys annotations on md5(datetime|pos0) and heals a known datetime
-- with a different pos0 as a "move" of the same annotation. Duplicate seconds
-- therefore collapse a whole import into one annotation per second, leaving
-- text and position from different highlights and failing anchor resolution.
--
-- Imported annotations must pick the next free second among the annotations
-- that already exist in the document.

local DateTime = {}

-- Returns a "%Y-%m-%d %H:%M:%S" datetime at or after `now` (defaults to the
-- current time) that is not used by any annotation in the list.
function DateTime.nextUnique(annotations, now)
    local used = {}
    for _, item in ipairs(annotations or {}) do
        if type(item.datetime) == "string" then
            used[item.datetime] = true
        end
    end

    local stamp = now or os.time()
    local datetime = os.date("%Y-%m-%d %H:%M:%S", stamp)
    while used[datetime] do
        stamp = stamp + 1
        datetime = os.date("%Y-%m-%d %H:%M:%S", stamp)
    end
    return datetime
end

return DateTime
