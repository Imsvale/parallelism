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
  not help (the viewer then stops updating). Idea: a light outline preview with
  `builtin.EdgeRenderable` that follows the mouse at once, next to the full preview.
- **Planning cost near many tracks.** Retracing a 6-track bundle made planning take
  20-40 ms per change of the drag. Now: faster crossing search, caches, a drag check
  without game objects, and planning only every 4th change while planning is expensive
  (over 10 ms); open ground plans every change.

## Features

- **Tell the player when a track fails.** Today only the log knows. An in-game notice,
  e.g. "2 of 3 extra tracks built, one would cross too close to a switch".
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
- **Split highways.** The same machinery for streets: physically separate one-way roads
  in opposite directions. Other street types are less interesting.
- **Undo.** To be started here, where it can be built in context, and moved to its own
  mod later.

## Tidying

- Turn off the per-build proposal dump (`DEBUG_DUMP` in `ptracks.script.lua`).
- Derive the node reuse, node move and minimum piece distances from the template's
  `trackDistance` instead of fixed meters.
- The module cache clearing at the top of `ptracks.script.lua` is a dev aid; decide
  whether it stays in a release.
