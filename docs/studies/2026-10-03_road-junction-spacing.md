# Road junction spacing: what the game accepts

How close two parallel roads may cross or join a main road, by angle. Measured with
native builds: a road crossing the main road at the chosen angle, a short parallel base
made with Parallelism at the chosen spacing, then extended natively across the main
road (step 3 is the native builder's own verdict).

- Roads: main road and crossing roads `town_new_small` (two-way), flat ground.
- Spacing: Parallelism's Spacing value (gap between the roads, edge to edge).
- **T**: the parallel roads end on the main road. **X**: they cross it.
- Smallest accepted: the smallest spacing that builds. Refused below: the largest tried
  that did not. Angle as the tooltip's crossing line reads it.

| Angle | T smallest accepted | T refused below | X smallest accepted | X refused below | Note |
|---|---|---|---|---|---|
| 90° | 2.5 m | 2.0 m? | 2.5 m | | X at 2.5 m holds from 90.0° down to 88.2°; 88.1° refused |
| 75° | 2.0 m | 1.5 m | | 2.0 m | |
| 60° | | | | | |
| 45° | | | | | |
| 30° | | | | | |
| 20° | | | | | |

## Observations

- T and X have different limits: at 75°, a T at 2.0 m builds, an X at 2.0 m does not.
- At 90° a T needs 2.5 m, at 75° only 2.0 m: a slanted T fits closer (its junction is
  longer along the main road, so the two junctions sit further apart there).
