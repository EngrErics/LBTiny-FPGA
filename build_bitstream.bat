@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ============================================================
rem Build Vivado bitstream for LBTiny / Nexys A7
rem Usage:
rem   build_bitstream.bat                       100T default, JTAG-only .bit
rem   build_bitstream.bat 50T                   Nexys A7-50T,  JTAG-only .bit
rem   build_bitstream.bat 100T                  Nexys A7-100T, JTAG-only .bit
rem   build_bitstream.bat 100T persistent       Nexys A7-100T, also emit .mcs
rem                                             for QSPI flash (power-cycle safe)
rem   build_bitstream.bat persistent            shorthand for 100T persistent
rem
rem When "persistent" is given, an .mcs file is generated alongside the
rem .bit and can be programmed into the on-board QSPI flash so the design
rem reloads automatically at power-on. The board's mode jumper (JP1) must
rem be set to QSPI.
rem ============================================================

cd /d "%~dp0"

rem -------- arg parsing --------
rem Walks up to two positional args. Either can be the board size (50T/100T)
rem or the "persistent" flag. Order does not matter.
set "BOARD_SIZE="
set "PERSISTENT=0"

call :parse_arg "%~1"
if errorlevel 1 exit /b 1
call :parse_arg "%~2"
if errorlevel 1 exit /b 1

if "%BOARD_SIZE%"=="" set "BOARD_SIZE=100T"

if /I "%BOARD_SIZE%"=="50T" (
    set "FPGA_PART=xc7a50tcsg324-1"
) else if /I "%BOARD_SIZE%"=="100T" (
    set "FPGA_PART=xc7a100tcsg324-1"
) else (
    echo ERROR: Unknown board size "%BOARD_SIZE%".
    echo Use either 50T or 100T.
    exit /b 1
)

if "%PERSISTENT%"=="1" (
    set "TCL_PERSIST_ARG=persistent"
) else (
    set "TCL_PERSIST_ARG="
)

goto :after_args

:parse_arg
if "%~1"=="" goto :eof
if /I "%~1"=="persistent" (
    set "PERSISTENT=1"
    goto :eof
)
if /I "%~1"=="50T" (
    set "BOARD_SIZE=50T"
    goto :eof
)
if /I "%~1"=="100T" (
    set "BOARD_SIZE=100T"
    goto :eof
)
echo ERROR: Unknown argument "%~1".
echo Expected 50T, 100T, or persistent.
exit /b 1

:after_args

rem If Vivado is already available, use it.
where vivado.exe >nul 2>nul
if not errorlevel 1 goto :vivado_found
where vivado.bat >nul 2>nul
if not errorlevel 1 goto :vivado_found

rem If XILINX_VIVADO is set, add it to PATH.
if defined XILINX_VIVADO (
    if exist "!XILINX_VIVADO!\bin\vivado.bat" (
        set "PATH=!XILINX_VIVADO!\bin;!PATH!"
        goto :vivado_found
    )
    if exist "!XILINX_VIVADO!\bin\vivado.exe" (
        set "PATH=!XILINX_VIVADO!\bin;!PATH!"
        goto :vivado_found
    )
    echo ERROR: XILINX_VIVADO is set but Vivado was not found here:
    echo   !XILINX_VIVADO!\bin
    exit /b 1
)

rem Try common install locations automatically.
for /d %%D in ("C:\Xilinx\Vivado\*" "C:\AMD\Vivado\*") do (
    if exist "%%~fD\bin\vivado.bat" (
        set "XILINX_VIVADO=%%~fD"
        set "PATH=%%~fD\bin;!PATH!"
        goto :vivado_found
    )
    if exist "%%~fD\bin\vivado.exe" (
        set "XILINX_VIVADO=%%~fD"
        set "PATH=%%~fD\bin;!PATH!"
        goto :vivado_found
    )
)

echo ERROR: vivado.exe was not found.
echo.
echo Option 1: run this from the Vivado Tcl Shell.
echo Option 2: set XILINX_VIVADO in PowerShell, for example:
echo   $env:XILINX_VIVADO = "C:\Xilinx\Vivado\2024.2"
echo   .\%~nx0
echo.
echo If your Vivado is installed somewhere else, replace the path above.
exit /b 1

:vivado_found
echo Using Vivado from PATH.
echo FPGA part: %FPGA_PART%
if "%PERSISTENT%"=="1" (
    echo Persistent mode: ON  (will also generate .mcs for QSPI flash^)
) else (
    echo Persistent mode: OFF (JTAG .bit only^)
)
echo.

if not exist "build_bitstream.tcl" (
    echo ERROR: build_bitstream.tcl not found in project root.
    exit /b 1
)

vivado -mode batch -source build_bitstream.tcl -tclargs "%FPGA_PART%" %TCL_PERSIST_ARG%
if errorlevel 1 (
    echo.
    echo ERROR: Vivado build failed.
    exit /b 1
)

echo.
echo Build complete.
echo Bitstream should be under:
echo   build\LBTiny\LBTiny.runs\impl_1\lbtiny_top.bit
if "%PERSISTENT%"=="1" (
    echo MCS for QSPI flash should be under:
    echo   build\LBTiny\LBTiny.runs\impl_1\lbtiny_top.mcs
    echo.
    echo To program the on-board flash, run:
    echo   program_bitstream.bat persistent
)
exit /b 0
