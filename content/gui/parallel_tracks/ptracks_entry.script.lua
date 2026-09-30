local react = require "::/gui/main/react.lua"
local mod_entry_point = require "::/gui/main/mod_entry_point.tl"
local shared = require "ptracks_shared.lua"
local menu_patch = require "ptracks_menu_patch.lua"

-- The plugin itself shows nothing. Loading this file for the mod entry point is what
-- installs the menu patch, early enough to be in place when the construction menu
-- collects its definitions.
local ok, err = pcall(menu_patch.install)
if not ok then
	shared.log("menu patch failed: " .. tostring(err))
end

local Entry = react.RegisterPluginRecipe(mod_entry_point.ModEntryPointExtension, "ImsvaleParallelTracksEntry", function()
	return nil
end)

function data()
return {
	Entry = Entry,
}
end
