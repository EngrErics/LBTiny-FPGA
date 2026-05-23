@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ============================================================
rem Program LBTiny to a Digilent Nexys A7 via USB-JTAG
rem
rem Usage:
rem   program_bitstream.bat                 (JTAG, default .bit, volatile)
rem   program_bitstream.bat foo.bit         (JTAG, custom .bit, volatile)
rem   program_bitstream.bat -persist        (QSPI flash, default .bit)
rem   program_bitstream.bat foo.bit -persist
rem   program_bitstream.bat -persist foo.bit
rem
rem -persist writes the design into the on-board QSPI flash so it
rem survives power cycles. Move the JP1 jumper to QSPI after flashing.
rem
rem Default .bit: build\LBTiny\LBTiny.runs\impl_1\lbtiny_top.bit
rem ============================================================

cd /d "%~dp0"

set "BITFILE="
set "PERSIST=0"

call :parse_arg "%~1"
if errorlevel 1 exit /b 1
call :parse_arg "%~2"
if errorlevel 1 exit /b 1

if not defined BITFILE set "BITFILE=build\LBTiny\LBTiny.runs\impl_1\lbtiny_top.bit"

if not exist "%BITFILE%" (
    echo ERROR: bitstream not found: %BITFILE%
    echo Build it first:  build_bitstream.bat
    exit /b 1
)

if not exist "program_bitstream.tcl" (
    echo ERROR: program_bitstream.tcl not found next to this script.
    exit /b 1
)

if "%PERSIST%"=="1" (
    set "TCL_PERSIST=-persist"
) else (
    set "TCL_PERSIST="
)

call :find_vivado
if errorlevel 1 exit /b 1

if not exist "build" mkdir "build"

if "%PERSIST%"=="1" (
    echo [program] target=QSPI-flash  bit=%BITFILE%
) else (
    echo [program] target=JTAG-SRAM   bit=%BITFILE%
)
echo [program] make sure Nexys A7 is powered on and USB-JTAG cable is connected
echo.

call vivado -mode batch ^
    -log     "build\program_bitstream.log" ^
    -journal "build\program_bitstream.jou" ^
    -source  program_bitstream.tcl ^
    -tclargs "%BITFILE%" %TCL_PERSIST%
if errorlevel 1 (
    echo.
    echo ERROR: programming failed. See build\program_bitstream.log
    exit /b 1
)

echo.
if "%PERSIST%"=="1" (
    echo [program] flashed. Move JP1 to QSPI and power-cycle to boot from flash.
) else (
    echo [program] done.
)
exit /b 0


rem ------------------------------------------------------------
rem :parse_arg
rem One positional argument. -persist toggles the flag; anything
rem else is treated as the bitstream path. Order doesn't matter.
rem Returns 1 if a path is given more than once.
rem ------------------------------------------------------------
:parse_arg
if "%~1"=="" exit /b 0
if /I "%~1"=="-persist" (
    set "PERSIST=1"
    exit /b 0
)
if /I "%~1"=="--persist" (
    set "PERSIST=1"
    exit /b 0
)
if /I "%~1"=="persist" (
    set "PERSIST=1"
    exit /b 0
)
if defined BITFILE (
    echo ERROR: extra argument "%~1"; bitstream path already set to "!BITFILE!".
    exit /b 1
)
set "BITFILE=%~1"
exit /b 0


rem ------------------------------------------------------------
rem :find_vivado
rem Locate vivado.exe / vivado.bat. Sets PATH on success.
rem ------------------------------------------------------------
:find_vivado
where vivado.exe >nul 2>nul && exit /b 0
where vivado.bat >nul 2>nul && exit /b 0

if defined XILINX_VIVADO (
    if exist "!XILINX_VIVADO!\bin\vivado.bat" (
        set "PATH=!XILINX_VIVADO!\bin;!PATH!"
        exit /b 0
    )
    if exist "!XILINX_VIVADO!\bin\vivado.exe" (
        set "PATH=!XILINX_VIVADO!\bin;!PATH!"
        exit /b 0
    )
    echo ERROR: XILINX_VIVADO is set but no Vivado at !XILINX_VIVADO!\bin
    exit /b 1
)

for /d %%D in ("C:\Xilinx\Vivado\*" "C:\AMD\Vivado\*") do (
    if exist "%%~fD\bin\vivado.bat" (
        set "PATH=%%~fD\bin;!PATH!"
        exit /b 0
    )
    if exist "%%~fD\bin\vivado.exe" (
        set "PATH=%%~fD\bin;!PATH!"
        exit /b 0
    )
)

echo ERROR: vivado.exe not found. Either:
echo   - run this from the Vivado Tcl Shell, or
echo   - set XILINX_VIVADO, e.g.  set XILINX_VIVADO=C:\Xilinx\Vivado\2024.2
exit /b 1
