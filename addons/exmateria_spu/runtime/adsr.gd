## The PSX SPU's envelope RATE TABLES — how fast each of the 128 encodable
## rates actually moves, in samples and in envelope units.
##
## The envelope itself is generated natively, inside [ExMateriaPsxSpu], once per
## output sample per voice. These tables exist because a tool that EDITS
## envelopes needs the same numbers to answer "how long is attack rate 58?" in
## milliseconds, and it must be the same table the emulation steps or the
## display lies.
##
## Two tables per rate, both indexed 0-127:
##
##     denominator[rate]  how many 44.1 kHz samples pass per envelope step
##     num_inc[rate]      envelope units added per step while rising
##     num_dec[rate]      envelope units added per step while falling (negative)
##
## Attack is linear below 0x6000 and then quarter-speed; decay, sustain-decrease
## and release are geometric — each step scales by (1 + num_dec/32768). A rate
## therefore has no single duration; derive it for the curve you mean.
##
##     ADSR.build_tables()
##     var steps := ceili(32767.0 / float(ADSR.num_inc[rate]))
##     var attack_ms := steps * ADSR.denominator[rate] * 1000.0 / 44100.0
##
## Source: PCSX-Redux `adsr.cc`. This is console hardware behaviour, not any
## one game's driver data.

# Lazily built once per process; the tables are pure functions of the rate.
static var denominator: PackedInt32Array
static var num_inc: PackedInt32Array
static var num_dec: PackedInt32Array
static var _tables_built := false


## Build the rate tables if they have not been built yet. Cheap and idempotent —
## call it before every read rather than trying to remember whether you have.
static func build_tables() -> void:
	if _tables_built:
		return
	denominator.resize(128)
	num_inc.resize(128)
	num_dec.resize(128)
	for rate in range(128):
		denominator[rate] = 1 if rate < 48 else (1 << ((rate >> 2) - 11))
		if rate < 48:
			var shift: int = 11 - (rate >> 2)
			num_inc[rate] = (7 - (rate & 3)) << shift
			# GDScript can't << a negative number; multiply instead.
			num_dec[rate] = (-8 + (rate & 3)) * (1 << shift)
		else:
			num_inc[rate] = 7 - (rate & 3)
			num_dec[rate] = -8 + (rate & 3)
	_tables_built = true
