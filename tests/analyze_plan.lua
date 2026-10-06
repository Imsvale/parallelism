-- Checks a failed build plan from the game log for likely reasons the game refused it.
--   lua tests/analyze_plan.lua <file>
-- The file holds the table printed after "plan: " in a "[parallelism]   plan: {...}" line.

local here = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
package.path = here .. "/../mod/content/gui/parallelism/?.lua;" .. package.path
local geometry = require "parallelism_geometry"

local file = assert(io.open(assert(arg[1], "usage: analyze_plan.lua <file>"), "r"))
local text = file:read("a")
file:close()
local plan = assert(load("return " .. (text:match("plan: (%b{})") or text)))()

local function len2d(v)
	return math.sqrt(v.x * v.x + v.y * v.y)
end

local function angle(a, b)
	local la, lb = len2d(a), len2d(b)
	if la < 1e-9 or lb < 1e-9 then
		return 0
	end
	local c = (a.x * b.x + a.y * b.y) / (la * lb)
	return math.deg(math.acos(math.max(-1, math.min(1, c))))
end

print(#plan .. " edges")
local byNode = {}
for _, e in ipairs(plan) do
	local chord = { x = e.p1.x - e.p0.x, y = e.p1.y - e.p0.y, z = 0 }
	local edge = { p0 = e.p0, p1 = e.p1, t0 = e.t0, t1 = e.t1 }
	print(string.format("edge %d  %d -> %d  chord %.2f m  arc %.2f m  |t0| %.2f  |t1| %.2f  t0/chord %.1f deg  t1/chord %.1f deg  radius %.1f",
		e.entity, e.node0, e.node1, len2d(chord), geometry.arcLength(edge), len2d(e.t0), len2d(e.t1),
		angle(e.t0, chord), angle(e.t1, chord), geometry.radius(e.p0, e.p1, e.t0, e.t1)))
	if len2d(chord) < 5 then
		print("  ! short edge")
	end
	if angle(e.t0, chord) > 60 or angle(e.t1, chord) > 60 then
		print("  ! tangent far off the chord (flipped or strongly bent)")
	end
	byNode[e.node0] = byNode[e.node0] or {}
	byNode[e.node1] = byNode[e.node1] or {}
	table.insert(byNode[e.node0], { edge = e, outgoing = e.t0, pos = e.p0 })
	table.insert(byNode[e.node1], { edge = e, incoming = e.t1, pos = e.p1 })
end

print("nodes:")
for node, list in pairs(byNode) do
	local line = string.format("node %d  %d edges", node, #list)
	for i = 2, #list do
		if geometry.horizontalDistance(list[i].pos, list[1].pos) > 0.01 then
			line = line .. string.format("  ! position mismatch %.3f m", geometry.horizontalDistance(list[i].pos, list[1].pos))
		end
	end
	-- a node joining two edges of one track: the tangents must run on
	if #list == 2 then
		local d1 = list[1].incoming or { x = -list[1].outgoing.x, y = -list[1].outgoing.y }
		local d2 = list[2].outgoing or { x = -list[2].incoming.x, y = -list[2].incoming.y }
		line = line .. string.format("  kink %.2f deg", angle(d1, d2))
	end
	-- a crossing: the four edges must pair up into two tracks running straight through,
	-- the game crashes on one that bends there
	if #list == 4 then
		local dirs = {}
		for i, entry in ipairs(list) do
			-- direction leaving the node
			dirs[i] = entry.outgoing or { x = -entry.incoming.x, y = -entry.incoming.y }
		end
		local best = math.huge
		for _, pairing in ipairs({ { 1, 2, 3, 4 }, { 1, 3, 2, 4 }, { 1, 4, 2, 3 } }) do
			local worst = math.max(
				180 - angle(dirs[pairing[1]], dirs[pairing[2]]),
				180 - angle(dirs[pairing[3]], dirs[pairing[4]]))
			best = math.min(best, worst)
		end
		line = line .. string.format("  crossing, straight within %.2f deg", best)
		if best > 1 then
			line = line .. "  ! tracks bend at the crossing"
		end
	end
	print(line)
end

print("crossings between plan edges:")
for i = 1, #plan do
	for j = i + 1, #plan do
		local a, b = plan[i], plan[j]
		for _, x in ipairs(geometry.intersections(a, b)) do
			local atEnds = geometry.horizontalDistance(x.pointA, a.p0) < 0.1 or geometry.horizontalDistance(x.pointA, a.p1) < 0.1
			if not atEnds then
				print(string.format("  ! edges %d and %d cross at (%.2f, %.2f)", a.entity, b.entity, x.pointA.x, x.pointA.y))
			end
		end
	end
end

-- the tightest bends, sampled along each edge (the game refuses some as Too Much Curvature)
print("tightest edges (radius sampled along the edge):")
local radii = {}
for _, e in ipairs(plan) do
	radii[#radii + 1] = { entity = e.entity, r = geometry.minRadiusAlong(e), ends = geometry.radius(e.p0, e.p1, e.t0, e.t1),
		length = geometry.arcLength(e) }
end
table.sort(radii, function(a, b) return a.r < b.r end)
for i = 1, math.min(8, #radii) do
	local r = radii[i]
	print(string.format("  edge %d: %.1f m along (%.1f m from its ends), %.1f m long", r.entity, r.r, r.ends, r.length))
end
