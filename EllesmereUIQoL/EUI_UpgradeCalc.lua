-------------------------------------------------------------------------------
--  EUI_UpgradeCalc.lua  (part of EllesmereUIQoL)
--  Gear upgrade planner: data tables, game logic, and calculator UI.
--  Frame: EUIUpgCalcFrame | Slash: /euic
-------------------------------------------------------------------------------

EUIUpgCalc      = EUIUpgCalc or {}
EUIUpgCalc.Data = {}

local Calc = EUIUpgCalc
local Data = EUIUpgCalc.Data
local EUI  = EllesmereUI
local PP   = EUI.PP

-------------------------------------------------------------------------------
--  DATA
-------------------------------------------------------------------------------

-- ── SEASON UPDATE: replace all values in Data.tracks each new season. ────────
-- Per track: goldPer (gold per upgrade step), crestName (tooltip display name),
-- hexColor (UI tint, can stay if the crest colour is unchanged), currID (currency
-- ID from Blizzard — check Wowhead or /dump C_CurrencyInfo.GetCurrencyInfo(id)),
-- ranks (ilvl at each of the 6 upgrade ranks, lowest to highest).
-- Add or remove tracks from Data.trackOrder to match the season's track list.
Data.tracks = {
    Adventurer = {
        goldPer = 10, crestName = "Adventurer Crest",
        hexColor = "|cff1eff00", currID = 3383, tier = 1,
        ranks = { 220, 224, 227, 230, 233, 237 },
    },
    Veteran = {
        goldPer = 20, crestName = "Veteran Crest",
        hexColor = "|cff0070dd", currID = 3341, tier = 2,
        ranks = { 233, 237, 240, 243, 246, 250 },
    },
    Champion = {
        goldPer = 30, crestName = "Champion Crest",
        hexColor = "|cffa335ee", currID = 3343, tier = 3,
        ranks = { 246, 250, 253, 256, 259, 263 },
    },
    Hero = {
        goldPer = 40, crestName = "Hero Crest",
        hexColor = "|cffff8000", currID = 3345, tier = 4,
        ranks = { 259, 263, 266, 269, 272, 276 },
    },
    Myth = {
        goldPer = 50, crestName = "Myth Crest",
        hexColor = "|cffffd100", currID = 3347, tier = 5,
        ranks = { 272, 276, 279, 282, 285, 289 },
    },
}

Data.trackOrder = { "Adventurer", "Veteran", "Champion", "Hero", "Myth" }

-- All equippable character slot IDs (paper-doll order; excludes ammo/relic).
Data.equipSlots = { 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17 }

-- Human-readable slot names keyed by slot ID.
Data.slotNames = {
    [1]  = "Head",       [2]  = "Neck",      [3]  = "Shoulder",
    [5]  = "Chest",      [6]  = "Waist",     [7]  = "Legs",
    [8]  = "Feet",       [9]  = "Wrist",     [10] = "Hands",
    [11] = "Ring 1",     [12] = "Ring 2",    [13] = "Trinket 1",
    [14] = "Trinket 2",  [15] = "Back",      [16] = "Main Hand",
    [17] = "Off Hand",
}

-- SEASON UPDATE: if Voidcore (or its equivalent) is removed, set voidcoreBonus=0
-- and clear voidcoreEligibleSlots. If new slots become eligible, add their IDs here.
-- The bonus ilvl value (currently 9) should match the Voidcore item level increase.
Data.voidcoreEligibleSlots = { 13, 14, 16, 17 }
Data.voidcoreBonus         = 9

-- Reverse lookup: currencyID → crestName (built after track table is complete).
local _currIDToCrestName = {}
for _, td in pairs(Data.tracks) do
    if td.currID and td.currID > 0 then
        _currIDToCrestName[td.currID] = td.crestName
    end
end

-- SEASON UPDATE: update these ilvl steps to match the base-crafted tier ilvls
-- for the new season (currently T1–T5 = 246/249/252/255/259).
-- Referenced in GetCraftedInfo; hoisted here so it is allocated once, not per call.
Data.craftedTierSteps = { 246, 249, 252, 255, 259 }

-- SEASON UPDATE: update minIlvl/maxIlvl each new season to match crafted item ilvl caps.
-- minIlvl: lowest ilvl at which an item belongs to this crafted band (checked highest-first).
-- maxIlvl: ilvl ceiling for crafted items in this band.
-- Ordered highest-first so CraftedBandFromIlvl can short-circuit on the first match.
Data.craftedBands = {
    { name = "Myth", minIlvl = 272, maxIlvl = 285 },
    { name = "Hero", minIlvl = 259, maxIlvl = 272 },
    { name = "None", minIlvl = 0,   maxIlvl = 259 },
}
-- Reverse lookup: band name → band data (for O(1) access in ScanItemLink).
Data.craftedBandByName = {}
for _, b in ipairs(Data.craftedBands) do Data.craftedBandByName[b.name] = b end

-------------------------------------------------------------------------------
--  CORE
-------------------------------------------------------------------------------

-- Pointer to the active EllesmereUIDB profile slice for this module.
-- Set on PLAYER_LOGIN once the profile system initialises.
-- All persistent reads/writes go through DB() and Opts() which use this.
local _euicProfileRef = nil
-- Cached direct references to the sub-tables, set once in PLAYER_LOGIN so that
-- every subsequent DB()/Opts() call is a simple local read with no table traversal.
local _dbCache   = nil
local _optsCache = nil

local function DB()
    if _dbCache then return _dbCache end
    local store
    if _euicProfileRef then
        store = _euicProfileRef
    else
        EllesmereUIQoLDB = EllesmereUIQoLDB or {}
        store            = EllesmereUIQoLDB
    end
    store.upgradeCalc       = store.upgradeCalc      or {}
    local db                = store.upgradeCalc
    db.cache                = db.cache               or { slots = {}, ts = 0 }
    db.calibrated           = db.calibrated          or false
    db.queue                = db.queue               or {}
    db.crestManualAdds      = db.crestManualAdds     or {}
    return db
end

local function Opts()
    if _optsCache then return _optsCache end
    local store
    if _euicProfileRef then
        store = _euicProfileRef
    else
        EllesmereUIQoLDB     = EllesmereUIQoLDB or {}
        store                = EllesmereUIQoLDB
    end
    store.upgradeCalcOpts    = store.upgradeCalcOpts or {}
    return store.upgradeCalcOpts
end

-- Exposed so EUI_UpgradeCalc_Options.lua can always read the live opts table,
-- regardless of whether the profile system has been initialised yet.
Calc.GetOptsDB  = function() return Opts() end
Calc.GetCalcDB  = function() return DB()   end  -- exposed for Options reset helper

-- Slot IDs grouped by category, used for filter settings.
Data.slotGroups = {
    Armour    = { 1, 3, 5, 6, 7, 8, 9, 10, 15 },  -- head, shoulder, chest, waist, legs, feet, wrist, hands, back
    Jewellery = { 2, 11, 12 },                      -- neck, ring 1, ring 2
    Trinkets  = { 13, 14 },
    Weapons   = { 16, 17 },
}
-- Build reverse lookup: slotID -> group name
Data.slotToGroup = {}
for grp, ids in pairs(Data.slotGroups) do
    for _, id in ipairs(ids) do Data.slotToGroup[id] = grp end
end

-- Two off-screen tooltips: one for upgrade/Voidforged scans, one for crafted.
local _upgTip = CreateFrame("GameTooltip", "EUIUpgCalcUpgradeTip",
    UIParent, "GameTooltipTemplate")
_upgTip:SetOwner(UIParent, "ANCHOR_NONE")

local _craftTip = CreateFrame("GameTooltip", "EUIUpgCalcCraftedTip",
    UIParent, "GameTooltipTemplate")
_craftTip:SetOwner(UIParent, "ANCHOR_NONE")

local function ForEachTooltipLine(tooltip, fn)
    -- Pre-cache the per-line FontString references using the tooltip's name prefix
    -- so the inner loop avoids a string concat + global lookup on every iteration.
    local prefix = tooltip:GetName() .. "TextLeft"
    for i = 1, tooltip:NumLines() do
        local fs   = _G[prefix .. i]
        local text = fs and fs:GetText()
        if text and text ~= "" then fn(text) end
    end
end

-- Strip WoW inline colour codes from a string.
local function Plain(s)
    return s and (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) or ""
end

-- Returns { slot, link, ilvl } for every equipped item on `unit` (default "player").
function Calc:GetEquippedGear(unit)
    unit = unit or "player"
    local gear = {}
    for _, slot in ipairs(Data.equipSlots) do
        local link = GetInventoryItemLink(unit, slot)
        if link then
            local ilvl = C_Item.GetDetailedItemLevelInfo(link) or 0
            gear[#gear + 1] = { slot = slot, link = link, ilvl = ilvl }
        end
    end
    return gear
end

Calc._tipCache = {}   -- [link] = { track, rank, isCrafted, craftBand, craftMaxIlvl, isVoidforged }

function Calc:ScanItemLink(link)
    if not link then return nil end
    local cached = Calc._tipCache[link]
    if cached then return cached end

    local result = {
        track = nil, rank = nil,
        isCrafted = false, craftBand = nil, craftMaxIlvl = nil,
        isVoidforged = false,
    }

    _upgTip:ClearLines()
    _upgTip:SetHyperlink(link)
    local foundTrack, foundRank, foundVoid = nil, nil, false
    ForEachTooltipLine(_upgTip, function(text)
        if not foundTrack and text:find("Upgrade Level") then
            -- Capture rank and max separately so a future rank cap change (e.g. /8) still works.
            local t, r = text:match("Upgrade Level:%s+(%a+)%s+(%d+)/%d+")
            if t then foundTrack = t; foundRank = tonumber(r) end
        end
        if not foundVoid and Plain(text):find("Ascendant Voidforged") then
            foundVoid = true
        end
    end)
    result.track = foundTrack
    result.rank  = foundRank
    result.isVoidforged = foundVoid

    -- Only scan the crafted tooltip if no upgrade track was found.
    if not foundTrack then
        _craftTip:ClearLines()
        _craftTip:SetHyperlink(link)
        local isCrafted, sawHero, sawMyth = false, false, false
        ForEachTooltipLine(_craftTip, function(raw)
            local t = Plain(raw)
            if t:find("Crafted") or t:find("Optional Reagents") or t:find("Recrafting") or t:find("Made by") then
                isCrafted = true
            end
            if t:find("Hero") then sawHero = true end
            if t:find("Myth") then sawMyth = true end
        end)
        result.isCrafted = isCrafted

        if isCrafted then
            local bname = sawMyth and "Myth" or sawHero and "Hero" or "None"
            local bdata = Data.craftedBandByName[bname]
            result.craftBand    = bname
            result.craftMaxIlvl = bdata and bdata.maxIlvl or 259
        end
    end

    Calc._tipCache[link] = result
    return result
end

-- Returns: trackName (string|nil), rank (number|nil).
function Calc:GetItemTrackAndRank(link)
    local r = self:ScanItemLink(link)
    return r and r.track, r and r.rank
end

-- Shared helper: given an ilvl, returns band ("Myth"/"Hero"/"None") and maxIlvl.
-- Called by both GetCraftedInfo (tooltip fallback) and the PopulateGear heuristic
-- so the two code paths can never silently diverge on a season update.
-- Thresholds are read from Data.craftedBands — update that table each new season.
local function CraftedBandFromIlvl(ilvl)
    for _, band in ipairs(Data.craftedBands) do
        if ilvl >= band.minIlvl then
            return band.name, math.max(band.maxIlvl, ilvl)
        end
    end
    -- Fallback: treat as base crafted (should never be reached; ilvl < 0 is impossible).
    local base = Data.craftedBandByName["None"]
    return "None", math.max(base and base.maxIlvl or 259, ilvl)
end

-- Returns: isCrafted, band, tier, maxIlvl.
function Calc:GetCraftedInfo(link, ilvl)
    local r = self:ScanItemLink(link)
    if not r or not r.isCrafted then return false end
    local band, maxIlvl = r.craftBand or "None", r.craftMaxIlvl or 259

    -- If tooltip gave no band keywords, fall back to ilvl thresholds via shared helper.
    -- (See CraftedBandFromIlvl above for the SEASON UPDATE note.)
    if r.craftBand == "None" then
        band, maxIlvl = CraftedBandFromIlvl(ilvl)
    end

    local tier
    if band == "None" then
        local steps   = Data.craftedTierSteps
        local best, bestDist = 1, math.huge
        for i, s in ipairs(steps) do
            local d = math.abs(ilvl - s)
            if d < bestDist then bestDist = d; best = i end
        end
        tier = best
    end
    return true, band, tier, maxIlvl
end

-- Returns true when the item has "Ascendant Voidforged" in its tooltip.
-- SEASON UPDATE: if the Voidforged modifier is renamed or replaced, update the
-- search string below to match the new tooltip text.
function Calc:IsVoidforged(link)
    local r = self:ScanItemLink(link)
    return r and r.isVoidforged or false
end

-- Returns the ilvl gain from the next upgrade step, or nil if already at max.
-- (Reserved for future use; not currently called by PopulateGear.)
function Calc:GetNextUpgradeGain(item)
    local track, rank = self:GetItemTrackAndRank(item.link)
    if not track or not rank then return nil end
    local td = Data.tracks[track]
    if not td or rank >= #td.ranks then return nil end
    return (td.ranks[rank + 1] or 0) - (td.ranks[rank] or 0)
end

-- Returns a table mapping crestName -> { quantity, cap, earned } for each track.
function Calc:GetPlayerCrests()
    local owned = {}
    for _, td in pairs(Data.tracks) do
        if td.currID and td.currID > 0 then
            local info = C_CurrencyInfo.GetCurrencyInfo(td.currID)
            if info then
                owned[td.crestName] = {
                    quantity = info.quantity    or 0,
                    cap      = (info.maxQuantity and info.maxQuantity > 0) and info.maxQuantity or nil,
                    earned   = info.totalEarned or 0,
                }
            end
        end
    end
    return owned
end

-- Returns detailed cost info for a single item.
-- Non-crafted: trackName, rank, crestCost, goldCost, maxIlvl
-- Crafted:     "Crafted", nil, nil, nil, maxIlvl, tierLabel, band
function Calc:GetItemUpgradeCost(item)
    local track, rank = self:GetItemTrackAndRank(item.link)

    if not track then
        local isCrafted, band, tier, maxIlvl = self:GetCraftedInfo(item.link, item.ilvl)
        if isCrafted then
            local label = (band == "Hero" and "Hero Craft")
                       or (band == "Myth" and "Myth Craft")
                       or (tier and "T" .. tier .. "/5")
                       or "Crafted"
            return "Crafted", nil, nil, nil, maxIlvl, label, band
        end
        return nil
    end

    local td = Data.tracks[track]
    if not td then return nil end

    local db = DB()

    -- Track-based max: always derived from data table, not the API's maxItemLevel
    -- (the NPC API returns the season ceiling for all items, not the track ceiling).
    -- SEASON UPDATE: update Data.tracks ranks array for the new season;
    -- expectedMax derives from the last entry automatically.
    local expectedMax = td.ranks[#td.ranks]
    for _, vs in ipairs(Data.voidcoreEligibleSlots) do
        if vs == item.slot then expectedMax = expectedMax + Data.voidcoreBonus; break end
    end

    -- Priority 1: exact costs from Upgrader NPC API (calibrated).
    local slotCache = db.calibrated and db.cache.slots[item.slot]
    if slotCache and slotCache.crestAmounts then
        local exactCrests = 0
        for _, v in pairs(slotCache.crestAmounts) do exactCrests = exactCrests + v end
        local exactGold = math.floor((slotCache.copperTotal or 0) / 10000)
        return track, rank, exactCrests, exactGold, expectedMax
    end

    -- Priority 2: raw estimate (upgrader scan not available for this slot).
    -- SEASON UPDATE: full price = 20 crests/step. Update if Blizzard changes this.
    local upgradesLeft = #td.ranks - rank
    return track, rank, upgradesLeft * 20, upgradesLeft * td.goldPer, expectedMax
end

function Calc:IsUpgraderOpen()
    return (ItemUpgradeFrame and ItemUpgradeFrame.IsShown and ItemUpgradeFrame:IsShown()) or false
end

local function SelectSlotInUpgrader(loc)
    -- Never touch protected API in combat; would cause taint.
    if not loc or InCombatLockdown() then return false end
    if C_ItemUpgrade and C_ItemUpgrade.ClearItemUpgrade then
        pcall(C_ItemUpgrade.ClearItemUpgrade)
    end
    for _, fnName in ipairs({ "SetItemUpgradeFromItemLocation", "SetItemUpgradeFromLocation" }) do
        if C_ItemUpgrade and C_ItemUpgrade[fnName] then
            if pcall(C_ItemUpgrade[fnName], loc) then return true end
        end
    end
    return false
end

local function TallySlotCosts(info)
    local crestAmounts, copper = {}, 0
    local curr = info.currUpgrade or 0
    for _, lvl in ipairs(info.upgradeLevelInfos or {}) do
        if (lvl.upgradeLevel or 0) > curr then
            copper = copper + (lvl.moneyCost or 0)
            for _, cc in ipairs(lvl.currencyCostsToUpgrade or {}) do
                -- cc.cost is already the correct amount to pay (Blizzard returns 10 for
                -- discounted steps, 20 for full-price steps). No halving needed here.
                crestAmounts[cc.currencyID] = (crestAmounts[cc.currencyID] or 0) + (cc.cost or 0)
            end
        end
    end
    return crestAmounts, copper
end

-- Scans every equipped slot at the Upgrader NPC, building an accurate cost cache.
-- Single-pass: selects each slot via SelectSlotInUpgrader, waits 0.3 s for the
-- Upgrader frame to populate async data for that slot, then reads the result via
-- C_ItemUpgrade.GetItemUpgradeItemInfo() (no arguments — returns data for the
-- currently-selected slot). Passing a loc argument is silently ignored by the API.
function Calc:ScanEquippedAtUpgrader(onDone)
    if InCombatLockdown() then
        if onDone then onDone(false) end
        return
    end
    if Calc._scanning then
        if onDone then onDone(false) end
        return
    end
    local db = DB()
    if not self:IsUpgraderOpen() then
        if onDone then onDone(false) end
        return
    end

    Calc._scanning = true
    Calc._tipCache = {}

    -- Build into a fresh scratch table; only swap into db.cache on success.
    local newSlots = {}
    local slots    = Data.equipSlots
    local total    = #slots

    local function onScanDone(ok)
        Calc._scanning = false
        if ok then
            db.cache      = { slots = newSlots, ts = time() }
            db.calibrated = true
        end
        if onDone then onDone(ok) end
    end

    local function saveSlotInfo(slotID, info)
        if not (info and info.upgradeLevelInfos) then return end
        local crestAmounts, copperTotal = TallySlotCosts(info)
        newSlots[slotID] = {
            crestAmounts = crestAmounts,
            copperTotal  = copperTotal,
        }
    end

    -- Single-pass scan: select each slot, wait 0.3 s for the Upgrader frame to
    -- populate async data, then call GetItemUpgradeItemInfo() with NO arguments
    -- (the API returns data for whichever slot is currently selected; passing a
    -- loc argument is silently ignored and the call returns nil).
    local si = 1
    local function scanNext()
        if InCombatLockdown() then onScanDone(false); return end
        if si > total then onScanDone(true); return end
        local slotID = slots[si]
        local loc    = ItemLocation and ItemLocation:CreateFromEquipmentSlot(slotID)
        if loc and SelectSlotInUpgrader(loc) then
            -- Wait for the Upgrader frame to load this slot's data, then read it.
            C_Timer.After(0.3, function()
                if InCombatLockdown() then onScanDone(false); return end
                local info = C_ItemUpgrade and C_ItemUpgrade.GetItemUpgradeItemInfo
                    and C_ItemUpgrade.GetItemUpgradeItemInfo()
                saveSlotInfo(slotID, info)
                si = si + 1
                scanNext()
            end)
        else
            -- Slot has no item or select failed; skip it.
            si = si + 1
            C_Timer.After(0.05, scanNext)
        end
    end

    scanNext()
end

function Calc:ClearCache()
    local db = DB()
    db.cache      = { slots = {}, ts = 0 }
    db.calibrated = false
end

-- Rescans a single slot at the Upgrader NPC and updates the cache entry for it.
-- Used after an upgrade so the display reflects the new remaining cost immediately.
-- Calls onDone(ok) when finished; ok=false if the NPC is closed, combat fires, or
-- the API returns no data for the slot.
function Calc:RescanSlot(slotID, onDone)
    if InCombatLockdown() or Calc._scanning then
        if onDone then onDone(false) end; return
    end
    if not self:IsUpgraderOpen() then
        if onDone then onDone(false) end; return
    end
    local loc = ItemLocation and ItemLocation:CreateFromEquipmentSlot(slotID)
    if not loc or not SelectSlotInUpgrader(loc) then
        if onDone then onDone(false) end; return
    end
    -- Guard the async window with _scanning so a second upgrade event within
    -- 0.3 s can't launch a concurrent rescan and overwrite the wrong slot.
    Calc._scanning = true
    local db = DB()
    C_Timer.After(0.3, function()
        Calc._scanning = false
        if InCombatLockdown() then
            if onDone then onDone(false) end; return
        end
        local info = C_ItemUpgrade and C_ItemUpgrade.GetItemUpgradeItemInfo
            and C_ItemUpgrade.GetItemUpgradeItemInfo()
        if info and info.upgradeLevelInfos then
            local crestAmounts, copperTotal = TallySlotCosts(info)
            db.cache        = db.cache or { slots = {}, ts = 0 }
            db.cache.slots  = db.cache.slots or {}
            db.cache.slots[slotID] = {
                crestAmounts = crestAmounts,
                copperTotal  = copperTotal,
            }
        end
        if onDone then onDone(true) end
    end)
end

-------------------------------------------------------------------------------
--  UI
-------------------------------------------------------------------------------

local function SolidTex(p,l,r,g,b,a) return EUI.SolidTex(p,l,r,g,b,a) end
local function MFont(p,s,f,r,g,b,a)  return EUI.MakeFont(p,s,f,r,g,b,a) end

local G    = EUI.ELLESMERE_GREEN
local ROW_H, HDR_H, FRAME_W, FRAME_H = 20, 20, 860, 730

-- Tile layout constants
local TILE_W    = 183
local TILE_H    = 50   -- tile frame height
local TILE_STEP = TILE_H + 5  -- row stride: tile height + gap (used in all layout math)
local TILE_COLS = 3
local TILE_GAP  = 5
local TILE_ROW_W = TILE_COLS * TILE_W + (TILE_COLS - 1) * TILE_GAP  -- 559
local QUEUE_X_OFF    = TILE_ROW_W + 16                                    -- 575
local QUEUE_W        = FRAME_W - 20 - QUEUE_X_OFF                        -- 265

-- Per-track RGB accent colours used on tile left-edge bars
local TRACK_RGB = {
    Adventurer = {0.12, 1.0,  0.0 },
    Veteran    = {0.0,  0.44, 0.87},
    Champion   = {0.64, 0.21, 0.93},
    Hero       = {1.0,  0.50, 0.0 },
    Myth       = {1.0,  0.82, 0.0 },
    Voidforged = {0.55, 0.0,  1.0 },
}

local CREST_COLS = {
    {key="crest",     label="Crest",          x=0,   w=150, align="LEFT"  },
    {key="need",      label="Need",            x=150, w=70,  align="CENTER"},
    {key="owned",     label="Owned",           x=220, w=70,  align="CENTER"},
    {key="missing",   label="Missing",         x=290, w=70,  align="CENTER"},
    {key="cap",       label="Earned / Cap",    x=360, w=130, align="CENTER"},
    {key="weeklyRem", label="Left This Week",  x=490, w=110, align="CENTER"},
}

local f = CreateFrame("Frame", "EUIUpgCalcFrame", UIParent)
PP.Size(f, FRAME_W, FRAME_H)
f:SetPoint("LEFT", UIParent, "LEFT", 30, 0)
f:SetFrameStrata("DIALOG")
f:SetMovable(true)
f:EnableMouse(true)
f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", function(self) self:StartMoving() end)
f:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)
f:Hide()

local fBg = SolidTex(f, "BACKGROUND", 0.05, 0.07, 0.09, 1)
fBg:SetAllPoints(f)

function Calc.ApplyBgOpacity()
    local opts  = Opts()
    local alpha = opts and opts.bgOpacity
    if alpha == nil then alpha = 96 end
    fBg:SetColorTexture(0.05, 0.07, 0.09, alpha / 100)
end

local brd = EUI.MakeBorder(f, 0.13, 0.75, 0.55, 1)
if brd.SetColor then brd:SetColor(0.13, 0.75, 0.55, 1) end

local titleBg = SolidTex(f, "BORDER", 0.08, 0.11, 0.14, 1)
PP.Point(titleBg, "TOPLEFT",  f, "TOPLEFT",  1, -1)
PP.Point(titleBg, "TOPRIGHT", f, "TOPRIGHT", -1, 0)
PP.Height(titleBg, 32)

local titleTxt = MFont(f, 13, "OUTLINE", G.r, G.g, G.b, 1)
PP.Point(titleTxt, "TOPLEFT", f, "TOPLEFT", 12, -10)
titleTxt:SetText("EllesmereUI  |cffffffff- Upgrade Calculator|r")

local closeBtn = CreateFrame("Button", nil, f)
PP.Size(closeBtn, 18, 18)
PP.Point(closeBtn, "TOPRIGHT", f, "TOPRIGHT", -8, -8)
SolidTex(closeBtn, "ARTWORK", 0.7, 0.2, 0.2, 0.9)
local closeTxt = MFont(closeBtn, 11, "OUTLINE", 1, 1, 1, 1)
closeTxt:SetAllPoints()
closeTxt:SetJustifyH("CENTER")
closeTxt:SetText("X")
closeBtn:SetScript("OnClick", function() f:Hide() end)

table.insert(UISpecialFrames, "EUIUpgCalcFrame")

local tabY = -36

local tabSep = SolidTex(f, "BORDER", G.r, G.g, G.b, 0.4)
PP.Point(tabSep, "TOPLEFT",  f, "TOPLEFT",  8,  tabY - 22)
PP.Point(tabSep, "TOPRIGHT", f, "TOPRIGHT", -8, tabY - 22)
PP.Height(tabSep, 1)

-- Row helpers
local function MakeTableHeader(parent, cols, yOffset)
    local hdrBg = SolidTex(parent, "BACKGROUND", 0.1, 0.13, 0.17, 1)
    PP.Point(hdrBg, "TOPLEFT",  parent, "TOPLEFT",  0, yOffset)
    PP.Point(hdrBg, "TOPRIGHT", parent, "TOPRIGHT", 0, yOffset)
    PP.Height(hdrBg, HDR_H)
    for _, col in ipairs(cols) do
        local lbl = MFont(parent, 10, "OUTLINE", G.r, G.g, G.b, 1)
        PP.Point(lbl, "TOPLEFT", parent, "TOPLEFT", col.x + 4, yOffset - 2)
        PP.Width(lbl, col.w)
        lbl:SetJustifyH(col.align)
        lbl:SetText(col.label)
    end
end

local function MakeRow(parent, cols, yOffset, isAlt)
    local row = {}
    if isAlt then
        local bg = SolidTex(parent, "BACKGROUND", 0.08, 0.1, 0.13, 0.5)
        PP.Point(bg, "TOPLEFT",  parent, "TOPLEFT",  0, yOffset)
        PP.Point(bg, "TOPRIGHT", parent, "TOPRIGHT", 0, yOffset)
        PP.Height(bg, ROW_H)
        row.altBg = bg  -- stored so PopulateGear can reposition and hide/show it
    end
    for _, col in ipairs(cols) do
        local cell = MFont(parent, 10, nil, 0.85, 0.85, 0.85, 1)
        PP.Point(cell, "TOPLEFT", parent, "TOPLEFT", col.x + 4, yOffset - 2)
        PP.Width(cell, col.w - 8)
        cell:SetJustifyH(col.align)
        row[col.key] = cell
    end
    return row
end

local function MakeButton(parent, label, w, h, yOff, xOff)
    local btn = CreateFrame("Button", nil, parent)
    PP.Size(btn, w, h)
    PP.Point(btn, "TOPLEFT", parent, "TOPLEFT", xOff, yOff)
    SolidTex(btn, "BACKGROUND", 0.1, 0.14, 0.18, 1)
    local bb = EUI.MakeBorder(btn, 0.13, 0.75, 0.55, 0.6)
    if bb.SetColor then bb:SetColor(0.13, 0.75, 0.55, 0.6) end
    local txt = MFont(btn, 10, "OUTLINE", G.r, G.g, G.b, 1)
    txt:SetAllPoints(); txt:SetJustifyH("CENTER"); txt:SetText(label)
    btn:SetScript("OnEnter", function() txt:SetTextColor(1, 1, 1, 1) end)
    btn:SetScript("OnLeave", function() txt:SetTextColor(G.r, G.g, G.b, 1) end)
    return btn, txt
end

-- Character Pane ──────────────────────────────────────────────────────────────
f.charPane = CreateFrame("Frame", nil, f)
f.charPane:SetAllPoints(f)

local ilvlStatLbl = MFont(f.charPane, 11, "OUTLINE", G.r, G.g, G.b, 1)
PP.Point(ilvlStatLbl, "TOPLEFT", f.charPane, "TOPLEFT", 14, tabY - 26)
ilvlStatLbl:SetText("Current iLvl: -   Max Possible: -")

local cc = CreateFrame("Frame", nil, f.charPane)
PP.Point(cc, "TOPLEFT",  f.charPane, "TOPLEFT",  10, tabY - 46)
PP.Point(cc, "TOPRIGHT", f.charPane, "TOPRIGHT", -10, tabY - 46)
PP.Height(cc, FRAME_H - 100)

-- ── iLvl Timeline bar ──────────────────────────────────────────────────────────
local tlTrack = SolidTex(cc, "BACKGROUND", 0.1, 0.12, 0.16, 1)
PP.Point(tlTrack, "TOPLEFT",  cc, "TOPLEFT",  0, -2)
PP.Point(tlTrack, "TOPRIGHT", cc, "TOPRIGHT", 0, -2)
PP.Height(tlTrack, 16)

local tlFill = SolidTex(cc, "ARTWORK", G.r, G.g, G.b, 0.3)
PP.Point(tlFill, "TOPLEFT", cc, "TOPLEFT", 0, -2)
PP.Height(tlFill, 16)
tlFill:SetWidth(1)  -- updated each refresh

local tlCurLbl = MFont(cc, 9, "OUTLINE", 0.65, 0.65, 0.65, 1)
PP.Point(tlCurLbl, "TOPLEFT", cc, "TOPLEFT", 2, -20)
local tlMaxLbl = MFont(cc, 9, "OUTLINE", G.r, G.g, G.b, 1)
PP.Point(tlMaxLbl, "TOPRIGHT", cc, "TOPRIGHT", -2, -20)
-- ── Tile frames ──────────────────────────────────────────────────────────────────
local ToggleTileQueue  -- forward declaration (defined in queue section)

local tileFrames = {}
for i = 1, 18 do
    local btn = CreateFrame("Button", nil, cc)
    PP.Size(btn, TILE_W, TILE_H)
    btn:Hide()
    local bg = SolidTex(btn, "BACKGROUND", 0.07, 0.09, 0.12, 1)
    bg:SetAllPoints(btn)
    btn.bg = bg
    -- Left accent bar (3 px, track colour)
    local accentBar = SolidTex(btn, "BORDER", 0.5, 0.5, 0.5, 1)
    PP.Point(accentBar, "TOPLEFT",    btn, "TOPLEFT",    0, 0)
    PP.Point(accentBar, "BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 0)
    PP.Width(accentBar, 3)
    btn.accentBar = accentBar
    -- Queue-selection highlight overlay
    local selHL = SolidTex(btn, "OVERLAY", 1, 0.85, 0.1, 0.12)
    selHL:SetAllPoints(btn)
    selHL:Hide()
    btn.selHL = selHL
    -- Top-left: slot name
    local sLbl = MFont(btn, 11, "OUTLINE", 0.9, 0.9, 0.9, 1)
    PP.Point(sLbl, "TOPLEFT", btn, "TOPLEFT", 7, -4)
    PP.Width(sLbl, TILE_W - 82)
    sLbl:SetJustifyH("LEFT")
    btn.sLbl = sLbl
    -- Top-right: current ^ max ilvl
    local iLbl = MFont(btn, 10, "OUTLINE", 0.8, 0.8, 0.8, 1)
    PP.Point(iLbl, "TOPRIGHT", btn, "TOPRIGHT", -5, -4)
    PP.Width(iLbl, 76)
    iLbl:SetJustifyH("RIGHT")
    btn.iLbl = iLbl
    -- Bottom-left: track name
    local tLbl = MFont(btn, 10, "OUTLINE", 0.55, 0.55, 0.55, 1)
    PP.Point(tLbl, "BOTTOMLEFT", btn, "BOTTOMLEFT", 7, 5)
    PP.Width(tLbl, TILE_W - 82)
    tLbl:SetJustifyH("LEFT")
    btn.tLbl = tLbl
    -- Bottom-right: rank badge
    local rLbl = MFont(btn, 10, "OUTLINE", 0.8, 0.8, 0.8, 1)
    PP.Point(rLbl, "BOTTOMRIGHT", btn, "BOTTOMRIGHT", -5, 5)
    PP.Width(rLbl, 76)
    rLbl:SetJustifyH("RIGHT")
    btn.rLbl = rLbl

    btn.tileEntry = nil

    -- Handlers wired ONCE here — no closures created during refresh.
    btn:SetScript("OnClick", function(self)
        if self.tileEntry then ToggleTileQueue(self.tileEntry, self) end
    end)
    btn:SetScript("OnEnter", function(self)
        self.bg:SetColorTexture(0.12, 0.16, 0.22, 1)
        local e = self.tileEntry
        if not e or not EUI.ShowWidgetTooltip then return end
        local lines = {}
        if e.isAtMax then
            lines[#lines + 1] = "|cff20c020At maximum item level|r"
        elseif e.trackKey == "Crafted" then
            lines[#lines + 1] = "Crafted item — cannot be upgraded here"
        elseif e.trackKey then
            local td = Data.tracks[e.trackKey]
            local snap = DB()
            local sc = snap.calibrated and snap.cache.slots[e.slotID] or nil
            if sc and sc.crestAmounts and next(sc.crestAmounts) then
                for cid, amt in pairs(sc.crestAmounts) do
                    local cn = _currIDToCrestName[cid]
                    if cn and amt > 0 then
                        lines[#lines + 1] = amt .. "x  " .. cn
                    end
                end
                local gold = math.floor((sc.copperTotal or 0) / 10000)
                if gold > 0 then lines[#lines + 1] = gold .. "g" end
            elseif (e.crestCost or 0) > 0 then
                lines[#lines + 1] = "~" .. e.crestCost .. "x  " .. (td and td.crestName or "Crest")
                if (e.goldCost or 0) > 0 then
                    lines[#lines + 1] = "~" .. e.goldCost .. "g"
                end
                lines[#lines + 1] = "|cff888888Scan at Upgrader for exact costs|r"
            elseif (e.goldCost or 0) > 0 then
                lines[#lines + 1] = e.goldCost .. "g"
            end
        end
        if #lines > 0 then
            EUI.ShowWidgetTooltip(self, table.concat(lines, "\n"))
        end
    end)
    btn:SetScript("OnLeave", function(self)
        local e = self.tileEntry
        if not e then return end
        if e.isAtMax then
            self.bg:SetColorTexture(0.04, 0.13, 0.05, 1)
        elseif type(e.max) == "number" and (e.max - e.ilvl) >= 10 then
            self.bg:SetColorTexture(0.14, 0.05, 0.04, 1)
        else
            self.bg:SetColorTexture(0.14, 0.10, 0.02, 1)
        end
        if EUI.HideWidgetTooltip then EUI.HideWidgetTooltip() end
    end)

    tileFrames[i] = btn
end

-- Section header labels and group separator line (repositioned each refresh)
local sHdrNeeds    = MFont(cc, 9, "OUTLINE", G.r, G.g, G.b, 1)
local sHdrMax      = MFont(cc, 9, "OUTLINE", 0.48, 0.48, 0.48, 1)
local groupSepLine = SolidTex(cc, "BORDER", 0.25, 0.28, 0.32, 1)
PP.Height(groupSepLine, 1)
PP.Width(groupSepLine, TILE_ROW_W)


-- ── Queue panel ──────────────────────────────────────────────────────────────────
local queuePane = CreateFrame("Frame", nil, cc)
PP.Size(queuePane, QUEUE_W, FRAME_H - 140)
PP.Point(queuePane, "TOPLEFT", cc, "TOPLEFT", QUEUE_X_OFF, -36)

local qHdrBg = SolidTex(queuePane, "BACKGROUND", 0.08, 0.11, 0.15, 1)
PP.Point(qHdrBg, "TOPLEFT",  queuePane, "TOPLEFT",  0, 0)
PP.Point(qHdrBg, "TOPRIGHT", queuePane, "TOPRIGHT", 0, 0)
PP.Height(qHdrBg, 20)
local qHdrLbl = MFont(queuePane, 10, "OUTLINE", G.r, G.g, G.b, 1)
PP.Point(qHdrLbl, "TOPLEFT", queuePane, "TOPLEFT", 4, -2)
qHdrLbl:SetText("UPGRADE QUEUE")
local qSubLbl = MFont(queuePane, 9, "OUTLINE", 0.38, 0.38, 0.38, 1)
PP.Point(qSubLbl, "TOPRIGHT", queuePane, "TOPRIGHT", -4, -2)
qSubLbl:SetText("click tiles to plan")

local qEmptyLbl = MFont(queuePane, 9, "OUTLINE", 0.32, 0.32, 0.32, 1)
PP.Point(qEmptyLbl, "TOPLEFT", queuePane, "TOPLEFT", 4, -24)
qEmptyLbl:SetText("No items queued.")

-- 16 pre-created queue entry rows
local queueEntries = {}
for i = 1, 16 do
    local ef = CreateFrame("Frame", nil, queuePane)
    PP.Size(ef, QUEUE_W, 20)
    PP.Point(ef, "TOPLEFT", queuePane, "TOPLEFT", 0, -(18 + (i - 1) * 20))
    ef:Hide()
    if i % 2 == 0 then
        local ebg = SolidTex(ef, "BACKGROUND", 0.07, 0.09, 0.12, 0.5)
        ebg:SetAllPoints(ef)
    end
    local nLbl = MFont(ef, 9, "OUTLINE", 0.8, 0.8, 0.8, 1)
    PP.Point(nLbl, "TOPLEFT", ef, "TOPLEFT", 4, -2)
    PP.Width(nLbl, QUEUE_W - 84)
    nLbl:SetJustifyH("LEFT")
    local cLbl = MFont(ef, 9, nil, 0.8, 0.8, 0.8, 1)
    PP.Point(cLbl, "TOPRIGHT", ef, "TOPRIGHT", -4, -2)
    PP.Width(cLbl, 82)
    cLbl:SetJustifyH("RIGHT")
    ef.nLbl = nLbl; ef.cLbl = cLbl
    queueEntries[i] = ef
end

local qTotalSep = SolidTex(queuePane, "BORDER", G.r, G.g, G.b, 0.22)
PP.Point(qTotalSep, "TOPLEFT",  queuePane, "TOPLEFT",  0, -42)
PP.Point(qTotalSep, "TOPRIGHT", queuePane, "TOPRIGHT", 0, -42)
PP.Height(qTotalSep, 1)
qTotalSep:Hide()

local qTotalLbl = MFont(queuePane, 9, "OUTLINE", G.r, G.g, G.b, 1)
PP.Point(qTotalLbl, "TOPLEFT", queuePane, "TOPLEFT", 4, -46)
qTotalLbl:SetText("")
qTotalLbl:Hide()

local qClearBtn = MakeButton(queuePane, "Clear Queue", QUEUE_W - 6, 20, -70, 0)
qClearBtn:Hide()

-- Queue state
local queueItems   = {}   -- ordered list of tileEntry tables
local queueSlotSet = {}   -- slotName -> position in queueItems
local _queueLoaded = false  -- true once saved queue has been applied after session start

local crestManualAdds = { ["Hero Crest"] = 0, ["Myth Crest"] = 0 }

-- Persist the current queue (slot IDs only) to the profile DB.
local function SaveQueue()
    local db = DB()
    db.queue = {}
    for i, it in ipairs(queueItems) do db.queue[i] = it.slotID end
end

-- Persist the current crest manual-add offsets to the profile DB.
local function SaveCrestManualAdds()
    local db = DB()
    db.crestManualAdds = db.crestManualAdds or {}
    for k, v in pairs(crestManualAdds) do db.crestManualAdds[k] = v end
end

local function UpdateQueueDisplay()
    local n = #queueItems
    qEmptyLbl:SetText(n == 0 and "No items queued." or "")

    local totalGoldQ, totalCrests = 0, {}
    for i, entry in ipairs(queueItems) do
        local qe = queueEntries[i]
        qe:Show()
        local parts = {}
        if entry.trackKey and entry.trackKey ~= "Crafted" then
            local td = Data.tracks[entry.trackKey]
            if td and (entry.crestCost or 0) > 0 then
                parts[#parts + 1] = entry.crestCost .. " " ..
                    (td.crestName or entry.trackKey):gsub(" Crest", "")
                totalCrests[td.crestName] = (totalCrests[td.crestName] or 0) + entry.crestCost
            end
            if (entry.goldCost or 0) > 0 then
                parts[#parts + 1] = entry.goldCost .. "g"
                totalGoldQ = totalGoldQ + entry.goldCost
            end
        end
        local costStr = #parts > 0 and table.concat(parts, " ") or "|cff20c020Max|r"
        local gain = (not entry.isAtMax and type(entry.max) == "number" and entry.max > entry.ilvl)
            and (entry.max - entry.ilvl) or nil
        local nameStr = gain and (entry.slotName .. " |cff888888+" .. gain .. "|r") or entry.slotName
        qe.nLbl:SetText(nameStr)
        qe.cLbl:SetText(costStr)
    end
    for i = n + 1, 16 do queueEntries[i]:Hide() end

    if n > 0 then
        local parts = {}
        for _, trackName in ipairs(Data.trackOrder) do
            local td   = Data.tracks[trackName]
            local ckey = td and td.crestName or trackName
            local amt  = totalCrests[ckey] or 0
            if amt > 0 then parts[#parts + 1] = amt .. " " .. ckey:gsub(" Crest", "") end
        end
        if totalGoldQ > 0 then parts[#parts + 1] = totalGoldQ .. "g" end

        local sepY = -(18 + n * 20 + 4)
        qTotalSep:ClearAllPoints()
        PP.Point(qTotalSep, "TOPLEFT",  queuePane, "TOPLEFT",  0, sepY)
        PP.Point(qTotalSep, "TOPRIGHT", queuePane, "TOPRIGHT", 0, sepY)
        qTotalLbl:ClearAllPoints()
        PP.Point(qTotalLbl, "TOPLEFT", queuePane, "TOPLEFT", 4, sepY - 4)
        qClearBtn:ClearAllPoints()
        PP.Point(qClearBtn, "TOPLEFT", queuePane, "TOPLEFT", 0, sepY - 28)

        qTotalLbl:SetText(#parts > 0 and table.concat(parts, "  ") or "Nothing needed")
        qTotalLbl:Show(); qTotalSep:Show(); qClearBtn:Show()
    else
        qTotalLbl:Hide(); qTotalSep:Hide(); qClearBtn:Hide()
    end
end

ToggleTileQueue = function(entry, btn)
    local sn = entry.slotName
    if queueSlotSet[sn] then
        local idx = queueSlotSet[sn]
        table.remove(queueItems, idx)
        queueSlotSet = {}
        for i, it in ipairs(queueItems) do queueSlotSet[it.slotName] = i end
        btn.selHL:Hide()
    else
        queueItems[#queueItems + 1] = entry
        queueSlotSet[sn] = #queueItems
        btn.selHL:Show()
    end
    UpdateQueueDisplay()
    SaveQueue()
end

qClearBtn:SetScript("OnClick", function()
    queueItems   = {}
    queueSlotSet = {}
    for _, btn in ipairs(tileFrames) do btn.selHL:Hide() end
    UpdateQueueDisplay()
    SaveQueue()
end)

-- ── Crest section — parented to a repositionable container frame ──────────────
-- crestSection is moved each PopulateGear so the window height stays tight.
local crestSection = CreateFrame("Frame", nil, cc)
PP.Point(crestSection, "TOPLEFT",  cc, "TOPLEFT",  0, -430)  -- initial; overwritten each refresh
PP.Point(crestSection, "TOPRIGHT", cc, "TOPRIGHT", 0, -430)
PP.Height(crestSection, 200)  -- large enough; content determines visible area

local gearSep = SolidTex(crestSection, "BORDER", 0.2, 0.24, 0.28, 1)
PP.Point(gearSep, "TOPLEFT",  crestSection, "TOPLEFT",  0, 4)
PP.Point(gearSep, "TOPRIGHT", crestSection, "TOPRIGHT", 0, 4)
PP.Height(gearSep, 1)

-- Accuracy label floats right of the separator line; updated each PopulateGear.
local crestAccuracyLbl = MFont(crestSection, 9, "OUTLINE", 0.38, 0.38, 0.38, 1)
PP.Point(crestAccuracyLbl, "TOPRIGHT", crestSection, "TOPRIGHT", -4, 12)
crestAccuracyLbl:SetText("")

-- Build crest table header once. The cap column label is kept as a separate
-- reference so it can be shown or hidden without recreating any frames.
do
    local baseCols = { CREST_COLS[1], CREST_COLS[2], CREST_COLS[3], CREST_COLS[4] }
    MakeTableHeader(crestSection, baseCols, 0)
end
local capHdrLbl = MFont(crestSection, 10, "OUTLINE", G.r, G.g, G.b, 1)
PP.Point(capHdrLbl, "TOPLEFT", crestSection, "TOPLEFT", CREST_COLS[5].x + 4, -2)
PP.Width(capHdrLbl, CREST_COLS[5].w)
capHdrLbl:SetJustifyH(CREST_COLS[5].align)
capHdrLbl:SetText(CREST_COLS[5].label)
capHdrLbl:Hide()

local weeklyRemHdrLbl = MFont(crestSection, 10, "OUTLINE", G.r, G.g, G.b, 1)
PP.Point(weeklyRemHdrLbl, "TOPLEFT", crestSection, "TOPLEFT", CREST_COLS[6].x + 4, -2)
PP.Width(weeklyRemHdrLbl, CREST_COLS[6].w)
weeklyRemHdrLbl:SetJustifyH(CREST_COLS[6].align)
weeklyRemHdrLbl:SetText(CREST_COLS[6].label)
weeklyRemHdrLbl:Hide()

-- Forward-declared so crest-row +/-80 buttons can call it.
local PopulateGear

local crestRows = {}
for i = 1, #Data.trackOrder do
    local rowY = -(HDR_H + (i - 1) * ROW_H)
    crestRows[i] = MakeRow(crestSection, CREST_COLS, rowY, i % 2 == 0)
    -- +/-80 buttons on Hero and Myth rows for manually budgeting crafted-item crests
    local tn = Data.trackOrder[i]
    if tn == "Hero" or tn == "Myth" then
        local ckey = Data.tracks[tn].crestName  -- "Hero Crest" / "Myth Crest"
        local mBtn = CreateFrame("Button", nil, crestSection)
        PP.Size(mBtn, 26, 16)
        PP.Point(mBtn, "TOPLEFT", crestSection, "TOPLEFT", 143, rowY - 2)
        local mBg = SolidTex(mBtn, "ARTWORK", 0.18, 0.08, 0.08, 0.9)
        mBg:SetAllPoints(mBtn)
        local mTxt = MFont(mBtn, 8, "OUTLINE", 0.9, 0.45, 0.45, 1)
        mTxt:SetAllPoints(); mTxt:SetJustifyH("CENTER"); mTxt:SetText("-80")
        mBtn:SetScript("OnEnter", function()
            mBg:SetColorTexture(0.28, 0.10, 0.10, 1)
            if EUI.ShowWidgetTooltip then
                EUI.ShowWidgetTooltip(mBtn, "Subtract 80 " .. ckey .. "s from the total.\n"
                    .. "Use this to account for crafted gear\nthat shares this currency.")
            end
        end)
        mBtn:SetScript("OnLeave", function()
            mBg:SetColorTexture(0.18, 0.08, 0.08, 0.9)
            if EUI.HideWidgetTooltip then EUI.HideWidgetTooltip() end
        end)
        mBtn:SetScript("OnClick", function()
            crestManualAdds[ckey] = math.max(0, (crestManualAdds[ckey] or 0) - 80)
            SaveCrestManualAdds()
            PopulateGear()
        end)
        local pBtn = CreateFrame("Button", nil, crestSection)
        PP.Size(pBtn, 26, 16)
        PP.Point(pBtn, "TOPLEFT", crestSection, "TOPLEFT", 200, rowY - 2)
        local pBg = SolidTex(pBtn, "ARTWORK", 0.06, 0.18, 0.08, 0.9)
        pBg:SetAllPoints(pBtn)
        local pTxt = MFont(pBtn, 8, "OUTLINE", 0.45, 0.9, 0.45, 1)
        pTxt:SetAllPoints(); pTxt:SetJustifyH("CENTER"); pTxt:SetText("+80")
        pBtn:SetScript("OnEnter", function()
            pBg:SetColorTexture(0.10, 0.28, 0.10, 1)
            if EUI.ShowWidgetTooltip then
                EUI.ShowWidgetTooltip(pBtn, "Add 80 " .. ckey .. "s to the total.\n"
                    .. "Use this to account for crafted gear\nthat shares this currency.")
            end
        end)
        pBtn:SetScript("OnLeave", function()
            pBg:SetColorTexture(0.06, 0.18, 0.08, 0.9)
            if EUI.HideWidgetTooltip then EUI.HideWidgetTooltip() end
        end)
        pBtn:SetScript("OnClick", function()
            crestManualAdds[ckey] = (crestManualAdds[ckey] or 0) + 80
            SaveCrestManualAdds()
            PopulateGear()
        end)
        crestRows[i].mBtn = mBtn
        crestRows[i].pBtn = pBtn
    end
end

-- Summary label and action buttons — initially anchored at y=0; repositioned
-- every PopulateGear call to sit below the last visible crest row.
local summaryLbl = MFont(crestSection, 11, "OUTLINE", G.r, G.g, G.b, 1)
PP.Point(summaryLbl, "TOPLEFT",  crestSection, "TOPLEFT",  4, 0)
PP.Point(summaryLbl, "TOPRIGHT", crestSection, "TOPRIGHT", 0, 0)
summaryLbl:SetJustifyH("LEFT")
summaryLbl:SetText("Missing Upgrades: -   Gold Needed: -")

local refreshBtn               = MakeButton(crestSection, "Refresh",            140, 22, 0, 0)
local scanBtn, scanBtnTxt      = MakeButton(crestSection, "Update at Upgrader", 160, 22, 0, 150)

-- ── PopulateGear ──────────────────────────────────────────────────────────────
PopulateGear = function()
    local gear  = Calc:GetEquippedGear()
    local owned = Calc:GetPlayerCrests()
    local totalMissing, totalGold, crestNeeds = 0, 0, {}
    local tileEntries = {}

    -- Pre-pass: compute the theoretical max ilvl across ALL equipped slots,
    -- deliberately ignoring slotFilter and hideCrafted so the timeline bar and
    -- "Max Possible" stat always reflect the full character potential.
    -- Running this first also warms _tipCache so the display loop below pays no
    -- extra tooltip scanning cost.
    local maxTotal = 0
    for _, item in ipairs(gear) do
        local pOk, _, _, _, _, maxIlvl = pcall(Calc.GetItemUpgradeCost, Calc, item)
        if pOk and type(maxIlvl) == "number" then
            maxTotal = maxTotal + maxIlvl
        elseif Calc:IsVoidforged(item.link) then
            maxTotal = maxTotal + item.ilvl
        elseif item.ilvl >= 200 then
            local _, maxI = CraftedBandFromIlvl(item.ilvl)
            maxTotal = maxTotal + maxI
        else
            maxTotal = maxTotal + item.ilvl
        end
    end

    -- Pre-build per-slot crest breakdown from scan data.
    -- Done once here from a single DB snapshot so every item in the loop
    -- sees a consistent view of the cache with no per-item DB reads.
    local slotCrestMap = {}
    local dbSnap = DB()
    if dbSnap.calibrated then
        for slotID, sc in pairs(dbSnap.cache.slots or {}) do
            if sc and sc.crestAmounts then
                local byName = {}
                for cid, amt in pairs(sc.crestAmounts) do
                    local cn = _currIDToCrestName[cid]
                    if cn and amt > 0 then byName[cn] = (byName[cn] or 0) + amt end
                end
                if next(byName) then slotCrestMap[slotID] = byName end
            end
        end
    end
    -- Read persistent settings once per refresh
    local opts         = Opts()
    local hideCrafted  = opts.hideCrafted
    local showMaxed    = opts.showMaxed
    local slotFilter   = opts.slotFilter   -- table of group -> bool (nil = all shown)
    local crestFilter  = opts.crestFilter  -- table of trackName -> bool (nil/true = shown)

    -- Build per-slot data
    for _, item in ipairs(gear) do
        local grp = Data.slotToGroup[item.slot]
        if not (slotFilter and grp and slotFilter[grp] == false) then
            local sn = Data.slotNames[item.slot] or ("Slot " .. item.slot)
            local pOk, pa, pb, pc, pd, pe, pf = pcall(Calc.GetItemUpgradeCost, Calc, item)
            local track, rank, crestCost, goldCost, maxIlvl, craftLabel
            if pOk then track, rank, crestCost, goldCost, maxIlvl, craftLabel = pa, pb, pc, pd, pe, pf end
            local dt, dm, du = "-", "-", "-"
            local isAtMax, shouldAdd = false, true

            if track == "Crafted" then
                if hideCrafted then
                    shouldAdd = false
                else
                    dt = craftLabel or "Crafted"; dm = maxIlvl or item.ilvl
                    isAtMax = true
                    du = "Crafted"
                end
            elseif track then
                local td = Data.tracks[track]
                totalMissing = totalMissing + ((td and #td.ranks or 6) - (rank or 0))
                totalGold    = totalGold + (goldCost or 0)
                local cn_map = slotCrestMap[item.slot]
                if cn_map then
                    for cn, amt in pairs(cn_map) do
                        crestNeeds[cn] = (crestNeeds[cn] or 0) + amt
                    end
                elseif td and (crestCost or 0) > 0 then
                    crestNeeds[td.crestName] = (crestNeeds[td.crestName] or 0) + crestCost
                end
                dt = track; dm = maxIlvl or item.ilvl
                du = rank and (rank .. "/" .. (td and #td.ranks or 6)) or "-"
                isAtMax = (rank == (td and #td.ranks or 6))
            else
                if Calc:IsVoidforged(item.link) then
                    dt = "Voidforged"; dm = item.ilvl; du = "Max"; isAtMax = true
                elseif item.ilvl >= 200 then
                    -- Use the shared helper so thresholds stay in one place.
                    local band, maxI = CraftedBandFromIlvl(item.ilvl)
                    local label = band == "Myth" and "Myth Craft"
                               or band == "Hero" and "Hero Craft" or "Crafted"
                    dt = label; dm = maxI
                    du = item.ilvl >= maxI and "Max" or "-"
                    isAtMax = item.ilvl >= maxI
                else
                    dm = item.ilvl; isAtMax = true
                end
            end

            if shouldAdd then
                tileEntries[#tileEntries + 1] = {
                    slotName = sn,       slotID  = item.slot,
                    ilvl     = item.ilvl, max    = dm,
                    upgrade  = du,       trackName = dt,
                    isAtMax  = isAtMax,  trackKey  = track,
                    crestCost = crestCost, goldCost = goldCost,
                }
            end
        end
    end

    -- Fold in manual crest additions (from the +/-80 buttons on Hero/Myth rows)
    for ckey, amt in pairs(crestManualAdds) do
        if (amt or 0) > 0 then
            crestNeeds[ckey] = (crestNeeds[ckey] or 0) + amt
        end
    end

    -- Sort: needs-upgrades first, then at-max. Within each group follow character sheet slot order.
    table.sort(tileEntries, function(a, b)
        if a.isAtMax ~= b.isAtMax then return not a.isAtMax end
        return a.slotID < b.slotID
    end)

    -- Restore queue from DB on the first PopulateGear call after a session start.
    -- We only do this once (_queueLoaded guard) so that subsequent Refresh calls
    -- don't overwrite in-session queue changes the user has made.
    if not _queueLoaded then
        _queueLoaded = true
        local savedSlots = DB().queue
        if savedSlots and #savedSlots > 0 then
            local slotToEntry = {}
            for _, e in ipairs(tileEntries) do slotToEntry[e.slotID] = e end
            queueItems = {}; queueSlotSet = {}
            for _, slotID in ipairs(savedSlots) do
                local e = slotToEntry[slotID]
                if e and not queueSlotSet[e.slotName] then
                    queueItems[#queueItems + 1] = e
                    queueSlotSet[e.slotName] = #queueItems
                end
            end
        end
    end

    -- On every refresh, sync queue item references to the current tileEntries so
    -- UpdateQueueDisplay shows live costs rather than costs snapshotted at session open.
    -- Safe to run on the first PopulateGear call too (entries are already fresh then).
    if #queueItems > 0 then
        local slotToEntry = {}
        for _, e in ipairs(tileEntries) do slotToEntry[e.slotID] = e end
        local newQueue, newSet = {}, {}
        for _, old in ipairs(queueItems) do
            local fresh = slotToEntry[old.slotID]
            if fresh then
                newQueue[#newQueue + 1] = fresh
                newSet[fresh.slotName] = #newQueue
            end
        end
        queueItems   = newQueue
        queueSlotSet = newSet
    end

    -- Timeline bar
    local curAvg = select(2, GetAverageItemLevel()) or 0
    -- Blizzard counts 2H weapons as two slots; clamp so max never shows below current.
    local maxAvg = math.max(curAvg, #gear > 0 and maxTotal / #gear or 0)
    local minBase = 200
    local frac = (maxAvg > minBase and curAvg > minBase)
        and math.min(1, (curAvg - minBase) / math.max(1, maxAvg - minBase)) or 0
    tlFill:SetWidth(math.max(1, math.floor(frac * (FRAME_W - 22))))
    tlCurLbl:SetText(string.format("%.1f", curAvg))
    tlMaxLbl:SetText(string.format("max %.1f", maxAvg))
    ilvlStatLbl:SetText(string.format(
        "Current iLvl: |cffffffff%.1f|r     Max Possible: |cffffffff%.1f|r |cff888888(estimated)|r",
        curAvg, maxAvg))

    -- Section header positions
    local needsCount = 0
    for _, e in ipairs(tileEntries) do if not e.isAtMax then needsCount = needsCount + 1 end end
    local maxCount  = #tileEntries - needsCount
    local needsRows = needsCount > 0 and math.ceil(needsCount / TILE_COLS) or 0

    if needsCount > 0 then
        sHdrNeeds:ClearAllPoints()
        PP.Point(sHdrNeeds, "TOPLEFT", cc, "TOPLEFT", 2, -36)
        sHdrNeeds:SetText(string.format("v  NEEDS UPGRADES (%d)", needsCount))
        sHdrNeeds:Show()
    else
        sHdrNeeds:SetText(""); sHdrNeeds:Hide()
    end

    local atMaxHdrY = -36 - (needsCount > 0 and needsRows * TILE_STEP + 18 or 0)
    if maxCount > 0 and showMaxed then
        groupSepLine:ClearAllPoints()
        PP.Point(groupSepLine, "TOPLEFT", cc, "TOPLEFT", 0, atMaxHdrY - 2)
        groupSepLine:Show()
        sHdrMax:ClearAllPoints()
        PP.Point(sHdrMax, "TOPLEFT", cc, "TOPLEFT", 2, atMaxHdrY - 6)
        sHdrMax:SetText(string.format("v  AT MAX (%d)", maxCount))
        sHdrMax:Show()
    else
        groupSepLine:Hide(); sHdrMax:Hide()
    end

    -- Position and fill tile frames
    local function getTilePos(group_start_y, local_idx)
        local row = math.floor(local_idx / TILE_COLS)
        local col = local_idx % TILE_COLS
        return col * (TILE_W + TILE_GAP), group_start_y - row * TILE_STEP
    end

    local needsStartY = -54  -- below timeline bar(16) + labels(18) + section header(20)
    local atMaxStartY = needsStartY - needsRows * TILE_STEP - (needsCount > 0 and 34 or 18)

    for _, btn in ipairs(tileFrames) do btn:Hide() end

    local ni, mi = 0, 0
    for idx, entry in ipairs(tileEntries) do
        if idx > #tileFrames then break end  -- tileFrames has 18 slots; equipSlots has 16
        local btn = tileFrames[idx]
        local tx, ty
        if not entry.isAtMax then
            tx, ty = getTilePos(needsStartY, ni); ni = ni + 1
        elseif showMaxed then
            tx, ty = getTilePos(atMaxStartY, mi); mi = mi + 1
        end
        if tx then
            btn:ClearAllPoints()
            PP.Point(btn, "TOPLEFT", cc, "TOPLEFT", tx, ty)
            btn:Show()

            -- Tile background colour by upgrade gap
            if entry.isAtMax then
                btn.bg:SetColorTexture(0.04, 0.13, 0.05, 1)
            elseif type(entry.max) == "number" and (entry.max - entry.ilvl) >= 10 then
                btn.bg:SetColorTexture(0.14, 0.05, 0.04, 1)
            else
                btn.bg:SetColorTexture(0.14, 0.10, 0.02, 1)
            end

            -- Left accent bar: track colour
            local rgb = (entry.trackKey and TRACK_RGB[entry.trackKey])
                   or TRACK_RGB[entry.trackName]
                   or {0.4, 0.4, 0.4}
            btn.accentBar:SetColorTexture(rgb[1], rgb[2], rgb[3], 1)

            -- Text labels
            btn.sLbl:SetText(entry.slotName)
            local maxStr = type(entry.max) == "number" and tostring(entry.max) or "-"
            btn.iLbl:SetText(entry.ilvl .. " ^ " .. maxStr)
            btn.tLbl:SetText(entry.trackName)
            btn.rLbl:SetText(entry.upgrade)

            local txtA = entry.isAtMax and 0.45 or 0.9
            btn.sLbl:SetTextColor(txtA, txtA, txtA, 1)
            btn.iLbl:SetTextColor(txtA, txtA, txtA, 1)
            btn.rLbl:SetTextColor(txtA, txtA, txtA, 1)

            -- Restore queue highlight
            if queueSlotSet[entry.slotName] then btn.selHL:Show()
            else btn.selHL:Hide() end

            btn.tileEntry = entry
        end
    end

    -- Reposition the crest section immediately below the last rendered tile row.
    local crestY
    if showMaxed and maxCount > 0 then
        -- atMaxStartY is where the at-max group starts; offset by its rows + gap.
        crestY = atMaxStartY - math.ceil(maxCount / TILE_COLS) * TILE_STEP - 20
    else
        -- Only needs-upgrade tiles are visible (or none at all).
        crestY = needsStartY - needsRows * TILE_STEP - 20
    end
    crestSection:ClearAllPoints()
    PP.Point(crestSection, "TOPLEFT",  cc, "TOPLEFT",  0, crestY)
    PP.Point(crestSection, "TOPRIGHT", cc, "TOPRIGHT", 0, crestY)

    -- Resize the outer frame to fit content: title(32) + tabY(-36) + cc offset(46) +
    -- tile area + crest section (rows + summary + buttons) + bottom padding
    local visibleCrestRows = 0
    for _, tn in ipairs(Data.trackOrder) do
        if crestFilter == nil or crestFilter[tn] ~= false then
            visibleCrestRows = visibleCrestRows + 1
        end
    end
    local crestSectionH = HDR_H + visibleCrestRows * ROW_H + 10 + 22 + 38  -- hdr+rows+gap+summary+btns
    local contentH      = math.abs(crestY) + crestSectionH
    -- cc is anchored at y = tabY - 46 = -82 from frame top; add title bar (32) + padding (12)
    local newFrameH     = contentH + 82 + 32 + 12
    PP.Size(f, FRAME_W, newFrameH)

    -- Crest accuracy label
    local db = DB()
    if db.calibrated then
        crestAccuracyLbl:SetText("|cff20ff20(exact — Upgrader scan)|r")
    else
        crestAccuracyLbl:SetText("|cffaaaaaa(estimated)|r")
    end

    -- Crest table — compact visible rows to consecutive y positions so that
    -- filtered-out rows leave no gap, and +/-80 buttons/summary/action buttons
    -- always appear immediately below the last visible row.
    local showCap      = opts.showEarnedCap
    local showWeeklyRem = opts.showWeeklyRemaining
    if showCap      then capHdrLbl:Show()      else capHdrLbl:Hide()      end
    -- When Earned/Cap is hidden, Left This Week slides into that column's space.
    local weeklyRemX = (showWeeklyRem and not showCap) and CREST_COLS[5].x or CREST_COLS[6].x
    if showWeeklyRem then
        weeklyRemHdrLbl:ClearAllPoints()
        PP.Point(weeklyRemHdrLbl, "TOPLEFT", crestSection, "TOPLEFT", weeklyRemX + 4, -2)
        weeklyRemHdrLbl:Show()
    else
        weeklyRemHdrLbl:Hide()
    end
    local visualIdx = 0
    for i, trackName in ipairs(Data.trackOrder) do
        local td      = Data.tracks[trackName]
        local ckey    = td and td.crestName or trackName
        local visible = crestFilter == nil or crestFilter[trackName] ~= false
        local rowFrame = crestRows[i]
        local rowY    = -(HDR_H + visualIdx * ROW_H)
        if visible then
            -- Reposition alt-row background stripe to the compacted visual position
            if rowFrame.altBg then
                rowFrame.altBg:ClearAllPoints()
                PP.Point(rowFrame.altBg, "TOPLEFT",  crestSection, "TOPLEFT",  0, rowY)
                PP.Point(rowFrame.altBg, "TOPRIGHT", crestSection, "TOPRIGHT", 0, rowY)
                rowFrame.altBg:Show()
            end
            -- Reposition every cell to the current visual slot
            for _, col in ipairs(CREST_COLS) do
                local cell = rowFrame[col.key]
                cell:ClearAllPoints()
                local cellX = (col.key == "weeklyRem") and weeklyRemX or col.x
                PP.Point(cell, "TOPLEFT", crestSection, "TOPLEFT", cellX + 4, rowY - 2)
            end
            -- Reposition and show +/-80 buttons if this row has them
            if rowFrame.mBtn then
                rowFrame.mBtn:ClearAllPoints()
                PP.Point(rowFrame.mBtn, "TOPLEFT", crestSection, "TOPLEFT", 143, rowY - 2)
                rowFrame.pBtn:ClearAllPoints()
                PP.Point(rowFrame.pBtn, "TOPLEFT", crestSection, "TOPLEFT", 200, rowY - 2)
                rowFrame.mBtn:Show()
                rowFrame.pBtn:Show()
            end
            local need      = crestNeeds[ckey] or 0
            local info      = owned[ckey]
            local have      = info and info.quantity or 0
            local miss      = math.max(0, need - have)
            rowFrame.crest:SetText(ckey)
            rowFrame.need:SetText(need > 0 and need or "-")
            rowFrame.owned:SetText(have > 0 and have or "-")
            rowFrame.missing:SetText(miss > 0
                and ("|cffff6060" .. miss .. "|r") or "|cff20ff20-|r")
            if showCap then
                local cap       = info and info.cap
                local earnedStr = info and info.earned and info.earned > 0 and tostring(info.earned) or "-"
                local capStr    = cap and tostring(cap) or "-"
                rowFrame.cap:SetText(earnedStr .. " / " .. capStr)
                rowFrame.cap:Show()
            else
                rowFrame.cap:Hide()
            end
            if showWeeklyRem then
                local cap    = info and info.cap
                local earned = info and info.earned or 0
                if cap then
                    local rem    = math.max(0, cap - earned)
                    local remStr = rem > 0 and tostring(rem) or "|cff20ff200|r"
                    rowFrame.weeklyRem:SetText(remStr)
                else
                    rowFrame.weeklyRem:SetText("-")
                end
                rowFrame.weeklyRem:Show()
            else
                rowFrame.weeklyRem:Hide()
            end
            rowFrame.crest:Show(); rowFrame.need:Show()
            rowFrame.owned:Show(); rowFrame.missing:Show()
            visualIdx = visualIdx + 1
        else
            rowFrame.crest:Hide(); rowFrame.need:Hide()
            rowFrame.owned:Hide(); rowFrame.missing:Hide(); rowFrame.cap:Hide(); rowFrame.weeklyRem:Hide()
            if rowFrame.altBg then rowFrame.altBg:Hide() end
            if rowFrame.mBtn then
                rowFrame.mBtn:Hide()
                rowFrame.pBtn:Hide()
            end
        end
    end

    -- Reposition summary label and action buttons immediately below the last visible row
    local crestBotY = -(HDR_H + visualIdx * ROW_H)
    summaryLbl:ClearAllPoints()
    PP.Point(summaryLbl, "TOPLEFT", crestSection, "TOPLEFT", 4, crestBotY - 10)
    refreshBtn:ClearAllPoints()
    PP.Point(refreshBtn, "TOPLEFT", crestSection, "TOPLEFT", 0, crestBotY - 38)
    scanBtn:ClearAllPoints()
    PP.Point(scanBtn, "TOPLEFT", crestSection, "TOPLEFT", 150, crestBotY - 38)

    local crestParts = {}
    for _, trackName in ipairs(Data.trackOrder) do
        local td   = Data.tracks[trackName]
        local ckey = td and td.crestName or trackName
        local amt  = crestNeeds[ckey] or 0
        if amt > 0 then
            local hexColor = (td and td.hexColor) or "|cffffffff"
            crestParts[#crestParts + 1] = "|cffffffff" .. amt .. "|r " .. hexColor .. trackName .. "|r"
        end
    end
    local crestStr = #crestParts > 0 and ("     Crests: " .. table.concat(crestParts, "  ")) or ""
    summaryLbl:SetText(string.format(
        "Missing Upgrades: |cffffffff%d|r%s     Gold: |cffffffff%dg|r",
        totalMissing, crestStr, totalGold))

    -- Sync queue panel text to match restored/refreshed queue state.
    UpdateQueueDisplay()
end

refreshBtn:SetScript("OnClick", PopulateGear)
Calc.PopulateGear = PopulateGear  -- exposed for options page live-refresh
refreshBtn:HookScript("OnEnter", function(self)
    if EUI.ShowWidgetTooltip then
        EUI.ShowWidgetTooltip(self,
            "Refresh using tooltip scan data.\n"
            .. "For exact costs, use |cffffffff'Update at Upgrader'|r\n"
            .. "while at an Item Upgrade NPC.")
    end
end)
refreshBtn:HookScript("OnLeave", function()
    if EUI.HideWidgetTooltip then EUI.HideWidgetTooltip() end
end)

scanBtn:HookScript("OnEnter", function(self)
    if EUI.ShowWidgetTooltip then
        local tip = "Scan all equipped gear costs at the Item Upgrade NPC.\n"
                 .. "Scans each slot one at a time — this can take up to 10 seconds.\n"
                 .. "Requires the Item Upgrade window to be open."
        if not Calc:IsUpgraderOpen() then
            tip = tip .. "\n|cffff6060Item Upgrade window is not open.|r"
        end
        EUI.ShowWidgetTooltip(self, tip)
    end
end)
scanBtn:HookScript("OnLeave", function()
    if EUI.HideWidgetTooltip then EUI.HideWidgetTooltip() end
end)

scanBtn:SetScript("OnClick", function()
    if Calc._scanning then return end
    scanBtnTxt:SetText("Scanning...")
    scanBtn:SetAlpha(0.5)
    Calc:ScanEquippedAtUpgrader(function(ok)
        scanBtnTxt:SetText("Update at Upgrader")
        scanBtn:SetAlpha(1)
        if ok then
            crestManualAdds["Hero Crest"] = 0
            crestManualAdds["Myth Crest"] = 0
            SaveCrestManualAdds()
            PopulateGear()
        end
    end)
end)

-- Debounce timer handle for PLAYER_EQUIPMENT_CHANGED: coalesces rapid gear swaps
-- (e.g. multiple pieces at once) into a single PopulateGear call.
-- Declared before equipListener so both the OnEvent and OnHide closures capture
-- the same upvalue (declaring it after would cause OnEvent to use the global slot
-- instead, making OnHide unable to cancel a pending debounce timer).
local _equipDebounce = nil

local equipListener = CreateFrame("Frame")
equipListener:SetScript("OnEvent", function(_, event, slotID)
    if event == "PLAYER_REGEN_DISABLED" then
        -- Combat started: close the frame silently
        if f:IsShown() then f:Hide() end
        return
    end
    -- Invalidate the tip cache for the changed slot (or all if slotID is missing).
    if slotID and slotID > 0 then
        local link = GetInventoryItemLink("player", slotID)
        if link then Calc._tipCache[link] = nil end
    else
        Calc._tipCache = {}
    end
    if not f:IsShown() then return end
    -- If the Upgrader NPC is open and we have a valid slot ID, rescan just that
    -- slot so the exact post-upgrade cost is shown without a full re-scan.
    if slotID and slotID > 0 and Calc:IsUpgraderOpen() and not Calc._scanning then
        -- Invalidate the slot's cache entry so PopulateGear won't stale-serve
        -- the old data while the rescan is in flight.
        local db = DB()
        if db.cache and db.cache.slots then
            db.cache.slots[slotID] = nil
        end
        Calc:RescanSlot(slotID, function()
            if f:IsShown() then PopulateGear() end
        end)
        return
    end
    -- Debounce: wait 0.3 s after the last equip event before refreshing.
    -- This prevents hammering PopulateGear when the user swaps multiple pieces.
    if _equipDebounce then _equipDebounce:Cancel() end
    _equipDebounce = C_Timer.NewTimer(0.3, function()
        _equipDebounce = nil
        if f:IsShown() then PopulateGear() end
    end)
end)

-- Show / Hide

f:SetScript("OnShow", function()
    if InCombatLockdown() then f:Hide(); return end
    Calc.ApplyBgOpacity()
    -- Reload persisted crest manual-add offsets each time the frame opens,
    -- so that values the user set before logging out are visible immediately.
    local dbAdds = DB().crestManualAdds
    for k in pairs(crestManualAdds) do
        crestManualAdds[k] = (dbAdds and dbAdds[k]) or 0
    end
    equipListener:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    equipListener:RegisterEvent("PLAYER_REGEN_DISABLED")
    PopulateGear()
end)
f:SetScript("OnHide", function()
    equipListener:UnregisterAllEvents()
    -- Cancel any pending equipment-change debounce.
    if _equipDebounce then _equipDebounce:Cancel(); _equipDebounce = nil end
    -- If hidden mid-scan (e.g. combat, /reload), unblock future scans.
    Calc._scanning = false
    Calc._tipCache = {}
    -- crestManualAdds are now persisted to DB; no longer reset on hide.
end)

SLASH_EUIUPGCALC1 = "/euic"
SLASH_EUIUPGCALC2 = "/upgcalc"
SlashCmdList["EUIUPGCALC"] = function()
    if InCombatLockdown() then return end
    if f:IsShown() then f:Hide() else f:Show() end
end

-- ── Profile integration + first-run crest filter ────────────────────────────
-- On PLAYER_LOGIN we call NewDB so our data lives inside EllesmereUIDB.profiles
-- (the same place Cursor, BattleRes etc store theirs).  Without this, NewDB
-- wipes EllesmereUIQoLDB and our saved data is lost every session.
-- The first-run filter runs once (guarded by opts.firstRunDone) to auto-hide
-- crest tracks that have no upgradeable items on the player's current gear.
local _firstRunEvt = CreateFrame("Frame")
_firstRunEvt:RegisterEvent("PLAYER_LOGIN")
_firstRunEvt:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    -- Register with the profile system; this MUST happen before Opts()/DB() are
    -- called so data is read from / written to the correct persistent location.
    if EllesmereUI and EllesmereUI.Lite and EllesmereUI.Lite.NewDB then
        local profileDB = EllesmereUI.Lite.NewDB("EllesmereUIQoLDB", {
            profile = {
                upgradeCalcOpts = {},
                upgradeCalc     = {
                    cache      = { slots = {}, ts = 0 },
                    calibrated = false,
                },
            },
        })
        _euicProfileRef = profileDB.profile
        -- Populate the direct sub-table caches now so DB()/Opts() are O(1)
        -- for the rest of the session with no repeated table traversal.
        local store = _euicProfileRef
        store.upgradeCalc       = store.upgradeCalc      or {}
        local db                = store.upgradeCalc
        db.cache                = db.cache               or { slots = {}, ts = 0 }
        db.calibrated           = db.calibrated          or false
        db.queue                = db.queue               or {}
        db.crestManualAdds      = db.crestManualAdds     or {}
        store.upgradeCalcOpts   = store.upgradeCalcOpts  or {}
        _dbCache   = db
        _optsCache = store.upgradeCalcOpts
    end
    local opts = Opts()
    if opts.firstRunDone then return end
    -- Brief delay so the client has fully loaded item data before tooltip scanning.
    C_Timer.After(1.5, function()
        opts.firstRunDone = true
        local tracksNeeded = {}
        for _, slotID in ipairs(Data.equipSlots) do
            local link = GetInventoryItemLink("player", slotID)
            if link then
                local r = Calc:ScanItemLink(link)
                local td = r and r.track and Data.tracks[r.track]
                if td and (r.rank or 0) < #td.ranks then
                    tracksNeeded[r.track] = true
                end
            end
        end
        -- Only apply a filter if at least one track can be hidden.
        local anyHidden = false
        for _, tn in ipairs(Data.trackOrder) do
            if not tracksNeeded[tn] then anyHidden = true; break end
        end
        if anyHidden then
            opts.crestFilter = opts.crestFilter or {}
            for _, tn in ipairs(Data.trackOrder) do
                if not tracksNeeded[tn] then
                    opts.crestFilter[tn] = false
                end
            end
        end
    end)
end)
