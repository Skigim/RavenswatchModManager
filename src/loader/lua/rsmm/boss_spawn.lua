-- R.bossspawn — bring in the CURRENT chapter's boss on command.
--
-- STATUS: written 2026-10-15 from static evidence only. NOTHING HERE HAS RUN IN
-- THE GAME. `R.bossspawn.probe()` calls no engine function and is the first
-- thing to run on a new build; `awaken` and `spawn_from_selector` are the two
-- routes and are both unproven.
--
-- WHY IT IS NOT R.spawn ALONE. Chapter bosses are not spawned by the camp pool.
-- A per-chapter Map_Boss_Spawner_* entity (Objects\Map_Boss_Spawner\..._Model,
-- a state machine Sleeping -> Awakening -> Fighting -> Dying) spawns the boss
-- from its own `Boss To Spawn Selector` through its `Boss Spawner`, and it also
-- owns the arena fence, the boss's starting behaviour, the
-- REQUEST_BHV_DEFAULT_FIGHTING kick and the BOSS_* events. Facts, read from the
-- cooked Map_Boss_Spawner_Model / _Cinematic_Awakening (2026-10-15):
--
--   * The spawner's `Bhv Awakening` group holds five oCEntityCpntNamedEventListener
--     components: AWAKENING_START, AWAKENING_BLACKOUT_START, AWAKENING_BOSS_SPAWN,
--     AWAKENING_FENCE_UP, AWAKENING_CINE_END. AWAKENING_BOSS_SPAWN's handler state
--     activates `Base\Spawn Boss Tester`, which activates `Base\Boss Spawner`.
--   * Those five names are SENT by the entity `Map_Boss_Spawner_Cinematic_Awakening`
--     (one oCEntityCpntNamedEventSender each, broadcast=false). Every sender's
--     target collector is an oCOwnerEntityCollector: the entity that spawned the
--     cinematic, i.e. the Map_Boss_Spawner. So the events are ENTITY-TARGETED at
--     the spawner, not hero/world broadcasts — sending them to the hero or the
--     world dispatcher (what rsmm/named_event.lua and rsmm/run_flow.lua do) can
--     not reach it. They have to go to the SPAWNER ENTITY's own dispatcher.
--   * `Base\Boss REQUEST_BHV_DEFAULT_FIGHTING Event Sender` and `Arena Fence
--     REQUEST_BHV_ACTIVE Event Sender` target an oCSpawnedEntityCollector (the
--     entities this spawner made). BOSS_* senders are broadcast=true.
--   * Behaviour Awakening is entered from Sleeping by `Sleeping To Awakening
--     Tester` (heroes inside `Sleeping Heroes Detection Radius`, or the
--     BossTimeStart game event raising `Sleeping Time Over Flag`). Entering it
--     activates the cinematic spawner, BOSS_FIGHTING_START and the fight-triggered
--     global value. Hand-sent AWAKENING_* events do NOT enter that state.
--
-- NOT KNOWN (see docs/superpowers/plans/2026-10-15-boss-spawn.md): that the
-- native listener actually subscribes on the spawner entity's dispatcher while
-- the spawner is still Sleeping; what `Spawn Boss Tester` tests; whether the
-- Map_Boss_Spawner exists in the scene (and on the scene list) before the hero
-- is near it; the cinematic's real event order and spacing.
--
-- ROUTES
--   awaken(opts)               A. send the spawner its own AWAKENING_* events
--                                 (keeps fence / starting behaviour / BOSS_*).
--   spawn_from_selector(opts)  B. read the Boss To Spawn Selector's resolved
--                                 template and R.spawn.near it (bare boss: no
--                                 fence, no kick, no BOSS_* events).
--
--     R.bossspawn.probe()                  -> report   (read-only, logs every step)
--     R.bossspawn.candidates()             -> { {entity=, source=}, ... }
--     R.bossspawn.awaken{ sequence = "boss_spawn"|"start"|"full", delay = 0.75,
--                         entity = <override> }       -> true | false, why
--     R.bossspawn.spawn_from_selector{ offset = {8,0,0}, trust = false,
--                         entity = <override> }       -> true | false, why
--     R.bossspawn.why()                    -> last refusal, or nil
--
-- Everything that touches the engine is queued to the main thread and re-checks
-- its pointers on arrival. A spawner is found by structure (its component set),
-- not by name or address; the dispatcher offset is the one rsmm.lua LEARNS
-- (never a literal), so awaken refuses until the hero has interacted with
-- something once in the run.
return function(env)
    local R, I = env.R, env.I
    local NE = env.named_event                 -- rsmm/named_event.lua
    local disp_off = env.dispatcher_entity_off -- () -> number | nil
    local M = {}

    -- Runtime component class ids (data/class_ids.json), the keys of an
    -- entity's component map. A Map_Boss_Spawner owns all four.
    local CLS = {
        state_machine = 277897763,   -- oCEntityCpntStateMachine
        listener      = 278935830,   -- oCEntityCpntNamedEventListener
        spawner       = 267629480,   -- oCEntityCpntEntitySpawner
        selector      = 381059020,   -- oCEntitySelectorToSpawnEntityCpnt
    }
    -- oCEntitySelectorToSpawnEntry: entry+0x18 is the resolved template
    -- (docs/_re/kinds/spawn-system.md). The candidate vector's offset inside the
    -- selector is NOT known for this class (the flag-list subclass keeps it at
    -- +0x68/+0x70), so it is searched for, read-only, inside the component.
    local ENTRY_TEMPLATE = 0x18
    local SELECTOR_SCAN_MAX = 0x80           -- oCEntitySelectorToSpawnEntityCpnt is 0x80 bytes
    local MAX_ENTRIES = 32
    local RESOURCE_SETTINGS = 0x98           -- oCEntitySettingsResource -> embedded settings

    -- The cinematic's five events, in the order the spawner lists them. The
    -- ORDER is an inference from the names; the spacing is a guess.
    local SEQUENCES = {
        boss_spawn = { "AWAKENING_BOSS_SPAWN" },
        start      = { "AWAKENING_START" },
        full       = { "AWAKENING_START", "AWAKENING_BLACKOUT_START", "AWAKENING_BOSS_SPAWN",
                       "AWAKENING_FENCE_UP", "AWAKENING_CINE_END" },
    }
    local FEATURE = "R.bossspawn"
    local TAG = "[rsmm.bossspawn] "

    local _why
    local function refuse(msg)
        _why = msg
        R.log(TAG .. msg)
        return false, msg
    end

    local function is(obj, class)
        return R.ptr.has_vtable(obj) and R.rtti.name(obj) == class
    end

    local function session_client()
        if not (R.game and R.game.flag) then return false end
        local ok, connected = pcall(R.game.flag, "is_connected_to_session")
        if not ok or connected ~= true then return false end
        local ok2, host = pcall(R.game.flag, "is_session_host")
        return not (ok2 and host == true)
    end

    -- The component set of an oCEntity, or nil when it is not one.
    local function classify(e)
        if not is(e, "oCEntity") then return nil end
        local c = {}
        for k, id in pairs(CLS) do c[k] = R.net.component(e, id) end
        return c
    end

    local function spawner_like(c)
        return c ~= nil and c.state_machine ~= nil and c.listener ~= nil
               and c.spawner ~= nil and c.selector ~= nil
    end

    -- Candidates -----------------------------------------------------------
    -- Two independent finders, both by structure: the scene's entity list, and
    -- the dispatchers the gameplay bus hands us (an event delivered AT the
    -- spawner names its entity as dispatcher - offset). Cleared at every chapter
    -- boundary: freed memory keeps reading plausible for a long time.
    local cands, order = {}, {}
    local checked, checked_n = {}, 0

    local function add(e, source)
        if cands[e] then return end
        cands[e] = { entity = e, source = source }
        order[#order + 1] = e
        R.log(string.format(TAG .. "spawner candidate 0x%x (%s)", e, source))
    end

    local function reset(why)
        if #order > 0 then R.log(TAG .. "candidates dropped (" .. why .. ")") end
        cands, order = {}, {}
        checked, checked_n = {}, 0
    end
    R.on("run:start", function() reset("run:start") end)
    R.on("run:end", function() reset("run:end") end)
    R.on("gameplay:GAME_END_NEXT_CHAPTER", function() reset("chapter end") end)
    R.on("gameplay:MAP_GENERATION_DONE", function() reset("new map") end)

    R.on("*", function(ev, name)
        if type(name) ~= "string" or name:sub(1, 9) ~= "gameplay:" then return end
        local off = disp_off and disp_off() or nil
        if not off then return end
        local d = type(ev) == "table" and type(ev.dispatcher) == "string"
                  and tonumber(ev.dispatcher) or nil
        if not d or d == 0 or checked[d] then return end
        if checked_n > 4096 then checked, checked_n = {}, 0 end
        checked[d], checked_n = true, checked_n + 1
        local e = d - off
        if spawner_like(classify(e)) then add(e, "bus " .. name) end
    end)

    local function scan_scene()
        if not (R.spawn and R.spawn.entities) then return end
        for _, row in ipairs(R.spawn.entities()) do
            if spawner_like(classify(row.entity)) then add(row.entity, "scene list") end
        end
    end

    --- Spawner entities that still pass the structural test now.
    function M.candidates()
        scan_scene()
        local out = {}
        for _, e in ipairs(order) do
            if spawner_like(classify(e)) then out[#out + 1] = cands[e] end
        end
        return out
    end

    local function pick(opts)
        if opts and opts.entity ~= nil then
            if spawner_like(classify(opts.entity)) then return opts.entity end
            return nil, "opts.entity is not a Map_Boss_Spawner-shaped entity"
        end
        local list = M.candidates()
        if #list == 0 then
            return nil, "no spawner found: not in the scene list and no event has been delivered at one "
                .. "(run probe(); the bus needs RSMM_ENABLE_GAMEPLAY_EVENTS=1)"
        end
        if #list > 1 then
            local parts = {}
            for i, c in ipairs(list) do parts[i] = string.format("0x%x (%s)", c.entity, c.source) end
            return nil, #list .. " spawner candidates, refusing to guess: " .. table.concat(parts, ", ")
        end
        return list[1].entity
    end

    -- Selector entries (read-only) --------------------------------------------
    local function selector_vectors(sel)
        local out = {}
        for off = 0x08, SELECTOR_SCAN_MAX - 0x10, 8 do
            local data = I.read_u64(sel + off)
            local n = I.read_u32(sel + off + 8)
            if R.ptr.plausible(data) and type(n) == "number" and n >= 1 and n <= MAX_ENTRIES then
                local rows, good = {}, true
                for i = 0, n - 1 do
                    local entry = I.read_u64(data + i * 8)
                    local res = R.ptr.plausible(entry) and I.read_u64(entry + ENTRY_TEMPLATE) or nil
                    if is(res, "oCEntitySettingsResource") or is(res, "oCEntitySettings") then
                        rows[#rows + 1] = { entry = entry, template = res }
                    else
                        good = false
                        break
                    end
                end
                if good then out[#out + 1] = { off = off, count = n, rows = rows } end
            end
        end
        return out
    end

    local function template_name(t)
        if not (R.spawn and R.spawn.name_of) then return nil end
        local s = is(t, "oCEntitySettingsResource") and t + RESOURCE_SETTINGS or t
        local ok, name = pcall(R.spawn.name_of, s)
        return ok and name or nil
    end

    -- probe ---------------------------------------------------------------
    --- Walk everything both routes depend on and log each link. Calls no engine
    --- function. Returns a table of what was found.
    function M.probe()
        local report = { candidates = {} }
        R.log(TAG .. "probe start (read-only; no engine call)")

        local off = disp_off and disp_off() or nil
        report.dispatcher_off = off
        R.log(TAG .. "  dispatcher offset: " .. (off and string.format("entity+0x%x (learned)", off)
              or "NOT LEARNED yet — awaken() will refuse; the hero must interact with something once"))
        report.session_client = session_client()
        R.log(TAG .. "  session client: " .. tostring(report.session_client))

        report.primitives = {}
        for _, n in ipairs({ "NamedEvent_Dispatch", "NamedEvent_Id_FromCrc", "EntityValueUnion_DefaultCtor",
                             "EntityValueUnion_InitAsType", "EntityValueUnion_Destruct",
                             "EntityStore_CreateEntity" }) do
            local ok = R.engine.resolve(n) and true or false
            report.primitives[n] = ok
            R.log(TAG .. "  engine symbol " .. n .. ": " .. (ok and "resolves" or "UNRESOLVED"))
        end
        report.named_event = NE ~= nil
        R.log(TAG .. "  rsmm/named_event.lua: " .. (NE and "loaded" or "MISSING — awaken() unavailable"))
        R.log(TAG .. "  R.spawn: " .. (R.spawn and "loaded" or "MISSING — spawn_from_selector() unavailable"))
        local hero = R.entity and R.entity.hero and R.entity.hero() or nil
        R.log(TAG .. "  hero: " .. (hero and string.format("0x%x", hero) or "not captured"))

        local list = M.candidates()
        R.log(TAG .. "  spawner candidates: " .. #list)
        for i, c in ipairs(list) do
            local e = c.entity
            local comp = classify(e)
            local row = { entity = e, source = c.source, components = comp }
            R.log(string.format(TAG .. "  [%d] entity 0x%x via %s", i, e, c.source))
            for _, k in ipairs({ "state_machine", "listener", "spawner", "selector" }) do
                R.log(string.format(TAG .. "      %s component: 0x%x", k, comp[k] or 0))
            end
            if off then
                row.dispatcher = e + off
                R.log(string.format(TAG .. "      dispatcher e+0x%x = 0x%x (%s)", off, e + off,
                      R.ptr.plausible(e + off) and "plausible" or "NOT plausible"))
            end
            local x, y, z = nil, nil, nil
            if R.spawn and R.spawn.position_of then x, y, z = R.spawn.position_of(e) end
            if x then R.log(string.format(TAG .. "      position (%.1f, %.1f, %.1f)", x, y, z)) end
            row.vectors = selector_vectors(comp.selector)
            R.log(string.format(TAG .. "      selector %s: %d template vector(s) found by scan",
                  string.format("0x%x", comp.selector), #row.vectors))
            for _, v in ipairs(row.vectors) do
                R.log(string.format(TAG .. "        vector at selector+0x%x, %d entr%s", v.off,
                      v.count, v.count == 1 and "y" or "ies"))
                for j, r in ipairs(v.rows) do
                    r.name = template_name(r.template)
                    R.log(string.format(TAG .. "          [%d] entry 0x%x -> %s 0x%x name=%s", j, r.entry,
                          R.rtti.name(r.template) or "?", r.template, tostring(r.name)))
                end
            end
            report.candidates[i] = row
        end
        if #list == 0 then
            R.log(TAG .. "  none found. Stand near the boss tile, trigger any gameplay event, probe again.")
        end
        R.log(TAG .. "probe end")
        return report
    end

    -- Route A: the spawner's own awakening --------------------------------------
    local function send_step(e, name)
        local c = classify(e)
        if not spawner_like(c) then
            return refuse(string.format("spawner 0x%x is gone or changed — stopping before %s", e, name))
        end
        local off = disp_off and disp_off() or nil
        if not off then return refuse("dispatcher offset is not learned — stopping before " .. name) end
        local disp = e + off
        if not R.ptr.plausible(disp) then return refuse("spawner dispatcher is not plausible — stopping") end
        -- The payload is a bool true on the with-data carrier every other
        -- hand-sent event here uses; the awakening listeners are not known to
        -- read one.
        if not NE.send_value(FEATURE, name, NE.T_BOOL, true, disp) then
            return refuse("could not send " .. name)
        end
        return true
    end

    --- Send the spawner its AWAKENING_* events. opts.sequence "boss_spawn"
    --- (default; just the spawn step), "start", or "full"; opts.delay seconds
    --- between steps (default 0.75); opts.entity overrides the finder.
    function M.awaken(opts)
        opts = opts or {}
        local steps = SEQUENCES[opts.sequence or "boss_spawn"]
        if not steps then return refuse("unknown sequence '" .. tostring(opts.sequence) .. "'") end
        if not NE then return refuse("rsmm/named_event.lua is not loaded") end
        if session_client() then
            return refuse("refused on a session client: boss spawns are host-authoritative")
        end
        local off = disp_off and disp_off() or nil
        if not off then
            return refuse("the dispatcher offset has not been learned yet — interact with a chest or "
                .. "portal once, then retry")
        end
        local e, why = pick(opts)
        if not e then return refuse(why) end
        local delay = tonumber(opts.delay) or 0.75
        if delay < 0 then delay = 0 end
        _why = nil
        R.log(string.format(TAG .. "awaken: %s -> spawner 0x%x, %d step(s), %.2fs apart",
              opts.sequence or "boss_spawn", e, #steps, delay))
        local function step(i)
            if not steps[i] then return end
            if not send_step(e, steps[i]) then return end
            if steps[i + 1] then R.schedule.after_main(delay, function() step(i + 1) end) end
        end
        R.schedule.next_main(function() step(1) end)
        return true
    end

    -- Route B: the selector's own template ----------------------------------------
    --- R.spawn.near the template the spawner's Boss To Spawn Selector resolved.
    --- A bare boss: no arena fence, no starting-behaviour value, no
    --- REQUEST_BHV_DEFAULT_FIGHTING, no BOSS_* events. Refuses unless exactly
    --- one template is found AND its name contains "Boss" or opts.trust is true
    --- (an entity can own more than one selector, e.g. "Dying Cinematic selector
    --- to spawn", and the component map keeps one per class).
    function M.spawn_from_selector(opts)
        opts = opts or {}
        if not (R.spawn and R.spawn.near) then return refuse("R.spawn is not loaded") end
        local e, why = pick(opts)
        if not e then return refuse(why) end
        local comp = classify(e)
        local vectors = selector_vectors(comp.selector)
        local rows = {}
        for _, v in ipairs(vectors) do
            for _, r in ipairs(v.rows) do rows[#rows + 1] = r end
        end
        if #rows ~= 1 then
            return refuse(string.format("%d template entries found in the selector (need exactly 1) — "
                .. "run probe() and read the layout", #rows))
        end
        local t = rows[1].template
        local name = template_name(t)
        if not opts.trust and not (type(name) == "string" and name:find("Boss", 1, true)) then
            return refuse(string.format("template 0x%x (name=%s) is not confirmed to be the boss — "
                .. "pass trust=true after reading probe()", t, tostring(name)))
        end
        _why = nil
        R.log(string.format(TAG .. "spawn_from_selector: template 0x%x (%s) from spawner 0x%x",
              t, tostring(name), e))
        local ok, rwhy = R.spawn.near(t, { offset = opts.offset or { 8, 0, 0 },
                                          on_spawned = opts.on_spawned })
        if not ok then return refuse("R.spawn.near refused: " .. tostring(rwhy)) end
        return true
    end

    function M.why() return _why end

    return M
end
