-- How far each node's area reaches along a road or track edge: the edge's transport-network
-- lanes start and end where the areas of its two nodes (a junction, a level crossing) end.
-- Prints, for each edge id in EDGES: its length between the nodes, and for each lane how far
-- its ends lie from node0 and node1, measured along the edge's own straight line; and for
-- each node of those edges, its own lanes (across the junction or crossing) the same way.
-- Read only, changes nothing. Paste into the in-game console (it has no dofile); the
-- output goes to the game log (stdout.txt), lines starting with "AREAS".
local EDGES = { 445, 484 }

local function p(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[#parts + 1] = tostring((select(i, ...)))
	end
	print("AREAS " .. table.concat(parts, " "))
end

local function v(x)
	return { x = x.x, y = x.y, z = x.z }
end

local function dist(a, b)
	return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
end

-- position along the line from a to b (meters from a), and how far off it
local function along(q, a, b)
	local dx, dy = b.x - a.x, b.y - a.y
	local len = math.sqrt(dx * dx + dy * dy)
	local s = ((q.x - a.x) * dx + (q.y - a.y) * dy) / len
	local off = ((q.x - a.x) * dy - (q.y - a.y) * dx) / len
	return s, off
end

local function lanes(entity)
	local result = {}
	local tn = api.engine.getComponent(entity, api.type.ComponentType.TRANSPORT_NETWORK)
	if not tn then
		return result
	end
	local edges = tn.edges
	for i = 1, #edges do
		local g = edges[i].geometry
		local p0 = v(api.engine.util.transport.calcPosition(g, 0))
		local p1 = v(api.engine.util.transport.calcPosition(g, 1))
		result[#result + 1] = { p0 = p0, p1 = p1, length = g.length }
	end
	return result
end

local nodesSeen = {}
for _, e in ipairs(EDGES) do
	local ok, err = pcall(function()
		local be = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		local n0 = api.engine.getComponent(be.node0, api.type.ComponentType.BASE_NODE)
		local n1 = api.engine.getComponent(be.node1, api.type.ComponentType.BASE_NODE)
		local a, b = v(n0.position), v(n1.position)
		p(string.format("edge %d: node %d (%.2f, %.2f, %.2f) -> node %d (%.2f, %.2f, %.2f), %.2f m, template %s", e, be.node0, a.x, a.y, a.z,
			be.node1, b.x, b.y, b.z, dist(a, b), tostring(be.roadTemplate)))
		for i, l in ipairs(lanes(e)) do
			local s0, o0 = along(l.p0, a, b)
			local s1, o1 = along(l.p1, a, b)
			p(string.format("  lane %d: from %.2f m (off %.2f, z %.2f) to %.2f m (off %.2f, z %.2f) along node %d -> %d; %.2f m left at node0, %.2f m at node1",
				i, s0, o0, l.p0.z, s1, o1, l.p1.z, be.node0, be.node1, math.min(s0, s1), dist(a, b) - math.max(s0, s1)))
		end
		nodesSeen[be.node0] = a
		nodesSeen[be.node1] = b
	end)
	if not ok then
		p("edge " .. tostring(e) .. " failed: " .. tostring(err))
	end
end

for node, pos in pairs(nodesSeen) do
	local ok, err = pcall(function()
		p(string.format("node %d at (%.2f, %.2f, %.2f):", node, pos.x, pos.y, pos.z))
		for i, l in ipairs(lanes(node)) do
			p(string.format("  lane %d: (%.2f, %.2f, %.2f) -> (%.2f, %.2f, %.2f), ends %.2f / %.2f m from the node, %.2f m long",
				i, l.p0.x, l.p0.y, l.p0.z, l.p1.x, l.p1.y, l.p1.z, dist(l.p0, pos), dist(l.p1, pos), l.length or -1))
		end
	end)
	if not ok then
		p("node " .. tostring(node) .. " failed: " .. tostring(err))
	end
end
