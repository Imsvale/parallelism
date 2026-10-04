# How tight a road may curve (native)

Native road builds at the tightest the road builder allows, 2026-10-04, read from the
builder's proposal dumps: the turn of each edge, its radius by the ends (as an arc through
both ends with the end directions) and the radius at its tightest point (sampled along the
cubic).

| Road | Width | Turn | By the ends | Tightest point |
| --- | --- | --- | --- | --- |
| town_new_small | 16 m | 60.9 deg | 9.0 m | 9.0 m |
| town_new_small | 16 m | 144.3 deg | 9.5 m | 9.0 m |
| town_new_small | 16 m | 173.3 deg | 10.0 m | 9.0 m |
| town_new_small | 16 m | 180.0 deg | 10.1 m | 9.0 m |
| highway_new_small (one lane) | 9 m | 57.3 deg | 5.5 m | 5.5 m |
| highway_new_small (one lane) | 9 m | 59.9 deg | 5.6 m | 5.5 m |
| highway_new_small (one lane) | 9 m | 175.8 deg | 6.1 m | 5.5 m |

- The road builder refuses (Too Much Curvature) an edge whose **tightest point** is under
  **half the road's width plus 1 m**: 9.0 m for 16 m, 5.5 m for 9 m.
- The template's `minCurveRadius` (44 m for the town road) is not enforced for roads.
- The radius by the ends at the limit grows with the turn: a cubic edge cannot follow a
  circular arc, and the longer the arc the more its curvature bunches in the middle. So a
  180 degree turn needs a larger radius by the ends than a 60 degree one.

Tracks are different: the track builder enforces the template's minimum (`minCurveRadius`,
`minCurveRadiusBuild` while dragging), which other mods may change (Tighter Curves).
