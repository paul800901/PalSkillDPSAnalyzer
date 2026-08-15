#include "PendingFingerprintMatcher.hpp"

#include <cstdlib>
#include <iostream>
#include <string_view>

namespace
{
    using namespace pal_dps;

    [[noreturn]] auto fail(const std::string_view message) -> void
    {
        std::cerr << "FAILED: " << message << '\n';
        std::exit(1);
    }

    auto expect(const bool condition, const std::string_view message) -> void
    {
        if (!condition) fail(message);
    }

    auto value(const std::uint64_t input) -> FingerprintValue
    {
        return {.kind = FingerprintValueKind::integer, .value = input};
    }

    auto fingerprint(const std::uint64_t power, const std::uint64_t element,
                     const std::uint64_t bullet) -> DamageFingerprint
    {
        DamageFingerprint result{};
        result.values[static_cast<std::size_t>(FingerprintField::base_power)] = value(power);
        result.values[static_cast<std::size_t>(FingerprintField::element)] = value(element);
        result.values[static_cast<std::size_t>(FingerprintField::bullet)] = value(bullet);
        return result;
    }

    auto source(const std::uint64_t cast, const std::uint32_t effect,
                const std::int64_t waza, std::string code) -> FingerprintSource
    {
        return {
            .effect = {effect, 1},
            .cast = {cast},
            .waza_id = waza,
            .skill_code = std::move(code),
        };
    }
}

auto main() -> int
{
    const ObjectToken pal{10, 1};
    const ObjectToken boss{20, 1};

    {
        PendingFingerprintMatcher matcher{};
        const auto rain = fingerprint(600, 6, 4101);
        expect(matcher.record(pal, boss, rain, source(1, 101, 12, "DiamondFall")),
            "exact record rejected");
        const auto match = matcher.resolve(pal, boss, rain);
        expect(match.kind == FingerprintMatchKind::exact
            && match.source.skill_code == "DiamondFall" && matcher.size() == 0,
            "exact fingerprint did not resolve and consume once");
    }

    {
        PendingFingerprintMatcher matcher{};
        DamageFingerprint weak{};
        weak.values[static_cast<std::size_t>(FingerprintField::base_power)] = value(600);
        weak.values[static_cast<std::size_t>(FingerprintField::element)] = value(6);
        expect(!weak.usable(), "BasePower + element became strong evidence");
        expect(!matcher.record(pal, boss, weak, source(1, 101, 12, "DiamondFall")),
            "weak signature entered pending source ledger");
        expect(matcher.resolve(pal, boss, weak).kind
                == FingerprintMatchKind::fingerprint_weak,
            "weak signature did not fail closed");

        weak.values[static_cast<std::size_t>(FingerprintField::attack_type)] = value(3);
        weak.values[static_cast<std::size_t>(FingerprintField::damage_type)] = value(5);
        expect(!weak.usable(),
            "generic attack/damage attributes became confirming evidence");
    }

    {
        PendingFingerprintMatcher matcher{};
        const auto shared = fingerprint(160, 8, 7000);
        expect(matcher.record(pal, boss, shared, source(1, 101, 165, "Apocalypse")),
            "ambiguous record A rejected");
        expect(matcher.record(pal, boss, shared, source(2, 102, 174, "SandTwister")),
            "ambiguous record B rejected");
        const auto match = matcher.resolve(pal, boss, shared);
        expect(match.kind == FingerprintMatchKind::source_ambiguous && matcher.size() == 2,
            "different skills with the same fingerprint were guessed or consumed");
    }

    {
        PendingFingerprintMatcher matcher{};
        const auto repeated = fingerprint(160, 8, 7001);
        expect(matcher.record(pal, boss, repeated, source(1, 101, 165, "Apocalypse")),
            "same-skill record A rejected");
        expect(matcher.record(pal, boss, repeated, source(2, 102, 165, "Apocalypse")),
            "same-skill record B rejected");
        const auto first = matcher.resolve(pal, boss, repeated);
        const auto second = matcher.resolve(pal, boss, repeated);
        expect(first.kind == FingerprintMatchKind::exact
            && second.kind == FingerprintMatchKind::exact && matcher.size() == 0,
            "repeated casts of the same skill were not consumed one-for-one");
    }

    {
        PendingFingerprintMatcher matcher{1};
        const auto exact = fingerprint(450, 6, 9001);
        expect(matcher.record(pal, boss, exact, source(1, 101, 10, "IcicleThrow")),
            "capacity fixture first record rejected");
        expect(!matcher.record(pal, boss, exact, source(2, 102, 10, "IcicleThrow")),
            "capacity overflow was silently accepted");
        matcher.reset();
        expect(matcher.size() == 0, "reset did not clear pending fingerprint records");
    }

    std::cout << "pending fingerprint matcher tests passed\n";
    return 0;
}
