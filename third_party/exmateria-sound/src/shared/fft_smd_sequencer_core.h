#ifndef FFT_SMD_SEQUENCER_CORE_H
#define FFT_SMD_SEQUENCER_CORE_H

#include <cstdint>
#include <functional>
#include <limits>
#include <string>
#include <vector>

#include "fft_smd_sequence_model.h"
#include "fft_smd_sequencer_tools.h"
#include "fft_spu_core_runtime.h"

namespace fftshared {

enum class FFTSmdPlaybackTraceKind {
	note,
	key_on,
	opcode,
	structure,
	tempo,
};

struct FFTSmdPlaybackTraceEvent {
	FFTSmdPlaybackTraceKind kind = FFTSmdPlaybackTraceKind::note;
	int32_t tick = 0;
	int32_t source_tick = 0;
	int32_t source_event_index = -1;
	int32_t track_idx = -1;
	int32_t loop_depth = 0;
	std::vector<int32_t> loop_source_ticks;
	std::vector<int32_t> loop_iteration_indices;
	int32_t relative_key = -1;
	int32_t midi_note = -1;
	int32_t velocity = 0;
	int32_t instrument_idx = -1;
	int32_t fine_tune = 0;
	int32_t pre_pitch = 0;
	int32_t raw_pitch = 0;
	int32_t start_addr = 0;
	int32_t loop_addr = 0;
	int32_t end_addr = 0;
	int32_t duration_ticks = 0;
	bool has_fermata = false;
	int32_t fermata_extension_ticks = 0;
	int32_t opcode = 0;
	int32_t value = 0;
	int32_t secondary_value = 0;
	std::vector<int32_t> params;
	std::string label;
};

class FFTSmdSequencerCore {
public:
	explicit FFTSmdSequencerCore(FFTSpuCoreRuntime *spu_core);

	bool load_sequence(const FFTSmdSequence &sequence, const std::vector<FFTSmdInstrumentInfo> &instruments);
	bool tick();
	int32_t consume_tick_frame_count();
	std::vector<int16_t> render_tick_pcm16();
	std::vector<int16_t> render_frames_only_pcm16(int32_t frame_count);
	bool has_active_audio() const;
	bool all_done() const;
	std::vector<int32_t> source_cursor_ticks() const;
	void set_track_muted(int32_t track_idx, bool muted);
	void set_track_soloed(int32_t track_idx, bool soloed);
	bool track_muted(int32_t track_idx) const;
	bool track_soloed(int32_t track_idx) const;
	bool track_audible(int32_t track_idx) const;

	double tempo_bpm() const { return tempo_bpm_; }
	double samples_per_tick() const { return samples_per_tick_; }
	double tick_accumulator() const { return tick_accumulator_; }
	int32_t total_ticks() const { return total_ticks_; }
	void set_trace_callback(std::function<void(const FFTSmdPlaybackTraceEvent&)> trace_callback);

private:
	struct LoopFrame {
		int32_t repeat_start_event_idx = 0;
		int32_t repeat_start_source_tick = 0;
		int32_t remaining_repeats = 0;
		int32_t current_iteration = 0;
		int32_t octave = 4;
	};

	struct TrackState {
		int32_t track_idx = -1;
		std::vector<FFTSmdTrackEvent> events;
		int32_t event_idx = 0;
		int32_t wait_ticks = 0;
		bool done = false;

		int32_t octave = 4;
		int32_t instrument = 0;
		int32_t volume = 127;
		int32_t pan = 64;
		bool reverb = false;
		bool slur = false;

		int32_t current_note = -1;
		int32_t note_ticks_remaining = 0;
		bool hold_note_for_retrigger = false;

		int32_t adsr_attack_override = -1;
		int32_t adsr_sustain_rate_override = -1;
		int32_t adsr_release_override = -1;
		int32_t adsr_decay_override = -1;
		int32_t adsr_sustain_level_override = -1;
		int32_t adsr1_low_slide_target = -1;
		bool adsr1_low_slide_pending = false;

		std::vector<LoopFrame> loop_stack;
		int32_t loop_point = -1;
		bool end_bar_pending = false;

		int32_t time_sig_numerator = 4;
		int32_t time_sig_denominator = 4;
		bool flag_0xFE = false;
		bool flag_0x11E = false;

		int32_t voice_idx = -1;
		int32_t last_key_on_tick = std::numeric_limits<int32_t>::min();
	};

	void update_timing();
	void advance_track(TrackState &track_state);
	void process_note(TrackState &track_state, const FFTSmdNoteEvent &event);
	void process_opcode(
		TrackState &track_state,
		const FFTSmdOpcodeEvent &event,
		int32_t effective_tick,
		int32_t source_tick,
		int32_t source_event_index);
	void emit_trace_event(const FFTSmdPlaybackTraceEvent &event) const;
	int32_t compute_source_cursor_tick(const TrackState &track_state) const;
	std::vector<int32_t> current_loop_source_tick_path(const TrackState &track_state) const;
	std::vector<int32_t> current_loop_iteration_index_path(const TrackState &track_state) const;
	bool any_track_soloed() const;
	void enforce_track_audibility(TrackState &track_state);
	int32_t allocate_voice_for_track(TrackState &track_state);
	void release_track_voice(TrackState &track_state, bool key_off);

	static constexpr int32_t kSampleRate = 44100;
	static constexpr int32_t kNumVoices = 24;
	static constexpr int32_t kMasterVol = 0x7F00;

	FFTSpuCoreRuntime *spu_core_ = nullptr;
	std::vector<FFTSmdInstrumentInfo> instruments_;
	std::vector<TrackState> tracks_;
	double tempo_bpm_ = 120.0;
	double samples_per_tick_ = 0.0;
	double tick_accumulator_ = 0.0;
	int32_t total_ticks_ = 0;
	std::vector<bool> track_muted_;
	std::vector<bool> track_soloed_;
	std::vector<int32_t> voice_track_owner_;
	std::function<void(const FFTSmdPlaybackTraceEvent&)> trace_callback_;
};

}  // namespace fftshared

#endif  // FFT_SMD_SEQUENCER_CORE_H
