-- Runtime cast -> skill effect -> OnAttack -> final damage source chain.
--
-- The chain never reads BasePower, element, current action, or elapsed time to
-- choose a skill. A hit is confirmed only while it is inside an observed
-- PalSkillEffect OnAttack callback, or when an exact DamageInfo identity was
-- linked to one cast.

local cast_effect_attribution = require("./cast_effect_attribution")

local M = {}
local SourceChain = {}
SourceChain.__index = SourceChain

local function nonempty(value)
    local text = tostring(value or "")
    return text ~= "" and text ~= "nil" and text or nil
end

function SourceChain:reset()
    self.graph:reset()
    self.cast_sequence = 0
    self.effect_records = {}
    self.filter_records = {}
    self.pending_attacks = {}
    self.attack_sequence = 0
end

function SourceChain:on_cast_begin(record, at)
    self.cast_sequence = self.cast_sequence + 1
    local cast_id = string.format("%s|%s|cast:%d",
        tostring(record.actor_key or "unknown"), tostring(record.key), self.cast_sequence)
    local _, reason = self.graph:on_cast_begin({
        cast_id = cast_id,
        skill_code = record.code,
        attacker_id = record.actor_key,
        action_instance_id = record.key,
        at = at,
    })
    if reason ~= nil then
        self.deps.trace("cast-link-rejected cast=" .. cast_id .. " reason=" .. reason)
        return nil
    end
    -- Action hooks are drained off their original callback, while effect
    -- initialization is observed synchronously. If the effect arrived after
    -- the real action-begin callback but before its queued event was drained,
    -- retro-link only that actor/code and only effects observed at or after
    -- the captured begin time.
    for _, effect in pairs(self.effect_records) do
        if effect.cast_id == nil and effect.actor_key == record.actor_key
            and self.deps.canonical(effect.code) == self.deps.canonical(record.code)
            and (effect.observed_at == nil or at == nil or effect.observed_at >= at) then
            effect.cast_id = cast_id
            local linked, link_reason = self.graph:on_effect({
                effect_id = effect.effect_id,
                cast_id = cast_id,
                attacker_id = record.actor_key,
            })
            if linked == nil then
                effect.cast_id = nil
                self.deps.trace("effect-retro-link-rejected effect="
                    .. tostring(effect.effect_id) .. " reason=" .. tostring(link_reason))
            else
                self.deps.trace("effect-retro-linked effect="
                    .. tostring(effect.effect_id) .. " cast=" .. cast_id)
            end
        end
    end
    return cast_id
end

function SourceChain:link_damage_info(attacker_key, code, damage_info_id)
    if nonempty(attacker_key) == nil or nonempty(code) == nil
        or nonempty(damage_info_id) == nil then return nil end
    local selected = nil
    for _, candidate in pairs(self.deps.action_records()) do
        if candidate.actor_key == attacker_key and candidate.ended_at == nil
            and self.deps.canonical(candidate.code) == self.deps.canonical(code) then
            if selected ~= nil and selected.cast_id ~= candidate.cast_id then return nil end
            selected = candidate
        end
    end
    if selected == nil or selected.cast_id == nil then return nil end
    local _, reason = self.graph:on_damage_info({
        damage_info_id = damage_info_id,
        cast_id = selected.cast_id,
        attacker_id = attacker_key,
    })
    if reason ~= nil then return nil end
    return selected.cast_id
end

function SourceChain:effect_waza(effect, direct_filter)
    local attack_filter = self.deps.is_valid(direct_filter) and direct_filter or nil
    if attack_filter == nil then
        local filter_ok, value = self.deps.safe_property(effect, "AttackFilter")
        if filter_ok and self.deps.is_valid(value) then attack_filter = value end
    end
    local waza_value = nil
    if attack_filter ~= nil then
        local waza_ok, value = self.deps.safe_property(attack_filter, "Waza")
        waza_value = waza_ok and self.deps.unwrap(value) or nil
    end
    local waza_id = math.floor(self.deps.to_number(waza_value))
    local code = nil
    if waza_id > 0 then
        code = self.deps.resolve_waza(waza_id).code
    else
        code = self.deps.canonical(self.deps.text_value(waza_value))
        if code == "" or code == "None" or code == "0" then code = nil end
    end
    if code == nil then
        local asset = self.deps.resolve_effect_asset(self.deps.object_info(effect))
        code = asset and self.deps.canonical(asset.code) or nil
    end
    return attack_filter, waza_id > 0 and waza_id or nil, code
end

function SourceChain:unique_active_cast(actor_key, code)
    if nonempty(actor_key) == nil or nonempty(code) == nil then return nil end
    local selected = nil
    for _, record in pairs(self.deps.action_records()) do
        if record.actor_key == actor_key and record.ended_at == nil
            and self.deps.canonical(record.code) == self.deps.canonical(code) then
            if selected ~= nil and selected.cast_id ~= record.cast_id then return nil end
            selected = record
        end
    end
    return selected
end

function SourceChain:locate_effect_source(effect, code)
    local function action_owner_key(candidate)
        if not self.deps.is_valid(candidate) then return nil end
        local component_ok, component = self.deps.safe_property(candidate, "ActionComponent")
        if not component_ok or not self.deps.is_valid(component) then
            component_ok, component = self.deps.safe_call(candidate, "GetActionComponent")
        end
        if component_ok and self.deps.is_valid(component) then
            return self.deps.actor_key(candidate)
        end
        return nil
    end

    local instigator_ok, instigator = self.deps.safe_call(effect, "GetInstigator")
    local instigator_key = instigator_ok and action_owner_key(instigator) or nil
    if instigator_key ~= nil then
        local cast = self:unique_active_cast(instigator_key, code)
        return cast and cast.cast_id or nil, instigator_key
    end

    local current = effect
    for _ = 1, 8 do
        local owner_ok, owner = self.deps.safe_call(current, "GetOwner")
        if not owner_ok or not self.deps.is_valid(owner) or owner == current then break end
        local owner_effect_id = self.deps.object_identity(owner)
        local parent = owner_effect_id and self.effect_records[owner_effect_id] or nil
        if parent ~= nil and parent.cast_id ~= nil then
            return parent.cast_id, parent.actor_key
        end
        local actor_key = action_owner_key(owner)
        if actor_key ~= nil then
            local cast = self:unique_active_cast(actor_key, code)
            return cast and cast.cast_id or nil, actor_key
        end
        current = owner
    end
    return nil, nil
end

function SourceChain:register_attack_handlers(effect)
    local class_ok, effect_class = self.deps.safe_call(effect, "GetClass")
    if not class_ok or not self.deps.is_valid(effect_class) then return end
    local iterated, iterate_error = self.deps.safe_call(
        effect_class, "ForEachFunction", function(fn)
            local full_name = self.deps.full_name(fn)
            if string.find(full_name, "OnAttackDelegate__DelegateSignature", 1, true) ~= nil then
                local event_name = string.match(full_name, ":([^:]+)$")
                if event_name == nil or event_name == "" then
                    self.deps.trace("effect-attack-event-name-missing function=" .. full_name)
                elseif self.registered_attack_hooks[event_name] ~= true then
                    -- RegisterHook explicitly does not support delegate
                    -- functions. Blueprint-bound OnAttack handlers execute
                    -- through ProcessInternal, which RegisterCustomEvent
                    -- observes by reflected event name and supplies Context +
                    -- every Blueprint parameter.
                    local registered, register_error = pcall(function()
                        self.deps.register_custom_event(event_name, function(
                            context, defender, damage_info, hit_count, attacker_component)
                            local ok, err = pcall(function()
                                self:capture_attack(context, defender, damage_info,
                                    hit_count, attacker_component)
                            end)
                            if not ok then self.deps.on_error("effect attack capture", err) end
                        end)
                    end)
                    if registered then
                        self.registered_attack_hooks[event_name] = true
                        self.deps.on_attack_hook_registered(event_name)
                    else
                        self.deps.trace("effect-attack-hook-failed event=" .. event_name
                            .. " error=" .. tostring(register_error))
                    end
                end
            end
            return false
        end)
    if not iterated then
        self.deps.trace("effect-function-enumeration-failed error=" .. tostring(iterate_error))
    end
end

function SourceChain:process_effect(effect, direct_filter)
    if not self.deps.is_valid(effect) then return nil end
    local effect_id = self.deps.object_identity(effect)
    if effect_id == nil then return nil end
    local attack_filter, waza_id, code = self:effect_waza(effect, direct_filter)
    local cast_id, actor_key = self:locate_effect_source(effect, code)
    local record = {
        effect_id = effect_id,
        cast_id = cast_id,
        actor_key = actor_key,
        waza_id = waza_id,
        code = code,
        attack_filter_id = self.deps.object_identity(attack_filter),
        observed_at = self.deps.clock(),
    }
    self.effect_records[effect_id] = record
    if record.attack_filter_id ~= nil then
        self.filter_records[record.attack_filter_id] = record
    end
    if cast_id ~= nil then
        self.graph:on_effect({
            effect_id = effect_id,
            cast_id = cast_id,
            attacker_id = actor_key,
        })
    end
    self.deps.trace(string.format(
        "effect-init effect=%s cast=%s actor=%s id=%s code=%s filter=%s",
        effect_id, tostring(cast_id or "none"), tostring(actor_key or "none"),
        tostring(waza_id or "none"), tostring(code or "none"),
        tostring(record.attack_filter_id or "none")))
    self:register_attack_handlers(effect)
    return record
end

function SourceChain:capture_attack(effect_param, defender_param, damage_info_param, hit_count_param)
    if not self.deps.enabled() then return end
    local effect = self.deps.unwrap(effect_param)
    local defender = self.deps.unwrap(defender_param)
    local damage_info = self.deps.unwrap(damage_info_param)
    if not self.deps.is_valid(effect) or defender == nil then return end
    local effect_id = self.deps.object_identity(effect)
    local record = effect_id and self.effect_records[effect_id] or nil
    if record == nil then record = self:process_effect(effect) end
    if record == nil or (record.code == nil and record.cast_id == nil) then return end

    local attacker = nil
    if damage_info ~= nil then
        local attacker_ok, value = pcall(function() return damage_info.Attacker end)
        attacker = attacker_ok and self.deps.unwrap(value) or nil
    end
    self.attack_sequence = self.attack_sequence + 1
    local attack = {
        token = self.attack_sequence,
        effect_id = record.effect_id,
        cast_id = record.cast_id,
        code = record.code,
        waza_id = record.waza_id,
        attacker_key = attacker and self.deps.value_identity(attacker) or nil,
        defender_key = self.deps.value_identity(defender),
        damage_info_key = damage_info and self.deps.value_identity(damage_info) or nil,
        hit_count = math.max(1, math.floor(self.deps.to_number(hit_count_param))),
    }
    self.pending_attacks[#self.pending_attacks + 1] = attack
    while #self.pending_attacks > 32 do table.remove(self.pending_attacks, 1) end
    self.deps.trace(string.format(
        "effect-attack token=%d effect=%s cast=%s code=%s defender=%s damage_info=%s",
        attack.token, tostring(attack.effect_id), tostring(attack.cast_id or "none"),
        tostring(attack.code or "none"), tostring(attack.defender_key or "none"),
        tostring(attack.damage_info_key or "none")))
    self.deps.defer(function() self:remove_pending(attack.token) end)
end

function SourceChain:remove_pending(token)
    for index = #self.pending_attacks, 1, -1 do
        if self.pending_attacks[index].token == token then
            table.remove(self.pending_attacks, index)
            return
        end
    end
end

function SourceChain:consume_hit(attacker, defender, damage_info_key)
    local defender_key = self.deps.value_identity(defender)
    for index = #self.pending_attacks, 1, -1 do
        local attack = self.pending_attacks[index]
        local actors_match = attack.defender_key ~= nil
            and attack.defender_key == defender_key
        local info_matches = damage_info_key ~= nil and attack.damage_info_key ~= nil
            and damage_info_key == attack.damage_info_key
        if info_matches or actors_match then
            table.remove(self.pending_attacks, index)
            return attack
        end
    end
    return nil
end

function SourceChain:register_effect_hook()
    return pcall(function()
        self.deps.register_hook("/Script/Pal.PalSkillEffectBase:OnInitialize", function()
        end, function(effect)
            local ok, err = pcall(function()
                self:process_effect(self.deps.unwrap(effect))
            end)
            if not ok then self.deps.on_error("effect initialize capture", err) end
        end)
    end)
end

function SourceChain:register_filter_hook()
    return pcall(function()
        -- The UFunction is declared by PalHitFilter, inherited by
        -- PalAttackFilter. RegisterHook requires its declaring class path.
        self.deps.register_hook("/Script/Pal.PalHitFilter:BindPrimitiveComponent",
            function(filter)
                local ok, err = pcall(function()
                    filter = self.deps.unwrap(filter)
                    if not self.deps.is_valid(filter) then return end
                    -- The base hook also sees non-attack hit filters.
                    local waza_ok, waza = self.deps.safe_property(filter, "Waza")
                    if not waza_ok or waza == nil then return end
                    local filter_id = self.deps.object_identity(filter)
                    if filter_id ~= nil and self.filter_records[filter_id] ~= nil then
                        return
                    end
                    local outer_ok, effect = self.deps.safe_call(filter, "GetOuter")
                    if outer_ok and self.deps.is_valid(effect) then
                        self:process_effect(effect, filter)
                    end
                end)
                if not ok then self.deps.on_error("attack filter capture", err) end
            end)
    end)
end

function M.new(deps)
    local instance = setmetatable({
        deps = deps,
        graph = cast_effect_attribution.new(),
        registered_attack_hooks = {},
    }, SourceChain)
    instance:reset()
    return instance
end

return M
