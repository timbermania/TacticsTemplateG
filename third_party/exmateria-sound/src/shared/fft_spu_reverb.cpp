#include "fft_spu_reverb.h"

#include <algorithm>
#include <array>
#include <cstddef>

namespace fftshared {

namespace {

struct ReverbCoefficients {
	int FB_SRC_A = 0x00E3;
	int FB_SRC_B = 0x00A9;
	int IIR_ALPHA = 28512;
	int ACC_COEF_A = 20392;
	int ACC_COEF_B = -17184;
	int ACC_COEF_C = 17680;
	int ACC_COEF_D = -16656;
	int IIR_COEF = -22912;
	int FB_ALPHA = 22144;
	int FB_X = 21184;
	int IIR_DEST_A0 = 0x0DFB;
	int IIR_DEST_A1 = 0x0B58;
	int ACC_SRC_A0 = 0x0D09;
	int ACC_SRC_A1 = 0x0A3C;
	int ACC_SRC_B0 = 0x0BD9;
	int ACC_SRC_B1 = 0x0973;
	int IIR_SRC_A0 = 0x0B59;
	int IIR_SRC_A1 = 0x08DA;
	int IIR_DEST_B0 = 0x08D9;
	int IIR_DEST_B1 = 0x05E9;
	int ACC_SRC_C0 = 0x07EC;
	int ACC_SRC_C1 = 0x04B0;
	int ACC_SRC_D0 = 0x06EF;
	int ACC_SRC_D1 = 0x03D2;
	int IIR_SRC_B1 = 0x05EA;
	int IIR_SRC_B0 = 0x031D;
	int MIX_DEST_A0 = 0x031C;
	int MIX_DEST_A1 = 0x0238;
	int MIX_DEST_B0 = 0x0154;
	int MIX_DEST_B1 = 0x00AA;
	int IN_COEF_L = -32768;
	int IN_COEF_R = -32768;
};

constexpr ReverbCoefficients kReverb {};
// psx-spx documents the SPU reverb resampler as a 39-tap FIR.
constexpr std::array<int32_t, FFTSpuReverb::kFirTapCount> kFirCoefficients = {
	-1, 0, 2, 0, -10, 0, 35, 0, -103, 0,
	266, 0, -616, 0, 1332, 0, -2960, 0, 10246, 16384,
	10246, 0, -2960, 0, 1332, 0, -616, 0, 266, 0,
	-103, 0, 35, 0, -10, 0, 2, 0, -1,
};

}  // namespace

FFTSpuReverb::FFTSpuReverb() {
	buf_.resize(kBufferSize);
	reset_state();
}

void FFTSpuReverb::reset_state() {
	std::fill(buf_.begin(), buf_.end(), 0);
	cnt_ = 0;
	last_l_ = 0;
	last_r_ = 0;
	cur_l_ = 0;
	cur_r_ = 0;
	curr_addr_ = buffer_start_;
	input_hist_l_.fill(0);
	input_hist_r_.fill(0);
	input_hist_pos_ = 0;
}

void FFTSpuReverb::set_enabled(bool enabled) {
	enabled_ = enabled;
}

void FFTSpuReverb::set_algorithm(FFTSpuReverbAlgorithm algorithm) {
	algorithm_ = algorithm;
}

const char *FFTSpuReverb::algorithm_name() const {
	switch (algorithm_) {
		case FFTSpuReverbAlgorithm::kXebra:
			return "xebra";
		case FFTSpuReverbAlgorithm::kCurrent:
		default:
			return "current";
	}
}

void FFTSpuReverb::set_buffer_start(int32_t addr) {
	buffer_start_ = std::clamp(addr, 0, kBufferEnd);
	reset_state();
}

void FFTSpuReverb::set_curr_addr(int32_t addr) {
	curr_addr_ = std::clamp(addr, buffer_start_, kBufferEnd);
}

std::array<int32_t, 2> FFTSpuReverb::mix(int32_t input_l, int32_t input_r, FFTSpuReverbDebugSnapshot *debug_snapshot) {
	if (debug_snapshot != nullptr) {
		*debug_snapshot = FFTSpuReverbDebugSnapshot {};
	}
	if (!enabled_) {
		return {0, 0};
	}

	input_hist_l_[static_cast<size_t>(input_hist_pos_)] = input_l;
	input_hist_r_[static_cast<size_t>(input_hist_pos_)] = input_r;
	input_hist_pos_ = (input_hist_pos_ + 1) % static_cast<int32_t>(input_hist_l_.size());

	cnt_ += 1;
	if ((cnt_ & 1) != 1) {
		return {last_l_, last_r_};
	}

	switch (algorithm_) {
		case FFTSpuReverbAlgorithm::kXebra:
			return mix_xebra(input_l, input_r, debug_snapshot);
		case FFTSpuReverbAlgorithm::kCurrent:
		default:
			return mix_current(input_l, input_r, debug_snapshot);
	}
}

std::array<int32_t, 2> FFTSpuReverb::mix_current(int32_t input_l, int32_t input_r, FFTSpuReverbDebugSnapshot *debug_snapshot) {
	FFTSpuReverbDebugSnapshot local_debug;

	local_debug.iir_input_a0 = (g(kReverb.IIR_SRC_A0) * kReverb.IIR_COEF) / 32768 + (input_l * kReverb.IN_COEF_L) / 32768;
	local_debug.iir_input_a1 = (g(kReverb.IIR_SRC_A1) * kReverb.IIR_COEF) / 32768 + (input_r * kReverb.IN_COEF_R) / 32768;
	local_debug.iir_input_b0 = (g(kReverb.IIR_SRC_B0) * kReverb.IIR_COEF) / 32768 + (input_l * kReverb.IN_COEF_L) / 32768;
	local_debug.iir_input_b1 = (g(kReverb.IIR_SRC_B1) * kReverb.IIR_COEF) / 32768 + (input_r * kReverb.IN_COEF_R) / 32768;

	local_debug.iir_a0 = (local_debug.iir_input_a0 * kReverb.IIR_ALPHA) / 32768 + (g(kReverb.IIR_DEST_A0) * (32768 - kReverb.IIR_ALPHA)) / 32768;
	local_debug.iir_a1 = (local_debug.iir_input_a1 * kReverb.IIR_ALPHA) / 32768 + (g(kReverb.IIR_DEST_A1) * (32768 - kReverb.IIR_ALPHA)) / 32768;
	local_debug.iir_b0 = (local_debug.iir_input_b0 * kReverb.IIR_ALPHA) / 32768 + (g(kReverb.IIR_DEST_B0) * (32768 - kReverb.IIR_ALPHA)) / 32768;
	local_debug.iir_b1 = (local_debug.iir_input_b1 * kReverb.IIR_ALPHA) / 32768 + (g(kReverb.IIR_DEST_B1) * (32768 - kReverb.IIR_ALPHA)) / 32768;

	s1(kReverb.IIR_DEST_A0, local_debug.iir_a0);
	s1(kReverb.IIR_DEST_A1, local_debug.iir_a1);
	s1(kReverb.IIR_DEST_B0, local_debug.iir_b0);
	s1(kReverb.IIR_DEST_B1, local_debug.iir_b1);

	local_debug.acc0 = (g(kReverb.ACC_SRC_A0) * kReverb.ACC_COEF_A) / 32768 +
		(g(kReverb.ACC_SRC_B0) * kReverb.ACC_COEF_B) / 32768 +
		(g(kReverb.ACC_SRC_C0) * kReverb.ACC_COEF_C) / 32768 +
		(g(kReverb.ACC_SRC_D0) * kReverb.ACC_COEF_D) / 32768;
	local_debug.acc1 = (g(kReverb.ACC_SRC_A1) * kReverb.ACC_COEF_A) / 32768 +
		(g(kReverb.ACC_SRC_B1) * kReverb.ACC_COEF_B) / 32768 +
		(g(kReverb.ACC_SRC_C1) * kReverb.ACC_COEF_C) / 32768 +
		(g(kReverb.ACC_SRC_D1) * kReverb.ACC_COEF_D) / 32768;

	local_debug.fb_a0 = g(kReverb.MIX_DEST_A0 - kReverb.FB_SRC_A);
	local_debug.fb_a1 = g(kReverb.MIX_DEST_A1 - kReverb.FB_SRC_A);
	local_debug.fb_b0 = g(kReverb.MIX_DEST_B0 - kReverb.FB_SRC_B);
	local_debug.fb_b1 = g(kReverb.MIX_DEST_B1 - kReverb.FB_SRC_B);

	s(kReverb.MIX_DEST_A0, local_debug.acc0 - (local_debug.fb_a0 * kReverb.FB_ALPHA) / 32768);
	s(kReverb.MIX_DEST_A1, local_debug.acc1 - (local_debug.fb_a1 * kReverb.FB_ALPHA) / 32768);

	const int32_t fb_alpha_xor = kReverb.FB_ALPHA ^ -32768;
	s(kReverb.MIX_DEST_B0, (kReverb.FB_ALPHA * local_debug.acc0) / 32768 - (local_debug.fb_a0 * fb_alpha_xor) / 32768 - (local_debug.fb_b0 * kReverb.FB_X) / 32768);
	s(kReverb.MIX_DEST_B1, (kReverb.FB_ALPHA * local_debug.acc1) / 32768 - (local_debug.fb_a1 * fb_alpha_xor) / 32768 - (local_debug.fb_b1 * kReverb.FB_X) / 32768);

	local_debug.mix_a0 = g(kReverb.MIX_DEST_A0);
	local_debug.mix_a1 = g(kReverb.MIX_DEST_A1);
	local_debug.mix_b0 = g(kReverb.MIX_DEST_B0);
	local_debug.mix_b1 = g(kReverb.MIX_DEST_B1);

	local_debug.last_rvb_l = cur_l_;
	local_debug.last_rvb_r = cur_r_;
	last_l_ = cur_l_;
	last_r_ = cur_r_;
	cur_l_ = (local_debug.mix_a0 + local_debug.mix_b0) / 3;
	cur_r_ = (local_debug.mix_a1 + local_debug.mix_b1) / 3;
	cur_l_ = (cur_l_ * vol_l_) / kVolumeDivisor;
	cur_r_ = (cur_r_ * vol_r_) / kVolumeDivisor;
	local_debug.rvb_l = cur_l_;
	local_debug.rvb_r = cur_r_;

	curr_addr_ += 1;
	if (curr_addr_ > kBufferEnd) {
		curr_addr_ = buffer_start_;
	}
	local_debug.curr_addr = curr_addr_;

	local_debug.out_l = last_l_ + (cur_l_ - last_l_) / 2;
	local_debug.out_r = last_r_ + (cur_r_ - last_r_) / 2;
	local_debug.valid = true;

	if (debug_snapshot != nullptr) {
		*debug_snapshot = local_debug;
	}
	return {local_debug.out_l, local_debug.out_r};
}

std::array<int32_t, 2> FFTSpuReverb::mix_xebra(int32_t, int32_t, FFTSpuReverbDebugSnapshot *debug_snapshot) {
	FFTSpuReverbDebugSnapshot local_debug;

	const int32_t l_in_fir = fir_input_l();
	const int32_t r_in_fir = fir_input_r();
	const int32_t l_in = (kReverb.IN_COEF_L * l_in_fir) / 32768;
	const int32_t r_in = (kReverb.IN_COEF_R * r_in_fir) / 32768;

	const int32_t m_apf1 = kReverb.FB_SRC_A * 4;
	const int32_t m_apf2 = kReverb.FB_SRC_B * 4;

	const int32_t z0_lsame = kReverb.IIR_DEST_A0 * 4;
	const int32_t z0_rsame = kReverb.IIR_DEST_A1 * 4;
	const int32_t m1_lcomb = kReverb.ACC_SRC_A0 * 4;
	const int32_t m1_rcomb = kReverb.ACC_SRC_A1 * 4;
	const int32_t m2_lcomb = kReverb.ACC_SRC_B0 * 4;
	const int32_t m2_rcomb = kReverb.ACC_SRC_B1 * 4;
	const int32_t zm_lsame = kReverb.IIR_SRC_A0 * 4;
	const int32_t zm_rsame = kReverb.IIR_SRC_A1 * 4;
	const int32_t z0_ldiff = kReverb.IIR_DEST_B0 * 4;
	const int32_t z0_rdiff = kReverb.IIR_DEST_B1 * 4;
	const int32_t m3_lcomb = kReverb.ACC_SRC_C0 * 4;
	const int32_t m3_rcomb = kReverb.ACC_SRC_C1 * 4;
	const int32_t m4_lcomb = kReverb.ACC_SRC_D0 * 4;
	const int32_t m4_rcomb = kReverb.ACC_SRC_D1 * 4;
	const int32_t zm_ldiff = kReverb.IIR_SRC_B1 * 4;
	const int32_t zm_rdiff = kReverb.IIR_SRC_B0 * 4;
	const int32_t z0_lapf1 = kReverb.MIX_DEST_A0 * 4;
	const int32_t z0_rapf1 = kReverb.MIX_DEST_A1 * 4;
	const int32_t z0_lapf2 = kReverb.MIX_DEST_B0 * 4;
	const int32_t z0_rapf2 = kReverb.MIX_DEST_B1 * 4;

	const int32_t z1_lsame = z0_lsame - 1;
	const int32_t z1_rsame = z0_rsame - 1;
	const int32_t z1_ldiff = z0_ldiff - 1;
	const int32_t z1_rdiff = z0_rdiff - 1;
	const int32_t zm_lapf1 = z0_lapf1 - m_apf1;
	const int32_t zm_rapf1 = z0_rapf1 - m_apf1;
	const int32_t zm_lapf2 = z0_lapf2 - m_apf2;
	const int32_t zm_rapf2 = z0_rapf2 - m_apf2;

	int32_t l_temp = g_raw(zm_lsame);
	int32_t r_temp = g_raw(zm_rsame);
	int32_t l_same = l_in + (kReverb.IIR_COEF * l_temp) / 32768;
	int32_t r_same = r_in + (kReverb.IIR_COEF * r_temp) / 32768;
	local_debug.iir_input_a0 = l_same;
	local_debug.iir_input_a1 = r_same;
	l_temp = g_raw(z1_lsame);
	r_temp = g_raw(z1_rsame);
	l_same = l_temp + (kReverb.IIR_ALPHA * (l_same - l_temp)) / 32768;
	r_same = r_temp + (kReverb.IIR_ALPHA * (r_same - r_temp)) / 32768;
	local_debug.iir_a0 = l_same;
	local_debug.iir_a1 = r_same;

	l_temp = g_raw(zm_rdiff);
	r_temp = g_raw(zm_ldiff);
	int32_t l_diff = l_in + (kReverb.IIR_COEF * l_temp) / 32768;
	int32_t r_diff = r_in + (kReverb.IIR_COEF * r_temp) / 32768;
	local_debug.iir_input_b0 = l_diff;
	local_debug.iir_input_b1 = r_diff;
	l_temp = g_raw(z1_ldiff);
	r_temp = g_raw(z1_rdiff);
	l_diff = l_temp + (kReverb.IIR_ALPHA * (l_diff - l_temp)) / 32768;
	r_diff = r_temp + (kReverb.IIR_ALPHA * (r_diff - r_temp)) / 32768;
	local_debug.iir_b0 = l_diff;
	local_debug.iir_b1 = r_diff;

	const int32_t l_comb = (kReverb.ACC_COEF_A * g_raw(m1_lcomb)) / 32768 +
		(kReverb.ACC_COEF_B * g_raw(m2_lcomb)) / 32768 +
		(kReverb.ACC_COEF_C * g_raw(m3_lcomb)) / 32768 +
		(kReverb.ACC_COEF_D * g_raw(m4_lcomb)) / 32768;
	const int32_t r_comb = (kReverb.ACC_COEF_A * g_raw(m1_rcomb)) / 32768 +
		(kReverb.ACC_COEF_B * g_raw(m2_rcomb)) / 32768 +
		(kReverb.ACC_COEF_C * g_raw(m3_rcomb)) / 32768 +
		(kReverb.ACC_COEF_D * g_raw(m4_rcomb)) / 32768;
	local_debug.acc0 = l_comb;
	local_debug.acc1 = r_comb;

	local_debug.fb_a0 = g_raw(zm_lapf1);
	local_debug.fb_a1 = g_raw(zm_rapf1);
	const int32_t l_apf1 = l_comb - (kReverb.FB_ALPHA * local_debug.fb_a0) / 32768;
	const int32_t r_apf1 = r_comb - (kReverb.FB_ALPHA * local_debug.fb_a1) / 32768;
	const int32_t l_apf1_out = local_debug.fb_a0 + (kReverb.FB_ALPHA * l_apf1) / 32768;
	const int32_t r_apf1_out = local_debug.fb_a1 + (kReverb.FB_ALPHA * r_apf1) / 32768;
	local_debug.mix_a0 = l_apf1;
	local_debug.mix_a1 = r_apf1;

	local_debug.fb_b0 = g_raw(zm_lapf2);
	local_debug.fb_b1 = g_raw(zm_rapf2);
	const int32_t l_apf2 = l_apf1_out - (kReverb.FB_X * local_debug.fb_b0) / 32768;
	const int32_t r_apf2 = r_apf1_out - (kReverb.FB_X * local_debug.fb_b1) / 32768;
	const int32_t l_out = local_debug.fb_b0 + (kReverb.FB_X * l_apf2) / 32768;
	const int32_t r_out = local_debug.fb_b1 + (kReverb.FB_X * r_apf2) / 32768;
	local_debug.mix_b0 = l_apf2;
	local_debug.mix_b1 = r_apf2;

	s_raw(z0_lsame, l_same);
	s_raw(z0_rsame, r_same);
	s_raw(z0_ldiff, l_diff);
	s_raw(z0_rdiff, r_diff);
	s_raw(z0_lapf1, l_apf1);
	s_raw(z0_rapf1, r_apf1);
	s_raw(z0_lapf2, l_apf2);
	s_raw(z0_rapf2, r_apf2);

	local_debug.last_rvb_l = cur_l_;
	local_debug.last_rvb_r = cur_r_;
	last_l_ = cur_l_;
	last_r_ = cur_r_;
	cur_l_ = (l_out * vol_l_) / kVolumeDivisor;
	cur_r_ = (r_out * vol_r_) / kVolumeDivisor;
	local_debug.rvb_l = cur_l_;
	local_debug.rvb_r = cur_r_;

	curr_addr_ += 1;
	if (curr_addr_ > kBufferEnd) {
		curr_addr_ = buffer_start_;
	}
	local_debug.curr_addr = curr_addr_;

	local_debug.out_l = last_l_ + (cur_l_ - last_l_) / 2;
	local_debug.out_r = last_r_ + (cur_r_ - last_r_) / 2;
	local_debug.valid = true;

	if (debug_snapshot != nullptr) {
		*debug_snapshot = local_debug;
	}
	return {local_debug.out_l, local_debug.out_r};
}

int32_t FFTSpuReverb::clip_int16(int32_t value) const {
	return std::clamp(value, -32768, 32767);
}

int32_t FFTSpuReverb::addr(int32_t sample_off) const {
	int32_t out = sample_off + curr_addr_;
	while (out >= kBufferSize) {
		out = buffer_start_ + (out - kBufferSize);
	}
	while (out < buffer_start_) {
		out = kBufferSize - 1 - (buffer_start_ - out);
	}
	return out;
}

int32_t FFTSpuReverb::g(int32_t off) const {
	return buf_[static_cast<size_t>(addr(off * 4))];
}

int32_t FFTSpuReverb::g_raw(int32_t sample_off) const {
	return buf_[static_cast<size_t>(addr(sample_off))];
}

void FFTSpuReverb::s(int32_t off, int32_t value) {
	buf_[static_cast<size_t>(addr(off * 4))] = static_cast<int16_t>(clip_int16(value));
}

void FFTSpuReverb::s1(int32_t off, int32_t value) {
	buf_[static_cast<size_t>(addr((off + 1) * 4))] = static_cast<int16_t>(clip_int16(value));
}

void FFTSpuReverb::s_raw(int32_t sample_off, int32_t value) {
	buf_[static_cast<size_t>(addr(sample_off))] = static_cast<int16_t>(clip_int16(value));
}

int32_t FFTSpuReverb::fir_input_l() const {
	int64_t acc = 0;
	for (size_t i = 0; i < kFirCoefficients.size(); ++i) {
		const size_t idx = (static_cast<size_t>(input_hist_pos_) + i) % input_hist_l_.size();
		acc += static_cast<int64_t>(input_hist_l_[idx]) * kFirCoefficients[i];
	}
	return static_cast<int32_t>(acc / 32768);
}

int32_t FFTSpuReverb::fir_input_r() const {
	int64_t acc = 0;
	for (size_t i = 0; i < kFirCoefficients.size(); ++i) {
		const size_t idx = (static_cast<size_t>(input_hist_pos_) + i) % input_hist_r_.size();
		acc += static_cast<int64_t>(input_hist_r_[idx]) * kFirCoefficients[i];
	}
	return static_cast<int32_t>(acc / 32768);
}

}  // namespace fftshared
