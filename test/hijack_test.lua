-- Simulates the game: a lookup of "slider_bg_left" returns the NEWEST clone under that slider (v3.0 symptom).
local orig_new = Vdo_base_object.new
function Vdo_base_object:new(name, parent, doc)
  if name == "slider_bg_left" then
    for i = #OBJS, 1, -1 do local o = OBJS[i]; if o.name == "clone" and o.parent == parent then return o end end
  end
  return orig_new(self, name, parent, doc)
end
store_clothing_hsl_fill({ id = 0 }); local m = Store_common_sub_menu; m.on_enter(m)
-- the stock vdo_slider:set_value + set_highlight on each slider
for i = 1, 3 do local f = Vdo_base_object:new("slider_bg_left", 100 + i); f:set_actual_size(120, 12); f:set_color(0.5, 0, 0.8) end
local purple_visible = 0
for _, o in ipairs(OBJS) do if o.tint and o.tint[1] == 0.5 and o.tint[3] == 0.8 and o.alpha ~= 0 then purple_visible = purple_visible + 1 end end
print(purple_visible == 0 and "pass: hijacked object is a hidden decoy, no purple bar shows" or ("FAIL: " .. purple_visible .. " purple pieces visible"))
