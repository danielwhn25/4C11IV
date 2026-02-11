$MODMAX10
CSEG
    ljmp main
org 0x000B
    ljmp Timer0_ISR
; =====================================================
; testall21.asm
; CV-8052 / DE10-Lite (soft processor)
;
; Combines:
;   - LCD_4bit_DE10Lite_no_RW.inc
;   - UIWorkingABD.asm (profile selection UI)
;   - SSR/MOSFET PWM on P1.3
;   - Temperature comes from the PC multimeter script over UART (115200 baud)
;
; NEW BEHAVIOR:
;   - Ramp states advance when UART temperature reaches the chosen setpoint
;     (instead of advancing after a fixed time)
;
; States:
;   0 IDLE
;   1 PREHEAT (ramp to SOAK temp)   : 100% until T >= temp_soak
;   2 SOAK (hold)                  : 60% for time_soak seconds
;   3 RAMP (ramp to REFLOW temp)   : 100% until T >= temp_reflow
;   4 REFLOW (hold)                : 60% for time_reflow seconds
;   5 COOL                         : 0% indefinitely (until user aborts)
;   6 ABORT                        : Heater OFF, requires CONFIRM to acknowledge
;
; Buttons (ACTIVE-LOW):
;   P3.7 = CYCLE   (edit profile in IDLE, abort while running)
;   P1.5 = CONFIRM (start in IDLE)
;   P3.5 = STOP    (abort anytime)
;
; RUN screen:
;   Line1: PWR:060% SOAK
;   Line2: t:012s T:145C
;
; 7-seg:
;   Displays current temp (degC) on HEX2-HEX0.
;
; =====================================================

; The Special Function Registers below were added to 'MODMAX10' recently.
; If you are getting an error, uncomment the three lines below.
;

; -------------------------
; LCD wiring (DE10-Lite) (matches your working files)
; -------------------------
ELCD_RS equ P1.7
ELCD_E  equ P1.1
ELCD_D4 equ P0.7
ELCD_D5 equ P0.5
ELCD_D6 equ P0.3
ELCD_D7 equ P0.1

; -------------------------
; Buttons (ACTIVE-LOW)
; -------------------------
CYCLE_BTN   equ P3.7
CONFIRM_BTN equ P1.5
STOP_BTN    equ P3.5

; -------------------------
; SSR / MOSFET gate output
; -------------------------
HEATER_OUT  equ P1.3
SPEAKER    equ P1.2
; -------------------------
; IR Remote input
; -------------------------
IR_IN       equ P2.4
BIT_THRESH    EQU 0Bh   ; Logic 0 vs 1 (TH0 compare)
HEADER_THRESH EQU 15h   ; Data vs Repeat code (TH0 compare)
IR_CODE_POWER EQU 45h
IR_CODE_OK    EQU 40h

; -----------------------------------------------------
; Timer1 timebase (Timer0 is left free for other features)
; 5 ms tick @ 33.333 MHz, timers tick at FREQ/12
; 200 ticks = 1 second
; reload = 0xC9C0
; -----------------------------------------------------
T1_RELOAD_H     equ 0C9h
T1_RELOAD_L     equ 0C0h
TICKS_PER_SEC   equ 200

; Non-blocking beep timing (driven from 5ms tick)
BEEP_ON_TICKS   equ 10    ; 10 * 5ms = 50ms
BEEP_OFF_TICKS  equ 10    ; 10 * 5ms = 50ms


; -----------------------------------------------------
; UART (serial)
; 115200 baud using Timer2 (same style as lab examples)
; -----------------------------------------------------
FREQ   EQU 33333333
TIMER0_RATE   EQU 4096     
TIMER0_RELOAD EQU ((65536-(FREQ/(12*TIMER0_RATE))))
BAUD   EQU 115200
T2LOAD EQU 65536-(FREQ/(32*BAUD))

; COOL is indefinite in this version (no auto-return to IDLE)

; =====================================================
; Reset Vector @ 0x0000
; =====================================================
CSEG
    ljmp main

; -----------------------------------------------------
; LCD include (after vector)
; -----------------------------------------------------
$NOLIST
$include(LCD_4bit_DE10Lite_no_RW.inc)
$LIST

; =====================================================
; RAM
; =====================================================
DSEG AT 30h

; ---- FSM variables ----
fsm_state:     ds 1   ; 0..5
seconds:       ds 1

; ---- chosen profile params (set by UI) ----
time_soak:     ds 1
temp_soak:     ds 1

time_reflow:   ds 1
temp_reflow:   ds 1

; ---- tick / pwm ----
timer_tick:    ds 1   ; 0..199
pwm_phase:     ds 1   ; 0..19
pwm_duty:      ds 1   ; 0..100

; ---- non-blocking beep helper ----
beep_ticks:    ds 1   ; 5ms ticks remaining in current beep phase
beep_reps:     ds 1   ; remaining beeps

; ---- UI / display helpers ----
last_seconds:  ds 1

; ---- debounce counters (0..3) ----
cyc_cnt:       ds 1
stop_cnt:      ds 1
conf_cnt:      ds 1

; ---- UI selection storage ----
ui_cat: ds 1
ui_opt: ds 1
ui_sel: ds 4

; ---- measured temperature (updated from UART) ----
temp_current:  ds 1
temp_tenths:   ds 1

; ---- remote setup entry ----
setup_phase:   ds 1   ; 0=soakT,1=soakTime,2=reflowT,3=reflowTime,4=ready
entry_value:   ds 1   ; numeric entry (0..255)
digit_count:   ds 1   ; how many digits typed (0..3)

; ---- startup abort check ----
temp_start:    ds 1   ; degC at GO (integer)
startup_sec:   ds 1   ; seconds since GO for 60s rise check


; ---- UART RX line buffer (ASCII temperature from PC) ----
rx_len:        ds 1
rx_buf:        ds 8

; ---- IR decoded bytes ----
ir_buf:        ds 4   ; 4 bytes decoded from NEC frame

BSEG
cyc_stable:    dbit 1
stop_stable:   dbit 1
conf_stable:   dbit 1
cyc_event:     dbit 1
stop_event:    dbit 1
conf_event:    dbit 1
conf_direct_prev: dbit 1   ; direct-edge detector for CONFIRM in setup mode
force_redraw:  dbit 1
startup_active: dbit 1
setup_active:   dbit 1
beep_active:    dbit 1
beep_phase_on:  dbit 1   ; 1=beep ON (TR0 running), 0=beep OFF

; =====================================================
; Include UI library (include-safe)
; =====================================================
$INCLUDE (UIWorkingABD2.asm)

; =====================================================
; MAIN
; =====================================================
CSEG

main:
    mov SP, #60h

    ; -------------------------
    ; Port directions
    ; P0.1,3,5,7 outputs for LCD D7..D4
    ; P1.7 RS output, P1.1 E output, P1.3 HEATER_OUT output
    ; P1.5 confirm input
    ; P3.x buttons input
    ; -------------------------
    mov P0MOD, #10101010b
    mov P1MOD, #10001110b     ; b7=1 (RS), b3=1 (HEATER), b1=1 (E)
        mov P3MOD, #00000000b     ; all P3 pins inputs (buttons). Buzzer moved to P1.2
    mov P2MOD, #00000000b     ; ensure IR pin P2.4 is input
    setb IR_IN                ; enable pull-up on IR input

    ; pull-up style inputs
    setb CONFIRM_BTN
    setb CYCLE_BTN
    setb STOP_BTN

    ; init direct CONFIRM edge detector (released)
    setb conf_direct_prev

    ; heater off
    clr HEATER_OUT
    mov pwm_duty, #0

    ; UART init (receive temperature from PC)
    lcall InitSerialPort
    ; IMPORTANT: init UART RX line buffer state (prevents stuck 0 on LCD/7-seg)
    mov rx_len, #0

    ; LCD init
    lcall ELCD_4BIT
    ; -----------------------------------------------------
    ; ADC init/reset (added: read op-amp on ADC channel 0)
    ; -----------------------------------------------------
    mov ADC_C, #080h
    lcall Wait50ms


    ; boot
    Set_Cursor(1,1)
    mov dptr, #M_STR_BOOT1
    lcall LCD_SendString
    Set_Cursor(2,1)
    mov dptr, #M_STR_BOOT2
    lcall LCD_SendString
    lcall Wait50ms
    ; ---------------------------------
    ; Remote setup (blocking, via IR OK)
    ; ---------------------------------
    setb setup_active
    mov setup_phase, #0
    mov entry_value, #0
    mov digit_count, #0
    lcall Clear_Entry_Displays
    lcall Setup_ShowPrompt

    ; init runtime state
    mov fsm_state, #0
    mov seconds, #0

    mov timer_tick, #0
    mov pwm_phase, #0
    mov pwm_duty, #0

    mov last_seconds, #0FFh

    mov cyc_cnt, #0
    mov stop_cnt, #0
    mov conf_cnt, #0

    clr cyc_stable
    clr stop_stable
    clr conf_stable

    clr cyc_event
    clr stop_event
    clr conf_event
    mov temp_current, #0
    mov temp_tenths,  #0

    mov temp_start,  #0
    mov startup_sec, #0
    clr startup_active


    setb force_redraw
    ; --- Init 3-buzzer outputs (idle HIGH) ---
    setb SPEAKER

    ; --- Beep system idle ---
    clr TR0
    clr beep_active
    clr beep_phase_on
    mov beep_ticks, #0
    mov beep_reps,  #0


    ; Timer1 setup (poll TF1). Timer0 is unused in this file.
    mov TMOD, #11h
    mov TH0, #high(TIMER0_RELOAD)
    mov TL0, #low(TIMER0_RELOAD)
    mov TH1, #T1_RELOAD_H
    mov TL1, #T1_RELOAD_L
    setb ET0
    setb EA
    setb TR1

main_loop:
    lcall IR_Task
    lcall Service_Tick
    lcall SerialRx_Task
    lcall FSM_Reflow_TempBased
    lcall Handle_UI_Events
    lcall Display_Update
    sjmp main_loop

; =====================================================
; Serial (UART) helpers
; - DE10 receives ASCII temperature lines from PC on UART RX
;   e.g. 150<CR><LF>  or  150.2<CR><LF>
; - We take the integer part (stops at '.') and clamp 0..255
; - On each complete line, updates temp_current, 7-seg, and LCD
; =====================================================

InitSerialPort:
    ; Configure serial port and baud rate (Timer2)
    clr TR2
    mov T2CON, #30H            ; RCLK=1, TCLK=1
    mov RCAP2H, #high(T2LOAD)
    mov RCAP2L, #low(T2LOAD)
    setb TR2
    mov SCON, #52H             ; mode1, REN=1, TI=1
    ret

putchar:
    jnb TI, putchar
    clr TI
    mov SBUF, a
    ret

SerialRx_Task:
SR_LOOP:
    jnb RI, SR_DONE
    mov a, SBUF
    clr RI
    lcall SerialRx_ProcessChar
    sjmp SR_LOOP
SR_DONE:
    ret

; A = received character
SerialRx_ProcessChar:
    mov r7, a

    ; end-of-line? (CR or LF)
    cjne a, #0Dh, SR_CHK_LF
    sjmp SR_EOL
SR_CHK_LF:
    cjne a, #0Ah, SR_CONT
    sjmp SR_EOL

SR_CONT:
    ; accept digits, '.' or '-' only
    mov a, r7
    clr c
    subb a, #'0'
    jc  SR_CHK_DOT
    mov a, r7
    clr c
    subb a, #('9'+1)
    jc  SR_STORECHAR

SR_CHK_DOT:
    mov a, r7
    cjne a, #'.', SR_CHK_MINUS
    sjmp SR_STORECHAR
SR_CHK_MINUS:
    mov a, r7
    cjne a, #'-', SR_IGNORE
    sjmp SR_STORECHAR

SR_IGNORE:
    ret

SR_STORECHAR:
    mov a, rx_len
    cjne a, #7, SR_SC_OK
    ret
SR_SC_OK:
    mov r6, a                 ; index
    inc rx_len

    mov a, #rx_buf
    add a, r6
    mov r1, a
    mov a, r7
    mov @r1, a
    ret

SR_EOL:
    mov a, rx_len
    jz  SR_RESET
    lcall ParseTempLine
SR_RESET:
    mov rx_len, #0
    ret

; Parses rx_buf[0..rx_len-1] into:
;   temp_current = integer part (0..255)
;   temp_tenths  = first digit after '.', else 0
ParseTempLine:
    mov r1, #rx_buf
    mov r0, rx_len

    mov r2, #0                ; integer result (0..255)
    mov r3, #0                ; neg flag
    mov r4, #0                ; seen '.' flag (0=no, 1=yes)
    mov r5, #0                ; tenths digit (0..9)

    ; leading '-'?
    mov a, @r1
    cjne a, #'-', PT_LOOP_ENTRY
    mov r3, #1
    inc r1
    dec r0

PT_LOOP_ENTRY:
    mov a, r0
    jz  PT_DONE_PARSE

PT_LOOP:
    mov a, @r1

    ; decimal point?
    cjne a, #'.', PT_CHK_DIG
    mov r4, #1
    inc r1
    djnz r0, PT_LOOP
    sjmp PT_DONE_PARSE

PT_CHK_DIG:
    ; digit?
    mov a, @r1
    clr c
    subb a, #'0'
    jc  PT_NEXT
    mov a, @r1
    clr c
    subb a, #('9'+1)
    jnc PT_NEXT

    ; digit in @r1
    mov a, r4
    jnz PT_TENTHS

    ; integer: result = result*10 + digit (saturate)
    mov a, r2
    mov b, #10
    mul ab                    ; AB = r2*10
    mov a, b
    jnz PT_SAT_INT

    mov a, r2
    mov b, #10
    mul ab
    mov r2, a                 ; r2 = low byte

    mov a, @r1
    anl a, #0Fh               ; digit 0..9
    add a, r2
    jc  PT_SAT_INT
    mov r2, a
    sjmp PT_NEXT

PT_TENTHS:
    ; first digit after '.' becomes tenths
    mov a, @r1
    anl a, #0Fh
    mov r5, a
    sjmp PT_DONE_PARSE

PT_SAT_INT:
    mov r2, #255
    mov r5, #0
    sjmp PT_DONE_PARSE

PT_NEXT:
    inc r1
    djnz r0, PT_LOOP

PT_DONE_PARSE:
    mov a, r3
    jz  PT_STORE
    mov r2, #0                ; negative => clamp to 0
    mov r5, #0

PT_STORE:
    mov temp_current, r2
    mov temp_tenths, r5
    jb  setup_active, PT_SKIP_7SEG
    lcall Update7SegTemp
PT_SKIP_7SEG:
    setb force_redraw
    ; --- Init 3-buzzer outputs (idle HIGH) ---
    setb SPEAKER


    ; echo back for debug (Python can read this)
    lcall Serial_SendTemp

    ; also send op-amp ADC0 reading for Python processing
    lcall ADC0_SendLine
    ret
; Sends temp_current as ASCII with 1 decimal digit + CRLF
Serial_SendTemp:
    mov a, temp_current
    mov b, #100
    div ab                    ; A=hundreds, B=remainder
    mov r2, a
    mov a, b
    mov b, #10
    div ab                    ; A=tens, B=ones
    mov r1, a
    mov r0, b

    mov a, r2
    jz  SST_TENS_CHECK
    add a, #'0'
    lcall putchar

SST_TENS_CHECK:
    mov a, r2
    jnz SST_SEND_TENS
    mov a, r1
    jz  SST_SEND_ONES

SST_SEND_TENS:
    mov a, r1
    add a, #'0'
    lcall putchar

SST_SEND_ONES:
    mov a, r0
    add a, #'0'
    lcall putchar

    mov a, #'.'
    lcall putchar
    mov a, temp_tenths
    add a, #'0'
    lcall putchar

    mov a, #'\r'
    lcall putchar
    mov a, #'\n'
    lcall putchar
    ret

; =====================================================
; Update7SegTemp
; Displays temp_current (degC, integer 0..255) on DE10-Lite 7-seg.
; Uses HEX2 HEX1 HEX0 as hundreds/tens/ones (HEX0 rightmost).
; Blanks leading zeros.
;
; If your digits appear inverted (active-low segments), uncomment the
; CPL A lines before writing HEXx.
; =====================================================
SEG_BLANK equ 0FFh

; =====================================================
; ADC0 -> UART (added)
; Reads ADC channel 0 (op-amp output) and prints:
;   A0=HHLL<CR><LF>   (hex)
; =====================================================

ADC0_SendLine:
    push acc
    push b
    push psw
    push 0
    push 1
    push 2
    push 3
    push 4
    push 5
    push 6
    push 7

    ; Select ADC channel 0 and allow conversion to settle
    mov ADC_C, #00h
    lcall ADC_Wait1ms

    mov r6, ADC_H
    mov r7, ADC_L

    ; "A0="
    mov a, #'A'
    lcall putchar
    mov a, #'0'
    lcall putchar
    mov a, #'='
    lcall putchar

    ; HH
    mov a, r6
    lcall SendHexByte
    ; LL
    mov a, r7
    lcall SendHexByte

    ; CRLF
    mov a, #0Dh
    lcall putchar
    mov a, #0Ah
    lcall putchar

    pop 7
    pop 6
    pop 5
    pop 4
    pop 3
    pop 2
    pop 1
    pop 0
    pop psw
    pop b
    pop acc
    ret

; ~1 ms delay using LCD's 40 us delay
ADC_Wait1ms:
    mov r5, #25
AW1_LOOP:
    lcall Wait40uSec
    djnz r5, AW1_LOOP
    ret

; A = byte, prints two hex characters
SendHexByte:
    mov b, a
    swap a
    anl a, #0Fh
    lcall NibbleToAscii
    lcall putchar

    mov a, b
    anl a, #0Fh
    lcall NibbleToAscii
    lcall putchar
    ret

; A = 0..15, returns ASCII '0'..'9','A'..'F'
NibbleToAscii:
    anl a, #0Fh
    clr c
    subb a, #10
    jc  NTA_DIGIT
    add a, #('A'-10)
    ret
NTA_DIGIT:
    add a, #10
    add a, #'0'
    ret


Update7SegTemp:
    ; split temp_current into hundreds/tens/ones
    mov a, temp_current
    mov b, #100
    div ab              ; A=hundreds, B=remainder
    mov r2, a
    mov a, b
    mov b, #10
    div ab              ; A=tens, B=ones
    mov r1, a
    mov r0, b

    ; HEX2 (hundreds) - blank if 0
    mov a, r2
    jz  U7_HUND_BLANK
    mov dptr, #SegTable
    movc a, @a+dptr
    ; cpl a
    mov HEX2, a
    sjmp U7_TENS

U7_HUND_BLANK:
    mov HEX2, #SEG_BLANK

U7_TENS:
    ; HEX1 (tens) - blank if hundreds=0 and tens=0
    mov a, r2
    jnz U7_TENS_SHOW
    mov a, r1
    jz  U7_TENS_BLANK
U7_TENS_SHOW:
    mov a, r1
    mov dptr, #SegTable
    movc a, @a+dptr
    ; cpl a
    mov HEX1, a
    sjmp U7_ONES

U7_TENS_BLANK:
    mov HEX1, #SEG_BLANK

U7_ONES:
    ; HEX0 (ones) always shown
    mov a, r0
    mov dptr, #SegTable
    movc a, @a+dptr
    ; cpl a
    mov HEX0, a

    ; blank unused digits
    mov HEX3, #SEG_BLANK
    mov HEX4, #SEG_BLANK
    mov HEX5, #SEG_BLANK
    ret

; =====================================================
; Handle_UI_Events
;   - STOP or CYCLE while running => abort immediately
;   - In IDLE:
;       CONFIRM starts
;       CYCLE re-enters profile UI
; =====================================================

; =====================================================
; IR Remote + Remote Setup UI
; =====================================================

; Clears HEX displays and entry_value (does not touch stored params)
Clear_Entry_Displays:
    mov entry_value, #0
    mov digit_count, #0

    ; Show 000 on HEX2-HEX0
    mov dptr, #SegTable
    mov a, #0
    movc a, @a+dptr
    mov HEX0, a
    mov HEX1, a
    mov HEX2, a

    mov HEX3, #0FFh
    mov HEX4, #0FFh
    mov HEX5, #0FFh
    ret

; Show entry_value on HEX2-HEX0
Update7SegEntry:
    ; Always display 3 digits with leading zeros (000..999)
    mov a, entry_value
    mov b, #100
    div ab              ; A=hundreds, B=remainder
    mov r2, a
    mov a, b
    mov b, #10
    div ab              ; A=tens, B=ones
    mov r1, a
    mov r0, b

    mov dptr, #SegTable

    mov a, r2
    movc a, @a+dptr
    mov HEX2, a

    mov a, r1
    movc a, @a+dptr
    mov HEX1, a

    mov a, r0
    movc a, @a+dptr
    mov HEX0, a

    mov HEX3, #0FFh
    mov HEX4, #0FFh
    mov HEX5, #0FFh
    ret

; Prints the prompt for the current setup_phase
Setup_ShowPrompt:
    ; Clear LCD
    mov a, #01h
    lcall ?WriteCommand
    lcall Wait50ms

    mov a, setup_phase
    cjne a, #0, SSP_1
    Set_Cursor(1,1)
    mov dptr, #M_STR_SET_SOAKT_1
    lcall LCD_SendString
    Set_Cursor(2,1)
    mov dptr, #M_STR_SET_SOAKT_2
    lcall LCD_SendString
    ljmp SSP_DONE

SSP_1:
    cjne a, #1, SSP_2
    Set_Cursor(1,1)
    mov dptr, #M_STR_SET_SOAKS_1
    lcall LCD_SendString
    Set_Cursor(2,1)
    mov dptr, #M_STR_SET_SOAKS_2
    lcall LCD_SendString
    ljmp SSP_DONE

SSP_2:
    cjne a, #2, SSP_3
    Set_Cursor(1,1)
    mov dptr, #M_STR_SET_REFT_1
    lcall LCD_SendString
    Set_Cursor(2,1)
    mov dptr, #M_STR_SET_REFT_2
    lcall LCD_SendString
    ljmp SSP_DONE

SSP_3:
    cjne a, #3, SSP_4
    Set_Cursor(1,1)
    mov dptr, #M_STR_SET_REFS_1
    lcall LCD_SendString
    Set_Cursor(2,1)
    mov dptr, #M_STR_SET_REFS_2
    lcall LCD_SendString
    ljmp SSP_DONE

SSP_4:
    ; summary screen: show all four selections, OK to start
    Set_Cursor(1,1)
    mov a, #'S'
    lcall ?WriteData
    mov a, temp_soak
    lcall LCD_Print3Dec
    mov a, #'C'
    lcall ?WriteData
    mov a, #' '
    lcall ?WriteData
    mov a, #'t'
    lcall ?WriteData
    mov a, time_soak
    lcall LCD_Print3Dec
    mov a, #'s'
    lcall ?WriteData
    mov a, #' '
    lcall ?WriteData
    mov a, #' '
    lcall ?WriteData
    mov a, #' '
    lcall ?WriteData

    Set_Cursor(2,1)
    mov a, #'R'
    lcall ?WriteData
    mov a, temp_reflow
    lcall LCD_Print3Dec
    mov a, #'C'
    lcall ?WriteData
    mov a, #' '
    lcall ?WriteData
    mov a, #'t'
    lcall ?WriteData
    mov a, time_reflow
    lcall LCD_Print3Dec
    mov a, #'s'
    lcall ?WriteData
    mov a, #' '
    lcall ?WriteData
    mov a, #'O'
    lcall ?WriteData
    mov a, #'K'
    lcall ?WriteData
    mov a, #' '
    lcall ?WriteData
    mov a, #' '
    lcall ?WriteData

SSP_DONE:
    lcall Update7SegEntry
    ret

; =====================================================
; Helper: print 3-digit decimal (000..255) to LCD
; Input: A = value
; Uses: A,B,R0,R1,R2
; =====================================================
LCD_Print3Dec:
    mov b, #100
    div ab              ; A=hundreds, B=remainder
    mov r2, a
    mov a, b
    mov b, #10
    div ab              ; A=tens, B=ones
    mov r1, a
    mov r0, b

    mov a, r2
    add a, #'0'
    lcall ?WriteData
    mov a, r1
    add a, #'0'
    lcall ?WriteData
    mov a, r0
    add a, #'0'
    lcall ?WriteData
    ret

; =====================================================
; Helper: wait about 5 seconds (blocking)
; =====================================================
Wait5s:
    mov r6, #100         ; 100 * 50ms = 5s
W5_LOOP:
    push 06h             ; save R6 in case Wait50ms uses it
    lcall Wait50ms
    pop 06h
    djnz r6, W5_LOOP
    ret

; =====================================================
; Helper: wait about 1 second (blocking)
; =====================================================
Wait1s:
    mov r6, #20          ; 20 * 50ms = 1s
W1_LOOP:
    push 06h
    lcall Wait50ms
    pop 06h
    djnz r6, W1_LOOP
    ret



; =====================================================
; LCD prompt strings (0-terminated)
; Keep each line <= 16 chars for HD44780
; =====================================================
M_STR_SET_SOAKT_1: db 'Set Soak Temp',0
M_STR_SET_SOAKT_2: db '130-170C  OK',0

M_STR_SET_SOAKS_1: db 'Set Soak Time',0
M_STR_SET_SOAKS_2: db '60-120s   OK',0

M_STR_SET_REFT_1:  db 'Set ReflowTmp',0
M_STR_SET_REFT_2:  db '200-240C  OK',0

M_STR_SET_REFS_1:  db 'Set ReflowTime',0
M_STR_SET_REFS_2:  db '45-75s    OK',0

M_STR_READY_1:     db 'Press OK to',0
M_STR_READY_2:     db 'START  Power=RST',0

M_STR_RANGE_ERR:   db 'Out of range!',0
M_STR_RANGE_CLR:   db 'Cleared to 000',0

; Adds a digit (0..9) to entry_value (saturates at 255)
; Input: A = digit
Setup_HandleDigit:
    ; Input: A = digit (0..9)
    ; Only accept digits during setup, and only up to 3 digits total.
    ; (BUGFIX: preserve the digit; do NOT clobber A during the digit_count check)
    mov r7, a              ; r7 = new digit
    jb  setup_active, SHD_IN_SETUP
    ret
SHD_IN_SETUP:
    ; If we're on the summary screen (phase >= 4), ignore digit keys
    mov a, setup_phase
    clr c
    subb a, #4
    jnc SHD_IGNORE

    ; If already have 3 digits, ignore further digits
    mov a, digit_count
    clr c
    subb a, #3
    jnc SHD_IGNORE

    ; entry_value = entry_value*10 + digit  (saturate at 255)
    mov a, entry_value
    mov b, #10
    mul ab                ; A=low, B=high
    mov r6, a
    mov a, b
    jnz SHD_SAT

    mov a, r6
    add a, r7
    jc  SHD_SAT
    mov entry_value, a

    ; digit_count++
    inc digit_count

    lcall Update7SegEntry
    ret

SHD_IGNORE:
    ret

SHD_SAT:
    mov entry_value, #255
    mov digit_count, #3
    lcall Update7SegEntry
    ret

; Handles OK/CONFIRM from the remote
Setup_HandleOK:
    jb  setup_active, SHOK_IN_SETUP
    ret
SHOK_IN_SETUP:
    mov a, setup_phase
    cjne a, #0, SHOK_1

    ; SOAK TEMP: 130..170C
    mov a, entry_value
    clr c
    subb a, #082h
    jnc SHOK_ST_MIN_OK
    ljmp SHOK_INVALID
SHOK_ST_MIN_OK:
    mov a, entry_value
    clr c
    subb a, #0ABh
    jc SHOK_ST_MAX_OK
    ljmp SHOK_INVALID
SHOK_ST_MAX_OK:
    mov temp_soak, entry_value
    inc setup_phase
    lcall Clear_Entry_Displays
    lcall Setup_ShowPrompt
    ret

SHOK_1:
    cjne a, #1, SHOK_2
    ; SOAK TIME: 60..120s
    mov a, entry_value
    clr c
    subb a, #03Ch
    jnc SHOK_SS_MIN_OK
    ljmp SHOK_INVALID
SHOK_SS_MIN_OK:
    mov a, entry_value
    clr c
    subb a, #079h
    jc SHOK_SS_MAX_OK
    ljmp SHOK_INVALID
SHOK_SS_MAX_OK:
    mov time_soak, entry_value
    inc setup_phase
    lcall Clear_Entry_Displays
    lcall Setup_ShowPrompt
    ret

SHOK_2:
    cjne a, #2, SHOK_3
    ; REFLOW TEMP: 200..240C
    mov a, entry_value
    clr c
    subb a, #0C8h
    jnc SHOK_RT_MIN_OK
    ljmp SHOK_INVALID
SHOK_RT_MIN_OK:
    mov a, entry_value
    clr c
    subb a, #0F1h
    jc SHOK_RT_MAX_OK
    ljmp SHOK_INVALID
SHOK_RT_MAX_OK:
    mov temp_reflow, entry_value
    inc setup_phase
    lcall Clear_Entry_Displays
    lcall Setup_ShowPrompt
    ret

SHOK_3:
    cjne a, #3, SHOK_4
    ; REFLOW TIME: 45..75s
    mov a, entry_value
    clr c
    subb a, #02Dh
    jnc SHOK_RS_MIN_OK
    ljmp SHOK_INVALID
SHOK_RS_MIN_OK:
    mov a, entry_value
    clr c
    subb a, #04Ch
    jc SHOK_RS_MAX_OK
    ljmp SHOK_INVALID
SHOK_RS_MAX_OK:
    mov time_reflow, entry_value
    inc setup_phase
    lcall Clear_Entry_Displays
    lcall Setup_ShowPrompt
    ret

SHOK_4:
    ; phase 4 -> start process
    clr setup_active
    mov setup_phase, #0
    mov entry_value, #0
    ; start PREHEAT
    mov fsm_state, #1
    mov seconds,   #0
    mov timer_tick,#0
    mov pwm_duty,  #100
    mov temp_start, temp_current
    mov startup_sec, #0
    setb startup_active
    setb force_redraw
    mov R3, #1
    lcall Beep_N_Times
    ret

SHOK_INVALID:
    ; Show error for ~1 second, then clear entry to 000 and re-prompt
    mov a, #01h
    lcall ?WriteCommand
    lcall Wait50ms

    Set_Cursor(1,1)
    mov dptr, #M_STR_RANGE_ERR
    lcall LCD_SendString
    Set_Cursor(2,1)
    mov dptr, #M_STR_RANGE_CLR
    lcall LCD_SendString

    lcall Wait1s
    lcall Clear_Entry_Displays
    lcall Setup_ShowPrompt
    ret

; Power button: stop everything and return to setup start
Reset_To_Setup:
    mov pwm_duty, #0
    clr HEATER_OUT
    mov fsm_state, #0
    mov seconds, #0
    mov timer_tick, #0
    mov startup_sec, #0
    clr startup_active

    setb setup_active
    mov setup_phase, #0
    mov entry_value, #0
    mov digit_count, #0
    lcall Clear_Entry_Displays
    lcall Setup_ShowPrompt
    setb force_redraw
    ret

; =====================================================
; IR decoding task (NEC style) using Timer0 in polling mode
; Non-blocking when idle; blocks ~ few ms when a frame starts.
; =====================================================
IR_Task:
    ; =====================================================
    ; NEC-style IR decode (polling Timer0)
    ; - Non-blocking when idle
    ; - Uses ET0=0 while measuring (prevents Timer0 ISR from corrupting TH0)
    ; - Includes generous timeouts so a stuck line won't freeze the UI
    ; =====================================================

    ; If we're currently beeping, ignore IR (Timer0 is used for tone generation)
    jb  beep_active, IR_EARLY_RET

    ; If line is idle (HIGH), nothing to do
    jb  IR_IN, IR_EARLY_RET

    sjmp IR_DECODE_START

IR_EARLY_RET:
    ret


IR_DECODE_START:
    ; --- From here on, we're decoding a frame ---
    clr ET0                 ; disable Timer0 interrupt while measuring

    ; -------------------------------------------------
    ; STEP 1: Wait for header MARK to end (line goes HIGH)
    ; -------------------------------------------------
    clr TR0
    clr TF0
    mov TH0, #0
    mov TL0, #0
    setb TR0
IRX_HDR_MARK_WAIT:
    jb  IR_IN, IRX_HDR_MARK_END
    mov a, TH0
    cjne a, #0FFh, IRX_HDR_MARK_WAIT
    ljmp IR_RESTORE         ; timeout
IRX_HDR_MARK_END:
    clr TR0

    ; -------------------------------------------------
    ; STEP 2: Measure header SPACE (line stays HIGH), detect repeat code
    ; -------------------------------------------------
    clr TR0
    clr TF0
    mov TH0, #0
    mov TL0, #0
    setb TR0
IRX_HDR_SPACE_WAIT:
    jnb IR_IN, IRX_HDR_SPACE_END
    mov a, TH0
    cjne a, #0FFh, IRX_HDR_SPACE_WAIT
    ljmp IR_RESTORE         ; timeout
IRX_HDR_SPACE_END:
    clr TR0

    ; Skip Repeat Codes (SPACE < HEADER_THRESH)
    mov a, TH0
    clr c
    subb a, #HEADER_THRESH
    jnc IRX_HDR_SPACE_OK
    ljmp IR_RESTORE
IRX_HDR_SPACE_OK:

    ; -------------------------------------------------
    ; STEP 3: Clear buffer, decode 32 bits into ir_buf[0..3]
    ; -------------------------------------------------
    mov r0, #4
    mov r1, #ir_buf
    clr a
IRX_CLR_BUF:
    mov @r1, a
    inc r1
    djnz r0, IRX_CLR_BUF

    mov r0, #4
    mov r1, #ir_buf
IRX_ReadByte:
    mov r2, #8
IRX_ReadBit:
    ; Wait for MARK to end (line goes HIGH)
    clr TR0
    clr TF0
    mov TH0, #0
    mov TL0, #0
    setb TR0
IRX_WAIT_RISE:
    jb  IR_IN, IRX_RISE_OK
    mov a, TH0
    cjne a, #0FFh, IRX_WAIT_RISE
    ljmp IR_RESTORE
IRX_RISE_OK:
    clr TR0

    ; Measure SPACE width (line stays HIGH) -> determines 0/1
    clr TR0
    clr TF0
    mov TH0, #0
    mov TL0, #0
    setb TR0
IRX_WAIT_FALL:
    jnb IR_IN, IRX_FALL_OK
    mov a, TH0
    cjne a, #0FFh, IRX_WAIT_FALL
    ljmp IR_RESTORE
IRX_FALL_OK:
    clr TR0

    mov a, TH0
    clr c
    subb a, #BIT_THRESH
    cpl c                  ; CY=1 for logic '1', CY=0 for logic '0'

    mov a, @r1
    rrc a
    mov @r1, a

    djnz r2, IRX_ReadBit
    inc r1
    djnz r0, IRX_ReadByte

    ; -------------------------------------------------
    ; STEP 4: Validate checksum
    ; -------------------------------------------------
    mov a, ir_buf+2
    cpl a
    xrl a, ir_buf+3
    jz  IRX_CHK_OK
    ljmp IR_RESTORE
IRX_CHK_OK:

    ; -------------------------------------------------
    ; STEP 5: Dispatch command code (ir_buf+2)
    ; -------------------------------------------------
    mov a, ir_buf+2
    lcall IR_Dispatch
    lcall Wait50ms         ; debounce / repeat suppression

IR_RESTORE:
    setb ET0

IR_DONE:
    ret

; Dispatch one decoded command code in A
IR_Dispatch:
    ; Power: always resets to setup
    cjne a, #IR_CODE_POWER, IRD_NOTPWR
    lcall Reset_To_Setup
    ret

IRD_NOTPWR:
    ; OK: setup advance / ABORT acknowledge
    cjne a, #IR_CODE_OK, IRD_NOTOK

    ; If we are in ABORT (state 6), OK acknowledges and returns to setup
    mov a, fsm_state
    cjne a, #6, IRD_OK_NOT_ABORT
    lcall Reset_To_Setup
    ret
IRD_OK_NOT_ABORT:
    ; Running (not setup): ignore OK
    jb  setup_active, IRD_OK_SETUP
    ret
IRD_OK_SETUP:
    lcall Setup_HandleOK
    ret

IRD_NOTOK:
    ; digit?
    lcall IR_GetDigit      ; returns digit in A, CY=0 if valid
    jnc IRD_DIGIT

    ; Not a digit and not OK/POWER: ignore.
    ; (Important: prevents accidental OK events while typing digits)
    ret

IRD_DIGIT:
    ; only accept digits during setup
    jb  setup_active, IRD_DIG_OK
    ret

IRD_DIG_OK:
    lcall Setup_HandleDigit
    ret

; Input: A = command code
; Output: CY=0 and A=digit (0..9) if valid; CY=1 if not a digit
IR_GetDigit:
    setb c
    cjne a, #16h, IGD_1
    clr c
    mov a, #0
    ret
IGD_1:
    cjne a, #0Ch, IGD_2
    clr c
    mov a, #1
    ret
IGD_2:
    cjne a, #18h, IGD_3
    clr c
    mov a, #2
    ret
IGD_3:
    cjne a, #5Eh, IGD_4
    clr c
    mov a, #3
    ret
IGD_4:
    cjne a, #08h, IGD_5
    clr c
    mov a, #4
    ret
IGD_5:
    cjne a, #1Ch, IGD_6
    clr c
    mov a, #5
    ret
IGD_6:
    cjne a, #5Ah, IGD_7
    clr c
    mov a, #6
    ret
IGD_7:
    cjne a, #42h, IGD_8
    clr c
    mov a, #7
    ret
IGD_8:
    cjne a, #52h, IGD_9
    clr c
    mov a, #8
    ret
IGD_9:
    cjne a, #4Ah, IGD_NO
    clr c
    mov a, #9
    ret
IGD_NO:
    setb c
    ret


Handle_UI_Events:
    ret

; =====================================================
; Display_Update
; =====================================================
Display_Update:
    jb  setup_active, DU_SETUP
    jb  force_redraw, M_DU_DRAW

    mov a, seconds
    cjne a, last_seconds, M_DU_DRAW
    ret

DU_SETUP:
    ; In remote-setup mode, LCD is controlled by Setup_ShowPrompt
    ; and 7-seg shows entry_value. Skip normal status screens.
    ret

M_DU_DRAW:
    clr force_redraw

    mov a, seconds
    mov last_seconds, a

    mov a, fsm_state
    jz  M_DU_IDLE

    cjne a, #6, DU_RUN
    lcall M_DisplayAbortStatus
    ret
DU_RUN:
    lcall M_DisplayRunStatus
    ret

M_DU_IDLE:
    lcall M_DisplayIdleStatus
    ret

; -------------------------
; IDLE screen
; Line1: S060s R045s
; Line2: CONF=GO CYC=EDIT
; -------------------------
M_DisplayIdleStatus:
    Set_Cursor(1,1)

    mov dptr, #M_STR_IDLE_P1
    lcall LCD_SendString

    mov a, time_soak
    lcall SendToLCD

    mov dptr, #M_STR_IDLE_MID
    lcall LCD_SendString

    mov a, time_reflow
    lcall SendToLCD

    mov dptr, #M_STR_IDLE_END
    lcall LCD_SendString

    Set_Cursor(2,1)
    mov dptr, #M_STR_IDLE_P2
    lcall LCD_SendString
    ret

; -------------------------
; ABORT screen (remote-only)
; Line1: ABORT T:145C
; Line2: OK=ACK  PWR=RST
; -------------------------
M_DisplayAbortStatus:
    Set_Cursor(1,1)
    mov dptr, #M_STR_ABORT_L1
    lcall LCD_SendString
    mov a, temp_current
    lcall SendToLCD
    mov a, #'C'
    lcall ?WriteData
    mov dptr, #M_STR_ABORT_L1_END
    lcall LCD_SendString

    Set_Cursor(2,1)
    mov dptr, #M_STR_ABORT_L2
    lcall LCD_SendString
    ret

; -------------------------
; RUN screen
; Line1: PWR:060% SOAK
; Line2: t:012s T:145C
; -------------------------
M_DisplayRunStatus:
    ; ----- line 1 -----
    Set_Cursor(1,1)

    mov dptr, #M_STR_RUN_L1
    lcall LCD_SendString

    mov a, pwm_duty
    lcall SendToLCD

    mov a, #'%'
    lcall ?WriteData

    mov a, #' '
    lcall ?WriteData

    ; state string (7 chars)
    mov a, fsm_state
    cjne a, #1, M_RS_ST2
    mov dptr, #M_ST_PREHEAT
    ljmp M_RS_PRINTST
M_RS_ST2:
    cjne a, #2, M_RS_ST3
    mov dptr, #M_ST_SOAK
    ljmp M_RS_PRINTST
M_RS_ST3:
    cjne a, #3, M_RS_ST4
    mov dptr, #M_ST_RAMP
    ljmp M_RS_PRINTST
M_RS_ST4:
    cjne a, #4, M_RS_ST5
    mov dptr, #M_ST_REFLOW
    ljmp M_RS_PRINTST

M_RS_ST5:
    cjne a, #5, M_RS_ST6
    mov dptr, #M_ST_COOL
    ljmp M_RS_PRINTST

M_RS_ST6:
    cjne a, #6, M_RS_STX
    mov dptr, #M_ST_ABORT
    ljmp M_RS_PRINTST

M_RS_STX:
    mov dptr, #M_ST_COOL

M_RS_PRINTST:
    lcall LCD_SendString

    ; ----- line 2 -----
    Set_Cursor(2,1)

    mov a, fsm_state
    cjne a, #6, M_RS_L2_NORMAL

    ; ABORT: require CONFIRM acknowledgement
    mov dptr, #M_STR_ABORT_L2
    lcall LCD_SendString

    mov a, temp_current
    lcall SendToLCD

    mov a, #'C'
    lcall ?WriteData

    mov dptr, #M_STR_RUN_L2_END
    lcall LCD_SendString
    ret

M_RS_L2_NORMAL:
    mov dptr, #M_STR_RUN_L2
    lcall LCD_SendString

    mov a, seconds
    lcall SendToLCD

    mov a, #'s'
    lcall ?WriteData

    mov dptr, #M_STR_TLAB
    lcall LCD_SendString

    mov a, temp_current
    lcall SendToLCD

    mov a, #'C'
    lcall ?WriteData

    mov dptr, #M_STR_RUN_L2_END
    lcall LCD_SendString

    ret

; =====================================================
; Service_Tick
; Called often; only runs when TF1 set.
; - debounces buttons (non-blocking)
; - updates PWM output (tick-based)
; - updates seconds
; =====================================================
Service_Tick:
    jnb TF1, M_ST_DONE
    clr TF1
    mov TH1, #T1_RELOAD_H
    mov TL1, #T1_RELOAD_L
    lcall PWM_Tick
    lcall Seconds_Tick
    lcall Beep_Task

M_ST_DONE:
    ret

; =====================================================
; Seconds_Tick
; TICKS_PER_SEC timer ticks = 1 second
; =====================================================
Seconds_Tick:
    inc timer_tick
    mov a, timer_tick
    cjne a, #TICKS_PER_SEC, M_SEC_DONE

    mov timer_tick, #0

    ; 60-second startup rise check (ONLY during PREHEAT state 1, only once total per run)
    jb  startup_active, M_SEC_STARTUP_GUARD
    ljmp M_SEC_MAINSEC

M_SEC_STARTUP_GUARD:
    mov a, fsm_state
    cjne a, #1, M_SEC_STARTUP_CANCEL
    ljmp M_SEC_STARTUP

M_SEC_STARTUP_CANCEL:
    ; left PREHEAT before 60s => check no longer applies
    clr startup_active
    ljmp M_SEC_MAINSEC

M_SEC_STARTUP:
    inc startup_sec
    mov a, startup_sec
    cjne a, #60, M_SEC_MAINSEC
    lcall StartupAbort_Check60

M_SEC_MAINSEC:
    ; don't advance seconds while waiting for ABORT acknowledgement
    mov a, fsm_state
    cjne a, #6, M_SEC_INC
    ljmp M_SEC_REDRAW

M_SEC_INC:
    inc seconds

M_SEC_REDRAW:
    setb force_redraw
    ; --- Init 3-buzzer outputs (idle HIGH) ---
    setb SPEAKER

M_SEC_DONE:
    ret

; -----------------------------------------------------
; StartupAbort_Check60
; After 60 seconds spent in PREHEAT (state 1), abort if temp is still below 50C.
; ABORT state requires CONFIRM to acknowledge.
; -----------------------------------------------------
StartupAbort_Check60:
    clr startup_active

    ; Requirement: abort if the oven has NOT reached at least 50C
    ; within the first 60 seconds of operation (PREHEAT only).
    mov a, temp_current
    clr c
    subb a, #50
    jc  SAB_ABORT

    ret

SAB_ABORT:
    mov pwm_duty, #0
    clr HEATER_OUT
    mov fsm_state, #6
    mov seconds, #0
    mov timer_tick, #0
    mov startup_sec, #0
    setb force_redraw
    ; --- Init 3-buzzer outputs (idle HIGH) ---
    setb SPEAKER

    mov R3, #10          
    lcall Beep_N_Times

    ret

; =====================================================
; Buttons_Tick (non-blocking debounce)
; =====================================================
Buttons_Tick:
    ; -------- CYCLE_BTN --------
    mov c, CYCLE_BTN
    jc  M_BT_CYC_RELEASED

M_BT_CYC_PRESSED:
    mov a, cyc_cnt
    cjne a, #3, M_BT_CYC_INC
    ljmp M_BT_CYC_DONE
M_BT_CYC_INC:
    inc cyc_cnt
    mov a, cyc_cnt
    cjne a, #3, M_BT_CYC_DONE
    jb  cyc_stable, M_BT_CYC_DONE
    setb cyc_stable
    setb cyc_event
    ljmp M_BT_CYC_DONE

M_BT_CYC_RELEASED:
    mov a, cyc_cnt
    jz  M_BT_CYC_REL_DONE
    dec cyc_cnt
    mov a, cyc_cnt
    jnz M_BT_CYC_REL_DONE
    clr cyc_stable
M_BT_CYC_REL_DONE:

M_BT_CYC_DONE:

    ; -------- STOP_BTN --------
    mov c, STOP_BTN
    jc  M_BT_STOP_RELEASED

M_BT_STOP_PRESSED:
    mov a, stop_cnt
    cjne a, #3, M_BT_STOP_INC
    ljmp M_BT_STOP_DONE
M_BT_STOP_INC:
    inc stop_cnt
    mov a, stop_cnt
    cjne a, #3, M_BT_STOP_DONE
    jb  stop_stable, M_BT_STOP_DONE
    setb stop_stable
    setb stop_event
    ljmp M_BT_STOP_DONE

M_BT_STOP_RELEASED:
    mov a, stop_cnt
    jz  M_BT_STOP_REL_DONE
    dec stop_cnt
    mov a, stop_cnt
    jnz M_BT_STOP_REL_DONE
    clr stop_stable
M_BT_STOP_REL_DONE:

M_BT_STOP_DONE:

    ; -------- CONFIRM_BTN --------
    mov c, CONFIRM_BTN
    jc  M_BT_CONF_RELEASED

M_BT_CONF_PRESSED:
    mov a, conf_cnt
    cjne a, #3, M_BT_CONF_INC
    ljmp M_BT_DONE
M_BT_CONF_INC:
    inc conf_cnt
    mov a, conf_cnt
    cjne a, #3, M_BT_DONE
    jb  conf_stable, M_BT_DONE
    setb conf_stable
    setb conf_event
    ljmp M_BT_DONE

M_BT_CONF_RELEASED:
    mov a, conf_cnt
    jz  M_BT_DONE
    dec conf_cnt
    mov a, conf_cnt
    jnz M_BT_DONE
    clr conf_stable

M_BT_DONE:
    ret

; =====================================================
; PWM_Tick
; 20-tick PWM window.
; duty is 0..100%, mapped to 0..20 ticks.
; =====================================================
PWM_Tick:
    ; advance phase 0..19
    inc pwm_phase
    mov a, pwm_phase
    cjne a, #20, M_PWM_PHASE_OK
    mov pwm_phase, #0
M_PWM_PHASE_OK:

    mov a, pwm_duty
    jz  M_PWM_OFF

    ; threshold = pwm_duty / 5  (0..20)
    mov b, #5
    div ab          ; A = threshold

    ; if pwm_phase < threshold => ON
    mov r7, a       ; threshold
    mov a, pwm_phase
    clr c
    subb a, r7
    jc  M_PWM_ON

M_PWM_OFF:
    clr HEATER_OUT
    ret

M_PWM_ON:
    setb HEATER_OUT
    ret

; =====================================================
; FSM_Reflow_TempBased
; Ramp states advance on temperature reaching the setpoint.
; =====================================================
FSM_Reflow_TempBased:
    mov a, fsm_state

M_FSM_0:
    cjne a, #0, M_FSM_1
    mov pwm_duty, #0
    ret

; PREHEAT: full power until within 20C of temp_soak, then 20% until reaching temp_soak
M_FSM_1:
    cjne a, #1, M_FSM_2

    ; If T >= temp_soak -> next state
    mov a, temp_current
    clr c
    subb a, temp_soak
    jnc M_FSM_1_REACHED

    ; threshold = max(temp_soak - 20, 0)
    mov a, temp_soak
    clr c
    subb a, #20
    jnc M_FSM_1_TOK
    mov a, #0
M_FSM_1_TOK:
    mov R7, a

    ; If T >= threshold -> 20%, else 100%
    mov a, temp_current
    clr c
    subb a, R7
    jnc M_FSM_1_NEAR

    mov pwm_duty, #100
    ret

M_FSM_1_NEAR:
    mov pwm_duty, #20
    ret

M_FSM_1_REACHED:
    mov seconds,   #0
    mov fsm_state, #2
    setb force_redraw
    ; --- Init 3-buzzer outputs (idle HIGH) ---
    setb SPEAKER


    mov R3, #1            
    lcall Beep_N_Times
    ret


; SOAK: 20% for time_soak seconds
M_FSM_2:
    cjne a, #2, M_FSM_3
    mov pwm_duty, #20

    mov a, seconds
    clr c
    subb a, time_soak
    jc  M_FSM_2_DONE

    mov seconds,   #0
    mov fsm_state, #3
    setb force_redraw
    ; --- Init 3-buzzer outputs (idle HIGH) ---
    setb SPEAKER

     mov R3, #1            
    lcall Beep_N_Times
M_FSM_2_DONE:
    ret

; RAMP: full power until within 5C of temp_reflow, then 25% until reaching temp_reflow
M_FSM_3:
    cjne a, #3, M_FSM_4

    ; If T >= temp_reflow -> next state
    mov a, temp_current
    clr c
    subb a, temp_reflow
    jnc M_FSM_3_REACHED

    ; threshold = max(temp_reflow - 5, 0)
    mov a, temp_reflow
    clr c
    subb a, #5
    jnc M_FSM_3_TOK
    mov a, #0
M_FSM_3_TOK:
    mov R7, a

    ; If T >= threshold -> 25%, else 100%
    mov a, temp_current
    clr c
    subb a, R7
    jnc M_FSM_3_NEAR

    mov pwm_duty, #100
    ret

M_FSM_3_NEAR:
    mov pwm_duty, #25
    ret

M_FSM_3_REACHED:
    mov seconds,   #0
    mov fsm_state, #4
    setb force_redraw
    ; --- Init 3-buzzer outputs (idle HIGH) ---
    setb SPEAKER

     mov R3, #1            
    lcall Beep_N_Times
    ret


; REFLOW: 25% for time_reflow seconds
M_FSM_4:
    cjne a, #4, M_FSM_5
    mov pwm_duty, #25

    mov a, seconds
    clr c
    subb a, time_reflow
    jc  M_FSM_4_DONE

    mov seconds,   #0
    mov fsm_state, #5
    mov pwm_duty,  #0
    setb force_redraw
    ; --- Init 3-buzzer outputs (idle HIGH) ---
    setb SPEAKER

     mov R3, #5            
    lcall Beep_N_Times
M_FSM_4_DONE:
    ret

; COOL: 0% indefinitely (until POWER reset)
M_FSM_5:
    cjne a, #5, M_FSM_DONE
    mov pwm_duty, #0
M_FSM_5_DONE:
    ret

M_FSM_DONE:
    ret

; =====================================================
; Local strings (unique names)
; =====================================================
M_STR_BOOT1:      db 'Reflow Controller',0
M_STR_BOOT2:      db 'Use IR remote...',0

; IDLE strings
M_STR_IDLE_P1:    db 'S',0
M_STR_IDLE_MID:   db 's R',0
M_STR_IDLE_END:   db 's     ',0
M_STR_IDLE_P2:    db 'CONF=GO CYC=EDIT',0

; ABORT strings (remote)
M_STR_ABORT_L1:      db 'ABORT T:',0
M_STR_ABORT_L1_END:  db '     ',0
M_STR_ABORT_L2:      db 'OK=ACK  PWR=RST ',0
; RUN strings
M_STR_RUN_L1:     db 'PWR:',0
M_STR_RUN_L2:     db 't:',0
M_STR_TLAB:       db ' T:',0
M_STR_RUN_L2_END: db '      ',0

; 7-char state strings
M_ST_PREHEAT:     db 'PREHEAT',0
M_ST_SOAK:        db 'SOAK   ',0
M_ST_RAMP:        db 'RAMP   ',0
M_ST_REFLOW:      db 'REFLOW ',0
M_ST_COOL:        db 'COOL   ',0
M_ST_ABORT:      db 'ABORT  ',0

; -----------------------------------------------------
; 7-seg digit font table (0..9)
; DE10-Lite HEX displays are active-LOW (0 = segment ON).
; This table matches the known-working myLUT values.
; -----------------------------------------------------
SegTable:
    db 0C0h ;0
    db 0F9h ;1
    db 0A4h ;2
    db 0B0h ;3
    db 099h ;4
    db 092h ;5
    db 082h ;6
    db 0F8h ;7
    db 080h ;8
    db 090h ;9

; =====================================================
; SUBROUTINES AND ISRs (Keep these separate from data!)
; =====================================================

Timer0_ISR:
    mov TH0, #high(TIMER0_RELOAD)
    mov TL0, #low(TIMER0_RELOAD)
    ; Only toggle the buzzer when we are in a beep ON phase.
    jb  beep_phase_on, T0_TOGGLE
    reti
T0_TOGGLE:
    cpl SPEAKER
    reti



; =====================================================
; Non-blocking beeper
; - Timer0 ISR toggles SPEAKER when TR0 is running.
; - Beep_Task is called every 5ms from Service_Tick.
;
; Beep_N_Times: start R3 short beeps without blocking.
; =====================================================

Beep_N_Times:
    mov a, R3
    jz  BNT_DONE
    ; If already beeping, ignore new request (prevents overlap)
    jb  beep_active, BNT_DONE

    ; Ensure Timer0 is configured for tone generation (IR decode may have left TH0/TL0 at 0)
    clr TR0
    clr TF0
    mov TH0, #high(TIMER0_RELOAD)
    mov TL0, #low(TIMER0_RELOAD)

    mov beep_reps, a
    mov beep_ticks, #BEEP_ON_TICKS
    setb beep_active
    setb beep_phase_on
    setb TR0
    ret
BNT_DONE:
    ret

Beep_Task:
    jb  beep_active, BT_ACTIVE
    ret

BT_ACTIVE:
    mov a, beep_ticks
    jz  BT_PHASE_DONE
    dec beep_ticks
    ret

BT_PHASE_DONE:
    ; phase finished: toggle ON/OFF
    jb  beep_phase_on, BT_TURN_OFF

    ; currently OFF -> either start next beep or finish
    mov a, beep_reps
    jz  BT_STOP
    dec beep_reps
    mov a, beep_reps
    jz  BT_STOP

    ; start next ON phase
    mov beep_ticks, #BEEP_ON_TICKS
    setb beep_phase_on
    setb TR0
    ret

BT_TURN_OFF:
    clr TR0
    setb SPEAKER
    clr beep_phase_on
    mov beep_ticks, #BEEP_OFF_TICKS
    ret

BT_STOP:
    clr TR0
    setb SPEAKER
    clr beep_active
    clr beep_phase_on
    mov beep_ticks, #0
    mov beep_reps,  #0
    ret

END
