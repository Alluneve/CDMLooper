local _, private = ...
local Debug = {}
local db
local addonName
local flightRecorder

-- Constructor --

---@param database table
---@param AddonName string
---@param recorder table
function Debug.Initialize(database, AddonName, recorder)
    database.Debug = database.Debug or {}
    db = database.Debug

    if db.DebugPrintSwitch == nil then
        db.DebugPrintSwitch = false
    end

    if db.DebugLogSwitch == nil then
        db.DebugLogSwitch = false
    end

    addonName = AddonName
    flightRecorder = recorder
end

private.Debug = Debug

-- Module Variables --

local debugLog = {}

-- Implementation --

local function DebugPrint(...)
    flightRecorder.Record(...)

    if db.DebugPrintSwitch then
        print(...)
    end
end

local function DebugLog(...)
    if db.DebugLogSwitch then
        table.insert(debugLog, {
            n = select("#", ...),
            ...
        })
    end

    DebugPrint(...)
end

local function SubmitDebugLog()
    local lines = {
        string.format("%s Debug Log", addonName)
    }

    for i, entry in ipairs(debugLog) do
        local values = {}

        for j = 1, entry.n do
            local value = entry[j]

            if issecretvalue and issecretvalue(value) then
                values[j] = "<secret>"
            else
                values[j] = tostring(value)
            end
        end

        table.insert(lines, string.format(
            "[%d] %s",
            i,
            table.concat(values, " ")
        ))
    end

    BugGrabber:StoreError({
        message = table.concat(lines, "\n"),
        session = BugGrabber:GetSessionId(),
        time = date("%Y/%m/%d %H:%M:%S"),
        counter = 1,
    })
end


local function ClearDebugLog()
    wipe(debugLog)
end

local function TogglePrintSwitch()
    db.DebugPrintSwitch = not db.DebugPrintSwitch
    return db.DebugPrintSwitch
end

local function ToggleLogSwitch()
    db.DebugLogSwitch = not db.DebugLogSwitch
    return db.DebugLogSwitch
end

local function GetDebugState()
    return db.DebugPrintSwitch, db.DebugLogSwitch
end

-- Interfaces --

function Debug.Print(...)
    DebugPrint(...)
end

function Debug.Log(...)
    DebugLog(...)
end

function Debug.PrintLog()
    SubmitDebugLog()
end

function Debug.Clear()
    ClearDebugLog()
end

---@return boolean
function Debug.TogglePrint()
    return TogglePrintSwitch()
end

---@return boolean
function Debug.ToggleLog()
    return ToggleLogSwitch()
end

---@return boolean, boolean
function Debug.GetState()
    return GetDebugState()
end
