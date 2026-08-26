# WoW Doom

A raycasting engine reimplemented against World of Warcraft's UI frame API.

This is **not** DOOM's code or WAD data — that's not something a WoW addon
could run at all (no FFI, no native code execution, no external processes;
addons are sandboxed Lua only). This is an original Wolfenstein/DOOM-style
raycaster: a hand-built maze, cast in pure Lua, drawn as a row of flat-shaded
vertical strips using WoW `Texture` objects — the same primitive used for
everything else in this repo's sibling addon, [Flappy Bird](https://github.com/scbasss/FlappyBird-WoW).

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

Early and actively evolving — currently a walkable maze with working
collision. Sprites (billboarded objects, depth-sorted against the walls) and
a HUD are next.
