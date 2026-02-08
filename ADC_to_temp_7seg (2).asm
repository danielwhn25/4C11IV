$MODMAX10

; The Special Function Registers below were added to 'MODMAX10' recently.
; If you are getting an error, uncomment the three lines below.

; ADC_C DATA 0xa1
; ADC_L DATA 0xa2
; ADC_H DATA 0xa3

	CSEG at 0
	ljmp mycode

dseg at 30h

x:		ds	4
y:		ds	4
bcd:	ds	5

; extra 32-bit working storage
adcref:	ds	4
cj_t10:	ds	4   ; cold-junction temp in 0.1C
th_t10:	ds	4   ; hot-junction rise in 0.1C

bseg

mf:		dbit 1

FREQ   EQU 33333333
BAUD   EQU 115200
T2LOAD EQU 65536-(FREQ/(32*BAUD))

CSEG

InitSerialPort:
	; Configure serial port and baud rate
	clr TR2 ; Disable timer 2
	mov T2CON, #30H ; RCLK=1, TCLK=1 
	mov RCAP2H, #high(T2LOAD)  
	mov RCAP2L, #low(T2LOAD)
	setb TR2 ; Enable timer 2
	mov SCON, #52H
	ret

putchar:
    JNB TI, putchar
    CLR TI
    MOV SBUF, a
    RET

SendString:
    CLR A
    MOVC A, @A+DPTR
    JZ SSDone
    LCALL putchar
    INC DPTR
    SJMP SendString
SSDone:
    ret

$include(math32.inc)

cseg
; These 'equ' must match the wiring between the DE10Lite board and the LCD!
; P0 is in connector JPIO.  Check "CV-8052 Soft Processor in the DE10Lite Board: Getting
; Started Guide" for the details.
ELCD_RS equ P1.7
; ELCD_RW equ Px.x ; Not used.  Connected to ground 
ELCD_E  equ P1.1
ELCD_D4 equ P0.7
ELCD_D5 equ P0.5
ELCD_D6 equ P0.3
ELCD_D7 equ P0.1
$NOLIST
$include(LCD_4bit_DE10Lite_no_RW.inc) ; A library of LCD related functions and utility macros
$LIST

; Look-up table for 7-seg displays
myLUT:
    DB 0xC0, 0xF9, 0xA4, 0xB0, 0x99        ; 0 TO 4
    DB 0x92, 0x82, 0xF8, 0x80, 0x90        ; 4 TO 9
    DB 0x88, 0x83, 0xC6, 0xA1, 0x86, 0x8E  ; A to F

Wait50ms:
;33.33MHz, 1 clk per cycle: 0.03us
	mov R0, #30
Wait50ms_L3:
	mov R1, #74
Wait50ms_L2:
	mov R2, #250
Wait50ms_L1:
	djnz R2, Wait50ms_L1 ;3*250*0.03us=22.5us
    djnz R1, Wait50ms_L2 ;74*22.5us=1.665ms
    djnz R0, Wait50ms_L3 ;1.665ms*30=50ms
    ret

Display_Voltage_7seg:
	
	mov dptr, #myLUT

	mov a, bcd+1
	swap a
	anl a, #0FH
	movc a, @a+dptr
	anl a, #0x7f ; Turn on decimal point
	;mov HEX3, a
	
	mov a, bcd+1
	anl a, #0FH
	movc a, @a+dptr
	mov HEX2, a

	mov a, bcd+0
	swap a
	anl a, #0FH
	movc a, @a+dptr
	mov HEX1, a
	
	mov a, bcd+0
	anl a, #0FH
	movc a, @a+dptr
	mov HEX0, a
	
	ret

Display_Voltage_LCD:
	Set_Cursor(2,1)
	mov a, #'T'
	lcall ?WriteData
	mov a, #'='
	lcall ?WriteData

	; Format: ddd.d where last digit is tenths
	mov a, bcd+1
	swap a
	anl a, #0FH
	orl a, #'0'
	lcall ?WriteData

	mov a, bcd+1
	anl a, #0FH
	orl a, #'0'
	lcall ?WriteData

	mov a, bcd+0
	swap a
	anl a, #0FH
	orl a, #'0'
	lcall ?WriteData

	mov a, #'.'
	lcall ?WriteData

	mov a, bcd+0
	anl a, #0FH
	orl a, #'0'
	lcall ?WriteData
	
	ret
	
Display_Voltage_Serial:
	; Send MSD (Tens of bcd+1) -> e.g., '0'
	mov a, bcd+1
	swap a
	anl a, #0FH
	orl a, #'0'
	lcall putchar
	
	; Send (Ones of bcd+1) -> e.g., '1'
	mov a, bcd+1
	anl a, #0FH
	orl a, #'0'
	lcall putchar

	; REMOVE THE DECIMAL POINT HERE
	; (We want "142", not "1.42")

	; Send (Tens of bcd+0) -> e.g., '4'
	mov a, bcd+0
	swap a
	anl a, #0FH
	orl a, #'0'
	lcall putchar
	
	; Send LSD (Ones of bcd+0) -> e.g., '2'
	mov a, bcd+0
	anl a, #0FH
	orl a, #'0'
	lcall putchar

	; Send new line
	mov a, #'\r'
	lcall putchar
	mov a, #'\n'
	lcall putchar
	
	ret

Initial_Message:  db 'Voltmeter test', 0

mycode:
	mov SP, #7FH
	clr a
	mov LEDRA, a
	mov LEDRB, a
	
	lcall InitSerialPort
	
	; COnfigure the pins connected to the LCD as outputs
	mov P0MOD, #10101010b ; P0.1, P0.3, P0.5, P0.7 are outputs.  ('1' makes the pin output)
    mov P1MOD, #10000010b ; P1.7 and P1.1 are outputs

    lcall ELCD_4BIT ; Configure LCD in four bit mode
    ; For convenience a few handy macros are included in 'LCD_4bit_DE1Lite.inc':
	Set_Cursor(1, 1)
    Send_Constant_String(#Initial_Message)
	
	mov dptr, #Initial_Message
	lcall SendString
	mov a, #'\r'
	lcall putchar
	mov a, #'\n'
	lcall putchar
	
	mov ADC_C, #0x80 ; Reset ADC
	lcall Wait50ms

; -----------------------------
; Temperature measurement using:
;  - LM4040-41 (4.096V) measured on ADC channel CH_REF
;  - LM335 cold junction measured on ADC channel CH_LM335
;  - Thermocouple diff-amp output (gain ~300) on ADC channel CH_OPAMP
;
; Math (all integer, scaled):
;  V(node) = 4.096V * ADC(node) / ADCREF
;  CJ_tenthsC = VLM335_mV - 2730
;  TH_tenthsC = (VOP_uV * 10) / (41uV/C * GAIN)  where (41*300)=12300 uV/C
;  Toven_tenthsC = CJ_tenthsC + TH_tenthsC
;
; NOTE: Update the channel numbers below to match your wiring.
CH_OPAMP  EQU 0  ; thermocouple amplifier output
CH_LM335  EQU 1  ; LM335 node
CH_REF    EQU 2  ; LM4040-41 node

TENTHS_PER_C EQU 10
VREF_MV      EQU 4096
VREF_UV      EQU 4096000
KGAIN_UV_PER_C EQU 12300 ; 41uV/C * 300 gain

; Temp BCD format: xxxx where last digit is tenths (e.g. 0176 -> 17.6C)
;
; --- helper: read ADC channel in A, returns 12-bit in ADC_H/ADC_L ---
ReadADC:
    mov ADC_C, a
    ret

; --- helper: load x with 12-bit ADC result (ADC_H/ADC_L) ---
LoadXFromADC:
    mov x+3, #0
    mov x+2, #0
    mov x+1, ADC_H
    mov x+0, ADC_L
    ret

; --- helper: compute x = (CONST * x) / ADCREF, where ADCREF is in y ---
; expects: x holds ADC(node) ; y holds ADCREF ; CONST already loaded into x via Load_y then mul32.

; --- Serial output: print temperature in format ddd.d (from bcd) ---
PrintTempBCD_Tenths:
    ; bcd+1: [thousands][hundreds], bcd+0: [tens][ones] where 'ones' is tenths
    ; Print hundreds digit (low nibble of bcd+1)
    mov a, bcd+1
    swap a
    anl a, #0FH
    orl a, #'0'
    lcall putchar

    mov a, bcd+1
    anl a, #0FH
    orl a, #'0'
    lcall putchar

    mov a, bcd+0
    swap a
    anl a, #0FH
    orl a, #'0'
    lcall putchar

    mov a, #'.'
    lcall putchar

    mov a, bcd+0
    anl a, #0FH
    orl a, #'0'
    lcall putchar
    ret

forever:

    ; -----------------------------
    ; 1) Read ADCREF (LM4040) -> adcref
    ; -----------------------------
    mov a, #CH_REF
    mov ADC_C, a
    mov adcref+3, #0
    mov adcref+2, #0
    mov adcref+1, ADC_H
    mov adcref+0, ADC_L

    ; If adcref == 0, skip (avoid div by zero)
    mov a, adcref+0
    orl a, adcref+1
    jnz adcref_ok
    ljmp forever
adcref_ok:

    ; -----------------------------
    ; 2) Cold junction (LM335)
    ;    VLM335_mV = 4096mV * ADCLM335 / ADCREF
    ;    CJ(0.1C)  = VLM335_mV - 2730
    ; -----------------------------
    mov a, #CH_LM335
    mov ADC_C, a
    lcall LoadXFromADC                 ; x = ADCLM335

    Load_y(VREF_MV)
    lcall mul32                        ; x = ADCLM335 * 4096

    ; y = ADCREF
    mov y+0, adcref+0
    mov y+1, adcref+1
    mov y+2, adcref+2
    mov y+3, adcref+3
    lcall div32                        ; x = VLM335_mV (integer mV)

    Load_y(2730)
    lcall sub32                        ; x = CJ_t10

    mov cj_t10+0, x+0
    mov cj_t10+1, x+1
    mov cj_t10+2, x+2
    mov cj_t10+3, x+3

    ; -----------------------------
    ; 3) Hot junction rise (op-amp)
    ;    VOP_uV   = 4096000uV * ADCOP / ADCREF
    ;    TH(0.1C) = (VOP_uV * 10) / 12300
    ; -----------------------------
    mov a, #CH_OPAMP
    mov ADC_C, a
    lcall LoadXFromADC                 ; x = ADCOP

    Load_y(VREF_UV)
    lcall mul32                        ; x = ADCOP * 4096000

    ; y = ADCREF
    mov y+0, adcref+0
    mov y+1, adcref+1
    mov y+2, adcref+2
    mov y+3, adcref+3
    lcall div32                        ; x = VOP_uV

    Load_y(TENTHS_PER_C)
    lcall mul32                        ; x = VOP_uV * 10
    Load_y(KGAIN_UV_PER_C)
    lcall div32                        ; x = TH_t10

    mov th_t10+0, x+0
    mov th_t10+1, x+1
    mov th_t10+2, x+2
    mov th_t10+3, x+3

    ; -----------------------------
    ; 4) Toven(0.1C) = CJ(0.1C) + TH(0.1C)
    ; -----------------------------
    mov x+0, cj_t10+0
    mov x+1, cj_t10+1
    mov x+2, cj_t10+2
    mov x+3, cj_t10+3
    mov y+0, th_t10+0
    mov y+1, th_t10+1
    mov y+2, th_t10+2
    mov y+3, th_t10+3
    lcall add32                        ; x = toven_t10

    ; -----------------------------
    ; Display + serial
    ; -----------------------------
    lcall hex2bcd
    lcall Display_Voltage_7seg
    lcall Display_Voltage_LCD

    ; Serial: output "Toven,CJ" both in C with 0.1C resolution
    ; Print Toven (already in x)
    lcall PrintTempBCD_Tenths
    mov a, #','
    lcall putchar

    ; Print CJ
    mov x+0, cj_t10+0
    mov x+1, cj_t10+1
    mov x+2, cj_t10+2
    mov x+3, cj_t10+3
    lcall hex2bcd
    lcall PrintTempBCD_Tenths

    mov a, #'\r'
    lcall putchar
    mov a, #'\n'
    lcall putchar


	; Limit to 1 sample per second
    mov R7, #20
delay_loop:
    lcall Wait50ms
    djnz R7, delay_loop
    
    ljmp forever

	
end

