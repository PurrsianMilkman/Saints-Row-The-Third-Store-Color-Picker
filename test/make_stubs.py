import re, sys
t = open('mod/character_color_pool.xtbl').read()
rows = []
for i, e in enumerate(re.findall(r'<Color_Entry>.*?</Color_Entry>', t, re.S)):
    nm = re.search(r'<Name>([^<]*)', e).group(1)
    r, g, b = (int(re.search(rf'<{c}>(\d+)', e).group(1)) for c in 'RGB')
    rows.append(f'{{{i},"{nm}",{r},{g},{b}}}')
asi = sys.argv[1] == 'asi'   # simulate the ASI answering debug_print("@cp", ...)
open('test/stubs.lua', 'w').write(f'''
floor = math.floor; sqrt = math.sqrt
TYPE_BUTTON = 0; TYPE_TOGGLE = 1; TYPE_SLIDER = 2; TYPE_TOGGLE_COLOR = 4
POOL = {{ {",".join(rows)} }}
function pcu_report_item_colors(cb, item)
  for _, p in ipairs(POOL) do _G[cb](p[1], nil, p[2], p[3]/255, p[4]/255, p[5]/255) end
end
Store_clothing_item_info = {{ item_index = 7, colors = {{ [0] = {{ index = 0 }}, [1] = {{}}, [2] = {{}} }} }}
do local p = POOL[1]; local c = Store_clothing_item_info.colors[0]; c.red, c.green, c.blue = p[3]/255, p[4]/255, p[5]/255 end
Store_common_sub_menu = {{}}
PREVIEWS = 0; function store_clothing_item_preview() PREVIEWS = PREVIEWS + 1 end
BACKS = 0; function store_common_back_menu() BACKS = BACKS + 1 end
GRID = nil; function store_clothing_color_select(row) GRID = row end
SWATCH = nil
-- vint object stubs
OBJS = {{}}
local Obj = {{}}; Obj.__index = Obj
function Obj:get_anchor() return 30, 0 end
function Obj:get_actual_size() return 80, 12 end
function Obj:get_depth() return 5 end
function Obj:get_scale() return 1.4, 1.4 end
function Obj:set_actual_size(w, h) self.w, self.h = w, h end
function Obj:set_anchor(x, y) self.x, self.y = x, y end
function Obj:set_depth(d) self.depth = d end
function Obj:set_alpha(a) self.alpha = a end
function Obj:set_visible(v) self.visible = v end
function Obj:set_color(r, g, b) self.tint = {{r, g, b}} end
Vdo_base_object = {{}}
function Vdo_base_object:new(name, parent) local o = setmetatable({{ name = name, parent = parent, handle = #OBJS + 1 }}, Obj); OBJS[#OBJS + 1] = o; return o end
function Vdo_base_object:clone(h, parent) local o = setmetatable({{ name = "clone", parent = parent, handle = #OBJS + 1 }}, Obj); OBJS[#OBJS + 1] = o; return o end
local function slider(i) return {{ handle = 100 + i, doc_handle = 1 }} end
LABELS = {{}}
local function btn(i) return {{ slider = slider(i), set_label = function(self, t) LABELS[i] = t end }} end
Active_list = {{ buttons = {{ [1] = btn(1), [2] = btn(2), [3] = btn(3),
  [4] = {{ toggle_color = {{ set_color_value = function(self, c) SWATCH = {{c.red, c.green, c.blue}} end }} }} }} }}
ASI_LOG = {{}}
''' + ('''
LIVE = {201, 202}; LIVE_NEXT = 1; KEPT = {}; NEXT_FREE = 150
function debug_print(tag, cmd, r, g, b)
  if tag ~= "@cp" then return end
  ASI_LOG[#ASI_LOG + 1] = {cmd, r, g, b}
  if cmd == "hello" then return 58 end
  if cmd == "live" then local i = LIVE[LIVE_NEXT]; LIVE_NEXT = 3 - LIVE_NEXT; return i end
  if cmd == "keep" then NEXT_FREE = NEXT_FREE + 1; return NEXT_FREE end
  return "badcmd"
end
''' if asi else '''
function debug_print() end   -- retail no-op
'''))
