#ifndef FFT_ADSR_ENVELOPE_H
#define FFT_ADSR_ENVELOPE_H

#include <cstdint>

namespace fftshared {

class FFTAdsrEnvelope {
public:
	static constexpr int32_t kOutputShift = 5;

	enum State {
		ATTACK = 0,
		DECAY = 1,
		SUSTAIN = 2,
		RELEASE = 3,
		STOPPED = 4,
	};

	State state = STOPPED;
	int32_t envelope_vol = 0;
	int32_t envelope_vol_f = 0;
	int32_t attack_rate = 0;
	int32_t attack_mode_exp = 0;
	int32_t decay_rate = 0;
	int32_t sustain_level = 0;
	int32_t sustain_rate = 0;
	int32_t sustain_mode_exp = 0;
	int32_t sustain_increase = 0;
	int32_t release_rate = 0;
	int32_t release_mode_exp = 0;

	void start();
	void key_off();
	void set_from_regs(int32_t adsr1, int32_t adsr2);
	int32_t mix();
};

}  // namespace fftshared

#endif  // FFT_ADSR_ENVELOPE_H
