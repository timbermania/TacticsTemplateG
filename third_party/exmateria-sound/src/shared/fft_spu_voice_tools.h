#ifndef FFT_SPU_VOICE_TOOLS_H
#define FFT_SPU_VOICE_TOOLS_H

#include <array>
#include <cstdint>

namespace fftshared {

void fft_decode_next_block(
	bool &on,
	bool &stop_after_block,
	int32_t &curr_addr,
	int32_t &loop_addr,
	int32_t &buf_pos,
	int32_t &adpcm_s1,
	int32_t &adpcm_s2,
	std::array<int32_t, 64> &sample_buf,
	const uint8_t *spu_ram,
	int32_t spu_ram_size
);

int32_t fft_get_voice_sample(
	bool &on,
	bool &stop_after_block,
	int32_t &curr_addr,
	int32_t &loop_addr,
	int32_t &buf_pos,
	int32_t &adpcm_s1,
	int32_t &adpcm_s2,
	int32_t &latest_sample,
	int32_t &latest_interp_sample,
	int32_t &spos,
	std::array<int32_t, 64> &sample_buf,
	std::array<int32_t, 4> &gauss_buf,
	int32_t &gauss_pos,
	int32_t effective_sinc,
	const uint8_t *spu_ram,
	int32_t spu_ram_size
);

}  // namespace fftshared

#endif  // FFT_SPU_VOICE_TOOLS_H
