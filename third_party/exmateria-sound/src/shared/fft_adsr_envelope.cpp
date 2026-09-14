#include "fft_adsr_envelope.h"

#include <algorithm>
#include <array>

namespace fftshared {

namespace {

constexpr int32_t kAdsrExponentialThreshold = 0x6000;
constexpr int32_t kAdsrEnvelopeMax = 32767;
constexpr int32_t kAdsrSustainLevelShift = 11;

constexpr std::array<int32_t, 128> make_denominator() {
	std::array<int32_t, 128> out = {};
	for (int32_t rate = 0; rate < 128; ++rate) {
		out[rate] = rate < 48 ? 1 : (1 << ((rate >> 2) - 11));
	}
	return out;
}

constexpr std::array<int32_t, 128> make_num_inc() {
	std::array<int32_t, 128> out = {};
	for (int32_t rate = 0; rate < 128; ++rate) {
		out[rate] = rate < 48 ? ((7 - (rate & 3)) << (11 - (rate >> 2))) : (7 - (rate & 3));
	}
	return out;
}

constexpr std::array<int32_t, 128> make_num_dec() {
	// PCSX-Redux's exact source form is `(coeff) << (shift)` (see
	// vendor/pcsx-redux/src/spu/adsr.cc:58-62 NumeratorDecreaseGenerator).
	// The Godot project's compile flags reject negative-LHS left-shift
	// (`-Wshift-negative-value` or stricter), so we use the equivalent
	// multiply form `coeff * (1 << shift)`. Under C++20 signed-shift
	// semantics these are mathematically identical — verified bit-exact
	// for every rate 0..127 (iter-52 investigation).
	std::array<int32_t, 128> out = {};
	for (int32_t rate = 0; rate < 128; ++rate) {
		if (rate < 48) {
			const int32_t coeff = -8 + (rate & 3);
			const int32_t shift = 11 - (rate >> 2);
			out[rate] = coeff * (1 << shift);
		} else {
			out[rate] = -8 + (rate & 3);
		}
	}
	return out;
}

constexpr std::array<int32_t, 128> kAdsrDenominator = make_denominator();
constexpr std::array<int32_t, 128> kAdsrNumInc = make_num_inc();
constexpr std::array<int32_t, 128> kAdsrNumDec = make_num_dec();

}  // namespace

void FFTAdsrEnvelope::start() {
	state = ATTACK;
	envelope_vol = 0;
	envelope_vol_f = 0;
}

void FFTAdsrEnvelope::key_off() {
	if (state != STOPPED) {
		state = RELEASE;
	}
}

void FFTAdsrEnvelope::set_from_regs(int32_t adsr1, int32_t adsr2) {
	sustain_level = adsr1 & 0xF;
	decay_rate = (adsr1 >> 4) & 0xF;
	attack_rate = (adsr1 >> 8) & 0x7F;
	attack_mode_exp = (adsr1 >> 15) & 1;
	release_rate = adsr2 & 0x1F;
	release_mode_exp = (adsr2 >> 5) & 1;
	sustain_rate = (adsr2 >> 6) & 0x7F;
	sustain_mode_exp = (adsr2 >> 15) & 1;
	sustain_increase = 1 - ((adsr2 >> 14) & 1);
}

int32_t FFTAdsrEnvelope::mix() {
	int32_t rate = 0;

	switch (state) {
		case ATTACK:
			rate = attack_rate;
			if (attack_mode_exp != 0 && envelope_vol >= kAdsrExponentialThreshold) {
				rate = std::min(rate + 8, 127);
			}
			envelope_vol_f += 1;
			if (envelope_vol_f >= kAdsrDenominator[rate]) {
				envelope_vol_f = 0;
				envelope_vol += kAdsrNumInc[rate];
			}
			if (envelope_vol >= kAdsrEnvelopeMax) {
				envelope_vol = kAdsrEnvelopeMax;
				state = DECAY;
			}
			return envelope_vol >> FFTAdsrEnvelope::kOutputShift;

		case DECAY:
			rate = std::min(decay_rate * 4, 127);
			envelope_vol_f += 1;
			if (envelope_vol_f >= kAdsrDenominator[rate]) {
				envelope_vol_f = 0;
				if (release_mode_exp != 0) {
					envelope_vol += (kAdsrNumDec[rate] * envelope_vol) >> 15;
				} else {
					envelope_vol += kAdsrNumDec[rate];
				}
			}
			if (envelope_vol < 0) {
				envelope_vol = 0;
			}
			if (((envelope_vol >> kAdsrSustainLevelShift) & 0xF) <= sustain_level) {
				state = SUSTAIN;
			}
			return envelope_vol >> FFTAdsrEnvelope::kOutputShift;

		case SUSTAIN:
			rate = sustain_rate;
			if (sustain_increase != 0) {
				if (sustain_mode_exp != 0 && envelope_vol >= kAdsrExponentialThreshold) {
					rate = std::min(rate + 8, 127);
				}
				envelope_vol_f += 1;
				if (envelope_vol_f >= kAdsrDenominator[rate]) {
					envelope_vol_f = 0;
					envelope_vol += kAdsrNumInc[rate];
				}
				if (envelope_vol > kAdsrEnvelopeMax) {
					envelope_vol = kAdsrEnvelopeMax;
				}
			} else {
				envelope_vol_f += 1;
				if (envelope_vol_f >= kAdsrDenominator[rate]) {
					envelope_vol_f = 0;
					if (sustain_mode_exp != 0) {
						envelope_vol += (kAdsrNumDec[rate] * envelope_vol) >> 15;
					} else {
						envelope_vol += kAdsrNumDec[rate];
					}
				}
				if (envelope_vol < 0) {
					envelope_vol = 0;
				}
			}
			return envelope_vol >> FFTAdsrEnvelope::kOutputShift;

		case RELEASE:
			rate = std::min(release_rate * 4, 127);
			envelope_vol_f += 1;
			if (envelope_vol_f >= kAdsrDenominator[rate]) {
				envelope_vol_f = 0;
				if (release_mode_exp != 0) {
					envelope_vol += (kAdsrNumDec[rate] * envelope_vol) >> 15;
				} else {
					envelope_vol += kAdsrNumDec[rate];
				}
			}
			if (envelope_vol < 0) {
				state = STOPPED;
				envelope_vol = 0;
				return 0;
			}
			return envelope_vol >> FFTAdsrEnvelope::kOutputShift;

		case STOPPED:
		default:
			return 0;
	}
}

}  // namespace fftshared
