import time
import collections
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from matplotlib.colors import Normalize
import serial
import serial.tools.list_ports
import kconvert

# ========= 图像/滚动特征 =========
INITIAL_WINDOW = 160
FINAL_WINDOW   = 700
DRAW_RATE      = 0.05     # 画图刷新节奏（秒）
Y_MIN, Y_MAX   = 0, 300

# ========= 冷端温度（和你们 UI 里的 CJTemp 一样）=========
CJ_TEMP_C = 22.0          # 你也可以改成输入/文件读取

# ========= 是否把温度发给 DE10（可选，默认关）=========
SEND_TO_DE10 = False
DE10_PORT = "COM9"
DE10_BAUD = 115200

# ========= 万用表设置（和你们代码一致）=========
METER_BAUD = 9600

# ========= 颜色映射 =========
cmap = plt.get_cmap("coolwarm")
norm = Normalize(vmin=Y_MIN, vmax=Y_MAX)

def find_meter():
    """
    按你们 FindPort 的逻辑扫描串口：
    - 打开端口
    - 发 Ctrl-C 请求 prompt '=>'
    - 识别到 prompt 后，发送 'VDC; RATE S; *IDN?' 并读回 ID
    - 发 'MEAS1?' 请求第一笔数据
    """
    portlist = list(serial.tools.list_ports.comports())
    for item in reversed(portlist):
        port = item.device if hasattr(item, "device") else item[0]
        try:
            ser = serial.Serial(port, METER_BAUD, timeout=0.5)
            time.sleep(0.2)
            ser.write(b"\x03")
            pstring = ser.readline().decode(errors="ignore")
            if len(pstring) > 1 and pstring[1] == ">":
                ser.timeout = 3
                ser.write(b"VDC; RATE S; *IDN?\r\n")
                devicename = ser.readline().decode(errors="ignore").strip()
                ser.readline()              # discard prompt
                ser.write(b"MEAS1?\r\n")    # request first value
                return ser, port, devicename
            ser.close()
        except Exception:
            try:
                ser.close()
            except Exception:
                pass
    return None, None, None

def read_meter_vdc(ser):
    """
    读万用表一笔：形如 '+0.234E-3 VDC'
    并处理你们代码中的 out-of-sync 情况，然后发送下一次 MEAS1?
    返回：float volts 或 None
    """
    try:
        s = ser.readline().decode(errors="ignore")
        ser.readline()  # discard prompt '=>'

        if len(s) > 1 and s[1] == ">":  # out of sync
            s = ser.readline().decode(errors="ignore")

        ser.write(b"MEAS1?\r\n")

        s_clean = s.replace("VDC", "").strip()
        if not s_clean:
            return None
        return float(s_clean)
    except Exception:
        return None

def volts_to_tempC(v_volts, cj_c):
    # 你们代码：V -> mV，然后 kconvert
    mv = v_volts * 1000.0
    return float(kconvert.mV_to_C(mv, cj_c))

# ====== (可选) 打开 DE10 串口 ======
ser2 = None
if SEND_TO_DE10:
    try:
        ser2 = serial.Serial(DE10_PORT, DE10_BAUD, timeout=0)
        print(f"[OK] DE10 serial opened: {DE10_PORT} @ {DE10_BAUD}")
    except Exception:
        print(f"[WARN] DE10 port {DE10_PORT} not available, SEND_TO_DE10 disabled.")
        ser2 = None
        SEND_TO_DE10 = False

# ====== 连接万用表 ======
ser, meter_port, meter_idn = find_meter()
if ser is None:
    raise RuntimeError("Multimeter not found. Check: 9600 8N1, echo Off, and no other program is using the COM port.")

print(f"[OK] Multimeter connected on {meter_port}")
print(f"[IDN] {meter_idn}")

# ====== 画图初始化 ======
plt.ion()
fig, ax = plt.subplots()
ax.set_title("Reflow Oven Temperature (from Multimeter)")
ax.set_xlabel("Time (s)")
ax.set_ylabel("Temperature (°C)")
ax.set_ylim(Y_MIN, Y_MAX)
ax.grid(True)

lc = LineCollection([], linewidth=2, cmap=cmap, norm=norm)
ax.add_collection(lc)

info_text = ax.text(
    0.98, 0.98, "",
    transform=ax.transAxes,
    ha="right", va="top",
    bbox=dict(boxstyle="round", facecolor="white", alpha=0.85)
)

current_dot, = ax.plot([], [], marker="o", markersize=6)
current_label = ax.text(
    0, 0, "",
    ha="left", va="bottom",
    bbox=dict(boxstyle="round", facecolor="white", alpha=0.7)
)

xs = collections.deque()
ys = collections.deque()

start = time.time()
last_draw = 0.0

# ====== 主循环 ======
while True:
    v = read_meter_vdc(ser)
    if v is None:
        # 掉线/超时：尝试重连
        try:
            ser.close()
        except Exception:
            pass
        print("[WARN] Communication lost. Reconnecting...")
        time.sleep(1.0)
        ser, meter_port, meter_idn = find_meter()
        if ser is None:
            time.sleep(2.0)
        continue

    t = time.time() - start
    temp = volts_to_tempC(v, CJ_TEMP_C)

    # (可选) 把温度发给 DE10（你们原来做的）
    if SEND_TO_DE10 and ser2 is not None:
        try:
            ser2.write(f"{int(round(temp))}\r\n".encode())
        except Exception:
            pass

    xs.append(t)
    ys.append(temp)

    if len(xs) > 1:
        x_arr = np.asarray(xs, dtype=float)
        y_arr = np.asarray(ys, dtype=float)
        points = np.column_stack((x_arr, y_arr)).reshape(-1, 1, 2)
        segs = np.concatenate([points[:-1], points[1:]], axis=1)
        lc.set_segments(segs)
        lc.set_array(y_arr[:-1])

    t_min = float(min(ys))
    t_max = float(max(ys))

    info_text.set_text(
        f"Port:    {meter_port}\n"
        f"CJ:      {CJ_TEMP_C:5.1f} °C\n"
        f"VDC:     {v: .6e} V\n"
        f"Current: {temp:6.1f} °C\n"
        f"Min:     {t_min:6.1f} °C\n"
        f"Max:     {t_max:6.1f} °C"
    )

    current_dot.set_data([t], [temp])
    current_label.set_position((t, temp))
    current_label.set_text(f"{temp:.1f}°C")

    # 横轴窗口（保留你的滚动特征）
    if t < INITIAL_WINDOW:
        ax.set_xlim(0, INITIAL_WINDOW)
    elif t < FINAL_WINDOW:
        ax.set_xlim(0, t)
    else:
        ax.set_xlim(t - FINAL_WINDOW, t)

    now = time.time()
    if now - last_draw >= DRAW_RATE:
        fig.canvas.draw()
        fig.canvas.flush_events()
        last_draw = now
