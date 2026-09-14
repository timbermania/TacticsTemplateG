extends RefCounted
## #219 slice B — order the combat compositor's unified transparent-prim buffer by
## OT depth (far -> near) instead of by blend mode.
##
## Slice A concatenated the four per-mode stagings in a fixed FOLD_ORDER [sub, mix,
## add, add25]; the fold therefore drew every sub before every add regardless of
## depth. Slice B instead emits prims in PSX Ordering-Table depth order so the fold's
## draw sequence (gl_InstanceIndex order) matches the depth order the mode shaders
## would rasterize. Runs become MAXIMAL adjacent same-mode spans over the depth-ordered
## stream — modes now interleave (more runs).
##
## Slice C (#220) collapses adjacent same-DIRECTION runs instead of same-MODE: an ADD
## run may contain BOTH mode1 (level 1.0) and mode3/ADD25 (level 0.25), since the hardware
## BLEND_OP_ADD accumulates them and the per-prim level_scale (carried in the record at
## float [20]) supplies each prim's 1.0 or 0.25. Direction classes:
##   add = {mode 1, mode 3}  (ceiling-only accumulate)   -> run.mode = 1 (add pipeline)
##   sub = {mode 2}          (floor-only accumulate)      -> run.mode = 2 (sub pipeline)
##   mix = {mode 0}          (rescales dst — ALWAYS SOLO) -> run.mode = 0 (mix pipeline)
## A run breaks at every add<->sub transition and at every mix prim (two adjacent mix prims
## are two runs). This is byte-exact vs slice B by associativity of single-sided saturation
## (proto_ordered_fold Q3, 200k trials): the hardware blend already accumulates overlapping
## same-direction instances within one draw with per-prim clamp, exactly as separate draws
## did — only the SOURCE of `level` moves from a per-run push-constant to a per-prim record
## field. The compositor folds an arbitrary run sequence, so nothing downstream changes.
##
## Direction (view-space Z, DepthMode.ot_order_z): more-negative = farther, less-negative =
## nearer. We emit the FARTHEST prim first and the NEAREST prim last, so the display-space
## accumulator folds far -> near and the nearest prim wins where they overlap (last drawn on top).
##
## Tie-break (#214 → #212 DEMI): equal-depth prims resolve by particle AGE — the
## NEWEST-spawned prim in a bucket sorts LAST and therefore folds ON TOP. This mirrors
## PSX's double-head-insert (list head-inserted at spawn, walked head->tail, each
## head-inserted into its OT bucket): net, the newest particle draws last within a
## bucket. depth_mode does NOT distinguish add from sub (DEMI: every particle is
## PULL_FORWARD_8), so where a white additive and a black subtractive prim tie in a
## bucket, age is what keeps the white on top — reverse-submission (the prior #214
## rule) put the FIRST-staged prim on top, and our staging is emitter-grouped (sub
## emitters before add), which folded the sub last and clobbered the white core.
## See research/working_documents/DEMI2_E046_ADDITIVE_SUBTRACTIVE_ORDERING.md.
##
## `ages` is optional: when absent (legacy callers / same-direction commutative cases)
## the within-bucket order falls back to submission order (stable), which is harmless
## because same-direction folds commute. When present it must be N-long.
##
## Pure + RD-free. Ordering is an LSD radix of two STABLE counting-sort passes (#219's
## "bucket/radix-assign, NOT an O(N log N) sort_custom comparator"): an optional age pass
## (secondary key) then the depth-bucket pass (primary key). Cost is O(N + maxAge + buckets),
## O(1) work per prim per pass — never a comparator sort. Determinism comes from the stable
## passes + submission-order start, independent of any library sort's stability.
## Vault: [[Display Space Blend Fold]]

## FFT's Ordering Table is ~383 buckets (ADR-0009: OTZ >> 2, a ~383-bucket painter's table).
## We bucket the VIEW-SPACE-Z ordering key (DepthMode.ot_order_z) at a FIXED PSX-calibrated
## 0.19-world-unit width so equal-depth prims share a bucket (giving the #214 tie-break) while
## distinct depths separate — matching PSX's `SZ>>2` instead of spreading buckets across the
## whole frustum. BUCKET_COUNT survives only as MAX_ORDER_SPAN's magnitude (the PSX OT size).
## See #212 / research/working_documents/COMPOSITOR_OT_BUCKET_WIDTH_PARITY.md.

## ADR-0212 dec. 1 — `addons/exmateria_schema` used to declare six bare globals,
## every one of them generic English (`Fold`, `DepthMode`, `ColorStack`,
## `ColorRecipe`, `CellMarking`, `TerrainCell`). It now declares only
## `ExMateriaSchema`, so these lines are what keep the use sites below spelled the
## way they were (ADR-0211 dec. 4).
const DepthMode = ExMateriaSchema.DepthMode

const BUCKET_COUNT := 384

## Cap on the per-frame NORMALIZED bucket span fed to the counting sort. order() normalizes each
## frame's raw view-Z buckets by subtracting the frame's min (0 = farthest), so key_max is the
## ACTUAL prim span (~11-20 buckets for DEMI), not a fixed 384/2790. This cap bounds the counts[]
## allocation to O(PSX OT size) so a stray far/near prim or a fixed-mode sentinel can't blow the
## key range — a prim beyond this many 0.19-u buckets from the frame's nearest pins to the near
## extreme (order among the rest preserved). Battle-effect prim clouds never approach this span.
const MAX_ORDER_SPAN := BUCKET_COUNT - 1   # 383, the PSX OT bucket count

# Slice C (#220): the unified record is now 24 floats/instance — [0..19] the MultiMesh-
# compatible ADR-0040 packing, [20] per-prim level_scale (1.0 for modes 0/1/2, 0.25 for
# mode 3), [21..23] vec4-alignment padding. The compositor reads level from the record
# (v_level varying) so a merged add run can serve both mode1 and mode3.
const _FLOATS_PER_INSTANCE := 24

# Unified-record stride stamped into each run so the compositor/renderer push it as the
# per-run stride push-constant (fp.w). Kept explicit here so a drift is caught by a test.
const _UNIFIED_STRIDE := 24


## Direction class of a compositor blend mode. add {1,3} and sub {2} accumulate (runs may
## merge same-direction prims); mix {0} rescales dst and is always its own run.
enum Direction { ADD, SUB, MIX }


static func _direction_of(mode: int) -> int:
	match mode:
		2: return Direction.SUB
		0: return Direction.MIX
		_: return Direction.ADD   # 1 (add) and 3 (add25) share the additive direction


## Representative mode for a direction's fold pipeline / is_mix selection.
static func _rep_mode_for(direction: int) -> int:
	match direction:
		Direction.SUB: return 2
		Direction.MIX: return 0
		_: return 1


## Order `records` (N*24 floats, submission order) by the parallel `depths` (N reversed-Z
## OT depths) into a depth-ordered unified buffer + run descriptors.
##   records: PackedFloat32Array, length N*24, one 24-float prim per instance (per-prim
##            level_scale at [20], slice C).
##   modes:   PackedInt32Array, length N, blend mode 0..3 per prim.
##   depths:  PackedFloat32Array, length N, DepthMode.ot_depth per prim (near=1, far=0).
##   ages:    PackedFloat32Array, the OPTIONAL within-bucket ORDERING KEY, length N or 0.
##
## ===== ORDERING CONTRACT (read before adding a new blended-prim source) =====
## Every blended prim routed through this compositor folds through order().
## Draw order = (1) depth bucket far->near, then (2) the
## within-bucket tie-break. The tie-break needs a per-prim key because equal-depth prims of
## OPPOSITE direction (add vs sub) are non-commutative and PSX resolves them by SUBMISSION
## order (AddPrim head-insert => net "newest drawn on top" for the particle engine).
##   * `ages` present (length N): ties resolve by age DESCENDING = NEWEST (smallest elapsed
##     age) ON TOP. This reproduces PSX for particles, whose Godot staging order (emitter-
##     grouped) does NOT match draw order, so a key is REQUIRED for correctness.
##   * `ages` empty: ties fall back to submission (staging) index — first-staged folds first
##     (behind), last-staged on top. This is correct ONLY if the caller already stages its
##     prims back-to-front. A source that cannot guarantee that (like particles) MUST pass an
##     ordering key, or overlapping opposite-direction prims will mis-order (the #212 bug).
## New blended-prim source? Decide: does my staging order == my intended back-to-front order?
## If not, supply an `ages`-equivalent monotonic ordering key. `age` is the particle instance
## of that general key. See research/working_documents/DEMI2_E046_ADDITIVE_SUBTRACTIVE_ORDERING.md.
## ===========================================================================
##
## Returns {"unified": PackedFloat32Array (N*24, depth-ordered), "runs": Array of
## {mode, base, count, stride, depth}} where runs collapse adjacent SAME-DIRECTION spans
## (add {1,3} / sub {2}; mix {0} is always solo). run.mode is the direction's
## representative (1=add, 2=sub, 0=mix) for pipeline/is_mix selection. run.depth is
## the run's base ot_order_z — the fold-order key a consumer hands DepthMode
## (corrected 2026-08-21, ADR-0200: the docstring listed four fields; :228/:235 write five).
static func order(records: PackedFloat32Array, modes: PackedInt32Array,
		depths: PackedFloat32Array, ages: PackedFloat32Array = PackedFloat32Array()) -> Dictionary:
	var n: int = modes.size()
	if n == 0:
		return {"unified": PackedFloat32Array(), "runs": []}

	# --- Order submission indices by (depth bucket asc = far->near, then age DESC) via an
	#     LSD radix of STABLE counting sorts. #219 requires bucket/radix-assign, O(N + buckets),
	#     NOT an O(N log N) sort_custom comparator, so we counting-sort by the LEAST significant
	#     key first (age) and the MOST significant last (bucket); each pass preserves the prior
	#     pass's order among ties, giving the composite key without any comparator.
	# Primary key: the depth bucket (BUCKET_COUNT painter's buckets, OTZ>>2). Ascending in d,
	# so far (small d) folds first and near (large d) folds last / on top.
	# Secondary key: particle AGE *descending* (oldest first, NEWEST last). `age` = elapsed
	# frames since spawn, so newest = SMALLEST age; putting the smallest age LAST folds it ON
	# TOP, which is the PSX double-head-insert rule (newest-spawned draws last). This keeps
	# DEMI's white additive (emitter idx3, spawns f36-49) ON TOP of the black subtractive
	# (emitter idx1, spawns f22-38 = older) where they tie in a bucket.
	# Tertiary key: submission index. It falls out for free -- order_idx starts in submission
	# order and every pass is stable, so equal-(bucket,age) prims keep their submission order.
	var has_ages: bool = ages.size() == n
	var order_idx: Array = []
	order_idx.resize(n)
	for i in range(n):
		order_idx[i] = i

	# Age pass (secondary key) -- run FIRST (least significant). Key = maxAge - age so a LARGER
	# age (older) gets a SMALLER key and sorts EARLIER (folds behind); newest (smallest age)
	# sorts LAST (on top). Skipped when ages are absent: order_idx then stays in submission
	# order, so the bucket pass alone yields the (bucket asc, submission asc) fallback contract.
	if has_ages:
		var max_age: int = 0
		var age_keys := PackedInt32Array()
		age_keys.resize(n)
		for i in range(n):
			var a: int = int(ages[i])
			if a < 0:
				a = 0
			age_keys[i] = a
			if a > max_age:
				max_age = a
		for i in range(n):
			age_keys[i] = max_age - age_keys[i]   # descending -> ascending key
		order_idx = _stable_counting_sort(order_idx, age_keys, max_age)

	# Bucket pass (primary key) -- run LAST (most significant). NORMALIZE per-frame: the raw
	# view-Z buckets (OTZ = round(view_z / 0.19), PSX's SZ>>2) are large and often negative, so
	# subtract the frame's MIN bucket to get a compact ascending key (0 = farthest, larger =
	# nearer). key_max is then the ACTUAL prim span, not a fixed 384/2790, so DEMI's ~15-bucket
	# spread separates instead of collapsing. Clamp the span to MAX_ORDER_SPAN so a stray prim /
	# fixed-mode sentinel can't blow the counting-sort key range. Stable, so the age order above
	# is preserved within each depth bucket.
	var raw_buckets := PackedInt32Array()
	raw_buckets.resize(n)
	var min_bucket: int = _bucket_of(depths[0])
	for i in range(n):
		var b: int = _bucket_of(depths[i])
		raw_buckets[i] = b
		if b < min_bucket:
			min_bucket = b
	var bucket_keys := PackedInt32Array()
	bucket_keys.resize(n)
	var key_max: int = 0
	for i in range(n):
		var nb: int = raw_buckets[i] - min_bucket   # >= 0 (b >= min_bucket)
		if nb > MAX_ORDER_SPAN:
			nb = MAX_ORDER_SPAN
		bucket_keys[i] = nb
		if nb > key_max:
			key_max = nb
	order_idx = _stable_counting_sort(order_idx, bucket_keys, key_max)

	# --- Emit records in depth order + build maximal same-DIRECTION runs (slice C). ---
	# A prim joins the current run iff current-run-direction == prim-direction AND that
	# direction is not MIX (mix never extends or joins — every mix prim is its own run).
	var unified := PackedFloat32Array()
	unified.resize(n * _FLOATS_PER_INSTANCE)
	var runs: Array = []
	var run_dir: int = -1
	var run_base: int = 0
	var run_count: int = 0
	# `depth` = the ot_order_z of the run's BASE (farthest) prim, carried through unchanged for
	# consumers that must place OTHER fold inputs (scene-mesh callbacks) on the same depth scale as
	# these runs. It is the EXACT per-prim depth this ordering used (right depth_mode / DEMI pull),
	# so a consumer bucketing it with DepthMode.UNITS_PER_OT_BUCKET gets a value directly comparable
	# to a callback's own ot_order_z. Runs are emitted far->near so base is the run's farthest prim.
	var run_base_depth: float = 0.0
	for out_i in range(n):
		var src: int = order_idx[out_i]
		var src_off: int = src * _FLOATS_PER_INSTANCE
		var dst_off: int = out_i * _FLOATS_PER_INSTANCE
		for f in range(_FLOATS_PER_INSTANCE):
			unified[dst_off + f] = records[src_off + f]

		var d: int = _direction_of(modes[src])
		if d == run_dir and d != Direction.MIX:
			run_count += 1
		else:
			if run_count > 0:
				runs.append({"mode": _rep_mode_for(run_dir), "base": run_base,
					"count": run_count, "stride": _UNIFIED_STRIDE, "depth": run_base_depth})
			run_dir = d
			run_base = out_i
			run_base_depth = depths[src]
			run_count = 1
	if run_count > 0:
		runs.append({"mode": _rep_mode_for(run_dir), "base": run_base,
			"count": run_count, "stride": _UNIFIED_STRIDE, "depth": run_base_depth})

	return {"unified": unified, "runs": runs}


## View-space-Z ordering key (DepthMode.ot_order_z, world units) -> a FIXED 0.19-u-wide bucket
## index (PSX's SZ>>2). NO frustum term, NO clampf[0,1] — that clamp was the #212 collapse (the
## combat camera's key is ≈ -0.77, clamping it to 0). Ascending in d: more-negative (farther) =
## smaller index. Can be negative; order() normalizes per-frame by subtracting the min.
static func _bucket_of(d: float) -> int:
	return int(round(d / DepthMode.UNITS_PER_OT_BUCKET))


## STABLE counting sort of `indices` ascending by `keys[index]`, where every key is in
## [0, key_max]. O(len(indices) + key_max). Stable: indices with equal keys keep their input
## order (this is what makes the LSD radix in order() compose the primary/secondary/tertiary
## keys without a comparator). `keys` is indexed by the particle index the array holds.
static func _stable_counting_sort(indices: Array, keys: PackedInt32Array, key_max: int) -> Array:
	var counts := PackedInt32Array()
	counts.resize(key_max + 1)   # Packed resize zero-fills
	for idx in indices:
		counts[keys[idx]] += 1
	# Prefix sums -> the start offset of each key's run in the output.
	var start: int = 0
	for k in range(key_max + 1):
		var c: int = counts[k]
		counts[k] = start
		start += c
	var out: Array = indices.duplicate()
	for idx in indices:   # walk in current order -> stable
		var k: int = keys[idx]
		out[counts[k]] = idx
		counts[k] += 1
	return out
