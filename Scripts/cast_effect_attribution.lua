-- Exact per-cast damage attribution.
--
-- This module deliberately does not inspect timing, current/recent actions,
-- BasePower, or element. Those values are useful diagnostics, but they are not
-- source identities. A final hit is certain only when it carries an exact
-- effect, DamageInfo, or direct-Waza token that was registered to one cast.

local M = {}

local function identity(value)
    if value == nil then return nil end
    local result = tostring(value)
    if result == "" then return nil end
    return result
end

local function positive_number(value)
    local result = tonumber(value)
    if result == nil or result ~= result or result <= 0 or result == math.huge then
        return nil
    end
    return result
end

local function same_cast(left, right)
    return left ~= nil and right ~= nil and left.cast_id == right.cast_id
end

local Attribution = {}
Attribution.__index = Attribution

function Attribution:reset()
    self.casts = {}
    self.effects = {}
    self.damage_infos = {}
    self.waza_tokens = {}
    self.hits = {}
    self.next_hit_sequence = 0
end

function Attribution:on_cast_begin(event)
    event = event or {}
    local cast_id = identity(event.cast_id)
    local skill_code = identity(event.skill_code)
    local attacker_id = identity(event.attacker_id)
    if cast_id == nil or skill_code == nil or attacker_id == nil then
        return nil, "cast_identity_missing"
    end
    if self.casts[cast_id] ~= nil then
        return nil, "cast_identity_reused"
    end

    local cast = {
        cast_id = cast_id,
        skill_code = skill_code,
        attacker_id = attacker_id,
        action_instance_id = identity(event.action_instance_id),
        began_at = tonumber(event.at),
    }
    self.casts[cast_id] = cast

    local waza_token_id = identity(event.waza_token_id)
    if waza_token_id ~= nil then
        if self.waza_tokens[waza_token_id] ~= nil then
            self.casts[cast_id] = nil
            return nil, "waza_token_reused"
        end
        self.waza_tokens[waza_token_id] = cast
    end
    return cast
end

local function resolve_parent_cast(self, event, direct_field, parent_table, parent_field)
    local direct_id = identity(event[direct_field])
    local direct_cast = direct_id ~= nil and self.casts[direct_id] or nil
    local parent_id = identity(event[parent_field])
    local parent_cast = parent_id ~= nil and parent_table[parent_id] or nil
    if direct_cast ~= nil and parent_cast ~= nil and not same_cast(direct_cast, parent_cast) then
        return nil, "exact_source_conflict"
    end
    return direct_cast or parent_cast
end

local function actor_matches(cast, event)
    local attacker_id = identity(event.attacker_id)
    return cast ~= nil and (attacker_id == nil or attacker_id == cast.attacker_id)
end

function Attribution:on_effect(event)
    event = event or {}
    local effect_id = identity(event.effect_id)
    if effect_id == nil then return nil, "effect_identity_missing" end
    if self.effects[effect_id] ~= nil then return nil, "effect_identity_reused" end

    local cast, reason = resolve_parent_cast(
        self, event, "cast_id", self.effects, "parent_effect_id")
    if cast == nil then return nil, reason or "effect_cast_link_missing" end
    if not actor_matches(cast, event) then return nil, "effect_attacker_mismatch" end
    self.effects[effect_id] = cast
    return cast
end

function Attribution:on_damage_info(event)
    event = event or {}
    local damage_info_id = identity(event.damage_info_id)
    if damage_info_id == nil then return nil, "damage_info_identity_missing" end
    if self.damage_infos[damage_info_id] ~= nil then
        return nil, "damage_info_identity_reused"
    end

    local direct_id = identity(event.cast_id)
    local direct_cast = direct_id ~= nil and self.casts[direct_id] or nil
    local effect_id = identity(event.effect_id)
    local effect_cast = effect_id ~= nil and self.effects[effect_id] or nil
    local parent_id = identity(event.parent_damage_info_id)
    local parent_cast = parent_id ~= nil and self.damage_infos[parent_id] or nil

    local cast = direct_cast or effect_cast or parent_cast
    for _, candidate in ipairs({ direct_cast, effect_cast, parent_cast }) do
        if candidate ~= nil and cast ~= nil and not same_cast(candidate, cast) then
            return nil, "exact_source_conflict"
        end
    end
    if cast == nil then return nil, "damage_info_cast_link_missing" end
    if not actor_matches(cast, event) then return nil, "damage_info_attacker_mismatch" end
    self.damage_infos[damage_info_id] = cast
    return cast
end

local function exact_hit_source(self, event)
    local damage_info_id = identity(event.damage_info_id)
    local damage_info_cast = damage_info_id ~= nil and self.damage_infos[damage_info_id] or nil
    local effect_id = identity(event.effect_id)
    local effect_cast = effect_id ~= nil and self.effects[effect_id] or nil
    local waza_token_id = identity(event.direct_waza_token_id)
    local waza_cast = waza_token_id ~= nil and self.waza_tokens[waza_token_id] or nil

    local selected = nil
    local evidence_kind = nil
    for _, candidate in ipairs({
        { cast = damage_info_cast, kind = "damage_info_cast_link" },
        { cast = effect_cast, kind = "effect_cast_link" },
        { cast = waza_cast, kind = "direct_waza_token" },
    }) do
        if candidate.cast ~= nil then
            if selected ~= nil and not same_cast(selected, candidate.cast) then
                return nil, "exact_source_conflict"
            end
            if selected == nil then
                selected = candidate.cast
                evidence_kind = candidate.kind
            end
        end
    end
    return selected, evidence_kind
end

function Attribution:on_hit(event)
    event = event or {}
    local damage = positive_number(event.damage)
    if damage == nil then return nil, "invalid_damage" end

    local cast, evidence_kind = exact_hit_source(self, event)
    if cast ~= nil and not actor_matches(cast, event) then
        cast = nil
        evidence_kind = "attacker_mismatch"
    end

    self.next_hit_sequence = self.next_hit_sequence + 1
    local hit = {
        hit_seq = self.next_hit_sequence,
        input_seq = event.seq,
        damage = damage,
        cast_id = cast and cast.cast_id or nil,
        skill_code = cast and cast.skill_code or nil,
        evidence_kind = cast and evidence_kind or "unresolved",
        confidence = cast and "exact" or "unresolved",
        unresolved_reason = cast and nil or evidence_kind or "exact_source_missing",
    }
    self.hits[#self.hits + 1] = hit
    return hit
end

function Attribution:snapshot()
    local result = {
        total_damage = 0,
        total_hits = 0,
        unresolved_damage = 0,
        unresolved_hits = 0,
        skills = {},
    }
    for _, hit in ipairs(self.hits) do
        result.total_damage = result.total_damage + hit.damage
        result.total_hits = result.total_hits + 1
        if hit.confidence ~= "exact" then
            result.unresolved_damage = result.unresolved_damage + hit.damage
            result.unresolved_hits = result.unresolved_hits + 1
        else
            local bucket = result.skills[hit.skill_code]
            if bucket == nil then
                bucket = { damage = 0, hits = 0, casts = {} }
                result.skills[hit.skill_code] = bucket
            end
            bucket.damage = bucket.damage + hit.damage
            bucket.hits = bucket.hits + 1
            bucket.casts[hit.cast_id] = true
        end
    end
    return result
end

function M.new()
    local instance = setmetatable({}, Attribution)
    instance:reset()
    return instance
end

return M
