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
local MIN_W, MIN_H = WIN_W, WIN_H   -- kept for any legacy references
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
	self.headerTitle = brandFS   -- so Settings can rebrand live
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
-- Built-in modules (rendered by the shell's own BuildInvite/Guild/Loot, not a
-- plugin build()). Listed here so they ALSO appear in the Modules manager and can
-- be toggled on/off exactly like the plugin modules. Home/Modules/Settings are the
-- fixed "core" and are never toggleable.
-- One coherent icon set (all verified 3.3.5a paths). Keep the nav icon and the
-- module's Dashboard header icon the SAME so the two never look mismatched.
Okanvil.ICONS = {
	home    = "Interface\\Icons\\INV_Misc_Rune_01",
	invite  = "Interface\\Icons\\Spell_ChargePositive",
	guild   = "Interface\\Icons\\INV_Shirt_GuildTabard_01",
	loot    = "Interface\\Icons\\INV_Misc_Coin_02",
	logs    = "Interface\\Icons\\INV_Scroll_03",
	ids     = "Interface\\Icons\\INV_Misc_Spyglass_02",
	recruit = "Interface\\Icons\\Achievement_General_StayClassy",
	modules = "Interface\\Icons\\INV_Misc_Gear_01",
	settings= "Interface\\Icons\\Trade_Engineering",
}

Okanvil.NATIVE = {
	{ key = "__invite", title = "Invite", icon = Okanvil.ICONS.invite,
	  desc = "Mass-invite the guild, by rank, or from saved lists." },
	{ key = "__guild",  title = "Guild",  icon = Okanvil.ICONS.guild,
	  desc = "Guild dashboard + JSON roster export for the web hub." },
	{ key = "__loot",   title = "Loot",   icon = Okanvil.ICONS.loot,
	  desc = "Per-boss loot tracking with a fair-loot priority tab." },
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
	for _, m in ipairs(self.NATIVE) do
		if self:IsModuleEnabled(m.key) then
			pool[m.title] = { key = m.key, title = m.title, icon = m.icon }
		end
	end
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
		-- count = built-in natives + registered plugins
		local total, on = 0, 0
		for _, m in ipairs(self.NATIVE) do
			total = total + 1
			if self:IsModuleEnabled(m.key) then on = on + 1 end
		end
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

-- Back-compat no-op: panels used to call this to get their own rat. Now the
-- single content rat covers every page, so per-panel mounts do nothing. Kept so
-- existing call sites don't error while we remove them.
function Okanvil:MountBgArt() end

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
		elseif key == GUILD then entry = self:BuildGuild()
		elseif key == LOOT then entry = self:BuildLoot()
		elseif key == INVITE then entry = self:BuildInvite()
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
-- Guild (native) -- roster export + raid attendance snapshots
-- ------------------------------------------------------------
function Okanvil:BuildGuild()
	local fill = newFillPanel()
	local host = fill.child
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
	fill.dash = dash

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
	G.onSnapshot = function() if fill:IsShown() then refreshAll() end end
	fill:SetScript("OnShow", refreshAll)
	return fill
end

-- ------------------------------------------------------------
-- Loot (native) -- what dropped, per boss. Data only; winners on the hub.
-- ------------------------------------------------------------
function Okanvil:BuildLoot()
	local L = Okanvil.Loot
	local fill = newFillPanel()
	local host = fill.child
	Okanvil._lootFill = fill   -- set BEFORE the tab builders run (they read it)

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
			{ key = "collectors", label = "Collectors", height = 330, build = function(pg) Okanvil:Loot_BuildCollectors(pg) end },
			{ key = "messages",   label = "Messages",   height = 260, build = function(pg) Okanvil:Loot_BuildMessages(pg) end },
			{ key = "settings",   label = "Settings",   height = 160, build = function(pg) Okanvil:Loot_BuildSettings(pg) end },
		},
	})
	fill.dash = dash

	Okanvil:Loot_BuildHistory(dash.main)     -- sessions accordion (landing)

	-- refresh when loot changes / the page shows / loot method changes
	local function refreshAll()
		dash:Refresh()
		if fill._rebuildHistory then fill._rebuildHistory() end
	end
	fill.refreshAll = refreshAll
	L.onLoot = function() if fill:IsShown() then refreshAll() end end
	if not fill._mlEv then
		fill._mlEv = CreateFrame("Frame")
		fill._mlEv:RegisterEvent("PARTY_LOOT_METHOD_CHANGED")
		fill._mlEv:RegisterEvent("RAID_ROSTER_UPDATE")
		fill._mlEv:SetScript("OnEvent", function() if fill:IsShown() then dash:Refresh() end end)
	end
	fill:SetScript("OnShow", refreshAll)
	Okanvil._lootFill = fill
	return fill
end

-- ---- Collectors tab: Main/Frag/BoE targets + auto toggle + whisper toggle ----
function Okanvil:Loot_BuildCollectors(p)
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
function Okanvil:Loot_BuildMessages(p)
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
function Okanvil:Loot_BuildHistory(main)
	local L = Okanvil.Loot
	local fill = Okanvil._lootFill
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

-- ------------------------------------------------------------
-- Invite (native) -- form a raid/party fast: mass-invite, by rank, saved lists
-- with comp-group import + auto-assign, keyword whisper invite, on-login invite.
-- ------------------------------------------------------------
function Okanvil:BuildInvite()
	local fill = newFillPanel()
	local host = fill.child
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
			{ key = "lists", label = "My Lists", height = 460, build = function(pg) Okanvil:Invite_BuildLists(pg) end },
		},
	})
	fill.dash = dash

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
		p:SetHeight(160); wrap.relayout()
		return fill
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
		if kwEnable.refresh then kwEnable.refresh() end   -- Recruit may have flipped this
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
	function fill:SetActiveList(name)
		if not name or name == "" then return end
		curList = name
		rebuild()
	end

	Okanvil._inviteFill = fill                 -- the My Lists tab reads engine off this
	local function refreshAll()
		dash:Refresh(); rebuild()
		if fill._rebuildLists then fill._rebuildLists() end   -- keep the My Lists tab fresh
	end
	I.onChange = function() if fill:IsShown() then refreshAll() end end
	fill:SetScript("OnShow", function() if GuildRoster then GuildRoster() end; refreshAll() end)
	return fill
end

-- ---- Invite: My Lists tab -- see each saved list's members, load / arm / delete ----
function Okanvil:Invite_BuildLists(p)
	local I = Okanvil.Invite
	local fill = Okanvil._inviteFill
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
-- Loot capture/threshold settings live in the Loot module now (Okanvil:Loot_BuildSettings).
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
	local tl = W.Text(p, "Bar texture", 11, "dim"); tl:SetPoint("TOPLEFT", X, -304)
	W.DropDown(p, function() return (LSM and LSM:List("statusbar")) or { db.statusbar } end,
		function() return db.statusbar end, function(v) db.statusbar = v end, "statusbar")
		:Size(200, 22):Point("TOPLEFT", X + 90, -302)

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

-- ---- Loot capture settings (used as a tab INSIDE the Loot module) ----
function Okanvil:Loot_BuildSettings(p)
	local db = self.db
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
			for _, m in ipairs(Okanvil.NATIVE) do total = total + 1; if Okanvil:IsModuleEnabled(m.key) then on = on + 1 end end
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
		-- one unified list: built-in modules first (in NATIVE order), then plugins.
		-- Each item = { key, title, icon, desc } -- the key is what IsModuleEnabled
		-- and the nav use.
		local items = {}
		for _, m in ipairs(Okanvil.NATIVE) do
			items[#items + 1] = { key = m.key, title = m.title, icon = m.icon, desc = m.desc }
		end
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
