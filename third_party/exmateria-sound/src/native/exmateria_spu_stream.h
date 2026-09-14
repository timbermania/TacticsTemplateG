#ifndef EXMATERIA_SPU_STREAM_H
#define EXMATERIA_SPU_STREAM_H

#include <godot_cpp/classes/audio_stream.hpp>
#include <godot_cpp/classes/audio_stream_playback_resampled.hpp>
#include <godot_cpp/core/class_db.hpp>

#include "exmateria_psx_spu.h"

namespace godot {

// The PSX SPU as a Godot AudioStream — D3 decisions 1 and 2 (#376).
//
// Before this, the only way GDScript could get SPU samples into Godot was
// AudioStreamGenerator + push_buffer: render a block on a producer thread,
// hand it to a ring, hope the ring never runs dry. That was not a shortcut
// somebody took — a GDScript `_mix` receives the output buffer as a raw
// pointer marshalled to TYPE_INT and cannot write a single sample into it, so
// push_buffer is the ONLY mechanism GDScript has. godot-cpp types the same
// parameter `AudioFrame *`, so the door that is shut to GDScript is open here.
//
// `_mix` RENDERS rather than draining a producer, which is the whole point:
// the native 24-voice render is ~1.5 % of a block's realtime budget, while a
// C++ stream draining a GDScript producer inherits that producer's ~30 ms
// scheduling floor. The sequencer stays in GDScript (it is the FFT music
// driver, and its end-of-note ADSR2 release force is why); it now enqueues
// timestamped register writes ahead of the audio clock instead of rendering in
// lockstep. See exmateria_spu_command_queue.h for that handshake.
class ExMateriaSpuStream : public AudioStream {
	GDCLASS(ExMateriaSpuStream, AudioStream)

	Ref<ExMateriaPsxSpu> mixer_;

protected:
	static void _bind_methods();

public:
	// The SPU this stream plays. One stream per Spu — that is the parity
	// boundary (the PSX has one 24-voice SPU; summing several of them was
	// never PSX-accurate, so the sum belongs to Godot's bus mixer).
	void set_mixer(const Ref<ExMateriaPsxSpu> &p_mixer) { mixer_ = p_mixer; }
	Ref<ExMateriaPsxSpu> get_mixer() const { return mixer_; }

	virtual Ref<AudioStreamPlayback> _instantiate_playback() const override;
	virtual String _get_stream_name() const override;
	virtual double _get_length() const override;
	virtual bool _is_monophonic() const override;
};

class ExMateriaSpuPlayback : public AudioStreamPlaybackResampled {
	GDCLASS(ExMateriaSpuPlayback, AudioStreamPlaybackResampled)

	Ref<ExMateriaPsxSpu> mixer_;
	bool active_ = false;
	uint64_t frames_mixed_ = 0;

protected:
	static void _bind_methods();

public:
	void set_mixer(const Ref<ExMateriaPsxSpu> &p_mixer) { mixer_ = p_mixer; }

	virtual void _start(double p_from_pos) override;
	virtual void _stop() override;
	virtual bool _is_playing() const override;
	virtual int32_t _get_loop_count() const override;
	virtual double _get_playback_position() const override;
	virtual void _seek(double p_position) override;
	virtual int32_t _mix_resampled(AudioFrame *p_dst_buffer, int32_t p_frame_count) override;
	// The SPU renders at 44 100 Hz, full stop. Declaring it lets Godot's own
	// resampler carry a host running at some other mix rate; at 44 100 the
	// resampler's interpolation coefficient is exactly zero, so it copies the
	// samples through untouched and the parity claim survives.
	virtual float _get_stream_sampling_rate() const override;
};

} // namespace godot

#endif
