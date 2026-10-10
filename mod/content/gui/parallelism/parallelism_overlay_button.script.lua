local react = require "::/gui/main/react.lua"
local builtin = require "::/gui/main/builtin.lua"
local main_mod_button_area = require "::/gui/main/main_mod_button_area.tl"
local game_react_globals = require "::/gui/main/game_react_globals.tl"
local overlay = require "parallelism_overlay.lua"

-- The network overlay's switch: a tool button in the HUD's mod button area. Pressed, it
-- puts the overlay's tool on the tool stack; pressed again, it takes it off (as the
-- game bar's music player button does with its tool).
local Button = react.RegisterPluginRecipe(main_mod_button_area.MainModButtonAreaExtension, "ImsvaleParallelismOverlayButton", function()
	local toolStack = game_react_globals.getDefaultToolStack()
	return builtin.BoxLayout{
		children = {
			builtin.ToolButton{
				meta = {
					id = "imsvale_parallelism.overlayButton",
					tooltip = _("Network overlay: every road and track edge with its nodes"),
				},
				toolDefinition = overlay.Tool,
				toolStack = toolStack,
				content = builtin.ImageView{
					path = "::/gui/game_bar/icons/symbol_eye.tga",
					scaling = builtin.type.ImageViewScaling.AutoFit,
				},
				showFn = function()
					toolStack:get():getApi().push(overlay.Tool, nil, {}, true)
				end,
				hideFn = function()
					toolStack:get():getApi().pop(overlay.Tool, nil)
				end,
			},
		},
	}
end)

function data()
return {
	Button = Button,
}
end
