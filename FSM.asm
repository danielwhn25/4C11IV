$INCLUDE (MODMAX10)

CSEG AT 0000h
    ljmp main

DSEG AT 30h
fsm_state:     ds 1
seconds:       ds 1
temp_current:  ds 1

temp_soak:     ds 1
time_soak:     ds 1
temp_reflow:   ds 1
time_reflow:   ds 1

pwm_duty:      ds 1
pwm_cnt:       ds 1
timer_tick:    ds 1

CSEG
main:
    mov SP, #60h
    setb KEY_1       
    mov P1MOD, #01h
    clr P1.0
    mov LEDRA, #00h
    mov LEDRB, #00h

    mov temp_soak,   #150  
    mov time_soak,   #60   
    mov temp_reflow, #220  
    mov time_reflow, #45   

    mov fsm_state, #0
    mov seconds,   #0
    mov pwm_duty,  #0
    mov pwm_cnt,   #0
    mov timer_tick, #0
    mov temp_current, #0

    mov TMOD, #01h
    mov TH0, #0B0h
    mov TL0, #00h
    setb TR0

main_loop:
    ;For UI part d
    ;lcall Check_Buttons     

    lcall Update_Seconds
    lcall Read_Temperature  
    lcall FSM_Reflow
    
    ;For UI part b
    ;lcall UI_DisplayStatus

    mov LEDRA, fsm_state
    lcall PWM_Update
    sjmp main_loop
    
FSM_Reflow:
    mov a, fsm_state

; =====================================================
; Check_Buttons
; Handles START / STOP buttons
; =====================================================
;Check_Buttons:
;
;    ; ---------- STOP has priority ----------
;    jnb STOP_BTN, STOP_PRESSED
;    sjmp CHECK_START
;
;STOP_PRESSED:
;    lcall Debounce_Delay
;    jb STOP_BTN, CHECK_START   ; false trigger
;
;WAIT_STOP_RELEASE:
;    jnb STOP_BTN, WAIT_STOP_RELEASE
;
;    ; FORCE safe stop
;    mov pwm_duty,  #0
;    mov fsm_state, #0      ; back to IDLE
;    mov seconds,   #0
;    ret
;
;CHECK_START:
;    ; Only allow START if IDLE
;    mov a, fsm_state
;    cjne a, #0, DONE_CHECK
;
;    jnb START_BTN, START_PRESSED
;    sjmp DONE_CHECK
;
;START_PRESSED:
;    lcall Debounce_Delay
;    jb START_BTN, DONE_CHECK
;
;WAIT_START_RELEASE:
;    jnb START_BTN, WAIT_START_RELEASE
;
;    ; Start reflow
;    mov seconds,   #0
;    mov fsm_state, #1      ; PREHEAT
;    ret
;
;DONE_CHECK:
;    ret


FSM_STATE_0: 
    cjne a, #0, FSM_STATE_1
    mov pwm_duty, #0
    jb  KEY_1, idle_done
    jnb KEY_1, $           
    mov seconds,   #0
    mov fsm_state, #1
idle_done:
    ret

FSM_STATE_1: 
    cjne a, #1, FSM_STATE_2
    mov pwm_duty, #100
    mov a, temp_soak
    clr c
    subb a, temp_current
    jnc preheat_done       
    mov seconds,   #0
    mov fsm_state, #2
preheat_done:
    ret

FSM_STATE_2: 
    cjne a, #2, FSM_STATE_3
    mov pwm_duty, #20
    mov a, seconds
    clr c
    subb a, time_soak
    jc soak_done           
    mov seconds,   #0
    mov fsm_state, #3
soak_done:
    ret

FSM_STATE_3: 
    cjne a, #3, FSM_STATE_4
    mov pwm_duty, #100
    mov a, temp_reflow
    clr c
    subb a, temp_current
    jnc ramp_done         
    mov seconds,   #0
    mov fsm_state, #4
ramp_done:
    ret

FSM_STATE_4: 
    cjne a, #4, FSM_STATE_5
    mov pwm_duty, #20
    mov a, seconds
    clr c
    subb a, time_reflow
    jc reflow_done        
    mov pwm_duty, #0
    mov fsm_state, #5
reflow_done:
    ret

FSM_STATE_5: 
    cjne a, #5, FSM_DONE
    mov pwm_duty, #0
    mov a, temp_current
    clr c
    subb a, #60
    jnc cooling_done       
    mov fsm_state, #0     
cooling_done:
    ret

FSM_DONE:
    ret
Update_Seconds:
    jnb TF0, us_done
    clr TF0
    mov TH0, #0B0h
    mov TL0, #00h
    mov a, timer_tick
    anl a, #03h        
    jnz tick_timer_only 

    
    mov a, fsm_state
    
  
    cjne a, #0, check_heat
    mov temp_current, #0 
    sjmp tick_timer_only

check_heat:
    cjne a, #1, check_ramp3
    sjmp do_heat
check_ramp3:
    cjne a, #3, check_cool
    sjmp do_heat

check_cool:
    cjne a, #5, tick_timer_only
    mov a, temp_current
    jz tick_timer_only
    dec temp_current     
    dec temp_current     
    sjmp tick_timer_only

do_heat:
    mov a, temp_current
    cjne a, #240, inc_temp
    sjmp tick_timer_only
inc_temp:
    inc temp_current

tick_timer_only:
    inc timer_tick
    mov a, timer_tick
    cjne a, #20, us_done 
    mov timer_tick, #0
    inc seconds
us_done:
    ret

Read_Temperature:
    ret

PWM_Update:
    inc pwm_cnt
    mov a, pwm_cnt
    cjne a, #100, pwm_chk
    mov pwm_cnt, #0
pwm_chk:
    mov a, pwm_cnt
    clr c
    subb a, pwm_duty
    jc pwm_on
    clr P1.0
    ret
pwm_on:
    setb P1.0
    ret
END
