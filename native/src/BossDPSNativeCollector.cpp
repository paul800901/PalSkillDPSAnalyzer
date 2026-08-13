#include "CollectorCore.hpp"
#include "NativeEventQueue.hpp"

#include <LuaMadeSimple/LuaMadeSimple.hpp>
#include <LuaType/LuaUObject.hpp>
#include <Mod/CppUserModBase.hpp>
#include <Unreal/CoreUObject/UObject/Class.hpp>
#include <Unreal/CoreUObject/UObject/UnrealType.hpp>
#include <Unreal/FField.hpp>
#include <Unreal/FWeakObjectPtr.hpp>
#include <Unreal/UFunctionStructs.hpp>
#include <Unreal/UObjectGlobals.hpp>
#include <Unreal/UObjectArray.hpp>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <string_view>
#include <unordered_map>

namespace
{
    using RC::LuaMadeSimple::Lua;
    using namespace RC::Unreal;

    constexpr auto damage_function_path =
        STR("/Script/Pal.PalEventNotify_Character:OnCharacterDamaged_ServerInternal");
    constexpr std::size_t maximum_pending_buckets = 4096;
    constexpr std::size_t maximum_pending_events = 16384;

    enum class TargetState : std::uint8_t
    {
        Unknown,
        Boss,
        NonBoss,
    };

    struct ObjectField
    {
        FProperty* property{};

        [[nodiscard]] auto read(void* container) const -> UObject*
        {
            if (property == nullptr || container == nullptr)
            {
                return nullptr;
            }
            auto* value = property->ContainerPtrToValuePtr<void>(container);
            if (auto* object_property = CastField<FObjectPropertyBase>(property))
            {
                return object_property->GetObjectPropertyValue(value);
            }
            if (CastField<FWeakObjectProperty>(property) != nullptr)
            {
                return static_cast<FWeakObjectPtr*>(value)->Get();
            }
            return nullptr;
        }
    };

    struct NumericField
    {
        FNumericProperty* property{};

        [[nodiscard]] auto read(void* container) const -> double
        {
            if (property == nullptr || container == nullptr)
            {
                return 0.0;
            }
            auto* value = property->ContainerPtrToValuePtr<void>(container);
            if (property->IsFloatingPoint())
            {
                return property->GetFloatingPointPropertyValue(value);
            }
            if (property->IsInteger())
            {
                return static_cast<double>(property->GetSignedIntPropertyValue(value));
            }
            return 0.0;
        }
    };

    struct ReflectedDamageLayout
    {
        FStructProperty* result_parameter{};
        UScriptStruct* result_struct{};
        ObjectField attacker{};
        ObjectField defender{};
        NumericField actual_damage{};
        FStructProperty* damage_info{};
        ObjectField damage_causer{};
        ObjectField override_network_owner{};
        ObjectField info_attacker{};
        bool damage_causer_nested{};
        bool override_network_owner_nested{};

        [[nodiscard]] auto ready() const -> bool
        {
            return result_parameter != nullptr
                && attacker.property != nullptr
                && defender.property != nullptr
                && actual_damage.property != nullptr;
        }
    };

    struct WeakObjects
    {
        FWeakObjectPtr defender{};
        FWeakObjectPtr attacker{};
        FWeakObjectPtr damage_causer{};
        FWeakObjectPtr override_network_owner{};
        FWeakObjectPtr info_attacker{};
    };

    struct PendingRecord
    {
        boss_dps::DamageKey key{};
        boss_dps::DamageTotal total{};
        WeakObjects objects{};
    };

    struct TargetClassification
    {
        TargetState state{TargetState::Unknown};
        FWeakObjectPtr object{};
    };

    auto field_name(FProperty* property) -> std::string
    {
        if (property == nullptr)
        {
            return {};
        }
        const auto name = property->GetName();
        return RC::to_string(name);
    }

    auto equals_ignore_case(std::string_view left, std::string_view right) -> bool
    {
        return left.size() == right.size()
            && std::equal(left.begin(), left.end(), right.begin(), [](char a, char b) {
                   return static_cast<unsigned char>(std::tolower(a))
                       == static_cast<unsigned char>(std::tolower(b));
               });
    }

    auto find_property(UStruct* owner, std::initializer_list<std::string_view> names) -> FProperty*
    {
        if (owner == nullptr)
        {
            return nullptr;
        }
        for (TFieldIterator<FProperty> iterator{owner, EFieldIterationFlags::IncludeSuper}; iterator; ++iterator)
        {
            auto* property = *iterator;
            const auto name = field_name(property);
            for (const auto candidate : names)
            {
                if (equals_ignore_case(name, candidate))
                {
                    return property;
                }
            }
        }
        return nullptr;
    }

    auto find_object_field(UStruct* owner, std::initializer_list<std::string_view> names) -> ObjectField
    {
        auto* property = find_property(owner, names);
        if (property == nullptr)
        {
            return {};
        }
        if (CastField<FObjectPropertyBase>(property) == nullptr
            && CastField<FWeakObjectProperty>(property) == nullptr)
        {
            return {};
        }
        return {property};
    }

    auto find_numeric_field(UStruct* owner, std::initializer_list<std::string_view> names) -> NumericField
    {
        return {CastField<FNumericProperty>(find_property(owner, names))};
    }

    auto pointer_key(UObject* object) -> std::uintptr_t
    {
        return reinterpret_cast<std::uintptr_t>(object);
    }

    auto object_token(UObject* object) -> pal_dps::ObjectToken
    {
        if (object == nullptr)
        {
            return {};
        }
        const auto index = object->GetInternalIndex();
        if (index < 0)
        {
            return {};
        }
        auto* item = FUObjectArray::IndexToObject(index);
        if (item == nullptr || item->GetSerialNumber() <= 0)
        {
            return {};
        }
        return {
            static_cast<std::uint32_t>(index),
            static_cast<std::uint32_t>(item->GetSerialNumber()),
        };
    }

    auto resolve_object(const pal_dps::ObjectToken token) -> UObject*
    {
        if (!token.valid())
        {
            return nullptr;
        }
        auto* item = FUObjectArray::IndexToObject(static_cast<std::int32_t>(token.index));
        if (item == nullptr || static_cast<std::uint32_t>(item->GetSerialNumber()) != token.serial)
        {
            return nullptr;
        }
        return item->GetUObject();
    }

    auto token_text(const pal_dps::ObjectToken token) -> std::string
    {
        if (!token.valid())
        {
            return {};
        }
        return std::to_string(token.index) + ":" + std::to_string(token.serial);
    }

    auto token_text(const pal_dps::CastToken token) -> std::string
    {
        return token.valid() ? std::to_string(token.value) : std::string{};
    }

    auto captured_nanoseconds() -> std::uint64_t
    {
        return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count());
    }

    auto format_pointer(std::uintptr_t value) -> std::string
    {
        char buffer[2 + sizeof(std::uintptr_t) * 2 + 1]{};
        std::snprintf(buffer, sizeof(buffer), "0x%llX", static_cast<unsigned long long>(value));
        return buffer;
    }

    class BossDPSNativeCollector final : public RC::CppUserModBase
    {
      public:
        BossDPSNativeCollector()
        {
            ModName = STR("BossDPSNativeCollector");
            ModVersion = STR("3.2.0");
            ModDescription = STR("Native high-frequency damage aggregator for BossDPSBroadcast");
            ModAuthors = STR("AsahiChan-Game");
        }

        auto on_unreal_init() -> void override
        {
            try
            {
                auto* damage_function =
                    UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, damage_function_path);
                if (damage_function == nullptr)
                {
                    log(STR("damage UFunction was not found; Lua fallback remains available"));
                    return;
                }
                if (!discover_layout(damage_function))
                {
                    log(STR("damage layout was not recognized; Lua fallback remains available"));
                    return;
                }
                m_hook_id = damage_function->RegisterPreHook(
                    [this](UnrealScriptFunctionCallableContext& context, void*) {
                        try
                        {
                            capture(context);
                        }
                        catch (...)
                        {
                            ++m_capture_errors;
                            m_faulted.store(true, std::memory_order_release);
                            m_ready.store(false, std::memory_order_release);
                        }
                    }
                );
                m_ready.store(m_hook_id >= 0, std::memory_order_release);
                log(m_ready
                        ? STR("native damage hook ready (aggregate-only mode)")
                        : STR("native damage hook registration failed; Lua fallback remains available"));
            }
            catch (const std::exception& error)
            {
                log(RC::to_wstring(std::string{"initialization error: "} + error.what()));
                m_ready.store(false, std::memory_order_release);
            }
        }

        auto on_lua_start(
            RC::StringViewType mod_name,
            Lua& lua,
            Lua&,
            Lua&,
            Lua*
        ) -> void override
        {
            if (mod_name != STR("BossDPSBroadcast"))
            {
                return;
            }
            s_instance = this;
            lua.register_function("BossDPSNativeIsReady", &lua_is_ready);
            lua.register_function("BossDPSNativeDrainOne", &lua_drain_one);
            lua.register_function("BossDPSNativeClassifyTarget", &lua_classify_target);
            lua.register_function("BossDPSNativeStatus", &lua_status);
            lua.register_function("BossDPSNativeEventIsReady", &lua_event_is_ready);
            lua.register_function("BossDPSNativeDrainEventOne", &lua_drain_event_one);
            lua.register_function("BossDPSNativeResetEvents", &lua_reset_events);
            lua.register_function("BossDPSNativeCapabilities", &lua_capabilities);
        }

        auto is_ready() const -> bool
        {
            return m_ready.load(std::memory_order_acquire);
        }

        auto is_faulted() const -> bool
        {
            return m_faulted.load(std::memory_order_acquire);
        }

        auto event_api_available() const -> bool
        {
            return is_ready() && !is_faulted();
        }

        auto event_is_ready() const -> bool
        {
            return event_api_available()
                && m_exact_source_ready.load(std::memory_order_acquire)
                && m_event_queue.exact_stream_usable();
        }

        auto drain_one() -> std::optional<PendingRecord>
        {
            std::scoped_lock lock{m_mutex};
            if (m_drained_records.empty())
            {
                const auto batch = m_collector.drain(maximum_pending_buckets);
                for (const auto& [key, total] : batch)
                {
                    const auto objects = m_bucket_objects.find(key);
                    if (objects != m_bucket_objects.end())
                    {
                        m_drained_records.push_back({key, total, objects->second});
                        m_bucket_objects.erase(objects);
                    }
                }
                purge_stale_classifications();
            }
            if (m_drained_records.empty())
            {
                return std::nullopt;
            }
            auto record = std::move(m_drained_records.front());
            m_drained_records.pop_front();
            return record;
        }

        auto classify(std::string_view key_text, std::string_view state_text) -> void
        {
            std::uintptr_t key{};
            try
            {
                key = static_cast<std::uintptr_t>(std::stoull(std::string{key_text}, nullptr, 0));
            }
            catch (...)
            {
                return;
            }

            std::scoped_lock lock{m_mutex};
            if (equals_ignore_case(state_text, "unknown"))
            {
                m_target_states.erase(key);
                return;
            }
            auto& classification = m_target_states[key];
            classification.state = equals_ignore_case(state_text, "nonboss")
                ? TargetState::NonBoss
                : TargetState::Boss;
            const auto weak = m_known_defenders.find(key);
            if (weak != m_known_defenders.end())
            {
                classification.object = weak->second;
            }
        }

        auto drain_event_one() -> std::optional<pal_dps::NativeEvent>
        {
            pal_dps::NativeEvent event{};
            if (!m_event_queue.drain_one(event))
            {
                return std::nullopt;
            }
            return event;
        }

        auto reset_events() -> void
        {
            m_event_queue.reset();
        }

        auto status() -> std::string
        {
            std::scoped_lock lock{m_mutex};
            std::ostringstream output;
            const auto event_stats = m_event_queue.stats();
            output << "ready=" << (is_ready() ? "true" : "false")
                   << "; faulted=" << (is_faulted() ? "true" : "false")
                   << "; accepted_hits=" << m_collector.accepted_hits()
                   << "; pending_buckets=" << m_collector.size()
                   << "; drained_buckets=" << m_collector.drained_buckets()
                   << "; skipped_nonboss=" << m_skipped_nonboss
                   << "; overflow_buckets=" << m_overflow_buckets
                   << "; capture_errors=" << m_capture_errors.load()
                   << "; event_api=2"
                   << "; event_api_available="
                   << (event_api_available() ? "true" : "false")
                   << "; event_ready=" << (event_is_ready() ? "true" : "false")
                   << "; event_pending=" << event_stats.pending
                   << "; event_accepted=" << event_stats.accepted
                   << "; event_drained=" << event_stats.drained
                   << "; event_dropped=" << event_stats.dropped
                   << "; event_overflow=" << (event_stats.overflowed ? "true" : "false");
            return output.str();
        }

      private:
        auto log(RC::StringViewType message) const -> void
        {
            std::fwprintf(
                stderr,
                L"[BossDPSNativeCollector] %.*ls\n",
                static_cast<int>(message.size()),
                message.data()
            );
            std::fflush(stderr);
        }

        auto discover_layout(UFunction* function) -> bool
        {
            for (TFieldIterator<FProperty> iterator{
                     function,
                     EFieldIterationFlags::IncludeSuper | EFieldIterationFlags::IncludeDeprecated
                 };
                 iterator;
                 ++iterator)
            {
                auto* property = *iterator;
                if (!property->HasAnyPropertyFlags(CPF_Parm))
                {
                    continue;
                }
                auto* structure = CastField<FStructProperty>(property);
                if (structure == nullptr)
                {
                    continue;
                }
                auto* script_struct = structure->GetStruct().Get();
                if (script_struct == nullptr)
                {
                    continue;
                }
                const auto attacker = find_object_field(script_struct, {"Attacker"});
                const auto defender = find_object_field(script_struct, {"Defender"});
                const auto actual_damage = find_numeric_field(script_struct, {"ActualDamage"});
                if (attacker.property != nullptr
                    && defender.property != nullptr
                    && actual_damage.property != nullptr)
                {
                    m_layout.result_parameter = structure;
                    m_layout.result_struct = script_struct;
                    m_layout.attacker = attacker;
                    m_layout.defender = defender;
                    m_layout.actual_damage = actual_damage;
                    break;
                }
            }

            if (!m_layout.ready())
            {
                return false;
            }

            auto* nested_property = CastField<FStructProperty>(
                find_property(m_layout.result_struct, {"DamageInfo", "CharacterDamageInfo", "damageInfo"})
            );
            m_layout.damage_info = nested_property;
            m_layout.damage_causer =
                find_object_field(m_layout.result_struct, {"DamageCauser", "damageCauser"});
            m_layout.override_network_owner =
                find_object_field(m_layout.result_struct, {"OverrideNetworkOwner"});

            if (nested_property != nullptr && nested_property->GetStruct().Get() != nullptr)
            {
                auto* nested_struct = nested_property->GetStruct().Get();
                if (m_layout.damage_causer.property == nullptr)
                {
                    m_layout.damage_causer =
                        find_object_field(nested_struct, {"DamageCauser", "damageCauser"});
                    m_layout.damage_causer_nested = m_layout.damage_causer.property != nullptr;
                }
                if (m_layout.override_network_owner.property == nullptr)
                {
                    m_layout.override_network_owner =
                        find_object_field(nested_struct, {"OverrideNetworkOwner"});
                    m_layout.override_network_owner_nested =
                        m_layout.override_network_owner.property != nullptr;
                }
                m_layout.info_attacker = find_object_field(nested_struct, {"Attacker"});
            }
            return true;
        }

        auto capture(UnrealScriptFunctionCallableContext& context) -> void
        {
            if (!is_ready() || context.TheStack.Locals() == nullptr)
            {
                return;
            }
            auto* parameters = reinterpret_cast<std::byte*>(context.TheStack.Locals());
            auto* result = m_layout.result_parameter->ContainerPtrToValuePtr<void>(parameters);
            auto* attacker = m_layout.attacker.read(result);
            auto* defender = m_layout.defender.read(result);
            const auto damage = m_layout.actual_damage.read(result);
            if (attacker == nullptr || defender == nullptr
                || !std::isfinite(damage) || damage <= 0.0)
            {
                return;
            }

            void* nested = nullptr;
            if (m_layout.damage_info != nullptr)
            {
                nested = m_layout.damage_info->ContainerPtrToValuePtr<void>(result);
            }
            auto* damage_causer = m_layout.damage_causer.read(
                m_layout.damage_causer_nested ? nested : result
            );
            auto* override_network_owner = m_layout.override_network_owner.read(
                m_layout.override_network_owner_nested ? nested : result
            );
            auto* info_attacker = m_layout.info_attacker.read(nested);

            // Do not start an undrained high-frequency stream until the exact
            // cast/effect source hooks are active. Until then Lua keeps using
            // its fail-closed fallback and this collector remains legacy-safe.
            if (m_exact_source_ready.load(std::memory_order_acquire))
            {
                pal_dps::NativeEvent native_event{};
                native_event.kind = pal_dps::NativeEventKind::final_damage;
                native_event.captured_ns = captured_nanoseconds();
                native_event.attacker = object_token(attacker);
                native_event.defender = object_token(defender);
                native_event.damage_causer = object_token(damage_causer);
                native_event.override_network_owner = object_token(override_network_owner);
                native_event.info_attacker = object_token(info_attacker);
                native_event.damage = damage;
                native_event.hits = 1;
                native_event.evidence_kind.assign("unresolved");
                static_cast<void>(m_event_queue.enqueue(std::move(native_event)));
            }

            const boss_dps::DamageKey key{
                .defender = pointer_key(defender),
                .attacker = pointer_key(attacker),
                .damage_causer = pointer_key(damage_causer),
                .override_network_owner = pointer_key(override_network_owner),
                .info_attacker = pointer_key(info_attacker),
            };

            std::scoped_lock lock{m_mutex};
            const auto target = m_target_states.find(key.defender);
            if (target != m_target_states.end() && target->second.state == TargetState::NonBoss)
            {
                ++m_skipped_nonboss;
                return;
            }
            if (m_collector.size() >= maximum_pending_buckets
                && m_bucket_objects.find(key) == m_bucket_objects.end())
            {
                ++m_overflow_buckets;
                return;
            }
            if (!m_collector.add(key, damage))
            {
                return;
            }
            if (m_bucket_objects.find(key) == m_bucket_objects.end())
            {
                m_bucket_objects.emplace(key, WeakObjects{
                    .defender = FWeakObjectPtr{defender},
                    .attacker = FWeakObjectPtr{attacker},
                    .damage_causer = FWeakObjectPtr{damage_causer},
                    .override_network_owner = FWeakObjectPtr{override_network_owner},
                    .info_attacker = FWeakObjectPtr{info_attacker},
                });
            }
            m_known_defenders.insert_or_assign(key.defender, FWeakObjectPtr{defender});
        }

        auto purge_stale_classifications() -> void
        {
            for (auto iterator = m_target_states.begin(); iterator != m_target_states.end();)
            {
                if (iterator->second.object.Get() == nullptr)
                {
                    m_known_defenders.erase(iterator->first);
                    iterator = m_target_states.erase(iterator);
                }
                else
                {
                    ++iterator;
                }
            }
        }

        static auto lua_is_ready(const Lua& lua) -> int
        {
            lua.set_bool(s_instance != nullptr && s_instance->is_ready());
            return 1;
        }

        static auto lua_drain_one(const Lua& lua) -> int
        {
            if (s_instance == nullptr || !s_instance->is_ready())
            {
                lua.set_bool(false);
                if (s_instance != nullptr && s_instance->is_faulted())
                {
                    lua.set_string("faulted");
                    return 2;
                }
                return 1;
            }
            const auto record = s_instance->drain_one();
            if (!record.has_value())
            {
                lua.set_bool(false);
                return 1;
            }

            lua.set_bool(true);
            RC::LuaType::auto_construct_object(lua, record->objects.attacker.Get());
            RC::LuaType::auto_construct_object(lua, record->objects.defender.Get());
            lua.set_number(record->total.damage);
            RC::LuaType::auto_construct_object(lua, record->objects.damage_causer.Get());
            RC::LuaType::auto_construct_object(lua, record->objects.override_network_owner.Get());
            RC::LuaType::auto_construct_object(lua, record->objects.info_attacker.Get());
            lua.set_integer(static_cast<std::int64_t>(record->total.hits));
            lua.set_string(format_pointer(record->key.defender));
            return 9;
        }

        static auto add_object_pair(
            const Lua& lua,
            Lua::Table& table,
            const char* key,
            const pal_dps::ObjectToken token) -> void
        {
            table.add_key(key);
            RC::LuaType::auto_construct_object(lua, resolve_object(token));
            table.fuse_pair();
        }

        static auto add_token_pair(
            Lua::Table& table,
            const char* key,
            const pal_dps::ObjectToken token) -> void
        {
            const auto text = token_text(token);
            table.add_pair(key, text.c_str());
        }

        static auto add_token_pair(
            Lua::Table& table,
            const char* key,
            const pal_dps::CastToken token) -> void
        {
            const auto text = token_text(token);
            table.add_pair(key, text.c_str());
        }

        static auto lua_event_is_ready(const Lua& lua) -> int
        {
            lua.set_bool(s_instance != nullptr && s_instance->event_is_ready());
            return 1;
        }

        static auto lua_drain_event_one(const Lua& lua) -> int
        {
            if (s_instance == nullptr || !s_instance->event_api_available())
            {
                lua.set_bool(false);
                if (s_instance != nullptr)
                {
                    lua.set_string(s_instance->is_faulted() ? "faulted" : "overflow");
                    return 2;
                }
                return 1;
            }
            const auto event = s_instance->drain_event_one();
            if (!event.has_value())
            {
                lua.set_bool(false);
                if (!s_instance->m_event_queue.exact_stream_usable())
                {
                    lua.set_string("overflow");
                    return 2;
                }
                return 1;
            }

            lua.set_bool(true);
            auto table = lua.prepare_new_table(0, 32);
            table.add_pair("api_version", 2);
            table.add_pair("kind", "damage");
            table.add_pair("sequence", static_cast<long long>(event->sequence));
            table.add_pair("captured_ns", static_cast<long long>(event->captured_ns));
            table.add_pair("damage", event->damage);
            table.add_pair("hits", static_cast<long long>(event->hits));
            const std::string evidence_kind{event->evidence_kind.view()};
            const std::string skill_code{event->skill_code.view()};
            const std::string status_code{event->status_code.view()};
            table.add_pair("evidence_kind", evidence_kind.c_str());
            add_object_pair(lua, table, "attacker", event->attacker);
            add_object_pair(lua, table, "defender", event->defender);
            add_object_pair(lua, table, "damage_causer", event->damage_causer);
            add_object_pair(lua, table, "override_network_owner", event->override_network_owner);
            add_object_pair(lua, table, "info_attacker", event->info_attacker);
            add_token_pair(table, "attacker_id", event->attacker);
            add_token_pair(table, "defender_id", event->defender);
            add_token_pair(table, "damage_causer_id", event->damage_causer);
            add_token_pair(table, "override_network_owner_id", event->override_network_owner);
            add_token_pair(table, "info_attacker_id", event->info_attacker);
            add_token_pair(table, "damage_info_id", event->damage_info);
            add_token_pair(table, "action_id", event->action);
            add_token_pair(table, "cast_id", event->cast);
            add_token_pair(table, "effect_id", event->effect);
            add_token_pair(table, "filter_id", event->filter);
            add_token_pair(table, "status_application_id", event->status_application);
            const auto target_key = format_pointer(pointer_key(resolve_object(event->defender)));
            table.add_pair("target_key", target_key.c_str());
            table.add_pair("waza_id", static_cast<long long>(event->waza_id));
            table.add_pair("skill_code", skill_code.c_str());
            table.add_pair("status_code", status_code.c_str());
            table.make_local();
            return 2;
        }

        static auto lua_reset_events(const Lua&) -> int
        {
            if (s_instance != nullptr)
            {
                s_instance->reset_events();
            }
            return 0;
        }

        static auto lua_capabilities(const Lua& lua) -> int
        {
            lua.set_string(
                "api_version=2;final_damage=true;exact_attribution=false;action=false;"
                "effect_init=false;effect_attack=false;damage_info=false;status=false"
            );
            return 1;
        }

        static auto lua_classify_target(const Lua& lua) -> int
        {
            if (s_instance != nullptr)
            {
                s_instance->classify(lua.get_string(1), lua.get_string(2));
            }
            return 0;
        }

        static auto lua_status(const Lua& lua) -> int
        {
            lua.set_string(s_instance == nullptr ? "not-loaded" : s_instance->status());
            return 1;
        }

      private:
        inline static BossDPSNativeCollector* s_instance{};
        ReflectedDamageLayout m_layout{};
        CallbackId m_hook_id{-1};
        std::atomic<bool> m_ready{};
        std::atomic<bool> m_faulted{};
        std::atomic<bool> m_exact_source_ready{};
        std::atomic<std::uint64_t> m_capture_errors{};
        std::mutex m_mutex;
        boss_dps::CollectorCore m_collector;
        pal_dps::NativeEventQueue m_event_queue{maximum_pending_events};
        std::unordered_map<boss_dps::DamageKey, WeakObjects, boss_dps::DamageKeyHash>
            m_bucket_objects;
        std::deque<PendingRecord> m_drained_records;
        std::unordered_map<std::uintptr_t, FWeakObjectPtr> m_known_defenders;
        std::unordered_map<std::uintptr_t, TargetClassification> m_target_states;
        std::uint64_t m_skipped_nonboss{};
        std::uint64_t m_overflow_buckets{};
    };
}

#define BOSS_DPS_NATIVE_API __declspec(dllexport)

extern "C"
{
    BOSS_DPS_NATIVE_API RC::CppUserModBase* start_mod()
    {
        return new BossDPSNativeCollector();
    }

    BOSS_DPS_NATIVE_API void uninstall_mod(RC::CppUserModBase* mod)
    {
        delete mod;
    }
}
