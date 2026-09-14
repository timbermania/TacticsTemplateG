#ifndef FFT_PITCH_TOOLS_H
#define FFT_PITCH_TOOLS_H

#include <cstdint>

namespace fftshared {

int32_t fft_pre_pitch_from_note(int16_t midi_note, int32_t fine_tune);
int32_t fft_raw_pitch_from_pre_pitch(int32_t pre_pitch);
int32_t fft_raw_pitch_from_note(int16_t midi_note, int32_t fine_tune);

}  // namespace fftshared

#endif  // FFT_PITCH_TOOLS_H
