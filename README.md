# BF6 Extended Terrain

The full-map terrain that sits **outside** the playable area, for every Battlefield 6
Portal map, so a level stops ending in a void.

## Install

1. Copy `addons/bf6_terrain_pack/` into your Godot project's `addons/` folder.
2. Enable **BF6 Extended Terrain** in Project Settings, Plugins.
3. Open a Portal level, pick a quality in the *Extended Terrain* dock, and it
   downloads that map and shows it.

That is the whole install. This plugin is **standalone**: it needs the Godot
Portal SDK and nothing else. Not the High Poly plugin, not any native extension,
and **not Battlefield 6 installed** - which is the point, because the terrain is
shipped ready-made for people who cannot extract it themselves.

You do not download the meshes from this page by hand; the plugin fetches the map
you have open at the quality you pick and caches it. They live on the
[Releases](../../releases) page because they are large. This repository itself
holds only the plugin, the index and these notes.

## Quality levels

Quality is **metres per vertex**, the same density on every map, so a given level
looks the same everywhere instead of depending on how large the map is.

| quality | maps | total | typical map |
|---|---|---|---|
| 2 m / vertex | 27 | 15.55 GB | 896 MB |
| 4 m / vertex | 27 | 3.92 GB | 224 MB |
| 8 m / vertex | 27 | 1.00 GB | 56 MB |
| 16 m / vertex | 27 | 0.26 GB | 14 MB |

You only ever download one map at one quality, so the numbers that matter are the
per-map ones: about 14 MB for a small map at 16 m, about 900 MB for one of the
large maps at 2 m. Sizes differ by map because the maps differ in area, from
2048 m across (Abbasid) to 8192 m (Dumbo, Golmud, Isolated and the Granite set).

- **2 m** is near the game's own terrain detail. Best for stills or one map you care about.
- **4 m** is the general-purpose choice.
- **8 m** is comfortable for building with everything else loaded.
- **16 m** is a reference silhouette: cheap, and enough to see where the land goes.

The game's own terrain data is 0.5 m or 1.0 m per sample. Those densities are not
published here because a single map at 0.5 m is several gigabytes of mesh. If you
own the game, the High Poly plugin reads it from your install at full detail.

## What is in the files

Geometry only: positions, normals and UVs. No textures and no materials.

The green grid material is **not** in these files and does not need to be. The
plugin reads your SDK's own `M_LevelTerrain` off the level's existing
`<Map>_Terrain` node and applies that, so the extended ground matches the playable
ground exactly, in whatever your SDK ships, rather than an approximation of it.
That also means no game material is redistributed here.

The terrain is placed with `owner = null`, so Godot will never save it into your
scene and it cannot be exported by accident. The shipped low-poly terrain
underneath is untouched; switch it off and everything is as it was.

## Two things that usually go wrong with heightfield terrain

**Which way is up.** Triangle winding was not guessed. The SDK's own low-poly
terrain was measured on MP_Capstone, MP_Abbasid and MP_Battery: every triangle has
`dot(cross(b-a, c-a), normal)` negative. These files are written in true glTF
counter-clockwise, which Godot's importer reverses, so they arrive matching the
terrain beside them. Checked after import, not in the file, because the two
disagree and only one of them is what you see.

**Walls and holes are hard, not sloped.** A plain heightfield mesh interpolates
between samples, so a retaining wall or a pit rim becomes a ramp no matter how
dense the grid is. Cells holding a real vertical feature get their own flat top
and true vertical faces instead. The threshold is taken from each map's own
height-step distribution, because one number cannot serve both a flat urban map
and a mountain: the p99.9 adjacent-sample step is 0.30 m on Plaza and 8.3 m on
Capstone, so any fixed rule either misses every wall on the flat maps or terraces
the hillsides on the steep ones.

## terrain_index.json

The index the plugin reads. One entry per file:

```json
"mp_capstone_8m.glb": {
  "level": "mp_capstone",
  "target_m": 8.0,
  "actual_m": 8.0,
  "step": 16,
  "bytes": 15742960,
  "sha256": "d82ea46b114a11c8f79260914fcc40ae32de6ae3767d3a31e16af0cd7013eef4"
}
```

`target_m` is the quality level asked for and `actual_m` is what that map could
actually deliver; they differ only where a map's native data is already coarser
than the target, in which case it is published at native rather than upsampled
into vertices carrying no new information.
