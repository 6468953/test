#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Keithley 2303 电源循环测试工具 - 串口版
通过 RS232 控制电源，自动记录电压电流到 CSV
"""

import sys
import time
import csv
import os
import configparser
import traceback
from datetime import datetime
import signal

# 导入串口库
try:
    import serial
    import serial.tools.list_ports
    SERIAL_AVAILABLE = True
except ImportError:
    SERIAL_AVAILABLE = False
    print("错误：未安装 pyserial 库，请先安装：pip install pyserial")
    sys.exit(1)


def get_config_value(config, section, key, fallback=None):
    """获取配置值，自动去除行内注释（# 后的内容）"""
    try:
        value = config.get(section, key, fallback=fallback)
        if value is None:
            return fallback
        if '#' in value:
            value = value.split('#')[0].strip()
        return value.strip()
    except (configparser.NoSectionError, configparser.NoOptionError):
        return fallback


class Keithley2303Serial:
    """通过 RS232 串口控制 Keithley 2303"""

    def __init__(self, port, baudrate=4800, timeout=2):
        self.port = port
        self.baudrate = baudrate
        self.timeout = timeout
        self.ser = None
        self._connect()

    def _connect(self):
        """打开串口并验证连接"""
        try:
            self.ser = serial.Serial(
                port=self.port,
                baudrate=self.baudrate,
                bytesize=8,
                parity='N',
                stopbits=1,
                timeout=self.timeout,
                write_timeout=self.timeout
            )
            # 等待设备就绪
            time.sleep(0.5)
            self.ser.reset_input_buffer()
            self.ser.reset_output_buffer()

            # 发送 *IDN? 验证连接
            self.write('*IDN?')
            idn = self.read().strip()
            if idn:
                print(f"✓ 已连接串口设备: {idn}")
            else:
                print("警告：无法读取设备 ID，请检查连接和波特率")
        except Exception as e:
            raise Exception(f"串口连接失败: {e}")

    def write(self, cmd):
        """发送命令，自动添加回车换行"""
        self.ser.write(f"{cmd}\r\n".encode())
        time.sleep(0.05)  # 短延时确保命令执行

    def read(self):
        """读取一行响应"""
        return self.ser.readline().decode().strip()

    def query(self, cmd):
        """发送查询并返回结果"""
        self.write(cmd)
        return self.read()

    def output_on(self):
        self.write(':OUTP ON')

    def output_off(self):
        self.write(':OUTP OFF')

    def set_voltage(self, voltage):
        self.write(f':SOUR:VOLT {voltage}')

    def set_current_limit(self, current):
        self.write(f':SOUR:CURR {current}')

    def read_all(self):
        """返回 {'voltage': float, 'current': float, 'timestamp': datetime}"""
        try:
            self.write(':READ?')
            resp = self.read()
            parts = resp.split(',')
            if len(parts) >= 2:
                voltage = float(parts[0])
                current = float(parts[1])
                return {
                    'voltage': voltage,
                    'current': current,
                    'timestamp': datetime.now()
                }
            else:
                return None
        except Exception as e:
            print(f"读取数据失败: {e}")
            return None

    def close(self):
        """关闭串口，恢复本地控制"""
        try:
            self.output_off()
            self.ser.close()
        except:
            pass


class PowerCycleTester:
    def __init__(self, config):
        self.config = config
        try:
            port = get_config_value(config, 'Interface', 'port', 'COM3')
            baudrate = int(get_config_value(config, 'Interface', 'baudrate', '4800'))
            self.power = Keithley2303Serial(port, baudrate)
        except Exception as e:
            print(f"初始化电源连接失败: {e}")
            raise

        self.data_file = None
        self.csv_writer = None
        self._init_csv()
        self.running = True

    def _init_csv(self):
        log_file = get_config_value(self.config, 'Test', 'log_file', '')
        if not log_file:
            log_file = f"power_test_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"
        self.data_file = open(log_file, 'w', newline='', encoding='utf-8')
        self.csv_writer = csv.writer(self.data_file)
        self.csv_writer.writerow([
            'cycle', 'timestamp', 'on_time', 'off_time',
            'voltage_on_start', 'current_on_start',
            'voltage_on_end', 'current_on_end',
            'voltage_off', 'current_off', 'status'
        ])
        self.data_file.flush()
        print(f"日志文件: {log_file}")

    def _log_row(self, data):
        self.csv_writer.writerow(data)
        self.data_file.flush()

    def _safe_read(self, retries=3):
        for i in range(retries):
            data = self.power.read_all()
            if data is not None:
                return data
            time.sleep(0.2)
        return None

    def run_cycle(self, cycle_num):
        """执行一次完整循环，返回记录字典"""
        on_time = int(get_config_value(self.config, 'Test', 'on_time', '5'))
        off_time = int(get_config_value(self.config, 'Test', 'off_time', '3'))

        result = {
            'cycle': cycle_num,
            'timestamp': datetime.now(),
            'status': 'OK'
        }

        try:
            # ----- 开机 -----
            self.power.output_on()
            time.sleep(0.1)
            start_data = self._safe_read()
            if start_data:
                result['voltage_on_start'] = start_data['voltage']
                result['current_on_start'] = start_data['current']
            else:
                result['status'] = 'ERROR: no read on start'

            # 开机保持
            time.sleep(on_time)
            result['on_time'] = on_time

            end_data = self._safe_read()
            if end_data:
                result['voltage_on_end'] = end_data['voltage']
                result['current_on_end'] = end_data['current']
            else:
                result['status'] = 'ERROR: no read before off'

            # ----- 关机 -----
            self.power.output_off()
            time.sleep(0.1)
            off_data = self._safe_read()
            if off_data:
                result['voltage_off'] = off_data['voltage']
                result['current_off'] = off_data['current']
            else:
                result['status'] = 'ERROR: no read after off'

            # 关机保持
            time.sleep(off_time)
            result['off_time'] = off_time

            # 验证关机状态（电压应接近0）
            if off_data and abs(off_data['voltage']) > 0.1:
                result['status'] = 'WARNING: voltage not zero after off'

        except Exception as e:
            result['status'] = f'ERROR: {str(e)}'
            # 尝试强制关闭
            try:
                self.power.output_off()
            except:
                pass

        return result

    def run(self):
        """主循环"""
        total_cycles = int(get_config_value(self.config, 'Test', 'total_cycles', '0'))  # 0 = 无限
        on_time = get_config_value(self.config, 'Test', 'on_time', '5')
        off_time = get_config_value(self.config, 'Test', 'off_time', '3')
        print(f"开始测试: 开机{on_time}秒, 关机{off_time}秒")
        if total_cycles > 0:
            print(f"总循环次数: {total_cycles}")
        else:
            print("无限循环模式，按 Ctrl+C 停止")

        cycle = 0
        error_count = 0
        warning_count = 0

        try:
            while self.running:
                cycle += 1
                result = self.run_cycle(cycle)

                # 记录CSV
                row = [
                    result['cycle'],
                    result['timestamp'].strftime('%Y-%m-%d %H:%M:%S.%f')[:-3],
                    result.get('on_time', ''),
                    result.get('off_time', ''),
                    result.get('voltage_on_start', ''),
                    result.get('current_on_start', ''),
                    result.get('voltage_on_end', ''),
                    result.get('current_on_end', ''),
                    result.get('voltage_off', ''),
                    result.get('current_off', ''),
                    result.get('status', 'OK')
                ]
                self._log_row(row)

                # 更新统计
                if 'ERROR' in result.get('status', ''):
                    error_count += 1
                elif 'WARNING' in result.get('status', ''):
                    warning_count += 1

                # 打印进度
                icon = '✓' if result['status'] == 'OK' else '⚠'
                voltage = result.get('voltage_on_end', 0)
                current = result.get('current_on_end', 0)
                print(f"{icon} 第{cycle}次 | 电压:{voltage:.3f}V 电流:{current:.4f}A | {result['status']}")

                # 检查是否达到指定次数
                if total_cycles > 0 and cycle >= total_cycles:
                    print(f"\n达到预设循环次数 {total_cycles}，测试结束")
                    break

        except KeyboardInterrupt:
            print("\n用户中断测试")
        finally:
            self.power.close()
            self.data_file.close()
            self._print_summary(cycle, error_count, warning_count)

    def _print_summary(self, total, errors, warnings):
        print("\n========== 测试摘要 ==========")
        print(f"总循环次数: {total}")
        print(f"异常次数: {errors}")
        print(f"警告次数: {warnings}")
        if total > 0:
            print(f"成功率: {(total - errors - warnings)/total*100:.2f}%")
        print("===============================")


def main():
    # 全局异常捕获，防止闪退
    try:
        # 读取配置文件
        config_file = 'config.ini'
        if not os.path.exists(config_file):
            print(f"错误：找不到配置文件 {config_file}")
            print("请确保 config.ini 与程序在同一目录下")
            input("按 Enter 退出...")
            return

        config = configparser.ConfigParser()
        config.read(config_file, encoding='utf-8')

        # 检查必要的节
        if 'Test' not in config or 'Interface' not in config:
            print("配置文件格式错误：缺少 [Test] 或 [Interface] 节")
            print("请参考示例配置文件修正")
            input("按 Enter 退出...")
            return

        # 验证必要参数
        if not get_config_value(config, 'Test', 'on_time'):
            print("配置文件缺少 on_time 参数")
            input("按 Enter 退出...")
            return
        if not get_config_value(config, 'Test', 'off_time'):
            print("配置文件缺少 off_time 参数")
            input("按 Enter 退出...")
            return
        if get_config_value(config, 'Interface', 'interface', '').lower() != 'serial':
            print("配置文件 interface 必须设置为 serial")
            input("按 Enter 退出...")
            return

        # 设置信号处理，优雅退出
        def signal_handler(sig, frame):
            print("\n正在停止...")
            sys.exit(0)
        signal.signal(signal.SIGINT, signal_handler)

        # 启动测试
        tester = PowerCycleTester(config)
        tester.run()

        input("\n测试完成，按 Enter 退出...")

    except Exception as e:
        print(f"\n程序发生未捕获异常: {e}")
        traceback.print_exc()
        input("\n按 Enter 退出...")


if __name__ == '__main__':
    main()