-- Dev aid: logs the edges and nodes around a point with all their components, to compare
-- what the game's builder makes with what the mod makes (e.g. a road pair built by hand
-- and one built by the mod). Self-contained, so the console can load it:
--   require("imsvale_parallelism::/gui/parallelism/parallelism_dump.lua").around()
-- around the mouse, or .around(radius) / .around(radius, x, y). The mod also calls it
-- when a drag starts at an existing node.

local dump = {}

-- to the game log, and to the console when called from there
local function logLine(msg)
	local line = "[parallelism] " .. tostring(msg)
	pcall(function()
		log.message(line)
	end)
	if dump.toConsole then
		print(line)
	end
end

local shared = { log = logLine }

local function try(fn)
	local ok, result = pcall(fn)
	if ok then
		return result
	end
	return "<" .. tostring(result) .. ">"
end

local function vec(v)
	if v == nil then
		return "nil"
	end
	return string.format("(%.2f, %.2f, %.2f)", v.x, v.y, v.z)
end

local function box(b)
	return try(function()
		return vec(b.min) .. " .. " .. vec(b.max)
	end)
end

local function laneConfigs(list)
	return try(function()
		local parts = {}
		for i, lc in ipairs(list) do
			local modes = {}
			pcall(function()
				for mode, on in pairs(lc.transportModes) do
					if on then
						modes[#modes + 1] = tostring(mode)
					end
				end
			end)
			parts[#parts + 1] = string.format("%d: %s w %.2f off %.2f h %.2f v %.2f modes {%s}", i,
				lc.forward and "fwd" or "back", lc.width or 0, lc.offset or 0, lc.height or 0, lc.speed or 0,
				table.concat(modes, ","))
		end
		return #parts .. " [" .. table.concat(parts, "; ") .. "]"
	end)
end

local function getComp(entity, name)
	return try(function()
		return api.engine.getComponent(entity, api.type.ComponentType[name])
	end)
end

local function dumpEdge(entity, log)
	local e = getComp(entity, "BASE_EDGE")
	if type(e) ~= "userdata" and type(e) ~= "table" then
		return
	end
	log(string.format("edge %d: nodes %s -> %s", entity, tostring(e.node0), tostring(e.node1)))
	log("  p " .. vec(e.position0) .. " -> " .. vec(e.position1) .. ", t " .. vec(e.tangent0) .. " -> " .. vec(e.tangent1))
	log("  type " .. tostring(e.type) .. "/" .. tostring(e.typeIndex) .. ", roadType " .. tostring(e.roadType)
		.. ", distance " .. tostring(try(function() return e.distance end))
		.. ", devLocked " .. tostring(try(function() return e.roadDevelopmentLocked end)))
	log("  template " .. tostring(e.roadTemplate) .. ", style " .. tostring(e.roadStyle))
	log("  laneConfigs " .. laneConfigs(e.laneConfigs))
	log("  edgeDecorations " .. tostring(try(function()
		local parts = {}
		for _, d in ipairs(e.edgeDecorations) do
			parts[#parts + 1] = tostring(d[1]) .. "/" .. tostring(d[2])
		end
		return #parts .. " [" .. table.concat(parts, ", ") .. "]"
	end)))
	log("  objects " .. tostring(try(function() return #e.objects end)))
	local street = getComp(entity, "BASE_EDGE_STREET")
	log("  street: " .. tostring(try(function()
		return "precedence " .. tostring(street.precedenceNode0) .. " / " .. tostring(street.precedenceNode1)
	end)))
	local owned = getComp(entity, "PLAYER_OWNED")
	log("  owner: " .. tostring(try(function() return owned.player end)))
	local bv = getComp(entity, "BOUNDING_VOLUME")
	log("  bbox: " .. tostring(try(function() return box(bv.bbox) end)))
	local tn = getComp(entity, "TRANSPORT_NETWORK")
	log("  transport network: " .. tostring(try(function()
		return #tn.nodes .. " nodes, " .. #tn.edges .. " edges, " .. #tn.turnaroundEdges .. " turnaround edges"
	end)))
end

local function dumpNode(entity, node2segments, log)
	local n = getComp(entity, "BASE_NODE")
	if type(n) ~= "userdata" and type(n) ~= "table" then
		return
	end
	local segments = node2segments[entity]
	log(string.format("node %d: %s, edges %s", entity, vec(n.position),
		tostring(try(function()
			local list = {}
			for _, s in ipairs(segments) do
				list[#list + 1] = tostring(s)
			end
			return table.concat(list, ", ")
		end))))
	local config = getComp(entity, "BASE_NODE_CONFIG")
	log("  config: " .. tostring(try(function()
		local parts = {}
		for _, c in ipairs(config.laneConnections) do
			parts[#parts + 1] = string.format("%s.%s->%s.%s%s%s", tostring(c.segment0), tostring(c.lane0), tostring(c.segment1), tostring(c.lane1),
				c.withRoad and " road" or "", c.withTram and " tram" or "")
		end
		local crosswalks = {}
		for _, e in ipairs(config.crosswalks) do
			crosswalks[#crosswalks + 1] = tostring(e)
		end
		return #parts .. " lane connections [" .. table.concat(parts, ", ") .. "], crosswalks ["
			.. table.concat(crosswalks, ", ") .. "], trafficLightPreference " .. tostring(config.trafficLightPreference)
			.. ", doubleSlip " .. tostring(config.doubleSlipSwitch)
			.. ", userModified " .. tostring(config.userModifiedLaneConnections)
	end)))
	local bv = getComp(entity, "BOUNDING_VOLUME")
	log("  bbox: " .. tostring(try(function() return box(bv.bbox) end)))
end

-- Logs every edge and node within radius (default 30 m) of (x, y), or of the terrain
-- under the mouse.
function dump.around(radius, x, y)
	radius = radius or 30
	if x == nil then
		-- no position given: called by hand, so answer in the console too
		dump.toConsole = true
		local p = api.gui.mouse.getTerrainPosition()
		x, y = p.x, p.y
	end
	local log = shared.log
	local center = api.type.Vec2f.new(x, y)
	log(string.format("dump around (%.1f, %.1f), radius %.0f m", x, y, radius))
	local node2segments = api.engine.system.streetSystem.getNode2SegmentMap()
	local edges = api.engine.util.octree.findEntitiesInCircle(center, radius, api.type.ComponentType.BASE_EDGE)
	table.sort(edges)
	for _, entity in ipairs(edges) do
		dumpEdge(entity, log)
	end
	local nodes = api.engine.util.octree.findEntitiesInCircle(center, radius, api.type.ComponentType.BASE_NODE)
	table.sort(nodes)
	for _, entity in ipairs(nodes) do
		dumpNode(entity, node2segments, log)
	end
	log("dump done: " .. #edges .. " edges, " .. #nodes .. " nodes")
	dump.toConsole = false
end

-- makes parallelismDump available to the console of the lua state this is loaded on
function dump.install()
	-- rawset: the game logs an error for globals made by assignment (base/init.lua);
	-- this one is meant, for the console
	rawset(_G, "parallelismDump", function(...)
		local ok, err = pcall(dump.around, ...)
		if not ok then
			shared.log("dump failed: " .. tostring(err))
		end
	end)
end

return dump
