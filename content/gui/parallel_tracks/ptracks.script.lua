local shared = require "ptracks_shared.lua"
local geometry = require "ptracks_geometry.lua"

-- an added segment within this distance of a removed one is a leftover of splitting it
local REMNANT_TOLERANCE = 0.25
local DEFAULT_TRACK_DISTANCE = 5.0

-- engine state: once per loaded script, saves made before an event was added still get it
local subscribed = false

local function ensureSubscriptions(state)
	if subscribed then
		return
	end
	subscribed = true
	state:subscribeToEvent("builder.proposalApply")
	state:subscribeToEvent(shared.EVENT_SET_PARAMS)
end

-- gui state: toolbar values, pushed by the menu patch
local current = {
	count = 1,
	side = shared.SIDE_RIGHT,
}

local function plain(v)
	return { x = v.x, y = v.y, z = v.z }
end

local function vec3(v)
	return api.type.Vec3f.new(v.x, v.y, v.z)
end

local function toEdge(comp)
	return {
		p0 = plain(comp.position0),
		p1 = plain(comp.position1),
		t0 = plain(comp.tangent0),
		t1 = plain(comp.tangent1),
	}
end

local function getTrackDistance(roadTemplate)
	local ok, distance = pcall(function()
		return api.res.streetTemplateRep.get(api.res.streetTemplateRep.find(roadTemplate)).trackDistance
	end)
	if ok and distance and distance > 0 then
		return distance
	end
	return DEFAULT_TRACK_DISTANCE
end

-- The segments the player has drawn. The proposal also re-adds the pieces of every
-- existing track or street that got split by the new track, those are left out.
local function collectDrawnSegments(streetProposal)
	local removed = {}
	for __, segment in ipairs(streetProposal.removedSegments) do
		removed[#removed + 1] = toEdge(segment.comp)
	end

	local drawn = {}
	for __, segment in ipairs(streetProposal.addedSegments) do
		if segment.comp.roadType == api.type["enum"].RoadType.TRACK then
			local edge = toEdge(segment.comp)
			local remnant = false
			for __, other in ipairs(removed) do
				if geometry.liesOn(edge, other, REMNANT_TOLERANCE) then
					remnant = true
					break
				end
			end
			if not remnant then
				drawn[#drawn + 1] = { segment = segment, edge = edge }
			end
		end
	end
	return drawn
end

-- proposal for one track next to the drawn one, and the tightest radius on it
local function makeProposal(drawn, offset)
	local nodesToAdd = {}
	local edgesToAdd = {}
	local nextEdgeId = -1
	local nextNodeId = -100000
	local minRadius = math.huge

	-- node of the drawn track -> its counterpart on the offset track
	local nodes = {}
	local function getNode(entity, position, tangent)
		local node = nodes[entity]
		if node == nil then
			local newPosition = geometry.offsetPoint(position, tangent, offset)
			if newPosition == nil then
				return nil
			end
			local nodeAndEntity = api.type.NodeAndEntity.new()
			nodeAndEntity.entity = nextNodeId
			nodeAndEntity.comp.position = vec3(newPosition)
			nodesToAdd[#nodesToAdd + 1] = nodeAndEntity
			node = { entity = nextNodeId, position = newPosition }
			nodes[entity] = node
			nextNodeId = nextNodeId - 1
		end
		return node
	end

	for __, d in ipairs(drawn) do
		local comp = d.segment.comp
		local edge = d.edge
		local node0 = getNode(comp.node0, edge.p0, edge.t0)
		local node1 = getNode(comp.node1, edge.p1, edge.t1)
		if node0 and node1 then
			local t0, t1 = geometry.offsetTangents(edge.p0, edge.p1, edge.t0, edge.t1, node0.position, node1.position)
			minRadius = math.min(minRadius, geometry.radius(node0.position, node1.position, t0, t1))

			local newSegment = api.type.SegmentAndEntity.new()
			newSegment.entity = nextEdgeId
			nextEdgeId = nextEdgeId - 1
			newSegment.type = d.segment.type
			newSegment.comp.node0 = node0.entity
			newSegment.comp.node1 = node1.entity
			newSegment.comp.position0 = vec3(node0.position)
			newSegment.comp.position1 = vec3(node1.position)
			newSegment.comp.tangent0 = vec3(t0)
			newSegment.comp.tangent1 = vec3(t1)
			newSegment.comp.type = comp.type
			newSegment.comp.typeIndex = comp.typeIndex
			newSegment.comp.laneConfigs = comp.laneConfigs
			newSegment.comp.roadTemplate = comp.roadTemplate
			newSegment.comp.roadStyle = comp.roadStyle
			newSegment.comp.roadType = comp.roadType
			-- not set by the base game's scripted track builder, so optional here
			pcall(function()
				newSegment.playerOwned = d.segment.playerOwned
			end)
			edgesToAdd[#edgesToAdd + 1] = newSegment
		end
	end

	local proposal = api.type.SimpleProposal.new()
	proposal.streetProposal.nodesToAdd = nodesToAdd
	proposal.streetProposal.edgesToAdd = edgesToAdd
	return proposal, #edgesToAdd, minRadius
end

local function logErrorState(res)
	local errorState = res.resultProposalData.errorState
	shared.log("  critical = " .. tostring(errorState.critical))
	for __, message in ipairs(errorState.messages) do
		shared.log("  message: " .. tostring(message))
	end
	for __, warning in ipairs(errorState.warnings) do
		shared.log("  warning: " .. tostring(warning))
	end
end

local function buildParallelTracks(param)
	local streetProposal = param[1].proposal
	local drawn = collectDrawnSegments(streetProposal)
	local drawnRadius = math.huge
	for __, d in ipairs(drawn) do
		drawnRadius = math.min(drawnRadius, geometry.radius(d.edge.p0, d.edge.p1, d.edge.t0, d.edge.t1))
	end
	shared.log("apply: count = " .. current.count .. ", side = " .. current.side
		.. ", added = " .. #streetProposal.addedSegments
		.. ", removed = " .. #streetProposal.removedSegments
		.. ", drawn = " .. #drawn
		.. ", min radius = " .. string.format("%.1f", drawnRadius))
	if #drawn == 0 then
		return
	end

	-- one command per track, so a track that cannot be built does not take the others with it
	local distance = getTrackDistance(drawn[1].segment.comp.roadTemplate)
	for __, offset in ipairs(geometry.offsets(current.count, current.side, distance)) do
		local proposal, numEdges, minRadius = makeProposal(drawn, offset)
		if numEdges > 0 then
			local label = "track at offset " .. offset .. " (" .. numEdges .. " edges, min radius " .. string.format("%.1f", minRadius) .. ")"
			api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(proposal, nil, false, true), function(res, success)
				shared.log(label .. ": " .. (success and "ok" or "FAILED"))
				if not success then
					local ok, err = pcall(logErrorState, res)
					if not ok then
						shared.log("  no error details: " .. tostring(err))
					end
				end
			end)
		end
	end
end

function data()
return {
	update = function(_userParams, state, _dt)
		ensureSubscriptions(state)
	end,

	handleEvent = function(_userParams, state, _src, _id, _name, _param)
		ensureSubscriptions(state)
	end,

	guiHandleEvent = function(_userParams, _state, _guiState, _src, id, name, param)
		if name == shared.EVENT_SET_PARAMS then
			if param.count ~= current.count or param.side ~= current.side then
				current.count = param.count
				current.side = param.side
				shared.log("params: count = " .. tostring(current.count) .. ", side = " .. tostring(current.side))
			end
		elseif name == "builder.proposalApply" and id == "trackBuilder" then
			if current.count > 1 then
				local ok, err = pcall(buildParallelTracks, param)
				if not ok then
					shared.log("buildParallelTracks failed: " .. tostring(err))
				end
			end
		end
	end,
}
end
