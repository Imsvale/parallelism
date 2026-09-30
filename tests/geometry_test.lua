-- Offline tests for ptracks_geometry.lua, run with any Lua 5.3+ interpreter:
--   lua tests/geometry_test.lua
-- The reference numbers come from a parallel branch built by hand in game.

local here = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
package.path = here .. "/../content/gui/parallel_tracks/?.lua;" .. package.path
local geometry = require "ptracks_geometry"

local failures = 0
local function check(name, ok, detail)
	print((ok and "ok   " or "FAIL ") .. name .. (detail and ("  " .. detail) or ""))
	if not ok then
		failures = failures + 1
	end
end

local function v(x, y, z)
	return { x = x, y = y, z = z or 5 }
end

local function near(a, b, tolerance)
	return geometry.horizontalDistance(a, b) < tolerance
end

local function fmt(p)
	return string.format("(%.2f, %.2f)", p.x, p.y)
end

local function straight(p0, p1)
	local t = v(p1.x - p0.x, p1.y - p0.y, p1.z - p0.z)
	return { p0 = p0, p1 = p1, t0 = t, t1 = t }
end

-- base track L before the branch, and the branch drawn off it (both from the game)
local baseL = straight(v(-24.33, -1531.87), v(-31.54, -1367.73))
local branch = {
	{ p0 = v(-26.18, -1489.83), p1 = v(-54.28, -1429.60), t0 = v(-3.03, 69.03, 0), t1 = v(-50.96, 46.67, 0) },
	{ p0 = v(-54.28, -1429.60), p1 = v(-116.75, -1406.88), t0 = v(-50.96, 46.67, 0), t1 = v(-69.03, -3.03, 0) },
}

-- start of the parallel branch, where the game put node 385
local start = geometry.offsetPoint(branch[1].p0, branch[1].t0, 5)
check("offset start next to the branch start", near(start, v(-21.18, -1489.61), 0.1), fmt(start))

-- the parallel branch crosses L where the game put node 676
local q0 = geometry.offsetPoint(branch[1].p0, branch[1].t0, 5)
local q1 = geometry.offsetPoint(branch[1].p1, branch[1].t1, 5)
local t0, t1 = geometry.offsetTangents(branch[1].p0, branch[1].p1, branch[1].t0, branch[1].t1, q0, q1)
local offsetEdge = { p0 = q0, p1 = q1, t0 = t0, t1 = t1 }
local crossings = geometry.intersections(offsetEdge, baseL)
check("one crossing with L", #crossings == 1, tostring(#crossings))
if crossings[1] then
	local x = crossings[1]
	check("crossing where the game put it", near(x.pointA, v(-27.49, -1459.98), 0.3), fmt(x.pointA))
	check("crossing lies on both edges", near(x.pointA, x.pointB, 0.001), fmt(x.pointB))
end

-- the offset curve keeps its distance: sample it against the drawn curve
local worst = 0
for i = 0, 20 do
	local u = i / 20
	local p = geometry.hermite(offsetEdge.p0, offsetEdge.p1, offsetEdge.t0, offsetEdge.t1, u)
	local d = geometry.distanceToEdge(p, branch[1])
	worst = math.max(worst, math.abs(d - 5))
end
check("offset curve stays 5 m away", worst < 0.05, string.format("worst deviation %.3f m", worst))

-- splitting keeps the shape
local pieces = geometry.splitMany(branch[1], { 0.25, 0.6 })
local splitError = 0
for i, piece in ipairs(pieces) do
	local from = ({ 0, 0.25, 0.6 })[i]
	local to = ({ 0.25, 0.6, 1 })[i]
	for k = 0, 10 do
		local s = k / 10
		local a = geometry.hermite(piece.p0, piece.p1, piece.t0, piece.t1, s)
		local b = geometry.hermite(branch[1].p0, branch[1].p1, branch[1].t0, branch[1].t1, from + (to - from) * s)
		splitError = math.max(splitError, geometry.horizontalDistance(a, b))
	end
end
check("splitMany keeps the curve", splitError < 1e-6, string.format("%.2e m", splitError))

-- closestParameter finds the anchor point on a neighbouring track
local baseR = straight(v(-19.34, -1531.65), v(-26.54, -1367.51))
local u, distance = geometry.closestParameter(start, baseR)
check("anchor lies on R", distance < 0.05, string.format("u = %.3f, distance %.3f", u, distance))

-- offsets per side
local function list(t)
	return table.concat(t, ", ")
end
check("offsets right", list(geometry.offsets(3, 3, 5)) == "5, 10", list(geometry.offsets(3, 3, 5)))
check("offsets left", list(geometry.offsets(3, 1, 5)) == "-5, -10", list(geometry.offsets(3, 1, 5)))
check("offsets center odd", list(geometry.offsets(3, 2, 5)) == "5, -5", list(geometry.offsets(3, 2, 5)))
check("offsets center even", list(geometry.offsets(4, 2, 5)) == "5, -5, 10", list(geometry.offsets(4, 2, 5)))

-- Branching off L, the builder removed L's edges 595-572 and 572-570, moved the split
-- node 2 m to 419 and re-added 595-419 and 419-570. The second spans both removed
-- edges and must still count as a leftover, the branch itself must not.
local removed = {
	straight(v(15.64, -1508.64), v(12.60, -1429.91)),
	straight(v(12.60, -1429.91), v(9.55, -1351.18)),
}
local leftoverA = straight(v(15.64, -1508.64), v(12.67, -1431.91))
local leftoverB = straight(v(12.67, -1431.91), v(9.55, -1351.18))
local drawnBranch = { p0 = v(12.67, -1431.91), p1 = v(-24.68, -1350.74), t0 = v(-3.74, 96.63, 0), t1 = v(-65.78, 60.88, 0) }
check("leftover within one removed edge", geometry.liesOnAny(leftoverA, removed, 0.25))
check("leftover spanning two removed edges", geometry.liesOnAny(leftoverB, removed, 0.25))
check("drawn branch is not a leftover", not geometry.liesOnAny(drawnBranch, removed, 0.25))

-- moving a node: merging two pieces of a curve gives back the whole curve, also when
-- one of them is stored the other way round
local curve = branch[1]
local pa, pb = geometry.split(curve, 0.3)
local function maxDeviation(a, b)
	local worstDeviation = 0
	for k = 0, 20 do
		local s = k / 20
		local p = geometry.hermite(a.p0, a.p1, a.t0, a.t1, s)
		worstDeviation = math.max(worstDeviation, geometry.distanceToEdge(p, b))
	end
	return worstDeviation
end
local merged = geometry.merge(pa, pb)
check("merge restores the curve", maxDeviation(merged, curve) < 0.05, string.format("%.3f m", maxDeviation(merged, curve)))
local mergedReversed = geometry.merge(geometry.reverse(geometry.reverse(pa)), pb)
check("reverse twice is a no-op", maxDeviation(mergedReversed, curve) < 0.05)
local twoStraights = geometry.merge(straight(v(0, 0), v(0, 30)), straight(v(0, 30), v(0, 100)))
check("merge of straights is a straight", maxDeviation(twoStraights, straight(v(0, 0), v(0, 100))) < 1e-6)

-- crossing angles
local ns = straight(v(0, -50), v(0, 50))
local ew = straight(v(-50, 0), v(50, 0))
local diagonal = straight(v(-50, -50 * math.tan(math.rad(3))), v(50, 50 * math.tan(math.rad(3))))
check("right angle crossing", math.abs(geometry.crossingAngle(ns, 0.5, ew, 0.5) - 90) < 1e-6)
check("3 degree crossing", math.abs(geometry.crossingAngle(ew, 0.5, diagonal, 0.5) - 3) < 1e-6,
	string.format("%.4f", geometry.crossingAngle(ew, 0.5, diagonal, 0.5)))
check("angle ignores direction", math.abs(geometry.crossingAngle(ns, 0.5, geometry.reverse(ew), 0.5) - 90) < 1e-6)

-- orientChain: a run with one segment stored the other way round
local s1 = { node0 = 1, node1 = 2, edge = straight(v(0, 0), v(0, 50)) }
local s2 = { node0 = 3, node1 = 2, edge = straight(v(0, 100), v(0, 50)) } -- reversed
local s3 = { node0 = 3, node1 = 4, edge = straight(v(0, 100), v(0, 150)) }
local chain, turned = geometry.orientChain({ s1, s2, s3 })
check("orientChain turns the odd one", turned == 1, tostring(turned))
check("orientChain keeps the majority direction", chain[1].node0 == 1 and chain[3].node1 == 4,
	chain[1].node0 .. " .. " .. chain[3].node1)
check("orientChain reverses its geometry", chain[2].edge.p0.y == 50 and chain[2].edge.t0.y > 0)
local backwards, turnedBack = geometry.orientChain({
	{ node0 = 2, node1 = 1, edge = straight(v(0, 50), v(0, 0)) },
	{ node0 = 3, node1 = 2, edge = straight(v(0, 100), v(0, 50)) },
})
check("orientChain leaves a consistent run alone", turnedBack == 0 and backwards[1].node0 == 3, tostring(turnedBack))

local tieFirst = { node0 = 5, node1 = 6, edge = straight(v(0, 50), v(0, 100)) }
local tieSecond = { node0 = 5, node1 = 4, edge = straight(v(0, 50), v(0, 0)) } -- runs the other way
local tie = geometry.orientChain({ tieFirst, tieSecond })
check("orientChain tie: the first segment decides", tie[#tie].node1 == 6 and tie[1].node0 == 4,
	tie[1].node0 .. " .. " .. tie[#tie].node1)

-- mergeDeviation: two halves of one arc merge cleanly, two quarters of a tight spiral
-- (180 degrees at 30 m radius) do not
local q1 = { p0 = v(30, 0), p1 = v(0, 30), t0 = v(0, 47.1, 0), t1 = v(-47.1, 0, 0) }
local q2 = { p0 = v(0, 30), p1 = v(-30, 0), t0 = v(-47.1, 0, 0), t1 = v(0, -47.1, 0) }
local halfA, halfB = geometry.split(q1, 0.5)
check("clean merge strays little", geometry.mergeDeviation(halfA, halfB, geometry.merge(halfA, halfB)) < 0.2)
local spiral = geometry.mergeDeviation(q1, q2, geometry.merge(q1, q2))
check("merging half a tight circle strays", spiral > 0.2, string.format("%.2f m", spiral))

-- checkPlan: a crossing with a bent track is a problem, a straight one is not
local function planEdge(entity, node0, node1, p0, p1, t)
	return { entity = entity, node0 = node0, node1 = node1, edge = { p0 = p0, p1 = p1, t0 = t, t1 = t } }
end
local goodCrossing = {
	planEdge(-1, 1, 9, v(0, -50), v(0, 0), v(0, 50, 0)),
	planEdge(-2, 9, 2, v(0, 0), v(0, 50), v(0, 50, 0)),
	planEdge(-3, 3, 9, v(-50, 0), v(0, 0), v(50, 0, 0)),
	planEdge(-4, 9, 4, v(0, 0), v(50, 0), v(50, 0, 0)),
}
check("straight crossing passes", #geometry.checkPlan(goodCrossing) == 0)
local badCrossing = {
	goodCrossing[1], goodCrossing[2], goodCrossing[3],
	planEdge(-4, 9, 4, v(0, 0), v(50, 10), v(50, 10, 0)),
}
local problems = geometry.checkPlan(badCrossing)
check("bent crossing is a problem", #problems == 1, problems[1])

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
