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

function geometry.offsetPoint(p, t, offset)
	local r = geometry.right(t)
	if r == nil then
		return nil
	end
	return { x = p.x + r.x * offset, y = p.y + r.y * offset, z = p.z }
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
function geometry.merge(a, b)
	local la = geometry.arcLength(a)
	local lb = geometry.arcLength(b)
	local fa = la / (la + lb)
	local fb = lb / (la + lb)
	return {
		p0 = geometry.copy(a.p0),
		p1 = geometry.copy(b.p1),
		t0 = { x = a.t0.x / fa, y = a.t0.y / fa, z = a.t0.z / fa },
		t1 = { x = b.t1.x / fb, y = b.t1.y / fb, z = b.t1.z / fb },
	}
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

-- Horizontal crossings of two edges: list of { ua, ub, pointA, pointB }.
function geometry.intersections(a, b)
	local n = 32
	local pa, boxA = polyline(a, n)
	local pb, boxB = polyline(b, n)
	local result = {}
	if not boxesOverlap(boxA, boxB) then
		return result
	end
	for i = 0, n - 1 do
		local a0, a1 = pa[i], pa[i + 1]
		for j = 0, n - 1 do
			local s, t = segmentIntersection(a0, a1, pb[j], pb[j + 1])
			if s then
				local ua, ub = refine(a, b, (i + s) / n, (j + t) / n)
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

-- Signed offsets (positive = right of build direction) of the additional tracks.
-- side: 1 = left, 2 = center, 3 = right. With center the drawn track stays in the
-- middle; for an even count the odd one out goes to the right.
function geometry.offsets(count, side, distance)
	local result = {}
	if side == 2 then
		local right = math.floor(count / 2)
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
