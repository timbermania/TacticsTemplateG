#include "fft_smd_sequencer_core.h"

#include <algorithm>
#include <sstream>
#include <utility>

namespace fftshared {

namespace {

std::string trace_opcode_label(const FFTSmdOpcodeEvent &event) {
	const int32_t op = event.opcode;
	const auto first_param = [&]() -> int32_t {
		return event.params.empty() ? 0 : event.params[0];
	};
	const auto second_param_signed = [&]() -> int32_t {
		if (event.params.size() < 2) {
			return 0;
		}
		const int32_t value = event.params[1];
		return value >= 128 ? value - 256 : value;
	};

	switch (op) {
	case 0x80: return "Wait" + std::to_string(first_param());
	case 0x81: return "Ext" + std::to_string(first_param());
	case 0x90: return "End";
	case 0x91: return "LoopTrk";
	case 0x94: return "Oct" + std::to_string(first_param());
	case 0x95: return "RaiseO";
	case 0x96: return "LowerO";
	case 0x97: return "TimeSig";
	case 0x98: return "RptStart";
	case 0x99: return "RptEnd";
	case 0x9A: return "RptBreak";
	case 0xA0: return "T" + std::to_string(first_param());
	case 0xAC: return "I" + std::to_string(first_param());
	case 0xB0: return "SlurOn";
	case 0xB1: return "SlurOff";
	case 0xBA: return "Rev+";
	case 0xBB: return "Rev-";
	case 0xC0: return "ADSR Rst";
	case 0xC2: return "Atk" + std::to_string(first_param());
	case 0xC4: return "SusRt" + std::to_string(first_param());
	case 0xC5: return "Rel" + std::to_string(first_param());
	case 0xC6: return "Slide" + std::to_string(first_param());
	case 0xC7:
		if (event.params.size() >= 2) {
			return "Dec/Sus" + std::to_string(event.params[0]) + "/" + std::to_string(event.params[1]);
		}
		return "Dec/Sus";
	case 0xC9: return "Dec" + std::to_string(first_param());
	case 0xCA: return "SusLvl" + std::to_string(first_param());
	case 0xD7: return "LFO" + std::to_string(first_param());
	case 0xD8:
		if (event.params.size() >= 3) {
			return "LFOlen" + std::to_string(event.params[0]) + "/" +
				std::to_string(second_param_signed()) + "/" + std::to_string(event.params[2]);
		}
		return "LFOlen";
	case 0xDA: return "FlgFE+";
	case 0xDB: return "FlgFE-";
	case 0xE0: return "Dyn" + std::to_string(first_param());
	case 0xE6: return "FlgE6";
	case 0xE8: return "Pan" + std::to_string(first_param());
	default: {
		std::ostringstream out;
		out << "0x" << std::hex << std::uppercase << op;
		return out.str();
	}
	}
}

void emit_opcode_trace(
		const std::function<void(const FFTSmdPlaybackTraceEvent&)> &trace_callback,
		int32_t tick,
		int32_t source_tick,
		int32_t source_event_index,
		int32_t track_idx,
		int32_t loop_depth,
		std::vector<int32_t> loop_source_ticks,
		std::vector<int32_t> loop_iteration_indices,
		const FFTSmdOpcodeEvent &event) {
	if (!trace_callback) {
		return;
	}
	trace_callback(FFTSmdPlaybackTraceEvent {
		.kind = FFTSmdPlaybackTraceKind::opcode,
		.tick = tick,
		.source_tick = source_tick,
		.source_event_index = source_event_index,
		.track_idx = track_idx,
		.loop_depth = loop_depth,
		.loop_source_ticks = std::move(loop_source_ticks),
		.loop_iteration_indices = std::move(loop_iteration_indices),
		.opcode = event.opcode,
		.value = event.params.empty() ? 0 : event.params[0],
		.secondary_value = event.params.size() > 1 ? event.params[1] : 0,
		.params = event.params,
		.label = trace_opcode_label(event),
	});
}

void emit_structure_trace(
		const std::function<void(const FFTSmdPlaybackTraceEvent&)> &trace_callback,
		int32_t tick,
		int32_t source_tick,
		int32_t source_event_index,
		int32_t track_idx,
		int32_t loop_depth,
		std::vector<int32_t> loop_source_ticks,
		std::vector<int32_t> loop_iteration_indices,
		int32_t opcode,
		const char *label,
		int32_t value = 0) {
	if (!trace_callback) {
		return;
	}
	trace_callback(FFTSmdPlaybackTraceEvent {
		.kind = FFTSmdPlaybackTraceKind::structure,
		.tick = tick,
		.source_tick = source_tick,
		.source_event_index = source_event_index,
		.track_idx = track_idx,
		.loop_depth = loop_depth,
		.loop_source_ticks = std::move(loop_source_ticks),
		.loop_iteration_indices = std::move(loop_iteration_indices),
		.opcode = opcode,
		.value = value,
		.label = label,
	});
}

}  // namespace

FFTSmdSequencerCore::FFTSmdSequencerCore(FFTSpuCoreRuntime *spu_core)
		: spu_core_(spu_core) {
	update_timing();
}

bool FFTSmdSequencerCore::load_sequence(const FFTSmdSequence &sequence, const std::vector<FFTSmdInstrumentInfo> &instruments) {
	if (spu_core_ == nullptr) {
		return false;
	}

	instruments_ = instruments;
	spu_core_->reset();
	tracks_.clear();
	tempo_bpm_ = fft_smd_tempo_to_bpm(sequence.initial_tempo);
	tick_accumulator_ = 0.0;
	total_ticks_ = 0;
	update_timing();

	tracks_.reserve(sequence.track_events.size());
	for (size_t i = 0; i < sequence.track_events.size(); ++i) {
		TrackState track_state;
		track_state.track_idx = static_cast<int32_t>(i);
		track_state.events = sequence.track_events[i];
		tracks_.push_back(track_state);
	}
	track_muted_.assign(sequence.track_events.size(), false);
	track_soloed_.assign(sequence.track_events.size(), false);
	voice_track_owner_.assign(static_cast<size_t>(kNumVoices), -1);

	return true;
}

void FFTSmdSequencerCore::set_trace_callback(
		std::function<void(const FFTSmdPlaybackTraceEvent&)> trace_callback) {
	trace_callback_ = std::move(trace_callback);
}

bool FFTSmdSequencerCore::tick() {
	if (all_done()) {
		return false;
	}

	for (TrackState &track_state : tracks_) {
		if (!track_state.done && track_state.note_ticks_remaining > 0) {
			track_state.note_ticks_remaining -= 1;
		}

		if (!track_state.done && track_state.note_ticks_remaining <= 0 &&
				track_state.current_note >= 0) {
			release_track_voice(track_state, true);
			track_state.current_note = -1;
			track_state.hold_note_for_retrigger = false;
		}

		if (!track_state.done && track_state.wait_ticks > 0) {
			track_state.wait_ticks -= 1;
		}

		if (track_state.end_bar_pending && track_state.current_note < 0 && track_state.wait_ticks <= 0) {
			track_state.done = true;
			track_state.end_bar_pending = false;
			continue;
		}

		if (track_state.wait_ticks <= 0 && !track_state.done) {
			advance_track(track_state);
		}
	}

	total_ticks_ += 1;
	return true;
}

std::vector<int16_t> FFTSmdSequencerCore::render_tick_pcm16() {
	const int32_t frame_count = consume_tick_frame_count();
	return render_frames_only_pcm16(frame_count);
}

int32_t FFTSmdSequencerCore::consume_tick_frame_count() {
	const int32_t frame_count = static_cast<int32_t>(tick_accumulator_ + samples_per_tick_);
	tick_accumulator_ = (tick_accumulator_ + samples_per_tick_) - static_cast<double>(frame_count);
	return frame_count;
}

std::vector<int16_t> FFTSmdSequencerCore::render_frames_only_pcm16(int32_t frame_count) {
	if (spu_core_ == nullptr || frame_count <= 0) {
		return {};
	}
	return spu_core_->render_interleaved_pcm16(frame_count);
}

bool FFTSmdSequencerCore::has_active_audio() const {
	return spu_core_ != nullptr && spu_core_->active_voice_count() > 0;
}

bool FFTSmdSequencerCore::all_done() const {
	return std::all_of(tracks_.begin(), tracks_.end(), [](const TrackState &track_state) {
		return track_state.done;
	});
}

std::vector<int32_t> FFTSmdSequencerCore::source_cursor_ticks() const {
	std::vector<int32_t> ticks;
	ticks.reserve(tracks_.size());
	for (const TrackState &track_state : tracks_) {
		ticks.push_back(compute_source_cursor_tick(track_state));
	}
	return ticks;
}

void FFTSmdSequencerCore::set_track_muted(int32_t track_idx, bool muted) {
	if (track_idx < 0 || static_cast<size_t>(track_idx) >= track_muted_.size()) {
		return;
	}
	track_muted_[static_cast<size_t>(track_idx)] = muted;
	if (static_cast<size_t>(track_idx) < tracks_.size()) {
		enforce_track_audibility(tracks_[static_cast<size_t>(track_idx)]);
	}
}

void FFTSmdSequencerCore::set_track_soloed(int32_t track_idx, bool soloed) {
	if (track_idx < 0 || static_cast<size_t>(track_idx) >= track_soloed_.size()) {
		return;
	}
	track_soloed_[static_cast<size_t>(track_idx)] = soloed;
	for (TrackState &track_state : tracks_) {
		enforce_track_audibility(track_state);
	}
}

bool FFTSmdSequencerCore::track_muted(int32_t track_idx) const {
	return track_idx >= 0 &&
		static_cast<size_t>(track_idx) < track_muted_.size() &&
		track_muted_[static_cast<size_t>(track_idx)];
}

bool FFTSmdSequencerCore::track_soloed(int32_t track_idx) const {
	return track_idx >= 0 &&
		static_cast<size_t>(track_idx) < track_soloed_.size() &&
		track_soloed_[static_cast<size_t>(track_idx)];
}

bool FFTSmdSequencerCore::track_audible(int32_t track_idx) const {
	if (track_idx < 0) {
		return false;
	}
	if (track_idx == 0) {
		return true;
	}
	const bool soloing = any_track_soloed();
	if (soloing) {
		return track_soloed(track_idx);
	}
	return !track_muted(track_idx);
}

void FFTSmdSequencerCore::update_timing() {
	const double bpm = tempo_bpm_ <= 0.0 ? 120.0 : tempo_bpm_;
	samples_per_tick_ = (static_cast<double>(kSampleRate) * 60.0) / (bpm * static_cast<double>(kFftSmdPpq));
}

void FFTSmdSequencerCore::advance_track(TrackState &track_state) {
	int32_t accumulated = 0;
	bool note_fired = false;

	while (!track_state.done && track_state.event_idx < static_cast<int32_t>(track_state.events.size())) {
		const FFTSmdTrackEvent &event = track_state.events[static_cast<size_t>(track_state.event_idx)];
		const int32_t current_event_idx = track_state.event_idx;
		const int32_t source_tick = compute_source_cursor_tick(track_state);

		if (std::holds_alternative<FFTSmdNoteEvent>(event)) {
			const FFTSmdNoteEvent &note_event = std::get<FFTSmdNoteEvent>(event);
			const bool is_note = note_event.relative_key < 12;
			const bool is_tie = note_event.relative_key == 12;
			const bool is_rest = note_event.relative_key == 13;

			if (is_note) {
				if (accumulated > 0 && !note_fired) {
					track_state.wait_ticks = accumulated;
					return;
				}

				track_state.event_idx += 1;
				note_fired = true;
				process_note(track_state, note_event);
				accumulated += note_event.delta_time;

				int32_t note_sustain = note_event.delta_time;
				while (track_state.event_idx < static_cast<int32_t>(track_state.events.size())) {
					const FFTSmdTrackEvent &next_event = track_state.events[static_cast<size_t>(track_state.event_idx)];
					if (std::holds_alternative<FFTSmdOpcodeEvent>(next_event)) {
						const FFTSmdOpcodeEvent &opcode_event = std::get<FFTSmdOpcodeEvent>(next_event);
						const int32_t next_event_idx = track_state.event_idx;
						if (opcode_event.opcode == 0x81) {
							emit_opcode_trace(
								trace_callback_,
								total_ticks_ + accumulated,
								source_tick + accumulated,
								next_event_idx,
								track_state.track_idx,
								static_cast<int32_t>(track_state.loop_stack.size()),
								current_loop_source_tick_path(track_state),
								current_loop_iteration_index_path(track_state),
								opcode_event);
							const int32_t duration = !opcode_event.params.empty() ? opcode_event.params[0] : 0;
							accumulated += duration;
							note_sustain += duration;
							track_state.event_idx += 1;
							continue;
						}
						if (opcode_event.opcode == 0x80) {
							emit_opcode_trace(
								trace_callback_,
								total_ticks_ + accumulated,
								source_tick + accumulated,
								next_event_idx,
								track_state.track_idx,
								static_cast<int32_t>(track_state.loop_stack.size()),
								current_loop_source_tick_path(track_state),
								current_loop_iteration_index_path(track_state),
								opcode_event);
							accumulated += !opcode_event.params.empty() ? opcode_event.params[0] : 0;
							track_state.event_idx += 1;
							continue;
						}

						track_state.event_idx += 1;
						process_opcode(
							track_state,
							opcode_event,
							total_ticks_ + accumulated,
							source_tick + accumulated,
							next_event_idx);
						if (track_state.done || track_state.end_bar_pending) {
							break;
						}
						continue;
					}
					break;
				}

				bool hold_for_retrigger = false;
				bool note_has_fermata = false;
				if (track_state.event_idx < static_cast<int32_t>(track_state.events.size())) {
					const FFTSmdTrackEvent &next_event = track_state.events[static_cast<size_t>(track_state.event_idx)];
					if (std::holds_alternative<FFTSmdNoteEvent>(next_event)) {
						const FFTSmdNoteEvent &next_note = std::get<FFTSmdNoteEvent>(next_event);
						hold_for_retrigger = next_note.relative_key < 12 && accumulated == note_sustain && !track_state.slur;
					}
				}
				note_has_fermata = note_sustain > note_event.delta_time;
				track_state.hold_note_for_retrigger = hold_for_retrigger;
				track_state.note_ticks_remaining = fft_smd_compute_note_life_ticks(note_sustain);
				const int32_t base_note_ticks = fft_smd_compute_note_life_ticks(note_event.delta_time);
				emit_trace_event(FFTSmdPlaybackTraceEvent {
					.kind = FFTSmdPlaybackTraceKind::note,
					.tick = total_ticks_,
					.source_tick = source_tick,
					.source_event_index = current_event_idx,
					.track_idx = track_state.track_idx,
					.loop_depth = static_cast<int32_t>(track_state.loop_stack.size()),
					.loop_source_ticks = current_loop_source_tick_path(track_state),
					.loop_iteration_indices = current_loop_iteration_index_path(track_state),
					.relative_key = note_event.relative_key,
					.duration_ticks = track_state.note_ticks_remaining,
					.has_fermata = note_has_fermata,
					.fermata_extension_ticks = std::max(0, track_state.note_ticks_remaining - base_note_ticks),
				});
				track_state.wait_ticks = accumulated;
				return;
			}

			track_state.event_idx += 1;
			if (is_rest) {
				emit_trace_event(FFTSmdPlaybackTraceEvent {
					.kind = FFTSmdPlaybackTraceKind::note,
					.tick = total_ticks_ + accumulated,
					.source_tick = source_tick,
					.source_event_index = current_event_idx,
					.track_idx = track_state.track_idx,
					.loop_depth = static_cast<int32_t>(track_state.loop_stack.size()),
					.loop_source_ticks = current_loop_source_tick_path(track_state),
					.loop_iteration_indices = current_loop_iteration_index_path(track_state),
					.relative_key = 13,
					.duration_ticks = std::max(1, note_event.delta_time),
				});
			}
			if (is_tie || is_rest) {
				accumulated += note_event.delta_time;
			}
			continue;
		}

		const FFTSmdOpcodeEvent &opcode_event = std::get<FFTSmdOpcodeEvent>(event);
		track_state.event_idx += 1;
		if (opcode_event.opcode == 0x80 || opcode_event.opcode == 0x81) {
			emit_opcode_trace(
				trace_callback_,
				total_ticks_ + accumulated,
				source_tick + accumulated,
				current_event_idx,
				track_state.track_idx,
				static_cast<int32_t>(track_state.loop_stack.size()),
				current_loop_source_tick_path(track_state),
				current_loop_iteration_index_path(track_state),
				opcode_event);
			accumulated += !opcode_event.params.empty() ? opcode_event.params[0] : 0;
		} else {
			process_opcode(
				track_state,
				opcode_event,
				total_ticks_ + accumulated,
				source_tick + accumulated,
				current_event_idx);
			if (track_state.done) {
				track_state.wait_ticks = accumulated;
				return;
			}
		}
	}

	if (!track_state.done) {
		if (track_state.loop_point >= 0) {
			track_state.event_idx = track_state.loop_point + 1;
		} else {
			track_state.done = true;
		}
	}
}

void FFTSmdSequencerCore::emit_trace_event(const FFTSmdPlaybackTraceEvent &event) const {
	if (trace_callback_) {
		trace_callback_(event);
	}
}

int32_t FFTSmdSequencerCore::compute_source_cursor_tick(const TrackState &track_state) const {
	int32_t tick = 0;
	const int32_t clamped_event_idx = std::clamp(track_state.event_idx, 0, static_cast<int32_t>(track_state.events.size()));
	for (int32_t i = 0; i < clamped_event_idx; ++i) {
		const auto &event = track_state.events[static_cast<size_t>(i)];
		if (std::holds_alternative<FFTSmdNoteEvent>(event)) {
			tick += std::get<FFTSmdNoteEvent>(event).delta_time;
		} else {
			const auto &opcode = std::get<FFTSmdOpcodeEvent>(event);
			if ((opcode.opcode == 0x80 || opcode.opcode == 0x81) && !opcode.params.empty()) {
				tick += opcode.params[0];
			}
		}
	}
	return std::max(0, tick - std::max(0, track_state.wait_ticks));
}

std::vector<int32_t> FFTSmdSequencerCore::current_loop_source_tick_path(const TrackState &track_state) const {
	std::vector<int32_t> path;
	path.reserve(track_state.loop_stack.size());
	for (const auto &frame : track_state.loop_stack) {
		path.push_back(frame.repeat_start_source_tick);
	}
	return path;
}

std::vector<int32_t> FFTSmdSequencerCore::current_loop_iteration_index_path(const TrackState &track_state) const {
	std::vector<int32_t> path;
	path.reserve(track_state.loop_stack.size());
	for (const auto &frame : track_state.loop_stack) {
		path.push_back(frame.current_iteration);
	}
	return path;
}

bool FFTSmdSequencerCore::any_track_soloed() const {
	return std::any_of(track_soloed_.begin(), track_soloed_.end(), [](bool soloed) {
		return soloed;
	});
}

void FFTSmdSequencerCore::enforce_track_audibility(TrackState &track_state) {
	if (track_audible(track_state.track_idx)) {
		return;
	}
	release_track_voice(track_state, true);
	track_state.current_note = -1;
	track_state.note_ticks_remaining = 0;
	track_state.hold_note_for_retrigger = false;
}

int32_t FFTSmdSequencerCore::allocate_voice_for_track(TrackState &track_state) {
	if (spu_core_ == nullptr) {
		return -1;
	}
	if (track_state.voice_idx >= 0 && track_state.voice_idx < kNumVoices) {
		return track_state.voice_idx;
	}

	for (size_t voice_idx = 0; voice_idx < voice_track_owner_.size(); ++voice_idx) {
		if (voice_track_owner_[voice_idx] < 0) {
			voice_track_owner_[voice_idx] = track_state.track_idx;
			track_state.voice_idx = static_cast<int32_t>(voice_idx);
			track_state.last_key_on_tick = total_ticks_;
			return track_state.voice_idx;
		}
	}

	int32_t best_voice_idx = -1;
	int32_t best_tick = std::numeric_limits<int32_t>::max();
	for (size_t voice_idx = 0; voice_idx < voice_track_owner_.size(); ++voice_idx) {
		const int32_t owner = voice_track_owner_[voice_idx];
		if (owner < 0 || static_cast<size_t>(owner) >= tracks_.size()) {
			continue;
		}
		const TrackState &owner_track = tracks_[static_cast<size_t>(owner)];
		if (owner_track.last_key_on_tick < best_tick) {
			best_tick = owner_track.last_key_on_tick;
			best_voice_idx = static_cast<int32_t>(voice_idx);
		}
	}
	if (best_voice_idx < 0) {
		return -1;
	}

	const int32_t previous_owner = voice_track_owner_[static_cast<size_t>(best_voice_idx)];
	if (previous_owner >= 0 && static_cast<size_t>(previous_owner) < tracks_.size()) {
		TrackState &owner_track = tracks_[static_cast<size_t>(previous_owner)];
		release_track_voice(owner_track, true);
		owner_track.current_note = -1;
		owner_track.note_ticks_remaining = 0;
		owner_track.hold_note_for_retrigger = false;
	}

	voice_track_owner_[static_cast<size_t>(best_voice_idx)] = track_state.track_idx;
	track_state.voice_idx = best_voice_idx;
	track_state.last_key_on_tick = total_ticks_;
	return track_state.voice_idx;
}

void FFTSmdSequencerCore::release_track_voice(TrackState &track_state, bool key_off) {
	if (track_state.voice_idx < 0 || track_state.voice_idx >= kNumVoices) {
		track_state.voice_idx = -1;
		return;
	}
	if (key_off && spu_core_ != nullptr) {
		spu_core_->key_off(track_state.voice_idx);
	}
	if (static_cast<size_t>(track_state.voice_idx) < voice_track_owner_.size() &&
			voice_track_owner_[static_cast<size_t>(track_state.voice_idx)] == track_state.track_idx) {
		voice_track_owner_[static_cast<size_t>(track_state.voice_idx)] = -1;
	}
	track_state.voice_idx = -1;
}

void FFTSmdSequencerCore::process_note(TrackState &track_state, const FFTSmdNoteEvent &event) {
	if (spu_core_ == nullptr) {
		return;
	}

		if (event.relative_key < 12) {
			if (track_state.current_note >= 0 && !track_state.slur) {
				release_track_voice(track_state, true);
				track_state.current_note = -1;
				track_state.hold_note_for_retrigger = false;
			}

		FFTSmdInstrumentInfo instrument_info;
		if (track_state.instrument >= 0 && track_state.instrument < static_cast<int32_t>(instruments_.size())) {
			instrument_info = instruments_[track_state.instrument];
		}
		const FFTSmdTrackStateView track_view {
			.octave = track_state.octave,
			.instrument = track_state.instrument,
			.volume = track_state.volume,
			.pan = track_state.pan,
			.reverb = track_state.reverb,
			.adsr_attack_override = track_state.adsr_attack_override,
			.adsr_sustain_rate_override = track_state.adsr_sustain_rate_override,
			.adsr_release_override = track_state.adsr_release_override,
			.adsr_decay_override = track_state.adsr_decay_override,
			.adsr_sustain_level_override = track_state.adsr_sustain_level_override,
			.adsr1_low_override = track_state.adsr1_low_slide_target,
		};
		const FFTSmdResolvedNoteTrigger resolved = fft_smd_resolve_note_trigger(
				track_view, instrument_info, event.relative_key, event.velocity, kMasterVol, FFTSpuCoreRuntime::kRamInstrumentBase);
		if (track_audible(track_state.track_idx) && resolved.has_sample) {
			const int32_t voice_idx = allocate_voice_for_track(track_state);
			if (voice_idx >= 0) {
				emit_trace_event(FFTSmdPlaybackTraceEvent {
					.kind = FFTSmdPlaybackTraceKind::key_on,
					.tick = total_ticks_,
					.track_idx = track_state.track_idx,
					.relative_key = event.relative_key,
					.midi_note = resolved.midi_note,
					.velocity = event.velocity,
					.instrument_idx = track_state.instrument,
					.fine_tune = instrument_info.fine_tune,
					.pre_pitch = resolved.pre_pitch,
					.raw_pitch = resolved.raw_pitch,
					.start_addr = resolved.addresses.start_addr,
					.loop_addr = resolved.addresses.loop_addr,
					.end_addr = resolved.addresses.end_addr,
				});
				spu_core_->set_voice_pre_pitch(voice_idx, resolved.pre_pitch);
				spu_core_->set_voice_mix_controls(voice_idx, resolved.mix_volume_base,
						resolved.mix_velocity_gain, resolved.mix_pan_base,
						resolved.mix_master_gain, resolved.mix_global_pan);
				spu_core_->key_on_with_addresses(voice_idx, track_state.instrument, resolved.raw_pitch,
					resolved.vol_l, resolved.vol_r, resolved.adsr1, resolved.adsr2,
					resolved.addresses.start_addr, resolved.addresses.loop_addr, track_state.reverb);
				track_state.current_note = resolved.midi_note;
			} else {
				track_state.current_note = -1;
			}
		} else {
			track_state.current_note = -1;
		}
		track_state.wait_ticks = event.delta_time;
		return;
	}

	if (event.relative_key == 12) {
		track_state.wait_ticks += event.delta_time;
	} else {
		track_state.wait_ticks = event.delta_time;
	}
}

void FFTSmdSequencerCore::process_opcode(
		TrackState &track_state,
		const FFTSmdOpcodeEvent &event,
		int32_t effective_tick,
		int32_t source_tick,
		int32_t source_event_index) {
	const int32_t op = event.opcode;
	const std::vector<int32_t> &params = event.params;

	if (op == 0x80) {
		track_state.wait_ticks = !params.empty() ? params[0] : 0;
	} else if (op == 0x81) {
		track_state.note_ticks_remaining += !params.empty() ? params[0] : 0;
	} else if (op == 0x90) {
		emit_structure_trace(
			trace_callback_,
			effective_tick,
			source_tick,
			source_event_index,
			track_state.track_idx,
			static_cast<int32_t>(track_state.loop_stack.size()),
			current_loop_source_tick_path(track_state),
			current_loop_iteration_index_path(track_state),
			op,
			"End");
		if (track_state.current_note >= 0) {
			track_state.end_bar_pending = true;
		} else {
			track_state.done = true;
		}
	} else if (op == 0x91) {
		emit_structure_trace(
			trace_callback_,
			effective_tick,
			source_tick,
			source_event_index,
			track_state.track_idx,
			static_cast<int32_t>(track_state.loop_stack.size()),
			current_loop_source_tick_path(track_state),
			current_loop_iteration_index_path(track_state),
			op,
			"LoopTrk");
		track_state.loop_point = track_state.event_idx;
	} else if (op == 0x94) {
		track_state.octave = !params.empty() ? params[0] : 4;
	} else if (op == 0x95) {
		track_state.octave += 1;
	} else if (op == 0x96) {
		track_state.octave -= 1;
	} else if (op == 0x98) {
		const int32_t repeat_count = !params.empty() ? std::max(1, params[0]) : 1;
		const int32_t remaining_repeats = std::max(0, repeat_count - 1);
		emit_structure_trace(
			trace_callback_,
			effective_tick,
			source_tick,
			source_event_index,
			track_state.track_idx,
			static_cast<int32_t>(track_state.loop_stack.size()) + 1,
			[&]() {
				auto path = current_loop_source_tick_path(track_state);
				path.push_back(source_tick);
				return path;
			}(),
			[&]() {
				auto path = current_loop_iteration_index_path(track_state);
				path.push_back(0);
				return path;
			}(),
			op,
			"RptStart",
			repeat_count);
		track_state.loop_stack.push_back(LoopFrame {
			.repeat_start_event_idx = track_state.event_idx,
			.repeat_start_source_tick = source_tick,
			.remaining_repeats = remaining_repeats,
			.current_iteration = 0,
			.octave = track_state.octave,
		});
	} else if (op == 0x99) {
		emit_structure_trace(
			trace_callback_,
			effective_tick,
			source_tick,
			source_event_index,
			track_state.track_idx,
			static_cast<int32_t>(track_state.loop_stack.size()),
			current_loop_source_tick_path(track_state),
			current_loop_iteration_index_path(track_state),
			op,
			"RptEnd");
		if (!track_state.loop_stack.empty()) {
			LoopFrame &entry = track_state.loop_stack.back();
			if (entry.remaining_repeats > 0) {
				entry.remaining_repeats -= 1;
				entry.current_iteration += 1;
				track_state.octave = entry.octave;
				track_state.event_idx = entry.repeat_start_event_idx;
				return;
			}
			track_state.loop_stack.pop_back();
		}
	} else if (op == 0x9A) {
		emit_structure_trace(
			trace_callback_,
			effective_tick,
			source_tick,
			source_event_index,
			track_state.track_idx,
			static_cast<int32_t>(track_state.loop_stack.size()),
			current_loop_source_tick_path(track_state),
			current_loop_iteration_index_path(track_state),
			op,
			"RptBreak");
		if (!track_state.loop_stack.empty()) {
			const LoopFrame &entry = track_state.loop_stack.back();
			if (entry.remaining_repeats == 0) {
				int32_t depth = 1;
				int32_t search = track_state.event_idx + 1;
				while (search < static_cast<int32_t>(track_state.events.size()) && depth > 0) {
					const FFTSmdTrackEvent &search_event = track_state.events[static_cast<size_t>(search)];
					if (std::holds_alternative<FFTSmdOpcodeEvent>(search_event)) {
						const FFTSmdOpcodeEvent &search_opcode = std::get<FFTSmdOpcodeEvent>(search_event);
						if (search_opcode.opcode == 0x98) {
							depth += 1;
						} else if (search_opcode.opcode == 0x99) {
							depth -= 1;
						}
					}
					search += 1;
				}
				track_state.event_idx = search;
				track_state.loop_stack.pop_back();
				return;
			}
		}
	} else if (op == 0xA0) {
		emit_trace_event(FFTSmdPlaybackTraceEvent {
			.kind = FFTSmdPlaybackTraceKind::tempo,
			.tick = effective_tick,
			.source_tick = source_tick,
			.source_event_index = source_event_index,
			.track_idx = track_state.track_idx,
			.loop_depth = static_cast<int32_t>(track_state.loop_stack.size()),
			.loop_source_ticks = current_loop_source_tick_path(track_state),
			.loop_iteration_indices = current_loop_iteration_index_path(track_state),
			.opcode = op,
			.value = !params.empty() ? params[0] : 0,
			.label = !params.empty() ? ("T" + std::to_string(params[0])) : std::string("T"),
		});
		tempo_bpm_ = !params.empty() ? fft_smd_tempo_to_bpm(params[0]) : 120.0;
		update_timing();
	} else if (op == 0xAC) {
		track_state.instrument = !params.empty() ? (params[0] + 1) : 0;
	} else if (op == 0xB0) {
		track_state.slur = true;
	} else if (op == 0xB1) {
		track_state.slur = false;
	} else if (op == 0xBA) {
		track_state.reverb = true;
	} else if (op == 0xBB) {
		track_state.reverb = false;
	} else if (op == 0xC0) {
		track_state.adsr_attack_override = -1;
		track_state.adsr_sustain_rate_override = -1;
		track_state.adsr_release_override = -1;
		track_state.adsr_decay_override = -1;
		track_state.adsr_sustain_level_override = -1;
		track_state.adsr1_low_slide_target = -1;
		track_state.adsr1_low_slide_pending = false;
	} else if (op == 0xC2) {
		track_state.adsr_attack_override = !params.empty() ? params[0] : -1;
	} else if (op == 0xC4) {
		track_state.adsr_sustain_rate_override = !params.empty() ? params[0] : -1;
	} else if (op == 0xC5) {
		track_state.adsr_release_override = !params.empty() ? params[0] : -1;
	} else if (op == 0xC6) {
		track_state.adsr1_low_slide_target = !params.empty() ? (params[0] & 0xF) : -1;
		track_state.adsr1_low_slide_pending = track_state.adsr1_low_slide_target >= 0;
		track_state.adsr_sustain_level_override = track_state.adsr1_low_slide_target;
		if (track_state.voice_idx >= 0 && track_state.adsr1_low_slide_target >= 0) {
			spu_core_->set_voice_adsr1_low(track_state.voice_idx, track_state.adsr1_low_slide_target);
		}
	} else if (op == 0xC7) {
		if (!params.empty()) {
			track_state.adsr_decay_override = params[0];
		}
		if (params.size() > 1) {
			track_state.adsr_sustain_level_override = params[1];
		}
	} else if (op == 0xE4) {
		if (track_state.voice_idx >= 0) {
			if (params.size() >= 3 && params[0] != 0 && fft_smd_signed_byte(params[1]) != 0) {
				spu_core_->init_voice_volume_lfo(track_state.voice_idx, params[0], fft_smd_signed_byte(params[1]), params[2]);
			} else {
				spu_core_->clear_voice_volume_lfo(track_state.voice_idx);
			}
		}
	} else if (op == 0xE3) {
		if (track_state.voice_idx >= 0 && !params.empty() && params[0] != 0xFF) {
			const int32_t depth = 0x100 / (params[0] + 1);
			spu_core_->set_voice_volume_lfo_depth(track_state.voice_idx, depth, depth);
		}
	} else if (op == 0xD8) {
		if (track_state.voice_idx >= 0) {
			if (params.size() >= 3 && params[0] != 0 && fft_smd_signed_byte(params[1]) != 0) {
				spu_core_->init_voice_pitch_lfo(track_state.voice_idx, params[0], fft_smd_signed_byte(params[1]), params[2]);
			} else {
				spu_core_->clear_voice_pitch_lfo(track_state.voice_idx);
			}
		}
	} else if (op == 0xD7) {
		if (track_state.voice_idx >= 0 && !params.empty() && params[0] != 0xFF) {
			const int32_t depth = 0x100 / (params[0] + 1);
			spu_core_->set_voice_pitch_lfo_depth(track_state.voice_idx, depth, depth);
		}
	} else if (op == 0xC9) {
		track_state.adsr_decay_override = !params.empty() ? params[0] : -1;
	} else if (op == 0xCA) {
		track_state.adsr_sustain_level_override = !params.empty() ? params[0] : -1;
	} else if (op == 0xE0) {
		track_state.volume = !params.empty() ? params[0] : 127;
	} else if (op == 0xE8) {
		track_state.pan = !params.empty() ? params[0] : 64;
	} else if (op == 0x97) {
		track_state.time_sig_numerator = !params.empty() ? params[0] : 4;
		track_state.time_sig_denominator = params.size() > 1 ? params[1] : 4;
	} else if (op == 0xDA) {
		track_state.flag_0xFE = true;
	} else if (op == 0xDB) {
		track_state.flag_0xFE = false;
	} else if (op == 0xE6) {
		track_state.flag_0x11E = true;
	}

	if (op != 0x90 && op != 0x91 && op != 0x98 && op != 0x99 && op != 0x9A && op != 0xA0) {
		emit_opcode_trace(
			trace_callback_,
			effective_tick,
			source_tick,
			source_event_index,
			track_state.track_idx,
			static_cast<int32_t>(track_state.loop_stack.size()),
			current_loop_source_tick_path(track_state),
			current_loop_iteration_index_path(track_state),
			event);
	}
}

}  // namespace fftshared
