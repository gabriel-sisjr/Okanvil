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

local G = Okanvil.Guild

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
		for _, m in ipairs(G.Roster()) do guild[m.name] = true end
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
	local me = UnitName and UnitName("player")
	for _, m in ipairs(G.Roster()) do
		if m.online and m.name ~= me then
			if (not rankFilter) or rankFilter[m.rankIndex] then
				out[#out + 1] = { name = m.name, rankIndex = m.rankIndex, rank = m.rank or "" }
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
	local online = {}
	for _, m in ipairs(G.Roster()) do online[m.name] = m.online end
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

-- ------------------------------------------------------------
-- Invite dashboard UI -- registered below as the "__invite" plugin (build once,
-- refresh on every show via Okanvil:ShowPanel's generic plugin dispatch).
-- ------------------------------------------------------------
local W = Okanvil.W
local C = Okanvil.Colors
local FLAT = "Interface\\ChatFrame\\ChatFrameBackground"

local inviteFill        -- shared panel handle: Invite_BuildUI sets it, Invite_BuildLists reads it
local inviteRefreshAll  -- bridges Invite_BuildUI's local refreshAll to Invite_Refresh below

-- ---- Invite: My Lists tab -- see each saved list's members, load / arm / delete ----
local function Invite_BuildLists(p)
	local I = Okanvil.Invite
	local fill = inviteFill
	if not I then
		local w = W.Text(p, "|cffff8888Invite engine not loaded.|r", 12, "dim"); w:SetPoint("TOPLEFT", 8, -8)
		return
	end
	local X = 8
	local hint = W.Text(p, "Your saved raid lists. Load one to edit/invite it, arm Auto to invite it when its members log in, or delete it.", 10, "dim")
	hint:SetPoint("TOPLEFT", X, -6); hint:SetPoint("RIGHT", p, "RIGHT", -X, 0); hint:SetJustifyH("LEFT")
	local safe = W.Text(p, "|cff7cfc8aSafe:|r |cff8a8d93Auto-invite only fires when you're solo, or the leader/assistant of a pure-guild group -- never in someone else's group or a pug raid.|r", 10, "dim")
	safe:SetPoint("TOPLEFT", X, -22); safe:SetPoint("RIGHT", p, "RIGHT", -X, 0); safe:SetJustifyH("LEFT")

	local rows, detail = {}, {}
	local expanded = nil
	local function rebuild()
		for _, r in ipairs(rows) do r:Hide() end
		for _, t in ipairs(detail) do t:Hide() end
		local lists = I.SavedLists()
		local names = {}
		for name in pairs(lists) do names[#names + 1] = name end
		table.sort(names)
		if #names == 0 then
			p._empty = p._empty or W.Text(p, "", 11, "dim")
			p._empty:ClearAllPoints(); p._empty:SetPoint("TOPLEFT", X, -60)
			p._empty:SetText("|cff6f7176No saved lists yet. Build one in the Invite page (pick raiders, name it, Save list).|r")
			p._empty:Show(); p:SetHeight(120); return
		end
		if p._empty then p._empty:Hide() end
		local di, y = 0, 60
		for i, name in ipairs(names) do
			local members = lists[name] or {}
			local r = rows[i]
			if not r then
				r = W.Frame(p, "input")
				r.name = W.Text(r, "", 13); r.name:SetPoint("LEFT", 10, 0)
				r.del  = W.Button(r, "Delete", "danger"); r.del:SetSize(60, 22); r.del:SetPoint("RIGHT", -8, 0)
				r.auto = W.Button(r, "Auto"); r.auto:SetSize(54, 22); r.auto:SetPoint("RIGHT", r.del, "LEFT", -6, 0)
				r.load = W.Button(r, "Load"); r.load:SetSize(54, 22); r.load:SetPoint("RIGHT", r.auto, "LEFT", -6, 0)
				r:EnableMouse(true)
				rows[i] = r
			end
			r:ClearAllPoints(); r:SetPoint("TOPLEFT", X, -y); r:SetPoint("RIGHT", p, "RIGHT", -X, 0); r:SetHeight(30)
			local armed = (I.db().autoLoginList == name)
			local isOpen = (expanded == name)
			r.name:SetText((isOpen and "|cffffd200v|r  " or "|cff8a8d93>|r  ") .. name
				.. "  |cff8a8d93(" .. #members .. ")|r" .. (armed and "  |cff7cfc8a[auto]|r" or ""))
			r.load:SetScript("OnClick", function()
				if fill and fill.SetActiveList then fill:SetActiveList(name) end  -- switch active list + refresh page
				if fill and fill.dash then fill.dash:CloseOverlay() end          -- back to the picker
				Okanvil:Print("Loaded list '" .. name .. "' (" .. #members .. ") -- now editing it.")
			end)
			r.auto:SetScript("OnClick", function()
				local iv = I.db(); iv.autoLoginList = (iv.autoLoginList == name) and "" or name
				Okanvil:Print(iv.autoLoginList == name and ("Auto-invite armed for '" .. name .. "'.") or "Auto-invite disarmed.")
				rebuild()
			end)
			r.del:SetScript("OnClick", function()
				if expanded == name then expanded = nil end
				if I.DeleteSavedList then I.DeleteSavedList(name) end
				rebuild()
			end)
			-- expand/collapse the member list on click of the row (not the buttons)
			r:SetScript("OnMouseUp", function()
				expanded = (expanded == name) and nil or name; rebuild()
			end)
			r:Show()
			y = y + 34
			if isOpen then
				di = di + 1
				local t = detail[di]
				if not t then
					t = W.Text(p, "", 11); t:SetJustifyH("LEFT"); t:SetJustifyV("TOP")
					if t.SetWordWrap then t:SetWordWrap(true) end
					detail[di] = t
				end
				-- give the fontstring an EXPLICIT width (the scroll child's real width
				-- minus our left indent + right pad) so the names actually wrap to
				-- multiple lines instead of overflowing off the right edge.
				local wpx = math.max(100, (p:GetWidth() or 400) - (X + 16) - X)
				t:ClearAllPoints(); t:SetPoint("TOPLEFT", X + 16, -y); t:SetWidth(wpx)
				if #members > 0 then
					local nm = {}
					for k = 1, #members do nm[k] = members[k].name end
					table.sort(nm)
					t:SetText("|cffdcddde" .. table.concat(nm, "  |cff5e6166\194\183|r  ") .. "|r")
				else
					t:SetText("|cff888888(empty list)|r")
				end
				t:Show()
				y = y + (t:GetStringHeight() or 12) + 12
			end
		end
		p:SetHeight(math.max(y + 10, 200))
		local sf = p:GetParent()          -- the overlay scrollframe owns _relayout
		if sf and sf._relayout then sf._relayout() end
	end
	fill._rebuildLists = rebuild
	rebuild()
end

local function Invite_BuildUI(panel)
	local host = panel
	local I = Okanvil.Invite
	local G = Okanvil.Guild

	-- Dashboard shell (MRT/Recruit-style): header (icon + title + CTA), no tabs,
	-- no drawer -> the two-column control/roster layout scrolls in one panel.
	local dash = W.Dashboard(host, {
		title = "Invite",
		icon = Okanvil.ICONS.invite,
		drawerWidth = 0,
		footerHeight = 0,
		-- Header ON/OFF for AUTO-INVITE (like the Logs REC button) -- mais visivel
		-- que a checkbox. Este e o master switch do keyword/on-login auto-invite:
		-- OFF = nenhum auto-invite mesmo com listas armadas (nao deixa guildies cair
		-- na tua party numa dungeon). A checkbox de baixo foi removida (era duplicada).
		primaryText = function()
			if not I then return "" end
			return I.KeywordEnabled() and "|cff7cfc8aAuto-Invite: ON|r" or "|cff8a8d93Auto-Invite: OFF|r"
		end,
		onPrimary = function()
			if not I then return end
			I.SetKeywordEnabled(not I.KeywordEnabled())
			if Okanvil.RefreshPanel then Okanvil:RefreshPanel() end
		end,
		statusText = function()
			if not I then return "|cffff5555engine not loaded|r" end
			return ""
		end,
		tabs = {
			{ key = "lists", label = "My Lists", height = 460, build = function(pg) Invite_BuildLists(pg) end },
		},
	})
	panel.dash = dash

	-- The page fills dash.main DIRECTLY -- no page-level scroll (the whole Invite
	-- page must never scroll). Only the roster on the right scrolls internally.
	-- The left column is short enough to always fit.
	local main = dash.main
	local X = 14
	local p = main
	local wrap = { relayout = function() end }   -- no page scroll to relayout

	-- Invite.lua provides the engine (Okanvil.Invite). If it isn't loaded, show a
	-- note instead of erroring (nil-index) so the tab never crashes the UI.
	if not I then
		local warn = W.Text(p, "", 12, "dim"); warn:SetPoint("TOPLEFT", X, -14)
		warn:SetPoint("RIGHT", p, "RIGHT", -X, 0); warn:SetJustifyH("LEFT")
		warn:SetText("|cffff8888The Invite engine (Invite.lua) isn't loaded.|r\n\n"
			.. "|cff888888Make sure Invite.lua is in the Okanvil folder and listed in Okanvil.toc, then /reload.|r")
		p:SetHeight(160); wrap.relayout(); return
	end

	-- The current working list name (all list actions use this).
	local curList = "Raid"

	-- ============================================================
	-- LEFT COLUMN = controls (fixed width). RIGHT COLUMN = list manager.
	-- Both start flush at the top -- no full-width intro banner (it pushed
	-- everything down and forced the page to scroll).
	-- ============================================================
	local LEFT_W = 340
	-- The controls column can be TALLER than the window (many guild ranks + all the
	-- keyword/list sections). Put it in its own ScrollFrame that stretches to the
	-- page bottom, so the footer ("Pick raiders...") is reachable by scrolling
	-- instead of being clipped. Mirrors the roster card on the right.
	local lsf = CreateFrame("ScrollFrame", nil, p)
	lsf:SetPoint("TOPLEFT", X, -10); lsf:SetWidth(LEFT_W + 8)
	lsf:SetPoint("BOTTOM", p, "BOTTOM", 0, 10)
	local left = W.Frame(lsf, "bare"); left:SetWidth(LEFT_W); left:SetHeight(560)
	lsf:SetScrollChild(left)
	local lsb = CreateFrame("Slider", nil, p)
	lsb:SetPoint("TOPLEFT", lsf, "TOPRIGHT", -4, 0); lsb:SetPoint("BOTTOMLEFT", lsf, "BOTTOMRIGHT", -4, 0); lsb:SetWidth(4)
	lsb:SetOrientation("VERTICAL"); lsb:SetValueStep(1)
	local lth = lsb:CreateTexture(nil, "OVERLAY"); lth:SetTexture(FLAT); lth:SetSize(4, 30)
	do local a = Okanvil.Colors.accent; lth:SetVertexColor(a[1], a[2], a[3], 1) end
	lsb:SetThumbTexture(lth)
	lsb:SetScript("OnValueChanged", function(_, v) lsf:SetVerticalScroll(v) end)
	lsf:EnableMouseWheel(true)
	lsf:SetScript("OnMouseWheel", function(_, d) lsb:SetValue(lsb:GetValue() - d * 28) end)
	-- keep the scrollbar range in sync with the column's real content height
	local function leftRelayout()
		local maxS = math.max(0, left:GetHeight() - lsf:GetHeight())
		lsb:SetMinMaxValues(0, maxS)
		lsb:SetShown(maxS > 0)
	end
	lsf:SetScript("OnSizeChanged", leftRelayout)
	wrap._leftRelayout = leftRelayout

	-- ---- invite BY RANK ----
	-- Two ways to invite: (1) BY RANK -- tick ranks, hit the button; (2) THIS LIST --
	-- pick names on the right, hit the list button. We never blanket-invite everyone.
	local qh = W.Text(left, "INVITE BY RANK", 11, "accent"); qh:SetPoint("TOPLEFT", 0, 0)
	local qsub = W.Text(left, "Tick the ranks to invite, then click.", 10, "dim"); qsub:SetPoint("TOPLEFT", 0, -18)

	-- rank checkboxes bound to iv.ranks[rankIndex], built once from the roster. The
	-- sections below anchor to `rankAnchor`, which grows with the number of ranks so
	-- nothing ever overlaps the next section.
	local rankChecks = {}
	local rankAnchor = W.Frame(left, "bare"); rankAnchor:SetPoint("TOPLEFT", 0, -40); rankAnchor:SetSize(1, 1)
	local rankBuilt = false
	local function buildRankChecks()
		if rankBuilt then for _, c in ipairs(rankChecks) do c.refresh() end; return end
		local iv = I.db()
		local seen, ranks = {}, {}
		for _, m in ipairs(G.Roster()) do
			local ridx = m.rankIndex
			if ridx and not seen[ridx] then
				seen[ridx] = true
				ranks[#ranks + 1] = { idx = ridx, name = (m.rank and m.rank ~= "" and m.rank) or ("Rank " .. ridx) }
			end
		end
		if #ranks == 0 then return end
		table.sort(ranks, function(a, b) return a.idx < b.idx end)
		local cx, cy = 0, 0
		for i, r in ipairs(ranks) do
			local idx = r.idx
			local c = W.Check(rankAnchor, r.name, function() return iv.ranks[idx] end,
				function(v) iv.ranks[idx] = v and true or false end)
			c:SetPoint("TOPLEFT", cx, cy)
			rankChecks[#rankChecks + 1] = c
			cx = cx + 165
			if i % 2 == 0 then cx = 0; cy = cy - 28 end       -- roomier rows
		end
		-- final height of the rank block so the button + sections sit below it
		rankAnchor:SetHeight(math.max(28, math.ceil(#ranks / 2) * 28))
		rankBuilt = true
	end

	local bRank = W.Button(left, "Invite by rank", "primary")
	bRank:SetSize(150, 26); bRank:SetPoint("TOPLEFT", rankAnchor, "BOTTOMLEFT", 0, -10)
	bRank:SetScript("OnClick", function() I.InviteByRank() end)

	-- ---- keyword invite (whisper/guild sub-toggles) ----
	-- O MASTER enable ("Auto-Invite: ON/OFF") vive no header do Dashboard, nao aqui
	-- (era duplicado). Mantemos so o aviso de exclusao com o Recruit + os sub-toggles.
	local whlbl = W.Text(left, "KEYWORD INVITE", 11, "accent"); whlbl:SetPoint("TOPLEFT", bRank, "BOTTOMLEFT", 0, -18)
	local kwWarn = W.Text(left, "|cff8a8d93Can't run with Recruit (shared keyword) -- enabling one disables the other.|r", 10, "dim")
	kwWarn:SetPoint("TOPLEFT", whlbl, "BOTTOMLEFT", 0, -8); kwWarn:SetWidth(LEFT_W); kwWarn:SetJustifyH("LEFT")

	local wChk = W.Check(left, "On whisper", function() return I.db().whisperInvite end,
		function(v) I.db().whisperInvite = v end)
	wChk:SetPoint("TOPLEFT", kwWarn, "BOTTOMLEFT", 0, -10)
	local gChk = W.Check(left, "On guild chat", function() return I.db().guildInvite end,
		function(v) I.db().guildInvite = v end)
	gChk:SetPoint("LEFT", wChk, "LEFT", 165, 0)
	local kwlbl = W.Text(left, "Keywords", 10, "dim"); kwlbl:SetPoint("TOPLEFT", wChk, "BOTTOMLEFT", 0, -14)
	-- multiple keywords allowed, comma/space separated (e.g. "inv, invite, ginv").
	-- Keep the raw text; matching splits it and checks each as a whole word.
	local kwBox = W.EditBox(left, function(t) I.db().keyword = t or "" end)
	kwBox:Size(300, 22); kwBox:SetPoint("TOPLEFT", kwlbl, "BOTTOMLEFT", 0, -4)
	kwBox.edit:SetText(I.db().keyword or "inv")
	local kwhint = W.Text(left, "comma-separated -- any of them triggers an invite", 10, "dim")
	kwhint:SetPoint("TOPLEFT", kwBox, "BOTTOMLEFT", 0, -6)

	-- ---- saved list (built by picking raiders on the right) ----
	local llbl = W.Text(left, "RAID LIST", 11, "accent"); llbl:SetPoint("TOPLEFT", kwhint, "BOTTOMLEFT", 0, -18)
	local nmLbl = W.Text(left, "List name", 10, "dim"); nmLbl:SetPoint("TOPLEFT", llbl, "BOTTOMLEFT", 0, -12)
	local nmBox = W.EditBox(left); nmBox:Size(160, 22); nmBox:SetPoint("TOPLEFT", nmLbl, "BOTTOMLEFT", 0, -4)
	nmBox.edit:SetText(curList)
	nmBox.edit:SetScript("OnEditFocusLost", function(s)
		local v = (s:GetText() or ""):gsub("%s+", ""); if v == "" then v = "Raid" end
		curList = v; if wrap._rebuild then wrap._rebuild() end
	end)

	local cntLbl = W.Text(left, "", 12, "dim"); cntLbl:SetPoint("LEFT", nmBox, "RIGHT", 12, 0)

	-- action row 1: invite + clear
	local bInviteList = W.Button(left, "Invite this list", "primary")
	bInviteList:SetSize(150, 26); bInviteList:SetPoint("TOPLEFT", nmBox, "BOTTOMLEFT", 0, -12)
	bInviteList:SetScript("OnClick", function() I.InviteList(curList) end)
	local bClear = W.Button(left, "Clear")
	bClear:SetSize(70, 26); bClear:SetPoint("LEFT", bInviteList, "RIGHT", 8, 0)
	bClear:SetScript("OnClick", function() I.SaveList(curList, {}); if wrap._rebuild then wrap._rebuild() end end)

	-- action row 2: save (lists persist; this just confirms + refreshes My Lists)
	local bSave = W.Button(left, "Save list")
	bSave:SetSize(100, 24); bSave:SetPoint("TOPLEFT", bInviteList, "BOTTOMLEFT", 0, -8)
	bSave:SetScript("OnClick", function()
		if I.PersistList then I.PersistList(curList) end
		Okanvil:Print("Saved list '" .. curList .. "'.")
		if wrap._rebuildSaved then wrap._rebuildSaved() end
	end)

	local alChk = W.Check(left, "Auto-invite this list when they log in",
		function() local iv = I.db(); return iv.autoLoginList == curList and curList ~= "" end,
		function(v)
			local iv = I.db()
			iv.autoLoginList = (v and curList ~= "") and curList or ""
			if v and curList ~= "" then Okanvil:Print("Armed auto-invite for '" .. curList .. "' on login.") end
		end)
	alChk:SetPoint("TOPLEFT", bSave, "BOTTOMLEFT", 0, -12)

	local pinfo = W.Text(left, "Pick raiders on the right -- click a name to add/remove it. Saved lists live in the My Lists tab above.", 10, "dim")
	pinfo:SetPoint("TOPLEFT", alChk, "BOTTOMLEFT", 0, -8); pinfo:SetWidth(LEFT_W); pinfo:SetJustifyH("LEFT")

	-- ============================================================
	-- RIGHT COLUMN = ROSTER PICKER: real guildies grouped by rank, class-coloured,
	-- click to toggle into the current list. Names are the true in-game names, so
	-- invites always match (no fuzzy sign-up name problems).
	-- ============================================================
	local rcard = W.Frame(p, "input")
	rcard:SetPoint("TOPLEFT", X + LEFT_W + 16, -10)
	rcard:SetPoint("RIGHT", p, "RIGHT", -X, 0)
	rcard:SetPoint("BOTTOM", p, "BOTTOM", 0, 10)   -- fill down to the page bottom; only THIS scrolls
	local rhdr = W.Text(rcard, "GUILD ROSTER", 11, "dim"); rhdr:SetPoint("TOPLEFT", 10, -8)

	-- search filter: narrows the roster AS YOU TYPE (empty box = show everyone).
	-- Sits on its own row under the header so it never overlaps the label.
	local rfilter = ""
	local fBox = W.EditBox(rcard)
	fBox:Size(200, 20); fBox:SetPoint("TOPLEFT", 10, -26); fBox:SetPoint("RIGHT", rcard, "RIGHT", -12, 0)
	local fGhost = W.Text(fBox, "|cff777777type a name to filter...|r", 10, "dim"); fGhost:SetPoint("LEFT", 6, 0)
	fBox.edit:SetScript("OnTextChanged", function(s)
		local t = s:GetText() or ""
		fGhost:SetShown(t == "")
		rfilter = string.lower(t:gsub("^%s*(.-)%s*$", "%1"))
		if wrap._rebuildPicker then wrap._rebuildPicker() end
	end)

	local rsf = CreateFrame("ScrollFrame", nil, rcard)
	rsf:SetPoint("TOPLEFT", 8, -52); rsf:SetPoint("BOTTOMRIGHT", -12, 8)
	local rchild = CreateFrame("Frame", nil, rsf); rchild:SetSize(10, 1); rsf:SetScrollChild(rchild)
	local rsb = CreateFrame("Slider", nil, rcard)
	rsb:SetPoint("TOPRIGHT", -3, -52); rsb:SetPoint("BOTTOMRIGHT", -3, 8); rsb:SetWidth(4)
	rsb:SetOrientation("VERTICAL"); rsb:SetValueStep(1)
	local rth = rsb:CreateTexture(nil, "OVERLAY"); rth:SetTexture(FLAT); rth:SetSize(4, 30)
	do local a = Okanvil.Colors.accent; rth:SetVertexColor(a[1], a[2], a[3], 1) end
	rsb:SetThumbTexture(rth)
	rsb:SetScript("OnValueChanged", function(_, v) rsf:SetVerticalScroll(v) end)
	rsf:EnableMouseWheel(true)
	rsf:SetScript("OnMouseWheel", function(_, d) rsb:SetValue(rsb:GetValue() - d * 28) end)
	rsf:SetScript("OnSizeChanged", function() rchild:SetWidth(rsf:GetWidth()) end)
	wrap.pickRows = {}

	local CLASS_HEX = {
		DEATHKNIGHT="C41F3B", DRUID="FF7D0A", HUNTER="ABD473", MAGE="69CCF0", PALADIN="F58CBA",
		PRIEST="FFFFFF", ROGUE="FFF569", SHAMAN="0070DE", WARLOCK="9482C9", WARRIOR="C79C6E",
	}

	local function rebuildPicker()
		for _, r in ipairs(wrap.pickRows) do r:Hide() end
		if not (IsInGuild and IsInGuild()) then
			local r = wrap.pickRows[1]
			if not r then r = CreateFrame("Button", nil, rchild); r.txt = W.Text(r, ""); r.txt:SetPoint("LEFT", 6, 0); wrap.pickRows[1] = r end
			r:ClearAllPoints(); r:SetPoint("TOPLEFT", 0, -4); r:SetSize(200, 18)
			r.txt:SetText("|cff888888Not in a guild.|r"); r:Show(); rchild:SetHeight(30); return
		end
		-- collect members, split alts out (shared G.IsAlt rule), group by rank
		local buckets, order = {}, {}
		for _, m in ipairs(G.Roster()) do
			-- search filter: if a query is typed, keep only matching names
			local pass = (rfilter == "") or m.name:lower():find(rfilter, 1, true)
			if not G.IsAlt(m.rank, m.rankIndex, m.officernote) and pass then
				local key = m.rankIndex
				if not buckets[key] then buckets[key] = { name = m.rank or ("Rank " .. key), idx = key, list = {} }; order[#order + 1] = key end
				table.insert(buckets[key].list, { name = m.name, class = m.className, classToken = m.classToken, online = m.online })
			end
		end
		table.sort(order)
		local ri, y = 0, 4
		-- get a pooled row; the CALLER positions it (we manage x/y manually for columns)
		local function pickRow()
			ri = ri + 1
			local r = wrap.pickRows[ri]
			if not r then
				r = CreateFrame("Button", nil, rchild)
				r.mark = r:CreateTexture(nil, "ARTWORK"); r.mark:SetTexture(FLAT); r.mark:SetSize(10, 10); r.mark:SetPoint("LEFT", 6, 0)
				r.txt = W.Text(r, ""); r.txt:SetPoint("LEFT", 22, 0); r.txt:SetPoint("RIGHT", -4, 0); r.txt:SetJustifyH("LEFT"); r.txt:SetWordWrap(false)
				local hl = r:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetTexture(FLAT)
				hl:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 0.12)
				wrap.pickRows[ri] = r
			end
			-- reset to the NAME-row layout every time. Rows are pooled and a row that
			-- was last used as a rank HEADER left r.txt anchored at LEFT,6 -- if not
			-- reset, the reused name would render on top of the checkbox mark.
			r.mark:Hide(); r:SetScript("OnClick", nil)
			r.txt:ClearAllPoints(); r.txt:SetPoint("LEFT", 22, 0); r.txt:SetPoint("RIGHT", -4, 0)
			r:Show()
			return r
		end

		local COLW = 175
		local cols = math.max(1, math.floor((rsf:GetWidth() or 520) / COLW))
		for _, key in ipairs(order) do
			local b = buckets[key]
			table.sort(b.list, function(a, c) return a.name:lower() < c.name:lower() end)
			-- rank header row (full width)
			local hr = pickRow()
			hr:ClearAllPoints(); hr:SetPoint("TOPLEFT", 0, -y); hr:SetPoint("RIGHT", rchild, "RIGHT", 0, 0); hr:SetHeight(18)
			hr.txt:ClearAllPoints(); hr.txt:SetPoint("LEFT", 6, 0); hr.txt:SetPoint("RIGHT", -4, 0)
			hr.txt:SetText("|cffc0943a" .. (b.name or "") .. "|r  |cff8a8d93(" .. #b.list .. ")|r")
			y = y + 20
			-- names laid across `cols` columns
			local col = 0
			for _, m in ipairs(b.list) do
				local r = pickRow()
				r:ClearAllPoints(); r:SetPoint("TOPLEFT", col * COLW, -y); r:SetWidth(COLW - 4); r:SetHeight(18)
				local inList = I.IsInList(curList, m.name)
				r.mark:Show(); r.mark:SetVertexColor(inList and C.ok[1] or 0.3, inList and C.ok[2] or 0.3, inList and C.ok[3] or 0.34, 1)
				local hex = (m.classToken and CLASS_HEX[m.classToken]) or "dcddde"
				local off = m.online and "" or "  |cff5e6166o|r"
				r.txt:SetText("|c" .. (inList and "ff" or "aa") .. hex .. m.name .. "|r" .. off)
				local who = m.name
				r:SetScript("OnClick", function() I.ToggleInList(curList, who) end)
				col = col + 1
				if col >= cols then col = 0; y = y + 18 end
			end
			if col > 0 then y = y + 18 end
			y = y + 8
		end
		rchild:SetHeight(math.max(1, y))
		local maxs = math.max(0, y - rsf:GetHeight())
		rsb:SetMinMaxValues(0, maxs); rsb:SetShown(maxs > 4)
	end
	wrap._rebuildPicker = rebuildPicker   -- the search filter re-runs just this

	local function rebuild()
		buildRankChecks()
		rebuildPicker()
		nmBox.edit:SetText(curList)                    -- reflect the active list name
		local n = 0
		local mem = I.ListMembers(curList)
		if mem then n = #mem end
		cntLbl:SetText("|cff7cfc8a" .. n .. "|r |cff8a8d93in list|r")
		if alChk.refresh then alChk.refresh() end        -- re-read the auto-invite toggle
		-- Fit the left column to its ACTUAL content (the rank block grows with the
		-- number of guild ranks). Measuring the last element and sizing the frame
		-- from it stops the footer ("Pick raiders...") being clipped off the bottom
		-- when there are many ranks -- the old fixed 560 height guessed wrong.
		local top = left:GetTop()
		local bot = pinfo:GetBottom()
		if top and bot then left:SetHeight(math.max(1, top - bot + 6)) end
		if wrap._leftRelayout then wrap._leftRelayout() end   -- refresh the scrollbar range
	end
	wrap._rebuild = rebuild

	-- Public setter so the My Lists tab can switch the active list and have the
	-- whole page update (name box, count, auto toggle, roster ticks).
	function panel:SetActiveList(name)
		if not name or name == "" then return end
		curList = name
		rebuild()
	end

	inviteFill = panel                 -- the My Lists tab reads engine off this
	local function refreshAll()
		dash:Refresh(); rebuild()
		if panel._rebuildLists then panel._rebuildLists() end   -- keep the My Lists tab fresh
	end
	inviteRefreshAll = refreshAll
	I.onChange = function() if panel:IsShown() then refreshAll() end end
	return
end

local function Invite_Refresh()
	if GuildRoster then GuildRoster() end
	if inviteRefreshAll then inviteRefreshAll() end
end

local inviteLoginEv = CreateFrame("Frame")
inviteLoginEv:RegisterEvent("PLAYER_LOGIN")
inviteLoginEv:SetScript("OnEvent", function()
	Okanvil_Plugins = Okanvil_Plugins or {}
	Okanvil_Plugins["__invite"] = {
		title = "Invite",
		desc = "Mass-invite the guild, by rank, or from saved lists.",
		icon = Okanvil.ICONS.invite,
		build = Invite_BuildUI,
		refresh = Invite_Refresh,
	}
	if Okanvil.Register then Okanvil:Register("__invite") end
end)
