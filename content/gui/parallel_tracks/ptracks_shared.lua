-- Constants and helpers used on all lua states of the mod (menu, game script gui, engine).
-- Each state loads its own copy, so this must not hold state that another one reads,
-- and it must stay free of gui requires.

local shared = {
	KEY_COUNT = "ptracksCount",
	KEY_SIDE = "ptracksSide",
	-- hidden, only changed to make the menu redraw the preview
	KEY_REDRAW = "ptracksRedraw",

	SIDE_LEFT = 1,
	SIDE_CENTER = 2,
	SIDE_RIGHT = 3,

	MAX_COUNT = 6,

	-- gui script event the menu uses to hand the toolbar values to the game script
	EVENT_ID = "ptracks",
	EVENT_SET_PARAMS = "ptracks.setParams",
}

function shared.log(msg)
	log.message("[ptracks] " .. tostring(msg))
end

function shared.vecToString(v)
	if v == nil then
		return "nil"
	end
	return string.format("(%.2f, %.2f, %.2f)", v.x, v.y, v.z)
end

return shared
