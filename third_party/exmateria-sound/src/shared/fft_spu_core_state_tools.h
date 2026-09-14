#ifndef FFT_SPU_CORE_STATE_TOOLS_H
#define FFT_SPU_CORE_STATE_TOOLS_H

#include <cstdint>
#include <vector>

#include "fft_spu_voice_runtime.h"

namespace fftshared {

void fft_load_spu_adpcm_bank(std::vector<uint8_t> &spu_ram, const uint8_t *adpcm_bank,
		int32_t adpcm_bank_size, int32_t spu_ram_size, int32_t ram_instrument_base);
void fft_reset_voice_states(std::vector<FFTSpuVoiceRuntime> &voices);
void fft_tick_pitch_lfo_all_voices(std::vector<FFTSpuVoiceRuntime> &voices);
int32_t fft_count_active_voices(const std::vector<FFTSpuVoiceRuntime> &voices);

}  // namespace fftshared

#endif  // FFT_SPU_CORE_STATE_TOOLS_H
