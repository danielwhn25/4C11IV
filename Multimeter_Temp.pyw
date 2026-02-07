import serial
import threading
import csv
import time
from datetime import datetime

# --- Configuration ---
DE10_PORT = 'COM4'
DMM_PORT  = 'COM6'
BAUD_DE10 = 115200
BAUD_DMM  = 9600

# Shared data storage
data_lock = threading.Lock()
current_data = {"temp": 0.0, "voltage": 0.0}

def de10_listener():
    try:
        ser = serial.Serial(DE10_PORT, BAUD_DE10, timeout=1)
        while True:
            line = ser.readline().decode('utf-8', errors='ignore').strip()
            if line:
                # Debug: print(f"Raw DE10: {line}") 
                try:
                    # Look for the temperature pattern specifically
                    import re
                    match = re.search(r"[-+]?\d*\.\d+|\d+", line)
                    if match:
                        val = float(match.group())
                        with data_lock:
                            current_data["temp"] = val
                except ValueError:
                    continue 
    except Exception as e:
        print(f"DE10 Error: {e}")

def dmm_listener():
    """Queries the Multimeter on COM6"""
    try:
        ser = serial.Serial(DMM_PORT, BAUD_DMM, timeout=1)
        while True:
            ser.write(b"MEAS1?\r\n") # Standard SCPI query
            line = ser.readline().decode('utf-8').strip()
            if line:
                try:
                    # Strips units like 'VDC'
                    val = float("".join(c for c in line if c in "0123456789.+-E"))
                    with data_lock:
                        current_data["voltage"] = val
                except ValueError:
                    pass
            time.sleep(0.5) # Prevent flooding the DMM buffer
    except Exception as e:
        print(f"DMM Error: {e}")

def logger():
    """Writes synchronized data to CSV every second"""
    filename = f"log_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"
    with open(filename, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(["Timestamp", "LM335_Temp_C", "DMM_Voltage_V"])
        print(f"Logging started: {filename}")
        
        try:
            while True:
                with data_lock:
                    temp = current_data["temp"]
                    volt = current_data["voltage"]
                
                timestamp = datetime.now().strftime("%H:%M:%S")
                writer.writerow([timestamp, temp, volt])
                f.flush() # Ensure data is written to disk
                
                print(f"[{timestamp}] Temp: {temp:>5.1f} C | DMM: {volt:>7.4f} V")
                time.sleep(1)
        except KeyboardInterrupt:
            print("\nLogging stopped.")

# Start threads
threading.Thread(target=de10_listener, daemon=True).start()
threading.Thread(target=dmm_listener, daemon=True).start()
logger()