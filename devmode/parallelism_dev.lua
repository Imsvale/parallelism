-- Dev switches for the dev build: ../tools/devmode.sh copies this over
-- mod/content/gui/parallelism/parallelism_dev.lua when dev is checked out.
return {
	networkOverlay = true,
	dumpBuilds = true,
	dumpAtDragStart = true,
	measureCrossings = true,
	logPlans = true,
	-- builds in chunks of this many parallels (0: as the build decides)
	buildChunk = 0,
}
