#!/usr/bin/python
from tkinter import *
import time
import serial
import serial.tools.list_ports
import kconvert
import csv
from datetime import datetime
import os

top = Tk()
top.resizable(0, 0)
top.title("Fluke_45/Tek_DMM4020 K-type Thermocouple")

# ATTENTION: Make sure the multimeter is configured at 9600 baud, 8-bits, parity none, 1 stop bit, echo Off

CJTemp = StringVar()
Temp = StringVar()
DMMout = StringVar()
portstatus = StringVar()
DMM_Name = StringVar()

connected = 0
global ser

# ---------- Recording controls ----------
logging_enabled = False
recording_status = StringVar()
recording_status.set("NOT RECORDING")

_last_log_epoch_int = None  # integer seconds; used to ensure 1 row/sec
csv_path = None             # path to the active CSV file
_record_btn = None          # will be assigned after button creation


def safe_default_csv_path():
    """
    Use a writable folder (home directory) to avoid permission issues.
    """
    home = os.path.expanduser("~")
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    filename = f"temperature_log_{stamp}.csv"
    return os.path.join(home, filename)


def init_csv(path):
    """
    Create CSV file (append mode) and write header if empty.
    """
    with open(path, "a", newline="") as f:
        if f.tell() == 0:
            w = csv.writer(f)
            w.writerow(["timestamp_iso", "cj_temp_c", "dmm_vdc", "dmm_mV", "temp_c"])


def start_recording():
    """
    Start logging to a new CSV file in the user's home directory.
    """
    global logging_enabled, csv_path, _last_log_epoch_int
    csv_path = safe_default_csv_path()
    try:
        init_csv(csv_path)
    except Exception as e:
        # Show error in the UI and do not enable recording
        portstatus.set(f"CSV init error: {e}")
        logging_enabled = False
        recording_status.set("NOT RECORDING")
        if _record_btn is not None:
            _record_btn.config(text="Start Recording")
        return

    logging_enabled = True
    _last_log_epoch_int = None  # allow immediate first write
    recording_status.set("RECORDING")
    portstatus.set(f"Recording to: {csv_path}")
    if _record_btn is not None:
        _record_btn.config(text="Stop Recording")


def stop_recording():
    """
    Stop logging (no file close needed since we open per write).
    """
    global logging_enabled
    logging_enabled = False
    recording_status.set("NOT RECORDING")
    if _record_btn is not None:
        _record_btn.config(text="Start Recording")


def toggle_recording():
    if logging_enabled:
        stop_recording()
    else:
        start_recording()


def log_once_per_second(cj_temp_c, dmm_vdc, dmm_mV, temp_c):
    """
    Write one row per second only when recording is enabled.
    """
    global _last_log_epoch_int, csv_path

    if not logging_enabled:
        return
    if csv_path is None:
        return

    now_int = int(time.time())
    if _last_log_epoch_int == now_int:
        return  # already logged this second
    _last_log_epoch_int = now_int

    try:
        with open(csv_path, "a", newline="") as f:
            w = csv.writer(f)
            w.writerow([
                datetime.now().isoformat(timespec="seconds"),
                cj_temp_c,
                dmm_vdc,
                dmm_mV,
                temp_c
            ])
    except Exception as e:
        # If writing fails (e.g., file locked by Excel), stop recording safely
        portstatus.set(f"CSV write error: {e}")
        stop_recording()


def Just_Exit():
    top.destroy()
    try:
        ser.close()
    except:
        pass


def update_temp():
    global ser, connected
    if connected == 0:
        top.after(5000, FindPort)  # Not connected, try again in 5 seconds
        return

    try:
        strin = ser.readline()  # Read the requested value, e.g. "+0.234E-3 VDC"
        strin = strin.rstrip().decode()
        print(strin)
        ser.readline()  # Read and discard the prompt "=>"
        if len(strin) > 1 and strin[1] == '>':  # Out of sync?
            strin = ser.readline()
        ser.write(b"MEAS1?\r\n")  # Request next value
    except:
        connected = 0
        DMMout.set("----")
        Temp.set("----")
        portstatus.set("Communication Lost")
        DMM_Name.set("--------")
        top.after(5000, FindPort)
        return

    strin_clean = strin.replace("VDC", "")  # float() doesn't like units

    if len(strin_clean) > 0:
        DMMout.set(strin.replace("\r", "").replace("\n", ""))

        try:
            dmm_vdc = float(strin_clean)       # volts
            dmm_mV = dmm_vdc * 1000.0          # millivolts
            valid_val = 1
        except:
            valid_val = 0
            dmm_vdc = None
            dmm_mV = None

        try:
            cj = float(CJTemp.get())  # cold junction temp (C)
        except:
            cj = 0.0

        if valid_val == 1:
            ktemp = round(kconvert.mV_to_C(dmm_mV, cj), 1)
            if ktemp < -200:
                Temp.set("UNDER")
            elif ktemp > 1372:
                Temp.set("OVER")
            else:
                Temp.set(ktemp)
                # Log only if the user pressed Start Recording
                log_once_per_second(cj, dmm_vdc, dmm_mV, ktemp)
        else:
            Temp.set("----")
    else:
        Temp.set("----")
        connected = 0

    top.after(500, update_temp)  # ~2 measurements/sec tops


def FindPort():
    global ser, connected
    try:
        ser.close()
    except:
        pass

    connected = 0
    DMM_Name.set("--------")

    portlist = list(serial.tools.list_ports.comports())
    for item in reversed(portlist):
        portstatus.set("Trying port " + item[0])
        top.update()
        try:
            ser = serial.Serial(item[0], 9600, timeout=0.5)
            ser.write(b"\x03")  # Request prompt
            pstring = ser.readline().rstrip().decode()

            if len(pstring) > 1 and pstring[1] == '>':
                ser.timeout = 3
                portstatus.set("Connected to " + item[0])
                ser.write(b"VDC; RATE S; *IDN?\r\n")
                devicename = ser.readline().rstrip().decode()
                DMM_Name.set(devicename.replace("\r", "").replace("\n", ""))
                ser.readline()  # discard prompt
                ser.write(b"MEAS1?\r\n")
                connected = 1
                top.after(1000, update_temp)
                break
            else:
                ser.close()
        except:
            connected = 0

    if connected == 0:
        portstatus.set("Multimeter not found")
        top.after(5000, FindPort)


# ---------- UI ----------
Label(top, text="Cold Junction Temperature:").grid(row=1, column=0, columnspan=2)
Entry(top, bd=1, width=7, textvariable=CJTemp, justify="center").grid(row=2, column=0, columnspan=2)

Label(top, text="Multimeter reading:").grid(row=3, column=0, columnspan=2)
Label(top, textvariable=DMMout, width=20, font=("Helvetica", 20), fg="red").grid(row=4, column=0, columnspan=2)

Label(top, text="Thermocouple Temperature (C)").grid(row=5, column=0, columnspan=2)
Label(top, textvariable=Temp, width=5, font=("Helvetica", 100), fg="blue").grid(row=6, column=0, columnspan=2)

Label(top, textvariable=portstatus, width=40, font=("Helvetica", 12)).grid(row=7, column=0, columnspan=2)
Label(top, textvariable=DMM_Name, width=40, font=("Helvetica", 12)).grid(row=8, column=0, columnspan=2)

# Recording status line
Label(top, textvariable=recording_status, width=20, font=("Helvetica", 12, "bold")).grid(row=9, column=0, columnspan=2)

# Buttons on the SAME ROW: Record (left) and Exit (right)
_record_btn = Button(top, width=16, text="Start Recording", command=toggle_recording)
_record_btn.grid(row=10, column=0, padx=6, pady=6)

Button(top, width=16, text="Exit", command=Just_Exit).grid(row=10, column=1, padx=6, pady=6)

CJTemp.set("22")
DMMout.set("NO DATA")
DMM_Name.set("--------")

top.after(500, FindPort)
top.mainloop()
