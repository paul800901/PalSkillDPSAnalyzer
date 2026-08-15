#include "CollectorCore.hpp"
#include "FilterCallbackScopeMatcher.hpp"
#include "NativeEventQueue.hpp"
#include "PendingAttackMatcher.hpp"
#include "PendingFinalDamageMatcher.hpp"
#include "PendingFingerprintMatcher.hpp"

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
#include <bit>
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
#include <unordered_set>
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
    constexpr auto action_base_class_path = STR("/Script/Pal.PalActionBase");
    constexpr auto damage_utility_function_path =
        STR("/Script/Pal.PalUtility:ProcessDamageAndPlayEffectsByDamageInfo");
    constexpr std::size_t maximum_pending_buckets = 4096;
    constexpr std::size_t maximum_pending_events = 16384;
    constexpr std::size_t maximum_source_records = 32768;
    constexpr std::size_t maximum_discovered_script_functions = 8192;
    constexpr std::size_t maximum_damage_handler_probe_functions = 128;
    constexpr std::size_t maximum_damage_handler_probe_samples = 3;
    constexpr std::size_t maximum_damage_handler_probe_reports = 24;
    constexpr std::size_t maximum_final_source_probe_samples = 24;
    constexpr std::size_t maximum_final_source_probe_fields = 48;
    constexpr std::size_t maximum_final_source_probe_visited_fields = 192;
    constexpr std::size_t maximum_final_source_schema_fields = 96;
    constexpr std::size_t maximum_final_source_stack_depth = 8;
    constexpr std::size_t maximum_final_source_log_bytes = 4096;
    constexpr std::size_t maximum_filter_attack_callback_probe_samples = 16;
    constexpr std::size_t maximum_damage_utility_probe_samples = 24;
    constexpr std::uint64_t maximum_pending_attack_age_ns = 1'000'000'000ULL;
    constexpr std::uint64_t maximum_pending_final_damage_age_ns = 1'000'000'000ULL;

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
        ObjectField attacker_component{};
        NumericField hit_count{};

        [[nodiscard]] auto ready() const -> bool
        {
            return defender.property != nullptr
                && damage_info != nullptr
                && info_attacker.property != nullptr;
        }
    };

    struct DamageFingerprintLayout
    {
        std::array<FProperty*, static_cast<std::size_t>(pal_dps::FingerprintField::count)> fields{};
        ObjectField damage_causer{};
        ObjectField override_network_owner{};
    };

    struct AttackScope
    {
        UFunction* function{};
        UObject* context{};
        pal_dps::ObjectToken attacker{};
        pal_dps::ObjectToken defender{};
        pal_dps::ObjectToken action{};
        pal_dps::ObjectToken effect{};
        pal_dps::ObjectToken parent_effect{};
        pal_dps::ObjectToken filter{};
        pal_dps::CastToken cast{};
        std::int64_t waza_id{};
        std::string skill_code{};
    };

    struct ActionScope
    {
        UFunction* function{};
        UObject* context{};
        pal_dps::ObjectToken action{};
        pal_dps::CastToken cast{};
    };

    struct FilterAttackScope
    {
        UFunction* function{};
        UObject* context{};
        pal_dps::FilterCallbackScopeLink link{};
        pal_dps::ObjectToken info_attacker{};
        pal_dps::ObjectToken attacker_component{};
        std::optional<std::int64_t> owner_action_id{};
        double hit_count{};
    };

    struct DamageUtilityScope
    {
        UFunction* function{};
        UObject* context{};
        pal_dps::FilterCallbackScopeLink link{};
        pal_dps::ObjectToken info_attacker{};
        pal_dps::ObjectToken stack_effect{};
        std::size_t stack_depth{};
    };

    struct EffectSourceRecord
    {
        pal_dps::ObjectToken effect{};
        pal_dps::ObjectToken action{};
        pal_dps::ObjectToken attacker{};
        pal_dps::ObjectToken parent_effect{};
        pal_dps::ObjectToken filter{};
        pal_dps::CastToken cast{};
        std::int64_t waza_id{};
        std::string skill_code{};
        bool conflicted{};
        bool initialize_emitted{};
    };

    thread_local std::vector<AttackScope> active_attack_scopes{};
    thread_local std::vector<ActionScope> active_action_scopes{};
    thread_local std::vector<FilterAttackScope> active_filter_attack_scopes{};
    thread_local std::vector<DamageUtilityScope> active_damage_utility_scopes{};

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

    auto object_token(UObject* object) -> pal_dps::ObjectToken;

    auto build_fingerprint_layout(UStruct* owner) -> DamageFingerprintLayout
    {
        DamageFingerprintLayout layout{};
        if (owner == nullptr)
        {
            return layout;
        }
        auto set = [&layout, owner](
            const pal_dps::FingerprintField field,
            const std::initializer_list<std::string_view> names
        ) {
            layout.fields[static_cast<std::size_t>(field)] = find_property(owner, names);
        };
        set(pal_dps::FingerprintField::base_power, {"BasePower"});
        set(pal_dps::FingerprintField::element,
            {"AttackElementType", "AttackElement", "ElementType"});
        set(pal_dps::FingerprintField::skill,
            {"SkillID", "SkillId", "AttackSkillID", "AttackSkillId", "SkillType"});
        set(pal_dps::FingerprintField::attack_type, {"AttackType"});
        set(pal_dps::FingerprintField::attack_attribute,
            {"AttackAttribute", "DamageAttribute"});
        set(pal_dps::FingerprintField::damage_type, {"DamageType"});
        set(pal_dps::FingerprintField::weapon_type, {"WeaponType"});
        set(pal_dps::FingerprintField::waza, {"Waza", "WazaID", "WazaId", "WazaType"});
        set(pal_dps::FingerprintField::action, {"ActionID", "ActionId"});
        set(pal_dps::FingerprintField::bullet, {"BulletID", "BulletId"});
        layout.damage_causer = find_object_field(owner, {"DamageCauser", "damageCauser"});
        layout.override_network_owner = find_object_field(owner, {"OverrideNetworkOwner"});
        return layout;
    }

    auto read_fingerprint_value(FProperty* property, void* container)
        -> pal_dps::FingerprintValue
    {
        if (property == nullptr || container == nullptr)
        {
            return {};
        }
        auto* address = property->ContainerPtrToValuePtr<void>(container);
        if (auto* enum_property = CastField<FEnumProperty>(property))
        {
            if (auto* numeric = enum_property->GetUnderlyingProperty())
            {
                return {
                    .kind = pal_dps::FingerprintValueKind::integer,
                    .value = numeric->GetUnsignedIntPropertyValue(address),
                };
            }
        }
        auto* numeric = CastField<FNumericProperty>(property);
        if (numeric == nullptr)
        {
            return {};
        }
        if (numeric->IsInteger())
        {
            return {
                .kind = pal_dps::FingerprintValueKind::integer,
                .value = static_cast<std::uint64_t>(numeric->GetSignedIntPropertyValue(address)),
            };
        }
        if (numeric->IsFloatingPoint())
        {
            auto value = numeric->GetFloatingPointPropertyValue(address);
            if (!std::isfinite(value))
            {
                return {};
            }
            if (value == 0.0) value = 0.0;
            return {
                .kind = pal_dps::FingerprintValueKind::floating_bits,
                .value = std::bit_cast<std::uint64_t>(value),
            };
        }
        return {};
    }

    auto build_damage_fingerprint(
        const DamageFingerprintLayout& layout,
        void* container
    ) -> pal_dps::DamageFingerprint
    {
        pal_dps::DamageFingerprint fingerprint{};
        for (std::size_t index = 0; index < layout.fields.size(); ++index)
        {
            fingerprint.values[index] = read_fingerprint_value(layout.fields[index], container);
        }
        fingerprint.damage_causer = object_token(layout.damage_causer.read(container));
        fingerprint.override_network_owner = object_token(
            layout.override_network_owner.read(container)
        );
        return fingerprint;
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

    auto looks_like_damage_handler(const std::string_view function_name) -> bool
    {
        // Several Pal effects do not call their FPalDamageInfo callback
        // "Attack" or "Damage". Blast/impact/projectile Blueprints commonly
        // use hit, overlap, collision, impact, burst or explode. The caller
        // still requires an effect context plus the reflected Defender,
        // FPalDamageInfo and Attacker fields, so unrelated Blueprint events
        // cannot become attribution evidence from the name alone.
        constexpr std::array handler_tokens{
            std::string_view{"attack"},
            std::string_view{"damage"},
            std::string_view{"hit"},
            std::string_view{"overlap"},
            std::string_view{"collision"},
            std::string_view{"impact"},
            std::string_view{"burst"},
            std::string_view{"explode"},
            std::string_view{"explosion"},
        };
        return std::any_of(
            handler_tokens.begin(), handler_tokens.end(),
            [function_name](const std::string_view token) {
                return contains_ignore_case(function_name, token);
            }
        );
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

    auto is_native_function(UFunction* function) -> bool
    {
        if (function == nullptr)
        {
            return false;
        }
        const auto function_pointer = function->GetFunc();
        return function_pointer != nullptr
            && function_pointer != UObject::ProcessInternalInternal.get_function_address()
            && function->HasAnyFunctionFlags(EFunctionFlags::FUNC_Native);
    }

    auto is_script_function(UFunction* function) -> bool
    {
        return function != nullptr
            && function->GetFunc() == UObject::ProcessInternalInternal.get_function_address()
            && !function->HasAnyFunctionFlags(EFunctionFlags::FUNC_Native);
    }

    auto format_pointer(std::uintptr_t value) -> std::string
    {
        char buffer[2 + sizeof(std::uintptr_t) * 2 + 1]{};
        std::snprintf(buffer, sizeof(buffer), "0x%llX", static_cast<unsigned long long>(value));
        return buffer;
    }

    auto is_direct_source_identifier(const std::string_view name) -> bool
    {
        constexpr std::array identifiers{
            std::string_view{"Waza"},
            std::string_view{"WazaID"},
            std::string_view{"WazaId"},
            std::string_view{"WazaType"},
            std::string_view{"SkillID"},
            std::string_view{"SkillId"},
            std::string_view{"AttackSkillID"},
            std::string_view{"AttackSkillId"},
            std::string_view{"SkillType"},
            std::string_view{"ActionID"},
            std::string_view{"ActionId"},
            std::string_view{"BulletID"},
            std::string_view{"BulletId"},
            std::string_view{"ProjectileID"},
            std::string_view{"ProjectileId"},
            std::string_view{"EffectID"},
            std::string_view{"EffectId"},
        };
        return std::any_of(
            identifiers.begin(), identifiers.end(),
            [name](const std::string_view candidate) {
                return equals_ignore_case(name, candidate);
            }
        );
    }

    auto bounded_log_payload(std::string payload, bool& truncated) -> std::string
    {
        if (payload.size() <= maximum_final_source_log_bytes)
        {
            return payload;
        }
        constexpr std::string_view suffix{"...[truncated]"};
        payload.resize(maximum_final_source_log_bytes - suffix.size());
        payload.append(suffix);
        truncated = true;
        return payload;
    }

    class BossDPSNativeCollector final : public RC::CppUserModBase
    {
      public:
        BossDPSNativeCollector()
        {
            ModName = STR("BossDPSNativeCollector");
            ModVersion = STR("3.11.0-reverse-pair-probe");
            ModDescription = STR("Native fail-closed Pal reverse source pairing probe");
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
            if (m_filter_attack_callback_function != nullptr)
            {
                if (m_filter_attack_callback_pre_hook_id >= 0)
                {
                    static_cast<void>(m_filter_attack_callback_function->UnregisterHook(
                        m_filter_attack_callback_pre_hook_id
                    ));
                }
                if (m_filter_attack_callback_post_hook_id >= 0)
                {
                    static_cast<void>(m_filter_attack_callback_function->UnregisterHook(
                        m_filter_attack_callback_post_hook_id
                    ));
                }
            }
            if (m_damage_utility_function != nullptr)
            {
                if (m_damage_utility_pre_hook_id >= 0)
                {
                    static_cast<void>(m_damage_utility_function->UnregisterHook(
                        m_damage_utility_pre_hook_id
                    ));
                }
                if (m_damage_utility_post_hook_id >= 0)
                {
                    static_cast<void>(m_damage_utility_function->UnregisterHook(
                        m_damage_utility_post_hook_id
                    ));
                }
            }
            if (m_effect_initialize_function != nullptr)
            {
                if (m_effect_initialize_pre_hook_id >= 0)
                {
                    static_cast<void>(m_effect_initialize_function->UnregisterHook(
                        m_effect_initialize_pre_hook_id
                    ));
                }
                if (m_effect_initialize_post_hook_id >= 0)
                {
                    static_cast<void>(m_effect_initialize_function->UnregisterHook(
                        m_effect_initialize_post_hook_id
                    ));
                }
            }
            if (m_action_begin_function != nullptr)
            {
                if (m_action_begin_pre_hook_id >= 0)
                {
                    static_cast<void>(m_action_begin_function->UnregisterHook(
                        m_action_begin_pre_hook_id
                    ));
                }
                if (m_action_begin_post_hook_id >= 0)
                {
                    static_cast<void>(m_action_begin_function->UnregisterHook(
                        m_action_begin_post_hook_id
                    ));
                }
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
            lua.register_function("BossDPSNativeProbeReport", &lua_probe_report);
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
            flush_expired_pending_final_damage();
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
            active_filter_attack_scopes.clear();
            active_damage_utility_scopes.clear();
            {
                std::scoped_lock lock{m_fingerprint_mutex};
                m_pending_fingerprints.reset();
            }
            {
                std::scoped_lock lock{m_attack_matcher_mutex};
                m_pending_attacks.reset();
            }
            {
                std::scoped_lock lock{m_final_damage_matcher_mutex};
                m_pending_final_damage.reset();
            }
            {
                std::scoped_lock lock{m_probe_mutex};
                m_probe_reports.clear();
                m_probe_samples_by_function.clear();
                m_final_source_probe_reports.clear();
            }
            m_probe_damage_callbacks.store(0, std::memory_order_release);
            m_probe_damage_functions.store(0, std::memory_order_release);
            m_probe_action_contexts.store(0, std::memory_order_release);
            m_probe_effect_contexts.store(0, std::memory_order_release);
            m_probe_other_contexts.store(0, std::memory_order_release);
            m_probe_waza_samples.store(0, std::memory_order_release);
            m_probe_cache_overflow.store(false, std::memory_order_release);
            m_final_source_probe_claims.store(0, std::memory_order_release);
            m_final_source_probe_samples.store(0, std::memory_order_release);
            m_final_source_probe_dropped.store(0, std::memory_order_release);
            m_final_source_probe_object_fields.store(0, std::memory_order_release);
            m_final_source_probe_direct_ids.store(0, std::memory_order_release);
            m_final_source_probe_stack_frames.store(0, std::memory_order_release);
            m_final_source_probe_effect_frames.store(0, std::memory_order_release);
            m_final_source_probe_action_frames.store(0, std::memory_order_release);
            m_final_source_probe_empty_fields.store(0, std::memory_order_release);
            m_final_source_probe_field_truncated.store(0, std::memory_order_release);
            m_final_source_probe_payload_truncated.store(0, std::memory_order_release);
            m_final_source_schema_samples.store(0, std::memory_order_release);
            m_final_source_schema_truncated.store(0, std::memory_order_release);
            m_final_source_schema_emitted.store(false, std::memory_order_release);
            m_filter_attack_callback_calls.store(0, std::memory_order_release);
            m_filter_attack_callback_layout_misses.store(0, std::memory_order_release);
            m_filter_attack_callback_missing_attacker.store(0, std::memory_order_release);
            m_filter_attack_callback_missing_defender.store(0, std::memory_order_release);
            m_filter_attack_callback_missing_waza.store(0, std::memory_order_release);
            m_filter_attack_callback_source_conflicts.store(0, std::memory_order_release);
            m_filter_attack_callback_nested_finals.store(0, std::memory_order_release);
            m_filter_attack_callback_nested_exact.store(0, std::memory_order_release);
            m_filter_attack_callback_nested_conflicts.store(0, std::memory_order_release);
            m_filter_attack_callback_nested_attacker_misses.store(0, std::memory_order_release);
            m_filter_attack_callback_nested_defender_misses.store(0, std::memory_order_release);
            m_filter_attack_callback_nested_incomplete.store(0, std::memory_order_release);
            m_filter_attack_callback_outside_scope_finals.store(0, std::memory_order_release);
            m_filter_attack_callback_scope_errors.store(0, std::memory_order_release);
            m_filter_attack_callback_errors.store(0, std::memory_order_release);
            m_filter_attack_callback_probe_claims.store(0, std::memory_order_release);
            m_filter_attack_callback_probe_samples.store(0, std::memory_order_release);
            m_filter_attack_callback_probe_dropped.store(0, std::memory_order_release);
            m_filter_attack_callback_probe_truncated.store(0, std::memory_order_release);
            m_damage_utility_calls.store(0, std::memory_order_release);
            m_damage_utility_layout_misses.store(0, std::memory_order_release);
            m_damage_utility_missing_filter.store(0, std::memory_order_release);
            m_damage_utility_missing_attacker.store(0, std::memory_order_release);
            m_damage_utility_missing_defender.store(0, std::memory_order_release);
            m_damage_utility_missing_waza.store(0, std::memory_order_release);
            m_damage_utility_source_conflicts.store(0, std::memory_order_release);
            m_damage_utility_nested_finals.store(0, std::memory_order_release);
            m_damage_utility_nested_exact.store(0, std::memory_order_release);
            m_damage_utility_nested_conflicts.store(0, std::memory_order_release);
            m_damage_utility_nested_attacker_misses.store(0, std::memory_order_release);
            m_damage_utility_nested_defender_misses.store(0, std::memory_order_release);
            m_damage_utility_nested_incomplete.store(0, std::memory_order_release);
            m_damage_utility_outside_scope_finals.store(0, std::memory_order_release);
            m_damage_utility_scope_errors.store(0, std::memory_order_release);
            m_damage_utility_errors.store(0, std::memory_order_release);
            m_damage_utility_probe_claims.store(0, std::memory_order_release);
            m_damage_utility_probe_samples.store(0, std::memory_order_release);
            m_damage_utility_probe_dropped.store(0, std::memory_order_release);
            m_damage_utility_probe_truncated.store(0, std::memory_order_release);
            m_pending_attack_recorded.store(0, std::memory_order_release);
            m_pending_attack_single.store(0, std::memory_order_release);
            m_pending_attack_agreed.store(0, std::memory_order_release);
            m_pending_attack_ambiguous.store(0, std::memory_order_release);
            m_pending_attack_missing.store(0, std::memory_order_release);
            m_pending_attack_expired.store(0, std::memory_order_release);
            m_pending_attack_overflow.store(0, std::memory_order_release);
            m_pending_attack_missing_actor.store(0, std::memory_order_release);
            m_reverse_pair_recorded.store(0, std::memory_order_release);
            m_reverse_pair_promoted.store(0, std::memory_order_release);
            m_reverse_pair_ambiguous.store(0, std::memory_order_release);
            m_reverse_pair_expired.store(0, std::memory_order_release);
            m_reverse_pair_overflow.store(0, std::memory_order_release);
            m_reverse_pair_source_consumed.store(0, std::memory_order_release);
        }

        auto probe_report() -> std::string
        {
            std::scoped_lock lock{m_probe_mutex};
            if (m_probe_reports.empty() && m_final_source_probe_reports.empty())
            {
                return "none";
            }
            std::ostringstream output;
            for (std::size_t index = 0; index < m_probe_reports.size(); ++index)
            {
                if (index > 0)
                {
                    output << " || ";
                }
                output << m_probe_reports[index];
            }
            for (const auto& report : m_final_source_probe_reports)
            {
                if (output.tellp() > 0)
                {
                    output << " || ";
                }
                output << report;
            }
            return output.str();
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
                   << "; script_callbacks_seen=" << m_script_callbacks_seen.load()
                   << "; action_hook="
                   << (m_action_source_ready.load() ? "true" : "false")
                   << "; effect_init_hook="
                   << (m_effect_initialize_ready.load() ? "true" : "false")
                   << "; filter_bind_hook="
                   << (m_filter_bind_ready.load() ? "true" : "false")
                   << "; filter_attack_callback_hook="
                   << (m_filter_attack_callback_ready.load() ? "true" : "false")
                   << "; filter_attack_callback_calls="
                   << m_filter_attack_callback_calls.load()
                   << "; filter_attack_callback_nested_finals="
                   << m_filter_attack_callback_nested_finals.load()
                   << "; filter_attack_callback_nested_exact="
                   << m_filter_attack_callback_nested_exact.load()
                   << "; filter_attack_callback_nested_conflicts="
                   << m_filter_attack_callback_nested_conflicts.load()
                   << "; filter_attack_callback_nested_incomplete="
                   << m_filter_attack_callback_nested_incomplete.load()
                   << "; filter_attack_callback_outside_scope_finals="
                   << m_filter_attack_callback_outside_scope_finals.load()
                   << "; filter_attack_callback_errors="
                   << m_filter_attack_callback_errors.load()
                   << "; damage_utility_hook="
                   << (m_damage_utility_ready.load() ? "true" : "false")
                   << "; damage_utility_calls=" << m_damage_utility_calls.load()
                   << "; damage_utility_layout_misses="
                   << m_damage_utility_layout_misses.load()
                   << "; damage_utility_missing_filter="
                   << m_damage_utility_missing_filter.load()
                   << "; damage_utility_missing_waza="
                   << m_damage_utility_missing_waza.load()
                   << "; damage_utility_nested_finals="
                   << m_damage_utility_nested_finals.load()
                   << "; damage_utility_nested_exact="
                   << m_damage_utility_nested_exact.load()
                   << "; damage_utility_nested_conflicts="
                   << m_damage_utility_nested_conflicts.load()
                   << "; damage_utility_nested_incomplete="
                   << m_damage_utility_nested_incomplete.load()
                   << "; damage_utility_outside_scope_finals="
                   << m_damage_utility_outside_scope_finals.load()
                   << "; damage_utility_scope_errors="
                   << m_damage_utility_scope_errors.load()
                   << "; damage_utility_errors=" << m_damage_utility_errors.load()
                   << "; action_begins=" << m_action_begin_matches.load()
                   << "; effect_initializes=" << m_effect_initialize_matches.load()
                   << "; attack_matches=" << m_attack_matches.load()
                   << "; attack_without_waza=" << m_attack_without_waza.load()
                   << "; attack_layout_misses=" << m_attack_layout_misses.load()
                   << "; attack_missing_defender=" << m_attack_missing_defender.load()
                   << "; attack_missing_source=" << m_attack_missing_source.load()
                   << "; attack_source_conflicts=" << m_attack_source_conflicts.load()
                   << "; attack_missing_waza=" << m_attack_missing_waza.load()
                   << "; attack_fingerprints_recorded="
                   << m_attack_fingerprints_recorded.load()
                   << "; attack_fingerprint_weak=" << m_attack_fingerprint_weak.load()
                   << "; attack_fingerprint_missing_actor="
                   << m_attack_fingerprint_missing_actor.load()
                   << "; pending_attack_recorded=" << m_pending_attack_recorded.load()
                   << "; pending_attack_single=" << m_pending_attack_single.load()
                   << "; pending_attack_agreed=" << m_pending_attack_agreed.load()
                   << "; pending_attack_ambiguous=" << m_pending_attack_ambiguous.load()
                   << "; pending_attack_missing=" << m_pending_attack_missing.load()
                   << "; pending_attack_expired=" << m_pending_attack_expired.load()
                   << "; pending_attack_overflow=" << m_pending_attack_overflow.load()
                   << "; pending_attack_missing_actor="
                   << m_pending_attack_missing_actor.load()
                   << "; reverse_pair_recorded=" << m_reverse_pair_recorded.load()
                   << "; reverse_pair_promoted=" << m_reverse_pair_promoted.load()
                   << "; reverse_pair_ambiguous=" << m_reverse_pair_ambiguous.load()
                   << "; reverse_pair_expired=" << m_reverse_pair_expired.load()
                   << "; reverse_pair_overflow=" << m_reverse_pair_overflow.load()
                   << "; reverse_pair_source_consumed="
                   << m_reverse_pair_source_consumed.load()
                   << "; probe_damage_callbacks=" << m_probe_damage_callbacks.load()
                   << "; probe_damage_functions=" << m_probe_damage_functions.load()
                   << "; probe_action_contexts=" << m_probe_action_contexts.load()
                   << "; probe_effect_contexts=" << m_probe_effect_contexts.load()
                   << "; probe_other_contexts=" << m_probe_other_contexts.load()
                   << "; probe_waza_samples=" << m_probe_waza_samples.load()
                   << "; probe_cache_overflow="
                   << (m_probe_cache_overflow.load() ? "true" : "false")
                   << "; final_source_probe_samples="
                   << m_final_source_probe_samples.load()
                   << "; final_source_probe_dropped="
                   << m_final_source_probe_dropped.load()
                   << "; final_source_probe_object_fields="
                   << m_final_source_probe_object_fields.load()
                   << "; final_source_probe_direct_ids="
                   << m_final_source_probe_direct_ids.load()
                   << "; final_source_probe_stack_frames="
                   << m_final_source_probe_stack_frames.load()
                   << "; final_source_probe_effect_frames="
                   << m_final_source_probe_effect_frames.load()
                   << "; final_source_probe_action_frames="
                   << m_final_source_probe_action_frames.load()
                   << "; final_source_probe_empty_fields="
                   << m_final_source_probe_empty_fields.load()
                   << "; final_source_probe_field_truncated="
                   << m_final_source_probe_field_truncated.load()
                   << "; final_source_probe_payload_truncated="
                   << m_final_source_probe_payload_truncated.load()
                   << "; final_source_schema_samples="
                   << m_final_source_schema_samples.load()
                   << "; final_source_schema_truncated="
                   << m_final_source_schema_truncated.load()
                   << "; filter_bind_matches=" << m_filter_bind_matches.load()
                   << "; exact_hits=" << m_exact_hits.load()
                   << "; fingerprint_candidate_hits="
                   << m_fingerprint_candidate_hits.load()
                   << "; final_fingerprint_weak=" << m_final_fingerprint_weak.load()
                   << "; final_fingerprint_missing=" << m_final_fingerprint_missing.load()
                   << "; final_fingerprint_ambiguous="
                   << m_final_fingerprint_ambiguous.load()
                   << "; unresolved_hits=" << m_unresolved_hits.load()
                   << "; final_no_attack_scope=" << m_final_no_attack_scope.load()
                   << "; final_pair_misses=" << m_final_pair_misses.load()
                   << "; final_incomplete_scope=" << m_final_incomplete_scope.load()
                   << "; source_overflow="
                   << (m_source_overflow.load() ? "true" : "false")
                   << "; fingerprint_overflow="
                   << (m_fingerprint_overflow.load() ? "true" : "false")
                   << "; source_errors=" << m_source_errors.load();
            return output.str();
        }

        auto capabilities() const -> std::string
        {
            std::ostringstream output;
            const auto stream_ready = event_is_ready();
            output << "api_version=2"
                   << ";final_damage=true"
                   << ";exact_attribution=" << (stream_ready ? "conditional" : "false")
                   << ";action=" << (m_action_source_ready.load() ? "true" : "false")
                   << ";effect_init="
                   << (m_effect_initialize_ready.load() ? "true" : "false")
                   << ";attack_filter="
                   << (m_filter_bind_ready.load() ? "true" : "false")
                   << ";filter_attack_callback="
                   << (m_filter_attack_callback_ready.load() ? "true" : "false")
                   << ";damage_utility="
                   << (m_damage_utility_ready.load() ? "true" : "false")
                   << ";effect_attack=" << (stream_ready ? "true" : "false")
                   << ";damage_info=false;status=false"
                   << ";final_source_probe=diagnostic_only"
                   << ";final_source_probe_limit=" << maximum_final_source_probe_samples
                   << ";action_observed="
                   << (m_action_begin_matches.load() > 0 ? "true" : "false")
                   << ";effect_init_observed="
                   << (m_effect_initialize_matches.load() > 0 ? "true" : "false")
                   << ";filter_bind_observed="
                   << (m_filter_bind_matches.load() > 0 ? "true" : "false")
                   << ";effect_attack_observed="
                   << (m_attack_matches.load() > 0 ? "true" : "false")
                   << ";action_matches=" << m_action_begin_matches.load()
                   << ";effect_init_matches=" << m_effect_initialize_matches.load()
                   << ";filter_bind_matches=" << m_filter_bind_matches.load()
                   << ";filter_attack_callback_calls="
                   << m_filter_attack_callback_calls.load()
                   << ";filter_attack_callback_nested_exact="
                   << m_filter_attack_callback_nested_exact.load()
                   << ";damage_utility_calls=" << m_damage_utility_calls.load()
                   << ";damage_utility_nested_finals="
                   << m_damage_utility_nested_finals.load()
                   << ";damage_utility_nested_exact="
                   << m_damage_utility_nested_exact.load()
                   << ";effect_attack_matches=" << m_attack_matches.load()
                   << ";attack_fingerprints_recorded="
                   << m_attack_fingerprints_recorded.load()
                   << ";attack_fingerprint_weak=" << m_attack_fingerprint_weak.load()
                   << ";pending_attack_recorded=" << m_pending_attack_recorded.load()
                   << ";pending_attack_single=" << m_pending_attack_single.load()
                   << ";pending_attack_agreed=" << m_pending_attack_agreed.load()
                   << ";pending_attack_ambiguous=" << m_pending_attack_ambiguous.load()
                   << ";pending_attack_missing=" << m_pending_attack_missing.load()
                   << ";pending_attack_expired=" << m_pending_attack_expired.load()
                   << ";reverse_pair=experimental_unique_only"
                   << ";reverse_pair_recorded=" << m_reverse_pair_recorded.load()
                   << ";reverse_pair_promoted=" << m_reverse_pair_promoted.load()
                   << ";reverse_pair_ambiguous=" << m_reverse_pair_ambiguous.load()
                   << ";reverse_pair_expired=" << m_reverse_pair_expired.load()
                   << ";reverse_pair_overflow=" << m_reverse_pair_overflow.load()
                   << ";probe_damage_callbacks=" << m_probe_damage_callbacks.load()
                   << ";probe_damage_functions=" << m_probe_damage_functions.load()
                   << ";probe_action_contexts=" << m_probe_action_contexts.load()
                   << ";probe_effect_contexts=" << m_probe_effect_contexts.load()
                   << ";probe_other_contexts=" << m_probe_other_contexts.load()
                   << ";probe_waza_samples=" << m_probe_waza_samples.load()
                   << ";final_source_probe_samples="
                   << m_final_source_probe_samples.load()
                   << ";final_source_probe_dropped="
                   << m_final_source_probe_dropped.load()
                   << ";final_source_probe_direct_ids="
                   << m_final_source_probe_direct_ids.load()
                   << ";final_source_probe_effect_frames="
                   << m_final_source_probe_effect_frames.load()
                   << ";final_source_probe_action_frames="
                   << m_final_source_probe_action_frames.load()
                   << ";exact_hit_matches=" << m_exact_hits.load()
                   << ";fingerprint_candidate_hits="
                   << m_fingerprint_candidate_hits.load()
                   << ";fingerprint_ambiguous_hits="
                   << m_final_fingerprint_ambiguous.load()
                   << ";unresolved_hits=" << m_unresolved_hits.load()
                   << ";final_no_attack_scope=" << m_final_no_attack_scope.load()
                   << ";final_pair_misses=" << m_final_pair_misses.load()
                   << ";final_incomplete_scope=" << m_final_incomplete_scope.load();
            return output.str();
        }

      private:
        static auto apply_pending_attack_source(
            pal_dps::NativeEvent& event,
            const pal_dps::PendingAttackSource& source,
            const std::string_view evidence_kind
        ) -> void
        {
            event.action = source.action;
            event.effect = source.effect;
            event.parent_effect = source.parent_effect;
            event.filter = source.filter;
            event.cast = source.cast;
            event.waza_id = source.waza_id;
            event.skill_code.assign(source.skill_code);
            event.evidence_kind.assign(evidence_kind);
        }

        auto decrement_unresolved_if_positive() -> void
        {
            auto value = m_unresolved_hits.load(std::memory_order_relaxed);
            while (value > 0 && !m_unresolved_hits.compare_exchange_weak(
                value, value - 1, std::memory_order_relaxed
            ))
            {
            }
        }

        auto enqueue_released_pending_final_damage(
            std::vector<pal_dps::NativeEvent> events,
            const std::size_t expired_count
        ) -> void
        {
            for (std::size_t index = 0; index < events.size(); ++index)
            {
                events[index].evidence_kind.assign(
                    index < expired_count
                        ? "unresolved_post_effect_timeout"
                        : "unresolved_post_effect_pair_ambiguous"
                );
                static_cast<void>(m_event_queue.enqueue(std::move(events[index])));
            }
        }

        auto flush_expired_pending_final_damage() -> void
        {
            std::vector<pal_dps::NativeEvent> expired{};
            {
                std::scoped_lock lock{m_final_damage_matcher_mutex};
                expired = m_pending_final_damage.flush_expired(
                    captured_nanoseconds(), maximum_pending_final_damage_age_ns
                );
            }
            if (expired.empty())
            {
                return;
            }
            const auto expired_count = expired.size();
            m_reverse_pair_expired.fetch_add(expired_count, std::memory_order_relaxed);
            enqueue_released_pending_final_damage(std::move(expired), expired_count);
        }

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

        auto append_final_source_schema(
            UStruct* owner,
            const std::string& prefix,
            const std::size_t depth,
            std::size_t& field_count,
            bool& truncated,
            std::ostringstream& output,
            FProperty* skip_property = nullptr
        ) const -> void
        {
            if (owner == nullptr || depth > 2 || truncated)
            {
                return;
            }
            for (TFieldIterator<FProperty> iterator{
                     owner, EFieldIterationFlags::IncludeSuper
                 };
                 iterator;
                 ++iterator)
            {
                if (field_count >= maximum_final_source_schema_fields)
                {
                    truncated = true;
                    return;
                }
                auto* property = *iterator;
                if (property == skip_property)
                {
                    continue;
                }
                const auto name = field_name(property);
                const auto path = prefix.empty() ? name : prefix + "." + name;
                if (field_count++ > 0)
                {
                    output << ',';
                }
                output << path << ':' << RC::to_string(property->GetClass().GetName());
                if (auto* structure = CastField<FStructProperty>(property);
                    structure != nullptr && structure->GetStruct().Get() != nullptr)
                {
                    append_final_source_schema(
                        structure->GetStruct().Get(), path, depth + 1,
                        field_count, truncated, output
                    );
                }
            }
        }

        auto append_final_source_values(
            UStruct* owner,
            void* container,
            const std::string& prefix,
            const std::size_t depth,
            std::size_t& visited_count,
            std::size_t& field_count,
            bool& truncated,
            std::ostringstream& output,
            FProperty* skip_property = nullptr
        ) -> void
        {
            if (owner == nullptr || container == nullptr || depth > 2 || truncated)
            {
                return;
            }
            for (TFieldIterator<FProperty> iterator{
                     owner, EFieldIterationFlags::IncludeSuper
                 };
                 iterator;
                 ++iterator)
            {
                auto* property = *iterator;
                if (property == skip_property)
                {
                    continue;
                }
                if (visited_count++ >= maximum_final_source_probe_visited_fields)
                {
                    truncated = true;
                    return;
                }
                const auto name = field_name(property);
                const auto path = prefix.empty() ? name : prefix + "." + name;
                const auto object_property = CastField<FObjectPropertyBase>(property) != nullptr
                    || CastField<FWeakObjectProperty>(property) != nullptr;
                if (object_property)
                {
                    auto* object = ObjectField{property}.read(container);
                    if (object == nullptr)
                    {
                        continue;
                    }
                    if (field_count >= maximum_final_source_probe_fields)
                    {
                        truncated = true;
                        return;
                    }
                    if (field_count++ > 0)
                    {
                        output << ',';
                    }
                    output << path << "=object(" << token_text(object_token(object));
                    if (object->GetClassPrivate() != nullptr)
                    {
                        output << '@' << RC::to_string(object->GetClassPrivate()->GetFullName());
                    }
                    output << ')';
                    ++m_final_source_probe_object_fields;
                    continue;
                }

                if (is_direct_source_identifier(name))
                {
                    const auto value = read_integer_property(property, container);
                    if (value.has_value())
                    {
                        if (field_count >= maximum_final_source_probe_fields)
                        {
                            truncated = true;
                            return;
                        }
                        if (field_count++ > 0)
                        {
                            output << ',';
                        }
                        output << path << "=id(" << value.value();
                        const auto code = enum_code(property, value.value());
                        if (!code.empty())
                        {
                            output << '@' << code;
                        }
                        output << ')';
                        ++m_final_source_probe_direct_ids;
                        continue;
                    }
                }

                if (auto* structure = CastField<FStructProperty>(property);
                    structure != nullptr && structure->GetStruct().Get() != nullptr)
                {
                    auto* nested = structure->ContainerPtrToValuePtr<void>(container);
                    append_final_source_values(
                        structure->GetStruct().Get(), nested, path, depth + 1,
                        visited_count, field_count, truncated, output
                    );
                }
            }
        }

        auto probe_final_damage_source(
            UnrealScriptFunctionCallableContext& context,
            void* result,
            const std::uint64_t unresolved,
            const std::string_view reason
        ) -> void
        {
            const auto slot = m_final_source_probe_claims.fetch_add(
                1, std::memory_order_relaxed
            );
            if (slot >= maximum_final_source_probe_samples)
            {
                ++m_final_source_probe_dropped;
                return;
            }
            ++m_final_source_probe_samples;

            if (!m_final_source_schema_emitted.exchange(true, std::memory_order_acq_rel))
            {
                std::ostringstream schema;
                schema << "final-source-schema diagnostic_only=true result_struct="
                       << (m_layout.result_struct != nullptr
                           ? RC::to_string(m_layout.result_struct->GetFullName())
                           : std::string{"none"})
                       << " fields=[";
                std::size_t schema_fields{};
                bool schema_truncated{};
                if (m_layout.damage_info != nullptr
                    && m_layout.damage_info->GetStruct().Get() != nullptr)
                {
                    const auto info_prefix = "result."
                        + field_name(m_layout.damage_info);
                    append_final_source_schema(
                        m_layout.damage_info->GetStruct().Get(), info_prefix, 0,
                        schema_fields, schema_truncated, schema
                    );
                }
                append_final_source_schema(
                    m_layout.result_struct, "result", 0,
                    schema_fields, schema_truncated, schema, m_layout.damage_info
                );
                schema << ']';
                auto payload = bounded_log_payload(schema.str(), schema_truncated);
                if (schema_truncated)
                {
                    ++m_final_source_schema_truncated;
                }
                ++m_final_source_schema_samples;
                log(RC::to_wstring(payload));
            }

            std::ostringstream message;
            message << "final-source-probe diagnostic_only=true sample=" << (slot + 1)
                    << " unresolved=" << unresolved
                    << " reason=" << reason
                    << " hook="
                    << (m_damage_function != nullptr
                        ? RC::to_string(m_damage_function->GetFullName())
                        : std::string{"none"})
                    << " context=" << token_text(object_token(context.Context)) << '@'
                    << (context.Context != nullptr
                            && context.Context->GetClassPrivate() != nullptr
                        ? RC::to_string(context.Context->GetClassPrivate()->GetFullName())
                        : std::string{"none"});

            message << " stack=[";
            auto* frame = &context.TheStack;
            std::size_t stack_depth{};
            while (frame != nullptr && stack_depth < maximum_final_source_stack_depth)
            {
                if (stack_depth > 0)
                {
                    message << ';';
                }
                auto* node = frame->Node();
                auto* native_function = frame->CurrentNativeFunction();
                auto* frame_object = frame->Object();
                message << stack_depth << "{node="
                        << (node != nullptr
                            ? RC::to_string(node->GetFullName())
                            : std::string{"none"})
                        << ",native="
                        << (native_function != nullptr
                            ? RC::to_string(native_function->GetFullName())
                            : std::string{"none"})
                        << ",object=" << token_text(object_token(frame_object)) << '@'
                        << (frame_object != nullptr
                                && frame_object->GetClassPrivate() != nullptr
                            ? RC::to_string(frame_object->GetClassPrivate()->GetFullName())
                            : std::string{"none"})
                        << '}';
                ++m_final_source_probe_stack_frames;
                if (frame_object != nullptr && m_skill_effect_base_class != nullptr
                    && frame_object->IsA(m_skill_effect_base_class))
                {
                    ++m_final_source_probe_effect_frames;
                }
                if (frame_object != nullptr && m_action_base_class != nullptr
                    && frame_object->IsA(m_action_base_class))
                {
                    ++m_final_source_probe_action_frames;
                }
                frame = frame->PreviousFrame();
                ++stack_depth;
            }
            message << "] source_fields=[";

            std::size_t source_fields{};
            std::size_t visited_source_fields{};
            bool source_truncated{};
            if (m_layout.damage_info != nullptr
                && m_layout.damage_info->GetStruct().Get() != nullptr)
            {
                auto* damage_info = m_layout.damage_info->ContainerPtrToValuePtr<void>(result);
                const auto info_prefix = "result." + field_name(m_layout.damage_info);
                append_final_source_values(
                    m_layout.damage_info->GetStruct().Get(), damage_info, info_prefix, 0,
                    visited_source_fields, source_fields, source_truncated, message
                );
            }
            append_final_source_values(
                m_layout.result_struct, result, "result", 0,
                visited_source_fields, source_fields, source_truncated, message,
                m_layout.damage_info
            );
            message << ']';
            if (source_fields == 0)
            {
                ++m_final_source_probe_empty_fields;
            }
            if (source_truncated)
            {
                ++m_final_source_probe_field_truncated;
            }
            bool payload_truncated{};
            auto payload = bounded_log_payload(message.str(), payload_truncated);
            if (payload_truncated)
            {
                ++m_final_source_probe_payload_truncated;
            }
            {
                std::scoped_lock lock{m_probe_mutex};
                if (m_final_source_probe_reports.size()
                    < maximum_final_source_probe_samples)
                {
                    m_final_source_probe_reports.push_back(payload);
                }
            }
            log(RC::to_wstring(payload));
        }

        auto initialize_skill_source_hooks() -> void
        {
            m_skill_effect_base_class = UObjectGlobals::StaticFindObject<UClass*>(
                nullptr, nullptr, skill_effect_base_class_path
            );
            m_attack_filter_class = UObjectGlobals::StaticFindObject<UClass*>(
                nullptr, nullptr, attack_filter_class_path
            );
            m_action_base_class = UObjectGlobals::StaticFindObject<UClass*>(
                nullptr, nullptr, action_base_class_path
            );
            if (m_skill_effect_base_class == nullptr || m_attack_filter_class == nullptr
                || m_action_base_class == nullptr)
            {
                log(STR("Pal action/skill-effect classes were not found"));
                return;
            }

            Hook::FCallbackOptions pre_options{};
            pre_options.bReadonly = true;
            pre_options.OwnerModName = STR("PalSkillDPSAnalyzer");
            pre_options.HookName = STR("ExactSkillSourcePre");
            m_script_pre_id = Hook::RegisterProcessLocalScriptFunctionPreCallback(
                [this](Hook::TCallbackIterationData<void>&, UObject* context, FFrame& stack, void*) {
                    try
                    {
                        capture_script_source_pre(context, stack);
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
            post_options.HookName = STR("ExactSkillSourcePost");
            m_script_post_id = Hook::RegisterProcessLocalScriptFunctionPostCallback(
                [this](Hook::TCallbackIterationData<void>&, UObject* context, FFrame& stack, void*) {
                    try
                    {
                        capture_script_source_post(context, stack);
                    }
                    catch (...)
                    {
                        ++m_source_errors;
                    }
                },
                post_options
            );

            const auto script_hooks_ready = m_script_pre_id != Hook::ERROR_ID
                && m_script_post_id != Hook::ERROR_ID;

            m_action_begin_function = UObjectGlobals::StaticFindObject<UFunction*>(
                nullptr, nullptr, STR("/Script/Pal.PalActionBase:OnBeginAction")
            );
            auto action_observable = script_hooks_ready
                && is_script_function(m_action_begin_function);
            if (is_native_function(m_action_begin_function))
            {
                m_action_begin_pre_hook_id = m_action_begin_function->RegisterPreHook(
                    [this](UnrealScriptFunctionCallableContext& context, void*) {
                        try
                        {
                            capture_action_begin_pre(
                                context.Context, m_action_begin_function
                            );
                        }
                        catch (...)
                        {
                            ++m_source_errors;
                        }
                    }
                );
                m_action_begin_post_hook_id = m_action_begin_function->RegisterPostHook(
                    [this](UnrealScriptFunctionCallableContext& context, void*) {
                        try
                        {
                            capture_action_begin_post(
                                context.Context, m_action_begin_function
                            );
                        }
                        catch (...)
                        {
                            ++m_source_errors;
                        }
                    }
                );
                action_observable = m_action_begin_pre_hook_id >= 0
                    && m_action_begin_post_hook_id >= 0;
            }

            m_effect_initialize_function = UObjectGlobals::StaticFindObject<UFunction*>(
                nullptr, nullptr, STR("/Script/Pal.PalSkillEffectBase:OnInitialize")
            );
            auto effect_initialize_observable = script_hooks_ready
                && is_script_function(m_effect_initialize_function);
            if (is_native_function(m_effect_initialize_function))
            {
                m_effect_initialize_pre_hook_id = m_effect_initialize_function->RegisterPreHook(
                    [this](UnrealScriptFunctionCallableContext& context, void*) {
                        try
                        {
                            capture_effect_initialize_pre(context.Context);
                        }
                        catch (...)
                        {
                            ++m_source_errors;
                        }
                    }
                );
                m_effect_initialize_post_hook_id = m_effect_initialize_function->RegisterPostHook(
                    [this](UnrealScriptFunctionCallableContext& context, void*) {
                        try
                        {
                            capture_effect_initialize_post(context.Context);
                        }
                        catch (...)
                        {
                            ++m_source_errors;
                        }
                    }
                );
                effect_initialize_observable = m_effect_initialize_pre_hook_id >= 0
                    && m_effect_initialize_post_hook_id >= 0;
            }

            m_filter_bind_function = UObjectGlobals::StaticFindObject<UFunction*>(
                nullptr, nullptr, STR("/Script/Pal.PalAttackFilter:BindPrimitiveComponent")
            );
            auto filter_bind_observable = script_hooks_ready
                && is_script_function(m_filter_bind_function);
            if (is_native_function(m_filter_bind_function))
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
                filter_bind_observable = m_filter_bind_hook_id >= 0;
            }

            m_damage_utility_function = UObjectGlobals::StaticFindObject<UFunction*>(
                nullptr, nullptr, damage_utility_function_path
            );
            auto damage_utility_observable = script_hooks_ready
                && is_script_function(m_damage_utility_function);
            if (is_native_function(m_damage_utility_function))
            {
                m_damage_utility_pre_hook_id = m_damage_utility_function->RegisterPreHook(
                    [this](UnrealScriptFunctionCallableContext& context, void*) {
                        try
                        {
                            capture_damage_utility_pre(
                                context.Context, context.TheStack, m_damage_utility_function
                            );
                        }
                        catch (...)
                        {
                            ++m_damage_utility_errors;
                            ++m_source_errors;
                        }
                    }
                );
                m_damage_utility_post_hook_id = m_damage_utility_function->RegisterPostHook(
                    [this](UnrealScriptFunctionCallableContext& context, void*) {
                        try
                        {
                            capture_damage_utility_post(
                                context.Context, m_damage_utility_function
                            );
                        }
                        catch (...)
                        {
                            ++m_damage_utility_errors;
                            ++m_source_errors;
                        }
                    }
                );
                damage_utility_observable = m_damage_utility_pre_hook_id >= 0
                    && m_damage_utility_post_hook_id >= 0;
            }

            m_filter_attack_callback_function = UObjectGlobals::StaticFindObject<UFunction*>(
                nullptr, nullptr,
                STR("/Script/Pal.PalAttackFilter:CallBackOnAttackDelegate")
            );
            auto filter_attack_callback_observable = script_hooks_ready
                && is_script_function(m_filter_attack_callback_function);
            if (is_native_function(m_filter_attack_callback_function))
            {
                m_filter_attack_callback_pre_hook_id =
                    m_filter_attack_callback_function->RegisterPreHook(
                        [this](UnrealScriptFunctionCallableContext& context, void*) {
                            try
                            {
                                capture_filter_attack_callback_pre(
                                    context.Context, context.TheStack,
                                    m_filter_attack_callback_function
                                );
                            }
                            catch (...)
                            {
                                ++m_filter_attack_callback_errors;
                                ++m_source_errors;
                            }
                        }
                    );
                m_filter_attack_callback_post_hook_id =
                    m_filter_attack_callback_function->RegisterPostHook(
                        [this](UnrealScriptFunctionCallableContext& context, void*) {
                            try
                            {
                                capture_filter_attack_callback_post(
                                    context.Context, m_filter_attack_callback_function
                                );
                            }
                            catch (...)
                            {
                                ++m_filter_attack_callback_errors;
                                ++m_source_errors;
                            }
                        }
                    );
                filter_attack_callback_observable =
                    m_filter_attack_callback_pre_hook_id >= 0
                    && m_filter_attack_callback_post_hook_id >= 0;
            }

            m_action_source_ready.store(action_observable, std::memory_order_release);
            m_effect_initialize_ready.store(
                effect_initialize_observable, std::memory_order_release
            );
            m_filter_bind_ready.store(filter_bind_observable, std::memory_order_release);
            m_filter_attack_callback_ready.store(
                filter_attack_callback_observable, std::memory_order_release
            );
            m_damage_utility_ready.store(
                damage_utility_observable, std::memory_order_release
            );
            // The global Blueprint script callbacks are the only mandatory
            // prerequisite for the Event v2 stream. OnAttack can discover the
            // effect/filter/Waza directly and backfill its source record even
            // when OnInitialize or BindPrimitiveComponent was not observable
            // at startup. Keep emitting every final hit and fail closed per hit
            // instead of disabling the whole stream and falling back to timing
            // inference.
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
            auto record = ensure_effect_source(outer, filter);
            if (!record.has_value())
            {
                return;
            }

            {
                std::scoped_lock lock{m_source_mutex};
                const auto known = m_effect_filters.find(effect_token);
                if (known == m_effect_filters.end())
                {
                    m_effect_filters.emplace(effect_token, filter_token);
                }
                else if (known->second != filter_token)
                {
                    m_ambiguous_effect_filters.insert(effect_token);
                }
                m_filter_effects.insert_or_assign(filter_token, effect_token);
            }
            ++m_filter_bind_matches;
        }

        auto read_object_member(
            UObject* object,
            std::initializer_list<std::string_view> names
        ) const -> UObject*
        {
            if (object == nullptr || object->GetClassPrivate() == nullptr)
            {
                return nullptr;
            }
            return find_object_field(object->GetClassPrivate(), names).read(object);
        }

        auto capture_action_begin_pre(UObject* action, UFunction* function) -> void
        {
            if (action == nullptr || function == nullptr || m_action_base_class == nullptr
                || !action->IsA(m_action_base_class))
            {
                return;
            }
            const auto action_token = object_token(action);
            if (!action_token.valid())
            {
                return;
            }

            pal_dps::CastToken cast{};
            bool emit_cast{};
            if (!active_action_scopes.empty()
                && active_action_scopes.back().context == action)
            {
                cast = active_action_scopes.back().cast;
            }
            else
            {
                std::scoped_lock lock{m_source_mutex};
                cast = {m_next_cast_value++};
                emit_cast = true;
            }
            active_action_scopes.push_back({
                .function = function,
                .context = action,
                .action = action_token,
                .cast = cast,
            });

            // Keep lifecycle records internal for now. The public API-v2 queue
            // remains damage-only so existing Lua consumers stay compatible.
            if (emit_cast)
            {
                ++m_action_begin_matches;
            }
        }

        auto capture_action_begin_post(UObject* action, UFunction* function) -> void
        {
            if (active_action_scopes.empty())
            {
                return;
            }
            const auto& scope = active_action_scopes.back();
            if (scope.function == function && scope.context == action)
            {
                active_action_scopes.pop_back();
                return;
            }
            active_action_scopes.clear();
            ++m_source_errors;
        }

        auto ensure_effect_source(
            UObject* effect,
            UObject* direct_filter = nullptr,
            std::size_t depth = 0
        ) -> std::optional<EffectSourceRecord>
        {
            if (effect == nullptr || m_skill_effect_base_class == nullptr
                || !effect->IsA(m_skill_effect_base_class) || depth > 16)
            {
                return std::nullopt;
            }
            const auto effect_token = object_token(effect);
            if (!effect_token.valid())
            {
                return std::nullopt;
            }

            auto* owner = read_object_member(effect, {"Owner"});
            auto* instigator = read_object_member(effect, {"Instigator"});
            pal_dps::ObjectToken parent_effect{};
            std::optional<EffectSourceRecord> parent_source{};
            if (owner != nullptr && owner->IsA(m_skill_effect_base_class))
            {
                parent_effect = object_token(owner);
                parent_source = ensure_effect_source(owner, nullptr, depth + 1);
            }

            auto* filter = direct_filter != nullptr
                ? direct_filter
                : find_attack_filter(effect, nullptr);
            const auto filter_token = object_token(filter);
            const auto [waza_id, skill_code] = read_filter_waza(filter);

            EffectSourceRecord result{};
            {
                std::scoped_lock lock{m_source_mutex};
                auto source = m_effect_sources.find(effect_token);
                if (source == m_effect_sources.end())
                {
                    if (m_effect_sources.size() >= maximum_source_records)
                    {
                        m_source_overflow.store(true, std::memory_order_release);
                        m_exact_source_ready.store(false, std::memory_order_release);
                        m_faulted.store(true, std::memory_order_release);
                        ++m_source_errors;
                        return std::nullopt;
                    }
                    EffectSourceRecord created{};
                    created.effect = effect_token;
                    created.parent_effect = parent_effect;
                    if (parent_source.has_value() && !parent_source->conflicted)
                    {
                        created.action = parent_source->action;
                        created.attacker = parent_source->attacker;
                        created.cast = parent_source->cast;
                    }
                    else if (!active_action_scopes.empty())
                    {
                        created.action = active_action_scopes.back().action;
                        created.cast = active_action_scopes.back().cast;
                    }
                    if (!created.attacker.valid())
                    {
                        created.attacker = object_token(instigator);
                    }
                    created.filter = filter_token;
                    created.waza_id = waza_id;
                    created.skill_code = skill_code;
                    source = m_effect_sources.emplace(effect_token, std::move(created)).first;
                }

                auto& record = source->second;
                if (parent_effect.valid())
                {
                    if (record.parent_effect.valid() && record.parent_effect != parent_effect)
                    {
                        record.conflicted = true;
                    }
                    else
                    {
                        record.parent_effect = parent_effect;
                    }
                    if (parent_source.has_value() && !parent_source->conflicted)
                    {
                        if (record.cast.valid() && parent_source->cast.valid()
                            && record.cast != parent_source->cast)
                        {
                            record.conflicted = true;
                        }
                        else if (!record.cast.valid())
                        {
                            record.cast = parent_source->cast;
                            record.action = parent_source->action;
                        }
                        if (!record.attacker.valid())
                        {
                            record.attacker = parent_source->attacker;
                        }
                    }
                }
                if (filter_token.valid())
                {
                    if (!record.filter.valid())
                    {
                        record.filter = filter_token;
                    }
                    m_filter_effects.insert_or_assign(filter_token, effect_token);
                }
                if (waza_id > 0)
                {
                    if (record.waza_id > 0 && record.waza_id != waza_id)
                    {
                        record.conflicted = true;
                    }
                    else
                    {
                        record.waza_id = waza_id;
                        record.skill_code = skill_code;
                    }
                }
                result = record;
            }
            return result;
        }

        auto capture_effect_initialize_pre(UObject* effect) -> void
        {
            static_cast<void>(ensure_effect_source(effect));
        }

        auto capture_effect_initialize_post(UObject* effect) -> void
        {
            auto source = ensure_effect_source(effect);
            if (!source.has_value())
            {
                return;
            }
            bool emit_initialize{};
            {
                std::scoped_lock lock{m_source_mutex};
                const auto known = m_effect_sources.find(source->effect);
                if (known != m_effect_sources.end() && !known->second.initialize_emitted)
                {
                    known->second.initialize_emitted = true;
                    source = known->second;
                    emit_initialize = true;
                }
            }
            if (emit_initialize)
            {
                ++m_effect_initialize_matches;
            }
        }

        auto find_attack_filter(UObject* effect, UFunction* handler) -> UObject*
        {
            if (effect == nullptr || effect->GetClassPrivate() == nullptr
                || m_attack_filter_class == nullptr)
            {
                return nullptr;
            }
            std::vector<std::pair<std::string, UObject*>> candidates{};
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
                    candidates.emplace_back(field_name(property), candidate);
                }
            }
            if (candidates.size() == 1)
            {
                return candidates.front().second;
            }
            if (handler != nullptr && !candidates.empty())
            {
                const auto handler_name = RC::to_string(handler->GetName());
                UObject* matched{};
                for (const auto& [property_name, candidate] : candidates)
                {
                    if (!property_name.empty()
                        && contains_ignore_case(handler_name, property_name))
                    {
                        if (matched != nullptr && matched != candidate)
                        {
                            return nullptr;
                        }
                        matched = candidate;
                    }
                }
                if (matched != nullptr)
                {
                    return matched;
                }
            }

            const auto effect_token = object_token(effect);
            pal_dps::ObjectToken filter_token{};
            {
                std::scoped_lock lock{m_source_mutex};
                if (m_ambiguous_effect_filters.contains(effect_token))
                {
                    return nullptr;
                }
                const auto known = m_effect_filters.find(effect_token);
                if (known != m_effect_filters.end())
                {
                    filter_token = known->second;
                }
            }
            return resolve_object(filter_token);
        }

        auto discover_attack_layout(UFunction* function) -> AttackFunctionLayout
        {
            AttackFunctionLayout layout{};
            if (function == nullptr)
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
                if (layout.attacker_component.property == nullptr
                    && equals_ignore_case(name, "AttackerComponent"))
                {
                    if (CastField<FObjectPropertyBase>(property) != nullptr
                        || CastField<FWeakObjectProperty>(property) != nullptr)
                    {
                        layout.attacker_component = {property};
                    }
                    continue;
                }
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
                if (layout.hit_count.property == nullptr
                    && (equals_ignore_case(name, "hitCount")
                        || equals_ignore_case(name, "HitCount")))
                {
                    if (auto* numeric = CastField<FNumericProperty>(property);
                        numeric != nullptr && numeric->IsInteger())
                    {
                        layout.hit_count = {numeric};
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

        auto cached_attack_layout(UFunction* function) -> AttackFunctionLayout
        {
            if (function == nullptr)
            {
                return {};
            }
            std::scoped_lock lock{m_probe_mutex};
            const auto known = m_attack_layout_cache.find(function);
            if (known != m_attack_layout_cache.end())
            {
                return known->second;
            }
            if (m_attack_layout_cache.size() >= maximum_discovered_script_functions)
            {
                m_probe_cache_overflow.store(true, std::memory_order_release);
                return {};
            }
            const auto layout = discover_attack_layout(function);
            m_attack_layout_cache.emplace(function, layout);
            return layout;
        }

        auto capture_damage_utility_pre(
            UObject* context,
            FFrame& stack,
            UFunction* function
        ) -> void
        {
            if (function == nullptr)
            {
                return;
            }

            ++m_damage_utility_calls;
            active_damage_utility_scopes.push_back({
                .function = function,
                .context = context,
            });
            auto& scope = active_damage_utility_scopes.back();

            const auto layout = cached_attack_layout(function);
            if (!layout.ready() || stack.Locals() == nullptr)
            {
                ++m_damage_utility_layout_misses;
                return;
            }

            auto* parameters = reinterpret_cast<std::byte*>(stack.Locals());
            auto* damage_info = layout.damage_info->ContainerPtrToValuePtr<void>(parameters);
            auto* info_attacker = layout.info_attacker.read(damage_info);
            auto* defender = layout.defender.read(parameters);
            scope.info_attacker = object_token(info_attacker);
            scope.link.defender = object_token(defender);

            UObject* selected_filter{};
            UObject* selected_effect{};
            auto selected_filter_token = pal_dps::ObjectToken{};
            auto selected_effect_token = pal_dps::ObjectToken{};
            bool source_conflicted{};

            auto accept_source = [&](UObject* candidate_filter, UObject* candidate_effect) {
                const auto candidate_filter_token = object_token(candidate_filter);
                if (!candidate_filter_token.valid())
                {
                    return;
                }
                if (selected_filter_token.valid()
                    && selected_filter_token != candidate_filter_token)
                {
                    source_conflicted = true;
                    return;
                }
                selected_filter = candidate_filter;
                selected_filter_token = candidate_filter_token;
                const auto candidate_effect_token = object_token(candidate_effect);
                if (!candidate_effect_token.valid())
                {
                    return;
                }
                if (selected_effect_token.valid()
                    && selected_effect_token != candidate_effect_token)
                {
                    // More than one effect may legitimately share a filter.
                    // Keep the direct filter/Waza identity and omit the
                    // ambiguous effect token instead of selecting one.
                    selected_effect = nullptr;
                    selected_effect_token = {};
                    return;
                }
                selected_effect = candidate_effect;
                selected_effect_token = candidate_effect_token;
            };

            auto* frame = &stack;
            for (std::size_t depth = 0;
                 frame != nullptr && depth < maximum_final_source_stack_depth;
                 frame = frame->PreviousFrame(), ++depth)
            {
                auto* frame_object = frame->Object();
                auto* frame_function = frame->Node();
                if (frame_function == nullptr)
                {
                    frame_function = frame->CurrentNativeFunction();
                }
                if (frame_object == nullptr)
                {
                    continue;
                }

                UObject* candidate_filter{};
                UObject* candidate_effect{};
                if (m_attack_filter_class != nullptr
                    && frame_object->IsA(m_attack_filter_class))
                {
                    candidate_filter = frame_object;
                    const auto filter_token = object_token(frame_object);
                    pal_dps::ObjectToken effect_token{};
                    {
                        std::scoped_lock lock{m_source_mutex};
                        const auto known = m_filter_effects.find(filter_token);
                        if (known != m_filter_effects.end())
                        {
                            effect_token = known->second;
                        }
                    }
                    candidate_effect = resolve_object(effect_token);
                }
                else if (m_skill_effect_base_class != nullptr
                         && frame_object->IsA(m_skill_effect_base_class))
                {
                    candidate_effect = frame_object;
                    candidate_filter = find_attack_filter(frame_object, frame_function);
                }
                else
                {
                    auto* outer = frame_object->GetOuterPrivate();
                    for (std::size_t outer_depth = 0;
                         outer != nullptr && outer_depth < 8;
                         outer = outer->GetOuterPrivate(), ++outer_depth)
                    {
                        if (m_attack_filter_class != nullptr
                            && outer->IsA(m_attack_filter_class))
                        {
                            candidate_filter = outer;
                            break;
                        }
                        if (m_skill_effect_base_class != nullptr
                            && outer->IsA(m_skill_effect_base_class))
                        {
                            candidate_effect = outer;
                            candidate_filter = find_attack_filter(outer, frame_function);
                            break;
                        }
                    }
                }
                if (candidate_filter != nullptr)
                {
                    accept_source(candidate_filter, candidate_effect);
                    scope.stack_depth = depth;
                }
            }

            scope.link.filter = selected_filter_token;
            scope.link.effect = selected_effect_token;
            scope.stack_effect = selected_effect_token;
            scope.link.source_conflicted = source_conflicted;
            if (selected_filter != nullptr)
            {
                auto* filter_attacker = read_object_member(selected_filter, {"Attacker"});
                scope.link.attacker = object_token(filter_attacker);
                const auto [waza_id, skill_code] = read_filter_waza(selected_filter);
                scope.link.waza_id = waza_id;
                scope.link.skill_code = skill_code;
                if (scope.info_attacker.valid() && scope.link.attacker.valid()
                    && scope.info_attacker != scope.link.attacker)
                {
                    scope.link.source_conflicted = true;
                }
            }

            if (!scope.link.filter.valid())
            {
                ++m_damage_utility_missing_filter;
            }
            if (!scope.link.attacker.valid())
            {
                ++m_damage_utility_missing_attacker;
            }
            if (!scope.link.defender.valid())
            {
                ++m_damage_utility_missing_defender;
            }
            if (scope.link.waza_id <= 0 || scope.link.skill_code.empty())
            {
                ++m_damage_utility_missing_waza;
            }
            if (scope.link.source_conflicted)
            {
                ++m_damage_utility_source_conflicts;
            }

            const auto sample = m_damage_utility_probe_claims.fetch_add(
                1, std::memory_order_relaxed
            );
            if (sample < maximum_damage_utility_probe_samples)
            {
                std::ostringstream message;
                message << "damage-utility-probe diagnostic_only=true sample="
                        << (sample + 1)
                        << " function=" << RC::to_string(function->GetFullName())
                        << " context=" << token_text(object_token(context))
                        << " filter=" << token_text(scope.link.filter)
                        << " effect=" << token_text(scope.link.effect)
                        << " attacker=" << token_text(scope.link.attacker)
                        << " info_attacker=" << token_text(scope.info_attacker)
                        << " defender=" << token_text(scope.link.defender)
                        << " waza=" << scope.link.waza_id
                        << " code=" << scope.link.skill_code
                        << " stack_depth=" << scope.stack_depth
                        << " source_conflicted="
                        << (scope.link.source_conflicted ? "true" : "false");
                bool truncated{};
                const auto payload = bounded_log_payload(message.str(), truncated);
                if (truncated)
                {
                    ++m_damage_utility_probe_truncated;
                }
                ++m_damage_utility_probe_samples;
                {
                    std::scoped_lock lock{m_probe_mutex};
                    if (m_probe_reports.size() < maximum_damage_handler_probe_reports)
                    {
                        m_probe_reports.push_back(payload);
                    }
                }
                log(RC::to_wstring(payload));
            }
            else
            {
                ++m_damage_utility_probe_dropped;
            }
        }

        auto capture_damage_utility_post(UObject* context, UFunction* function) -> void
        {
            if (!active_damage_utility_scopes.empty())
            {
                const auto& scope = active_damage_utility_scopes.back();
                if (scope.function == function && scope.context == context)
                {
                    active_damage_utility_scopes.pop_back();
                    return;
                }
            }
            active_damage_utility_scopes.clear();
            ++m_damage_utility_scope_errors;
            ++m_source_errors;
        }

        auto capture_filter_attack_callback_pre(
            UObject* filter,
            FFrame& stack,
            UFunction* function
        ) -> void
        {
            if (filter == nullptr || function == nullptr || stack.Locals() == nullptr
                || m_attack_filter_class == nullptr || !filter->IsA(m_attack_filter_class))
            {
                return;
            }

            ++m_filter_attack_callback_calls;
            active_filter_attack_scopes.push_back({
                .function = function,
                .context = filter,
            });
            auto& scope = active_filter_attack_scopes.back();
            scope.link.filter = object_token(filter);

            const auto layout = cached_attack_layout(function);
            if (!layout.ready())
            {
                ++m_filter_attack_callback_layout_misses;
                return;
            }

            auto* parameters = reinterpret_cast<std::byte*>(stack.Locals());
            auto* damage_info = layout.damage_info->ContainerPtrToValuePtr<void>(parameters);
            auto* filter_attacker = read_object_member(filter, {"Attacker"});
            auto* info_attacker = layout.info_attacker.read(damage_info);
            auto* defender = layout.defender.read(parameters);
            auto* attacker_component = layout.attacker_component.read(parameters);
            const auto [waza_id, skill_code] = read_filter_waza(filter);
            auto* owner = filter->GetOuterPrivate();

            scope.link.attacker = object_token(filter_attacker);
            scope.link.defender = object_token(defender);
            scope.link.effect = owner != nullptr && m_skill_effect_base_class != nullptr
                    && owner->IsA(m_skill_effect_base_class)
                ? object_token(owner)
                : pal_dps::ObjectToken{};
            scope.link.waza_id = waza_id;
            scope.link.skill_code = skill_code;
            scope.info_attacker = object_token(info_attacker);
            scope.attacker_component = object_token(attacker_component);
            scope.owner_action_id = read_integer_property(
                find_property(filter->GetClassPrivate(), {"OwnerActionId", "OwnerActionID"}),
                filter
            );
            scope.hit_count = layout.hit_count.read(parameters);
            if (scope.info_attacker.valid() && scope.link.attacker.valid()
                && scope.info_attacker != scope.link.attacker)
            {
                scope.link.source_conflicted = true;
                ++m_filter_attack_callback_source_conflicts;
            }
            if (!scope.link.attacker.valid())
            {
                ++m_filter_attack_callback_missing_attacker;
            }
            if (!scope.link.defender.valid())
            {
                ++m_filter_attack_callback_missing_defender;
            }
            if (scope.link.waza_id <= 0 || scope.link.skill_code.empty())
            {
                ++m_filter_attack_callback_missing_waza;
            }

            const auto sample = m_filter_attack_callback_probe_claims.fetch_add(
                1, std::memory_order_relaxed
            );
            if (sample < maximum_filter_attack_callback_probe_samples)
            {
                std::ostringstream message;
                message << "filter-attack-callback diagnostic_only=true sample="
                        << (sample + 1)
                        << " function=" << RC::to_string(function->GetFullName())
                        << " filter=" << token_text(scope.link.filter)
                        << " attacker=" << token_text(scope.link.attacker)
                        << " info_attacker=" << token_text(scope.info_attacker)
                        << " defender=" << token_text(scope.link.defender)
                        << " attacker_component="
                        << token_text(scope.attacker_component)
                        << " effect=" << token_text(scope.link.effect)
                        << " owner_action_id="
                        << (scope.owner_action_id.has_value()
                            ? std::to_string(scope.owner_action_id.value())
                            : std::string{"none"})
                        << " waza=" << scope.link.waza_id
                        << " code=" << scope.link.skill_code
                        << " hit_count=" << scope.hit_count
                        << " source_conflicted="
                        << (scope.link.source_conflicted ? "true" : "false");
                bool truncated{};
                const auto payload = bounded_log_payload(message.str(), truncated);
                if (truncated)
                {
                    ++m_filter_attack_callback_probe_truncated;
                }
                ++m_filter_attack_callback_probe_samples;
                log(RC::to_wstring(payload));
            }
            else
            {
                ++m_filter_attack_callback_probe_dropped;
            }
        }

        auto capture_filter_attack_callback_post(
            UObject* filter,
            UFunction* function
        ) -> void
        {
            if (!active_filter_attack_scopes.empty())
            {
                const auto& scope = active_filter_attack_scopes.back();
                if (scope.function == function && scope.context == filter)
                {
                    active_filter_attack_scopes.pop_back();
                    return;
                }
            }
            active_filter_attack_scopes.clear();
            ++m_filter_attack_callback_scope_errors;
            ++m_source_errors;
        }

        auto probe_script_damage_handler(
            UObject* context,
            FFrame& stack,
            UFunction* function
        ) -> void
        {
            if (context == nullptr || stack.Locals() == nullptr || function == nullptr)
            {
                return;
            }
            const auto function_name = RC::to_string(function->GetName());
            if (!looks_like_damage_handler(function_name))
            {
                return;
            }
            const auto layout = cached_attack_layout(function);
            if (!layout.ready())
            {
                return;
            }

            ++m_probe_damage_callbacks;
            std::size_t sample_number{};
            bool first_function_sample{};
            {
                std::scoped_lock lock{m_probe_mutex};
                auto known = m_probe_samples_by_function.find(function);
                if (known == m_probe_samples_by_function.end())
                {
                    if (m_probe_samples_by_function.size()
                        >= maximum_damage_handler_probe_functions)
                    {
                        m_probe_cache_overflow.store(true, std::memory_order_release);
                        return;
                    }
                    known = m_probe_samples_by_function.emplace(function, 0).first;
                    first_function_sample = true;
                }
                if (known->second >= maximum_damage_handler_probe_samples)
                {
                    return;
                }
                sample_number = ++known->second;
            }
            if (first_function_sample)
            {
                ++m_probe_damage_functions;
            }

            const auto context_is_effect = m_skill_effect_base_class != nullptr
                && context->IsA(m_skill_effect_base_class);
            const auto context_is_action = m_action_base_class != nullptr
                && context->IsA(m_action_base_class);
            if (context_is_effect)
            {
                ++m_probe_effect_contexts;
            }
            else if (context_is_action)
            {
                ++m_probe_action_contexts;
            }
            else
            {
                ++m_probe_other_contexts;
            }

            auto* parameters = reinterpret_cast<std::byte*>(stack.Locals());
            auto* damage_info = layout.damage_info->ContainerPtrToValuePtr<void>(parameters);
            auto* attacker = layout.info_attacker.read(damage_info);
            auto* defender = layout.defender.read(parameters);
            auto* filter = find_attack_filter(context, function);
            const auto [waza_id, skill_code] = read_filter_waza(filter);
            if (waza_id > 0)
            {
                ++m_probe_waza_samples;
            }

            std::ostringstream message;
            message << "damage-handler-probe sample=" << sample_number
                    << " function=" << function_name
                    << " owner="
                    << (function->GetOuterPrivate() != nullptr
                        ? RC::to_string(function->GetOuterPrivate()->GetName())
                        : std::string{"none"})
                    << " context_class="
                    << (context->GetClassPrivate() != nullptr
                        ? RC::to_string(context->GetClassPrivate()->GetName())
                        : std::string{"none"})
                    << " context_kind="
                    << (context_is_effect ? "effect" : (context_is_action ? "action" : "other"))
                    << " attacker=" << token_text(object_token(attacker))
                    << " defender=" << token_text(object_token(defender))
                    << " filter=" << token_text(object_token(filter))
                    << " waza=" << waza_id
                    << " code=" << skill_code
                    << " hit_count=" << layout.hit_count.read(parameters);
            {
                std::scoped_lock lock{m_probe_mutex};
                if (m_probe_reports.size() < maximum_damage_handler_probe_reports)
                {
                    m_probe_reports.push_back(message.str());
                }
            }
            log(RC::to_wstring(message.str()));
        }

        auto capture_script_source_pre(UObject* context, FFrame& stack) -> void
        {
            auto* function = stack.Node();
            if (function == nullptr)
            {
                function = stack.CurrentNativeFunction();
            }
            if (function == nullptr)
            {
                return;
            }
            ++m_script_callbacks_seen;
            const auto function_name = RC::to_string(function->GetName());
            if (function == m_damage_utility_function)
            {
                ++m_script_calls;
                capture_damage_utility_pre(context, stack, function);
                return;
            }
            if (equals_ignore_case(function_name, "CallBackOnAttackDelegate")
                && context != nullptr && m_attack_filter_class != nullptr
                && context->IsA(m_attack_filter_class))
            {
                ++m_script_calls;
                capture_filter_attack_callback_pre(context, stack, function);
                return;
            }
            probe_script_damage_handler(context, stack, function);
            if (equals_ignore_case(function_name, "OnBeginAction")
                && context != nullptr && m_action_base_class != nullptr
                && context->IsA(m_action_base_class))
            {
                ++m_script_calls;
                capture_action_begin_pre(context, function);
                return;
            }
            if (equals_ignore_case(function_name, "OnInitialize")
                && context != nullptr && m_skill_effect_base_class != nullptr
                && context->IsA(m_skill_effect_base_class))
            {
                ++m_script_calls;
                capture_effect_initialize_pre(context);
                return;
            }
            if (equals_ignore_case(function_name, "BindPrimitiveComponent")
                && context != nullptr && m_attack_filter_class != nullptr
                && context->IsA(m_attack_filter_class))
            {
                ++m_script_calls;
                capture_filter_binding(context);
                return;
            }
            const auto context_is_effect = context != nullptr
                && m_skill_effect_base_class != nullptr
                && context->GetClassPrivate() != nullptr
                && context->GetClassPrivate()->IsChildOf(m_skill_effect_base_class);
            const auto damage_handler_name = looks_like_damage_handler(function_name);
            if (context_is_effect && damage_handler_name
                && cached_attack_layout(function).ready())
            {
                ++m_script_calls;
                capture_script_attack_pre(context, stack, function);
            }
        }

        auto capture_script_source_post(UObject* context, FFrame& stack) -> void
        {
            auto* function = stack.Node();
            if (function == nullptr)
            {
                function = stack.CurrentNativeFunction();
            }
            if (function == nullptr)
            {
                return;
            }
            const auto function_name = RC::to_string(function->GetName());
            if (function == m_damage_utility_function)
            {
                capture_damage_utility_post(context, function);
                return;
            }
            if (equals_ignore_case(function_name, "CallBackOnAttackDelegate")
                && context != nullptr && m_attack_filter_class != nullptr
                && context->IsA(m_attack_filter_class))
            {
                capture_filter_attack_callback_post(context, function);
                return;
            }
            // The pre-hook accepts reflected Pal effect handlers such as the
            // plain Blueprint "OnAttack" used by GravityShot, not only the
            // delegate-signature spelling. Pop by exact function/context so
            // unrelated script callbacks remain untouched.
            capture_script_attack_post(context, function);
            if (equals_ignore_case(function_name, "OnInitialize")
                && context != nullptr && m_skill_effect_base_class != nullptr
                && context->IsA(m_skill_effect_base_class))
            {
                capture_effect_initialize_post(context);
                return;
            }
            if (equals_ignore_case(function_name, "OnBeginAction")
                && context != nullptr && m_action_base_class != nullptr
                && context->IsA(m_action_base_class))
            {
                capture_action_begin_post(context, function);
            }
        }

        auto capture_script_attack_pre(
            UObject* context,
            FFrame& stack,
            UFunction* function
        ) -> void
        {
            if (context == nullptr || stack.Locals() == nullptr
                || m_skill_effect_base_class == nullptr
                || context->GetClassPrivate() == nullptr
                || !context->GetClassPrivate()->IsChildOf(m_skill_effect_base_class))
            {
                return;
            }

            active_attack_scopes.push_back({
                .function = function,
                .context = context,
                .effect = object_token(context),
            });
            auto& attack_scope = active_attack_scopes.back();

            auto layout = cached_attack_layout(function);
            if (!layout.ready())
            {
                ++m_attack_without_waza;
                ++m_attack_layout_misses;
                return;
            }

            auto* parameters = reinterpret_cast<std::byte*>(stack.Locals());
            auto* damage_info = layout.damage_info->ContainerPtrToValuePtr<void>(parameters);
            auto* attacker = layout.info_attacker.read(damage_info);
            auto* defender = layout.defender.read(parameters);
            attack_scope.attacker = object_token(attacker);
            attack_scope.defender = object_token(defender);
            if (defender == nullptr)
            {
                ++m_attack_without_waza;
                ++m_attack_missing_defender;
                return;
            }

            auto* filter = find_attack_filter(context, function);
            auto source = ensure_effect_source(context, filter);
            if (!source.has_value() || source->conflicted)
            {
                ++m_attack_without_waza;
                if (source.has_value() && source->conflicted)
                {
                    ++m_attack_source_conflicts;
                }
                else
                {
                    ++m_attack_missing_source;
                }
                return;
            }

            auto waza_id = source->waza_id;
            auto skill_code = source->skill_code;
            if (filter != nullptr)
            {
                const auto filter_waza = read_filter_waza(filter);
                if (filter_waza.first > 0)
                {
                    if (waza_id > 0 && waza_id != filter_waza.first)
                    {
                        ++m_source_errors;
                        ++m_attack_source_conflicts;
                        return;
                    }
                    waza_id = filter_waza.first;
                    skill_code = filter_waza.second;
                }
            }
            if (waza_id <= 0 || skill_code.empty())
            {
                ++m_attack_without_waza;
                ++m_attack_missing_waza;
                return;
            }

            const auto attacker_token = object_token(attacker);
            {
                std::scoped_lock lock{m_source_mutex};
                const auto known = m_effect_sources.find(source->effect);
                if (known == m_effect_sources.end())
                {
                    ++m_attack_missing_source;
                    return;
                }
                auto& record = known->second;
                if (record.attacker.valid() && attacker_token.valid()
                    && record.attacker != attacker_token)
                {
                    record.conflicted = true;
                    ++m_source_errors;
                    ++m_attack_source_conflicts;
                    return;
                }
                if (!record.attacker.valid())
                {
                    record.attacker = attacker_token;
                }
                source = record;
            }
            attack_scope.attacker = attacker_token.valid() ? attacker_token : source->attacker;
            attack_scope.action = source->action;
            attack_scope.effect = source->effect;
            attack_scope.parent_effect = source->parent_effect;
            attack_scope.filter = object_token(filter);
            attack_scope.cast = source->cast;
            attack_scope.waza_id = waza_id;
            attack_scope.skill_code = skill_code;
            ++m_attack_matches;

            if (attack_scope.attacker.valid() && attack_scope.defender.valid())
            {
                const pal_dps::PendingAttackSource pending_source{
                    .action = attack_scope.action,
                    .effect = attack_scope.effect,
                    .parent_effect = attack_scope.parent_effect,
                    .filter = attack_scope.filter,
                    .cast = attack_scope.cast,
                    .waza_id = attack_scope.waza_id,
                    .skill_code = attack_scope.skill_code,
                    .captured_ns = captured_nanoseconds(),
                };
                pal_dps::PendingFinalDamageMatch reverse_match{};
                {
                    std::scoped_lock lock{m_final_damage_matcher_mutex};
                    reverse_match = m_pending_final_damage.resolve(
                        attack_scope.attacker,
                        attack_scope.defender,
                        pending_source,
                        pending_source.captured_ns,
                        maximum_pending_final_damage_age_ns
                    );
                }
                if (reverse_match.expired_count > 0)
                {
                    m_reverse_pair_expired.fetch_add(
                        reverse_match.expired_count, std::memory_order_relaxed
                    );
                }
                if (reverse_match.kind
                    == pal_dps::PendingFinalDamageMatchKind::pending_ambiguous)
                {
                    m_reverse_pair_ambiguous.fetch_add(
                        reverse_match.candidate_count, std::memory_order_relaxed
                    );
                }
                enqueue_released_pending_final_damage(
                    std::move(reverse_match.released), reverse_match.expired_count
                );

                auto source_consumed = reverse_match.pair_expired_count > 0
                    || reverse_match.kind
                        != pal_dps::PendingFinalDamageMatchKind::no_pending;
                if (reverse_match.kind
                        == pal_dps::PendingFinalDamageMatchKind::unique_pending
                    && reverse_match.matched.has_value())
                {
                    auto matched = std::move(reverse_match.matched.value());
                    apply_pending_attack_source(
                        matched, pending_source, "post_effect_pair_single_link"
                    );
                    ++m_reverse_pair_promoted;
                    ++m_exact_hits;
                    decrement_unresolved_if_positive();
                    static_cast<void>(m_event_queue.enqueue(std::move(matched)));
                }
                if (source_consumed)
                {
                    ++m_reverse_pair_source_consumed;
                }
                else
                {
                    bool recorded{};
                    {
                        std::scoped_lock lock{m_attack_matcher_mutex};
                        recorded = m_pending_attacks.record(
                            attack_scope.attacker, attack_scope.defender, pending_source
                        );
                    }
                    if (recorded)
                    {
                        ++m_pending_attack_recorded;
                    }
                    else
                    {
                        ++m_pending_attack_overflow;
                        m_source_overflow.store(true, std::memory_order_release);
                        m_faulted.store(true, std::memory_order_release);
                        ++m_source_errors;
                    }
                }
            }
            else
            {
                ++m_pending_attack_missing_actor;
            }

            const auto* info_struct = layout.damage_info->GetStruct().Get();
            const auto fingerprint = build_damage_fingerprint(
                build_fingerprint_layout(const_cast<UScriptStruct*>(info_struct)), damage_info
            );
            if (!fingerprint.usable())
            {
                ++m_attack_fingerprint_weak;
                return;
            }
            if (!attack_scope.attacker.valid() || !attack_scope.defender.valid())
            {
                ++m_attack_fingerprint_missing_actor;
                return;
            }
            pal_dps::FingerprintSource fingerprint_source{
                .action = attack_scope.action,
                .effect = attack_scope.effect,
                .parent_effect = attack_scope.parent_effect,
                .filter = attack_scope.filter,
                .cast = attack_scope.cast,
                .waza_id = attack_scope.waza_id,
                .skill_code = attack_scope.skill_code,
            };
            bool recorded{};
            {
                std::scoped_lock lock{m_fingerprint_mutex};
                recorded = m_pending_fingerprints.record(
                    attack_scope.attacker,
                    attack_scope.defender,
                    fingerprint,
                    std::move(fingerprint_source)
                );
            }
            if (recorded)
            {
                ++m_attack_fingerprints_recorded;
            }
            else
            {
                m_fingerprint_overflow.store(true, std::memory_order_release);
                m_faulted.store(true, std::memory_order_release);
                ++m_source_errors;
            }
        }

        auto capture_script_attack_post(UObject* context, UFunction* function) -> void
        {
            if (!active_attack_scopes.empty())
            {
                const auto& scope = active_attack_scopes.back();
                if (scope.function == function && scope.context == context)
                {
                    active_attack_scopes.pop_back();
                    return;
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
                native_event.evidence_kind.assign("unresolved_no_attack_scope");

                const auto attacker_token = object_token(attacker);
                const auto defender_token = object_token(defender);
                pal_dps::PendingAttackMatch pending_attack_match{};
                {
                    std::scoped_lock lock{m_attack_matcher_mutex};
                    pending_attack_match = m_pending_attacks.resolve(
                        attacker_token,
                        defender_token,
                        native_event.captured_ns,
                        maximum_pending_attack_age_ns
                    );
                }
                m_pending_attack_expired.fetch_add(
                    pending_attack_match.expired_count, std::memory_order_relaxed
                );
                switch (pending_attack_match.kind)
                {
                case pal_dps::PendingAttackMatchKind::single_candidate:
                    ++m_pending_attack_single;
                    break;
                case pal_dps::PendingAttackMatchKind::agreed_candidate:
                    ++m_pending_attack_agreed;
                    break;
                case pal_dps::PendingAttackMatchKind::source_ambiguous:
                    ++m_pending_attack_ambiguous;
                    break;
                case pal_dps::PendingAttackMatchKind::no_candidate:
                    ++m_pending_attack_missing;
                    break;
                }
                pal_dps::FingerprintMatch fingerprint_match{};
                if (nested != nullptr && m_layout.damage_info != nullptr
                    && m_layout.damage_info->GetStruct().Get() != nullptr)
                {
                    const auto fingerprint = build_damage_fingerprint(
                        build_fingerprint_layout(const_cast<UScriptStruct*>(
                            m_layout.damage_info->GetStruct().Get()
                        )),
                        nested
                    );
                    {
                        std::scoped_lock lock{m_fingerprint_mutex};
                        fingerprint_match = m_pending_fingerprints.resolve(
                            attacker_token, defender_token, fingerprint
                        );
                    }
                    if (fingerprint_match.kind == pal_dps::FingerprintMatchKind::exact)
                    {
                        const auto& source = fingerprint_match.source;
                        native_event.action = source.action;
                        native_event.effect = source.effect;
                        native_event.parent_effect = source.parent_effect;
                        native_event.filter = source.filter;
                        native_event.cast = source.cast;
                        native_event.waza_id = source.waza_id;
                        native_event.skill_code.assign(source.skill_code);
                        // Equality across canonical DamageInfo fields is a
                        // diagnostic candidate, not object identity. Keep the
                        // source on the event for logging, but do not promote
                        // it to a confirmed skill bucket until live evidence
                        // proves this path stable across overlapping skills.
                        native_event.evidence_kind.assign(
                            "damage_info_fingerprint_candidate"
                        );
                        ++m_fingerprint_candidate_hits;
                    }
                    else if (fingerprint_match.kind
                             == pal_dps::FingerprintMatchKind::fingerprint_weak)
                    {
                        ++m_final_fingerprint_weak;
                    }
                    else if (fingerprint_match.kind
                             == pal_dps::FingerprintMatchKind::source_ambiguous)
                    {
                        ++m_final_fingerprint_ambiguous;
                    }
                    else
                    {
                        ++m_final_fingerprint_missing;
                    }
                }
                else
                {
                    fingerprint_match.kind = pal_dps::FingerprintMatchKind::fingerprint_weak;
                    ++m_final_fingerprint_weak;
                }
                bool confirmed_exact{};
                if (!active_damage_utility_scopes.empty())
                {
                    ++m_damage_utility_nested_finals;
                    const auto& utility_scope = active_damage_utility_scopes.back();
                    const auto utility_match = pal_dps::match_filter_callback_scope(
                        utility_scope.link, attacker_token, defender_token
                    );
                    switch (utility_match)
                    {
                    case pal_dps::FilterCallbackMatchKind::exact:
                        native_event.action = {};
                        native_event.parent_effect = {};
                        native_event.cast = {};
                        native_event.effect = utility_scope.link.effect;
                        native_event.filter = utility_scope.link.filter;
                        native_event.waza_id = utility_scope.link.waza_id;
                        native_event.skill_code.assign(utility_scope.link.skill_code);
                        // The final hit is synchronously nested under the
                        // engine damage utility, whose caller stack contains a
                        // concrete PalAttackFilter with matching
                        // Attacker/Defender/Waza. No timing, power, element or
                        // current-action inference participates.
                        native_event.evidence_kind.assign("direct_waza_token");
                        confirmed_exact = true;
                        ++m_damage_utility_nested_exact;
                        ++m_exact_hits;
                        break;
                    case pal_dps::FilterCallbackMatchKind::source_conflict:
                        ++m_damage_utility_nested_conflicts;
                        break;
                    case pal_dps::FilterCallbackMatchKind::attacker_mismatch:
                        ++m_damage_utility_nested_attacker_misses;
                        break;
                    case pal_dps::FilterCallbackMatchKind::defender_mismatch:
                        ++m_damage_utility_nested_defender_misses;
                        break;
                    case pal_dps::FilterCallbackMatchKind::incomplete:
                        ++m_damage_utility_nested_incomplete;
                        break;
                    }
                }
                else
                {
                    ++m_damage_utility_outside_scope_finals;
                }

                if (!confirmed_exact && !active_filter_attack_scopes.empty())
                {
                    ++m_filter_attack_callback_nested_finals;
                    const auto& callback_scope = active_filter_attack_scopes.back();
                    const auto callback_match = pal_dps::match_filter_callback_scope(
                        callback_scope.link, attacker_token, defender_token
                    );
                    switch (callback_match)
                    {
                    case pal_dps::FilterCallbackMatchKind::exact:
                        native_event.effect = callback_scope.link.effect;
                        native_event.filter = callback_scope.link.filter;
                        native_event.waza_id = callback_scope.link.waza_id;
                        native_event.skill_code.assign(callback_scope.link.skill_code);
                        // The filter is executing its own attack delegate on
                        // this thread, and its direct Attacker/Defender/Waza
                        // all match the final damage event. This is an engine
                        // identity chain, not a time/signature inference.
                        native_event.evidence_kind.assign("direct_waza_token");
                        confirmed_exact = true;
                        ++m_filter_attack_callback_nested_exact;
                        ++m_exact_hits;
                        break;
                    case pal_dps::FilterCallbackMatchKind::source_conflict:
                        ++m_filter_attack_callback_nested_conflicts;
                        break;
                    case pal_dps::FilterCallbackMatchKind::attacker_mismatch:
                        ++m_filter_attack_callback_nested_attacker_misses;
                        break;
                    case pal_dps::FilterCallbackMatchKind::defender_mismatch:
                        ++m_filter_attack_callback_nested_defender_misses;
                        break;
                    case pal_dps::FilterCallbackMatchKind::incomplete:
                        ++m_filter_attack_callback_nested_incomplete;
                        break;
                    }
                }
                else if (active_filter_attack_scopes.empty())
                {
                    ++m_filter_attack_callback_outside_scope_finals;
                }

                bool matched_pair{};
                bool matched_incomplete_scope{};
                for (auto scope = active_attack_scopes.rbegin();
                     !confirmed_exact && scope != active_attack_scopes.rend();
                     ++scope)
                {
                    if (scope->defender.valid() && scope->defender != defender_token)
                    {
                        continue;
                    }
                    if (scope->attacker.valid() && attacker_token.valid()
                        && scope->attacker != attacker_token)
                    {
                        continue;
                    }
                    matched_pair = true;
                    if (!scope->effect.valid() || scope->waza_id <= 0
                        || scope->skill_code.empty())
                    {
                        matched_incomplete_scope = true;
                        break;
                    }
                    native_event.action = scope->action;
                    native_event.effect = scope->effect;
                    native_event.parent_effect = scope->parent_effect;
                    native_event.filter = scope->filter;
                    native_event.cast = scope->cast;
                    native_event.waza_id = scope->waza_id;
                    native_event.skill_code.assign(scope->skill_code);
                    native_event.evidence_kind.assign(
                        scope->cast.valid() ? "effect_cast_link" : "effect_waza"
                    );
                    confirmed_exact = true;
                    ++m_exact_hits;
                    break;
                }
                if (!confirmed_exact)
                {
                    if (pending_attack_match.kind
                            == pal_dps::PendingAttackMatchKind::single_candidate
                        || pending_attack_match.kind
                            == pal_dps::PendingAttackMatchKind::agreed_candidate)
                    {
                        const auto& source = pending_attack_match.source;
                        native_event.action = source.action;
                        native_event.effect = source.effect;
                        native_event.parent_effect = source.parent_effect;
                        native_event.filter = source.filter;
                        native_event.cast = source.cast;
                        native_event.waza_id = source.waza_id;
                        native_event.skill_code.assign(source.skill_code);
                        native_event.evidence_kind.assign(
                            pending_attack_match.kind
                                    == pal_dps::PendingAttackMatchKind::single_candidate
                                ? "effect_pair_single_link"
                                : "effect_pair_agreed_link"
                        );
                        // One engine OnAttack source, or several sources that
                        // all agree on the same action/effect/Waza, is a
                        // deterministic pair link. Different simultaneous
                        // sources are source_ambiguous below and remain
                        // unresolved; no current-action, time-window,
                        // BasePower or element guess participates here.
                        confirmed_exact = true;
                        ++m_exact_hits;
                    }
                    else if (pending_attack_match.kind
                             == pal_dps::PendingAttackMatchKind::source_ambiguous)
                    {
                        native_event.action = {};
                        native_event.effect = {};
                        native_event.parent_effect = {};
                        native_event.filter = {};
                        native_event.cast = {};
                        native_event.waza_id = 0;
                        native_event.skill_code.assign("");
                        native_event.evidence_kind.assign(
                            "unresolved_effect_pair_ambiguous"
                        );
                    }
                }
                if (!confirmed_exact)
                {
                    const auto pending_diagnostic = pending_attack_match.kind
                            == pal_dps::PendingAttackMatchKind::single_candidate
                        || pending_attack_match.kind
                            == pal_dps::PendingAttackMatchKind::agreed_candidate
                        || pending_attack_match.kind
                            == pal_dps::PendingAttackMatchKind::source_ambiguous;
                    const auto fingerprint_diagnostic = fingerprint_match.kind
                        == pal_dps::FingerprintMatchKind::exact;
                    if (active_attack_scopes.empty())
                    {
                        if (!pending_diagnostic && fingerprint_match.kind
                            == pal_dps::FingerprintMatchKind::source_ambiguous)
                        {
                            native_event.evidence_kind.assign(
                                "unresolved_fingerprint_ambiguous"
                            );
                        }
                        else if (!pending_diagnostic && fingerprint_match.kind
                                 == pal_dps::FingerprintMatchKind::fingerprint_weak)
                        {
                            native_event.evidence_kind.assign("unresolved_fingerprint_weak");
                        }
                        else if (!pending_diagnostic && !fingerprint_diagnostic)
                        {
                            native_event.evidence_kind.assign(
                                "unresolved_fingerprint_no_candidate"
                            );
                        }
                        ++m_final_no_attack_scope;
                    }
                    else if (matched_incomplete_scope)
                    {
                        if (!pending_diagnostic && !fingerprint_diagnostic)
                        {
                            native_event.evidence_kind.assign("unresolved_incomplete_scope");
                        }
                        ++m_final_incomplete_scope;
                    }
                    else if (!matched_pair)
                    {
                        if (!pending_diagnostic && !fingerprint_diagnostic)
                        {
                            native_event.evidence_kind.assign("unresolved_pair_miss");
                        }
                        ++m_final_pair_misses;
                    }
                    const auto unresolved = ++m_unresolved_hits;
                    probe_final_damage_source(
                        context, result, unresolved, native_event.evidence_kind.view()
                    );
                    if (unresolved == 1 || unresolved % 64 == 0)
                    {
                        std::ostringstream checkpoint;
                        checkpoint << "attribution checkpoint unresolved=" << unresolved
                                   << " reason=" << native_event.evidence_kind.view()
                                   << " attack_matches=" << m_attack_matches.load()
                                   << " attack_without_waza=" << m_attack_without_waza.load()
                                   << " no_scope=" << m_final_no_attack_scope.load()
                                   << " pair_miss=" << m_final_pair_misses.load()
                                   << " incomplete_scope=" << m_final_incomplete_scope.load()
                                   << " fp_recorded=" << m_attack_fingerprints_recorded.load()
                                   << " fp_candidate="
                                   << m_fingerprint_candidate_hits.load()
                                   << " fp_weak=" << m_final_fingerprint_weak.load()
                                   << " fp_missing=" << m_final_fingerprint_missing.load()
                                   << " fp_ambiguous=" << m_final_fingerprint_ambiguous.load()
                                   << " pair_single=" << m_pending_attack_single.load()
                                   << " pair_agreed=" << m_pending_attack_agreed.load()
                                   << " pair_ambiguous=" << m_pending_attack_ambiguous.load()
                                   << " pair_missing=" << m_pending_attack_missing.load();
                        log(RC::to_wstring(checkpoint.str()));
                    }
                }
                if (confirmed_exact)
                {
                    static_cast<void>(m_event_queue.enqueue(std::move(native_event)));
                }
                else
                {
                    bool buffered{};
                    {
                        std::scoped_lock lock{m_final_damage_matcher_mutex};
                        buffered = m_pending_final_damage.record(native_event);
                    }
                    if (buffered)
                    {
                        ++m_reverse_pair_recorded;
                    }
                    else
                    {
                        ++m_reverse_pair_overflow;
                        native_event.evidence_kind.assign(
                            "unresolved_post_effect_buffer_overflow"
                        );
                        static_cast<void>(m_event_queue.enqueue(std::move(native_event)));
                    }
                }
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
            lua.set_string(s_instance == nullptr
                ? "api_version=2;final_damage=false;exact_attribution=false;action=false;"
                  "effect_init=false;attack_filter=false;effect_attack=false;"
                  "damage_info=false;status=false"
                : s_instance->capabilities());
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

        static auto lua_probe_report(const Lua& lua) -> int
        {
            lua.set_string(s_instance == nullptr ? "not-loaded" : s_instance->probe_report());
            return 1;
        }

      private:
        inline static BossDPSNativeCollector* s_instance{};
        ReflectedDamageLayout m_layout{};
        UFunction* m_damage_function{};
        UFunction* m_action_begin_function{};
        UFunction* m_effect_initialize_function{};
        UFunction* m_filter_bind_function{};
        UFunction* m_filter_attack_callback_function{};
        UFunction* m_damage_utility_function{};
        UClass* m_action_base_class{};
        UClass* m_skill_effect_base_class{};
        UClass* m_attack_filter_class{};
        std::string m_damage_function_path{};
        CallbackId m_hook_id{-1};
        CallbackId m_action_begin_pre_hook_id{-1};
        CallbackId m_action_begin_post_hook_id{-1};
        CallbackId m_effect_initialize_pre_hook_id{-1};
        CallbackId m_effect_initialize_post_hook_id{-1};
        CallbackId m_filter_bind_hook_id{-1};
        CallbackId m_filter_attack_callback_pre_hook_id{-1};
        CallbackId m_filter_attack_callback_post_hook_id{-1};
        CallbackId m_damage_utility_pre_hook_id{-1};
        CallbackId m_damage_utility_post_hook_id{-1};
        Hook::GlobalCallbackId m_script_pre_id{Hook::ERROR_ID};
        Hook::GlobalCallbackId m_script_post_id{Hook::ERROR_ID};
        std::atomic<bool> m_ready{};
        std::atomic<bool> m_faulted{};
        std::atomic<bool> m_exact_source_ready{};
        std::atomic<bool> m_action_source_ready{};
        std::atomic<bool> m_effect_initialize_ready{};
        std::atomic<bool> m_filter_bind_ready{};
        std::atomic<bool> m_filter_attack_callback_ready{};
        std::atomic<bool> m_damage_utility_ready{};
        std::atomic<bool> m_source_overflow{};
        std::atomic<std::uint64_t> m_capture_errors{};
        std::atomic<std::uint64_t> m_script_calls{};
        std::atomic<std::uint64_t> m_script_callbacks_seen{};
        std::atomic<std::uint64_t> m_action_begin_matches{};
        std::atomic<std::uint64_t> m_effect_initialize_matches{};
        std::atomic<std::uint64_t> m_attack_matches{};
        std::atomic<std::uint64_t> m_attack_without_waza{};
        std::atomic<std::uint64_t> m_attack_layout_misses{};
        std::atomic<std::uint64_t> m_attack_missing_defender{};
        std::atomic<std::uint64_t> m_attack_missing_source{};
        std::atomic<std::uint64_t> m_attack_source_conflicts{};
        std::atomic<std::uint64_t> m_attack_missing_waza{};
        std::atomic<std::uint64_t> m_attack_fingerprints_recorded{};
        std::atomic<std::uint64_t> m_attack_fingerprint_weak{};
        std::atomic<std::uint64_t> m_attack_fingerprint_missing_actor{};
        std::atomic<std::uint64_t> m_pending_attack_recorded{};
        std::atomic<std::uint64_t> m_pending_attack_single{};
        std::atomic<std::uint64_t> m_pending_attack_agreed{};
        std::atomic<std::uint64_t> m_pending_attack_ambiguous{};
        std::atomic<std::uint64_t> m_pending_attack_missing{};
        std::atomic<std::uint64_t> m_pending_attack_expired{};
        std::atomic<std::uint64_t> m_pending_attack_overflow{};
        std::atomic<std::uint64_t> m_pending_attack_missing_actor{};
        std::atomic<std::uint64_t> m_reverse_pair_recorded{};
        std::atomic<std::uint64_t> m_reverse_pair_promoted{};
        std::atomic<std::uint64_t> m_reverse_pair_ambiguous{};
        std::atomic<std::uint64_t> m_reverse_pair_expired{};
        std::atomic<std::uint64_t> m_reverse_pair_overflow{};
        std::atomic<std::uint64_t> m_reverse_pair_source_consumed{};
        std::atomic<std::uint64_t> m_probe_damage_callbacks{};
        std::atomic<std::uint64_t> m_probe_damage_functions{};
        std::atomic<std::uint64_t> m_probe_action_contexts{};
        std::atomic<std::uint64_t> m_probe_effect_contexts{};
        std::atomic<std::uint64_t> m_probe_other_contexts{};
        std::atomic<std::uint64_t> m_probe_waza_samples{};
        std::atomic<bool> m_probe_cache_overflow{};
        std::atomic<std::uint64_t> m_final_source_probe_claims{};
        std::atomic<std::uint64_t> m_final_source_probe_samples{};
        std::atomic<std::uint64_t> m_final_source_probe_dropped{};
        std::atomic<std::uint64_t> m_final_source_probe_object_fields{};
        std::atomic<std::uint64_t> m_final_source_probe_direct_ids{};
        std::atomic<std::uint64_t> m_final_source_probe_stack_frames{};
        std::atomic<std::uint64_t> m_final_source_probe_effect_frames{};
        std::atomic<std::uint64_t> m_final_source_probe_action_frames{};
        std::atomic<std::uint64_t> m_final_source_probe_empty_fields{};
        std::atomic<std::uint64_t> m_final_source_probe_field_truncated{};
        std::atomic<std::uint64_t> m_final_source_probe_payload_truncated{};
        std::atomic<std::uint64_t> m_final_source_schema_samples{};
        std::atomic<std::uint64_t> m_final_source_schema_truncated{};
        std::atomic<bool> m_final_source_schema_emitted{};
        std::atomic<std::uint64_t> m_filter_bind_matches{};
        std::atomic<std::uint64_t> m_filter_attack_callback_calls{};
        std::atomic<std::uint64_t> m_filter_attack_callback_layout_misses{};
        std::atomic<std::uint64_t> m_filter_attack_callback_missing_attacker{};
        std::atomic<std::uint64_t> m_filter_attack_callback_missing_defender{};
        std::atomic<std::uint64_t> m_filter_attack_callback_missing_waza{};
        std::atomic<std::uint64_t> m_filter_attack_callback_source_conflicts{};
        std::atomic<std::uint64_t> m_filter_attack_callback_nested_finals{};
        std::atomic<std::uint64_t> m_filter_attack_callback_nested_exact{};
        std::atomic<std::uint64_t> m_filter_attack_callback_nested_conflicts{};
        std::atomic<std::uint64_t> m_filter_attack_callback_nested_attacker_misses{};
        std::atomic<std::uint64_t> m_filter_attack_callback_nested_defender_misses{};
        std::atomic<std::uint64_t> m_filter_attack_callback_nested_incomplete{};
        std::atomic<std::uint64_t> m_filter_attack_callback_outside_scope_finals{};
        std::atomic<std::uint64_t> m_filter_attack_callback_scope_errors{};
        std::atomic<std::uint64_t> m_filter_attack_callback_errors{};
        std::atomic<std::uint64_t> m_filter_attack_callback_probe_claims{};
        std::atomic<std::uint64_t> m_filter_attack_callback_probe_samples{};
        std::atomic<std::uint64_t> m_filter_attack_callback_probe_dropped{};
        std::atomic<std::uint64_t> m_filter_attack_callback_probe_truncated{};
        std::atomic<std::uint64_t> m_damage_utility_calls{};
        std::atomic<std::uint64_t> m_damage_utility_layout_misses{};
        std::atomic<std::uint64_t> m_damage_utility_missing_filter{};
        std::atomic<std::uint64_t> m_damage_utility_missing_attacker{};
        std::atomic<std::uint64_t> m_damage_utility_missing_defender{};
        std::atomic<std::uint64_t> m_damage_utility_missing_waza{};
        std::atomic<std::uint64_t> m_damage_utility_source_conflicts{};
        std::atomic<std::uint64_t> m_damage_utility_nested_finals{};
        std::atomic<std::uint64_t> m_damage_utility_nested_exact{};
        std::atomic<std::uint64_t> m_damage_utility_nested_conflicts{};
        std::atomic<std::uint64_t> m_damage_utility_nested_attacker_misses{};
        std::atomic<std::uint64_t> m_damage_utility_nested_defender_misses{};
        std::atomic<std::uint64_t> m_damage_utility_nested_incomplete{};
        std::atomic<std::uint64_t> m_damage_utility_outside_scope_finals{};
        std::atomic<std::uint64_t> m_damage_utility_scope_errors{};
        std::atomic<std::uint64_t> m_damage_utility_errors{};
        std::atomic<std::uint64_t> m_damage_utility_probe_claims{};
        std::atomic<std::uint64_t> m_damage_utility_probe_samples{};
        std::atomic<std::uint64_t> m_damage_utility_probe_dropped{};
        std::atomic<std::uint64_t> m_damage_utility_probe_truncated{};
        std::atomic<std::uint64_t> m_exact_hits{};
        std::atomic<std::uint64_t> m_fingerprint_candidate_hits{};
        std::atomic<std::uint64_t> m_final_fingerprint_weak{};
        std::atomic<std::uint64_t> m_final_fingerprint_missing{};
        std::atomic<std::uint64_t> m_final_fingerprint_ambiguous{};
        std::atomic<std::uint64_t> m_unresolved_hits{};
        std::atomic<std::uint64_t> m_final_no_attack_scope{};
        std::atomic<std::uint64_t> m_final_pair_misses{};
        std::atomic<std::uint64_t> m_final_incomplete_scope{};
        std::atomic<std::uint64_t> m_source_errors{};
        std::atomic<bool> m_fingerprint_overflow{};
        std::mutex m_mutex;
        std::mutex m_source_mutex;
        std::mutex m_fingerprint_mutex;
        std::mutex m_attack_matcher_mutex;
        std::mutex m_final_damage_matcher_mutex;
        std::mutex m_probe_mutex;
        boss_dps::CollectorCore m_collector;
        pal_dps::NativeEventQueue m_event_queue{maximum_pending_events};
        pal_dps::PendingFingerprintMatcher m_pending_fingerprints{maximum_source_records};
        pal_dps::PendingAttackMatcher m_pending_attacks{maximum_source_records};
        pal_dps::PendingFinalDamageMatcher m_pending_final_damage{maximum_source_records};
        std::unordered_map<boss_dps::DamageKey, WeakObjects, boss_dps::DamageKeyHash>
            m_bucket_objects;
        std::deque<PendingRecord> m_drained_records;
        std::unordered_map<std::uintptr_t, FWeakObjectPtr> m_known_defenders;
        std::unordered_map<std::uintptr_t, TargetClassification> m_target_states;
        std::unordered_map<pal_dps::ObjectToken, pal_dps::ObjectToken, pal_dps::ObjectTokenHash>
            m_effect_filters;
        std::unordered_map<pal_dps::ObjectToken, pal_dps::ObjectToken, pal_dps::ObjectTokenHash>
            m_filter_effects;
        std::unordered_map<pal_dps::ObjectToken, EffectSourceRecord, pal_dps::ObjectTokenHash>
            m_effect_sources;
        std::unordered_set<pal_dps::ObjectToken, pal_dps::ObjectTokenHash>
            m_ambiguous_effect_filters;
        std::unordered_map<UFunction*, AttackFunctionLayout> m_attack_layout_cache;
        std::unordered_map<UFunction*, std::size_t> m_probe_samples_by_function;
        std::vector<std::string> m_probe_reports;
        std::vector<std::string> m_final_source_probe_reports;
        std::uint64_t m_next_cast_value{1};
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
