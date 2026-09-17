// Read the actual native AttackFilter frame during the existing final-damage
// callback. OnAttackDelegate is a later notification, not the damage's parent.
#include "NativeAttackFrame.hpp"
#include <LuaMadeSimple/LuaMadeSimple.hpp>
#include <Mod/CppUserModBase.hpp>
#include <Unreal/CoreUObject/UObject/Class.hpp>
#include <Unreal/CoreUObject/UObject/UnrealType.hpp>
#include <Unreal/Property/FEnumProperty.hpp>
#include <Unreal/FWeakObjectPtr.hpp>
#include <Unreal/FFrame.hpp>
#include <Unreal/UObjectGlobals.hpp>
#include <DynamicOutput/DynamicOutput.hpp>
#include <Windows.h>
#include <bcrypt.h>
#include <array>
#include <atomic>
#include <cctype>
#include <cstdio>
#include <string>
#include <vector>

#pragma comment(lib, "bcrypt.lib")

namespace
{
    using namespace RC::Unreal;
    using RC::LuaMadeSimple::Lua;

    // The installed runtime differed from the project's old ABI. Check the
    // loaded DLL before constructing any UE4SS C++ object on another machine.
    auto module_matches(HMODULE module, const std::array<unsigned char, 32>& expected) -> bool
    {
        wchar_t path[32768]{};
        if (!module || !GetModuleFileNameW(module, path, 32768)) return false;
        const auto file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                      nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE) return false;
        BCRYPT_ALG_HANDLE algorithm{};
        BCRYPT_HASH_HANDLE hash{};
        std::array<unsigned char, 32> digest{};
        auto ok = BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) >= 0;
        if (ok) ok = BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0) >= 0;
        std::array<unsigned char, 65536> buffer{};
        while (ok)
        {
            DWORD size{};
            if (!ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()), &size, nullptr))
            { ok = false; break; }
            if (!size) break;
            ok = BCryptHashData(hash, buffer.data(), size, 0) >= 0;
        }
        if (ok) ok = BCryptFinishHash(hash, digest.data(), static_cast<ULONG>(digest.size()), 0) >= 0;
        if (hash) BCryptDestroyHash(hash);
        if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
        CloseHandle(file);
        return ok && digest == expected;
    }

    auto runtime_matches() -> bool
    {
        return module_matches(GetModuleHandleW(L"UE4SS.dll"), {
            0x21,0xB6,0x91,0xA6,0x9A,0x20,0xC0,0x80,0x1F,0x46,0x53,0x69,0xD4,0xFC,0xBC,0xA7,
            0xD7,0x44,0x47,0x64,0x02,0x2F,0xAC,0x2A,0x7E,0x8E,0xDC,0x77,0x09,0xEF,0x92,0xB8});
    }

    auto key(const void* value) -> std::uintptr_t
    {
        return reinterpret_cast<std::uintptr_t>(value);
    }

    auto lower(std::string text) -> std::string
    {
        for (auto& c : text) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        return text;
    }

    auto property(UStruct* owner, std::string_view wanted) -> FProperty*
    {
        if (!owner) return nullptr;
        for (TFieldIterator<FProperty> it{owner, EFieldIterationFlags::IncludeSuper}; it; ++it)
            if (lower(RC::to_string((*it)->GetName())) == wanted) return *it;
        return nullptr;
    }

    auto object_field(FProperty* field, void* container) -> UObject*
    {
        if (!field || !container) return nullptr;
        auto* value = field->ContainerPtrToValuePtr<void>(container);
        if (auto* object = CastField<FObjectPropertyBase>(field))
            return object->GetObjectPropertyValue(value);
        if (CastField<FWeakObjectProperty>(field)) return static_cast<FWeakObjectPtr*>(value)->Get();
        return nullptr;
    }

    auto member(UObject* object, std::string_view name) -> UObject*
    {
        return object ? object_field(property(object->GetClassPrivate(), name), object) : nullptr;
    }

    auto waza(UObject* filter) -> std::int64_t
    {
        auto* field = filter ? property(filter->GetClassPrivate(), "waza") : nullptr;
        if (!field) return 0;
        auto* address = field->ContainerPtrToValuePtr<void>(filter);
        if (auto* enumeration = CastField<FEnumProperty>(field))
        {
            auto* underlying = enumeration->GetUnderlyingProperty();
            return underlying ? static_cast<std::int64_t>(underlying->GetUnsignedIntPropertyValue(address)) : 0;
        }
        auto* number = CastField<FNumericProperty>(field);
        return number && number->IsInteger() ? number->GetSignedIntPropertyValue(address) : 0;
    }

    struct FilterIdentity
    {
        std::int64_t skill{};
        std::uintptr_t effect{};
        const char* reason{"filter_read_failed"};
    };

    auto resolve_filter(UObject* filter, UClass* filter_class, UClass* effect_class,
                        std::uintptr_t attacker) -> FilterIdentity
    {
        // The recovered register is untrusted until reflection confirms it.
        // A failed read must leave the hit unresolved, not crash the game.
        __try
        {
            if (!filter || !filter->IsA(filter_class)) return {0, 0, "filter_class_mismatch"};
            if (key(member(filter, "attacker")) != attacker) return {0, 0, "attacker_mismatch"};
            const auto skill = waza(filter);
            if (skill <= 0) return {0, 0, "waza_missing"};
            auto* outer = filter->GetOuterPrivate();
            return {skill, outer && effect_class && outer->IsA(effect_class) ? key(outer) : 0, "matched"};
        }
        __except (GetExceptionCode() == EXCEPTION_ACCESS_VIOLATION
                    ? EXCEPTION_EXECUTE_HANDLER : EXCEPTION_CONTINUE_SEARCH)
        {
            return {};
        }
    }

    auto meteor_rock_class(UObject* object) -> UClass*
    {
        for (auto* type = object->GetClassPrivate(); type; type = type->GetSuperClass())
            if (type->GetFName() == FName(STR("BP_SkillEffect_Commet_Rock_C"))) return type;
        return nullptr;
    }

    struct MeteorSpawn
    {
        UObject* ring{};
        UObject* attacker{};
        std::int64_t skill{};
        const char* reason{"meteor_spawn_read_failed"};
    };

    auto meteor_spawn_result(UObject* rock, UClass* effect_class, UClass* filter_class) -> MeteorSpawn
    {
        __try
        {
            if (!rock || !effect_class || !rock->IsA(effect_class)) return {nullptr, nullptr, 0, "meteor_not_effect"};
            auto* rock_class = meteor_rock_class(rock);
            if (!rock_class) return {nullptr, nullptr, 0, "meteor_not_rock"};
            auto* frame_field = property(rock_class, "ubergraphframe");
            auto* function = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr,
                STR("/Game/Pal/Blueprint/Skill/Commet/BP_SkillEffect_Commet_Rock.BP_SkillEffect_Commet_Rock_C:ExecuteUbergraph_BP_SkillEffect_Commet_Rock"));
            auto* result_field = property(function, "callfunc_finishspawningactor_returnvalue");
            if (!frame_field || !CastField<FStructProperty>(frame_field) || !result_field)
                return {nullptr, nullptr, 0, "meteor_spawn_field_missing"};
            // FPointerToUberGraphFrame::RawPointer is the first member in the
            // checked UE 5.1 source; local offsets are reflected, never fixed.
            auto* locals = *frame_field->ContainerPtrToValuePtr<void*>(rock);
            if (!locals) return {nullptr, nullptr, 0, "meteor_locals_missing"};
            auto* ring = object_field(result_field, locals);
            if (!ring || !ring->IsA(effect_class)
                || ring->GetClassPrivate()->GetFName() != FName(STR("BP_SkillEffect_Commet_Ring_C")))
                return {nullptr, nullptr, 0, "meteor_spawn_result_missing"};
            auto* filter = member(rock, "attackfilter");
            if (!filter || !filter->IsA(filter_class) || filter->GetOuterPrivate() != rock)
                return {nullptr, nullptr, 0, "meteor_parent_filter_missing"};
            auto* attacker = member(filter, "attacker");
            const auto skill = waza(filter);
            return attacker && skill > 0 ? MeteorSpawn{ring, attacker, skill, "meteor_spawn_verified"}
                : MeteorSpawn{nullptr, nullptr, 0, "meteor_parent_identity_missing"};
        }
        __except (GetExceptionCode() == EXCEPTION_ACCESS_VIOLATION
                    ? EXCEPTION_EXECUTE_HANDLER : EXCEPTION_CONTINUE_SEARCH)
        { return {}; }
    }

    auto blueprint_effect(const pal_dps::NativeAttackFrame& frame, UClass* effect_class,
                          std::uintptr_t attacker, std::uintptr_t defender,
                          const char*& reason) -> UObject*
    {
        __try
        {
            reason = "blueprint_actor_pair_mismatch";
            if (!frame.script_frame || !attacker || !defender
                || frame.attacker != attacker || frame.defender != defender) return nullptr;
            auto* effect = reinterpret_cast<FFrame*>(frame.script_frame)->Object();
            reason = "blueprint_not_skill_effect";
            if (!effect || !effect_class || !effect->IsA(effect_class)) return nullptr;
            reason = "blueprint_effect_verified";
            return effect;
        }
        __except (GetExceptionCode() == EXCEPTION_ACCESS_VIOLATION
                    ? EXCEPTION_EXECUTE_HANDLER : EXCEPTION_CONTINUE_SEARCH)
        { reason = "blueprint_reflection_failed"; return nullptr; }
    }

    // CommetRain and ThreeCommet inherit the base rock's Blueprint damage
    // implementation. Its child DamageInfo says Commet, but the executing
    // rock's own AttackFilter carries the real parent Waza. Read only that
    // synchronous object; no previous action, time window or damage estimate.
    auto blueprint_meteor_filter(const pal_dps::NativeAttackFrame& frame,
                                  UClass* effect_class, std::uintptr_t attacker,
                                  std::uintptr_t defender) -> UObject*
    {
        __try
        {
            if (!frame.script_frame || !attacker || !defender
                || frame.attacker != attacker || frame.defender != defender) return nullptr;
            auto* effect = reinterpret_cast<FFrame*>(frame.script_frame)->Object();
            if (!effect || !effect_class || !effect->IsA(effect_class)) return nullptr;
            bool meteor = false;
            for (auto* type = effect->GetClassPrivate(); type; type = type->GetSuperClass())
                if (type->GetFName() == FName(STR("BP_SkillEffect_Commet_Rock_C")))
                { meteor = true; break; }
            if (!meteor) return nullptr;
            auto* filter = member(effect, "attackfilter");
            return filter && filter->GetOuterPrivate() == effect ? filter : nullptr;
        }
        __except (GetExceptionCode() == EXCEPTION_ACCESS_VIOLATION
                    ? EXCEPTION_EXECUTE_HANDLER : EXCEPTION_CONTINUE_SEARCH)
        { return nullptr; }
    }

    class ScriptSourceBridge final : public RC::CppUserModBase
    {
        UClass* effect_class{};
        UClass* filter_class{};
        pal_dps::NativeAttackFrameSpec frame_spec{};
        std::uintptr_t game_base{};
        std::atomic<bool> ready{};
        std::atomic<std::uint64_t> reads{}, matched{}, rejected{}, errors{};
        std::uint64_t blueprint_reads{};
        bool meteor_spawn_ready{};
        std::uint64_t spawn_reads{}, spawn_links{}, spawn_matches{};
        struct MeteorChild
        {
            FWeakObjectPtr ring, attacker;
            std::int64_t skill{};
        };
        std::vector<MeteorChild> meteor_children;
        inline static ScriptSourceBridge* instance{};

        static auto remember_meteor(const Lua& lua) -> int
        {
            if (!instance || !instance->ready || !instance->meteor_spawn_ready || !lua.is_integer(1)) return 0;
            auto* rock = reinterpret_cast<UObject*>(static_cast<std::uintptr_t>(lua.get_integer(1)));
            const auto spawn = meteor_spawn_result(rock, instance->effect_class, instance->filter_class);
            const auto count = ++instance->spawn_reads;
            if (spawn.ring) ++instance->spawn_links;
            if (count <= 3 || count % 256 == 0 || (spawn.ring && instance->spawn_links <= 3))
                RC::Output::send<RC::LogLevel::Normal>(
                    STR("[PalDpsSourceBridge] meteor-spawn reads={} links={} reason={} rock={:X} ring={:X} attacker={:X} waza={}\n"),
                    count, instance->spawn_links, RC::to_generic_string(spawn.reason),
                    key(rock), key(spawn.ring), key(spawn.attacker), spawn.skill);
            if (!spawn.ring) return 0;
            auto& children = instance->meteor_children;
            std::erase_if(children, [](const MeteorChild& child) {
                return !child.ring.Get() || !child.attacker.Get();
            });
            for (auto& child : children)
                if (child.ring.Get() == spawn.ring)
                {
                    // A conflicting link must not be silently overwritten.
                    if (child.attacker.Get() != spawn.attacker || child.skill != spawn.skill) child.skill = 0;
                    return 0;
                }
            children.push_back({FWeakObjectPtr(spawn.ring), FWeakObjectPtr(spawn.attacker), spawn.skill});
            if (children.size() > 256) children.erase(children.begin());
            return 0;
        }

        static auto read(const Lua& lua) -> int
        {
            if (!instance || !instance->ready)
            {
                lua.set_string("unavailable");
                return 1;
            }
            if (!lua.is_integer(1) || !lua.is_integer(2))
            {
                lua.set_string("unavailable");
                return 1;
            }
            // get_integer removes the argument. After reading attacker, the
            // defender moves to index 1; index 2 would read nil as zero.
            const auto attacker = static_cast<std::uintptr_t>(lua.get_integer(1));
            const auto defender = static_cast<std::uintptr_t>(lua.get_integer(1));
            const auto count = ++instance->reads;
            const auto frame = pal_dps::capture_native_attack_frame(instance->frame_spec);
            auto* filter = reinterpret_cast<UObject*>(frame.filter);
            const bool blueprint = std::string_view(frame.reason) == "blueprint_frame";
            std::int64_t skill{};
            std::uintptr_t effect{};
            std::string blueprint_class;
            const char* source_kind = blueprint ? "native_blueprint_effect_frame" : "native_attack_filter_frame";
            const char* status = "no_scope";
            const char* validation = frame.reason;
            try
            {
                if (blueprint)
                {
                    status = "rejected_scope";
                    ++instance->blueprint_reads;
                    auto* object = blueprint_effect(frame, instance->effect_class, attacker, defender, validation);
                    if (object) blueprint_class = RC::to_string(object->GetClassPrivate()->GetName());
                    if (object && object->GetClassPrivate()->GetFName() == FName(STR("BP_SkillEffect_Commet_Ring_C")))
                    {
                        validation = "meteor_ring_spawn_link_missing";
                        for (const auto& child : instance->meteor_children)
                            if (child.ring.Get() == object && key(child.attacker.Get()) == attacker && child.skill > 0)
                            {
                                skill = child.skill;
                                effect = key(object);
                                source_kind = "native_spawned_meteor_frame";
                                status = "matched";
                                validation = "meteor_ring_spawn_link";
                                break;
                            }
                    }
                    else if (object)
                    {
                        filter = blueprint_meteor_filter(frame, instance->effect_class, attacker, defender);
                        validation = "blueprint_meteor_identity_missing";
                    }
                }
                if (filter)
                {
                    status = "rejected_scope";
                    validation = !attacker || !defender ? "invalid_actor_pair" : "defender_mismatch";
                    if (attacker && defender && frame.defender == defender)
                    {
                        const auto identity = resolve_filter(filter, instance->filter_class,
                                                             instance->effect_class, attacker);
                        skill = identity.skill;
                        validation = identity.reason;
                        if (skill > 0)
                        {
                            status = "matched";
                            effect = identity.effect;
                        }
                    }
                }
                else if (std::string_view(frame.reason) == "unwind_unavailable") status = "unavailable";
                else if (std::string_view(frame.reason) == "other_damage_caller") status = "rejected_scope";
            }
            catch (...) { ++instance->errors; status = "unavailable"; validation = "reflection_exception"; }
            const bool found = std::string_view(status) == "matched";
            const bool spawned_match = found && std::string_view(source_kind) == "native_spawned_meteor_frame";
            if (spawned_match) ++instance->spawn_matches;
            if (found) ++instance->matched;
            else if (std::string_view(status) == "rejected_scope") ++instance->rejected;
            lua.set_string(status);
            if (found)
            {
                lua.set_integer(skill);
                lua.set_integer(static_cast<std::int64_t>(effect));
                lua.set_integer(static_cast<std::int64_t>(key(filter)));
                lua.set_integer(static_cast<std::int64_t>(count));
                lua.set_string(source_kind);
            }
            // Bounded live evidence, independent of the Lua trace budget.
            if (count <= 3 || count % 256 == 0 || (found && instance->matched <= 3)
                || (blueprint && instance->blueprint_reads <= 3)
                || (spawned_match && instance->spawn_matches <= 3))
            {
                RC::Output::send<RC::LogLevel::Normal>(
                    STR("[PalDpsSourceBridge] reads={} matched={} rejected={} errors={} status={} reason={} validation={} depth={} damage_rva={:X} caller_rva={:X} attacker={:X} defender={:X} frame_defender={:X} filter={:X} waza={} effect_class={} source={}\n"),
                    count, instance->matched.load(), instance->rejected.load(), instance->errors.load(),
                    RC::to_generic_string(status), RC::to_generic_string(frame.reason),
                    RC::to_generic_string(validation), frame.depth,
                    frame.damage_pc ? frame.damage_pc - instance->game_base : 0,
                    frame.caller_pc ? frame.caller_pc - instance->game_base : 0,
                    attacker, defender, frame.defender, key(filter), skill,
                    RC::to_generic_string(blueprint_class), RC::to_generic_string(source_kind));
            }
            return found ? 6 : 1;
        }

    public:
        ScriptSourceBridge()
        {
            ModName = STR("PalDpsSourceBridge");
            ModVersion = STR("0.2.4-meteor-ring-spawn-link");
            ModDescription = STR("Read-only native attack frame source bridge");
            ModAuthors = STR("AsahiChan-Game");
            instance = this;
        }

        ~ScriptSourceBridge() override
        {
            ready = false;
            if (instance == this) instance = nullptr;
        }

        auto on_unreal_init() -> void override
        {
            effect_class = UObjectGlobals::StaticFindObject<UClass*>(nullptr, nullptr, STR("/Script/Pal.PalSkillEffectBase"));
            filter_class = UObjectGlobals::StaticFindObject<UClass*>(nullptr, nullptr, STR("/Script/Pal.PalAttackFilter"));
            const auto game = GetModuleHandleW(nullptr);
            // Steam build 25246127: the executable hash changed, but inspection
            // confirms the same filter call, source registers and damage unwind.
            const bool current_game_matches = module_matches(game, {
                0xE5,0x90,0xB5,0xE7,0xBF,0xAA,0x3F,0xEA,0x40,0xFA,0xB1,0xA0,0x2C,0xC7,0x2C,0x8F,
                0xC5,0xFD,0x6F,0x86,0x31,0xEF,0x23,0x08,0xE9,0x5A,0xC5,0x6C,0x25,0x19,0x58,0x37});
            const bool game_matches = current_game_matches || module_matches(game, {
                0x44,0xB6,0x29,0x5E,0x70,0xAA,0x37,0xB8,0x3D,0x1C,0x42,0xCE,0x1D,0xCF,0x86,0x5A,
                0x7F,0xFA,0xDC,0xD3,0x00,0x29,0x8B,0x0E,0x49,0xA0,0x2B,0xAD,0x8E,0xB8,0x34,0x43});
            game_base = key(game);
            // Verified in this exact executable, not SDK offsets or a skill
            // list. The filter calls ProcessDamage... BEFORE OnAttackDelegate.
            frame_spec = {game_base + 0x33112B0, game_base + 0x33113F4,
                          game_base + 0x2D8B4EB, current_game_matches ? game_base + 0x2B9544A : 0};
            ready = filter_class && game_matches;
            meteor_spawn_ready = ready && effect_class && current_game_matches;
            RC::Output::send<RC::LogLevel::Normal>(
                STR("[PalDpsSourceBridge] native attack frame ready={} game_build_match={}; read-only unwind and exact meteor spawn links; no delayed hit matching\n"),
                ready.load(), game_matches);
        }

        auto on_lua_start(RC::StringViewType mod_name, Lua& lua, Lua&, Lua&, Lua*) -> void override
        {
            if (mod_name == STR("PalSkillDPSAnalyzerSP"))
            {
                lua.register_function("PalDpsReadSynchronousSource", &read);
                if (meteor_spawn_ready) lua.register_function("PalDpsRememberMeteorChild", &remember_meteor);
            }
        }
    };
}

extern "C" __declspec(dllexport) RC::CppUserModBase* start_mod()
{
    if (!runtime_matches())
    {
        std::fprintf(stderr, "[PalDpsSourceBridge] unsupported UE4SS ABI; bridge not loaded\n");
        return nullptr;
    }
    return new ScriptSourceBridge;
}

extern "C" __declspec(dllexport) void uninstall_mod(RC::CppUserModBase* mod)
{
    delete mod;
}
