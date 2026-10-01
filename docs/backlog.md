# Backlog

Open work first, then what was solved and how (kept for the reasoning).

## Parked (the user brings these up)

- **Fanned crossing (2026-10-01).** The drawn track runs down alongside a 6-track
  bundle and turns away; the extra tracks fan out and cross each other ("would cross
  each other"). A different kind of failure. Screenshot `2026-10-01 21_12_24-Transport
  Fever 3.png` (in the user's Screenshots folder); log lines with the judged and the
  refused plan in `docs/parked/2026-10-01_fanned-crossing.log`.

## Open: tracks and roads

- **Buildings in the way are not bulldozed (confirmed 2026-10-02, unresolved).** A
  single track built by hand marks buildings in its way with yellow outlines ("will be
  bulldozed") and removes them on build. With extra tracks or roads they show as red
  collisions and block the build. Same for tracks and roads. Leads: a fresh `Context`
  has `gatherBuildings` false (also `checkTerrainAlignment` and `cleanupStreetGraph`;
  `gatherFields` is true, and fields are cleared fine); the preview is judged by
  `builtin.ProposalViewer`, which may need the same. `refundableEntities` (refunds when
  rebuilding recent construction) is not set either.
- **Show refused extra tracks.** When our own plan has a problem (e.g. a piece too
  short), the extra tracks are not shown at all: the game can crash evaluating such a
  plan. Showing them as a red outline (`builtin.EdgeRenderable`, drawn without the game
  judging it) would tell the player which track is the trouble.
- **Explain predictable failures before sending.** Partly done: the planner refuses
  with a message for crossings too flat, pieces too short, bends too tight, a track
  crossing itself. Still unexplained: what the game alone refuses (e.g. "Construction
  Not Possible").
- **Room needed next to a crossing.** Crossings under 6 degrees are refused (measured
  2026-09-30, a game limit). How much room a crossing needs depending on its angle is
  still fitted from failures (1.5 m / tan(angle)), not measured.
- **Preview cost near many tracks.** The preview's Lua costs ~8 ms per tooltip call
  even while the drag holds still over a 6-track crossing (855 ms per 100 calls), most
  likely collecting the drawn segments against many removed ones every call. The
  preview plans only every 4th change while planning is expensive (over 10 ms); the
  drag check plans every change (a skipped one could be where the drag stopped).
- **To confirm when they come up again:**
  - "Construction Not Possible" on 6-track branches (2026-09-30: 3 of 5 extra tracks
    failed on a ~300 m branch across a 6-track straight, clean plans; the next round
    passed 29 of 29). A failed build logs what it collides with; read that.
  - Spiral drags: fixed in the planner (consistent orientation, merges capped at 0.2 m,
    no plan with a track bending at a node is shown or built), never confirmed.
  - The preview showing fewer tracks than get built. Both now plan all tracks in one
    proposal, so probably gone.
  - Combined build failures: in play the extra tracks are built in one command or not
    at all, a failure notifies the player. `ONE_BY_ONE_DIAGNOSTIC` in
    `parallelism.script.lua` builds them one by one instead, to show which one fails.

## Open: roads

- **Road junctions are off.** Three crashes (`map_util.h` "it != map.end()", while the
  game evaluated the preview) came from plans where an extra road crossed or branched
  onto a road; track crossings never did this. Suspected: missing node configs, which
  our roads now copy from the drawn ones (fixed after the crashes). `ROAD_JUNCTIONS =
  false` in the planner refuses such drags. To try: turn it on, a two-way road
  crossing, then one-way.
- **Starting a drag from the extra road's end.** The new pair pivots around the other
  road, so its extra road lands beside or into the old pair; some angles are accepted,
  some refused (collision). Wanted: a drag from either end of a pair continues the pair.
- **Corner filling.** Sharp corners only join the centre lines. Roads are wide, so the
  inside of a sharp corner overlaps and outside corners are spiky. The answer is filling
  the gaps (a short curve on the extra road in the corner).
- **Left turns at a pair's end (extra road on the inside).** The road builder refuses
  the player's own drag: its kink collides with the old extra road beside it. Ruled out
  2026-10-01: builder geometry controls (none), skipRender without an error, a Selector
  (disables the native builder), staggered pair ends, a road tool of our own, cutting
  back mid-drag. Still to try: whether changing the proposal the builder hands to
  `guiHandleEvent` (`builder.proposalCreate`) changes what gets built. If not: accept
  it; curved drags that leave the road end tangentially work.
- **Kinks where a drag starts at a junction** (not a road end).
- **Untested:**
  - roads crossing tracks and tracks crossing roads (level crossings are not planned);
  - side-specific edge decorations (barriers) on reversed roads, whether they need
    flipping;
  - the preview red at ~120 degree corners: the game reports a non-critical Collision
    because the preview is judged before the drawn road exists; the build goes through.
    Possible fix: put the drawn segments into the preview proposal too.
- **Known limitation, not worked around:** a straight-mode drag leaving a pair's end at
  an angle toward the extra road is refused by the game itself once the turn collides
  with the extra road (from ~36 degrees with the builder's spacing). The curved tool is
  the way to turn.

## Open: features

- **Translations.** The strings are English only. Easy to add at any time.
- **Undo.** To be started here, where it can be built in context, and moved to its own
  mod later.

## Before a release

- Turn off the per-build proposal dump (`DEBUG_DUMP` in `parallelism.script.lua`) and
  the dump at drag start (`DUMP_AT_DRAG_START`).
- Remove the radius line code (`SHOW_RADIUS`, off): it lives in the sibling mod Better
  Construction Tooltip now.
- The module cache clearing at the top of `parallelism.script.lua` is a dev aid; decide
  whether it stays.
- Derive the node reuse, node move and minimum piece distances from the template's
  `trackDistance` instead of fixed meters.
- Dev aids to decide on: the Wireframe param (`DEBUG_WIREFRAME`), held-still logging.

## Rules

- **Existing track keeps its shape (2026-10-01).** Crossing nodes lie exactly on both
  tracks. Nodes near a crossing: our own ones (offsets of the drawn track's nodes) are
  dropped or slid onto the crossing; a plain node of an existing track is slid onto the
  crossing within 5 cm of the old line. If a slide does not fit, the drag is refused.
  A node at a seam (a straight meeting a curve) slides away instead, to just over 5 m
  from the crossing. Switches still merge to clear their zone, as the native builder
  does. Our own nodes reuse existing ones only within 5 cm (0.1 m at run ends); tracks
  do not snap to loose ends.
- **Tooltip additions are out of scope.** Anything in the builder tooltip belongs in
  the sibling mod Better Construction Tooltip (`mods/better-construction-tooltip`), and
  must add to the tooltip (wrap `getProposalStringsFn`, keep what is there) and be
  switchable. The curve radius override is the sibling mod Tighter Curves
  (`mods/tighter-curves`).

## Done

- **Terrain, fields, catenary, bridges (2026-10-01/02).** Terrain needs nothing: the
  extra tracks follow the drawn one's heights; follow terrain, embankments, levelling,
  cuttings and tunnels work (revisit on an actual failure). Fields are cleared.
  Catenary: the extra tracks had no wires and the masts covered only two tracks,
  because their edge `distance` was 0; native track carries the template's
  `trackDistance` (5). Copied from the drawn track now. The game groups side-by-side
  edges into "parallel strips" by it (computed by the game, in the proposal data).
  Bridges got only a narrow central pillar; with `extendProposalRedoPillars` and the
  distance they span the whole bundle.
- **Side: L / CL / CR / R (2026-10-02).** Center split in two, the odd one out of an
  uneven split on the left or right. Roads with at most 2 offer Left / Right only.
- **Spacing (2026-10-01).** One slider: the gap for roads (default the road builder's
  4 m, 0 = edge to edge), the centre distance for tracks (default the type's own).
- **Preview while dragging.** The builder calls `getProposalStringsFn(proposal,
  proposalData)` with its live proposal on every change of the drag;
  `builtin.ProposalViewer` renders our proposal. It trails the builder's own track by a
  few frames: the builder draws natively and only then hands its proposal to Lua, so
  ours can never be in the same frame (a fixed viewer id does not help). An outline
  preview that follows the mouse more closely was considered and not wanted: the exact
  preview is worth more.
- **The drag check knows the game's verdict on the preview (2026-10-01).** A drag whose
  preview the game judges critical is refused before the click, instead of failing.
- **One build, no partial builds.** The drawn and extra tracks go in one command;
  refusals use `errorMessages` from `builder.proposalCreate`. A failure after the click
  adds a notification of the mod's own type (`parallelism_notification`).
- **Cost (2026-09-30).** Built with a `Context` whose `player` is set, each extra track
  is charged by its length. Bulldozing works like hand-built track.
- **Flat crossings and the crossing crash (2026-09-30).** The game asserted in
  `track/Crossing.cpp` on a track bending at a crossing node. Crossings under 6 degrees
  are a game limit (it refuses them hand-drawn too); the mod refuses them. Plans with a
  track bending at a crossing are never built; `tests/analyze_plan.lua` checks it.
- **Switch zones (2026-09-30).** A switch the mod creates on a base track clears plain
  nodes within sqrt(2 * branch radius * 5 m) on both sides, as the native builder does
  (the 5 m clearance assumed).
- **Merges.** Edges are cubic curves, not arcs: merging two pieces of one circle needs
  fitted tangent lengths (the length-ratio merge strayed 3 cm on a 0.44 m + 50 m merge,
  the fit 1.4 mm). The deviation check samples every half meter. Merges refuse to bend
  tighter than the type allows; cut pieces of existing tracks are checked against their
  own type. Bumps already in the world stay; plans crossing them are refused.
- **Node configs.** Our nodes copy the config of the drawn node they mirror (edges
  matched by direction, swapped for reversed roads); touched existing nodes get theirs
  rewritten. Removing a config from a node that had none crashed the game
  (`ecs::Engine::PostRemoveComponent`); only existing configs are removed now.
- **Road kinks at road ends.** The road builder lets a drag leave a road end at an
  angle; the old road's parallel is cut back or extended to the miter corner (1 to 100
  degrees). Right-turn spiral from 10 to 135 degrees confirmed; sharper is refused.
  Curved mode crash (`lane_config_util.cpp` "!laneConfigs.empty()"): lane configs of
  every planned edge are checked now.
- **Matching the road builder (2026-10-01).** Dumps of a hand-built and a mod-built
  pair: edges identical; spacing and node configs were the differences, both fixed.
- **Split highways.** The street builder gets Roads, Side, Spacing and Direction (Same /
  Opposite, default Opposite; Side defaults to Left). Highway templates are one-way, so
  the other carriageway is the same template with reversed edges. Roads lie a road
  width apart (the template's lane widths) plus the spacing. More than 2 roads with the
  mod option "moreRoads".
