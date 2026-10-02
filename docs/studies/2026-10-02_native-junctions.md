# How the native road builder configures junctions

2026-10-02, game log 00:45-00:46 UTC. Small town roads (two-way `town_new_small`, one-way
`town_new_one_way_small`), built by hand: a straight road, then (1) a two-way road across
it, (2) a two-way T-junction onto it, (3) a one-way road across a two-way road, (4) a
one-way road across that one-way road.

## Every node gets a config

The builder's proposal carries a `nodeConfigsToAdd` entry for every node it touches, new
or existing (an existing node's config is replaced: `nodeConfigsToRemove` + add):

- a dead end: no lane connections, `crosswalks` = its one edge;
- a plain node between two edges: 2 connections (straight on, both ways);
- a junction: every turn, see below; `crosswalks` = all its edges;
- always `trafficLightPreference 2`, `doubleSlipSwitch false`.

## Lane indices are seen from the node

Lanes of these roads: 0 sidewalk, 1 and 2 driving lanes, 3 sidewalk (two-way: 1 back,
2 forward; one-way: 1 and 2 forward). A connection `segment.lane` counts the lanes as
seen from the node looking out along the edge: for an edge that starts at the node
(node0) the physical index, for an edge that ends there (node1) mirrored
(`n - 1 - index`). From the node, a two-way road's lane 1 always comes in and lane 2
always goes out (`A.1 -> B.2` for every pair at the 4-way junction).

## Which turns

- No U-turns; every other incoming edge to outgoing edge pair is connected.
- Straight on with the same number of lanes: lane to lane.
- Into a two-lane one-way road from a single lane: into both lanes.
- From a two-lane one-way road: a right turn from the right lane (into one lane) or lane
  to lane (into two); a left turn from the left lane, into all lanes.
- Only `withRoad` connections on these roads (no trams).
- Crosswalks only over edges with a sidewalk (a lane for PERSON): at a highway crossing
  a town road only the two town road pieces get one, a highway dead end none.

## Highways (00:54-00:55, built by the mod's tests)

A three-lane highway carriageway across a two-way road (13 connections) and starting
at one (8): the same rules hold. Straight on lane to lane, the right turn from the
right lane, the left turn from the left lane, a single lane into all three.

## Hand-built highway controls (01:02-01:05)

Two-lane highway carriageway across a two-way street in both directions, starting at
one, ending at one; three-lane highways crossing each other sharply (turns of about 146
degrees). The rules above reproduce the first four once one is added: **a road with no
way straight on (ending at another) turns left from all its lanes**, the right turn
still from the right lane only. The sharp highway crossing does not fit: the builder
connects the 146-degree turn lane to lane and spreads the right two lanes over the
straight exit. One sample is not enough to derive that; it stays a known difference
(our connections there are complete, just laid out differently).

## 6-lane country roads, ramps, bus lanes (01:11-01:18)

13 more junctions (`tests/junction_survey.lua`, made by `tests/junctions_from_log.py`).
The builder's lane allocation for multi-lane roads goes its own way: a left turn from
the two left lanes of three, a 6-lane road at a T turning from all three lanes, ramps
into the adjacent lane only, and sharp turns (146 degrees) connected lane to lane.

## Decision: our own rules (2026-10-02)

Not worth reverse-engineering further: the player can change any junction with the
game's lane tool, other mods will have their own ideas, and some of the builder's
defaults are arguably poor (turning across three lanes at a sharp highway junction).
The bar is: never a junction the game cannot take, and lanes reasonably aligned. The
rules (`planner.junctionConnections`): straight on lane to lane; turns from the lanes on
their own side (a third each side when there is a way straight on, half each at a T),
never across other traffic; no turns sharper than 135 degrees; a ramp lane to lane into
the outer lanes on its side. `tests/junction_check.lua` checks every junction for
completeness, allowed turns and uncrossed lanes; all 24 recorded junctions pass, 13 of
them 100 % like the builder's, most others 80-88 %. Known: a ramp exactly in line with
the main road joins on the left; the builder chose the right once, the left twice (we
do not know which side the ramp lies on from directions alone). The drawn road always
keeps the builder's own config, a ready comparison in game.

## The mod (2026-10-02)

`planner.junctionConnections` reproduces all six junctions exactly
(`tests/junction_test.lua`). In game, extra road pairs crossing a two-way road, a
highway pair across a town road and a pair starting at a road (T) all built.

## What this means for the mod

Our junction nodes (an extra road crossing or joining a road) got no config at all, the
prime suspect for the crashes in `map_util.h` that made us switch junctions off. The
drawn road usually crosses the same road right next to ours (a split highway's two
carriageways cross a road together), so the builder's own config for the drawn road's
junction is a model: mirror it, with edges matched by direction, as our other nodes
already copy the drawn node they mirror.
