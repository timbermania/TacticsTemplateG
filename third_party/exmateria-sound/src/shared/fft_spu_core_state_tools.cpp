#include "fft_spu_core_state_tools.h"

#include <algorithm>
#include <cstdint>
#include <vector>

#include "fft_spu_pitch_runtime.h"

namespace fftshared {

void fft_load_spu_adpcm_bank(std::vector<uint8_t> &spu_ram, const uint8_t *adpcm_bank,
		int32_t adpcm_bank_size, int32_t spu_ram_size, int32_t ram_instrument_base) {
	std::fill(spu_ram.begin(), spu_ram.end(), static_cast<uint8_t>(0));
	const int32_t copy_size = std::min(adpcm_bank_size, spu_ram_size - ram_instrument_base);
	for (int32_t i = 0; i < copy_size; ++i) {
		spu_ram[ram_instrument_base + i] = adpcm_bank[i];
	}
}

void fft_reset_voice_states(std::vector<FFTSpuVoiceRuntime> &voices) {
	for (FFTSpuVoiceRuntime &voice : voices) {
		voice = FFTSpuVoiceRuntime {};
	}
}

void fft_tick_pitch_lfo_all_voices(std::vector<FFTSpuVoiceRuntime> &voices) {
	for (FFTSpuVoiceRuntime &voice : voices) {
		fft_tick_voice_pitch_lfo(voice);
	}
}

int32_t fft_count_active_voices(const std::vector<FFTSpuVoiceRuntime> &voices) {
	int32_t count = 0;
	for (const FFTSpuVoiceRuntime &voice : voices) {
		if (voice.on) {
			++count;
		}
	}
	return count;
}

}  // namespace fftshared
