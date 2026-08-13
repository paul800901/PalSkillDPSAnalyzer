#include "CollectorCore.hpp"
#include "NativeEventQueue.hpp"

#include <LuaMadeSimple/LuaMadeSimple.hpp>
#include <LuaType/LuaUObject.hpp>
#include <Mod/CppUserModBase.hpp>
#include <Unreal/CoreUObject/UObject/Class.hpp>
#include <Unreal/CoreUObject/UObject/UnrealType.hpp>
#include <Unreal/FField.hpp>
#include <Unreal/Hooks/Hooks.hpp>
#include <Unreal/Property/FEnumProperty.hpp>
#include <Unreal/FWeakObjectPtr.hpp>
#include <Unreal/UFunctionStructs.hpp>
#include <Unreal/UObjectGlobals.hpp>
#include <Unreal/UObjectArray.hpp>

#include <algorithm>
#include <array>
#include <atomic>
#include <cctype>
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
#include <vector>

namespace
{
    using RC::LuaMadeSimple::Lua;
    using namespace RC::Unreal;

    constexpr std::array damage_function_paths{
        STR("/Script/Pal.PalCharacterParameterComponent:OnDamage"),
        STR("/Script/Pal.PalEventNotify_Character:OnCharacterDamaged_ServerInternal"),
    };
    constexpr auto skill_effect_base_class_path = STR("/Script/Pal.PalSkillEffectBase");
    constexpr auto attack_filter_class_path = STR("/Script/Pal.PalAttackFilter");
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

    struct AttackFunctionLayout
    {
        ObjectField defender{};
        FStructProperty* damage_info{};
        ObjectField info_attacker{};

        [[nodiscard]] auto ready() const -> bool
        {
            return defender.property != nullptr
                && damage_info != nullptr
                && info_attacker.property != nullptr;
        }
    };

    struct AttackScope
    {
        UFunction* function{};
        UObject* context{};
        pal_dps::ObjectToken attacker{};
        pal_dps::ObjectToken defender{};
        pal_dps::ObjectToken effect{};
        pal_dps::ObjectToken filter{};
        std::int64_t waza_id{};
        std::string skill_code{};
    };

    thread_local std::vector<AttackScope> active_attack_scopes{};

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

    auto contains_ignore_case(std::string_view value, std::string_view needle) -> bool
    {
        if (needle.empty())
        {
            return true;
        }
        if (value.size() < needle.size())
        {
            return false;
        }
        for (std::size_t index = 0; index + needle.size() <= value.size(); ++index)
        {
            if (std::equal(
                    needle.begin(), needle.end(), value.begin() + static_cast<std::ptrdiff_t>(index),
                    [](const char left, const char right) {
                        return static_cast<unsigned char>(std::tolower(left))
                            == static_cast<unsigned char>(std::tolower(right));
                    }))
            {
                return true;
            }
        }
        return false;
    }

    auto read_integer_property(FProperty* property, void* container) -> std::optional<std::int64_t>
    {
        if (property == nullptr || container == nullptr)
        {
            return std::nullopt;
        }
        auto* address = property->ContainerPtrToValuePtr<void>(container);
        if (auto* enum_property = CastField<FEnumProperty>(property))
        {
            auto* numeric = enum_property->GetUnderlyingProperty();
            if (numeric != nullptr)
            {
                return static_cast<std::int64_t>(numeric->GetUnsignedIntPropertyValue(address));
            }
        }
        if (auto* numeric = CastField<FNumericProperty>(property))
        {
            return numeric->IsInteger()
                ? std::optional<std::int64_t>{numeric->GetSignedIntPropertyValue(address)}
                : std::nullopt;
        }
        return std::nullopt;
    }

    auto enum_code(FProperty* property, const std::int64_t value) -> std::string
    {
        UEnum* enumeration{};
        if (auto* enum_property = CastField<FEnumProperty>(property))
        {
            enumeration = enum_property->GetEnum().Get();
        }
        else if (auto* numeric = CastField<FNumericProperty>(property))
        {
            enumeration = numeric->GetIntPropertyEnum();
        }
        if (enumeration == nullptr)
        {
            return {};
        }
        auto code = RC::to_string(enumeration->GetNameByValue(value).ToString());
        if (const auto separator = code.rfind("::"); separator != std::string::npos)
        {
            code.erase(0, separator + 2);
        }
        return code;
    }

    auto read_filter_waza(UObject* filter) -> std::pair<std::int64_t, std::string>
    {
        if (filter == nullptr || filter->GetClassPrivate() == nullptr)
        {
            return {};
        }
        auto* property = find_property(filter->GetClassPrivate(), {"Waza", "WazaID", "WazaId", "WazaType"});
        const auto value = read_integer_property(property, filter);
        if (!value.has_value() || value.value() <= 0)
        {
            return {};
        }
        auto code = enum_code(property, value.value());
        if (code.empty())
        {
            code = "WAZA_ID_" + std::to_string(value.value());
        }
        return {value.value(), std::move(code)};
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
            ModVersion = STR("3.4.0");
            ModDescription = STR("Native exact Pal skill damage source collector");
            ModAuthors = STR("AsahiChan-Game");
        }

        ~BossDPSNativeCollector() override
        {
            if (m_damage_function != nullptr && m_hook_id >= 0)
            {
                static_cast<void>(m_damage_function->UnregisterHook(m_hook_id));
            }
            if (m_filter_bind_function != nullptr && m_filter_bind_hook_id >= 0)
            {
                static_cast<void>(m_filter_bind_function->UnregisterHook(m_filter_bind_hook_id));
            }
            if (m_script_pre_id != Hook::ERROR_ID)
            {
                static_cast<void>(Hook::UnregisterCallback(m_script_pre_id));
            }
            if (m_script_post_id != Hook::ERROR_ID)
            {
                static_cast<void>(Hook::UnregisterCallback(m_script_post_id));
            }
            if (s_instance == this)
            {
                s_instance = nullptr;
            }
        }

        auto on_unreal_init() -> void override
        {
            try
            {
                for (const auto path : damage_function_paths)
                {
                    auto* candidate = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, path);
                    if (candidate != nullptr && discover_layout(candidate))
                    {
                        m_damage_function = candidate;
                        m_damage_function_path = RC::to_string(path);
                        break;
                    }
                }
                if (m_damage_function == nullptr)
                {
                    log(STR("final damage UFunction/layout was not found; Lua fallback remains available"));
                    return;
                }
                m_hook_id = m_damage_function->RegisterPreHook(
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
                if (!m_ready)
                {
                    log(STR("native damage hook registration failed; Lua fallback remains available"));
                    return;
                }
                initialize_skill_source_hooks();
                log(m_exact_source_ready
                        ? STR("native damage + Blueprint OnAttack source hooks ready")
                        : STR("native damage hook ready; exact source hook unavailable, using Lua fallback"));
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
            if (mod_name != STR("PalSkillDPSAnalyzerSP")
                && mod_name != STR("BossDPSBroadcast"))
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
            log(STR("native event API registered for Lua mod ") + StringType{mod_name});
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
                   << "; event_overflow=" << (event_stats.overflowed ? "true" : "false")
                   << "; damage_path=" << m_damage_function_path
                   << "; script_calls=" << m_script_calls.load()
                   << "; attack_matches=" << m_attack_matches.load()
                   << "; attack_without_waza=" << m_attack_without_waza.load()
                   << "; filter_bind_matches=" << m_filter_bind_matches.load()
                   << "; exact_hits=" << m_exact_hits.load()
                   << "; unresolved_hits=" << m_unresolved_hits.load()
                   << "; source_errors=" << m_source_errors.load();
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

        auto initialize_skill_source_hooks() -> void
        {
            m_skill_effect_base_class = UObjectGlobals::StaticFindObject<UClass*>(
                nullptr, nullptr, skill_effect_base_class_path
            );
            m_attack_filter_class = UObjectGlobals::StaticFindObject<UClass*>(
                nullptr, nullptr, attack_filter_class_path
            );
            if (m_skill_effect_base_class == nullptr || m_attack_filter_class == nullptr)
            {
                log(STR("Pal skill-effect classes were not found"));
                return;
            }

            Hook::FCallbackOptions pre_options{};
            pre_options.bReadonly = true;
            pre_options.OwnerModName = STR("PalSkillDPSAnalyzer");
            pre_options.HookName = STR("SkillEffectAttackPre");
            m_script_pre_id = Hook::RegisterProcessLocalScriptFunctionPreCallback(
                [this](Hook::TCallbackIterationData<void>&, UObject* context, FFrame& stack, void*) {
                    try
                    {
                        capture_script_attack_pre(context, stack);
                    }
                    catch (...)
                    {
                        ++m_source_errors;
                    }
                },
                pre_options
            );

            Hook::FCallbackOptions post_options{};
            post_options.bReadonly = true;
            post_options.OwnerModName = STR("PalSkillDPSAnalyzer");
            post_options.HookName = STR("SkillEffectAttackPost");
            m_script_post_id = Hook::RegisterProcessLocalScriptFunctionPostCallback(
                [this](Hook::TCallbackIterationData<void>&, UObject* context, FFrame& stack, void*) {
                    try
                    {
                        capture_script_attack_post(context, stack);
                    }
                    catch (...)
                    {
                        ++m_source_errors;
                    }
                },
                post_options
            );

            m_filter_bind_function = UObjectGlobals::StaticFindObject<UFunction*>(
                nullptr, nullptr, STR("/Script/Pal.PalAttackFilter:BindPrimitiveComponent")
            );
            if (m_filter_bind_function != nullptr)
            {
                m_filter_bind_hook_id = m_filter_bind_function->RegisterPreHook(
                    [this](UnrealScriptFunctionCallableContext& context, void*) {
                        try
                        {
                            capture_filter_binding(context.Context);
                        }
                        catch (...)
                        {
                            ++m_source_errors;
                        }
                    }
                );
            }

            const auto script_hooks_ready = m_script_pre_id != Hook::ERROR_ID
                && m_script_post_id != Hook::ERROR_ID;
            m_exact_source_ready.store(script_hooks_ready, std::memory_order_release);
        }

        auto capture_filter_binding(UObject* filter) -> void
        {
            if (filter == nullptr || m_attack_filter_class == nullptr
                || !filter->IsA(m_attack_filter_class))
            {
                return;
            }
            auto* outer = filter->GetOuterPrivate();
            if (outer == nullptr || m_skill_effect_base_class == nullptr
                || !outer->IsA(m_skill_effect_base_class))
            {
                return;
            }
            const auto effect_token = object_token(outer);
            const auto filter_token = object_token(filter);
            if (!effect_token.valid() || !filter_token.valid())
            {
                return;
            }
            std::scoped_lock lock{m_source_mutex};
            m_effect_filters.insert_or_assign(effect_token, filter_token);
            ++m_filter_bind_matches;
        }

        auto find_attack_filter(UObject* effect) -> UObject*
        {
            if (effect == nullptr || effect->GetClassPrivate() == nullptr
                || m_attack_filter_class == nullptr)
            {
                return nullptr;
            }
            for (TFieldIterator<FProperty> iterator{
                     effect->GetClassPrivate(), EFieldIterationFlags::IncludeSuper
                 };
                 iterator;
                 ++iterator)
            {
                auto* property = *iterator;
                auto* object_property = CastField<FObjectPropertyBase>(property);
                if (object_property == nullptr)
                {
                    continue;
                }
                auto* address = property->ContainerPtrToValuePtr<void>(effect);
                auto* candidate = object_property->GetObjectPropertyValue(address);
                if (candidate != nullptr && candidate->IsA(m_attack_filter_class))
                {
                    return candidate;
                }
            }

            const auto effect_token = object_token(effect);
            std::scoped_lock lock{m_source_mutex};
            const auto known = m_effect_filters.find(effect_token);
            return known == m_effect_filters.end() ? nullptr : resolve_object(known->second);
        }

        auto discover_attack_layout(UFunction* function) -> AttackFunctionLayout
        {
            AttackFunctionLayout layout{};
            if (function == nullptr)
            {
                return layout;
            }
            const auto function_name = RC::to_string(function->GetName());
            if (!contains_ignore_case(function_name, "OnAttackDelegate__DelegateSignature"))
            {
                return layout;
            }
            for (TFieldIterator<FProperty> iterator{
                     function,
                     EFieldIterationFlags::IncludeSuper | EFieldIterationFlags::IncludeDeprecated
                 };
                 iterator;
                 ++iterator)
            {
                auto* property = *iterator;
                if (!property->HasAnyPropertyFlags(CPF_Parm)
                    || property->HasAnyPropertyFlags(CPF_ReturnParm))
                {
                    continue;
                }
                const auto name = field_name(property);
                if (layout.defender.property == nullptr
                    && (equals_ignore_case(name, "Defencer") || equals_ignore_case(name, "Defender")))
                {
                    if (CastField<FObjectPropertyBase>(property) != nullptr
                        || CastField<FWeakObjectProperty>(property) != nullptr)
                    {
                        layout.defender = {property};
                    }
                    continue;
                }
                auto* structure = CastField<FStructProperty>(property);
                if (structure == nullptr || structure->GetStruct().Get() == nullptr)
                {
                    continue;
                }
                auto* info_struct = structure->GetStruct().Get();
                const auto attacker = find_object_field(info_struct, {"Attacker"});
                if (attacker.property != nullptr
                    && (equals_ignore_case(name, "damageInfo")
                        || contains_ignore_case(RC::to_string(info_struct->GetName()), "PalDamageInfo")))
                {
                    layout.damage_info = structure;
                    layout.info_attacker = attacker;
                }
            }
            return layout;
        }

        auto capture_script_attack_pre(UObject* context, FFrame& stack) -> void
        {
            auto* function = stack.Node();
            if (function == nullptr)
            {
                function = stack.CurrentNativeFunction();
            }
            if (function == nullptr
                || !contains_ignore_case(
                    RC::to_string(function->GetName()), "OnAttackDelegate__DelegateSignature"
                ))
            {
                return;
            }
            ++m_script_calls;
            if (context == nullptr || stack.Locals() == nullptr
                || m_skill_effect_base_class == nullptr
                || context->GetClassPrivate() == nullptr
                || !context->GetClassPrivate()->IsChildOf(m_skill_effect_base_class))
            {
                return;
            }

            auto layout = discover_attack_layout(function);
            if (!layout.ready())
            {
                return;
            }
            auto* filter = find_attack_filter(context);
            const auto [waza_id, skill_code] = read_filter_waza(filter);
            if (filter == nullptr || waza_id <= 0 || skill_code.empty())
            {
                ++m_attack_without_waza;
                return;
            }

            auto* parameters = reinterpret_cast<std::byte*>(stack.Locals());
            auto* damage_info = layout.damage_info->ContainerPtrToValuePtr<void>(parameters);
            auto* attacker = layout.info_attacker.read(damage_info);
            auto* defender = layout.defender.read(parameters);
            if (defender == nullptr)
            {
                return;
            }
            active_attack_scopes.push_back({
                .function = function,
                .context = context,
                .attacker = object_token(attacker),
                .defender = object_token(defender),
                .effect = object_token(context),
                .filter = object_token(filter),
                .waza_id = waza_id,
                .skill_code = skill_code,
            });
            ++m_attack_matches;
        }

        auto capture_script_attack_post(UObject* context, FFrame& stack) -> void
        {
            auto* function = stack.Node();
            if (function == nullptr)
            {
                function = stack.CurrentNativeFunction();
            }
            if (!active_attack_scopes.empty())
            {
                const auto& scope = active_attack_scopes.back();
                if (scope.function == function && scope.context == context)
                {
                    active_attack_scopes.pop_back();
                }
            }
        }

        auto discover_layout(UFunction* function) -> bool
        {
            m_layout = {};
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

                const auto attacker_token = object_token(attacker);
                const auto defender_token = object_token(defender);
                for (auto scope = active_attack_scopes.rbegin();
                     scope != active_attack_scopes.rend();
                     ++scope)
                {
                    if (scope->defender != defender_token)
                    {
                        continue;
                    }
                    if (scope->attacker.valid() && attacker_token.valid()
                        && scope->attacker != attacker_token)
                    {
                        continue;
                    }
                    native_event.effect = scope->effect;
                    native_event.filter = scope->filter;
                    native_event.waza_id = scope->waza_id;
                    native_event.skill_code.assign(scope->skill_code);
                    native_event.evidence_kind.assign("effect_waza");
                    ++m_exact_hits;
                    break;
                }
                if (native_event.waza_id <= 0)
                {
                    ++m_unresolved_hits;
                }
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

        static auto native_event_kind_text(const pal_dps::NativeEventKind kind) -> std::string_view
        {
            switch (kind)
            {
            case pal_dps::NativeEventKind::cast_begin: return "cast_begin";
            case pal_dps::NativeEventKind::cast_end: return "cast_end";
            case pal_dps::NativeEventKind::effect_initialize: return "effect_initialize";
            case pal_dps::NativeEventKind::effect_link: return "effect_link";
            case pal_dps::NativeEventKind::damage_info_link: return "damage_info_link";
            case pal_dps::NativeEventKind::status_application: return "status_application";
            case pal_dps::NativeEventKind::final_damage: return "damage";
            }
            return "unknown";
        }

        static auto push_token(const Lua& lua, const pal_dps::ObjectToken token) -> void
        {
            lua.set_string(token_text(token));
        }

        static auto push_token(const Lua& lua, const pal_dps::CastToken token) -> void
        {
            lua.set_string(token_text(token));
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

            // UE4SS statically links the raw Lua C API and does not export those
            // symbols to C++ mods. LuaMadeSimple's inline Table::add_pair helper
            // therefore cannot be used by a separately linked mod. Return one
            // stable positional event tuple and let the Lua bridge name it.
            lua.set_bool(true);
            lua.set_integer(2);
            lua.set_string(native_event_kind_text(event->kind));
            lua.set_integer(static_cast<std::int64_t>(event->sequence));
            lua.set_integer(static_cast<std::int64_t>(event->captured_ns));
            lua.set_number(event->damage);
            lua.set_integer(static_cast<std::int64_t>(event->hits));
            const std::string evidence_kind{event->evidence_kind.view()};
            const std::string skill_code{event->skill_code.view()};
            const std::string status_code{event->status_code.view()};
            lua.set_string(evidence_kind);
            RC::LuaType::auto_construct_object(lua, resolve_object(event->attacker));
            RC::LuaType::auto_construct_object(lua, resolve_object(event->defender));
            RC::LuaType::auto_construct_object(lua, resolve_object(event->damage_causer));
            RC::LuaType::auto_construct_object(lua, resolve_object(event->override_network_owner));
            RC::LuaType::auto_construct_object(lua, resolve_object(event->info_attacker));
            push_token(lua, event->attacker);
            push_token(lua, event->defender);
            push_token(lua, event->damage_causer);
            push_token(lua, event->override_network_owner);
            push_token(lua, event->info_attacker);
            push_token(lua, event->damage_info);
            push_token(lua, event->action);
            push_token(lua, event->cast);
            push_token(lua, event->effect);
            push_token(lua, event->filter);
            push_token(lua, event->status_application);
            const auto target_key = format_pointer(pointer_key(resolve_object(event->defender)));
            lua.set_string(target_key);
            lua.set_integer(event->waza_id);
            lua.set_string(skill_code);
            lua.set_string(status_code);
            return 28;
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
            const auto exact = s_instance != nullptr && s_instance->event_is_ready();
            lua.set_string(exact
                ? "api_version=2;final_damage=true;exact_attribution=true;action=false;"
                  "effect_init=false;effect_attack=true;damage_info=false;status=false"
                : "api_version=2;final_damage=true;exact_attribution=false;action=false;"
                  "effect_init=false;effect_attack=false;damage_info=false;status=false");
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
        UFunction* m_damage_function{};
        UFunction* m_filter_bind_function{};
        UClass* m_skill_effect_base_class{};
        UClass* m_attack_filter_class{};
        std::string m_damage_function_path{};
        CallbackId m_hook_id{-1};
        CallbackId m_filter_bind_hook_id{-1};
        Hook::GlobalCallbackId m_script_pre_id{Hook::ERROR_ID};
        Hook::GlobalCallbackId m_script_post_id{Hook::ERROR_ID};
        std::atomic<bool> m_ready{};
        std::atomic<bool> m_faulted{};
        std::atomic<bool> m_exact_source_ready{};
        std::atomic<std::uint64_t> m_capture_errors{};
        std::atomic<std::uint64_t> m_script_calls{};
        std::atomic<std::uint64_t> m_attack_matches{};
        std::atomic<std::uint64_t> m_attack_without_waza{};
        std::atomic<std::uint64_t> m_filter_bind_matches{};
        std::atomic<std::uint64_t> m_exact_hits{};
        std::atomic<std::uint64_t> m_unresolved_hits{};
        std::atomic<std::uint64_t> m_source_errors{};
        std::mutex m_mutex;
        std::mutex m_source_mutex;
        boss_dps::CollectorCore m_collector;
        pal_dps::NativeEventQueue m_event_queue{maximum_pending_events};
        std::unordered_map<boss_dps::DamageKey, WeakObjects, boss_dps::DamageKeyHash>
            m_bucket_objects;
        std::deque<PendingRecord> m_drained_records;
        std::unordered_map<std::uintptr_t, FWeakObjectPtr> m_known_defenders;
        std::unordered_map<std::uintptr_t, TargetClassification> m_target_states;
        std::unordered_map<pal_dps::ObjectToken, pal_dps::ObjectToken, pal_dps::ObjectTokenHash>
            m_effect_filters;
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
