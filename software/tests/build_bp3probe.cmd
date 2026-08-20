@echo off
rem Builds tests\bp3probe.exe, the console harness that drives the Pascal BBIO
rem engine in buzzpirathw.pas against a real Bus Pirate v3.x or Buzzpirat.
rem
rem By Dreg
rem https://github.com/therealdreg/asprogrammer-dregmod
rem
rem Build AsProgrammer first (Lazarus, or lazbuild AsProgrammer.lpi): this
rem reuses the units it leaves in lib\i386-win32. buzzpirathw pulls in main
rem for the menu settings, so the LCL has to be on the unit path even though no
rem form is ever created here.
rem
rem Run from the software\ directory:  tests\build_bp3probe.cmd

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
  -Filib\i386-win32 -FU"%OUT%" -FE"%OUT%" -o"%OUT%\bp3probe.exe" tests\bp3probe.lpr

if errorlevel 1 (
  echo BUILD FAILED
  exit /b 1
)
echo Built %OUT%\bp3probe.exe
endlocal
