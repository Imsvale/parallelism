-- Offline tests for parallelism_chain.lua (re-laying a road around junctions), run with
-- any Lua 5.3+ interpreter: lua tests/chain_test.lua
-- The cases are the native builds of 2026-10-03 (docs/design/2026-10-03_node-placement.md).

local here = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
package.path = here .. "/../content/gui/parallelism/?.lua;" .. package.path
local geometry = require "parallelism_geometry"
local chain = require "parallelism_chain"

local failures = 0
local function check(name, ok, detail)
	print((ok and "ok   " or "FAIL ") .. name .. (detail and ("  " .. detail) or ""))
	if not ok then
		failures = failures + 1
	end
end

local function v(x, y)
	return { x = x, y = y, z = 5 }
end

local function straight(p0, p1)
	local t = { x = p1.x - p0.x, y = p1.y - p0.y, z = 0 }
	return { p0 = p0, p1 = p1, t0 = t, t1 = t }
end

-- a straight road along y through the given ys, nodes "n<y>", edges "e<i>"
local function straightChain(ys)
	local c = { nodes = {}, edges = {} }
	for i, y in ipairs(ys) do
		c.nodes[i] = { id = "n" .. y, position = v(0, y) }
		if i > 1 then
			c.edges[i - 1] = { id = "e" .. (i - 1), edge = straight(v(0, ys[i - 1]), v(0, y)) }
		end
	end
	return c
end

local function set(list)
	local s = {}
	for __, x in ipairs(list) do
		s[x] = true
	end
	return s
end

local function pieceLengths(result)
	local parts = {}
	for __, p in ipairs(result.pieces) do
		parts[#parts + 1] = string.format("%s-%s %.1f", tostring(p.node0), tostring(p.node1), geometry.arcLength(p.edge))
	end
	return table.concat(parts, ", ")
end

local function findPiece(result, a, b)
	for __, p in ipairs(result.pieces) do
		if (p.node0 == a and p.node1 == b) or (p.node0 == b and p.node1 == a) then
			return p
		end
	end
	return nil
end

-- the rule's numbers
do
	check("corner at 90 degrees is half the width", math.abs(chain.corner(16, 90) - 8) < 1e-6)
	check("corner at 20 degrees", math.abs(chain.corner(16, 20) - 45.4) < 0.05, string.format("%.2f", chain.corner(16, 20)))
	check("keep-out at 20 degrees is native's 71.3 m", math.abs(chain.roadKeepOut(16, 20) - 71.4) < 0.1,
		string.format("%.2f", chain.roadKeepOut(16, 20)))
	check("keep-out at 33 degrees is native's 53.0 m", math.abs(chain.roadKeepOut(16, 33) - 53.0) < 0.1,
		string.format("%.2f", chain.roadKeepOut(16, 33)))
	check("keep-out at 25 degrees is native's 62.1 m", math.abs(chain.roadKeepOut(16, 25) - 62.1) < 0.1,
		string.format("%.2f", chain.roadKeepOut(16, 25)))
end

-- 20 degree X, 20 m spacing (3 roads): junctions 105.3 m apart along the main road, one
-- edge between neighbours, no plain node within 71.4 m of any of them
do
	local c = straightChain({ -300, -230, -150, -95, -40, 30, 95, 150, 220, 300 })
	local keep = chain.roadKeepOut(16, 20)
	local corner = chain.corner(16, 20)
	local d = 36 / math.sin(math.rad(20))
	local function j(id, y)
		return { id = id, position = v(0, y), keepBefore = keep, keepAfter = keep, corner = corner }
	end
	local r = chain.relay(c, { j("J1", -d), j("J0", 0), j("J2", d) }, { junctionGap = chain.ROAD_JUNCTION_GAP })
	local removed = set(r.removedNodes)
	check("20 X: the six plain nodes within the keep-outs go", #r.removedNodes == 6 and removed["n-150"] and removed["n150"],
		table.concat(r.removedNodes, " "))
	check("20 X: no problems", #r.problems == 0, table.concat(r.problems, "; "))
	local between = findPiece(r, "J1", "J0")
	check("20 X: one edge between neighboring junctions, 105.3 m", between ~= nil and math.abs(geometry.arcLength(between.edge) - d) < 0.1,
		pieceLengths(r))
	local outer = findPiece(r, "J2", "n220")
	check("20 X: the outer node beyond the keep-out stays", outer ~= nil and geometry.arcLength(outer.edge) > keep, pieceLengths(r))
	check("20 X: the untouched ends are not re-laid", findPiece(r, "n-300", "n-230") == nil and not set(r.removedEdges)["e1"])
end

-- 90 degree T at 2.5 m (native, 03:58:29): our junction 18.5 m from the drawn one, the
-- plain node between removed
do
	local c = straightChain({ -100, 0, 9, 40, 80, 150 })
	c.nodes[2].fixed = true -- the drawn road's junction, already there
	local keep = chain.roadKeepOut(16, 90)
	local corner = chain.corner(16, 90)
	local r = chain.relay(c, {
		{ id = "n0", node = 2, keepBefore = keep, keepAfter = keep, corner = corner },
		{ id = "J", position = v(0, 18.5), keepBefore = keep, keepAfter = keep, corner = corner },
	}, { junctionGap = chain.ROAD_JUNCTION_GAP })
	local removed = set(r.removedNodes)
	check("90 T: the node between the junctions and the one within 34 m go", removed["n9"] and removed["n40"] and #r.removedNodes == 2,
		table.concat(r.removedNodes, " "))
	check("90 T: 18.5 m is exactly corners + 2.5 m, no problem", #r.problems == 0, table.concat(r.problems, "; "))
	check("90 T: junction to junction is one 18.5 m edge", findPiece(r, "n0", "J") ~= nil, pieceLengths(r))
end

-- 8 degree T (native, 04:41): 114 m corner on the acute side only, the obtuse side keeps
-- its node at 40.9 m
do
	local c = straightChain({ -140, -40.9, 57.9, 156.5, 250 })
	local r = chain.relay(c, {
		{ id = "J", position = v(0, 0), keepBefore = 10, keepAfter = chain.roadKeepOut(16, 8), corner = chain.corner(16, 8) },
	})
	local removed = set(r.removedNodes)
	check("8 T: the node at 57.9 m on the acute side goes", removed["n57.9"] and #r.removedNodes == 1, table.concat(r.removedNodes, " "))
	check("8 T: the obtuse side keeps its node at 40.9 m", findPiece(r, "n-40.9", "J") ~= nil, pieceLengths(r))
	check("8 T: the acute side runs to the node beyond the keep-out (native: 156.5 m)", findPiece(r, "J", "n156.5") ~= nil, pieceLengths(r))
end

-- too close: junctions closer than their corners plus 2.5 m
do
	local c = straightChain({ -100, 100 })
	local corner = chain.corner(16, 30)
	local r = chain.relay(c, {
		{ id = "A", position = v(0, 0), corner = corner },
		{ id = "B", position = v(0, 50), corner = corner },
	}, { junctionGap = chain.ROAD_JUNCTION_GAP })
	check("spacing: 50 m between two 30 degree junctions is refused (needs 62.3 m)", #r.problems == 1, table.concat(r.problems, "; "))
end

-- a curved road: a straight meeting an arc at a plain node inside the keep-out. One curve
-- strays more than 5 cm, so it is refitted the native way (arc-like from the junction)
do
	local radius = 150
	local arcEnd = v(radius - radius * math.cos(math.rad(30)), 80 + radius * math.sin(math.rad(30)))
	local k = 4 / 3 * math.tan(math.rad(30) / 4) * radius
	local arc = { p0 = v(0, 80), p1 = arcEnd, t0 = { x = 0, y = 3 * k, z = 0 },
		t1 = { x = 3 * k * math.sin(math.rad(30)), y = 3 * k * math.cos(math.rad(30)), z = 0 } }
	local c = {
		nodes = { { id = "a", position = v(0, -100) }, { id = "b", position = v(0, 80) }, { id = "c", position = arcEnd } },
		edges = { { id = "s", edge = straight(v(0, -100), v(0, 80)) }, { id = "r", edge = arc } },
	}
	local made = 0
	local r = chain.relay(c, { { id = "J", position = v(0, 40), keepBefore = 60, keepAfter = 60 } }, {
		newNode = function()
			made = made + 1
			return "new" .. made
		end,
	})
	check("seam: the node at the seam inside the keep-out goes", set(r.removedNodes)["b"] == true, table.concat(r.removedNodes, " "))
	check("seam: refitted from the junction to a node just outside the keep-out, the arc beyond kept",
		findPiece(r, "J", "new1") ~= nil and findPiece(r, "new1", "c") ~= nil and #r.problems == 0,
		pieceLengths(r) .. " " .. table.concat(r.problems, "; "))
	local p = findPiece(r, "J", "new1")
	check("seam: the node outside the keep-out is 60 m from the junction", p ~= nil and math.abs(geometry.arcLength(p.edge) - 60) < 0.5,
		pieceLengths(r))
end

-- a kink that no single curve can follow: refused, the road is not bent
do
	local c = {
		nodes = { { id = "a", position = v(0, -100) }, { id = "b", position = v(0, 30) }, { id = "c", position = v(40, 120) } },
		edges = { { id = "s1", edge = straight(v(0, -100), v(0, 30)) }, { id = "s2", edge = straight(v(0, 30), v(40, 120)) } },
	}
	local r = chain.relay(c, { { id = "J", position = v(0, 0), keepBefore = 60, keepAfter = 60 } })
	check("kink: refused rather than bending the road", #r.problems == 1, table.concat(r.problems, "; "))
end

-- a node just outside the keep-out, the old curve beyond kept (the kink lies beyond)
do
	local c = {
		nodes = { { id = "a", position = v(0, -100) }, { id = "b", position = v(0, 30) }, { id = "c", position = v(0, 200) },
			{ id = "d", position = v(40, 290) } },
		edges = { { id = "s1", edge = straight(v(0, -100), v(0, 30)) }, { id = "s2", edge = straight(v(0, 30), v(0, 200)) },
			{ id = "s3", edge = straight(v(0, 200), v(40, 290)) } },
	}
	local r = chain.relay(c, { { id = "J", position = v(0, 0), keepBefore = 60, keepAfter = 60 } })
	check("straight beyond: the node inside the keep-out goes, the far one stays", set(r.removedNodes)["b"] and not set(r.removedNodes)["c"],
		table.concat(r.removedNodes, " "))
	check("straight beyond: one edge from the junction to the next node, the kink untouched",
		findPiece(r, "J", "c") ~= nil and not set(r.removedEdges)["s3"], pieceLengths(r))
end

print(failures == 0 and "all passed" or (failures .. " failed"))
if failures > 0 then
	os.exit(1)
end
