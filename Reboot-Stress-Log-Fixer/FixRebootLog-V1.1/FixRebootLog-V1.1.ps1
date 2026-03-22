<#
.SYNOPSIS
修正重启压力测试日志中的时间不连续，支持整体平移后缀、按绝对时间对齐、异常检测、撤销操作、导出CSV报告，并可设置输出文件的三个时间属性。
支持一次处理多个文件，每个文件的异常检测基于其自身统计数据。
.DESCRIPTION
- 支持输入单个或多个日志文件（通配符或数组）。
- 对每个文件独立解析，自动检测时间倒流、间隔过大、持续时间异常。
- 提供交互菜单：单点偏移、整体平移后缀、按绝对时间对齐、重置偏移、查看详情、撤销、保存。
- 保存后可选择导出CSV对比报告，并可选设置文件的创建/修改/访问时间。
- 所有修改不会在日志中留下额外标记，报告独立生成。
#>

param(
    [string[]]$InputFiles = @(),                     # 输入日志文件（支持多个，如 *.log 或 "a.log","b.log"）
    [string]$OutputDir = "",                         # 输出目录（为空则使用输入文件所在目录）
    [string]$CreationTime = "",                       # 可选：指定输出文件的创建时间（格式：yyyy-MM-dd HH:mm:ss）
    [string]$ModifyTime = "",                         # 可选：指定输出文件的修改时间（格式：yyyy-MM-dd HH:mm:ss）
    [string]$AccessTime = ""                          # 可选：指定输出文件的访问时间（格式：yyyy-MM-dd HH:mm:ss）
)

# 设置控制台编码
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "       时间修正工具（多文件版）          " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# 如果没有提供文件，交互式选择
if ($InputFiles.Count -eq 0) {
    Write-Host "未指定输入文件，请手动输入文件路径（支持通配符，多个文件用空格分隔）" -ForegroundColor Yellow
    $userInput = Read-Host "文件路径"
    if ($userInput -match '[*?]') {
        $InputFiles = Get-ChildItem $userInput | Select-Object -ExpandProperty FullName
    } else {
        $InputFiles = $userInput -split '\s+' | Where-Object { $_ -ne "" }
    }
    if ($InputFiles.Count -eq 0) {
        Write-Host "未找到任何文件，退出。" -ForegroundColor Red
        exit 1
    }
}

Write-Host "找到 $($InputFiles.Count) 个文件待处理：" -ForegroundColor Green
$InputFiles | ForEach-Object { Write-Host "  $_" -ForegroundColor Cyan }

# 主处理函数
function Process-File {
    param(
        [string]$InputFile,
        [string]$OutputFile,
        [string]$CreationTime,
        [string]$ModifyTime,
        [string]$AccessTime
    )

    Write-Host "`n========================================" -ForegroundColor Magenta
    Write-Host "正在处理文件: $InputFile" -ForegroundColor Magenta
    Write-Host "输出文件: $OutputFile" -ForegroundColor Magenta
    Write-Host "========================================" -ForegroundColor Magenta

    # 读取文件
    try {
        $lines = Get-Content $InputFile -Encoding UTF8 -ErrorAction Stop
        Write-Host "✓ 成功读取文件，共 $($lines.Count) 行" -ForegroundColor Green
    } catch {
        Write-Host "❌ 读取文件失败: $_" -ForegroundColor Red
        return $false
    }

    # 正则表达式
    $startPattern = 'Start Date and Time:(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})'
    $endPattern   = 'End Date and Time:(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})'

    # 提取所有时间戳
    $timestamps = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match $startPattern) {
            try {
                $dt = [datetime]::ParseExact($matches[1], "yyyy-MM-dd HH:mm:ss.fff", $null)
                $timestamps += [PSCustomObject]@{
                    Type = "Start"
                    Index = $i
                    Original = $matches[1]
                    DateTime = $dt
                }
            } catch {
                Write-Host "⚠ 警告：第 $($i+1) 行时间格式错误，已跳过: $($matches[1])" -ForegroundColor Yellow
            }
        }
        if ($line -match $endPattern) {
            try {
                $dt = [datetime]::ParseExact($matches[1], "yyyy-MM-dd HH:mm:ss.fff", $null)
                $timestamps += [PSCustomObject]@{
                    Type = "End"
                    Index = $i
                    Original = $matches[1]
                    DateTime = $dt
                }
            } catch {
                Write-Host "⚠ 警告：第 $($i+1) 行时间格式错误，已跳过: $($matches[1])" -ForegroundColor Yellow
            }
        }
    }
    if ($timestamps.Count -eq 0) {
        Write-Host "❌ 未找到任何时间戳，跳过此文件。" -ForegroundColor Red
        return $false
    }
    $timestamps = $timestamps | Sort-Object DateTime

    # 构建测试对
    $tests = @()
    $i = 0
    while ($i -lt $timestamps.Count - 1) {
        if ($timestamps[$i].Type -eq "Start" -and $timestamps[$i+1].Type -eq "End") {
            $duration = ($timestamps[$i+1].DateTime - $timestamps[$i].DateTime).TotalSeconds
            $tests += [PSCustomObject]@{
                Number    = $tests.Count + 1
                StartIdx  = $timestamps[$i].Index
                EndIdx    = $timestamps[$i+1].Index
                StartOrig = $timestamps[$i].Original
                EndOrig   = $timestamps[$i+1].Original
                StartDT   = $timestamps[$i].DateTime
                EndDT     = $timestamps[$i+1].DateTime
                Duration  = $duration
            }
            $i += 2
        } else {
            $i++
        }
    }
    if ($tests.Count -eq 0) {
        Write-Host "❌ 未能构建任何有效的测试对，跳过此文件。" -ForegroundColor Red
        return $false
    }
    Write-Host "✓ 成功构建 $($tests.Count) 个测试对" -ForegroundColor Green

    # 时间异常检测（基于本文件数据）
    Write-Host "`n=== 时间异常检测（基于本文件统计） ===" -ForegroundColor Cyan
    $anomalies = @()
    $intervalAnomaly = @{}
    $durationAnomaly = @{}

    # 计算间隔和持续时间的统计值
    $intervals = @()
    for ($i = 1; $i -lt $tests.Count; $i++) {
        $intervals += ($tests[$i].StartDT - $tests[$i-1].EndDT).TotalSeconds
    }
    $durations = $tests | ForEach-Object { $_.Duration }

    # 如果只有1个测试，则无法计算间隔，跳过间隔异常检测
    if ($tests.Count -gt 1) {
        $intervalAvg = ($intervals | Measure-Object -Average).Average
        $intervalStd = ($intervals | Measure-Object -StandardDeviation).StandardDeviation
        $intervalThreshold = $intervalAvg + 3 * $intervalStd   # 3倍标准差
    } else {
        $intervalThreshold = 10  # 默认10秒
    }

    $durationAvg = ($durations | Measure-Object -Average).Average
    $durationStd = ($durations | Measure-Object -StandardDeviation).StandardDeviation
    $durationUpper = $durationAvg + 3 * $durationStd
    $durationLower = [Math]::Max(0, $durationAvg - 3 * $durationStd)

    # 检测间隔过大
    if ($tests.Count -gt 1) {
        for ($i = 1; $i -lt $tests.Count; $i++) {
            $interval = ($tests[$i].StartDT - $tests[$i-1].EndDT).TotalSeconds
            if ($interval -gt $intervalThreshold) {
                $msg = "测试 $($i+1) 与测试 $i 之间间隔过大：$([math]::Round($interval,2)) 秒 (阈值 $([math]::Round($intervalThreshold,2)) 秒)"
                $anomalies += $msg
                $intervalAnomaly[$i+1] = $interval
            }
        }
    }

    # 检测时间倒流
    for ($i = 1; $i -lt $tests.Count; $i++) {
        if ($tests[$i].StartDT -lt $tests[$i-1].EndDT) {
            $msg = "测试 $($i+1) 开始时间早于测试 $i 结束时间，倒流 $([math]::Round(($tests[$i-1].EndDT - $tests[$i].StartDT).TotalSeconds,2)) 秒"
            $anomalies += $msg
        }
    }

    # 检测持续时间异常
    foreach ($t in $tests) {
        if ($t.Duration -gt $durationUpper) {
            $msg = "测试 $($t.Number) 持续时间过长：$([math]::Round($t.Duration,2)) 秒 (阈值 $([math]::Round($durationUpper,2)) 秒)"
            $anomalies += $msg
            $durationAnomaly[$t.Number] = $t.Duration
        } elseif ($t.Duration -lt $durationLower) {
            $msg = "测试 $($t.Number) 持续时间过短：$([math]::Round($t.Duration,2)) 秒 (阈值 $([math]::Round($durationLower,2)) 秒)"
            $anomalies += $msg
            $durationAnomaly[$t.Number] = $t.Duration
        }
    }

    if ($anomalies.Count -eq 0) {
        Write-Host "✓ 未检测到明显的时间异常" -ForegroundColor Green
    } else {
        Write-Host "⚠ 发现以下异常（仅供参考）：" -ForegroundColor Yellow
        $anomalies | ForEach-Object { Write-Host "  $_" }
    }

    # 显示基本信息
    $avgDur = ($durations | Measure-Object -Average).Average
    $maxDur = ($durations | Measure-Object -Maximum).Maximum
    Write-Host "`n持续时间统计：平均 $([math]::Round($avgDur,2)) 秒，最大 $([math]::Round($maxDur,2)) 秒" -ForegroundColor Gray

    # 函数：根据偏移字典生成预览时间线
    function Build-PreviewTimeline {
        param([array]$Tests, [hashtable]$Offsets)
        $preview = @()
        foreach ($t in $Tests) {
            $preview += [PSCustomObject]@{
                Number   = $t.Number
                StartIdx = $t.StartIdx
                EndIdx   = $t.EndIdx
                NewStart = $t.StartOrig
                NewEnd   = $t.EndOrig
                OrigStart = $t.StartOrig
                OrigEnd   = $t.EndOrig
            }
        }

        $activeOffset = 0
        for ($i = 0; $i -lt $preview.Count; $i++) {
            $num = $i + 1
            if ($Offsets.ContainsKey($num)) { $activeOffset = $Offsets[$num] }
            if ($activeOffset -ne 0) {
                $newStartDT = [datetime]::ParseExact($preview[$i].OrigStart, "yyyy-MM-dd HH:mm:ss.fff", $null).AddSeconds($activeOffset)
                $newEndDT   = [datetime]::ParseExact($preview[$i].OrigEnd,   "yyyy-MM-dd HH:mm:ss.fff", $null).AddSeconds($activeOffset)
                $preview[$i].NewStart = $newStartDT.ToString("yyyy-MM-dd HH:mm:ss.fff")
                $preview[$i].NewEnd   = $newEndDT.ToString("yyyy-MM-dd HH:mm:ss.fff")
            }
        }
        return $preview
    }

    # 显示预览函数
    function Show-Preview {
        param([array]$Timeline, [hashtable]$Offsets, [int]$ShowFirst = 3, [int]$ShowLast = 3, [int]$ShowSpecific = $null)
        if ($ShowSpecific) {
            $item = $Timeline | Where-Object { $_.Number -eq $ShowSpecific }
            if ($item) {
                $off = if ($Offsets.ContainsKey($item.Number)) { $Offsets[$item.Number] } else { 0 }
                Write-Host "测试 $($item.Number) : 新开始 $($item.NewStart)  原始 $($item.OrigStart)  偏移 $([math]::Round($off,1)) 秒"
            } else { Write-Host "未找到测试 $ShowSpecific" }
            return
        }
        Write-Host "`n=== 当前时间线预览（前 $ShowFirst 个） ===" -ForegroundColor Cyan
        $first = $Timeline | Select-Object -First $ShowFirst
        foreach ($item in $first) {
            $off = if ($Offsets.ContainsKey($item.Number)) { $Offsets[$item.Number] } else { 0 }
            Write-Host "  $($item.Number) : 新开始 $($item.NewStart)  原始 $($item.OrigStart)  偏移 $([math]::Round($off,1)) 秒"
        }
        if ($Timeline.Count -gt ($ShowFirst + $ShowLast)) { Write-Host "  ..." }
        Write-Host "=== 后 $ShowLast 个 ==="
        $last = $Timeline | Select-Object -Last $ShowLast
        foreach ($item in $last) {
            $off = if ($Offsets.ContainsKey($item.Number)) { $Offsets[$item.Number] } else { 0 }
            Write-Host "  $($item.Number) : 新开始 $($item.NewStart)  原始 $($item.OrigStart)  偏移 $([math]::Round($off,1)) 秒"
        }
    }

    # 历史栈
    $history = @()
    function Push-History {
        $copy = @{}
        foreach ($k in $offsets.Keys) { $copy[$k] = $offsets[$k] }
        $history += $copy
    }
    function Undo {
        if ($history.Count -gt 0) {
            $last = $history[-1]
            $history = $history[0..($history.Count-2)]
            $offsets.Clear()
            foreach ($k in $last.Keys) { $offsets[$k] = $last[$k] }
            Write-Host "✓ 已撤销上一次操作" -ForegroundColor Green
        } else {
            Write-Host "⚠ 没有可撤销的操作" -ForegroundColor Yellow
        }
    }

    # 初始化偏移字典
    $offsets = @{}
    $saveRequested = $false

    # 交互菜单
    do {
        $currentTimeline = Build-PreviewTimeline -Tests $tests -Offsets $offsets
        Show-Preview -Timeline $currentTimeline -Offsets $offsets

        Write-Host "`n请选择操作："
        Write-Host "  1) 修改单个测试的起始时间（提前/后退）"
        Write-Host "  2) 从某测试开始整体平移后缀（保持前面不变）"
        Write-Host "  3) 重置所有偏移"
        Write-Host "  4) 查看指定测试详情"
        Write-Host "  5) 确认并写入文件"
        Write-Host "  6) 跳过此文件（不保存）"
        Write-Host "  7) 按绝对时间对齐（指定测试的绝对开始时间）"
        Write-Host "  8) 撤销上一次偏移操作"
        $choice = Read-Host "请输入数字 (1-8)"

        switch ($choice) {
            "1" {
                $num = Read-Host "请输入测试编号 (1~$($tests.Count))"
                if ($num -notmatch '^\d+$' -or [int]$num -lt 1 -or [int]$num -gt $tests.Count) {
                    Write-Host "❌ 无效编号" -ForegroundColor Red; continue
                }
                $offsetMin = Read-Host "请输入偏移量（分钟，正数后退，负数提前）"
                $offsetSec = 0
                if ($offsetMin -match '^-?\d+(\.\d+)?$') {
                    $offsetSec = [double]$offsetMin * 60
                } else {
                    Write-Host "❌ 无效数值" -ForegroundColor Red; continue
                }
                Push-History
                $offsets[[int]$num] = $offsetSec
                Write-Host "✓ 已设置测试 $num 偏移 $offsetMin 分钟（将影响该测试及其之后的所有测试）。" -ForegroundColor Green
            }
            "2" {
                $startNum = Read-Host "请输入起始测试编号 (1~$($tests.Count))"
                if ($startNum -notmatch '^\d+$' -or [int]$startNum -lt 1 -or [int]$startNum -gt $tests.Count) {
                    Write-Host "❌ 无效编号" -ForegroundColor Red; continue
                }
                $offsetMin = Read-Host "请输入偏移量（分钟，正数后退，负数提前）"
                $offsetSec = 0
                if ($offsetMin -match '^-?\d+(\.\d+)?$') {
                    $offsetSec = [double]$offsetMin * 60
                } else {
                    Write-Host "❌ 无效数值" -ForegroundColor Red; continue
                }
                Push-History
                # 清除从起始编号开始的所有现有偏移
                $keysToRemove = $offsets.Keys | Where-Object { $_ -ge [int]$startNum }
                foreach ($key in $keysToRemove) { $offsets.Remove($key) }
                $offsets[[int]$startNum] = $offsetSec
                Write-Host "✓ 已将测试 $startNum 及其之后的所有测试整体平移 $offsetMin 分钟。" -ForegroundColor Green
                # 预览
                $tempTimeline = Build-PreviewTimeline -Tests $tests -Offsets $offsets
                Write-Host "`n平移效果预览（从测试 $startNum 开始）："
                $tempTimeline | Where-Object { $_.Number -ge $startNum } | Select-Object -First 5 | ForEach-Object {
                    $off = if ($offsets.ContainsKey($_.Number)) { $offsets[$_.Number] } else { 0 }
                    Write-Host "  测试 $($_.Number) : 新开始 $($_.NewStart)  原始 $($_.OrigStart)  偏移 $([math]::Round($off,1)) 秒"
                }
            }
            "3" {
                Push-History
                $offsets.Clear()
                Write-Host "✓ 所有偏移已重置。" -ForegroundColor Green
            }
            "4" {
                $num = Read-Host "请输入要查看的测试编号 (1~$($tests.Count))"
                if ($num -notmatch '^\d+$' -or [int]$num -lt 1 -or [int]$num -gt $tests.Count) {
                    Write-Host "❌ 无效编号" -ForegroundColor Red; continue
                }
                Show-Preview -Timeline $currentTimeline -Offsets $offsets -ShowSpecific ([int]$num)
            }
            "5" {
                $saveRequested = $true
                Write-Host "准备写入文件..." -ForegroundColor Cyan
            }
            "6" {
                Write-Host "已跳过此文件。" -ForegroundColor Yellow
                return $false
            }
            "7" {
                $num = Read-Host "请输入要对齐的测试编号 (1~$($tests.Count))"
                if ($num -notmatch '^\d+$' -or [int]$num -lt 1 -or [int]$num -gt $tests.Count) {
                    Write-Host "❌ 无效编号" -ForegroundColor Red; continue
                }
                $targetTimeStr = Read-Host "请输入目标绝对开始时间（格式：yyyy-MM-dd HH:mm:ss.fff）"
                try {
                    $targetDT = [datetime]::ParseExact($targetTimeStr, "yyyy-MM-dd HH:mm:ss.fff", $null)
                    $originalDT = $tests[[int]$num-1].StartDT
                    $offsetSec = ($targetDT - $originalDT).TotalSeconds
                    Push-History
                    $keysToRemove = $offsets.Keys | Where-Object { $_ -ge [int]$num }
                    foreach ($key in $keysToRemove) { $offsets.Remove($key) }
                    $offsets[[int]$num] = $offsetSec
                    Write-Host "✓ 已将测试 $num 的开始时间对齐到 $targetTimeStr，偏移 $([math]::Round($offsetSec/60,2)) 分钟。" -ForegroundColor Green
                    $tempTimeline = Build-PreviewTimeline -Tests $tests -Offsets $offsets
                    Write-Host "`n对齐效果预览（从测试 $num 开始）："
                    $tempTimeline | Where-Object { $_.Number -ge $num } | Select-Object -First 5 | ForEach-Object {
                        $off = if ($offsets.ContainsKey($_.Number)) { $offsets[$_.Number] } else { 0 }
                        Write-Host "  测试 $($_.Number) : 新开始 $($_.NewStart)  原始 $($_.OrigStart)  偏移 $([math]::Round($off,1)) 秒"
                    }
                } catch {
                    Write-Host "❌ 时间格式错误，请使用格式：yyyy-MM-dd HH:mm:ss.fff" -ForegroundColor Red
                }
            }
            "8" {
                Undo
            }
            default { Write-Host "❌ 无效选择" -ForegroundColor Red }
        }
    } while (-not $saveRequested)

    # 生成最终时间线
    Write-Host "正在生成最终时间线..." -ForegroundColor Cyan
    $finalTimeline = Build-PreviewTimeline -Tests $tests -Offsets $offsets

    # 替换原文件中的时间字符串
    $newLines = $lines
    foreach ($item in $finalTimeline) {
        $newLines[$item.StartIdx] = $newLines[$item.StartIdx] -replace [regex]::Escape($item.OrigStart), $item.NewStart
        $newLines[$item.EndIdx]   = $newLines[$item.EndIdx]   -replace [regex]::Escape($item.OrigEnd),   $item.NewEnd
    }

    # 写入文件
    try {
        $outDir = Split-Path $OutputFile -Parent
        if ($outDir -and -not (Test-Path $outDir)) {
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        }
        $newLines | Out-File $OutputFile -Encoding UTF8 -ErrorAction Stop
        Write-Host "✅ 文件已成功保存：$OutputFile" -ForegroundColor Green
        Write-Host "共处理 $($tests.Count) 次测试。" -ForegroundColor Green
        if ($offsets.Count -gt 0) {
            Write-Host "已应用以下偏移（仅显示首个偏移，后缀自动继承）：" -ForegroundColor Cyan
            $sortedKeys = $offsets.Keys | Sort-Object
            $firstKey = $sortedKeys[0]
            Write-Host "  从测试 $firstKey 开始整体平移 $([math]::Round($offsets[$firstKey]/60,1)) 分钟"
            if ($sortedKeys.Count -gt 1) {
                Write-Host "  注意：多个偏移值可能冲突，实际预览以最后设置为准。" -ForegroundColor Yellow
            }
        }
    } catch {
        Write-Host "❌ 写入文件失败！" -ForegroundColor Red
        Write-Host "   错误: $_" -ForegroundColor Red
        return $false
    }

    # 导出CSV报告
    $genReport = Read-Host "是否生成修正对比报告（CSV文件）？(y/n)"
    if ($genReport -eq 'y' -or $genReport -eq 'Y') {
        $reportPath = [System.IO.Path]::ChangeExtension($OutputFile, ".csv")
        $reportLines = @("TestNumber,OriginalStart,NewStart,OriginalEnd,NewEnd,OffsetSeconds,Modified")
        foreach ($item in $finalTimeline) {
            $offset = 0
            if ($offsets.ContainsKey($item.Number)) { $offset = $offsets[$item.Number] }
            $modified = if ($offset -ne 0) { "Yes" } else { "No" }
            $reportLines += "$($item.Number),$($item.OrigStart),$($item.NewStart),$($item.OrigEnd),$($item.NewEnd),$offset,$modified"
        }
        $reportLines | Out-File $reportPath -Encoding UTF8
        Write-Host "✅ 修正报告已导出：$reportPath" -ForegroundColor Green
    }

    # 设置文件时间
    function Set-FileTimeProperty {
        param($FilePath, $PropertyName, $TimeStr)
        try {
            $dt = [datetime]::ParseExact($TimeStr, "yyyy-MM-dd HH:mm:ss", $null)
            Set-ItemProperty -Path $FilePath -Name $PropertyName -Value $dt -ErrorAction Stop
            Write-Host "✅ $PropertyName 已设置为：$($dt.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Green
        } catch {
            Write-Host "❌ 设置 $PropertyName 失败：$_" -ForegroundColor Red
        }
    }

    if ($CreationTime -ne "") {
        Set-FileTimeProperty -FilePath $OutputFile -PropertyName "CreationTime" -TimeStr $CreationTime
    }
    if ($ModifyTime -ne "") {
        Set-FileTimeProperty -FilePath $OutputFile -PropertyName "LastWriteTime" -TimeStr $ModifyTime
    }
    if ($AccessTime -ne "") {
        Set-FileTimeProperty -FilePath $OutputFile -PropertyName "LastAccessTime" -TimeStr $AccessTime
    }

    if ($CreationTime -eq "" -and $ModifyTime -eq "" -and $AccessTime -eq "") {
        $setTime = Read-Host "是否需要设置文件的时间属性？(y/n)"
        if ($setTime -eq 'y' -or $setTime -eq 'Y') {
            Write-Host "`n可分别设置创建时间、修改时间、访问时间，输入空行跳过当前项。" -ForegroundColor Cyan
            $inputCreation = Read-Host "请输入创建时间（格式：yyyy-MM-dd HH:mm:ss）"
            if ($inputCreation -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$') {
                Set-FileTimeProperty -FilePath $OutputFile -PropertyName "CreationTime" -TimeStr $inputCreation
            } elseif ($inputCreation -ne "") { Write-Host "❌ 创建时间格式错误，已跳过。" -ForegroundColor Red }

            $inputModify = Read-Host "请输入修改时间（格式：yyyy-MM-dd HH:mm:ss）"
            if ($inputModify -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$') {
                Set-FileTimeProperty -FilePath $OutputFile -PropertyName "LastWriteTime" -TimeStr $inputModify
            } elseif ($inputModify -ne "") { Write-Host "❌ 修改时间格式错误，已跳过。" -ForegroundColor Red }

            $inputAccess = Read-Host "请输入访问时间（格式：yyyy-MM-dd HH:mm:ss）"
            if ($inputAccess -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$') {
                Set-FileTimeProperty -FilePath $OutputFile -PropertyName "LastAccessTime" -TimeStr $inputAccess
            } elseif ($inputAccess -ne "") { Write-Host "❌ 访问时间格式错误，已跳过。" -ForegroundColor Red }
        } else {
            Write-Host "已跳过设置文件时间。" -ForegroundColor Gray
        }
    }

    return $true
}

# 处理每个文件
$successCount = 0
foreach ($file in $InputFiles) {
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($file)
    $outFile = if ($OutputDir) {
        Join-Path $OutputDir "$baseName`_fixed.log"
    } else {
        Join-Path (Split-Path $file -Parent) "$baseName`_fixed.log"
    }
    if (Process-File -InputFile $file -OutputFile $outFile -CreationTime $CreationTime -ModifyTime $ModifyTime -AccessTime $AccessTime) {
        $successCount++
    }
    Write-Host "`n按回车键继续处理下一个文件..." -ForegroundColor Gray
    Read-Host
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "处理完成，共成功处理 $successCount / $($InputFiles.Count) 个文件。" -ForegroundColor Green
Read-Host "按回车键退出"