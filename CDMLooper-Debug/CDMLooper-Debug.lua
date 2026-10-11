local ADDON_NAME, private = ...

local Debug = private.Debug
local FlightRecorder = private.FlightRecorder
local CORE_ADDON_NAME = C_AddOns.GetAddOnMetadata(ADDON_NAME, "X-CoreAddon")

-- Keep internal modules private to the orchestrator
private.Debug = nil
private.FlightRecorder = nil

-- Business Logic --

local function OnBugGrabbed(_, errorID)
    local errorObject = BugGrabber:GetErrorByID(errorID)

    if not errorObject then
        return
    end

    local message = errorObject.message

    if type(message) ~= "string" then
        return
    end

    if issecretvalue and issecretvalue(message) then
        return
    end

    if string.find(message, CORE_ADDON_NAME, 1, true)
        or string.find(message, ADDON_NAME, 1, true) then
        FlightRecorder.Trigger()
    end
end

local function OnCombatStart()
    FlightRecorder.setEnabled(true)
end

local function OnCombatEnd()
    FlightRecorder.setEnabled(false)
    FlightRecorder.Clear()
end

local function Initialize()
    LooperDebugDB = LooperDebugDB or {}

    FlightRecorder.Initialize(LooperDebugDB, ADDON_NAME)
    Debug.Initialize(LooperDebugDB, ADDON_NAME, FlightRecorder)

    EventRegistry:RegisterCallback(
        "BugGrabber.BugGrabbed",
        OnBugGrabbed
    )
end

-- Event Handling --

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...

        if loadedAddon ~= ADDON_NAME then
            return
        end

        Initialize()

        self:UnregisterEvent("ADDON_LOADED")
        self:RegisterEvent("PLAYER_REGEN_DISABLED")
        self:RegisterEvent("PLAYER_REGEN_ENABLED")

        if UnitAffectingCombat("player") then
            OnCombatStart()
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        OnCombatStart()
    elseif event == "PLAYER_REGEN_ENABLED" then
        OnCombatEnd()
    end
end)

-- Public Interfaces --

local API = {}

function API.Print(...)
    Debug.Print(...)
end

function API.Log(...)
    Debug.Log(...)
end

function API.SubmitLog()
    Debug.PrintLog()
end

-- Other public methods...

private.API = API
