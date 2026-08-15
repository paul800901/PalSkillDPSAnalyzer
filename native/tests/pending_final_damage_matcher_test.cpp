#include "PendingFinalDamageMatcher.hpp"

#include <cassert>
#include <cmath>
#include <iostream>

namespace
{
    using pal_dps::NativeEvent;
    using pal_dps::NativeEventKind;
    using pal_dps::ObjectToken;
    using pal_dps::PendingAttackSource;
    using pal_dps::PendingFinalDamageMatchKind;
    using pal_dps::PendingFinalDamageMatcher;

    auto make_event(
        const ObjectToken attacker,
        const ObjectToken defender,
        const double damage,
        const std::uint64_t captured_ns
    ) -> NativeEvent
    {
        NativeEvent event{};
        event.kind = NativeEventKind::final_damage;
        event.attacker = attacker;
        event.defender = defender;
        event.damage = damage;
        event.hits = 1;
        event.captured_ns = captured_ns;
        event.evidence_kind.assign("unresolved");
        return event;
    }

    auto make_source(const std::uint64_t captured_ns) -> PendingAttackSource
    {
        return {
            .effect = {30, 1},
            .filter = {31, 1},
            .waza_id = 187,
            .skill_code = "IceAge",
            .captured_ns = captured_ns,
        };
    }

    auto unique_pair_test() -> void
    {
        const ObjectToken attacker{1, 1};
        const ObjectToken defender{2, 1};
        const ObjectToken other_defender{3, 1};
        PendingFinalDamageMatcher matcher{8};
        assert(matcher.record(make_event(attacker, defender, 9346.0, 100)));
        assert(matcher.record(make_event(attacker, other_defender, 55.0, 101)));

        const auto match = matcher.resolve(
            attacker, defender, make_source(120), 120, 1000
        );
        assert(match.kind == PendingFinalDamageMatchKind::unique_pending);
        assert(match.matched.has_value());
        assert(std::abs(match.matched->damage - 9346.0) < 0.001);
        assert(match.candidate_count == 1);
        assert(matcher.size() == 1);
    }

    auto ambiguous_pair_conserves_damage_test() -> void
    {
        const ObjectToken attacker{1, 1};
        const ObjectToken defender{2, 1};
        PendingFinalDamageMatcher matcher{8};
        assert(matcher.record(make_event(attacker, defender, 3000.0, 100)));
        assert(matcher.record(make_event(attacker, defender, 9000.0, 101)));
        const auto match = matcher.resolve(
            attacker, defender, make_source(120), 120, 1000
        );
        assert(match.kind == PendingFinalDamageMatchKind::pending_ambiguous);
        assert(match.candidate_count == 2);
        assert(match.released.size() == 2);
        const auto damage = match.released[0].damage + match.released[1].damage;
        const auto hits = match.released[0].hits + match.released[1].hits;
        assert(std::abs(damage - 12000.0) < 0.001);
        assert(hits == 2);
        assert(matcher.size() == 0);
    }

    auto identity_and_expiry_test() -> void
    {
        const ObjectToken attacker{1, 1};
        const ObjectToken defender{2, 1};
        PendingFinalDamageMatcher matcher{8};
        assert(matcher.record(make_event(attacker, defender, 1477.0, 100)));
        const auto wrong_serial = matcher.resolve(
            {1, 2}, defender, make_source(150), 150, 1000
        );
        assert(wrong_serial.kind == PendingFinalDamageMatchKind::no_pending);
        assert(matcher.size() == 1);

        const auto expired = matcher.resolve(
            attacker, defender, make_source(2000), 2000, 1000
        );
        assert(expired.kind == PendingFinalDamageMatchKind::no_pending);
        assert(expired.expired_count == 1);
        assert(expired.pair_expired_count == 1);
        assert(expired.released.size() == 1);
        assert(std::abs(expired.released.front().damage - 1477.0) < 0.001);
    }

    auto capacity_and_damage_independence_test() -> void
    {
        const ObjectToken attacker{1, 1};
        const ObjectToken defender{2, 1};
        PendingFinalDamageMatcher matcher{1};
        assert(matcher.record(make_event(attacker, defender, 1.0, 100)));
        assert(!matcher.record(make_event(attacker, defender, 999999.0, 101)));
        const auto match = matcher.resolve(
            attacker, defender, make_source(120), 120, 1000
        );
        assert(match.kind == PendingFinalDamageMatchKind::unique_pending);
        assert(std::abs(match.matched->damage - 1.0) < 0.001);
    }
}

int main()
{
    unique_pair_test();
    ambiguous_pair_conserves_damage_test();
    identity_and_expiry_test();
    capacity_and_damage_independence_test();
    std::cout << "pending final damage matcher tests passed\n";
    return 0;
}
