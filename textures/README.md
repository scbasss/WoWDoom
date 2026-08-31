# Texture provenance

All art in this folder is extracted from [Freedoom](https://freedoom.github.io/)
(v0.13.0, `freedoom2.wad`), an entirely original replacement game-data set for
the DOOM engine, released under a 3-clause BSD license - see
`FREEDOOM-LICENSE.txt` in this folder (required to travel with the assets).

Freedoom is not id Software/Bethesda's DOOM content: it's a from-scratch
replacement created specifically so DOOM-engine source ports don't need the
commercial game's copyrighted WAD. id's original sprite/texture art is not
used anywhere in this addon and isn't freely licensed - only Freedoom's
original replacement designs are.

| File                | Source lump | What it is                                                     |
|---------------------|-------------|-------------------------------------------------------------------|
| `torch.tga`         | `TREDA0`    | Freedoom's burning red torch decoration                           |
| `creature.tga`      | `TROOA1`    | Freedoom's monster for the "imp" slot (its own original design)   |
| `zombie.tga`        | `POSSA1`    | Freedoom's monster for the "zombieman" slot                       |
| `shotgunguy.tga`    | `SPOSA1`    | Freedoom's monster for the "shotgun guy" slot                     |
| `demon.tga`         | `SARGA1`    | Freedoom's monster for the "demon/pinky" slot                     |
| `wall_outpost.tga`  | `STONEW1`   | Wall texture, Level 1 (The Outpost) - stone/brick                 |
| `wall_garrison.tga` | `COMP01_1`  | Wall texture, Level 2 (The Garrison) - computer panel              |
| `wall_pit.tga`      | `HELL5_1`   | Wall texture, Level 3 (The Pit) - organic hellish rock             |

Extracted with a small custom WAD/picture-format parser (DOOM's picture format
stores images as columns of RLE-ish "posts" against the `PLAYPAL` palette;
areas with no post are transparent by construction, so no color-keying was
needed) - not a general-purpose tool, just enough to pull these lumps.
