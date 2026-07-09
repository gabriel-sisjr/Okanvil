-- ============================================================
-- Recruit -- PURE logic (NO WoW API). Unit-testable.
-- Loaded before Recruit.lua.
-- ============================================================

RecruitLogic = RecruitLogic or {}

-- Damerau-Levenshtein distance (counts an adjacent transposition as 1, so it
-- catches common typos like "guidl" -> "guild" and "jpin" -> "join").
local function editDistance(a, b)
	local la, lb = #a, #b
	if math.abs(la - lb) > 1 then
		return 2
	end
	local d = {}
	for i = 0, la do
		d[i] = {}
		d[i][0] = i
	end
	for j = 0, lb do
		d[0][j] = j
	end
	for i = 1, la do
		for j = 1, lb do
			local cost = (a:sub(i, i) == b:sub(j, j)) and 0 or 1
			d[i][j] = math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
			if i > 1 and j > 1 and a:sub(i, i) == b:sub(j - 1, j - 1) and a:sub(i - 1, i - 1) == b:sub(j, j) then
				d[i][j] = math.min(d[i][j], d[i - 2][j - 2] + 1)
			end
		end
	end
	return d[la][lb]
end

-- does `msg` contain ANY of the comma-separated keywords in `list`?
-- Exact substring match, PLUS a 1-char fuzzy match per word for keywords of
-- length >= 4 (so "jpin" still matches "join", "guidl" matches "guild", ...).
function RecruitLogic.matchList(msg, list)
	if not msg or msg == "" or not list or list == "" then
		return false
	end
	local lower = string.lower(msg)
	for raw in string.gmatch(list, "[^,]+") do
		local kw = raw:gsub("^%s+", ""):gsub("%s+$", ""):lower()
		if kw ~= "" then
			if string.find(lower, kw, 1, true) then
				return true
			end
			if #kw >= 4 then
				for word in string.gmatch(lower, "%a+") do
					if math.abs(#word - #kw) <= 1 and editDistance(word, kw) <= 1 then
						return true
					end
				end
			end
		end
	end
	return false
end

-- Pure decision: what should happen for one whisper?
--   db  = config (keywords, reply, afkReply, afkMode, autoInvite,
--                 replyCooldown, inviteCooldown, blacklist)
--   ctx = { known=bool, now=number, lastInvite=num|nil, lastReply=num|nil, isEcho=bool }
-- returns { invite=bool, reply=string|nil }
function RecruitLogic.decide(db, msg, ctx)
	local out = { invite = false, reply = nil }
	if ctx.isEcho or ctx.known then
		return out
	end
	-- block words win over everything: gold sellers / beggars / ads are ignored
	-- even when they include an invite keyword ("inv pls i pay 10 gold").
	if db.blacklist and db.blacklist ~= "" and RecruitLogic.matchList(msg, db.blacklist) then
		return out
	end
	if not RecruitLogic.matchList(msg, db.keywords) then
		return out
	end

	-- invite and reply are independent features from here on: invite keeps its own
	-- toggle + cooldown, reply must still fire even when Auto-invite is off/cooling down.
	if db.autoInvite and not (ctx.lastInvite and (ctx.now - ctx.lastInvite) <= (db.inviteCooldown or 300)) then
		out.invite = true
	end

	local text = (db.afkMode and db.afkReply ~= "") and db.afkReply or db.reply
	if text and text ~= "" and (not ctx.lastReply or (ctx.now - ctx.lastReply) > (db.replyCooldown or 600)) then
		out.reply = text
	end
	return out
end
