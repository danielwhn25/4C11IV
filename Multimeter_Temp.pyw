import csv
import time
from datetime import datetime
import serial
import serial.tools.list_ports
from tkinter import *
from tkinter import messagebox

# ========= Settings =========
DE10_BAUD = 115200
DMM_BAUD  = 9600

# 如果 DE10 输出 208 表示 20.8°C，就用 0.1
# 如果你确认 DE10 输出就是 °C 整数，改成 1.0
DE10_SCALE = 0.1

CSV_PATH = "combined_temp_log.csv"
# ============================


def list_ports():
    """Return list of (device, description)."""
    ports = list(serial.tools.list_ports.comports())
    items = []
    for p in ports:
        # p.device like 'COM5'
        # p.description like 'USB Serial Device (COM5)'
        items.append((p.device, p.description))
    return items


def parse_de10_line(line: str):
    """
    Expect DE10 sends one value per line (often 3-digit integer like '208').
    Return (raw_int, temp_c_float) or (None, None) if invalid.
    """
    s = line.strip()
    if not s:
        return None, None

    # keep digits only (tolerate prefixes/spaces)
    digits = "".join(ch for ch in s if ch.isdigit())
    if not digits:
        return None, None

    raw = int(digits)
    temp_c = raw * DE10_SCALE
    return raw, temp_c


def parse_dmm_line(line: str):
    """
    Parse DMM line like '+0.872E-3 VDC' or '+0.872E-3'
    Return (vdc, mv) or (None, None).
    """
    s = line.strip()
    if not s:
        return None, None
    s = s.replace("VDC", "").strip()
    try:
        v = float(s)
        return v, v * 1000.0
    except:
        return None, None


class DualLoggerGUI:
    def __init__(self, root: Tk):
        self.root = root
        self.root.title("DE10 + DMM Combined Logger")
        self.root.resizable(0, 0)

        # state
        self.ser_de10 = None
        self.ser_dmm = None
        self.connected = False

        self.logging_enabled = False
        self.last_logged_sec = None

        # latest values
        self.de10_raw = None
        self.de10_temp_c = None
        self.dmm_vdc = None
        self.dmm_mv = None

        # UI variables
        self.status = StringVar(value="Click 'Refresh Ports', select ports, then click 'Connect'.")
        self.rec_status = StringVar(value="NOT RECORDING")
        self.latest_de10 = StringVar(value="----")
        self.latest_dmm = StringVar(value="----")

        self.de10_sel = StringVar(value="")
        self.dmm_sel = StringVar(value="")

        self.port_display_list = []     # list of display strings
        self.display_to_device = {}     # display string -> COMx

        # layout
        Label(root, textvariable=self.status, width=92, anchor="w").grid(row=0, column=0, columnspan=3, padx=8, pady=8)

        Label(root, text="DE10 Port:", width=10, anchor="e").grid(row=1, column=0, padx=6, sticky="e")
        self.de10_menu = OptionMenu(root, self.de10_sel, ())
        self.de10_menu.config(width=65)
        self.de10_menu.grid(row=1, column=1, columnspan=2, sticky="w", padx=6)

        Label(root, text="DMM Port:", width=10, anchor="e").grid(row=2, column=0, padx=6, sticky="e")
        self.dmm_menu = OptionMenu(root, self.dmm_sel, ())
        self.dmm_menu.config(width=65)
        self.dmm_menu.grid(row=2, column=1, columnspan=2, sticky="w", padx=6)

        Button(root, text="Refresh Ports", width=16, command=self.refresh_ports).grid(row=3, column=1, pady=6, sticky="w")
        self.btn_connect = Button(root, text="Connect", width=16, command=self.connect)
        self.btn_connect.grid(row=3, column=2, pady=6, sticky="w")

        Label(root, text="DE10 latest:", width=10, anchor="e").grid(row=4, column=0, padx=6, sticky="e")
        Label(root, textvariable=self.latest_de10, width=70, anchor="w", font=("Helvetica", 12)).grid(row=4, column=1, columnspan=2, sticky="w")

        Label(root, text="DMM latest:", width=10, anchor="e").grid(row=5, column=0, padx=6, sticky="e")
        Label(root, textvariable=self.latest_dmm, width=70, anchor="w", font=("Helvetica", 12)).grid(row=5, column=1, columnspan=2, sticky="w")

        Label(root, textvariable=self.rec_status, width=20, font=("Helvetica", 12, "bold")).grid(row=6, column=0, columnspan=3, pady=8)

        self.btn_record = Button(root, text="Start Recording", width=18, command=self.toggle_recording, state=DISABLED)
        self.btn_record.grid(row=7, column=1, pady=10, sticky="w")

        Button(root, text="Exit", width=18, command=self.exit).grid(row=7, column=2, pady=10, sticky="w")

        # initial scan
        self.refresh_ports()

    def refresh_ports(self):
        ports = list_ports()
        self.port_display_list = []
        self.display_to_device = {}

        for dev, desc in ports:
            display = f"{dev}  |  {desc}"
            self.port_display_list.append(display)
            self.display_to_device[display] = dev

        # rebuild option menus
        self._rebuild_option_menu(self.de10_menu, self.de10_sel, self.port_display_list)
        self._rebuild_option_menu(self.dmm_menu, self.dmm_sel, self.port_display_list)

        # pick defaults
        if self.port_display_list:
            if not self.de10_sel.get():
                self.de10_sel.set(self.port_display_list[0])
            if not self.dmm_sel.get():
                self.dmm_sel.set(self.port_display_list[0])

            self.status.set("Ports refreshed. Select DE10 and DMM ports, then click Connect.")
        else:
            self.de10_sel.set("")
            self.dmm_sel.set("")
            self.status.set("No serial ports detected. Plug devices in, then click Refresh Ports.")

    def _rebuild_option_menu(self, menu_widget, var, items):
        menu = menu_widget["menu"]
        menu.delete(0, "end")
        for item in items:
            menu.add_command(label=item, command=lambda v=item: var.set(v))

    def connect(self):
        if self.connected:
            self.disconnect()
            return

        if not self.port_display_list:
            messagebox.showerror("No Ports", "No serial ports detected.")
            return

        de10_display = self.de10_sel.get()
        dmm_display = self.dmm_sel.get()

        de10_port = self.display_to_device.get(de10_display)
        dmm_port = self.display_to_device.get(dmm_display)

        if not de10_port or not dmm_port:
            messagebox.showerror("Select Ports", "Please select both DE10 and DMM ports.")
            return

        if de10_port == dmm_port:
            messagebox.showerror("Port Conflict", "DE10 and DMM cannot use the same COM port.")
            return

        # close any previous
        self.disconnect()

        # open DE10
        try:
            self.ser_de10 = serial.Serial(de10_port, DE10_BAUD, timeout=0.2)
        except Exception as e:
            messagebox.showerror("DE10 Open Error", f"Failed to open {de10_port}:\n\n{e}")
            self.ser_de10 = None
            return

        # open DMM
        try:
            self.ser_dmm = serial.Serial(dmm_port, DMM_BAUD, timeout=0.5)
        except Exception as e:
            messagebox.showerror("DMM Open Error", f"Failed to open {dmm_port}:\n\n{e}")
            try:
                self.ser_de10.close()
            except:
                pass
            self.ser_de10 = None
            self.ser_dmm = None
            return

        # init DMM (optional; safe if your meter supports it)
        try:
            self.ser_dmm.write(b"\x03")
            _ = self.ser_dmm.readline()
            self.ser_dmm.write(b"VDC; RATE S; *IDN?\r\n")
            _ = self.ser_dmm.readline()
            _ = self.ser_dmm.readline()
            self.ser_dmm.write(b"MEAS1?\r\n")
        except:
            pass

        self.connected = True
        self.btn_connect.config(text="Disconnect")
        self.btn_record.config(state=NORMAL)
        self.status.set(f"Connected: DE10={de10_port}@{DE10_BAUD}, DMM={dmm_port}@{DMM_BAUD}")
        self.root.after(50, self.poll)

    def disconnect(self):
        # stop recording if active
        if self.logging_enabled:
            self.logging_enabled = False
            self.rec_status.set("NOT RECORDING")
            self.btn_record.config(text="Start Recording")

        self.connected = False
        self.btn_connect.config(text="Connect")
        self.btn_record.config(state=DISABLED)

        try:
            if self.ser_de10:
                self.ser_de10.close()
        except:
            pass
        try:
            if self.ser_dmm:
                self.ser_dmm.close()
        except:
            pass

        self.ser_de10 = None
        self.ser_dmm = None

    def init_csv(self):
        with open(CSV_PATH, "a", newline="") as f:
            if f.tell() == 0:
                csv.writer(f).writerow([
                    "timestamp_iso",
                    "de10_temp_raw",
                    "de10_temp_c",
                    "dmm_vdc",
                    "dmm_mV",
                ])

    def toggle_recording(self):
        if not self.connected:
            messagebox.showinfo("Not Connected", "Please connect to both devices first.")
            return

        self.logging_enabled = not self.logging_enabled
        if self.logging_enabled:
            try:
                self.init_csv()
            except Exception as e:
                self.logging_enabled = False
                messagebox.showerror("CSV Error", str(e))
                return
            self.last_logged_sec = None
            self.rec_status.set("RECORDING")
            self.btn_record.config(text="Stop Recording")
        else:
            self.rec_status.set("NOT RECORDING")
            self.btn_record.config(text="Start Recording")

    def poll(self):
        if not self.connected:
            return

        # --- DE10 read ---
        try:
            line = self.ser_de10.readline().decode(errors="ignore").strip()
            if line:
                raw, tc = parse_de10_line(line)
                if raw is not None:
                    self.de10_raw = raw
                    self.de10_temp_c = tc
                    self.latest_de10.set(f"raw={raw} -> {tc:.1f} °C   (line='{line}')")
        except Exception as e:
            self.status.set(f"DE10 read error: {e}")

        # --- DMM read ---
        try:
            line = self.ser_dmm.readline().decode(errors="ignore").strip()
            if line:
                vdc, mv = parse_dmm_line(line)
                if vdc is not None:
                    self.dmm_vdc = vdc
                    self.dmm_mv = mv
                    self.latest_dmm.set(f"{vdc:.6g} V  ({mv:.3f} mV)   (line='{line}')")

            # Request next reading continuously (won't hurt if meter ignores it)
            try:
                self.ser_dmm.readline()  # discard prompt if any
                self.ser_dmm.write(b"MEAS1?\r\n")
            except:
                pass
        except Exception as e:
            self.status.set(f"DMM read error: {e}")

        # --- write CSV once per second ---
        if self.logging_enabled:
            now_sec = int(time.time())
            if self.last_logged_sec != now_sec:
                self.last_logged_sec = now_sec
                try:
                    with open(CSV_PATH, "a", newline="") as f:
                        csv.writer(f).writerow([
                            datetime.now().isoformat(timespec="seconds"),
                            self.de10_raw,
                            self.de10_temp_c,
                            self.dmm_vdc,
                            self.dmm_mv,
                        ])
                except Exception as e:
                    messagebox.showwarning("CSV write error", str(e))
                    self.logging_enabled = False
                    self.rec_status.set("NOT RECORDING")
                    self.btn_record.config(text="Start Recording")

        self.root.after(50, self.poll)

    def exit(self):
        self.disconnect()
        self.root.destroy()


if __name__ == "__main__":
    root = Tk()
    app = DualLoggerGUI(root)
    root.mainloop()
