#ifndef FFT_SMD_SEQUENCE_MODEL_H
#define FFT_SMD_SEQUENCE_MODEL_H

#include <cstdint>
#include <string>
#include <variant>
#include <vector>

namespace fftshared {

struct FFTSmdNoteEvent {
	int32_t velocity = 0;
	int32_t relative_key = 0;  // 0-11 note, 12 tie, 13 rest
	int32_t delta_time = 0;
};

struct FFTSmdOpcodeEvent {
	int32_t opcode = 0;
	std::vector<int32_t> params;
};

using FFTSmdTrackEvent = std::variant<FFTSmdNoteEvent, FFTSmdOpcodeEvent>;

struct FFTSmdSequence {
	int32_t track_count = 0;
	int32_t initial_tempo = 0;
	int32_t initial_volume = 0;
	int32_t assoc_wds_id = 0;
	std::string song_title;
	std::vector<std::vector<FFTSmdTrackEvent>> track_events;
};

constexpr int32_t kFftSmdPpq = 48;

inline double fft_smd_tempo_to_bpm(int32_t tempo_value) {
	if (tempo_value <= 0) {
		return 120.0;
	}
	return (static_cast<double>(tempo_value) * 256.0) / 218.0;
}

}  // namespace fftshared

#endif  // FFT_SMD_SEQUENCE_MODEL_H
