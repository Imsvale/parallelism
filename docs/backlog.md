# Backlog

Open work first, then the rules, then what was solved and how (kept for the reasoning).
Tidied 2026-10-05 after the one-rule redesign (docs/design/2026-10-03_node-placement.md).

## Parked (the user brings these up)

- **Fanned crossing (2026-10-01).** The drawn track runs down alongside a 6-track
  bundle and turns away; the extra tracks fan out and cross each other ("would cross
  each other"). Screenshot `2026-10-01 21_12_24-Transport Fever 3.png` (user's
  Screenshots folder); judged and refused plan in `docs/parked/2026-10-01_fanned-crossing.log`.

## Open: features and gaps

- **Bend later, a maybe (2026-10-06).** Continuing a curving drag from staggered junctions
  of ours: the mod keeps the bends concentric, the outer parallels kinked at their junctions.
  A second option could start the bend at the outermost junction instead (the drawn road
  straight on until level with it): no kinks, but not where the player started the bend.
  The player can do it by hand already. docs/studies/2026-10-06_staggered-junction-bends.md
- **Translations.** English only. Easy to add at any time.

## Open: known limits and to-confirm

- **Kinks at a bundle's end, the builder's own collision (2026-10-05).** A straight-mode
  kink from the end of a bundle collides with the untrimmed end of the parallel on the
  inside of the turn (side C: from about 63 degrees; earlier with the parallels on the
  inside). The mod trims that parallel after the build, but the builder judges its own
  road against the world as it is, and a script answering `builder.proposalCreate` can
  only add errors (base game scripts: company permits, missions), never lift the
  builder's verdict. Workarounds: the curved tool; bulldoze a piece of the inside
  parallel by hand first (then down to 90 degrees); or side L/R with the drag anchored on
  the road on the inside of the turn, the parallels outside (tested to 135 degrees). The
  same limit applies when continuing from an outer road. Accepted for now.
- **Level crossings: room constant** fitted on one flat build (19 m beyond the overlap):
  check at a second angle (15-20 degrees). docs/studies/2026-10-03_native-level-crossings.md
- **Track crossing clearance** (1.5 m / tan(angle)) fitted on one angle (6.1 degrees):
  check at a second.
- **Road minimum piece** (10 m) is a first guess, not measured.
- **Red flash when a drag first hits a house.** Cosmetic: the game has to report the
  collision before the plan can name the house for removal.
- **Explain what the game alone refuses** ("Construction Not Possible"): the drag check
  dumps our refused plan; a pairwise native build shows the difference.
- **Untested:** side-specific edge decorations (barriers) on reversed roads; trams.
- **Performance:** see docs/performance.md.

## Before a release

- Turn off the per-build proposal dump (`DEBUG_DUMP`), the dump at drag start
  (`DUMP_AT_DRAG_START`), the crossing measurement (`MEASURE_CROSSINGS`), and decide on
  `DUMP_BEFORE_JUDGING` (off), `PERF_MEASURES` and the held-still logging.
- Remove the radius line code (`SHOW_RADIUS`, off): it lives in Better Construction
  Tooltip now.
- The module cache clearing at the top of `parallelism.script.lua` is a dev aid; decide
  whether it stays.
- Dev aids to decide on: the Wireframe param (`DEBUG_WIREFRAME`).

## Rules

- **STRICT: replicate the game's pattern, geometry and math (2026-10-04).** No more
  hard-coded limits, distances or tolerances than the game itself appears to hard-code;
  everything else emerges from the geometry. Limits that exist in the game (minimum
  radius, widths, track distance) are read from it at run time (other mods and updates
  change them). Only exception: a cut-off that saves processing on what cannot work
  anyway, never one that decides what gets built.
- **Existing roads and tracks keep their shape.** Re-laid by the chain module: one edge
  per stretch where one curve follows within 5 cm, else refitted as native (arc-like from
  the junction, within 0.5 m and not tighter than the type allows), else refused.
- **No partial builds.** Whatever the game would refuse is refused before the click; a
  plan the game cannot judge is never shown or built.
- **Pairwise testing.** When the game refuses something, build the same natively and
  compare the dumps.
- **Tooltip additions are out of scope.** They belong in Better Construction Tooltip;
  curve radius overrides in Tighter Curves.

## Done

- **One rule for nodes near junctions (2026-10-03/04).** docs/design/2026-10-03_node-placement.md,
  `parallelism_chain.lua` (offline tests: `tests/chain_test.lua`). Every road the plan
  touches, existing ones and our own parallels, is re-laid around its junctions: no
  plain node within a junction's keep-out, one edge per stretch. The keep-out
  (`junctionRoom`): where the two surfaces overlap along this road (the other's half
  width / sin(a) + this one's half width / tan(a)) plus 26 m at a road junction, 19 m at
  a level crossing; the track clearance for track crossings; the switch zone for
  switches. neighboring junctions need their corners plus 2.5 m. A final plan check
  names any node left inside a keep-out and refuses overlapping corners.
- **Road junctions (2026-10-02/03).** Every junction gets a node config (the mod's own
  lane rules, `tests/junction_test.lua`); X down to about 12.4 degrees (the native limit:
  below it the drawn road itself collides), 16 m spacing at 20 degrees as native; T down
  to 12 degrees, flatter refused ("Angle is too shallow"). T ends slide along the
  parallel to meet the road, shortened or lengthened over as many edges as needed.
  docs/studies/2026-10-03_road-junction-spacing.md
- **Level crossings (2026-10-03/04).** Roads over tracks and tracks over roads, down to 6
  degrees; T's on a track; a T on a track extended into an X continues smoothly (as
  native, even in straight mode), the transition into a curve as long as the radius
  needs. The node's config: the road's lanes straight through only.
- **How tight a road may curve (2026-10-04).** The tightest point of a road edge: half
  its width plus 1 m (native, two widths); the template's minCurveRadius is ignored by
  the road builder. Tracks: the type's own minimum. docs/studies/2026-10-04_native-road-radius.md
- **Partial builds by a race, judged in the game script (2026-10-03).** The drag check
  plans against the world after the drawn road (the builder's proposal laid over it) and
  has the game judge our plan joined with the builder's (`joinWithBuilder`).
- **Crashes (2026-10-03).** A node without edges (StreetShapeFactory `!cc.empty()`):
  only used nodes are emitted, the join refuses any left, the preview shows only what
  the game can judge. Negative (proposal) ids never reach `getComponent`. The builder's
  proposal lists are kept alive while their elements are used. A preview past a build is
  dropped once the world no longer has what it refers to.
- **Continuing a bundle from an outer road (2026-10-05).** The parallels go where they
  continue the bundle's loose ends beside the drawn road's start or end (the arrangement
  that continues the most; the Side setting decides otherwise). Tested straight, curved,
  kinked from either outer road, and across a 3x3 grid of crossings.
- **Continuing from a bundle's junctions at another angle (2026-10-05).** A drag from one
  of our T's on a road, at a new angle: each parallel continues from its own junction on
  that road (the road running through the drawn node, followed both ways), at the
  spacing those junctions give (in-world placement over the panel: wider or narrower
  than set). Straight and curved; at a level crossing the roads continue smoothly as
  native.
- **Continuing from staggered junctions into a curve (2026-10-06).** Concentric, each
  parallel through its own junction (kinked there if the bend has begun). Spacing through
  the bend or the bend at the junction, not both: docs/studies/2026-10-06_staggered-junction-bends.md
  and the picture https://claude.ai/artifact/HvkmV5af2qL8oSkqHVZxdh
- **Showing refused plans (2026-10-06).** Instead of nothing: white lines, red where the
  planner located the problem (all red if it could not).
- **Corner filling (closed 2026-10-06).** Parallel corners at straight-mode kinks look like
  the drawn road's own, on the small town road and the large country road (6 lanes);
  past 90 degrees the outside corner gets a spike, as the drawn road's does.
- **Corners at a bundle's end (2026-10-01, 2026-10-05).** The old parallel is cut back or
  extended to the miter corner at any kink (no cut-off), cut back over as many edges as
  it takes.
- **Buildings in the way (2026-10-02).** Town buildings the game reports as collisions
  are removed with the build (as native); industries stay collisions.
- **Terrain, fields, catenary, bridges (2026-10-01/02).** Catenary needs the edge
  `distance` (the template's `trackDistance`); bridges need `extendProposalRedoPillars`.
- **Side: L / CL / CR / R, Spacing, split highways, cost, switch zones, merges, node
  configs** (2026-09-30 to 10-02): see git history.
- **Preview while dragging.** `getProposalStringsFn` with the builder's live proposal,
  rendered by `builtin.ProposalViewer`; a few frames behind the builder by design.
