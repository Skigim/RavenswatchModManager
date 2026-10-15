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

local off_value = OFF
local R = {
    log = function(m) logs[#logs + 1] = m end,
    ptr = { plausible = function(p) return type(p) == "number" and p >= 0x10000 and p % 8 == 0 end,
            has_vtable = function(p) return classes[p] ~= nil end },
    rtti = { name = function(p) return classes[p] end },
    entity = { hero = function() return HERO_E end },
    spawn = {
        entities = function() return { { entity = GRUNT, template = 0xa0 }, { entity = BOSS, template = 0xb0 } } end,
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

-- find: filter by template path, case-insensitive; nearest the hero first
local rows = aggro.find("BOSS_")
check(#rows == 1 and rows[1].entity == BOSS, "find('BOSS_') returns only the boss")
check(rows[1].hero_distance and math.abs(rows[1].hero_distance - 10) < 1e-6, "find reports hero distance")
local all = aggro.find(nil)
check(#all == 2 and all[1].entity == GRUNT, "find(nil) lists every enemy, nearest first")

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
