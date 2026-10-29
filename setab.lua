--[[
SetAB - per-gear-set damage logger / comparer for Windower 4 (Lua 5.1)
Read-only: listens to 'action' events, never sends packets.
Chat output is ASCII only (Japanese needs Shift-JIS conversion in the FFXI chat log).
]]

_addon.name     = 'SetAB'
_addon.author   = 'hikaruoshino'
_addon.version  = '0.2.4'
_addon.commands = {'setab', 'sab'}

local res      = require('resources')
local config   = require('config')
local extdata  = require('extdata')
local stats    = require('setab_stats')

local defaults = {enabled = true, ignore = ''}
local settings = config.load(defaults)

-- Windower's equipment slot names (ear1/ring1 etc. do not exist, so earrings and rings were never hashed before 0.2.2)
local SLOTS = {'main','sub','range','ammo','head','neck','left_ear','right_ear',
               'body','hands','left_ring','right_ring','back','waist','legs','feet'}

-- action categories whose "finish" packet carries damage
local FINISH_SELF = {[3] = true, [4] = true}                     -- WS, spell
local FINISH_PET  = {[3] = true, [4] = true, [11] = true, [13] = true} -- pet TP moves (verify 11/13 in game)

-- message ids (VERIFY in game; raw id is always written to the CSV so rows can be re-classified)
local MISS_MSG   = {[188] = true, [282] = true}
local RESIST_MSG = {[85] = true, [284] = true, [653] = true, [654] = true, [655] = true, [656] = true}
-- Only damage messages count as damage, for every category (buffs carry a status id in param, not damage:
-- e.g. a Garuda ward recorded "33" = Haste before 0.2.2). Built from res: "... points of damage" or "... drained".
local DMG_MSG = {}
for id, m in pairs(res.action_messages or {}) do
    if m.en and (string.find(m.en, 'points of damage', 1, true) or string.find(m.en, ' drained', 1, true)) then
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

local HEADER = 'ts,zone,target,actor,action,cat,set,hash,tp,weather,day,buffs,result,dmg,msg,hits'

local me_id, me_name
local rows  = {}   -- parsed log rows
local queue = {}   -- CSV lines waiting to be written
local sets  = {}   -- hash -> {name=, desc=}
local unnamed_count = 0
local pending_tp = -1
local pending_snap = nil   -- {hash, desc, t}: equipment read at the WS "start" packet (see on_action)
local tp_prev, tp_prev_t = nil, 0
local last_flush = os.clock()
local filt = {tpmin = nil, tpmax = nil, target = nil}
local debug_on = false   -- //setab debug on|off (temporary: prints the raw action values for in-game checks)

local function say(msg) windower.add_to_chat(207, 'SetAB: ' .. msg) end

local function clean(s)
    return (tostring(s):gsub('[,\r\n\t]', ' '))
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

---------------------------------------------------------------- sets.tsv
local function save_sets()
    local f = io.open(data_dir() .. 'sets.tsv', 'w')
    if not f then return end
    for h, s in pairs(sets) do
        f:write(h, '\t', clean(s.name), '\t', clean(s.desc or ''), '\n')
    end
    f:close()
end

local function load_sets()
    sets = {}
    unnamed_count = 0
    local f = io.open(data_dir() .. 'sets.tsv', 'r')
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
                }
            end
        end
    end
    f:close()
end

local function flush()
    if #queue == 0 then return end
    local f = io.open(data_dir() .. 'log.csv', 'a')
    if not f then return end
    for _, l in ipairs(queue) do f:write(l, '\n') end
    f:close()
    queue = {}
    last_flush = os.clock()
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
        sets[hash] = {name = 'unnamed_' .. unnamed_count, desc = desc}
        save_sets()
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
local function total_damage(cat, t)
    local total, hits, first_msg = 0, 0, 0
    for i, a in ipairs(t.actions or {}) do
        local m, p = a.message or 0, a.param or 0
        if i == 1 then first_msg = m end
        if DMG_MSG[m] and p > 0 then total, hits = total + p, hits + 1 end
    end
    return total, hits, first_msg
end

local function classify(dmg, msg)
    if dmg and dmg > 0 then return 'hit' end
    if MISS_MSG[msg] then return 'miss' end
    if RESIST_MSG[msg] then return 'resist' end
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
            local pl = windower.ffxi.get_player()
            local tp = pl and pl.vitals and pl.vitals.tp or -1
            -- the TP may already be spent when this packet arrives (the 'tp change' event can come first): take the TP that was just lost
            if tp_prev and os.clock() - tp_prev_t < 3 and tp_prev > tp then tp = tp_prev end
            pending_tp = tp
            -- read the equipment now: the WS gear is on at the start, but the aftercast swap can land before the result packet
            -- (0.2.3 sometimes recorded the idle/engaged set instead of the WS set)
            local hash, desc = snapshot()
            pending_snap = hash and {hash = hash, desc = desc, t = os.clock()} or nil
        end
        return
    end
    local ok = (kind == 'self' and FINISH_SELF[cat]) or (kind == 'pet' and FINISH_PET[cat])
    if not ok then return end

    -- decide what to record first, so buff spells etc. do not cost a snapshot or create unnamed sets
    local todo = {}
    for _, t in ipairs(act.targets or {}) do
        if t.actions and t.actions[1] then
            local dmg, hits, msg = total_damage(cat, t)
            local landed = false
            if cat == 4 and dmg == 0 and LAND_MSG[msg] then
                local mob = windower.ffxi.get_mob_by_id(t.id)
                landed = mob ~= nil and mob.spawn_type == 16   -- enemies only (not party members)
            end
            if dmg > 0 or MISS_MSG[msg] or RESIST_MSG[msg] or landed then
                todo[#todo + 1] = {id = t.id, dmg = dmg, hits = hits, msg = msg}
            end
        end
    end
    if #todo == 0 then return end

    local hash, desc
    if kind == 'self' and cat == 3 and pending_snap and os.clock() - pending_snap.t < 30 then
        hash, desc = pending_snap.hash, pending_snap.desc   -- the set at the WS start
    else
        hash, desc = snapshot()
    end
    pending_snap = nil
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
        tp = pending_tp
        if tp < 0 then
            -- fallback when no start packet was seen: use the TP seen just before it was spent
            tp = pl and pl.vitals and pl.vitals.tp or -1
            if tp_prev and os.clock() - tp_prev_t < 3 and tp_prev > tp then tp = tp_prev end
        end
    end
    pending_tp = -1
    local aname = action_name(cat, act.param, todo[1].msg)

    for _, d in ipairs(todo) do
        local mob = windower.ffxi.get_mob_by_id(d.id)
        local r = {
            ts = os.date('%Y-%m-%d %H:%M:%S'), zone = clean(zone or '?'),
            target = clean(mob and mob.name or '?'), actor = kind, action = clean(aname),
            cat = cat, set = setname, hash = hash, tp = tp,
            weather = tostring(info.weather or ''), day = tostring(info.day or ''),
            buffs = table.concat(buffs, '-'), result = classify(d.dmg, d.msg),
            dmg = d.dmg, msg = d.msg, hits = d.hits,
        }
        rows[#rows + 1] = r
        queue[#queue + 1] = table.concat({r.ts, r.zone, r.target, r.actor, r.action, r.cat,
            r.set, r.hash, r.tp, r.weather, r.day, r.buffs, r.result, r.dmg, r.msg, r.hits}, ',')
    end
end

---------------------------------------------------------------- reporting
local function current_name(r)
    return sets[r.hash] and sets[r.hash].name or r.set
end

local function passes(r)
    if filt.tpmin and (r.tp < 0 or r.tp < filt.tpmin) then return false end
    if filt.tpmax and (r.tp < 0 or r.tp > filt.tpmax) then return false end
    if filt.target and not string.find(string.lower(r.target), string.lower(filt.target), 1, true) then
        return false
    end
    return true
end

local function summarize(list)
    local dm, miss = {}, 0
    for _, r in ipairs(list) do
        if r.result == 'hit' then dm[#dm + 1] = r.dmg
        elseif r.result == 'miss' or r.result == 'resist' then miss = miss + 1 end
    end
    return {
        n = #list, hits = #dm, miss = miss, dm = dm,
        mean = stats.mean(dm), med = stats.median(dm), ci = stats.ci95(dm),
    }
end

local function f0(x) return x and string.format('%.0f', x) or '-' end
local function ci(x) return x and ('+-' .. string.format('%.0f', x)) or '+-?' end

local function matching(actionname)
    local out = {}
    local want = actionname and string.lower(actionname)
    for _, r in ipairs(rows) do
        if passes(r) and (not want or string.find(string.lower(r.action), want, 1, true)) then
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
    for i = 1, math.min(#order, 5) do
        say('== ' .. order[i].a .. ' (n=' .. order[i].n .. ')')
        local by_set = stats.group(by_action[order[i].a], current_name)
        local names = {}
        for nm in pairs(by_set) do names[#names + 1] = nm end
        table.sort(names)
        for _, nm in ipairs(names) do
            local s = summarize(by_set[nm])
            local missp = s.n > 0 and (100 * s.miss / s.n) or 0
            say(string.format('  %-18s n=%d avg=%s med=%s %s miss/resist=%.0f%%',
                nm, s.n, f0(s.mean), f0(s.med), ci(s.ci), missp))
        end
    end
end

local function compare(a, b, actionname)
    local list = matching(actionname)
    local by_set = stats.group(list, current_name)
    local la, lb = by_set[a], by_set[b]
    if not la or not lb then say('need rows for both sets: ' .. a .. ' / ' .. b); return end
    local sa, sb = summarize(la), summarize(lb)
    if not sa.mean or not sb.mean then say('no hit rows for one of the sets.'); return end
    local diff = sa.mean - sb.mean
    local pct = sb.mean ~= 0 and (100 * diff / sb.mean) or 0
    local t = stats.welch(sa.dm, sb.dm)
    say(string.format('%s: n=%d avg=%s | %s: n=%d avg=%s', a, sa.n, f0(sa.mean), b, sb.n, f0(sb.mean)))
    local verdict
    if not t then verdict = 'not enough data (need 2+ hits per set)'
    elseif math.abs(t) >= 2 then verdict = 'likely a real difference (|t|>=2)'
    else verdict = 'no clear difference yet (|t|<2); collect more samples' end
    say(string.format('diff %+.0f (%+.1f%%) t=%s -> %s', diff, pct, t and string.format('%.2f', t) or '-', verdict))
end

local function list_sets()
    local counts = {}
    for _, r in ipairs(rows) do counts[r.hash] = (counts[r.hash] or 0) + 1 end
    for h, s in pairs(sets) do
        say(string.format('%s  %-16s rows=%d', h, s.name, counts[h] or 0))
    end
end

---------------------------------------------------------------- commands
local function help()
    say('//setab on|off | status')
    say('//setab label <name>      name the currently equipped set')
    say('//setab name <hash> <name> rename a set by hash (see //setab sets)')
    say('//setab sets              list known sets')
    say('//setab report [action]   per-set stats')
    say('//setab compare <A> <B> [action]')
    say('//setab tp <min> [max] | target <text> | filter clear')
    say('//setab ignore <slot>     toggle a slot out of the set hash (e.g. ammo)')
    say('//setab reset confirm     erase the log')
    say('//setab debug on|off      print raw action values (temporary, for in-game checks)')
end

local function on_command(cmd, ...)
    local args = {...}
    cmd = cmd and string.lower(cmd) or 'help'
    if cmd == 'on' or cmd == 'off' then
        settings.enabled = (cmd == 'on'); config.save(settings)
        say('recording ' .. cmd)
    elseif cmd == 'status' then
        say(string.format('enabled=%s rows=%d sets=%d ignore=[%s]',
            tostring(settings.enabled), #rows, (function() local c = 0 for _ in pairs(sets) do c = c + 1 end return c end)(),
            settings.ignore or ''))
    elseif cmd == 'label' then
        local nm = table.concat(args, ' ')
        if nm == '' then say('usage: //setab label <name>'); return end
        local hash, desc = snapshot()
        if not hash then say('cannot read equipment.'); return end
        sets[hash] = {name = clean(nm), desc = desc}
        save_sets(); say('labeled ' .. hash .. ' as ' .. nm)
    elseif cmd == 'name' then
        local hash, nm = args[1], table.concat(args, ' ', 2)
        if not hash or not sets[hash] or nm == '' then say('usage: //setab name <hash> <name>'); return end
        sets[hash].name = clean(nm); save_sets(); say('renamed.')
    elseif cmd == 'sets' then list_sets()
    elseif cmd == 'report' then report(table.concat(args, ' ') ~= '' and table.concat(args, ' ') or nil)
    elseif cmd == 'compare' then
        if #args < 2 then say('usage: //setab compare <A> <B> [action]'); return end
        compare(args[1], args[2], args[3] and table.concat(args, ' ', 3) or nil)
    elseif cmd == 'tp' then
        filt.tpmin, filt.tpmax = tonumber(args[1]), tonumber(args[2])
        say('tp filter: ' .. tostring(filt.tpmin) .. ' - ' .. tostring(filt.tpmax))
    elseif cmd == 'target' then
        filt.target = (#args > 0) and table.concat(args, ' ') or nil
        say('target filter: ' .. tostring(filt.target))
    elseif cmd == 'filter' and args[1] == 'clear' then
        filt = {}; say('filters cleared.')
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
        rows, queue = {}, {}
        local f = io.open(data_dir() .. 'log.csv', 'w')
        if f then f:write(HEADER, '\n'); f:close() end
        say('log erased.')
    else help() end
end

---------------------------------------------------------------- lifecycle
local function init()
    local pl = windower.ffxi.get_player()
    if not pl then return end
    me_id, me_name = pl.id, pl.name
    windower.create_dir(windower.addon_path .. 'data')
    windower.create_dir(windower.addon_path .. 'data/' .. me_name)
    load_sets(); load_rows()
    say(string.format('loaded %d rows, %d sets. //setab help', #rows, (function() local c = 0 for _ in pairs(sets) do c = c + 1 end return c end)()))
end

windower.register_event('load', function()
    if windower.ffxi.get_info().logged_in then init() end
end)
windower.register_event('login', function() coroutine.schedule(init, 5) end)
windower.register_event('logout', function() flush(); me_id = nil end)
windower.register_event('unload', flush)
windower.register_event('action', on_action)
windower.register_event('tp change', function(new_tp, old_tp)
    tp_prev, tp_prev_t = old_tp, os.clock()
    if debug_on then dbg(string.format('tp change new=%s old=%s', tostring(new_tp), tostring(old_tp))) end
end)
windower.register_event('addon command', on_command)
windower.register_event('prerender', function()
    if #queue > 0 and os.clock() - last_flush > 10 then flush() end
end)
