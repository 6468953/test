import serial
import time
import configparser
import os
from datetime import datetime

# 读取配置文件
config = configparser.ConfigParser()
config.read('config.ini', encoding='utf-8')

# 参数设置
COM_PORT = config.get('SETTINGS', 'COM_PORT', fallback='COM3')
BAUD_RATE = config.getint('SETTINGS', 'BAUD_RATE', fallback=9600)
CHANNEL = config.get('SETTINGS', 'CHANNEL', fallback='OUT1')
VOLTAGE = config.getfloat('SETTINGS', 'VOLTAGE', fallback=5.0)
CURRENT = config.getfloat('SETTINGS', 'CURRENT', fallback=1.0)
ON_TIME = config.getfloat('SETTINGS', 'ON_TIME', fallback=5)
OFF_TIME = config.getfloat('SETTINGS', 'OFF_TIME', fallback=5)
CYCLE_COUNT = config.getint('SETTINGS', 'CYCLE_COUNT', fallback=10)
ENABLE_MEASURE = config.getboolean('SETTINGS', 'ENABLE_MEASURE', fallback=True)
MEASURE_INTERVAL = config.getfloat('SETTINGS', 'MEASURE_INTERVAL', fallback=1.0)

LOG_FILE = 'log.txt'
CSV_FILE = 'measure.csv'

def log(msg):
    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    line = f'{timestamp} - {msg}'
    print(line)
    with open(LOG_FILE, 'a', encoding='utf-8') as f:
        f.write(line + '\n')

def send_cmd(ser, cmd, wait=0.3):
    ser.write((cmd + '\n').encode())
    time.sleep(wait)
    if ser.in_waiting:
        resp = ser.read(ser.in_waiting).decode().strip()
        if resp:
            log(f'<- {resp}')
        return resp
    return None

def measure(ser, cycle):
    send_cmd(ser, 'MEAS:VOLT?')
    volt_str = ser.readline().decode().strip()
    send_cmd(ser, 'MEAS:CURR?')
    curr_str = ser.readline().decode().strip()
    try:
        volt = float(volt_str)
        curr = float(curr_str)
    except:
        volt = curr = 0.0
    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    with open(CSV_FILE, 'a', encoding='utf-8') as f:
        f.write(f'{cycle},{timestamp},{volt},{curr}\n')
    log(f'测量: {volt:.4f}V, {curr:.4f}A')
    return volt, curr

def main():
    log('========== 程序启动 ==========')
    # 初始化 CSV 头
    with open(CSV_FILE, 'w', encoding='utf-8') as f:
        f.write('Cycle,Timestamp,Voltage(V),Current(A)\n')

    try:
        ser = serial.Serial(COM_PORT, BAUD_RATE, timeout=1)
        log(f'已连接 {COM_PORT} 波特率 {BAUD_RATE}')
    except Exception as e:
        log(f'打开串口失败: {e}')
        return

    send_cmd(ser, '*IDN?')
    send_cmd(ser, f'INST:SEL {CHANNEL}')
    send_cmd(ser, f'VOLT {VOLTAGE}')
    send_cmd(ser, f'CURR {CURRENT}')
    log(f'参数设置完成：通道{CHANNEL}，{VOLTAGE}V / {CURRENT}A')

    count = 0
    try:
        while CYCLE_COUNT is None or count < CYCLE_COUNT:
            count += 1
            log(f'----- 第 {count} 次循环开始 -----')
            send_cmd(ser, 'OUTP ON')
            log('输出已开启')

            if ENABLE_MEASURE:
                start_time = time.time()
                while time.time() - start_time < ON_TIME:
                    measure(ser, count)
                    time.sleep(MEASURE_INTERVAL)
            else:
                time.sleep(ON_TIME)

            send_cmd(ser, 'OUTP OFF')
            log('输出已关闭')
            time.sleep(OFF_TIME)

            if CYCLE_COUNT is not None and count >= CYCLE_COUNT:
                break
    except KeyboardInterrupt:
        log('用户中断')
    finally:
        send_cmd(ser, 'OUTP OFF')
        ser.close()
        log('程序结束')

if __name__ == '__main__':
    main()