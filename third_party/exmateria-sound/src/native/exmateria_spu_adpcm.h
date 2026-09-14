#ifndef EXMATERIA_SPU_ADPCM_H
#define EXMATERIA_SPU_ADPCM_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

namespace godot {

// PSX ADPCM encoding, exposed to GDScript as static methods.
//
// The encoder itself is not ours: src/vendor/supportpsx/adpcm.{h,cc} is a
// verbatim MIT copy from PCSX-Redux, a re-creation of Sony's Psy-Q `encvag`.
// See addons/exmateria_spu/NOTICE and src/vendor/README.md. Everything in this
// file is the thin part — Variant marshalling and the choice of which
// BlockAttribute each block gets, which is where the loop contract lives.
//
// Nothing here holds state between calls, so there is nothing to instantiate:
//
//     var adpcm := ExMateriaSpuAdpcm.encode_pcm16(pcm, loop_at)
//
// GDScript authors should reach for ExMateriaSpu.Sample.from_pcm16() instead;
// this class is what that one calls.
class ExMateriaSpuAdpcm : public RefCounted {
	GDCLASS(ExMateriaSpuAdpcm, RefCounted)

protected:
	static void _bind_methods();

public:
	// 28 PCM samples per 16-byte ADPCM block. Public because the packing rules
	// a caller needs (where a loop point can land) are stated in these units.
	static constexpr int SAMPLES_PER_BLOCK = 28;
	static constexpr int BLOCK_SIZE = 16;

	// Encode 16-bit mono PCM into PSX ADPCM blocks.
	//
	// `p_pcm` is one int per sample, clamped to int16 range. `p_loop_at` is a
	// SAMPLE index: >= 0 marks the loop point and makes the result loop
	// forever; -1 makes it a one-shot that stops at its end.
	static PackedByteArray encode_pcm16(const PackedInt32Array &p_pcm, int64_t p_loop_at);
};

} // namespace godot

#endif // EXMATERIA_SPU_ADPCM_H
