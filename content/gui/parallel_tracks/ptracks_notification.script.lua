-- Notification type for the mod's messages to the player. The game script adds one with
-- params = { title = ..., description = ... }, both ready to show.

local data = {}

data.useDataState = function(params)
	return {
		title = params.title or _("Parallel Tracks"),
		description = params.description or "",
		icon = "::game_mechanics/notifications/gui/icons/relation_track_plus.tga",
	}
end

return data
