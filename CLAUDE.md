Shared notes for all mods in this folder: `../CLAUDE.md` (and `../docs/`). Cross-mod compatibility rules: `../docs/COMPATIBILITY.md`.

Compatibility review (2026-10-24): `docs/design/2026-10-24_cross-mod-compatibility.md`. Its gap (an EdgeRenderable added without checking for one already in the action) is fixed the guard way: ours is left out of an action that has one, a second one added after ours is refused. Merging our lines into another mod's set is not done.
