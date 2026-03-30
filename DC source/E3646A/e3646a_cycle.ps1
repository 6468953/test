# ========== 配置参数（请根据实际情况修改） ==========
$comPort = "COM3"           # 串口号
$baudRate = 9600            # 波特率
$channel = "OUT1"           # 通道：OUT1 或 OUT2
$voltage = 5.0              # 设置电压 (V)
$current = 1.0              # 设置限流 (A)
$onTime = 5                 # 每次 ON 持续秒数
$offTime = 5                # 每次 OFF 等待秒数
$cycles = 10                # 循环次数
$measureInterval = 1.0      # 测量间隔（秒）
$logFile = "log.txt"        # 操作日志文件
$csvFile = "measure.csv"    # 测量数据文件
# ==================================================

# 初始化 CSV 文件头
"Cycle,Timestamp,Voltage(V),Current(A)" | Out-File -FilePath $csvFile -Encoding utf8

# 日志函数
function Log-Message($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp - $msg"
    Write-Host $line
    Add-Content -Path $logFile -Value $line -Encoding utf8
}

# 发送命令函数（可选读取响应）
function Send-Command($cmd, $readResponse = $false) {
    $port.Write($cmd + "`n")
    Start-Sleep -Milliseconds 200
    if ($readResponse -and $port.BytesToRead -gt 0) {
        $resp = $port.ReadExisting()
        Log-Message "<- $resp"
        return $resp
    }
    return $null
}

# 测量电压电流函数
function Measure-Output($cycleNum) {
    # 发送电压查询指令
    $port.Write("MEAS:VOLT?`n")
    Start-Sleep -Milliseconds 200
    $voltStr = ""
    if ($port.BytesToRead -gt 0) {
        $voltStr = $port.ReadExisting().Trim()
    }
    
    # 发送电流查询指令
    $port.Write("MEAS:CURR?`n")
    Start-Sleep -Milliseconds 200
    $currStr = ""
    if ($port.BytesToRead -gt 0) {
        $currStr = $port.ReadExisting().Trim()
    }
    
    # 解析数值
    try {
        $voltVal = [float]($voltStr -replace '[^0-9.-]', '')
    } catch { $voltVal = 0.0 }
    try {
        $currVal = [float]($currStr -replace '[^0-9.-]', '')
    } catch { $currVal = 0.0 }
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $csvLine = "$cycleNum,$timestamp,$voltVal,$currVal"
    Add-Content -Path $csvFile -Value $csvLine -Encoding utf8
    Log-Message "测量: ${voltVal}V, ${currVal}A"
    
    return @($voltVal, $currVal)
}

# 主程序
Log-Message "========== 程序启动（PowerShell 带测量） =========="

try {
    # 打开串口
    $port = New-Object System.IO.Ports.SerialPort $comPort, $baudRate, None, 8, One
    $port.ReadTimeout = 1000
    $port.Open()
    Log-Message "已连接 $comPort 波特率 $baudRate"
    
    # 测试连接
    Send-Command "*IDN?" $true
    
    # 设置通道、电压、电流
    Send-Command "INST:SEL $channel"
    Send-Command "VOLT $voltage"
    Send-Command "CURR $current"
    Log-Message "参数设置完成：通道$channel，${voltage}V / ${current}A"
    
    # 主循环
    for ($i = 1; $i -le $cycles; $i++) {
        Log-Message "----- 第 $i 次循环开始 -----"
        
        # 开启输出
        Send-Command "OUTP ON"
        Log-Message "输出已开启"
        
        # 在 ON 期间定期测量
        $startTime = Get-Date
        while (((Get-Date) - $startTime).TotalSeconds -lt $onTime) {
            Measure-Output $i
            Start-Sleep -Seconds $measureInterval
        }
        
        # 关闭输出
        Send-Command "OUTP OFF"
        Log-Message "输出已关闭"
        
        # OFF 等待（最后一次循环不等待）
        if ($i -lt $cycles) {
            Start-Sleep -Seconds $offTime
        }
    }
    
    # 确保最后关闭输出
    Send-Command "OUTP OFF"
    Log-Message "循环结束，输出已关闭"
    
} catch {
    Log-Message "错误: $_"
} finally {
    if ($port -ne $null -and $port.IsOpen) {
        $port.Close()
        Log-Message "串口已关闭"
    }
}

Log-Message "========== 程序结束 =========="