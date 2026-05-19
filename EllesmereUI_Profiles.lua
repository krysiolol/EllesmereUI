-------------------------------------------------------------------------------
--  EllesmereUI_Profiles.lua
--
--  Global profile system: import/export, presets, spec assignment.
--  Handles serialization (LibDeflate + custom serializer) and profile
--  management across all EllesmereUI addons.
--
--  Load order (via TOC):
--    1. Libs/LibDeflate.lua
--    2. EllesmereUI_Lite.lua
--    3. EllesmereUI.lua
--    4. EllesmereUI_Widgets.lua
--    5. EllesmereUI_Presets.lua
--    6. EllesmereUI_Profiles.lua  -- THIS FILE
-------------------------------------------------------------------------------

local EllesmereUI = _G.EllesmereUI

-------------------------------------------------------------------------------
--  LibDeflate reference (loaded before us via TOC)
--  LibDeflate registers via LibStub, not as a global, so use LibStub to get it.
-------------------------------------------------------------------------------
local LibDeflate = LibStub and LibStub("LibDeflate", true) or _G.LibDeflate

-------------------------------------------------------------------------------
--  Reload popup: uses Blizzard StaticPopup so the button click is a hardware
--  event and ReloadUI() is not blocked as a protected function call.
-------------------------------------------------------------------------------
StaticPopupDialogs["EUI_PROFILE_RELOAD"] = {
    text = "EllesmereUI Profile switched. Reload UI to apply?",
    button1 = "Reload Now",
    button2 = "Later",
    OnAccept = function() ReloadUI() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-------------------------------------------------------------------------------
--  Addon registry: display-order list of all managed addons.
--  Each entry: { folder, display, svName }
--    folder  = addon folder name (matches _dbRegistry key)
--    display = human-readable name for the Profiles UI
--    svName  = SavedVariables name (e.g. "EllesmereUINameplatesDB")
--
--  All addons use _dbRegistry for profile access. Order matters for UI display.
-------------------------------------------------------------------------------
local ADDON_DB_MAP = {
    { folder = "EllesmereUIActionBars",        display = "Action Bars",         svName = "EllesmereUIActionBarsDB"        },
    { folder = "EllesmereUINameplates",        display = "Nameplates",          svName = "EllesmereUINameplatesDB"        },
    { folder = "EllesmereUIUnitFrames",        display = "Unit Frames",         svName = "EllesmereUIUnitFramesDB"        },
    { folder = "EllesmereUICooldownManager",   display = "Cooldown Manager",    svName = "EllesmereUICooldownManagerDB"   },
    { folder = "EllesmereUIResourceBars",      display = "Resource Bars",       svName = "EllesmereUIResourceBarsDB"      },
    { folder = "EllesmereUIAuraBuffReminders", display = "AuraBuff Reminders",  svName = "EllesmereUIAuraBuffRemindersDB" },
    -- v6.6 split-out addons (were previously bundled under EllesmereUIBasics).
    -- The old Basics entry is intentionally removed -- it's a shim with no
    -- user-visible profile data and listing it produced a misleading
    -- "Not included: Basics" warning on every imported v6.6+ profile.
    { folder = "EllesmereUIQoL",               display = "Quality of Life",     svName = "EllesmereUIQoLDB"               },
    { folder = "EllesmereUIBlizzardSkin",      display = "Blizz UI Enhanced",   svName = "EllesmereUIBlizzardSkinDB"      },
    { folder = "EllesmereUIFriends",           display = "Friends List",        svName = "EllesmereUIFriendsDB"           },
    { folder = "EllesmereUIMythicTimer",       display = "Mythic+ Timer",       svName = "EllesmereUIMythicTimerDB"       },
    { folder = "EllesmereUIQuestTracker",      display = "Quest Tracker",       svName = "EllesmereUIQuestTrackerDB"      },
    { folder = "EllesmereUIMinimap",           display = "Minimap",             svName = "EllesmereUIMinimapDB"           },
    { folder = "EllesmereUIDamageMeters",     display = "Damage Meters",       svName = "EllesmereUIDamageMetersDB"     },
    { folder = "EllesmereUIChat",             display = "Chat",                svName = "EllesmereUIChatDB"             },
    { folder = "EllesmereUIBags",             display = "Bags",                svName = "EllesmereUIBagsDB"             },
}
EllesmereUI._ADDON_DB_MAP = ADDON_DB_MAP

-------------------------------------------------------------------------------
--  Serializer: Lua table <-> string (no AceSerializer dependency)
--  Handles: string, number, boolean, nil, table (nested), color tables
-------------------------------------------------------------------------------
local Serializer = {}

local function SerializeValue(v, parts)
    local t = type(v)
    if t == "string" then
        parts[#parts + 1] = "s"
        -- Length-prefixed to avoid delimiter issues
        parts[#parts + 1] = #v
        parts[#parts + 1] = ":"
        parts[#parts + 1] = v
    elseif t == "number" then
        parts[#parts + 1] = "n"
        parts[#parts + 1] = tostring(v)
        parts[#parts + 1] = ";"
    elseif t == "boolean" then
        parts[#parts + 1] = v and "T" or "F"
    elseif t == "nil" then
        parts[#parts + 1] = "N"
    elseif t == "table" then
        parts[#parts + 1] = "{"
        -- Serialize array part first (integer keys 1..n)
        local n = #v
        for i = 1, n do
            SerializeValue(v[i], parts)
        end
        -- Then hash part (non-integer keys, or integer keys > n)
        for k, val in pairs(v) do
            local kt = type(k)
            if kt == "number" and k >= 1 and k <= n and k == math.floor(k) then
                -- Already serialized in array part
            else
                parts[#parts + 1] = "K"
                SerializeValue(k, parts)
                SerializeValue(val, parts)
            end
        end
        parts[#parts + 1] = "}"
    end
end

function Serializer.Serialize(tbl)
    local parts = {}
    SerializeValue(tbl, parts)
    return table.concat(parts)
end

-- Deserializer
local function DeserializeValue(str, pos)
    local tag = str:sub(pos, pos)
    if tag == "s" then
        -- Find the colon after the length
        local colonPos = str:find(":", pos + 1, true)
        if not colonPos then return nil, pos end
        local len = tonumber(str:sub(pos + 1, colonPos - 1))
        if not len then return nil, pos end
        local val = str:sub(colonPos + 1, colonPos + len)
        return val, colonPos + len + 1
    elseif tag == "n" then
        local semi = str:find(";", pos + 1, true)
        if not semi then return nil, pos end
        return tonumber(str:sub(pos + 1, semi - 1)), semi + 1
    elseif tag == "T" then
        return true, pos + 1
    elseif tag == "F" then
        return false, pos + 1
    elseif tag == "N" then
        return nil, pos + 1
    elseif tag == "{" then
        local tbl = {}
        local idx = 1
        local p = pos + 1
        while p <= #str do
            local c = str:sub(p, p)
            if c == "}" then
                return tbl, p + 1
            elseif c == "K" then
                -- Key-value pair
                local key, val
                key, p = DeserializeValue(str, p + 1)
                val, p = DeserializeValue(str, p)
                if key ~= nil then
                    tbl[key] = val
                end
            else
                -- Array element
                local val
                val, p = DeserializeValue(str, p)
                tbl[idx] = val
                idx = idx + 1
            end
        end
        return tbl, p
    end
    return nil, pos + 1
end

function Serializer.Deserialize(str)
    if not str or #str == 0 then return nil end
    local val, _ = DeserializeValue(str, 1)
    return val
end

EllesmereUI._Serializer = Serializer

-------------------------------------------------------------------------------
--  Deep copy utility
-------------------------------------------------------------------------------
local function DeepCopy(src, seen)
    if type(src) ~= "table" then return src end
    if seen and seen[src] then return seen[src] end
    if not seen then seen = {} end
    local copy = {}
    seen[src] = copy
    for k, v in pairs(src) do
        -- Skip frame references and other userdata that can't be serialized
        if type(v) ~= "userdata" and type(v) ~= "function" then
            copy[k] = DeepCopy(v, seen)
        end
    end
    return copy
end

local function DeepMerge(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then
            DeepMerge(dst[k], v)
        else
            dst[k] = DeepCopy(v)
        end
    end
end

EllesmereUI._DeepCopy = DeepCopy




-------------------------------------------------------------------------------
--  Profile DB helpers
--  Profiles are stored in EllesmereUIDB.profiles = { [name] = profileData }
--  profileData = {
--      addons = { [folderName] = <snapshot of that addon's profile table> },
--      fonts  = <snapshot of EllesmereUIDB.fonts>,
--      customColors = <snapshot of EllesmereUIDB.customColors>,
--  }
--  EllesmereUIDB.activeProfile = "Default"  (name of active profile)
--  EllesmereUIDB.profileOrder  = { "Default", ... }
--  EllesmereUIDB.specProfiles  = { [specID] = "profileName" }
-------------------------------------------------------------------------------
local function GetProfilesDB()
    if not EllesmereUIDB then EllesmereUIDB = {} end
    if not EllesmereUIDB.profiles then EllesmereUIDB.profiles = {} end
    if not EllesmereUIDB.profileOrder then EllesmereUIDB.profileOrder = {} end
    if not EllesmereUIDB.specProfiles then EllesmereUIDB.specProfiles = {} end
    return EllesmereUIDB
end
EllesmereUI.GetProfilesDB = GetProfilesDB

-------------------------------------------------------------------------------
--  Anchor offset format conversion
--
--  Anchor offsets were originally stored relative to the target's center
--  (format version 0/nil). The current system stores them relative to
--  stable edges (format version 1):
--    TOP/BOTTOM: offsetX relative to target LEFT edge
--    LEFT/RIGHT: offsetY relative to target TOP edge
--
--- Check if an addon is loaded
local function IsAddonLoaded(name)
    if C_AddOns and C_AddOns.IsAddOnLoaded then return C_AddOns.IsAddOnLoaded(name) end
    if _G.IsAddOnLoaded then return _G.IsAddOnLoaded(name) end
    return false
end

--- Re-point all db.profile references to the given profile name.
--- Called when switching profiles so addons see the new data immediately.
local function RepointAllDBs(profileName)
    if not EllesmereUIDB.profiles then EllesmereUIDB.profiles = {} end
    if type(EllesmereUIDB.profiles[profileName]) ~= "table" then
        EllesmereUIDB.profiles[profileName] = {}
    end
    local profileData = EllesmereUIDB.profiles[profileName]
    if not profileData.addons then profileData.addons = {} end

    -- Sync: copy synced module data from outgoing profile to incoming.
    -- activeProfile is already set to the new name by callers, so read
    -- the outgoing profile from the db registry (not yet re-pointed).
    local sm = EllesmereUIDB.syncedModules
    if sm then
        local reg = EllesmereUI.Lite and EllesmereUI.Lite._dbRegistry
        local outName = reg and reg[1] and reg[1]._profileName or "Default"
        local outProf = EllesmereUIDB.profiles[outName]
        if outProf and outProf.addons and outName ~= profileName then
            for folder, synced in pairs(sm) do
                if synced and outProf.addons[folder] then
                    profileData.addons[folder] = DeepCopy(outProf.addons[folder])
                end
            end
        end
    end

    local registry = EllesmereUI.Lite and EllesmereUI.Lite._dbRegistry
    if not registry then return end
    for _, db in ipairs(registry) do
        local folder = db.folder
        if folder then
            if type(profileData.addons[folder]) ~= "table" then
                profileData.addons[folder] = {}
            end
            db.profile = profileData.addons[folder]
            db._profileName = profileName
            -- Re-merge defaults so new profile has all keys
            if db._profileDefaults then
                EllesmereUI.Lite.DeepMergeDefaults(db.profile, db._profileDefaults)
            end
        end
    end
    -- Restore unlock layout from the profile.
    -- If the profile has no unlockLayout yet (e.g. created before this key
    -- existed), leave the live unlock data untouched so the current
    -- positions are preserved. Only restore when the profile explicitly
    -- contains layout data from a previous save.
    local ul = profileData.unlockLayout
    if ul then
        EllesmereUIDB.unlockAnchors     = DeepCopy(ul.anchors      or {})
        EllesmereUIDB.unlockWidthMatch  = DeepCopy(ul.widthMatch   or {})
        EllesmereUIDB.unlockHeightMatch = DeepCopy(ul.heightMatch  or {})
        EllesmereUIDB.phantomBounds     = DeepCopy(ul.phantomBounds or {})
    end
    -- Seed castbar anchor defaults ONLY on brand-new profiles (no unlockLayout
    -- yet). Re-seeding every load would clobber a user's deliberate un-anchor
    -- or manual position with the default "target BOTTOM" anchor the next
    -- time the profile is applied (e.g. via spec profile assignment).
    if not ul then
        local anchors = EllesmereUIDB.unlockAnchors
        local wMatch  = EllesmereUIDB.unlockWidthMatch
        if anchors and wMatch then
            local CB_DEFAULTS = {
                { cb = "playerCastbar", parent = "player" },
                { cb = "targetCastbar", parent = "target" },
                { cb = "focusCastbar",  parent = "focus" },
            }
            for _, def in ipairs(CB_DEFAULTS) do
                if not anchors[def.cb] then
                    anchors[def.cb] = { target = def.parent, side = "BOTTOM" }
                end
                if not wMatch[def.cb] then
                    wMatch[def.cb] = def.parent
                end
            end
        end
    end
    -- Restore fonts and custom colors from the profile
    if profileData.fonts then
        local fontsDB = EllesmereUI.GetFontsDB()
        for k in pairs(fontsDB) do fontsDB[k] = nil end
        for k, v in pairs(profileData.fonts) do fontsDB[k] = DeepCopy(v) end
        if fontsDB.global      == nil then fontsDB.global      = "Expressway" end
        if fontsDB.outlineMode == nil then fontsDB.outlineMode = "shadow"     end
    end
    if profileData.customColors then
        local colorsDB = EllesmereUI.GetCustomColorsDB()
        for k in pairs(colorsDB) do colorsDB[k] = nil end
        for k, v in pairs(profileData.customColors) do colorsDB[k] = DeepCopy(v) end
    end
end

-------------------------------------------------------------------------------
--  ResolveSpecProfile
--
--  Single authoritative function that resolves the current spec's target
--  profile name. Used by both PreSeedSpecProfile (before OnEnable) and the
--  runtime spec event handler.
--
--  Resolution order:
--    1. Cached spec from lastSpecByChar (reliable across sessions)
--    2. Live GetSpecialization() API (available after ADDON_LOADED for
--       returning characters, may be nil for brand-new characters)
--
--  Returns: targetProfileName, resolvedSpecID, charKey  -- or nil if no
--           spec assignment exists or spec cannot be resolved yet.
-------------------------------------------------------------------------------
local function ResolveSpecProfile()
    if not EllesmereUIDB then return nil end
    local specProfiles = EllesmereUIDB.specProfiles
    if not specProfiles or not next(specProfiles) then return nil end

    local charKey = UnitName("player") .. " - " .. GetRealmName()
    if not EllesmereUIDB.lastSpecByChar then
        EllesmereUIDB.lastSpecByChar = {}
    end

    -- Prefer cached spec from last session (always reliable)
    local resolvedSpecID = EllesmereUIDB.lastSpecByChar[charKey]

    -- Fall back to live API if no cached value
    if not resolvedSpecID then
        local specIdx = GetSpecialization and GetSpecialization()
        if specIdx and specIdx > 0 then
            local liveSpecID = GetSpecializationInfo(specIdx)
            if liveSpecID then
                resolvedSpecID = liveSpecID
                EllesmereUIDB.lastSpecByChar[charKey] = resolvedSpecID
            end
        end
    end

    if not resolvedSpecID then return nil end

    local targetProfile = specProfiles[resolvedSpecID]
    if not targetProfile then return nil end

    local profiles = EllesmereUIDB.profiles
    if not profiles or not profiles[targetProfile] then return nil end

    return targetProfile, resolvedSpecID, charKey
end

-------------------------------------------------------------------------------
--  Spec profile pre-seed
--
--  Runs once just before child addon OnEnable calls, after all OnInitialize
--  calls have completed (so all NewDB calls have run).
--  At this point the spec API is available, so we can resolve the current
--  spec and re-point all db.profile references to the correct profile table
--  in the central store before any addon builds its UI.
--
--  This is the sole pre-OnEnable resolution point. NewDB reads activeProfile
--  as-is (defaults to "Default" or whatever was saved from last session).
-------------------------------------------------------------------------------

--- Called by EllesmereUI_Lite just before child addon OnEnable calls fire.
--- Uses ResolveSpecProfile() to determine the correct profile, then
--- re-points all db.profile references via RepointAllDBs.
function EllesmereUI.PreSeedSpecProfile()
    local targetProfile, resolvedSpecID = ResolveSpecProfile()
    if not targetProfile then
        -- No spec assignment resolved; lock auto-save if spec profiles exist
        if EllesmereUIDB and EllesmereUIDB.specProfiles and next(EllesmereUIDB.specProfiles) then
            EllesmereUI._profileSaveLocked = true
        end
        return
    end

    EllesmereUIDB.activeProfile = targetProfile
    RepointAllDBs(targetProfile)
    EllesmereUI._preSeedComplete = true
end

--- Get the live profile table for an addon.
--- All addons use _dbRegistry (which points into
--- EllesmereUIDB.profiles[active].addons[folder]).
local function GetAddonProfile(entry)
    if EllesmereUI.Lite and EllesmereUI.Lite._dbRegistry then
        for _, db in ipairs(EllesmereUI.Lite._dbRegistry) do
            if db.folder == entry.folder then
                return db.profile
            end
        end
    end
    return nil
end

--- Snapshot the current state of all loaded addons into a profile data table
function EllesmereUI.SnapshotAllAddons()
    local data = { addons = {} }
    for _, entry in ipairs(ADDON_DB_MAP) do
        if IsAddonLoaded(entry.folder) then
            local profile = GetAddonProfile(entry)
            if profile then
                data.addons[entry.folder] = DeepCopy(profile)
            end
        end
    end
    -- Include global font and color settings
    data.fonts = DeepCopy(EllesmereUI.GetFontsDB())
    local cc = EllesmereUI.GetCustomColorsDB()
    data.customColors = DeepCopy(cc)
    -- Include unlock mode layout data (anchors, size matches)
    if EllesmereUIDB then
        data.unlockLayout = {
            anchors       = DeepCopy(EllesmereUIDB.unlockAnchors     or {}),
            widthMatch    = DeepCopy(EllesmereUIDB.unlockWidthMatch  or {}),
            heightMatch   = DeepCopy(EllesmereUIDB.unlockHeightMatch or {}),
            phantomBounds = DeepCopy(EllesmereUIDB.phantomBounds     or {}),
        }
    end
    return data
end

--[[ ADDON-SPECIFIC EXPORT DISABLED
--- Snapshot a single addon's profile
function EllesmereUI.SnapshotAddon(folderName)
    for _, entry in ipairs(ADDON_DB_MAP) do
        if entry.folder == folderName and IsAddonLoaded(folderName) then
            local profile = GetAddonProfile(entry)
            if profile then return DeepCopy(profile) end
        end
    end
    return nil
end

--- Snapshot multiple addons (for multi-addon export)
function EllesmereUI.SnapshotAddons(folderList)
    local data = { addons = {} }
    for _, folderName in ipairs(folderList) do
        for _, entry in ipairs(ADDON_DB_MAP) do
            if entry.folder == folderName and IsAddonLoaded(folderName) then
                local profile = GetAddonProfile(entry)
                if profile then
                    data.addons[folderName] = DeepCopy(profile)
                end
                break
            end
        end
    end
    -- Always include fonts and colors
    data.fonts = DeepCopy(EllesmereUI.GetFontsDB())
    data.customColors = DeepCopy(EllesmereUI.GetCustomColorsDB())
    -- Include unlock mode layout data
    if EllesmereUIDB then
        data.unlockLayout = {
            anchors       = DeepCopy(EllesmereUIDB.unlockAnchors     or {}),
            widthMatch    = DeepCopy(EllesmereUIDB.unlockWidthMatch  or {}),
            heightMatch   = DeepCopy(EllesmereUIDB.unlockHeightMatch or {}),
            phantomBounds = DeepCopy(EllesmereUIDB.phantomBounds     or {}),
        }
    end
    return data
end
--]] -- END ADDON-SPECIFIC EXPORT DISABLED

--- Apply imported profile data into the live db.profile tables.
--- Used by import to write external data into the active profile.
--- For normal profile switching, use SwitchProfile (which calls RepointAllDBs).
function EllesmereUI.ApplyProfileData(profileData)
    if not profileData or not profileData.addons then return end

    -- Build a folder -> db lookup from the Lite registry
    local dbByFolder = {}
    if EllesmereUI.Lite and EllesmereUI.Lite._dbRegistry then
        for _, db in ipairs(EllesmereUI.Lite._dbRegistry) do
            if db.folder then dbByFolder[db.folder] = db end
        end
    end

    for _, entry in ipairs(ADDON_DB_MAP) do
        local snap = profileData.addons[entry.folder]
        if snap and IsAddonLoaded(entry.folder) then
            local db = dbByFolder[entry.folder]
            if db then
                local profile = db.profile
                -- TBB and barGlows are spec-specific (in spellAssignments),
                -- not in profile. No save/restore needed on profile switch.
                for k in pairs(profile) do profile[k] = nil end
                for k, v in pairs(snap) do profile[k] = DeepCopy(v) end
                if db._profileDefaults then
                    EllesmereUI.Lite.DeepMergeDefaults(profile, db._profileDefaults)
                end
                -- Ensure per-unit bg colors are never nil after import
                if entry.folder == "EllesmereUIUnitFrames" then
                    local UF_UNITS = { "player", "target", "focus", "boss", "pet", "totPet" }
                    local DEF_BG = 17/255
                    for _, uKey in ipairs(UF_UNITS) do
                        local s = profile[uKey]
                        if s and s.customBgColor == nil then
                            s.customBgColor = { r = DEF_BG, g = DEF_BG, b = DEF_BG }
                        end
                    end
                end
            end
        end
    end
    -- Apply fonts and colors
    do
        local fontsDB = EllesmereUI.GetFontsDB()
        for k in pairs(fontsDB) do fontsDB[k] = nil end
        if profileData.fonts then
            for k, v in pairs(profileData.fonts) do fontsDB[k] = DeepCopy(v) end
        end
        if fontsDB.global      == nil then fontsDB.global      = "Expressway" end
        if fontsDB.outlineMode == nil then fontsDB.outlineMode = "shadow"     end
    end
    do
        local colorsDB = EllesmereUI.GetCustomColorsDB()
        for k in pairs(colorsDB) do colorsDB[k] = nil end
        if profileData.customColors then
            for k, v in pairs(profileData.customColors) do colorsDB[k] = DeepCopy(v) end
        end
    end
    -- Restore unlock mode layout data
    if EllesmereUIDB then
        local ul = profileData.unlockLayout
        if ul then
            EllesmereUIDB.unlockAnchors     = DeepCopy(ul.anchors      or {})
            EllesmereUIDB.unlockWidthMatch  = DeepCopy(ul.widthMatch   or {})
            EllesmereUIDB.unlockHeightMatch = DeepCopy(ul.heightMatch  or {})
            EllesmereUIDB.phantomBounds     = DeepCopy(ul.phantomBounds or {})
        end
        -- If profile predates unlockLayout, leave live data untouched
    end
end

--- Trigger live refresh on all loaded addons after a profile apply.
function EllesmereUI.RefreshAllAddons()
    -- Suppress stale anchor moves on AB bars during the rebuild phase.
    -- LayoutBar positions them from the new profile's barPositions; resize
    -- hooks would reposition them with old-profile offsets (1-frame blink).
    -- Separate flag from _applyingSavedPositions so CDM's early-return in
    -- ApplyAnchorPosition (which checks _applyingSavedPositions) isn't
    -- triggered prematurely by the wider window.
    EllesmereUI._abAnchorSuppressed = true
    -- ResourceBars (full rebuild)
    if _G._ERB_Apply then _G._ERB_Apply() end
    -- CDM: skip during spec-profile switch. CDM's SPELLS_CHANGED handler
    -- will detect the spec key mismatch and rebuild with the correct spec.
    -- Running it here would race with that rebuild.
    if not EllesmereUI._specProfileSwitching then
        if _G._ECME_LoadSpecProfile and _G._ECME_GetCurrentSpecKey then
            local curKey = _G._ECME_GetCurrentSpecKey()
            if curKey then _G._ECME_LoadSpecProfile(curKey) end
        end
        if _G._ECME_Apply then _G._ECME_Apply() end
    end
    -- Cursor (style + position)
    if _G._ECL_Apply then _G._ECL_Apply() end
    if _G._ECL_ApplyTrail then _G._ECL_ApplyTrail() end
    if _G._ECL_ApplyGCDCircle then _G._ECL_ApplyGCDCircle() end
    if _G._ECL_ApplyCastCircle then _G._ECL_ApplyCastCircle() end
    -- AuraBuffReminders (refresh + position)
    if _G._EABR_RequestRefresh then _G._EABR_RequestRefresh() end
    if _G._EABR_ApplyUnlockPos then _G._EABR_ApplyUnlockPos() end
    -- ActionBars (style + layout + position)
    if _G._EAB_Apply then _G._EAB_Apply() end
    -- UnitFrames (style + layout + position)
    if _G._EUF_ReloadFrames then _G._EUF_ReloadFrames() end
    -- Nameplates
    if _G._ENP_RefreshAllSettings then _G._ENP_RefreshAllSettings() end
    -- Quest Tracker
    if _G._EQT_RefreshAll then _G._EQT_RefreshAll() end
    -- Chat (sidebar icons, borders, fonts, visibility)
    if _G._ECHAT_RefreshAll then _G._ECHAT_RefreshAll() end
    -- Friends List
    if _G._EFR_ApplyFriends then _G._EFR_ApplyFriends() end
    -- Mythic Timer
    if _G._EMT_Apply then _G._EMT_Apply() end
    -- Damage Meters
    if _G._EDM_Apply then _G._EDM_Apply() end
    -- Dragon Riding HUD
    if _G._EDR_Rebuild then _G._EDR_Rebuild() end
    -- Minimap (flyout button state)
    if _G._EMIN_RefreshFlyout then _G._EMIN_RefreshFlyout() end
    -- Global class/power colors (updates oUF, nameplates, raid frames)
    if EllesmereUI.ApplyColorsToOUF then EllesmereUI.ApplyColorsToOUF() end
    -- Re-register unlock elements for all modules whose bar sets can
    -- differ between profiles. Without this, _applySavedPositions uses
    -- stale registrations from the outgoing profile and anchors fail
    -- for elements that only exist in the incoming profile (they land
    -- at CENTER/CENTER = screen center).
    if _G._ECME_RegisterUnlock then _G._ECME_RegisterUnlock() end
    if _G._ECME_RegisterTBBUnlock then _G._ECME_RegisterTBBUnlock() end
    if _G._ERB_RegisterUnlock then _G._ERB_RegisterUnlock() end
    if _G._EABR_RegisterUnlock then _G._EABR_RegisterUnlock() end
    if _G._ECL_RegisterUnlock then _G._ECL_RegisterUnlock() end
    if _G._EUI_BattleRes_RegisterUnlock then _G._EUI_BattleRes_RegisterUnlock() end
    -- After all addons have rebuilt and positioned their frames from
    -- db.profile.positions, re-apply centralized grow-direction positioning
    -- (handles lazy migration of imported TOPLEFT positions to CENTER format)
    -- and resync anchor offsets so the anchor relationships stay correct for
    -- future drags. Triple-deferred so it runs AFTER debounced rebuilds have
    -- completed and frames are at final positions.
    -- Position re-application and anchor resync are deferred to
    -- OnSpecSwitchComplete (if spec switching) or run inline here
    -- for non-spec profile switches (manual switch from options).
    if not EllesmereUI._specProfileSwitching then
        C_Timer.After(0, function()
            C_Timer.After(0, function()
                if EllesmereUI._applySavedPositions then
                    EllesmereUI._applySavedPositions()
                end
                if EllesmereUI.ResyncAnchorOffsets then
                    EllesmereUI.ResyncAnchorOffsets()
                end
            end)
        end)
    end
    -- If CDM is loaded, it calls OnSpecSwitchComplete from ProcessSpecChange
    -- after its SPELLS_CHANGED rebuild finishes. If CDM is NOT loaded,
    -- complete immediately since there's nothing to wait for.
    local cdmLoaded = C_AddOns and C_AddOns.IsAddOnLoaded
        and C_AddOns.IsAddOnLoaded("EllesmereUICooldownManager")
    if not cdmLoaded then
        EllesmereUI.OnSpecSwitchComplete()
    end
end

--- Called by CDM (or RefreshAllAddons if CDM not loaded) when the spec
--- switch rebuild is fully settled. Clears the suppression flag and
--- re-applies width/height matches so all matched frames pick up
--- the new profile dimensions.
function EllesmereUI.OnSpecSwitchComplete()
    EllesmereUI._specProfileSwitching = false
    if EllesmereUI.ApplyAllWidthHeightMatches then
        EllesmereUI.ApplyAllWidthHeightMatches()
    end
    if EllesmereUI._applySavedPositions then
        EllesmereUI._applySavedPositions()
    end
    if EllesmereUI.ResyncAnchorOffsets then
        EllesmereUI.ResyncAnchorOffsets()
    end
end

-------------------------------------------------------------------------------
--  Profile Keybinds
--  Each profile can have a key bound to switch to it instantly.
--  Stored in EllesmereUIDB.profileKeybinds = { ["Name"] = "CTRL-1", ... }
--  Uses hidden buttons + SetOverrideBindingClick, same pattern as Party Mode.
-------------------------------------------------------------------------------
local _profileBindBtns = {} -- [profileName] = hidden Button

local function GetProfileKeybinds()
    if not EllesmereUIDB then EllesmereUIDB = {} end
    if not EllesmereUIDB.profileKeybinds then EllesmereUIDB.profileKeybinds = {} end
    return EllesmereUIDB.profileKeybinds
end

local function EnsureProfileBindBtn(profileName)
    if _profileBindBtns[profileName] then return _profileBindBtns[profileName] end
    local safeName = profileName:gsub("[^%w]", "")
    local btn = CreateFrame("Button", "EllesmereUIProfileBind_" .. safeName, UIParent)
    btn:Hide()
    btn:SetScript("OnClick", function()
        local active = EllesmereUI.GetActiveProfileName()
        if active == profileName then return end
        local _, profiles = EllesmereUI.GetProfileList()
        local fontWillChange = EllesmereUI.ProfileChangesFont(profiles and profiles[profileName])
        EllesmereUI.SwitchProfile(profileName)
        EllesmereUI.RefreshAllAddons()
        if fontWillChange then
            EllesmereUI:ShowConfirmPopup({
                title       = "Reload Required",
                message     = "Font changed. A UI reload is needed to apply the new font.",
                confirmText = "Reload Now",
                cancelText  = "Later",
                onConfirm   = function() ReloadUI() end,
            })
        else
            EllesmereUI:RefreshPage()
        end
    end)
    _profileBindBtns[profileName] = btn
    return btn
end

function EllesmereUI.SetProfileKeybind(profileName, key)
    local kb = GetProfileKeybinds()
    -- Clear old binding for this profile
    local oldKey = kb[profileName]
    local btn = EnsureProfileBindBtn(profileName)
    if oldKey then
        ClearOverrideBindings(btn)
    end
    if key then
        kb[profileName] = key
        SetOverrideBindingClick(btn, true, key, btn:GetName())
    else
        kb[profileName] = nil
    end
end

function EllesmereUI.GetProfileKeybind(profileName)
    local kb = GetProfileKeybinds()
    return kb[profileName]
end

--- Called on login to restore all saved profile keybinds
function EllesmereUI.RestoreProfileKeybinds()
    local kb = GetProfileKeybinds()
    for profileName, key in pairs(kb) do
        if key then
            local btn = EnsureProfileBindBtn(profileName)
            SetOverrideBindingClick(btn, true, key, btn:GetName())
        end
    end
end

--- Update keybind references when a profile is renamed
function EllesmereUI.OnProfileRenamed(oldName, newName)
    local kb = GetProfileKeybinds()
    local key = kb[oldName]
    if key then
        local oldBtn = _profileBindBtns[oldName]
        if oldBtn then ClearOverrideBindings(oldBtn) end
        _profileBindBtns[oldName] = nil
        kb[oldName] = nil
        kb[newName] = key
        local newBtn = EnsureProfileBindBtn(newName)
        SetOverrideBindingClick(newBtn, true, key, newBtn:GetName())
    end
end

--- Clean up keybind when a profile is deleted
function EllesmereUI.OnProfileDeleted(profileName)
    local kb = GetProfileKeybinds()
    if kb[profileName] then
        local btn = _profileBindBtns[profileName]
        if btn then ClearOverrideBindings(btn) end
        _profileBindBtns[profileName] = nil
        kb[profileName] = nil
    end
end

--- Returns true if applying profileData would change the global font or outline mode.
--- Used to decide whether to show a reload popup after a profile switch.
function EllesmereUI.ProfileChangesFont(profileData)
    if not profileData or not profileData.fonts then return false end
    local cur = EllesmereUI.GetFontsDB()
    local curFont    = cur.global      or "Expressway"
    local curOutline = cur.outlineMode or "shadow"
    local newFont    = profileData.fonts.global      or "Expressway"
    local newOutline = profileData.fonts.outlineMode or "shadow"
    -- "none" and "shadow" are both drop-shadow (no outline) -- treat as identical
    if curOutline == "none" then curOutline = "shadow" end
    if newOutline == "none" then newOutline = "shadow" end
    return curFont ~= newFont or curOutline ~= newOutline
end

--[[ ADDON-SPECIFIC EXPORT DISABLED
--- Apply a partial profile (specific addons only) by merging into active
function EllesmereUI.ApplyPartialProfile(profileData)
    if not profileData or not profileData.addons then return end
    for folderName, snap in pairs(profileData.addons) do
        for _, entry in ipairs(ADDON_DB_MAP) do
            if entry.folder == folderName and IsAddonLoaded(folderName) then
                local profile = GetAddonProfile(entry)
                if profile then
                    for k, v in pairs(snap) do
                        profile[k] = DeepCopy(v)
                    end
                end
                break
            end
        end
    end
    -- Always apply fonts and colors if present
    if profileData.fonts then
        local fontsDB = EllesmereUI.GetFontsDB()
        for k, v in pairs(profileData.fonts) do
            fontsDB[k] = DeepCopy(v)
        end
    end
    if profileData.customColors then
        local colorsDB = EllesmereUI.GetCustomColorsDB()
        for k, v in pairs(profileData.customColors) do
            colorsDB[k] = DeepCopy(v)
        end
    end
end
--]] -- END ADDON-SPECIFIC EXPORT DISABLED

-------------------------------------------------------------------------------
--  Export / Import
--  Format: !EUI_<base64 encoded compressed serialized data>
--  The data table contains:
--    { version = 3, type = "full"|"partial", data = profileData }
-------------------------------------------------------------------------------
local EXPORT_PREFIX = "!EUI_"

function EllesmereUI.ExportProfile(profileName)
    local db = GetProfilesDB()
    local profileData = db.profiles[profileName]
    if not profileData then return nil end
    -- If exporting the active profile, ensure fonts/colors/layout are current
    if profileName == (db.activeProfile or "Default") then
        profileData.fonts = DeepCopy(EllesmereUI.GetFontsDB())
        profileData.customColors = DeepCopy(EllesmereUI.GetCustomColorsDB())
        profileData.unlockLayout = {
            anchors       = DeepCopy(EllesmereUIDB.unlockAnchors     or {}),
            widthMatch    = DeepCopy(EllesmereUIDB.unlockWidthMatch  or {}),
            heightMatch   = DeepCopy(EllesmereUIDB.unlockHeightMatch or {}),
            phantomBounds = DeepCopy(EllesmereUIDB.phantomBounds     or {}),
        }
    end
    local exportData = DeepCopy(profileData)
    -- Exclude spec-specific data from export
    exportData.trackedBuffBars = nil
    exportData.tbbPositions = nil
    -- CDM spell assignments are NOT exported -- users share spell layouts
    -- via Blizzard's built-in CDM sharing system instead.
    exportData.spellAssignments = nil
    local payload = { version = 3, type = "full", data = exportData }
    local serialized = Serializer.Serialize(payload)
    if not LibDeflate then return nil end
    local compressed = LibDeflate:CompressDeflate(serialized)
    local encoded = LibDeflate:EncodeForPrint(compressed)
    return EXPORT_PREFIX .. encoded
end

--[[ ADDON-SPECIFIC EXPORT DISABLED
function EllesmereUI.ExportAddons(folderList)
    local profileData = EllesmereUI.SnapshotAddons(folderList)
    local sw, sh = GetPhysicalScreenSize()
    local euiScale = EllesmereUIDB and EllesmereUIDB.ppUIScale or (UIParent and UIParent:GetScale()) or 1
    local meta = {
        euiScale = euiScale,
        screenW  = sw and math.floor(sw) or 0,
        screenH  = sh and math.floor(sh) or 0,
    }
    local payload = { version = 3, type = "partial", data = profileData, meta = meta }
    local serialized = Serializer.Serialize(payload)
    if not LibDeflate then return nil end
    local compressed = LibDeflate:CompressDeflate(serialized)
    local encoded = LibDeflate:EncodeForPrint(compressed)
    return EXPORT_PREFIX .. encoded
end
--]] -- END ADDON-SPECIFIC EXPORT DISABLED

-------------------------------------------------------------------------------
--  CDM spec profile helpers for export/import spec picker
-------------------------------------------------------------------------------

--- Get info about which specs have data in the CDM specProfiles table.
--- Returns: { { key="250", name="Blood", icon=..., hasData=true }, ... }
--- Includes ALL specs for the player's class, with hasData indicating
--- whether specProfiles contains data for that spec.
function EllesmereUI.GetCDMSpecInfo()
    local sa = EllesmereUIDB and EllesmereUIDB.spellAssignments
    local specProfiles = sa and sa.specProfiles or {}
    local result = {}
    local numSpecs = GetNumSpecializations and GetNumSpecializations() or 0
    for i = 1, numSpecs do
        local specID, sName, _, sIcon = GetSpecializationInfo(i)
        if specID then
            local key = tostring(specID)
            result[#result + 1] = {
                key     = key,
                name    = sName or ("Spec " .. key),
                icon    = sIcon,
                hasData = specProfiles[key] ~= nil,
            }
        end
    end
    return result
end

--- Filter specProfiles in an export snapshot to only include selected specs.
--- Reads from snapshot.spellAssignments (the dedicated store copy on the payload).
--- Modifies the snapshot in-place. selectedSpecs = { ["250"] = true, ... }
function EllesmereUI.FilterExportSpecProfiles(snapshot, selectedSpecs)
    if not snapshot or not snapshot.spellAssignments then return end
    local sp = snapshot.spellAssignments.specProfiles
    if not sp then return end
    for key in pairs(sp) do
        if not selectedSpecs[key] then
            sp[key] = nil
        end
    end
end

--- After a profile import, apply only selected specs' specProfiles from the
--- imported data into the dedicated spell assignment store.
--- importedSpellAssignments = the spellAssignments object from the import payload.
--- selectedSpecs = { ["250"] = true, ... }
function EllesmereUI.ApplyImportedSpecProfiles(importedSpellAssignments, selectedSpecs)
    if not importedSpellAssignments or not importedSpellAssignments.specProfiles then return end
    if not EllesmereUIDB.spellAssignments then
        EllesmereUIDB.spellAssignments = { specProfiles = {} }
    end
    local sa = EllesmereUIDB.spellAssignments
    if not sa.specProfiles then sa.specProfiles = {} end
    for key, data in pairs(importedSpellAssignments.specProfiles) do
        if selectedSpecs[key] then
            sa.specProfiles[key] = DeepCopy(data)
        end
    end
    -- If the current spec was imported, reload it live
    if _G._ECME_GetCurrentSpecKey and _G._ECME_LoadSpecProfile then
        local currentKey = _G._ECME_GetCurrentSpecKey()
        if currentKey and selectedSpecs[currentKey] then
            _G._ECME_LoadSpecProfile(currentKey)
        end
    end
end

--- Get the list of spec keys that have data in imported spell assignments.
--- Returns same format as GetCDMSpecInfo but based on imported data.
--- Accepts either the new spellAssignments format or legacy CDM snapshot.
function EllesmereUI.GetImportedCDMSpecInfo(importedSpellAssignments)
    if not importedSpellAssignments then return {} end
    -- Support both new format (spellAssignments.specProfiles) and legacy (cdmSnap.specProfiles)
    local specProfiles = importedSpellAssignments.specProfiles
    if not specProfiles then return {} end
    local result = {}
    for specKey in pairs(specProfiles) do
        local specID = tonumber(specKey)
        local name, icon
        if specID and specID > 0 and GetSpecializationInfoByID then
            local _, sName, _, sIcon = GetSpecializationInfoByID(specID)
            name = sName
            icon = sIcon
        end
        result[#result + 1] = {
            key     = specKey,
            name    = name or ("Spec " .. specKey),
            icon    = icon,
            hasData = true,
        }
    end
    table.sort(result, function(a, b) return a.key < b.key end)
    return result
end

-------------------------------------------------------------------------------
--  CDM Spec Picker Popup
--  Thin wrapper around ShowSpecAssignPopup for CDM export/import.
--
--  opts = {
--      title    = string,
--      subtitle = string,
--      confirmText = string (button label),
--      specs    = { { key, name, icon, hasData, checked }, ... },
--      onConfirm = function(selectedSpecs)  -- { ["250"]=true, ... }
--      onCancel  = function() (optional)
--  }
--  specs[i].hasData = false grays out the row and shows disabled tooltip.
--  specs[i].checked = initial checked state (only for hasData=true rows).
-------------------------------------------------------------------------------
do
    -- Dummy db/dbKey/presetKey for the assignments table
    local dummyDB = { _cdmPick = { _cdm = {} } }

    function EllesmereUI:ShowCDMSpecPickerPopup(opts)
        local specs = opts.specs or {}

        -- Reset assignments
        dummyDB._cdmPick._cdm = {}

        -- Pre-check specs that have data; all specs remain selectable
        local preCheckedSpecs = {}
        for _, sp in ipairs(specs) do
            local numID = tonumber(sp.key)
            if numID and sp.checked then
                preCheckedSpecs[numID] = true
            end
        end

        EllesmereUI:ShowSpecAssignPopup({
            db              = dummyDB,
            dbKey           = "_cdmPick",
            presetKey       = "_cdm",
            title           = opts.title,
            subtitle        = opts.subtitle,
            buttonText      = opts.confirmText or "Confirm",
            disabledSpecs   = {},
            preCheckedSpecs = preCheckedSpecs,
            onConfirm       = opts.onConfirm and function(assignments)
                -- Convert numeric specID assignments back to string keys
                local selected = {}
                for specID in pairs(assignments) do
                    selected[tostring(specID)] = true
                end
                opts.onConfirm(selected)
            end,
            onCancel        = opts.onCancel,
        })
    end
end

function EllesmereUI.ExportCurrentProfile()
    local profileData = EllesmereUI.SnapshotAllAddons()
    -- CDM spell assignments are NOT exported -- users share spell layouts
    -- via Blizzard's built-in CDM sharing system instead.
    profileData.spellAssignments = nil
    local sw, sh = GetPhysicalScreenSize()
    -- Use EllesmereUI's own stored scale (UIParent scale), not Blizzard's CVar
    local euiScale = EllesmereUIDB and EllesmereUIDB.ppUIScale or (UIParent and UIParent:GetScale()) or 1
    local meta = {
        euiScale = euiScale,
        screenW  = sw and math.floor(sw) or 0,
        screenH  = sh and math.floor(sh) or 0,
    }
    local payload = { version = 3, type = "full", data = profileData, meta = meta }
    local serialized = Serializer.Serialize(payload)
    if not LibDeflate then return nil end
    local compressed = LibDeflate:CompressDeflate(serialized)
    local encoded = LibDeflate:EncodeForPrint(compressed)
    return EXPORT_PREFIX .. encoded
end

function EllesmereUI.DecodeImportString(importStr)
    if not importStr or #importStr < 5 then return nil, "Invalid string" end
    -- Detect old CDM bar layout strings (format removed in 5.1.2)
    if importStr:sub(1, 9) == "!EUICDM_" then
        return nil, "This is an old CDM Bar Layout string. This format is no longer supported. Use the standard profile import instead."
    end
    if importStr:sub(1, #EXPORT_PREFIX) ~= EXPORT_PREFIX then
        return nil, "Not a valid EllesmereUI string. Make sure you copied the entire string."
    end
    if not LibDeflate then return nil, "LibDeflate not available" end
    local encoded = importStr:sub(#EXPORT_PREFIX + 1)
    local decoded = LibDeflate:DecodeForPrint(encoded)
    if not decoded then return nil, "Failed to decode string" end
    local decompressed = LibDeflate:DecompressDeflate(decoded)
    if not decompressed then return nil, "Failed to decompress data" end
    local payload = Serializer.Deserialize(decompressed)
    if not payload or type(payload) ~= "table" then
        return nil, "Failed to deserialize data"
    end
    if not payload.version or payload.version < 3 then
        return nil, "This profile was created before the beta wipe and is no longer compatible. Please create a new export."
    end
    if payload.version > 3 then
        return nil, "This profile was created with a newer version of EllesmereUI. Please update your addon."
    end
    return payload, nil
end

--- Reset class-dependent fill colors in Resource Bars after a profile import.
--- The exporter's class color may be baked into fillR/fillG/fillB; this
--- resets them to the importer's own class/power colors and clears
--- customColored so the bars use runtime class color lookup.
local function FixupImportedClassColors()
    local rbEntry
    for _, e in ipairs(ADDON_DB_MAP) do
        if e.folder == "EllesmereUIResourceBars" then rbEntry = e; break end
    end
    if not rbEntry or not IsAddonLoaded(rbEntry.folder) then return end
    local profile = GetAddonProfile(rbEntry)
    if not profile then return end

    local _, classFile = UnitClass("player")
    -- CLASS_COLORS and POWER_COLORS are local to ResourceBars, so we
    -- use the same lookup the addon uses at init time.
    local classColors = EllesmereUI.CLASS_COLOR_MAP
    local cc = classColors and classColors[classFile]

    -- Health bar: reset to importer's class color
    if profile.health and not profile.health.darkTheme then
        profile.health.customColored = false
        if cc then
            profile.health.fillR = cc.r
            profile.health.fillG = cc.g
            profile.health.fillB = cc.b
        end
    end
end

--- Import a profile string. Returns: success, errorMsg
--- The caller must provide a name for the new profile.
function EllesmereUI.ImportProfile(importStr, profileName)
    local payload, err = EllesmereUI.DecodeImportString(importStr)
    if not payload then return false, err end

    local db = GetProfilesDB()

    if payload.type == "cdm_spells" then
        return false, "This is a CDM Bar Layout string, not a profile string."
    end

    -- Check if current spec has an assigned profile (blocks auto-apply)
    local specLocked = false
    do
        local si = GetSpecialization and GetSpecialization() or 0
        local sid = si and si > 0 and GetSpecializationInfo(si) or nil
        if sid then
            local assigned = db.specProfiles and db.specProfiles[sid]
            if assigned then specLocked = true end
        end
    end

    if payload.type == "full" then
        -- Full profile: store as a new named profile
        local stored = DeepCopy(payload.data)
        -- Strip spell assignment data from stored profile (lives in dedicated store)
        if stored.addons and stored.addons["EllesmereUICooldownManager"] then
            stored.addons["EllesmereUICooldownManager"].specProfiles = nil
            stored.addons["EllesmereUICooldownManager"].barGlows = nil
        end
        stored.spellAssignments = nil
        -- Snap all positions to the physical pixel grid (imported profiles
        -- may come from a different version without pixel snapping)
        if EllesmereUI.SnapProfilePositions then
            EllesmereUI.SnapProfilePositions(stored)
        end
        db.profiles[profileName] = stored
        -- Add to order if not present
        local found = false
        for _, n in ipairs(db.profileOrder) do
            if n == profileName then found = true; break end
        end
        if not found then
            table.insert(db.profileOrder, 1, profileName)
        end
        -- CDM spell assignments are NOT written here. The caller shows
        -- a spec picker popup that lets the user choose which specs to
        -- import, then calls ApplyImportedSpecProfiles() with only the
        -- selected specs. Writing here would bypass that selection.
        -- Disable all reskin module syncs so the pre-logout sync
        -- doesn't overwrite other profiles with the imported data.
        if EllesmereUI._reskinModules and EllesmereUIDB then
            if not EllesmereUIDB.syncedModules then EllesmereUIDB.syncedModules = {} end
            for folder in pairs(EllesmereUI._reskinModules) do
                EllesmereUIDB.syncedModules[folder] = false
            end
        end

        if specLocked then
            return true, nil, "spec_locked"
        end
        -- Make it the active profile and re-point db references
        db.activeProfile = profileName
        RepointAllDBs(profileName)
        -- Apply imported data into the live db.profile tables
        EllesmereUI.ApplyProfileData(payload.data)
        FixupImportedClassColors()
        -- Don't ReloadUI() here: the caller (options panel import flow)
        -- may need to show the CDM spec picker popup before reloading.
        -- The caller handles the reload/refresh after the popup completes.
        return true, nil
    --[[ ADDON-SPECIFIC EXPORT DISABLED
    elseif payload.type == "partial" then
        -- Partial: deep-copy current profile, overwrite the imported addons
        local current = db.activeProfile or "Default"
        local currentData = db.profiles[current]
        local merged = currentData and DeepCopy(currentData) or {}
        if not merged.addons then merged.addons = {} end
        if payload.data and payload.data.addons then
            for folder, snap in pairs(payload.data.addons) do
                local copy = DeepCopy(snap)
                -- Strip spell assignment data from CDM profile (lives in dedicated store)
                if folder == "EllesmereUICooldownManager" and type(copy) == "table" then
                    copy.specProfiles = nil
                    copy.barGlows = nil
                end
                merged.addons[folder] = copy
            end
        end
        if payload.data.fonts then
            merged.fonts = DeepCopy(payload.data.fonts)
        end
        if payload.data.customColors then
            merged.customColors = DeepCopy(payload.data.customColors)
        end
        -- Store as new profile
        merged.spellAssignments = nil
        db.profiles[profileName] = merged
        local found = false
        for _, n in ipairs(db.profileOrder) do
            if n == profileName then found = true; break end
        end
        if not found then
            table.insert(db.profileOrder, 1, profileName)
        end
        -- Write spell assignments to dedicated store
        if payload.data and payload.data.spellAssignments then
            if not EllesmereUIDB.spellAssignments then
                EllesmereUIDB.spellAssignments = { specProfiles = {} }
            end
            local sa = EllesmereUIDB.spellAssignments
            local imported = payload.data.spellAssignments
            if imported.specProfiles then
                for key, data in pairs(imported.specProfiles) do
                    sa.specProfiles[key] = DeepCopy(data)
                end
            end
            if imported.barGlows and next(imported.barGlows) then
                -- barGlows is now per-spec in specProfiles, not global. Skip import.
            end
        end
        -- Backward compat: extract specProfiles from CDM addon data (pre-migration format)
        if payload.data and payload.data.addons and payload.data.addons["EllesmereUICooldownManager"] then
            local cdm = payload.data.addons["EllesmereUICooldownManager"]
            if cdm.specProfiles then
                if not EllesmereUIDB.spellAssignments then
                    EllesmereUIDB.spellAssignments = { specProfiles = {} }
                end
                for key, data in pairs(cdm.specProfiles) do
                    if not EllesmereUIDB.spellAssignments.specProfiles[key] then
                        EllesmereUIDB.spellAssignments.specProfiles[key] = DeepCopy(data)
                    end
                end
            end
            if cdm.barGlows then
                if not EllesmereUIDB.spellAssignments then
                    EllesmereUIDB.spellAssignments = { specProfiles = {} }
                end
                if not next(EllesmereUIDB.spellAssignments.barGlows or {}) then
                    -- barGlows is now per-spec in specProfiles, not global. Skip import.
                end
            end
        end
        if specLocked then
            return true, nil, "spec_locked"
        end
        db.activeProfile = profileName
        RepointAllDBs(profileName)
        EllesmereUI.ApplyProfileData(merged)
        FixupImportedClassColors()
        -- Reload UI so every addon rebuilds from scratch with correct data
        ReloadUI()
        return true, nil
    --]] -- END ADDON-SPECIFIC EXPORT DISABLED
    end

    return false, "Unknown profile type"
end

-------------------------------------------------------------------------------
--  Profile management
-------------------------------------------------------------------------------
function EllesmereUI.SaveCurrentAsProfile(name)
    local db = GetProfilesDB()
    local current = db.activeProfile or "Default"
    local src = db.profiles[current]
    -- Deep-copy the current profile into the new name
    local copy = src and DeepCopy(src) or {}
    -- Ensure fonts/colors/unlock layout are current
    copy.fonts = DeepCopy(EllesmereUI.GetFontsDB())
    copy.customColors = DeepCopy(EllesmereUI.GetCustomColorsDB())
    copy.unlockLayout = {
        anchors       = DeepCopy(EllesmereUIDB.unlockAnchors     or {}),
        widthMatch    = DeepCopy(EllesmereUIDB.unlockWidthMatch  or {}),
        heightMatch   = DeepCopy(EllesmereUIDB.unlockHeightMatch or {}),
        phantomBounds = DeepCopy(EllesmereUIDB.phantomBounds     or {}),
    }
    db.profiles[name] = copy
    local found = false
    for _, n in ipairs(db.profileOrder) do
        if n == name then found = true; break end
    end
    if not found then
        table.insert(db.profileOrder, 1, name)
    end
    -- Switch to the new profile using the standard path so the outgoing
    -- profile's state is properly saved before repointing.
    EllesmereUI.SwitchProfile(name)
end

function EllesmereUI.DeleteProfile(name)
    local db = GetProfilesDB()
    db.profiles[name] = nil
    for i, n in ipairs(db.profileOrder) do
        if n == name then table.remove(db.profileOrder, i); break end
    end
    -- Clean up spec assignments
    for specID, pName in pairs(db.specProfiles) do
        if pName == name then db.specProfiles[specID] = nil end
    end
    -- Clean up keybind
    EllesmereUI.OnProfileDeleted(name)
    -- If deleted profile was active, fall back to Default
    if db.activeProfile == name then
        db.activeProfile = "Default"
        RepointAllDBs("Default")
    end
end

function EllesmereUI.RenameProfile(oldName, newName)
    local db = GetProfilesDB()
    if not db.profiles[oldName] then return end
    db.profiles[newName] = db.profiles[oldName]
    db.profiles[oldName] = nil
    for i, n in ipairs(db.profileOrder) do
        if n == oldName then db.profileOrder[i] = newName; break end
    end
    for specID, pName in pairs(db.specProfiles) do
        if pName == oldName then db.specProfiles[specID] = newName end
    end
    if db.activeProfile == oldName then
        db.activeProfile = newName
        RepointAllDBs(newName)
    end
    -- Update keybind reference
    EllesmereUI.OnProfileRenamed(oldName, newName)
end

function EllesmereUI.SwitchProfile(name)
    local db = GetProfilesDB()
    if not db.profiles[name] then return end
    -- Save current fonts/colors into the outgoing profile before switching
    local outgoing = db.profiles[db.activeProfile or "Default"]
    if outgoing then
        outgoing.fonts = DeepCopy(EllesmereUI.GetFontsDB())
        outgoing.customColors = DeepCopy(EllesmereUI.GetCustomColorsDB())
        -- Save unlock layout into outgoing profile
        outgoing.unlockLayout = {
            anchors       = DeepCopy(EllesmereUIDB.unlockAnchors     or {}),
            widthMatch    = DeepCopy(EllesmereUIDB.unlockWidthMatch  or {}),
            heightMatch   = DeepCopy(EllesmereUIDB.unlockHeightMatch or {}),
            phantomBounds = DeepCopy(EllesmereUIDB.phantomBounds     or {}),
        }
    end
    db.activeProfile = name
    RepointAllDBs(name)
end

function EllesmereUI.GetActiveProfileName()
    local db = GetProfilesDB()
    return db.activeProfile or "Default"
end

function EllesmereUI.GetProfileList()
    local db = GetProfilesDB()
    return db.profileOrder, db.profiles
end

function EllesmereUI.AssignProfileToSpec(profileName, specID)
    local db = GetProfilesDB()
    db.specProfiles[specID] = profileName
end

function EllesmereUI.UnassignSpec(specID)
    local db = GetProfilesDB()
    db.specProfiles[specID] = nil
end

function EllesmereUI.GetSpecProfile(specID)
    local db = GetProfilesDB()
    return db.specProfiles[specID]
end

-------------------------------------------------------------------------------
--  AutoSaveActiveProfile: no-op in single-storage mode.
--  Addons write directly to EllesmereUIDB.profiles[active].addons[folder],
--  so there is nothing to snapshot. Kept as a stub so existing call sites
--  (keybind buttons, options panel hooks) do not error.
-------------------------------------------------------------------------------
function EllesmereUI.AutoSaveActiveProfile()
    -- Intentionally empty: single-storage means data is always in sync.
end

-------------------------------------------------------------------------------
--  Spec auto-switch handler
--
--  Single authoritative runtime handler for spec-based profile switching.
--  Uses ResolveSpecProfile() for all resolution. Defers the entire switch
--  during combat via pendingSpecSwitch / PLAYER_REGEN_ENABLED.
-------------------------------------------------------------------------------
do
    local specFrame = CreateFrame("Frame")
    local lastKnownSpecID = nil
    local lastKnownCharKey = nil
    local pendingSpecSwitch = false   -- true when a switch was deferred by combat
    local specRetryTimer = nil        -- retry handle for new characters

    specFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    specFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    specFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    specFrame:SetScript("OnEvent", function(_, event, unit)
        ---------------------------------------------------------------
        --  PLAYER_REGEN_ENABLED: handle deferred spec switch
        ---------------------------------------------------------------
        if event == "PLAYER_REGEN_ENABLED" then
            if pendingSpecSwitch then
                pendingSpecSwitch = false
                -- Re-resolve after combat ends (spec may have changed again)
                local targetProfile = ResolveSpecProfile()
                if targetProfile then
                    local current = EllesmereUIDB and EllesmereUIDB.activeProfile or "Default"
                    if current ~= targetProfile then
                        local fontWillChange = EllesmereUI.ProfileChangesFont(
                            EllesmereUIDB.profiles[targetProfile])
                        -- _specProfileSwitching disabled (see doSwitch comment)
                        EllesmereUI.SwitchProfile(targetProfile)
                        EllesmereUI.RefreshAllAddons()
                        if fontWillChange then
                            EllesmereUI:ShowConfirmPopup({
                                title       = "Reload Required",
                                message     = "Font changed. A UI reload is needed to apply the new font.",
                                confirmText = "Reload Now",
                                cancelText  = "Later",
                                onConfirm   = function() ReloadUI() end,
                            })
                        end
                    end
                end
            end
            return
        end

        ---------------------------------------------------------------
        --  Filter: only handle "player" for PLAYER_SPECIALIZATION_CHANGED
        ---------------------------------------------------------------
        if event == "PLAYER_SPECIALIZATION_CHANGED" and unit ~= "player" then
            return
        end

        ---------------------------------------------------------------
        --  Resolve the current spec via live API
        ---------------------------------------------------------------
        local specIdx = GetSpecialization and GetSpecialization() or 0
        local specID = specIdx and specIdx > 0
            and GetSpecializationInfo(specIdx) or nil

        if not specID then
            -- Spec info not available yet (common on brand new characters).
            -- Start a short polling retry so we can assign the correct
            -- profile once the server sends spec data.
            if not specRetryTimer and (lastKnownSpecID == nil) then
                local attempts = 0
                specRetryTimer = C_Timer.NewTicker(1, function(ticker)
                    attempts = attempts + 1
                    local idx = GetSpecialization and GetSpecialization() or 0
                    local sid = idx and idx > 0
                        and GetSpecializationInfo(idx) or nil
                    if sid then
                        ticker:Cancel()
                        specRetryTimer = nil
                        -- Record the spec so future events use the fast path
                        lastKnownSpecID = sid
                        local ck = UnitName("player") .. " - " .. GetRealmName()
                        lastKnownCharKey = ck
                        if not EllesmereUIDB then EllesmereUIDB = {} end
                        if not EllesmereUIDB.lastSpecByChar then
                            EllesmereUIDB.lastSpecByChar = {}
                        end
                        EllesmereUIDB.lastSpecByChar[ck] = sid
                        EllesmereUI._profileSaveLocked = false
                        -- Resolve via the unified function
                        local target = ResolveSpecProfile()
                        if target then
                            local cur = (EllesmereUIDB and EllesmereUIDB.activeProfile) or "Default"
                            if cur ~= target then
                                local fontChange = EllesmereUI.ProfileChangesFont(
                                    EllesmereUIDB.profiles[target])
                                -- _specProfileSwitching disabled (see doSwitch comment)
                                EllesmereUI.SwitchProfile(target)
                                EllesmereUI.RefreshAllAddons()
                                if fontChange then
                                    EllesmereUI:ShowConfirmPopup({
                                        title       = "Reload Required",
                                        message     = "Font changed. A UI reload is needed to apply the new font.",
                                        confirmText = "Reload Now",
                                        cancelText  = "Later",
                                        onConfirm   = function() ReloadUI() end,
                                    })
                                end
                            end
                        end
                    elseif attempts >= 10 then
                        ticker:Cancel()
                        specRetryTimer = nil
                    end
                end)
            end
            return
        end

        -- Spec resolved -- cancel any pending retry
        if specRetryTimer then
            specRetryTimer:Cancel()
            specRetryTimer = nil
        end

        local charKey = UnitName("player") .. " - " .. GetRealmName()
        local isFirstLogin = (lastKnownSpecID == nil)
        -- charChanged is true when the active character is different from the
        -- last session (alt-swap). On a plain /reload the charKey stays the same.
        local charChanged = (lastKnownCharKey ~= nil) and (lastKnownCharKey ~= charKey)

        -- On PLAYER_ENTERING_WORLD (reload/zone-in), skip if same character
        -- and same spec -- a plain /reload should not override the user's
        -- active profile selection.
        if event == "PLAYER_ENTERING_WORLD" then
            if not isFirstLogin and not charChanged and specID == lastKnownSpecID then
                return -- same char, same spec, nothing to do
            end
        end
        lastKnownSpecID = specID
        lastKnownCharKey = charKey

        -- Persist the current spec so PreSeedSpecProfile can guarantee the
        -- correct profile is loaded on next login via ResolveSpecProfile().
        if not EllesmereUIDB then EllesmereUIDB = {} end
        if not EllesmereUIDB.lastSpecByChar then EllesmereUIDB.lastSpecByChar = {} end
        EllesmereUIDB.lastSpecByChar[charKey] = specID

        -- Spec resolved successfully -- unlock auto-save if it was locked
        -- during PreSeedSpecProfile when spec was unavailable.
        EllesmereUI._profileSaveLocked = false

        ---------------------------------------------------------------
        --  Defer entire switch during combat
        ---------------------------------------------------------------
        if InCombatLockdown() then
            pendingSpecSwitch = true
            return
        end

        ---------------------------------------------------------------
        --  Resolve target profile via the unified function
        ---------------------------------------------------------------
        local db = GetProfilesDB()
        local targetProfile = ResolveSpecProfile()
        if targetProfile then
            local current = db.activeProfile or "Default"
            if current ~= targetProfile then
                local function doSwitch()
                    -- _specProfileSwitching disabled: was causing width/height
                    -- matches to never re-apply because SPELLS_CHANGED fires
                    -- before PLAYER_SPECIALIZATION_CHANGED (CDM completes
                    -- before the flag is set, flag stuck true forever).
                    -- EllesmereUI._specProfileSwitching = true
                    local fontWillChange = EllesmereUI.ProfileChangesFont(db.profiles[targetProfile])
                    EllesmereUI.SwitchProfile(targetProfile)
                    EllesmereUI.RefreshAllAddons()
                    if not isFirstLogin and fontWillChange then
                        EllesmereUI:ShowConfirmPopup({
                            title       = "Reload Required",
                            message     = "Font changed. A UI reload is needed to apply the new font.",
                            confirmText = "Reload Now",
                            cancelText  = "Later",
                            onConfirm   = function() ReloadUI() end,
                        })
                    end
                end
                if isFirstLogin then
                    -- Defer two frames: one frame lets child addon OnEnable
                    -- callbacks run, a second frame lets any deferred
                    -- registrations inside OnEnable (e.g. SetupOptionsPanel)
                    -- complete before SwitchProfile tries to rebuild frames.
                    C_Timer.After(0, function()
                        C_Timer.After(0, doSwitch)
                    end)
                else
                    doSwitch()
                end
            elseif isFirstLogin or charChanged then
                -- activeProfile already matches the target. If the pre-seed
                -- already injected the correct data into each child SV, the
                -- addons built with the right values and no further action is
                -- needed. Only call SwitchProfile if the pre-seed did not run
                -- (e.g. first session after update, no lastSpecByChar entry).
                if not EllesmereUI._preSeedComplete then
                    C_Timer.After(0, function()
                        C_Timer.After(0, function()
                            EllesmereUI.SwitchProfile(targetProfile)
                        end)
                    end)
                end
            end
        elseif charChanged then
            -- No spec assignment for this character and character changed
            -- (alt swap). If the current activeProfile is spec-assigned
            -- (left over from the previous character), switch to the last
            -- non-spec profile so this character doesn't inherit another
            -- character's spec layout. Skip on plain /reload (same char)
            -- to respect the user's intentional profile choice.
            local current = db.activeProfile or "Default"
            local currentIsSpecAssigned = false
            if db.specProfiles then
                for _, pName in pairs(db.specProfiles) do
                    if pName == current then currentIsSpecAssigned = true; break end
                end
            end
            if currentIsSpecAssigned then
                -- Find the best fallback: lastNonSpecProfile, or any profile
                -- that isn't spec-assigned, or Default as last resort.
                local fallback = db.lastNonSpecProfile
                if not fallback or not db.profiles[fallback] then
                    -- Walk profileOrder to find first non-spec-assigned profile
                    local specAssignedSet = {}
                    if db.specProfiles then
                        for _, pName in pairs(db.specProfiles) do
                            specAssignedSet[pName] = true
                        end
                    end
                    for _, pName in ipairs(db.profileOrder or {}) do
                        if not specAssignedSet[pName] and db.profiles[pName] then
                            fallback = pName
                            break
                        end
                    end
                end
                fallback = fallback or "Default"
                if fallback ~= current and db.profiles[fallback] then
                    C_Timer.After(0, function()
                        C_Timer.After(0, function()
                            EllesmereUI.SwitchProfile(fallback)
                        end)
                    end)
                end
            end
        end
    end)
end

-------------------------------------------------------------------------------
--  Popular Presets & Weekly Spotlight
--  Hardcoded profile strings that ship with the addon.
--  To add a new preset: add an entry to POPULAR_PRESETS with name + string.
--  To update the weekly spotlight: change WEEKLY_SPOTLIGHT.
-------------------------------------------------------------------------------
EllesmereUI.POPULAR_PRESETS = {
    { name = "EllesmereUI (2k)", description = "The default EllesmereUI look", exportString = "!EUI_S3x6YTTvYc)QmVawfX(Y8ljl7e9fBlnsYzsMAQsfejKeUccGdiOLvsDF3)6LZkWbKul2tsUYvLyAqWZsF69UpD)7)0QW87k7lGpKMxUU6S5f1LnZ2lo8V)tRsYxnVRSS5hB8cdNz8G)zJFu8S)()l(R7Fyzj8xxTUUg)fFPSBvvBtta86H5lkOH2ZpFDtD78B)qXdTR7HNKKx0m)M2Uv43gK3x0DDz)Blw1Fzrh8OyXtuFa)fTxD1QY(FfwDPbM)HMPvvlkH3(GJp)8J)O(T)LgAz6hM)2d)4fZxVQV9Ul8MDHFuw6SWWlY8mNnyLqVwBB9I27BwzoRVjEpVzbrErX(rLVzwKEwdYp)4tmNY3ehHtQNhnAR7RQR6F4BW84fNSx0m4pbjHbz(4CgKVSeHVgaWL1fpu2zTviiyOFyAA8S4KeVndbJJ3lg(tuCywOxOhT18fhq8b3oDIf5fhgKMoZFw6gGD8KLecNoXPjs447o9GlqSJdSXo8sYPVPUy1Qtlx1UUBEP1g1ZJw6bXEHzZsZ28(8nZ2l0loklkmknlfwR0oDakH1X42M(PXuhHZqOPX58HL5KKK)XIQgyJBTXIWLQ8izwSEJfM)H39(ZTWgbKeXz2vTafGdQSOC6BSiY2bQkjs2Zy5gLF6r)WpATEt3diU9J8YIc88PvEw(z9a7IYbN(sO1iEdHPrz(E((bzgaMXuPPb4mfa00zrzjz8mH4tN0EV9zW2WZEcCKaMdemFmbKRddIJxwyqCAyAw0MOFIMThWqWlYpknjndiwrC4z53xTO)Mpw0p)gMDSjMWk1moezFL7nUbuAI3a2DgKSoFjMb5nLvxFtpVWyQTL3u0amPpODDZIv)oU8JZlwSOTbfv4dJBDD5Q7k7k)8r7pVhe1ayfKuKK8fvRkUSU89TD3DsX1vnx)E6XlxV6MYfVL49)226wK8YdK)GS98YVeL2ndf35LFnjBbzt4L3bFoljGOCIYxDt79hux9B)2rZHzKg4mXa)5vLediAOHVW3xUqo72h6QwaRd1Qbw)3acQqsq4X73uDxbUfwbea4wVRD(pu3EVErkxedxCYfnkAZhgYRVPgHJJwkZYbPIf9R7k6lpU5Tc5A4ImkxkL7DlUUC4p0dOTiO2bTDlk7oR63kBiquC(LAOW(14Hfbg9Zbb3N0UQI2oKAfW5sabPFO5nG(d7b8RIt8sI8ZqDdsZ7kRpPTQPhoFF77(05V70Fcqexo4jE5FTXlGyjeegenlknMv7ag9yXONedm4ECJii6Nit89NLmJpJbE5FTVRqGtTUVVTrU6J5fV4pjpU5YpLLbX)jrT69FrGnVXbWbiR(5YBQMxx(UVwHYM5JGeudUhdypXITMAHNkhXGSiIVK8C5rn6W6H1DXlBwsqiX9LovJKdpOH5E(WRetQDHCYFelEH40tlxYcnqqqK3Jecqdsu(VCIEma1im1(8jSOasL31mh4U1x2zmUEmSu8NNW4saVeXw1ptGXolywAks5UfyNuVzKE7nbJj4uAHipD8NbQGKLb6jLe65J8a24mivlHgFV0S9sGtwwkfD0d4S)J1LRlbb99Rj25ioBWm5(GPD262qYiHMgFpt6wIYZwtcbDbRgGFQFyYSTohwBKWagBWZpln1N0xmo)KsHAQ0WhM8miseMybhSHkQcpe294GeWWGG4mTGIHS11YEydajE6jwIiEAsoZYxVQKeCw0T4qWAquAnk9m2AWjbm(7rtRx(Q)Z6IUsusljymo)UwyuAbtlpdedVFDnoa(kXLNdwGcM5rVPXSDw)dGUa8awwxoVhKMbtUbkGH2bNx(vqkzjnu(e0TcM()vB7DnrK0fqYTu8SdPSkjWpdTmcrrO2Io9bGeWO4yPHV4Emi)ss40jGsrGoe0Q1lm)lvR(rqZIp1(UMY7EG32SUL)tu1pg(asPPF7psAD14Zg2zixljVz9DN2E)kgda0oIK)78SxQXKuBjImom)2YhUSQzbVMrZVj9NeQMDoObsF1sedijVSb1wBbEeNM3Ug2MNw0CDjnzcL3ILd37BB61RIlf6UDT4V7G)gN908Bamf43IGI3XdpRdOuzh8CE7JtsEr99fpScr3oGGyeoRck)rI9nn0rAi)5e4gFyq(DfZ7AXfnHz7rhsXGkpO7rim7Jr4k)Ux31E)HvDagkQ7eqyuIYgqCq4WGOcedqM124xzqmdHbTCjnE3VdgSvNIhV8kwTq2(UEWz3Vkp7wDtXYsdogipsyZGQeZk2YtkdnyeMZb1pUTPC1k0br3u1iodU7YIEeMAC0aOyea(mCsG3UPTbmHhw4eM)UDSdKj1W8D(nDTRV(gM5aFac4blkBqmmPdleO(c0YbyDetwu3A20a0Ca(tOE4S7a8P9nGOElEYW2byIC9lMNkrMOVgycSva)etPWibQTRfcJG8Z08cczgbK244j5xETjz6mIRfTBCsOotCsXtN8evDqV7u8a)i(iN5Gc6lTQTUAbHIGSSblGk)KepMOdsbqOAIeOc4ruK57RycLbBml8fG5aqGW2nbw2Ed8V)nGqROMMsLOcJFJptfyXgvl)zavAaD28r8hGBj2YmGZ8pxTQ6sYtEWwSbjKjSbdg0cMDsmAMV7yESWpYy5i(rXiBKJBQF4OMvKVoqYPrcH0CG(rMph8sGLAeriz(mqVRevUSSCbIat4bYtjdWTX7knKZYYQVXcFcX11RYBe2EosEdI39Q8gI70F6K3WsGyTVEvEdzedWOMft8nuEJB5htkUzkjaBuGtkgGR(kWiPhL0MHsqIf6NqCMhjVXLufxcnSL0qmuDj0LC7b8fpjjmaFOxyjmJn13wBn26qxYXLA(mqfs3kezkl0YrLd1vCdNnBqC6ukT72gePGvY3z)xqWQdKS)YAP2Rsov8z)tNKZxTuJS60YLkFhKC6WsnwOXFSnv7X7EQNJLCS81)qB8MrSk(MitnIJJCt4mc7y3KCoPWx2XFU9yNx(aZ8)XJp9O)1XF689)WgmZnwep5gVrE2Cs)SXo1zyizEMGVn5iYX(UzAZ2h7zl3wTBg1bLvJAFe8s604aorWE1pXaEJd)e)Q2h)5v7JxTB)vTpErDuSHz(Um6Z2(DIXQtpk7qNJXUg2P99VWMUt5yaL4kFJTH91itoreoFnYKCkGZrv(1it(AKjNoeNVgzszQJ8xNitszh4lSWhBh()xutBMi4iVAbZFQKNeMFXQIVqjY2gJPXy3x8A8i)U7v1bQ3BLGVykWpP3vDKSgp2myBK)Z2sAYWoEFCAYm0fFz6aZ5o2LtMxnUcQPl)otPi0ZWlRdYXXGrG9DZMixErBKV3ezz(bfxlYK7NPBd)tuKmPes(vbXO2NYKfuMQGBoxuFvqmLpLmq6pTPC6RcI5SQ(pfjI6RcIntd9)YkiwFdO(2jxIUPYwX(6pnPwZFaf84N)5tE9Eo869CqEnJ(Z59CWw8s0gtCMhRDCdSMHhCBJ7EIPK6KgQ9ToRACy03F8ZSMPUE4ptd((ENNiP5FSAEx7)xYA1bx53Dr1aYqUN4vQ08Y(t3y5)SQUWJLt1)n9KSQkY86vM8f6kt(h7uHHVuE)f8kt(94kS80VZKBiFpF8knSRxYfhQlqopFW1SCeF3N6fE5L)kvAv7m2f5ppJR0FODPO6Pl)jo)YRpPyXZ5c8Z1Ubr9ay3Uj3tPp0FaTD9vzoKssVGxt)VDYCqmXV3xt)r1mmCrmraECWJJkcztuTTES31Fh5mon4gPp1lZ993XnmCYGCUTiuoSsUaGVb3mZD)Y(VbbxVGMbV9IbWyUZoJ05WypcB9X575Ju)8DlQNJVRrdJfnvIJ0LvRNP9VUPh(l51mblvFZ0vGPHfCiViv9fsw5k4I7Nr9o8Jp0Ft18ZRUJQoLYsWs96vNFFl9uKdAAE7L)pyTK5lLdl2nZ2JlTHyDnXOihsrId4gSSUQ)SAS2xAwRyMThFXNOFL4JIW3b0JfDIl4owtkbXbyXr5y58lQEt0a)(Iv9JgyX4QRXkHIYHqjveJA7MxU6K59N0UAvu(h2)G3Hx(NGC6BpOyWYKwb0QmIxWyrBjqw6tXfgvAKGFhFXJSwQi4dxUwvLipUg30v(LQY756iupcMpHb5UQOoyzIrn3ca7IYI(BWj4OMZR65AsLyKE3xxw1vUWgEtQ)rBe(turGuulAPXALXaHeGvx3SFDnEAdGjr9ufolu4bRmQPm8(MWwoORS4wSohZcEvV(puSKl2JZYVQR4UszHmb99OVhd95ZgCkXQTzrpvNCp(ZF68lo5DNIvHncBOh3UFEv5(ZXAAKgStaWB6klnWAji7ry188dLx1lk9kGquZ6rMcDdGBfnlkx04lUiAyrtzrrDBtjGSaehaJfQkk9lnPPKkXYcklPrm)D)k8Rt2Z3UoqMLxC1vvF1aInJGy8waRCMirmwDPuqHpuCzznU5y8L9XFpv)waiGjImGfNL)5pD47o9Id2)ucjqIjBbJcZzmMbLQkazMm8HWmeFKqnO6xPpt795LZBVRQ56ZqAoUGujkmtAieN5ysaNKUqaXHTNcr4TT3TSOR8JTlWkZ0No(tVdLb3xn)wDYN5Z65GVADzF5IpwvxxTQCEBZcI8hFFjjdEIpG1IBoa4pcWC4dbSYpcZYWv1HL19fyfZbb08z0HeXbpRxwUQxXiIGguvfmkpkknh2KzVXB2B8ct(9MOaQKIgaFd(VY8(7nEEaEvJxusc8)tYIH)FaaX5sbRFqwomb6biindEHzXH4lhcmZAIGpfgj)b0m6zoJz4Rc)HlyGHZ8Z98)DyiagxnXZGrZpYhhIWu4)7Zfn0aCI)9MGi4RZsWbi2h)60mC2cGNqdgSjGTNEFGVsCiUBYG9j8IWUH3h4BATpI9XxyYToo2WohHrWQZawKAcl24YdHXPmexT)XNf)7nPZW1ia)GDhiLbGKEiiiiruvfHxcwTt)EWzGCBfBF(M6fGqXay8ZYWXmHoCfJSaqyJriWbMg2rhzM7BpFFyOtWdq)eC(sHtxaYdpqGBbRDnCJHKMOekqkVrn(QPGm8ooarFaWIpmDHzi(Akc9MLsGtpc1bp5qGc8ABewaVdIBdNqBdlZl2JFVu4Kmje3WZMbhD(ZGzeqC56MmoViQpInAHXZKq4pFduoccdCvV5nhFya0pB8mqSyqsdjbpSl22waqp49Qf9(220iH1V3Sf6jyOzkFJHEZSaK)cj3R4ndBOtGU27r55iturTRJL9ZAbfK3dmLbEN1l0s88dSz2s81T5BRfenuDNzm)Esqood4)gyLV1QpykQlPqtdpUNnyvRV)eOiYY6I(srhJ4MIv38HQMTpW4EeKKck22tLfremCtzrD)nFA9DxsvXnV8(2L4lWLHucwLikr6yXOux004A79YYASmDdcTX6fQSUFBun85IiivN2ffvCT62HahswZ(5Cdn4ZnvO2iDRx2xDzDPQge6sTBsdCMpxnOLeUMTk4GGGZ2LD42C0xfiNpHc7aHkV1faNZBxcc3jfsqynPOtX6UIdXIhEvBdQFaJJGQRdl)Q7w22bQDrTTdeECgvX5iudq92wqFaEf(daoiixoKwYyvE(Q2gqt1O8JW99vfZl)37VyXXnR(3g268VVRCrvX)ME1)nOUhGLU6(Ih278ZrDWcantRkBwutRvulaz1W8nSgHYIFQOC2Y1RaS8aGh8iQPOAfAuWj7kQw8XIUBf1OkFsfypgQDTqNj2SjV8gywTQ)MP2izBfDhqUhcC36VbyczCyzEUdJ2Cm3jOgxWWsqlIkAqVYv6EzcycQ9F1vNx0C7(xFDxRc3lLRyPKQMjXA7Z8s5QGjOAptXmQiKcALFxfvf7z0bA6WSy4QRWcMjtHrpmmxH3FAzXcSbPW0n6PgSEJxSGwUKkh4gfopek2(RTRnQNHzwBfdA2z5)N1G2GFS9sceRlmK(XJrIvvUugrgiQ10hB9eYfvbYKAfiE0GPYXFPSRU4bjoLaeDtv)LTFLqy)fuCk(dyIwIJnt7r2GnZ40(D3TS)b31Mzx2rYkUbdRcDbnUoo)Y2((27ikx8OIMrv58xrndFFkH3EwFX8B3TAPRO5sGmjKCE49gmt0K6GtLMuexDaAVGPgT0jwuh1awCCzbxD7Pk2AaXpJRzRIpRRARubiwW2MQl0CztoXEZOzVPrWTyVcydgSx14YWjILmgRFeEZBAU9hlwztIfRpEs125pJyVdO5YX7TSPQMvv2y(0RAUIULl9UgSCniZGPxGbJ2vRRWUS8hK9PgZc226ZedHHmAir)QnhhK1igyEnUvQdyjkNYrv0AaLBNQmZZmoi5D9C2HyUqwHJfPyItqvhSGI8Ec3)BFHNyqVmSa)IfEy4)myejveGklYAagmiQoyeJZQ9gNKPmWT10dy4QZwURJsYnosZOunHX(LFgX(XpJe8MBGdSQtW6MGYmbAingMOKWNzpekbMJC9wi1sNeQ6Oyzh4XUZdWmbcGp0IfSwBAapneirtdKY3nanRxeXvJKcAkcCOqUgkvkWRcE1IY9botYJhA4agLZTL6mIYY84mn)UQMQlbwok2kzuZtq4noWohP4OipsqOTGxv6lI(GyipblKpaTvXa2GKkkxQw7jLDO)MA4IcbXbCkf(myUyvYZT4izrJtEPQU(WseqsUhYpN8NMqYn7OoU(LkKvTvAeGPe5HxnKlw724iTge(bYtxNQPMK3uUUVROwZyFt4ib53kO)26ceSPg33VxO3iWq4HYoYzrGo9lx9PYIUDh5efbR0dr39FeaoTgdwh6AgMicT1xXoVJgisho2r(McBekrhLtGnI8qPAGvT2Nlq5O4weZ3EfXmQnWfmveantuuN6r1BjJT2W63KWbdiPPgYyZsWeFswn4L9vcZVCGHL(6JBPPLc3K1xSCz5cfEHb2LMQKyCKLVGWSNwjg2DHCjThjvDzmdPLaI3MKFt7Q(kdlZMPxJKXqIqni9rVL2MAZ5OU2HGhPrek8Iyw0b8jR2muKXJpySKaHfl6PhwEvX6AsOLW)YkdAytNjtx1CrSBbcke2bfc9HMsXbQwHdWCaw(ZnECXWpL5DXM9kwCo4yyPDl3TaKV9No5T0YhBAbAUoSIY0HU262b2xO5Ak)crUAYN4AE9caHbrQQXFn1f2ZuFuRPLnv7SLfZv9BdlgYdvotQXUfyg7sxk97)vP(9X0qJI4DQSni5uZlXGSfui3qNUTZ6lGa)uiloreqGm2)gc27sZHrhP33vb0zV5l(WbbyNNLoEA1hf(hzxfpaSRmik3(koBGDEdAjAHEEjXHjZIstzJjz9(bf)9JcZM5Lfl0iHmnW(XSZxg59IbZqwMxCmyUBKh6oAfHBQFsKVxqqAIFkRnaodHZ89IdJcc9ZcHhZwiRypV9DlQHekSLmBgz8G(yOu2O7wxXe1sFxmWboGWRHgxOwVs7NjwOgEn5hDowSgQSX1wYuqVP0C7NAhiGuRZPVu7nw4oQ3LwVvr6SPhBnMmFmB5KgG9c8ibELbdmghgLRr81zooSHqxvnNCrfPtOPXQj5DfDLVRUQN65kSfnC9l0SBzqijAZXeFe1Fg(iUFaoaxUQT7s(Sbuav0qJm0tAGRfqhhrGGTE4d4IsgWQtfMzUhFBpgA1KQJrOKxmGbefGx6qu3ywypWm4mb7oGkDPdq1nOPBfACpWQZYKgga826YIgMZUSCLjvl1WKZehUvb9f9850jKwhgB3vATnCLjk8Qv(Acl4nfHWM2lADrSJ7SvVWvFDHPnal4n13DK)btyWIqkGjgRWbhkb9tzyptAy6jITGBGVEQz(FWYp5WBZ4mKHkoR8BoV)cgQzk7UwaRhq1MFGchmkbevjAFceMrTalgLht1k4lAStqcmmT1Lsb9SZ64WbFA51a9OCoKJlpla3HVO7LkwLiVcki7eyb1mpaOspfTgvmYA9oinGO01GxXhix)c1qX1VvUdmcDs(lHXhExCMGXaMjAQgOFidJ45qeKFG9ynOVcYfYzhGAgP)eTtGD9EK50a)3I19TyMeSSNplpQ5laVjsziJFbUsIyZNCxgken7lJ2qLp25ZePzrXLcyhoZeSJ3a8w1CIqGBAmjhlahaR(ykm3xvi6WQnnGTsVh7ICWMWWl9YMUSOhSA6IJSCG3mWRE(TkaGiauFq8CQd3Gwz0m)b8Dyv)9ZVE(cQ7Vw0rpMDfru(1DflWo)JbBjGOe5112xuRctXWH4uHs8MO2WwtmVAbmazCvDnbr8IItJ9tcJMLrQJIvHxPgVux)crxeiZwlxjAi3BZzg1wzueieBjix32NozQTgUDJt8MfmlooywOOT0Ys(ot(dPSbuS8LuQsyd)Vfzg2BbU0nL14rasRWBqe3kqPKusk5td9z1(OBPquMmrhBNtNgSvgIBMhFh4KIgOesWNbUGCQ5fqe5euA(TyWyid0Xyik(NYttgc)RnVjcv)tWOGw2Q0BAe7bnCMbcHzjbPbEEHjuhPfT6GrgrtTOuBYEUpqWwKpnGfhhb1jA)vXCGqf1QWDJ)JG3J8KwiPh4gjFIA0uaKFqGEJ6PJTFlzaTqqccujD0yMY)WBpusxb7mrI5O95Tg8iicsdcssa1GdIjRPmofKdSgVHpx4Klt0y0KzX5W2WjhadKZy5I3D3s0DhN1xCnXfupGmPKcrhpXi(dmwSaphu7xWu4WQoCfAwLW1fdCU9bB1BvfN00oLeCXJlsagMLoliZxWeafANKFDjWaKDk1MRm5W5So4IP5f9DTZR6FahdBMckeymsp0CSSR6oGLhohBKRVDlEeo2h6wBDJUMywzlvpbJsMUZmksXr2BJukwdSDV98BkVdttrrahvrEYIxghZdr6)PIJk8uzgfW4eiEJ8jIJTaz7GCbWuBoWFbt9P)(5)uJFC2F)Cayizvj83qjLTFhD1NALYBiuL1n1TZV95XGYw1efkJngdYDqc3KSCO8vqNgCkvvmAOMChR1vx8YwTLP0GyqdtAcnwgpHaNhjaxlRuXpqOGJ6viklwOHR03FJO7c5G7bIRg0irrphOYSe6qMTlu9qsGpr3XTuaNCjuV9jfD9vf1Y09ZxpoNmx6K8j5eBYYqjLNvLdXGTcOZe6Mk5oiCfjBk(3vk1PjmzFukAMQcrwVqeMdjfno)KOntqaz3oRhqafZnK6)7sanTKBlsfLLb7mkUBJBEI0rttEGXhBazU4cujFQM0WjPTtYI9Yiz9oPmCq7kLzYP5iO8fL4VcPyo5dn19QFGCSye74asdgUproq99bmxyZGDW2dVSRfRUHmetQ1cy1aWr6Odx97nGrwd4ljerz8ZuIXWb6NlQxxUA1SCC3Ipq4QMbc6qQJuWacFq)AVzus3oM9xm7OsuhCrglmw4PbB03InexoRumwDS(FO7luh728knExubwQtGBBqZgf7BXDrOm(wfWpGpXiiHTsiAdt4M8)8BqpXSa1nle5umws)B8cnVVVBTPThNB2y4TVISCEDlUweCdFDipncvu6Iew9jqnGa02qhCX4tewHa7kjH2EDBfaei7chmmlFz1sz0geMZ5S19bVMmHjTB09tQbj8lo2U75A1wDg7ZTbcShHXYChzCeMcv5KbNSbvhUsdxHvKSzKl8Us36MYvNvHxNasdub2aplQ)jQ(qcPEfBwIbDPK99wOlCtznDndh7E(lkPOZE0vg6Hko849DAEB7CTwHtWILubZblwxEssBxsgt7gA6)L)r7hawFX5Zx3TQLI9UFELOdclvwYvxK1vXnX9SBC)Bg7IOG8Bk)km9ZE7H(zhoPoKHANtrmIz2iO)zFBv3CkWQMkWeNJg1TEf7IzLB8OSglkVG8(Ck71oE6dE)(jVNf(TcTlxR1Bso2j5bB5H3QbVOsyB7CmiAWoJ8WsrFFX8BkxG2JeG(KAQvPVLZgNEv(E6p4wvUMIYRfbZFRljIuWCjfL33vuvZ3YiH)a1n8PbgQ5KwKdIi6ZaaxexsxWqisq(LWCvxcO5tvMxDx(gwiswyJRpvuU8HwXdfZ0mKFXNfEDe2iI(5GYfgwBIHdd7Be8sDdsf1oXW4EYYHM)rxyk4rGgXGrooWQn2Q7T9wwnaNhF8Kp85ZUy)pD4fNU)raDrq(Yb3kT3eMqTOS0GzZI9t5cfK8AP9gFp(oRf6h6fdYz(FjpVALp8FUPQ)94TZJoH4OncYPogJsD)dcpvbZAf1N05trkIVye0Gx8z4upaMsJehWeJbYl)R0PseSDRA6bAoPyxh(nK1dHhJN9ifNVKYNNNZIjqSyE(aiZic9qZB8t9jLyFcop9zdHntvybW5n(uiqFSRgKGvKyCp04NA2G944a)1MOSeAJURN)azXZa)HZrWrz0VPt3iQ)vRKktrcnmrv25iNb0Elkz5bN02HCE7p7MILySGXlbb(Vj0z5)4mqvbD2jA(CGTcPOtOaJvGTXo2nJUIeORNfU(fuhP)skQmOtvfpKdAoqdRdxd5OpmsXKV)EFvD9G4EooZiOu73iqhZ05GQhf5dHtq5SAkJZojkI2wvProuzh1CAr1coXHOi6JoSwNBXeNyoHBLXPr4jBpbtpJ9Sd9v8Xu6Yg8ZjVLIDhNs5GcSa4sCXFfPkVja8dTCIcOpAIfr2FuGTdeXg3kpi40yItDW9PaId46GcmfnMNDQTMon2fpsEZJeQ8g6QLaWi0wPeKzaZz(CcSgzMGiUpfwqEXuI6iHd4HvRWFkSZVST)gByf)QP53v81dWmcLV0gGAyQJ82MEaQQ)X2NLQmsGCM)PLFPSBvjIeIiLXaoDbCuDuZcmnnWG28YCjga7KWPJnbIo(b1wKh)wiPGrA9xI5CPyHcsljCKbPdbwrPU6Qbh4kykNrfIrWxGDSpfgkDwrzJ1OIwJX1O3lDOLRiwlmVQBjfgJyogjscjEQ3AMKG5thcrWlLgM)mDatOFhvFvMOmKXlQentMWhCIKYHxKMif(RgCmvuSmzalPfZKhV0f0qDSZjsGiXNj2W4QrfIlfUMAQuprZ2BWisPZJW31cwIJz9fhyKrPgjzEmFT5X8sZfNfsbqr)ZMJrfs5RItcYRf5dsrkzyosahe2PZ7bfug9oGNpVVacY(lvLzl4Z0Tu8TkkUM2MsK7Iu0Ich(g49i7hm6emOIM4zmVo1uAk0DBM3VaxlaqYigfgDQlFElPwkxpeeETJmzt4leJeFhbXOtu8XA5NfYIcjfS6MyFbs7ucxKIq2obbAnpEfJqcDXzGKYDa5MiLt5m2sYSdtHdIdMjqLkZgQWDnI7gF8a7ObC9CMFNYJlPA6r5xww3Epb6O5uWGN8EiwPISasw6iyKz3eG2hrRo4At7bqReuzyoao0059xQwE6RcMV)W9G19G1eMW37qTP9iJdbRr70XtZ3Dic(gAM0oOrhMY9sYg9cHmyMIupSSejlOPIjBf5HOlvGiwjhmmupiQVesjnwtjWlheIkUyfIl9harvsLgqvJ33kwY0iKom1fL3hvJSGeptynenmXwKwxQC3K9VcD(BRg403iqojdhi6o0ynWP3hLomK4uMlLPQGWX0ae0X3evz(3jZAEoN4qYaHs1IeSu6PdYbR4T9rXQNKXttUINPbhf6NljoP0mWIIHZSm0DzOAYsQeA0mDHaLZZuqVraMM1RaBGpqLkLZViLS(SwryrQbK8(pVPS5OgmbQ(cXm0wvEEOeCw(1M3qACbgtyQDNi0cPIOGlp4Ta6AWHGzpYFZL8mCjyZiJw4KSXubtwt7je8VzStJlg5y)PCjR8fMb20F3b)nNPJelcGrJTw6B7YklhmrIFjVQYw36vB6FtXywPPpRVoQSSz6HLYsS4JkdXvjcWWiQaLK2TY0WzMBaGefPSwdutoXkTGe5JRb2oDrv0xtluKKIxT8g1Jk(AkNtAwGiuEAMUcey2BrkB0uQVBAFMXTnqCqAuSNGNu2TeZw4ejdmB2G8LqsAQmJ(BkWqmLmhA2EkJBSKsFDX6vnj2AVmTV6DMsMJypjgDroOR1)1aBNKIQi1n1ZxPDQbFywTp92bqVyZY1N)7JfRlDgq7Nmb5QfFBxKxa32HALm8iqYuLQFt(5(liUP9xAyXeWXIyfouqX2UpPOJkSmQJHcCPfAtSZvU8bon0kLISL5a8mPpu2z(od9HIzomjUjckoP48kcsN2hngGluNl7vjhCp7kJM3mRikYE35rWZyOwGg1KcRvQacXxokNAQooaEonINnPydS9hXXWMEMVDItips(4PDWJ0r3d2c8IAGls8fPR0qJbNPDoHQBqB4UckTRfba04e0YZvcVQOUKgkWR94iWpM0byBQldpa5rmugoT0YMzGzkBSZabqpvIuw8GA)HaerW)fUp04kXnBVishg(IuHLTkHO8984BXTz1TXv6jMK32u)aZ7tFXI3OkrpjNQQ9fMdVQ(m9F6KNXo162TYfFh8YPlPBG2rB2rN2xlyKc2Lhonm6rdl)g6pZbAI8n1NLtyrLqo6U51sGX)FyC6ifls07gCzvAW553BFp(S8IiNfYsnYjlvuX1XIf5J3RH86c1eBuqrSs)kDfsshhK4rzc(3e3f(n3dGUlAionAtBcBjAvmyy7EE6mFe9h6MClKi6p)rYbDUCSXZ27CCTZrxW6ccmVHbiG1H)7yhaSl(Pd01DkpY94962t17zyqdEuomZm8l2MI4YlxS2Eo8C1qtuMWBtpwhC9C8X0q7rDg9lYuXbUsAdo1uwVhg4kVP8TKTVmz(LA)roWpsBkmLtR4UC5VdosYmQTkbngo(uwd(eo30WG6rrODs3enDKKhzrhZJxY1XQ8MmXLZAlEmXryl2D75Eg20pZ0CtlJvC4dj1T32L3I46AJBVf50vmt5BWDofjKhKpx3ezQg7M9)ZeUTCK)AD7URHjUWerYb7Bi2Hh1QkXnSOrkUVOoC9YMCd0uw(nH7N2QVF2uih2O13pvtn3O)Gad1iZc5OlJzHKBJfL(N2wv8HbaWDMZiYUeD)iGTMDCi9hWQCNcyph9TPdc4e2TVj35VvIxRajX8tNmxvm3LktOyxjBLndt5NFhYlu(GYfZcqfWP1dzkgjdZ9fY50UIx9W8qbON3uoV4Wp6ILWGi2pzMW8yIwVi0(J8XRd992KBZDgj2ntw))sPkGif8CqaH1XQngaQD0JRAhS46Wz3nLWHVyKrhtAAbNZotKmBd8E12CdhN3z7ULhtQZWuU8DQehWTBG2GtAD6HiNXFD60dWryMDGbUB(8zJuZM6D4oj2cgzHikPtN5ykxXksszvyNe6zUL4ySdzLgfnQBWOrn0Cc2nxMigQCMyfDdteEQKs4F74m7WtpCEA5iVgghGhvK5EubcyiCtEP6TJh92fQ5WXVt7XESsfPIXHkc3tL2BUuSzCoCIXQDIuoYzYUnTraoLppIevDrRCQo2M0GZQf34flsnxxHDzcH8UJIWtj79ESQ4Zi3tzGZlR)4MwZbtfb0zuWog)3nPl6q)p)4D9Ndh(YzbXtmxbbOTDU0Qz84wJJnPbWGmiDOZCDBZY0jx9MZrn3otfzn(KI(7JZZq8LihVWitDH5FcAZ8xYyhnr(w9h2CKF30V45ftjhQxSBbnstCA4ZPDot31)6hvyJ(du4HmSGZ0uqNXfIL79ILh6VSYE(UelO)lKL4FZd7Zg0cBuyEScGHS)AZfdqDYB)yTX6BF6x)inBAyCB4Bn03Ky1mmMbtz8WFvdpZZjElCYRpowkUY5UPcyYgun2zQEnWVGoZGWjZ5PhrOt2qRi2PLQuSaTZbx7ybnvA2kkuLgjTUdd9EuMNUXWkTHuq9PhqKnKruJUkHJIk0tXEQDpAho8aZePP6KEAAkJQEe5uRJGL8it8)DoVkDNbVt5T3nz6ZWiVSb7ZhflNPTaAdzz7qppjUJoBYl2FlI8Yt1CRPTsMZlV2(t4WQSJE4v5CQD(S)fnNANiz62TeTLLxRFxL)8y)qiVivkLF3GFyh4Lmr6FUPeMDC616GL6uu1ti8qutCLPkpFJzDM3OdDiYguV7LidBFuIgMWJVBplDFIjD7KoJ7B2fGFtEA7f29kUZBx7cai1h0kUSUCHQiGWrh6CDfoGR5VOJxOhYfzd(E9yu)oefnoJ6Wbv9OxcVkNTWJC5lETzTQl5yFxcVJkNwExvdyYa5OhG0OTz167WfjxYYfly4Z(5u17gg8I1xFxzt)fyvFIQ8w9y)N4w(ZCLmcxYapdUegFpwyO573wvZTpCXL1yJOdFH7XxGl(dlXUKpoanRV7sS()qlNYIU(BQR(c)aaYuxSc)P4naUyrnEV(sZVh2axTUd)hyFQSvmxf3TSU6Qh4FAAExvF5ffl(FeaZ6I7k7BBUEnUSXKig(2vfn4Aae9CFzXY2MlkBMFdVza5DDvlHbegnUIoHBLdWDY)QTruD5e9ZBSaPwvuV6tTnhjQRt4scJztx5vLDDLl(N04)oE4fvq3lwVQCXGsGoCMk)jVh2y2VjgZg4iquLaORarC(Dp0dqsAfQ)PiuZ83sLlOHLIv)ONt9zt2c8kQbudjsLQbFsDfHeQpWvxGLlxFoDO(mI6jdaiwok47FzA(11T3J3jErDk7Rg9sVK8wJcMts(dIVZNSmu2t1nh4dx3CDzBtteEZ5gQZj)VFp2ZsbeuDxlLW)OYkKOjYiZobQWaCwFxrFbaV)47o8Op)reEIl5bngPekG5Ch5u8zrt80Sq3Bvh7W68hvyW2NQLvSZV7KePg1rDh1Im(rAGoDriXhTdnTaSDMyE0T63j6FQkwF0HnHXzHuXzkJFevm)bgA7)3()TEv)F70Y7l6aKxrLa)tT9FQSCbvHtex6EySoz)pS)Hh9jCm(nGMHgIFh)jNFt5F7NBRwSAzvxjvy)UaZcQZynKg89NtfwjGIfWwOlzhRffInzsWrfTltUxfvepYv3I8jalqHFWAKYok)M746cEy(DT93ZFBxBZVHCgqgkDexvRwtaN(bh3FdW48JvRWUKh)oyRbcxrwV94vhXPtV6GLv7DexMfLFP9cQ)crPCd2r8BV)I7lFOd4KaanApCz7vI)UMzRU6MIfT3dRuCqWk0u1DLah8viJjMH2Ly59O72lqMZZP72km41vy3FdRIyufJdFv449bG)BBpXngg6fLxj)rCfTYQxc8pWM065DaxqUoo5ZTTvJN406SywygvjVtSR3I6kLn2UDNFtv5xkrPnyVRQUyjWIKRkdi8h58sRaAtcNjLZjm9pRARce6d3Hk(r6YVrVzg1thoFDhWF(SBQUQ)SBRwIFrq(fZlwI1xTfhlatmFQZBxIT6kEQVVTRg7T26LtaHqB(ivvPoK7jeJAP2iFajVHm(Juxjs17hBXyD3dBxGZKv6Rnx(n2D)i(wxb8A0dwavPub2lc4IrFnJ6ctbr(avT(cMNPRGqIomH8I8MIDxC75t08hjEB8qGRF4JS4r6wv2v(G55dmgL0DRwVNeoXwFEWyDol(DYkYg2yd8SsY9hzXenjLUTZ6oqGR69TUFry2P84ttxEAc7Da9uhhboePZaUc()prSfnuiIPqCHotV0r9L3riPKOFSlbRqZmRTEIsCmmnI5veoDaDTCUg8sEfoeiIR)If6jqcGvgZde9ejb9kX6JOmPk9n3bi9WJ(biHWSCBvJbffDR9z8vQpneIsAbfE09ofax4lav4hxx3JmIHZyJ(QIAEztlKfq5azdvMGS61G4kHoQckc014v1LyxiQuocOdUFyQmJvQ6EHQw7idjX2oGpNWJdDHmaLZaB8t6AVg7T5yhubehbJQLQ1FSQP6UILK8tS5KYF2DTAhniKJNBpv)cnkBeUQ3NOloAuwmt1N9yqrUR7AxVea9R7bzeO4hqliJo(IybXFnZFil)dvxE4byfkZB2fhS(6ZaE4nmXlyOgGB82UIR6bzdhJbuyuljGQcgnha)iCUBwqOSyhnVD(TGsVWVNfMGxri8ztWDfm1xuEVKfAY3WfMwaMj68xIkteUK2FXIwShsVeSkapKr2XEIs8AhO(c1tEelcrpoii3ZhRCwzCJlVyEpABJayZfIiSCWXLCrrX2lmLUBWHbraxsHoJDL1NmO(ioUI5H1tVSqo3Q8JYsIJ4lxn2Lokl6)zSpq(UVcAoEuZvy9nbGpfFPCX)QT9ornyeeKVe1IF1)zDrhEzlcuair7RApp7Em0u1NyuRG5Da3dC0rOVlEw2fn5bLdySGtdNCwzJkOSeCoGdPaxJjLn66behhSXjIVgOVIQLSGsivygtuZfqwc4GFmPz2uYbqxd222TayPmVAfCUXfXcSNSvw(X2VGhVeQaiewI1iwU8v73gNJDhvk9UFuuEwT27)ktYWVbXQeil4bKv3cF(pG1pjqTlr6Rzstl6D(SluFlUYfnpkc(AFUcSmrKCfckMr0HuTVG19GMkfYeFPUXNH2oDy1vxvnhWXEGxedBouA5hKICXMSiGLvnOczZhlAkUM1LduCFXDalon7gKWCDFvDvp34)FO5nPC5WBxPvIYp9OF4hrOgqQ4nlzVWm4pXEPruL9clnS86450aJIOC(tocVHl74rzrHrPCRH(rugn92ZpmlnjjZplonHB07sw2xaCobY80zHHxK59eHiH5F4DVxaqEJ3mUeDAZ8GfqCr4f(jbPPPxeg5lMmV4NNj7WUjrCktsn8Y7A7PQT4pwwVSStlnc(ksHbeWoOk5aweSOCvbO1CrpqHZvphz5pb(s7Hu1UmBi(yziwQune8hHYunTDJSb7s4HO9Ot0KD4(YZOsSYgwZ4TzyD)XxDArZ1uD3RUajAiVpDA79RKf(SBlF4YQMfsEGO4ctTWsZfVa1kSyMquHN3WoDwv4ZWgri1nayzuuJjK(3MLEESjUZASnQBXTdTFgaXKb(7d6CmSSRaIPV)qW8AQ5WzvLF1LozsVkX96LQN)c7QSAxJlbd75Inj13KoWO79bRBla2V28ghn8rBZi88qga(H((WFjDxIYegrN8umQwDt3jAdXWYF9sqZ5vR(H3Eil3tKULYgATUeqdYrOT5yTBvNoScPd6SfGGfEmj)4(bqX2AcBoa3(MmXi2Wm2PzH0gDRc3yIjTDqw4TRrFiG1Gkduh7o8Ui3rl6(zNDIrxQlILphMF6iLN1iGwfkknce1g)ev9E9tzZmcPBPgStLInwrntGcQmwoaay3WO5U9POihPxdcRx4(ihQZnrAWUIbXXeDOaBGPQgiXhgdBeIAMsh3irf4ncqm2tejygKRBlSGa67RwQ6nMuHKuA(Fly2YsUGUthNN3A112O(qj3Bje4QkJlg0rOuVGAlp91DKSHgBwUFbu7OQ5wUnqB35jCh9BXfCqC4JkHXomIAole0plh461xnVO2O7saJ(KTbEM3NvdJWKngNJAd65lEGkzANLMKF(Xh)HZp6ecUQXPuncuJonOOrMsQdldmOrDIxaTv9Yke0lGlIovO5AtGOWNL)eZsNolfNvupwXL4f23ztiEX(CyNeO4adBZItMIZW3pHkdrOdaBzmLKi1FXOe8ZL31VJYr0vZo7AuON8aExeC8siNWg9NfhOuzEcHbB4(MpuoXUZoN0IWKgBh4MNK)zw3EsO5g5uARLZqnAMKz(GEk8ZJBUdoXyXuUOzr5DvZ1QzAi)w2Vxmi7nLBzCsnQZ48u5IRAfz0jItM1Bs1ApRn05svyAqkSDIDUSTYAljyKynlnsvvCqhA)IXw2aeZh9dzLR1Fv7n)Vhm0Nsb4hpVDlrdWECN4Upq73FHoLEmMlOJSX2mxWXXWlTndgmFg18TqzNkZg8hxr8)oY73mokHPZMnlWpnmZpiHloqOOb0fCKTkwfw5xkHdCx6h53qXRwCB0EAgw4s(HWBgpEPhGGLPm6JQl1dmmGmFf0Rqz6dj08PiijkNS(3OxWJJI2(a9oYujTjLAmP5r7U8JbcE2I0nxsrid1g02WS00FtoBadaJ0bjsBrgLxA7SHb2YMS0cDO0gHdhjlaFmgbGopEKPqt1Rz1ymIBh8MeA5sYZ)feFyOHQP9adSTJKBSb9ct0DNPZWGGadLUCZUlImCrVNXd6TvZVL4Bn(GWTlfeztahjCo86ISgHdKcz1hModgFJQ(TA60Qn7NHPmZF31nL7Xxt47fhKkkNn8ECP)teCXMGw1iNfopBSd32mfVTLCpE2kY(E(ixd4sPNPnOCedBT3Y3U987wZQx6KcTW7XTlTHcVbTQSqAg0SvqpbTeBn7Mp3x04YKOGwzKXKUEW5eP0g1AriCVYa8zwgYWfSzRfu64nt)Ml653zKtTOTcxVaenekH)5tzOaI)b7gUU4O9gJ00ceWYXZJb1BWdfX65ZQl75sdBdFA()V8UA6TTHHH(xjh3Uj)TJ7PUMT1c0UwSgSd7srAIxAqDTdItagW(ZprszllzPKMbimd4DjyTP2Mwspr(4JIZrujBf9GfUkm5rUfNAvcfOPpH2LwCtGwWrcs)SuCg4xwWduANGNI0dA0xFXmhAZmHPhby)mbZ6tmfQ5cTT8f4y8v5pubKWp5sKms78)Ac9qc)cj6MELd(FAmPc9sxcLUs9a4ozKdMc12yXwDCywfy6JhEHouiSN0jq4Sx8yD7oKccTrhJAtXXr580Ce0VRGVvDhtZTszEu6tJQgrgMoy5vz6QjHe6z9PBUheSGQ(yaQARg9YxLPDBmPCwmUQ52TgRraoMY6B9YSlkReAlz9slNECnTBtseUXNO80tRFPQE)tlxrAyLs2IqRzBQ)k8l)0cON2AXDMM1QSSR3SAvE5KRMXJNPZeP(9JANWF8)eySLeuBbn2IJyMCYu5PHqBpjaD)u6yCVi7LyPbW1ZeE2IxywbO9YUDZVYN84cOSdqetD3JTV1HC(uxEF7NVxtP41a0SX11QPc2fGZhPqCTU47u4ZkGHDPpsXvSojDtIpBHetBaQVlS5tKNR2e0AG7ltKLQ(SCAaBlbzyONXRTxGtbSTr1sxGCrBnMomBLI9ausikRjsouTklLQhP9pl7wzOQfXwH9YxbnlsA(Gk)O68I8LGisxq86jL(rAtPiu)Ns)u)Olkd89s9VOmLfefCbp(2qWp(YGPSG0y(NPEbmVlkdddzX8Vg)t)isC18yQbsUQLj(MVtd31FrjMkwSo)LD5CJSyvhjzgLTgAZ55L7v(H4LR97JQAhcdrqMw7V4Uf)(i)zqkKPcSO5Eq9BFQzYdx0PyNFnLLa6accNxkr5gI7AVxOEe0Ag3QpMqgHuVFOOFHyZ77IOnNgar3Ry8CBKkHh6vkf8gzcGbMaco3ljLLgec3QiKg52dPoJN9TI9ItYUoFx1MAOfGjEZw3Pd4rLFj4gZl0rvOpOrfXJxnn0cIb(TM(xPS2wWPtDLdoPBvqnFyBVN)FvSX58qaRRzzDhRaJdzFiGUhTpzThnJQLTeDlEe689ImZtKiiEeBpeDTi9MiThjAQcuvA8xNuB2fNDtkBugTpP(nS4AWM)dTfoTC4DWExdYkk)hBHXpLEdiVbYz0O(QXBztBSVTOFTbGk53xruq0ehAyTrU4(jnKVJXf1uwzLH0BbScHeD5sBU3sZufVn9AxjoBZoa2467)(n)8(Vn)YBruKTvBpuSyhW630SNlQQwvWVXiog8Wj7EVuV7HU2WISOqSngeeM4hehtDkESovqXPSnFjCj9Yy4pLJc96gXykOhl(CF(3aliZeg)d4WwC7wUNkIk2QPetX1XWLKpHqk8BuUFpwuTx0T5fFbbCRErS1n5kCSw(LelYdSN0iwwgWq2(NaVzN8H81ztMbLRz(KhoSBBvD(hP6QcRnXlVA(n)4Zn1khjfirnga7z8LDvVD1S7(c(6GpdxSxWDK5rDcNGm)OyhB1KjcgluClc7wu3E)3S6yxB1dZXAqPRUCg(WBSomZlm11lShEMDqMhly0ny7N5811dVHAygEIRhRhMWzJsRo21w9WBkEqwusYOdnJ7CwC4i0Q9yrJqR2pA6y0QhNbDfpg9i1pE8f(b3JuxdMn8CnJB0UEFRHNrduPm(gQbRoDeUVLhZ1ZWhEEH7N58WmhEgneDDSRNHpirZIDT)OdrR2J5AFugAwnLUe4yYdYYdMQ9AiNYW5Mz5ErIKRoSVytzU4qrKoF0GSRTUO65ffgoP)ERA1b6mgIFX4)7Vp" },
}

EllesmereUI.WEEKLY_SPOTLIGHT = nil  -- { name = "...", description = "...", exportString = "!EUI_..." }
-- To set a weekly spotlight, uncomment and fill in:
-- EllesmereUI.WEEKLY_SPOTLIGHT = {
--     name = "Week 1 Spotlight",
--     description = "A clean minimal setup",
--     exportString = "!EUI_...",
-- }


-------------------------------------------------------------------------------
--  Initialize profile system on first login
--  Creates the "Default" profile from current settings if none exists.
--  Also saves the active profile on logout (via Lite pre-logout callback)
--  so SavedVariables are current before StripDefaults runs.
-------------------------------------------------------------------------------
do
    -- Register pre-logout callback to persist fonts, colors, and unlock layout
    -- into the active profile, and track the last non-spec profile.
    -- All addons use _dbRegistry (NewDB), so no manual snapshot is needed --
    -- they write directly to the central store.
    EllesmereUI.Lite.RegisterPreLogout(function()
        if not EllesmereUI._profileSaveLocked then
            local db = GetProfilesDB()
            local name = db.activeProfile or "Default"
            local profileData = db.profiles[name]
            if profileData then
                profileData.fonts = DeepCopy(EllesmereUI.GetFontsDB())
                profileData.customColors = DeepCopy(EllesmereUI.GetCustomColorsDB())
                profileData.unlockLayout = {
                    anchors       = DeepCopy(EllesmereUIDB.unlockAnchors     or {}),
                    widthMatch    = DeepCopy(EllesmereUIDB.unlockWidthMatch  or {}),
                    heightMatch   = DeepCopy(EllesmereUIDB.unlockHeightMatch or {}),
                    phantomBounds = DeepCopy(EllesmereUIDB.phantomBounds     or {}),
                }
            end
            -- Track the last active profile that was NOT spec-assigned so
            -- characters without a spec assignment can fall back to it.
            local isSpecAssigned = false
            if db.specProfiles then
                for _, pName in pairs(db.specProfiles) do
                    if pName == name then isSpecAssigned = true; break end
                end
            end
            if not isSpecAssigned then
                db.lastNonSpecProfile = name
            end
        end
    end)

    local initFrame = CreateFrame("Frame")
    initFrame:RegisterEvent("PLAYER_LOGIN")
    initFrame:SetScript("OnEvent", function(self)
        self:UnregisterEvent("PLAYER_LOGIN")

        local db = GetProfilesDB()

        -- On first install, create "Default" from current (default) settings
        if not db.activeProfile then
            db.activeProfile = "Default"
        end
        -- Ensure Default profile exists (empty table -- NewDB fills defaults)
        if not db.profiles["Default"] then
            db.profiles["Default"] = {}
        end
        -- Ensure Default is in the order list
        local hasDefault = false
        for _, n in ipairs(db.profileOrder) do
            if n == "Default" then hasDefault = true; break end
        end
        if not hasDefault then
            table.insert(db.profileOrder, "Default")
        end

        ---------------------------------------------------------------
        --  Note: multiple specs may intentionally point to the same
        --  profile. No deduplication is performed here.
        ---------------------------------------------------------------

        -- Restore saved profile keybinds
        C_Timer.After(1, function()
            EllesmereUI.RestoreProfileKeybinds()
        end)
    end)
end

-------------------------------------------------------------------------------
--  Shared popup builder for Export and Import
--  Matches the info popup look: dark bg, thin scrollbar, smooth scroll.
-------------------------------------------------------------------------------
local SCROLL_STEP  = 45
local SMOOTH_SPEED = 12

local function BuildStringPopup(title, subtitle, readOnly, onConfirm, confirmLabel)
    local POPUP_W, POPUP_H = 520, 310
    local FONT = EllesmereUI.EXPRESSWAY

    -- Dimmer
    local dimmer = CreateFrame("Frame", nil, UIParent)
    dimmer:SetFrameStrata("FULLSCREEN_DIALOG")
    dimmer:SetAllPoints(UIParent)
    dimmer:EnableMouse(true)
    dimmer:EnableMouseWheel(true)
    dimmer:SetScript("OnMouseWheel", function() end)
    local dimTex = dimmer:CreateTexture(nil, "BACKGROUND")
    dimTex:SetAllPoints()
    dimTex:SetColorTexture(0, 0, 0, 0.25)

    -- Popup
    local popup = CreateFrame("Frame", nil, dimmer)
    popup:SetSize(POPUP_W, POPUP_H)
    popup:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    popup:SetFrameStrata("FULLSCREEN_DIALOG")
    popup:SetFrameLevel(dimmer:GetFrameLevel() + 10)
    popup:EnableMouse(true)
    local bg = popup:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.06, 0.08, 0.10, 1)
    EllesmereUI.MakeBorder(popup, 1, 1, 1, 0.15, EllesmereUI.PanelPP)

    -- Title
    local titleFS = EllesmereUI.MakeFont(popup, 15, "", 1, 1, 1)
    titleFS:SetPoint("TOP", popup, "TOP", 0, -20)
    titleFS:SetText(title)

    -- Subtitle
    local subFS = EllesmereUI.MakeFont(popup, 11, "", 1, 1, 1)
    subFS:SetAlpha(0.45)
    subFS:SetPoint("TOP", titleFS, "BOTTOM", 0, -4)
    subFS:SetText(subtitle)

    -- ScrollFrame containing the EditBox
    local sf = CreateFrame("ScrollFrame", nil, popup)
    sf:SetPoint("TOPLEFT",     popup, "TOPLEFT",     20, -58)
    sf:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -20, 52)
    sf:SetFrameLevel(popup:GetFrameLevel() + 1)
    sf:EnableMouseWheel(true)

    local sc = CreateFrame("Frame", nil, sf)
    sc:SetWidth(sf:GetWidth() or (POPUP_W - 40))
    sc:SetHeight(1)
    sf:SetScrollChild(sc)

    local editBox = CreateFrame("EditBox", nil, sc)
    editBox:SetMultiLine(true)
    editBox:SetAutoFocus(false)
    editBox:SetFont(FONT, 11, "")
    editBox:SetTextColor(1, 1, 1, 0.75)
    editBox:SetPoint("TOPLEFT",     sc, "TOPLEFT",     0, 0)
    editBox:SetPoint("TOPRIGHT",    sc, "TOPRIGHT",   -14, 0)
    editBox:SetHeight(1)  -- grows with content

    -- Scrollbar track
    local scrollTrack = CreateFrame("Frame", nil, sf)
    scrollTrack:SetWidth(4)
    scrollTrack:SetPoint("TOPRIGHT",    sf, "TOPRIGHT",    -2, -4)
    scrollTrack:SetPoint("BOTTOMRIGHT", sf, "BOTTOMRIGHT", -2,  4)
    scrollTrack:SetFrameLevel(sf:GetFrameLevel() + 2)
    scrollTrack:Hide()
    local trackBg = scrollTrack:CreateTexture(nil, "BACKGROUND")
    trackBg:SetAllPoints()
    trackBg:SetColorTexture(1, 1, 1, 0.02)

    local scrollThumb = CreateFrame("Button", nil, scrollTrack)
    scrollThumb:SetWidth(4)
    scrollThumb:SetHeight(60)
    scrollThumb:SetPoint("TOP", scrollTrack, "TOP", 0, 0)
    scrollThumb:SetFrameLevel(scrollTrack:GetFrameLevel() + 1)
    scrollThumb:EnableMouse(true)
    scrollThumb:RegisterForDrag("LeftButton")
    scrollThumb:SetScript("OnDragStart", function() end)
    scrollThumb:SetScript("OnDragStop",  function() end)
    local thumbTex = scrollThumb:CreateTexture(nil, "ARTWORK")
    thumbTex:SetAllPoints()
    thumbTex:SetColorTexture(1, 1, 1, 0.27)

    local scrollTarget = 0
    local isSmoothing  = false
    local smoothFrame  = CreateFrame("Frame")
    smoothFrame:Hide()

    local function UpdateThumb()
        local maxScroll = EllesmereUI.SafeScrollRange(sf)
        if maxScroll <= 0 then scrollTrack:Hide(); return end
        scrollTrack:Show()
        local trackH = scrollTrack:GetHeight()
        local visH   = sf:GetHeight()
        local ratio  = visH / (visH + maxScroll)
        local thumbH = math.max(30, trackH * ratio)
        scrollThumb:SetHeight(thumbH)
        local scrollRatio = (tonumber(sf:GetVerticalScroll()) or 0) / maxScroll
        scrollThumb:ClearAllPoints()
        scrollThumb:SetPoint("TOP", scrollTrack, "TOP", 0, -(scrollRatio * (trackH - thumbH)))
    end

    smoothFrame:SetScript("OnUpdate", function(_, elapsed)
        local cur = sf:GetVerticalScroll()
        local maxScroll = EllesmereUI.SafeScrollRange(sf)
        scrollTarget = math.max(0, math.min(maxScroll, scrollTarget))
        local diff = scrollTarget - cur
        if math.abs(diff) < 0.3 then
            sf:SetVerticalScroll(scrollTarget)
            UpdateThumb()
            isSmoothing = false
            smoothFrame:Hide()
            return
        end
        sf:SetVerticalScroll(cur + diff * math.min(1, SMOOTH_SPEED * elapsed))
        UpdateThumb()
    end)

    local function SmoothScrollTo(target)
        local maxScroll = EllesmereUI.SafeScrollRange(sf)
        scrollTarget = math.max(0, math.min(maxScroll, target))
        if not isSmoothing then isSmoothing = true; smoothFrame:Show() end
    end

    sf:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = EllesmereUI.SafeScrollRange(self)
        if maxScroll <= 0 then return end
        SmoothScrollTo((isSmoothing and scrollTarget or self:GetVerticalScroll()) - delta * SCROLL_STEP)
    end)
    sf:SetScript("OnScrollRangeChanged", function() UpdateThumb() end)

    -- Thumb drag
    local isDragging, dragStartY, dragStartScroll
    local function StopDrag()
        if not isDragging then return end
        isDragging = false
        scrollThumb:SetScript("OnUpdate", nil)
    end
    scrollThumb:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        isSmoothing = false; smoothFrame:Hide()
        isDragging = true
        local _, cy = GetCursorPosition()
        dragStartY      = cy / self:GetEffectiveScale()
        dragStartScroll = sf:GetVerticalScroll()
        self:SetScript("OnUpdate", function(self2)
            if not IsMouseButtonDown("LeftButton") then StopDrag(); return end
            isSmoothing = false; smoothFrame:Hide()
            local _, cy2 = GetCursorPosition()
            cy2 = cy2 / self2:GetEffectiveScale()
            local trackH   = scrollTrack:GetHeight()
            local maxTravel = trackH - self2:GetHeight()
            if maxTravel <= 0 then return end
            local maxScroll = EllesmereUI.SafeScrollRange(sf)
            local newScroll = math.max(0, math.min(maxScroll,
                dragStartScroll + ((dragStartY - cy2) / maxTravel) * maxScroll))
            scrollTarget = newScroll
            sf:SetVerticalScroll(newScroll)
            UpdateThumb()
        end)
    end)
    scrollThumb:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then StopDrag() end
    end)

    -- Reset on hide
    dimmer:HookScript("OnHide", function()
        isSmoothing = false; smoothFrame:Hide()
        scrollTarget = 0
        sf:SetVerticalScroll(0)
        editBox:ClearFocus()
    end)

    -- Auto-select for export (read-only): click selects all for easy copy.
    -- For import (editable): just re-focus so the user can paste immediately.
    if readOnly then
        editBox:SetScript("OnMouseUp", function(self)
            C_Timer.After(0, function() self:SetFocus(); self:HighlightText() end)
        end)
        editBox:SetScript("OnEditFocusGained", function(self)
            self:HighlightText()
        end)
    else
        editBox:SetScript("OnMouseUp", function(self)
            self:SetFocus()
        end)
        -- Click anywhere in the scroll area should also focus the editbox
        sf:SetScript("OnMouseDown", function()
            editBox:SetFocus()
        end)
    end

    if readOnly then
        editBox:SetScript("OnChar", function(self)
            self:SetText(self._readOnly or ""); self:HighlightText()
        end)
    end

    -- Resize scroll child to fit editbox content
    local function RefreshHeight()
        C_Timer.After(0.01, function()
            local lineH = (editBox.GetLineHeight and editBox:GetLineHeight()) or 14
            local h = editBox:GetNumLines() * lineH
            local sfH = sf:GetHeight() or 100
            -- Only grow scroll child beyond the visible area when content is taller
            if h <= sfH then
                sc:SetHeight(sfH)
                editBox:SetHeight(sfH)
            else
                sc:SetHeight(h + 4)
                editBox:SetHeight(h + 4)
            end
            UpdateThumb()
        end)
    end
    editBox:SetScript("OnTextChanged", function(self, userInput)
        if readOnly and userInput then
            self:SetText(self._readOnly or ""); self:HighlightText()
        end
        RefreshHeight()
    end)

    -- Buttons
    if onConfirm then
        local confirmBtn = CreateFrame("Button", nil, popup)
        confirmBtn:SetSize(120, 26)
        confirmBtn:SetPoint("BOTTOMRIGHT", popup, "BOTTOM", -4, 14)
        confirmBtn:SetFrameLevel(popup:GetFrameLevel() + 2)
        EllesmereUI.MakeStyledButton(confirmBtn, confirmLabel or "Import", 11,
            EllesmereUI.WB_COLOURS, function()
                local str = editBox:GetText()
                if str and #str > 0 then
                    dimmer:Hide()
                    onConfirm(str)
                end
            end)

        local cancelBtn = CreateFrame("Button", nil, popup)
        cancelBtn:SetSize(120, 26)
        cancelBtn:SetPoint("BOTTOMLEFT", popup, "BOTTOM", 4, 14)
        cancelBtn:SetFrameLevel(popup:GetFrameLevel() + 2)
        EllesmereUI.MakeStyledButton(cancelBtn, "Cancel", 11,
            EllesmereUI.RB_COLOURS, function() dimmer:Hide() end)
    else
        local closeBtn = CreateFrame("Button", nil, popup)
        closeBtn:SetSize(120, 26)
        closeBtn:SetPoint("BOTTOM", popup, "BOTTOM", 0, 14)
        closeBtn:SetFrameLevel(popup:GetFrameLevel() + 2)
        EllesmereUI.MakeStyledButton(closeBtn, "Close", 11,
            EllesmereUI.RB_COLOURS, function() dimmer:Hide() end)
    end

    -- Dimmer click to close
    dimmer:SetScript("OnMouseDown", function()
        if not popup:IsMouseOver() then dimmer:Hide() end
    end)

    -- Escape to close
    popup:EnableKeyboard(true)
    popup:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            dimmer:Hide()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)

    return dimmer, editBox, RefreshHeight
end

-------------------------------------------------------------------------------
--  Export Popup
-------------------------------------------------------------------------------
function EllesmereUI:ShowExportPopup(exportStr)
    local dimmer, editBox, RefreshHeight = BuildStringPopup(
        "Export Profile",
        "Copy the string below and share it",
        true, nil, nil)

    editBox._readOnly = exportStr
    editBox:SetText(exportStr)
    RefreshHeight()

    dimmer:Show()
    C_Timer.After(0.05, function()
        editBox:SetFocus()
        editBox:HighlightText()
    end)
end

-------------------------------------------------------------------------------
--  Import Popup
-------------------------------------------------------------------------------
function EllesmereUI:ShowImportPopup(onImport)
    local dimmer, editBox = BuildStringPopup(
        "Import Profile",
        "Paste an EllesmereUI profile string below",
        false,
        function(str) if onImport then onImport(str) end end,
        "Import")

    dimmer:Show()
    C_Timer.After(0.05, function() editBox:SetFocus() end)
end

-------------------------------------------------------------------------------
--  Wago UI Packs API
--  ExportProfile and ImportProfile already exist above with the right
--  signatures. The functions below fill in the rest of the spec:
--  https://github.com/methodgg/Wago-Creator-UI/blob/main/
--  WagoUI_Libraries/LibAddonProfiles/ImplementationGuide.lua
-------------------------------------------------------------------------------
function EllesmereUI.DecodeProfileString(profileString)
    local payload = EllesmereUI.DecodeImportString(profileString)
    return payload and payload.data or nil
end

function EllesmereUI.SetProfile(profileKey)
    EllesmereUI.SwitchProfile(profileKey)
end

function EllesmereUI.GetProfileKeys()
    local _, profiles = EllesmereUI.GetProfileList()
    local keys = {}
    if profiles then
        for k in pairs(profiles) do keys[k] = true end
    end
    return keys
end

function EllesmereUI.GetProfileAssignments()
    return nil
end

function EllesmereUI.GetCurrentProfileKey()
    return EllesmereUI.GetActiveProfileName()
end

function EllesmereUI.OpenConfig()
    if not InCombatLockdown() then EllesmereUI:Show() end
end

function EllesmereUI.CloseConfig()
    EllesmereUI:Hide()
end
