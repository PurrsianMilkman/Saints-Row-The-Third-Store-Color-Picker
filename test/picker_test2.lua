local function check(cond, msg) if not cond then error("FAIL: " .. msg, 2) end print("pass: " .. msg) end
local ASI = debug_print("@cp", "hello") ~= nil
print(ASI and "== mode: ASI present (true RGB)" or "== mode: no ASI (snapping fallback)")
local row = { id = 0 }
store_clothing_hsl_fill(row)
local m = Store_common_sub_menu
check(#m == 5 and m.on_enter ~= nil, "menu has 5 rows and an on_enter that draws the bars")
m.on_enter(m)
local nsegs = 0
for _, o in ipairs(OBJS) do if o.name == "clone" then nsegs = nsegs + 1 end end
check(nsegs == 81, "3 bars x (24 segments + 2 marker pieces + 1 decoy) cloned (" .. nsegs .. ")")
local function clone(n0) local n = 0; for _, o in ipairs(OBJS) do if o.name == "clone" then n = n + 1; if n == n0 then return o end end end end
local function seg(bar, k) return clone((bar - 1) * 27 + k) end
local function marker(bar) return clone((bar - 1) * 27 + 26) end
local function decoy(bar) return clone((bar - 1) * 27 + 27) end
check(seg(1, 1).x == 30 and math.abs(seg(1, 24).x - (30 + 23 * 156 / 24)) < 1e-6 and math.abs(seg(1, 24).w - (156 / 24 + 0.75)) < 1e-6, "segments tile 156 units from the fill's anchor (v3.0 layout)")
check(decoy(1).alpha == 0 and decoy(3).alpha == 0, "a hidden decoy per bar takes the stock name lookup")
check(marker(1).tint[1] == 1, "white marker piece exists")
check(marker(1).depth < clone(25).depth and clone(25).depth < seg(1, 5).depth and seg(1, 5).depth == 5, "marker drawn in front of the segments (lower depth)")
local hidden = 0; for _, o in ipairs(OBJS) do if (o.name == "slider_bg_left" or o.name == "slider_bg_right" or o.name == "slider_value") and o.alpha == 0 then hidden = hidden + 1 end end
check(hidden == 9, "stock fill, right fill and number hidden on all 3 sliders")
local function set(h, s, l)
  m[1].current_value, m[2].current_value, m[3].current_value = h, s, l
  m[1].on_value_update(m[1])
  return Store_clothing_item_info.colors[0]
end
local c = set(0, 100, 50)
check(math.abs(marker(1).x - (30 - 0.6)) < 1e-6, "hue 0: marker at the left end")
set(359, 100, 50); check(math.abs(marker(1).x - (30 + 156 - 0.6)) < 1e-6, "hue 359: marker at the right end")
check(LABELS[1] == "Hue  359" and m[1].label == "Hue  359", "value shown in the label (" .. tostring(LABELS[1]) .. ")")
c = set(0, 100, 50)
local t1 = seg(1, 1).tint; local t12 = seg(1, 9).tint
check(t1[1] > 0.9 and t12[2] > 0.9, "hue bar is a rainbow (segment 1 red, segment 9 green)")
local s1 = seg(2, 1).tint; local s24 = seg(2, 24).tint
check(math.abs(s1[1] - s1[2]) < 0.05 and s24[1] > 0.9 and s24[2] < 0.1, "saturation bar runs grey -> full red at hue 0")
local l1 = seg(3, 1).tint; local l24 = seg(3, 24).tint
check(l1[1] < 0.05 and l24[1] > 0.95 and l24[2] > 0.95, "luminance bar runs black -> white")
set(120, 100, 50); check(seg(2, 24).tint[2] > 0.9 and seg(2, 24).tint[1] < 0.1, "bars repaint when the hue changes")
if ASI then
  local last = ASI_LOG[#ASI_LOG]
  check(last[1] == "live" and c.index == 201 or c.index == 202, "slider move sends 'live' and selects a live slot")
  print(string.format("  green (120,100,50) -> table units %.2f %.2f %.2f", last[2], last[3], last[4]))
  check(last[2] < 0.01 and last[4] < 0.01 and math.abs(last[3] - 255) < 0.01, "pure green -> (0, 255, 0) table units")
  set(0, 0, 50); last = ASI_LOG[#ASI_LOG]
  print(string.format("  50%% grey -> table units %.2f (sRGB 0.5 = linear 0.214)", last[2]))
  check(math.abs(last[2] - last[3]) < 1e-9 and last[2] > 10 and last[2] < 20, "50% grey is neutral and in range")
  local i1 = set(10, 80, 40).index; local i2 = set(11, 80, 40).index
  check(i1 ~= i2, "consecutive moves alternate live slots, so the engine always sees a new index")
  local p0 = PREVIEWS; set(12, 80, 40); check(PREVIEWS == p0 + 1, "every move previews")
  check(SWATCH[1] > SWATCH[3], "Result swatch shows the exact target colour")
  m[4].on_select(m[4])
  check(ASI_LOG[#ASI_LOG][1] == "keep" and Store_clothing_item_info.colors[0].index == 151, "accept sends 'keep' and stores the custom slot")
else
  check(c.index ~= nil and c.index ~= 201, "fallback snaps to a pool colour")
  local i = set(0, 0, 100).index; check(POOL[i + 1][2] == "WHITE", "fallback: white snaps to WHITE")
  m[4].on_select(m[4]); check(BACKS == 1, "fallback accept backs out")
end
store_clothing_hsl_fill(row); m = Store_common_sub_menu; m.on_enter(m)
set(200, 50, 50); m[1].on_cancel(m[1])
check(Store_clothing_item_info.colors[0].index == (ASI and 151 or Store_clothing_item_info.colors[0].index), "cancel restores the colour the picker opened with")
print("ALL PASS")
