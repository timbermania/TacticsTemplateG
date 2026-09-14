#ifndef FFT_SPU_REPLAY_MIX_TOOLS_H
#define FFT_SPU_REPLAY_MIX_TOOLS_H

#include <array>
#include <cstdint>
#include <vector>

namespace fftshared {

struct FFTReplayEvent {
	int64_t sample_index = 0;
	int32_t left_volume = 0;
	int32_t right_volume = 0;
	bool reverb = false;
};

struct FFTReplayVoiceRuntime {
	const int32_t *samples = nullptr;
	int64_t sample_len = 0;
	std::vector<FFTReplayEvent> events;
	int64_t event_cursor = 0;
	int32_t left_volume = 0;
	int32_t right_volume = 0;
	bool reverb = false;
};

struct FFTReplayFrameMixResult {
	int32_t sum_l = 0;
	int32_t sum_r = 0;
	int32_t rvb_in_l = 0;
	int32_t rvb_in_r = 0;
};

void fft_render_replay_mix_frame(std::array<FFTReplayVoiceRuntime, 24> &voices,
		int64_t frame_index, int32_t volume_divisor, FFTReplayFrameMixResult &result);

}  // namespace fftshared

#endif  // FFT_SPU_REPLAY_MIX_TOOLS_H
