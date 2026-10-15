-- R.aggro — make a live enemy (a chapter boss) start fighting on command, through
-- the game's own REQUEST_BHV_DEFAULT_FIGHTING named event. NOT PROVEN IN GAME:
-- written from cooked-entity data and the events-bus notes only (2026-10-15,
-- docs/superpowers/plans/2026-10-15-boss-aggro.md has what is confirmed vs not).
--
--     R.aggro.find("boss_")            -> { {entity, template, name, pos={x,y,z}}, ... }
--     R.aggro.dispatcher_of(entity)    -> dispatcher | nil, why        (read-only, validated)
--     R.aggro.force(entity [, opts])   -> true | false, why            (sends the event)
--     R.aggro.position(entity)         -> x, y, z | nil
--     R.aggro.hero_distance(entity)    -> metres-ish | nil
--     R.aggro.observe(entity, seconds) -> true | false, why            (logs the gameplay
--                                          events that reach that entity's dispatcher)
--
-- WHY THE DISPATCHER IS THE BOSS'S OWN. The bus delivers per dispatcher:
-- NamedEvent_Dispatch(disp, ev) looks the event id up in disp+0x28's channel map
-- and runs only the subscribers on that map (events-bus.md). The hero events go to
-- the hero's dispatcher and the GAME_END_* family to the world's (run_flow.lua),
-- so an event sent to either never reaches an NPC's subscriber. The game's own
-- sender of this event, `Boss REQUEST_BHV_DEFAULT_FIGHTING Event Sender` in
-- Map_Boss_Spawner_Model, carries an oCSpawnedEntityCollectorSettings that
-- names the spawner's `Boss Spawner` — i.e. it is addressed to the entities that
-- spawner placed. The native sender was not read, so "addressed to the boss's
-- entity dispatcher" is the working reading, not a fact.
--
-- The dispatcher is a sub-object of the oCEntity (the offset is learned at
-- runtime by rsmm.lua and handed in as a getter; it went stale once, 2026-07-09,
-- so it is never a literal here). It is learned from the hero's interaction event,
-- so one interaction (a chest, a fountain) must have happened first.
--
-- The event is built with named_event.send_value (a with-data carrier holding a
-- bool): the NPC listener reads no payload as far as the cooked data shows, and
-- the bus clones the event through its vftable, which the with-data ctor sets.
--
-- MAIN THREAD only (R.schedule.next_main), like every engine-mutating call.
return function(env)
    local R, I = env.R, env.I
    local NE = env.named_event                   -- rsmm/named_event.lua
    local disp_off = env.dispatcher_entity_off   -- () -> offset | nil
    local M = {}

    local EVENT       = "REQUEST_BHV_DEFAULT_FIGHTING"
    local ENTITY_POS  = 0x324      -- SetPosition's store (rsmm/spawn.lua)
    local DISP_CHAN   = 0x28       -- channel map (events-bus.md)
    local DISP_BUSY   = 0x18       -- "currently dispatching" guard (events-bus.md)
    local OBS_MAX     = 40         -- lines per observe() window
    local _POS_LIMIT  = 1.0e6

    local function log(msg) R.log("[rsmm.aggro] " .. msg) end

    local function refuse(msg)
        log(msg)
        return false, msg
    end

    local function is_entity(e)
        return type(e) == "number" and R.ptr.plausible(e) and R.ptr.has_vtable(e)
               and R.rtti.name(e) == "oCEntity"
    end

    local function finite(v)
        return type(v) == "number" and v == v and v - v == 0 and math.abs(v) < _POS_LIMIT
    end

    function M.position(entity)
        if not is_entity(entity) or type(I.read_f32) ~= "function" then return nil end
        local x = I.read_f32(entity + ENTITY_POS)
        local y = I.read_f32(entity + ENTITY_POS + 4)
        local z = I.read_f32(entity + ENTITY_POS + 8)
        if finite(x) and finite(y) and finite(z) then return x, y, z end
        return nil
    end

    function M.hero_distance(entity)
        local hero = R.entity and R.entity.hero and R.entity.hero() or nil
        local d = hero and R.spawn and R.spawn.describe(hero) or nil
        local hx, hy, hz = M.position(d and d.entity or nil)
        local x, y, z = M.position(entity)
        if not (hx and x) then return nil end
        return math.sqrt((hx - x) ^ 2 + (hy - y) ^ 2 + (hz - z) ^ 2)
    end

    --- Live enemies whose template path contains `match` (case-insensitive plain
    --- text; nil or "" = every enemy). One row per ENTITY, nearest the hero first
    --- when both positions read. Read-only.
    function M.find(match)
        local needle = type(match) == "string" and match ~= "" and match:lower() or nil
        local out, name_cache = {}, {}
        for _, row in ipairs(R.spawn.entities()) do
            local name = name_cache[row.template]
            if name == nil then
                name = R.spawn.name_of(row.template) or false
                name_cache[row.template] = name
            end
            local hit = not needle or (name and name:lower():find(needle, 1, true))
            if hit and R.spawn.is_enemy(row.entity) then
                local x, y, z = M.position(row.entity)
                out[#out + 1] = {
                    entity = row.entity, template = row.template, name = name or nil,
                    pos = x and { x, y, z } or nil, hero_distance = M.hero_distance(row.entity),
                }
            end
        end
        table.sort(out, function(a, b)
            return (a.hero_distance or math.huge) < (b.hero_distance or math.huge)
        end)
        return out
    end

    --- The dispatcher of an enemy entity, or nil + why. Everything the engine will
    --- walk is checked here: a live oCEntity that is an enemy, the learned offset,
    --- a plausible dispatcher whose channel map reads, and not mid-dispatch.
    function M.dispatcher_of(entity)
        if not is_entity(entity) then return nil, "not a live oCEntity" end
        if not R.spawn.is_enemy(entity) then
            return nil, "entity has no enemy controller (refusing to address a non-enemy)"
        end
        local off = disp_off and disp_off() or nil
        if not off then
            return nil, "dispatcher offset not learned yet — interact with anything once "
                .. "(chest, fountain) with RSMM_ENABLE_GAMEPLAY_EVENTS=1 and wait for the "
                .. "'[rsmm.interact] dispatcher sits at entity+0x..' log line"
        end
        local disp = entity + off
        if not R.ptr.plausible(disp) then return nil, "dispatcher address implausible" end
        local chan = I.read_u64(disp + DISP_CHAN)
        if not R.ptr.plausible(chan) then
            return nil, string.format("dispatcher 0x%x has no readable channel map", disp)
        end
        local busy = I.read_u32(disp + DISP_BUSY)
        if busy == nil then return nil, "dispatcher guard word unreadable" end
        if busy ~= 0 then
            return nil, string.format("dispatcher 0x%x is mid-dispatch (guard=0x%x)", disp, busy)
        end
        return disp
    end

    -- Dispatcher -> label, for the one observe() window that is open per target.
    local watching, hooked = {}, false

    local function ensure_hook()
        if hooked then return end
        hooked = true
        R.on("*", function(ev, name)
            if type(name) ~= "string" or name:sub(1, 9) ~= "gameplay:" then return end
            local d = type(ev) == "table" and type(ev.dispatcher) == "string"
                      and tonumber(ev.dispatcher) or nil
            local w = d and watching[d] or nil
            if not w or w.left <= 0 then return end
            w.left = w.left - 1
            log(string.format("  boss-dispatcher 0x%x saw %s (%d left)", d, name, w.left))
        end)
    end

    --- Log the gameplay events that fire at this enemy's dispatcher for `seconds`
    --- (default 10), up to OBS_MAX lines. Needs RSMM_ENABLE_GAMEPLAY_EVENTS=1.
    function M.observe(entity, seconds)
        local disp, why = M.dispatcher_of(entity)
        if not disp then return refuse("observe: " .. why) end
        ensure_hook()
        watching[disp] = { left = OBS_MAX }
        log(string.format("observing dispatcher 0x%x of entity 0x%x for %ss", disp, entity,
            tostring(seconds or 10)))
        R.schedule.after(tonumber(seconds) or 10, function()
            local w = watching[disp]
            watching[disp] = nil
            log(string.format("observe window closed for 0x%x (%d events logged)", disp,
                w and (OBS_MAX - w.left) or 0))
        end)
        return true
    end

    --- Send REQUEST_BHV_DEFAULT_FIGHTING to this enemy. opts.observe = seconds
    --- opens an observe() window first so the echo and any reaction are logged.
    function M.force(entity, opts)
        opts = opts or {}
        local disp, why = M.dispatcher_of(entity)
        if not disp then return refuse("force: " .. why) end
        if opts.observe then M.observe(entity, opts.observe) end
        log(string.format("force: sending %s to entity 0x%x via its dispatcher 0x%x",
            EVENT, entity, disp))
        local ok = NE.send_value("R.aggro", EVENT, NE.T_BOOL, true, disp)
        if not ok then return refuse("force: the event was not sent (see the lines above)") end
        return true
    end

    return M
end
