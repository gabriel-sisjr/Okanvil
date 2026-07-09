-- ============================================================
-- Okanvil -- Invite (native core module).
-- Tools to form a raid/party fast: mass-invite online guildies (all, by rank,
-- or from a saved list), a keyword whisper-invite (whisper "inv" -> pulled into
-- YOUR group), and an opt-in "auto-invite these people when they log in".
-- Parties auto-convert to raid past 5; declined/offline are retried on a cooldown.
--
-- 3.3.5a API: InviteUnit, GetNumRaidMembers/GetNumPartyMembers, ConvertToRaid,
-- GetGuildRosterInfo, GuildRoster. No retail C_PartyInfo.
-- ============================================================

local Okanvil = Okanvil
local I = {}
Okanvil.Invite = I

-- ------------------------------------------------------------
-- DB
-- ------------------------------------------------------------
local function db()
	local d = Okanvil.db
	d.invite = d.invite or {}
	local iv = d.invite
	if iv.keyword == nil then iv.keyword = "inv" end
	if iv.keywordEnabled == nil then iv.keywordEnabled = false end  -- MASTER switch for keyword-invite
	if iv.whisperInvite == nil then iv.whisperInvite = false end
	if iv.guildInvite == nil then iv.guildInvite = false end   -- keyword in /guild chat
	if iv.retry == nil then iv.retry = true end
	if iv.retryCooldown == nil then iv.retryCooldown = 30 end
	if iv.autoAssign == nil then iv.autoAssign = true end  -- move to comp group as they join
	iv.ranks = iv.ranks or {}          -- rankIndex(number) -> true = include when "invite by rank"
	-- iv.lists: name -> { members = { {name=, group=}, ... } }. Legacy plain-array
	-- lists ({ "A", "B" }) are auto-migrated to this shape on first read.
	iv.lists = iv.lists or {}
	for k, v in pairs(iv.lists) do
		if v[1] ~= nil and v.members == nil then          -- old plain-array list
			local members = {}
			for _, n in ipairs(v) do members[#members + 1] = { name = n } end
			iv.lists[k] = { members = members }
		end
	end
	iv.autoLoginList = iv.autoLoginList or ""  -- which saved list is armed for on-login invite ("" = off)
	return iv
end

-- members of a saved list (always the {name=,group=} shape)
local function listMembers(iv, listName)
	local l = iv.lists[listName]
	return l and l.members or nil
end
I.ListMembers = function(listName) return listMembers(db(), listName) end

-- list names (sorted) for a picker/dropdown
function I.ListNames()
	local out = {}
	for k in pairs(db().lists) do out[#out + 1] = k end
	table.sort(out)
	return out
end

-- is `name` a member of this list?
function I.IsInList(listName, name)
	local members = listMembers(db(), listName)
	if not members then return false end
	for _, m in ipairs(members) do if m.name == name then return true end end
	return false
end

-- toggle a roster name in/out of the list (used by the roster picker checkboxes)
function I.ToggleInList(listName, name)
	if I.IsInList(listName, name) then I.RemoveFromList(listName, name)
	else I.AddToList(listName, name) end
end

-- comp grouped for display: returns an ordered array of
--   { group = <n or nil>, names = { "A", "B", ... } }
-- groups first (1..8, in order), then an "ungrouped" bucket last.
function I.ListGrouped(listName)
	local members = listMembers(db(), listName)
	if not members then return {} end
	local byGroup, ungrouped = {}, {}
	for _, m in ipairs(members) do
		if m.group then
			byGroup[m.group] = byGroup[m.group] or {}
			table.insert(byGroup[m.group], m.name)
		else
			ungrouped[#ungrouped + 1] = m.name
		end
	end
	local out = {}
	for g = 1, 8 do
		if byGroup[g] then out[#out + 1] = { group = g, names = byGroup[g] } end
	end
	if #ungrouped > 0 then out[#out + 1] = { group = nil, names = ungrouped } end
	return out
end
I.db = db

local function Print(msg) Okanvil:Print(msg) end

-- ------------------------------------------------------------
-- group helpers
-- ------------------------------------------------------------
local function groupSize()
	local r = (GetNumRaidMembers and GetNumRaidMembers()) or 0
	if r > 0 then return r, true end
	local p = (GetNumPartyMembers and GetNumPartyMembers()) or 0
	return p + (p > 0 and 1 or 0), false   -- party count includes you when non-empty
end

-- is `name` already in my group (party or raid)?
local function inMyGroup(name)
	local r = (GetNumRaidMembers and GetNumRaidMembers()) or 0
	if r > 0 then
		for i = 1, r do if UnitName("raid" .. i) == name then return true end end
		return false
	end
	local p = (GetNumPartyMembers and GetNumPartyMembers()) or 0
	for i = 1, p do if UnitName("party" .. i) == name then return true end end
	return name == UnitName("player")
end

-- Am I ALLOWED to auto-invite right now? Guards the automatic (on-login) path so
-- the addon never starts pulling guildies "out of nowhere". Rules:
--   * solo (no group)                    -> yes (I'll form the group)
--   * in a party/raid but NOT leader/assist -> NO (someone else runs this group)
--   * raid contains any non-guild member (a PUG) -> NO (don't drag guildies into a pug)
-- The manual buttons are the user's explicit action and aren't gated here.
local function canAutoInvite()
	local nRaid = (GetNumRaidMembers and GetNumRaidMembers()) or 0
	local nParty = (GetNumPartyMembers and GetNumPartyMembers()) or 0
	if nRaid == 0 and nParty == 0 then return true end          -- solo -> free to form a group

	-- must be leader or assistant to legitimately invite into this group
	local iAmLead = (IsRaidLeader and IsRaidLeader()) or (IsPartyLeader and IsPartyLeader())
	local iAmAssist = (IsRaidOfficer and IsRaidOfficer())        -- raid assist
	if not (iAmLead or iAmAssist) then return false end

    -- Don't auto-invite guildies into a group that already has a PUG (non-guildie).
	-- Build a set of my guild's member names, then check every group member.
	if IsInGuild and IsInGuild() then
		local guild = {}
		local total = (GetNumGuildMembers and GetNumGuildMembers()) or 0
		for i = 1, total do
			local gname = GetGuildRosterInfo(i)
			if gname then guild[(gname:gsub("%-.*$", ""))] = true end
		end
		if nRaid > 0 then
			for i = 1, nRaid do
				local rn = UnitName("raid" .. i)
				if rn and not guild[rn] then return false end       -- a pug is in the raid
			end
		else
			for i = 1, nParty do
				local pn = UnitName("party" .. i)
				if pn and not guild[pn] then return false end        -- a pug is in the party
			end
		end
	end
	return true
end
I.CanAutoInvite = canAutoInvite

-- Send one invite (guarded). Tracks pending invites for retry. Auto-converts to
-- raid when the group would exceed 5.
-- pending: name -> { t = last-invite time, tries = how many invites we've sent }.
-- The `tries` cap is what stops the invite SPAM: we give up after MAX_TRIES instead
-- of re-inviting the same person forever (they may be in another group / ignoring).
local pending = {}
local MAX_TRIES = 3
local function inviteOne(name)
	if not name or name == "" then return false end
	name = (name:gsub("%-.*$", ""))     -- strip realm
	if name == UnitName("player") then return false end
	if inMyGroup(name) then return false end
	-- convert to raid BEFORE we overflow a full party
	local size = groupSize()
	if size >= 5 and (GetNumRaidMembers and GetNumRaidMembers() == 0) and ConvertToRaid then
		ConvertToRaid()
	end
	if InviteUnit then InviteUnit(name) else return false end
	local p = pending[name] or { tries = 0 }
	p.t = GetTime and GetTime() or 0
	p.tries = (p.tries or 0) + 1
	pending[name] = p
	return true
end
I.InviteOne = inviteOne

-- Invite a plain list of names. Returns how many invites were sent.
function I.InviteNames(names)
	if not names then return 0 end
	local sent = 0
	for _, n in ipairs(names) do
		if inviteOne(n) then sent = sent + 1 end
	end
	if sent > 0 then Print("Invited " .. sent .. " player(s).") end
	if I.onChange then I.onChange() end
	return sent
end

-- ------------------------------------------------------------
-- roster scan: walk online guildies, optionally filtered by included ranks.
-- rankFilter=nil -> everyone online. Returns a list of {name, rankIndex, rank}.
-- ------------------------------------------------------------
local function onlineGuildies(rankFilter)
	local out = {}
	if not (IsInGuild and IsInGuild()) then return out end
	if SetGuildRosterShowOffline then SetGuildRosterShowOffline(true) end
	local total = (GetNumGuildMembers and GetNumGuildMembers()) or 0
	local me = UnitName and UnitName("player")
	for i = 1, total do
		local name, rank, rankIndex, _, _, _, _, _, online = GetGuildRosterInfo(i)
		if name and online and name ~= me then
			name = (name:gsub("%-.*$", ""))
			if (not rankFilter) or rankFilter[rankIndex] then
				out[#out + 1] = { name = name, rankIndex = rankIndex or 99, rank = rank or "" }
			end
		end
	end
	return out
end
I.OnlineGuildies = onlineGuildies

-- Invite every online guildie (skips grouped). One button.
function I.InviteGuildOnline()
	if GuildRoster then GuildRoster() end
	local list = onlineGuildies(nil)
	local names = {}
	for _, m in ipairs(list) do names[#names + 1] = m.name end
	return I.InviteNames(names)
end

-- Invite online guildies whose rankIndex is in the ticked set (iv.ranks).
function I.InviteByRank()
	local iv = db()
	local any = false
	for _, v in pairs(iv.ranks) do if v then any = true break end end
	if not any then Print("Pick at least one rank first."); return 0 end
	if GuildRoster then GuildRoster() end
	local list = onlineGuildies(iv.ranks)
	local names = {}
	for _, m in ipairs(list) do names[#names + 1] = m.name end
	return I.InviteNames(names)
end

-- The list currently "loaded" for group auto-assignment: name -> desired group.
-- Set when you invite a list; used as members accept (RAID_ROSTER_UPDATE).
local activeComp = nil    -- { [nameLower] = group, listName = ..., raw = members }

-- Invite everyone on a saved list. Also arms group auto-assignment from that
-- list's comp, so people are moved to their group as they accept.
function I.InviteList(listName)
	local iv = db()
	local members = listMembers(iv, listName)
	if not members or #members == 0 then Print("List '" .. tostring(listName) .. "' is empty."); return 0 end
	I.LoadComp(listName)         -- arm auto-assign for this comp
	local names = {}
	for _, m in ipairs(members) do names[#names + 1] = m.name end
	return I.InviteNames(names)
end

-- Arm the group map from a saved list (so auto-assign + Arrange use it).
function I.LoadComp(listName)
	local iv = db()
	local members = listMembers(iv, listName)
	if not members then activeComp = nil; return end
	local map = { listName = listName, raw = members }
	for _, m in ipairs(members) do if m.group then map[m.name:lower()] = m.group end end
	activeComp = map
end

-- ------------------------------------------------------------
-- Group assignment (SetRaidSubgroup) -- put raiders into their comp group.
-- Only works in a raid; needs group lead/assist. Arrange() does a full pass over
-- everyone currently in the raid; assignOne() handles a single joiner.
-- ------------------------------------------------------------
local function raidIndexOf(name)
	local n = (GetNumRaidMembers and GetNumRaidMembers()) or 0
	for i = 1, n do
		local rn, _, subgroup = GetRaidRosterInfo(i)
		if rn == name then return i, subgroup end
	end
	return nil
end

local function assignOne(name)
	if not activeComp then return end
	local want = activeComp[name:lower()]
	if not want or want < 1 or want > 8 then return end
	local idx, cur = raidIndexOf(name)
	if not idx or cur == want then return end
	if SetRaidSubgroup then SetRaidSubgroup(idx, want) end
end

-- full pass: move every raider we have a comp group for. Safe to click repeatedly.
function I.Arrange()
	if not activeComp then Print("No comp loaded -- invite a saved list first."); return end
	if (GetNumRaidMembers and GetNumRaidMembers() or 0) == 0 then Print("Not in a raid yet."); return end
	local n = GetNumRaidMembers()
	local moved = 0
	for i = 1, n do
		local rn = GetRaidRosterInfo(i)
		if rn then
			local want = activeComp[rn:lower()]
			if want then
				local _, cur = raidIndexOf(rn)
				if cur ~= want and SetRaidSubgroup then SetRaidSubgroup(i, want); moved = moved + 1 end
			end
		end
	end
	Print("Arranged " .. moved .. " raider(s) into comp groups.")
end

-- ------------------------------------------------------------
-- saved lists (members = { {name=, group=}, ... })
-- ------------------------------------------------------------
function I.SaveList(listName, members)
	if not listName or listName == "" then return end
	local iv = db()
	iv.lists[listName] = { members = members or {} }
	if I.onChange then I.onChange() end
end

function I.AddToList(listName, name, group)
	if not listName or not name or name == "" then return end
	local iv = db()
	local l = iv.lists[listName]; if not l then l = { members = {} }; iv.lists[listName] = l end
	name = (name:gsub("%-.*$", ""))
	for _, m in ipairs(l.members) do if m.name == name then if group then m.group = group end return end end
	l.members[#l.members + 1] = { name = name, group = group }
	if I.onChange then I.onChange() end
end

function I.RemoveFromList(listName, name)
	local iv = db()
	local l = iv.lists[listName]; if not l then return end
	for i = #l.members, 1, -1 do if l.members[i].name == name then table.remove(l.members, i) end end
	if I.onChange then I.onChange() end
end

-- ---- saved-list helpers for the Invite UI's "SAVED LISTS" panel ----
-- Lists ALREADY persist in the account DB (iv.lists) the moment you add a name,
-- so these are thin conveniences: a name->members map, and clear aliases.
function I.SavedLists()
	local out = {}
	local iv = db()
	for name, l in pairs(iv.lists) do out[name] = (l and l.members) or {} end
	return out
end
-- "Save list" is really just a confirmation the list exists (it already persists).
function I.PersistList(listName)
	if not listName or listName == "" then return end
	local iv = db()
	if not iv.lists[listName] then iv.lists[listName] = { members = {} } end
	if I.onChange then I.onChange() end
end
-- Loading a saved list is just switching the working list name to it (the UI does
-- that); provided as a named entry point for clarity / future hooks.
function I.LoadSavedList(listName) return I.ListMembers(listName) end
I.DeleteSavedList = function(listName) return I.DeleteList(listName) end

function I.DeleteList(listName)
	local iv = db()
	iv.lists[listName] = nil
	if iv.autoLoginList == listName then iv.autoLoginList = "" end
	if activeComp and activeComp.listName == listName then activeComp = nil end
	if I.onChange then I.onChange() end
end

-- ------------------------------------------------------------
-- JSON / paste import -- lenient. Handles:
--   * Composition/Raid-Helper exports: a "slots":[ {..,"name":"X",..}, .. ] array
--     (we take ONLY slot names, never the classes[]/groups[] name fields).
--   * a plain comma / newline / space separated list of names.
-- Names are cleaned like the RATS website normName: strip [..] and (..) tags,
-- take the first of "A/B" or "A|B" or "A,B", drop trailing emoji/flags, keep the
-- leading letter run. e.g. "Shockaa[SHAKA]" -> Shockaa, "Lecoque/Chims" -> Lecoque,
-- "Franzherman<flag>" -> Franzherman. De-dupes, WoW-capitalizes.
-- ------------------------------------------------------------
local function cleanName(raw)
	if not raw or raw == "" then return nil end
	local n = raw
	n = n:gsub("%[.-%]", ""):gsub("%(.-%)", "")   -- drop [tags] and (notes)
	n = n:gsub("%-.*$", "")                          -- drop realm
	n = n:match("^%s*([^/|,]+)") or n                -- first of A/B, A|B, A,B
	-- keep only the leading run of letters (ASCII + Latin-1 accented bytes),
	-- which strips trailing emoji/flag codepoints and spaces
	n = n:match("([A-Za-z\192-\255]+)") or ""
	if #n < 2 then return nil end
	return n:sub(1, 1):upper() .. n:sub(2):lower()
end

-- Parse into MEMBERS: { {name=, group=}, ... }. `group` is the raid subgroup 1-5
-- (nil if unknown). De-dupes by name. Handles the composition export's groupNumber
-- and slotNumber, a generic names JSON, OR a pasted grid where each LINE is a group
-- (line 1 = group 1, etc.) with names separated by commas; "-" = empty slot.
function I.ParseMembers(text)
	if not text or text == "" then return {} end
	local seen, out = {}, {}
	local function add(raw, group)
		local n = cleanName(raw)
		if not n then return end
		local key = n:lower()
		if seen[key] then
			if group and not seen[key].group then seen[key].group = group end
			return
		end
		local m = { name = n, group = group }
		seen[key] = m; out[#out + 1] = m
	end

	-- 1) Composition/Raid-Helper: pull name + groupNumber from each slot object ONLY.
	local slotsBlock = text:match('"slots"%s*:%s*(%b[])')
	if slotsBlock then
		for obj in slotsBlock:gmatch("%b{}") do
			local nm = obj:match('"name"%s*:%s*"([^"]+)"')
			local grp = tonumber(obj:match('"groupNumber"%s*:%s*(%d+)'))
			if nm then add(nm, grp) end
		end
		if #out > 0 then return out end
	end

	-- 2) generic JSON name-ish keys (no group info)
	local hadField = false
	for _, field in ipairs({ "name", "character", "char", "player", "user", "nickname" }) do
		for v in text:gmatch('"' .. field .. '"%s*:%s*"([^"]+)"') do
			hadField = true; add(v, nil)
		end
	end
	if hadField and #out > 0 then return out end

	-- 3) plain TEXT list -- any Raid-Helper "Players" export (space / , / ; delimited,
	-- horizontal or vertical). We do NOT infer groups from text layout: horizontal vs
	-- vertical grids are indistinguishable from raw text, so a wrong guess would put
	-- people in the wrong raid group. Use the JSON export when you want group assignment.
	-- "-" = empty slot (skipped).
	for tok in text:gmatch("[^%s,;]+") do
		if tok ~= "-" then add(tok, nil) end
	end
	return out
end

-- back-compat: names-only view of ParseMembers
function I.ParseNames(text)
	local out = {}
	for _, m in ipairs(I.ParseMembers(text)) do out[#out + 1] = m.name end
	return out
end

-- import `text` into a named list (merges, de-dupes, keeps group numbers).
-- If `replace` is true the list is overwritten with exactly the imported comp.
function I.ImportToList(listName, text, replace)
	local members = I.ParseMembers(text)
	if #members == 0 then Print("No names found in that text."); return 0 end
	if replace then I.SaveList(listName, {}) end
	for _, m in ipairs(members) do I.AddToList(listName, m.name, m.group) end
	local withGroups = 0
	for _, m in ipairs(members) do if m.group then withGroups = withGroups + 1 end end
	Print("Imported " .. #members .. " name(s) into '" .. listName .. "'"
		.. (withGroups > 0 and (" (" .. withGroups .. " with groups).") or "."))
	return #members
end

-- Master switch for keyword-invite. MUTUALLY EXCLUSIVE with Recruit: both listen
-- for the same keyword ("inv") on whisper, so only one may run at a time -- turning
-- this ON turns Recruit's advertising OFF, and vice-versa (Recruit calls us too).
function I.KeywordEnabled() return db().keywordEnabled and true or false end
function I.SetKeywordEnabled(on)
	on = on and true or false
	db().keywordEnabled = on
	if on then
		-- can't have both grabbing "inv" -- stand Recruit down.
		if RecruitDB and RecruitDB.active and Rec_ToggleActive then
			Rec_ToggleActive(false)
			Print("Recruit advertising turned OFF (can't share the invite keyword).")
		end
		Print("keyword-invite |cff7cfc8aON|r.")
	else
		Print("keyword-invite |cffff5555OFF|r.")
	end
	if I.onChange then I.onChange() end
end

-- ------------------------------------------------------------
-- events: keyword whisper-invite, decline/offline retry, on-login auto-invite
-- ------------------------------------------------------------
-- build patterns from WoW globals so join/decline detection is locale-safe
local function mkPat(fmt) local p = (fmt or ""):gsub("[%(%)%.%+%-%*%?%[%]%^%$]", "%%%0"); return (p:gsub("%%s", "(.+)")) end
local PAT_DECLINE = ERR_INVITE_PLAYER_S and mkPat(ERR_DECLINE_GROUP_S or "%s declines your group invitation.")

-- Parse the keyword setting into a list. Multiple keywords are allowed, split on
-- comma/space/semicolon -- e.g. "inv, invite, ginv" all trigger.
local function keywordList(iv)
	local out = {}
	for w in (iv.keyword or "inv"):lower():gmatch("[^%s,;]+") do out[#out + 1] = w end
	return out
end

-- Does the message contain any keyword as a WHOLE word? (so "inv" matches "inv"
-- and "inv pls" but NOT "invisible"). Frontier pattern %f guards word edges.
local function msgHasKeyword(msg, list)
	local lc = " " .. msg:lower() .. " "
	for _, kw in ipairs(list) do
		if kw ~= "" and lc:find("%f[%w]" .. kw:gsub("(%W)", "%%%1") .. "%f[%W]") then
			return true
		end
	end
	return false
end

-- shared keyword-invite: if `sender` said ANY keyword, pull them into the group.
local function keywordInvite(msg, sender, where)
	local iv = db()
	if not sender or not msg then return end
	local list = keywordList(iv)
	if #list == 0 then return end
	if not msgHasKeyword(msg, list) then return end
	if not canAutoInvite() then return end
	local clean = (sender:gsub("%-.*$", ""))
	if inviteOne(clean) then
		Print("Invited " .. clean .. " (" .. (where or "chat") .. " keyword).")
		if I.onChange then I.onChange() end
	end
end

-- Modulo DESLIGADO nos Modules = como se nao existisse: nao auto-invita, nao reage
-- a chat, nada. (Nao basta esconder a UI -- estar numa dungeon com o modulo ligado
-- "por baixo" fazia guildies entrarem na party sem querer.)
local function module_on()
	return not Okanvil.IsModuleEnabled or Okanvil:IsModuleEnabled("__invite")
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("CHAT_MSG_WHISPER")
ev:RegisterEvent("CHAT_MSG_GUILD")     -- keyword in guild chat
ev:RegisterEvent("CHAT_MSG_SYSTEM")
ev:SetScript("OnEvent", function(_, event, arg1, arg2)
	if not module_on() then return end
	local iv = db()
	-- keyword-invite is gated by the MASTER switch (iv.keywordEnabled). The
	-- per-channel toggles only matter when the master is on. This also keeps it
	-- mutually exclusive with Recruit (see I.SetKeywordEnabled).
	if event == "CHAT_MSG_WHISPER" then
		if iv.keywordEnabled and iv.whisperInvite then keywordInvite(arg1, arg2, "whisper") end
		return
	end
	if event == "CHAT_MSG_GUILD" then
		if iv.keywordEnabled and iv.guildInvite then keywordInvite(arg1, arg2, "guild") end
		return
	end
	if event == "CHAT_MSG_SYSTEM" then
		local m = arg1 or ""
		-- retry on decline
		if iv.retry and PAT_DECLINE then
			local who = m:match(PAT_DECLINE)
			if who then
				who = (who:gsub("%-.*$", ""))
				-- re-arm: back-date the cooldown so the OnUpdate retry fires soon, but
				-- ONLY if this name is still pending and under the try cap (a decline
				-- doesn't reset the counter -> a hard "no" won't loop forever).
				local p = pending[who]
				if p and (p.tries or 0) < MAX_TRIES then
					p.t = (GetTime and GetTime() or 0) - (iv.retryCooldown or 30) + 5
				end
				return
			end
		end
	end
end)

-- retry loop: re-invite pending names whose cooldown elapsed and who still aren't
-- grouped (covers declines + offline-then-online). Cheap 1s tick, only while we
-- actually have pending invites.
ev:SetScript("OnUpdate", function(self, e)
	self._t = (self._t or 0) + e
	if self._t < 1 then return end
	self._t = 0
	if not module_on() then return end
	local iv = Okanvil.db and Okanvil.db.invite
	if not iv or not iv.retry then return end
	local now = GetTime and GetTime() or 0
	local cd = iv.retryCooldown or 30
	for name, p in pairs(pending) do
		if inMyGroup(name) then
			pending[name] = nil                       -- joined -> done
		elseif (p.tries or 0) >= MAX_TRIES then
			pending[name] = nil                       -- gave up -> STOP re-inviting (no spam)
		elseif (now - (p.t or 0)) >= cd then
			if InviteUnit then InviteUnit(name) end
			p.t = now
			p.tries = (p.tries or 0) + 1
		end
	end
end)

-- On-login auto-invite: watch GUILD roster online flips (more reliable than the
-- friend line for guildies). Poll the roster diff on GUILD_ROSTER_UPDATE.
local wasOnline = {}
local gev = CreateFrame("Frame")
gev:RegisterEvent("GUILD_ROSTER_UPDATE")
gev:SetScript("OnEvent", function()
	if not module_on() then return end
	local iv = Okanvil.db and Okanvil.db.invite
	if not iv or iv.autoLoginList == "" then return end
	-- SAFETY: only auto-invite when it's legitimate (solo, or lead/assist of a
	-- pure-guild group). Never when in someone else's group or a pug raid.
	if not canAutoInvite() then return end
	local l = iv.lists[iv.autoLoginList]
	local members = l and l.members
	if not members or #members == 0 then return end
	-- build a quick name->online map
	if SetGuildRosterShowOffline then SetGuildRosterShowOffline(true) end
	local total = (GetNumGuildMembers and GetNumGuildMembers()) or 0
	local online = {}
	for i = 1, total do
		local name, _, _, _, _, _, _, _, isOn = GetGuildRosterInfo(i)
		if name then online[(name:gsub("%-.*$", ""))] = isOn and true or false end
	end
	for _, m in ipairs(members) do
		local n = m.name
		local now = online[n]
		if now and wasOnline[n] == false then   -- just flipped offline->online
			if inviteOne(n) then Print("Auto-invited " .. n .. " (came online).") end
		end
		if now ~= nil then wasOnline[n] = now end
	end
end)

-- Auto-assign to comp group as people accept: when the raid roster changes and a
-- comp is loaded (via InviteList/LoadComp), move any raider we have a group for.
local rev = CreateFrame("Frame")
rev:RegisterEvent("RAID_ROSTER_UPDATE")
rev:SetScript("OnEvent", function()
	local iv = Okanvil.db and Okanvil.db.invite
	if not iv or not iv.autoAssign or not activeComp then return end
	if (GetNumRaidMembers and GetNumRaidMembers() or 0) == 0 then return end
	-- one pass: cheap, idempotent (assignOne skips anyone already in the right group)
	local n = GetNumRaidMembers()
	for i = 1, n do
		local rn = GetRaidRosterInfo(i)
		if rn then assignOne(rn) end
	end
end)
