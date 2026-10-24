-- Constants and helpers used on all lua states of the mod (menu, game script gui, engine).
-- Each state loads its own copy, so this must not hold state that another one reads,
-- and it must stay free of gui requires.

-- the tweakables (counts, spacing range): see parallelism_config.lua
local config = require "parallelism_config.lua"

-- Dev switches from parallelism_dev.lua: committed with all off (a release), filled in by
-- dev mode on the dev branch (../tools/devmode.sh, devmode/). See mods\RELEASING.md.
local okDev, dev = pcall(require, "parallelism_dev.lua")
if not okDev or type(dev) ~= "table" then
	dev = {}
end

local shared = {
	KEY_COUNT = "parallelismCount",
	KEY_SIDE = "parallelismSide",
	-- the gap between neighboring tracks or roads, edge to edge, in meters
	KEY_SPACING = "parallelismSpacing",
	-- whether the Spacing slider shows that gap (edge to edge) or the distance between
	-- centers; only the display changes, the value stays the gap
	KEY_SPACING_FROM = "parallelismSpacingFrom",
	SPACING_FROM_EDGE = 1,
	SPACING_FROM_CENTER = 2,
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

	-- the drawn track at the edge, or in the middle with the odd one out of an uneven
	-- split on the left / right
	SIDE_LEFT = 1,
	SIDE_CENTER_LEFT = 2,
	SIDE_CENTER_RIGHT = 3,
	SIDE_RIGHT = 4,

	-- the first of the values of the mod settings maxTracks / maxRoads (mod.json)
	COUNT_SETTING_FIRST = 2,

	SPACING_STEP = config.SPACING_STEP,
	MAX_SPACING = config.MAX_SPACING,
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

	-- a "Wireframe" button in the track and road toolbars that draws the whole plan of the
	-- preview as lines (drawn track, new pieces, existing pieces cut and added again,
	-- removed edges), also for plans that are refused (public: players like it, 2026-10-20)
	DEBUG_WIREFRAME = true,

	-- dev switch: the network overlay's button in the HUD (parallelism_overlay.lua), in
	-- progress
	NETWORK_OVERLAY = dev.networkOverlay == true,

	-- dev switches of the game script (parallelism.script.lua): the full proposal of every
	-- build in the log, the network around a drag's start node, the crossings measured
	DUMP_BUILDS = dev.dumpBuilds == true,
	DUMP_AT_DRAG_START = dev.dumpAtDragStart == true,
	MEASURE_CROSSINGS = dev.measureCrossings == true,

	-- dev switch: the menu's log lines per plan and per draw (each plan, perf every 100
	-- tooltip calls, slow plans, refused plans held still, the game's verdicts); a release
	-- logs only failures
	LOG_PLANS = dev.logPlans == true,
	-- dev switch: the node markers' two shapes take turns, to compare their cost in frame
	-- time (parallelism_overlay.lua, noteFrame)
	MARKER_AB = dev.markerAB == true,
	-- dev switches for finding what makes the game slow with a big track build (50 tracks:
	-- 12 s, 50 roads: under 1 s, 2026-10-24): the build without the tracks' shared-strip
	-- distance, without redoing pillars, or in chunks of this many parallels (0: all at once)
	BUILD_NO_DISTANCE = dev.buildNoDistance == true,
	BUILD_NO_REDO_PILLARS = dev.buildNoRedoPillars == true,
	BUILD_CHUNK = tonumber(dev.buildChunk) or 0,
	-- dev experiment: neighboring straight pieces of a parallel merged into one edge where
	-- that changes nothing about its shape (one line, heights on it, same type), to see
	-- whether the game's time for a big build follows the number of edges
	BUILD_MERGE_STRAIGHTS = dev.buildMergeStraights == true,

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

-- the most tracks or roads (the drawn one included) a builder offers: the mod settings
-- maxTracks / maxRoads, else the config's
-- Whether to draw the preview: the mod setting "Hide Parallelism's build preview" (a
-- checkbox: index 1 unchecked, 2 checked; unchecked when it cannot be read). Hidden, the
-- extra roads are planned and checked as always but not drawn while dragging (another
-- mod's preview, e.g. Auto Bridges', then gets the builder's one preview slot); Wireframe
-- still draws.
-- (Asked on every draw: mod settings can't change during a game, so read once.)
function shared.showPreview()
	if not shared.SHOW_PREVIEW then
		return false
	end
	if shared.hidePreviewIndex == nil then
		local index = tonumber(shared.modParam("hidePreview"))
		shared.hidePreviewIndex = index or false
		shared.log("mod option hidePreview: index " .. tostring(index))
	end
	return shared.hidePreviewIndex ~= 2
end

function shared.maxCount(builder)
	local streets = builder == shared.STREET_BUILDER
	local key = streets and "maxRoads" or "maxTracks"
	-- the game gives the 1-based index of the chosen value, not its number (seen with an
	-- earlier option: "No" of numbers 0 / 1 read as 1); the values run 2, 3, 4, ...
	local index = tonumber(shared.modParam(key))
	if not shared.loggedModParams then
		shared.loggedModParams = {}
	end
	local count = (index and index >= 1) and math.floor(index) + shared.COUNT_SETTING_FIRST - 1
		or (streets and config.MAX_ROADS or config.MAX_TRACKS)
	if not shared.loggedModParams[key] then
		shared.loggedModParams[key] = true
		shared.log(string.format("mod option %s: index %s, up to %d", key, tostring(index), count))
	end
	return count
end

-- a short fingerprint of a (long) string, to compare drag signatures in the log
function shared.fingerprint(s)
	if s == nil then
		return "nil"
	end
	local h = 0
	for i = 1, #s do
		h = (h * 31 + s:byte(i)) % 1000003
	end
	return string.format("%06d/%d", h, #s)
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

-- true when the game already refuses the builder's own proposal (the drawn road): the
-- drag cannot be built, so the mod neither plans nor judges nor shows its part. Those are
-- the fragile cases: at 14.4 degrees, with the drawn road colliding, the game crashed in
-- StreetShapeFactory (2026-10-03).
function shared.builderRefuses(proposalData)
	local refuses = false
	pcall(function()
		-- the game's own messages only: ours (the drag check's refusals, "Parallel ...")
		-- reach the builder's data too, and the preview must stay up for those
		for __, m in ipairs(proposalData.errorState.messages) do
			if tostring(m):sub(1, 9) ~= "Parallel " then
				refuses = true
			end
		end
	end)
	return refuses
end

return shared
