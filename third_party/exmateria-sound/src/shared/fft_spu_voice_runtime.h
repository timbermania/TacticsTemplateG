#ifndef FFT_SPU_VOICE_RUNTIME_H
#define FFT_SPU_VOICE_RUNTIME_H

#include <array>
#include <cstdint>
#include <deque>

#include "fft_adsr_envelope.h"
#include "fft_spu_lfo_tools.h"

namespace fftshared {

// Scheduled pitch update entry for sample-precise SPU pitch register
// writes. PSX SPU mixes one sample at a time and applies pitch register
// changes immediately — Godot's per-block render locks pitch for ~8 ms
// without this, vs PCSX's ~0.7 ms. The queue restores sample-precise
// granularity. Consumed inside the per-frame render loop, which
// decrements sample_offset until 0 then applies raw_pitch via
// fft_set_voice_pitch.
struct FFTPitchUpdateScheduled {
	int32_t sample_offset = 0;  // frames remaining until apply
	int32_t raw_pitch = 0;
};

struct FFTSpuInstrumentData {
	bool is_null = true;
	int32_t fine_tune = 0;
	int32_t adsr1 = 0;
	int32_t adsr2 = 0;
	int32_t sample_offset = 0;
	int32_t sample_size = 0;
	int32_t loop_start = -1;
	int32_t loop_offset_bytes = -1;
	bool has_explicit_loop_start = false;
	bool has_loop_repeat = false;
	int32_t start_offset_bytes = 0;
};

struct FFTSpuVoiceAddresses {
	int32_t start_addr = 0;
	int32_t loop_addr = 0;
	int32_t end_addr = 0;
};

struct FFTSpuVoiceRuntime {
	bool on = false;
	bool fresh_key_on = false;
	bool stop_requested = false;
	bool stop_after_block = false;
	int32_t instrument_idx = -1;
	int32_t start_addr = 0;
	int32_t curr_addr = 0;
	int32_t loop_addr = 0;
	int32_t end_addr = 0;
	int32_t requested_loop_addr = 0;
	std::array<int32_t, 64> sample_buf = {};
	int32_t buf_pos = 28;
	int32_t adpcm_s1 = 0;
	int32_t adpcm_s2 = 0;
	int32_t latest_sample = 0;
	int32_t latest_interp_sample = 0;
	int32_t spos = 0;
	int32_t sinc = 0;
	std::array<int32_t, 4> gauss_buf = { 0, 0, 0, 0 };
	int32_t gauss_pos = 0;
	int32_t left_volume = 0x3FFF;
	int32_t right_volume = 0x3FFF;
	int32_t mix_volume_base = 0;
	int32_t mix_velocity_gain = 0;
	int32_t mix_pan_base = 0;
	int32_t mix_master_gain = 0x7F00;
	int32_t mix_global_pan = 0;
	int32_t raw_pitch = 0;
	int32_t pre_pitch = 0;
	int32_t adsr1 = 0;
	int32_t adsr2 = 0;
	FFTAdsrEnvelope adsr;
	bool reverb = false;
	int32_t sval = 0;

	// Retrigger de-click (typewriter-blip pop fix). When a voice is re-keyed
	// while still audible, hard-resetting the envelope to 0 leaves an
	// instantaneous amplitude STEP from the previous blip's last output to the
	// new note's near-silent attack start — a broadband click. To remove it we
	// capture the previous blip's last emitted L/R output at re-key and ramp
	// that residual linearly to zero over declick_total output samples, ADDED
	// on top of the fresh note. The new note's sample content is untouched;
	// only the DC-ish residual level fades out. This is the software analog of
	// the PSX SPU's click-free KOFF→Release→0 / KON→Attack-from-0 sequencing.
	// Enabled per-core via set_click_retrigger_fade_samples (0 = disabled,
	// bit-identical to the historical instant reset); intended for the reserved
	// typewriter-click mixer only, so music/SFX parity is unaffected.
	int32_t last_out_l = 0;         // last emitted L contribution (post-declick)
	int32_t last_out_r = 0;         // last emitted R contribution (post-declick)
	int32_t declick_l = 0;          // residual L captured at retrigger
	int32_t declick_r = 0;          // residual R captured at retrigger
	int32_t declick_remaining = 0;  // output samples left in the ramp
	int32_t declick_total = 0;      // ramp length (ratio denominator)
	std::array<FFTPitchLfoBlock, 4> lfo_blocks = {};
	// FMod routing: 0 = no FM; 1 = this voice's playback rate is
	// modulated by the previous voice's emitted sample (per-sample);
	// 2 = this voice provides FM to the next voice (its emitted
	// sample value is captured and used as iFMod for next voice).
	// Mirrors PCSX-Redux's Chan::FMod (vendor/pcsx-redux/src/spu/spu.cc:272
	// FModChangeFrequency). FFT's effect-pool pair pattern:
	// silent-driver voice has fmod=2 driving the audible voice (fmod=1).
	int32_t fmod = 0;

	// Noise mode (Chan::Noise per PCSX-Redux spu.cc:296-345). When true, the
	// voice's source sample is replaced by the global SPU noise generator
	// output (16-bit LFSR clocked by NoiseClock). The decoded ADPCM stream is
	// IGNORED for output but ADSR/volume scaling still apply normally.
	bool noise_on = false;

	// Pending sample-precise pitch updates. Each entry holds
	// (sample_offset, raw_pitch); the update fires when sample_offset
	// reaches 0 inside the per-frame render loop. Allows GDScript to
	// schedule pitch writes at exact future audio sample indices instead
	// of immediate-only set_voice_pitch.
	std::deque<FFTPitchUpdateScheduled> pending_pitch_updates;
};

bool fft_spu_instrument_playable(const FFTSpuInstrumentData &instrument);
FFTSpuVoiceAddresses fft_compute_voice_addresses(const FFTSpuInstrumentData &instrument,
		int32_t ram_instrument_base, int32_t spu_ram_size, int32_t adpcm_block_size,
		int32_t start_addr_override, int32_t loop_addr_override, bool use_overrides);
void fft_prepare_voice_for_key_on(FFTSpuVoiceRuntime &voice, int32_t instrument_idx,
		const FFTSpuVoiceAddresses &addresses, int32_t raw_pitch,
		int32_t vol_l, int32_t vol_r, int32_t adsr1, int32_t adsr2,
		bool reverb, bool preserve_repeat_addr, int32_t volume_max,
		int32_t pitch_to_sinc_shift, int32_t adpcm_samples_per_block,
		int32_t retrigger_fade_samples = 0);

}  // namespace fftshared

#endif  // FFT_SPU_VOICE_RUNTIME_H
