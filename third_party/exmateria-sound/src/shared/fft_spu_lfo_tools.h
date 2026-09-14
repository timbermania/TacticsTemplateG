#ifndef FFT_SPU_LFO_TOOLS_H
#define FFT_SPU_LFO_TOOLS_H

#include <cstdint>

namespace fftshared {

struct FFTPitchLfoBlock {
	bool enabled = false;
	int32_t accum = 0;
	int32_t step = 0;
	int32_t base_step = 0;
	int32_t counter = 0;
	int32_t reload = 0;
	int32_t rate_divider = 0;
	int32_t rate_reload = 0;
	int32_t depth = 0;
	int32_t depth_delta = 0;
	uint8_t mode = 0;
	uint16_t flags = 0;
	int32_t scaled_output = 0;
	int32_t consumer_output = 0;
};

void fft_init_pitch_lfo(FFTPitchLfoBlock &block, int32_t count, int32_t signed_step, int32_t rate_reload);
void fft_init_volume_lfo(FFTPitchLfoBlock &block, int32_t count, int32_t signed_step, int32_t rate_reload);
void fft_clear_pitch_lfo(FFTPitchLfoBlock &block);
void fft_clear_volume_lfo(FFTPitchLfoBlock &block);
void fft_set_pitch_lfo_depth(FFTPitchLfoBlock &block, int32_t depth, int32_t depth_delta);
void fft_set_volume_lfo_depth(FFTPitchLfoBlock &block, int32_t depth, int32_t depth_delta);
void fft_reset_enabled_pitch_lfo_on_key_on(FFTPitchLfoBlock &block);
void fft_reset_enabled_volume_lfo_on_key_on(FFTPitchLfoBlock &block);
void fft_tick_pitch_lfo(FFTPitchLfoBlock &block);
void fft_tick_volume_lfo(FFTPitchLfoBlock &block);

}  // namespace fftshared

#endif  // FFT_SPU_LFO_TOOLS_H
