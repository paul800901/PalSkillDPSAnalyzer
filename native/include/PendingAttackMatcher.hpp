#pragma once

#include "AttributionEventCore.hpp"

#include <cstddef>
#include <cstdint>
#include <deque>
#include <string>
#include <utility>

namespace pal_dps
{
    struct PendingAttackSource
    {
        ObjectToken action{};
        ObjectToken effect{};
        ObjectToken parent_effect{};
        ObjectToken filter{};
        CastToken cast{};
        std::int64_t waza_id{};
        std::string skill_code{};
        std::uint64_t captured_ns{};

        [[nodiscard]] auto valid() const noexcept -> bool
        {
            return effect.valid() && waza_id > 0 && !skill_code.empty()
                && captured_ns > 0;
        }

        [[nodiscard]] auto same_skill(const PendingAttackSource& other) const noexcept -> bool
        {
            return waza_id == other.waza_id && skill_code == other.skill_code;
        }
    };

    enum class PendingAttackMatchKind : std::uint8_t
    {
        single_candidate,
        agreed_candidate,
        no_candidate,
        source_ambiguous,
    };

    struct PendingAttackMatch
    {
        PendingAttackMatchKind kind{PendingAttackMatchKind::no_candidate};
        PendingAttackSource source{};
        std::size_t candidate_count{};
        std::size_t expired_count{};
    };

    // OnAttack and final OnDamage are separate Palworld callbacks. This matcher
    // bridges only engine-observed events for the exact attacker/defender pair.
    // Time is used exclusively to discard stale records, never to choose a
    // skill. A mixed-skill batch fails closed and is consumed as ambiguous.
    class PendingAttackMatcher
    {
      public:
        explicit PendingAttackMatcher(const std::size_t capacity = 32768)
            : m_capacity(capacity)
        {
        }

        [[nodiscard]] auto record(
            const ObjectToken attacker,
            const ObjectToken defender,
            PendingAttackSource source
        ) -> bool
        {
            if (!attacker.valid() || !defender.valid() || !source.valid()
                || m_records.size() >= m_capacity)
            {
                return false;
            }
            m_records.push_back({
                .attacker = attacker,
                .defender = defender,
                .source = std::move(source),
            });
            return true;
        }

        [[nodiscard]] auto resolve(
            const ObjectToken attacker,
            const ObjectToken defender,
            const std::uint64_t now_ns,
            const std::uint64_t maximum_age_ns
        ) -> PendingAttackMatch
        {
            PendingAttackMatch result{};
            for (auto iterator = m_records.begin(); iterator != m_records.end();)
            {
                const auto stale = now_ns >= iterator->source.captured_ns
                    && now_ns - iterator->source.captured_ns > maximum_age_ns;
                if (stale)
                {
                    iterator = m_records.erase(iterator);
                    ++result.expired_count;
                    continue;
                }
                ++iterator;
            }

            bool has_source{};
            bool ambiguous{};
            for (auto iterator = m_records.begin(); iterator != m_records.end();)
            {
                if (iterator->attacker != attacker || iterator->defender != defender)
                {
                    ++iterator;
                    continue;
                }

                ++result.candidate_count;
                if (!has_source)
                {
                    result.source = iterator->source;
                    has_source = true;
                }
                else if (!result.source.same_skill(iterator->source))
                {
                    ambiguous = true;
                }
                else if (result.source.action != iterator->source.action
                         || result.source.effect != iterator->source.effect
                         || result.source.parent_effect != iterator->source.parent_effect
                         || result.source.filter != iterator->source.filter
                         || result.source.cast != iterator->source.cast)
                {
                    // Multiple effects can legitimately report the same Waza.
                    // Skill identity agrees, but no individual object/cast may
                    // be claimed as the unique source of the final hit.
                    result.source.action = {};
                    result.source.effect = {};
                    result.source.parent_effect = {};
                    result.source.filter = {};
                    result.source.cast = {};
                }
                iterator = m_records.erase(iterator);
            }

            if (!has_source)
            {
                result.kind = PendingAttackMatchKind::no_candidate;
            }
            else if (ambiguous)
            {
                result.kind = PendingAttackMatchKind::source_ambiguous;
                result.source = {};
            }
            else if (result.candidate_count == 1)
            {
                result.kind = PendingAttackMatchKind::single_candidate;
            }
            else
            {
                result.kind = PendingAttackMatchKind::agreed_candidate;
            }
            return result;
        }

        auto reset() -> void
        {
            m_records.clear();
        }

        [[nodiscard]] auto size() const noexcept -> std::size_t
        {
            return m_records.size();
        }

      private:
        struct PendingRecord
        {
            ObjectToken attacker{};
            ObjectToken defender{};
            PendingAttackSource source{};
        };

        std::size_t m_capacity{};
        std::deque<PendingRecord> m_records{};
    };
}
