-- The network overlay: every road and track edge around the camera as a line, with a
-- square at each node (larger where 3 or more edges meet), switched on and off with a
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

-- node markers: squares of this half size (meters), larger where 3 or more edges meet
overlay.NODE_MARKER = 0.75
overlay.JUNCTION_MARKER = 1.5
overlay.MAX_NODE_MARKERS = 400

-- Around the camera: the spot it looks at, as far as it is away from it, so the view
-- zoomed out covers more. (The cap only spares the game a view it could not read.)
local EDGES_MAX = 1500
local ROAD_COLOR = { 0.7, 0.75, 0.8, 0.8 }
local TRACK_COLOR = { 0.85, 0.7, 0.45, 0.8 }

-- the four sides of a square around p, as straight edges, into edges
function overlay.addSquare(edges, p, h, color)
	local corners = { { -h, -h }, { h, -h }, { h, h }, { -h, h } }
	for i = 1, 4 do
		local a, b = corners[i], corners[i % 4 + 1]
		local p0 = { x = p.x + a[1], y = p.y + a[2], z = p.z }
		local p1 = { x = p.x + b[1], y = p.y + b[2], z = p.z }
		local t = { x = p1.x - p0.x, y = p1.y - p0.y, z = 0 }
		edges[#edges + 1] = { p0 = p0, p1 = p1, t0 = t, t1 = t, color = color }
	end
end

-- one line of an edge renderable
function overlay.makeEdge(e, color, width)
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
	edge.stepSize = 1.0
	return edge
end

-- (a zero-length edge crashed the game drawing it)
function overlay.drawable(e)
	local t0 = math.sqrt(e.t0.x * e.t0.x + e.t0.y * e.t0.y)
	local t1 = math.sqrt(e.t1.x * e.t1.x + e.t1.y * e.t1.y)
	return geometry.arcLength(e) >= 0.1 and t0 > 1e-3 and t1 > 1e-3
end

local state = {
	on = false,
	edges = nil,
	key = nil,
	version = 0,
	failed = false,
}

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
		state.edges, state.key = nil, nil
		return false
	end
	local changed = false
	local ok, err = pcall(function()
		local camera = api.gui.camera.getCameraData()
		local radius = math.max(50, camera.z)
		local step = radius / 20
		local key = string.format("%d,%d,%d", math.floor(camera.x / step), math.floor(camera.y / step), math.floor(math.log(radius) * 20))
		if key == state.key and state.edges then
			return
		end
		state.key = key
		local list = {}
		local tracks = api.type["enum"].RoadType.TRACK
		for __, entity in ipairs(api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(camera.x, camera.y), radius,
			api.type.ComponentType.BASE_EDGE)) do
			if #list >= EDGES_MAX then
				break
			end
			local comp = planner.getEdgeComp(entity)
			if comp then
				list[#list + 1] = { edge = planner.toEdge(comp), track = comp.roadType == tracks, node0 = comp.node0, node1 = comp.node1 }
			end
		end
		state.edges = list
		state.version = state.version + 1
		changed = true
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
	local ok, result = pcall(function()
		local edges, ends = {}, {}
		for __, w in ipairs(state.edges) do
			local e = w.edge
			if overlay.drawable(e) then
				edges[#edges + 1] = overlay.makeEdge(e, w.track and TRACK_COLOR or ROAD_COLOR, 0.4)
				for __, n in ipairs({ { w.node0, e.p0 }, { w.node1, e.p1 } }) do
					local entry = ends[n[1]]
					if entry == nil then
						entry = { position = n[2], count = 0, track = w.track }
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
			local c = n.track and TRACK_COLOR or ROAD_COLOR
			overlay.addSquare(squares, n.position, n.count >= 3 and overlay.JUNCTION_MARKER or overlay.NODE_MARKER, { c[1], c[2], c[3], 1 })
		end
		for __, s in ipairs(squares) do
			edges[#edges + 1] = overlay.makeEdge(s, s.color, 0.3)
		end
		return edges
	end)
	if not ok then
		state.failed = true
		shared.log("network overlay failed, off until the game restarts: " .. tostring(result))
		return nil
	end
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
