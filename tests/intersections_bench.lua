-- Benchmark for geometry.intersections on the worst case seen in game: a new track
-- laid back over a bundle of existing tracks, near-parallel, overlapping for its whole
-- length, plus a few real crossings. Run with any Lua 5.3+ interpreter:
--   lua tests/intersections_bench.lua

local here = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
package.path = here .. "/../content/gui/parallel_tracks/?.lua;" .. package.path
local geometry = require "ptracks_geometry"

local function v(x, y) return { x = x, y = y, z = 5 } end

-- a gentle arc of radius r around (cx, cy) from angle a0 to a1 (radians)
local function arc(cx, cy, r, a0, a1)
	local function point(a) return v(cx + r * math.cos(a), cy + r * math.sin(a)) end
	local k = 4 / 3 * math.tan((a1 - a0) / 4) * r * 3 -- hermite tangent length for the arc
	local function tangent(a) return { x = -math.sin(a) * k, y = math.cos(a) * k, z = 0 } end
	return { p0 = point(a0), p1 = point(a1), t0 = tangent(a0), t1 = tangent(a1) }
end

-- new edges: 5 tracks, each 4 edges of an arc of radius 300 m
local new = {}
for t = 1, 5 do
	for i = 0, 3 do
		new[#new + 1] = arc(0, 0, 300 + t * 5, i * 0.3, (i + 1) * 0.3)
	end
end
-- existing: 6 tracks on nearly the same arc (a slightly different centre, so they drift
-- across the new ones at a very flat angle), plus straights crossing everything
local existing = {}
for t = 0, 5 do
	for i = 0, 3 do
		existing[#existing + 1] = arc(3, -2, 300 + t * 5, i * 0.3 - 0.02, (i + 1) * 0.3 - 0.02)
	end
end
for i = 0, 5 do
	local a = 0.2 + i * 0.2
	existing[#existing + 1] = { p0 = v(250 * math.cos(a), 250 * math.sin(a)), p1 = v(380 * math.cos(a), 380 * math.sin(a)),
		t0 = { x = 130 * math.cos(a), y = 130 * math.sin(a), z = 0 }, t1 = { x = 130 * math.cos(a), y = 130 * math.sin(a), z = 0 } }
end

local function run()
	local found = 0
	for _, a in ipairs(new) do
		for _, b in ipairs(existing) do
			found = found + #geometry.intersections(a, b)
		end
	end
	return found
end

-- reference: brute force on 256 samples per edge, to see what the fast search misses
local function reference(a, b)
	local n = 256
	local pts = function(e)
		local t = {}
		for i = 0, n do
			t[i] = geometry.hermite(e.p0, e.p1, e.t0, e.t1, i / n)
		end
		return t
	end
	local pa, pb = pts(a), pts(b)
	local found = {}
	for i = 0, n - 1 do
		for j = 0, n - 1 do
			local p0, p1, q0, q1 = pa[i], pa[i + 1], pb[j], pb[j + 1]
			local rx, ry, sx, sy = p1.x - p0.x, p1.y - p0.y, q1.x - q0.x, q1.y - q0.y
			local d = rx * sy - ry * sx
			if math.abs(d) > 1e-12 then
				local qx, qy = q0.x - p0.x, q0.y - p0.y
				local s, t = (qx * sy - qy * sx) / d, (qx * ry - qy * rx) / d
				if s >= 0 and s <= 1 and t >= 0 and t <= 1 then
					found[#found + 1] = { x = p0.x + s * rx, y = p0.y + s * ry, ua = (i + s) / n }
				end
			end
		end
	end
	return found
end

local missed = 0
for ia, a in ipairs(new) do
	for ib, b in ipairs(existing) do
		local fast = geometry.intersections(a, b)
		for _, r in ipairs(reference(a, b)) do
			local hit = false
			for _, f in ipairs(fast) do
				if math.abs(f.pointA.x - r.x) < 0.5 and math.abs(f.pointA.y - r.y) < 0.5 then
					hit = true
				end
			end
			if not hit then
				missed = missed + 1
				print(string.format("missed: new %d x existing %d at (%.2f, %.2f), u = %.3f, angle %.2f deg",
					ia, ib, r.x, r.y, r.ua, geometry.crossingAngle(a, r.ua, b, 0.5)))
			end
		end
	end
end
print("missed against the reference: " .. missed)

local rounds = 5
local t0 = os.clock()
local found
for _ = 1, rounds do
	found = run()
end
local ms = (os.clock() - t0) * 1000 / rounds
print(string.format("%d new x %d existing edges: %d crossings found, %.1f ms per plan", #new, #existing, found, ms))
