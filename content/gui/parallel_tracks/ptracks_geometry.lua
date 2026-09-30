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
	else
		local sign = side == 1 and -1 or 1
		for i = 1, count - 1 do
			result[#result + 1] = sign * i * distance
		end
	end
	return result
end

return geometry
