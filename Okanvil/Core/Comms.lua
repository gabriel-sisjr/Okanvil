-- ============================================================
-- Okanvil -- Comms (central addon-message bus).
-- ONE place for ALL cross-client talk. Every feature that needs to reach other
-- players' Okanvil (loot re-sync now; collectors / counters / whatever later)
-- goes through here instead of each module opening its own SendAddonMessage.
--
-- 3.3.5a notes (verified against RCLootCouncil's AceComm on the live client):
--   * SendAddonMessage(prefix, text, chattype, target) exists; NO
--     RegisterAddonMessagePrefix on this patch -- CHAT_MSG_ADDON just arrives,
--     we filter by prefix in the handler.
--   * CHAT_MSG_ADDON fires as (prefix, message, channel, sender).
--   * prefix + text must stay under ~255 bytes and shares the chat throttle, so
--     payloads are short and fire-and-forget (pair a PUSH with a FETCH/ACK).
--
-- WIRE FORMAT (versioned so mismatched clients ignore what they don't know):
--     OKV1|<TYPE>|<arg1>|<arg2>|...
--   Fields are '|'-separated; a leading "OKV1" gates the protocol version.
--   Unknown TYPEs are dropped silently (forward-compatible).
--
-- TRUST MODEL (the user's hard rule -- anti-ninja): messages are trusted by the
-- sender's ROLE, never by the prefix (anyone can spoof "OKANVIL"). A handler
-- that ACTS on a message (e.g. changes loot method) must re-check the live
-- game state -- "is this sender really the current ML / raid leader?" -- before
-- doing anything. Comms only delivers; it never assumes the sender is honest.
-- ============================================================

local Okanvil = Okanvil
local C = {}
Okanvil.Comms = C

local PREFIX  = "OKANVIL"   -- addon-message prefix (shared by every feature)
local VERSION = "OKV1"      -- payload version tag; bump only on a breaking change
local SEP     = "|"

-- registered message handlers: TYPE -> fn(sender, ...args). Modules add theirs
-- with C.On("MLFIX", handler). Kept load-order safe: a module can register
-- before or after Comms loads, as long as Comms loads first in the .toc (it does).
local handlers = {}

-- ------------------------------------------------------------
-- Encode / decode. We escape the separator inside args so a name or payload that
-- happens to contain '|' can't split a field (belt-and-suspenders: player names
-- can't contain '|', but future payloads might).
-- ------------------------------------------------------------
local function encField(s)
	return (tostring(s == nil and "" or s):gsub("|", "/"))   -- '|' -> '/' (names never contain either meaningfully)
end

local function pack(msgType, ...)
	local parts = { VERSION, msgType }
	local n = select("#", ...)
	for i = 1, n do parts[#parts + 1] = encField(select(i, ...)) end
	return table.concat(parts, SEP)
end

-- ------------------------------------------------------------
-- Channel pick: whatever group we're in. RAID if raiding, else PARTY; nil solo
-- (nothing to send to -- callers should no-op). We never send to GUILD here:
-- these messages are about the CURRENT group's state, not the whole guild.
-- ------------------------------------------------------------
local function groupChannel()
	if GetNumRaidMembers and GetNumRaidMembers() > 0 then return "RAID" end
	if GetNumPartyMembers and GetNumPartyMembers() > 0 then return "PARTY" end
	return nil
end

-- ------------------------------------------------------------
-- PUBLIC API
-- ------------------------------------------------------------

-- Register a handler for a message TYPE. fn is called as fn(sender, arg1, arg2, ...)
-- where sender is the raw unit name from CHAT_MSG_ADDON. Only ONE handler per
-- type (last registration wins) -- keeps the bus simple; a type maps to a feature.
function C.On(msgType, fn)
	handlers[msgType] = fn
end

-- Send a typed message to the current group. Returns true if it went out.
-- Fire-and-forget: no delivery guarantee (that's why acts are PUSH + ACK).
function C.Send(msgType, ...)
	local chan = groupChannel()
	if not chan then return false end
	local text = pack(msgType, ...)
	if #text > 240 then return false end   -- stay well under the ~255B cap; long payloads must chunk (none yet)
	SendAddonMessage(PREFIX, text, chan)
	return true
end

-- ------------------------------------------------------------
-- Receive: split the payload, gate on version, dispatch to the type handler.
-- The sender name is passed through un-trusted -- handlers validate by role.
-- ------------------------------------------------------------
local function onMessage(prefix, message, channel, sender)
	if prefix ~= PREFIX or not message then return end
	-- split on SEP
	local fields = {}
	for f in (message .. SEP):gmatch("(.-)" .. "%" .. SEP) do fields[#fields + 1] = f end
	if fields[1] ~= VERSION then return end          -- other/older protocol -> ignore
	local msgType = fields[2]
	local fn = msgType and handlers[msgType]
	if not fn then return end                         -- unknown type -> forward-compatible drop
	-- normalise the sender ("Name-Realm" -> "Name" for same-realm compares)
	local who = sender and sender:gsub("%-.*$", "") or ""
	-- hand the remaining fields (3..n) to the handler as varargs
	fn(who, unpack(fields, 3))
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:SetScript("OnEvent", function(_, _, prefix, message, channel, sender)
	onMessage(prefix, message, channel, sender)
end)
