# Backlog

Ideas and open questions parked until the core track building is robust.

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
- **Combined build fallback.** The extra tracks are built with one command; if that
  fails, they are built one by one. Once the single command proves reliable, comment the
  fallback out (keep it in the code).

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
  (over 10 ms); open ground plans every change.

## Features

- **Tell the player when a track fails.** Refused drags get a builder error message. A
  build that fails after the drag was accepted (combined build falls back to one by one,
  or a plan with problems at apply) adds an in-game notification of the mod's own type
  (`ptracks_notification`). Set `FORCE_FALLBACK` in `ptracks.script.lua` to see it.
- **Explain predictable failures before sending.** Some failures can be spotted while
  planning, e.g. two crossings 4 m apart on the new track (a piece shorter than the game
  allows), or a crossing next to a switch or crossing node that cannot be moved.
- **Preview while dragging.** In progress. The track builder calls
  `getProposalStringsFn(proposal, proposalData)` with its live proposal on every change
  of the drag (menu Lua state, reachable through the `getActionParams` wrapper; the
  strings it returns go into the builder's tooltip). `builtin.ProposalViewer` renders
  any proposal and reports its costs and errors through `onCreateProposalData`. First
  version written: planning moved to `ptracks_planner.lua`, one viewer per extra track
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
  Confirmed 2026-10-01: a loop of corners from 10 to 100 degrees, both turn directions,
  all joined, no crash. The limit is now 135 degrees (untested above 100); sharper is
  refused ("would turn too sharply").
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

- Turn off the per-build proposal dump (`DEBUG_DUMP` in `ptracks.script.lua`).
- Derive the node reuse, node move and minimum piece distances from the template's
  `trackDistance` instead of fixed meters.
- The module cache clearing at the top of `ptracks.script.lua` is a dev aid; decide
  whether it stays in a release.
