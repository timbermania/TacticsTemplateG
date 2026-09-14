#include "fft_smd_sequencer_native.h"

#include <algorithm>
#include <cstdint>
#include <utility>

#include "fft_pitch_tools.h"

#include <godot_cpp/core/method_bind.hpp>
#include <godot_cpp/variant/dictionary.hpp>

using namespace godot;

namespace {

String trace_kind_name(fftshared::FFTSmdPlaybackTraceKind kind) {
	switch (kind) {
		case fftshared::FFTSmdPlaybackTraceKind::note:
			return "note";
		case fftshared::FFTSmdPlaybackTraceKind::key_on:
			return "key_on";
		case fftshared::FFTSmdPlaybackTraceKind::opcode:
			return "opcode";
		case fftshared::FFTSmdPlaybackTraceKind::structure:
			return "structure";
		case fftshared::FFTSmdPlaybackTraceKind::tempo:
			return "tempo";
		default:
			return "unknown";
	}
}

}  // namespace

void FFTSmdSequencerNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_reverb_algorithm", "algorithm"), &FFTSmdSequencerNative::set_reverb_algorithm);
	ClassDB::bind_method(D_METHOD("get_reverb_algorithm"), &FFTSmdSequencerNative::get_reverb_algorithm);
	ClassDB::bind_method(D_METHOD("set_debug_trace_enabled", "enabled"), &FFTSmdSequencerNative::set_debug_trace_enabled);
	ClassDB::bind_method(D_METHOD("is_debug_trace_enabled"), &FFTSmdSequencerNative::is_debug_trace_enabled);
	ClassDB::bind_method(D_METHOD("get_debug_trace"), &FFTSmdSequencerNative::get_debug_trace);
	ClassDB::bind_method(D_METHOD("clear_debug_trace"), &FFTSmdSequencerNative::clear_debug_trace);
	ClassDB::bind_method(D_METHOD("load_instruments", "instruments", "adpcm_bank"), &FFTSmdSequencerNative::load_instruments);
	ClassDB::bind_method(D_METHOD("load_sequence", "initial_tempo", "track_events"), &FFTSmdSequencerNative::load_sequence);
	ClassDB::bind_method(D_METHOD("tick"), &FFTSmdSequencerNative::tick);
	ClassDB::bind_method(D_METHOD("render_tick_pcm16"), &FFTSmdSequencerNative::render_tick_pcm16);
	ClassDB::bind_method(D_METHOD("render_frames_only_pcm16", "frame_count"), &FFTSmdSequencerNative::render_frames_only_pcm16);
	ClassDB::bind_method(D_METHOD("has_active_audio"), &FFTSmdSequencerNative::has_active_audio);
	ClassDB::bind_method(D_METHOD("all_done"), &FFTSmdSequencerNative::all_done);
	ClassDB::bind_method(D_METHOD("get_active_voice_count"), &FFTSmdSequencerNative::get_active_voice_count);
	ClassDB::bind_method(D_METHOD("get_tempo_bpm"), &FFTSmdSequencerNative::get_tempo_bpm);
	ClassDB::bind_method(D_METHOD("get_samples_per_tick"), &FFTSmdSequencerNative::get_samples_per_tick);
	ClassDB::bind_method(D_METHOD("get_tick_accumulator"), &FFTSmdSequencerNative::get_tick_accumulator);
	ClassDB::bind_method(D_METHOD("get_total_ticks"), &FFTSmdSequencerNative::get_total_ticks);
	ClassDB::bind_method(D_METHOD("set_sampled_voice_trace_enabled", "enabled"), &FFTSmdSequencerNative::set_sampled_voice_trace_enabled);
	ClassDB::bind_method(D_METHOD("is_sampled_voice_trace_enabled"), &FFTSmdSequencerNative::is_sampled_voice_trace_enabled);
	ClassDB::bind_method(D_METHOD("set_sampled_voice_trace_dense", "enabled"), &FFTSmdSequencerNative::set_sampled_voice_trace_dense);
	ClassDB::bind_method(D_METHOD("is_sampled_voice_trace_dense"), &FFTSmdSequencerNative::is_sampled_voice_trace_dense);
	ClassDB::bind_method(D_METHOD("set_sampled_voice_trace_voices", "voice_indices"), &FFTSmdSequencerNative::set_sampled_voice_trace_voices);
	ClassDB::bind_method(D_METHOD("clear_sampled_voice_trace"), &FFTSmdSequencerNative::clear_sampled_voice_trace);
	ClassDB::bind_method(D_METHOD("get_sampled_voice_trace"), &FFTSmdSequencerNative::get_sampled_voice_trace);
}

PackedInt32Array FFTSmdSequencerNative::to_packed_pcm(const std::vector<int16_t> &pcm) {
	PackedInt32Array out;
	out.resize(static_cast<int>(pcm.size()));
	int32_t *write = out.ptrw();
	for (int i = 0; i < static_cast<int>(pcm.size()); ++i) {
		write[i] = pcm[static_cast<size_t>(i)];
	}
	return out;
}

int FFTSmdSequencerNative::clip_pcm16(int value) {
	return std::clamp(value, -32767, 32767);
}

FFTSmdSequencerNative::FFTSmdSequencerNative()
		: sequencer_(&core_) {
	// This driver stages pitch in note space (fft_smd_sequencer_tools.cpp
	// resolves a MIDI note + fine-tune into voice.pre_pitch), so it is the side
	// that owns the note->raw mapping. Install it on our own SPU core; the SPU
	// itself ships no note space at all (#384 / D1 dec. 1).
	core_.set_pitch_remap(&fftshared::fft_raw_pitch_from_pre_pitch);
	sampled_voice_trace_mask_.fill(true);
	sequencer_.set_trace_callback([this](const fftshared::FFTSmdPlaybackTraceEvent &event) {
		on_trace_event(event);
	});
}

void FFTSmdSequencerNative::clear_debug_trace_internal() {
	debug_trace_.clear();
}

void FFTSmdSequencerNative::clear_sampled_voice_trace_internal() {
	sampled_voice_trace_.clear();
	for (SampleTraceState &state : sampled_voice_prev_) {
		state = SampleTraceState();
	}
}

void FFTSmdSequencerNative::set_reverb_algorithm(const String &algorithm) {
	const String lowered = algorithm.to_lower();
	if (lowered == "xebra") {
		core_.set_reverb_algorithm(fftshared::FFTSpuReverbAlgorithm::kXebra);
		return;
	}
	core_.set_reverb_algorithm(fftshared::FFTSpuReverbAlgorithm::kCurrent);
}

String FFTSmdSequencerNative::get_reverb_algorithm() const {
	return String(core_.reverb_algorithm_name());
}

void FFTSmdSequencerNative::set_debug_trace_enabled(bool enabled) {
	debug_trace_enabled_ = enabled;
	clear_debug_trace_internal();
}

bool FFTSmdSequencerNative::is_debug_trace_enabled() const {
	return debug_trace_enabled_;
}

Array FFTSmdSequencerNative::get_debug_trace() const {
	Array out;
	out.resize(static_cast<int>(debug_trace_.size()));
	for (int i = 0; i < static_cast<int>(debug_trace_.size()); ++i) {
		out[i] = debug_trace_[static_cast<size_t>(i)];
	}
	return out;
}

void FFTSmdSequencerNative::clear_debug_trace() {
	clear_debug_trace_internal();
}

void FFTSmdSequencerNative::on_trace_event(const fftshared::FFTSmdPlaybackTraceEvent &event) {
	if (!debug_trace_enabled_) {
		return;
	}

	Dictionary row;
	row["kind"] = trace_kind_name(event.kind);
	row["tick"] = event.tick;
	row["frame"] = rendered_frames_total_;
	row["tempo_bpm"] = sequencer_.tempo_bpm();
	row["track"] = event.track_idx;
	row["voice"] = event.track_idx > 0 ? (event.track_idx - 1) : -1;
	row["label"] = String(event.label.c_str());

	if (event.kind == fftshared::FFTSmdPlaybackTraceKind::opcode) {
		row["opcode"] = event.opcode;
		row["opcode_name"] = String(event.label.c_str());
		Array params;
		params.resize(static_cast<int>(event.params.size()));
		for (int i = 0; i < static_cast<int>(event.params.size()); ++i) {
			params[i] = event.params[static_cast<size_t>(i)];
		}
		row["params"] = params;
	} else if (event.kind == fftshared::FFTSmdPlaybackTraceKind::tempo) {
		row["opcode"] = event.opcode;
		row["value"] = event.value;
	} else if (event.kind == fftshared::FFTSmdPlaybackTraceKind::key_on) {
		row["relative_key"] = event.relative_key;
		row["midi_note"] = event.midi_note;
		row["velocity"] = event.velocity;
		row["instrument_idx"] = event.instrument_idx;
		row["fine_tune"] = event.fine_tune;
		row["pre_pitch"] = event.pre_pitch;
		row["raw_pitch"] = event.raw_pitch;
		row["start_addr"] = event.start_addr;
		row["loop_addr"] = event.loop_addr;
		row["end_addr"] = event.end_addr;
	} else if (event.kind == fftshared::FFTSmdPlaybackTraceKind::note) {
		row["relative_key"] = event.relative_key;
		row["duration_ticks"] = event.duration_ticks;
		row["has_fermata"] = event.has_fermata;
		row["fermata_extension_ticks"] = event.fermata_extension_ticks;
	}

	debug_trace_.push_back(row);
}

bool FFTSmdSequencerNative::load_instruments(const Array &p_instruments, const PackedByteArray &p_adpcm_bank) {
	std::vector<fftshared::FFTSpuCoreRuntime::InstrumentData> spu_instruments;
	spu_instruments.reserve(p_instruments.size());
	smd_instruments_.clear();
	smd_instruments_.reserve(p_instruments.size());

	for (int i = 0; i < p_instruments.size(); ++i) {
		const Dictionary dict = p_instruments[i];
		fftshared::FFTSpuCoreRuntime::InstrumentData spu_inst;
		fftshared::FFTSmdInstrumentInfo smd_inst;
		spu_inst.is_null = dict.has("is_null") ? bool(dict["is_null"]) : true;
		spu_inst.fine_tune = dict.has("fine_tune") ? int(dict["fine_tune"]) : 0;
		spu_inst.adsr1 = dict.has("adsr1") ? int(dict["adsr1"]) : 0;
		spu_inst.adsr2 = dict.has("adsr2") ? int(dict["adsr2"]) : 0;
		spu_inst.sample_offset = dict.has("sample_offset") ? int(dict["sample_offset"]) : 0;
		spu_inst.sample_size = dict.has("sample_size") ? int(dict["sample_size"]) : 0;
		spu_inst.loop_start = dict.has("loop_start") ? int(dict["loop_start"]) : -1;
		spu_inst.loop_offset_bytes = dict.has("loop_offset_bytes") ? int(dict["loop_offset_bytes"]) : -1;
		spu_inst.has_explicit_loop_start = dict.has("has_explicit_loop_start") ? bool(dict["has_explicit_loop_start"]) : false;
		spu_inst.has_loop_repeat = dict.has("has_loop_repeat") ? bool(dict["has_loop_repeat"]) : false;
		spu_inst.start_offset_bytes = dict.has("start_offset_bytes") ? int(dict["start_offset_bytes"]) : 0;
		spu_instruments.push_back(spu_inst);

		smd_inst.is_null = spu_inst.is_null;
		smd_inst.fine_tune = spu_inst.fine_tune;
		smd_inst.adsr1 = spu_inst.adsr1;
		smd_inst.adsr2 = spu_inst.adsr2;
		smd_inst.loop_start = spu_inst.loop_start;
		smd_inst.sample_offset = spu_inst.sample_offset;
		smd_inst.sample_size = spu_inst.sample_size;
		smd_inst.loop_offset_bytes = spu_inst.loop_offset_bytes;
		smd_inst.has_explicit_loop_start = spu_inst.has_explicit_loop_start;
		smd_inst.has_loop_repeat = spu_inst.has_loop_repeat;
		smd_inst.start_offset_bytes = spu_inst.start_offset_bytes;
		smd_inst.start_sample_skip = dict.has("start_sample_skip") ? int(dict["start_sample_skip"]) : 0;
		smd_instruments_.push_back(smd_inst);
	}

	return core_.load_instruments(spu_instruments, p_adpcm_bank.ptr(), p_adpcm_bank.size());
}

bool FFTSmdSequencerNative::load_sequence(int initial_tempo, const Array &track_events) {
	fftshared::FFTSmdSequence sequence;
	sequence.initial_tempo = initial_tempo;
	sequence.track_count = track_events.size();
	sequence.track_events.resize(track_events.size());

	for (int track_idx = 0; track_idx < track_events.size(); ++track_idx) {
		const Array track = track_events[track_idx];
		std::vector<fftshared::FFTSmdTrackEvent> native_track;
		native_track.reserve(track.size());
		for (int event_idx = 0; event_idx < track.size(); ++event_idx) {
			const Dictionary event = track[event_idx];
			const String kind = event.get("kind", "");
			if (kind == "note") {
				fftshared::FFTSmdNoteEvent note_event;
				note_event.velocity = int(event.get("velocity", 0));
				note_event.relative_key = int(event.get("relative_key", 13));
				note_event.delta_time = int(event.get("delta_time", 0));
				native_track.push_back(note_event);
			} else if (kind == "opcode") {
				fftshared::FFTSmdOpcodeEvent opcode_event;
				opcode_event.opcode = int(event.get("opcode", 0));
				const PackedInt32Array params = event.get("params", PackedInt32Array());
				opcode_event.params.reserve(params.size());
				for (int i = 0; i < params.size(); ++i) {
					opcode_event.params.push_back(params[i]);
				}
				native_track.push_back(opcode_event);
			}
		}
		sequence.track_events[static_cast<size_t>(track_idx)] = std::move(native_track);
	}

	rendered_sample_count_ = 0;
	rendered_frames_total_ = 0;
	clear_debug_trace_internal();
	clear_sampled_voice_trace_internal();
	return sequencer_.load_sequence(sequence, smd_instruments_);
}

bool FFTSmdSequencerNative::tick() {
	return sequencer_.tick();
}

bool FFTSmdSequencerNative::should_trace_voice_event(int voice_idx) const {
	return sampled_voice_trace_enabled_ &&
		voice_idx >= 0 &&
		voice_idx < fftshared::FFTSpuCoreRuntime::kNumVoices &&
		sampled_voice_trace_mask_[static_cast<size_t>(voice_idx)];
}

FFTSmdSequencerNative::SampleTraceState FFTSmdSequencerNative::build_sample_trace_state(
		const fftshared::FFTSpuCoreRuntime::Voice &voice, int env_vol, int sample) const {
	SampleTraceState next;
	next.valid = true;
	next.on = voice.on;
	next.stop = voice.stop_requested;
	next.instrument_idx = voice.instrument_idx;
	next.raw_pitch = voice.raw_pitch;
	next.left_volume = voice.left_volume;
	next.right_volume = voice.right_volume;
	next.start_addr = voice.start_addr;
	next.loop_addr = voice.loop_addr;
	next.requested_loop_addr = voice.requested_loop_addr;
	next.curr_addr = voice.curr_addr;
	next.env_state = static_cast<int>(voice.adsr.state);
	next.env_vol = env_vol;
	next.sample = sample;
	next.decoded_sample = voice.latest_sample;
	next.interp_sample = voice.latest_interp_sample;
	next.adsr1 = voice.adsr1;
	next.adsr2 = voice.adsr2;
	return next;
}

bool FFTSmdSequencerNative::sample_trace_changed(int voice_idx, const SampleTraceState &next) const {
	const SampleTraceState &prev = sampled_voice_prev_[static_cast<size_t>(voice_idx)];
	return !prev.valid ||
		prev.on != next.on ||
		prev.stop != next.stop ||
		prev.instrument_idx != next.instrument_idx ||
		prev.raw_pitch != next.raw_pitch ||
		prev.left_volume != next.left_volume ||
		prev.right_volume != next.right_volume ||
		prev.start_addr != next.start_addr ||
		prev.loop_addr != next.loop_addr ||
		prev.requested_loop_addr != next.requested_loop_addr ||
		prev.curr_addr != next.curr_addr ||
		prev.env_state != next.env_state ||
		prev.env_vol != next.env_vol ||
		prev.sample != next.sample ||
		prev.decoded_sample != next.decoded_sample ||
		prev.interp_sample != next.interp_sample ||
		prev.adsr1 != next.adsr1 ||
		prev.adsr2 != next.adsr2;
}

Dictionary FFTSmdSequencerNative::build_sample_trace_row(int voice_idx, uint64_t sample_index,
		const fftshared::FFTSpuCoreRuntime::Voice &voice, const SampleTraceState &next) const {
	Dictionary row;
	row["kind"] = "voice_event";
	row["voice"] = voice_idx;
	row["sample_index"] = static_cast<int64_t>(sample_index);
	row["on"] = next.on;
	row["stop"] = next.stop;
	row["instrument_idx"] = next.instrument_idx;
	row["raw_pitch"] = next.raw_pitch;
	row["left_volume"] = next.left_volume;
	row["right_volume"] = next.right_volume;
	row["start_addr"] = next.start_addr;
	row["loop_addr"] = next.loop_addr;
	row["requested_loop_addr"] = next.requested_loop_addr;
	row["curr_addr"] = next.curr_addr;
	row["env_state"] = next.env_state;
	row["env_vol"] = next.env_vol;
	row["sample"] = next.sample;
	row["decoded_sample"] = next.decoded_sample;
	row["interp_sample"] = next.interp_sample;
	row["adsr1"] = next.adsr1;
	row["adsr2"] = next.adsr2;
	row["buf_pos"] = voice.buf_pos;
	row["spos"] = voice.spos;
	row["gauss_pos"] = voice.gauss_pos;
	row["adpcm_s1"] = voice.adpcm_s1;
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

void FFTSmdSequencerNative::trace_voice_event(int voice_idx, uint64_t sample_index,
		const fftshared::FFTSpuCoreRuntime::Voice &voice, int env_vol, int sample) {
	if (!should_trace_voice_event(voice_idx)) {
		return;
	}

	const SampleTraceState next = build_sample_trace_state(voice, env_vol, sample);
	if (!sampled_voice_trace_dense_ && !sample_trace_changed(voice_idx, next)) {
		return;
	}

	sampled_voice_trace_.push_back(build_sample_trace_row(voice_idx, sample_index, voice, next));
	sampled_voice_prev_[static_cast<size_t>(voice_idx)] = next;
}

void FFTSmdSequencerNative::trace_inactive_voices(uint64_t sample_index) {
	if (!sampled_voice_trace_enabled_) {
		return;
	}
	const std::vector<fftshared::FFTSpuCoreRuntime::Voice> &voices = core_.voices();
	for (int voice_idx = 0; voice_idx < static_cast<int>(voices.size()); ++voice_idx) {
		const auto &voice = voices[static_cast<size_t>(voice_idx)];
		if (voice.on) {
			continue;
		}
		trace_voice_event(voice_idx, sample_index, voice, 0, 0);
	}
}

PackedInt32Array FFTSmdSequencerNative::render_interleaved_with_trace(int frame_count) {
	PackedInt32Array output;
	output.resize(frame_count * 2);
	int32_t *write = output.ptrw();

	for (int frame = 0; frame < frame_count; ++frame) {
		core_.advance_lfo_tick();

		const fftshared::FFTSpuFrameRenderResult frame_result = core_.render_mix_frame(-1);
		const std::vector<fftshared::FFTSpuCoreRuntime::Voice> &voices = core_.voices();
		const std::vector<fftshared::FFTSpuVoiceMixResult> &frame_mix_results = core_.frame_mix_results();

		for (int voice_idx = 0; voice_idx < static_cast<int>(voices.size()); ++voice_idx) {
			const fftshared::FFTSpuVoiceMixResult &mix_result = frame_mix_results[static_cast<size_t>(voice_idx)];
			if (!mix_result.active) {
				continue;
			}
			trace_voice_event(voice_idx, rendered_sample_count_ + static_cast<uint64_t>(frame),
					voices[static_cast<size_t>(voice_idx)], mix_result.env_vol, clip_pcm16(mix_result.sample));
		}

		const std::array<int32_t, 2> rvb_out = core_.mix_reverb(frame_result.rvb_in_l, frame_result.rvb_in_r, nullptr);
		write[frame * 2] = clip_pcm16(frame_result.sum_l + rvb_out[0]);
		write[frame * 2 + 1] = clip_pcm16(frame_result.sum_r + rvb_out[1]);

		trace_inactive_voices(rendered_sample_count_ + static_cast<uint64_t>(frame));
	}

	rendered_sample_count_ += static_cast<uint64_t>(frame_count);
	rendered_frames_total_ += frame_count;
	return output;
}

PackedInt32Array FFTSmdSequencerNative::render_tick_pcm16() {
	if (!sampled_voice_trace_enabled_) {
		PackedInt32Array pcm = to_packed_pcm(sequencer_.render_tick_pcm16());
		rendered_frames_total_ += pcm.size() / 2;
		rendered_sample_count_ += static_cast<uint64_t>(pcm.size() / 2);
		return pcm;
	}
	return render_interleaved_with_trace(sequencer_.consume_tick_frame_count());
}

PackedInt32Array FFTSmdSequencerNative::render_frames_only_pcm16(int frame_count) {
	if (frame_count <= 0) {
		return PackedInt32Array();
	}
	if (!sampled_voice_trace_enabled_) {
		PackedInt32Array pcm = to_packed_pcm(sequencer_.render_frames_only_pcm16(frame_count));
		rendered_frames_total_ += pcm.size() / 2;
		rendered_sample_count_ += static_cast<uint64_t>(pcm.size() / 2);
		return pcm;
	}
	return render_interleaved_with_trace(frame_count);
}

bool FFTSmdSequencerNative::has_active_audio() const {
	return sequencer_.has_active_audio();
}

bool FFTSmdSequencerNative::all_done() const {
	return sequencer_.all_done();
}

int FFTSmdSequencerNative::get_active_voice_count() const {
	return core_.active_voice_count();
}

double FFTSmdSequencerNative::get_tempo_bpm() const {
	return sequencer_.tempo_bpm();
}

double FFTSmdSequencerNative::get_samples_per_tick() const {
	return sequencer_.samples_per_tick();
}

double FFTSmdSequencerNative::get_tick_accumulator() const {
	return sequencer_.tick_accumulator();
}

int FFTSmdSequencerNative::get_total_ticks() const {
	return sequencer_.total_ticks();
}

void FFTSmdSequencerNative::set_sampled_voice_trace_enabled(bool enabled) {
	sampled_voice_trace_enabled_ = enabled;
	clear_sampled_voice_trace_internal();
}

bool FFTSmdSequencerNative::is_sampled_voice_trace_enabled() const {
	return sampled_voice_trace_enabled_;
}

void FFTSmdSequencerNative::set_sampled_voice_trace_dense(bool enabled) {
	sampled_voice_trace_dense_ = enabled;
	if (sampled_voice_trace_enabled_) {
		clear_sampled_voice_trace_internal();
	}
}

bool FFTSmdSequencerNative::is_sampled_voice_trace_dense() const {
	return sampled_voice_trace_dense_;
}

void FFTSmdSequencerNative::set_sampled_voice_trace_voices(const PackedInt32Array &voice_indices) {
	sampled_voice_trace_mask_.fill(false);
	if (voice_indices.is_empty()) {
		sampled_voice_trace_mask_.fill(true);
		return;
	}
	for (int i = 0; i < voice_indices.size(); ++i) {
		const int voice_idx = voice_indices[i];
		if (voice_idx >= 0 && voice_idx < fftshared::FFTSpuCoreRuntime::kNumVoices) {
			sampled_voice_trace_mask_[static_cast<size_t>(voice_idx)] = true;
		}
	}
}

void FFTSmdSequencerNative::clear_sampled_voice_trace() {
	clear_sampled_voice_trace_internal();
}

Array FFTSmdSequencerNative::get_sampled_voice_trace() const {
	Array out;
	out.resize(static_cast<int>(sampled_voice_trace_.size()));
	for (int i = 0; i < static_cast<int>(sampled_voice_trace_.size()); ++i) {
		out[i] = sampled_voice_trace_[static_cast<size_t>(i)];
	}
	return out;
}
