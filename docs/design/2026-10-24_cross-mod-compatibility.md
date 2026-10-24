# Cross-mod compatibility: what Parallelism's hooks get right, and one gap to fix

Reviewed 2026-10-24 (from path-visualizer, which wraps the same builtins). Background and the
general rules: `../../../docs/COMPATIBILITY.md`.

## How Parallelism hooks in

`parallelism_menu_patch.lua`, `patch.install()` (run when the entry plugin loads), reassigns
fields of shared module tables, each time keeping the previous value and calling it:

- `construction_react_util.getTrackDefinitions`, `getStreetDefinitions`, `getActionParams`;
- `builtin.ProposalViewer` (to recognise every preview made, whoever makes it);
- `builtin.ActionDescriptor` (to add the preview, Wireframe lines and the network overlay).

## What's right

- **It chains.** Every patch calls the value it replaced, never the game's original. Other
  mods patching the same fields chain with it in either order.
- **Slot replacements can't knock it out.** Its wrapper sits around the recipe function, which
  only then looks up `_react.recipeReplace`, so a `react-replacement-config` mod (even one
  calling the original) can't remove it, and Parallelism can't remove such a mod either.
  Parallelism's ActionDescriptor wrapper is therefore always the outermost: it runs before
  any slot wrapper.
- **No game code bypasses the patches.** Checked in `game-src`: nothing captures
  `builtin.ActionDescriptor`, `ProposalViewer`, `EdgeRenderable` or the three
  `construction_react_util` functions in a local early; the one table listing the definition
  functions (`construction_react_util.tl` ~2798) is built when used.
- **It draws through `builtin.EdgeRenderable{…}`**, so a mod wrapping EdgeRenderable can merge
  into its line set (path-visualizer does: the two share one).
- **ProposalViewer limit guarded** (the Auto Bridges crash, fixed in 1.0.1): viewers are
  recognised by their constructor; Parallelism leaves its own out if another mod's is already
  in the descriptor, and refuses a second one added by an inner wrapper (a `__newindex` guard
  on the children table).

## The gap: its EdgeRenderable is added without checking for one

Near the end of the ActionDescriptor wrapper:

```lua
if #lines > 0 and params and params.children then
	params.children[#params.children + 1] = builtin.EdgeRenderable{ edges = lines, ignoreDepth = true }
end
```

An ActionDescriptor takes at most one EdgeRenderable ("Must not specify more than 1
EdgeRenderable", a fatal error). If the action already has one, the game crashes.

- **Release:** lines are only added in the road and track builders (preview Wireframe, refused
  plan), where the game adds none. A crash needs another mod putting an EdgeRenderable into a
  builder action without merging. Mods wrapping inside Parallelism (any slot wrapper) are fine
  if they merge as path-visualizer does; the danger is one adding its own unchecked, before
  Parallelism (an outer field patch installed later) or after it.
- **Dev build:** the network overlay, while on, adds lines to *every* action. A tool with its
  own EdgeRenderable (node-swatter, the traffic-lab tools, any mod tool drawing lines) then
  crashes the game.

### Fix

Done 2026-10-24 (the guard below, plus the same `__newindex` refusal as for viewers; the
merge is not done).

Recognise EdgeRenderables the same way as viewers, and never add a second one:

```lua
local renderables = {}
local EdgeRenderable = builtin.EdgeRenderable
builtin.EdgeRenderable = function(...)
	local node = EdgeRenderable(...)
	if node ~= nil then renderables[node] = true end
	return node
end
local function holdsRenderable(children)
	for __, child in ipairs(children) do
		if renderables[child] then return true end
	end
	return false
end
```

then, in the ActionDescriptor wrapper:

```lua
if #lines > 0 and params and params.children then
	if holdsRenderable(params.children) then
		-- leave ours out (log once), as with a second viewer
	else
		params.children[#params.children + 1] = builtin.EdgeRenderable{ edges = lines, ignoreDepth = true }
	end
end
renderables = {} -- with viewers = {} after the call
```

That turns the crash into "Parallelism's lines don't show in that action". To show them
anyway, merge instead: also have the EdgeRenderable wrapper append Parallelism's current
lines to the `edges` of an EdgeRenderable built inside a builder action, and then not add one
(path-visualizer's `path_visualizer_replace.script.lua` does this with a flag: children are
built before their descriptor). That needs the lines known when the action builds its
children, i.e. computed from module state rather than inside the descriptor wrapper.

## Smaller limitations (no action needed now)

- The second-viewer guard watches the children table it was handed. An inner wrapper that
  copies the children into a new table (path-visualizer's does) and adds a viewer there gets
  past it. Only matters if such a wrapper adds a viewer.
- Viewers made by a mod that kept its own reference to `builtin.ProposalViewer` from before
  Parallelism loaded aren't recognised. Auto Bridges evidently doesn't (the guard works).

## Auto Bridges and the build (read from its code, mod.io 6450598, 2026-10-24)

Auto Bridges rebuilds after the build, not in it. Its game script queues every applied
build as a job; its `guiUpdate` rebuilds the jobs that match a confirmed tool build onto
ramps and a bridge, a frame or more later.

- Parallelism sends its build right after the player's, reading the drawn road while it is
  still plain, so its parallels are built plain. That ordering is why the two work: if Auto
  Bridges rebuilt first, the drawn edges Parallelism reads would be gone.
- Auto Bridges then bridges our parallels through its generic fallback: new segments of a
  non-tool build lying 3 to 100 m beside a way it bridged in the last 20 s, within about 18
  degrees of its direction, are bridged with the same settings, each planned on its own
  (own crossings, ramps and heights). Parallels further than 100 m out keep their level
  crossings; a failed rebuild of one parallel leaves the others.
- Its dedicated support (wait for the parallels, raise them with the drawn track in one
  build, following its heights) is for a different mod.io mod, "Parallel Tracks", detected
  by that mod's toolbar key `parallelTracksEnabled`. It doesn't apply to Parallelism.
- The build preview shows none of this (Parallelism's preview is planned from the road as
  dragged).

Decided 2026-10-24 (user): no coordination with Auto Bridges, neither a shared preview nor
a joint build. The guards and its own fallback are as far as it goes.
