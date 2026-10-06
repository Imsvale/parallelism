# Bending away from staggered junctions

A drag that continues from one of our junctions into a curve, where the other parallels
have their own junctions on the same road (for example three roads ending in T junctions on
a main road that crosses them diagonally). Decided 2026-10-06.

Interactive picture: [Staggered Junction Bends](https://claude.ai/artifact/HvkmV5af2qL8oSkqHVZxdh)
(sliders for the cut angle, spacing, radius and sweep).

## The geometry

A diagonal cut staggers the junctions along the roads: each one lies
`spacing / tan(cut angle)` further along than its neighbour (32.8 m at 36 m spacing and 51
degrees). Concentric bends must all start on one line square to the roads, through their
shared center. The junctions lie on a slanted line instead, so of these three only two can
hold:

1. each road leaves its junction straight on (no kink);
2. the bends are concentric (the set spacing all through the bend);
3. the bend starts at the drawn road's junction.

## The options

- **Concentric (the mod's behavior).** 2 and 3: each parallel follows the drawn road's curve
  through its own junction. A parallel whose junction lies alongside the bend meets it at an
  angle (about 11 degrees in the case above): a kink at a road junction, which native allows.
  Its spacing is taken where the drawn road is nearest its junction, so it may differ a little
  from the others'. A parallel whose junction lies before the bend runs straight on to it.
- **Bend later (a maybe, see the backlog).** 1 and 2: the bend starts at the outermost
  junction, the drawn road running straight past its own junction until then. The player can
  do this by hand today: draw the middle road straight to level with the outermost junction,
  then continue with the curve.
- **Smooth (rejected).** 1 and 3: each parallel leaves its junction straight on and curves
  in to the bend, so its spacing varies through it. One edge cannot do that evenly: it bent
  hard at the junction, flattened out and only then met the bend (tested in game: "anything but
  smooth"). Drawing roads is mostly about how they look, and this looked worse than either
  other option.

So the choice left to the player is: the set spacing through the bend, or the bend starting
at the junction. Not both.

## In the code

- `junctionOfOurs` adoption (`parallelism_planner.lua`): for a junction alongside the drawn
  road, the spacing is the distance to the drawn road's nearest point, so the concentric
  parallel runs through the junction; for one before the drawn road's end, square to the end.
- `branchPoint`: the meeting point is searched on the parallel's own curve ahead of its end
  and on its straight line behind it.
- A curving parallel lengthened back to a junction behind its start is one edge fitted to
  straight-then-curve (`geometry.refitFrom`).
