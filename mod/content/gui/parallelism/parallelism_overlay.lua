-- The network overlay: every road and track edge around the camera as a line, with a
-- square at each node (larger where 3 or more edges meet), switched on and off with a
-- button in the HUD's mod button area (parallelism_overlay_button.script.lua).
--
-- A 3D overlay only renders as part of the active tool's action (an action descriptor):
-- from a mod's entry plugin it crashed the game (2026-10-09, IsTransformWithContext), and
-- a descriptor only shows a new overlay when the tool sets its action again. So while it
-- is on:
--   - with no tool open, a tool of the mod's own is on the tool stack, its action the
--     normal selector plus the overlay, set again whenever the camera has moved;
--   - with the construction menu open, the menu patch adds the overlay to the builder's
--     action and redraws the menu when the camera has moved.
-- (The game's own tool windows work the same way, e.g. the mission window's arrows.)

local builtin = require "::/gui/main/builtin.lua"
local react = require "::/gui/main/react.lua"
local selector_react_util = require "::/gui/main/selector_react_util.tl"
local game_react_globals = require "::/gui/main/game_react_globals.tl"
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
	-- the overlay tool's context while it is on the stack (setActionFn)
	toolCtx = nil,
	edges = nil,
	key = nil,
	version = 0,
	failed = false,
}

function overlay.isOn()
	return state.on and not state.failed
end

-- The network around the camera, read again when the camera has moved or zoomed by a
-- twentieth of the view. Returns true if it was.
function overlay.refresh()
	if not overlay.isOn() then
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

-- the overlay to render (a builtin edge renderable), or nil
function overlay.view()
	if not overlay.isOn() or not state.edges or #state.edges == 0 then
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
		return builtin.EdgeRenderable{ edges = edges, ignoreDepth = true }
	end)
	if not ok then
		state.failed = true
		shared.log("network overlay failed, off until the game restarts: " .. tostring(result))
		return nil
	end
	return result
end

-- The overlay tool's action: the normal selector (clicking and selecting work as with
-- no tool open, as the data layers do it) plus the overlay. A new function each time, so
-- the tool stack takes it as a new action.
local function makeAction()
	return function()
		local children = {}
		local view = overlay.view()
		if view then
			children[#children + 1] = view
		end
		local ok, selector = pcall(function()
			local selected = react.useRef(-1)
			return selector_react_util.makeDefaultSelector(game_react_globals.getDefaultRendererComponent(), selected, true, nil, true)
		end)
		if ok and selector then
			children[#children + 1] = selector
		elseif not ok and not state.selectorLogged then
			state.selectorLogged = true
			shared.log("network overlay: no selector with it: " .. tostring(selector))
		end
		return builtin.ActionDescriptor{
			tool = "parallelism-network-overlay",
			children = children,
		}
	end
end

overlay.Tool = react.RegisterTool{
	name = "ImsvaleParallelismNetworkOverlay",
	push = function(ctx)
		state.on = true
		state.toolCtx = ctx
		state.key = nil
		overlay.refresh()
		ctx.setActionFn(makeAction())
		shared.log("network overlay on")
	end,
	pop = function()
		state.on = false
		state.toolCtx = nil
		state.edges, state.key = nil, nil
		shared.log("network overlay off")
	end,
	-- (another tool on top, e.g. the construction menu: the overlay stays on, drawn by the
	-- menu patch in the builders' actions)
	shelve = function(ctx, _param, shelve)
		state.toolCtx = not shelve and ctx or nil
		if not shelve then
			state.key = nil
			overlay.refresh()
			ctx.setActionFn(makeAction())
		end
	end,
}

-- Called on every step (from the entry plugin): refreshes the view when the camera has
-- moved and has whoever shows it redraw. redrawMenu: redraws the construction menu.
function overlay.step(redrawMenu)
	if not overlay.refresh() then
		return
	end
	if state.toolCtx then
		local ok, err = pcall(state.toolCtx.setActionFn, makeAction())
		if not ok then
			shared.log("network overlay: setting the action failed: " .. tostring(err))
		end
	elseif redrawMenu then
		redrawMenu(-state.version)
	end
end

return overlay
