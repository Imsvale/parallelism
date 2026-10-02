# Road junction spacing: what the game accepts

How close two parallel roads may cross or join a main road, by angle. Measured with
native builds: a road crossing the main road at the chosen angle, a short parallel base
made with Parallelism at the chosen spacing, then extended natively across the main
road (step 3 is the native builder's own verdict).

- Roads: main road and crossing roads `town_new_small` (two-way), flat ground.
- Spacing: Parallelism's Spacing value (gap between the roads, edge to edge).
- **T**: the parallel roads end on the main road. **X**: they cross it.
- Each cell: the smallest spacing that builds; the next step down (0.5 m less, the
  slider's step) is refused. Angle as the tooltip's crossing line reads it.

### Native

Procedure:

1. To get the angle exact, start with a T going "South" from the main road.
1. Extend it "North" to form a full X crossing.
1. At either end, create a "foothold" for a parallel road with a given spacing, using the mod.
1. Extend the new parallel road _straight_ so that it passes through the main road.
1. Record the smallest spacing where the build succeeds. The next step below is the first to fail.

**NB:** Make sure the extension in **#4** snaps to its own **0° build guide**,
**not** the road beside it, as that would shift it to a 4 m spacing!

| Angle | X     | Note |
| ----- | ----- | ---- |
| 90°   | 2.5 m |      |
| 75°   |       |      |
| 60°   |       |      |
| 45°   |       |      |
| 30°   |       |      |
| 20°   |       |      |

### Parallelism mod

| Angle | T     | X     | Note                                                                 |
| ----- | ----- | ----- | -------------------------------------------------------------------- |
| 90°   | 2.5 m | 2.5 m | X at 2.5 m holds from 90.0° down to about 88.2° (slightly variable). |
| 75°   | 2.0 m |       | X at 2.0 m refused                                                   |
| 60°   |       |       |                                                                      |
| 45°   |       |       |                                                                      |
| 30°   |       |       |                                                                      |
| 20°   |       |       |                                                                      |

#### Observations

- T and X have different limits: at 75°, a T at 2.0 m builds, an X at 2.0 m does not.
- ¹Follow-up to the above: T works at (mostly?) any angle at 2.5 m spacing.
- At 90° a T needs 2.5 m, at 75° only 2.0 m: a slanted T fits closer (its junction is
  longer along the main road, so the two junctions sit further apart there).

## Native layout of the main road (33 degrees, 20 m spacing)

Twice the same: junctions 66.1 m apart (36 m centre distance / sin 33), the nearest
plain nodes outside them 53.0 m away, none between them. The builder removes plain nodes
12.7-12.9 m from a junction and moves or inserts a node to make the outer piece 53.0 m.
Verified parallel: the three crossing roads at 0.00 degrees to each other, 36.00 m apart.

## T and X are the same

Built correctly (extended along the straight build guide, not snapped to the other road,
which pulls the spacing toward the builder's 4 m), T and X accept the same spacing. 90
degrees: 2.5 m.
