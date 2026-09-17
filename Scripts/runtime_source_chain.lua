-- Runtime cast -> skill effect -> OnAttack -> final damage source chain.
--
-- Actual delegate bindings establish effect candidates. Element conflicts
-- are rejected before matching. Pending callbacks are asynchronous evidence,
-- not an exact scope; DamageInfo addresses can be reused across skills.

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
    self.bound_attack_contexts = {}
    self.collision_scopes = {}
    self.pending_collisions = {}
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

function SourceChain:register_attack_handlers(effect, filter)
    local effect_id = self.deps.object_identity(effect)
    local delegate_ok, delegate = self.deps.safe_property(filter, "OnAttackDelegate")
    local bindings_ok, bindings = false, nil
    if delegate_ok and delegate ~= nil then
        bindings_ok, bindings = self.deps.safe_call(delegate, "GetBindings")
    end
    if not bindings_ok or type(bindings) ~= "table" then
        self.deps.trace("effect-bindings-unavailable effect=" .. tostring(effect_id))
        return false
    end
    local found = false
    for _, binding in ipairs(bindings) do
        -- Global custom-event hooks are name-based. Authorize only a target
        -- actually bound on THIS effect's attack delegate, not a same-named
        -- event from some other object. Do not modify/broadcast the delegate.
        local target = self.deps.unwrap(binding.Object)
        local event_name = self.deps.text_value(binding.FunctionName)
        if self.deps.object_identity(target) == effect_id and nonempty(event_name)
            and event_name ~= "None" then
                found = true
                self.bound_attack_contexts[event_name] = self.bound_attack_contexts[event_name] or {}
                self.bound_attack_contexts[event_name][effect_id] = true
                if self.registered_attack_hooks[event_name] ~= true then
                    -- RegisterHook explicitly does not support delegate
                    -- functions. Blueprint-bound OnAttack handlers execute
                    -- through ProcessInternal, which RegisterCustomEvent
                    -- observes by reflected event name and supplies Context +
                    -- every Blueprint parameter.
                    local registered, register_error = pcall(function()
                        self.deps.register_custom_event(event_name, function(
                            context, defender, damage_info, hit_count, attacker_component)
                            local ok, err = pcall(function()
                                local context_id = self.deps.object_identity(self.deps.unwrap(context))
                                local allowed = self.bound_attack_contexts[event_name]
                                if not allowed or not allowed[context_id] then return end
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
    end
    if found then self.deps.trace("effect-bindings-ready effect=" .. tostring(effect_id)) end
    return found
end

function SourceChain:register_meteor_spawn_hooks(code)
    if self.meteor_spawn_hooks_registered
        or not self.deps.has_meteor_child_bridge or not self.deps.has_meteor_child_bridge()
        or (code ~= "Commet" and code ~= "CommetRain" and code ~= "ThreeCommet") then return end
    -- OnInitialize proves the rock classes are loaded. These are ordinary
    -- Blueprint event functions (not FUNC_Delegate). For /Game functions the
    -- second RegisterHook callback runs AFTER the event, once spawn returned.
    local path = "/Game/Pal/Blueprint/Skill/Commet/BP_SkillEffect_Commet_Rock.BP_SkillEffect_Commet_Rock_C:"
    self.meteor_spawn_hook_paths = self.meteor_spawn_hook_paths or {}
    for _, name in ipairs({
        "BndEvt__BP_SkillEffect_SeedMine_Seed_MovementSphereRoot_K2Node_ComponentBoundEvent_0_ComponentHitSignature__DelegateSignature",
        "BndEvt__BP_SkillEffect_IcicleThrow_MovementSphereRoot_K2Node_ComponentBoundEvent_0_ComponentBeginOverlapSignature__DelegateSignature",
    }) do
        if not self.meteor_spawn_hook_paths[name] then
            local ok, err = pcall(self.deps.register_hook, path .. name, function(context)
                local bound, failure = pcall(self.deps.remember_meteor_child, self.deps.unwrap(context))
                if not bound then self.deps.on_error("meteor spawn link", failure) end
            end)
            if ok then
                self.meteor_spawn_hook_paths[name] = true
                self.deps.trace("meteor-spawn-hook function=" .. path .. name)
            else
                self.deps.on_error("meteor spawn hook", err)
                return
            end
        end
    end
    self.meteor_spawn_hooks_registered = true
end

function SourceChain:process_effect(effect, direct_filter)
    if not self.deps.is_valid(effect) then return nil end
    local effect_id = self.deps.object_identity(effect)
    if effect_id == nil then return nil end
    local attack_filter, waza_id, code = self:effect_waza(effect, direct_filter)
    self:register_meteor_spawn_hooks(code)
    -- Independent stage-component observation, not learned from damage buckets.
    -- An observed component is not proof that every stage was enumerated, or
    -- that its rate remained unchanged until impact. Do not use it to assign hits.
    local rate_ok, rate_value = self.deps.safe_property(attack_filter, "WazaPowerRate")
    local stage_rate = rate_ok and tonumber(self.deps.unwrap(rate_value)) or nil
    if stage_rate ~= nil and (stage_rate ~= stage_rate or stage_rate < 0
        or stage_rate == math.huge) then stage_rate = nil end
    local metadata = waza_id and self.deps.resolve_waza(waza_id) or {}
    local cast_id, actor_key = self:locate_effect_source(effect, code)
    local record = {
        effect_id = effect_id,
        cast_id = cast_id,
        actor_key = actor_key,
        waza_id = waza_id,
        code = code,
        skill_element = metadata.attack_element,
        game_power = metadata.game_power,
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
    self.deps.trace(string.format(
        "effect-stage-probe effect=%s filter=%s actor=%s id=%s code=%s rate=%s game_power=%s element=%s source=attack-filter completeness=unverified",
        effect_id, tostring(record.attack_filter_id or "none"), tostring(actor_key or "none"),
        tostring(waza_id or "none"), tostring(code or "none"), tostring(stage_rate),
        tostring(metadata.game_power), tostring(metadata.attack_element)))
    if self.deps.has_native_bridge and self.deps.has_native_bridge() then
        -- The native pre/post lane supplies the live call directly. Do not
        -- register unused late callbacks that can also pollute collision hints.
        return record
    end
    if not self:register_attack_handlers(effect, attack_filter) then
        -- Binding may finish after OnInitialize/BindPrimitiveComponent. One
        -- deferred retry, not a per-frame scan or another global object walk.
        self.deps.defer(function()
            if self.effect_records[effect_id] == record and self.deps.is_valid(effect)
                and self.deps.is_valid(attack_filter) then
                self:register_attack_handlers(effect, attack_filter)
            end
        end)
    end
    return record
end

function SourceChain:capture_attack(effect_param, defender_param, damage_info_param, hit_count_param)
    if not self.deps.enabled() then return end
    if self.deps.has_native_bridge and self.deps.has_native_bridge() then return end
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
        skill_element = record.skill_element,
        game_power = record.game_power,
        at = self.deps.clock(),
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
    -- A game-thread scheduling boundary is not the final-damage boundary.
    -- Keep the copied evidence briefly, with an additional power check after
    -- that boundary. Expiry is measured from capture, never extended on reuse.
    self.deps.defer(function() attack.deferred = true end)
end

function SourceChain:remove_pending(token)
    for index = #self.pending_attacks, 1, -1 do
        if self.pending_attacks[index].token == token then
            table.remove(self.pending_attacks, index)
            return
        end
    end
end

function SourceChain:consume_hit(attacker, defender, damage_info_key, hit_element, hit_power, received_at)
    local attacker_key = self.deps.value_identity(attacker)
    local defender_key = self.deps.value_identity(defender)
    -- Judge evidence at callback arrival, not after reflective diagnostic reads.
    local processed_at = self.deps.clock()
    local now = received_at or processed_at
    local audit = {pending=#self.pending_attacks, expired=0, actors=0, elements=0, powers=0}
    audit.processing_ms = math.floor(math.max(0, processed_at - now) * 1000)
    local native_status, native_waza, native_effect, native_filter, native_sequence, native_kind
    if self.deps.native_source then
        native_status, native_waza, native_effect, native_filter, native_sequence, native_kind =
            self.deps.native_source(attacker, defender)
    end
    if native_status ~= nil then
        audit.native = native_status
        if native_status == "matched" then
            local metadata = self.deps.resolve_waza(native_waza)
            if metadata.attack_element ~= nil and hit_element ~= nil
                and tonumber(hit_element) ~= tonumber(metadata.attack_element) then
                audit.reason = "native_element_conflict"
                return nil, audit
            end
            local filter_address = tonumber(native_filter) or 0
            local effect_address = tonumber(native_effect) or 0
            local frame_source = native_kind == "native_attack_filter_frame"
            local blueprint_source = native_kind == "native_blueprint_effect_frame"
            local spawned_source = native_kind == "native_spawned_meteor_frame"
            local source_kind = (frame_source or blueprint_source or spawned_source) and native_kind or "native_call_scope"
            if not metadata.code or (not spawned_source and filter_address <= 0)
                or (not frame_source and effect_address <= 0) then
                audit.reason = "native_metadata_missing"
                return nil, audit
            end
            audit.reason = source_kind
            audit.call = native_sequence
            self.deps.trace("native-source-match call=" .. tostring(native_sequence)
                .. " code=" .. tostring(metadata.code) .. " source=" .. source_kind
                .. " confidence=exact")
            return {
                token = native_sequence, waza_id = native_waza, code = metadata.code,
                effect_id = effect_address > 0 and "addr:" .. tostring(native_effect) or nil,
                attack_filter_id = filter_address > 0 and "addr:" .. tostring(native_filter) or nil,
                skill_element = metadata.attack_element, confidence = "exact",
                source = source_kind,
            }, audit
        elseif native_status ~= "no_scope" then
            -- An incomplete/conflicting nested call cannot borrow an old event.
            audit.reason = "native_" .. tostring(native_status)
            return nil, audit
        end
    end
    for index = #self.pending_attacks, 1, -1 do
        local at = self.pending_attacks[index].at
        if at and (now < at or now - at > 0.075) then
            local old = self.pending_attacks[index]
            if old.attacker_key == attacker_key and old.defender_key == defender_key then
                audit.expired = audit.expired + 1
                audit.expired_age_ms = math.floor((now - at) * 1000)
            end
            table.remove(self.pending_attacks, index)
        end
    end
    -- Only the current synchronous OnHit scope may supply animation collision
    -- evidence. Never retain it until a later frame or select a recent action.
    local scope = self.collision_scopes[#self.collision_scopes]
    if scope ~= nil or #self.pending_collisions > 0 then
        self.deps.trace('animation-collision-final scope=' .. tostring(scope ~= nil)
            .. ' pending=' .. tostring(#self.pending_collisions)
            .. ' attacker=' .. tostring(attacker_key) .. ' target=' .. tostring(defender_key)
            .. ' element=' .. tostring(hit_element) .. ' power=' .. tostring(hit_power))
    end
    if scope and scope.attacker_key ~= nil and scope.defender_key ~= nil
        and scope.attacker_key == attacker_key and scope.defender_key == defender_key
        and scope.skill_element ~= nil and tonumber(hit_element) == scope.skill_element then
        self.deps.trace('animation-collision-match id=' .. tostring(scope.waza_id)
            .. ' code=' .. tostring(scope.code) .. ' confidence=inferred')
        scope.consumed = true
        audit.reason = 'collision_scope'
        return scope, audit
    end
    -- OnHit can return before final damage is reported. Preserve only copied
    -- identities, not Unreal parameters. This short-lived, single-use evidence
    -- is still inferred: never use a recent action or an address as a hit ID.
    local collision_matches = {}
    for index = #self.pending_collisions, 1, -1 do
        local candidate = self.pending_collisions[index]
        local age = now - candidate.at
        if age < 0 or age > 0.075 then
            table.remove(self.pending_collisions, index)
        elseif candidate.attacker_key == attacker_key and candidate.defender_key == defender_key
            and candidate.skill_element == tonumber(hit_element)
            and candidate.game_power ~= nil and candidate.game_power == tonumber(hit_power) then
            collision_matches[#collision_matches + 1] = candidate
        end
    end
    if #collision_matches > 0 and scope == nil then
        local candidate = collision_matches[1]
        local ambiguous = false
        for _, other in ipairs(collision_matches) do
            if other.waza_id ~= candidate.waza_id or other.code ~= candidate.code then ambiguous = true end
        end
        for _, other in ipairs(self.pending_attacks) do
            if other.attacker_key == attacker_key and other.defender_key == defender_key
                and other.skill_element == tonumber(hit_element) and other.code ~= candidate.code then
                ambiguous = true
            end
        end
        -- Consume duplicate notifications together, including ambiguous ones;
        -- none may remain to label a subsequent damage event.
        for index = #self.pending_collisions, 1, -1 do
            for _, matched in ipairs(collision_matches) do
                if self.pending_collisions[index] == matched then
                    table.remove(self.pending_collisions, index)
                    break
                end
            end
        end
        if ambiguous then
            self.deps.trace('animation-collision-delayed ambiguous=true')
            audit.reason = 'collision_ambiguous'
            return nil, audit
        end
        candidate.source = 'inferred_animation_collision_delayed'
        self.deps.trace('animation-collision-delayed-match code=' .. tostring(candidate.code)
            .. ' age=' .. tostring(now - candidate.at) .. ' confidence=inferred')
        audit.reason = 'collision_delayed'
        return candidate, audit
    end
    if native_status ~= nil then
        -- Blueprint OnAttack custom events are post callbacks. Once the native
        -- pre/post bridge is available, never reuse their late report on the
        -- next hit. Animation collision evidence remains a separate lane.
        audit.reason = "native_no_scope"
        return nil, audit
    end
    local matches = {}
    for index = #self.pending_attacks, 1, -1 do
        local attack = self.pending_attacks[index]
        local actors_match = attack.attacker_key ~= nil
            and attack.attacker_key == attacker_key
            and attack.defender_key ~= nil
            and attack.defender_key == defender_key
        if actors_match then
            audit.actors = audit.actors + 1
            if hit_element ~= nil and attack.skill_element ~= nil
                and tonumber(hit_element) == attack.skill_element then
                audit.elements = audit.elements + 1
            end
        end
        -- Filter before considering a source. DamageInfo addresses are reused
        -- by the engine and cannot identify a hit, even with matching actors.
        if actors_match and hit_element ~= nil and attack.skill_element ~= nil
            and tonumber(hit_element) == attack.skill_element
            and (not attack.deferred or (attack.game_power ~= nil
                and tonumber(hit_power) == tonumber(attack.game_power))) then
            matches[#matches + 1] = index
            audit.powers = audit.powers + 1
        end
    end
    -- Multiple projectiles from one cast are different effect instances, not
    -- different skills. Permit their common skill only when the cast identity
    -- is known and equal; without a cast, retain the same-effect restriction.
    if #matches > 0 then
        local candidate = self.pending_attacks[matches[1]]
        local ambiguous = false
        for _, index in ipairs(matches) do
            local other = self.pending_attacks[index]
            if candidate.effect_id == nil or candidate.waza_id == nil
                or other.waza_id ~= candidate.waza_id
                or other.code ~= candidate.code
                or other.cast_id ~= candidate.cast_id
                or (other.effect_id ~= candidate.effect_id and candidate.cast_id == nil) then ambiguous = true end
        end
        -- Distinct projectiles can each produce a final hit. Consume only one
        -- effect's duplicate callback group, retaining the other projectiles
        -- for their own hits. Ambiguous evidence cannot label a later hit.
        for _, index in ipairs(matches) do
            if ambiguous or self.pending_attacks[index].effect_id == candidate.effect_id then
                table.remove(self.pending_attacks, index)
            end
        end
        if ambiguous then
            self.deps.trace('effect-callback-group ambiguous=true consumed=' .. tostring(#matches))
            audit.reason = 'effect_ambiguous'
            return nil, audit
        end
        if #matches > 1 then
            self.deps.trace("effect-callback-group count=" .. tostring(#matches)
                .. " code=" .. tostring(candidate.code) .. " confidence=inferred")
        end
        -- This asynchronous scope is still an inference, not an exact hit ID.
        candidate.confidence = "inferred"
        if candidate.deferred then
            candidate.source = 'inferred_effect_candidate_delayed'
            self.deps.trace('effect-delayed-match code=' .. tostring(candidate.code)
                .. ' age=' .. tostring(now - candidate.at) .. ' confidence=inferred')
        end
        audit.reason = candidate.deferred and 'effect_delayed' or 'effect_pending'
        audit.age_ms = math.floor((now - candidate.at) * 1000)
        return candidate, audit
    end
    audit.reason = audit.elements > 0 and 'power_mismatch'
        or audit.actors > 0 and 'element_mismatch'
        or audit.expired > 0 and 'expired'
        or audit.pending > 0 and 'actors_mismatch' or 'no_pending'
    return nil, audit
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
    local collision_ok, collision_error = pcall(function()
        self.deps.register_hook('/Script/Pal.PalAnimNotifyState_AttackCollision:OnHit',
            function(notify, component, target)
                -- Push a barrier even if capture fails, so a nested unrelated
                -- call cannot borrow its parent's source.
                local scope = {}
                self.collision_scopes[#self.collision_scopes + 1] = scope
                local ok, err = pcall(function()
                    if not self.deps.enabled() then return end
                    notify = self.deps.unwrap(notify)
                    component = self.deps.unwrap(component)
                    target = self.deps.unwrap(target)
                    if not self.deps.is_valid(notify) or not self.deps.is_valid(component)
                        or not self.deps.is_valid(target) then return end
                    local filter_ok, filter = self.deps.safe_property(notify, 'AttackFilter')
                    if not filter_ok or not self.deps.is_valid(filter) then return end
                    local id_ok, raw_id = self.deps.safe_property(filter, 'Waza')
                    local id = id_ok and math.floor(self.deps.to_number(self.deps.unwrap(raw_id))) or 0
                    local owner_ok, owner = self.deps.safe_call(component, 'GetOwner')
                    if id <= 0 or not owner_ok or not self.deps.is_valid(owner) then return end
                    local metadata = self.deps.resolve_waza(id)
                    if metadata.attack_element == nil or metadata.code == nil then return end
                    scope.attacker_key = self.deps.value_identity(owner)
                    scope.defender_key = self.deps.value_identity(target)
                    scope.waza_id, scope.code = id, metadata.code
                    scope.skill_element = metadata.attack_element
                    scope.game_power = tonumber(metadata.game_power)
                    scope.effect_id = self.deps.object_identity(notify)
                    scope.confidence = 'inferred'
                    scope.source = 'inferred_animation_collision'
                    self.deps.trace('animation-collision-begin id=' .. tostring(id)
                        .. ' code=' .. tostring(scope.code) .. ' notify=' .. tostring(scope.effect_id)
                        .. ' attacker=' .. tostring(scope.attacker_key) .. ' target=' .. tostring(scope.defender_key))
                end)
                if not ok then self.deps.on_error('animation collision capture', err) end
            end,
            function()
                local scope = table.remove(self.collision_scopes)
                if scope and not scope.consumed and scope.waza_id and scope.game_power then
                    scope.at = self.deps.clock()
                    self.pending_collisions[#self.pending_collisions + 1] = scope
                    while #self.pending_collisions > 32 do table.remove(self.pending_collisions, 1) end
                end
            end)
    end)
    self.deps.trace('animation-collision-hook ready=' .. tostring(collision_ok)
        .. (collision_ok and '' or ' error=' .. tostring(collision_error)))
    -- Observe the filter's native dispatch independently of effect Blueprint
    -- bindings. Some attacks have no observed SkillEffect initialization.
    -- No parameter layout assumptions and no damage attribution from this probe.
    local probe_ok, probe_error = pcall(function()
        self.deps.register_hook('/Script/Pal.PalAttackFilter:CallBackOnAttackDelegate',
            function(filter)
                if not self.deps.enabled() then return end
                local ok, err = pcall(function()
                    filter = self.deps.unwrap(filter)
                    if not self.deps.is_valid(filter) then return end
                    local waza_ok, waza = self.deps.safe_property(filter, 'Waza')
                    local id = waza_ok and math.floor(self.deps.to_number(self.deps.unwrap(waza))) or 0
                    local outer_ok, outer = self.deps.safe_call(filter, 'GetOuter')
                    self.deps.trace('filter-dispatch-probe filter='
                        .. tostring(self.deps.object_identity(filter))
                        .. ' id=' .. tostring(id)
                        .. ' outer=' .. tostring(outer_ok and self.deps.object_identity(outer) or 'unavailable'))
                end)
                if not ok then self.deps.on_error('filter dispatch probe', err) end
            end)
    end)
    self.deps.trace('filter-dispatch-probe-hook ready=' .. tostring(probe_ok)
        .. (probe_ok and '' or ' error=' .. tostring(probe_error)))
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
