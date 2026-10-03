# Backlog

Open work first, then what was solved and how (kept for the reasoning).

## Parked (the user brings these up)

- **Fanned crossing (2026-10-01).** The drawn track runs down alongside a 6-track
  bundle and turns away; the extra tracks fan out and cross each other ("would cross
  each other"). A different kind of failure. Screenshot `2026-10-01 21_12_24-Transport
  Fever 3.png` (in the user's Screenshots folder); log lines with the judged and the
  refused plan in `docs/parked/2026-10-01_fanned-crossing.log`.

## Open: tracks and roads

- **Red flash when a drag first hits a house.** Cosmetic. The first time in a drag
  that the extra tracks run into a town building, the preview shows red for a moment:
  the game has to report the collision before the plan can name the house for removal.
  Later hits of the same house in that drag do not flash.
- **Show refused extra tracks.** When our own plan has a problem (e.g. a piece too
  short), the extra tracks are not shown at all: the game can crash evaluating such a
  plan. Decided 2026-10-02: two modes, both drawn with `builtin.EdgeRenderable` (not
  judged by the game):
  - default: a stripped-down view that fits what the game does, the problem segment
    highlighted in red;
  - the Wireframe view (all edges by kind) stays as the detailed option, likely in a
    release too, not only as a dev aid. Its problem marker is now white (was magenta);
    whether something more visible is needed is open.
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

- **Tests still to run (2026-10-03).** The 2026-10-03 round passed track and road
  bundles and a 90 degree crossing (6 roads over one main road at 4 m spacing). Still
  to do, after the crash fixes:
  - a 20 degree X (primary plus one parallel on each side): builds at 20 m since
    2026-10-03 (after the crash fixes and the room fixes found by pairwise testing);
    still to find the smallest spacing (native: 16 m);
  - the T sweep from 90 degrees down to about 30;
  - a 30 degree X.

- **Partial build by a race (2026-10-02, next up).** The drag check knows the game's
  verdict on our plan only through the preview. Released before the preview of that
  exact position was judged, the drag went through on our own plan alone; the game
  then refused our part (a 42 degree crossing at 4 m spacing, Construction Not
  Possible) after the drawn road was built. Seen where the game is at its limit. Ideas:
  undo the drawn build when ours fails (it may have split roads: restore them); or
  refuse while the verdict for the current position is pending (but the builder only
  asks again when the drag changes, a pending refusal could stick); or judge our plan
  in the game script itself (`api.engine.util.proposal.makeProposalData` wants a full
  `Proposal`, not a `SimpleProposal`).
- **Angled road T and crossings (2026-10-02).** T: each parallel's end slides along
  itself to meet the road (searching the road's further pieces, up to 5x the offset,
  not below 15 degrees), its first edge lengthened as one edge (a short piece before a
  junction was refused) or cut exactly at the road. Reliable from 90 down to about 20
  degrees at the road builder's 4 m spacing. Roads: 10 m minimum piece next to a
  junction, 8 m / tan(angle) room along the road at flat angles (guesses). Angled
  crossings at 4 m spacing are refused by the game: two junctions at 42 degrees 39 m
  apart overlap (a junction takes about the crossing road's width / sin(angle) of the
  road it crosses). The builder's own verdict flips between ok and Collision at 21-36
  degrees. To test: angled crossings with more spacing.
- **Road junctions: on, first tests passed (2026-10-02).** Crossings of two-way roads,
  a highway pair across a town road and a pair starting at a road built, no crash.
  Crosswalks now only over roads with sidewalks. Three crashes (`map_util.h`
  "it != map.end()", while the game evaluated the preview) came from plans where an
  extra road crossed or branched onto a road. Our junction nodes had no node config at
  all. Study of the road builder's junctions (`docs/studies/2026-10-02_native-junctions.md`):
  every node gets a config, lanes counted from the node, every turn but U-turns.
  `planner.junctionConnections` reproduces all four studied junctions exactly
  (`tests/junction_test.lua`); `ROAD_JUNCTIONS = true`. A junction whose config fails
  is refused, never sent. Untested in game; trams (`withTram`) and roads with more
  lanes not studied.
- **Room between road junctions (2026-10-02).** Parallel roads crossing a road make
  junctions a spacing apart along it; the game refuses them when they are too close
  (with the road builder's own 4 m gap even near 90 degrees; from about 9-10 m most
  angles work, and a sharper angle needs less, its junction being longer). Not one
  number. For now a refused plan with junctions suggests more spacing. Possible later:
  work out the spacing needed from the crossing angles and offer or apply it.
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

- **Existing track: as the native builder (2026-10-02).** Crossing nodes lie exactly on
  both tracks. Nodes near a crossing: our own ones (offsets of the drawn track's nodes)
  are dropped or slid onto the crossing. A plain node of an existing track, first
  choice: slid onto the crossing or away from it within 5 cm of the old line. Else, as
  the native builder does (study `docs/studies/2026-10-02_native-crossings.md`): the
  node is removed and the old track refitted from the crossing to a new node 30 m on
  (or the next node) with an arc-like cubic, within 0.5 m of the old line and not
  tighter than the type's minimum radius; else the drag is refused. Switches still
  merge to clear their zone. Our own nodes reuse existing ones only within 5 cm (0.1 m
  at run ends); tracks do not snap to loose ends. (Until 2026-10-02 the rule was
  stricter: no reshaping beyond the 5 cm slides.) Not yet refitted: a seam between two
  edges that are both crossed (`absorbNeighbour` still only slides).
- **Tooltip additions are out of scope.** Anything in the builder tooltip belongs in
  the sibling mod Better Construction Tooltip (`mods/better-construction-tooltip`), and
  must add to the tooltip (wrap `getProposalStringsFn`, keep what is there) and be
  switchable. The curve radius override is the sibling mod Tighter Curves
  (`mods/tighter-curves`).

## Done

- **Buildings in the way (2026-10-02).** The builder's own proposal lists the
  constructions of houses in its way for removal (`toRemove`); ours got them back as
  collisions (red, build blocked). Now the preview collects town buildings the game
  reports as collisions, plans again with their constructions in
  `constructionsToRemove` (yellow outline, as native), keeps only those the tracks
  still pass, and hands the list to the build. Tracks and roads confirmed in game.
  Industries and other constructions stay collisions. `refundableEntities` is not set.
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
