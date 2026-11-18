-------------------------------------------------------------------------------------------------------
-- Store Colour Picker - SR3 Mod UI script (goes in <game>\SR3ModUI\mods\).
-- In the clothing stores, each colour slot of an item opens an HSL editor (ModUI.HslEditor) instead of
-- the swatch grid. No game file is modified: the store's item menu is hooked with ModUI.wrap.
--
-- TRUE RGB (with SR3StoreColorPicker.asi): the engine colours clothing through a pool INDEX per slot, so
-- the ASI owns a few pool records whose RGB it rewrites. While a slider moves, the exact colour goes to a
-- live record and is previewed; "Result" keeps it in a custom record saved in SR3StoreColors.ini. The
-- channel is ModUI.call("storecolors", cmd, r, g, b).
-- FALLBACK (no ASI): the sliders snap to the nearest of the pool's colours.
--
-- Appearance model (tools/gen_palette.py): the cloth shader shows a table value v as Reinhard(5 * v/255).
-- Slider colours are sRGB; they are linearised, scaled into that range and inverted to table units.
-------------------------------------------------------------------------------------------------------
local TINT = 5
local TOP = TINT / (1 + TINT)

local Pool = {}			-- { index, red, green, blue, dr, dg, db }: the item's colour pool (dr.. = shown sRGB)
local Ed = nil			-- the open HslEditor
local Slot = 0			-- colour slot being edited
local Row = nil			-- the item-menu row that opened the editor
local Prev = nil		-- slot colour when the editor opened
local Exact = false		-- the ASI answered: exact colours
local Rgb = nil			-- last exact colour sent, table units
local Shown = { red = 1, green = 1, blue = 1 }

local function srgb_to_lin(c)
	if c <= 0.04045 then return c / 12.92 end
	return ((c + 0.055) / 1.055) ^ 2.4
end
local function lin_to_srgb(c)
	if c <= 0.0031308 then return c * 12.92 end
	return 1.055 * c ^ (1 / 2.4) - 0.055
end
-- table channel (0..1 of 255) -> displayed sRGB 0..1
local function display(x)
	if x < 0 then x = 0 end
	local a = (TINT * x / (1 + TINT * x)) / TOP
	if a > 1 then a = 1 end
	return lin_to_srgb(a)
end
-- displayed sRGB 0..1 -> table units 0..255
local function table_units(c)
	local l = srgb_to_lin(c) * TOP
	if l >= TOP then return 255 end
	local v = 255 * l / (TINT * (1 - l))
	if v > 255 then v = 255 end
	return v
end

-- a number back means yes (hello: free custom slots, live/keep: pool index); anything else means no
local function asi(cmd, r, g, b)
	local res = ModUI.call("storecolors", cmd, r, g, b)
	if type(res) == "number" then return res end
	return nil
end

-- pcu_report_item_colors callback (by global name): one pool colour per call
function store_color_picker_pool_add(color_index, label_crc, label_str, red, green, blue)
	Pool[#Pool + 1] = { index = color_index, red = red, green = green, blue = blue }
end

local function find(index)
	for i = 1, #Pool do
		if Pool[i].index == index then return Pool[i] end
	end
	return nil
end

local function nearest(tr, tg, tb)
	local best, best_d = nil, 0
	for i = 1, #Pool do
		local e = Pool[i]
		local dr, dg, db = e.dr - tr, e.dg - tg, e.db - tb
		local rm = (e.dr + tr) * 0.5		-- "redmean" perceptual distance
		local d = (2 + rm) * dr * dr + 4 * dg * dg + (3 - rm) * db * db
		if best == nil or d < best_d then best, best_d = e, d end
	end
	return best
end

local function set_slot(index, red, green, blue)
	local c = Store_clothing_item_info.colors[Slot]
	local changed = c.index ~= index
	c.index, c.red, c.green, c.blue = index, red, green, blue
	return changed
end

-- the editor's colour changed: exact through the ASI, else the nearest pool colour
local function apply(tr, tg, tb)
	if Exact then
		local vr, vg, vb = table_units(tr), table_units(tg), table_units(tb)
		local idx = asi("live", vr, vg, vb)
		if idx ~= nil then
			Rgb = { vr, vg, vb }
			set_slot(idx, vr / 255, vg / 255, vb / 255)
			store_clothing_item_preview(true)		-- live slots alternate, so the index always changes
			return
		end
	end
	if #Pool > 0 then
		local best = nearest(tr, tg, tb)
		Rgb = nil
		if set_slot(best.index, best.red, best.green, best.blue) then store_clothing_item_preview(true) end
		Shown.red, Shown.green, Shown.blue = best.dr, best.dg, best.db	-- show the preset it snapped to
		Ed.rgb.red, Ed.rgb.green, Ed.rgb.blue = best.dr, best.dg, best.db
		Ed:paint()
	end
end

local function on_value_update(menu_data)
	if Ed ~= nil then Ed:changed() end
end

-- Back/Esc: put the slot back to the colour it had when the editor opened
local function on_cancel(menu_data)
	if Prev ~= nil then
		set_slot(Prev.index, Prev.red, Prev.green, Prev.blue)
		store_clothing_item_preview(true)
	end
	Ed = nil
end

-- keep the colour: an exact colour moves from the live record to a custom one (nearest preset if full)
local function on_accept(menu_data)
	if Exact and Rgb ~= nil then
		local idx = asi("keep", Rgb[1], Rgb[2], Rgb[3])
		if idx ~= nil then
			set_slot(idx, Rgb[1] / 255, Rgb[2] / 255, Rgb[3] / 255)
		else
			local best = nearest(Ed.rgb.red, Ed.rgb.green, Ed.rgb.blue)
			set_slot(best.index, best.red, best.green, best.blue)
		end
		store_clothing_item_preview(true)
	end
	Ed, Prev = nil, nil
	store_common_back_menu()
end

-- the game's own swatch grid for this slot
local function on_grid(menu_data)
	local row = Row
	on_cancel(menu_data)
	Prev = nil
	store_common_back_menu()
	store_clothing_color_select(row)
end

local function on_enter(menu_data)
	if Ed ~= nil then Ed:attach(Active_list, 1) end
end

-- on_sub_menu_fill for a colour row of the item menu
local function fill(menu_data)
	Row = menu_data
	Slot = menu_data.id
	local cur = Store_clothing_item_info.colors[Slot]
	Prev = { index = cur.index, red = cur.red, green = cur.green, blue = cur.blue }
	Rgb = nil
	Exact = asi("hello") ~= nil

	Pool = {}
	pcu_report_item_colors("store_color_picker_pool_add", Store_clothing_item_info.item_index)
	local scale = 1
	for i = 1, #Pool do
		local e = Pool[i]
		if e.red > 1.001 or e.green > 1.001 or e.blue > 1.001 then scale = 1 / 255 end
	end
	for i = 1, #Pool do
		local e = Pool[i]
		e.dr, e.dg, e.db = display(e.red * scale), display(e.green * scale), display(e.blue * scale)
	end

	local r, g, b = 0.5, 0.5, 0.5
	local e = find(cur.index)
	if e ~= nil then r, g, b = e.dr, e.dg, e.db end
	Ed = ModUI.HslEditor.new{ r = r, g = g, b = b, on_change = apply }

	local label = "Result (select to keep)"
	if not Exact then label = "Nearest preset (select to keep)" end
	local rows = Ed:make_rows(label, { on_cancel = on_cancel })
	local m = Store_common_sub_menu
	for i = 1, 3 do
		rows[i].on_value_update = on_value_update
		m[i] = rows[i]
	end
	rows[4].on_select = on_accept
	m[4] = rows[4]
	m[5] = { type = TYPE_BUTTON, label = "Swatch grid", on_select = on_grid, on_cancel = on_cancel }
	m.on_enter = on_enter
end

-- After the store builds an item's menu, point its colour rows at the editor instead of the grid.
ModUI.wrap("store_clothing_item_details", function(orig, menu_data)
	local a, b = orig(menu_data)
	local m = Store_common_sub_menu
	if m ~= nil then
		for i = 1, #m do
			local it = m[i]
			if type(it) == "table" and it.type == TYPE_TOGGLE_COLOR and it.on_select == store_clothing_color_select then
				it.on_select = nil
				it.on_sub_menu_fill = fill
			end
		end
	end
	return a, b
end)

-- also listed in Pause > MODS so players can see it is installed
local page = ModUI.page("store_color_picker", "Store Colour Picker")
page:label("info1", "In clothing stores: item > colour")
page:label("info2", "HSL sliders, live preview")
page:on_open(function(p)
	local free = asi("hello")
	if free ~= nil then
		p:set_label("info3", "True RGB: " .. free .. " slots free")
	else
		p:set_label("info3", "No plugin: presets only")
	end
end)
page:label("info3", "")
