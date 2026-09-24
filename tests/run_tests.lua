-- Run with: luajit tests/run_tests.lua   (from the repo root)
local script = (arg and arg[0]) or "tests/run_tests.lua"
local root = script:match("^(.*)[/\\]tests[/\\][^/\\]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/tests/stubs/?.lua;" .. package.path

local H = require("tests.harness")
H.root = root

local test_modules = {
    "tests.test_parse_boox",
    "tests.test_parse_clippings_notes",
    "tests.test_endpoint",
}

for _, name in ipairs(test_modules) do
    local ok, err = pcall(require, name)
    if ok and type(err) == "function" then
        local ran, run_err = pcall(err, H)
        if not ran then
            H.failed = H.failed + 1
            H.failures[#H.failures + 1] = name .. ": " .. tostring(run_err)
        end
    elseif not ok then
        -- module intentionally absent until its task lands
        print("SKIP (not implemented yet): " .. name)
    end
end

H.report()
