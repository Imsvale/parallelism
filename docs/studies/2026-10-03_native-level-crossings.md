# Native level crossings

Roads crossing tracks and tracks crossing roads, built natively on 2026-10-03 (town road
`town_new_small`, 16 m; track `simple`) and read from the builder's proposal dumps
(`tests/`-style analysis of `dump streetBuilder` / `dump trackBuilder`).

## The node

A level crossing is one shared node with two road edges and two track edges (three for a
T). Its node config holds the road's lanes only, straight through, with crosswalks on the
road edges:

    node 692: lanes [669.1->718.2 road, 718.1->669.2 road] crosswalks [718, 669]

The track edges take no part in the config. (In `tests/junction_test.lua` as "level
crossing: the road straight through": the mod's junction rules give the same.)

## Angles

Both ways (road over track at 21:34:15, track over road at 21:34:58) native builds down to
about 6.3 degrees, the same limit as track crossings (6.0).

## Room along each road

| Build | Case | Native |
| --- | --- | --- |
| 21:32:42 | road over track, 90 deg | nodes 28-40 m away kept |
| 21:33:11 | road over track, 45 deg | track node 29.9 m away kept |
| 21:36:22 | road over track, 90 deg, track node 6.7 m away | removed |
| 21:34:15 | road over track, 6.3 deg | track nodes 19, 62, 100 m away removed; new nodes 110.0 m along the track, 109.6 m along the road, both sides |
| 21:34:58 | track over road, 6.3 deg | the same: 109.3-109.7 m on all four sides |

Fit, the same shape as the road junction rule: along a road or track `along` wide, crossed
by one `across` wide at angle `a`,

    overlap = across/2 / sin(a) + along/2 / tan(a)
    room    = overlap + 19 m

with a 4 m track: 110 m along the track and 109.6 along the road at 6.3 degrees; 27 m along
the track and 21 m along the road at 90 degrees, which keeps or removes every node above
as native did. Fitted on one flat build: the constant (and the track width) to check at a
second angle, e.g. 15 or 20 degrees.

## A road continuing from a level crossing node (2026-10-04)

A road started from (or extended across) a level crossing node continues the road already
there smoothly, from its tangent, even in the straight build mode: as track does, unlike a
road junction, where the straight mode makes a corner. So extending a T on a track into an
X at another angle makes the extension curve away from the T's direction. The mod's
parallels continue from their own T nodes, which lie where each parallel's line meets the
track (offset / tan(angle) along it from beside the drawn node): their ends slide along
the parallel to those nodes, and a curving extension meets them a few metres off the
straight slide (accepted up to a tenth of the spacing).

## 2026-10-27: limits between level crossings (native, town road 16 m, simple track 4 m)

- **Flattest level crossing:** 6.0 degrees (track across a road: 6.0 built, 5.8 and below
  refused), the same as track over track. Not exposed by the game: an engine limit.
- **Along a road, crossings side by side merge** (one wide crossing, barriers only at its
  outer edges): 8 tracks 4.0 m apart (center to center, ballast touching) crossed by a road
  at 88.6 degrees, road pieces 4.0 m between the crossings: built. At 45.5 degrees with
  tracks 5 m apart, 7.0 m pieces: built.
- **Along a track, each road's crossing needs its full corner plus 2.5 m to the next**
  (its own barriers and signs; the user saw the extra room is for them). A track across 4
  roads side by side, at the flattest angle the game took for each road gap:

  | Road gap | Angle | Track piece | Piece - 2 x (8/sin a + 2/tan a) |
  |---|---|---|---|
  | 3.0 m | 82.7 | 19.15 m | 2.51 m |
  | 3.5 m | 74.3 | 20.26 m | 2.51 m |
  | 4.0 m | 64.2 | 22.20 m | 2.51 m |

  2.5 m is also the gap between road junction corners (native X, 2026-10-03).
- **Next to a road junction, along the road** (one square T, the track crossing the T's
  stem): the road piece between them held the junction's corner (8 m), the level
  crossing's corner (2/sin a + 8/tan a) and 4.3 m: built at 90 degrees with 15.0 m and at
  71.5 with 17.1 m, refused at 88.0 / 87.6 with 14.4 / 14.3 m and at 71.4 with 17.1 m. One
  T only: whether the 4.3 m is 2.5 m plus a fixed setback of the barriers, or depends on
  angle or width, needs a T at another angle (planned).
- **Nodes near a level crossing** (a road with nodes every 30 m, a track across at 90, 45
  and 20 degrees): every node the builder removed lay within corner + 19 m, every node it
  kept beyond it; no contradiction of LEVEL_CROSSING_BEYOND, no tighter bound either.
- **Roads crossing tracks 5 m apart** were refused below 20.9 degrees (20.8 refused with a
  longer road piece than 20.9 built). The builder re-lays the crossed tracks around the
  crossings (removes their nodes, adds new ones further out); that refit is the likely
  limit, not the crossings' spacing.

### A T at 60 degrees (2026-10-27, second session)

Track crossing the T's main road near the junction (node 322), road piece crossing to
junction at the limit:

| Side | Track angle | Piece | Junction corner | Level corner (2/sin a + 8/tan a) | Extra |
|---|---|---|---|---|---|
| acute (60) | 60.4 | 25.8 m | 13.9 m (8/sin 60 + 8/tan 60) | 6.86 m | 5.1 m |
| obtuse (120) | 88.7 | 10.95 m | 4.6 m (8/sin 60 - 8/tan 60) | 2.18 m | 4.15 m |
| obtuse (120) | 82.45 | 11.85 m | 4.6 m | 3.08 m | 4.15 m |
| square T (first session) | 71.5-90 | 15.0-17.1 m | 8 m | 2.0-4.8 m | 4.3 m |

The extra is about 4.2-4.3 m, about 1 m more on the acute side (the real corner is
rounded differently from the simple corner formula). Screenshot: the barrier and its box
stand on the road's edge between the junction's corner and the crossing; the road ramps
up to the top of the rails over about 2 m (track lane height 0.53 m: ballast 0.3 +
sleepers 0.054 + rail 0.17; road driving lanes 0); one drag logged "Too Much Incline".
Candidates: 2.5 m corner gap + ramp (0.53 / the road's slope limit), or 2.5 m + the
barrier's footprint. The town road's template sets no slope limit (game default).

Bulldozing a track that crossed a road leaves the road's node where the crossing was: the
two road pieces are not merged back.

Slope limits read in game (2026-10-27): town road maxSlope 0.40, maxSlopeBuild 0.20,
maxSlopeShape 0.40; simple track 0.13 / 0.085 / 0.16. The road's ramp up to the rails at
maxSlopeShape: 0.53 / 0.40 = 1.33 m. Margin beyond 2.5 m + ramp: 0.3 m (obtuse side),
0.5 m (square), 1.3 m (acute side): growing with how sharp the junction's curb corner is,
which the corner formula leaves out. The planner now keeps a level crossing and a road
junction along a road junction corner + level crossing's full corner + 2.5 m + ramp, all
from the templates, at most that much more permissive than the game (whose own verdict on
the plan covers the rest).

### Node areas read from the game (2026-10-27, tools/node_areas.lua)

An edge's transport-network lanes run only between the areas of its two nodes, so the
areas can be read exactly:

- **Junction area** along a road: the corner of the road edges (w/2 / sin + w/2 / tan of
  the sharpest neighbor) **+ 1.00 m**: 14.86 m (60 degree side, 13.86 + 1), 5.62 m (120,
  4.62 + 1), 17.00 m on a 32 m road at a square T (16 + 1).
- **The ramp** is the edge's own lanes, whatever their length: 0.48 m up (road surface to
  the crossing's road lanes) over 1.92 m at the limit (slope 0.25, "Too Much Incline"),
  over 38-58 m on longer edges.
- **Crossing area** along the road, squared off: set by the barrier model (the crossing
  type's config picks it by street width; era C EU: eu_c_barrier_small up to 18 m,
  bbMin y -1.68 = overhang beyond the post, x -0.95 .. 0.43 = 1.38 m deep). Area =
  (road half width + overhang) x cot(angle) + track half width / sin(angle) + depth,
  depth fitting 1.20-1.30 m: 9.06 m (16 m road, 60.45 deg), 3.40 m (16 m, 88.84), 13.81 m
  (32 m road, 60.0, eu_c_barrier_large, same overhang).
- Era A crossings have only a sign (no barrier): smaller areas then.

### Era A (1900, sign only) and the rule as built (2026-10-27)

Country roads (no raised sidewalks), 60 degree Ts, crossings at the limit, node areas:

| Edge | Road, side | Angle | Junction area | Ramp | Crossing area |
|---|---|---|---|---|---|
| 883 | small (14 m), acute | 82.2 | 13.11 (corner + 1: 13.12) | 1.79 | 4.23 |
| 938 | small, obtuse | 76.0 | 5.04 (5.04) | 1.78 | 5.10 |
| 1086 | large (30 m), acute | 76.9 | 26.96 (26.98) | 2.71 | 6.80 |
| 1114 | large, obtuse | 83.6 | 9.67 (9.66) | 2.67 | 4.95 |

Fitting reach and depth freely per road: depth 1.20 (small), 1.25 (large); with the
era C barrier it was 1.20: a fixed depth, not the model's. The ramps are not settled
(1.78-1.92 m on the smaller roads, 2.7 m on the large country road).

The rule in the planner: crossing area = (road half width + overhang) x cot + track half
width / sin + 1.2 m, the overhang read at run time from the crossing type of the current
year (its models for the road's width class, -bbMin.y); junction area = corner of the road
edges at the sharpest unfolded angle + 1.00 m; between them the ramp (height / the road's
maxSlopeShape). Against the six native limits: 0.5-0.7 m more permissive, 1.4 m on the
large country road; never stricter.

### The ramp's minimum by road width (2026-10-27, at the limit)

| Road | Width | Minimum ramp |
|---|---|---|
| country_old_small | 14 m | 1.78-1.79 m |
| town_new_small | 16 m | 1.92 m |
| town_old_medium_tram | 24 m | 2.43-2.47 m |
| country_old_large | 30 m | 2.65-2.67 m |

The climb is 0.48 m on all of them and their slope limits are the game's defaults, so no
slope rule gives this; it is not linear in the width either (the line through 14 and 30 m
says 2.33 at 24). Mechanism unknown. The planner keeps height / maxSlopeShape (1.33 m),
0.5-1.4 m more permissive than the game; the game's verdict covers the rest. (The medium
road's T at 69.6 / 110.4 degrees: junction areas 18.28 / 9.34 m, corner + 1 m again.)
