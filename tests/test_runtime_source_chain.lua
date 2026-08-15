package.path = "../Scripts/?.lua;" .. package.path

local source_chain_module = require("runtime_source_chain")

local function equal(actual, expected, message)
    assert(actual == expected, string.format(
        "%s (expected=%s actual=%s)", message, tostring(expected), tostring(actual)))
end

local registered_hooks = {}
local registered_events = {}
local deferred = {}
local traces = {}
local action_records = {}
local attack_hook_count = 0

local function object(name, address)
    return {
        __name = name,
        __address = address,
        GetAddress = function(self) return self.__address end,
        GetFullName = function(self) return self.__name end,
    }
end

local pal = object("BP_Pal_C TestPal", 100)
pal.ActionComponent = object("PalActionComponent ActionComponent", 101)
local defender = object("BP_Enemy_C Target", 200)
local action = object("BP_Action_C Action", 300)
local effect = object("BP_SkillEffect_C Effect", 400)
local filter = object("PalAttackFilter Filter", 500)
local damage_info = object("FPalDamageInfo DamageInfo", 600)
local on_attack_function = object(
    "Function /Game/Test/BP_SkillEffect.BP_SkillEffect_C:"
        .. "BndEvt__AttackFilter_OnAttackDelegate__DelegateSignature", 700)
local effect_class = object("BlueprintGeneratedClass /Game/Test/BP_SkillEffect", 800)

function effect:GetOwner() return pal end
function effect:GetClass() return effect_class end
effect.AttackFilter = filter
filter.Waza = 602
function filter:GetOuter() return effect end
function effect_class:ForEachFunction(callback)
    callback(on_attack_function)
end
damage_info.Attacker = pal

local function unwrap(value) return value end
local function valid(value) return type(value) == "table" end
local function identity(value)
    if value == nil then return nil end
    return "addr:" .. tostring(value.__address or tostring(value))
end
local function actor_key(value)
    return value and tostring(value.__address) or nil
end

local chain = source_chain_module.new({
    enabled = function() return true end,
    safe_call = function(target, method, ...)
        local fn = target and target[method]
        if type(fn) ~= "function" then return false, nil end
        local ok, result = pcall(fn, target, ...)
        return ok, result
    end,
    safe_property = function(target, name)
        if target == nil then return false, nil end
        return true, target[name]
    end,
    is_valid = valid,
    unwrap = unwrap,
    to_number = function(value) return tonumber(value) or 0 end,
    text_value = function(value) return tostring(value or "") end,
    canonical = function(value) return tostring(value or "") end,
    resolve_waza = function(waza_id)
        if tonumber(waza_id) == 602 then return { code = "DiamondFall" } end
        return { code = "UNKNOWN" }
    end,
    resolve_effect_asset = function() return nil end,
    object_info = function(value) return { full_name = value.__name } end,
    object_identity = identity,
    value_identity = identity,
    actor_key = actor_key,
    full_name = function(value) return value.__name end,
    clock = function() return 2.0 end,
    action_records = function() return action_records end,
    register_hook = function(path, pre, post)
        registered_hooks[path] = { pre = pre, post = post }
        return 1, post and 2 or nil
    end,
    register_custom_event = function(name, callback)
        registered_events[name] = callback
    end,
    trace = function(message) traces[#traces + 1] = message end,
    on_error = function(label, err) error(label .. ": " .. tostring(err)) end,
    on_attack_hook_registered = function() attack_hook_count = attack_hook_count + 1 end,
    defer = function(callback) deferred[#deferred + 1] = callback end,
})

local action_record = {
    key = "action:300",
    actor_key = actor_key(pal),
    code = "DiamondFall",
    ended_at = nil,
}
action_records[action_record.key] = action_record
action_record.cast_id = chain:on_cast_begin(action_record, 1.0)
assert(action_record.cast_id ~= nil, "cast id was not created")

local effect_hook_ok = chain:register_effect_hook()
assert(effect_hook_ok == true, "effect initialize hook registration failed")
local initialize = registered_hooks["/Script/Pal.PalSkillEffectBase:OnInitialize"]
assert(initialize ~= nil and type(initialize.post) == "function",
    "effect initialize post hook was not installed")
local filter_hook_ok = chain:register_filter_hook()
assert(filter_hook_ok == true, "attack filter hook registration failed")
assert(registered_hooks["/Script/Pal.PalAttackFilter:BindPrimitiveComponent"] ~= nil,
    "attack filter hook was not installed")
initialize.post(effect)

local attack_event = "BndEvt__AttackFilter_OnAttackDelegate__DelegateSignature"
local attack_hook = registered_events[attack_event]
assert(attack_hook ~= nil, "Blueprint OnAttack custom event was not registered")
equal(attack_hook_count, 1, "OnAttack hook registration count")

attack_hook(effect, defender, damage_info, 1, nil)
local hit = chain:consume_hit(object("DifferentAttackerWrapper", 999), defender,
    identity(damage_info))
assert(hit ~= nil, "nested final damage was not linked to the effect")
equal(hit.code, "DiamondFall", "effect Waza code")
equal(hit.cast_id, action_record.cast_id, "effect cast link")
equal(hit.effect_id, identity(effect), "effect identity")

-- A consumed pending attack must not be reused by another final hit.
equal(chain:consume_hit(pal, defender, identity(damage_info)), nil,
    "effect attack token was reused")

-- If no final hit happens inside the Blueprint callback, the game-thread
-- cleanup closes the temporary token instead of leaking it to a later skill.
attack_hook(effect, defender, damage_info, 1, nil)
assert(#deferred > 0, "OnAttack cleanup was not scheduled")
deferred[#deferred]()
equal(chain:consume_hit(pal, defender, identity(damage_info)), nil,
    "expired effect attack leaked into a later hit")

chain:reset()
equal(chain:consume_hit(pal, defender, identity(damage_info)), nil,
    "reset retained a pending effect attack")

-- Some cooked effects expose a differently named filter component. The
-- BindPrimitiveComponent hook passes the real Filter object directly and must
-- still recover its Waza without relying on effect.AttackFilter.
effect.AttackFilter = nil
registered_hooks["/Script/Pal.PalAttackFilter:BindPrimitiveComponent"].pre(filter)
attack_hook(effect, defender, damage_info, 1, nil)
local direct_filter_hit = chain:consume_hit(pal, defender, identity(damage_info))
assert(direct_filter_hit ~= nil, "direct AttackFilter binding was not captured")
equal(direct_filter_hit.code, "DiamondFall", "direct AttackFilter Waza")
effect.AttackFilter = filter

-- Live hooks can observe effect initialization synchronously before the queued
-- action-begin event is drained. The captured timestamps must retro-link that
-- effect to the correct cast without using a wall-clock guessing window.
action_records = {}
initialize.post(effect)
local late_action = {
    key = "action:301",
    actor_key = actor_key(pal),
    code = "DiamondFall",
    ended_at = nil,
}
action_records[late_action.key] = late_action
late_action.cast_id = chain:on_cast_begin(late_action, 1.5)
attack_hook(effect, defender, damage_info, 1, nil)
local retro_hit = chain:consume_hit(pal, defender, identity(damage_info))
assert(retro_hit ~= nil, "pre-drain effect was not captured")
equal(retro_hit.cast_id, late_action.cast_id, "pre-drain effect retro-link")

print("runtime source-chain hook regression tests passed")
