local addon = LibStub("AceAddon-3.0"):GetAddon("KuiNameplates")
local mod   = addon:NewModule("ThreatDifferential", addon.Prototype, "AceEvent-3.0", "AceTimer-3.0")
local LSM   = LibStub("LibSharedMedia-3.0")
local AceConfig       = LibStub("AceConfig-3.0")
local AceConfigDialog = LibStub("AceConfigDialog-3.0")

mod.uiName = "Threat Differential"

-- fade override modes
local OM = {
    OFF="off", LOSING="losing", RED_ONLY="red", THRESHOLD="threshold",
    STICKY_RECENT="sticky", OFF_TARGETS="offtargets", ELITE_PRIORITY="elite", SMART_TANKMODE="smart",
}
-- value display modes
local VM = { MY_PCT="my_pct", LEAD="lead", BOTH="both" }

function mod:OnInitialize()
    self.db = addon.db:RegisterNamespace(self.moduleName, {
        profile = {
            enabled=true, ooc=false, x=0, y=2, scale=1.0,
            colourThreat=true, useKuiGlowColour=true,
            staleSecs=1.0, tickSecs=0.2,

            valueMode=VM.BOTH,                   -- MY_PCT | LEAD | BOTH
            overrideMode=OM.LOSING,
            alwaysShowTarget=true,
            thresholdPct=70, stickySecs=1.0,

            -- NEW: force-show when anyone changes target to a non-player
            forceOnTargetChange=true,
            forceOnTargetSecs=1.5,
        }
    })
    AceConfig:RegisterOptionsTable("kuinameplates-threatdifferential", self:GetOptions())
    AceConfigDialog:AddToBlizOptions("kuinameplates-threatdifferential", self.uiName, "Kui |cff9966ffNameplates|r")
end

-- runtime state
local shown, cache = {}, {} -- cache[guid] = { pct, val, lead, t, r,g,b }
local lastNonGreenAt = setmetatable({}, { __mode="k" })
local touchedAlpha   = setmetatable({}, { __mode="k" })
local forceShowUntil = setmetatable({}, { __mode="k" }) -- NEW: per-frame timestamp
local timerHandle, currentTargetPlate

-- ---------- small utils ----------
local function Abbrev(v)
    if not v or v == 0 then return "0" end
    local a = math.abs(v)
    if a >= 1e12 then return string.format("%dt", math.floor(v/1e12)) end
    if a >= 1e9  then return string.format("%db", math.floor(v/1e9))  end
    if a >= 1e6  then return string.format("%dm", math.floor(v/1e6))  end
    if a >= 1e3  then return string.format("%dk", math.floor(v/1e3))  end
    return tostring(v)
end

local function FormatLead(v)
    if not v or v == 0 then return "0" end
    if v > 0 then return "+"..Abbrev(v) end
    return "-"..Abbrev(-v)
end

local function IsFrame(o) return type(o)=="table" and o.GetObjectType and o:IsObjectType("Frame") end
local function isOptionsOpen()
    local of = AceConfigDialog and AceConfigDialog.OpenFrames and AceConfigDialog.OpenFrames["kuinameplates-threatdifferential"]
    return of and of.frame and of.frame:IsShown()
end

-- FontString scaling (Wrath FS has no SetScale)
local function applyFontScale(fs, mult)
    if not (fs and fs.SetFont) then return end
    local font, size, flags = fs:GetFont()
    if not fs._baseFont then fs._baseFont, fs._baseSize, fs._baseFlags = font, size or 12, flags end
    local baseSize = fs._baseSize or size or 12
    local newSize  = math.max(6, math.floor(baseSize * (mult or 1.0) + 0.5))
    fs:SetFont(fs._baseFont or font, newSize, fs._baseFlags or flags)
end

local function applyFSLayout(frame, fs, db)
    fs:ClearAllPoints()
    fs:SetPoint("BOTTOM", frame, "TOP", db.x or 0, db.y or 0)
    applyFontScale(fs, db.scale or 1.0)
end

local function EnsureText(frame)
    if not IsFrame(frame) then return end
    if frame.threatText and frame.threatText.SetText then
        applyFSLayout(frame, frame.threatText, mod.db.profile); return
    end
    local parent = (frame.overlay and IsFrame(frame.overlay)) and frame.overlay or frame
    local fs = frame:CreateFontString(parent, { font = addon.font, size = "small", outline = "OUTLINE", alpha = 1 })
    fs:SetJustifyH("CENTER"); fs:SetJustifyV("BOTTOM"); fs:SetText("")
    frame.threatText = fs
    applyFSLayout(frame, fs, mod.db.profile)
end

-- ---------- threat + colours ----------
local function PlayerThreat(unit)
    if not UnitExists(unit) then return 0, 0, false, 0 end
    local isTanking, status, pct, _, val = UnitDetailedThreatSituation("player", unit)
    return pct or 0, val or 0, isTanking and true or false, status or 0
end

local function NextHighestThreatValue(unit)
    if not UnitExists(unit) then return 0, 0, 0 end
    local _, _, _, _, myVal = UnitDetailedThreatSituation("player", unit)
    myVal = myVal or 0
    local function chk(u)
        if UnitExists(u) then
            local _,_,_,_,v = UnitDetailedThreatSituation(u, unit)
            if v and not UnitIsUnit(u, "player") then return v end
        end
    end
    local best = 0
    local rn = GetNumRaidMembers() or 0
    local pn = GetNumPartyMembers() or 0
    if rn > 0 then
        for i=1,rn do best = math.max(best, chk("raid"..i) or 0, chk("raidpet"..i) or 0) end
    elseif pn > 0 then
        for i=1,pn do best = math.max(best, chk("party"..i) or 0, chk("partypet"..i) or 0) end
    end
    best = math.max(best, chk("pet") or 0)
    return myVal, best, (myVal - best)
end

local function GetTankMod() return addon.GetModule and addon:GetModule("TankMode", true) or nil end
local function TankColours()
    local TM = GetTankMod()
    if TM and TM.db and TM.db.profile and TM.db.profile.tankmode then
        local t = TM.db.profile.tankmode
        return t.barcolour, t.midcolour, t.glowcolour
    end
    return {0.2,0.9,0.1},{1,0.5,0},{1,0,0}
end

-- text colour that matches Kui TankMode; negative lead forces orange
local function KuiThreatTextColour(frame, unit, pct, lead)
    local bar, mid, glow = TankColours()
    if lead and lead < 0 then return unpack(mid) end
    if frame and frame.holdingThreat ~= nil then
        if frame.holdingThreat == true then return unpack(bar) else return unpack(mid) end
    end
    if unit then
        local isTanking, status = UnitDetailedThreatSituation("player", unit)
        if isTanking then return unpack(bar) end
        if (pct or 0) >= 80 or (status and status >= 2) then return unpack(mid) end
        return unpack(glow)
    end
    return 1,1,1
end

local function canShowNow() if mod.db.profile.ooc then return true end return UnitAffectingCombat("player") end

-- ---------- draw/update ----------
local function UpdateFromCache(frame)
    if not IsFrame(frame) then return end
    local fs = frame.threatText; if not (fs and fs.SetText) then return end
    local db = mod.db.profile; local staleSecs = db.staleSecs or 1.0

    if isOptionsOpen() then
        applyFSLayout(frame, fs, db)
        local demo = (db.valueMode==VM.LEAD) and "+12k" or (db.valueMode==VM.BOTH and "88% (123k)  +12k" or "88% (123k)")
        fs:SetText(demo)
        local r,g,b = KuiThreatTextColour(frame, nil, nil, (db.valueMode~=VM.MY_PCT) and -1 or nil)
        fs:SetTextColor(r,g,b); fs:Show(); return
    end

    if not canShowNow() then fs:SetText(""); fs:Hide(); return end
    if frame.guid and frame.guid:find("^Player") then fs:SetText(""); fs:Hide(); return end

    local c = frame.guid and cache[frame.guid] or nil
    if c and (GetTime() - (c.t or 0)) <= staleSecs then
        local text
        if db.valueMode == VM.LEAD then
            text = FormatLead(c.lead or 0)
        elseif db.valueMode == VM.BOTH then
            text = string.format("%d%% (%s)  %s", c.pct or 0, Abbrev(c.val or 0), FormatLead(c.lead or 0))
        else
            text = string.format("%d%% (%s)", c.pct or 0, Abbrev(c.val or 0))
        end
        fs:SetText(text)
        local r,g,b = KuiThreatTextColour(frame, nil, c.pct, c.lead)
        fs:SetTextColor(r,g,b)
        fs:Show()
    else
        fs:SetText(""); fs:Hide()
    end
end

local function HideForUnit(unit)
    local plate = addon.GetUnitPlate and addon:GetUnitPlate(unit) or nil
    if IsFrame(plate) and plate.threatText then plate.threatText:SetText(""); plate.threatText:Hide() end
    local g = UnitGUID(unit); if g then cache[g] = nil end
end

local function SaveThreatFor(unit)
    if not UnitExists(unit) then return end
    if UnitIsPlayer(unit) then HideForUnit(unit); return end
    if not canShowNow() then return end
    local guid = UnitGUID(unit); if not guid then return end
    local pct, val = PlayerThreat(unit)
    local myVal, otherVal, lead = NextHighestThreatValue(unit)
    local plate = addon.GetUnitPlate and addon:GetUnitPlate(unit) or nil
    local r,g,b = KuiThreatTextColour(plate, unit, pct, lead)
    cache[guid] = { pct=pct, val=val, lead=lead, t=GetTime(), r=r, g=g, b=b }
    if IsFrame(plate) then EnsureText(plate); UpdateFromCache(plate) end
end

-- ---------- fade override ----------
local function IsEliteBoss(frame) return (frame and (frame.isElite or frame.isBoss)) and true or false end
local function IsPlateTarget(frame) return currentTargetPlate and frame == currentTargetPlate end

local function PlateNonGreen_Kui(frame)
    if frame and frame.holdingThreat ~= nil then return frame.holdingThreat == false end
    if frame and frame.glow and frame.glow:IsVisible() then
        local r,g,b = frame.glow:GetVertexColor()
        if r and g and b then return not (g > r*1.1 and g > b*1.1) end
    end
    return false
end

local function PlateRed_Fallback(frame)
    if frame and frame.glow and frame.glow:IsVisible() then
        local r,g,b = frame.glow:GetVertexColor()
        if r and g and b then return (r > g*1.1 and r > b*1.1) end
    end
    return false
end

-- Hard force to 1 by cancelling KUI's fade for the frame
local function PinAlpha(frame)
    if not IsFrame(frame) then return end
    if kui and kui.frameIsFading and kui.frameFadeRemoveFrame and kui.frameIsFading(frame) then
        kui.frameFadeRemoveFrame(frame)
    end
    frame.fadingTo = nil
    frame.lastAlpha = 1
    frame.currentAlpha = 1
    frame:SetAlpha(1)
end

local function ShouldForceShow(frame, db)
    if not frame then return false end
    if db.overrideMode == OM.OFF then return false end
    if db.alwaysShowTarget and IsPlateTarget(frame) then return true end

    -- NEW: force-show window from UNIT_TARGET
    if forceShowUntil[frame] and GetTime() < forceShowUntil[frame] then return true end

    if db.overrideMode == OM.SMART_TANKMODE then
        return frame.holdingThreat == false
    elseif db.overrideMode == OM.LOSING then
        return PlateNonGreen_Kui(frame)
    elseif db.overrideMode == OM.RED_ONLY then
        return PlateRed_Fallback(frame)
    elseif db.overrideMode == OM.THRESHOLD then
        local c = frame.guid and cache[frame.guid] or nil
        if c and (GetTime() - (c.t or 0)) <= (db.staleSecs or 1.0) then
            return (c.pct or 0) < (db.thresholdPct or 70)
        end
        return PlateNonGreen_Kui(frame)
    elseif db.overrideMode == OM.STICKY_RECENT then
        local ng = PlateNonGreen_Kui(frame)
        if ng then
            if not lastNonGreenAt[frame] then lastNonGreenAt[frame] = GetTime() end
            return true
        elseif lastNonGreenAt[frame] and (GetTime() - lastNonGreenAt[frame]) <= (db.stickySecs or 1.0) then
            return true
        else
            lastNonGreenAt[frame] = nil; return false
        end
    elseif db.overrideMode == OM.OFF_TARGETS then
        if IsPlateTarget(frame) then return false end
        return PlateNonGreen_Kui(frame)
    elseif db.overrideMode == OM.ELITE_PRIORITY then
        if not IsEliteBoss(frame) then return false end
        return PlateNonGreen_Kui(frame)
    end
    return false
end

local function ApplyFadeOverride(frame, db)
    local force = ShouldForceShow(frame, db)
    if force then
        if not touchedAlpha[frame] then touchedAlpha[frame] = frame:GetAlpha() or 1 end
        PinAlpha(frame)
    elseif touchedAlpha[frame] then
        frame:SetAlpha(touchedAlpha[frame]); touchedAlpha[frame] = nil
    end
end

-- ---------- helpers to clear everything ----------
local function ClearAllPlates()
    for f in pairs(shown) do
        if IsFrame(f) and f.threatText then f.threatText:SetText(""); f.threatText:Hide() end
        touchedAlpha[f] = nil
        lastNonGreenAt[f] = nil
        forceShowUntil[f] = nil
    end
end

-- ---------- Kui messages ----------
function mod:KuiNameplates_PostCreate(frame) if IsFrame(frame) then EnsureText(frame) end end
function mod:KuiNameplates_PostShow(frame) if IsFrame(frame) then shown[frame]=true; EnsureText(frame); UpdateFromCache(frame) end end
function mod:KuiNameplates_PostHide(frame) if IsFrame(frame) then shown[frame]=nil; touchedAlpha[frame]=nil; lastNonGreenAt[frame]=nil; forceShowUntil[frame]=nil end end
function mod:KuiNameplates_PostTarget(frame, isTarget)
    if not IsFrame(frame) then return end
    if isTarget and UnitExists("target") then SaveThreatFor("target") end
    EnsureText(frame); UpdateFromCache(frame)
end

-- ---------- events ----------
function mod:PLAYER_TARGET_CHANGED()
    currentTargetPlate = nil
    if UnitExists("target") then
        local p = addon.GetUnitPlate and addon:GetUnitPlate("target") or nil
        if IsFrame(p) then currentTargetPlate = p end
        if UnitIsPlayer("target") then HideForUnit("target") else SaveThreatFor("target") end
    end
end

function mod:UPDATE_MOUSEOVER_UNIT()
    if UnitExists("mouseover") then
        if UnitIsPlayer("mouseover") then HideForUnit("mouseover") else SaveThreatFor("mouseover") end
    end
end

-- NEW: when *any* unit swaps target, if that new target exists and isn't the player,
-- find the plate by GUID and force-show it briefly (and refresh threat if it’s our target/mouseover).
function mod:UNIT_TARGET(unit)
    if not self.db.profile.forceOnTargetChange then return end
    if not unit or unit == "player" or unit == "pet" then return end
    local ut = unit.."target"
    if not UnitExists(ut) then return end
    if UnitIsUnit(ut, "player") then return end

    local guid = UnitGUID(ut)
    if not guid then return end

    local plate
    for f in pairs(shown) do
        if IsFrame(f) and f.guid == guid then plate = f; break end
    end
    if plate then
        forceShowUntil[plate] = GetTime() + (self.db.profile.forceOnTargetSecs or 1.5)
        -- If it's also our target/mouseover, refresh threat values right away
        if UnitIsUnit(ut, "target") then SaveThreatFor("target")
        elseif UnitIsUnit(ut, "mouseover") then SaveThreatFor("mouseover") end
        ApplyFadeOverride(plate, self.db.profile)
        UpdateFromCache(plate)
    end
end

function mod:COMBAT_LOG_EVENT_UNFILTERED()
    local _, sub, _, _,_,_,_, destGUID = CombatLogGetCurrentEventInfo()
    if sub == "UNIT_DIED" and destGUID then cache[destGUID] = nil end
end

-- hard clear when leaving combat to avoid stale numbers
function mod:PLAYER_REGEN_ENABLED()
    wipe(cache)
    ClearAllPlates()
end

-- ---------- enable/disable ----------
function mod:OnEnable()
    local db = self.db.profile
    if db.enabled == false then self:Disable(); return end

    self:RegisterMessage("KuiNameplates_PostCreate")
    self:RegisterMessage("KuiNameplates_PostShow")
    self:RegisterMessage("KuiNameplates_PostHide")
    self:RegisterMessage("KuiNameplates_PostTarget")

    self:RegisterEvent("PLAYER_TARGET_CHANGED")
    self:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
    self:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    self:RegisterEvent("PLAYER_REGEN_ENABLED")
    self:RegisterEvent("UNIT_TARGET") -- NEW

    if UnitExists("target") then
        local p = addon.GetUnitPlate and addon:GetUnitPlate("target") or nil
        if IsFrame(p) then currentTargetPlate = p end
    end

    local tick = db.tickSecs or 0.2
    timerHandle = self:ScheduleRepeatingTimer(function()
        if UnitExists("target") then
            if UnitIsPlayer("target") then HideForUnit("target") else SaveThreatFor("target") end
            local p = addon.GetUnitPlate and addon:GetUnitPlate("target") or nil
            if IsFrame(p) then currentTargetPlate = p end
        else currentTargetPlate = nil end

        if UnitExists("mouseover") then
            if UnitIsPlayer("mouseover") then HideForUnit("mouseover") else SaveThreatFor("mouseover") end
        end

        for f in pairs(shown) do
            if IsFrame(f) then EnsureText(f); UpdateFromCache(f); ApplyFadeOverride(f, db) else shown[f]=nil end
        end
    end, tick)
end

function mod:OnDisable()
    if timerHandle then self:CancelTimer(timerHandle); timerHandle = nil end
    ClearAllPlates()
    wipe(shown); wipe(cache); wipe(touchedAlpha); wipe(lastNonGreenAt); wipe(forceShowUntil)
end

-- ---------- options ----------
local function applyAll()
    local db = mod.db.profile
    for f in pairs(shown) do
        if IsFrame(f) then EnsureText(f); UpdateFromCache(f); ApplyFadeOverride(f, db) end
    end
end

function mod:GetOptions()
    local function hiddenThreshold() return self.db.profile.overrideMode ~= OM.THRESHOLD end
    local function hiddenSticky()    return self.db.profile.overrideMode ~= OM.STICKY_RECENT end
    return {
        name = self.uiName, type = "group",
        args = {
            enabled = { name="Enable", type="toggle", order=1,
                get=function() return self.db.profile.enabled~=false end,
                set=function(_,v) self.db.profile.enabled= not not v; if v then self:Enable() else self:Disable() end end },
            ooc = { name="Enable out of combat", type="toggle", order=2,
                get=function() return self.db.profile.ooc end, set=function(_,v) self.db.profile.ooc= not not v; applyAll() end },

            valueMode = { name="Display mode", type="select", order=3,
                values = { [VM.MY_PCT]="My threat %", [VM.LEAD]="Lead vs next (±value)", [VM.BOTH]="Both: % and Lead" },
                get=function() return self.db.profile.valueMode end,
                set=function(_,v) self.db.profile.valueMode=v; applyAll() end },

            colourThreat = { name="Colour by threat", type="toggle", order=4,
                get=function() return self.db.profile.colourThreat end,
                set=function(_,v) self.db.profile.colourThreat= not not v; applyAll() end },
            useKuiGlowColour = { name="Match Kui glow colour", type="toggle", order=5,
                get=function() return self.db.profile.useKuiGlowColour end,
                set=function(_,v) self.db.profile.useKuiGlowColour= not not v; applyAll() end },

            overrideHeader = { type="header", name="Fade override", order=9 },
            overrideMode = {
                name="Override mode", type="select", order=10,
                values = {
                    [OM.OFF]="Off (respect Kui fading)",
                    [OM.LOSING]="Losing threat (non-green)",
                    [OM.RED_ONLY]="Not tanking (red only)",
                    [OM.THRESHOLD]="Below threshold %",
                    [OM.STICKY_RECENT]="Recently lost aggro (sticky)",
                    [OM.OFF_TARGETS]="Off-targets only",
                    [OM.ELITE_PRIORITY]="Boss/Elite priority",
                    [OM.SMART_TANKMODE]="Smart (Tank Mode)",
                },
                get=function() return self.db.profile.overrideMode end,
                set=function(_,v) self.db.profile.overrideMode=v; applyAll() end
            },
            alwaysShowTarget = { name="Always show target", type="toggle", order=11,
                get=function() return self.db.profile.alwaysShowTarget end,
                set=function(_,v) self.db.profile.alwaysShowTarget= not not v; applyAll() end },

            thresholdPct = { name="Threshold %", type="range", order=12, min=1, max=99, step=1, hidden=hiddenThreshold,
                get=function() return self.db.profile.thresholdPct end,
                set=function(_,v) self.db.profile.thresholdPct=v; applyAll() end },

            stickySecs = { name="Sticky window (sec)", type="range", order=13, min=0.2, max=3.0, step=0.1, hidden=hiddenSticky,
                get=function() return self.db.profile.stickySecs end,
                set=function(_,v) self.db.profile.stickySecs=v; applyAll() end },

            posHeader = { type="header", name="Position", order=20 },
            x = { name="Offset X", type="range", order=21, min=-200,max=200,step=1,
                get=function() return self.db.profile.x end,
                set=function(_,v) self.db.profile.x=v; applyAll() end },
            y = { name="Offset Y", type="range", order=22, min=-200,max=200,step=1,
                get=function() return self.db.profile.y end,
                set=function(_,v) self.db.profile.y=v; applyAll() end },
            scale = { name="Scale", type="range", order=23, min=0.5, max=2.0, step=0.05,
                get=function() return self.db.profile.scale end,
                set=function(_,v) self.db.profile.scale=v; applyAll() end },

            perfHeader = { type="header", name="Performance", order=30 },
            staleSecs = { name="Stale timeout (s)", type="range", order=31, min=0.2, max=3.0, step=0.1,
                get=function() return self.db.profile.staleSecs end,
                set=function(_,v) self.db.profile.staleSecs=v; applyAll() end },
            tickSecs = { name="Update rate (s)", type="range", order=32, min=0.05, max=0.5, step=0.01,
                get=function() return self.db.profile.tickSecs end,
                set=function(_,v)
                    self.db.profile.tickSecs=v
                    if timerHandle then self:CancelTimer(timerHandle) end
                    local db = self.db.profile
                    timerHandle = self:ScheduleRepeatingTimer(function()
                        if UnitExists("target") then
                            if UnitIsPlayer("target") then HideForUnit("target") else SaveThreatFor("target") end
                            local p = addon.GetUnitPlate and addon:GetUnitPlate("target") or nil
                            if IsFrame(p) then currentTargetPlate = p end
                        else currentTargetPlate = nil end

                        if UnitExists("mouseover") then
                            if UnitIsPlayer("mouseover") then HideForUnit("mouseover") else SaveThreatFor("mouseover") end
                        end

                        for f in pairs(shown) do
                            if IsFrame(f) then EnsureText(f); UpdateFromCache(f); ApplyFadeOverride(f, db) else shown[f]=nil end
                        end
                    end, v)
                end },

            forceHeader = { type="header", name="Target-change force show", order=40 },
            forceOnTargetChange = { name="Enable force-show on target change", type="toggle", order=41,
                get=function() return self.db.profile.forceOnTargetChange end,
                set=function(_,v) self.db.profile.forceOnTargetChange = not not v end },
            forceOnTargetSecs = { name="Force-show duration (sec)", type="range", order=42, min=0.2, max=3.0, step=0.1,
                get=function() return self.db.profile.forceOnTargetSecs end,
                set=function(_,v) self.db.profile.forceOnTargetSecs = v end },
        }
    }
end
