#pragma once

#include "AttributionEventCore.hpp"

#include <cstdint>
#include <string>

namespace pal_dps
{
    enum class FilterCallbackMatchKind : std::uint8_t
    {
        exact,
        incomplete,
        source_conflict,
        attacker_mismatch,
        defender_mismatch,
    };

    struct FilterCallbackScopeLink
    {
        ObjectToken attacker{};
        ObjectToken defender{};
        ObjectToken filter{};
        ObjectToken effect{};
        std::int64_t waza_id{};
        std::string skill_code{};
        bool source_conflicted{};

        [[nodiscard]] auto complete() const noexcept -> bool
        {
            return attacker.valid() && defender.valid() && filter.valid()
                && waza_id > 0 && !skill_code.empty();
        }
    };

    [[nodiscard]] inline auto match_filter_callback_scope(
        const FilterCallbackScopeLink& scope,
        const ObjectToken final_attacker,
        const ObjectToken final_defender
    ) noexcept -> FilterCallbackMatchKind
    {
        if (scope.source_conflicted)
        {
            return FilterCallbackMatchKind::source_conflict;
        }
        if (!scope.complete() || !final_attacker.valid() || !final_defender.valid())
        {
            return FilterCallbackMatchKind::incomplete;
        }
        if (scope.attacker != final_attacker)
        {
            return FilterCallbackMatchKind::attacker_mismatch;
        }
        if (scope.defender != final_defender)
        {
            return FilterCallbackMatchKind::defender_mismatch;
        }
        return FilterCallbackMatchKind::exact;
    }
}
