cmake_minimum_required(VERSION 3.16)
project(SuperMetroidSNESRecomp C)

# Cross-platform (macOS/Linux/MinGW) build for SuperMetroidSNESRecomp.
#
# Mirrors the shared framework source list (snesrecomp/runner/runner.cmake)
# plus the Super Metroid-specific runtime in src/. Prerequisites:
#   - a snesrecomp checkout at ./snesrecomp (junction/symlink to the sibling repo)
#   - generated C in src/gen/ and recomp/funcs.h:
#       ./tools/regen.sh --strict-idempotent
#   - SDL2 + OpenGL

set(CMAKE_C_STANDARD 11)

# CACHE PATH, so -DSNESRECOMP_ROOT=<engine checkout> works -- the framework
# README documents that flag as the way to build a game against an engine
# worktree. A plain set() here created a normal variable that SHADOWED the
# cache entry, so the override was accepted and then silently ignored: the
# build linked this repo's pinned snesrecomp against C emitted by a DIFFERENT
# engine, which surfaces as undefined runner symbols at link time rather than
# as a clear "wrong engine" error. SMW and MMX already use this form.
set(SNESRECOMP_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/snesrecomp" CACHE PATH
    "Path to the snesrecomp checkout used by this game")

find_package(Python3 COMPONENTS Interpreter REQUIRED)

if(NOT ANDROID)
    include(CTest)
endif()
if(BUILD_TESTING AND NOT ANDROID)
    add_executable(sm_display_test tests/sm_display_test.c src/sm_display.c)
    target_include_directories(sm_display_test PRIVATE
        src
        ${SNESRECOMP_ROOT}/runner/src)
    add_test(NAME sm_display_geometry COMMAND sm_display_test)

    add_executable(ppu_window_test tests/ppu_window_test.c)
    target_include_directories(ppu_window_test PRIVATE
        ${SNESRECOMP_ROOT}/runner/src)
    add_test(NAME ppu_widescreen_windows COMMAND ppu_window_test)

    add_executable(sm_widescreen_test tests/sm_widescreen_test.c src/sm_widescreen.c)
    target_include_directories(sm_widescreen_test PRIVATE
        src
        ${SNESRECOMP_ROOT}/runner/src)
    add_test(NAME sm_widescreen_helpers COMMAND sm_widescreen_test)

    add_test(NAME sm_widescreen_visual_smoke
        COMMAND ${Python3_EXECUTABLE}
                ${CMAKE_CURRENT_SOURCE_DIR}/tools/widescreen_visual_smoke.py
                --root ${CMAKE_CURRENT_SOURCE_DIR}
                --skip-missing)
    set_tests_properties(sm_widescreen_visual_smoke PROPERTIES
        SKIP_RETURN_CODE 77)
endif()

# Android uses the SDL2 source tree fetched by android/fetch_sdl.sh. Desktop
# keeps the framework default (currently SDL3).
if(ANDROID)
    set(SNESRECOMP_SDL_BACKEND "SDL2" CACHE STRING
        "SDL backend (SDL3 or SDL2)" FORCE)
endif()

include(${SNESRECOMP_ROOT}/runner/runner.cmake)

# Launcher UI backend: the SHARED recomp-ui launcher (F:\Projects\recomp-ui,
# consumed as the ./recomp-ui junction/submodule) so every recomp game drives
# ONE launcher repo. The former in-tree launcher_ng has been retired from the
# engine in favour of this shared, console-agnostic launcher.
# CACHE PATH for the same reason as SNESRECOMP_ROOT: a debug worktree, or a
# build pinned against a specific launcher revision, needs to point this
# somewhere other than the in-tree submodule.
set(RECOMP_UI_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/recomp-ui" CACHE PATH
    "Path to the shared recomp-ui checkout used by this game")
include(${RECOMP_UI_ROOT}/recomp_ui.cmake)

# On Android the SDL2 target comes from the sibling add_subdirectory(SDL) in
# android/app/jni/CMakeLists.txt, and rendering goes through SDL_Renderer on
# GLES; the desktop-GL presenter is not compiled at all.
if(NOT ANDROID)
    find_package(OpenGL REQUIRED)
endif()
# Generated recompiler output (produced by tools/regen.sh; not committed).
#
# SM_GEN_DIR is overridable so a build can be pointed at generated C emitted by
# a DIFFERENT engine revision without disturbing this repo's src/gen. That is
# what an engine A/B needs: same sources, same flags, two emits. SMK and F-Zero
# already expose the same knob.
set(SM_GEN_DIR "${CMAKE_CURRENT_SOURCE_DIR}/src/gen" CACHE PATH
    "Directory containing the private generated Super Metroid C sources")
file(GLOB SM_GEN_SOURCES CONFIGURE_DEPENDS ${SM_GEN_DIR}/*.c)
if(NOT SM_GEN_SOURCES)
    message(FATAL_ERROR
        "${SM_GEN_DIR} is empty — run the regen (see header) with a verified "
        "Super Metroid ROM at the repo root before building.")
endif()

# Generated sources are regenerated from the ROM and remain untracked. Apply
# the opt-in, runtime-gated enemy range branches before any bank is compiled so
# regen cannot silently discard widescreen spawning/effect culling support.
add_custom_target(sm_widescreen_overrides ALL
    COMMAND ${Python3_EXECUTABLE}
            ${CMAKE_CURRENT_SOURCE_DIR}/tools/apply_widescreen_overrides.py
            --check --gen-dir ${SM_GEN_DIR}
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Applying Super Metroid widescreen enemy range overrides"
    VERBATIM
)

set(SM_HOST_SOURCES
    ${SNESRECOMP_RUNNER_SOURCES}
    # game-specific runtime
    src/config.c
    src/sm_display.c
    src/main.c
    src/post_mortem.c
    src/gen_stubs.c
    src/sm_cpu_infra.c
    src/sm_rtl.c
    src/sm_spc_player.c
    src/sm_widescreen.c
    src/fiber_compat.c    # Win32 Fiber API shim (ucontext/pthread) for non-Windows
    # recompiled banks (generated)
    ${SM_GEN_SOURCES}
)
if(NOT ANDROID)
    list(APPEND SM_HOST_SOURCES
        # desktop-GL presenter + GLSL presets + loader (SDL_Renderer on Android)
        src/glsl_shader.c
        src/opengl.c
        third_party/gl_core/gl_core_3_1.c)
endif()

if(ANDROID)
    # SDLActivity loads "libmain.so" and calls its SDL_main.
    add_library(SuperMetroidSNESRecomp SHARED ${SM_HOST_SOURCES})
    set_target_properties(SuperMetroidSNESRecomp PROPERTIES OUTPUT_NAME main)
else()
    add_executable(SuperMetroidSNESRecomp ${SM_HOST_SOURCES})
endif()

add_dependencies(SuperMetroidSNESRecomp sm_widescreen_overrides)

target_include_directories(SuperMetroidSNESRecomp PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/recomp
    ${SNESRECOMP_RUNNER_INCLUDE_DIRS}
)

# Desktop SDL is selected through the shared framework helper. Android already
# has the vendored SDL2 target from android/app/jni/CMakeLists.txt, so wire that
# target directly instead of asking find_package() for a host installation.
if(ANDROID)
    target_link_libraries(SuperMetroidSNESRecomp PRIVATE SDL2::SDL2)
    target_compile_definitions(SuperMetroidSNESRecomp PRIVATE
        SNESRECOMP_SDL3=0
        SDL_MAIN_HANDLED)
else()
    snesrecomp_target_sdl(SuperMetroidSNESRecomp)
endif()

# Release version stamp: configure with -DSNESRECOMP_BUILD_VERSION=<ver>
# (the CMake equivalent of the MSVC games' /p:SnesRecompBuildVersion); it
# lands in the post-mortem report's "build" section via the
# SNESRECOMP_BUILD_VERSION define. Unset (local builds) the define is
# omitted and main.c defaults to "dev".
set(SNESRECOMP_BUILD_VERSION "" CACHE STRING
    "Release version stamp baked into crash reports (empty = dev)")
if(SNESRECOMP_BUILD_VERSION)
    target_compile_definitions(SuperMetroidSNESRecomp PRIVATE
        SNESRECOMP_BUILD_VERSION="${SNESRECOMP_BUILD_VERSION}")
endif()

target_compile_definitions(SuperMetroidSNESRecomp PRIVATE
    SMW_DISABLE_LM=1
    SYSTEM_VOLUME_MIXER_AVAILABLE=0   # Win32 WASAPI volume control excluded
    SNESRECOMP_TRACE=$<BOOL:${SNESRECOMP_ENABLE_TRACE}>
    SNESRECOMP_REVERSE_DEBUG=0        # raw WRAM stores; matches non-debug generated C
)

# The recompiled C is machine-generated; quiet its warnings and tolerate the
# K&R-style implicit declarations clang/gcc reject by default.
if(NOT MSVC)
    target_compile_options(SuperMetroidSNESRecomp PRIVATE
        -w -Wno-implicit-function-declaration)
endif()

if(ANDROID)
    target_link_libraries(SuperMetroidSNESRecomp PRIVATE
        ${SNESRECOMP_RUNNER_LIBRARIES}
        android
        log
    )
else()
    target_link_libraries(SuperMetroidSNESRecomp PRIVATE
        ${SNESRECOMP_RUNNER_LIBRARIES}
        OpenGL::GL
    )
endif()

# post_mortem.c's crash backtrace uses the Win32 DbgHelp API (StackWalk64,
# SymFromAddr, ...) on Windows. The MSVC .vcxproj links it via #pragma
# comment(lib); the CMake/MinGW path needs it on the link line explicitly.
if(WIN32)
    target_link_libraries(SuperMetroidSNESRecomp PRIVATE dbghelp)
endif()

# Dear ImGui pre-boot launcher (GUI) from the shared recomp-ui repo. One call
# wires sources/includes/RECOMP_LAUNCHER define/CXX/asset-staging (same SM
# boxart; recomp-ui's default pad.tga is already the SNES pad).
# CONSOLE is required by recomp-ui: it selects exactly one validated
# assets/consoles/<id>/ manifest, so an SNES game cannot silently stage N64
# cartridge or NES pad art next to the exe.
recomp_target_launcher_ui(SuperMetroidSNESRecomp
    CONSOLE snes
    BOXART ${CMAKE_CURRENT_SOURCE_DIR}/recomp/launcher/boxart.tga)
