local react = require "::/gui/main/react.lua"
local mod_entry_point = require "::/gui/main/mod_entry_point.tl"
local shared = require "parallelism_shared.lua"
local menu_patch = require "parallelism_menu_patch.lua"
local overlay = require "parallelism_overlay.lua"

-- Loading this file for the mod entry point is what installs the menu patch, early
-- enough to be in place when the construction menu collects its definitions.
local ok, err = pcall(menu_patch.install)
if not ok then
	shared.log("menu patch failed: " .. tostring(err))
end

-- The plugin keeps the network overlay up to date (parallelism_overlay.lua): checked a
-- few times a second, read again when the camera has moved. It draws nothing itself: an
-- edge renderable here, outside the renderer, crashed the game (2026-10-09: assertion
-- IsTransformWithContext).
-- (on every step, timed here: react.onStepTimer runs its function on a worker thread,
-- where the game API is restricted, 2026-10-09: "API is currently restricted")
local CHECK_SECONDS = 0.25
local lastCheck = nil

local Entry = react.RegisterPluginRecipe(mod_entry_point.ModEntryPointExtension, "ImsvaleParallelTracksEntry", function()
	react.onStep(function()
		overlay.noteFrame()
		local now = os.clock()
		if lastCheck and now - lastCheck < CHECK_SECONDS then
			return
		end
		lastCheck = now
		overlay.step()
	end)
	return nil
end)

function data()
return {
	Entry = Entry,
}
end
