-- Adds the mod's params to the toolbar of every track type.
-- The base game builds these params in a file-local function without an extension
-- point, so the module functions that the construction menu calls are wrapped instead.

local construction_react_util = require "::/gui/construction/construction_react_util.tl"
local shared = require "ptracks_shared.lua"

local patch = {}

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
		if definition and definition.action == "ACTION_TRACK_BUILDER_UPGRADER" and params then
			-- the replace mode keeps the count value but must not build anything extra
			local count = params["mode"] == 1 and params[shared.KEY_COUNT] or 1
			local side = params[shared.KEY_SIDE] or shared.SIDE_RIGHT
			-- the game script runs on another lua state, this event is the way across
			api.gui.fireGuiScriptEvent(shared.EVENT_ID, shared.EVENT_SET_PARAMS, { count = count, side = side })
		end
		return getActionParams(definition, params, ...)
	end

	shared.log("menu patch installed")
end

return patch
