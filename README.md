# Saints Row: The Third - Store Colour Picker

A true-RGB colour picker for the clothing stores in **Saints Row: The Third (PC, DX11)**. Instead of
the fixed swatch grid, every colour slot of a clothing item gets **Hue / Saturation / Luminance**
sliders with colour bars, a live preview on your character and the exact colour you picked.

Also included: an **F7 teleport** to the nearest clothing store (a testing helper).

> No game files are distributed here. `install.ps1` builds the modified game files from **your own**
> game install.

## What it does

| | |
|---|---|
| **Where** | Clothing stores: Planet Saints (all 5), Nobody Loves Me, Let's Pretend, Leather & Lace. Pick an item, then *Primary / Secondary / Tertiary colour*. |
| **Sliders** | Hue 0-359, Saturation 0-100, Luminance 0-100, each with a colour bar and a marker; the value is shown in the row label. |
| **Result** | Shows the colour; selecting it keeps the colour for that slot. **Back** restores the colour the slot had. |
| **Swatch grid** | Opens the game's original grid if you want a preset. |
| **F7 / Shift+F7** | Teleport to the nearest clothing store's entrance / cycle through all 8. |

### Why it needs a plugin for true RGB

The game never stores a colour for clothing: each colour slot stores an **index into a colour table**
(`character_color_pool.xtbl`), and the save keeps that index in **one byte**, so the table can hold at
most 255 colours. The mod fills the table up to 255 with extra entries; the plugin
(`SR3StoreColorPicker.asi`) then rewrites those entries in memory:

- two entries are **live slots**: while you drag a slider the exact colour is written there and previewed;
- the rest are **custom slots**: when you keep a colour it moves into one and is saved to
  `SR3StoreColors.ini` in the game folder; on every launch the plugin restores them before your save loads.

Limits that follow from the one-byte index:

- **Custom colours at once** = 255 minus the size of your colour table minus 2: **127** with the
  vanilla table, **58** if another colour mod already added 69 colours. Items in the same colour share
  a slot. When all are used, keeping a new colour falls back to the nearest existing one.
- Clothes in a custom colour depend on the plugin and the ini. Without the plugin those slots show
  their preset colours (the picker still works, snapping to the nearest of the 255 colours).
- In the swatch grid, don't pick the last two swatches: they are the live slots.

## Install

Requirements: the **DX11** executable (`SaintsRowTheThird_DX11.exe`), an **ASI loader**
(`dinput8.dll`, e.g. Ultimate ASI Loader), **Python 3** on PATH.

1. Close the game.
2. Build the plugin with `build.bat` (Visual Studio 2022 Build Tools, x86), or take
   `SR3StoreColorPicker.asi` from a release and put it next to `install.ps1`.
3. Run:
   ```
   powershell -ExecutionPolicy Bypass -File install.ps1 -Game "C:\Games\Saints Row 3"
   ```

The installer backs up an existing loose `character_color_pool.xtbl` (from another colour mod) to
`backup\` before replacing it, builds the files from your game's packfiles, copies them and checks
their hashes.

**Uninstall:** `install.ps1 -Uninstall` (restores the colour table; keeps `SR3StoreColors.ini`).

### Files it puts in the game folder

| File | What |
|---|---|
| `character_color_pool.xtbl` | your colour table, unchanged, plus `hsl_NN` entries up to 255 |
| `store_clothing.str2_pc` + `patch_vint_doc_containers.asm_pc` | the store's UI container rebuilt with the picker script, and its size record. A loose `.lua` is **not** read for scripts inside a `.str2_pc`, so the container itself is rebuilt. |
| `sr3_city.lua` | the city script plus a thread that polls the F7 hotkey |
| `SR3StoreColorPicker.asi` | the plugin (true RGB + teleport); writes `SR3StoreColorPicker.log` |
| `SR3StoreColors.ini` | created when you keep your first custom colour |

## Status

| | |
|---|---|
| Picker, sliders, colour bars, marker | confirmed in game |
| Exact colour written to the live slots while dragging | confirmed in game (plugin log) |
| Kept colours saved and restored before the save loads | confirmed in game |
| F7 teleport lands at the store entrance | confirmed in game (all 8 points are floor-level entrance navpoints; Planet Saints tested) |
| DX9 executable | not supported (the plugin checks the DX11 bytes and does nothing on anything else) |
| Co-op | untested |

## How it works (for modders)

- `src/hsl_picker.lua` is appended to the game's patched `store_clothing.lua`; the colour rows open
  it instead of the grid. The store UI reaches the plugin through `debug_print("@cp", ...)`, which is
  a no-op in the retail game. The plugin wraps it (and `teleport_to_object` in the gameplay state)
  by swapping the function pointer in the Lua registration table.
- Colour bars are clones of the slider's fill image. The stock slider looks its fill up **by name**
  on every change, which can land on a clone; hidden decoy clones absorb that lookup.
- Colour model: the cloth shader shows a table value `v` as `Reinhard(5 * v/255)`; sliders are sRGB,
  converted to linear, scaled into that range and inverted through the curve.
- `tools/build_str2.py` rebuilds a compressed+condensed `.str2_pc` (one zlib level-9 stream, a sync
  flush after each file, no final block) and patches its `.asm_pc` record; run with `-` as the Lua
  file it reproduces the original files byte for byte.
- Tests: `python tools/build_mod.py <game>` then `python test/make_stubs.py asi` and
  `python tools/luacheck.py run test/stubs.lua src/hsl_picker.lua test/picker_test2.lua`
  (`luacheck.py` loads a Lua 5.1 DLL; set its path at the top).

## License

MIT. Saints Row: The Third is © Deep Silver / Volition; this repository contains none of its files.
