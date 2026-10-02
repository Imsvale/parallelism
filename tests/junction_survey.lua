-- Survey: the road builder's junctions from the game log (tests/junctions_from_log.py),
-- 2026-10-02 01:11-01:18 UTC. Reported, not counted: see how far the rules reach.
local here = arg and arg[0] and arg[0]:match("(.*)[/\\]") or "."
package.path = here .. "/../content/gui/parallelism/?.lua;" .. package.path
rawset(_G, "api", rawget(_G, "api") or {})
for __, name in ipairs({ "parallelism_shared", "parallelism_geometry" }) do
	package.preload[name .. ".lua"] = function() return require(name) end
end
local planner = require "parallelism_planner"
local matched, total = 0, 0
local function lane(forward, modes) return { forward = forward, transportModes = modes } end
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
	total = total + 1
	if a == b then matched = matched + 1 end
	local gotSet, expSet = {}, {}
	for __, x in ipairs(got) do gotSet[x] = true end
	for __, x in ipairs(expected) do expSet[x] = true end
	local missing, extra = {}, {}
	for __, x in ipairs(expected) do if not gotSet[x] then missing[#missing + 1] = x end end
	for __, x in ipairs(got) do if not expSet[x] then extra[#extra + 1] = x end end
	print((a == b and "same " or "DIFF ") .. name .. string.format("  (%d builder, %d ours)", #expected, #got)
		.. (a == b and "" or ("\n     missing " .. table.concat(missing, " ") .. "\n     extra   " .. table.concat(extra, " "))))
end
-- node 640 (01:11:08)
compare("node 640 (01:11:08)", {
	edge(896, true, -13.45, 75.28, { lane(false, {}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {}) }), -- highway_new_large.street_template
	edge(917, false, 23.18, -129.79, { lane(false, {}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {}) }), -- highway_new_large.street_template
	edge(919, false, 49.80, -123.06, { lane(false, {}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {}) }), -- highway_new_small.street_template
}, { "917.1->896.3", "917.2->896.2", "917.3->896.1", "919.1->896.3" })

-- node 323 (01:11:30)
compare("node 323 (01:11:30)", {
	edge(819, true, -4.95, 27.73, { lane(false, {}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {}) }), -- highway_new_large.street_template
	edge(923, false, 27.88, -156.08, { lane(false, {}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {}) }), -- highway_new_small.street_template
	edge(845, false, 31.67, -177.33, { lane(false, {}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {}) }), -- highway_new_large.street_template
}, { "845.1->819.3", "845.2->819.2", "845.3->819.1", "923.1->819.3" })

-- node 500 (01:13:00)
compare("node 500 (01:13:00)", {
	edge(874, false, 15.42, -86.34, { lane(false, {}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {}) }), -- highway_new_small.street_template
	edge(492, false, 25.15, -140.82, { lane(false, {}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {}) }), -- highway_new_large.street_template
	edge(326, true, -3.18, 17.83, { lane(false, {}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {}) }), -- highway_new_large.street_template
}, { "874.1->326.1", "492.1->326.3", "492.2->326.2", "492.3->326.1" })

-- node 900 (01:13:00)
compare("node 900 (01:13:00)", {
	edge(904, true, -46.45, -106.33, { lane(false, {}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {}) }), -- highway_new_large.street_template
	edge(905, false, 12.53, -70.15, { lane(false, {}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {}) }), -- highway_new_large.street_template
	edge(492, true, -25.15, 140.82, { lane(false, {}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {}) }), -- highway_new_large.street_template
	edge(903, false, 31.45, 71.99, { lane(false, {}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {}) }), -- highway_new_large.street_template
}, { "903.1->904.3", "903.2->904.2", "903.3->904.1", "905.1->904.3", "905.2->904.2", "905.3->904.1", "905.1->492.3", "905.2->492.1", "905.2->492.2", "903.1->492.2", "903.1->492.3", "903.2->492.1" })

-- node 844 (01:13:14)
compare("node 844 (01:13:14)", {
	edge(944, false, 14.05, -78.67, { lane(false, {}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {}) }), -- highway_new_large.street_template
	edge(945, true, -9.66, 54.09, { lane(false, {}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {}) }), -- highway_new_large.street_template
	edge(943, false, 14.76, -82.65, { lane(false, {}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {}) }), -- highway_new_small.street_template
}, { "943.1->945.1", "944.1->945.3", "944.2->945.2", "944.3->945.1" })

-- node 940 (01:16:29)
compare("node 940 (01:16:29)", {
	edge(992, false, -34.09, -49.22, { lane(false, {[1] = true, [0] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[1] = true, [0] = true}) }), -- town_new_small.street_template
	edge(987, false, 33.16, -22.37, { lane(false, {[1] = true, [0] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[1] = true, [0] = true}) }), -- country_new_large_barriers.street_template
	edge(988, true, -46.08, 31.08, { lane(false, {[1] = true, [0] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[1] = true, [0] = true}) }), -- country_new_large_barriers.street_template
	edge(990, true, 31.71, 45.78, { lane(false, {[1] = true, [0] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[1] = true, [0] = true}) }), -- town_new_small.street_template
}, { "987.1->988.6", "987.2->988.5", "987.3->988.4", "988.1->987.6", "988.2->987.5", "988.3->987.4", "992.1->987.4", "992.1->987.5", "992.1->987.6", "992.1->988.4", "992.1->988.5", "992.1->988.6", "987.3->992.2", "988.1->992.2", "992.1->990.2", "987.1->990.2", "990.1->992.2", "990.1->987.4", "990.1->987.5", "990.1->987.6", "990.1->988.4", "990.1->988.5", "990.1->988.6", "988.3->990.2" })

-- node 434 (01:16:48)
compare("node 434 (01:16:48)", {
	edge(1019, false, -51.09, -80.87, { lane(false, {[1] = true, [0] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[1] = true, [0] = true}) }), -- country_new_large_barriers.street_template
	edge(1020, true, 39.17, 62.00, { lane(false, {[1] = true, [0] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[1] = true, [0] = true}) }), -- country_new_large_barriers.street_template
	edge(1022, false, -68.42, 42.95, { lane(false, {[1] = true, [0] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[1] = true, [0] = true}) }), -- country_new_large_barriers.street_template
	edge(1023, true, 75.26, -47.25, { lane(false, {[1] = true, [0] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[1] = true, [0] = true}) }), -- country_new_large_barriers.street_template
}, { "1019.1->1020.6", "1019.2->1020.5", "1019.3->1020.4", "1020.1->1019.6", "1020.2->1019.5", "1020.3->1019.4", "1019.2->1022.6", "1019.3->1022.4", "1019.3->1022.5", "1020.1->1022.5", "1020.1->1022.6", "1020.2->1022.4", "1022.1->1019.5", "1022.1->1019.6", "1022.2->1019.4", "1022.2->1020.6", "1022.3->1020.4", "1022.3->1020.5", "1019.1->1023.4", "1019.1->1023.5", "1019.1->1023.6", "1023.3->1019.4", "1023.3->1019.5", "1023.3->1019.6", "1023.1->1020.4", "1023.1->1020.5", "1023.1->1020.6", "1023.1->1022.6", "1023.2->1022.5", "1023.3->1022.4", "1020.3->1023.4", "1020.3->1023.5", "1020.3->1023.6", "1022.1->1023.6", "1022.2->1023.5", "1022.3->1023.4" })

-- node 565 (01:17:15)
compare("node 565 (01:17:15)", {
	edge(1049, false, -16.38, -29.66, { lane(false, {[1] = true, [0] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[1] = true, [0] = true}) }), -- country_new_large_barriers.street_template
	edge(1050, true, 28.91, 52.33, { lane(false, {[1] = true, [0] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[1] = true, [0] = true}) }), -- country_new_large_barriers.street_template
	edge(1047, true, 45.97, -25.39, { lane(false, {[1] = true, [0] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[1] = true, [0] = true}) }), -- town_new_small.street_template
}, { "1049.1->1047.2", "1049.2->1047.2", "1049.3->1047.2", "1047.1->1049.4", "1047.1->1049.5", "1047.1->1049.6", "1049.1->1050.6", "1049.2->1050.5", "1049.3->1050.4", "1047.1->1050.4", "1047.1->1050.5", "1047.1->1050.6", "1050.1->1049.6", "1050.2->1049.5", "1050.3->1049.4", "1050.3->1047.2" })

-- node 468 (01:17:19)
compare("node 468 (01:17:19)", {
	edge(1056, true, 24.57, 44.48, { lane(false, {[1] = true, [0] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[1] = true, [0] = true}) }), -- country_new_large_barriers.street_template
	edge(467, false, 51.35, -27.88, { lane(false, {[1] = true, [0] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[1] = true, [0] = true}) }), -- town_new_small.street_template
	edge(1055, false, -20.72, -37.50, { lane(false, {[1] = true, [0] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[1] = true, [0] = true}) }), -- country_new_large_barriers.street_template
}, { "1055.1->467.2", "1055.2->467.2", "1055.3->467.2", "467.1->1055.4", "467.1->1055.5", "467.1->1055.6", "1055.1->1056.6", "1055.2->1056.5", "1055.3->1056.4", "467.1->1056.4", "467.1->1056.5", "467.1->1056.6", "1056.1->1055.6", "1056.2->1055.5", "1056.3->1055.4", "1056.3->467.2" })

-- node 978 (01:17:46)
compare("node 978 (01:17:46)", {
	edge(1072, true, -26.97, -50.13, { lane(false, {[1] = true, [0] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[1] = true, [0] = true}) }), -- town_new_small.street_template
	edge(1074, false, 32.40, 60.24, { lane(false, {[1] = true, [0] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[1] = true, [0] = true}) }), -- town_new_small.street_template
	edge(427, true, -56.94, 30.63, { lane(false, {[1] = true, [0] = true}), lane(false, {[3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[3] = true, [4] = true}), lane(true, {[1] = true, [0] = true}) }), -- country_new_large_bus.street_template
}, { "1074.1->427.4", "1074.1->427.5", "1074.1->427.6", "427.1->1074.2", "427.2->1074.2", "427.3->1074.2", "1072.1->1074.2", "1072.1->427.4", "1072.1->427.5", "1072.1->427.6", "1074.1->1072.2", "427.1->1072.2", "427.2->1072.2" })

-- node 438 (01:17:50)
compare("node 438 (01:17:50)", {
	edge(1082, false, -54.89, 28.99, { lane(false, {[1] = true, [0] = true}), lane(false, {[3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[3] = true, [4] = true}), lane(true, {[1] = true, [0] = true}) }), -- country_new_large_bus.street_template
	edge(1083, false, 26.49, 49.25, { lane(false, {[1] = true, [0] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[1] = true, [0] = true}) }), -- town_new_small.street_template
	edge(1084, true, -32.64, -60.68, { lane(false, {[1] = true, [0] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[1] = true, [0] = true}) }), -- town_new_small.street_template
}, { "1083.1->1082.4", "1083.1->1082.5", "1083.1->1082.6", "1082.1->1083.2", "1082.2->1083.2", "1082.3->1083.2", "1084.1->1083.2", "1084.1->1082.4", "1084.1->1082.5", "1084.1->1082.6", "1083.1->1084.2", "1082.1->1084.2", "1082.2->1084.2" })

-- node 1108 (01:18:13)
compare("node 1108 (01:18:13)", {
	edge(1114, true, 103.60, -45.02, { lane(false, {[1] = true, [0] = true}), lane(false, {[3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[3] = true, [4] = true}), lane(true, {[1] = true, [0] = true}) }), -- country_new_large_bus.street_template
	edge(1116, false, -94.69, 41.15, { lane(false, {[1] = true, [0] = true}), lane(false, {[3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[3] = true, [4] = true}), lane(true, {[1] = true, [0] = true}) }), -- country_new_large_bus.street_template
	edge(1117, true, -88.85, 82.51, { lane(false, {}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {}) }), -- highway_new_large.street_template
	edge(1118, false, 90.24, -83.81, { lane(false, {}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {}) }), -- highway_new_large.street_template
}, { "1118.1->1117.3", "1118.2->1117.2", "1118.3->1117.1", "1118.2->1116.6", "1118.3->1116.4", "1118.3->1116.5", "1116.1->1117.1", "1116.1->1117.2", "1116.1->1117.3", "1116.2->1117.2", "1116.2->1117.3", "1116.3->1117.1", "1118.1->1114.4", "1118.1->1114.5", "1118.1->1114.6", "1114.1->1117.1", "1114.1->1117.2", "1114.1->1117.3", "1114.2->1117.1", "1114.2->1117.2", "1114.2->1117.3", "1114.1->1116.4", "1114.1->1116.5", "1114.1->1116.6", "1114.3->1116.4", "1114.3->1116.5", "1114.3->1116.6", "1116.1->1114.4", "1116.1->1114.5", "1116.1->1114.6", "1116.2->1114.5", "1116.2->1114.6", "1116.3->1114.4" })

-- node 499 (01:18:21)
compare("node 499 (01:18:21)", {
	edge(820, true, 69.45, -30.18, { lane(false, {[1] = true, [0] = true}), lane(false, {[3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[3] = true, [4] = true}), lane(true, {[1] = true, [0] = true}) }), -- country_new_large_bus.street_template
	edge(694, true, -28.90, -66.50, { lane(false, {}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {}) }), -- highway_new_medium.street_template
	edge(319, false, -47.68, 20.72, { lane(false, {[1] = true, [0] = true}), lane(false, {[3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(false, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[2] = true, [3] = true, [4] = true}), lane(true, {[3] = true, [4] = true}), lane(true, {[1] = true, [0] = true}) }), -- country_new_large_bus.street_template
}, { "319.1->694.2", "319.2->694.2", "319.3->694.1", "820.1->694.1", "820.1->694.2", "820.3->694.1", "820.3->694.2", "820.1->319.4", "820.1->319.5", "820.1->319.6", "820.2->319.5", "820.2->319.6", "820.3->319.4", "319.1->820.4", "319.1->820.5", "319.1->820.6", "319.2->820.5", "319.2->820.6", "319.3->820.4" })

print(matched .. " of " .. total .. " the same")

