@echo off
setlocal enabledelayedexpansion

:: ========== 配置参数 ==========
set COM_PORT=COM3
set BAUD=9600
set CHANNEL=OUT1
set VOLTAGE=5.0
set CURRENT=1.0
set ON_TIME=5
set OFF_TIME=5
set CYCLES=10
set LOG_FILE=log.txt
set CSV_FILE=measure.csv
:: =============================

echo 程序启动 > %LOG_FILE%
echo Cycle,Timestamp,Voltage,Current > %CSV_FILE%

for /l %%i in (1,1,%CYCLES%) do (
    echo ----- 第 %%i 次循环 ----- >> %LOG_FILE%
    
    :: 1. 开启输出
    echo 开启输出 >> %LOG_FILE%
    echo OUTP ON | plink -serial %COM_PORT% -sercfg %BAUD%,8,1,n,N >> %LOG_FILE% 2>&1
    timeout /t %ON_TIME% /nobreak > nul
    
    :: 2. 在 ON 期间测量（这里测量一次，也可以循环多次，但批处理循环麻烦，可改为测量一次）
    echo 测量电压电流 >> %LOG_FILE%
    :: 发送电压查询，读取一行
    for /f "delims=" %%v in ('echo MEAS:VOLT? ^| plink -serial %COM_PORT% -sercfg %BAUD%,8,1,n,N') do set VOLT_RAW=%%v
    for /f "delims=" %%c in ('echo MEAS:CURR? ^| plink -serial %COM_PORT% -sercfg %BAUD%,8,1,n,N') do set CURR_RAW=%%c
    :: 清理数值（去除可能的回车换行和非数字）
    set VOLT=%VOLT_RAW: =%
    set CURR=%CURR_RAW: =%
    set TIMESTAMP=%date% %time%
    echo %%i,!TIMESTAMP!,%VOLT%,%CURR% >> %CSV_FILE%
    echo 电压=%VOLT% 电流=%CURR% >> %LOG_FILE%
    
    :: 3. 关闭输出
    echo 关闭输出 >> %LOG_FILE%
    echo OUTP OFF | plink -serial %COM_PORT% -sercfg %BAUD%,8,1,n,N >> %LOG_FILE% 2>&1
    timeout /t %OFF_TIME% /nobreak > nul
)

echo 程序结束 >> %LOG_FILE%
pause