import time
import collections
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from matplotlib.colors import Normalize
import serial

INITIAL_WINDOW = 160
FINAL_WINDOW   = 700
UPDATE_RATE    = 0.05
Y_MIN, Y_MAX   = 0, 300

PORT = "COM3"      # 改成你的
BAUD = 115200
ser = serial.Serial(PORT, BAUD, timeout=1)
print(f"[OK] Serial opened: {PORT} @ {BAUD}")

cmap = plt.get_cmap("coolwarm")
norm = Normalize(vmin=Y_MIN, vmax=Y_MAX)

xs = collections.deque()
ys = collections.deque()

pc_t0 = time.time()
last_draw = 0.0

plt.ion()
fig, ax = plt.subplots()
ax.set_title("Reflow Oven Temperature (Real Data)")
ax.set_xlabel("Time (s)")
ax.set_ylabel("Temperature (°C)")
ax.set_ylim(Y_MIN, Y_MAX)
ax.grid(True)

line_collection = LineCollection([], linewidth=2, cmap=cmap, norm=norm)
ax.add_collection(line_collection)

# 右上角信息框：Current/Min/Max（你已经有）
info_text = ax.text(
    0.98, 0.98, "",
    transform=ax.transAxes,
    ha="right", va="top",
    bbox=dict(boxstyle="round", facecolor="white", alpha=0.85)
)

# ✅ 新增：当前点（一个小圆点）+ 当前温度标签（跟着走）
current_dot, = ax.plot([], [], marker="o", markersize=6)  # 不指定颜色，默认即可
current_label = ax.text(
    0, 0, "",
    ha="left", va="bottom",
    bbox=dict(boxstyle="round", facecolor="white", alpha=0.7)
)

def parse_line(s: str):
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

while True:
    raw = ser.readline().decode(errors="ignore")
    parsed = parse_line(raw)
    if parsed is None:
        continue

    sec_val, temp = parsed
    temp = float(temp)

    # x轴：有sec用sec，没有就用电脑时间
    if sec_val is not None:
        t = float(sec_val)
    else:
        t = time.time() - pc_t0

    xs.append(t)
    ys.append(temp)

    if len(xs) > 1:
        x_arr = np.asarray(xs, dtype=float)
        y_arr = np.asarray(ys, dtype=float)

        points = np.column_stack((x_arr, y_arr)).reshape(-1, 1, 2)
        segments = np.concatenate([points[:-1], points[1:]], axis=1)

        line_collection.set_segments(segments)
        line_collection.set_array(y_arr[:-1])

    # min/max/current
    t_min = float(min(ys))
    t_max = float(max(ys))
    info_text.set_text(
        f"Current: {temp:6.1f} °C\n"
        f"Min:     {t_min:6.1f} °C\n"
        f"Max:     {t_max:6.1f} °C"
    )

    # ✅ 更新“当前点 + 当前温度标签”
    current_dot.set_data([t], [temp])
    current_label.set_position((t, temp))
    current_label.set_text(f"{temp:.1f}°C")

    # 横轴窗口
    if t < INITIAL_WINDOW:
        ax.set_xlim(0, INITIAL_WINDOW)
    elif t < FINAL_WINDOW:
        ax.set_xlim(0, t)
    else:
        ax.set_xlim(t - FINAL_WINDOW, t)

    # 限制刷新频率
    now = time.time()
    if now - last_draw >= UPDATE_RATE:
        fig.canvas.draw()
        fig.canvas.flush_events()
        last_draw = now
