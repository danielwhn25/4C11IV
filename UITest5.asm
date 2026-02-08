import time
import collections
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from matplotlib.colors import Normalize

# ========= 原有参数（保持你的特征）=========
INITIAL_WINDOW = 160     # 起始窗口：0-160
FINAL_WINDOW   = 700     # 最终窗口：0-700，然后滚动
UPDATE_RATE    = 0.05    # 刷新间隔（秒）
TIME_SCALE     = 10      # 速度加速倍数（10倍）

Y_MIN, Y_MAX   = 0, 300  # 温度显示范围

# ========= 颜色映射（更自然的渐变）=========
# coolwarm: 冷色->暖色，非常适合温度显示
cmap = plt.get_cmap("coolwarm")
norm = Normalize(vmin=Y_MIN, vmax=Y_MAX)

# ========= 温度模拟函数（你之前那套形状）=========
def reflow_temp(t):
    noise = 0.8*np.sin(0.12*t) + 0.4*np.sin(0.035*t)

    if t < 20:
        return 25 + 0.1*t + 0.2*noise

    if t < 140:
        k = 0.055
        t0 = 80
        return 25 + (165-25)/(1 + np.exp(-k*(t - t0))) + noise

    if t < 200:
        return 165 + (170-165)*(t - 140)/60 + 0.6*noise

    if t < 300:
        k = 0.06
        t0 = 245
        return 170 + (230-170)/(1 + np.exp(-k*(t - t0))) + 0.7*noise

    if t < 380:
        tau = 22.0
        return 80 + (230-80)*np.exp(-(t - 300)/tau) + 0.6*noise

    tau2 = 140.0
    return 60 + (80-60)*np.exp(-(t - 380)/tau2) + 0.4*noise

# ========= 初始化数据缓存 =========
xs = collections.deque()
ys = collections.deque()

# ========= 初始化绘图 =========
plt.ion()
fig, ax = plt.subplots()
ax.set_title("Reflow Oven Temperature")
ax.set_xlabel("Time (s)")
ax.set_ylabel("Temperature (°C)")
ax.set_ylim(Y_MIN, Y_MAX)
ax.grid(True)

# 用 LineCollection 画“分段着色”的折线
line_collection = LineCollection([], linewidth=2, cmap=cmap, norm=norm)
ax.add_collection(line_collection)

# 右上角信息框：Current/Min/Max
info_text = ax.text(
    0.98, 0.98, "",
    transform=ax.transAxes,
    ha="right", va="top",
    bbox=dict(boxstyle="round", facecolor="white", alpha=0.85)
)

start = time.time()

# ========= 主循环 =========
while True:
    # 10倍速度：真实 1s = 曲线 10s
    t = (time.time() - start) * TIME_SCALE
    temp = float(reflow_temp(t))

    xs.append(t)
    ys.append(temp)

    if len(xs) > 1:
        # deque 不支持切片，所以转成 numpy array 再做分段
        x_arr = np.asarray(xs, dtype=float)
        y_arr = np.asarray(ys, dtype=float)

        # 构造线段：[(x0,y0)-(x1,y1), (x1,y1)-(x2,y2), ...]
        points = np.column_stack((x_arr, y_arr)).reshape(-1, 1, 2)
        segments = np.concatenate([points[:-1], points[1:]], axis=1)

        line_collection.set_segments(segments)
        # 每段颜色按该段起点温度（y_arr[:-1]）
        line_collection.set_array(y_arr[:-1])

    # 更新 min/max/current
    t_min = min(ys)
    t_max = max(ys)
    info_text.set_text(
        f"Current: {temp:6.1f} °C\n"
        f"Min:     {t_min:6.1f} °C\n"
        f"Max:     {t_max:6.1f} °C"
    )

    # 横轴动态窗口（保持你之前特征）
    if t < INITIAL_WINDOW:
        ax.set_xlim(0, INITIAL_WINDOW)
    elif t < FINAL_WINDOW:
        ax.set_xlim(0, t)
    else:
        ax.set_xlim(t - FINAL_WINDOW, t)

    fig.canvas.draw()
    fig.canvas.flush_events()
    time.sleep(UPDATE_RATE)
