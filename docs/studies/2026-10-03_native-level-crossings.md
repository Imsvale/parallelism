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
