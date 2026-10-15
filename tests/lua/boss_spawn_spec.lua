-- Unit tests for src/loader/lua/rsmm/boss_spawn.lua against a mocked SDK.
-- Run with plain lua 5.4:  lua tests/lua/boss_spawn_spec.lua src/loader/lib
-- (the same argument as rsmm_spec.lua; submodules are found at <lib>/../lua).
--
-- Models only what the module reads: an entity's component map, a selector
-- component holding a template vector, the named-event builder, and the
-- scheduler. It proves the module's own logic (what it refuses, what order it
-- sends, which pointers it hands the builder) — NOT that the game accepts any of
-- it. Exits nonzero on the first failed assertion.

local LIB = (arg and arg[1]) or "src/loader/lib"
package.path = LIB .. "/../lua/?.lua;" .. package.path

local mem, logs = {}, {}
local function w64(a, v) mem[a] = v end

local ENT, SEL, SM, LST, SPN = 0x1000000, 0x1100000, 0x1200000, 0x1300000, 0x1400000
local VEC, ENTRY, RES = 0x1500000, 0x1600000, 0x1700000
local OFF = 0x4d8
local CLS = { state_machine = 277897763, listener = 278935830,
              spawner = 267629480, selector = 381059020 }

local rtti = { [ENT] = "oCEntity", [RES] = "oCEntitySettingsResource" }
local comps = { [CLS.state_machine] = SM, [CLS.listener] = LST,
                [CLS.spawner] = SPN, [CLS.selector] = SEL }
local handlers = {}
local sent, near_calls = {}, {}
local learned, in_scene, tname = OFF, true, nil

local R = {
    log = function(m) logs[#logs + 1] = m end,
    on = function(ev, cb) handlers[ev] = cb end,
    ptr = { plausible = function(p) return type(p) == "number" and p >= 0x10000 and p % 8 == 0 end,
            has_vtable = function(p) return rtti[p] ~= nil end },
    rtti = { name = function(p) return rtti[p] end },
    net = { component = function(e, id) if e == ENT then return comps[id] end end },
    spawn = {
        entities = function() return in_scene and { { entity = ENT, template = 0 } } or {} end,
        position_of = function() return 1.0, 2.0, 3.0 end,
        name_of = function() return tname end,
        near = function(t, o) near_calls[#near_calls + 1] = { t = t, o = o }; return true end,
    },
    engine = { resolve = function() return 1 end },
    entity = { hero = function() return 0x2000000 end },
    schedule = { next_main = function(f) f() end, after_main = function(_, f) f() end },
}
local I = { read_u64 = function(a) return mem[a] end,
            read_u32 = function(a) return mem[a] end }
local NE = {
    T_BOOL = 2,
    send_value = function(feature, name, vt, val, disp)
        sent[#sent + 1] = { feature = feature, name = name, vt = vt, val = val, disp = disp }
        return true
    end,
}

-- selector: one-entry vector at +0x68 (the flag-list subclass's layout), whose
-- entry carries the resolved template at +0x18.
w64(SEL + 0x68, VEC); mem[SEL + 0x70] = 1
w64(VEC, ENTRY); w64(ENTRY + 0x18, RES)

local mod = dofile(LIB .. "/../lua/rsmm/boss_spawn.lua")
local B = mod({ R = R, I = I, named_event = NE, dispatcher_entity_off = function() return learned end })

local function check(cond, msg)
    if not cond then io.stderr:write("FAIL: " .. msg .. "\n"); os.exit(1) end
end

-- 1. the finder takes the scene-list spawner and names its dispatcher
local list = B.candidates()
check(#list == 1 and list[1].entity == ENT, "scene-list spawner found")

-- 2. awaken "full" sends the five events in order, all to entity + learned offset
check(B.awaken({ sequence = "full", delay = 0 }), "awaken(full) accepted")
local want = { "AWAKENING_START", "AWAKENING_BLACKOUT_START", "AWAKENING_BOSS_SPAWN",
               "AWAKENING_FENCE_UP", "AWAKENING_CINE_END" }
check(#sent == 5, "five events sent, got " .. #sent)
for i, n in ipairs(want) do
    check(sent[i].name == n, "step " .. i .. " is " .. n)
    check(sent[i].disp == ENT + OFF, "step " .. i .. " goes to the spawner's dispatcher")
    check(sent[i].vt == NE.T_BOOL and sent[i].val == true, "bool true carrier")
end

-- 3. default sequence is the single spawn step
sent = {}
check(B.awaken(), "awaken() default accepted")
check(#sent == 1 and sent[1].name == "AWAKENING_BOSS_SPAWN", "default sends AWAKENING_BOSS_SPAWN only")

-- 4. refuses while the dispatcher offset is unlearned, sending nothing
sent, learned = {}, nil
local ok = B.awaken()
check(ok == false and #sent == 0, "refuses with no learned dispatcher offset")
learned = OFF

-- 5. refuses an unknown sequence and a missing spawner
check(B.awaken({ sequence = "nope" }) == false, "unknown sequence refused")
in_scene = false
local fresh = mod({ R = R, I = I, named_event = NE, dispatcher_entity_off = function() return learned end })
check(fresh.awaken() == false and #sent == 0, "no spawner -> refuses")
in_scene = true

-- 6. a half-built entity (missing the selector) is not a spawner
comps[CLS.selector] = nil
check(#fresh.candidates() == 0, "missing selector component -> not a spawner")
comps[CLS.selector] = SEL

-- 7. template route: refuses an unnamed template, accepts it with trust
tname = nil
check(B.spawn_from_selector() == false and #near_calls == 0, "unnamed template refused")
check(B.spawn_from_selector({ trust = true }), "trust=true accepted")
check(#near_calls == 1 and near_calls[1].t == RES, "R.spawn.near gets the selector's template")
tname = "Enemies\\Tentacle_Nightmares\\Boss_Tentacle_Master_Nightmare"
near_calls = {}
check(B.spawn_from_selector(), "a Boss-named template needs no trust")
check(#near_calls == 1, "one spawn queued")

-- 8. probe returns the same finding without sending anything
sent = {}
local rep = B.probe()
check(#rep.candidates == 1 and #rep.candidates[1].vectors == 1, "probe reports the vector")
check(#sent == 0, "probe sent nothing")

print("boss_spawn_spec: ok")
