local react = require "::/gui/main/react.lua"
local builtin = require "::/gui/main/builtin.lua"
local main_mod_button_area = require "::/gui/main/main_mod_button_area.tl"
local overlay = require "parallelism_overlay.lua"
local shared = require "parallelism_shared.lua"

-- The network overlay's switch: a toggle button in the HUD's mod button area. (Not a
-- tool: tools are exclusive, any other tool ended it, 2026-10-10.)
local Button = react.RegisterPluginRecipe(main_mod_button_area.MainModButtonAreaExtension, "ImsvaleParallelismOverlayButton", function()
	local on = react.useState(overlay.isOn() and 1 or 0)
	-- (in progress: a dev build only)
	if not shared.NETWORK_OVERLAY then
		return builtin.BoxLayout{ children = {} }
	end
	return builtin.BoxLayout{
		children = {
			builtin.ToggleButton{
				meta = {
					id = "imsvale_parallelism.overlayButton",
					tooltip = _("Network overlay: every road and track edge with its nodes"),
				},
				value = on:old(),
				onValueChange = function(value)
					on:set(value)
					overlay.setOn(value == 1)
				end,
				content = builtin.ImageView{
					path = "::/gui/game_bar/icons/symbol_eye.tga",
					scaling = builtin.type.ImageViewScaling.AutoFit,
				},
			},
		},
	}
end)

function data()
return {
	Button = Button,
}
end
