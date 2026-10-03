-- Re-laying a road or track around the junctions a plan puts on it
-- (docs/design/2026-10-03_node-placement.md). Plain geometry, no game API: offline tests
-- in tests/chain_test.lua.
--
-- A chain is one road or track followed through its plain nodes:
--   nodes: { { id, position, fixed } ... } (n + 1 of them, in order along the chain)
--   edges: { { id, edge = { p0, p1, t0, t1 }, reversed } ... } (n of them); edge i joins
--          node i and node i + 1 and runs along the chain (reversed: the edge in the world
--          runs the other way)
-- A fixed node stays (a junction already there, the end of the chain, a node another plan
-- part needs). Every other node is plain: free to go.
--
-- Junctions are the new ones the plan puts on the chain (crossings, T anchors) and
-- existing nodes that need room (the drawn road's junction):
--   { id, position, edge (index, optional), node (index, for an existing chain node),
--     keepBefore, keepAfter, corner }
-- keepBefore / keepAfter: the stretch before / after it along the chain that must hold no
-- plain node. corner: how far its corner reaches along the chain, for the spacing check
-- between neighbouring junctions (optional).
-- (the game loads the mod's modules by file name, plain Lua by module name: the tests)
local found, geometry = pcall(require, "parallelism_geometry.lua")
if not found then
	geometry = require "parallelism_geometry"
end

local chain = {}

-- road rules (native, see the design note)
chain.ROAD_BEYOND = 26.0
chain.ROAD_JUNCTION_GAP = 2.5

-- How far along a road (width w) the corner of a junction at angle a (degrees) reaches:
-- where the two road surfaces stop overlapping.
function chain.corner(width, angle)
	local a = math.rad(math.max(math.min(angle, 90), 1))
	local half = width / 2
	return half / math.sin(a) + half / math.tan(a)
end

-- The stretch next to a road junction that must hold no plain node.
function chain.roadKeepOut(width, angle)
	return chain.corner(width, angle) + chain.ROAD_BEYOND
end

local EPS = 0.01

-- the part of edge e between lengths a and b along it (0 <= a < b <= its length)
local function portion(e, length, a, b)
	local piece = e
	if b < length - EPS then
		piece = geometry.split(piece, geometry.parameterAtLength(piece, b))
	end
	if a > EPS then
		local u = geometry.parameterAtLength(piece, a)
		local __, rest = geometry.split(piece, u)
		piece = rest
	end
	return piece
end

-- how far curve strays from the pieces it replaces
local function strays(curve, pieces)
	return geometry.straysFrom(curve, pieces)
end

local function mergeAll(pieces)
	local merged = pieces[1]
	for i = 2, #pieces do
		merged = geometry.merge(merged, pieces[i])
	end
	return merged
end

local function unit(v)
	local l = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
	if l < 1e-9 then
		return { x = 0, y = 0, z = 0 }
	end
	return { x = v.x / l, y = v.y / l, z = v.z / l }
end

-- Re-lays the chain around the junctions.
-- opts: joinTolerance (default 0.05 m: one curve for what was several), refitTolerance
--   (default 0.5 m: an arc-like curve from a junction, as native refits), junctionGap
--   (between neighbouring junctions' corners, default 0), newNode(position) -> id (for a
--   node put just outside a keep-out when the old curve cannot be joined), accept(curve,
--   pieces) -> ok (optional, e.g. the type's minimum radius).
-- Returns { pieces = { { node0, node1, edge, origins, reversed } }, removedNodes,
--   removedEdges, problems } with node0 / node1 ids, origins the ids of the old edges the
--   piece replaces. Edges and nodes untouched are not listed.
function chain.relay(c, junctions, opts)
	opts = opts or {}
	local joinTolerance = opts.joinTolerance or 0.05
	local refitTolerance = opts.refitTolerance or 0.5
	local result = { pieces = {}, removedNodes = {}, removedEdges = {}, problems = {} }

	-- 1. distance along the chain of every node
	local lengths, at = {}, { [1] = 0 }
	for i, e in ipairs(c.edges) do
		lengths[i] = geometry.arcLength(e.edge)
		at[i + 1] = at[i] + lengths[i]
	end
	local total = at[#c.edges + 1]

	-- the edge index and length along it for a distance along the chain
	local function locate(s)
		for i = 1, #c.edges do
			if s <= at[i + 1] + EPS or i == #c.edges then
				return i, math.max(0, math.min(lengths[i], s - at[i]))
			end
		end
	end

	-- 2. the points along the chain: its nodes and the junctions
	local points = {}
	for i, n in ipairs(c.nodes) do
		points[#points + 1] = { s = at[i], id = n.id, position = n.position, fixed = n.fixed or i == 1 or i == #c.nodes,
			node = i }
	end
	local keeps = {}
	for __, j in ipairs(junctions) do
		local s
		if j.node then
			s = at[j.node]
			points[j.node].fixed = true
			points[j.node].junction = j
		else
			local best, bestDistance = nil, math.huge
			for i = (j.edge or 1), (j.edge or #c.edges) do
				local u, d = geometry.closestParameter(j.position, c.edges[i].edge)
				if d < bestDistance then
					local before = geometry.split(c.edges[i].edge, math.max(u, 1e-6))
					best, bestDistance = at[i] + (u > 1e-6 and geometry.arcLength(before) or 0), d
				end
			end
			s = best
			points[#points + 1] = { s = s, id = j.id, position = j.position, fixed = true, junction = j }
		end
		keeps[#keeps + 1] = { s = s, before = j.keepBefore or 0, after = j.keepAfter or 0, junction = j }
	end
	table.sort(points, function(a, b)
		return a.s < b.s
	end)

	-- spacing between neighbouring junctions
	local last = nil
	for __, p in ipairs(points) do
		if p.junction then
			if last and last.junction.corner and p.junction.corner then
				local need = last.junction.corner + p.junction.corner + (opts.junctionGap or 0)
				if p.s - last.s < need - EPS then
					result.problems[#result.problems + 1] = string.format("junctions %s and %s only %.1f m apart, they need %.1f m",
						tostring(last.id), tostring(p.id), p.s - last.s, need)
				end
			end
			last = p
		end
	end

	-- 3. plain nodes inside a keep-out go
	local function insideKeepOut(s)
		for __, k in ipairs(keeps) do
			if (s > k.s - k.before + EPS and s < k.s - EPS) or (s > k.s + EPS and s < k.s + k.after - EPS) then
				return true
			end
		end
		return false
	end
	local kept = {}
	for __, p in ipairs(points) do
		if p.fixed or not insideKeepOut(p.s) then
			kept[#kept + 1] = p
		else
			result.removedNodes[#result.removedNodes + 1] = p.id
			p.removed = true
		end
	end

	-- the old curve between two distances, as pieces of the old edges, and their ids
	local function stretch(a, b)
		local pieces, origins = {}, {}
		local i0 = locate(a + EPS)
		local i1 = locate(b - EPS)
		for i = i0, i1 do
			local from = math.max(0, a - at[i])
			local to = math.min(lengths[i], b - at[i])
			if to - from > EPS then
				pieces[#pieces + 1] = portion(c.edges[i].edge, lengths[i], from, to)
				origins[#origins + 1] = c.edges[i].id
			end
		end
		return pieces, origins, c.edges[i0].reversed
	end

	local function emit(p0, p1, edge, origins, reversed)
		result.pieces[#result.pieces + 1] = { node0 = p0.id, node1 = p1.id, edge = edge, origins = origins, reversed = reversed }
	end

	-- one curve for the old pieces, or nil and how far the best try strays
	local function oneCurve(pieces, p0, p1)
		if #pieces == 0 then
			-- two points of the chain at one spot (a junction on a node): nothing to lay
			return nil, 0
		end
		if #pieces == 1 then
			return pieces[1], 0
		end
		-- all on one straight line: one straight, exactly (most roads; no sampling needed)
		local first, lastOne = pieces[1].p0, pieces[#pieces].p1
		local dx, dy = lastOne.x - first.x, lastOne.y - first.y
		local length = math.sqrt(dx * dx + dy * dy)
		if length > EPS then
			local onLine = true
			local function off(v)
				local l = math.sqrt(v.x * v.x + v.y * v.y)
				return l < 1e-9 or math.abs(v.x * dy - v.y * dx) / (l * length) > 1e-4 or v.x * dx + v.y * dy <= 0
			end
			for __, piece in ipairs(pieces) do
				local toEnd = { x = piece.p1.x - first.x, y = piece.p1.y - first.y }
				if off(piece.t0) or off(piece.t1) or math.abs(toEnd.x * dy - toEnd.y * dx) / length > 0.001 then
					onLine = false
					break
				end
			end
			if onLine then
				local t = { x = lastOne.x - first.x, y = lastOne.y - first.y, z = lastOne.z - first.z }
				return { p0 = first, p1 = lastOne, t0 = t, t1 = { x = t.x, y = t.y, z = t.z } }, 0
			end
		end
		local merged = mergeAll(pieces)
		local d = strays(merged, pieces)
		if d <= joinTolerance and (opts.accept == nil or opts.accept(merged, pieces)) then
			return merged, d
		end
		-- as native refits: an arc-like curve from end to end with the old directions
		local first, lastPiece = pieces[1], pieces[#pieces]
		local arc = geometry.arcCubic(p0.position, unit(first.t0), p1.position, unit(lastPiece.t1))
		local da = strays(arc, pieces)
		if da <= refitTolerance and (opts.accept == nil or opts.accept(arc, pieces)) then
			return arc, da
		end
		return nil, math.min(d, da)
	end

	-- 4. re-lay between the points that stay
	local changed = {}
	for k = 1, #kept - 1 do
		local p0, p1 = kept[k], kept[k + 1]
		-- untouched: an old edge from node to node with nothing on it (an existing node
		-- that is a junction keeps its edges)
		local untouched = p0.node and p1.node and p1.node == p0.node + 1
		if not untouched then
			local pieces, origins, reversed = stretch(p0.s, p1.s)
			local curve, d = oneCurve(pieces, p0, p1)
			if curve == nil and opts.newNode then
				-- a node just outside the keep-out of the junction at one end, the old curve
				-- beyond it kept exactly (native: the next node at corner + 26 m)
				local jAt, s = nil, nil
				if p0.junction and (p0.junction.keepAfter or 0) > 0 then
					jAt, s = p0, p0.s + p0.junction.keepAfter
				elseif p1.junction and (p1.junction.keepBefore or 0) > 0 then
					jAt, s = p1, p1.s - p1.junction.keepBefore
				end
				if jAt and s > math.min(p0.s, p1.s) + EPS and s < math.max(p0.s, p1.s) - EPS and not insideKeepOut(s) then
					local i, along = locate(s)
					local u = geometry.parameterAtLength(c.edges[i].edge, along)
					local position = geometry.hermite(c.edges[i].edge.p0, c.edges[i].edge.p1, c.edges[i].edge.t0, c.edges[i].edge.t1, u)
					local mid = { s = s, id = opts.newNode(position), position = position }
					local aPieces, aOrigins = stretch(p0.s, s)
					local bPieces, bOrigins = stretch(s, p1.s)
					local aCurve = oneCurve(aPieces, p0, mid)
					local bCurve = oneCurve(bPieces, mid, p1)
					if aCurve and bCurve then
						emit(p0, mid, aCurve, aOrigins, reversed)
						emit(mid, p1, bCurve, bOrigins, reversed)
						curve = true
					end
				end
			end
			if curve == nil then
				result.problems[#result.problems + 1] = string.format(
					"the road between %s and %s cannot be re-laid without bending it (strays %.2f m)", tostring(p0.id), tostring(p1.id), d)
			elseif curve ~= true then
				emit(p0, p1, curve, origins, reversed)
			end
			for __, id in ipairs(origins) do
				changed[id] = true
			end
		end
	end
	for __, e in ipairs(c.edges) do
		if changed[e.id] then
			result.removedEdges[#result.removedEdges + 1] = e.id
		end
	end
	result.total = total
	return result
end

return chain
