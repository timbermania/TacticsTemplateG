#ifndef FFT_SMD_SEQUENCER_NATIVE_H
#define FFT_SMD_SEQUENCER_NATIVE_H

#include <array>
#include <vector>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include "fft_smd_sequencer_core.h"
#include "fft_spu_core_runtime.h"

namespace godot {

class FFTSmdSequencerNative : public RefCounted {
	GDCLASS(FFTSmdSequencerNative, RefCounted)

	struct SampleTraceState {
		bool valid = false;
		bool on = false;
		bool stop = false;
		int instrument_idx = -1;
		int raw_pitch = 0;
		int left_volume = 0;
		int right_volume = 0;
		int start_addr = 0;
		int loop_addr = 0;
		int requested_loop_addr = 0;
		int curr_addr = 0;
		int env_state = -1;
		int env_vol = -1;
		int sample = 0;
		int decoded_sample = 0;
		int interp_sample = 0;
		int adsr1 = 0;
		int adsr2 = 0;
	};

	fftshared::FFTSpuCoreRuntime core_;
	fftshared::FFTSmdSequencerCore sequencer_;
	std::vector<fftshared::FFTSmdInstrumentInfo> smd_instruments_;
	std::vector<Dictionary> debug_trace_;
	std::vector<Dictionary> sampled_voice_trace_;
	std::array<SampleTraceState, fftshared::FFTSpuCoreRuntime::kNumVoices> sampled_voice_prev_ = {};
	std::array<bool, fftshared::FFTSpuCoreRuntime::kNumVoices> sampled_voice_trace_mask_ = {};
	bool debug_trace_enabled_ = false;
	bool sampled_voice_trace_enabled_ = false;
	bool sampled_voice_trace_dense_ = false;
	uint64_t rendered_sample_count_ = 0;
	int32_t rendered_frames_total_ = 0;

	static void _bind_methods();
	static godot::PackedInt32Array to_packed_pcm(const std::vector<int16_t> &pcm);
	static int clip_pcm16(int value);

	void clear_debug_trace_internal();
	void clear_sampled_voice_trace_internal();
	void on_trace_event(const fftshared::FFTSmdPlaybackTraceEvent &event);
	bool should_trace_voice_event(int voice_idx) const;
	SampleTraceState build_sample_trace_state(const fftshared::FFTSpuCoreRuntime::Voice &voice, int env_vol, int sample) const;
	bool sample_trace_changed(int voice_idx, const SampleTraceState &next) const;
	Dictionary build_sample_trace_row(int voice_idx, uint64_t sample_index,
			const fftshared::FFTSpuCoreRuntime::Voice &voice, const SampleTraceState &next) const;
	void trace_voice_event(int voice_idx, uint64_t sample_index,
			const fftshared::FFTSpuCoreRuntime::Voice &voice, int env_vol, int sample);
	void trace_inactive_voices(uint64_t sample_index);
	PackedInt32Array render_interleaved_with_trace(int frame_count);

public:
	FFTSmdSequencerNative();

	void set_reverb_algorithm(const String &algorithm);
	String get_reverb_algorithm() const;
	void set_debug_trace_enabled(bool enabled);
	bool is_debug_trace_enabled() const;
	Array get_debug_trace() const;
	void clear_debug_trace();
	bool load_instruments(const Array &p_instruments, const PackedByteArray &p_adpcm_bank);
	bool load_sequence(int initial_tempo, const Array &track_events);
	bool tick();
	PackedInt32Array render_tick_pcm16();
	PackedInt32Array render_frames_only_pcm16(int frame_count);
	bool has_active_audio() const;
	bool all_done() const;
	int get_active_voice_count() const;
	double get_tempo_bpm() const;
	double get_samples_per_tick() const;
	double get_tick_accumulator() const;
	int get_total_ticks() const;
	void set_sampled_voice_trace_enabled(bool enabled);
	bool is_sampled_voice_trace_enabled() const;
	void set_sampled_voice_trace_dense(bool enabled);
	bool is_sampled_voice_trace_dense() const;
	void set_sampled_voice_trace_voices(const PackedInt32Array &voice_indices);
	void clear_sampled_voice_trace();
	Array get_sampled_voice_trace() const;
};

}  // namespace godot

#endif  // FFT_SMD_SEQUENCER_NATIVE_H
