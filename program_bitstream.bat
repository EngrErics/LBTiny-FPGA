@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ============================================================
rem Program LBTiny bitstream to a Digilent Nexys A7 via USB-JTAG
rem
rem Usage:
rem   program_bitstream.bat
rem   program_bitstream.bat path\to\some.bit
rem
rem Default bitstream:
rem   build\LBTiny.runs\impl_1\lbtiny_top.bit
rem ============================================================

cd /d "%~dp0"

if "%~1"=="" (
    set "BITFILE=build\LBTiny\LBTiny.runs\impl_1\lbtiny_top.bit"
) else (
    set "BITFILE=%~1"
)

if not exist "%BITFILE%" (
    echo ERROR: bitstream not found:
    echo   %BITFILE%
    echo.
    echo Build it first with:
    echo   build_bitstream.bat
    exit /b 1
)

if not exist "program_bitstream.tcl" (
    echo ERROR: program_bitstream.tcl not found in project root.
    exit /b 1
)

if not exist "build" mkdir "build"

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
exit /b 1

:vivado_found
echo Using Vivado from PATH.
echo Bitstream: %BITFILE%
echo.
echo Make sure the Nexys A7 is powered on and connected through the PROG USB-JTAG port.
echo.

call vivado -mode batch -log "build\program_bitstream.log" -journal "build\program_bitstream.jou" -source program_bitstream.tcl -tclargs "%BITFILE%"
if errorlevel 1 (
    echo.
    echo ERROR: FPGA programming failed.
    echo See build\program_bitstream.log for details.
    exit /b 1
)

echo.
echo FPGA programming complete.
exit /b 0
