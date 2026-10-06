-- Planning of the tracks next to a drawn one: offset geometry, anchoring on and
-- crossing existing tracks, and the proposal for it. Loaded on both lua states that
-- need it: the game script (building) and the menu (preview).

local shared = require "parallelism_shared.lua"
local geometry = require "parallelism_geometry.lua"
local chainModule = require "parallelism_chain.lua"

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
-- Roads need more room between a junction or crossing and the next node: a 5.06 m
-- piece next to a T and a 5.9 m one before a junction were refused (Construction Not
-- Possible, 2026-10-02). A first guess, not measured.
local ROAD_MIN_PIECE_LENGTH = 10.0
-- A crossing this close to an existing junction of the other road goes through it.
local JUNCTION_REUSE_DISTANCE = 0.3
-- an intersection this close to a node both edges share is where they meet, not a crossing
local SHARED_NODE_MEETING_DISTANCE = 2.0
-- how far beyond a junction's corner the road builder keeps the next node (fitted to its
-- builds at 33 and 25 degrees, see junctionRoom)
local ROAD_JUNCTION_BEYOND = 26.0
-- the gap the game leaves between the corners of neighbouring junctions along a road
-- (native X, 2026-10-03; see docs/studies/2026-10-03_road-junction-spacing.md)
local ROAD_CORNER_GAP = 2.5
-- the width of the roads being planned (set per plan; nil for tracks)
local planRoadWidth = nil
-- the width of the planned road or track (its template's lanes)
local planWidth = nil
-- an end of an offset track continues a loose end within this share of the distance
-- between neighbouring tracks (below half, so never the neighbour's)
local LOOSE_END_SHARE = 0.4
-- shortfall of a piece against MIN_PIECE_LENGTH that is still let through
local PIECE_TOLERANCE = 0.25
-- A drag starting (or ending) at the end of an existing road at an angle to it, which
-- the road builder allows in both its modes, kinks there. From this angle (degrees) on
-- the parallel of the old road is cut back or extended to the corner where the two
-- parallels meet (offset * tan(kink / 2) along the roads, at any kink: the miter never
-- crosses itself), and the new parallel starts there.
local MITER_MIN_ANGLE = 1.0
-- A drag starting or ending on a road at an angle (a T): each parallel's end slides
-- along the parallel to meet that road, by at most this many times the offset (about
-- 2.7 times at 20 degrees, 4.7 at 12), and not for roads meeting flatter than
-- ROAD_MIN_CROSSING_ANGLE (refused as too shallow).
local BRANCH_MAX_SLIDE = 5.0
-- dev switch: extra roads crossing or branching onto roads. Until 2026-10-02 every plan
-- with such a junction crashed the game (map_util.h "it != map.end()", three times,
-- while evaluating the preview): our junction nodes had no node config. Now they get
-- the lane connections the road builder would give them (junctionConnections).
-- Off: such drags are refused.
local ROAD_JUNCTIONS = true
-- give new and touched nodes node configs (lane connections etc.) as the builder does;
-- false: none at all, as before 2026-10-01
local NODE_CONFIGS = true
-- crossings flatter than this (degrees) are not built: measured in game, the builder
-- refuses crossings under 6.0 degrees (and a very flat one once crashed the game)
local MIN_CROSSING_ANGLE = 6.05
planner.MIN_CROSSING_ANGLE = MIN_CROSSING_ANGLE
-- roads: below about 12.4 degrees even the drawn road collides at its own junction, and
-- a parallel crossing at 11.5 degrees crashed the game while it built the road shapes
-- (StreetShapeFactory, 2026-10-03); 12.3 degrees was built in game
local ROAD_MIN_CROSSING_ANGLE = 12.0
-- how much room a crossing needs along each track, as clearance / tan(angle)
local CROSSING_CLEARANCE = 1.5
-- cap on the length of a switch zone (a branch leaving on a straight never clears)
local MAX_SWITCH_ZONE = 150.0
-- two edges are only merged into one if that one strays no more than this from them
local MAX_MERGE_DEVIATION = 0.2
-- Existing roads and tracks keep their shape (parallelism_chain): edges joined into one
-- curve may stray this much from the old ones,
local EXISTING_MAX_DEVIATION = 0.05
-- and where one curve cannot follow them (a seam: a straight meeting a curve), the old
-- road is refitted as the native builder does (docs/studies/2026-10-02_native-crossings.md):
-- an arc-like cubic from the junction with the old directions, straying up to this much
-- (the native refits strayed up to 0.38 m per build).
local REFIT_MAX_DEVIATION = 0.5
-- smallest curve radius for extra tracks if the track template does not say
local DEFAULT_MIN_RADIUS = 40.0
-- roads: the tightest a road may curve is half its width plus this (native limit builds,
-- 2026-10-04: 9.0 m for a 16 m road, 5.5 m for the 9 m one-lane highway, at any turn angle)
local ROAD_INNER_EDGE_ROOM = 1.0
-- (if a road type's width cannot be read)
local DEFAULT_MIN_RADIUS_STREET = 9.0

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

-- A road crossing a track or a track crossing a road: a level crossing, one shared node
-- (native, 2026-10-03: road over track and track over road down to about 6.3 degrees; the
-- node's config holds only the road's lanes, straight through).
local function isLevelCrossable(comp)
	local planned = planRoadType or trackRoadType()
	if comp.roadType == planned then
		return false
	end
	return (isStreet(planned) and comp.roadType == trackRoadType()) or (planned == trackRoadType() and isStreet(comp.roadType))
end

-- beyond the overlap of the two surfaces, the stretch native keeps free of nodes at a
-- level crossing (fitted 2026-10-03 on one 6.3 degree build: new nodes 110.0 m along the
-- track and 109.6 m along the road; to check at a second angle)
local LEVEL_CROSSING_BEYOND = 19.0

-- how far along a road or track (alongWidth wide) the surfaces of a level crossing at
-- angle overlap, the other one crossWidth wide
local function levelCorner(angle, alongWidth, crossWidth)
	local a = math.rad(math.max(math.min(angle, 90), 1))
	return crossWidth / 2 / math.sin(a) + alongWidth / 2 / math.tan(a)
end

-- While a plan is made, edge components read from the world are kept: reading one
-- copies it into lua, and the same nearby edges come up for many offset edges.
local compCache = nil

-- the component as it is in the world now, for everything outside a plan
local function readEdgeComp(entity)
	if entity < 0 then
		return nil
	end
	return api.engine.getComponent(entity, api.type.ComponentType.BASE_EDGE)
end

-- The world as it will be after the player's build (set for a plan made while dragging,
-- see setOverlay): the builder's live proposal laid over the world. Its removed edges and
-- nodes are gone, its added ones there (with the builder's own, made-up entity numbers),
-- its node configs in place. Planning against it gives the plan that will really be
-- built after the player's part, so the preview and the drag check judge that one (the
-- world without the drawn road differed: partial builds at 20 degrees, 2026-10-03).
local overlay = nil
-- cell size of the grid the builder's edges are sorted into for searches (m)
local OVERLAY_CELL = 50

-- The elements of a proposal's lists (and their comp) are references into the native
-- proposal, and lua does not keep the list they point into alive: a list read once,
-- then let go, is freed whenever lua collects garbage, and a comp kept from it then reads
-- freed memory ("bad allocation" from reading roadTemplate, then a hard crash while
-- dragging 6 roads over 6, 2026-10-03). Whatever keeps such references beyond a loop over
-- the list gets them from here: the list and its elements as a lua array, with the list
-- and elements added to pins (a table the holder keeps as long as it uses them).
function planner.pinned(container, pins)
	pins[#pins + 1] = container
	local list = {}
	for __, x in ipairs(container) do
		list[#list + 1] = x
		pins[#pins + 1] = x
	end
	return list
end

local function setOverlay(streetProposal)
	if streetProposal == nil then
		overlay = nil
		return
	end
	local o = { edges = {}, hiddenEdges = {}, nodes = {}, hiddenNodes = {}, configs = {}, edgeList = {}, nodeList = {} }
	-- The parts of the proposal kept below are references into it: lua does not keep what
	-- they point into alive, so it is kept here (see pinned).
	o.pins = { streetProposal }
	local function pinned(container)
		return planner.pinned(container, o.pins)
	end
	local function real(id)
		return id < 0 and (-id - 1) or id
	end
	for __, s in ipairs(streetProposal.removedSegments) do
		o.hiddenEdges[real(s.entity)] = true
	end
	for __, n in ipairs(streetProposal.removedNodes) do
		o.hiddenNodes[real(n.entity)] = true
	end
	-- The live proposal can hold broken geometry in the middle of a drag (seen 2026-10-03:
	-- "the native floating point can't fit inside a lua number", then a hard crash):
	-- such a proposal is not used at all.
	local function finite(x)
		return x == x and x > -1e9 and x < 1e9
	end
	local function vec(v)
		local ok, r = pcall(function()
			return { x = v.x, y = v.y, z = v.z }
		end)
		if not ok or not (finite(r.x) and finite(r.y) and finite(r.z)) then
			error("the builder's proposal has broken geometry", 0)
		end
		return r
	end
	-- the builder's pieces of a cut edge typed like it (see planner.typedSegment)
	local removedComps = {}
	for __, s in ipairs(pinned(streetProposal.removedSegments)) do
		removedComps[#removedComps + 1] = s.comp
	end
	for __, s in ipairs(pinned(streetProposal.addedSegments)) do
		local typed = planner.typedSegment(s, removedComps, nil)
		o.pins[#o.pins + 1] = typed
		local comp = typed.comp
		local p0, p1 = vec(comp.position0), vec(comp.position1)
		-- the plain geometry once: searches test it many times per plan
		o.plain = o.plain or {}
		o.plain[s.entity] = { p0 = p0, p1 = p1, t0 = vec(comp.tangent0), t1 = vec(comp.tangent1) }
		o.edges[s.entity] = comp
		o.edgeList[#o.edgeList + 1] = s.entity
		-- a circle around the edge, to skip it quickly in searches
		local chord = math.sqrt((p1.x - p0.x) ^ 2 + (p1.y - p0.y) ^ 2)
		o.bounds = o.bounds or {}
		o.bounds[s.entity] = { x = (p0.x + p1.x) / 2, y = (p0.y + p1.y) / 2, r = chord * 0.75 + 5 }
	end
	for __, n in ipairs(streetProposal.addedNodes) do
		o.nodes[n.entity] = vec(n.comp.position)
		o.nodeList[#o.nodeList + 1] = n.entity
	end
	pcall(function()
		for __, nc in ipairs(pinned(streetProposal.nodeConfigsToAdd)) do
			o.configs[nc.entity] = nc.comp
		end
	end)
	-- the builder's edges in a grid of cells, so a search looks only at the cells it touches
	-- (a 12-track drag over 12 tracks: hundreds of edges, searched some 300 times a plan)
	o.grid = {}
	for __, e in ipairs(o.edgeList) do
		local bound = o.bounds[e]
		for cx = math.floor((bound.x - bound.r) / OVERLAY_CELL), math.floor((bound.x + bound.r) / OVERLAY_CELL) do
			for cy = math.floor((bound.y - bound.r) / OVERLAY_CELL), math.floor((bound.y + bound.r) / OVERLAY_CELL) do
				local key = cx .. ":" .. cy
				o.grid[key] = o.grid[key] or {}
				table.insert(o.grid[key], e)
			end
		end
	end
	overlay = o
end

local function getEdgeComp(entity)
	if overlay then
		if overlay.edges[entity] then
			return overlay.edges[entity]
		end
		if overlay.hiddenEdges[entity] or entity < 0 then
			return nil
		end
	end
	if entity < 0 then
		return nil
	end
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

-- a node's position, from the overlay or the world; nil if there is none
local function nodePosition(entity)
	if overlay then
		if overlay.nodes[entity] then
			return overlay.nodes[entity]
		end
		if overlay.hiddenNodes[entity] or entity < 0 then
			return nil
		end
	end
	if entity < 0 then
		return nil
	end
	local comp = api.engine.getComponent(entity, api.type.ComponentType.BASE_NODE)
	return comp and plain(comp.position) or nil
end

-- edges / nodes within radius of center (Vec2f), the overlay's included
-- dev aid: time spent in the game's spatial index and the overlay's part (planner timing)
local searchTiming = { octree = 0, overlay = 0 }

local function edgesInCircle(center, radius)
	local result = {}
	local started = clockMs and clockMs()
	for __, e in ipairs(api.engine.util.octree.findEntitiesInCircle(center, radius, api.type.ComponentType.BASE_EDGE)) do
		if not (overlay and overlay.hiddenEdges[e]) then
			result[#result + 1] = e
		end
	end
	local octreeDone = clockMs and clockMs()
	if overlay then
		local c = { x = center.x, y = center.y, z = 0 }
		local seen = {}
		for cx = math.floor((c.x - radius) / OVERLAY_CELL), math.floor((c.x + radius) / OVERLAY_CELL) do
			for cy = math.floor((c.y - radius) / OVERLAY_CELL), math.floor((c.y + radius) / OVERLAY_CELL) do
				for __, e in ipairs(overlay.grid[cx .. ":" .. cy] or {}) do
					if not seen[e] then
						seen[e] = true
						local b = overlay.bounds[e]
						if math.sqrt((b.x - c.x) ^ 2 + (b.y - c.y) ^ 2) <= radius + b.r
							and geometry.distanceToEdge(c, overlay.plain[e]) <= radius then
							result[#result + 1] = e
						end
					end
				end
			end
		end
	end
	if started and octreeDone then
		searchTiming.octree = searchTiming.octree + octreeDone - started
		searchTiming.overlay = searchTiming.overlay + clockMs() - octreeDone
	end
	return result
end

local function nodesInCircle(center, radius)
	local result = {}
	for __, n in ipairs(api.engine.util.octree.findEntitiesInCircle(center, radius, api.type.ComponentType.BASE_NODE)) do
		if not (overlay and (overlay.hiddenNodes[n] or overlay.nodes[n])) then
			result[#result + 1] = n
		end
	end
	if overlay then
		for __, n in ipairs(overlay.nodeList) do
			local p = overlay.nodes[n]
			if math.sqrt((p.x - center.x) ^ 2 + (p.y - center.y) ^ 2) <= radius then
				result[#result + 1] = n
			end
		end
	end
	return result
end

local function getPlayerOwned(entity)
	if entity < 0 then
		return nil
	end
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

-- The shortest piece the plan allows next to a crossing or junction: roads need more.
-- the flattest crossing the plan builds, for the type being planned
local function minCrossingAngle()
	return isStreet(planRoadType) and ROAD_MIN_CROSSING_ANGLE or MIN_CROSSING_ANGLE
end

local function pieceMinimum()
	return isStreet(planRoadType) and ROAD_MIN_PIECE_LENGTH or MIN_PIECE_LENGTH
end

-- The stretch next to a junction or crossing, along one road or track (alongWidth wide),
-- that must hold no plain node (docs/design/2026-10-03_node-placement.md), and how far the
-- junction's corner reaches along it (nil where that does not apply). acrossWidth: the
-- width of the other one.
-- - a switch: its zone along the track it branches off
-- - roads meeting, or a road and a track (a level crossing): where the two surfaces
--   overlap, plus what the builder keeps free beyond that (26 m at a road junction, 19 m at
--   a level crossing; docs/studies 2026-10-03)
-- - tracks crossing: the clearance the track builder was measured to need (at 6.1 degrees
--   7.7 m next to a crossing failed, 14.9 m worked), at least the minimum piece
local function junctionRoom(cut, alongWidth, acrossWidth)
	if cut.zone ~= nil then
		return math.max(pieceMinimum(), cut.zone), nil
	end
	if cut.angle == nil then
		return pieceMinimum(), nil
	end
	if cut.level or isStreet(planRoadType) then
		local corner = levelCorner(cut.angle, alongWidth, acrossWidth)
		return math.max(pieceMinimum(), corner + (cut.level and LEVEL_CROSSING_BEYOND or ROAD_JUNCTION_BEYOND)), corner
	end
	return math.max(pieceMinimum(), CROSSING_CLEARANCE / math.tan(math.rad(math.max(cut.angle, 1)))), nil
end

-- the width of what is being planned: the road's, or a track's (its template's lanes;
-- should the template not be readable, the standard track distance as a stand-in)
local function plannedWidth()
	return planWidth or DEFAULT_TRACK_DISTANCE
end

-- Lane connections at a road junction: the mod's own sensible default (2026-10-02), not
-- a copy of the road builder's (its choices are studied in
-- docs/studies/2026-10-02_native-junctions.md; the player can change any of it with the
-- game's lane tool). edges: { entity, dir (leaving the node), atStart (the node is the
-- edge's node0), lanes (its lane configs) }. Returns plain { segment0, lane0, segment1,
-- lane1, withRoad, withTram }.
-- Lanes are counted as seen from the node, as the game does: the physical index for an
-- edge starting there, mirrored for one ending there.
-- The rules, per incoming road:
-- 1. Straight on: lane to lane; more or fewer lanes on the far side spread evenly.
-- 2. Turns use the lanes on their own side, never across other traffic: left turns the
--    left lane(s), right turns the right; with no way straight on (a T) the lanes are
--    split between the two sides, an odd middle lane turning both ways. A turn into several
--    lanes spreads over them.
-- 3. No turns sharper than JUNCTION_MAX_TURN (and no U-turns).
-- 4. A road merging into another that carries straight-on traffic (a ramp): lane to lane
--    into the outer lanes on its own side only.
local TRANSPORT_ROAD = { 2, 3, 4 } -- CAR, BUS, TRUCK
local TRANSPORT_TRAM = { 5, 6 } -- TRAM, ELECTRIC_TRAM
local JUNCTION_MAX_TURN = 135
local JUNCTION_STRAIGHT = 45
local function junctionConnections(edges)
	local function hasMode(lane, modes)
		local found = false
		pcall(function()
			for mode, on in pairs(lane.transportModes) do
				for __, m in ipairs(modes) do
					if on and mode == m then
						found = true
					end
				end
			end
		end)
		return found
	end
	-- per edge: driving lanes coming in and going out, each ordered left to right as the
	-- driver sees them
	local info = {}
	for __, e in ipairs(edges) do
		local incoming, outgoing = {}, {}
		local lanes = e.lanes or {}
		local n = #lanes
		for i, lane in ipairs(lanes) do
			local road, tram = hasMode(lane, TRANSPORT_ROAD), hasMode(lane, TRANSPORT_TRAM)
			if road or tram then
				local physical = i - 1
				local frame = e.atStart and physical or (n - 1 - physical)
				local entry = { lane = frame, road = road, tram = tram }
				local coming = (e.atStart and not lane.forward) or (not e.atStart and lane.forward)
				if coming then
					incoming[#incoming + 1] = entry
				else
					outgoing[#outgoing + 1] = entry
				end
			end
		end
		-- incoming: the higher index is further left; outgoing: the lower
		table.sort(incoming, function(a, b) return a.lane > b.lane end)
		table.sort(outgoing, function(a, b) return a.lane < b.lane end)
		info[#info + 1] = { edge = e, incoming = incoming, outgoing = outgoing }
	end
	local atan2 = math.atan2 or math.atan
	-- the turn from arriving along a (against its leaving direction) to leaving along b,
	-- in degrees, positive to the left
	local function turn(a, b)
		local ax, ay = -a.edge.dir.x, -a.edge.dir.y
		local bx, by = b.edge.dir.x, b.edge.dir.y
		return math.deg(atan2(ax * by - ay * bx, ax * bx + ay * by))
	end
	local result = {}
	local function connect(a, la, b, lb)
		local withRoad, withTram = la.road and lb.road, la.tram and lb.tram
		if withRoad or withTram then
			result[#result + 1] = { segment0 = a.edge.entity, lane0 = la.lane, segment1 = b.edge.entity, lane1 = lb.lane,
				withRoad = withRoad, withTram = withTram }
		end
	end
	-- lanes ins (left to right) into outs (left to right): one to one if as many, else
	-- spread evenly; spare outgoing lanes go to the left or right end (wide)
	local function spread(a, ins, b, outs, wide)
		local k, m = #ins, #outs
		if k == 0 or m == 0 then
			return
		end
		if k >= m then
			for i = 1, k do
				connect(a, ins[i], b, outs[math.max(1, math.ceil(i * m / k))])
			end
			return
		end
		local base, extra = math.floor(m / k), m % k
		local o = 1
		for i = 1, k do
			local size = base
			if (wide == "left" and i <= extra) or (wide ~= "left" and i > k - extra) then
				size = size + 1
			end
			for __ = 1, size do
				connect(a, ins[i], b, outs[o])
				o = o + 1
			end
		end
	end
	local function slice(list, from, to)
		local s = {}
		for i = from, to do
			s[#s + 1] = list[i]
		end
		return s
	end
	for __, a in ipairs(info) do
		local ins = a.incoming
		if #ins > 0 then
			local exits = {}
			for __, b in ipairs(info) do
				if b.edge.entity ~= a.edge.entity and #b.outgoing > 0 then
					local angle = turn(a, b)
					if math.abs(angle) <= JUNCTION_MAX_TURN then
						exits[#exits + 1] = { b = b, angle = angle }
					end
				end
			end
			-- a merge (a ramp): the road's only way on, which another road enters more
			-- nearly straight on (or as straight with more lanes)
			local merge = nil
			if #exits == 1 and math.abs(exits[1].angle) < JUNCTION_STRAIGHT then
				local x = exits[1]
				for __, c in ipairs(info) do
					if c ~= a and c ~= x.b and #c.incoming > 0 then
						local other = math.abs(turn(c, x.b))
						if other < math.abs(x.angle) - 0.5
							or (math.abs(other - math.abs(x.angle)) <= 0.5 and #c.incoming > #ins) then
							merge = x
						end
					end
				end
			end
			local lefts, rights, straights = {}, {}, {}
			if merge then
				-- into the outer lanes on its own side: a ramp turning right to join comes
				-- from the right (in line: the left, as the builder does)
				local outs = merge.b.outgoing
				local k = math.min(#ins, #outs)
				for i = 1, k do
					if merge.angle < -0.5 then
						connect(a, ins[#ins - k + i], merge.b, outs[#outs - k + i])
					else
						connect(a, ins[i], merge.b, outs[i])
					end
				end
				exits = {}
			end
			-- straight on: the most nearly straight way within JUNCTION_STRAIGHT; any
			-- other way is a turn to its side, however slight
			local straightest = nil
			for __, x in ipairs(exits) do
				if math.abs(x.angle) < JUNCTION_STRAIGHT and (straightest == nil or math.abs(x.angle) < math.abs(straightest.angle)) then
					straightest = x
				end
			end
			for __, x in ipairs(exits) do
				if x == straightest then
					straights[#straights + 1] = x
				elseif x.angle > 0 then
					lefts[#lefts + 1] = x
				else
					rights[#rights + 1] = x
				end
			end
			local n = #ins
			local leftCount, rightCount
			if #straights > 0 then
				-- a third of the lanes each side (at least one), sharing with straight on
				leftCount = math.max(1, math.floor(n / 3))
				rightCount = leftCount
			elseif #lefts > 0 and #rights > 0 then
				-- a T: half the lanes each way, a single middle lane both ways
				leftCount = math.ceil(n / 2)
				rightCount = leftCount
			else
				leftCount, rightCount = n, n
			end
			for __, x in ipairs(lefts) do
				spread(a, slice(ins, 1, leftCount), x.b, x.b.outgoing, "left")
			end
			for __, x in ipairs(rights) do
				spread(a, slice(ins, n - rightCount + 1, n), x.b, x.b.outgoing, "right")
			end
			-- straight on: all lanes; two ways straight on (a fork) split them, left to left
			table.sort(straights, function(p, q) return p.angle > q.angle end)
			for i, x in ipairs(straights) do
				local from = math.floor((i - 1) * n / #straights) + 1
				local to = math.max(from, math.floor(i * n / #straights))
				spread(a, slice(ins, from, to), x.b, x.b.outgoing, "right")
			end
		end
	end
	return result
end

planner.junctionConnections = junctionConnections

-- true if a road with these lanes has a sidewalk (a lane for PERSON, transport mode 0)
local function junctionHasSidewalk(lanes)
	local found = false
	pcall(function()
		for __, lane in ipairs(lanes) do
			for mode, on in pairs(lane.transportModes) do
				if on and mode == 0 then
					found = true
				end
			end
		end
	end)
	return found
end

-- The smallest radius the game allows for a track or road type.
local function allowedRadius(templateName)
	local template = getTemplate(templateName)
	if template and isStreet(template.roadType) then
		-- Roads: the road builder ignores the template's minCurveRadius (44 m for a 16 m
		-- road); what it refuses (Too Much Curvature) is an edge whose tightest point
		-- comes closer than ROAD_INNER_EDGE_ROOM to folding its inner edge over: native,
		-- 2026-10-04, the tightest point of every limit build was 9.0 m on a 16 m road and
		-- 5.5 m on the 9 m one-lane highway, at 57 to 180 degrees of turn (the radius by the
		-- ends grows with the turn: a cubic edge bunches its curvature in the middle).
		local width = 0
		for __, lc in ipairs(template.laneConfigs or {}) do
			width = width + math.abs(lc.width or 0)
		end
		return width > 0 and (width / 2 + ROAD_INNER_EDGE_ROOM) or DEFAULT_MIN_RADIUS_STREET
	end
	-- tracks: the type's own minimum, as loaded (other mods change it, e.g. Tighter Curves)
	if template and template.minCurveRadius and template.minCurveRadius > 0 then
		return template.minCurveRadius
	end
	return DEFAULT_MIN_RADIUS
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

-- The width of a road or track: the sum of its template's lanes (a road's sidewalks
-- included; a track's one lane is its ballast bed, which the game also collides with).
-- nil if the template cannot be read.
local function widthOf(roadTemplate)
	local template = getTemplate(roadTemplate)
	if template == nil then
		return nil
	end
	local width = 0
	for __, lc in ipairs(template.laneConfigs or {}) do
		width = width + math.abs(lc.width or 0)
	end
	return width > 0 and width or nil
end

-- The width of a road; nil for a track.
local function roadWidth(roadTemplate)
	local template = getTemplate(roadTemplate)
	if not (template and isStreet(template.roadType)) then
		return nil
	end
	return widthOf(roadTemplate)
end

-- The Spacing value is the gap between the edges of neighbours (the panel may show it
-- from centre to centre instead). Its default: as the game places them, the road builder
-- snapping a second road shared.ROAD_GAP away, a track's template trackDistance between
-- centres.
local function defaultGap(roadTemplate)
	local width = widthOf(roadTemplate)
	if width == nil then
		return 0
	end
	return math.max(0, getTrackDistance(roadTemplate) - width)
end

-- Distance between the centre lines of neighbours for a Spacing value (the gap).
local function parallelDistance(roadTemplate, spacing)
	local width = widthOf(roadTemplate) or 0
	if spacing == nil then
		return getTrackDistance(roadTemplate)
	end
	return width + math.max(0, spacing)
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
	-- each drawn segment keeps its comp, a reference into the proposal (see planner.pinned)
	local pins = { streetProposal }
	for __, segment in ipairs(planner.pinned(streetProposal.addedSegments, pins)) do
		if segment.comp.roadType == roadType then
			local edge = toEdge(segment.comp)
			if not geometry.liesOnAny(edge, removed, REMNANT_TOLERANCE) then
				drawn[#drawn + 1] = { entity = segment.entity, segmentType = segment.type, comp = segment.comp, edge = edge, pins = pins }
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
	for __, entity in ipairs(nodesInCircle(center, math.max(maxDistance, 0.01))) do
		local p = nodePosition(entity)
		if p and geometry.horizontalDistance(p, position) < maxDistance and math.abs(p.z - position.z) < NODE_SNAP_HEIGHT then
			return { entity = entity, position = p }
		end
	end
	return nil
end

-- The node config of a node in the world; nil for one that is not (yet): asking the
-- game about such an entity is an error ("Invalid entity"), e.g. drawn nodes while
-- dragging.
local function worldNodeConfig(node)
	if overlay then
		if overlay.configs[node] then
			return overlay.configs[node]
		end
		if overlay.hiddenNodes[node] then
			return nil
		end
	end
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
		-- node by node: the whole map is a large native object for every plan, which lua's
		-- garbage collector does not see (the game ran out of memory, 2026-10-03)
		local world = setmetatable({}, { __index = function(t, node)
			local list = nil
			if node >= 0 then
				pcall(function()
					list = api.engine.system.streetSystem.getNodeSegments(node)
				end)
			end
			-- an empty list, not nil: what lua tables gave for an unknown node
			list = list or {}
			rawset(t, node, list)
			return list
		end })
		if overlay == nil then
			node2segmentsCache = world
		else
			-- the world's lists without the overlay's removed edges, plus its added ones
			local added = {}
			for __, e in ipairs(overlay.edgeList) do
				local comp = overlay.edges[e]
				for __, n in ipairs({ comp.node0, comp.node1 }) do
					added[n] = added[n] or {}
					table.insert(added[n], e)
				end
			end
			local o = overlay
			node2segmentsCache = setmetatable({}, { __index = function(t, node)
				local list = {}
				local w = node >= 0 and not o.hiddenNodes[node] and world[node] or nil
				for __, e in ipairs(w or {}) do
					if not o.hiddenEdges[e] then
						list[#list + 1] = e
					end
				end
				for __, e in ipairs(added[node] or {}) do
					list[#list + 1] = e
				end
				rawset(t, node, list)
				return list
			end })
		end
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
	for __, entity in ipairs(nodesInCircle(center, radius)) do
		local p = nodePosition(entity)
		if p and math.abs(p.z - position.z) < NODE_SNAP_HEIGHT then
			local distance = geometry.horizontalDistance(p, position)
			local segments = getNode2Segments()[entity]
			if distance < radius and distance < bestDistance and segments and #segments == 1 then
				local edge = getEdgeComp(segments[1])
				if edge and isPlanned(edge) then
					best, bestDistance = { entity = entity, position = p }, distance
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
-- neighbour of the track a branch was drawn from. alsoLevel: a track under a road (or a
-- road under a track) too, for a T at a level crossing.
local function findEdgeAt(position, alsoLevel)
	local center = api.type.Vec2f.new(position.x, position.y)
	for __, entity in ipairs(edgesInCircle(center, EDGE_SEARCH_RADIUS)) do
		local comp = getEdgeComp(entity)
		if comp and (isPlanned(comp) or (alsoLevel and isLevelCrossable(comp))) then
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
	return edgesInCircle(api.type.Vec2f.new(cx, cy), radius)
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
-- The road running straight through a node (two of its edges in line, the drawn ones and
-- accept(c) false left out): those two edges, and the leaving directions of the others.
-- nil if no two run on through.
local function throughRoad(nodeEntity, isDrawn, accept)
	local list = {}
	for __, seg in ipairs(getNode2Segments()[nodeEntity] or {}) do
		local c = not isDrawn[seg] and getEdgeComp(seg) or nil
		if c and accept(c) then
			local e = toEdge(c)
			list[#list + 1] = { entity = seg, dir = c.node0 == nodeEntity and e.t0 or { x = -e.t1.x, y = -e.t1.y, z = -e.t1.z } }
		end
	end
	for i = 1, #list do
		for j = i + 1, #list do
			if geometry.angleBetween(list[i].dir, list[j].dir) > 179 then
				local others = {}
				for k = 1, #list do
					if k ~= i and k ~= j then
						others[#others + 1] = list[k].dir
					end
				end
				return { list[i].entity, list[j].entity }, others
			end
		end
	end
	return nil
end

local function makeProposalIn(drawn, offsets, log, planOnly, options)
	if type(offsets) == "number" then
		offsets = { offsets }
	end
	options = options or {}
	log = log or function() end
	compCache = shared.PERF_MEASURES and {} or nil
	node2segmentsCache = nil
	planRoadType = drawn[1] and drawn[1].comp.roadType or trackRoadType()
	planRoadWidth = nil
	planWidth = nil
	pcall(function()
		local template = nonEmpty(drawn[1].comp.roadTemplate) or drawn[1].template
		planRoadWidth = roadWidth(template)
		planWidth = widthOf(template)
	end)
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
	local timing = { start = clockMs(), offsets = 0, crossings = 0, merges = 0, relay = 0, segments = 0, configs = 0 }
	searchTiming.octree, searchTiming.overlay = 0, 0
	local function lap(name, since)
		local t = clockMs()
		if t and since then
			timing[name] = timing[name] + (t - since)
		end
		return t
	end
	local stats = { edges = 0, minRadius = math.huge, reused = 0, anchored = 0, crossings = 0, junctions = 0, shallow = 0, moved = 0, dropped = 0, skipped = 0, plan = {}, problems = {} }
	stats.minCrossingAngle = minCrossingAngle()
	-- dev aid: why nodes were left where they are, kept even without a log (the preview
	-- has none), for the log of a refused plan
	stats.notes = {}
	do
		local userLog = log
		log = function(msg)
			userLog(msg)
			local text = tostring(msg)
			if #stats.notes < 60 and (text:find("kept", 1, true) or text:find("removed", 1, true)
				or text:find("moved", 1, true) or text:find("cannot", 1, true) or text:find("could not", 1, true)
				or text:find("joined", 1, true) or text:find("refit", 1, true) or text:find("not done", 1, true)
				or text:find("slid", 1, true) or text:find("anchored", 1, true) or text:find("crossing edge", 1, true)
				or text:find("lengthened", 1, true) or text:find("junction node", 1, true) or text:find("cut ", 1, true)
				or text:find("run end", 1, true) or text:find("through existing", 1, true)
				or text:find("shortened", 1, true) or text:find("existing node", 1, true)
				or text:find("re-laid", 1, true) or text:find("apart, they need", 1, true)) then
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

	-- A drag from (or to) the end of a road of an existing bundle other than where the
	-- drawn one would be (an outer road): the bundle's other roads end beside it at whole
	-- steps to either side. The parallels go where they continue those loose ends, the
	-- arrangement that continues the most; the Side setting decides only when none
	-- continues more than it (2026-10-05: a drag from an outer road put the new parallels
	-- beside or into the old bundle).
	if not options.step and #offsets > 0 and step < math.huge then
		local count = #offsets + 1
		local continued = {}
		local function scan(position, tangent)
			for k = -(count - 1), count - 1 do
				if k ~= 0 then
					local p = geometry.offsetPoint(position, tangent, k * step)
					if p and findLooseEnd(p, looseEndRadius) then
						continued[k] = true
					end
				end
			end
		end
		scan(drawn[1].edge.p0, drawn[1].edge.t0)
		scan(drawn[#drawn].edge.p1, drawn[#drawn].edge.t1)
		if next(continued) then
			local function score(set)
				local n = 0
				for __, o in ipairs(set) do
					if continued[math.floor(o / step + 0.5)] then
						n = n + 1
					end
				end
				return n
			end
			local best, bestScore = nil, score(offsets)
			for first = -(count - 1), 0 do
				local set = {}
				for j = first, first + count - 1 do
					if j ~= 0 then
						set[#set + 1] = j * step
					end
				end
				local sc = score(set)
				if sc > bestScore then
					best, bestScore = set, sc
				end
			end
			if best then
				-- nearest first, as geometry.offsets: each may continue the one before it
				table.sort(best, function(x, y)
					if math.abs(x) ~= math.abs(y) then
						return math.abs(x) < math.abs(y)
					end
					return x > y
				end)
				local listed = {}
				for __, o in ipairs(best) do
					listed[#listed + 1] = string.format("%.1f", o)
				end
				log("  continuing an existing bundle: offsets " .. table.concat(listed, ", "))
				offsets = best
				stats.bundleContinued = true
			end
		end
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
	-- the cut at each crossing node, for the room an edge ending there needs
	local cutAt = {}
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
		cutAt[node.entity] = cutAt[node.entity] or cut
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
	-- per track, its own nodes that only mirror the drawn road's (free to go)
	local trackMovable = {}
	-- existing parallels whose loose end moves to a corner: { entity, comp, removeEdges, removeNodes,
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
		-- run ends slid onto a road (branchPoint): node -> where the parallel would end
		local branchFrom = {}

		-- The drawn road continues from a junction where an earlier bundle's roads have
		-- their own junctions on the same road (a T of ours extended at another angle):
		-- each parallel continues from its own junction, as native does (each road from its
		-- own node, kinked there), so it runs through that junction parallel to the drawn
		-- road, at whatever spacing that gives (spacing * sin(out) / sin(in)); keeping the
		-- set spacing would put a new junction a few metres from the old one (2026-10-05).
		do
			local function junctionOfOurs(endEntity, position, tangent)
				-- the roads at the node besides the one running on through it
				local pair, incoming = throughRoad(endEntity, drawnEntities, isPlanned)
				if pair == nil or #incoming == 0 then
					return nil
				end
				local expected = geometry.offsetPoint(position, tangent, offset)
				if expected == nil then
					return nil
				end
				-- the junctions along that same road, both ways (2026-10-05: a junction off it,
				-- at the far end of a road coming in, was taken)
				local reach = 2 * math.abs(offset)
				local along = {}
				for __, first in ipairs(pair) do
					local seg, from, walked = first, endEntity, 0
					local seen = {}
					while seg and not seen[seg] do
						seen[seg] = true
						local c = getEdgeComp(seg)
						if c == nil then
							break
						end
						local n = c.node0 == from and c.node1 or c.node0
						local p0, p1 = nodePosition(from), nodePosition(n)
						walked = walked + ((p0 and p1) and geometry.horizontalDistance(p0, p1) or math.huge)
						-- (a junction within reach of the expected point is at most three
						-- offsets away in a straight line; four along a curving road)
						if walked > 2 * reach then
							break
						end
						along[#along + 1] = n
						local nextPair = throughRoad(n, drawnEntities, isPlanned)
						local nextSeg = nil
						if nextPair == nil then
							local at = {}
							for __, t in ipairs(getNode2Segments()[n] or {}) do
								if not drawnEntities[t] then
									at[#at + 1] = t
								end
							end
							if #at == 2 then
								nextPair = at
							end
						end
						for __, t in ipairs(nextPair or {}) do
							if t ~= seg then
								nextSeg = t
							end
						end
						seg, from = nextSeg, n
					end
				end
				local best, bestDistance = nil, reach
				for __, n in ipairs(along) do
					local p = nodePosition(n)
					local d = p and geometry.horizontalDistance(p, expected) or math.huge
					if d < bestDistance then
						-- a junction of the same road with a road parallel to one of those
						local parallel = false
						local jPair, jOthers = throughRoad(n, drawnEntities, isPlanned)
						for __, dir in ipairs(jPair and jOthers or {}) do
							for __, inc in ipairs(incoming) do
								parallel = parallel or geometry.angleBetween(dir, inc) < 1
							end
						end
						if parallel then
							best, bestDistance = { entity = n, position = p }, d
						end
					end
				end
				return best
			end
			for __, endInfo in ipairs({ { drawn[1].node0, drawn[1].edge.p0, drawn[1].edge.t0 },
				{ drawn[#drawn].node1, drawn[#drawn].edge.p1, drawn[#drawn].edge.t1 } }) do
				if useCount[endInfo[1]] == 1 then
					local j = junctionOfOurs(endInfo[1], endInfo[2], endInfo[3])
					if j then
						local r = geometry.right(endInfo[3])
						if r then
							local adopted = (j.position.x - endInfo[2].x) * r.x + (j.position.y - endInfo[2].y) * r.y
							log(string.format("  continuing from our junction %d: parallel at %.1f m instead of %.1f m", j.entity, adopted, offset))
							offset = adopted
							break
						end
					end
				end
			end
		end

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
			local arriving, leaving = oldDir, tangent
			if not atStart then
				arriving, leaving = tangent, oldDir
			end
			local corner = geometry.miter(position, arriving, leaving, offset)
			if corner == nil then
				return nil
			end
			corner.z = loose.position.z
			-- The old parallel, from its loose end back through its plain nodes, each edge run
			-- towards the loose end: on the inside of a sharp kink the corner lies further back
			-- than its last edge (2026-10-05). (Ten edges: a cut-off for how far to look.)
			local back = {}
			do
				local entity, comp, near = parEntity, par, loose.entity
				for __ = 1, 10 do
					local e = toEdge(comp)
					local towardNear = comp.node1 == near
					local farNode = towardNear and comp.node0 or comp.node1
					back[#back + 1] = { entity = entity, comp = comp, near = near, far = farNode,
						edge = towardNear and e or geometry.reverse(e), sameWay = towardNear }
					local segs = getNode2Segments()[farNode]
					if segs == nil or #segs ~= 2 or drawnNodes[farNode] or reusedNodes[farNode] then
						break
					end
					local nextEntity = segs[1] == entity and segs[2] or segs[1]
					local nextComp = not drawnEntities[nextEntity] and not splits[nextEntity] and getEdgeComp(nextEntity) or nil
					if nextComp == nil or not isPlanned(nextComp) or nextComp.roadTemplate ~= par.roadTemplate
						or (nextComp.objects and #nextComp.objects > 0) then
						break
					end
					entity, comp, near = nextEntity, nextComp, farNode
				end
			end
			-- the edge the corner lies on (inside), or the last one, reaching on (outside)
			local at, best = 1, math.huge
			for i, b in ipairs(back) do
				local __, d = geometry.closestParameter(corner, b.edge)
				if d < best then
					at, best = i, d
				end
			end
			local cutEdge = back[at]
			local q0, q1 = cutEdge.edge.p0, corner
			if geometry.horizontalDistance(q0, q1) < MIN_PIECE_LENGTH then
				return nil
			end
			local t0, t1 = geometry.offsetTangents(cutEdge.edge.p0, cutEdge.edge.p1, cutEdge.edge.t0, cutEdge.edge.t1, q0, q1)
			local node = newNode(corner)
			local far = { entity = cutEdge.far, position = q0 }
			local removeEdges, removeNodes = {}, {}
			for i = 1, at do
				removeEdges[#removeEdges + 1] = back[i].entity
				removeNodes[#removeNodes + 1] = back[i].near
				movedAway[back[i].near] = true
				-- the rebuilt edge and those it replaces are not crossed, split or moved by the
				-- rest of the plan
				drawnEntities[back[i].entity] = true
			end
			local piece = { p0 = q0, p1 = q1, t0 = t0, t1 = t1 }
			rebuilt[#rebuilt + 1] = {
				entity = cutEdge.entity,
				comp = cutEdge.comp,
				removeEdges = removeEdges,
				removeNodes = removeNodes,
				-- (the way the old edge ran: one-way roads)
				node0 = cutEdge.sameWay and far or node,
				node1 = cutEdge.sameWay and node or far,
				edge = cutEdge.sameWay and piece or geometry.reverse(piece),
			}
			corners[node.entity] = true
			log(string.format("  node %d: kinks %.1f deg, parallel end %d moved %.2f m to the corner%s ", entity, kink, loose.entity,
				geometry.horizontalDistance(loose.position, corner), at > 1 and string.format(" (cut back over %d edges)", at) or "")
				.. shared.vecToString(corner))
			return node
		end

		-- The drawn road starts or ends on a road (a T, at any angle): the parallel's end,
		-- offset sideways, misses that road unless the angle is square. Slide it along
		-- the parallel's own direction until it meets the road (shortening or extending the
		-- parallel), where it then branches off as usual. The road is followed through its
		-- plain nodes: at sharp angles and on curves the parallel meets it on a further
		-- piece. Returns the point, or nil.
		local function branchPoint(entity, position, tangent, offsetPosition)
			if not streets then
				return nil
			end
			-- the road the drawn end lies on: its edges at the drawn node (built), or the
			-- edge under it (while dragging the drawn end is new, the road still whole)
			-- (or a track: a road starting or ending on a track, a T at a level crossing)
			local start = {}
			for __, s in ipairs(getNode2Segments()[entity] or {}) do
				if not drawnEntities[s] then
					local comp = getEdgeComp(s)
					if comp and (isPlanned(comp) or isLevelCrossable(comp)) then
						start[#start + 1] = s
					end
				end
			end
			-- at a junction: only the road running on through it, not the other roads there
			-- (2026-10-05: a parallel slid onto a road coming in to the same junction)
			if #start > 2 then
				local pair = throughRoad(entity, drawnEntities, function(c)
					return isPlanned(c) or isLevelCrossable(c)
				end)
				if pair then
					start = pair
				end
			end
			if #start < 2 then
				local e = findEdgeAt(position, true)
				if e and not drawnEntities[e] then
					start = { e }
				elseif #start < 2 then
					return nil -- not a T (a road end is a corner, see tryCorner)
				end
			end
			local len = math.sqrt(tangent.x * tangent.x + tangent.y * tangent.y)
			if len < 1e-9 then
				return nil
			end
			local dir = { x = tangent.x / len, y = tangent.y / len, z = 0 }
			local reach = BRANCH_MAX_SLIDE * math.abs(offset)
			-- the road (or track) is followed by its own kind; a track is met at a level
			-- crossing, down to the flatter angle those allow
			local startComp = getEdgeComp(start[1])
			local kind = startComp and startComp.roadType
			local minAngle = (startComp and isLevelCrossable(startComp)) and MIN_CROSSING_ANGLE or ROAD_MIN_CROSSING_ANGLE
			-- the road's edges within reach, following plain nodes (two edges) both ways
			local roads, seen, queue = {}, {}, {}
			for __, s in ipairs(start) do
				seen[s] = true
				queue[#queue + 1] = s
			end
			while #queue > 0 and #roads < 12 do
				local s = table.remove(queue, 1)
				local comp = getEdgeComp(s)
				if comp then
					local edge = toEdge(comp)
					roads[#roads + 1] = edge
					for __, n in ipairs({ comp.node0, comp.node1 }) do
						local p = plain(n == comp.node0 and comp.position0 or comp.position1)
						local at = getNode2Segments()[n] or {}
						if #at == 2 and geometry.horizontalDistance(p, offsetPosition) < reach + 10 then
							for __, t in ipairs(at) do
								local c = not seen[t] and not drawnEntities[t] and getEdgeComp(t)
								if c and c.roadType == kind then
									seen[t] = true
									queue[#queue + 1] = t
								end
							end
						end
					end
				end
			end
			-- the parallel's line, both ways, as a straight edge
			local ray = {
				p0 = { x = offsetPosition.x - dir.x * reach, y = offsetPosition.y - dir.y * reach, z = offsetPosition.z },
				p1 = { x = offsetPosition.x + dir.x * reach, y = offsetPosition.y + dir.y * reach, z = offsetPosition.z },
			}
			ray.t0 = { x = ray.p1.x - ray.p0.x, y = ray.p1.y - ray.p0.y, z = 0 }
			ray.t1 = ray.t0
			local best, bestS = nil, math.huge
			local reasons = {}
			for __, road in ipairs(roads) do
				-- the line through an end node of the road (an existing junction, e.g. a T
				-- built earlier and now extended to an X): the intersection search below
				-- misses points at an edge's very end (seen 2026-10-03)
				for __, p in ipairs({ road.p0, road.p1 }) do
					local dx, dy = p.x - offsetPosition.x, p.y - offsetPosition.y
					local s = dx * dir.x + dy * dir.y
					local off = math.abs(dx * dir.y - dy * dir.x)
					if off < JUNCTION_REUSE_DISTANCE and math.abs(s) <= reach and math.abs(s) < math.abs(bestS) then
						best, bestS = { x = p.x, y = p.y, z = offsetPosition.z }, s
					end
				end
				for __, x in ipairs(geometry.intersections(ray, road)) do
					local angle = geometry.crossingAngle(ray, x.ua, road, x.ub)
					local s = (x.pointB.x - offsetPosition.x) * dir.x + (x.pointB.y - offsetPosition.y) * dir.y
					if angle < minAngle then
						reasons[#reasons + 1] = string.format("meets at %.1f deg", angle)
					elseif math.abs(s) < math.abs(bestS) then
						best, bestS = { x = x.pointB.x, y = x.pointB.y, z = offsetPosition.z }, s
					end
				end
			end
			if best then
				log(string.format("  node %d: on a road at an angle, parallel end slid %.2f m along itself to meet it", entity, bestS))
			else
				log(string.format("  node %d: on a road, parallel end not slid (%d road edges searched within %.0f m%s)", entity, #roads,
					reach, #reasons > 0 and ("; " .. table.concat(reasons, "; ")) or ""))
				if #reasons > 0 then
					-- the parallel meets the road too flat to branch off it: left as it is, it
					-- stopped short of the road or ran across it (2026-10-03, T under 15
					-- degrees); refused as too shallow
					stats.shallow = stats.shallow + 1
				end
			end
			return best
		end

		local function getNode(entity, position, tangent, atStart)
			local node = nodes[entity]
			if node == nil then
				local newPosition = geometry.offsetPoint(position, tangent, offset)
				if newPosition == nil then
					return nil
				end
				local slidFrom = nil
				if useCount[entity] == 1 then
					node = tryCorner(entity, position, tangent, atStart)
					if node == nil then
						local point = branchPoint(entity, position, tangent, newPosition)
						if point then
							slidFrom, newPosition = newPosition, point
						end
					end
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
					elseif streets and useCount[entity] == 1 and segments and #segments >= 2 then
						-- a T on an existing node of the road: a junction like an anchored one,
						-- with the room its angle needs on our side too (2026-10-03: our own node
						-- left 9.7 m from such a T, refused)
						local comp = getEdgeComp(segments[1])
						if comp then
							local e = toEdge(comp)
							local a = geometry.angleBetween(tangent, comp.node0 == node.entity and e.t0 or e.t1)
							cutNodes[node.entity] = true
							cutAt[node.entity] = cutAt[node.entity] or { node = node, angle = math.min(a, 180 - a),
								level = isLevelCrossable(comp) or nil, otherWidth = isLevelCrossable(comp) and (widthOf(comp.roadTemplate) or plannedWidth()) or nil }
						end
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
					local edgeEntity, u, point = findEdgeAt(newPosition, streets)
					if edgeEntity and noJunctions then
						stats.junctions = stats.junctions + 1
						log("  node " .. entity .. ": would branch off edge " .. edgeEntity .. ", road junctions are off")
					elseif edgeEntity then
						node = newNode(point)
						-- roads: the angle of the T decides how much room it needs along the road
						local angle = nil
						if streets then
							local other = toEdge(getEdgeComp(edgeEntity))
							local a = geometry.angleBetween(tangent, geometry.hermiteDerivative(other.p0, other.p1, other.t0, other.t1, u))
							angle = math.min(a, 180 - a)
						end
						anchorCuts[node.entity] = addSplit(edgeEntity, u, node, angle)
						local anchoredComp = getEdgeComp(edgeEntity)
						if anchoredComp and isLevelCrossable(anchoredComp) then
							-- a road ending on a track: a level crossing T
							anchorCuts[node.entity].level = true
							anchorCuts[node.entity].otherWidth = widthOf(anchoredComp.roadTemplate) or plannedWidth()
						end
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
				-- dev aid: how each end of the run was placed
				if useCount[entity] == 1 then
					local segments = getNode2Segments()[entity]
					log(string.format("  run end: drawn node %d (%d world edges) at %s -> our node %d at %s%s%s", entity,
						segments and #segments or 0, shared.vecToString(position), node.entity, shared.vecToString(node.position),
						slidFrom and " (slid)" or "", corners[node.entity] and " (corner)" or ""))
				end
				if slidFrom then
					branchFrom[node.entity] = slidFrom
				end
				nodes[entity] = node
			end
			return node
		end

		-- offset edges: { node0, node1, edge, props, cuts }
		local offsetEdges = {}
		-- ends slid back past the start of their edge (a T at a small angle shortens a
		-- parallel by more than one edge, 2026-10-03: 86 m at 22.6 degrees)
		local pastEnds = {}
		for __, d in ipairs(drawn) do
			local node0 = getNode(d.node0, d.edge.p0, d.edge.t0, true)
			local node1 = getNode(d.node1, d.edge.p1, d.edge.t1, false)
			local skipEdge = false
			-- a piece refitted to continue one of our roads (see transitions below)
			local transition = nil
			if node0 and node1 then
				-- the parallel as it would run, then cut or lengthened to an end slid onto a
				-- road (branchPoint): cut exactly where it meets the road, lengthened by a
				-- straight piece (a gap under a minimum piece: the end just moves)
				local props = { comp = d.comp, template = d.template, segmentType = d.segmentType, playerOwned = getPlayerOwned(d.entity) }
				local p0 = branchFrom[node0.entity] or node0.position
				local p1 = branchFrom[node1.entity] or node1.position
				local t0, t1 = geometry.offsetTangents(d.edge.p0, d.edge.p1, d.edge.t0, d.edge.t1, p0, p1)
				local natural = { p0 = p0, p1 = p1, t0 = t0, t1 = t1 }
				local startNode, endNode = node0, node1
				for __, atStart in ipairs({ true, false }) do
					local slid = atStart and node0 or node1
					if branchFrom[slid.entity] then
						local x = slid.position
						local u, distance = geometry.closestParameter(x, natural)
						-- shortened when the meeting point lies along the edge: it can be up to
						-- the reuse distance off it, moved onto an existing node of the road
						-- (2026-10-03, road T at 41 degrees: 0.14 m off, taken for lengthening,
						-- the edge ran on across the road and a straight piece came back to the
						-- node, a 179.9 degree bend and a crossing beside the T)
						local keptLength = nil
						-- continuing a road of ours from an existing node on a track (a T extended
						-- into an X): the new piece leaves in that road's direction, as roads go
						-- through a level crossing smoothly (2026-10-04: a parallel cut along a
						-- curve left its T node at an angle, the game refused the kink)
						-- (the road it continues: of ours at the node, the one closest to the
						-- parallel's own direction there, within 90 degrees; at a junction the
						-- crossing road is not it, 2026-10-05: a parallel left its T node along the
						-- main road)
						local continueDir = nil
						-- (smooth only through a level crossing: at a road junction native kinks)
						local atLevelCrossing = false
						for __, seg in ipairs(slid.entity >= 0 and getNode2Segments()[slid.entity] or {}) do
							local c = getEdgeComp(seg)
							atLevelCrossing = atLevelCrossing or (c ~= nil and isLevelCrossable(c))
						end
						if slid.entity >= 0 and atLevelCrossing then
							local own = atStart and natural.t0 or natural.t1
							local bestAngle = 90
							for __, seg in ipairs(getNode2Segments()[slid.entity] or {}) do
								local c = not drawnEntities[seg] and getEdgeComp(seg) or nil
								if c and isPlanned(c) then
									local e = toEdge(c)
									local leaving = c.node0 == slid.entity and e.t0 or { x = -e.t1.x, y = -e.t1.y, z = -e.t1.z }
									-- ours leaves the node against it (at its start), arrives along it (at its end)
									local dir = atStart and { x = -leaving.x, y = -leaving.y, z = -leaving.z } or leaving
									local angle = geometry.angleBetween(dir, own)
									if angle < bestAngle then
										continueDir, bestAngle = dir, angle
									end
								end
							end
						end
						-- (continuing one of our roads, the piece is refitted from the node in that
						-- road's direction whatever the slide missed by: the type's minimum radius
						-- decides; otherwise only a node moved onto the road may be off the edge)
						local tolerance = continueDir and math.huge or (JUNCTION_REUSE_DISTANCE + 0.05)
						if distance < tolerance and u > 0.001 and u < 0.999 then
							local first, second = geometry.split(natural, u)
							keptLength = geometry.arcLength(atStart and second or first)
						end
						local endHere = geometry.horizontalDistance(x, atStart and natural.p0 or natural.p1)
						if not keptLength and endHere <= JUNCTION_REUSE_DISTANCE then
							-- the parallel already ends where it meets the road (a square T extended
							-- straight on, 2026-10-05: a 0.0 m straight piece added there was refused)
							if atStart then
								natural.p0 = x
							else
								natural.p1 = x
							end
							if continueDir then
								natural = atStart and geometry.arcCubic(x, continueDir, natural.p1, natural.t1)
									or geometry.arcCubic(natural.p0, natural.t0, x, continueDir)
							end
						elseif keptLength and keptLength < pieceMinimum() then
							-- shortened to almost nothing (2026-10-03: 0.18 m left, its other node
							-- right on the road): the edge goes, the one before ends at the road
							pastEnds[#pastEnds + 1] = { slid = slid, x = x, atStart = atStart,
								other = atStart and node1 or node0, distance = distance }
							skipEdge = true
						elseif keptLength then
							local first, second = geometry.split(natural, u)
							natural = atStart and second or first
							if atStart then
								natural.p0 = x
							else
								natural.p1 = x
							end
							if continueDir then
								local refit = atStart and geometry.arcCubic(x, continueDir, natural.p1, natural.t1)
									or geometry.arcCubic(natural.p0, natural.t0, x, continueDir)
								-- (our own new road: how tight it may curve is the only limit, checked
								-- with the plan; too tight, the transition is made longer, see below)
								natural = refit
								transition = { atStart = atStart, dir = continueDir }
							end
						elseif (function()
							-- the meeting point behind the end (inside the edge, but too far off it
							-- to shorten): lengthening would run back over the edge
							local far = atStart and natural.p0 or natural.p1
							-- (at the end itself there is nothing to fit: 90 degree T ends land right
							-- on the road, and the direction test there is rounding noise)
							if geometry.horizontalDistance(x, far) <= JUNCTION_REUSE_DISTANCE then
								return false
							end
							local t = atStart and natural.t0 or natural.t1
							local dot = (x.x - far.x) * t.x + (x.y - far.y) * t.y
							return (atStart and dot > 0) or (not atStart and dot < 0)
						end)() then
							-- shortened by more than this edge: the edge goes, the one before it is
							-- shortened instead (see pastEnds below)
							pastEnds[#pastEnds + 1] = { slid = slid, x = x, atStart = atStart,
								other = atStart and node1 or node0, distance = distance }
							skipEdge = true
						elseif (function()
							-- lengthened as one edge: the road builder leaves a junction with one
							-- edge, a short straight piece before a node there was refused (seen
							-- 2026-10-02 at 70 degrees: 5.9 and 12.6 m pieces, Construction Not
							-- Possible). The same curve, arc-like from the junction with the old
							-- directions: exact for a straight, close for a curve.
							local q0, q1 = atStart and x or natural.p0, atStart and natural.p1 or x
							local whole = geometry.arcCubic(q0, (atStart and continueDir) or natural.t0, q1,
								(not atStart and continueDir) or natural.t1)
							local far = atStart and natural.p0 or natural.p1
							local straight = atStart and { p0 = x, p1 = far, t0 = { x = far.x - x.x, y = far.y - x.y, z = far.z - x.z },
								t1 = { x = far.x - x.x, y = far.y - x.y, z = far.z - x.z } }
								or { p0 = far, p1 = x, t0 = { x = x.x - far.x, y = x.y - far.y, z = x.z - far.z },
								t1 = { x = x.x - far.x, y = x.y - far.y, z = x.z - far.z } }
							local deviation = atStart and geometry.mergeDeviation(straight, natural, whole)
								or geometry.mergeDeviation(natural, straight, whole)
							if deviation <= REFIT_MAX_DEVIATION and geometry.minRadiusAlong(whole) >= allowedRadius(templateOf(props)) then
								natural = whole
								log(string.format("  node %d: lengthened %.1f m to meet the road, as one edge (strays %.3f m)", slid.entity,
									geometry.horizontalDistance(x, far), deviation))
								return true
							end
							return false
						end)() then
							-- done above
						else
							local far = atStart and natural.p0 or natural.p1
							local mid = newNode(far)
							local straight = atStart and { x = far.x - x.x, y = far.y - x.y, z = far.z - x.z }
								or { x = x.x - far.x, y = x.y - far.y, z = x.z - far.z }
							offsetEdges[#offsetEdges + 1] = {
								node0 = atStart and slid or mid,
								node1 = atStart and mid or slid,
								edge = { p0 = atStart and x or far, p1 = atStart and far or x, t0 = straight, t1 = straight },
								props = props,
								cuts = {},
							}
							if atStart then
								startNode = mid
							else
								endNode = mid
							end
							log(string.format("  node %d: lengthened by a straight %.1f m to meet the road", slid.entity,
								geometry.horizontalDistance(x, far)))
						end
					end
				end
				node0, node1 = startNode, endNode
				local edge = natural
				t0, t1 = edge.t0, edge.t1
				local radius = geometry.radius(edge.p0, edge.p1, t0, t1)
				-- on the inside of a bend tighter than the offset the track turns inside out:
				-- its ends swap over, the chord runs against the drawn one
				local dx, dy = edge.p1.x - edge.p0.x, edge.p1.y - edge.p0.y
				local ex, ey = d.edge.p1.x - d.edge.p0.x, d.edge.p1.y - d.edge.p0.y
				if dx * ex + dy * ey <= 0 then
					radius = 0
				end
				if not skipEdge then
					-- (a refitted transition is measured once made long enough, with the plan)
					if not transition then
						stats.minRadius = math.min(stats.minRadius, radius)
					end
					offsetEdges[#offsetEdges + 1] = {
						node0 = node0,
						node1 = node1,
						edge = edge,
						props = props,
						cuts = {},
						transition = transition,
					}
				end
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

		-- each end slid past its edge's start: the edges before it are walked back to the
		-- one the meeting point lies on, which is cut there and ends at the slid node; the
		-- edges and nodes in between go
		for __, pe in ipairs(pastEnds) do
			local other, fitted = pe.other, false
			for __ = 1, 10 do
				local index = nil
				for i, oe in ipairs(offsetEdges) do
					if (pe.atStart and oe.node0 == other) or (not pe.atStart and oe.node1 == other) then
						index = i
					end
				end
				if index == nil then
					break
				end
				local oe = offsetEdges[index]
				local u, distance = geometry.closestParameter(pe.x, oe.edge)
				local endPosition = pe.atStart and oe.edge.p0 or oe.edge.p1
				if geometry.horizontalDistance(pe.x, endPosition) < pieceMinimum() then
					-- the meeting point right beyond this edge's end: the end moves onto it
					if pe.atStart then
						oe.edge.p0, oe.node0 = pe.x, pe.slid
					else
						oe.edge.p1, oe.node1 = pe.x, pe.slid
					end
					movable[other.entity] = nil
					log(string.format("  node %d: the parallel shortened onto its node %d, which goes", pe.slid.entity, other.entity))
					fitted = true
					break
				end
				if distance < JUNCTION_REUSE_DISTANCE + 0.05 and u > 0.001 and u < 0.999 then
					local first, second = geometry.split(oe.edge, u)
					if pe.atStart then
						second.p0 = pe.x
						oe.edge, oe.node0 = second, pe.slid
					else
						first.p1 = pe.x
						oe.edge, oe.node1 = first, pe.slid
					end
					movable[other.entity] = nil
					log(string.format("  node %d: the parallel shortened past its node %d, onto the edge before", pe.slid.entity, other.entity))
					fitted = true
					break
				end
				-- not on this one either: it goes too, on to the next
				table.remove(offsetEdges, index)
				movable[other.entity] = nil
				other = pe.atStart and oe.node1 or oe.node0
			end
			if not fitted then
				stats.unfitEnd = string.format("the end of a parallel at node %d could not be fitted to the road (%.2f m off its line)",
					pe.slid.entity, pe.distance)
				log("  " .. stats.unfitEnd)
			end
		end

		-- A refitted piece that turns tighter than the type allows takes in the next piece of
		-- the parallel and is refitted over both, as often as it needs: the transition from
		-- the old road into the curve is as long as the curve needs, not one edge (2026-10-04:
		-- 47.6 m where a concentric parallel would curve at 98 m). Not across a crossing.
		for __, oe in ipairs(offsetEdges) do
			local t = oe.transition
			local limit = t and allowedRadius(templateOf(oe.props)) or nil
			for __ = 1, 6 do
				if not t or geometry.minRadiusAlong(oe.edge) >= limit then
					break
				end
				local far = t.atStart and oe.node1 or oe.node0
				local index = nil
				for i, other in ipairs(offsetEdges) do
					if other ~= oe and ((t.atStart and other.node0 == far) or (not t.atStart and other.node1 == far)) then
						index = i
					end
				end
				local nb = index and offsetEdges[index]
				if nb == nil or #nb.cuts > 0 or #oe.cuts > 0 or not movable[far.entity] then
					break
				end
				local longer = t.atStart and geometry.arcCubic(oe.edge.p0, t.dir, nb.edge.p1, nb.edge.t1)
					or geometry.arcCubic(nb.edge.p0, nb.edge.t0, oe.edge.p1, t.dir)
				if geometry.minRadiusAlong(longer) <= geometry.minRadiusAlong(oe.edge) then
					break
				end
				oe.edge = longer
				if t.atStart then
					oe.node1 = nb.node1
				else
					oe.node0 = nb.node0
				end
				movable[far.entity] = nil
				table.remove(offsetEdges, index)
				log(string.format("  transition into the curve made longer over node %d (now bends at %.1f m)", far.entity,
					geometry.minRadiusAlong(longer)))
			end
		end

		local phase = lap("offsets", timing.trackStart)
		-- crossings with existing tracks on the same level get a shared node
		-- (own node .. ":" .. existing edge) of crossings made at one of our nodes
		local crossingNodes = {}
		-- An offset edge that ends on a node of the other edge meets it there, it does not
		-- cross it: an intersection right beside that node is the same meeting (2026-10-03,
		-- road T at 47 and 53 degrees: a parallel lengthened onto existing node 567 also
		-- "crossed" its edge 0.19 m short of it, leaving a 0.2 m piece).
		local function awayFromSharedNode(xs, oe, comp)
			local result = {}
			for __, x in ipairs(xs) do
				local beside = false
				for __, n in ipairs({ oe.node0, oe.node1 }) do
					if (n.entity == comp.node0 or n.entity == comp.node1)
						and geometry.horizontalDistance(x.pointA, n.position) < SHARED_NODE_MEETING_DISTANCE then
						beside = true
					end
				end
				if not beside then
					result[#result + 1] = x
				end
			end
			return result
		end
		for __, oe in ipairs(offsetEdges) do
			for __, entity in ipairs(findEdgesNear(oe.edge)) do
				local comp = not drawnEntities[entity] and getEdgeComp(entity) or nil
				-- a road over a track or the other way round: a level crossing
				local level = comp and not isPlanned(comp) and isLevelCrossable(comp) or false
				local minAngle = level and MIN_CROSSING_ANGLE or minCrossingAngle()
				if comp and (isPlanned(comp) or level) then
					-- one edge table per existing edge and plan, so its sampled polyline is
					-- reused for every offset edge it is tested against
					local other = shared.PERF_MEASURES and worldEdges[entity] or nil
					if other == nil then
						other = toEdge(comp)
						worldEdges[entity] = other
					end
					for __, x in ipairs(awayFromSharedNode(geometry.intersections(oe.edge, other), oe, comp)) do
						local angle = geometry.crossingAngle(oe.edge, x.ua, other, x.ub)
						-- (a crossing right at one of our own nodes, at the end of both offset
						-- edges there, is not reported here at all; see below)
						-- A crossing right at a plain node of the other track (two edges of one
						-- track meet there, e.g. a leftover of an earlier crossing): cut just
						-- inside the edge; the node is then merged away as for any cut next to
						-- it, and the crossing placed on the merged curve. Once per node.
						-- Roads: crossing right at an existing junction of the other road (e.g. a
						-- T built earlier, now extended to an X): go through that node instead of
						-- crossing a hair beside it (seen 2026-10-03: a crossing 0.10 m from a T's
						-- node, refused as a 0.1 m piece).
						local junctionNode = nil
						if streets and not level and math.abs(x.pointA.z - x.pointB.z) < NODE_SNAP_HEIGHT and isAwayFromEnds(oe.edge, x.pointA) then
							for __, e in ipairs({ { other.p0, comp.node0 }, { other.p1, comp.node1 } }) do
								if geometry.horizontalDistance(x.pointB, e[1]) < JUNCTION_REUSE_DISTANCE then
									local segments = getNode2Segments()[e[2]]
									if segments and #segments >= 3 and not drawnNodes[e[2]] then
										junctionNode = { entity = e[2], position = e[1] }
									end
								end
							end
						end
						local plainNode = nil
						if junctionNode then
							local key = "j" .. junctionNode.entity .. ":" .. tostring(oe)
							if not crossingNodes[key] then
								crossingNodes[key] = true
								local node = { entity = junctionNode.entity, position = junctionNode.position }
								oe.cuts[#oe.cuts + 1] = { u = geometry.closestParameter(node.position, oe.edge), node = node, angle = angle, entity = entity }
								cutNodes[node.entity] = true
								cutAt[node.entity] = cutAt[node.entity] or oe.cuts[#oe.cuts]
								reusedNodes[node.entity] = true
								stats.crossings = stats.crossings + 1
								log(string.format("  through existing junction %d of edge %d, %.1f deg, %.2f m off our line", node.entity, entity,
									angle, geometry.horizontalDistance(node.position, x.pointA)))
							end
						elseif math.abs(x.pointA.z - x.pointB.z) < NODE_SNAP_HEIGHT
							and isAwayFromEnds(oe.edge, x.pointA) and not isAwayFromEnds(other, x.pointB) then
							local n = geometry.horizontalDistance(x.pointB, other.p0) <= EDGE_END_DISTANCE and comp.node0 or comp.node1
							local segments = getNode2Segments()[n]
							if segments and #segments == 2 and not drawnNodes[n] and not reusedNodes[n]
								and not crossingNodes["w" .. n .. ":" .. tostring(oe)] then
								plainNode = n
							end
						end
						if junctionNode then
							-- through the junction, above
						elseif plainNode then
							crossingNodes["w" .. plainNode .. ":" .. tostring(oe)] = true
							if noJunctions and not level then
								stats.junctions = stats.junctions + 1
							elseif angle < minAngle then
								stats.shallow = stats.shallow + 1
							else
								local node = newNode(x.pointA)
								local u = math.max(0.001, math.min(0.999, x.ub))
								oe.cuts[#oe.cuts + 1] = { u = x.ua, node = node, angle = angle, entity = entity, level = level or nil,
									otherWidth = widthOf(comp.roadTemplate) or plannedWidth() }
								local cut = addSplit(entity, u, node, angle)
								cut.level = level or nil
								stats.crossings = stats.crossings + 1
								log("  crossing edge " .. entity .. string.format(" at its plain node %d, %.1f deg ", plainNode, angle) .. shared.vecToString(x.pointA))
							end
						elseif math.abs(x.pointA.z - x.pointB.z) < NODE_SNAP_HEIGHT
							and isAwayFromEnds(oe.edge, x.pointA) and isAwayFromEnds(other, x.pointB) then
							if noJunctions and not level then
								stats.junctions = stats.junctions + 1
								log(string.format("  would cross edge %d at %.1f deg, road junctions are off", entity, angle))
							elseif angle < minAngle then
								-- the game crashes building the geometry of a crossing this
								-- shallow, better let the build fail on the collision
								stats.shallow = stats.shallow + 1
								log(string.format("  crossing edge %d at %.1f deg is too shallow, not built", entity, angle))
							else
								local node = newNode(x.pointA)
								oe.cuts[#oe.cuts + 1] = { u = x.ua, node = node, angle = angle, entity = entity, level = level or nil,
									otherWidth = widthOf(comp.roadTemplate) or plannedWidth() }
								local cut = addSplit(entity, x.ub, node, angle)
								cut.level = level or nil
								stats.crossings = stats.crossings + 1
								-- roads: the spacing the game needs between parallel roads crossing a
								-- road at this angle (native X, 2026-10-03: the corners of neighbouring
								-- junctions about 2.5 m apart along the crossed road)
								if streets and not level then
									local crossedWidth = roadWidth(comp.roadTemplate)
									if crossedWidth then
										local a = math.rad(angle)
										local need = crossedWidth * math.cos(a) + ROAD_CORNER_GAP * math.sin(a)
										if need > (stats.spacingNeeded or 0) then
											stats.spacingNeeded, stats.spacingAngle = need, angle
										end
									end
								end
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

		-- (each node of ours is checked once, though two of our edges share it)
		local nodeChecked = {}
		-- a rough distance from the edge's chord, to skip edges far from the node before the
		-- exact search (a curve stays within about a quarter of its chord from the chord)
		local function nearChord(position, e)
			local dx, dy = e.p1.x - e.p0.x, e.p1.y - e.p0.y
			local len2 = dx * dx + dy * dy
			local t = len2 > 1e-9 and math.max(0, math.min(1, ((position.x - e.p0.x) * dx + (position.y - e.p0.y) * dy) / len2)) or 0
			local ox, oy = position.x - (e.p0.x + t * dx), position.y - (e.p0.y + t * dy)
			return math.sqrt(ox * ox + oy * oy) <= 0.3 * math.sqrt(len2) + 1
		end
		for __, oe in ipairs(offsetEdges) do
			for which, node in ipairs({ oe.node0, oe.node1 }) do
				if movable[node.entity] and not crossingAtNode[node.entity] and not nodeChecked[node.entity] then
					nodeChecked[node.entity] = true
					local center = api.type.Vec2f.new(node.position.x, node.position.y)
					for __, entity in ipairs(edgesInCircle(center, EDGE_SEARCH_RADIUS)) do
						local comp = not drawnEntities[entity] and getEdgeComp(entity) or nil
						local level = comp and not isPlanned(comp) and isLevelCrossable(comp) or false
						local other = comp and (isPlanned(comp) or level) and not crossingNodes[node.entity .. ":" .. entity] and (worldEdges[entity] or toEdge(comp)) or nil
						local u, distance, point = nil, math.huge, nil
						if other and nearChord(node.position, other) then
							u, distance = geometry.closestParameter(node.position, other)
							point = geometry.hermite(other.p0, other.p1, other.t0, other.t1, u)
						end
						-- a crossing already found near the node, with this edge
						local found = false
						if distance < 0.15 then
							for __, e in ipairs(offsetEdges) do
								for __, cut in ipairs(e.cuts) do
									if cut.entity == entity and geometry.horizontalDistance(cut.node.position, node.position) < 1 then
										found = true
									end
								end
							end
						end
						if other then
							if not found and distance < 0.15 and isAwayFromEnds(other, point)
								and math.abs(point.z - node.position.z) < NODE_SNAP_HEIGHT then
								crossingNodes[node.entity .. ":" .. entity] = true
								local angle = geometry.crossingAngle(oe.edge, which == 1 and 0 or 1, other, u)
								if noJunctions and not level then
									stats.junctions = stats.junctions + 1
								elseif angle < (level and MIN_CROSSING_ANGLE or minCrossingAngle()) then
									stats.shallow = stats.shallow + 1
								elseif snapOntoCrossing(node, other) then
									u = geometry.closestParameter(node.position, other)
									movable[node.entity] = nil
									crossingAtNode[node.entity] = true
									local cut = addSplit(entity, u, node, angle)
									if level then
										cut.level, cut.otherWidth = true, widthOf(comp.roadTemplate) or plannedWidth()
									end
									stats.crossings = stats.crossings + 1
									log("  crossing edge " .. entity .. string.format(" at u = %.3f, %.1f deg, through own node %d ", u, angle, node.entity)
										.. shared.vecToString(node.position))
								else
									-- not without bending: the track would run through the other one
									stats.missedCrossing = string.format("a crossing at own node %d could not be placed (on edge %d, nodes %d -> %d%s)",
										node.entity, entity, comp.node0, comp.node1, (drawnNodes[comp.node0] or drawnNodes[comp.node1]) and ", at the drawn road" or "")
									-- dev aid: where, and on which of our edges (2026-10-03: a node not in the
									-- final plan, after a parallel was shortened to meet the road)
									log(string.format("  could not place: own node %d at %s, %.3f m from edge %d at u = %.3f; our edge %s -> %s %s -> %s",
										node.entity, shared.vecToString(node.position), distance, entity, u, tostring(oe.node0.entity),
										tostring(oe.node1.entity), shared.vecToString(oe.edge.p0), shared.vecToString(oe.edge.p1)))
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
		-- (own nodes near crossings are dealt with when the parallel is re-laid, see the emit)
		local function reversed(oe)
			return { node0 = oe.node1, node1 = oe.node0, edge = geometry.reverse(oe.edge), props = oe.props, cuts = oe.cuts }
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
		trackMovable[#tracks] = movable
		lap("merges", phase)
	end
	local emitStart = clockMs()

	-- emit
	local edgesToAdd = {}
	local edgesToRemove = {}
	-- (options.edgeIdBase: ids clear of another proposal's, see judgeTogether)
	local nextEdgeId = options.edgeIdBase or (overlay and -300000) or -1
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
			origins = props.origins, template = templateOf(props), comp = props.comp }
		-- the game objects only when a proposal is wanted, a check needs just the plan
		if planOnly then
			return
		end
		local segmentStart = clockMs()
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
		if segmentStart then
			timing.segments = timing.segments + clockMs() - segmentStart
		end
	end


	local nodesToRemove = {}

	-- Each existing road or track the plan crosses or joins is re-laid around its new
	-- junctions by one rule (docs/design/2026-10-03_node-placement.md, parallelism_chain):
	-- no plain node within a junction's keep-out, one edge for each stretch between the
	-- nodes that stay, refitted the native way where one curve cannot follow the old one.
	local segmentType = drawn[1].segmentType
	-- the segment type of an existing edge we rebuild: the drawn one's for the same kind,
	-- else street 0 / track 1 (a track re-laid at a level crossing as a street segment made
	-- the game refuse to judge the plan, 2026-10-04)
	local function segmentTypeOf(comp)
		if comp.roadType == drawn[1].comp.roadType then
			return segmentType
		end
		return isStreet(comp.roadType) and 0 or 1
	end
	local node2segments = getNode2Segments()
	-- the longest keep-out of any junction: how far to follow a road past its last crossing
	local reach = 0
	for __, split in pairs(splits) do
		for __, cut in ipairs(split.cuts) do
			-- (a cut-off for how far to look: as if both were wide roads)
			reach = math.max(reach, (junctionRoom(cut, 40, 40)))
		end
	end
	local inChain = {}
	local function fixedNode(n)
		local segments = node2segments[n]
		return segments == nil or #segments ~= 2 or drawnNodes[n] or reusedNodes[n]
	end
	-- the road through the crossed edge, followed both ways through its plain nodes
	local function followChain(startEntity)
		local startComp = splits[startEntity].comp
		local startEdge = toEdge(startComp)
		local edges = { { id = startEntity, edge = startEdge, comp = startComp, reversed = false } }
		local nodes = { { id = startComp.node0, position = startEdge.p0 }, { id = startComp.node1, position = startEdge.p1 } }
		inChain[startEntity] = true
		for __, forward in ipairs({ true, false }) do
			local beyond = 0
			while true do
				local endNode = forward and nodes[#nodes] or nodes[1]
				local last = forward and edges[#edges] or edges[1]
				if fixedNode(endNode.id) then
					break
				end
				local segments = node2segments[endNode.id]
				local other = segments[1] == last.id and segments[2] or segments[1]
				local comp = not inChain[other] and not drawnEntities[other] and getEdgeComp(other) or nil
				if comp == nil or comp.roadType ~= startComp.roadType or comp.roadTemplate ~= startComp.roadTemplate or comp.type ~= startComp.type
					or (comp.objects and #comp.objects > 0) then
					break
				end
				local crossed = splits[other] ~= nil
				if not crossed and beyond > reach then
					break
				end
				local e = toEdge(comp)
				-- runs along: the edge's own direction is the chain's
				local runsAlong, far
				if forward then
					runsAlong = comp.node0 == endNode.id
					far = runsAlong and { id = comp.node1, position = e.p1 } or { id = comp.node0, position = e.p0 }
				else
					runsAlong = comp.node1 == endNode.id
					far = runsAlong and { id = comp.node0, position = e.p0 } or { id = comp.node1, position = e.p1 }
				end
				local entry = { id = other, edge = runsAlong and e or geometry.reverse(e), comp = comp, reversed = not runsAlong }
				inChain[other] = true
				if forward then
					edges[#edges + 1] = entry
					nodes[#nodes + 1] = far
				else
					table.insert(edges, 1, entry)
					table.insert(nodes, 1, far)
				end
				beyond = crossed and 0 or beyond + geometry.arcLength(e)
			end
		end
		return { nodes = nodes, edges = edges }
	end
	-- roads: the smallest angle between the chain and another road at an existing junction
	-- (the same road running on through it does not count)
	local function angleAt(nodeId, tangent, own)
		local best = nil
		for __, s in ipairs(node2segments[nodeId] or {}) do
			local comp = not own[s] and getEdgeComp(s) or nil
			if comp then
				local e = toEdge(comp)
				local a = geometry.angleBetween(tangent, comp.node0 == nodeId and e.t0 or e.t1)
				a = math.min(a, 180 - a)
				if a > 3 and (best == nil or a < best) then
					best = a
				end
			end
		end
		return best
	end
	local function accept(curve, pieces)
		local radius = geometry.minRadiusAlong(curve)
		if radius >= allowedRadius(templateOf({ comp = drawn[1].comp, template = drawn[1].template })) then
			return true
		end
		local tightest = math.huge
		for __, p in ipairs(pieces) do
			tightest = math.min(tightest, geometry.minRadiusAlong(p))
		end
		return radius >= 0.95 * tightest
	end

	local splitEntities = {}
	for entity in pairs(splits) do
		splitEntities[#splitEntities + 1] = entity
	end
	table.sort(splitEntities)
	for __, entity in ipairs(splitEntities) do
		local split = splits[entity]
		local objects = split.comp.objects
		if inChain[entity] then
			-- re-laid with another crossed edge of the same road
		elseif objects and #objects > 0 then
			-- rebuilding the edge would lose its signals, the build will fail on the collision
			log("  not splitting edge " .. entity .. ", it has " .. #objects .. " objects (signals?)")
			stats.skipped = stats.skipped + 1
		else
			local c = followChain(entity)
			local own, compOf, nodeIndex = {}, {}, {}
			for i, e in ipairs(c.edges) do
				own[e.id], compOf[e.id] = i, e.comp
			end
			local nodeById = {}
			for i, n in ipairs(c.nodes) do
				nodeById[n.id] = { entity = n.id, position = n.position }
				nodeIndex[n.id] = i
			end
			local junctions, junctionAt = {}, {}
			for i, e in ipairs(c.edges) do
				for __, cut in ipairs(splits[e.id] and splits[e.id].cuts or {}) do
					-- measured along this (the crossed) road or track, ours across it
					local keep, corner = junctionRoom(cut, widthOf(c.edges[1].comp.roadTemplate) or plannedWidth(), plannedWidth())
					local j = { id = cut.node.entity, position = cut.node.position, keepBefore = keep, keepAfter = keep,
						node = nodeIndex[cut.node.entity], edge = not nodeIndex[cut.node.entity] and i or nil, corner = corner }
					junctions[#junctions + 1] = j
					junctionAt[cut.node.entity] = true
					nodeById[cut.node.entity] = nodeById[cut.node.entity] or cut.node
				end
			end
			-- roads: a junction at an end of the chain (the drawn road's, an existing one)
			-- keeps its room on the chain too
			if streets and planRoadWidth and isStreet(c.edges[1].comp.roadType) then
				for __, endIndex in ipairs({ 1, #c.nodes }) do
					local n = c.nodes[endIndex]
					local segments = node2segments[n.id]
					if segments and #segments >= 3 and not junctionAt[n.id] then
						local tangent = endIndex == 1 and c.edges[1].edge.t0 or c.edges[#c.edges].edge.t1
						local a = angleAt(n.id, tangent, own)
						if a then
							-- dev aid: what makes it a junction (2026-10-03: a refusal named a node the
							-- player knew of no junction at)
							local names = {}
							for __, s in ipairs(segments) do
								names[#names + 1] = tostring(s) .. (own[s] and " (this road)" or "")
							end
							log(string.format("  re-laid road ends at junction %d, %.1f deg: edges %s", n.id, a, table.concat(names, ", ")))
							local keep, corner = junctionRoom({ angle = a }, roadWidth(c.edges[1].comp.roadTemplate) or planRoadWidth, planRoadWidth)
							junctions[#junctions + 1] = { id = n.id, node = endIndex, keepBefore = endIndex == 1 and 0 or keep,
								keepAfter = endIndex == 1 and keep or 0, corner = corner }
						end
					end
				end
			end
			local relayStart = clockMs()
			local result = chainModule.relay(c, junctions, {
				joinTolerance = EXISTING_MAX_DEVIATION,
				refitTolerance = REFIT_MAX_DEVIATION,
				junctionGap = streets and chainModule.ROAD_JUNCTION_GAP or 0,
				newNode = function(position)
					local n = newNode(position)
					nodeById[n.entity] = n
					return n.entity
				end,
				accept = accept,
			})
			if relayStart then
				timing.relay = timing.relay + clockMs() - relayStart
			end
			local ids = {}
			for __, e in ipairs(c.edges) do
				ids[#ids + 1] = tostring(e.id)
			end
			log(string.format("  re-laid road of edges %s: %d junctions, %d nodes removed, %d pieces", table.concat(ids, ","),
				#junctions, #result.removedNodes, #result.pieces))
			for __, problem in ipairs(result.problems) do
				log("  " .. problem)
				stats.relayProblem = stats.relayProblem or problem
				if problem:find("apart, they need", 1, true) then
					-- two junctions closer than their corners allow (refusal text, see the script)
					stats.junctionsTooClose = true
				end
			end
			for __, p in ipairs(result.pieces) do
				local n0, n1, edge = nodeById[p.node0], nodeById[p.node1], p.edge
				if p.reversed then
					n0, n1, edge = n1, n0, geometry.reverse(edge)
				end
				local origin = p.origins[1]
				addSegment(n0, n1, edge,
					{ comp = compOf[origin], segmentType = segmentTypeOf(compOf[origin]), playerOwned = getPlayerOwned(origin), origins = p.origins })
				local length = geometry.arcLength(edge)
				if length < pieceMinimum() - PIECE_TOLERANCE and not stats.shortPiece then
					stats.shortPiece = string.format("a piece of %.1f m next to a crossing or branch at %s, the game needs %.0f m",
						length, shared.vecToString(n0.position), pieceMinimum())
					stats.problemAt = n0.position
				end
			end
			for __, e in ipairs(result.removedEdges) do
				edgesToRemove[#edgesToRemove + 1] = e
			end
			for __, n in ipairs(result.removedNodes) do
				nodesToRemove[#nodesToRemove + 1] = n
				stats.moved = stats.moved + 1
			end
		end
	end

	-- existing parallels ending at a corner now: the edge again with its loose end moved
	for __, r in ipairs(rebuilt) do
		addSegment(r.node0, r.node1, r.edge,
			{ comp = r.comp, segmentType = segmentType, playerOwned = getPlayerOwned(r.entity), origins = r.removeEdges })
		for __, e in ipairs(r.removeEdges) do
			edgesToRemove[#edgesToRemove + 1] = e
		end
		for __, n in ipairs(r.removeNodes) do
			nodesToRemove[#nodesToRemove + 1] = n
		end
		stats.moved = stats.moved + #r.removeNodes
	end

	-- Our own parallels: their nodes only mirror the drawn road's, so they are plain nodes
	-- of a chain like any other and are re-laid around the crossings and junctions on the
	-- parallel by the same rule (parallelism_chain). Edges with nothing near them are
	-- added as they are.
	for ti, runEdges in ipairs(tracks) do
		local movable = trackMovable[ti]
		local edgesAt = {}
		for i, oe in ipairs(runEdges) do
			for __, n in ipairs({ oe.node0, oe.node1 }) do
				edgesAt[n.entity] = edgesAt[n.entity] or {}
				table.insert(edgesAt[n.entity], i)
			end
		end
		local used = {}
		-- the run in order from a node, as far as it goes through nodes with two edges
		local function followRun(start)
			local c = { nodes = { { id = start.entity, position = start.position, fixed = not movable[start.entity] } }, edges = {} }
			local current = start
			while true do
				local index = nil
				for __, i in ipairs(edgesAt[current.entity]) do
					if not used[i] then
						index = i
						break
					end
				end
				if index == nil then
					break
				end
				used[index] = true
				local oe = runEdges[index]
				local forward = oe.node0.entity == current.entity
				local other = forward and oe.node1 or oe.node0
				c.edges[#c.edges + 1] = { id = index, edge = forward and oe.edge or geometry.reverse(oe.edge), reversed = not forward }
				c.nodes[#c.nodes + 1] = { id = other.entity, position = other.position, fixed = not movable[other.entity] }
				current = other
				if #edgesAt[current.entity] ~= 2 then
					break
				end
			end
			return c
		end
		local runs = {}
		for __, oe in ipairs(runEdges) do
			for __, n in ipairs({ oe.node0, oe.node1 }) do
				if #edgesAt[n.entity] ~= 2 then
					local c = followRun(n)
					if #c.edges > 0 then
						runs[#runs + 1] = c
					end
				end
			end
		end
		for i, oe in ipairs(runEdges) do
			if not used[i] then
				-- a closed run: from any of its nodes
				local c = followRun(oe.node0)
				if #c.edges > 0 then
					runs[#runs + 1] = c
				end
			end
		end
		for __, c in ipairs(runs) do
			local nodeById = {}
			local nodeIndex = {}
			for i, n in ipairs(c.nodes) do
				nodeIndex[n.id] = i
			end
			for __, e in ipairs(c.edges) do
				local oe = runEdges[e.id]
				nodeById[oe.node0.entity], nodeById[oe.node1.entity] = oe.node0, oe.node1
			end
			local junctions = {}
			local function addJunction(cut, j, keep)
				-- measured along our road or track, the crossed one across it
				local room, corner = junctionRoom(cut, plannedWidth(), cut.otherWidth or plannedWidth())
				keep = keep or room
				j.corner = corner
				j.keepBefore, j.keepAfter = keep, keep
				junctions[#junctions + 1] = j
			end
			for i, e in ipairs(c.edges) do
				for __, cut in ipairs(runEdges[e.id].cuts) do
					nodeById[cut.node.entity] = nodeById[cut.node.entity] or cut.node
					addJunction(cut, { id = cut.node.entity, position = cut.node.position, node = nodeIndex[cut.node.entity],
						edge = not nodeIndex[cut.node.entity] and i or nil })
				end
			end
			-- nodes of ours that are junctions themselves: a crossing right at the node, a T
			-- anchored on a road or on one of its nodes
			for i, n in ipairs(c.nodes) do
				local cut = cutAt[n.id]
				if cut then
					local already = false
					for __, j in ipairs(junctions) do
						already = already or j.id == n.id
					end
					if not already then
						-- (a switch's zone lies along the track it branches off, not along ours)
						addJunction(cut, { id = n.id, node = i }, cut.zone and pieceMinimum() or nil)
					end
				end
			end
			local relayStart = clockMs()
			local result = chainModule.relay(c, junctions, {
				joinTolerance = MAX_MERGE_DEVIATION,
				refitTolerance = MAX_MERGE_DEVIATION,
				junctionGap = streets and chainModule.ROAD_JUNCTION_GAP or 0,
				newNode = function(position)
					local n = newNode(position)
					nodeById[n.entity] = n
					return n.entity
				end,
				accept = accept,
			})
			if relayStart then
				timing.relay = timing.relay + clockMs() - relayStart
			end
			if #result.removedNodes > 0 or #result.problems > 0 then
				log(string.format("  re-laid our parallel: %d junctions, %d own nodes dropped, %d pieces", #junctions,
					#result.removedNodes, #result.pieces))
			end
			for __, problem in ipairs(result.problems) do
				log("  " .. problem)
				stats.relayProblem = stats.relayProblem or problem
				if problem:find("apart, they need", 1, true) then
					-- two junctions closer than their corners allow (refusal text, see the script)
					stats.junctionsTooClose = true
				end
			end
			stats.dropped = stats.dropped + #result.removedNodes
			local function emitOwn(n0, n1, edge, props)
				addSegment(n0, n1, edge, props)
				stats.edges = stats.edges + 1
				if cutNodes[n0.entity] or cutNodes[n1.entity] then
					local length = geometry.arcLength(edge)
					if length < pieceMinimum() - PIECE_TOLERANCE and not stats.shortPiece then
						stats.shortPiece = string.format("a piece of %.1f m next to a crossing or branch at %s, the game needs %.0f m",
							length, shared.vecToString(n0.position), pieceMinimum())
						stats.problemAt = n0.position
					end
				end
			end
			for __, p in ipairs(result.pieces) do
				-- runs the way the parallel's own edge ran (one-way roads, the reverse option)
				local n0, n1, edge = nodeById[p.node0], nodeById[p.node1], p.edge
				if p.reversed then
					n0, n1, edge = n1, n0, geometry.reverse(edge)
				end
				emitOwn(n0, n1, edge, runEdges[p.origins[1]].props)
			end
			local relaid = {}
			for __, id in ipairs(result.removedEdges) do
				relaid[id] = true
			end
			for __, e in ipairs(c.edges) do
				if not relaid[e.id] then
					local oe = runEdges[e.id]
					emitOwn(oe.node0, oe.node1, oe.edge, oe.props)
				end
			end
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
	-- nodes where an existing edge stays attached are junctions, not nodes our road runs
	-- through: two of our edges meeting there may turn (2026-10-03, a road T on an existing
	-- node, our re-laid main road and the parallel met at 158.7 degrees, "track bends")
	local skipBend = {}
	for node in pairs(corners) do
		skipBend[node] = true
	end
	do
		local removed = {}
		for __, e in ipairs(edgesToRemove) do
			removed[e] = true
		end
		local seen = {}
		for __, e in ipairs(stats.plan) do
			for __, node in ipairs({ e.node0, e.node1 }) do
				if not seen[node] then
					seen[node] = true
					for __, s in ipairs(getNode2Segments()[node] or {}) do
						if not removed[s] then
							skipBend[node] = true
						end
					end
				end
			end
		end
	end
	stats.problems = geometry.checkPlan(stats.plan, nil, skipBend)
	-- Roads: the finished plan against the native rules, whatever placed its nodes
	-- (2026-10-03: nodes left near junctions by one mechanism or another kept turning up as
	-- the game's "Construction Not Possible", and corners overlapping crashed the game in
	-- StreetShapeFactory). A plain node of ours next to a junction must be beyond the
	-- junction's room; two junctions joined by one edge must not overlap at their corners.
	if isStreet(planRoadType) and planRoadWidth then
		local half = planRoadWidth / 2
		local function corner(cut)
			local a = math.rad(math.max(cut.angle or 90, 1))
			return half / math.sin(a) + half / math.tan(a)
		end
		local edgesAtNode = {}
		for __, e in ipairs(stats.plan) do
			for __, n in ipairs({ e.node0, e.node1 }) do
				edgesAtNode[n] = (edgesAtNode[n] or 0) + 1
			end
		end
		-- a plain node: two edges in all (ours and existing ones that stay), not a junction
		local removedSet = {}
		for __, id in ipairs(edgesToRemove) do
			removedSet[id] = true
		end
		local function plainOurs(n)
			if cutAt[n] or drawnNodes[n] then
				return false
			end
			local count = edgesAtNode[n] or 0
			for __, s in ipairs(getNode2Segments()[n] or {}) do
				if not removedSet[s] then
					count = count + 1
				end
			end
			return count == 2
		end
		for __, e in ipairs(stats.plan) do
			local length = geometry.arcLength(e.edge)
			local c0, c1 = e.node0 and cutAt[e.node0], e.node1 and cutAt[e.node1]
			-- (level crossings keep their own, smaller room, applied when re-laying)
			if c0 and c0.level then
				c0 = nil
			end
			if c1 and c1.level then
				c1 = nil
			end
			if c0 and c1 and c0.angle and c1.angle then
				local need = corner(c0) + corner(c1)
				if length < need then
					stats.junctionsOverlap = stats.junctionsOverlap or string.format(
						"junctions %d and %d only %.1f m apart, their corners need %.1f m", e.node0, e.node1, length, need)
				end
			end
			for __, pair in ipairs({ { c0, e.node1 }, { c1, e.node0 } }) do
				local cut, other = pair[1], pair[2]
				local room = cut and (junctionRoom(cut, plannedWidth(), plannedWidth()))
				if cut and cut.angle and plainOurs(other) and length < room - 0.5 then
					stats.nodeInRoom = stats.nodeInRoom or string.format(
						"node %d left %.1f m from junction %d, inside its %.1f m room", other, length,
						e.node0 == other and e.node1 or e.node0, room)
				end
			end
		end
		if stats.nodeInRoom then
			log("  plan problem: " .. stats.nodeInRoom)
			table.insert(stats.problems, 1, stats.nodeInRoom)
		end
		if stats.junctionsOverlap then
			stats.junctionsTooClose = true
			log("  plan problem: " .. stats.junctionsOverlap)
			table.insert(stats.problems, 1, stats.junctionsOverlap)
		end
	end
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
	if stats.unfitEnd then
		table.insert(stats.problems, 1, stats.unfitEnd)
	end
	if stats.relayProblem then
		table.insert(stats.problems, 1, stats.relayProblem)
	end
	if stats.missedCrossing then
		table.insert(stats.problems, 1, stats.missedCrossing)
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
	local minRadius = allowedRadius(templateOf({ comp = drawn[1].comp, template = drawn[1].template }))
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
			addAt(p.node0, { entity = p.entity, dir = p.t0, origins = p.origins, piece = p, atStart = true })
			addAt(p.node1, { entity = p.entity, dir = neg(p.t1), origins = p.origins, piece = p, atStart = false })
		end
		-- existing edges at a node, but those left out
		local function worldAt(node, leaveOut)
			local result = {}
			for __, s in ipairs(getNode2Segments()[node] or {}) do
				if not leaveOut[s] then
					local comp = getEdgeComp(s)
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
		-- LaneConnection objects for junctionConnections' plain tables. The API documents
		-- no constructor; if there is none, copies of a connection of a drawn node's config
		-- are reused (each read of laneConnections hands out fresh copies).
		local function makeLaneConnections(connections)
			local make = nil
			pcall(function()
				if api.type.LaneConnection and api.type.LaneConnection.new then
					api.type.LaneConnection.new()
					make = function()
						return api.type.LaneConnection.new()
					end
				end
			end)
			if make == nil then
				for __, d in ipairs(drawn) do
					for __, node in ipairs({ d.node0, d.node1 }) do
						local src = make == nil and sourceConfig(node)
						if src and #src.laneConnections > 0 then
							make = function()
								return src.laneConnections[1]
							end
						end
					end
				end
			end
			if make == nil then
				error("no way to make lane connections")
			end
			local result = {}
			for __, c in ipairs(connections) do
				local lc = make()
				lc.segment0, lc.lane0, lc.segment1, lc.lane1 = c.segment0, c.lane0, c.segment1, c.lane1
				lc.withRoad, lc.withTram = c.withRoad, c.withTram
				result[#result + 1] = lc
			end
			return result
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

		-- Road junctions our extra roads make (crossing or joining a road): every turn, as
		-- the road builder configures its own (docs/studies/2026-10-02_native-junctions.md).
		-- Level crossings (a road and a track sharing a node, either of them ours): the road's
		-- lanes straight through and nothing else, as native (2026-10-03). Track edges never
		-- take part in a node's lane connections.
		do
			for node, entries in pairs(atNode) do
				local ours = false
				for __, e in ipairs(entries) do
					if e.origins == nil then
						ours = true
					end
				end
				if ours and not done[node] then
					local edges = {}
					local levelCrossing = false
					for __, e in ipairs(entries) do
						if e.piece.comp and isStreet(e.piece.comp.roadType) then
							local lanes = nil
							pcall(function()
								lanes = laneConfigsOf(e.piece.comp, e.piece.template)
							end)
							edges[#edges + 1] = { entity = e.entity, dir = e.dir, atStart = e.atStart, lanes = lanes }
						else
							levelCrossing = true
						end
					end
					if not newNodes[node] then
						for __, s in ipairs(getNode2Segments()[node] or {}) do
							if not removedEdges[s] then
								local comp = getEdgeComp(s)
								if comp and isStreet(comp.roadType) then
									local atStart = comp.node0 == node
									edges[#edges + 1] = { entity = s, atStart = atStart, lanes = comp.laneConfigs,
										dir = atStart and plain(comp.tangent0) or neg(plain(comp.tangent1)) }
								elseif comp then
									levelCrossing = true
								end
							end
						end
					end
					if (streets and #edges >= 3) or (levelCrossing and (#edges == 2 or #edges == 1)) then
						-- (a road ending on a track: no lanes to connect, only its crosswalk, as native)
						local connections = #edges >= 2 and junctionConnections(edges) or {}
						-- crosswalks only over roads with sidewalks (the builder gives a highway none)
						local crosswalks = {}
						for __, e in ipairs(edges) do
							if junctionHasSidewalk(e.lanes) then
								crosswalks[#crosswalks + 1] = e.entity
							end
						end
						local ok, err = pcall(function()
							local nc = api.type.BaseNodeLaneConnectionAndEntity.new()
							nc.entity = node
							local comp = nc.comp
							comp.laneConnections = makeLaneConnections(connections)
							comp.crosswalks = crosswalks
							comp.trafficLightPreference = 2
							comp.doubleSlipSwitch = false
							nc.comp = comp
							if not newNodes[node] and worldNodeConfig(node) ~= nil then
								toRemove[#toRemove + 1] = node
							end
							toAdd[#toAdd + 1] = nc
						end)
						done[node] = true
						local listed = {}
						for __, c in ipairs(connections) do
							listed[#listed + 1] = string.format("%d.%d->%d.%d%s%s", c.segment0, c.lane0, c.segment1, c.lane1,
								c.withRoad and " road" or "", c.withTram and " tram" or "")
						end
						log(string.format("  junction node %d: %d edges, %d lane connections [%s], crosswalks [%s]%s", node, #edges,
							#connections, table.concat(listed, ", "), table.concat(crosswalks, ", "),
							ok and "" or (", config failed: " .. tostring(err))))
						if not ok then
							stats.junctionFailed = tostring(err)
						end
					end
				end
			end
		end

		-- our nodes: like the drawn node they mirror, edges matched by direction
		for node, drawnNode in pairs(mirrorOf) do
			local exists = not done[node] and (newNodes[node] or (node >= 0 and not removedNodes[node]))
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
					if (node >= 0 or overlay ~= nil) and not removedNodes[node] and not done[node] then
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
	-- only nodes our edges use: a node left without edges (a parallel shortened past it)
	-- crashed the game in StreetShapeFactory (2026-10-03); before the nodes are emitted and
	-- their configs made
	do
		local used = {}
		for __, e in ipairs(stats.plan) do
			used[e.node0], used[e.node1] = true, true
		end
		local kept = {}
		for __, n in ipairs(nodesToAdd) do
			if used[n.entity] then
				kept[#kept + 1] = n
			else
				log(string.format("  own node %d left without edges, not added", n.entity))
			end
		end
		nodesToAdd = kept
	end
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
				local configsStart = clockMs()
				local toAdd, toRemove = makeNodeConfigs()
				if configsStart then
					timing.configs = timing.configs + clockMs() - configsStart
				end
				proposal.streetProposal.nodeConfigsToAdd = toAdd
				proposal.streetProposal.nodeConfigsToRemove = toRemove
				stats.nodeConfigs = #toAdd
			end)
			if not ok then
				shared.log("node configs left out: " .. tostring(err))
			end
			-- a road junction without its config is what crashed the game before
			-- (map_util.h): never hand one over
			if streets and (not ok or stats.junctionFailed) then
				local problem = "a road junction could not be configured: " .. tostring(stats.junctionFailed or err)
				table.insert(stats.problems, 1, problem)
				log("  plan problem: " .. problem)
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
		stats.timing = string.format("%.0f ms: orient %.0f, offsets %.0f, crossings %.0f, merges %.0f, emit %.0f (re-lay %.0f, game objects %.0f, node configs %.0f), check %.0f; searches: game index %.0f, builder's edges %.0f",
			finished - timing.start, (timing.firstTrack or timing.start) - timing.start, timing.offsets, timing.crossings, timing.merges,
			checkStart - emitStart, timing.relay, timing.segments, timing.configs, finished - checkStart, searchTiming.octree, searchTiming.overlay)
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
	-- negative ids are the builder's proposal (not in the world): asking the engine about
	-- one can crash the game outright (2026-10-03, after "preview removes edge -7")
	if type(entity) ~= "number" or entity < 0 then
		local edge = overlay and overlay.edges[entity]
		if edge then
			parts[#parts + 1] = "proposal edge " .. tostring(edge.node0) .. " -> " .. tostring(edge.node1)
		else
			parts[#parts + 1] = "(in the builder's proposal)"
		end
		return table.concat(parts, " ")
	end
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
		local building = api.engine.getComponent(entity, api.type.ComponentType.TOWN_BUILDING)
		if building then
			parts[#parts + 1] = "town building of construction " .. tostring(building.construction)
				.. ", town " .. tostring(building.town)
			return
		end
		-- dev aid: which components it has, to tell what it is
		local names = {}
		for name, id in pairs(api.type.ComponentType) do
			local found = false
			pcall(function()
				found = type(id) == "number" and api.engine.getComponent(entity, id) ~= nil
			end)
			if found then
				names[#names + 1] = name
			end
		end
		table.sort(names)
		parts[#parts + 1] = "(not an edge, node or construction; components " .. table.concat(names, ", ") .. ")"
	end)
	if not ok then
		parts[#parts + 1] = "(lookup failed)"
	end
	return table.concat(parts, " ")
end
-- The bounding box of an entity, nil if it has none.
local function bboxOf(entity)
	if entity < 0 then
		return nil
	end
	local bbox = nil
	pcall(function()
		local bv = api.engine.getComponent(entity, api.type.ComponentType.BOUNDING_VOLUME)
		if bv then
			bbox = { min = bv.bbox.min, max = bv.bbox.max }
		end
	end)
	return bbox
end

-- Buildings in the way. The game reports a town building our tracks run into as a
-- collision (the builder's own proposal lists the construction to bulldoze instead), so
-- the preview collects those and the plan names them for removal. candidates: {
-- construction, building } from the game's collision reports. Returns the constructions
-- the proposal's edges still pass (within half their width and a little), so one hit
-- earlier in a drag is let go when the drag moves on.
local function buildingsInTheWay(proposal, candidates)
	local result = {}
	if #candidates == 0 then
		return result
	end
	local edges = {}
	for __, s in ipairs(proposal.streetProposal.edgesToAdd) do
		local width = 0
		pcall(function()
			for __, lane in ipairs(s.comp.laneConfigs) do
				width = width + lane.width
			end
		end)
		edges[#edges + 1] = { edge = toEdge(s.comp), reach = width / 2 + 1.5 }
	end
	local function passes(bbox)
		for __, e in ipairs(edges) do
			local edge = e.edge
			local chord = math.sqrt((edge.p1.x - edge.p0.x) ^ 2 + (edge.p1.y - edge.p0.y) ^ 2)
			local n = math.max(4, math.ceil(chord / 2))
			for i = 0, n do
				local p = geometry.hermite(edge.p0, edge.p1, edge.t0, edge.t1, i / n)
				local dx = math.max(bbox.min.x - p.x, 0, p.x - bbox.max.x)
				local dy = math.max(bbox.min.y - p.y, 0, p.y - bbox.max.y)
				if dx * dx + dy * dy <= e.reach * e.reach then
					return true
				end
			end
		end
		return false
	end
	local seen = {}
	for __, c in ipairs(candidates) do
		if not seen[c.construction] and api.engine.entityExists(c.construction) then
			seen[c.construction] = true
			local bbox = bboxOf(c.building) or bboxOf(c.construction)
			if bbox and passes(bbox) then
				result[#result + 1] = c.construction
			end
		end
	end
	return result
end

-- The town building a collision report names, as a candidate for buildingsInTheWay;
-- nil for anything else (industries, stations and the like stay in the way).
local function townBuildingCandidate(entity)
	if entity < 0 then
		return nil
	end
	local candidate = nil
	pcall(function()
		local building = api.engine.getComponent(entity, api.type.ComponentType.TOWN_BUILDING)
		if building and building.construction and building.construction >= 0 then
			candidate = { construction = building.construction, building = entity }
		end
	end)
	return candidate
end

planner.buildingsInTheWay = buildingsInTheWay
planner.townBuildingCandidate = townBuildingCandidate
planner.toEdge = toEdge
planner.getEdgeComp = readEdgeComp
planner.getTrackDistance = getTrackDistance
planner.roadWidth = roadWidth
planner.widthOf = widthOf
planner.defaultGap = defaultGap
planner.parallelDistance = parallelDistance
planner.formatRadius = formatRadius
planner.collectDrawnSegments = collectDrawnSegments
planner.isApplied = isApplied
-- options.overlay: the builder's live street proposal; the plan is made against the
-- world as it will be after it (see setOverlay). Such a plan refers to the builder's
-- made-up entities: build or judge it only joined with the builder's part
-- (planner.joinWithBuilder).
local function makeProposal(drawn, offsets, log, planOnly, options)
	local overlayOk, overlayErr = pcall(setOverlay, options and options.overlay)
	if not overlayOk then
		setOverlay(nil)
		error(overlayErr, 0)
	end
	node2segmentsCache = nil
	local ok, proposal, stats = pcall(makeProposalIn, drawn, offsets, log, planOnly, options)
	setOverlay(nil)
	node2segmentsCache = nil
	if not ok then
		error(proposal, 0)
	end
	return proposal, stats
end

-- A copy of one of the builder's segments with its road type filled in. Pieces of an
-- edge the builder cuts can come without type, style or lane configs in the middle of a
-- drag: they get those of that edge (removedComps: the comps of the builder's removed
-- segments), the one sharing a node with the piece, or for a middle piece (an edge cut
-- twice) the one it lies on. templateName: the type when there is none (the join; the
-- overlay passes nil). A copy: s is the builder's live data, which the builder goes on
-- using (writing to it changed the drag under the builder's feet).
-- Untyped, the overlay's pieces looked like another road type to the planner, which then
-- would not move their nodes: a builder node 31.7 m from our junction, inside its corner,
-- stayed and the game refused the 20 degree X (2026-10-03).
function planner.typedSegment(s, removedComps, templateName)
	local copy = api.type.SegmentAndEntity.new()
	copy.entity = s.entity
	copy.type = s.type
	local from = s.comp
	local comp = copy.comp
	comp.node0 = from.node0
	comp.node1 = from.node1
	comp.position0 = from.position0
	comp.position1 = from.position1
	comp.tangent0 = from.tangent0
	comp.tangent1 = from.tangent1
	comp.type = from.type
	comp.typeIndex = from.typeIndex
	comp.roadType = from.roadType
	comp.roadTemplate = from.roadTemplate
	comp.roadStyle = from.roadStyle
	if from.laneConfigs ~= nil and sizeOf(from.laneConfigs) > 0 then
		comp.laneConfigs = from.laneConfigs
	end
	pcall(function()
		comp.distance = from.distance
	end)
	pcall(function()
		if from.edgeDecorations ~= nil then
			comp.edgeDecorations = from.edgeDecorations
		end
	end)
	pcall(function()
		copy.playerOwned = s.playerOwned
	end)
	-- a piece of a cut edge: the type of that edge
	local source = nil
	for __, r in ipairs(removedComps) do
		if source == nil and (r.node0 == comp.node0 or r.node0 == comp.node1 or r.node1 == comp.node0 or r.node1 == comp.node1) then
			source = r
		end
	end
	if source == nil and nonEmpty(comp.roadTemplate) == nil then
		-- a middle piece (an edge cut twice) shares no node with it: by position
		local mid = geometry.hermite(plain(comp.position0), plain(comp.position1), plain(comp.tangent0), plain(comp.tangent1), 0.5)
		for __, r in ipairs(removedComps) do
			if source == nil and geometry.distanceToEdge(mid, toEdge(r)) < 0.5 then
				source = r
			end
		end
	end
	if nonEmpty(comp.roadTemplate) == nil and source and nonEmpty(source.roadTemplate) then
		comp.roadTemplate = source.roadTemplate
		comp.roadStyle = source.roadStyle
		if comp.laneConfigs == nil or sizeOf(comp.laneConfigs) == 0 then
			comp.laneConfigs = source.laneConfigs
		end
	end
	local name = nonEmpty(comp.roadTemplate) or templateName
	if nonEmpty(comp.roadTemplate) == nil and name then
		comp.roadTemplate = name
		local template = getTemplate(name)
		if template and nonEmpty(comp.roadStyle) == nil then
			comp.roadStyle = template.streetStyle
		end
	end
	if name and (comp.laneConfigs == nil or sizeOf(comp.laneConfigs) == 0) then
		comp.laneConfigs = laneConfigsOf(comp, name)
	end
	return copy
end

-- What is wrong with a street proposal made of these lists, nil if nothing: every edge on
-- nodes that are there (added, or in the world and not removed), no node taken away under
-- an edge that stays, no id twice, configs on nodes that are there. Handed a proposal
-- that does not hold together, makeProposalData crashed the game (a 20 degree road X,
-- 2026-10-03), so the join is checked before the engine sees it.
local function proposalProblem(nodesToAdd, edgesToAdd, edgesToRemove, nodesToRemove, configsToAdd)
	local added, removedNode, removedEdge = {}, {}, {}
	for __, n in ipairs(nodesToAdd) do
		if n.entity >= 0 or added[n.entity] then
			return "node " .. tostring(n.entity) .. " added twice or with a world id"
		end
		added[n.entity] = true
	end
	for __, id in ipairs(nodesToRemove) do
		if id < 0 or removedNode[id] then
			return "node " .. tostring(id) .. " removed twice or not a world node"
		end
		removedNode[id] = true
	end
	for __, id in ipairs(edgesToRemove) do
		if removedEdge[id] or readEdgeComp(id) == nil then
			return "edge " .. tostring(id) .. " removed twice or not in the world"
		end
		removedEdge[id] = true
	end
	local function nodeThere(n)
		if n < 0 then
			return added[n] == true
		end
		return not removedNode[n] and api.engine.getComponent(n, api.type.ComponentType.BASE_NODE) ~= nil
	end
	local edgeSeen = {}
	local usedNode = {}
	for __, s in ipairs(edgesToAdd) do
		local c = s.comp
		if edgeSeen[s.entity] or c.node0 == c.node1 then
			return "edge " .. tostring(s.entity) .. " added twice or from a node to itself"
		end
		edgeSeen[s.entity] = true
		for __, n in ipairs({ c.node0, c.node1 }) do
			if not nodeThere(n) then
				return "edge " .. tostring(s.entity) .. " on node " .. tostring(n) .. ", which is not there"
			end
			usedNode[n] = true
		end
	end
	-- a new node without edges crashed the game (StreetShapeFactory, 2026-10-03)
	for id in pairs(added) do
		if not usedNode[id] then
			return "node " .. tostring(id) .. " added without any edge"
		end
	end
	for id in pairs(removedNode) do
		local stays = nil
		local ok = pcall(function()
			for __, e in ipairs(api.engine.system.streetSystem.getNodeSegments(id)) do
				if not removedEdge[e] then
					stays = e
				end
			end
		end)
		if not ok then
			return "the edges at removed node " .. tostring(id) .. " could not be read"
		end
		if stays then
			return "node " .. tostring(id) .. " removed, edge " .. tostring(stays) .. " stays on it"
		end
	end
	for __, nc in ipairs(configsToAdd) do
		if not nodeThere(nc.entity) then
			return "node config for node " .. tostring(nc.entity) .. ", which is not there"
		end
	end
	return nil
end

-- One SimpleProposal: the builder's live street proposal and our plan made against it
-- (options.overlay). The builder's removals by real id, its new edges and nodes as they
-- are, except those our plan takes away again (it splits a piece the builder adds, it
-- replaces a config the builder gives); our part on top.
local function joinWithBuilder(streetProposal, planned, templateName)
	local ours = planned.streetProposal
	-- elements are kept past their loops (removedComps, the lists to add): see planner.pinned
	local pins = { streetProposal, planned, ours }
	local function pinned(container)
		return planner.pinned(container, pins)
	end
	local function real(id)
		return id < 0 and (-id - 1) or id
	end
	local builderEdge, builderNode, builderConfig = {}, {}, {}
	for __, s in ipairs(pinned(streetProposal.addedSegments)) do
		builderEdge[s.entity] = true
	end
	for __, n in ipairs(pinned(streetProposal.addedNodes)) do
		if n.entity < 0 then
			builderNode[n.entity] = true
		end
	end
	for __, nc in ipairs(pinned(streetProposal.nodeConfigsToAdd)) do
		builderConfig[nc.entity] = true
	end
	local dropEdge, dropNode, dropConfig = {}, {}, {}
	local removedComps = {}
	for __, s in ipairs(pinned(streetProposal.removedSegments)) do
		removedComps[#removedComps + 1] = s.comp
	end
	local edgesToRemove, nodesToRemove, configsToRemove = {}, {}, {}
	local removing = {}
	for __, s in ipairs(pinned(streetProposal.removedSegments)) do
		local id = real(s.entity)
		removing[id] = true
		edgesToRemove[#edgesToRemove + 1] = id
	end
	for __, id in ipairs(pinned(ours.edgesToRemove)) do
		if builderEdge[id] then
			dropEdge[id] = true
		elseif not removing[id] then
			removing[id] = true
			edgesToRemove[#edgesToRemove + 1] = id
		end
	end
	for __, n in ipairs(pinned(streetProposal.removedNodes)) do
		nodesToRemove[#nodesToRemove + 1] = real(n.entity)
	end
	for __, id in ipairs(pinned(ours.nodesToRemove)) do
		if builderNode[id] then
			dropNode[id] = true
		else
			nodesToRemove[#nodesToRemove + 1] = id
		end
	end
	for __, id in ipairs(pinned(streetProposal.nodeConfigsToRemove)) do
		configsToRemove[#configsToRemove + 1] = real(id)
	end
	for __, id in ipairs(pinned(ours.nodeConfigsToRemove)) do
		if builderConfig[id] then
			dropConfig[id] = true
		else
			configsToRemove[#configsToRemove + 1] = id
		end
	end
	local nodesToAdd, edgesToAdd, configsToAdd = {}, {}, {}
	for __, n in ipairs(pinned(streetProposal.addedNodes)) do
		if n.entity < 0 and not dropNode[n.entity] then
			local node = api.type.NodeAndEntity.new()
			node.entity = n.entity
			node.comp.position = n.comp.position
			nodesToAdd[#nodesToAdd + 1] = node
		end
	end
	for __, s in ipairs(pinned(streetProposal.addedSegments)) do
		if not dropEdge[s.entity] then
			-- the live proposal's segments can come without track type or lane configs in
			-- the middle of a drag; an edge without lane configs crashes the game.
			-- Filled in on a copy: s is the builder's own live data, which the builder
			-- goes on using (writing to it changed the drag under the builder's feet).
			local copy = planner.typedSegment(s, removedComps, templateName)
			edgesToAdd[#edgesToAdd + 1] = copy
		end
	end
	-- the builder's configs for nodes our plan takes away (a node it moves, a builder node
	-- it replaces) go with them: a config for a node that is not there crashed the game
	-- (20 degree road X, 2026-10-03); our plan configures the nodes it puts in their place
	local goneNode = {}
	for __, id in ipairs(nodesToRemove) do
		goneNode[id] = true
	end
	for __, nc in ipairs(pinned(streetProposal.nodeConfigsToAdd)) do
		if not dropConfig[nc.entity] and not dropNode[nc.entity] and not goneNode[nc.entity] then
			configsToAdd[#configsToAdd + 1] = nc
		end
	end
	for __, n in ipairs(pinned(ours.nodesToAdd)) do
		nodesToAdd[#nodesToAdd + 1] = n
	end
	for __, s in ipairs(pinned(ours.edgesToAdd)) do
		edgesToAdd[#edgesToAdd + 1] = s
	end
	for __, nc in ipairs(pinned(ours.nodeConfigsToAdd)) do
		if goneNode[nc.entity] or dropNode[nc.entity] then
			error("the plan gives a config to node " .. tostring(nc.entity) .. ", which it takes away", 0)
		end
		configsToAdd[#configsToAdd + 1] = nc
	end
	-- builder nodes whose edges our plan all replaced go too, with their configs (a node
	-- without edges crashed the game, 2026-10-03)
	do
		local used = {}
		for __, s in ipairs(edgesToAdd) do
			used[s.comp.node0], used[s.comp.node1] = true, true
		end
		local keptNodes, keptConfigs = {}, {}
		for __, n in ipairs(nodesToAdd) do
			if used[n.entity] or not builderNode[n.entity] then
				keptNodes[#keptNodes + 1] = n
			end
		end
		for __, nc in ipairs(configsToAdd) do
			if used[nc.entity] or nc.entity >= 0 or not builderNode[nc.entity] then
				keptConfigs[#keptConfigs + 1] = nc
			end
		end
		nodesToAdd, configsToAdd = keptNodes, keptConfigs
	end
	local problem = proposalProblem(nodesToAdd, edgesToAdd, edgesToRemove, nodesToRemove, configsToAdd)
	if problem then
		error("the plan joined with the builder's does not hold together: " .. problem, 0)
	end
	-- the existing nodes and edges the joined proposal refers to: shown later (the menu
	-- redraws it), it must still match the world (2026-10-04: a preview kept past a build
	-- named a node that build removed, and the game crashed redrawing it)
	local refs = { edges = {}, nodes = {} }
	for __, id in ipairs(edgesToRemove) do
		refs.edges[#refs.edges + 1] = id
	end
	for __, id in ipairs(nodesToRemove) do
		refs.nodes[#refs.nodes + 1] = id
	end
	for __, seg in ipairs(edgesToAdd) do
		for __, n in ipairs({ seg.comp.node0, seg.comp.node1 }) do
			if n >= 0 then
				refs.nodes[#refs.nodes + 1] = n
			end
		end
	end
	local joined = api.type.SimpleProposal.new()
	joined.streetProposal.nodesToAdd = nodesToAdd
	joined.streetProposal.edgesToAdd = edgesToAdd
	joined.streetProposal.edgesToRemove = edgesToRemove
	joined.streetProposal.nodesToRemove = nodesToRemove
	joined.streetProposal.nodeConfigsToAdd = configsToAdd
	joined.streetProposal.nodeConfigsToRemove = configsToRemove
	pcall(function()
		joined.constructionsToRemove = planned.constructionsToRemove
	end)
	return joined, refs
end

-- true while every existing node and edge in refs (see joinWithBuilder) is still there
local function refsStillThere(refs)
	if refs == nil then
		return true
	end
	local there = true
	pcall(function()
		for __, id in ipairs(refs.edges) do
			if id >= 0 and api.engine.getComponent(id, api.type.ComponentType.BASE_EDGE) == nil then
				there = false
				return
			end
		end
		for __, id in ipairs(refs.nodes) do
			if id >= 0 and api.engine.getComponent(id, api.type.ComponentType.BASE_NODE) == nil then
				there = false
				return
			end
		end
	end)
	return there
end
planner.refsStillThere = refsStillThere

planner.makeProposal = makeProposal
planner.joinWithBuilder = joinWithBuilder
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
