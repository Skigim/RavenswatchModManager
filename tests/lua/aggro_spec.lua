-- Unit tests for src/loader/lua/rsmm/aggro.lua under a hand-built env (no
-- rsmm.lua, no engine). Run with plain lua 5.4:
--     lua tests/lua/aggro_spec.lua src/loader/lib
-- (the same argument as rsmm_spec.lua; submodules are found at <lib>/../lua).
local LIB = (arg and arg[1]) or "src/loader/lib"
package.path = LIB .. "/../lua/?.lua;" .. package.path

local failed, total = 0, 0
local function check(cond, msg)
    total = total + 1
    if not cond then failed = failed + 1; print("FAIL: " .. msg) end
end

local OFF = 0x4d8
local BOSS, GRUNT, HERO_E = 0x1000000, 0x2000000, 0x3000000
local mem, classes, enemies = {}, {}, {}
local logs, sent = {}, {}
classes[BOSS], classes[GRUNT], classes[HERO_E] = "oCEntity", "oCEntity", "oCEntity"
enemies[BOSS], enemies[GRUNT] = true, true
local function setd(entity, busy)       -- a plausible dispatcher at entity+OFF
    mem[entity + OFF + 0x28] = 0x7000000
    mem[entity + OFF + 0x18] = busy or 0
end
setd(BOSS); setd(GRUNT); setd(HERO_E)
local function setpos(e, x, y, z) mem[e + 0x324], mem[e + 0x328], mem[e + 0x32c] = x, y, z end
setpos(BOSS, 10, 0, 0); setpos(GRUNT, 1, 0, 0); setpos(HERO_E, 0, 0, 0)

-- Census. The scene list holds GRUNT plus two non-enemy holders. CAMP owns a
-- component with a store at the usual +0x68; BSP (a boss spawner) owns a
-- spawner-class component whose store sits elsewhere (+0x80), found by the scan.
-- CAMP_EN and BOSS are on those stores only, not on the scene list.
local CAMP, CAMP_EN, BSP = 0x4000000, 0x4100000, 0x4200000
local CAMP_CPNT, BSP_CPNT = 0x4800000, 0x4900000
local SPAWNER_CLS = 267629480
classes[CAMP], classes[CAMP_EN], classes[BSP] = "oCEntity", "oCEntity", "oCEntity"
enemies[CAMP_EN] = true
setd(CAMP_EN)
setpos(CAMP_EN, 5, 0, 0)
local function cmap(e, cls, cpnt)              -- a one-slot component map
    local slots = e + 0x700
    mem[e + 0x5f0], mem[e + 0x600] = slots, 0
    mem[slots], mem[slots + 8] = cls, cpnt
end
local function store(sp, ...)                   -- an oCEntitySpawner list
    classes[sp] = "oCEntitySpawner"
    local list = { ... }
    mem[sp + 0x18], mem[sp + 0x28] = #list, list[1] or 0
    for i, e in ipairs(list) do mem[e + 0x10] = list[i + 1] or 0 end
end
classes[CAMP_CPNT] = "oCEntityCpntEntitySpawner"
cmap(CAMP, 111, CAMP_CPNT)
store(CAMP_CPNT + 0x68, CAMP_EN)
-- A second camp whose store is reachable ONLY through the store chain
-- (camp store +0x10 -> next store), as the in-game hit trace showed.
local CAMP2_STORE, CAMP2_EN = 0x4a00000, 0x4b00000
classes[CAMP2_EN] = "oCEntity"
enemies[CAMP2_EN] = true
setd(CAMP2_EN)
setpos(CAMP2_EN, 7, 0, 0)
store(CAMP2_STORE, CAMP2_EN)
mem[CAMP_CPNT + 0x68 + 0x10] = CAMP2_STORE
classes[BSP_CPNT] = "oCEntityCpntEntitySpawner"
cmap(BSP, SPAWNER_CLS, BSP_CPNT)
store(BSP_CPNT + 0x80, BOSS)
local templates = { [BOSS] = 0xb0, [CAMP_EN] = 0xa1, [CAMP2_EN] = 0xa2 }

local hero_on = true
local off_value = OFF
local R = {
    log = function(m) logs[#logs + 1] = m end,
    ptr = { plausible = function(p) return type(p) == "number" and p >= 0x10000 and p % 8 == 0 end,
            has_vtable = function(p) return classes[p] ~= nil end },
    rtti = { name = function(p) return classes[p] end },
    entity = { hero = function() return hero_on and HERO_E or nil end },
    net = { _k = { SLOTS = 0x5f0, MASK = 0x600, MAX = 1024 } },
    spawn = {
        entities = function()
            if not hero_on then return {} end
            return { { entity = GRUNT, template = 0xa0 }, { entity = CAMP, template = 0xc0 },
                     { entity = BSP, template = 0xd0 } }
        end,
        template_of = function(e) return templates[e] end,
        is_enemy = function(e) return enemies[e] == true end,
        name_of = function(t) return t == 0xb0 and "Enemies\\Boss_X\\Boss_X.entity.ot" or "Enemies\\Grunt.entity.ot" end,
        describe = function(e) return { entity = e } end,
    },
    schedule = { after = function() end },
    on = function() end,
}
local I = {
    read_u64 = function(a) return mem[a] end,
    read_u32 = function(a) return mem[a] end,
    read_f32 = function(a) return mem[a] end,
}
local NE = { T_BOOL = 2, send_value = function(feature, name, vtype, value, world)
    sent[#sent + 1] = { feature = feature, name = name, vtype = vtype, value = value, world = world }
    return true
end }

local aggro = require("rsmm.aggro")({ R = R, I = I, named_event = NE,
    dispatcher_entity_off = function() return off_value end })

-- census: scene list plus every store reachable from it
local seen, cstats = aggro.census()
check(cstats.scene == 3 and cstats.stores == 3 and cstats.entities == 6,
      "census walks the scene list, both stores and the chained one (3 scene, 3 stores, 6 entities)")

-- find: filter by template path, case-insensitive; nearest the hero first
local rows = aggro.find("BOSS_")
check(#rows == 1 and rows[1].entity == BOSS, "find('BOSS_') reaches the boss on its spawner's store")
check(rows[1] and rows[1].hero_distance and math.abs(rows[1].hero_distance - 10) < 1e-6,
      "find reports hero distance")
local all = aggro.find(nil)
check(#all == 4 and all[1].entity == GRUNT and all[2].entity == CAMP_EN
      and all[3].entity == CAMP2_EN and all[4].entity == BOSS,
      "find(nil) lists scene, store and chained-store enemies, nearest first")

-- no hero: nothing to anchor the scene list, and the reason says so
hero_on = false
local none, nstats = aggro.find(nil)
check(#none == 0 and nstats.why and nstats.why:find("HERO_CAPTURE", 1, true),
      "find without a hero returns nothing and names hero capture")
hero_on = true

-- trace_store: from an enemy's +0x38 back to the component that embeds the store
mem[CAMP_EN + 0x38] = CAMP_CPNT + 0x68
mem[CAMP_CPNT + 0x08] = CAMP
local tr = aggro.trace_store(CAMP_EN)
check(tr.store == CAMP_CPNT + 0x68 and tr.store_class == "oCEntitySpawner",
      "trace_store reads the store at entity+0x38")
check(tr.container == CAMP_CPNT and tr.embed_off == 0x68 and tr.owner == CAMP
      and tr.owner_class_id == 111, "trace_store finds the embedding component, its owner and class id")
check(aggro.trace_store(0x5000000).store == nil, "trace_store refuses a non-entity")

-- crosscheck: an enemy on a store census reaches, then one it cannot
local xc = aggro.crosscheck(CAMP_EN)
check(xc.in_census and xc.store_in_census and xc.head_walk == 1 and xc.head_found,
      "crosscheck: a reached enemy and store, head walk finds it")
check(xc.chain[1] and xc.chain[1].dir == "next" and xc.chain[1].store == CAMP2_STORE
      and xc.chain[1].in_census, "crosscheck walks the store chain")
local LOST_STORE, LOST_EN = 0x4c00000, 0x4d00000
classes[LOST_EN] = "oCEntity"
store(LOST_STORE, LOST_EN)
mem[LOST_EN + 0x38] = LOST_STORE
local lost = aggro.crosscheck(LOST_EN)
check(lost.in_census == false and lost.store_in_census == false and lost.head_found,
      "crosscheck reports an unreached enemy and store")

-- dispatcher_of: the full guard chain
check(aggro.dispatcher_of(BOSS) == BOSS + OFF, "dispatcher_of = entity + learned offset")
check(select(1, aggro.dispatcher_of(0x5000000)) == nil, "dispatcher_of refuses a non-entity")
check(select(1, aggro.dispatcher_of(HERO_E)) == nil, "dispatcher_of refuses a non-enemy entity")
off_value = nil
local d, why = aggro.dispatcher_of(BOSS)
check(d == nil and why:find("not learned", 1, true), "dispatcher_of refuses until the offset is learned")
off_value = OFF
setd(BOSS, 1)
check(select(1, aggro.dispatcher_of(BOSS)) == nil, "dispatcher_of refuses a mid-dispatch dispatcher")
setd(BOSS, 0)
mem[BOSS + OFF + 0x28] = nil
check(select(1, aggro.dispatcher_of(BOSS)) == nil, "dispatcher_of refuses an unreadable channel map")
setd(BOSS, 0)

-- force: one event, to the boss's own dispatcher
check(aggro.force(BOSS) == true, "force succeeds on a valid boss")
local s = sent[#sent]
check(s and s.name == "REQUEST_BHV_DEFAULT_FIGHTING" and s.vtype == 2 and s.value == true
      and s.world == BOSS + OFF and s.feature == "R.aggro", "force sends the named event to the boss dispatcher")
local before = #sent
check(aggro.force(HERO_E) == false and #sent == before, "force sends nothing to a non-enemy")

print(string.format("aggro_spec: %d checks, %d failed", total, failed))
os.exit(failed == 0 and 0 or 1)
