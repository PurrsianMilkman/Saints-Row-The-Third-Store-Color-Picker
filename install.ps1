# Installs (or with -Uninstall removes) the Store Colour Picker into the game folder.
#   powershell -ExecutionPolicy Bypass -File install.ps1 [-Game "C:\Games\Saints Row 3"]
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
# Needs Python 3 (builds the game-side files from YOUR game install, tools\build_mod.py) and the
# plugin at out\SR3StoreColorPicker.asi (build.bat) or next to this script (release zip).
# The game must be closed (the .asi is locked while it runs).
# Needs SR3 Mod UI (SR3ModUI.asi + SR3ModUI\ in the game folder): the picker's UI is built with it. The
# script SR3ModUI\mods\store_color_picker.lua hooks the stock clothing store; no store file is replaced.
# https://github.com/PurrsianMilkman/Saints-Row-The-Third-Mod-UI
param([switch]$Uninstall, [string]$Game = 'C:\Games\Saints Row 3')
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (Get-Process SaintsRow* -ea 0) { 'The game is running - close it first.'; exit 1 }
if (-not (Test-Path "$Game\SaintsRowTheThird_DX11.exe")) { "No SaintsRowTheThird_DX11.exe in '$Game' - pass -Game <folder>"; exit 1 }
$backup = Join-Path $here 'backup\character_color_pool.xtbl.installed-before'
$installed = 'character_color_pool.xtbl', 'sr3_city.lua', 'SR3StoreColorPicker.asi'
$v01 = 'store_clothing.str2_pc', 'patch_vint_doc_containers.asm_pc'   # v0.1 built its own store UI into these

# leftovers from development builds
foreach ($n in 'store_clothing.lua', 'SR3StoreTeleport.asi', 'SR3StoreTeleport.log') { Remove-Item "$Game\$n" -ea 0 }

$modui = (Test-Path "$Game\SR3ModUI.asi") -and (Test-Path "$Game\SR3ModUI\modui.lua")
$script = "$Game\SR3ModUI\mods\store_color_picker.lua"

# the v0.1 store files replace the clothing store with the old built-in picker: remove them together (the
# loose .asm_pc holds the size record of that .str2_pc), but only when the .str2_pc is the v0.1 one
function Remove-V01 {
    if (-not (Test-Path "$Game\store_clothing.str2_pc")) { return }
    python "$here\tools\build_mod.py" --v01 "$Game"
    if ($LASTEXITCODE -eq 0) { foreach ($n in $v01) { Remove-Item "$Game\$n" -ea 0 }; 'removed the v0.1 store files (store_clothing.str2_pc, patch_vint_doc_containers.asm_pc)' }
    else { "NOTE: $Game\store_clothing.str2_pc is from another mod - left in place; if it replaces the clothing store, the picker will not appear" }
}

if ($Uninstall) {
    foreach ($n in $installed + 'SR3StoreColorPicker.log') { if ($n -ne 'character_color_pool.xtbl') { Remove-Item "$Game\$n" -ea 0 } }
    Remove-Item $script -ea 0
    Remove-V01
    if (Test-Path $backup) { Copy-Item $backup "$Game\character_color_pool.xtbl" -Force; 'restored character_color_pool.xtbl from backup' }
    else { Remove-Item "$Game\character_color_pool.xtbl" -ea 0; 'removed character_color_pool.xtbl (the game falls back to its packed one)' }
    'kept SR3StoreColors.ini (your custom colours); delete it by hand if you are not reinstalling'
    'uninstalled'; exit 0
}

if (-not $modui) {
    'SR3 Mod UI is not installed in this game folder - install it first:'
    '  https://github.com/PurrsianMilkman/Saints-Row-The-Third-Mod-UI'
    'nothing installed'; exit 1
}

# 1. keep the colour pool another mod may have installed, before we ever overwrite it
$loose = "$Game\character_color_pool.xtbl"
if (-not (Test-Path $backup) -and (Test-Path $loose) -and -not (Select-String -Path $loose -Pattern '<Name>hsl_' -Quiet)) {
    New-Item -ItemType Directory -Force (Split-Path $backup) | Out-Null
    Copy-Item $loose $backup
    "backed up the existing colour pool to $backup"
}

# 2. build the game-side files from this game install
python "$here\tools\build_mod.py" "$Game"
if ($LASTEXITCODE -ne 0) { 'build failed - nothing installed'; exit 1 }

# 3. copy
$asi = @("$here\out\SR3StoreColorPicker.asi", "$here\SR3StoreColorPicker.asi") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $asi) { 'SR3StoreColorPicker.asi not found - run build.bat or use the release zip'; exit 1 }
$files = [ordered]@{
    'character_color_pool.xtbl'             = "$here\mod\character_color_pool.xtbl"
    'sr3_city.lua'                          = "$here\mod\sr3_city.lua"
    'SR3StoreColorPicker.asi'               = $asi
    'SR3ModUI\mods\store_color_picker.lua' = "$here\src\modui\store_color_picker.lua"
}
New-Item -ItemType Directory -Force "$Game\SR3ModUI\mods" | Out-Null
Remove-V01
foreach ($k in $files.Keys) {
    Copy-Item $files[$k] "$Game\$k" -Force
    $a = (Get-FileHash $files[$k]).Hash; $b = (Get-FileHash "$Game\$k").Hash
    '{0,-40} {1}  {2}' -f $k, $(if ($a -eq $b) { 'OK ' } else { 'HASH MISMATCH' }), $b.Substring(0, 16)
}
if (-not (Get-ChildItem $Game -Filter dinput8.dll -ea 0)) { 'NOTE: no dinput8.dll in the game folder - install an ASI loader (Ultimate ASI Loader) or the plugin will not load' }
