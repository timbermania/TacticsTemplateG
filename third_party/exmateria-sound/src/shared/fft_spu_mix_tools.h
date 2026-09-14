#ifndef FFT_SPU_MIX_TOOLS_H
#define FFT_SPU_MIX_TOOLS_H

#include <cstdint>
#include <vector>

#include "fft_spu_pitch_runtime.h"
#include "fft_spu_sample_runtime.h"
#include "fft_spu_voice_runtime.h"

namespace fftshared {

struct FFTSpuVoiceMixResult {
	bool active = false;
	int32_t env_vol = 0;
	int32_t sample = 0;
	int32_t vol_l = 0;
	int32_t vol_r = 0;
	// Raw source sample passed to finalize (= post-decode + interpolation,
	// pre-envelope). Mirrors PCSX-Redux spu.cc's interp_sample.
	int32_t interp_sample = 0;
};

struct FFTSpuFrameRenderResult {
	int32_t sum_l = 0;
	int32_t sum_r = 0;
	int32_t rvb_in_l = 0;
	int32_t rvb_in_r = 0;
	int32_t target_sample = 0;
};

// Batched mix output. Mirrors PCSX-Redux's per-NSSIZE (= 45) SSumL/SSumR/iFMod
// accumulator. The batched mixer runs OUTER per voice, INNER per output
// sample (spu.cc:505-815), so each active noise-mode voice sees the shared
// LFSR at the same contiguous advance positions PCSX sees, not the strided
// positions a per-output-sample driver produced before this batching.
struct FFTSpuBatchRenderResult {
	static constexpr int32_t kMaxBatch = 45;  // PCSX-Redux NSSIZE.
	int32_t sum_l[kMaxBatch];
	int32_t sum_r[kMaxBatch];
	int32_t rvb_in_l[kMaxBatch];
	int32_t rvb_in_r[kMaxBatch];
	int32_t target_sample[kMaxBatch];
};

bool fft_finalize_voice_mix_frame(FFTSpuVoiceRuntime &voice, int32_t sample,
		int32_t volume_divisor, FFTSpuVoiceMixResult &result);
// Emit ONLY an off voice's remaining retrigger de-click residual (no sample gen /
// ADSR / FM / noise). Returns false when nothing is armed, so callers that gate on
// an off voice stay bit-identical for non-click cores. See the mix-loop off-gates.
bool fft_emit_voice_declick_tail(FFTSpuVoiceRuntime &voice, FFTSpuVoiceMixResult &result);
bool fft_render_voice_mix_frame(FFTSpuVoiceRuntime &voice, int32_t effective_sinc,
		int32_t volume_divisor, const uint8_t *spu_ram, int32_t spu_ram_size,
		FFTSpuVoiceMixResult &result);
void fft_render_mix_frame(std::vector<FFTSpuVoiceRuntime> &voices,
		bool lfo_pitch_bias_enabled, int32_t volume_max, int32_t pitch_to_sinc_shift,
		int32_t volume_divisor, const uint8_t *spu_ram, int32_t spu_ram_size,
		int32_t target_voice_idx, std::vector<FFTSpuVoiceMixResult> &voice_results,
		FFTSpuFrameRenderResult &frame_result, FFTSpuPitchRemapFn pitch_remap = nullptr);
void fft_render_mix_batch(std::vector<FFTSpuVoiceRuntime> &voices,
		int32_t batch_size, bool lfo_pitch_bias_enabled, int32_t volume_max,
		int32_t pitch_to_sinc_shift, int32_t volume_divisor,
		const uint8_t *spu_ram, int32_t spu_ram_size,
		int32_t target_voice_idx,
		std::vector<FFTSpuVoiceMixResult> &voice_results,
		FFTSpuBatchRenderResult &batch_result, FFTSpuPitchRemapFn pitch_remap = nullptr);

// SPU noise generator clock setting (mirrors spuCtrl bits 8-13 = NoiseShift |
// NoiseStep, range 0..63). 0 = highest-rate broadband white noise. Clock
// state shared across all noise-mode voices per real PSX hardware.
void fft_spu_set_noise_clock(int32_t noise_clock);

// Read the global noise clock (PCSX getNoiseInfo().noiseClock parity).
uint32_t fft_spu_get_noise_clock();

// Seed the global SPU noise LFSR state to mirror a PCSX-Redux savestate's
// m_noiseVal/m_noiseClock/m_noiseCount. Required for noise-using sessions
// to match PCSX bit-for-bit from the seed point forward; without it the
// LFSRs start out-of-sync and produce different noise samples.
//
// Only the low 16 bits of noise_val matter functionally (output is
// int16_t; LFSR feedback uses bits 10-15).
void fft_spu_set_noise_state(uint32_t noise_val, uint32_t noise_clock,
		uint32_t noise_count);

}  // namespace fftshared

#endif  // FFT_SPU_MIX_TOOLS_H
