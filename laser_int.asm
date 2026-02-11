;--------------------------------------------------------
; NUVOTON N76E003 - TSL2591 LIGHT DETECTOR
; Wiring: 
;   SCL   -> Pin 18 (P0.2)
;   SDA   -> Pin 8  (P1.6)
;   INT   -> Pin 5  (P3.0)
;   ALARM -> Pin 20 (P0.4)
;--------------------------------------------------------

$NOLIST
$MODN76E003
$LIST

; --- PIN RE-MAPPING ---
MY_SCL  EQU P0_2    ; Pin 18
MY_SDA  EQU P1_6    ; Pin 8
MY_INT  EQU P3_0    ; Pin 5 (INT0)
ALARM   EQU P0_4    ; Pin 20

; --- TSL2591 CONSTANTS ---
ADDR_WR EQU 052H    
ADDR_RD EQU 053H    
CMD_NRM EQU 0A0H    

;====================================================================
; RESET VECTOR
;====================================================================
ORG 0000H
    LJMP MAIN

;====================================================================
; MAIN PROGRAM
;====================================================================
ORG 0100H
MAIN:
    ; 1. PIN CONFIGURATION
    
    ; --- Configure SCL (P0.2) as Open Drain ---
    ; P0M1.2=1, P0M2.2=1
    ORL P0M1, #004H
    ORL P0M2, #004H

    ; --- Configure SDA (P1.6) as Open Drain ---
    ; P1M1.6=1, P1M2.6=1
    ORL P1M1, #040H
    ORL P1M2, #040H

    ; --- Configure ALARM (P0.4) as Push-Pull ---
    ; P0M1.4=0, P0M2.4=1
    ANL P0M1, #0EFH 
    ORL P0M2, #010H 
    
    ; --- Configure INT (P3.0) as Input Only ---
    ; P3M1.0=1, P3M2.0=0
    ORL P3M1, #001H
    ANL P3M2, #0FEH

    ; 2. INITIAL STATES
    SETB MY_SCL     ; Idle High
    SETB MY_SDA     ; Idle High
    SETB MY_INT     ; Input Mode (High-Z)
    SETB ALARM      ; Default ON (Assume light first)

    ; 3. SENSOR INIT
    LCALL TSL_INIT_LASER

    ; 4. POLLING LOOP
    ; Check Pin 5 (P3.0) directly.
    ; High = Light. Low = Dark.
LOOP:
    JNB MY_INT, IS_DARK    ; If P3.0 is Low (0), go to Dark logic

IS_LIGHT:
    SETB ALARM             ; Turn LED ON
    SJMP LOOP

IS_DARK:
    CLR ALARM              ; Turn LED OFF
    LCALL CLEAR_SENSOR_INT ; Tell sensor we saw the event
    SJMP LOOP

;====================================================================
; SUBROUTINES
;====================================================================

CLEAR_SENSOR_INT:
    LCALL I2C_START
    MOV A, #ADDR_WR
    LCALL I2C_WRITE
    MOV A, #0E6H
    LCALL I2C_WRITE
    LCALL I2C_STOP
    RET

TSL_INIT_LASER:
    ; 1. Set Gain Low
    LCALL I2C_START
    MOV A, #ADDR_WR
    LCALL I2C_WRITE
    MOV A, #(CMD_NRM + 001H) 
    LCALL I2C_WRITE
    MOV A, #000H             
    LCALL I2C_WRITE
    LCALL I2C_STOP

    ; 2. Set Threshold (Trip Point)
    ; Value 0x2000 (Adjust if needed)
    LCALL I2C_START
    MOV A, #ADDR_WR
    LCALL I2C_WRITE
    MOV A, #(CMD_NRM + 004H) 
    LCALL I2C_WRITE
    MOV A, #000H             
    LCALL I2C_WRITE
    LCALL I2C_STOP

    LCALL I2C_START
    MOV A, #ADDR_WR
    LCALL I2C_WRITE
    MOV A, #(CMD_NRM + 005H) 
    LCALL I2C_WRITE
    MOV A, #020H             
    LCALL I2C_WRITE
    LCALL I2C_STOP

    ; 3. Enable
    LCALL I2C_START
    MOV A, #ADDR_WR
    LCALL I2C_WRITE
    MOV A, #(CMD_NRM + 000H) 
    LCALL I2C_WRITE
    MOV A, #013H             
    LCALL I2C_WRITE
    LCALL I2C_STOP
    RET

;====================================================================
; I2C DRIVERS (Using MY_SCL / MY_SDA)
;====================================================================
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
    
    ; ACK
    SETB MY_SDA
    SETB MY_SCL
    NOP
    CLR MY_SCL
    RET

;====================================================================
; DELAY
;====================================================================
DELAY_SHORT:
    MOV R6, #200
DS_LP:
    NOP
    NOP
    DJNZ R6, DS_LP
    RET

END
