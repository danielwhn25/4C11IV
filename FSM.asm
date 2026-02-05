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

CSEG
main:
    mov SP, #60h
    clr KEY.1
    mov P1MOD, #01h
    clr P1.0
    mov LEDRA, #00h

    mov temp_soak,   #50
    mov time_soak,   #20
    mov temp_reflow, #80
    mov time_reflow, #15

    mov fsm_state, #0
    mov seconds,   #0
    mov pwm_duty,  #0
    mov pwm_cnt,   #0

    mov TMOD, #01h
    mov TH0, #0B0h
    mov TL0, #00h
    setb TR0

main_loop:
    lcall Update_Seconds
    lcall Read_Temperature
    lcall FSM_Reflow
    mov LEDRA, fsm_state
    lcall PWM_Update
    sjmp main_loop

Abort_Check:
    mov a, fsm_state
    jz abort_done
    mov a, seconds
    clr c
    subb a, #60
    jc abort_done
    mov a, temp_current
    clr c
    subb a, #50
    jnc abort_done
    mov pwm_duty, #0
    mov fsm_state, #0
abort_done:
    ret

FSM_Reflow:
    lcall Abort_Check
    mov a, fsm_state

FSM_STATE_0:
    cjne a, #0, FSM_STATE_1
    mov pwm_duty, #0
    jb  KEY.1, idle_done
    jnb KEY.1, $
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
    mov a, #30
    clr c
    subb a, temp_current
    jc cooling_done
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
    inc seconds
us_done:
    ret

Read_Temperature:
    mov ADC_C, #080h
    nop
    nop
    mov ADC_C, #000h
adc_wait:
    mov a, ADC_C
    jb acc.7, adc_wait
    mov a, ADC_H
    mov temp_current, a
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
