cmake_minimum_required(VERSION 3.20)
project(exmateria_spu_core CXX)

# Static library exposing the FFT PSX SPU + sequencer core. Header-and-impl
# pair, no external dependencies. Consumers add this directory via
# add_subdirectory() and link the `exmateria_spu_core` target.

add_library(exmateria_spu_core STATIC
    fft_adsr_envelope.cpp
    fft_pitch_tools.cpp
    fft_smd_sequencer_core.cpp
    fft_smd_sequencer_tools.cpp
    fft_spu_core_runtime.cpp
    fft_spu_core_state_tools.cpp
    fft_spu_lfo_tools.cpp
    fft_spu_mix_tools.cpp
    fft_spu_pitch_runtime.cpp
    fft_spu_replay_mix_tools.cpp
    fft_spu_reverb.cpp
    fft_spu_sample_runtime.cpp
    fft_spu_voice_runtime.cpp
    fft_spu_voice_tools.cpp
)

target_include_directories(exmateria_spu_core PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
)

target_compile_features(exmateria_spu_core PUBLIC cxx_std_20)

# Match the warning posture of the umbrella plugin build.
if(MSVC)
    target_compile_options(exmateria_spu_core PRIVATE /W3)
else()
    target_compile_options(exmateria_spu_core PRIVATE -Wall -Wextra)
endif()

add_library(exmateria::spu_core ALIAS exmateria_spu_core)
