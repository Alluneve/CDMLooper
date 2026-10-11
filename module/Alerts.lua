local _, private = ...
local Alerts = {}

local playback
local debug

-- Constructor --

---@param params { playback: table, debugInterface: table }
function Alerts.Initialize(params)
    playback = params.playback
    debug = params.debugInterface
end

private.Alerts = Alerts

-- Module Variables --

local BLIZZ_ALERT_EVENT_TYPE = Enum.CooldownViewerAlertEventType

local RACE_CONDITION_TIMER = 0.30

local raceConditionCleanupTicker
local raceConditionList = {}

-- Implementation --

-- Cooldown identification --

local function SafeFetchIDs(cooldownItem)
    local cooldownID = cooldownItem:GetCooldownID()
    local spellID = cooldownItem:GetBaseSpellID()

    if issecretvalue(spellID) then
        debug.Log("SafeFetchIDs", "SpellID is secret")
    else
        debug.Print("SafeFetchIDs", "SpellID:", spellID)
    end

    if issecretvalue(cooldownID) then
        debug.Log("SafeFetchIDs", "CooldownID is secret")
    else
        debug.Print("SafeFetchIDs", "CooldownID:", cooldownID)
    end

    if not spellID or issecretvalue(spellID)
        or not cooldownID or issecretvalue(cooldownID) then
        return nil, nil
    end

    return spellID, cooldownID
end

-- Race condition handling --

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

-- CDM Alert Event Handlers --

local function OnAvailable(cooldownItem, _, alert, soundSubType)
    local spellID, cooldownID = SafeFetchIDs(cooldownItem)

    if not spellID or not cooldownID then
        return
    end

    if cooldownItem:IsEquippedItem() then
        local equipSlot = cooldownItem:GetEquipSlot()
        local start, duration =
            GetInventoryItemCooldown("player", equipSlot)

        if start > 0 and duration > 0 then
            debug.Print(
                "OnAvailable",
                "Trinket still on cooldown"
            )
            return
        end
    end

    local chargeInfo = C_Spell.GetSpellCharges(spellID)

    if chargeInfo and chargeInfo.isActive then
        debug.Print(
            "OnAvailable",
            "Spell is still actively charging, quick returning"
        )
        return
    end

    if RaceConditionCheck(spellID) then
        playback.StartLoop(
            cooldownID,
            spellID,
            cooldownItem,
            alert,
            soundSubType
        )
    end
end

local function OnPandemicTime(cooldownItem, _, alert, soundSubType)
    local spellID, cooldownID = SafeFetchIDs(cooldownItem)

    if not spellID or not cooldownID then
        return
    end

    if RaceConditionCheck(spellID) then
        playback.StartLoop(
            cooldownID,
            spellID,
            cooldownItem,
            alert,
            soundSubType
        )
    end
end

local function OnCooldown(cooldownItem, _, alert, soundSubType)
    local spellID, cooldownID = SafeFetchIDs(cooldownItem)

    if not spellID or not cooldownID then
        return
    end

    if cooldownItem:IsEquippedItem() then
        local equipSlot = cooldownItem:GetEquipSlot()
        local start, duration =
            GetInventoryItemCooldown("player", equipSlot)

        if start > 0 and duration > 0 then
            debug.Print(
                "OnCooldown",
                "Trinket still on cooldown"
            )
            return
        end
    end

    if RaceConditionCheck(spellID) then
        playback.StartLoop(
            cooldownID,
            spellID,
            cooldownItem,
            alert,
            soundSubType
        )
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
        playback.StartLoop(
            cooldownID,
            spellID,
            cooldownItem,
            alert,
            soundSubType
        )
    end
end

local function OnAuraApplied(cooldownItem, _, alert, soundSubType)
    local spellID, cooldownID = SafeFetchIDs(cooldownItem)

    if not spellID or not cooldownID then
        return
    end

    if RaceConditionCheck(spellID) then
        playback.StartLoop(
            cooldownID,
            spellID,
            cooldownItem,
            alert,
            soundSubType
        )
    end
end

local function OnAuraRemoved(cooldownItem, _, alert, soundSubType)
    local spellID, cooldownID = SafeFetchIDs(cooldownItem)

    if not spellID or not cooldownID then
        return
    end

    if RaceConditionCheck(spellID) then
        playback.StartLoop(
            cooldownID,
            spellID,
            cooldownItem,
            alert,
            soundSubType
        )
    end
end

-- CDM Alert Dispatching --

local CDM_EVENT_HANDLERS = {
    [BLIZZ_ALERT_EVENT_TYPE.Available] = OnAvailable,
    [BLIZZ_ALERT_EVENT_TYPE.PandemicTime] = OnPandemicTime,
    [BLIZZ_ALERT_EVENT_TYPE.OnCooldown] = OnCooldown,
    [BLIZZ_ALERT_EVENT_TYPE.ChargeGained] = OnChargeGained,
    [BLIZZ_ALERT_EVENT_TYPE.OnAuraApplied] = OnAuraApplied,
    [BLIZZ_ALERT_EVENT_TYPE.OnAuraRemoved] = OnAuraRemoved,
}

local function OnCDMAlertEvent(
    cooldownItem,
    spellName,
    alert,
    soundSubType
)
    if not cooldownItem then
        debug.Print(
            "OnCDMAlertEvent",
            "cooldownItem is nil, quick returning"
        )
        return
    end

    debug.Print(
        "OnCDMAlertEvent",
        "cooldownItem:",
        issecretvalue(cooldownItem) and "<secret>" or cooldownItem,
        "spellName:",
        issecretvalue(spellName) and "<secret>" or spellName,
        "alert:",
        issecretvalue(alert) and "<secret>" or alert
    )

    -- Ignore previews from the CDM settings item.
    if cooldownItem.PlayAlertSample then
        return
    end

    -- Ignore the preview button inside the alert editor.
    if cooldownItem == CooldownViewerSettingsEditAlert then
        return
    end

    -- Do nothing outside combat.
    if not UnitAffectingCombat("player") then
        return
    end

    local eventType = CooldownViewerAlert_GetEvent(alert)

    if eventType == nil or issecretvalue(eventType) then
        return
    end

    debug.Print(
        "OnCDMAlertEvent",
        "eventType:",
        eventType
    )

    local handler = CDM_EVENT_HANDLERS[eventType]

    if handler then
        handler(
            cooldownItem,
            spellName,
            alert,
            soundSubType
        )
    end
end

-- Runtime Handling --

local function OnSpellFired(spellID)
    if not UnitAffectingCombat("player") then
        return
    end

    if issecretvalue(spellID) then
        debug.Log(
            "OnSpellFired",
            "spellID secret:",
            true,
            "quick returning"
        )
        return
    end

    debug.Print("OnSpellFired", "SpellID:", spellID)

    local baseSpellID = C_Spell.GetBaseSpell(spellID)

    if not baseSpellID or issecretvalue(baseSpellID) then
        return
    end

    debug.Print(
        "OnSpellFired",
        "BaseSpellID:",
        baseSpellID
    )

    raceConditionList[baseSpellID] =
        GetTimePreciseSec() + RACE_CONDITION_TIMER

    playback.StopLoop(baseSpellID)
end

local function OnCombatStart()
    if not raceConditionCleanupTicker then
        raceConditionCleanupTicker = C_Timer.NewTicker(
            60,
            RaceConditionCleanup
        )
    end
end

local function OnCombatEnd()
    playback.StopAllLoops()

    if raceConditionCleanupTicker then
        raceConditionCleanupTicker:Cancel()
        raceConditionCleanupTicker = nil
    end

    wipe(raceConditionList)
end

-- Interfaces --

function Alerts.HandleCDMAlert(
    cooldownItem,
    spellName,
    alert,
    soundSubType
)
    OnCDMAlertEvent(
        cooldownItem,
        spellName,
        alert,
        soundSubType
    )
end

---@param spellID number
function Alerts.OnSpellFired(spellID)
    OnSpellFired(spellID)
end

function Alerts.OnCombatStart()
    OnCombatStart()
end

function Alerts.OnCombatEnd()
    OnCombatEnd()
end