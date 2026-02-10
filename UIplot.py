import time
import collections
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from matplotlib.colors import Normalize
import serial

# ========= 参数（保留你的特征）=========
INITIAL_WINDOW = 160     # 起始窗口：0-160
FINAL_WINDOW   = 700     # 最终窗口：0-700，然后滚动
UPDATE_RATE    = 0.05    # 刷新间隔（秒）— 只影响画图刷新，不影响串口读取
Y_MIN, Y_MAX   = 0, 300  # 温度显示范围

# ========= 串口设置（只改这里）=========
PORT = "COM3"            # <<< 改成你的端口，比如 "COM5"
BAUD = 115200
SER_TIMEOUT = 1

ser = serial.Serial(PORT, BAUD, timeout=SER_TIMEOUT)
print(f"[OK] Serial opened: {PORT} @ {BAUD}")

# ========= 颜色映射（自然渐变）=========
cmap = plt.get_cmap("coolwarm")
norm = Normalize(vmin=Y_MIN, vmax=Y_MAX)

# ========= 初始化数据缓存 =========
xs = collections.deque()
ys = collections.deque()

# 如果串口没给 sec，我们用电脑时间
pc_t0 = time.time()
last_draw = 0.0

# ========= 初始化绘图 =========
plt.ion()
fig, ax = plt.subplots()
ax.set_title("Reflow Oven Temperature (Real Data)")
ax.set_xlabel("Time (s)")
ax.set_ylabel("Temperature (°C)")
ax.set_ylim(Y_MIN, Y_MAX)
ax.grid(True)

line_collection = LineCollection([], linewidth=2, cmap=cmap, norm=norm)
ax.add_collection(line_collection)

info_text = ax.text(
    0.98, 0.98, "",
    transform=ax.transAxes,
    ha="right", va="top",
    bbox=dict(boxstyle="round", facecolor="white", alpha=0.85)
)

def parse_line(s: str):
    """
    支持：
    - "sec,temp"  -> (sec, temp)
    - "temp"      -> (None, temp)
    """
    s = s.strip()
    if not s:
        return None
    parts = s.split(",")
    try:
        if len(parts) == 1:
            return (None, float(parts[0]))
        return (float(parts[0]), float(parts[1]))
    except ValueError:
        return None

# ========= 主循环 =========
while True:
    raw = ser.readline().decode(errors="ignore")
    parsed = parse_line(raw)
    if parsed is None:
        continue

    sec_val, temp = parsed

    # x轴：优先用 MCU 发来的 sec；否则用电脑时间
    if sec_val is not None:
        t = sec_val
    else:
        t = time.time() - pc_t0

    xs.append(t)
    ys.append(float(temp))

    # ====== 构造彩色线段 ======
    if len(xs) > 1:
        x_arr = np.asarray(xs, dtype=float)
        y_arr = np.asarray(ys, dtype=float)

        points = np.column_stack((x_arr, y_arr)).reshape(-1, 1, 2)
        segments = np.concatenate([points[:-1], points[1:]], axis=1)

        line_collection.set_segments(segments)
        line_collection.set_array(y_arr[:-1])  # 每段颜色按该段起点温度

    # ====== 更新 min/max/current ======
    t_min = float(min(ys))
    t_max = float(max(ys))
    info_text.set_text(
        f"Current: {float(temp):6.1f} °C\n"
        f"Min:     {t_min:6.1f} °C\n"
        f"Max:     {t_max:6.1f} °C"
    )

    # ====== 横轴动态窗口（保持你之前特征）======
    if t < INITIAL_WINDOW:
        ax.set_xlim(0, INITIAL_WINDOW)
    elif t < FINAL_WINDOW:
        ax.set_xlim(0, t)
    else:
        ax.set_xlim(t - FINAL_WINDOW, t)

    # 限制绘图刷新频率（防止太占CPU）
    now = time.time()
    if now - last_draw >= UPDATE_RATE:
        fig.canvas.draw()
        fig.canvas.flush_events()
        last_draw = now
