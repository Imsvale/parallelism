# How the native builder crosses a bundle at a straight-to-curve seam

2026-10-02. A 6-track bundle (straight 84 m, then 90 degrees right in two 45-degree
edges, radii 55-80 m) crossed by 8 straight tracks built one by one by hand, heading
about 110 degrees, right through the seams. Before/after dumps (100 m around
(-113.9, -1364.4)) and the builder's proposal for every build are in the game log of
that night (00:03-00:07 UTC); the parser used is `tests/study_native.py`.

## Findings

1. **Crossing nodes lie on the old track**, within 1-8 mm.
2. **Plain nodes near a crossing are removed and the track is refitted.** Every
   straight-to-curve seam node and every curve-to-curve node of the bundle near the
   crossings was gone after the builds (12 nodes). In their place the builder lays one
   cubic from the crossing node to a new node further along the old track:
   - the new node lies on the old track, usually **30.0 m** (29-30) along from the
     crossing; when the seam is behind the crossing (crossing already on the curve), the
     run from the last kept node to the crossing is re-split into equal pieces instead
     (51.9 + 51.9; 33.1 + 33.1 + 29.0; 27.5 + 27.5 + 30.0);
   - **both end directions are the old track's** at those points (G1 continuous);
   - **both tangents have the same length, 4R tan(theta/4)**: the cubic of the circular
     arc through the two ends with those directions (theta the turn between them,
     R = chord / (2 sin(theta/2))). Matches all refitted pieces within 0.1 %.
3. **The track moves.** The refitted pieces stray from the old line by 0.03-0.38 m per
   build; after all 9 builds the original line is off by up to 0.49 m (typically
   0.1-0.25 m). Pieces not touching a seam (cut between crossings) stay within 1 cm.
4. **Curvature may get tighter than before.** A refitted piece reached 49.8 m minimum
   radius on a 65 m curve, 47.2 m on 55 m: below the drag limit (55 m), above the
   type's `minCurveRadius` (40 m). So the check for reshaped existing track is the
   type's minimum, not the original radius.
5. **Short pieces between crossings** were 5.9-13 m (crossings 5 m apart on parallel
   tracks at a shallow angle), consistent with the 5 m minimum.

## The mod across the same seam (refit added 2026-10-02, c3cefad)

Same bundle, reloaded each time, one straight drag with the mod through the seams.

| Tracks | Result | Notes |
|---|---|---|
| 2 | built | The drawn track crossed first (native: 11 edges removed, 24 added, seams refitted). The extra track at 5 m then crossed the native's new pieces (6 crossings, 29-41 deg, pieces 9.2-10.2 m), no existing node had to go: 0 moved, 5 own nodes slid onto crossings. Our refit was not needed. |

## Compared with the mod

The mod's rule (2026-10-01) keeps existing track exact: plain nodes may only slide along
their own track within 5 cm, seam nodes slide away to 5 m, otherwise the drag is refused.
The native builder is looser: it removes seam nodes near crossings and refits up to 30 m
of track with a G1 arc-cubic, accepting several decimetres of drift and tighter curves
down to the type's minimum. That is why bundles across seams build by hand and not with
the mod.
