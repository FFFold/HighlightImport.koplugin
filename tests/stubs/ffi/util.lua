return {
    template = function(fmt, ...)
        local args = { ... }
        return (fmt:gsub("%%(%d)", function(n)
            return tostring(args[tonumber(n)] or "")
        end))
    end,
}
