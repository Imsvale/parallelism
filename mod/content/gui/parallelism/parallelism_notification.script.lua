-- Notification type for the mod's messages to the player. The game script adds one with
-- params = { title = ..., description = ... }, both ready to show.

local function useDataState(params)
	return {
		title = params.title or _("Parallelism"),
		description = params.description or "",
		icon = "::game_mechanics/notifications/gui/icons/relation_track_plus.tga",
	}
end

-- a .script.lua hands its functions over through data() (the game asked for it:
-- "function data() not defined")
function data()
	return {
		useDataState = useDataState,
	}
end
