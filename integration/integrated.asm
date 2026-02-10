$MODMAX10

; =====================================================
; testall19.asm
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
; ADC_C DATA 0xa1
; ADC_L DATA 0xa2
; ADC_H DATA 0xa3

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

; -----------------------------------------------------
; Timer0 timebase
; 5 ms tick @ 33.333 MHz, Timer0 ticks at FREQ/12
; 200 ticks = 1 second
; reload = 0xC9C0
; -----------------------------------------------------
T0_RELOAD_H     equ 0C9h
T0_RELOAD_L     equ 0C0h
TICKS_PER_SEC   equ 200


; -----------------------------------------------------
; UART (serial)
; 115200 baud using Timer2 (same style as lab examples)
; -----------------------------------------------------
FREQ   EQU 33333333
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

; ---- startup abort check ----
temp_start:    ds 1   ; degC at GO (integer)
startup_sec:   ds 1   ; seconds since GO for 60s rise check


; ---- UART RX line buffer (ASCII temperature from PC) ----
rx_len:        ds 1
rx_buf:        ds 8


BSEG
cyc_stable:    dbit 1
stop_stable:   dbit 1
conf_stable:   dbit 1
cyc_event:     dbit 1
stop_event:    dbit 1
conf_event:    dbit 1
force_redraw:  dbit 1
startup_active: dbit 1

; =====================================================
; Include UI library (include-safe)
; =====================================================
$INCLUDE (UIWorkingABD.asm)

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
    mov P1MOD, #10001010b      ; b7=1 (RS), b3=1 (HEATER), b1=1 (E)
    mov P3MOD, #00000000b

    ; pull-up style inputs
    setb CONFIRM_BTN
    setb CYCLE_BTN
    setb STOP_BTN

    ; heater off
    clr HEATER_OUT
    mov pwm_duty, #0

    ; UART init (receive temperature from PC)
    lcall InitSerialPort

    ; LCD init
    lcall ELCD_4BIT

    ; boot
    Set_Cursor(1,1)
    mov dptr, #M_STR_BOOT1
    lcall LCD_SendString
    Set_Cursor(2,1)
    mov dptr, #M_STR_BOOT2
    lcall LCD_SendString
    lcall Wait50ms

    ; Profile selection UI (blocking)
    lcall UI_SelectProfile

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

    ; Timer0 setup (poll TF0)
    mov TMOD, #01h
    mov TH0, #T0_RELOAD_H
    mov TL0, #T0_RELOAD_L
    setb TR0

main_loop:
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
    lcall Update7SegTemp
    setb force_redraw

    ; echo back for debug (Python can read this)
    lcall Serial_SendTemp
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
Handle_UI_Events:
    ; If we're in ABORT (state 6), only CONFIRM acknowledges.
    mov a, fsm_state
    cjne a, #6, HE_NORMAL

    jb  conf_event, HE_ABORT_CONFIRM
    jb  stop_event, HE_ABORT_CLR_STOP
    jb  cyc_event,  HE_ABORT_CLR_CYC
    ret

HE_ABORT_CLR_STOP:
    clr stop_event
    ret

HE_ABORT_CLR_CYC:
    clr cyc_event
    ret

HE_ABORT_CONFIRM:
    clr conf_event
    mov pwm_duty, #0
    clr HEATER_OUT
    mov fsm_state, #0
    mov seconds, #0
    mov timer_tick, #0
    mov startup_sec, #0
    clr startup_active
    setb force_redraw
    ret

HE_NORMAL:
    jb  stop_event, M_HE_STOP
    jb  cyc_event,  M_HE_CYCLE
    jb  conf_event, M_HE_CONFIRM
    ret

M_HE_STOP:
    clr stop_event

    mov a, fsm_state
    jz  M_HE_STOP_DONE          ; ignore if already idle

M_HE_ABORT_COMMON:
    mov pwm_duty, #0
    clr HEATER_OUT
    mov fsm_state, #0
    mov seconds, #0
    mov timer_tick, #0
    mov startup_sec, #0
    clr startup_active
    setb force_redraw
M_HE_STOP_DONE:
    ret

M_HE_CYCLE:
    clr cyc_event

    mov a, fsm_state
    jnz M_HE_ABORT_COMMON       ; running => abort

    ; IDLE => edit profile
    clr TR0

    lcall UI_SelectProfile

    ; reset to idle
    mov fsm_state, #0
    mov seconds, #0
    mov timer_tick, #0
    mov pwm_duty, #0
    clr HEATER_OUT

    mov last_seconds, #0FFh
    setb force_redraw

    setb TR0
    ret

M_HE_CONFIRM:
    clr conf_event

    mov a, fsm_state
    jnz M_HE_CONFIRM_DONE       ; running: ignore

    ; IDLE: start
    mov seconds, #0
    mov timer_tick, #0
    mov fsm_state, #1
    mov a, temp_current
    mov temp_start, a
    mov startup_sec, #0
    setb startup_active
    setb force_redraw

M_HE_CONFIRM_DONE:
    ret

; =====================================================
; Display_Update
; =====================================================
Display_Update:
    jb  force_redraw, M_DU_DRAW

    mov a, seconds
    cjne a, last_seconds, M_DU_DRAW
    ret

M_DU_DRAW:
    clr force_redraw

    mov a, seconds
    mov last_seconds, a

    mov a, fsm_state
    jz  M_DU_IDLE

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
    sjmp M_RS_PRINTST
M_RS_ST2:
    cjne a, #2, M_RS_ST3
    mov dptr, #M_ST_SOAK
    sjmp M_RS_PRINTST
M_RS_ST3:
    cjne a, #3, M_RS_ST4
    mov dptr, #M_ST_RAMP
    sjmp M_RS_PRINTST
M_RS_ST4:
    cjne a, #4, M_RS_ST5
    mov dptr, #M_ST_REFLOW
    sjmp M_RS_PRINTST

M_RS_ST5:
    cjne a, #5, M_RS_ST6
    mov dptr, #M_ST_COOL
    sjmp M_RS_PRINTST

M_RS_ST6:
    cjne a, #6, M_RS_STX
    mov dptr, #M_ST_ABORT
    sjmp M_RS_PRINTST

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
; Called often; only runs when TF0 set.
; - debounces buttons (non-blocking)
; - updates PWM output (tick-based)
; - updates seconds
; =====================================================
Service_Tick:
    jnb TF0, M_ST_DONE
    clr TF0
    mov TH0, #T0_RELOAD_H
    mov TL0, #T0_RELOAD_L

    lcall Buttons_Tick
    lcall PWM_Tick
    lcall Seconds_Tick

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

    ; 60-second startup rise check (only once at t=60s after GO)
    jb  startup_active, M_SEC_STARTUP
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
    sjmp M_SEC_REDRAW

M_SEC_INC:
    inc seconds

M_SEC_REDRAW:
    setb force_redraw
M_SEC_DONE:
    ret

; -----------------------------------------------------
; StartupAbort_Check60
; At t = 60 seconds after GO, abort if temp has not risen by 50C.
; ABORT state requires CONFIRM to acknowledge.
; -----------------------------------------------------
StartupAbort_Check60:
    clr startup_active

    mov a, temp_current
    clr c
    subb a, temp_start
    jc  SAB_ABORT

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
    sjmp M_BT_CYC_DONE
M_BT_CYC_INC:
    inc cyc_cnt
    mov a, cyc_cnt
    cjne a, #3, M_BT_CYC_DONE
    jb  cyc_stable, M_BT_CYC_DONE
    setb cyc_stable
    setb cyc_event
    sjmp M_BT_CYC_DONE

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
    sjmp M_BT_STOP_DONE
M_BT_STOP_INC:
    inc stop_cnt
    mov a, stop_cnt
    cjne a, #3, M_BT_STOP_DONE
    jb  stop_stable, M_BT_STOP_DONE
    setb stop_stable
    setb stop_event
    sjmp M_BT_STOP_DONE

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
    sjmp M_BT_DONE
M_BT_CONF_INC:
    inc conf_cnt
    mov a, conf_cnt
    cjne a, #3, M_BT_DONE
    jb  conf_stable, M_BT_DONE
    setb conf_stable
    setb conf_event
    sjmp M_BT_DONE

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
    ret


; REFLOW: 20% for time_reflow seconds
M_FSM_4:
    cjne a, #4, M_FSM_5
    mov pwm_duty, #20

    mov a, seconds
    clr c
    subb a, time_reflow
    jc  M_FSM_4_DONE

    mov seconds,   #0
    mov fsm_state, #5
    mov pwm_duty,  #0
    setb force_redraw
M_FSM_4_DONE:
    ret

; COOL: 0% indefinitely (until user aborts)
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
M_STR_BOOT2:      db 'Select profile...',0

; IDLE strings
M_STR_IDLE_P1:    db 'S',0
M_STR_IDLE_MID:   db 's R',0
M_STR_IDLE_END:   db 's     ',0
M_STR_IDLE_P2:    db 'CONF=GO CYC=EDIT',0

; ABORT line2
M_STR_ABORT_L2:   db 'CONF=ACK T:',0

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

END
