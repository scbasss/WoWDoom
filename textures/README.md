# Texture provenance

Two sprites in this folder are extracted from [Freedoom](https://freedoom.github.io/)
(v0.13.0, `freedoom2.wad`), an entirely original replacement game-data set for
the DOOM engine, released under a 3-clause BSD license - see
`FREEDOOM-LICENSE.txt` in this folder (required to travel with the assets).

Freedoom is not id Software/Bethesda's DOOM content: it's a from-scratch
replacement created specifically so DOOM-engine source ports don't need the
commercial game's copyrighted WAD. id's original sprite art (the actual red
Imp, Zombieman, etc.) is not used anywhere in this addon and isn't freely
licensed - only Freedoom's original replacement designs are.

| File          | Source lump | What it is                                             |
|---------------|-------------|---------------------------------------------------------|
| `creature.tga`| `TROOA1`    | Freedoom's monster for the "imp" slot (its own original creature design, not id's Imp) |
| `torch.tga`   | `TREDA0`    | Freedoom's burning red torch decoration                |

Extracted with a small custom WAD/picture-format parser (DOOM's sprite format
stores images as columns of RLE-ish "posts" against the `PLAYPAL` palette;
areas with no post are transparent by construction, so no color-keying was
needed) - not a general-purpose tool, just enough to pull these two lumps.
