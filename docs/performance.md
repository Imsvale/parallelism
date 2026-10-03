# Performance

Where the time goes while dragging, what has been done about it, what could still be
done, and what cannot. Status 2026-10-03.

## How to measure

With `PERF_MEASURES` on (`parallelism_shared.lua`), the log has two kinds of lines:

- `perf [tracks N]: preview plan took X ms (... ; orient, offsets, crossings, merges,
  emit (re-lay, game objects, node configs), check; searches: game index, builder's
  edges)`: one plan for the preview, by phase. Logged for plans over 20 ms.
- `perf [tracks N]: 100 builder requests, P planned, X ms planning (worst ...), ...,
  J judged by the game in Y ms` (the drag check), and `100 tooltip calls, C preview
  changes, X ms preview lua (of which J judged by the game in Y ms)` (the preview).

`tests/chain_bench.lua` times the re-laying offline.

## Where the time goes

Every change of a drag is handled twice, by two separate parts of the mod:

1. **The drag check** (game script, `checkPlayerProposal`): the builder asks it
   synchronously on every change. It plans the drag and, for drags that cross or join
   roads, has the game judge our plan joined with the builder's (`makeProposalData`).
2. **The preview** (menu, `updatePreview`): plans the same drag again, has the game judge
   it once more as a safety check before showing it, and the preview display judges it a
   third time.

The builder also alternates between two drag positions while the cursor is still, and asks
again for each.

Measured on a 12-track drag over 12 tracks (132 crossings), per plan:

| Part | Before | Now |
| --- | --- | --- |
| Whole plan | 240-400 ms | about 220 ms |
| Finding crossings | 142-265 ms | about 90 ms |
| of which: searching the builder's edges | 105-235 ms | about 77 ms |
| of which: the game's spatial index | | 1-5 ms |
| Re-laying (chain module) | 56-91 ms | 60-85 ms |
| Creating the game's edge objects | | under 15 ms |
| The game's judging, drag check | | about 100 ms each |
| The game's judging, preview | | about 10-30 ms each |

A 6-track drag over 6 tracks takes 60-155 ms per plan, simple bundles 20-30 ms.

## Done

- **Log volume** (2026-10-03): full proposal dumps on every judgement and per-change
  log lines made the log grow by megabytes per drag. Off by default (`DUMP_BEFORE_JUDGING`).
- **Straying measure** (`geometry.straysFrom`): checking how far a merged curve strays from
  the old pieces compared every sample with every point of the curve. The search now moves
  along the curve with the samples; same results on 48 test cases, about 6 times faster.
  `mergeDeviation` (and with it `geometry.merge`) uses it too.
- **Straight joins**: pieces on one straight line are joined without any sampling.
- **Builder's edges**: their plain geometry is read from the game's objects once per plan,
  not on every search, and they are sorted into a 50 m grid so a search only looks at the
  cells it touches.
- **Crossings at our own nodes**: each node is checked once (two edges share it), roads
  far from the node are skipped by a rough distance before the exact one, and the scan for
  a crossing already found runs only for a node actually on the road.
- Earlier (2026-10-02): edges at a node read node by node instead of the whole map (also
  a memory problem), component and template caches, adaptive sampling and cached
  polylines in the crossing search, a preview debounce.

## What could still be done

Roughly by expected gain:

1. **Plan once per drag position.** The drag check and the preview plan the same drag
   independently. Sharing one plan (and one judgement) would roughly halve the mod's work.
   Structural: the two run in different parts of the game (game script and menu), and
   whether they can share Lua state is not known yet.
2. **Fewer judgements by the game.** The preview's safety judgement before showing a plan
   (added against the empty-node crash) could go now that the join's consistency check
   refuses such plans. Saves 10-30 ms per preview change.
3. **Searching the builder's edges** still costs about 77 ms on the biggest drags: the
   exact distance (`distanceToEdge`, sampled) runs for every edge whose bounding circle
   touches the search. A rough distance first (as done for our own nodes) would skip most.
4. **Re-laying**: about half a millisecond per crossing. Edge lengths and positions
   along each chain are sampled again for every junction and piece; computing them once
   per chain would save part of it.
5. **Crossing search proper**: the intersections of each offset edge with each nearby
   edge; a grid of the world's edges per plan (like the builder's) would cut the candidate
   pairs further.

## Fundamental limits

- **The game's judging** (`makeProposalData`) is the game's own work: about 100 ms for a
  joined 12x12 proposal. The mod can only ask less often, not make it faster. The drag
  check needs it to refuse drags that would build in part.
- **Synchronous drag check**: the builder waits for the game script's answer on every
  change, so planning time there is felt directly as lag. The preview's time shows as a
  late preview instead.
- **Lua and the game API**: plain Lua, single-threaded, and every read of a game object
  (components, proposal entries) goes through the API. Big plans create hundreds of
  game objects (edges, node configs).
- **Size of the job**: a 12x12 crossing is 132 junctions, each with its own geometry,
  keep-outs and lane connections. The work grows with the number of crossings; there is
  no way to plan it without doing it.
