-- logic.lua -- Escape Matrix engine (no GUI/WindUI dependency)
-- Loaded by the main script via: loadstring(game:HttpGet(LOGIC_URL))(VERSION)
local VERSION = ...

local RobluxBot = { alive = true, running = false, ok = true, err = nil }

local RS = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local ETM = RS:WaitForChild("ETM", 10)
if not ETM then
    return { ok = false, err = "Escape Matrix (ETM) not found. This script only works in Escape Matrix." }
end

local Net = require(ETM:WaitForChild("Client"):WaitForChild("Net"))
local RobluxData = require(ETM:WaitForChild("Shared"):WaitForChild("RobluxData"))

-- ============================================================
-- CONFIG -- every create-project / publish choice lives here as a
-- plain field so GUI dropdowns can just assign to it. Defaults below
-- are the already-confirmed-optimal picks (see per-field notes):
--   scope/budget  -> best retention/content-polish bonus for the dev
--                    tier that's always unlocked (confirmed via
--                    decompile dump of RobluxData.SCOPES/BUDGETS)
--   thumb/desc/monet/timing/ads -> best CTR/reach WITHOUT the
--                    satisfaction/review penalty (confirmed via
--                    decompile dump of RobluxData.THUMBS/DESCS/MONET;
--                    ADS_TIERS below has no such penalty at all)
-- GUI only ever needs to overwrite these fields -- nothing else in
-- the engine below needs to change.
-- ============================================================
local CONFIG = {
    autoCreate = true,

    -- create-project form
    genre     = "simulator",
    theme     = "pets",
    mech      = "pets",
    aud       = "kids",
    scope     = "large",   -- RobluxData.SCOPES[i].id
    budgetIdx = 4,         -- RobluxData.BUDGETS[i], 4 = "$10,000 (pro assets)"

    -- publish form
    thumbIdx  = 3,  -- RobluxData.THUMBS[i],  3 = "shock" (best ctr, not clickbait)
    descIdx   = 1,  -- RobluxData.DESCS[i],   1 = "honest"
    monetIdx  = 2,  -- RobluxData.MONET[i],   2 = "fair"
    timingIdx = 2,  -- RobluxData.TIMING[i],  2 = "evening" (+20% launch reach)
    adsIdx    = 1,  -- ADS_TIERS[i] below,    1 = "No ads"

    -- post-launch updates (live projects only)
    autoUpdates = true,
    updateTypes = { auto = true },  -- set from the multi-select dropdown.
                                     -- "auto" key = let the bot fully decide (bugfix
                                     -- priority, else weighted). Any RobluxData.UPDATES[i].id
                                     -- keys = restrict the bot to randomly cycling only
                                     -- through those picked types. Default: everything on.
}

-- Local "ads" tier table -- NOT part of RobluxData, this is a UI-local
-- table (confirmed via decompile, ReplicatedStorage.ETM.Client.Apps.Roblux).
-- Only {cents, name} -- no sat/like fields exist for any ads tier, so
-- (unlike thumb/monet) there's no satisfaction trade-off to worry about here.
local ADS_TIERS = {
    { cents = 0,        name = "No ads" },
    { cents = 10000,    name = "$100 of ads" },
    { cents = 100000,   name = "$1,000 of ads" },
    { cents = 1000000,  name = "$10,000 of ads" },
    { cents = 10000000, name = "$100,000 of ads" },
}

local PUBLISH_THRESHOLD   = 1.0   -- wait for 100% dev progress, not just the 50% "early access" gate
local ALL_STATS_THRESHOLD = 0.99  -- content/polish/stability must ALSO individually clear this before publish
local ACTIVITY_SKIP_THRESHOLD = 0.999 -- an activity's stat already this maxed -> skip it, don't re-poke it

local PUBLISH_RETRY_COOLDOWN = 60
local PUBLISH_MAX_FAILURES   = 3
local CREATE_COOLDOWN        = 60
local LOOP_INTERVAL          = 5
local SESSION_GAP            = 1.0

local NAME_PREFIXES = { "Pet", "Fluffy", "Tiny", "Mega", "Super", "Lucky", "Cozy", "Royal" }
local NAME_SUFFIXES = { "Simulator", "Tycoon", "World", "Life", "Paradise", "Adventure", "Rush", "Mania" }
local function generateProjectName()
    return NAME_PREFIXES[math.random(#NAME_PREFIXES)] .. " Pet " .. NAME_SUFFIXES[math.random(#NAME_SUFFIXES)]
end

local DEBUG_LOG, DEBUG_MAX_LINES = {}, 200

local function log(s)
    local line = "[RobluxBot " .. VERSION .. "] " .. s
    DEBUG_LOG[#DEBUG_LOG + 1] = line
    if #DEBUG_LOG > DEBUG_MAX_LINES then table.remove(DEBUG_LOG, 1) end
    print(line) -- in case your executor DOES have a console, it'll show there too
end

local function rbx()
    return Net.state.rbx or { projects = {}, workers = {}, market = {} }
end

local function errToString(err)
    if err == nil then return "nil" end
    local t = type(err)
    if t == "string" or t == "number" or t == "boolean" then return tostring(err) end
    if t == "table" then
        local okJ, json = pcall(function() return HttpService:JSONEncode(err) end)
        if okJ then return json end
        local parts = {}
        for k, v in pairs(err) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(err)
end

local function words(s)
    local set = {}
    for w in (s or ""):lower():gmatch("%a+") do set[w] = true end
    return set
end

-- ============================================================
-- Activity choice logic (script/debug/build/ui/anim) -- unchanged
-- engine from v11, kept as-is.
-- ============================================================

local SCRIPT_SYMPTOM_MAP = {
    { symptom = {"freeze", "lag", "hang", "stuck", "slow"},       gloss = {"forever", "no pause", "repeat", "loop", "wait"} },
    { symptom = {"crash", "error", "break"},                      gloss = {"nil", "error", "missing", "undefined"} },
    { symptom = {"exploit", "cheat", "hack", "dupe", "duplicate"}, gloss = {"no check", "no validation", "anyone", "without checking", "trust"} },
    { symptom = {"spam", "multiple", "twice", "double"},           gloss = {"debounce", "cooldown", "again", "every time"} },
    { symptom = {"memory", "leak"},                                gloss = {"never", "disconnect", "clean", "forever"} },
}

local function pickScriptLine(content)
    local lines = content.lines or {}
    local plain = content.plain or {}
    if #lines == 0 then return 1 end

    local reportWords = words(content.title)
    if next(reportWords) and next(plain) then
        local activeCategories = {}
        for _, cat in ipairs(SCRIPT_SYMPTOM_MAP) do
            for _, sym in ipairs(cat.symptom) do
                if reportWords[sym] then activeCategories[#activeCategories + 1] = cat; break end
            end
        end
        local scored = {}
        for i = 1, #lines do
            local glossText = (plain[i] or ""):lower()
            local score = 0
            for _, cat in ipairs(activeCategories) do
                for _, g in ipairs(cat.gloss) do
                    if glossText:find(g, 1, true) then score = score + 3 end
                end
            end
            if score > 0 then scored[#scored + 1] = { idx = i, score = score } end
        end
        if #scored > 0 then
            table.sort(scored, function(a, b) return a.score > b.score end)
            return scored[1].idx
        end
    end

    local bestIdx, bestLen = 1, math.huge
    for i, l in ipairs(lines) do
        if #l < bestLen then bestIdx, bestLen = i, #l end
    end
    return bestIdx
end

local DEBUG_SIGNAL_WORDS = {
    "client", "server", "timer", "sync", "validate", "authority",
    "replicate", "race", "cache", "stale", "null", "nil", "overflow",
    "leak", "loop", "async", "debounce", "cooldown", "event", "remote",
    "index", "order", "render", "update", "throttle",
}

local function pickDebugOption(content)
    local options = content.options or {}
    if #options == 0 then return 1, false end
    if content.likely then return content.likely, true end

    local logWords = words((content.log or "") .. " " .. (content.report or ""))
    local scored = {}
    for i, opt in ipairs(options) do
        local optWords = words(opt)
        local score = 0
        for w in pairs(optWords) do
            if logWords[w] then score = score + 2 end
            for _, sig in ipairs(DEBUG_SIGNAL_WORDS) do
                if w == sig and logWords[sig] then score = score + 1 end
            end
        end
        scored[#scored + 1] = { idx = i, score = score }
    end
    table.sort(scored, function(a, b) return a.score > b.score end)
    if scored[1] and scored[1].score > 0 then return scored[1].idx, false end
    return 1, false
end

local BUILD_CATEGORY_MAP = {
    { need = {"collect", "gather", "earn"},                     part = {"pet", "egg", "leaderboard", "crate", "coin"} },
    { need = {"stronger", "progress", "upgrade", "rebirth", "grow"}, part = {"rebirth", "upgrade", "level"} },
    { need = {"spend", "shop", "buy", "purchase"},              part = {"shop", "stand", "store", "dealership"} },
    { need = {"compete", "rank", "social"},                     part = {"leaderboard"} },
    { need = {"danger", "challenge", "obstacle", "risk"},       part = {"kill", "brick", "trap"} },
    { need = {"home", "own", "personal", "base"},               part = {"house", "plot"} },
    { need = {"reward", "incentive", "return"},                 part = {"rebirth", "upgrade", "shop"} },
}

local function pickBuildParts(content)
    local pick = content.pick or 1
    local options = content.options or {}
    if #options == 0 then return {} end

    local briefWords = words(content.brief)
    local activeCategories = {}
    for _, cat in ipairs(BUILD_CATEGORY_MAP) do
        for _, needWord in ipairs(cat.need) do
            if briefWords[needWord] then activeCategories[#activeCategories + 1] = cat; break end
        end
    end

    local scored = {}
    for i, opt in ipairs(options) do
        local optLower = opt:lower()
        local score = 0
        for w in pairs(briefWords) do
            if optLower:find(w, 1, true) then score = score + 1 end
        end
        for _, cat in ipairs(activeCategories) do
            for _, partWord in ipairs(cat.part) do
                if optLower:find(partWord, 1, true) then score = score + 3 end
            end
        end
        scored[#scored + 1] = { idx = i, score = score, text = opt }
    end
    table.sort(scored, function(a, b) return a.score > b.score end)

    local chosen = {}
    for i = 1, math.min(pick, #scored) do
        if scored[i].score > 0 or i == 1 then chosen[#chosen + 1] = scored[i].idx end
    end
    if #chosen == 0 and #options > 0 then chosen = { 1 } end
    return chosen
end

local UI_PRIORITY_WORDS = {
    { 100, {"currency", "coin", "cash", "money", "balance"} },
    { 90,  {"shop", "buy", "store"} },
    { 80,  {"settings", "options"} },
    { 70,  {"leaderboard", "rank"} },
    { 60,  {"notification", "alert"} },
}

local function elementPriority(name)
    local lower = name:lower()
    for _, entry in ipairs(UI_PRIORITY_WORDS) do
        for _, kw in ipairs(entry[2]) do
            if lower:find(kw, 1, true) then return entry[1] end
        end
    end
    return 10
end

local function pickUiLayout(content)
    local elements = content.elements or {}
    local spots = content.spots or {}
    if #elements == 0 or #spots == 0 then return {} end

    local ranked = {}
    for i, name in ipairs(elements) do ranked[#ranked + 1] = { idx = i, priority = elementPriority(name) } end
    table.sort(ranked, function(a, b) return a.priority > b.priority end)

    local layout = {}
    for rank, entry in ipairs(ranked) do
        layout[entry.idx] = ((rank - 1) % #spots) + 1
    end
    return layout
end

local function pickAnimOrder(content)
    local frames = content.frames or {}
    local order = {}
    for i = 1, math.min(4, #frames) do order[i] = i end
    return order
end

local function submit(sid, payload, label, context)
    local okS, res = pcall(function() return Net.request("RbxSubmit", sid, payload) end)
    if okS and res and res.ok then
        log(string.format("SUBMIT [%s] score=%.3f work=+%.1f", label, res.score or -1, res.work or 0))
        if (res.score or 0) < 0.5 and context then log("  low score context: " .. context) end
        if res.explain then log("  server explain: " .. tostring(res.explain)) end
    else
        log(string.format("SUBMIT [%s] FAILED: %s", label, tostring(res and res.err or res)))
    end
    return okS, res
end

local function runActivity(project, activityId)
    local okS, session = pcall(function() return Net.request("RbxSession", project.id, activityId) end)
    if not okS or not session or not session.ok then
        log(string.format("session open failed [%s/%s]: %s", project.title or project.id, activityId, tostring(session and session.err or session)))
        return
    end

    local content, sid = session.content, session.sid
    local label = activityId .. ":" .. (project.title or project.id)

    if activityId == "script" then
        submit(sid, pickScriptLine(content), label, "title=" .. tostring(content.title))
    elseif activityId == "debug" then
        local opt, confident = pickDebugOption(content)
        submit(sid, opt, label .. (confident and " (likely-hint)" or " (semantic-guess)"),
            "report=" .. tostring(content.report) .. " | log=" .. tostring(content.log))
    elseif activityId == "build" then
        submit(sid, pickBuildParts(content), label, "brief=" .. tostring(content.brief))
    elseif activityId == "ui" then
        submit(sid, pickUiLayout(content), label, nil)
    elseif activityId == "anim" then
        local order = pickAnimOrder(content)
        if #order < 4 then log("anim: not enough frames to pick 4, skipping"); return end
        submit(sid, order, label, "NO SIGNAL YET - neutral order used")
    else
        log("unknown activity id: " .. tostring(activityId))
    end

    task.wait(SESSION_GAP)
end

-- ============================================================
-- Publish -- reads CONFIG directly, no auto-pick functions. GUI
-- dropdowns write to CONFIG.thumbIdx/descIdx/monetIdx/timingIdx/adsIdx.
-- ============================================================

local publishedProjects, publishFailures, nextPublishAttempt, publishGaveUp = {}, {}, {}, {}

local function tryPublish(project)
    if publishedProjects[project.id] or publishGaveUp[project.id] then return end
    if project.published then publishedProjects[project.id] = true; return end
    if (nextPublishAttempt[project.id] or 0) > os.clock() then return end

    local parts = project.parts or {}
    local progress = parts.progress or 0
    if progress < PUBLISH_THRESHOLD then return end

    local content = parts.content or 0
    local polish  = (parts.polish or 0) / 100
    local stab    = (parts.stab or 0) / 100
    if content < ALL_STATS_THRESHOLD or polish < ALL_STATS_THRESHOLD or stab < ALL_STATS_THRESHOLD then
        log(string.format("publish waiting [%s]: progress=%.0f%% but content=%.0f%% polish=%.0f%% stability=%.0f%% not all done yet",
            project.title or project.id, progress * 100, content * 100, polish * 100, stab * 100))
        return
    end

    local thumbs, descs, monets, timings = RobluxData.THUMBS or {}, RobluxData.DESCS or {}, RobluxData.MONET or {}, RobluxData.TIMING or {}
    local thumbEntry, descEntry, monetEntry, timingEntry, adsEntry =
        thumbs[CONFIG.thumbIdx], descs[CONFIG.descIdx], monets[CONFIG.monetIdx], timings[CONFIG.timingIdx], ADS_TIERS[CONFIG.adsIdx]

    if not (thumbEntry and descEntry and monetEntry and timingEntry and adsEntry) then
        log(string.format("publish aborted [%s]: missing RobluxData entry for current CONFIG (thumb=%s desc=%s monet=%s timing=%s ads=%s)",
            project.title or project.id, tostring(thumbEntry), tostring(descEntry), tostring(monetEntry), tostring(timingEntry), tostring(adsEntry)))
        return
    end
    -- informational only -- GUI lets you pick clickbait on purpose if you want to; this just flags it
    if thumbEntry.clickbait then
        log(string.format("publish note [%s]: selected thumbnail is clickbait (ctr=%.2f, sat=%.2f)",
            project.title or project.id, thumbEntry.ctr or 0, thumbEntry.sat or 0))
    end

    if project.sold or project.shutDown or project.closed then
        log(string.format("publish skipped [%s]: project is sold/shut down/closed, not eligible", project.title or project.id))
        publishGaveUp[project.id] = true
        return
    end

    local pubForm = { thumb = thumbEntry.id, desc = descEntry.id, monet = monetEntry.id, timing = timingEntry.id, ads = adsEntry.cents }
    local okP, res = pcall(function() return Net.request("RbxPublish", project.id, pubForm) end)
    if okP and res and res.ok then
        log(string.format("PUBLISHED [%s] progress=%.0f%% thumb=%s desc=%s monet=%s timing=%s ads=%s",
            project.title or project.id, progress * 100, pubForm.thumb, pubForm.desc, pubForm.monet, pubForm.timing, tostring(pubForm.ads)))
        publishedProjects[project.id] = true
        publishFailures[project.id] = nil
        nextPublishAttempt[project.id] = nil
    else
        local errText = errToString(okP and res and res.err or res)
        publishFailures[project.id] = (publishFailures[project.id] or 0) + 1
        local failCount = publishFailures[project.id]
        if failCount >= PUBLISH_MAX_FAILURES then
            publishGaveUp[project.id] = true
            log(string.format("publish GIVING UP [%s] after %d failed attempts, last error: %s", project.title or project.id, failCount, errText))
        else
            nextPublishAttempt[project.id] = os.clock() + PUBLISH_RETRY_COOLDOWN
            log(string.format("publish failed [%s] (attempt %d/%d, retrying in %ds): %s",
                project.title or project.id, failCount, PUBLISH_MAX_FAILURES, PUBLISH_RETRY_COOLDOWN, errText))
        end
    end
end

-- ============================================================
-- Updates (live projects only) -- ported from the game's own "Updates"
-- tab (confirmed via decompile of Apps.Roblux + RobluxData.UPDATES):
--   start : Net.request("RbxUpdate", project.id, updateTypeId, monetId)
--           (monetId only sent when updateTypeId == "monet", it's the
--           RobluxData.MONET[i].id from the same cycler used at publish)
--   state : project.update = { type = id, done = n, need = n }
--   work  : the SAME script/build/ui/anim/debug activities (RbxSession/
--           RbxSubmit via runActivity) feed update.done, not just dev progress
--   finish: Net.request("RbxRelease", project.id) once done >= need
-- ============================================================

local UPDATE_WEIGHTS = { content = 3, features = 2, feedback = 2, ui = 1, monet = 1 }
local BUGFIX_BUG_THRESHOLD = 10 -- known-bug count high enough to prioritize a bug-fix update over growth

local function pickUpdateType(project)
    local sel = CONFIG.updateTypes
    if not sel or next(sel) == nil then sel = { auto = true } end -- never run with nothing picked

    -- bugfix only jumps the queue if "Auto" or "Bugfix" itself is one of the picks,
    -- and bugfix is an id the game actually exposes
    local bugfixAllowed = (sel.auto or sel.bugfix) and (RobluxData.updateById or {}).bugfix
    if bugfixAllowed and (project.bugs or 0) >= BUGFIX_BUG_THRESHOLD then
        return "bugfix"
    end

    -- "Auto" selected -> full weighted pool (content/features/feedback/ui/monet).
    -- Otherwise -> restrict the weighted pool to only the specific types picked.
    local candidates = {}
    if sel.auto then
        for id, w in pairs(UPDATE_WEIGHTS) do candidates[id] = w end
    else
        for id in pairs(sel) do
            if id ~= "auto" and id ~= "bugfix" then
                candidates[id] = UPDATE_WEIGHTS[id] or 1 -- picked type with no weight entry -> treat as equal weight
            end
        end
    end
    if next(candidates) == nil then candidates.content = 1 end -- picked only "Bugfix" with no bugs due -> fall back

    local total = 0
    for _, w in pairs(candidates) do total = total + w end
    local r = math.random() * total
    for id, w in pairs(candidates) do
        r = r - w
        if r <= 0 then return id end
    end
    return "content"
end

local nextUpdateAttempt = {}
local function startUpdate(project)
    if (nextUpdateAttempt[project.id] or 0) > os.clock() then return end

    local typeId = pickUpdateType(project)
    local monetId = nil
    if typeId == "monet" then
        local monets = RobluxData.MONET or {}
        monetId = monets[CONFIG.monetIdx] and monets[CONFIG.monetIdx].id
    end

    local ok, res = pcall(function() return Net.request("RbxUpdate", project.id, typeId, monetId) end)
    if ok and res and res.ok then
        log(string.format("UPDATE STARTED [%s] type=%s", project.title or project.id, typeId))
    else
        nextUpdateAttempt[project.id] = os.clock() + CREATE_COOLDOWN
        log(string.format("update start failed [%s] type=%s: %s",
            project.title or project.id, typeId, tostring(res and res.err or res)))
    end
end

local function tryReleaseUpdate(project)
    local upd = project.update
    if not upd then return end
    if (upd.done or 0) < (upd.need or 0) then return end

    local ok, res = pcall(function() return Net.request("RbxRelease", project.id) end)
    if ok and res and res.ok then
        log(string.format("UPDATE RELEASED [%s] type=%s", project.title or project.id, tostring(upd.type)))
    end
end

local UPDATE_ACTIVITIES = { "script", "build", "ui", "anim", "debug" }
local function workOnUpdate(project)
    local wait = project.wait or {}
    for _, activityId in ipairs(UPDATE_ACTIVITIES) do
        if (wait[activityId] or 0) <= 0 then
            runActivity(project, activityId)
        end
    end
end

-- ============================================================
-- Stat-gap activity prioritization + create -- unchanged engine.
-- ============================================================

local STAT_ACTIVITIES = { stability = {"debug"}, content = {"script", "build"}, polish = {"ui", "anim"} }
local STAT_FIELD = {
    stability = { key = "stab",    scale = 100 },
    content   = { key = "content", scale = 1 },
    polish    = { key = "polish",  scale = 100 },
}
local ACTIVITY_STAT = { debug = "stability", script = "content", build = "content", ui = "polish", anim = "polish" }

local function defaultActivityOrder()
    local order = {}
    for _, a in ipairs(RobluxData.ACTIVITIES) do order[#order + 1] = a.id end
    return order
end

local function activityOrderFor(project)
    local parts = project.parts or {}
    local stats = {}
    for statName, field in pairs(STAT_FIELD) do
        local raw = parts[field.key]
        if raw ~= nil then stats[#stats + 1] = { name = statName, value = raw / field.scale } end
    end
    if #stats == 0 then return defaultActivityOrder() end

    table.sort(stats, function(a, b) return a.value < b.value end)
    local order, seen = {}, {}
    for _, s in ipairs(stats) do
        for _, actId in ipairs(STAT_ACTIVITIES[s.name]) do
            if not seen[actId] then order[#order + 1] = actId; seen[actId] = true end
        end
    end
    for _, actId in ipairs(defaultActivityOrder()) do
        if not seen[actId] then order[#order + 1] = actId; seen[actId] = true end
    end
    return order
end

local function currentStatValue(project, statName)
    local field = STAT_FIELD[statName]
    if not field then return nil end
    local raw = (project.parts or {})[field.key]
    if raw == nil then return nil end
    return raw / field.scale
end

local nextCreateAttempt = 0
local function createProject()
    if os.clock() < nextCreateAttempt then return false end

    local form = {
        title  = generateProjectName(),
        genre  = CONFIG.genre,
        theme  = CONFIG.theme,
        mech   = CONFIG.mech,
        aud    = CONFIG.aud,
        scope  = CONFIG.scope,
        budget = CONFIG.budgetIdx,
    }

    local okC, res = pcall(function() return Net.request("RbxCreate", form) end)
    if okC and res and res.ok then
        log(string.format("CREATED [%s] genre=%s theme=%s mech=%s aud=%s scope=%s (id=%s)",
            form.title, form.genre, form.theme, form.mech, form.aud, form.scope, tostring(res.id)))
    else
        nextCreateAttempt = os.clock() + CREATE_COOLDOWN
        log(string.format("create failed [%s]: %s (retrying in %ds)", form.title, tostring(res and res.err or res), CREATE_COOLDOWN))
    end

    task.wait(SESSION_GAP)
    return okC and res and res.ok
end

local function cycle()
    local state = rbx()
    local projects = state.projects or {}

    if CONFIG.autoCreate then
        createProject()
        state = rbx()
        projects = state.projects or {}
    end

    if #projects == 0 then log("no active projects"); return end

    for _, project in ipairs(projects) do
        tryPublish(project)
        local wait = project.wait or {}
        for _, activityId in ipairs(activityOrderFor(project)) do
            if (wait[activityId] or 0) <= 0 then
                local statName = ACTIVITY_STAT[activityId]
                local statValue = statName and currentStatValue(project, statName)
                if not (statValue and statValue >= ACTIVITY_SKIP_THRESHOLD) then
                    runActivity(project, activityId)
                end
            end
        end

        if CONFIG.autoUpdates and project.phase == "live" then
            if project.update then
                workOnUpdate(project)
                tryReleaseUpdate(project)
            else
                startUpdate(project)
            end
        end
    end
end

-- main loop: only ticks cycle() while RobluxBot.running is on; RobluxBot.alive stops it
-- for good on unload.
task.spawn(function()
    while RobluxBot.alive do
        task.wait(LOOP_INTERVAL)
        if RobluxBot.running then
            local okR, err = pcall(cycle)
            if not okR then log("cycle error: " .. tostring(err)) end
        end
    end
end)

-- =====================================================================
-- SHIPIFY (second job minigame) -- engine ported from user's own script,
-- scoped in a do-block so its locals (log/cycle/RS/Net/etc) don't clash
-- with the Roblux Studio engine above. Shipify table below is the only
-- thing exposed outward, for the GUI toggle + demand dropdown.
-- =====================================================================
local Shipify = { running = false, ok = false, minDemand = "medium" }

do
    local shipOk, Products, Progression = pcall(function()
        local Shared = ETM:WaitForChild("Shared")
        return require(Shared:WaitForChild("Products")), require(Shared:WaitForChild("Progression"))
    end)
    Shipify.ok = shipOk
    if not shipOk then
        -- Products/Progression not found (job not unlocked yet, or not this game) --
        -- leave Shipify.ok = false, GUI toggle will refuse to turn on and notify.
    else

    local CASH_BUFFER_PCT = 0.20
    local LOOP_INTERVAL    = 15
    local MAX_SAMPLE_SPEND = 0.5
    local AD_BUDGET_SPEND_PCT = 0.3

    local MIN_DEMAND = 0.4
    local COMP_PENALTY_MULT = 1.4
    local BASE_BUDGET_TIER_IDX = 2

    local COMP_TIER_PENALTY_HIGH = 0.75
    local COMP_TIER_PENALTY_MED  = 0.5
    local BROAD_AUDIENCE_TIER_PENALTY = 1
    local MIN_CONV_SAMPLE_CLICKS = 20
    local LOW_CONV_RATIO = 0.5

    local REL_PENALTY_MULT = 0.6
    local MIN_REL = 0.5
    local SAMPLE_NOTE_PENALTY = 0.7
    local RED_FLAG_WORDS = {
        "permanently", "fridge", "blob", "sticker", "fake", "doesn't work",
        "broken", "stopped working", "melted", "cracked", "stain", "smell",
        "gave up", "fell apart", "scam",
    }

    local ROTATE_SCORE_RATIO = 0.6
    local ROTATE_MIN_AGE_SEC = 180
    local listingStartedAt = {}

    -- ===== HustleGPT AI pitch =====
    -- Data mentah dari ai.ideas (conf, claimDemand, hype) itu KLAIM AI, bisa dilebih-lebihkan
    -- (UI game sendiri bilang "HustleGPT exaggerates"). Makanya WAJIB AiAnalyze dulu tiap pitch
    -- baru sebelum diputusin adopt atau nggak -- jangan pernah adopt cuma dari klaim conf/claimDemand.
    local DEMAND_RANK = { low = 1, medium = 2, high = 3, ["very high"] = 4 }
    -- Shipify.minDemand (table field, settable from GUI dropdown) replaces the old
    -- MIN_AI_DEMAND local constant -- default stays "medium", same as before.
    local AI_REROLL_BUDGET_PCT = 0.5
    local aiAnalyzedThisSession = {}

    local function shipLog(s) end

    local function cash()
        return (Net.state.core or {}).cash or 0
    end

    local function shipState()
        return Net.state.ship or {}
    end

    local function availableBudget()
        local c = cash()
        local usable = c * (1 - CASH_BUFFER_PCT)
        return math.max(0, usable)
    end

    local function skillLevel(id)
        local skills = (Net.state.core or {}).skills or {}
        return Progression.levelFromXp(skills[id] or 0)
    end

    local function audienceFit(aud, cat)
        local a = Products.audienceById[aud]
        if not a or not a.fit then return 1 end
        return a.fit[cat] or 1
    end

    local function bestPrice(prod)
        local bestP, bestScore = prod.msrp, -math.huge
        local lo = prod.cost * 1.3
        local hi = prod.msrp * 1.15
        local steps = 12
        for i = 0, steps do
            local price = lo + (hi - lo) * (i / steps)
            local fairValue = prod.msrp * (0.5 + 0.5 * prod.quality)
            local priceRatio = price / fairValue
            local demandMult = math.clamp(1.6 - priceRatio, 0.05, 1.6)
            local demandScore = prod.demand * demandMult * (1 - prod.comp * 0.5)
            local margin = price - prod.cost
            local score = margin * demandScore
            if score > bestScore then
                bestScore = score
                bestP = price
            end
        end
        return math.floor(bestP), bestScore
    end

    local function bestAudience(cat)
        local best, bestMult = "everyone", 1
        for _, a in ipairs(Products.audiences) do
            local mult = audienceFit(a.id, cat)
            if mult > bestMult then
                bestMult = mult
                best = a.id
            end
        end
        return best, bestMult
    end

    local function bestHeadline(aud)
        local best, bestScore = "honest", -math.huge
        for _, h in ipairs(Products.headlines) do
            local fit = (h.fit and h.fit[aud]) or 1
            local score = fit - (h.refund or 0) * 2
            if score > bestScore then
                bestScore = score
                best = h.id
            end
        end
        return best
    end

    local function isPlatformUnlocked(p)
        if p.id == "gurutube" then
            return skillLevel("marketing") >= 3
        end
        return true
    end

    local function bestPlatform(budget)
        local best, bestScore = nil, -math.huge
        for _, p in ipairs(Products.platforms) do
            if not isPlatformUnlocked(p) then continue end
            local clicksPerBudget = (budget / p.cpm) * 1000 * p.ctr * p.reach
            local expectedOrders = clicksPerBudget * p.conv
            if expectedOrders > bestScore then
                bestScore = expectedOrders
                best = p.id
            end
        end
        if not best then
            for _, p in ipairs(Products.platforms) do
                if isPlatformUnlocked(p) then
                    best = p.id
                    break
                end
            end
        end
        return best, bestScore
    end

    local function sampleNotePenalty(prod)
        local note = prod.sampleNote
        if not note or type(note) ~= "string" then return 1 end
        local lower = note:lower()
        for _, w in ipairs(RED_FLAG_WORDS) do
            if lower:find(w, 1, true) then
                return SAMPLE_NOTE_PENALTY
            end
        end
        return 1
    end

    local function scoreProduct(prod, trendBoost)
        if prod.demand < MIN_DEMAND then
            return nil
        end
        local price, marginScore = bestPrice(prod)
        local cat = prod.cat
        local aud, audMult = bestAudience(cat)
        local hl = bestHeadline(aud)
        local boost = trendBoost[prod.id] or trendBoost[cat] or 1
        local compPenalty = math.clamp(1 - (prod.comp or 0) * COMP_PENALTY_MULT, 0.05, 1)
        local rel = prod.rel or 1
        local relPenalty = 1
        if rel < MIN_REL then
            relPenalty = math.clamp(1 - (MIN_REL - rel) * REL_PENALTY_MULT, 0.3, 1)
        end
        local notePenalty = sampleNotePenalty(prod)
        local totalScore = marginScore * audMult * boost * compPenalty * relPenalty * notePenalty
        return {
            prod = prod,
            price = price,
            aud = aud,
            hl = hl,
            score = totalScore,
            audMult = audMult,
        }
    end

    local function getTrendBoosts()
        local boosts = {}
        local trends = (Net.state.trends or {}).active or {}
        for _, t in ipairs(trends) do
            for _, eff in ipairs(t.effects or {}) do
                local pct = eff:match("%+(%d+)%%")
                if pct and eff:find("Shipify") then
                    for _, prod in ipairs(Products.list) do
                        if eff:find(prod.name, 1, true) then
                            boosts[prod.id] = 1 + tonumber(pct) / 100
                        end
                    end
                end
            end
        end
        return boosts
    end

    local SORTED_BUDGETS = {}
    for _, b in ipairs(Products.budgets) do table.insert(SORTED_BUDGETS, b) end
    table.sort(SORTED_BUDGETS)

    local function pickBudgetPreset(targetSpend, prevBudgetCents, hadOrders, comp, audMult)
        local maxBudget = shipState().maxBudget or math.huge
        local cap = math.min(targetSpend, maxBudget, availableBudget())

        local wantIdx
        if not prevBudgetCents then
            wantIdx = BASE_BUDGET_TIER_IDX
        else
            local prevIdx = nil
            for i, b in ipairs(SORTED_BUDGETS) do
                if b == prevBudgetCents then prevIdx = i break end
            end
            if not prevIdx then
                wantIdx = BASE_BUDGET_TIER_IDX
            elseif hadOrders then
                wantIdx = prevIdx + 1
            else
                wantIdx = prevIdx
            end
        end

        comp = comp or 0
        audMult = audMult or 1
        if comp >= COMP_TIER_PENALTY_HIGH then
            wantIdx = wantIdx - 2
        elseif comp >= COMP_TIER_PENALTY_MED then
            wantIdx = wantIdx - 1
        end
        if audMult <= 1 then
            wantIdx = wantIdx - BROAD_AUDIENCE_TIER_PENALTY
        end

        wantIdx = math.clamp(wantIdx, 1, #SORTED_BUDGETS)
        local best = nil
        for i = wantIdx, 1, -1 do
            local b = SORTED_BUDGETS[i]
            if b <= cap then
                best = b
                break
            end
        end
        if not best then
            for _, b in ipairs(SORTED_BUDGETS) do
                if b <= cap then
                    if not best or b < best then best = b end
                end
            end
        end
        return best
    end

    local function pickDurationPreset()
        local best = nil
        for _, d in ipairs(Products.durations) do
            if not best or d > best then
                best = d
            end
        end
        return best
    end

    local function fulfillAll()
        -- "Fulfill all" needs business skill level 2 (confirmed via decompile of
        -- Apps.Shipify's Orders tab: button disabled + labeled "Fulfill all (Biz 2)"
        -- below that level). Below it, fulfill each "new" order one by one with
        -- the same Ship/Fulfill remote the per-order button uses (Ship, "Fulfill", order.id).
        if skillLevel("business") < 2 then
            local s = shipState()
            for _, order in ipairs(s.orders or {}) do
                if order.status == "new" then
                    local ok, res = pcall(function() return Net.request("Ship", "Fulfill", order.id) end)
                    if ok and res and res.ok then
                        shipLog("Fulfill order #" .. tostring(order.id) .. " ok")
                    end
                end
            end
            return
        end

        local ok, res = pcall(function() return Net.request("Ship", "FulfillAll") end)
        if ok and res and res.ok then
            shipLog("FulfillAll ok")
        end
    end

    local function resolveTickets()
        local s = shipState()
        for _, ticket in ipairs(s.tickets or {}) do
            local opt1 = ticket.options and ticket.options[1]
            if opt1 then
                local ok, res = pcall(function()
                    return Net.request("Ship", "Resolve", ticket.id, opt1.id)
                end)
                if ok and res and res.ok then
                    shipLog("Resolve ticket ok: " .. tostring(ticket.id) .. " (opsi: " .. tostring(opt1.label) .. ")")
                else
                    shipLog("Resolve ticket failed: " .. tostring(ticket.id) .. " -> " .. tostring(ok and res and res.err or res))
                end
            else
                shipLog("Skip resolve ticket " .. tostring(ticket.id) .. ": ticket.options kosong/nil")
            end
        end
    end

    local function ensureListing(pid, price)
        local s = shipState()
        local existing = s.listings and s.listings[pid]
        if existing and existing.active then
            return true
        end
        local prod = Products.byId[pid]

        local samples = s.samples or {}
        if not samples[pid] then
            shipLog("Skip list " .. prod.name .. ": belum ada sample (nunggu sample arrive / belum dipesan)")
            return false
        end

        local ok, res = pcall(function()
            return Net.request("Ship", "List", pid, price, "honest")
        end)
        if ok and res and res.ok then
            shipLog("Listed " .. prod.name .. " @ $" .. string.format("%.2f", price/100))
            listingStartedAt[pid] = os.clock()
            return true
        else
            shipLog("Failed to list " .. tostring(pid) .. ": " .. tostring(ok and res and res.err or res))
            return false
        end
    end

    local function unlistProduct(pid)
        local prod = Products.byId[pid]
        local ok, res = pcall(function()
            return Net.request("Ship", "Unlist", pid)
        end)
        if ok and res and res.ok then
            shipLog("Unlisted " .. (prod and prod.name or pid) .. " (digantiin kandidat lebih bagus)")
            listingStartedAt[pid] = nil
            return true
        else
            shipLog("Failed to unlist " .. tostring(pid) .. ": " .. tostring(ok and res and res.err or res))
            return false
        end
    end

    local function hasActiveCampaignFor(pid)
        local s = shipState()
        for _, c in ipairs(s.campaigns or {}) do
            if c.pid == pid then return true end
        end
        return false
    end

    local function computeHadOrders(last)
        local clicks = last.clicks or 0
        local orders = last.orders or 0
        if clicks < MIN_CONV_SAMPLE_CLICKS then
            return nil
        end
        local conv = orders / clicks
        local storeConv = (shipState().storeConv) or ((Net.state.core or {}).conv) or 0.0832
        return conv >= storeConv * LOW_CONV_RATIO
    end

    local function lastCampaignResultFor(pid)
        local s = shipState()
        local history = s.finishedCampaigns or s.history or s.pastCampaigns or {}
        local last = nil
        for _, c in ipairs(history) do
            if c.pid == pid then
                if not last or (c.endedAt or 0) >= (last.endedAt or 0) then
                    last = c
                end
            end
        end
        if not last then return nil, nil end
        local budgetCents = last.budget or last.budgetCents
        local hadOrders = computeHadOrders(last)
        return budgetCents, hadOrders
    end

    local function launchAdFor(choice, budgetCents, hours)
        local ok, res = pcall(function()
            return Net.request("Ship", "Launch", choice.prod.id, choice.platform, choice.aud, choice.hl, budgetCents, hours)
        end)
        if ok and res and res.ok then
            shipLog(string.format("Launched ad: %s | %s/%s/%s | budget $%.2f | %dh",
                choice.prod.name, choice.platform, choice.aud, choice.hl, budgetCents/100, hours))
        else
            shipLog("Launch failed: " .. tostring(ok and res and res.err or res))
        end
    end

    local function tryUpgrade()
        local s = shipState()
        local level = s.level or 1
        local nextUp = Products.UPGRADES[level + 1]
        if not nextUp then return end
        local c = cash()
        if nextUp.cost > 0 and nextUp.cost <= c * 0.5 then
            local ok, res = pcall(function() return Net.request("Ship", "Upgrade") end)
            if ok and res and res.ok then
                shipLog("Upgraded store to level " .. (level + 1) .. " (" .. nextUp.name .. ")")
            end
        end
    end

    local function aiState()
        return (Net.state.ship or {}).ai or {}
    end

    local function aiRequest(action, ...)
        local args = { ... }
        return pcall(function()
            return Net.request("Ship", action, table.unpack(args))
        end)
    end

    local function demandRankOf(demandStr)
        if not demandStr then return 0 end
        return DEMAND_RANK[tostring(demandStr):lower()] or 0
    end

    -- Flow: AiReroll (kalau ideas kosong & masih ada rerollsLeft) -> AiAnalyze tiap idea
    -- yang belum dianalisa -> baru putusin AiAdopt berdasar data analysis ASLI (bukan klaim AI).
    local function decideAiPitches()
        local ai = aiState()
        if not ai.unlocked then return end

        local ideas = ai.ideas or {}
        local analysis = ai.analysis or {}
        local adopted = ai.adopted or {}
        local costs = ai.costs or {}
        local budget = availableBudget() * AI_REROLL_BUDGET_PCT

        local minRankCheck = demandRankOf(Shipify.minDemand)
        local hasPending = false
        for _, idea in ipairs(ideas) do
            local pid = idea.pid
            if not adopted[pid] then
                local a = analysis[pid]
                if not a then
                    hasPending = true break
                elseif demandRankOf(a.demand) >= minRankCheck then
                    hasPending = true break
                end
            end
        end
        if not hasPending then
            local rerollCost = costs.reroll or 0
            if (ai.rerollsLeft or 0) > 0 and rerollCost <= budget then
                local ok, res = aiRequest("AiReroll")
                if ok and res and res.ok then
                    shipLog("AiReroll ok (rerollsLeft sisa " .. ((ai.rerollsLeft or 1) - 1) .. ")")
                end
            end
            return
        end

        for _, idea in ipairs(ideas) do
            local pid = idea.pid
            if not adopted[pid] and not analysis[pid] and not aiAnalyzedThisSession[pid] then
                local analyzeCost = costs.analyze or 0
                if analyzeCost <= budget then
                    local ok, res = aiRequest("AiAnalyze", pid)
                    if ok and res and res.ok then
                        aiAnalyzedThisSession[pid] = true
                        shipLog("AiAnalyze ok: " .. tostring(pid))
                    else
                        shipLog("AiAnalyze failed: " .. tostring(pid) .. " -> " .. tostring(ok and res and res.err or res))
                    end
                else
                    shipLog("Skip AiAnalyze " .. tostring(pid) .. ": budget available gak cukup")
                end
                return
            end
        end

        local minRank = demandRankOf(Shipify.minDemand)
        for _, idea in ipairs(ideas) do
            local pid = idea.pid
            local a = analysis[pid]
            if not adopted[pid] and a then
                if demandRankOf(a.demand) >= minRank then
                    local ok, res = aiRequest("AiAdopt", pid)
                    if ok and res and res.ok then
                        shipLog("AiAdopt ok: " .. tostring(pid) .. " (real demand=" .. tostring(a.demand) .. ", comp=" .. tostring(a.comp) .. ", margin=" .. tostring(a.margin) .. ")")
                    else
                        shipLog("AiAdopt failed: " .. tostring(pid) .. " -> " .. tostring(ok and res and res.err or res))
                    end
                else
                    shipLog("Skip adopt " .. tostring(pid) .. ": real demand cuma '" .. tostring(a.demand) .. "' (minimal '" .. Shipify.minDemand .. "')")
                end
            end
        end
    end

    local MAX_SAMPLED_PRODUCTS = 3

    local function countSamples()
        local s = shipState()
        local n = 0
        for _ in pairs(s.samples or {}) do n = n + 1 end
        return n
    end

    local function decideSample()
        if countSamples() >= MAX_SAMPLED_PRODUCTS then
            return
        end
        local s = shipState()
        local samples = s.samples or {}
        local trendBoost = getTrendBoosts()
        local candidates = {}
        for _, prod in ipairs(Products.list) do
            if prod.ai then continue end
            if not samples[prod.id] then
                local scored = scoreProduct(prod, trendBoost)
                if scored then
                    table.insert(candidates, scored)
                end
            end
        end
        table.sort(candidates, function(a, b) return a.score > b.score end)

        local budget = availableBudget()
        for _, c in ipairs(candidates) do
            local sampleCost = c.prod.sample
            if sampleCost <= budget * MAX_SAMPLE_SPEND then
                local ok, res = pcall(function()
                    return Net.request("Ship", "Sample", c.prod.id)
                end)
                if ok and res and res.ok then
                    shipLog("Ordered sample: " .. c.prod.name .. " ($" .. string.format("%.2f", sampleCost/100) .. ")")
                end
                return
            end
        end
    end

    local function profitOf(pid)
        local s = shipState()
        local pp = s.perProduct and s.perProduct[pid]
        return (pp and pp.profit) or 0
    end

    local function decideListingAndAds()
        local s = shipState()
        local trendBoost = getTrendBoosts()
        local candidates = {}
        for _, prod in ipairs(Products.list) do
            if prod.ai then continue end
            local scored = scoreProduct(prod, trendBoost)
            if scored then
                table.insert(candidates, scored)
            end
        end
        table.sort(candidates, function(a, b) return a.score > b.score end)

        local maxListings = s.maxListings or 1

        local activeCount = 0
        for _, listing in pairs(s.listings or {}) do
            if listing.active then
                activeCount = activeCount + 1
            end
        end

        do
            local samples = s.samples or {}
            local rankable = {}
            for _, c in ipairs(candidates) do
                if samples[c.prod.id] then
                    table.insert(rankable, { pid = c.prod.id, profit = profitOf(c.prod.id) })
                end
            end
            table.sort(rankable, function(a, b) return a.profit > b.profit end)

            local candByPid = {}
            for _, c in ipairs(candidates) do candByPid[c.prod.id] = c end
            local reordered = {}
            local used = {}
            for _, r in ipairs(rankable) do
                if candByPid[r.pid] and not used[r.pid] then
                    table.insert(reordered, candByPid[r.pid])
                    used[r.pid] = true
                end
            end
            for _, c in ipairs(candidates) do
                if not used[c.prod.id] then
                    table.insert(reordered, c)
                    used[c.prod.id] = true
                end
            end
            candidates = reordered

            if activeCount >= maxListings and #rankable > 0 then
                local bestCandidate = nil
                for _, r in ipairs(rankable) do
                    local isListed = s.listings and s.listings[r.pid] and s.listings[r.pid].active
                    if not isListed then
                        bestCandidate = r
                        break
                    end
                end

                if bestCandidate then
                    local worstPid, worstProfit = nil, math.huge
                    for pid, listing in pairs(s.listings or {}) do
                        if listing.active then
                            local age = listingStartedAt[pid] and (os.clock() - listingStartedAt[pid]) or math.huge
                            if age >= ROTATE_MIN_AGE_SEC and not hasActiveCampaignFor(pid) then
                                local p = profitOf(pid)
                                if p < worstProfit then
                                    worstProfit = p
                                    worstPid = pid
                                end
                            end
                        end
                    end

                    if worstPid and bestCandidate.profit > worstProfit then
                        if unlistProduct(worstPid) then
                            activeCount = activeCount - 1
                        end
                    end
                end
            end
        end

        local maxCampaigns = s.maxCampaigns or maxListings
        local activeCampaignCount = #(s.campaigns or {})

        local hours = pickDurationPreset()
        if not hours then
            shipLog("Skip ads: Products.durations kosong/nil")
            return
        end

        for _, c in ipairs(candidates) do
            local already = s.listings and s.listings[c.prod.id] and s.listings[c.prod.id].active
            if not already and activeCount < maxListings then
                if ensureListing(c.prod.id, c.price) then
                    activeCount = activeCount + 1
                    already = true
                end
            end

            if already then
                if not hasActiveCampaignFor(c.prod.id) then
                    if activeCampaignCount >= maxCampaigns then
                        shipLog("Skip launch ads " .. c.prod.name .. ": slot campaign penuh (" .. activeCampaignCount .. "/" .. maxCampaigns .. ")")
                    else
                        local remainingSlots = math.max(1, maxCampaigns - activeCampaignCount)
                        local curBudget = availableBudget()
                        local targetSpend = (curBudget * AD_BUDGET_SPEND_PCT) / remainingSlots
                        local plat = bestPlatform(targetSpend)
                        if not plat then
                            shipLog("Skip launch ads " .. c.prod.name .. ": ga ada platform yang unlocked")
                        else
                            local prevBudget, hadOrders = lastCampaignResultFor(c.prod.id)
                            local budgetPreset = pickBudgetPreset(targetSpend, prevBudget, hadOrders, c.prod.comp, c.audMult)
                            if budgetPreset then
                                launchAdFor({ prod = c.prod, platform = plat, aud = c.aud, hl = c.hl }, budgetPreset, hours)
                                activeCampaignCount = activeCampaignCount + 1
                            else
                                shipLog("Skip launch ads " .. c.prod.name .. ": budget available ga cukup buat preset terkecil")
                            end
                        end
                    end
                end
            end
        end
    end

    local function shipifyCycle()
        shipLog("--- cycle | cash=" .. cash() .. " ---")
        fulfillAll()
        resolveTickets()
        decideListingAndAds()
        decideSample()
        decideAiPitches()
        tryUpgrade()
    end

    -- Gated loop: only ticks while Shipify.running is on (GUI toggle) and the
    -- hub is still alive (shares `alive` with the Roblux Studio unload switch).
    task.spawn(function()
        while RobluxBot.alive do
            task.wait(LOOP_INTERVAL)
            if Shipify.running then
                local okR, err = pcall(shipifyCycle)
                if not okR then shipLog("cycle error: " .. tostring(err)) end
            end
        end
    end)

    end -- if shipOk
end

-- =====================================================================
-- TRADE X (third job minigame) -- v8 engine (real candle-based trailing
-- TP via TxChart) ported from user's own script, scoped in a do-block
-- like Shipify above so locals don't clash. The four sell-timing %
-- knobs (trail arm / trail drop / trail drop wide / stop loss) are
-- exposed as TradeX.cfg so GUI sliders can tune them; everything else
-- stays as the script's own hardcoded logic.
-- =====================================================================
local TradeX = {
    running = false,
    ok = false,
    cfg = {
        trailArmPct      = 4,    -- TRAIL_ARM_PCT   (0.04) * 100
        trailDropPct     = 3,    -- TRAIL_DROP_PCT  (0.03) * 100
        trailDropWidePct = 4.5,  -- TRAIL_DROP_WIDE (0.045) * 100
        slPct            = 6,    -- abs(STOP_LOSS_PCT) (0.06) * 100
    },
}

do
    local tradeOk, MarketData = pcall(function()
        return require(ETM:WaitForChild("Shared"):WaitForChild("MarketData"))
    end)
    TradeX.ok = tradeOk
    if tradeOk then

    local LOOP_INTERVAL   = 15
    local CASH_BUFFER_PCT = 0.25
    local MAX_SPEND_PCT   = 0.25
    local MAX_IMPACT      = 0.03
    local MAX_HOLDINGS    = 5

    -- trailing take-profit based on REAL in-game candles.
    -- Read live from TradeX.cfg (GUI sliders) every check, /100 to get
    -- back to the script's original 0..1 fraction. Defaults above match
    -- the script's own TRAIL_ARM_PCT/TRAIL_DROP_PCT/TRAIL_DROP_WIDE/STOP_LOSS_PCT.

    local DIP_THRESHOLD   = -0.03
    local NEWS_FRESH_SEC  = 120

    local TREND_NEGATIVE_BLOCK = -0.10
    local TREND_POSITIVE_ENTRY = 0.15
    local TREND_CONF_BONUS     = 0.20
    local TREND_EXIT_THRESHOLD = -0.20

    local ALLOWED_CATS = { stock = true, tech = true }

    local CONF_SIZE_MULT = {
        low = 0.5,
        medium = 0.8,
        high = 1.0,
    }

    -- per-symbol trailing state (candle-based)
    local lastK    = {}
    local peakHigh = {}
    local armed    = {}

    local function tradeLog(s) end

    local function cash()
        return (Net.state.core or {}).cash or 0
    end

    local function mkt()
        return Net.state.mkt or { px = {}, news = {} }
    end

    local function acct()
        return Net.state.trade or { pos = {} }
    end

    local function activeTrends()
        return (Net.state.trends or {}).active or {}
    end

    local function availableBudget()
        local c = cash() / 100
        return math.max(0, c * (1 - CASH_BUFFER_PCT))
    end

    local function countHoldings()
        local n = 0
        for _, p in pairs(acct().pos or {}) do
            if (p.q or 0) > 0 then n = n + 1 end
        end
        return n
    end

    local function avgCostOf(sym)
        local pos = (acct().pos or {})[sym]
        if not pos or not pos.q or pos.q <= 0 or not pos.cost then
            return nil
        end
        return (pos.cost / 100) / pos.q
    end

    local function sizedBuyQty(sym, price, fee, budgetDollar)
        local qty = math.floor(budgetDollar / (price * (1 + fee) * 1.01))
        if qty < 1 then return 0 end
        local budgetCents = budgetDollar * 100
        for _ = 1, 8 do
            local ok, q = pcall(function()
                return Net.request("TxQuote", sym, "buy", qty)
            end)
            if ok and q and q.ok then
                if q.total <= budgetCents and q.impact <= MAX_IMPACT then
                    return qty, q
                end
                local shrink = (q.impact and q.impact > MAX_IMPACT) and 0.6 or 0.85
                qty = math.floor(qty * shrink)
                if qty < 1 then return 0 end
            else
                return 0
            end
        end
        return 0
    end

    local function freshBullishSymbols()
        local nowT = os.time()
        local result = {}
        for _, n in ipairs(mkt().news or {}) do
            if n.x and n.x > 0 and n.s then
                local assetDef = MarketData.bySym and MarketData.bySym[n.s]
                local cat = assetDef and assetDef.cat
                if cat and ALLOWED_CATS[cat] then
                    local age = nowT - (n.m or 0)
                    if age >= 0 and age <= NEWS_FRESH_SEC then
                        result[n.s] = true
                    end
                end
            end
        end
        return result
    end

    local function hasFreshNegativeNews(sym)
        local nowT = os.time()
        for _, n in ipairs(mkt().news or {}) do
            if n.s == sym and n.x and n.x < 0 then
                local age = nowT - (n.m or 0)
                if age >= 0 and age <= NEWS_FRESH_SEC then
                    return true
                end
            end
        end
        return false
    end

    local function outlookSymbols()
        local bullish, bearish = {}, {}
        for sym, data in pairs(mkt().px or {}) do
            local assetDef = MarketData.bySym and MarketData.bySym[sym]
            local cat = assetDef and assetDef.cat
            if cat and ALLOWED_CATS[cat] and data.out and data.out.label then
                local label = data.out.label
                local conf = data.out.conf or "low"
                if label == "Bullish" then
                    table.insert(bullish, { sym = sym, data = data, cat = cat, conf = conf })
                elseif label == "Bearish" then
                    table.insert(bearish, { sym = sym, data = data, cat = cat, conf = conf })
                end
            end
        end
        return bullish, bearish
    end

    local function categoryTrendScore(cat)
        local score = 0
        for _, t in ipairs(activeTrends()) do
            local eff = t.effects or {}
            if eff.assetCat and eff.assetCat[cat] then
                score = score + eff.assetCat[cat]
            end
        end
        return score
    end

    local function assetTrendScore(sym)
        local score = 0
        for _, t in ipairs(activeTrends()) do
            local eff = t.effects or {}
            if eff.asset and eff.asset[sym] then
                score = score + eff.asset[sym]
            end
        end
        return score
    end

    local function trendScore(sym, cat)
        return categoryTrendScore(cat) + assetTrendScore(sym)
    end

    local function clearTrailState(sym)
        lastK[sym] = nil
        peakHigh[sym] = nil
        armed[sym] = nil
    end

    local function fetchLatestClosedCandle(sym)
        local ok, res = pcall(function()
            return Net.request("TxChart", sym)
        end)
        if not ok or not res or not res.ok or not res.c or #res.c == 0 then
            return nil
        end
        local last = res.c[#res.c]
        if not last then return nil end
        return { o = last[1], h = last[2], l = last[3], c = last[4] }
    end

    local function decideBuy()
        if countHoldings() >= MAX_HOLDINGS then
            tradeLog("skip buy: max holdings reached")
            return
        end
        local budget = availableBudget()
        if budget <= 0 then return end

        local positions = acct().pos or {}
        local bullishOutlook = select(1, outlookSymbols())
        local bullishNews = freshBullishSymbols()

        local momentumCandidates = {}
        local outlookCandidates  = {}
        local trendCandidates    = {}
        local dipCandidates      = {}

        for sym, data in pairs(mkt().px or {}) do
            local assetDef = MarketData.bySym and MarketData.bySym[sym]
            local cat = assetDef and assetDef.cat
            if cat and ALLOWED_CATS[cat] then
                local already = positions[sym] and (positions[sym].q or 0) > 0
                if not already then
                    local tScore = trendScore(sym, cat)
                    if tScore >= TREND_NEGATIVE_BLOCK then
                        if bullishNews[sym] then
                            table.insert(momentumCandidates, { sym = sym, data = data, cat = cat, tScore = tScore })
                        end
                        if tScore >= TREND_POSITIVE_ENTRY then
                            table.insert(trendCandidates, { sym = sym, data = data, cat = cat, tScore = tScore })
                        end
                        local chg = data.chg or 0
                        if chg <= DIP_THRESHOLD and not hasFreshNegativeNews(sym) then
                            table.insert(dipCandidates, { sym = sym, data = data, chg = chg, cat = cat, tScore = tScore })
                        end
                    end
                end
            end
        end

        for _, c in ipairs(bullishOutlook) do
            local already = positions[c.sym] and (positions[c.sym].q or 0) > 0
            local tScore = trendScore(c.sym, c.cat)
            if not already and tScore >= TREND_NEGATIVE_BLOCK then
                c.tScore = tScore
                table.insert(outlookCandidates, c)
            end
        end

        local pick, mode, confMult
        if #momentumCandidates > 0 then
            pick = momentumCandidates[1]
            mode = "momentum"
            confMult = 1.0
        elseif #outlookCandidates > 0 then
            pick = outlookCandidates[1]
            mode = "outlook"
            confMult = CONF_SIZE_MULT[pick.conf] or CONF_SIZE_MULT.low
        elseif #trendCandidates > 0 then
            table.sort(trendCandidates, function(a, b) return a.tScore > b.tScore end)
            pick = trendCandidates[1]
            mode = "trend"
            confMult = 0.8
        elseif #dipCandidates > 0 then
            table.sort(dipCandidates, function(a, b) return a.chg < b.chg end)
            pick = dipCandidates[1]
            mode = "dip"
            confMult = 0.6
        else
            tradeLog("no candidates (momentum/outlook/trend/dip, stock/tech only, trend-filtered) this cycle")
            return
        end

        if mode ~= "trend" and pick.tScore and pick.tScore > 0 then
            confMult = math.min(1.0, confMult + TREND_CONF_BONUS)
        end

        local sym, data = pick.sym, pick.data
        local catParams = MarketData.catById[data.cat] or MarketData.catById.stock
        local fee = catParams.fee or 0.01
        local spendCap = budget * MAX_SPEND_PCT * confMult

        local qty = sizedBuyQty(sym, data.p, fee, spendCap)
        if qty < 1 then
            tradeLog(string.format("skip %s [%s]: qty too small (price $%.2f, spendCap $%.2f)", sym, mode, data.p, spendCap))
            return
        end

        local ok, res = pcall(function()
            return Net.request("TxBuy", sym, qty)
        end)
        if ok and res and res.ok then
            local confNote = pick.conf and (" conf=" .. pick.conf) or ""
            local trendNote = pick.tScore and string.format(" trend=%.2f", pick.tScore) or ""
            tradeLog(string.format("BUY %s [%s/%s%s%s] x%d (chg %.1f%%, total $%.2f)",
                sym, pick.cat, mode, confNote, trendNote, qty, (data.chg or 0) * 100, (res.total or 0) / 100))
        else
            tradeLog("buy failed for " .. sym .. ": " .. tostring(res and res.err or "unknown"))
        end
    end

    local function decideSell()
        local positions = acct().pos or {}
        local prices = mkt().px or {}
        local _, bearishOutlook = outlookSymbols()
        local bearishSet = {}
        for _, c in ipairs(bearishOutlook) do
            bearishSet[c.sym] = c.conf
        end

        for sym in pairs(lastK) do
            local p = positions[sym]
            if not p or (p.q or 0) <= 0 then
                clearTrailState(sym)
            end
        end

        -- GUI-tunable sell thresholds, converted back from % to 0..1 fraction.
        local trailArmPct   = (TradeX.cfg.trailArmPct or 4) / 100
        local trailDropPct  = (TradeX.cfg.trailDropPct or 3) / 100
        local trailDropWide = (TradeX.cfg.trailDropWidePct or 4.5) / 100
        local stopLossPct   = -(TradeX.cfg.slPct or 6) / 100

        for sym, pos in pairs(positions) do
            local qty = pos.q or 0
            if qty > 0 then
                local avg = avgCostOf(sym)
                if not avg then
                    tradeLog("skip sell-check " .. sym .. ": cost basis unavailable")
                else
                    local data = prices[sym]
                    if data then
                        local pnlPct = (data.p - avg) / avg
                        local assetDef = MarketData.bySym and MarketData.bySym[sym]
                        local cat = assetDef and assetDef.cat
                        local tScore = cat and trendScore(sym, cat) or 0

                        if not armed[sym] and pnlPct >= trailArmPct then
                            armed[sym] = true
                        end

                        local shouldExit = false
                        local exitReason = nil

                        if armed[sym] then
                            local curK = data.k
                            if curK ~= nil and curK ~= lastK[sym] then
                                lastK[sym] = curK
                                local candle = fetchLatestClosedCandle(sym)
                                if candle then
                                    peakHigh[sym] = math.max(peakHigh[sym] or candle.h, candle.h)
                                end
                            end
                            if peakHigh[sym] then
                                local dropPct = tScore > 0 and trailDropWide or trailDropPct
                                if data.p <= peakHigh[sym] * (1 - dropPct) then
                                    shouldExit = true
                                    exitReason = string.format(
                                        "trail-TP(peak %.4f -> live %.4f, pnl %.1f%%)",
                                        peakHigh[sym], data.p, pnlPct * 100)
                                end
                            end
                        end

                        if not shouldExit and pnlPct <= stopLossPct then
                            shouldExit = true
                            exitReason = "SL"
                        elseif not shouldExit and bearishSet[sym] then
                            shouldExit = true
                            exitReason = "outlook-bearish(" .. bearishSet[sym] .. ")"
                        elseif not shouldExit and tScore <= TREND_EXIT_THRESHOLD then
                            shouldExit = true
                            exitReason = string.format("trend-negative(%.2f)", tScore)
                        end

                        if shouldExit then
                            local ok, res = pcall(function()
                                return Net.request("TxSell", sym, qty)
                            end)
                            if ok and res and res.ok then
                                clearTrailState(sym)
                                tradeLog(string.format("SELL %s x%d [%s] (pnl %.1f%%, got $%.2f)", sym, qty, exitReason, pnlPct * 100, (res.total or 0) / 100))
                            else
                                tradeLog("sell failed for " .. sym .. ": " .. tostring(res and res.err or "unknown"))
                            end
                        end
                    end
                end
            end
        end
    end

    local function tradeXCycle()
        tradeLog(string.format("--- cycle | cash=%d | holdings=%d ---", cash(), countHoldings()))
        decideSell()
        decideBuy()
    end

    -- Gated loop: only ticks while TradeX.running is on (GUI toggle) and the
    -- hub is still alive.
    task.spawn(function()
        while RobluxBot.alive do
            task.wait(LOOP_INTERVAL)
            if TradeX.running then
                local okR, err = pcall(tradeXCycle)
                if not okR then tradeLog("cycle error: " .. tostring(err)) end
            end
        end
    end)

    end -- if tradeOk
end

-- =====================================================================
-- FLEXGRAM (fourth job minigame) -- v2 auto-post engine ported from
-- user's own standalone script (flexgram-autopost-v2.lua), scoped in a
-- do-block like Shipify/TradeX above. Subject dropdown is kept, but now
-- means "force this subject" -- the first entry is "Auto (bot decides)"
-- (selectedId = nil), which lets pickSubject() choose by score like the
-- original standalone engine did.
-- =====================================================================
local AUTO_SUBJECT_LABEL = "Auto (bot decides)"

local FlexGram = {
    running = false,
    ok = false,
    selectedId = nil,   -- nil = auto-pick; GUI dropdown can force one subject id
    dropdownValues = {},
    labelToId = {},
    cfg = {
        autoCreateProfile = true,
        profileBio    = "honest",
        profileTheme  = "real",
        profileAvatar = "hoodie",

        maxFakeRisk     = 39,       -- %, just under the game's own "high risk" cutoff (>=40%)
        maxSpendPerPost = 300000,   -- $3,000 ceiling rent per post (cents), on top of the cash guard below

        usePromotion  = true,
        maxPromoLevel = 3,         -- 1=no promo, 2=$50, 3=$500, 4=$5000 (clamped to FlexData.PROMOS count)

        acceptSponsors = true,
        acceptNegativeInfluenceSponsors = false,
        minSponsorPay  = 0,

        -- cash guard, same 3 layers as the standalone script
        minCashReserve            = 500000,   -- $5,000 floor, never touched
        fallbackSpendFractionOfNW = 0.001,    -- if no cash field detected, max spend = 0.1% net worth
        maxSessionSpend           = 3000000,  -- $30,000 total cap for this run

        scandalChoiceIndex = 1,
        checkInterval       = 2,
    },
}

function FlexGram.resetSessionSpend()
    FlexGram._spentSession, FlexGram._warnedLimit = 0, false
end
FlexGram.resetSessionSpend()

do
    local flexOk, FlexData = pcall(function()
        return require(ETM:WaitForChild("Shared"):WaitForChild("FlexData"))
    end)
    FlexGram.ok = flexOk
    if flexOk then

    local function flexLog(s) end -- stub, same style as Shipify/TradeX (silent unless pcall errors)

    -- ---------- cash / budget guard (ported as-is) ----------
    local function getAvailableCash()
        local core = Net.state.core or {}
        local candidates = { core.cash, core.bank, core.liquid, core.balance, core.money }
        for _, v in ipairs(candidates) do
            if type(v) == "number" then return v end
        end
        return nil
    end

    local function canAfford(cost)
        if cost <= 0 then return true end
        if FlexGram._spentSession + cost > FlexGram.cfg.maxSessionSpend then
            if not FlexGram._warnedLimit then
                FlexGram._warnedLimit = true
                flexLog("session spend limit reached, free posts only from here")
            end
            return false
        end
        local cash = getAvailableCash()
        if cash then
            return (cash - cost) >= FlexGram.cfg.minCashReserve
        else
            local nw = (Net.state.core or {}).nw or (Net.state.flex or {}).nw or 0
            return cost <= nw * FlexGram.cfg.fallbackSpendFractionOfNW
        end
    end

    -- ---------- profile ----------
    local function ensureProfile()
        local flex = Net.state.flex or {}
        if flex.profile then return true end

        local handle = game:GetService("Players").LocalPlayer.Name .. tostring(math.random(10, 99))
        local res = Net.request("FxProfile", {
            handle = handle,
            bio    = FlexGram.cfg.profileBio,
            theme  = FlexGram.cfg.profileTheme,
            avatar = FlexGram.cfg.profileAvatar,
        })
        if res and res.ok then
            flexLog("profile created: @" .. handle)
            return true
        else
            flexLog("profile creation failed: " .. tostring(res and res.err))
            return false
        end
    end

    -- ---------- post selection (unified ranking + variety) ----------
    local function bestAudience(subject)
        local bestId, bestMult = "everyone", 1
        if subject.aud then
            for id, mult in pairs(subject.aud) do
                if mult > bestMult then bestId, bestMult = id, mult end
            end
        end
        return bestId, bestMult
    end

    local function bestFilter()
        local best = FlexData.FILTERS[1]
        for _, f in ipairs(FlexData.FILTERS) do
            if f.appeal > best.appeal then best = f end
        end
        return best
    end

    local function weightedPick(list) -- list = { {item=..., value=...}, ... } already sorted desc
        local top = {}
        for i = 1, math.min(3, #list) do top[i] = list[i] end
        local total = 0
        for _, c in ipairs(top) do total = total + math.max(c.value, 0.01) end
        local r = math.random() * total
        for _, c in ipairs(top) do
            r = r - math.max(c.value, 0.01)
            if r <= 0 then return c.item end
        end
        return top[1] and top[1].item or list[1].item
    end

    local function pickSubject(nw)
        -- GUI dropdown override: user forced a specific subject instead of "Auto"
        if FlexGram.selectedId then
            for _, s in ipairs(FlexData.SUBJECTS) do
                if s.id == FlexGram.selectedId then
                    local isReal = s.realAt and nw >= s.realAt
                    if (isReal or s.fake < FlexGram.cfg.maxFakeRisk / 100)
                        and s.rent <= FlexGram.cfg.maxSpendPerPost and canAfford(s.rent) then
                        return s
                    end
                    break -- forced pick not affordable/too risky right now -> fall through to auto-pick
                end
            end
        end

        local candidates = {}
        for _, s in ipairs(FlexData.SUBJECTS) do
            local isReal = s.realAt and nw >= s.realAt
            local riskOk = isReal or (s.fake < FlexGram.cfg.maxFakeRisk / 100)
            local costOk = s.rent <= FlexGram.cfg.maxSpendPerPost and canAfford(s.rent)
            if riskOk and costOk then
                local _, audMult = bestAudience(s)
                table.insert(candidates, { item = s, value = s.appeal * audMult })
            end
        end
        if #candidates == 0 then
            -- safest fallback: free & zero fake, always usable regardless of cash
            for _, s in ipairs(FlexData.SUBJECTS) do
                if s.rent == 0 and s.fake == 0 then
                    local _, audMult = bestAudience(s)
                    table.insert(candidates, { item = s, value = s.appeal * audMult })
                end
            end
        end
        table.sort(candidates, function(a, b) return a.value > b.value end)
        return weightedPick(candidates)
    end

    local function pickCaption(allowFake)
        local candidates = {}
        for _, c in ipairs(FlexData.CAPTIONS) do
            if c.fake <= allowFake then
                table.insert(candidates, { item = c, value = c.appeal })
            end
        end
        table.sort(candidates, function(a, b) return a.value > b.value end)
        if #candidates == 0 then return FlexData.CAPTIONS[1] end
        return weightedPick(candidates)
    end

    local function buildForm(nw)
        local subject = pickSubject(nw)
        local isReal  = subject.realAt and nw >= subject.realAt
        local allowFake = isReal and 1 or (FlexGram.cfg.maxFakeRisk / 100)

        local caption = pickCaption(allowFake)
        local filter  = bestFilter()
        local audId   = bestAudience(subject)

        return {
            subject = subject.id,
            caption = caption.id,
            filter  = filter.id,
            time    = "evening", -- mult 1.25x, always highest & free
            aud     = audId,
            promo   = 1,
        }, subject.rent
    end

    local function choosePromo(form, subjectRent)
        if not FlexGram.cfg.usePromotion then return 1, 0 end
        local flex = Net.state.flex or {}
        local maxLevel = math.min(FlexGram.cfg.maxPromoLevel, #FlexData.PROMOS)

        if flex.insights then
            local bestLevel, bestCost, bestRatio = 1, 0, -math.huge
            for level = 1, maxLevel do
                local cost = FlexData.PROMOS[level].cents
                if canAfford(subjectRent + cost) then
                    local testForm = table.clone(form)
                    testForm.promo = level
                    local res = Net.request("FxPredict", testForm)
                    if res and res.ok then
                        local ratio = res.reach / (1 + cost)
                        if ratio > bestRatio then
                            bestRatio, bestLevel, bestCost = ratio, level, cost
                        end
                    end
                end
            end
            return bestLevel, bestCost
        else
            -- no Insights to compare against yet -> take the highest still-affordable level
            for level = maxLevel, 1, -1 do
                local cost = FlexData.PROMOS[level].cents
                if canAfford(subjectRent + cost) then
                    return level, cost
                end
            end
            return 1, 0
        end
    end

    -- ---------- sponsor & scandal ----------
    local function handleSponsor()
        local flex = Net.state.flex or {}
        local offer = flex.offer
        if not offer or not FlexGram.cfg.acceptSponsors then return end

        local accept = offer.pay >= FlexGram.cfg.minSponsorPay
            and (offer.inf >= 0 or FlexGram.cfg.acceptNegativeInfluenceSponsors)
        local res = Net.request("FxSponsor", accept)
        if res and res.ok then
            flexLog((accept and "accepted sponsor: " or "declined sponsor: ") .. offer.name)
        end
    end

    local function handleScandal()
        local flex = Net.state.flex or {}
        local scandal = flex.scandal
        if not scandal then return end

        local choice = scandal.choices[FlexGram.cfg.scandalChoiceIndex] or scandal.choices[1]
        if not choice then return end
        local res = Net.request("FxRespond", choice.id)
        if res then
            flexLog(res.note or (res.ok and "handled the scandal" or "scandal response failed"))
        end
    end

    -- ---------- main cycle ----------
    local function flexCycle()
        local core = Net.state.core or {}
        if not (core.unlocks and core.unlocks.flexgram) then return end

        if FlexGram.cfg.autoCreateProfile then
            if not ensureProfile() then return end
        end

        local flex = Net.state.flex or {}
        if not flex.profile then return end

        handleSponsor()
        handleScandal()

        if (flex.nextPostIn or 0) <= 0 then
            local nw = core.nw or flex.nw or 0
            local form, subjectRent = buildForm(nw)
            local promoLevel, promoCost = choosePromo(form, subjectRent)
            form.promo = promoLevel

            local res = Net.request("FxPost", form)
            if res and res.ok then
                FlexGram._spentSession = FlexGram._spentSession + subjectRent + promoCost
                flexLog("posted (" .. form.subject .. "). reach ~" .. tostring(res.reach))
            else
                flexLog("post failed: " .. tostring(res and res.err))
            end
        end
    end

    -- ---------- subject dropdown (GUI override list) ----------
    function FlexGram.buildSubjectDropdownValues(nw)
        nw = nw or ((Net.state.core or {}).nw or (Net.state.flex or {}).nw or 0)
        local values, labelToId = { AUTO_SUBJECT_LABEL }, {}
        local real, staged = {}, {}

        for _, s in ipairs(FlexData.SUBJECTS) do
            local isReal = s.realAt and nw >= s.realAt
            local price  = s.rent > 0 and ("$" .. string.format("%d", s.rent / 100)) or "Free"
            local tag
            if isReal then
                tag = "REAL FLEX"
            elseif s.fake >= 0.4 then
                tag = "HIGH RISK"
            elseif s.fake > 0 then
                tag = "STAGED"
            else
                tag = "AUTHENTIC"
            end

            local cleanName = s.name:gsub(" %(.-%)", "")
            local label = "[" .. tag .. "] " .. cleanName .. " - " .. price
            labelToId[label] = s.id

            if isReal then
                table.insert(real, label)
            else
                table.insert(staged, label)
            end
        end

        for _, l in ipairs(real) do table.insert(values, l) end
        for _, l in ipairs(staged) do table.insert(values, l) end
        return values, labelToId
    end

    FlexGram.dropdownValues, FlexGram.labelToId = FlexGram.buildSubjectDropdownValues()

    -- Gated loop: only ticks while FlexGram.running is on (GUI toggle) and
    -- the hub is still alive (shares `alive` with the Roblux Studio unload switch).
    task.spawn(function()
        while RobluxBot.alive do
            task.wait(FlexGram.cfg.checkInterval)
            if FlexGram.running then
                local okR, err = pcall(flexCycle)
                if not okR then flexLog("cycle error: " .. tostring(err)) end
            end
        end
    end)

    end -- if flexOk
end

-- =====================================================================
-- EXPORTS -- everything the GUI file needs, nothing more
-- =====================================================================
return {
    ok = true,

    VERSION = VERSION,

    RobluxBot = RobluxBot,  -- .alive / .running (toggle this to start/stop the engine)
    Shipify   = Shipify,    -- .running / .ok / .minDemand
    TradeX    = TradeX,     -- .running / .ok / .cfg
    FlexGram  = FlexGram,   -- .running / .ok / .cfg / .dropdownValues / .labelToId / .selectedId / .buildSubjectDropdownValues

    CONFIG     = CONFIG,
    Net        = Net,
    RobluxData = RobluxData,

    -- unload: stops every loop (alive=false) and every running toggle;
    -- the GUI file still has to Disconnect its own Connections + Destroy the Window
    unload = function()
        RobluxBot.alive = false
        RobluxBot.running = false
        Shipify.running = false
        TradeX.running = false
        FlexGram.running = false
    end,
}

