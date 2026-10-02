"""Turns the road builder's junction configs in the game log into junction_test.lua cases.

python tests/junctions_from_log.py <stdout.txt> <from HH:MM:SS>

Reads every "dump streetBuilder" proposal logged after the given time (UTC), finds the
node configs with three or more edges and prints a compare(...) call per junction, with
each edge's direction (leaving the node), whether the node is its node0, its lanes and
the builder's lane connections.
"""
import re
import sys

PREFIX = re.compile(r"^\[(\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d)Z.*?\[parallelism\] (.*)$")
EDGE = re.compile(r"^  \+ edge (-?\d+) nodes (-?\d+) -> (-?\d+) p .*? t \(([-\d.]+), ([-\d.]+), [-\d.]+\) -> \(([-\d.]+), ([-\d.]+), [-\d.]+\) type \S+ objects \d+ (\S+)")
LANES = re.compile(r"^    lanes (\d+:.*)$")
CONFIG = re.compile(r"^  \+ nodeConfig (-?\d+) laneConnections (\d+)")
CONN = re.compile(r"^    lanes \[(.*)\] crosswalks \[(.*)\] trafficLightPreference")


def lanes_lua(text):
    parts = []
    for item in text.split("; "):
        m = re.match(r"\d+:(back|fwd) [\d.]+ \{(.*)\}", item.strip())
        modes = [x for x in m.group(2).split(",") if x != ""]
        table = "{" + ", ".join("[%s] = true" % x for x in modes) + "}"
        parts.append("lane(%s, %s)" % ("true" if m.group(1) == "fwd" else "false", table))
    return "{ " + ", ".join(parts) + " }"


def main():
    path, since = sys.argv[1], sys.argv[2]
    edges = {}  # latest definition of each edge
    junctions = []
    block = None
    last_edge = None
    pending = None
    for raw in open(path, encoding="utf-8", errors="replace"):
        m = PREFIX.match(raw.rstrip("\n"))
        if not m:
            continue
        time, text = m.group(2), m.group(3)
        if text.startswith("dump streetBuilder"):
            block = time >= since
            continue
        if block is None:
            continue
        if not text.startswith("  "):
            block = None
            continue
        e = EDGE.match(text)
        if e:
            entity = int(e.group(1))
            last_edge = {"entity": entity, "node0": int(e.group(2)), "node1": int(e.group(3)),
                         "t0": (float(e.group(4)), float(e.group(5))), "t1": (float(e.group(6)), float(e.group(7))),
                         "template": e.group(8)}
            edges[entity] = last_edge
            continue
        lm = LANES.match(text)
        if lm and last_edge is not None:
            last_edge["lanes"] = lanes_lua(lm.group(1))
            last_edge = None
            continue
        c = CONFIG.match(text)
        if c:
            pending = (int(c.group(1)), time)
            continue
        cm = CONN.match(text)
        if cm and pending and block:
            node, t = pending
            pending = None
            conns = [x.split(" ")[0] for x in cm.group(1).split(", ") if x]
            segs = set()
            for x in conns:
                a, b = x.split("->")
                segs.add(int(a.split(".")[0]))
                segs.add(int(b.split(".")[0]))
            for x in cm.group(2).split(", "):
                if x:
                    segs.add(int(x))
            at = [edges[s] for s in segs if s in edges and node in (edges[s]["node0"], edges[s]["node1"])]
            if len(at) >= 3:
                junctions.append((node, t, at, conns))
    for node, t, at, conns in junctions:
        print("-- node %d (%s)" % (node, t))
        print('compare("node %d (%s)", {' % (node, t))
        for e in at:
            start = e["node0"] == node
            d = e["t0"] if start else (-e["t1"][0], -e["t1"][1])
            print("\tedge(%d, %s, %.2f, %.2f, %s), -- %s" % (e["entity"], "true" if start else "false", d[0], d[1],
                                                          e.get("lanes", "{}"), e["template"].split("/")[-1]))
        print("}, { " + ", ".join('"%s"' % x for x in conns) + " })")
        print()


main()
