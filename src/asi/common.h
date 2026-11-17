// Shared by teleport.cpp and colors.cpp (SR3StoreColorPicker.asi, SaintsRowTheThird_DX11.exe only).
#pragma once
#include <windows.h>
#include <cstddef>
#include <cstdint>

void logf(const char* fmt, ...);                 // SR3StoreColorPicker.log next to the exe
bool readable(const void* p, size_t n);          // VirtualQuery guard before raw reads
bool patchImm(uintptr_t at, uintptr_t expect, uintptr_t value);   // swap one imm32 if it holds `expect`
const char* gameDir();                           // folder of the exe, with trailing backslash

// Lua 5.1 API inside the exe (DX11)
typedef int         (__cdecl *lua_fn_t)(void*);
extern int          (__cdecl *lua_gettop)(void*);
extern const char*  (__cdecl *lua_tolstr)(void*, int, size_t*);
extern double       (__cdecl *lua_tonum)(void*, int);
extern void         (__cdecl *lua_pushstr)(void*, const char*);
extern void         (__cdecl *lua_pushnum)(void*, double);

void installTeleport();
void installColors();
