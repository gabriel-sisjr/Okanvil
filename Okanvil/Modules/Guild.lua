-- ============================================================
-- Okanvil -- Guild (native core module, not a plugin).
-- Two exports for the RATS web hub:
--   * Roster export   -- the full guild roster as JSON (comp/guild importer).
--   * Attendance      -- a snapshot of the raid group at the first pull of the
--                        night (auto, MRT-style) or on demand, as JSON.
-- Attendance capture runs ALWAYS (core), so a raid is recorded even if you
-- never open the window.
-- ============================================================

local Okanvil = Okanvil
local G = {}
Okanvil.Guild = G

-- ------------------------------------------------------------
-- minimal JSON string escaper (WoW strings are UTF-8 -> raw is valid JSON)
-- ------------------------------------------------------------
local function esc(s)
	s = tostring(s or "")
	s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
	return s
end
G.esc = esc

local function stripRealm(name)
	return (name or ""):gsub("%-.*$", "")
end

-- ------------------------------------------------------------
-- Shared guild-roster walk. Every module that needs "all guild members" (or a
-- single member's rank/class) should go through this instead of re-deriving
-- its own GetGuildRosterInfo loop -- independent copies had already drifted
-- into real bugs: an incomplete roster export, a rank checkbox that could
-- vanish for a session, dead class-coloring (see CODE-REVIEW.md §3/§2).
-- ------------------------------------------------------------

-- G.Roster(includeOffline=true) -> array of member records:
--   { name, rank, rankIndex, level, classToken, className, zone, note,
--     officernote, online }
-- name is realm-stripped. classToken is the locale-proof "MAGE"-style token
-- (11th GetGuildRosterInfo return) -- use this for RAID_CLASS_COLORS lookups,
-- NOT className (the localized display name, kept only for text that must
-- show a human-readable class name, e.g. the roster JSON export).
function G.Roster(includeOffline)
	if includeOffline ~= false and SetGuildRosterShowOffline then
		SetGuildRosterShowOffline(true)
	end
	local total = (GetNumGuildMembers and GetNumGuildMembers()) or 0
	local out = {}
	for i = 1, total do
		-- 3.3.5a signature: name, rank, rankIndex, level, class, zone, note,
		-- officernote, online, status, classToken, achievementPoints, ...
		local name, rank, rankIndex, level, className, zone, note, officernote, online, _, classToken =
			GetGuildRosterInfo(i)
		if name then
			out[#out + 1] = {
				name = stripRealm(name), rank = rank, rankIndex = rankIndex or 99, level = level,
				classToken = classToken, className = className, zone = zone,
				note = note, officernote = officernote, online = online and true or false,
			}
		end
	end
	return out
end

-- G.FindMember(name, includeOffline=true) -> that member's roster record, or
-- nil. Case-insensitive, realm-stripped. For one-off lookups; callers that
-- need to test MANY names against one roster (canAutoInvite) should call
-- G.Roster() once themselves instead of calling this in a loop.
function G.FindMember(name, includeOffline)
	if not name or name == "" then return nil end
	name = stripRealm(name):lower()
	for _, m in ipairs(G.Roster(includeOffline)) do
		if m.name:lower() == name then return m end
	end
	return nil
end

-- G.IsAlt(rankName, rankIndex, officernote) -> boolean. THE alt rule -- MUST
-- match the RATS website (loot/history tools): an entry is an ALT if
-- rankIndex == 4, OR its rank name contains "alt", OR its officer note
-- starts with "<Main> alt".
function G.IsAlt(rankName, rankIndex, officernote)
	if rankIndex == 4 then return true end
	if rankName and rankName:lower():find("alt", 1, true) then return true end
	-- officer note like "Mainname alt" (site rule: /^(.+?)\s+alt\b/i)
	if officernote and officernote:lower():match("^.-%s+alt%f[%A]") then return true end
	return false
end

-- G.MainOf(publicnote, officernote) -> the main's name this alt belongs to,
-- or nil if we can't tell. Mirrors the RATS site's mainOfG/altMainNote:
--   1) officer note "Mainname alt ..." -> the word before "alt"
--   2) else the first word of the public note if it looks like a name
function G.MainOf(publicnote, officernote)
	if officernote and officernote ~= "" then
		local m = officernote:match("^(.-)%s+[Aa][Ll][Tt]%f[%A]")
		if m and m ~= "" then return (m:gsub("^%s+", ""):gsub("%s+$", "")) end
	end
	if publicnote and publicnote ~= "" then
		local first = publicnote:match("^%s*([A-Za-z\192-\255]+)")
		if first and #first >= 2 then return first end
	end
	return nil
end

-- ------------------------------------------------------------
-- Roster export (absorbed from the old Okanvil-Guild plugin)
-- matches officer/guild importer:
--   { guildName, realm, exportedAt, ranks:[{name,rankIndex}], roster:[{...}] }
-- ------------------------------------------------------------
function G.BuildRosterJSON()
	local guildName = GetGuildInfo("player") or "Guild"
	local realm = GetRealmName() or ""
	local ranksSeen, ranks, members = {}, {}, {}
	for _, m in ipairs(G.Roster(true)) do
		local rankIndex = m.rankIndex or 0
		if not ranksSeen[rankIndex] then
			ranksSeen[rankIndex] = true
			table.insert(ranks, { idx = rankIndex, name = m.rank or ("Rank " .. rankIndex) })
		end
		table.insert(members, string.format(
			'{"name":"%s","class":"%s","level":%d,"rankName":"%s","rankIndex":%d,"publicNote":"%s","officerNote":"%s"}',
			esc(m.name), esc(m.className), m.level or 0, esc(m.rank), rankIndex, esc(m.note), esc(m.officernote)
		))
	end
	table.sort(ranks, function(a, b) return a.idx < b.idx end)
	local ranksJson = {}
	for _, r in ipairs(ranks) do
		table.insert(ranksJson, string.format('{"name":"%s","rankIndex":%d}', esc(r.name), r.idx))
	end
	return string.format(
		'{"guildName":"%s","realm":"%s","exportedAt":%d,"ranks":[%s],"roster":[%s]}',
		esc(guildName), esc(realm), time(),
		table.concat(ranksJson, ","), table.concat(members, ",")
	), #members
end

-- ------------------------------------------------------------
-- Attendance snapshot
-- ------------------------------------------------------------
-- A snapshot = the raid roster (name/class/group/role/rank) plus raid meta
-- (zone, difficulty, boss, trigger, time). Stored in the guild SavedVariables
-- so the hub can be fed later even after a /reload.
local function snapshotRaid(trigger, bossName)
	local raidN = (GetNumRaidMembers and GetNumRaidMembers()) or 0
	local partyN = (GetNumPartyMembers and GetNumPartyMembers()) or 0
	if raidN == 0 and partyN == 0 then
		return nil, "not in a group"
	end
	local zone, difficultyID, groupSize, mapID
	if GetInstanceInfo then
		-- 3.3.5a: name, type, difficulty, difficultyName, maxPlayers, dynDiff, isDyn, mapID
		local name, _, diff, _, maxPlayers, _, _, mid = GetInstanceInfo()
		zone, difficultyID, groupSize, mapID = name, diff, maxPlayers, mid
	end

	local players = {}
	if raidN > 0 then
		-- raid: rich per-player info incl. subgroup and role
		for i = 1, 40 do
			local name, rank, subgroup, level, _, class, _, online, _, role = GetRaidRosterInfo(i)
			if name then
				players[#players + 1] = {
					name = stripRealm(name), class = class or "", level = level or 0,
					group = subgroup or 0, role = role or "", rankName = rank or "",
					online = online and true or false,
				}
			end
		end
	else
		-- party (incl. dungeons): GetRaidRosterInfo is empty, so walk the units.
		-- No subgroups in a party -> everyone is group 1; everyone shown is online.
		local units = { "player" }
		for i = 1, partyN do units[#units + 1] = "party" .. i end
		for _, u in ipairs(units) do
			if UnitExists(u) then
				local _, classToken = UnitClass(u)
				players[#players + 1] = {
					name = stripRealm(UnitName(u)), class = classToken or "",
					level = UnitLevel(u) or 0, group = 1, role = "",
					rankName = "", online = true,
				}
			end
		end
	end

	table.sort(players, function(a, b)
		if a.group ~= b.group then return a.group < b.group end
		return a.name < b.name
	end)
	return {
		t = time(), zone = zone or "", difficulty = difficultyID or 0, mapID = mapID or 0,
		groupSize = groupSize or (raidN > 0 and raidN or (partyN + 1)),
		boss = bossName or "", trigger = trigger,
		count = #players, players = players,
	}
end

-- persist a snapshot into the guild DB (keeps the last N)
local MAX_SNAPSHOTS = 20
function G.SaveSnapshot(trigger, bossName)
	local snap, err = snapshotRaid(trigger, bossName)
	if not snap then return nil, err end
	local db = Okanvil.db
	db.guild = db.guild or {}
	db.guild.snapshots = db.guild.snapshots or {}
	table.insert(db.guild.snapshots, 1, snap)   -- newest first
	while #db.guild.snapshots > MAX_SNAPSHOTS do
		table.remove(db.guild.snapshots)
	end
	if G.onSnapshot then G.onSnapshot() end       -- refresh the tab if open
	return snap
end

function G.DeleteSnapshot(snap)
	local list = Okanvil.db.guild and Okanvil.db.guild.snapshots
	if not list then return end
	for i = #list, 1, -1 do
		if list[i] == snap then table.remove(list, i); break end
	end
	if G.onSnapshot then G.onSnapshot() end
end

-- JSON for one snapshot (fed to the hub attendance importer)
function G.SnapshotJSON(snap)
	if not snap then return "{}" end
	local guildName = GetGuildInfo("player") or "Guild"
	local realm = GetRealmName() or ""
	local rows = {}
	for _, p in ipairs(snap.players) do
		rows[#rows + 1] = string.format(
			'{"name":"%s","class":"%s","level":%d,"group":%d,"role":"%s","rankName":"%s","online":%s}',
			esc(p.name), esc(p.class), p.level, p.group, esc(p.role), esc(p.rankName),
			p.online and "true" or "false"
		)
	end
	return string.format(
		'{"type":"attendance","guildName":"%s","realm":"%s","capturedAt":%d,"zone":"%s",'
		.. '"mapID":%d,"difficulty":%d,"groupSize":%d,"boss":"%s","trigger":"%s","players":[%s]}',
		esc(guildName), esc(realm), snap.t, esc(snap.zone),
		snap.mapID or 0, snap.difficulty, snap.groupSize, esc(snap.boss), esc(snap.trigger),
		table.concat(rows, ",")
	)
end

-- class color as |cffRRGGBB (RAID_CLASS_COLORS is a global on 3.3.5a)
local function classHex(classToken)
	local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
	if c then
		return string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
	end
	return "|cffffd200"
end

-- ------------------------------------------------------------
-- Snapshot body as a single formatted string: group headers + class-coloured
-- names. Shared by the inline Guild-tab expansion and the (legacy) popup.
-- ------------------------------------------------------------
function G.SnapshotBodyText(snap)
	if not snap or not snap.players then return "" end
	local lines, lastGroup = {}, nil
	for _, p in ipairs(snap.players) do
		if p.group ~= lastGroup then
			lastGroup = p.group
			lines[#lines + 1] = "|cff8a8d93Group " .. p.group .. "|r"
		end
		local role = (p.role and p.role ~= "") and ("  |cff5e6166(" .. p.role .. ")|r") or ""
		local off = p.online and "" or "  |cff5e6166[offline]|r"
		lines[#lines + 1] = "  " .. classHex(p.class) .. p.name .. "|r"
			.. "  |cff5e6166" .. (p.level > 0 and p.level or "") .. "|r" .. role .. off
	end
	return table.concat(lines, "\n")
end

-- Visual snapshot viewer -- see exactly who was captured, in-game,
-- names colored by class and split by group. Reuses one flat popup.
-- ------------------------------------------------------------
local viewer
function G.ShowSnapshot(snap)
	if not snap then return end
	local W = Okanvil.W
	local f = viewer
	if not f then
		f = Okanvil:Popup("Snapshot")
		f:SetSize(360, 440)
		f.meta = W.Text(f, "", 11, "dim"); f.meta:SetPoint("TOPLEFT", 12, -30)
		f.meta:SetPoint("RIGHT", f, "RIGHT", -12, 0); f.meta:SetJustifyH("LEFT")

		local box = Okanvil.W.Frame(f, "input")
		box:SetPoint("TOPLEFT", 8, -64); box:SetPoint("BOTTOMRIGHT", -8, 8)
		local sf = CreateFrame("ScrollFrame", nil, box)
		sf:SetPoint("TOPLEFT", 4, -4); sf:SetPoint("BOTTOMRIGHT", -10, 4)
		Okanvil.Clip(sf)
		local child = CreateFrame("Frame", nil, sf); child:SetSize(320, 10); sf:SetScrollChild(child)
		local sb = CreateFrame("Slider", nil, box)
		sb:SetPoint("TOPRIGHT", -3, -4); sb:SetPoint("BOTTOMRIGHT", -3, 4); sb:SetWidth(4)
		sb:SetOrientation("VERTICAL"); sb:SetValueStep(1)
		local th = sb:CreateTexture(nil, "OVERLAY")
		th:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
		local ac = Okanvil.Colors.accent; th:SetVertexColor(ac[1], ac[2], ac[3], 1); th:SetSize(4, 40)
		sb:SetThumbTexture(th)
		sb:SetScript("OnValueChanged", function(_, v) sf:SetVerticalScroll(v) end)
		sf:EnableMouseWheel(true)
		sf:SetScript("OnMouseWheel", function(_, d) sb:SetValue(sb:GetValue() - d * 24) end)
		f.sf, f.child, f.sb, f.body = sf, child, sb, W.Text(child, "", 12)
		f.body:SetPoint("TOPLEFT", 6, -6); f.body:SetPoint("TOPRIGHT", -6, -6); f.body:SetJustifyH("LEFT")
		viewer = f
	end

	local dateStr = date("%b %d  %H:%M", snap.t)
	local where = (snap.zone ~= "" and snap.zone) or "Unknown"
	f.title:SetText("|cffffd200" .. where .. "|r")
	f.meta:SetText(dateStr .. "   |cff8a8d93" .. (snap.count or 0) .. " players  |  "
		.. (snap.boss ~= "" and (snap.boss .. "  |  ") or "") .. (snap.trigger or "") .. "|r")

	f.body:SetText(G.SnapshotBodyText(snap))
	-- size the scroll child to the text so the slider range is right
	local h = f.body:GetStringHeight() + 16
	f.child:SetHeight(h)
	f.child:SetWidth(f.sf:GetWidth())
	local maxS = math.max(0, h - f.sf:GetHeight())
	f.sb:SetMinMaxValues(0, maxS); f.sb:SetValue(0); f.sb:SetShown(maxS > 0)
	f:Show()
end

-- ------------------------------------------------------------
-- Auto-capture at the first pull of the raid (MRT-style).
-- Prefer ENCOUNTER_START (some 3.3.5a private servers backport it);
-- fall back to entering combat (PLAYER_REGEN_DISABLED) inside a raid instance.
-- One auto-snapshot per raid lockout session (reset when the raid empties).
-- ------------------------------------------------------------
local firstPullDone = false
local haveEncounterEvent = false

local function inGroup()
	local raidN = (GetNumRaidMembers and GetNumRaidMembers()) or 0
	local partyN = (GetNumPartyMembers and GetNumPartyMembers()) or 0
	return raidN > 0 or partyN > 0
end

local function tryFirstPull(bossName, trigger)
	if firstPullDone then return end
	if not inGroup() then return end
	if not Okanvil:ShouldRecord() then return end   -- dungeon/raid toggle
	local snap = G.SaveSnapshot(trigger, bossName)
	if snap then
		firstPullDone = true
		Okanvil:Print("Attendance snapshot saved (" .. (snap.count or 0) .. " players).")
	end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")   -- entered combat
ev:RegisterEvent("RAID_ROSTER_UPDATE")
ev:RegisterEvent("PARTY_MEMBERS_CHANGED")
-- ENCOUNTER_START may not exist on 3.3.5a; RegisterEvent errors on unknown
-- events, so guard it in pcall.
pcall(function() ev:RegisterEvent("ENCOUNTER_START"); haveEncounterEvent = true end)

ev:SetScript("OnEvent", function(_, event, a1, a2)
	-- Modulo Guild DESLIGADO = nao faz first-pull announce nem reage a grupo.
	if Okanvil.ModuleActive and not Okanvil:ModuleActive("__guild") then return end
	if event == "ENCOUNTER_START" then
		-- a1 = encounterID, a2 = encounterName
		tryFirstPull(a2, "encounter-start")
	elseif event == "PLAYER_REGEN_DISABLED" then
		-- only use combat as a fallback when the encounter event isn't available
		if not haveEncounterEvent then tryFirstPull(nil, "combat") end
	else
		-- group emptied -> arm the next session's first-pull capture again
		if not inGroup() then firstPullDone = false end
	end
end)

-- ------------------------------------------------------------
-- Guild dashboard UI -- registered below as the "__guild" plugin (build once,
-- refresh on every show via Okanvil:ShowPanel's generic plugin dispatch).
-- ------------------------------------------------------------
local W = Okanvil.W
local C = Okanvil.Colors
local FLAT = "Interface\\ChatFrame\\ChatFrameBackground"
local function u3(t, a) return t[1], t[2], t[3], a or 1 end

local guildRefreshAll   -- bridges Guild_BuildUI's local refreshAll to Guild_Refresh below

local function Guild_BuildUI(panel)
	local host = panel
	local G = Okanvil.Guild

	-- Dashboard shell (MRT/Recruit-style): header (icon + title + status + CTA),
	-- no tabs, no drawer -> the snapshots list gets the whole content area and
	-- scrolls internally. CTA = Export roster.
	local dash = W.Dashboard(host, {
		title = "Guild",
		icon = Okanvil.ICONS.guild,
		drawerWidth = 0,
		footerHeight = 0,
		primaryText = function() return "Export roster" end,
		onPrimary = function() Okanvil:ShowExport(G.BuildRosterJSON(), "Guild roster") end,
		statusText = function()
			local snaps = (Okanvil.db.guild and Okanvil.db.guild.snapshots) or {}
			return "|cff8a8d93" .. #snaps .. " snapshot" .. (#snaps == 1 and "" or "s") .. "|r"
		end,
	})
	panel.dash = dash

	-- a scroll panel INSIDE main so the snapshots list scrolls without resizing
	local main = dash.main
	local X = 12
	local sf = CreateFrame("ScrollFrame", nil, main)
	sf:SetPoint("TOPLEFT", X, -8); sf:SetPoint("BOTTOMRIGHT", -14, 8)
	local p = CreateFrame("Frame", nil, sf); p:SetSize(10, 1); sf:SetScrollChild(p)
	local sb = CreateFrame("Slider", nil, main)
	sb:SetPoint("TOPRIGHT", -4, -8); sb:SetPoint("BOTTOMRIGHT", -4, 8); sb:SetWidth(4)
	sb:SetOrientation("VERTICAL"); sb:SetValueStep(1)
	local th = sb:CreateTexture(nil, "OVERLAY"); th:SetTexture(FLAT); th:SetVertexColor(u3(C.accent)); th:SetSize(4, 40)
	sb:SetThumbTexture(th)
	sb:SetScript("OnValueChanged", function(_, v) sf:SetVerticalScroll(v) end)
	sf:EnableMouseWheel(true)
	sf:SetScript("OnMouseWheel", function(_, d) sb:SetValue(sb:GetValue() - d * 30) end)
	sf:SetScript("OnSizeChanged", function() p:SetWidth(sf:GetWidth()) end)
	local wrap = { relayout = function()
		p:SetWidth(sf:GetWidth())
		local maxs = math.max(0, p:GetHeight() - sf:GetHeight())
		sb:SetMinMaxValues(0, maxs); sb:SetShown(maxs > 4)
	end }

	-- row 0: intro hint + "Snapshot now" secondary action, then the list below it
	local hint = W.Text(p, "Attendance is captured automatically at the first pull. Export roster feeds the web hub.", 10, "dim")
	local snapNow = W.Button(p, "Snapshot group now")
	snapNow:SetSize(150, 24)
	snapNow:SetScript("OnClick", function()
		local snap, err = G.SaveSnapshot("manual")
		if not snap then
			Okanvil:Print("Snapshot failed: " .. (err or "?"))
		else
			wrap.expanded = snap        -- expand the new snapshot inline (no popup)
			if wrap._rebuild then wrap._rebuild() end
		end
	end)
	local sh = W.Text(p, "SAVED SNAPSHOTS", 10, "dim")

	wrap.rows = {}
	wrap.detailFS = {}       -- pooled expansion text blocks (one per row when open)
	wrap.expanded = nil
	local function rebuild()
		for _, r in ipairs(wrap.rows) do r:Hide() end
		for _, t in ipairs(wrap.detailFS) do t:Hide() end
		-- top block (hint + snapshot-now + list header) lives inside the scroll child
		hint:ClearAllPoints(); hint:SetPoint("TOPLEFT", X, -4); hint:SetPoint("RIGHT", p, "RIGHT", -X, 0); hint:SetJustifyH("LEFT")
		snapNow:ClearAllPoints(); snapNow:SetPoint("TOPLEFT", X, -34)
		sh:ClearAllPoints(); sh:SetPoint("TOPLEFT", X, -70)
		local snaps = (Okanvil.db.guild and Okanvil.db.guild.snapshots) or {}
		if #snaps == 0 then
			wrap.empty = wrap.empty or W.Text(p, "", 12, "dim")
			wrap.empty:ClearAllPoints(); wrap.empty:SetPoint("TOPLEFT", X, -90)
			wrap.empty:SetText("|cff888888No snapshots yet. They save at the first pull, or use the button above.|r")
			wrap.empty:Show(); p:SetHeight(140); wrap.relayout(); return
		end
		if wrap.empty then wrap.empty:Hide() end

		local di = 0
		local y = 90
		for i, snap in ipairs(snaps) do
			local r = wrap.rows[i]
			if not r then
				r = W.Frame(p, "input")
				r.title = W.Text(r, "", 13); r.title:SetPoint("TOPLEFT", 10, -6)
				r.sub = W.Text(r, "", 10, "dim"); r.sub:SetPoint("BOTTOMLEFT", 10, 6)
				r.del = W.Button(r, "X", "danger"); r.del:SetSize(24, 22); r.del:SetPoint("RIGHT", -8, 0)
				r.export = W.Button(r, "Export"); r.export:SetSize(72, 22); r.export:SetPoint("RIGHT", r.del, "LEFT", -6, 0)
				r.view = W.Button(r, "View"); r.view:SetSize(60, 22); r.view:SetPoint("RIGHT", r.export, "LEFT", -6, 0)
				r:EnableMouse(true)
				wrap.rows[i] = r
			end
			r:ClearAllPoints(); r:SetPoint("TOPLEFT", X, -y); r:SetPoint("RIGHT", p, "RIGHT", -X, 0); r:SetHeight(40)
			local dateStr = date("%b %d  %H:%M", snap.t)
			local where = (snap.zone ~= "" and snap.zone) or "Unknown"
			local isOpen = (wrap.expanded == snap)
			r.title:SetText((isOpen and "|cffffd200v|r  " or "|cff8a8d93>|r  ")
				.. where .. (snap.boss ~= "" and ("  |cff8a8d93-- " .. snap.boss .. "|r") or ""))
			r.sub:SetText(dateStr .. "  |cff8a8d93|  " .. (snap.count or 0) .. " players  |  " .. (snap.trigger or "") .. "|r")
			r.view.text:SetText(isOpen and "Close" or "View")
			local function toggle()
				if wrap.expanded == snap then wrap.expanded = nil else wrap.expanded = snap end
				rebuild()
			end
			r.view:SetScript("OnClick", toggle)   -- View/Close button owns the toggle
			r.export:SetScript("OnClick", function()
				Okanvil:ShowExport(G.SnapshotJSON(snap), "Attendance -- " .. dateStr)
			end)
			r.del:SetScript("OnClick", function()
				if wrap.expanded == snap then wrap.expanded = nil end
				G.DeleteSnapshot(snap)
			end)
			r:Show()
			y = y + 46

			if isOpen then
				di = di + 1
				local t = wrap.detailFS[di]
				if not t then t = W.Text(p, "", 12); t:SetJustifyH("LEFT"); wrap.detailFS[di] = t end
				t:ClearAllPoints()
				t:SetPoint("TOPLEFT", X + 14, -y); t:SetPoint("RIGHT", p, "RIGHT", -X, 0)
				t:SetText(G.SnapshotBodyText(snap))
				t:Show()
				y = y + t:GetStringHeight() + 10
			end
		end
		p:SetHeight(math.max(y + 10, sf:GetHeight()))
		wrap.relayout()
	end
	wrap._rebuild = rebuild
	local function refreshAll() dash:Refresh(); rebuild() end
	guildRefreshAll = refreshAll
	G.onSnapshot = function() if panel:IsShown() then refreshAll() end end
	return
end

local function Guild_Refresh()
	if guildRefreshAll then guildRefreshAll() end
end

local guildLoginEv = CreateFrame("Frame")
guildLoginEv:RegisterEvent("PLAYER_LOGIN")
guildLoginEv:SetScript("OnEvent", function()
	Okanvil_Plugins = Okanvil_Plugins or {}
	Okanvil_Plugins["__guild"] = {
		title = "Guild",
		desc = "Guild dashboard + JSON roster export for the web hub.",
		icon = Okanvil.ICONS.guild,
		build = Guild_BuildUI,
		refresh = Guild_Refresh,
	}
	if Okanvil.Register then Okanvil:Register("__guild") end
end)
