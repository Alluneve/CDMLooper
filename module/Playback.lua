local _, private = ...
local Playback = {}

local preventOverlappingLoopSounds
local settingsHandler
local debug

-- Constructor --

---@param params { preventOverlappingLoopSounds: boolean, settingsHandler: table, debugInterface: table }
function Playback.Initialize(params)
    preventOverlappingLoopSounds = params.preventOverlappingLoopSounds
    settingsHandler = params.settingsHandler
    debug = params.debugInterface
end

private.Playback = Playback

-- Module Variables --

local activeLoops = {}

local activeLoopPlaybackType = nil
local activeLoopSoundHandle = nil
local activeLoopPlaybackSpellID = nil
local activeLoopTTSUtteranceID = nil
local waitingForLoopTTSRequest = false

local pendingLoopAlerts = {}
local queuedLoopAlerts = {}

-- Implementation --

local function PlayQueuedLoopAlert(pending)
    local alertType = CooldownViewerAlert_GetType(pending.alert)
    local payload = CooldownViewerAlert_GetPayload(pending.alert)

    if not alertType or issecretvalue(alertType) then
        debug.Print("PlayQueuedLoopAlert", "AlertType is secret")
        return false
    end

    if payload == nil or issecretvalue(payload) then
        debug.Print("PlayQueuedLoopAlert", "Payload is secret")
        return false
    end

    if alertType ~= Enum.CooldownViewerAlertType.Sound then
        return false
    end

    local success = false

    if payload == Enum.CooldownViewerSound.TextToSpeech then
        local voiceID =
            C_TTSSettings.GetVoiceOptionID(Enum.TtsVoiceType.Standard)

        if not voiceID then
            return false
        end

        if preventOverlappingLoopSounds then
            activeLoopPlaybackType = "tts"
            activeLoopSoundHandle = nil
            activeLoopPlaybackSpellID = pending.spellID
            activeLoopTTSUtteranceID = nil
            waitingForLoopTTSRequest = true
        end

        C_VoiceChat.SpeakText(
            voiceID,
            pending.spellName,
            C_TTSSettings.GetSpeechRate(),
            C_TTSSettings.GetSpeechVolume(),
            not preventOverlappingLoopSounds
        )

        waitingForLoopTTSRequest = false

        if preventOverlappingLoopSounds
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
            debug.Print("PlayQueuedLoopAlert", "SoundKit is secret")
            return false
        end

        local soundHandle

        success, soundHandle = C_Sound.PlaySoundWithOptions({
            soundKitID = soundKit,
            uiSoundSubType = pending.soundSubType,
            runFinishCallback = preventOverlappingLoopSounds,
        })

        if success and preventOverlappingLoopSounds then
            activeLoopPlaybackType = "sound"
            activeLoopSoundHandle = soundHandle
            activeLoopPlaybackSpellID = pending.spellID
            waitingForLoopTTSRequest = false
        end
    end

    return success
end

local function ProcessPendingLoopAlerts()
    if preventOverlappingLoopSounds
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
                    and preventOverlappingLoopSounds
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
        debug.Log("QueueLoopedAlert", "SpellID is secret")
        return
    end

    -- Already waiting in the queue.
    if queuedLoopAlerts[spellID] then
        return
    end

    -- Don't queue another reminder for a spell
    -- while its previous reminder is playing.
    if preventOverlappingLoopSounds
        and activeLoopPlaybackSpellID == spellID then
        return
    end

    local spellName = C_Spell.GetSpellName(spellID)

    if not spellName or issecretvalue(spellName) then
        debug.Print("QueueLoopedAlert", "SpellName is secret")
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

    ProcessPendingLoopAlerts()
end

local function StopLoop(spellID)
    debug.Print("StopLoop", "spellID secret:", issecretvalue(spellID))

    if issecretvalue(spellID) then
        return
    end

    local ticker = activeLoops[spellID]

    if ticker then
        ticker:Cancel()
        activeLoops[spellID] = nil
    end

    -- The processor will ignore stale FIFO entries.
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

local function CreateSound(
    cooldownID,
    spellID,
    cooldownItem,
    alert,
    soundSubType
)
    local settings = settingsHandler.GetAlertSettings(cooldownID, alert)

    if not settings or not settings.looping then
        return
    end

    StopLoop(spellID)

    activeLoops[spellID] = C_Timer.NewTicker(
        settings.interval,
        function()
            debug.Print("Loop tick", spellID)

            QueueLoopedAlert(
                spellID,
                cooldownItem,
                alert,
                soundSubType
            )
        end
    )
end

-- Playback event implementations --

local function OnLoopSoundFinished(soundHandle)
    if soundHandle ~= activeLoopSoundHandle then
        return
    end

    activeLoopPlaybackType = nil
    activeLoopSoundHandle = nil
    activeLoopPlaybackSpellID = nil

    ProcessPendingLoopAlerts()
end

local function OnLoopTTSStarted(utteranceID)
    if activeLoopPlaybackType ~= "tts"
        or utteranceID ~= activeLoopTTSUtteranceID then
        return
    end

    debug.Print("Our TTS started:", utteranceID)
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

    debug.Print(
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

local PLAYBACK_EVENT_HANDLERS = {
    ["SOUNDKIT_FINISHED"] = OnLoopSoundFinished,
    ["VOICE_CHAT_TTS_PLAYBACK_STARTED"] = OnLoopTTSStarted,
    ["VOICE_CHAT_TTS_PLAYBACK_FINISHED"] = OnLoopTTSFinished,
    ["VOICE_CHAT_TTS_PLAYBACK_FAILED"] = OnLoopTTSFailed,
    ["VOICE_CHAT_TTS_SPEAK_TEXT_UPDATE"] = OnLoopTTSSpeakTextUpdate,
}

local function HandlePlaybackEvent(event, ...)
    local handler = PLAYBACK_EVENT_HANDLERS[event]

    if handler then
        handler(...)
    end
end

---@param value boolean
local function SetPreventOverlappingLoopSounds(value)
    preventOverlappingLoopSounds = value
end

-- Interfaces --

---@param cooldownID number
---@param spellID number
---@param cooldownItem table
---@param alert table
---@param soundSubType number
function Playback.StartLoop(
    cooldownID,
    spellID,
    cooldownItem,
    alert,
    soundSubType
)
    CreateSound(
        cooldownID,
        spellID,
        cooldownItem,
        alert,
        soundSubType
    )
end

---@param spellID number
function Playback.StopLoop(spellID)
    StopLoop(spellID)
end

function Playback.StopAllLoops()
    StopAllLoops()
end

---@param event string
function Playback.HandleEvent(event, ...)
    HandlePlaybackEvent(event, ...)
end

---@param value boolean
function Playback.SetPreventOverlappingLoopSounds(value)
    SetPreventOverlappingLoopSounds(value)
end