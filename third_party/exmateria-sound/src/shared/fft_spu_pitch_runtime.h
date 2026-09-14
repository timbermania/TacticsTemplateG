#ifndef FFT_SPU_PITCH_RUNTIME_H
#define FFT_SPU_PITCH_RUNTIME_H

#include <cstdint>

#include "fft_spu_voice_runtime.h"

namespace fftshared {

// Optional driver-space pitch remap (#384 / D1 dec. 1).
//
// The SPU's pitch register is a raw 14-bit frequency ratio. How a *note* maps
// to that value is a driver concern, not hardware: every PSX title solved it
// its own way, usually with a ROM lookup table. This SPU therefore keeps note
// space out of the core and takes the mapping as an installable hook.
//
// nullptr — the default — means the core has no note space at all: a voice's
// pitch bias is applied directly in raw pitch units, which is the branch this
// file has always taken for voices whose driver never staged a driver-space
// pitch. A driver that DOES stage one installs its own table here via
// FFTSpuCoreRuntime::set_pitch_remap.
using FFTSpuPitchRemapFn = int32_t (*)(int32_t driver_pitch);

void fft_set_voice_pitch(FFTSpuVoiceRuntime &voice, int32_t raw_pitch, int32_t volume_max, int32_t pitch_to_sinc_shift);
void fft_set_voice_pre_pitch(FFTSpuVoiceRuntime &voice, int32_t pre_pitch);
void fft_tick_voice_pitch_lfo(FFTSpuVoiceRuntime &voice);
bool fft_advance_lfo_tick_counter(int32_t &sample_counter, int32_t tick_samples);
int32_t fft_effective_voice_sinc(const FFTSpuVoiceRuntime &voice, bool lfo_pitch_bias_enabled,
		int32_t volume_max, int32_t pitch_to_sinc_shift, FFTSpuPitchRemapFn pitch_remap = nullptr);

}  // namespace fftshared

#endif  // FFT_SPU_PITCH_RUNTIME_H
