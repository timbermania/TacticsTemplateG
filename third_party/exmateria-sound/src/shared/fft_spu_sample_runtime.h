#ifndef FFT_SPU_SAMPLE_RUNTIME_H
#define FFT_SPU_SAMPLE_RUNTIME_H

#include <cstdint>

#include "fft_spu_voice_runtime.h"

namespace fftshared {

void fft_decode_voice_block(FFTSpuVoiceRuntime &voice, const uint8_t *spu_ram, int32_t spu_ram_size);
int32_t fft_get_voice_source_sample(FFTSpuVoiceRuntime &voice, int32_t effective_sinc,
		const uint8_t *spu_ram, int32_t spu_ram_size);

}  // namespace fftshared

#endif  // FFT_SPU_SAMPLE_RUNTIME_H
