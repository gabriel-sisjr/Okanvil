-- ============================================================
--  Okanvil-RaidFinder :: Module
--  Scans trade/yell chat for LFM raid spam (via Okanvil.RF) and shows
--  joinable listings in a W.Dashboard page: filters, roles, GS, Ress
--  column, /w + Join actions, leader, and a STABLE age timer.
--
--  Anti-jump design: each listing keeps firstSeen (frozen -> sort order)
--  and lastSeen (updated on re-spam -> age + expiry). Re-spam never
--  reorders rows; the age label just updates in place.
-- ============================================================

local ADDON = "Okanvil-RaidFinder"
Okanvil = Okanvil or {}
local RF = Okanvil.RF                       -- parser (loaded before this file)

local W = Okanvil.W
local ICON = "Interface\\Icons\\INV_Misc_GroupLooking"

local db                                     -- OkanvilRaidFinderDB (account-wide)
local defaults = {
	expiry = 60,           -- drop a listing this many seconds after its LAST spam
	scanChannels = true,   -- CHAT_MSG_CHANNEL (trade / LookingForGroup)
	scanYell = true,       -- CHAT_MSG_YELL
	minGS = 0,             -- hide listings below this GS req (0 = show all)
	showSaved = true,      -- show raids you're already saved to
	shortSpec = false,     -- short vs full spec name in the Join whisper
	gsOverride = 0,        -- manual GS for the whisper (0 = use detected GearScore)
}

-- listings[sender] = { raid, instance, size, hc, weekly, roles, gs, reserved,
--                      wantsAchiev, message, firstSeen, lastSeen, locked, reset }
local listings = {}

-- module UI state (rebuilt on Build)
local ui = {}

-- forward decl: is the Raid Finder panel the one currently shown?
local function page_visible()
	return Okanvil._current == ADDON and ui.count ~= nil
end

-- Modulo ligado? Um modulo DESLIGADO nos Modules deve ser como se nao existisse --
-- nao scaneia chat, nao faz parse, nada. (Nao basta esconder a UI.)
local function module_on()
	return not Okanvil.IsModuleEnabled or Okanvil:IsModuleEnabled(ADDON)
end

-- active filters (nil = All)
local filter = { instance = nil, size = nil, role = nil, weekly = nil }

-- column sort state. key = which column; asc = direction. Default: the stable
-- "firstSeen" order (what we've always used -- anti-jump). Clicking a header
-- switches to that column; clicking the active header flips direction; the
-- "seen" default is restored by clicking it a 3rd time (handled in the header).
local sortState = { key = "seen", asc = true }

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cffe0b860[Okanvil-RaidFinder]|r " .. tostring(msg))
end

-- ------------------------------------------------------------
-- lockout: is the player saved to this raid's instance+size?
-- (3.3.5a: GetNumSavedInstances / GetSavedInstanceInfo)
-- ------------------------------------------------------------
local function raid_lock_info(instance, size)
	if not instance or not size then return false, nil end
	for i = 1, GetNumSavedInstances() do
		local name, _, reset, _, locked, _, _, _, ssize = GetSavedInstanceInfo(i)
		if name and locked and ssize == size and name:lower() == instance:lower() then
			return true, reset
		end
	end
	return false, nil
end

-- ------------------------------------------------------------
-- CHAT SCANNING -> listings store
-- ------------------------------------------------------------
local function record(sender, message)
	if not sender or sender == "" then return end
	if not RF or not RF.parse then return end
	local info = RF.parse(message)
	if not info then return end

	local now = time()
	local existing = listings[sender]
	if existing then
		-- SAME sender re-spamming: refresh lastSeen + payload, but KEEP firstSeen
		-- so the row does not jump. Update fields in case they changed the message.
		existing.lastSeen  = now
		existing.raid      = info.raid
		existing.instance  = info.instance
		existing.size      = info.size
		existing.hc        = info.hc
		existing.weekly    = info.weekly
		existing.roles     = info.roles
		existing.classNeeds = info.classNeeds
		existing.gs        = info.gs
		existing.reserved  = info.reserved
		existing.wantsAchiev = info.wantsAchiev
		existing.message   = message
		existing._flash    = now             -- brief highlight; no reorder
	else
		info.sender    = sender
		info.message   = message
		info.firstSeen = now
		info.lastSeen  = now
		info._flash    = now
		info.locked, info.reset = raid_lock_info(info.instance, info.size)
		listings[sender] = info
	end

	if page_visible() then Okanvil.RaidFinder_Render() end
end

-- prune expired listings; refresh lockout (cheap RequestRaidInfo cache)
local function prune()
	local now = time()
	local changed = false
	for name, info in pairs(listings) do
		if now - info.lastSeen > (db.expiry or 60) then
			listings[name] = nil
			changed = true
		end
	end
	if changed and page_visible() then
		Okanvil.RaidFinder_Render()
	end
end

-- ------------------------------------------------------------
-- filtering + sorted view (SORT BY firstSeen -> stable)
-- ------------------------------------------------------------
local function passes_filter(info)
	if filter.instance and info.instance ~= filter.instance then return false end
	if filter.size and info.size ~= filter.size then return false end
	if filter.weekly ~= nil and (info.weekly and true or false) ~= filter.weekly then return false end
	if filter.role then
		local has = false
		for _, r in ipairs(info.roles) do if r == filter.role then has = true break end end
		if not has then return false end
	end
	if db.minGS and db.minGS > 0 then
		local n = tonumber(info.gs)
		if n and n * 1000 < db.minGS then return false end
	end
	if not db.showSaved and info.locked then return false end
	return true
end

local function get_view()
	local out = {}
	for _, info in pairs(listings) do
		if passes_filter(info) then out[#out + 1] = info end
	end
	-- Sort by the active column. Default ("seen") keeps the STABLE anti-jump order
	-- (oldest firstSeen on top, re-spam never reorders). Header clicks switch key
	-- and direction. Ties always fall back to firstSeen so order stays stable.
	local key, asc = sortState.key, sortState.asc
	local function cmp(a, b)
		local av, bv
		if key == "instance" then
			av, bv = a.raid or "", b.raid or ""
		elseif key == "leader" then
			av, bv = (a.sender or ""):lower(), (b.sender or ""):lower()
		elseif key == "age" then
			-- "age" = time since last spam; newer (bigger lastSeen) = younger.
			av, bv = a.lastSeen or 0, b.lastSeen or 0
		elseif key == "roles" then
			av, bv = #(a.roles or {}), #(b.roles or {})
		elseif key == "gs" then
			av, bv = tonumber(a.gs) or -1, tonumber(b.gs) or -1
		else -- "seen"
			av, bv = a.firstSeen or 0, b.firstSeen or 0
		end
		if av == bv then return (a.firstSeen or 0) < (b.firstSeen or 0) end
		if asc then return av < bv else return av > bv end
	end
	table.sort(out, cmp)
	return out
end

-- ------------------------------------------------------------
-- display helpers
-- ------------------------------------------------------------
local RAID_LABEL = {
	icc10nm="ICC10", icc25nm="ICC25", icc10hc="ICC10 HC", icc25hc="ICC25 HC", icc10wq="ICC10 Wk",
	toc10nm="ToC10", toc25nm="ToC25", toc10hc="ToGC10", toc25hc="ToGC25",
	ulduar10="Uld10", ulduar25="Uld25", ulduar10wq="Uld10 Wk",
	ulduar10hc="Uld10 HM", ulduar25hc="Uld25 HM",
	naxx10="Naxx10", naxx25="Naxx25", naxx10wq="Naxx10 Wk",
	rs10nm="RS10", rs25nm="RS25", rs10hc="RS10 HC", rs25hc="RS25 HC",
	voa10="VoA10", voa25="VoA25", os10="OS10", os25="OS25",
	eoe10="EoE10", eoe25="EoE25", ony10="Ony10", ony25="Ony25",
	-- TBC
	bt25="BT", swp25="Sunwell", mh25="Hyjal", ssc25="SSC", tk25="TK (Eye)",
	gruul25="Gruul", mag25="Mag", za10="ZA", kara10="Kara",
	-- Classic
	mc40="MC", bwl40="BWL", aq40="AQ40", aq20="AQ20",
}
local function raid_label(info) return RAID_LABEL[info.raid] or info.raid end

-- short instance-key (drop size/difficulty) for tier lookups
local function raid_tier(raidId) return (raidId:gsub("%d.*$", "")) end

-- Tier-specific loot items per raid, so a generic reserved category ("Orb",
-- "Fragments") resolves to the ACTUAL item for that tier and we can show a
-- real item link. itemIDs are standard WotLK; a wrong id just falls back to
-- the generic pill (GetItemInfo returns nil -> no link, no error).
--   Orb: crafting orb of the tier.  Frag: the raid's fragment/shard.
--   IDs marked (IDs-DB) were confirmed against Okanvil's ID Finder data; the
--   rest are standard WotLK ids. A wrong/unknown id is SAFE -- the resolver
--   falls back to a generic gold pill, never a wrong link or an error.
-- Per-tier reserve items, stored by NAME (+ a confirmed id where the ID Finder
-- DB already has it). We resolve the id in reserve_item_id() by:
--   1. the confirmed hardcoded id (Frozen/Runed Orb -- verified in the ID DB), else
--   2. a live name lookup in Okanvil.IDs (the ID Finder) -- so Crusader Orb /
--      Primordial Saronite / Shadowfrost Shard auto-resolve once your DB has
--      seen them, without me ever guessing a wrong id again.
--   3. nothing -> render a safe gold pill.
local TIER_ITEMS = {
	naxx   = { Orb = { name = "Frozen Orb", id = 43102 } },
	ulduar = { Orb = { name = "Runed Orb",  id = 45087 } },
	eoe    = { Orb = { name = "Runed Orb",  id = 45087 } },
	os     = { Orb = { name = "Runed Orb",  id = 45087 } },
	voa    = {},
	toc    = { Orb = { name = "Crusader Orb" } },
	icc    = { Orb = { name = "Primordial Saronite" },      -- resolves via ID Finder when seen
	           Fragments = { name = "Shadowfrost Shard" } },
	rs     = { Orb = { name = "Primordial Saronite" } },
	ony    = {},
}

-- Raid mounts that DROP from a boss (NOT achievement-reward mounts -- those
-- can't be loot-reserved). Keyed by FULL raid id (mounts differ by size).
-- Resolved by name via the ID Finder (auto-links once the DB has seen it);
-- until then -> a gold "Mount" pill.
--   Excluded on purpose: Ulduar Rusted/Ironbound Proto-Drake (achievement),
--   Naxx Blue Proto-Drake (achievement) -- leaders don't reserve those.
local TIER_MOUNTS = {
	icc25hc = { name = "Invincible's Reins" },              -- Lich King 25 HC drop
	eoe10   = { name = "Reins of the Blue Drake" },         -- Malygos 10 drop
	eoe25   = { name = "Reins of the Azure Drake" },        -- Malygos 25 drop
	os10    = { name = "Reins of the Twilight Drake" },     -- Sartharion 3D (10) drop
	os25    = { name = "Reins of the Black Drake" },        -- Sartharion 3D (25) drop
	ony10   = { name = "Reins of the Onyxian Drake" },      -- Onyxia drop
	ony25   = { name = "Reins of the Onyxian Drake" },
}

-- Size-specific reserved items keyed by FULL raid id (the item differs by 10 vs
-- 25). Right now: the Eye of Eternity key (Malygos gate item leaders reserve).
--   EoE10 = Key to the Focusing Iris (44582)
--   EoE25 = Heroic Key to the Focusing Iris (44581)  [confirmed by user]
local TIER_KEYS = {
	eoe10 = { name = "Key to the Focusing Iris",        id = 44582 },
	eoe25 = { name = "Heroic Key to the Focusing Iris", id = 44581 },
}

-- Quest turn-in items leaders reserve ("QUEST RESS"). Keyed by FULL raid id
-- (differ by size). Onyxia: the head that starts the reward quest.
--   NOTE: no hardcoded id -- our ID Finder DB (IDs-Data.lua) does NOT yet have
--   "Head of Onyxia", and the nearby ids 49485/49487 are OTHER Onyxia items
--   (Tooth Pendant / Blood Talisman), so guessing would show the WRONG link.
--   We resolve by NAME via the ID Finder; until the DB learns it -> a safe gold
--   "Quest" pill. Same pattern as Crusader Orb / Primordial Saronite.
local TIER_QUEST = {
	ony10 = { name = "Head of Onyxia" },
	ony25 = { name = "Head of Onyxia" },
}

-- resolve a category to a specific itemID for this raid, or nil (generic pill)
local function reserve_item_id(raidId, cat)
	-- Mounts + Keys + Quest items are keyed by FULL raid id (differ by size);
	-- generic tier items (Orb/Frags) are keyed by short tier.
	local e
	if cat == "Mount" then
		e = TIER_MOUNTS[raidId]
	elseif cat == "Key" then
		e = TIER_KEYS[raidId]
	elseif cat == "Quest" then
		e = TIER_QUEST[raidId]
	else
		local t = TIER_ITEMS[raid_tier(raidId)]
		e = t and t[cat]
	end
	if not e then return nil end
	if e.id then return e.id end
	-- try the ID Finder DB by exact name (auto-corrects as the DB grows)
	if Okanvil.IDs and Okanvil.IDs.FindItem and e.name then
		local res = Okanvil.IDs.FindItem(e.name, 3)
		for _, r in ipairs(res) do
			if r.name and r.name:lower() == e.name:lower() then
				e.id = r.id          -- cache it on the entry
				return r.id
			end
		end
	end
	return nil
end

-- Pre-warm the item cache so GetItemInfo returns links immediately (the first
-- query on an uncached item returns nil, then the client caches it). Called on
-- login. A tooltip scan forces the client to request each id from the server.
local _warmTip
function Okanvil.RaidFinder_WarmItemCache()
	if not _warmTip then
		_warmTip = CreateFrame("GameTooltip", "OkanvilRFWarmTip", nil, "GameTooltipTemplate")
		_warmTip:SetOwner(WorldFrame, "ANCHOR_NONE")
	end
	for _, items in pairs(TIER_ITEMS) do
		for _, e in pairs(items) do
			if e.id then
				GetItemInfo(e.id)                       -- triggers a cache request
				_warmTip:SetHyperlink("item:" .. e.id)   -- forces the client to load it
			end
		end
	end
end

-- Build the reserved tooltip for a listing. LIST format (one entry per line, a
-- gold bullet before each) so it's readable instead of a long single line:
--   Reserved loot          (gold header)
--     • BoE
--     • [Runed Orb]        (real item link where the tier id is confirmed)
--     • Patterns
-- Returns a multi-line string, or nil.
-- Categories that apply to ANY raid (loot-rule words + universally-possible
-- drops). Everything NOT here is tier-specific and must be validated against the
-- raid (a "Fragments" reserve on a ToC listing is a parse error -- ToC has no
-- shards; those are ICC). This kills bogus pills like the "of the" -> Fragments
-- misread surfacing on the wrong raid.
local UNIVERSAL_CATS = {
	BoE = true, Patterns = true, SoftRes = true, EV = true, STS = true,
	Mount = true,   -- validated further by TIER_MOUNTS; pill ok if the raid drops one
}
-- Is this reserve category plausible for this raid?
local function cat_valid_for_raid(raidId, cat)
	if UNIVERSAL_CATS[cat] then return true end
	-- tier/size-specific ones must exist in the resolver tables for this raid
	if cat == "Key"   then return TIER_KEYS[raidId]  ~= nil end
	if cat == "Quest" then return TIER_QUEST[raidId] ~= nil end
	local tier = TIER_ITEMS[raid_tier(raidId)]
	if cat == "Orb"       then return tier and tier.Orb ~= nil end
	if cat == "Fragments" then return tier and tier.Fragments ~= nil end
	if cat == "Shards"    then return tier and tier.Fragments ~= nil end
	-- unknown verbatim tokens (e.g. "RAG") -> allow (we surfaced them on purpose)
	return true
end

local function reserved_tooltip(info)
	local rv = info.reserved
	if type(rv) ~= "table" then return nil end
	local bits = {}
	for _, cat in ipairs(rv.cats or {}) do
		if cat_valid_for_raid(info.raid, cat) then
			local id = reserve_item_id(info.raid, cat)
			local link = id and select(2, GetItemInfo(id))
			bits[#bits + 1] = link or ("|cffe0b860" .. cat .. "|r")   -- item link, else gold pill
		end
	end
	-- Explicit named item (typed [Name] / nickname). Prefer a LIVE link resolved
	-- from the canonical name via the ID Finder; else fall back to the raw text.
	if rv.itemName and Okanvil.IDs and Okanvil.IDs.FindItem then
		local resolved
		for _, r in ipairs(Okanvil.IDs.FindItem(rv.itemName, 3)) do
			if r.name and r.name:lower() == rv.itemName:lower() then
				resolved = select(2, GetItemInfo(r.id)); break
			end
		end
		bits[#bits + 1] = resolved or rv.link or ("|cffe0b860[" .. rv.itemName .. "]|r")
	elseif rv.link then
		bits[#bits + 1] = rv.link
	end
	if #bits == 0 then
		return "|cffe0b860Reserved loot|r\n|cff8a8d93(details not specified)|r"
	end
	-- one entry per line, gold bullet prefix
	local lines = { "|cffe0b860Reserved loot|r" }
	for _, b in ipairs(bits) do
		lines[#lines + 1] = "|cffe0b860\226\128\162|r " .. b   -- "• <entry>"
	end
	return table.concat(lines, "\n")
end

local ROLE_COLOR = { tank = "|cff4a90d9", healer = "|cff7cfc8a", dps = "|cffe05555" }
local ROLE_SHORT = { tank = "Tank", healer = "Heal", dps = "DPS" }

-- Class-color escape ("|cffRRGGBB") for a WoW class token, from the client's
-- RAID_CLASS_COLORS (3.3.5a global). Fallback white if unknown/missing. A hard-
-- coded copy backs it up so the tooltip still colors right if the global is nil.
local CLASS_HEX = {
	DEATHKNIGHT = "c41f3b", DRUID = "ff7d0a", HUNTER = "abd473", MAGE = "69ccf0",
	PALADIN = "f58cba", PRIEST = "ffffff", ROGUE = "fff569", SHAMAN = "0070de",
	WARLOCK = "9482c9", WARRIOR = "c79c6e",
}
local function class_color(classToken)
	if not classToken then return "|cffffffff" end
	local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
	if c then return ("|cff%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255) end
	return "|cff" .. (CLASS_HEX[classToken] or "ffffff")
end
local function roles_text(roles)
	local parts = {}
	for _, r in ipairs(roles) do
		parts[#parts + 1] = (ROLE_COLOR[r] or "|cffffffff") .. (ROLE_SHORT[r] or r) .. "|r"
	end
	return table.concat(parts, " ")
end

-- Roles-cell tooltip: the generic roles wanted, plus any SPECIFIC specs the
-- leader named (grouped under their role, colored like the role). Returns a
-- multiline string, or nil when there's nothing worth showing.
local function roles_tooltip(info)
	local lines = { "|cffe0b860Roles wanted|r" }
	-- line 1: the generic roles (Tank / Heal / DPS)
	if info.roles and #info.roles > 0 then
		lines[#lines + 1] = roles_text(info.roles)
	end
	-- grouped specific specs, in Tank/Heal/DPS order -- each spec in its CLASS color
	local needs = info.classNeeds
	if type(needs) == "table" and #needs > 0 then
		lines[#lines + 1] = "|cff55575b\194\183\194\183\194\183|r"
		lines[#lines + 1] = "|cff8a8d93Specifically asking for:|r"
		for _, role in ipairs({ "tank", "healer", "dps" }) do
			local grp = {}
			for _, n in ipairs(needs) do
				if n.role == role then grp[#grp + 1] = class_color(n.class) .. n.label .. "|r" end
			end
			if #grp > 0 then
				lines[#lines + 1] = (ROLE_COLOR[role] or "|cffffffff") .. ROLE_SHORT[role] ..
					":|r " .. table.concat(grp, ", ")
			end
		end
	end
	if #lines <= 1 then return nil end
	return table.concat(lines, "\n")
end

local function age_text(info)
	local s = time() - info.lastSeen
	if s < 60 then return s .. "s" end
	if s < 3600 then return math.floor(s / 60) .. "m" end
	return math.floor(s / 3600) .. "h"
end

-- ------------------------------------------------------------
-- Shared tooltip helpers -- render a multiline string in the GameTooltip with a
-- SOLID (opaque) black backdrop so it's readable over the busy list (the default
-- WoW tooltip is semi-transparent). We force the backdrop on show and restore
-- the WoW defaults on hide, so other addons' tooltips are unaffected.
-- ------------------------------------------------------------
local function show_tip(owner, str, anchor)
	if type(str) ~= "string" then return end
	GameTooltip:SetOwner(owner, anchor or "ANCHOR_TOP")
	for line in (str .. "\n"):gmatch("(.-)\n") do
		GameTooltip:AddLine(line, 1, 1, 1)
	end
	GameTooltip:Show()
	-- opaque backdrop (default WoW is ~0.9 bg but border/tail let light through
	-- and it reads faint over the rows). Set AFTER Show(): 3.3.5a re-applies the
	-- template backdrop on show, so our override must come last. Full black bg +
	-- our gold-ish border.
	GameTooltip:SetBackdropColor(0, 0, 0, 1)
	GameTooltip:SetBackdropBorderColor(0.88, 0.72, 0.38, 1)
end
local function hide_tip()
	GameTooltip:Hide()
	-- restore WoW defaults so we don't leave every game tooltip opaque
	GameTooltip:SetBackdropColor(0, 0, 0, 0.9)
	GameTooltip:SetBackdropBorderColor(1, 1, 1, 1)
end

-- ------------------------------------------------------------
-- ACHIEVEMENTS (server-safe). Keyed by FULL raid id so it works for
-- every raid we care about -- NOT stripped to icc/toc like RaidBrowser
-- (whose link never fired for Naxx/Ulduar). IDs are Wrath retail values;
-- a private server may remap them, so every use is guarded by a live
-- GetAchievementInfo() check (Settings > Verify Achievement IDs pops the
-- real names). A bad/missing id => no link, never an error.
-- ------------------------------------------------------------
Okanvil.RaidFinder_Achievements = {
	{ raid = "naxx10",   name = "The Fall of Naxxramas (10)",     id = 576 },
	{ raid = "naxx25",   name = "The Fall of Naxxramas (25)",     id = 577 },
	{ raid = "ulduar10", name = "The Siege of Ulduar (10)",       id = 2886 },
	{ raid = "ulduar25", name = "The Siege of Ulduar (25)",       id = 2887 },
	{ raid = "toc10nm",  name = "Call of the Crusade (10)",       id = 3917 },
	{ raid = "toc25nm",  name = "Call of the Crusade (25)",       id = 3916 },
	{ raid = "toc10hc",  name = "Call of the Grand Crusade (10)", id = 3918 },
	{ raid = "toc25hc",  name = "Call of the Grand Crusade (25)", id = 3812 },
	{ raid = "icc10nm",  name = "Fall of the Lich King (10)",     id = 4532 },
	{ raid = "icc25nm",  name = "Fall of the Lich King (25)",     id = 4608 },
	{ raid = "icc10hc",  name = "Bane of the Fallen King (10 HC)",id = 4583 },
	{ raid = "icc25hc",  name = "The Light of Dawn (25 HC)",      id = 4584 },
}
local ach_by_raid = {}
for _, a in ipairs(Okanvil.RaidFinder_Achievements) do ach_by_raid[a.raid] = a.id end

-- Return a chat-ready achievement link for this raid IF the player has it
-- completed on THIS server, else nil. Fail-safe: bad id -> nil, no error.
local function my_achievement_link(raidId)
	local id = ach_by_raid[raidId]
	if not id then return nil end
	local ok, _, _, completed = pcall(GetAchievementInfo, id)
	if not ok then return nil end
	-- GetAchievementInfo returns (id, name, points, completed, ...)
	local _, aname, _, done = GetAchievementInfo(id)
	if not aname then return nil end          -- id doesn't exist on this server
	if not done then return nil end            -- player hasn't earned it
	local link = GetAchievementLink(id)
	return link
end

-- Player's GS read live from a GearScore addon (nil if none installed).
local function detected_gs()
	if GearScore_GetScore then
		local gs = GearScore_GetScore(UnitName("player"), "player")
		if gs then return gs end
	end
	if _G.GS_Data and GetRealmName then
		local realm = GS_Data[GetRealmName()]
		if realm and realm.Players and realm.Players[UnitName("player")] then
			return realm.Players[UnitName("player")].GearScore
		end
	end
	return nil
end

-- GS used in the whisper: manual override wins, else the detected GS.
local function my_gs()
	if db and db.gsOverride and db.gsOverride > 0 then return db.gsOverride end
	return detected_gs()
end

local function my_spec()
	if not GetTalentTabInfo then return nil end
	-- 3.3.5a: GetTalentTabInfo(tab) -> name, iconTexture, pointsSpent, background, ...
	-- (name is #1, NOT #2 -- #2 is the icon path, which leaked into the whisper.)
	local bestPts, bestName = -1, nil
	for i = 1, GetNumTalentTabs and GetNumTalentTabs() or 3 do
		local name, _, pts = GetTalentTabInfo(i)
		if pts and pts > bestPts then bestPts, bestName = pts, name end
	end
	if not bestName then return nil end
	-- append the class -> "Holy Paladin" (unless shortSpec keeps just "Holy")
	local class = UnitClass and select(1, UnitClass("player"))
	if class and not (db and db.shortSpec) then
		return bestName .. " " .. class
	end
	return bestName
end

-- expose for the Settings "Save Raid Gear" card
Okanvil.RaidFinder_DetectedGS = detected_gs
Okanvil.RaidFinder_MyGS = my_gs
Okanvil.RaidFinder_MySpec = my_spec

-- "inv for <raid> - <gs>gs <spec> [achiev]" -- shared by Join (sends) and /w (fills box)
local function build_whisper(info)
	local msg = "inv for " .. raid_label(info)
	local gs, spec = my_gs(), my_spec()
	local tail = {}
	if gs then tail[#tail + 1] = math.floor(gs) .. "gs" end
	if spec then tail[#tail + 1] = spec end
	if #tail > 0 then msg = msg .. " - " .. table.concat(tail, " ") end
	local link = my_achievement_link(info.raid)
	if link then msg = msg .. " " .. link end
	return msg
end
Okanvil.RaidFinder_BuildWhisper = build_whisper

-- Join: send the whisper immediately.
function Okanvil.RaidFinder_Join(info)
	if not info or not info.sender then return end
	SendChatMessage(build_whisper(info), "WHISPER", nil, info.sender)
end

-- /w: just open a blank whisper to the leader (you type your own message).
-- (Join sends the full "inv for ..." message; /w is a plain tell.)
function Okanvil.RaidFinder_Whisper(info)
	if not info or not info.sender then return end
	ChatFrame_SendTell(info.sender)
end

-- Verify the achievement-ID table against THIS server. Pops a copyable
-- report: OK (name matches), DIFF (server has a different name), NIL
-- (id doesn't exist here). Turns "ids might be wrong on my realm" into
-- a one-click check whose output we use to lock the table.
function Okanvil.RaidFinder_VerifyAchievements()
	local lines = { "Achievement-ID check for " .. (GetRealmName and GetRealmName() or "this realm") .. ":", "" }
	-- compare on the base name only: strip any trailing "(...)" from BOTH our
	-- label and the server name (server appends "(10 player)", we append "(10 HC)")
	local function base(s) return (s or ""):gsub("%s*%b()%s*$", ""):lower() end
	for _, a in ipairs(Okanvil.RaidFinder_Achievements) do
		local _, sname = GetAchievementInfo(a.id)
		local tag
		if not sname then
			tag = "NIL "
		elseif base(sname) == base(a.name) then
			tag = "OK  "
		else
			tag = "DIFF"
		end
		lines[#lines + 1] = string.format("[%s] %-5d %-28s | server: %s",
			tag, a.id, a.name, sname or "(none)")
	end

	-- reserve items per tier: shows resolved id (confirmed or via ID Finder) and
	-- the server name. "PILL" = no id yet -> renders as a gold pill (safe).
	lines[#lines + 1] = ""
	lines[#lines + 1] = "Reserve items (PILL = shows as pill until the ID Finder learns the item):"
	local seen = {}
	for tier, items in pairs(TIER_ITEMS) do
		for cat, e in pairs(items) do
			local key = tier .. "/" .. cat
			if not seen[key] then
				seen[key] = true
				local id = reserve_item_id(tier .. "25", cat)   -- resolve via same path as rows
				local iname = id and GetItemInfo(id)
				lines[#lines + 1] = string.format("[%s] %-10s want '%s' -> id=%s server='%s'",
					id and "OK  " or "PILL", key, e.name or "?", id and tostring(id) or "-", iname or "(pill)")
			end
		end
	end

	local text = table.concat(lines, "\n")
	if Okanvil.ShowExport then
		Okanvil:ShowExport(text, "Verify IDs (achievements + reserve items)")
	else
		Print(text)
	end
end

-- ------------------------------------------------------------
-- ROW LAYOUT
-- Columns (matches the reference screenshot):
--   Instance | GS | Roles | Ress | Action (/w, Join) | Leader | Age
-- x = left offset inside the row (row width tracks the scroll frame).
-- ------------------------------------------------------------
local COL = {
	instance = 10,
	gs       = 130,
	roles    = 185,
	ress     = 320,
	saved    = 372,
	action   = 428,
	leader   = 540,
	age      = 650,
}
local ROW_H = 22
local RESS_W = 42     -- Ress chip width (header centers over this)

-- one whisper/Join row. Created once, recycled by index.
local function make_row(parent)
	local r = CreateFrame("Button", nil, parent)
	r:SetHeight(ROW_H)
	-- base stripe (zebra) so rows read as a list
	local base = r:CreateTexture(nil, "BACKGROUND")
	base:SetAllPoints(); base:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
	base:SetVertexColor(1, 1, 1, 0); r._base = base
	-- hover/flash highlight (above base)
	local hl = r:CreateTexture(nil, "BORDER")
	hl:SetAllPoints(); hl:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
	hl:SetVertexColor(1, 1, 1, 0); r._hl = hl
	r:SetScript("OnEnter", function(s)
		s._hl:SetVertexColor(1, 1, 1, 0.06)
		if s._info and s._info.message then
			GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
			GameTooltip:AddLine(s._info.message, 1, 1, 1, true)
			GameTooltip:AddLine("Last spam: " .. (time() - s._info.lastSeen) .. "s ago", 0.6, 0.6, 0.6)
			if s._info.locked then
				GameTooltip:AddLine("|cffff5555You are saved to this raid|r")
			end
			GameTooltip:Show()
			GameTooltip:SetBackdropColor(0, 0, 0, 1)                 -- opaque, readable
			GameTooltip:SetBackdropBorderColor(0.88, 0.72, 0.38, 1)
		end
	end)
	r:SetScript("OnLeave", function(s) s._hl:SetVertexColor(1, 1, 1, 0); hide_tip() end)

	local function fs(x, size)
		local t = W.Text(r, "", size or 12)
		t:SetPoint("LEFT", x, 0); t:SetJustifyH("LEFT")
		return t
	end
	r.instance = fs(COL.instance)
	r.gs       = fs(COL.gs)
	r.roles    = fs(COL.roles)

	-- transparent hit area over the Roles cell -> "classes needed" tooltip.
	-- Spans from the Roles column to just before the Ress chip.
	r.rolesBtn = CreateFrame("Button", nil, r)
	r.rolesBtn:SetPoint("LEFT", COL.roles - 2, 0)
	r.rolesBtn:SetSize(COL.ress - COL.roles - 4, ROW_H)
	r.rolesBtn:SetScript("OnEnter", function(s)
		r._hl:SetVertexColor(1, 1, 1, 0.06)          -- keep the row highlight
		show_tip(s, s._tip)
	end)
	r.rolesBtn:SetScript("OnLeave", function() r._hl:SetVertexColor(1, 1, 1, 0); hide_tip() end)

	-- Ress chip -- a bordered box around YES/NO (like the reference image)
	r.ress = CreateFrame("Button", nil, r)
	r.ress:SetSize(RESS_W, 17); r.ress:SetPoint("LEFT", COL.ress, 0)
	Okanvil:Skin(r.ress, "input")
	r.ress.txt = W.Text(r.ress, "", 11); r.ress.txt:SetAllPoints(); r.ress.txt:SetJustifyH("CENTER")
	r.ress:SetScript("OnEnter", function(s)
		show_tip(s, s._res)   -- pre-built multiline list (header + item links/pills)
	end)
	r.ress:SetScript("OnLeave", function() hide_tip() end)

	-- Saved column (are YOU locked to this raid?) -- centered under its header
	r.saved = W.Text(r, "", 11); r.saved:SetPoint("LEFT", COL.saved, 0)
	r.saved:SetWidth(44); r.saved:SetJustifyH("CENTER")

	-- Action: /w  +  Join
	r.wsp = W.Button(r, "/w"); r.wsp:SetSize(34, 18); r.wsp:SetPoint("LEFT", COL.action, 0)
	r.wsp:SetScript("OnClick", function(s)
		if s._info then Okanvil.RaidFinder_Whisper(s._info) end
	end)
	r.join = W.Button(r, "Join", "primary"); r.join:SetSize(50, 18)
	r.join:SetPoint("LEFT", r.wsp, "RIGHT", 4, 0)
	r.join:SetScript("OnClick", function(s)
		if s._info then Okanvil.RaidFinder_Join(s._info) end
	end)

	r.leader = fs(COL.leader)
	r.age    = fs(COL.age, 11)
	return r
end

-- Repaint the sort-header labels: active column gets an up/down arrow and a
-- brighter tint; the rest revert to the accent color.
function Okanvil.RaidFinder_UpdateSortHeaders()
	if not ui.sortHeaders then return end
	for _, b in ipairs(ui.sortHeaders) do
		if b.key == sortState.key then
			local arrow = sortState.asc and " |cffe0b860\226\150\178|r" or " |cffe0b860\226\150\188|r"  -- ▲ / ▼
			b.fs:SetText(b.label .. arrow)
			b.fs:Color(1, 1, 1)
		else
			b.fs:SetText(b.label)
			local a = Okanvil.Colors.accent
			b.fs:Color(a[1], a[2], a[3])
		end
	end
end

function Okanvil.RaidFinder_Render()
	if not ui.count then return end
	local view = get_view()
	ui.count:SetText((#view) .. " active listing" .. (#view == 1 and "" or "s"))

	if not ui.child then return end
	ui.rows = ui.rows or {}
	local now = time()

	for i, info in ipairs(view) do
		local r = ui.rows[i]
		if not r then r = make_row(ui.child); ui.rows[i] = r end
		r._info = info
		r:ClearAllPoints()
		r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
		r:SetPoint("TOPRIGHT", 0, -(i - 1) * ROW_H)

		-- Instance (red if you're saved)
		r.instance:SetText(raid_label(info))
		if info.locked then r.instance:Color(1, 0.33, 0.33) else r.instance:Color(0.86, 0.86, 0.86) end

		-- GS
		r.gs:SetText(info.gs and (info.gs .. "k") or "|cff8a8d93--|r")

		-- Roles (+ "classes needed" tooltip on the cell)
		r.roles:SetText(roles_text(info.roles))
		r.rolesBtn._tip = roles_tooltip(info)

		-- Ress chip (bordered box). Our palette: YES = gold, NO = grey.
		if info.reserved == nil then
			r.ress:Hide(); r.ress._res = nil
		elseif info.reserved == false then
			r.ress:Show(); r.ress.txt:SetText("|cff8a8d93NO|r")
			r.ress:SetBackdropBorderColor(0.54, 0.55, 0.58, 1); r.ress._res = false   -- grey
		else
			r.ress:Show(); r.ress.txt:SetText("|cffe0b860YES|r")
			r.ress:SetBackdropBorderColor(0.88, 0.72, 0.38, 1)                          -- gold
			r.ress._res = reserved_tooltip(info)   -- pre-built multiline tooltip
		end

		-- Saved (are you locked to this raid?)
		if info.locked then r.saved:SetText("|cffff5555Saved|r") else r.saved:SetText("|cff7cfc8aOpen|r") end

		-- Actions
		r.wsp._info = info
		r.join._info = info

		-- Leader
		r.leader:SetText(info.sender or "?")

		-- Age (off lastSeen; updates in place, never reorders)
		r.age:SetText("|cff8a8d93" .. age_text(info) .. "|r")

		-- zebra stripe (odd rows slightly lighter)
		if i % 2 == 0 then r._base:SetVertexColor(1, 1, 1, 0) else r._base:SetVertexColor(1, 1, 1, 0.03) end

		-- brief flash on a fresh re-spam (no reorder)
		if info._flash and now - info._flash < 3 then
			r._hl:SetVertexColor(1, 0.82, 0, 0.10)
		else
			r._hl:SetVertexColor(1, 1, 1, 0)
		end
		r:Show()
	end
	-- hide leftover rows
	for i = #view + 1, #ui.rows do ui.rows[i]:Hide() end

	ui.child:SetHeight(math.max(1, #view * ROW_H))
	-- refresh scroll range
	if ui.sb and ui.sf then
		local maxS = math.max(0, (#view * ROW_H) - ui.sf:GetHeight())
		ui.sb:SetMinMaxValues(0, maxS)
		if ui.sb:GetValue() > maxS then ui.sb:SetValue(maxS) end
	end
end

-- ------------------------------------------------------------
-- SETTINGS TAB (overlay page from W.Dashboard tabs)
-- ------------------------------------------------------------
local function buildSettings(pg)
	local y = -12

	-- ---- Save Raid Gear: shows your spec + GS, lets you override the GS, and
	-- previews the whisper /w and Join send (spec + GS auto-filled). ----
	local hdr = W.Text(pg, "|cffe0b860Raid Gear|r  |cff8a8d93(auto-fills /w + Join with your spec + GS)|r", 12)
	hdr:SetPoint("TOPLEFT", 12, y); y = y - 22

	local specLine = W.Text(pg, "", 12)
	specLine:SetPoint("TOPLEFT", 12, y); y = y - 22

	-- GS override row: label + edit box + note
	local ovLabel = W.Text(pg, "Override GS (blank = use detected):", 11, "dim")
	ovLabel:SetPoint("TOPLEFT", 12, y)
	local preview = W.Text(pg, "", 11, "dim")
	local refreshGear   -- fwd decl (edit-box callback needs it)
	local ov = W.EditBox(pg, function(text)
		local n = tonumber((text or ""):gsub("[^%d.]", ""))
		if n and n < 100 then n = n * 1000 end          -- allow "6.2" meaning 6200
		db.gsOverride = n and math.floor(n) or 0
		refreshGear()
	end)
	ov:SetSize(70, 20); ov:SetPoint("LEFT", ovLabel, "RIGHT", 8, 0)
	if db.gsOverride and db.gsOverride > 0 then ov.edit:SetText(tostring(db.gsOverride)) end

	function refreshGear()
		local spec = Okanvil.RaidFinder_MySpec() or "?"
		local det  = Okanvil.RaidFinder_DetectedGS()
		local used = Okanvil.RaidFinder_MyGS()
		specLine:SetText(("Active spec: |cff4a90d9%s|r   Detected GS: |cffe0b860%s|r%s"):format(
			spec, det and (string.format("%.1fk", det/1000)) or "n/a",
			(db.gsOverride and db.gsOverride > 0) and ("   Using override: |cffe0b860"..string.format("%.1fk", db.gsOverride/1000).."|r") or ""))
		-- preview against a sample ICC25 listing
		local sample = { raid = "icc25nm", instance = "Icecrown Citadel", size = 25, roles = {} }
		preview:SetText("|cff8a8d93/w fills:|r |cffffffff" .. Okanvil.RaidFinder_BuildWhisper(sample) .. "|r")
	end
	-- expose so the talent-change event can live-refresh the spec/GS line
	Okanvil.RaidFinder_RefreshGear = refreshGear
	refreshGear()
	y = y - 24
	preview:SetPoint("TOPLEFT", 12, y); y = y - 26

	-- divider gap
	y = y - 6

	local function check(label, key)
		local c = W.Check(pg, label, function() return db[key] end, function(v) db[key] = v end)
		c:SetPoint("TOPLEFT", 12, y); y = y - 26
		return c
	end
	check("Scan chat channels (Trade / General / Global / LookingForGroup)", "scanChannels")
	check("Scan yell", "scanYell")
	check("Show raids I'm already saved to", "showSaved")
	check("Short spec name in Join whisper", "shortSpec")

	y = y - 24   -- breathing room before the sliders (label sits above the track)
	-- expiry slider (drop a listing N seconds after its last spam)
	local exp = W.Slider(pg, "Listing expiry (seconds)", 20, 300, 5,
		function() return db.expiry end,
		function(v) db.expiry = v end)
	exp:SetPoint("TOPLEFT", 12, y); exp:SetWidth(240); y = y - 60

	-- min GS filter
	local mgs = W.Slider(pg, "Minimum GS (0 = show all)", 0, 7000, 100,
		function() return db.minGS end,
		function(v) db.minGS = v; if page_visible() then Okanvil.RaidFinder_Render() end end)
	mgs:SetPoint("TOPLEFT", 12, y); mgs:SetWidth(240); y = y - 64

	-- Verify Achievement IDs
	local vb = W.Button(pg, "Verify Achievement IDs")
	vb:SetPoint("TOPLEFT", 12, y); vb:SetSize(190, 24)
	vb:SetScript("OnClick", function() Okanvil.RaidFinder_VerifyAchievements() end)
	local vh = W.Text(pg, "Checks the achievement link IDs against this server (OK / DIFF / NIL).", 11, "dim")
	vh:SetPoint("LEFT", vb, "RIGHT", 10, 0)
end

-- ------------------------------------------------------------
-- BUILD PAGE (W.Dashboard)  -- filters row + list area (scaffold)
-- ------------------------------------------------------------
local function buildUI(panel)
	ui = {}
	local dash = W.Dashboard(panel, {
		title = "Raid Finder",
		icon = ICON,
		drawerWidth = 0,   -- single-panel page
		footerHeight = 0,  -- no footer -> the list uses the full height (no dead strip)
		statusText = function() return "" end,
		tabs = {
			{ key = "settings", label = "Settings", height = 460, build = function(pg) buildSettings(pg) end },
		},
	})
	local main = dash.main

	-- filter bar
	local bar = W.Frame(main, "bare")
	bar:SetPoint("TOPLEFT", 8, -8); bar:SetPoint("TOPRIGHT", -8, -8); bar:SetHeight(24)

	local function label(x, t)
		local fs = W.Text(bar, t, 11, "dim"); fs:SetPoint("LEFT", x, 0); return fs
	end
	-- Raid Type
	label(0, "Raid")
	local instances = { "All", "Icecrown Citadel", "Trial of the Crusader", "Ulduar", "Naxxramas",
		"The Ruby Sanctum", "Vault of Archavon", "The Obsidian Sanctum", "The Eye of Eternity", "Onyxia's Lair",
		-- TBC
		"Black Temple", "Sunwell Plateau", "Hyjal Summit", "Serpentshrine Cavern", "Tempest Keep",
		"Gruul's Lair", "Magtheridon's Lair", "Zul'Aman", "Karazhan",
		-- Classic
		"Molten Core", "Blackwing Lair", "Temple of Ahn'Qiraj", "Ruins of Ahn'Qiraj" }
	ui.ddRaid = W.DropDown(bar,
		function() return instances end,
		function() return filter.instance or "All" end,
		function(v) filter.instance = (v ~= "All") and v or nil; Okanvil.RaidFinder_Render() end)
	ui.ddRaid:SetPoint("LEFT", 34, 0); ui.ddRaid:SetWidth(150)

	-- Size (10/25 only; old 40/20 raids still show under "All")
	ui.ddSize = W.DropDown(bar,
		function() return { "All", "10", "25" } end,
		function() return filter.size and tostring(filter.size) or "All" end,
		function(v) filter.size = (v ~= "All") and tonumber(v) or nil; Okanvil.RaidFinder_Render() end)
	ui.ddSize:SetPoint("LEFT", ui.ddRaid, "RIGHT", 8, 0); ui.ddSize:SetWidth(60)

	-- Role
	ui.ddRole = W.DropDown(bar,
		function() return { "All", "Tank", "Heal", "DPS" } end,
		function()
			if filter.role == "tank" then return "Tank" end
			if filter.role == "healer" then return "Heal" end
			if filter.role == "dps" then return "DPS" end
			return "All"
		end,
		function(v)
			filter.role = (v == "Tank" and "tank") or (v == "Heal" and "healer") or (v == "DPS" and "dps") or nil
			Okanvil.RaidFinder_Render()
		end)
	ui.ddRole:SetPoint("LEFT", ui.ddSize, "RIGHT", 8, 0); ui.ddRole:SetWidth(70)

	-- Weekly
	ui.ddWeekly = W.DropDown(bar,
		function() return { "All", "Weekly only", "Non-weekly" } end,
		function()
			if filter.weekly == true then return "Weekly only" end
			if filter.weekly == false then return "Non-weekly" end
			return "All"
		end,
		function(v)
			filter.weekly = (v == "Weekly only" and true) or (v == "Non-weekly" and false) or nil
			Okanvil.RaidFinder_Render()
		end)
	ui.ddWeekly:SetPoint("LEFT", ui.ddRole, "RIGHT", 8, 0); ui.ddWeekly:SetWidth(100)

	-- Reset filters
	local reset = W.Button(bar, "Reset")
	reset:SetPoint("RIGHT", 0, 0); reset:SetSize(70, 22)
	reset:SetScript("OnClick", function()
		filter.instance, filter.size, filter.role, filter.weekly = nil, nil, nil, nil
		ui.ddRaid:refreshText(); ui.ddSize:refreshText(); ui.ddRole:refreshText(); ui.ddWeekly:refreshText()
		Okanvil.RaidFinder_Render()
	end)

	-- count line
	ui.count = W.Text(main, "0 active listings", 12, "dim")
	ui.count:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -10)

	-- opaque list well (dark panel) so the game world never shows through
	local well = W.Frame(main, "dark")
	well:SetPoint("TOPLEFT", ui.count, "BOTTOMLEFT", 0, -6)
	well:SetPoint("BOTTOMRIGHT", main, "BOTTOMRIGHT", -8, 8)

	-- column header row (inside the well, opaque strip)
	local hdr = W.Frame(well, "input")
	hdr:SetPoint("TOPLEFT", 2, -2); hdr:SetPoint("TOPRIGHT", -2, 0); hdr:SetHeight(18)
	local function colh(x, t) local fs = W.Text(hdr, t, 11, "accent"); fs:SetPoint("LEFT", x + 4, 0) end
	-- centered header (over a fixed-width cell): x = cell left, w = cell width
	local function colhC(x, w, t)
		local fs = W.Text(hdr, t, 11, "accent"); fs:SetJustifyH("CENTER")
		fs:SetPoint("LEFT", x, 0); fs:SetWidth(w)
	end

	-- CLICKABLE sort header. Clicking sets the sort column; clicking the active
	-- one flips direction, and a 3rd click on it returns to the default "seen"
	-- (stable) order. Shows a small ^/v arrow on the active column.
	ui.sortHeaders = {}
	local function sortHeader(x, t, key)
		local b = CreateFrame("Button", nil, hdr)
		b:SetHeight(18); b:SetPoint("LEFT", x, 0)
		local fs = W.Text(b, t, 11, "accent"); fs:SetPoint("LEFT", 4, 0)
		b:SetWidth(fs:GetStringWidth() + 18)
		b.label, b.key = t, key
		b:SetScript("OnClick", function()
			if sortState.key ~= key then
				sortState.key, sortState.asc = key, true
			elseif sortState.asc then
				sortState.asc = false
			else
				sortState.key, sortState.asc = "seen", true   -- 3rd click -> default
			end
			Okanvil.RaidFinder_UpdateSortHeaders()
			Okanvil.RaidFinder_Render()
		end)
		b:SetScript("OnEnter", function() fs:Color(1, 1, 1) end)
		b:SetScript("OnLeave", function() Okanvil.RaidFinder_UpdateSortHeaders() end)
		b.fs = fs
		ui.sortHeaders[#ui.sortHeaders + 1] = b
		return b
	end

	sortHeader(COL.instance, "Instance", "instance")
	sortHeader(COL.gs, "GS", "gs")
	sortHeader(COL.roles, "Roles", "roles")
	colhC(COL.ress, RESS_W, "Ress"); colhC(COL.saved, 44, "Saved"); colh(COL.action, "Action")
	sortHeader(COL.leader, "Leader", "leader")
	sortHeader(COL.age, "Age", "age")

	-- flat scroll list (plain ScrollFrame + our slider), like Logs history
	local sf = CreateFrame("ScrollFrame", nil, well)
	sf:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, -2)
	sf:SetPoint("BOTTOMRIGHT", well, "BOTTOMRIGHT", -14, 6)
	Okanvil.Clip(sf)
	local child = CreateFrame("Frame", nil, sf); child:SetSize(10, 1); sf:SetScrollChild(child)
	local sb = CreateFrame("Slider", nil, well)
	sb:SetPoint("TOPRIGHT", sf, "TOPRIGHT", 8, 0); sb:SetPoint("BOTTOMRIGHT", sf, "BOTTOMRIGHT", 8, 0); sb:SetWidth(4)
	sb:SetOrientation("VERTICAL"); sb:SetValueStep(1); sb:SetMinMaxValues(0, 0); sb:SetValue(0)
	local th = sb:CreateTexture(nil, "OVERLAY"); th:SetTexture("Interface\\ChatFrame\\ChatFrameBackground"); th:SetSize(4, 40)
	do local a = Okanvil.Colors.accent; th:SetVertexColor(a[1], a[2], a[3], 1) end
	sb:SetThumbTexture(th)
	sb:SetScript("OnValueChanged", function(_, v) sf:SetVerticalScroll(v) end)
	sf:EnableMouseWheel(true)
	sf:SetScript("OnMouseWheel", function(_, d) sb:SetValue(sb:GetValue() - d * 30) end)
	sf:SetScript("OnSizeChanged", function() child:SetWidth(sf:GetWidth()) end)
	ui.sf, ui.child, ui.sb = sf, child, sb

	Okanvil.RaidFinder_UpdateSortHeaders()
	Okanvil.RaidFinder_Render()
end

-- ------------------------------------------------------------
-- events / boot
-- ------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("CHAT_MSG_CHANNEL")
ev:RegisterEvent("CHAT_MSG_YELL")
-- talent/spec changes -> live-refresh the "Active spec" line in Settings.
-- 3.3.5a spec/talent-change events (register all; some cores fire only one).
ev:RegisterEvent("PLAYER_TALENT_UPDATE")
ev:RegisterEvent("CHARACTER_POINTS_CHANGED")
ev:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")   -- dual-spec swap
ev:SetScript("OnEvent", function(_, event, arg1, arg2, ...)
	if event == "PLAYER_TALENT_UPDATE" or event == "CHARACTER_POINTS_CHANGED"
	   or event == "ACTIVE_TALENT_GROUP_CHANGED" then
		if Okanvil.RaidFinder_RefreshGear then Okanvil.RaidFinder_RefreshGear() end
		return
	end
	if event == "ADDON_LOADED" and arg1 == "Okanvil" then
		OkanvilRaidFinderDB = OkanvilRaidFinderDB or {}
		db = OkanvilRaidFinderDB
		for k, v in pairs(defaults) do if db[k] == nil then db[k] = v end end
	elseif event == "PLAYER_LOGIN" then
		if not db then
			OkanvilRaidFinderDB = OkanvilRaidFinderDB or {}
			db = OkanvilRaidFinderDB
			for k, v in pairs(defaults) do if db[k] == nil then db[k] = v end end
		end
		-- register as a native module (toggle off in Modules to hide + silence)
		Okanvil_Plugins = Okanvil_Plugins or {}
		Okanvil_Plugins[ADDON] = {
			title = "Raid Finder",
			desc = "Scan chat for LFM raids: filter, whisper/join, Ress + achievements.",
			icon = ICON,
			build = function(panel) buildUI(panel) end,
			refresh = function() if Okanvil.RaidFinder_Render then Okanvil.RaidFinder_Render() end end,
		}
		if Okanvil.Register then
			Okanvil:Register(ADDON)
			Print("loaded. |cff00ff00/okrf|r opens the Raid Finder.  |cff00ff00/script Okanvil.RF.test()|r tests the parser.")
		end
		-- RequestRaidInfo warms the lockout cache for raid_lock_info().
		RequestRaidInfo()
		-- pre-warm reserve item links so they resolve on first hover
		Okanvil.RaidFinder_WarmItemCache()
	elseif event == "CHAT_MSG_CHANNEL" then
		-- Modulo DESLIGADO = como se nao existisse: nao scaneia nada.
		-- Ligado mas com a tab FECHADA = tambem nao scaneia (performance): antes
		-- corria RF.parse() para CADA linha de chat sempre, dando lag/frame-drops
		-- numa raid com muito trafego. So scaneia com o modulo ligado E a tab aberta.
		if module_on() and page_visible() and db and db.scanChannels then record(arg2, arg1) end
	elseif event == "CHAT_MSG_YELL" then
		if module_on() and page_visible() and db and db.scanYell then record(arg2, arg1) end
	end
end)

-- lightweight prune ticker (independent OnUpdate frame, 5s cadence)
local tick = CreateFrame("Frame")
local acc = 0
tick:SetScript("OnUpdate", function(_, elapsed)
	acc = acc + elapsed
	if acc >= 5 then
		acc = 0
		if db then prune() end
		-- keep age labels fresh while the page is open
		if page_visible() then Okanvil.RaidFinder_Render() end
	end
end)

-- ------------------------------------------------------------
-- slash
-- ------------------------------------------------------------
SLASH_OKANVILRF1 = "/okrf"
SlashCmdList["OKANVILRF"] = function()
	if Okanvil.ShowPanel then Okanvil:ShowPanel(ADDON) end
	if Okanvil.win and not Okanvil.win:IsShown() then Okanvil.win:Show() end
end
