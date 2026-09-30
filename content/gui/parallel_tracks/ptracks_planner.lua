-- Planning of the tracks next to a drawn one: offset geometry, anchoring on and
-- crossing existing tracks, and the proposal for it. Loaded on both lua states that
-- need it: the game script (building) and the menu (preview).

local shared = require "ptracks_shared.lua"
local geometry = require "ptracks_geometry.lua"

local planner = {}

-- CPU time in milliseconds, for timing logs; nil if the game does not offer it
local function clockMs()
	local ok, t = pcall(os.clock)
	return ok and t and t * 1000 or nil
end

-- an added segment within this distance of a removed one is a leftover of splitting it
local REMNANT_TOLERANCE = 0.25
local DEFAULT_TRACK_DISTANCE = 5.0
-- an existing node this close to where a new one would go is used instead
local NODE_SNAP_DISTANCE = 0.5
-- height difference up to which nodes / crossings count as the same level
local NODE_SNAP_HEIGHT = 1.0
-- an existing track edge this close to the start or end of an offset track gets split
-- there, so the offset track branches off it
local EDGE_SEARCH_RADIUS = 1.0
local EDGE_SNAP_DISTANCE = 0.25
-- no split or crossing this close (in meters) to the end of an edge, it is at the node
local EDGE_END_DISTANCE = 0.1
-- a split closer than this to a node of the split edge moves that node instead
local MIN_PIECE_LENGTH = 5.0
-- an end of an offset track continues a loose end within this share of the distance
-- between neighbouring tracks (below half, so never the neighbour's)
local LOOSE_END_SHARE = 0.4
-- shortfall of a piece against MIN_PIECE_LENGTH that is still let through
local PIECE_TOLERANCE = 0.25
-- A drag starting (or ending) at the end of an existing road at an angle to it, which
-- the road builder allows in both its modes, kinks there. Between these angles
-- (degrees) the parallel of the old road is cut back or extended to the corner where
-- the two parallels meet, and the new parallel starts there.
local MITER_MIN_ANGLE = 1.0
local MITER_MAX_ANGLE = 100.0
-- dev switch: extra roads crossing or branching onto roads. Every plan with such a
-- junction crashed the game so far (map_util.h "it != map.end()", three times, while
-- evaluating the preview), road plans without one did not. Off: such drags are refused.
local ROAD_JUNCTIONS = false
-- crossings flatter than this (degrees) are not built: measured in game, the builder
-- refuses crossings under 6.0 degrees (and a very flat one once crashed the game)
local MIN_CROSSING_ANGLE = 6.05
planner.MIN_CROSSING_ANGLE = MIN_CROSSING_ANGLE
-- how much room a crossing needs along each track, as clearance / tan(angle)
local CROSSING_CLEARANCE = 1.5
-- cap on the length of a switch zone (a branch leaving on a straight never clears)
local MAX_SWITCH_ZONE = 150.0
-- two edges are only merged into one if that one strays no more than this from them
local MAX_MERGE_DEVIATION = 0.2
-- smallest curve radius for extra tracks if the track template does not say
local DEFAULT_MIN_RADIUS = 40.0
-- for extra roads only a road turned inside out on the inside of a bend is refused, the
-- street builder has no radius limit of its own (not measured)
local DEFAULT_MIN_RADIUS_STREET = 1.0

local function plain(v)
	return { x = v.x, y = v.y, z = v.z }
end

local function vec3(v)
	return api.type.Vec3f.new(v.x, v.y, v.z)
end

local function toEdge(comp)
	return {
		p0 = plain(comp.position0),
		p1 = plain(comp.position1),
		t0 = plain(comp.tangent0),
		t1 = plain(comp.tangent1),
	}
end

-- The kind of edge being planned (track or street, api.type.enum.RoadType), set for
-- the time a plan is made. Extra roads anchor on, cross and rebuild roads, extra
-- tracks tracks; edges of the other kind are left alone.
local planRoadType = nil

local function trackRoadType()
	return api.type["enum"].RoadType.TRACK
end

local function isStreet(roadType)
	return roadType == api.type["enum"].RoadType.STREET
end

local function isPlanned(comp)
	return comp.roadType == (planRoadType or trackRoadType())
end

-- While a plan is made, edge components read from the world are kept: reading one
-- copies it into lua, and the same nearby edges come up for many offset edges.
local compCache = nil

-- the component as it is in the world now, for everything outside a plan
local function readEdgeComp(entity)
	return api.engine.getComponent(entity, api.type.ComponentType.BASE_EDGE)
end

local function getEdgeComp(entity)
	if compCache ~= nil then
		local cached = compCache[entity]
		if cached == nil then
			cached = api.engine.getComponent(entity, api.type.ComponentType.BASE_EDGE) or false
			compCache[entity] = cached
		end
		return cached or nil
	end
	return api.engine.getComponent(entity, api.type.ComponentType.BASE_EDGE)
end

local function getPlayerOwned(entity)
	local ok, result = pcall(function()
		return api.engine.getComponent(entity, api.type.ComponentType.PLAYER_OWNED)
	end)
	return ok and result or nil
end

local function sizeOf(list)
	local ok, n = pcall(function()
		return #list
	end)
	return ok and n or 0
end

-- The lane configs for an edge like comp. Segments of the builder's live proposal can
-- come without them in the middle of a drag, and an edge without lane configs crashes
-- the game, so they are then taken from the track template.
-- Track templates by name. Fetching one copies the whole template into lua, and they do
-- not change during a game, so each is fetched once.
local templateCache = {}

local function getTemplate(name)
	if name == nil then
		return nil
	end
	local cached = shared.PERF_MEASURES and templateCache[name] or nil
	if cached == nil then
		local ok, template = pcall(function()
			return api.res.streetTemplateRep.get(api.res.streetTemplateRep.find(name))
		end)
		cached = ok and template or false
		templateCache[name] = cached
	end
	return cached or nil
end

local function laneConfigsOf(comp, templateName)
	if comp.laneConfigs ~= nil and sizeOf(comp.laneConfigs) > 0 then
		return comp.laneConfigs
	end
	local template = getTemplate(templateName)
	if template and template.laneConfigs ~= nil and sizeOf(template.laneConfigs) > 0 then
		return template.laneConfigs
	end
	error("no lane configs for an edge of " .. tostring(templateName))
end

local function nonEmpty(s)
	return s ~= nil and s ~= "" and s or nil
end

-- Track template and style for an edge like props.comp. Segments of the builder's live
-- proposal can also come without them, then props.template (the track type selected in
-- the menu) is used.
local function templateOf(props)
	return nonEmpty(props.comp.roadTemplate) or props.template
end

local function styleOf(props)
	local style = nonEmpty(props.comp.roadStyle)
	if style then
		return style
	end
	local template = getTemplate(templateOf(props))
	return template and template.streetStyle or nil
end

-- The shortest piece of track the game accepts next to a node on it. A crossing needs
-- more the flatter it is: the two tracks run side by side for a while (fitted to builds
-- in game: at 6.1 degrees 7.7 m next to a crossing failed, 14.9 m worked).
local function minPieceLength(cut)
	if cut.zone ~= nil then
		return math.max(MIN_PIECE_LENGTH, cut.zone)
	end
	if cut.angle == nil then
		return MIN_PIECE_LENGTH
	end
	local t = math.tan(math.rad(math.max(cut.angle, 1)))
	return math.max(MIN_PIECE_LENGTH, CROSSING_CLEARANCE / t)
end

-- How far along the base track a switch reaches: until the track branching off it with
-- this radius is a track distance away. The game wants no other node on the base
-- track within that (seen in game: the builder removed a node 40 m into such a zone,
-- and building with the node there failed).
local function switchZone(radius)
	if radius == nil or radius == math.huge then
		return MAX_SWITCH_ZONE
	end
	return math.min(MAX_SWITCH_ZONE, math.sqrt(2 * radius * DEFAULT_TRACK_DISTANCE))
end

-- Distance between the centre lines of neighbouring tracks or roads. Tracks have it in
-- their template; roads lie side by side, a road's width apart (the sum of its lanes,
-- sidewalks and verges included).
local function getTrackDistance(roadTemplate)
	local template = getTemplate(roadTemplate)
	if template and isStreet(template.roadType) then
		local width = 0
		for __, lc in ipairs(template.laneConfigs or {}) do
			width = width + math.abs(lc.width or 0)
		end
		if width > 0 then
			return width
		end
	end
	local distance = template and template.trackDistance
	if distance and distance > 0 then
		return distance
	end
	return DEFAULT_TRACK_DISTANCE
end

local function formatRadius(r)
	return string.format("%.1f", r)
end

--------------------------------------------------------------------------------
-- reading the player's build

-- The segments the player has drawn, as { entity, segmentType, comp, edge }. The proposal also
-- re-adds the pieces of every existing track or street that got split by the new
-- track, those are left out. roadType: what the builder draws (default: track).
local function collectDrawnSegments(streetProposal, roadType)
	roadType = roadType or trackRoadType()
	local removed = {}
	for __, segment in ipairs(streetProposal.removedSegments) do
		removed[#removed + 1] = toEdge(segment.comp)
	end

	local drawn = {}
	for __, segment in ipairs(streetProposal.addedSegments) do
		if segment.comp.roadType == roadType then
			local edge = toEdge(segment.comp)
			if not geometry.liesOnAny(edge, removed, REMNANT_TOLERANCE) then
				drawn[#drawn + 1] = { entity = segment.entity, segmentType = segment.type, comp = segment.comp, edge = edge }
			end
		end
	end
	return drawn
end

-- true once every drawn segment exists in the world as it was proposed. Entity ids get
-- reused, so the id alone does not tell.
local function isApplied(drawn)
	for __, d in ipairs(drawn) do
		local comp = readEdgeComp(d.entity)
		if comp == nil
			or geometry.horizontalDistance(plain(comp.position0), d.edge.p0) > 0.01
			or geometry.horizontalDistance(plain(comp.position1), d.edge.p1) > 0.01 then
			return false
		end
	end
	return true
end

--------------------------------------------------------------------------------
-- searching the world

-- A node that already exists at the position, e.g. the end of the parallel track of
-- the previous drag. A new node on top of it would make the whole build fail.
local function findExistingNode(position)
	local center = api.type.Vec2f.new(position.x, position.y)
	local candidates = api.engine.util.octree.findEntitiesInCircle(center, NODE_SNAP_DISTANCE, api.type.ComponentType.BASE_NODE)
	for __, entity in ipairs(candidates) do
		local comp = api.engine.getComponent(entity, api.type.ComponentType.BASE_NODE)
		if comp and math.abs(comp.position.x - position.x) < NODE_SNAP_DISTANCE
			and math.abs(comp.position.y - position.y) < NODE_SNAP_DISTANCE
			and math.abs(comp.position.z - position.z) < NODE_SNAP_HEIGHT then
			return { entity = entity, position = plain(comp.position) }
		end
	end
	return nil
end

-- Which edges meet at each node, fetched once per plan when first needed (the whole
-- map comes over into lua).
local node2segmentsCache = nil

local function getNode2Segments()
	if node2segmentsCache == nil then
		node2segmentsCache = api.engine.system.streetSystem.getNode2SegmentMap()
	end
	return node2segmentsCache
end

-- The loose end (a node with a single edge of the planned kind) nearest to the
-- position within radius, e.g. where the parallel of the previous drag stops. A drag
-- continuing that one at a slight angle puts the offset end next to it rather than on
-- it; branching off a metre from the end would leave a stub the game cannot handle.
local function findLooseEnd(position, radius)
	local center = api.type.Vec2f.new(position.x, position.y)
	local best, bestDistance = nil, math.huge
	for __, entity in ipairs(api.engine.util.octree.findEntitiesInCircle(center, radius, api.type.ComponentType.BASE_NODE)) do
		local comp = api.engine.getComponent(entity, api.type.ComponentType.BASE_NODE)
		if comp and math.abs(comp.position.z - position.z) < NODE_SNAP_HEIGHT then
			local distance = geometry.horizontalDistance(plain(comp.position), position)
			local segments = getNode2Segments()[entity]
			if distance < radius and distance < bestDistance and segments and #segments == 1 then
				local edge = getEdgeComp(segments[1])
				if edge and isPlanned(edge) then
					best, bestDistance = { entity = entity, position = plain(comp.position) }, distance
				end
			end
		end
	end
	return best, bestDistance
end

local function isAwayFromEnds(edge, point)
	return geometry.horizontalDistance(point, edge.p0) > EDGE_END_DISTANCE
		and geometry.horizontalDistance(point, edge.p1) > EDGE_END_DISTANCE
end

-- An existing track edge running through the position, away from its ends, e.g. the
-- neighbour of the track a branch was drawn from.
local function findEdgeAt(position)
	local center = api.type.Vec2f.new(position.x, position.y)
	local candidates = api.engine.util.octree.findEntitiesInCircle(center, EDGE_SEARCH_RADIUS, api.type.ComponentType.BASE_EDGE)
	for __, entity in ipairs(candidates) do
		local comp = getEdgeComp(entity)
		if comp and isPlanned(comp) then
			local edge = toEdge(comp)
			local u, distance = geometry.closestParameter(position, edge)
			local point = geometry.hermite(edge.p0, edge.p1, edge.t0, edge.t1, u)
			if distance < EDGE_SNAP_DISTANCE and isAwayFromEnds(edge, point)
				and math.abs(point.z - position.z) < NODE_SNAP_HEIGHT then
				return entity, u, point
			end
		end
	end
	return nil
end

-- existing track edges that may cross the edge
local function findEdgesNear(edge)
	local cx, cy = (edge.p0.x + edge.p1.x) / 2, (edge.p0.y + edge.p1.y) / 2
	-- the chord plus some room for the bulge of a curve
	local radius = geometry.horizontalDistance(edge.p0, edge.p1) * 0.75 + 5
	return api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(cx, cy), radius, api.type.ComponentType.BASE_EDGE)
end

-- The first crossing of a planned edge with a drawn edge or another planned edge, as a
-- problem text, or nil. Edges meeting at their ends (a chain) do not count, nor edges
-- passing over each other at different heights.
local function findSelfCrossing(drawn, tracks)
	local function crossing(a, b)
		for __, x in ipairs(geometry.intersections(a, b)) do
			if math.abs(x.pointA.z - x.pointB.z) < NODE_SNAP_HEIGHT
				and isAwayFromEnds(a, x.pointA) and isAwayFromEnds(b, x.pointB) then
				return x
			end
		end
		return nil
	end
	local planned = {}
	for __, offsetEdges in ipairs(tracks) do
		for __, oe in ipairs(offsetEdges) do
			planned[#planned + 1] = oe.edge
		end
	end
	for i, edge in ipairs(planned) do
		for __, d in ipairs(drawn) do
			local x = crossing(edge, d.edge)
			if x then
				return "a parallel edge would cross the drawn one at " .. shared.vecToString(x.pointA)
			end
		end
		for j = i + 1, #planned do
			local x = crossing(edge, planned[j])
			if x then
				return "two parallel edges would cross each other at " .. shared.vecToString(x.pointA)
			end
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- building one offset track

-- Builds the proposal for one track next to the drawn one. The plan is made on plain
-- tables first: nodes, offset edges, cuts where offset edges cross existing tracks
-- and splits of existing edges. Returns the proposal and stats for the log; with
-- planOnly just nil and the stats, e.g. to check a drag before it is built.
-- options.reverse: the extra edges run against the drawn ones (the other carriageway of
-- a split highway: a one-way road's lanes run along its edge).
local function makeProposal(drawn, offsets, log, planOnly, options)
	if type(offsets) == "number" then
		offsets = { offsets }
	end
	options = options or {}
	log = log or function() end
	compCache = shared.PERF_MEASURES and {} or nil
	node2segmentsCache = nil
	planRoadType = drawn[1] and drawn[1].comp.roadType or trackRoadType()
	local streets = isStreet(planRoadType)
	local noJunctions = streets and not ROAD_JUNCTIONS
	-- the distance between neighbouring tracks: the nearest offset is one step out
	local step = math.huge
	for __, offset in ipairs(offsets) do
		step = math.min(step, math.abs(offset))
	end
	local looseEndRadius = math.min(MIN_PIECE_LENGTH * 1.5, LOOSE_END_SHARE * step)
	geometry.fastIntersections = shared.PERF_MEASURES
	local timing = { start = clockMs(), offsets = 0, crossings = 0, merges = 0 }
	local function lap(name, since)
		local t = clockMs()
		if t and since then
			timing[name] = timing[name] + (t - since)
		end
		return t
	end
	local stats = { edges = 0, minRadius = math.huge, reused = 0, anchored = 0, crossings = 0, junctions = 0, shallow = 0, moved = 0, dropped = 0, skipped = 0, plan = {}, problems = {} }

	-- Right and left are taken from each segment's own direction, so all segments of the
	-- run must run the same way. The builder does not always hand them over like that.
	do
		local segments = {}
		for __, d in ipairs(drawn) do
			segments[#segments + 1] = { node0 = d.comp.node0, node1 = d.comp.node1, edge = d.edge, d = d }
		end
		local ordered, turned = geometry.orientChain(segments)
		if turned > 0 then
			log("  " .. turned .. " of " .. #segments .. " drawn segments ran the other way, turned them around")
		end
		local oriented = {}
		for __, s in ipairs(ordered) do
			local d = (s.source or s).d
			oriented[#oriented + 1] = {
				entity = d.entity,
				segmentType = d.segmentType,
				comp = d.comp,
				template = d.template,
				node0 = s.node0,
				node1 = s.node1,
				edge = s.edge,
			}
		end
		drawn = oriented
	end
	-- existing nodes the offset track connects to, they must stay where they are
	local reusedNodes = {}
	local nextNodeId = -100000
	local nodesToAdd = {}

	local function newNode(position)
		local node = { entity = nextNodeId, position = position }
		nodesToAdd[#nodesToAdd + 1] = node
		nextNodeId = nextNodeId - 1
		return node
	end

	-- existing edges to split: entity -> { comp, edge, cuts = { { u, node } } }
	local splits = {}
	local function addSplit(entity, u, node, angle)
		local split = splits[entity]
		if split == nil then
			local comp = getEdgeComp(entity)
			split = { comp = comp, edge = toEdge(comp), cuts = {} }
			splits[entity] = split
		end
		local cut = { u = u, node = node, angle = angle }
		split.cuts[#split.cuts + 1] = cut
		return cut
	end
	-- the cuts of switches (anchors), by their node, to give them their zone once the
	-- track branching off is known
	local anchorCuts = {}

	local drawnEntities = {}
	local useCount = {}
	for __, d in ipairs(drawn) do
		drawnEntities[d.entity] = true
		useCount[d.node0] = (useCount[d.node0] or 0) + 1
		useCount[d.node1] = (useCount[d.node1] or 0) + 1
	end

	-- existing edges as geometry, by entity, for the crossing search
	local worldEdges = {}
	-- the offset edges of each planned track
	local tracks = {}
	-- existing parallels whose loose end moves to a corner: { entity, comp, looseNode,
	-- node0, node1, edge }, and the corner nodes, where a kink is meant
	local rebuilt = {}
	local corners = {}
	timing.firstTrack = clockMs()
	for __, offset in ipairs(offsets) do
		timing.trackStart = clockMs()
		-- node of the drawn track -> its counterpart on the offset track
		local nodes = {}
		-- new nodes in the middle of the offset track, which may be dropped
		local movable = {}

		-- The drawn run starts (atStart) or ends at the end of an existing road and kinks
		-- there. If the parallel of that road ends where it should, move its end to the
		-- corner of the two parallels and return the corner node; else nil.
		local function tryCorner(entity, position, tangent, atStart)
			-- tracks cannot kink, the track builder always continues a track smoothly
			if not streets then
				return nil
			end
			local segments = getNode2Segments()[entity]
			if segments == nil then
				return nil
			end
			local old = nil
			for __, s in ipairs(segments) do
				if not drawnEntities[s] then
					local comp = getEdgeComp(s)
					if comp and isPlanned(comp) then
						if old then
							return nil -- a junction, not the end of a road
						end
						old = comp
					end
				end
			end
			if old == nil then
				return nil
			end
			local oldEdge = toEdge(old)
			-- the old road's direction at the node, the way the run goes
			local oldDir
			if atStart then
				oldDir = old.node1 == entity and oldEdge.t1 or { x = -oldEdge.t0.x, y = -oldEdge.t0.y, z = -oldEdge.t0.z }
			else
				oldDir = old.node0 == entity and oldEdge.t0 or { x = -oldEdge.t1.x, y = -oldEdge.t1.y, z = -oldEdge.t1.z }
			end
			local kink = geometry.angleBetween(oldDir, tangent)
			if kink < MITER_MIN_ANGLE or kink > MITER_MAX_ANGLE then
				return nil
			end
			local arriving, leaving = oldDir, tangent
			if not atStart then
				arriving, leaving = tangent, oldDir
			end
			local corner = geometry.miter(position, arriving, leaving, offset)
			if corner == nil then
				return nil
			end
			-- the old road's parallel, ending where it would without the kink
			local loose = findExistingNode(geometry.offsetPoint(position, oldDir, offset))
			local looseSegments = loose and getNode2Segments()[loose.entity]
			if looseSegments == nil or #looseSegments ~= 1 then
				return nil
			end
			local parEntity = looseSegments[1]
			local par = getEdgeComp(parEntity)
			if par == nil or not isPlanned(par) or drawnEntities[parEntity] or splits[parEntity]
				or (par.objects and #par.objects > 0) then
				return nil
			end
			local parEdge = toEdge(par)
			corner.z = loose.position.z
			local q0, q1 = parEdge.p0, parEdge.p1
			local looseAtEnd = par.node1 == loose.entity
			if looseAtEnd then
				q1 = corner
			else
				q0 = corner
			end
			if geometry.horizontalDistance(q0, q1) < MIN_PIECE_LENGTH then
				return nil
			end
			local t0, t1 = geometry.offsetTangents(parEdge.p0, parEdge.p1, parEdge.t0, parEdge.t1, q0, q1)
			local node = newNode(corner)
			local far = { entity = looseAtEnd and par.node0 or par.node1, position = looseAtEnd and parEdge.p0 or parEdge.p1 }
			rebuilt[#rebuilt + 1] = {
				entity = parEntity,
				comp = par,
				looseNode = loose.entity,
				node0 = looseAtEnd and far or node,
				node1 = looseAtEnd and node or far,
				edge = { p0 = q0, p1 = q1, t0 = t0, t1 = t1 },
			}
			corners[node.entity] = true
			-- the rebuilt edge is not crossed, split or moved by the rest of the plan
			drawnEntities[parEntity] = true
			log(string.format("  node %d: kinks %.1f deg, parallel end %d moved %.2f m to the corner ", entity, kink, loose.entity,
				geometry.horizontalDistance(loose.position, corner)) .. shared.vecToString(corner))
			return node
		end

		local function getNode(entity, position, tangent, atStart)
			local node = nodes[entity]
			if node == nil then
				local newPosition = geometry.offsetPoint(position, tangent, offset)
				if newPosition == nil then
					return nil
				end
				if useCount[entity] == 1 then
					node = tryCorner(entity, position, tangent, atStart)
				end
				node = node or findExistingNode(newPosition)
				if node and corners[node.entity] then
					-- the corner, made above
				elseif node then
					stats.reused = stats.reused + 1
					reusedNodes[node.entity] = true
					log("  node " .. entity .. ": existing node " .. node.entity .. " " .. shared.vecToString(node.position))
					local segments = getNode2Segments()[node.entity]
					if noJunctions and segments and #segments >= 2 then
						-- joining a road in the middle, not at its end
						stats.junctions = stats.junctions + 1
					end
				elseif useCount[entity] == 1 then
					-- an end of the run next to the loose end of a previous parallel: continue it
					local looseEnd, distance = findLooseEnd(newPosition, looseEndRadius)
					if looseEnd then
						node = looseEnd
						stats.reused = stats.reused + 1
						reusedNodes[node.entity] = true
						log(string.format("  node %d: continues loose end %d, %.2f m off ", entity, node.entity, distance)
							.. shared.vecToString(node.position))
					end
				end
				if node == nil and useCount[entity] == 1 then
					-- an end of the run lying on an existing track: branch off it
					local edgeEntity, u, point = findEdgeAt(newPosition)
					if edgeEntity and noJunctions then
						stats.junctions = stats.junctions + 1
						log("  node " .. entity .. ": would branch off edge " .. edgeEntity .. ", road junctions are off")
					elseif edgeEntity then
						node = newNode(point)
						anchorCuts[node.entity] = addSplit(edgeEntity, u, node)
						stats.anchored = stats.anchored + 1
						log("  node " .. entity .. ": anchored on edge " .. edgeEntity .. string.format(" at u = %.3f ", u) .. shared.vecToString(point))
					end
				end
				if node == nil then
					node = newNode(newPosition)
					if useCount[entity] == 2 then
						-- only mirrors a node of the drawn track, free to go if in the way
						movable[node.entity] = true
					end
				end
				nodes[entity] = node
			end
			return node
		end

		-- offset edges: { node0, node1, edge, props, cuts }
		local offsetEdges = {}
		for __, d in ipairs(drawn) do
			local node0 = getNode(d.node0, d.edge.p0, d.edge.t0, true)
			local node1 = getNode(d.node1, d.edge.p1, d.edge.t1, false)
			if node0 and node1 then
				local t0, t1 = geometry.offsetTangents(d.edge.p0, d.edge.p1, d.edge.t0, d.edge.t1, node0.position, node1.position)
				local edge = { p0 = node0.position, p1 = node1.position, t0 = t0, t1 = t1 }
				local radius = geometry.radius(edge.p0, edge.p1, t0, t1)
				-- on the inside of a bend tighter than the offset the track turns inside out:
				-- its ends swap over, the chord runs against the drawn one
				local dx, dy = edge.p1.x - edge.p0.x, edge.p1.y - edge.p0.y
				local ex, ey = d.edge.p1.x - d.edge.p0.x, d.edge.p1.y - d.edge.p0.y
				if dx * ex + dy * ey <= 0 then
					radius = 0
				end
				stats.minRadius = math.min(stats.minRadius, radius)
				offsetEdges[#offsetEdges + 1] = {
					node0 = node0,
					node1 = node1,
					edge = edge,
					props = { comp = d.comp, template = d.template, segmentType = d.segmentType, playerOwned = getPlayerOwned(d.entity) },
					cuts = {},
				}
				-- a switch reaches as far along the base track as its branch takes to clear it
				-- (a road branching off makes a junction, which has no such zone)
				for __, node in ipairs({ node0, node1 }) do
					local cut = anchorCuts[node.entity]
					if cut and not streets then
						cut.zone = switchZone(geometry.radius(edge.p0, edge.p1, t0, t1))
						log(string.format("  switch at node %d keeps the base track clear for %.1f m", node.entity, cut.zone))
					end
				end
			end
		end

		local phase = lap("offsets", timing.trackStart)
		-- crossings with existing tracks on the same level get a shared node
		for __, oe in ipairs(offsetEdges) do
			for __, entity in ipairs(findEdgesNear(oe.edge)) do
				local comp = not drawnEntities[entity] and getEdgeComp(entity) or nil
				if comp and isPlanned(comp) then
					-- one edge table per existing edge and plan, so its sampled polyline is
					-- reused for every offset edge it is tested against
					local other = shared.PERF_MEASURES and worldEdges[entity] or nil
					if other == nil then
						other = toEdge(comp)
						worldEdges[entity] = other
					end
					for __, x in ipairs(geometry.intersections(oe.edge, other)) do
						local angle = geometry.crossingAngle(oe.edge, x.ua, other, x.ub)
						if math.abs(x.pointA.z - x.pointB.z) < NODE_SNAP_HEIGHT
							and isAwayFromEnds(oe.edge, x.pointA) and isAwayFromEnds(other, x.pointB) then
							if noJunctions then
								stats.junctions = stats.junctions + 1
								log(string.format("  would cross edge %d at %.1f deg, road junctions are off", entity, angle))
							elseif angle < MIN_CROSSING_ANGLE then
								-- the game crashes building the geometry of a crossing this
								-- shallow, better let the build fail on the collision
								stats.shallow = stats.shallow + 1
								log(string.format("  crossing edge %d at %.1f deg is too shallow, not built", entity, angle))
							else
								local node = newNode(x.pointA)
								oe.cuts[#oe.cuts + 1] = { u = x.ua, node = node, angle = angle }
								addSplit(entity, x.ub, node, angle)
								stats.crossings = stats.crossings + 1
								log("  crossing edge " .. entity .. string.format(" at u = %.3f, %.1f deg ", x.ub, angle) .. shared.vecToString(x.pointA))
							end
						end
					end
				end
			end
		end

		phase = lap("crossings", phase)
		-- A crossing close to a node in the middle of the offset track would leave a short
		-- piece there. Those nodes only mirror nodes of the drawn track, so drop them: merge
		-- the two offset edges around it, the crossing takes its place.
		local dropped = {}
		-- nodes that stay because merging around them would bend the track
		local keptNodes = {}
		local function edgesAt(entity)
			local result = {}
			for i, oe in ipairs(offsetEdges) do
				if oe.node0.entity == entity or oe.node1.entity == entity then
					result[#result + 1] = i
				end
			end
			return result
		end
		local function reversed(oe)
			return { node0 = oe.node1, node1 = oe.node0, edge = geometry.reverse(oe.edge), props = oe.props, cuts = oe.cuts }
		end
		local merging = true
		while merging do
			merging = false
			for entity in pairs(movable) do
				local at = edgesAt(entity)
				-- a node whose merge was refused stays refused, no need to work it out again
				if not dropped[entity] and not keptNodes[entity] and #at == 2 then
					local a = offsetEdges[at[1]]
					local b = offsetEdges[at[2]]
					local position = a.node0.entity == entity and a.node0.position or a.node1.position
					-- the cut most in need of room: distance short of its minimum piece
					local nearest = math.huge
					local tooClose = false
					for __, oe in ipairs({ a, b }) do
						for __, cut in ipairs(oe.cuts) do
							local d = geometry.horizontalDistance(cut.node.position, position)
							nearest = math.min(nearest, d)
							if d < minPieceLength(cut) then
								tooClose = true
							end
						end
					end
					if tooClose
						and a.props.comp.type == b.props.comp.type and a.props.comp.typeIndex == b.props.comp.typeIndex then
						if a.node1.entity ~= entity then
							a = reversed(a)
						end
						if b.node0.entity ~= entity then
							b = reversed(b)
						end
						-- one curve cannot follow every shape two can (e.g. a long stretch of a
						-- tight spiral): keep the node if the merged curve would stray
						local merged = geometry.merge(a.edge, b.edge)
						local deviation = geometry.mergeDeviation(a.edge, b.edge, merged)
						if deviation > MAX_MERGE_DEVIATION then
							if not keptNodes[entity] then
								keptNodes[entity] = true
								log(string.format("  own node %d is %.2f m from a crossing, kept it: merging would stray %.2f m", entity, nearest, deviation))
							end
						else
							local cuts = {}
							for __, cut in ipairs(a.cuts) do
								cuts[#cuts + 1] = cut
							end
							for __, cut in ipairs(b.cuts) do
								cuts[#cuts + 1] = cut
							end
							offsetEdges[at[1]] = { node0 = a.node0, node1 = b.node1, edge = merged, props = a.props, cuts = cuts }
							table.remove(offsetEdges, at[2])
							dropped[entity] = true
							stats.dropped = stats.dropped + 1
							log(string.format("  own node %d is %.2f m from a crossing, dropped it", entity, nearest))
							merging = true
							break
						end
					end
				end
			end
		end
		if next(dropped) ~= nil then
			local kept = {}
			for __, node in ipairs(nodesToAdd) do
				if not dropped[node.entity] then
					kept[#kept + 1] = node
				end
			end
			nodesToAdd = kept
		end
		if options.reverse then
			for i, oe in ipairs(offsetEdges) do
				offsetEdges[i] = reversed(oe)
			end
		end
		-- the cut parameters refer to the edges as they were, find them again
		for __, oe in ipairs(offsetEdges) do
			for __, cut in ipairs(oe.cuts) do
				cut.u = geometry.closestParameter(cut.node.position, oe.edge)
			end
		end
		tracks[#tracks + 1] = offsetEdges
		lap("merges", phase)
	end
	local emitStart = clockMs()

	-- emit
	local edgesToAdd = {}
	local edgesToRemove = {}
	local nextEdgeId = -1

	local function addSegment(node0, node1, piece, props)
		local entity = nextEdgeId
		nextEdgeId = nextEdgeId - 1
		stats.plan[#stats.plan + 1] = {
			entity = entity,
			node0 = node0.entity,
			node1 = node1.entity,
			edge = { p0 = node0.position, p1 = node1.position, t0 = piece.t0, t1 = piece.t1 },
		}
		-- the game objects only when a proposal is wanted, a check needs just the plan
		if planOnly then
			return
		end
		local segment = api.type.SegmentAndEntity.new()
		segment.entity = entity
		segment.type = props.segmentType
		segment.comp.node0 = node0.entity
		segment.comp.node1 = node1.entity
		segment.comp.position0 = vec3(node0.position)
		segment.comp.position1 = vec3(node1.position)
		segment.comp.tangent0 = vec3(piece.t0)
		segment.comp.tangent1 = vec3(piece.t1)
		segment.comp.type = props.comp.type
		segment.comp.typeIndex = props.comp.typeIndex
		segment.comp.laneConfigs = laneConfigsOf(props.comp, templateOf(props))
		segment.comp.roadTemplate = templateOf(props)
		segment.comp.roadStyle = styleOf(props)
		segment.comp.roadType = props.comp.roadType
		-- e.g. the barriers of a highway; not in every proposal, so optional
		pcall(function()
			if props.comp.edgeDecorations ~= nil then
				segment.comp.edgeDecorations = props.comp.edgeDecorations
			end
		end)
		if props.playerOwned then
			-- not set by the base game's scripted track builder, so optional here
			pcall(function()
				segment.playerOwned = props.playerOwned
			end)
		end
		edgesToAdd[#edgesToAdd + 1] = segment
	end

	-- adds the edge cut into pieces between its end nodes and the cut nodes
	local function addCut(edge, node0, node1, cuts, props)
		table.sort(cuts, function(a, b) return a.u < b.u end)
		local us = {}
		local chain = { node0 }
		for __, cut in ipairs(cuts) do
			us[#us + 1] = cut.u
			chain[#chain + 1] = cut.node
		end
		chain[#chain + 1] = node1
		for i, piece in ipairs(geometry.splitMany(edge, us)) do
			addSegment(chain[i], chain[i + 1], piece, props)
			-- a piece next to a crossing or branch that could not be made long enough: the
			-- game refuses it at best, and crashed on it for roads
			if #chain > 2 then
				local length = geometry.arcLength({ p0 = chain[i].position, p1 = chain[i + 1].position, t0 = piece.t0, t1 = piece.t1 })
				if length < MIN_PIECE_LENGTH - PIECE_TOLERANCE and not stats.shortPiece then
					stats.shortPiece = string.format("a piece of %.1f m next to a crossing or branch at %s, the game needs %.0f m",
						length, shared.vecToString(chain[i].position), MIN_PIECE_LENGTH)
				end
			end
		end
	end

	local nodesToRemove = {}

	-- A cut this close to an end node of the edge would leave a very short piece, or a
	-- node inside a switch zone, which the game refuses. Like the game's own builder,
	-- remove that node: merge the edge with the one on the other side of the node, drop
	-- the node and cut the merged curve. Only for a node between exactly two plain edges
	-- of the same kind. Returns true if it removed one.
	local node2segments = nil
	local function tryMoveEnd(part, which)
		local endNode = which == 0 and part.node0 or part.node1
		local nearest = nil
		for __, cut in ipairs(part.cuts) do
			local d = geometry.horizontalDistance(cut.node.position, endNode.position)
			if d < minPieceLength(cut) and (nearest == nil or d < nearest) then
				nearest = d
			end
		end
		if nearest == nil then
			return
		end
		local prefix = string.format("  cut %.2f m from node %d", nearest, endNode.entity)

		if reusedNodes[endNode.entity] then
			log(prefix .. ", which this track uses, not moved")
			return
		end
		node2segments = node2segments or getNode2Segments()
		local segments = node2segments[endNode.entity]
		if segments == nil or #segments ~= 2 then
			log(prefix .. ", which has " .. (segments and #segments or 0) .. " edges, not moved")
			return
		end
		local own = part.endEdge[which]
		local other = segments[1] == own and segments[2] or segments[1]
		local otherComp = getEdgeComp(other)
		if splits[other] or drawnEntities[other] or otherComp == nil or not isPlanned(otherComp)
			or otherComp.roadTemplate ~= part.comp.roadTemplate or otherComp.type ~= part.comp.type
			or (otherComp.objects and #otherComp.objects > 0) then
			log(prefix .. ", its other edge " .. other .. " cannot be rebuilt, not moved")
			return
		end

		local otherEdge = toEdge(otherComp)
		local merged, far
		if which == 0 then
			-- other runs far node -> end node
			if otherComp.node1 == endNode.entity then
				far = { entity = otherComp.node0, position = otherEdge.p0 }
			else
				otherEdge = geometry.reverse(otherEdge)
				far = { entity = otherComp.node1, position = otherEdge.p0 }
			end
			merged = geometry.merge(otherEdge, part.edge)
		else
			-- other runs end node -> far node
			if otherComp.node0 == endNode.entity then
				far = { entity = otherComp.node1, position = otherEdge.p1 }
			else
				otherEdge = geometry.reverse(otherEdge)
				far = { entity = otherComp.node0, position = otherEdge.p1 }
			end
			merged = geometry.merge(part.edge, otherEdge)
		end
		-- one curve cannot follow every shape two can: rather keep the node than bend the track
		local deviation = geometry.mergeDeviation(part.edge, otherEdge, merged)
		if deviation > MAX_MERGE_DEVIATION then
			log(prefix .. string.format(", not removed: merging with edge %d would stray %.2f m", other, deviation))
			return
		end
		part.edge = merged
		if which == 0 then
			part.node0 = far
		else
			part.node1 = far
		end
		part.endEdge[which] = other
		part.removeEdges[#part.removeEdges + 1] = other
		part.removeNodes[#part.removeNodes + 1] = endNode.entity
		stats.moved = stats.moved + 1
		log(prefix .. ", removed it (merged with edge " .. other .. ")")
		return true
	end

	-- clears one end of a split edge of nodes too close to its cuts, several in a row if a
	-- switch zone reaches that far
	local function clearEnd(part, which)
		for __ = 1, 10 do
			if not tryMoveEnd(part, which) then
				return
			end
		end
	end

	local segmentType = drawn[1].segmentType
	for entity, split in pairs(splits) do
		local objects = split.comp.objects
		if objects and #objects > 0 then
			-- rebuilding the edge would lose its signals, the build will fail on the collision
			log("  not splitting edge " .. entity .. ", it has " .. #objects .. " objects (signals?)")
			stats.skipped = stats.skipped + 1
		else
			local part = {
				comp = split.comp,
				edge = split.edge,
				node0 = { entity = split.comp.node0, position = split.edge.p0 },
				node1 = { entity = split.comp.node1, position = split.edge.p1 },
				endEdge = { [0] = entity, [1] = entity },
				removeEdges = { entity },
				removeNodes = {},
				cuts = split.cuts,
			}
			clearEnd(part, 0)
			clearEnd(part, 1)
			if #part.removeNodes > 0 then
				-- the curve changed, find the cuts on it again
				for __, cut in ipairs(part.cuts) do
					cut.u = geometry.closestParameter(cut.node.position, part.edge)
				end
			end
			addCut(part.edge, part.node0, part.node1, part.cuts, { comp = split.comp, segmentType = segmentType, playerOwned = getPlayerOwned(entity) })
			for __, e in ipairs(part.removeEdges) do
				edgesToRemove[#edgesToRemove + 1] = e
			end
			for __, n in ipairs(part.removeNodes) do
				nodesToRemove[#nodesToRemove + 1] = n
			end
		end
	end

	-- existing parallels ending at a corner now: the edge again with its loose end moved
	for __, r in ipairs(rebuilt) do
		addSegment(r.node0, r.node1, r.edge, { comp = r.comp, segmentType = segmentType, playerOwned = getPlayerOwned(r.entity) })
		edgesToRemove[#edgesToRemove + 1] = r.entity
		nodesToRemove[#nodesToRemove + 1] = r.looseNode
		stats.moved = stats.moved + 1
	end

	for __, offsetEdges in ipairs(tracks) do
		for __, oe in ipairs(offsetEdges) do
			addCut(oe.edge, oe.node0, oe.node1, oe.cuts, oe.props)
			stats.edges = stats.edges + 1
		end
	end

	-- A plan with a track bending at one of its nodes must not reach the game: at a
	-- crossing that crashes it. Callers check stats.problems.
	stats.removedEdges = edgesToRemove
	stats.removedNodes = nodesToRemove
	local checkStart = clockMs()
	stats.problems = geometry.checkPlan(stats.plan, nil, corners)
	-- A drag turning in on itself makes the extra edges cross the drawn ones or each
	-- other. Those crossings are not planned (no shared node), so the game would get two
	-- edges running through each other.
	if stats.shortPiece then
		table.insert(stats.problems, 1, stats.shortPiece)
	end
	if stats.junctions > 0 then
		table.insert(stats.problems, 1, string.format("a parallel road would make %d junction(s), road junctions are off", stats.junctions))
	end
	local selfCrossing = findSelfCrossing(drawn, tracks)
	if selfCrossing then
		stats.selfCrossing = true
		table.insert(stats.problems, 1, selfCrossing)
	end
	-- The tracks on the inside of a bend are tighter than the drawn one, on a hairpin they
	-- turn inside out. The game allows down to the template's minCurveRadius for tracks
	-- laid along others (seen in game: 45 m built where dragging needs 55 m).
	local template = getTemplate(templateOf({ comp = drawn[1].comp, template = drawn[1].template }))
	local minRadius = template and template.minCurveRadius or (streets and DEFAULT_MIN_RADIUS_STREET or DEFAULT_MIN_RADIUS)
	stats.tooTight = stats.minRadius < minRadius
	if stats.tooTight then
		table.insert(stats.problems, 1, string.format("a parallel %s would curve at %.1f m radius, the type needs %.0f m",
			streets and "road" or "track", stats.minRadius, minRadius))
		log("  plan problem: " .. stats.problems[1])
	end
	stats.minAllowedRadius = minRadius
	for __, problem in ipairs(stats.problems) do
		log("  plan problem: " .. problem)
	end

	local proposal = nil
	if not planOnly then
		local nodeAndEntities = {}
		for __, node in ipairs(nodesToAdd) do
			local nodeAndEntity = api.type.NodeAndEntity.new()
			nodeAndEntity.entity = node.entity
			nodeAndEntity.comp.position = vec3(node.position)
			nodeAndEntities[#nodeAndEntities + 1] = nodeAndEntity
		end

		proposal = api.type.SimpleProposal.new()
		proposal.streetProposal.nodesToAdd = nodeAndEntities
		proposal.streetProposal.edgesToAdd = edgesToAdd
		proposal.streetProposal.edgesToRemove = edgesToRemove
		proposal.streetProposal.nodesToRemove = nodesToRemove
	end
	compCache = nil
	node2segmentsCache = nil
	planRoadType = nil
	local finished = clockMs()
	if finished and timing.start then
		stats.timing = string.format("%.0f ms: orient %.0f, offsets %.0f, crossings %.0f, merges %.0f, emit %.0f, check %.0f",
			finished - timing.start, (timing.firstTrack or timing.start) - timing.start, timing.offsets, timing.crossings, timing.merges,
			checkStart - emitStart, finished - checkStart)
	end
	return proposal, stats
end

-- Identifies a drag and the settings it is planned with, to plan again only when one
-- of them changed. The builder asks about the same drag many times.
local function signatureOf(drawn, ...)
	local parts = {}
	for __, extra in ipairs({ ... }) do
		parts[#parts + 1] = tostring(extra)
	end
	for __, d in ipairs(drawn) do
		local e = d.edge
		parts[#parts + 1] = string.format("%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f",
			e.p0.x, e.p0.y, e.p1.x, e.p1.y, e.t0.x, e.t0.y, e.t1.x, e.t1.y)
	end
	return table.concat(parts, ";")
end

-- Decides when to plan a drag that keeps changing. The builder asks about the drag
-- continuously, also while it holds still. As long as planning is cheap (open ground)
-- every change is planned, so the preview follows the mouse exactly. When it gets
-- expensive (many tracks nearby), only every n-th change is planned while the drag
-- moves, and the drag as soon as it holds still (the same drag asked about twice).
local function newDebounce(every, cheapMs)
	local d = { lastSeen = nil, lastPlanned = nil, skipped = 0, lastCost = nil }
	function d.shouldPlan(signature)
		if signature == d.lastPlanned then
			return false
		end
		if not shared.PERF_MEASURES or d.lastCost == nil or d.lastCost < cheapMs then
			return true
		end
		if signature == d.lastSeen then
			return true
		end
		d.lastSeen = signature
		d.skipped = d.skipped + 1
		return d.skipped >= every
	end
	-- cost: how long planning it took, in ms, if known
	function d.planned(signature, cost)
		d.lastPlanned = signature
		d.lastSeen = signature
		d.skipped = 0
		d.lastCost = cost
	end
	return d
end

local function planToString(plan)
	local function vec(v)
		return string.format("{x=%.4f,y=%.4f,z=%.4f}", v.x, v.y, v.z)
	end
	local parts = {}
	for __, p in ipairs(plan) do
		parts[#parts + 1] = string.format("{entity=%d,node0=%d,node1=%d,p0=%s,p1=%s,t0=%s,t1=%s}",
			p.entity, p.node0, p.node1, vec(p.edge.p0), vec(p.edge.p1), vec(p.edge.t0), vec(p.edge.t1))
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

-- what an entity is, for the log
local function describeEntity(entity)
	local parts = { tostring(entity) }
	local ok = pcall(function()
		local edge = getEdgeComp(entity)
		if edge then
			parts[#parts + 1] = "edge " .. tostring(edge.node0) .. " -> " .. tostring(edge.node1)
				.. " " .. shared.vecToString(edge.position0) .. " -> " .. shared.vecToString(edge.position1)
				.. " " .. tostring(edge.roadTemplate)
			return
		end
		local node = api.engine.getComponent(entity, api.type.ComponentType.BASE_NODE)
		if node then
			parts[#parts + 1] = "node " .. shared.vecToString(node.position)
			return
		end
		local construction = api.engine.getComponent(entity, api.type.ComponentType.CONSTRUCTION)
		if construction then
			parts[#parts + 1] = "construction " .. tostring(construction.fileName)
			return
		end
		parts[#parts + 1] = "(not an edge, node or construction)"
	end)
	if not ok then
		parts[#parts + 1] = "(lookup failed)"
	end
	return table.concat(parts, " ")
end
planner.toEdge = toEdge
planner.getEdgeComp = readEdgeComp
planner.getTrackDistance = getTrackDistance
planner.formatRadius = formatRadius
planner.collectDrawnSegments = collectDrawnSegments
planner.isApplied = isApplied
planner.makeProposal = makeProposal
planner.planToString = planToString
planner.signatureOf = signatureOf
planner.newDebounce = newDebounce
-- while a drag moves and planning it is expensive, plan only every this many changes
planner.PLAN_EVERY = 4
-- planning that takes less than this (ms) counts as cheap: every change is planned
planner.CHEAP_PLAN_MS = 10
planner.clockMs = clockMs
planner.describeEntity = describeEntity

return planner
