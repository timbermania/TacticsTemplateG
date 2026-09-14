extends RefCounted
## Entirely generated ISO9660/raw2352 fixture. Never uses game content.
const RAW := 2352
const BLOCK := 2048
const TABLE := 0x14d8d0

static func both(data: PackedByteArray, offset: int, value: int, width: int) -> void:
	for i in range(width):
		data[offset + i] = (value >> (8 * i)) & 255
		data[offset + width + i] = (value >> (8 * (width - 1 - i))) & 255

static func record(label: PackedByteArray, lba: int, size: int, directory: bool = false) -> PackedByteArray:
	var data := PackedByteArray()
	data.resize(33 + label.size() + (1 if label.size() % 2 == 0 else 0))
	data[0] = data.size()
	both(data, 2, lba, 4)
	both(data, 10, size, 4)
	data[25] = 2 if directory else 0
	both(data, 28, 1, 2)
	data[32] = label.size()
	for i in range(label.size()):
		data[33 + i] = label[i]
	return data

static func put(image: PackedByteArray, lba: int, data: PackedByteArray, offset: int = 0) -> void:
	for i in range(data.size()):
		var at := offset + i
		image[(lba + at / BLOCK) * RAW + 24 + at % BLOCK] = data[i]

static func make(waveset: PackedByteArray, smd: PackedByteArray, feds: PackedByteArray, sed: PackedByteArray) -> PackedByteArray:
	var image := PackedByteArray()
	image.resize(780 * RAW)
	for sector in range(780):
		for i in range(1, 11):
			image[sector * RAW + i] = 255
		image[sector * RAW + 15] = 2
	var pvd := PackedByteArray()
	pvd.resize(BLOCK)
	pvd[0] = 1
	for i in range(5):
		pvd[1 + i] = "CD001".to_ascii_buffer()[i]
	pvd[6] = 1
	both(pvd, 80, 780, 4)
	both(pvd, 120, 1, 2)
	both(pvd, 124, 1, 2)
	both(pvd, 128, BLOCK, 2)
	var root := record(PackedByteArray([0]), 20, BLOCK, true)
	for i in range(root.size()):
		pvd[156 + i] = root[i]
	put(image, 16, pvd)
	pvd[0] = 255
	put(image, 17, pvd)
	root.append_array(record(PackedByteArray([1]), 20, BLOCK, true))
	root.append_array(record("SOUND".to_ascii_buffer(), 22, BLOCK, true))
	root.append_array(record("EFFECT".to_ascii_buffer(), 23, BLOCK, true))
	root.append_array(record("BATTLE.BIN;1".to_ascii_buffer(), 40, TABLE + 511 * 4))
	put(image, 20, root)
	var sound := record(PackedByteArray([0]), 22, BLOCK, true)
	sound.append_array(record(PackedByteArray([1]), 20, BLOCK, true))
	sound.append_array(record("WAVESET.WD;1".to_ascii_buffer(), 30, waveset.size()))
	sound.append_array(record("MUSIC_00.SMD;1".to_ascii_buffer(), 32, smd.size()))
	sound.append_array(record("MUSIC_01.SMD;1".to_ascii_buffer(), 36, 7))
	sound.append_array(record("SYSTEM.SED;1".to_ascii_buffer(), 34, sed.size()))
	# ENV is deliberately missing. Effect names deliberately out of order.
	put(image, 22, sound)
	var effect_dir := record(PackedByteArray([0]), 23, BLOCK, true)
	effect_dir.append_array(record(PackedByteArray([1]), 20, BLOCK, true))
	effect_dir.append_array(record("E001.BIN;1".to_ascii_buffer(), 750, 0x7f0 + 0x28 + feds.size()))
	effect_dir.append_array(record("E000.BIN;1".to_ascii_buffer(), 755, 0x28 + feds.size()))
	effect_dir.append_array(record("E002.BIN;1".to_ascii_buffer(), 760, 0x28))
	put(image, 23, effect_dir)
	put(image, 30, waveset)
	put(image, 32, smd)
	put(image, 34, sed)
	var table := PackedByteArray()
	table.resize(511 * 4)
	table.encode_u32(0, 0x801c2500)
	table.encode_u32(4, 0x801c2500 + 0x7f0)
	table.encode_u32(8, 0x801c2500)
	put(image, 40, table, TABLE)
	var header := PackedByteArray()
	header.resize(0x28)
	header.encode_u32(0, 0x28)
	header.encode_u32(4, 0x2c)
	header.encode_u32(0x20, 0x28)
	header.encode_u32(0x24, 0x28 + feds.size())
	put(image, 750, header, 0x7f0)
	put(image, 750, feds, 0x818)
	put(image, 755, header)
	put(image, 755, feds, 0x28)
	# E002 header stays zero: corrupt/missing sound, diagnosed on lazy load.
	return image
