--[[
Flow:
-> QuestieValidateGameCache.StartCheck()
--> Wait for PLAYER_ENTERING_WORLD
---> Wait For QUEST_LOG_UPDATE (2x at login, 1x at reload)
----> Game cache should have all quests in it, data of each quest may be invalid.
      If data is invalid, Wait for next QUEST_LOG_UPDATE and check again.
-----> Game Cache ok. Call possible callback functions.
]]--

---@class QuestieValidateGameCache
local QuestieValidateGameCache = QuestieLoader:CreateModule("QuestieValidateGameCache")


---@type QuestieLib
local QuestieLib = QuestieLoader:CreateModule("QuestieLib")

--- COMPATIBILITY ---
local GetNumQuestLogEntries = GetNumQuestLogEntries
local GetQuestLogTitle = QuestieCompat.GetQuestLogTitle
local GetQuestObjectives = QuestieCompat.C_QuestLog.GetQuestObjectives
local HaveQuestData = QuestieCompat.HaveQuestData

local stringByte, tremove = string.byte, table.remove
local tpack =  QuestieLib.tpack
local tunpack = QuestieLib.tunpack

-- 3 * (Max possible number of quests in game quest log)
-- This is a safe value, even smaller would be enough. Too large won't effect performance
local MAX_QUEST_LOG_INDEX = 75

local eventFrame
local numberOfQuestLogUpdatesToSkip
local checkStarted = false

local isCacheGood = false
local callbacks = {} -- example: { [1] = {func, {arg1, arg2, arg3}}, [2] = {func, {arg1, arg2}}, }

-- Some private servers can provide malformed quest log data (e.g. C_QuestLog.GetQuestObjectives
-- returning nil/non-table for custom quests). Those quests must not block Questie from loading.
local brokenQuestIds = {}

---@return boolean
function QuestieValidateGameCache.IsCacheGood()
    return isCacheGood
end

--- Calls the callback function imediately if the cache is already good.
--- Otherwise adds it to list of functions called once the cache comes good.
---@param func function @A function to call once cache is good.
---@param ... any @Possible arguments for function.
function QuestieValidateGameCache.AddCallback(func, ...)
    if isCacheGood then
        Questie:Debug(Questie.DEBUG_DEVELOP, "[QuestieValidateGameCache] Calling a callback function imediately.")
        func(...)
    else
        callbacks[#callbacks+1] = {func, tpack(...)}
    end
end


local function DestroyEventFrame()
    if eventFrame then
        eventFrame:UnregisterAllEvents()
        eventFrame:SetScript("OnEvent", nil)
        eventFrame:SetParent(nil)
        eventFrame = nil
    end
end

-- Called directly and OnEvent.
local function OnQuestLogUpdate()
    local numEntries, numQuests = GetNumQuestLogEntries()

    -- Player can have 0 quests in quest log for real OR game's cached quest log can be empty while cache is still invalid
    -- This is to wait until cache has atleast some refreshed data from a game server.
    if numberOfQuestLogUpdatesToSkip > 0 then
        numberOfQuestLogUpdatesToSkip = numberOfQuestLogUpdatesToSkip - 1
        Questie:Debug(Questie.DEBUG_DEVELOP, "[QuestieValidateGameCache] Skipping a QUEST_LOG_UPDATE event. Quest log has entries, quests:", numEntries, numQuests)
        return
    end

    local isQuestLogGood = true
    local goodQuestsCount = 0 -- for debug stats
    local brokenEntriesCount = 0 -- for nil-title slots inside the quest log range

    -- Reset broken quest list on each pass; we only use this for current cache validation state.
    brokenQuestIds = {}

    local maxIndex = math.min(numEntries or MAX_QUEST_LOG_INDEX, MAX_QUEST_LOG_INDEX)
    for i = 1, maxIndex do
        local title, _, _, isHeader, _, _, _, questId = GetQuestLogTitle(i)
        if (not title) then
            -- Some private servers can create malformed quest log entries where a slot inside
            -- the valid range returns nil. Do not stop scanning early; just skip the slot.
            brokenEntriesCount = brokenEntriesCount + 1
            isQuestLogGood = false -- still indicates the cache isn't fully sane
        else
            if (not isHeader) then
                if (not HaveQuestData(questId)) then
                    isQuestLogGood = false
                else
                    local hasInvalidObjective -- for debug stats
                    local objectiveList = GetQuestObjectives(questId, i)

                    if type(objectiveList) ~= "table" then
                        -- Some servers return malformed quest objective data for custom quests.
                        -- Do not let a single broken quest block Questie from loading/tracking other quests.
                        Questie:Warning("Quest objectives aren't a table. Ignoring this quest for cache validation. questId =", questId)
                        brokenQuestIds[questId] = true
                        hasInvalidObjective = true
                        objectiveList = {}
                    end

                    for _, objective in pairs(objectiveList) do -- objectiveList may be {}, which is also a valid cached quest in quest log
                        if (not objective.text) or (stringByte(objective.text, 1) == 32) then -- if (text starts with a space " ") then
                            -- Game hasn't cached the quest fully yet
                            isQuestLogGood = false
                            hasInvalidObjective = true

                            -- No early "return false" here to force iterate whole quest log and speed up caching
                        end
                    end

                    if not hasInvalidObjective then
                        goodQuestsCount = goodQuestsCount + 1
                    end
                end
            end
        end
    end

    if not isQuestLogGood then
        Questie:Debug(Questie.DEBUG_INFO, "[QuestieValidateGameCache] Quest log is NOT yet okey. Good quest:", goodQuestsCount.."/"..numQuests )
        return
    end

    local brokenCount = 0
    for _ in pairs(brokenQuestIds) do
        brokenCount = brokenCount + 1
    end

    if brokenEntriesCount > 0 or brokenCount > 0 then
        -- Continue initialization even with broken entries/quests; this is common with custom quests on private servers.
        Questie:Warning("Quest log contains broken entries. Questie will continue, but the broken quest(s) may not be tracked. Good quest: "..goodQuestsCount.."/"..numQuests..". Broken quests: "..brokenCount..". Broken entries: "..brokenEntriesCount..".")
    end

    DestroyEventFrame()

    Questie:Debug(Questie.DEBUG_CRITICAL, "[QuestieValidateGameCache] Quest log is ok. Good quest:", goodQuestsCount.."/"..numQuests )

    isCacheGood = true

    -- Call all callbacks
    while (#callbacks > 0) do
        local callback = tremove(callbacks, 1)
        local func, args = callback[1], callback[2]
        Questie:Debug(Questie.DEBUG_DEVELOP, "[QuestieValidateGameCache] Calling a callback.")
        func(tunpack(args))
    end
end

local function OnPlayerEnteringWorld(_, _, isInitialLogin, isReloadingUi)
	isInitialLogin = isInitialLogin or Questie.db.profile.isInitialLogin
	isReloadingUi = isReloadingUi or not isInitialLogin

    assert(isInitialLogin or isReloadingUi) -- We should get to here only at login or at /reload.

    -- Game's quest log has still old cached data on the first QUEST_LOG_UPDATE after PLAYER_ENTERING_WORLD during login.
    -- So we need to skip that event.
    numberOfQuestLogUpdatesToSkip = isInitialLogin and 1 or 0

    eventFrame:UnregisterAllEvents()
    eventFrame:SetScript("OnEvent", OnQuestLogUpdate)
    eventFrame:RegisterEvent("QUEST_LOG_UPDATE")
end

-- MUST be started very early to count number of events firing.
function QuestieValidateGameCache.StartCheck()
    assert(not checkStarted) -- to avoid bugging the module by wrong usage
    checkStarted = true

    eventFrame = CreateFrame("Frame")
    eventFrame:SetScript("OnEvent", OnPlayerEnteringWorld)
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
end