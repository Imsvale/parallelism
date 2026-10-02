-- Offline test of planner.junctionConnections against the road builder's own junction
-- configs (docs/studies/2026-10-02_native-junctions.md). Run with any Lua 5.3+:
--   lua-language-server.exe tests/junction_test.lua
local here = arg and arg[0] and arg[0]:match("(.*)[/\\]") or "."
package.path = here .. "/../content/gui/parallelism/?.lua;" .. package.path
-- the planner logs through the game; outside it nothing is needed at load
rawset(_G, "api", rawget(_G, "api") or {})
-- in game modules are required with their extension ("parallelism_shared.lua")
for __, name in ipairs({ "parallelism_shared", "parallelism_geometry" }) do
	package.preload[name .. ".lua"] = function()
		return require(name)
	end
end
local planner = require "parallelism_planner"

local failures = 0
local function check(name, ok, detail)
	print((ok and "ok   " or "FAIL ") .. name .. (detail and ("  " .. detail) or ""))
	if not ok then
		failures = failures + 1
	end
end

local SIDEWALK = { [0] = true, [1] = true }
local CAR = { [2] = true, [3] = true, [4] = true }
local function lane(forward, modes)
	return { forward = forward, transportModes = modes }
end
local TWO_WAY = { lane(false, SIDEWALK), lane(false, CAR), lane(true, CAR), lane(true, SIDEWALK) }
local ONE_WAY = { lane(false, SIDEWALK), lane(true, CAR), lane(true, CAR), lane(true, SIDEWALK) }

local function edge(entity, atStart, dx, dy, lanes)
	return { entity = entity, atStart = atStart, dir = { x = dx, y = dy, z = 0 }, lanes = lanes }
end

local function compare(name, edges, expected)
	local got = {}
	for __, c in ipairs(planner.junctionConnections(edges)) do
		got[#got + 1] = string.format("%d.%d->%d.%d", c.segment0, c.lane0, c.segment1, c.lane1)
	end
	table.sort(got)
	table.sort(expected)
	local a, b = table.concat(got, " "), table.concat(expected, " ")
	check(name, a == b, a == b and (#got .. " connections") or ("\n     got      " .. a .. "\n     expected " .. b))
end

-- (1) two-way across two-way, node 372
compare("4-way, two-way roads", {
	edge(533, false, 86.03, 1.26, TWO_WAY),   -- 410 -> 372, ends here, leaves east
	edge(444, true, -100.24, -1.47, TWO_WAY), -- 372 -> 361, leaves west
	edge(418, false, 1.19, -50.77, TWO_WAY),  -- 269 -> 372, leaves south
	edge(737, true, -2.14, 91.61, TWO_WAY),   -- 372 -> 604, leaves north
}, { "444.1->533.2", "533.1->444.2", "444.1->418.2", "418.1->444.2", "418.1->533.2", "533.1->418.2",
	"444.1->737.2", "418.1->737.2", "533.1->737.2", "737.1->444.2", "737.1->418.2", "737.1->533.2" })

-- (2) T-junction, node 594
compare("T-junction, two-way roads", {
	edge(565, false, 0.67, -28.87, TWO_WAY), -- 560 -> 594, leaves south
	edge(758, true, -1.70, 72.67, TWO_WAY),  -- 594 -> 372, leaves north
	edge(350, true, 73.91, 1.73, TWO_WAY),   -- 594 -> 573, leaves east
}, { "565.1->350.2", "350.1->565.2", "565.1->758.2", "350.1->758.2", "758.1->565.2", "758.1->350.2" })

-- (3) one-way across two-way, node 749
compare("one-way across two-way", {
	edge(765, false, 80.06, 1.26, ONE_WAY),    -- 472 -> 749, comes from the east
	edge(766, true, -92.51, -1.46, ONE_WAY),   -- 749 -> 562, leaves west
	edge(767, false, 1.72, -73.80, TWO_WAY),   -- 372 -> 749, leaves south
	edge(768, true, -1.34, 57.19, TWO_WAY),    -- 749 -> 764, leaves north
}, { "765.1->766.2", "765.2->766.1", "767.1->766.1", "767.1->766.2", "765.2->767.2", "767.1->768.2",
	"765.1->768.2", "768.1->766.1", "768.1->766.2", "768.1->767.2" })

-- (4) one-way across one-way, node 344
compare("one-way across one-way", {
	edge(539, false, 1.55, -37.00, ONE_WAY),  -- 272 -> 344, comes from the south
	edge(670, false, 69.67, 1.10, ONE_WAY),   -- 749 -> 344, comes from the east
	edge(552, true, -22.82, -0.36, ONE_WAY),  -- 344 -> 562, leaves west
	edge(774, true, -3.01, 71.78, ONE_WAY),   -- 344 -> 547, leaves north
}, { "539.1->774.2", "539.2->774.1", "670.1->774.2", "670.2->774.1", "539.2->552.1", "539.2->552.2",
	"670.1->552.2", "670.2->552.1" })

-- highways (2026-10-02 00:54-00:55): three lanes one way, shoulders with no modes
local SHOULDER = {}
local HIGHWAY = { lane(false, SHOULDER), lane(true, CAR), lane(true, CAR), lane(true, CAR), lane(true, SHOULDER) }

-- (5) highway carriageway across a two-way road, node 431
compare("highway across two-way", {
	edge(731, false, 76.81, -2.75, HIGHWAY),  -- 433 -> 431, comes from the east
	edge(776, true, -96.59, 3.46, HIGHWAY),   -- 431 -> 339, leaves west
	edge(777, true, 1.48, 78.47, TWO_WAY),    -- 431 -> 375, leaves north
	edge(778, false, -1.81, -95.94, TWO_WAY), -- 605 -> 431, leaves south
}, { "731.1->776.3", "731.2->776.2", "731.3->776.1", "778.1->776.1", "778.1->776.2", "778.1->776.3", "731.3->778.2",
	"778.1->777.2", "731.1->777.2", "777.1->778.2", "777.1->776.1", "777.1->776.2", "777.1->776.3" })

-- (6) highway carriageway starting at a two-way road, node 512
compare("highway leaving a two-way road (T)", {
	edge(796, false, -1.00, -53.15, TWO_WAY), -- 517 -> 512, leaves south
	edge(486, true, 1.07, 56.66, TWO_WAY),    -- 512 -> 790, leaves north
	edge(411, true, 63.80, -1.20, HIGHWAY),   -- 512 -> 523, leaves east
}, { "796.1->411.1", "796.1->411.2", "796.1->411.3", "796.1->486.2", "486.1->796.2", "486.1->411.1",
	"486.1->411.2", "486.1->411.3" })

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
