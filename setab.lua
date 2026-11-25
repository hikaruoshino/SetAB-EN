--[[
SetAB - per-gear-set damage logger / comparer for Windower 4 (Lua 5.1)
Read-only: listens to 'action' events, never sends packets.
Chat output is ASCII only (Japanese needs Shift-JIS conversion in the FFXI chat log).
]]

_addon.name     = 'SetAB'
_addon.author   = 'hikaruoshino'
_addon.version  = '0.3.3'
_addon.commands = {'setab', 'sab'}

local res      = require('resources')
local config   = require('config')
local extdata  = require('extdata')
local texts    = require('texts')
local stats    = require('setab_stats')

-- Client language. A Japanese client's chat is Shift-JIS: chat output goes through to_shift_jis and command arguments
-- (auto-translate words from Tab included) come back through convert_auto_trans + from_shift_jis, as in SkillUp / BoxOpener.
local function client_is_ja()
    local ok, info = pcall(windower.ffxi.get_info)
    local l = ok and info and info.language and tostring(info.language):lower() or 'japanese'
    return l == 'japanese'
end

local function sjis(str)
    str = tostring(str)
    if not client_is_ja() then return str end
    return windower.to_shift_jis and windower.to_shift_jis(str) or str
end

local function from_sjis(str)
    if not str then return nil end
    local s = windower.convert_auto_trans and windower.convert_auto_trans(str) or str
    if not client_is_ja() then return s end
    return windower.from_shift_jis and windower.from_shift_jis(s) or s
end

local defaults = {enabled = true, ignore = '', hud_on = true, hud_tip = true, lang = 'auto', hud_font_v = 0}
-- HUD (//setab compare shows it): libs/texts reads pos / text / bg / padding from the settings root and saves the position after a drag.
-- MS Gothic on a Japanese client: fixed width for both ASCII (1 cell) and Japanese (2 cells), which the table layout assumes.
defaults.pos = {x = 40, y = 330}
defaults.text = {font = client_is_ja() and 'MS Gothic' or 'Consolas', size = 11, alpha = 255}
defaults.bg = {alpha = 200, red = 10, green = 10, blue = 15}
defaults.padding = 6
local settings = config.load(defaults)
if settings.hud_font_v ~= 1 then   -- one-time: the first 0.3.0 builds saved Consolas, which has no Japanese glyphs
    settings.hud_font_v = 1
    if client_is_ja() and settings.text.font == 'Consolas' then settings.text.font = 'MS Gothic' end
    config.save(settings)
end
local HUD_SIZE_MIN, HUD_SIZE_MAX = 6, 40

-- which language action names are shown in: settings.lang = auto (the client's) / ja / en
local function use_ja()
    local s = tostring(settings.lang or 'auto'):lower()
    if s == 'ja' then return true elseif s == 'en' then return false end
    return client_is_ja()
end

-- Windower's equipment slot names (ear1/ring1 etc. do not exist, so earrings and rings were never hashed before 0.2.2)
local SLOTS = {'main','sub','range','ammo','head','neck','left_ear','right_ear',
               'body','hands','left_ring','right_ring','back','waist','legs','feet'}

-- action categories whose "finish" packet carries damage
local FINISH_SELF = {[3] = true, [4] = true}                     -- WS, spell
local FINISH_PET  = {[3] = true, [4] = true, [11] = true, [13] = true} -- pet TP moves (verify 11/13 in game)

-- message ids (VERIFY in game; raw id is always written to the CSV so rows can be re-classified)
-- misses: 188 = "uses <WS>, but misses", 282 = "evades", 324 / 658 = "uses <ability>, but misses" (pet moves) (res/action_messages)
local MISS_MSG   = {[188] = true, [282] = true, [324] = true, [658] = true}
-- resists: spell messages only ("resists the spell", "completely resists" ...)
local RESIST_MSG = {[85] = true, [284] = true, [653] = true, [654] = true, [655] = true, [656] = true}
-- An enemy that absorbs the element gets "recovers N HP" instead of damage. Per category, as the message names the action
-- (7 = spell, 103 / 238 = weapon skill, 102 / 306 / 318 = ability). Only counted when the target is an enemy.
local ABSORB_MSG = {
    [3] = {[103] = true, [238] = true},
    [4] = {[7] = true},
    [11] = {[103] = true, [238] = true, [102] = true, [306] = true, [318] = true},
    [13] = {[103] = true, [238] = true, [102] = true, [306] = true, [318] = true},
}
-- category 7 (WS start) param: 28787 = the WS was interrupted (libs/actions.lua, GearSwap/triggers.lua); any other value = a start
local WS_INTERRUPTED = 28787
local START_LIMIT = 30   -- seconds a WS start (its gear and TP) waits for its result
-- Only damage messages count as damage, for every category (buffs carry a status id in param, not damage:
-- e.g. a Garuda ward recorded "33" = Haste before 0.2.2). Built from res: "... points of damage" or "... HP drained"
-- (MP / TP / stat drains such as Aspir or Absorb-STR are not HP damage: before 0.3.2 they were recorded as damage).
local DMG_MSG = {}
for id, m in pairs(res.action_messages or {}) do
    if m.en and (string.find(m.en, 'points of damage', 1, true) or string.find(m.en, 'HP drained', 1, true)) then
        DMG_MSG[id] = true
    end
end
-- Spells that land a status on an enemy ("... is paralyzed." / "... receives the effect of Slow.", incl. Magic Burst
-- and the AoE follow-up lines), so enfeebles are recorded as 'land' and the resist rate can be worked out.
-- Only used for spells (category 4) on enemies; ally buffs use "gains the effect" and are not matched.
local LAND_MSG = {}
for id, m in pairs(res.action_messages or {}) do
    local e = m.en or ''
    if (string.find(e, '${target} is ${status}', 1, true) or string.find(e, '${target} receives the effect of ${status}', 1, true))
            and not string.find(e, 'cannot', 1, true) and not string.find(e, 'equipment change', 1, true) then
        LAND_MSG[id] = true
    end
end

-- Category 13 (pet ability/WS: avatar Blood Pacts, BST Ready moves) carries a job_abilities id when the
-- message is an "${ability}" message, otherwise a monster_abilities id (same rule as the healthbar addon).
-- The two tables share 387 ids, so looking up the wrong one silently gives another move's name.
local ABILITY_MSG = {}
for id, m in pairs(res.action_messages or {}) do
    if m.en and string.find(m.en, '${ability}', 1, true) then ABILITY_MSG[id] = true end
end

-- act = one id per action packet: the rows of one area move (one row per enemy) share it, and count as one sample in the
-- statistics. Older logs have no act column; each of their rows counts as its own sample.
local HEADER = 'ts,zone,target,actor,action,cat,set,hash,tp,weather,day,buffs,result,dmg,msg,hits,act'

local me_id, me_name
local rows  = {}   -- parsed log rows
local queue = {}   -- CSV lines waiting to be written: {path = the character's log.csv, line = text}
local queue_warned = false   -- the "could not write" message was shown (once per failure, not every 10 s)
local sets  = {}   -- hash -> {name=, desc=}
local sets_file = nil   -- the sets.tsv that sets was loaded from
local sets_dirty = false   -- an automatic name (unnamed_N) could not be saved yet: retried with the log
local unnamed_count = 0
local pending = nil   -- {ws, hash, desc, tp, t}: gear and TP read at my WS "start" packet (see on_action)
local act_seq = 0
local tp_prev, tp_prev_t = nil, 0
local last_flush = os.clock()
local filt = {tpmin = nil, tpmax = nil, target = nil}
local debug_on = false   -- //setab debug on|off (temporary: prints the raw action values for in-game checks)
local hud_state = nil     -- {a, b, action}: what the HUD table is showing (set by //setab compare); it refreshes as new rows come in
local hud_dirty = false   -- new rows or a changed filter: refresh the HUD table in prerender

local function say(msg) windower.add_to_chat(207, sjis('SetAB: ' .. msg)) end

local function clean(s)
    return (tostring(s):gsub('[,\r\n\t]', ' '))
end

-- set names are typed as one word in //setab compare A B, so spaces (and the full-width space) become '_'
local function set_name(s)
    local t = clean(s):gsub('^%s+', ''):gsub('%s+$', '')
    return (t:gsub('\227\128\128', '_'):gsub('%s+', '_'))
end

local function ignore_set()
    local t = {}
    for w in string.gmatch(settings.ignore or '', '[^,]+') do t[w] = true end
    return t
end

local function data_dir()
    return windower.addon_path .. 'data/' .. (me_name or 'unknown') .. '/'
end

-- debug output: one line to chat and to data/<name>/debug.log (ASCII only)
local function dbg(line)
    if not debug_on then return end
    say('[dbg] ' .. line)
    local f = io.open(data_dir() .. 'debug.log', 'a')
    if f then
        f:write(os.date('%H:%M:%S'), string.format(' %.2f ', os.clock()), line, '\n')
        f:close()
    end
end

local function dbg_action(act, kind)
    local parts = {string.format('%s cat=%s param=%s targets=%d', kind, tostring(act.category),
        tostring(act.param), #(act.targets or {}))}
    for ti, t in ipairs(act.targets or {}) do
        parts[#parts + 1] = string.format('| t%d id=%s actions=%d', ti, tostring(t.id), #(t.actions or {}))
        for ai, a in ipairs(t.actions or {}) do
            parts[#parts + 1] = string.format('a%d param=%s msg=%s react=%s', ai, tostring(a.param),
                tostring(a.message), tostring(a.reaction))
        end
    end
    dbg(table.concat(parts, ' '))
end

---------------------------------------------------------------- files
-- io.open / write / close give nil on failure (Lua 5.1): every one of them is checked before data is thrown away.
local function read_all(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local s = f:read('*a')
    f:close()
    return s
end

-- Replace path with content without losing the old file when something fails: the text goes to path.tmp and is read back,
-- the old file becomes path.bak (os.rename cannot replace an existing file on Windows), then path.tmp becomes path.
-- Returns true, or nil and the reason.
local function replace_file(path, content)
    local tmp, bak = path .. '.tmp', path .. '.bak'
    local f = io.open(tmp, 'w')
    if not f then return nil, 'cannot open ' .. tmp end
    local wrote = f:write(content)
    local closed = f:close()
    if not wrote or not closed then os.remove(tmp); return nil, 'cannot write ' .. tmp end
    if read_all(tmp) ~= content then os.remove(tmp); return nil, 'the written file reads back differently' end
    local old = io.open(path, 'r')
    if old then
        old:close()
        os.remove(bak)
        if not os.rename(path, bak) then os.remove(tmp); return nil, 'cannot rename the old file (is it open elsewhere?)' end
    end
    if not os.rename(tmp, path) then
        if old then os.rename(bak, path) end
        os.remove(tmp)
        return nil, 'cannot rename ' .. tmp
    end
    return true
end

-- size and last byte of a file (nil when it does not exist)
local function file_end(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local size = f:seek('end')
    local last
    if size and size > 0 then f:seek('end', -1); last = f:read(1) end
    f:close()
    return size or 0, last
end

-- Append lines to path. Returns how many of them (from the first) are surely in the file; the rest must be kept.
local function append_lines(path, lines)
    local size, last = file_end(path)
    local f = io.open(path, 'a')
    if not f then return 0 end
    -- a new file gets the header; after a write that broke off mid-line, start on a new line
    local lead = (not size) and (HEADER .. '\n') or ((size > 0 and last ~= '\n') and '\n' or '')
    local ok = lead == '' or f:write(lead) ~= nil
    local n = 0
    if ok then
        for i, l in ipairs(lines) do
            if not f:write(l, '\n') then ok = false; break end
            n = i
        end
    end
    if f:close() and ok then return n end
    -- something failed: read back what was added and count the whole lines that are there
    local r = io.open(path, 'rb')
    if not r then return 0 end
    r:seek('set', size or 0)
    local added = (r:read('*a') or ''):gsub('\r\n', '\n')
    r:close()
    local pos = 1
    if string.sub(added, 1, #lead) == lead then pos = #lead + 1 end
    n = 0
    for i, l in ipairs(lines) do
        local e = pos + #l
        if string.sub(added, pos, e) ~= l .. '\n' then break end
        n, pos = i, e + 1
    end
    return n
end

---------------------------------------------------------------- sets.tsv
-- writes list (hash -> {name, desc}) to sets.tsv; returns true, or nil and the reason (the old file is kept then)
local function save_sets(list)
    if not sets_file then return nil, 'not logged in' end
    local hs = {}
    for h in pairs(list) do hs[#hs + 1] = h end
    table.sort(hs)
    local out = {}
    for _, h in ipairs(hs) do
        local s = list[h]
        out[#out + 1] = h .. '\t' .. clean(s.name) .. '\t' .. clean(s.desc or '') .. '\n'
    end
    return replace_file(sets_file, table.concat(out))
end

-- a copy of sets with one entry replaced (the stored sets change only after the file is saved)
local function sets_with(hash, entry)
    local t = {}
    for h, s in pairs(sets) do t[h] = s end
    t[hash] = entry
    return t
end

local function load_sets()
    sets = {}
    unnamed_count = 0
    sets_dirty = false
    sets_file = data_dir() .. 'sets.tsv'
    local f = io.open(sets_file, 'r') or io.open(sets_file .. '.bak', 'r')   -- .bak: a replace that stopped half way
    if not f then return end
    for line in f:lines() do
        local p = stats.split(line, '\t')
        if p[1] and p[2] then
            sets[p[1]] = {name = p[2], desc = p[3] or ''}
            local n = tonumber(string.match(p[2], '^unnamed_(%d+)$'))
            if n and n > unnamed_count then unnamed_count = n end
        end
    end
    f:close()
end

---------------------------------------------------------------- log file
local function load_rows()
    rows = {}
    local f = io.open(data_dir() .. 'log.csv', 'r')
    if not f then
        f = io.open(data_dir() .. 'log.csv', 'w')
        if f then f:write(HEADER, '\n'); f:close() end
        return
    end
    for line in f:lines() do
        if line ~= '' and string.sub(line, 1, 3) ~= 'ts,' then
            local p = stats.split(line, ',')
            if #p >= 15 then
                rows[#rows + 1] = {
                    ts = p[1], zone = p[2], target = p[3], actor = p[4], action = p[5],
                    cat = tonumber(p[6]), set = p[7], hash = p[8], tp = tonumber(p[9]) or -1,
                    weather = p[10], day = p[11], buffs = p[12], result = p[13],
                    dmg = tonumber(p[14]) or 0, msg = tonumber(p[15]) or 0,
                    hits = tonumber(p[16]) or 1,
                    act = (p[17] and p[17] ~= '') and p[17] or ('old' .. (#rows + 1)),   -- older rows: one sample each
                }
            end
        end
    end
    f:close()
end

-- Write the waiting lines, each to the log.csv of the character it was recorded for. A line leaves the queue only when it
-- is surely in the file; a locked file (e.g. open in a spreadsheet) keeps its lines for the next try (10 s later).
local function flush()
    last_flush = os.clock()
    if sets_dirty and save_sets(sets) then sets_dirty = false end
    if #queue == 0 then return end
    local order, by_path = {}, {}
    for _, q in ipairs(queue) do
        local l = by_path[q.path]
        if not l then l = {}; by_path[q.path] = l; order[#order + 1] = q.path end
        l[#l + 1] = q.line
    end
    local done = {}
    for _, p in ipairs(order) do done[p] = append_lines(p, by_path[p]) end
    local keep, seen = {}, {}
    for _, q in ipairs(queue) do
        seen[q.path] = (seen[q.path] or 0) + 1
        if seen[q.path] > done[q.path] then keep[#keep + 1] = q end
    end
    queue = keep
    if #queue > 0 then
        if not queue_warned then
            queue_warned = true
            say(string.format('could not write log.csv (is it open in another program?). %d rows wait and are retried every 10 s.', #queue))
        end
    elseif queue_warned then
        queue_warned = false
        say('log.csv written.')
    end
end

---------------------------------------------------------------- equipment snapshot
local function snapshot()
    -- only the equipment table (get_items() with no argument builds the whole inventory every time)
    local eq = windower.ffxi.get_items('equipment')
    if not eq then return nil end
    local ign = ignore_set()
    local keys, descs = {}, {}
    for _, slot in ipairs(SLOTS) do
        if not ign[slot] then
            local idx, bag = eq[slot], eq[slot .. '_bag']
            local key, desc = '-', '-'
            if idx and idx > 0 and bag then
                local it = windower.ffxi.get_items(bag, idx)
                if it and it.id and it.id ~= 0 then
                    local ext = ''
                    local ok, dec = pcall(extdata.decode, it)
                    if ok and dec then
                        if dec.augments then ext = table.concat(dec.augments, '|') end
                        if dec.path then ext = ext .. '#path' .. tostring(dec.path) end
                        if dec.rank then ext = ext .. '#rank' .. tostring(dec.rank) end
                    end
                    key  = it.id .. ':' .. ext
                    desc = res.items[it.id] and res.items[it.id].en or tostring(it.id)
                end
            end
            keys[#keys + 1]  = slot .. '=' .. key
            descs[#descs + 1] = slot .. '=' .. desc
        end
    end
    return stats.hash(table.concat(keys, ';')), table.concat(descs, '; ')
end

local function name_for(hash, desc)
    if not sets[hash] then
        unnamed_count = unnamed_count + 1
        -- the row needs the name now: it is kept even when sets.tsv cannot be written, and saved again with the log
        sets[hash] = {name = 'unnamed_' .. unnamed_count, desc = desc}
        if not save_sets(sets) then sets_dirty = true end
    end
    return sets[hash].name
end

---------------------------------------------------------------- recording
local function action_name(cat, param, msg)
    local r
    if cat == 3 then r = res.weapon_skills[param]
    elseif cat == 4 then r = res.spells[param]
    elseif cat == 13 and ABILITY_MSG[msg] then r = res.job_abilities[param]
    else r = res.monster_abilities[param] end
    return r and r.en or ('id' .. tostring(param))
end

-- sum the damage of every hit on one target (multi-hit WS / pet moves have several actions)
-- returns total, hit count, message of the first action (for miss/resist classification)
-- A damage message with 0 is a hit for 0 damage (it landed): it counts, as a miss would understate the miss rate otherwise.
-- Only a param that is a number counts: a damage message without a param is not a hit (it is not a 0-damage hit).
local function total_damage(cat, t)
    local total, hits, first_msg = 0, 0, 0
    for i, a in ipairs(t.actions or {}) do
        local m, p = a.message or 0, a.param
        if i == 1 then first_msg = m end
        if DMG_MSG[m] and type(p) == 'number' and p >= 0 then total, hits = total + p, hits + 1 end
    end
    return total, hits, first_msg
end

local function classify(hits, msg, absorbed)
    if hits > 0 then return 'hit' end
    if MISS_MSG[msg] then return 'miss' end
    if RESIST_MSG[msg] then return 'resist' end
    if absorbed then return 'absorb' end
    if LAND_MSG[msg] then return 'land' end
    return 'other'
end

local function pet_id()
    local p = windower.ffxi.get_mob_by_target('pet')
    return p and p.id or nil
end

local function on_action(act)
    if not settings.enabled or not me_id then return end
    local kind
    if act.actor_id == me_id then kind = 'self'
    else
        local pid = pet_id()   -- looked up once per action (actions from everyone pass through here)
        if pid and act.actor_id == pid then kind = 'pet' else return end
    end
    if debug_on then dbg_action(act, kind) end

    local cat = act.category
    if cat == 7 then
        if kind == 'self' then
            if act.param == WS_INTERRUPTED then pending = nil; return end   -- the WS did not go off: its start is void
            local pl = windower.ffxi.get_player()
            local tp = pl and pl.vitals and pl.vitals.tp or -1
            -- the TP may already be spent when this packet arrives (the 'tp change' event can come first): take the TP that was just lost
            if tp_prev and os.clock() - tp_prev_t < 3 and tp_prev > tp then tp = tp_prev end
            -- read the equipment now: the WS gear is on at the start, but the aftercast swap can land before the result packet
            -- (0.2.3 sometimes recorded the idle/engaged set instead of the WS set)
            local hash, desc = snapshot()
            local t1 = act.targets and act.targets[1]
            local a1 = t1 and t1.actions and t1.actions[1]
            -- the WS id of a start is in the first action's param (GearSwap get_spell); the result has it in act.param
            local ws_id = a1 and a1.param
            if type(ws_id) ~= 'number' then
                -- without the id no result can match this start: the result then reads the gear worn at the result
                ws_id = nil
                if debug_on then dbg('WS start: no start id (targets[1].actions[1].param missing), the start gear will not be used') end
            end
            pending = {ws = ws_id, hash = hash, desc = desc, tp = tp, t = os.clock()}
        end
        return
    end
    local ok = (kind == 'self' and FINISH_SELF[cat]) or (kind == 'pet' and FINISH_PET[cat])
    if not ok then return end

    -- my result uses the start only when it is the start of this WS and recent; gear and TP are taken (or dropped) together.
    -- A pet's result leaves the start alone.
    local start = nil
    if kind == 'self' then
        if cat == 3 and pending and pending.ws == act.param and os.clock() - pending.t < START_LIMIT then start = pending end
        pending = nil
    end

    -- decide what to record first, so buff spells etc. do not cost a snapshot or create unnamed sets
    local todo = {}
    for _, t in ipairs(act.targets or {}) do
        if t.actions and t.actions[1] then
            local dmg, hits, msg = total_damage(cat, t)
            local landed, absorbed = false, false
            local need_enemy = hits == 0 and ((cat == 4 and LAND_MSG[msg]) or (ABSORB_MSG[cat] and ABSORB_MSG[cat][msg]))
            if need_enemy then
                local mob = windower.ffxi.get_mob_by_id(t.id)
                if mob ~= nil and mob.spawn_type == 16 then   -- enemies only (not party members)
                    absorbed = ABSORB_MSG[cat] ~= nil and ABSORB_MSG[cat][msg] == true
                    landed = not absorbed and cat == 4 and LAND_MSG[msg] == true
                end
            end
            if hits > 0 or MISS_MSG[msg] or RESIST_MSG[msg] or landed or absorbed then
                todo[#todo + 1] = {id = t.id, dmg = dmg, hits = hits, msg = msg, absorbed = absorbed}
            end
        end
    end
    if #todo == 0 then return end

    local hash, desc
    if start and start.hash then
        hash, desc = start.hash, start.desc   -- the set at the WS start
    else
        hash, desc = snapshot()
    end
    if not hash then return end
    local setname = name_for(hash, desc)

    local info = windower.ffxi.get_info() or {}
    local zone = info.zone and res.zones[info.zone] and res.zones[info.zone].en or tostring(info.zone)
    local pl = windower.ffxi.get_player()
    local buffs = {}
    if pl and pl.buffs then
        for _, b in ipairs(pl.buffs) do if b and b > 0 and b < 1024 then buffs[#buffs + 1] = b end end
        table.sort(buffs)
    end
    local tp = -1
    if kind == 'self' and cat == 3 then
        tp = start and start.tp or -1
        if tp < 0 then
            -- fallback when no start packet was seen: use the TP seen just before it was spent
            tp = pl and pl.vitals and pl.vitals.tp or -1
            if tp_prev and os.clock() - tp_prev_t < 3 and tp_prev > tp then tp = tp_prev end
        end
    end
    local aname = action_name(cat, act.param, todo[1].msg)
    act_seq = act_seq + 1
    local act_id = os.time() .. '-' .. act_seq   -- shared by the rows of this packet (one per enemy)
    local path = data_dir() .. 'log.csv'

    for _, d in ipairs(todo) do
        local mob = windower.ffxi.get_mob_by_id(d.id)
        local r = {
            ts = os.date('%Y-%m-%d %H:%M:%S'), zone = clean(zone or '?'),
            target = clean(mob and mob.name or '?'), actor = kind, action = clean(aname),
            cat = cat, set = setname, hash = hash, tp = tp,
            weather = tostring(info.weather or ''), day = tostring(info.day or ''),
            buffs = table.concat(buffs, '-'), result = classify(d.hits, d.msg, d.absorbed),
            dmg = d.dmg, msg = d.msg, hits = d.hits, act = act_id,
        }
        rows[#rows + 1] = r
        queue[#queue + 1] = {path = path, line = table.concat({r.ts, r.zone, r.target, r.actor, r.action, r.cat,
            r.set, r.hash, r.tp, r.weather, r.day, r.buffs, r.result, r.dmg, r.msg, r.hits, r.act}, ',')}
    end
    if hud_state then hud_dirty = true end   -- the HUD table refreshes in prerender (at most once a second)
end

---------------------------------------------------------------- reporting
-- Rows are grouped by gear hash, never by name: two sets given the same name stay apart. The label shown (and typed) for a
-- hash is its name; when other hashes have the same name, '#' and the start of the hash are added (Nyame#1a2b).
-- returns label (hash -> label) and name_of (hash -> plain name)
local function set_labels()
    local name_of = {}
    for h, s in pairs(sets) do name_of[h] = s.name end
    for _, r in ipairs(rows) do if not name_of[r.hash] then name_of[r.hash] = r.set end end
    local by_name = {}
    for h, nm in pairs(name_of) do
        local l = by_name[nm]
        if not l then l = {}; by_name[nm] = l end
        l[#l + 1] = h
    end
    local label = {}
    for nm, hs in pairs(by_name) do
        if #hs == 1 then label[hs[1]] = nm
        else
            local n = 4   -- the shortest start of the hash (4 to 8 characters) that tells them apart
            while n < 8 do
                local seen, clash = {}, false
                for _, h in ipairs(hs) do
                    local p = string.sub(h, 1, n)
                    if seen[p] then clash = true; break end
                    seen[p] = true
                end
                if not clash then break end
                n = n + 1
            end
            for _, h in ipairs(hs) do label[h] = nm .. '#' .. string.sub(h, 1, n) end
        end
    end
    return label, name_of
end

-- what was typed -> the label of one set; or nil and the labels it could mean (a name shared by several sets)
local function resolve_set(typed, label, name_of)
    local cands = {}
    for h, l in pairs(label) do
        if l == typed or h == typed then return l end
        if name_of[h] == typed then cands[#cands + 1] = l end
    end
    if #cands == 1 then return cands[1] end
    table.sort(cands)
    return nil, cands
end

local function passes(r)
    if filt.tpmin and (r.tp < 0 or r.tp < filt.tpmin) then return false end
    if filt.tpmax and (r.tp < 0 or r.tp > filt.tpmax) then return false end
    if filt.target and not string.find(string.lower(r.target), string.lower(filt.target), 1, true) then
        return false
    end
    return true
end

-- dm = every hit (shown as min / max / the last values); samples = one value per use (the average over the enemies one
-- area move hit), because the enemies of one use are not independent records. The average, median, confidence interval
-- and t test use the samples. The average per enemy (not the sum) keeps a use comparable however many enemies it hit.
local function summarize(list)
    local dm, miss = {}, 0
    local lo, hi
    local by_act, uses = {}, {}
    for _, r in ipairs(list) do
        if r.result == 'hit' then
            dm[#dm + 1] = r.dmg
            if not lo or r.dmg < lo then lo = r.dmg end
            if not hi or r.dmg > hi then hi = r.dmg end
            local g = by_act[r.act]
            if not g then g = {0, 0}; by_act[r.act] = g; uses[#uses + 1] = g end
            g[1], g[2] = g[1] + r.dmg, g[2] + 1
        elseif r.result == 'miss' or r.result == 'resist' or r.result == 'absorb' then miss = miss + 1 end
    end
    local samples = {}
    for i, g in ipairs(uses) do samples[i] = g[1] / g[2] end
    return {
        n = #list, hits = #dm, uses = #samples, miss = miss, dm = dm, samples = samples, min = lo, max = hi,
        mean = stats.mean(samples), med = stats.median(samples), ci = stats.ci95(samples),
    }
end

local function f0(x) return x and string.format('%.0f', x) or '-' end
local function ci(x) return x and ('+-' .. string.format('%.0f', x)) or '+-?' end

-- Action names are recorded in English (the CSV stays the same for both clients). The Japanese name of each is found in res
-- (weapon skills, spells, job abilities, monster abilities) so lists can show it and Japanese can be typed (Tab included).
local ja_of = nil
local function build_names()
    if ja_of then return end
    ja_of = {}
    for _, tbl in ipairs({res.weapon_skills, res.spells, res.job_abilities, res.monster_abilities}) do
        for _, row in pairs(tbl or {}) do
            if type(row) == 'table' and row.en and row.ja and not ja_of[row.en] then ja_of[row.en] = row.ja end
        end
    end
end

-- the name to show: Japanese when the client (or //setab lang ja) is Japanese and res has it
local function disp(action)
    if not use_ja() then return action end
    build_names()
    return ja_of[action] or action
end

-- does a recorded action match what was typed? English: part of the name, any case. Japanese: part of the Japanese name
local function action_matches(action, want)
    if string.find(string.lower(action), want, 1, true) then return true end
    if string.find(want, '[\128-\255]') then
        build_names()
        local ja = ja_of[action]
        return ja ~= nil and string.find(ja, want, 1, true) ~= nil
    end
    return false
end

local function matching(actionname)
    local out = {}
    local want = actionname and string.lower(actionname)
    for _, r in ipairs(rows) do
        if passes(r) and (not want or action_matches(r.action, want)) then
            out[#out + 1] = r
        end
    end
    return out
end

local function report(actionname)
    local list = matching(actionname)
    if #list == 0 then say('no matching rows.'); return end
    local by_action = stats.group(list, function(r) return r.action end)
    local order = {}
    for a, l in pairs(by_action) do order[#order + 1] = {a = a, n = #l} end
    table.sort(order, function(x, y) return x.n > y.n end)
    local label = set_labels()
    local function label_of(r) return label[r.hash] end
    for i = 1, math.min(#order, 5) do
        say('== ' .. disp(order[i].a) .. ' (n=' .. order[i].n .. ')')
        local by_set = stats.group(by_action[order[i].a], label_of)
        local names = {}
        for nm in pairs(by_set) do names[#names + 1] = nm end
        table.sort(names)
        for _, nm in ipairs(names) do
            local s = summarize(by_set[nm])
            local missp = s.n > 0 and (100 * s.miss / s.n) or 0
            say(string.format('  %-18s n=%d uses=%d avg=%s med=%s %s miss/resist=%.0f%%',
                nm, s.n, s.uses, f0(s.mean), f0(s.med), ci(s.ci), missp))
        end
    end
    if #order > 5 then say(string.format('... and %d more actions (list: //setab actions)', #order - 5)) end
end

-- everything compare needs, for the chat lines and for the HUD; returns nil, message when it cannot be worked out
local function compare_data(a, b, actionname)
    local label, name_of = set_labels()
    for _, typed in ipairs({a, b}) do
        local l, cands = resolve_set(typed, label, name_of)
        if not l and cands and #cands > 1 then
            local list = table.concat(cands, ', ')
            return nil, 'more than one set is named ' .. typed .. ': ' .. list .. '. Type one of these (//setab sets)',
                typed .. ' という名前のセットが複数あります: ' .. list .. '。このどれかを入力してください（//setab sets）'
        end
    end
    a = resolve_set(a, label, name_of) or a
    b = resolve_set(b, label, name_of) or b
    local list = matching(actionname)
    local by_set = stats.group(list, function(r) return label[r.hash] end)
    local la, lb = by_set[a], by_set[b]
    if not la or not lb then
        local missing, known = {}, {}
        if not la then missing[#missing + 1] = a end
        if not lb then missing[#missing + 1] = b end
        for nm in pairs(by_set) do known[#known + 1] = nm end
        table.sort(known)
        local shown = {}
        for i = 1, math.min(#known, 8) do shown[#shown + 1] = known[i] end
        local names = #shown > 0 and (table.concat(shown, ', ') .. (#known > 8 and ', ...' or '')) or nil
        return nil,
            'no rows for set: ' .. table.concat(missing, ', ') .. '. Sets with rows: ' .. (names or '(none under the current filters)')
                .. '. Type the set names as they are, without < >  (//setab sets)',
            'セットの記録がありません: ' .. table.concat(missing, ', ') .. '。記録があるセット: ' .. (names or '（今の絞り込みでは、ありません）')
                .. '。< > は付けずに、名前をそのまま入力してください（//setab sets）'
    end
    local sa, sb = summarize(la), summarize(lb)
    if not sa.mean or not sb.mean then return nil, 'no hit rows for one of the sets.', 'どちらかのセットに、ダメージの記録がありません。' end
    local diff = sa.mean - sb.mean
    local pct = sb.mean ~= 0 and (100 * diff / sb.mean) or 0
    local t = stats.welch(sa.samples, sb.samples)   -- one value per use (see summarize)
    -- the |t| needed for "a real difference" depends on how many records there are (Welch degrees of freedom):
    -- about 2.8 with 3 records per set, about 2.1 with 10, about 2.0 with 60 or more (when both sets vary about
    -- as much; when one set varies far more, df falls and the value rises, up to 4.3 with 3 records per set)
    local df = stats.welch_df(sa.samples, sb.samples)
    local crit = df and stats.tcrit(df) or 2
    local verdict, level
    if not t then verdict, level = 'not enough data (need 2+ uses with damage per set)', 'none'
    elseif math.abs(t) >= crit then verdict, level = string.format('likely a real difference (|t|>=%.2f)', crit), 'yes'
    else verdict, level = string.format('no clear difference yet (|t|<%.2f); collect more samples', crit), 'no' end
    -- how many different actions are mixed in these rows (only matters when no action name was given)
    local seen, kinds = {}, 0
    for _, l in ipairs({la, lb}) do
        for _, r in ipairs(l) do
            if not seen[r.action] then seen[r.action] = true; kinds = kinds + 1 end
        end
    end
    return {a = a, b = b, sa = sa, sb = sb, diff = diff, pct = pct, t = t, verdict = verdict, level = level,
            action = actionname, kinds = kinds, crit = crit}
end

local function compare(a, b, actionname)
    local d, err = compare_data(a, b, actionname)
    if not d then say(err); return end
    say(string.format('%s: n=%d avg=%s | %s: n=%d avg=%s  (uses with damage: %d | %d)', d.a, d.sa.n, f0(d.sa.mean),
        d.b, d.sb.n, f0(d.sb.mean), d.sa.uses, d.sb.uses))
    say(string.format('diff %+.0f (%+.1f%%) t=%s -> %s', d.diff, d.pct, d.t and string.format('%.2f', d.t) or '-', d.verdict))
    if not actionname and d.kinds > 1 then
        say(string.format('note: %d different actions are mixed here. Add an action name to compare one of them (list: //setab actions)', d.kinds))
    end
end

---------------------------------------------------------------- HUD (//setab compare shows a table: A on top, B below)
local hud = texts.new('', settings)
hud:hide()
local hud_last = 0

local function color(r, g, b, s) return string.format('\\cs(%d,%d,%d)%s\\cr', r, g, b, s) end

-- display-width helpers: set names may be Japanese (3 UTF-8 bytes = a wide character), so cut and pad by character
local function fit(s, w, right)
    local out, used = {}, 0
    for c in string.gmatch(tostring(s), '[%z\1-\127\194-\244][\128-\191]*') do
        local x = #c >= 3 and 2 or 1
        if used + x > w then break end
        out[#out + 1] = c; used = used + x
    end
    local fill = string.rep(' ', w - used)
    if right then return fill .. table.concat(out) end
    return table.concat(out) .. fill
end

local function last_values(dm, limit)
    local n = #dm
    local from = math.max(1, n - limit + 1)
    local out = {}
    for i = from, n do out[#out + 1] = string.format('%.0f', dm[i]) end
    return (from > 1 and '.. ' or '') .. table.concat(out, ' ')
end

-- HUD wording: Japanese when the client (or //setab lang ja) is Japanese; the chat lines stay English
local function T(ja, en) return use_ja() and ja or en end

-- width in screen cells: a Japanese character (3 UTF-8 bytes) is 2 cells wide in MS Gothic, ASCII is 1
local function cells(s)
    local n = 0
    for c in string.gmatch(tostring(s), '[%z\1-\127\194-\244][\128-\191]*') do n = n + (#c >= 3 and 2 or 1) end
    return n
end

-- One HUD line built from segments {text, key, rgb}. key = what the mouse tooltip explains over that part of the line.
-- The cell range of every key is recorded in layout, so a pointer position can be turned back into a key (see key_at).
local function build_line(layout, segs, line_rgb)
    local out, marks, c = {}, {}, 0
    for _, sg in ipairs(segs) do
        local w = cells(sg[1])
        if sg[2] then marks[#marks + 1] = {c, c + w, sg[2]} end
        out[#out + 1] = sg[3] and color(sg[3][1], sg[3][2], sg[3][3], sg[1]) or sg[1]
        c = c + w
    end
    layout.lines[#layout.lines + 1] = marks
    if c > layout.max then layout.max = c end
    local s = table.concat(out)
    if line_rgb then return color(line_rgb[1], line_rgb[2], line_rgb[3], s) end
    return s
end

-- the columns of one set's row (A or B); label + name = the set, the rest are the statistics
local function hud_cols(label, name, s, key)
    local missp = s.n > 0 and (100 * s.miss / s.n) or 0
    return {
        {label .. '  ', key}, {fit(name, 14), key}, {' '},
        {fit(s.n, 4, true), 'n'}, {' '}, {fit(f0(s.mean), 7, true), 'avg'}, {' '}, {fit(f0(s.med), 7, true), 'med'}, {' '},
        {fit(f0(s.min), 7, true), 'min'}, {' '}, {fit(f0(s.max), 7, true), 'max'}, {' '},
        {fit(s.ci and ('+-' .. f0(s.ci)) or '+-?', 8, true), 'ci'}, {' '},
        {fit(string.format('%.0f%%', missp), 5, true), 'miss'},
    }
end

-- returns the HUD text and its layout (see build_line)
local function hud_text(d)
    local layout = {lines = {}, max = 0}
    local lines = {}
    local function add(segs, rgb) lines[#lines + 1] = build_line(layout, segs, rgb) end
    local filters = {}
    if filt.target then filters[#filters + 1] = T('敵=', 'target=') .. filt.target end
    if filt.tpmin or filt.tpmax then filters[#filters + 1] = 'TP=' .. tostring(filt.tpmin or '') .. '-' .. tostring(filt.tpmax or '') end
    local title = d.action or T('全ての技', 'all actions')
    if not d.action and d.kinds > 1 then
        title = title .. T(' (' .. d.kinds .. ' 種類が混ざっています。技名を付けてください)',
                           ' (' .. d.kinds .. ' kinds mixed: add an action name)')
    end
    add({{'SetAB  ' .. title, 'title', {255, 220, 120}},
         {#filters > 0 and ('   [' .. table.concat(filters, ' ') .. ']') or '', 'filter'}})
    add({{string.rep('-', 68)}})
    add({{'   '}, {fit(T('セット', 'set'), 14), 'set'}, {' '}, {fit(T('回数', 'n'), 4, true), 'n'}, {' '},
         {fit(T('平均', 'avg'), 7, true), 'avg'}, {' '}, {fit(T('中央値', 'med'), 7, true), 'med'}, {' '},
         {fit(T('最小', 'min'), 7, true), 'min'}, {' '}, {fit(T('最大', 'max'), 7, true), 'max'}, {' '},
         {fit(T('信頼幅', '+-ci'), 8, true), 'ci'}, {' '}, {fit(T('ミス', 'miss'), 5, true), 'miss'}})
    local dmglabel = T('ダメージ ', 'dmg ')
    add(hud_cols('A', d.a, d.sa, 'a'), {140, 200, 255})
    add({{'     ' .. dmglabel .. last_values(d.sa.dm, 10), 'dmg'}})
    add(hud_cols('B', d.b, d.sb, 'b'), {255, 180, 140})
    add({{'     ' .. dmglabel .. last_values(d.sb.dm, 10), 'dmg'}})
    add({{string.rep('-', 68)}})
    local rgb = {yes = {120, 255, 120}, no = {200, 200, 200}, none = {255, 180, 80}}
    local c = rgb[d.level] or rgb.no
    local tv = d.t and string.format('%.2f', d.t) or '-'
    add({{T(string.format('A と B の差   %+.0f（B を基準に %+.1f%%）', d.diff, d.pct),
            string.format('A vs B   diff %+.0f (%+.1f%% of B)', d.diff, d.pct)), 'diff'},
         {'   '}, {'t=' .. tv, 't'}}, c)
    local cr = string.format('%.2f', d.crit or 2)
    local verdicts = {
        yes = T('差がありそうです（|t| が ' .. cr .. ' 以上）', 'likely a real difference (|t|>=' .. cr .. ')'),
        no = T('差があるとは言えません（|t| が ' .. cr .. ' より小さい）。記録を増やしてください', 'no clear difference yet (|t|<' .. cr .. '); collect more samples'),
        none = T('データが足りません（各セットに、ダメージの出た使用が 2 回以上必要）', 'not enough data (need 2+ uses with damage per set)'),
    }
    add({{verdicts[d.level] or d.verdict, 'verdict'}}, c)
    return table.concat(lines, string.char(10)), layout
end

---------------------------------------------------------------- mouse tooltip (a second small HUD)
-- What each part of the table means. Shown beside the pointer while it is over that part of the HUD.
local function tip_content(key)
    local t = {
        title = {T('技名と絞り込み', 'Action and filters'),
                 T('比べている技の名前です。[ ] の中は、今の絞り込み（敵の名前・TP の範囲）です。//setab target・//setab tp・//setab filter clear で変えられます。',
                   'The action being compared. In [ ] are the current filters (enemy name, TP range). Change them with //setab target, //setab tp, //setab filter clear.')},
        filter = {T('絞り込み', 'Filters'),
                  T('今の絞り込み（敵の名前・TP の範囲）です。この条件に合う記録だけを、表にしています。//setab filter clear で外せます。',
                    'The current filters (enemy name, TP range). Only the records that match are in the table. //setab filter clear removes them.')},
        set = {T('セット', 'Set'),
               T('装備のセットの名前です。A は compare の 1 つ目、B は 2 つ目に指定したセットです。',
                 'The name of the gear set. A is the first set given to compare, B is the second.')},
        a = {T('A（1 つ目のセット）', 'A (the first set)'),
             T('compare の 1 つ目に指定したセットです。差は「A − B」で計算します。', 'The first set given to compare. The difference is worked out as A - B.')},
        b = {T('B（2 つ目のセット）', 'B (the second set)'),
             T('compare の 2 つ目に指定したセットです。割合は、B の平均を基準にしています。', 'The second set given to compare. The percentage is taken against the average of B.')},
        n = {T('回数（n）', 'n (count)'),
             T('記録された回数です（ミスやレジストも 1 回に数えます）。多いほど、結果が安定します。',
               'How many records there are (a miss or a resist counts as one too). The more, the steadier the result.')},
        avg = {T('平均', 'avg (average)'),
               T('ダメージの平均値です（ミスやレジストは含みません）。範囲技は、1 回の使用で当たった敵の平均を、1 回分として数えます。',
                 'The average damage (misses and resists are not counted). For an area move, the average over the enemies one use hit counts as one use.')},
        med = {T('中央値', 'med (median)'),
               T('ダメージを小さい順に並べたときの、真ん中の値です。極端に大きい・小さい値の影響を受けにくいので、平均と離れているときは、ばらつきが大きいサインです。',
                 'The middle value when the damage is sorted. It is hardly moved by extreme values, so when it is far from the average, the damage varies a lot.')},
        min = {T('最小', 'min'), T('いちばん小さかったダメージです。', 'The smallest damage.')},
        max = {T('最大', 'max'), T('いちばん大きかったダメージです。', 'The largest damage.')},
        ci = {T('信頼幅（+-）', '+-ci (confidence)'),
              T('平均の「±」に当たる値で、95% 信頼区間の半分の幅です。「本当の平均は、平均 ± この値の中にありそう」という目安です。回数が少ない・ばらつきが大きいほど、大きくなります。',
                'The "plus or minus" of the average: half the width of the 95% confidence interval. The real average is probably within the average +- this value. It grows when there are few records or the damage varies a lot.')},
        miss = {T('ミス', 'miss'),
                T('ミス（魔法ではレジスト、属性を吸収する敵では吸収）の割合です。記録の回数のうち、当たらなかった割合です。0 ダメージで当たったものは、ここに入りません。',
                  'The share of records that missed (for spells: resisted; for an enemy that absorbs the element: absorbed), the ones that did not land. A hit for 0 damage is not counted here.')},
        dmg = {T('撃った順のダメージ', 'Damage, in order'),
               T('直近 10 回のダメージを、撃った順に並べています（「..」は、それより前にも記録があるという意味）。値がいくつかの段に分かれていないか、見てください。分かれているときは、敵の状態や天候など、条件が混ざっています。',
                 'The last 10 damage values in the order they happened (".." means there are earlier ones). Check whether they fall into a few separate levels: if so, conditions such as the enemy state or the weather are mixed.')},
        diff = {T('A と B の差', 'Difference of A and B'),
                T('A の平均から B の平均を引いた値です。かっこの中は、B の平均を基準にした割合で、「A は B より何 % 高いか」を表します（マイナスなら低い）。',
                  'The average of A minus the average of B. In brackets is the percentage against B: how much higher A is than B (a minus means lower).')},
        t = {T('t 値（Welch の t 値）', 't (Welch t value)'),
             T('差が、偶然のばらつきなのかを見る目安です。|t|（t の絶対値）が基準値以上なら、偶然とは考えにくく、差がありそうです。基準値は、回数が少ないほど大きく（3 回ずつで約 2.8、10 回ずつで約 2.1、多いと約 2.0。2 つのセットのばらつきが大きく違うと、もっと大きくなります）、判定の行に出ています。基準値より小さいときは、まだ差があるとは言えません。回数が少ない、またはダメージのばらつきが大きいと、t は 0 に近くなります。',
               'A guide to whether the difference could be chance. If |t| (t without the sign) reaches the threshold, chance is unlikely and the difference is probably real. The threshold is larger when there are few records (about 2.8 with 3 per set, 2.1 with 10, 2.0 with many; higher still when the two sets vary very differently) and is shown on the verdict line. Below it, you cannot say there is a difference yet. With few records or widely varying damage, t stays near 0.')},
        verdict = {T('判定', 'Verdict'),
                   T('|t| が基準値（回数が少ないほど大きい。行に出ている値）以上なら「差がありそう」、それより小さいなら「差があるとは言えない」です。「データが足りません」は、どちらかのセットに、ダメージの出た使用が 2 回未満のときです。範囲技で複数の敵に当たっても、1 回の使用は 1 回と数えます。',
                     '"Likely a real difference" when |t| reaches the threshold (larger with few records; the value on the line), "no clear difference" when it is below. "Not enough data" means one of the sets has fewer than 2 uses with damage. One use of an area move counts once, however many enemies it hit.')},
    }
    local v = t[key]
    if v then return v[1], v[2] end
end

-- Wrap the tooltip text at max cells. Where a line may break:
--   Japanese: between any two characters, except right after an ASCII word or number ("2|以上", "t|の": the ASCII part
--             moves to the next line together with what follows it), before closing punctuation (。 、 ）) and after an
--             opening bracket (（ 「).
--   English:  only at a space between words (a word is never cut unless it is longer than a line).
local NO_LINE_START = {['。'] = true, ['、'] = true, ['）'] = true, ['」'] = true, ['，'] = true, ['．'] = true, ['！'] = true, ['？'] = true}
local NO_LINE_END = {['（'] = true, ['「'] = true, ['『'] = true}

local function break_ok(buf, n, c)   -- may a line break between buf[n] and the next character c?
    if c == ' ' or NO_LINE_START[c] or NO_LINE_END[buf[n]] then return false end
    local p = buf[n]
    if #c >= 3 then
        -- c is Japanese: not right after an ASCII word / number (spaces between them do not help)
        local j = n
        while j > 1 and buf[j] == ' ' do j = j - 1 end
        local last = buf[j]
        return last == nil or #last >= 3
    end
    -- c is ASCII: only after a space (between words) or after Japanese
    return p == ' ' or #p >= 3
end

local function wrap(s, max)
    local out, buf, bw, brk = {}, {}, 0, nil
    local function flush_at(n)   -- close the line after buf[n]; the rest carries over
        local line, carry = {}, {}
        for i = 1, n do line[#line + 1] = buf[i] end
        for i = n + 1, #buf do carry[#carry + 1] = buf[i] end
        out[#out + 1] = (table.concat(line):gsub(' +$', ''))
        buf, bw, brk = carry, 0, nil
        for i, x in ipairs(buf) do
            bw = bw + (#x >= 3 and 2 or 1)
            if i < #buf and break_ok(buf, i, buf[i + 1]) then brk = i end
        end
    end
    for c in string.gmatch(s, '[%z\1-\127\194-\244][\128-\191]*') do
        local w = #c >= 3 and 2 or 1
        if #buf > 0 and break_ok(buf, #buf, c) then brk = #buf end
        if bw + w > max and #buf > 0 then
            if brk and brk > 0 then flush_at(brk) else flush_at(#buf) end
            if #buf > 0 and break_ok(buf, #buf, c) then brk = #buf end
        end
        buf[#buf + 1] = c; bw = bw + w
    end
    if #buf > 0 then out[#out + 1] = (table.concat(buf):gsub(' +$', '')) end
    return out
end

local tip = texts.new('', {
    pos = {x = 0, y = 0},
    text = {font = settings.text.font, size = settings.text.size, alpha = 255},
    bg = {alpha = 235, red = 20, green = 20, blue = 45, visible = true},
    flags = {draggable = false},
    padding = 6,
})
tip:hide()
local TIP_COLS = 50   -- wrap width, in cells
local tip_key, tip_suppress, tip_w, tip_h = nil, false, 0, 0
local hud_layout = nil   -- where each key sits in the HUD text (set by hud_refresh)

local function tip_hide()
    tip_key = nil
    if tip:visible() then tip:hide() end
end

local function hud_hide()
    hud:hide()
    tip_hide()
end

-- the key under the pointer, from its position: the HUD box is made of the text lines and the text cells (all lines have the
-- same height, every cell the same width in a fixed-width font), inside the padding. hud:extents() is the whole box.
local function key_at(x, y)
    if not hud_layout or #hud_layout.lines == 0 or hud_layout.max <= 0 then return nil end
    local px, py = hud:pos()
    local w, h = hud:extents()
    if not (px and py and w and h) or w <= 0 or h <= 0 then return nil end
    local pad = settings.padding or 6
    local line_h = (h - 2 * pad) / #hud_layout.lines
    local cell_w = (w - 2 * pad) / hud_layout.max
    if line_h <= 0 or cell_w <= 0 then return nil end
    local marks = hud_layout.lines[math.floor((y - py - pad) / line_h) + 1]
    if not marks then return nil end
    local col = math.floor((x - px - pad) / cell_w)
    for _, m in ipairs(marks) do
        if col >= m[1] and col < m[2] then return m[3], cell_w, line_h end
    end
    return nil
end

local function tip_update(x, y)
    if not settings.hud_tip or tip_suppress or not hud:visible() or not hud:hover(x, y) then tip_hide(); return end
    local key, cell_w, line_h = key_at(x, y)
    local title, body = tip_content(key)
    if not title then tip_hide(); return end
    if key ~= tip_key then
        tip_key = key
        if debug_on then
            local px, py = hud:pos()
            local w, h = hud:extents()
            dbg(string.format('tip key=%s pointer=%d,%d hud=%s,%s box=%s x %s lines=%d cells=%d', tostring(key), x, y,
                tostring(px), tostring(py), tostring(w), tostring(h), #hud_layout.lines, hud_layout.max))
        end
        local lines = wrap(body, TIP_COLS)
        local maxc = cells(title)
        for _, l in ipairs(lines) do maxc = math.max(maxc, cells(l)) end
        tip:text(color(255, 220, 120, title) .. string.char(10) .. table.concat(lines, string.char(10)))
        tip_w, tip_h = maxc, #lines + 1
    end
    -- beside the pointer; on the other side near the screen edge
    local ok, info = pcall(windower.get_windower_settings)
    local sw = ok and info and info.ui_x_res or 1920
    local sh = ok and info and info.ui_y_res or 1080
    local bw = tip_w * (cell_w or 7) + 12
    local bh = tip_h * (line_h or 14) + 12
    local tx, ty = x + 16, y + 22
    if tx + bw > sw then tx = x - bw - 8 end
    if ty + bh > sh then ty = y - bh - 8 end
    tip:pos(math.max(0, tx), math.max(0, ty))
    tip:show()
end

local function hud_refresh()
    if not hud_state then return end
    hud_dirty = false
    local d, err, err_ja = compare_data(hud_state.a, hud_state.b, hud_state.action)
    if d then
        local text, layout = hud_text(d)
        hud_layout = layout
        hud:text(text)
    else
        hud_layout = nil
        hud:text(color(255, 180, 80, 'SetAB: ' .. T(err_ja, err)))
    end
end

local function hud_set_size(size)
    size = math.max(HUD_SIZE_MIN, math.min(HUD_SIZE_MAX, math.floor(size + 0.5)))
    settings.text.size = size
    hud:size(size)
    tip:size(size)
    tip_hide()
    config.save(settings)
    return size
end

-- the action names to type after report / compare: exactly as recorded (WS, spell and pet ability names in English)
local function list_actions(setname)
    local counts, order = {}, {}
    local set_label, name_of = set_labels()
    local want = setname and string.lower(setname)
    for _, r in ipairs(matching(nil)) do
        if not want or string.lower(set_label[r.hash]) == want or string.lower(name_of[r.hash]) == want or r.hash == setname then
            if not counts[r.action] then counts[r.action] = 0; order[#order + 1] = r.action end
            counts[r.action] = counts[r.action] + 1
        end
    end
    if #order == 0 then say('no recorded actions' .. (setname and (' for set ' .. setname) or '') .. '.'); return end
    table.sort(order, function(x, y) if counts[x] ~= counts[y] then return counts[x] > counts[y] end return x < y end)
    say('recorded actions (type the name after report / compare; English or Japanese, a part of the name is enough):')
    for i = 1, math.min(#order, 20) do
        local shown = disp(order[i])
        local label = shown == order[i] and shown or (shown .. ' (' .. order[i] .. ')')
        say(string.format('  %s  n=%d', label, counts[order[i]]))
    end
    if #order > 20 then say(string.format('  ... and %d more', #order - 20)) end
end

local function list_sets()
    local counts = {}
    for _, r in ipairs(rows) do counts[r.hash] = (counts[r.hash] or 0) + 1 end
    local label = set_labels()
    for h in pairs(sets) do
        say(string.format('%s  %-16s rows=%d', h, label[h], counts[h] or 0))
    end
end

---------------------------------------------------------------- commands
local function help()
    say('//setab on|off | status')
    say('//setab label <name>      name the currently equipped set')
    say('//setab name <hash> <name> rename a set by hash (see //setab sets)')
    say('//setab sets              list known sets')
    say('//setab actions [set]     list the recorded action names (WS / spell / pet ability)')
    say('//setab report [action]   per-set stats. action = a name from //setab actions (English or Japanese; Tab works); none = all')
    say('//setab compare A B [action]  chat lines + the HUD table (A on top, B below). Do not type the < >')
    say('   e.g. //setab compare Nyame ABMagic Aeolian Edge   (set names: //setab sets)')
    say('//setab lang ja|en|auto   language of the action names shown (auto = the client)')
    say('//setab hud [on|off|size <n>|reset|tip on|off]  show / hide the table; on|off = open it on compare or not; tip = the pointer tooltips')
    say('   drag the table with the mouse to move it; wheel over it to resize; the pointer over a heading (t, avg ...) explains it')
    say('//setab tp <min> [max] | target <text> | filter clear')
    say('//setab ignore <slot>     toggle a slot out of the set hash (e.g. ammo)')
    say('//setab reset confirm     erase the log')
    say('//setab debug on|off      print raw action values (temporary, for in-game checks)')
end

local function on_command(cmd, ...)
    local args = {...}
    for i = 1, #args do args[i] = from_sjis(args[i]) end   -- Japanese typed or Tab-converted arrives as Shift-JIS
    cmd = cmd and string.lower(cmd) or 'help'
    if cmd == 'on' or cmd == 'off' then
        settings.enabled = (cmd == 'on'); config.save(settings)
        say('recording ' .. cmd)
    elseif cmd == 'status' then
        say(string.format('enabled=%s rows=%d sets=%d ignore=[%s]',
            tostring(settings.enabled), #rows, (function() local c = 0 for _ in pairs(sets) do c = c + 1 end return c end)(),
            settings.ignore or ''))
    elseif cmd == 'label' then
        local nm = set_name(table.concat(args, ' '))
        if nm == '' then say('usage: //setab label <name>'); return end
        local hash, desc = snapshot()
        if not hash then say('cannot read equipment.'); return end
        local new = sets_with(hash, {name = nm, desc = desc})
        local ok, err = save_sets(new)
        if not ok then say('could not save sets.tsv (' .. tostring(err) .. '); the name was not changed.'); return end
        sets, sets_dirty = new, false
        say('labeled ' .. hash .. ' as ' .. nm)
        local label = set_labels()
        if label[hash] ~= nm then say('another set is also named ' .. nm .. ': this one is shown as ' .. label[hash] .. ' (//setab sets)') end
    elseif cmd == 'name' then
        local hash, nm = args[1], set_name(table.concat(args, ' ', 2))
        if not hash or not sets[hash] or nm == '' then say('usage: //setab name <hash> <name>'); return end
        local new = sets_with(hash, {name = nm, desc = sets[hash].desc})
        local ok, err = save_sets(new)
        if not ok then say('could not save sets.tsv (' .. tostring(err) .. '); the name was not changed.'); return end
        sets, sets_dirty = new, false
        say('renamed to ' .. nm)
        local label = set_labels()
        if label[hash] ~= nm then say('another set is also named ' .. nm .. ': this one is shown as ' .. label[hash] .. ' (//setab sets)') end
    elseif cmd == 'sets' then list_sets()
    elseif cmd == 'actions' then list_actions(table.concat(args, ' ') ~= '' and set_name(table.concat(args, ' ')) or nil)
    elseif cmd == 'report' then report(table.concat(args, ' ') ~= '' and table.concat(args, ' ') or nil)
    elseif cmd == 'compare' then
        if #args < 2 then say('usage: //setab compare <A> <B> [action]'); return end
        local action = args[3] and table.concat(args, ' ', 3) or nil
        -- the same '_' rule as label / name, so a name typed with a full-width space still matches
        local a, b = set_name(args[1]), set_name(args[2])
        compare(a, b, action)
        hud_state = {a = a, b = b, action = action}
        hud_refresh()
        if settings.hud_on then hud:show() end
    elseif cmd == 'lang' then
        local a = args[1] and string.lower(args[1])
        if a == 'ja' or a == 'en' or a == 'auto' then
            settings.lang = a; config.save(settings)
            hud_dirty = hud_state ~= nil
            tip_hide()   -- the tooltip text is in the old language
        end
        say('action names shown in: ' .. tostring(settings.lang) .. ' (' .. (use_ja() and 'Japanese' or 'English') .. ').  //setab lang ja|en|auto')
    elseif cmd == 'hud' then
        local a = args[1] and string.lower(args[1])
        if a == 'on' or a == 'off' then
            settings.hud_on = (a == 'on'); config.save(settings)
            if a == 'off' then hud_hide() end
            say('hud ' .. a .. (a == 'on' and ' (the table opens on //setab compare)' or ' (hidden; //setab hud shows it again)'))
        elseif a == 'tip' then
            local b = args[2] and string.lower(args[2])
            if b == 'on' or b == 'off' then settings.hud_tip = (b == 'on'); config.save(settings); if b == 'off' then tip_hide() end end
            say('hud tooltip ' .. (settings.hud_tip and 'on' or 'off') .. '  (//setab hud tip on|off)')
        elseif a == 'size' then
            local n = tonumber(args[2])
            if not n then say('usage: //setab hud size <' .. HUD_SIZE_MIN .. '-' .. HUD_SIZE_MAX .. '>'); return end
            say('hud size ' .. hud_set_size(n))
        elseif a == 'reset' then
            settings.pos.x, settings.pos.y = defaults.pos.x, defaults.pos.y
            hud:pos(settings.pos.x, settings.pos.y)
            hud_set_size(defaults.text.size)
            say('hud position and size reset.')
        else
            if not hud_state then say('nothing to show yet: run //setab compare <A> <B> [action]'); return end
            if hud:visible() then hud_hide() else hud_refresh(); hud:show() end
        end
    elseif cmd == 'tp' then
        filt.tpmin, filt.tpmax = tonumber(args[1]), tonumber(args[2])
        say('tp filter: ' .. tostring(filt.tpmin) .. ' - ' .. tostring(filt.tpmax))
        hud_dirty = hud_state ~= nil
    elseif cmd == 'target' then
        filt.target = (#args > 0) and table.concat(args, ' ') or nil
        say('target filter: ' .. tostring(filt.target))
        hud_dirty = hud_state ~= nil
    elseif cmd == 'filter' and args[1] == 'clear' then
        filt = {}; say('filters cleared.')
        hud_dirty = hud_state ~= nil
    elseif cmd == 'ignore' then
        local slot = args[1]
        if not slot then say('usage: //setab ignore <slot>'); return end
        local ign = ignore_set()
        if ign[slot] then ign[slot] = nil else ign[slot] = true end
        local l = {}
        for k in pairs(ign) do l[#l + 1] = k end
        table.sort(l); settings.ignore = table.concat(l, ','); config.save(settings)
        say('ignored slots: [' .. settings.ignore .. '] (set hashes change; relabel your sets)')
    elseif cmd == 'debug' then
        local a = args[1] and string.lower(args[1])
        if a == 'on' then debug_on = true elseif a == 'off' then debug_on = false else debug_on = not debug_on end
        say('debug ' .. (debug_on and 'on (chat + data/<name>/debug.log)' or 'off'))
    elseif cmd == 'reset' then
        if args[1] ~= 'confirm' then say('this erases the log. run: //setab reset confirm'); return end
        local path = data_dir() .. 'log.csv'
        local ok, err = replace_file(path, HEADER .. '\n')
        if not ok then say('could not erase the log (' .. tostring(err) .. '). Close log.csv if another program has it open, and try again.'); return end
        rows = {}
        local keep = {}   -- the waiting lines of this character are erased too; another character's stay
        for _, q in ipairs(queue) do if q.path ~= path then keep[#keep + 1] = q end end
        queue = keep
        say('log erased (the old log is kept as log.csv.bak).')
    else help() end
end

---------------------------------------------------------------- lifecycle
local function init()
    local pl = windower.ffxi.get_player()
    if not pl then return end
    if sets_dirty and save_sets(sets) then sets_dirty = false end   -- the previous character's automatic names, before they are replaced
    me_id, me_name = pl.id, pl.name
    pending = nil
    windower.create_dir(windower.addon_path .. 'data')
    windower.create_dir(windower.addon_path .. 'data/' .. me_name)
    load_sets(); load_rows()
    say(string.format('loaded %d rows, %d sets. //setab help', #rows, (function() local c = 0 for _ in pairs(sets) do c = c + 1 end return c end)()))
end

windower.register_event('load', function()
    if windower.ffxi.get_info().logged_in then init() end
end)
local function init_retry(left)
    init()
    if not me_id and left > 0 then coroutine.schedule(function() init_retry(left - 1) end, 5) end   -- the player may not be readable yet
end
windower.register_event('login', function() coroutine.schedule(function() init_retry(3) end, 5) end)
windower.register_event('logout', function() flush(); me_id = nil; pending = nil; hud_hide() end)
windower.register_event('zone change', function() pending = nil end)   -- a WS start does not carry over a zone change
windower.register_event('unload', function() flush(); hud:destroy(); tip:destroy() end)
windower.register_event('action', on_action)
windower.register_event('tp change', function(new_tp, old_tp)
    tp_prev, tp_prev_t = old_tp, os.clock()
    if debug_on then dbg(string.format('tp change new=%s old=%s', tostring(new_tp), tostring(old_tp))) end
end)
windower.register_event('addon command', on_command)
windower.register_event('prerender', function()
    if (#queue > 0 or sets_dirty) and os.clock() - last_flush > 10 then flush() end
    if hud_dirty and hud:visible() and os.clock() - hud_last > 1 then
        hud_last = os.clock()
        hud_refresh()
    end
end)

-- Mouse: dragging the table is done by libs/texts (and it saves the position); the wheel over the table resizes it;
-- the pointer over a part of the table shows what that part means (a second small HUD).
-- A move is never swallowed (returning true would stop libs/texts from dragging). Returning true on the wheel keeps it
-- from reaching the game while the cursor is on the table.
local MOUSE_MOVE, MOUSE_LEFT_DOWN, MOUSE_LEFT_UP, MOUSE_WHEEL = 0, 1, 2, 10
windower.register_event('mouse', function(mtype, x, y, delta, blocked)
    if mtype == MOUSE_MOVE then
        if not blocked then tip_update(x, y) end
        return
    elseif mtype == MOUSE_LEFT_DOWN then
        tip_suppress = true   -- no tooltip while the button is down (dragging the table)
        tip_hide()
        return
    elseif mtype == MOUSE_LEFT_UP then
        tip_suppress = false
        return
    end
    if blocked or mtype ~= MOUSE_WHEEL then return end
    if not hud:visible() or not hud:hover(x, y) then return end
    hud_set_size((settings.text.size or 11) + ((delta or 0) > 0 and 1 or -1))
    return true
end)
