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
local clock_now = 2.0

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
filter.OnAttackDelegate = {GetBindings=function()
    return {{Object=effect, FunctionName='BndEvt__AttackFilter_OnAttackDelegate__DelegateSignature'}}
end}
function filter:GetOuter() return effect end
function effect_class:ForEachFunction(callback)
    error('broken native iterator must not be called')
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
        if tonumber(waza_id) == 602 then return { code = "DiamondFall", attack_element=6, game_power=600 } end
        if tonumber(waza_id) == 183 then return {code='BubbleShower',attack_element=8, game_power=400} end
        if tonumber(waza_id) == 205 then return {code='Unique_BlackCentaur_TwoSpearRushes',attack_element=8,game_power=700} end
        return { code = "UNKNOWN" }
    end,
    resolve_effect_asset = function() return nil end,
    object_info = function(value) return { full_name = value.__name } end,
    object_identity = identity,
    value_identity = identity,
    actor_key = actor_key,
    full_name = function(value) return value.__name end,
    clock = function() return clock_now end,
    action_records = function() return action_records end,
    register_hook = function(path, pre, post)
        assert(path ~= "/Script/Pal.PalAttackFilter:BindPrimitiveComponent",
            "inherited UFunction must be hooked on its declaring PalHitFilter class")
        -- UE4SS /Game Blueprint events use arg2 as their post-event callback;
        -- arg3 is ignored for this non-native function family.
        local blueprint_post = string.sub(path, 1, 6) == "/Game/" and pre or nil
        registered_hooks[path] = { pre = pre, post = post, blueprint_post = blueprint_post }
        return 1, (post or blueprint_post) and 2 or nil
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
assert(registered_hooks["/Script/Pal.PalHitFilter:BindPrimitiveComponent"] ~= nil,
    "attack filter hook was not installed")
registered_hooks["/Script/Pal.PalHitFilter:BindPrimitiveComponent"].pre(
    object("PalHitFilter NonAttackFilter", 501))
assert(next(chain.effect_records) == nil,
    "base-class filter hook must ignore filters without Waza")
initialize.post(effect)

local attack_event = "BndEvt__AttackFilter_OnAttackDelegate__DelegateSignature"
local attack_hook = registered_events[attack_event]
assert(attack_hook ~= nil, "Blueprint OnAttack custom event was not registered")
equal(attack_hook_count, 1, "OnAttack hook registration count")

attack_hook(effect, defender, damage_info, 1, nil)
equal(chain:consume_hit(object("DifferentAttackerWrapper", 999), defender,
    identity(damage_info),6), nil, "another attacker stole a source token")
local hit = chain:consume_hit(pal, defender, identity(damage_info),6)
assert(hit.confidence=='inferred', 'pending token falsely promoted to exact')
assert(hit ~= nil, "nested final damage was not linked to the effect")
equal(hit.code, "DiamondFall", "effect Waza code")
equal(hit.cast_id, action_record.cast_id, "effect cast link")
equal(hit.effect_id, identity(effect), "effect identity")

-- A consumed pending attack must not be reused by another final hit.
equal(chain:consume_hit(pal, defender, identity(damage_info),6), nil,
    "effect attack token was reused")

-- A queued cleanup may run before final damage: retain short-lived copied
-- evidence, requiring power as well as actor/target/element after that point.
attack_hook(effect, defender, damage_info, 1, nil)
assert(#deferred > 0, "OnAttack cleanup was not scheduled")
deferred[#deferred]()
equal(chain:consume_hit(pal, defender, identity(damage_info),6), nil,
    "delayed effect accepted missing power")
assert(not chain:consume_hit(pal,defender,nil,6,400), 'delayed effect accepted wrong power')
clock_now=clock_now+0.004
local delayed_effect=chain:consume_hit(pal,defender,nil,6,600)
assert(delayed_effect and delayed_effect.source=='inferred_effect_candidate_delayed')
assert(not chain:consume_hit(pal,defender,nil,6,600), 'delayed effect consumed twice')
attack_hook(effect,defender,damage_info,1,nil)
deferred[#deferred]()
clock_now=clock_now+0.076
assert(not chain:consume_hit(pal,defender,nil,6,600), 'expired effect reused')

chain:reset()
equal(chain:consume_hit(pal, defender, identity(damage_info),6), nil,
    "reset retained a pending effect attack")

-- Some cooked effects expose a differently named filter component. The
-- BindPrimitiveComponent hook passes the real Filter object directly and must
-- still recover its Waza without relying on effect.AttackFilter.
effect.AttackFilter = nil
registered_hooks["/Script/Pal.PalHitFilter:BindPrimitiveComponent"].pre(filter)
attack_hook(effect, defender, damage_info, 1, nil)
local direct_filter_hit = chain:consume_hit(pal, defender, identity(damage_info),6)
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
local retro_hit = chain:consume_hit(pal, defender, identity(damage_info),6)
assert(retro_hit ~= nil, "pre-drain effect was not captured")
equal(retro_hit.cast_id, late_action.cast_id, "pre-drain effect retro-link")

chain:reset()
initialize.post(effect)
attack_hook(effect, defender, damage_info, 1, nil)
local second_info = object("FPalDamageInfo Second", 601)
second_info.Attacker = pal
attack_hook(effect, defender, second_info, 1, nil)
local grouped = chain:consume_hit(pal, defender, nil,6)
assert(grouped and grouped.code=='DiamondFall' and grouped.confidence=='inferred',
    'same-effect callbacks were mistaken for competing sources')
equal(#chain.pending_attacks,0,'duplicate callback remained available for next hit')
assert(not chain:consume_hit(pal, defender, identity(second_info),6), "address broke same-element ambiguity")
assert(not chain:consume_hit(pal, defender, identity(damage_info),6), "address promoted ambiguous token")
print("runtime source-chain hook regression tests passed")

-- Probe missing, fractional, zero and malformed component rates without
-- inventing a default or changing hit attribution. No per-skill rate table.
for _, case in ipairs({{0.05,'0.05'}, {0,'0'}, {-1,'nil'}, {'bad','nil'}}) do
    filter.WazaPowerRate=case[1]
    chain:process_effect(effect)
    local observed=false
    for index=#traces,1,-1 do
        if traces[index]:find('effect-stage-probe ',1,true) then
            assert(traces[index]:find('rate=' .. case[2] .. ' ',1,true))
            assert(traces[index]:find('completeness=unverified',1,true))
            observed=true
            break
        end
    end
    assert(observed,'stage probe missing')
end
filter.WazaPowerRate=nil
chain:process_effect(effect)
assert(chain.effect_records[identity(effect)].code=='DiamondFall', 'probe changed source identity')
print('effect component stage-rate probe tests passed')

chain:reset()
attack_hook(effect, defender, damage_info, 1, nil)
assert(#chain.pending_attacks==0, 'reset retained event-context permission')
initialize.post(effect)
attack_hook(object('OtherEffect', 900), defender, damage_info, 1, nil)
assert(#chain.pending_attacks==0, 'same event name from unbound object was accepted')
attack_hook(effect, defender, damage_info, 1, nil)
assert(chain:consume_hit(pal,defender,identity(damage_info),6), 'bound effect was not accepted')

chain:reset()
local original_bindings=filter.OnAttackDelegate.GetBindings
filter.OnAttackDelegate.GetBindings=function() return {} end
initialize.post(effect)
assert(not chain.bound_attack_contexts[attack_event], 'empty delegate manufactured binding')
local binding_retry=deferred[#deferred]
filter.OnAttackDelegate.GetBindings=original_bindings
binding_retry()
assert(chain.bound_attack_contexts[attack_event][identity(effect)], 'late binding retry failed')
equal(attack_hook_count,1,'shared hook registered twice')

chain:reset()
filter.OnAttackDelegate.GetBindings=function() error('API unavailable') end
initialize.post(effect)
deferred[#deferred]()
assert(next(chain.bound_attack_contexts)==nil, 'unavailable API enabled guessing')
filter.OnAttackDelegate.GetBindings=original_bindings
print('delegate binding identity/reset/late-bind/unavailable tests passed')

-- Live regression: poison and ice callbacks reused the same DamageInfo address.
chain:reset()
local poison = object('PoisonEffect', 901)
poison.AttackFilter=object('PoisonFilter',902)
poison.AttackFilter.Waza=183
function poison:GetOwner() return pal end
chain:process_effect(poison)
chain:capture_attack(poison,defender,damage_info,1)
chain:process_effect(effect)
chain:capture_attack(effect,defender,damage_info,1)
local ice_candidate=chain:consume_hit(pal,defender,identity(damage_info),6)
assert(ice_candidate and ice_candidate.code=='DiamondFall', '969 ice damage selected poison')
assert(ice_candidate.confidence=='inferred', 'reused address falsely proved exact hit')
assert(not chain:consume_hit(pal,defender,identity(damage_info),6), 'remaining poison accepted ice hit')
assert(not chain:consume_hit(pal,defender,identity(damage_info)), 'missing element accepted source')
assert(chain:consume_hit(pal,defender,nil,8).confidence=='inferred', 'compatible candidate mislabeled exact')
print('reused-address cross-element 969-damage source regression passed')

-- Different effects with no common known cast remain competing even with
-- the same element, address, skill or attacker.
chain:reset()
chain:process_effect(effect)
local other_effect=object('SecondIceEffect',950)
other_effect.AttackFilter=filter
function other_effect:GetOwner() return pal end
chain:process_effect(other_effect)
chain:capture_attack(effect,defender,damage_info,1)
chain:capture_attack(effect,defender,damage_info,1)
chain:capture_attack(other_effect,defender,damage_info,1)
for _, entry in ipairs(chain.pending_attacks) do entry.cast_id=nil end
assert(not chain:consume_hit(pal,defender,identity(damage_info),6),
    'duplicate grouping hid competing effect')
equal(#chain.pending_attacks,0,'ambiguous evidence leaked into subsequent damage')
chain:reset()
chain:process_effect(effect)
chain:capture_attack(effect,defender,damage_info,1)
chain:capture_attack(effect,defender,damage_info,1)
chain.pending_attacks[2].waza_id=999
chain.pending_attacks[2].code='OtherSameElementSkill'
assert(not chain:consume_hit(pal,defender,nil,6),'different skills were merged')
chain:reset()
chain:process_effect(effect)
chain:capture_attack(effect,defender,damage_info,1)
chain:capture_attack(effect,defender,damage_info,1)
for _, callback in ipairs(deferred) do callback() end
assert(not chain:consume_hit(pal,defender,nil,6),'expired callback group survived')
print('same-effect duplicate grouping/competing-source/expiry tests passed')

-- Apocalypse creates multiple projectile instances per cast. Their shared
-- cast/skill is usable at skill level without claiming a precise projectile.
chain:reset()
chain:process_effect(effect)
chain:process_effect(other_effect)
chain:capture_attack(effect,defender,damage_info,1)
chain:capture_attack(other_effect,defender,damage_info,1)
for _, entry in ipairs(chain.pending_attacks) do entry.cast_id='verified-cast:1' end
local multi=chain:consume_hit(pal,defender,nil,6,600)
assert(multi and multi.code=='DiamondFall' and multi.confidence=='inferred')
equal(#chain.pending_attacks,1,'first hit consumed another projectile')
local second_projectile=chain:consume_hit(pal,defender,nil,6,600)
assert(second_projectile and second_projectile.code=='DiamondFall')
equal(#chain.pending_attacks,0,'second projectile was not consumed')
assert(not chain:consume_hit(pal,defender,nil,6,600),'two projectiles invented a third hit')
chain:capture_attack(effect,defender,damage_info,1)
chain:capture_attack(other_effect,defender,damage_info,1)
chain.pending_attacks[1].cast_id='cast:1'
chain.pending_attacks[2].cast_id='cast:2'
assert(not chain:consume_hit(pal,defender,nil,6,600),'different casts silently merged')
chain:reset()
chain:process_effect(effect)
chain:capture_attack(effect,defender,damage_info,1)
clock_now=clock_now+0.076
assert(not chain:consume_hit(pal,defender,nil,6,600),'expiry relied on deferred callback running')
print('effect delayed-damage/power/one-use/expiry/shared-cast-projectile tests passed')

chain:register_filter_hook()
local dispatch = registered_hooks['/Script/Pal.PalAttackFilter:CallBackOnAttackDelegate']
assert(dispatch and dispatch.pre, 'filter dispatch observation not registered')
local pending_before = #chain.pending_attacks
dispatch.pre(filter)
assert(traces[#traces]:find('filter-dispatch-probe filter=',1,true))
assert(traces[#traces]:find(' id=602 ',1,true))
equal(#chain.pending_attacks,pending_before,'observation invented damage evidence')
print('native filter dispatch observation test passed')

chain:reset()
local collision=registered_hooks['/Script/Pal.PalAnimNotifyState_AttackCollision:OnHit']
assert(collision and collision.pre and collision.post, 'collision scope hooks missing')
local notify=object('AnimationNotify',980)
notify.AttackFilter=filter
local shape=object('LanceCollision',981)
function shape:GetOwner() return pal end
collision.pre(notify,shape,defender)
local collision_hit=chain:consume_hit(pal,defender,nil,6)
assert(collision_hit and collision_hit.code=='DiamondFall')
equal(collision_hit.source,'inferred_animation_collision','collision source label')
equal(collision_hit.confidence,'inferred','unverified runtime scope claimed exact')
assert(not chain:consume_hit(pal,defender,nil,8),'collision element conflict accepted')
assert(not chain:consume_hit(defender,pal,nil,6),'collision actors reversed')
collision.pre({},shape,defender)
assert(not chain:consume_hit(pal,defender,nil,6),'invalid nested scope borrowed parent')
collision.post()
assert(chain:consume_hit(pal,defender,nil,6),'nested return lost parent scope')
collision.post()
assert(not chain:consume_hit(pal,defender,nil,6),'collision leaked after callback return')
equal(#chain.pending_attacks,0,'collision created delayed guess token')
collision.pre(notify,shape,defender)
chain:reset()
collision.post()
assert(not chain:consume_hit(pal,defender,nil,6),'reset retained collision evidence')
print('animation collision scope/element/actor/nesting/cleanup tests passed')

-- A final-damage callback after OnHit returns was completely missed by v10.
chain:reset()
filter.Waza=205
collision.pre(notify,shape,defender)
collision.post()
clock_now=clock_now+0.008
assert(not chain:consume_hit(pal,defender,nil,6,700), 'cross-element delayed collision')
assert(not chain:consume_hit(pal,defender,nil,8,400), 'different power borrowed collision')
assert(not chain:consume_hit(defender,pal,nil,8,700), 'reversed actor delayed collision')
local delayed_hit=chain:consume_hit(pal,defender,nil,8,700)
assert(delayed_hit and delayed_hit.code=='Unique_BlackCentaur_TwoSpearRushes')
equal(delayed_hit.source,'inferred_animation_collision_delayed','delayed evidence route')
equal(delayed_hit.confidence,'inferred','delayed evidence claimed exact')
assert(not chain:consume_hit(pal,defender,nil,8,700), 'single collision counted twice')
for i=1,2 do collision.pre(notify,shape,defender); collision.post() end
assert(chain:consume_hit(pal,defender,nil,8,700), 'duplicate notify group rejected')
assert(not chain:consume_hit(pal,defender,nil,8,700), 'duplicate notify leaked to next hit')
collision.pre(notify,shape,defender); collision.post()
clock_now=clock_now+0.076
assert(not chain:consume_hit(pal,defender,nil,8,700), 'stale collision borrowed by next action')
collision.pre(notify,shape,defender); collision.post()
chain.pending_attacks={{attacker_key=identity(pal),defender_key=identity(defender),skill_element=8,code='Apocalypse'}}
assert(not chain:consume_hit(pal,defender,nil,8,700), 'competing same-element effect ignored')
equal(#chain.pending_collisions,0,'ambiguous collision retained')
chain:reset()
collision.pre(notify,shape,defender); collision.post()
chain:reset()
assert(not chain:consume_hit(pal,defender,nil,8,700), 'reset retained delayed collision')
filter.Waza=602
print('delayed animation collision/element/power/actors/duplicates/expiry/competition/reset tests passed')

chain:reset()
local absent, audit=chain:consume_hit(pal,defender,nil,6,600)
assert(not absent and audit.reason=='no_pending')
chain:process_effect(effect)
chain:capture_attack(effect,defender,damage_info,1)
deferred[#deferred]()
local _, actor_audit=chain:consume_hit(defender,pal,nil,6,600)
equal(actor_audit.reason,'actors_mismatch','actor rejection audit')
local _, element_audit=chain:consume_hit(pal,defender,nil,8,600)
equal(element_audit.reason,'element_mismatch','element rejection audit')
local _, power_audit=chain:consume_hit(pal,defender,nil,6,400)
equal(power_audit.reason,'power_mismatch','power rejection audit')
clock_now=clock_now+0.076
local _, expiry_audit=chain:consume_hit(pal,defender,nil,6,600)
equal(expiry_audit.reason,'expired','expiry rejection audit')
equal(expiry_audit.expired,1,'expired same-actor evidence count')
equal(power_audit.reason,'power_mismatch','later audit mutated prior hit')
chain:capture_attack(effect,defender,damage_info,1)
local matched, match_audit=chain:consume_hit(pal,defender,nil,6,600)
assert(matched and match_audit.reason=='effect_pending')
print('per-hit immutable source-link rejection audit tests passed')

-- Reflection/log collection latency must not turn a timely hit into an expiry.
chain:reset()
chain:process_effect(effect)
chain:capture_attack(effect,defender,damage_info,1)
deferred[#deferred]()
local arrival=clock_now+0.010
clock_now=clock_now+0.250
local timely, timing=chain:consume_hit(pal,defender,nil,6,600,arrival)
assert(timely and timely.code=='DiamondFall','diagnostic latency expired valid effect')
assert(timing.processing_ms>=239 and timing.age_ms<=11)
assert(not chain:consume_hit(pal,defender,nil,6,600,arrival),'arrival-time hit reused token')
chain:capture_attack(effect,defender,damage_info,1)
local late=clock_now+0.080
clock_now=clock_now+0.250
assert(not chain:consume_hit(pal,defender,nil,6,600,late),'actual late hit accepted')
filter.Waza=205
collision.pre(notify,shape,defender); collision.post()
arrival=clock_now+0.010
clock_now=clock_now+0.250
assert(not chain:consume_hit(pal,defender,nil,6,700,arrival),'arrival clock bypassed element')
assert(not chain:consume_hit(pal,defender,nil,8,400,arrival),'arrival clock bypassed power')
assert(chain:consume_hit(pal,defender,nil,8,700,arrival),'diagnostic latency expired collision')
print('callback-arrival timing/effect/collision/expiry/one-use regressions passed')

-- Native pre/post identity is available during the final hit, before Lua's
-- Blueprint OnAttack post event. It does not require a prior pending token.
chain:reset()
local native_status = 'matched'
local native_waza = 602
chain.deps.native_source = function(attacker, target)
    assert(attacker == pal and target == defender)
    return native_status, native_waza, 400, 500, 123
end
local direct, direct_audit = chain:consume_hit(pal, defender, nil, 6, 600)
assert(direct and direct.code == 'DiamondFall' and direct.confidence == 'exact')
equal(direct_audit.reason, 'native_call_scope', 'native source read during call')
equal(direct.token, 123, 'source call sequence')
assert(not chain:consume_hit(pal, defender, nil, 8, 600), 'native source bypassed element conflict')
-- A stage may use a different power from the skill total. Actual source
-- identity must not be discarded or guessed using the total power.
assert(chain:consume_hit(pal, defender, nil, 6, 42), 'native identity rejected stage power')
chain:process_effect(effect)
chain:capture_attack(effect, defender, damage_info, 1)
native_status = 'no_scope'
local late_source, late_audit = chain:consume_hit(pal, defender, nil, 6, 600)
assert(not late_source, 'late Blueprint post callback labeled the next hit')
equal(late_audit.reason, 'native_no_scope', 'native scope ended')
native_status = 'rejected_scope'
assert(not chain:consume_hit(pal, defender, nil, 6, 600), 'nested source borrowed old evidence')
native_status = 'unavailable'
assert(not chain:consume_hit(pal, defender, nil, 6, 600), 'failed native bridge used stale source')
native_status, native_waza = 'matched', 183
equal(chain:consume_hit(pal, defender, nil, 8, 400).code, 'BubbleShower',
    'different runtime skill uses same bridge without a special case')
print('synchronous native source / post callback ordering / nested barrier / element regressions passed')

-- The recovered native frame is exact even when its filter has no owning
-- SkillEffect. A zero effect address must remain absent from the result.
chain:reset()
local native_kind = 'native_attack_filter_frame'
native_waza = 602
chain.deps.native_source = function(attacker, target)
    assert(attacker == pal and target == defender)
    return 'matched', native_waza, 0, 500, 321, native_kind
end
local filter_only, filter_only_audit = chain:consume_hit(pal, defender, nil, 6, 1)
assert(filter_only and filter_only.effect_id == nil,
    'native filter frame manufactured an effect identity')
equal(filter_only.attack_filter_id, identity(filter), 'native filter identity')
equal(filter_only.source, native_kind, 'native filter source kind')
equal(filter_only_audit.reason, native_kind, 'native filter audit source kind')
equal(filter_only.token, 321, 'native filter sequence')
assert(not chain:consume_hit(pal, defender, nil, 8, 999),
    'native filter frame accepted wrong element')
native_waza = 183
local different_waza = chain:consume_hit(pal, defender, nil, 8, 1)
assert(different_waza and different_waza.waza_id == 183
    and different_waza.code == 'BubbleShower'
    and different_waza.effect_id == nil,
    'native filter frame did not use actual Waza identity')
native_waza = 602
chain.deps.native_source = function() return 'matched', 602, 0, 0, 322, native_kind end
local _, zero_filter_audit = chain:consume_hit(pal, defender, nil, 6, 1)
equal(zero_filter_audit.reason, 'native_metadata_missing',
    'zero native filter was accepted')
chain.deps.native_source = function() return 'matched', 602, 0, 500, 323, native_kind end
assert(chain:consume_hit(pal, defender, nil, 6, 999),
    'stage power rejected exact native filter source')
chain.deps.native_source = function() return 'no_scope' end
chain:process_effect(effect)
chain:capture_attack(effect, defender, damage_info, 1)
local no_scope_hit, no_scope_audit = chain:consume_hit(pal, defender, nil, 6, 600)
assert(not no_scope_hit and no_scope_audit.reason == 'native_no_scope',
    'native no_scope reused a late callback')
print('native filter-only/zero-filter/element/Waza/stage-power/no-scope regressions passed')
chain:reset()
chain.deps.has_native_bridge = function() return true end
chain:process_effect(effect)
chain:capture_attack(effect, defender, damage_info, 1)
equal(#chain.pending_attacks, 0, 'bridge mode must not collect late effect hints')
print('native bridge avoids unused Blueprint post callbacks passed')

-- The synchronous Blueprint rock owns a CommetRain filter even when its
-- final child damage uses Commet power. Use source identity, not hit power.
chain:reset()
local prior_resolve = chain.deps.resolve_waza
chain.deps.resolve_waza = function(id)
    if id == 177 then return {code='CommetRain', attack_element=9, game_power=700} end
    return prior_resolve(id)
end
chain.deps.native_source = function(attacker, target)
    assert(attacker == pal and target == defender)
    return 'matched',177,400,500,401,'native_blueprint_effect_frame'
end
local meteor, meteor_audit = chain:consume_hit(pal,defender,nil,9,180)
assert(meteor and meteor.code == 'CommetRain' and meteor.confidence == 'exact')
equal(meteor.source,'native_blueprint_effect_frame','Blueprint source provenance')
equal(meteor_audit.reason,'native_blueprint_effect_frame','Blueprint source audit')
assert(meteor.effect_id and meteor.attack_filter_id)
assert(not chain:consume_hit(pal,defender,nil,8,180),'Blueprint source bypassed element')
chain.deps.native_source = function()
    return 'matched',177,0,500,402,'native_blueprint_effect_frame'
end
assert(not chain:consume_hit(pal,defender,nil,9,180),'Blueprint source accepted missing effect')
chain.deps.native_source = function() return 'rejected_scope' end
assert(not chain:consume_hit(pal,defender,nil,9,180),'rejected Blueprint borrowed preceding meteor')
chain.deps.resolve_waza = prior_resolve
print('Blueprint meteor parent identity / child power / element / missing object / no reuse passed')

-- Spawned meteor links identify the executing Commet Rock's parent Waza even
-- though its filter is absent from the final Ring. These are Lua contract
-- tests only; the mocks do not verify Unreal object parentage.
chain:reset()
chain.deps.resolve_waza = function(id)
    if id == 177 then return {code='CommetRain', attack_element=9, game_power=700} end
    if id == 9006 then return {code='ThreeCommet', attack_element=9, game_power=900} end
    return prior_resolve(id)
end
local spawned_source = {'matched', 177, 7101, 0, 901, 'native_spawned_meteor_frame'}
chain.deps.native_source = function()
    return spawned_source[1], spawned_source[2], spawned_source[3],
        spawned_source[4], spawned_source[5], spawned_source[6]
end
local spawned_rain = chain:consume_hit(pal, defender, nil, 9, 180)
assert(spawned_rain and spawned_rain.code == 'CommetRain'
    and spawned_rain.effect_id == 'addr:7101' and spawned_rain.attack_filter_id == nil
    and spawned_rain.source == 'native_spawned_meteor_frame'
    and spawned_rain.confidence == 'exact',
    'spawned meteor source did not accept effect-only identity without addr:0')
assert(spawned_rain.effect_id:find('addr:0', 1, true) == nil,
    'spawned meteor source fabricated a zero effect address')

spawned_source = {'matched', 9006, 7102, 0, 902, 'native_spawned_meteor_frame'}
local spawned_three = chain:consume_hit(pal, defender, nil, 9, 180)
spawned_source = {'matched', 177, 7103, 0, 903, 'native_spawned_meteor_frame'}
local spawned_rain_again = chain:consume_hit(pal, defender, nil, 9, 180)
assert(spawned_three and spawned_three.code == 'ThreeCommet' and spawned_three.waza_id == 9006
    and spawned_rain_again and spawned_rain_again.code == 'CommetRain' and spawned_rain_again.waza_id == 177,
    'same-element interleaved meteor hits did not follow each native Waza identity')

-- A missing spawned Ring, an element conflict, or a rejected/no-scope frame
-- cannot fall through to an older matching effect record.
chain.pending_attacks[1] = {
    token = 'older-commet-rain', attacker_key = actor_key(pal),
    defender_key = actor_key(defender), code = 'CommetRain', waza_id = 177,
    skill_element = 9, game_power = 180, at = clock_now,
}
spawned_source = {'matched', 177, 0, 0, 904, 'native_spawned_meteor_frame'}
local missing_ring, missing_ring_audit = chain:consume_hit(pal, defender, nil, 9, 180)
assert(not missing_ring and missing_ring_audit.reason == 'native_metadata_missing',
    'spawned meteor source borrowed an older effect when its Ring was absent')
spawned_source = {'matched', 177, 7104, 0, 905, 'native_spawned_meteor_frame'}
local conflict_hit, conflict_audit = chain:consume_hit(pal, defender, nil, 8, 180)
assert(not conflict_hit and conflict_audit.reason == 'native_element_conflict',
    'spawned meteor source borrowed an older effect across an element conflict')
spawned_source = {'rejected_scope'}
local rejected_hit, rejected_audit = chain:consume_hit(pal, defender, nil, 9, 180)
assert(not rejected_hit and rejected_audit.reason == 'native_rejected_scope',
    'rejected spawned meteor frame borrowed an older effect')
spawned_source = {'no_scope'}
local no_scope_hit, no_scope_audit = chain:consume_hit(pal, defender, nil, 9, 180)
assert(not no_scope_hit and no_scope_audit.reason == 'native_no_scope',
    'out-of-scope spawned meteor hit borrowed an older effect')

-- The pair of /Game callbacks is registered only after both prerequisites:
-- an available child bridge and a meteor effect. Its arg2 callback is the
-- post-event callback for these Blueprint functions.
chain:reset()
local rock_path = '/Game/Pal/Blueprint/Skill/Commet/BP_SkillEffect_Commet_Rock.BP_SkillEffect_Commet_Rock_C:'
local seed_mine_event = rock_path
    .. 'BndEvt__BP_SkillEffect_SeedMine_Seed_MovementSphereRoot_K2Node_ComponentBoundEvent_0_ComponentHitSignature__DelegateSignature'
local icicle_event = rock_path
    .. 'BndEvt__BP_SkillEffect_IcicleThrow_MovementSphereRoot_K2Node_ComponentBoundEvent_0_ComponentBeginOverlapSignature__DelegateSignature'
local meteor_hook_registrations = 0
local register_hook = chain.deps.register_hook
local bridge_ready = false
local remembered_rocks = {}
chain.deps.register_hook = function(path, pre, post)
    if string.sub(path, 1, #rock_path) == rock_path then
        meteor_hook_registrations = meteor_hook_registrations + 1
    end
    return register_hook(path, pre, post)
end
chain.deps.has_meteor_child_bridge = function() return bridge_ready end
chain.deps.remember_meteor_child = function(rock) remembered_rocks[#remembered_rocks + 1] = rock end
filter.Waza = 177
chain:process_effect(effect)
assert(meteor_hook_registrations == 0,
    'meteor spawn callbacks registered without the native child bridge')
bridge_ready = true
filter.Waza = 602
chain:process_effect(effect)
assert(meteor_hook_registrations == 0,
    'meteor spawn callbacks registered for a non-meteor skill')
filter.Waza = 177
chain:process_effect(effect)
assert(meteor_hook_registrations == 2
    and registered_hooks[seed_mine_event] ~= nil
    and registered_hooks[icicle_event] ~= nil,
    'the two Rock bound events were not registered exactly once')
local seed_mine_post = registered_hooks[seed_mine_event].blueprint_post
local icicle_post = registered_hooks[icicle_event].blueprint_post
assert(type(seed_mine_post) == 'function' and type(icicle_post) == 'function'
    and registered_hooks[seed_mine_event].post == nil
    and registered_hooks[icicle_event].post == nil,
    '/Game bound-event arg2 callbacks were not modeled as Blueprint post callbacks')
local rock_a = object('BP_SkillEffect_Commet_Rock_C RockA', 8101)
local rock_b = object('BP_SkillEffect_Commet_Rock_C RockB', 8102)
seed_mine_post(rock_a)
icicle_post(rock_b)
assert(#remembered_rocks == 2 and remembered_rocks[1] == rock_a and remembered_rocks[2] == rock_b,
    'each Rock bound-event callback did not forward its own Rock to remember_meteor_child')
filter.Waza = 9006
chain:process_effect(effect)
chain:reset()
filter.Waza = 177
chain:process_effect(effect)
assert(meteor_hook_registrations == 2,
    'meteor spawn callbacks were registered again after reset or another meteor Waza')
chain.deps.resolve_waza = prior_resolve
chain.deps.register_hook = register_hook
print('spawned meteor exact-source and one-time Rock callback contract passed')
