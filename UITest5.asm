;===========================================================
; CV8052 / 8052 UART Telemetry Demo (Part e)
; - UART: 115200 8N1 using Timer2 as baud generator
; - Timer0: 1ms interrupt tick, set tx_flag every 1000ms
; - Main: every second send "sec,temp\r\n"
;
; TODO later:
;  1) Replace dummy_temp with real oven temperature variable
;  2) If UART baud wrong, only adjust RCAP2H/RCAP2L (and maybe SMOD)
;===========================================================

$MODMAX10            

;----------------------------
; Reset vector
;----------------------------
CSEG at 0000h
    ljmp  start

;----------------------------
; Timer0 Interrupt Vector
;----------------------------
CSEG at 000Bh
    ljmp  isr_timer0

;----------------------------
; Constants 
;----------------------------
FREQ   EQU 33333333          ; 先按 33.333333 MHz (你之前工程常见值)  —— 后面知道了再改
BAUD   EQU 115200
; Timer2 reload for baud (SMOD=0): RCAP2 = 65536 - (FREQ/(32*BAUD))
T2LOAD EQU 65536-(FREQ/(32*BAUD))

;----------------------------
; RAM variables
;----------------------------
dseg at 30h
ms_cnt_L:  ds 1              ; 16-bit millisecond counter (0..999)
ms_cnt_H:  ds 1
sec_L:     ds 1              ; seconds counter (16-bit optional)
sec_H:     ds 1
dummy_temp: ds 1             ; fake temp (25..)

bseg
tx_flag:   dbit 1


;===========================================================
; Start
;===========================================================
CSEG
start:
    ; Init variables
    mov  ms_cnt_L, #00h
    mov  ms_cnt_H, #00h
    mov  sec_L,    #00h
    mov  sec_H,    #00h
    mov  dummy_temp, #25
    clr  tx_flag

    ; Init UART + timers
    lcall InitSerialPort_T2
    lcall InitTimer0_1ms

    ; Enable interrupts
    setb EA

main_loop:
    ; If 1-second flag set, send telemetry line
    jnb  tx_flag, main_loop
    clr  tx_flag

    ; Build and send: sec,temp\r\n
    ; Send sec (16-bit decimal)
    mov  A, sec_L
    mov  R0, A
    mov  A, sec_H
    mov  R1, A
    lcall UART_SendU16Dec      ; prints R1:R0

    mov  A, #','
    lcall UART_SendChar

    ; Send dummy temp (8-bit decimal)
    mov  A, dummy_temp
    mov  R0, A
    lcall UART_SendU8Dec       ; prints R0

    ; CRLF
    mov  A, #0Dh
    lcall UART_SendChar
    mov  A, #0Ah
    lcall UART_SendChar

    ; Update dummy values
    ; sec++
    inc  sec_L
    mov  A, sec_L
    jnz  sec_ok
    inc  sec_H
sec_ok:
    ; temp cycles 25..250 (just for demo)
    inc  dummy_temp
    mov  A, dummy_temp
    cjne A, #251, main_loop
    mov  dummy_temp, #25
    sjmp main_loop

;===========================================================
; UART init using Timer2 baud generator (8052)
;===========================================================
InitSerialPort_T2:
    ; Serial mode 1, REN=1
    mov  SCON, #50h           ; 0101 0000b: SM0=0 SM1=1 REN=1

    ; Timer2 as baud rate generator for both Rx/Tx
    clr  TR2
    mov  T2CON, #30h          ; RCLK=1 TCLK=1 (others 0)
    mov  RCAP2H, #HIGH(T2LOAD)
    mov  RCAP2L, #LOW(T2LOAD)
    mov  TH2,    #HIGH(T2LOAD)
    mov  TL2,    #LOW(T2LOAD)
    setb TR2

    ; Clear TI/RI
    clr  TI
    clr  RI
    ret

;===========================================================
; Timer0 init for ~1ms tick (interrupt)
; IMPORTANT: Needs correct FREQ. We'll GUESS now.
; We'll use mode 1 (16-bit), reload each ISR.
;
; For 33.333333MHz 8051 core: machine cycle maybe FREQ/12 if classic.
; If CV8052 uses different divider, tick will be off; that's OK for demo.
; We'll set a placeholder reload and you adjust later if needed.
;===========================================================
InitTimer0_1ms:
    ; Timer0 mode 1 (16-bit)
    anl  TMOD, #0F0h
    orl  TMOD, #01h

    ; --- Placeholder reload for ~1ms ---
    ; Classic 8051: ticks at FREQ/12
    ; counts per ms = FREQ/12/1000
    ; reload = 65536 - counts_per_ms
    ;
    ; With FREQ=33,333,333 => counts/ms ~ 2777.78 => reload ~ 62758 = 0xF516
    mov  TH0, #0F5h
    mov  TL0, #016h

    ; Enable Timer0 interrupt and start
    setb ET0
    setb TR0
    ret

;===========================================================
; Timer0 ISR: every ~1ms increment ms counter; at 1000ms set tx_flag
;===========================================================
isr_timer0:
    push ACC
    push PSW

    ; reload Timer0
    mov  TH0, #0F5h
    mov  TL0, #016h

    ; ms_count++
    inc  ms_cnt_L
    mov  A, ms_cnt_L
    jnz  ms_check
    inc  ms_cnt_H

ms_check:
    ; if ms == 1000 -> set flag and clear
    ; 1000 decimal = 03E8h
    mov  A, ms_cnt_L
    cjne A, #0E8h, isr_exit_checkH
    mov  A, ms_cnt_H
    cjne A, #03h,  isr_exit
    ; match 1000
    mov  ms_cnt_L, #00h
    mov  ms_cnt_H, #00h
    setb tx_flag

isr_exit_checkH:
    ; not equal, nothing
isr_exit:
    pop  PSW
    pop  ACC
    reti

;===========================================================
; UART_SendChar: send char in A
;===========================================================
UART_SendChar:
    mov  SBUF, A
wait_TI:
    jnb  TI, wait_TI
    clr  TI
    ret

;===========================================================
; UART_SendU8Dec: print unsigned 8-bit in R0 (0..255)
; Simple division by 10 (uses 8051 DIV AB)
;===========================================================
UART_SendU8Dec:
    ; if R0 == 0 -> print '0'
    mov  A, R0
    jnz  u8_nonzero
    mov  A, #'0'
    lcall UART_SendChar
    ret

u8_nonzero:
    ; Convert to decimal digits by repeated div10, store remainders in stack-ish R registers
    ; We'll use R2,R3,R4 as digit buffer (max 3 digits)
    mov  R2, #00h
    mov  R3, #00h
    mov  R4, #00h

    ; A = value
    mov  A, R0
    mov  B, #10
    div  AB              ; A=quotient, B=remainder
    mov  R4, B           ; ones
    mov  R0, A           ; quotient

    mov  A, R0
    jz   u8_print2       ; only 1 digit

    mov  B, #10
    div  AB
    mov  R3, B           ; tens
    mov  R2, A           ; hundreds (0..2)

u8_print3:
    ; if hundreds != 0 print it
    mov  A, R2
    jz   u8_print_tens
    add  A, #'0'
    lcall UART_SendChar

u8_print_tens:
    ; if hundreds==0 and tens==0, skip tens (avoid leading zero)
    mov  A, R3
    jnz  u8_tens_yes
    mov  A, R2
    jnz  u8_tens_yes
    sjmp u8_print_ones

u8_tens_yes:
    mov  A, R3
    add  A, #'0'
    lcall UART_SendChar

u8_print_ones:
    mov  A, R4
    add  A, #'0'
    lcall UART_SendChar
    ret

u8_print2:
    ; only ones digit in R4
    mov  A, R4
    add  A, #'0'
    lcall UART_SendChar
    ret

;===========================================================
; UART_SendU16Dec: print unsigned 16-bit in R1:R0
; (Simple but not super fast) repeated subtraction by 10000/1000/100/10
; Works fine at 1Hz.
;===========================================================
UART_SendU16Dec:
    ; We'll print without leading zeros.
    ; Use R2..R7 as workspace.
    ; Value in R1:R0 (hi:lo)

    mov  R2, #0          ; printed_flag = 0

    ; print digit for 10000s
    lcall u16_digit_10000
    ; 1000s
    lcall u16_digit_1000
    ; 100s
    lcall u16_digit_100
    ; 10s
    lcall u16_digit_10
    ; 1s
    lcall u16_digit_1
    ret

; Each helper computes one digit by repeated subtracting constant,
; leaves remainder in R1:R0, prints digit if needed.

u16_digit_10000:
    ; constant 10000 = 2710h
    mov  R3, #0          ; digit
u16_10000_loop:
    ; if R1:R0 < 2710h -> done
    mov  A, R1
    clr  C
    subb A, #027h
    mov  A, R0
    subb A, #010h
    jc   u16_10000_done

    ; subtract 2710h
    mov  A, R0
    clr  C
    subb A, #010h
    mov  R0, A
    mov  A, R1
    subb A, #027h
    mov  R1, A

    inc  R3
    sjmp u16_10000_loop

u16_10000_done:
    mov  A, R3
    lcall u16_print_digit
    ret

u16_digit_1000:
    ; constant 1000 = 03E8h
    mov  R3, #0
u16_1000_loop:
    mov  A, R1
    clr  C
    subb A, #003h
    mov  A, R0
    subb A, #0E8h
    jc   u16_1000_done

    mov  A, R0
    clr  C
    subb A, #0E8h
    mov  R0, A
    mov  A, R1
    subb A, #003h
    mov  R1, A

    inc  R3
    sjmp u16_1000_loop

u16_1000_done:
    mov  A, R3
    lcall u16_print_digit
    ret

u16_digit_100:
    ; constant 100 = 0064h
    mov  R3, #0
u16_100_loop:
    mov  A, R1
    clr  C
    subb A, #000h
    mov  A, R0
    subb A, #064h
    jc   u16_100_done

    mov  A, R0
    clr  C
    subb A, #064h
    mov  R0, A
    ; R1 unchanged
    inc  R3
    sjmp u16_100_loop

u16_100_done:
    mov  A, R3
    lcall u16_print_digit
    ret

u16_digit_10:
    ; constant 10 = 000Ah
    mov  R3, #0
u16_10_loop:
    mov  A, R1
    jnz  u16_10_sub        ; if high byte nonzero, definitely >=10
    mov  A, R0
    clr  C
    subb A, #0Ah
    jc   u16_10_done
u16_10_sub:
    mov  A, R0
    clr  C
    subb A, #0Ah
    mov  R0, A
    mov  A, R1
    subb A, #00h
    mov  R1, A
    inc  R3
    sjmp u16_10_loop

u16_10_done:
    mov  A, R3
    lcall u16_print_digit
    ret

u16_digit_1:
    ; remaining value is 0..9 in R0 (R1 should be 0)
    mov  A, R0
    ; always print last digit (even if leading)
    add  A, #'0'
    lcall UART_SendChar
    ret

u16_print_digit:
    ; A = digit 0..9
    ; R2 = printed_flag (0/1)
    ; Print digit if printed_flag already set OR digit != 0
    jnz  u16_pd_print
    mov  A, R2
    jnz  u16_pd_print
    ret

u16_pd_print:
    ; mark printed_flag
    mov  R2, #1
    add  A, #'0'
    lcall UART_SendChar
    ret
