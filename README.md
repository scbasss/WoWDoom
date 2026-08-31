# WoW Doom

A raycasting engine reimplemented against World of Warcraft's UI frame API.

This is **not** id Software's DOOM code or game data — running actual DOOM
data isn't something a WoW addon could do at all (no FFI, no native code
execution, no external processes; addons are sandboxed Lua only). The engine
is an original Wolfenstein/DOOM-style raycaster: a hand-built maze, cast in
pure Lua, drawn as a row of shaded vertical strips using WoW `Texture`
objects — the same primitive used for everything else in this repo's sibling
addon, [Flappy Bird](https://github.com/scbasss/FlappyBird-WoW).

Two sprites (the enemy creature and the torch decoration) are real extracted
game-data, but from [Freedoom](https://freedoom.github.io/) — a completely
original, BSD-licensed replacement for DOOM's WAD data, made specifically so
projects like this don't need id's commercial (still-sold-today) art. See
[`textures/README.md`](textures/README.md) for exactly what was taken from
where, and `textures/FREEDOOM-LICENSE.txt` for the license that travels with
them per its terms.

## Install

Copy the `WoWDoom` folder into your WoW `Interface/AddOns` directory, then
`/reload` and enable it at the character-select AddOns screen.

## Play

`/wowdoom` opens the game window.

- **W/S** or **Up/Down** — move forward/back
- **A/D** or **Left/Right** — turn
- **Escape** or the X button — close

A small debug minimap in the top-left corner shows the maze layout and your
current position/facing.

## How it stays fast

Rendering a first-person view with no GPU/canvas access, only discrete UI
widgets, is the same problem every "DOOM on a constrained surface" novelty
port has solved (spreadsheets, terminals, etc.) — and the fix is the same one
they all converge on:

1. **Low column count.** One `Texture` per screen column (72, not real pixel
   columns) — this is the actual cost driver, not the ray math.
2. **Anchor once, never again.** Each column's texture is centered at its
   final screen position exactly once, at load. Every frame only calls
   `SetHeight()` / `SetVertexColor()` — and only on columns whose value
   actually changed since the last frame, skipping the API call entirely
   otherwise.
3. **Flat shading, not textures.** Walls are distance-darkened solid colors
   with classic two-tone N/S-vs-E/W shading, no per-pixel texture sampling.

## Status

Early and actively evolving. Currently: a walkable maze with wall collision,
enemies with chase AI/contact damage/gunfire, a HP bar and death/respawn, and
real sprite art for the enemy and torch decorations (see above). Multiple
levels with progression between them are next.
