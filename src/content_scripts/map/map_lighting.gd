class_name MapLighting
extends Resource
## The three directional lights + ambient colour FFT stores in every map's mesh
## resource, at the same pointer (0x64) whose last six bytes already feed the
## background gradient.
##
## 🔴 THE THREE TRAPS THIS TYPE EXISTS TO HOLD, all of which produce a
## plausible-but-wrong picture rather than an error:
##
## 1. THE COLOURS ARE A 3x3 MATRIX, not three RGB triples. All three reds come
##    first, then all three greens, then all three blues. Read as triples the
##    result is still three colours, just the wrong ones.
## 2. A LIGHT COLOUR IS A GAIN AND ROUTINELY EXCEEDS 1.0. Each component is
##    `int16 / 8`, floored at 0 and NOT capped - MAP062's key light measures
##    (604, 528, 476), a warm ~2.4x overbright. The PSX clamps only the FINAL
##    per-vertex pixel, after the ambient add and the texture multiply, so the
##    gain is stored raw here and `map_shader.gdshader` clamps at the end.
##    Clamping to 255 here (what GaneshaDx's *display* path does) drops the
##    overbright and the warmth and leaves lit faces too dark and too cool.
## 3. THE DIRECTIONS ARE STORED IN THE MESH'S OWN (ROM) SPACE AND STAY THERE.
##    See `from_lighting_bytes` - the sign question is the whole of it.
##
## A `MapData` with no lighting is not an error: see `unlit()`.

## Bytes from the start of the lighting block to the end of the ambient colour.
## The block continues with the six background-gradient bytes `FftMapData`
## already consumes.
const LIGHTING_BYTES: int = 18 + 18 + 3

const NUM_LIGHTS: int = 3

## Directional light gains, in 0-1 texture-multiply space (the ROM's `int16 / 8`
## divided by 255). NOT a displayable colour: components above 1.0 are normal and
## are the point. Always `NUM_LIGHTS` long.
@export var light_gains: PackedVector3Array = []

## Unit direction TOWARDS each light, in the map mesh's own coordinate space -
## the same space `FftMapData.get_normals` leaves its normals in. Always
## `NUM_LIGHTS` long.
@export var light_directions: PackedVector3Array = []

## Ambient term, 0-1. Added to the diffuse sum before the texture multiply, with
## NO scale factor: GaneshaDx's `ambient x 1.5` existed only to claw back the
## brightness lost by clamping the lights to white (trap 2), and with the true
## unclamped gains it is wrong.
@export var ambient: Vector3 = Vector3.ZERO


## Decode the block `FftMapData` slices at the lighting pointer. `bytes` must be
## at least `LIGHTING_BYTES` long; the six gradient bytes after it are ignored
## here. Returns `unlit()` for a map with no lighting block.
##
## 🔴 THE DIRECTION SIGNS ARE THE TRAP, AND THE ANSWER IS "NONE OF THEM".
## The exporter this layout was read from
## (fft-monorepo `tools/fft_exporter/parsers/lighting.py`) negates x and y of the
## light direction - and its mesh parser (`parsers/mesh.py:_parse_normal_data`)
## negates x and y of every NORMAL by the same lines, then both go through the
## identical spherical round trip, which works out to a further `(-x, y, -z)`.
## Net, that pipeline applies ONE orthogonal transform, `diag(1, -1, -1)`, to the
## lights AND to the normals. `dot(Tn, Tl) == dot(n, l)` for orthogonal T, so the
## quantity it actually shades with is the RAW dot product.
##
## TacticsG's `get_normals` negates nothing, so the matching light direction
## negates nothing either. Copying the exporter's `-x, -y, +z` across without
## also copying its normal negation flips the lighting in Y and darkens every
## floor in the game - measured: it takes map_116 from 17% to 99% of its textured
## vertices receiving ambient only, and it is otherwise invisible.
static func from_lighting_bytes(bytes: PackedByteArray) -> MapLighting:
	if bytes.size() < LIGHTING_BYTES:
		push_warning("MapLighting: lighting block is %d bytes, need %d" % [bytes.size(), LIGHTING_BYTES])
		return unlit()

	var new_lighting: MapLighting = MapLighting.new()
	new_lighting.light_gains.resize(NUM_LIGHTS)
	new_lighting.light_directions.resize(NUM_LIGHTS)

	for light_index: int in NUM_LIGHTS:
		# Trap 1: a 3x3 matrix, so red_i is at 0 + 2i, green_i at 6 + 2i, blue_i
		# at 12 + 2i - NOT three consecutive triples.
		# Trap 2: floor at 0, never cap.
		new_lighting.light_gains[light_index] = Vector3(
			maxf(0.0, float(bytes.decode_s16(light_index * 2)) / 8.0),
			maxf(0.0, float(bytes.decode_s16(6 + light_index * 2)) / 8.0),
			maxf(0.0, float(bytes.decode_s16(12 + light_index * 2)) / 8.0),
		) / 255.0

		var direction_offset: int = 18 + light_index * 6
		var direction: Vector3 = Vector3(
			float(bytes.decode_s16(direction_offset)),
			float(bytes.decode_s16(direction_offset + 2)),
			float(bytes.decode_s16(direction_offset + 4)),
		)
		new_lighting.light_directions[light_index] = direction.normalized()

	new_lighting.ambient = Vector3(
		float(bytes.decode_u8(36)),
		float(bytes.decode_u8(37)),
		float(bytes.decode_u8(38)),
	) / 255.0

	return new_lighting


## The identity lighting: ambient 1.0, no directional light, so
## `texture * (ambient + diffuse)` is `texture * 1.0`. This is what a map with no
## lighting block - or a `.map_data.tres` exported before lighting was carried -
## renders as, and it is pixel-identical to the flat map that shipped before.
static func unlit() -> MapLighting:
	var new_lighting: MapLighting = MapLighting.new()
	new_lighting.ambient = Vector3.ONE
	new_lighting.light_gains.resize(NUM_LIGHTS)
	new_lighting.light_directions.resize(NUM_LIGHTS)
	for light_index: int in NUM_LIGHTS:
		new_lighting.light_directions[light_index] = Vector3.UP
	return new_lighting


## True when at least one light carries a non-zero gain. Most maps leave the
## third light at zero; a map with all three at zero is lit by ambient alone.
func has_directional_light() -> bool:
	for gain: Vector3 in light_gains:
		if gain.length_squared() > 0.0:
			return true
	return false


## Push the uniforms `map_shader.gdshader` reads. Safe on a material whose shader
## has no such uniforms - Godot drops unknown parameters - but then nothing is
## lit, which is why `MapChunkNodes.set_mesh_shader` is the only caller.
func apply_to_material(material: ShaderMaterial) -> void:
	if material == null:
		return
	var gains: PackedVector3Array = light_gains.duplicate()
	var directions: PackedVector3Array = light_directions.duplicate()
	gains.resize(NUM_LIGHTS)
	directions.resize(NUM_LIGHTS)
	material.set_shader_parameter("light_gains", gains)
	material.set_shader_parameter("light_directions", directions)
	material.set_shader_parameter("ambient_light", ambient)
	material.set_shader_parameter("lighting_enabled", true)
	# Set explicitly rather than left to the shader's default: `get_shader_parameter`
	# answers null for a uniform the MATERIAL never stored, so leaving it implicit
	# makes "is this map on the faithful path?" unanswerable from the material.
	material.set_shader_parameter("lighting_per_vertex", true)
