# ExMateria SPU

A **PlayStation 1 SPU for Godot 4**. Twenty-four voices of ADPCM playback with
the console's own ADSR envelopes, pitch and volume LFOs, noise, frequency
modulation and reverb — mixed by a native C++ core and delivered as an
`AudioStream`.

Bring your own samples. This addon knows nothing about any particular game.

> **A clone of this repository is SOURCE, not an install.** `bin/` is
> gitignored, so a clone has no compiled library and nothing will load. Install
> from a [release ZIP](https://github.com/timbermania/ExMateria-Sound/releases),
> or build it yourself (see *Building* below).

## Install

1. Unzip `exmateria_spu-vX.Y.Z.zip` into your project root — it creates
   `addons/exmateria_spu/`.
2. **Project → Project Settings → Plugins**, enable **ExMateria SPU**.
3. Restart the editor once so the GDExtension registers.

Requires **Godot 4.4** or newer. Verified on stock 4.4, 4.5 and 4.7 (Linux x86_64).

## Hear it in ten seconds

The addon ships a demo scene that needs nothing else — no downloads, no assets,
no setup. Open

```
addons/exmateria_spu/demo/demo.tscn
```

and press **Run Current Scene** (F6).

A piece starts playing that the SPU synthesised into its own RAM about ten
milliseconds earlier. No audio file is involved and none ships: the bass, pad
and lead are band-limited harmonic stacks put through `from_pcm16`, the kick is
a sine whose pitch falls, and the hats and snare are the chip's own noise
generator. The pad, the lead and the snare are wet through the reverb tank.

Everything on the screen is a register write. Mute a part and its key-ons stop
going out — the key-offs still do, which is why nothing sticks on. Drag the
noise clock and the hats change character. Switch the reverb tank off and the
tails vanish. The readout underneath is the scheduler's own health: how far
ahead of the audio clock it is running, and whether any write landed late or was
dropped.

Two files, split the way any sound driver splits:

| | |
|---|---|
| `demo/demo_song.gd` | the score — sample synthesis, and a list of register writes with the frame each one belongs at. No Node, no scene, no audio device |
| `demo/demo.gd` | the audio path — hands the SPU to an `ExMateriaSpuStream` and stays a third of a second ahead of the audio clock, stamping the score's writes |

That split is what makes the demo testable rather than merely audible: the same
score rendered offline through `render_deferred_pcm16` comes out
sample-for-sample as what you just heard.

Neither file declares a `class_name`, so running the demo adds nothing to your
project's global namespace.

## What you get

One `class_name`, `ExMateriaSpu`, and everything the addon publishes hangs off
it as a constant. A script constant is a full type: it works as an annotation,
in an `is` check and for `.new()`.

| | |
|---|---|
| `ExMateriaSpu.Spu` | the GDScript handle — the whole register interface |
| `ExMateriaSpu.Sample` | one sample: ADPCM bytes, a loop point, a root pitch. Encodes from PCM or `.wav` |
| `ExMateriaSpu.ADSR` | the SPU's envelope rate tables, for tools that display envelope times |

Four more names come from the GDExtension, and a façade cannot hide those —
ClassDB is global and has no namespace to move them into, which is why they
carry the prefix in their own spelling:

| | |
|---|---|
| `ExMateriaPsxSpu` | the native core `ExMateriaSpu.Spu` forwards to. You rarely touch it directly |
| `ExMateriaSpuAdpcm` | the PSX ADPCM encoder. `ExMateriaSpu.Sample` is the friendly way in |
| `ExMateriaSpuStream` | an `AudioStream` that renders an `ExMateriaSpu.Spu` on the audio thread |
| `ExMateriaSpuPlayback` | the stream's playback object. Godot instantiates it; you do not |

**Five global names, and that is the whole footprint** — one declared by
GDScript `class_name` and four registered by the GDExtension. The acceptance rig
counts them against this sentence on every run, so the number in it is measured
rather than remembered.

`ExMateriaSpu.Sample` was called `ExMateriaSpuSample` up to `#383`. The prefix
was there because there was no namespace to put the type in; now there is one,
and carrying both would spell `ExMateriaSpu.ExMateriaSpuSample`.

## Make a sound

You do not need PSX ADPCM to start. Hand it 16-bit PCM and it encodes for you:

```gdscript
func _ready() -> void:
    # A second of 440 Hz. Any source of 16-bit samples will do.
    var pcm := PackedInt32Array()
    for i in range(44100):
        pcm.append(int(round(20000.0 * sin(TAU * 440.0 * float(i) / 44100.0))))

    # loop_at is a SAMPLE index; 0 loops the whole thing, -1 is a one-shot.
    var sample := ExMateriaSpu.Sample.from_pcm16(pcm, 0)

    var spu := ExMateriaSpu.Spu.new()
    var idx := spu.load_samples([sample])

    #          voice, instrument, pitch,  vol L,  vol R,  adsr1,  adsr2
    spu.key_on(0,     idx[0],     0x1000, 0x3FFF, 0x3FFF, 0x000F, 0x1FDF)

    var pcm_out := spu.render_interleaved_pcm16(4410)   # 100 ms, interleaved L,R
    var peak := 0
    for v in pcm_out:
        peak = maxi(peak, absi(v))
    print("peak ", peak)   # 10031
```

`pitch` `0x1000` is 1:1 with the 44.1 kHz output rate; halve it to drop an
octave. Volumes are 14-bit, `0x3FFF` being full scale. The `adsr1`/`adsr2` pair
is the envelope, and it belongs to the note rather than to the sample — which is
why `key_on` takes it and `ExMateriaSpu.Sample` does not carry one.

That envelope, incidentally, is why the peak above is about half the amplitude
that went in: `adsr1 = 0x000F` sustains at half scale, and it gets there within
50 samples.

`0x000F` is the pair most PSX examples reach for, and half scale is not what it
looks like it should do — sustain level 15 reads as *sustain at the top*. The
other nibble is why: `0x000F` also sets **decay rate 0**, and the decay phase
takes one step before the sustain-level check can stop it. At rate 0 that one
step is half of full scale. Raise the decay nibble and the step becomes
negligible:

| `adsr1` | attack | decay | sustain level | holds at |
|---|---|---|---|---|
| `0x000F` | instant | 0, the fastest | 15 | **half** scale |
| `0x00FF` | instant | 15, the slowest | 15 | **full** scale |

So `0x00FF` is the pair to use when you want a note to sit where you put it.
The demo scene's `demo_song.gd` documents the rest of the envelopes it uses the
same way — each one measured against this core rather than copied from a
hardware document.

### Where do I get PSX ADPCM?

You make it. `ExMateriaSpu.Sample.from_pcm16()` and `.from_wav()` encode for you
at roughly 1800x realtime, so you never *need* an import step or an external
tool:

```gdscript
var spu := ExMateriaSpu.Spu.new()
var kick := ExMateriaSpu.Sample.from_wav("res://kick.wav", -1)      # one-shot
var pad := ExMateriaSpu.Sample.from_wav("res://pad.wav", 12000)     # loops at sample 12000
var indices: PackedInt32Array = spu.load_samples([kick, pad])
```

`from_wav` takes 16-bit PCM RIFF/WAVE, mono or stereo (downmixed), at any sample
rate. It does **not** resample: the file's rate is carried on the sample as
`base_pitch_cents` — a 22050 Hz file gets `-1200.0`, because played at the SPU's
nominal rate it would sound an octave high — and what you do with that number at
`key_on` is yours to decide.

Deciding it is one line, and it is the same line whatever note table you go on to
build on top: `base_pitch_cents` is an offset in cents against the `0x1000` that
plays 1:1 with the output rate.

```gdscript
var spu := ExMateriaSpu.Spu.new()
var voice := ExMateriaSpu.Sample.from_wav("res://voice_22050.wav", -1)
var loaded: PackedInt32Array = spu.load_samples([voice])
# 0x1000 is 1:1; every 1200 cents is a factor of two.
var pitch := int(round(0x1000 * pow(2.0, voice.base_pitch_cents / 1200.0)))
spu.key_on(0, loaded[0], pitch, 0x3FFF, 0x3FFF, 0x000F, 0x0000)
```

For the 22050 Hz file that is `0x800` — half rate, an octave down, cancelling the
octave the SPU would otherwise add. **Skip it and the sample plays an octave
high**, which is the one way this seam bites. The SPU does not apply it for you
on purpose: the rate a file was recorded at belongs to the file, the pitch a note
sounds at belongs to the note, and only the caller knows the second one. That is
the same reason `key_on` takes an envelope and `ExMateriaSpu.Sample` does not
carry one.

The encoder is a verbatim copy of [PCSX-Redux](https://github.com/grumpycoders/pcsx-redux)'s
re-creation of Sony's Psy-Q `encvag`, used under the MIT licence. See `NOTICE`.

### Or do it in the Import dock

Enabling the plugin also registers an importer called **ExMateria SPU Sample**.
Select a `.wav` in the FileSystem dock, open the **Import** tab, choose it in the
*Importer* dropdown, and press **Reimport**. From then on that file loads as an
`ExMateriaSpu.Sample` instead of an `AudioStreamWAV`, and the three fields below
travel with it in the `.import` file rather than living in your code.

**It does not take your `.wav` files.** The importer registers *below* Godot's
own WAV importer, so every other `.wav` in your project keeps importing exactly
as it did before you installed this. Nothing changes until you point the dock at
a file. That is deliberate: an addon is a component in your project, not your
project's audio policy, and an importer that reassigned every `.wav` on enable
would break `AudioStreamPlayer.stream` references it has nothing to do with.

| option | values | default | what it does |
|---|---|---|---|
| `edit/loop_mode` | Disabled / Forward / Detect From WAV | `0` (Disabled) | Disabled is a one-shot. Forward loops from `edit/loop_begin` to the end. Detect reads the file's own RIFF `smpl` chunk, and falls back to a one-shot if it has none — or if the loop it finds is one the SPU cannot encode. |
| `edit/loop_begin` | samples | `0` | Where the loop starts, in samples. Floored to a 28-sample block, because the SPU's loop marker is a flag on a block. Only shown when the mode is Forward. |
| `pitch/tune_cents` | cents | `0.0` | **Added to** the `base_pitch_cents` the source rate already implies — it is a trim, not an override, so replacing a 22050 Hz file with a 44100 Hz one still lands in tune. |

There is no `edit/loop_end` and no ping-pong: a PSX loop always runs to the end
of the sample, and the block flags cannot express a backward one. A file whose
`smpl` chunk asks for ping-pong or backward is imported as a **one-shot** — the
loop is refused rather than flattened into a forward one the file never asked
for.

The importer warns whenever the result differs from what you asked it for, and
stays quiet otherwise: on that refused loop, on Detect finding no `smpl` chunk
at all, and when it downmixes a stereo file to mono. A failure it cannot recover
from is an import error in the dock, with the reason already in the Output
panel.

An import plugin has no code you call, so there is nothing here to run. What you
write is what you would have written anyway, minus the encoding:

```gdscript
# The dock already encoded it. At run time you just load the result.
var kick: ExMateriaSpu.Sample = load("res://kick.wav")
var spu := ExMateriaSpu.Spu.new()
var indices: PackedInt32Array = spu.load_samples([kick])
spu.key_on(0, indices[0], 0x1000, 0x3FFF, 0x3FFF, 0x000F, 0x1FDF)
```

### Loop points live in the bytes

PSX ADPCM is 16-byte blocks, and every block's second byte is a flag field: bit
2 marks the loop point, bit 0 ends the sample, and bits 0 and 1 together mean
*jump back to the loop point* rather than *stop*. That is where the SPU looks
for a loop, so that is where a loop is.

`ExMateriaSpu.Sample.loop_offset` is the author-time way to say it — a byte
offset, or `-1` for "the bytes already say what I mean". `load_samples` stamps
the flags into a copy at upload time; your resource is not modified. The loop
point cannot land in the sample's final block, because one block cannot be both
the start and the end of a loop; `from_pcm16` handles that case for you.

## The raw bank door

If your samples are already packed into one image whose internal offsets mean
something — several instruments addressing one shared window, the way a PSX
game's own sample bank does — go in through `load_instruments` instead and keep
that structure. The two doors sit over one implementation.

This example synthesises its own ADPCM and needs no asset files at all:

```gdscript
# One 16-byte PSX ADPCM block. Header byte is (predictor << 4 | shift);
# predictor 0 with shift 0 means each 4-bit nibble is just (n << 12)
# sign-extended, so this is a literal square wave.
func adpcm_block(flags: int) -> PackedByteArray:
    var b := PackedByteArray()
    b.append(0x00)      # predictor 0, shift 0
    b.append(flags)     # bit 0 = loop end, bit 1 = repeat, bit 2 = loop start
    for i in range(14):
        b.append(0x77 if (i % 2) == 0 else 0x99)   # +7,+7 then -7,-7
    return b


func _ready() -> void:
    var spu := ExMateriaSpu.Spu.new()

    # Eight blocks: the first marks the loop point, the last loops back to it.
    # Nothing in the descriptor below says so — the flags in these bytes do.
    var bank := PackedByteArray()
    bank.append_array(adpcm_block(0x04))
    for i in range(6):
        bank.append_array(adpcm_block(0x00))
    bank.append_array(adpcm_block(0x03))

    # sample_size is the only required key; the core defaults the rest.
    var descriptor := {
        "sample_size": bank.size(),
        "sample_offset": 0,     # byte offset into the bank
        "adsr1": 0x000F,        # attack rate 0 (fastest), sustain level 15
        "adsr2": 0x1FDF,        # sustain rate 127 (slowest), release rate 31
    }

    spu.load_instruments([descriptor], bank)
    #        voice, instrument, pitch,  vol L,  vol R,  adsr1, adsr2
    spu.key_on(0,   0,          0x1000, 0x3FFF, 0x3FFF, 0x000F, 0x1FDF)

    var pcm := spu.render_interleaved_pcm16(4410)   # 100 ms, interleaved L,R
    var peak := 0
    for v in pcm:
        peak = maxi(peak, absi(v))
    print("peak ", peak)   # 18325
```

## Playing it live

`render_interleaved_pcm16` is the offline path. For real-time audio, hand the
SPU to a stream and let the audio thread drive it:

```gdscript
var spu := ExMateriaSpu.Spu.new()
spu.load_samples([ExMateriaSpu.Sample.from_wav("res://kick.wav")])
spu.set_deferred_mode(true)          # register writes queue, stamped by frame

var stream := ExMateriaSpuStream.new()
stream.set_mixer(spu.get_native())

var player := AudioStreamPlayer.new()
player.stream = stream
player.bus = "Master"
add_child(player)
player.play()
```

In deferred mode every register write is **stamped** with
`set_schedule_frame()` and applied by the audio thread at that frame, so you
can schedule notes ahead of the playhead and the output is bit-identical to an
offline render. Keep the scheduler's lead above one mix block plus the output
latency, and watch `get_deferred_stats()` — `overdue` and `overflow` should
both stay at zero.

`reset()`, `load_samples()`, `load_instruments()`, `seed_voice_residue()`,
`set_noise_state()`, the reverb address setters and every `render_*` call need
the stream **stopped**; they touch state the audio thread is reading.

## Two things that will surprise you

**The noise generator is process-global, not per-`ExMateriaSpu.Spu`.** The console has one
SPU with one LFSR, and this is faithful to it. Instantiate several
`ExMateriaSpu.Spu`s and
they share noise phase, so a fresh one inherits whatever the last one left
behind. If a run has to be reproducible, seed it with `set_noise_state()`.

**Note space is not the SPU's.** The pitch register takes a raw frequency
ratio; mapping a musical note to it is a driver's job, and every PSX title did
it differently. This addon ships no note table, so `set_voice_pre_pitch()` does
nothing on its own — compute the raw pitch yourself and use `set_voice_pitch()`.

## Building

```bash
git clone --recursive https://github.com/timbermania/ExMateria-Sound.git
cd ExMateria-Sound
git clone --depth 1 --branch godot-4.4-stable \
    https://github.com/godotengine/godot-cpp.git extern/godot-cpp
scons target=template_debug
```

Build against the godot-cpp branch matching the **oldest** Godot you intend to
support: a library built against godot-cpp 4.5 will not load in Godot 4.4, and
fails with `Attempt to get non-existent interface function: get_godot_version2`
rather than anything that mentions versions.

## License

GPL-3.0 —
[LICENSE](https://github.com/timbermania/ExMateria-Sound/blob/main/LICENSE).
Absolute, because the release ZIP is the `addons/exmateria_spu/` folder and
nothing above it, so a relative link out of the addon lands in your project.

The compiled library also contains third-party MIT-licensed code — the PSX
ADPCM encoder behind `ExMateriaSpu.Sample.from_pcm16()`. Its notice is in
`NOTICE`, beside this file, and it ships inside the addon for that reason.
