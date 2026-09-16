# [Click here for newest release](https://github.com/mrgudenheim/TacticsEngineG/releases)

# About
This engine is intended to create a game similar to Final Fantasy Tactics (FFT), including reading data from an FFT ROM


Controls:

Selection: Left Mouse

WASD: Move

Q/E: Rotate camera

Space: Jump

Scroll Wheel: Zoom in/out

Escape: Open/Close debug menus

Right click on unit to toggle showing more details about them


Scenarios are exported as a json file to the app data folder. On Windows the app data folder will be similar to C:\Users\[user_name]\AppData\Roaming\TacticsTemplateG\overrides\scenarios
In the scenario editor, unit can be drag and dropped with the mouse.

# Features
- Displays maps
- Displays unit animations
- Dipslays vfx frames (not 3d models or movement)
- FFTae allows exporting a grid sheet of all shp frames
- FFTae allows exporting a gif of an animation
...


# FFTae Limitations and Notes
- Does not show items (MFItem related opcodes)
...


# TacticsEngineG Limitations and Notes
- vfx do not display 3d models
- Indoor maps are practically unplayable because wall geometry intercepts mouse input
- Sometimes units will have trouble reaching the tile they are trying to move to. The unit can be manually controlled with WASD and Spacebar to help it get there.
- Initial loading of the ROM can take a little while (about 10+ seconds for me)
- Loading expanded maps with lots of units can take a while (over a minute for 45 units per team + more time for pathfinding to run)
- Units with lots of ranged actions (ex. Summoner) will take some time to decide what action to take
- The following Reaction / Support / Movement abilities are not implemented:
-- R: Counter Flood, Auto Potion, Distribute, Damage Split, MP Switch, Catch
-- S: Gain JP Up, Gained EXP Up, Equip Change, Train, Secret Hunt, Two Hands, Two Swords, Monster Skill
-- M: Fly, Teleport, Teleport2, Cant enter depth, Move Find Item, Swim, Walk on Water, Move Underwater, Float
- Status Effects partially implemented:
-- No AI changes or team changes (Berserk, Confused, Charm, Invite)
-- Oil status caunts as Fire Weakness
-- Reflect re-targeting not implemented
-- Undead status changing healing to damage not implemented
- Some jobs not fully implemented:
-- Bard, Dancer, Calculator, Mime will not be generated, skillsets not implemented
-- Skillsets not implemented: Chemist Item, Archer Charge, Lancer Jump, Ninja Throw 


# Future Improvements
- Generally improve ability vfx by using more data from vfx files
- UI for unit hp, mp, ct
- Action list UI as a hot bar of icons with tooltip names and descriptions so it can better fit up to 35 actions without scrolling or menus
- Action preview UI to show the hp bar with a overlay bar showing the hp that will be lost, and situationally show the mp and CT bars if they will be affected
- UI to deploy units on maps
- Alternate palettes for weapons and items in animations
- Accurately handle transparency in unit animations
- Allow exporting gif of full ability animation chain
- Statuses
- Victory conditions (defeat all enemies, defeat specific targets, special conditions, ...)
- Turn order preview (aka action timeline) including when delayed actions execute and statuses wear off
- Reaction/Support/Movement abilities
- AI
...

# Building From Source
This project targets Godot 4.7 / GL Compatibility; audio integration is tested with official Godot 4.7.2.
https://godotengine.org/

## Effects addons and distribution

ExMateria Effects (with its platform/render/schema dependencies) draws ability VFX,
the map tint, the screen background gradient, the unit colour track and the cast
camera track. See [effects installation, verification and scope](docs/effects-installation.md).

The ExMateria Sound and SPU addons were **removed**: their PSX SPU emulation carried
PCSX-derived GPL sources and committed native binaries, and they are being replaced by
differently licensed addons. Nothing that remains depended on them — the one runtime
reach from Effects goes through `exmateria_platform`'s `SfxPort`, whose absent path is
the sound engine's own not-ready behaviour, so casts simply play silently. Disc audio
extraction from the ROM (`src/audio_test/`) is host code and is unaffected.

**The distribution is MIT throughout.** `LICENSE.txt` is the original TacticsTemplateG
grant; the Effects selection carries its own upstream MIT grant in
`LICENSES/ExMateria-MIT.txt`. The GPL-3.0 obligation is gone — it came from the removed
audio addons and from the Effects selection's upstream root licence, which has since
been relicensed. Read `THIRD_PARTY_NOTICES.txt`. Do not distribute ROM content.
