#include "exmateria_psx_spu.h"
#include "fft_adsr_envelope.h"
#include "fft_spu_lfo_tools.h"
#include "fft_spu_reverb.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>

#include <godot_cpp/core/method_bind.hpp>

using namespace godot;

// Every runtime register write starts with this. In deferred mode the write is
// stamped with the scheduler's frame and queued instead of applied; the audio
// thread runs the identical core_ call at that frame in apply_deferred_command.
// Kept as a macro so each setter's prologue is one line and the deferred op can
// be read off next to the call it defers.
#define FFT_SPU_DEFER(op, ...)                                   \
	if (deferred_.load(std::memory_order_relaxed)) {             \
		push_deferred(exmateria::SpuCommandOp::op, __VA_ARGS__); \
		return;                                                  \
	}


ExMateriaPsxSpu::ExMateriaPsxSpu() {
	sampled_voice_trace_mask.fill(true);
	reset();
}

void ExMateriaPsxSpu::_bind_methods() {
	ClassDB::bind_method(D_METHOD("load_instruments", "instruments", "adpcm_bank"), &ExMateriaPsxSpu::load_instruments);
	ClassDB::bind_method(D_METHOD("reset"), &ExMateriaPsxSpu::reset);
	ClassDB::bind_method(D_METHOD("key_on", "voice_idx", "instrument_idx", "pitch", "vol_l", "vol_r", "adsr1", "adsr2", "reverb"), &ExMateriaPsxSpu::key_on);
	ClassDB::bind_method(D_METHOD("key_on_with_addresses", "voice_idx", "instrument_idx", "pitch", "vol_l", "vol_r", "adsr1",
				"adsr2", "start_addr", "loop_addr", "reverb"), &ExMateriaPsxSpu::key_on_with_addresses);
	ClassDB::bind_method(D_METHOD("key_off", "voice_idx"), &ExMateriaPsxSpu::key_off);
	ClassDB::bind_method(D_METHOD("seed_voice_residue", "voice_idx", "start_addr", "loop_addr", "curr_addr",
				"adsr1", "adsr2", "env_state", "env_vol",
				"vol_l", "vol_r", "raw_pitch", "reverb"),
			&ExMateriaPsxSpu::seed_voice_residue);
	ClassDB::bind_method(D_METHOD("set_voice_pitch", "voice_idx", "raw_pitch"), &ExMateriaPsxSpu::set_voice_pitch);
	ClassDB::bind_method(D_METHOD("set_voice_fmod", "voice_idx", "mode"), &ExMateriaPsxSpu::set_voice_fmod);
	ClassDB::bind_method(D_METHOD("set_voice_noise", "voice_idx", "on"), &ExMateriaPsxSpu::set_voice_noise);
	ClassDB::bind_method(D_METHOD("set_noise_clock", "noise_clock"), &ExMateriaPsxSpu::set_noise_clock);
	ClassDB::bind_method(D_METHOD("set_noise_state", "noise_val", "noise_clock", "noise_count"), &ExMateriaPsxSpu::set_noise_state);
	ClassDB::bind_method(D_METHOD("set_voice_pre_pitch", "voice_idx", "pre_pitch"), &ExMateriaPsxSpu::set_voice_pre_pitch);
	ClassDB::bind_method(D_METHOD("set_voice_adsr1_low", "voice_idx", "nibble"), &ExMateriaPsxSpu::set_voice_adsr1_low);
	ClassDB::bind_method(D_METHOD("set_voice_adsr2", "voice_idx", "adsr2"), &ExMateriaPsxSpu::set_voice_adsr2);
	ClassDB::bind_method(D_METHOD("init_voice_pitch_lfo", "voice_idx", "count", "signed_step", "rate_reload"),
			&ExMateriaPsxSpu::init_voice_pitch_lfo);
	ClassDB::bind_method(D_METHOD("clear_voice_pitch_lfo", "voice_idx"), &ExMateriaPsxSpu::clear_voice_pitch_lfo);
	ClassDB::bind_method(D_METHOD("set_voice_pitch_lfo_depth", "voice_idx", "depth", "depth_delta"),
			&ExMateriaPsxSpu::set_voice_pitch_lfo_depth);
	ClassDB::bind_method(D_METHOD("init_voice_volume_lfo", "voice_idx", "count", "signed_step", "rate_reload"),
			&ExMateriaPsxSpu::init_voice_volume_lfo);
	ClassDB::bind_method(D_METHOD("clear_voice_volume_lfo", "voice_idx"), &ExMateriaPsxSpu::clear_voice_volume_lfo);
	ClassDB::bind_method(D_METHOD("set_voice_lfo_subslot", "voice_idx", "subslot_idx",
			"accum", "step_current", "step_source",
			"countdown", "inner_reload",
			"depth", "depth_reload",
			"mode", "active_dir_flags"),
			&ExMateriaPsxSpu::set_voice_lfo_subslot);
	ClassDB::bind_method(D_METHOD("set_voice_volume_lfo_depth", "voice_idx", "depth", "depth_delta"),
			&ExMateriaPsxSpu::set_voice_volume_lfo_depth);
	ClassDB::bind_method(D_METHOD("set_lfo_tick_samples", "samples"),
			&ExMateriaPsxSpu::set_lfo_tick_samples);
	ClassDB::bind_method(D_METHOD("set_click_retrigger_fade_ms", "ms"),
			&ExMateriaPsxSpu::set_click_retrigger_fade_ms);
	ClassDB::bind_method(D_METHOD("get_click_retrigger_fade_ms"),
			&ExMateriaPsxSpu::get_click_retrigger_fade_ms);
	ClassDB::bind_method(D_METHOD("carry_voice_declick", "src_voice_idx", "dst_voice_idx"),
			&ExMateriaPsxSpu::carry_voice_declick);
	ClassDB::bind_method(D_METHOD("get_lfo_tick_samples"),
			&ExMateriaPsxSpu::get_lfo_tick_samples);
	ClassDB::bind_method(D_METHOD("set_lfo_pitch_bias_enabled", "enabled"),
			&ExMateriaPsxSpu::set_lfo_pitch_bias_enabled);
	ClassDB::bind_method(D_METHOD("is_lfo_pitch_bias_enabled"),
			&ExMateriaPsxSpu::is_lfo_pitch_bias_enabled);
	ClassDB::bind_method(D_METHOD("render_interleaved_pcm16", "frame_count"), &ExMateriaPsxSpu::render_interleaved_pcm16);
	ClassDB::bind_method(D_METHOD("render_voice_pcm16", "frame_count", "voice_idx"), &ExMateriaPsxSpu::render_voice_pcm16);
	ClassDB::bind_method(D_METHOD("render_replay_mix_frames", "frame_count", "per_voice_samples", "per_voice_events",
								  "ground_truth_rvb_input"),
			&ExMateriaPsxSpu::render_replay_mix_frames);
	ClassDB::bind_method(D_METHOD("set_reverb_debug_enabled", "enabled"), &ExMateriaPsxSpu::set_reverb_debug_enabled);
	ClassDB::bind_method(D_METHOD("set_reverb_debug_path", "path"), &ExMateriaPsxSpu::set_reverb_debug_path);
	ClassDB::bind_method(D_METHOD("render_frames", "frame_count"), &ExMateriaPsxSpu::render_frames);
	ClassDB::bind_method(D_METHOD("get_active_voice_count"), &ExMateriaPsxSpu::get_active_voice_count);
	ClassDB::bind_method(D_METHOD("get_debug_stats"), &ExMateriaPsxSpu::get_debug_stats);
	ClassDB::bind_method(D_METHOD("get_voice_debug_info", "voice_idx"), &ExMateriaPsxSpu::get_voice_debug_info);
	ClassDB::bind_method(D_METHOD("set_sampled_voice_trace_enabled", "enabled"), &ExMateriaPsxSpu::set_sampled_voice_trace_enabled);
	ClassDB::bind_method(D_METHOD("is_sampled_voice_trace_enabled"), &ExMateriaPsxSpu::is_sampled_voice_trace_enabled);
	ClassDB::bind_method(D_METHOD("set_sampled_voice_trace_dense", "enabled"), &ExMateriaPsxSpu::set_sampled_voice_trace_dense);
	ClassDB::bind_method(D_METHOD("is_sampled_voice_trace_dense"), &ExMateriaPsxSpu::is_sampled_voice_trace_dense);
	ClassDB::bind_method(D_METHOD("set_sampled_voice_trace_voices", "voice_indices"), &ExMateriaPsxSpu::set_sampled_voice_trace_voices);
	ClassDB::bind_method(D_METHOD("clear_sampled_voice_trace"), &ExMateriaPsxSpu::clear_sampled_voice_trace);
	ClassDB::bind_method(D_METHOD("get_sampled_voice_trace"), &ExMateriaPsxSpu::get_sampled_voice_trace);
	ClassDB::bind_method(D_METHOD("set_reverb_enabled", "enabled"), &ExMateriaPsxSpu::set_reverb_enabled);
	ClassDB::bind_method(D_METHOD("is_reverb_enabled"), &ExMateriaPsxSpu::is_reverb_enabled);
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "reverb_enabled"), "set_reverb_enabled", "is_reverb_enabled");
	ClassDB::bind_method(D_METHOD("set_reverb_algorithm", "algorithm"), &ExMateriaPsxSpu::set_reverb_algorithm);
	ClassDB::bind_method(D_METHOD("get_reverb_algorithm"), &ExMateriaPsxSpu::get_reverb_algorithm);
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "reverb_algorithm"), "set_reverb_algorithm", "get_reverb_algorithm");
	ClassDB::bind_method(D_METHOD("set_reverb_buffer_start", "addr"), &ExMateriaPsxSpu::set_reverb_buffer_start);
	ClassDB::bind_method(D_METHOD("get_reverb_buffer_start"), &ExMateriaPsxSpu::get_reverb_buffer_start);
	ClassDB::bind_method(D_METHOD("set_reverb_curr_addr", "addr"), &ExMateriaPsxSpu::set_reverb_curr_addr);
	ClassDB::bind_method(D_METHOD("get_reverb_curr_addr"), &ExMateriaPsxSpu::get_reverb_curr_addr);
	ClassDB::bind_method(D_METHOD("set_irq_period_samples", "n"), &ExMateriaPsxSpu::set_irq_period_samples);
	ClassDB::bind_method(D_METHOD("drain_irq_passes"), &ExMateriaPsxSpu::drain_irq_passes);
	// Walker bit-window setters (RMW on cached adsr1/adsr2/volumes).
	ClassDB::bind_method(D_METHOD("set_voice_volume_lr", "voice_idx", "vol_l", "vol_r"), &ExMateriaPsxSpu::set_voice_volume_lr);
	ClassDB::bind_method(D_METHOD("set_voice_volume_lr_with_mode", "voice_idx", "vol_l", "vol_r", "mode_l", "mode_r"), &ExMateriaPsxSpu::set_voice_volume_lr_with_mode);
	ClassDB::bind_method(D_METHOD("set_voice_adsr1_high", "voice_idx", "attack_rate", "lin_or_exp_mode"), &ExMateriaPsxSpu::set_voice_adsr1_high);
	ClassDB::bind_method(D_METHOD("set_voice_adsr1_mid", "voice_idx", "mid_nibble"), &ExMateriaPsxSpu::set_voice_adsr1_mid);
	ClassDB::bind_method(D_METHOD("set_voice_adsr2_low", "voice_idx", "low_bits", "mode"), &ExMateriaPsxSpu::set_voice_adsr2_low);
	// Walker bit 0x008 SAMPLE_ADDR fan-out setters.
	ClassDB::bind_method(D_METHOD("set_voice_start_addr", "voice_idx", "start_addr"), &ExMateriaPsxSpu::set_voice_start_addr);
	ClassDB::bind_method(D_METHOD("set_voice_repeat_addr", "voice_idx", "repeat_addr"), &ExMateriaPsxSpu::set_voice_repeat_addr);
	ClassDB::bind_method(D_METHOD("get_irq_pass_counter"), &ExMateriaPsxSpu::get_irq_pass_counter);
	ClassDB::bind_method(D_METHOD("reset_rail_metrics"), &ExMateriaPsxSpu::reset_rail_metrics);
	// Deferred (audio-thread) mode — D3 decisions 1-3 (#376).
	ClassDB::bind_method(D_METHOD("set_deferred_mode", "enabled", "queue_capacity"), &ExMateriaPsxSpu::set_deferred_mode);
	ClassDB::bind_method(D_METHOD("is_deferred_mode"), &ExMateriaPsxSpu::is_deferred_mode);
	ClassDB::bind_method(D_METHOD("clear_deferred_commands"), &ExMateriaPsxSpu::clear_deferred_commands);
	ClassDB::bind_method(D_METHOD("set_schedule_frame", "frame"), &ExMateriaPsxSpu::set_schedule_frame);
	ClassDB::bind_method(D_METHOD("get_schedule_frame"), &ExMateriaPsxSpu::get_schedule_frame);
	ClassDB::bind_method(D_METHOD("get_audio_frame"), &ExMateriaPsxSpu::get_audio_frame);
	ClassDB::bind_method(D_METHOD("set_stream_idle", "idle"), &ExMateriaPsxSpu::set_stream_idle);
	ClassDB::bind_method(D_METHOD("is_stream_idle"), &ExMateriaPsxSpu::is_stream_idle);
	ClassDB::bind_method(D_METHOD("reset_deferred_stats"), &ExMateriaPsxSpu::reset_deferred_stats);
	ClassDB::bind_method(D_METHOD("get_audio_active_voices"), &ExMateriaPsxSpu::get_audio_active_voices);
	ClassDB::bind_method(D_METHOD("get_deferred_free_slots"), &ExMateriaPsxSpu::get_deferred_free_slots);
	ClassDB::bind_method(D_METHOD("get_deferred_stats"), &ExMateriaPsxSpu::get_deferred_stats);
	ClassDB::bind_method(D_METHOD("render_deferred_pcm16", "frame_count"), &ExMateriaPsxSpu::render_deferred_pcm16);
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "sampled_voice_trace_enabled"), "set_sampled_voice_trace_enabled", "is_sampled_voice_trace_enabled");
}

int ExMateriaPsxSpu::clip_pcm16(int value) {
	return std::clamp(value, CLIP_PCM16_MIN, CLIP_PCM16_MAX);
}

void ExMateriaPsxSpu::reset_reverb_state() {
	core_.reset_reverb_state();
}

bool ExMateriaPsxSpu::load_instruments(const Array &p_instruments, const PackedByteArray &p_adpcm_bank) {
	std::vector<InstrumentData> instruments;
	instruments.reserve(p_instruments.size());

	for (int i = 0; i < p_instruments.size(); i++) {
		Dictionary dict = p_instruments[i];
		InstrumentData inst;
		inst.is_null = dict.has("is_null") ? bool(dict["is_null"]) : true;
		inst.fine_tune = dict.has("fine_tune") ? int(dict["fine_tune"]) : 0;
		inst.adsr1 = dict.has("adsr1") ? int(dict["adsr1"]) : 0;
		inst.adsr2 = dict.has("adsr2") ? int(dict["adsr2"]) : 0;
		inst.sample_offset = dict.has("sample_offset") ? int(dict["sample_offset"]) : 0;
		inst.sample_size = dict.has("sample_size") ? int(dict["sample_size"]) : 0;
		inst.loop_start = dict.has("loop_start") ? int(dict["loop_start"]) : -1;
		inst.loop_offset_bytes = dict.has("loop_offset_bytes") ? int(dict["loop_offset_bytes"]) : -1;
		inst.has_explicit_loop_start = dict.has("has_explicit_loop_start") ? bool(dict["has_explicit_loop_start"]) : false;
		inst.has_loop_repeat = dict.has("has_loop_repeat") ? bool(dict["has_loop_repeat"]) : false;
		inst.start_offset_bytes = dict.has("start_offset_bytes") ? int(dict["start_offset_bytes"]) : 0;
		instruments.push_back(std::move(inst));
	}

	return core_.load_instruments(instruments, p_adpcm_bank.ptr(), p_adpcm_bank.size());
}

void ExMateriaPsxSpu::reset() {
	core_.reset();
	last_render_ms = 0.0;
	max_render_ms = 0.0;
	rendered_sample_count = 0;
	irq_sample_counter_ = 0;
	irq_pass_counter_ = 0;
	pending_irq_passes_ = 0;
	reset_rail_metrics();
	clear_sampled_voice_trace_internal();
}

void ExMateriaPsxSpu::reset_rail_metrics() {
	rail_pre_clamp_peak_ = 0;
	rail_hit_count_ = 0;
	rail_sample_count_ = 0;
}

void ExMateriaPsxSpu::accumulate_rail_metrics(int raw_l, int raw_r) {
	// Pre-clamp magnitude + rail-hit accounting for one output frame. Peak is the
	// larger channel's absolute value BEFORE clip_pcm16, so it can exceed 32767
	// (that overshoot is exactly the "dynamics too hot" number). A hit is any
	// channel the clamp actually cut.
	++rail_sample_count_;
	const int mag_l = raw_l < 0 ? -raw_l : raw_l;
	const int mag_r = raw_r < 0 ? -raw_r : raw_r;
	const int mag = mag_l > mag_r ? mag_l : mag_r;
	if (mag > rail_pre_clamp_peak_) {
		rail_pre_clamp_peak_ = mag;
	}
	if (raw_l < CLIP_PCM16_MIN || raw_l > CLIP_PCM16_MAX
			|| raw_r < CLIP_PCM16_MIN || raw_r > CLIP_PCM16_MAX) {
		++rail_hit_count_;
	}
}

void ExMateriaPsxSpu::set_irq_period_samples(int n) {
	if (n < 64) n = 64;
	if (n > 8192) n = 8192;
	irq_period_samples_ = n;
}

int ExMateriaPsxSpu::drain_irq_passes() {
	int n = pending_irq_passes_;
	pending_irq_passes_ = 0;
	return n;
}

void ExMateriaPsxSpu::set_click_retrigger_fade_ms(double ms) {
	if (ms < 0.0) {
		ms = 0.0;
	}
	// ms → output samples at the SPU render rate (round to nearest).
	const int samples = static_cast<int>(ms * SAMPLE_RATE / 1000.0 + 0.5);
	core_.set_click_retrigger_fade_samples(samples);
}

double ExMateriaPsxSpu::get_click_retrigger_fade_ms() const {
	return static_cast<double>(core_.click_retrigger_fade_samples()) * 1000.0 / SAMPLE_RATE;
}

void ExMateriaPsxSpu::carry_voice_declick(int src_voice_idx, int dst_voice_idx) {
	FFT_SPU_DEFER(CARRY_VOICE_DECLICK, src_voice_idx, dst_voice_idx);
	core_.carry_voice_declick(src_voice_idx, dst_voice_idx);
}

void ExMateriaPsxSpu::key_on(int voice_idx, int instrument_idx, int pitch, int vol_l, int vol_r, int adsr1, int adsr2, bool p_reverb) {
	FFT_SPU_DEFER(KEY_ON, voice_idx, instrument_idx, pitch, vol_l, vol_r, adsr1, adsr2, p_reverb ? 1 : 0);
	core_.key_on(voice_idx, instrument_idx, pitch, vol_l, vol_r, adsr1, adsr2, p_reverb);
}

void ExMateriaPsxSpu::key_on_with_addresses(int voice_idx, int instrument_idx, int pitch, int vol_l, int vol_r, int adsr1,
		int adsr2, int start_addr, int loop_addr, bool p_reverb) {
	FFT_SPU_DEFER(KEY_ON_WITH_ADDRESSES, voice_idx, instrument_idx, pitch, vol_l, vol_r, adsr1, adsr2, start_addr, loop_addr, p_reverb ? 1 : 0);
	core_.key_on_with_addresses(voice_idx, instrument_idx, pitch, vol_l, vol_r, adsr1, adsr2, start_addr, loop_addr, p_reverb);
}

void ExMateriaPsxSpu::key_off(int voice_idx) {
	FFT_SPU_DEFER(KEY_OFF, voice_idx);
	core_.key_off(voice_idx);
}

void ExMateriaPsxSpu::seed_voice_residue(int voice_idx, int start_addr, int loop_addr, int curr_addr,
		int adsr1, int adsr2, int env_state, int env_vol,
		int vol_l, int vol_r, int raw_pitch, bool reverb) {
	core_.seed_voice_residue(voice_idx, start_addr, loop_addr, curr_addr, adsr1, adsr2,
			env_state, env_vol, vol_l, vol_r, raw_pitch, reverb);
}

void ExMateriaPsxSpu::set_voice_pitch(int voice_idx, int raw_pitch) {
	FFT_SPU_DEFER(SET_VOICE_PITCH, voice_idx, raw_pitch);
	core_.set_voice_pitch(voice_idx, raw_pitch);
}

void ExMateriaPsxSpu::set_voice_fmod(int voice_idx, int mode) {
	FFT_SPU_DEFER(SET_VOICE_FMOD, voice_idx, mode);
	core_.set_voice_fmod(voice_idx, mode);
}

void ExMateriaPsxSpu::set_voice_noise(int voice_idx, bool on) {
	FFT_SPU_DEFER(SET_VOICE_NOISE, voice_idx, on ? 1 : 0);
	core_.set_voice_noise(voice_idx, on);
}

void ExMateriaPsxSpu::set_noise_clock(int noise_clock) {
	FFT_SPU_DEFER(SET_NOISE_CLOCK, noise_clock);
	core_.set_noise_clock(noise_clock);
}

void ExMateriaPsxSpu::set_noise_state(int noise_val, int noise_clock,
		int noise_count) {
	core_.set_noise_state(static_cast<uint32_t>(noise_val),
			static_cast<uint32_t>(noise_clock), static_cast<uint32_t>(noise_count));
}

void ExMateriaPsxSpu::set_voice_pre_pitch(int voice_idx, int pre_pitch) {
	FFT_SPU_DEFER(SET_VOICE_PRE_PITCH, voice_idx, pre_pitch);
	core_.set_voice_pre_pitch(voice_idx, pre_pitch);
}

void ExMateriaPsxSpu::set_voice_adsr1_low(int voice_idx, int nibble) {
	FFT_SPU_DEFER(SET_VOICE_ADSR1_LOW, voice_idx, nibble);
	core_.set_voice_adsr1_low(voice_idx, nibble);
}

void ExMateriaPsxSpu::set_voice_adsr2(int voice_idx, int adsr2) {
	FFT_SPU_DEFER(SET_VOICE_ADSR2, voice_idx, adsr2);
	core_.set_voice_adsr2(voice_idx, adsr2);
}

// Walker bit-window setters. Thin wrappers over core_.
void ExMateriaPsxSpu::set_voice_volume_lr(int voice_idx, int vol_l, int vol_r) {
	FFT_SPU_DEFER(SET_VOICE_VOLUME_LR, voice_idx, vol_l, vol_r);
	core_.set_voice_volume_lr(voice_idx, vol_l, vol_r);
}

void ExMateriaPsxSpu::set_voice_volume_lr_with_mode(int voice_idx, int vol_l, int vol_r,
		int mode_l, int mode_r) {
	FFT_SPU_DEFER(SET_VOICE_VOLUME_LR_WITH_MODE, voice_idx, vol_l, vol_r, mode_l, mode_r);
	core_.set_voice_volume_lr_with_mode(voice_idx, vol_l, vol_r, mode_l, mode_r);
}

void ExMateriaPsxSpu::set_voice_adsr1_high(int voice_idx, int attack_rate, int lin_or_exp_mode) {
	FFT_SPU_DEFER(SET_VOICE_ADSR1_HIGH, voice_idx, attack_rate, lin_or_exp_mode);
	core_.set_voice_adsr1_high(voice_idx, attack_rate, lin_or_exp_mode);
}

void ExMateriaPsxSpu::set_voice_adsr1_mid(int voice_idx, int mid_nibble) {
	FFT_SPU_DEFER(SET_VOICE_ADSR1_MID, voice_idx, mid_nibble);
	core_.set_voice_adsr1_mid(voice_idx, mid_nibble);
}

void ExMateriaPsxSpu::set_voice_adsr2_low(int voice_idx, int low_bits, int mode) {
	FFT_SPU_DEFER(SET_VOICE_ADSR2_LOW, voice_idx, low_bits, mode);
	core_.set_voice_adsr2_low(voice_idx, low_bits, mode);
}

// Walker bit 0x008 SAMPLE_ADDR fan-out setters.
void ExMateriaPsxSpu::set_voice_start_addr(int voice_idx, int start_addr) {
	FFT_SPU_DEFER(SET_VOICE_START_ADDR, voice_idx, start_addr);
	core_.set_voice_start_addr(voice_idx, start_addr);
}

void ExMateriaPsxSpu::set_voice_repeat_addr(int voice_idx, int repeat_addr) {
	FFT_SPU_DEFER(SET_VOICE_REPEAT_ADDR, voice_idx, repeat_addr);
	core_.set_voice_repeat_addr(voice_idx, repeat_addr);
}

// Populate pitch LFO block (index 0). Mirrors FFT 0xD8 dispatch
// (LAB_80016420) + its tail call to FUN_80016dc0:
//   block+0x0c (base_step)  = (signed_step * |signed_step|) << 14 then
//                             divided by count×3 via FUN_80016bf8;
//                             for now we store the raw step — the
//                             frame-tick iter will decide whether to
//                             pre-divide or divide at consumption time.
//   block+0x12 (reload)     = count
//   block+0x10 (counter)    = 1 (initialized by FUN_80016dc0)
//   block+0x04 (accum)      = 0 (zeroed by FUN_80016dc0)
//   block+0x18 (depth)      = 0x100 (FFT default; overwritten by 0xD7 or
//                             FUN_80016dc0 copy from block+0x1a)
//   block+0x16 (rate_reload)= param[2] (byte at opcode_arg+2)
//   block+0x14 (rate_div)   = rate_reload (via FUN_80016dc0 copy)
//   block+0x1c (mode)       = 0 (pitch)
//   block+0x1e (flags)      = 3 (bits 0+1 set; bit 0 = enabled)
void ExMateriaPsxSpu::init_voice_pitch_lfo(int voice_idx, int count, int signed_step, int rate_reload) {
	FFT_SPU_DEFER(INIT_VOICE_PITCH_LFO, voice_idx, count, signed_step, rate_reload);
	core_.init_voice_pitch_lfo(voice_idx, count, signed_step, rate_reload);
}

void ExMateriaPsxSpu::clear_voice_pitch_lfo(int voice_idx) {
	FFT_SPU_DEFER(CLEAR_VOICE_PITCH_LFO, voice_idx);
	core_.clear_voice_pitch_lfo(voice_idx);
}

// FFT 0xD7 (LAB_800165ac): writes 0x100/(param+1) into ch+0xf8 (depth)
// AND ch+0xfa (depth_delta). If param == 0xff, skips.
void ExMateriaPsxSpu::set_voice_pitch_lfo_depth(int voice_idx, int depth, int depth_delta) {
	FFT_SPU_DEFER(SET_VOICE_PITCH_LFO_DEPTH, voice_idx, depth, depth_delta);
	core_.set_voice_pitch_lfo_depth(voice_idx, depth, depth_delta);
}

void ExMateriaPsxSpu::init_voice_volume_lfo(int voice_idx, int count, int signed_step, int rate_reload) {
	FFT_SPU_DEFER(INIT_VOICE_VOLUME_LFO, voice_idx, count, signed_step, rate_reload);
	core_.init_voice_volume_lfo(voice_idx, count, signed_step, rate_reload);
}

void ExMateriaPsxSpu::clear_voice_volume_lfo(int voice_idx) {
	FFT_SPU_DEFER(CLEAR_VOICE_VOLUME_LFO, voice_idx);
	core_.clear_voice_volume_lfo(voice_idx);
}

void ExMateriaPsxSpu::set_voice_volume_lfo_depth(int voice_idx, int depth, int depth_delta) {
	FFT_SPU_DEFER(SET_VOICE_VOLUME_LFO_DEPTH, voice_idx, depth, depth_delta);
	core_.set_voice_volume_lfo_depth(voice_idx, depth, depth_delta);
}

void ExMateriaPsxSpu::set_voice_lfo_subslot(int voice_idx, int subslot_idx,
		int accum, int step_current, int step_source,
		int countdown, int inner_reload,
		int depth, int depth_reload,
		int mode, int active_dir_flags) {
	core_.set_voice_lfo_subslot(voice_idx, subslot_idx,
			accum, step_current, step_source,
			countdown, inner_reload,
			depth, depth_reload,
			mode, active_dir_flags);
}

void ExMateriaPsxSpu::set_lfo_tick_samples(int samples) {
	FFT_SPU_DEFER(SET_LFO_TICK_SAMPLES, samples);
	core_.set_lfo_tick_samples(samples);
}

int ExMateriaPsxSpu::get_active_voice_count_internal() const {
	return core_.active_voice_count();
}

std::array<int, 2> ExMateriaPsxSpu::mix_reverb(int input_l, int input_r) {
	fftshared::FFTSpuReverbDebugSnapshot debug_snapshot;
	fftshared::FFTSpuReverbDebugSnapshot *debug_ptr = (rvb_debug_enabled && rvb_debug_file != nullptr) ? &debug_snapshot : nullptr;
	const std::array<int32_t, 2> out = core_.mix_reverb(input_l, input_r, debug_ptr);
	if (debug_ptr != nullptr && debug_snapshot.valid) {
		rvb_debug_iter_count++;
		std::fprintf(rvb_debug_file,
			"{\"iter\":%u,\"in_l\":%d,\"in_r\":%d,\"curr_addr\":%d,"
			"\"iir_in_a0\":%d,\"iir_in_a1\":%d,\"iir_in_b0\":%d,\"iir_in_b1\":%d,"
			"\"iir_a0\":%d,\"iir_a1\":%d,\"iir_b0\":%d,\"iir_b1\":%d,"
			"\"acc0\":%d,\"acc1\":%d,"
			"\"fb_a0\":%d,\"fb_a1\":%d,\"fb_b0\":%d,\"fb_b1\":%d,"
			"\"mix_a0\":%d,\"mix_a1\":%d,\"mix_b0\":%d,\"mix_b1\":%d,"
			"\"rvb_l\":%d,\"rvb_r\":%d,\"last_rvb_l\":%d,\"last_rvb_r\":%d,"
			"\"out_l\":%d,\"out_r\":%d}\n",
			rvb_debug_iter_count,
			input_l, input_r, debug_snapshot.curr_addr,
			debug_snapshot.iir_input_a0, debug_snapshot.iir_input_a1, debug_snapshot.iir_input_b0, debug_snapshot.iir_input_b1,
			debug_snapshot.iir_a0, debug_snapshot.iir_a1, debug_snapshot.iir_b0, debug_snapshot.iir_b1,
			debug_snapshot.acc0, debug_snapshot.acc1,
			debug_snapshot.fb_a0, debug_snapshot.fb_a1, debug_snapshot.fb_b0, debug_snapshot.fb_b1,
			debug_snapshot.mix_a0, debug_snapshot.mix_a1, debug_snapshot.mix_b0, debug_snapshot.mix_b1,
			debug_snapshot.rvb_l, debug_snapshot.rvb_r, debug_snapshot.last_rvb_l, debug_snapshot.last_rvb_r,
			debug_snapshot.out_l, debug_snapshot.out_r);
	}
	return { static_cast<int>(out[0]), static_cast<int>(out[1]) };
}

void ExMateriaPsxSpu::update_render_timing(double elapsed_ms) {
	last_render_ms = elapsed_ms;
	if (elapsed_ms > max_render_ms) {
		max_render_ms = elapsed_ms;
	}
}

void ExMateriaPsxSpu::clear_sampled_voice_trace_internal() {
	sampled_voice_trace.clear();
	for (SampleTraceState &state : sampled_voice_prev) {
		state = SampleTraceState();
	}
}

bool ExMateriaPsxSpu::should_trace_voice_event(int voice_idx) const {
	return sampled_voice_trace_enabled && voice_idx >= 0 && voice_idx < NUM_VOICES && sampled_voice_trace_mask[voice_idx];
}

ExMateriaPsxSpu::SampleTraceState ExMateriaPsxSpu::build_sample_trace_state(
		const Voice &voice, int env_vol, int sample) const {
	SampleTraceState next;
	next.valid = true;
	next.on = voice.on;
	next.stop = voice.stop_requested;
	next.raw_pitch = voice.raw_pitch;
	next.left_volume = voice.left_volume;
	next.right_volume = voice.right_volume;
	next.start_addr = voice.start_addr;
	next.loop_addr = voice.loop_addr;
	next.curr_addr = voice.curr_addr;
	next.env_state = static_cast<int>(voice.adsr.state);
	next.env_vol = env_vol;
	next.sample = sample;
	next.decoded_sample = voice.latest_sample;
	next.interp_sample = voice.latest_interp_sample;
	next.fmod = voice.fmod;
	return next;
}

bool ExMateriaPsxSpu::sample_trace_changed(int voice_idx, const SampleTraceState &next) const {
	const SampleTraceState &prev = sampled_voice_prev[voice_idx];
	return !prev.valid ||
		prev.on != next.on ||
		prev.stop != next.stop ||
		prev.raw_pitch != next.raw_pitch ||
		prev.left_volume != next.left_volume ||
		prev.right_volume != next.right_volume ||
		prev.start_addr != next.start_addr ||
		prev.loop_addr != next.loop_addr ||
		prev.curr_addr != next.curr_addr ||
		prev.env_state != next.env_state ||
		prev.env_vol != next.env_vol ||
		prev.sample != next.sample ||
		prev.decoded_sample != next.decoded_sample ||
		prev.interp_sample != next.interp_sample ||
		prev.fmod != next.fmod;
}

Dictionary ExMateriaPsxSpu::build_sample_trace_row(
		int voice_idx, uint64_t sample_index, const Voice &voice, const SampleTraceState &next) const {
	Dictionary row;
	row["kind"] = "voice_event";
	row["voice"] = voice_idx;
	row["sample_index"] = static_cast<int64_t>(sample_index);
	row["on"] = next.on;
	row["stop"] = next.stop;
	row["raw_pitch"] = next.raw_pitch;
	row["left_volume"] = next.left_volume;
	row["right_volume"] = next.right_volume;
	row["start_addr"] = next.start_addr;
	row["loop_addr"] = next.loop_addr;
	row["curr_addr"] = next.curr_addr;
	row["env_state"] = next.env_state;
	row["env_vol"] = next.env_vol;
	// Emit raw ADSR register values so the trace verifies Godot's runtime
	// adsr2 directly rather than inferring it from external tools.
	row["adsr1"] = voice.adsr1;
	row["adsr2"] = voice.adsr2;
	row["sample"] = next.sample;
	row["decoded_sample"] = next.decoded_sample;
	row["interp_sample"] = next.interp_sample;
	row["fmod"] = next.fmod;
	row["buf_pos"] = voice.buf_pos;
	row["spos"] = voice.spos;
	row["gauss_pos"] = voice.gauss_pos;
	row["adpcm_s1"] = voice.adpcm_s1;
	// Pitch-LFO block 0 state — for calibration debugging against the
	// PCSX raw_pitch trajectory. Only meaningful on dense-trace runs
	// with the LFO rail active.
	row["lfo0_accum"] = voice.lfo_blocks[0].accum;
	row["lfo0_step"] = voice.lfo_blocks[0].step;
	row["lfo0_counter"] = voice.lfo_blocks[0].counter;
	row["lfo0_depth"] = voice.lfo_blocks[0].depth;
	row["lfo0_scaled_output"] = voice.lfo_blocks[0].scaled_output;
	row["lfo0_flags"] = static_cast<int>(voice.lfo_blocks[0].flags);
	row["lfo1_accum"] = voice.lfo_blocks[1].accum;
	row["lfo1_step"] = voice.lfo_blocks[1].step;
	row["lfo1_counter"] = voice.lfo_blocks[1].counter;
	row["lfo1_depth"] = voice.lfo_blocks[1].depth;
	row["lfo1_scaled_output"] = voice.lfo_blocks[1].scaled_output;
	row["lfo1_consumer_output"] = voice.lfo_blocks[1].consumer_output;
	row["lfo1_flags"] = static_cast<int>(voice.lfo_blocks[1].flags);
	row["adpcm_s2"] = voice.adpcm_s2;
	return row;
}

void ExMateriaPsxSpu::trace_voice_event(int voice_idx, uint64_t sample_index, const Voice &voice, int env_vol, int sample) {
	if (!should_trace_voice_event(voice_idx)) {
		return;
	}

	const SampleTraceState next = build_sample_trace_state(voice, env_vol, sample);

	if (!sampled_voice_trace_dense && !sample_trace_changed(voice_idx, next)) {
		return;
	}

	sampled_voice_trace.push_back(build_sample_trace_row(voice_idx, sample_index, voice, next));
	sampled_voice_prev[voice_idx] = next;
}

void ExMateriaPsxSpu::trace_inactive_voices(uint64_t sample_index) {
	if (!sampled_voice_trace_enabled) {
		return;
	}
	for (int voice_idx = 0; voice_idx < NUM_VOICES; ++voice_idx) {
		const Voice &voice = core_.voices()[voice_idx];
		if (voice.on) {
			continue;
		}
		trace_voice_event(voice_idx, sample_index, voice, 0, 0);
	}
}

void ExMateriaPsxSpu::apply_deferred_command(const exmateria::SpuCommand &p_cmd) {
	// Audio thread. Calls core_ directly rather than re-entering the public
	// setters, so the deferral prologue can never fire from this thread.
	const int32_t *a = p_cmd.args;
	switch (p_cmd.op) {
		case exmateria::SpuCommandOp::KEY_ON:
			core_.key_on(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7] != 0);
			break;
		case exmateria::SpuCommandOp::KEY_ON_WITH_ADDRESSES:
			core_.key_on_with_addresses(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9] != 0);
			break;
		case exmateria::SpuCommandOp::KEY_OFF:
			core_.key_off(a[0]);
			break;
		case exmateria::SpuCommandOp::SET_VOICE_PITCH:
			core_.set_voice_pitch(a[0], a[1]);
			break;
		case exmateria::SpuCommandOp::SET_VOICE_FMOD:
			core_.set_voice_fmod(a[0], a[1]);
			break;
		case exmateria::SpuCommandOp::SET_VOICE_NOISE:
			core_.set_voice_noise(a[0], a[1] != 0);
			break;
		case exmateria::SpuCommandOp::SET_NOISE_CLOCK:
			core_.set_noise_clock(a[0]);
			break;
		case exmateria::SpuCommandOp::SET_VOICE_PRE_PITCH:
			core_.set_voice_pre_pitch(a[0], a[1]);
			break;
		case exmateria::SpuCommandOp::SET_VOICE_ADSR1_LOW:
			core_.set_voice_adsr1_low(a[0], a[1]);
			break;
		case exmateria::SpuCommandOp::SET_VOICE_ADSR2:
			core_.set_voice_adsr2(a[0], a[1]);
			break;
		case exmateria::SpuCommandOp::SET_VOICE_VOLUME_LR:
			core_.set_voice_volume_lr(a[0], a[1], a[2]);
			break;
		case exmateria::SpuCommandOp::SET_VOICE_VOLUME_LR_WITH_MODE:
			core_.set_voice_volume_lr_with_mode(a[0], a[1], a[2], a[3], a[4]);
			break;
		case exmateria::SpuCommandOp::SET_VOICE_ADSR1_HIGH:
			core_.set_voice_adsr1_high(a[0], a[1], a[2]);
			break;
		case exmateria::SpuCommandOp::SET_VOICE_ADSR1_MID:
			core_.set_voice_adsr1_mid(a[0], a[1]);
			break;
		case exmateria::SpuCommandOp::SET_VOICE_ADSR2_LOW:
			core_.set_voice_adsr2_low(a[0], a[1], a[2]);
			break;
		case exmateria::SpuCommandOp::SET_VOICE_START_ADDR:
			core_.set_voice_start_addr(a[0], a[1]);
			break;
		case exmateria::SpuCommandOp::SET_VOICE_REPEAT_ADDR:
			core_.set_voice_repeat_addr(a[0], a[1]);
			break;
		case exmateria::SpuCommandOp::INIT_VOICE_PITCH_LFO:
			core_.init_voice_pitch_lfo(a[0], a[1], a[2], a[3]);
			break;
		case exmateria::SpuCommandOp::CLEAR_VOICE_PITCH_LFO:
			core_.clear_voice_pitch_lfo(a[0]);
			break;
		case exmateria::SpuCommandOp::SET_VOICE_PITCH_LFO_DEPTH:
			core_.set_voice_pitch_lfo_depth(a[0], a[1], a[2]);
			break;
		case exmateria::SpuCommandOp::INIT_VOICE_VOLUME_LFO:
			core_.init_voice_volume_lfo(a[0], a[1], a[2], a[3]);
			break;
		case exmateria::SpuCommandOp::CLEAR_VOICE_VOLUME_LFO:
			core_.clear_voice_volume_lfo(a[0]);
			break;
		case exmateria::SpuCommandOp::SET_VOICE_VOLUME_LFO_DEPTH:
			core_.set_voice_volume_lfo_depth(a[0], a[1], a[2]);
			break;
		case exmateria::SpuCommandOp::SET_REVERB_ENABLED:
			core_.set_reverb_enabled(a[0] != 0);
			break;
		case exmateria::SpuCommandOp::SET_LFO_TICK_SAMPLES:
			core_.set_lfo_tick_samples(a[0]);
			break;
		case exmateria::SpuCommandOp::SET_LFO_PITCH_BIAS_ENABLED:
			core_.set_lfo_pitch_bias_enabled(a[0] != 0);
			break;
		case exmateria::SpuCommandOp::CARRY_VOICE_DECLICK:
			core_.carry_voice_declick(a[0], a[1]);
			break;
	}
}

void ExMateriaPsxSpu::set_deferred_mode(bool enabled, int queue_capacity) {
	if (enabled) {
		if (deferred_queue_.capacity() < queue_capacity) {
			deferred_queue_.set_capacity(queue_capacity);
		}
		// Pre-size the audio thread's staging generously (the resampler asks in
		// 128-frame blocks) so render_audio_frames never allocates.
		if (audio_scratch_.size() < 8192) {
			audio_scratch_.assign(8192, 0);
		}
		// Arming a stream always starts it SOUNDING; an idle claim is the engine's
		// to re-assert per unit after it takes the SPU back.
		stream_idle_.store(false, std::memory_order_release);
		audio_was_idle_ = false;
	}
	clear_deferred_commands();
	deferred_.store(enabled, std::memory_order_release);
}

void ExMateriaPsxSpu::clear_deferred_commands() {
	deferred_queue_.clear();
	carry_len_ = 0;
	carry_pos_ = 0;
	schedule_frame_ = 0;
	audio_frame_.store(0, std::memory_order_release);
	audio_active_voices_.store(0, std::memory_order_relaxed);
	audio_overdue_commands_.store(0, std::memory_order_relaxed);
}

void ExMateriaPsxSpu::reset_deferred_stats() {
	deferred_queue_.reset_stats();
	audio_overdue_commands_.store(0, std::memory_order_relaxed);
}

Dictionary ExMateriaPsxSpu::get_deferred_stats() const {
	Dictionary stats;
	stats["enabled"] = deferred_.load(std::memory_order_relaxed);
	stats["capacity"] = deferred_queue_.capacity();
	stats["pending"] = deferred_queue_.pending_count();
	stats["free_slots"] = deferred_queue_.free_slots();
	stats["high_water"] = deferred_queue_.high_water();
	// A non-zero overflow means register writes were DROPPED — the queue is
	// undersized for the lead the scheduler is running. Never expected.
	stats["overflow"] = static_cast<int64_t>(deferred_queue_.overflow_count());
	// Writes the audio thread reached after their own frame had passed: the
	// scheduler fell behind the audio clock. Audible as the music hesitating.
	stats["overdue"] = static_cast<int64_t>(audio_overdue_commands_.load(std::memory_order_relaxed));
	stats["schedule_frame"] = static_cast<int64_t>(schedule_frame_);
	stats["audio_frame"] = static_cast<int64_t>(audio_frame_.load(std::memory_order_relaxed));
	return stats;
}

void ExMateriaPsxSpu::render_deferred_pcm16_into(int frame_count, int32_t *write) {
	// Applies every queued register write at exactly the frame it was stamped
	// with, rendering the SPU between writes.
	//
	// Why it renders through a carry buffer instead of straight into `write`:
	// the mix loop is voice-major inside a 45-sample batch (PCSX's NSSIZE), so
	// WHERE the batch boundaries fall is audible — the noise LFSR advances once
	// per active voice per sample, and an FM pair reads its modulator out of a
	// per-batch buffer. Rendering 459 frames as 45x10+9 is not the same
	// arithmetic as rendering it as 128+128+128+75. Lockstep GDScript rendered
	// exactly one tick per call, so its batches ran 45,45,...,partial from each
	// tick's first frame. Rendering in whole 45s that break only where a
	// register write lands reproduces that decomposition exactly, whatever
	// block size the audio driver asks for — which is what makes the streamed
	// samples bit-identical rather than merely equivalent.
	//
	// The carry is at most 44 frames (1 ms). It is a render-ahead inside the
	// audio thread, not a producer hand-off.
	if (frame_count <= 0) {
		return;
	}
	constexpr int kBatch = fftshared::FFTSpuBatchRenderResult::kMaxBatch;
	if (static_cast<int>(carry_pcm_.size()) < kBatch * 2) {
		carry_pcm_.assign(static_cast<size_t>(kBatch) * 2, 0);
	}

	uint64_t frame = audio_frame_.load(std::memory_order_relaxed);
	int produced = 0;
	uint64_t overdue = 0;
	while (produced < frame_count) {
		if (carry_pos_ < carry_len_) {
			int take = carry_len_ - carry_pos_;
			if (take > frame_count - produced) {
				take = frame_count - produced;
			}
			for (int i = 0; i < take * 2; i++) {
				write[produced * 2 + i] = carry_pcm_[static_cast<size_t>(carry_pos_) * 2 + i];
			}
			carry_pos_ += take;
			produced += take;
			continue;
		}

		while (const exmateria::SpuCommand *cmd = deferred_queue_.peek()) {
			if (cmd->at_frame > frame) {
				break;
			}
			if (cmd->at_frame < frame) {
				++overdue;
			}
			apply_deferred_command(*cmd);
			deferred_queue_.pop_front();
		}

		// One unit: a full batch, or short if the next register write lands
		// inside it. Anything at exactly `frame` was applied above, so the next
		// command is strictly ahead and this is always > 0.
		int unit = kBatch;
		if (const exmateria::SpuCommand *next = deferred_queue_.peek()) {
			const uint64_t gap = next->at_frame - frame;
			if (gap < static_cast<uint64_t>(unit)) {
				unit = static_cast<int>(gap);
			}
		}
		render_pcm16_into(unit, carry_pcm_.data());
		carry_len_ = unit;
		carry_pos_ = 0;
		frame += static_cast<uint64_t>(unit);
	}

	audio_frame_.store(frame, std::memory_order_release);
	audio_active_voices_.store(get_active_voice_count_internal(), std::memory_order_relaxed);
	if (overdue != 0) {
		audio_overdue_commands_.fetch_add(overdue, std::memory_order_relaxed);
	}
}

PackedInt32Array ExMateriaPsxSpu::render_deferred_pcm16(int frame_count) {
	// The audio thread's own render loop, run synchronously and handed back as
	// PCM. This exists for the parity guard (#385 task 4): it is the SAME code
	// path the stream takes, so a test can compare it against a lockstep render
	// sample for sample without needing an audio device or a thread.
	PackedInt32Array output;
	if (frame_count <= 0) {
		return output;
	}
	output.resize(frame_count * 2);
	render_deferred_pcm16_into(frame_count, output.ptrw());
	return output;
}

void ExMateriaPsxSpu::render_audio_frames(AudioFrame *dst, int frame_count) {
	// THE audio-thread entry point (D3 decision 2: _mix renders, it does not
	// drain a producer).
	if (frame_count <= 0) {
		return;
	}
	// Deferred mode IS the audio thread's claim on this SPU. Once GDScript
	// drops it, a still-in-flight stream renders silence and touches no SPU
	// state at all — Godot keeps mixing a stopped playback for one more block
	// to fade it out (AudioServer::stop_playback_stream marks
	// FADE_OUT_TO_DELETION rather than unlinking it), so that block must not
	// race the teardown. Callers flip the flag under AudioServer.lock(), which
	// is what guarantees no _mix is mid-render when it flips.
	if (!deferred_.load(std::memory_order_acquire)) {
		for (int i = 0; i < frame_count; i++) {
			dst[i].left = 0.0f;
			dst[i].right = 0.0f;
		}
		return;
	}
	// Idle: this unit holds no live cast. Advance the clock — the scheduler
	// paces off it, so it must keep running or the lead arithmetic stalls — and
	// emit silence without entering the mix loop at all. This is what makes one
	// stream per SFX unit affordable: MAX_UNITS + MAX_BG_UNITS + click +
	// audition streams exist, but only the sounding ones cost a render.
	if (stream_idle_.load(std::memory_order_acquire)) {
		audio_frame_.fetch_add(static_cast<uint64_t>(frame_count), std::memory_order_release);
		audio_active_voices_.store(0, std::memory_order_relaxed);
		audio_was_idle_ = true;
		for (int i = 0; i < frame_count; i++) {
			dst[i].left = 0.0f;
			dst[i].right = 0.0f;
		}
		return;
	}
	if (audio_was_idle_) {
		// idle -> active edge. The carry holds up to 44 frames rendered before
		// the unit went quiet; those frames are behind the clock now, so keeping
		// them would emit stale samples at the front of the new cast.
		audio_was_idle_ = false;
		carry_len_ = 0;
		carry_pos_ = 0;
	}

	const size_t needed = static_cast<size_t>(frame_count) * 2;
	if (audio_scratch_.size() < needed) {
		audio_scratch_.assign(needed, 0);
	}

	render_deferred_pcm16_into(frame_count, audio_scratch_.data());

	const float inv_32767 = 1.0f / 32767.0f;
	for (int i = 0; i < frame_count; i++) {
		dst[i].left = static_cast<float>(audio_scratch_[i * 2]) * inv_32767;
		dst[i].right = static_cast<float>(audio_scratch_[i * 2 + 1]) * inv_32767;
	}
}

PackedInt32Array ExMateriaPsxSpu::render_interleaved_pcm16(int frame_count) {
	PackedInt32Array output;
	output.resize(frame_count * 2);
	render_pcm16_into(frame_count, output.ptrw());
	return output;
}

// The whole mix loop, writing into a caller-owned interleaved int32 buffer.
// Both the GDScript render (which allocates a PackedInt32Array around it) and
// the audio thread (which reuses one scratch buffer) go through here — one
// implementation is what makes the streamed samples bit-identical to the
// offline ones.
void ExMateriaPsxSpu::render_pcm16_into(int frame_count, int32_t *write) {
	auto started = std::chrono::high_resolution_clock::now();

	// Batched mix loop — outer per voice, inner per output sample
	// (PCSX-Redux spu.cc:505-815). The noise LFSR shared by all noise-mode
	// voices now advances at the same contiguous positions PCSX advances
	// it within a batch (see CURE_4_V18_BATCHED_MIXER_REFACTOR_PLAN.md
	// for the cure_4 voice-18 motivation).
	constexpr int kBatchSize = fftshared::FFTSpuBatchRenderResult::kMaxBatch;
	fftshared::FFTSpuBatchRenderResult batch;
	int frame = 0;
	while (frame < frame_count) {
		const int batch_size = std::min(kBatchSize, frame_count - frame);

		core_.render_mix_batch(batch_size, -1, batch);
		const std::vector<Voice> &voices_after = core_.voices();
		const std::vector<fftshared::FFTSpuVoiceMixResult> &frame_mix_results = core_.frame_mix_results();

		for (int ns = 0; ns < batch_size; ++ns) {
			const uint64_t sample_index = rendered_sample_count + static_cast<uint64_t>(frame + ns);
			const std::array<int, 2> rvb_out = mix_reverb(batch.rvb_in_l[ns], batch.rvb_in_r[ns]);
			const int raw_l = batch.sum_l[ns] + rvb_out[0];
			const int raw_r = batch.sum_r[ns] + rvb_out[1];
			accumulate_rail_metrics(raw_l, raw_r);
			write[(frame + ns) * 2] = clip_pcm16(raw_l);
			write[(frame + ns) * 2 + 1] = clip_pcm16(raw_r);

			// Per-sample IRQ cadence (FUN_80014590 analog). Counter wraps
			// at irq_period_samples_; on wrap, pending_irq_passes_ is
			// incremented for the GDScript harness to drain after this
			// render call returns.
			if (++irq_sample_counter_ >= irq_period_samples_) {
				irq_sample_counter_ = 0;
				irq_pass_counter_++;
				pending_irq_passes_++;
			}
		}

		// Per-batch trace at end-of-batch sample_index. The batched mixer
		// leaves voice state at end-of-batch; sample-precise within-batch
		// trajectory is lost (acceptable per the refactor plan — cos_dist
		// is the parity target, not trace granularity).
		const uint64_t batch_end_sample_index =
				rendered_sample_count + static_cast<uint64_t>(frame + batch_size - 1);
		for (int voice_idx = 0; voice_idx < static_cast<int>(voices_after.size()); ++voice_idx) {
			const fftshared::FFTSpuVoiceMixResult &mix_result = frame_mix_results[voice_idx];
			if (!mix_result.active) {
				continue;
			}
			trace_voice_event(voice_idx, batch_end_sample_index, voices_after[voice_idx],
					mix_result.env_vol, clip_pcm16(mix_result.sample));
		}
		trace_inactive_voices(batch_end_sample_index);

		frame += batch_size;
	}
	rendered_sample_count += static_cast<uint64_t>(frame_count);

	auto ended = std::chrono::high_resolution_clock::now();
	double elapsed_ms = std::chrono::duration<double, std::milli>(ended - started).count();
	update_render_timing(elapsed_ms);
}

PackedInt32Array ExMateriaPsxSpu::render_voice_pcm16(int frame_count, int voice_idx) {
	auto started = std::chrono::high_resolution_clock::now();

	PackedInt32Array output;
	output.resize(frame_count);
	int32_t *write = output.ptrw();

	// Batched mix loop — outer per voice, inner per output sample
	// (PCSX-Redux spu.cc:505-815, NSSIZE=45). Matches the structure already
	// in render_interleaved_pcm16. The previous per-frame driver
	// (core_.render_mix_frame called once per output sample) gave noise-mode
	// voices a stride-N LFSR read pattern (N = active voice count), because
	// each per-sample frame advanced the shared LFSR once per active voice
	// and the target voice only read it once at its position in the outer
	// loop. That produced a wildly HF-shifted noise spectrum on
	// spu_voice_NN.wav even though full-mix output was correct.
	// See CURE_4_V18_NOISE_LFSR_SPECTRAL_DIVERGENCE.md §10.
	constexpr int kBatchSize = fftshared::FFTSpuBatchRenderResult::kMaxBatch;
	fftshared::FFTSpuBatchRenderResult batch;
	int frame = 0;
	while (frame < frame_count) {
		const int batch_size = std::min(kBatchSize, frame_count - frame);

		core_.render_mix_batch(batch_size, voice_idx, batch);
		const std::vector<Voice> &voices_after = core_.voices();
		const std::vector<fftshared::FFTSpuVoiceMixResult> &frame_mix_results = core_.frame_mix_results();

		for (int ns = 0; ns < batch_size; ++ns) {
			// Keep reverb state advancing in lockstep with the full-mix
			// path so reverb-buffer evolution stays identical between
			// per-voice and full-mix renders.
			(void)mix_reverb(batch.rvb_in_l[ns], batch.rvb_in_r[ns]);
			write[frame + ns] = clip_pcm16(batch.target_sample[ns]);

			if (++irq_sample_counter_ >= irq_period_samples_) {
				irq_sample_counter_ = 0;
				irq_pass_counter_++;
				pending_irq_passes_++;
			}
		}

		// Per-batch trace at end-of-batch sample_index (mirrors
		// render_interleaved_pcm16). Per-voice mode in render_effect_sound.gd
		// doesn't consume sampled_voice_trace events, so this block is only
		// exercised when the trace is independently enabled.
		if (sampled_voice_trace_enabled) {
			const uint64_t batch_end_sample_index =
					rendered_sample_count + static_cast<uint64_t>(frame + batch_size - 1);
			for (int voice_idx_iter = 0;
					voice_idx_iter < static_cast<int>(voices_after.size());
					++voice_idx_iter) {
				const fftshared::FFTSpuVoiceMixResult &mix_result = frame_mix_results[voice_idx_iter];
				const Voice &voice = voices_after[voice_idx_iter];
				const int sample_value = (voice_idx_iter == voice_idx && mix_result.active)
						? clip_pcm16(mix_result.sample)
						: 0;
				const int env_vol = voice.on
						? (voice.adsr.envelope_vol >> fftshared::FFTAdsrEnvelope::kOutputShift)
						: 0;
				trace_voice_event(voice_idx_iter, batch_end_sample_index, voice, env_vol, sample_value);
			}
			trace_inactive_voices(batch_end_sample_index);
		}

		frame += batch_size;
	}
	rendered_sample_count += static_cast<uint64_t>(frame_count);

	auto ended = std::chrono::high_resolution_clock::now();
	double elapsed_ms = std::chrono::duration<double, std::milli>(ended - started).count();
	update_render_timing(elapsed_ms);

	return output;
}

PackedInt32Array ExMateriaPsxSpu::render_replay_mix_frames(int frame_count,
		const Array &per_voice_samples, const Array &per_voice_events,
		const PackedInt32Array &ground_truth_rvb_input) {
	PackedInt32Array output;
	output.resize(frame_count * 2);
	int32_t *write = output.ptrw();

	// Optional ground-truth reverb-input stream (PCSX-captured in_l/in_r
	// pairs at 22 050 Hz). When non-empty, substitute these for the
	// per-voice-sum only on the odd-branch iter that actually consumes
	// `input`. See render_replay_mix.gd `--ground-truth-reverb-input`.
	const int32_t *gt_ptr = ground_truth_rvb_input.ptr();
	const int64_t gt_size = ground_truth_rvb_input.size();
	const bool gt_enabled = gt_size >= 2;
	int64_t gt_iter = 0;

	// Unpack per-voice sample streams + event cursors. Each voice holds
	// a pointer to its int32 (mono int16-valued) sample stream, its
	// length, an event list, and a cursor into the event list. Volumes
	// start at 0 — the caller must provide a sample_index=0 event to
	// establish the initial volume if the voice is active from frame 0.
	std::array<fftshared::FFTReplayVoiceRuntime, NUM_VOICES> rep;
	for (int v = 0; v < NUM_VOICES; v++) {
		if (v < per_voice_samples.size()) {
			const PackedInt32Array &arr = per_voice_samples[v];
			rep[v].samples = arr.ptr();
			rep[v].sample_len = arr.size();
		}
		if (v < per_voice_events.size()) {
			const Array events = per_voice_events[v];
			rep[v].events.reserve(events.size());
			for (int i = 0; i < events.size(); ++i) {
				const Array ev = events[i];
				if (ev.size() < 4) {
					continue;
				}
				fftshared::FFTReplayEvent replay_event;
				replay_event.sample_index = static_cast<int64_t>(ev[0]);
				replay_event.left_volume = static_cast<int>(ev[1]);
				replay_event.right_volume = static_cast<int>(ev[2]);
				replay_event.reverb = static_cast<int>(ev[3]) != 0;
				rep[v].events.push_back(replay_event);
			}
		}
	}

	for (int frame = 0; frame < frame_count; frame++) {
		fftshared::FFTReplayFrameMixResult frame_result;
		fftshared::fft_render_replay_mix_frame(rep, frame, VOLUME_DIVISOR, frame_result);
		int rvb_in_l = frame_result.rvb_in_l;
		int rvb_in_r = frame_result.rvb_in_r;

		// mix_reverb increments rvb_cnt then runs the odd branch when the
		// new value is odd. Substitute ground-truth input on those iters
		// only — the even-branch call discards `input` anyway.
		const bool odd_branch = core_.next_reverb_mix_odd_branch();
		if (gt_enabled && odd_branch) {
			const int64_t base = gt_iter * 2;
			if (base + 1 < gt_size) {
				rvb_in_l = gt_ptr[base];
				rvb_in_r = gt_ptr[base + 1];
			}
			gt_iter++;
		}

		std::array<int, 2> rvb_out = mix_reverb(rvb_in_l, rvb_in_r);
		write[frame * 2] = clip_pcm16(frame_result.sum_l + rvb_out[0]);
		write[frame * 2 + 1] = clip_pcm16(frame_result.sum_r + rvb_out[1]);

		// IRQ cadence — replay-mix path advances the same counter as
		// the synthesis-path renders so a session that interleaves the
		// two doesn't desync the IRQ rate.
		if (++irq_sample_counter_ >= irq_period_samples_) {
			irq_sample_counter_ = 0;
			irq_pass_counter_++;
			pending_irq_passes_++;
		}
	}

	return output;
}

PackedVector2Array ExMateriaPsxSpu::render_frames(int frame_count) {
	PackedInt32Array pcm = render_interleaved_pcm16(frame_count);
	PackedVector2Array output;
	output.resize(frame_count);
	Vector2 *write = output.ptrw();
	const int32_t *read = pcm.ptr();
	const float inv_32767 = 1.0f / 32767.0f;
	for (int i = 0; i < frame_count; i++) {
		write[i] = Vector2(float(read[i * 2]) * inv_32767, float(read[i * 2 + 1]) * inv_32767);
	}
	return output;
}

int ExMateriaPsxSpu::get_active_voice_count() const {
	return get_active_voice_count_internal();
}

Dictionary ExMateriaPsxSpu::get_debug_stats() const {
	Dictionary stats;
	stats["last_render_ms"] = last_render_ms;
	stats["max_render_ms"] = max_render_ms;
	stats["active_voices"] = get_active_voice_count_internal();
	stats["reverb_enabled"] = core_.reverb_enabled();
	// SPU-rail saturation (per-unit in-core clip, pre-BusLimiter). Raw pre-clamp
	// peak is int16-scaled: /32767 in GDScript gives the overshoot factor.
	stats["rail_pre_clamp_peak"] = static_cast<int64_t>(rail_pre_clamp_peak_);
	stats["rail_hits"] = static_cast<int64_t>(rail_hit_count_);
	stats["rail_samples"] = static_cast<int64_t>(rail_sample_count_);
	return stats;
}

Dictionary ExMateriaPsxSpu::get_voice_debug_info(int voice_idx) const {
	Dictionary info;
	if (voice_idx < 0 || voice_idx >= static_cast<int>(core_.voices().size())) {
		return info;
	}

	const Voice &voice = core_.voices()[voice_idx];
	info["voice_idx"] = voice_idx;
	info["on"] = voice.on;
	info["instrument_idx"] = voice.instrument_idx;
	info["raw_pitch"] = voice.raw_pitch;
	info["start_addr"] = voice.start_addr;
	info["curr_addr"] = voice.curr_addr;
	info["loop_addr"] = voice.loop_addr;
	info["end_addr"] = voice.end_addr;
	info["requested_loop_addr"] = voice.requested_loop_addr;
	info["buf_pos"] = voice.buf_pos;
	info["left_volume"] = voice.left_volume;
	info["right_volume"] = voice.right_volume;
	info["adsr1"] = voice.adsr1;
	info["adsr2"] = voice.adsr2;
	info["env_state"] = static_cast<int>(voice.adsr.state);
	info["env_vol"] = voice.adsr.envelope_vol >> fftshared::FFTAdsrEnvelope::kOutputShift;
	info["env_vol_raw"] = voice.adsr.envelope_vol;
	// Full ADSR engine internals exposed for trace comparison.
	info["env_vol_f"] = voice.adsr.envelope_vol_f;
	info["attack_rate"] = voice.adsr.attack_rate;
	info["attack_mode_exp"] = voice.adsr.attack_mode_exp;
	info["decay_rate"] = voice.adsr.decay_rate;
	info["sustain_level"] = voice.adsr.sustain_level;
	info["sustain_rate"] = voice.adsr.sustain_rate;
	info["sustain_mode_exp"] = voice.adsr.sustain_mode_exp;
	info["sustain_increase"] = voice.adsr.sustain_increase;
	info["release_rate"] = voice.adsr.release_rate;
	info["release_mode_exp"] = voice.adsr.release_mode_exp;
	info["spos"] = voice.spos;
	info["sinc"] = voice.sinc;
	info["reverb"] = voice.reverb;
	info["noise_on"] = voice.noise_on;
	info["fmod"] = voice.fmod;
	info["last_out_l"] = voice.last_out_l;
	info["last_out_r"] = voice.last_out_r;
	info["declick_l"] = voice.declick_l;
	info["declick_remaining"] = voice.declick_remaining;
	info["noise_clock"] = static_cast<int>(fftshared::fft_spu_get_noise_clock());

	if (voice.instrument_idx >= 0 && voice.instrument_idx < static_cast<int>(core_.instruments().size())) {
		const InstrumentData &inst = core_.instruments()[voice.instrument_idx];
		info["sample_offset"] = inst.sample_offset;
		info["sample_size"] = inst.sample_size;
		info["loop_offset_bytes"] = inst.loop_offset_bytes;
		info["has_explicit_loop_start"] = inst.has_explicit_loop_start;
		info["has_loop_repeat"] = inst.has_loop_repeat;
		info["start_offset_bytes"] = inst.start_offset_bytes;
	}

	return info;
}

void ExMateriaPsxSpu::set_sampled_voice_trace_enabled(bool enabled) {
	sampled_voice_trace_enabled = enabled;
	if (enabled) {
		clear_sampled_voice_trace_internal();
		rendered_sample_count = 0;
	}
}

bool ExMateriaPsxSpu::is_sampled_voice_trace_enabled() const {
	return sampled_voice_trace_enabled;
}

void ExMateriaPsxSpu::set_sampled_voice_trace_dense(bool enabled) {
	sampled_voice_trace_dense = enabled;
	if (sampled_voice_trace_enabled) {
		clear_sampled_voice_trace_internal();
		rendered_sample_count = 0;
	}
}

bool ExMateriaPsxSpu::is_sampled_voice_trace_dense() const {
	return sampled_voice_trace_dense;
}

void ExMateriaPsxSpu::set_sampled_voice_trace_voices(const PackedInt32Array &voice_indices) {
	sampled_voice_trace_mask.fill(false);
	if (voice_indices.is_empty()) {
		sampled_voice_trace_mask.fill(true);
		return;
	}
	for (int i = 0; i < voice_indices.size(); i++) {
		const int voice_idx = voice_indices[i];
		if (voice_idx >= 0 && voice_idx < NUM_VOICES) {
			sampled_voice_trace_mask[voice_idx] = true;
		}
	}
}

void ExMateriaPsxSpu::clear_sampled_voice_trace() {
	clear_sampled_voice_trace_internal();
	rendered_sample_count = 0;
}

Array ExMateriaPsxSpu::get_sampled_voice_trace() const {
	Array out;
	out.resize(static_cast<int>(sampled_voice_trace.size()));
	for (int i = 0; i < static_cast<int>(sampled_voice_trace.size()); i++) {
		out[i] = sampled_voice_trace[i];
	}
	return out;
}

void ExMateriaPsxSpu::set_reverb_enabled(bool enabled) {
	FFT_SPU_DEFER(SET_REVERB_ENABLED, enabled ? 1 : 0);
	core_.set_reverb_enabled(enabled);
}

bool ExMateriaPsxSpu::is_reverb_enabled() const {
	return core_.reverb_enabled();
}

void ExMateriaPsxSpu::set_reverb_algorithm(const String &algorithm) {
	const String lowered = algorithm.to_lower();
	if (lowered == "xebra") {
		core_.set_reverb_algorithm(fftshared::FFTSpuReverbAlgorithm::kXebra);
		return;
	}
	core_.set_reverb_algorithm(fftshared::FFTSpuReverbAlgorithm::kCurrent);
}

String ExMateriaPsxSpu::get_reverb_algorithm() const {
	return String(core_.reverb_algorithm_name());
}

void ExMateriaPsxSpu::set_reverb_buffer_start(int addr) {
	core_.set_reverb_buffer_start(addr);
}

void ExMateriaPsxSpu::set_reverb_curr_addr(int addr) {
	core_.set_reverb_curr_addr(addr);
}

void ExMateriaPsxSpu::set_reverb_debug_path(const String &path) {
	if (rvb_debug_file != nullptr) {
		std::fclose(rvb_debug_file);
		rvb_debug_file = nullptr;
	}
	rvb_debug_path = std::string(path.utf8().get_data());
}

void ExMateriaPsxSpu::set_reverb_debug_enabled(bool enabled) {
	rvb_debug_enabled = enabled;
	if (rvb_debug_file != nullptr) {
		std::fclose(rvb_debug_file);
		rvb_debug_file = nullptr;
	}
	if (enabled && !rvb_debug_path.empty()) {
		rvb_debug_iter_count = 0;
		rvb_debug_file = std::fopen(rvb_debug_path.c_str(), "wb");
	}
}
