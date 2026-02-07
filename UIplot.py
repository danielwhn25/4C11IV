import time
import collections
import matplotlib.pyplot as plt
import numpy as np

# ========= 参数 =========
INITIAL_WINDOW = 160   # 起始窗口
FINAL_WINDOW   = 700   # 最终窗口
UPDATE_RATE    = 0.1   # 刷新速度（秒）→ 更快移动
Y_MIN, Y_MAX   = 0, 300

# ========= 模拟 reflow 曲线 =========
def reflow_temp(t):
    """
    生成类似你图里的形状：
    - 0~20s: 室温平稳
    - 20~140s: S型升温到 ~160
    - 140~200s: soak 平台 ~165-170
    - 200~300s: 再次上升到 ~225-235
    - 300s: 触发快速降温
    - 300~380s: 快速下降到 ~70-90
    - 380s后: 缓慢降到 ~60-80
    """
    # 让曲线更“真实”的轻微抖动（可关掉）
    noise = 0.8 * np.sin(0.12*t) + 0.4 * np.sin(0.035*t)

    # 1) 初始室温段
    if t < 20:
        return 25 + 0.1*t + 0.2*noise

    # 2) S 型升温到 ~160（像真实炉子加热惯性）
    if t < 140:
        # logistic: 从 25 -> 165
        # 调参：中心点、陡峭度
        k = 0.055
        t0 = 80
        base = 25 + (165-25) / (1 + np.exp(-k*(t - t0)))
        return base + noise

    # 3) Soak 平台（轻微爬升）
    if t < 200:
        # 165 -> 170 缓慢上升
        base = 165 + (170-165) * (t - 140) / (200 - 140)
        return base + 0.6*noise

    # 4) 再次升温到峰值（S型上升到 ~230）
    if t < 300:
        k = 0.06
        t0 = 245
        base = 170 + (230-170) / (1 + np.exp(-k*(t - t0)))
        return base + 0.7*noise

    # 5) 快速降温段（指数衰减，先快后慢）
    if t < 380:
        # 从 230 在 80 秒内掉到 ~80 左右
        tau = 22.0  # 越小掉得越快
        base = 80 + (230-80) * np.exp(-(t-300)/tau)
        return base + 0.6*noise

    # 6) 冷却尾巴（慢慢到 ~60）
    tau2 = 140.0
    base = 60 + (80-60) * np.exp(-(t-380)/tau2)
    return base + 0.4*noise

# ========= 初始化绘图 =========
xs = collections.deque()
ys = collections.deque()

plt.ion()
fig, ax = plt.subplots()
ax.set_title("Reflow Oven Temperature")
ax.set_xlabel("Time (s)")
ax.set_ylabel("Temperature (°C)")
ax.set_ylim(Y_MIN, Y_MAX)
ax.grid(True)

line, = ax.plot([], [], linewidth=2)   # 单色曲线

TIME_SCALE = 10

start = time.time()

# ========= 主循环 =========
while True:
    #t = time.time() - start
    t = (time.time() - start) * TIME_SCALE
    temp = reflow_temp(t)

    xs.append(t)
    ys.append(temp)

    # 更新曲线
    line.set_data(xs, ys)

    # ===== 动态横轴窗口 =====
    # 前160秒：固定 0–160
    if t < INITIAL_WINDOW:
        ax.set_xlim(0, INITIAL_WINDOW)

    # 160 → 700 秒：窗口逐渐变宽
    elif t < FINAL_WINDOW:
        ax.set_xlim(0, t)

    # >700 秒：进入滚动模式
    else:
        ax.set_xlim(t - FINAL_WINDOW, t)

    fig.canvas.draw()
    fig.canvas.flush_events()
    time.sleep(UPDATE_RATE)
