extends RefCounted

## The addon's ONE injection point for host content it can never ship — ADR-0202 dec. 5's
## "settable search root with a default", built for `Effects` (#1224's sibling item; the
## register rows were seeded by #1225 and carried `#658` as their owner).
##
## WHAT THIS IS FOR. Eight rows of the install register (ADR-0202 Class B) were
## `res://assets/…` literals sitting in addon code: the per-effect `E###` directory, the
## per-callback `callback_data.json` under it, the four TRAP config tables, and the
## `TRAP1` texture/palette pair. All of it is ROM-derived and gitignored (ADR-0142), so
## "move it into the addon" was never available — dec. 5 says so and says the fix instead:
## the addon stops NAMING `res://assets/` and takes a root from the host. The dependency
## survives as a documented contract; the register scores the literal, not the dependency.
##
## 🔴 THE DEFAULT IS EMPTY, ON PURPOSE, AND THAT IS THE WHOLE DESIGN. A default of
## `res://assets/` would leave the literal in an addon file, so the register would still
## score it and the eight rows would not reach 0 — the fix would be booked into the bucket
## it drains. It would also re-create the failure dec. 5 names by name: a bare project
## would silently resolve paths that do not exist and load nothing. Empty means `resolve()`
## refuses, once, in words that name the setting — dec. 5's *"a legible failure instead of
## a silent empty load"*.
##
## THE READ IS **INJECT**, NOT THE READ ADR-0203 dec. 2 FORBIDS. dec. 2's forbidden
## direction is an addon sourcing from `ProjectSettings` configuration it could have
## authored itself. A content root is the opposite case: the addon cannot author where a
## host keeps its ROM rips, so the host is the only possible source. ADR-0203 dec. 1
## blesses exactly this for Class B in the same breath as dec. 2.
##
## THE HOST'S SIDE. `godot-learning/project.godot` declares
## `exmateria_effects/content_root="res://assets/"`, beside the three that already ship
## (`exmateria_battlefield`, `exmateria_catalogue`, `exmateria_sprite_rig`). A stranger
## project either declares its own or gets the refusal above. The claim lives in the addon
## README under ADR-0202 dec. 4, because an install step nobody wrote down is one somebody
## re-derives by crash.
##
## Transcribed from `addons/exmateria_battlefield/install/BattlefieldContent.gd`, which is
## the shipped precedent, rather than adapted — including the once-only `push_error` and
## the `""` return.

## The `ProjectSettings` key a host points at its ROM-derived content tree. A directory
## path; a trailing slash is supplied by `resolve()` so a host may write it either way.
const ROOT_SETTING: String = "exmateria_effects/content_root"

## Subpaths BELOW the root. These are not `res://` literals and are not the register's
## business — they are the shape of the tree the contract describes, and they are named
## here rather than at eight call sites so the contract has one address.
const EFFECTS_SUBPATH: String = "effects/"
const TRAP_SUBPATH: String = "effects/trap/"
const TRAP_TEX_SUBPATH: String = "sprites/textures/TRAP1.tga"
const TRAP_PALETTE_SUBPATH: String = "sprites/textures/TRAP1.palette.tga"

static var _unset_reported: bool = false


## The configured content root, normalised to a trailing slash. `""` when the host has not
## declared one — callers get that through `resolve()` rather than reading this directly.
static func root() -> String:
	var raw: String = str(ProjectSettings.get_setting(ROOT_SETTING, ""))
	if raw.is_empty():
		return ""
	return raw if raw.ends_with("/") else raw + "/"


## `true` when a host has pointed the addon at its content tree.
static func has_root() -> bool:
	return not root().is_empty()


## Resolve a subpath against the content root, or `""` if no host declared one.
##
## Returns `""` rather than a half-formed `res://`-less path so that every caller's own
## existence check fails the way it already fails for a missing file, instead of a
## `DirAccess.dir_exists_absolute("effects/E005")` quietly resolving against the process's
## working directory. The refusal is reported ONCE per run — a cast spawns per action and
## `push_error` per spawn would bury it.
static func resolve(subpath: String) -> String:
	var base: String = root()
	if base.is_empty():
		if not _unset_reported:
			_unset_reported = true
			push_error(
				"ExMateria Effects: no content root. This addon needs ROM-derived "
				+ "content it cannot ship (the per-effect `E###` directories, the TRAP "
				+ "config tables, the TRAP1 texture/palette pair), so a host must declare `"
				+ ROOT_SETTING + "` in project.godot, pointing at the directory holding "
				+ "its `" + EFFECTS_SUBPATH + "` and `sprites/textures/` trees. Until then "
				+ "no effect will load. See the addon README, \"Content the host must "
				+ "supply\"."
			)
		return ""
	return base + subpath


## `res://…/effects/E###` — one effect's directory. `""` when unset.
##
## `effect_name` is the `E%03d` string the caller already built; this function does not
## format it, because two of the three call sites derive it from an ability's effect id and
## the third from an item's directory number, and the formatting is theirs.
static func effect_dir(effect_name: String) -> String:
	var base: String = resolve(EFFECTS_SUBPATH)
	if base.is_empty():
		return ""
	return base + effect_name


## `res://…/effects/E###/callbacks/CB##/callback_data.json` — one callback's ROM payload.
## `""` when unset.
static func callback_data_path(effect_name: String, callback_id: int) -> String:
	var dir: String = effect_dir(effect_name)
	if dir.is_empty():
		return ""
	return "%s/callbacks/CB%02d/callback_data.json" % [dir, callback_id]


## One of the four TRAP config tables, by file name. `""` when unset.
static func trap_table_path(file_name: String) -> String:
	var base: String = resolve(TRAP_SUBPATH)
	if base.is_empty():
		return ""
	return base + file_name


## The ROM-ripped TRAP indexed texture. `""` when unset.
static func trap_tex_path() -> String:
	return resolve(TRAP_TEX_SUBPATH)


## Its palette LUT. `""` when unset.
static func trap_palette_path() -> String:
	return resolve(TRAP_PALETTE_SUBPATH)
