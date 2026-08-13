#include "NativeEventQueue.hpp"

#include <algorithm>
#include <cstdlib>
#include <iostream>
#include <mutex>
#include <string_view>
#include <thread>
#include <vector>

namespace
{
    using pal_dps::NativeEvent;
    using pal_dps::NativeEventKind;
    using pal_dps::NativeEventQueue;

    [[noreturn]] auto fail(const std::string_view message) -> void
    {
        std::cerr << "FAILED: " << message << '\n';
        std::exit(1);
    }

    auto expect(const bool condition, const std::string_view message) -> void
    {
        if (!condition) fail(message);
    }

    auto ordered_fifo_test() -> void
    {
        NativeEventQueue queue{4};
        for (std::uint64_t value = 10; value < 14; ++value)
        {
            NativeEvent event{};
            event.kind = NativeEventKind::final_damage;
            event.captured_ns = value;
            event.damage = static_cast<double>(value);
            expect(queue.enqueue(event), "FIFO enqueue failed");
        }

        NativeEvent event{};
        for (std::uint64_t sequence = 1; sequence <= 4; ++sequence)
        {
            expect(queue.drain_one(event), "FIFO drain failed");
            expect(event.sequence == sequence, "sequence was not monotonic");
            expect(event.captured_ns == sequence + 9, "FIFO order changed");
        }
        expect(!queue.drain_one(event), "empty queue returned an event");
        const auto stats = queue.stats();
        expect(stats.accepted == 4 && stats.drained == 4 && stats.pending == 0,
            "FIFO counters mismatch");
        expect(queue.exact_stream_usable(), "healthy stream was marked unusable");
    }

    auto overflow_fails_closed_test() -> void
    {
        NativeEventQueue queue{2};
        expect(queue.enqueue({}), "overflow fixture event 1");
        expect(queue.enqueue({}), "overflow fixture event 2");
        expect(!queue.enqueue({}), "overflow fixture did not reject event 3");
        const auto stats = queue.stats();
        expect(stats.accepted == 2 && stats.dropped == 1 && stats.pending == 2,
            "overflow counters mismatch");
        expect(stats.next_sequence == 4, "dropped event did not leave a sequence gap");
        expect(stats.overflowed && !queue.exact_stream_usable(),
            "overflow did not invalidate exact stream");

        NativeEvent event{};
        expect(queue.drain_one(event) && event.sequence == 1, "overflow changed retained FIFO");
        queue.reset();
        expect(queue.exact_stream_usable(), "reset did not clear overflow state");
        expect(queue.enqueue({}), "reset queue did not accept event");
        expect(queue.drain_one(event) && event.sequence == 1, "reset did not reset sequence");
    }

    auto fixed_text_test() -> void
    {
        NativeEvent event{};
        event.skill_code.assign("DiamondFall");
        expect(event.skill_code.view() == "DiamondFall", "fixed text changed short code");
        event.status_code.assign("Poison");
        expect(event.status_code.view() == "Poison", "fixed text changed status code");
        event.evidence_kind.assign(std::string(100, 'x'));
        expect(event.evidence_kind.view().size() == 64 && event.evidence_kind.truncated(),
            "fixed text bound was not enforced");
        event.evidence_kind.assign(std::string(64, 'y'));
        expect(event.evidence_kind.view().size() == 64 && !event.evidence_kind.truncated(),
            "exact-capacity fixed text was incorrectly marked truncated");
    }

    auto concurrent_sequence_test() -> void
    {
        constexpr std::size_t thread_count = 8;
        constexpr std::size_t events_per_thread = 2000;
        NativeEventQueue queue{thread_count * events_per_thread};
        std::vector<std::thread> producers;
        producers.reserve(thread_count);
        for (std::size_t thread = 0; thread < thread_count; ++thread)
        {
            producers.emplace_back([&queue, thread] {
                for (std::size_t index = 0; index < events_per_thread; ++index)
                {
                    NativeEvent event{};
                    event.captured_ns = thread * events_per_thread + index;
                    if (!queue.enqueue(event)) fail("concurrent enqueue overflowed");
                }
            });
        }
        for (auto& producer : producers) producer.join();

        std::uint64_t expected_sequence = 1;
        NativeEvent event{};
        while (queue.drain_one(event))
        {
            expect(event.sequence == expected_sequence, "concurrent sequence/FIFO mismatch");
            ++expected_sequence;
        }
        expect(expected_sequence == thread_count * events_per_thread + 1,
            "concurrent queue lost events");
        const auto stats = queue.stats();
        expect(stats.accepted == thread_count * events_per_thread
            && stats.drained == stats.accepted && stats.dropped == 0,
            "concurrent counters mismatch");
    }
}

auto main() -> int
{
    ordered_fifo_test();
    overflow_fails_closed_test();
    fixed_text_test();
    concurrent_sequence_test();
    std::cout << "native event queue tests passed\n";
    return 0;
}
