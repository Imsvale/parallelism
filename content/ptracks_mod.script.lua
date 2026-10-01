-- Load-time part of the mod (mod.json runScript). Experiment: override the curve radius
-- limits of all track types from the mod settings. The game reads them from each
-- .street_template.lua: minCurveRadiusBuild when dragging, minCurveRadius when snapping
-- to or along existing track (wiki, tracks and streets). 0 in a setting keeps the
-- template's own value.

local function runFn(_captureParams, _settings, allModParams)
	local params = allModParams and allModParams[getCurrentModId()] or {}
	local minRadius = tonumber(params.trackMinCurveRadius) or 0
	local minRadiusBuild = tonumber(params.trackMinCurveRadiusBuild) or 0
	if minRadius <= 0 and minRadiusBuild <= 0 then
		return
	end
	local logged = false
	addModifier("loadStreetTemplate", function(fileName, data)
		if data and data.roadType == "TRACK" then
			if minRadius > 0 then
				data.minCurveRadius = minRadius
			end
			if minRadiusBuild > 0 then
				data.minCurveRadiusBuild = minRadiusBuild
			end
			if not logged then
				logged = true
				pcall(function()
					print(string.format("[ptracks] track curve radius overrides: minCurveRadius %s, minCurveRadiusBuild %s (first: %s)",
						tostring(data.minCurveRadius), tostring(data.minCurveRadiusBuild), tostring(fileName)))
				end)
			end
		end
		return data
	end)
end

function data()
	return {
		runFn = runFn,
	}
end
