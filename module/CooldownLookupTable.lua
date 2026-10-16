local _, private = ...
local CooldownLookupTable = {}

local STATIC_LOOKUP_TABLE = {
    [33763] = { 1227806 }, -- Lifebloom
}

private.CooldownLookupTableHandler = CooldownLookupTable

local debug
local reverseLookup = {}

---@param params {debugInterface: table }
function CooldownLookupTable.Initialize(params)
    debug = params.debugInterface

    for mainId, altIDs in pairs(STATIC_LOOKUP_TABLE) do
        for _, altID in ipairs(altIDs) do
            reverseLookup[altID] = mainId
        end
    end
end

---@param id number
---@return number?
function CooldownLookupTable.fetch(id)
    local mainID = reverseLookup[id]
    if mainID then
        debug.Info("CooldownLookupTableHandler", "Resolved:", id, "->", mainID)
    end
    return mainID
end