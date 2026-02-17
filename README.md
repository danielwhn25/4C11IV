# ELEC291 Project 1: Reflow Oven Controller
## Team: Jonathan Chik, Irene Lam, Nathan Law, Daniel Ng, Krish Vashist, Rex

How to navigate this repo: 
- The full oven controller utilizes two files:
-   one assembly file coded in A51 Assembly on the CV-8052 soft processor (on the DE10-Lite FPGA)
-   one python file to display temperature, extract temperature validation readings from a multimeter, and display voltage to temperature readings from an operational amplifier to the serial terminl

- Special features: NEC communication protocol remote control to modify reflow parameters
- I2C laser receiver module to detect oven door open/close states

<img width="1939" height="958" alt="ELEC291_PROJ1_BLOCK_DIAGRAM" src="https://github.com/user-attachments/assets/f6013a2b-5a07-4fa8-b6d5-d718caf24818" />

