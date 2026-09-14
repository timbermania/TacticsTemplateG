extends RefCounted
## Bounded read-only ISO9660 metadata reader for raw Mode2/Form1 sectors.
## No whole-image read, paths persisted, cache writes, or gameplay objects.

const RAW := 2352
const PAYLOAD := 2048
const MAX_IMAGE := 1024 * 1024 * 1024
const MAX_FILE := 32 * 1024 * 1024
const MAX_DIRECTORY := 256 * 1024
const MAX_DIRECTORY_TOTAL := 4 * 1024 * 1024
const MAX_ENTRIES := 8192
const MAX_DEPTH := 8
var file: FileAccess
var sectors := 0
var records: Dictionary = {}
var diagnostics: Array[String] = []
var error := ""
var bytes_read := 0
var _entries := 0
var _directory_bytes := 0
var _visited: Dictionary = {}

func open_private(path: String) -> bool:
	file = null
	records.clear()
	diagnostics.clear()
	_visited.clear()
	_entries = 0
	_directory_bytes = 0
	bytes_read = 0
	error = ""
	var absolute := ProjectSettings.globalize_path(path.strip_edges()).simplify_path()
	var project := ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	if not absolute.is_absolute_path() or absolute == project or absolute.begins_with(project + "/"):
		return _fail("Choose a private absolute disc path outside the project.")
	file = FileAccess.open(absolute, FileAccess.READ)
	if file == null:
		return _fail("Cannot open disc: " + error_string(FileAccess.get_open_error()))
	var length := file.get_length()
	# Check cooked signature separately to give an actionable layout diagnostic.
	if length >= 16 * PAYLOAD + 7:
		file.seek(16 * PAYLOAD + 1)
		if file.get_buffer(5).get_string_from_ascii() == "CD001":
			return _fail("Cooked 2048-byte ISO is unsupported. Supply raw 2352 Mode2/Form1 (24-byte header).")
	if length < 18 * RAW or length > MAX_IMAGE or length % RAW != 0:
		return _fail("Truncated/unsupported raw image size (18 sectors minimum, 1 GiB maximum, whole 2352-byte sectors).")
	sectors = length / RAW
	var pvd := PackedByteArray()
	var terminated := false
	for sector in range(16, mini(sectors, 48)):
		var data := read_span(sector, 0, PAYLOAD)
		if data.is_empty():
			return false
		if data.slice(1, 6).get_string_from_ascii() != "CD001" or data[6] != 1:
			return _fail("Unsupported volume descriptor (expected CD001 version 1).")
		if data[0] == 1:
			if not pvd.is_empty():
				return _fail("Multiple primary volumes are unsupported.")
			pvd = data
		elif data[0] == 255:
			terminated = true
			break
	if pvd.is_empty() or not terminated:
		return _fail("Missing primary volume or descriptor terminator.")
	var volume := int(pvd.decode_u32(80))
	if volume <= 16 or volume > sectors or volume != _be(pvd, 84, 4) or pvd.decode_u16(128) != PAYLOAD or _be(pvd, 130, 2) != PAYLOAD or pvd.decode_u16(120) != 1 or _be(pvd, 122, 2) != 1 or pvd.decode_u16(124) != 1 or _be(pvd, 126, 2) != 1:
		return _fail("Unsupported volume size/block size/multi-volume layout.")
	sectors = volume
	var root := _record(pvd.slice(156, 156 + int(pvd[156])))
	if root.has("error") or not root.get("directory", false):
		return _fail("Invalid root directory record.")
	return _walk(root, "", 0)

func _fail(message: String) -> bool:
	error = message
	return false

static func _be(data: PackedByteArray, offset: int, count: int) -> int:
	var value := 0
	for i in range(count):
		value = (value << 8) | data[offset + i]
	return value

func _record(data: PackedByteArray) -> Dictionary:
	if data.size() < 34 or data[0] != data.size() or data[32] == 0 or 33 + int(data[32]) > data.size():
		return {"error": "Malformed directory record/name length."}
	var lba := int(data.decode_u32(2))
	var length := int(data.decode_u32(10))
	if lba != _be(data, 6, 4) or length != _be(data, 14, 4) or lba >= sectors or length > (sectors - lba) * PAYLOAD:
		return {"error": "Directory record extent/length outside volume or endian mismatch."}
	if data[1] != 0 or data[26] != 0 or data[27] != 0 or (data[25] & ~3) != 0 or data.decode_u16(28) != 1 or _be(data, 30, 2) != 1:
		return {"error": "Unsupported extended/interleaved/multi-extent record."}
	return {"lba": lba, "length": length, "directory": bool(data[25] & 2), "name": data.slice(33, 33 + int(data[32])).get_string_from_ascii().trim_suffix(";1")}

func _walk(record: Dictionary, path: String, depth: int) -> bool:
	if depth > MAX_DEPTH or _visited.has(record.lba):
		return _fail("Directory recursion/cycle limit exceeded.")
	_visited[record.lba] = true
	var length: int = record.length
	_directory_bytes += length
	if length <= 0 or length > MAX_DIRECTORY or _directory_bytes > MAX_DIRECTORY_TOTAL:
		return _fail("Directory byte budget exceeded.")
	var data := read_span(record.lba, 0, length)
	if data.size() != length:
		return false
	var offset := 0
	while offset < length:
		var size := int(data[offset])
		if size == 0:
			offset += PAYLOAD - (offset % PAYLOAD)
			continue
		_entries += 1
		if _entries > MAX_ENTRIES or size > length - offset or size > PAYLOAD - offset % PAYLOAD:
			return _fail("Directory entry count or record boundary invalid.")
		var entry := _record(data.slice(offset, offset + size))
		offset += size
		if entry.has("error"):
			diagnostics.append(path + ": " + entry.error)
			continue
		# ISO self and parent records must not be recursed.
		if size >= 34 and data[offset - size + 32] == 1 and data[offset - size + 33] <= 1:
			continue
		var name: String = entry.name
		if name.is_empty() or name.contains("/") or name.contains("\\") or name == "." or name == "..":
			return _fail("Unsupported directory identifier.")
		var key := path.path_join(name) if not path.is_empty() else name
		if entry.directory:
			if not _walk(entry, key, depth + 1):
				return false
		elif records.has(key):
			return _fail("Duplicate directory identifier: " + key)
		else:
			records[key] = entry
	return true

func read_file(record: Dictionary, offset: int = 0, count: int = -1) -> Dictionary:
	if count == -1:
		count = int(record.length) - offset
	if int(record.length) > MAX_FILE or offset < 0 or count <= 0 or offset > int(record.length) or count > int(record.length) - offset:
		return {"error": "File size/read exceeds declared length or 32 MiB budget."}
	var data := read_span(record.lba, offset, count)
	if data.size() != count:
		return {"error": error}
	return {"bytes": data}

func read_span(lba: int, offset: int, count: int) -> PackedByteArray:
	var output := PackedByteArray()
	if file == null or lba < 0 or offset < 0 or count <= 0 or count > MAX_FILE or lba >= sectors or offset + count > (sectors - lba) * PAYLOAD:
		_fail("Read outside bounded volume.")
		return output
	while count > 0:
		var sector := lba + offset / PAYLOAD
		file.seek(sector * RAW)
		var header := file.get_buffer(24)
		bytes_read += header.size()
		if header.size() != 24 or header[0] != 0 or header[11] != 0 or header[15] != 2 or header.slice(16, 20) != header.slice(20, 24) or (header[18] & 0x20) != 0:
			_fail("Unsupported/truncated sector: expected raw2352 Mode2/Form1, 24-byte header.")
			return PackedByteArray()
		for i in range(1, 11):
			if header[i] != 255:
				_fail("Invalid raw sector sync.")
				return PackedByteArray()
		var take := mini(count, PAYLOAD - offset % PAYLOAD)
		file.seek(sector * RAW + 24 + offset % PAYLOAD)
		var part := file.get_buffer(take)
		bytes_read += part.size()
		if part.size() != take:
			_fail("Truncated sector payload.")
			return PackedByteArray()
		output.append_array(part)
		offset += take
		count -= take
	return output
