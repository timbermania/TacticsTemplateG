#include "fft_spu_replay_mix_tools.h"

#include <cstdint>

namespace fftshared {

namespace {

int32_t floor_div_i64(int64_t numer, int64_t denom) {
	int64_t q = numer / denom;
	int64_t r = numer % denom;
	if (r != 0 && ((r < 0) != (denom < 0))) {
		q -= 1;
	}
	return static_cast<int32_t>(q);
}

}  // namespace

void fft_render_replay_mix_frame(std::array<FFTReplayVoiceRuntime, 24> &voices,
		int64_t frame_index, int32_t volume_divisor, FFTReplayFrameMixResult &result) {
	result = FFTReplayFrameMixResult {};

	for (FFTReplayVoiceRuntime &voice : voices) {
		while (voice.event_cursor < static_cast<int64_t>(voice.events.size())) {
			const FFTReplayEvent &event = voice.events[static_cast<size_t>(voice.event_cursor)];
			if (event.sample_index > frame_index) {
				break;
			}
			voice.left_volume = event.left_volume;
			voice.right_volume = event.right_volume;
			voice.reverb = event.reverb;
			voice.event_cursor += 1;
		}

		int32_t sample = 0;
		if (frame_index < voice.sample_len) {
			sample = voice.samples[frame_index];
		}

		const int32_t vol_l = floor_div_i64(int64_t(sample) * voice.left_volume, volume_divisor);
		const int32_t vol_r = floor_div_i64(int64_t(sample) * voice.right_volume, volume_divisor);
		result.sum_l += vol_l;
		result.sum_r += vol_r;
		if (voice.reverb) {
			result.rvb_in_l += vol_l;
			result.rvb_in_r += vol_r;
		}
	}
}

}  // namespace fftshared
