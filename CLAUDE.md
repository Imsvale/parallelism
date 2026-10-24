Shared notes for all mods in this folder: `../CLAUDE.md` (and `../docs/`). Cross-mod compatibility rules: `../docs/COMPATIBILITY.md`.

Open compatibility gap (2026-10-24): the ActionDescriptor wrapper in `mod/content/gui/parallelism/parallelism_menu_patch.lua` adds its EdgeRenderable without checking for one already in the action (two crash the game). Review, the issue and the fix: `docs/design/2026-10-24_cross-mod-compatibility.md`.
