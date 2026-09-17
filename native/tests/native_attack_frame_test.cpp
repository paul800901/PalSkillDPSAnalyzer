#include "NativeAttackFrame.hpp"
#include <cassert>
#include <iostream>
#include <string_view>

extern "C" void FixtureFilter(std::uintptr_t, std::uintptr_t, void (*)());
extern "C" void FixtureOtherCaller(void (*)());
extern "C" void FixtureBlueprint(std::uintptr_t, std::uintptr_t, std::uintptr_t, void (*)());
extern "C" char FixtureBlueprintReturn;
extern "C" char FixtureFilterReturn, FixtureDamage, FixtureDamageEnd;

static const pal_dps::NativeAttackFrameSpec spec{
    reinterpret_cast<std::uintptr_t>(&FixtureDamage),
    reinterpret_cast<std::uintptr_t>(&FixtureDamageEnd),
    reinterpret_cast<std::uintptr_t>(&FixtureFilterReturn),
    reinterpret_cast<std::uintptr_t>(&FixtureBlueprintReturn)};
static pal_dps::NativeAttackFrame observed;

__declspec(noinline) static void capture()
{
    observed = pal_dps::capture_native_attack_frame(spec);
}

__declspec(noinline) static void nested_filter()
{
    FixtureFilter(300, 8, &capture);
    assert(observed.filter == 300 && observed.defender == 8);
    capture();
    assert(observed.filter == 100 && observed.defender == 8);
}

__declspec(noinline) static void unrelated_nested_damage()
{
    FixtureOtherCaller(&capture);
    assert(!observed.filter);
    assert(std::string_view(observed.reason) == "other_damage_caller");
    capture();
    assert(observed.filter == 100 && observed.defender == 8);
}

__declspec(noinline) static void repeated()
{
    for (int i = 0; i < 3; ++i)
    {
        capture();
        assert(observed.filter == 100 && observed.defender == 8);
    }
}

__declspec(noinline) static void nested_blueprint()
{
    FixtureOtherCaller(&capture);
    assert(!observed.script_frame && !observed.filter);
    assert(std::string_view(observed.reason) == "other_damage_caller");
    FixtureFilter(300, 8, &capture);
    assert(observed.filter == 300 && !observed.script_frame);
    capture();
    assert(observed.script_frame == 0x1234 && observed.attacker == 100 && observed.defender == 8);
}

int main()
{
    FixtureFilter(100, 8, &capture);
    assert(std::string_view(observed.reason) == "filter_frame");
    assert(observed.filter == 100 && observed.defender == 8);
    assert(observed.caller_pc == spec.filter_return);
    assert(observed.damage_pc >= spec.damage_begin && observed.damage_pc < spec.damage_end);
    assert(observed.depth > 0 && observed.depth < 192);
    FixtureFilter(200, 9, &capture);
    assert(observed.filter == 200 && observed.defender == 9);
    FixtureFilter(100, 8, &nested_filter);
    FixtureFilter(100, 8, &unrelated_nested_damage);
    FixtureFilter(100, 8, &repeated);
    FixtureBlueprint(0x1234, 100, 8, &capture);
    assert(std::string_view(observed.reason) == "blueprint_frame");
    assert(observed.script_frame == 0x1234 && observed.attacker == 100 && observed.defender == 8);
    assert(!observed.filter && observed.caller_pc == spec.blueprint_return);
    FixtureBlueprint(0x1234, 100, 8, &nested_blueprint);
    capture(); // No source is retained after the real caller returns.
    assert(!observed.filter && !observed.script_frame);
    FixtureOtherCaller(&capture);
    assert(!observed.filter && std::string_view(observed.reason) == "other_damage_caller");
    std::cout << "native_attack_frame_test: real x64 unwind, restored registers, nested barriers, lifetime passed\n";
}
