local ADDON_NAME, private = ...

local SettingsHandler = private.SettingsHandler
local Playback = private.Playback
local Alerts = private.Alerts
local SettingsUI = private.SettingsUI

-- Module Variables --

local function NoOp() end

local debugAPI = Alluneve
    and Alluneve.Debug
    and Alluneve.Debug.RegisterYourself(ADDON_NAME)

local debugInterface = debugAPI or {
    Print = NoOp,
    Log = NoOp,
}

local initialImportPromptShown = false
local initialImportRetryCount = 0
local MAX_INITIAL_IMPORT_RETRIES = 10

-- Business Logic --

-- First-Time Import --

local function ShowImportResult(message)
    UIErrorsFrame:AddMessage(
        "CDMLooper: " .. message,
        0.3, 1, 0.3
    )
end

StaticPopupDialogs["CDMLOOPER_INITIAL_IMPORT"] = {
    text =
        "CDMLooper found %d class-exported alerts and "
        .. "%d eligible legacy alerts.\n\n"
        .. "Import these settings for this character?",

    button1 = YES,
    button2 = NO,

    OnAccept = function()
        local tagged, legacy, skipped =
            SettingsHandler.ImportFirstTime()

        if tagged == nil then
            ShowImportResult(
                "Import failed: " .. tostring(legacy)
            )
            return
        end

        ShowImportResult(string.format(
            "%d imported, %d skipped",
            tagged + legacy,
            skipped
        ))
    end,

    OnCancel = function()
        SettingsHandler.SkipFirstImport()
    end,

    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function TryInitialImport()
    if not SettingsHandler.NeedsInitialImport()
        or initialImportPromptShown
        or InCombatLockdown() then
        return
    end

    local tagged, legacy, ready =
        SettingsHandler.GetInitialImportCounts()

    -- Legacy migration needs Cooldown Viewer data.
    -- Allow Blizzard some time to initialize it.
    if not ready then
        if initialImportRetryCount < MAX_INITIAL_IMPORT_RETRIES then
            initialImportRetryCount =
                initialImportRetryCount + 1

            C_Timer.After(2, TryInitialImport)
        end

        return
    end

    -- No applicable entries: no reason to prompt.
    if tagged + legacy == 0 then
        SettingsHandler.SkipFirstImport()
        return
    end

    local dialog = StaticPopup_Show(
        "CDMLOOPER_INITIAL_IMPORT",
        tagged,
        legacy
    )

    if dialog then
        initialImportPromptShown = true
    end
end

-- Slash Commands --

local function HandleDebugCommand(action)
    if not debugAPI then
        print(
            "CDMLooper: Debug addon is not loaded. "
            .. "Enable Alluneve-Debug and reload."
        )
        return
    end

    if action == "print" then
        local enabled = debugAPI.ToggleDebugPrint()

        print(
            "CDMLooper: Debug printing "
            .. (enabled and "enabled." or "disabled.")
        )
    elseif action == "log" then
        local enabled = debugAPI.ToggleDebugLog()

        print(
            "CDMLooper: Debug logging "
            .. (enabled and "enabled." or "disabled.")
        )
    elseif action == "submit" then
        debugAPI.SubmitLog()
        print("CDMLooper: Debug log submitted to BugGrabber.")
    else
        print(
            "CDMLooper: /cdml debug print | log | submit"
        )
    end
end

local function HandleLegacyCommand(action)
    if action == "check" then
        SettingsHandler.CheckLegacy()
    elseif action == "migrate" then
        local migrated, skipped =
            SettingsHandler.MigrateLegacy()

        if migrated == nil then
            print(
                "CDMLooper: Legacy migration unavailable: "
                .. tostring(skipped)
            )
            return
        end

        print(string.format(
            "CDMLooper: %d legacy alerts migrated, %d skipped.",
            migrated,
            skipped
        ))
    else
        print(
            "CDMLooper: /cdml legacy check | migrate"
        )
    end
end

local function HandleSlashCommand(message)
    local command, action =
        message:lower():match("^%s*(%S*)%s*(%S*)")

    if command == "debug" then
        HandleDebugCommand(action)
    elseif command == "legacy" then
        HandleLegacyCommand(action)
    else
        print("CDMLooper commands:")
        print("  /cdml debug print | log | submit")
        print("  /cdml legacy check | migrate")
    end
end

-- Initialization --

local function Initialize()
    LooperDB = LooperDB or {}
    LooperProfileDB = LooperProfileDB or {}

    local _, classToken = UnitClass("player")

    SettingsHandler.Initialize({
        database = LooperDB,
        characterDatabase = LooperProfileDB,
        playerClass = classToken,
    })

    Playback.Initialize({
        preventOverlappingLoopSounds =
            SettingsHandler.GetPreventOverlapping(),
        settingsHandler = SettingsHandler,
        debugInterface = debugInterface,
    })

    Alerts.Initialize({
        playback = Playback,
        debugInterface = debugInterface,
    })

    SettingsUI.Initialize({
        settingsHandler = SettingsHandler,
        playback = Playback,
    })

    SettingsHandler.CleanupEmptyAlertSettings()

    SettingsUI.Setup()

    -- Observe Blizzard's original alert playback without
    -- replacing or interfering with its implementation.
    hooksecurefunc(
        "CooldownViewerAlert_PlayAlert",
        Alerts.HandleCDMAlert
    )

    SLASH_CDMLOOPER1 = "/cdml"
    SlashCmdList.CDMLOOPER = HandleSlashCommand
end

-- Event Handling --

local eventFrame = CreateFrame("Frame")

eventFrame:RegisterEvent("ADDON_LOADED")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...

        if loadedAddon == ADDON_NAME then
            Initialize()

            self:RegisterEvent("PLAYER_ENTERING_WORLD")
            self:RegisterEvent("PLAYER_REGEN_DISABLED")
            self:RegisterEvent("PLAYER_REGEN_ENABLED")
            self:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")

            self:RegisterEvent("SOUNDKIT_FINISHED")
            self:RegisterEvent("VOICE_CHAT_TTS_PLAYBACK_STARTED")
            self:RegisterEvent("VOICE_CHAT_TTS_PLAYBACK_FINISHED")
            self:RegisterEvent("VOICE_CHAT_TTS_PLAYBACK_FAILED")
            self:RegisterEvent("VOICE_CHAT_TTS_SPEAK_TEXT_UPDATE")

            if UnitAffectingCombat("player") then
                Alerts.OnCombatStart()
            end
            self:UnregisterEvent("ADDON_LOADED")
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(1, TryInitialImport)
    elseif event == "PLAYER_REGEN_DISABLED" then
        Alerts.OnCombatStart()
    elseif event == "PLAYER_REGEN_ENABLED" then
        Alerts.OnCombatEnd()
        TryInitialImport()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellID = ...

        if unit == "player" then
            Alerts.OnSpellFired(spellID)
        end
    else
        -- Playback owns dispatching of the sound and TTS
        -- events registered above.
        Playback.HandleEvent(event, ...)
    end
end)
