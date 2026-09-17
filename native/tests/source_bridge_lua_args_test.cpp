#include <LuaMadeSimple/LuaMadeSimple.hpp>
#include <lua.hpp>

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string_view>

namespace
{
    using RC::LuaMadeSimple::Lua;

    constexpr std::uintptr_t attacker_value = 1'311'768'468'963'794'320ULL;
    constexpr std::uintptr_t defender_value = 1'147'797'409'030'816'545ULL;

    struct Observation
    {
        std::uintptr_t attacker{};
        std::uintptr_t defender{};
        bool available{};
        std::uint32_t calls{};
    };

    Observation old_route{};
    Observation new_route{};

    [[noreturn]] auto fail(const std::string_view message) -> void
    {
        std::cerr << "FAILED: " << message << '\n';
        std::exit(1);
    }

    auto expect(const bool condition, const std::string_view message) -> void
    {
        if (!condition) fail(message);
    }

    auto old_argument_read(const Lua& lua) -> int
    {
        if (!lua.is_integer(1) || !lua.is_integer(2))
        {
            return 0;
        }

        // Reproduce the pre-fix order using real LuaMadeSimple/LuaRaw.
        old_route.attacker = static_cast<std::uintptr_t>(lua.get_integer(1));
        old_route.defender = static_cast<std::uintptr_t>(lua.get_integer(2));
        old_route.available = true;
        ++old_route.calls;
        return 0;
    }

    auto production_argument_read(const Lua& lua) -> int
    {
        // The build extracts this block unchanged from ScriptSourceBridge.cpp,
        // so the regression exercises the production guard and read order.
#include "source_bridge_arguments.inc"
        new_route.attacker = attacker;
        new_route.defender = defender;
        new_route.available = true;
        ++new_route.calls;
        lua.set_string("arguments-read");
        return 1;
    }
}

auto main() -> int
{
    Lua& lua = RC::LuaMadeSimple::new_state();
    luaL_openlibs(lua.get_lua_state());
    lua.register_function("source_bridge_old_fixture", &old_argument_read);
    lua.register_function("source_bridge_production_fixture", &production_argument_read);

    lua.execute_string(R"lua(
        source_bridge_old_fixture(1311768468963794320, 1147797409030816545)
        assert(source_bridge_production_fixture(1311768468963794320, 1147797409030816545) == "arguments-read")
        assert(source_bridge_production_fixture(nil, 1147797409030816545) == "unavailable")
        assert(source_bridge_production_fixture(1311768468963794320, nil) == "unavailable")
        assert(source_bridge_production_fixture(1311768468963794320) == "unavailable")
    )lua");

    expect(old_route.calls == 1, "old fixture did not receive the valid pair");
    expect(old_route.attacker == attacker_value, "old fixture changed attacker");
    expect(old_route.defender == 0, "old (1,2) extraction did not read defender as zero");

    expect(new_route.calls == 1, "production fixture accepted an invalid pair");
    expect(new_route.available, "production fixture did not keep a valid pair");
    expect(new_route.attacker == attacker_value, "production extraction changed attacker");
    expect(new_route.defender == defender_value, "production (1,1) extraction lost defender");

    lua_close(lua.get_lua_state());
    std::cout << "source bridge Lua argument tests passed; old_defender=" << old_route.defender
              << " corrected_attacker=" << new_route.attacker
              << " corrected_defender=" << new_route.defender << '\n';
    return 0;
}
