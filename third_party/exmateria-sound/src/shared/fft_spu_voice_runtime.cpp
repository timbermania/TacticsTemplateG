#include "fft_spu_voice_runtime.h"

#include <algorithm>
#include <cstdint>

namespace fftshared {

bool fft_spu_instrument_playable(const FFTSpuInstrumentData &instrument) {
	return !instrument.is_null && instrument.sample_size > 0;
}

FFTSpuVoiceAddresses fft_compute_voice_addresses(const FFTSpuInstrumentData &instrument,
		int32_t ram_instrument_base, int32_t spu_ram_size, int32_t adpcm_block_size,
		int32_t start_addr_override, int32_t loop_addr_override, bool use_overrides) {
	const int32_t max_addr = std::max(0, spu_ram_size - adpcm_block_size);
	const int32_t default_start_addr = ram_instrument_base + instrument.sample_offset + instrument.start_offset_bytes;
	int32_t default_loop_addr = ram_instrument_base + instrument.sample_offset + instrument.sample_size + instrument.start_offset_bytes;
	if (instrument.has_explicit_loop_start && instrument.loop_offset_bytes >= 0) {
		default_loop_addr = ram_instrument_base + instrument.sample_offset + instrument.loop_offset_bytes;
	} else if (instrument.has_loop_repeat) {
		default_loop_addr = std::max(default_start_addr, default_loop_addr - 0x1010);
	}

	FFTSpuVoiceAddresses addresses;
	addresses.start_addr = use_overrides ? start_addr_override : default_start_addr;
	addresses.loop_addr = use_overrides ? loop_addr_override : default_loop_addr;
	addresses.end_addr = ram_instrument_base + instrument.sample_offset + instrument.sample_size + instrument.start_offset_bytes;
	addresses.start_addr = std::clamp(addresses.start_addr, 0, max_addr);
	addresses.loop_addr = std::clamp(addresses.loop_addr, 0, max_addr);
	return addresses;
}

void fft_prepare_voice_for_key_on(FFTSpuVoiceRuntime &voice, int32_t instrument_idx,
		const FFTSpuVoiceAddresses &addresses, int32_t raw_pitch,
		int32_t vol_l, int32_t vol_r, int32_t adsr1, int32_t adsr2,
		bool reverb, bool preserve_repeat_addr, int32_t volume_max,
		int32_t pitch_to_sinc_shift, int32_t adpcm_samples_per_block,
		int32_t retrigger_fade_samples) {
	// Retrigger de-click: if we are re-keying a voice that is still audible,
	// capture its last emitted L/R output BEFORE the reset below wipes the
	// envelope. fft_finalize_voice_mix_frame ramps this residual to zero over
	// the fade window, added on top of the fresh note, so there is no
	// amplitude step at the reuse seam. Only arms when a fade length is
	// configured (reserved-click mixer); 0 leaves behavior bit-identical.
	if (retrigger_fade_samples > 0 && voice.on) {
		voice.declick_l = voice.last_out_l;
		voice.declick_r = voice.last_out_r;
		voice.declick_remaining = retrigger_fade_samples;
		voice.declick_total = retrigger_fade_samples;
	}
	voice.on = true;
	voice.fresh_key_on = true;
	voice.stop_requested = false;
	voice.stop_after_block = false;
	voice.instrument_idx = instrument_idx;
	fft_reset_enabled_pitch_lfo_on_key_on(voice.lfo_blocks[0]);
	fft_reset_enabled_volume_lfo_on_key_on(voice.lfo_blocks[1]);
	for (int block_idx = 2; block_idx < static_cast<int>(voice.lfo_blocks.size()); ++block_idx) {
		fft_reset_enabled_pitch_lfo_on_key_on(voice.lfo_blocks[block_idx]);
	}
	voice.start_addr = addresses.start_addr;
	voice.curr_addr = voice.start_addr;
	voice.end_addr = addresses.end_addr;
	voice.requested_loop_addr = addresses.loop_addr;
	voice.loop_addr = preserve_repeat_addr ? voice.loop_addr : addresses.loop_addr;
	voice.sample_buf.fill(0);
	voice.buf_pos = adpcm_samples_per_block;
	voice.adpcm_s1 = 0;
	voice.adpcm_s2 = 0;
	voice.latest_sample = 0;
	voice.latest_interp_sample = 0;
	voice.spos = 0x30000;
	voice.sinc = std::clamp(raw_pitch, 1, volume_max) << pitch_to_sinc_shift;
	voice.raw_pitch = std::clamp(raw_pitch, 1, volume_max);
	voice.gauss_buf = { 0, 0, 0, 0 };
	voice.gauss_pos = 0;
	voice.left_volume = std::clamp(vol_l, 0, volume_max);
	voice.right_volume = std::clamp(vol_r, 0, volume_max);
	voice.adsr1 = adsr1;
	voice.adsr2 = adsr2;
	voice.adsr.set_from_regs(adsr1, adsr2);
	voice.adsr.start();
	voice.reverb = reverb;
	voice.sval = 0;
}

}  // namespace fftshared
