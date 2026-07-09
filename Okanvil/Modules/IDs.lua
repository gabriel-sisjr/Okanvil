-- ============================================================
--   ██████╗ ██╗  ██╗ █████╗ ███╗   ██╗██╗   ██╗██╗██╗
--  ██╔═══██╗██║ ██╔╝██╔══██╗████╗  ██║██║   ██║██║██║
--  ██║   ██║█████╔╝ ███████║██╔██╗ ██║██║   ██║██║██║
--  ██║   ██║██╔═██╗ ██╔══██║██║╚██╗██║╚██╗ ██╔╝██║██║
--  ╚██████╔╝██║  ██╗██║  ██║██║ ╚████║ ╚████╔╝ ██║███████╗
--   ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝  ╚═══╝  ╚═╝╚══════╝
--  Okanvil-IDs -- a spell/item ID LIBRARY (find an ID by name, no need to
--  own the item). Two layers:
--    * LIB  (Okanvil.IDs.*)  a reusable, UI-free lookup API other addons can
--      call: EnsureSpells / FindSpell / FindItem / RecordItem / SweepLoaded /
--      FullScan. Spells come from a fully-offline client scan (Spell.dbc);
--      items are harvested from anything the client already cached (tooltips
--      you hover, bags, bank, merchant, chat links) + a "Sweep loaded" pass.
--    * UI   a thin client of the lib (search box + 2 result columns).
--  A native Okanvil module (no standalone).
-- ============================================================

local ADDON = "Okanvil-IDs"
local FLAT = "Interface\\ChatFrame\\ChatFrameBackground"
local QMARK = "Interface\\Icons\\INV_Misc_QuestionMark"

local MAX_SPELL_ID = 80000 -- WotLK 3.3.5a tops out well under this
local MAX_ITEM_ID = 56000 -- upper bound for the optional full item scan
local MAX_RESULTS = 300 -- cap matches per search (keeps the UI snappy)
local ROW_H = 20 -- a touch of breathing room; names are clamped to one line

local defaults = {
	items = {}, -- [itemID] = name   (harvested; account-wide)
	icons = {}, -- [itemID] = iconPath  (harvested during Full scan; survives a
	            -- client change so we render the real icon from the FILE instead
	            -- of "?" when the fresh client hasn't cached the item yet)
}
local db

OkanvilIDs = OkanvilIDs or {} -- namespace for slash / boot

-- The public library table. Lives on Okanvil (Okanvil.IDs) so other plugins can
-- call it.
local IDs = {}
if Okanvil then Okanvil.IDs = IDs end

-- ============================================================
-- LIBRARY LAYER  (no UI -- pure data + lookup)
-- ============================================================

-- ------------------------------------------------------------
-- spell index (built once per session from the client, in memory)
-- ------------------------------------------------------------
local spellIndex = {}       -- { {id=, name=, nl=lower} ... }
local spellByName = {}      -- [lowername] = id   (first id wins; exact lookups)
local spellBuilt, spellBuilding = false, false
local spellDoneCbs = {}     -- callbacks waiting for the index
local builder = CreateFrame("Frame")

local function fireSpellDone()
	for i = 1, #spellDoneCbs do
		local cb = spellDoneCbs[i]
		if cb then pcall(cb) end
	end
	spellDoneCbs = {}
end

-- Build the offline spell index (async, chunked so it never hitches the client).
-- Callback (optional) fires once the index is ready; calling again while built
-- just runs the callback immediately.
function IDs.EnsureSpells(onDone)
	if spellBuilt then
		if onDone then onDone() end
		return
	end
	if onDone then spellDoneCbs[#spellDoneCbs + 1] = onDone end
	if spellBuilding then return end
	spellBuilding = true
	spellIndex, spellByName = {}, {}
	local i = 0
	builder:SetScript("OnUpdate", function(self)
		local stop = i + 2500
		while i < stop and i < MAX_SPELL_ID do
			i = i + 1
			local name = GetSpellInfo(i)
			if name and name ~= "" then
				local nl = string.lower(name)
				spellIndex[#spellIndex + 1] = { id = i, name = name, nl = nl }
				if spellByName[nl] == nil then spellByName[nl] = i end
			end
		end
		if IDs.OnStatus then
			IDs.OnStatus(string.format("Building spell index... %d%%", math.floor(i / MAX_SPELL_ID * 100)))
		end
		if i >= MAX_SPELL_ID then
			self:SetScript("OnUpdate", nil)
			spellBuilding, spellBuilt = false, true
			if IDs.OnStatus then IDs.OnStatus(#spellIndex .. " spells indexed.") end
			fireSpellDone()
		end
	end)
end

-- Substring search over the spell index. `query` may be a name fragment or a
-- numeric id. Returns an array of { id, name } (capped at MAX_RESULTS).
function IDs.FindSpell(query, limit)
	local out = {}
	if not query or query == "" then return out end
	limit = limit or MAX_RESULTS
	local q = string.lower(query)
	local num = tonumber(q)
	if num then
		local n = GetSpellInfo(num)
		if n and n ~= "" then out[#out + 1] = { id = num, name = n } end
	end
	for i = 1, #spellIndex do
		local s = spellIndex[i]
		if string.find(s.nl, q, 1, true) then
			out[#out + 1] = { id = s.id, name = s.name }
			if #out >= limit then break end
		end
	end
	return out
end

-- ------------------------------------------------------------
-- item DB (harvested -- only ids the client has already cached)
-- ------------------------------------------------------------
local itemCount = 0
local itemLower, itemLowerN = {}, -1 -- lowercase name cache, rebuilt when DB grows

local function recountItems()
	itemCount = 0
	for _ in pairs(db.items) do itemCount = itemCount + 1 end
end
function IDs.ItemCount() return itemCount end

local function refreshItemLower()
	if itemLowerN == itemCount then return end
	itemLower = {}
	for id, name in pairs(db.items) do itemLower[id] = string.lower(name) end
	itemLowerN = itemCount
end

-- Icon path for an item id, preferring the FILE-persisted one (survives a client
-- change) and falling back to the live client cache. nil if we have neither yet.
function IDs.ItemIcon(id)
	id = tonumber(id)
	if not id then return nil end
	local saved = db and db.icons and db.icons[id]
	if saved then return saved end
	return select(10, GetItemInfo(id))
end

-- Record an item by link OR numeric id (only succeeds when the client already
-- has it cached -- i.e. it just showed in a tooltip/bag/etc). Returns true if new.
function IDs.RecordItem(linkOrId)
	if not linkOrId or not db then return false end
	local id
	if type(linkOrId) == "number" then
		id = linkOrId
	else
		id = tonumber(string.match(linkOrId, "item:(%d+)"))
	end
	if not id then return false end
	local name = GetItemInfo(id)
	if name and db.items[id] ~= name then
		db.items[id] = name
		itemCount = itemCount + 1
		return true
	end
	return false
end

-- Sweep everything currently loaded (equipped, bags, bank, open merchant). No
-- server requests -- all of it is already cached. Returns how many were new.
function IDs.SweepLoaded()
	if not db then return 0 end
	local before = itemCount
	for slot = 1, 19 do -- equipped
		IDs.RecordItem(GetInventoryItemLink("player", slot))
	end
	for bag = -1, 11 do -- backpack/bags (0-4) + bank (-1, 5-11)
		local n = GetContainerNumSlots(bag) or 0
		for s = 1, n do IDs.RecordItem(GetContainerItemLink(bag, s)) end
	end
	if MerchantFrame and MerchantFrame:IsShown() then
		for i = 1, GetMerchantNumItems() do IDs.RecordItem(GetMerchantItemLink(i)) end
	end
	return itemCount - before
end

-- Substring search over the item DB. Returns { id, name, isItem=true }.
-- `matched` (optional) is filled with [id]=true for the caller's de-dupe.
function IDs.FindItem(query, limit, matched)
	local out = {}
	if not query or query == "" then return out end
	refreshItemLower()
	limit = limit or MAX_RESULTS
	local q = string.lower(query)
	local num = tonumber(q)
	if num then
		local n = db.items[num] or GetItemInfo(num)
		if n then
			out[#out + 1] = { id = num, name = n, isItem = true }
			if matched then matched[num] = true end
		end
	end
	for id, nl in pairs(itemLower) do
		if string.find(nl, q, 1, true) then
			out[#out + 1] = { id = id, name = db.items[id], isItem = true }
			if matched then matched[id] = true end
			if #out >= limit then break end
		end
	end
	return out
end

-- ------------------------------------------------------------
-- optional FULL item scan (brute-force GetItemInfo -- risky: fires a server
-- request per uncached id). Throttled + abortable. Lives in the lib so the UI
-- (or a script) can drive it; progress/status via IDs.OnStatus.
-- ------------------------------------------------------------
local scanning, scanFrame = false, CreateFrame("Frame")

function IDs.StopFullScan()
	if not scanning then return end
	scanning = false
	scanFrame:SetScript("OnUpdate", nil)
	recountItems()
	if IDs.OnStatus then IDs.OnStatus("Full scan stopped. DB holds " .. itemCount .. " item(s).") end
end

function IDs.FullScan()
	if scanning then return end
	scanning = true
	local i, acc = 0, 0
	scanFrame:SetScript("OnUpdate", function(self, e)
		acc = acc + e
		if acc < 0.1 then return end -- ~10 batches/sec to keep the request rate low
		acc = 0
		local stop = i + 100 -- 100 ids/batch -> ~1000 ids/sec
		while i < stop and i < MAX_ITEM_ID do
			i = i + 1
			-- GetItemInfo: name is #1, icon path is #10. nil for uncached -> queues
			-- a server request (that's what the Full scan is for).
			local name, _, _, _, _, _, _, _, _, icon = GetItemInfo(i)
			if name and db.items[i] ~= name then db.items[i] = name end
			-- persist the icon too, so a fresh client renders it from the FILE
			-- (no more "?" after a client change).
			if icon and icon ~= "" and db.icons and db.icons[i] ~= icon then db.icons[i] = icon end
		end
		if IDs.OnStatus then
			IDs.OnStatus(string.format("Full scan %d%%  (id %d) -- watch for lag/disconnect", math.floor(i / MAX_ITEM_ID * 100), i))
		end
		if i >= MAX_ITEM_ID then
			scanning = false
			self:SetScript("OnUpdate", nil)
			recountItems()
			if IDs.OnStatus then IDs.OnStatus("Full scan complete. DB holds " .. itemCount .. " item(s).") end
		end
	end)
end
function IDs.IsScanning() return scanning end

-- ------------------------------------------------------------
-- seed / export -- the point of the DB: scan ONCE, ship the data with the
-- addon so everyone else opens it already full (no scanning required).
-- ------------------------------------------------------------
-- Fold a { [id]=name } table into the live DB (used at boot to load an
-- optional pre-built data file: `OkanvilIDs_Seed`). New ids only; never
-- overwrites what the player has already harvested locally.
function IDs.MergeSeed(seed)
	if type(seed) ~= "table" or not db then return 0 end
	local added = 0
	for id, name in pairs(seed) do
		id = tonumber(id)
		if id and type(name) == "string" and db.items[id] == nil then
			db.items[id] = name
			added = added + 1
		end
	end
	if added > 0 then recountItems() end
	return added
end

-- Serialize the whole item DB as a Lua chunk you can paste into a data file
-- (Okanvil-IDs-Data.lua) shipped with the addon. Sorted by id for clean diffs.
function IDs.ExportItems()
	local ids = {}
	for id in pairs(db.items) do ids[#ids + 1] = id end
	table.sort(ids)
	local out = { "OkanvilIDs_Seed = {" }
	for _, id in ipairs(ids) do
		-- escape quotes/backslashes so odd item names stay valid Lua
		local name = db.items[id]:gsub("\\", "\\\\"):gsub('"', '\\"')
		out[#out + 1] = string.format("[%d]=\"%s\",", id, name)
	end
	out[#out + 1] = "}"
	return table.concat(out, "\n"), #ids
end

-- ============================================================
-- UI LAYER  (a thin client of the lib above)
-- ============================================================

-- ------------------------------------------------------------
-- helpers -- thin wrappers over the shared Okanvil widget layer. The host is
-- always loaded (native module), so no local fallbacks. Used only for the
-- floating toast; the in-window UI uses Okanvil.W.* directly.
-- ------------------------------------------------------------
local function flat(f, a, dark) Okanvil:Backdrop(f, a, dark) end

local function newText(parent, layer, size)
	local fs = Okanvil:NewText(parent, layer)
	if size then fs._okSize = size; fs:SetFont(Okanvil:Font(), size) end
	return fs
end

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cffe0b860[Okanvil-IDs]|r " .. tostring(msg))
end

-- transient toast (success/failure feedback)
local toastF
local function toast(msg, color)
	PlaySound("UI_BnetToast")
	if not toastF then
		toastF = CreateFrame("Frame", nil, UIParent)
		toastF:SetSize(300, 32)
		toastF:SetPoint("TOP", 0, -110)
		toastF:SetFrameStrata("FULLSCREEN_DIALOG")
		flat(toastF, 0.96, true)
		toastF.txt = newText(toastF, "OVERLAY")
		toastF.txt:SetPoint("CENTER")
		toastF:SetScript("OnUpdate", function(s, e)
			s._life = (s._life or 0) - e
			if s._life <= 0 then
				s:Hide()
			elseif s._life < 1 then
				s:SetAlpha(s._life)
			end
		end)
	end
	toastF.txt:SetText("|cff" .. (color or "ffffff") .. msg .. "|r")
	toastF:SetAlpha(1)
	toastF._life = 4
	toastF:Show()
end

-- shared gold RATS-Hub button (host always present)
local function flatButton(parent, text, w, h, kind)
	local b = Okanvil.W.Button(parent, text, kind)
	b:SetSize(w, h)
	return b
end

-- ------------------------------------------------------------
-- UI  -- a native Okanvil module page (Dashboard shell)
-- ------------------------------------------------------------
local function buildUI(host)
	local X = 12
	local statusFS, searchBox

	-- Dashboard shell (MRT/Recruit-style gold header). The finder's own two-column
	-- layout draws into dash.main; the header carries the title, DB count and the
	-- safe "Sweep loaded" CTA.
	local W = Okanvil.W
	local dash = W.Dashboard(host, {
		title = "ID Finder",
		icon = (Okanvil.ICONS and Okanvil.ICONS.ids) or "Interface\\Icons\\INV_Misc_Spyglass_02",
		drawerWidth = 0,
		footerHeight = 0,
		primaryText = function() return "Sweep loaded" end,
		onPrimary = function()
			local added = IDs.SweepLoaded()
			if Okanvil.Print then Okanvil:Print("Swept " .. added .. " new item(s).") end
			if OkanvilIDs._doRun then OkanvilIDs._doRun() end
			if OkanvilIDs._paintStatus then OkanvilIDs._paintStatus() end
		end,
		statusText = function() return "|cff8a8d93" .. IDs.ItemCount() .. " items in DB|r" end,
	})
	local parent = dash.main
	OkanvilIDs._dash = dash

	local colSpell, colItem -- forward decl (the two result columns)

	-- shared row renderer (icon + name + id), used by every column
	local function renderRow(r, d)
		if not d then
			r._d = nil
			r:Hide()
			return
		end
		r._d = d
		local icon
		if d.isItem then
			icon = select(10, GetItemInfo(d.id))
			local q = select(3, GetItemInfo(d.id))
			if q then
				local cr, cg, cb = GetItemQualityColor(q)
				r.name:SetTextColor(cr, cg, cb)
			else
				r.name:SetTextColor(0.9, 0.9, 0.9)
			end
		else
			icon = select(3, GetSpellInfo(d.id)) -- 3rd return = icon path (reliable)
			r.name:SetTextColor(0.9, 0.9, 0.9)
		end
		if not icon or icon == "" then icon = QMARK end
		r.icon:SetTexture(icon)
		r.name:SetText(d.name or "?")
		r.id:SetText("|cffffd100" .. d.id .. "|r")
		r:Show()
	end

	-- build one result column: a dark card with a gold header + scrolling list
	local COL_W, COL_ROWS = 320, 13
	local function makeColumn(x, header, key)
		local col = { results = {} }
		local rowW = COL_W - 20
		-- the card that frames the whole column (header + list share it)
		local card = W.Frame(parent, "dark")
		card:SetPoint("TOPLEFT", x, -64)
		card:SetSize(COL_W, COL_ROWS * ROW_H + 30)
		-- gold header sits INSIDE the card top
		local h = newText(card, "OVERLAY", 12)
		h:SetPoint("TOPLEFT", 8, -7)
		h:SetTextColor(1.0, 0.82, 0.0)
		h:SetText(header)
		col.count = newText(card, "OVERLAY")
		col.count:SetPoint("LEFT", h, "RIGHT", 6, 0)
		col.count:SetTextColor(0.54, 0.55, 0.58)
		local scroll = CreateFrame("ScrollFrame", "OkanvilIDs_Col" .. key, card, "FauxScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", 4, -26)
		scroll:SetSize(rowW, COL_ROWS * ROW_H)
		local rows = {}
		local function update()
			local off = FauxScrollFrame_GetOffset(scroll)
			for i = 1, COL_ROWS do
				renderRow(rows[i], col.results[off + i])
			end
			FauxScrollFrame_Update(scroll, #col.results, COL_ROWS, ROW_H)
		end
		col.update = update
		scroll:SetScript("OnVerticalScroll", function(self, o)
			FauxScrollFrame_OnVerticalScroll(self, o, ROW_H, update)
		end)
		for i = 1, COL_ROWS do
			local r = CreateFrame("Button", nil, card)
			r:SetSize(rowW, ROW_H)
			if i == 1 then
				r:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
			else
				r:SetPoint("TOPLEFT", rows[i - 1], "BOTTOMLEFT", 0, 0)
			end
			r.icon = r:CreateTexture(nil, "ARTWORK")
			r.icon:SetSize(16, 16)
			r.icon:SetPoint("LEFT", 2, 0)
			r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
			r.name = newText(r, "OVERLAY")
			r.name:SetPoint("LEFT", r.icon, "RIGHT", 4, 0)
			r.name:SetJustifyH("LEFT")
			r.name:SetWidth(rowW - 16 - 46)
			r.name:SetHeight(ROW_H)           -- clamp to one row so a long name
			if r.name.SetWordWrap then         -- can't spill onto the next line
				r.name:SetWordWrap(false)      -- (truncates instead of wrapping)
			end
			if r.name.SetMaxLines then r.name:SetMaxLines(1) end
			r.id = newText(r, "OVERLAY")
			r.id:SetPoint("RIGHT", -4, 0)
			r.id:SetTextColor(1.0, 0.82, 0.0)
			r.hl = r:CreateTexture(nil, "BACKGROUND")
			r.hl:SetAllPoints()
			r.hl:SetTexture(0.75, 0.58, 0.23, 0.22) -- gold hover, matches the shell
			r.hl:Hide()
			-- hover shows the item/spell tooltip; no click action -- the id is right
			-- there in the row to read (3.3.5a has no OS clipboard anyway).
			r:SetScript("OnEnter", function(s)
				s.hl:Show()
				if s._d then
					GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
					GameTooltip:SetHyperlink((s._d.isItem and "item:" or "spell:") .. s._d.id)
					GameTooltip:Show()
				end
			end)
			r:SetScript("OnLeave", function(s)
				s.hl:Hide()
				GameTooltip:Hide()
			end)
			rows[i] = r
		end
		col.set = function(list)
			col.results = list or {}
			local sb = _G["OkanvilIDs_Col" .. key .. "ScrollBar"]
			if sb then sb:SetValue(0) end
			update()
			col.count:SetText("|cff888888(" .. #col.results .. ")|r")
		end
		return col
	end

	colSpell = makeColumn(X, "Spells / Auras", "S")
	colItem = makeColumn(X + COL_W + 10, "Items", "I")

	-- ---- run a search: three lib calls, nothing else ----
	local function runSearch()
		local q = string.lower(string.gsub(searchBox:GetText() or "", "^%s*(.-)%s*$", "%1"))
		if q == "" then
			colSpell.set({}); colItem.set({})
			if statusFS then
				statusFS:SetText("|cffaaaaaatype a name or id -> searches the item + spell library.|r")
			end
			return
		end
		colItem.set(IDs.FindItem(q, MAX_RESULTS))
		colSpell.set(IDs.FindSpell(q, MAX_RESULTS)) -- spells & auras are the same library
		if statusFS then
			statusFS:SetText("|cffaaaaaaSpells/Auras " .. #colSpell.results .. "   Items " .. #colItem.results .. "|r")
		end
	end

	local function doRun()
		IDs.EnsureSpells(runSearch) -- build the index once (async), then search
	end

	-- ---- header: hint + search + item-scan buttons ----
	-- (the gold "ID Finder" title lives in the Dashboard header above; here we just
	--  show the one-line usage hint, then the search box.)
	local sub = newText(parent, "OVERLAY", 11)
	sub:SetPoint("TOPLEFT", X, -8)
	sub:SetTextColor(0.54, 0.55, 0.58)
	sub:SetText("Type a name or id -> read the ID off the result. (Auras are spells -- same column.)")

	searchBox = CreateFrame("EditBox", nil, parent)
	searchBox:SetSize(380, 26)
	searchBox:SetPoint("TOPLEFT", X, -30)
	searchBox:SetAutoFocus(false)
	searchBox:SetFontObject("GameFontHighlight")
	searchBox:SetTextInsets(6, 6, 0, 0)
	flat(searchBox, 1, true)
	searchBox:SetScript("OnEnterPressed", doRun)
	searchBox:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
	-- SHIFT-CLICK an item (bags/AtlasLoot/chat) while the box is focused -> drop the
	-- item's NAME in and search it, instead of pasting the raw link. Hook the global
	-- link inserter; only act when OUR box has focus so we don't hijack chat.
	if not OkanvilIDs._linkHooked and hooksecurefunc then
		OkanvilIDs._linkHooked = true
		hooksecurefunc("ChatEdit_InsertLink", function(link)
			local box = OkanvilIDs._searchBox
			if not (box and box:HasFocus() and link) then return end
			local name = link:match("|h%[(.-)%]|h") or link:match("item:%d+")
			if name then
				box:SetText(name)
				if OkanvilIDs._doRun then OkanvilIDs._doRun() end
			end
		end)
	end
	OkanvilIDs._searchBox, OkanvilIDs._doRun = searchBox, doRun
	local ghost = newText(searchBox, "OVERLAY")
	ghost:SetPoint("LEFT", 6, 0)
	ghost:SetText("|cff777777type a name, or shift-click an item|r")
	searchBox:SetScript("OnTextChanged", function(s)
		if s:GetText() == "" then ghost:Show() else ghost:Hide() end
	end)
	searchBox:SetScript("OnEditFocusGained", function() ghost:Hide() end)

	local sweep = flatButton(parent, "Sweep loaded", 110, 24)
	sweep:SetPoint("LEFT", searchBox, "RIGHT", 10, 0)
	sweep:SetScript("OnClick", function()
		local added = IDs.SweepLoaded()
		toast("Swept " .. added .. " new item(s). DB now holds " .. IDs.ItemCount() .. ".", "00ff00")
		runSearch() -- refresh the Items column with anything new
	end)
	-- item-count readout beside Sweep (shows how full the shared DB is)
	local dbInfo = newText(parent, "OVERLAY", 11)
	dbInfo:SetPoint("LEFT", sweep, "RIGHT", 10, 0)
	dbInfo:SetTextColor(0.54, 0.55, 0.58)
	local function paintDbInfo() dbInfo:SetText(IDs.ItemCount() .. " items in DB") end
	paintDbInfo()

	-- Full scan + Stop are RISKY (a server request per uncached id -> lag/DC), and
	-- rarely needed once the DB is seeded. Hide them behind a small "advanced" link
	-- in the footer; Stop only shows while a scan is actually running.
	local full, stopb -- created later in the footer (forward decl)

	-- (no copy bar / link library / row actions -- the id is right there in each
	--  result row to read. Export DB below is the only copy dialog left.)

	statusFS = newText(parent, "OVERLAY")
	statusFS:SetPoint("TOPLEFT", X, -364)
	statusFS:SetWidth(660)
	statusFS:SetJustifyH("LEFT")

	-- ---- advanced (risky) footer: full item scan, tucked away ----
	-- A small toggle reveals Full scan + Stop. Most people never need it: the
	-- shared DB is seeded and hover/Sweep fills the rest. Full scan fires a
	-- server request per uncached id (lag/DC risk) -- so it's opt-in, not up top.
	local advToggle = flatButton(parent, "advanced", 84, 18)
	advToggle:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", X, 8)
	advToggle.text:SetText("|cff777777advanced +|r")

	full = flatButton(parent, "Full scan", 90, 20, "danger")
	full:SetPoint("LEFT", advToggle, "RIGHT", 8, 0)
	full:SetScript("OnClick", function()
		IDs.FullScan()
		if stopb then stopb:Show() end
	end)
	full:Hide()

	stopb = flatButton(parent, "Stop", 56, 20)
	stopb:SetPoint("LEFT", full, "RIGHT", 8, 0)
	stopb:SetScript("OnClick", function()
		IDs.StopFullScan()
		stopb:Hide()
		paintDbInfo()
	end)
	stopb:Hide()

	-- risk note sits ABOVE the advanced row so buttons don't overlap it
	local advNote = newText(parent, "OVERLAY", 10)
	advNote:SetPoint("BOTTOMLEFT", advToggle, "TOPLEFT", 0, 4)
	advNote:SetTextColor(0.5, 0.42, 0.2)
	advNote:SetText("Full scan brute-forces every item id -- risky (lag/disconnect). Run once, then Export DB to ship the data.")
	advNote:Hide()

	-- Export the whole item DB as a Lua chunk (paste into Okanvil-IDs-Data.lua and
	-- ship it so guildmates open the finder already full -- no scan needed).
	local exportBtn = flatButton(parent, "Export DB", 84, 20)
	exportBtn:SetPoint("LEFT", stopb, "RIGHT", 8, 0)
	exportBtn:Hide()
	exportBtn:SetScript("OnClick", function()
		local chunk, n = IDs.ExportItems()
		-- shell's shared multi-line copy dialog (Ctrl+C, pre-highlighted)
		Okanvil:ShowExport(chunk, "Item DB seed (" .. n .. " items) -> Okanvil-IDs-Data.lua")
	end)

	advToggle:SetScript("OnClick", function()
		local show = not full:IsShown()
		full:SetShown(show)
		exportBtn:SetShown(show)
		advNote:SetShown(show and not IDs.IsScanning())
		advToggle.text:SetText(show and "|cff999999advanced -|r" or "|cff777777advanced +|r")
	end)

	-- route lib status (index build / scan progress) into this panel's status line
	OkanvilIDs._paintStatus = function() if dash then dash:Refresh() end end
	IDs.OnStatus = function(msg)
		if statusFS then statusFS:SetText("|cffaaaaaa" .. msg .. "|r") end
		if dbInfo then paintDbInfo() end
		if dash then dash:Refresh() end
	end

	-- NEVER auto-SetFocus: grabbing the keyboard the moment the page opens steals
	-- W/A/S/D from the game -- if you open the addon mid-fight you can't move and
	-- die. The user clicks the box themselves when they want to type.
	runSearch() -- initial: empty box shows the helper line
end

-- ------------------------------------------------------------
-- universal item harvester (hover any item anywhere -> recorded via the lib)
-- ------------------------------------------------------------
GameTooltip:HookScript("OnTooltipSetItem", function(self)
	if not db then return end
	local _, link = self:GetItem()
	IDs.RecordItem(link)
end)
ItemRefTooltip:HookScript("OnTooltipSetItem", function(self)
	if not db then return end
	local _, link = self:GetItem()
	IDs.RecordItem(link)
end)

-- ------------------------------------------------------------
-- events / boot
-- ------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(_, event, arg1)
	-- Native Okanvil module (lives in the host folder) -- inits on the HOST's load.
	if event == "ADDON_LOADED" and arg1 == "Okanvil" then
		OkanvilIDsDB = OkanvilIDsDB or {}
		for k, v in pairs(defaults) do
			if OkanvilIDsDB[k] == nil then
				OkanvilIDsDB[k] = (type(v) == "table") and {} or v
			end
		end
		db = OkanvilIDsDB
		OkanvilIDsDB.auras = nil -- legacy: aura-catcher removed (auras ARE spells)
		recountItems()
		-- load an optional pre-built item DB shipped with the addon
		-- (Modules/IDs-Data.lua sets the global OkanvilIDs_Seed). New ids only.
		if OkanvilIDs_Seed then
			local n = IDs.MergeSeed(OkanvilIDs_Seed)
			if n > 0 then Print("loaded " .. n .. " seeded item name(s).") end
			OkanvilIDs_Seed = nil -- free it
		end
		-- late-bind the lib onto the host if IDs loaded before Okanvil's Core
		if Okanvil and not Okanvil.IDs then Okanvil.IDs = IDs end
	elseif event == "PLAYER_LOGIN" then
		IDs.SweepLoaded() -- seed the item DB from your own gear/bags once (no server hits)
		-- native module: register into the host (toggle in Modules to hide it)
		Okanvil_Plugins = Okanvil_Plugins or {}
		Okanvil_Plugins[ADDON] = {
			title = "ID Finder",
			desc = "Search spells & items by name to get their ID (a lookup library for WeakAuras).",
			icon = (Okanvil and Okanvil.ICONS and Okanvil.ICONS.ids) or "Interface\\Icons\\INV_Misc_Spyglass_02",
			build = function(panel) buildUI(panel) end,
		}
		if Okanvil and Okanvil.Register then
			Okanvil.IDs = IDs
			Okanvil:Register(ADDON)
			Print("loaded. |cff00ff00/okid|r opens the finder.")
		end
	end
end)

-- ------------------------------------------------------------
-- slash
-- ------------------------------------------------------------
SLASH_OkanvilIDS1 = "/okid"
SLASH_OkanvilIDS2 = "/idfind"
SlashCmdList["OkanvilIDS"] = function(arg)
	arg = string.lower(arg or "")
	if arg == "sweep" then
		local added = IDs.SweepLoaded()
		Print("swept " .. added .. " new item(s). DB now holds " .. IDs.ItemCount() .. ".")
	elseif Okanvil and Okanvil.Toggle then
		Okanvil:Toggle() -- open the Okanvil window (ID Finder is a module in it)
	else
		Print("Okanvil host not loaded.")
	end
end
