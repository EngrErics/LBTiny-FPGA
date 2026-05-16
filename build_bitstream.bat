@echo off
setlocal enabledelayedexpansion

rem ================================================================
rem Build FPGA bitstream for LBTiny-MemBus on Digilent Nexys A7
rem Default target: Nexys A7-100T, part xc7a100tcsg324-1
rem Use: build_bitstream.bat        ^(100T default^)
rem      build_bitstream.bat 50T    ^(Nexys A7-50T^)
rem      build_bitstream.bat 100T   ^(Nexys A7-100T^)
rem ================================================================

set BOARD=%~1
if "%BOARD%"=="" set BOARD=100T

if /I "%BOARD%"=="50T" (
    set FPGA_PART=xc7a50tcsg324-1
) else if /I "%BOARD%"=="100T" (
    set FPGA_PART=xc7a100tcsg324-1
) else (
    echo ERROR: Unknown board "%BOARD%". Use 50T or 100T.
    exit /b 1
)

rem Find Vivado. This works when Vivado is already in PATH, or when XILINX_VIVADO is set.
where vivado >nul 2>nul
if errorlevel 1 (
    if defined XILINX_VIVADO (
        set PATH=%XILINX_VIVADO%\bin;%PATH%
    ) else (
        echo ERROR: vivado.exe not found in PATH and XILINX_VIVADO is not set.
        echo Open "Vivado Tcl Shell" or set XILINX_VIVADO, for example:
        echo   set XILINX_VIVADO=C:\Xilinx\Vivado\2024.2
        exit /b 1
    )
)

rem Run from the folder containing this .bat, so relative paths are stable.
cd /d "%~dp0"

if not exist src\lbtiny_top.v (
    echo ERROR: expected src\lbtiny_top.v not found.
    echo Put this script in the project root, next to the src folder.
    exit /b 1
)
if not exist src\lbtiny_bus_slave.v (
    echo ERROR: expected src\lbtiny_bus_slave.v not found.
    exit /b 1
)
if not exist src\lbtiny.xdc (
    echo ERROR: expected src\lbtiny.xdc not found.
    exit /b 1
)
if not exist src\rom_init.mem (
    echo ERROR: expected src\rom_init.mem not found.
    exit /b 1
)

vivado -mode batch -source vivado_build.tcl -tclargs %FPGA_PART%
if errorlevel 1 (
    echo.
    echo ERROR: Vivado build failed. Check build\vivado.log and build\vivado.jou.
    exit /b 1
)

echo.
echo SUCCESS: bitstream written to build\LBTiny-MemBus.runs\impl_1\lbtiny_top.bit
exit /b 0
