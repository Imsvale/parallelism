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
- Only `withRoad` connections on these roads (no trams); crosswalks on every edge.

## What this means for the mod

Our junction nodes (an extra road crossing or joining a road) got no config at all, the
prime suspect for the crashes in `map_util.h` that made us switch junctions off. The
drawn road usually crosses the same road right next to ours (a split highway's two
carriageways cross a road together), so the builder's own config for the drawn road's
junction is a model: mirror it, with edges matched by direction, as our other nodes
already copy the drawn node they mirror.
