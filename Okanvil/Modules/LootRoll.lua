-- ============================================================
-- Okanvil -- Mini Roll Manager (native module).
-- A small floating loot-master window (RaidRoll-style): pops when eligible loot
-- drops, lists the items, lets you START a roll (MS / OS / Free -> announced in
-- raid/RW), shows the live rolls (main-spec beats off-spec, highest wins), and
-- AWARDS the winner (marks the drop owner + whispers them). Also shows the
-- fragment/BoE collector counters. Uses the Loot module's data + API; adds NO
-- new capture -- purely a control surface, so you don't open the big window.
-- ============================================================

local Okanvil = Okanvil
local W = Okanvil.W
local L = Okanvil.Loot
local RM = {}
Okanvil.RollMgr = RM

-- roomier than before: bigger rows, bigger text (user asked for more spacing).
local ROW_H = 26
local FONT_SZ = 13
local ITEM_ROWS, ROLL_ROWS = 5, 6
local WIN_W = 340   -- wider: long item names + player names fit

local function db()
	Okanvil.db.rollmgr = Okanvil.db.rollmgr or { point = "RIGHT", x = -30, y = 60, autoShow = true }
	return Okanvil.db.rollmgr
end

-- Icon resolver: delegates to the shared Core warmer (Okanvil:ItemIcon), which
-- returns the icon now or nil + auto-queues a server query so a later tick fills
-- it in. Fixes the "?" icons on a fresh client without any manual hovering.
local function itemIcon(itemLink)
	return itemLink and Okanvil:ItemIcon(itemLink) or nil
end

-- are we the loot master right now? (drives ML-vs-raider layout)
-- MUST match the Loot module's real check: master-loot method AND *we* are the ML.
-- The old test only checked the method was "master" (true for EVERYONE in the raid,
-- not just the ML), so it showed the "Loot Master" layout + Award button to plain
-- raiders who can't actually give loot -- and disagreed with the Loot page's
-- "not the Master Looter" banner. Delegate to L.IsMasterLooter so they always agree.
local function amML()
	if L and L.IsMasterLooter then return L.IsMasterLooter() end
	return false
end

-- class-ish color for an item by rarity (falls back to white)
local function rarityColor(r)
	local q = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[r or 1]
	if q then return q.r, q.g, q.b end
	return 0.9, 0.9, 0.9
end

-- class color of a player by NAME -> "|cffRRGGBB". Delegates to the Loot
-- module's persistent, cross-session class cache (L.ClassOf) so rolls and the
-- saved history always agree on a player's color. Falls back to gold if
-- unknown -- but once we EVER see the player grouped or in the guild, Loot
-- remembers their class, so the color shows up even later.
local function classColorCode(name)
	if not name or name == "" then return "|cffffd200" end
	local short = name:gsub("%-.*$", "")
	local class
	-- The PERSISTENT cache from the Loot module (L.ClassOf), shared with the
	-- history -- so rolls and history use the SAME class color, and it
	-- persists across sessions (remembered once seen grouped/in the guild).
	if Okanvil.Loot and Okanvil.Loot.ClassOf then
		local c0 = Okanvil.Loot.ClassOf(short)
		if c0 and c0 ~= "" then class = c0 end
	end
	local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if c then return string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255) end
	return "|cffffd200"   -- unknown class -> gold (shows up once they're grouped/guilded)
end

-- ------------------------------------------------------------
-- window
-- ------------------------------------------------------------
local win
local selected            -- the drop table currently picked for a roll
local function isML() return amML() end

local function buildWindow()
	if win then return win end
	local f = CreateFrame("Frame", "Okanvil_RollMgr", UIParent)
	f:SetSize(WIN_W, 200)   -- height set dynamically in Refresh
	local d = db()
	f:SetPoint(d.point or "RIGHT", UIParent, d.point or "RIGHT", d.x or -30, d.y or 60)
	f:SetFrameStrata("HIGH"); f:SetToplevel(true)
	Okanvil:Skin(f, "panel")
	local br, bg, bb = f:GetBackdropColor()
	if br then f:SetBackdropColor(br, bg, bb, 0.97) end
	f:EnableMouse(true); f:SetMovable(true); f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(s)
		s:StopMovingOrSizing()
		local p, _, _, x, y = s:GetPoint(1)
		d.point, d.x, d.y = p, x, y
	end)
	f:SetClampedToScreen(true)

	-- header
	local hdr = W.Frame(f, "raise")
	hdr:SetPoint("TOPLEFT", 1, -1); hdr:SetPoint("TOPRIGHT", -1, -1); hdr:SetHeight(26)
	local ico = hdr:CreateTexture(nil, "OVERLAY")
	ico:SetSize(16, 16); ico:SetPoint("LEFT", 8, 0)
	ico:SetTexture("Interface\\Icons\\Trade_BlackSmithing")   -- anvil, like the shell
	ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	local title = W.Text(hdr, "Okanvil - Mini Roll Manager", 13, "accent"); title:SetPoint("LEFT", ico, "RIGHT", 6, 0); title:Color(1, 0.82, 0)
	local close = W.Button(hdr, "X"); close:SetSize(22, 20); close:SetPoint("RIGHT", -3, 0)
	close:SetScript("OnClick", function() f:Hide() end)

	-- status line (ML / Raider, from the real loot method)
	local status = W.Text(f, "", 12, "dim"); status:SetPoint("TOPLEFT", 12, -34)
	f.status = status

	-- everything below the status is rebuilt when the ML state changes, so pack the
	-- mode-specific widgets into a container we can wipe. Give it a FULL size
	-- (TOPLEFT + BOTTOMRIGHT) -- a frame with height 0 doesn't render its children
	-- reliably on 3.3.5a, which is why the body looked empty.
	local body = CreateFrame("Frame", nil, f)
	body:SetPoint("TOPLEFT", 0, -52); body:SetPoint("BOTTOMRIGHT", 0, 0)
	f.body = body

	-- "Roll open" animation: while a roll-off is open, cycle dots + a pulsing gold
	-- so the window feels alive. NO countdown: a roll never auto-closes here (the
	-- item is often handed out by master loot outside the addon), so a shrinking
	-- "110s" timer just got stuck at "Rolling.." forever after the item was given.
	-- We show which item is up for roll, no timer.
	f._anim = 0
	f:SetScript("OnUpdate", function(self, e)
		if not self:IsShown() then return end
		-- Fill in any "?" icons once the client has cached the item (fresh client:
		-- GetItemInfo is nil at first). Throttled to ~2x/sec so it's cheap.
		self._iconAcc = (self._iconAcc or 0) + e
		if self._iconAcc >= 0.5 and self.itemRows then
			self._iconAcc = 0
			for _, r in ipairs(self.itemRows) do
				if r:IsShown() and r._d and r._d.item then
					local tex = itemIcon(r._d.item)
					if tex then r.icon:SetTexture(tex) end
				end
			end
		end
		-- Shrinking roll-timer bars on the item rows (ElvUI M:statusbarOnUpdate style):
		-- read GetLootRollTimeLeft(rollID) each frame and scale the row-width bar.
		if self.itemRows then
			self._dots = (self._dots or 0) + e
			local dots = ("."):rep(1 + (math.floor(self._dots * 2) % 3))   -- . / .. / ...
			for _, r in ipairs(self.itemRows) do
				local d = r._d
				if r:IsShown() and r._rolling and d then
					-- shrinking bar
					local frac
					if d.rollID then
						local left = GetLootRollTimeLeft and GetLootRollTimeLeft(d.rollID) or 0
						local dur = (d.rollDur and d.rollDur > 0) and (d.rollDur * 1000) or 60000
						frac = left / dur
					elseif d.rollStart and d.rollDur then
						frac = 1 - ((GetTime() - d.rollStart) / d.rollDur)
					end
					if frac then
						if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
						if frac <= 0 then r.bar:Hide()
						else r.bar:SetWidth(math.max(1, r:GetWidth() * frac)) end
					end
					-- TIMER ENDED: stop showing "rolling". The winner arrives via
					-- CHAT_MSG_LOOT (recordRollWon) que limpa rollID + poe receivedBy;
					-- mas se o roll expira sem esse evento chegar, limpamos aqui para a
					-- bar doesn't stay stuck on "rolling..." forever.
					if frac and frac <= 0 then
						r._rolling = false
						d.rollID = nil; d.rollStart = nil
						if r._baseTxt then r.txt:SetText(r._baseTxt) end
					elseif r._baseTxt then
						r.txt:SetText(r._baseTxt .. "  |cffffd200- rolling " .. dots .. "|r")
					end
				end
			end
		end
		-- "Roll open" pulsing label (only when a managed roll-off is active)
		local ar = L and L.ActiveRoll and L.ActiveRoll()
		if not (ar and self.rollState) then return end
		self._anim = self._anim + e
		local dots = ("."):rep(1 + (math.floor(self._anim * 2) % 3))   -- . / .. / ...
		local pulse = 0.7 + 0.3 * math.abs(math.sin(self._anim * 3))
		local g = string.format("|cff%02xd200", math.floor(0xff * pulse))
		local m = (ar.mode == "ms" and "MS") or (ar.mode == "os" and "OS") or "FREE"
		local nm = (ar.name ~= "" and ar.name) or "item"
		self.rollState:SetText(g .. "Roll open" .. dots .. "|r " .. nm .. "  |cff8a8d93[" .. m .. "]|r")
	end)

	win = f
	f:Hide()
	return f
end

-- (re)build the mode-specific body: full manager for ML, just roll buttons for a
-- raider. Called on show and whenever the ML mode changes.
function RM.Rebuild()
	if not win then return end
	local f = win
	-- clear old body widgets. NOTE: fontstrings/textures CANNOT take a nil parent
	-- on 3.3.5a (that's the LootRoll.lua:112 error) -- only real Frames can be
	-- reparented to the hidden trash. FontStrings just get hidden + cleared.
	f.trash = f.trash or CreateFrame("Frame"); f.trash:Hide()
	if f.bodyKids then
		for _, w in ipairs(f.bodyKids) do
			w:Hide()
			if w.GetObjectType and w:GetObjectType() == "FontString" then
				if w.SetText then w:SetText("") end
			elseif w.SetParent then
				w:SetParent(f.trash)
			end
		end
	end
	f.bodyKids = {}
	f.itemRows, f.rollRows = {}, {}
	local body = f.body
	local function keep(w) f.bodyKids[#f.bodyKids + 1] = w; return w end

	local ml = isML()
	local ac = Okanvil.Colors and Okanvil.Colors.accent or { 0.75, 0.58, 0.23 }

	-- UNIFIED layout: raider and ML share the same look (boss pager, item box,
	-- rolls box, "Your roll"). The ML additionally gets the management controls
	-- (Start roll MS/OS/Free/Stop + Award/Clear). Raider just watches + rolls.
	local M = 12
	local INNER = WIN_W - M * 2
	local y = -6

	-- boss pager header:  <  Boss Name (1/3)  >
	local prev = keep(W.Button(body, "<")); prev:SetSize(24, 22); prev:SetPoint("TOPLEFT", M, y)
	prev:SetScript("OnClick", function()
		f.bossIdx = math.max(1, (f.bossIdx or 1) - 1); selected = nil; RM.Refresh()
	end)
	local bossHd = keep(W.Text(body, "", 13, "accent")); bossHd:Color(1, 0.82, 0)
	bossHd:SetPoint("LEFT", prev, "RIGHT", 6, 0); bossHd:SetPoint("RIGHT", -M - 28, 0); bossHd:SetJustifyH("CENTER")
	if bossHd.SetWordWrap then bossHd:SetWordWrap(false) end
	f.bossHd = bossHd
	local nxt = keep(W.Button(body, ">")); nxt:SetSize(24, 22); nxt:SetPoint("TOPRIGHT", -M, y)
	nxt:SetScript("OnClick", function()
		f.bossIdx = math.min(f.bossCount or 1, (f.bossIdx or 1) + 1); selected = nil; RM.Refresh()
	end)
	y = y - 28

	-- item box (this boss's items) -------------------------------------------
	local LIST_H = ITEM_ROWS * ROW_H
	local ibox = keep(W.Frame(body, "dark")); ibox:SetPoint("TOPLEFT", M, y); ibox:SetSize(INNER, LIST_H + 6)
	f.ibox = ibox
	-- mouse wheel pages the item list (raids drop more than ITEM_ROWS items)
	ibox:EnableMouseWheel(true)
	ibox:SetScript("OnMouseWheel", function(_, delta)
		f.itemScroll = (f.itemScroll or 0) - delta   -- wheel up = earlier items
		RM.Refresh()
	end)
	-- side scrollbar: a thin track on the right edge with a gold thumb whose size +
	-- position reflect how much of the list is shown / where we are. Replaces the
	-- old [+]/[v] end-row hints with a proper scroll indicator. Purely visual here
	-- (the wheel still does the scrolling); RM.Refresh sizes it each rebuild.
	local SB_W = 5
	local track = ibox:CreateTexture(nil, "ARTWORK")
	track:SetPoint("TOPRIGHT", -2, -3); track:SetPoint("BOTTOMRIGHT", -2, 3); track:SetWidth(SB_W)
	track:SetTexture(1, 1, 1, 0.06)   -- faint track
	local thumb = ibox:CreateTexture(nil, "OVERLAY")
	thumb:SetPoint("TOPRIGHT", -2, -3); thumb:SetWidth(SB_W)
	thumb:SetTexture(0.75, 0.58, 0.23, 0.9)   -- gold thumb
	f.sbTrack, f.sbThumb, f.sbW = track, thumb, SB_W
	f.makeItemRow = function(i)
		local r = f.itemRows[i]
		if r then return r end
		r = CreateFrame("Button", nil, ibox)
		-- roll timer bar: the WHOLE ROW is the bar. It fills the row from the left and
		-- shrinks as the Blizzard need/greed timer runs down (a reversed cast bar), so
		-- you can watch the time left to choose. Sits at BACKGROUND, behind text/icon.
		r.bar = r:CreateTexture(nil, "BACKGROUND")
		r.bar:SetPoint("TOPLEFT", 0, 0); r.bar:SetPoint("BOTTOMLEFT", 0, 0)
		r.bar:SetTexture(0.75, 0.58, 0.23, 0.30)   -- gold, translucent
		r.bar:Hide()
		r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(22, 22); r.icon:SetPoint("LEFT", 5, 0)
		r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		r.txt = W.Text(r, "", FONT_SZ); r.txt:SetPoint("LEFT", r.icon, "RIGHT", 6, 0); r.txt:SetPoint("RIGHT", -6, 0); r.txt:SetJustifyH("LEFT")
		if r.txt.SetWordWrap then r.txt:SetWordWrap(false) end
		r.hl = r:CreateTexture(nil, "BORDER"); r.hl:SetAllPoints(); r.hl:SetTexture(0.75, 0.58, 0.23, 0.22); r.hl:Hide()
		r:SetScript("OnEnter", function(s)
			if s._d and s._d.item then GameTooltip:SetOwner(s, "ANCHOR_RIGHT"); GameTooltip:SetHyperlink(s._d.item); GameTooltip:Show() end
		end)
		r:SetScript("OnLeave", function() GameTooltip:Hide() end)
		-- clicking an item SELECTS it -> the Rolls panel below shows that item's
		-- rolls (each person's need/greed). ANYONE can select (the
		-- raider just watches; the ML can also start a roll on the selected item).
		-- Clicking the same item again de-selects.
		r:SetScript("OnClick", function(s)
			if not s._d then return end
			-- toggle: clicking the already-selected item DE-selects. (Don't use the
			-- "a and nil or b" idiom -- nil is falsy in Lua, so "true and nil or s._d"
			-- returns s._d and never de-selected.)
			if selected == s._d then selected = nil else selected = s._d end
			RM.Refresh()
		end)
		f.itemRows[i] = r
		return r
	end
	y = y - (LIST_H + 6) - 10

	-- ML-only: Start Roll row (4 equal buttons) ------------------------------
	if ml then
		local sr = keep(W.Text(body, "Start roll (announces)", 11, "dim")); sr:SetPoint("TOPLEFT", M, y); y = y - 16
		local gap, bw = 6, (INNER - 3 * 6) / 4
		local function srBtn(label, kind, idx, fn)
			local b = keep(W.Button(body, label, kind)); b:SetSize(bw, 26)
			b:SetPoint("TOPLEFT", M + (idx - 1) * (bw + gap), y)
			b:SetScript("OnClick", fn); return b
		end
		local function startSel(mode)
			if not (selected and selected.item) then Okanvil:Print("Pick an item first."); return end
			L.StartRoll(selected.item, mode)
		end
		srBtn("MS", "primary", 1, function() startSel("ms") end)
		srBtn("OS", nil, 2, function() startSel("os") end)
		srBtn("Free", nil, 3, function() startSel("free") end)
		srBtn("Stop", "danger", 4, function() L.StopRoll() end)
		y = y - 32
	end

	-- rolls: state line + list (both modes see the rolls) --------------------
	local rs = keep(W.Text(body, "", 11, "dim")); rs:SetPoint("TOPLEFT", M, y); f.rollState = rs; y = y - 16
	local rl = keep(W.Text(body, ml and "Rolls -- click to pick winner" or "Rolls", 10, "dim")); rl:SetPoint("TOPLEFT", M, y); y = y - 16
	local rbox = keep(W.Frame(body, "dark")); rbox:SetPoint("TOPLEFT", M, y); rbox:SetSize(INNER, ROLL_ROWS * ROW_H + 4)
	for i = 1, ROLL_ROWS do
		local r = CreateFrame("Button", nil, rbox)
		r:SetSize(INNER - 8, ROW_H); r:SetPoint("TOPLEFT", 4, -2 - (i - 1) * ROW_H)
		r.txt = W.Text(r, "", FONT_SZ); r.txt:SetPoint("LEFT", 4, 0); r.txt:SetPoint("RIGHT", -4, 0); r.txt:SetJustifyH("LEFT")
		r.hl = r:CreateTexture(nil, "BACKGROUND"); r.hl:SetAllPoints(); r.hl:SetTexture(0.49, 0.99, 0.54, 0.16); r.hl:Hide()
		-- only ML can award by clicking a roll
		r:SetScript("OnClick", function(s)
			if ml and s._roll and selected then L.AwardWinner(selected.id, s._roll.player, s._roll.roll, s._roll.spec) end
		end)
		f.rollRows[i] = r
	end
	y = y - (ROLL_ROWS * ROW_H + 4) - 10

	-- ML-only: award / clear -------------------------------------------------
	if ml then
		local award = keep(W.Button(body, "Award top roll", "primary")); award:SetSize(INNER - 90, 26); award:SetPoint("TOPLEFT", M, y)
		award:SetScript("OnClick", function()
			local ar = L.ActiveRoll()
			if ar and ar.best and selected then L.AwardWinner(selected.id, ar.best.player, ar.best.roll, ar.best.spec)
			else Okanvil:Print("No rolls yet.") end
		end)
		local clear = keep(W.Button(body, "Clear")); clear:SetSize(82, 26); clear:SetPoint("LEFT", award, "RIGHT", 8, 0)
		clear:SetScript("OnClick", function() selected = nil; L.StopRoll(); RM.Refresh() end)
		y = y - 36

		-- Clear the whole session's loot list (fresh run). Confirms first.
		local wipeBtn = keep(W.Button(body, "Clear session loot", "danger")); wipeBtn:SetSize(INNER, 22); wipeBtn:SetPoint("TOPLEFT", M, y)
		wipeBtn:SetScript("OnClick", function()
			if not StaticPopupDialogs["OKANVIL_ROLL_CLEAR"] then
				StaticPopupDialogs["OKANVIL_ROLL_CLEAR"] = {
					text = "Clear ALL loot from this session's list?\n(Any roll in progress is cancelled.)",
					button1 = YES, button2 = NO,
					OnAccept = function()
						if L.ClearActiveDrops and L.ClearActiveDrops() then
							selected = nil
							Okanvil:Print("Cleared this session's loot.")
						end
						RM.Refresh()
					end,
					timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
				}
			end
			StaticPopup_Show("OKANVIL_ROLL_CLEAR")
		end)
		y = y - 28
	end

	-- Your roll (both modes) -------------------------------------------------
	local yrl = keep(W.Text(body, "Your roll", 11, "dim")); yrl:SetPoint("TOPLEFT", M, y); y = y - 18
	local hw = (INNER - 8) / 2
	local myms = keep(W.Button(body, "Roll MS (100)", "primary")); myms:SetSize(hw, 28); myms:SetPoint("TOPLEFT", M, y)
	myms:SetScript("OnClick", function() L.SelfRoll("ms") end)
	local myos = keep(W.Button(body, "Roll OS (99)")); myos:SetSize(hw, 28); myos:SetPoint("LEFT", myms, "RIGHT", 8, 0)
	myos:SetScript("OnClick", function() L.SelfRoll("os") end)
	y = y - 32
	-- (fragment/BoE collector tally is NOT shown here -- it lives on the Loot page's
	--  COLLECTED panel. The mini manager stays focused on rolling.)
	f.colInfo = nil

	f:SetHeight(52 + (-y) + 8)

	RM.Refresh()
end

-- ------------------------------------------------------------
-- refresh -- paint items, rolls, status from the Loot module's live data
-- ------------------------------------------------------------
function RM.Refresh()
	if not win or not win:IsShown() then return end
	local f = win
	local ml = isML()
	f.status:SetText(ml and "|cff7cfc8aLoot Master|r" or "|cff8a8d93Raider|r")

	local ar = L.ActiveRoll()

	-- per-boss pager: pick the current boss group and list its items (both modes)
	local groups = L.DropsByBoss and L.DropsByBoss() or {}
	f.bossCount = #groups
	if f.bossCount == 0 then
		if f.bossHd then f.bossHd:SetText("|cff8a8d93No loot yet|r") end
		for _, r in ipairs(f.itemRows) do r:Hide() end
		if f.sbThumb then f.sbThumb:Hide(); if f.sbTrack then f.sbTrack:Hide() end end
	else
		-- auto-jump to the newest boss when fresh loot just arrived (a new kill).
		-- DropsByBoss() lists bosses in arrival order, so newest = last.
		if f._jumpNewest then f.bossIdx = f.bossCount; f._jumpNewest = nil end
		f.bossIdx = math.max(1, math.min(f.bossIdx or 1, f.bossCount))
		local g = groups[f.bossIdx]
		if f.bossHd then f.bossHd:SetText(g.boss .. "  |cff8a8d93(" .. f.bossIdx .. "/" .. f.bossCount .. ")|r") end
		-- VALIDAR a seleccao AQUI (antes de desenhar os itens/highlight): o `selected`
		-- so vale se pertence ao boss ATUAL mostrado. Mudar de boss com <> limpa uma
		-- seleccao de outro boss, e o highlight fica sincronizado.
		if selected then
			local inThisBoss = false
			for _, d in ipairs(g.items) do if d == selected then inThisBoss = true; break end end
			if not inThisBoss then selected = nil end
		end
		-- SCROLL: a raid boss drops more than ITEM_ROWS items, so page the list with
		-- the mouse wheel instead of the old "...and N more" dead-end. Clamp the
		-- offset so we never scroll past the last full page.
		local nItems = #g.items
		local maxOff = math.max(0, nItems - ITEM_ROWS)
		f.itemScroll = math.max(0, math.min(f.itemScroll or 0, maxOff))
		local off = f.itemScroll
		for _, r in ipairs(f.itemRows) do r._d = nil; r:Hide() end
		for i = 1, ITEM_ROWS do
			local d = g.items[i + off]
			local r = f.makeItemRow(i)
			-- leave room on the right for the scrollbar (track width + gaps)
			r:ClearAllPoints(); r:SetPoint("TOPLEFT", 4, -2 - (i - 1) * ROW_H); r:SetPoint("RIGHT", f.ibox, "RIGHT", -4 - (f.sbW or 5) - 3, 0); r:SetHeight(ROW_H)
			if d then
				r._d = d
				r.icon:Show(); r.icon:SetTexture(itemIcon(d.item) or "Interface\\Icons\\INV_Misc_QuestionMark")
				-- item name in RARITY color; receiver in CLASS color; both inline so
				-- one string can carry two colors. Long names get truncated with ...
				r.txt:SetTextColor(1, 1, 1)   -- base; inline codes do the coloring
				local cr, cg, cb = rarityColor(d.rarity)
				local rcode = string.format("|cff%02x%02x%02x", cr * 255, cg * 255, cb * 255)
				local nm = d.name ~= "" and d.name or "?"
				local who = ""
				if d.receivedBy and d.receivedBy ~= "" then
					who = "  |cff8a8d93->|r " .. classColorCode(d.receivedBy) .. d.receivedBy .. "|r"
				elseif d.passed then
					who = "  |cff8a8d93(passed)|r"
				end
				-- When there's a winner, truncate the NAME shorter so the "-> winner"
				-- always fits (else long names like "Vambraces of Unholy Command"
				-- pushed the winner off-screen and you couldn't see who won).
				local maxNm = (who ~= "") and 16 or 26
				if #nm > maxNm then nm = nm:sub(1, maxNm - 1) .. ".." end
				-- (the side scrollbar now shows there's more above/below -- no [+]/[v])
				local baseTxt = rcode .. nm .. "|r" .. who
				r.hl:SetShown(selected == d)
				-- roll timer bar (ElvUI-style): show while a roll is live for this item
				-- and not yet won. Live = a native need/greed roll (d.rollID) OR the
				-- time-based fallback (d.rollStart). Master loot has neither, so no bar.
				-- The row's OnUpdate shrinks it each frame + animates "rolling".
				if (d.rollID or d.rollStart) and not d.receivedBy then
					r.bar:Show()
					r.bar:SetWidth(r:GetWidth())   -- start full; OnUpdate shrinks it
					r.bar:SetTexture(cr * 0.6, cg * 0.6, cb * 0.6, 0.30)  -- tinted by rarity
					r._rolling = true
					r._baseTxt = baseTxt           -- OnUpdate appends " - rolling ..."
				else
					r.bar:Hide()
					r._rolling = false
				end
				r.txt:SetText(baseTxt)
				r:Show()
			else
				r._d = nil; r:Hide()
			end
		end

		-- size + place the side scrollbar thumb from the scroll position. Thumb
		-- height = (visible / total) of the track; thumb top slides with `off`.
		if f.sbThumb and f.sbTrack then
			if nItems <= ITEM_ROWS then
				f.sbThumb:Hide(); f.sbTrack:Hide()   -- everything fits -> no bar
			else
				f.sbTrack:Show(); f.sbThumb:Show()
				local trackH = ITEM_ROWS * ROW_H       -- usable track height (approx)
				local thumbH = math.max(16, trackH * (ITEM_ROWS / nItems))
				local frac = (maxOff > 0) and (off / maxOff) or 0
				local yOff = -3 - frac * (trackH - thumbH)
				f.sbThumb:SetHeight(thumbH)
				f.sbThumb:ClearAllPoints()
				f.sbThumb:SetPoint("TOPRIGHT", f.ibox, "TOPRIGHT", -2, yOff)
				f.sbThumb:SetWidth(f.sbW or 5)
			end
		end
	end

	-- (the selection was already validated against the current boss above, before drawing
	-- the items -- so here `selected` is already valid or nil.)

	-- The bottom panel (state + rolls) only shows something when an item is SELECTED.
	-- No selection = empty (we don't auto-pick any item). "only when I select".
	local rollItem = selected

	-- roll state line
	if f.rollState then
		if rollItem then
			local nm = (rollItem.name ~= "" and rollItem.name) or "item"
			local won = ""
			if rollItem.receivedBy and rollItem.receivedBy ~= "" then
				won = "  |cff8a8d93won by|r " .. classColorCode(rollItem.receivedBy) .. rollItem.receivedBy .. "|r"
			elseif rollItem.passed then
				won = "  |cff8a8d93(all passed)|r"
			end
			f.rollState:SetText("|cffffd200" .. nm .. "|r" .. won)
		elseif ar then
			f.rollState:SetText("|cffffd200Rolling...|r")
		else
			f.rollState:SetText("|cff5e6166Click an item to see its rolls.|r")
		end
	end

	-- ROLLS of the selected item (native need/greed in dp.rolls), OR the MANUAL roll
	-- (activeRoll) if no item is selected but a /roll is in progress.
	local sorted, best = {}, nil
	local selRolls = rollItem and rollItem.rolls
	local showingItemRolls = false
	if selRolls and #selRolls > 0 then
		-- item need/greed: need > greed > de; within a type, higher roll first.
		local rank = { need = 3, greed = 2, de = 1 }
		for _, e in ipairs(selRolls) do sorted[#sorted + 1] = e end
		table.sort(sorted, function(a, b)
			local ra, rb = rank[a.kind] or 0, rank[b.kind] or 0
			if ra ~= rb then return ra > rb end
			return (a.roll or 0) > (b.roll or 0)
		end)
		best = sorted[1]
		showingItemRolls = true
	elseif rollItem then
		-- item selected but NO rolls yet -> empty list (don't fall to the manual
		-- roll). showingItemRolls stays true so we show the right header.
		showingItemRolls = true
	else
		-- nothing selected and nothing rolling -> MANUAL roll (activeRoll).
		local list = (ar and ar.list) or {}
		for _, e in ipairs(list) do sorted[#sorted + 1] = e end
		table.sort(sorted, function(a, b)
			if a.spec ~= b.spec then return a.spec == "main" end
			return a.roll > b.roll
		end)
		best = ar and ar.best
	end
	for i = 1, ROLL_ROWS do
		local r, e = f.rollRows[i], sorted[i]
		if e then
			r._roll = e
			-- tag: spec (manual) OR need/greed/de type (native)
			local tag = ""
			if e.kind == "greed" then tag = " |cff8a8d93(greed)|r"
			elseif e.kind == "de" then tag = " |cff8a5ad9(DE)|r"
			elseif e.kind == "need" then tag = " |cff7cfc8a(need)|r"
			elseif e.spec == "off" then tag = " |cff8a5ad9(off)|r" end
			local isBest = best and best.player == e.player and (best.roll == e.roll)
			local mark = isBest and "|cff7cfc8a> |r" or "  "
			r.txt:SetText(mark .. classColorCode(e.player) .. e.player .. "|r  |cffffd200" .. (e.roll or 0) .. "|r" .. tag)
			r.hl:SetShown(isBest)
			r:Show()
		elseif i == 1 and showingItemRolls then
			-- selected item with no captured rolls (e.g. master loot, or still
			-- ongoing with nobody having rolled) -> a note instead of an empty panel.
			r._roll = nil
			r.txt:SetText("|cff5e6166   (no rolls captured for this item)|r")
			r.hl:Hide(); r:Show()
		else
			r._roll = nil; r:Hide()
		end
	end

	-- (collector tally intentionally not shown here -- it's on the Loot page)
end

-- pending "jump to the newest boss" request. Kept at MODULE scope (not on the
-- maybe-nil `win` frame) so a loot event that arrives BEFORE the window is ever
-- built is not lost -- showWin() applies it once the frame exists. This is what
-- makes the pager auto-advance to boss 2's loot instead of staying on boss 1.
local pendingJumpNewest = false

-- show the window (building + rebuilding the mode-specific body)
local function showWin()
	buildWindow()
	if pendingJumpNewest then win._jumpNewest = true; pendingJumpNewest = false end
	win:Show()                       -- always show (idempotent)
	win:Raise()                      -- bring to front in case something covers it
	local ok, err = pcall(RM.Rebuild)  -- never let a rebuild error leave it half-open
	if not ok then Okanvil:Print("|cffff5555Roll rebuild error:|r " .. tostring(err)) end
	if OkanvilLootDebug and L and L.Dbg then
		local p, _, _, x, y = win:GetPoint(1)
		L.Dbg("  showWin: visible=" .. tostring(win:IsVisible())
			.. " shown=" .. tostring(win:IsShown())
			.. " strata=" .. tostring(win:GetFrameStrata())
			.. " alpha=" .. string.format("%.2f", win:GetAlpha())
			.. " @ " .. tostring(p) .. " " .. tostring(math.floor(x or 0)) .. "," .. tostring(math.floor(y or 0)))
	end
end

-- We auto-pop when boss loot drops in the CURRENT run (we never resurrect a stale
-- session from a dungeon left hours ago -- that's the InLiveRun / current-drops gate).
-- We auto-pop when either we're inside a live run OR the Loot module actually has
-- drops for the current session right now. The InLiveRun() check alone raced with
-- zoning (loot could fire a hair before IsInInstance/ShouldRecord settled), which
-- swallowed the very first boss's auto-show. If real loot just landed, show it.
local function haveCurrentDrops()
	local g = Okanvil.Loot and Okanvil.Loot.DropsByBoss and Okanvil.Loot.DropsByBoss()
	return g and #g > 0
end
local function canAutoShow()
	if not db().autoShow then return false end
	if Okanvil.Loot and Okanvil.Loot.InLiveRun and Okanvil.Loot.InLiveRun() then return true end
	return haveCurrentDrops()
end

-- shared handler: request a jump to the newest boss, then show/refresh. The jump
-- flag lives at module scope so it survives even if `win` isn't built yet.
-- `force` = we KNOW a loot window is open in front of us (the LOOT_OPENED trigger,
-- RaidRoll/RCLootCouncil style) so show regardless of the InLiveRun timing race.
local function popOrRefresh(force)
	local dbg = OkanvilLootDebug and L and L.Dbg
	if dbg then
		L.Dbg("  |cffccccffpopOrRefresh|r force=" .. tostring(force)
			.. " shown=" .. tostring(win and win:IsShown())
			.. " autoShow=" .. tostring(db().autoShow)
			.. " canAuto=" .. tostring(canAutoShow()))
	end
	if win and win:IsShown() then
		-- only jump to the newest boss when this is a FORCED pop (NEW loot
		-- coming in, force=true). A normal refresh (e.g. winner filled, roll
		-- captured) must NOT change the page you're viewing -- just redraws.
		if force then win._jumpNewest = true; pendingJumpNewest = false end
		RM.Refresh()
		if dbg then L.Dbg("  => refresh (already shown)") end
	elseif (force and db().autoShow) or canAutoShow() then
		pendingJumpNewest = true; showWin()        -- eligible (or forced) -> build, show, then jump
		if dbg then L.Dbg("  => |cff7cfc8aSHOW|r") end
	else
		pendingJumpNewest = true                    -- hidden + not eligible -> remember for next open
		if dbg then L.Dbg("  => |cffff5555NOT shown|r (not eligible)") end
	end
end
local function onLoot() popOrRefresh(false) end

-- also pop for a raider when a roll opens (so they see the Roll MS/OS buttons).
function RM.OnRollOpen() popOrRefresh(false) end

-- a loot window just opened with items in front of us -> always pop (forced).
function RM.OnLootWindow() popOrRefresh(true) end

function RM.Toggle()
	local ok, err = pcall(function()
		if win and win:IsShown() then
			win:Hide()
		else
			showWin()
		end
	end)
	if not ok then
		Okanvil:Print("|cffff5555Roll manager error:|r " .. tostring(err))
		-- recover: force a clean show so a transient error can't wedge it closed
		if win then pcall(function() win:Show(); RM.Rebuild() end) end
	end
end

-- ------------------------------------------------------------
-- boot: hook the Loot module's callbacks + register a slash
-- ------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function()
	if not Okanvil.Loot then return end
	L = Okanvil.Loot
	-- chain onto Loot's callbacks without clobbering them
	local prevLoot = L.onLoot
	L.onLoot = function() if prevLoot then prevLoot() end; onLoot() end
	L.onRoll = function() RM.OnRollOpen() end
	-- fired the instant a loot window opens with items (RaidRoll / RCLootCouncil
	-- model) -- pop the mini roll even if the item is filtered from recording, and
	-- regardless of the InLiveRun timing race (we KNOW a corpse is open).
	local prevWin = L.onLootWindow
	L.onLootWindow = function() if prevWin then prevWin() end; RM.OnLootWindow() end
end)

SLASH_OKROLL1 = "/okroll"
SlashCmdList["OKROLL"] = function() RM.Toggle() end
