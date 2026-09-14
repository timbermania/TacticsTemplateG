#include "fft_spu_pitch_runtime.h"

#include <algorithm>
#include <cstdint>

namespace fftshared {

void fft_set_voice_pitch(FFTSpuVoiceRuntime &voice, int32_t raw_pitch, int32_t volume_max, int32_t pitch_to_sinc_shift) {
	voice.raw_pitch = std::clamp(raw_pitch, 1, volume_max);
	voice.sinc = voice.raw_pitch << pitch_to_sinc_shift;
}

void fft_set_voice_pre_pitch(FFTSpuVoiceRuntime &voice, int32_t pre_pitch) {
	voice.pre_pitch = pre_pitch;
}

void fft_tick_voice_pitch_lfo(FFTSpuVoiceRuntime &voice) {
	// Subslot 0 — pitch LFO (D7 family). The historical Godot path
	// covered only this one; D7/D8 init paths still write here.
	fft_tick_pitch_lfo(voice.lfo_blocks[0]);
	// Subslot 1 — volume LFO (D8 family). Drives consumer_output which
	// the per-frame mix consumer scales vol_l / vol_r by.
	fft_tick_volume_lfo(voice.lfo_blocks[1]);
	// Subslots 2 + 3 — mode-dispatched per the chan-side mode byte at
	// sub+0x1C. Seeded from chan_lfo_residue.json for sessions whose
	// savestate caught a mid-cast pitch- or pan-LFO running. Mirrors
	// the FFT-side `lfo_handler_tick` jumptable at PC 0x800174C8 — mode
	// 0/2 = pitch-class tick, mode 1 = volume-class tick. See
	// HASTE_VOICE_21_FAITHFUL_LFO_RESIDUE_REPLAY.md §6.4.
	FFTPitchLfoBlock &s2 = voice.lfo_blocks[2];
	switch (s2.mode) {
		case 0:
		case 2: fft_tick_pitch_lfo(s2); break;
		case 1: fft_tick_volume_lfo(s2); break;
		default: break;
	}
	FFTPitchLfoBlock &s3 = voice.lfo_blocks[3];
	switch (s3.mode) {
		case 0:
		case 2: fft_tick_pitch_lfo(s3); break;
		case 1: fft_tick_volume_lfo(s3); break;
		default: break;
	}
}

bool fft_advance_lfo_tick_counter(int32_t &sample_counter, int32_t tick_samples) {
	sample_counter += 1;
	if (sample_counter < tick_samples) {
		return false;
	}
	sample_counter = 0;
	return true;
}

int32_t fft_effective_voice_sinc(const FFTSpuVoiceRuntime &voice, bool lfo_pitch_bias_enabled,
		int32_t volume_max, int32_t pitch_to_sinc_shift, FFTSpuPitchRemapFn pitch_remap) {
	if (!lfo_pitch_bias_enabled) {
		return voice.sinc;
	}

	// Combine pitch-class subslots additively. PCSX's lfo_handler_tick
	// commits each subslot's scaled output back to the chan-side pitch-bias
	// accumulator with += semantics (see HASTE_VOICE_21_FAITHFUL_LFO_RESIDUE_
	// REPLAY.md §6.6 / §9.1.2). Subslot 0 is conventionally pitch (mode 0);
	// subslots 2 + 3 are mode-dispatched and feed pitch when mode is 0 or 2.
	// Subslot 1 is volume-class and routes via consumer_output (no pitch
	// contribution).
	int32_t pitch_bias = 0;
	const FFTPitchLfoBlock &s0 = voice.lfo_blocks[0];
	if (s0.enabled && s0.mode == 0 && s0.scaled_output != 0) {
		pitch_bias += s0.scaled_output;
	}
	const FFTPitchLfoBlock &s2 = voice.lfo_blocks[2];
	if (s2.enabled && (s2.mode == 0 || s2.mode == 2) && s2.scaled_output != 0) {
		pitch_bias += s2.scaled_output;
	}
	const FFTPitchLfoBlock &s3 = voice.lfo_blocks[3];
	if (s3.enabled && (s3.mode == 0 || s3.mode == 2) && s3.scaled_output != 0) {
		pitch_bias += s3.scaled_output;
	}

	if (pitch_bias == 0) {
		return voice.sinc;
	}

	// A driver that stages a driver-space pitch modulates in THAT space and
	// remaps once, per sample; one with no remap installed has no driver space
	// to modulate in, so the bias lands directly on the raw pitch register.
	// Both branches predate the hook — only the mapping moved behind it.
	int32_t biased_raw;
	if (voice.pre_pitch != 0 && pitch_remap != nullptr) {
		biased_raw = pitch_remap(voice.pre_pitch + pitch_bias);
	} else {
		biased_raw = voice.raw_pitch + pitch_bias;
	}
	biased_raw = std::clamp(biased_raw, 1, volume_max);
	return biased_raw << pitch_to_sinc_shift;
}

}  // namespace fftshared
