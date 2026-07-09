-- ============================================================
--   ██████╗ ██╗  ██╗ █████╗ ███╗   ██╗██╗   ██╗██╗██╗
--  ██╔═══██╗██║ ██╔╝██╔══██╗████╗  ██║██║   ██║██║██║
--  ██║   ██║█████╔╝ ███████║██╔██╗ ██║██║   ██║██║██║
--  ██║   ██║██╔═██╗ ██╔══██║██║╚██╗██║╚██╗ ██╔╝██║██║
--  ╚██████╔╝██║  ██╗██║  ██║██║ ╚████║ ╚████╔╝ ██║███████╗
--   ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝  ╚═══╝  ╚═╝╚══════╝
--  Okanvil-Logs -- combat-log control + a movable/lockable REC timer
--  + session tracker. A native Okanvil module (no standalone).
--  (Addons can't read/write files, so SLICING + EXPORT live in the
--   desktop tool; this records start/stop/zone as a reference.)
-- ============================================================

local ADDON = "Okanvil-Logs"
local FLAT = "Interface\\ChatFrame\\ChatFrameBackground"

local defaults = {
	askOnEnter = true, -- prompt (Start log / No) when entering an instance
	autoLog = false, -- legacy: silently auto-log on raid entry (used only if askOnEnter is off)
	recLocked = false, -- lock the REC timer (click-through, no drag)
	rec = { point = "TOP", x = 0, y = -140 },
	sessions = {}, -- persisted history of logging sessions (zone, start, stop, bosses)
}
local db
local rec, toastF, askLogF -- floating frames (live on UIParent, not in the host window)
local askedZone -- last instance we already prompted for (avoid re-asking on repeat PLAYER_ENTERING_WORLD)
OkanvilLogs = OkanvilLogs or {} -- tiny namespace for slash / boot

-- ------------------------------------------------------------
-- helpers -- thin wrappers over the shared Okanvil widget layer. The host is
-- always loaded (this is a native module), so no local fallbacks. These are only
-- used for the floating frames (REC timer, toast, ask-prompt); the in-window UI
-- uses Okanvil.W.* directly.
-- ------------------------------------------------------------
local function flat(f, a, dark) Okanvil:Backdrop(f, a, dark) end

local function newText(parent, layer, size)
	local fs = Okanvil:NewText(parent, layer)
	if size then fs._okSize = size; fs:SetFont(Okanvil:Font(), size) end
	return fs
end

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cffe0b860[Okanvil-Logs]|r " .. tostring(msg))
end

local function fmtTime(s)
	s = math.floor(s or 0)
	if s >= 3600 then
		return string.format("%d:%02d:%02d", math.floor(s / 3600), math.floor(s / 60) % 60, s % 60)
	end
	return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

-- shared gold RATS-Hub button (host always present)
local function flatButton(parent, text, w, h, kind)
	local b = Okanvil.W.Button(parent, text, kind)
	b:SetSize(w, h)
	return b
end

-- A full-width settings card: title (+ optional sub) on the left, an ON/OFF pill
-- right-aligned INSIDE the card. Nothing can overlap regardless of label width.
local function cardToggle(parent, title, sub, getFn, setFn)
	local card = Okanvil.W.Frame(parent, "panel")
	card:SetHeight(sub and 42 or 30)

	local t = newText(card, "OVERLAY")
	t:SetPoint("LEFT", 12, sub and 8 or 0)
	t:SetText(title)

	if sub then
		local s = newText(card, "OVERLAY", 10)
		s:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, -3)
		s:SetText("|cff8a8d93" .. sub .. "|r")
	end

	local b = flatButton(card, "", 48, 20)
	b:SetPoint("RIGHT", -10, 0)
	local function paint()
		b.text:SetText(getFn() and "|cff7cfc8aON|r" or "|cff8a8d93OFF|r")
	end
	paint()
	b:SetScript("OnClick", function() setFn(not getFn()); paint() end)
	card.pill, card._paint = b, paint
	return card
end

-- ------------------------------------------------------------
-- logging state + sessions
-- ------------------------------------------------------------
local function isLogging()
	return LoggingCombat()
end

-- We keep a small history of logging sessions (zone, times, bosses killed) so the
-- Combat Logs page is a real log, not just a live toggle. The desktop tool still
-- does the actual WoWCombatLog.txt slicing; this is the in-game reference index.
local MAX_LOG_SESSIONS = 30
local function beginSession()
	local zone = GetRealZoneText()
	if not zone or zone == "" then zone = GetZoneText() end
	db._cur = { start = time(), zone = zone or "", bosses = {} }
end

local function endSession()
	if db._cur then
		db._cur.stop = time()
		db._cur.recentDeaths = nil          -- transient, don't persist
		db._lastBosses = db._cur.bosses     -- keep last session's kills visible after Stop
		-- persist into the history list (newest first)
		db.sessions = db.sessions or {}
		table.insert(db.sessions, 1, db._cur)
		while #db.sessions > MAX_LOG_SESSIONS do table.remove(db.sessions) end
	end
	db._cur = nil
	if OkanvilLogs.Refresh then OkanvilLogs.Refresh() end
end

function OkanvilLogs.DeleteSession(sess)
	if not db or not db.sessions then return end
	for i = #db.sessions, 1, -1 do
		if db.sessions[i] == sess then table.remove(db.sessions, i); break end
	end
	if OkanvilLogs.Refresh then OkanvilLogs.Refresh() end
end

-- ------------------------------------------------------------
-- transient toast (start/stop)
-- ------------------------------------------------------------
local function toast(msg, color)
	PlaySound("UI_BnetToast")
	if not toastF then
		toastF = CreateFrame("Frame", nil, UIParent)
		toastF:SetSize(230, 30)
		toastF:SetPoint("TOP", 0, -100)
		toastF:SetFrameStrata("FULLSCREEN_DIALOG")
		flat(toastF, 0.96, true)
		toastF.txt = newText(toastF, "OVERLAY")
		toastF.txt:SetPoint("CENTER")
		toastF:SetScript("OnUpdate", function(s, e)
			s._life = (s._life or 0) - e
			if s._life <= 0 then
				s:Hide()
			elseif s._life < 1 then
				s:SetAlpha(s._life)
			end
		end)
	end
	toastF.txt:SetText("|cff" .. (color or "ffffff") .. msg .. "|r")
	toastF:SetAlpha(1)
	toastF._life = 3
	toastF:Show()
end

-- ------------------------------------------------------------
-- raid boss recognition -- record which bosses died during a session
-- (no encounter API in 3.3.5a, so we match UNIT_DIED against known names)
-- ------------------------------------------------------------
local BOSSES = {}
do
	local names = {
		-- Ulduar
		"Flame Leviathan", "Ignis the Furnace Master", "Razorscale", "XT-002 Deconstructor",
		"Steelbreaker", "Runemaster Molgeim", "Stormcaller Brundir", "Kologarn", "Auriaya",
		"Hodir", "Thorim", "Freya", "Mimiron", "General Vezax", "Yogg-Saron", "Algalon the Observer",
		-- Icecrown Citadel
		"Lord Marrowgar", "Lady Deathwhisper", "Deathbringer Saurfang", "Festergut", "Rotface",
		"Professor Putricide", "Prince Keleseth", "Prince Taldaram", "Prince Valanar",
		"Blood-Queen Lana'thel", "Sindragosa", "The Lich King",
		-- Trial of the (Grand) Crusader
		"Gormok the Impaler", "Acidmaw", "Dreadscale", "Icehowl", "Lord Jaraxxus",
		"Eydis Darkbane", "Fjola Lightbane", "Anub'arak",
		-- Naxxramas
		"Anub'Rekhan", "Grand Widow Faerlina", "Maexxna", "Noth the Plaguebringer",
		"Heigan the Unclean", "Loatheb", "Instructor Razuvious", "Gothik the Harvester",
		"Patchwerk", "Grobbulus", "Gluth", "Thaddius", "Sapphiron", "Kel'Thuzad",
		-- Other WotLK raids
		"Malygos", "Sartharion", "Onyxia",
		"Archavon the Stone Watcher", "Emalon the Storm Watcher", "Koralon the Flame Watcher", "Toravon the Ice Watcher",
		"Halion", "Baltharus the Warborn", "General Zarithrian", "Saviana Ragefire",
	}
	for i = 1, #names do
		BOSSES[names[i]] = true
	end
end

-- Boss NPC IDs -- locale-proof and more reliable than names. Either an ID match OR a
-- name match counts, so a wrong/missing ID still gets caught by the name list above.
local BOSS_IDS = {}
do
	local ids = {
		-- Ulduar
		33113, 33118, 33186, 33293,            -- Flame Leviathan, Ignis, Razorscale, XT-002
		32867, 32927, 32857,                   -- Assembly: Steelbreaker, Molgeim, Brundir
		32930, 33515, 32845, 32865, 32906,     -- Kologarn, Auriaya, Hodir, Thorim, Freya
		33350, 33271, 33288, 32871,            -- Mimiron, General Vezax, Yogg-Saron, Algalon
		-- Icecrown Citadel
		36612, 36855, 37813, 36626, 36627, 36678, -- Marrowgar, Deathwhisper, Saurfang, Festergut, Rotface, Putricide
		37972, 37973, 37970, 37955, 36853, 36597, -- Keleseth, Taldaram, Valanar, Lana'thel, Sindragosa, Lich King
		-- Trial of the (Grand) Crusader
		34796, 35144, 34799, 34797, 34780, 34496, 34497, 34564, -- Gormok, Acidmaw, Dreadscale, Icehowl, Jaraxxus, Twins, Anub
		-- Naxxramas
		15956, 15953, 15952, 15954, 15936, 16011, 16061, 16060, -- Anub'Rekhan..Gothik
		16028, 15931, 15932, 15928, 15989, 15990,               -- Patchwerk..Kel'Thuzad
		-- Other WotLK raids
		28859, 28860, 10184,                   -- Malygos, Sartharion, Onyxia
		31125, 33993, 35013, 38433,            -- VoA: Archavon, Emalon, Koralon, Toravon
		39863, 39751, 39746, 39747,            -- Ruby Sanctum: Halion, Baltharus, Zarithrian, Saviana
	}
	for i = 1, #ids do
		BOSS_IDS[ids[i]] = true
	end
end

-- 3.3.5a: pull the creature entry id out of a unit GUID (same parse as Loot.lua's
-- cidFromGUID: pad to 16 hex chars, validate the F13/F15 type triplet, extract sub(6,10))
local function npcID(guid)
	if type(guid) ~= "string" then
		return nil
	end
	local hex = guid:match("^0x(%x+)$") or guid:match("^(%x+)$")
	if not hex then
		return nil
	end
	if #hex < 16 then
		hex = string.rep("0", 16 - #hex) .. hex
	end
	local triplet = hex:sub(1, 3):upper()
	if triplet ~= "F13" and triplet ~= "F15" then
		return nil
	end
	return tonumber(hex:sub(6, 10), 16)
end

-- Multi-NPC encounters: collapse their members into one line (by id or name).
local GROUP = {
	-- Iron Council (Assembly of Iron)
	[32867] = "Iron Council", [32927] = "Iron Council", [32857] = "Iron Council",
	["Steelbreaker"] = "Iron Council", ["Runemaster Molgeim"] = "Iron Council", ["Stormcaller Brundir"] = "Iron Council",
	-- Blood Prince Council
	[37972] = "Blood Prince Council", [37973] = "Blood Prince Council", [37970] = "Blood Prince Council",
	["Prince Keleseth"] = "Blood Prince Council", ["Prince Taldaram"] = "Blood Prince Council", ["Prince Valanar"] = "Blood Prince Council",
	-- Twin Val'kyr
	[34496] = "Twin Val'kyr", [34497] = "Twin Val'kyr",
	["Eydis Darkbane"] = "Twin Val'kyr", ["Fjola Lightbane"] = "Twin Val'kyr",
	-- Northrend Beasts
	[34796] = "Northrend Beasts", [35144] = "Northrend Beasts", [34799] = "Northrend Beasts", [34797] = "Northrend Beasts",
	["Gormok the Impaler"] = "Northrend Beasts", ["Acidmaw"] = "Northrend Beasts", ["Dreadscale"] = "Northrend Beasts", ["Icehowl"] = "Northrend Beasts",
}

-- add a boss to the current session (deduped). Shared by the combat-log death
-- path and the loot-confirmation path.
local function addBoss(label, id)
	local cur = db and db._cur
	if not cur or not label or label == "" then return end
	cur.bosses = cur.bosses or {}
	for i = 1, #cur.bosses do
		if cur.bosses[i].name == label then return end -- already logged this session
	end
	cur.bosses[#cur.bosses + 1] = { name = label, id = id, at = time() - cur.start }
	toast("Boss logged: " .. label, "00ddff")
	if OkanvilLogs.Refresh then OkanvilLogs.Refresh() end
end

local function recordBoss(guid, name)
	local id = npcID(guid)
	local known = (id and BOSS_IDS[id]) or (name and BOSSES[name])
	-- Dungeon bosses aren't in the raid list -- but if the Loot module already
	-- recorded a drop from this name, it's a real boss (loot-confirmed). Also
	-- remember recent NPC deaths so a kill can be promoted when its loot arrives.
	if not known then
		if Okanvil.Loot and Okanvil.Loot.SessionHasBoss and Okanvil.Loot.SessionHasBoss(name) then
			known = true
		else
			-- stash as a candidate; loot arriving later promotes it (NoteBossFromLoot)
			if name and name ~= "" and db and db._cur then
				db._cur.recentDeaths = db._cur.recentDeaths or {}
				db._cur.recentDeaths[name] = time() - db._cur.start
			end
			return
		end
	end
	local label = (id and GROUP[id]) or (name and GROUP[name]) or ((name and name ~= "") and name) or ("NPC " .. tostring(id))
	addBoss(label, id)
end

-- Called by the Loot module when it records a drop from `bossName`. If we saw
-- that NPC die this session (recentDeaths), promote it to a logged boss -- this
-- is how dungeon bosses get named without a hardcoded 5-man list.
function OkanvilLogs.NoteBossFromLoot(bossName)
	if not bossName or bossName == "" then return end
	local cur = db and db._cur
	if not cur then return end
	if cur.recentDeaths and cur.recentDeaths[bossName] then
		addBoss(bossName)
	end
end

-- ------------------------------------------------------------
-- "Log this instance?" prompt (shown once on entering an instance)
-- ------------------------------------------------------------
local function askToLog(zone)
	if not askLogF then
		askLogF = CreateFrame("Frame", nil, UIParent)
		askLogF:SetSize(280, 76)
		askLogF:SetPoint("TOP", 0, -120)
		askLogF:SetFrameStrata("FULLSCREEN_DIALOG")
		flat(askLogF, 0.97, true)
		askLogF.txt = newText(askLogF, "OVERLAY")
		askLogF.txt:SetPoint("TOP", 0, -12)
		local yes = flatButton(askLogF, "Start log", 116, 24, "primary")
		yes:SetPoint("BOTTOMLEFT", 12, 12)
		yes:SetScript("OnClick", function()
			askLogF:Hide()
			OkanvilLogs.SetLogging(true)
		end)
		local no = flatButton(askLogF, "|cffff5555No|r", 116, 24)
		no:SetPoint("BOTTOMRIGHT", -12, 12)
		no:SetScript("OnClick", function()
			askLogF:Hide()
		end)
	end
	askLogF.txt:SetText("Log this instance?\n|cffaaaaaa" .. (zone or "") .. "|r")
	PlaySound("UI_BnetToast")
	askLogF:Show()
end

-- ------------------------------------------------------------
-- REC timer (persistent while logging; movable + lockable)
-- ------------------------------------------------------------
local function applyRecLock()
	if not rec then
		return
	end
	rec:EnableMouse(not db.recLocked) -- locked = click-through (no accidental drags mid-fight)
end

local function buildRec()
	if rec then
		return
	end
	local r = CreateFrame("Frame", "OkanvilLogs_Rec", UIParent)
	r:SetSize(160, 26)
	r:SetPoint(db.rec.point, UIParent, db.rec.point, db.rec.x, db.rec.y)
	r:SetFrameStrata("HIGH")
	flat(r, 0.9, true)
	r:SetMovable(true)
	r:RegisterForDrag("LeftButton")
	r:SetScript("OnDragStart", function(s)
		if not db.recLocked then
			s:StartMoving()
		end
	end)
	r:SetScript("OnDragStop", function(s)
		s:StopMovingOrSizing()
		local p, _, _, x, y = s:GetPoint(1)
		db.rec.point, db.rec.x, db.rec.y = p, x, y
	end)
	local dot = newText(r, "OVERLAY")
	dot:SetPoint("LEFT", 9, 0)
	dot:SetText("|cffff3333REC|r")
	r.label = newText(r, "OVERLAY")
	r.label:SetPoint("LEFT", dot, "RIGHT", 6, 0)
	r.label:SetText("0:00")
	-- Stop button: always clickable (even when locked/click-through) to end the session
	local stop = flatButton(r, "|cffff5555Stop|r", 42, 18)
	stop:SetPoint("RIGHT", -4, 0)
	stop:SetScript("OnClick", function()
		OkanvilLogs.SetLogging(false)
	end)
	r:SetScript("OnUpdate", function(s, e)
		-- Modulo desligado = nao forca o LoggingCombat nem mostra o REC ligado.
		if Okanvil.ModuleActive and not Okanvil:ModuleActive(ADDON) then
			s:Hide()
			return
		end
		s._t = (s._t or 0) + e
		if s._t < 0.5 then
			return
		end
		s._t = 0
		if db._cur then
			s.label:SetText(fmtTime(time() - db._cur.start))
			-- live-tick the panel's status sub-line if the page is open
			local pn = OkanvilLogs.panel
			if pn and pn._stSub and pn:IsVisible() then
				local nb = db._cur.bosses and #db._cur.bosses or 0
				pn._stSub:SetText("|cff8a8d93" .. fmtTime(time() - db._cur.start) .. "  |  " .. nb .. " boss" .. (nb == 1 and "" or "es") .. " logged|r")
			end
			-- WATCHDOG: a session is open, but is the client log ACTUALLY on? A zone change,
			-- death or ghost re-enter can silently switch LoggingCombat off while the timer
			-- keeps ticking. Detect that, self-heal, and make it visible.
			if not LoggingCombat() then
				LoggingCombat(true)
				dot:SetText("|cffffaa00REC!|r") -- amber = it had dropped and was re-armed
				if not s._dropped then
					s._dropped = true
					toast("Logging had DROPPED -- re-armed!", "ffaa00")
				end
			else
				dot:SetText("|cffff3333REC|r")
				s._dropped = false
			end
		end
		dot:SetAlpha((math.floor(GetTime() * 1.5) % 2 == 0) and 1 or 0.35) -- blink
	end)
	r:Hide()
	rec = r
	applyRecLock()
end

-- ------------------------------------------------------------
-- start / stop
-- ------------------------------------------------------------
function OkanvilLogs.SetLogging(on)
	buildRec()
	if on then
		if not LoggingCombat() then
			LoggingCombat(true)
		end
		if not db._cur then
			beginSession()
		end
		OkanvilLogs._suppressAuto = nil -- explicit start -> auto-log allowed
		rec:Show()
		toast("REC -- combat log STARTED", "00ff00")
	else
		if LoggingCombat() then
			LoggingCombat(false)
		end
		endSession()
		OkanvilLogs._suppressAuto = true -- explicit stop -> don't auto-restart until you leave the raid
		rec:Hide()
		toast("STOP -- combat log saved", "ff5555")
	end
	if OkanvilLogs.Refresh then
		OkanvilLogs.Refresh()
	end
end

-- ------------------------------------------------------------
-- UI panel -- a native Okanvil module page (Dashboard shell)
-- ------------------------------------------------------------
function OkanvilLogs.BuildUI(host)
	local X = 16
	local W = Okanvil.W

	-- Dashboard shell (MRT/Recruit-style gold header). The logger's own layout
	-- (big Start/Stop, status card, settings, history) draws into dash.main; the
	-- header carries the title + a REC status readout.
	local dash = W.Dashboard(host, {
		title = "Combat Logs",
		icon = Okanvil.ICONS and Okanvil.ICONS.logs or "Interface\\Icons\\INV_Scroll_03",
		drawerWidth = 0,
		footerHeight = 0,
		statusText = function()
			if isLogging() then return "|cffff5555REC|r |cff8a8d93logging|r" end
			return "|cff8a8d93idle|r"
		end,
	})
	local parent = dash.main
	OkanvilLogs._dash = dash
	OkanvilLogs.panel = parent   -- RebuildHistory/Refresh read _hist* off this frame

	-- ---- Row 1: big Start/Stop CTA (left) + live status card (right) ----
	local toggle = flatButton(parent, "", 190, 46, "primary")
	toggle:SetPoint("TOPLEFT", X, -16)
	toggle:SetScript("OnClick", function()
		OkanvilLogs.SetLogging(not isLogging())
	end)
	parent._toggle = toggle

	-- status card: shows REC state + elapsed while a session is open
	local status = W.Frame(parent, "dark")
	status:SetPoint("TOPLEFT", toggle, "TOPRIGHT", 10, 0)
	status:SetPoint("RIGHT", parent, "RIGHT", -14, 0)
	status:SetHeight(46)
	local stTop = newText(status, "OVERLAY")
	stTop:SetPoint("TOPLEFT", 12, -8)
	local stSub = newText(status, "OVERLAY", 10)
	stSub:SetPoint("BOTTOMLEFT", 12, 8)
	parent._stTop, parent._stSub = stTop, stSub

	-- ---- Row 2/3: settings cards (label left, pill right -- no clipping) ----
	local c1 = cardToggle(parent, "Ask to log when entering a raid",
		"Pops a Start log / No prompt on the first raid zone-in. Dungeons never prompt.",
		function() return db.askOnEnter end,
		function(v) db.askOnEnter = v end)
	c1:SetPoint("TOPLEFT", X, -74)
	c1:SetPoint("RIGHT", parent, "RIGHT", -14, 0)

	local c2 = cardToggle(parent, "Lock REC timer (click-through)",
		"Stops accidental drags mid-fight. Stop still works.",
		function() return db.recLocked end,
		function(v) db.recLocked = v; applyRecLock() end)
	c2:SetPoint("TOPLEFT", X, -122)
	c2:SetPoint("RIGHT", parent, "RIGHT", -14, 0)

	local hint = newText(parent, "OVERLAY", 11)
	hint:SetPoint("TOPLEFT", X, -172)
	hint:SetPoint("RIGHT", parent, "RIGHT", -14, 0)
	hint:SetJustifyH("LEFT")
	hint:SetText(
		"|cff6f7176Logging writes to WoWCombatLog.txt -- slice/export it with the desktop tool. Bosses that drop loot are named automatically.|r"
	)

	-- ---- live "this session" boss list (only while a session is open) ----
	-- Its header+list live in a container we can hide/collapse; PAST SESSIONS
	-- and the scroll re-anchor under it so there is no dead space when idle.
	local live = CreateFrame("Frame", nil, parent)
	live:SetPoint("TOPLEFT", X, -200)
	live:SetPoint("RIGHT", parent, "RIGHT", -14, 0)
	live:SetHeight(20)
	local blbl = newText(live, "OVERLAY")
	blbl:SetPoint("TOPLEFT", 0, 0)
	blbl:SetText("|cffffd200THIS SESSION|r")
	parent._blbl = blbl
	local blist = newText(live, "OVERLAY")
	blist:SetPoint("TOPLEFT", 0, -18)
	blist:SetWidth(420); blist:SetJustifyH("LEFT"); blist:SetJustifyV("TOP")
	parent._blist = blist
	parent._live = live

	-- ---- session history: a scrollable, inline-expandable list ----
	-- Anchored just below the live block (which collapses to 0 height when idle).
	local hh = newText(parent, "OVERLAY")
	hh:SetPoint("TOPLEFT", live, "BOTTOMLEFT", 0, -14)
	hh:SetText("|cff8a8d93PAST SESSIONS|r")
	parent._histHdr = hh

	-- flat scroll (no Blizzard template): plain ScrollFrame + our own slider
	local sf = CreateFrame("ScrollFrame", nil, parent)
	sf:SetPoint("TOPLEFT", hh, "BOTTOMLEFT", 0, -8); sf:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -14, 8)
	local child = CreateFrame("Frame", nil, sf); child:SetSize(10, 1); sf:SetScrollChild(child)
	local sb = CreateFrame("Slider", nil, parent)
	sb:SetPoint("TOPRIGHT", sf, "TOPRIGHT", 8, 0); sb:SetPoint("BOTTOMRIGHT", sf, "BOTTOMRIGHT", 8, 0); sb:SetWidth(4)
	sb:SetOrientation("VERTICAL"); sb:SetValueStep(1)
	local th = sb:CreateTexture(nil, "OVERLAY"); th:SetTexture(FLAT); th:SetSize(4, 40)
	do local a = Okanvil.Colors.accent; th:SetVertexColor(a[1], a[2], a[3], 1) end
	sb:SetThumbTexture(th)
	sb:SetScript("OnValueChanged", function(_, v) sf:SetVerticalScroll(v) end)
	sf:EnableMouseWheel(true)
	sf:SetScript("OnMouseWheel", function(_, d) sb:SetValue(sb:GetValue() - d * 30) end)
	sf:SetScript("OnSizeChanged", function() child:SetWidth(sf:GetWidth()) end)
	parent._histSF, parent._histChild, parent._histSB = sf, child, sb
	parent._histRows, parent._histDetail = {}, {}
	parent._expanded = nil

	OkanvilLogs.Refresh()
	OkanvilLogs.RebuildHistory()
end

-- build the past-sessions list (rows + inline expansion), like the Loot tab.
function OkanvilLogs.RebuildHistory()
	local p = OkanvilLogs.panel
	if not p or not p._histChild then return end
	local W = Okanvil.W
	local child = p._histChild
	for _, r in ipairs(p._histRows) do r:Hide() end
	for _, t in ipairs(p._histDetail) do t:Hide() end
	local sessions = (db and db.sessions) or {}

	if #sessions == 0 then
		p._histEmpty = p._histEmpty or newText(child, "OVERLAY")
		p._histEmpty:SetPoint("TOPLEFT", 2, -4)
		p._histEmpty:SetText("|cff888888No past sessions yet. Start a log and kill a boss.|r")
		p._histEmpty:Show()
		child:SetHeight(30)
		return
	end
	if p._histEmpty then p._histEmpty:Hide() end

	local di, y = 0, 0
	for i, s in ipairs(sessions) do
		local r = p._histRows[i]
		if not r then
			r = W.Frame(child, "input")
			r.title = newText(r, "OVERLAY"); r.title:SetPoint("TOPLEFT", 8, -5)
			r.sub = newText(r, "OVERLAY", 10); r.sub:SetPoint("BOTTOMLEFT", 8, 5)
			r.del = W.Button(r, "X", "danger")
			r.del:SetSize(22, 20); r.del:SetPoint("RIGHT", -6, 0)
			r:EnableMouse(true)
			p._histRows[i] = r
		end
		r:ClearAllPoints(); r:SetPoint("TOPLEFT", 0, -y); r:SetPoint("RIGHT", child, "RIGHT", 0, 0); r:SetHeight(38)
		local where = (s.zone ~= "" and s.zone) or "World"
		local dateStr = date("%b %d  %H:%M", s.start)
		local dur = (s.stop and s.stop > s.start) and fmtTime(s.stop - s.start) or "?"
		local nb = s.bosses and #s.bosses or 0
		local isOpen = (p._expanded == s)
		r.title:SetText((isOpen and "|cffffd200v|r  " or "|cff8a8d93>|r  ") .. where)
		r.sub:SetText("|cff8a8d93" .. dateStr .. "  |  " .. dur .. "  |  " .. nb .. " boss" .. (nb == 1 and "" or "es") .. "|r")
		local function toggle()
			if p._expanded == s then p._expanded = nil else p._expanded = s end
			OkanvilLogs.RebuildHistory()
		end
		r:SetScript("OnMouseUp", toggle)
		r.del:SetScript("OnClick", function()
			if p._expanded == s then p._expanded = nil end
			OkanvilLogs.DeleteSession(s)
		end)
		r:Show()
		y = y + 44

		if isOpen then
			di = di + 1
			local t = p._histDetail[di]
			if not t then t = newText(child, "OVERLAY"); t:SetJustifyH("LEFT"); t:SetJustifyV("TOP"); p._histDetail[di] = t end
			t:ClearAllPoints(); t:SetPoint("TOPLEFT", 14, -y); t:SetPoint("RIGHT", child, "RIGHT", -8, 0)
			if s.bosses and #s.bosses > 0 then
				local lines = {}
				for k = 1, #s.bosses do
					lines[k] = string.format("|cff66dd66+|r %s  |cff888888%s|r", s.bosses[k].name, fmtTime(s.bosses[k].at or 0))
				end
				t:SetText(table.concat(lines, "\n"))
			else
				t:SetText("|cff888888No bosses recorded this session.|r")
			end
			t:Show()
			y = y + (t:GetStringHeight() or 12) + 10
		end
	end
	child:SetHeight(math.max(1, y))
	local maxs = math.max(0, y - p._histSF:GetHeight())
	p._histSB:SetMinMaxValues(0, maxs); p._histSB:SetShown(maxs > 4)
end

function OkanvilLogs.Refresh()
	if OkanvilLogs._dash then OkanvilLogs._dash:Refresh() end   -- header REC status
	local p = OkanvilLogs.panel
	if not p or not p._toggle then
		return
	end
	if isLogging() then
		p._toggle.text:SetText("STOP logging")
	else
		p._toggle.text:SetText("START logging")
	end
	-- status card (right of the CTA)
	if p._stTop then
		local cur = db and db._cur
		if cur then
			p._stTop:SetText("|cffff3333REC|r  |cffdcddde" .. ((cur.zone ~= "" and cur.zone) or "World") .. "|r")
			local nb = cur.bosses and #cur.bosses or 0
			p._stSub:SetText("|cff8a8d93" .. fmtTime(time() - cur.start) .. "  |  " .. nb .. " boss" .. (nb == 1 and "" or "es") .. " logged|r")
		else
			p._stTop:SetText("|cff8a8d93Not logging|r")
			p._stSub:SetText("|cff6f7176Press START to begin a session.|r")
		end
	end
	if p._blist then
		local cur = db and db._cur
		if cur then
			if p._blbl then p._blbl:Show() end
			if p._live then p._live:Show() end
			local list = cur.bosses
			local n = list and #list or 0
			if n > 0 then
				local lines = {}
				for i = 1, n do
					lines[i] = string.format("|cff66dd66+|r %s  |cff888888%s|r", list[i].name, fmtTime(list[i].at or 0))
				end
				p._blist:SetText(table.concat(lines, "\n"))
			else
				p._blist:SetText("|cff888888Recording... boss kills appear here as they happen.|r")
			end
			-- grow the live block so PAST SESSIONS sits below it
			if p._live then
				local h = 18 + (p._blist:GetStringHeight() or 12) + 6
				p._live:SetHeight(math.max(20, h))
			end
		else
			-- no open session: COLLAPSE the live block so the history list pulls
			-- right up under the hint (no dead space).
			if p._blbl then p._blbl:Hide() end
			p._blist:SetText("")
			if p._live then p._live:SetHeight(1); p._live:Hide() end
		end
	end
	if OkanvilLogs.RebuildHistory then OkanvilLogs.RebuildHistory() end
end

-- ------------------------------------------------------------
-- events / boot
-- ------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_REGEN_DISABLED") -- entered combat -> guarantee the raid is being logged
ev:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED") -- watch for boss deaths to list them per session
ev:SetScript("OnEvent", function(_, event, arg1, ...)
	if event == "COMBAT_LOG_EVENT_UNFILTERED" then
		-- Modulo Combat Logs DESLIGADO = nao regista nada (como se nao existisse).
		if Okanvil.ModuleActive and not Okanvil:ModuleActive(ADDON) then return end
		-- cheap early-out unless a session is active; arg1 = timestamp, ... = subevent, src*, dest*
		if not db or not db._cur then
			return
		end
		if ... == "UNIT_DIED" then
			recordBoss(select(5, ...), select(6, ...)) -- destGUID, destName
		end
		return
	end
	if event == "ADDON_LOADED" and arg1 == "Okanvil" then -- native module: host's load
		OkanvilLogsDB = OkanvilLogsDB or {}
		for k, v in pairs(defaults) do
			if OkanvilLogsDB[k] == nil then
				OkanvilLogsDB[k] = (type(v) == "table") and {} or v
				if type(v) == "table" then
					for kk, vv in pairs(v) do
						OkanvilLogsDB[k][kk] = vv
					end
				end
			end
		end
		db = OkanvilLogsDB
		-- NOTE: we intentionally KEEP db._cur across reload/relog. A session stays
		-- open until the user hits Stop, so PLAYER_ENTERING_WORLD can resume the
		-- client log (reload/teleport turn it off) without losing or splitting it.
	elseif event == "PLAYER_LOGIN" then
		buildRec()
		-- native module: register into the host (toggle in Modules to hide it)
		Okanvil_Plugins = Okanvil_Plugins or {}
		Okanvil_Plugins[ADDON] = {
			title = "Combat Logs",
			desc = "Combat-log control, REC timer and session tracker.",
			icon = (Okanvil and Okanvil.ICONS and Okanvil.ICONS.logs) or "Interface\\Icons\\INV_Scroll_03",
			build = function(panel)
				OkanvilLogs.panel = panel
				OkanvilLogs.BuildUI(panel)
			end,
			refresh = function()
				OkanvilLogs.Refresh()
			end,
		}
		if Okanvil and Okanvil.Register then
			Okanvil:Register(ADDON)
			Print("loaded. |cff00ff00/oklog|r toggles logging.")
		end
	elseif event == "PLAYER_ENTERING_WORLD" then
		if not db then
			return
		end
		-- Modulo desligado = nao faz auto-resume nem pergunta para gravar.
		if Okanvil.ModuleActive and not Okanvil:ModuleActive(ADDON) then return end
		local inInstance, itype = IsInInstance()
		if db._cur then
			-- Session still open: a /reload, relog or in-instance teleport turns the
			-- client log back OFF. Silently RESUME -- never reset, never split, never re-ask.
			if not LoggingCombat() then
				buildRec()
				LoggingCombat(true)
				rec:Show()
				toast("REC -- resumed (still logging)", "00ff00")
			end
		elseif inInstance and itype == "raid" and not LoggingCombat() then
			-- No active session and we just entered a RAID: ask once per zone. We only
			-- prompt for raids -- 5-man dungeon combat logs are rarely wanted, so they
			-- never nag (start those by hand with the Combat Logs page if needed).
			local zone = GetRealZoneText()
			if not zone or zone == "" then
				zone = GetZoneText()
			end
			if db.askOnEnter and zone ~= askedZone then
				askedZone = zone
				askToLog(zone)
			elseif db.autoLog then
				OkanvilLogs.SetLogging(true) -- legacy silent auto-log (askOnEnter off)
			end
		elseif not inInstance then
			askedZone = nil -- left the instance -> allow asking again on next entry
			OkanvilLogs._suppressAuto = nil -- left the raid -> auto-log may kick in again next time
		end
	elseif event == "PLAYER_REGEN_DISABLED" then
		-- Modulo desligado = nao inicia logging automatico ao entrar em combate.
		if Okanvil.ModuleActive and not Okanvil:ModuleActive(ADDON) then return end
		-- Entered combat: guarantee a raid pull is always being logged.
		if db then
			if db._cur then
				if not LoggingCombat() then LoggingCombat(true) end -- keep an open session truly ON
			else
				local inInstance, itype = IsInInstance()
				if inInstance and itype == "raid" and not OkanvilLogs._suppressAuto then
					OkanvilLogs.SetLogging(true) -- safety net: never miss a raid boss again
				end
			end
		end
	end
end)

-- ------------------------------------------------------------
-- slash
-- ------------------------------------------------------------
SLASH_OkanvilLOGS1 = "/oklog"
SlashCmdList["OkanvilLOGS"] = function(arg)
	arg = string.lower(arg or "")
	if arg == "on" then
		OkanvilLogs.SetLogging(true)
	elseif arg == "off" then
		OkanvilLogs.SetLogging(false)
	elseif Okanvil and Okanvil.Toggle then
		Okanvil:Toggle() -- open the Okanvil window (Combat Logs is a module in it)
	else
		Print("Okanvil host not loaded.")
	end
end
