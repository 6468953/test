# Generate-BatchFiles.ps1
# 功能：根据模板和CSV生成每个设备的批处理文件

# 定义输入文件
$templateFile = "test51.txt"
$csvFile = "devices.csv"

# 检查模板文件是否存在
if (-not (Test-Path $templateFile)) {
    Write-Error "错误：找不到模板文件 '$templateFile'，请确保它在当前目录。"
    exit 1
}

# 检查设备列表文件是否存在
if (-not (Test-Path $csvFile)) {
    Write-Error "错误：找不到设备列表文件 '$csvFile'，请确保它在当前目录。"
    exit 1
}

# 读取模板内容（保留原始格式，包括换行和特殊符号）
$template = Get-Content -Path $templateFile -Raw

# 读取CSV（无表头，指定列名为“序号”和“设备ID”）
# 使用 -Encoding Default 以匹配CSV可能的ANSI编码（若为UTF-8可改为 -Encoding UTF8）
$devices = Import-Csv -Path $csvFile -Header "序号", "设备ID" -Encoding Default

# 循环处理每个设备
foreach ($d in $devices) {
    $number = $d.序号      # 序号 1..66
    $deviceId = $d.设备ID   # 设备ID（如 4168cdd6）

    # 替换内容：将默认设备ID替换为当前ID，并将“51#”替换为“序号#”
    $newContent = $template.Replace('2da2094d', $deviceId).Replace('51#', "${number}#")

    # 生成输出文件名（例如 test_1.bat）
    $outputFile = "test_$number.bat"

    # 写入文件，使用ASCII编码确保批处理兼容性
    $newContent | Set-Content -Path $outputFile -Encoding ASCII

    Write-Host "已生成: $outputFile"
}

Write-Host "所有文件生成完毕！"