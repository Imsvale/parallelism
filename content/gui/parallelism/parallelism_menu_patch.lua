-- Adds the mod's params to the toolbar of every track type, and shows the extra tracks
-- as a preview while dragging. The base game builds the params in a file-local function
-- without an extension point, so the module functions that the construction menu calls
-- are wrapped instead.

local construction_react_util = require "::/gui/construction/construction_react_util.tl"
local builtin = require "::/gui/main/builtin.lua"
local shared = require "parallelism_shared.lua"
local geometry = require "parallelism_geometry.lua"
local planner = require "parallelism_planner.lua"

local patch = {}

-- dev aid: tooltip calls about the same drag that count as holding it still (about a
-- second), see where the refused plan is logged
local HOLD_STILL_CALLS = 60

-- dev experiment: a Selector in the road builder, to see the build click (it disables
-- the builder, see where it is added)
local SPIKE_SELECTOR = false

--------------------------------------------------------------------------------
-- preview

-- Planned proposals for the extra tracks of the drag in progress. Written when the
-- builder reports a new live proposal, read by the preview components.
local preview = {
	version = 0,
	count = 1,
	side = shared.SIDE_RIGHT,
	spacing = nil,
	reverse = false,
	builder = shared.TRACK_BUILDER,
	signature = nil,
	proposals = {},
	-- per track, filled in by the preview components once the game has evaluated them
	costs = {},
	failed = {},
	-- town buildings the game reported in the way during this drag ({ construction,
	-- building }); the plan names those it still passes for removal, as the builder does
	-- for its own track. bulldozeVersion counts additions, to plan again after one.
	bulldoze = {},
	bulldozeKnown = {},
	bulldozeVersion = 0,
	plannedBulldozeVersion = 0,
	bulldozeList = {},
}

local function clearPreview()
	-- the drag is over: buildings it ran into are not in the way of the next one
	if #preview.bulldoze > 0 then
		preview.bulldoze = {}
		preview.bulldozeKnown = {}
		preview.bulldozeVersion = preview.bulldozeVersion + 1
		preview.bulldozeList = {}
	end
	if preview.wireframeEdges then
		preview.wireframeEdges = nil
		preview.version = preview.version + 1
	end
	if #preview.proposals > 0 then
		preview.proposals = {}
		preview.costs = {}
		preview.failed = {}
		preview.warning = nil
		preview.gameMessage = nil
		preview.signature = nil
		preview.version = preview.version + 1
	end
end

-- identifies a drawn proposal, to plan again only when the drag changed
local function signatureOf(drawn)
	return planner.signatureOf(drawn, preview.count, preview.side, preview.spacing, preview.reverse, preview.resName)
end

local previewDebounce = planner.newDebounce(planner.PLAN_EVERY, planner.CHEAP_PLAN_MS)

local function updatePreview(proposal)
	local drawn = planner.collectDrawnSegments(proposal.proposal, shared.roadTypeOf(preview.builder))
	if #drawn == 0 then
		clearPreview()
		return
	end
	local signature = signatureOf(drawn)
	if signature == preview.signature and preview.bulldozeVersion == preview.plannedBulldozeVersion then
		return
	end
	-- while the drag moves the preview follows every few changes, and settles where it
	-- stops; a building newly found in the way is planned again right away
	local planKey = signature .. "|" .. preview.bulldozeVersion
	if not previewDebounce.shouldPlan(planKey) then
		return
	end
	previewDebounce.planned(planKey)
	preview.plannedBulldozeVersion = preview.bulldozeVersion
	-- segments of the live proposal can come without a track type, the one selected in
	-- the menu is what is being built
	for __, d in ipairs(drawn) do
		d.template = preview.resName
	end
	-- all extra tracks in one proposal: an action takes only one proposal viewer
	local proposals = {}
	local distance = planner.parallelDistance(preview.resName, preview.spacing)
	local started = planner.clockMs()
	-- the node configs the builder made for the drawn nodes, which ours copy (while
	-- dragging the drawn nodes are not in the world yet)
	local nodeConfigs = {}
	pcall(function()
		for __, nc in ipairs(proposal.proposal.nodeConfigsToAdd) do
			nodeConfigs[nc.entity] = nc.comp
		end
	end)
	local planned, stats = planner.makeProposal(drawn, geometry.offsets(preview.count, preview.side, distance), nil, false,
		{ reverse = preview.reverse, nodeConfigs = nodeConfigs, wireframe = preview.wireframe })
	preview.wireframeEdges = preview.wireframe and stats.wireframe or nil
	-- the cost decides whether the next changes are all planned; slow ones are logged
	if started then
		local took = planner.clockMs() - started
		previewDebounce.planned(planKey, took)
		if took > 20 then
			shared.log(string.format("perf [tracks " .. preview.count .. (shared.SHOW_PREVIEW and "" or ", preview hidden") .. "]: preview plan took %.0f ms (%d drawn, %d edges, %d crossings; %s)", took, #drawn, stats.edges, stats.crossings,
				tostring(stats.timing)))
		end
	end
	-- a plan with problems is not shown: the game can crash drawing it
	if stats.edges > 0 and #stats.problems == 0 then
		proposals[1] = planned
		preview.bulldozeList = planner.buildingsInTheWay(planned, preview.bulldoze)
		if #preview.bulldozeList > 0 then
			planned.constructionsToRemove = preview.bulldozeList
		end
	else
		preview.bulldozeList = {}
	end
	preview.problems = #stats.problems
	preview.tooTight = stats.tooTight and stats.minAllowedRadius or nil
	-- dev aid: what the preview planned, next to what the game says about it
	local planned = string.format("%d drawn, %d edges, %d anchored, %d crossings, %d too shallow, %d moved, %d dropped, %d problems%s",
		#drawn, stats.edges, stats.anchored, stats.crossings, stats.shallow, stats.moved, stats.dropped, #stats.problems,
		#stats.problems > 0 and (" (" .. stats.problems[1] .. ")") or "")
	if planned ~= preview.loggedPlan then
		preview.loggedPlan = planned
		shared.log("preview planned: " .. planned)
		-- dev aid: a plan with crossings in full, the game's crashes so far came with those
		if (stats.crossings > 0 or stats.anchored > 0 or stats.moved > 0 or stats.reused > 0) and #stats.problems == 0 then
			shared.log("  preview plan: " .. planner.planToString(stats.plan))
			for __, e in ipairs(stats.removedEdges or {}) do
				shared.log("  preview removes edge " .. planner.describeEntity(e))
			end
			for __, n in ipairs(stats.removedNodes or {}) do
				shared.log("  preview removes node " .. planner.describeEntity(n))
			end
		end
	end
	preview.selfCrossing = stats.selfCrossing
	-- the plan the viewer shows, logged when the game objects to it
	preview.plan = stats.plan
	preview.firstProblem = stats.problems[1]
	preview.notes = stats.notes
	preview.problemAt = stats.problemAt
	preview.stillCalls = 0
	preview.stillLogged = false
	preview.shortPiece = stats.shortPiece ~= nil
	preview.existingBend = stats.existingBend ~= nil
	preview.junctions = stats.junctions > 0
	preview.sharpCorner = stats.sharpCorner ~= nil
	preview.shallow = stats.shallow
	preview.signature = signature
	preview.proposals = proposals
	preview.costs = {}
	preview.failed = {}
	preview.warning = nil
	preview.gameMessage = nil
	preview.version = preview.version + 1
end

-- Tooltip line with the tightest curve of the drawn track: by its ends (as an arc) and
-- at its tightest point (what the game checks against the type's minimum radius; the
-- builder's cubic edges bend about 0.8 % tighter mid-edge). nil for a straight drag.
local function radiusLine(proposal, builder)
	if not shared.SHOW_RADIUS then
		return nil
	end
	local drawn = planner.collectDrawnSegments(proposal.proposal, shared.roadTypeOf(builder))
	local byEnds, along = math.huge, math.huge
	for __, d in ipairs(drawn) do
		local e = d.edge
		byEnds = math.min(byEnds, geometry.radius(e.p0, e.p1, e.t0, e.t1))
		along = math.min(along, geometry.minRadiusAlong(e))
	end
	if #drawn == 0 then
		return nil
	end
	if byEnds == math.huge then
		return "Radius: straight"
	end
	return string.format("Radius: %.1f m (tightest %.1f m)", byEnds, along)
end

-- tooltip line for the extra tracks, with their costs once known
local function previewSummary()
	local total, known, failed = 0, 0, 0
	for i = 1, #preview.proposals do
		if preview.costs[i] then
			total = total + preview.costs[i]
			known = known + 1
		end
		if preview.failed[i] then
			failed = failed + 1
		end
	end
	local text = "Parallel " .. shared.nounOf(preview.builder) .. ": " .. (preview.count - 1) .. " more"
	if known == #preview.proposals and known > 0 then
		text = text .. ", " .. api.util.formatMoney(total)
	end
	if preview.sharpCorner then
		text = text .. " (would turn too sharply)"
	elseif preview.junctions then
		text = text .. " (would make a junction, not supported yet)"
	elseif preview.selfCrossing then
		text = text .. " (would cross each other)"
	elseif preview.existingBend then
		text = text .. " (would cross a track where it bends too tightly)"
	elseif preview.shortPiece then
		text = text .. " (would leave a piece too short to build)"
	elseif (preview.shallow or 0) > 0 then
		-- the game script refuses the drag for this, see checkPlayerProposal
		text = text .. string.format(" (would cross at less than %.0f degrees)", planner.MIN_CROSSING_ANGLE)
	elseif preview.tooTight then
		text = text .. string.format(" (would curve tighter than %.0f m)", preview.tooTight)
	elseif (preview.problems or 0) > 0 then
		text = text .. " (cannot be laid out here)"
	elseif failed > 0 then
		text = text .. " (cannot be built" .. (preview.gameMessage and (": " .. preview.gameMessage) or "") .. ")"
	elseif preview.warning then
		text = text .. " (game notes: " .. preview.warning .. ")"
	end
	return text
end

-- dev aid (shared.DEBUG_WIREFRAME): the whole plan as lines, drawn by the game without
-- judging it, so also for plans that are refused. Colors by kind of edge.
local WIREFRAME_COLORS = {
	drawn = { 1, 1, 1, 0.9 },        -- the drawn track, as the planner collected it
	ours = { 0, 0.9, 1, 0.9 },       -- new track of the mod
	existing = { 1, 0.85, 0, 0.9 },  -- existing track cut or reshaped, added again
	removed = { 1, 0.1, 0.1, 0.6 },  -- existing track the plan removes
}
local wireframeFailed = false

local function makeWireframeEdge(e, color, width)
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

local function makeWireframe()
	if wireframeFailed or not preview.wireframeEdges then
		return nil
	end
	local ok, result = pcall(function()
		local edges = {}
		-- the spot a refused plan names: a small magenta square, 3 m across
		if preview.problemAt then
			local p, h = preview.problemAt, 1.5
			local corners = { { -h, -h }, { h, -h }, { h, h }, { -h, h } }
			for i = 1, 4 do
				local a, b = corners[i], corners[i % 4 + 1]
				local p0 = { x = p.x + a[1], y = p.y + a[2], z = p.z }
				local p1 = { x = p.x + b[1], y = p.y + b[2], z = p.z }
				local t = { x = p1.x - p0.x, y = p1.y - p0.y, z = 0 }
				edges[#edges + 1] = makeWireframeEdge({ p0 = p0, p1 = p1, t0 = t, t1 = t }, { 1, 0, 1, 1 }, 0.4)
			end
		end
		for __, w in ipairs(preview.wireframeEdges) do
			-- a refused plan can hold degenerate edges (a drag just started, a track turned
			-- inside out); drawing one of zero length crashed the game
			-- (edge_geometry_util.h: transport::VisitEdge: len > 0)
			local e = w.edge
			local t0 = math.sqrt(e.t0.x * e.t0.x + e.t0.y * e.t0.y)
			local t1 = math.sqrt(e.t1.x * e.t1.x + e.t1.y * e.t1.y)
			if geometry.arcLength(e) >= 0.1 and t0 > 1e-3 and t1 > 1e-3 then
				-- removed edges a little wider, so the pieces drawn on top of them stay visible
				edges[#edges + 1] = makeWireframeEdge(e, WIREFRAME_COLORS[w.kind] or WIREFRAME_COLORS.ours, w.kind == "removed" and 0.8 or 0.4)
			end
		end
		return builtin.EdgeRenderable{ edges = edges, ignoreDepth = true }
	end)
	if not ok then
		-- once: a wrong guess at the API should not cost every frame
		wireframeFailed = true
		shared.log("wireframe failed, off until the game restarts: " .. tostring(result))
		return nil
	end
	return result
end

-- The preview of one extra track: the game's own proposal viewer, which draws the
-- proposal and evaluates its costs and errors. It must go into the action descriptor
-- as a builtin, a recipe of the mod's own there crashes the game.
local function makeViewer(index)
	local version = preview.version
	return builtin.ProposalViewer{
		simpleProposal = preview.proposals[index],
		onCreateProposalData = function(proposalData)
			if version == preview.version then
				local errorState = proposalData.errorState
				preview.costs[index] = proposalData.costs
				-- town buildings in the way: plan again with them bulldozed, as the builder
				-- does for its own track (it reports them for removal, ours come back as
				-- collisions); the verdict waits for that plan
				local foundBuildings = false
				pcall(function()
					for __, e in ipairs(proposalData.collisionInfo.collisionEntities) do
						local candidate = planner.townBuildingCandidate(e.entity)
						if candidate and not preview.bulldozeKnown[candidate.construction] then
							preview.bulldozeKnown[candidate.construction] = true
							preview.bulldoze[#preview.bulldoze + 1] = candidate
							foundBuildings = true
						end
					end
				end)
				if foundBuildings then
					preview.bulldozeVersion = preview.bulldozeVersion + 1
					return
				end
				-- Any message stops the build, critical or not (seen in game: a single track
				-- with "Too Much Curvature" did not build). The one exception: Collision for
				-- roads, which the preview reports next to a road end the drawn road is about to
				-- continue (judged before the drawn road exists) and which builds. Same rule as
				-- the drag check in the game script.
				local message = #errorState.messages > 0 and tostring(errorState.messages[1]) or nil
				local roadEndArtifact = message == "Collision" and preview.builder == shared.STREET_BUILDER
				preview.failed[index] = errorState.critical or (message ~= nil and not roadEndArtifact)
				-- the drag check (game script) refuses a drag the game would not build; the
				-- build bulldozes what the preview does (two lists: plain values cross over)
				local bulldozeConstructions, bulldozeBuildings = {}, {}
				local inList = {}
				for __, c in ipairs(preview.bulldozeList) do
					inList[c] = true
				end
				for __, c in ipairs(preview.bulldoze) do
					if inList[c.construction] then
						bulldozeConstructions[#bulldozeConstructions + 1] = c.construction
						bulldozeBuildings[#bulldozeBuildings + 1] = c.building
					end
				end
				pcall(function()
					api.gui.fireGuiScriptEvent(shared.EVENT_ID, shared.EVENT_PREVIEW_VERDICT, {
						signature = preview.signature,
						critical = errorState.critical and true or false,
						message = #errorState.messages > 0 and tostring(errorState.messages[1]) or nil,
						-- the buildings the preview bulldozes, for the build
						bulldozeConstructions = bulldozeConstructions,
						bulldozeBuildings = bulldozeBuildings,
					})
				end)
				preview.warning = (not preview.failed[index] and message) or nil
				preview.gameMessage = message
				-- dev aid: what the game says about the preview, when that changes
				local messages = {}
				for __, m in ipairs(errorState.messages) do
					messages[#messages + 1] = tostring(m)
				end
				for __, w in ipairs(errorState.warnings) do
					messages[#messages + 1] = "warning: " .. tostring(w)
				end
				local verdict = "critical " .. tostring(errorState.critical) .. (#messages > 0 and (", " .. table.concat(messages, "; ")) or "")
				if verdict ~= preview.loggedVerdict then
					preview.loggedVerdict = verdict
					shared.log("preview verdict: " .. verdict)
					-- dev aid: the plan the game objects to, for tests/analyze_plan.lua
					if #messages > 0 and preview.plan then
						shared.log("  judged plan: " .. planner.planToString(preview.plan))
					end
					-- dev aid: what the preview collides with
					pcall(function()
						local collision = proposalData.collisionInfo
						for __, e in ipairs(collision.collisionEntities) do
							shared.log("  preview collides with " .. planner.describeEntity(e.entity))
						end
						for entity in pairs(collision.autoRemovalEntity2models) do
							shared.log("  preview would auto-remove " .. planner.describeEntity(entity))
						end
						for __, entity in ipairs(collision.buildingEntities) do
							shared.log("  preview building entity " .. planner.describeEntity(entity))
						end
					end)
				end
			end
		end,
		entityForRefundableContext = api.engine.util.getPlayer(),
		-- the version must be in the id: with one id for the whole drag the viewer does
		-- not pick up a changed proposal (tried in game)
		proposalId = "imsvale_parallelism_preview," .. index .. "," .. version,
	}
end

-- The toolbar params of the builder being rendered. Changing a param redraws the
-- construction menu's action, which is how a new preview gets into it.
-- getActionParams gets two of them (main and sub list), the base game finds the
-- toolbar params in the second, so both are tried
local paramRefs = {}

local function paramsApi(ref)
	if ref == nil or ref:hasExpired() then
		return nil
	end
	local wrap = ref:get()
	if wrap == nil or wrap:getIdentity() == nil then
		return nil
	end
	return wrap:getApi()
end

local lastLoggedRedraw = nil

-- dev aid: how often the builder asks for its tooltip lines, how often that changes the
-- preview (each change redraws the menu and has the game evaluate the preview), and the
-- lua time spent, logged every 100 calls
local previewPerf = { calls = 0, changes = 0, ms = 0 }

local function countPreviewCall(changed, started)
	previewPerf.calls = previewPerf.calls + 1
	if changed then
		previewPerf.changes = previewPerf.changes + 1
	end
	local now = planner.clockMs()
	if started and now then
		previewPerf.ms = previewPerf.ms + (now - started)
	end
	if previewPerf.calls >= 100 then
		shared.log(string.format("perf [tracks " .. preview.count .. (shared.SHOW_PREVIEW and "" or ", preview hidden") .. "]: %d tooltip calls, %d preview changes (each a menu redraw), %.0f ms preview lua",
			previewPerf.calls, previewPerf.changes, previewPerf.ms))
		previewPerf = { calls = 0, changes = 0, ms = 0 }
	end
end

-- bumps the hidden redraw param to the preview version
local function requestRedraw()
	local ok, err = pcall(function()
		for __, ref in ipairs(paramRefs) do
			local api_ = paramsApi(ref)
			local info = api_ and api_.getParamByKey(shared.KEY_REDRAW)
			if info then
				if info.value ~= preview.version then
					api_.changeParam(info.index, preview.version)
				end
				return
			end
		end
		shared.log("preview redraw: redraw param not found")
	end)
	if not ok then
		shared.log("preview redraw failed: " .. tostring(err))
	end
end

-- set while the track builder with extra tracks is being rendered, so the action
-- descriptor rendered right after it gets the preview components
local injectPreview = false

-- Spacing, in meters: for roads the gap between neighbours (0 = edge to edge, default
-- the gap the road builder snaps to), for tracks the distance between their centres
-- (from the track type's own distance, which is the default, up). Returns the slider's
-- smallest, largest and default value.
local function spacingRange(builder, resName)
	if builder == shared.STREET_BUILDER then
		return 0, shared.MAX_SPACING, shared.ROAD_GAP
	end
	local native = planner.getTrackDistance(resName)
	return native, native + shared.MAX_SPACING, native
end

local function spacingNumbers(builder, resName)
	local low, high = spacingRange(builder, resName)
	local numbers = {}
	for i = 0, (high - low) / shared.SPACING_STEP do
		numbers[#numbers + 1] = low + i * shared.SPACING_STEP
	end
	return numbers
end

-- the slider's value is the number itself, as with the base game's height slider
local function spacingOf(params, builder, resName)
	local low, high, default = spacingRange(builder, resName)
	local value = tonumber(params[shared.KEY_SPACING]) or default
	return math.max(low, math.min(high, value))
end

local function hasParam(params, key)
	for __, p in ipairs(params) do
		if p.key == key then
			return true
		end
	end
	return false
end

-- The sides the Side buttons offer, in button order. With at most 2 in all there is no
-- middle, so only left and right.
local function sideChoices(builder)
	if shared.maxCount(builder) <= 2 then
		return { shared.SIDE_LEFT, shared.SIDE_RIGHT }
	end
	return { shared.SIDE_LEFT, shared.SIDE_CENTER_LEFT, shared.SIDE_CENTER_RIGHT, shared.SIDE_RIGHT }
end

local function sideIndex(builder, side)
	for i, s in ipairs(sideChoices(builder)) do
		if s == side then
			return i
		end
	end
	return 1
end

-- true if the builder's toolbar is set to drawing (not replacing or upgrading)
local function isDrawing(builder, params)
	if builder == shared.STREET_BUILDER then
		return params["mode_street"] ~= 3
	end
	return params["mode"] == 1
end

local function makeParams(builder, resName)
	local countValues = {}
	for i = 1, shared.maxCount(builder) do
		countValues[i] = tostring(i)
	end
	local streets = builder == shared.STREET_BUILDER
	-- short labels only to fit four buttons
	local choices = sideChoices(builder)
	local sideLabels = #choices > 2 and {
		[shared.SIDE_LEFT] = "L",
		[shared.SIDE_CENTER_LEFT] = "CL",
		[shared.SIDE_CENTER_RIGHT] = "CR",
		[shared.SIDE_RIGHT] = "R",
	} or {
		[shared.SIDE_LEFT] = _("Left"),
		[shared.SIDE_RIGHT] = _("Right"),
	}
	local sideTooltips = {
		[shared.SIDE_LEFT] = streets and _("Parallel roads on the left side") or _("Parallel tracks on the left side"),
		[shared.SIDE_CENTER_LEFT] = streets and _("Uneven split puts the extra road on the left")
			or _("Uneven split puts the extra track on the left"),
		[shared.SIDE_CENTER_RIGHT] = streets and _("Uneven split puts the extra road on the right")
			or _("Uneven split puts the extra track on the right"),
		[shared.SIDE_RIGHT] = streets and _("Parallel roads on the right side") or _("Parallel tracks on the right side"),
	}
	local sideValues, sideValueTooltips = {}, {}
	for i, side in ipairs(choices) do
		sideValues[i] = sideLabels[side]
		sideValueTooltips[i] = sideTooltips[side]
	end
	local spacing = spacingNumbers(builder, resName)
	local spacingLow, spacingHigh, spacingDefault = spacingRange(builder, resName)

	-- the options for the extra tracks only matter with some
	local function withExtras(params)
		if not isDrawing(builder, params) then
			return "Disabled"
		end
		return (params[shared.KEY_COUNT] or 1) > 1 and "Enabled" or "Disabled"
	end

	local result = {
		{
			group = "parallelTracks",
			key = shared.KEY_COUNT,
			name = streets and _("Roads") or _("Tracks"),
			tooltip = streets and _("Number of parallel roads to build.") or _("Number of parallel tracks to build."),
			values = countValues,
			defaultIndex = 1,
			resetOnCategoryChange = false,
			resetOnMenuClose = false,
			uiType = api.type["enum"].ScriptParamType.Button,
			yearFrom = 0,
			yearTo = 0,
			location = api.type["enum"].ScriptParamLocation.Toolbar,
			checkEnabledFn = function(params)
				return isDrawing(builder, params) and "Enabled" or "Disabled"
			end,
		},
		{
			group = "parallelTracks",
			key = shared.KEY_SIDE,
			name = _("Side"),
			tooltip = streets and _("Where to put the additional roads, seen in build direction.")
				or _("Where to put the additional tracks, seen in build direction."),
			values = sideValues,
			tooltips = sideValueTooltips,
			-- a split highway's other carriageway goes left where traffic keeps right
			defaultIndex = sideIndex(builder, streets and shared.SIDE_LEFT or shared.SIDE_RIGHT),
			resetOnCategoryChange = false,
			resetOnMenuClose = false,
			uiType = api.type["enum"].ScriptParamType.Button,
			yearFrom = 0,
			yearTo = 0,
			location = api.type["enum"].ScriptParamLocation.Toolbar,
			checkEnabledFn = withExtras,
		},
		{
			group = "parallelTracks",
			key = shared.KEY_SPACING,
			name = _("Spacing"),
			tooltip = streets
				and string.format(_("Gap between neighbouring roads, 0 m is edge to edge. The road builder leaves %g m."), spacingDefault)
				or string.format(_("Distance between the centres of neighbouring tracks. The standard for this track type is %g m."), spacingDefault),
			numbers = spacing,
			defaultIndex = math.floor((spacingDefault - spacingLow) / shared.SPACING_STEP + 0.5) + 1,
			resetOnCategoryChange = false,
			resetOnMenuClose = false,
			uiType = api.type["enum"].ScriptParamType.Slider,
			yearFrom = 0,
			yearTo = 0,
			location = api.type["enum"].ScriptParamLocation.Toolbar,
			-- in meters, as the base game's height slider steps (precise: half meters)
			stepValueFn = function(value, direction, precise)
				local step = precise and shared.SPACING_STEP or 1
				local newValue = math.floor((value + direction * step) / step + 0.5) * step
				return math.max(spacingLow, math.min(spacingHigh, newValue))
			end,
			formatValueFn = function(value)
				return string.format("%.1f m", value)
			end,
			checkEnabledFn = withExtras,
		},
	}
	if streets then
		result[#result + 1] = {
			group = "parallelTracks",
			key = shared.KEY_DIRECTION,
			name = _("Direction"),
			tooltip = _("Whether the additional roads run the same way as the drawn one, or against it (the other carriageway of a split highway)."),
			values = { _("Same"), _("Opposite") },
			defaultIndex = shared.DIRECTION_OPPOSITE,
			resetOnCategoryChange = false,
			resetOnMenuClose = false,
			uiType = api.type["enum"].ScriptParamType.Button,
			yearFrom = 0,
			yearTo = 0,
			location = api.type["enum"].ScriptParamLocation.Toolbar,
			checkEnabledFn = withExtras,
		}
	end
	if shared.DEBUG_WIREFRAME then
		result[#result + 1] = {
			group = "parallelTracks",
			key = shared.KEY_WIREFRAME,
			name = "Wireframe",
			tooltip = "Dev aid: draw the whole plan as lines. White: drawn track as the mod reads it. Cyan: new track. Yellow: existing track cut and added again. Red: existing track removed.",
			values = { "Off", "On" },
			defaultIndex = 1,
			resetOnCategoryChange = false,
			resetOnMenuClose = false,
			uiType = api.type["enum"].ScriptParamType.Button,
			yearFrom = 0,
			yearTo = 0,
			location = api.type["enum"].ScriptParamLocation.Toolbar,
			checkEnabledFn = withExtras,
		}
	end
	result[#result + 1] = {
		-- never shown: the preview changes its value to have the menu redraw the builder
		group = "parallelTracks",
		key = shared.KEY_REDRAW,
		name = "",
		values = { "" },
		numbers = { 0 },
		defaultIndex = 1,
		resetOnCategoryChange = true,
		resetOnMenuClose = true,
		uiType = api.type["enum"].ScriptParamType.Button,
		yearFrom = 0,
		yearTo = 0,
		location = api.type["enum"].ScriptParamLocation.Toolbar,
		checkEnabledFn = function(_params)
			return "Hidden"
		end,
	}
	return result
end

-- appends the mod's params to each definition of a builder's menu
local function addParams(definitions, builder)
	for __, definition in ipairs(definitions) do
		definition.params = definition.params or {}
		if not hasParam(definition.params, shared.KEY_COUNT) then
			for __, p in ipairs(makeParams(builder, definition.resName)) do
				definition.params[#definition.params + 1] = p
			end
		end
	end
	return definitions
end

function patch.install()
	if construction_react_util.parallelismPatched then
		shared.log("menu patch already installed")
		return
	end
	construction_react_util.parallelismPatched = true

	local getTrackDefinitions = construction_react_util.getTrackDefinitions
	construction_react_util.getTrackDefinitions = function(...)
		return addParams(getTrackDefinitions(...), shared.TRACK_BUILDER)
	end

	local getStreetDefinitions = construction_react_util.getStreetDefinitions
	construction_react_util.getStreetDefinitions = function(...)
		return addParams(getStreetDefinitions(...), shared.STREET_BUILDER)
	end

	local getActionParams = construction_react_util.getActionParams
	construction_react_util.getActionParams = function(definition, params, ...)
		local builder = nil
		if definition and params then
			if definition.action == "ACTION_TRACK_BUILDER_UPGRADER" then
				builder = shared.TRACK_BUILDER
			elseif definition.action == "ACTION_STREET_BUILDER_UPGRADER" then
				builder = shared.STREET_BUILDER
			end
		end
		local count = 1
		local side, spacing, reverse
		if builder then
			-- the replace / upgrade mode keeps the count value but must not build anything extra
			count = isDrawing(builder, params) and params[shared.KEY_COUNT] or 1
			side = sideChoices(builder)[params[shared.KEY_SIDE] or 0] or shared.SIDE_RIGHT
			spacing = spacingOf(params, builder, definition.resName)
			reverse = builder == shared.STREET_BUILDER and params[shared.KEY_DIRECTION] == shared.DIRECTION_OPPOSITE
			-- the game script runs on another lua state, this event is the way across
			api.gui.fireGuiScriptEvent(shared.EVENT_ID, shared.EVENT_SET_PARAMS, {
				builder = builder, count = count, side = side, spacing = spacing, reverse = reverse, resName = definition.resName,
			})
		end

		local result = getActionParams(definition, params, ...)

		-- the builder calls this with its live proposal on every change of the drag, the
		-- returned strings go into its tooltip
		local actionParams = result and result.constructionActionParams
		if builder and count > 1 and actionParams and actionParams.getProposalStringsFn then
			-- (repository, isGamepadMode, refParams, entity, notifications, refSublistParams)
			paramRefs = { select(6, ...), select(3, ...) }
			if preview.builder ~= builder or preview.count ~= count or preview.side ~= side or preview.spacing ~= spacing
				or preview.reverse ~= reverse or preview.resName ~= definition.resName then
				shared.log("menu spacing param = " .. tostring(params[shared.KEY_SPACING]))
				preview.builder = builder
				preview.count = count
				preview.side = side
				preview.spacing = spacing
				preview.reverse = reverse
				preview.resName = definition.resName
				clearPreview()
			end
			local wireframe = shared.DEBUG_WIREFRAME and params[shared.KEY_WIREFRAME] == 2 or false
			if wireframe ~= preview.wireframe then
				preview.wireframe = wireframe
				-- plan again, with or without the wireframe edges
				clearPreview()
				preview.signature = nil
			end
			-- dev aid: what the hidden redraw param holds, against the preview version
			local redrawValue = tostring(params[shared.KEY_REDRAW])
			if redrawValue ~= lastLoggedRedraw then
				lastLoggedRedraw = redrawValue
				shared.log("redraw param = " .. redrawValue .. ", preview version = " .. preview.version)
			end
			-- the builder clears when the drag is cancelled (and after building)
			local edgeBuilder = actionParams.trackEdgeBuilder or actionParams.streetEdgeBuilder
			if edgeBuilder and edgeBuilder.onClearFn then
				local onClear = edgeBuilder.onClearFn
				edgeBuilder.onClearFn = function(...)
					onClear(...)
					local ok, err = pcall(function()
						clearPreview()
						requestRedraw()
					end)
					if not ok then
						shared.log("clearing the preview failed: " .. tostring(err))
					end
				end
			end
			injectPreview = true
			local getProposalStrings = actionParams.getProposalStringsFn
			actionParams.getProposalStringsFn = function(proposal, proposalData)
				local strings = getProposalStrings(proposal, proposalData) or {}
				local ok, err = pcall(function()
					local version = preview.version
					local started = planner.clockMs()
					updatePreview(proposal)
					countPreviewCall(preview.version ~= version, started)
					-- dev aid: a refused drag held still is one the player means, log its plan
					-- once (a moving cursor passes many refused positions nobody wants built);
					-- the tooltip is asked many times a second, also while the drag holds still
					if preview.version == version then
						preview.stillCalls = (preview.stillCalls or 0) + 1
						if preview.firstProblem and not preview.stillLogged and preview.stillCalls >= HOLD_STILL_CALLS and preview.plan then
							preview.stillLogged = true
							shared.log("refused and held still: " .. tostring(preview.firstProblem))
							for __, note in ipairs(preview.notes or {}) do
								shared.log("  note:" .. note)
							end
							shared.log("  refused plan: " .. planner.planToString(preview.plan))
						end
					end
					if preview.version ~= version and shared.SHOW_PREVIEW then
						requestRedraw()
					end
					local radius = radiusLine(proposal, builder)
					if radius then
						strings[#strings + 1] = radius
					end
					if #preview.proposals > 0 or (preview.problems or 0) > 0 or (preview.shallow or 0) > 0 then
						strings[#strings + 1] = previewSummary()
					end
				end)
				if not ok then
					shared.log("preview failed: " .. tostring(err))
				end
				return strings
			end
		else
			clearPreview()
			if builder and actionParams and actionParams.getProposalStringsFn and shared.SHOW_RADIUS then
				local getProposalStrings = actionParams.getProposalStringsFn
				actionParams.getProposalStringsFn = function(proposal, proposalData)
					local strings = getProposalStrings(proposal, proposalData) or {}
					local ok, line = pcall(radiusLine, proposal, builder)
					if ok and line then
						strings[#strings + 1] = line
					end
					return strings
				end
			end
		end
		return result
	end

	-- The construction menu renders the builder as an action descriptor whose children
	-- are the builder action and its helpers. The preview components go in there too,
	-- as the base game does with its proposal viewer for swapping bridge types.
	local ActionDescriptor = builtin.ActionDescriptor
	builtin.ActionDescriptor = function(params, ...)
		if injectPreview and not shared.SHOW_PREVIEW then
			injectPreview = false
		end
		if injectPreview then
			injectPreview = false
			if params and params.children and type(params.tool) == "string" and params.tool:find("construction-menu-", 1, true) == 1 then
				-- one at most: a second proposal viewer in an action crashes the game
				if preview.proposals[1] then
					params.children[#params.children + 1] = makeViewer(1)
				end
				if preview.wireframe then
					local wireframe = makeWireframe()
					if wireframe then
						params.children[#params.children + 1] = wireframe
					end
				end
				if SPIKE_SELECTOR and preview.builder == shared.STREET_BUILDER then
					-- experiment: does a script see the build click? A Selector is how the base
					-- game's own custom tools take clicks (a builtin: recipes of the mod's own
					-- crash the game in here). Result 2026-10-01: it sees every click (onSelect,
					-- mouse event types 0/1/2/8), but takes the input over: the road builder no
					-- longer drags or previews. Kept for a custom road tool.
					params.children[#params.children + 1] = builtin.Selector{
						onSelect = function(entity)
							shared.log("spike: selector onSelect " .. tostring(entity))
							return false
						end,
						onProcessMouseEvent = function(evt)
							-- everything but plain mouse moves
							if evt.xrel == 0 and evt.yrel == 0 then
								shared.log("spike: mouse event type " .. tostring(evt.type) .. ", button " .. tostring(evt.button)
									.. ", handled " .. tostring(evt.handled))
							end
							return false
						end,
					}
				end
			end
		end
		return ActionDescriptor(params, ...)
	end

	-- dev aid: parallelismDump() in the console
	local ok, err = pcall(function()
		require("parallelism_dump.lua").install()
	end)
	if not ok then
		shared.log("dump tool not installed: " .. tostring(err))
	end

	shared.log("menu patch installed")
end

return patch
