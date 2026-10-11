local _, private = ...
local SettingsHandler = {}

local database
local characterDatabase
local classToken


-- Constructor --

---@param params { database: table, characterDatabase: table, playerClass: string }
function SettingsHandler.Initialize(params)
    database = params.database
    characterDatabase = params.characterDatabase
    classToken = params.playerClass

    -- Account-wide configuration
    if database.PreventOverlappingLoopSounds == nil then
        database.PreventOverlappingLoopSounds = true
    end

    database.Exports = database.Exports or {}

    -- Character-specific configuration
    characterDatabase.Alerts = characterDatabase.Alerts or {}
end


private.SettingsHandler = SettingsHandler

-- Module Variables --

local DEFAULT_LOOP_INTERVAL = 3

-- Implementation --

-- Alert configuration --

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
    local alerts = characterDatabase.Alerts[cooldownID]

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

    characterDatabase.Alerts[cooldownID] =
        characterDatabase.Alerts[cooldownID] or {}

    characterDatabase.Alerts[cooldownID][alertKey] = {
        looping = false,
        interval = DEFAULT_LOOP_INTERVAL,
    }

    return characterDatabase.Alerts[cooldownID][alertKey]
end

local function SaveAlertSettings(
    cooldownID,
    alert,
    oldAlertKey,
    looping,
    interval
)
    local alerts = characterDatabase.Alerts[cooldownID]
    local newAlertKey = GetAlertKey(alert)
    local alertType = CooldownViewerAlert_GetType(alert)

    -- CDMLooper only supports Sound alerts.
    if alertType ~= Enum.CooldownViewerAlertType.Sound then
        if alerts then
            if oldAlertKey then
                alerts[oldAlertKey] = nil
            end

            alerts[newAlertKey] = nil

            if not next(alerts) then
                characterDatabase.Alerts[cooldownID] = nil
            end
        end

        return
    end

    characterDatabase.Alerts[cooldownID] = alerts or {}
    alerts = characterDatabase.Alerts[cooldownID]

    -- Remove the old key if Type / When / Payload changed.
    if oldAlertKey and oldAlertKey ~= newAlertKey then
        alerts[oldAlertKey] = nil
    end

    alerts[newAlertKey] = {
        looping = not not looping,
        interval = interval or DEFAULT_LOOP_INTERVAL,
    }
end

local function RemoveAlertSettings(cooldownID, alert)
    local alerts = characterDatabase.Alerts[cooldownID]

    if not alerts then
        return
    end

    local alertKey = GetAlertKey(alert)
    local layoutManager = CooldownViewerSettings:GetLayoutManager()

    -- Identical Blizzard alerts share one settings entry.
    -- Only remove it if no identical alert remains.
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
        characterDatabase.Alerts[cooldownID] = nil
    end
end

local function RemoveAllAlertSettings(cooldownID)
    characterDatabase.Alerts[cooldownID] = nil
end

local function PruneCooldownAlertSettings(cooldownID)
    local alerts = characterDatabase.Alerts[cooldownID]

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
        characterDatabase.Alerts[cooldownID] = nil
    end
end

local function CleanupEmptyAlertSettings()
    for cooldownID, alerts in pairs(characterDatabase.Alerts) do
        if not next(alerts) then
            characterDatabase.Alerts[cooldownID] = nil
        end
    end
end

-- Shared import/export utilities --

local function CountAlertEntries(source, eligibleIDs)
    local count = 0

    if type(source) ~= "table" then
        return count
    end

    for cooldownID, alerts in pairs(source) do
        if not eligibleIDs or eligibleIDs[cooldownID] then
            if type(alerts) == "table" then
                for _, settings in pairs(alerts) do
                    if type(settings) == "table" then
                        count = count + 1
                    end
                end
            end
        end
    end

    return count
end

-- Move individual alert entries without overwriting.
-- Successfully moved entries are deleted from the source.
local function MoveAlertEntries(source, destination, eligibleIDs)
    local imported = 0
    local skipped = 0

    if type(source) ~= "table" then
        return imported, skipped
    end

    for cooldownID, sourceAlerts in pairs(source) do
        if (not eligibleIDs or eligibleIDs[cooldownID])
            and type(sourceAlerts) == "table" then

            local destinationAlerts = destination[cooldownID]

            if destinationAlerts == nil then
                destinationAlerts = {}
                destination[cooldownID] = destinationAlerts
            end

            if type(destinationAlerts) == "table" then
                for alertKey, settings in pairs(sourceAlerts) do
                    if type(settings) == "table" then
                        if destinationAlerts[alertKey] == nil then
                            destinationAlerts[alertKey] = CopyTable(settings)
                            sourceAlerts[alertKey] = nil
                            imported = imported + 1
                        else
                            skipped = skipped + 1
                        end
                    end
                end
            end

            if not next(sourceAlerts) then
                source[cooldownID] = nil
            end
        end
    end

    return imported, skipped
end

-- Class-tagged account-wide import/export --

local function ExportClassAlerts(overwrite)
    database.Exports[classToken] = database.Exports[classToken] or {}

    local destination = database.Exports[classToken]
    local exported = 0
    local skipped = 0

    for cooldownID, alerts in pairs(characterDatabase.Alerts) do
        if type(alerts) == "table" then
            local destinationAlerts = destination[cooldownID]

            if destinationAlerts == nil then
                destinationAlerts = {}
                destination[cooldownID] = destinationAlerts
            end

            if type(destinationAlerts) == "table" then
                for alertKey, settings in pairs(alerts) do
                    if type(settings) == "table" then
                        if overwrite or destinationAlerts[alertKey] == nil then
                            destinationAlerts[alertKey] = CopyTable(settings)
                            exported = exported + 1
                        else
                            skipped = skipped + 1
                        end
                    end
                end
            end
        end
    end

    return exported, skipped
end

local function ImportClassAlerts()
    local source = database.Exports[classToken]

    local imported, skipped = MoveAlertEntries(
        source,
        characterDatabase.Alerts
    )

    if type(source) == "table" and not next(source) then
        database.Exports[classToken] = nil
    end

    return imported, skipped
end

-- Legacy migration --

local function IsSecret(value)
    return issecretvalue and issecretvalue(value)
end

-- Discover cooldowns belonging to the currently active
-- specialization, including unlearned cooldowns.
--
-- Exclude equipment and item-based entries to avoid
-- claiming generic item cooldowns for a character class.
--
-- Returns eligibleIDs, ready.
local function FindLegacyEligibleCooldowns()
    if InCombatLockdown() then
        return nil, false
    end

    if not C_CooldownViewer
        or not C_CooldownViewer.GetCooldownViewerCategorySet
        or not C_CooldownViewer.GetCooldownViewerCooldownInfo
        or not Enum.CooldownViewerCategory then
        return nil, false
    end

    if C_CooldownViewer.IsCooldownViewerAvailable then
        if not C_CooldownViewer.IsCooldownViewerAvailable() then
            return nil, false
        end
    end

    local eligibleIDs = {}
    local dataReady = false

    for categoryName, category in pairs(Enum.CooldownViewerCategory) do
        if type(category) == "number"
            and categoryName ~= "EquipSlotEssential"
            and categoryName ~= "EquipSlotTracked" then

            local cooldownIDs =
                C_CooldownViewer.GetCooldownViewerCategorySet(
                    category,
                    true
                )

            if cooldownIDs and not IsSecret(cooldownIDs) then
                dataReady = true

                for _, cooldownID in ipairs(cooldownIDs) do
                    if not IsSecret(cooldownID)
                        and database.Alerts[cooldownID] then

                        local info =
                            C_CooldownViewer.GetCooldownViewerCooldownInfo(
                                cooldownID
                            )

                        if info and not IsSecret(info) then
                            local spellID = info.spellID
                            local equipSlot = info.equipSlot
                            local buffSlot = info.buffSlot
                            local spellCategoryID = info.spellCategoryID

                            if not IsSecret(spellID)
                                and type(spellID) == "number"
                                and not IsSecret(equipSlot)
                                and not IsSecret(buffSlot)
                                and not IsSecret(spellCategoryID)
                                and equipSlot == nil
                                and buffSlot == nil
                                and spellCategoryID == nil then

                                eligibleIDs[cooldownID] = true
                            end
                        end
                    end
                end
            end
        end
    end

    return eligibleIDs, dataReady
end

-- Reusable legacy migration implementation.
-- First-time import and manual migration call this.
local function MigrateLegacyAlerts(eligibleIDs)
    if type(database.Alerts) ~= "table" or not next(database.Alerts) then
        return 0, 0
    end

    if not eligibleIDs then
        local ready
        eligibleIDs, ready = FindLegacyEligibleCooldowns()

        if not ready then
            return nil, "Cooldown Viewer data is not ready"
        end
    end

    return MoveAlertEntries(
        database.Alerts,
        characterDatabase.Alerts,
        eligibleIDs
    )
end

-- Print every remaining legacy alert, including entries
-- that cannot be identified in the current specialization.
local function CheckLegacyAlerts()
    if type(database.Alerts) ~= "table" or not next(database.Alerts) then
        print("CDMLooper: No legacy alerts remaining.")
        return 0
    end

    local cooldownIDs = {}

    for cooldownID in pairs(database.Alerts) do
        table.insert(cooldownIDs, cooldownID)
    end

    table.sort(cooldownIDs, function(a, b)
        if type(a) == "number" and type(b) == "number" then
            return a < b
        end
        return tostring(a) < tostring(b)
    end)

    local count = 0

    print("=== CDMLooper Legacy Account-Wide Alerts ===")

    for _, cooldownID in ipairs(cooldownIDs) do
        local alerts = database.Alerts[cooldownID]

        if type(alerts) == "table" then
            for alertKey, settings in pairs(alerts) do
                count = count + 1

                if type(settings) == "table" then
                    print(string.format(
                        "CooldownID: %s | Alert: %s | Loop: %s | Interval: %s",
                        tostring(cooldownID),
                        tostring(alertKey),
                        tostring(settings.looping),
                        tostring(settings.interval)
                    ))
                else
                    print(string.format(
                        "CooldownID: %s | Alert: %s | Invalid settings",
                        tostring(cooldownID),
                        tostring(alertKey)
                    ))
                end
            end
        else
            count = count + 1

            print(string.format(
                "CooldownID: %s | Invalid alert collection",
                tostring(cooldownID)
            ))
        end
    end

    print(string.format(
        "=== %d legacy entries remaining ===",
        count
    ))

    return count
end

-- First-time character setup --

local function GetInitialImportCounts()
    local tagged = CountAlertEntries(database.Exports[classToken])
    local legacy = 0

    if type(database.Alerts) == "table" and next(database.Alerts) then
        local eligibleIDs, ready = FindLegacyEligibleCooldowns()

        if not ready then
            return tagged, 0, false
        end

        legacy = CountAlertEntries(database.Alerts, eligibleIDs)
    end

    return tagged, legacy, true
end

local function ImportFirstTime()
    if characterDatabase.InitialImportHandled then
        return 0, 0, 0
    end

    local eligibleIDs

    if type(database.Alerts) == "table" and next(database.Alerts) then
        local ready
        eligibleIDs, ready = FindLegacyEligibleCooldowns()

        if not ready then
            return nil, "Cooldown Viewer data is not ready"
        end
    end

    -- Class-tagged exports take priority.
    local taggedImported, taggedSkipped = ImportClassAlerts()

    -- Attempt legacy migration only during initial setup.
    local legacyImported, legacySkipped = MigrateLegacyAlerts(
        eligibleIDs
    )

    characterDatabase.InitialImportHandled = true

    return taggedImported, legacyImported,
        taggedSkipped + legacySkipped
end

local function SkipFirstImport()
    characterDatabase.InitialImportHandled = true
end

-- Interfaces --

function SettingsHandler.GetDefaultLoopInterval()
    return DEFAULT_LOOP_INTERVAL
end

-- Alert configuration --

---@param cooldownID number
---@param alert table
function SettingsHandler.GetAlertSettings(cooldownID, alert)
    return GetAlertSettings(cooldownID, alert)
end

---@param cooldownID number
---@param alert table
function SettingsHandler.GetOrCreateAlertSettings(cooldownID, alert)
    return GetOrCreateAlertSettings(cooldownID, alert)
end

---@param alert table
---@return string
function SettingsHandler.GetAlertKey(alert)
    return GetAlertKey(alert)
end

function SettingsHandler.SaveAlertSettings(
    cooldownID,
    alert,
    oldAlertKey,
    looping,
    interval
)
    SaveAlertSettings(
        cooldownID,
        alert,
        oldAlertKey,
        looping,
        interval
    )
end

function SettingsHandler.RemoveAlertSettings(cooldownID, alert)
    RemoveAlertSettings(cooldownID, alert)
end

function SettingsHandler.RemoveAllAlertSettings(cooldownID)
    RemoveAllAlertSettings(cooldownID)
end

function SettingsHandler.PruneCooldownAlertSettings(cooldownID)
    PruneCooldownAlertSettings(cooldownID)
end

function SettingsHandler.CleanupEmptyAlertSettings()
    CleanupEmptyAlertSettings()
end

-- Account-wide configuration --

---@return boolean
function SettingsHandler.GetPreventOverlapping()
    return database.PreventOverlappingLoopSounds
end

---@param enabled boolean
function SettingsHandler.SetPreventOverlapping(enabled)
    database.PreventOverlappingLoopSounds = enabled
end

-- Class-tagged import/export --

---@param overwrite? boolean
---@return number, number
function SettingsHandler.Export(overwrite)
    return ExportClassAlerts(overwrite)
end

---@return number, number
function SettingsHandler.Import()
    return ImportClassAlerts()
end

-- First-time setup --

---@return boolean
function SettingsHandler.NeedsInitialImport()
    return not characterDatabase.InitialImportHandled
end

---@return number, number, boolean
function SettingsHandler.GetInitialImportCounts()
    return GetInitialImportCounts()
end

function SettingsHandler.ImportFirstTime()
    return ImportFirstTime()
end

function SettingsHandler.SkipFirstImport()
    SkipFirstImport()
end

-- Manual legacy operations --

---@return number
function SettingsHandler.CheckLegacy()
    return CheckLegacyAlerts()
end

---@return number|nil, number|string
function SettingsHandler.MigrateLegacy()
    return MigrateLegacyAlerts()
end