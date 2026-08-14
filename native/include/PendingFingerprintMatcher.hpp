#pragma once

#include "AttributionEventCore.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <string>
#include <utility>

namespace pal_dps
{
    enum class FingerprintValueKind : std::uint8_t
    {
        missing,
        integer,
        floating_bits,
    };

    struct FingerprintValue
    {
        FingerprintValueKind kind{FingerprintValueKind::missing};
        std::uint64_t value{};

        auto operator==(const FingerprintValue&) const -> bool = default;
    };

    enum class FingerprintField : std::size_t
    {
        base_power,
        element,
        skill,
        attack_type,
        attack_attribute,
        damage_type,
        weapon_type,
        waza,
        action,
        bullet,
        count,
    };

    struct DamageFingerprint
    {
        std::array<FingerprintValue, static_cast<std::size_t>(FingerprintField::count)> values{};
        ObjectToken damage_causer{};
        ObjectToken override_network_owner{};

        [[nodiscard]] auto scalar_count() const noexcept -> std::size_t
        {
            std::size_t result{};
            for (const auto& value : values)
            {
                if (value.kind != FingerprintValueKind::missing) ++result;
            }
            return result;
        }

        [[nodiscard]] auto has_strong_discriminator() const noexcept -> bool
        {
            // BasePower + element is deliberately insufficient. It is useful
            // telemetry, but many Pal skills share those values. A production
            // join needs at least one additional engine field or stable object.
            // Generic attack/damage/weapon attributes are shared by many
            // skills. They may participate in equality but cannot, by
            // themselves, promote a diagnostic match. Only fields that can
            // name the originating skill/action/effect make this usable.
            for (const auto field : {
                     FingerprintField::skill,
                     FingerprintField::waza,
                     FingerprintField::action,
                     FingerprintField::bullet,
                 })
            {
                if (values[static_cast<std::size_t>(field)].kind
                    != FingerprintValueKind::missing)
                {
                    return true;
                }
            }
            return damage_causer.valid();
        }

        [[nodiscard]] auto usable() const noexcept -> bool
        {
            return scalar_count() >= 2 && has_strong_discriminator();
        }

        auto operator==(const DamageFingerprint&) const -> bool = default;
    };

    struct FingerprintSource
    {
        ObjectToken action{};
        ObjectToken effect{};
        ObjectToken parent_effect{};
        ObjectToken filter{};
        CastToken cast{};
        std::int64_t waza_id{};
        std::string skill_code{};

        [[nodiscard]] auto valid() const noexcept -> bool
        {
            return effect.valid() && waza_id > 0 && !skill_code.empty();
        }

        [[nodiscard]] auto same_skill(const FingerprintSource& other) const noexcept -> bool
        {
            return waza_id == other.waza_id && skill_code == other.skill_code;
        }
    };

    enum class FingerprintMatchKind : std::uint8_t
    {
        exact,
        fingerprint_weak,
        no_candidate,
        source_ambiguous,
    };

    struct FingerprintMatch
    {
        FingerprintMatchKind kind{FingerprintMatchKind::no_candidate};
        FingerprintSource source{};
        std::size_t candidate_count{};
    };

    class PendingFingerprintMatcher
    {
      public:
        explicit PendingFingerprintMatcher(const std::size_t capacity = 32768)
            : m_capacity(capacity)
        {
        }

        [[nodiscard]] auto record(
            const ObjectToken attacker,
            const ObjectToken defender,
            DamageFingerprint fingerprint,
            FingerprintSource source
        ) -> bool
        {
            if (!attacker.valid() || !defender.valid() || !fingerprint.usable()
                || !source.valid() || m_records.size() >= m_capacity)
            {
                return false;
            }
            m_records.push_back({
                .attacker = attacker,
                .defender = defender,
                .fingerprint = std::move(fingerprint),
                .source = std::move(source),
            });
            return true;
        }

        [[nodiscard]] auto resolve(
            const ObjectToken attacker,
            const ObjectToken defender,
            const DamageFingerprint& fingerprint
        ) -> FingerprintMatch
        {
            if (!fingerprint.usable())
            {
                return {.kind = FingerprintMatchKind::fingerprint_weak};
            }

            std::size_t first_match = m_records.size();
            std::size_t candidate_count{};
            const FingerprintSource* agreed_source{};
            for (std::size_t index = 0; index < m_records.size(); ++index)
            {
                const auto& record = m_records[index];
                if (record.attacker != attacker || record.defender != defender
                    || record.fingerprint != fingerprint)
                {
                    continue;
                }
                if (first_match == m_records.size()) first_match = index;
                ++candidate_count;
                if (agreed_source == nullptr)
                {
                    agreed_source = &record.source;
                }
                else if (!agreed_source->same_skill(record.source))
                {
                    return {
                        .kind = FingerprintMatchKind::source_ambiguous,
                        .candidate_count = candidate_count,
                    };
                }
            }

            if (first_match == m_records.size())
            {
                return {.kind = FingerprintMatchKind::no_candidate};
            }

            auto source = m_records[first_match].source;
            m_records.erase(m_records.begin() + static_cast<std::ptrdiff_t>(first_match));
            return {
                .kind = FingerprintMatchKind::exact,
                .source = std::move(source),
                .candidate_count = candidate_count,
            };
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
            DamageFingerprint fingerprint{};
            FingerprintSource source{};
        };

        std::size_t m_capacity{};
        std::deque<PendingRecord> m_records{};
    };
}
