#include "exmateria_spu_stream.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/method_bind.hpp>

using namespace godot;

// ---------------------------------------------------------------- stream ----

void ExMateriaSpuStream::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_mixer", "mixer"), &ExMateriaSpuStream::set_mixer);
	ClassDB::bind_method(D_METHOD("get_mixer"), &ExMateriaSpuStream::get_mixer);
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "mixer", PROPERTY_HINT_RESOURCE_TYPE, "ExMateriaPsxSpu"),
			"set_mixer", "get_mixer");
}

Ref<AudioStreamPlayback> ExMateriaSpuStream::_instantiate_playback() const {
	Ref<ExMateriaSpuPlayback> playback;
	playback.instantiate();
	playback->set_mixer(mixer_);
	return playback;
}

String ExMateriaSpuStream::_get_stream_name() const {
	return String("ExMateria SPU");
}

double ExMateriaSpuStream::_get_length() const {
	// Endless: the SPU sounds for as long as the sequencer keeps feeding it.
	// Godot reads 0.0 as "unknown length", which is what stops the player from
	// trying to seek or report progress against a total.
	return 0.0;
}

bool ExMateriaSpuStream::_is_monophonic() const {
	// One AudioStreamPlayer per SPU; several SPUs playing at once IS the
	// arrangement, so nothing here is monophonic.
	return false;
}

// -------------------------------------------------------------- playback ----

void ExMateriaSpuPlayback::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_mixer", "mixer"), &ExMateriaSpuPlayback::set_mixer);
}

void ExMateriaSpuPlayback::_start(double p_from_pos) {
	// Nothing to seek to — the SPU has no timeline of its own, only whatever
	// the sequencer has queued. Starting always means "from here".
	frames_mixed_ = 0;
	begin_resample();
	active_ = true;
}

void ExMateriaSpuPlayback::_stop() {
	active_ = false;
}

bool ExMateriaSpuPlayback::_is_playing() const {
	return active_;
}

int32_t ExMateriaSpuPlayback::_get_loop_count() const {
	return 0;
}

double ExMateriaSpuPlayback::_get_playback_position() const {
	return double(frames_mixed_) / double(44100.0);
}

void ExMateriaSpuPlayback::_seek(double p_position) {
	// Deliberately a no-op: seeking would mean rewinding SPU voice state,
	// reverb tank and the sequencer's queued writes together, and the FFT
	// driver has no notion of a random-access position.
}

int32_t ExMateriaSpuPlayback::_mix_resampled(AudioFrame *p_dst_buffer, int32_t p_frame_count) {
	if (!active_ || mixer_.is_null() || p_frame_count <= 0) {
		for (int32_t i = 0; i < p_frame_count; i++) {
			p_dst_buffer[i].left = 0.0f;
			p_dst_buffer[i].right = 0.0f;
		}
		return p_frame_count;
	}

	mixer_->render_audio_frames(p_dst_buffer, p_frame_count);
	frames_mixed_ += static_cast<uint64_t>(p_frame_count);
	return p_frame_count;
}

float ExMateriaSpuPlayback::_get_stream_sampling_rate() const {
	return 44100.0f;
}
