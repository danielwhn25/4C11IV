$MODMAX10

; =========================
; Standalone LCD UI Project
; =========================

; =========================
; Start / Stop buttons
; =========================
;START_BTN   BIT P2.0    ; TODO: assign actual START button pin
;STOP_BTN    BIT P2.1    ; TODO: assign actual STOP button pin

; -------------------------
; Reset Vector
; -------------------------


CSEG at 0
    ljmp start

; -------------------------
; LCD wiring (match your DE10Lite wiring)
; -------------------------
ELCD_RS equ P1.7
ELCD_E  equ P1.1
ELCD_D4 equ P0.7
ELCD_D5 equ P0.5
ELCD_D6 equ P0.3
ELCD_D7 equ P0.1

; -------------------------
; Buttons
; -------------------------
CYCLE_BTN   equ P3.7     ; "cycle"
CONFIRM_BTN equ P1.5     ; "confirm"

; -------------------------
; RAM
; -------------------------
dseg at 30h
ui_cat: ds 1     ; 0..4 (4 = summary)
ui_opt: ds 1     ; 0..2
ui_sel: ds 4     ; selections for 4 categories (each 0..2)

cseg

$NOLIST
$include(LCD_4bit_DE10Lite_no_RW.inc)
$LIST

; -------------------------
; Simple delay ~50ms @ 33.33MHz (same as your example)
; -------------------------
Wait50ms:
    mov R0, #30
W50_L3:
    mov R1, #74
W50_L2:
    mov R2, #250
W50_L1:
    djnz R2, W50_L1
    djnz R1, W50_L2
    djnz R0, W50_L3
    ret

; -------------------------
; LCD print null-terminated string from code memory at DPTR
; -------------------------
LCD_SendString:
    clr a
    movc a, @a+dptr
    jz  LCD_SendString_Done
    lcall ?WriteData
    inc dptr
    sjmp LCD_SendString
LCD_SendString_Done:
    ret

; -------------------------
; Send 8-bit number in A to LCD as decimal (XXX)
; -------------------------
SendToLCD:
    mov b, #100
    div ab
    orl a, #30h
    lcall ?WriteData

    mov a, b
    mov b, #10
    div ab
    orl a, #30h
    lcall ?WriteData

    mov a, b
    orl a, #30h
    lcall ?WriteData
    ret

; -------------------------
; Debounced button press
; Returns A:
;   0 = none
;   1 = cycle
;   2 = confirm
; Assumes ACTIVE-LOW buttons (pressed=0).
; -------------------------
UI_GetButtonPress:
    ; confirm priority
    jnb CONFIRM_BTN, UI_ConfDown
    jnb CYCLE_BTN,   UI_CycDown
    clr a
    ret

UI_ConfDown:
    lcall Wait50ms
    jb   CONFIRM_BTN, UI_None
UI_ConfWaitRel:
    jnb  CONFIRM_BTN, UI_ConfWaitRel
    lcall Wait50ms
    mov  a, #2
    ret

UI_CycDown:
    lcall Wait50ms
    jb   CYCLE_BTN, UI_None
UI_CycWaitRel:
    jnb  CYCLE_BTN, UI_CycWaitRel
    lcall Wait50ms
    mov  a, #1
    ret

UI_None:
    clr a
    ret

; =========================
; START / STOP debouncer  ← ADD HERE
; =========================
; Returns A:
;   0 = none
;   1 = START
;   2 = STOP
;
; NOTE: pin assignments TBD
GetStartStopEvent:
    ; TODO: implement
    ret

UI_WaitButton:
WB_Loop:
    lcall UI_GetButtonPress
    jz   WB_Loop
    ret

UI_WaitConfirmOnly:
WCO_Loop:
    lcall UI_GetButtonPress
    cjne a, #2, WCO_Loop
    ret

; -------------------------
; ui_sel[ui_cat] = ui_opt
; -------------------------
UI_StoreSelection:
    mov  a, #ui_sel
    add  a, ui_cat
    mov  r0, a
    mov  a, ui_opt
    mov  @r0, a
    ret

; -------------------------
; Print chosen strings helpers (A=0..2)
; -------------------------
UI_PrintSoakTime:
    cjne a, #0, PST1
    mov dptr, #UI_60s
    sjmp PSTgo
PST1:
    cjne a, #1, PST2
    mov dptr, #UI_90s
    sjmp PSTgo
PST2:
    mov dptr, #UI_120s
PSTgo:
    lcall LCD_SendString
    ret

UI_PrintSoakTemp:
    cjne a, #0, PSTT1
    mov dptr, #UI_130C
    sjmp PSTTgo
PSTT1:
    cjne a, #1, PSTT2
    mov dptr, #UI_150C
    sjmp PSTTgo
PSTT2:
    mov dptr, #UI_170C
PSTTgo:
    lcall LCD_SendString
    ret

UI_PrintReflowTime:
    cjne a, #0, PRT1
    mov dptr, #UI_45s
    sjmp PRTgo
PRT1:
    cjne a, #1, PRT2
    mov dptr, #UI_60s
    sjmp PRTgo
PRT2:
    mov dptr, #UI_75s
PRTgo:
    lcall LCD_SendString
    ret

UI_PrintReflowTemp:
    cjne a, #0, PRTT1
    mov dptr, #UI_200C
    sjmp PRTTgo
PRTT1:
    cjne a, #1, PRTT2
    mov dptr, #UI_220C
    sjmp PRTTgo
PRTT2:
    mov dptr, #UI_240C
PRTTgo:
    lcall LCD_SendString
    ret

; -------------------------
; Summary screen
; -------------------------
UI_DisplaySummary:
    ; Line 1: "S:" + soak time + " " + soak temp
    Set_Cursor(1,1)
    mov dptr, #UI_SUM_L1
    lcall LCD_SendString

    mov a, ui_sel+0
    lcall UI_PrintSoakTime
    mov a, #' '
    lcall ?WriteData
    mov a, ui_sel+1
    lcall UI_PrintSoakTemp

    mov dptr, #UI_CLRTAIL
    lcall LCD_SendString

    ; Line 2: "R:" + reflow time + " " + reflow temp
    Set_Cursor(2,1)
    mov dptr, #UI_SUM_L2
    lcall LCD_SendString

    mov a, ui_sel+2
    lcall UI_PrintReflowTime
    mov a, #' '
    lcall ?WriteData
    mov a, ui_sel+3
    lcall UI_PrintReflowTemp

    mov dptr, #UI_CLRTAIL
    lcall LCD_SendString
    ret

; =====================================================
; UI_DisplayStatus  (PART b)
; Displays:
;   Line 1: Temperature + time
;   Line 2: Current reflow state
;
; Uses variables:
;   temp_current        ; current temperature (°C)
;   seconds             ; elapsed time (s)
;   fsm_state           ; 0..5
; =====================================================
UI_DisplayStatus:

    ; ---------- Line 1 ----------
    Set_Cursor(1,1)
    mov dptr, #UI_STAT_L1
    lcall LCD_SendString

    ; Print temperature
    mov a, temp_current
    lcall SendToLCD        ; prints 3 digits
    mov a, #'C'
    lcall ?WriteData

    mov a, #' '
    lcall ?WriteData
    mov a, #'t'
    lcall ?WriteData
    mov a, #':'
    lcall ?WriteData

    ; Print time
    mov a, seconds
    lcall SendToLCD
    mov a, #'s'
    lcall ?WriteData

    ; Clear rest of line
    mov dptr, #UI_CLRTAIL
    lcall LCD_SendString

    ; ---------- Line 2 ----------
    Set_Cursor(2,1)
    mov dptr, #UI_STAT_L2
    lcall LCD_SendString

    mov a, fsm_state
    cjne a, #0, ST1
    mov dptr, #UI_ST_IDLE
    sjmp ST_PRINT
ST1:
    cjne a, #1, ST2
    mov dptr, #UI_ST_PREHEAT
    sjmp ST_PRINT
ST2:
    cjne a, #2, ST3
    mov dptr, #UI_ST_SOAK
    sjmp ST_PRINT
ST3:
    cjne a, #3, ST4
    mov dptr, #UI_ST_RAMP
    sjmp ST_PRINT
ST4:
    cjne a, #4, ST5
    mov dptr, #UI_ST_REFLOW
    sjmp ST_PRINT
ST5:
    mov dptr, #UI_ST_COOL

ST_PRINT:
    lcall LCD_SendString
    mov dptr, #UI_CLRTAIL
    lcall LCD_SendString
    ret


; -------------------------
; Display current category + option
; -------------------------
UI_DisplayMenu:
    mov a, ui_cat

    cjne a, #0, CAT1
    Set_Cursor(1,1)
    mov dptr, #UI_C0_L1
    lcall LCD_SendString
    mov a, ui_opt
    cjne a, #0, C0O1
    Set_Cursor(2,1)  ; >60  90 120
    mov dptr, #UI_C0_O0
    lcall LCD_SendString
    ret
C0O1:
    cjne a, #1, C0O2
    Set_Cursor(2,1)
    mov dptr, #UI_C0_O1
    lcall LCD_SendString
    ret
C0O2:
    Set_Cursor(2,1)
    mov dptr, #UI_C0_O2
    lcall LCD_SendString
    ret

CAT1:
    cjne a, #1, CAT2
    Set_Cursor(1,1)
    mov dptr, #UI_C1_L1
    lcall LCD_SendString
    mov a, ui_opt
    cjne a, #0, C1O1
    Set_Cursor(2,1)
    mov dptr, #UI_C1_O0
    lcall LCD_SendString
    ret
C1O1:
    cjne a, #1, C1O2
    Set_Cursor(2,1)
    mov dptr, #UI_C1_O1
    lcall LCD_SendString
    ret
C1O2:
    Set_Cursor(2,1)
    mov dptr, #UI_C1_O2
    lcall LCD_SendString
    ret

CAT2:
    cjne a, #2, CAT3
    Set_Cursor(1,1)
    mov dptr, #UI_C2_L1
    lcall LCD_SendString
    mov a, ui_opt
    cjne a, #0, C2O1
    Set_Cursor(2,1)
    mov dptr, #UI_C2_O0
    lcall LCD_SendString
    ret
C2O1:
    cjne a, #1, C2O2
    Set_Cursor(2,1)
    mov dptr, #UI_C2_O1
    lcall LCD_SendString
    ret
C2O2:
    Set_Cursor(2,1)
    mov dptr, #UI_C2_O2
    lcall LCD_SendString
    ret

CAT3:
    cjne a, #3, SUMMARY
    Set_Cursor(1,1)
    mov dptr, #UI_C3_L1
    lcall LCD_SendString
    mov a, ui_opt
    cjne a, #0, C3O1
    Set_Cursor(2,1)
    mov dptr, #UI_C3_O0
    lcall LCD_SendString
    ret
C3O1:
    cjne a, #1, C3O2
    Set_Cursor(2,1)
    mov dptr, #UI_C3_O1
    lcall LCD_SendString
    ret
C3O2:
    Set_Cursor(2,1)
    mov dptr, #UI_C3_O2
    lcall LCD_SendString
    ret

SUMMARY:
    ; ui_cat = 4
    lcall UI_DisplaySummary
    ret

; -------------------------
; Main UI state machine
; Returns after summary confirm (your "go later" point)
; -------------------------
UI_SelectProfile:
    mov ui_cat, #0
    mov ui_opt, #0
    mov ui_sel+0, #0
    mov ui_sel+1, #0
    mov ui_sel+2, #0
    mov ui_sel+3, #0

UI_Loop:
    lcall UI_DisplayMenu

    mov a, ui_cat
    cjne a, #4, NOT_SUMMARY

    ; Summary state: require confirm only
    lcall UI_WaitConfirmOnly

    ; Placeholder (no "go" yet)
    Set_Cursor(1,1)
    mov dptr, #UI_DONE1
    lcall LCD_SendString
    Set_Cursor(2,1)
    mov dptr, #UI_DONE2
    lcall LCD_SendString
    ret

NOT_SUMMARY:
    lcall UI_WaitButton        ; A=1 cycle, A=2 confirm
    cjne a, #1, CONFIRM

    ; cycle: ui_opt = (ui_opt + 1) mod 3
    inc ui_opt
    mov a, ui_opt
    cjne a, #3, UI_Loop
    mov ui_opt, #0
    sjmp UI_Loop

CONFIRM:
    ; confirm: store selection, next category, reset option
    lcall UI_StoreSelection
    inc ui_cat
    mov ui_opt, #0
    sjmp UI_Loop

; -------------------------
; Program start
; -------------------------
start:
    mov SP, #7FH

    ; LEDs off (optional)
    clr a
    mov LEDRA, a
    mov LEDRB, a

    ; LCD pins outputs, others inputs:
    mov P0MOD, #10101010b      ; P0.1,3,5,7 outputs
    mov P1MOD, #10000010b      ; P1.7, P1.1 outputs; P1.5 stays input
    mov P3MOD, #00000000b      ; ensure P3.7 is input

    lcall ELCD_4BIT

    ; small boot message
    Set_Cursor(1,1)
    mov dptr, #UI_BOOT1
    lcall LCD_SendString
    Set_Cursor(2,1)
    mov dptr, #UI_BOOT2
    lcall LCD_SendString
    lcall Wait50ms
    lcall Wait50ms

    ; run UI
    lcall UI_SelectProfile

HANG:
    sjmp HANG

; -------------------------
; Strings (pad to 16 chars)
; -------------------------
UI_BOOT1:   db 'Reflow UI Ready ',0
UI_BOOT2:   db 'Cycle/Confirm   ',0

UI_C0_L1:   db 'Soak Time (s)   ',0
UI_C1_L1:   db 'Soak Temp (C)   ',0
UI_C2_L1:   db 'Reflow Time (s) ',0
UI_C3_L1:   db 'Reflow Temp (C) ',0

UI_C0_O0:   db '>60  90 120     ',0
UI_C0_O1:   db ' 60 >90 120     ',0
UI_C0_O2:   db ' 60  90 >120    ',0

UI_C1_O0:   db '>130 150 170    ',0
UI_C1_O1:   db ' 130>150 170    ',0
UI_C1_O2:   db ' 130 150>170    ',0

UI_C2_O0:   db '>45  60  75     ',0
UI_C2_O1:   db ' 45 >60  75     ',0
UI_C2_O2:   db ' 45  60 >75     ',0

UI_C3_O0:   db '>200 220 240    ',0
UI_C3_O1:   db ' 200>220 240    ',0
UI_C3_O2:   db ' 200 220>240    ',0

UI_SUM_L1:  db 'S:',0
UI_SUM_L2:  db 'R:',0
UI_CLRTAIL: db '        ',0   ; clears leftover chars

UI_45s:     db '45s',0
UI_60s:     db '60s',0
UI_75s:     db '75s',0
UI_90s:     db '90s',0
UI_120s:    db '120s',0

UI_130C:    db '130C',0
UI_150C:    db '150C',0
UI_170C:    db '170C',0
UI_200C:    db '200C',0
UI_220C:    db '220C',0
UI_240C:    db '240C',0

UI_DONE1:   db 'Selections saved',0
UI_DONE2:   db 'Press reset     ',0

; ---------- Status screen strings ----------
UI_STAT_L1:     db 'T:',0
UI_STAT_L2:     db 'State: ',0

UI_ST_IDLE:     db 'IDLE',0
UI_ST_PREHEAT:  db 'PREHEAT',0
UI_ST_SOAK:     db 'SOAK',0
UI_ST_RAMP:     db 'RAMP',0
UI_ST_REFLOW:   db 'REFLOW',0
UI_ST_COOL:     db 'COOLDOWN',0


end