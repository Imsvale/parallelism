
Parallel roads and tracks tool for all your parallelization dreams.

The mod is in a pretty good place now, but I'll keep hunting for edge cases to make it support as much as possible. The goal is to support everything you can do one by one using the native construction tool. And who knows, maybe even more.

### Features

* Parallel roads and tracks, obviously
* Defaults: 9 tracks, 9 roads – configurable (see limitations below)
* Preview the build while dragging
* Track across track
* Roads across roads
* Roads across track with level crossings
* Parallel junctions (crossings) including T/Y junctions (at any angle)
* Continuing parallels from the above
* Parallel monster junctions if you want them (12x12 "grids" or worse)
* Straight and curved roads alike
* Spacing between the parallels, measured between edges or centers (toggleable)
* Wireframe overlay to visualize [nodes](https://en.wikipedia.org/wiki/Vertex_(geometry)) and [edges](https://en.wikipedia.org/wiki/Edge_(geometry)) for advanced users

### Limitations

**Edge cases:** I have done a ton of testing to try to find all the edge cases where it doesn't work. I have fixed a lot, but no doubt many still remain. This is 99% of the work, and I'll be continuing to swat them wherever I find them. You can help – see **Reporting issues** below.

**Construction panel size:** The mod supports an arbitrary number of parallel roads and tracks, but the construction panel can only fit so many buttons for the setting. You can change the defaults (listed above), but the panel starts to look weird at 10+, and really cramped beyond 12. At 16 the tens are all squished, so that's the current cap.

I might look into ways to present more options more cleanly, but needing more than 10 seems pretty niche.

**Performance**: With many parallels crossing many other, the tool will be slow. Lua can only do so much here. Ideally a parallel road and track construction tool will be built into the game natively so it can be much quicker using the game's own C++ engine rather than the Lua wrapper. The nature of this tool requires looking up many, many things in the area around the build. I encourage you to complain to the devs and ask for this to be done in the base game instead. :)

Who knows, maybe the devs are already working on it, but couldn't iron out all the kinks in time for release.

### Known issues

* Road: Angled (non-orthogonal) T junction into curve has a limited angular range on the curve. The possible range expands the closer to 90° the T junction is.


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