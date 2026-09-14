#ifndef FFT_SPU_REVERB_H
#define FFT_SPU_REVERB_H

#include <array>
#include <cstdint>
#include <vector>

namespace fftshared {

enum class FFTSpuReverbAlgorithm : int32_t {
	kCurrent = 0,
	kXebra = 1,
};

struct FFTSpuReverbDebugSnapshot {
	bool valid = false;
	int32_t curr_addr = 0;
	int32_t iir_input_a0 = 0;
	int32_t iir_input_a1 = 0;
	int32_t iir_input_b0 = 0;
	int32_t iir_input_b1 = 0;
	int32_t iir_a0 = 0;
	int32_t iir_a1 = 0;
	int32_t iir_b0 = 0;
	int32_t iir_b1 = 0;
	int32_t acc0 = 0;
	int32_t acc1 = 0;
	int32_t fb_a0 = 0;
	int32_t fb_a1 = 0;
	int32_t fb_b0 = 0;
	int32_t fb_b1 = 0;
	int32_t mix_a0 = 0;
	int32_t mix_a1 = 0;
	int32_t mix_b0 = 0;
	int32_t mix_b1 = 0;
	int32_t rvb_l = 0;
	int32_t rvb_r = 0;
	int32_t last_rvb_l = 0;
	int32_t last_rvb_r = 0;
	int32_t out_l = 0;
	int32_t out_r = 0;
};

class FFTSpuReverbModel {
public:
	virtual ~FFTSpuReverbModel() = default;

	virtual void reset_state() = 0;
	virtual void set_enabled(bool enabled) = 0;
	virtual bool enabled() const = 0;
	virtual void set_algorithm(FFTSpuReverbAlgorithm algorithm) = 0;
	virtual FFTSpuReverbAlgorithm algorithm() const = 0;
	virtual const char *algorithm_name() const = 0;
	virtual void set_buffer_start(int32_t addr) = 0;
	virtual int32_t buffer_start() const = 0;
	virtual void set_curr_addr(int32_t addr) = 0;
	virtual int32_t curr_addr() const = 0;
	virtual bool next_mix_odd_branch() const = 0;
	virtual std::array<int32_t, 2> mix(int32_t input_l, int32_t input_r, FFTSpuReverbDebugSnapshot *debug_snapshot = nullptr) = 0;
};

class FFTSpuReverb : public FFTSpuReverbModel {
public:
	static constexpr int32_t kVolumeMax = 0x3FFF;
	static constexpr int32_t kVolumeDivisor = 0x4000;
	static constexpr int32_t kDefaultBufferStart = 0x3C800;
	static constexpr int32_t kBufferEnd = 0x3FFFF;
	static constexpr int32_t kBufferSize = 0x40000;
	static constexpr size_t kFirTapCount = 39;

	FFTSpuReverb();

	void reset_state() override;
	void set_enabled(bool enabled) override;
	bool enabled() const override { return enabled_; }
	void set_algorithm(FFTSpuReverbAlgorithm algorithm) override;
	FFTSpuReverbAlgorithm algorithm() const override { return algorithm_; }
	const char *algorithm_name() const override;
	void set_buffer_start(int32_t addr) override;
	int32_t buffer_start() const override { return buffer_start_; }
	void set_curr_addr(int32_t addr) override;
	int32_t curr_addr() const override { return curr_addr_; }
	bool next_mix_odd_branch() const override { return ((cnt_ + 1) & 1) == 1; }

	std::array<int32_t, 2> mix(int32_t input_l, int32_t input_r, FFTSpuReverbDebugSnapshot *debug_snapshot = nullptr) override;

private:
	std::array<int32_t, 2> mix_current(int32_t input_l, int32_t input_r, FFTSpuReverbDebugSnapshot *debug_snapshot);
	std::array<int32_t, 2> mix_xebra(int32_t input_l, int32_t input_r, FFTSpuReverbDebugSnapshot *debug_snapshot);
	int32_t clip_int16(int32_t value) const;
	int32_t addr(int32_t sample_off) const;
	int32_t g(int32_t off) const;
	int32_t g_raw(int32_t sample_off) const;
	void s(int32_t off, int32_t value);
	void s1(int32_t off, int32_t value);
	void s_raw(int32_t sample_off, int32_t value);
	int32_t fir_input_l() const;
	int32_t fir_input_r() const;

	bool enabled_ = true;
	FFTSpuReverbAlgorithm algorithm_ = FFTSpuReverbAlgorithm::kCurrent;
	int32_t cnt_ = 0;
	int32_t last_l_ = 0;
	int32_t last_r_ = 0;
	int32_t cur_l_ = 0;
	int32_t cur_r_ = 0;
	int32_t buffer_start_ = kDefaultBufferStart;
	int32_t curr_addr_ = kDefaultBufferStart;
	int32_t vol_l_ = kVolumeMax;
	int32_t vol_r_ = kVolumeMax;
	std::array<int32_t, kFirTapCount> input_hist_l_ {};
	std::array<int32_t, kFirTapCount> input_hist_r_ {};
	int32_t input_hist_pos_ = 0;
	std::vector<int16_t> buf_;
};

}  // namespace fftshared

#endif  // FFT_SPU_REVERB_H
