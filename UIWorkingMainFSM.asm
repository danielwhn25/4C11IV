$MODMAX10

; =====================================================
; FSMChat3.asm (MAIN)
; Reflow Oven Controller
; - This is the ONLY main/entry file
; - UI module is included from: UITest2Chat2.asm
; - LCD routines are included from: LCD_4bit_DE10Lite_no_RW.inc
;
; IMPORTANT (fix for your CrossIDE error):
;   Do NOT use "CSEG AT 0" here.
;   Some setups/modules enter CSEG before your code, and CrossIDE then
;   throws: "CSEG at directive must use a value that is greater than the
;   current CSEG counter."  Starting with plain CSEG + putting LJMP main as
;   the first instruction reliably places the reset vector at address 0.
; =====================================================

; -------------------------
; LCD wiring (DE10-Lite)
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
CYCLE_BTN   equ P3.7     ; cycle / stop / edit
CONFIRM_BTN equ P1.5     ; confirm / start / toggle display
STOP_BTN    equ P3.5     ; emergency stop (active-low)

; -------------------------
; SSR / Heater output
; -------------------------
HEATER_OUT  equ P1.0

; -----------------------------------------------------
; Timer0 timebase
; -----------------------------------------------------
; Goal: make 'seconds' increment at 1 real-life second.
; Assumption (ELEC 291 / MODMAX10): FREQ = 33.333 MHz and Timer0 ticks at FREQ/12.
; We generate a 5 ms tick using Timer0 overflow, then count 200 ticks = 1 second.
;
; 5 ms tick reload (16-bit):
;   tick_hz = 200 Hz
;   counts  = (FREQ/12) / tick_hz ≈ 2,777,777 / 200 ≈ 13,888
;   reload  = 65,536 - 13,888 = 51,648 = 0xC9C0
;
T0_RELOAD_H     equ 0C9h
T0_RELOAD_L     equ 0C0h
TICKS_PER_SEC   equ 200     ; 200 * 5 ms = 1 s

; =====================================================
; Reset Vector @ 0x0000
; =====================================================
CSEG
    ljmp main

; -----------------------------------------------------
; Includes
; (LCD include contains code, so include it after vector)
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
temp_current:  ds 1

temp_soak:     ds 1
time_soak:     ds 1

temp_reflow:   ds 1
time_reflow:   ds 1

; ---- tick / pwm ----
timer_tick:    ds 1   ; 0..199 (TICKS_PER_SEC ticks = 1 second)
pwm_phase:     ds 1   ; 0..19 (20 ticks PWM window)
pwm_duty:      ds 1   ; 0..100 (%), mapped to 0..20 ticks

; ---- runtime UI helpers ----
display_mode:  ds 1   ; 0=status LCD, 1=large temp (placeholder)
last_seconds:  ds 1

; ---- debounce counters (0..3) ----
cyc_cnt:       ds 1
stop_cnt:      ds 1
conf_cnt:      ds 1

; ---- UI selection storage (indices 0..2) ----
ui_cat: ds 1            ; 0..4
ui_opt: ds 1            ; 0..2
ui_sel: ds 4            ; [0]=soak time, [1]=soak temp, [2]=reflow time, [3]=reflow temp

BSEG
cyc_stable:    dbit 1   ; 1 if button is stably pressed
stop_stable:   dbit 1
conf_stable:   dbit 1
cyc_event:     dbit 1   ; latched on press
stop_event:    dbit 1
conf_event:    dbit 1
force_redraw:  dbit 1

; =====================================================
; Include UI library (include-safe: no reset vector / no dseg / no END)
; =====================================================
$INCLUDE (UIWorkingABD.asm)

; =====================================================
; MAIN
; =====================================================
CSEG
main:
    mov SP, #60h
	
	; ===== HARD RESET ALL FSM / UI STATE =====

    ; -------------------------
    ; Port directions
    ; P0.1,3,5,7 outputs for LCD D7..D4
    ; P1.0 output heater, P1.1 E output, P1.7 RS output
    ; P1.5 confirm button input
    ; P3.7 cycle button input
    ; -------------------------
    mov P0MOD, #10101010b
    mov P1MOD, #10000011b
    mov P3MOD, #00000000b

    ; make button pins '1' so they read high when idle (pull-up style)
    setb CONFIRM_BTN
    setb CYCLE_BTN
    setb STOP_BTN

    ; heater off
    clr HEATER_OUT

    ; LEDs off (optional)
    clr a
    mov LEDRA, a
    mov LEDRB, a

    ; -------------------------
    ; LCD init + boot
    ; -------------------------
    lcall ELCD_4BIT

    Set_Cursor(1,1)
    mov dptr, #STR_BOOT1
    lcall LCD_SendString
    Set_Cursor(2,1)
    mov dptr, #STR_BOOT2
    lcall LCD_SendString
    lcall Wait50ms
    lcall Wait50ms

    ; -------------------------
    ; Profile selection (blocking UI)
    ; -------------------------
    lcall UI_SelectProfile     ; sets temp_soak/time_soak/temp_reflow/time_reflow

    ; show ready screen
    Set_Cursor(1,1)
    mov dptr, #STR_READY1
    lcall LCD_SendString
    Set_Cursor(2,1)
    mov dptr, #STR_READY2
    lcall LCD_SendString

    ; -------------------------
    ; Init runtime state
    ; -------------------------
    mov fsm_state, #0
    mov seconds, #0
    mov temp_current, #0

    mov timer_tick, #0
    mov pwm_phase, #0
    mov pwm_duty, #0

    mov display_mode, #0
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
    setb force_redraw

    ; -------------------------
    ; Timer0 setup (poll TF0)
    ; -------------------------
    mov TMOD, #01h
    ; Timer0 overflow every ~5ms (see constants above)
    mov TH0, #T0_RELOAD_H
    mov TL0, #T0_RELOAD_L
    setb TR0

main_loop:
    ; service periodic tick (buttons + pwm + seconds + temp sim)
    lcall Service_Tick

    ; real sensor read would update temp_current
    lcall Read_Temperature

    ; run FSM (sets pwm_duty)
    lcall FSM_Reflow

    ; handle start/stop/edit/toggle events
    lcall Handle_UI_Events

    ; update LCD (rate-limited)
    lcall Display_Update

    mov LEDRA, fsm_state
    sjmp main_loop

; =====================================================
; Handle_UI_Events
;
; IDLE (fsm_state=0):
;   - CONFIRM starts
;   - CYCLE edits profile (re-enters UI)
;
; RUNNING (fsm_state!=0):
;   - CYCLE stops immediately (pwm_duty=0, state->IDLE)
;   - CONFIRM toggles display mode
; =====================================================
Handle_UI_Events:
    ; -------- EMERGENCY STOP (P3.5) has top priority --------
    jb  stop_event, HE_STOP

HE_CHECK_CYCLE:
    ; -------- STOP (cycle) has priority --------
    jb  cyc_event, HE_CYCLE
    ljmp HE_CHECK_CONFIRM

HE_STOP:
    clr stop_event

    ; Only act as emergency stop during SOAK (2), RAMP (3), REFLOW (4)
    mov a, fsm_state
    cjne a, #2, HE_STOP_CHK3
    sjmp HE_STOP_DO
HE_STOP_CHK3:
    cjne a, #3, HE_STOP_CHK4
    sjmp HE_STOP_DO
HE_STOP_CHK4:
    cjne a, #4, HE_CHECK_CYCLE   ; not in 2/3/4: ignore

HE_STOP_DO:
    mov pwm_duty, #0
    clr HEATER_OUT
    mov fsm_state, #0
    mov seconds, #0
    mov timer_tick, #0
    setb force_redraw
    ret

HE_CYCLE:
    clr cyc_event

    mov a, fsm_state
    jz  HE_EDIT_PROFILE

    ; RUNNING: stop immediately
    mov pwm_duty, #0
    mov fsm_state, #0
    mov seconds, #0
    mov timer_tick, #0
    setb force_redraw
    ret

HE_EDIT_PROFILE:
    clr TR0



    lcall UI_SelectProfile


    ; after selection, show ready again
    Set_Cursor(1,1)
    mov dptr, #STR_READY1
    lcall LCD_SendString
    Set_Cursor(2,1)
    mov dptr, #STR_READY2
    lcall LCD_SendString

    mov seconds, #0
    mov timer_tick, #0
    mov pwm_duty, #0
    mov temp_current, #0
    mov last_seconds, #0FFh
    setb force_redraw

    setb TR0
    ret

HE_CHECK_CONFIRM:
    jb  conf_event, HE_CONFIRM
    ret

HE_CONFIRM:
    clr conf_event

    mov a, fsm_state
    jz  HE_START

    ; RUNNING: toggle display mode
    mov a, display_mode
    xrl a, #01h
    mov display_mode, a
    setb force_redraw
    ret

HE_START:
    ; IDLE: start
    mov seconds, #0
    mov timer_tick, #0
    mov fsm_state, #1
    setb force_redraw
    ret

; =====================================================
; Display_Update
; Updates LCD when seconds changed or force_redraw set.
; display_mode:
;   0 = UI_DisplayStatus (part b)
;   1 = UI_DisplayLargeTemp (part c - placeholder)
; =====================================================
Display_Update:
    jb  force_redraw, DU_DRAW

    mov a, seconds
    cjne a, last_seconds, DU_DRAW
    ret

DU_DRAW:
    clr force_redraw

    mov a, seconds
    mov last_seconds, a

    mov a, display_mode
    jz  DU_STATUS

    ; large temperature display (placeholder)
    lcall UI_DisplayLargeTemp
    ret

DU_STATUS:
    lcall UI_DisplayStatus
    ret

; =====================================================
; Service_Tick
; Called often; only runs when TF0 set.
; - debounces buttons (non-blocking)
; - updates seconds
; - updates PWM output (tick-based)
; - (optional) temperature simulation
; =====================================================
Service_Tick:
    jnb TF0, ST_DONE
    clr TF0
    mov TH0, #T0_RELOAD_H
    mov TL0, #T0_RELOAD_L

    lcall Buttons_Tick
    lcall PWM_Tick
    lcall Seconds_Tick
    lcall TempSim_Tick

ST_DONE:
    ret

; =====================================================
; Seconds_Tick
; TICKS_PER_SEC timer ticks = 1 second
; =====================================================
Seconds_Tick:
    inc timer_tick
    mov a, timer_tick
    cjne a, #TICKS_PER_SEC, SEC_DONE
    mov timer_tick, #0
    inc seconds
    setb force_redraw
SEC_DONE:
    ret

; =====================================================
; Buttons_Tick (non-blocking debounce)
; Debounce uses counters 0..3, event latched on stable press.
; =====================================================
Buttons_Tick:
    ; -------- CYCLE_BTN --------
    mov c, CYCLE_BTN
    jc  BT_CYC_RELEASED     ; 1 = released

BT_CYC_PRESSED:
    mov a, cyc_cnt
    cjne a, #3, BT_CYC_INC
    sjmp BT_CYC_DONE
BT_CYC_INC:
    inc cyc_cnt
    mov a, cyc_cnt
    cjne a, #3, BT_CYC_DONE
    jb  cyc_stable, BT_CYC_DONE
    setb cyc_stable
    setb cyc_event
    sjmp BT_CYC_DONE

BT_CYC_RELEASED:
    mov a, cyc_cnt
    jz  BT_CYC_REL_DONE
    dec cyc_cnt
    mov a, cyc_cnt
    jnz BT_CYC_REL_DONE
    clr cyc_stable
BT_CYC_REL_DONE:

BT_CYC_DONE:


    ; -------- STOP_BTN --------
    mov c, STOP_BTN
    jc  BT_STOP_RELEASED     ; 1 = released

BT_STOP_PRESSED:
    mov a, stop_cnt
    cjne a, #3, BT_STOP_INC
    sjmp BT_STOP_DONE
BT_STOP_INC:
    inc stop_cnt
    mov a, stop_cnt
    cjne a, #3, BT_STOP_DONE
    jb  stop_stable, BT_STOP_DONE
    setb stop_stable
    setb stop_event
    sjmp BT_STOP_DONE

BT_STOP_RELEASED:
    mov a, stop_cnt
    jz  BT_STOP_REL_DONE
    dec stop_cnt
    mov a, stop_cnt
    jnz BT_STOP_REL_DONE
    clr stop_stable
BT_STOP_REL_DONE:

BT_STOP_DONE:

    ; -------- CONFIRM_BTN --------
    mov c, CONFIRM_BTN
    jc  BT_CONF_RELEASED

BT_CONF_PRESSED:
    mov a, conf_cnt
    cjne a, #3, BT_CONF_INC
    sjmp BT_DONE
BT_CONF_INC:
    inc conf_cnt
    mov a, conf_cnt
    cjne a, #3, BT_DONE
    jb  conf_stable, BT_DONE
    setb conf_stable
    setb conf_event
    sjmp BT_DONE

BT_CONF_RELEASED:
    mov a, conf_cnt
    jz  BT_DONE
    dec conf_cnt
    mov a, conf_cnt
    jnz BT_DONE
    clr conf_stable

BT_DONE:
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
    cjne a, #20, PWM_PHASE_OK
    mov pwm_phase, #0
PWM_PHASE_OK:

    mov a, pwm_duty
    jz  PWM_OFF

    ; threshold = pwm_duty / 5  (0..20)
    mov b, #5
    div ab          ; A = threshold

    ; if pwm_phase < threshold => ON
    mov r7, a       ; threshold
    mov a, pwm_phase
    clr c
    subb a, r7
    jc  PWM_ON

PWM_OFF:
    clr HEATER_OUT
    ret

PWM_ON:
    setb HEATER_OUT
    ret

; =====================================================
; TempSim_Tick (optional)
; Simple temperature simulation so UI/FSM can be tested.
; Remove/replace when ADC reading is implemented.
; =====================================================
TempSim_Tick:
    mov a, fsm_state

    ; IDLE: temp -> 0
    cjne a, #0, TS_NOT_IDLE
    mov temp_current, #0
    ret

TS_NOT_IDLE:
    ; heating states 1 (preheat) and 3 (ramp)
    cjne a, #1, TS_CHECK_3
    sjmp TS_HEAT
TS_CHECK_3:
    cjne a, #3, TS_CHECK_COOL
    sjmp TS_HEAT

TS_CHECK_COOL:
    cjne a, #5, TS_DONE

    ; cooling
    mov a, temp_current
    jz  TS_DONE
    dec temp_current
    ret

TS_HEAT:
    mov a, temp_current
    cjne a, #240, TS_INC
    sjmp TS_DONE
TS_INC:
    inc temp_current

TS_DONE:
    ret

; =====================================================
; Read_Temperature (placeholder)
; Replace this with ADC read that updates temp_current.
; =====================================================
Read_Temperature:
    ret

; =====================================================
; FSM_Reflow
; State meanings:
;   0 IDLE
;   1 PREHEAT (heat until temp_soak)
;   2 SOAK    (hold time_soak)
;   3 RAMP    (heat until temp_reflow)
;   4 REFLOW  (hold time_reflow)
;   5 COOL    (cool until < 60C)
;
; NOTE: start/stop handled in Handle_UI_Events.
; =====================================================
FSM_Reflow:
    mov a, fsm_state

FSM_STATE_0:
    cjne a, #0, FSM_STATE_1
    mov pwm_duty, #0
    ret

FSM_STATE_1:
    cjne a, #1, FSM_STATE_2
    mov pwm_duty, #100

    mov a, temp_soak
    clr c
    subb a, temp_current
    jnc PREHEAT_DONE          ; if temp_current <= temp_soak, keep heating

    mov seconds,   #0
    mov fsm_state, #2
    setb force_redraw
PREHEAT_DONE:
    ret

FSM_STATE_2:
    cjne a, #2, FSM_STATE_3
    mov pwm_duty, #20

    mov a, seconds
    clr c
    subb a, time_soak
    jc  SOAK_DONE             ; if seconds < time_soak, keep soaking

    mov seconds,   #0
    mov fsm_state, #3
    setb force_redraw
SOAK_DONE:
    ret

FSM_STATE_3:
    cjne a, #3, FSM_STATE_4
    mov pwm_duty, #100

    mov a, temp_reflow
    clr c
    subb a, temp_current
    jnc RAMP_DONE             ; if temp_current <= temp_reflow, keep heating

    mov seconds,   #0
    mov fsm_state, #4
    setb force_redraw
RAMP_DONE:
    ret

FSM_STATE_4:
    cjne a, #4, FSM_STATE_5
    mov pwm_duty, #20

    mov a, seconds
    clr c
    subb a, time_reflow
    jc  REFLOW_DONE           ; if seconds < time_reflow, keep reflowing

    mov pwm_duty,  #0
    mov fsm_state, #5
    setb force_redraw
REFLOW_DONE:
    ret

FSM_STATE_5:
    cjne a, #5, FSM_DONE
    mov pwm_duty, #0

    mov a, temp_current
    clr c
    subb a, #60
    jnc COOL_DONE             ; if temp_current >= 60, keep cooling

    mov fsm_state, #0
    mov seconds,   #0
    setb force_redraw
COOL_DONE:
    ret

FSM_DONE:
    ret

; =====================================================
; Local strings used by main
; =====================================================
STR_BOOT1:  db 'Reflow Controller',0
STR_BOOT2:  db 'Select profile...',0

STR_READY1: db 'Ready. CONF=Start',0
STR_READY2: db 'CYC=Edit/Stop    ',0

END
