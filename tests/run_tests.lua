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
    "tests.test_datetime",
    "tests.test_create_highlight",
    "tests.test_adaptive_ellipsis",
}

for _, name in ipairs(test_modules) do
    local ok, mod = pcall(require, name)
    if not ok then
        -- A test module that fails to load (syntax error, bad require) is a
        -- failure, not a skip: skipping would report a false green.
        H.failed = H.failed + 1
        H.failures[#H.failures + 1] = name .. ": " .. tostring(mod)
    elseif type(mod) ~= "function" then
        H.failed = H.failed + 1
        H.failures[#H.failures + 1] = name .. ": module did not return a test function"
    else
        local ran, run_err = pcall(mod, H)
        if not ran then
            H.failed = H.failed + 1
            H.failures[#H.failures + 1] = name .. ": " .. tostring(run_err)
        end
    end
end

H.report()
