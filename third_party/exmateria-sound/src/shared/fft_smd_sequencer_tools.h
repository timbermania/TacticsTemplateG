#ifndef FFT_SMD_SEQUENCER_TOOLS_H
#define FFT_SMD_SEQUENCER_TOOLS_H

#include <cstdint>
#include <utility>

namespace fftshared {

struct FFTSmdInstrumentInfo {
	bool is_null = true;
	int32_t fine_tune = 0;
	int32_t adsr1 = 0;
	int32_t adsr2 = 0;
	int32_t loop_start = -1;
	int32_t sample_offset = -1;
	int32_t sample_size = 0;
	int32_t loop_offset_bytes = -1;
	bool has_explicit_loop_start = false;
	bool has_loop_repeat = false;
	int32_t start_offset_bytes = 0;
	int32_t start_sample_skip = 0;
};

struct FFTSmdTrackStateView {
	int32_t octave = 4;
	int32_t instrument = 0;
	int32_t volume = 127;
	int32_t pan = 64;
	bool reverb = false;
	int32_t adsr_attack_override = -1;
	int32_t adsr_sustain_rate_override = -1;
	int32_t adsr_release_override = -1;
	int32_t adsr_decay_override = -1;
	int32_t adsr_sustain_level_override = -1;
	int32_t adsr1_low_override = -1;
};

struct FFTSmdResolvedAddresses {
	int32_t start_addr = 0;
	int32_t loop_addr = 0;
	int32_t end_addr = 0;
};

struct FFTSmdResolvedNoteTrigger {
	bool has_sample = false;
	int32_t midi_note = 0;
	int32_t pre_pitch = 0;
	int32_t raw_pitch = 0;
	int32_t mix_volume_base = 0;
	int32_t mix_velocity_gain = 0;
	int32_t mix_pan_base = 0;
	int32_t mix_master_gain = 0;
	int32_t mix_global_pan = 0;
	int32_t vol_l = 0;
	int32_t vol_r = 0;
	int32_t adsr1 = 0;
	int32_t adsr2 = 0;
	FFTSmdResolvedAddresses addresses;
};

FFTSmdResolvedAddresses fft_smd_resolve_voice_addresses(const FFTSmdInstrumentInfo &instrument, int32_t ram_instrument_base);
std::pair<int32_t, int32_t> fft_smd_apply_adsr_overrides(const FFTSmdTrackStateView &track_state, int32_t adsr1, int32_t adsr2);
int32_t fft_smd_compute_note_life_ticks(int32_t raw_ticks, int32_t gate_mode = 0x0F);
int32_t fft_smd_signed_byte(int32_t value);
FFTSmdResolvedNoteTrigger fft_smd_resolve_note_trigger(const FFTSmdTrackStateView &track_state,
		const FFTSmdInstrumentInfo &instrument, int32_t relative_key, int32_t velocity, int32_t master_vol,
		int32_t ram_instrument_base);

}  // namespace fftshared

#endif  // FFT_SMD_SEQUENCER_TOOLS_H
