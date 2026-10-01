-- Constants and helpers used on all lua states of the mod (menu, game script gui, engine).
-- Each state loads its own copy, so this must not hold state that another one reads,
-- and it must stay free of gui requires.

local shared = {
	KEY_COUNT = "parallelismCount",
	KEY_SIDE = "parallelismSide",
	-- extra meters between neighbouring tracks, on top of the track type's own distance
	KEY_SPACING = "parallelismSpacing",
	-- roads only: whether the extra roads run the same way as the drawn one or against
	-- it (the other carriageway of a split highway)
	KEY_DIRECTION = "parallelismDirection",
	DIRECTION_SAME = 1,
	DIRECTION_OPPOSITE = 2,

	-- the builders the mod works with, by their id in the builder events
	TRACK_BUILDER = "trackBuilder",
	STREET_BUILDER = "streetBuilder",
	-- hidden, only changed to make the menu redraw the preview
	KEY_REDRAW = "parallelismRedraw",

	SIDE_LEFT = 1,
	SIDE_CENTER = 2,
	SIDE_RIGHT = 3,

	MAX_COUNT = 6,
	-- roads: a split highway needs 2; more only with the mod option "moreRoads"
	MAX_ROADS = 2,

	SPACING_STEP = 0.5,
	MAX_SPACING = 20,
	-- Roads side by side: the road builder snaps a second road a road width plus this
	-- much away (measured 2026-10-01: 20 m between two 16 m one-way roads). The default
	-- of the Spacing slider for roads, which is the gap between them.
	ROAD_GAP = 4,

	-- dev switch: false keeps the preview's planning, tooltip line and the drag check, but
	-- does not draw the preview (no proposal viewer, no menu redraw), to measure what
	-- drawing it costs the game
	SHOW_PREVIEW = true,

	-- dev switch: false turns off the speed-ups (planning only some changes of a moving
	-- drag, the drag check without game objects, adaptive sampling in the crossing
	-- search, caches for templates, components and edge geometry), to compare with them
	PERF_MEASURES = true,

	-- dev switch: a "Wireframe" button in the track and road toolbars that draws the whole
	-- plan of the preview as lines (drawn track, new pieces, existing pieces cut and
	-- added again, removed edges), also for plans that are refused
	DEBUG_WIREFRAME = true,

	-- dev aid: a "Radius" line in the track and road builder tooltip (tightest curve of the
	-- drawn track), also for single tracks. Out of scope for this mod: the sibling mod
	-- Better Construction Tooltip (imsvale_better_construction_tooltip) has it now, so off
	-- here to not show it twice.
	SHOW_RADIUS = false,
	KEY_WIREFRAME = "parallelismWireframe",

	-- dev experiment, roads with 2+ only: can the mod take the drawn road over? The
	-- builder is told not to draw its own preview (skipRender), and an input catcher
	-- logs the build click (IA_SELECT / IA_APPLY). Normal building is unchanged otherwise.
	-- Result 2026-10-01: skipRender without an error changes nothing (the builder still
	-- draws and builds its road).
	SPIKE_TAKEOVER = false,

	-- gui script event the menu uses to hand the toolbar values to the game script
	EVENT_ID = "parallelism",
	EVENT_SET_PARAMS = "parallelism.setParams",
	-- the game's verdict on the preview, for the drag check: { signature, critical, message }
	EVENT_PREVIEW_VERDICT = "parallelism.previewVerdict",
}

function shared.log(msg)
	log.message("[parallelism] " .. tostring(msg))
end

-- what the builder draws, for collectDrawnSegments
function shared.roadTypeOf(builder)
	if builder == shared.STREET_BUILDER then
		return api.type["enum"].RoadType.STREET
	end
	return api.type["enum"].RoadType.TRACK
end

-- The mod's option from the game's mod settings, nil if it cannot be read.
function shared.modParam(key)
	local ok, value = pcall(function()
		return api.engine.config.getModParams()["imsvale_parallelism"][key]
	end)
	return ok and value or nil
end

-- the most tracks or roads (the drawn one included) a builder offers
function shared.maxCount(builder)
	if builder == shared.STREET_BUILDER then
		local moreRoads = shared.modParam("moreRoads")
		if not shared.loggedModParams then
			shared.loggedModParams = true
			shared.log("mod option moreRoads = " .. tostring(moreRoads))
		end
		return moreRoads == 1 and shared.MAX_COUNT or shared.MAX_ROADS
	end
	return shared.MAX_COUNT
end

-- "tracks" or "roads", for messages to the player
function shared.nounOf(builder)
	return builder == shared.STREET_BUILDER and "roads" or "tracks"
end

function shared.vecToString(v)
	if v == nil then
		return "nil"
	end
	return string.format("(%.2f, %.2f, %.2f)", v.x, v.y, v.z)
end

return shared
