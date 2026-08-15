#pragma once

#include "AttributionEventCore.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string_view>

namespace pal_dps
{
    enum class NativeEventKind : std::uint8_t
    {
        cast_begin,
        cast_end,
        effect_initialize,
        effect_link,
        damage_info_link,
        status_application,
        final_damage,
    };

    template <std::size_t Capacity>
    class FixedText
    {
    public:
        auto assign(const std::string_view value) noexcept -> void
        {
            m_size = std::min(value.size(), Capacity);
            m_truncated = value.size() > Capacity;
            std::copy_n(value.data(), m_size, m_data.data());
        }

        [[nodiscard]] auto view() const noexcept -> std::string_view
        {
            return {m_data.data(), m_size};
        }

        [[nodiscard]] auto truncated() const noexcept -> bool
        {
            return m_truncated;
        }

    private:
        std::array<char, Capacity> m_data{};
        std::size_t m_size{};
        bool m_truncated{};
    };

    struct NativeEvent
    {
        NativeEventKind kind{NativeEventKind::final_damage};
        std::uint64_t sequence{};
        std::uint64_t captured_ns{};
        ObjectToken attacker{};
        ObjectToken defender{};
        ObjectToken action{};
        CastToken cast{};
        ObjectToken effect{};
        ObjectToken parent_effect{};
        ObjectToken filter{};
        ObjectToken damage_info{};
        ObjectToken parent_damage_info{};
        ObjectToken direct_waza_token{};
        ObjectToken status_application{};
        ObjectToken damage_causer{};
        ObjectToken override_network_owner{};
        ObjectToken info_attacker{};
        std::int64_t waza_id{};
        double damage{};
        std::uint64_t hits{1};
        FixedText<96> skill_code{};
        FixedText<64> status_code{};
        FixedText<64> evidence_kind{};
    };

    struct NativeEventQueueStats
    {
        std::uint64_t next_sequence{1};
        std::uint64_t accepted{};
        std::uint64_t drained{};
        std::uint64_t dropped{};
        std::size_t pending{};
        bool overflowed{};
    };

    // Hook callbacks may run on loading threads. This queue deliberately uses
    // one short critical section and a bounded deque so that sequence order,
    // overflow detection, and fail-closed behavior remain deterministic.
    class NativeEventQueue
    {
    public:
        explicit NativeEventQueue(const std::size_t capacity = 16384)
            : m_capacity(capacity)
        {
        }

        [[nodiscard]] auto enqueue(NativeEvent event) -> bool
        {
            std::scoped_lock lock{m_mutex};
            event.sequence = m_next_sequence++;
            if (m_events.size() >= m_capacity)
            {
                ++m_dropped;
                m_overflowed = true;
                return false;
            }
            m_events.push_back(std::move(event));
            ++m_accepted;
            return true;
        }

        [[nodiscard]] auto drain_one(NativeEvent& output) -> bool
        {
            std::scoped_lock lock{m_mutex};
            if (m_events.empty()) return false;
            output = std::move(m_events.front());
            m_events.pop_front();
            ++m_drained;
            return true;
        }

        auto reset() -> void
        {
            std::scoped_lock lock{m_mutex};
            m_events.clear();
            m_next_sequence = 1;
            m_accepted = 0;
            m_drained = 0;
            m_dropped = 0;
            m_overflowed = false;
        }

        [[nodiscard]] auto exact_stream_usable() const -> bool
        {
            std::scoped_lock lock{m_mutex};
            return !m_overflowed;
        }

        [[nodiscard]] auto stats() const -> NativeEventQueueStats
        {
            std::scoped_lock lock{m_mutex};
            return {
                m_next_sequence,
                m_accepted,
                m_drained,
                m_dropped,
                m_events.size(),
                m_overflowed,
            };
        }

    private:
        const std::size_t m_capacity{};
        mutable std::mutex m_mutex{};
        std::deque<NativeEvent> m_events{};
        std::uint64_t m_next_sequence{1};
        std::uint64_t m_accepted{};
        std::uint64_t m_drained{};
        std::uint64_t m_dropped{};
        bool m_overflowed{};
    };
}
