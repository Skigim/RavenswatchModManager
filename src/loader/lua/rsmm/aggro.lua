-- R.aggro — make a live enemy (a chapter boss) start fighting on command, through
-- the game's own REQUEST_BHV_DEFAULT_FIGHTING named event. NOT PROVEN IN GAME:
-- written from cooked-entity data and the events-bus notes only (2026-10-15,
-- docs/superpowers/plans/2026-10-15-boss-aggro.md has what is confirmed vs not).
--
--     R.aggro.find("boss_")            -> { {entity, template, name, pos={x,y,z}}, ... }, stats
--     R.aggro.census()                 -> { {entity, template, store}, ... }, stats
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
-- WHERE ENEMIES ARE. Not only on the scene spawner's list (R.spawn.entities):
-- a camp keeps its enemies on its OWN oCEntitySpawner (entity+0x38 names it;
-- measured in game 2026-09-13), and a Map_Boss_Spawner places the boss through
-- its own `Boss Spawner` component. census() walks the scene list, then every
-- oCEntitySpawner embedded in a component of an entity it has seen (or named by
-- an entity's +0x38), breadth first, read-only. The scene list is reached from
-- the hero, so the hero must be captured (RSMM_ENABLE_HERO_CAPTURE; a mod asks
-- for it with `loader_flags` in its manifest). First playtest without this:
-- "0 live enemies" (2026-10-15).
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

    -- Every store is an intrusive list, the same layout as the scene spawner's
    -- (spawn.lua): count +0x18, head +0x28, next entity +0x10.
    local SP_COUNT, SP_HEAD, E_NEXT = 0x18, 0x28, 0x10
    -- Stores are themselves chained, prev +0x08 / next +0x10 (hit trace in game
    -- 2026-10-15: three camp stores, each linking two more oCEntitySpawners).
    local SP_PREV, SP_NEXT = 0x08, 0x10
    local E_OWNER       = 0x38    -- entity -> the oCEntitySpawner that placed it
    local CPNT_STORE    = 0x68    -- where spawner components embed their store
                                  -- (confirmed for camp stores, same trace)
    local SCAN_TO       = 0x100   -- spawner-class components: search up to here
    local LIST_MAX      = 8192
    local MAX_STORES    = 2048
    local MAX_ENTITIES  = 16384
    -- Runtime component classes that own a store (data/class_ids.json).
    local SPAWNER_CLASSES = {
        [267629480] = true,   -- oCEntityCpntEntitySpawner
        [369581258] = true,   -- oCDtEntityCpntTileSpawner
        [370187979] = true,   -- oCDtEntityCpntHeroSpawner
    }

    local function is(obj, class)
        return R.ptr.has_vtable(obj) and R.rtti.name(obj) == class
    end

    local function walk_store(sp, fn)
        local n = I.read_u32(sp + SP_COUNT)
        if type(n) ~= "number" or n > LIST_MAX then return end
        local e, seen = I.read_u64(sp + SP_HEAD), 0
        while e and e ~= 0 and seen < n and is(e, "oCEntity") do
            seen = seen + 1
            fn(e)
            e = I.read_u64(e + E_NEXT)
        end
    end

    -- Stores embedded in the entity's components, from its class-id map
    -- (R.net._k: slots +0x5f0 of { u32 class; u64 component }, mask +0x600).
    local function stores_in(entity, out)
        local k = R.net and R.net._k
        if not k then return end
        local slots, mask = I.read_u64(entity + k.SLOTS), I.read_u64(entity + k.MASK)
        if not R.ptr.plausible(slots) or type(mask) ~= "number" or mask < 0
           or mask >= k.MAX then return end
        for i = 0, mask do
            local cls = I.read_u32(slots + i * 0x10)
            local c = I.read_u64(slots + i * 0x10 + 8)
            if cls and cls ~= 0 and R.ptr.plausible(c) and R.ptr.has_vtable(c) then
                if is(c + CPNT_STORE, "oCEntitySpawner") then
                    out[#out + 1] = c + CPNT_STORE
                elseif SPAWNER_CLASSES[cls] then
                    for off = 0x10, SCAN_TO, 8 do
                        if is(c + off, "oCEntitySpawner") then
                            out[#out + 1] = c + off
                            break
                        end
                    end
                end
            end
        end
    end

    --- Every entity reachable from the scene: { {entity, template, store}, ... }
    --- plus stats {scene, stores, entities}. `store` is "scene" or the address of
    --- the oCEntitySpawner the entity was found on. Read-only.
    function M.census()
        local rows, stats = {}, { scene = 0, stores = 0, entities = 0 }
        local hero = R.entity and R.entity.hero and R.entity.hero() or nil
        if not hero then
            stats.why = "no hero: the scene list is reached from the hero "
                .. "(RSMM_ENABLE_HERO_CAPTURE off, or not in a run yet)"
            return rows, stats
        end
        local seen_e, seen_s, queue = {}, {}, {}
        local function enqueue(sp)
            if sp and not seen_s[sp] and #queue < MAX_STORES and is(sp, "oCEntitySpawner") then
                seen_s[sp] = true
                queue[#queue + 1] = sp
            end
        end
        local function add(e, t, store)
            if seen_e[e] or #rows >= MAX_ENTITIES then return end
            seen_e[e] = true
            rows[#rows + 1] = { entity = e, template = t, store = store }
            local found = {}
            stores_in(e, found)
            found[#found + 1] = I.read_u64(e + E_OWNER)
            for _, sp in ipairs(found) do enqueue(sp) end
        end
        local scene = R.spawn.entities()
        stats.scene = #scene
        for _, r in ipairs(scene) do add(r.entity, r.template, "scene") end
        local qi = 1
        while qi <= #queue do
            local sp = queue[qi]
            qi = qi + 1
            stats.stores = stats.stores + 1
            enqueue(I.read_u64(sp + SP_PREV))
            enqueue(I.read_u64(sp + SP_NEXT))
            walk_store(sp, function(e) add(e, R.spawn.template_of(e), sp) end)
        end
        stats.entities = #rows
        stats.seen_entities, stats.seen_stores = seen_e, seen_s
        return rows, stats
    end

    --- Where does this entity's store live? Logs and returns what is readable:
    --- the store named by entity+0x38, its first pointer fields with their RTTI,
    --- the nearest objects with a vtable BEFORE it (the candidates for the
    --- object that embeds it), the first of those that names itself a component
    --- with its +0x08 owner, and whether that owner's component map holds it
    --- (and under which class id). Read-only diagnostics for census().
    local TRACE_BACK, TRACE_FIELDS, TRACE_HITS = 0x800, 0x60, 6
    function M.trace_store(entity)
        local out = { entity = entity }
        if not is_entity(entity) then
            log("trace: not a live oCEntity")
            return out
        end
        local sp = I.read_u64(entity + E_OWNER)
        out.store = sp
        out.store_class = R.ptr.has_vtable(sp) and R.rtti.name(sp) or nil
        log(string.format("trace: entity 0x%x store(+0x38)=0x%x rtti=%s count=%s",
            entity, sp or 0, tostring(out.store_class),
            tostring(sp and I.read_u32(sp + SP_COUNT))))
        if not R.ptr.plausible(sp) then return out end
        out.fields = {}
        for off = 0, TRACE_FIELDS, 8 do
            local v = I.read_u64(sp + off)
            local cls = R.ptr.plausible(v) and R.ptr.has_vtable(v) and R.rtti.name(v) or nil
            if cls then
                out.fields[#out.fields + 1] = { off = off, value = v, class = cls }
                log(string.format("trace:   store+0x%x -> 0x%x %s", off, v, cls))
            end
        end
        out.before = {}
        for off = 8, TRACE_BACK, 8 do
            local obj = sp - off
            if R.ptr.has_vtable(obj) then
                local cls = R.rtti.name(obj)
                out.before[#out.before + 1] = { off = off, obj = obj, class = cls }
                log(string.format("trace:   store-0x%x = 0x%x %s", off, obj, tostring(cls)))
                -- The spawner component, not the value signals packed before
                -- the store (the first trace picked a signal at -0x30).
                if not out.container and type(cls) == "string" and cls:find("Cpnt", 1, true)
                   and cls:find("Spawner", 1, true) then
                    out.container, out.container_class, out.embed_off = obj, cls, off
                end
                if #out.before >= TRACE_HITS then break end
            end
        end
        if out.container then
            local owner = I.read_u64(out.container + 0x08)
            out.owner = owner
            out.owner_class = R.ptr.has_vtable(owner) and R.rtti.name(owner) or nil
            local k = R.net and R.net._k
            if k and is(owner, "oCEntity") then
                local slots, mask = I.read_u64(owner + k.SLOTS), I.read_u64(owner + k.MASK)
                if R.ptr.plausible(slots) and type(mask) == "number" and mask >= 0 and mask < k.MAX then
                    for i = 0, mask do
                        if I.read_u64(slots + i * 0x10 + 8) == out.container then
                            out.owner_class_id = I.read_u32(slots + i * 0x10)
                            break
                        end
                    end
                end
            end
            log(string.format("trace: container 0x%x %s embeds the store at +0x%x; owner 0x%x %s; "
                .. "owner map class id %s", out.container, out.container_class, out.embed_off,
                owner or 0, tostring(out.owner_class), tostring(out.owner_class_id)))
        else
            log("trace: no component with a vtable within 0x" .. string.format("%x", TRACE_BACK)
                .. " bytes before the store")
        end
        return out
    end

    --- Why does census() miss this (hit) enemy? Runs a census and logs: whether
    --- the entity and its store are in it; how far the store's own list walks
    --- from the head (+0x28 / next +0x10) and from the tail (+0x20 / prev +0x08),
    --- and whether either reaches the entity; then CHAIN_STEPS stores each way
    --- along the store chain (+0x08 / +0x10) with their counts, selector RTTI
    --- (+0x60) and census membership; and the store's spawner component
    --- (store - 0x68) with its +0x08 owner. Read-only.
    local CHAIN_STEPS = 8
    local SP_TAIL, E_PREV, SP_SELECTOR = 0x20, 0x08, 0x60
    function M.crosscheck(entity)
        local out = {}
        local _, stats = M.census()
        local se, ss = stats.seen_entities or {}, stats.seen_stores or {}
        local sp = I.read_u64(entity + E_OWNER)
        out.in_census, out.store_in_census = se[entity] == true, ss[sp] == true
        log(string.format("xcheck: enemy 0x%x in census=%s; store 0x%x in census=%s "
            .. "(census %s scene, %s stores, %s entities)", entity, tostring(out.in_census),
            sp or 0, tostring(out.store_in_census), tostring(stats.scene),
            tostring(stats.stores), tostring(stats.entities)))
        if not is(sp, "oCEntitySpawner") then return out end
        local function walk(start, link)
            local n, e, found = 0, I.read_u64(sp + start), false
            while e and e ~= 0 and n < LIST_MAX and is(e, "oCEntity") do
                n = n + 1
                if e == entity then found = true end
                e = I.read_u64(e + link)
            end
            return n, found, e
        end
        local hn, hfound, hstop = walk(SP_HEAD, E_NEXT)
        local tn, tfound, tstop = walk(SP_TAIL, E_PREV)
        out.head_walk, out.head_found, out.tail_walk, out.tail_found = hn, hfound, tn, tfound
        log(string.format("xcheck: store count=%s; head walk %d (reaches enemy=%s, stopped at 0x%x %s); "
            .. "tail walk %d (reaches enemy=%s, stopped at 0x%x %s)",
            tostring(I.read_u32(sp + SP_COUNT)), hn, tostring(hfound), hstop or 0,
            tostring(R.ptr.has_vtable(hstop) and R.rtti.name(hstop) or nil),
            tn, tostring(tfound), tstop or 0,
            tostring(R.ptr.has_vtable(tstop) and R.rtti.name(tstop) or nil)))
        out.chain = {}
        for _, dir in ipairs({ { "prev", SP_PREV }, { "next", SP_NEXT } }) do
            local cur = sp
            for step = 1, CHAIN_STEPS do
                cur = I.read_u64(cur + dir[2])
                if not is(cur, "oCEntitySpawner") then
                    log(string.format("xcheck:   %s %d: 0x%x %s (end)", dir[1], step, cur or 0,
                        tostring(R.ptr.has_vtable(cur) and R.rtti.name(cur) or nil)))
                    break
                end
                local sel = I.read_u64(cur + SP_SELECTOR)
                out.chain[#out.chain + 1] = { dir = dir[1], step = step, store = cur,
                                              in_census = ss[cur] == true }
                log(string.format("xcheck:   %s %d: store 0x%x count=%s in census=%s selector=%s",
                    dir[1], step, cur, tostring(I.read_u32(cur + SP_COUNT)), tostring(ss[cur] == true),
                    tostring(R.ptr.has_vtable(sel) and R.rtti.name(sel) or nil)))
            end
        end
        local cpnt = sp - CPNT_STORE
        if R.ptr.has_vtable(cpnt) then
            local owner = I.read_u64(cpnt + 0x08)
            out.component_class = R.rtti.name(cpnt)
            out.owner, out.owner_in_census = owner, se[owner] == true
            log(string.format("xcheck: store-0x68 = %s; its +0x08 = 0x%x %s, in census=%s",
                tostring(out.component_class), owner or 0,
                tostring(R.ptr.has_vtable(owner) and R.rtti.name(owner) or nil),
                tostring(out.owner_in_census)))
        end
        return out
    end

    --- Live enemies whose template path contains `match` (case-insensitive plain
    --- text; nil or "" = every enemy). One row per ENTITY, nearest the hero first
    --- when both positions read. Read-only. Second value: census stats.
    function M.find(match)
        local needle = type(match) == "string" and match ~= "" and match:lower() or nil
        local out, name_cache = {}, {}
        local all, stats = M.census()
        for _, row in ipairs(all) do
            -- A store entity may have no readable template: no name, never an index.
            local name = false
            if row.template then name = name_cache[row.template] end
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
        return out, stats
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
