#ifndef FFT_SPU_CORE_RUNTIME_H
#define FFT_SPU_CORE_RUNTIME_H

#include <cstdint>
#include <memory>
#include <vector>

#include "fft_spu_mix_tools.h"
#include "fft_spu_reverb.h"
#include "fft_spu_voice_runtime.h"

namespace fftshared {

class FFTSpuCoreRuntime {
public:
	static constexpr int32_t kNumVoices = 24;
	static constexpr int32_t kSpuRamSize = 0x80000;
	static constexpr int32_t kVolumeMax = 0x3FFF;
	static constexpr int32_t kVolumeDivisor = 0x4000;
	static constexpr int32_t kPitchToSincShift = 4;
	static constexpr int32_t kAdpcmBlockSize = 16;
	static constexpr int32_t kAdpcmSamplesPerBlock = 28;
	// FFT's runtime loads the WAVESET ADPCM bank starting at SPU RAM
	// address 0x1010 (verified via PCSX-Redux readSpuRam: SPU 0x1020
	// holds WAVESET adpcm[0x10], i.e. bank base = 0x1010). Using 0x1000
	// here puts every WAVESET byte 16 bytes (one ADPCM block) ahead of
	// where PCSX has it — voice 21 (sample_start=0x1010) reads
	// WAVESET[0x10] on Godot but the zero block WAVESET[0x00] on PCSX,
	// shifting its loop region (LOOP_START flag at WAVESET[0x20] vs
	// [0x30]) and producing a wrong-pitch second note (~4180 Hz vs
	// PCSX's ~3800 Hz). See RERAISE_VOICE_21_RENDERED_AUDIO_DIVERGENCE...
	static constexpr int32_t kRamInstrumentBase = 0x1010;
	static constexpr int32_t kDefaultLfoTickSamples = 611;

	using InstrumentData = FFTSpuInstrumentData;
	using Voice = FFTSpuVoiceRuntime;

	FFTSpuCoreRuntime();

	bool load_instruments(const std::vector<InstrumentData> &instruments, const uint8_t *adpcm_bank, int32_t adpcm_bank_size);
	void reset();
	void key_on(int32_t voice_idx, int32_t instrument_idx, int32_t pitch, int32_t vol_l, int32_t vol_r, int32_t adsr1, int32_t adsr2, bool reverb);
	void key_on_with_addresses(int32_t voice_idx, int32_t instrument_idx, int32_t pitch, int32_t vol_l, int32_t vol_r,
			int32_t adsr1, int32_t adsr2, int32_t start_addr, int32_t loop_addr, bool reverb);
	void key_off(int32_t voice_idx);
	// State-preserving residue replay. For sessions whose savestate has a
	// voice mid-playback (e.g. haste voice 20/21 — the FM modulator/carrier
	// pair captured mid-note), this keys the voice on at sample 0 with the
	// SPU register state restored verbatim — start_addr, loop_addr, curr_addr,
	// ADSR1/ADSR2 register values, env_state, env_vol, vol_l/r, raw_pitch.
	// Unlike key_on_with_addresses this does NOT reset the ADSR to ATTACK,
	// does NOT reset curr_addr to start_addr, and does NOT touch
	// voice.lfo_blocks (the savestate's chan-side LFO state is independent).
	// Mirrors what PCSX-Redux's loadSaveState does for a keyed-on voice.
	// See HASTE_VOICE_21_FMOD_LFO_RESIDUE_FIX.md §5.
	void seed_voice_residue(int32_t voice_idx, int32_t start_addr, int32_t loop_addr,
			int32_t curr_addr, int32_t adsr1, int32_t adsr2,
			int32_t env_state, int32_t env_vol, int32_t vol_l, int32_t vol_r,
			int32_t raw_pitch, bool reverb);
	void set_voice_pitch(int32_t voice_idx, int32_t raw_pitch);
	// Sample-precise scheduled pitch update — see FFTPitchUpdateScheduled.
	void set_voice_pitch_at(int32_t voice_idx, int32_t raw_pitch, int32_t sample_offset);
	void tick_voice_pitch_queue(int32_t voice_idx);
	void set_voice_pre_pitch(int32_t voice_idx, int32_t pre_pitch);
	void set_voice_adsr1_low(int32_t voice_idx, int32_t nibble);
	void set_voice_adsr2(int32_t voice_idx, int32_t adsr2);
	// Walker bit-window setters mirroring FFT helpers FUN_8001B428 / B4B0 /
	// B79C / B938 / BAB8 at the granularity those helpers write — RMW
	// bit-windows on ADSR1/ADSR2, or vol_L/vol_R with optional sweep mode.
	void set_voice_volume_lr(int32_t voice_idx, int32_t vol_l, int32_t vol_r);
	void set_voice_volume_lr_with_mode(int32_t voice_idx, int32_t vol_l, int32_t vol_r,
			int32_t mode_l, int32_t mode_r);
	// Walker bit 0x008 (SAMPLE_ADDR) fan-out. Mirror FFT helpers FUN_8001B6A4
	// (writes SPU+0x6 = sample start_addr) and FUN_8001B720 (writes SPU+0xE
	// = sample repeat_addr / loop_addr). Both are pure SPU register writes;
	// they must NOT re-arm KEYON or reset curr_addr / ADPCM decode state.
	void set_voice_start_addr(int32_t voice_idx, int32_t start_addr);
	void set_voice_repeat_addr(int32_t voice_idx, int32_t repeat_addr);
	void set_voice_adsr1_high(int32_t voice_idx, int32_t attack_rate, int32_t lin_or_exp_mode);
	void set_voice_adsr1_mid(int32_t voice_idx, int32_t mid_nibble);
	void set_voice_adsr2_low(int32_t voice_idx, int32_t low_bits, int32_t mode);
	void set_voice_fmod(int32_t voice_idx, int32_t mode);
	void set_voice_noise(int32_t voice_idx, bool on);
	void set_noise_clock(int32_t noise_clock);
	// Seed noise LFSR state from a PCSX-Redux savestate.
	void set_noise_state(uint32_t noise_val, uint32_t noise_clock, uint32_t noise_count);
	void set_voice_mix_controls(int32_t voice_idx, int32_t volume_base, int32_t velocity_gain,
			int32_t pan_base, int32_t master_gain, int32_t global_pan);
	void init_voice_pitch_lfo(int32_t voice_idx, int32_t count, int32_t signed_step, int32_t rate_reload);
	void clear_voice_pitch_lfo(int32_t voice_idx);
	void set_voice_pitch_lfo_depth(int32_t voice_idx, int32_t depth, int32_t depth_delta);
	// Seed a chan-side LFO subslot from a PCSX savestate's chan_lfo_residue
	// snapshot. Each voice has 4 subslots at chan+{0xE0, 0x100, 0x120, 0x140};
	// FFT's lfo_handler_tick continues ticking them across a savestate load,
	// but Godot starts every voice with zeroed lfo_blocks, so a session whose
	// savestate caught a voice mid-LFO (e.g. haste voice 20 with subslot 2
	// at accum=-9.4e8) emits a divergent per-sample sval. FM (NP_carrier =
	// (32768 + sval_mod) * raw_pitch / 32768) amplifies the divergence into
	// the carrier voice's audible spectrum. Seeding mirrors the FFT-side
	// state at the snapshot cadence so the tick loop resumes from the right
	// phase. See HASTE_VOICE_21_FAITHFUL_LFO_RESIDUE_REPLAY.md §6.4.
	void set_voice_lfo_subslot(int32_t voice_idx, int32_t subslot_idx,
			int32_t accum, int32_t step_current, int32_t step_source,
			int32_t countdown, int32_t inner_reload,
			int32_t depth, int32_t depth_reload,
			int32_t mode, int32_t active_dir_flags);
	void init_voice_volume_lfo(int32_t voice_idx, int32_t count, int32_t signed_step, int32_t rate_reload);
	void clear_voice_volume_lfo(int32_t voice_idx);
	void set_voice_volume_lfo_depth(int32_t voice_idx, int32_t depth, int32_t depth_delta);
	void set_lfo_tick_samples(int32_t samples);
	int32_t lfo_tick_samples() const { return lfo_tick_samples_; }
	// Retrigger de-click ramp length, in output samples (0 = disabled). When
	// > 0, re-keying an already-audible voice fades its residual to zero over
	// this many samples instead of stepping — kills the typewriter-blip pop on
	// the reserved click mixer. A per-core config (survives reset()); leave 0
	// on music/SFX cores so their output stays bit-identical.
	void set_click_retrigger_fade_samples(int32_t samples) {
		click_retrigger_fade_samples_ = samples < 0 ? 0 : samples;
	}
	int32_t click_retrigger_fade_samples() const { return click_retrigger_fade_samples_; }
	// Explicit retrigger de-click carry. Copies the SOURCE voice's last emitted
	// L/R output into the DESTINATION voice's de-click ramp (armed for
	// click_retrigger_fade_samples_ output samples), bypassing the voice.on gate
	// in fft_prepare_voice_for_key_on. Needed when a retriggered click lands on a
	// DIFFERENT voice pair than the outgoing one: the fresh destination reads
	// last_out=0 at key-on, so the on-gated de-click can't smooth the seam — but
	// the outgoing (src) voice still holds the true residual. No-op when the fade
	// is disabled (0 = music/SFX cores stay bit-identical) or an index is out of
	// range. See ExMateriaEffectSfx.play_click (Option 1 seam-carry).
	void carry_voice_declick(int32_t src_voice_idx, int32_t dst_voice_idx);
	void set_lfo_pitch_bias_enabled(bool enabled) { lfo_pitch_bias_enabled_ = enabled; }
	bool lfo_pitch_bias_enabled() const { return lfo_pitch_bias_enabled_; }

	// Install this SPU's driver-space pitch remap (#384 / D1 dec. 1). Per
	// instance, not per process — an SPU with no remap has no note space and
	// biases pitch in raw register units. See FFTSpuPitchRemapFn.
	void set_pitch_remap(FFTSpuPitchRemapFn fn) { pitch_remap_ = fn; }
	FFTSpuPitchRemapFn pitch_remap() const { return pitch_remap_; }
	void tick_pitch_lfo_all_voices();
	void tick_volume_lfo_all_voices();
	void apply_volume_lfo_consumer_all_voices();
	bool advance_lfo_tick();
	FFTSpuFrameRenderResult render_mix_frame(int32_t target_voice_idx);
	// Batched mix: produces up to FFTSpuBatchRenderResult::kMaxBatch (= 45)
	// output samples per call, outer-voice / inner-sample (PCSX-Redux
	// spu.cc:505-815). Used by render_interleaved_pcm16 and the native
	// effect-sound binding.
	void render_mix_batch(int32_t batch_size, int32_t target_voice_idx,
			FFTSpuBatchRenderResult &batch_result);
	std::vector<int16_t> render_interleaved_pcm16(int32_t frame_count);
	int32_t active_voice_count() const;
	void set_reverb_enabled(bool enabled);
	bool reverb_enabled() const;
	void set_reverb_algorithm(FFTSpuReverbAlgorithm algorithm);
	FFTSpuReverbAlgorithm reverb_algorithm() const;
	const char *reverb_algorithm_name() const;
	void set_reverb_buffer_start(int32_t addr);
	int32_t reverb_buffer_start() const;
	void set_reverb_curr_addr(int32_t addr);
	int32_t reverb_curr_addr() const;
	void reset_reverb_state();
	bool next_reverb_mix_odd_branch() const;
	std::array<int32_t, 2> mix_reverb(int32_t input_l, int32_t input_r, FFTSpuReverbDebugSnapshot *debug_snapshot);

	const std::vector<InstrumentData> &instruments() const { return instruments_; }
	const std::vector<Voice> &voices() const { return voices_; }
	std::vector<Voice> &voices_mut() { return voices_; }
	const std::vector<FFTSpuVoiceMixResult> &frame_mix_results() const { return frame_mix_results_; }

private:
	std::vector<InstrumentData> instruments_;
	std::vector<uint8_t> spu_ram_;
	std::vector<Voice> voices_;
	std::vector<FFTSpuVoiceMixResult> frame_mix_results_;
	std::unique_ptr<FFTSpuReverbModel> reverb_;
	int32_t lfo_tick_samples_ = kDefaultLfoTickSamples;
	int32_t lfo_tick_sample_counter_ = 0;
	bool lfo_pitch_bias_enabled_ = true;
	FFTSpuPitchRemapFn pitch_remap_ = nullptr;
	int32_t click_retrigger_fade_samples_ = 0;
};

}  // namespace fftshared

#endif  // FFT_SPU_CORE_RUNTIME_H
