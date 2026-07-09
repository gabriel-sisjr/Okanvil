-- ============================================================
-- Recruit  (WotLK 3.3.5a)
-- Generic guild-recruitment advertiser: auto-advertise + auto-reply
-- (AFK mode) + auto-invite, keyword + known-contact filters.
-- Guild name is configurable (default "Guild"); use {guild} in any
-- message and it is replaced with the guild name at send time.
-- Dashboard UI: Text / Settings / Filters tabs + a contacts drawer.
-- A native Okanvil module (no standalone window / minimap).
-- ============================================================

-- Native Okanvil module (lives in the host folder). ADDON is only the module
-- key registered in Okanvil_Plugins / IsModuleEnabled -- NOT a separate addon.
local ADDON = "Okanvil-Recruit"
local FLAT = "Interface\\ChatFrame\\ChatFrameBackground"
local G = Okanvil.Guild

-- ------------------------------------------------------------
-- Saved-variable defaults -- NO pre-filled text (the user inserts it all).
-- ------------------------------------------------------------
local defaults = {
	guildName = "Guild", -- used by the {guild} token and the join toast
	message = "",
	reply = "",
	afkReply = "",
	afkMode = false,
	keywords = "",
	replyCooldown = 600,
	inviteCooldown = 300,
	active = false,
	autoInvite = true,
	toastOnJoin = true, -- pop a toast when someone joins the guild
	toastOnlyActive = false, -- ...only while advertising is ON (false = always)
	filterGuild = true,
	filterGroup = true,
	filterFriends = true,
	-- per-channel spam interval in seconds (0 = off). All off by default.
	channelIntervals = { Global = 0, LookingForGroup = 0, General = 0 },
	customChannel = "",
	customInterval = 0,
	blacklist = "", -- block words (gold sellers / ads); user fills it in
	log = {},
	session = {}, -- per-name recruiting tally (uncapped); cleared from the Summary tab
}

local db
local chElapsed = {} -- per-channel advertise timer accumulators
local recentInvites = {}
local repliedTo = {}

-- ------------------------------------------------------------
-- Helpers
-- ------------------------------------------------------------
local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cffF1C40F[Recruit]|r " .. tostring(msg))
end

-- guild name with a safe fallback (never empty)
local function gname()
	return (db and db.guildName and db.guildName ~= "" and db.guildName) or "Guild"
end

-- replace the {guild} token with the configured guild name
local function brand(s)
	if not s or s == "" then
		return s
	end
	return (s:gsub("{guild}", gname()))
end

local function stripRealm(name)
	if not name then
		return name
	end
	local n = strsplit("-", name)
	return n
end

-- best-effort real class lookup (self / group / guild roster); nil if unknown
local function resolveClass(name)
	if not name or name == "" then
		return nil
	end
	if name == UnitName("player") then
		return select(2, UnitClass("player"))
	end
	local raidN = (GetNumRaidMembers and GetNumRaidMembers()) or 0
	if raidN > 0 then
		for i = 1, raidN do
			if UnitName("raid" .. i) == name then
				return select(2, UnitClass("raid" .. i))
			end
		end
	else
		local partyN = (GetNumPartyMembers and GetNumPartyMembers()) or 0
		for i = 1, partyN do
			if UnitName("party" .. i) == name then
				return select(2, UnitClass("party" .. i))
			end
		end
	end
	local m = G.FindMember(name)
	if m then return m.classToken end
	return nil
end

-- skip people we already know / are playing with (toggle each in Filters tab)
local function isKnownContact(name)
	if not name then
		return false
	end
	if db.filterGroup then
		local raidN = (GetNumRaidMembers and GetNumRaidMembers()) or 0
		if raidN > 0 then
			for i = 1, raidN do
				if UnitName("raid" .. i) == name then
					return true
				end
			end
		else
			local partyN = (GetNumPartyMembers and GetNumPartyMembers()) or 0
			for i = 1, partyN do
				if UnitName("party" .. i) == name then
					return true
				end
			end
		end
	end
	if db.filterFriends then
		local nf = (GetNumFriends and GetNumFriends()) or 0
		for i = 1, nf do
			local fname = GetFriendInfo(i)
			if fname then
				fname = strsplit("-", fname)
				if fname == name then
					return true
				end
			end
		end
	end
	if db.filterGuild and G.FindMember(name) then
		return true
	end
	return false
end

-- is this name currently in MY guild? (used to hide the re-invite button)
local function isInMyGuild(name)
	return G.FindMember(name) ~= nil
end

-- parse guild join/decline system messages to track an invite's outcome
local function makePattern(fmt)
	local p = fmt:gsub("[%(%)%.%+%-%*%?%[%]%^%$]", "%%%0")
	return (p:gsub("%%s", "(.+)"))
end
local PAT_JOIN = ERR_GUILD_JOIN_S and makePattern(ERR_GUILD_JOIN_S)
local PAT_DECLINE = ERR_GUILD_DECLINE_S and makePattern(ERR_GUILD_DECLINE_S)
local PAT_FAILS = {}
do
	local function addFail(g)
		if g and g:find("%%s") then
			PAT_FAILS[#PAT_FAILS + 1] = makePattern(g)
		end
	end
	addFail(ERR_ALREADY_IN_GUILD_S)
	addFail(ERR_ALREADY_INVITED_TO_GUILD_S)
end
local PAT_OFFLINE = ERR_GUILD_PLAYER_NOT_FOUND_S
	and ERR_GUILD_PLAYER_NOT_FOUND_S:find("%%s")
	and makePattern(ERR_GUILD_PLAYER_NOT_FOUND_S)
local PAT_FRIEND_ONLINE = ERR_FRIEND_ONLINE_SS and makePattern(ERR_FRIEND_ONLINE_SS)

local function setInviteState(name, state)
	db.session[name] = db.session[name] or {}
	db.session[name].state = state
	for i = 1, #db.log do
		local e = db.log[i]
		if e.who == name then
			e.state = state
			break
		end
	end
	if RecruitFrame and RecruitFrame.logPanel and RecruitFrame.logPanel:IsShown() then
		Rec_RefreshLog()
	end
end

-- resolve a configured channel name to the numeric id THIS player has for it.
local function resolveChannelId(name)
	if not name or name == "" then
		return nil
	end
	local asNum = tonumber(name)
	if asNum then
		return asNum
	end
	local id = GetChannelName(name)
	if id and id > 0 then
		return id
	end
	local list = { GetChannelList() } -- id1, name1, id2, name2, ...
	local target = name:lower()
	for i = 1, #list - 1, 2 do -- exact match first
		if type(list[i + 1]) == "string" and list[i + 1]:lower() == target then
			return list[i]
		end
	end
	for i = 1, #list - 1, 2 do -- then prefix ("General" -> "General - Dalaran")
		if type(list[i + 1]) == "string" and list[i + 1]:lower():find(target, 1, true) == 1 then
			return list[i]
		end
	end
	return nil
end

local function SendToChannel(name, msg)
	if not name or not msg or msg == "" then
		return
	end
	if name == "GUILD" then
		SendChatMessage(msg, "GUILD")
		return
	end
	local id = resolveChannelId(name)
	if id and id > 0 then
		SendChatMessage(msg, "CHANNEL", nil, id)
	end
end

-- ------------------------------------------------------------
-- Core engine
-- ------------------------------------------------------------
local core = CreateFrame("Frame")

core:SetScript("OnUpdate", function(self, e)
	if not db or not db.active then
		return
	end
	if not db.message or db.message == "" then
		return -- nothing to advertise until the user writes a message
	end
	-- each channel advertises on its own interval (staggered)
	for name, iv in pairs(db.channelIntervals) do
		if iv and iv > 0 then
			chElapsed[name] = (chElapsed[name] or 0) + e
			if chElapsed[name] >= iv then
				chElapsed[name] = 0
				SendToChannel(name, brand(db.message))
			end
		end
	end
	if db.customChannel ~= "" and (db.customInterval or 0) > 0 then
		chElapsed.__custom = (chElapsed.__custom or 0) + e
		if chElapsed.__custom >= db.customInterval then
			chElapsed.__custom = 0
			SendToChannel(db.customChannel, brand(db.message))
		end
	end
end)

core:RegisterEvent("ADDON_LOADED")
core:RegisterEvent("PLAYER_LOGIN")
core:RegisterEvent("CHAT_MSG_WHISPER")
core:RegisterEvent("CHAT_MSG_SYSTEM")

core:SetScript("OnEvent", function(self, event, arg1, arg2)
	-- Recruit is now a NATIVE module of Okanvil (it lives in the host folder and is
	-- loaded by Okanvil.toc, so Okanvil.W is always present). It initialises on the
	-- HOST's ADDON_LOADED -- there's no separate "Okanvil-Recruit" addon anymore.
	if event == "ADDON_LOADED" and arg1 == "Okanvil" then
		RecruitDB = RecruitDB or {}
		for k, v in pairs(defaults) do
			if RecruitDB[k] == nil then
				if type(v) == "table" then
					RecruitDB[k] = {}
					for kk, vv in pairs(v) do
						RecruitDB[k][kk] = vv
					end
				else
					RecruitDB[k] = v
				end
			end
		end
		db = RecruitDB
		db.active = false
		if GuildRoster then
			GuildRoster()
		end
		-- register as a Okanvil plugin (Okanvil builds it lazily into its panel)
		Okanvil_Plugins = Okanvil_Plugins or {}
		Okanvil_Plugins[ADDON] = {
			title = "Recruit",
			desc = "Recruitment/pug advertiser with auto-reply and auto-invite. For officers & pug leaders.",
			icon = "Interface\\Icons\\Ability_Warrior_BattleShout",
			build = function(panel)
				Rec_BuildUI(panel)
			end,
			refresh = function()
				Rec_RefreshUI()
			end,
		}
		return
	end

	if event == "PLAYER_LOGIN" then
		if not db then
			return
		end
		-- native module: always hosted. Okanvil builds the UI lazily when you open
		-- the Recruit tab (and Modules lets you toggle it off).
		if Okanvil and Okanvil.Register then
			Okanvil:Register(ADDON)
			Print("loaded. |cff00ff00/recruit|r opens it.")
		end
		return
	end

	-- Modulo Recruit DESLIGADO = nao responde a whispers nem reage a chat.
	if Okanvil.ModuleActive and not Okanvil:ModuleActive(ADDON) then return end

	if event == "CHAT_MSG_WHISPER" then
		if not db.active then
			return -- only act / log while advertising is ON
		end
		local msg, sender = arg1, arg2
		if not sender then
			return
		end
		local clean = stripRealm(sender)
		local brandedReply, brandedAfk = brand(db.reply), brand(db.afkReply)
		if msg == brandedReply or msg == brandedAfk then
			return -- ignore our own auto-reply echoing back
		end
		if isKnownContact(clean) then
			return -- guildies / party / friends: ignore entirely
		end

		local ctx = {
			known = false,
			now = GetTime(),
			lastInvite = recentInvites[clean],
			lastReply = repliedTo[clean],
			isEcho = (msg == brandedReply or msg == brandedAfk),
		}
		local decision = RecruitLogic.decide(db, msg, ctx)
		local sentReply, didInvite = nil, false
		if decision.invite then
			recentInvites[clean] = ctx.now
			GuildInvite(clean)
			didInvite = true
			Print("Guild-invited |cff00ff00" .. clean .. "|r.")
		end
		if decision.reply then
			repliedTo[clean] = ctx.now
			sentReply = brand(decision.reply)
			SendChatMessage(sentReply, "WHISPER", nil, sender)
		end

		db.session[clean] = db.session[clean] or {}
		if didInvite then
			db.session[clean].invited = true
		end
		if sentReply then
			db.session[clean].replied = true
		end

		local classFile = resolveClass(clean)
		table.insert(db.log, 1, { who = clean, msg = msg or "", inv = didInvite, state = (didInvite and "sent" or nil), reply = sentReply, class = classFile, t = date("%H:%M"), ts = time() })
		while #db.log > 50 do
			table.remove(db.log)
		end
		if RecruitFrame and RecruitFrame.logPanel and RecruitFrame.logPanel:IsShown() then
			Rec_RefreshLog()
		end
	end

	if event == "CHAT_MSG_SYSTEM" and db then
		local m = arg1 or ""
		if PAT_JOIN then
			local who = m:match(PAT_JOIN)
			if who then
				who = stripRealm(who)
				setInviteState(who, "joined")
				if db.toastOnJoin and (not db.toastOnlyActive or db.active) then
					Rec_ShowToast(who, resolveClass(who))
				end
				return
			end
		end
		if PAT_DECLINE then
			local who = m:match(PAT_DECLINE)
			if who then
				setInviteState(stripRealm(who), "declined")
				return
			end
		end
		if PAT_OFFLINE then
			local who = m:match(PAT_OFFLINE)
			if who then
				setInviteState(stripRealm(who), "offline")
				return
			end
		end
		if PAT_FRIEND_ONLINE then
			local who = m:match(PAT_FRIEND_ONLINE)
			if who then
				who = stripRealm(who)
				local s = db.session[who]
				if s and s.watch then
					s.watch = nil
					Rec_ShowToast(who, resolveClass(who), "|cff66ddffOnline now -- re-invite!|r")
				end
				return
			end
		end
		for _, p in ipairs(PAT_FAILS) do
			local who = m:match(p)
			if who then
				setInviteState(stripRealm(who), "failed")
				return
			end
		end
	end
end)

function Rec_ToggleActive(state)
	if state == nil then
		state = not db.active
	end
	db.active = state
	chElapsed = {}
	if db.active then
		-- MUTUAL EXCLUSION with the Invite module's keyword-invite: both grab the
		-- same "inv" whisper, so only one runs. Turning Recruit ON stands it down.
		if Okanvil and Okanvil.Invite and Okanvil.Invite.KeywordEnabled
			and Okanvil.Invite.KeywordEnabled() then
			Okanvil.Invite.SetKeywordEnabled(false)
			Print("Invite keyword-invite turned OFF (can't share the invite keyword).")
		end
		local i = 0
		for name, iv in pairs(db.channelIntervals) do
			if iv and iv > 0 then
				i = i + 1
				chElapsed[name] = -(i - 1) * 5
			end
		end
	end
	if RecruitFrame then
		Rec_RefreshUI()
	end
	if db.active then
		Print("advertising |cff00ff00ON|r.")
	else
		Print("advertising |cffff5555OFF|r.")
	end
end

-- ============================================================
-- UI
-- ============================================================
local CH_LIST = { "Global", "LookingForGroup", "General" }

local CLASS_COLORS = {
	DEATHKNIGHT = "C41F3B",
	DRUID = "FF7D0A",
	HUNTER = "ABD473",
	MAGE = "69CCF0",
	PALADIN = "F58CBA",
	PRIEST = "FFFFFF",
	ROGUE = "FFF569",
	SHAMAN = "0070DE",
	WARLOCK = "9482C9",
	WARRIOR = "C79C6E",
}
local function nameColor(name, classFile)
	return "|cff" .. ((classFile and CLASS_COLORS[classFile]) or "F1C40F")
end

-- ---- UI helpers: prefer the shared Okanvil.W widgets (gold design system);
-- UI helpers: thin wrappers over the shared Okanvil.W widget layer (the host is
-- always present -- this is a native module, no standalone).
local W = Okanvil.W

-- flat panel backdrop for the few floating frames (toast) that live on UIParent,
-- not inside a W.Dashboard. Extra args are ignored -- Okanvil:Skin owns the look.
local function flatBackdrop(frame) Okanvil:Skin(frame, "input") end

local function makeLabel(parent, text, x, y)
	local fs = W.Text(parent, text, nil, "dim")
	fs:SetPoint("TOPLEFT", x, y)
	return fs
end

-- single-line edit box; returns the EditBox (with .bd = the bordered frame) so
-- existing call-sites (SetText/GetText/hooks) keep working.
local function makeBox(parent, name, x, y, w, h)
	local box = W.EditBox(parent)
	box:SetSize(w, h); box:SetPoint("TOPLEFT", x, y)
	local e = box.edit
	e.bd = box
	return e
end

-- responsive multi-line box: stretches to the parent's right edge (minus rightMargin)
local function makeScrollBox(parent, name, x, y, rightMargin, h)
	local box = W.MultiEdit(parent)
	box:SetPoint("TOPLEFT", x, y)
	box:SetPoint("RIGHT", parent, "RIGHT", -(rightMargin or 12), 0)
	box:SetHeight(h)
	local e = box.edit
	e.bd = box
	return e
end

-- checkbox bound to a db key; W.Check reads/writes via getFn/setFn. onChange(v)
-- runs after a toggle. Returns a frame with SetChecked/GetChecked shims so the
-- existing Rec_RefreshUI (which calls :SetChecked) keeps working.
local function makeCheck(parent, key, label, x, y, onChange)
	local c = W.Check(parent, label,
		function() return db[key] end,
		function(v) db[key] = v and true or false; if onChange then onChange(v) end end)
	c:SetPoint("TOPLEFT", x, y)
	c.SetChecked = function(_, v) db[key] = v and true or false; c.refresh() end
	c.GetChecked = function() return db[key] end
	return c
end

-- shared gold RATS-Hub button (honours ._active for tab highlighting)
local function makeFlatButton(parent, text, w, h, kind)
	local b = W.Button(parent, text, kind)
	b:SetSize(w, h)
	return b
end

local function numHook(box, key, lo, hi)
	box:SetScript("OnEditFocusLost", function(s)
		local v = tonumber(s:GetText())
		if v then
			db[key] = math.max(lo, math.min(hi, math.floor(v)))
		end
		s:SetText(db[key])
		if s.bd then
			s.bd:SetBackdropBorderColor(0.4, 0.4, 0.45, 1)
		end
	end)
end

local function strHook(box, key)
	box:SetScript("OnEditFocusLost", function(s)
		db[key] = (s:GetText() or ""):gsub("\n", " ")
		if s.bd then
			s.bd:SetBackdropBorderColor(0.4, 0.4, 0.45, 1)
		end
	end)
end

-- ============================================================
-- "New member!" toast -- pops when someone joins the guild
-- ============================================================
local toast
local function Rec_ApplyToastPoint()
	if not toast then
		return
	end
	toast:ClearAllPoints()
	local p = db.toastPoint
	if p and p.point then
		toast:SetPoint(p.point, UIParent, p.relPoint or p.point, p.x or 0, p.y or 0)
	else
		toast:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -20, -180)
	end
end

local function Rec_BuildToast()
	if toast then
		return
	end
	local t = CreateFrame("Frame", "Recruit_Toast", UIParent)
	t:SetSize(236, 56)
	t:SetFrameStrata("FULLSCREEN_DIALOG")
	flatBackdrop(t, 0.09, 0.09, 0.11, 0.96, 0.85, 0.66, 0.2)
	t:EnableMouse(true)
	t:SetMovable(true)
	t:RegisterForDrag("LeftButton")
	t:SetScript("OnMouseDown", function(self)
		if not self.unlocked then
			self:Hide()
		end
	end)
	t:SetScript("OnDragStart", function(self)
		if self.unlocked then
			self:StartMoving()
		end
	end)
	t:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint(1)
		db.toastPoint = { point = point, relPoint = relPoint, x = x, y = y }
	end)
	t:Hide()

	local icon = t:CreateTexture(nil, "ARTWORK")
	icon:SetSize(38, 38)
	icon:SetPoint("LEFT", 9, 0)
	icon:SetTexture("Interface\\Icons\\Ability_Warrior_BattleShout")
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	local top = t:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	top:SetPoint("TOPLEFT", icon, "TOPRIGHT", 10, -4)
	t.top = top

	local bottom = t:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	bottom:SetPoint("TOPLEFT", top, "BOTTOMLEFT", 0, -4)
	t.bottom = bottom

	t:SetScript("OnUpdate", function(self, e)
		if self.unlocked then
			return
		end
		self.life = (self.life or 0) - e
		if self.life <= 0 then
			self:Hide()
		elseif self.life < 1 then
			self:SetAlpha(self.life)
		end
	end)
	toast = t
	Rec_ApplyToastPoint()
end

function Rec_ShowToast(name, classFile, title)
	if not name then
		return
	end
	Rec_BuildToast()
	if toast.unlocked then
		return
	end
	toast.top:SetText(title or ("|cffF1C40FNew member joined " .. gname() .. "!|r"))
	toast.bottom:SetText(nameColor(name, classFile) .. name .. "|r")
	toast:SetAlpha(1)
	toast.life = 5
	toast:Show()
	PlaySound("UI_BnetToast")
end

function Rec_SetToastMove(on)
	Rec_BuildToast()
	toast.unlocked = on
	if on then
		toast.top:SetText("|cffF1C40FToast preview|r")
		toast.bottom:SetText("|cff00ff00drag me, untick to lock|r")
		toast:SetAlpha(1)
		toast:Show()
		Print("Toast |cff00ff00unlocked|r -- drag it where you want, then untick to lock.")
	else
		toast:Hide()
		Print("Toast position |cffffcc00locked|r.")
	end
end

function Rec_BuildUI(parent)
	if RecruitFrame then
		return
	end

	-- Okanvil always gives us a content panel (it owns the window chrome).
	local f = parent
	RecruitFrame = f

	-- content region: everything below draws through a shared Dashboard shell
	-- (header + toggleable contacts drawer + config overlays). The X offset just
	-- pads inside each fill frame.
	local X = 4

	local afkTag = function() return db.afkMode and "  |cff88aaff(AFK reply active)|r" or "" end
	local dash = W.Dashboard(f, {
		title = "Recruit",
		icon = "Interface\\Icons\\Ability_Warrior_BattleShout",
		drawerWidth = 190,
		drawerLabel = "contacts",
		footerHeight = 0, -- no footer strip; contacts live in the right drawer now
		primaryText = function() return db.active and "STOP advertising" or "START advertising" end,
		onPrimary = function() Rec_ToggleActive() end,
		statusText = function()
			if db.active then return "|cff7cfc8aAdvertising ON|r" .. afkTag() end
			return "|cffff5555Advertising OFF|r" .. afkTag()
		end,
		tabs = {
			{ key = "text",     label = "Text",     height = 360, build = function(p) Rec_BuildText(p) end },
			{ key = "settings", label = "Settings", height = 420, build = function(p) Rec_BuildSettings(p) end },
			{ key = "filters",  label = "Filters",  height = 320, build = function(p) Rec_BuildFilters(p) end },
		},
	})
	f.dash = dash
	f.toggleBtn = dash.cta

	-- fill the shell zones: main = live log + a compact stat bar across its top;
	-- drawer = the vertical Contacts list (name + inv/+f) -- the thing you act on.
	Rec_BuildLog(dash.main)        -- live whisper log + stats bar (landing view)
	Rec_BuildContacts(dash.drawer) -- contacts invite list (right)

	Rec_RefreshUI()
	return
end

-- Config-tab page builders (each fills a fill-frame the Dashboard hands them).
function Rec_BuildText(tp)
	local f = RecruitFrame
	local X = 4

	-- ---------- TEXT panel ----------
	makeLabel(tp, "Guild name (used by {guild} + toast):", X, -6)
	f.guildName = makeBox(tp, "guildName", X, -26, 260, 22)
	strHook(f.guildName, "guildName")

	makeLabel(tp, "Advertise message:  (tip: write {guild} for the name)", X, -56)
	f.msg = makeScrollBox(tp, "msg", X, -74, 12, 74)
	makeLabel(tp, "Auto-reply (on whisper):", X, -156)
	f.reply = makeScrollBox(tp, "reply", X, -174, 12, 74)
	makeLabel(tp, "AFK reply (used when AFK mode is on):", X, -256)
	f.afkReply = makeScrollBox(tp, "afkReply", X, -274, 12, 70)
	strHook(f.msg, "message")
	strHook(f.reply, "reply")
	strHook(f.afkReply, "afkReply")
	Rec_ApplyText()
end

function Rec_BuildSettings(stp)
	local f = RecruitFrame
	local X = 4

	-- ---------- SETTINGS panel ----------
	makeLabel(stp, "Keywords -- whisper triggers invite (typos ok):", X, -10)
	f.keywords = makeScrollBox(stp, "keywords", X, -30, 12, 56)
	strHook(f.keywords, "keywords")

	makeLabel(stp, "Channel spam intervals (sec, 0 = off -- stagger them):", X, -98)
	f.chInputs = {}
	local function chHook(box, name)
		box:SetScript("OnEditFocusLost", function(s)
			local v = math.max(0, math.min(3600, math.floor(tonumber(s:GetText()) or 0)))
			db.channelIntervals[name] = v
			s:SetText(v)
			if s.bd then
				s.bd:SetBackdropBorderColor(0.4, 0.4, 0.45, 1)
			end
		end)
	end
	local CH_LABELS = { Global = "Global", LookingForGroup = "LFG", General = "General" }
	local COL2 = X + 224
	local cols = { { lx = X, bx = X + 70 }, { lx = COL2, bx = COL2 + 70 } }
	local rowY = -124
	for i, name in ipairs(CH_LIST) do
		local col = cols[((i - 1) % 2) + 1]
		makeLabel(stp, CH_LABELS[name], col.lx, rowY)
		local box = makeBox(stp, "iv_" .. name, col.bx, rowY + 2, 48, 22)
		chHook(box, name)
		f.chInputs[name] = box
		if i % 2 == 0 then
			rowY = rowY - 30
		end
	end

	makeLabel(stp, "Custom channel + interval:", X, -214)
	f.custom = makeBox(stp, "custom", X, -234, 286, 22)
	strHook(f.custom, "customChannel")
	f.customIv = makeBox(stp, "iv_custom", COL2 + 70, -234, 48, 22)
	numHook(f.customIv, "customInterval", 0, 3600)

	makeLabel(stp, "Reply CD (s):", X, -272)
	f.replyCd = makeBox(stp, "replyCd", X + 88, -272, 48, 22)
	makeLabel(stp, "Invite CD (s):", COL2, -272)
	f.inviteCd = makeBox(stp, "inviteCd", COL2 + 88, -272, 48, 22)
	numHook(f.replyCd, "replyCooldown", 0, 3600)
	numHook(f.inviteCd, "inviteCooldown", 0, 3600)

	local cdNote = stp:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	cdNote:SetPoint("TOPLEFT", X, -300)
	cdNote:SetWidth(440)
	cdNote:SetJustifyH("LEFT")
	cdNote:SetText("Give each channel a different interval to stagger spam (not all at once). Cooldown = silence per person after replying/inviting. 0 = off.")

	f.cInvite = makeCheck(stp, "autoInvite", "Auto-invite (+ welcome)", X, -334)
	f.cAfk = makeCheck(stp, "afkMode", "AFK mode", COL2, -334, function() Rec_RefreshUI() end)
	f.cToast = makeCheck(stp, "toastOnJoin", "Toast on guild join", X, -362)
	f.cToastActive = makeCheck(stp, "toastOnlyActive", "only while advertising ON", COL2, -362)
	f.cToastMove = makeCheck(stp, "toastMove", "Move toast (drag it, untick to lock)", X, -390,
		function(v) Rec_SetToastMove(v) end)
	Rec_ApplySettings()
end

function Rec_BuildFilters(fp)
	local f = RecruitFrame
	local X = 4

	-- ---------- FILTERS panel ----------
	makeLabel(fp, "Don't auto-reply / invite if the whisperer is:", X, -8)
	f.fGuild = makeCheck(fp, "filterGuild", "In my guild", X, -36)
	f.fGroup = makeCheck(fp, "filterGroup", "In my party / raid", X, -66)
	f.fFriends = makeCheck(fp, "filterFriends", "On my friends list", X, -96)
	local note = fp:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	note:SetPoint("TOPLEFT", X, -136)
	note:SetWidth(430)
	note:SetJustifyH("LEFT")
	note:SetText("Turn a filter OFF to test on yourself/guildies. The addon only ever replies/invites on a keyword whisper anyway.")

	makeLabel(fp, "Block words -- ignore whisper if it has any (gold sellers / ads):", X, -176)
	f.blacklist = makeScrollBox(fp, "blacklist", X, -196, 12, 70)
	strHook(f.blacklist, "blacklist")
	local bnote = fp:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	bnote:SetPoint("TOPLEFT", X, -272)
	bnote:SetWidth(440)
	bnote:SetJustifyH("LEFT")
	bnote:SetText("Comma-separated. Beats keywords -- e.g. 'inv pls i pay 10 gold' is ignored because of 'gold'. Typos caught too.")
	Rec_ApplyFilters()
end

-- ---------- MAIN: live whisper log (landing view) ----------
function Rec_BuildLog(main)
	local f = RecruitFrame

	local logsLbl = W.Text(main, "Live log", nil, "dim")
	logsLbl:SetPoint("TOPLEFT", 8, -7)
	local clr = W.Button(main, "Clear", "secondary")
	clr:SetSize(56, 18); clr:SetPoint("TOPRIGHT", -8, -4)
	clr:SetScript("OnClick", function() wipe(db.log); Rec_RefreshLog() end)

	-- Opaque dark well behind the log so the faded rat art mounted on the shell
	-- panel doesn't bleed into the whisper text area (it stays visible elsewhere).
	local well = W.Frame(main, "dark")
	well:SetPoint("TOPLEFT", 8, -26)
	well:SetPoint("BOTTOMRIGHT", -8, 8)

	local s = CreateFrame("ScrollingMessageFrame", nil, well)
	s:SetPoint("TOPLEFT", 4, -4)
	s:SetPoint("BOTTOMRIGHT", -4, 4)
	s:SetFontObject(GameFontHighlightSmall)
	s:SetJustifyH("LEFT")
	s:SetMaxLines(120)
	s:SetFading(false)
	s:EnableMouseWheel(true)
	s:SetScript("OnMouseWheel", function(self, delta)
		if delta > 0 then self:ScrollUp() else self:ScrollDown() end
	end)
	f.logBox = s
	f.logPanel = main -- Rec_RefreshLog checks :IsShown() to know it's live
	Rec_RefreshLog()
end

-- ---------- DRAWER: session summary cards + the Contacts invite list ----------
-- Top: a 3-column grid of stat cards (this session). Below: the invite list
-- (who to re-invite), vertical + scrollable. Both live in the right drawer.
function Rec_BuildContacts(drawer)
	local f = RecruitFrame

	-- ----- session summary: 3 columns x 2 rows of small stat cards -----
	local sHead = W.Text(drawer, "This session", nil, "accent")
	sHead:SetPoint("TOPLEFT", 8, -8)
	local sclr = W.Button(drawer, "clear", "secondary")
	sclr:SetSize(44, 16); sclr:SetPoint("TOPRIGHT", -8, -6)
	sclr:SetScript("OnClick", function() wipe(db.session); Rec_RefreshSummary() end)

	local CARD_W, CARD_H, GAPX, GAPY = 56, 30, 4, 4
	local grid = { { "reached", "Reached", "dcddde" }, { "joined", "Joined", "7cfc8a" }, { "declined", "Declined", "ff5555" },
	               { "inguild", "In-guild", "ff8888" }, { "offline", "Offline", "aaaaaa" }, { "waiting", "Waiting", "ffcc00" } }
	f.statCards = {}
	for i, g in ipairs(grid) do
		local col = (i - 1) % 3
		local rowi = math.floor((i - 1) / 3)
		local card = W.Frame(drawer, "input")
		card:SetSize(CARD_W, CARD_H)
		card:SetPoint("TOPLEFT", 8 + col * (CARD_W + GAPX), -26 - rowi * (CARD_H + GAPY))
		-- keep the stat cards OPAQUE (over the page rat), so the numbers read
		-- clearly instead of the rat bleeding through the card. Fixed alpha,
		-- independent of the background-opacity slider (so unregister it from the
		-- reskin table, else ReskinAll would drop it back to the slider alpha).
		if Okanvil._skinned then Okanvil._skinned[card] = nil end
		if card.SetBackdropColor then
			local d = Okanvil.Colors.panelD
			card:SetBackdropColor(d[1], d[2], d[3], 1)
		end
		local num = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		num:SetPoint("TOP", 0, -2); num:SetText("0")
		num:SetTextColor(1, 1, 1)
		local cap = W.Text(card, g[2], 9, "dim")
		cap:SetPoint("BOTTOM", 0, 2)
		cap:SetText("|cff" .. g[3] .. g[2] .. "|r")
		f.statCards[g[1]] = num
	end
	-- list starts below the 2 card rows (26 + 2*(30+4) = 94) + a small gap
	local listTop = -(26 + 2 * (CARD_H + GAPY) + 8)

	local lbl = W.Text(drawer, "Contacts", nil, "accent")
	lbl:SetPoint("TOPLEFT", 8, listTop + 2)

	-- flat scroll (no Blizzard template): plain ScrollFrame + our own slider
	local csf = CreateFrame("ScrollFrame", "Rec_contactSF", drawer)
	csf:SetPoint("TOPLEFT", 6, listTop - 18); csf:SetPoint("BOTTOMRIGHT", -10, 6)
	local cchild = CreateFrame("Frame", nil, csf)
	cchild:SetSize(10, 1)
	csf:SetScrollChild(cchild)
	local csb = CreateFrame("Slider", nil, drawer)
	csb:SetPoint("TOPRIGHT", -3, listTop - 18); csb:SetPoint("BOTTOMRIGHT", -3, 6); csb:SetWidth(4)
	csb:SetOrientation("VERTICAL"); csb:SetValueStep(1)
	local cth = csb:CreateTexture(nil, "OVERLAY"); cth:SetTexture(FLAT); cth:SetSize(4, 30)
	if Okanvil and Okanvil.Colors then local a = Okanvil.Colors.accent; cth:SetVertexColor(a[1], a[2], a[3], 1)
	else cth:SetVertexColor(0.75, 0.58, 0.23, 1) end
	csb:SetThumbTexture(cth)
	csb:SetScript("OnValueChanged", function(_, v) csf:SetVerticalScroll(v) end)
	csf:EnableMouseWheel(true)
	csf:SetScript("OnMouseWheel", function(_, d) csb:SetValue(csb:GetValue() - d * 24) end)
	f.contactChild = cchild
	f.contactSF = csf
	f.contactSB = csb
	f.contactRows = {}

	drawer:SetScript("OnUpdate", function(self, el)
		self._t = (self._t or 0) + el
		if self._t > 1 then self._t = 0; Rec_RenderContacts(); Rec_RefreshSummary() end
	end)
	Rec_RenderContacts()
	Rec_RefreshSummary()
end

-- Config pages are built LAZILY (only when the user opens that overlay tab), so
-- each has its own apply-fn that pushes db values into its widgets. They're
-- guarded (widgets may not exist yet). Rec_RefreshUI just fans out to all of them
-- plus repaints the dashboard header.
function Rec_ApplyText()
	local f = RecruitFrame
	if not f or not f.msg then return end
	f.guildName:SetText(db.guildName or "")
	f.msg:SetText(db.message or "")
	f.reply:SetText(db.reply or "")
	f.afkReply:SetText(db.afkReply or "")
end

function Rec_ApplySettings()
	local f = RecruitFrame
	if not f or not f.keywords then return end
	f.keywords:SetText(db.keywords or "")
	f.custom:SetText(db.customChannel or "")
	f.customIv:SetText(db.customInterval or 0)
	f.replyCd:SetText(db.replyCooldown or 600)
	f.inviteCd:SetText(db.inviteCooldown or 300)
	f.cInvite:SetChecked(db.autoInvite)
	f.cAfk:SetChecked(db.afkMode)
	f.cToast:SetChecked(db.toastOnJoin)
	f.cToastActive:SetChecked(db.toastOnlyActive)
	if f.chInputs then
		for name, box in pairs(f.chInputs) do
			box:SetText(db.channelIntervals[name] or 0)
		end
	end
end

function Rec_ApplyFilters()
	local f = RecruitFrame
	if not f or not f.fGuild then return end
	f.fGuild:SetChecked(db.filterGuild)
	f.fGroup:SetChecked(db.filterGroup)
	f.fFriends:SetChecked(db.filterFriends)
	f.blacklist:SetText(db.blacklist or "")
end

function Rec_RefreshUI()
	local f = RecruitFrame
	if not f then return end
	if f.dash then f.dash:Refresh() end
	Rec_ApplyText()
	Rec_ApplySettings()
	Rec_ApplyFilters()
end

local SKULL = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_8:12:12|t"

local function stateTag(state)
	if state == "sent" then
		return "|cffffcc00[sent]|r "
	elseif state == "joined" then
		return "|cff00ff00[joined]|r "
	elseif state == "declined" then
		return "|cffff5555[declined]|r "
	elseif state == "failed" then
		return SKULL .. "|cffff5555[failed]|r "
	elseif state == "offline" then
		return "|cffaaaaaa[offline]|r "
	end
	return ""
end

local function stateMark(state)
	if state == "sent" then
		return " |cffffcc00+|r"
	elseif state == "joined" then
		return " |cff00ff00OK|r"
	elseif state == "declined" then
		return " |cffff5555X|r"
	elseif state == "failed" then
		return " " .. SKULL
	elseif state == "offline" then
		return " |cffaaaaaaoff|r"
	end
	return ""
end

local function fmtCD(remain)
	remain = math.floor(remain)
	if remain >= 60 then
		return string.format("%dm%02ds", math.floor(remain / 60), remain % 60)
	end
	return remain .. "s"
end

function Rec_InviteContact(name)
	recentInvites[name] = GetTime()
	GuildInvite(name)
	db.session[name] = db.session[name] or {}
	db.session[name].invited = true
	for i = 1, #db.log do
		if db.log[i].who == name then
			db.log[i].state = "sent"
			break
		end
	end
	Print("Guild-invited |cff00ff00" .. name .. "|r.")
	Rec_RenderContacts()
end

function Rec_AddWatchFriend(name)
	if not name or name == "" then
		return
	end
	if AddFriend then
		AddFriend(name)
	end
	db.session[name] = db.session[name] or {}
	db.session[name].watch = true
	Print("Added |cff00ff00" .. name .. "|r to friends -- you'll get a toast when they come online.")
	Rec_RenderContacts()
end

-- Contacts render as a HORIZONTAL row of chips inside the footer strip. Each chip
-- is name+state; invitable ones get a tiny inline [inv] button, offline ones [+f].
function Rec_RenderContacts()
	local f = RecruitFrame
	if not f or not f.contactChild then
		return
	end
	for _, row in ipairs(f.contactRows) do
		row:Hide()
	end
	local seen, list = {}, {}
	for i = 1, #db.log do
		local e = db.log[i]
		if not seen[e.who] then
			seen[e.who] = true
			list[#list + 1] = e
		end
	end
	local n = #list
	local now = GetTime()
	local ROWH = 20
	local width = (f.contactSF and f.contactSF:GetWidth() or 176)
	for k = 1, n do
		local e = list[k] -- most-recent first (log[1] is newest)
		local who = e.who
		local row = f.contactRows[k]
		if not row then
			row = CreateFrame("Frame", nil, f.contactChild)
			row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
			row.label:SetPoint("LEFT", 2, 0)
			row.label:SetJustifyH("LEFT")
			row.label:SetWordWrap(false)
			row.btn = W.Button(row, "inv", "secondary")
			row.btn:SetSize(32, 16); row.btn:SetPoint("RIGHT", -2, 0)
			row.fbtn = W.Button(row, "+f", "secondary")
			row.fbtn:SetSize(24, 16); row.fbtn:SetPoint("RIGHT", row.btn, "LEFT", -3, 0)
			f.contactRows[k] = row
		end
		row:SetHeight(ROWH); row:SetWidth(width)
		row:ClearAllPoints(); row:SetPoint("TOPLEFT", 0, -(k - 1) * ROWH)
		row:Show()
		row.label:SetText(nameColor(e.who, e.class) .. e.who .. "|r" .. stateMark(e.state))

		local showInv = not (e.state == "joined" or isInMyGuild(e.who))
		local showF = (e.state == "offline") and not (db.session[e.who] and db.session[e.who].watch)
		if showF then
			row.fbtn:Show(); row.fbtn:SetScript("OnClick", function() Rec_AddWatchFriend(who) end)
		else
			row.fbtn:Hide()
		end
		if showInv then
			local last = recentInvites[e.who]
			local remain = last and ((db.inviteCooldown or 300) - (now - last)) or 0
			row.btn.text:SetText(remain > 0 and fmtCD(remain) or "inv")
			row.btn:Show(); row.btn:SetScript("OnClick", function() Rec_InviteContact(who) end)
		else
			row.btn:Hide()
		end

		-- pin the name's RIGHT edge just left of whatever buttons are showing, so
		-- long names truncate cleanly instead of running under the inv/+f buttons.
		local rightPad = 4                       -- no buttons -> almost full width
		if showInv then rightPad = rightPad + 36 end
		if showF then rightPad = rightPad + 28 end
		row.label:SetPoint("RIGHT", row, "RIGHT", -rightPad, 0)
	end
	local h = math.max(1, n * ROWH)
	f.contactChild:SetHeight(h); f.contactChild:SetWidth(width)
	if f.contactSF and f.contactSB then
		local maxs = math.max(0, h - f.contactSF:GetHeight())
		f.contactSB:SetMinMaxValues(0, maxs); f.contactSB:SetShown(maxs > 4)
	end
	f._lastContactCount = n
end

function Rec_RefreshLog()
	local f = RecruitFrame
	if not f or not f.logBox then
		return
	end
	f.logBox:Clear()
	if #db.log == 0 then
		f.logBox:AddMessage("|cff888888No whispers yet.|r")
		Rec_RenderContacts()
		return
	end
	for i = #db.log, 1, -1 do
		local e = db.log[i]
		f.logBox:AddMessage(
			"|cff888888" .. e.t .. "|r " .. stateTag(e.state) .. nameColor(e.who, e.class) .. e.who .. "|r|cffdddddd: " .. (e.msg or "") .. "|r"
		)
		if e.reply and e.reply ~= "" then
			f.logBox:AddMessage("    |cff66bbff>> " .. e.reply .. "|r")
		end
	end
	Rec_RenderContacts()
end

function Rec_RefreshSummary()
	local f = RecruitFrame
	if not f or not f.statCards then
		return
	end
	local contacts, joined, declined, failed, offline, sent, noState, replied = 0, 0, 0, 0, 0, 0, 0, 0
	for _, v in pairs(db.session) do
		contacts = contacts + 1
		if v.state == "joined" then
			joined = joined + 1
		elseif v.state == "declined" then
			declined = declined + 1
		elseif v.state == "failed" then
			failed = failed + 1
		elseif v.state == "offline" then
			offline = offline + 1
		elseif v.invited then
			sent = sent + 1
		else
			noState = noState + 1
		end
		if v.replied then
			replied = replied + 1
		end
	end
	-- fill the 3-column stat cards in the drawer
	local c = f.statCards
	local function set(key, val) if c[key] then c[key]:SetText(tostring(val)) end end
	set("reached", contacts)
	set("joined", joined)
	set("declined", declined)
	set("inguild", failed)   -- "already in a guild"
	set("offline", offline)
	set("waiting", sent)
end

-- ============================================================
-- Slash
-- ============================================================
SLASH_RECRUIT1 = "/recruit"
SLASH_RECRUIT2 = "/okrec"
SlashCmdList["RECRUIT"] = function(arg)
	arg = string.lower(arg or "")
	if arg == "on" then
		Rec_ToggleActive(true)
	elseif arg == "off" then
		Rec_ToggleActive(false)
	elseif arg == "afk" then
		db.afkMode = not db.afkMode
		Rec_RefreshUI()
		Print("AFK mode " .. (db.afkMode and "|cff00ff00ON|r" or "|cffff5555OFF|r") .. ".")
	elseif arg == "clear" then
		wipe(db.log)
		if RecruitFrame then
			Rec_RefreshLog()
		end
		Print("whisper log cleared.")
	elseif arg == "toast" then
		Rec_ShowToast(UnitName("player"), select(2, UnitClass("player")))
	elseif arg == "channels" then
		local list = { GetChannelList() }
		if #list == 0 then
			Print("you are not in any channels.")
		else
			Print("your channels (number = name):")
			for i = 1, #list - 1, 2 do
				Print("  |cff00ff00" .. tostring(list[i]) .. "|r = " .. tostring(list[i + 1]))
			end
		end
	elseif Okanvil and Okanvil.Toggle then
		Okanvil:Toggle() -- open the Okanvil window (Recruit is a module in it)
	else
		Print("Okanvil host not loaded.")
	end
end
