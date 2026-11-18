// SR3StoreColorPicker.asi, part 2: true-RGB clothing colours.
//
// The engine colours clothing through the character colour pool (character_color_pool.xtbl): a colour
// slot holds a pool INDEX, the save keeps it as a u8, and the cloth reads the pool record's RGB. So a
// free colour needs a pool record whose RGB we own. tools/build_mod.py fills the pool up to 255
// entries with records named hsl_NN (60 on top of a 195-colour pool, 129 on a vanilla one). Here:
//   * the last two hsl_ records are LIVE slots: while a slider moves we write the exact colour into
//     one of them (alternating, so the engine always sees a changed index) and the store previews it;
//   * the other hsl_ records are CUSTOM slots: "keep" writes the colour into a free one (or reuses one
//     that already holds that colour) and records it in SR3StoreColors.ini next to the exe;
//   * a watcher thread applies the ini to the pool as soon as the table exists (long before a save is
//     loaded) and re-applies it if the table is ever rebuilt.
//
// Pool (DX11, loader 0x00745560): count per pool at 0x0495AB48[pool], record array at 0x0495AB58[pool],
// pool 0 = character_color_pool. Record 0x30 bytes: +0x00 char* name, +0x04 name hash, +0x08 display
// name id, +0x0C authored RGB, +0x18 player RGB, +0x24 ped RGB (floats, xtbl value / 255 - checked in
// game: WHITE reads 1.0). We write all three triples.
//
// Channel from the store UI: debug_print is registered in the interface Lua state and is a no-op in
// the retail build (0x007AE590: lua_gettop, return 0). Its function pointer is the imm32 at 0x00E7DC6C.
// The wrapper answers debug_print("@cp", cmd, r, g, b) and forwards everything else. Colours cross as
// table units (0..255 floats, stored /255). Answers: hello -> free custom slots (number),
// live/keep -> pool index (number); failures -> a string ("nopool", "full", "badcmd"). Without this
// ASI debug_print returns nothing and the store script falls back to the nearest pool colour.
#include "common.h"
#include "sr3modui.h"     // SR3 Mod UI (optional at run time; copy of SR3-ModUI/include/sr3modui.h)
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cmath>

namespace {

const uintptr_t POOL_COUNT    = 0x0495AB48;
const uintptr_t POOL_RECS     = 0x0495AB58;
const uintptr_t DBG_NAME_IMM  = 0x00E7DC64;   // "mov [esp+34h], 125B218h" ("debug_print")
const uintptr_t DBG_NAME_STR  = 0x0125B218;
const uintptr_t DBG_FN_IMM    = 0x00E7DC6C;   // "mov [esp+38h], 7AE590h"
const uintptr_t DBG_ORIG      = 0x007AE590;
const int REC = 0x30;
const int MAXI = 256;

CRITICAL_SECTION g_cs;
char   g_ini[MAX_PATH];
char*  g_recs = nullptr;           // record array the slot table was built for
int    g_count = 0;
int    g_custom[MAXI]; int g_ncustom = 0;  // pool indices of the hsl_ slots except the last two
int    g_live[2] = { -1, -1 }; int g_liveNext = 0;
bool   g_has[MAXI];                // custom slot holds a kept colour
float  g_rgb[MAXI][3];             // kept colour, table units 0..255
char   g_name[MAXI][16];
bool   g_announced = false;

char* recAt(int i) { return g_recs + i * REC; }

void writeRec(int i, const float rgb[3]) {
    float* f = (float*)(recAt(i) + 0x0C);
    for (int t = 0; t < 3; t++)
        for (int c = 0; c < 3; c++) f[t * 3 + c] = rgb[c] / 255.0f;
}

bool recMatches(int i, const float rgb[3]) {
    const float* f = (const float*)(recAt(i) + 0x18);
    for (int c = 0; c < 3; c++) if (fabsf(f[c] - rgb[c] / 255.0f) > 1e-6f) return false;
    return true;
}

// Find hsl_NN records in the current pool. Called with g_cs held.
bool discover() {
    char* recs = readable((void*)POOL_RECS, 4) ? *(char**)POOL_RECS : nullptr;
    int count = readable((void*)POOL_COUNT, 4) ? *(int*)POOL_COUNT : 0;
    if (!recs || count <= 0 || count > MAXI || !readable(recs, count * REC)) return false;
    if (recs == g_recs && count == g_count) return true;
    g_recs = recs; g_count = count; g_ncustom = 0;
    int hsl[MAXI]; int nh = 0;
    for (int i = 0; i < count; i++) {
        const char* nm = *(const char**)recAt(i);
        g_name[i][0] = 0;
        if (readable(nm, 8) && !strncmp(nm, "hsl_", 4)) { hsl[nh++] = i; strncpy(g_name[i], nm, 15); g_name[i][15] = 0; }
    }
    if (nh < 3) { logf("colors: pool has %d entries but only %d hsl_ slots - true RGB disabled", count, nh); g_count = 0; return false; }
    g_live[0] = hsl[nh - 2]; g_live[1] = hsl[nh - 1];
    for (int k = 0; k < nh - 2 && g_ncustom < MAXI; k++) g_custom[g_ncustom++] = hsl[k];
    const float* w = (const float*)(recAt(0) + 0x0C);
    logf("colors: pool %p, %d entries; custom slots %d..%d (%d), live %d,%d; record 0 '%s' rgb %.4f %.4f %.4f",
         recs, count, g_custom[0], g_custom[g_ncustom - 1], g_ncustom, g_live[0], g_live[1],
         *(const char**)recAt(0), w[0], w[1], w[2]);
    for (int i = 0; i < count; i++) {
        const char* nm = *(const char**)recAt(i);
        if (readable(nm, 6) && !strcmp(nm, "WHITE")) {
            const float* f = (const float*)(recAt(i) + 0x0C);
            logf("colors: scale check WHITE (xtbl 255,255,255) = %.4f %.4f %.4f / player %.4f", f[0], f[1], f[2], f[3]);
        }
    }
    return true;
}

void loadIni() {
    FILE* f = fopen(g_ini, "r");
    if (!f) return;
    char line[128]; int n = 0;
    while (fgets(line, sizeof line, f)) {
        char nm[32]; float r, g, b;
        if (sscanf(line, " %31[^= ] = %f %f %f", nm, &r, &g, &b) != 4) continue;
        for (int k = 0; k < g_ncustom; k++) {
            int i = g_custom[k];
            if (!strcmp(g_name[i], nm)) { g_has[i] = true; g_rgb[i][0] = r; g_rgb[i][1] = g; g_rgb[i][2] = b; n++; }
        }
    }
    fclose(f);
    logf("colors: %d kept colours loaded from SR3StoreColors.ini", n);
}

void saveIni() {
    FILE* f = fopen(g_ini, "w");
    if (!f) { logf("colors: cannot write %s", g_ini); return; }
    fprintf(f, "; Custom clothing colours (SR3 Store Colour Picker). slot = R G B in colour-table units (0-255).\n"
               "; Each slot is a colour-table entry your saved clothes point at: deleting a line turns that\n"
               "; colour back into the slot's preset colour.\n");
    for (int k = 0; k < g_ncustom; k++) {
        int i = g_custom[k];
        if (g_has[i]) fprintf(f, "%s = %.3f %.3f %.3f\n", g_name[i], g_rgb[i][0], g_rgb[i][1], g_rgb[i][2]);
    }
    fclose(f);
}

void applyKept() {   // g_cs held, pool discovered
    for (int k = 0; k < g_ncustom; k++) {
        int i = g_custom[k];
        if (g_has[i] && !recMatches(i, g_rgb[i])) writeRec(i, g_rgb[i]);
    }
}

DWORD WINAPI watcher(LPVOID) {
    for (;;) {
        EnterCriticalSection(&g_cs);
        char* before = g_recs;
        if (discover()) {
            if (!g_announced || g_recs != before) { if (!g_announced) loadIni(); g_announced = true; }
            applyKept();
        }
        LeaveCriticalSection(&g_cs);
        Sleep(500);
    }
}

float clamp255(double v) { return v < 0 ? 0.f : v > 255 ? 255.f : (float)v; }

// One command from the store script: hello | live r g b | keep r g b (table units 0..255).
// Returns the answer number (>= 0) or -1 with a failure string in out.
int colorCore(const char* cmd, bool haveRgb, float rgb[3], char out[64]) {
    strcpy(out, "nopool");
    int num = -1;
    int n = haveRgb ? 5 : 2;
    EnterCriticalSection(&g_cs);
    if (cmd && discover()) {
        if (!strcmp(cmd, "hello")) {
            int used = 0;
            for (int k = 0; k < g_ncustom; k++) used += g_has[g_custom[k]];
            num = g_ncustom - used;
            sprintf(out, "%d free of %d", num, g_ncustom);
        } else if (!strcmp(cmd, "live") && n >= 5) {
            int i = g_live[g_liveNext]; g_liveNext ^= 1;
            writeRec(i, rgb);
            num = i; sprintf(out, "%d", i);
        } else if (!strcmp(cmd, "keep") && n >= 5) {
            int pick = -1;
            for (int k = 0; k < g_ncustom && pick < 0; k++) {     // same colour already kept: share it
                int i = g_custom[k];
                if (g_has[i] && fabsf(g_rgb[i][0] - rgb[0]) < 0.05f && fabsf(g_rgb[i][1] - rgb[1]) < 0.05f &&
                    fabsf(g_rgb[i][2] - rgb[2]) < 0.05f) pick = i;
            }
            for (int k = 0; k < g_ncustom && pick < 0; k++)
                if (!g_has[g_custom[k]]) pick = g_custom[k];
            if (pick < 0) {
                strcpy(out, "full");
                logf("colors: keep %.1f %.1f %.1f refused - all %d custom slots are in use", rgb[0], rgb[1], rgb[2], g_ncustom);
            } else {
                bool fresh = !g_has[pick];
                g_has[pick] = true; memcpy(g_rgb[pick], rgb, sizeof rgb);
                writeRec(pick, rgb);
                if (fresh) saveIni();
                num = pick; sprintf(out, "%d", pick);
                logf("colors: keep %.1f %.1f %.1f -> slot %d (%s)%s", rgb[0], rgb[1], rgb[2], pick, g_name[pick], fresh ? "" : " (shared)");
            }
        } else {
            strcpy(out, "badcmd");
        }
    }
    LeaveCriticalSection(&g_cs);
    static int calls = 0;
    if (++calls <= 3 || (cmd && strcmp(cmd, "live"))) logf("colors: %s -> %s", cmd ? cmd : "(nil)", out);
    return num;
}

int colorCommand(void* L, int n) {   // debug_print("@cp", cmd, r, g, b) channel (no SR3 Mod UI)
    const char* cmd = lua_tolstr(L, 2, nullptr);
    char out[64];
    float rgb[3] = { 0, 0, 0 };
    if (n >= 5) for (int c = 0; c < 3; c++) rgb[c] = clamp255(lua_tonum(L, 3 + c));
    int num = colorCore(cmd, n >= 5, rgb, out);
    if (num >= 0) lua_pushnum(L, num); else lua_pushstr(L, out);
    return 1;
}

// SR3 Mod UI handler: ModUI.call("storecolors", cmd, r, g, b)
void __cdecl modUiHandler(SR3ModUI_Call* c, void*) {
    const char* cmd = ModUI.ArgString(c, 1);
    char out[64];
    float rgb[3] = { 0, 0, 0 };
    int n = ModUI.ArgCount(c);
    if (n >= 4) for (int k = 0; k < 3; k++) rgb[k] = clamp255(ModUI.ArgNumber(c, 2 + k));
    int num = colorCore(cmd, n >= 4, rgb, out);
    if (num >= 0) ModUI.ReturnNumber(c, num); else ModUI.ReturnString(c, out);
}

int __cdecl debugPrintWrapper(void* L) {
    int n = lua_gettop(L);
    if (n >= 2) {
        const char* tag = lua_tolstr(L, 1, nullptr);
        if (tag && !strcmp(tag, "@cp")) return colorCommand(L, n);
    }
    return ((lua_fn_t)DBG_ORIG)(L);
}

}  // namespace

void installColors() {
    InitializeCriticalSection(&g_cs);
    strcpy(g_ini, gameDir()); strcat(g_ini, "SR3StoreColors.ini");
    if (SR3ModUI_Load() && ModUI.RegisterHandler("storecolors", modUiHandler, nullptr)) {
        CreateThread(nullptr, 0, watcher, nullptr, 0, nullptr);
        logf("OK colors: SR3 Mod UI found - store script talks to us through ModUI.call(\"storecolors\"); watcher started");
        return;
    }
    const char* nm = (const char*)DBG_NAME_STR;
    if (!readable((void*)DBG_NAME_IMM, 4) || *(uintptr_t*)DBG_NAME_IMM != DBG_NAME_STR || !readable(nm, 12) ||
        strcmp(nm, "debug_print") || !patchImm(DBG_FN_IMM, DBG_ORIG, (uintptr_t)&debugPrintWrapper)) {
        logf("SKIP colors: debug_print registration bytes differ - true RGB disabled (picker will snap to presets)");
        return;
    }
    CreateThread(nullptr, 0, watcher, nullptr, 0, nullptr);
    logf("OK colors: debug_print routed through the colour wrapper; watcher started");
}
