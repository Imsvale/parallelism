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
