@echo off
REM start_wifi_toolbox.bat
REM
REM Wrapper for simplelink-wifi-toolbox.exe that patches libusb-1.0.dll
REM in the PyInstaller temp directory before the Programmer tab is opened.
REM
REM The toolbox extracts to a _MEI* temp directory at startup, but only
REM loads libusb-1.0.dll lazily when Programmer is first accessed.
REM This gives us a window to replace the bundled DLL.
REM
REM Usage: place this .bat next to simplelink-wifi-toolbox.exe, or
REM        set TOOLBOX_EXE and LIBUSB_DLL to the correct paths.
REM
REM You have ~60 seconds after the toolbox window appears to click
REM Programmer - the script patches the DLL 3 seconds after launch.

setlocal

REM --- Configuration ---------------------------------------------------

REM Path to the toolbox executable (default: same directory as this script)
if "%TOOLBOX_EXE%"=="" (
    set "TOOLBOX_EXE=%~dp0simplelink-wifi-toolbox.exe"
)

REM Path to the RDS-patched libusb-1.0.dll
REM Default: look in the build output relative to this script
if "%LIBUSB_DLL%"=="" (
    set "LIBUSB_DLL=%~dp0..\..\build\v145\x64\Release\dll\libusb-1.0.dll"
)
if not exist "%LIBUSB_DLL%" (
    set "LIBUSB_DLL=%~dp0..\..\build\v145\x64\Debug\dll\libusb-1.0.dll"
)

REM How many seconds to wait after launch before patching (default: 3)
if "%PATCH_DELAY%"=="" set PATCH_DELAY=3

REM ---------------------------------------------------------------------

if not exist "%TOOLBOX_EXE%" (
    echo ERROR: Toolbox not found: %TOOLBOX_EXE%
    echo Set TOOLBOX_EXE environment variable to the correct path.
    pause
    exit /b 1
)

if not exist "%LIBUSB_DLL%" (
    echo ERROR: Patched libusb-1.0.dll not found: %LIBUSB_DLL%
    echo Set LIBUSB_DLL environment variable to the correct path.
    pause
    exit /b 1
)

echo Starting: %TOOLBOX_EXE%
echo Will patch libusb from: %LIBUSB_DLL%
echo Waiting %PATCH_DELAY% seconds for extraction, then patching...
echo.
echo NOTE: Do NOT click Programmer until this window says "Done patching".

REM Launch the toolbox in the background
start "" "%TOOLBOX_EXE%"

REM Wait for PyInstaller to extract
timeout /t %PATCH_DELAY% /nobreak >nul

REM Find and replace libusb-1.0.dll in all _MEI* temp directories
set PATCHED=0
for /d %%D in ("%TEMP%\_MEI*") do (
    if exist "%%D\libusb-1.0.dll" (
        echo Patching: %%D\libusb-1.0.dll
        copy /y "%LIBUSB_DLL%" "%%D\libusb-1.0.dll" >nul
        if errorlevel 1 (
            echo   WARNING: copy failed for %%D
        ) else (
            echo   OK
            set /a PATCHED+=1
        )
    )
)

if %PATCHED%==0 (
    echo WARNING: No _MEI* directories found with libusb-1.0.dll.
    echo The toolbox may not have extracted yet - try increasing PATCH_DELAY.
) else (
    echo.
    echo Done patching %PATCHED% location(s). You can now click Programmer.
)
