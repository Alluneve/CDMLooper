local _, private = ...
local FlightRecorder = {}
local db
local addonName

-- Constructor--

---@param database table
---@param AddonName string
function FlightRecorder.Initialize(database, AddonName)
    database.FlightRecorder = database.FlightRecorder or {}
    db = database.FlightRecorder
    db.CaptureSeconds = db.CaptureSeconds or 60
    db.PostTriggerSeconds = db.PostTriggerSeconds or 10
    addonName = AddonName
end

private.FlightRecorder = FlightRecorder

-- Module Variables --

local currentFlightRecorder = {}

local flightRecorderTriggered = false
local flightRecorderTriggeredTime = nil
local cleanupTicker
local postTriggerTimer
local cleanupEnabled = false

-- Implementation --

local function CleanCurrentFlightRecorder()
    if flightRecorderTriggered then
        return
    end

    local cutoff = GetTimePreciseSec() - db.CaptureSeconds

    while currentFlightRecorder[1]
        and currentFlightRecorder[1].timestamp < cutoff
    do
        table.remove(currentFlightRecorder, 1)
    end
end

local function StartCleanupTicker()
    if not cleanupEnabled or cleanupTicker or flightRecorderTriggered then
        return
    end

    CleanCurrentFlightRecorder()

    cleanupTicker = C_Timer.NewTicker(
        db.CaptureSeconds,
        CleanCurrentFlightRecorder
    )
end

local function RecordFlightEvent(...)
    table.insert(currentFlightRecorder, {
        timestamp = GetTimePreciseSec(),
        n = select("#", ...),
        ...
    })
end

local function SubmitFlightRecorder()
    local lines = {
        string.format(
            "%s Flight Recorder - triggered at %.3f",
            addonName,
            flightRecorderTriggeredTime
        )
    }

    for i, entry in ipairs(currentFlightRecorder) do
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
            "%.3f [%d] %s",
            entry.timestamp,
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


local function TriggerFlightRecorder()
    if not flightRecorderTriggered then
        flightRecorderTriggered = true
        flightRecorderTriggeredTime = GetTimePreciseSec()

        -- Suspend rolling cleanup during post-recording.
        if cleanupTicker then
            cleanupTicker:Cancel()
            cleanupTicker = nil
        end
    end

    -- Every trigger restarts the post-recording window.
    if postTriggerTimer then
        postTriggerTimer:Cancel()
    end

    postTriggerTimer = C_Timer.NewTimer(db.PostTriggerSeconds, function()
        postTriggerTimer = nil

        SubmitFlightRecorder()

        currentFlightRecorder = {}
        flightRecorderTriggered = false
        flightRecorderTriggeredTime = nil

        -- Resume cleanup only when still requested.
        if cleanupEnabled then
            StartCleanupTicker()
        end
    end)
end

---@param enabled boolean
local function setEnabled(enabled)
    cleanupEnabled = enabled

    if cleanupEnabled then
        StartCleanupTicker()
    elseif cleanupTicker then
        cleanupTicker:Cancel()
        cleanupTicker = nil
    end
end

local function Clear()
    if postTriggerTimer then
        return
    end
    wipe(currentFlightRecorder)
end

-- Interfaces --

function FlightRecorder.Record(...)
    RecordFlightEvent(...)
end

function FlightRecorder.Trigger()
    TriggerFlightRecorder()
end

---@param enabled boolean
function FlightRecorder.setEnabled(enabled)
    setEnabled(enabled)
end

function FlightRecorder.Clear()
    Clear()
end
