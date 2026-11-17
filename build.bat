@echo off
rem Builds out\SR3StoreColorPicker.asi (32-bit) from src\asi\. Run from this folder.
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars32.bat" >nul 2>&1
if not exist out\obj mkdir out\obj
cl /nologo /O2 /LD /EHsc /W3 /D_CRT_SECURE_NO_WARNINGS /Fo:out\obj\ /Fe:out\SR3StoreColorPicker.asi src\asi\teleport.cpp src\asi\colors.cpp user32.lib kernel32.lib
if errorlevel 1 exit /b 1
echo built: out\SR3StoreColorPicker.asi
