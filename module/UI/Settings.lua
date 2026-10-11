local _, private = ...
local SettingsUI = {}

local settingsHandler
local playback

-- Constructor --

---@param params { settingsHandler: table, playback: table }
function SettingsUI.Initialize(params)
    settingsHandler = params.settingsHandler
    playback = params.playback
end

private.SettingsUI = SettingsUI

-- Module Variables --

local looperSettingsBlock
local looperSettingsCollapsed = false

local alertLoopingCheckBox
local alertIntervalSlider

local currentEditCooldownID
local currentOriginalAlertKey

local layoutManagerHooksInitialized = false
local uiHooksInitialized = false
local overwriteExistingExports = false

-- Implementation --

-- General CDMLooper Settings --

local function InitializeCDMLooperSettingsBlock()
    local settings = CooldownViewerSettings
    local content = settings.CooldownScroll.Content
    local lastCategory = settings.previousCategory

    -- Blizzard has not built the category list yet.
    if not lastCategory then
        return
    end

    -- Blizzard rebuilds its category frames. Re-anchor
    -- our existing frame to the current final category.
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
    looperSettingsBlock:SetHeight(145)
    looperSettingsBlock:SetPoint(
        "TOPLEFT",
        lastCategory,
        "BOTTOMLEFT",
        0,
        -18
    )

    -- Match Blizzard's category header style.
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

    -- Prevent overlapping loop sounds.
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
        settingsHandler.GetPreventOverlapping()
    )

    overlapCheckBox:SetScript("OnClick", function(self)
        local enabled = self:GetChecked()

        settingsHandler.SetPreventOverlapping(enabled)
        playback.SetPreventOverlappingLoopSounds(enabled)
    end)

    -- Import character settings from account-wide storage.
    local importButton = CreateFrame(
        "Button",
        nil,
        looperSettingsBlock,
        "UIPanelButtonTemplate"
    )

    importButton:SetSize(145, 26)
    importButton:SetPoint(
        "TOPLEFT",
        overlapCheckBox,
        "BOTTOMLEFT",
        0,
        -10
    )
    importButton:SetText("Import")

    importButton:SetScript("OnClick", function()
        local imported, skipped = settingsHandler.Import()

        UIErrorsFrame:AddMessage(
            string.format(
                "CDMLooper: %d imported, %d skipped",
                imported,
                skipped
            ),
            0.3, 1, 0.3
        )
    end)

    -- Export character settings to account-wide storage.
    local exportButton = CreateFrame(
        "Button",
        nil,
        looperSettingsBlock,
        "UIPanelButtonTemplate"
    )

    exportButton:SetSize(145, 26)
    exportButton:SetPoint(
        "LEFT",
        importButton,
        "RIGHT",
        15,
        0
    )
    exportButton:SetText("Export")

    -- Allow overwriting existing account-wide exports.
    local overwriteCheckBox = CreateFrame(
        "CheckButton",
        nil,
        looperSettingsBlock,
        "UICheckButtonTemplate"
    )

    overwriteCheckBox:SetPoint(
        "TOPLEFT",
        importButton,
        "BOTTOMLEFT",
        0,
        -10
    )

    overwriteCheckBox.Text:SetText(
        "Overwrite existing exports"
    )

    overwriteCheckBox:SetChecked(overwriteExistingExports)

    overwriteCheckBox:SetScript("OnClick", function(self)
        overwriteExistingExports = self:GetChecked()
    end)

    exportButton:SetScript("OnClick", function()
        local exported, skipped = settingsHandler.Export(
            overwriteExistingExports
        )

        UIErrorsFrame:AddMessage(
            string.format(
                "CDMLooper: %d exported, %d skipped",
                exported,
                skipped
            ),
            0.3, 1, 0.3
        )
    end)

    -- Collapsible settings category.
    local function UpdateCollapsedState()
        local expanded = not looperSettingsCollapsed

        overlapCheckBox:SetShown(expanded)
        importButton:SetShown(expanded)
        exportButton:SetShown(expanded)
        overwriteCheckBox:SetShown(expanded)

        looperSettingsBlock:SetHeight(
            expanded and 145 or 22
        )

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

-- Blizzard Layout Manager Hooks --

local function InitializeLayoutManagerHooks()
    if layoutManagerHooksInitialized then
        return
    end

    local layoutManager =
        CooldownViewerSettings:GetLayoutManager()

    if not layoutManager then
        return
    end

    hooksecurefunc(
        layoutManager,
        "RemoveAlert",
        function(_, cooldownID, alert)
            settingsHandler.RemoveAlertSettings(
                cooldownID,
                alert
            )
        end
    )

    hooksecurefunc(
        layoutManager,
        "RemoveAllAlerts",
        function(_, cooldownID)
            settingsHandler.RemoveAllAlertSettings(
                cooldownID
            )
        end
    )

    layoutManagerHooksInitialized = true
end

-- CDM Alert Editor --

local function InitializeCDMLooperAlertUI()
    local editFrame = CooldownViewerSettingsEditAlert

    -- Original Blizzard frame is 310 x 385.
    -- Extend it to fit our additional settings.
    editFrame:SetHeight(500)

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

    -- Loop checkbox.
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

    -- Loop interval slider.
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
    alertIntervalSlider:SetValue(
        settingsHandler.GetDefaultLoopInterval()
    )
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

    -- Display CDMLooper controls for Sound alerts only.
    local function UpdateCDMLooperAlertUIVisibility()
        local alert = editFrame.workingCopyOfAlert

        if not alert then
            settingsLabel:Hide()
            alertLoopingCheckBox:Hide()
            alertIntervalSlider:Hide()
            return
        end

        local alertType = CooldownViewerAlert_GetType(alert)
        local show =
            alertType == Enum.CooldownViewerAlertType.Sound

        settingsLabel:SetShown(show)
        alertLoopingCheckBox:SetShown(show)
        alertIntervalSlider:SetShown(show)
    end

    -- Blizzard rebuilds its dropdowns when Type changes.
    hooksecurefunc(
        editFrame,
        "SetupDropdowns",
        function()
            UpdateCDMLooperAlertUIVisibility()
        end
    )

    -- Populate controls when editing or creating an alert.
    hooksecurefunc(
        editFrame,
        "DisplayForAlert",
        function(self, cooldownItem, alert, isNewAlert)
            currentEditCooldownID = self:GetCooldownID()
            currentOriginalAlertKey =
                settingsHandler.GetAlertKey(alert)

            local alertType =
                CooldownViewerAlert_GetType(alert)

            if alertType == Enum.CooldownViewerAlertType.Sound then
                local settings =
                    settingsHandler.GetOrCreateAlertSettings(
                        currentEditCooldownID,
                        alert
                    )

                alertLoopingCheckBox:SetChecked(
                    settings.looping
                )

                alertIntervalSlider:SetValue(
                    settings.interval
                    or settingsHandler.GetDefaultLoopInterval()
                )
            else
                -- Defaults if Visual is switched to Sound.
                alertLoopingCheckBox:SetChecked(false)
                alertIntervalSlider:SetValue(
                    settingsHandler.GetDefaultLoopInterval()
                )
            end

            UpdateSliderText()
            UpdateCDMLooperAlertUIVisibility()
        end
    )

    -- Blizzard's Apply Changes button commits the settings.
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

            settingsHandler.SaveAlertSettings(
                currentEditCooldownID,
                self.workingCopyOfAlert,
                currentOriginalAlertKey,
                alertLoopingCheckBox:GetChecked(),
                interval
            )

            currentOriginalAlertKey =
                settingsHandler.GetAlertKey(
                    self.workingCopyOfAlert
                )
        end
    )

    -- Remove orphaned entries when an unapplied
    -- newly-created alert is closed.
    editFrame:HookScript("OnHide", function()
        local cooldownID = currentEditCooldownID

        if not cooldownID then
            return
        end

        C_Timer.After(0, function()
            settingsHandler.PruneCooldownAlertSettings(
                cooldownID
            )
        end)
    end)
end

-- UI Hook Registration --

local function SetupUI()
    if uiHooksInitialized then
        return
    end

    uiHooksInitialized = true

    InitializeCDMLooperAlertUI()
    InitializeLayoutManagerHooks()

    -- The Layout Manager may not exist during ADDON_LOADED.
    -- Retry whenever Blizzard's settings frame opens.
    CooldownViewerSettings:HookScript(
        "OnShow",
        InitializeLayoutManagerHooks
    )

    -- Create or re-anchor the CDMLooper settings block.
    CooldownViewerSettings:HookScript("OnShow", function()
        C_Timer.After(
            0,
            InitializeCDMLooperSettingsBlock
        )
    end)

    hooksecurefunc(
        CooldownViewerSettings,
        "ClearDisplayCategories",
        function()
            C_Timer.After(
                0,
                InitializeCDMLooperSettingsBlock
            )
        end
    )
end

-- Interfaces --

function SettingsUI.Setup()
    SetupUI()
end