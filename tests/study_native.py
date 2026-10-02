import re, math, sys

LINES = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
LINES = [l[10:] for l in LINES]

V = r"\(([-\d.]+), ([-\d.]+), ([-\d.]+)\)"

def vec(m, i):
    return tuple(float(m.group(i + k)) for k in range(3))

def hermite(e, u):
    p0, p1, t0, t1 = e["p0"], e["p1"], e["t0"], e["t1"]
    u2, u3 = u * u, u * u * u
    h00, h10, h01, h11 = 2*u3 - 3*u2 + 1, u3 - 2*u2 + u, -2*u3 + 3*u2, u3 - u2
    return tuple(h00*p0[k] + h10*t0[k] + h01*p1[k] + h11*t1[k] for k in range(2))

def deriv(e, u, second=False):
    p0, p1, t0, t1 = e["p0"], e["p1"], e["t0"], e["t1"]
    if second:
        c = (12*u - 6, 6*u - 4, -12*u + 6, 6*u - 2)
    else:
        u2 = u * u
        c = (6*u2 - 6*u, 3*u2 - 4*u + 1, -6*u2 + 6*u, 3*u2 - 2*u)
    return tuple(c[0]*p0[k] + c[1]*t0[k] + c[2]*p1[k] + c[3]*t1[k] for k in range(2))

def min_radius(e, n=200):
    best = math.inf
    for i in range(n + 1):
        u = i / n
        d1, d2 = deriv(e, u), deriv(e, u, True)
        sp = math.hypot(*d1)
        cr = abs(d1[0]*d2[1] - d1[1]*d2[0])
        if sp > 1e-9 and cr > 1e-12:
            best = min(best, sp**3 / cr)
    return best

def polyline(e, n=200):
    return [hermite(e, i / n) for i in range(n + 1)]

def dist_point_poly(p, poly):
    best = math.inf
    for a, b in zip(poly, poly[1:]):
        dx, dy = b[0]-a[0], b[1]-a[1]
        L = dx*dx + dy*dy
        t = 0 if L == 0 else max(0, min(1, ((p[0]-a[0])*dx + (p[1]-a[1])*dy) / L))
        q = (a[0] + t*dx, a[1] + t*dy)
        best = min(best, math.hypot(p[0]-q[0], p[1]-q[1]))
    return best

def length(e):
    pts = polyline(e, 64)
    return sum(math.hypot(b[0]-a[0], b[1]-a[1]) for a, b in zip(pts, pts[1:]))

def parse_dump(start):
    edges, nodes = {}, {}
    i = start + 1
    cur = None
    while i < len(LINES) and not LINES[i].startswith("dump done"):
        l = LINES[i]
        m = re.match(r"edge (\d+): nodes (-?\d+) -> (-?\d+)", l)
        if m:
            cur = {"id": int(m.group(1)), "n0": int(m.group(2)), "n1": int(m.group(3))}
            edges[cur["id"]] = cur
        m = re.match(r"  p " + V + " -> " + V + ", t " + V + " -> " + V, l)
        if m and cur is not None:
            cur["p0"], cur["p1"], cur["t0"], cur["t1"] = vec(m, 1), vec(m, 4), vec(m, 7), vec(m, 10)
        m = re.match(r"  type (-?\d+)/(-?\d+), roadType", l)
        if m and cur is not None:
            cur["type"] = m.group(1)
        m = re.match(r"node (\d+): " + V + ", edges (.*)", l)
        if m:
            cur = None
            nodes[int(m.group(1))] = {"pos": vec(m, 2), "edges": [int(x) for x in re.findall(r"\d+", m.group(5))]}
        i += 1
    return edges, nodes

def parse_proposal(start):
    added_nodes, removed_nodes, added, removed, configs = {}, {}, {}, {}, []
    i = start + 1
    while i < len(LINES) and LINES[i].startswith("  "):
        l = LINES[i]
        m = re.match(r"  ([+-]) node (-?\d+) " + V, l)
        if m:
            (added_nodes if m.group(1) == "+" else removed_nodes)[int(m.group(2))] = vec(m, 3)
        m = re.match(r"  ([+-]) edge (-?\d+) nodes (-?\d+) -> (-?\d+) p " + V + " -> " + V + " t " + V + " -> " + V + r" type (\S+)", l)
        if m:
            e = {"id": int(m.group(2)), "n0": int(m.group(3)), "n1": int(m.group(4)),
                 "p0": vec(m, 5), "p1": vec(m, 8), "t0": vec(m, 11), "t1": vec(m, 14), "type": m.group(17)}
            (added if m.group(1) == "+" else removed)[e["id"]] = e
        m = re.match(r"  \+ nodeConfig (-?\d+)", l)
        if m:
            configs.append(int(m.group(1)))
        i += 1
    return added_nodes, removed_nodes, added, removed, configs

def fmt(p):
    return "(%.2f, %.2f)" % (p[0], p[1])

def heading(t):
    return math.degrees(math.atan2(t[1], t[0])) % 360

dumps = [i for i, l in enumerate(LINES) if l.startswith("dump around") and "radius 100" in l]
props = [i for i, l in enumerate(LINES) if l.startswith("dump trackBuilder")]
before_e, before_n = parse_dump(dumps[0])
after_e, after_n = parse_dump(dumps[-1])

mode = sys.argv[2] if len(sys.argv) > 2 else "before"

if mode == "before":
    print("BEFORE: %d edges, %d nodes" % (len(before_e), len(before_n)))
    for e in sorted(before_e.values(), key=lambda e: (e["p0"][0], e["p0"][1])):
        r = min_radius(e)
        print("edge %d  %d -> %d  %s -> %s  hdg %.1f -> %.1f  len %.1f  minR %s" % (
            e["id"], e["n0"], e["n1"], fmt(e["p0"]), fmt(e["p1"]), heading(e["t0"]), heading(e["t1"]),
            length(e), "inf" if r > 1e5 else "%.1f" % r))
    print()
    for nid, n in sorted(before_n.items()):
        print("node %d %s edges %s" % (nid, fmt(n["pos"]), n["edges"]))

if mode == "builds":
    for k, start in enumerate(props):
        an, rn, ae, re_, cf = parse_proposal(start)
        print("=== build %d (line %d): +%d nodes, -%d nodes, +%d edges, -%d edges, configs %s" % (
            k + 1, start, len(an), len(rn), len(ae), len(re_), cf))
        for nid, p in an.items():
            print("  + node %d %s" % (nid, fmt(p)))
        for nid, p in rn.items():
            print("  - node %d %s" % (nid, fmt(p)))
        for e in re_.values():
            print("  - edge %d %d -> %d %s -> %s hdg %.2f -> %.2f len %.1f" % (e["id"], e["n0"], e["n1"], fmt(e["p0"]), fmt(e["p1"]), heading(e["t0"]), heading(e["t1"]), length(e)))
        rpolys = {e["id"]: polyline(e) for e in re_.values()}
        for e in ae.values():
            # which removed edge it replaces (lies along), and how far it strays from it
            best = None
            for rid, poly in rpolys.items():
                dev = max(dist_point_poly(hermite(e, i / 40), poly) for i in range(41))
                if best is None or dev < best[1]:
                    best = (rid, dev)
            along = ""
            if best and best[1] < 1.0:
                along = " along -%d, strays %.4f m" % best
            # against all removed edges together (a piece spanning a removed seam)
            if rpolys:
                devs = [min(dist_point_poly(hermite(e, i / 80), poly) for poly in rpolys.values()) for i in range(81)]
                if max(devs) < 3.0:
                    along += " | vs old track: max %.4f m at u=%.2f" % (max(devs), devs.index(max(devs)) / 80)
            r = min_radius(e)
            print("  + edge %d %d -> %d %s -> %s hdg %.2f -> %.2f len %.1f minR %s%s" % (
                e["id"], e["n0"], e["n1"], fmt(e["p0"]), fmt(e["p1"]), heading(e["t0"]), heading(e["t1"]), length(e),
                "inf" if r > 1e5 else "%.1f" % r, along))

if mode == "compare":
    # for every edge that existed before: where its line is in the after state, and how far
    # the after edges along it stray from it
    bpolys = {e["id"]: polyline(e) for e in before_e.values()}
    for e in sorted(before_e.values(), key=lambda e: e["id"]):
        if e["id"] in after_e:
            a = after_e[e["id"]]
            same = a["p0"] == e["p0"] and a["p1"] == e["p1"] and a["t0"] == e["t0"] and a["t1"] == e["t1"]
            print("edge %d kept%s" % (e["id"], "" if same else " BUT CHANGED"))
            continue
        pieces = []
        for a in after_e.values():
            pts = [hermite(a, i / 20) for i in range(21)]
            near = [dist_point_poly(p, bpolys[e["id"]]) for p in pts]
            if max(near) < 1.0:
                pieces.append((a, max(near)))
        print("edge %d (%d -> %d, len %.1f, minR %.1f) replaced by %d pieces:" % (e["id"], e["n0"], e["n1"], length(e), min(min_radius(e), 99999), len(pieces)))
        for a, dev in sorted(pieces, key=lambda x: dist_point_poly(x[0]["p0"][:2], [e["p0"][:2]])):
            r = min_radius(a)
            print("   %d %d -> %d %s -> %s len %.1f minR %s strays %.4f m" % (a["id"], a["n0"], a["n1"], fmt(a["p0"]), fmt(a["p1"]), length(a), "inf" if r > 1e5 else "%.1f" % r, dev))
    print()
    print("nodes before that are gone:", sorted(set(before_n) - set(after_n)))
    moved = [(n, before_n[n]["pos"], after_n[n]["pos"]) for n in before_n if n in after_n and before_n[n]["pos"] != after_n[n]["pos"]]
    print("nodes moved:", [(n, fmt(a), fmt(b)) for n, a, b in moved])
