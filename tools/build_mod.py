"""Build every game-side file of the mod from YOUR game install (no game files ship in this repo).

    python tools/build_mod.py "C:/Games/Saints Row 3"      -> writes mod/

    python tools/build_mod.py --v01 "C:/Games/Saints Row 3"
        exit 0 if the game folder holds the v0.1 store files (a loose store_clothing.str2_pc with the
        old built-in picker); install.ps1 then removes them, because they would replace the SR3 Mod UI
        picker with the v0.1 one.

The picker's UI is SR3 Mod UI (src/modui/store_color_picker.lua hooks the stock store at run time), so
no store file is rebuilt. Reads (never writes) the game folder:
  packfiles/pc/cache/misc.vpp_pc                 sr3_city.lua
  character_color_pool.xtbl (loose, if another mod installed one) else misc_tables.vpp_pc's copy
If backup/character_color_pool.xtbl.installed-before exists (install.ps1 makes it before first
overwriting the loose pool) that is the source instead, so rebuilding never stacks colours twice.

Writes mod/: character_color_pool.xtbl (+palette_report.txt), sr3_city.lua.
"""
import os, sys, hashlib
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from srvpp import Pack
import build_str2, gen_palette   # build_str2: only read_str2, to recognise the v0.1 files


def pack_file(path, name):
    with open(path, 'rb') as f:
        data = f.read()
    for n, blob, _ in Pack(data).read_all():
        if n.lower() == name.lower():
            return blob
    raise SystemExit(f'{name} not found in {path}')


def patch_city_lua(src):
    old = b"function sr3_city_main()\r\n\r\nend\r\n"
    new = (b"function sr3_city_main()\r\n"
           b"\t-- [StoreTeleport] F7 = nearest clothing store, Shift+F7 = next store (needs SR3StoreColorPicker.asi)\r\n"
           b"\tthread_new(\"sr3_store_teleport_thread\")\r\n"
           b"end\r\n\r\n"
           b"-- [StoreTeleport] Polls the hotkey once per frame on the script thread. SR3StoreColorPicker.asi answers\r\n"
           b"-- teleport_to_object calls whose target starts with '@'; without the ASI there is no object\r\n"
           b"-- named \"@tick\" and the call does nothing.\r\n"
           b"function sr3_store_teleport_thread()\r\n"
           b"\twhile true do\r\n"
           b"\t\tteleport_to_object(LOCAL_PLAYER, \"@tick\")\r\n"
           b"\t\tthread_yield()\r\n"
           b"\tend\r\n"
           b"end\r\n")
    if src.count(old) != 1:
        raise SystemExit('sr3_city.lua: sr3_city_main anchor not found (unexpected game version)')
    return src.replace(old, new)


def main(game):
    cache = os.path.join(game, 'packfiles', 'pc', 'cache')
    out = os.path.join(ROOT, 'mod')
    tmp = os.path.join(out, 'orig')
    os.makedirs(tmp, exist_ok=True)

    city = pack_file(os.path.join(cache, 'misc.vpp_pc'), 'sr3_city.lua')

    # colour pool source: backup of the pre-mod loose pool > loose pool > packed pool
    backup = os.path.join(ROOT, 'backup', 'character_color_pool.xtbl.installed-before')
    loose = os.path.join(game, 'character_color_pool.xtbl')
    if os.path.exists(backup):
        pool_src, why = backup, 'backup of the pool that was installed before this mod'
    elif os.path.exists(loose) and b'<Name>hsl_' not in open(loose, 'rb').read():
        pool_src, why = loose, 'loose pool in the game folder (from another mod)'
    else:
        pool_src = os.path.join(tmp, 'character_color_pool.xtbl')
        open(pool_src, 'wb').write(pack_file(os.path.join(cache, 'misc_tables.vpp_pc'), 'character_color_pool.xtbl'))
        why = 'the game\'s packed pool'
    print(f'colour pool: {why}')
    gen_palette.main(pool_src, os.path.join(out, 'character_color_pool.xtbl'), os.path.join(out, 'palette_report.txt'))

    open(os.path.join(out, 'sr3_city.lua'), 'wb').write(patch_city_lua(city))

    for n in ('character_color_pool.xtbl', 'sr3_city.lua'):
        h = hashlib.sha256(open(os.path.join(out, n), 'rb').read()).hexdigest()[:16].upper()
        print(f'  mod/{n:34} {h}')


def is_v01_store(game):
    """True if the game folder's loose store_clothing.str2_pc carries the v0.1 built-in picker."""
    path = os.path.join(game, 'store_clothing.str2_pc')
    if not os.path.exists(path):
        return False
    try:
        _, files = build_str2.read_str2(open(path, 'rb').read())
    except Exception:
        return False
    return b'store_clothing_hsl_fill' in dict(files).get('store_clothing.lua', b'')


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--v01':
        sys.exit(0 if is_v01_store(sys.argv[2]) else 1)
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    main(sys.argv[1])
