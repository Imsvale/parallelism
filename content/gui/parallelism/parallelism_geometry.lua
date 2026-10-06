-- Pure geometry on plain tables {x, y, z}, no game api.
-- Edges are cubic hermite curves: end points p0 / p1 and tangents t0 / t1, where the
-- tangents are scaled to the edge (a straight edge has t0 = t1 = p1 - p0).

local geometry = {}

local function length2d(x, y)
	return math.sqrt(x * x + y * y)
end

function geometry.copy(v)
	return { x = v.x, y = v.y, z = v.z }
end

-- unit vector pointing to the right of the horizontal direction of t
function geometry.right(t)
	local len = length2d(t.x, t.y)
	if len < 1e-6 then
		return nil
	end
	return { x = t.y / len, y = -t.x / len, z = 0 }
end

-- The edge from p0 to p1 leaving p0 in direction d0 and arriving at p1 in direction d1,
-- shaped like a circular arc: both tangents 4 R tan(theta / 4) long, theta the turn
-- from d0 to d1 and R = chord / (2 sin(theta / 2)), which is chord for a straight. The
-- native builder refits existing track this way when it removes a node next to a
-- crossing (measured 2026-10-02, within 0.1 %). Directions keep their slope.
function geometry.arcCubic(p0, d0, p1, d1)
	local chord = length2d(p1.x - p0.x, p1.y - p0.y)
	local l0, l1 = length2d(d0.x, d0.y), length2d(d1.x, d1.y)
	local cos = (d0.x * d1.x + d0.y * d1.y) / (l0 * l1)
	local theta = math.acos(math.max(-1, math.min(1, cos)))
	local factor = 1
	if theta > 1e-6 then
		factor = 2 * math.tan(theta / 4) / math.sin(theta / 2)
	end
	local len = chord * factor
	return {
		p0 = geometry.copy(p0),
		p1 = geometry.copy(p1),
		t0 = { x = d0.x / l0 * len, y = d0.y / l0 * len, z = d0.z / l0 * len },
		t1 = { x = d1.x / l1 * len, y = d1.y / l1 * len, z = d1.z / l1 * len },
	}
end

function geometry.offsetPoint(p, t, offset)
	local r = geometry.right(t)
	if r == nil then
		return nil
	end
	return { x = p.x + r.x * offset, y = p.y + r.y * offset, z = p.z }
end

-- Where the horizontal lines p + t * a and q + s * b meet: t, s; nil if parallel.
function geometry.lineIntersection(p, a, q, b)
	local cross = a.x * b.y - a.y * b.x
	local la, lb = length2d(a.x, a.y), length2d(b.x, b.y)
	if la < 1e-9 or lb < 1e-9 or math.abs(cross) < 1e-9 * la * lb then
		return nil
	end
	local dx, dy = q.x - p.x, q.y - p.y
	return (dx * b.y - dy * b.x) / cross, (dx * a.y - dy * a.x) / cross
end

-- Angle in degrees between the horizontal directions a and b (0 = same way).
function geometry.angleBetween(a, b)
	local la, lb = length2d(a.x, a.y), length2d(b.x, b.y)
	if la < 1e-9 or lb < 1e-9 then
		return 0
	end
	local c = (a.x * b.x + a.y * b.y) / (la * lb)
	return math.deg(math.acos(math.max(-1, math.min(1, c))))
end

-- The corner of the offset of a path that kinks at p: the old direction a arrives,
-- the new direction b leaves. Returns the corner, and how far it lies along a from the
-- old offset point and along b from the new one (negative: behind it, the inside of
-- the bend). nil for no kink or a reversal.
function geometry.miter(p, a, b, offset)
	local pa = geometry.offsetPoint(p, a, offset)
	local pb = geometry.offsetPoint(p, b, offset)
	if pa == nil or pb == nil then
		return nil
	end
	local t, s = geometry.lineIntersection(pa, a, pb, b)
	if t == nil then
		return nil
	end
	local la, lb = length2d(a.x, a.y), length2d(b.x, b.y)
	local corner = { x = pa.x + a.x * t, y = pa.y + a.y * t, z = p.z }
	return corner, t * la, s * lb
end

-- Tangents of the edge between the offset end points q0 / q1. Scaling the horizontal
-- part by the chord ratio is exact for straights and circular arcs. The vertical part
-- is kept, so the offset edge has the same height profile.
function geometry.offsetTangents(p0, p1, t0, t1, q0, q1)
	local chord = length2d(p1.x - p0.x, p1.y - p0.y)
	local newChord = length2d(q1.x - q0.x, q1.y - q0.y)
	local scale = chord > 1e-6 and newChord / chord or 1
	return { x = t0.x * scale, y = t0.y * scale, z = t0.z },
		{ x = t1.x * scale, y = t1.y * scale, z = t1.z }
end

-- Radius of the edge taken as a circular arc, from its chord and the angle between
-- its end tangents. math.huge for a straight edge.
function geometry.radius(p0, p1, t0, t1)
	local len0 = length2d(t0.x, t0.y)
	local len1 = length2d(t1.x, t1.y)
	if len0 < 1e-6 or len1 < 1e-6 then
		return math.huge
	end
	local cos = (t0.x * t1.x + t0.y * t1.y) / (len0 * len1)
	local angle = math.acos(math.max(-1, math.min(1, cos)))
	local sin = math.sin(angle / 2)
	if sin < 1e-6 then
		return math.huge
	end
	return length2d(p1.x - p0.x, p1.y - p0.y) / (2 * sin)
end

function geometry.hermite(p0, p1, t0, t1, u)
	local u2 = u * u
	local u3 = u2 * u
	local h00 = 2 * u3 - 3 * u2 + 1
	local h10 = u3 - 2 * u2 + u
	local h01 = -2 * u3 + 3 * u2
	local h11 = u3 - u2
	return {
		x = h00 * p0.x + h10 * t0.x + h01 * p1.x + h11 * t1.x,
		y = h00 * p0.y + h10 * t0.y + h01 * p1.y + h11 * t1.y,
		z = h00 * p0.z + h10 * t0.z + h01 * p1.z + h11 * t1.z,
	}
end

-- derivative of the hermite curve with respect to u
function geometry.hermiteDerivative(p0, p1, t0, t1, u)
	local u2 = u * u
	local d00 = 6 * u2 - 6 * u
	local d10 = 3 * u2 - 4 * u + 1
	local d01 = -6 * u2 + 6 * u
	local d11 = 3 * u2 - 2 * u
	return {
		x = d00 * p0.x + d10 * t0.x + d01 * p1.x + d11 * t1.x,
		y = d00 * p0.y + d10 * t0.y + d01 * p1.y + d11 * t1.y,
		z = d00 * p0.z + d10 * t0.z + d01 * p1.z + d11 * t1.z,
	}
end

local function hermiteSecondDerivative(p0, p1, t0, t1, u)
	local d00 = 12 * u - 6
	local d10 = 6 * u - 4
	local d01 = -12 * u + 6
	local d11 = 6 * u - 2
	return {
		x = d00 * p0.x + d10 * t0.x + d01 * p1.x + d11 * t1.x,
		y = d00 * p0.y + d10 * t0.y + d01 * p1.y + d11 * t1.y,
	}
end

-- The tightest horizontal radius anywhere along the edge, sampled. geometry.radius
-- takes the edge for a circular arc from its ends; a merged curve can bend much
-- tighter in between (seen in game: "Too Much Curvature" with 124 m by the ends).
function geometry.minRadiusAlong(edge, samples)
	-- about one per meter, a short sharp bend in a long edge falls between 16 samples
	samples = samples or math.max(16, math.min(200, math.floor(length2d(edge.p1.x - edge.p0.x, edge.p1.y - edge.p0.y))))
	local best = math.huge
	for i = 0, samples do
		local u = i / samples
		local d1 = geometry.hermiteDerivative(edge.p0, edge.p1, edge.t0, edge.t1, u)
		local d2 = hermiteSecondDerivative(edge.p0, edge.p1, edge.t0, edge.t1, u)
		local speed = length2d(d1.x, d1.y)
		local cross = math.abs(d1.x * d2.y - d1.y * d2.x)
		if speed > 1e-9 and cross > 1e-12 then
			best = math.min(best, speed * speed * speed / cross)
		end
	end
	return best
end

local function horizontalDistance(a, b)
	return length2d(a.x - b.x, a.y - b.y)
end

-- parameter u of the point on the edge closest to p (horizontally), and that distance
function geometry.closestParameter(p, edge)
	local n = 64
	local bestU, bestD = 0, math.huge
	for i = 0, n do
		local u = i / n
		local d = horizontalDistance(p, geometry.hermite(edge.p0, edge.p1, edge.t0, edge.t1, u))
		if d < bestD then
			bestU, bestD = u, d
		end
	end
	-- ternary search around the best sample
	local lo = math.max(0, bestU - 1 / n)
	local hi = math.min(1, bestU + 1 / n)
	for __ = 1, 40 do
		local a = lo + (hi - lo) / 3
		local b = hi - (hi - lo) / 3
		local da = horizontalDistance(p, geometry.hermite(edge.p0, edge.p1, edge.t0, edge.t1, a))
		local db = horizontalDistance(p, geometry.hermite(edge.p0, edge.p1, edge.t0, edge.t1, b))
		if da < db then
			hi = b
		else
			lo = a
		end
	end
	local u = (lo + hi) / 2
	return u, horizontalDistance(p, geometry.hermite(edge.p0, edge.p1, edge.t0, edge.t1, u))
end

-- Splits the edge at u into two edges with the same shape, and returns them plus the
-- split point. The tangents of each piece are scaled to that piece.
function geometry.split(edge, u)
	local m = geometry.hermite(edge.p0, edge.p1, edge.t0, edge.t1, u)
	local tm = geometry.hermiteDerivative(edge.p0, edge.p1, edge.t0, edge.t1, u)
	local function scaled(v, s)
		return { x = v.x * s, y = v.y * s, z = v.z * s }
	end
	local a = { p0 = geometry.copy(edge.p0), p1 = m, t0 = scaled(edge.t0, u), t1 = scaled(tm, u) }
	local b = { p0 = geometry.copy(m), p1 = geometry.copy(edge.p1), t0 = scaled(tm, 1 - u), t1 = scaled(edge.t1, 1 - u) }
	return a, b, m
end

-- Splits the edge at several parameters, sorted ascending and inside (0, 1).
-- Returns the pieces in order.
function geometry.splitMany(edge, us)
	local pieces = {}
	local rest = edge
	local done = 0
	for __, u in ipairs(us) do
		local a, b = geometry.split(rest, (u - done) / (1 - done))
		pieces[#pieces + 1] = a
		rest = b
		done = u
	end
	pieces[#pieces + 1] = rest
	return pieces
end

-- the same curve run the other way
function geometry.reverse(edge)
	return {
		p0 = geometry.copy(edge.p1),
		p1 = geometry.copy(edge.p0),
		t0 = { x = -edge.t1.x, y = -edge.t1.y, z = -edge.t1.z },
		t1 = { x = -edge.t0.x, y = -edge.t0.y, z = -edge.t0.z },
	}
end

-- horizontal length along the curve, by sampling
function geometry.arcLength(edge)
	local n = 32
	local total = 0
	local prev = edge.p0
	for i = 1, n do
		local cur = geometry.hermite(edge.p0, edge.p1, edge.t0, edge.t1, i / n)
		total = total + horizontalDistance(prev, cur)
		prev = cur
	end
	return total
end

-- One edge replacing a followed by b (a.p1 = b.p0). Exact when both are pieces of one
-- curve split at a point (straights, arcs), since a piece's tangents are those of the
-- whole curve scaled by the piece's share of it.
-- The parameter u at which the edge is length long (from its start), by sampling the
-- arc length and interpolating; 0 or 1 beyond the ends.
function geometry.parameterAtLength(edge, length)
	if length <= 0 then
		return 0
	end
	local n = 64
	local total = 0
	local prev = geometry.hermite(edge.p0, edge.p1, edge.t0, edge.t1, 0)
	for i = 1, n do
		local u = i / n
		local p = geometry.hermite(edge.p0, edge.p1, edge.t0, edge.t1, u)
		local step = horizontalDistance(prev, p)
		if total + step >= length then
			return (i - 1 + (length - total) / math.max(step, 1e-12)) / n
		end
		total = total + step
		prev = p
	end
	return 1
end

-- One edge for a followed by b: the outer end points and end directions are kept. The
-- tangent lengths are first taken from the arc length ratio (exact for two pieces cut
-- from one curve), then fitted to points sampled along a and b, which matters when a
-- short bit is joined to a long edge (the ratio alone strayed 5 cm for a 0.44 m bit on
-- a 54 m edge, where the track barely changes).
function geometry.merge(a, b)
	local la = geometry.arcLength(a)
	local lb = geometry.arcLength(b)
	local fa = la / (la + lb)
	local fb = lb / (la + lb)
	local ratio = {
		p0 = geometry.copy(a.p0),
		p1 = geometry.copy(b.p1),
		t0 = { x = a.t0.x / fa, y = a.t0.y / fa, z = a.t0.z / fa },
		t1 = { x = b.t1.x / fb, y = b.t1.y / fb, z = b.t1.z / fb },
	}
	-- least squares for the two tangent lengths, samples placed by arc length share
	local q0, q1, d0, d1 = ratio.p0, ratio.p1, ratio.t0, ratio.t1
	local a11, a12, a22, b1, b2 = 0, 0, 0, 0, 0
	local n = 12
	for _, side in ipairs({ { a, 0, fa }, { b, fa, fb } }) do
		local edge, start, share = side[1], side[2], side[3]
		for i = 1, n do
			local s = (i - 0.5) / n
			local target = geometry.hermite(edge.p0, edge.p1, edge.t0, edge.t1, s)
			local u = start + share * s
			local u2, u3 = u * u, u * u * u
			local h00 = 2 * u3 - 3 * u2 + 1
			local h01 = -2 * u3 + 3 * u2
			local h10 = u3 - 2 * u2 + u
			local h11 = u3 - u2
			local rx = target.x - (h00 * q0.x + h01 * q1.x)
			local ry = target.y - (h00 * q0.y + h01 * q1.y)
			a11 = a11 + h10 * h10 * (d0.x * d0.x + d0.y * d0.y)
			a12 = a12 + h10 * h11 * (d0.x * d1.x + d0.y * d1.y)
			a22 = a22 + h11 * h11 * (d1.x * d1.x + d1.y * d1.y)
			b1 = b1 + h10 * (rx * d0.x + ry * d0.y)
			b2 = b2 + h11 * (rx * d1.x + ry * d1.y)
		end
	end
	local det = a11 * a22 - a12 * a12
	if math.abs(det) < 1e-12 then
		return ratio
	end
	local s0 = (b1 * a22 - b2 * a12) / det
	local s1 = (a11 * b2 - a12 * b1) / det
	if not (s0 > 0 and s1 > 0) then
		return ratio
	end
	local fitted = {
		p0 = ratio.p0,
		p1 = ratio.p1,
		t0 = { x = d0.x * s0, y = d0.y * s0, z = d0.z * s0 },
		t1 = { x = d1.x * s1, y = d1.y * s1, z = d1.z * s1 },
	}
	if geometry.mergeDeviation(a, b, fitted) < geometry.mergeDeviation(a, b, ratio) then
		return fitted
	end
	return ratio
end

local function evalEdge(e, u)
	return geometry.hermite(e.p0, e.p1, e.t0, e.t1, u)
end

local function derivEdge(e, u)
	return geometry.hermiteDerivative(e.p0, e.p1, e.t0, e.t1, u)
end

local function polyline(e, n)
	local points = {}
	local box = { minX = math.huge, minY = math.huge, maxX = -math.huge, maxY = -math.huge }
	for i = 0, n do
		local p = evalEdge(e, i / n)
		points[i] = p
		box.minX = math.min(box.minX, p.x)
		box.minY = math.min(box.minY, p.y)
		box.maxX = math.max(box.maxX, p.x)
		box.maxY = math.max(box.maxY, p.y)
	end
	return points, box
end

local function boxesOverlap(a, b)
	return a.minX <= b.maxX and b.minX <= a.maxX and a.minY <= b.maxY and b.minY <= a.maxY
end

-- parameters s, t in [0, 1] where segments p0-p1 and q0-q1 cross, or nil
local function segmentIntersection(p0, p1, q0, q1)
	local rx, ry = p1.x - p0.x, p1.y - p0.y
	local sx, sy = q1.x - q0.x, q1.y - q0.y
	local d = rx * sy - ry * sx
	if math.abs(d) < 1e-12 then
		return nil
	end
	local qx, qy = q0.x - p0.x, q0.y - p0.y
	local s = (qx * sy - qy * sx) / d
	local t = (qx * ry - qy * rx) / d
	if s < 0 or s > 1 or t < 0 or t > 1 then
		return nil
	end
	return s, t
end

-- Newton iterations on a(ua) = b(ub) in the horizontal plane
local function refine(a, b, ua, ub)
	for __ = 1, 8 do
		local pa = evalEdge(a, ua)
		local pb = evalEdge(b, ub)
		local fx, fy = pa.x - pb.x, pa.y - pb.y
		if fx * fx + fy * fy < 1e-10 then
			break
		end
		local da = derivEdge(a, ua)
		local db = derivEdge(b, ub)
		-- [da.x -db.x; da.y -db.y] * [dua; dub] = [-fx; -fy]
		local det = da.x * (-db.y) - (-db.x) * da.y
		if math.abs(det) < 1e-9 then
			break
		end
		ua = ua + (-fx * (-db.y) - (-db.x) * (-fy)) / det
		ub = ub + (da.x * (-fy) - (-fx) * da.y) / det
	end
	if ua < 0 or ua > 1 or ub < 0 or ub > 1 then
		return nil
	end
	return ua, ub
end

-- Sample points for finding crossings: a straight edge needs few, a curve about one per
-- 4 degrees of turn. The crossing found on them is refined on the curves afterwards.
local function samplesFor(e)
	local l0 = length2d(e.t0.x, e.t0.y)
	local l1 = length2d(e.t1.x, e.t1.y)
	local turn = 0
	if l0 > 1e-9 and l1 > 1e-9 then
		local c = (e.t0.x * e.t1.x + e.t0.y * e.t1.y) / (l0 * l1)
		turn = math.deg(math.acos(math.max(-1, math.min(1, c))))
	end
	return math.max(4, math.min(32, math.ceil(turn / 4)))
end

-- the sampled polyline of an edge, kept while the edge table lives: an edge is tested
-- against many others
local polylineCache = setmetatable({}, { __mode = "k" })

-- speed-ups in the crossing search (adaptive sampling, cache); set by the planner
geometry.fastIntersections = true

local function sampled(e)
	if not geometry.fastIntersections then
		local points, box = polyline(e, 32)
		return { n = 32, points = points, box = box }
	end
	local cached = polylineCache[e]
	if cached == nil then
		local n = samplesFor(e)
		local points, box = polyline(e, n)
		cached = { n = n, points = points, box = box }
		polylineCache[e] = cached
	end
	return cached
end

-- Horizontal crossings of two edges: list of { ua, ub, pointA, pointB }.
function geometry.intersections(a, b)
	local sa, sb = sampled(a), sampled(b)
	local result = {}
	if not boxesOverlap(sa.box, sb.box) then
		return result
	end
	local pa, pb, na, nb = sa.points, sb.points, sa.n, sb.n
	for i = 0, na - 1 do
		local a0, a1 = pa[i], pa[i + 1]
		local aMinX, aMaxX = math.min(a0.x, a1.x), math.max(a0.x, a1.x)
		local aMinY, aMaxY = math.min(a0.y, a1.y), math.max(a0.y, a1.y)
		for j = 0, nb - 1 do
			local b0, b1 = pb[j], pb[j + 1]
			-- cheap box test before the exact one
			local s, t = nil, nil
			if (b0.x >= aMinX or b1.x >= aMinX) and (b0.x <= aMaxX or b1.x <= aMaxX)
				and (b0.y >= aMinY or b1.y >= aMinY) and (b0.y <= aMaxY or b1.y <= aMaxY) then
				s, t = segmentIntersection(a0, a1, b0, b1)
			end
			if s then
				local ua, ub = refine(a, b, (i + s) / na, (j + t) / nb)
				if ua then
					local point = evalEdge(a, ua)
					local duplicate = false
					for __, r in ipairs(result) do
						if horizontalDistance(r.pointA, point) < 0.5 then
							duplicate = true
							break
						end
					end
					if not duplicate then
						result[#result + 1] = { ua = ua, ub = ub, pointA = point, pointB = evalEdge(b, ub) }
					end
				end
			end
		end
	end
	return result
end

-- Angle in degrees (0 to 90) between two edges where they cross, at their parameters.
function geometry.crossingAngle(a, ua, b, ub)
	local da = derivEdge(a, ua)
	local db = derivEdge(b, ub)
	local la = length2d(da.x, da.y)
	local lb = length2d(db.x, db.y)
	if la < 1e-9 or lb < 1e-9 then
		return 0
	end
	local c = math.abs(da.x * db.x + da.y * db.y) / (la * lb)
	return math.deg(math.acos(math.min(1, c)))
end

function geometry.horizontalDistance(a, b)
	return horizontalDistance(a, b)
end

local SAMPLES = 32

-- horizontal distance of point p to the edge, by sampling
function geometry.distanceToEdge(p, edge)
	local best = math.huge
	local prev = edge.p0
	for i = 1, SAMPLES do
		local cur = geometry.hermite(edge.p0, edge.p1, edge.t0, edge.t1, i / SAMPLES)
		local dx, dy = cur.x - prev.x, cur.y - prev.y
		local len2 = dx * dx + dy * dy
		local s = 0
		if len2 > 1e-12 then
			s = ((p.x - prev.x) * dx + (p.y - prev.y) * dy) / len2
			s = math.max(0, math.min(1, s))
		end
		local d = length2d(p.x - (prev.x + s * dx), p.y - (prev.y + s * dy))
		if d < best then
			best = d
		end
		prev = cur
	end
	return best
end

-- true if the edge runs along the other edge for its whole length
function geometry.liesOn(edge, other, tolerance)
	local mid = geometry.hermite(edge.p0, edge.p1, edge.t0, edge.t1, 0.5)
	return geometry.distanceToEdge(edge.p0, other) < tolerance
		and geometry.distanceToEdge(edge.p1, other) < tolerance
		and geometry.distanceToEdge(mid, other) < tolerance
end

-- True if the edge runs along the others for its whole length, where it may span
-- several of them (the builder sometimes moves a node when it splits a track).
function geometry.liesOnAny(edge, others, tolerance)
	for i = 0, 8 do
		local p = geometry.hermite(edge.p0, edge.p1, edge.t0, edge.t1, i / 8)
		local onSome = false
		for __, other in ipairs(others) do
			if geometry.distanceToEdge(p, other) < tolerance then
				onSome = true
				break
			end
		end
		if not onSome then
			return false
		end
	end
	return true
end

-- How far the merged curve strays from the two pieces it replaces (see straysFrom).
function geometry.mergeDeviation(a, b, merged)
	if a == b then
		return geometry.straysFrom(merged, { a })
	end
	return geometry.straysFrom(merged, { a, b })
end

-- How far a curve strays from the pieces it replaces (any number of them, in order along
-- it): the curve sampled once, each piece checked against it. The nearest segment of the
-- curve moves along with the piece, so the search goes on from the last one found within a
-- window instead of over the whole curve (the pieces follow the curve closely: that is
-- what is being checked; a sample further off than the window is measured fully).
function geometry.straysFrom(curve, pieces)
	local n = math.max(32, math.min(400, math.ceil(horizontalDistance(curve.p0, curve.p1) / 0.5)))
	local line = {}
	for i = 0, n do
		line[i] = geometry.hermite(curve.p0, curve.p1, curve.t0, curve.t1, i / n)
	end
	local function toSegment(p, j)
		local q0, q1 = line[j], line[j + 1]
		local dx, dy = q1.x - q0.x, q1.y - q0.y
		local len2 = dx * dx + dy * dy
		local s = 0
		if len2 > 1e-12 then
			s = math.max(0, math.min(1, ((p.x - q0.x) * dx + (p.y - q0.y) * dy) / len2))
		end
		return length2d(p.x - (q0.x + s * dx), p.y - (q0.y + s * dy))
	end
	local segment = math.max(horizontalDistance(curve.p0, curve.p1) / n, 1e-6)
	local at = 0
	local worst = 0
	for _, piece in ipairs(pieces) do
		-- as far as the nearest point moves between two samples of this piece, and some
		local window = math.ceil(horizontalDistance(piece.p0, piece.p1) / 6 / segment * 1.5) + 4
		for i = 0, 6 do
			local p = geometry.hermite(piece.p0, piece.p1, piece.t0, piece.t1, i / 6)
			local best, bestJ = math.huge, at
			for j = math.max(0, at - 2), math.min(n - 1, at + window) do
				local d = toSegment(p, j)
				if d < best then
					best, bestJ = d, j
				end
			end
			if best > 0.5 then
				-- off the window's reach: the whole curve
				for j = 0, n - 1 do
					local d = toSegment(p, j)
					if d < best then
						best, bestJ = d, j
					end
				end
			end
			at = bestJ
			worst = math.max(worst, best)
		end
	end
	return worst
end

local angleBetween = geometry.angleBetween

-- Puts segments { node0, node1, edge } of a run in order along it, all running the same
-- way: the way most of them already run. Returns the new list and how many had to be
-- turned around. A run that is not a simple chain is returned as it is.
function geometry.orientChain(segments)
	local byNode = {}
	for i, s in ipairs(segments) do
		byNode[s.node0] = byNode[s.node0] or {}
		byNode[s.node1] = byNode[s.node1] or {}
		table.insert(byNode[s.node0], i)
		table.insert(byNode[s.node1], i)
	end
	local start = nil
	for node, list in pairs(byNode) do
		if #list > 2 then
			return segments, 0
		end
		if #list == 1 and (start == nil or node < start) then
			start = node
		end
	end
	if start == nil then
		-- a closed loop: begin with the first segment as it runs
		start = segments[1].node0
	end

	local function walk(from)
		local result, turned, used = {}, 0, {}
		local node = from
		while true do
			local nextIndex = nil
			for _, i in ipairs(byNode[node]) do
				if not used[i] then
					nextIndex = i
					break
				end
			end
			if nextIndex == nil then
				break
			end
			used[nextIndex] = true
			local s = segments[nextIndex]
			if s.node0 == node then
				result[#result + 1] = s
				node = s.node1
			else
				result[#result + 1] = { node0 = s.node1, node1 = s.node0, edge = geometry.reverse(s.edge), source = s }
				turned = turned + 1
				node = s.node0
			end
		end
		return result, turned
	end

	local result, turned = walk(start)
	if #result ~= #segments then
		return segments, 0
	end
	-- on a tie the first segment as handed over decides
	local firstTurned = false
	for _, r in ipairs(result) do
		if r.source == segments[1] then
			firstTurned = true
		end
	end
	if turned * 2 > #segments or (turned * 2 == #segments and firstTurned) then
		-- most ran the other way: walk from the other end
		local other = result[#result].node1
		result, turned = walk(other)
	end
	return result, turned
end

-- Problems in a plan of edges { entity, node0, node1, edge } the game would refuse or
-- crash on: a track bending at a node it runs through (crossings are two tracks
-- running straight through, other nodes with two edges one), or a very short edge.
-- corners: nodes (set) where two edges meet at an angle on purpose, e.g. the corner of
-- a road parallel to a road that kinks there.
function geometry.checkPlan(plan, tolerance, corners)
	tolerance = tolerance or 1.0
	local problems = {}
	-- where they are: positions of the nodes and short edges named
	local points = {}
	local byNode = {}
	local positionOf = {}
	for _, e in ipairs(plan) do
		if horizontalDistance(e.edge.p0, e.edge.p1) < 0.5 then
			problems[#problems + 1] = string.format("edge %d is only %.2f m long", e.entity, horizontalDistance(e.edge.p0, e.edge.p1))
			points[#points + 1] = e.edge.p0
		end
		positionOf[e.node0] = e.edge.p0
		positionOf[e.node1] = e.edge.p1
		byNode[e.node0] = byNode[e.node0] or {}
		byNode[e.node1] = byNode[e.node1] or {}
		-- directions leaving the node
		table.insert(byNode[e.node0], e.edge.t0)
		table.insert(byNode[e.node1], { x = -e.edge.t1.x, y = -e.edge.t1.y, z = -e.edge.t1.z })
	end
	for node, dirs in pairs(byNode) do
		if #dirs == 2 and not (corners and corners[node]) then
			local bend = 180 - angleBetween(dirs[1], dirs[2])
			if bend > tolerance then
				problems[#problems + 1] = string.format("track bends %.1f deg at node %d", bend, node)
				points[#points + 1] = positionOf[node]
			end
		elseif #dirs == 4 then
			local best = math.huge
			for _, p in ipairs({ { 1, 2, 3, 4 }, { 1, 3, 2, 4 }, { 1, 4, 2, 3 } }) do
				best = math.min(best, math.max(180 - angleBetween(dirs[p[1]], dirs[p[2]]), 180 - angleBetween(dirs[p[3]], dirs[p[4]])))
			end
			if best > tolerance then
				problems[#problems + 1] = string.format("a track bends %.1f deg through the crossing at node %d", best, node)
				points[#points + 1] = positionOf[node]
			end
		end
	end
	return problems, points
end

-- Signed offsets (positive = right of build direction) of the additional tracks.
-- side: 1 = left, 2 = center-left, 3 = center-right, 4 = right. With a center side the
-- drawn track stays in the middle; for an even count the odd one out goes to the left
-- (center-left) or the right (center-right).
function geometry.offsets(count, side, distance)
	local result = {}
	if side == 2 or side == 3 then
		local right = side == 3 and math.floor(count / 2) or count - 1 - math.floor(count / 2)
		local left = count - 1 - right
		for i = 1, right do
			result[#result + 1] = i * distance
		end
		for i = 1, left do
			result[#result + 1] = -i * distance
		end
		-- nearest first, each track may anchor on the one before it
		table.sort(result, function(a, b)
			if math.abs(a) ~= math.abs(b) then
				return math.abs(a) < math.abs(b)
			end
			return a > b
		end)
	else
		local sign = side == 1 and -1 or 1
		for i = 1, count - 1 do
			result[#result + 1] = sign * i * distance
		end
	end
	return result
end

return geometry
