#include "fft_spu_sample_runtime.h"

#include <cstdint>

#include "fft_spu_voice_tools.h"

namespace fftshared {

void fft_decode_voice_block(FFTSpuVoiceRuntime &voice, const uint8_t *spu_ram, int32_t spu_ram_size) {
	fft_decode_next_block(
			voice.on,
			voice.stop_after_block,
			voice.curr_addr,
			voice.loop_addr,
			voice.buf_pos,
			voice.adpcm_s1,
			voice.adpcm_s2,
			voice.sample_buf,
			spu_ram,
			spu_ram_size);
	if (!voice.on) {
		voice.adsr.state = FFTAdsrEnvelope::STOPPED;
		// Mirror the natural RELEASE→STOPPED drain in
		// fft_adsr_envelope.cpp:155-157 so envelope_vol doesn't sit
		// frozen at its pre-stop value. Without this, probe_envelope_
		// tail reads the stuck field and over-emits ~1680 rows per
		// silenced voice (cure_no_music v20 case). See
		// research/effect_sound/working_documents/
		// PROBE_ENVELOPE_TAIL_VOICE20_STUCK.md.
		voice.adsr.envelope_vol = 0;
		voice.adsr.envelope_vol_f = 0;
	}
}

int32_t fft_get_voice_source_sample(FFTSpuVoiceRuntime &voice, int32_t effective_sinc,
		const uint8_t *spu_ram, int32_t spu_ram_size) {
	voice.latest_interp_sample = fft_get_voice_sample(
			voice.on,
			voice.stop_after_block,
			voice.curr_addr,
			voice.loop_addr,
			voice.buf_pos,
			voice.adpcm_s1,
			voice.adpcm_s2,
			voice.latest_sample,
			voice.latest_interp_sample,
			voice.spos,
			voice.sample_buf,
			voice.gauss_buf,
			voice.gauss_pos,
			effective_sinc,
			spu_ram,
			spu_ram_size);
	if (!voice.on) {
		voice.adsr.state = FFTAdsrEnvelope::STOPPED;
		// Same drain as in fft_get_voice_sample above — see comment
		// there for rationale.
		voice.adsr.envelope_vol = 0;
		voice.adsr.envelope_vol_f = 0;
		return 0;
	}
	voice.fresh_key_on = false;
	return voice.latest_interp_sample;
}

}  // namespace fftshared
