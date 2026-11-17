"""Syntax-check Lua files and run a Lua test script, using OBS's lua51.dll (LuaJIT, Lua 5.1 syntax).
    python tools/luacheck.py check FILE...      compile only
    python tools/luacheck.py run FILE...        load and run in order in one state (stdlib opened)"""
import ctypes, sys, os
# Any 64-bit Lua 5.1 / LuaJIT DLL works (OBS Studio ships one). Override with LUA51_DLL=<path>.
DLL = os.environ.get('LUA51_DLL', r'C:\Program Files\obs-studio\bin\64bit\lua51.dll')
os.add_dll_directory(os.path.dirname(DLL))
L = ctypes.CDLL(DLL)
L.luaL_newstate.restype = ctypes.c_void_p
L.luaL_loadbuffer.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p]
L.lua_tolstring.restype = ctypes.c_char_p
L.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
L.lua_pcall.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int]
L.luaL_openlibs.argtypes = [ctypes.c_void_p]
L.lua_settop.argtypes = [ctypes.c_void_p, ctypes.c_int]
S = L.luaL_newstate(); L.luaL_openlibs(S)
mode, files = sys.argv[1], sys.argv[2:]
bad = 0
for f in files:
    src = open(f, 'rb').read()
    if L.luaL_loadbuffer(S, src, len(src), ('@' + f).encode()) != 0:
        print('SYNTAX', L.lua_tolstring(S, -1, None).decode()); bad += 1; continue
    if mode == 'check':
        print('ok', f); L.lua_settop(S, 0); continue
    if L.lua_pcall(S, 0, 0, 0) != 0:
        print('RUNTIME', L.lua_tolstring(S, -1, None).decode()); bad += 1
sys.exit(bad)
