cmake_minimum_required(VERSION 3.25)
project(BossDPSNativeCollector LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")

if(NOT DEFINED UE4SS_SOURCE_DIR)
    message(FATAL_ERROR "UE4SS_SOURCE_DIR must point to the commit locked by tools/native-toolchain.lock.json")
endif()
if(NOT DEFINED UE4SS_IMPORT_LIBRARY)
    message(FATAL_ERROR "UE4SS_IMPORT_LIBRARY must point to the generated UE4SS.lib")
endif()
if(NOT DEFINED FMT_SOURCE_DIR)
    message(FATAL_ERROR "FMT_SOURCE_DIR must point to fmt 11.2.0")
endif()
if(NOT DEFINED ZYDIS_SOURCE_DIR OR NOT DEFINED ZYCORE_SOURCE_DIR)
    message(FATAL_ERROR "ZYDIS_SOURCE_DIR and ZYCORE_SOURCE_DIR are required")
endif()
if(NOT DEFINED IMGUI_SOURCE_DIR OR NOT DEFINED IMGUI_TEXT_EDIT_SOURCE_DIR OR NOT DEFINED ICON_FONT_SOURCE_DIR)
    message(FATAL_ERROR "IMGUI_SOURCE_DIR, IMGUI_TEXT_EDIT_SOURCE_DIR, and ICON_FONT_SOURCE_DIR are required")
endif()

add_library(UE4SSRuntime SHARED IMPORTED GLOBAL)
set_target_properties(UE4SSRuntime PROPERTIES
    IMPORTED_IMPLIB "${UE4SS_IMPORT_LIBRARY}"
)

add_library(BossDPSNativeCollector SHARED
    src/BossDPSNativeCollector.cpp
)
target_include_directories(BossDPSNativeCollector PRIVATE
    "${UE4SS_SOURCE_DIR}/UE4SS/include"
    "${UE4SS_SOURCE_DIR}/UE4SS/generated_include"
    "${UE4SS_SOURCE_DIR}/deps/first/Unreal/include"
    "${UE4SS_SOURCE_DIR}/deps/first/Unreal/include/Unreal"
    "${UE4SS_SOURCE_DIR}/deps/first/Unreal/include/Unreal/Core"
    "${UE4SS_SOURCE_DIR}/deps/first/Unreal/generated_include"
    "${UE4SS_SOURCE_DIR}/deps/first/LuaMadeSimple/include"
    "${UE4SS_SOURCE_DIR}/deps/first/LuaRaw/include"
    "${UE4SS_SOURCE_DIR}/deps/first/String/include"
    "${UE4SS_SOURCE_DIR}/deps/first/File/include"
    "${UE4SS_SOURCE_DIR}/deps/first/Function/include"
    "${UE4SS_SOURCE_DIR}/deps/first/Helpers/include"
    "${UE4SS_SOURCE_DIR}/deps/first/Input/include"
    "${UE4SS_SOURCE_DIR}/deps/first/IniParser/include"
    "${UE4SS_SOURCE_DIR}/deps/first/JSON/include"
    "${UE4SS_SOURCE_DIR}/deps/first/MProgram/include"
    "${UE4SS_SOURCE_DIR}/deps/first/ParserBase/include"
    "${UE4SS_SOURCE_DIR}/deps/first/Profiler/include"
    "${UE4SS_SOURCE_DIR}/deps/first/ScopedTimer/include"
    "${UE4SS_SOURCE_DIR}/deps/first/SinglePassSigScanner/include"
    "${UE4SS_SOURCE_DIR}/deps/first/Constructs/include"
    "${UE4SS_SOURCE_DIR}/deps/first/DynamicOutput/include"
    "${UE4SS_SOURCE_DIR}/deps/first/ASMHelper/include"
    "${FMT_SOURCE_DIR}/include"
    "${ZYDIS_SOURCE_DIR}/include"
    "${ZYCORE_SOURCE_DIR}/include"
    "${IMGUI_SOURCE_DIR}"
    "${IMGUI_TEXT_EDIT_SOURCE_DIR}"
    "${ICON_FONT_SOURCE_DIR}"
    include
)
target_compile_definitions(BossDPSNativeCollector PRIVATE
    UE_BUILD_SHIPPING=1
    UE_GAME=1
    PLATFORM_WINDOWS=1
    PLATFORM_MICROSOFT=1
    OVERRIDE_PLATFORM_HEADER_NAME=Windows
    UBT_COMPILED_PLATFORM=Win64
    _WIN32_WINNT=0x0A00
    WINVER=0x0A00
    FMT_HEADER_ONLY=1
    _UNICODE
    UNICODE
    WIN32_LEAN_AND_MEAN
)
target_compile_options(BossDPSNativeCollector PRIVATE /W4 /EHsc /utf-8)
target_link_libraries(BossDPSNativeCollector PRIVATE UE4SSRuntime)
set_target_properties(BossDPSNativeCollector PROPERTIES
    OUTPUT_NAME "main"
)

add_executable(collector_stress tests/collector_stress.cpp)
target_include_directories(collector_stress PRIVATE include)
target_compile_options(collector_stress PRIVATE /W4 /EHsc)

add_executable(attribution_event_core_test tests/attribution_event_core_test.cpp)
target_include_directories(attribution_event_core_test PRIVATE include)
target_compile_options(attribution_event_core_test PRIVATE /W4 /WX /EHsc /utf-8)

add_executable(native_event_queue_test tests/native_event_queue_test.cpp)
target_include_directories(native_event_queue_test PRIVATE include)
target_compile_options(native_event_queue_test PRIVATE /W4 /WX /EHsc /utf-8)

enable_testing()
add_test(NAME collector_stress COMMAND collector_stress)
add_test(NAME attribution_event_core_test COMMAND attribution_event_core_test)
add_test(NAME native_event_queue_test COMMAND native_event_queue_test)
