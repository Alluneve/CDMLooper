local ADDON_NAME = "CDMLooper"

--AlertEventType.Available
--AlertEventType.PandemicTime
--AlertEventType.OnCooldown
--AlertEventType.ChargeGained
--AlertEventType.OnAuraApplied
--AlertEventType.OnAuraRemoved

local BLIZZ_AlertEventType = Enum.CooldownViewerAlertEventType

local db
local DB_VERSION = 1

local DEFAULT_LOOP_INTERVAL = 3

local activeLoops = {}
local replayingAlert = false

local activeLoopSoundHandle = nil
local activeLoopSoundSpellID = nil

local pendingLoopAlerts = {}
local queuedLoopAlerts = {}

-- UI
local looperSettingsBlock
local looperSettingsCollapsed = false
local alertLoopingCheckBox
local alertIntervalSlider

local currentEditCooldownID
local currentOriginalAlertKey

local layoutManagerHooksInitialized = false
local advancedCooldownSettingsGuardInitialized = false

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

    looperSettingsBlock = CreateFrame(
        "Frame",
        nil,
        content
    )

    looperSettingsBlock:SetWidth(344)
    looperSettingsBlock:SetHeight(60)
    looperSettingsBlock:SetPoint(
        "TOPLEFT",
        content,
        "TOPLEFT",
        0,
        0
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

    -- Blizzard resets previousCategory every time it rebuilds the category list. Put our block back at the front.
    hooksecurefunc(
        settings,
        "ClearDisplayCategories",
        function(self)
            self.previousCategory = looperSettingsBlock
        end
    )
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

local function InitializeCDMCombatGuard()
    local originalShowUIPanel = CooldownViewerSettings.ShowUIPanel

    CooldownViewerSettings.ShowUIPanel = function(self, ...)
        if InCombatLockdown() then
            UIErrorsFrame:AddMessage(
                "cannot open this with CDMLooper installed while in combat",
                1, 0.1, 0.1
            )

            return
        end

        return originalShowUIPanel(self, ...)
    end
end


local function UpdateAdvancedCooldownSettingsButton(frame, enabled)
    if not frame.Button
        or not frame.Button.Text
        or frame.Button.Text:GetText() ~= HUD_EDIT_MODE_COOLDOWN_VIEWER_SETTINGS then
        return
    end

    if enabled == nil then
        enabled = not InCombatLockdown()
    end

    frame.Button:SetEnabled(enabled)
end


local function RefreshAdvancedCooldownSettingsButton(enabled)
    if not SettingsPanel
        or not SettingsPanel.Container
        or not SettingsPanel.Container.SettingsList
        or not SettingsPanel.Container.SettingsList.ScrollBox then
        return
    end

    SettingsPanel.Container.SettingsList.ScrollBox:ForEachFrame(
        function(frame)
            UpdateAdvancedCooldownSettingsButton(frame, enabled)
        end
    )
end


local function InitializeAdvancedCooldownSettingsGuard()
    if advancedCooldownSettingsGuardInitialized then
        RefreshAdvancedCooldownSettingsButton()
        return
    end

    if not SettingsPanel
        or not SettingsPanel.Container
        or not SettingsPanel.Container.SettingsList
        or not SettingsPanel.Container.SettingsList.ScrollBox then
        return
    end

    local scrollBox = SettingsPanel.Container.SettingsList.ScrollBox
    local view = scrollBox:GetView()

    if not view then
        return
    end

    view:RegisterCallback(
        ScrollBoxListViewMixin.Event.OnInitializedFrame,
        function(_, frame)
            UpdateAdvancedCooldownSettingsButton(frame)
        end
    )

    advancedCooldownSettingsGuardInitialized = true
    RefreshAdvancedCooldownSettingsButton()
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

local ProcessPendingLoopAlerts


local function PlayQueuedLoopAlert(pending)
    local alertType = CooldownViewerAlert_GetType(pending.alert)

    if db.PreventOverlappingLoopSounds
        and alertType == Enum.CooldownViewerAlertType.Sound then
        local soundKit = CooldownViewerAlert_GetPayloadContextData(
            pending.alert
        )

        if soundKit then
            local success, soundHandle = C_Sound.PlaySoundWithOptions({
                soundKitID = soundKit,
                uiSoundSubType = pending.soundSubType,
                runFinishCallback = true,
            })

            if success then
                activeLoopSoundHandle = soundHandle
                activeLoopSoundSpellID = pending.spellID

                -- Queue must wait for SOUNDKIT_FINISHED
                return true
            end

            return false
        end
    end

    -- Visual alerts, TTS, or overlap prevention disabled:
    -- replay through CDM normally.
    replayingAlert = true

    CooldownViewerAlert_PlayAlert(
        pending.cooldownItem,
        pending.spellName,
        pending.alert,
        pending.soundSubType
    )

    replayingAlert = false

    -- Nothing blocking the queue
    return false
end


ProcessPendingLoopAlerts = function()
    -- A tracked loop sound is still playing.
    if db.PreventOverlappingLoopSounds
        and activeLoopSoundHandle then
        return
    end

    while #pendingLoopAlerts > 0 do
        local pending = table.remove(pendingLoopAlerts, 1)

        -- Check that this queued entry wasn't cancelled while waiting.
        if queuedLoopAlerts[pending.spellID] == pending then
            queuedLoopAlerts[pending.spellID] = nil

            -- Spell may have been fired while waiting.
            if activeLoops[pending.spellID] then
                local blocking = PlayQueuedLoopAlert(pending)

                if blocking then
                    return
                end
            end
        end
    end
end


local function QueueLoopedAlert(
    spellID,
    cooldownItem,
    spellName,
    alert,
    soundSubType
)
    -- Already waiting in the queue.
    if queuedLoopAlerts[spellID] then
        return
    end

    -- Don't queue another reminder for this spell while its previous reminder is currently playing.
    if db.PreventOverlappingLoopSounds
        and activeLoopSoundSpellID == spellID
        and activeLoopSoundHandle then
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
    -- Otherwise it waits for SOUNDKIT_FINISHED.
    ProcessPendingLoopAlerts()
end


local function StopLoop(spellID)
    local ticker = activeLoops[spellID]

    if ticker then
        ticker:Cancel()
        activeLoops[spellID] = nil
    end

    -- Cancel anything this spell still has waiting in the queue.
    -- The stale FIFO entry can stay there; the processor skips it.
    queuedLoopAlerts[spellID] = nil
end


local function stopAllLoops()
    for _, ticker in pairs(activeLoops) do
        ticker:Cancel()
    end

    wipe(activeLoops)
    wipe(pendingLoopAlerts)
    wipe(queuedLoopAlerts)
end


-- CDM alert handling functions

local function OnAvailable(cooldownItem, spellName, alert, soundSubType)
    local spellID = cooldownItem:GetSpellID()
    local cooldownID = cooldownItem:GetCooldownID()

    if not spellID then
        return
    end

    local settings = GetAlertSettings(cooldownID, alert)

    if not settings or not settings.looping then
        return
    end

    StopLoop(spellID)

    activeLoops[spellID] = C_Timer.NewTicker(
        settings.interval,
        function()
            QueueLoopedAlert(
                spellID,
                cooldownItem,
                spellName,
                alert,
                soundSubType
            )
        end
    )
end


local function OnPandemicTime(cooldownItem, spellName, alert, soundSubType)
    -- do nothing on pandemic for now
end


local function OnCooldown(cooldownItem, spellName, alert, soundSubType)
    -- do nothing on cooldown for now
end


local function OnChargeGained(cooldownItem, spellName, alert, soundSubType)
    -- do nothing on charge gained for now
end


local function OnAuraApplied(cooldownItem, spellName, alert, soundSubType)
    -- do nothing on aura applied for now
end


local function OnAuraRemoved(cooldownItem, spellName, alert, soundSubType)
    -- do nothing on aura removed for now
end


local function NoOp()
    -- noOperation function
end


-- Runtime handling
local cdmHiddenForCombat = false

local function onCombatStart()
    if CooldownViewerSettings
        and CooldownViewerSettings:IsShown() then
        CooldownViewerSettings:Hide()
        cdmHiddenForCombat = true
    end

    InitializeAdvancedCooldownSettingsGuard()
    RefreshAdvancedCooldownSettingsButton(false)
end


local function onCombatEnd()
    stopAllLoops()

    if cdmHiddenForCombat then
        HideUIPanel(CooldownViewerSettings)
        cdmHiddenForCombat = false
    end

    InitializeAdvancedCooldownSettingsGuard()
    RefreshAdvancedCooldownSettingsButton(true)
end

local function onSpellFired(spellID)
    StopLoop(spellID)
end


local function onLoopSoundFinished(soundHandle)
    -- Ignore SOUNDKIT_FINISHED events belonging to anything else.
    if soundHandle ~= activeLoopSoundHandle then
        return
    end

    activeLoopSoundHandle = nil
    activeLoopSoundSpellID = nil

    -- Immediately service the next queued reminder.
    ProcessPendingLoopAlerts()
end


-- CDM event handler

local CDM_EVENT_HANDLERS = {
    [BLIZZ_AlertEventType.Available]     = OnAvailable,
    [BLIZZ_AlertEventType.PandemicTime]  = OnPandemicTime,
    [BLIZZ_AlertEventType.OnCooldown]    = OnCooldown,
    [BLIZZ_AlertEventType.ChargeGained]  = OnChargeGained,
    [BLIZZ_AlertEventType.OnAuraApplied] = OnAuraApplied,
    [BLIZZ_AlertEventType.OnAuraRemoved] = OnAuraRemoved,
}


-- Hooked handler

local function OnCDMAlertEvent(cooldownItem, spellName, alert, soundSubType)
    -- Prevent our own repeated alert from re-entering the handler
    if replayingAlert then
        return
    end

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

    LooperDB.Alerts = LooperDB.Alerts or {}

    db = LooperDB

    CleanupEmptyAlertSettings()

    InitializeCDMLooperSettingsBlock()
    InitializeCDMLooperAlertUI()
    InitializeCDMCombatGuard()
    InitializeAdvancedCooldownSettingsGuard()

    -- The layout manager may not exist yet during ADDON_LOADED.
    -- It will definitely exist by the time the settings window can be used, so try now and again whenever the settings open.
    InitializeLayoutManagerHooks()
    CooldownViewerSettings:HookScript(
        "OnShow",
        InitializeLayoutManagerHooks
    )

    hooksecurefunc(
        "CooldownViewerAlert_PlayAlert",
        OnCDMAlertEvent
    )
end)


-- Runtime events

local function onUnitSpellcastSucceeded(_, _, spellID)
    onSpellFired(spellID)
end


local RUNTIME_EVENT_HANDLERS = {
    ["UNIT_SPELLCAST_SUCCEEDED"] = onUnitSpellcastSucceeded,
    ["PLAYER_REGEN_DISABLED"] = onCombatStart,
    ["PLAYER_REGEN_ENABLED"] = onCombatEnd,
    ["SOUNDKIT_FINISHED"] = onLoopSoundFinished,
}

local runtimeFrame = CreateFrame("Frame")

runtimeFrame:RegisterUnitEvent(
    "UNIT_SPELLCAST_SUCCEEDED",
    "player"
)

runtimeFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
runtimeFrame:RegisterEvent("SOUNDKIT_FINISHED")
runtimeFrame:RegisterEvent("PLAYER_REGEN_DISABLED")

runtimeFrame:SetScript("OnEvent", function(_, event, ...)
    local handler = RUNTIME_EVENT_HANDLERS[event] or NoOp

    handler(...)
end)
