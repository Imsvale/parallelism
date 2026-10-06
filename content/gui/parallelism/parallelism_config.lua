-- Tweakables: values a player or modder may want to change. Each lua state of the mod
-- loads its own copy (through parallelism_shared.lua), so this holds values only.

return {
	-- The most tracks or roads the Tracks / Roads buttons offer, the drawn one included.
	-- These are the fallbacks: the mod settings (maxTracks and maxRoads in mod.json, whose
	-- defaultIndex is the default there) decide when the game can tell them.
	MAX_TRACKS = 8,
	MAX_ROADS = 8,

	-- The Spacing slider: up to this many meters between neighboring tracks or roads
	-- (edge to edge), in steps of this many meters (the slider's fine steps).
	MAX_SPACING = 20,
	SPACING_STEP = 0.5,
}
