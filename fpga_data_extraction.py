import serial
import csv
from datetime import datetime

# MATCH THE ASM BAUD RATE
serial_port = 'COM5' # Change to your port
baud_rate = 115200 
csv_filename = "thermocouple_data.csv"

with open(csv_filename, mode='w', newline='') as file:
    writer = csv.writer(file)
    writer.writerow(["Timestamp", "Temperature (C)"])

try:
    ser = serial.Serial(serial_port, baud_rate, timeout=1)
    print("Logging started. Press Ctrl+C to stop.")
    while True:
        line = ser.readline().decode('utf-8').strip()
        if line:
            timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            print(f"{timestamp} -> {line}")
            with open(csv_filename, mode='a', newline='') as file:
                csv.writer(file).writerow([timestamp, line])
except KeyboardInterrupt:
    print("Logging stopped.")