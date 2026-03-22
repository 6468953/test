# 设备重启压力测试批处理文件生成工具

## 概述
本工具用于根据设备列表（`devices.csv`）和模板文件（`test51.txt`）批量生成针对 66 个不同 Android 设备的重启压力测试批处理文件。每个生成的批处理文件将自动执行指定次数的设备重启测试，并记录日志。

## 文件说明
| 文件                  | 说明 |
|-----------------------|------|
| `test51.txt`          | 批处理模板文件，其中包含设备 ID 占位符 `2da2094d` 和日志文件名占位符 `51#` |
| `devices.csv`         | 设备列表，格式为 `序号,设备ID`（无表头），共 66 行 |
| `Generate-BatchFiles.ps1` | PowerShell 脚本，用于读取模板和设备列表，生成针对每个设备的独立批处理文件 |
| `test_*.bat`          | 生成的批处理文件，例如 `test_1.bat`、`test_2.bat` …… `test_66.bat` |


## 使用步骤

### 1. 准备文件
- 将 `test51.txt`、`devices.csv` 和 `Generate-BatchFiles.ps1` 放在同一个目录下。
- 检查 `devices.csv` 的内容是否正确，每行格式为 `序号,设备ID`，无表头。

### 2. 运行 PowerShell 脚本生成批处理文件
- 在文件资源管理器中，右键单击 `Generate-BatchFiles.ps1`，选择“使用 PowerShell 运行”。
- 或在 PowerShell 中切换到该目录，执行：
  ```powershell
  .\Generate-BatchFiles.ps1
  ```
- 脚本执行后，将在当前目录生成 `test_1.bat` 至 `test_66.bat` 共 66 个文件。

## 注意事项
- **编码问题**：本脚本默认使用系统 ANSI 编码（简体中文 Windows 下为 GBK），确保模板文件 `test51.txt` 也是使用该编码保存，否则可能出现中文乱码。如果模板文件为 UTF-8 格式，请修改脚本中的 `-Encoding Default` 为 `-Encoding UTF8`。
- **ADB 命令**：请确保 ADB 已正确安装且版本兼容，否则批处理可能会因 `adb` 命令失败而中断。
- **设备 ID 匹配**：生成的批处理文件中的设备 ID 直接取自 `devices.csv`，请确保其与 `adb devices` 显示的一致（通常为序列号）。
- **权限**：某些设备可能需要先执行 `adb root` 才能执行 `sys_reboot` 命令，模板中已包含该步骤。如果设备不支持 `adb root`，可自行修改模板。
- **日志目录**：脚本会在 `./LOG/` 下创建日志文件，请确保该目录存在或脚本有创建权限，否则日志写入会失败。

## 常见问题

### Q1: 生成批处理后，打开发现中文注释变成了“？”
**解决方法**：模板文件 `test51.txt` 的编码与脚本读取/写入编码不一致。请确认：
- 模板文件保存为 ANSI（记事本另存为，编码选择“ANSI”）。
- 脚本中的 `-Encoding Default` 保持不变。
- 如果模板必须是 UTF-8，则将脚本中的两处 `-Encoding Default` 都改为 `-Encoding UTF8`。

### Q2: 运行批处理时提示“adb 不是内部或外部命令”
**解决方法**：ADB 未添加到系统环境变量。请将 ADB 所在目录（如 `C:\platform-tools`）添加到系统 `PATH` 中，或修改批处理文件，在 `adb` 前加上完整路径。
