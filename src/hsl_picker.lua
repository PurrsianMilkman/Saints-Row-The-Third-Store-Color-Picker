

-------------------------------------------------------------------------------
-- [StoreColorPicker] HSL colour picker for clothing colour slots
-------------------------------------------------------------------------------
-- TRUE RGB (with SR3StoreColorPicker.asi): the engine colours clothing through a pool INDEX per slot,
-- so the ASI owns a few pool records whose RGB it rewrites. While a slider moves, the exact colour is
-- written to a live record and previewed; "Result" keeps it in a custom record the ASI remembers in
-- SR3StoreColors.ini. The channel is debug_print("@cp", ...), a no-op in the retail game.
-- FALLBACK (no ASI): the sliders snap to the nearest of the pool's 255 colours, as in v1.
--
-- Appearance model (tools/gen_palette.py): the cloth shader shows a table value v as
-- Reinhard(5 * v/255), so v = 255 is the brightest the cloth gets. Slider colours are sRGB; they are
-- linearised, scaled into that range and inverted through the Reinhard curve to table units.

local HSL_TINT = 5
local HSL_TOP = HSL_TINT / (1 + HSL_TINT)
local HSL_SEGS = 24				-- segments per colour bar
local HSL_BAR_W = 156				-- width of the slider's fill (vdo_slider.lua width_max)

local Hsl_pool = {}			-- snapping fallback: { index, red, green, blue, dr, dg, db }
local Hsl_menu = nil
local Hsl_row = nil
local Hsl_slot = 0
local Hsl_prev = nil
local Hsl_true = false			-- the ASI answered: exact colours
local Hsl_rgb = nil			-- last exact colour sent, table units
local Hsl_result = { red = 1, green = 1, blue = 1 }
local Hsl_bars = {}

local HSL_ROW_HUE = 1
local HSL_ROW_SAT = 2
local HSL_ROW_LUM = 3
local HSL_ROW_RESULT = 4

local function hsl_max3(a, b, c)
	local m = a
	if b > m then m = b end
	if c > m then m = c end
	return m
end

local function hsl_min3(a, b, c)
	local m = a
	if b < m then m = b end
	if c < m then m = c end
	return m
end

local function hsl_hue2rgb(p, q, t)
	if t < 0 then t = t + 1 end
	if t > 1 then t = t - 1 end
	if t < 1 / 6 then return p + (q - p) * 6 * t end
	if t < 1 / 2 then return q end
	if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
	return p
end

-- h 0..360, s and l 0..1  ->  sRGB 0..1
local function hsl_to_rgb(h, s, l)
	if s <= 0 then
		return l, l, l
	end
	local q
	if l < 0.5 then
		q = l * (1 + s)
	else
		q = l + s - l * s
	end
	local p = 2 * l - q
	local hh = h / 360
	return hsl_hue2rgb(p, q, hh + 1 / 3), hsl_hue2rgb(p, q, hh), hsl_hue2rgb(p, q, hh - 1 / 3)
end

-- sRGB 0..1  ->  h 0..360, s and l 0..1
local function rgb_to_hsl(r, g, b)
	local mx = hsl_max3(r, g, b)
	local mn = hsl_min3(r, g, b)
	local l = (mx + mn) / 2
	local d = mx - mn
	if d < 0.00001 then
		return 0, 0, l
	end
	local s
	if l > 0.5 then
		s = d / (2 - mx - mn)
	else
		s = d / (mx + mn)
	end
	local h
	if mx == r then
		h = (g - b) / d
		if g < b then h = h + 6 end
	elseif mx == g then
		h = (b - r) / d + 2
	else
		h = (r - g) / d + 4
	end
	return h * 60, s, l
end

local function srgb_to_lin(c)
	if c <= 0.04045 then return c / 12.92 end
	return ((c + 0.055) / 1.055) ^ 2.4
end

local function lin_to_srgb(c)
	if c <= 0.0031308 then return c * 12.92 end
	return 1.055 * c ^ (1 / 2.4) - 0.055
end

-- table channel (0..1 of 255) -> displayed sRGB channel 0..1
local function hsl_display(x)
	if x < 0 then x = 0 end
	local a = (HSL_TINT * x / (1 + HSL_TINT * x)) / HSL_TOP
	if a > 1 then a = 1 end
	return lin_to_srgb(a)
end

-- displayed sRGB channel 0..1 -> table units 0..255
local function hsl_table_units(c)
	local l = srgb_to_lin(c) * HSL_TOP
	if l >= HSL_TOP then return 255 end
	local v = 255 * l / (HSL_TINT * (1 - l))
	if v > 255 then v = 255 end
	return v
end

local function hsl_snap(v, step, lo, hi)
	v = floor(v / step + 0.5) * step
	if v < lo then v = lo end
	if v > hi then v = hi end
	return v
end

-- Callback from pcu_report_item_colors: one pool colour per call.
function store_clothing_hsl_pool_add(color_index, label_crc, label_str, red, green, blue)
	Hsl_pool[#Hsl_pool + 1] = { index = color_index, red = red, green = green, blue = blue }
end

local function hsl_find(index)
	for i = 1, #Hsl_pool do
		if Hsl_pool[i].index == index then
			return Hsl_pool[i]
		end
	end
	return nil
end

-- Ask the ASI; a number back means yes (hello: free custom slots, live/keep: pool index). Anything
-- else (nil from the retail no-op debug_print, or a failure string) means no.
local function hsl_asi(cmd, r, g, b)
	if debug_print == nil then return nil end
	local res = debug_print("@cp", cmd, r, g, b)
	if type(res) == "number" then return res end
	return nil
end

-------------------------------------------------------------------------------
-- colour bars: each slider's fill is replaced by HSL_SEGS tinted copies of itself
-------------------------------------------------------------------------------
local function hsl_bar_color(row, t)
	local h = Hsl_menu[HSL_ROW_HUE].current_value
	local s = Hsl_menu[HSL_ROW_SAT].current_value / 100
	local l = Hsl_menu[HSL_ROW_LUM].current_value / 100
	if row == HSL_ROW_HUE then
		return hsl_to_rgb(t * 360, 1, 0.5)
	elseif row == HSL_ROW_SAT then
		return hsl_to_rgb(h, t, l)
	end
	return hsl_to_rgb(h, s, t)
end

local HSL_NAMES = { [HSL_ROW_HUE] = "Hue", [HSL_ROW_SAT] = "Saturation", [HSL_ROW_LUM] = "Luminance" }

-- "Hue  251": the value lives in the row label (the slider's own number sat on top of the bar).
local function hsl_label(row)
	return HSL_NAMES[row] .. "  " .. floor(Hsl_menu[row].current_value + 0.5)
end

-- Lay out, recolour and re-show every piece of every bar, move the marker, update the label.
-- Everything is re-applied on each paint, so nothing the stock slider code did in between survives.
-- Geometry is in the fill's own units (v3.0 layout: anchor step == segment size, contiguous).
local function hsl_paint_bars()
	if Hsl_menu == nil then return end
	for row, bar in pairs(Hsl_bars) do
		local item = Hsl_menu[row]
		for k = 1, HSL_SEGS do
			local seg = bar.parts[k]
			local r, g, b = hsl_bar_color(row, (k - 0.5) / HSL_SEGS)
			seg:set_actual_size(bar.seg_w + 0.75, bar.h)
			seg:set_anchor(bar.x + (k - 1) * bar.seg_w, bar.y)
			seg:set_color(r, g, b)
			seg:set_depth(bar.depth)
			seg:set_alpha(1)
		end
		local t = (item.current_value - item.min) / (item.max - item.min)
		local mx = bar.x + t * HSL_BAR_W
		local out, inn = bar.parts[HSL_SEGS + 1], bar.parts[HSL_SEGS + 2]
		out:set_actual_size(3, bar.h)
		out:set_anchor(mx - 1.5, bar.y)
		-- vint draws lower depth in front (hint text -100, highlighted button -10); at equal depth the
		-- order is arbitrary, which hid the marker behind some segments
		out:set_color(0.05, 0.05, 0.05)
		out:set_depth(bar.depth - 1)
		out:set_alpha(1)
		inn:set_actual_size(1.2, bar.h)
		inn:set_anchor(mx - 0.6, bar.y)
		inn:set_color(1, 1, 1)
		inn:set_depth(bar.depth - 2)
		inn:set_alpha(1)
		for _, o in pairs(bar.hide) do
			o:set_alpha(0)
		end
		item.label = hsl_label(row)
		if bar.button.set_label ~= nil then
			bar.button:set_label(item.label)
		end
	end
end

local function hsl_piece(left, sl)
	local o = Vdo_base_object:clone(left.handle, sl.handle, sl.doc_handle)
	o:set_visible(true)
	return o
end

local function hsl_build_bars()
	Hsl_bars = {}
	if Active_list == nil or Active_list.buttons == nil then return end
	for row = HSL_ROW_HUE, HSL_ROW_LUM do
		local b = Active_list.buttons[row]
		if b ~= nil and b.slider ~= nil then
			local sl = b.slider
			local left = Vdo_base_object:new("slider_bg_left", sl.handle, sl.doc_handle)
			local right = Vdo_base_object:new("slider_bg_right", sl.handle, sl.doc_handle)
			local value = Vdo_base_object:new("slider_value", sl.handle, sl.doc_handle)
			local x, y = left:get_anchor()
			local w, h = left:get_actual_size()
			local depth = left:get_depth()
			if type(depth) ~= "number" then depth = 0 end
			local bar = { parts = {}, x = x, y = y, h = h, depth = depth, seg_w = HSL_BAR_W / HSL_SEGS, button = b,
				hide = { left, right, value } }
			-- parts 1..HSL_SEGS = colour segments, then the marker's dark and white lines
			for k = 1, HSL_SEGS + 2 do
				bar.parts[k] = hsl_piece(left, sl)
			end
			-- The stock slider (vdo_slider.lua) finds its fill BY NAME on every value/highlight change,
			-- resizes it to the value and paints it purple. Clones share that name, so the lookup can land
			-- on one of ours (v3.0: the last segment, the purple bar past the right end). A hidden decoy
			-- takes the hit instead; if the lookup still lands on a visible piece, that piece becomes a
			-- decoy too and is replaced. The stock code never sets alpha, so a decoy stays invisible.
			local decoys = { hsl_piece(left, sl) }
			for _ = 1, 4 do
				local f = Vdo_base_object:new("slider_bg_left", sl.handle, sl.doc_handle)
				local hit = nil
				for k = 1, #bar.parts do
					if bar.parts[k].handle == f.handle then hit = k end
				end
				if hit == nil then break end
				decoys[#decoys + 1] = bar.parts[hit]
				bar.parts[hit] = hsl_piece(left, sl)
			end
			for _, o in pairs(decoys) do
				o:set_actual_size(0.01, h)
				bar.hide[#bar.hide + 1] = o
			end
			Hsl_bars[row] = bar
		end
	end
	hsl_paint_bars()
end

-- Repaint the Result swatch; fall back to redrawing the list if the button is not reachable.
local function hsl_refresh_swatch()
	local b = nil
	if Active_list ~= nil and Active_list.buttons ~= nil then
		b = Active_list.buttons[HSL_ROW_RESULT]
	end
	if b ~= nil and b.toggle_color ~= nil then
		b.toggle_color:set_color_value(Hsl_result)
	else
		store_clothing_populate_list(Menu_data, Active_list:get_selection())
		hsl_build_bars()
	end
end

local function hsl_set_slot(index, red, green, blue)
	local c = Store_clothing_item_info.colors[Hsl_slot]
	local changed = c.index ~= index
	c.index = index
	c.red = red
	c.green = green
	c.blue = blue
	return changed
end

-- Snap a target sRGB colour to the nearest pool colour (fallback mode).
local function hsl_nearest(tr, tg, tb)
	local best = nil
	local best_d = 0
	for i = 1, #Hsl_pool do
		local e = Hsl_pool[i]
		local dr = e.dr - tr
		local dg = e.dg - tg
		local db = e.db - tb
		local rm = (e.dr + tr) * 0.5		-- "redmean": cheap perceptual RGB distance
		local d = (2 + rm) * dr * dr + 4 * dg * dg + (3 - rm) * db * db
		if best == nil or d < best_d then
			best = e
			best_d = d
		end
	end
	return best
end

-- Apply the slider colour: exact through the ASI, else the nearest pool colour.
local function hsl_apply()
	if Hsl_menu == nil then
		return
	end
	local h = Hsl_menu[HSL_ROW_HUE].current_value
	local s = Hsl_menu[HSL_ROW_SAT].current_value / 100
	local l = Hsl_menu[HSL_ROW_LUM].current_value / 100
	local tr, tg, tb = hsl_to_rgb(h, s, l)

	local done = false
	if Hsl_true then
		local vr, vg, vb = hsl_table_units(tr), hsl_table_units(tg), hsl_table_units(tb)
		local idx = hsl_asi("live", vr, vg, vb)
		if idx ~= nil then
			Hsl_rgb = { vr, vg, vb }
			hsl_set_slot(idx, vr / 255, vg / 255, vb / 255)
			store_clothing_item_preview(true)		-- live slots alternate, so the index always changes
			Hsl_result.red, Hsl_result.green, Hsl_result.blue = tr, tg, tb
			done = true
		end
	end
	if not done and #Hsl_pool > 0 then
		local best = hsl_nearest(tr, tg, tb)
		Hsl_rgb = nil
		if hsl_set_slot(best.index, best.red, best.green, best.blue) then
			store_clothing_item_preview(true)
		end
		Hsl_result.red, Hsl_result.green, Hsl_result.blue = best.dr, best.dg, best.db
	end
	hsl_refresh_swatch()
	hsl_paint_bars()
end

function store_clothing_hsl_update(menu_data)
	hsl_apply()
end

-- Back/Esc: put the slot back to the colour it had when the picker opened.
function store_clothing_hsl_cancel(menu_data)
	if Hsl_prev ~= nil then
		hsl_set_slot(Hsl_prev.index, Hsl_prev.red, Hsl_prev.green, Hsl_prev.blue)
		store_clothing_item_preview(true)
	end
	Hsl_menu = nil
	Hsl_bars = {}
end

-- Keep the colour and return to the item menu. An exact colour moves from the live record to a
-- custom record; if all custom records are taken it falls back to the nearest pool colour.
function store_clothing_hsl_accept(menu_data)
	if Hsl_true and Hsl_rgb ~= nil then
		local idx = hsl_asi("keep", Hsl_rgb[1], Hsl_rgb[2], Hsl_rgb[3])
		if idx ~= nil then
			hsl_set_slot(idx, Hsl_rgb[1] / 255, Hsl_rgb[2] / 255, Hsl_rgb[3] / 255)
		else
			local best = hsl_nearest(Hsl_result.red, Hsl_result.green, Hsl_result.blue)
			hsl_set_slot(best.index, best.red, best.green, best.blue)
		end
		store_clothing_item_preview(true)
	end
	Hsl_menu = nil
	Hsl_prev = nil
	Hsl_bars = {}
	store_common_back_menu()
end

-- Open the game's original swatch grid for this slot (exact pick).
function store_clothing_hsl_grid(menu_data)
	local row = Hsl_row
	store_clothing_hsl_cancel(menu_data)
	Hsl_prev = nil
	store_common_back_menu()
	store_clothing_color_select(row)
end

function store_clothing_hsl_enter(menu_data)
	hsl_build_bars()
end

-- on_sub_menu_fill for a colour row of the item details menu.
function store_clothing_hsl_fill(menu_data)
	Hsl_row = menu_data
	Hsl_slot = menu_data.id
	local cur = Store_clothing_item_info.colors[Hsl_slot]
	Hsl_prev = { index = cur.index, red = cur.red, green = cur.green, blue = cur.blue }
	Hsl_rgb = nil
	Hsl_true = hsl_asi("hello") ~= nil

	-- the whole pool, with its displayed colours (fallback snapping and the starting colour)
	Hsl_pool = {}
	pcu_report_item_colors("store_clothing_hsl_pool_add", Store_clothing_item_info.item_index)
	local scale = 1
	for i = 1, #Hsl_pool do
		local e = Hsl_pool[i]
		if e.red > 1.001 or e.green > 1.001 or e.blue > 1.001 then
			scale = 1 / 255
		end
	end
	for i = 1, #Hsl_pool do
		local e = Hsl_pool[i]
		e.dr = hsl_display(e.red * scale)
		e.dg = hsl_display(e.green * scale)
		e.db = hsl_display(e.blue * scale)
	end

	-- start the sliders on the slot's current colour
	local h, s, l = 0, 0, 0.5
	local e = hsl_find(cur.index)
	if e ~= nil then
		h, s, l = rgb_to_hsl(e.dr, e.dg, e.db)
		Hsl_result.red = e.dr
		Hsl_result.green = e.dg
		Hsl_result.blue = e.db
	end

	local result_label = "Result (select to keep)"
	if not Hsl_true then
		result_label = "Nearest preset (select to keep)"
	end
	local m = Store_common_sub_menu
	m[HSL_ROW_HUE] = { type = TYPE_SLIDER, label = "Hue", min = 0, max = 359, step = 3,
		current_value = hsl_snap(h, 1, 0, 359), on_value_update = store_clothing_hsl_update, on_cancel = store_clothing_hsl_cancel }
	m[HSL_ROW_SAT] = { type = TYPE_SLIDER, label = "Saturation", min = 0, max = 100, step = 2,
		current_value = hsl_snap(s * 100, 1, 0, 100), on_value_update = store_clothing_hsl_update, on_cancel = store_clothing_hsl_cancel }
	m[HSL_ROW_LUM] = { type = TYPE_SLIDER, label = "Luminance", min = 0, max = 100, step = 2,
		current_value = hsl_snap(l * 100, 1, 0, 100), on_value_update = store_clothing_hsl_update, on_cancel = store_clothing_hsl_cancel }
	m[HSL_ROW_RESULT] = { type = TYPE_TOGGLE_COLOR, label = result_label, color = Hsl_result,
		on_select = store_clothing_hsl_accept, on_cancel = store_clothing_hsl_cancel }
	m[5] = { type = TYPE_BUTTON, label = "Swatch grid", on_select = store_clothing_hsl_grid, on_cancel = store_clothing_hsl_cancel }
	m.on_enter = store_clothing_hsl_enter
	Hsl_menu = m
	for row = HSL_ROW_HUE, HSL_ROW_LUM do
		m[row].label = hsl_label(row)
	end
	Hsl_bars = {}
end
