-- Timing of chain.relay for a 6-track bundle crossing a long curved track: every
-- crossing in one chain, nodes every 90 m. Run with any Lua 5.3+:
--   lua-language-server.exe tests/chain_bench.lua
local here = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
package.path = here .. "/../mod/content/gui/parallelism/?.lua;" .. package.path
local geometry = require "parallelism_geometry"
local chain = require "parallelism_chain"

-- an arc of radius 600 through nodes every 90 m
local radius, step, count = 600, 90, 12
local function at(s)
	local a = s / radius
	return { x = radius - radius * math.cos(a), y = radius * math.sin(a), z = 5 }, { x = math.sin(a), y = math.cos(a), z = 0 }
end
local c = { nodes = {}, edges = {} }
for i = 0, count do
	local p = at(i * step)
	c.nodes[#c.nodes + 1] = { id = "n" .. i, position = p }
	if i > 0 then
		local p0, d0 = at((i - 1) * step)
		local p1, d1 = at(i * step)
		c.edges[#c.edges + 1] = { id = "e" .. i, edge = geometry.arcCubic(p0, d0, p1, d1) }
	end
end
local junctions = {}
for k = 0, 5 do
	local s = 400 + k * 12
	-- (the planner always says which edge a junction is on)
	junctions[#junctions + 1] = { id = "J" .. k, position = (at(s)), edge = math.floor(s / step) + 1, keepBefore = 5, keepAfter = 5 }
end

local made = 0
local started = os.clock()
local runs = 20
local result
for __ = 1, runs do
	result = chain.relay(c, junctions, {
		newNode = function()
			made = made + 1
			return "new" .. made
		end,
	})
end
print(string.format("relay: %.1f ms per run (%d pieces, %d nodes removed, %d problems)", (os.clock() - started) * 1000 / runs,
	#result.pieces, #result.removedNodes, #result.problems))
