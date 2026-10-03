"""Edges at each junction of a proposal dump in the game log (ours: "dump refused", native:
"dump streetBuilder"): the dump at or before the given log line, with the length of each
edge at a junction and of the next edge beyond a plain node. For pairwise comparison with
native builds (2026-10-03). Usage: python tests/junction_room_from_log.py <stdout.txt> <line>"""
import re, sys, math, collections
lines = open(sys.argv[1], encoding='utf-8', errors='replace').read().split('\n')
target = int(sys.argv[2])
start = max(i for i in range(target) if 'dump refused' in lines[i] or 'dump streetBuilder' in lines[i])
edges = []
for l in lines[start+1:start+600]:
    if 'dump ' in l and ('refused' in l or 'streetBuilder' in l): break
    m = re.search(r'\+ edge (-?\d+) nodes (-?\d+) -> (-?\d+) p \(([-\d.]+), ([-\d.]+), [-\d.]+\) -> \(([-\d.]+), ([-\d.]+)', l)
    if m:
        e,a,b,x0,y0,x1,y1 = m.groups()
        edges.append((int(e),int(a),int(b),math.hypot(float(x1)-float(x0),float(y1)-float(y0))))
print(lines[start][75:200])
at = collections.defaultdict(list)
for e,a,b,L in edges:
    at[a].append((e,b,L)); at[b].append((e,a,L))
for n,lst in at.items():
    if len(lst) >= 3:
        print("junction", n, " ".join("%d->%d %.1fm" % (e,o,L) for e,o,L in lst))
        for e,o,L in lst:
            if len(at[o]) == 2:
                nxt = [x for x in at[o] if x[0] != e][0]
                print("    beyond", o, "next %.1f" % nxt[2])
