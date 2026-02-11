;--------------------------------------------------------
; NUVOTON N76E003 - LASER INTERRUPT (OUTPUT ON PIN 10)
; Logic: 
;   - Laser (Value > Threshold) -> Pin 5 HIGH -> LED ON
;   - Dark  (Value < Threshold) -> Pin 5 LOW  -> LED OFF
;--------------------------------------------------------

$NOLIST
$MODN76E003
$LIST

; --- PINS ---
MY_SCL  EQU P0_2    ; Pin 18
MY_SDA  EQU P1_6    ; Pin 8
MY_INT  EQU P3_0    ; Pin 5 (INT0)
ALARM   EQU P1_5    ; Pin 10 (LED) <--- CHANGED TO P1.5

; --- CONSTANTS ---
ADDR_WR EQU 052H    
CMD_NRM EQU 0A0H    

ORG 0000H
    LJMP MAIN

ORG 0100H
MAIN:
    ; 1. PIN CONFIGURATION
    
    ; --- SCL (P0.2) Open Drain ---
    ORL P0M1, #004H
    ORL P0M2, #004H

    ; --- SDA (P1.6) Open Drain ---
    ORL P1M1, #040H
    ORL P1M2, #040H

    ; --- INT (P3.0) Input Only ---
    ORL P3M1, #001H
    ANL P3M2, #0FEH

    ; --- LED (P1.5 / Pin 10) Push-Pull ---
    ; To set P1.5 to Push-Pull (Mode 01):
    ; P1M1.5 = 0
    ; P1M2.5 = 1
    ANL P1M1, #0DFH  ; Clear Bit 5 (1101 1111)
    ORL P1M2, #020H  ; Set Bit 5   (0010 0000)

    ; 2. INIT
    SETB MY_SCL     
    SETB MY_SDA     
    SETB MY_INT     
    SETB ALARM      ; Assume ON

    ; 3. START SENSOR (With LOWER Threshold)
    LCALL TSL_INIT_LOWER_THRESH

    ; 4. MAIN LOOP
LOOP:
    ; Read Pin 5 directly.
    ; High = Light. Low = Dark.
    JNB MY_INT, IS_DARK   ; If Pin 5 is LOW, go to Dark

IS_LIGHT:
    ; --- LASER DETECTED ---
    SETB ALARM      ; LED ON
    SJMP LOOP

IS_DARK:
    ; --- BEAM BROKEN ---
    CLR ALARM       ; LED OFF
    
    ; We must tell sensor to reset Pin 5, or it stays Low forever.
    LCALL CLEAR_SENSOR_INT
    
    ; Wait 100ms for sensor to re-check light
    LCALL DELAY_100MS
    
    SJMP LOOP

;====================================================================
; SUBROUTINES
;====================================================================

CLEAR_SENSOR_INT:
    LCALL I2C_START
    MOV A, #ADDR_WR
    LCALL I2C_WRITE
    MOV A, #0E6H    ; Command: Clear Interrupt
    LCALL I2C_WRITE
    LCALL I2C_STOP
    RET

TSL_INIT_LOWER_THRESH:
    ; 1. Enable Power & Interrupts
    LCALL I2C_START
    MOV A, #ADDR_WR
    LCALL I2C_WRITE
    MOV A, #(CMD_NRM + 000H) 
    LCALL I2C_WRITE
    MOV A, #013H             
    LCALL I2C_WRITE
    LCALL I2C_STOP

    ; 2. Set Gain Low
    LCALL I2C_START
    MOV A, #ADDR_WR
    LCALL I2C_WRITE
    MOV A, #(CMD_NRM + 001H) 
    LCALL I2C_WRITE
    MOV A, #000H             
    LCALL I2C_WRITE
    LCALL I2C_STOP

    ; 3. Set LOW Threshold (TRIP POINT)
    ; Threshold = 0x0200 (Decimal 512).
    LCALL I2C_START
    MOV A, #ADDR_WR
    LCALL I2C_WRITE
    MOV A, #(CMD_NRM + 004H) 
    LCALL I2C_WRITE
    MOV A, #000H             ; Low Byte
    LCALL I2C_WRITE
    LCALL I2C_STOP

    LCALL I2C_START
    MOV A, #ADDR_WR
    LCALL I2C_WRITE
    MOV A, #(CMD_NRM + 005H) 
    LCALL I2C_WRITE
    MOV A, #002H             ; High Byte (0x02)
    LCALL I2C_WRITE
    LCALL I2C_STOP
    RET

; --- I2C DRIVERS ---
I2C_START:
    SETB MY_SDA
    SETB MY_SCL
    NOP
    CLR MY_SDA
    NOP
    CLR MY_SCL
    RET

I2C_STOP:
    CLR MY_SDA
    SETB MY_SCL
    NOP
    SETB MY_SDA
    NOP
    RET

I2C_WRITE:
    MOV R7, #8
W_LP:
    RLC A
    MOV MY_SDA, C
    SETB MY_SCL
    NOP
    CLR MY_SCL
    DJNZ R7, W_LP
    SETB MY_SDA
    SETB MY_SCL
    NOP
    CLR MY_SCL
    RET

; --- DELAY ---
DELAY_100MS:
    MOV R5, #200    
D100_1:
    MOV R6, #200    
D100_2:
    DJNZ R6, D100_2
    DJNZ R5, D100_1
    RET

END
