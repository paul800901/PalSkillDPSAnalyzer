#pragma once

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <Windows.h>
#include <cstdint>

namespace pal_dps
{
    struct NativeAttackFrameSpec
    {
        std::uintptr_t damage_begin{}, damage_end{}, filter_return{}, blueprint_return{};
    };

    struct NativeAttackFrame
    {
        std::uintptr_t filter{}, defender{}, damage_pc{}, caller_pc{};
        std::uintptr_t script_frame{}, attacker{};
        unsigned depth{};
        const char* reason{"no_damage_frame"};
    };

    // Work on a COPY of the current context. No detour, stack scan, handler
    // execution or modification of the suspended caller's stack/registers.
    inline auto unwind_caller(CONTEXT& context, ULONG_PTR low, ULONG_PTR high) -> bool
    {
        if (context.Rsp < low || context.Rsp > high - sizeof(DWORD64)) return false;
        const auto previous_sp = context.Rsp;
        DWORD64 image_base{};
        if (auto* entry = RtlLookupFunctionEntry(context.Rip, &image_base, nullptr))
        {
            void* handler_data{};
            DWORD64 establisher{};
            RtlVirtualUnwind(UNW_FLAG_NHANDLER, image_base, context.Rip, entry,
                             &context, &handler_data, &establisher, nullptr);
        }
        else
        {
            // A loaded image's x64 leaf function has no unwind entry. An
            // unregistered JIT/trampoline is NOT assumed to be a leaf.
            MEMORY_BASIC_INFORMATION page{};
            if (!VirtualQuery(reinterpret_cast<const void*>(context.Rip), &page, sizeof(page))
                || page.State != MEM_COMMIT || page.Type != MEM_IMAGE
                || !(page.Protect & 0xF0) || (page.Protect & PAGE_GUARD)) return false;
            context.Rip = *reinterpret_cast<const DWORD64*>(context.Rsp);
            context.Rsp += sizeof(DWORD64);
        }
        if (context.Rsp <= previous_sp || context.Rsp > high) return false;
        if (!context.Rip) return true;
        MEMORY_BASIC_INFORMATION caller{};
        return VirtualQuery(reinterpret_cast<const void*>(context.Rip), &caller, sizeof(caller))
            && caller.State == MEM_COMMIT && (caller.Protect & 0xF0) && !(caller.Protect & PAGE_GUARD);
    }

    __declspec(noinline) inline auto capture_native_attack_frame(const NativeAttackFrameSpec& spec)
        -> NativeAttackFrame
    {
        NativeAttackFrame result;
        CONTEXT context{};
        ULONG_PTR low{}, high{};
        GetCurrentThreadStackLimits(&low, &high);
        RtlCaptureContext(&context);
        __try
        {
            for (unsigned depth = 0; depth < 192 && context.Rip; ++depth)
            {
                result.depth = depth;
                if (context.Rip >= spec.damage_begin && context.Rip < spec.damage_end)
                {
                    result.damage_pc = context.Rip;
                    // The NEAREST damage utility is a barrier. Its immediate
                    // caller must be the verified filter call site; an unrelated
                    // nested hit cannot borrow an older filter on the stack.
                    if (!unwind_caller(context, low, high))
                    { result.reason = "unwind_unavailable"; return result; }
                    result.caller_pc = context.Rip;
                    if (spec.blueprint_return && context.Rip == spec.blueprint_return)
                    {
                        // Verified execProcessDamage thunk: RBX retains FFrame*,
                        // and the actual attacker/defender arguments are its
                        // stack locals at +38/+30. Never search older frames.
                        if (context.Rsp > high - 0x40)
                        { result.reason = "unwind_unavailable"; return result; }
                        result.script_frame = context.Rbx;
                        result.attacker = *reinterpret_cast<const std::uintptr_t*>(context.Rsp + 0x38);
                        result.defender = *reinterpret_cast<const std::uintptr_t*>(context.Rsp + 0x30);
                        result.reason = "blueprint_frame";
                        return result;
                    }
                    if (context.Rip != spec.filter_return)
                    { result.reason = "other_damage_caller"; return result; }
                    result.filter = context.Rsi;
                    result.defender = context.R12;
                    result.reason = "filter_frame";
                    return result;
                }
                if (!unwind_caller(context, low, high))
                { result.reason = "unwind_unavailable"; return result; }
            }
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            result.reason = "unwind_unavailable";
        }
        return result;
    }
}
