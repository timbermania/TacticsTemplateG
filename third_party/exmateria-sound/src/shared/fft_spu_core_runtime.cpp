#include "fft_spu_core_runtime.h"

#include <algorithm>
#include <cstdint>
#include <memory>

#include "fft_spu_core_state_tools.h"
#include "fft_spu_pitch_runtime.h"

namespace fftshared {

namespace {

void fft_apply_voice_volume_lfo_consumer(FFTSpuCoreRuntime::Voice &voice) {
	if (voice.mix_velocity_gain <= 0 || voice.mix_master_gain <= 0) {
		return;
	}
	const int32_t volume_bias = voice.lfo_blocks[1].consumer_output;
	const int32_t pan_bias = voice.lfo_blocks[2].consumer_output;
	const int32_t mixed_volume = std::clamp(voice.mix_volume_base + volume_bias, 0, 0x7FFF);
	int32_t gain = (voice.mix_velocity_gain * mixed_volume) >> 15;
	gain = (voice.mix_master_gain * gain) >> 16;

	const int32_t mixed_pan = std::clamp(voice.mix_pan_base + pan_bias + voice.mix_global_pan, 0, 0x7F00);
	int32_t vol_l;
	int32_t vol_r;
	if (mixed_pan < 0x4000) {
		vol_l = ((0x7F00 - ((mixed_pan * 0x2500) >> 14)) * gain) >> 15;
		vol_r = (((mixed_pan * 0x5A00) >> 14) * gain) >> 15;
	} else {
		const int32_t mirror = 0x8000 - mixed_pan;
		vol_l = (((mirror * 0x5A00) >> 14) * gain) >> 15;
		vol_r = ((0x7F00 - ((mirror * 0x2500) >> 14)) * gain) >> 15;
	}
	voice.left_volume = std::clamp(vol_l, 0, FFTSpuCoreRuntime::kVolumeMax);
	voice.right_volume = std::clamp(vol_r, 0, FFTSpuCoreRuntime::kVolumeMax);
}

}  // namespace

FFTSpuCoreRuntime::FFTSpuCoreRuntime() {
	spu_ram_.resize(kSpuRamSize);
	voices_.resize(kNumVoices);
	reverb_ = std::make_unique<FFTSpuReverb>();
	reset();
}

bool FFTSpuCoreRuntime::load_instruments(const std::vector<InstrumentData> &instruments, const uint8_t *adpcm_bank, int32_t adpcm_bank_size) {
	instruments_ = instruments;
	fft_load_spu_adpcm_bank(spu_ram_, adpcm_bank, adpcm_bank_size, kSpuRamSize, kRamInstrumentBase);
	reset();
	return true;
}

void FFTSpuCoreRuntime::reset() {
	std::fill(spu_ram_.begin(), spu_ram_.begin() + std::min<int32_t>(kRamInstrumentBase, static_cast<int32_t>(spu_ram_.size())), 0);
	fft_reset_voice_states(voices_);
	reverb_->reset_state();
	lfo_tick_sample_counter_ = 0;
}

void FFTSpuCoreRuntime::key_on(int32_t voice_idx, int32_t instrument_idx, int32_t pitch, int32_t vol_l, int32_t vol_r, int32_t adsr1, int32_t adsr2, bool reverb) {
	if (instrument_idx < 0 || instrument_idx >= static_cast<int32_t>(instruments_.size())) {
		if (voice_idx >= 0 && voice_idx < kNumVoices) {
			voices_[voice_idx].on = false;
		}
		return;
	}
	const InstrumentData &inst = instruments_[instrument_idx];
	const FFTSpuVoiceAddresses addresses = fft_compute_voice_addresses(
			inst, kRamInstrumentBase, kSpuRamSize, kAdpcmBlockSize, 0, 0, false);
	key_on_with_addresses(voice_idx, instrument_idx, pitch, vol_l, vol_r, adsr1, adsr2, addresses.start_addr, addresses.loop_addr, reverb);
}

void FFTSpuCoreRuntime::key_on_with_addresses(int32_t voice_idx, int32_t instrument_idx, int32_t pitch, int32_t vol_l, int32_t vol_r,
		int32_t adsr1, int32_t adsr2, int32_t start_addr, int32_t loop_addr, bool reverb) {
	if (voice_idx < 0 || voice_idx >= kNumVoices) {
		return;
	}
	if (instrument_idx < 0 || instrument_idx >= static_cast<int32_t>(instruments_.size())) {
		voices_[voice_idx].on = false;
		return;
	}
	const InstrumentData &inst = instruments_[instrument_idx];
	if (!fft_spu_instrument_playable(inst)) {
		voices_[voice_idx].on = false;
		return;
	}
	Voice &voice = voices_[voice_idx];
	const FFTSpuVoiceAddresses addresses = fft_compute_voice_addresses(
			inst, kRamInstrumentBase, kSpuRamSize, kAdpcmBlockSize, start_addr, loop_addr, true);
	const bool preserve_repeat_addr = voice.on && voice.start_addr == addresses.start_addr && voice.loop_addr > addresses.loop_addr;
	fft_prepare_voice_for_key_on(voice, instrument_idx, addresses, pitch, vol_l, vol_r, adsr1, adsr2,
			reverb, preserve_repeat_addr, kVolumeMax, kPitchToSincShift, kAdpcmSamplesPerBlock,
			click_retrigger_fade_samples_);
}

void FFTSpuCoreRuntime::seed_voice_residue(int32_t voice_idx, int32_t start_addr, int32_t loop_addr,
		int32_t curr_addr, int32_t adsr1, int32_t adsr2,
		int32_t env_state, int32_t env_vol, int32_t vol_l, int32_t vol_r,
		int32_t raw_pitch, bool reverb) {
	if (voice_idx < 0 || voice_idx >= kNumVoices) {
		return;
	}
	// HASTE_VOICE_21_FMOD_LFO_RESIDUE_FIX.md §5 — state-preserving variant.
	// The orchestrator's silenceAllVoices wipes SPU register state but
	// leaves the chan-side LFO blocks intact. PCSX's SMD interpreter
	// then re-keys voices that the savestate had pending KON for, but
	// for sessions whose pre-silence env_vol is non-trivial (haste voices
	// 20 + 21), the per-voice WAV scorer compares the audio in the
	// ALIGNED region — and the FM-carrier voice 21 reads voice 20's
	// instantaneous sval at every output sample, so micro-divergence in
	// voice 20's waveform position propagates non-linearly into voice 21
	// via the `NP * (32768 + iFMod) / 32768` modulation. Preserving the
	// residue env_state + env_vol + curr_addr puts Godot's voice 20 at
	// the same waveform position PCSX is at when the SoundTrackController
	// fires its first KEYON, minimizing the FM-input divergence.
	//
	// `fresh_key_on = false` ensures the mixer's first per-sample step
	// does NOT call fft_reset_enabled_pitch_lfo_on_key_on — the chan-side
	// LFO blocks survived the silence in FFT's memory model.
	Voice &voice = voices_[voice_idx];
	voice.on = true;
	voice.fresh_key_on = false;
	voice.stop_requested = false;
	voice.stop_after_block = false;
	voice.reverb = reverb;
	voice.start_addr = start_addr;
	voice.loop_addr = loop_addr;
	voice.curr_addr = curr_addr;
	voice.requested_loop_addr = loop_addr;
	// SPU end_addr is start + sample_size; without the instrument record
	// we don't have sample_size. Set end_addr large so the voice loops
	// through loop_addr naturally via the LOOP_REPEAT flag in the ADPCM
	// block headers (same outcome as a normally-keyed voice).
	voice.end_addr = kSpuRamSize;
	voice.adsr1 = adsr1;
	voice.adsr2 = adsr2;
	voice.adsr.set_from_regs(adsr1, adsr2);
	voice.adsr.state = static_cast<FFTAdsrEnvelope::State>(
			env_state >= 0 && env_state <= 4 ? env_state : 4 /* STOPPED */);
	voice.adsr.envelope_vol = env_vol;
	voice.adsr.envelope_vol_f = 0;
	voice.left_volume = std::clamp(vol_l, 0, kVolumeMax);
	voice.right_volume = std::clamp(vol_r, 0, kVolumeMax);
	fft_set_voice_pitch(voice, raw_pitch, kVolumeMax, kPitchToSincShift);
	voice.sample_buf.fill(0);
	voice.buf_pos = kAdpcmSamplesPerBlock;
	voice.adpcm_s1 = 0;
	voice.adpcm_s2 = 0;
	voice.latest_sample = 0;
	voice.latest_interp_sample = 0;
	voice.spos = 0x30000;
	voice.gauss_buf = {0, 0, 0, 0};
	voice.gauss_pos = 0;
	voice.instrument_idx = -1;  // residue voice — no instrument record
	voice.pending_pitch_updates.clear();
}

void FFTSpuCoreRuntime::carry_voice_declick(int32_t src_voice_idx, int32_t dst_voice_idx) {
	const int32_t fade = click_retrigger_fade_samples_;
	if (fade <= 0) {
		return;  // de-click disabled (music/SFX cores) — bit-identical
	}
	if (src_voice_idx < 0 || src_voice_idx >= kNumVoices) {
		return;
	}
	if (dst_voice_idx < 0 || dst_voice_idx >= kNumVoices) {
		return;
	}
	// Seed the destination's de-click ramp from the source's last emitted output.
	// fft_finalize_voice_mix_frame then fades this residual to zero over `fade`
	// samples, ADDED on top of the fresh note — removing the amplitude step even
	// across a voice-pair change. Mirrors the on-gated arm block in
	// fft_prepare_voice_for_key_on, but reads an explicit source voice so it works
	// when dst is a fresh voice whose own last_out is already 0.
	const FFTSpuVoiceRuntime &src = voices_[src_voice_idx];
	FFTSpuVoiceRuntime &dst = voices_[dst_voice_idx];
	dst.declick_l = src.last_out_l;
	dst.declick_r = src.last_out_r;
	dst.declick_remaining = fade;
	dst.declick_total = fade;
}

void FFTSpuCoreRuntime::key_off(int32_t voice_idx) {
	if (voice_idx < 0 || voice_idx >= kNumVoices) {
		return;
	}
	voices_[voice_idx].stop_requested = true;
}

void FFTSpuCoreRuntime::set_voice_pitch(int32_t voice_idx, int32_t raw_pitch) {
	if (voice_idx < 0 || voice_idx >= kNumVoices) {
		return;
	}
	fft_set_voice_pitch(voices_[voice_idx], raw_pitch, kVolumeMax, kPitchToSincShift);
}

// Schedule a pitch update to fire `sample_offset` audio frames in the
// future. sample_offset = 0 fires on the next render frame. Callers use
// this to align Godot pitch writes to PSX SPU sample-precise timing
// rather than to render-block boundaries (~367 samples). No-op for
// sample_offset < 0.
void FFTSpuCoreRuntime::set_voice_pitch_at(int32_t voice_idx, int32_t raw_pitch, int32_t sample_offset) {
	if (voice_idx < 0 || voice_idx >= kNumVoices || sample_offset < 0) {
		return;
	}
	voices_[voice_idx].pending_pitch_updates.push_back(
			FFTPitchUpdateScheduled { sample_offset, raw_pitch });
}

// Drain ready scheduled pitch updates for one voice. Called from the
// per-frame render loop BEFORE consuming the voice's source sample.
// Decrements all pending sample_offsets by 1 and applies any update
// whose offset has reached 0 (FIFO; last scheduled wins for the same
// offset, matching FFT semantics where the latest pitch register write
// before SPU mix is the one that takes effect).
void FFTSpuCoreRuntime::tick_voice_pitch_queue(int32_t voice_idx) {
	if (voice_idx < 0 || voice_idx >= kNumVoices) {
		return;
	}
	auto &q = voices_[voice_idx].pending_pitch_updates;
	if (q.empty()) {
		return;
	}
	bool applied = false;
	int32_t pitch_to_apply = 0;
	while (!q.empty() && q.front().sample_offset <= 0) {
		pitch_to_apply = q.front().raw_pitch;
		applied = true;
		q.pop_front();
	}
	if (applied) {
		fft_set_voice_pitch(voices_[voice_idx], pitch_to_apply, kVolumeMax, kPitchToSincShift);
	}
	for (auto &entry : q) {
		entry.sample_offset -= 1;
	}
}

void FFTSpuCoreRuntime::set_voice_pre_pitch(int32_t voice_idx, int32_t pre_pitch) {
	if (voice_idx < 0 || voice_idx >= kNumVoices) {
		return;
	}
	fft_set_voice_pre_pitch(voices_[voice_idx], pre_pitch);
}

void FFTSpuCoreRuntime::set_voice_fmod(int32_t voice_idx, int32_t mode) {
	if (voice_idx < 0 || voice_idx >= kNumVoices) {
		return;
	}
	voices_[voice_idx].fmod = mode;
}

void FFTSpuCoreRuntime::set_voice_noise(int32_t voice_idx, bool on) {
	if (voice_idx < 0 || voice_idx >= kNumVoices) {
		return;
	}
	voices_[voice_idx].noise_on = on;
}

void FFTSpuCoreRuntime::set_noise_clock(int32_t noise_clock) {
	fft_spu_set_noise_clock(noise_clock);
}

void FFTSpuCoreRuntime::set_noise_state(uint32_t noise_val, uint32_t noise_clock,
		uint32_t noise_count) {
	fft_spu_set_noise_state(noise_val, noise_clock, noise_count);
}

void FFTSpuCoreRuntime::set_voice_adsr1_low(int32_t voice_idx, int32_t nibble) {
	if (voice_idx < 0 || voice_idx >= kNumVoices) {
		return;
	}
	Voice &voice = voices_[voice_idx];
	voice.adsr1 = (voice.adsr1 & ~0xF) | (nibble & 0xF);
	voice.adsr.set_from_regs(voice.adsr1, voice.adsr2);
}

// Mid-spell ADSR2 register update for opcodes 0xC9 / 0xCA. Mirrors FFT
// helpers L8001B9D4 (sustain bits) and L8001BAB8 (release bits) which
// write SPU register 1F801C0A+v*0x10. The GDScript dispatcher computes
// the full 16-bit ADSR2 (including mode bits picked from slot+0x58); we
// just store it here, then refresh the cached fields the mix() consumer
// reads (sustain_rate, sustain_increase, sustain_mode_exp, release_rate,
// release_mode_exp).
void FFTSpuCoreRuntime::set_voice_adsr2(int32_t voice_idx, int32_t adsr2) {
	if (voice_idx < 0 || voice_idx >= kNumVoices) {
		return;
	}
	Voice &voice = voices_[voice_idx];
	voice.adsr2 = adsr2 & 0xFFFF;
	voice.adsr.set_from_regs(voice.adsr1, voice.adsr2);
}

// Mirrors FFT FUN_8001B428: writes vol_L (SPU+0) + vol_R (SPU+2), no sweep.
// Helper masks each operand with 0x7fff (clears bit 15 = no sweep mode).
void FFTSpuCoreRuntime::set_voice_volume_lr(int32_t voice_idx, int32_t vol_l, int32_t vol_r) {
	if (voice_idx < 0 || voice_idx >= kNumVoices) {
		return;
	}
	Voice &voice = voices_[voice_idx];
	voice.left_volume = vol_l & 0x7FFF;
	voice.right_volume = vol_r & 0x7FFF;
}

// Walker bit 0x008 SAMPLE_ADDR fan-out. Mirror FFT FUN_8001B6A4 (writes
// SPU+0x6 = sample start_addr). Pure register write — no KEYON re-arm,
// no curr_addr / ADPCM decode reset.
void FFTSpuCoreRuntime::set_voice_start_addr(int32_t voice_idx, int32_t start_addr) {
	if (voice_idx < 0 || voice_idx >= kNumVoices) {
		return;
	}
	voices_[voice_idx].start_addr = start_addr;
}

// Mirrors FFT FUN_8001B720 (writes SPU+0xE = sample repeat_addr).
// Updates the loop / repeat target the SPU jumps to on ADPCM block-end
// without restarting playback.
void FFTSpuCoreRuntime::set_voice_repeat_addr(int32_t voice_idx, int32_t repeat_addr) {
	if (voice_idx < 0 || voice_idx >= kNumVoices) {
		return;
	}
	voices_[voice_idx].loop_addr = repeat_addr;
}

// Mirrors FFT FUN_8001B4B0: writes vol_L + vol_R with optional sweep mode.
// Mode 1..7 maps to high-nibble bits 0x8000, 0x9000, ..., 0xE000. Mode 0 (or
// out-of-range) leaves the high nibble at 0 (raw write equivalent to
// set_voice_volume_lr). Per the helper decomp the switch is on (mode-1)
// with 7 cases — modes outside 1..7 produce no high-nibble bits.
static inline int32_t volume_mode_high_nibble(int32_t mode) {
	switch (mode - 1) {
		case 0: return 0x8000;
		case 1: return 0x9000;
		case 2: return 0xA000;
		case 3: return 0xB000;
		case 4: return 0xC000;
		case 5: return 0xD000;
		case 6: return 0xE000;
		default: return 0;
	}
}

void FFTSpuCoreRuntime::set_voice_volume_lr_with_mode(int32_t voice_idx,
		int32_t vol_l, int32_t vol_r, int32_t mode_l, int32_t mode_r) {
	if (voice_idx < 0 || voice_idx >= kNumVoices) {
		return;
	}
	Voice &voice = voices_[voice_idx];
	// Note: PSX SPU sweep mode (high nibble of vol register) shapes volume
	// envelope on the SPU itself. Godot's mixer mirrors only the linear-
	// volume value; sweep mode is dropped here. Capturing the high-nibble
	// bits in the future would require new ramp state on the voice.
	voice.left_volume = (vol_l & 0x7FFF) | (volume_mode_high_nibble(mode_l) & 0x7FFF);
	voice.right_volume = (vol_r & 0x7FFF) | (volume_mode_high_nibble(mode_r) & 0x7FFF);
}

// Mirrors FFT FUN_8001B938: RMW ADSR1 high byte (bits 8-15) =
//   (param_2 | ((param_3 == 5) ? 0x80 : 0)) << 8
// Bit 15 of ADSR1 is the attack-mode (linear vs exponential) flag, bits 8-14
// are the attack rate (7 bits). Caller passes attack_rate (0..127) and
// lin_or_exp_mode (5 = exponential, anything else = linear).
void FFTSpuCoreRuntime::set_voice_adsr1_high(int32_t voice_idx,
		int32_t attack_rate, int32_t lin_or_exp_mode) {
	if (voice_idx < 0 || voice_idx >= kNumVoices) {
		return;
	}
	Voice &voice = voices_[voice_idx];
	int32_t mode_bit = (lin_or_exp_mode == 5) ? 0x80 : 0;
	int32_t high_byte = ((attack_rate & 0x7F) | mode_bit) << 8;
	voice.adsr1 = (voice.adsr1 & 0xFF) | (high_byte & 0xFF00);
	voice.adsr.set_from_regs(voice.adsr1, voice.adsr2);
}

// Mirrors FFT FUN_8001B79C: RMW ADSR1 mid-nibble (bits 4-7) =
//   (cur & 0xff0f) | (param_2 << 4)
// Bits 4-7 carry decay-rate / sustain-rate-LSB on the PSX SPU layout.
void FFTSpuCoreRuntime::set_voice_adsr1_mid(int32_t voice_idx, int32_t mid_nibble) {
	if (voice_idx < 0 || voice_idx >= kNumVoices) {
		return;
	}
	Voice &voice = voices_[voice_idx];
	voice.adsr1 = (voice.adsr1 & 0xFF0F) | ((mid_nibble & 0xF) << 4);
	voice.adsr.set_from_regs(voice.adsr1, voice.adsr2);
}

// Mirrors FFT FUN_8001BAB8: RMW ADSR2 low bits (bits 0-5) =
//   (cur & 0xffc0) | param_2 | mode_bits
// where mode_bits = (param_3 == 7) ? 0x20 : 0  (when param_3 != 3),
// else 0. Caller passes the 6-bit low value + the FFT mode selector.
void FFTSpuCoreRuntime::set_voice_adsr2_low(int32_t voice_idx,
		int32_t low_bits, int32_t mode) {
	if (voice_idx < 0 || voice_idx >= kNumVoices) {
		return;
	}
	Voice &voice = voices_[voice_idx];
	int32_t mode_bits = 0;
	if (mode != 3) {
		mode_bits = (mode == 7) ? 0x20 : 0;
	}
	voice.adsr2 = (voice.adsr2 & 0xFFC0) | (low_bits & 0x3F) | mode_bits;
	voice.adsr.set_from_regs(voice.adsr1, voice.adsr2);
}

void FFTSpuCoreRuntime::set_voice_mix_controls(int32_t voice_idx, int32_t volume_base, int32_t velocity_gain,
		int32_t pan_base, int32_t master_gain, int32_t global_pan) {
	if (voice_idx < 0 || voice_idx >= kNumVoices) {
		return;
	}
	Voice &voice = voices_[voice_idx];
	voice.mix_volume_base = volume_base;
	voice.mix_velocity_gain = velocity_gain;
	voice.mix_pan_base = pan_base;
	voice.mix_master_gain = master_gain;
	voice.mix_global_pan = global_pan;
}

void FFTSpuCoreRuntime::init_voice_pitch_lfo(int32_t voice_idx, int32_t count, int32_t signed_step, int32_t rate_reload) {
	if (voice_idx < 0 || voice_idx >= kNumVoices) {
		return;
	}
	fft_init_pitch_lfo(voices_[voice_idx].lfo_blocks[0], count, signed_step, rate_reload);
}

void FFTSpuCoreRuntime::clear_voice_pitch_lfo(int32_t voice_idx) {
	if (voice_idx < 0 || voice_idx >= kNumVoices) {
		return;
	}
	fft_clear_pitch_lfo(voices_[voice_idx].lfo_blocks[0]);
}

void FFTSpuCoreRuntime::set_voice_pitch_lfo_depth(int32_t voice_idx, int32_t depth, int32_t depth_delta) {
	if (voice_idx < 0 || voice_idx >= kNumVoices) {
		return;
	}
	fft_set_pitch_lfo_depth(voices_[voice_idx].lfo_blocks[0], depth, depth_delta);
}

void FFTSpuCoreRuntime::init_voice_volume_lfo(int32_t voice_idx, int32_t count, int32_t signed_step, int32_t rate_reload) {
	if (voice_idx < 0 || voice_idx >= kNumVoices) {
		return;
	}
	fft_init_volume_lfo(voices_[voice_idx].lfo_blocks[1], count, signed_step, rate_reload);
}

void FFTSpuCoreRuntime::clear_voice_volume_lfo(int32_t voice_idx) {
	if (voice_idx < 0 || voice_idx >= kNumVoices) {
		return;
	}
	fft_clear_volume_lfo(voices_[voice_idx].lfo_blocks[1]);
}

void FFTSpuCoreRuntime::set_voice_volume_lfo_depth(int32_t voice_idx, int32_t depth, int32_t depth_delta) {
	if (voice_idx < 0 || voice_idx >= kNumVoices) {
		return;
	}
	fft_set_volume_lfo_depth(voices_[voice_idx].lfo_blocks[1], depth, depth_delta);
}

void FFTSpuCoreRuntime::set_voice_lfo_subslot(int32_t voice_idx, int32_t subslot_idx,
		int32_t accum, int32_t step_current, int32_t step_source,
		int32_t countdown, int32_t inner_reload,
		int32_t depth, int32_t depth_reload,
		int32_t mode, int32_t active_dir_flags) {
	if (voice_idx < 0 || voice_idx >= kNumVoices) {
		return;
	}
	if (subslot_idx < 0 || subslot_idx >= 4) {
		return;
	}
	FFTPitchLfoBlock &block = voices_[voice_idx].lfo_blocks[subslot_idx];
	block.accum = accum;
	block.step = step_current;
	block.base_step = step_source;
	block.counter = countdown;
	block.reload = inner_reload;
	// FFT chan-side doesn't expose rate_divider separately; the
	// per-subslot rate-prescaler lives in the chan-block byte at the
	// subslot's mode-dispatcher level and reloads from inner_reload's
	// upper half. For the savestate-residue replay we don't need an
	// independent prescaler — the tick logic uses counter/reload, and
	// rate_divider==0 lets ticking proceed every IRQ. See §9.1 known
	// unknowns in HASTE_VOICE_21_FAITHFUL_LFO_RESIDUE_REPLAY.md.
	block.rate_divider = 0;
	block.rate_reload = 0;
	block.depth = depth;
	block.depth_delta = (depth == depth_reload) ? 0 : (depth_reload - depth);
	block.mode = static_cast<uint8_t>(mode & 0xff);
	block.flags = static_cast<uint16_t>(active_dir_flags & 0xffff);
	block.scaled_output = 0;
	block.consumer_output = 0;
	// PCSX's lfo_handler_tick gates per-subslot on `andi v0, 0x1` at PC
	// 0x800174EC. Mirror that gate here so we never tick a dormant
	// subslot, and tick-side gating in fft_tick_pitch_lfo (`if
	// (!block.enabled) return;`) matches FFT's behavior.
	block.enabled = (active_dir_flags & 0x1) != 0;
}

void FFTSpuCoreRuntime::set_lfo_tick_samples(int32_t samples) {
	lfo_tick_samples_ = std::max(1, samples);
}

void FFTSpuCoreRuntime::tick_pitch_lfo_all_voices() {
	fft_tick_pitch_lfo_all_voices(voices_);
}

void FFTSpuCoreRuntime::tick_volume_lfo_all_voices() {
	for (Voice &voice : voices_) {
		fft_tick_volume_lfo(voice.lfo_blocks[1]);
	}
}

void FFTSpuCoreRuntime::apply_volume_lfo_consumer_all_voices() {
	for (Voice &voice : voices_) {
		if (!voice.on) {
			continue;
		}
		if (!voice.lfo_blocks[1].enabled && !voice.lfo_blocks[2].enabled) {
			continue;
		}
		fft_apply_voice_volume_lfo_consumer(voice);
	}
}

bool FFTSpuCoreRuntime::advance_lfo_tick() {
	if (!fft_advance_lfo_tick_counter(lfo_tick_sample_counter_, lfo_tick_samples_)) {
		return false;
	}
	tick_pitch_lfo_all_voices();
	tick_volume_lfo_all_voices();
	apply_volume_lfo_consumer_all_voices();
	return true;
}

FFTSpuFrameRenderResult FFTSpuCoreRuntime::render_mix_frame(int32_t target_voice_idx) {
	// Apply pending sample-precise pitch updates BEFORE this frame's mix.
	// Empty in the immediate-pitch-write fast path; only callers using
	// set_voice_pitch_at populate queues.
	for (int32_t v = 0; v < kNumVoices; ++v) {
		tick_voice_pitch_queue(v);
	}
	FFTSpuFrameRenderResult frame_result;
	fft_render_mix_frame(voices_, lfo_pitch_bias_enabled_, kVolumeMax, kPitchToSincShift,
			kVolumeDivisor, spu_ram_.data(), kSpuRamSize, target_voice_idx, frame_mix_results_, frame_result,
			pitch_remap_);
	return frame_result;
}

void FFTSpuCoreRuntime::render_mix_batch(int32_t batch_size,
		int32_t target_voice_idx, FFTSpuBatchRenderResult &batch_result) {
	// PCSX-Redux ticks LFO state once per output sample (decoupled from
	// the per-voice mix loop). Default lfo_tick_samples (= 611) is >>
	// NSSIZE (= 45), so at most one LFO tick fires per batch on
	// cure_4-class sessions; the pre-advance here keeps total tick count
	// equal to a per-sample driver. Sample-precise LFO ordering inside a
	// batch is lost — acceptable per
	// CURE_4_V18_BATCHED_MIXER_REFACTOR_PLAN.md §4.4.
	for (int32_t ns = 0; ns < batch_size; ++ns) {
		advance_lfo_tick();
	}
	// Drain pending sample-precise pitch updates. tick_voice_pitch_queue
	// decrements offsets by 1 per call; do it batch_size times per voice
	// to match a per-sample driver's drain rate. No callers of
	// set_voice_pitch_at exist today, so this is functionally a no-op.
	for (int32_t v = 0; v < kNumVoices; ++v) {
		for (int32_t ns = 0; ns < batch_size; ++ns) {
			tick_voice_pitch_queue(v);
		}
	}
	fft_render_mix_batch(voices_, batch_size, lfo_pitch_bias_enabled_,
			kVolumeMax, kPitchToSincShift, kVolumeDivisor,
			spu_ram_.data(), kSpuRamSize, target_voice_idx, frame_mix_results_,
			batch_result, pitch_remap_);
}

std::vector<int16_t> FFTSpuCoreRuntime::render_interleaved_pcm16(int32_t frame_count) {
	std::vector<int16_t> output(static_cast<size_t>(std::max(0, frame_count)) * 2, 0);
	constexpr int32_t kBatchSize = FFTSpuBatchRenderResult::kMaxBatch;
	FFTSpuBatchRenderResult batch;
	int32_t frame = 0;
	while (frame < frame_count) {
		const int32_t batch_size = std::min(kBatchSize, frame_count - frame);
		render_mix_batch(batch_size, -1, batch);
		for (int32_t ns = 0; ns < batch_size; ++ns) {
			const std::array<int32_t, 2> reverb_out = mix_reverb(
					batch.rvb_in_l[ns], batch.rvb_in_r[ns], nullptr);
			output[static_cast<size_t>(frame + ns) * 2] = static_cast<int16_t>(
					std::clamp(batch.sum_l[ns] + reverb_out[0], -32767, 32767));
			output[static_cast<size_t>(frame + ns) * 2 + 1] = static_cast<int16_t>(
					std::clamp(batch.sum_r[ns] + reverb_out[1], -32767, 32767));
		}
		frame += batch_size;
	}

	return output;
}

int32_t FFTSpuCoreRuntime::active_voice_count() const {
	return fft_count_active_voices(voices_);
}

void FFTSpuCoreRuntime::set_reverb_enabled(bool enabled) {
	reverb_->set_enabled(enabled);
}

bool FFTSpuCoreRuntime::reverb_enabled() const {
	return reverb_->enabled();
}

void FFTSpuCoreRuntime::set_reverb_algorithm(FFTSpuReverbAlgorithm algorithm) {
	reverb_->set_algorithm(algorithm);
}

FFTSpuReverbAlgorithm FFTSpuCoreRuntime::reverb_algorithm() const {
	return reverb_->algorithm();
}

const char *FFTSpuCoreRuntime::reverb_algorithm_name() const {
	return reverb_->algorithm_name();
}

void FFTSpuCoreRuntime::set_reverb_buffer_start(int32_t addr) {
	reverb_->set_buffer_start(addr);
}

int32_t FFTSpuCoreRuntime::reverb_buffer_start() const {
	return reverb_->buffer_start();
}

void FFTSpuCoreRuntime::set_reverb_curr_addr(int32_t addr) {
	reverb_->set_curr_addr(addr);
}

int32_t FFTSpuCoreRuntime::reverb_curr_addr() const {
	return reverb_->curr_addr();
}

void FFTSpuCoreRuntime::reset_reverb_state() {
	reverb_->reset_state();
}

bool FFTSpuCoreRuntime::next_reverb_mix_odd_branch() const {
	return reverb_->next_mix_odd_branch();
}

std::array<int32_t, 2> FFTSpuCoreRuntime::mix_reverb(
		int32_t input_l, int32_t input_r, FFTSpuReverbDebugSnapshot *debug_snapshot) {
	return reverb_->mix(input_l, input_r, debug_snapshot);
}

}  // namespace fftshared
