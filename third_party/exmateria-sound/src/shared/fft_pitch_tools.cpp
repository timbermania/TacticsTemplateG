#include "fft_pitch_tools.h"

namespace fftshared {

namespace {

#include "detail/pitch_tables.inc"

}  // namespace

int32_t fft_pre_pitch_from_note(int16_t midi_note, int32_t fine_tune) {
	return static_cast<int32_t>(midi_note) * 256 + fine_tune;
}

int32_t fft_raw_pitch_from_pre_pitch(int32_t pre_pitch) {
	if (pre_pitch < 0) {
		pre_pitch = 0;
	}

	int32_t octave_index = (pre_pitch >> 8) & 0x7F;
	int32_t fine_byte = pre_pitch & 0xFF;
	int32_t semitone = static_cast<int32_t>(SEMITONE_LOOKUP[octave_index]);
	int32_t shift = 6 - static_cast<int32_t>(OCTAVE_SHIFT_LOOKUP[octave_index]);
	int32_t table_idx = semitone * 256 + fine_byte;
	constexpr int32_t table_size = static_cast<int32_t>(sizeof(PITCH_TABLE) / sizeof(PITCH_TABLE[0]));
	if (table_idx >= table_size) {
		table_idx = table_size - 1;
	}

	int32_t base = static_cast<int32_t>(PITCH_TABLE[table_idx]);
	if (shift >= 0) {
		return base >> shift;
	}
	return base << (-shift);
}

int32_t fft_raw_pitch_from_note(int16_t midi_note, int32_t fine_tune) {
	return fft_raw_pitch_from_pre_pitch(fft_pre_pitch_from_note(midi_note, fine_tune));
}

}  // namespace fftshared
