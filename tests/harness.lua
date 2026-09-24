local H = { passed = 0, failed = 0, failures = {} }

local function fmt(v)
    if v == nil then return "nil" end
    if type(v) == "string" then return string.format("%q", v) end
    return tostring(v)
end

function H.expect(actual, expected, label)
    if actual == expected then
        H.passed = H.passed + 1
    else
        H.failed = H.failed + 1
        H.failures[#H.failures + 1] = string.format("%s: expected %s, got %s",
            label or "?", fmt(expected), fmt(actual))
    end
end

function H.ok(cond, label)
    if cond then
        H.passed = H.passed + 1
    else
        H.failed = H.failed + 1
        H.failures[#H.failures + 1] = (label or "?") .. ": condition failed"
    end
end

function H.isNil(v, label)
    H.expect(v, nil, label)
end

function H.report()
    for _, f in ipairs(H.failures) do
        print("FAIL: " .. f)
    end
    print(string.format("%d passed, %d failed", H.passed, H.failed))
    os.exit(H.failed == 0 and 0 or 1)
end

return H
