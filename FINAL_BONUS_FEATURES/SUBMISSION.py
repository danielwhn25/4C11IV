import time
import collections
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from matplotlib.colors import Normalize

import serial
import serial.tools.list_ports
import kconvert

METER_PORT = "COM12"
METER_BAUD = 9600

DE10_PORT = "COM3"
DE10_BAUD = 115200

CJ_TEMP_C = 21.2

INITIAL_WINDOW = 160
FINAL_WINDOW   = 700
DRAW_RATE      = 0.05
Y_MIN, Y_MAX   = 0, 250

cmap = plt.get_cmap("coolwarm")
norm = Normalize(vmin=Y_MIN, vmax=Y_MAX)

def open_meter(port: str) -> serial.Serial:
    ser = serial.Serial(port, METER_BAUD, timeout=0.5)
    time.sleep(0.2)
    ser.write(b"\x03")
    ser.readline()
    ser.timeout = 3
    ser.write(b"VDC; RATE S; *IDN?\r\n")
    _idn = ser.readline().decode(errors="ignore").strip()
    ser.readline() 
    ser.write(b"MEAS1?\r\n")
    print(f"[OK] Multimeter opened: {port} - {_idn}")
    return ser

def read_meter_vdc(ser: serial.Serial):
    try:
        s = ser.readline().decode(errors="ignore")
        ser.readline()
        if len(s) > 1 and s[1] == ">": 
            s = ser.readline().decode(errors="ignore")
        ser.write(b"MEAS1?\r\n")
        s_clean = s.replace("VDC", "").strip()
        if not s_clean:
            return None
        return float(s_clean)
    except Exception:
        return None

def volts_to_tempC(v_volts: float, cj_c: float) -> float:
    mv = v_volts * 1000.0
    return float(kconvert.mV_to_C(mv, cj_c))

def open_de10(port: str):
    ser2 = serial.Serial(port, DE10_BAUD, timeout=0.05)
    ser2.reset_input_buffer()
    print(f"[OK] DE10 opened: {port} @ {DE10_BAUD}")
    return ser2

def read_de10_temp(ser2: serial.Serial, last_temp: float):
    if ser2 is None:
        return last_temp

    temp = last_temp
    while ser2.in_waiting > 0:
        try:
            line = ser2.readline().decode(errors="ignore").strip()
            if line:
                temp = float(line)
        except ValueError:
            pass
    return temp

print("Available serial ports:")
for p in serial.tools.list_ports.comports():
    print(f" - {p.device}  {p.description}")

ser2 = None
try:
    ser2 = open_de10(DE10_PORT)
except Exception as e:
    print(f"[WARN] Failed to open DE10: {e}")

ser = None
try:
    ser = open_meter(METER_PORT)
except Exception as e:
    print(f"[WARN] Failed to open Multimeter: {e}")

plt.ion()
fig, ax = plt.subplots(figsize=(10, 6))
ax.set_title("Reflow Oven Temperature Profile")
ax.set_xlabel("Time (s)")
ax.set_ylabel("Temperature (°C)")
ax.set_ylim(Y_MIN, Y_MAX)
ax.grid(True)

lc = LineCollection([], linewidth=3, cmap=cmap, norm=norm)
ax.add_collection(lc)

line_dmm, = ax.plot([], [], color='gray', linestyle='--', linewidth=1.5, label='DMM Benchmark')
ax.legend(loc='upper right')

info_text = ax.text(
    0.02, 0.98, "", transform=ax.transAxes,
    ha="left", va="top", bbox=dict(boxstyle="round", facecolor="white", alpha=0.85)
)

xs = collections.deque()
ys_meter = collections.deque()
ys_opamp = collections.deque()

start = time.time()
last_draw = 0.0

last_de10_temp = CJ_TEMP_C

print("\nStarting Data Acquisition.")
print("Format: DMM Temp (°C) | DE10 Op-Amp Temp (°C)")

while True:
    v_meter = read_meter_vdc(ser) if ser else None
    meter_temp = round(volts_to_tempC(v_meter, CJ_TEMP_C), 1) if v_meter is not None else ys_meter[-1] if ys_meter else CJ_TEMP_C

    last_de10_temp = read_de10_temp(ser2, last_de10_temp)
    opamp_temp = round(last_de10_temp, 1)

    t = time.time() - start

    print(f"DMM: {meter_temp:6.1f} °C  |  DE10: {opamp_temp:6.1f} °C")

    xs.append(t)
    ys_meter.append(meter_temp)
    ys_opamp.append(opamp_temp)

    if len(xs) > 1:
        x_arr = np.asarray(xs, dtype=float)
        
        y_arr_opamp = np.asarray(ys_opamp, dtype=float)
        points = np.column_stack((x_arr, y_arr_opamp)).reshape(-1, 1, 2)
        segs = np.concatenate([points[:-1], points[1:]], axis=1)
        lc.set_segments(segs)
        lc.set_array(y_arr_opamp[:-1])

        line_dmm.set_xdata(x_arr)
        line_dmm.set_ydata(ys_meter)

    y_arr_legend = np.asarray(ys_opamp, dtype=float)
    if y_arr_legend.size:
        info_text.set_text(
            f"DE10 Min:     {float(np.nanmin(y_arr_legend)):6.1f} °C\n"
            f"DE10 Max:     {float(np.nanmax(y_arr_legend)):6.1f} °C\n"
            f"DE10 Current: {float(y_arr_legend[-1]):6.1f} °C"
        )

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
