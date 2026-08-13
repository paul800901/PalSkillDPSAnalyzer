#pragma once

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace pal_dps
{
    // An Unreal object index alone can be reused after destruction. The serial
    // is therefore part of every identity used by this core.
    struct ObjectToken
    {
        std::uint32_t index{};
        std::uint32_t serial{};

        [[nodiscard]] constexpr auto valid() const noexcept -> bool
        {
            return serial != 0;
        }

        auto operator==(const ObjectToken&) const -> bool = default;
    };

    struct ObjectTokenHash
    {
        [[nodiscard]] auto operator()(const ObjectToken& token) const noexcept -> std::size_t
        {
            const auto high = static_cast<std::uint64_t>(token.index) << 32U;
            const auto low = static_cast<std::uint64_t>(token.serial);
            return std::hash<std::uint64_t>{}(high | low);
        }
    };

    // A cast is an occurrence, not an Unreal object. Palworld can reuse the
    // same action UObject for later activations, so UObject identity alone
    // would merge delayed effects from different casts. The native bridge
    // assigns a new monotonically increasing value for every cast begin.
    struct CastToken
    {
        std::uint64_t value{};

        [[nodiscard]] constexpr auto valid() const noexcept -> bool
        {
            return value != 0;
        }

        auto operator==(const CastToken&) const -> bool = default;
    };

    struct CastTokenHash
    {
        [[nodiscard]] auto operator()(const CastToken& token) const noexcept -> std::size_t
        {
            return std::hash<std::uint64_t>{}(token.value);
        }
    };

    enum class LinkResult
    {
        linked,
        invalid_identity,
        identity_reused,
        source_missing,
        source_conflict,
        actor_mismatch,
        target_mismatch,
    };

    enum class AttributionKind
    {
        skill,
        status,
        unresolved,
    };

    enum class EvidenceKind
    {
        damage_info,
        effect,
        direct_waza,
        status_application,
        none,
        conflict,
        actor_mismatch,
        target_mismatch,
    };

    struct CastBegin
    {
        CastToken cast{};
        ObjectToken attacker{};
        ObjectToken action_instance{};
        ObjectToken direct_waza_token{};
        std::string skill_code{};
    };

    struct EffectLink
    {
        ObjectToken effect{};
        ObjectToken attacker{};
        CastToken cast{};
        ObjectToken parent_effect{};
    };

    struct DamageInfoLink
    {
        ObjectToken damage_info{};
        ObjectToken attacker{};
        CastToken cast{};
        ObjectToken effect{};
        ObjectToken parent_damage_info{};
    };

    struct StatusApplication
    {
        ObjectToken application{};
        ObjectToken attacker{};
        ObjectToken defender{};
        CastToken source_cast{};
        std::string status_code{};
    };

    struct FinalHit
    {
        ObjectToken attacker{};
        ObjectToken defender{};
        ObjectToken effect{};
        ObjectToken damage_info{};
        ObjectToken direct_waza_token{};
        ObjectToken status_application{};
        double damage{};

        // Diagnostic values are intentionally never used as identities.
        double base_power{};
        std::int32_t element{};
    };

    struct AttributedHit
    {
        AttributionKind kind{AttributionKind::unresolved};
        EvidenceKind evidence{EvidenceKind::none};
        CastToken cast{};
        std::string bucket{};
        double damage{};
    };

    struct DamageTotal
    {
        double damage{};
        std::uint64_t hits{};
    };

    struct Snapshot
    {
        DamageTotal total{};
        DamageTotal unresolved{};
        std::unordered_map<std::string, DamageTotal> skills{};
        std::unordered_map<std::string, DamageTotal> statuses{};
        std::uint64_t history_drops{};
    };

    class AttributionEventCore
    {
    public:
        explicit AttributionEventCore(const std::size_t history_capacity = 4096)
            : m_history(history_capacity)
        {
        }

        auto reset() -> void
        {
            m_casts.clear();
            m_effects.clear();
            m_damage_infos.clear();
            m_waza_tokens.clear();
            m_statuses.clear();
            m_skill_totals.clear();
            m_status_totals.clear();
            m_total = {};
            m_unresolved = {};
            m_history_start = 0;
            m_history_size = 0;
            m_history_drops = 0;
        }

        [[nodiscard]] auto on_cast_begin(const CastBegin& event) -> LinkResult
        {
            if (!event.cast.valid() || !event.attacker.valid() || event.skill_code.empty())
            {
                return LinkResult::invalid_identity;
            }
            if (m_casts.contains(event.cast))
            {
                return LinkResult::identity_reused;
            }
            if (event.direct_waza_token.valid() && m_waza_tokens.contains(event.direct_waza_token))
            {
                return LinkResult::identity_reused;
            }

            m_casts.emplace(event.cast, CastRecord{event.attacker, event.action_instance, event.skill_code});
            if (event.direct_waza_token.valid())
            {
                m_waza_tokens.emplace(event.direct_waza_token, event.cast);
            }
            return LinkResult::linked;
        }

        [[nodiscard]] auto on_effect(const EffectLink& event) -> LinkResult
        {
            if (!event.effect.valid()) return LinkResult::invalid_identity;
            if (m_effects.contains(event.effect)) return LinkResult::identity_reused;

            const auto resolution = resolve_cast(event.cast, lookup(m_effects, event.parent_effect));
            if (resolution.result != LinkResult::linked) return resolution.result;
            if (!attacker_matches(resolution.cast, event.attacker)) return LinkResult::actor_mismatch;
            m_effects.emplace(event.effect, resolution.cast);
            return LinkResult::linked;
        }

        [[nodiscard]] auto on_damage_info(const DamageInfoLink& event) -> LinkResult
        {
            if (!event.damage_info.valid()) return LinkResult::invalid_identity;
            if (m_damage_infos.contains(event.damage_info)) return LinkResult::identity_reused;

            const auto direct = lookup(m_casts, event.cast).has_value()
                ? std::optional<CastToken>{event.cast}
                : std::nullopt;
            const auto effect = lookup(m_effects, event.effect);
            const auto parent = lookup(m_damage_infos, event.parent_damage_info);
            const auto resolution = resolve_casts(direct, effect, parent);
            if (resolution.result != LinkResult::linked) return resolution.result;
            if (!attacker_matches(resolution.cast, event.attacker)) return LinkResult::actor_mismatch;
            m_damage_infos.emplace(event.damage_info, resolution.cast);
            return LinkResult::linked;
        }

        [[nodiscard]] auto on_status_application(const StatusApplication& event) -> LinkResult
        {
            if (!event.application.valid() || !event.attacker.valid() || !event.defender.valid()
                || event.status_code.empty())
            {
                return LinkResult::invalid_identity;
            }
            if (m_statuses.contains(event.application)) return LinkResult::identity_reused;
            if (event.source_cast.valid())
            {
                const auto cast = m_casts.find(event.source_cast);
                if (cast == m_casts.end()) return LinkResult::source_missing;
                if (cast->second.attacker != event.attacker) return LinkResult::actor_mismatch;
            }
            m_statuses.emplace(event.application, StatusRecord{
                event.attacker, event.defender, event.source_cast, event.status_code});
            return LinkResult::linked;
        }

        [[nodiscard]] auto on_hit(const FinalHit& event) -> AttributedHit
        {
            AttributedHit result{};
            result.damage = event.damage;
            if (!valid_damage(event.damage) || !event.attacker.valid() || !event.defender.valid())
            {
                result.evidence = EvidenceKind::none;
                return result;
            }

            if (event.status_application.valid())
            {
                const auto status_it = m_statuses.find(event.status_application);
                if (status_it == m_statuses.end())
                {
                    result.evidence = EvidenceKind::none;
                }
                else if (status_it->second.attacker != event.attacker)
                {
                    result.evidence = EvidenceKind::actor_mismatch;
                }
                else if (status_it->second.defender != event.defender)
                {
                    result.evidence = EvidenceKind::target_mismatch;
                }
                else
                {
                    result.kind = AttributionKind::status;
                    result.evidence = EvidenceKind::status_application;
                    result.cast = status_it->second.source_cast;
                    result.bucket = status_it->second.status_code;
                }
                aggregate_and_record(result);
                return result;
            }

            const auto damage_info = lookup(m_damage_infos, event.damage_info);
            const auto effect = lookup(m_effects, event.effect);
            const auto direct_waza = lookup(m_waza_tokens, event.direct_waza_token);
            const auto resolution = resolve_casts(damage_info, effect, direct_waza);
            if (resolution.result == LinkResult::source_conflict)
            {
                result.evidence = EvidenceKind::conflict;
            }
            else if (resolution.result == LinkResult::linked
                && !attacker_matches(resolution.cast, event.attacker))
            {
                result.evidence = EvidenceKind::actor_mismatch;
            }
            else if (resolution.result == LinkResult::linked)
            {
                const auto cast_it = m_casts.find(resolution.cast);
                if (cast_it != m_casts.end())
                {
                    result.kind = AttributionKind::skill;
                    result.cast = resolution.cast;
                    result.bucket = cast_it->second.skill_code;
                    result.evidence = damage_info.has_value() ? EvidenceKind::damage_info
                        : effect.has_value() ? EvidenceKind::effect
                        : EvidenceKind::direct_waza;
                }
            }
            aggregate_and_record(result);
            return result;
        }

        [[nodiscard]] auto snapshot() const -> Snapshot
        {
            return Snapshot{m_total, m_unresolved, m_skill_totals, m_status_totals, m_history_drops};
        }

        [[nodiscard]] auto history() const -> std::vector<AttributedHit>
        {
            std::vector<AttributedHit> result;
            result.reserve(m_history_size);
            if (m_history.empty()) return result;
            for (std::size_t offset = 0; offset < m_history_size; ++offset)
            {
                result.push_back(m_history[(m_history_start + offset) % m_history.size()]);
            }
            return result;
        }

        [[nodiscard]] auto history_drops() const noexcept -> std::uint64_t
        {
            return m_history_drops;
        }

    private:
        struct CastRecord
        {
            ObjectToken attacker{};
            ObjectToken action_instance{};
            std::string skill_code{};
        };

        struct StatusRecord
        {
            ObjectToken attacker{};
            ObjectToken defender{};
            CastToken source_cast{};
            std::string status_code{};
        };

        struct CastResolution
        {
            CastToken cast{};
            LinkResult result{LinkResult::source_missing};
        };

        template <typename Key, typename Value, typename Hash>
        [[nodiscard]] static auto lookup(
            const std::unordered_map<Key, Value, Hash>& source,
            const Key token) -> std::optional<Value>
        {
            if (!token.valid()) return std::nullopt;
            const auto it = source.find(token);
            if (it == source.end()) return std::nullopt;
            return it->second;
        }

        [[nodiscard]] auto attacker_matches(
            const CastToken cast, const ObjectToken attacker) const -> bool
        {
            if (!attacker.valid()) return true;
            const auto it = m_casts.find(cast);
            return it != m_casts.end() && it->second.attacker == attacker;
        }

        [[nodiscard]] auto resolve_cast(
            const CastToken direct_cast,
            const std::optional<CastToken> inherited_cast) const -> CastResolution
        {
            const auto direct = lookup(m_casts, direct_cast).has_value()
                ? std::optional<CastToken>{direct_cast}
                : std::nullopt;
            return resolve_casts(direct, inherited_cast, std::nullopt);
        }

        [[nodiscard]] static auto resolve_casts(
            const std::optional<CastToken> first,
            const std::optional<CastToken> second,
            const std::optional<CastToken> third) -> CastResolution
        {
            std::optional<CastToken> selected;
            for (const auto candidate : {first, second, third})
            {
                if (!candidate.has_value()) continue;
                if (selected.has_value() && *selected != *candidate)
                {
                    return {{}, LinkResult::source_conflict};
                }
                selected = candidate;
            }
            return selected.has_value()
                ? CastResolution{*selected, LinkResult::linked}
                : CastResolution{{}, LinkResult::source_missing};
        }

        [[nodiscard]] static auto valid_damage(const double damage) noexcept -> bool
        {
            return std::isfinite(damage) && damage > 0.0;
        }

        static auto add(DamageTotal& total, const double damage) -> void
        {
            total.damage += damage;
            ++total.hits;
        }

        auto aggregate_and_record(const AttributedHit& hit) -> void
        {
            add(m_total, hit.damage);
            if (hit.kind == AttributionKind::skill)
            {
                add(m_skill_totals[hit.bucket], hit.damage);
            }
            else if (hit.kind == AttributionKind::status)
            {
                add(m_status_totals[hit.bucket], hit.damage);
            }
            else
            {
                add(m_unresolved, hit.damage);
            }

            if (m_history.empty())
            {
                ++m_history_drops;
                return;
            }
            if (m_history_size < m_history.size())
            {
                const auto index = (m_history_start + m_history_size) % m_history.size();
                m_history[index] = hit;
                ++m_history_size;
                return;
            }
            m_history[m_history_start] = hit;
            m_history_start = (m_history_start + 1) % m_history.size();
            ++m_history_drops;
        }

        std::unordered_map<CastToken, CastRecord, CastTokenHash> m_casts{};
        std::unordered_map<ObjectToken, CastToken, ObjectTokenHash> m_effects{};
        std::unordered_map<ObjectToken, CastToken, ObjectTokenHash> m_damage_infos{};
        std::unordered_map<ObjectToken, CastToken, ObjectTokenHash> m_waza_tokens{};
        std::unordered_map<ObjectToken, StatusRecord, ObjectTokenHash> m_statuses{};
        std::unordered_map<std::string, DamageTotal> m_skill_totals{};
        std::unordered_map<std::string, DamageTotal> m_status_totals{};
        DamageTotal m_total{};
        DamageTotal m_unresolved{};
        std::vector<AttributedHit> m_history{};
        std::size_t m_history_start{};
        std::size_t m_history_size{};
        std::uint64_t m_history_drops{};
    };
}
