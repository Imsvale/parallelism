-- Adds the mod's params to the toolbar of every track type, and shows the extra tracks
-- as a preview while dragging. The base game builds the params in a file-local function
-- without an extension point, so the module functions that the construction menu calls
-- are wrapped instead.

local construction_react_util = require "::/gui/construction/construction_react_util.tl"
local builtin = require "::/gui/main/builtin.lua"
local shared = require "ptracks_shared.lua"
local geometry = require "ptracks_geometry.lua"
local planner = require "ptracks_planner.lua"

local patch = {}

--------------------------------------------------------------------------------
-- preview

-- Planned proposals for the extra tracks of the drag in progress. Written when the
-- builder reports a new live proposal, read by the preview components.
local preview = {
	version = 0,
	count = 1,
	side = shared.SIDE_RIGHT,
	signature = nil,
	proposals = {},
	-- per track, filled in by the preview components once the game has evaluated them
	costs = {},
	failed = {},
}

local function clearPreview()
	if #preview.proposals > 0 then
		preview.proposals = {}
		preview.costs = {}
		preview.failed = {}
		preview.signature = nil
		preview.version = preview.version + 1
	end
end

-- identifies a drawn proposal, to plan again only when the drag changed
local function signatureOf(drawn)
	local parts = { preview.count, preview.side }
	for __, d in ipairs(drawn) do
		parts[#parts + 1] = string.format("%.2f,%.2f,%.2f,%.2f", d.edge.p0.x, d.edge.p0.y, d.edge.p1.x, d.edge.p1.y)
	end
	return table.concat(parts, ";")
end

local function updatePreview(proposal)
	local drawn = planner.collectDrawnSegments(proposal.proposal)
	if #drawn == 0 then
		clearPreview()
		return
	end
	local signature = signatureOf(drawn)
	if signature == preview.signature then
		return
	end
	-- segments of the live proposal can come without a track type, the one selected in
	-- the menu is what is being built
	for __, d in ipairs(drawn) do
		d.template = preview.resName
	end
	-- all extra tracks in one proposal: an action takes only one proposal viewer
	local proposals = {}
	local distance = planner.getTrackDistance(preview.resName)
	local planned, stats = planner.makeProposal(drawn, geometry.offsets(preview.count, preview.side, distance))
	if stats.edges > 0 then
		proposals[1] = planned
	end
	-- dev aid: what the preview planned, next to what the game says about it
	local planned = string.format("%d drawn, %d edges, %d anchored, %d crossings, %d too shallow, %d moved, %d dropped",
		#drawn, stats.edges, stats.anchored, stats.crossings, stats.shallow, stats.moved, stats.dropped)
	if planned ~= preview.loggedPlan then
		preview.loggedPlan = planned
		shared.log("preview planned: " .. planned)
	end
	preview.shallow = stats.shallow
	preview.signature = signature
	preview.proposals = proposals
	preview.costs = {}
	preview.failed = {}
	preview.version = preview.version + 1
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
	local text = "Parallel tracks: " .. (preview.count - 1) .. " more"
	if known == #preview.proposals and known > 0 then
		text = text .. ", " .. api.util.formatMoney(total)
	end
	if (preview.shallow or 0) > 0 then
		-- the game script refuses the drag for this, see checkPlayerProposal
		text = text .. string.format(" (would cross a track at less than %.0f degrees)", planner.MIN_CROSSING_ANGLE)
	elseif failed > 0 then
		text = text .. " (cannot be built)"
	end
	return text
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
				preview.failed[index] = errorState.critical or #errorState.messages > 0
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
				end
			end
		end,
		entityForRefundableContext = api.engine.util.getPlayer(),
		proposalId = "imsvale_parallel_tracks_preview," .. index .. "," .. version,
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

local function makeParams()
	local countValues = {}
	for i = 1, shared.MAX_COUNT do
		countValues[i] = tostring(i)
	end

	return {
		{
			group = "parallelTracks",
			key = shared.KEY_COUNT,
			name = _("Tracks"),
			tooltip = _("Number of parallel tracks to build."),
			values = countValues,
			defaultIndex = 1,
			resetOnCategoryChange = false,
			resetOnMenuClose = false,
			uiType = api.type["enum"].ScriptParamType.Button,
			yearFrom = 0,
			yearTo = 0,
			location = api.type["enum"].ScriptParamLocation.Toolbar,
			checkEnabledFn = function(params)
				return params["mode"] == 1 and "Enabled" or "Disabled"
			end,
		},
		{
			group = "parallelTracks",
			key = shared.KEY_SIDE,
			name = _("Side"),
			tooltip = _("Where to put the additional tracks, seen in build direction."),
			values = { _("Left"), _("Center"), _("Right") },
			defaultIndex = shared.SIDE_RIGHT,
			resetOnCategoryChange = false,
			resetOnMenuClose = false,
			uiType = api.type["enum"].ScriptParamType.Button,
			yearFrom = 0,
			yearTo = 0,
			location = api.type["enum"].ScriptParamLocation.Toolbar,
			checkEnabledFn = function(params)
				if params["mode"] ~= 1 then
					return "Disabled"
				end
				return (params[shared.KEY_COUNT] or 1) > 1 and "Enabled" or "Disabled"
			end,
		},
		{
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
		},
	}
end

local function hasParam(params, key)
	for __, p in ipairs(params) do
		if p.key == key then
			return true
		end
	end
	return false
end

function patch.install()
	if construction_react_util.ptracksPatched then
		shared.log("menu patch already installed")
		return
	end
	construction_react_util.ptracksPatched = true

	local getTrackDefinitions = construction_react_util.getTrackDefinitions
	construction_react_util.getTrackDefinitions = function(...)
		local definitions = getTrackDefinitions(...)
		for __, definition in ipairs(definitions) do
			definition.params = definition.params or {}
			if not hasParam(definition.params, shared.KEY_COUNT) then
				for __, p in ipairs(makeParams()) do
					definition.params[#definition.params + 1] = p
				end
			end
		end
		return definitions
	end

	local getActionParams = construction_react_util.getActionParams
	construction_react_util.getActionParams = function(definition, params, ...)
		local isTrackBuilder = definition and definition.action == "ACTION_TRACK_BUILDER_UPGRADER" and params
		local count = 1
		if isTrackBuilder then
			-- the replace mode keeps the count value but must not build anything extra
			count = params["mode"] == 1 and params[shared.KEY_COUNT] or 1
			local side = params[shared.KEY_SIDE] or shared.SIDE_RIGHT
			-- the game script runs on another lua state, this event is the way across
			api.gui.fireGuiScriptEvent(shared.EVENT_ID, shared.EVENT_SET_PARAMS, { count = count, side = side, resName = definition.resName })
		end

		local result = getActionParams(definition, params, ...)

		-- the builder calls this with its live proposal on every change of the drag, the
		-- returned strings go into its tooltip
		local actionParams = result and result.constructionActionParams
		if isTrackBuilder and count > 1 and actionParams and actionParams.getProposalStringsFn then
			-- (repository, isGamepadMode, refParams, entity, notifications, refSublistParams)
			paramRefs = { select(6, ...), select(3, ...) }
			local side = params[shared.KEY_SIDE] or shared.SIDE_RIGHT
			if preview.count ~= count or preview.side ~= side or preview.resName ~= definition.resName then
				preview.count = count
				preview.side = side
				preview.resName = definition.resName
				clearPreview()
			end
			-- dev aid: what the hidden redraw param holds, against the preview version
			local redrawValue = tostring(params[shared.KEY_REDRAW])
			if redrawValue ~= lastLoggedRedraw then
				lastLoggedRedraw = redrawValue
				shared.log("redraw param = " .. redrawValue .. ", preview version = " .. preview.version)
			end
			-- the builder clears when the drag is cancelled (and after building)
			local trackEdgeBuilder = actionParams.trackEdgeBuilder
			if trackEdgeBuilder and trackEdgeBuilder.onClearFn then
				local onClear = trackEdgeBuilder.onClearFn
				trackEdgeBuilder.onClearFn = function(...)
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
					updatePreview(proposal)
					if preview.version ~= version then
						requestRedraw()
					end
					if #preview.proposals > 0 then
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
		end
		return result
	end

	-- The construction menu renders the builder as an action descriptor whose children
	-- are the builder action and its helpers. The preview components go in there too,
	-- as the base game does with its proposal viewer for swapping bridge types.
	local ActionDescriptor = builtin.ActionDescriptor
	builtin.ActionDescriptor = function(params, ...)
		if injectPreview then
			injectPreview = false
			if params and params.children and type(params.tool) == "string" and params.tool:find("construction-menu-", 1, true) == 1 then
				-- one at most: a second proposal viewer in an action crashes the game
				if preview.proposals[1] then
					params.children[#params.children + 1] = makeViewer(1)
				end
			end
		end
		return ActionDescriptor(params, ...)
	end

	shared.log("menu patch installed")
end

return patch
