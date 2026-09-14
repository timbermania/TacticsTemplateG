# `src/vendor/` — third-party sources, verbatim

Files here are **copies**, not forks. They are not edited, not reformatted, and
not renamed; a diff against upstream must come back empty. Anything this repo
needs to *change* about them belongs in a wrapper under `src/native/`, never in
the file itself.

| path | upstream | licence | why |
|---|---|---|---|
| `supportpsx/adpcm.{h,cc}` | [PCSX-Redux](https://github.com/grumpycoders/pcsx-redux) `src/supportpsx/adpcm.{h,cc}`, commit `1a29d59` (2024-02-28), taken at submodule `ed08297c` | **MIT**, © 2024 PCSX-Redux authors | The PSX ADPCM encoder — `D7` (#380) dec. 5. `ExMateriaSpu.Sample.from_pcm16()` / `.from_wav()` are bindings over it. |

`adpcm.cc` includes its header as `"supportpsx/adpcm.h"`, which is why
`src/vendor` — not `src/vendor/supportpsx` — is what `SConstruct` puts on
`CPPPATH`. That keeps the copy byte-identical to upstream.

**PCSX-Redux as a whole is GPL-2.0**, but `src/supportpsx` is deliberately its
reusable half: 18 of its 19 files carry their own MIT header. Only MIT-marked
files may be copied here. The obligation is to retain the copyright line and
permission paragraph — which the verbatim copy does, and which
`addons/exmateria_spu/NOTICE` restates for anyone who only ever sees the
compiled addon.
