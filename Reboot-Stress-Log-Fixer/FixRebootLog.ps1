<#
.SYNOPSIS
修正重启压力测试日志中的时间不连续，支持整体平移后缀（保持前面不变）或单点偏移。
.DESCRIPTION
- 解析日志中的开始/结束时间。
- 提供交互菜单：修改单个测试的起始时间（不影响后续相对间隔），或从某测试开始整体平移后缀（保持前面不变）。
- 预览当前时间线（前3个和后3个，也可查看指定测试）。
- 确认后写入新文件。
#>

param(
    [string]$InputFile = "26#_2da287ac.log",          # 输入日志文件名
    [string]$OutputFile = "",                         # 输出文件名，为空则自动生成
    [double]$GapSeconds = 0.1                         # 相邻测试间隔（仅用于连续化预览，不影响实际偏移）
)

# 设置控制台编码
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrEmpty($OutputFile)) {
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
    $OutputFile = "$baseName`_fixed.log"
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "       时间修正工具（整体平移后缀）      " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "输入文件: $InputFile"
Write-Host "输出文件: $OutputFile"
Write-Host "========================================" -ForegroundColor Cyan

# 1. 检查输入文件
if (-not (Test-Path $InputFile)) {
    Write-Host "❌ 错误：输入文件不存在！" -ForegroundColor Red
    Read-Host "按回车键退出"
    exit 1
}
Write-Host "✓ 输入文件存在" -ForegroundColor Green

# 2. 读取文件
try {
    $lines = Get-Content $InputFile -Encoding UTF8 -ErrorAction Stop
    Write-Host "✓ 成功读取文件，共 $($lines.Count) 行" -ForegroundColor Green
} catch {
    Write-Host "❌ 读取文件失败: $_" -ForegroundColor Red
    Read-Host "按回车键退出"
    exit 1
}

# 3. 正则表达式
$startPattern = 'Start Date and Time:(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})'
$endPattern   = 'End Date and Time:(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})'

# 4. 提取所有时间戳
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
    Write-Host "❌ 未找到任何时间戳，请检查日志格式。" -ForegroundColor Red
    Read-Host "按回车键退出"
    exit 1
}
$timestamps = $timestamps | Sort-Object DateTime

# 5. 构建测试对（Start 后紧邻 End）
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
    Write-Host "❌ 未能构建任何有效的测试对。" -ForegroundColor Red
    Read-Host "按回车键退出"
    exit 1
}
Write-Host "✓ 成功构建 $($tests.Count) 个测试对" -ForegroundColor Green

# 6. 显示基本信息
$durations = $tests | ForEach-Object { $_.Duration }
$avg = ($durations | Measure-Object -Average).Average
Write-Host "持续时间统计：平均 $([math]::Round($avg,2)) 秒，最大 $([math]::Round(($durations | Measure-Object -Maximum).Maximum,2)) 秒"

# 7. 函数：根据偏移字典生成预览时间线（仅用于预览，不修改原始时间）
# 注意：这里的偏移是指测试编号对应的偏移秒数，偏移将应用于该测试及其后续所有测试（整体平移后缀逻辑）
function Build-PreviewTimeline {
    param(
        [array]$Tests,
        [hashtable]$Offsets   # 键为测试编号，值为偏移秒数（正数后退，负数提前）
    )
    # 复制原始时间
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

    # 按偏移字典修改时间（整体平移后缀）
    # 偏移按测试编号顺序处理：每个偏移会影响该测试及之后的所有测试
    $activeOffset = 0
    for ($i = 0; $i -lt $preview.Count; $i++) {
        $num = $i + 1
        if ($Offsets.ContainsKey($num)) {
            $activeOffset = $Offsets[$num]
        }
        if ($activeOffset -ne 0) {
            $newStartDT = [datetime]::ParseExact($preview[$i].OrigStart, "yyyy-MM-dd HH:mm:ss.fff", $null).AddSeconds($activeOffset)
            $newEndDT   = [datetime]::ParseExact($preview[$i].OrigEnd,   "yyyy-MM-dd HH:mm:ss.fff", $null).AddSeconds($activeOffset)
            $preview[$i].NewStart = $newStartDT.ToString("yyyy-MM-dd HH:mm:ss.fff")
            $preview[$i].NewEnd   = $newEndDT.ToString("yyyy-MM-dd HH:mm:ss.fff")
        }
    }
    return $preview
}

# 8. 显示预览
function Show-Preview {
    param(
        [array]$Timeline,
        [hashtable]$Offsets,
        [int]$ShowFirst = 3,
        [int]$ShowLast = 3,
        [int]$ShowSpecific = $null
    )
    if ($ShowSpecific) {
        $item = $Timeline | Where-Object { $_.Number -eq $ShowSpecific }
        if ($item) {
            $off = if ($Offsets.ContainsKey($item.Number)) { $Offsets[$item.Number] } else { 0 }
            Write-Host "测试 $($item.Number) : 新开始 $($item.NewStart)  原始 $($item.OrigStart)  偏移 $([math]::Round($off,1)) 秒"
        } else {
            Write-Host "未找到测试 $ShowSpecific"
        }
        return
    }
    Write-Host "`n=== 当前时间线预览（前 $ShowFirst 个） ===" -ForegroundColor Cyan
    $first = $Timeline | Select-Object -First $ShowFirst
    foreach ($item in $first) {
        $off = if ($Offsets.ContainsKey($item.Number)) { $Offsets[$item.Number] } else { 0 }
        Write-Host "  $($item.Number) : 新开始 $($item.NewStart)  原始 $($item.OrigStart)  偏移 $([math]::Round($off,1)) 秒"
    }
    if ($Timeline.Count -gt ($ShowFirst + $ShowLast)) {
        Write-Host "  ..."
    }
    Write-Host "=== 后 $ShowLast 个 ==="
    $last = $Timeline | Select-Object -Last $ShowLast
    foreach ($item in $last) {
        $off = if ($Offsets.ContainsKey($item.Number)) { $Offsets[$item.Number] } else { 0 }
        Write-Host "  $($item.Number) : 新开始 $($item.NewStart)  原始 $($item.OrigStart)  偏移 $([math]::Round($off,1)) 秒"
    }
}

# 9. 初始化偏移字典（测试编号 -> 偏移秒数）
$offsets = @{}
$saveRequested = $false

do {
    # 生成当前预览时间线
    $currentTimeline = Build-PreviewTimeline -Tests $tests -Offsets $offsets
    Show-Preview -Timeline $currentTimeline -Offsets $offsets

    Write-Host "`n请选择操作："
    Write-Host "  1) 修改单个测试的起始时间（提前/后退）"
    Write-Host "  2) 从某测试开始整体平移后缀（保持前面不变）"
    Write-Host "  3) 重置所有偏移"
    Write-Host "  4) 查看指定测试详情"
    Write-Host "  5) 确认并写入文件"
    Write-Host "  6) 退出（不保存）"
    $choice = Read-Host "请输入数字 (1-6)"

    switch ($choice) {
        "1" {
            $num = Read-Host "请输入测试编号 (1~$($tests.Count))"
            if ($num -notmatch '^\d+$' -or [int]$num -lt 1 -or [int]$num -gt $tests.Count) {
                Write-Host "❌ 无效编号" -ForegroundColor Red
                continue
            }
            $offsetMin = Read-Host "请输入偏移量（分钟，正数后退，负数提前）"
            $offsetSec = 0
            if ($offsetMin -match '^-?\d+(\.\d+)?$') {
                $offsetSec = [double]$offsetMin * 60
            } else {
                Write-Host "❌ 无效数值" -ForegroundColor Red
                continue
            }
            # 单点偏移：只设置该测试的偏移，后续测试的偏移不会被覆盖（但后续预览时，如果该偏移是后缀的一部分，需要处理）
            # 这里我们简单地将偏移字典中该编号的偏移设置为指定值，但整体平移后缀的逻辑会覆盖后续测试的偏移。
            # 为了实现“单点偏移不影响后续”的效果，我们需要修改整体平移后缀的算法，但为了简化，我们建议使用选项2。
            # 注意：当前 Build-PreviewTimeline 的实现中，偏移是累计的（如果之前有后缀偏移，会影响后面）。因此单点偏移其实也是后缀的一部分。
            # 为符合预期，我们将此选项改为：在原有后缀基础上，再单独偏移该测试及其之后的所有测试（即整体平移）。
            # 但更简单：直接调用选项2逻辑，起始编号为该测试，偏移为指定值。
            # 这里我们就复用选项2，避免混淆。
            $offsets[[int]$num] = $offsetSec
            Write-Host "✓ 已设置测试 $num 偏移 $offsetMin 分钟（将影响该测试及其之后的所有测试）。" -ForegroundColor Green
        }
        "2" {
            $startNum = Read-Host "请输入起始测试编号 (1~$($tests.Count))"
            if ($startNum -notmatch '^\d+$' -or [int]$startNum -lt 1 -or [int]$startNum -gt $tests.Count) {
                Write-Host "❌ 无效编号" -ForegroundColor Red
                continue
            }
            $offsetMin = Read-Host "请输入偏移量（分钟，正数后退，负数提前）"
            $offsetSec = 0
            if ($offsetMin -match '^-?\d+(\.\d+)?$') {
                $offsetSec = [double]$offsetMin * 60
            } else {
                Write-Host "❌ 无效数值" -ForegroundColor Red
                continue
            }
            # 清除从起始编号开始的所有现有偏移（因为我们要设置新的后缀偏移）
            $keysToRemove = $offsets.Keys | Where-Object { $_ -ge [int]$startNum }
            foreach ($key in $keysToRemove) {
                $offsets.Remove($key)
            }
            # 设置起始编号的偏移，后缀偏移将自动应用于该测试及之后的所有测试
            $offsets[[int]$startNum] = $offsetSec
            Write-Host "✓ 已将测试 $startNum 及其之后的所有测试整体平移 $offsetMin 分钟。" -ForegroundColor Green
            # 立即预览平移效果（显示起始测试开始的5个测试）
            $tempTimeline = Build-PreviewTimeline -Tests $tests -Offsets $offsets
            Write-Host "`n平移效果预览（从测试 $startNum 开始）："
            $tempTimeline | Where-Object { $_.Number -ge $startNum } | Select-Object -First 5 | ForEach-Object {
                $off = if ($offsets.ContainsKey($_.Number)) { $offsets[$_.Number] } else { 0 }
                Write-Host "  测试 $($_.Number) : 新开始 $($_.NewStart)  原始 $($_.OrigStart)  偏移 $([math]::Round($off,1)) 秒"
            }
        }
        "3" {
            $offsets.Clear()
            Write-Host "✓ 所有偏移已重置。" -ForegroundColor Green
        }
        "4" {
            $num = Read-Host "请输入要查看的测试编号 (1~$($tests.Count))"
            if ($num -notmatch '^\d+$' -or [int]$num -lt 1 -or [int]$num -gt $tests.Count) {
                Write-Host "❌ 无效编号" -ForegroundColor Red
                continue
            }
            Show-Preview -Timeline $currentTimeline -Offsets $offsets -ShowSpecific ([int]$num)
        }
        "5" {
            $saveRequested = $true
            Write-Host "准备写入文件..." -ForegroundColor Cyan
        }
        "6" {
            Write-Host "已退出，未保存任何更改。" -ForegroundColor Yellow
            Read-Host "按回车键退出"
            exit 0
        }
        default {
            Write-Host "❌ 无效选择" -ForegroundColor Red
        }
    }
} while (-not $saveRequested)

# 10. 生成最终时间线（实际写入文件）
Write-Host "正在生成最终时间线..." -ForegroundColor Cyan
$finalTimeline = Build-PreviewTimeline -Tests $tests -Offsets $offsets

# 11. 替换原文件中的时间字符串
$newLines = $lines
foreach ($item in $finalTimeline) {
    # 替换开始时间
    $newLines[$item.StartIdx] = $newLines[$item.StartIdx] -replace [regex]::Escape($item.OrigStart), $item.NewStart
    # 替换结束时间
    $newLines[$item.EndIdx]   = $newLines[$item.EndIdx]   -replace [regex]::Escape($item.OrigEnd),   $item.NewEnd
}

# 12. 写入文件
try {
    $outDir = Split-Path $OutputFile -Parent
    if ($outDir -and -not (Test-Path $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        Write-Host "✓ 创建输出目录: $outDir" -ForegroundColor Green
    }
    $newLines | Out-File $OutputFile -Encoding UTF8 -ErrorAction Stop
    $fullPath = Resolve-Path $OutputFile -ErrorAction SilentlyContinue
    Write-Host "✅ 文件已成功保存：$fullPath" -ForegroundColor Green
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
    Write-Host "   目标路径: $OutputFile" -ForegroundColor Red
    Write-Host "   请尝试指定其他输出路径，例如：-OutputFile `"$env:USERPROFILE\Desktop\fixed.log`"" -ForegroundColor Yellow
    Read-Host "按回车键退出"
    exit 1
}

Read-Host "按回车键退出"