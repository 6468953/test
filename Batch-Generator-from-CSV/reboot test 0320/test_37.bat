@echo off
setlocal enabledelayedexpansion

set "DEVICE=c5383dc8"
set "ITERATIONS=1000" 
set "LOG_FILE=./LOG/37#_%DEVICE%.log"

echo. > "%LOG_FILE%"
echo Start Reboot Stress Test: 
echo Start Reboot Stress Test: >> "%LOG_FILE%"

for /L %%i in (1,1,%ITERATIONS%) do (
    rem ????????????????????
    for /f "tokens=*" %%t in ('powershell -Command "Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'"') do set "current_time=%%t"
    
    echo Current Test %%i/%ITERATIONS% Start Date and Time:!current_time!
    echo Current Test %%i/%ITERATIONS% Start Date and Time:!current_time! >> "%LOG_FILE%"
    
    adb -s %DEVICE% root
    adb -s %DEVICE% wait-for-device
    adb -s %DEVICE% shell sys_reboot 
    echo module reboot, waiting for device to come back online... 
    echo module reboot, waiting for device to come back online... >> "%LOG_FILE%"
    adb -s %DEVICE% wait-for-device
    echo Device is back online
    echo Device is back online >> "%LOG_FILE%"
    timeout /t 50 >nul
    
    rem ?????????
    for /f "tokens=*" %%t in ('powershell -Command "Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'"') do set "end_time=%%t"
    
    echo Current Test %%i/%ITERATIONS% End Date and Time:!end_time!
    echo Current Test %%i/%ITERATIONS% End Date and Time:!end_time! >> "%LOG_FILE%"
)
echo End Reboot Stress Test, All pass
echo End Reboot Stress Test, All pass >> "%LOG_FILE%"
pause
