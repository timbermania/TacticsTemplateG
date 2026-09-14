extends RefCounted
## Read-only, bounded input adapter for privately supplied audition files.

const FedsBank = preload("res://src/audio_test/audition_feds_bank.gd")
const MAX_FILE_BYTES := 32 * 1024 * 1024

static func read_private(path: String) -> Dictionary:
	var absolute := ProjectSettings.globalize_path(path.strip_edges()).simplify_path()
	var project := ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	if not absolute.is_absolute_path() or absolute == project or absolute.begins_with(project + "/"):
		return {"error": "Choose an absolute path outside the project. Private content is never copied."}
	var file := FileAccess.open(absolute, FileAccess.READ)
	if file == null:
		return {"error": "Cannot read file: " + error_string(FileAccess.get_open_error())}
	var length := file.get_length()
	if length == 0 or length > MAX_FILE_BYTES:
		return {"error": "Expected a nonempty file no larger than 32 MiB."}
	var bytes := file.get_buffer(length)
	if bytes.size() != length:
		return {"error": "Could not read the entire file."}
	return {"bytes": bytes}

static func smd_error(bytes: PackedByteArray) -> String:
	if bytes.size() < 0x22 or bytes.slice(0, 4).get_string_from_ascii() != "smds":
		return "Expected an SMD sequence (smds header)."
	var count := int(bytes[0x14])
	var header_end := 0x22 + count * 2
	if count == 0 or header_end > bytes.size():
		return "SMD track table is missing or truncated."
	var end := int(bytes.decode_u16(0x08))
	if end == 0:
		end = bytes.size()
	if end > bytes.size() or end < header_end:
		return "SMD declared length is invalid."
	var previous := header_end
	for i in range(count):
		var offset := int(bytes.decode_u16(0x22 + i * 2))
		if offset < previous or offset >= end:
			return "SMD track pointer is outside its data or out of order."
		previous = offset
	return ""

static func sound_id_error(bank, sound_id: int) -> String:
	if sound_id == -1:
		return ""
	if sound_id < 0 or bank.data_offset + sound_id >= bank.raw.size():
		return "Sound ID is outside this bank's lookup data. Use -1 for the engine default."
	return ""

static func feds(bytes: PackedByteArray, global_bank: bool = false) -> Dictionary:
	var blob := bytes
	if bytes.size() < 4:
		return {"error": "File is too short for FEDS or E###.BIN."}
	if bytes.slice(0, 4).get_string_from_ascii() != "feds":
		if bytes.size() < 0x28:
			return {"error": "Expected FEDS, ENV.SED, or an E###.BIN with a sound section."}
		# Match the addon's DATA/CODE header detection without invoking its parser
		# until the untrusted offset table has been checked.
		var base := 0
		if (bytes.decode_u32(0) & 0xffff0000) == 0x27bd0000:
			base = -1
			for offset in range(4, mini(bytes.size() - 0x28, 0x400) + 1, 4):
				var animation := int(bytes.decode_u32(offset + 4))
				if bytes.decode_u32(offset) == 0x28 and animation > 0x28 and offset + animation < bytes.size():
					base = offset
					break
			if base < 0:
				return {"error": "No supported CODE effect header found."}
		var sound := int(bytes.decode_u32(base + 0x20))
		var texture := int(bytes.decode_u32(base + 0x24))
		if sound < 0x28 or texture <= sound or base + texture > bytes.size():
			return {"error": "Effect has no valid bounded sound section."}
		blob = bytes.slice(base + sound, base + texture)
	if blob.size() < 0x18 or blob.slice(0, 4).get_string_from_ascii() != "feds":
		return {"error": "No FEDS header found in the sound section."}
	var count := int(blob.decode_u16(8))
	var pairs := count - 1
	var table_end := 0x14 + count * 4
	var data_size := int(blob.decode_u32(4))
	if pairs <= 0 or table_end > blob.size() or data_size < table_end or data_size > blob.size():
		return {"error": "FEDS pair table or declared data length is invalid."}
	var gain := int(blob.decode_u32(12))
	if gain < table_end or gain >= data_size:
		return {"error": "FEDS gain lookup offset is invalid."}
	var bank = FedsBank.new()
	bank.raw = blob.slice(0, data_size)
	bank.magic = "feds"
	bank.data_size = data_size
	bank.pair_count_plus1 = count
	bank.resource_id = int(blob.decode_u16(10))
	bank.data_offset = gain
	var choices: Array[Dictionary] = []
	var diagnostics: Array[String] = []
	if global_bank and (blob.decode_u16(0x14) != 0 or blob.decode_u16(0x16) != 0):
		diagnostics.append("Global sound ID 0 is nonempty and unsupported (no addon pair -1).")
	for pair in range(pairs):
		var a := int(blob.decode_u16(0x18 + pair * 4))
		var b := int(blob.decode_u16(0x1a + pair * 4))
		bank.track_offsets.append(a)
		bank.track_offsets.append(b)
		var sid := pair + 1 if global_bank else -1
		var problem := ""
		if a == 0 and b == 0:
			problem = "Empty sound ID/pair."
		elif (a != 0 and (a < table_end or a >= data_size)) or (b != 0 and (b < table_end or b >= data_size)):
			problem = "FEDS track pointer is outside its opcode data."
		elif global_bank and gain + sid >= data_size:
			problem = "Sound ID gain lookup is outside this bank."
		var single := 1 if a == 0 else (0 if b == 0 else -1)
		choices.append({"pair": pair, "sound_id": sid, "single_track": single, "error": problem})
		if not problem.is_empty():
			diagnostics.append(("Sound ID %d: " % sid if global_bank else "Pair %d: " % pair) + problem)
	# Keep effect-file validation strict for malformed nonzero pointers. Global
	# catalogs retain disabled IDs so holes cannot renumber the original IDs.
	if not global_bank:
		for choice in choices:
			if not choice.error.is_empty():
				return {"error": choice.error}
	return {"bank": bank, "choices": choices, "global": global_bank, "diagnostics": diagnostics}
