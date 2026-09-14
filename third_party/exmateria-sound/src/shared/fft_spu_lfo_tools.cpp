#include "fft_spu_lfo_tools.h"

#include <algorithm>
#include <cstdint>

namespace fftshared {

namespace {

void fft_clear_lfo_block(FFTPitchLfoBlock &block) {
	block = FFTPitchLfoBlock {};
}

void fft_set_lfo_depth_fields(FFTPitchLfoBlock &block, int32_t depth, int32_t depth_delta) {
	block.depth = depth;
	block.depth_delta = depth_delta;
}

void fft_reset_enabled_lfo_on_key_on(FFTPitchLfoBlock &block) {
	if (!block.enabled) {
		return;
	}
	block.counter = 1;
	block.accum = 0;
	block.flags &= 0xfff3;
	block.rate_divider = block.rate_reload;
	block.depth = block.depth_delta;
	block.scaled_output = 0;
	block.consumer_output = 0;
}

}  // namespace

void fft_init_pitch_lfo(FFTPitchLfoBlock &block, int32_t count, int32_t signed_step, int32_t rate_reload) {
	if (count <= 0) {
		fft_clear_lfo_block(block);
		return;
	}

	const int32_t step8 = static_cast<int8_t>(signed_step);
	const int32_t magnitude = step8 * (step8 < 0 ? -step8 : step8);
	block.base_step = (magnitude << 14) / count;
	block.reload = count;
	block.counter = 1;
	block.accum = 0;
	block.depth = 0x100;
	block.depth_delta = 0;
	block.rate_reload = rate_reload;
	block.rate_divider = rate_reload;
	block.mode = 0;
	block.flags = 3;
	block.enabled = true;
	block.step = block.base_step;
}

void fft_init_volume_lfo(FFTPitchLfoBlock &block, int32_t count, int32_t signed_step, int32_t rate_reload) {
	if (count <= 0) {
		fft_clear_lfo_block(block);
		return;
	}

	const int32_t step8 = static_cast<int8_t>(signed_step);
	block.base_step = static_cast<int32_t>((int64_t(-step8) * int64_t(1 << 24)) / count);
	block.reload = count;
	block.counter = 1;
	block.accum = 0;
	block.depth = 0x100;
	block.depth_delta = 0;
	block.rate_reload = rate_reload;
	block.rate_divider = rate_reload;
	block.mode = 1;
	block.flags = 3;
	block.enabled = true;
	block.step = -block.base_step;
}

void fft_clear_pitch_lfo(FFTPitchLfoBlock &block) {
	fft_clear_lfo_block(block);
}

void fft_clear_volume_lfo(FFTPitchLfoBlock &block) {
	fft_clear_lfo_block(block);
}

void fft_set_pitch_lfo_depth(FFTPitchLfoBlock &block, int32_t depth, int32_t depth_delta) {
	fft_set_lfo_depth_fields(block, depth, depth_delta);
}

void fft_set_volume_lfo_depth(FFTPitchLfoBlock &block, int32_t depth, int32_t depth_delta) {
	fft_set_lfo_depth_fields(block, depth, depth_delta);
}

void fft_reset_enabled_pitch_lfo_on_key_on(FFTPitchLfoBlock &block) {
	fft_reset_enabled_lfo_on_key_on(block);
}

void fft_reset_enabled_volume_lfo_on_key_on(FFTPitchLfoBlock &block) {
	fft_reset_enabled_lfo_on_key_on(block);
}

void fft_tick_pitch_lfo(FFTPitchLfoBlock &block) {
	if (!block.enabled) {
		return;
	}
	if (block.rate_divider > 0) {
		block.rate_divider -= 1;
		return;
	}

	block.counter -= 1;
	if (block.counter == 0) {
		int32_t new_counter = block.reload;
		if ((block.flags & 0x4) != 0) {
			new_counter <<= 1;
		}
		block.counter = new_counter;
		block.step = (block.flags & 0x8) != 0 ? -block.base_step : block.base_step;
		block.flags = (block.flags | 0x4) ^ 0x8;
	}
	block.accum += block.step;

	if (block.depth < 0x100) {
		int64_t prod = int64_t(block.accum >> 8) * int64_t(block.depth);
		block.scaled_output = static_cast<int32_t>(prod >> 16);
		block.depth += block.depth_delta;
	} else {
		block.scaled_output = block.accum >> 16;
	}
}

void fft_tick_volume_lfo(FFTPitchLfoBlock &block) {
	if (!block.enabled) {
		return;
	}
	if (block.rate_divider > 0) {
		block.rate_divider -= 1;
		return;
	}

	block.counter -= 1;
	if (block.counter == 0) {
		block.counter = block.reload;
		block.flags ^= 0x8;
		block.step = (block.flags & 0x8) != 0 ? block.base_step : -block.base_step;
	}
	block.accum += block.step;

	if (block.depth < 0x100) {
		const int64_t prod = int64_t(block.accum) * int64_t(block.depth);
		block.scaled_output = static_cast<int32_t>(prod >> 30);
		block.consumer_output = static_cast<int32_t>(prod >> 24);
		block.depth += block.depth_delta;
	} else {
		block.scaled_output = block.accum >> 24;
		block.consumer_output = block.accum >> 16;
	}
}

}  // namespace fftshared
