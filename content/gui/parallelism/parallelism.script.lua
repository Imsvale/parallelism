-- dev aid: a save reload runs this file again but keeps the modules it requires in
-- the loader's cache, so edits to them would need a game restart. Dropping them from
-- the cache makes the requires below load the current files.
if type(_ug_loadedModules) == "table" then
	for path in pairs(_ug_loadedModules) do
		if type(path) == "string" and path:find("imsvale_parallelism", 1, true) then
			_ug_loadedModules[path] = nil
		end
	end
end

local shared = require "parallelism_shared.lua"
local geometry = require "parallelism_geometry.lua"

local planner = require "parallelism_planner.lua"

local dump = require "parallelism_dump.lua"

-- how long to wait for the player's build to show up in the world before giving up
local PENDING_MAX_FRAMES = 300

-- dev aid: log the whole proposal of every track build, also with a track count of 1
local DEBUG_DUMP = true

-- dev aid: when the combined build of the extra tracks fails, build them one by one, to
-- see which one fails and why. Builds part of a drag, so never on in play.
local ONE_BY_ONE_DIAGNOSTIC = false

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
	state:subscribeToEvent(shared.EVENT_PREVIEW_VERDICT)
end

-- gui state: toolbar values, pushed by the menu patch
local current = {
	count = 1,
	side = shared.SIDE_RIGHT,
	spacing = nil,
	reverse = false,
	-- the builder the values are for: shared.TRACK_BUILDER or shared.STREET_BUILDER
	builder = shared.TRACK_BUILDER,
}

-- gui state: whether the takeover experiment has said so in the log
local spikeLogged = false

-- dev aid: a drag starting at an existing node dumps the edges and nodes around it
-- (parallelism_dump.lua), once per node; the console runs on a lua state of its own, so
-- this is the way to trigger it
local DUMP_AT_DRAG_START = true
local lastDumpedNode = nil

local function dumpAtDragStart(param)
	local drawn = planner.collectDrawnSegments(param[1].proposal, shared.roadTypeOf(current.builder))
	if #drawn == 0 then
		lastDumpedNode = nil
		return
	end
	for __, d in ipairs(drawn) do
		for __, node in ipairs({ d.comp.node0, d.comp.node1 }) do
			local comp = node >= 0 and api.engine.getComponent(node, api.type.ComponentType.BASE_NODE) or nil
			if comp then
				if node ~= lastDumpedNode then
					lastDumpedNode = node
					shared.log("drag starts at existing node " .. node .. ", dumping around it")
					dump.around(30, comp.position.x, comp.position.y)
				end
				return
			end
		end
	end
end

-- gui state: player builds waiting to be applied before their parallel tracks are built
local pending = {}

--------------------------------------------------------------------------------
-- logging

-- dev aid: measures the crossings in the builder's proposal while dragging, next to the
-- game's verdict, to find out which crossings the game refuses
local MEASURE_CROSSINGS = true
-- dev aid (2026-10-03): the drag check's joined proposal in full before the game judges it;
-- after a crash in StreetShapeFactory the last such dump is what crashed it. Verbose.
local DUMP_BEFORE_JUDGING = false
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
-- the last drag checked and the answer
local lastCheck = { signature = nil, result = nil }
-- dev aid: how often the builder asks and what answering costs, logged every so often
local perf = { requests = 0, planned = 0, planMs = 0, measureMs = 0, worstMs = 0, judged = 0, judgeMs = 0 }


local function logPerf()
	if perf.requests >= 100 then
		shared.log(string.format("perf [tracks " .. current.count .. "]: %d builder requests, %d planned, %.0f ms planning (worst %.0f ms: %s), %.0f ms measuring, %d judged by the game in %.0f ms",
			perf.requests, perf.planned, perf.planMs, perf.worstMs, tostring(perf.worstTiming), perf.measureMs, perf.judged, perf.judgeMs))
		perf = { requests = 0, planned = 0, planMs = 0, measureMs = 0, worstMs = 0, judged = 0, judgeMs = 0 }
	end
end

-- the game's verdict on the menu's preview, pushed by the menu patch
local previewVerdict = {}
-- the game's verdicts by drag signature, the last few: holding still, the builder can
-- alternate between two slightly different drags (seen 2026-10-03), and a check that
-- knew only the latest verdict waited forever
local verdicts, verdictOrder = {}, {}
local loggedSignatures = false
local MAX_VERDICTS = 32

-- Refuse road drags whose spacing is below what the game needs between parallel roads
-- crossing a road at that angle (planner: stats.spacingNeeded). Off until it is clear
-- what the mod can build and what the game will not (the user, 2026-10-03).
local SPACING_CHECK = false

-- dev switch: judge the drawn and our part together in the drag check (judgeTogether)
-- off: it judges every such drag Construction Not Possible, also drags that build fine
-- (2026-10-03): the builder already splits the crossed road, our plan splits the same
-- original edge again, the two sets of pieces overlap
local JUDGE_TOGETHER = false

-- The builder's live proposal (a full Proposal) with our planned SimpleProposal added
-- in, judged by the game as one build. Returns a short verdict text. Our edges carry
-- ids far from the builder's (edgeIdBase); edges we remove appear as -(id + 1), as the
-- builder's own removals do; nodes the same.
local judgeCallLogged = false

local function judgeTogether(builderProposal, planned)
	-- makeProposalData takes a SimpleProposal (seen: "SimpleProposal expected, got
	-- Proposal"), so the builder's part is turned into one: its new edges and nodes as
	-- they are, its removals by real id (they appear as -(id + 1))
	local sp = builderProposal.proposal
	local ours = planned.streetProposal
	local combined = api.type.SimpleProposal.new()
	local nodesToAdd, edgesToAdd, edgesToRemove, nodesToRemove = {}, {}, {}, {}
	local configsToAdd, configsToRemove = {}, {}
	local removing = {}
	for __, n in ipairs(sp.addedNodes) do
		if n.entity < 0 then
			local node = api.type.NodeAndEntity.new()
			node.entity = n.entity
			node.comp.position = n.comp.position
			nodesToAdd[#nodesToAdd + 1] = node
		end
	end
	for __, s in ipairs(sp.addedSegments) do
		edgesToAdd[#edgesToAdd + 1] = s
	end
	for __, s in ipairs(sp.removedSegments) do
		local id = s.entity < 0 and (-s.entity - 1) or s.entity
		removing[id] = true
		edgesToRemove[#edgesToRemove + 1] = id
	end
	for __, n in ipairs(sp.removedNodes) do
		nodesToRemove[#nodesToRemove + 1] = n.entity < 0 and (-n.entity - 1) or n.entity
	end
	for __, nc in ipairs(sp.nodeConfigsToAdd) do
		configsToAdd[#configsToAdd + 1] = nc
	end
	for __, id in ipairs(sp.nodeConfigsToRemove) do
		configsToRemove[#configsToRemove + 1] = id < 0 and (-id - 1) or id
	end
	local builderEdges = #edgesToAdd
	for __, n in ipairs(ours.nodesToAdd) do
		nodesToAdd[#nodesToAdd + 1] = n
	end
	for __, s in ipairs(ours.edgesToAdd) do
		edgesToAdd[#edgesToAdd + 1] = s
	end
	for __, id in ipairs(ours.edgesToRemove) do
		if not removing[id] then
			edgesToRemove[#edgesToRemove + 1] = id
		end
	end
	for __, id in ipairs(ours.nodesToRemove) do
		nodesToRemove[#nodesToRemove + 1] = id
	end
	for __, nc in ipairs(ours.nodeConfigsToAdd) do
		configsToAdd[#configsToAdd + 1] = nc
	end
	for __, id in ipairs(ours.nodeConfigsToRemove) do
		configsToRemove[#configsToRemove + 1] = id
	end
	combined.streetProposal.nodesToAdd = nodesToAdd
	combined.streetProposal.edgesToAdd = edgesToAdd
	combined.streetProposal.edgesToRemove = edgesToRemove
	combined.streetProposal.nodesToRemove = nodesToRemove
	combined.streetProposal.nodeConfigsToAdd = configsToAdd
	combined.streetProposal.nodeConfigsToRemove = configsToRemove
	local context = api.type.Context.new()
	context.player = api.engine.util.getPlayer()
	local util = api.engine.util.proposal
	-- the argument order is not documented for this form: try both
	local ok, data = pcall(util.makeProposalData, combined, context)
	if not ok then
		local first = data
		ok, data = pcall(util.makeProposalData, context, combined)
		if not ok then
			error(tostring(first) .. " / " .. tostring(data))
		end
		if not judgeCallLogged then
			judgeCallLogged = true
			shared.log("judged together: makeProposalData(context, proposal) is the form that works")
		end
	elseif not judgeCallLogged then
		judgeCallLogged = true
		shared.log("judged together: makeProposalData(proposal, context) is the form that works")
	end
	local ours_ = #edgesToAdd - builderEdges
	builderEdges = builderEdges
	local messages = {}
	for __, m in ipairs(data.errorState.messages) do
		messages[#messages + 1] = tostring(m)
	end
	return string.format("critical %s%s (%d drawn + %d ours edges)", tostring(data.errorState.critical),
		#messages > 0 and (", " .. table.concat(messages, "; ")) or "", builderEdges, ours_)
end

-- One segment of a proposal for the log, the same for the builder's and ours (to compare
-- a refused build of ours with the native build of the same thing)
local function logSegment(prefix, s)
	local v = shared.vecToString
	local c = s.comp
	shared.log("  " .. prefix .. " edge " .. tostring(s.entity)
		.. " nodes " .. tostring(c.node0) .. " -> " .. tostring(c.node1)
		.. " p " .. v(c.position0) .. " -> " .. v(c.position1)
		.. " t " .. v(c.tangent0) .. " -> " .. v(c.tangent1)
		.. " type " .. tostring(s.type) .. "/" .. tostring(c.type) .. "/" .. tostring(c.typeIndex)
		.. " objects " .. tostring(c.objects and #c.objects or "nil")
		.. " " .. tostring(c.roadTemplate))
	-- roads: the lanes the junction configs refer to (index, direction, width, modes)
	if current.builder == shared.STREET_BUILDER then
		pcall(function()
			local lanes = {}
			for i, lc in ipairs(c.laneConfigs) do
				local modes = {}
				pcall(function()
					for mode, on in pairs(lc.transportModes) do
						if on then
							modes[#modes + 1] = tostring(mode)
						end
					end
				end)
				lanes[#lanes + 1] = string.format("%d:%s %.1f {%s}", i, lc.forward and "fwd" or "back", lc.width,
					table.concat(modes, ","))
			end
			shared.log("    lanes " .. table.concat(lanes, "; "))
		end)
	end
end

local function logNodeConfig(nc)
	local c = nc.comp
	shared.log("  + nodeConfig " .. tostring(nc.entity)
		.. " laneConnections " .. tostring(c.laneConnections and #c.laneConnections or "nil")
		.. " doubleSlipSwitch " .. tostring(c.doubleSlipSwitch))
	-- in full for roads: junctions are what the mod still has to learn to build
	if current.builder == shared.STREET_BUILDER then
		pcall(function()
			local parts = {}
			for __, l in ipairs(c.laneConnections) do
				parts[#parts + 1] = string.format("%s.%s->%s.%s%s%s", tostring(l.segment0), tostring(l.lane0),
					tostring(l.segment1), tostring(l.lane1), l.withRoad and " road" or "", l.withTram and " tram" or "")
			end
			local crosswalks = {}
			for __, e in ipairs(c.crosswalks) do
				crosswalks[#crosswalks + 1] = tostring(e)
			end
			shared.log("    lanes [" .. table.concat(parts, ", ") .. "] crosswalks [" .. table.concat(crosswalks, ", ")
				.. "] trafficLightPreference " .. tostring(c.trafficLightPreference)
				.. " userModified " .. tostring(c.userModifiedLaneConnections))
		end)
	end
end

-- The street part of a SimpleProposal of ours that the game refused, in the format of
-- the builder's dumps (dumpProposal): built natively next to it, the difference shows
-- (pairwise testing, 2026-10-03). data: its ProposalData.
local dumpedRefusals, dumpedCount = {}, 0
local function dumpOurs(label, simple, data)
	local street = simple.streetProposal
	local messages = {}
	pcall(function()
		for __, m in ipairs(data.errorState.messages) do
			messages[#messages + 1] = tostring(m)
		end
	end)
	if data then
		shared.log("dump " .. label .. ": costs = " .. tostring(data.costs) .. ", critical = " .. tostring(data.errorState.critical)
			.. ", messages [" .. table.concat(messages, "; ") .. "]")
	else
		shared.log("dump " .. label)
	end
	for __, n in ipairs(street.nodesToAdd) do
		shared.log("  + node " .. tostring(n.entity) .. " " .. shared.vecToString(n.comp.position))
	end
	for __, id in ipairs(street.nodesToRemove) do
		shared.log("  - node " .. planner.describeEntity(id))
	end
	for __, id in ipairs(street.edgesToRemove) do
		shared.log("  - edge " .. planner.describeEntity(id))
	end
	for __, s in ipairs(street.edgesToAdd) do
		logSegment("+", s)
	end
	for __, nc in ipairs(street.nodeConfigsToAdd) do
		logNodeConfig(nc)
	end
	for __, id in ipairs(street.nodeConfigsToRemove) do
		shared.log("  - nodeConfig " .. tostring(id))
	end
	pcall(function()
		for __, e in ipairs(data.collisionInfo.collisionEntities) do
			shared.log("  collides with " .. planner.describeEntity(e.entity))
		end
	end)
end

-- The builder shows only the refusal when there is one, the tooltip lines (e.g. Better
-- Construction Tooltip's crossing angle) are gone then. With that mod's "Crossing angles"
-- on, the refusal names the crossing angle itself.
local function withAngle(message, stats)
	if message == nil or stats == nil or stats.spacingAngle == nil then
		return message
	end
	local on = false
	pcall(function()
		-- 1-based index of the chosen value: 1 Off, 2 On
		on = api.engine.config.getModParams()["imsvale_better_construction_tooltip"].showCrossings == 2
	end)
	if not on then
		return message
	end
	return message .. string.format(" [crossing at %.1f°]", stats.spacingAngle)
end

local function checkPlayerProposal(param)
	if shared.builderRefuses(param[2]) then
		return nil
	end
	local drawn = planner.collectDrawnSegments(param[1].proposal, shared.roadTypeOf(current.builder))
	if #drawn == 0 then
		return nil
	end
	local signature = planner.signatureOf(drawn, current.count, current.side, current.spacing, current.reverse, current.resName)
	local verdict = verdicts[signature]
	-- the game judged the preview of this very drag and would not build it: refuse the
	-- drag rather than build part of it (the verdict arrives a little after the preview).
	-- Not only critical errors: "Too Much Curvature" came as a plain message and the
	-- build failed. The one message let through is Collision for roads, which the
	-- preview reports next to a road end the drawn road is about to continue (judged
	-- before the drawn road exists) and which builds. Messages come translated, so this
	-- only knows the English one.
	-- (with junctions in the plan a Collision is real: it once failed the build after the
	-- drawn road had been built)
	local blocking = verdict ~= nil and (verdict.critical
		or (verdict.message ~= nil
			and not (verdict.message == "Collision" and current.builder == shared.STREET_BUILDER
				and not verdict.roadJunctions)))
	if blocking then
		local message = "Parallel " .. shared.nounOf(current.builder) .. " cannot be built here"
			.. (verdict.message and (" (" .. verdict.message .. ")") or "")
			.. (verdict.roadJunctions and ". Junctions too close together? Try more spacing." or "")
		message = withAngle(message, { spacingAngle = verdict.spacingAngle })
		if message ~= lastRefusal then
			lastRefusal = message
			shared.log("check: " .. message)
		end
		local errorMessages = {}
		errorMessages[message] = true
		return { errorMessages = errorMessages, skipRender = false }
	end
	if signature == lastCheck.signature then
		return lastCheck.result
	end
	-- Every position is planned: the builder asks only when the drag changes, so an
	-- answer reused from an earlier position (planning only every few changes while it
	-- was expensive) could stick on the position the drag stopped at (seen in game: a
	-- refusal the preview of that very position did not have).
	local started = planner.clockMs()
	for __, d in ipairs(drawn) do
		d.template = current.resName
	end
	local distance = planner.parallelDistance(current.resName, current.spacing)
	-- only the verdict is needed here, not the game objects of a proposal
	local __, stats = planner.makeProposal(drawn, geometry.offsets(current.count, current.side, distance), nil, shared.PERF_MEASURES,
		{ reverse = current.reverse, overlay = param[1].proposal })
	if started then
		local took = planner.clockMs() - started
		perf.planned = perf.planned + 1
		perf.planMs = perf.planMs + took
		if took > perf.worstMs then
			perf.worstMs = took
			perf.worstTiming = stats.timing
		end
	end
	local message = nil
	local noun = shared.nounOf(current.builder)
	if stats.sharpCorner then
		message = "Parallel " .. noun .. " would turn too sharply"
	elseif stats.junctions > 0 then
		message = "Parallel " .. noun .. " would make a junction (not supported yet)"
	elseif stats.selfCrossing then
		message = "Parallel " .. noun .. " would cross each other"
	elseif stats.existingBend then
		message = "Parallel " .. noun .. " would cross a track where it bends too tightly"
	elseif stats.shortPiece then
		message = "Parallel " .. noun .. " would leave a piece too short to build"
	elseif stats.shallow > 0 then
		-- (the limit itself means nothing to the player: just that it cannot be done, and why)
		message = "Angle is too shallow"
	elseif stats.junctionsTooClose then
		message = "Too close to another junction"
	elseif stats.tooTight then
		-- (no number: where it comes from, and why it differs between road types, is not the
		-- player's concern; that it bends too tightly is)
		message = "Too much curvature on inner parallel " .. (current.builder == shared.STREET_BUILDER and "road" or "track")
	elseif #stats.problems > 0 then
		message = "Parallel " .. noun .. " cannot be laid out here"
	elseif SPACING_CHECK and stats.spacingNeeded and current.spacing and current.spacing < stats.spacingNeeded - 0.01 then
		-- (rounded up to the slider's step)
		local step = shared.SPACING_STEP
		message = string.format("Parallel %s crossing at %.0f degrees need at least %.1f m spacing", noun, stats.spacingAngle,
			math.ceil(stats.spacingNeeded / step - 1e-6) * step)
	end
	message = withAngle(message, stats)
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
	-- Experiment (2026-10-03): the game's verdict on the drawn and our part together,
	-- asked right here instead of waiting for the preview's (the builder asks only when
	-- the drag changes, so a check waiting for the preview's verdict waited forever).
	-- Logged only for now, to compare with the preview's verdicts.
	-- The game's verdict on our part, asked right here: the same judgement the preview gets
	-- (our plan against the world, before the drawn road exists), without its delay. A
	-- drag released before the preview's verdict arrived was built in part (2026-10-03).
	-- (not when the preview's verdict on this very drag is already in: one judgement less,
	-- each leaves a large native object behind)
	if result == nil and verdict == nil and (stats.crossings + stats.anchored) > 0 then
		local ok, err = pcall(function()
			local planned = planner.makeProposal(drawn, geometry.offsets(current.count, current.side, distance), nil, false,
				{ reverse = current.reverse, overlay = param[1].proposal })
			if planned then
				-- judged together with the builder's part: it was planned against it
				planned = planner.joinWithBuilder(param[1].proposal, planned, current.resName)
				local context = api.type.Context.new()
				context.player = api.engine.util.getPlayer()
				if DUMP_BEFORE_JUDGING then
					pcall(dumpOurs, "before judging (drag check)", planned, nil)
				end
				local judgeStarted = planner.clockMs()
				local data = api.engine.util.proposal.makeProposalData(planned, context)
				if judgeStarted then
					perf.judged = perf.judged + 1
					perf.judgeMs = perf.judgeMs + planner.clockMs() - judgeStarted
				end
				-- town buildings in the way are bulldozed, as in the preview: judged again with them
				local candidates = {}
				pcall(function()
					for __, e in ipairs(data.collisionInfo.collisionEntities) do
						local c = planner.townBuildingCandidate(e.entity)
						if c then
							candidates[#candidates + 1] = c
						end
					end
				end)
				if #candidates > 0 then
					planned.constructionsToRemove = planner.buildingsInTheWay(planned, candidates)
					data = api.engine.util.proposal.makeProposalData(planned, context)
				end
				local gameMessage = #data.errorState.messages > 0 and tostring(data.errorState.messages[1]) or nil
				-- same rule as for the preview: any message stops it, but a road Collision
				-- without junctions (a road end the drawn road continues, judged before it exists)
				local blocking = data.errorState.critical or (gameMessage ~= nil
					and not (gameMessage == "Collision" and current.builder == shared.STREET_BUILDER and stats.crossings + stats.anchored == 0))
				if blocking then
					-- in full, once per drag position, to compare with the native build
					if not dumpedRefusals[signature] then
						dumpedRefusals[signature] = true
						dumpedCount = dumpedCount + 1
						if dumpedCount > 200 then
							dumpedRefusals, dumpedCount = {}, 0
						end
						pcall(dumpOurs, "refused (ours joined with the builder's)", planned, data)
					end
					message = "Parallel " .. noun .. " cannot be built here (" .. tostring(gameMessage) .. ")"
						.. (current.builder == shared.STREET_BUILDER and ". Junctions too close together? Try more spacing." or "")
					message = withAngle(message, stats)
					local errorMessages = {}
					errorMessages[message] = true
					result = { errorMessages = errorMessages, skipRender = false }
				end
			end
		end)
		if not ok then
			shared.log("check: the game's verdict could not be asked: " .. tostring(err))
			-- without the game's verdict the drag could build in part: refused
			message = withAngle("Parallel " .. noun .. " cannot be laid out here", stats)
			local errorMessages = {}
			errorMessages[message] = true
			result = { errorMessages = errorMessages, skipRender = false }
		end
		if message ~= lastRefusal then
			lastRefusal = message
			shared.log("check: " .. (message or "ok"))
		end
	end
	if result == nil and JUDGE_TOGETHER and (stats.crossings + stats.anchored) > 0 then
		local ok, err = pcall(function()
			local planned = planner.makeProposal(drawn, geometry.offsets(current.count, current.side, distance), nil, false,
				{ reverse = current.reverse, edgeIdBase = -300000 })
			if planned then
				local verdictNow = judgeTogether(param[1], planned)
				shared.log("judged together: " .. verdictNow)
			end
		end)
		if not ok then
			shared.log("judged together: failed: " .. tostring(err))
		end
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
	for __, s in ipairs(street.removedSegments) do
		logSegment("-", s)
	end
	for __, s in ipairs(street.addedSegments) do
		logSegment("+", s)
	end
	for __, nc in ipairs(street.nodeConfigsToAdd) do
		logNodeConfig(nc)
	end
	for __, entity in ipairs(street.nodeConfigsToRemove) do
		shared.log("  - nodeConfig " .. tostring(entity))
	end
	shared.log("  edgeObjectsToAdd " .. #street.edgeObjectsToAdd
		.. ", parallel strips + " .. #data.parallelProposal.toAdd .. " / - " .. #data.parallelProposal.toRemove)
	-- buildings in the way: how the builder's own proposal bulldozes them
	local ok, err = pcall(function()
		for __, entity in ipairs(proposal.toRemove) do
			shared.log("  - construction " .. planner.describeEntity(entity))
		end
		local collision = data.collisionInfo
		for __, e in ipairs(collision.collisionEntities) do
			shared.log("  collides with " .. planner.describeEntity(e.entity))
		end
		for entity in pairs(collision.autoRemovalEntity2models) do
			shared.log("  auto-removes " .. planner.describeEntity(entity))
		end
		for __, entity in ipairs(collision.buildingEntities) do
			shared.log("  building entity " .. planner.describeEntity(entity))
		end
		for __, entity in ipairs(collision.removableModules) do
			shared.log("  removable module " .. planner.describeEntity(entity))
		end
	end)
	if not ok then
		shared.log("  removals: " .. tostring(err))
	end
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
		.. stats.dropped .. " own nodes dropped, " .. stats.skipped .. " splits skipped, "
		.. tostring(stats.nodeConfigs or 0) .. " node configs"
end

-- Sends one build and logs how it went; onDone(success, game message) runs after it.
local function sendBuild(label, proposal, stats, onDone)
	-- with a player in the context the build is paid like the player's own, as the base
	-- game does when swapping a bridge type from the entity window
	-- a fresh context (logged 2026-10-02): gatherFields true, checkTerrainAlignment,
	-- gatherBuildings, cleanupStreetGraph and extendProposalRedoPillars false
	local context = api.type.Context.new()
	context.player = api.engine.util.getPlayer()
	-- bridges: without it a bundle got only a narrow central pillar, built one by one
	-- natively it gets one across its whole width (fixed together with the edge
	-- distance, which of the two did it was not tested)
	context.extendProposalRedoPillars = true
	api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(proposal, context, false, true, true), function(res, success)
		local costs = ""
		pcall(function()
			costs = ", costs " .. tostring(res.resultProposalData.costs)
		end)
		shared.log(label .. " (" .. describeStats(stats) .. "): " .. (success and "ok" or "FAILED") .. costs)
		local message = nil
		if not success then
			-- the whole plan, as a lua table that tests can load
			shared.log("  plan: " .. planner.planToString(stats.plan))
			local ok, err = pcall(logErrorState, res)
			if not ok then
				shared.log("  no error details: " .. tostring(err))
			end
			pcall(function()
				local messages = res.resultProposalData.errorState.messages
				message = #messages > 0 and tostring(messages[1]) or nil
			end)
		end
		onDone(success, message)
	end)
end

-- Shows the player a message in the game's notifications.
local function notify(description)
	local notification = {
		type = "imsvale_parallelism::/gui/parallelism/parallelism_notification.script",
		params = { title = _("Parallelism"), description = description },
		autoDismissDuration = 60000,
	}
	local ok, err = pcall(function()
		api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd("", "Notifications", "add", notification))
	end)
	if not ok then
		shared.log("notification failed: " .. tostring(err))
	end
end

-- Diagnostic, not for play (ONE_BY_ONE_DIAGNOSTIC): builds the track at offsets[index],
-- then the next one once that is in the world, one command per track planned from the
-- world as it is then. Builds what it can around a track that fails, which the mod must
-- not do; it shows which track fails and why, when the combined build fails.
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
	local proposal, stats = planner.makeProposal(readDrawn(job), offset, shared.log, false, { reverse = job.reverse, step = job.distance })
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
-- or not at all, and it is the same plan the preview shows. If the game refuses it,
-- nothing is built: either a game limit or a fault in the mod, to be found and dealt
-- with here (ONE_BY_ONE_DIAGNOSTIC shows which track fails).
local function buildCombined(job)
	shared.log("tracks at offsets " .. table.concat(job.offsets, ", ") .. ":")
	local proposal, stats = planner.makeProposal(readDrawn(job), job.offsets, shared.log, false,
		{ reverse = job.reverse, step = job.distance })
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
	-- the town buildings the preview showed bulldozed, those still standing (the drawn
	-- track may have taken some) and still in the way of this plan
	local candidates = {}
	for i, construction in ipairs(previewVerdict.bulldozeConstructions or {}) do
		candidates[#candidates + 1] = { construction = construction, building = previewVerdict.bulldozeBuildings[i] }
	end
	local bulldoze = planner.buildingsInTheWay(proposal, candidates)
	if #bulldoze > 0 then
		proposal.constructionsToRemove = bulldoze
		shared.log("  bulldozes " .. #bulldoze .. " buildings: " .. table.concat(bulldoze, ", "))
	end
	sendBuild("all tracks", proposal, stats, function(success, message)
		if not success then
			if ONE_BY_ONE_DIAGNOSTIC then
				shared.log("combined build failed, ONE_BY_ONE_DIAGNOSTIC: building the tracks one by one")
				job.built = 0
				buildNext(job, 1)
			else
				shared.log("combined build failed, nothing built")
				notify("The parallel " .. shared.nounOf(job.builder) .. " could not be built"
					.. (message and (": " .. message) or "") .. ". Only the drawn one was built.")
			end
		end
	end)
end

-- Runs once the player's build is in the world: the drawn edges are read back from
-- there, and edges it split are found in their new state.
local function runJob(job)
	local ok, err = pcall(function()
		local comp = planner.getEdgeComp(job.drawn[1].entity)
		job.distance = planner.parallelDistance(comp.roadTemplate, job.spacing)
		job.offsets = geometry.offsets(job.count, job.side, job.distance)
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
				current.spacing = param.spacing
				current.reverse = reverse
				current.builder = builder
				shared.log("params: " .. builder .. ", count = " .. tostring(current.count) .. ", side = " .. tostring(current.side)
					.. ", spacing = " .. tostring(current.spacing) .. ", reverse = " .. tostring(current.reverse))
			end
		elseif name == shared.EVENT_PREVIEW_VERDICT then
			if param.critical ~= previewVerdict.critical then
				shared.log("preview verdict for the drag check: critical " .. tostring(param.critical) .. ", " .. tostring(param.message))
			end
			previewVerdict = { signature = param.signature, critical = param.critical, message = param.message,
				roadJunctions = param.roadJunctions, spacingAngle = param.spacingAngle,
				bulldozeConstructions = param.bulldozeConstructions or {}, bulldozeBuildings = param.bulldozeBuildings or {} }
			if param.signature then
				if verdicts[param.signature] == nil then
					verdictOrder[#verdictOrder + 1] = param.signature
					if #verdictOrder > MAX_VERDICTS then
						verdicts[table.remove(verdictOrder, 1)] = nil
					end
				end
				verdicts[param.signature] = previewVerdict
			end
		elseif name == "builder.proposalCreate" and id == current.builder then
			perf.requests = perf.requests + 1
			logPerf()
			if DUMP_AT_DRAG_START then
				local ok, err = pcall(dumpAtDragStart, param)
				if not ok then
					shared.log("dumpAtDragStart failed: " .. tostring(err))
				end
			end
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
					result = nil
				end
				if shared.SPIKE_TAKEOVER and current.builder == shared.STREET_BUILDER then
					-- experiment: does the builder hide its own preview without refusing?
					if not spikeLogged then
						spikeLogged = true
						shared.log("spike: returning skipRender = true for the road builder's proposal")
					end
					return { errorMessages = result and result.errorMessages or nil, skipRender = true }
				end
				if result then
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
