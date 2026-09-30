-- dev aid: a save reload runs this file again but keeps the modules it requires in
-- the loader's cache, so edits to them would need a game restart. Dropping them from
-- the cache makes the requires below load the current files.
if type(_ug_loadedModules) == "table" then
	for path in pairs(_ug_loadedModules) do
		if type(path) == "string" and path:find("imsvale_parallel_tracks", 1, true) then
			_ug_loadedModules[path] = nil
		end
	end
end

local shared = require "ptracks_shared.lua"
local geometry = require "ptracks_geometry.lua"

local planner = require "ptracks_planner.lua"

-- how long to wait for the player's build to show up in the world before giving up
local PENDING_MAX_FRAMES = 300

-- dev aid: log the whole proposal of every track build, also with a track count of 1
local DEBUG_DUMP = true

-- dev aid: skip the combined build and go straight to the one-by-one fallback, to see
-- its notification
local FORCE_FALLBACK = false

-- engine state: once per loaded script, saves made before an event was added still get it
local subscribed = false

local function ensureSubscriptions(state)
	if subscribed then
		return
	end
	subscribed = true
	state:subscribeToEvent("builder.proposalApply")
	state:subscribeToEvent("builder.proposalCreate")
	state:subscribeToEvent(shared.EVENT_SET_PARAMS)
end

-- gui state: toolbar values, pushed by the menu patch
local current = {
	count = 1,
	side = shared.SIDE_RIGHT,
	spacing = 0,
	reverse = false,
	-- the builder the values are for: shared.TRACK_BUILDER or shared.STREET_BUILDER
	builder = shared.TRACK_BUILDER,
}

-- gui state: player builds waiting to be applied before their parallel tracks are built
local pending = {}

--------------------------------------------------------------------------------
-- logging

-- dev aid: measures the crossings in the builder's proposal while dragging, next to the
-- game's verdict, to find out which crossings the game refuses
local MEASURE_CROSSINGS = true
local lastMeasurement = nil

local function angleBetween(a, b)
	local la = math.sqrt(a.x * a.x + a.y * a.y)
	local lb = math.sqrt(b.x * b.x + b.y * b.y)
	if la < 1e-9 or lb < 1e-9 then
		return 0
	end
	local c = (a.x * b.x + a.y * b.y) / (la * lb)
	return math.deg(math.acos(math.max(-1, math.min(1, c))))
end

local function measureCrossings(param)
	local street = param[1].proposal
	local errorState = param[2].errorState

	-- the added edges at each node, with the direction leaving the node
	local byNode = {}
	for __, s in ipairs(street.addedSegments) do
		local edge = planner.toEdge(s.comp)
		local length = geometry.arcLength(edge)
		for __, e in ipairs({
			{ node = s.comp.node0, dir = edge.t0, length = length },
			{ node = s.comp.node1, dir = { x = -edge.t1.x, y = -edge.t1.y }, length = length },
		}) do
			byNode[e.node] = byNode[e.node] or {}
			table.insert(byNode[e.node], e)
		end
	end

	local crossings = {}
	for __, list in pairs(byNode) do
		if #list == 4 then
			-- pair the edges into the two tracks running straight through
			local best, bestPairing = math.huge, nil
			for __, pairing in ipairs({ { 1, 2, 3, 4 }, { 1, 3, 2, 4 }, { 1, 4, 2, 3 } }) do
				local bend = math.max(180 - angleBetween(list[pairing[1]].dir, list[pairing[2]].dir),
					180 - angleBetween(list[pairing[3]].dir, list[pairing[4]].dir))
				if bend < best then
					best, bestPairing = bend, pairing
				end
			end
			local p = bestPairing
			local angle = angleBetween(list[p[1]].dir, list[p[3]].dir)
			if angle > 90 then
				angle = 180 - angle
			end
			crossings[#crossings + 1] = string.format("%.1f deg, pieces %.1f/%.1f and %.1f/%.1f m%s",
				angle, list[p[1]].length, list[p[2]].length, list[p[3]].length, list[p[4]].length,
				best > 1 and string.format(" (bends %.1f deg)", best) or "")
		end
	end
	table.sort(crossings)

	local messages = {}
	for __, m in ipairs(errorState.messages) do
		messages[#messages + 1] = tostring(m)
	end
	local verdict = errorState.critical and "REFUSED" or (#messages > 0 and "not ok" or "ok")
	local summary = verdict .. (#messages > 0 and (" (" .. table.concat(messages, "; ") .. ")") or "")
		.. ", " .. #crossings .. " crossings" .. (#crossings > 0 and (": " .. table.concat(crossings, " | ")) or "")
	-- only the boundary: the state just before and just after the verdict flips
	if lastMeasurement ~= nil and verdict ~= lastMeasurement.verdict then
		shared.log("measure: " .. lastMeasurement.summary)
		shared.log("measure: " .. summary)
	end
	lastMeasurement = { verdict = verdict, summary = summary }
end

-- The builder asks the game scripts about its proposal on every change of the drag. If
-- one of the extra tracks would cross another track flatter than the game allows, the
-- whole drag is refused, with the reason, instead of building the rest around it.
local lastRefusal = nil
-- the last drag checked and the answer, the builder asks about the same drag many times
local lastCheck = { signature = nil, result = nil }
local checkDebounce = planner.newDebounce(planner.PLAN_EVERY, planner.CHEAP_PLAN_MS)
-- dev aid: how often the builder asks and what answering costs, logged every so often
local perf = { requests = 0, planned = 0, planMs = 0, measureMs = 0, worstMs = 0 }

local function logPerf()
	if perf.requests >= 100 then
		shared.log(string.format("perf [tracks " .. current.count .. "]: %d builder requests, %d planned, %.0f ms planning (worst %.0f ms: %s), %.0f ms measuring",
			perf.requests, perf.planned, perf.planMs, perf.worstMs, tostring(perf.worstTiming), perf.measureMs))
		perf = { requests = 0, planned = 0, planMs = 0, measureMs = 0, worstMs = 0 }
	end
end

local function checkPlayerProposal(param)
	local drawn = planner.collectDrawnSegments(param[1].proposal, shared.roadTypeOf(current.builder))
	if #drawn == 0 then
		return nil
	end
	local signature = planner.signatureOf(drawn, current.count, current.side, current.spacing, current.reverse, current.resName)
	if signature == lastCheck.signature then
		return lastCheck.result
	end
	-- while the drag moves, the answer for a recent position stands in; the position it
	-- stops at is always checked
	if not checkDebounce.shouldPlan(signature) then
		return lastCheck.result
	end
	checkDebounce.planned(signature)
	local started = planner.clockMs()
	for __, d in ipairs(drawn) do
		d.template = current.resName
	end
	local distance = planner.getTrackDistance(current.resName) + current.spacing
	-- only the verdict is needed here, not the game objects of a proposal
	local __, stats = planner.makeProposal(drawn, geometry.offsets(current.count, current.side, distance), nil, shared.PERF_MEASURES,
		{ reverse = current.reverse })
	if started then
		local took = planner.clockMs() - started
		checkDebounce.planned(signature, took)
		perf.planned = perf.planned + 1
		perf.planMs = perf.planMs + took
		if took > perf.worstMs then
			perf.worstMs = took
			perf.worstTiming = stats.timing
		end
	end
	local message = nil
	local noun = shared.nounOf(current.builder)
	if stats.selfCrossing then
		message = "Parallel " .. noun .. " would cross each other"
	elseif stats.shortPiece then
		message = "Parallel " .. noun .. " would leave a piece too short to build"
	elseif stats.shallow > 0 then
		message = string.format("Parallel %s would cross at less than %.0f degrees", noun, planner.MIN_CROSSING_ANGLE)
	elseif stats.tooTight then
		message = string.format("Parallel %s would curve tighter than %.0f m", noun, stats.minAllowedRadius)
	elseif #stats.problems > 0 then
		message = "Parallel " .. noun .. " cannot be laid out here"
	end
	if message ~= lastRefusal then
		lastRefusal = message
		shared.log("check: " .. (message or "ok"))
	end
	local result = nil
	if message ~= nil then
		local errorMessages = {}
		errorMessages[message] = true
		result = { errorMessages = errorMessages, skipRender = false }
	end
	lastCheck = { signature = signature, result = result }
	return result
end

local function dumpProposal(id, param)
	local proposal = param[1]
	local data = param[2]
	local street = proposal.proposal
	local v = shared.vecToString
	shared.log("dump " .. id .. ": costs = " .. tostring(data.costs)
		.. ", critical = " .. tostring(data.errorState.critical))
	for __, n in ipairs(street.addedNodes) do
		shared.log("  + node " .. tostring(n.entity) .. " " .. v(n.comp.position))
	end
	for __, n in ipairs(street.removedNodes) do
		shared.log("  - node " .. tostring(n.entity) .. " " .. v(n.comp.position))
	end
	local function logSegment(prefix, s)
		local c = s.comp
		shared.log("  " .. prefix .. " edge " .. tostring(s.entity)
			.. " nodes " .. tostring(c.node0) .. " -> " .. tostring(c.node1)
			.. " p " .. v(c.position0) .. " -> " .. v(c.position1)
			.. " t " .. v(c.tangent0) .. " -> " .. v(c.tangent1)
			.. " type " .. tostring(s.type) .. "/" .. tostring(c.type) .. "/" .. tostring(c.typeIndex)
			.. " objects " .. tostring(c.objects and #c.objects or "nil")
			.. " " .. tostring(c.roadTemplate))
	end
	for __, s in ipairs(street.removedSegments) do
		logSegment("-", s)
	end
	for __, s in ipairs(street.addedSegments) do
		logSegment("+", s)
	end
	for __, nc in ipairs(street.nodeConfigsToAdd) do
		local c = nc.comp
		shared.log("  + nodeConfig " .. tostring(nc.entity)
			.. " laneConnections " .. tostring(c.laneConnections and #c.laneConnections or "nil")
			.. " doubleSlipSwitch " .. tostring(c.doubleSlipSwitch))
	end
	for __, entity in ipairs(street.nodeConfigsToRemove) do
		shared.log("  - nodeConfig " .. tostring(entity))
	end
	shared.log("  edgeObjectsToAdd " .. #street.edgeObjectsToAdd
		.. ", parallel strips + " .. #data.parallelProposal.toAdd .. " / - " .. #data.parallelProposal.toRemove)
end


local function logErrorState(res)
	local data = res.resultProposalData
	local ok, err = pcall(function()
		local collision = data.collisionInfo
		for __, e in ipairs(collision.collisionEntities) do
			shared.log("  collides with " .. planner.describeEntity(e.entity))
		end
		for entity in pairs(collision.autoRemovalEntity2models) do
			shared.log("  would auto-remove " .. planner.describeEntity(entity))
		end
		for __, entity in ipairs(collision.buildingEntities) do
			shared.log("  touches building " .. planner.describeEntity(entity))
		end
	end)
	if not ok then
		shared.log("  no collision info: " .. tostring(err))
	end
	local errorState = data.errorState
	shared.log("  critical = " .. tostring(errorState.critical))
	for __, message in ipairs(errorState.messages) do
		shared.log("  message: " .. tostring(message))
	end
	for __, warning in ipairs(errorState.warnings) do
		shared.log("  warning: " .. tostring(warning))
	end
end

--------------------------------------------------------------------------------
-- building all offset tracks of a player build

-- The drawn edges as they are in the world now
local function readDrawn(job)
	local drawn = {}
	for __, d in ipairs(job.drawn) do
		local comp = planner.getEdgeComp(d.entity)
		drawn[#drawn + 1] = { entity = d.entity, segmentType = d.segmentType, comp = comp, edge = planner.toEdge(comp) }
	end
	return drawn
end

local function describeStats(stats)
	return stats.edges .. " edges, min radius " .. planner.formatRadius(stats.minRadius)
		.. ", " .. stats.reused .. " existing nodes, " .. stats.anchored .. " anchored, "
		.. stats.crossings .. " crossings, " .. stats.shallow .. " too shallow, " .. stats.moved .. " nodes moved, "
		.. stats.dropped .. " own nodes dropped, " .. stats.skipped .. " splits skipped"
end

-- Sends one build and logs how it went; onDone(success) runs after it.
local function sendBuild(label, proposal, stats, onDone)
	-- with a player in the context the build is paid like the player's own, as the base
	-- game does when swapping a bridge type from the entity window
	local context = api.type.Context.new()
	context.player = api.engine.util.getPlayer()
	api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(proposal, context, false, true, true), function(res, success)
		local costs = ""
		pcall(function()
			costs = ", costs " .. tostring(res.resultProposalData.costs)
		end)
		shared.log(label .. " (" .. describeStats(stats) .. "): " .. (success and "ok" or "FAILED") .. costs)
		if not success then
			-- the whole plan, as a lua table that tests can load
			shared.log("  plan: " .. planner.planToString(stats.plan))
			local ok, err = pcall(logErrorState, res)
			if not ok then
				shared.log("  no error details: " .. tostring(err))
			end
		end
		onDone(success)
	end)
end

-- Shows the player a message in the game's notifications.
local function notify(description)
	local notification = {
		type = "imsvale_parallel_tracks::/gui/parallel_tracks/ptracks_notification.script",
		params = { title = _("Parallel Tracks"), description = description },
		autoDismissDuration = 60000,
	}
	local ok, err = pcall(function()
		api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd("", "Notifications", "add", notification))
	end)
	if not ok then
		shared.log("notification failed: " .. tostring(err))
	end
end

-- Fallback: builds the track at offsets[index], then the next one once that is in the
-- world. One command per track, planned from the world as it is at that moment, so a
-- track that cannot be built does not take the others with it.
local buildTrack

local function buildNext(job, index)
	local ok, err = pcall(buildTrack, job, index)
	if not ok then
		shared.log("buildTrack failed: " .. tostring(err))
	end
end

buildTrack = function(job, index)
	local offset = job.offsets[index]
	if offset == nil then
		local total = #job.offsets
		local noun = shared.nounOf(job.builder)
		notify(string.format("The parallel %s could not be built together, so they were built one by one: %d of %d built.",
			noun, job.built, total))
		return
	end
	shared.log("track at offset " .. offset .. ":")
	local proposal, stats = planner.makeProposal(readDrawn(job), offset, shared.log, false, { reverse = job.reverse })
	if stats.edges == 0 or #stats.problems > 0 then
		buildNext(job, index + 1)
		return
	end
	sendBuild("track at offset " .. offset, proposal, stats, function(success)
		if success then
			job.built = job.built + 1
		end
		buildNext(job, index + 1)
	end)
end

-- All extra tracks in one command: they appear together, the drag is built completely
-- or not at all, and it is the same plan the preview shows. While it is new, a failure
-- falls back to building the tracks one by one, and the log tells how often that is.
local function buildCombined(job)
	shared.log("tracks at offsets " .. table.concat(job.offsets, ", ") .. ":")
	local proposal, stats = planner.makeProposal(readDrawn(job), job.offsets, shared.log, false, { reverse = job.reverse })
	if stats.edges == 0 then
		return
	end
	if #stats.problems > 0 then
		-- never hand the game a plan like this, it can crash on it
		shared.log("  not built: the plan has " .. #stats.problems .. " problems")
		shared.log("  plan: " .. planner.planToString(stats.plan))
		notify("The parallel " .. shared.nounOf(job.builder) .. " were not built: they cannot be laid out safely here.")
		return
	end
	if FORCE_FALLBACK then
		shared.log("FORCE_FALLBACK: building the tracks one by one")
		job.built = 0
		buildNext(job, 1)
		return
	end
	sendBuild("all tracks", proposal, stats, function(success)
		if not success then
			shared.log("combined build failed, building the tracks one by one")
			job.built = 0
			buildNext(job, 1)
		end
	end)
end

-- Runs once the player's build is in the world: the drawn edges are read back from
-- there, and edges it split are found in their new state.
local function runJob(job)
	local ok, err = pcall(function()
		local comp = planner.getEdgeComp(job.drawn[1].entity)
		job.offsets = geometry.offsets(job.count, job.side, planner.getTrackDistance(comp.roadTemplate) + job.spacing)
		buildCombined(job)
	end)
	if not ok then
		shared.log("runJob failed: " .. tostring(err))
	end
end

local function onPlayerBuild(param)
	local streetProposal = param[1].proposal
	local drawn = planner.collectDrawnSegments(streetProposal, shared.roadTypeOf(current.builder))
	local drawnRadius = math.huge
	for __, d in ipairs(drawn) do
		drawnRadius = math.min(drawnRadius, geometry.radius(d.edge.p0, d.edge.p1, d.edge.t0, d.edge.t1))
	end
	shared.log("apply: count = " .. current.count .. ", side = " .. current.side
		.. ", added = " .. #streetProposal.addedSegments
		.. ", removed = " .. #streetProposal.removedSegments
		.. ", drawn = " .. #drawn
		.. ", min radius = " .. planner.formatRadius(drawnRadius))
	if #drawn == 0 then
		return
	end

	local job = { drawn = drawn, count = current.count, side = current.side, spacing = current.spacing,
		reverse = current.reverse, builder = current.builder, frames = 0 }
	if planner.isApplied(drawn) then
		shared.log("  player build already in the world")
		runJob(job)
	else
		pending[#pending + 1] = job
	end
end

local function processPending()
	if #pending == 0 then
		return
	end
	local remaining = {}
	for __, job in ipairs(pending) do
		if planner.isApplied(job.drawn) then
			shared.log("  player build in the world after " .. job.frames .. " frames")
			runJob(job)
		else
			job.frames = job.frames + 1
			if job.frames > PENDING_MAX_FRAMES then
				shared.log("  gave up waiting for the player build")
			else
				remaining[#remaining + 1] = job
			end
		end
	end
	pending = remaining
end

function data()
return {
	update = function(_userParams, state, _dt)
		ensureSubscriptions(state)
	end,

	handleEvent = function(_userParams, state, _src, _id, _name, _param)
		ensureSubscriptions(state)
	end,

	guiUpdate = function(_userParams, _state, _guiState)
		local ok, err = pcall(processPending)
		if not ok then
			pending = {}
			shared.log("processPending failed: " .. tostring(err))
		end
	end,

	guiHandleEvent = function(_userParams, _state, _guiState, _src, id, name, param)
		if name == shared.EVENT_SET_PARAMS then
			current.resName = param.resName
			local builder = param.builder or shared.TRACK_BUILDER
			local reverse = param.reverse or false
			if param.count ~= current.count or param.side ~= current.side or param.spacing ~= current.spacing
				or reverse ~= current.reverse or builder ~= current.builder then
				current.count = param.count
				current.side = param.side
				current.spacing = param.spacing or 0
				current.reverse = reverse
				current.builder = builder
				shared.log("params: " .. builder .. ", count = " .. tostring(current.count) .. ", side = " .. tostring(current.side)
					.. ", spacing = " .. tostring(current.spacing) .. ", reverse = " .. tostring(current.reverse))
			end
		elseif name == "builder.proposalCreate" and id == current.builder then
			perf.requests = perf.requests + 1
			logPerf()
			if MEASURE_CROSSINGS then
				local started = planner.clockMs()
				local ok, err = pcall(measureCrossings, param)
				if not ok then
					shared.log("measureCrossings failed: " .. tostring(err))
				end
				if started then
					perf.measureMs = perf.measureMs + planner.clockMs() - started
				end
			end
			if current.count > 1 then
				local ok, result = pcall(checkPlayerProposal, param)
				if not ok then
					shared.log("checkPlayerProposal failed: " .. tostring(result))
				elseif result then
					return result
				end
			end
		elseif name == "builder.proposalApply" and id == current.builder then
			if DEBUG_DUMP then
				local ok, err = pcall(dumpProposal, id, param)
				if not ok then
					shared.log("dumpProposal failed: " .. tostring(err))
				end
			end
			if current.count > 1 then
				local ok, err = pcall(onPlayerBuild, param)
				if not ok then
					shared.log("onPlayerBuild failed: " .. tostring(err))
				end
			end
		end
	end,
}
end
