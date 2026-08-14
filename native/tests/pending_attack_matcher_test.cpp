#include "PendingAttackMatcher.hpp"

#include <cassert>
#include <cstdint>
#include <iostream>
#include <string>

namespace
{
    using pal_dps::ObjectToken;
    using pal_dps::PendingAttackMatchKind;
    using pal_dps::PendingAttackMatcher;
    using pal_dps::PendingAttackSource;

    constexpr std::uint64_t second = 1'000'000'000ULL;

    auto source(
        const std::uint32_t effect_index,
        const std::int64_t waza,
        std::string code,
        const std::uint64_t captured_ns
    ) -> PendingAttackSource
    {
        return {
            .effect = {effect_index, 1},
            .waza_id = waza,
            .skill_code = std::move(code),
            .captured_ns = captured_ns,
        };
    }
}

int main()
{
    const ObjectToken pal{10, 1};
    const ObjectToken boss{20, 1};
    const ObjectToken other_pal{11, 1};
    const ObjectToken other_boss{21, 1};

    PendingAttackMatcher matcher{8};
    assert(matcher.record(pal, boss, source(30, 187, "IceAge", second)));
    auto match = matcher.resolve(pal, boss, second + 10, second);
    assert(match.kind == PendingAttackMatchKind::single_candidate);
    assert(match.candidate_count == 1);
    assert(match.source.skill_code == "IceAge");
    assert(matcher.size() == 0);

    assert(matcher.record(pal, boss, source(31, 187, "IceAge", second)));
    assert(matcher.record(pal, boss, source(32, 187, "IceAge", second + 1)));
    match = matcher.resolve(pal, boss, second + 10, second);
    assert(match.kind == PendingAttackMatchKind::agreed_candidate);
    assert(match.candidate_count == 2);
    assert(match.source.skill_code == "IceAge");
    assert(!match.source.effect.valid());

    assert(matcher.record(pal, boss, source(33, 187, "IceAge", second)));
    assert(matcher.record(pal, boss, source(34, 300, "Apocalypse", second + 1)));
    match = matcher.resolve(pal, boss, second + 10, second);
    assert(match.kind == PendingAttackMatchKind::source_ambiguous);
    assert(match.candidate_count == 2);
    assert(matcher.size() == 0);

    assert(matcher.record(pal, boss, source(35, 187, "IceAge", second)));
    assert(matcher.record(pal, other_boss, source(36, 300, "Apocalypse", second)));
    assert(matcher.record(other_pal, boss, source(37, 137, "GravityShot", second)));
    match = matcher.resolve(pal, boss, second + 10, second);
    assert(match.kind == PendingAttackMatchKind::single_candidate);
    assert(match.source.skill_code == "IceAge");
    assert(matcher.size() == 2);

    match = matcher.resolve(pal, other_boss, second + 10, second);
    assert(match.kind == PendingAttackMatchKind::single_candidate);
    assert(match.source.skill_code == "Apocalypse");
    match = matcher.resolve(other_pal, boss, second + 10, second);
    assert(match.kind == PendingAttackMatchKind::single_candidate);
    assert(match.source.skill_code == "GravityShot");

    assert(matcher.record(pal, boss, source(38, 187, "IceAge", second)));
    match = matcher.resolve(pal, boss, 3 * second, second / 2);
    assert(match.kind == PendingAttackMatchKind::no_candidate);
    assert(match.expired_count == 1);

    assert(matcher.record(pal, boss, source(39, 187, "IceAge", second)));
    match = matcher.resolve({pal.index, 2}, boss, second + 10, second);
    assert(match.kind == PendingAttackMatchKind::no_candidate);
    matcher.reset();
    assert(matcher.size() == 0);

    PendingAttackMatcher bounded{1};
    assert(bounded.record(pal, boss, source(40, 187, "IceAge", second)));
    assert(!bounded.record(pal, boss, source(41, 187, "IceAge", second)));

    std::cout << "pending attack matcher tests passed\n";
    return 0;
}
