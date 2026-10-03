# Node placement around junctions and crossings

Status: proposal, 2026-10-03. Replaces the node-moving code in `parallelism_planner.lua`
(see "What it replaces").

## Why

Where our new roads or tracks meet existing ones, the game refuses a build that leaves a
node too close to a junction or crossing. The planner currently fixes this with a chain of
local moves, each added when a new way of leaving a node behind turned up:

- slide a node onto the crossing, or away from it, or refit from it (`tryMoveEnd`);
- repeat that along one end of a part (`clearEnd`);
- join a crossed neighbour edge (`absorbNeighbour`), or an uncut edge between two
  crossings (`bridgeUncut`), or refit between two crossings (`refitBetweenCrossings`);
- drop our own mirrored nodes near a crossing (the `dropped` loop);
- walk a shortened T end back past its edge (`pastEnds`);
- plus guards so that two parts do not undo each other (`movedNodes`, `farNodes`,
  `endCuts`, `farTooClose`).

These moves depend on the order in which they run and interact. Most refusals and crashes
on 2026-10-03 came from those interactions, not from a missing rule.

The rule itself is small. This note writes it down and describes one step that applies it
to every road and track the plan touches.

## Terms

- **Chain**: one road or track, followed edge by edge through plain nodes. The crossed
  road is a chain; so is each of our parallels.
- **Junction**: a node where three or more edges meet, or where a crossing or T joins the
  chain. Junctions stay where they are.
- **Plain node**: a node with exactly two edges, on one chain. Plain nodes can always be
  removed: native removes them freely.
- **Keep-out**: the stretch of a chain next to a junction that must hold no plain node.

## The rule (native)

From the native studies (`docs/studies/2026-10-03_road-junction-spacing.md`,
`2026-10-02_native-crossings.md`, `2026-10-02_native-junctions.md`) and the builds of
2026-10-03.

### Roads

Two roads of width `w` meeting at angle `a`:

    corner(a) = w/2 / sin(a) + w/2 / tan(a)

This is how far along the road the two road surfaces still overlap, from the junction.
The 16 m town road measurements:

| a   | corner  |
| --- | ------- |
| 90  | 8.0 m   |
| 45  | 19.3 m  |
| 30  | 29.9 m  |
| 20  | 45.4 m  |
| 12  | 76.1 m  |
| 8   | 114.4 m |

- **Keep-out** on each side of the junction where the roads form an acute angle:
  `corner(a) + 26 m`. Native puts the next node exactly there when it has to move one
  (53.0 m at 33 degrees, 62.1 m at 25, 71.3 m at 20). A T has an acute side and an
  obtuse side; the obtuse side needs almost nothing (8 degree native T: 40.9 m on the
  obtuse side against 114 m on the acute side). An X is acute on both sides along each
  road.
- **Two junctions on one chain** need `corner(a1) + corner(a2) + 2.5 m` between them
  (the native X spacing fits this within one 0.5 m slider step from 90 down to 10
  degrees). Below that the game refuses, and corners that overlap can crash the game
  (StreetShapeFactory).
- **Between neighbouring junctions** closer than their two keep-outs combined there is
  no plain node at all: the chain between them is one edge (105 m at 20 degrees, 20 m
  spacing; 18.5 m at 90 degrees, 2.5 m spacing).
- **Flattest angle**: about 12.4 degrees in practice. Below it even the drawn road
  usually collides; native builds succeed only where the acute-side keep-out happens to
  be clear (8 degrees worked once on a long clear stretch). The mod refuses below 12.

Constants: 26 m, 2.5 m, 12 degrees. Everything else follows from `w` and `a`.

### Tracks

- **Crossing**: keep-out `max(5 m, 1.5 m / tan(a))` (fitted: at 6.1 degrees 7.7 m
  failed, 14.9 m worked). Native refuses crossings under 6.0 degrees.
- **Switch** (a track branching off): keep-out along the base track is the switch zone,
  from the branch's radius (`switchZone`, capped at 150 m).

Same structure as roads: a keep-out per junction, longer or shorter.

### Shape

Existing roads and tracks keep their shape. Removing a plain node joins its two edges into
one curve, which may stray from the old line:

- joined as one curve when it strays at most 0.05 m (`EXISTING_MAX_DEVIATION`);
- otherwise refitted the native way, from the junction with an arc-like cubic, the next
  node placed just outside the keep-out, at most 0.5 m off (`REFIT_MAX_DEVIATION`);
- if neither fits, the plan is refused: never a build that bends existing road.

## The step: re-lay each chain

For every chain the plan touches (each crossed road or track, and each of our parallels):

1. **Positions.** Take the chain as a sequence of edges and give every node and every
   junction its distance along the chain. Junctions include our crossings and T anchors,
   the drawn road's junction, and existing junctions.
2. **Keep-outs.** For each junction, mark its keep-out on the side or sides where the rule
   asks for one. Two junctions closer than their keep-outs combined: mark the whole
   stretch between them.
3. **Remove.** Every plain node inside a marked stretch goes.
4. **Re-lay.** Rebuild the chain between the nodes that remain, as one edge per stretch.
   Where that one edge would stray too far, refit: keep a node just outside the
   keep-out (see Shape). Edges are cut at junctions by distance along the old curves, so
   the parts that do not move keep their exact shape.
5. **Check.** Junction pairs closer than their corners plus 2.5 m, or a stretch that
   could not be re-laid within the shape limits: the plan is refused, with the chain,
   junctions and distances named.

The same step serves our own parallels: their mirrored nodes are plain nodes, and a
parallel's T end is cut by distance along the whole run, so a shortening longer than one
edge needs no special case.

## What it replaces

`tryMoveEnd`, `clearEnd`, `absorbNeighbour`, `bridgeUncut`, `refitBetweenCrossings`, the
own-node `dropped` loop, `pastEnds`, `endCuts`, `farTooClose`, and the `movedNodes` /
`farNodes` guards. Kept: finding crossings and T anchors, offsets, junction lane
connections, node configs, the join with the builder's proposal and its consistency
check, and the final plan check (no plain node inside a keep-out, no overlapping
corners), which stays as the safeguard.

## Testing

The step is plain geometry: chains of cubic edges, positions, angles. It goes in its own
module with no game API calls, so it can be unit-tested offline (`tests/`) against the
native numbers above:

- 20 degree X, 20 m spacing: junctions 105 m apart, one edge between, outer node at
  71.3 m;
- 90 degree T, 2.5 m spacing: junctions 18.5 m apart, the plain node between removed;
- 8 degree T: 114 m clear on the acute side, short obtuse side kept;
- a parallel shortened by more than one edge;
- a curved chain where joining strays: refit, or refuse.

Then in game, the sweeps of 2026-10-03: road X and T (3 roads, C(L), 20 m) from 90 down
to 12 degrees, 90 degree T at 2.5 m, track crossings and switches.

## Open questions

- Does native put the outer node at exactly `corner + 26 m` only when it has to move
  one, or also when an existing node lies further out? The data so far: further-out nodes
  stay where they are.
- The obtuse side of a T: is "almost nothing" `corner` of the obtuse angle (under 1 m at
  8 degrees), or a minimum piece (10 m)? Native kept 40.9 m; to measure.
- Tracks: the 1.5 m crossing clearance was fitted on one angle; check it against a
  second.
