import serial
import time
from datetime import datetime

# ========== 配置参数 ==========
COM_PORT = 'COM3'          # 串口号，如 COM3
BAUD_RATE = 9600
CHANNEL = 'OUT1'           # 控制的通道：OUT1 或 OUT2
VOLTAGE = 5.0              # 设置电压 (V)
CURRENT = 1.0              # 设置限流 (A)
ON_TIME = 5                # 每次 ON 持续秒数
OFF_TIME = 5               # 每次 OFF 等待秒数
CYCLE_COUNT = 10           # 循环次数（None 表示无限循环）

# 测量记录相关
ENABLE_MEASURE = True      # 是否记录测量值
MEASURE_INTERVAL = 1.0     # 采样间隔（秒），仅在 ON 期间采样

# 日志文件
LOG_FILE = 'log.txt'       # 操作日志
CSV_FILE = 'measure.csv'   # 测量数据文件（CSV格式）
# =============================

def log(msg):
    """写入操作日志并打印"""
    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    line = f'{timestamp} - {msg}'
    print(line)
    with open(LOG_FILE, 'a', encoding='utf-8') as f:
        f.write(line + '\n')

def write_csv(cycle, timestamp, voltage, current):
    """写入测量数据到CSV"""
    with open(CSV_FILE, 'a', encoding='utf-8') as f:
        f.write(f'{cycle},{timestamp},{voltage},{current}\n')

def send_cmd(ser, cmd, wait=0.3):
    """发送命令并可选读取响应"""
    ser.write((cmd + '\n').encode())
    time.sleep(wait)
    if ser.in_waiting:
        resp = ser.read(ser.in_waiting).decode().strip()
        if resp:
            log(f'<- {resp}')
        return resp
    return None

def measure(ser, cycle):
    """读取当前通道的电压和电流，返回 (电压, 电流)"""
    # 测量电压
    send_cmd(ser, 'MEAS:VOLT?')
    # 响应格式：例如 "+5.012E+0"
    volt_str = ser.readline().decode().strip()
    # 测量电流
    send_cmd(ser, 'MEAS:CURR?')
    curr_str = ser.readline().decode().strip()
    try:
        volt = float(volt_str)
        curr = float(curr_str)
    except:
        volt = curr = 0.0
    # 记录到CSV
    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    write_csv(cycle, timestamp, volt, curr)
    log(f'测量: {volt:.4f}V, {curr:.4f}A')
    return volt, curr

def main():
    log('========== 程序启动（带测量记录） ==========')
    # 初始化CSV文件头
    with open(CSV_FILE, 'w', encoding='utf-8') as f:
        f.write('Cycle,Timestamp,Voltage(V),Current(A)\n')

    try:
        ser = serial.Serial(COM_PORT, BAUD_RATE, timeout=1)
        log(f'已连接 {COM_PORT} 波特率 {BAUD_RATE}')
    except Exception as e:
        log(f'打开串口失败: {e}')
        return

    # 1. 测试连接
    send_cmd(ser, '*IDN?')
    # 2. 选择通道
    send_cmd(ser, f'INST:SEL {CHANNEL}')
    # 3. 设置电压和电流
    send_cmd(ser, f'VOLT {VOLTAGE}')
    send_cmd(ser, f'CURR {CURRENT}')
    log(f'参数设置完成：通道{CHANNEL}，{VOLTAGE}V / {CURRENT}A')

    count = 0
    try:
        while CYCLE_COUNT is None or count < CYCLE_COUNT:
            count += 1
            log(f'----- 第 {count} 次循环开始 -----')

            # 开启输出
            send_cmd(ser, 'OUTP ON')
            log('输出已开启')

            # 在ON期间进行测量采样
            if ENABLE_MEASURE:
                start_time = time.time()
                while time.time() - start_time < ON_TIME:
                    measure(ser, count)          # 测量一次
                    time.sleep(MEASURE_INTERVAL) # 等待下次采样
            else:
                time.sleep(ON_TIME)

            # 关闭输出
            send_cmd(ser, 'OUTP OFF')
            log('输出已关闭')
            time.sleep(OFF_TIME)

            if CYCLE_COUNT is not None and count >= CYCLE_COUNT:
                break

    except KeyboardInterrupt:
        log('用户中断，正在关闭...')
    finally:
        # 确保最后关闭输出
        send_cmd(ser, 'OUTP OFF')
        ser.close()
        log('串口已关闭，程序结束')
        log('========== 日志结束 ==========')

if __name__ == '__main__':
    main()