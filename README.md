
Parallel roads and tracks tool for all your parallelization dreams.

The mod is in a pretty good place now, but I'll keep hunting for edge cases to make it support as much as possible. The goal is to support everything you can do one by one using the native construction tool. And who knows, maybe even more.

### Features

* Parallel roads and tracks, obviously
* Defaults: 9 tracks, 9 roads – configurable up to 50 in the mod settings
* Preview the build while dragging
* Track across track
* Roads across roads
* Roads across track with level crossings
* Parallel junctions (crossings) including T/Y junctions (at any angle)
* Continuing parallels from the above
* Parallel monster junctions if you want them (12x12 "grids" or worse)
* Straight and curved roads alike
* Level crossings (parallel across parallel)
* Spacing between the parallels, measured between edges or centers (toggleable)
* Wireframe overlay to visualize [nodes](https://en.wikipedia.org/wiki/Vertex_(geometry)) and [edges](https://en.wikipedia.org/wiki/Edge_(geometry)) for advanced users
* Setting to hide Parallelism's build preview (see Mod Compatibility: Auto Bridges)

### Limitations

**Edge cases:** I have done a ton of testing to try to find all the edge cases where it doesn't work. I have fixed a lot, but no doubt many still remain. This is 99% of the work, and I'll be continuing to swat them wherever I find them. You can help – see **Reporting issues** below.

**Performance**: With many parallels crossing many other, the tool will be slow. Lua can only do so much here. Ideally a parallel road and track construction tool will be built into the game natively so it can be much quicker using the game's own C++ engine rather than the Lua wrapper. The nature of this tool requires looking up many, many things in the area around the build. I encourage you to complain to the devs and ask for this to be done in the base game instead. :)

Who knows, maybe the devs are already working on it, but couldn't iron out all the kinks in time for release.

**Level crossings:** For track crossing parallel roads, a certain amount of space is needed to place the barriers/signs *between each road*, which puts a lower limit on the road spacing that can be used. This is true even for a single track (nothing to do with the mod). The required road spacing increases as the track gets further from going straight across the road (i.e. angle between road and track decreases).

**Geometry:** Certain geometries are simply impossible without loosening restrictions – things you're trying to keep true. Those restrictions can be: 

* the roads must be parallel (concentric in a curve);
* the roads must continue straight/smoothly from a junction;
* the bend of a corner must start immediately from a junction.

One concrete example that was a challenge early on: Parallels from angled (non-orthogonal) T junctions into a curve. This is geometrically unsolvable without giving up one of the restrictions in the list above.

There may be other such unsolvable geometries not yet encountered.

### Mod Compatibility

* **Auto Bridges:** Works together with a limitation – while dragging, only one of the two previews can show. Because of how the mods are structured, Parallelism's preview is the one that ends up showing. If you'd rather see the bridges, tick *Hide Parallelism's build preview* in the mod settings. The wireframe can still be used to see the parallels. Hiding the preview does not affect what gets built.

Auto Bridges also only builds bridges within a certain radius (100 m) of the primary road being built. Parallelism can potentially act much wider, so you would end up with bridges nearest the primary, and no bridges on the rest. It's also sensitive to the spacing, especially with tracks. If you get no bridges, try increasing the spacing a bit. At 20 m spacing, 9 parallel roads (C) only get bridges on the 5 central roads, while at 4 m spacing all 9 get bridges. Tracks are more temperamental still.

### Known issues

None currently.

### Unfixable
* Road: [See screenshots](https://imgur.com/a/HBsafao). Workaround: Manually bulldoze the offending road segment.

### Reporting issues

* If you run into something that doesn't work, please send me a screenshot of what you were trying to build, showing the error message it gives you.
* If you run into a crash you believe was caused by the mod, please send me your game log.

* I need this information to figure out what went wrong. Without it, I can't help you.
*  If you're on console, the game log is not available (as far as I know) so we're out of luck.

### Log location

The log is the file `stdout.txt` from your `userdata\crash_dumps` folder.

You can open the userdata folder from inside the game: `Settings > Advanced > Open User Data Folder`.

Otherwise the default locations can be found on the [official wiki](https://wiki.transportfever3.com/doku.php?id=gamemanual:installation:gamefilelocations#folder_locations).

### Contact
* Github: https://github.com/Imsvale/parallelism
* Reddit: [u/Imsvale](https://www.reddit.com/user/Imsvale)
* Discord: `imsvale`

**AI Disclaimer**

This mod was made with the help of Anthropic's Claude. It's been heavily tested and verified by myself. There may still be flaws.