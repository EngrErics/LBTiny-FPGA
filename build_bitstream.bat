@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ============================================================
rem Build Vivado bitstream for LBTiny / Nexys A7
rem Usage:
rem   build_bitstream.bat         (default: 100T)
rem   build_bitstream.bat 50T
rem   build_bitstream.bat 100T
rem ============================================================

cd /d "%~dp0"

if "%~1"=="" (
    set "BOARD_SIZE=100T"
) else (
    set "BOARD_SIZE=%~1"
)

if /I "%BOARD_SIZE%"=="50T" (
    set "FPGA_PART=xc7a50tcsg324-1"
) else if /I "%BOARD_SIZE%"=="100T" (
    set "FPGA_PART=xc7a100tcsg324-1"
) else (
    echo ERROR: unknown board size "%BOARD_SIZE%". Use 50T or 100T.
    exit /b 1
)

call :find_vivado
if errorlevel 1 exit /b 1

if not exist "build_bitstream.tcl" (
    echo ERROR: build_bitstream.tcl not found next to this script.
    exit /b 1
)

echo [build] board=%BOARD_SIZE%  part=%FPGA_PART%
echo.

vivado -mode batch -source build_bitstream.tcl -tclargs "%FPGA_PART%"
if errorlevel 1 (
    echo.
    echo ERROR: Vivado build failed.
    exit /b 1
)

echo.
echo [build] done -^> build\LBTiny\LBTiny.runs\impl_1\lbtiny_top.bit
exit /b 0


rem ------------------------------------------------------------
rem :find_vivado
rem Locate vivado.exe / vivado.bat. Sets PATH on success.
rem Returns 0 if found, 1 otherwise.
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
