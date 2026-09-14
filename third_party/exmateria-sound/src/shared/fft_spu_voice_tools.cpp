#include "fft_spu_voice_tools.h"

#include <algorithm>
#include <array>

namespace fftshared {

namespace {

constexpr int32_t kAdpcmBlockSize = 16;
constexpr int32_t kAdpcmSamplesPerBlock = 28;
constexpr int32_t kSamplePosStep = 0x10000;
constexpr int32_t kClipPcm16Min = -32767;
constexpr int32_t kClipPcm16Max = 32767;

constexpr std::array<std::array<int32_t, 2>, 5> kAdpcmFilter = {{
	{{0, 0}},
	{{60, 0}},
	{{115, -52}},
	{{98, -55}},
	{{122, -60}},
}};

constexpr int32_t clip_pcm16(int32_t value) {
	return value < kClipPcm16Min ? kClipPcm16Min : (value > kClipPcm16Max ? kClipPcm16Max : value);
}

constexpr int32_t kGaussTable[] = {
#include "detail/fft_gauss_table.inc"
};

}  // namespace

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
) {
	if (stop_after_block) {
		on = false;
		stop_after_block = false;
		return;
	}

	const int32_t addr = curr_addr;
	if (addr < 0 || addr + kAdpcmBlockSize > spu_ram_size) {
		on = false;
		return;
	}

	int32_t predict_nr = (spu_ram[addr] >> 4) & 0x0F;
	if (predict_nr > 4) {
		predict_nr = 4;
	}
	const int32_t shift_factor = spu_ram[addr] & 0x0F;
	const int32_t flags = spu_ram[addr + 1];
	const int32_t f0 = kAdpcmFilter[static_cast<size_t>(predict_nr)][0];
	const int32_t f1 = kAdpcmFilter[static_cast<size_t>(predict_nr)][1];

	int32_t s_1 = adpcm_s1;
	int32_t s_2 = adpcm_s2;
	int32_t sample_n = 0;
	for (int32_t byte_idx = addr + 2; byte_idx < addr + kAdpcmBlockSize; ++byte_idx) {
		const uint8_t data_byte = spu_ram[byte_idx];
		for (const int32_t nibble_shift : {0, 4}) {
			int32_t s = ((data_byte >> nibble_shift) & 0x0F) << 12;
			if ((s & 0x8000) != 0) {
				s |= ~0xFFFF;
			}
			int32_t fa = s >> shift_factor;
			fa = fa + ((s_1 * f0) >> 6) + ((s_2 * f1) >> 6);
			s_2 = s_1;
			s_1 = fa;
			sample_buf[static_cast<size_t>(sample_n++)] = fa;
		}
	}

	adpcm_s1 = s_1;
	adpcm_s2 = s_2;
	buf_pos = 0;

	if ((flags & 0x04) != 0) {
		loop_addr = std::clamp(addr, 0, spu_ram_size - kAdpcmBlockSize);
	}

	curr_addr = addr + kAdpcmBlockSize;
	if ((flags & 0x01) != 0) {
		if (flags == 3 && loop_addr > 0) {
			curr_addr = loop_addr;
		} else {
			stop_after_block = true;
		}
	}
}

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
) {
	while (spos >= kSamplePosStep) {
		spos -= kSamplePosStep;
		if (buf_pos >= kAdpcmSamplesPerBlock) {
			fft_decode_next_block(
				on,
				stop_after_block,
				curr_addr,
				loop_addr,
				buf_pos,
				adpcm_s1,
				adpcm_s2,
				sample_buf,
				spu_ram,
				spu_ram_size
			);
			if (!on) {
				return 0;
			}
		}

		latest_sample = clip_pcm16(sample_buf[static_cast<size_t>(buf_pos)]);
		gauss_buf[static_cast<size_t>(gauss_pos)] = latest_sample;
		gauss_pos = (gauss_pos + 1) & 3;
		buf_pos += 1;
	}

	const int32_t vl = (spos >> 6) & ~3;
	const int32_t gp = gauss_pos;
	int32_t vr = (kGaussTable[vl] * gauss_buf[static_cast<size_t>(gp)]) & ~2047;
	vr += (kGaussTable[vl + 1] * gauss_buf[static_cast<size_t>((gp + 1) & 3)]) & ~2047;
	vr += (kGaussTable[vl + 2] * gauss_buf[static_cast<size_t>((gp + 2) & 3)]) & ~2047;
	vr += (kGaussTable[vl + 3] * gauss_buf[static_cast<size_t>((gp + 3) & 3)]) & ~2047;
	latest_interp_sample = vr >> 11;
	spos += effective_sinc;
	return latest_interp_sample;
}

}  // namespace fftshared
