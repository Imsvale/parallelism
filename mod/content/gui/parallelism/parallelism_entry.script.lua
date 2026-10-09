local react = require "::/gui/main/react.lua"
local mod_entry_point = require "::/gui/main/mod_entry_point.tl"
local shared = require "parallelism_shared.lua"
local menu_patch = require "parallelism_menu_patch.lua"

-- Loading this file for the mod entry point is what installs the menu patch, early
-- enough to be in place when the construction menu collects its definitions.
local ok, err = pcall(menu_patch.install)
if not ok then
	shared.log("menu patch failed: " .. tostring(err))
end

-- The plugin draws the Wireframe's world view (setting On), outside any builder: the
-- network around the camera, refreshed a few times a second. Nothing otherwise.
local REFRESH_SECONDS = 0.25

local Entry = react.RegisterPluginRecipe(mod_entry_point.ModEntryPointExtension, "ImsvaleParallelTracksEntry", function()
	local version = react.useState(0)
	react.onStepTimer(function()
		local v = menu_patch.refreshWorldWireframe()
		if v ~= version:old() then
			version:set(v)
		end
	end, REFRESH_SECONDS)
	return menu_patch.worldWireframe()
end)

function data()
return {
	Entry = Entry,
}
end
