-- Checks a junction's lane connections for the properties the mod's rules promise (see
-- planner.junctionConnections), worked out here independently of the planner:
--   complete: every incoming lane with somewhere to go gets a connection, every
--     outgoing lane that traffic can reach gets one, and every allowed turn exists;
--   allowed:  no U-turns, no turn sharper than MAX_TURN;
--   uncrossed: per incoming road, turns further left use lanes further left.
-- Also how close they come to the road builder's own (shared / all connections).
local check = {}

local MAX_TURN = 135
local ROAD = { [2] = true, [3] = true, [4] = true, [5] = true, [6] = true }

local function lanesAt(e)
	local incoming, outgoing = {}, {}
	local n = #(e.lanes or {})
	for i, lane in ipairs(e.lanes or {}) do
		local drives = false
		for mode, on in pairs(lane.transportModes or {}) do
			if on and ROAD[mode] then
				drives = true
			end
		end
		if drives then
			local frame = e.atStart and (i - 1) or (n - i)
			local coming = (e.atStart and not lane.forward) or (not e.atStart and lane.forward)
			if coming then
				incoming[#incoming + 1] = frame
			else
				outgoing[#outgoing + 1] = frame
			end
		end
	end
	table.sort(incoming, function(a, b) return a > b end) -- left to right
	table.sort(outgoing, function(a, b) return a < b end)
	return incoming, outgoing
end

local function turn(a, b)
	local ax, ay = -a.dir.x, -a.dir.y
	local bx, by = b.dir.x, b.dir.y
	local atan2 = math.atan2 or math.atan
	return math.deg(atan2(ax * by - ay * bx, ax * bx + ay * by))
end

-- connections: plain { segment0, lane0, segment1, lane1 }; native: "s.l->s.l" strings
-- or nil. Returns a list of problems and the share in common with native (or nil).
function check.junction(edges, connections, native)
	local problems = {}
	local byEntity, ins, outs = {}, {}, {}
	for __, e in ipairs(edges) do
		byEntity[e.entity] = e
		ins[e.entity], outs[e.entity] = lanesAt(e)
	end
	local function allowed(a, b)
		return a ~= b and #ins[a.entity] > 0 and #outs[b.entity] > 0 and math.abs(turn(a, b)) <= MAX_TURN
	end
	local from, to, pair = {}, {}, {}
	for __, c in ipairs(connections) do
		local a, b = byEntity[c.segment0], byEntity[c.segment1]
		if a == nil or b == nil then
			problems[#problems + 1] = "connection to an edge not at the node"
		elseif not allowed(a, b) then
			problems[#problems + 1] = string.format("turn %d->%d not allowed (%.0f deg)", c.segment0, c.segment1, turn(a, b))
		end
		from[c.segment0 .. "." .. c.lane0] = true
		to[c.segment1 .. "." .. c.lane1] = true
		pair[c.segment0 .. ">" .. c.segment1] = pair[c.segment0 .. ">" .. c.segment1] or {}
		table.insert(pair[c.segment0 .. ">" .. c.segment1], c.lane0)
	end
	for __, a in ipairs(edges) do
		local exits = {}
		for __, b in ipairs(edges) do
			if allowed(a, b) then
				exits[#exits + 1] = b
				if pair[a.entity .. ">" .. b.entity] == nil then
					problems[#problems + 1] = string.format("no way from %d to %d", a.entity, b.entity)
				end
			end
		end
		if #exits > 0 then
			for __, l in ipairs(ins[a.entity]) do
				if not from[a.entity .. "." .. l] then
					problems[#problems + 1] = string.format("lane %d.%d goes nowhere", a.entity, l)
				end
			end
		end
		-- uncrossed (the user's rule, 2026-10-02): number the destinations left to right,
		-- exits from the leftmost turn to the rightmost and each exit's lanes left to
		-- right; a lane further left may only go to destinations at or before every
		-- destination of a lane further right (meeting where they land is fine)
		table.sort(exits, function(p, q) return turn(a, p) > turn(a, q) end)
		local destination = {}
		local index = 0
		for __, b in ipairs(exits) do
			for __, l in ipairs(outs[b.entity]) do
				index = index + 1
				destination[b.entity .. "." .. l] = index
			end
		end
		local lowest, highest = {}, {}
		for __, c in ipairs(connections) do
			if c.segment0 == a.entity then
				local d = destination[c.segment1 .. "." .. c.lane1]
				if d then
					lowest[c.lane0] = math.min(lowest[c.lane0] or math.huge, d)
					highest[c.lane0] = math.max(highest[c.lane0] or 0, d)
				end
			end
		end
		local lanes = ins[a.entity]
		for i = 1, #lanes do
			for j = i + 1, #lanes do
				local hi, lo = highest[lanes[i]], lowest[lanes[j]]
				if hi and lo and hi > lo then
					problems[#problems + 1] = string.format("lanes %d.%d and %d.%d cross", a.entity, lanes[i], a.entity, lanes[j])
				end
			end
		end
	end
	for __, b in ipairs(edges) do
		local reached = false
		for __, a in ipairs(edges) do
			if allowed(a, b) then
				reached = true
			end
		end
		if reached then
			for __, l in ipairs(outs[b.entity]) do
				if not to[b.entity .. "." .. l] then
					problems[#problems + 1] = string.format("lane %d.%d is never entered", b.entity, l)
				end
			end
		end
	end
	local share = nil
	if native then
		local mine, all, common = {}, {}, 0
		for __, c in ipairs(connections) do
			local key = string.format("%d.%d->%d.%d", c.segment0, c.lane0, c.segment1, c.lane1)
			mine[key] = true
			all[key] = true
		end
		for __, key in ipairs(native) do
			if mine[key] then
				common = common + 1
			end
			all[key] = true
		end
		local count = 0
		for __ in pairs(all) do
			count = count + 1
		end
		share = count > 0 and common / count or 1
	end
	return problems, share
end

return check
