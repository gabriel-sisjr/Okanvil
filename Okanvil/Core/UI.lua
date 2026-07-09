-- ============================================================
-- Okanvil -- UI shell: resizable window with a left nav, a clipped
-- scrolling content well, a Home page and a built-in Settings tab.
-- Built on Okanvil.W (Widgets.lua). Every panel lives inside a scrolling
-- child frame, so plugin widgets stay bounded by the content well and
-- never spill past the window edge -- the MRT structure the guild liked.
-- ============================================================

local Okanvil = Okanvil
local W = Okanvil.W
local C = Okanvil.Colors
local LSM = Okanvil.LSM
local FLAT = "Interface\\ChatFrame\\ChatFrameBackground"
local function u3(t, a) return t[1], t[2], t[3], a or 1 end

Okanvil.panels = {}       -- key -> { panel, scroll, child }
Okanvil._navButtons = {}
local HOME, GUILD, LOOT, INVITE, MODULES, SETTINGS = "__home", "__guild", "__loot", "__invite", "__modules", "__settings"

-- FIXED window size (MRT-style): the window is NOT resizable -- a hand-tuned size
-- that always looks right. Users make it bigger/smaller with the Scale slider in
-- Settings (proportional, never breaks the layout). Resizing from offsets was
-- fragile and could break the UI, so we dropped it entirely.
local WIN_W, WIN_H = 940, 660
local NAV_W = 190
local HEADER_H = 30
local FOOTER_H = 22

-- ------------------------------------------------------------
-- Nav entry (icon + label + active bar)
-- ------------------------------------------------------------
local function makeNavEntry(parent)
	local b = CreateFrame("Button", nil, parent)
	b:SetHeight(24)
	local hl = b:CreateTexture(nil, "BACKGROUND")
	hl:SetAllPoints(); hl:SetTexture(FLAT); hl:SetVertexColor(0, 0, 0, 0)
	b.hl = hl
	local bar = b:CreateTexture(nil, "ARTWORK")   -- left accent bar when active
	bar:SetPoint("TOPLEFT"); bar:SetPoint("BOTTOMLEFT"); bar:SetWidth(2)
	bar:SetTexture(FLAT); bar:SetVertexColor(u3(C.accent)); bar:Hide()
	b.bar = bar
	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetSize(15, 15); b.icon:SetPoint("LEFT", 8, 0)
	b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	b.text = W.Text(b); b.text:SetPoint("LEFT", b.icon, "RIGHT", 7, 0); b.text:SetJustifyH("LEFT")
	b:SetScript("OnEnter", function(s) if not s._active then s.hl:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 0.08) end end)
	b:SetScript("OnLeave", function(s) if not s._active then s.hl:SetVertexColor(0, 0, 0, 0) end end)
	return b
end

-- ------------------------------------------------------------
-- Shell (window)
-- ------------------------------------------------------------
function Okanvil:BuildShell()
	if self.win then return end
	local db = self.db

	local f = CreateFrame("Frame", "Okanvil_Window", UIParent)
	f:SetSize(WIN_W, WIN_H)          -- FIXED size (not resizable) -- use Scale to grow
	f:SetPoint(db.window.point, UIParent, db.window.point, db.window.x, db.window.y)
	f:SetScale(db.scale or 1)
	f:SetFrameStrata("HIGH")
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:SetResizable(false)            -- no drag-resize: it broke layouts. Scale instead.
	self:Skin(f)
	self.win = f
	-- ESC closes the window: register it as a special frame (WoW hides frames in
	-- UISpecialFrames when Escape is pressed). Uses the frame's global name.
	tinsert(UISpecialFrames, "Okanvil_Window")
	-- SAFETY: closing the window must release any keyboard focus, so a text box can
	-- never keep eating W/A/S/D after you close the addon.
	f:HookScript("OnHide", function() Okanvil:ClearAllFocus() end)
	-- Clicking a bare area of the window drops focus where it can (a focused 3.3.5a
	-- EditBox captures input, so this won't fire in every case -- ESC and closing
	-- the window are the reliable releases).
	f:SetScript("OnMouseDown", function() Okanvil:ClearAllFocus() end)

	-- header (drag)
	local hdr = W.Frame(f, "raise")
	hdr:SetPoint("TOPLEFT", 1, -1); hdr:SetPoint("TOPRIGHT", -1, -1); hdr:SetHeight(HEADER_H)
	hdr:EnableMouse(true); hdr:RegisterForDrag("LeftButton")
	hdr:SetScript("OnMouseDown", function() Okanvil:ClearAllFocus() end)  -- click header = stop typing
	hdr:SetScript("OnDragStart", function() f:StartMoving() end)
	hdr:SetScript("OnDragStop", function()
		f:StopMovingOrSizing()
		local p, _, _, x, y = f:GetPoint(1)
		db.window.point, db.window.x, db.window.y = p, x, y
	end)

	-- ---- product wordmark: [anvil] Okanvil ("OK Anvil" pun lives in the word) ----
	-- The product name is FIXED (Okanvil, by Okanor); only the guild skin (db.brand)
	-- is editable -- shown as a separate suffix, MRT-style. Title/version must be
	-- children of the HEADER (not the window) so they draw ABOVE its raised backdrop.
	local logo = hdr:CreateTexture(nil, "OVERLAY")
	logo:SetSize(18, 18); logo:SetPoint("LEFT", 9, 0)
	logo:SetTexture("Interface\\Icons\\Trade_BlackSmithing")   -- the anvil
	logo:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	local title = W.Text(hdr, "Okanvil", 16, "accent")
	title:SetPoint("LEFT", logo, "RIGHT", 7, 0); title:Color(1, 0.82, 0)
	local ver = W.Text(hdr, "v" .. (self.version or "1.0"), 10, "dim")
	ver:SetPoint("LEFT", title, "RIGHT", 6, -1)
	-- guild skin (editable) sits after the version as a dimmer suffix
	local brandFS = W.Text(hdr, "", 13, "dim")
	brandFS:SetPoint("LEFT", ver, "RIGHT", 8, 1)
	local function paintBrand()
		local b = db.brand or ""
		if b == "" or b == "Okanvil" then brandFS:SetText("") -- no guild skin set
		else brandFS:SetText("|cff8a8d93\194\183  " .. b .. "|r") end -- "· <guild>"
	end
	paintBrand()
	self.headerPaintBrand = paintBrand

	local close = W.Button(hdr, "X"); close:SetSize(24, 20); close:SetPoint("RIGHT", -3, 0)
	close:SetScript("OnClick", function() f:Hide() end)
	-- collapse to a small anvil icon (WeakAuras-style): hides the big window and
	-- shows a draggable puck so you can watch your game; click the puck to restore.
	local collapse = W.Button(hdr, "_"); collapse:SetSize(24, 20); collapse:SetPoint("RIGHT", close, "LEFT", -3, 0)
	collapse:SetScript("OnClick", function() Okanvil:Collapse(true) end)

	-- left nav
	local nav = W.Frame(f, "dark")
	nav:SetPoint("TOPLEFT", 6, -(HEADER_H + 6))
	nav:SetPoint("BOTTOMLEFT", 6, FOOTER_H + 4)
	nav:SetWidth(NAV_W)
	local navHdr = W.Text(nav, "NAVIGATION", 10, "dim"); navHdr:SetPoint("TOPLEFT", 10, -8)
	local navSF = CreateFrame("ScrollFrame", "Okanvil_NavSF", nav)
	navSF:SetPoint("TOPLEFT", 4, -24); navSF:SetPoint("BOTTOMRIGHT", -6, 4)
	Okanvil.Clip(navSF)
	local navChild = CreateFrame("Frame", nil, navSF)
	navChild:SetSize(NAV_W - 12, 1); navSF:SetScrollChild(navChild)
	navSF:EnableMouseWheel(true)
	navSF:SetScript("OnMouseWheel", function(s, d)
		local cur = s:GetVerticalScroll()
		local maxS = math.max(0, navChild:GetHeight() - s:GetHeight())
		s:SetVerticalScroll(math.min(maxS, math.max(0, cur - d * 24)))
	end)
	self.navChild = navChild

	-- content well
	local content = W.Frame(f, "dark")
	content:SetPoint("TOPLEFT", nav, "TOPRIGHT", 6, 0)
	content:SetPoint("BOTTOMRIGHT", -6, FOOTER_H + 4)
	self.content = content
	-- ONE shared rat behind every page (single mount; see MountPageRat).
	self:MountPageRat()

	-- footer: fixed author credit (Okanvil is by Okanor) + a flavor line
	local footer = W.Text(f, "|cffe0b860Okanvil by Okanor|r  |cff55575b--  the void in your stack trace|r", 10, "dim")
	footer:SetPoint("BOTTOMLEFT", 10, 6)
	-- web-hub link in the footer (WeakAuras-style): click -> copyable URL popup.
	local hubBtn = CreateFrame("Button", nil, f)
	hubBtn:SetHeight(14); hubBtn:SetPoint("BOTTOM", 0, 6)
	local hubTxt = W.Text(hubBtn, "", 10, "accent"); hubTxt:SetAllPoints(); hubTxt:SetJustifyH("CENTER")
	hubBtn.text = hubTxt
	self.footerHub = hubBtn
	local function paintHub()
		hubTxt:SetText("|cffe0b860Web Hub:|r |cff8a8d93" .. (self.db.hubURL or "") .. "|r")
		hubBtn:SetWidth(hubTxt:GetStringWidth() + 8)
	end
	paintHub(); self.footerPaintHub = paintHub
	hubBtn:SetScript("OnEnter", function() hubTxt:SetText("|cffffd200Web Hub:|r |cffffffff" .. (self.db.hubURL or "") .. "|r") end)
	hubBtn:SetScript("OnLeave", paintHub)
	hubBtn:SetScript("OnClick", function()
		if Okanvil.ShowExport then Okanvil:ShowExport(self.db.hubURL or "", "Web Hub -- Ctrl+C to copy") end
	end)
	self.footerCount = W.Text(f, "", 10, "dim")
	self.footerCount:SetPoint("BOTTOMRIGHT", -20, 6)

	-- (No resize grip: the window is fixed-size. Grow it with the Scale slider in
	-- Settings -- proportional and layout-safe.)

	self:RefreshNav()
	self:ShowPanel(HOME)
	f:Hide()
end

-- ------------------------------------------------------------
-- Collapse to a small draggable anvil puck (WeakAuras-style). Lets you watch the
-- game without the big window; click the puck to restore. The puck position is
-- saved so it stays where you left it.
-- ------------------------------------------------------------
function Okanvil:BuildPuck()
	if self.puck then return self.puck end
	local db = self.db
	db.puck = db.puck or { point = "CENTER", x = 0, y = 0 }
	local p = CreateFrame("Button", "Okanvil_Puck", UIParent)
	p:SetSize(48, 48)
	p:SetPoint(db.puck.point, UIParent, db.puck.point, db.puck.x, db.puck.y)
	p:SetFrameStrata("FULLSCREEN_DIALOG"); p:SetFrameLevel(200); p:SetToplevel(true)
	-- skin via SetBackdrop directly (safer on a Button than :Skin)
	p:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1,
		insets = { left = 1, right = 1, top = 1, bottom = 1 } })
	p:SetBackdropColor(u3(C.panelHi)); p:SetBackdropBorderColor(u3(C.accent))
	local ic = p:CreateTexture(nil, "ARTWORK")
	ic:SetPoint("TOPLEFT", 4, -4); ic:SetPoint("BOTTOMRIGHT", -4, 4)
	ic:SetTexture("Interface\\Icons\\Trade_BlackSmithing"); ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	p:SetMovable(true); p:EnableMouse(true); p:RegisterForDrag("LeftButton")
	p:SetScript("OnDragStart", p.StartMoving)
	p:SetScript("OnDragStop", function(s)
		s:StopMovingOrSizing()
		local pt, _, _, x, y = s:GetPoint(1)
		db.puck.point, db.puck.x, db.puck.y = pt, x, y
	end)
	p:SetScript("OnClick", function() Okanvil:Collapse(false) end)
	p:SetScript("OnEnter", function(s)
		GameTooltip:SetOwner(s, "ANCHOR_LEFT")
		GameTooltip:AddLine("|cffffd200Okanvil|r")
		GameTooltip:AddLine("Click: open   ·   Drag: move", 1, 1, 1)
		GameTooltip:Show()
	end)
	p:SetScript("OnLeave", function() GameTooltip:Hide() end)
	p:Hide()
	self.puck = p
	return p
end

-- collapse(true) -> hide window, show puck. collapse(false) -> restore window.
function Okanvil:Collapse(on)
	local ok, err = pcall(function() self:BuildPuck() end)
	if not ok or not self.puck then
		-- puck failed to build -> DON'T hide the window (that would look like "close")
		self:Print("|cffff5555Collapse error:|r " .. tostring(err))
		return
	end
	if on then
		if self.win then self.win:Hide() end
		self.puck:Show()
		self.puck:Raise()
		self:Print("collapsed -- click the anvil puck (screen center) to reopen, or /okanvil")
	else
		self.puck:Hide()
		if self.win then self.win:Show() end
	end
end

-- ------------------------------------------------------------
-- Nav list
-- ------------------------------------------------------------
-- Every module -- Recruit/IDs/Logs/RaidFinder/Guild/Invite/Loot/LootRoll -- registers
-- the same way: it fills Okanvil_Plugins[key] and calls Okanvil:Register(key), landing
-- in self.entries. There is no more native-vs-plugin distinction; Home/Modules/Settings
-- are the fixed "core" shell pages and are never toggleable.
-- One coherent icon set (all verified 3.3.5a paths). Keep the nav icon and the
-- module's Dashboard header icon the SAME so the two never look mismatched.
Okanvil.ICONS = {
	home    = "Interface\\Icons\\INV_Misc_Rune_01",
	invite  = "Interface\\Icons\\Spell_ChargePositive",
	guild   = "Interface\\Icons\\INV_Shirt_GuildTabard_01",
	loot    = "Interface\\Icons\\INV_Misc_Coin_02",
	lootroll= "Interface\\Icons\\INV_Misc_Dice_01",
	logs    = "Interface\\Icons\\INV_Scroll_03",
	ids     = "Interface\\Icons\\INV_Misc_Spyglass_02",
	recruit = "Interface\\Icons\\Achievement_General_StayClassy",
	modules = "Interface\\Icons\\INV_Misc_Gear_01",
	settings= "Interface\\Icons\\Trade_Engineering",
}

-- Nav display order (top to bottom), by module TITLE. This is the ONE place to
-- set where a module sits in the menu -- add a new feature's title here at the
-- index you want. Home is always first; Modules + Settings are always last.
-- Anything enabled but NOT listed here falls to the end (alphabetical).
Okanvil.NAV_ORDER = { "Guild", "Invite", "Recruit", "Raid Finder", "Loot", "ID Finder", "Combat Logs" }

function Okanvil:RefreshNav()
	if not self.navChild then return end
	for _, b in ipairs(self._navButtons) do b:Hide() end

	local list = {
		{ key = HOME, title = "Home", icon = self.ICONS.home },
	}

	-- Gather every enabled module (native + plugins) into one pool keyed by title,
	-- then emit them in a FIXED display order. Anything not in NAV_ORDER falls to
	-- the end (alphabetical) so a new plugin still shows up.
	local pool = {}
	for name in pairs(self.entries) do
		if self:IsModuleEnabled(name) then
			local t = self.entries[name].title or name
			pool[t] = { key = name, title = t, icon = self.entries[name].icon }
		end
	end

	-- emit in the master order (Okanvil.NAV_ORDER -- edit that to reorder / place
	-- a new feature). Missing / disabled entries are simply skipped.
	local emitted = {}
	for _, title in ipairs(self.NAV_ORDER) do
		if pool[title] then list[#list + 1] = pool[title]; emitted[title] = true end
	end
	-- any enabled module not named in NAV_ORDER (future plugins), alphabetical
	local leftover = {}
	for title in pairs(pool) do if not emitted[title] then leftover[#leftover + 1] = title end end
	table.sort(leftover)
	for _, title in ipairs(leftover) do list[#list + 1] = pool[title] end

	list[#list + 1] = { key = MODULES, title = "Modules", icon = self.ICONS.modules }
	list[#list + 1] = { key = SETTINGS, title = "Settings", icon = self.ICONS.settings }

	local y = 0
	for i, item in ipairs(list) do
		local b = self._navButtons[i] or makeNavEntry(self.navChild)
		self._navButtons[i] = b
		b:ClearAllPoints(); b:SetPoint("TOPLEFT", 0, -y); b:SetPoint("TOPRIGHT", 0, -y)
		b.text:SetText(item.title)
		if item.icon then b.icon:SetTexture(item.icon); b.icon:Show() else b.icon:Hide() end
		b._key = item.key
		b:SetScript("OnClick", function() Okanvil:ShowPanel(item.key) end)
		b:Show()
		y = y + 26
	end
	self.navChild:SetHeight(math.max(1, y))
	if self.footerCount then
		-- count = registered modules (plugins)
		local total, on = 0, 0
		for name in pairs(self.entries) do
			total = total + 1
			if self:IsModuleEnabled(name) then on = on + 1 end
		end
		self.footerCount:SetText(on .. "/" .. total .. " modules on")
	end
end

-- ------------------------------------------------------------
-- Panels. Two shapes:
--   newFillPanel()   -> a frame that FILLS the content well (real
--                       BOTTOMRIGHT). Plugins draw into `.child` here;
--                       they anchor their own widgets/scrollframes to it,
--                       exactly as they were written. This is what stops
--                       Recruit/IDs/etc collapsing.
--   newScrollPanel() -> internal scrolling area for the shell's own long
--                       pages (Home, Settings).
-- Both expose `.child` (draw target) and `.relayout()`.
-- ------------------------------------------------------------
-- Shared "rat art" watermark -- ONE faded image in the content's bottom-right
-- corner, shown on every page. WoW 3.3.5a draws only BLP (DXT5) shipped in the
-- addon -> Media\rat1.blp (the Okanor blacksmith). db.ratArt "off" hides it.
-- Mounted once on Okanvil.content's ARTWORK layer (see MountPageRat), behind the
-- transparent "page" panels, so it is ALWAYS visible -- independent of panel
-- opacity, via its own db.ratAlpha slider -- and never duplicated.
-- ------------------------------------------------------------
local RAT_TEX = "Interface\\AddOns\\Okanvil\\Media\\rat1"
local function applyRatTex(tex)
	tex:SetTexture(RAT_TEX); tex:SetTexCoord(0, 1, 0, 1)
end

-- ONE rat, once, on the shared content well -- NOT per panel.
--
-- Old design mounted a rat on every panel (main + drawer + each scroll/fill
-- wrap), so a page with a drawer + inner scrolls showed 2-3 rats, each pinned to
-- its OWN corner => duplicated + misaligned art, plus a stray small one in list
-- columns. We now mount a SINGLE texture on `Okanvil.content` (the frame that
-- hosts every page), on its ARTWORK layer -- above content's own dark fill but
-- below the page panels, which are the transparent "page" skin -- so this one
-- rat reads as a true, uniform background behind every page and NEVER moves.
-- Its intensity is db.ratAlpha (its own Settings slider), so it stays visible
-- even at full panel opacity (the old rat lived under opaque panels and vanished
-- when bgAlpha hit 1).
function Okanvil:MountPageRat()
	if self._pageRat then return self._pageRat end
	local host = self.content
	if not host then return end
	-- Single texture on the content well's ARTWORK layer -- ABOVE content's own
	-- dark BACKGROUND fill, but BELOW the page panels (which are now transparent,
	-- see the "page" skin) so it reads as a true background behind the content.
	-- One draw, fixed corner, never duplicated. Intensity = db.ratAlpha (its own
	-- Settings slider, independent of the panel opacity slider).
	local art = host:CreateTexture(nil, "ARTWORK")
	art:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -10, 10)
	local function refresh()
		if (Okanvil.db.ratArt or "on") == "off" then art:Hide(); return end
		applyRatTex(art)
		art:SetAlpha(Okanvil.db.ratAlpha or 0.30)
		local vw, vh = host:GetWidth() or 700, host:GetHeight() or 500
		local s = math.max(220, math.min(vh * 0.62, vw * 0.46))
		art:SetSize(s, s); art:Show()
	end
	art.refresh = refresh
	host:HookScript("OnSizeChanged", refresh)
	host:HookScript("OnShow", refresh)
	refresh()
	self._pageRat = art
	return art
end

-- refresh the single page rat (called from Settings when opacity/toggle changes).
function Okanvil:RefreshRatArt()
	if self._pageRat and self._pageRat.refresh then self._pageRat.refresh() end
end

local function newFillPanel()
	local wrap = CreateFrame("Frame", nil, Okanvil.content)
	wrap:SetPoint("TOPLEFT", 2, -2); wrap:SetPoint("BOTTOMRIGHT", -2, 2)
	wrap:Hide()
	wrap.child = wrap                 -- plugins anchor straight to the panel
	wrap.relayout = function() end
	-- (rat art is a single shared overlay on content -- no per-panel mount)
	return wrap
end

local function newScrollPanel()
	local wrap = CreateFrame("Frame", nil, Okanvil.content)
	wrap:SetPoint("TOPLEFT", 2, -2); wrap:SetPoint("BOTTOMRIGHT", -2, 2)
	wrap:Hide()

	local sf = CreateFrame("ScrollFrame", nil, wrap)
	sf:SetPoint("TOPLEFT", 4, -4); sf:SetPoint("BOTTOMRIGHT", -8, 4)
	Okanvil.Clip(sf)
	local child = CreateFrame("Frame", nil, sf)
	child:SetSize(10, 10); sf:SetScrollChild(child)

	local sb = CreateFrame("Slider", nil, wrap)
	sb:SetPoint("TOPRIGHT", -3, -4); sb:SetPoint("BOTTOMRIGHT", -3, 4); sb:SetWidth(4)
	sb:SetOrientation("VERTICAL"); sb:SetValueStep(1)
	local th = sb:CreateTexture(nil, "OVERLAY"); th:SetTexture(FLAT); th:SetVertexColor(u3(C.accent)); th:SetSize(4, 40)
	sb:SetThumbTexture(th)
	sb:SetScript("OnValueChanged", function(_, v) sf:SetVerticalScroll(v) end)
	sf:EnableMouseWheel(true)
	sf:SetScript("OnMouseWheel", function(_, d) sb:SetValue(sb:GetValue() - d * 24) end)

	local function relayout()
		child:SetWidth(sf:GetWidth())
		local maxS = math.max(0, child:GetHeight() - sf:GetHeight())
		sb:SetMinMaxValues(0, maxS)
		sb:SetShown(maxS > 0)
	end
	sf:SetScript("OnSizeChanged", relayout)
	wrap.scroll, wrap.child, wrap.relayout = sf, child, relayout
	-- (rat art is a single shared overlay on content -- no per-panel mount)
	return wrap
end

function Okanvil:ShowPanel(key)
	self:CloseDropdown()
	self:ClearAllFocus()          -- switching pages releases any text-box focus
	for _, b in ipairs(self._navButtons) do
		b._active = (b._key == key)
		if b._active then b.hl:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 0.10); b.bar:Show()
		else b.hl:SetVertexColor(0, 0, 0, 0); b.bar:Hide() end
	end

	local entry = self.panels[key]
	if not entry then
		if key == HOME then entry = self:BuildHome()
		elseif key == MODULES then entry = self:BuildModules()
		elseif key == SETTINGS then entry = self:BuildSettings()
		else
			local plug = self.entries[key]
			if plug and plug.build then
				entry = newFillPanel()
				plug.build(entry.child)   -- plugin draws into a full-size panel
			end
		end
		self.panels[key] = entry
	end

	for _, e in pairs(self.panels) do if e.Hide then e:Hide() end end
	if entry then
		entry:Show()
		if entry.relayout then entry.relayout() end
		local plug = self.entries[key]
		if plug and plug.refresh then plug.refresh() end
	end
	self._current = key
end

-- ------------------------------------------------------------
-- Home
-- ------------------------------------------------------------
function Okanvil:BuildHome()
	local wrap = newScrollPanel()
	local p = wrap.child
	local X = 16

	-- header: product wordmark (fixed) + guild skin subtitle + version
	-- product wordmark (there's no logo.blp; the text wordmark IS the logo)
	local title = W.Text(p, "Okanvil", 26, "accent"); title:SetPoint("TOPLEFT", X, -20)
	local anchor = title
	-- guild skin (editable) as a subtitle under the product name
	local gb = self.db.brand
	local guildFS
	if gb and gb ~= "" and gb ~= "Okanvil" then
		guildFS = W.Text(p, gb, 14, "accent"); guildFS:Color(0.88, 0.72, 0.38)
		guildFS:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -4)
		anchor = guildFS
	end
	local sub = W.Text(p, "v" .. (self.version or "1.0") .. "  --  raid & guild toolkit by Okanor", 11, "dim")
	sub:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -6)

	-- stat tiles: online / members / your rank. Anchored to the header's bottom
	-- (the `sub` line) so a 2- or 3-line header never overlaps them.
	-- Three identical tiles in one row. All values share the SAME font size and
	-- baseline so numbers and the rank name read as one aligned row (a big "20pt
	-- number" next to a "Warchief Rat" name looked like uneven steps before).
	local TILE_W, TILE_H, VAL_SZ = 150, 48, 17
	local tiles = {}
	local function tile(i, label)
		local t = W.Frame(p, "input")
		t:SetSize(TILE_W, TILE_H)
		if i == 1 then
			t:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", 0, -12)
		else
			t:SetPoint("TOPLEFT", tiles["_t" .. (i - 1)], "TOPRIGHT", 8, 0)
		end
		-- label pinned near the bottom; the value sits just above it, so all three
		-- values line up on the same baseline regardless of number vs name.
		t.lbl = W.Text(t, label, 10, "dim"); t.lbl:SetPoint("BOTTOMLEFT", 12, 8)
		t.num = W.Text(t, "--", VAL_SZ, "accent")
		t.num:SetPoint("BOTTOMLEFT", t.lbl, "TOPLEFT", 0, 5); t.num:SetPoint("RIGHT", t, "RIGHT", -10, 0); t.num:SetJustifyH("LEFT")
		if t.num.SetWordWrap then t.num:SetWordWrap(false) end
		tiles["_t" .. i] = t
		return t
	end
	tiles.online = tile(1, "ONLINE")
	tiles.members = tile(2, "MAINS")
	tiles.rank = tile(3, "YOUR RANK")

	-- guild online card -- a SCROLLABLE row list (shows everyone, not a capped
	-- text blob) with a per-row [inv] button for quick invites from Home.
	-- The online card fills the rest of the page height (Home is a fixed-size
	-- window, so anchoring its bottom to the content area gives many more visible
	-- rows -> far less scrolling). BOTTOMRIGHT is the scroll area's real bottom.
	local gcard = W.Frame(p, "input")
	gcard:SetPoint("TOPLEFT", tiles._t1, "BOTTOMLEFT", 0, -12)
	gcard:SetPoint("RIGHT", p, "RIGHT", -X, 0)
	gcard:SetPoint("BOTTOM", p, "BOTTOM", 0, 12)
	gcard:SetHeight(180)   -- fallback min; the BOTTOM anchor stretches it taller
	local gh = W.Text(gcard, "GUILD ONLINE", 10, "dim"); gh:SetPoint("TOPLEFT", 10, -8)
	-- flat scroll (no Blizzard template): plain ScrollFrame + our own slider
	local gsf = CreateFrame("ScrollFrame", nil, gcard)
	gsf:SetPoint("TOPLEFT", 8, -24); gsf:SetPoint("BOTTOMRIGHT", -12, 6)
	local gchild = CreateFrame("Frame", nil, gsf); gchild:SetSize(10, 1)
	gsf:SetScrollChild(gchild)
	local gsb = CreateFrame("Slider", nil, gcard)
	gsb:SetPoint("TOPRIGHT", -3, -24); gsb:SetPoint("BOTTOMRIGHT", -3, 6); gsb:SetWidth(4)
	gsb:SetOrientation("VERTICAL"); gsb:SetValueStep(1)
	local gth = gsb:CreateTexture(nil, "OVERLAY"); gth:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
	gth:SetSize(4, 30); local ga = Okanvil.Colors.accent; gth:SetVertexColor(ga[1], ga[2], ga[3], 1)
	gsb:SetThumbTexture(gth)
	gsb:SetScript("OnValueChanged", function(_, v) gsf:SetVerticalScroll(v) end)
	gsf:EnableMouseWheel(true)
	gsf:SetScript("OnMouseWheel", function(_, d) gsb:SetValue(gsb:GetValue() - d * 24) end)
	wrap.gsf, wrap.gchild, wrap.gsb, wrap.gRows = gsf, gchild, gsb, {}
	local gempty = W.Text(gcard, "", 12, "dim"); gempty:SetPoint("TOPLEFT", 10, -26)
	wrap.gempty = gempty

	-- (The web-hub link now lives in the window FOOTER, WeakAuras-style -- always
	-- visible, click to copy the URL. No card here anymore.)

	-- (rat art is one shared overlay on Okanvil.content -- nothing to build here.)

	local G = Okanvil.Guild
	local function refreshGuild()
		if not (IsInGuild and IsInGuild()) then
			tiles.online.num:SetText("--"); tiles.members.num:SetText("--"); tiles.rank.num:SetText("--")
			for _, r in ipairs(wrap.gRows) do r:Hide() end
			if wrap.gsb then wrap.gsb:Hide() end
			wrap.gempty:SetText("|cff888888You are not in a guild.|r")
			return
		end
		local online, mains, mine, mineIdx = 0, 0, "--", nil
		local myName = UnitName and UnitName("player")
		local onlineList = {}
		-- rank colour so the online list is scannable at a glance. RATS ladder
		-- (rankIndex 0 = top): Warchief Rat / Warchief's Fangs = officers (red-gold),
		-- Raider Rat = orange, Sewer Rat = yellow, Alt = grey-blue, Pug/other = grey.
		local function rankColor(rankName, rankIndex, alt)
			if alt then return "ff8fb4d9" end            -- alt: muted blue-grey
			local rn = (rankName or ""):lower()
			-- Guild Master / Rat King ("King Rat" / "Rat King") -> purple
			if rankIndex == 0 or rn:find("king", 1, true) then return "ffc659ff" end
			if rn:find("warchief rat", 1, true) then return "ffff4d4d" end   -- Warchief Rat: officer red
			if rn:find("fang", 1, true) then return "ffff8c42" end            -- Warchief's Fangs: orange-red
			if rn:find("raider", 1, true) then return "ffffa030" end          -- Raider Rat: orange
			if rn:find("sewer", 1, true) then return "ffffe049" end           -- Sewer Rat: yellow
			return "ff9aa0a6"                                                  -- Pug / unranked: grey
		end
		for _, m in ipairs(G.Roster()) do
			local alt = G.IsAlt(m.rank, m.rankIndex, m.officernote)
			if not alt then mains = mains + 1 end
			if m.online then
				online = online + 1
				onlineList[#onlineList + 1] = {
					name = m.name, rank = m.rank or "", rankIndex = m.rankIndex, class = m.className,
					col = rankColor(m.rank, m.rankIndex, alt), alt = alt,
					zone = m.zone or "",
					main = alt and G.MainOf(m.note, m.officernote) or nil,
				}
			end
			if m.name == myName then mine = m.rank or "--"; mineIdx = m.rankIndex end
		end
		tiles.online.num:SetText(tostring(online))
		tiles.members.num:SetText(tostring(mains))   -- MAINS only (real people, alts excluded)
		-- your rank, coloured with the SAME rank colour used in the online list. Keep
		-- the shared value size so it lines up with the two numbers; only step down a
		-- point if a very long rank name would clip the tile.
		local myCol = rankColor(mine, mineIdx, false)
		tiles.rank.num._okSize = nil
		tiles.rank.num:SetFont(Okanvil:Font(), (#mine > 12) and (VAL_SZ - 3) or VAL_SZ)
		tiles.rank.num:SetText("|c" .. myCol .. mine .. "|r")

		-- render the online list as scrollable rows, each with a quick [inv] button.
		-- Order: Rat King > Warchief > Raider > Sewer > ... , alts ALWAYS last
		-- (regardless of their own rankIndex), then alphabetical within a tier.
		table.sort(onlineList, function(a, b)
			if a.alt ~= b.alt then return not a.alt end          -- alts sink to the bottom
			if a.rankIndex ~= b.rankIndex then return a.rankIndex < b.rankIndex end
			return a.name:lower() < b.name:lower()
		end)
		-- three ALIGNED columns per row so it reads like a clean table:
		--   [name]        [rank]              [-> main]   [inv]
		-- name left, rank at a fixed x, main right-aligned before the inv button.
		local rows, ROWH = wrap.gRows, 20
		local RANK_X = 130   -- fixed left edge of the rank column
		local ZONE_W = 150   -- width of the right-aligned zone column
		for _, r in ipairs(rows) do r:Hide() end
		for k, m in ipairs(onlineList) do
			local row = rows[k]
			if not row then
				row = CreateFrame("Frame", nil, wrap.gchild)
				row:SetHeight(ROWH)
				row.name = row:CreateFontString(nil, "OVERLAY")
				row.name:SetFont(Okanvil:Font(), 12)
				row.name:SetPoint("LEFT", 4, 0); row.name:SetJustifyH("LEFT"); row.name:SetWordWrap(false)
				row.rank = row:CreateFontString(nil, "OVERLAY")
				row.rank:SetFont(Okanvil:Font(), 12)
				row.rank:SetPoint("LEFT", RANK_X, 0); row.rank:SetJustifyH("LEFT"); row.rank:SetWordWrap(false)
				-- main column sits right AFTER the rank text (close to the name), not
				-- pushed to the far right edge.
				row.main = row:CreateFontString(nil, "OVERLAY")
				row.main:SetFont(Okanvil:Font(), 11)
				row.main:SetPoint("LEFT", RANK_X + 84, 0); row.main:SetJustifyH("LEFT"); row.main:SetWordWrap(false)
				row.btn = W.Button(row, "inv", "secondary")
				row.btn:SetSize(34, 15); row.btn:SetPoint("RIGHT", -4, 0)
				row.btn:Tooltip("Invite to your group/raid")
				-- zone column: current location, right-aligned just left of the inv
				-- button (like the default Blizzard guild list's location column).
				row.zone = row:CreateFontString(nil, "OVERLAY")
				row.zone:SetFont(Okanvil:Font(), 11)
				row.zone:SetPoint("RIGHT", row.btn, "LEFT", -8, 0)
				row.zone:SetJustifyH("RIGHT"); row.zone:SetWordWrap(false)
				row.zone:SetWidth(ZONE_W)
				-- main column ends where the zone begins (avoids overlap on alts).
				-- Set once here; the LEFT point is already fixed above.
				row.main:SetPoint("RIGHT", row.zone, "LEFT", -8, 0)
				rows[k] = row
			end
			row:SetWidth(wrap.gsf:GetWidth()); row:SetHeight(ROWH)
			row:ClearAllPoints(); row:SetPoint("TOPLEFT", 0, -(k - 1) * ROWH); row:Show()
			-- name column has a fixed right bound so it never runs into the rank column
			row.name:SetPoint("RIGHT", row, "LEFT", RANK_X - 6, 0)
			row.name:SetText("|cff5a5d63* |r|c" .. m.col .. m.name .. "|r")
			row.rank:SetText("|cff8a8d93" .. m.rank .. "|r")
			-- alt -> show the main it belongs to, aligned in its own right column
			if m.alt and m.main then
				row.main:SetText("|cff6a6d73of |r|cffbfc4cc" .. m.main .. "|r")
			else
				row.main:SetText("")
			end
			-- zone (current location), dim so the name/rank stay dominant
			row.zone:SetText(m.zone ~= "" and ("|cff8a8d93" .. m.zone .. "|r") or "")
			local who = m.name
			row.btn.text:SetText("inv")
			row.btn:SetScript("OnClick", function()
				if InviteUnit then InviteUnit(who) else GuildInvite(who) end
			end)
			row.btn:SetShown(who ~= myName)
		end
		local h = math.max(1, #onlineList * ROWH)
		wrap.gchild:SetHeight(h); wrap.gchild:SetWidth(wrap.gsf:GetWidth())
		local maxs = math.max(0, h - wrap.gsf:GetHeight())
		wrap.gsb:SetMinMaxValues(0, maxs); wrap.gsb:SetShown(maxs > 4)
		wrap.gempty:SetText(#onlineList == 0 and "|cff888888Nobody online.|r" or "")
	end

	-- live-update on roster changes (login/logoff), not just when the panel opens.
	local ev = CreateFrame("Frame")
	ev:RegisterEvent("GUILD_ROSTER_UPDATE")
	ev:SetScript("OnEvent", function()
		if wrap:IsShown() then refreshGuild() end
	end)

	wrap:SetScript("OnShow", function()
		if GuildRoster then GuildRoster() end   -- async; GUILD_ROSTER_UPDATE fires when ready
		refreshGuild()
		p:SetHeight(math.max(wrap.scroll:GetHeight(), 640))
		wrap.relayout()
	end)
	return wrap
end

-- ------------------------------------------------------------
-- Settings
-- ------------------------------------------------------------
function Okanvil:BuildSettings()
	local fill = newFillPanel()
	local host = fill.child
	local db = self.db
	local X = 12

	-- Dashboard shell: no tabs -- all general settings (appearance + media +
	-- branding) live directly on the landing, in one internal scroll. Loot settings
	-- moved to the Loot module. The app credit sits in the bottom-right corner.
	local dash = W.Dashboard(host, {
		title = "Settings",
		icon = Okanvil.ICONS.settings,
		drawerWidth = 0,
		footerHeight = 0,
	})
	fill.dash = dash

	local main = dash.main
	-- internal scroll so the stacked sections never spill off the window
	local sf = CreateFrame("ScrollFrame", nil, main)
	sf:SetPoint("TOPLEFT", 10, -8); sf:SetPoint("BOTTOMRIGHT", -14, 22)  -- leave room for the credit line
	local p = CreateFrame("Frame", nil, sf); p:SetSize(10, 1); sf:SetScrollChild(p)
	local sb = CreateFrame("Slider", nil, main)
	sb:SetPoint("TOPRIGHT", -4, -8); sb:SetPoint("BOTTOMRIGHT", -4, 22); sb:SetWidth(4)
	sb:SetOrientation("VERTICAL"); sb:SetValueStep(1)
	local th = sb:CreateTexture(nil, "OVERLAY"); th:SetTexture(FLAT); th:SetVertexColor(u3(C.accent)); th:SetSize(4, 40)
	sb:SetThumbTexture(th)
	sb:SetScript("OnValueChanged", function(_, v) sf:SetVerticalScroll(v) end)
	sf:EnableMouseWheel(true)
	sf:SetScript("OnMouseWheel", function(_, d) sb:SetValue(sb:GetValue() - d * 30) end)
	sf:SetScript("OnSizeChanged", function()
		p:SetWidth(sf:GetWidth())
		local maxs = math.max(0, p:GetHeight() - sf:GetHeight())
		sb:SetMinMaxValues(0, maxs); sb:SetShown(maxs > 4)
	end)
	p:SetHeight(500)
	Okanvil:Settings_Options(p)

	-- app credit -- a small badge in the bottom-right corner (anvil + wordmark),
	-- nicer than a bare line of text.
	local badge = W.Frame(main, "panel")
	badge:SetPoint("BOTTOMRIGHT", main, "BOTTOMRIGHT", -12, 12)
	badge:SetHeight(48)
	local bIcon = badge:CreateTexture(nil, "ARTWORK")
	bIcon:SetSize(30, 30); bIcon:SetPoint("LEFT", 12, 0)
	bIcon:SetTexture("Interface\\Icons\\Trade_BlackSmithing"); bIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	local bName = W.Text(badge, "Okanvil", 14, "accent"); bName:SetPoint("LEFT", bIcon, "RIGHT", 10, 8); bName:Color(1, 0.82, 0)
	local bVer = W.Text(badge, "v" .. (self.version or "1.0"), 10, "dim"); bVer:SetPoint("LEFT", bName, "RIGHT", 5, 0)
	local bBy = W.Text(badge, "forged by |cffe0b860Okanor|r", 10, "dim"); bBy:SetPoint("LEFT", bIcon, "RIGHT", 10, -10)
	-- size the badge to fit its contents (icon + the wider of the two text rows)
	local wName = (bName:GetStringWidth() or 60) + (bVer:GetStringWidth() or 20) + 5
	local wBy = bBy:GetStringWidth() or 80
	badge:SetWidth(30 + 10 + math.max(wName, wBy) + 18)

	fill:SetScript("OnShow", function() dash:Refresh() end)
	return fill
end

-- ---- Settings: Options (single tab -- Appearance + Media + Branding stacked) ----
-- Loot capture/threshold settings live in the Loot module now (Loot_BuildSettings in Loot.lua).
function Okanvil:Settings_Options(p)
	local db = self.db
	local X = 4

	-- NOTE: W.Slider anchors at its BAR; its own label sits ~5px ABOVE that anchor.
	-- So each slider needs a full ~46px of vertical room, and the first one must
	-- start ~24px below a section header so the header isn't overlapped.

	-- APPEARANCE
	local a = W.Text(p, "APPEARANCE", 10, "dim"); a:SetPoint("TOPLEFT", X, -8)
	W.Slider(p, "Window scale", 0.6, 1.4, 0.05, function() return db.scale end,
		function(v) db.scale = v; Okanvil.win:SetScale(v) end, true):SetPoint("TOPLEFT", X, -46)
	W.Slider(p, "Background opacity", 0.3, 1.0, 0.05, function() return db.bgAlpha end,
		function(v) db.bgAlpha = v; Okanvil:ReskinAll(v); Okanvil:RefreshRatArt() end):SetPoint("TOPLEFT", X, -92)
	W.Slider(p, "Font size", 8, 20, 1, function() return db.fontSize end,
		function(v) db.fontSize = v; Okanvil:ApplyFonts() end):SetPoint("TOPLEFT", X, -138)
	local showChk = W.Check(p, "Show rat art on pages",
		function() return (db.ratArt or "on") ~= "off" end,
		function(v) db.ratArt = v and "on" or "off"; Okanvil:RefreshRatArt() end)
	showChk:SetPoint("TOPLEFT", X, -170)
	-- rat watermark intensity -- its OWN slider, independent of panel opacity.
	W.Slider(p, "Rat art opacity", 0.0, 0.8, 0.05, function() return db.ratAlpha end,
		function(v) db.ratAlpha = v; Okanvil:RefreshRatArt() end):SetPoint("TOPLEFT", X, -212)

	-- MEDIA
	local m = W.Text(p, "MEDIA", 10, "dim"); m:SetPoint("TOPLEFT", X, -252)
	local fl = W.Text(p, "Font", 11, "dim"); fl:SetPoint("TOPLEFT", X, -274)
	W.DropDown(p, function() return (LSM and LSM:List("font")) or { db.font } end,
		function() return db.font end, function(v) db.font = v; Okanvil:ApplyFonts() end, "font")
		:Size(200, 22):Point("TOPLEFT", X + 90, -272)

	-- BRANDING (product name is FIXED -- guilds only set their own skin)
	local b = W.Text(p, "BRANDING", 10, "dim"); b:SetPoint("TOPLEFT", X, -344)
	local nl = W.Text(p, "Guild skin (shown after Okanvil)", 11, "dim"); nl:SetPoint("TOPLEFT", X, -366)
	local nameBox = W.EditBox(p, function(txt)
		db.brand = txt or ""
		if Okanvil.headerPaintBrand then Okanvil.headerPaintBrand() end
		Okanvil.panels["__home"] = nil
	end)
	nameBox:SetSize(320, 22); nameBox:SetPoint("TOPLEFT", X, -384)
	nameBox.edit:SetText((db.brand ~= "Okanvil" and db.brand) or "")
	local nh = W.Text(p, "e.g. RATS Guild Hub -- leave empty for just \"Okanvil\".", 10, "dim")
	nh:SetPoint("TOPLEFT", X, -410)
	local ul = W.Text(p, "Web hub URL", 11, "dim"); ul:SetPoint("TOPLEFT", X, -434)
	local urlBox = W.EditBox(p, function(txt)
		db.hubURL = txt
		if Okanvil.footerPaintHub then Okanvil.footerPaintHub() end   -- live-update footer link
	end)
	urlBox:SetSize(320, 22); urlBox:SetPoint("TOPLEFT", X, -452)
	urlBox.edit:SetText(db.hubURL or "")
end

-- ------------------------------------------------------------
-- Modules -- enable/disable each registered plugin (no /reload for
-- show/hide in the nav; deeper event-gating is opt-in per plugin later)
-- ------------------------------------------------------------
function Okanvil:BuildModules()
	local fill = newFillPanel()
	local host = fill.child

	-- Dashboard shell: header only (no tabs/drawer/CTA); the module list scrolls.
	local dash = W.Dashboard(host, {
		title = "Modules",
		icon = Okanvil.ICONS.modules,
		drawerWidth = 0,
		footerHeight = 0,
		statusText = function()
			local on, total = 0, 0
			for name in pairs(Okanvil.entries) do total = total + 1; if Okanvil:IsModuleEnabled(name) then on = on + 1 end end
			return "|cff8a8d93" .. on .. "/" .. total .. " on|r"
		end,
	})
	fill.dash = dash

	local main = dash.main
	local X = 14
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

	local hint = W.Text(p, "Turn modules on/off for THIS character (off = hidden from the menu). Each module's settings stay shared across your toons.", 11, "dim")
	hint:SetPoint("TOPLEFT", X, -6); hint:SetPoint("RIGHT", p, "RIGHT", -X, 0); hint:SetJustifyH("LEFT")

	wrap.rows = {}
	local function rebuild()
		for _, r in ipairs(wrap.rows) do r:Hide() end
		-- one unified list of every registered module, alphabetical by title.
		-- Each item = { key, title, icon, desc } -- the key is what IsModuleEnabled
		-- and the nav use.
		local items = {}
		local names = {}
		for name in pairs(Okanvil.entries) do names[#names + 1] = name end
		table.sort(names, function(a, b)
			return (Okanvil.entries[a].title or a) < (Okanvil.entries[b].title or b)
		end)
		for _, name in ipairs(names) do
			local e = Okanvil.entries[name]
			items[#items + 1] = { key = name, title = e.title or name, icon = e.icon, desc = e.desc }
		end
		if wrap.empty then wrap.empty:SetText("") end

		local y = 44
		for i, it in ipairs(items) do
			local name = it.key
			local r = wrap.rows[i]
			if not r then
				r = W.Frame(p, "input")
				r.icon = r:CreateTexture(nil, "ARTWORK")
				r.icon:SetSize(24, 24); r.icon:SetPoint("LEFT", 8, 0)
				r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
				r.title = W.Text(r, "", 13); r.title:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 10, -1)
				r.desc = W.Text(r, "", 10, "dim")
				r.desc:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 10, -15)
				r.desc:SetPoint("RIGHT", r, "RIGHT", -110, 0); r.desc:SetJustifyH("LEFT")
				r.toggle = W.Button(r, "")
				r.toggle:SetSize(88, 24)
				r.toggle:SetPoint("RIGHT", -8, 0)
				wrap.rows[i] = r
			end
			r:ClearAllPoints()
			r:SetPoint("TOPLEFT", X, -y); r:SetPoint("RIGHT", p, "RIGHT", -X, 0)
			r:SetHeight(44)
			r.icon:SetTexture(it.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
			r.title:SetText(it.title or name)
			r.desc:SetText(it.desc or "")

			local function paintToggle()
				local on = Okanvil:IsModuleEnabled(name)
				r.toggle.text:SetText(on and "|cff7cfc8aEnabled|r" or "|cff8a8d93Disabled|r")
				r.toggle._active = on
				if r.toggle._paint then r.toggle._paint(false) end
			end
			paintToggle()
			r.toggle:SetScript("OnClick", function()
				Okanvil:SetModuleEnabled(name, not Okanvil:IsModuleEnabled(name))
				paintToggle()
				dash:Refresh()
			end)
			r:Show()
			y = y + 50
		end
		p:SetHeight(math.max(y + 10, sf:GetHeight()))
		wrap.relayout()
	end

	wrap._rebuild = rebuild
	local function refreshAll() dash:Refresh(); rebuild() end
	fill:SetScript("OnShow", refreshAll)
	return fill
end

-- ------------------------------------------------------------
-- Toggle
-- ------------------------------------------------------------
function Okanvil:Toggle()
	if not self.win then self:BuildShell() end
	if self.puck then self.puck:Hide() end   -- opening always leaves the collapsed puck
	if self.win:IsShown() then
		self:CloseDropdown()
		self.win:Hide()
	else
		self:RefreshNav()
		self.win:Show()
		self:ShowPanel(self._current or HOME)
	end
end

-- ------------------------------------------------------------
-- Minimap button
-- ------------------------------------------------------------
function Okanvil:BuildMinimap()
	if self.minimap then return end
	local b = CreateFrame("Button", "Okanvil_MinimapButton", Minimap)
	b:SetSize(31, 31); b:SetFrameStrata("MEDIUM"); b:SetFrameLevel(8)
	b:RegisterForClicks("LeftButtonUp"); b:RegisterForDrag("LeftButton")

	local overlay = b:CreateTexture(nil, "OVERLAY")
	overlay:SetSize(53, 53); overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder"); overlay:SetPoint("TOPLEFT")
	local icon = b:CreateTexture(nil, "BACKGROUND")
	icon:SetSize(20, 20); icon:SetTexture("Interface\\Icons\\Trade_BlackSmithing")   -- anvil
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92); icon:SetPoint("CENTER", 1, 1)

	local function pos()
		local a = math.rad(Okanvil.db.minimapAngle or 200)
		b:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(a), 80 * math.sin(a))
	end
	pos()
	b:SetScript("OnDragStart", function(s)
		s:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local px, py = GetCursorPosition()
			local sc = Minimap:GetEffectiveScale()
			Okanvil.db.minimapAngle = math.deg(math.atan2(py / sc - my, px / sc - mx))
			pos()
		end)
	end)
	b:SetScript("OnDragStop", function(s) s:SetScript("OnUpdate", nil) end)
	b:SetScript("OnClick", function() Okanvil:Toggle() end)
	b:SetScript("OnEnter", function(s)
		GameTooltip:SetOwner(s, "ANCHOR_LEFT")
		GameTooltip:AddLine("|cffffd200Okanvil|r")
		local gb = Okanvil.db.brand
		if gb and gb ~= "" and gb ~= "Okanvil" then GameTooltip:AddLine(gb, 0.88, 0.72, 0.38) end
		GameTooltip:AddLine("Click: open", 1, 1, 1)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	self.minimap = b
end
