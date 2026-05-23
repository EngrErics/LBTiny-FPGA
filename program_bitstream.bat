@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ============================================================
rem Program LBTiny bitstream to a Digilent Nexys A7 via USB-JTAG
rem
rem Usage:
rem   program_bitstream.bat
rem       -> program the FPGA with the default .bit (volatile, JTAG)
rem
rem   program_bitstream.bat path\to\some.bit
rem       -> program the FPGA with that .bit (volatile, JTAG)
rem
rem   program_bitstream.bat persistent
rem       -> program the on-board QSPI flash with the default .mcs
rem          (survives power cycle; set JP1 to QSPI)
rem
rem   program_bitstream.bat persistent path\to\some.mcs
rem   program_bitstream.bat path\to\some.mcs persistent
rem   program_bitstream.bat path\to\some.mcs
rem       -> program the on-board QSPI flash with that .mcs
rem
rem Default files (produced by build_bitstream.bat):
rem   .bit -> build\LBTiny\LBTiny.runs\impl_1\lbtiny_top.bit
rem   .mcs -> build\LBTiny\LBTiny.runs\impl_1\lbtiny_top.mcs
rem ============================================================

cd /d "%~dp0"

rem -------- arg parsing --------
rem Walks up to two positional args. Either can be the "persistent" flag
rem or a path to a .bit / .mcs file. Order does not matter.
set "PROG_FILE="
set "PERSISTENT=0"

call :parse_arg "%~1"
if errorlevel 1 exit /b 1
call :parse_arg "%~2"
if errorlevel 1 exit /b 1

rem If user passed an .mcs path, persistent mode is implied.
if defined PROG_FILE (
    if /I "!PROG_FILE:~-4!"==".mcs" set "PERSISTENT=1"
)

rem Fill in default file if none was given.
if not defined PROG_FILE (
    if "%PERSISTENT%"=="1" (
        set "PROG_FILE=build\LBTiny\LBTiny.runs\impl_1\lbtiny_top.mcs"
    ) else (
        set "PROG_FILE=build\LBTiny\LBTiny.runs\impl_1\lbtiny_top.bit"
    )
)

if not exist "%PROG_FILE%" (
    echo ERROR: programming file not found:
    echo   %PROG_FILE%
    echo.
    if "%PERSISTENT%"=="1" (
        echo Build it first with:
        echo   build_bitstream.bat persistent
    ) else (
        echo Build it first with:
        echo   build_bitstream.bat
    )
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
rem Anything else is treated as a file path.
if defined PROG_FILE (
    echo ERROR: too many file paths given. Only one .bit or .mcs may be passed.
    exit /b 1
)
set "PROG_FILE=%~1"
goto :eof

:after_args

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
echo Programming file: %PROG_FILE%
if "%PERSISTENT%"=="1" (
    echo Target: on-board QSPI flash (persistent across power cycles^)
) else (
    echo Target: FPGA SRAM via JTAG (volatile - lost on power cycle^)
)
echo.
echo Make sure the Nexys A7 is powered on and connected through the PROG USB-JTAG port.
echo.

call vivado -mode batch -log "build\program_bitstream.log" -journal "build\program_bitstream.jou" -source program_bitstream.tcl -tclargs "%PROG_FILE%" %TCL_PERSIST_ARG%
if errorlevel 1 (
    echo.
    echo ERROR: FPGA programming failed.
    echo See build\program_bitstream.log for details.
    exit /b 1
)

echo.
if "%PERSISTENT%"=="1" (
    echo QSPI flash programming complete.
    echo.
    echo To boot the design from flash:
    echo   1. Set the JP1 mode jumper to QSPI.
    echo   2. Power-cycle the board, or press the red PROG button.
) else (
    echo FPGA programming complete.
)
exit /b 0
