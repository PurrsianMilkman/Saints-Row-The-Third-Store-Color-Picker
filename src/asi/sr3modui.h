/* sr3modui.h - SR3 Mod UI API for ASI plugins (Saints Row: The Third, DX11).
 *
 * Header only. Include it, call SR3ModUI_Load() once (e.g. in DllMain), then use the functions.
 * If SR3ModUI.asi is not installed, SR3ModUI_Load() returns 0 and every call is a safe no-op.
 *
 *   #include "sr3modui.h"
 *   static void on_change(const char* page, const char* key, double value, void* user) { ... }
 *   SR3ModUI_Load();
 *   ModUI.AddPage("mymod", "My Mod");
 *   ModUI.AddToggle("mymod", "enabled", "Enabled", 1, on_change, NULL);
 *   ModUI.AddSlider("mymod", "density", "Density", 0, 10, 0.5, 2, on_change, NULL);
 *   double d = ModUI.GetValue("mymod", "density");     // any thread
 *
 * Values are saved to SR3ModUI.ini and restored when you add the widget (read them with GetValue;
 * the callback is not called for the restored value). The callback runs on the game's UI thread
 * when the player changes a value or presses a button. Colours are 0xRRGGBB (sRGB).
 */
#ifndef SR3MODUI_H
#define SR3MODUI_H
#include <windows.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SR3MODUI_VERSION 1

typedef void (__cdecl *SR3ModUI_Callback)(const char* page, const char* key, double value, void* user);

/* Lua bridge: a Lua script calls ModUI.call("name", ...) and your handler runs on the UI thread. */
typedef struct SR3ModUI_Call SR3ModUI_Call;
typedef void (__cdecl *SR3ModUI_Handler)(SR3ModUI_Call* call, void* user);

typedef struct SR3ModUI_Api {
    int    (__cdecl *Version)(void);
    /* pages and widgets; page/key are short ids ([A-Za-z0-9_]), labels are shown as written */
    int    (__cdecl *AddPage)(const char* page, const char* title);
    int    (__cdecl *AddButton)(const char* page, const char* key, const char* label, SR3ModUI_Callback cb, void* user);
    int    (__cdecl *AddToggle)(const char* page, const char* key, const char* label, int def, SR3ModUI_Callback cb, void* user);
    int    (__cdecl *AddSlider)(const char* page, const char* key, const char* label, double min, double max, double step, double def, SR3ModUI_Callback cb, void* user);
    /* options separated by '|', e.g. "Low|Medium|High"; value = 0-based option index */
    int    (__cdecl *AddChoice)(const char* page, const char* key, const char* label, const char* options, int def, SR3ModUI_Callback cb, void* user);
    /* HSL colour picker with colour bars; value = 0xRRGGBB */
    int    (__cdecl *AddColor)(const char* page, const char* key, const char* label, unsigned rgb, SR3ModUI_Callback cb, void* user);
    int    (__cdecl *AddLabel)(const char* page, const char* key, const char* text);
    /* values: thread safe */
    double (__cdecl *GetValue)(const char* page, const char* key);
    void   (__cdecl *SetValue)(const char* page, const char* key, double value);   /* saves; no callback */
    void   (__cdecl *SetLabel)(const char* page, const char* key, const char* label);
    void   (__cdecl *SetEnabled)(const char* page, const char* key, int enabled);
    /* Lua bridge */
    int    (__cdecl *RegisterHandler)(const char* name, SR3ModUI_Handler h, void* user);
    int    (__cdecl *ArgCount)(SR3ModUI_Call* c);
    double (__cdecl *ArgNumber)(SR3ModUI_Call* c, int i);        /* i = 1..ArgCount */
    const char* (__cdecl *ArgString)(SR3ModUI_Call* c, int i);   /* NULL if not a string/number */
    void   (__cdecl *ReturnNumber)(SR3ModUI_Call* c, double v);
    void   (__cdecl *ReturnString)(SR3ModUI_Call* c, const char* s);
    void   (__cdecl *ReturnBool)(SR3ModUI_Call* c, int b);
    void   (__cdecl *Log)(const char* mod, const char* text);    /* SR3ModUI.log */
} SR3ModUI_Api;

#ifndef SR3MODUI_NO_LOADER
/* Filled by SR3ModUI_Load(); all members point at no-ops until then. */
static SR3ModUI_Api ModUI;

static int    __cdecl sr3modui_noop_i(void) { return 0; }
static double __cdecl sr3modui_noop_d(void) { return 0; }

static int SR3ModUI_Load(void) {
    typedef const SR3ModUI_Api* (__cdecl *get_t)(int);
    HMODULE m = GetModuleHandleA("SR3ModUI.asi");
    if (!m) m = LoadLibraryA("SR3ModUI.asi");
    get_t get = m ? (get_t)GetProcAddress(m, "SR3ModUI_GetApi") : NULL;
    const SR3ModUI_Api* api = get ? get(SR3MODUI_VERSION) : NULL;
    if (api) { ModUI = *api; return 1; }
    {   /* not installed: make every member callable */
        void** p = (void**)&ModUI; size_t i;
        for (i = 0; i < sizeof ModUI / sizeof(void*); i++) p[i] = (void*)sr3modui_noop_i;
        ModUI.GetValue = (double (__cdecl*)(const char*, const char*))sr3modui_noop_d;
        ModUI.ArgNumber = (double (__cdecl*)(SR3ModUI_Call*, int))sr3modui_noop_d;
    }
    return 0;
}
#endif /* SR3MODUI_NO_LOADER */

#ifdef __cplusplus
}
#endif
#endif
