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

| Angle | X      | Note |
| ----- | ------ | ---- |
| 90°   | 2.5 m  |      |
| 75°   | 6.5 m  |      |
| 60°   | 10.0 m |      |
| 45°   | 13.0 m |      |
| 30°   | 15.0 m |      |
| 20°   | 16.0 m |      |
| 15°   | 16.0 m |      |
| 10°   | 16.5 m |      |

At 5° the game will do a T, but not an X. Since T's are more generous, I here placed the
junctions for the now pesudo-parallels as close to the middle junction as I could fit.
(They're no longer exactly parallel, but inching a bit closer to the middle road.)
See log for the result. It's the last one I built.

### Analysis of the native X (2026-10-03)

The native X column is one rule: **the corners of neighbouring junctions must be about
2.5 m apart along the main road.** A junction's corner (where the edges of the two roads
meet) lies `wc/2 / sin(a) + wm/2 / tan(a)` from its centre along the main road (`wc`:
crossing road width, `wm`: main road width, `a`: the angle). With the junctions
`(gap + wc) / sin(a)` apart, that gives the smallest gap:

    gap_min = wm * cos(a) + 2.5 m * sin(a)

For 16 m roads, predicted against measured: 90: 2.50 / 2.5, 75: 6.56 / 6.5, 60: 10.17 /
10.0, 45: 13.08 / 13.0, 30: 15.11 / 15.0, 20: 15.89 / 16.0, 15: 16.10 / 16.0, 10: 16.19 /
16.5. The measured values are on the slider's 0.5 m steps; all within one step. Left
between the corners: 2.1 to 2.8 m (4.3 m at 10 degrees, where one step is a lot).

Read: the main road's width, seen along the crossing roads (`wm * cos(a)`), plus a
little. At small angles it approaches the main road's full width.

### Parallelism mod

| Angle | T     | X      | Note                                                                 |
| ----- | ----- | ------ | -------------------------------------------------------------------- |
| 90°   | 2.5 m | 2.5 m  |  |
| 75°   | 2.5 m | 6.5 m  |                                                                      |
| 60°   | 2.0 m | 10.5 m |                                                                      |
| 45°   | 1.5 m | 13.5 m |                                                                      |
| 30°   | 1.5 m | 16.0 m |                                                                      |
| 20°   | N/A   |        | Angle too small. Won't build at any spacing (current mod version).   |

## Earlier notes (to re-validate against the new data)

### Native layout of the main road (33 degrees, 20 m spacing)

Twice the same: junctions 66.1 m apart (36 m centre distance / sin 33), the nearest
plain nodes outside them 53.0 m away, none between them. The builder removes plain nodes
12.7-12.9 m from a junction and moves or inserts a node to make the outer piece 53.0 m.
Verified parallel: the three crossing roads at 0.00 degrees to each other, 36.00 m apart.

### T and X are the same

Built correctly (extended along the straight build guide, not snapped to the other road,
which pulls the spacing toward the builder's 4 m), T and X accept the same spacing. 90
degrees: 2.5 m.

### Native layout at 25 degrees (20 m spacing, two X groups)

Junctions 85.3 m apart along the main road (36 / sin 25), nothing between them, the
nearest plain node outside 62.1 m away (both groups); on the outer crossing roads also
62.1 m on both sides of the junction.

**Fit:** the outer distance is the junction's corner plus 26.0 m, exactly at both angles:
w/2 / sin(a) + w/2 / tan(a) + 26.0 (16 m roads: 53.0 m at 33 degrees, 62.1 m at 25;
predicts 34 m at 90, 40 m at 60, 46 m at 45). Used as the room next to a road junction
(outer side) since 2026-10-03. To check: a native X at 90 or 60 degrees.

### Native layouts at 90 and 60 degrees (20 m spacing)

No fixed distance here: the nearest plain nodes outside the junctions were wherever they
happened to be, all beyond the predicted room (90 degrees: 45.3 m and more against 34 m
predicted; 60 degrees: 47.1 m and more against 39.9 m). Consistent with the rule, no
check of it: the builder only moves nodes that are inside the room, and here none were.
At 33 and 25 degrees the same 53.0 / 62.1 m came back every time, which is what a moved
node looks like.

With the rule: the mod's T builds from 90 down to about 28-32 degrees (2026-10-03).
