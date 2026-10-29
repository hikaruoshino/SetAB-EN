-- stats.lua : pure-Lua helpers (no Windower dependency), used by setab.lua
local M = {}

function M.mean(t)
    local n = #t
    if n == 0 then return nil end
    local s = 0
    for i = 1, n do s = s + t[i] end
    return s / n
end

function M.median(t)
    local n = #t
    if n == 0 then return nil end
    local c = {}
    for i = 1, n do c[i] = t[i] end
    table.sort(c)
    if n % 2 == 1 then return c[(n + 1) / 2] end
    return (c[n / 2] + c[n / 2 + 1]) / 2
end

-- sample standard deviation (n-1); nil when n < 2
function M.sd(t)
    local n = #t
    if n < 2 then return nil end
    local m = M.mean(t)
    local s = 0
    for i = 1, n do s = s + (t[i] - m) ^ 2 end
    return math.sqrt(s / (n - 1))
end

-- half width of the ~95% confidence interval of the mean (normal approx.)
function M.ci95(t)
    local sd = M.sd(t)
    if not sd then return nil end
    return 1.96 * sd / math.sqrt(#t)
end

-- Welch t statistic for mean(a) - mean(b); nil if not computable
function M.welch(a, b)
    if #a < 2 or #b < 2 then return nil end
    local va, vb = M.sd(a) ^ 2 / #a, M.sd(b) ^ 2 / #b
    local denom = math.sqrt(va + vb)
    if denom == 0 then return nil end
    return (M.mean(a) - M.mean(b)) / denom
end

-- split a CSV line on commas (no quoting; fields must not contain commas)
function M.split(line, sep)
    sep = sep or ','
    local out, pos = {}, 1
    while true do
        local i = string.find(line, sep, pos, true)
        if not i then
            out[#out + 1] = string.sub(line, pos)
            break
        end
        out[#out + 1] = string.sub(line, pos, i - 1)
        pos = i + #sep
    end
    return out
end

-- djb2-style hash -> 8 hex chars (stays inside double precision)
function M.hash(str)
    local h = 5381
    for i = 1, #str do
        h = (h * 33 + string.byte(str, i)) % 4294967296
    end
    return string.format('%08x', h)
end

-- group rows by key function; returns map key -> list of rows
function M.group(rows, keyfn)
    local g = {}
    for _, r in ipairs(rows) do
        local k = keyfn(r)
        if k ~= nil then
            g[k] = g[k] or {}
            g[k][#g[k] + 1] = r
        end
    end
    return g
end

return M
