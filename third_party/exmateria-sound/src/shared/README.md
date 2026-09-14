# ExMateria SPU Core

Portable C++ implementation of the *Final Fantasy Tactics* (PSX) sound
chip — SPU voice runtime, ADSR/LFO envelopes, pitch tables, gauss
interpolation, reverb, and the SMD sequencer core. No platform or
framework dependencies; pure C++20 you can drop into any project.

This is the audio engine consumed by the
[ExMateria DAW Plugin](https://github.com/timbermania/ExMateria-DAW-Plugin),
which currently vendors a snapshot of these sources under
`vendor/exmateria-spu-core/`. Other consumers (a Godot SMD player, etc.)
are planned but not yet released.

Most users don't need to interact with this repo directly — it's a
build-time library, not a runtime download.

## Using it from CMake

```cmake
add_subdirectory(path/to/exmateria-spu-core)
target_link_libraries(your_target PRIVATE exmateria::spu_core)
```

That gives you the public headers (`fft_spu_core_runtime.h`,
`fft_smd_sequencer_core.h`, etc.) plus the compiled static library.

## Layout

```
.
├── CMakeLists.txt
├── fft_adsr_envelope.{cpp,h}
├── fft_pitch_tools.{cpp,h}
├── fft_smd_sequencer_core.{cpp,h}
├── fft_smd_sequencer_tools.{cpp,h}
├── fft_spu_core_runtime.{cpp,h}
├── fft_spu_core_state_tools.{cpp,h}
├── fft_spu_lfo_tools.{cpp,h}
├── fft_spu_mix_tools.{cpp,h}
├── fft_spu_pitch_runtime.{cpp,h}
├── fft_spu_replay_mix_tools.{cpp,h}
├── fft_spu_reverb.{cpp,h}
├── fft_spu_sample_runtime.{cpp,h}
├── fft_spu_voice_runtime.{cpp,h}
├── fft_spu_voice_tools.{cpp,h}
├── fft_smd_sequence_model.h
└── detail/
    └── fft_gauss_table.inc
```

## Status

Reverse-engineering and parity work against the original game's SPU
output is ongoing. Most music tracks are handled correctly; a few
opcodes and edge cases are still in progress.
