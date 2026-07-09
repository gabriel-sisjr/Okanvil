-- ============================================================
--   ██████╗ ██╗  ██╗ █████╗ ███╗   ██╗██╗   ██╗██╗██╗
--  ██╔═══██╗██║ ██╔╝██╔══██╗████╗  ██║██║   ██║██║██║
--  ██║   ██║█████╔╝ ███████║██╔██╗ ██║██║   ██║██║██║
--  ██║   ██║██╔═██╗ ██╔══██║██║╚██╗██║╚██╗ ██╔╝██║██║
--  ╚██████╔╝██║  ██╗██║  ██║██║ ╚████║ ╚████╔╝ ██║███████╗
--   ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝  ╚═══╝  ╚═╝╚══════╝
--  Okanvil -- a single raid & guild toolkit (MRT-style), by Okanor. One addon
--  with a native core (guild dashboard + module manager) and a set of built-in
--  modules (Guild / Invite / Recruit / Loot / ID Finder / Combat Logs) you toggle
--  on/off per character. Modules register into Okanvil_Plugins and share one media
--  layer. No standalone plugins -- it's all one addon.
-- ============================================================

Okanvil = Okanvil or {}
local Okanvil = Okanvil

-- ------------------------------------------------------------
-- 3.3.5a API compat shim: SetShown was added in WoW 4.x (Cataclysm). On a stock
-- 3.3.5a client the widget methods don't exist, so every `frame:SetShown(cond)`
-- throws "attempt to call method 'SetShown' (a nil value)". Some custom/patched
-- 3.3.5a cores backport it, which is why it works for some players and not
-- others. Polyfill it onto the shared widget metatables here, BEFORE any UI is
-- built (Core loads first in the .toc), so all 25+ call sites just work. Guarded
-- so a client that already has SetShown (patched core) is left untouched.
-- ------------------------------------------------------------
do
	local function polyfill(obj)
		if not obj then return end
		local mt = getmetatable(obj)
		local idx = mt and mt.__index
		if type(idx) ~= "table" then return end
		if not idx.SetShown then
			idx.SetShown = function(self, shown)
				if shown then self:Show() else self:Hide() end
			end
		end
	end
	-- In 3.3.5a EVERY widget type (Frame, Button, Slider, EditBox, ScrollFrame,
	-- CheckButton, ...) shares ONE method table -- getmetatable(x).__index is the
	-- same for all -- so patching a single throwaway Frame covers them all.
	-- CRITICAL: do NOT create an EditBox here to "also patch it". A fresh EditBox
	-- defaults to autoFocus=true and, on creation, GRABS the keyboard -- an orphan
	-- box left focused eats W/A/S/D for the whole session (this made the game
	-- unplayable). One Frame + its Texture/FontString metatables is enough.
	local f = CreateFrame("Frame")
	polyfill(f)
	polyfill(f:CreateTexture())
	polyfill(f:CreateFontString())
end

local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
Okanvil.LSM = LSM

Okanvil.version = GetAddOnMetadata and GetAddOnMetadata("Okanvil", "Version") or "1.0"
Okanvil.entries = {}          -- name -> plugin table (registered)
Okanvil._fontStrings = {}     -- font strings to restyle when the font changes

-- ------------------------------------------------------------
-- KEYBOARD-FOCUS SAFETY
-- An EditBox with keyboard focus swallows ALL keys -- including W/A/S/D -- so a
-- focus we forget to release makes the game unplayable (the user lost all keybinds
-- and had to delete the addon). Rules, per the user:
--   * NEVER auto-SetFocus (opening the addon must not steal the keyboard -- you
--     could be mid-fight and unable to move).
--   * Clicking ANYWHERE outside a text box drops focus.
--   * Entering combat / closing the window / switching page releases focus.
-- We track every EditBox we make and clear them all on those events.
-- ------------------------------------------------------------
Okanvil._editBoxes = Okanvil._editBoxes or {}
function Okanvil:TrackEditBox(e)
	if not e then return end
	self._editBoxes[e] = true
end
function Okanvil:ClearAllFocus()
	for e in pairs(self._editBoxes) do
		if e.HasFocus and e:HasFocus() then e:ClearFocus() end
	end
end

local FLAT = "Interface\\ChatFrame\\ChatFrameBackground"

-- ------------------------------------------------------------
-- ITEM CACHE WARMER  (shared by Mini Roll / Loot / Raid Finder)
-- On a fresh client, GetItemInfo returns nil for an item it has never seen, so
-- icons show "?" and AtlasLoot draws a red border. The fix is exactly what
-- AtlasLoot's "Query" button does: a hidden GameTooltip:SetHyperlink forces the
-- client to request the item from the server; a moment later GetItemInfo works.
--   * Okanvil:WarmItem(link|id)  -> queue a server request (deduped, throttled)
--   * Okanvil:ItemIcon(link|id)  -> icon texture now, or nil + auto-warm for later
-- Warming is throttled to a few items/sec on a ticker so it can't lag/disconnect
-- you (AtlasLoot's busy-loop can; ours is async).
-- ------------------------------------------------------------
do
	local tip                       -- hidden scanning tooltip (created on demand)
	local queue, queued = {}, {}    -- pending item keys + dedupe set
	local ticker                    -- OnUpdate driver (runs only while queue nonempty)
	local acc = 0

	local function keyOf(itemLinkOrId)
		if type(itemLinkOrId) == "number" then return "item:" .. itemLinkOrId end
		if type(itemLinkOrId) ~= "string" then return nil end
		if itemLinkOrId:find("item:") then
			-- extract the numeric id so links/ids dedupe to the same key
			local id = itemLinkOrId:match("item:(%d+)")
			return id and ("item:" .. id) or itemLinkOrId
		end
		local id = tonumber(itemLinkOrId)
		return id and ("item:" .. id) or nil
	end

	local function pump()
		if #queue == 0 then
			if ticker then ticker:SetScript("OnUpdate", nil); ticker:Hide() end
			return
		end
		if not tip then
			tip = CreateFrame("GameTooltip", "OkanvilWarmTip", nil, "GameTooltipTemplate")
			tip:SetOwner(WorldFrame, "ANCHOR_NONE")
		end
		-- process a few per tick (throttle -- server query is the risky part)
		for _ = 1, 3 do
			local key = table.remove(queue, 1)
			if not key then break end
			queued[key] = nil
			GetItemInfo(key)                       -- triggers cache request
			pcall(function() tip:SetHyperlink(key) end)
		end
	end

	function Okanvil:WarmItem(itemLinkOrId)
		local key = keyOf(itemLinkOrId)
		if not key or queued[key] then return end
		-- already cached? nothing to do.
		if GetItemInfo(key) then return end
		queued[key] = true
		queue[#queue + 1] = key
		if not ticker then
			ticker = CreateFrame("Frame")
		end
		-- (re)arm the driver: it clears its own OnUpdate when the queue empties.
		ticker:SetScript("OnUpdate", function(_, e)
			acc = acc + e
			if acc >= 0.1 then acc = 0; pump() end
		end)
		ticker:Show()
	end

	-- Return the icon texture NOW, or nil (and queue a warm so a later paint fills
	-- it in). Order: (1) the ID Finder's FILE-persisted icon (survives a client
	-- change -> no "?" after switching clients, IF you ran a Full scan), then
	-- (2) the live client cache (select(10, GetItemInfo) = icon path in 3.3.5a).
	function Okanvil:ItemIcon(itemLinkOrId)
		if not itemLinkOrId then return nil end
		-- try the saved DB first (needs a numeric id)
		if Okanvil.IDs and Okanvil.IDs.ItemIcon then
			local id = (type(itemLinkOrId) == "number") and itemLinkOrId
				or tonumber(tostring(itemLinkOrId):match("item:(%d+)"))
				or tonumber(itemLinkOrId)
			if id then
				local saved = Okanvil.IDs.ItemIcon(id)
				if saved then return saved end
			end
		end
		local tex = select(10, GetItemInfo(itemLinkOrId))
		if not tex then self:WarmItem(itemLinkOrId) end
		return tex
	end
end

-- ------------------------------------------------------------
-- Saved-variable defaults
-- ------------------------------------------------------------
local defaults = {
	window = { width = 660, height = 480, point = "CENTER", x = 0, y = 0 },
	scale = 1.0,
	font = "Friz Quadrata TT", -- LSM font name
	fontSize = 12,
	fontFlag = "", -- "", "OUTLINE", "THICKOUTLINE"
	statusbar = "Blizzard", -- LSM statusbar (for plugins that draw bars)
	bgAlpha = 0.95,
	minimapAngle = 200,
	modules = {},      -- name -> { enabled = bool }. Absent = enabled by default.
	brand = "RATS Guild Hub", -- GUILD SKIN shown after the fixed "Okanvil" wordmark (editable per guild; "" = none)
	hubURL = "https://mrnog.github.io/RATS/", -- the guild's web hub
	lootThreshold = 3, -- min item rarity to log: 0 poor,1 common,2 uncommon,3 rare,4 epic
	recordDungeon = true, -- capture attendance/loot in 5-man dungeons (party instances)
	recordRaid = true,    -- capture attendance/loot in raids
	ratArt = "on",         -- faded rat blacksmith art in the page corner: "on" | "off"
	ratAlpha = 0.30,       -- rat watermark intensity (own slider; independent of bgAlpha)
}

local function applyDefaults(dst, src)
	for k, v in pairs(src) do
		if dst[k] == nil then
			if type(v) == "table" then
				dst[k] = {}
				applyDefaults(dst[k], v)
			else
				dst[k] = v
			end
		elseif type(v) == "table" then
			applyDefaults(dst[k], v)
		end
	end
end

-- ------------------------------------------------------------
-- Media (shared look -- plugins use these so everything matches)
-- ------------------------------------------------------------
function Okanvil:Font()
	local db = self.db
	local path = LSM and LSM:Fetch("font", db.font, true)
	return path or STANDARD_TEXT_FONT, db.fontSize, db.fontFlag
end

-- create a font string that auto-restyles when the user changes the font
function Okanvil:NewText(parent, layer, template)
	local fs = parent:CreateFontString(nil, layer or "OVERLAY", template)
	fs:SetFont(self:Font())
	self._fontStrings[fs] = true
	return fs
end

function Okanvil:ApplyFonts()
	local font, size, flag = self:Font()
	for fs in pairs(self._fontStrings) do
		if fs.SetFont then
			-- keep per-string size if it was bumped (store a .sizeMul); default to global size
			fs:SetFont(font, fs._okSize or size, flag)
		end
	end
end

-- flat 1px-bordered panel (the Okanvil/ElvUI look). Plugins: use Okanvil:Backdrop(frame).
-- Kept for back-compat; delegates to the shared Okanvil:Skin (Widgets.lua) so
-- legacy plugins pick up the same palette and alpha re-tinting as the shell.
function Okanvil:Backdrop(frame, alpha, dark)
	if self.Skin then
		self:Skin(frame, dark and "dark" or "panel")
		if alpha then
			local r, g, b = frame:GetBackdropColor()
			frame:SetBackdropColor(r, g, b, alpha)
		end
		return
	end
end

function Okanvil:Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cffffd200[Okanvil]|r " .. tostring(msg))
end

-- Should we record attendance/loot right now? Respects the dungeon/raid toggles.
-- Outside instances (e.g. world) we still allow it (manual snapshots, etc.).
function Okanvil:ShouldRecord()
	if not GetInstanceInfo then return true end
	local _, instanceType = GetInstanceInfo()
	if instanceType == "party" then return self.db.recordDungeon ~= false end
	if instanceType == "raid" then return self.db.recordRaid ~= false end
	return true
end

-- ------------------------------------------------------------
-- Plugin registry (load-order safe: plugins fill Okanvil_Plugins)
-- ------------------------------------------------------------
function Okanvil:Register(name)
	local p = Okanvil_Plugins and Okanvil_Plugins[name]
	if not p or self.entries[name] then
		return
	end
	self.entries[name] = p
	if self.RefreshNav then
		self:RefreshNav() -- live update if the window is already built
	end
end

function Okanvil:ProcessPlugins()
	if not Okanvil_Plugins then
		return
	end
	for name in pairs(Okanvil_Plugins) do
		self:Register(name)
	end
end

function Okanvil:CountPlugins()
	local n = 0
	for _ in pairs(self.entries) do
		n = n + 1
	end
	return n
end

-- ------------------------------------------------------------
-- Module enable state -- PER CHARACTER (Okanvil_CharDB). Default: enabled. Each
-- toon decides which tools show; content settings stay account-wide. A disabled
-- module is still registered but hidden from the nav; deeper event-gating is
-- opt-in inside each module later.
-- ------------------------------------------------------------
function Okanvil:IsModuleEnabled(name)
	local m = self.cdb and self.cdb.modules and self.cdb.modules[name]
	if m and m.enabled == false then
		return false
	end
	return true
end

-- Should this module's PASSIVE behaviour run right now? A DISABLED module must be
-- as if it didn't exist -- it must NOT scan chat, log combat, capture loot, or
-- auto-invite. Every module gates its event handlers / OnUpdate ticks with this
-- (return early when false). Safe before login (cdb nil -> treated as enabled, so
-- boot events still register). This is the ONE rule for "off = off, not just hidden".
function Okanvil:ModuleActive(name)
	if not self.cdb then return true end   -- pre-login: let boot run
	return self:IsModuleEnabled(name)
end

function Okanvil:SetModuleEnabled(name, enabled)
	local cdb = self.cdb
	cdb.modules = cdb.modules or {}
	cdb.modules[name] = cdb.modules[name] or {}
	cdb.modules[name].enabled = enabled and true or false
	if self.RefreshNav then self:RefreshNav() end
	-- if the active panel was just disabled, fall back to Home
	if not enabled and self._current == name and self.ShowPanel then
		self:ShowPanel("__home")
	end
end

-- ------------------------------------------------------------
-- Events / boot
-- ------------------------------------------------------------
local core = CreateFrame("Frame")
core:RegisterEvent("ADDON_LOADED")
core:RegisterEvent("PLAYER_LOGIN")
core:RegisterEvent("PLAYER_REGEN_DISABLED")   -- entered combat -> release keyboard
core:SetScript("OnEvent", function(_, event, arg1)
	if event == "PLAYER_REGEN_DISABLED" then
		-- combat started: never keep the keyboard captured (movement must work)
		Okanvil:ClearAllFocus()
		return
	end
	if event == "ADDON_LOADED" and arg1 == "Okanvil" then
		Okanvil_DB = Okanvil_DB or {}
		applyDefaults(Okanvil_DB, defaults)
		Okanvil.db = Okanvil_DB
		-- PER-CHARACTER state (which modules THIS toon shows). Content settings
		-- (brand, fonts, recruit messages, item DB...) stay account-wide in db;
		-- only enable/disable is per-char, so each toon can turn tools on/off.
		Okanvil_CharDB = Okanvil_CharDB or {}
		Okanvil.cdb = Okanvil_CharDB
		-- one-time migration: move any account-wide module toggles to this char
		if Okanvil_DB.modules and not Okanvil_CharDB.modules then
			Okanvil_CharDB.modules = Okanvil_DB.modules
			Okanvil_DB.modules = nil
		end
		Okanvil_CharDB.modules = Okanvil_CharDB.modules or {}
		-- migrate old saved brands: the product name is now a FIXED wordmark, so
		-- db.brand is only the guild skin. Strip a leading "Okanvil" (+ separator)
		-- left over from when it held the whole "Okanvil - <guild>" string.
		local b = Okanvil_DB.brand
		if type(b) == "string" then
			local skin = b:gsub("^%s*[Oo]kanvil%s*[%-%:%|\194\183]*%s*", "")
			if skin == "Okanvil" then skin = "" end
			Okanvil_DB.brand = skin
		end
	elseif event == "PLAYER_LOGIN" then
		Okanvil:ProcessPlugins()
		if Okanvil.BuildMinimap then
			Okanvil:BuildMinimap()
		end
		Okanvil:Print("loaded -- |cff00ff00/okanvil|r. " .. Okanvil:CountPlugins() .. " plugin(s).")
	end
end)

-- ------------------------------------------------------------
-- Slash
-- ------------------------------------------------------------
SLASH_Okanvil1 = "/okanvil"
SlashCmdList["Okanvil"] = function()
	Okanvil:Toggle()
end

-- Emergency keyboard release: if anything ever traps the keyboard again, this
-- clears our tracked boxes AND force-releases any lingering focus. Type /okfocus.
SLASH_OKFOCUS1 = "/okfocus"
SlashCmdList["OKFOCUS"] = function()
	Okanvil:ClearAllFocus()
	Okanvil:Print("released keyboard focus.")
end
