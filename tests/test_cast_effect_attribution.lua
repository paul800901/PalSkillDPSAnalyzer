package.path = "../Scripts/?.lua;./fixtures/?.lua;" .. package.path

local attribution_module = require("cast_effect_attribution")
local fixtures = require("cast_effect_overlap")

local function equal(actual, expected, message)
    assert(actual == expected, string.format(
        "%s (expected=%s actual=%s)", message, tostring(expected), tostring(actual)))
end

local function dispatch(engine, event)
    if event.kind == "cast_begin" then
        local result, reason = engine:on_cast_begin(event)
        assert(result ~= nil, "cast registration failed: " .. tostring(reason))
    elseif event.kind == "effect" then
        local result, reason = engine:on_effect(event)
        assert(result ~= nil, "effect registration failed: " .. tostring(reason))
    elseif event.kind == "damage_info" then
        local result, reason = engine:on_damage_info(event)
        assert(result ~= nil, "DamageInfo registration failed: " .. tostring(reason))
    elseif event.kind == "damage_info_unlinked" then
        local result, reason = engine:on_damage_info(event)
        assert(result == nil and reason == "damage_info_cast_link_missing",
            "unlinked DamageInfo copy did not fail closed")
    elseif event.kind == "hit" then
        local result, reason = engine:on_hit(event)
        assert(result ~= nil, "hit registration failed: " .. tostring(reason))
        return result
    else
        error("unknown fixture event: " .. tostring(event.kind))
    end
    return nil
end

local function run_case(name, fixture)
    local engine = attribution_module.new()
    local hits = {}
    for _, event in ipairs(fixture.events) do
        local hit = dispatch(engine, event)
        if hit ~= nil then hits[#hits + 1] = hit end
    end

    equal(#hits, #fixture.expected_hits, name .. " hit count")
    for index, expected in ipairs(fixture.expected_hits) do
        local actual = hits[index]
        equal(actual.cast_id, expected.cast_id, name .. " hit " .. index .. " cast")
        equal(actual.skill_code, expected.skill_code, name .. " hit " .. index .. " skill")
        equal(actual.evidence_kind, expected.evidence_kind,
            name .. " hit " .. index .. " evidence")
        if expected.evidence_kind == "unresolved" then
            equal(actual.confidence, "unresolved", name .. " weak hit confidence")
        else
            equal(actual.confidence, "exact", name .. " exact hit confidence")
            assert(actual.evidence_kind == "effect_cast_link"
                or actual.evidence_kind == "damage_info_cast_link"
                or actual.evidence_kind == "direct_waza_token",
                name .. " accepted a non-exact attribution source")
        end
    end

    local snapshot = engine:snapshot()
    equal(snapshot.total_damage, fixture.expected_total.damage, name .. " total damage")
    equal(snapshot.total_hits, fixture.expected_total.hits, name .. " total hits")
    equal(snapshot.unresolved_damage, fixture.expected_total.unresolved_damage,
        name .. " unresolved damage")
    equal(snapshot.unresolved_hits, fixture.expected_total.unresolved_hits,
        name .. " unresolved hits")

    local visible_damage = snapshot.unresolved_damage
    local visible_hits = snapshot.unresolved_hits
    for skill_code, expected in pairs(fixture.expected_skills) do
        local actual = snapshot.skills[skill_code]
        assert(actual ~= nil, name .. " missing skill bucket " .. skill_code)
        equal(actual.damage, expected.damage, name .. " " .. skill_code .. " damage")
        equal(actual.hits, expected.hits, name .. " " .. skill_code .. " hits")
    end
    for skill_code, actual in pairs(snapshot.skills) do
        assert(fixture.expected_skills[skill_code] ~= nil,
            name .. " created unexpected skill bucket " .. skill_code)
        visible_damage = visible_damage + actual.damage
        visible_hits = visible_hits + actual.hits
    end
    equal(visible_damage, snapshot.total_damage, name .. " damage conservation")
    equal(visible_hits, snapshot.total_hits, name .. " hit conservation")
end

run_case("overlap", fixtures.overlap)
run_case("same_signature_exact", fixtures.same_signature_exact)
run_case("same_signature_weak", fixtures.same_signature_weak)
run_case("wrapper_copy_propagated", fixtures.wrapper_copy_propagated)
run_case("wrapper_copy_unpropagated", fixtures.wrapper_copy_unpropagated)

-- Exact links, not hit order, determine the result. Replay the overlap hits in
-- reverse order while preserving all source registrations.
do
    local reordered = { events = {}, expected_hits = {}, expected_skills = fixtures.overlap.expected_skills,
        expected_total = fixtures.overlap.expected_total }
    local registrations = {}
    local hits = {}
    for _, event in ipairs(fixtures.overlap.events) do
        if event.kind == "hit" then hits[#hits + 1] = event else registrations[#registrations + 1] = event end
    end
    for _, event in ipairs(registrations) do reordered.events[#reordered.events + 1] = event end
    for index = #hits, 1, -1 do
        reordered.events[#reordered.events + 1] = hits[index]
        reordered.expected_hits[#reordered.expected_hits + 1] = fixtures.overlap.expected_hits[index]
    end
    run_case("overlap_reordered", reordered)
end

-- Reset removes every exact identity, preventing old effects from contaminating
-- a new manual measurement session.
do
    local engine = attribution_module.new()
    dispatch(engine, { kind = "cast_begin", attacker_id = "pal:reset:1", cast_id = "reset:1", skill_code = "OldField" })
    dispatch(engine, { kind = "effect", attacker_id = "pal:reset:1", effect_id = "effect:reset:1", cast_id = "reset:1" })
    engine:reset()
    local hit = dispatch(engine, { kind = "hit", attacker_id = "pal:reset:1", effect_id = "effect:reset:1", damage = 9 })
    equal(hit.evidence_kind, "unresolved", "reset retained an old effect link")
end

print("cast/effect attribution regression tests passed")
