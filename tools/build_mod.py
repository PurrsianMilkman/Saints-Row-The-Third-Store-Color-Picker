"""Build every game-side file of the mod from YOUR game install (no game files ship in this repo).

    python tools/build_mod.py "C:/Games/Saints Row 3"      -> writes mod/

Reads (never writes) the game folder:
  packfiles/pc/cache/patch_uncompressed.vpp_pc   store_clothing.str2_pc, patch_vint_doc_containers.asm_pc
  packfiles/pc/cache/misc.vpp_pc                 sr3_city.lua
  character_color_pool.xtbl (loose, if another mod installed one) else misc_tables.vpp_pc's copy
If backup/character_color_pool.xtbl.installed-before exists (install.ps1 makes it before first
overwriting the loose pool) that is the source instead, so rebuilding never stacks colours twice.

Writes mod/: character_color_pool.xtbl (+palette_report.txt), store_clothing.lua,
store_clothing.str2_pc, patch_vint_doc_containers.asm_pc, sr3_city.lua.
"""
import os, sys, hashlib
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from srvpp import Pack
import build_str2, gen_palette


def pack_file(path, name):
    with open(path, 'rb') as f:
        data = f.read()
    for n, blob, _ in Pack(data).read_all():
        if n.lower() == name.lower():
            return blob
    raise SystemExit(f'{name} not found in {path}')


def patch_store_lua(src):
    old = b"\t\t\t\t\tcolor = c[i],\r\n\t\t\t\t\ton_select = store_clothing_color_select,\r\n"
    new = (b"\t\t\t\t\tcolor = c[i],\r\n\t\t\t\t\ton_sub_menu_fill = store_clothing_hsl_fill,"
           b"\t-- [StoreColorPicker] was on_select = store_clothing_color_select\r\n")
    if src.count(old) != 1:
        raise SystemExit('store_clothing.lua: colour-row anchor not found (unexpected game version)')
    add = open(os.path.join(ROOT, 'src', 'hsl_picker.lua'), 'rb').read().replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')
    return src.replace(old, new) + add


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

    # originals from the player's own packs
    str2 = pack_file(os.path.join(cache, 'patch_uncompressed.vpp_pc'), 'store_clothing.str2_pc')
    asm = pack_file(os.path.join(cache, 'patch_uncompressed.vpp_pc'), 'patch_vint_doc_containers.asm_pc')
    city = pack_file(os.path.join(cache, 'misc.vpp_pc'), 'sr3_city.lua')
    for n, b in (('store_clothing.str2_pc', str2), ('patch_vint_doc_containers.asm_pc', asm)):
        open(os.path.join(tmp, n), 'wb').write(b)

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

    # scripts
    _, files = build_str2.read_str2(str2)
    lua = patch_store_lua(dict(files)['store_clothing.lua'])
    open(os.path.join(out, 'store_clothing.lua'), 'wb').write(lua)
    open(os.path.join(out, 'sr3_city.lua'), 'wb').write(patch_city_lua(city))
    build_str2.main(os.path.join(tmp, 'store_clothing.str2_pc'), os.path.join(tmp, 'patch_vint_doc_containers.asm_pc'),
                    os.path.join(out, 'store_clothing.lua'), os.path.join(out, 'store_clothing.str2_pc'),
                    os.path.join(out, 'patch_vint_doc_containers.asm_pc'))

    for n in ('character_color_pool.xtbl', 'store_clothing.str2_pc', 'patch_vint_doc_containers.asm_pc', 'sr3_city.lua'):
        h = hashlib.sha256(open(os.path.join(out, n), 'rb').read()).hexdigest()[:16].upper()
        print(f'  mod/{n:34} {h}')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    main(sys.argv[1])
