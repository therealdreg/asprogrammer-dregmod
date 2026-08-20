@echo off
rem Builds testsuild\i18ncheck.exe, which proves the interface can really be
rem translated: it switches through every file in lang\ and checks no caption
rem goes blank and no language file can raise. Needs no hardware.
rem
rem By Dreg
rem https://github.com/therealdreg/asprogrammer-dregmod
rem
rem Build AsProgrammer first (Lazarus, or lazbuild AsProgrammer.lpi): this
rem reuses the units it leaves in lib\i386-win32. This one does build the real
rem form, so the whole LCL has to be on the unit path.
rem
rem Run from the software\ directory:  tests\build_i18ncheck.cmd

setlocal
if "%LAZDIR%"=="" set LAZDIR=C:\lazarus
set FPC=%LAZDIR%\fpc\3.2.2\bin\i386-win32\fpc.exe
set MPHEX=..\mphexeditor\src\lib\i386-win32
set OUT=tests\build

if not exist lib\i386-win32\main.ppu (
  echo Build AsProgrammer first - lib\i386-win32\main.ppu is missing.
  exit /b 1
)

if not exist "%OUT%" md "%OUT%"

"%FPC%" -Mobjfpc -Sh -O2 ^
  -Fulib\i386-win32 -Fu. ^
  -Fu"%LAZDIR%\lcl\units\i386-win32" ^
  -Fu"%LAZDIR%\lcl\units\i386-win32\win32" ^
  -Fu"%LAZDIR%\components\lazutils\lib\i386-win32" ^
  -Fu"%LAZDIR%\packager\units\i386-win32" ^
  -Fu"%LAZDIR%\components\synedit\units\i386-win32\win32" ^
  -Fu"%MPHEX%" ^
  -Filib\i386-win32 -FU"%OUT%" -FE"%OUT%" -o"%OUT%\i18ncheck.exe" tests\i18ncheck.lpr

if errorlevel 1 (
  echo BUILD FAILED
  exit /b 1
)
echo Built %OUT%\i18ncheck.exe
endlocal
