// SR3StoreColorPicker.asi, part 1: shared helpers, DllMain, and the store teleport test helper.
// F7 teleports the player to the nearest clothing store, Shift+F7 to the next one in the list.
// SaintsRowTheThird_DX11.exe only.
//
// How the teleport works. The Lua binding teleport_to_object (handler 0x00A60440) is registered once at
// start-up from a table whose function pointer is the imm32 at 0x00A242B0. We point that slot at a
// wrapper: a target name beginning with '@' is ours, anything else goes to the original handler. The
// patched sr3_city.lua runs a script thread that calls teleport_to_object(LOCAL_PLAYER, "@tick") every
// frame, so the hotkey is polled and the teleport runs on the game's own script thread. Without this
// ASI that call finds no object named "@tick" and returns.
//
// The teleport itself is the engine call teleport_to_object makes (0x00A606F3):
//   0x009E1740(human, &pos, &orient3x3, 1, 1, exit_vehicle, id16 = 0x006F50B0(human, 4, 0), 1, 1, 0)
// Landing points are each store's floor-level entrance navpoint (tools/store_navs.py).
#include "common.h"
#include "sr3modui.h"
#include <cstdio>
#include <cstring>
#include <cstdarg>
#include <cmath>

int         (__cdecl *lua_gettop)(void*)               = (int (__cdecl*)(void*))0x00E02050;
const char* (__cdecl *lua_tolstr)(void*, int, size_t*)  = (const char* (__cdecl*)(void*, int, size_t*))0x00E02410;
double      (__cdecl *lua_tonum)(void*, int)           = (double (__cdecl*)(void*, int))0x00E02360;
void        (__cdecl *lua_pushstr)(void*, const char*)  = (void (__cdecl*)(void*, const char*))0x00E02620;
void        (__cdecl *lua_pushnum)(void*, double)       = (void (__cdecl*)(void*, double))0x00E025A0;   // seen in trigger_get_radius

static char g_dir[MAX_PATH];
static char g_log[MAX_PATH];
const char* gameDir() { return g_dir; }

void logf(const char* fmt, ...) {
    FILE* f = fopen(g_log, "a");
    if (!f) return;
    SYSTEMTIME t; GetLocalTime(&t);
    fprintf(f, "%02d:%02d:%02d.%03d ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
    va_list a; va_start(a, fmt); vfprintf(f, fmt, a); va_end(a);
    fputc('\n', f);
    fclose(f);
}

bool readable(const void* p, size_t n) {
    MEMORY_BASIC_INFORMATION m;
    return p && VirtualQuery(p, &m, sizeof m) && m.State == MEM_COMMIT &&
           !(m.Protect & (PAGE_NOACCESS | PAGE_GUARD)) && (const char*)p + n <= (const char*)m.BaseAddress + m.RegionSize;
}

bool patchImm(uintptr_t at, uintptr_t expect, uintptr_t value) {
    if (!readable((void*)at, 4) || *(uintptr_t*)at != expect) return false;
    DWORD old;
    VirtualProtect((void*)at, 4, PAGE_EXECUTE_READWRITE, &old);
    *(uintptr_t*)at = value;
    VirtualProtect((void*)at, 4, old, &old);
    FlushInstructionCache(GetCurrentProcess(), (void*)at, 4);
    return true;
}

namespace {

// ---- DX11 addresses (checked before use) ----
const uintptr_t REG_FN_IMM   = 0x00A242B0;   // imm32 of "mov [esp+1A78h], 0A60440h" in the Lua registration table
const uintptr_t REG_NAME_IMM = 0x00A242A5;   // imm32 of the preceding "mov [esp+1A74h], 117C8FCh"
const uintptr_t NAME_STR     = 0x0117C8FC;   // "teleport_to_object"
const uintptr_t ORIG_HANDLER = 0x00A60440;
const uintptr_t FIND_HUMAN   = 0x00A273A0;   // (name, 0) -> object*   (accepts "#PLAYER1#")
const uintptr_t GET_ID16     = 0x006F50B0;   // (object*, 4, 0) -> u16
const uintptr_t TELEPORT     = 0x009E1740;   // see header
const uintptr_t CLASS_TABLE  = 0x061EE7E0;   // class descriptor table, indexed by object byte +0x34

typedef void*    (__cdecl *find_human_t)(const char*, int);
typedef unsigned (__cdecl *get_id16_t)(void*, int, int);
typedef void     (__cdecl *teleport_t)(void*, float*, float*, int, int, int, int, int, int, int);

struct Store { const char* name; float x, y, z; };
// Landing points: the floor-level navpoint at each store's entrance (ref/store_navs.txt), NOT the
// shop_object itself, which sits up at the sign and dropped the player onto the awning (v1 bug).
// Planet Saints is one prefab: its entrance nav is 2.4 m from the shop_object and ~4 m lower, the
// same spot as Let's Pretend's named "GPS Nav 1". y is up.
const Store STORES[] = {
    { "Planet Saints (int_dt_ps)",       -521.77f, 14.41f,  -86.56f },
    { "Planet Saints (int_dt_ps2)",       383.88f,  8.86f,  838.51f },
    { "Planet Saints (int_ne_psaints)", -1526.04f, 18.65f, -507.99f },
    { "Planet Saints (nw_planetsaints)", 1714.12f,  6.78f, -474.17f },
    { "Planet Saints (sw_planetsaints)", 1792.42f, 12.75f,  182.96f },
    { "Nobody Loves Me (int_nw_nobody)", 1168.88f, 11.15f, -532.66f },
    { "Let's Pretend (GPS Nav 1)",       1220.60f, 12.57f,  967.01f },
    { "Leather & Lace (ne_leather)",    -1251.44f, 10.40f, -800.63f },
};
const int NSTORES = sizeof(STORES) / sizeof(STORES[0]);

long  g_ticks = 0;
bool  g_keyWasDown = false;
int   g_cycle = -1;
int   g_verifyIn = 0;          // ticks until the post-teleport position is logged
int   g_verifyStore = -1;

bool gameHasFocus() {
    DWORD pid = 0;
    GetWindowThreadProcessId(GetForegroundWindow(), &pid);
    return pid == GetCurrentProcessId();
}

void* localPlayer() { return ((find_human_t)FIND_HUMAN)("#PLAYER1#", 0); }

bool playerPos(void* h, float out[3]) {
    if (!readable((char*)h + 0x40, 12)) return false;
    memcpy(out, (char*)h + 0x40, 12);
    return true;
}

bool isHumanClass(void* h) {
    if (!readable((char*)h + 0x34, 1)) return false;
    unsigned char type = *((unsigned char*)h + 0x34);
    char* desc = *(char**)(CLASS_TABLE + type * 4);
    return readable(desc + 0xA, 1) && (desc[0xA] & 2);
}

int nearestStore(const float p[3]) {
    int best = 0; float bd = 0;
    for (int i = 0; i < NSTORES; i++) {
        float dx = STORES[i].x - p[0], dy = STORES[i].y - p[1], dz = STORES[i].z - p[2];
        float d = dx * dx + dy * dy + dz * dz;
        if (i == 0 || d < bd) { bd = d; best = i; }
    }
    return best;
}

void teleportTo(int si) {
    void* h = localPlayer();
    if (!h) { logf("teleport: no local player"); return; }
    if (!isHumanClass(h)) { logf("teleport: player object %p is not human-class, refusing", h); return; }
    float from[3] = { 0, 0, 0 };
    playerPos(h, from);
    float pos[3] = { STORES[si].x, STORES[si].y + 0.1f, STORES[si].z };
    float orient[9] = { 1, 0, 0,  0, 1, 0,  0, 0, 1 };
    unsigned id16 = ((get_id16_t)GET_ID16)(h, 4, 0) & 0xFFFF;
    logf("teleport: %s  from (%.1f, %.1f, %.1f) to (%.1f, %.1f, %.1f)  id16=%u",
         STORES[si].name, from[0], from[1], from[2], pos[0], pos[1], pos[2], id16);
    ((teleport_t)TELEPORT)(h, pos, orient, 1, 1, 1 /*exit vehicle*/, (int)id16, 1, 1, 0);
    g_verifyIn = 120;           // about 2 s of ticks later, log where the player actually is
    g_verifyStore = si;
}

volatile LONG g_tpRequest = 0;    // set by the MODS page button (UI thread), served here (script thread)

void __cdecl onTeleportButton(const char*, const char*, double, void*) { InterlockedExchange(&g_tpRequest, 1); }

void tick() {
    if (++g_ticks == 1) logf("first @tick from sr3_city.lua: the script thread is running");
    if (InterlockedExchange(&g_tpRequest, 0)) {
        void* h = localPlayer(); float p[3];
        if (h && playerPos(h, p)) { logf("MODS button: teleport to the nearest clothing store"); teleportTo(nearestStore(p)); }
    }
    if (g_verifyIn > 0 && --g_verifyIn == 0) {
        float p[3];
        void* h = localPlayer();
        if (h && playerPos(h, p)) {
            const Store& s = STORES[g_verifyStore];
            float dx = p[0] - s.x, dz = p[2] - s.z;
            logf("verify: player now at (%.1f, %.1f, %.1f), %.1f m (horizontal) from %s",
                 p[0], p[1], p[2], sqrtf(dx * dx + dz * dz), s.name);
        }
    }
    bool down = (GetAsyncKeyState(VK_F7) & 0x8000) != 0;
    bool pressed = down && !g_keyWasDown;
    g_keyWasDown = down;
    if (!pressed || !gameHasFocus()) return;

    int target;
    if (GetAsyncKeyState(VK_SHIFT) & 0x8000) {
        g_cycle = (g_cycle + 1) % NSTORES;
        target = g_cycle;
    } else {
        void* h = localPlayer();
        float p[3];
        if (!h || !playerPos(h, p)) { logf("F7: no player position"); return; }
        target = nearestStore(p);
    }
    teleportTo(target);
}

int __cdecl teleportToObjectWrapper(void* L) {
    int n = lua_gettop(L);
    if (n >= 2) {
        const char* target = lua_tolstr(L, 2, nullptr);
        if (target && target[0] == '@') {
            if (!strcmp(target, "@tick")) tick();
            else if (!strcmp(target, "@nearest_clothing")) {
                void* h = localPlayer(); float p[3];
                if (h && playerPos(h, p)) teleportTo(nearestStore(p));
            }
            return 0;
        }
    }
    return ((lua_fn_t)ORIG_HANDLER)(L);
}

}  // namespace

void installTeleport() {
    const unsigned char want[] = { 0xC7, 0x84, 0x24, 0x78, 0x1A, 0x00, 0x00, 0x40, 0x04, 0xA6, 0x00 };
    const char* nm = (const char*)NAME_STR;
    if (!readable((void*)(REG_FN_IMM - 7), sizeof want) || memcmp((void*)(REG_FN_IMM - 7), want, sizeof want) ||
        !readable((void*)REG_NAME_IMM, 4) || *(uintptr_t*)REG_NAME_IMM != NAME_STR ||
        !readable(nm, 19) || strcmp(nm, "teleport_to_object")) {
        logf("SKIP teleport: not the DX11 executable this was built for (registration bytes differ)");
        return;
    }
    if (!patchImm(REG_FN_IMM, ORIG_HANDLER, (uintptr_t)&teleportToObjectWrapper)) { logf("SKIP teleport: patch failed"); return; }
    logf("OK teleport: teleport_to_object routed through the wrapper (F7 nearest clothing store, Shift+F7 next store)");
    if (SR3ModUI_Load()) {   // a button on the picker's page in Pause > MODS (the page itself comes from its script)
        ModUI.AddButton("store_color_picker", "teleport", "Teleport to a clothing store", onTeleportButton, nullptr);
        logf("OK teleport: button added to the SR3 Mod UI page");
    }
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(inst);
        GetModuleFileNameA(nullptr, g_dir, MAX_PATH);
        char* slash = strrchr(g_dir, '\\');
        if (slash) slash[1] = 0;
        strcpy(g_log, g_dir); strcat(g_log, "SR3StoreColorPicker.log");
        DeleteFileA(g_log);
        logf("SR3StoreColorPicker loaded in %s", g_dir);
        installTeleport();
        installColors();
    }
    return TRUE;
}
