#include "AttributionEventCore.hpp"

#include <cmath>
#include <cstdlib>
#include <iostream>
#include <string_view>

namespace
{
    using pal_dps::AttributionEventCore;
    using pal_dps::AttributionKind;
    using pal_dps::CastBegin;
    using pal_dps::CastToken;
    using pal_dps::DamageInfoLink;
    using pal_dps::EffectLink;
    using pal_dps::EvidenceKind;
    using pal_dps::FinalHit;
    using pal_dps::LinkResult;
    using pal_dps::ObjectToken;
    using pal_dps::Snapshot;
    using pal_dps::StatusApplication;

    [[nodiscard]] constexpr auto token(const std::uint32_t index, const std::uint32_t serial)
        -> ObjectToken
    {
        return {index, serial};
    }

    [[nodiscard]] constexpr auto cast_token(const std::uint64_t generation) -> CastToken
    {
        return {generation};
    }

    [[noreturn]] auto fail(const std::string_view message) -> void
    {
        std::cerr << "FAILED: " << message << '\n';
        std::exit(1);
    }

    auto expect(const bool condition, const std::string_view message) -> void
    {
        if (!condition) fail(message);
    }

    auto expect_damage(const double actual, const double expected, const std::string_view message) -> void
    {
        if (std::abs(actual - expected) > 0.000001) fail(message);
    }

    auto expect_total(
        const pal_dps::DamageTotal& actual,
        const double damage,
        const std::uint64_t hits,
        const std::string_view message) -> void
    {
        expect_damage(actual.damage, damage, message);
        expect(actual.hits == hits, message);
    }

    auto expect_conservation(const Snapshot& snapshot) -> void
    {
        double damage = snapshot.unresolved.damage;
        std::uint64_t hits = snapshot.unresolved.hits;
        for (const auto& [_, total] : snapshot.skills)
        {
            damage += total.damage;
            hits += total.hits;
        }
        for (const auto& [_, total] : snapshot.statuses)
        {
            damage += total.damage;
            hits += total.hits;
        }
        expect_damage(damage, snapshot.total.damage, "damage conservation");
        expect(hits == snapshot.total.hits, "hit conservation");
    }

    auto overlap_test() -> void
    {
        AttributionEventCore core{16};
        const auto pal = token(1, 7);
        const auto boss = token(2, 3);
        const auto bubble_cast = cast_token(10);
        const auto apocalypse_cast = cast_token(11);
        const auto gravity_cast = cast_token(12);
        const auto bubble_effect = token(20, 1);
        const auto apocalypse_effect = token(21, 1);
        const auto apocalypse_info = token(30, 1);
        const auto gravity_waza = token(40, 1);

        expect(core.on_cast_begin({bubble_cast, pal, token(100, 1), {}, "BubbleShower"})
            == LinkResult::linked, "BubbleShower cast link");
        expect(core.on_effect({bubble_effect, pal, bubble_cast, {}})
            == LinkResult::linked, "BubbleShower effect link");
        expect(core.on_cast_begin({apocalypse_cast, pal, token(101, 1), {}, "Apocalypse"})
            == LinkResult::linked, "Apocalypse cast link");
        expect(core.on_effect({apocalypse_effect, pal, apocalypse_cast, {}})
            == LinkResult::linked, "Apocalypse effect link");
        expect(core.on_damage_info({apocalypse_info, pal, {}, apocalypse_effect, {}})
            == LinkResult::linked, "Apocalypse DamageInfo link");
        expect(core.on_cast_begin({gravity_cast, pal, token(102, 1), gravity_waza, "GravityShot"})
            == LinkResult::linked, "GravityShot cast link");

        const auto bubble_hit_one = core.on_hit({pal, boss, bubble_effect, {}, {}, {}, 31, 160, 8});
        const auto apocalypse_hit_one = core.on_hit({pal, boss, {}, apocalypse_info, {}, {}, 101, 400, 8});
        const auto bubble_hit_two = core.on_hit({pal, boss, bubble_effect, {}, {}, {}, 29, 160, 8});
        const auto apocalypse_hit_two = core.on_hit({pal, boss, {}, apocalypse_info, {}, {}, 103, 400, 8});
        const auto gravity_hit = core.on_hit({pal, boss, {}, {}, gravity_waza, {}, 40, 40, 8});

        expect(bubble_hit_one.cast == bubble_cast && bubble_hit_two.cast == bubble_cast,
            "delayed BubbleShower hits crossed cast boundary");
        expect(apocalypse_hit_one.cast == apocalypse_cast && apocalypse_hit_two.cast == apocalypse_cast,
            "Apocalypse hits did not use exact DamageInfo");
        expect(gravity_hit.cast == gravity_cast && gravity_hit.evidence == EvidenceKind::direct_waza,
            "GravityShot direct token did not remain independent");

        const auto snapshot = core.snapshot();
        expect_total(snapshot.skills.at("BubbleShower"), 60, 2, "BubbleShower total");
        expect_total(snapshot.skills.at("Apocalypse"), 204, 2, "Apocalypse total");
        expect_total(snapshot.skills.at("GravityShot"), 40, 1, "GravityShot total");
        expect_total(snapshot.unresolved, 0, 0, "overlap unresolved total");
        expect_total(snapshot.total, 304, 5, "overlap total");
        expect_conservation(snapshot);
    }

    auto sustained_exact_overlap_test() -> void
    {
        AttributionEventCore core{32};
        const auto pal = token(201, 7);
        const auto boss = token(202, 1);
        const auto ice_cast = cast_token(210);
        const auto apocalypse_cast = cast_token(211);
        const auto gravity_cast = cast_token(212);
        const auto sand_cast = cast_token(213);
        const auto ice_effect = token(220, 1);
        const auto apocalypse_effect = token(221, 1);
        const auto sand_effect = token(222, 1);
        const auto ice_info = token(230, 1);
        const auto apocalypse_info = token(231, 1);
        const auto gravity_waza = token(240, 1);

        expect(core.on_cast_begin({ice_cast, pal, token(250, 1), {}, "IceAge"})
            == LinkResult::linked, "IceAge cast link");
        expect(core.on_effect({ice_effect, pal, ice_cast, {}})
            == LinkResult::linked, "IceAge effect link");
        expect(core.on_damage_info({ice_info, pal, {}, ice_effect, {}})
            == LinkResult::linked, "IceAge DamageInfo link");

        expect(core.on_cast_begin(
            {apocalypse_cast, pal, token(251, 1), {}, "Apocalypse"})
            == LinkResult::linked, "sustained Apocalypse cast link");
        expect(core.on_effect({apocalypse_effect, pal, apocalypse_cast, {}})
            == LinkResult::linked, "sustained Apocalypse effect link");
        expect(core.on_damage_info({apocalypse_info, pal, {}, apocalypse_effect, {}})
            == LinkResult::linked, "sustained Apocalypse DamageInfo link");

        // IceAge lands after Apocalypse starts, but its exact DamageInfo must
        // keep the delayed hit on the older IceAge cast.
        const auto ice_after_apocalypse =
            core.on_hit({pal, boss, {}, ice_info, {}, {}, 80, 160, 6});
        const auto apocalypse_first =
            core.on_hit({pal, boss, {}, apocalypse_info, {}, {}, 101, 400, 8});

        expect(core.on_cast_begin(
            {gravity_cast, pal, token(252, 1), gravity_waza, "GravityShot"})
            == LinkResult::linked, "sustained GravityShot cast link");
        const auto gravity = core.on_hit({pal, boss, {}, {}, gravity_waza, {}, 40, 40, 8});
        // Apocalypse keeps ticking after GravityShot becomes the newer cast.
        const auto apocalypse_after_gravity =
            core.on_hit({pal, boss, {}, apocalypse_info, {}, {}, 103, 400, 8});

        expect(core.on_cast_begin({sand_cast, pal, token(253, 1), {}, "SandTwister"})
            == LinkResult::linked, "SandTwister cast link");
        expect(core.on_effect({sand_effect, pal, sand_cast, {}})
            == LinkResult::linked, "SandTwister effect link");
        const auto sand = core.on_hit({pal, boss, sand_effect, {}, {}, {}, 55, 80, 3});
        // Both older sustained effects keep their original cast after
        // SandTwister starts.
        const auto ice_after_sand =
            core.on_hit({pal, boss, ice_effect, {}, {}, {}, 82, 160, 6});
        const auto apocalypse_after_sand =
            core.on_hit({pal, boss, {}, apocalypse_info, {}, {}, 107, 400, 8});

        // BasePower/element and event order alone are not exact evidence.
        const auto weak_apocalypse = core.on_hit({pal, boss, {}, {}, {}, {}, 17, 400, 8});

        expect(ice_after_apocalypse.cast == ice_cast
                && ice_after_apocalypse.evidence == EvidenceKind::damage_info,
            "IceAge delayed hit was stolen by Apocalypse");
        expect(ice_after_sand.cast == ice_cast
                && ice_after_sand.evidence == EvidenceKind::effect,
            "IceAge delayed effect was stolen by SandTwister");
        expect(apocalypse_first.cast == apocalypse_cast
                && apocalypse_after_gravity.cast == apocalypse_cast
                && apocalypse_after_sand.cast == apocalypse_cast,
            "Apocalypse tail was stolen by a newer cast");
        expect(gravity.cast == gravity_cast && gravity.evidence == EvidenceKind::direct_waza,
            "GravityShot exact token crossed into a sustained skill");
        expect(sand.cast == sand_cast && sand.evidence == EvidenceKind::effect,
            "SandTwister exact effect did not remain independent");
        expect(weak_apocalypse.kind == AttributionKind::unresolved
                && weak_apocalypse.evidence == EvidenceKind::none,
            "missing exact token guessed Apocalypse from signature/order");

        const auto snapshot = core.snapshot();
        expect_total(snapshot.skills.at("IceAge"), 162, 2, "IceAge sustained total");
        expect_total(snapshot.skills.at("Apocalypse"), 311, 3,
            "Apocalypse sustained total");
        expect_total(snapshot.skills.at("GravityShot"), 40, 1,
            "GravityShot sustained total");
        expect_total(snapshot.skills.at("SandTwister"), 55, 1,
            "SandTwister sustained total");
        expect_total(snapshot.unresolved, 17, 1, "sustained overlap unresolved total");
        expect_total(snapshot.total, 585, 8, "sustained overlap total");
        expect_conservation(snapshot);
    }

    auto same_signature_and_fail_closed_test() -> void
    {
        AttributionEventCore core;
        const auto pal = token(50, 9);
        const auto boss = token(51, 2);
        const auto cast_a = cast_token(52);
        const auto cast_b = cast_token(53);
        const auto effect_a = token(54, 1);
        const auto effect_b = token(55, 1);

        expect(core.on_cast_begin({cast_a, pal, {}, {}, "SameSignatureA"}) == LinkResult::linked,
            "same signature cast A");
        expect(core.on_cast_begin({cast_b, pal, {}, {}, "SameSignatureB"}) == LinkResult::linked,
            "same signature cast B");
        expect(core.on_effect({effect_a, pal, cast_a, {}}) == LinkResult::linked,
            "same signature effect A");
        expect(core.on_effect({effect_b, pal, cast_b, {}}) == LinkResult::linked,
            "same signature effect B");

        const auto exact_a = core.on_hit({pal, boss, effect_a, {}, {}, {}, 47, 160, 8});
        const auto exact_b = core.on_hit({pal, boss, effect_b, {}, {}, {}, 53, 160, 8});
        expect(exact_a.cast == cast_a && exact_b.cast == cast_b,
            "same BasePower/element exact links were merged");
        const auto weak = core.on_hit({pal, boss, {}, {}, {}, {}, 19, 160, 8});
        expect(weak.kind == AttributionKind::unresolved && weak.evidence == EvidenceKind::none,
            "BasePower/element guessed a certain skill");

        const auto snapshot = core.snapshot();
        expect_total(snapshot.skills.at("SameSignatureA"), 47, 1, "same signature A total");
        expect_total(snapshot.skills.at("SameSignatureB"), 53, 1, "same signature B total");
        expect_total(snapshot.unresolved, 19, 1, "weak evidence unresolved total");
        expect_total(snapshot.total, 119, 3, "same signature total");
        expect_conservation(snapshot);
    }

    auto wrapper_and_object_serial_test() -> void
    {
        AttributionEventCore core;
        const auto pal = token(60, 1);
        const auto boss = token(61, 1);
        const auto cast = cast_token(62);
        const auto effect = token(63, 1);
        const auto original = token(64, 1);
        const auto copied = token(65, 1);

        expect(core.on_cast_begin({cast, pal, {}, {}, "WrappedRain"}) == LinkResult::linked,
            "wrapper cast");
        expect(core.on_effect({effect, pal, cast, {}}) == LinkResult::linked, "wrapper effect");
        expect(core.on_damage_info({original, pal, {}, effect, {}}) == LinkResult::linked,
            "original DamageInfo");
        expect(core.on_damage_info({copied, pal, {}, {}, original}) == LinkResult::linked,
            "copied DamageInfo propagation");
        const auto propagated = core.on_hit({pal, boss, {}, copied, {}, {}, 71, 200, 4});
        expect(propagated.kind == AttributionKind::skill && propagated.cast == cast,
            "DamageInfo wrapper lost its cast");

        const auto unlinked_copy = token(66, 1);
        expect(core.on_damage_info({unlinked_copy, pal, {}, {}, {}}) == LinkResult::source_missing,
            "unlinked DamageInfo copy did not fail closed");
        const auto unlinked = core.on_hit({pal, boss, {}, unlinked_copy, {}, {}, 13, 200, 4});
        expect(unlinked.kind == AttributionKind::unresolved, "unlinked wrapper guessed a skill");

        // Same object index, different serial: the new object must not inherit
        // the destroyed object's exact link.
        const auto reused_effect_index = token(effect.index, effect.serial + 1);
        const auto reused = core.on_hit({pal, boss, reused_effect_index, {}, {}, {}, 17, 200, 4});
        expect(reused.kind == AttributionKind::unresolved,
            "object index reuse inherited the old serial's source");
        expect_conservation(core.snapshot());
    }

    auto reused_action_instance_test() -> void
    {
        AttributionEventCore core;
        const auto pal = token(67, 1);
        const auto boss = token(68, 1);
        const auto reused_action = token(69, 1);
        const auto first_cast = cast_token(6201);
        const auto second_cast = cast_token(6202);
        const auto old_effect = token(691, 1);
        const auto new_effect = token(692, 1);

        expect(core.on_cast_begin({first_cast, pal, reused_action, {}, "FirstRain"})
            == LinkResult::linked, "first reused-action cast");
        expect(core.on_effect({old_effect, pal, first_cast, {}}) == LinkResult::linked,
            "first reused-action effect");
        expect(core.on_cast_begin({second_cast, pal, reused_action, {}, "SecondRain"})
            == LinkResult::linked, "second reused-action cast");
        expect(core.on_effect({new_effect, pal, second_cast, {}}) == LinkResult::linked,
            "second reused-action effect");

        const auto delayed_old = core.on_hit({pal, boss, old_effect, {}, {}, {}, 41, 90, 4});
        const auto immediate_new = core.on_hit({pal, boss, new_effect, {}, {}, {}, 59, 90, 4});
        expect(delayed_old.cast == first_cast && immediate_new.cast == second_cast,
            "reused action UObject merged two cast generations");
        const auto snapshot = core.snapshot();
        expect_total(snapshot.skills.at("FirstRain"), 41, 1, "first reused-action total");
        expect_total(snapshot.skills.at("SecondRain"), 59, 1, "second reused-action total");
        expect_conservation(snapshot);
    }

    auto status_bucket_test() -> void
    {
        AttributionEventCore core;
        const auto pal = token(70, 1);
        const auto boss = token(71, 1);
        const auto cast = cast_token(72);
        const auto effect = token(73, 1);
        const auto poison = token(74, 1);

        expect(core.on_cast_begin({cast, pal, {}, {}, "PoisonRain"}) == LinkResult::linked,
            "status source cast");
        expect(core.on_effect({effect, pal, cast, {}}) == LinkResult::linked,
            "status source effect");
        expect(core.on_status_application({poison, pal, boss, cast, "Poison"}) == LinkResult::linked,
            "status application");

        const auto direct = core.on_hit({pal, boss, effect, {}, {}, {}, 80, 90, 4});
        const auto tick_one = core.on_hit({pal, boss, effect, {}, {}, poison, 7, 90, 4});
        const auto tick_two = core.on_hit({pal, boss, {}, {}, {}, poison, 7, 0, 4});
        expect(direct.kind == AttributionKind::skill, "direct skill damage became status");
        expect(tick_one.kind == AttributionKind::status && tick_two.kind == AttributionKind::status,
            "status ticks did not stay in independent bucket");

        const auto snapshot = core.snapshot();
        expect_total(snapshot.skills.at("PoisonRain"), 80, 1, "status skill total");
        expect_total(snapshot.statuses.at("Poison"), 14, 2, "independent Poison total");
        expect_total(snapshot.total, 94, 3, "status combined total");
        expect_conservation(snapshot);
    }

    auto conflict_and_actor_guard_test() -> void
    {
        AttributionEventCore core;
        const auto pal = token(80, 1);
        const auto other_pal = token(81, 1);
        const auto boss = token(82, 1);
        const auto cast_a = cast_token(83);
        const auto cast_b = cast_token(84);
        const auto effect_a = token(85, 1);
        const auto info_b = token(86, 1);
        expect(core.on_cast_begin({cast_a, pal, {}, {}, "SkillA"}) == LinkResult::linked,
            "conflict cast A");
        expect(core.on_cast_begin({cast_b, pal, {}, {}, "SkillB"}) == LinkResult::linked,
            "conflict cast B");
        expect(core.on_effect({effect_a, pal, cast_a, {}}) == LinkResult::linked,
            "conflict effect A");
        expect(core.on_damage_info({info_b, pal, cast_b, {}, {}}) == LinkResult::linked,
            "conflict info B");

        const auto conflict = core.on_hit({pal, boss, effect_a, info_b, {}, {}, 11, 1, 1});
        expect(conflict.kind == AttributionKind::unresolved
            && conflict.evidence == EvidenceKind::conflict,
            "conflicting exact identities did not fail closed");
        const auto mismatch = core.on_hit({other_pal, boss, effect_a, {}, {}, {}, 12, 1, 1});
        expect(mismatch.kind == AttributionKind::unresolved
            && mismatch.evidence == EvidenceKind::actor_mismatch,
            "attacker mismatch crossed Pal identity");
        expect_conservation(core.snapshot());
    }

    auto bounded_ring_test() -> void
    {
        AttributionEventCore core{3};
        const auto pal = token(90, 1);
        const auto boss = token(91, 1);
        const auto cast = cast_token(92);
        const auto effect = token(93, 1);
        expect(core.on_cast_begin({cast, pal, {}, {}, "RingSkill"}) == LinkResult::linked,
            "ring cast");
        expect(core.on_effect({effect, pal, cast, {}}) == LinkResult::linked, "ring effect");
        for (int damage = 1; damage <= 5; ++damage)
        {
            const auto hit = core.on_hit(
                {pal, boss, effect, {}, {}, {}, static_cast<double>(damage), 10, 1});
            expect(hit.kind == AttributionKind::skill, "ring fixture lost exact source");
        }

        const auto history = core.history();
        expect(history.size() == 3, "bounded history exceeded capacity");
        expect_damage(history[0].damage, 3, "ring did not retain chronological tail");
        expect_damage(history[2].damage, 5, "ring newest event mismatch");
        expect(core.history_drops() == 2, "ring drop counter mismatch");
        const auto snapshot = core.snapshot();
        expect_total(snapshot.skills.at("RingSkill"), 15, 5, "ring aggregate lost dropped detail");
        expect_total(snapshot.total, 15, 5, "ring total lost dropped detail");
        expect(snapshot.history_drops == 2, "snapshot drop counter mismatch");
        expect_conservation(snapshot);

        core.reset();
        const auto stale = core.on_hit({pal, boss, effect, {}, {}, {}, 9, 10, 1});
        expect(stale.kind == AttributionKind::unresolved, "reset retained stale effect identity");
    }
}

auto main() -> int
{
    overlap_test();
    sustained_exact_overlap_test();
    same_signature_and_fail_closed_test();
    wrapper_and_object_serial_test();
    reused_action_instance_test();
    status_bucket_test();
    conflict_and_actor_guard_test();
    bounded_ring_test();
    std::cout << "attribution event core tests passed\n";
    return 0;
}
