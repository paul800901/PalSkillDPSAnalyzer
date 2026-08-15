#pragma once

#include "NativeEventQueue.hpp"
#include "PendingAttackMatcher.hpp"

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <optional>
#include <utility>
#include <vector>

namespace pal_dps
{
    enum class PendingFinalDamageMatchKind : std::uint8_t
    {
        no_pending,
        unique_pending,
        pending_ambiguous,
    };

    struct PendingFinalDamageMatch
    {
        PendingFinalDamageMatchKind kind{PendingFinalDamageMatchKind::no_pending};
        std::optional<NativeEvent> matched{};
        std::vector<NativeEvent> released{};
        std::size_t candidate_count{};
        std::size_t expired_count{};
        std::size_t pair_expired_count{};
    };

    // Some Pal skills report final ActualDamage before their Blueprint
    // OnAttack notification. Hold only unresolved final events, then permit a
    // reverse link when exactly one event exists for the exact attacker and
    // defender identity. Time only expires records; it never ranks candidates.
    class PendingFinalDamageMatcher
    {
      public:
        explicit PendingFinalDamageMatcher(const std::size_t capacity = 32768)
            : m_capacity(capacity)
        {
        }

        [[nodiscard]] auto record(NativeEvent event) -> bool
        {
            if (event.kind != NativeEventKind::final_damage
                || !event.attacker.valid() || !event.defender.valid()
                || event.captured_ns == 0 || !std::isfinite(event.damage)
                || event.damage <= 0.0 || event.hits == 0
                || m_records.size() >= m_capacity)
            {
                return false;
            }
            m_records.push_back(std::move(event));
            return true;
        }

        [[nodiscard]] auto resolve(
            const ObjectToken attacker,
            const ObjectToken defender,
            const PendingAttackSource& source,
            const std::uint64_t now_ns,
            const std::uint64_t maximum_age_ns
        ) -> PendingFinalDamageMatch
        {
            PendingFinalDamageMatch result{};
            expire_into(result, attacker, defender, now_ns, maximum_age_ns);
            if (!attacker.valid() || !defender.valid() || !source.valid())
            {
                return result;
            }

            std::vector<NativeEvent> candidates{};
            for (auto iterator = m_records.begin(); iterator != m_records.end();)
            {
                if (iterator->attacker != attacker || iterator->defender != defender)
                {
                    ++iterator;
                    continue;
                }
                candidates.push_back(std::move(*iterator));
                iterator = m_records.erase(iterator);
            }
            result.candidate_count = candidates.size();
            if (candidates.empty())
            {
                return result;
            }
            if (candidates.size() == 1)
            {
                result.kind = PendingFinalDamageMatchKind::unique_pending;
                result.matched.emplace(std::move(candidates.front()));
                return result;
            }

            result.kind = PendingFinalDamageMatchKind::pending_ambiguous;
            result.released = std::move(candidates);
            return result;
        }

        [[nodiscard]] auto flush_expired(
            const std::uint64_t now_ns,
            const std::uint64_t maximum_age_ns
        ) -> std::vector<NativeEvent>
        {
            PendingFinalDamageMatch result{};
            expire_into(result, {}, {}, now_ns, maximum_age_ns);
            return std::move(result.released);
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
        auto expire_into(
            PendingFinalDamageMatch& result,
            const ObjectToken pair_attacker,
            const ObjectToken pair_defender,
            const std::uint64_t now_ns,
            const std::uint64_t maximum_age_ns
        ) -> void
        {
            for (auto iterator = m_records.begin(); iterator != m_records.end();)
            {
                const auto stale = now_ns >= iterator->captured_ns
                    && now_ns - iterator->captured_ns > maximum_age_ns;
                if (!stale)
                {
                    ++iterator;
                    continue;
                }
                if (pair_attacker.valid() && pair_defender.valid()
                    && iterator->attacker == pair_attacker
                    && iterator->defender == pair_defender)
                {
                    ++result.pair_expired_count;
                }
                result.released.push_back(std::move(*iterator));
                iterator = m_records.erase(iterator);
                ++result.expired_count;
            }
        }

        std::size_t m_capacity{};
        std::deque<NativeEvent> m_records{};
    };
}
