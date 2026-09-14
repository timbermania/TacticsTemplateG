#include "exmateria_spu_adpcm.h"

#include <algorithm>
#include <cstdint>
#include <vector>

#include "supportpsx/adpcm.h"

using namespace godot;

void ExMateriaSpuAdpcm::_bind_methods() {
	ClassDB::bind_static_method("ExMateriaSpuAdpcm",
			D_METHOD("encode_pcm16", "pcm", "loop_at"), &ExMateriaSpuAdpcm::encode_pcm16,
			DEFVAL(-1));
}

PackedByteArray ExMateriaSpuAdpcm::encode_pcm16(const PackedInt32Array &p_pcm, int64_t p_loop_at) {
	PackedByteArray out;
	const int64_t sample_count = p_pcm.size();
	if (sample_count <= 0) {
		return out;
	}

	// Pad the tail to a whole block with silence. A partial block cannot be
	// expressed — ADPCM is 28 samples or nothing.
	int64_t block_count = (sample_count + SAMPLES_PER_BLOCK - 1) / SAMPLES_PER_BLOCK;

	// Where the loop point lands, in blocks. The SPU's loop marker is a flag on
	// a BLOCK, so a loop point is only ever block-accurate.
	const bool looped = p_loop_at >= 0;
	int64_t loop_block = looped ? std::clamp<int64_t>(p_loop_at / SAMPLES_PER_BLOCK, 0, block_count - 1) : -1;

	// The last block has to carry LoopEnd (flags 0x03) for playback to jump
	// back, and the loop point has to carry LoopStart (0x04). One block cannot
	// be both: fft_decode_next_block only loops on flags == 3 EXACTLY, so a
	// block marked 0x07 stops instead. When the loop point falls in the final
	// block, emit that block TWICE — the copy carries LoopEnd and jumps back to
	// the original, so the loop body is those 28 samples, played over and over.
	const bool duplicate_final = looped && loop_block == block_count - 1;
	if (duplicate_final) {
		block_count += 1;
	}

	std::vector<int16_t> block(SAMPLES_PER_BLOCK, 0);
	PCSX::ADPCM::Encoder encoder;
	encoder.reset(PCSX::ADPCM::Encoder::Mode::Normal);

	out.resize(block_count * BLOCK_SIZE);
	uint8_t *dst = out.ptrw();

	for (int64_t b = 0; b < block_count; ++b) {
		// The duplicated tail block re-reads the final block's samples.
		const int64_t src_block = (duplicate_final && b == block_count - 1) ? b - 1 : b;
		for (int i = 0; i < SAMPLES_PER_BLOCK; ++i) {
			const int64_t idx = src_block * SAMPLES_PER_BLOCK + i;
			const int32_t v = idx < sample_count ? p_pcm[static_cast<int>(idx)] : 0;
			block[static_cast<size_t>(i)] = static_cast<int16_t>(std::clamp<int32_t>(v, -32768, 32767));
		}

		PCSX::ADPCM::Encoder::BlockAttribute attr;
		if (!looped) {
			attr = (b == block_count - 1)
					? PCSX::ADPCM::Encoder::BlockAttribute::OneShotEnd
					: PCSX::ADPCM::Encoder::BlockAttribute::OneShot;
		} else if (b == block_count - 1) {
			attr = PCSX::ADPCM::Encoder::BlockAttribute::LoopEnd;
		} else if (b == loop_block) {
			attr = PCSX::ADPCM::Encoder::BlockAttribute::LoopStart;
		} else {
			attr = PCSX::ADPCM::Encoder::BlockAttribute::LoopBody;
		}

		encoder.processSPUBlock(block.data(), dst + b * BLOCK_SIZE, attr);
	}

	return out;
}
