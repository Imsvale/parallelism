-- The railroad crossing types as the game has them loaded: their fields, their config (the
-- sign and barrier models by street width) and those models' bounding boxes. For working out
-- how much room a level crossing takes along a road (the barrier models set it).
-- Read only, changes nothing. Paste into the in-game console (it has no dofile); the
-- output goes to the game log (stdout.txt), lines starting with "RCRTYPES".
local function p(msg)
	print("RCRTYPES " .. tostring(msg))
end

local function box(path)
	local text = "?"
	pcall(function()
		local id = api.res.modelRep.find(path)
		local m = api.res.modelRep.get(id)
		local bi = m.boundingInfo
		text = string.format("model %s (id %s): bbMin (%.3f, %.3f, %.3f) bbMax (%.3f, %.3f, %.3f)", path, tostring(id),
			bi.bbMin.x, bi.bbMin.y, bi.bbMin.z, bi.bbMax.x, bi.bbMax.y, bi.bbMax.z)
	end)
	return text
end

local ok, err = pcall(function()
	local all = api.res.railroadCrossingTypeRep.getAll()
	for id, name in pairs(all) do
		local okType, errType = pcall(function()
			local t = api.res.railroadCrossingTypeRep.get(id)
			p(string.format("type %s %s: visible %s", tostring(id), tostring(name), tostring(api.res.railroadCrossingTypeRep.isVisible(id))))
			-- the whole object, as the console's echo would dump it
			for _, k in ipairs({ "availability", "speedLimit", "cost", "trafficDelay", "categoryList", "description" }) do
				pcall(function()
					p("  " .. k .. " = " .. tostring(t[k]))
				end)
			end
			pcall(function()
				p("  availability yearFrom " .. tostring(t.availability.yearFrom) .. " yearTo " .. tostring(t.availability.yearTo))
			end)
			pcall(function()
				for i, c in ipairs(t.config) do
					p(string.format("  config %d: streetWidth %s, left %s, right %s", i, tostring(c.streetWidth), tostring(c.modelLeft),
						tostring(c.modelRight)))
					for _, path in ipairs({ c.modelLeft, c.modelRight }) do
						if path and path ~= "" then
							p("    " .. box(path))
						end
					end
				end
			end)
		end)
		if not okType then
			p("type " .. tostring(id) .. " failed: " .. tostring(errType))
		end
	end
end)
if not ok then
	p("failed: " .. tostring(err))
end
-- the climate of the current game, for which types apply
pcall(function()
	p("climate " .. tostring(api.res.getBaseConfig and api.res.getBaseConfig().climate))
end)
