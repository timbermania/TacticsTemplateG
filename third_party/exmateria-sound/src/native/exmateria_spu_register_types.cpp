#include "exmateria_spu_register_types.h"

#include <gdextension_interface.h>

#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#include "exmateria_psx_spu.h"
#include "exmateria_spu_adpcm.h"
#include "exmateria_spu_stream.h"

using namespace godot;

// The published `exmateria_spu` addon's entry point. Four classes — a generic
// PSX SPU, the AudioStream pair that carries its output onto a Godot bus, and
// the PSX ADPCM encoder that lets a caller produce samples for it (D7 #380
// dec. 5). Nothing here knows what game the samples came from.
//
// The SMD music accelerator does NOT register from this library; it has its
// own, which the publish manifest excludes. See D2 (#375) decisions 1 and 2,
// and the count amendment on that ticket.
void initialize_exmateria_spu_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}

	GDREGISTER_CLASS(ExMateriaPsxSpu);
	GDREGISTER_CLASS(ExMateriaSpuAdpcm);
	GDREGISTER_CLASS(ExMateriaSpuStream);
	GDREGISTER_CLASS(ExMateriaSpuPlayback);
}

void uninitialize_exmateria_spu_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" {
GDExtensionBool GDE_EXPORT exmateria_spu_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

	init_obj.register_initializer(initialize_exmateria_spu_module);
	init_obj.register_terminator(uninitialize_exmateria_spu_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

	return init_obj.init();
}
}
