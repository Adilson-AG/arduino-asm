.equ PINB,  0x03
.equ DDRB,  0x04
.equ PORTB, 0x05

.section .text

.org 0x0000
    rjmp reset

reset:
    ; PB5 como saída
    sbi DDRB, 5

    ; PB4 como entrada
    cbi DDRB, 4

    ; habilita pull-up interno em PB4
    sbi PORTB, 4

loop:

    ; se PB4 = 1, execute a instrução
    sbic PINB, 4
    rjmp led_off

    sbi PORTB, 5
    rjmp loop

led_off:
    cbi PORTB, 5
    rjmp loop
