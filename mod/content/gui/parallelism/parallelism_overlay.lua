-- The network overlay: every road and track edge around the camera as a line, with a
-- ring at each node (larger where 3 or more edges meet), switched on and off with a
-- button in the HUD's mod button area (parallelism_overlay_button.script.lua).
--
-- A 3D overlay only renders as part of the active tool's action (an action descriptor):
-- from a mod's entry plugin it crashed the game (2026-10-09, IsTransformWithContext). So the
-- menu patch adds it to every action descriptor while on. An action function runs as a
-- recipe of its own (the construction menu's declares state and listens to events in it),
-- and the descriptor is built inside it: there each action subscribes to the overlay
-- (overlay.subscribe), so it is redrawn when the view changes. (A tool of the mod's own
-- carrying the overlay ended as soon as another tool took over, tools being exclusive,
-- and stayed as it was drawn, 2026-10-10.)

local builtin = require "::/gui/main/builtin.lua"
local react = require "::/gui/main/react.lua"
local shared = require "parallelism_shared.lua"
local geometry = require "parallelism_geometry.lua"
local planner = require "parallelism_planner.lua"

local overlay = {}

-- node markers: rings of this radius (meters), larger where 3 or more edges meet
overlay.NODE_MARKER = 0.75
overlay.JUNCTION_MARKER = 1.5
overlay.MAX_NODE_MARKERS = 400

-- Around the camera: the spot it looks at, as far as it is away from it, so the view
-- zoomed out covers more. (The cap only spares the game a view it could not read.)
local EDGES_MAX = 1500
local ROAD_COLOR = { 0.7, 0.75, 0.8, 0.8 }
local TRACK_COLOR = { 0.85, 0.7, 0.45, 0.8 }

-- one line of an edge renderable (stepSize: the length of the pieces it's drawn in,
-- default 1 m)
function overlay.makeEdge(e, color, width, stepSize)
	local geom = api.type.EdgeGeometry.new()
	geom.type = api.type.EdgeGeometry.Type.CUBIC_SPLINE
	local spline = geom.cubicSpline
	spline.pos = { api.type.Vec2f.new(e.p0.x, e.p0.y), api.type.Vec2f.new(e.p1.x, e.p1.y) }
	spline.tangent = { api.type.Vec2f.new(e.t0.x, e.t0.y), api.type.Vec2f.new(e.t1.x, e.t1.y) }
	geom.cubicSpline = spline
	geom.height = api.type.Vec2f.new(e.p0.z, e.p1.z)
	geom.length = geometry.arcLength(e)
	geom.width = width
	local edge = builtin.type.EdgeRenderable.Edge.new(geom)
	edge.colors = { api.type.Vec4f.new(color[1], color[2], color[3], color[4]) }
	edge.width = width
	edge.offsetZ = 1.0
	edge.stepSize = stepSize or 1.0
	return edge
end

-- a straight, level line from (x0, y0) to (x1, y1) at height z: one piece, no curve to
-- sample
local function makeStraightEdge(x0, y0, x1, y1, z, color, width)
	local st = api.type.EdgeGeometry.Straight.new()
	st.pos = { api.type.Vec2f.new(x0, y0), api.type.Vec2f.new(x1, y1) }
	local geom = api.type.EdgeGeometry.new()
	geom.type = api.type.EdgeGeometry.Type.STRAIGHT
	geom.straight = st
	geom.height = api.type.Vec2f.new(z, z)
	geom.tangent = api.type.Vec2f.new(0, 0)
	geom.length = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
	geom.width = width
	local edge = builtin.type.EdgeRenderable.Edge.new(geom)
	edge.colors = { api.type.Vec4f.new(color[1], color[2], color[3], color[4]) }
	edge.width = width
	edge.offsetZ = 1.0
	edge.stepSize = 2.0
	return edge
end

-- The square node marker (overlay.MARKER_RING false): the four sides of a square of half
-- size h around p, as straight lines, appended to lines.
function overlay.addSquareLines(lines, p, h, color, width)
	local corners = { { -h, -h }, { h, -h }, { h, h }, { -h, h } }
	for i = 1, 4 do
		local a, b = corners[i], corners[i % 4 + 1]
		lines[#lines + 1] = makeStraightEdge(p.x + a[1], p.y + a[2], p.x + b[1], p.y + b[2], p.z, color, width)
	end
end

-- A node marker: a ring of radius h around p, one arc (one line object where the square
-- took four; nodes move with every plan, so they are made anew each time). Just short of a
-- full turn: a closed one might be degenerate to the renderer. Drawn in pieces of a
-- sixteenth of the circle, or it comes out a polygon. overlay.MARKER_RING false: squares.
overlay.MARKER_RING = true

function overlay.addNodeMarker(lines, p, h, color, width)
	if not overlay.MARKER_RING then
		overlay.addSquareLines(lines, p, h, color, width)
		return
	end
	local angle = 2 * math.pi - 0.02
	local arc = api.type.EdgeGeometry.Arc.new()
	arc.center = api.type.Vec2f.new(p.x, p.y)
	arc.radius = h
	arc.startAngle = 0
	arc.angle = angle
	local geom = api.type.EdgeGeometry.new()
	geom.type = api.type.EdgeGeometry.Type.ARC
	geom.arc = arc
	geom.height = api.type.Vec2f.new(p.z, p.z)
	geom.tangent = api.type.Vec2f.new(0, 0)
	geom.length = h * angle
	geom.width = width
	local edge = builtin.type.EdgeRenderable.Edge.new(geom)
	edge.colors = { api.type.Vec4f.new(color[1], color[2], color[3], color[4]) }
	edge.width = width
	edge.offsetZ = 1.0
	edge.stepSize = math.max(0.05, geom.length / 16)
	lines[#lines + 1] = edge
end

-- (a zero-length edge crashed the game drawing it)
function overlay.drawable(e)
	local t0 = math.sqrt(e.t0.x * e.t0.x + e.t0.y * e.t0.y)
	local t1 = math.sqrt(e.t1.x * e.t1.x + e.t1.y * e.t1.y)
	return geometry.arcLength(e) >= 0.1 and t0 > 1e-3 and t1 > 1e-3
end

-- Nothing is built again that can't have changed (after path-visualizer, 2026-10-24):
-- * each edge in view is read once and kept while it stays in view (entries, by entity:
--   its plain geometry, kind, end nodes and line). A build replaces the edges it reshapes,
--   but entity ids get reused (planner.isApplied), so an id can come back as another edge:
--   after a build the mod hears of (the builder clears, onProposalApply while the HUD
--   overlay is on) everything is read again for a few seconds, which also covers the
--   mod's own build right after the player's; and every few seconds anyway, for builds it
--   doesn't hear of (towns, other tools while the builder is closed);
-- * the lines are joined once per change of the view (version), not on every draw;
-- * node markers are kept by node and look, and drawn as straight lines.
local REREAD_AFTER = 10 -- seconds: entries read again, for builds the mod didn't hear of
local DIRTY_FOR = 3 -- seconds after a build the mod heard of: read again on every step

local state = {
	on = false,
	edges = nil, -- the entries in view, in octree order
	entries = {}, -- entity -> entry (see refresh)
	squares = {}, -- node marker key -> its lines
	key = nil,
	version = 0,
	lines = nil, -- the joined lines, for linesVersion
	linesVersion = nil,
	readAt = nil, -- clock() when the entries were last all dropped
	dirtyUntil = nil, -- clock() until which every step reads everything again (a build)
	failed = false,
	timing = { refreshes = 0, reads = 0, refreshMs = 0, builds = 0, buildMs = 0, since = nil },
}

local function clock()
	local ok, c = pcall(os.clock)
	return ok and c or nil
end

-- dev: the overlay's cost, logged every 10 s while it works (shared.LOG_PLANS)
local function noteTiming(field, started, reads)
	if not shared.LOG_PLANS or not started then
		return
	end
	local c = clock()
	if not c then
		return
	end
	local tm = state.timing
	if field == "refresh" then
		tm.refreshes = tm.refreshes + 1
		tm.refreshMs = tm.refreshMs + (c - started) * 1000
		tm.reads = tm.reads + (reads or 0)
	else
		tm.builds = tm.builds + 1
		tm.buildMs = tm.buildMs + (c - started) * 1000
	end
	tm.since = tm.since or c
	if c - tm.since >= 10 then
		shared.log(string.format("perf [network view]: %d refreshes in %.0f ms (%d edges read), %d line builds in %.0f ms; %d edges, %d lines in view",
			tm.refreshes, tm.refreshMs, tm.reads, tm.builds, tm.buildMs, state.edges and #state.edges or 0, state.lines and #state.lines or 0))
		state.timing = { refreshes = 0, reads = 0, refreshMs = 0, builds = 0, buildMs = 0, since = c }
	end
end

-- After a build: every entry is read again at the next refresh.
function overlay.networkChanged()
	state.entries, state.squares, state.key = {}, {}, nil
	local c = clock()
	if c then
		state.dirtyUntil = c + DIRTY_FOR
	end
end

function overlay.isOn()
	return state.on and not state.failed
end

-- The builder's own view of the network: with the toolbar's Wireframe on, the builder
-- shows the network around the camera too, also while not dragging (set by the menu
-- patch; only in the construction menu's actions, independent of the button above).
function overlay.builderView()
	return state.builderView == true and not state.failed
end

function overlay.setBuilderView(on)
	on = on and true or false
	if state.builderView == on then
		return
	end
	state.builderView = on
	state.key = nil
	if on then
		overlay.refresh()
	end
	state.version = state.version + 1
end

-- whether the network is read at all: for the button's overlay or the builder's view
local function wanted()
	return (state.on or state.builderView) and not state.failed
end

-- switches the overlay on or off (the button)
function overlay.setOn(on)
	state.on = on and true or false
	state.key = nil
	if state.on then
		overlay.refresh()
	else
		state.edges = nil
	end
	state.version = state.version + 1
	shared.log("network overlay " .. (state.on and "on" or "off"))
end

-- Called while an action descriptor is being built, inside the action's own recipe: the
-- action is redrawn whenever the overlay's view changes. Only while the overlay is on:
-- off, the actions are as without the mod (2026-10-11: with it declared in every action
-- all the time, the builder's preview display stopped following the plans now and then).
-- An action subscribed while on is redrawn once more when it goes off. (Outside a recipe
-- the hooks are refused, which is ignored.)
function overlay.subscribe()
	if not overlay.isOn() then
		return
	end
	pcall(function()
		-- a build was applied (any tool): the network is read again
		react.onEvent("onProposalApply", function()
			overlay.networkChanged()
		end)
		local seen = react.useState(state.version)
		react.onStep(function()
			if seen:old() ~= state.version then
				seen:set(state.version)
			end
		end)
	end)
end

-- The network around the camera, read again when the camera has moved or zoomed by a
-- twentieth of the view. Returns true if it was.
function overlay.refresh()
	if not wanted() then
		state.edges, state.key, state.lines, state.linesVersion = nil, nil, nil, nil
		state.entries, state.squares = {}, {}
		return false
	end
	local changed = false
	local ok, err = pcall(function()
		local c = clock()
		if c and (not state.readAt or c - state.readAt > REREAD_AFTER) then
			state.readAt = c
			state.entries, state.squares, state.key = {}, {}, nil
		elseif c and state.dirtyUntil and c < state.dirtyUntil then
			state.entries, state.squares, state.key = {}, {}, nil
		end
		local camera = api.gui.camera.getCameraData()
		local radius = math.max(50, camera.z)
		local step = radius / 20
		local key = string.format("%d,%d,%d", math.floor(camera.x / step), math.floor(camera.y / step), math.floor(math.log(radius) * 20))
		if key == state.key and state.edges then
			return
		end
		state.key = key
		local started = shared.LOG_PLANS and clock()
		local list, entries, old, reads = {}, {}, state.entries, 0
		local tracks = api.type["enum"].RoadType.TRACK
		for __, entity in ipairs(api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(camera.x, camera.y), radius,
			api.type.ComponentType.BASE_EDGE)) do
			if #list >= EDGES_MAX then
				break
			end
			local entry = old[entity]
			if entry == nil then
				reads = reads + 1
				local comp = planner.getEdgeComp(entity)
				entry = comp and { edge = planner.toEdge(comp), track = comp.roadType == tracks, node0 = comp.node0, node1 = comp.node1 } or false
			end
			entries[entity] = entry
			if entry then
				list[#list + 1] = entry
			end
		end
		-- (only what's in view is kept)
		state.entries = entries
		state.edges = list
		state.version = state.version + 1
		changed = true
		noteTiming("refresh", started, reads)
	end)
	if not ok then
		state.failed = true
		shared.log("network overlay failed, off until the game restarts: " .. tostring(err))
	end
	return changed
end

function overlay.version()
	return state.version
end

-- The overlay's lines (edges of an edge renderable), or nil. An action descriptor takes
-- one edge renderable at most (2026-10-10, a crash: "Must not specify more than 1
-- EdgeRenderable"), so whoever adds it puts all lines into one (menu patch).
function overlay.lines()
	if not wanted() or not state.edges or #state.edges == 0 then
		return nil
	end
	if state.linesVersion == state.version then
		return state.lines
	end
	local started = shared.LOG_PLANS and clock()
	local ok, result = pcall(function()
		local edges, ends = {}, {}
		for __, w in ipairs(state.edges) do
			if w.line == nil then
				-- (in 2 m pieces: an overview, it doesn't need the builder's detail)
				w.line = overlay.drawable(w.edge) and overlay.makeEdge(w.edge, w.track and TRACK_COLOR or ROAD_COLOR, 0.4, 2.0) or false
			end
			if w.line then
				edges[#edges + 1] = w.line
				local e = w.edge
				for __, n in ipairs({ { w.node0, e.p0 }, { w.node1, e.p1 } }) do
					local entry = ends[n[1]]
					if entry == nil then
						entry = { node = n[1], position = n[2], count = 0, track = w.track }
						ends[n[1]] = entry
						ends[#ends + 1] = entry
					end
					entry.count = entry.count + 1
				end
			end
		end
		local squares = {}
		for i, n in ipairs(ends) do
			if i > overlay.MAX_NODE_MARKERS then
				break
			end
			local junction = n.count >= 3
			local key = n.node .. (junction and "j" or "n") .. (n.track and "t" or "r")
			local lines = state.squares[key]
			if lines == nil then
				local c = n.track and TRACK_COLOR or ROAD_COLOR
				lines = {}
				overlay.addNodeMarker(lines, n.position, junction and overlay.JUNCTION_MARKER or overlay.NODE_MARKER, { c[1], c[2], c[3], 1 }, 0.3)
			end
			squares[key] = lines
			for __, l in ipairs(lines) do
				edges[#edges + 1] = l
			end
		end
		-- (only the markers in view are kept)
		state.squares = squares
		return edges
	end)
	if not ok then
		state.failed = true
		shared.log("network overlay failed, off until the game restarts: " .. tostring(result))
		return nil
	end
	state.lines, state.linesVersion = result, state.version
	noteTiming("build", started)
	return result
end

-- Called after each change of the view, besides the subscriptions: the menu patch
-- redraws an open builder this way (a subscription declared from a builder's action can
-- miss the first time a builder opens, the action having drawn the selector before:
-- 2026-10-11, the overlay stood still until the builder was opened again).
overlay.onChange = nil

-- Called on every step (from the entry plugin): reads the network again when the camera
-- has moved; the subscribed actions see the new version and redraw.
function overlay.step()
	if overlay.refresh() and overlay.onChange then
		pcall(overlay.onChange, state.version)
	end
end

return overlay
