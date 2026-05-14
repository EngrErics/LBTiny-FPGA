@echo off
setlocal

set VIVADO_BIN=C:\Xilinx\Vivado\2024.2\bin
set XVLOG=%VIVADO_BIN%\xvlog.bat
set XELAB=%VIVADO_BIN%\xelab.bat
set XSIM=%VIVADO_BIN%\xsim.bat

set BUILD_DIR=build

if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"

echo.
echo ===== Compiling Verilog =====
pushd "%BUILD_DIR%"
call "%XVLOG%" -sv ..\src\lbtiny_bus_slave.v ..\tb\lbtiny_bus_slave_tb.v
if errorlevel 1 (
    popd
    goto failed
)

echo.
echo ===== Elaborating =====
call "%XELAB%" lbtiny_bus_slave_tb -s sim
if errorlevel 1 (
    popd
    goto failed
)

echo.
echo ===== Running simulation =====
call "%XSIM%" sim -tclbatch ../wave.tcl
if errorlevel 1 (
    popd
    goto failed
)

popd

echo.
echo ===== Simulation succeeded =====

if exist "%BUILD_DIR%\sim.wdb" (
    echo Closing old XSim GUI if open...
    taskkill /IM xsim.exe /F >nul 2>&1

    echo Opening waveform viewer...

	if exist sim.wcfg (
		echo Loading saved waveform config...
		start "" cmd /c "cd /d %CD%\%BUILD_DIR% && call "%XSIM%" --gui sim.wdb -view ..\sim.wcfg"
	) else (
		echo No waveform config found, opening default view...
		start "" cmd /c "cd /d %CD%\%BUILD_DIR% && call "%XSIM%" --gui sim.wdb"
	)

    exit /b 0
) else (
    echo ERROR: %BUILD_DIR%\sim.wdb not found!
    exit /b 1
)

:failed
echo.
echo Simulation FAILED.
exit /b 1