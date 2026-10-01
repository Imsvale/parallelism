# Backlog

Ideas and open questions parked until the core track building is robust.

## Parked (the user brings these up)

- **Fanned crossing (2026-10-01).** The drawn track runs down alongside a 6-track
  bundle and turns away; the extra tracks fan out and cross each other ("would cross
  each other"). A different kind of failure. Screenshot `2026-10-01 21_12_24-Transport
  Fever 3.png` (in the user's Screenshots folder); log lines with the judged and the
  refused plan in `docs/parked/2026-10-01_fanned-crossing.log`.

## Open questions

- **Cost of the extra tracks.** Done 2026-09-30: built with a `Context` whose `player`
  is set (as the base game does for the paid bridge/tunnel swap), each extra track is
  charged by its own length. Bulldozing works like hand-built track.

- **Unexplained "Construction Not Possible" on 6-track branches.** On 2026-09-30 three
  of five extra tracks failed on a gentle (~300 m radius) branch across a 6-track
  straight. Their plans were clean in `tests/analyze_plan.lua`. The next round, with no
  functional change, passed everything (29 of 29 tracks), so it depends on the geometry
  of the drag. A failed build now logs what it collides with; read that when it recurs.

- **Crash in the game's crossing geometry.** 2026-09-30: after a 6-track, ~1900 m radius
  curve across a 2-track straight, the game asserted in `track/Crossing.cpp`
  (`Angle(ctx1, ctx3) > PI - ANGLE_TOL`: a track bending at a crossing node). All five
  extra tracks had built fine two seconds earlier; the preview had been logging
  non-fatal `transition not valid ... track::Crossing` warnings before. Suspected: a very
  shallow crossing. Guard added (no crossings under 5 degrees) and every build's plan is
  logged; `tests/analyze_plan.lua` now checks crossing nodes for straightness.

- **Parallels of a gentle curve-in onto a multi-track fail near the merge.** When the
  drawn track joins a track tangentially after a large-radius curve, the extra tracks
  cross the base tracks at ever flatter angles near the merge (4.8 deg seen) and then
  run squeezed between them. Steeper curve-ins (14, 26 deg) build fine. Confirmed as a
  game limit: the game also refuses such a track drawn by hand. Measured 2026-09-30
  with single tracks (`measure:` log lines): crossings under 6.0 degrees are refused,
  independent of piece length when the pieces are long. The mod now refuses the whole
  drag in the builder when an extra track would cross that flat (returning
  `errorMessages` from `builder.proposalCreate`, as the company permits do). Still to
  measure: how the room needed next to a crossing depends on its angle (fitted so far
  from build failures as 1.5 m / tan(angle)).
- **Preview can show fewer tracks than get built.** The preview plans all extra tracks
  at once against the world before the drag; the build plans them one by one after it.
  The preview now logs its plan and the game's verdict on it, to find where they part.

- **Switch zones.** Solved 2026-09-30: a switch the mod creates on a base track now
  clears plain nodes on that track within sqrt(2 * branch radius * 5 m) on both sides,
  as the native builder does. The 5 m clearance is assumed; the native build only shows
  that a node 40 m into a 94.5 m zone had to go.

- **Spiral drag: flipped side and a crash.** 2026-09-30: dragging a tight, spiralling
  turn in toward an existing 6-track curve made the preview show wild shapes, the extra
  tracks apparently switch sides, and then the game crashed on a crossing with a track
  bending through it (`Crossing.cpp`, preview plan with 18 of its own nodes dropped).
  Fixed in the planner, to be confirmed in game: drawn segments are oriented
  consistently before offsetting, merges that would stray more than 0.2 m are not made,
  and plans with a track bending at a node are never shown or built.
- **Combined build fallback: now a diagnostic only (2026-10-01).** In play the extra
  tracks are built in one command or not at all; a failure notifies the player. The
  one-by-one builder runs only with `ONE_BY_ONE_DIAGNOSTIC` in `parallelism.script.lua`: it
  builds part of a drag, but shows which track fails and why. It did that once: 6
  tracks across a curving 6-track bundle, 3 of 5 built, the other 2 buildable by hand.
  Faults it exposed, fixed: a crossing exactly at one of our own nodes was dropped
  (the track ran through the other one; now that node becomes the crossing node), and
  the loose-end snap took a single track's offset as the step (snapped onto the
  neighbour's end; the planner now gets the real distance). Also from it: an own node
  4.6 m from a crossing could not be merged away (the merge of the two whole edges
  strayed 3.6 m, and elsewhere such merges bent too tight: Too Much Curvature). Now the
  node slides onto the nearest crossing: only the short bit in between is merged, the
  rest keeps its shape (whole-edge merge kept as the fallback).
- **Node configs crash, fixed 2026-10-01.** Replacing the config of an existing node
  that has none (plain track nodes) crashed the game when applying the build
  (`ecs::Engine::PostRemoveComponent`). Only existing configs are removed now.
- **Uneven bends from merges (2026-10-01).** A merged curve can stay within 0.2 m of
  its pieces and still bend unevenly; one such bump (37.6 m in a 124 m curve) in an
  existing track made the game refuse a later crossing of it ("Too Much Curvature" on
  the cut pieces). Merges now also refuse to bend tighter than the type allows (and
  than their pieces), and cut pieces of existing tracks are checked against their own
  type. Bumps already in the world stay; plans crossing them are refused with a
  message. Observed: the native builder seems to move a row of plain nodes away from
  its crossing rather than remove it (screenshots of a bundle before/after a build).
- **Policy: existing track keeps its shape (2026-10-01).** Crossing nodes lie exactly
  on both tracks. Nodes near a crossing: our own ones (offsets of the drawn track's
  nodes) are dropped or slid onto the crossing; a plain node of an existing track is
  slid onto the crossing, the bit in between changing edge, within 5 cm of the old
  line (a straight-to-curve transition moves a couple of meters at most). No whole-edge
  merges on existing track for crossings any more (they drifted long stretches up to
  0.2 m): if a slide does not fit, the drag is refused. Edges are cubic curves, not
  arcs: merging two pieces of one circle needs the right tangent lengths. The old merge
  took them from the length ratio, exact only for two pieces cut from one edge; for a
  0.44 m bit and 50 m of the same 65.6 m circle it strayed 3 cm. Merges now fit the
  tangent lengths (1.4 mm there). The deviation check itself traced curves too coarsely
  (4.7 mm on that arc) and now samples every half meter. A node at a seam (a straight
  meeting a curve) cannot slide onto the crossing without a cubic carrying both (2 cm
  for a 0.44 m move); it slides away instead, to just over 5 m from the crossing, so
  the seam sits in one short piece (about 2 mm) and the rest stays exact. Switches still merge to clear
  their zone, as the native builder does. Our own nodes reuse existing ones only
  within 5 cm (0.1 m at run ends); tracks no longer snap to loose ends at all.
- **Show refused extra tracks.** When our own plan has a problem (e.g. a piece too
  short), the extra tracks are not shown at all: the game can crash evaluating such a
  plan. Showing them as a red outline (`builtin.EdgeRenderable`, drawn without the game
  judging it) would tell the player which track is the trouble.
- **The drag check knows the game's verdict on the preview (2026-10-01).** A drag whose
  preview the game judges critical (e.g. a grid of crossings 5 m apart: Collision) is
  refused before the click, instead of being built and failing.

- **Preview trails the primary track.** The extra tracks appear a few frames after the
  builder's own. Planning is about 1 ms on open ground; the rest is the forced menu
  redraw and the game evaluating our proposal before drawing it. A fixed viewer id does
  not help (the viewer then stops updating). The builder draws its own track natively
  and only then hands its proposal to Lua, so ours can never be in the same frame.
  Parked idea: a light outline preview with `builtin.EdgeRenderable` that follows the
  mouse more closely, next to the full preview. Not wanted for now: the exact track
  preview is worth more than the speed. A real fix needs parallel tracks in the base
  game's builder.
- **Planning cost near many tracks.** Retracing a 6-track bundle made planning take
  20-40 ms per change of the drag. Now: faster crossing search, caches, a drag check
  without game objects, and planning only every 4th change while planning is expensive
  (over 10 ms); open ground plans every change. 2026-10-01: the drag check (game
  script) plans every change again: the builder asks only when the drag changes, so a
  skipped position could be the one the drag stopped at, and the answer for an earlier
  one stuck (a false refusal). The preview keeps the debounce (its tooltip is asked
  continuously, so it catches up). Open: the preview's lua costs ~8 ms per tooltip
  call even while the drag holds still over a 6-track crossing (855 ms per 100 calls),
  most likely collecting the drawn segments against many removed ones every call.

## Features

- **Terrain, catenary, fields, bridges.** Tested 2026-10-01 against native builds:
  - Terrain: done for the basics. The extra tracks follow the drawn one's heights;
    follow terrain, embankments, levelling, cuttings and tunnels all work. Revisit only
    on an actual failure.
  - Fields: destroyed by the extra tracks, as they should be.
  - Catenary: fixed 2026-10-02. The extra tracks had no overhead wires and the masts
    were merged over the first two tracks only, because their edge `distance` was 0
    (native track carries the template's `trackDistance`, 5). Now copied from the
    drawn track.
  - Bridges: fixed 2026-10-02, pillars now span the whole bundle (before: a narrow
    central one). Fixed by `extendProposalRedoPillars` and the `distance` together.
  - Still to check: buildings in the way. A fresh `Context` has `gatherBuildings`
    false (also `checkTerrainAlignment` and `cleanupStreetGraph`; `gatherFields` is
    true), so whether a bundle through a town demolishes houses as the native builder
    does is untested. `refundableEntities` (refunds when rebuilding recent
    construction) is not set either.
- **Translations.** The strings are English only.
- **Tell the player when a track fails.** Refused drags get a builder error message. A
  build that fails after the drag was accepted (combined build falls back to one by one,
  or a plan with problems at apply) adds an in-game notification of the mod's own type
  (`parallelism_notification`). Set `FORCE_FALLBACK` in `parallelism.script.lua` to see it.
- **Explain predictable failures before sending.** Some failures can be spotted while
  planning, e.g. two crossings 4 m apart on the new track (a piece shorter than the game
  allows), or a crossing next to a switch or crossing node that cannot be moved.
- **Preview while dragging.** In progress. The track builder calls
  `getProposalStringsFn(proposal, proposalData)` with its live proposal on every change
  of the drag (menu Lua state, reachable through the `getActionParams` wrapper; the
  strings it returns go into the builder's tooltip). `builtin.ProposalViewer` renders
  any proposal and reports its costs and errors through `onCreateProposalData`. First
  version written: planning moved to `parallelism_planner.lua`, one viewer per extra track
  injected into the builder's `builtin.ActionDescriptor`, cost in the tooltip.
- **Faster building.** The extra tracks appear one after the other, each waiting for the
  previous build command to finish. Planning all of them in one proposal would be
  faster, but has to handle edges that several tracks split.
- **Split highways.** First version 2026-10-01, untested in game: the street builder
  gets the same params (Roads, Side, Extra Spacing) plus Direction (Same / Opposite,
  default Opposite; Side defaults to Left for roads). Highway templates are one-way
  (all lanes `forward`), so the other carriageway is the same template with its edges
  reversed. Roads lie a road width apart (sum of the template's lane widths, 18 m for
  the medium highway) plus the spacing. Roads anchor on and cross roads (junctions);
  no switch zones, no radius limit beyond "not inside out". Open: whether roads that
  touch edge to edge collide, the crossing angle and piece length rules for roads,
  roads crossing tracks (level crossings are not planned, neither are tracks crossing
  roads today), and whether side-specific edge decorations (barriers) need flipping on
  reversed edges.
- **Road drags kink at road ends.** Unlike the track builder, the road builder (straight
  and curved mode alike) lets a drag leave the end of a road at an angle. Handled from
  the geometry, not the mode: the old road's parallel is cut back or extended to the
  corner where both parallels meet (miter), between 1 and 100 degrees. Two crashes in
  the game's street code (`map_util.h` "it != map.end()") came from the stubs left
  before this; pieces under 5 m next to a crossing or branch are now refused anyway.
  Confirmed 2026-10-01: a spiral of right turns (extra road Left, so on the outside)
  from 10 to 135 degrees, all joined, no crash; sharper is refused ("would turn too
  sharply"). Left turns with the extra road on the inside (the old parallel cut back)
  are untested. Around 120 degrees the preview is red at the corner: the game reports a
  non-critical Collision, because the preview is judged before the drawn road exists
  (the old main road still ends there); the build goes through. Possible fix: put the
  drawn segments into the preview proposal too, so it is judged as built.
  Open:
  - Starting a drag from the extra road's end instead of the main road's: the new
    pair pivots around the other road, so its extra road lands beside or into the old
    pair; some angles are accepted, some refused (collision). Wanted: treat a drag from
    either end of a pair as continuing the pair.
  - Sharp corners only join the centre lines. Roads are wide, so the inside of a sharp
    corner overlaps and outside corners are spiky. The real answer is filling the gaps
    (a short curve on the extra road in the corner), much more work than tracks needed.
  - Kinks where the drag starts at a junction (not a road end).
  - Curved mode: first click sets the start direction, second the end point, and the
    game fits a curve between them. Crash seen once while wiggling a first stretch in
    it (`lane_config_util.cpp` "!laneConfigs.empty()"); lane configs of every planned
    edge are now checked before the game sees them.
- **Left turns at a pair's end (extra road on the inside).** The road builder refuses
  the player's own drag: its kink collides with the old extra road beside it (touching,
  plus its turnaround loop). Our corner handling would cut it back, but only after a
  build that never happens. Ruled out 2026-10-01:
  - the builder object has no geometry controls (start point, pivot);
  - the builder-event result only refuses (errorMessages); skipRender without an error
    does nothing;
  - catching the build click needs a Selector, which disables the native builder;
  - staggered pair ends (direction of the next turn is unknown);
  - a road tool of our own (too big), cutting back mid-drag (too hacky).
  Still to try: whether the builder uses the objects it hands to `guiHandleEvent`
  (`builder.proposalCreate` param: proposal, proposal data), i.e. whether changing
  them there (adding a straight extension, clearing the collision) changes what gets
  built. If not: accept it, and favour curved drags that leave the road end
  tangentially (no kink), as the track builder does.
- **Matching the road builder (2026-10-01, dumps of a hand-built and a mod-built pair).**
  Edges were identical (lane configs, template, style, precedence, transport network).
  Differences found and fixed:
  - Spacing: the builder snaps a second road a width plus 4 m away (20 m for a 16 m
    road); we placed them edge to edge, so left turns collided at ~6 deg instead of
    ~36. Now the default. The slider is "Spacing": the gap for roads (default 4 m,
    0 = edge to edge), the centre distance for tracks (default the type's own).
  - Node configs: the builder gives every node one (lane connections, crosswalks,
    traffic light preference); ours had none, and existing nodes at the ends of edges
    we split or rebuilt kept configs naming the removed edge. Now our nodes copy the
    config of the drawn node they mirror (edges matched by direction, swapped for
    reversed roads), and touched existing nodes get theirs rewritten
    (`NODE_CONFIGS` in the planner). Prime suspect for the road junction crashes.
- **Straight road mode: known limitation.** A straight drag leaving a pair's end at an
  angle toward the extra road is refused by the game itself once the turn collides
  with the extra road (now from ~36 deg with the builder's spacing). Not worked around;
  the curved tool (smooth continuation) is the way to turn.
- **Road junctions crash the game.** Three crashes (`map_util.h` "it != map.end()",
  while the game evaluated the preview) all came from plans where an extra road crossed
  or branched onto a road; the last one was a plain 44 degree crossing of one-way roads
  with long pieces. Track crossings never did this. Suspect: the builder's own road
  proposals carry node configs (lane connections) for junction nodes, ours carry none
  (`SimpleStreetProposal.nodeConfigsToAdd` exists but nothing in the base game fills
  it). `ROAD_JUNCTIONS = false` in the planner refuses such drags for now. To find
  out: with it on, try a two-way road crossing, then one-way; and try filling
  nodeConfigsToAdd.
- **Extra spacing.** Slider 0-20 m in 0.5 m steps (1 m without the precision key),
  added to the track distance or road width. Untested in game.
- **Undo.** To be started here, where it can be built in context, and moved to its own
  mod later.

## Tidying

- **Tooltip additions are out of scope.** The radius line moved to the sibling mod
  Better Construction Tooltip (`mods/better-construction-tooltip`); `SHOW_RADIUS` here is
  off and the code can go once that mod is settled. Anything in the builder tooltip must
  add to it (wrap `getProposalStringsFn`, keep what is there) and be switchable, so other
  tooltip mods are not stepped on.
- **Curve radius override** moved to the sibling mod Tighter Curves
  (`mods/tighter-curves`, `imsvale_tighter_curves`) on 2026-10-01.

- Turn off the per-build proposal dump (`DEBUG_DUMP` in `parallelism.script.lua`).
- Derive the node reuse, node move and minimum piece distances from the template's
  `trackDistance` instead of fixed meters.
- The module cache clearing at the top of `parallelism.script.lua` is a dev aid; decide
  whether it stays in a release.
