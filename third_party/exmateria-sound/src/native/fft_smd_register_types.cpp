#include "fft_smd_register_types.h"

#include <gdextension_interface.h>

#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#include "fft_smd_sequencer_native.h"

using namespace godot;

// The MONOREPO-ONLY SMD accelerator (D2 #375 decision 2).
//
// This library never ships: `exmateria-sound.manifest` excludes its
// .gdextension, so a published install has no FFTSmdSequencerNative and
// `sequencer.gd` stays on its GDScript driver, which is the path the game has
// always used anyway. Native mode is off because the C++ sequencer never
// received the end-of-note ADSR2 release-rate force, so retriggers click —
// a known parity defect, not a dormant optimisation (smd_player.gd:45).
//
// It has to be a separate library rather than a second class in the SPU's,
// because FFTSmdSequencerNative embeds fftshared::FFTSpuCoreRuntime BY VALUE
// and sizes arrays off its kNumVoices. A plain struct has no ClassDB identity
// and cannot cross a GDExtension boundary, so this library statically
// re-links the SPU sources — D2's finding that godot-proposals #13997 bites
// harder than "no cross-extension inheritance".
void initialize_fft_smd_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}

	GDREGISTER_CLASS(FFTSmdSequencerNative);
}

void uninitialize_fft_smd_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" {
GDExtensionBool GDE_EXPORT fft_smd_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

	init_obj.register_initializer(initialize_fft_smd_module);
	init_obj.register_terminator(uninitialize_fft_smd_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

	return init_obj.init();
}
}
