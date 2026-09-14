#include "fft_spu_mix_tools.h"

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

// SPU noise generator state — port of PCSX-Redux spu.cc:296-345 (Dr. Hell /
// Xebra). Single LFSR shared across all voices in noise mode. Clocked once
// per output sample (via NoiseClock).
//
// m_noiseClock: spuCtrl bits 8-13 (NoiseShift|NoiseStep). Higher values =
// faster LFSR advance (level = 0x8000 >> (clock >> 2), then << 16; the
// counter grows by 0x10000 per call, so advance rate ~ 0x10000/level).
// Default 0x3F (max) gives full-bandwidth white noise; clock 0 makes
// level = 0x8000_0000 so the LFSR effectively never advances (DC silence).
static uint16_t g_noise_val = 0x8000;  // seeded with high bit so LFSR spreads
static uint32_t g_noise_count = 0;
static uint32_t g_noise_clock = 0x3F;  // default to max rate (full-bandwidth)

// LFSR step + frequency table — verbatim from PCSX-Redux spu.cc:311-313, 315.
static constexpr char kNoiseWaveAdd[64] = {
		1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1,
		1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0,
		1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1};
static constexpr unsigned short kNoiseFreqAdd[5] = {0, 84, 140, 180, 210};

// Per-output-sample noise advance. Mirrors PCSX-Redux NoiseClock() exactly.
inline void noise_clock_advance() {
	const unsigned int level = (0x8000u >> (g_noise_clock >> 2)) << 16;
	g_noise_count += 0x10000u;
	g_noise_count += kNoiseFreqAdd[g_noise_clock & 3];
	if ((g_noise_count & 0xffff) >= kNoiseFreqAdd[4]) {
		g_noise_count += 0x10000u;
		g_noise_count -= kNoiseFreqAdd[g_noise_clock & 3];
	}
	if (g_noise_count >= level) {
		while (g_noise_count >= level) {
			g_noise_count -= level;
		}
		g_noise_val = (g_noise_val << 1) |
				kNoiseWaveAdd[(g_noise_val >> 10) & 63];
	}
}

inline int32_t noise_current_sample() {
	return static_cast<int16_t>(g_noise_val);
}

}  // namespace

void fft_spu_set_noise_clock(int32_t noise_clock) {
	g_noise_clock = static_cast<uint32_t>(noise_clock & 0x3F);
}

uint32_t fft_spu_get_noise_clock() {
	return g_noise_clock;
}

void fft_spu_set_noise_state(uint32_t noise_val, uint32_t noise_clock,
		uint32_t noise_count) {
	g_noise_val = static_cast<uint16_t>(noise_val & 0xFFFF);
	g_noise_clock = noise_clock & 0x3F;
	g_noise_count = noise_count;
}

bool fft_finalize_voice_mix_frame(FFTSpuVoiceRuntime &voice, int32_t sample,
		int32_t volume_divisor, FFTSpuVoiceMixResult &result) {
	result = FFTSpuVoiceMixResult {};
	if (!voice.on) {
		return false;
	}

	if (voice.stop_requested) {
		voice.adsr.key_off();
		voice.stop_requested = false;
	}

	result.env_vol = voice.adsr.mix();
	if (voice.adsr.state == FFTAdsrEnvelope::STOPPED) {
		voice.on = false;
		return false;
	}

	result.interp_sample = sample;
	result.sample = floor_div_i64(int64_t(sample) * result.env_vol, 1023);
	voice.sval = result.sample;
	result.vol_l = floor_div_i64(int64_t(result.sample) * voice.left_volume, volume_divisor);
	result.vol_r = floor_div_i64(int64_t(result.sample) * voice.right_volume, volume_divisor);

	// Retrigger de-click: add the captured previous-blip residual, linearly
	// ramped to zero over the fade window. Applied AFTER sval is latched, so
	// the FM chain (fmod==2 driver's sval feeding the next voice) is untouched
	// — only the direct L/R mix contribution is smoothed. Inactive unless a
	// retrigger armed it (declick_remaining > 0), so non-click voices are
	// bit-identical. See FFTSpuVoiceRuntime declick_* / fft_prepare_voice_for_key_on.
	if (voice.declick_remaining > 0 && voice.declick_total > 0) {
		result.vol_l += floor_div_i64(int64_t(voice.declick_l) * voice.declick_remaining, voice.declick_total);
		result.vol_r += floor_div_i64(int64_t(voice.declick_r) * voice.declick_remaining, voice.declick_total);
		voice.declick_remaining -= 1;
	}
	// Track the actual emitted L/R so the NEXT retrigger captures a continuous
	// starting level (includes any residual still fading here).
	voice.last_out_l = result.vol_l;
	voice.last_out_r = result.vol_r;

	result.active = true;
	return true;
}

bool fft_emit_voice_declick_tail(FFTSpuVoiceRuntime &voice, FFTSpuVoiceMixResult &result) {
	// Bleed the armed retrigger de-click residual for a voice that is OFF (ADSR
	// STOPPED, or KOFF'd before its ramp finished) but still has declick_remaining
	// left. fft_finalize_voice_mix_frame only applies the residual while the voice
	// is on, so without this a click voice KOFF'd between blips drops its output
	// to 0 in one sample — the exact typewriter-blip step at ~2-sub retrigger
	// spacing. This emits ONLY the decaying residual (no sample gen / ADSR / FM /
	// noise), ramps it, and tracks last_out so a further retrigger stays
	// continuous. No-op (returns false) when nothing is armed, so non-click cores
	// (declick_remaining == 0) stay bit-identical. See carry_voice_declick.
	result = FFTSpuVoiceMixResult {};
	if (voice.declick_remaining <= 0 || voice.declick_total <= 0) {
		return false;
	}
	result.vol_l = floor_div_i64(int64_t(voice.declick_l) * voice.declick_remaining, voice.declick_total);
	result.vol_r = floor_div_i64(int64_t(voice.declick_r) * voice.declick_remaining, voice.declick_total);
	voice.declick_remaining -= 1;
	voice.last_out_l = result.vol_l;
	voice.last_out_r = result.vol_r;
	result.active = true;
	return true;
}

bool fft_render_voice_mix_frame(FFTSpuVoiceRuntime &voice, int32_t effective_sinc,
		int32_t volume_divisor, const uint8_t *spu_ram, int32_t spu_ram_size,
		FFTSpuVoiceMixResult &result) {
	if (!voice.on) {
		result = FFTSpuVoiceMixResult {};
		return false;
	}
	int32_t source_sample = fft_get_voice_source_sample(voice, effective_sinc, spu_ram, spu_ram_size);
	if (!voice.on) {
		result = FFTSpuVoiceMixResult {};
		return false;
	}
	// Per PCSX-Redux spu.cc:711-712: when Chan::Noise is set, the voice's
	// source sample is REPLACED with the global noise generator output (LFSR).
	// ADSR + volume scaling still apply on the noise sample.
	if (voice.noise_on) {
		source_sample = noise_current_sample();
	}
	return fft_finalize_voice_mix_frame(voice, source_sample, volume_divisor, result);
}

void fft_render_mix_frame(std::vector<FFTSpuVoiceRuntime> &voices,
		bool lfo_pitch_bias_enabled, int32_t volume_max, int32_t pitch_to_sinc_shift,
		int32_t volume_divisor, const uint8_t *spu_ram, int32_t spu_ram_size,
		int32_t target_voice_idx, std::vector<FFTSpuVoiceMixResult> &voice_results,
		FFTSpuFrameRenderResult &frame_result, FFTSpuPitchRemapFn pitch_remap) {
	frame_result = FFTSpuFrameRenderResult {};
	voice_results.assign(voices.size(), FFTSpuVoiceMixResult {});

	// FMod chain: iFMod is set by a voice with fmod==2 (FM source) and
	// consumed by the NEXT voice with fmod==1 (FM modulated). Mirrors
	// PCSX-Redux spu.cc:272-289 (FModChangeFrequency). Reset per frame
	// since FFT's effect-pool pair pattern uses adjacent voice indices.
	int32_t i_fmod = 0;
	for (size_t idx = 0; idx < voices.size(); ++idx) {
		FFTSpuVoiceRuntime &voice = voices[idx];
		if (!voice.on) {
			i_fmod = 0;
			// Off but maybe still ramping out a retrigger de-click residual — add
			// its direct-mix contribution (fmod==2 sources never sum, matching the
			// live path). No-op unless armed, so non-click cores stay bit-identical.
			FFTSpuVoiceMixResult tail;
			if (fft_emit_voice_declick_tail(voice, tail) && voice.fmod != 2) {
				frame_result.sum_l += tail.vol_l;
				frame_result.sum_r += tail.vol_r;
			}
			continue;
		}

		// PCSX-Redux spu.cc:515 + spu.cc:565: NoiseClock() runs in the
		// per-channel mix loop AFTER the Chan::On gate. Each active voice
		// advances the shared LFSR once per output sample. With N active
		// voices, PCSX advances the LFSR N times per output sample; a single
		// top-of-frame advance left Godot N× slow and de-synced cure_4 v18
		// (noise-mode) by ~2430 shifts at first KEY-ON.
		noise_clock_advance();

		FFTSpuVoiceMixResult &mix_result = voice_results[idx];
		int32_t effective_sinc = fft_effective_voice_sinc(
				voice, lfo_pitch_bias_enabled, volume_max, pitch_to_sinc_shift, pitch_remap);
		// FMod target: multiply sinc by (32768 + iFMod)/32768 each output
		// sample. iFMod was set by the previous voice (fmod==2 source).
		if (voice.fmod == 1 && i_fmod != 0) {
			int64_t adj = (int64_t(32768) + i_fmod) * effective_sinc / 32768;
			if (adj < 1) adj = 1;
			if (adj > 0x3FFF << pitch_to_sinc_shift) adj = 0x3FFF << pitch_to_sinc_shift;
			effective_sinc = static_cast<int32_t>(adj);
		}
		if (!fft_render_voice_mix_frame(voice, effective_sinc, volume_divisor, spu_ram, spu_ram_size, mix_result)) {
			i_fmod = 0;
			// Voice went off THIS sample (ADSR hit STOPPED inside finalize, before
			// its declick could apply) — bleed the residual so the transition
			// sample isn't a 1-sample dropout. No-op unless armed.
			FFTSpuVoiceMixResult tail;
			if (fft_emit_voice_declick_tail(voice, tail) && voice.fmod != 2) {
				frame_result.sum_l += tail.vol_l;
				frame_result.sum_r += tail.vol_r;
			}
			continue;
		}

		// FMod source: pass this voice's emitted sample to the next voice
		// as iFMod modulation input. PCSX-Redux uses ch->data.sval which
		// is the post-envelope mixedSample. Per spu.cc:773-797 the fmod==2
		// voice ONLY feeds iFMod and does NOT contribute to SSumL/SSumR
		// direct mix or reverb — skip the sum/reverb adds for fmod==2
		// voices.
		if (voice.fmod == 2) {
			i_fmod = voice.sval;
			// Still expose target_sample for per-voice rendering, but
			// skip the direct-mix and reverb contributions.
			if (static_cast<int32_t>(idx) == target_voice_idx) {
				frame_result.target_sample = mix_result.sample;
			}
			continue;
		}
		i_fmod = 0;

		frame_result.sum_l += mix_result.vol_l;
		frame_result.sum_r += mix_result.vol_r;
		if (voice.reverb) {
			frame_result.rvb_in_l += mix_result.vol_l;
			frame_result.rvb_in_r += mix_result.vol_r;
		}
		if (static_cast<int32_t>(idx) == target_voice_idx) {
			frame_result.target_sample = mix_result.sample;
		}
	}
}

// Batched mixer — port of PCSX-Redux spu.cc:505-815. OUTER per voice,
// INNER per output sample. Each active noise-mode voice reads the shared
// LFSR at the same contiguous advance positions PCSX does within a batch,
// which a per-output-sample / inner-voice driver could not reproduce.
//
// FMod chain: voice with fmod==2 writes iFMod[ns] at sample ns
// (spu.cc:779-781); a later voice with fmod==1 consumes iFMod[ns] at the
// same ns (spu.cc:567-568). The off-gate (spu.cc:515) skips an inactive
// voice entirely without touching iFMod, so a fmod==1 target consumes
// whichever earlier-indexed fmod==2 source wrote iFMod[ns] last.
//
// voice_results: per-voice LAST-sample mix result (used by trace probes
// that snapshot at batch boundaries; full per-sample fidelity is not
// preserved).
void fft_render_mix_batch(std::vector<FFTSpuVoiceRuntime> &voices,
		int32_t batch_size, bool lfo_pitch_bias_enabled, int32_t volume_max,
		int32_t pitch_to_sinc_shift, int32_t volume_divisor,
		const uint8_t *spu_ram, int32_t spu_ram_size,
		int32_t target_voice_idx,
		std::vector<FFTSpuVoiceMixResult> &voice_results,
		FFTSpuBatchRenderResult &batch_result, FFTSpuPitchRemapFn pitch_remap) {
	constexpr int32_t kMaxBatch = FFTSpuBatchRenderResult::kMaxBatch;
	if (batch_size < 0) {
		batch_size = 0;
	}
	if (batch_size > kMaxBatch) {
		batch_size = kMaxBatch;
	}
	for (int32_t ns = 0; ns < batch_size; ++ns) {
		batch_result.sum_l[ns] = 0;
		batch_result.sum_r[ns] = 0;
		batch_result.rvb_in_l[ns] = 0;
		batch_result.rvb_in_r[ns] = 0;
		batch_result.target_sample[ns] = 0;
	}
	voice_results.assign(voices.size(), FFTSpuVoiceMixResult {});

	int32_t i_fmod_buf[kMaxBatch] = { 0 };
	for (size_t idx = 0; idx < voices.size(); ++idx) {
		FFTSpuVoiceRuntime &voice = voices[idx];
		// spu.cc:515 gate — skip the inner loop entirely for off voices.
		// Off voices do not advance the noise LFSR and do not touch iFMod.
		if (!voice.on) {
			// Off at batch entry, but a retrigger de-click ramp may still owe
			// samples — bleed it out per output sample so a click voice KOFF'd
			// between blips ramps to zero instead of stepping. Pure residual add
			// (no sample gen / FM / noise); fmod==2 sources never sum, as in the
			// live path. No-op (breaks immediately) unless armed, so non-click
			// cores stay bit-identical.
			for (int32_t ns = 0; ns < batch_size; ++ns) {
				FFTSpuVoiceMixResult tail;
				if (!fft_emit_voice_declick_tail(voice, tail)) {
					break;
				}
				if (voice.fmod != 2) {
					batch_result.sum_l[ns] += tail.vol_l;
					batch_result.sum_r[ns] += tail.vol_r;
				}
			}
			continue;
		}

		FFTSpuVoiceMixResult &mix_result = voice_results[idx];
		for (int32_t ns = 0; ns < batch_size; ++ns) {
			// spu.cc:565 — per active voice, per output sample. PCSX keeps
			// ticking NoiseClock for the full NSSIZE even if ADSR drops
			// the voice to STOPPED mid-batch (the On gate above is only
			// checked at outer-loop entry).
			noise_clock_advance();

			if (!voice.on) {
				// Voice transitioned to STOPPED earlier in this batch.
				// Keep ticking NoiseClock to mirror PCSX (done above) but skip
				// sample mix — still bleed out any armed retrigger de-click
				// residual so the KOFF seam ramps instead of stepping. No-op
				// unless armed → non-click cores stay bit-identical.
				FFTSpuVoiceMixResult tail;
				if (fft_emit_voice_declick_tail(voice, tail) && voice.fmod != 2) {
					batch_result.sum_l[ns] += tail.vol_l;
					batch_result.sum_r[ns] += tail.vol_r;
				}
				continue;
			}

			int32_t effective_sinc = fft_effective_voice_sinc(
					voice, lfo_pitch_bias_enabled, volume_max, pitch_to_sinc_shift, pitch_remap);
			if (voice.fmod == 1 && i_fmod_buf[ns] != 0) {
				int64_t adj = (int64_t(32768) + i_fmod_buf[ns]) * effective_sinc / 32768;
				if (adj < 1) adj = 1;
				const int64_t max_sinc = int64_t(0x3FFF) << pitch_to_sinc_shift;
				if (adj > max_sinc) adj = max_sinc;
				effective_sinc = static_cast<int32_t>(adj);
			}

			if (!fft_render_voice_mix_frame(voice, effective_sinc, volume_divisor,
					spu_ram, spu_ram_size, mix_result)) {
				// Voice went off THIS sample (STOPPED inside finalize, before its
				// declick applied) — bleed the residual so the transition sample
				// isn't a 1-sample dropout. No-op unless armed.
				FFTSpuVoiceMixResult tail;
				if (fft_emit_voice_declick_tail(voice, tail) && voice.fmod != 2) {
					batch_result.sum_l[ns] += tail.vol_l;
					batch_result.sum_r[ns] += tail.vol_r;
				}
				continue;
			}

			if (voice.fmod == 2) {
				i_fmod_buf[ns] = voice.sval;
				if (static_cast<int32_t>(idx) == target_voice_idx) {
					batch_result.target_sample[ns] = mix_result.sample;
				}
				continue;
			}

			batch_result.sum_l[ns] += mix_result.vol_l;
			batch_result.sum_r[ns] += mix_result.vol_r;
			if (voice.reverb) {
				batch_result.rvb_in_l[ns] += mix_result.vol_l;
				batch_result.rvb_in_r[ns] += mix_result.vol_r;
			}
			if (static_cast<int32_t>(idx) == target_voice_idx) {
				batch_result.target_sample[ns] = mix_result.sample;
			}
		}
	}
}

}  // namespace fftshared
