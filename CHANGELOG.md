# Changelog

Each release: version, the `revision` in `mod/mod.json` (what the game shows), date. The
entry is also the changelog text for the mod.io upload.

## Unreleased

## 1.1.0 (revision 4), 2026-10-27

- Much faster while dragging, especially with many parallels and when ending on another road (T junctions).
- Big track bundles build much faster: they're now built in several steps instead of all at once.
- The number of roads/tracks is now a slider instead of buttons.
- The max number of roads/tracks in the mod settings now goes up to 50.
- Wireframe now also shows the network around the camera while not dragging, with node markers as magenta squares.
- Fixed a possible crash with other mods that draw lines in the construction view.
- Level crossings follow the game's own spacing rules: tracks side by side cross a road like the game's own tool allows (touching), and crossings near road junctions fit as close as the barriers allow.
- Crossing a road just before it bends now works like the game's own road tool instead of being refused.
- Parallels ending at a road no longer pick up pieces of that road and wrap around to the other side.
- The Side setting is kept when the drawn road ends at a road near another road's dead end.
- The build preview keeps up better with slow drags.

## 1.0.2 (revision 3), 2026-10-21

- New setting: Hide Parallelism's build preview. Tick it to see Auto Bridges' preview instead.

## 1.0.1 (revision 2), 2026-10-21

- Fixed a crash when used together with Auto Bridges.
- Writes much less to the game log.

## 1.0.0 (revision 1), 2026-10-06

- First release.
