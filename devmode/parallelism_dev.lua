-- Dev switches for the dev build: ../tools/devmode.sh copies this over
-- mod/content/gui/parallelism/parallelism_dev.lua when dev is checked out.
return {
	networkOverlay = true,
	dumpBuilds = true,
	dumpAtDragStart = true,
	measureCrossings = true,
	logPlans = true,
	-- build experiments (parallelism_shared.lua): flip one at a time
	buildNoDistance = false,
	buildNoRedoPillars = false,
	buildChunk = 0,
	buildMergeStraights = false,
}
