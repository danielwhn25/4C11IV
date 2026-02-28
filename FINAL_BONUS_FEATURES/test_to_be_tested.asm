$MODMAX10
CSEG
    ljmp main
org 0x000B
    ljmp Timer0_ISR


ELCD_RS equ P1.7
ELCD_E  equ P1.1
ELCD_D4 equ P0.7
ELCD_D5 equ P0.5
ELCD_D6 equ P0.3
ELCD_D7 equ P0.1

CYCLE_BTN   equ P3.7
CONFIRM_BTN equ P1.5
STOP_BTN    equ P3.5

HEATER_OUT  equ P1.3
SPEAKER    equ P1.2
IR_IN       equ P2.4
BIT_THRESH    EQU 0Bh
HEADER_THRESH EQU 15h
IR_CODE_POWER EQU 45h
IR_CODE_OK    EQU 40h

T1_RELOAD_H     equ 0C9h
T1_RELOAD_L     equ 0C0h
TICKS_PER_SEC   equ 200

BEEP_ON_TICKS   equ 10
BEEP_OFF_TICKS  equ 10


FREQ   EQU 33333333
TIMER0_RATE   EQU 4096
TIMER0_RELOAD EQU ((65536-(FREQ/(12*TIMER0_RATE))))
BAUD   EQU 115200
T2LOAD EQU 65536-(FREQ/(32*BAUD))


CSEG
    ljmp main

$NOLIST
$include(LCD_4bit_DE10Lite_no_RW.inc)
$LIST

DSEG AT 30h

fsm_state:     ds 1
seconds:       ds 1

time_soak:     ds 1
temp_soak:     ds 1

time_reflow:   ds 1
temp_reflow:   ds 1

timer_tick:    ds 1
pwm_phase:     ds 1
pwm_duty:      ds 1

beep_ticks:    ds 1
beep_reps:     ds 1

last_seconds:  ds 1

cyc_cnt:       ds 1
stop_cnt:      ds 1
conf_cnt:      ds 1

ui_cat: ds 1
ui_opt: ds 1
ui_sel: ds 4

temp_current:  ds 1
temp_tenths:   ds 1

setup_phase:   ds 1
entry_value:   ds 1
digit_count:   ds 1

temp_start:    ds 1
startup_sec:   ds 1


rx_len:        ds 1
rx_buf:        ds 8

ir_buf:        ds 4

BSEG
cyc_stable:    dbit 1
stop_stable:   dbit 1
conf_stable:   dbit 1
cyc_event:     dbit 1
stop_event:    dbit 1
conf_event:    dbit 1
conf_direct_prev: dbit 1
force_redraw:  dbit 1
startup_active: dbit 1
setup_active:   dbit 1
beep_active:    dbit 1
beep_phase_on:  dbit 1

$INCLUDE (UIWorkingABD2.asm)

CSEG

main:
    mov SP, #60h

    mov P0MOD, #10101010b
    mov P1MOD, #10001110b
        mov P3MOD, #00000000b
    mov P2MOD, #00000000b
    setb IR_IN

    setb CONFIRM_BTN
    setb CYCLE_BTN
    setb STOP_BTN

    setb conf_direct_prev

    clr HEATER_OUT
    mov pwm_duty, #0

    lcall InitSerialPort
    mov rx_len, #0

    lcall ELCD_4BIT
    mov ADC_C, #080h
    lcall Wait50ms


    Set_Cursor(1,1)
    mov dptr, #M_STR_BOOT1
    lcall LCD_SendString
    Set_Cursor(2,1)
    mov dptr, #M_STR_BOOT2
    lcall LCD_SendString
    lcall Wait50ms
    setb setup_active
    mov setup_phase, #0
    mov entry_value, #0
    mov digit_count, #0
    lcall Clear_Entry_Displays
    lcall Setup_ShowPrompt

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
    setb SPEAKER

    clr TR0
    clr beep_active
    clr beep_phase_on
    mov beep_ticks, #0
    mov beep_reps,  #0


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


InitSerialPort:
    clr TR2
    mov T2CON, #30H
    mov RCAP2H, #high(T2LOAD)
    mov RCAP2L, #low(T2LOAD)
    setb TR2
    mov SCON, #52H
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

SerialRx_ProcessChar:
    mov r7, a

    cjne a, #0Dh, SR_CHK_LF
    sjmp SR_EOL
SR_CHK_LF:
    cjne a, #0Ah, SR_CONT
    sjmp SR_EOL

SR_CONT:
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
    mov r6, a
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

ParseTempLine:
    mov r1, #rx_buf
    mov r0, rx_len

    mov r2, #0
    mov r3, #0
    mov r4, #0
    mov r5, #0

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

    cjne a, #'.', PT_CHK_DIG
    mov r4, #1
    inc r1
    djnz r0, PT_LOOP
    sjmp PT_DONE_PARSE

PT_CHK_DIG:
    mov a, @r1
    clr c
    subb a, #'0'
    jc  PT_NEXT
    mov a, @r1
    clr c
    subb a, #('9'+1)
    jnc PT_NEXT

    mov a, r4
    jnz PT_TENTHS

    mov a, r2
    mov b, #10
    mul ab
    mov a, b
    jnz PT_SAT_INT

    mov a, r2
    mov b, #10
    mul ab
    mov r2, a

    mov a, @r1
    anl a, #0Fh
    add a, r2
    jc  PT_SAT_INT
    mov r2, a
    sjmp PT_NEXT

PT_TENTHS:
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
    mov r2, #0
    mov r5, #0

PT_STORE:
    mov temp_current, r2
    mov temp_tenths, r5
    jb  setup_active, PT_SKIP_7SEG
    lcall Update7SegTemp
PT_SKIP_7SEG:
    setb force_redraw
    setb SPEAKER


    lcall Serial_SendTemp

    lcall ADC0_SendLine
    ret
Serial_SendTemp:
    mov a, temp_current
    mov b, #100
    div ab
    mov r2, a
    mov a, b
    mov b, #10
    div ab
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

SEG_BLANK equ 0FFh


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

    mov ADC_C, #00h
    lcall ADC_Wait1ms

    mov r6, ADC_H
    mov r7, ADC_L

    mov a, #'A'
    lcall putchar
    mov a, #'0'
    lcall putchar
    mov a, #'='
    lcall putchar

    mov a, r6
    lcall SendHexByte
    mov a, r7
    lcall SendHexByte

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

ADC_Wait1ms:
    mov r5, #25
AW1_LOOP:
    lcall Wait40uSec
    djnz r5, AW1_LOOP
    ret

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
    mov a, temp_current
    mov b, #100
    div ab
    mov r2, a
    mov a, b
    mov b, #10
    div ab
    mov r1, a
    mov r0, b

    mov a, r2
    jz  U7_HUND_BLANK
    mov dptr, #SegTable
    movc a, @a+dptr
    mov HEX2, a
    sjmp U7_TENS

U7_HUND_BLANK:
    mov HEX2, #SEG_BLANK

U7_TENS:
    mov a, r2
    jnz U7_TENS_SHOW
    mov a, r1
    jz  U7_TENS_BLANK
U7_TENS_SHOW:
    mov a, r1
    mov dptr, #SegTable
    movc a, @a+dptr
    mov HEX1, a
    sjmp U7_ONES

U7_TENS_BLANK:
    mov HEX1, #SEG_BLANK

U7_ONES:
    mov a, r0
    mov dptr, #SegTable
    movc a, @a+dptr
    mov HEX0, a

    mov HEX3, #SEG_BLANK
    mov HEX4, #SEG_BLANK
    mov HEX5, #SEG_BLANK
    ret



Clear_Entry_Displays:
    mov entry_value, #0
    mov digit_count, #0

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

Update7SegEntry:
    mov a, entry_value
    mov b, #100
    div ab
    mov r2, a
    mov a, b
    mov b, #10
    div ab
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

Setup_ShowPrompt:
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

LCD_Print3Dec:
    mov b, #100
    div ab
    mov r2, a
    mov a, b
    mov b, #10
    div ab
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

Wait5s:
    mov r6, #100
W5_LOOP:
    push 06h
    lcall Wait50ms
    pop 06h
    djnz r6, W5_LOOP
    ret

Wait1s:
    mov r6, #20
W1_LOOP:
    push 06h
    lcall Wait50ms
    pop 06h
    djnz r6, W1_LOOP
    ret



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

Setup_HandleDigit:
    mov r7, a
    jb  setup_active, SHD_IN_SETUP
    ret
SHD_IN_SETUP:
    mov a, setup_phase
    clr c
    subb a, #4
    jnc SHD_IGNORE

    mov a, digit_count
    clr c
    subb a, #3
    jnc SHD_IGNORE

    mov a, entry_value
    mov b, #10
    mul ab
    mov r6, a
    mov a, b
    jnz SHD_SAT

    mov a, r6
    add a, r7
    jc  SHD_SAT
    mov entry_value, a

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

Setup_HandleOK:
    jb  setup_active, SHOK_IN_SETUP
    ret
SHOK_IN_SETUP:
    mov a, setup_phase
    cjne a, #0, SHOK_1

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
    clr setup_active
    mov setup_phase, #0
    mov entry_value, #0
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

IR_Task:

    jb  beep_active, IR_EARLY_RET

    jb  IR_IN, IR_EARLY_RET

    sjmp IR_DECODE_START

IR_EARLY_RET:
    ret


IR_DECODE_START:
    clr ET0

    clr TR0
    clr TF0
    mov TH0, #0
    mov TL0, #0
    setb TR0
IRX_HDR_MARK_WAIT:
    jb  IR_IN, IRX_HDR_MARK_END
    mov a, TH0
    cjne a, #0FFh, IRX_HDR_MARK_WAIT
    ljmp IR_RESTORE
IRX_HDR_MARK_END:
    clr TR0

    clr TR0
    clr TF0
    mov TH0, #0
    mov TL0, #0
    setb TR0
IRX_HDR_SPACE_WAIT:
    jnb IR_IN, IRX_HDR_SPACE_END
    mov a, TH0
    cjne a, #0FFh, IRX_HDR_SPACE_WAIT
    ljmp IR_RESTORE
IRX_HDR_SPACE_END:
    clr TR0

    mov a, TH0
    clr c
    subb a, #HEADER_THRESH
    jnc IRX_HDR_SPACE_OK
    ljmp IR_RESTORE
IRX_HDR_SPACE_OK:

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
    cpl c

    mov a, @r1
    rrc a
    mov @r1, a

    djnz r2, IRX_ReadBit
    inc r1
    djnz r0, IRX_ReadByte

    mov a, ir_buf+2
    cpl a
    xrl a, ir_buf+3
    jz  IRX_CHK_OK
    ljmp IR_RESTORE
IRX_CHK_OK:

    mov a, ir_buf+2
    lcall IR_Dispatch
    lcall Wait50ms

IR_RESTORE:
    setb ET0

IR_DONE:
    ret

IR_Dispatch:
    cjne a, #IR_CODE_POWER, IRD_NOTPWR
    lcall Reset_To_Setup
    ret

IRD_NOTPWR:
    cjne a, #IR_CODE_OK, IRD_NOTOK

    mov a, fsm_state
    cjne a, #6, IRD_OK_NOT_ABORT
    lcall Reset_To_Setup
    ret
IRD_OK_NOT_ABORT:
    jb  setup_active, IRD_OK_SETUP
    ret
IRD_OK_SETUP:
    lcall Setup_HandleOK
    ret

IRD_NOTOK:
    lcall IR_GetDigit
    jnc IRD_DIGIT

    ret

IRD_DIGIT:
    jb  setup_active, IRD_DIG_OK
    ret

IRD_DIG_OK:
    lcall Setup_HandleDigit
    ret

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

Display_Update:
    jb  setup_active, DU_SETUP
    jb  force_redraw, M_DU_DRAW

    mov a, seconds
    cjne a, last_seconds, M_DU_DRAW
    ret

DU_SETUP:
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

M_DisplayRunStatus:
    Set_Cursor(1,1)

    mov dptr, #M_STR_RUN_L1
    lcall LCD_SendString

    mov a, pwm_duty
    lcall SendToLCD

    mov a, #'%'
    lcall ?WriteData

    mov a, #' '
    lcall ?WriteData

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

    Set_Cursor(2,1)

    mov a, fsm_state
    cjne a, #6, M_RS_L2_NORMAL

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

Seconds_Tick:
    inc timer_tick
    mov a, timer_tick
    cjne a, #TICKS_PER_SEC, M_SEC_DONE

    mov timer_tick, #0

    jb  startup_active, M_SEC_STARTUP_GUARD
    ljmp M_SEC_MAINSEC

M_SEC_STARTUP_GUARD:
    mov a, fsm_state
    cjne a, #1, M_SEC_STARTUP_CANCEL
    ljmp M_SEC_STARTUP

M_SEC_STARTUP_CANCEL:
    clr startup_active
    ljmp M_SEC_MAINSEC

M_SEC_STARTUP:
    inc startup_sec
    mov a, startup_sec
    cjne a, #60, M_SEC_MAINSEC
    lcall StartupAbort_Check60

M_SEC_MAINSEC:
    mov a, fsm_state
    cjne a, #6, M_SEC_INC
    ljmp M_SEC_REDRAW

M_SEC_INC:
    inc seconds

M_SEC_REDRAW:
    setb force_redraw
    setb SPEAKER

M_SEC_DONE:
    ret

StartupAbort_Check60:
    clr startup_active

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
    setb SPEAKER

    mov R3, #10
    lcall Beep_N_Times

    ret

Buttons_Tick:
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

PWM_Tick:
    inc pwm_phase
    mov a, pwm_phase
    cjne a, #20, M_PWM_PHASE_OK
    mov pwm_phase, #0
M_PWM_PHASE_OK:

    mov a, pwm_duty
    jz  M_PWM_OFF

    mov b, #5
    div ab

    mov r7, a
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

FSM_Reflow_TempBased:
    mov a, fsm_state

M_FSM_0:
    cjne a, #0, M_FSM_1
    mov pwm_duty, #0
    ret

M_FSM_1:
    cjne a, #1, M_FSM_2

    mov a, temp_current
    clr c
    subb a, temp_soak
    jnc M_FSM_1_REACHED

    mov a, temp_soak
    clr c
    subb a, #20
    jnc M_FSM_1_TOK
    mov a, #0
M_FSM_1_TOK:
    mov R7, a

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
    setb SPEAKER


    mov R3, #1
    lcall Beep_N_Times
    ret


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
    setb SPEAKER

     mov R3, #1
    lcall Beep_N_Times
M_FSM_2_DONE:
    ret

M_FSM_3:
    cjne a, #3, M_FSM_4

    mov a, temp_current
    clr c
    subb a, temp_reflow
    jnc M_FSM_3_REACHED

    mov a, temp_reflow
    clr c
    subb a, #5
    jnc M_FSM_3_TOK
    mov a, #0
M_FSM_3_TOK:
    mov R7, a

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
    setb SPEAKER

     mov R3, #1
    lcall Beep_N_Times
    ret


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
    setb SPEAKER

     mov R3, #5
    lcall Beep_N_Times
M_FSM_4_DONE:
    ret

M_FSM_5:
    cjne a, #5, M_FSM_DONE
    mov pwm_duty, #0
M_FSM_5_DONE:
    ret

M_FSM_DONE:
    ret

M_STR_BOOT1:      db 'Reflow Controller',0
M_STR_BOOT2:      db 'Use IR remote...',0

M_STR_IDLE_P1:    db 'S',0
M_STR_IDLE_MID:   db 's R',0
M_STR_IDLE_END:   db 's     ',0
M_STR_IDLE_P2:    db 'CONF=GO CYC=EDIT',0

M_STR_ABORT_L1:      db 'ABORT T:',0
M_STR_ABORT_L1_END:  db '     ',0
M_STR_ABORT_L2:      db 'OK=ACK  PWR=RST ',0
M_STR_RUN_L1:     db 'PWR:',0
M_STR_RUN_L2:     db 't:',0
M_STR_TLAB:       db ' T:',0
M_STR_RUN_L2_END: db '      ',0

M_ST_PREHEAT:     db 'PREHEAT',0
M_ST_SOAK:        db 'SOAK   ',0
M_ST_RAMP:        db 'RAMP   ',0
M_ST_REFLOW:      db 'REFLOW ',0
M_ST_COOL:        db 'COOL   ',0
M_ST_ABORT:      db 'ABORT  ',0

SegTable:
    db 0C0h
    db 0F9h
    db 0A4h
    db 0B0h
    db 099h
    db 092h
    db 082h
    db 0F8h
    db 080h
    db 090h


Timer0_ISR:
    mov TH0, #high(TIMER0_RELOAD)
    mov TL0, #low(TIMER0_RELOAD)
    jb  beep_phase_on, T0_TOGGLE
    reti
T0_TOGGLE:
    cpl SPEAKER
    reti




Beep_N_Times:
    mov a, R3
    jz  BNT_DONE
    jb  beep_active, BNT_DONE

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
    jb  beep_phase_on, BT_TURN_OFF

    mov a, beep_reps
    jz  BT_STOP
    dec beep_reps
    mov a, beep_reps
    jz  BT_STOP

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
