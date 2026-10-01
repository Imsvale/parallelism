-- Planning of the tracks next to a drawn one: offset geometry, anchoring on and
-- crossing existing tracks, and the proposal for it. Loaded on both lua states that
-- need it: the game script (building) and the menu (preview).

local shared = require "parallelism_shared.lua"
local geometry = require "parallelism_geometry.lua"

local planner = {}

-- CPU time in milliseconds, for timing logs; nil if the game does not offer it
local function clockMs()
	local ok, t = pcall(os.clock)
	return ok and t and t * 1000 or nil
end

-- an added segment within this distance of a removed one is a leftover of splitting it
local REMNANT_TOLERANCE = 0.25
-- ...and within this for a piece that branches off the drawn chain (see collectDrawnSegments)
local REMNANT_LOOSE_TOLERANCE = 1.0
local DEFAULT_TRACK_DISTANCE = 5.0
-- An existing node this close to where a new one would go is used instead, e.g. the
-- end of the previous drag's parallel, which a smooth continuation meets to within
-- millimeters. Not a way to bend a track onto a node: at 0.5 m that made bumps.
local NODE_SNAP_DISTANCE = 0.1
-- ...in the middle of a run (the offset of a node of the drawn track that is not an end)
local MID_NODE_SNAP_DISTANCE = 0.05
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
-- (the corner lies offset * tan(kink / 2) along the roads: 21 m at 105 degrees for a
-- 16 m road, 39 m at 135; an inside corner that eats a whole edge is refused anyway)
local MITER_MAX_ANGLE = 135.0
-- dev switch: extra roads crossing or branching onto roads. Every plan with such a
-- junction crashed the game so far (map_util.h "it != map.end()", three times, while
-- evaluating the preview), road plans without one did not. Off: such drags are refused.
local ROAD_JUNCTIONS = false
-- give new and touched nodes node configs (lane connections etc.) as the builder does;
-- false: none at all, as before 2026-10-01
local NODE_CONFIGS = true
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
-- Existing track may be reshaped only this much: a node slid onto a crossing (the bit
-- in between changes edge, e.g. a straight-to-curve transition moves a few meters) or
-- crossed pieces joined back. Whole edges are no longer merged on existing track (it
-- drifted off long stretches), except to clear a switch's zone, as the game does.
local EXISTING_MAX_DEVIATION = 0.05
-- a slide onto a crossing that strays more than this tries sliding away from it instead
local SEAM_DEVIATION = 0.005
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

-- The smallest radius the game allows for a track or road type.
local function allowedRadius(templateName)
	local template = getTemplate(templateName)
	if template and template.minCurveRadius and template.minCurveRadius > 0 then
		return template.minCurveRadius
	end
	return template and isStreet(template.roadType) and DEFAULT_MIN_RADIUS_STREET or DEFAULT_MIN_RADIUS
end

-- How far the merge of edges a and b strays from them, or math.huge if it bends tighter
-- than the type allows and than a and b do. One curve can stay close to two and still
-- bend unevenly; such a bump in an existing track made the game refuse later crossings
-- of it (Too Much Curvature on the cut pieces).
local function mergeStray(a, b, merged, templateName)
	local deviation = geometry.mergeDeviation(a, b, merged)
	if deviation > MAX_MERGE_DEVIATION then
		return deviation
	end
	local limit = allowedRadius(templateName)
	local radius = geometry.minRadiusAlong(merged)
	if radius < limit and radius < 0.95 * math.min(geometry.minRadiusAlong(a), geometry.minRadiusAlong(b)) then
		return math.huge
	end
	return deviation
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
-- their template; roads lie side by side as the road builder snaps them: the road's
-- width (the sum of its lanes, sidewalks included) plus shared.ROAD_GAP.
local loggedTrackDistance = {}

local function getTrackDistance(roadTemplate)
	local template = getTemplate(roadTemplate)
	if template and isStreet(template.roadType) then
		local width = 0
		for __, lc in ipairs(template.laneConfigs or {}) do
			width = width + math.abs(lc.width or 0)
		end
		if not loggedTrackDistance[roadTemplate] then
			-- dev aid: whether the game fills trackDistance in for roads (unset in the files)
			loggedTrackDistance[roadTemplate] = true
			shared.log(string.format("road %s: width %.1f, template trackDistance %s", tostring(roadTemplate), width,
				tostring(template.trackDistance)))
		end
		if width > 0 then
			return width + shared.ROAD_GAP
		end
	end
	local distance = template and template.trackDistance
	if distance and distance > 0 then
		return distance
	end
	return DEFAULT_TRACK_DISTANCE
end

-- The width of a road (its lanes, sidewalks included); nil for a track.
local function roadWidth(roadTemplate)
	local template = getTemplate(roadTemplate)
	if not (template and isStreet(template.roadType)) then
		return nil
	end
	local width = 0
	for __, lc in ipairs(template.laneConfigs or {}) do
		width = width + math.abs(lc.width or 0)
	end
	return width > 0 and width or nil
end

-- Distance between the centre lines of neighbours for the Spacing value: for roads the
-- gap between them (default shared.ROAD_GAP), for tracks the distance between their
-- centres (default and minimum the template's).
local function parallelDistance(roadTemplate, spacing)
	local width = roadWidth(roadTemplate)
	if width then
		return width + math.max(0, spacing or shared.ROAD_GAP)
	end
	return math.max(getTrackDistance(roadTemplate), spacing or 0)
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

	-- The builder also reshapes existing track next to its crossings (merges edges into
	-- a re-fitted curve, moves nodes); such a piece can stray further than
	-- REMNANT_TOLERANCE and was taken for drawn (seen in game: the extra tracks branched
	-- off at the crossing and crossed each other). The drawn track is one chain that runs
	-- straight through its nodes, so where three or more pieces meet, the pair that goes
	-- straight through is drawn and the others are remnants if they run along a removed
	-- edge more loosely.
	local changed = true
	while changed do
		changed = false
		local atNode = {}
		for i, d in ipairs(drawn) do
			for __, e in ipairs({ { d.comp.node0, d.edge.t0 }, { d.comp.node1, { x = -d.edge.t1.x, y = -d.edge.t1.y, z = 0 } } }) do
				atNode[e[1]] = atNode[e[1]] or {}
				table.insert(atNode[e[1]], { index = i, dir = e[2] })
			end
		end
		for __, list in pairs(atNode) do
			if #list >= 3 then
				local bestI, bestJ, best = nil, nil, -1
				for i = 1, #list do
					for j = i + 1, #list do
						local through = 180 - geometry.angleBetween(list[i].dir, list[j].dir)
						if best < 0 or through < best then
							bestI, bestJ, best = i, j, through
						end
					end
				end
				for k = #list, 1, -1 do
					local d = drawn[list[k].index]
					if k ~= bestI and k ~= bestJ and geometry.liesOnAny(d.edge, removed, REMNANT_LOOSE_TOLERANCE) then
						table.remove(drawn, list[k].index)
						changed = true
						break
					end
				end
				if changed then
					break
				end
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
local function findExistingNode(position, maxDistance)
	maxDistance = maxDistance or NODE_SNAP_DISTANCE
	local center = api.type.Vec2f.new(position.x, position.y)
	local candidates = api.engine.util.octree.findEntitiesInCircle(center, math.max(maxDistance, 0.01), api.type.ComponentType.BASE_NODE)
	for __, entity in ipairs(candidates) do
		local comp = api.engine.getComponent(entity, api.type.ComponentType.BASE_NODE)
		if comp and geometry.horizontalDistance(plain(comp.position), position) < maxDistance
			and math.abs(comp.position.z - position.z) < NODE_SNAP_HEIGHT then
			return { entity = entity, position = plain(comp.position) }
		end
	end
	return nil
end

-- The node config of a node in the world; nil for one that is not (yet): asking the
-- game about such an entity is an error ("Invalid entity"), e.g. drawn nodes while
-- dragging.
local function worldNodeConfig(node)
	if node < 0 then
		return nil
	end
	local ok, cfg = pcall(function()
		return api.engine.getComponent(node, api.type.ComponentType.BASE_NODE_CONFIG)
	end)
	return ok and cfg or nil
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
	-- options.step: when planning a single track further out (the one-by-one builder),
	-- its offset is several steps (it once snapped onto the neighbour's loose end)
	local step = options.step or math.huge
	if not options.step then
		for __, offset in ipairs(offsets) do
			step = math.min(step, math.abs(offset))
		end
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
	-- dev aid: why nodes were left where they are, kept even without a log (the preview
	-- has none), for the log of a refused plan
	stats.notes = {}
	do
		local userLog = log
		log = function(msg)
			userLog(msg)
			local text = tostring(msg)
			if #stats.notes < 40 and (text:find("kept", 1, true) or text:find("not removed", 1, true)
				or text:find("not moved", 1, true) or text:find("cannot", 1, true) or text:find("could not", 1, true)) then
				stats.notes[#stats.notes + 1] = text
			end
		end
	end

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
	-- every node where we cross or branch off an existing edge (its pieces need room)
	local cutNodes = {}
	local function addSplit(entity, u, node, angle)
		local split = splits[entity]
		if split == nil then
			local comp = getEdgeComp(entity)
			split = { comp = comp, edge = toEdge(comp), cuts = {} }
			splits[entity] = split
		end
		local cut = { u = u, node = node, angle = angle }
		split.cuts[#split.cuts + 1] = cut
		cutNodes[node.entity] = true
		return cut
	end
	-- the cuts of switches (anchors), by their node, to give them their zone once the
	-- track branching off is known
	local anchorCuts = {}

	local drawnEntities = {}
	-- nodes of the drawn road: the builder holds them while dragging, the plan must not
	-- remove them (the game asserted in ProposalStreetGraph::IsNodeLocked)
	local drawnNodes = {}
	local useCount = {}
	for __, d in ipairs(drawn) do
		drawnEntities[d.entity] = true
		drawnNodes[d.node0] = true
		drawnNodes[d.node1] = true
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
	-- loose ends moved to a corner: they are removed, nothing may use them
	local movedAway = {}
	-- our own nodes that became crossing nodes (a crossing right at the node)
	local crossingAtNode = {}
	-- our node -> the drawn node it mirrors, for node configs
	local mirrorOf = {}
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
			if kink < MITER_MIN_ANGLE then
				return nil
			end
			-- the old road's parallel, ending where it would without the kink; never a node
			-- of the drawn road, which the builder holds while dragging
			local loose = findExistingNode(geometry.offsetPoint(position, oldDir, offset))
			local looseSegments = loose and not drawnNodes[loose.entity] and not reusedNodes[loose.entity]
				and getNode2Segments()[loose.entity]
			if not looseSegments or #looseSegments ~= 1 then
				return nil
			end
			local parEntity = looseSegments[1]
			local par = getEdgeComp(parEntity)
			if par == nil or not isPlanned(par) or drawnEntities[parEntity] or splits[parEntity]
				or (par.objects and #par.objects > 0) then
				return nil
			end
			if kink > MITER_MAX_ANGLE then
				-- the corner would lie far off: rather refuse than leave the parallel detached
				stats.sharpCorner = kink
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
			movedAway[loose.entity] = true
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
				-- in the middle of the run only a node practically on the spot: a node of
				-- another track half a meter off pulled the track onto it (seen in game: 7 m
				-- bends in 5 m pieces at leftover nodes of an earlier crossing)
				node = node or findExistingNode(newPosition, useCount[entity] == 2 and MID_NODE_SNAP_DISTANCE or nil)
				if node and movedAway[node.entity] then
					-- a very short drag: its other end lies on the loose end just moved away
					stats.usesRemoved = node.entity
					log("  node " .. entity .. ": existing node " .. node.entity .. " is moved to a corner, not reused")
					node = nil
				end
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
				elseif useCount[entity] == 1 and streets then
					-- an end of the run next to the loose end of a previous parallel: continue
					-- it. Roads only: a road drag can leave a road end at an angle; the track
					-- builder always continues smoothly, so a track's offset meets the old end
					-- exactly, and snapping further only bends the track.
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
				if not anchorCuts[node.entity] then
					-- gets the node config the builder made for the drawn node
					mirrorOf[node.entity] = entity
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
		-- (own node .. ":" .. existing edge) of crossings made at one of our nodes
		local crossingNodes = {}
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
						-- (a crossing right at one of our own nodes, at the end of both offset
						-- edges there, is not reported here at all; see below)
						-- A crossing right at a plain node of the other track (two edges of one
						-- track meet there, e.g. a leftover of an earlier crossing): cut just
						-- inside the edge; the node is then merged away as for any cut next to
						-- it, and the crossing placed on the merged curve. Once per node.
						local plainNode = nil
						if math.abs(x.pointA.z - x.pointB.z) < NODE_SNAP_HEIGHT
							and isAwayFromEnds(oe.edge, x.pointA) and not isAwayFromEnds(other, x.pointB) then
							local n = geometry.horizontalDistance(x.pointB, other.p0) <= EDGE_END_DISTANCE and comp.node0 or comp.node1
							local segments = getNode2Segments()[n]
							if segments and #segments == 2 and not drawnNodes[n] and not reusedNodes[n]
								and not crossingNodes["w" .. n .. ":" .. tostring(oe)] then
								plainNode = n
							end
						end
						if plainNode then
							crossingNodes["w" .. plainNode .. ":" .. tostring(oe)] = true
							if noJunctions then
								stats.junctions = stats.junctions + 1
							elseif angle < MIN_CROSSING_ANGLE then
								stats.shallow = stats.shallow + 1
							else
								local node = newNode(x.pointA)
								local u = math.max(0.001, math.min(0.999, x.ub))
								oe.cuts[#oe.cuts + 1] = { u = x.ua, node = node, angle = angle, entity = entity }
								addSplit(entity, u, node, angle)
								stats.crossings = stats.crossings + 1
								log("  crossing edge " .. entity .. string.format(" at its plain node %d, %.1f deg ", plainNode, angle) .. shared.vecToString(x.pointA))
							end
						elseif math.abs(x.pointA.z - x.pointB.z) < NODE_SNAP_HEIGHT
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
								oe.cuts[#oe.cuts + 1] = { u = x.ua, node = node, angle = angle, entity = entity }
								addSplit(entity, x.ub, node, angle)
								stats.crossings = stats.crossings + 1
								log("  crossing edge " .. entity .. string.format(" at u = %.3f, %.1f deg ", x.ub, angle) .. shared.vecToString(x.pointA))
							end
						end
					end
				end
			end
		end

		-- An existing track running through one of our own nodes in the middle of the run:
		-- the intersection search misses a crossing right at the end of both edges there
		-- (seen twice in game: the track ran through the other one, Collision). Checked
		-- here by distance; the node becomes the crossing node, moved exactly onto the
		-- crossing first: a crossing node has to lie on both tracks. Left where it was (up
		-- to 0.15 m off), the 5 m pieces cut from the other track bent to meet it (seen in
		-- game: 30 m bends in a 75 m arc).

		-- signed horizontal distance of p from the edge (positive: to its left)
		local function signedDistance(p, other)
			local u = geometry.closestParameter(p, other)
			local w = geometry.hermite(other.p0, other.p1, other.t0, other.t1, u)
			local t = geometry.hermiteDerivative(other.p0, other.p1, other.t0, other.t1, u)
			local d = geometry.horizontalDistance(p, w)
			return (t.x * (p.y - w.y) - t.y * (p.x - w.x)) >= 0 and d or -d
		end
		-- Moves the own node (between two offset edges) along our track onto the point
		-- where it crosses other: only the short bit in between changes edge. Returns
		-- the point, or nil if the crossing is not within a meter or the edges would bend.
		local function snapOntoCrossing(node, other)
			local a, b = nil, nil
			for __, oe in ipairs(offsetEdges) do
				if oe.node1.entity == node.entity then
					a = oe
				elseif oe.node0.entity == node.entity then
					b = oe
				end
			end
			if a == nil or b == nil then
				return nil
			end
			-- s in [-1, 0] runs back along a, [0, 1] on along b, about a meter each way
			local spanA = math.min(0.5, 1 / math.max(1, geometry.arcLength(a.edge)))
			local spanB = math.min(0.5, 1 / math.max(1, geometry.arcLength(b.edge)))
			local function pointAt(s)
				if s < 0 then
					return geometry.hermite(a.edge.p0, a.edge.p1, a.edge.t0, a.edge.t1, 1 + s * spanA)
				end
				return geometry.hermite(b.edge.p0, b.edge.p1, b.edge.t0, b.edge.t1, s * spanB)
			end
			local lo, hi = -1, 1
			local fLo = signedDistance(pointAt(lo), other)
			if fLo * signedDistance(pointAt(hi), other) > 0 then
				return nil
			end
			for __ = 1, 40 do
				local mid = (lo + hi) / 2
				local fMid = signedDistance(pointAt(mid), other)
				if (fMid >= 0) == (fLo >= 0) then
					lo, fLo = mid, fMid
				else
					hi = mid
				end
			end
			local s = (lo + hi) / 2
			local newA, newB, short, merged, mergeA, mergeB
			if s < 0 then
				newA, short = geometry.split(a.edge, 1 + s * spanA)
				merged = geometry.merge(short, b.edge)
				newB, mergeA, mergeB = merged, short, b.edge
			else
				short, newB = geometry.split(b.edge, s * spanB)
				merged = geometry.merge(a.edge, short)
				newA, mergeA, mergeB = merged, a.edge, short
			end
			if mergeStray(mergeA, mergeB, merged, templateOf(a.props)) > MAX_MERGE_DEVIATION then
				return nil
			end
			local point = pointAt(s)
			a.edge, b.edge = newA, newB
			node.position = { x = point.x, y = point.y, z = node.position.z }
			return node.position
		end

		for __, oe in ipairs(offsetEdges) do
			for which, node in ipairs({ oe.node0, oe.node1 }) do
				if movable[node.entity] and not crossingAtNode[node.entity] then
					local center = api.type.Vec2f.new(node.position.x, node.position.y)
					for __, entity in ipairs(api.engine.util.octree.findEntitiesInCircle(center, EDGE_SEARCH_RADIUS, api.type.ComponentType.BASE_EDGE)) do
						local comp = not drawnEntities[entity] and getEdgeComp(entity) or nil
						if comp and isPlanned(comp) and not crossingNodes[node.entity .. ":" .. entity] then
							local other = worldEdges[entity] or toEdge(comp)
							local u, distance = geometry.closestParameter(node.position, other)
							local point = geometry.hermite(other.p0, other.p1, other.t0, other.t1, u)
							-- a crossing already found near the node, with this edge
							local found = false
							for __, e in ipairs(offsetEdges) do
								for __, cut in ipairs(e.cuts) do
									if cut.entity == entity and geometry.horizontalDistance(cut.node.position, node.position) < 1 then
										found = true
									end
								end
							end
							if not found and distance < 0.15 and isAwayFromEnds(other, point)
								and math.abs(point.z - node.position.z) < NODE_SNAP_HEIGHT then
								crossingNodes[node.entity .. ":" .. entity] = true
								local angle = geometry.crossingAngle(oe.edge, which == 1 and 0 or 1, other, u)
								if noJunctions then
									stats.junctions = stats.junctions + 1
								elseif angle < MIN_CROSSING_ANGLE then
									stats.shallow = stats.shallow + 1
								elseif snapOntoCrossing(node, other) then
									u = geometry.closestParameter(node.position, other)
									movable[node.entity] = nil
									crossingAtNode[node.entity] = true
									addSplit(entity, u, node, angle)
									stats.crossings = stats.crossings + 1
									log("  crossing edge " .. entity .. string.format(" at u = %.3f, %.1f deg, through own node %d ", u, angle, node.entity)
										.. shared.vecToString(node.position))
								else
									-- not without bending: the track would run through the other one
									stats.missedCrossing = string.format("a crossing at own node %d could not be placed", node.entity)
									log("  " .. stats.missedCrossing)
								end
								break
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
						-- a crossing at the far end of the edge counts too: since nodes slide
						-- onto crossings, edges often end at one (seen in game: an own node
						-- kept 0.96 m from a crossing, the game refused the piece)
						local far = oe.node0.entity == entity and oe.node1 or oe.node0
						if cutNodes[far.entity] or crossingAtNode[far.entity] then
							local d = geometry.horizontalDistance(far.position, position)
							nearest = math.min(nearest, d)
							if d < MIN_PIECE_LENGTH then
								tooClose = true
							end
						end
					end
					local slid = false
					if tooClose
						and a.props.comp.type == b.props.comp.type and a.props.comp.typeIndex == b.props.comp.typeIndex then
						if a.node1.entity ~= entity then
							a = reversed(a)
						end
						if b.node0.entity ~= entity then
							b = reversed(b)
						end
						-- First choice: slide the node onto the nearest crossing. Only the short
						-- bit between node and crossing is merged into the edge beyond the node,
						-- the rest keeps its exact shape (merging the two whole edges bent the
						-- track too much and strayed metres, seen in game: Too Much Curvature).
						local nearestCut, onB = nil, false
						for __, side in ipairs({ { a, false }, { b, true } }) do
							for __, cut in ipairs(side[1].cuts) do
								if nearestCut == nil or geometry.horizontalDistance(cut.node.position, position)
									< geometry.horizontalDistance(nearestCut.node.position, position) then
									nearestCut, onB = cut, side[2]
								end
							end
						end
						if nearestCut then
							local newA, newB, short, mergedPart, merged
							if onB then
								local u = geometry.closestParameter(nearestCut.node.position, b.edge)
								short, newB = geometry.split(b.edge, u)
								merged = geometry.merge(a.edge, short)
								mergedPart = { a.edge, short }
								newA = merged
							else
								local u = geometry.closestParameter(nearestCut.node.position, a.edge)
								newA, short = geometry.split(a.edge, u)
								merged = geometry.merge(short, b.edge)
								mergedPart = { short, b.edge }
								newB = merged
							end
							if mergeStray(mergedPart[1], mergedPart[2], merged, templateOf(a.props)) <= MAX_MERGE_DEVIATION then
								local joint = nearestCut.node
								local edgeA = { node0 = a.node0, node1 = joint, edge = newA, props = a.props, cuts = {} }
								local edgeB = { node0 = joint, node1 = b.node1, edge = newB, props = a.props, cuts = {} }
								-- the other cuts go to whichever new edge they lie on
								for __, side in ipairs({ a, b }) do
									for __, cut in ipairs(side.cuts) do
										if cut ~= nearestCut then
											local __, da = geometry.closestParameter(cut.node.position, newA)
											local __, db = geometry.closestParameter(cut.node.position, newB)
											table.insert(da <= db and edgeA.cuts or edgeB.cuts, cut)
										end
									end
								end
								offsetEdges[at[1]] = edgeA
								offsetEdges[at[2]] = edgeB
								dropped[entity] = true
								stats.dropped = stats.dropped + 1
								log(string.format("  own node %d is %.2f m from a crossing, moved it onto the crossing", entity, nearest))
								merging = true
								slid = true
							end
						end
					end
					if slid then
						break
					end
					if tooClose
						and a.props.comp.type == b.props.comp.type and a.props.comp.typeIndex == b.props.comp.typeIndex then
						-- one curve cannot follow every shape two can (e.g. a long stretch of a
						-- tight spiral): keep the node if the merged curve would stray
						local merged = geometry.merge(a.edge, b.edge)
						local deviation = mergeStray(a.edge, b.edge, merged, templateOf(a.props))
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
		-- Dropping or sliding our own nodes merged our edges, which may stray from the old
		-- curve; the crossing nodes on them were placed on the old one. Put each where our
		-- edge now crosses the existing one, a node off the curve bends the pieces next to
		-- it (seen in game: the crossing point drifted along the crossed track).
		for __, oe in ipairs(offsetEdges) do
			for __, cut in ipairs(oe.cuts) do
				local comp = cut.entity and getEdgeComp(cut.entity)
				if comp then
					local other = worldEdges[cut.entity] or toEdge(comp)
					local best = nil
					for __, x in ipairs(geometry.intersections(oe.edge, other)) do
						local d = geometry.horizontalDistance(x.pointA, cut.node.position)
						if d < 1 and (best == nil or d < best.d) then
							best = { d = d, point = x.pointA }
						end
					end
					if best and best.d > 1e-4 then
						cut.node.position = { x = best.point.x, y = best.point.y, z = cut.node.position.z }
					end
				end
			end
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
	-- every edge added, with the existing edges it replaces (origins), for node configs
	local pieces = {}

	local function addSegment(node0, node1, piece, props)
		local entity = nextEdgeId
		nextEdgeId = nextEdgeId - 1
		stats.plan[#stats.plan + 1] = {
			entity = entity,
			node0 = node0.entity,
			node1 = node1.entity,
			edge = { p0 = node0.position, p1 = node1.position, t0 = piece.t0, t1 = piece.t1 },
		}
		pieces[#pieces + 1] = { entity = entity, node0 = node0.entity, node1 = node1.entity, t0 = piece.t0, t1 = piece.t1,
			origins = props.origins, template = templateOf(props) }
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
		-- the track type's trackDistance on native track (0 on roads), wherever the track
		-- lies; with 0 neighbouring tracks do not share catenary masts as they should
		pcall(function()
			segment.comp.distance = props.comp.distance
		end)
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
			-- (also an edge with no cut of its own that ends at a crossing: own nodes slide
			-- onto crossings, then edges run crossing to crossing; seen in game: 1.35 m)
			if #chain > 2 or cutNodes[chain[i].entity] or cutNodes[chain[i + 1].entity] then
				local length = geometry.arcLength({ p0 = chain[i].position, p1 = chain[i + 1].position, t0 = piece.t0, t1 = piece.t1 })
				if length < MIN_PIECE_LENGTH - PIECE_TOLERANCE and not stats.shortPiece then
					stats.shortPiece = string.format("a piece of %.1f m next to a crossing or branch at %s, the game needs %.0f m",
						length, shared.vecToString(chain[i].position), MIN_PIECE_LENGTH)
					stats.problemAt = chain[i].position
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

		if drawnNodes[endNode.entity] then
			log(prefix .. ", a node of the drawn road, not moved")
			return
		end
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
		local far
		if which == 0 then
			-- other runs far node -> end node
			if otherComp.node1 == endNode.entity then
				far = { entity = otherComp.node0, position = otherEdge.p0 }
			else
				otherEdge = geometry.reverse(otherEdge)
				far = { entity = otherComp.node1, position = otherEdge.p0 }
			end
		else
			-- other runs end node -> far node
			if otherComp.node0 == endNode.entity then
				far = { entity = otherComp.node1, position = otherEdge.p1 }
			else
				otherEdge = geometry.reverse(otherEdge)
				far = { entity = otherComp.node0, position = otherEdge.p1 }
			end
		end

		-- First choice: slide the plain node onto the nearest crossing. A node in the middle
		-- of a track may sit anywhere along it; the crossing may not. The crossing becomes
		-- the end of this piece, the short bit beyond it goes to the neighbouring edge, and
		-- the rest of the track keeps its exact shape (merging the two whole edges reshaped
		-- long stretches). Not for switches: a switch needs its whole zone clear of nodes.
		local nearestCut = nil
		for __, cut in ipairs(part.cuts) do
			if nearestCut == nil or geometry.horizontalDistance(cut.node.position, endNode.position)
				< geometry.horizontalDistance(nearestCut.node.position, endNode.position) then
				nearestCut = cut
			end
		end
		local slideNote = nil
		if nearestCut and nearestCut.zone == nil then
			local u = geometry.closestParameter(nearestCut.node.position, part.edge)
			local keep, short
			if which == 0 then
				short, keep = geometry.split(part.edge, u)
			else
				keep, short = geometry.split(part.edge, u)
			end
			local shortLength = geometry.arcLength(short)
			local template = part.comp.roadTemplate

			-- (a) onto the crossing: the bit beyond joins the neighbouring edge
			local ontoEdge = which == 0 and geometry.merge(otherEdge, short) or geometry.merge(short, otherEdge)
			local ontoStray = which == 0 and mergeStray(otherEdge, short, ontoEdge, template)
				or mergeStray(short, otherEdge, ontoEdge, template)

			-- (b) away from it, just far enough along the neighbouring edge: the bit and the
			-- start of the neighbour become one piece of minimum length, the rest of the
			-- neighbour stays exactly as it is. At a seam (a straight meeting a curve) one
			-- long curve for (a) strays centimeters, one short piece only millimeters.
			local awayPiece, awayRest, awayPoint, awayStray = nil, nil, nil, math.huge
			local need = minPieceLength(nearestCut) + 0.5 - shortLength
			local otherLength = geometry.arcLength(otherEdge)
			if need > 0 and otherLength - need >= MIN_PIECE_LENGTH then
				if which == 0 then
					-- other runs far -> node: the new node lies need short of its end
					local v = geometry.parameterAtLength(otherEdge, otherLength - need)
					local rest, near = geometry.split(otherEdge, v)
					awayPiece = geometry.merge(near, short)
					awayRest = rest
					awayStray = mergeStray(near, short, awayPiece, template)
				else
					local v = geometry.parameterAtLength(otherEdge, need)
					local near, rest = geometry.split(otherEdge, v)
					awayPiece = geometry.merge(short, near)
					awayRest = rest
					awayStray = mergeStray(short, near, awayPiece, template)
				end
				awayPoint = which == 0 and awayRest.p1 or awayRest.p0
			end

			local function fmt(x)
				return x == math.huge and "no" or string.format("%.3f m", x)
			end
			slideNote = string.format(" (bit %.2f m; onto the crossing strays %s, away from it %s; node %.3f m off the track)",
				shortLength, fmt(ontoStray), fmt(awayStray),
				geometry.horizontalDistance(geometry.hermite(part.edge.p0, part.edge.p1, part.edge.t0, part.edge.t1, u), nearestCut.node.position))

			-- onto the crossing when it is (nearly) exact, it needs no node; else the smaller
			local useAway = awayPiece ~= nil and ontoStray > SEAM_DEVIATION and awayStray < ontoStray
			local stray = useAway and awayStray or ontoStray
			if stray <= EXISTING_MAX_DEVIATION then
				local joint = nearestCut.node
				part.edge = keep
				if which == 0 then
					part.node0 = joint
				else
					part.node1 = joint
				end
				if useAway then
					local moved = newNode({ x = awayPoint.x, y = awayPoint.y, z = awayPoint.z })
					if which == 0 then
						part.extra[#part.extra + 1] = { node0 = far, node1 = moved, edge = awayRest, origins = { other } }
						part.extra[#part.extra + 1] = { node0 = moved, node1 = joint, edge = awayPiece, origins = { other } }
					else
						part.extra[#part.extra + 1] = { node0 = joint, node1 = moved, edge = awayPiece, origins = { other } }
						part.extra[#part.extra + 1] = { node0 = moved, node1 = far, edge = awayRest, origins = { other } }
					end
				elseif which == 0 then
					part.extra[#part.extra + 1] = { node0 = far, node1 = joint, edge = ontoEdge, origins = { other } }
				else
					part.extra[#part.extra + 1] = { node0 = joint, node1 = far, edge = ontoEdge, origins = { other } }
				end
				for i, cut in ipairs(part.cuts) do
					if cut == nearestCut then
						table.remove(part.cuts, i)
						break
					end
				end
				part.endEdge[which] = nil
				part.removeEdges[#part.removeEdges + 1] = other
				part.removeNodes[#part.removeNodes + 1] = endNode.entity
				stats.moved = stats.moved + 1
				log(prefix .. (useAway and ", moved it away from the crossing" or ", moved it onto the crossing") .. slideNote)
				-- the end is now the crossing, nothing more to clear on this side
				return false
			end
		end

		if not (nearestCut and nearestCut.zone ~= nil) then
			-- no whole-edge merge on existing track for a crossing: the piece stays short and
			-- the plan is refused
			log(prefix .. ", not removed: sliding it onto the crossing would reshape the track" .. (slideNote or ""))
			return
		end
		local merged
		if which == 0 then
			merged = geometry.merge(otherEdge, part.edge)
		else
			merged = geometry.merge(part.edge, otherEdge)
		end
		-- one curve cannot follow every shape two can: rather keep the node than bend the track
		local deviation = mergeStray(part.edge, otherEdge, merged, part.comp.roadTemplate)
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

	-- Joins the neighbouring edge at one end of a part into it when that edge is crossed
	-- too (has cuts of its own) and a cut on either is too close to the plain node between
	-- them. A track crossed before keeps a node at every old crossing, about a crossing's
	-- spacing apart; new crossings then land next to them on both sides (seen in game: a
	-- whole grid refused for short pieces). Those nodes lie on one curve, so the join
	-- restores it. Returns true if it joined one.
	-- the offset edge with a cut at the node (a crossing node of ours), lazily indexed
	local offsetEdgeByCutNode = nil
	local function offsetEdgeAt(nodeEntity)
		if offsetEdgeByCutNode == nil then
			offsetEdgeByCutNode = {}
			for __, offsetEdges in ipairs(tracks) do
				for __, oe in ipairs(offsetEdges) do
					for __, cut in ipairs(oe.cuts) do
						offsetEdgeByCutNode[cut.node.entity] = oe
					end
				end
			end
		end
		return offsetEdgeByCutNode[nodeEntity]
	end

	local consumed = {}
	local function absorbNeighbour(part, which)
		local endNode = which == 0 and part.node0 or part.node1
		if reusedNodes[endNode.entity] or drawnNodes[endNode.entity] then
			return false
		end
		local tooClose = false
		local function check(cuts)
			for __, cut in ipairs(cuts) do
				if geometry.horizontalDistance(cut.node.position, endNode.position) < minPieceLength(cut) then
					tooClose = true
				end
			end
		end
		node2segments = node2segments or getNode2Segments()
		local segments = node2segments[endNode.entity]
		if segments == nil or #segments ~= 2 then
			return false
		end
		local own = part.endEdge[which]
		local other = segments[1] == own and segments[2] or segments[1]
		local split = splits[other]
		if split == nil or consumed[other] or drawnEntities[other] then
			return false
		end
		local otherComp = split.comp
		if otherComp.roadTemplate ~= part.comp.roadTemplate or otherComp.type ~= part.comp.type
			or (otherComp.objects and #otherComp.objects > 0) then
			return false
		end
		check(part.cuts)
		check(split.cuts)
		if not tooClose then
			return false
		end
		local otherEdge = toEdge(otherComp)
		local merged, far
		if which == 0 then
			if otherComp.node1 == endNode.entity then
				far = { entity = otherComp.node0, position = otherEdge.p0 }
			else
				otherEdge = geometry.reverse(otherEdge)
				far = { entity = otherComp.node1, position = otherEdge.p0 }
			end
			merged = geometry.merge(otherEdge, part.edge)
		else
			if otherComp.node0 == endNode.entity then
				far = { entity = otherComp.node1, position = otherEdge.p1 }
			else
				otherEdge = geometry.reverse(otherEdge)
				far = { entity = otherComp.node0, position = otherEdge.p1 }
			end
			merged = geometry.merge(part.edge, otherEdge)
		end
		local deviation = which == 0 and mergeStray(otherEdge, part.edge, merged, part.comp.roadTemplate)
			or mergeStray(part.edge, otherEdge, merged, part.comp.roadTemplate)
		if deviation > EXISTING_MAX_DEVIATION then
			-- Not one curve (e.g. a straight meeting a curve): slide the node onto the
			-- nearest crossing instead. The short bit between them changes edge, the rest
			-- of both edges keeps its shape, and the neighbour keeps its own crossings
			-- (seen in game: a leftover node 0.5 m from a crossing, both edges crossed).
			local nearestCut, onOther = nil, false
			for __, side in ipairs({ { part.cuts, false }, { split.cuts, true } }) do
				for __, cut in ipairs(side[1]) do
					if nearestCut == nil or geometry.horizontalDistance(cut.node.position, endNode.position)
						< geometry.horizontalDistance(nearestCut.node.position, endNode.position) then
						nearestCut, onOther = cut, side[2]
					end
				end
			end
			if nearestCut == nil or nearestCut.zone ~= nil then
				log(string.format("  node %d between crossed edges %d and %d kept: joining would stray %.2f m", endNode.entity, own, other, deviation))
				return false
			end
			-- which == 1: part runs ... -> node, other runs node -> far; which == 0 mirrored
			local newPart, newOther, mergeA, mergeB, merged2
			if not onOther then
				local u = geometry.closestParameter(nearestCut.node.position, part.edge)
				local keep, short
				if which == 1 then
					keep, short = geometry.split(part.edge, u)
					merged2 = geometry.merge(short, otherEdge)
					mergeA, mergeB = short, otherEdge
				else
					short, keep = geometry.split(part.edge, u)
					merged2 = geometry.merge(otherEdge, short)
					mergeA, mergeB = otherEdge, short
				end
				newPart, newOther = keep, merged2
			else
				local u = geometry.closestParameter(nearestCut.node.position, otherEdge)
				local short, rest
				if which == 1 then
					short, rest = geometry.split(otherEdge, u)
					merged2 = geometry.merge(part.edge, short)
					mergeA, mergeB = part.edge, short
				else
					rest, short = geometry.split(otherEdge, u)
					merged2 = geometry.merge(short, part.edge)
					mergeA, mergeB = short, part.edge
				end
				newPart, newOther = merged2, rest
			end
			local slideDeviation = mergeStray(mergeA, mergeB, merged2, part.comp.roadTemplate)
			if slideDeviation > EXISTING_MAX_DEVIATION then
				log(string.format("  node %d between crossed edges %d and %d kept: joining would stray %.2f m, sliding %.2f m",
					endNode.entity, own, other, deviation, slideDeviation))
				return false
			end
			local joint = nearestCut.node
			local otherCuts = {}
			for __, cut in ipairs(split.cuts) do
				if cut ~= nearestCut then
					otherCuts[#otherCuts + 1] = cut
				end
			end
			for i, cut in ipairs(part.cuts) do
				if cut == nearestCut then
					table.remove(part.cuts, i)
					break
				end
			end
			consumed[other] = true
			part.edge = newPart
			if which == 1 then
				part.node1 = joint
				part.extra[#part.extra + 1] = { node0 = joint, node1 = far, edge = newOther, origins = { other }, cuts = otherCuts }
			else
				part.node0 = joint
				part.extra[#part.extra + 1] = { node0 = far, node1 = joint, edge = newOther, origins = { other }, cuts = otherCuts }
			end
			part.endEdge[which] = nil
			part.removeEdges[#part.removeEdges + 1] = other
			part.removeNodes[#part.removeNodes + 1] = endNode.entity
			stats.moved = stats.moved + 1
			log(string.format("  node %d between crossed edges %d and %d moved onto the crossing", endNode.entity, own, other))
			-- the end is now the crossing, nothing more to join on this side
			return false
		end
		consumed[other] = true
		part.edge = merged
		if which == 0 then
			part.node0 = far
		else
			part.node1 = far
		end
		part.endEdge[which] = other
		part.removeEdges[#part.removeEdges + 1] = other
		part.removeNodes[#part.removeNodes + 1] = endNode.entity
		for __, cut in ipairs(split.cuts) do
			part.cuts[#part.cuts + 1] = cut
		end
		stats.moved = stats.moved + 1
		log(string.format("  joined crossed edges %d and %d, removing node %d next to a crossing", own, other, endNode.entity))
		return true
	end

	local segmentType = drawn[1].segmentType
	local splitEntities = {}
	for entity in pairs(splits) do
		splitEntities[#splitEntities + 1] = entity
	end
	table.sort(splitEntities)
	for __, entity in ipairs(splitEntities) do
		local split = splits[entity]
		local objects = split.comp.objects
		if consumed[entity] then
			-- joined into a neighbour's part
		elseif objects and #objects > 0 then
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
				-- neighbouring edges that took over a bit of this one (a node slid onto a
				-- crossing): { node0, node1, edge, origins }
				extra = {},
			}
			consumed[entity] = true
			for __, which in ipairs({ 0, 1 }) do
				for __ = 1, 20 do
					if not absorbNeighbour(part, which) then
						break
					end
				end
			end
			clearEnd(part, 0)
			clearEnd(part, 1)
			if #part.removeNodes > 0 then
				-- The curve changed (joined or merged, a little off the old one):
				-- move each crossing node to where our track crosses the new curve, a
				-- node off the curve makes the short pieces next to it bend to meet it.
				for __, cut in ipairs(part.cuts) do
					local ours = offsetEdgeAt(cut.node.entity)
					local best = nil
					if ours then
						for __, x in ipairs(geometry.intersections(ours.edge, part.edge)) do
							local d = geometry.horizontalDistance(x.pointA, cut.node.position)
							if d < 1 and (best == nil or d < best.d) then
								best = { d = d, point = x.pointA, u = x.ub }
							end
						end
					end
					if best then
						cut.node.position = { x = best.point.x, y = best.point.y, z = cut.node.position.z }
						cut.u = best.u
					else
						cut.u = geometry.closestParameter(cut.node.position, part.edge)
					end
				end
			else
				-- the crossing nodes may have moved onto our merged edges since they were cut
				for __, cut in ipairs(part.cuts) do
					cut.u = geometry.closestParameter(cut.node.position, part.edge)
				end
			end
			addCut(part.edge, part.node0, part.node1, part.cuts,
				{ comp = split.comp, segmentType = segmentType, playerOwned = getPlayerOwned(entity), origins = part.removeEdges })
			for __, x in ipairs(part.extra) do
				local props = { comp = split.comp, segmentType = segmentType, playerOwned = getPlayerOwned(entity), origins = x.origins }
				if x.cuts and #x.cuts > 0 then
					-- a crossed neighbour that took over a bit of this edge: its own crossings
					for __, cut in ipairs(x.cuts) do
						cut.u = geometry.closestParameter(cut.node.position, x.edge)
					end
					addCut(x.edge, x.node0, x.node1, x.cuts, props)
				else
					addSegment(x.node0, x.node1, x.edge, props)
					local length = geometry.arcLength({ p0 = x.node0.position, p1 = x.node1.position, t0 = x.edge.t0, t1 = x.edge.t1 })
					if length < MIN_PIECE_LENGTH - PIECE_TOLERANCE and not stats.shortPiece then
						stats.shortPiece = string.format("a piece of %.1f m next to a crossing at %s, the game needs %.0f m",
							length, shared.vecToString(x.node0.position), MIN_PIECE_LENGTH)
						stats.problemAt = x.node0.position
					end
				end
			end
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
		addSegment(r.node0, r.node1, r.edge,
			{ comp = r.comp, segmentType = segmentType, playerOwned = getPlayerOwned(r.entity), origins = { r.entity } })
		edgesToRemove[#edgesToRemove + 1] = r.entity
		nodesToRemove[#nodesToRemove + 1] = r.looseNode
		stats.moved = stats.moved + 1
	end

	for __, offsetEdges in ipairs(tracks) do
		for __, oe in ipairs(offsetEdges) do
			-- crossing nodes may have moved onto a merged existing track, see above
			for __, cut in ipairs(oe.cuts) do
				cut.u = geometry.closestParameter(cut.node.position, oe.edge)
			end
			addCut(oe.edge, oe.node0, oe.node1, oe.cuts, oe.props)
			stats.edges = stats.edges + 1
		end
	end

	-- A plan with a track bending at one of its nodes must not reach the game: at a
	-- crossing that crashes it. Callers check stats.problems.
	stats.removedEdges = edgesToRemove
	-- dev aid (options.wireframe): every edge of the plan, for a wireframe view of it:
	-- { edge, kind } with kind "drawn" (as collected from the builder), "ours" (new
	-- track), "existing" (an existing edge cut or reshaped and added again), "removed"
	if options.wireframe then
		local list = {}
		for __, d in ipairs(drawn) do
			list[#list + 1] = { edge = d.edge, kind = "drawn" }
		end
		for __, entity in ipairs(edgesToRemove) do
			local comp = getEdgeComp(entity)
			if comp then
				list[#list + 1] = { edge = toEdge(comp), kind = "removed" }
			end
		end
		for i, p in ipairs(pieces) do
			if stats.plan[i] then
				list[#list + 1] = { edge = stats.plan[i].edge, kind = p.origins and "existing" or "ours" }
			end
		end
		stats.wireframe = list
	end
	stats.removedNodes = nodesToRemove
	local checkStart = clockMs()
	stats.problems = geometry.checkPlan(stats.plan, nil, corners)
	-- A drag turning in on itself makes the extra edges cross the drawn ones or each
	-- other. Those crossings are not planned (no shared node), so the game would get two
	-- edges running through each other.
	if stats.shortPiece then
		table.insert(stats.problems, 1, stats.shortPiece)
	end
	-- The plan must not build on a node it removes: the game asserts on that
	-- (ProposalStreetGraph::IsNodeLocked, seen on a very short drag at a corner).
	do
		local removedSet = {}
		for __, n in ipairs(nodesToRemove) do
			removedSet[n] = true
		end
		for __, p in ipairs(stats.plan) do
			if removedSet[p.node0] or removedSet[p.node1] then
				stats.usesRemoved = removedSet[p.node0] and p.node0 or p.node1
				break
			end
		end
	end
	if stats.usesRemoved then
		table.insert(stats.problems, 1, string.format("the plan uses node %d, which it removes", stats.usesRemoved))
	end
	if stats.missedCrossing then
		table.insert(stats.problems, 1, stats.missedCrossing)
	end
	if stats.sharpCorner then
		table.insert(stats.problems, 1, string.format("the road turns %.0f deg at the end of a parallel, more than %.0f", stats.sharpCorner, MITER_MAX_ANGLE))
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
	-- The radius above takes each offset edge for an arc, from its ends. Merged edges
	-- (dropped own nodes, moved nodes) can bend tighter in between, so sample the edges
	-- we shape: our own pieces and merged existing edges, not plain cuts of existing ones.
	for i, p in ipairs(pieces) do
		local e = stats.plan[i] and stats.plan[i].edge
		if e and (p.origins == nil or #p.origins > 1) then
			stats.minRadius = math.min(stats.minRadius, geometry.minRadiusAlong(e))
		elseif e and not stats.existingBend then
			-- a plain cut of an existing track keeps its shape, but the game judges the
			-- pieces again: a bend there tighter than its own type allows gets the plan
			-- refused (Too Much Curvature)
			local radius = geometry.minRadiusAlong(e)
			local limit = allowedRadius(p.template)
			if radius < limit then
				stats.existingBend = string.format("an existing track is cut where it bends at %.1f m radius, its type needs %.0f m", radius, limit)
			end
		end
	end
	if stats.existingBend then
		table.insert(stats.problems, 1, stats.existingBend)
		log("  plan problem: " .. stats.existingBend)
	end
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

	-- Node configs (lane connections, crosswalks, traffic light preference), as the
	-- builder makes them: our nodes copy the config of the drawn node they mirror, and
	-- existing nodes at the ends of edges we replace get theirs rewritten to the new
	-- pieces. Without the rewrite those configs name edges that no longer exist.
	-- Returns the configs to add and the nodes whose config they replace.
	local function makeNodeConfigs()
		local function set(list)
			local s = {}
			for __, v in ipairs(list) do
				s[v] = true
			end
			return s
		end
		local removedEdges, removedNodes = set(edgesToRemove), set(nodesToRemove)
		local newNodes = {}
		for __, n in ipairs(nodesToAdd) do
			newNodes[n.entity] = true
		end
		local function neg(v)
			return { x = -v.x, y = -v.y, z = -v.z }
		end
		-- the edges at each node after the build: { entity, dir (leaving the node), origins }
		local atNode = {}
		local function addAt(node, entry)
			atNode[node] = atNode[node] or {}
			table.insert(atNode[node], entry)
		end
		for __, p in ipairs(pieces) do
			addAt(p.node0, { entity = p.entity, dir = p.t0, origins = p.origins })
			addAt(p.node1, { entity = p.entity, dir = neg(p.t1), origins = p.origins })
		end
		-- existing edges at a node, but those left out
		local function worldAt(node, leaveOut)
			local result = {}
			for __, s in ipairs(getNode2Segments()[node] or {}) do
				if not leaveOut[s] then
					local comp = readEdgeComp(s)
					if comp then
						result[#result + 1] = { entity = s, dir = comp.node0 == node and plain(comp.tangent0) or neg(plain(comp.tangent1)) }
					end
				end
			end
			return result
		end
		-- the edges at each drawn node: drawn ones and existing ones
		local drawnAt = {}
		for __, d in ipairs(drawn) do
			drawnAt[d.node0] = drawnAt[d.node0] or {}
			drawnAt[d.node1] = drawnAt[d.node1] or {}
			table.insert(drawnAt[d.node0], { entity = d.entity, dir = d.edge.t0 })
			table.insert(drawnAt[d.node1], { entity = d.entity, dir = neg(d.edge.t1) })
		end
		local function sourceConfig(node)
			local given = options.nodeConfigs and options.nodeConfigs[node]
			if given then
				return given
			end
			return worldNodeConfig(node)
		end
		local toAdd, toRemove, done = {}, {}, {}
		-- A new config for node, like src with its edges replaced through map (connections
		-- to unmapped edges dropped), traffic turned around with swap. src is only read:
		-- the builder's proposal hands out the same object for every use.
		local function addConfig(node, src, map, swap)
			local nc = api.type.BaseNodeLaneConnectionAndEntity.new()
			nc.entity = node
			local comp = nc.comp
			local connections = {}
			for __, c in ipairs(src.laneConnections) do
				local s0, s1 = map[c.segment0], map[c.segment1]
				if s0 and s1 then
					local l0, l1 = c.lane0, c.lane1
					if swap then
						s0, s1, l0, l1 = s1, s0, l1, l0
					end
					-- c is this loop's own copy of the connection
					c.segment0, c.lane0, c.segment1, c.lane1 = s0, l0, s1, l1
					connections[#connections + 1] = c
				end
			end
			comp.laneConnections = connections
			local crosswalks = {}
			for __, e in ipairs(src.crosswalks) do
				if map[e] then
					crosswalks[#crosswalks + 1] = map[e]
				end
			end
			comp.crosswalks = crosswalks
			comp.trafficLightPreference = src.trafficLightPreference
			comp.doubleSlipSwitch = src.doubleSlipSwitch
			pcall(function()
				comp.trafficLightConfig = src.trafficLightConfig
			end)
			nc.comp = comp
			-- replace the config an existing node has; many have none (plain track nodes),
			-- and removing a config that is not there crashed the game on applying the
			-- build (ecs::Engine::PostRemoveComponent)
			if not newNodes[node] and worldNodeConfig(node) ~= nil then
				toRemove[#toRemove + 1] = node
			end
			toAdd[#toAdd + 1] = nc
			done[node] = true
		end

		-- our nodes: like the drawn node they mirror, edges matched by direction
		for node, drawnNode in pairs(mirrorOf) do
			local exists = newNodes[node] or (node >= 0 and not removedNodes[node])
			local src = exists and sourceConfig(drawnNode)
			if src then
				local from = {}
				for __, e in ipairs(drawnAt[drawnNode] or {}) do
					from[#from + 1] = e
				end
				for __, e in ipairs(worldAt(drawnNode, drawnEntities)) do
					from[#from + 1] = e
				end
				local to = {}
				for __, e in ipairs(atNode[node] or {}) do
					to[#to + 1] = e
				end
				for __, e in ipairs(newNodes[node] and {} or worldAt(node, removedEdges)) do
					to[#to + 1] = e
				end
				local map, used = {}, {}
				for __, f in ipairs(from) do
					local best, bestAngle = nil, 45
					for i, t in ipairs(to) do
						local angle = geometry.angleBetween(f.dir, t.dir)
						if not used[i] and angle < bestAngle then
							best, bestAngle = i, angle
						end
					end
					if best then
						used[best] = true
						map[f.entity] = to[best].entity
					end
				end
				addConfig(node, src, map, options.reverse)
			end
		end

		-- existing nodes at the ends of replaced edges: the new piece instead of the old edge
		for __, p in ipairs(pieces) do
			if p.origins then
				for __, node in ipairs({ p.node0, p.node1 }) do
					if node >= 0 and not removedNodes[node] and not done[node] then
						local cfg = worldNodeConfig(node)
						if cfg then
							local map = {}
							for __, s in ipairs(getNode2Segments()[node] or {}) do
								map[s] = s
								if removedEdges[s] then
									map[s] = nil
									for __, e in ipairs(atNode[node] or {}) do
										for __, o in ipairs(e.origins or {}) do
											if o == s then
												map[s] = e.entity
											end
										end
									end
								end
							end
							addConfig(node, cfg, map, false)
						else
							done[node] = true
						end
					end
				end
			end
		end
		return toAdd, toRemove
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
		if NODE_CONFIGS then
			local ok, err = pcall(function()
				local toAdd, toRemove = makeNodeConfigs()
				proposal.streetProposal.nodeConfigsToAdd = toAdd
				proposal.streetProposal.nodeConfigsToRemove = toRemove
				stats.nodeConfigs = #toAdd
			end)
			if not ok then
				shared.log("node configs left out: " .. tostring(err))
			end
		end
		-- An edge without lane configs crashes the game (lane_config_util.cpp, seen for
		-- tracks and for roads in curved mode). Read them back from what the game gets.
		local ok, err = pcall(function()
			for i, segment in ipairs(proposal.streetProposal.edgesToAdd) do
				if sizeOf(segment.comp.laneConfigs) == 0 then
					local p = stats.plan[i]
					local problem = string.format("edge %d has no lane configs (%s)", segment.entity,
						p and (shared.vecToString(p.edge.p0) .. " -> " .. shared.vecToString(p.edge.p1)) or "?")
					table.insert(stats.problems, 1, problem)
					log("  plan problem: " .. problem)
					shared.log("lane config check: " .. problem .. ", template " .. tostring(segment.comp.roadTemplate))
					break
				end
			end
		end)
		if not ok then
			table.insert(stats.problems, 1, "lane configs could not be checked: " .. tostring(err))
			shared.log("lane config check failed: " .. tostring(err))
		end
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
	-- by count, not ipairs: a setting may be nil (e.g. spacing left at the default)
	for i = 1, select("#", ...) do
		parts[#parts + 1] = tostring((select(i, ...)))
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
planner.roadWidth = roadWidth
planner.parallelDistance = parallelDistance
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
