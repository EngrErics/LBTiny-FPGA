@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ============================================================
rem Build standalone memory-viewer bitstream for LBTiny-MemBus / Nexys A7
rem Usage:
rem   build_mem_viewer_bitstream.bat        rem Nexys A7-100T default
rem   build_mem_viewer_bitstream.bat 50T    rem Nexys A7-50T
rem   build_mem_viewer_bitstream.bat 100T   rem Nexys A7-100T
rem ============================================================

cd /d "%~dp0"

set "BOARD_SIZE=%~1"
if "%BOARD_SIZE%"=="" set "BOARD_SIZE=100T"

if /I "%BOARD_SIZE%"=="50T" (
    set "FPGA_PART=xc7a50tcsg324-1"
) else if /I "%BOARD_SIZE%"=="100T" (
    set "FPGA_PART=xc7a100tcsg324-1"
) else (
    echo ERROR: Unknown board size "%BOARD_SIZE%".
    echo Use either:
    echo   %~nx0 50T
    echo   %~nx0 100T
    exit /b 1
)

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
echo Target FPGA part: %FPGA_PART%
echo.

if not exist "vivado_build_mem_viewer.tcl" (
    echo ERROR: vivado_build_mem_viewer.tcl not found in project root.
    exit /b 1
)
if not exist "src\lbtiny_bus_slave.v" (
    echo ERROR: expected src\lbtiny_bus_slave.v not found.
    exit /b 1
)
if not exist "src\lbtiny_mem_viewer_top.v" (
    echo ERROR: expected src\lbtiny_mem_viewer_top.v not found.
    exit /b 1
)
if not exist "src\lbtiny_mem_viewer.xdc" (
    echo ERROR: expected src\lbtiny_mem_viewer.xdc not found.
    exit /b 1
)
if not exist "src\rom_init.mem" (
    echo ERROR: expected src\rom_init.mem not found.
    exit /b 1
)

vivado -mode batch -source vivado_build_mem_viewer.tcl -tclargs "%FPGA_PART%"
if errorlevel 1 (
    echo.
    echo ERROR: Vivado build failed. Check build_mem_viewer\vivado.log and build_mem_viewer\vivado.jou.
    exit /b 1
)

echo.
echo Build complete.
echo Bitstream should be under:
echo   build_mem_viewer\LBTiny-MemViewer.runs\impl_1\lbtiny_mem_viewer_top.bit
exit /b 0
