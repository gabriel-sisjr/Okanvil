-- ============================================================
-- Okanvil -- Loot (native core module).
--
-- Implements the plan in docs/LOOT_PLAN.md, combining:
--   * DROP capture, RaidRoll-style  (docs/RAIDROLL_HOW_IT_WORKS.md)
--   * WHO-RECEIVED attribution, MRT-style via CHAT_MSG_LOOT  (docs/MRT_LOOT_MODEL.md)
--   * MS/OS rolls + confirm-before-award + GiveMasterLoot
--
-- Goal: a persistent HISTORY per session/boss (item + who got it + roll + boss +
-- date), exportable to the RATS web hub.
--
-- Triggers (by context -- GetInstanceInfo instance_type):
--   RAID    -> broadcast via Okanvil.Comms: whoever detects loot tells the others.
--   DUNGEON -> START_LOOT_ROLL (native need/greed, fires on every client).
--   (LOOT_OPENED also feeds capture when WE open the corpse -- reinforcement.)
--
-- Boss: 3.3.5a has NO native ENCOUNTER_START/END, so we ported MRT's boss SCANNER
-- (Compat335) -- recognises a boss by classification/level/HP (no hardcoded list)
-- and its death from the COMBAT_LOG. Bosses are PAGES within one run/session
-- (DropsByBoss), navigated with the <> pager -- never a session per boss.
-- ============================================================

local Okanvil = Okanvil
local L = {}
Okanvil.Loot = L
local G = Okanvil.Guild

local esc = function(s)
	if Okanvil.Guild and Okanvil.Guild.esc then return Okanvil.Guild.esc(s) end
	s = tostring(s or "")
	return (s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t"))
end

local function itemIDFromLink(link)
	return link and tonumber(link:match("item:(%d+)")) or 0
end
local function shortLink(link)
	return link and link:match("(item:[%-%d:]+)") or nil
end

-- ------------------------------------------------------------
-- FILTER. allow-list forces inclusion (orbs/patterns/shards), deny-list forces
-- exclusion (emblems/gems/mats), else epic+.
-- ------------------------------------------------------------
local ACCEPT_IDS = {
	[46110] = true, -- Alchemist's Cache
	[47556] = true, -- Crusader Orb
	[45087] = true, -- Runed Orb
	[49908] = true, -- Primordial Saronite
	[45038] = true, [45039] = true, [45896] = true, [49869] = true, -- fragmentos de lendario
}
local DENY_IDS = {
	[34057] = true, -- Abyss Crystal
	[36931] = true, [36919] = true, [36928] = true, [36934] = true,
	[36922] = true, [36925] = true, -- epic gems
	[47241] = true, -- Emblem of Triumph
	[49426] = true, -- Emblem of Frost
	[40752] = true, [40753] = true, [45624] = true, [43228] = true, -- emblemas / shard
	[44990] = true, -- Champion's Seal
	[47242] = true, -- Trophy of the Crusade (token de moeda)
	[20725] = true, [22450] = true, -- crystals de DE
}
-- allow por NOME (robusto): patterns/plans/recipes + orbs + fragmentos.
local ACCEPT_NAME = {
	"pattern:", "plans:", "recipe:", "schematic:", "formula:", "design:",
	"crusader orb", "runed orb", "primordial saronite",
	"fragment of val'anyr", "shadowfrost shard",
}
local function nameHasAny(name, list)
	if not name or name == "" then return false end
	local low = name:lower()
	for _, h in ipairs(list) do if low:find(h, 1, true) then return true end end
	return false
end

-- Rarity threshold = the SETTING from the "Log items of quality" dropdown
-- (db.lootThreshold, default 3 = Rare+). It used to be hardcoded to epic (4), which
-- ignored the dropdown and ate all the blue dungeon loot (e.g. Oculus drops
-- tudo azul). Agora respeita a setting: Rare+ apanha os azuis.
local function acceptItem(id, rarity, name)
	if id ~= 0 and DENY_IDS[id] then return false end
	if id ~= 0 and ACCEPT_IDS[id] then return true end
	if nameHasAny(name, ACCEPT_NAME) then return true end
	local threshold = (Okanvil.db and Okanvil.db.lootThreshold) or 3
	return (rarity or 0) >= threshold
end

-- Zone gate: raid sempre; dungeon honra o toggle do Okanvil.
local RAID_ZONES = {
	-- WotLK
	["Trial of the Crusader"] = true, ["Icecrown Citadel"] = true,
	["Naxxramas"] = true, ["Onyxia's Lair"] = true, ["The Eye of Eternity"] = true,
	["The Obsidian Sanctum"] = true, ["Ulduar"] = true, ["Vault of Archavon"] = true,
	["The Ruby Sanctum"] = true,
	-- Classic / TBC
	["Zul'Aman"] = true, ["Zul'Gurub"] = true, ["Sunwell Plateau"] = true,
	["Serpentshrine Cavern"] = true, ["Tempest Keep"] = true, ["The Eye"] = true,
	["Hyjal Summit"] = true, ["The Battle for Mount Hyjal"] = true, ["Black Temple"] = true,
	["Gruul's Lair"] = true, ["Magtheridon's Lair"] = true, ["Karazhan"] = true,
	["Molten Core"] = true, ["Blackwing Lair"] = true,
}

local function currentContext()   -- "raid" | "party" | "world"
	if not GetInstanceInfo then return "world" end
	local _, itype = GetInstanceInfo()
	if itype == "raid" then return "raid" end
	if itype == "party" then return "party" end
	return "world"
end
local function shouldRecordHere()
	local zone = GetRealZoneText and GetRealZoneText() or ""
	local ctx = currentContext()
	if ctx == "raid" or RAID_ZONES[zone] then return Okanvil.db.recordRaid ~= false end
	if ctx == "party" then return Okanvil.db.recordDungeon ~= false end
	return false
end

-- NPC GUID? (nibble tipo & 0x7 == 3)
local function guidIsNPC(guid)
	if not guid then return false end
	local b = tonumber(guid:sub(5, 5), 16)
	return b and (b % 8) == 3
end

-- BoE probe (tooltip) -- only to tag drops for the export.
local scanTip
local function isBoE(link)
	if not link then return false end
	if not scanTip then
		scanTip = CreateFrame("GameTooltip", "OkanvilLootScanTip", nil, "GameTooltipTemplate")
		scanTip:SetOwner(UIParent, "ANCHOR_NONE")
	end
	scanTip:ClearLines(); scanTip:SetHyperlink(link)
	for i = 2, math.min(6, scanTip:NumLines()) do
		local t = _G["OkanvilLootScanTipTextLeft" .. i]
		local s = t and t:GetText()
		if s == ITEM_BIND_ON_PICKUP then return false end
		if s == ITEM_BIND_ON_EQUIP  then return true end
	end
	return false
end

-- ============================================================
-- BOSS SCANNER (ported from MRT Compat335.lua).
-- On 3.3.5a the server does NOT fire ENCOUNTER_START/END. MRT reconstructs them
-- by scanning units and recognising "boss-like" -- we ported that logic so
-- Okanvil is autonomous (no MRT needed) and just as robust.
--
-- Idea: an NPC is "boss-like" if classification worldboss, level -1/999
-- (skull), or very high maxHp -- no hardcoded list needed. On engaging
-- a boss we keep its name (currentBoss) to LABEL the loot -- which becomes a
-- PAGE (per boss) within the session/run, NOT a new session.
-- ============================================================
local currentBoss = nil       -- nome do boss atualmente engajado
local encounterBoss = nil     -- ultimo boss confirmado (para rotular loot depois da morte)
local lastCorpseBoss = nil    -- ultimo corpo NPC lootado (fallback)
local inCombatCid = nil       -- creatureID do boss em combate (para casar o UNIT_DIED)

-- creatureID a partir do GUID (MRT cidFromGUID): valida o triplet F13 (NPC) / F15
-- (vehicle) do 3.3.5a e extrai o id.
local function cidFromGUID(guid)
	if type(guid) ~= "string" or guid == "" then return nil end
	local hex = guid:match("^0x(%x+)$") or guid:match("^(%x+)$")
	if not hex then return nil end
	if #hex < 16 then hex = string.rep("0", 16 - #hex) .. hex end
	if hex:sub(1, 4) == "0000" then return nil end
	local triplet = hex:sub(1, 3):upper()
	if triplet ~= "F13" and triplet ~= "F15" then return nil end
	return tonumber(hex:sub(6, 10), 16)
end

-- "boss-like" (MRT isBossLike adapted). MRT HP threshold (>1M) only suits
-- for RAID bosses; DUNGEON bosses (5-man, e.g. Trial of the Champion) have much
-- less HP and a normal level (80-82, not -1/999), so they were REJECTED -- and all
-- drops fell on the last known boss (lumping everything on one page). Fix:
--   * worldboss / level -1/999  -> sempre boss (skull)
--   * elite/rareelite           -> boss if HP is high for the context
--   * the HP threshold is lower in a dungeon (party) than in a raid.
local function isBossLike(unit)
	if not UnitExists or not UnitExists(unit) then return false end
	if not UnitCanAttack or not UnitCanAttack("player", unit) then return false end
	if UnitIsDead and UnitIsDead(unit) then return false end
	local classif = UnitClassification and UnitClassification(unit)
	if classif == "worldboss" then return true end
	local level = (UnitLevel and UnitLevel(unit)) or 0
	if level == -1 or level == 999 then return true end   -- skull = boss
	local maxHp = (UnitHealthMax and UnitHealthMax(unit)) or 0
	local party = IsInInstance and select(2, IsInInstance()) == "party"
	-- in a dungeon a 5-man boss is ~100k-600k HP; trash is much less. An
	-- elite/rareelite with HP clearly above trash counts as a boss.
	if party then
		if (classif == "elite" or classif == "rareelite" or classif == "rare")
			and maxHp > 80000 then return true end
		return maxHp > 200000        -- fallback por HP alto para dungeon
	end
	-- raid: mantem o criterio alto (evita apanhar adds elite como "boss")
	return maxHp > 1000000
end

-- varre um unit token: se for um NPC boss-like em raid/party, engaja.
local UNIT_TOKENS = { "target", "focus", "mouseover", "boss1", "boss2", "boss3", "boss4" }
local function tryEngage(unit)
	if not (UnitExists and UnitExists(unit)) then return end
	if UnitIsFriend and UnitIsFriend("player", unit) then return end
	local guid = UnitGUID and UnitGUID(unit)
	local cid = cidFromGUID(guid)
	if not cid then return end
	-- only treat as an encounter inside an instance (raid/party) and if boss-like.
	local ctxOK = IsInInstance and IsInInstance()
	if not (ctxOK and isBossLike(unit)) then return end
	local name = (UnitName and UnitName(unit)) or ""
	if name == "" then return end
	inCombatCid = cid
	-- a new boss only changes the current NAME (the run page via dp.boss/DropsByBoss).
	-- does NOT open a new session -- bosses are pages WITHIN the same session/run.
	if currentBoss ~= name then
		currentBoss = name
		encounterBoss = name
	end
end
local function fireScan()
	for _, u in ipairs(UNIT_TOKENS) do tryEngage(u) end
	if IsInRaid and IsInRaid() then
		local n = (GetNumRaidMembers and GetNumRaidMembers()) or 0
		for i = 1, n do tryEngage("raid" .. i .. "target") end
	end
end

-- boss died -> confirm the name, clear combat state. The new page was already
-- marked on engage; here we just finalise the name and reset combat.
local function onUnitDied(destGUID)
	local cid = cidFromGUID(destGUID)
	if not cid then return end
	if cid == inCombatCid then
		inCombatCid = nil
		-- currentBoss/encounterBoss already hold the name; keep encounterBoss to
		-- label the loot that drops right after death. currentBoss = nil so the
		-- next pull is detected as new.
		currentBoss = nil
	end
end

local function resolveBoss()
	if encounterBoss and encounterBoss ~= "" then return encounterBoss end
	if lastCorpseBoss and lastCorpseBoss ~= "" then return lastCorpseBoss end
	local t = UnitName("target")
	if t and t ~= "" and guidIsNPC(UnitGUID("target")) then return t end
	local zn = GetInstanceInfo and (GetInstanceInfo()) or ""
	return (zn ~= "" and zn) or "Trash"
end

-- ------------------------------------------------------------
-- STORAGE (per-character). cdb.lootSessions = { { t,day,zone,difficulty,key,drops={} }, ... }
-- ONE session = ONE run (see runKey below). Bosses are PAGES within, via
-- DropsByBoss() -- never a session per boss.
-- ------------------------------------------------------------
local MAX_SESSIONS = 20
local lastLootAt   = 0   -- so para info; nao decide sessoes

-- db() returns the ACCOUNT-WIDE loot block (CONFIG only: collectors, rollMsg). NEVER
-- stores sessions here -- history is PER-CHARACTER (storage-model rule).
local function db()
	Okanvil.db.loot = Okanvil.db.loot or {}
	-- migration/cleanup: if an old version wrote sessions into the account file, drop them
	-- (the real loot is per-character; leaving it here gave TWO sources that
	-- diverged -- the old alias). We do this once per game session.
	Okanvil.db.loot.sessions = nil
	return Okanvil.db.loot
end

-- sessions() returns the PER-CHARACTER list (cdb.lootSessions). This is the ONLY
-- source of truth for loot history. All code/UI reads from here.
local function sessions()
	local cdb = Okanvil.cdb or Okanvil.db
	cdb.lootSessions = cdb.lootSessions or {}
	return cdb.lootSessions
end
function L.Sessions() return sessions() end

-- ------------------------------------------------------------
-- SESSION IDENTITY (runKey). ONE session = ONE instance run; bosses are
-- PAGES within (navigated with <> in the mini roll via DropsByBoss), NOT sessions.
--
--   RAID    -> "lock|<zona>|<diff>|<resetDay>"  -- junta pelo LOCKOUT: reentrar na
--              same raid ID (e.g. 2 nights, a boss was missed) = SAME session.
--   DUNGEON -> "run|<zona>|<diff>|<runToken>"    -- cada ENTRADA = run novo. Refazer
--              the same dungeon (normal or HC) = new session (runToken bumps).
--
-- runToken bumps on PLAYER_ENTERING_WORLD when we enter a new party instance.
-- Persisted in cdb so it survives a /reload mid-run.
-- ------------------------------------------------------------
local function runToken(bump)
	local cdb = Okanvil.cdb or Okanvil.db
	cdb.lootRunToken = cdb.lootRunToken or 0
	if bump then cdb.lootRunToken = cdb.lootRunToken + 1 end
	return cdb.lootRunToken
end

-- The current run key (nil if we are not in a recordable instance).
local function runKey()
	if not GetInstanceInfo then return nil end
	local name, itype, diff, _, _, _, _, mapID = GetInstanceInfo()
	name = name or (GetRealZoneText and GetRealZoneText()) or ""
	if itype == "raid" then
		-- lockout: procurar o reset desta raid nas saved instances -> resetDay
		if GetNumSavedInstances and GetSavedInstanceInfo then
			for i = 1, GetNumSavedInstances() do
				local sname, _, reset, sdiff = GetSavedInstanceInfo(i)
				if sname == name and (not sdiff or sdiff == diff) and reset and reset > 0 then
					return "lock|" .. name .. "|" .. (diff or 0) .. "|" .. date("%Y-%m-%d", time() + reset), name, diff, mapID
				end
			end
		end
		-- no lockout yet (first boss before the save) -> by day
		return "lock|" .. name .. "|" .. (diff or 0) .. "|" .. date("%Y-%m-%d"), name, diff, mapID
	elseif itype == "party" then
		return "run|" .. name .. "|" .. (diff or 0) .. "|" .. runToken(), name, diff, mapID
	end
	-- outside an instance: group by day+zone (rare; world loot)
	return "day|" .. date("%Y-%m-%d") .. "|" .. name, name, diff, mapID
end

local function newSession(key, name, diff, mapID)
	local list = sessions()
	local s = { t = time(), day = date("%Y-%m-%d"), zone = name or "", difficulty = diff or 0,
		mapID = mapID or 0, boss = resolveBoss(), key = key, drops = {} }
	table.insert(list, 1, s)
	while #list > MAX_SESSIONS do table.remove(list) end
	return s
end

-- The CURRENT run session. Finds the one with the same runKey (even if not the
-- newest -- you re-entered the raid after another instance), else creates one.
-- Does NOT open a new session per boss or on a silence gap -- only per different RUN.
local function currentSession()
	local key, name, diff, mapID = runKey()
	local list = sessions()
	-- match by runKey in any session (not just [1])
	for i = 1, #list do
		if list[i].key == key then
			if i > 1 then                       -- traz para a frente (a "atual")
				local found = table.remove(list, i)
				table.insert(list, 1, found)
			end
			return list[1]
		end
	end
	return newSession(key, name, diff, mapID)
end

-- ------------------------------------------------------------
-- DE-DUPE
--  (a) repeated BROADCAST (several clients report the same drop): same key
--      item within the time window -> keep the 1st, discard the rest.
--  (b) WHO-RECEIVED record (CHAT_MSG_LOOT): PLAYER:ITEM key within 5s -- so
--      2 of the same item to different people both count (the bracers bug).
-- ------------------------------------------------------------
-- An "open" drop of that item, so `won`/`receive`/rolls link to the SAME
-- drop que o START_LOOT_ROLL criou -- INDEPENDENTE do boss atual (o scanner pode
-- have advanced the boss by the time the item is given, creating a duplicate on the
-- wrong boss). Match by id, within a recent window (default 5 min = 1 pull).
-- Prefere um drop que ainda esta a rolar / sem dono.
local DROP_MATCH_WINDOW = 300
local function findOpenDrop(s, id)
	local now = time()
	local recent
	for i = #s.drops, 1, -1 do
		local dp = s.drops[i]
		if dp.id == id and (now - (dp.t or 0)) <= DROP_MATCH_WINDOW then
			if not dp.receivedBy then return dp end   -- ideal: ainda por atribuir
			recent = recent or dp                      -- fallback: o mais recente
		end
	end
	return recent
end

-- broadcast de-dupe: the same item reported by several clients in the same short
-- window. Only blocks if a drop with SAME item + SAME boss is still rolling
-- (2 clients reporting the same START_LOOT_ROLL). Does NOT block 2 legit drops
-- (esses vem com receive/roll distintos).
local function dropExists(s, id, boss)
	local now = time()
	for i = #s.drops, 1, -1 do
		local dp = s.drops[i]
		if dp.id == id and dp.boss == boss and (now - (dp.t or 0)) <= 40 then return dp end
	end
	return nil
end

local recvSeen = {}
local function recvDedupe(player, id)
	if not (player and id) then return false end
	local key = player:lower() .. ":" .. id
	local now = GetTime and GetTime() or 0
	local prev = recvSeen[key]
	recvSeen[key] = now
	return prev and (now - prev) < 5
end

-- ------------------------------------------------------------
-- Store a DROP (what fell). Does not set who got it -- that comes from CHAT_MSG_LOOT.
-- ------------------------------------------------------------
local function storeDrop(boss, id, link, name, rarity, boe, rollID, rollDur)
	if id == 0 then return nil end
	if not acceptItem(id, rarity, name) then return nil end
	local s = currentSession()
	local existing = dropExists(s, id, boss)
	if existing then
		if rollID and not existing.rollID then
			existing.rollID = rollID; existing.rollStart = GetTime(); existing.rollDur = rollDur or 60
		end
		return existing
	end
	-- ICON: store it NOW (the item just dropped -> it is cached). If we only
	-- compute it at export time, un-cached items give an empty icon (the bug). Uses
	-- GetItemInfo (10th return = texture), falling back to GetItemIcon(id) (id only).
	local icon = (link and select(10, GetItemInfo(link))) or (GetItemIcon and GetItemIcon(id)) or nil
	local iconTok = icon and (icon:gsub(".*\\", "")) or nil
	local dp = {
		t = time(), boss = boss or "Trash", id = id, item = link or "",
		name = name or "", rarity = rarity or 0, qty = 1, boe = boe and true or false,
		icon = iconTok,
	}
	if rollID then dp.rollID = rollID; dp.rollStart = GetTime(); dp.rollDur = rollDur or 60 end
	s.drops[#s.drops + 1] = dp
	lastLootAt = GetTime and GetTime() or 0
	if L.onLoot then L.onLoot() end
	if OkanvilLogs and OkanvilLogs.NoteBossFromLoot and boss then OkanvilLogs.NoteBossFromLoot(boss) end
	return dp
end

-- ------------------------------------------------------------
-- BROADCAST (RAID). Wire via Comms: LOOT | boss | id | link | rarity | boe
-- ------------------------------------------------------------
local function broadcastDrop(boss, id, link, rarity, boe)
	if not Okanvil.Comms then return end
	Okanvil.Comms.Send("LOOT", boss or "", id or 0, link or "", rarity or 0, boe and "1" or "0")
end

if Okanvil.Comms then
	Okanvil.Comms.On("LOOT", function(sender, boss, idStr, link, rarityStr, boeStr)
		local id = tonumber(idStr) or itemIDFromLink(link)
		if id == 0 then return end
		local rarity = tonumber(rarityStr) or 0
		local name = link ~= "" and (GetItemInfo(link)) or (GetItemInfo(id))
		if (not rarity or rarity == 0) and id ~= 0 then rarity = select(3, GetItemInfo(id)) or rarity end
		if not acceptItem(id, rarity, name) then return end
		local dp = storeDrop(boss ~= "" and boss or "Trash", id, link, name, rarity, boeStr == "1")
		if dp and L.onLootWindow then L.onLootWindow() end
	end)
end

-- ------------------------------------------------------------
-- CAPTURE 1: LOOT_OPENED -- scans the corpse as soon as ANYONE opens it.
-- ANYONE who opens the loot broadcasts the item list to the
-- other clients -- ML or raider, raid or dungeon, does not matter. So
-- everyone sees the items TO ROLL before they are handed out. (Comms.Send
-- escolhe RAID/PARTY sozinho e no-op se estivermos solo.)
-- ------------------------------------------------------------
local function captureCorpse()
	if not shouldRecordHere() then return end
	fireScan()   -- atualiza o boss atual ANTES de rotular o loot (timing do scanner)
	local guid, tname = UnitGUID("target"), UnitName("target")
	if tname and tname ~= "" and guidIsNPC(guid) and not encounterBoss then lastCorpseBoss = tname end
	local boss = resolveBoss()
	local n = (GetNumLootItems and GetNumLootItems()) or 0
	if n == 0 then return end
	local added = 0
	for i = 1, n do
		if LootSlotIsItem and LootSlotIsItem(i) then
			local _, lootName, _, rarity = GetLootSlotInfo(i)
			local link = GetLootSlotLink(i)
			local id = itemIDFromLink(link)
			if (not rarity or rarity == 0) and link then rarity = select(3, GetItemInfo(link)) end
			rarity = rarity or 0
			if acceptItem(id, rarity, lootName) then
				local boe = isBoE(link)
				local dp = storeDrop(boss, id, link, lootName, rarity, boe)
				if dp then
					added = added + 1
					broadcastDrop(boss, id, link, rarity, boe)   -- sempre; quem abre transmite
				end
			end
		end
	end
	if added > 0 then
		Okanvil:Print("Loot: " .. added .. " item(s) de " .. boss .. ".")
		if L.onLootWindow then L.onLootWindow() end
	end
	-- AUTO-GIVE: if you are the ML and the toggle is ON, hand the buckets (frag/boe) to the
	-- collectors now that the loot window is open. BoP stays to roll; frag/boe with no
	-- collector stays on the boss. (Resolves L. at runtime -> definition order does not matter.)
	if L.RunAutoGive then
		local dec = L.RunAutoGive()
		if dec then
			for _, d in ipairs(dec) do
				if d.action == "give" and d.done then
					Okanvil:Print("Auto-loot: " .. (d.name or "item") .. " -> " .. d.who .. " (" .. d.bucket .. ").")
				elseif d.action == "give" and not d.done then
					Okanvil:Print("|cffff5555Auto-loot falhou:|r " .. (d.name or "item") .. " -> " .. d.who
						.. " nao e candidato (fora de alcance/offline). Fica no boss.|r")
				end
			end
		end
	end
end
L.CaptureLoot = captureCorpse

-- ------------------------------------------------------------
-- CAPTURE 2: START_LOOT_ROLL -- native need/greed. Fires on ALL clients,
-- ideal for DUNGEON. Records the item and pops the mini manager.
-- ------------------------------------------------------------
local function captureRollStart(rollID)
	if not shouldRecordHere() then return end
	fireScan()   -- atualiza o boss atual ANTES de rotular o item (timing do scanner)
	if not (rollID and GetLootRollItemLink) then return end
	local link = GetLootRollItemLink(rollID)
	if not link then return end
	local _, _, _, quality = GetLootRollItemInfo(rollID)
	local rarity = quality or select(3, GetItemInfo(link)) or 0
	local id = itemIDFromLink(link)
	local name = (GetItemInfo(link))
	if not acceptItem(id, rarity, name) then return end
	local dur = (GetLootRollTimeLeft and GetLootRollTimeLeft(rollID) or 60000) / 1000
	local dp = storeDrop(resolveBoss(), id, link, name, rarity, isBoE(link), rollID, dur)
	if dp and L.onLootWindow then L.onLootWindow() end
end

-- ------------------------------------------------------------
-- ATTRIBUTION (MRT model): CHAT_MSG_LOOT says WHO received what.
-- Patterns built from the localized global constants (any locale).
-- ------------------------------------------------------------
local LOOT_PATTERNS
local function buildLootPatterns()
	if LOOT_PATTERNS then return LOOT_PATTERNS end
	LOOT_PATTERNS = {}
	local function add(template, extract)
		if type(template) ~= "string" or template == "" then return end
		local p = template:gsub("([%%%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
		p = p:gsub("%%%%s", "(.+)"):gsub("%%%%d", "(%%d+)")
		LOOT_PATTERNS[#LOOT_PATTERNS + 1] = { p, extract }
	end
	local me = function() return UnitName("player") end
	add(LOOT_ITEM_MULTIPLE,             function(n, l) return n, l end)
	add(LOOT_ITEM_SELF_MULTIPLE,        function(l)    return me(), l end)
	add(LOOT_ITEM,                      function(n, l) return n, l end)
	add(LOOT_ITEM_SELF,                 function(l)    return me(), l end)
	add(LOOT_ITEM_PUSHED_MULTIPLE,      function(n, l) return n, l end)
	add(LOOT_ITEM_PUSHED_SELF_MULTIPLE, function(l)    return me(), l end)
	add(LOOT_ITEM_PUSHED,               function(n, l) return n, l end)
	add(LOOT_ITEM_PUSHED_SELF,          function(l)    return me(), l end)
	add(LOOT_ROLL_WON,                  function(n, l) return n, l end)
	add(LOOT_ROLL_YOU_WON,              function(l)    return me(), l end)
	return LOOT_PATTERNS
end

local function noRealm(name) return name and name:gsub("%-.*$", "") or name end

local function tagReceiver(player, link)
	local id = itemIDFromLink(link)
	if id == 0 then return end
	player = noRealm(player)
	if recvDedupe(player, id) then return end
	local rarity = select(3, GetItemInfo(shortLink(link) or link)) or 0
	local name = (GetItemInfo(link))
	if not acceptItem(id, rarity, name) then return end
	local s = currentSession()
	-- link to the drop START_LOOT_ROLL/scan already created (by id, INDEPENDENT of
	-- the current boss -- else it made a duplicate on the wrong boss, e.g. Spaulders on
	-- "Spitting Cobra" AND "Slad'ran"). Only creates a new one if none exists.
	local target = findOpenDrop(s, id)
	if not target then target = storeDrop(resolveBoss(), id, link, name, rarity, isBoE(link)) end
	if target then
		target.receivedBy = player
		if L.onLoot then L.onLoot() end
	end
end

-- (onChatLoot defined further down, after the need/greed helpers.)

-- ------------------------------------------------------------
-- NATIVE NEED/GREED (WoW auto-roll). The game announces via CHAT_MSG_LOOT:
--   "X rolled Need - 87 for [item]"   (LOOT_ROLL_ROLLED_NEED)
--   "X rolled Greed - 42 for [item]"  (LOOT_ROLL_ROLLED_GREED)
--   "X rolled Disenchant - 12 for [item]" (LOOT_ROLL_ROLLED_DE)
--   "X won: [item]" / "You won: [item]"    (LOOT_ROLL_WON / _YOU_WON)
--   "Everyone passed on: [item]"           (LOOT_ROLL_ALL_PASSED)
-- We capture EACH roll (to show in the UI without relying on chat) and the winner
-- (to fill receivedBy + close the bar "rolling").
-- ------------------------------------------------------------
local NG_PATTERNS   -- { {pattern, kind, extractor}, ... }
local function buildNeedGreedPatterns()
	if NG_PATTERNS then return NG_PATTERNS end
	NG_PATTERNS = {}
	local function esc2(t) return (t:gsub("([%%%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")) end
	-- someone's roll: template has %s (name), %d (value), %s (item). Order varies by
	-- locale, mas em enUS e "%s rolled Need - %d for %s". Capturamos os 3 grupos e
	-- we resolve which is which by type (link has "|H", number is digits only).
	local function addRoll(template, kind)
		if type(template) ~= "string" or template == "" then return end
		-- %s -> (.+) GREEDY (not (.-): lazy fails to capture the whole name/link,
		-- so only the winner showed). We resolve which group is name/number/link
		-- by inspection (the link has item:, the number is digits only).
		local p = esc2(template):gsub("%%%%s", "(.+)"):gsub("%%%%d", "(%%d+)")
		NG_PATTERNS[#NG_PATTERNS + 1] = { p, kind }
	end
	addRoll(LOOT_ROLL_ROLLED_NEED, "need")
	addRoll(LOOT_ROLL_ROLLED_GREED, "greed")
	addRoll(LOOT_ROLL_ROLLED_DE, "de")
	return NG_PATTERNS
end

-- store one player's roll (need/greed/de) on the drop for that item.
local function recordNeedGreed(msg)
	local patterns = buildNeedGreedPatterns()
	for i = 1, #patterns do
		local a, b, c = msg:match(patterns[i][1])
		if a then
			-- the 3 groups are: name, number, itemlink (any order by locale).
			-- find which is the link (has item:), the number, and the name.
			local kind = patterns[i][2]
			local parts = { a, b, c }
			local link, roll, who
			for _, v in ipairs(parts) do
				if not v then
				elseif v:find("|Hitem:") or v:find("item:%d") then link = v
				elseif v:match("^%d+$") then roll = tonumber(v)
				else who = v end
			end
			if not link then return end
			local id = itemIDFromLink(link)
			if id == 0 then return end
			who = noRealm(who or "")
			-- find the drop these rolls belong to. Do NOT require "no owner":
			-- the "X won" may arrive amid the rolls and set receivedBy, but the rolls
			-- that follow still belong to this same item. Prefer the most recent drop that
			-- is/was rolling (has rollID or already has .rolls); else the most recent.
			local s = currentSession()
			-- o drop deste item (por id, ignora boss atual) -- o mesmo do rolling.
			local dp = findOpenDrop(s, id)
			if not dp then return end
			dp.rolls = dp.rolls or {}
			-- one entry per player (the first roll counts)
			for _, e in ipairs(dp.rolls) do if e.player == who then return end end
			dp.rolls[#dp.rolls + 1] = { player = who, roll = roll or 0, kind = kind }
			if L.onLoot then L.onLoot() end
			if L.onRoll then L.onRoll() end
			return
		end
	end
end

-- need/greed winner: fills receivedBy and CLOSES the rolling (clears rollID).
local function recordRollWon(player, link)
	local id = itemIDFromLink(link)
	if id == 0 then return end
	player = noRealm(player)
	local s = currentSession()
	local dp = findOpenDrop(s, id)   -- o mesmo drop do rolling (ignora boss atual)
	if dp then
		dp.receivedBy = player
		dp.rollID = nil; dp.rollStart = nil   -- para de mostrar "rolling"
		if L.onLoot then L.onLoot() end
		return
	end
	-- no drop found: fall through to the normal tagReceiver (creates if needed)
	tagReceiver(player, link)
end

-- everyone passed: closes the rolling with no winner.
local function recordAllPassed(link)
	local id = itemIDFromLink(link)
	if id == 0 then return end
	local s = currentSession()
	local dp = findOpenDrop(s, id)
	if dp then
		dp.rollID = nil; dp.rollStart = nil
		dp.passed = true
		if L.onLoot then L.onLoot() end
	end
end

-- winner / all-passed patterns (built once).
local WIN_PATTERNS
local function buildWinPatterns()
	if WIN_PATTERNS then return WIN_PATTERNS end
	WIN_PATTERNS = {}
	local function esc2(t) return (t:gsub("([%%%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")) end
	local me = function() return UnitName("player") end
	local function add(template, kind, extract)
		if type(template) ~= "string" or template == "" then return end
		-- (.+) GREEDY, not (.-): lazy fails to capture the name/link (that is why
		-- the "X won" never matched -> the winner was never written on the item).
		local p = esc2(template):gsub("%%%%s", "(.+)"):gsub("%%%%d", "(%%d+)")
		WIN_PATTERNS[#WIN_PATTERNS + 1] = { p, kind, extract }
	end
	-- won: "%s won: %s" (name, item) or just item (You won). resolve by link.
	add(LOOT_ROLL_WON,      "won", function(a, b) return a, b end)
	add(LOOT_ROLL_YOU_WON,  "won", function(a) return me(), a end)
	add(LOOT_ROLL_ALL_PASSED, "passed", function(a) return nil, a end)
	return WIN_PATTERNS
end

-- Single CHAT_MSG_LOOT handler: 1) need/greed rolls, 2) winner/all-passed,
-- 3) loot normal (quem recebeu). A ordem importa -- um "won" tambem casaria o
-- padrao de loot generico, por isso testamos won ANTES.
local function onChatLoot(msg)
	if type(msg) ~= "string" or msg == "" then return end
	if not shouldRecordHere() then return end

	-- 1) someone's roll (need/greed/de) -> store on the drop
	recordNeedGreed(msg)

	-- 2) winner or all-passed. Resolve who/link by inspection (the group with item:
	-- e o link; o outro e o nome) -- robusto a ordem que varia por locale.
	for _, w in ipairs(buildWinPatterns()) do
		local a, b = msg:match(w[1])
		if a ~= nil then
			local link = (a and a:find("item:") and a) or (b and b:find("item:") and b) or nil
			local who = (link ~= a) and a or b
			if w[2] == "passed" then
				if link then recordAllPassed(link); return end
			elseif w[2] == "won" then
				-- "You won": only the link exists (who = me). else who is the other group.
				if not who or who:find("item:") then who = UnitName("player") end
				if link then recordRollWon(who, link); return end
			end
		end
	end

	-- 3) loot normal ("X receives loot: [item]") -> quem recebeu
	local patterns = buildLootPatterns()
	for i = 1, #patterns do
		local a, b = msg:match(patterns[i][1])
		if a then
			local player, link = patterns[i][2](a, b)
			if player and link then tagReceiver(player, link) end
			return
		end
	end
end

-- ------------------------------------------------------------
-- ROLLS (RaidRoll). MS = /roll (1-100) bate OS = /roll 99 (1-99); maior ganha.
-- ------------------------------------------------------------
local ROLL_WINDOW = 120
local activeRoll = nil

local function announceChannel()
	if GetNumRaidMembers and GetNumRaidMembers() > 0 then
		return ((IsRaidLeader and IsRaidLeader()) or (IsRaidOfficer and IsRaidOfficer()))
			and "RAID_WARNING" or "RAID"
	end
	if GetNumPartyMembers and GetNumPartyMembers() > 0 then return "PARTY" end
	return "SAY"
end

local ROLL_MSG = {
	ms   = "Roll [item]  --  MAIN SPEC  /roll (1-100)",
	os   = "Roll [item]  --  OFF SPEC  /roll 99 (1-99)",
	free = "Roll [item]  --  FREE  /roll (1-100)",
}
function L.RollMsg(mode)
	local d = db(); d.rollMsg = d.rollMsg or {}
	return d.rollMsg[mode] or ROLL_MSG[mode] or ROLL_MSG.free
end
function L.SetRollMsg(mode, text)
	local d = db(); d.rollMsg = d.rollMsg or {}
	d.rollMsg[mode] = (text ~= "" and text) or nil
end

function L.ActiveRoll() return activeRoll end

function L.StartRoll(link, mode)
	if not link then return end
	mode = mode or "free"
	activeRoll = { id = itemIDFromLink(link), link = link, name = (GetItemInfo(link)) or "",
		mode = mode, opened = GetTime(), best = nil, list = {}, seen = {} }
	local chan = announceChannel()
	if chan then SendChatMessage(L.RollMsg(mode):gsub("%[item%]", link), chan) end
	if L.onRoll then L.onRoll() end
end

function L.StopRoll()
	activeRoll = nil
	if L.onRoll then L.onRoll() end
end

function L.SelfRoll(mode)
	if mode == "os" then RandomRoll(1, 99) else RandomRoll(1, 100) end
end

local ROLL_PATTERN = (RANDOM_ROLL_RESULT or "%s rolls %d (%d-%d)")
	:gsub("([%(%)%-])", "%%%1"):gsub("%%s", "(.+)"):gsub("%%d", "(%%d+)")
local function captureRoll(msg)
	if not activeRoll then return end
	if (GetTime() - activeRoll.opened) > ROLL_WINDOW then return end
	local who, roll, _, hi = msg:match(ROLL_PATTERN)
	if not who then return end
	roll = tonumber(roll) or 0
	local hiN = tonumber(hi) or 100
	if hiN > 100 or roll > 100 then return end
	local spec = (hiN >= 100) and "main" or "off"
	local key = noRealm(who)
	if activeRoll.seen[key] then return end
	activeRoll.seen[key] = true
	activeRoll.list[#activeRoll.list + 1] = { player = key, roll = roll, spec = spec }
	local b = activeRoll.best
	local better = (not b) or (spec == "main" and b.spec == "off") or (spec == b.spec and roll > b.roll)
	if better then activeRoll.best = { player = key, roll = roll, spec = spec } end
	if L.onRoll then L.onRoll() end
end

-- ------------------------------------------------------------
-- MASTER LOOT: resolver candidato + dar (RaidRoll RR_ReallyGiveLoot).
-- ------------------------------------------------------------
local function iAmMasterLooter()
	if not GetLootMethod then return false end
	local method, partyML, raidML = GetLootMethod()
	if method ~= "master" then return false end
	if partyML == 0 then return true end
	if raidML and GetRaidRosterInfo then
		local n = GetRaidRosterInfo(raidML)
		return n and n == UnitName("player")
	end
	return false
end
function L.IsMasterLooter() return iAmMasterLooter() end

local function mlCandidate(playerName)
	if not (GetMasterLootCandidate and playerName) then return nil end
	local want = noRealm(playerName):lower()
	local inRaid = GetNumRaidMembers and GetNumRaidMembers() > 0
	local last = inRaid and 40 or ((GetNumPartyMembers and GetNumPartyMembers() or 0) + 1)
	for i = 1, last do
		local cand = GetMasterLootCandidate(i)
		if cand and cand:lower() == want then return i end
	end
	return nil
end

local function giveLootNow(id, winner)
	if not (id and winner and GetNumLootItems and GiveMasterLoot) then return "noapi" end
	if (GetLootMethod and GetLootMethod()) ~= "master" then return "notml" end
	local n = GetNumLootItems() or 0
	if n == 0 then return "closed" end
	local saw = false
	for slot = 1, n do
		if LootSlotIsItem and LootSlotIsItem(slot) then
			local link = GetLootSlotLink(slot)
			if link and itemIDFromLink(link) == id then
				saw = true
				local cand = mlCandidate(winner)
				if cand then GiveMasterLoot(slot, cand); return "ok" end
			end
		end
	end
	return saw and "nocand" or "noitem"
end

local function markWinner(id, winner)
	local s = sessions()[1]
	if not s then return end
	for i = #s.drops, 1, -1 do
		if s.drops[i].id == id and not s.drops[i].receivedBy then
			s.drops[i].receivedBy = winner
			return
		end
	end
end

local function commitAward(id, winner)
	markWinner(id, winner)
	local res = giveLootNow(id, winner)
	local nm = (GetItemInfo(id)) or "item"
	if res == "ok" then
		Okanvil:Print("Dado (master loot): " .. nm .. " -> " .. winner .. ".")
	else
		local why = ({
			noapi = "master loot indisponivel", notml = "metodo nao e Master Loot",
			closed = "janela de loot fechada (item nos bags)", noitem = "item ja nao esta na janela",
			nocand = winner .. " nao e candidato valido (fora de alcance/offline)",
		})[res] or "razao desconhecida"
		Okanvil:Print("|cffff5555Marcado " .. winner .. " como vencedor mas NAO deu " .. nm
			.. " -- " .. why .. ". Passa por trade.|r")
	end
	activeRoll = nil
	if L.onLoot then L.onLoot() end
	if L.onRoll then L.onRoll() end
end

-- AWARD with CONFIRMATION -- SAME flow as RaidRoll RR_GiveLoot (where the idea came from):
-- popup "are you sure? give [item] to X" with the button showing the winner's NAME,
-- and only OnAccept does it give (RR_ReallyGiveLoot -> GiveMasterLoot). Always confirm.
StaticPopupDialogs = StaticPopupDialogs or {}
StaticPopupDialogs["OKANVIL_AWARD_CONFIRM"] = {
	text = "", button1 = "", button2 = CANCEL,   -- button1 e definido por-show com o nome
	OnAccept = function(self) local a = self.data; if a then commitAward(a.id, a.winner) end end,
	timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}
function L.AwardWinner(id, winner, topRoll, spec)
	if not (id and winner and winner ~= "") then return end
	local link
	if activeRoll and activeRoll.id == id then link = activeRoll.link end
	local itemStr = link or ("[" .. ((GetItemInfo(id)) or "item") .. "]")
	local rollTag = (topRoll and topRoll > 0) and (" (rolou " .. topRoll .. (spec == "off" and " OS" or "") .. ")") or ""
	-- botao com o nome, como o RaidRoll ("Give to X")
	StaticPopupDialogs["OKANVIL_AWARD_CONFIRM"].button1 = "Dar a " .. winner
	StaticPopupDialogs["OKANVIL_AWARD_CONFIRM"].text =
		"Tens a certeza?\nDar " .. itemStr .. " a |cffffd200" .. winner .. "|r" .. rollTag .. "?"
	local dlg = StaticPopup_Show("OKANVIL_AWARD_CONFIRM")
	if dlg then dlg.data = { id = id, winner = winner } end
end

function L.ClearActiveDrops()
	local s = sessions()[1]
	if not s then return false end
	wipe(s.drops)
	activeRoll = nil; lastLootAt = 0
	if L.onLoot then L.onLoot() end
	return true
end

-- ------------------------------------------------------------
-- Data accessors for the UI.
-- ------------------------------------------------------------
function L.RecentDrops(limit)
	local s = sessions()[1]; if not s then return {} end
	local out = {}
	for i = #s.drops, 1, -1 do out[#out + 1] = s.drops[i]; if limit and #out >= limit then break end end
	return out
end

function L.DropsByBoss()
	local s = sessions()[1]; if not s then return {} end
	local order, byBoss = {}, {}
	for _, dp in ipairs(s.drops) do
		local b = (dp.boss ~= "" and dp.boss) or "Trash"
		if not byBoss[b] then byBoss[b] = { boss = b, items = {} }; order[#order + 1] = byBoss[b] end
		table.insert(byBoss[b].items, dp)
	end
	return order
end

function L.SessionHasBoss(name)
	if not name or name == "" then return false end
	local s = sessions()[1]; if not s then return false end
	for i = 1, #s.drops do if s.drops[i].boss == name then return true end end
	return false
end

function L.InLiveRun()
	if not (IsInInstance and IsInInstance()) then return false end
	local _, itype = IsInInstance()
	if itype ~= "party" and itype ~= "raid" then return false end
	return shouldRecordHere()
end

function L.DeleteSession(sess)
	local list = sessions()
	for i = #list, 1, -1 do if list[i] == sess then table.remove(list, i); break end end
	if L.onLoot then L.onLoot() end
end

-- ------------------------------------------------------------
-- Classe/cor/icone helpers (export + render inline).
--
-- classNameOf resolves a player's class (token "MAGE" etc.) by searching
-- party -> raid -> guild roster, and stores it in a PERSISTENT cache (cdb.classCache).
-- O cache persistente e o que faz o HISTORICO colorir mesmo dias depois, quando o
-- player is no longer in your group (e.g. yesterday's loot). Once seen grouped or
-- na guild, lembramos a classe para sempre.
-- ------------------------------------------------------------
local function classCache()
	local cdb = Okanvil.cdb or Okanvil.db
	cdb.classCache = cdb.classCache or {}
	return cdb.classCache
end
local function classNameOf(name)
	if not name or name == "" then return "" end
	local short = noRealm(name):lower()
	local cache = classCache()
	-- the player themselves
	if UnitName("player"):lower() == short then
		local _, cls = UnitClass("player"); if cls then cache[short] = cls; return cls end
	end
	-- party / raid units (tem class token via UnitClass)
	local function scan(prefix, n)
		for i = 1, n do
			local u = prefix .. i
			if UnitExists(u) and UnitName(u) and UnitName(u):lower() == short then
				local _, cls = UnitClass(u); if cls then cache[short] = cls; return cls end
			end
		end
	end
	local r
	if GetNumRaidMembers and GetNumRaidMembers() > 0 then r = scan("raid", GetNumRaidMembers())
	elseif GetNumPartyMembers and GetNumPartyMembers() > 0 then r = scan("party", GetNumPartyMembers()) end
	if r then return r end
	-- raid roster (gives the class token in the 6th slot)
	if GetNumRaidMembers and GetNumRaidMembers() > 0 then
		for i = 1, GetNumRaidMembers() do
			local rn, _, _, _, _, cls = GetRaidRosterInfo(i)
			if rn and rn:lower() == short and cls then cache[short] = cls; return cls end
		end
	end
	-- guild roster (class token)
	local gm = G.FindMember(short)
	if gm and gm.classToken then cache[short] = gm.classToken; return gm.classToken end
	return cache[short] or ""
end
function L.ClassColorName(name)
	if not name or name == "" then return "|cffffd200" .. (name or "") .. "|r" end
	local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classNameOf(name)]
	if c then return string.format("|cff%02x%02x%02x%s|r", c.r * 255, c.g * 255, c.b * 255, name) end
	return "|cffffd200" .. name .. "|r"
end
-- public: class token (so LootRoll shares the same persistent cache).
function L.ClassOf(name) return classNameOf(name) end
-- icon token (just the file name, e.g. "INV_Sword_39"). Tries GetItemInfo
-- (10th = texture), falling back to GetItemIcon(id) -- the LATTER works with the id only,
-- even when the item is not fully cached (that is why the export failed the
-- icone enquanto o UI in-game o mostrava via o warmer Okanvil:ItemIcon).
local function iconToken(link, id)
	local tex = link and select(10, GetItemInfo(link))
	if not tex and id and GetItemIcon then tex = GetItemIcon(id) end
	return tex and (tex:gsub(".*\\", "")) or ""
end

function L.SessionJSON(s)
	if not s then return "{}" end
	local guildName = GetGuildInfo("player") or "Guild"
	local realm = GetRealmName() or ""
	local runId = (s.day or "") .. "-" .. (s.zone or ""):lower():gsub("%s+", "-") .. "-" .. (s.difficulty or 0)
	-- size: DUNGEON (key "run|...") = 5; RAID = 25 on difficulties 2/4, else 10.
	local isDungeon = s.key and s.key:find("^run|") ~= nil
	local size = isDungeon and 5 or ((s.difficulty == 2 or s.difficulty == 4) and 25 or 10)
	local drops = {}
	for _, d in ipairs(s.drops) do
		-- DE -> sentinel "Disenchant" (sem pessoa; o hub exclui das contas de win).
		local player = d.de and "Disenchant" or (d.receivedBy or "")
		local class  = d.de and "" or classNameOf(d.receivedBy)
		drops[#drops + 1] = string.format(
			'{"ts":%d,"player":"%s","class":"%s","itemId":%d,"name":"%s","icon":"%s",'
			.. '"quality":%d,"boss":"%s","raid":"%s","size":%d,"runId":"%s","de":%s,"boe":%s}',
			d.t or 0, esc(player), esc(class), d.id or 0,
			esc(d.name), esc(d.icon or iconToken(d.item, d.id)), d.rarity or 4, esc(d.boss),
			esc(s.zone or ""), size, esc(runId), d.de and "true" or "false",
			d.boe and "true" or "false")
	end
	return string.format(
		'{"type":"loot","guildName":"%s","realm":"%s","capturedAt":%d,"day":"%s",'
		.. '"zone":"%s","runId":"%s","size":%d,"loot":[%s]}',
		esc(guildName), esc(realm), s.t or 0, esc(s.day or ""),
		esc(s.zone), esc(runId), size, table.concat(drops, ","))
end

-- Desenha o detalhe de uma sessao: um header por boss + uma linha por drop.
-- rowFn(idx, yTop) returns a "row" (with r.txt and r.icon) placed at yTop
-- (positive, going DOWN the screen). Returns (finalIdx, totalHeight) -- POSITIVE values
-- que a pagina usa para reaproveitar rows e dimensionar o painel de detalhe.
-- (contrato identico ao RenderInline original; UI.lua usa select(2,...) = altura.)
function L.RenderInline(s, rowFn, idx, y)
	idx = idx or 0
	y = y or 0
	if not s or not rowFn then return idx, y end
	local lastBoss = nil
	for _, d in ipairs(s.drops) do
		local header = (d.boss and d.boss ~= "" and d.boss)
			or (GetInstanceInfo and (GetInstanceInfo())) or "Trash"
		if header ~= lastBoss then
			lastBoss = header
			idx = idx + 1
			local hr = rowFn(idx, y)
			if hr.icon then hr.icon:Hide() end
			hr.txt:ClearAllPoints(); hr.txt:SetPoint("LEFT", hr, "LEFT", 0, 0)
			hr.txt:SetText("|cffffd200" .. header .. "|r")
			y = y + 20
		end
		idx = idx + 1
		local r = rowFn(idx, y)
		if r.icon then
			r.icon:Show()
			local tex = Okanvil:ItemIcon(d.item) or "Interface\\Icons\\INV_Misc_QuestionMark"
			r.icon:SetTexture(tex); r.icon:ClearAllPoints(); r.icon:SetPoint("LEFT", r, "LEFT", 2, 0)
			r.txt:ClearAllPoints(); r.txt:SetPoint("LEFT", r.icon, "RIGHT", 6, 0); r.txt:SetPoint("RIGHT", r, "RIGHT", -4, 0)
		else
			r.txt:ClearAllPoints(); r.txt:SetPoint("LEFT", r, "LEFT", 0, 0); r.txt:SetPoint("RIGHT", r, "RIGHT", -4, 0)
		end
		local qty = (d.qty and d.qty > 1) and ("  |cff8a8d93x" .. d.qty .. "|r") or ""
		local who = ""
		if d.de then
			who = "  |cff8a8d93->|r |cff8a5ad9Disenchant|r"
		elseif d.receivedBy and d.receivedBy ~= "" then
			who = "  |cff5e6166->|r " .. L.ClassColorName(d.receivedBy)
		end
		if d.rolls and #d.rolls > 0 then
			local kindColor = { need = "|cff7cfc8a", greed = "|cff8a8d93", de = "|cff8a5ad9" }
			local tags = {}
			for _, e in ipairs(d.rolls) do
				local kc = kindColor[e.kind] or "|cff7cfc8a"
				tags[#tags + 1] = L.ClassColorName(e.player) .. " " .. kc .. (e.roll or 0) .. "|r"
			end
			who = who .. "  |cff5e6166[|r" .. table.concat(tags, "|cff5e6166, |r") .. "|cff5e6166]|r"
		end
		-- d.item ja e o link colorido pela raridade; fallback para o nome.
		r.txt:SetText((d.item ~= "" and d.item or ("[" .. (d.name or "?") .. "]")) .. qty .. who)
		local link = d.item ~= "" and d.item or nil
		r:SetScript("OnEnter", function(self)
			if not link then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetHyperlink(link); GameTooltip:Show()
		end)
		r:SetScript("OnLeave", function() GameTooltip:Hide() end)
		r:SetScript("OnClick", function()
			if link and IsShiftKeyDown() and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
		end)
		y = y + 20
	end
	if #s.drops == 0 then
		idx = idx + 1
		local r = rowFn(idx, y)
		if r.icon then r.icon:Hide() end
		r.txt:ClearAllPoints(); r.txt:SetPoint("LEFT", r, "LEFT", 0, 0)
		r.txt:SetText("|cff888888No drops recorded.|r")
		y = y + 20
	end
	return idx, y
end

-- ------------------------------------------------------------
-- Collectors: config (nomes) + AUTO-GIVE quando es o Master Looter.
-- ------------------------------------------------------------
local function collectorsDB()
	local d = db(); d.collectors = d.collectors or {}
	local c = d.collectors
	if c.main == nil then c.main = "" end     -- coletor principal: auto-loot BoE/orb/pattern p/ este nome
	if c.frag == nil then c.frag = "" end     -- coletor de fragmentos/shards
	if c.boe  == nil then c.boe  = "" end     -- coletor de BoE/orbs/patterns
	if c.enabled == nil then c.enabled = false end
	if c.whisper == nil then c.whisper = false end
	return c
end
function L.Collectors() return collectorsDB() end
function L.CollectorName(bucket) local n = collectorsDB()[bucket] or ""; return (n:gsub("^%s*(.-)%s*$", "%1")) end
function L.SetCollector(bucket, name) collectorsDB()[bucket] = name or ""; if L.onLoot then L.onLoot() end end
function L.CollectorsEnabled() return collectorsDB().enabled and true or false end
function L.SetCollectorsEnabled(on) collectorsDB().enabled = on and true or false; if L.onLoot then L.onLoot() end end
function L.WhisperWinner() return collectorsDB().whisper and true or false end
function L.SetWhisperWinner(on) collectorsDB().whisper = on and true or false end
function L.WhisperMsg() return collectorsDB().whisperMsg or "" end
function L.SetWhisperMsg(text) collectorsDB().whisperMsg = (text ~= "" and text) or nil end

-- ------------------------------------------------------------
-- CLASSIFICACAO para auto-give (que "bucket" e cada item). IDs verificados no ID
-- Finder (don't guess -- see [[verify-item-ids-against-idfinder]]); name as a
-- fallback robusto.
--   "frag" -> legendary fragments (Val'anyr, Shadowmourne). NOT transferable
--             once given; NO collector -> LEAVE ON THE BOSS.
--   "boe"  -> orbs / patterns / any BoE. Transferable; NO collector -> your bags.
--   "main" -> the rest (BoP gear). Stays to ROLL -- never auto-bags.
-- ------------------------------------------------------------
local FRAGMENT_IDS = {
	[45038] = true,  -- Fragment of Val'anyr
	[45039] = true,  -- Shattered Fragments of Val'anyr
	[45896] = true,  -- Unbound Fragments of Val'anyr
	[49869] = true,  -- Shadowfrost Shard (Shadowmourne)
}
local ORB_IDS = {
	[45087] = true,  -- Runed Orb
	[47556] = true,  -- Crusader Orb
	[49908] = true,  -- Primordial Saronite
	[46110] = true,  -- Alchemist's Cache
}
local FRAG_NAME_HINTS = { "fragment of val'anyr", "fragments of val'anyr", "shadowfrost shard" }
local ORB_NAME_HINTS  = { "runed orb", "crusader orb", "primordial saronite" }
local PATTERN_HINTS   = { "pattern:", "plans:", "recipe:", "schematic:", "formula:", "design:" }

-- Returns "frag" | "boe" | "main". Called before the ignore filter (shards still route).
local function collectorFor(link, name)
	local id = itemIDFromLink(link)
	if (id ~= 0 and FRAGMENT_IDS[id]) or nameHasAny(name, FRAG_NAME_HINTS) then return "frag" end
	if (id ~= 0 and ORB_IDS[id]) or nameHasAny(name, ORB_NAME_HINTS) then return "boe" end
	if nameHasAny(name, PATTERN_HINTS) then return "boe" end   -- patterns/plans = boe bucket
	if isBoE(link) then return "boe" end                        -- qualquer BoE
	return "main"                                                -- BoP gear -> rola
end

-- Give slot `slot` (from the open loot window) to player `who` via master loot.
-- Returns true if the give was accepted.
local function giveSlotTo(slot, who)
	if not (who and who ~= "" and GiveMasterLoot) then return false end
	local cand = mlCandidate(who)
	if not cand then return false end
	GiveMasterLoot(slot, cand)
	return true
end

-- ------------------------------------------------------------
-- AUTO-GIVE: decides the fate of ONE loot-window slot (when you are ML and the
-- toggle is ON). Returns a DECISION: { action, who, bucket, name } without acting --
-- so callers can inspect it; the real path calls giveSlotTo.
--   action: "give" (who) | "leave" (stay on boss) | "roll" (BoP, stays to roll)
-- ------------------------------------------------------------
local function autoGiveDecision(link, name)
	local c = collectorsDB()
	local bucket = collectorFor(link, name)   -- frag | boe | main
	if bucket == "frag" then
		local who = (c.frag or ""):gsub("^%s*(.-)%s*$", "%1")
		if who ~= "" then return { action = "give", who = who, bucket = "frag", name = name } end
		-- fragment with no collector -> LEAVE ON THE BOSS (binds, not transferable)
		return { action = "leave", bucket = "frag", name = name }
	elseif bucket == "boe" then
		local who = (c.boe or ""):gsub("^%s*(.-)%s*$", "%1")
		if who ~= "" then return { action = "give", who = who, bucket = "boe", name = name } end
		-- orb/BoE/pattern with no collector -> LEAVE ON THE CORPSE (roll it normally)
		return { action = "leave", bucket = "boe", name = name }
	end
	-- main = BoP gear -> stays to roll (never auto-bags)
	return { action = "roll", bucket = "main", name = name }
end

-- Runs auto-give for ALL slots of the open loot window. Only runs if the
-- toggle is ON + you are ML. Returns the decisions (and performs the gives).
local function runAutoGive()
	if not (collectorsDB().enabled and iAmMasterLooter()) then return nil end
	local n = (GetNumLootItems and GetNumLootItems()) or 0
	if n == 0 then return nil end
	local thr = GetLootThreshold and GetLootThreshold() or 4
	local warnedThreshold = false
	local out = {}
	for slot = 1, n do
		if LootSlotIsItem and LootSlotIsItem(slot) then
			local link = GetLootSlotLink(slot)
			local iname = link and (GetItemInfo(link)) or nil
			if link then
				local d = autoGiveDecision(link, iname)
				d.slot = slot; d.link = link
				-- WARNING: an item that should go to a collector but is BELOW the ML
				-- threshold (e.g. a blue orb, rarity 3, with an epic-4 threshold) does NOT go
				-- through master loot -- the server lets anyone grab it (the Mojo bug).
				if d.action == "give" and not warnedThreshold then
					local rarity = select(3, GetItemInfo(link)) or 4
					if rarity < thr then
						Okanvil:Print("|cffff5555Aviso:|r ha loot (ex.: " .. (iname or "orb")
							.. ") ABAIXO do threshold do ML (" .. thr .. ") -- nao passa pelo master loot,"
							.. " qualquer um pode pegar. Baixa o Loot Threshold para o apanhares.")
						warnedThreshold = true
					end
				end
				if d.action == "give" then
					d.done = giveSlotTo(slot, d.who)   -- pode falhar (nao candidato)
				end
				-- "bags": no master-loot -> falls into your bags when the window closes
				-- "leave"/"roll": don't touch (stays on the boss to roll/decide)
				out[#out + 1] = d
			end
		end
	end
	return out
end
L.RunAutoGive = runAutoGive

-- ------------------------------------------------------------
-- EVENTOS. O scanner de boss (portado do MRT) corre em target/mouseover/combate;
-- death is confirmed by COMBAT_LOG UNIT_DIED. No ENCOUNTER_* (absent on 3.3.5a).
-- ------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("LOOT_OPENED")
ev:RegisterEvent("START_LOOT_ROLL")
ev:RegisterEvent("CHAT_MSG_LOOT")
ev:RegisterEvent("CHAT_MSG_SYSTEM")
ev:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")   -- mortes de boss
ev:RegisterEvent("PLAYER_TARGET_CHANGED")         -- scanner de boss
ev:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")         -- entrou em combate
ev:RegisterEvent("PLAYER_ENTERING_WORLD")         -- entrada em instancia -> run novo (dungeon)

-- deteta ENTRADA numa dungeon nova para bumpar o runToken (= sessao nova por run).
-- So dungeons (party): reentrar/refazer a mesma dungeon = run novo. Raids agrupam
-- by lockout, so they do NOT bump (the lockout runKey merges everything).
local lastPartyInstance = nil
local function onEnterWorld()
	if not (IsInInstance and IsInInstance()) then lastPartyInstance = nil; return end
	local _, itype = IsInInstance()
	if itype ~= "party" then return end
	local name = (GetRealZoneText and GetRealZoneText()) or (GetInstanceInfo and (GetInstanceInfo())) or ""
	-- entering a different dungeon than last (or re-entering after leaving) = new run
	if name ~= lastPartyInstance then
		runToken(true)               -- bump -> currentSession abre uma sessao nova
		lastPartyInstance = name
	end
end

ev:SetScript("OnEvent", function(_, event, ...)
	-- Loot module DISABLED = no loot capture, no boss scan, nothing.
	if Okanvil.ModuleActive and not Okanvil:ModuleActive("__loot") then return end
	if event == "LOOT_OPENED" then captureCorpse()
	elseif event == "START_LOOT_ROLL" then captureRollStart(...)
	elseif event == "CHAT_MSG_LOOT" then onChatLoot(...)
	elseif event == "CHAT_MSG_SYSTEM" then local a1 = ...; if a1 then captureRoll(a1) end
	elseif event == "PLAYER_ENTERING_WORLD" then onEnterWorld()
	elseif event == "PLAYER_TARGET_CHANGED" or event == "UPDATE_MOUSEOVER_UNIT"
		or event == "PLAYER_REGEN_DISABLED" then
		fireScan()
	elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
		if select(2, ...) == "UNIT_DIED" then
			onUnitDied(select(5, ...))   -- destGUID
		end
	end
end)

-- UI hooks + debug
L.onLoot, L.onRoll, L.onLootWindow = nil, nil, nil
function L.Dbg() end

-- /okdebug -- liga/desliga os prints de diagnostico do loot (mais fiavel que /run).
SLASH_OKDEBUG1 = "/okdebug"
SlashCmdList["OKDEBUG"] = function()
	OkanvilLootDebug = not OkanvilLootDebug
	Okanvil:Print("Loot debug = " .. (OkanvilLootDebug and "|cff7cfc8aON|r" or "|cff8a8d93OFF|r"))
end

-- ------------------------------------------------------------
-- Loot dashboard UI -- registered below as the "__loot" plugin (build once,
-- refresh on every show via Okanvil:ShowPanel's generic plugin dispatch).
-- ------------------------------------------------------------
local W = Okanvil.W
local C = Okanvil.Colors
local FLAT = "Interface\\ChatFrame\\ChatFrameBackground"
local function u3(t, a) return t[1], t[2], t[3], a or 1 end

local lootFill         -- shared panel handle: Loot_BuildUI sets it, Loot_BuildHistory reads it
local lootRefreshAll   -- bridges Loot_BuildUI's local refreshAll to Loot_Refresh below

-- ---- Collectors tab: Main/Frag/BoE targets + auto toggle + whisper toggle ----
local function Loot_BuildCollectors(p)
	local L = Okanvil.Loot
	local X = 8
	if not (L and L.Collectors) then return end
	local warn = W.Text(p, "", 11); warn:SetPoint("TOPLEFT", X, -6); warn:SetPoint("RIGHT", -X, 0); warn:SetJustifyH("LEFT")
	local function paintWarn()
		if L.IsMasterLooter and L.IsMasterLooter() then
			warn:SetText("|cff7cfc8aYou are the Master Looter -- these apply.|r")
		else
			warn:SetText("|cffff5555You are NOT the Master Looter -- auto-loot is inactive (safe).|r")
		end
	end
	paintWarn()
	local en = W.Check(p, "Auto master-loot (only when you're the Master Looter)",
		function() return L.CollectorsEnabled() end,
		function(v) L.SetCollectorsEnabled(v) end)
	en:SetPoint("TOPLEFT", X + 2, -26)
	local hint = W.Text(p, "Set a name to auto-give that bucket. |cffffd200Leave a field EMPTY and that loot is left on the corpse (roll it normally)|r -- the addon never sweeps loot to anyone unless you name them.", 10, "dim")
	hint:SetPoint("TOPLEFT", X, -48); hint:SetPoint("RIGHT", -X, 0); hint:SetJustifyH("LEFT")

	local col = L.Collectors()
	local function row(bucket, label, y)
		local lb = W.Text(p, label, 11); lb:SetPoint("TOPLEFT", X, y - 4); lb:SetWidth(92); lb:SetJustifyH("LEFT")
		if lb.SetWordWrap then lb:SetWordWrap(false) end
		local eb = W.EditBox(p, function(t) L.SetCollector(bucket, t) end)
		eb:SetSize(150, 24); eb:SetPoint("LEFT", lb, "RIGHT", 8, 0); eb.edit:SetText(col[bucket] or "")
		local function setName(n)
			if not n or n == "" then return end
			n = n:gsub("%-.*$", ""); eb.edit:SetText(n); L.SetCollector(bucket, n)
		end
		local sf = W.Button(p, "Self"); sf:SetSize(48, 24); sf:SetPoint("LEFT", eb, "RIGHT", 6, 0)
		if sf.text then sf.text:SetText("|cff7cfc8aSelf|r") end
		sf:SetScript("OnClick", function() setName(UnitName("player")) end)
		local tg = W.Button(p, "Target"); tg:SetSize(56, 24); tg:SetPoint("LEFT", sf, "RIGHT", 4, 0)
		tg:SetScript("OnClick", function()
			local n = UnitName("target")
			if n and UnitIsPlayer("target") then setName(n) else Okanvil:Print("Target a player first.") end
		end)
		local cl = W.Button(p, "Clear", "danger"); cl:SetSize(48, 24); cl:SetPoint("LEFT", tg, "RIGHT", 6, 0)
		cl:SetScript("OnClick", function() eb.edit:SetText(""); L.SetCollector(bucket, "") end)
	end
	row("main", "Main loot", -92)
	row("frag", "Fragments", -122)
	row("boe", "BoE / orbs", -152)
	local wc = W.Check(p, "Whisper winner on Award (\"you won, trade me\")",
		function() return L.WhisperWinner() end, function(v) L.SetWhisperWinner(v) end)
	wc:SetPoint("TOPLEFT", X + 2, -188)
end

-- ---- Messages tab: editable MS/OS/Free/Whisper templates ([item] placeholder) --
local function Loot_BuildMessages(p)
	local L = Okanvil.Loot
	local X = 8
	if not (L and L.RollMsg) then return end
	local hd = W.Text(p, "Announce templates -- |cffffd200[item]|r = the itemlink.", 11, "dim")
	hd:SetPoint("TOPLEFT", X, -6); hd:SetPoint("RIGHT", -X, 0); hd:SetJustifyH("LEFT")
	local function row(label, y, getFn, setFn)
		local lb = W.Text(p, label, 11); lb:SetPoint("TOPLEFT", X, y - 4); lb:SetWidth(58); lb:SetJustifyH("LEFT")
		if lb.SetWordWrap then lb:SetWordWrap(false) end
		local eb = W.EditBox(p, function(t) setFn(t) end)
		eb:SetSize(360, 24); eb:SetPoint("LEFT", lb, "RIGHT", 8, 0); eb.edit:SetText(getFn())
	end
	row("MS", -30, function() return L.RollMsg("ms") end, function(t) L.SetRollMsg("ms", t) end)
	row("OS", -60, function() return L.RollMsg("os") end, function(t) L.SetRollMsg("os", t) end)
	row("Free", -90, function() return L.RollMsg("free") end, function(t) L.SetRollMsg("free", t) end)
	row("Whisper", -128, function() return L.WhisperMsg() end, function(t) L.SetWhisperMsg(t) end)
	local wh = W.Text(p, "Whisper is sent on Award when the boss loot window is already closed.", 10, "dim")
	wh:SetPoint("TOPLEFT", X, -156); wh:SetPoint("RIGHT", -X, 0); wh:SetJustifyH("LEFT")
end

-- ---- History (landing/main): sessions accordion with an internal-scroll detail
-- box, drawn into the Dashboard's main area. Full width (no drawer).
local function Loot_BuildHistory(main)
	local L = Okanvil.Loot
	local fill = lootFill
	local X = 8

	-- a scroll panel INSIDE main so the sessions list scrolls without resizing
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

	local rows, detailRows = {}, {}
	local expanded = nil

	-- one reusable fixed-height detail box (internal scroll) for the open session
	local DETAIL_H = 260
	local dbox = W.Frame(p, "dark")
	local dsf = CreateFrame("ScrollFrame", nil, dbox)
	dsf:SetPoint("TOPLEFT", 4, -4); dsf:SetPoint("BOTTOMRIGHT", -10, 4)
	local dchild = CreateFrame("Frame", nil, dsf); dchild:SetSize(10, 1); dsf:SetScrollChild(dchild)
	local dsb = CreateFrame("Slider", nil, dbox)
	dsb:SetPoint("TOPRIGHT", -3, -4); dsb:SetPoint("BOTTOMRIGHT", -3, 4); dsb:SetWidth(4)
	dsb:SetOrientation("VERTICAL"); dsb:SetValueStep(1)
	local dth = dsb:CreateTexture(nil, "OVERLAY"); dth:SetTexture(FLAT); dth:SetVertexColor(u3(C.accent)); dth:SetSize(4, 40)
	dsb:SetThumbTexture(dth)
	dsb:SetScript("OnValueChanged", function(_, v) dsf:SetVerticalScroll(v) end)
	dsf:EnableMouseWheel(true)
	dsf:SetScript("OnMouseWheel", function(_, d) dsb:SetValue(dsb:GetValue() - d * 28) end)
	dsf:SetScript("OnSizeChanged", function() dchild:SetWidth(dsf:GetWidth()) end)
	dbox:Hide()

	local function detailRow(idx, yTop)
		local r = detailRows[idx]
		if not r then
			r = CreateFrame("Button", nil, dchild); r:SetHeight(18)
			r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(16, 16); r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92); r.icon:Hide()
			r.txt = r:CreateFontString(nil, "OVERLAY"); r.txt:SetFont(Okanvil:Font()); r.txt:SetJustifyH("LEFT")
			local hl = r:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetTexture(FLAT); hl:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 0.10)
			detailRows[idx] = r
		end
		r:ClearAllPoints(); r:SetPoint("TOPLEFT", 8, -yTop); r:SetPoint("RIGHT", dchild, "RIGHT", -6, 0)
		r:SetScript("OnEnter", nil); r:SetScript("OnLeave", nil); r:SetScript("OnClick", nil)
		r.icon:Hide(); r:Show()
		return r
	end

	local function rebuild()
		for _, r in ipairs(rows) do r:Hide() end
		for _, r in ipairs(detailRows) do r:Hide() end
		dbox:Hide()
		local sessions = (L.Sessions and L.Sessions()) or {}
		if #sessions == 0 then
			p._empty = p._empty or W.Text(p, "", 12, "dim")
			p._empty:SetPoint("TOPLEFT", X, -4)
			p._empty:SetText("|cff888888No loot logged yet. Kill a boss and open the corpse.|r")
			p._empty:Show(); p:SetHeight(math.max(sf:GetHeight(), 40)); return
		end
		if p._empty then p._empty:Hide() end
		local y = 0
		for i, s in ipairs(sessions) do
			local r = rows[i]
			if not r then
				r = W.Frame(p, "input")
				r.title = W.Text(r, "", 13); r.title:SetPoint("TOPLEFT", 10, -6)
				r.sub = W.Text(r, "", 10, "dim"); r.sub:SetPoint("BOTTOMLEFT", 10, 6)
				r.del = W.Button(r, "X", "danger"); r.del:SetSize(24, 22); r.del:SetPoint("RIGHT", -8, 0)
				r.export = W.Button(r, "Export"); r.export:SetSize(72, 22); r.export:SetPoint("RIGHT", r.del, "LEFT", -6, 0)
				r.view = W.Button(r, "View"); r.view:SetSize(60, 22); r.view:SetPoint("RIGHT", r.export, "LEFT", -6, 0)
				r:EnableMouse(true)
				rows[i] = r
			end
			r:ClearAllPoints(); r:SetPoint("TOPLEFT", X, -y); r:SetPoint("RIGHT", p, "RIGHT", -X, 0); r:SetHeight(40)
			local where = (s.zone ~= "" and s.zone) or "World"
			local isOpen = (expanded == s)
			r.title:SetText((isOpen and "|cffffd200v|r  " or "|cff8a8d93>|r  ") .. where .. "  |cff8a8d93" .. (s.day or "") .. "|r")
			r.sub:SetText("|cff8a8d93" .. #s.drops .. " drops|r")
			r.view.text:SetText(isOpen and "Close" or "View")
			r.view:SetScript("OnClick", function() if expanded == s then expanded = nil else expanded = s end; rebuild() end)
			r.export:SetScript("OnClick", function() Okanvil:ShowExport(L.SessionJSON(s), "Loot -- " .. (s.day or where)) end)
			r.del:SetScript("OnClick", function() if expanded == s then expanded = nil end; L.DeleteSession(s) end)
			r:Show()
			y = y + 46
			if isOpen then
				dbox:ClearAllPoints(); dbox:SetPoint("TOPLEFT", X, -y); dbox:SetPoint("RIGHT", p, "RIGHT", -X, 0)
				dbox:SetHeight(DETAIL_H); dbox:Show()
				dchild:SetWidth(dsf:GetWidth())
				local dy = select(2, L.RenderInline(s, detailRow, 0, 4))
				dchild:SetHeight(math.max(1, dy))
				local maxs = math.max(0, dy - (DETAIL_H - 8))
				dsb:SetMinMaxValues(0, maxs); dsb:SetValue(0); dsb:SetShown(maxs > 4)
				y = y + DETAIL_H + 6
			end
		end
		p:SetHeight(math.max(y + 6, sf:GetHeight()))
		local maxs = math.max(0, p:GetHeight() - sf:GetHeight())
		sb:SetMinMaxValues(0, maxs); sb:SetShown(maxs > 4)
	end
	if fill then fill._rebuildHistory = rebuild end
	rebuild()
end

-- ---- Loot capture settings (used as a tab INSIDE the Loot module) ----
local function Loot_BuildSettings(p)
	local db = Okanvil.db
	local ll = W.Text(p, "Log items of quality", 11, "dim"); ll:SetPoint("TOPLEFT", 8, -8)
	local RARITY = {
		{ text = "|cff9d9d9dPoor+|r", value = 0 }, { text = "|cffffffffCommon+|r", value = 1 },
		{ text = "|cff1eff00Uncommon+|r", value = 2 }, { text = "|cff0070ddRare+|r", value = 3 },
		{ text = "|cffa335eeEpic|r", value = 4 },
	}
	local lootDD = W.DropDown(p, function() return RARITY end,
		function() return db.lootThreshold or 3 end, function(v) db.lootThreshold = v end)
	lootDD:Size(160, 22):Point("TOPLEFT", 8, -26)
	lootDD.refreshText = function(self)
		local cur = db.lootThreshold or 3
		for _, o in ipairs(RARITY) do
			if o.value == cur then self.textFS:SetText(o.text); return end
		end
	end
	lootDD:refreshText()
	local rhint = W.Text(p, "Auto-capture in:", 11, "dim"); rhint:SetPoint("TOPLEFT", 8, -66)
	local cDun = W.Check(p, "Dungeons",
		function() return db.recordDungeon ~= false end, function(v) db.recordDungeon = v end)
	cDun:SetPoint("TOPLEFT", 8, -86)
	local cRaid = W.Check(p, "Raids",
		function() return db.recordRaid ~= false end, function(v) db.recordRaid = v end)
	cRaid:SetPoint("TOPLEFT", 160, -86)
end

local function Loot_BuildUI(panel)
	local host = panel
	local L = Okanvil.Loot
	lootFill = panel   -- set BEFORE the tab builders run (they read it)

	-- Dashboard shell (MRT/Recruit-style): header (icon + title + ML status + CTA),
	-- tabs (History = landing / Collectors / Messages as overlays), no drawer, no
	-- footer. History gets the whole main area so it scales as loot grows.
	local dash = W.Dashboard(host, {
		title = "Loot",
		icon = Okanvil.ICONS.loot,
		drawerWidth = 0,
		footerHeight = 0,
		primaryText = function() return "Mini Roll Manager" end,
		onPrimary = function()
			if Okanvil.RollMgr and Okanvil.RollMgr.Toggle then Okanvil.RollMgr.Toggle()
			else Okanvil:Print("Roll manager not loaded.") end
		end,
		statusText = function()
			if L and L.IsMasterLooter and L.IsMasterLooter() then
				return "|cff7cfc8aMaster Looter|r"
			end
			return "|cffff5555not the Master Looter|r"
		end,
		tabs = {
			{ key = "collectors", label = "Collectors", height = 330, build = function(pg) Loot_BuildCollectors(pg) end },
			{ key = "messages",   label = "Messages",   height = 260, build = function(pg) Loot_BuildMessages(pg) end },
			{ key = "settings",   label = "Settings",   height = 160, build = function(pg) Loot_BuildSettings(pg) end },
		},
	})
	panel.dash = dash

	Loot_BuildHistory(dash.main)     -- sessions accordion (landing)

	-- refresh when loot changes / the page shows / loot method changes
	local function refreshAll()
		dash:Refresh()
		if panel._rebuildHistory then panel._rebuildHistory() end
	end
	panel.refreshAll = refreshAll
	lootRefreshAll = refreshAll
	L.onLoot = function() if panel:IsShown() then refreshAll() end end
	if not panel._mlEv then
		panel._mlEv = CreateFrame("Frame")
		panel._mlEv:RegisterEvent("PARTY_LOOT_METHOD_CHANGED")
		panel._mlEv:RegisterEvent("RAID_ROSTER_UPDATE")
		panel._mlEv:SetScript("OnEvent", function() if panel:IsShown() then dash:Refresh() end end)
	end
	lootFill = panel
	return
end

local function Loot_Refresh()
	if lootRefreshAll then lootRefreshAll() end
end

local lootLoginEv = CreateFrame("Frame")
lootLoginEv:RegisterEvent("PLAYER_LOGIN")
lootLoginEv:SetScript("OnEvent", function()
	Okanvil_Plugins = Okanvil_Plugins or {}
	Okanvil_Plugins["__loot"] = {
		title = "Loot",
		desc = "Per-boss loot tracking with a fair-loot priority tab.",
		icon = Okanvil.ICONS.loot,
		build = Loot_BuildUI,
		refresh = Loot_Refresh,
	}
	if Okanvil.Register then Okanvil:Register("__loot") end
end)
