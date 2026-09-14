class_name ExMateriaSpu
extends RefCounted

## The whole public surface of `addons/exmateria_spu`, and — beside the four
## classes the GDExtension registers — the only name it puts in your project.
##
## Godot has no namespaces: a `class_name` is engine-global, so every one an
## addon declares lands in YOUR global scope, and if you declare a colliding one
## the ADDON's file is the one that fails to parse. This addon therefore
## declares exactly one, and reaches its own internals by `preload` path. See
## `docs/adr/0003-an-installed-addon-owns-five-global-names.md`.
##
## The constants below are scripts, and a script constant is a full type — it
## works as an annotation, in an `is` check and for `.new()`:
##
##     var spu: ExMateriaSpu.Spu = ExMateriaSpu.Spu.new()
##     var sample := ExMateriaSpu.Sample.from_wav("res://kick.wav")
##     if sample is ExMateriaSpu.Sample:
##         ...
##
## Nothing here is instantiated. `ExMateriaSpu.new()` gives you an empty
## RefCounted; the class exists to be a namespace, not an object.

## The SPU itself — 24 voices, ADSR, pitch/volume LFO, noise, reverb, and the
## interleaved-stereo render. `spu.gd` is the GDScript handle; the DSP is in
## the `ExMateriaPsxSpu` GDExtension class behind it.
const Spu = preload("res://addons/exmateria_spu/runtime/spu.gd")

## One sample: PSX ADPCM bytes, a start point, a loop point and a root pitch.
## Encode one with `from_pcm16()` / `from_wav()`, or import a `.wav` in the dock.
##
## **This was `ExMateriaSpuSample`.** The self-prefix existed only because there
## was no namespace to put the type in — which is the very thing this class now
## is — so carrying it inside the namespace would spell
## `ExMateriaSpu.ExMateriaSpuSample`. Every consumer has to rewrite the name
## either way (the global is gone), so the rewrite goes to the shorter one. The
## four GDExtension classes KEEP their prefixes: ClassDB has no namespace to
## move them into, which is the same argument pointing the other way.
const Sample = preload("res://addons/exmateria_spu/runtime/spu_sample.gd")

## The ADSR envelope model — the `adsr1`/`adsr2` register pair `key_on` takes,
## and the helpers that build one.
const ADSR = preload("res://addons/exmateria_spu/runtime/adsr.gd")
