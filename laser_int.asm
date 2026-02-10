;https://gemini.google.com/share/1db7be8750ce
;--------------------------------------------------------
; NUVOTON N76E003 - TSL2591 LASER TRIPWIRE
;--------------------------------------------------------

; --- N76E003 Special Function Registers ---
P1      DATA 0x90
P3      DATA 0xB0
P1M1    DATA 0xB1   ; Port 1 Mode Select 1
P1M2    DATA 0xB2   ; Port 1 Mode Select 2
IE      DATA 0xA8   ; Interrupt Enable
IP      DATA 0xB8   ; Interrupt Priority
TCON    DATA 0x88   ; Timer/Interrupt Control

; --- Pin Definitions ---
SCL     BIT P1.3    ; I2C Clock
SDA     BIT P1.4    ; I2C Data
ALARM   BIT P1.5    ; Output Pin (LED/Buzzer)
INT_PIN BIT P1.7    ; Sensor Interrupt (INT0)

; --- TSL2591 Constants ---
ADDR_WR EQU 0x52    ; Write Address
ADDR_RD EQU 0x53    ; Read Address
CMD_NRM EQU 0xA0    ; Command: Normal Transaction

;====================================================================
; RESET VECTORS
;====================================================================
ORG 0000H
    LJMP MAIN

ORG 0003H           ; INT0 Vector (Pin 1.7 triggers this)
    LJMP BEAM_BROKEN_ISR

;====================================================================
; MAIN PROGRAM
;====================================================================
ORG 0100H
MAIN:
    ; 1. PIN CONFIGURATION (Crucial for N76E003)
    ; We need P1.3 and P1.4 to be OPEN DRAIN for I2C.
    ; Mode 11 = Open Drain.
    ; P1M1 |= 0x18 (0001 1000)
    ; P1M2 |= 0x18 (0001 1000)
    ORL P1M1, #0x18
    ORL P1M2, #0x18
    
    ; P1.5 (Alarm) and P1.7 (INT) can stay default (Quasi-Bidirectional)
    ; This is fine for driving LEDs and reading Inputs.

    ; 2. SENSOR SETUP
    SETB SCL        ; I2C Idle High
    SETB SDA        ; I2C Idle High
    SETB INT_PIN    ; Set INT pin as Input
    CLR ALARM       ; Turn OFF Alarm initially

    ; 3. INTERRUPT SETUP
    SETB IT0        ; Set INT0 to Edge Triggered (Falling Edge)
    SETB EX0        ; Enable External Interrupt 0
    SETB EA         ; Enable Global Interrupts

    ; 4. INITIALIZE TSL2591
    LCALL TSL_INIT_LASER

    ; 5. MAIN LOOP
    ; We constantly turn the alarm OFF. 
    ; If the beam is broken, the ISR will constantly interrupt us 
    ; and turn the alarm ON, overpowering this loop.
LOOP:
    CLR ALARM       ; Reset Alarm State
    LCALL DELAY_SHORT ; Brief pause
    SJMP LOOP

;====================================================================
; INTERRUPT SERVICE ROUTINE (ISR)
; Fires when Sensor pulls P1.7 LOW (Darkness detected)
;====================================================================
BEAM_BROKEN_ISR:
    PUSH ACC
    PUSH PSW

    ; --- 1. ACTION: DRIVE PIN HIGH ---
    SETB ALARM      ; Turn ON the LED/Siren!

    ; --- 2. CLEAR SENSOR INTERRUPT ---
    ; We must tell the TSL2591 we saw the event, or P1.7 stays Low forever.
    LCALL I2C_START
    MOV A, #ADDR_WR
    LCALL I2C_WRITE
    MOV A, #0xE6    ; Special Function: Clear ALS Interrupt
    LCALL I2C_WRITE
    LCALL I2C_STOP

    ; --- 3. DEBOUNCE / HOLD ---
    ; Keep the alarm on for a perceptible moment
    LCALL DELAY_LONG 

    POP PSW
    POP ACC
    RETI

;====================================================================
; SENSOR INITIALIZATION (Calibrated for Laser)
;====================================================================
TSL_INIT_LASER:
    ; 1. Set Gain to LOW (1x) to prevent saturation from Laser
    LCALL I2C_START
    MOV A, #ADDR_WR
    LCALL I2C_WRITE
    MOV A, #(CMD_NRM + 0x01) ; CONTROL Register
    LCALL I2C_WRITE
    MOV A, #0x00             ; Low Gain, 100ms
    LCALL I2C_WRITE
    LCALL I2C_STOP

    ; 2. Set LOW Threshold (The Trip Point)
    ; If light drops BELOW this value, interrupt fires.
    ; Value 0x2000 (8192). Adjust this if it triggers too easily!
    LCALL I2C_START
    MOV A, #ADDR_WR
    LCALL I2C_WRITE
    MOV A, #(CMD_NRM + 0x04) ; AILTL (Low Threshold Low Byte)
    LCALL I2C_WRITE
    MOV A, #0x00
    LCALL I2C_WRITE
    LCALL I2C_STOP

    LCALL I2C_START
    MOV A, #ADDR_WR
    LCALL I2C_WRITE
    MOV A, #(CMD_NRM + 0x05) ; AILTH (Low Threshold High Byte)
    LCALL I2C_WRITE
    MOV A, #0x20             ; 0x20 = High Byte
    LCALL I2C_WRITE
    LCALL I2C_STOP

    ; 3. Enable Sensor and Interrupts
    LCALL I2C_START
    MOV A, #ADDR_WR
    LCALL I2C_WRITE
    MOV A, #(CMD_NRM + 0x00) ; ENABLE Register
    LCALL I2C_WRITE
    MOV A, #0x13             ; AIEN (Int) | AEN (ALS) | PON (Power)
    LCALL I2C_WRITE
    LCALL I2C_STOP
    RET

;====================================================================
; I2C DRIVERS (Bit-Banged)
;====================================================================
I2C_START:
    SETB SDA
    SETB SCL
    NOP
    CLR SDA
    NOP
    CLR SCL
    RET

I2C_STOP:
    CLR SDA
    SETB SCL
    NOP
    SETB SDA
    NOP
    RET

I2C_WRITE:
    ; Writes byte in Accumulator (A)
    MOV R7, #8
W_LP:
    RLC A           ; Rotate MSB into Carry
    MOV SDA, C      ; Output Carry to SDA
    SETB SCL        ; Clock High
    NOP
    CLR SCL         ; Clock Low
    DJNZ R7, W_LP
    
    ; ACK / NACK Phase (We just clock it, ignoring the slave's reply)
    SETB SDA        ; Release SDA
    SETB SCL
    NOP
    CLR SCL
    RET

;====================================================================
; DELAY ROUTINES (Approximate for 16MHz Clock)
;====================================================================
DELAY_SHORT:
    MOV R6, #200
DS_LP:
    NOP
    NOP
    DJNZ R6, DS_LP
    RET

DELAY_LONG:
    MOV R5, #50     ; Loop outer counter
DL_L1:
    MOV R6, #255    ; Loop inner counter
DL_L2:
    DJNZ R6, DL_L2
    DJNZ R5, DL_L1
    RET

END
