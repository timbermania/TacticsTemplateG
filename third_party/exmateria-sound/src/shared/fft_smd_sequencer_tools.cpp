#include "fft_smd_sequencer_tools.h"

#include <algorithm>
#include <cstdint>

#include "fft_pitch_tools.h"

namespace fftshared {

FFTSmdResolvedAddresses fft_smd_resolve_voice_addresses(const FFTSmdInstrumentInfo &instrument, int32_t ram_instrument_base) {
	FFTSmdResolvedAddresses resolved;
	resolved.start_addr = ram_instrument_base + instrument.sample_offset + instrument.start_offset_bytes;
	resolved.end_addr = resolved.start_addr + instrument.sample_size;
	resolved.loop_addr = resolved.end_addr;

	if (instrument.has_explicit_loop_start && instrument.loop_offset_bytes >= 0) {
		resolved.loop_addr = ram_instrument_base + instrument.sample_offset + instrument.loop_offset_bytes;
	}

	return resolved;
}

std::pair<int32_t, int32_t> fft_smd_apply_adsr_overrides(const FFTSmdTrackStateView &track_state, int32_t adsr1, int32_t adsr2) {
	int32_t am = (adsr1 >> 15) & 1;
	int32_t ar = (adsr1 >> 8) & 0x7F;
	int32_t dr = (adsr1 >> 4) & 0xF;
	int32_t sl = adsr1 & 0xF;
	int32_t rr = adsr2 & 0x1F;
	int32_t rm = (adsr2 >> 5) & 1;
	int32_t sr = (adsr2 >> 6) & 0x7F;
	int32_t sm = (adsr2 >> 15) & 1;
	int32_t sd = (adsr2 >> 14) & 1;

	if (track_state.adsr_attack_override >= 0) {
		ar = track_state.adsr_attack_override & 0x7F;
	}
	if (track_state.adsr_decay_override >= 0) {
		dr = track_state.adsr_decay_override & 0xF;
	}
	if (track_state.adsr_sustain_rate_override >= 0) {
		sr = track_state.adsr_sustain_rate_override & 0x7F;
	}
	if (track_state.adsr_release_override >= 0) {
		rr = track_state.adsr_release_override & 0x1F;
	}
	if (track_state.adsr_sustain_level_override >= 0) {
		sl = track_state.adsr_sustain_level_override & 0xF;
	}
	if (track_state.adsr1_low_override >= 0) {
		sl = track_state.adsr1_low_override & 0xF;
	}

	return {
		(am << 15) | (ar << 8) | (dr << 4) | sl,
		(sm << 15) | (sd << 14) | (sr << 6) | (rm << 5) | rr,
	};
}

int32_t fft_smd_compute_note_life_ticks(int32_t raw_ticks, int32_t gate_mode) {
	if (raw_ticks <= 0) {
		return 0;
	}
	int32_t sustain_ticks = raw_ticks;
	if (gate_mode == 0x0F) {
		sustain_ticks = raw_ticks - 1;
	} else if (gate_mode != 0x10) {
		sustain_ticks = (raw_ticks * gate_mode) >> 4;
	}
	if (sustain_ticks <= 0) {
		return 1;
	}
	return sustain_ticks;
}

int32_t fft_smd_signed_byte(int32_t value) {
	return value >= 128 ? value - 256 : value;
}

FFTSmdResolvedNoteTrigger fft_smd_resolve_note_trigger(const FFTSmdTrackStateView &track_state,
		const FFTSmdInstrumentInfo &instrument, int32_t relative_key, int32_t velocity, int32_t master_vol,
		int32_t ram_instrument_base) {
	FFTSmdResolvedNoteTrigger resolved;
	resolved.midi_note = track_state.octave * 12 + relative_key;
	if (instrument.is_null || instrument.sample_size <= 0) {
		return resolved;
	}

	resolved.has_sample = true;
	resolved.addresses = fft_smd_resolve_voice_addresses(instrument, ram_instrument_base);
	const std::pair<int32_t, int32_t> adsr = fft_smd_apply_adsr_overrides(track_state, instrument.adsr1, instrument.adsr2);
	resolved.adsr1 = adsr.first;
	resolved.adsr2 = adsr.second;
	resolved.pre_pitch = fft_pre_pitch_from_note(static_cast<int16_t>(resolved.midi_note), instrument.fine_tune);
	resolved.raw_pitch = fft_raw_pitch_from_pre_pitch(resolved.pre_pitch);

	const int32_t dynamics_14bit = track_state.volume << 8;
	const int32_t velocity_14bit = velocity << 8;
	const int32_t after_vel = (velocity_14bit * dynamics_14bit) >> 15;
	const int32_t after_master = (master_vol * after_vel) >> 16;
	const int32_t pan_14bit = track_state.pan << 8;
	resolved.mix_volume_base = dynamics_14bit;
	resolved.mix_velocity_gain = velocity_14bit;
	resolved.mix_pan_base = pan_14bit;
	resolved.mix_master_gain = master_vol;
	resolved.mix_global_pan = 0;
	if (pan_14bit < 0x4000) {
		resolved.vol_l = ((0x7F00 - ((pan_14bit * 0x2500) >> 14)) * after_master) >> 15;
		resolved.vol_r = (((pan_14bit * 0x5A00) >> 14) * after_master) >> 15;
	} else {
		const int32_t mirror = 0x8000 - pan_14bit;
		resolved.vol_l = (((mirror * 0x5A00) >> 14) * after_master) >> 15;
		resolved.vol_r = ((0x7F00 - ((mirror * 0x2500) >> 14)) * after_master) >> 15;
	}
	resolved.vol_l = std::clamp(resolved.vol_l, 0, 0x3FFF);
	resolved.vol_r = std::clamp(resolved.vol_r, 0, 0x3FFF);
	return resolved;
}

}  // namespace fftshared
