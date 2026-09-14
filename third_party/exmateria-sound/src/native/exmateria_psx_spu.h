#ifndef EXMATERIA_PSX_SPU_H
#define EXMATERIA_PSX_SPU_H

#include <array>
#include <atomic>
#include <cstdint>
#include <string>
#include <vector>

#include <godot_cpp/classes/audio_frame.hpp>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

#include "exmateria_spu_command_queue.h"
#include "fft_adsr_envelope.h"
#include "fft_spu_core_runtime.h"
#include "fft_spu_core_state_tools.h"
#include "fft_spu_lfo_tools.h"
#include "fft_spu_mix_tools.h"
#include "fft_spu_pitch_runtime.h"
#include "fft_spu_replay_mix_tools.h"
#include "fft_spu_reverb.h"
#include "fft_spu_sample_runtime.h"
#include "fft_spu_voice_runtime.h"

namespace godot {

class ExMateriaPsxSpu : public RefCounted {
	GDCLASS(ExMateriaPsxSpu, RefCounted)

	static constexpr int SAMPLE_RATE = 44100;
	static constexpr int NUM_VOICES = 24;
	static constexpr int VOLUME_MAX = 0x3FFF;
	static constexpr int VOLUME_DIVISOR = 0x4000;
	static constexpr int PITCH_TO_SINC_SHIFT = 4;
	static constexpr int CLIP_PCM16_MIN = -32767;
	static constexpr int CLIP_PCM16_MAX = 32767;

	using ADSREnvelope = fftshared::FFTAdsrEnvelope;
	using InstrumentData = fftshared::FFTSpuCoreRuntime::InstrumentData;

	// Per-voice LFO block, mirroring FFT's 0x20-byte channel-local LFO state
	// at ch+{0xe0, 0x100, 0x120, 0x140}. The pitch-LFO block is index 0 and
	// biases SPU raw_pitch; block 1/2 bias into per-voice accumulators
	// (sequencer+0x88, 0x8a) used by the envelope smoother. Populated by
	// 0xD7/0xD8 handlers.
	using LFOBlock = fftshared::FFTPitchLfoBlock;

	using Voice = fftshared::FFTSpuCoreRuntime::Voice;

	struct SampleTraceState {
		bool valid = false;
		bool on = false;
		bool stop = false;
		int raw_pitch = 0;
		int left_volume = 0;
		int right_volume = 0;
		int start_addr = 0;
		int loop_addr = 0;
		int curr_addr = 0;
		int env_state = -1;
		int env_vol = -1;
		int sample = 0;
		int decoded_sample = 0;
		int interp_sample = 0;
		int fmod = 0;
	};

	fftshared::FFTSpuCoreRuntime core_;
	std::vector<Dictionary> sampled_voice_trace;
	std::array<SampleTraceState, NUM_VOICES> sampled_voice_prev = {};
	std::array<bool, NUM_VOICES> sampled_voice_trace_mask = {};
	bool sampled_voice_trace_enabled = false;
	bool sampled_voice_trace_dense = false;
	uint64_t rendered_sample_count = 0;

	bool rvb_debug_enabled = false;
	std::string rvb_debug_path;
	FILE *rvb_debug_file = nullptr;
	uint32_t rvb_debug_iter_count = 0;

	double last_render_ms = 0.0;
	double max_render_ms = 0.0;

	// Async-commit walker (FUN_80014590 analog) cadence counter. FFT's SPU
	// sample-buffer IRQ fires roughly every 512 samples (~88 Hz at 44100).
	// Counter advances per rendered sample in the three render paths; on
	// overflow, pending_irq_passes_ is incremented for GDScript to drain
	// after the render call returns. Boundary-only firing — never re-enters
	// GDScript synchronously mid-render. See spu_irq_walker.gd.
	int irq_period_samples_ = 512;
	int irq_sample_counter_ = 0;
	uint32_t irq_pass_counter_ = 0;
	int pending_irq_passes_ = 0;

	// SPU "rail" saturation metrics (typewriter-burst popping hunt). Track how
	// hard the summed voices push past the int16 output rail INSIDE this unit's
	// core, before clip_pcm16 cuts them — the per-unit analog of the downstream
	// BusLimiter / master-bus headroom counters, and the one clip the GDScript
	// side cannot see (render_interleaved_pcm16 already returns clamped PCM).
	// Updated per output sample in the live/capture mix path; read + zeroed under
	// the GDScript audio mutex (get_debug_stats / reset_rail_metrics). Plain ints
	// (no godot-cpp / atomics) so the accounting stays portable and cheap — the
	// caller's mutex already serialises render vs. read.
	int64_t rail_pre_clamp_peak_ = 0;  // max |sum+reverb| pre-clamp (raw; /32767 = xN over rail)
	uint64_t rail_hit_count_ = 0;      // output samples the clamp actually cut (L or R)
	uint64_t rail_sample_count_ = 0;   // output samples rendered since reset (rate denominator)

	// ---- Deferred (audio-thread) mode — D3 decisions 1-3 (#376) ----------
	//
	// Off by default: every register write applies immediately and GDScript
	// renders in lockstep, which is what the parity rigs and the offline
	// renderers want. Turned on by a live ExMateriaSpuStream, at which point
	// each register write is stamped with `schedule_frame_` and queued, and the
	// audio thread applies it at that frame inside render_audio_frames(). The
	// two modes run the SAME core_ calls in the same order — that is what makes
	// the streamed output bit-identical to the lockstep render.
	exmateria::SpuCommandQueue deferred_queue_;
	std::atomic<bool> deferred_{ false };
	// Producer-owned. The frame the NEXT register write belongs at; the
	// scheduler advances it by one tick's samples per sequencer tick.
	uint64_t schedule_frame_ = 0;
	// Audio-thread-owned, published for the scheduler: frames rendered since
	// the stream started, and the active-voice count as of the last block.
	// The active count is how the scheduler learns a song's tail has decayed
	// without reading SPU state across the thread boundary.
	std::atomic<uint64_t> audio_frame_{ 0 };
	std::atomic<int> audio_active_voices_{ 0 };
	std::atomic<uint64_t> audio_overdue_commands_{ 0 };
	// Idle claim — #385 task 3. An SFX unit holds a live cast only part of the
	// time, and with one stream per unit an always-rendering stream would burn a
	// full 24-voice render per idle unit per block. While this is set the audio
	// thread advances the clock and emits silence WITHOUT touching core_. Flipped
	// from the game thread; the audio thread's own view is audio_was_idle_.
	std::atomic<bool> stream_idle_{ false };
	// Audio-thread-owned: whether the previous block took the idle path, so the
	// 45-sample carry can be dropped on the idle -> active edge (it holds samples
	// rendered before the unit went quiet).
	bool audio_was_idle_ = false;
	// Reused int16 staging for render_audio_frames — the audio thread must not
	// allocate, and going through the pcm16 path is what keeps the streamed
	// samples identical to render_interleaved_pcm16's.
	std::vector<int32_t> audio_scratch_;
	// One 45-sample mix batch, rendered ahead so that batch boundaries fall
	// where the lockstep renderer put them rather than where the audio driver's
	// block size falls. See render_deferred_pcm16_into.
	std::vector<int32_t> carry_pcm_;
	int carry_len_ = 0;
	int carry_pos_ = 0;

	template <typename... Args>
	void push_deferred(exmateria::SpuCommandOp p_op, Args... p_args) {
		exmateria::SpuCommand cmd;
		cmd.at_frame = schedule_frame_;
		cmd.op = p_op;
		cmd.argc = static_cast<int32_t>(sizeof...(Args));
		if constexpr (sizeof...(Args) > 0) {
			const int32_t values[] = { static_cast<int32_t>(p_args)... };
			for (int i = 0; i < cmd.argc && i < exmateria::kSpuCommandMaxArgs; ++i) {
				cmd.args[i] = values[i];
			}
		}
		deferred_queue_.push(cmd);
	}

	void apply_deferred_command(const exmateria::SpuCommand &p_cmd);
	void render_pcm16_into(int frame_count, int32_t *write);
	void render_deferred_pcm16_into(int frame_count, int32_t *write);

	static void _bind_methods();

	static int clip_pcm16(int value);
	void accumulate_rail_metrics(int raw_l, int raw_r);

	void reset_reverb_state();
	int get_active_voice_count_internal() const;
	std::array<int, 2> mix_reverb(int input_l, int input_r);
	void update_render_timing(double elapsed_ms);
	void clear_sampled_voice_trace_internal();
	bool should_trace_voice_event(int voice_idx) const;
	SampleTraceState build_sample_trace_state(const Voice &voice, int env_vol, int sample) const;
	bool sample_trace_changed(int voice_idx, const SampleTraceState &next) const;
	Dictionary build_sample_trace_row(int voice_idx, uint64_t sample_index, const Voice &voice, const SampleTraceState &next) const;
	void trace_voice_event(int voice_idx, uint64_t sample_index, const Voice &voice, int env_vol, int sample);
	void trace_inactive_voices(uint64_t sample_index);

public:
	ExMateriaPsxSpu();

	bool load_instruments(const Array &p_instruments, const PackedByteArray &p_adpcm_bank);
	void reset();
	void key_on(int voice_idx, int instrument_idx, int pitch, int vol_l, int vol_r, int adsr1, int adsr2, bool p_reverb);
	void key_on_with_addresses(int voice_idx, int instrument_idx, int pitch, int vol_l, int vol_r, int adsr1, int adsr2,
			int start_addr, int loop_addr, bool p_reverb);
	void key_off(int voice_idx);
	// State-preserving residue seed — see FFTSpuCoreRuntime::seed_voice_residue
	// + HASTE_VOICE_21_FMOD_LFO_RESIDUE_FIX.md §5.
	void seed_voice_residue(int voice_idx, int start_addr, int loop_addr, int curr_addr,
			int adsr1, int adsr2, int env_state, int env_vol,
			int vol_l, int vol_r, int raw_pitch, bool reverb);
	void set_voice_pitch(int voice_idx, int raw_pitch);
	// FMod mode: 0=off, 1=this voice modulated by previous voice's
	// sample, 2=this voice provides FM to next voice. Used by FFT
	// silent-driver pair pattern (ice: v18=2, v19=1).
	void set_voice_fmod(int voice_idx, int mode);
	// SPU noise-mode toggle (Chan::Noise per PCSX-Redux spu.cc:296-345).
	// When on, this voice's source sample is replaced by the global LFSR
	// noise generator output; ADSR/volume still apply.
	void set_voice_noise(int voice_idx, bool on);
	// SPU global noise clock (spuCtrl bits 8-13, range 0..63). 0 = highest
	// rate (broadband white noise). Affects all noise-mode voices.
	void set_noise_clock(int noise_clock);
	// Seed the global SPU noise LFSR state from a PCSX-Redux savestate
	// (m_noiseVal/m_noiseClock/m_noiseCount). Required for noise-using
	// sessions to match PCSX bit-for-bit from the seed point.
	void set_noise_state(int noise_val, int noise_clock, int noise_count);
	// Store the pre-conversion pitch (midi_note * 256 + fine_tune) alongside
	// the SPU-format raw_pitch, so the LFO tick can bias in pre-space and
	// run through FUN_80017424 for correct non-linear output.
	void set_voice_pre_pitch(int voice_idx, int pre_pitch);
	void set_voice_adsr1_low(int voice_idx, int nibble);
	// Mid-spell ADSR2 update for opcodes 0xC9 / 0xCA. Mirrors FFT helpers
	// L8001B9D4 + L8001BAB8 which write SPU register 1F801C0A+v*0x10.
	// GDScript dispatcher computes the full 16-bit ADSR2 (sustain + release
	// bits + mode); we just store + refresh cached fields the mixer's
	// mix() consumes.
	void set_voice_adsr2(int voice_idx, int adsr2);
	// Bit-window setters that mirror the actual FFT helper write
	// granularity so spu_irq_walker.gd can fan out to the right SPU
	// register on the right bits with RMW semantics on the voice's cached
	// adsr1/adsr2.
	void set_voice_volume_lr(int voice_idx, int vol_l, int vol_r);
	void set_voice_volume_lr_with_mode(int voice_idx, int vol_l, int vol_r, int mode_l, int mode_r);
	void set_voice_adsr1_high(int voice_idx, int attack_rate, int lin_or_exp_mode);
	void set_voice_adsr1_mid(int voice_idx, int mid_nibble);
	void set_voice_adsr2_low(int voice_idx, int low_bits, int mode);
	// Walker bit 0x008 (SAMPLE_ADDR) fan-out helpers. Mirror FFT
	// FUN_8001B6A4 (SPU+0x6 = start_addr) and FUN_8001B720 (SPU+0xE =
	// repeat_addr / loop_addr). Pure register writes; no KEYON re-arm,
	// no decode reset.
	void set_voice_start_addr(int voice_idx, int start_addr);
	void set_voice_repeat_addr(int voice_idx, int repeat_addr);
	// Populate the voice's pitch LFO block (lfo_blocks[0]) per FFT 0xD8 init
	// semantics (LAB_80016420).
	void init_voice_pitch_lfo(int voice_idx, int count, int signed_step, int rate_reload);
	void clear_voice_pitch_lfo(int voice_idx);
	// Set the initial LFO depth + per-frame fade-in delta (FFT 0xD7 init,
	// LAB_800165ac). Must be called AFTER init_voice_pitch_lfo, else no
	// effect (writes ch+0xf8/0xfa which FUN_80016dc0 overwrites at enable).
	void set_voice_pitch_lfo_depth(int voice_idx, int depth, int depth_delta);
	void init_voice_volume_lfo(int voice_idx, int count, int signed_step, int rate_reload);
	void clear_voice_volume_lfo(int voice_idx);
	void set_voice_volume_lfo_depth(int voice_idx, int depth, int depth_delta);
	// Seed a chan-side LFO subslot from a PCSX savestate snapshot. Mirrors
	// FFTSpuCoreRuntime::set_voice_lfo_subslot. Used by render_effect_sound.gd
	// to prime voice.lfo_blocks[subslot_idx] before the capture window when
	// the savestate caught a mid-cast LFO (haste voice 20 subslot 2). See
	// HASTE_VOICE_21_FAITHFUL_LFO_RESIDUE_REPLAY.md §6.4.
	void set_voice_lfo_subslot(int voice_idx, int subslot_idx,
			int accum, int step_current, int step_source,
			int countdown, int inner_reload,
			int depth, int depth_reload,
			int mode, int active_dir_flags);
	void set_lfo_tick_samples(int samples);
	int get_lfo_tick_samples() const { return core_.lfo_tick_samples(); }
	// Retrigger de-click knob (typewriter-blip pop fix). Fade length in
	// milliseconds for re-keying an already-audible voice; 0 disables (instant
	// reset = historical behavior). Converted to output samples at SAMPLE_RATE.
	// Set only on the reserved click mixer so music/SFX stay bit-identical.
	// Tunable live from GDScript for A/B (3 ms default; 3 ms ≈ 132 samples).
	void set_click_retrigger_fade_ms(double ms);
	double get_click_retrigger_fade_ms() const;
	// Carry the outgoing click voice's residual onto the incoming pair so a
	// retriggered blip has no seam step even when it lands on a different voice
	// pair. See FFTSpuCoreRuntime::carry_voice_declick + ExMateriaEffectSfx.play_click.
	void carry_voice_declick(int src_voice_idx, int dst_voice_idx);
	void set_lfo_pitch_bias_enabled(bool enabled) {
		if (deferred_.load(std::memory_order_relaxed)) {
			push_deferred(exmateria::SpuCommandOp::SET_LFO_PITCH_BIAS_ENABLED, enabled ? 1 : 0);
			return;
		}
		core_.set_lfo_pitch_bias_enabled(enabled);
	}
	bool is_lfo_pitch_bias_enabled() const { return core_.lfo_pitch_bias_enabled(); }
	PackedInt32Array render_interleaved_pcm16(int frame_count);
	PackedInt32Array render_voice_pcm16(int frame_count, int voice_idx);
	// Replay-harness mix path: takes pre-rendered per-voice mono samples
	// (post-ADSR, pre-volume — matches what both PCSX's per-voice WAV
	// capture and render_voice_pcm16 emit) plus a per-voice event stream
	// of volume/reverb changes, and runs ONLY the mix+reverb stage of
	// the SPU pipeline. Used to isolate whether mix-level divergence
	// between the player and PCSX comes from per-voice synthesis or from
	// the mixer itself.
	//
	// per_voice_samples: Array of 24 PackedInt32Array, each element a
	//   mono int16 sample stream. Missing or short arrays read as zero.
	// per_voice_events: Array of 24 Arrays. Each inner Array is a
	//   time-series of 4-element integer arrays
	//   [sample_index, left_volume, right_volume, reverb_flag]. Events
	//   must be sorted ascending by sample_index within each voice.
	// ground_truth_rvb_input: Optional stereo-interleaved int32 array of
	//   PCSX-captured reverb inputs at 22 050 Hz (one (in_l, in_r) pair
	//   per odd-branch reverb iteration). When non-empty, the per-voice
	//   reverb-input accumulation is bypassed and these values are fed
	//   straight into mix_reverb's odd-branch call. Pass an empty array
	//   to keep the legacy per-voice-sum behavior.
	PackedInt32Array render_replay_mix_frames(int frame_count,
			const Array &per_voice_samples, const Array &per_voice_events,
			const PackedInt32Array &ground_truth_rvb_input);
	// Toggle per-reverb-iteration debug dump. When enabled, each call
	// to mix_reverb writes a JSONL row with IIR/ACC/FB intermediates
	// to the path supplied via set_reverb_debug_path.
	void set_reverb_debug_enabled(bool enabled);
	void set_reverb_debug_path(const String &path);
	PackedVector2Array render_frames(int frame_count);
	int get_active_voice_count() const;
	Dictionary get_debug_stats() const;
	Dictionary get_voice_debug_info(int voice_idx) const;
	void set_sampled_voice_trace_enabled(bool enabled);
	bool is_sampled_voice_trace_enabled() const;
	void set_sampled_voice_trace_dense(bool enabled);
	bool is_sampled_voice_trace_dense() const;
	void set_sampled_voice_trace_voices(const PackedInt32Array &voice_indices);
	void clear_sampled_voice_trace();
	Array get_sampled_voice_trace() const;
	void set_reverb_enabled(bool enabled);
	bool is_reverb_enabled() const;
	void set_reverb_algorithm(const String &algorithm);
	String get_reverb_algorithm() const;
	// Override the reverb-buffer start (wrap target). Also resets
	// rvb_curr to the new start and clears the reverb buffer, mirroring
	// the savestate-cold-start scenario. Use set_reverb_curr_addr AFTER
	// this if replaying a savestate where CurrAddr ≠ StartAddr.
	void set_reverb_buffer_start(int addr);
	int get_reverb_buffer_start() const { return core_.reverb_buffer_start(); }
	// Override the reverb current write address independently of
	// reverb_buffer_start. PCSX savestates restore CurrAddr from its
	// captured value (often mid-buffer); replaying with ground-truth
	// reverb input requires matching this value so the circular-buffer
	// reads/writes land at the same physical addresses as PCSX.
	void set_reverb_curr_addr(int addr);
	int get_reverb_curr_addr() const { return core_.reverb_curr_addr(); }

	// Async-commit walker IRQ cadence (FUN_80014590 analog).
	void set_irq_period_samples(int n);
	int drain_irq_passes();
	uint32_t get_irq_pass_counter() const { return irq_pass_counter_; }

	// Zero the SPU-rail saturation counters (get_debug_stats surfaces them). Cheap
	// per-second window reset for the clipping-metrics suite; distinct from the
	// heavyweight reset() which also clears voices/reverb.
	void reset_rail_metrics();

	// ---- Deferred (audio-thread) mode ------------------------------------
	//
	// While deferred mode is on, an ExMateriaSpuStream owns this mixer's core
	// on the audio thread. Only the register-write setters above are safe to
	// call from the game thread — they queue rather than touch core_. Anything
	// else that mutates state (reset, load_instruments, seed_voice_residue,
	// set_voice_lfo_subslot, set_noise_state, the reverb address setters, the
	// trace setters) and every render_* entry point require the stream stopped;
	// calling them live is a data race, not a queued write.
	//
	// Arm/disarm queueing. `queue_capacity` is rounded up to a power of two and
	// allocated once here; the audio thread never allocates. Call with the
	// stream stopped.
	void set_deferred_mode(bool enabled, int queue_capacity);
	bool is_deferred_mode() const { return deferred_.load(std::memory_order_relaxed); }
	// Drop every queued write and rewind both clocks. Song switch / stream stop.
	void clear_deferred_commands();
	// Producer: the frame the next register write belongs at.
	void set_schedule_frame(int64_t frame) { schedule_frame_ = static_cast<uint64_t>(frame < 0 ? 0 : frame); }
	int64_t get_schedule_frame() const { return static_cast<int64_t>(schedule_frame_); }
	// Producer: what the audio thread has actually rendered, and what it saw.
	int64_t get_audio_frame() const { return static_cast<int64_t>(audio_frame_.load(std::memory_order_acquire)); }
	int get_audio_active_voices() const { return audio_active_voices_.load(std::memory_order_relaxed); }
	int get_deferred_free_slots() const { return deferred_queue_.free_slots(); }
	// Park/unpark this SPU's stream without stopping its AudioStreamPlayer.
	// An idle stream advances its audio clock (so the scheduler's lead arithmetic
	// stays valid) and writes silence, but runs no mix and touches no voice state.
	// Cheaper than stopping and restarting the player, and safe to flip from the
	// game thread at any time — the audio thread only ever reads it.
	void set_stream_idle(bool idle) { stream_idle_.store(idle, std::memory_order_release); }
	bool is_stream_idle() const { return stream_idle_.load(std::memory_order_relaxed); }
	Dictionary get_deferred_stats() const;
	// Zero overdue/overflow/high_water for a fresh monitoring window. Leaves the
	// ring and both clocks alone. Call with the audio thread held off.
	void reset_deferred_stats();

	// Audio-thread entry point. Applies every queued write due inside this
	// block at its own frame, rendering the SPU between writes, and publishes
	// the clock. Not bound to GDScript — ExMateriaSpuPlayback calls it.
	void render_audio_frames(AudioFrame *dst, int frame_count);
	// The same loop, synchronous, handed back as PCM. The parity guard's oracle
	// (#385 task 4) — same code path as the stream, no audio device needed.
	PackedInt32Array render_deferred_pcm16(int frame_count);
};

} // namespace godot

#endif
