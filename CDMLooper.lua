local ADDON_NAME = "CDMLooper"

--AlertEventType.Available
--AlertEventType.PandemicTime
--AlertEventType.OnCooldown
--AlertEventType.ChargeGained
--AlertEventType.OnAuraApplied
--AlertEventType.OnAuraRemoved

local BLIZZ_ALERT_EVENT_TYPE = Enum.CooldownViewerAlertEventType

local db
local DB_VERSION = 1

local DEFAULT_LOOP_INTERVAL = 3

local activeLoops = {}

local activeLoopPlaybackType = nil
local activeLoopSoundHandle = nil
local activeLoopPlaybackSpellID = nil
local activeLoopTTSUtteranceID = nil
local waitingForLoopTTSRequest = false

local pendingLoopAlerts = {}
local queuedLoopAlerts = {}

local raceConditionCleanupTicker
local raceConditionList = {}
local RACE_CONDITION_TIMER = 0.30

-- UI
local looperSettingsBlock
local looperSettingsCollapsed = false
local alertLoopingCheckBox
local alertIntervalSlider

local currentEditCooldownID
local currentOriginalAlertKey

local layoutManagerHooksInitialized = false

-- debug and flight recorder

local flightRecorderEnabled = BugGrabber ~= nil
local currentFlightRecorder = {}

local FLIGHT_RECORDER_CAPTURE_SECONDS = 60
local FLIGHT_RECORDER_POST_TRIGGER_SECONDS = 10

local flightRecorderTriggered = false
local flightRecorderTriggeredTime = nil

local function RecordFlightEvent(...)
    if not flightRecorderEnabled then
        return
    end

    table.insert(currentFlightRecorder, {
        timestamp = GetTimePreciseSec(),
        n = select("#", ...),
        ...
    })
end

local function StoreFlightRecorder()
    if not flightRecorderEnabled then
        return
    end

    local lines = {
        string.format(
            "%s Flight Recorder - triggered at %.3f",
            ADDON_NAME,
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

local function FlushCurrentFlightRecorder()
    if not flightRecorderEnabled or flightRecorderTriggered then
        return
    end

    flightRecorderTriggered = true
    flightRecorderTriggeredTime = GetTimePreciseSec()

    C_Timer.After(FLIGHT_RECORDER_POST_TRIGGER_SECONDS, function()
        StoreFlightRecorder()

        currentFlightRecorder = {}
        flightRecorderTriggered = false
        flightRecorderTriggeredTime = nil
    end)
end

local function CleanCurrentFlightRecorder()
    if not flightRecorderEnabled or flightRecorderTriggered then
        return
    end

    local cutoff =
        GetTimePreciseSec() - FLIGHT_RECORDER_CAPTURE_SECONDS

    while currentFlightRecorder[1]
        and currentFlightRecorder[1].timestamp < cutoff
    do
        table.remove(currentFlightRecorder, 1)
    end
end

local function OnBugGrabbed(_, errorID)
    if not flightRecorderEnabled or flightRecorderTriggered then
        return
    end

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

    if string.find(message, ADDON_NAME, 1, true) then
        FlushCurrentFlightRecorder()
    end
end

local function DebugPrint(...)
    RecordFlightEvent(...)
    if db.DebugPrintSwitch then
        print(...)
    end
end

local debugLog = {}
local function DebugLog(...)
    if db.DebugLogSwitch then
        table.insert(debugLog, {
            n = select("#", ...),
            ...
        })
    end
    DebugPrint(...)
end

local function PrintDebugLog()
    print("=== CDMLooper Debug Log ===")

    for i, entry in ipairs(debugLog) do
        print(i, unpack(entry, 1, entry.n))
    end

    print("=== End Debug Log ===")
end
-- Alert settings

local function GetAlertKey(alert)
    local alertType = CooldownViewerAlert_GetType(alert)
    local eventType = CooldownViewerAlert_GetEvent(alert)
    local payload = CooldownViewerAlert_GetPayload(alert)

    return string.format(
        "%s:%s:%s",
        tostring(alertType),
        tostring(eventType),
        tostring(payload)
    )
end


local function GetAlertSettings(cooldownID, alert)
    local alerts = db.Alerts[cooldownID]

    if not alerts then
        return nil
    end

    return alerts[GetAlertKey(alert)]
end


local function GetOrCreateAlertSettings(cooldownID, alert)
    local settings = GetAlertSettings(cooldownID, alert)

    if settings then
        return settings
    end

    local alertKey = GetAlertKey(alert)

    db.Alerts[cooldownID] = db.Alerts[cooldownID] or {}
    db.Alerts[cooldownID][alertKey] = {
        looping = false,
        interval = DEFAULT_LOOP_INTERVAL,
    }

    return db.Alerts[cooldownID][alertKey]
end


local function SaveAlertSettings(
    cooldownID,
    alert,
    oldAlertKey,
    looping,
    interval
)
    local alerts = db.Alerts[cooldownID]
    local newAlertKey = GetAlertKey(alert)
    local alertType = CooldownViewerAlert_GetType(alert)

    -- CDMLooper only supports Sound alerts.
    -- If the alert was changed to Visual, remove any existing CDMLooper settings.
    if alertType ~= Enum.CooldownViewerAlertType.Sound then
        if alerts then
            if oldAlertKey then
                alerts[oldAlertKey] = nil
            end

            alerts[newAlertKey] = nil

            if not next(alerts) then
                db.Alerts[cooldownID] = nil
            end
        end

        return
    end

    db.Alerts[cooldownID] = alerts or {}
    alerts = db.Alerts[cooldownID]

    -- If Type / When / Payload changed, remove the old key.
    if oldAlertKey and oldAlertKey ~= newAlertKey then
        alerts[oldAlertKey] = nil
    end

    -- Keep one settings entry for every supported Blizzard alert,
    -- even when looping is off.
    alerts[newAlertKey] = {
        looping = not not looping,
        interval = interval or DEFAULT_LOOP_INTERVAL,
    }
end


local function RemoveAlertSettings(cooldownID, alert)
    local alerts = db.Alerts[cooldownID]

    if not alerts then
        return
    end

    local alertKey = GetAlertKey(alert)
    local layoutManager = CooldownViewerSettings:GetLayoutManager()

    -- Identical Blizzard alerts share one CDMLooper settings entry.
    -- Remove our entry only when the deleted alert was the last Blizzard alert with this exact type/event/payload key.
    if layoutManager then
        local existingAlerts = layoutManager:GetAlerts(
            cooldownID,
            Enum.CDMLayoutMode.AccessOnly
        )

        if existingAlerts then
            for _, existingAlert in ipairs(existingAlerts) do
                if GetAlertKey(existingAlert) == alertKey then
                    return
                end
            end
        end
    end

    alerts[alertKey] = nil

    if not next(alerts) then
        db.Alerts[cooldownID] = nil
    end
end


local function RemoveAllAlertSettings(cooldownID)
    db.Alerts[cooldownID] = nil
end


local function PruneCooldownAlertSettings(cooldownID)
    local alerts = db.Alerts[cooldownID]

    if not alerts then
        return
    end

    local layoutManager = CooldownViewerSettings:GetLayoutManager()

    if not layoutManager then
        return
    end

    local existingAlerts = layoutManager:GetAlerts(
        cooldownID,
        Enum.CDMLayoutMode.AccessOnly
    )

    local existingAlertKeys = {}

    if existingAlerts then
        for _, alert in ipairs(existingAlerts) do
            existingAlertKeys[GetAlertKey(alert)] = true
        end
    end

    for alertKey in pairs(alerts) do
        if not existingAlertKeys[alertKey] then
            alerts[alertKey] = nil
        end
    end

    if not next(alerts) then
        db.Alerts[cooldownID] = nil
    end
end


local function CleanupEmptyAlertSettings()
    for cooldownID, alerts in pairs(db.Alerts) do
        if not next(alerts) then
            db.Alerts[cooldownID] = nil
        end
    end
end


-- UI

local function InitializeCDMLooperSettingsBlock()
    local settings = CooldownViewerSettings
    local content = settings.CooldownScroll.Content
    local lastCategory = settings.previousCategory

    -- Blizzard has not built the category list yet.
    if not lastCategory then
        return
    end

    -- Blizzard rebuilds its category frames. We only ever re-anchor our own
    -- frame to the current final category; Blizzard state is left untouched.
    if looperSettingsBlock then
        looperSettingsBlock:ClearAllPoints()
        looperSettingsBlock:SetPoint(
            "TOPLEFT",
            lastCategory,
            "BOTTOMLEFT",
            0,
            -18
        )
        looperSettingsBlock:Show()
        return
    end

    looperSettingsBlock = CreateFrame(
        "Frame",
        nil,
        content
    )

    looperSettingsBlock:SetWidth(344)
    looperSettingsBlock:SetHeight(60)
    looperSettingsBlock:SetPoint(
        "TOPLEFT",
        lastCategory,
        "BOTTOMLEFT",
        0,
        -18
    )

    -- Same header style Blizzard uses for Essential Cooldowns etc.
    local header = CreateFrame(
        "Button",
        nil,
        looperSettingsBlock,
        "ListHeaderThreeSliceTemplate"
    )

    header:SetHeight(22)
    header:SetPoint("TOPLEFT")
    header:SetPoint("TOPRIGHT")

    header:SetHeaderText("CDMLooper Settings")
    header:SetTitleColor(false, NORMAL_FONT_COLOR)
    header:SetTitleColor(true, NORMAL_FONT_COLOR)

    -- Global checkbox
    local overlapCheckBox = CreateFrame(
        "CheckButton",
        nil,
        looperSettingsBlock,
        "UICheckButtonTemplate"
    )

    overlapCheckBox:SetPoint(
        "TOPLEFT",
        header,
        "BOTTOMLEFT",
        10,
        -8
    )

    overlapCheckBox.Text:SetText(
        "Prevent overlapping loop sounds"
    )

    overlapCheckBox:SetChecked(
        db.PreventOverlappingLoopSounds
    )

    overlapCheckBox:SetScript("OnClick", function(self)
        db.PreventOverlappingLoopSounds = self:GetChecked()
    end)

    local function UpdateCollapsedState()
        overlapCheckBox:SetShown(not looperSettingsCollapsed)

        if looperSettingsCollapsed then
            looperSettingsBlock:SetHeight(22)
        else
            looperSettingsBlock:SetHeight(60)
        end

        header:UpdateCollapsedState(
            looperSettingsCollapsed
        )
    end

    header:SetScript("OnClick", function()
        looperSettingsCollapsed =
            not looperSettingsCollapsed

        UpdateCollapsedState()
    end)

    UpdateCollapsedState()
end

local function InitializeLayoutManagerHooks()
    if layoutManagerHooksInitialized then
        return
    end

    local layoutManager = CooldownViewerSettings:GetLayoutManager()

    if not layoutManager then
        return
    end

    hooksecurefunc(
        layoutManager,
        "RemoveAlert",
        function(_, cooldownID, alert)
            RemoveAlertSettings(cooldownID, alert)
        end
    )

    hooksecurefunc(
        layoutManager,
        "RemoveAllAlerts",
        function(_, cooldownID)
            RemoveAllAlertSettings(cooldownID)
        end
    )

    layoutManagerHooksInitialized = true
end


local function InitializeCDMLooperAlertUI()
    local editFrame = CooldownViewerSettingsEditAlert

    -- Original Blizzard frame is 310 x 385.
    -- Add enough space beneath PayloadDropdown for our section.
    editFrame:SetHeight(500)

    -- Yellow section title, same font style Blizzard uses for Type / When / Sound Alert.
    local settingsLabel = editFrame:CreateFontString(
        nil,
        "BORDER",
        "GameFontNormalHuge"
    )

    settingsLabel:SetPoint(
        "TOPLEFT",
        editFrame.PayloadDropdown,
        "BOTTOMLEFT",
        0,
        -25
    )

    settingsLabel:SetText("CDMLooper Settings")

    -- Loop checkbox
    alertLoopingCheckBox = CreateFrame(
        "CheckButton",
        nil,
        editFrame,
        "UICheckButtonTemplate"
    )

    alertLoopingCheckBox:SetPoint(
        "TOPLEFT",
        settingsLabel,
        "BOTTOMLEFT",
        0,
        -8
    )

    alertLoopingCheckBox.Text:SetText("Loop alert")

    -- Interval slider
    alertIntervalSlider = CreateFrame(
        "Slider",
        "CDMLooperAlertIntervalSlider",
        editFrame,
        "OptionsSliderTemplate"
    )

    alertIntervalSlider:SetPoint(
        "TOPLEFT",
        alertLoopingCheckBox,
        "BOTTOMLEFT",
        8,
        -22
    )

    alertIntervalSlider:SetWidth(245)
    alertIntervalSlider:SetMinMaxValues(1, 30)
    alertIntervalSlider:SetValueStep(1)
    alertIntervalSlider:SetObeyStepOnDrag(true)
    alertIntervalSlider:SetValue(DEFAULT_LOOP_INTERVAL)
    alertIntervalSlider:Enable()

    _G["CDMLooperAlertIntervalSliderLow"]:SetText("1")
    _G["CDMLooperAlertIntervalSliderHigh"]:SetText("30")

    local sliderText =
        _G["CDMLooperAlertIntervalSliderText"]

    local function UpdateSliderText()
        local interval = math.floor(
            alertIntervalSlider:GetValue() + 0.5
        )

        sliderText:SetText(
            string.format(
                "Repeat every %d seconds",
                interval
            )
        )
    end

    alertIntervalSlider:SetScript(
        "OnValueChanged",
        UpdateSliderText
    )

    local function UpdateCDMLooperAlertUIVisibility()
        local alert = editFrame.workingCopyOfAlert

        if not alert then
            settingsLabel:Hide()
            alertLoopingCheckBox:Hide()
            alertIntervalSlider:Hide()
            return
        end

        local alertType = CooldownViewerAlert_GetType(alert)
        local show = alertType == Enum.CooldownViewerAlertType.Sound

        settingsLabel:SetShown(show)
        alertLoopingCheckBox:SetShown(show)
        alertIntervalSlider:SetShown(show)
    end

    -- Blizzard rebuilds the dropdowns immediately when Type changes.
    -- Use that as our signal to hide/show the CDMLooper controls.
    hooksecurefunc(
        editFrame,
        "SetupDropdowns",
        function()
            UpdateCDMLooperAlertUIVisibility()
        end
    )

    -- Populate our controls whenever Blizzard opens New/Edit Alert.
    -- Sound alerts get a default CDMLooper entry on first open.
    -- Visual alerts do not get CDMLooper settings.
    hooksecurefunc(
        editFrame,
        "DisplayForAlert",
        function(self, cooldownItem, alert, isNewAlert)
            currentEditCooldownID = self:GetCooldownID()
            currentOriginalAlertKey = GetAlertKey(alert)

            local alertType = CooldownViewerAlert_GetType(alert)

            if alertType == Enum.CooldownViewerAlertType.Sound then
                local settings =
                    GetOrCreateAlertSettings(currentEditCooldownID, alert)

                alertLoopingCheckBox:SetChecked(settings.looping)
                alertIntervalSlider:SetValue(
                    settings.interval or DEFAULT_LOOP_INTERVAL
                )
            else
                -- Keep sane staged defaults in case the user changes
                -- this Visual alert to Sound before applying.
                alertLoopingCheckBox:SetChecked(false)
                alertIntervalSlider:SetValue(DEFAULT_LOOP_INTERVAL)
            end

            UpdateSliderText()
            UpdateCDMLooperAlertUIVisibility()
        end
    )

    -- This is the only point that commits checkbox/slider changes.
    -- Blizzard calls this from its existing Apply Changes button.
    hooksecurefunc(
        editFrame,
        "AddCurrentAlert",
        function(self)
            if not currentEditCooldownID then
                return
            end

            local interval = math.floor(
                alertIntervalSlider:GetValue() + 0.5
            )

            SaveAlertSettings(
                currentEditCooldownID,
                self.workingCopyOfAlert,
                currentOriginalAlertKey,
                alertLoopingCheckBox:GetChecked(),
                interval
            )

            currentOriginalAlertKey =
                GetAlertKey(self.workingCopyOfAlert)
        end
    )

    -- DisplayForAlert creates a default DB entry immediately.
    -- If a brand-new alert is closed without being applied, remove that orphan again after Blizzard has finished its hide/apply sequence.
    editFrame:HookScript("OnHide", function()
        local cooldownID = currentEditCooldownID

        if not cooldownID then
            return
        end

        C_Timer.After(0, function()
            PruneCooldownAlertSettings(cooldownID)
        end)
    end)
end

-- Loop queue handling

local function SafeFetchIDs(cooldownItem)
    local cooldownID = cooldownItem:GetCooldownID()
    local spellID = cooldownItem:GetBaseSpellID()

    if issecretvalue(spellID) then
        DebugLog("SafeFetchIDs", "SpellID is secret")
    else
        DebugPrint("SafeFetchIDs", "SpellID:", spellID)
    end

    if issecretvalue(cooldownID) then
        DebugLog("SafeFetchIDs", "CooldownID is secret")
    else
        DebugPrint("SafeFetchIDs", "CooldownID:", cooldownID)
    end

    if not spellID or issecretvalue(spellID) or not cooldownID or issecretvalue(cooldownID) then
        return nil, nil
    end

    return spellID, cooldownID
end

local ProcessPendingLoopAlerts

local function PlayQueuedLoopAlert(pending)
    local alertType = CooldownViewerAlert_GetType(pending.alert)
    local payload = CooldownViewerAlert_GetPayload(pending.alert)

    if not alertType or issecretvalue(alertType) then
        DebugPrint("PlayQueuedLoopAlert", "AlertType is secret")
        return false
    end

    if payload == nil or issecretvalue(payload) then
        DebugPrint("PlayQueuedLoopAlert", "Payload is secret")
        return false
    end

    if alertType ~= Enum.CooldownViewerAlertType.Sound then
        return false
    end

    local success = false

    if payload == Enum.CooldownViewerSound.TextToSpeech then
        local voice = TextToSpeechFrame_GetSpeakerVoiceForMessageType(nil)

        if not voice or not voice.voiceID then
            return false
        end

        if db.PreventOverlappingLoopSounds then
            activeLoopPlaybackType = "tts"
            activeLoopSoundHandle = nil
            activeLoopPlaybackSpellID = pending.spellID
            activeLoopTTSUtteranceID = nil
            waitingForLoopTTSRequest = true
        end

        C_VoiceChat.SpeakText(
            voice.voiceID,
            pending.spellName,
            C_TTSSettings.GetSpeechRate(),
            C_TTSSettings.GetSpeechVolume(),
            not db.PreventOverlappingLoopSounds
        )

        waitingForLoopTTSRequest = false

        if db.PreventOverlappingLoopSounds
            and not activeLoopTTSUtteranceID then
            activeLoopPlaybackType = nil
            activeLoopPlaybackSpellID = nil
            success = false
        else
            success = true
        end

    else
        local soundKit =
            CooldownViewerAlert_GetPayloadContextData(pending.alert)

        if not soundKit or issecretvalue(soundKit) then
            DebugPrint("PlayQueuedLoopAlert", "SoundKit is secret")
            return false
        end

        local soundHandle

        success, soundHandle = C_Sound.PlaySoundWithOptions({
            soundKitID = soundKit,
            uiSoundSubType = pending.soundSubType,
            runFinishCallback = db.PreventOverlappingLoopSounds,
        })

        if success and db.PreventOverlappingLoopSounds then
            activeLoopPlaybackType = "sound"
            activeLoopSoundHandle = soundHandle
            activeLoopPlaybackSpellID = pending.spellID
            waitingForLoopTTSRequest = false
        end
    end

    return success
end

ProcessPendingLoopAlerts = function()
    if db.PreventOverlappingLoopSounds
        and activeLoopPlaybackType then
        return
    end

    while #pendingLoopAlerts > 0 do
        local pending = table.remove(pendingLoopAlerts, 1)

        if queuedLoopAlerts[pending.spellID] == pending then
            queuedLoopAlerts[pending.spellID] = nil

            if activeLoops[pending.spellID] then
                local success = PlayQueuedLoopAlert(pending)

                if success
                    and db.PreventOverlappingLoopSounds
                    and activeLoopPlaybackType then
                    return
                end
            end
        end
    end
end


local function QueueLoopedAlert(
    spellID,
    cooldownItem,
    alert,
    soundSubType
)
    if issecretvalue(spellID) then
        DebugLog("QueueLoopedAlert", "SpellID is secret")
        return
    end

    -- Already waiting in the queue.
    if queuedLoopAlerts[spellID] then
        return
    end

    -- Don't queue another reminder for this spell while its previous reminder is currently playing.
    if db.PreventOverlappingLoopSounds
        and activeLoopPlaybackSpellID == spellID then
        return
    end

    local spellName = C_Spell.GetSpellName(spellID)

    if not spellName or issecretvalue(spellName) then
        DebugPrint("QueueLoopedAlert", "SpellName is secret")
        return
    end

    local pending = {
        spellID = spellID,
        cooldownItem = cooldownItem,
        spellName = spellName,
        alert = alert,
        soundSubType = soundSubType,
    }

    queuedLoopAlerts[spellID] = pending
    table.insert(pendingLoopAlerts, pending)

    -- If the queue is free this will play immediately.
    -- Otherwise it waits for the active playback completion event.
    ProcessPendingLoopAlerts()
end


local function StopLoop(spellID)
    DebugPrint("StopLoop", "spellID secret:", issecretvalue(spellID))

    if issecretvalue(spellID) then
        return
    end

    local ticker = activeLoops[spellID]

    if ticker then
        ticker:Cancel()
        activeLoops[spellID] = nil
    end

    -- Cancel anything this spell still has waiting in the queue.
    -- The stale FIFO entry can stay there; the processor skips it.
    queuedLoopAlerts[spellID] = nil
end


local function StopAllLoops()
    for _, ticker in pairs(activeLoops) do
        ticker:Cancel()
    end

    wipe(activeLoops)
    wipe(pendingLoopAlerts)
    wipe(queuedLoopAlerts)

    activeLoopPlaybackType = nil
    activeLoopSoundHandle = nil
    activeLoopPlaybackSpellID = nil
    activeLoopTTSUtteranceID = nil
    waitingForLoopTTSRequest = false
end

local function CreateSound(cooldownID,
                           spellID,
                           cooldownItem,
                           alert,
                           soundSubType)
    local settings = GetAlertSettings(cooldownID, alert)

    if not settings or not settings.looping then
        return
    end

    StopLoop(spellID)

    activeLoops[spellID] = C_Timer.NewTicker(
        settings.interval,
        function()
            DebugPrint("Loop tick", spellID)
            QueueLoopedAlert(
                spellID,
                cooldownItem,
                alert,
                soundSubType
            )
        end
    )
end

local function NoOp()
    -- noOperation function
end
local function RaceConditionCleanup()
    if not UnitAffectingCombat("player") then
        return
    end
    local now = GetTimePreciseSec()

    for spellID, suppressionTime in pairs(raceConditionList) do
        if now > suppressionTime then
            raceConditionList[spellID] = nil
        end
    end
end

local function PeriodicCleanup()
    RaceConditionCleanup()
    CleanCurrentFlightRecorder()
end


local function RaceConditionCheck(spellID)
    local suppressionTime = raceConditionList[spellID]
    if suppressionTime then
        if suppressionTime > GetTimePreciseSec() then
            return false
        else
            raceConditionList[spellID] = nil
        end
    end
    return true
end

-- CDM alert handling functions
local function OnAvailable(cooldownItem, _, alert, soundSubType)
    local spellID, cooldownID = SafeFetchIDs(cooldownItem)
    if not spellID or not cooldownID then
        return
    end
    if cooldownItem:IsEquippedItem() then
        local equipSlot = cooldownItem:GetEquipSlot()
        local start, duration = GetInventoryItemCooldown("player", equipSlot)

        if start > 0 and duration > 0 then
            DebugPrint("OnAvailable", "Trinket still on cooldown")
            return
        end
    end
    if RaceConditionCheck(spellID) then
        CreateSound(cooldownID, spellID, cooldownItem, alert, soundSubType)
    end
end


local function OnPandemicTime(cooldownItem, _, alert, soundSubType)
    local spellID, cooldownID = SafeFetchIDs(cooldownItem)
    if not spellID or not cooldownID then
        return
    end
    if RaceConditionCheck(spellID) then
        CreateSound(cooldownID, spellID, cooldownItem, alert, soundSubType)
    end
end


local function OnCooldown(cooldownItem, _, alert, soundSubType)
    local spellID, cooldownID = SafeFetchIDs(cooldownItem)
    if not spellID or not cooldownID then
        return
    end
    if cooldownItem:IsEquippedItem() then
        local equipSlot = cooldownItem:GetEquipSlot()
        local start, duration = GetInventoryItemCooldown("player", equipSlot)

        if start > 0 and duration > 0 then
            DebugPrint("OnCooldown", "Trinket still on cooldown")
            return
        end
    end
    if RaceConditionCheck(spellID) then
        CreateSound(cooldownID, spellID, cooldownItem, alert, soundSubType)
    end
end

local function OnChargeGained(cooldownItem, _, alert, soundSubType)
    local spellID, cooldownID = SafeFetchIDs(cooldownItem)
    if not spellID or not cooldownID then
        return
    end
    local chargeInfo = C_Spell.GetSpellCharges(spellID)
    if not chargeInfo then
        return
    end

    if not chargeInfo.isActive and RaceConditionCheck(spellID) then
        CreateSound(cooldownID, spellID, cooldownItem, alert, soundSubType)
    end
end

local function OnAuraApplied(cooldownItem, _, alert, soundSubType)
    local spellID, cooldownID = SafeFetchIDs(cooldownItem)
    if not spellID or not cooldownID then
        return
    end
    if RaceConditionCheck(spellID) then
        CreateSound(cooldownID, spellID, cooldownItem, alert, soundSubType)
    end
end

local function OnAuraRemoved(cooldownItem, _, alert, soundSubType)
    local spellID, cooldownID = SafeFetchIDs(cooldownItem)
    if not spellID or not cooldownID then
        return
    end
    if RaceConditionCheck(spellID) then
        CreateSound(cooldownID, spellID, cooldownItem, alert, soundSubType)
    end
end


-- Runtime handling

local function OnSpellFired(spellID)
    if not UnitAffectingCombat("player") then
        return
    end

    local isSecret = issecretvalue(spellID)

    if isSecret then
        DebugLog("OnSpellFired", "spellID secret:", true, "quick returning")
        return
    end
    DebugPrint("OnSpellFired", "SpellID:", spellID)
    local baseSpellID = C_Spell.GetBaseSpell(spellID)
    DebugPrint("OnSpellFired", "BaseSpellID:", baseSpellID)
    raceConditionList[baseSpellID] = GetTimePreciseSec() + RACE_CONDITION_TIMER
    StopLoop(baseSpellID)
end


local function OnLoopSoundFinished(soundHandle)
    -- Ignore SOUNDKIT_FINISHED events belonging to anything else.
    if soundHandle ~= activeLoopSoundHandle then
        return
    end

    activeLoopPlaybackType = nil
    activeLoopSoundHandle = nil
    activeLoopPlaybackSpellID = nil

    -- Immediately service the next queued reminder.
    ProcessPendingLoopAlerts()
end


-- CDM event handler

local CDM_EVENT_HANDLERS = {
    [BLIZZ_ALERT_EVENT_TYPE.Available]     = OnAvailable,
    [BLIZZ_ALERT_EVENT_TYPE.PandemicTime]  = OnPandemicTime,
    [BLIZZ_ALERT_EVENT_TYPE.OnCooldown]    = OnCooldown,
    [BLIZZ_ALERT_EVENT_TYPE.ChargeGained]  = OnChargeGained,
    [BLIZZ_ALERT_EVENT_TYPE.OnAuraApplied] = OnAuraApplied,
    [BLIZZ_ALERT_EVENT_TYPE.OnAuraRemoved] = OnAuraRemoved,
}


-- Hooked handler

local function OnCDMAlertEvent(cooldownItem, spellName, alert, soundSubType)
    DebugPrint(
        "OnCDMAlertEvent",
        "cooldownItem:", issecretvalue(cooldownItem) and "<secret>" or cooldownItem,
        "spellName:", issecretvalue(spellName) and "<secret>" or spellName,
        "alert:", issecretvalue(alert) and "<secret>" or alert
    )

    -- Ignore preview from the CDM settings item
    if cooldownItem.PlayAlertSample then
        return
    end

    -- Ignore preview button inside the alert editor itself
    if cooldownItem == CooldownViewerSettingsEditAlert then
        return
    end

    -- Do nothing when not in combat
    if not UnitAffectingCombat("player") then
        return
    end

    local eventType = CooldownViewerAlert_GetEvent(alert)
    DebugPrint("OnCDMAlertEvent", "eventType:", eventType)
    local handler = CDM_EVENT_HANDLERS[eventType] or NoOp

    handler(
        cooldownItem,
        spellName,
        alert,
        soundSubType
    )
end

-- Addon Load Sequence

local loadFrame = CreateFrame("Frame")
loadFrame:RegisterEvent("ADDON_LOADED")

loadFrame:SetScript("OnEvent", function(_, _, loadedAddon)
    if loadedAddon ~= ADDON_NAME then
        return
    end

    LooperDB = LooperDB or {}

    if LooperDB.DB_Version ~= DB_VERSION then
        LooperDB = {
            DB_Version = DB_VERSION
        }
    end

    -- Init DB values here
    if LooperDB.PreventOverlappingLoopSounds == nil then
        LooperDB.PreventOverlappingLoopSounds = true
    end

    if LooperDB.DebugPrintSwitch == nil then
        LooperDB.DebugPrintSwitch = false
    end
    if LooperDB.DebugLogSwitch == nil then
        LooperDB.DebugLogSwitch = false
    end

    LooperDB.Alerts = LooperDB.Alerts or {}

    db = LooperDB

    if flightRecorderEnabled and EventRegistry then
        EventRegistry:RegisterCallback(
            "BugGrabber.BugGrabbed",
            OnBugGrabbed
        )
    end

    CleanupEmptyAlertSettings()

    InitializeCDMLooperAlertUI()

    -- The layout manager may not exist yet during ADDON_LOADED.
    -- It will definitely exist by the time the settings window can be used, so try now and again whenever the settings open.
    InitializeLayoutManagerHooks()
    CooldownViewerSettings:HookScript(
        "OnShow",
        InitializeLayoutManagerHooks
    )

    -- Create/re-anchor the CDMLooper block after Blizzard has built the list.
    -- This does not modify Blizzard's previousCategory state.
    CooldownViewerSettings:HookScript("OnShow", function()
        C_Timer.After(0, InitializeCDMLooperSettingsBlock)
    end)

    hooksecurefunc(CooldownViewerSettings, "ClearDisplayCategories", function()
        C_Timer.After(0, InitializeCDMLooperSettingsBlock)
    end)

    hooksecurefunc(
        "CooldownViewerAlert_PlayAlert",
        OnCDMAlertEvent
    )

    SLASH_CMDLOOPER1 = "/cdmlooper"
    SLASH_CMDLOOPER2 = "/cdml"

    SlashCmdList["CMDLOOPER"] = function(message)
        local command, args = message:match("^(%S*)%s*(.-)$")

        if command == "debug" then
            local debugCommand, debugArgs = args:match("^(%S*)%s*(.-)$")

            if debugCommand == "switch" then
                local switchCommand, _ = debugArgs:match("^(%S*)%s*(.-)$")
                if switchCommand == "log" then
                    db.DebugLogSwitch = not db.DebugLogSwitch
                    print("Debug log switch is: " .. (db.DebugLogSwitch and "on" or "off"))
                    return
                end
                if switchCommand == "print" then
                    db.DebugPrintSwitch = not db.DebugPrintSwitch
                    print("Debug print switch is: " .. (db.DebugPrintSwitch and "on" or "off"))
                    return
                end
                print("Debug switch commands")
                print("/cdml debug switch log")
                print("/cdml debug switch print")
                return
            end
            if debugCommand == "clear" then
                wipe(debugLog)
                print("Debug log cleared.")
                return
            end
            if debugCommand == "alert" then
                StopAllLoops()
                print("All active loops stopped.")
                return
            end
            if debugCommand == "print" then
                PrintDebugLog()
                return
            end
            if debugCommand == "testerror" then
                C_Timer.After(0, function()
                    error(ADDON_NAME .. " synthetic flight recorder test")
                end)
                return
            end

            print(ADDON_NAME, "debug commands")
            print("/cdml debug switch")
            print("/cdml debug clear")
            print("/cdml debug alert")
            print("/cdml debug print")
            print("/cdml debug testerror")
            print("Debug print switch is: " .. (db.DebugPrintSwitch and "on" or "off"))
            print("Debug log switch is: " .. (db.DebugLogSwitch and "on" or "off"))
            return
        end

        print(ADDON_NAME, "commands")
        print("/cdml debug")
    end
end)


-- Runtime events

local function OnUnitSpellcastSucceeded(_, _, spellID)
    OnSpellFired(spellID)
end

local function OnCombatEnd()
    StopAllLoops()
    if raceConditionCleanupTicker then
        raceConditionCleanupTicker:Cancel()
        raceConditionCleanupTicker = nil
    end
    wipe(raceConditionList)
end

local function OnCombatStart()
    if not raceConditionCleanupTicker then
        raceConditionCleanupTicker = C_Timer.NewTicker(
            60,
            PeriodicCleanup
        )
    end
end

local function OnLoopTTSStarted(utteranceID)
    if activeLoopPlaybackType ~= "tts"
        or utteranceID ~= activeLoopTTSUtteranceID then
        return
    end

    DebugPrint("Our TTS started:", utteranceID)
end

local function OnLoopTTSFinished(utteranceID)
    if activeLoopPlaybackType ~= "tts"
        or utteranceID ~= activeLoopTTSUtteranceID then
        return
    end

    activeLoopTTSUtteranceID = nil
    waitingForLoopTTSRequest = false
    activeLoopPlaybackType = nil
    activeLoopPlaybackSpellID = nil

    ProcessPendingLoopAlerts()
end

local function OnLoopTTSFailed(utteranceID, status)
    if activeLoopPlaybackType ~= "tts"
        or utteranceID ~= activeLoopTTSUtteranceID then
        return
    end

    DebugPrint(
        "OnLoopTTSFailed",
        "utteranceID:", utteranceID,
        "status:", status
    )

    activeLoopTTSUtteranceID = nil
    waitingForLoopTTSRequest = false
    activeLoopPlaybackType = nil
    activeLoopPlaybackSpellID = nil

    ProcessPendingLoopAlerts()
end

local function OnLoopTTSSpeakTextUpdate(status, utteranceID)
    if activeLoopPlaybackType ~= "tts"
        or not waitingForLoopTTSRequest then
        return
    end

    activeLoopTTSUtteranceID = utteranceID
end

local RUNTIME_EVENT_HANDLERS = {
    ["UNIT_SPELLCAST_SUCCEEDED"] = OnUnitSpellcastSucceeded,
    ["PLAYER_REGEN_DISABLED"] = OnCombatStart,
    ["PLAYER_REGEN_ENABLED"] = OnCombatEnd,
    ["SOUNDKIT_FINISHED"] = OnLoopSoundFinished,
    ["VOICE_CHAT_TTS_PLAYBACK_STARTED"] = OnLoopTTSStarted,
    ["VOICE_CHAT_TTS_PLAYBACK_FINISHED"] = OnLoopTTSFinished,
    ["VOICE_CHAT_TTS_PLAYBACK_FAILED"] = OnLoopTTSFailed,
    ["VOICE_CHAT_TTS_SPEAK_TEXT_UPDATE"] = OnLoopTTSSpeakTextUpdate,
}

local runtimeFrame = CreateFrame("Frame")

runtimeFrame:RegisterUnitEvent(
    "UNIT_SPELLCAST_SUCCEEDED",
    "player"
)

runtimeFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
runtimeFrame:RegisterEvent("SOUNDKIT_FINISHED")
runtimeFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
runtimeFrame:RegisterEvent("VOICE_CHAT_TTS_PLAYBACK_FINISHED")
runtimeFrame:RegisterEvent("VOICE_CHAT_TTS_PLAYBACK_FAILED")
runtimeFrame:RegisterEvent("VOICE_CHAT_TTS_PLAYBACK_STARTED")
runtimeFrame:RegisterEvent("VOICE_CHAT_TTS_SPEAK_TEXT_UPDATE")

runtimeFrame:SetScript("OnEvent", function(_, event, ...)
    local handler = RUNTIME_EVENT_HANDLERS[event] or NoOp

    handler(...)
end)
