-- Tweakables: values a player or modder may want to change. Each lua state of the mod
-- loads its own copy (through parallelism_shared.lua), so this holds values only.

return {
	-- The most tracks or roads the Tracks / Roads sliders offer, the drawn one included.
	-- These are the fallbacks: the mod settings (maxTracks and maxRoads in mod.json, whose
	-- defaultIndex is the default there) decide when the game can tell them.
	MAX_TRACKS = 9,
	MAX_ROADS = 9,

	-- The Spacing slider: up to this many meters between neighboring tracks or roads
	-- (edge to edge), in steps of this many meters (the slider's fine steps).
	MAX_SPACING = 20,

	-- Track bundles with more track than this (meters, all parallels together) are built
	-- in chunks of whole parallels: the game's time for one track build grows steeply with
	-- the amount of track in it (2026-10-24: chunks of about 8 km took 0.3-0.4 s each, a
	-- whole 50-track bundle of about 25 km 3-12 s).
	BUILD_CHUNK_LENGTH = 8000,
	SPACING_STEP = 0.5,
}
