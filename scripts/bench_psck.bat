@echo off
REM ============================================================================
REM bench_psck.bat - Windows launcher for bench_psck.ps1
REM
REM The .ps1 does all the real work; this .bat exists so users can double-click
REM and so the command line in the README stays simple.
REM
REM Override sweep parameters via environment variables before running:
REM   set OCC_LIST=1 2
REM   set PNT_LIST=24 32 48 64
REM   set RUN_SECONDS=120
REM   bench_psck.bat
REM
REM Requires: Visual Studio 2019+ with C++/CUDA build tools (or VS Build Tools).
REM ============================================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0bench_psck.ps1" %*
