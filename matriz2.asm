; ============================================================
; ATmega328P + MAX7219 + MATRIZ 8x8
;
; D13 / PB5 = CLK
; D11 / PB3 = DIN
; D10 / PB2 = CS
; D12 / PB4 = BOTAO  (PB4 ---[ BOTAO ]--- GND, pull-up interno)
;
; ANIMACOES:
;   0 = CARINHA
;   1 = SETA (scroll para baixo, com espaco entre ciclos)
;   2 = PING-PONG (ainda nao implementada)
;
; REGISTRADORES:
;   r14 = contador de passos da seta
;   r15 = estado do botao (1 = liberado, 0 = ja processado)
;   r24 = animacao atual
;   r16,r17,r25 = send_command / send_byte
;   r18 = endereco, r19 = dado
;   r20,r21,r22 = delays
;   X (r26:r27), Y (r28:r29), Z (r30:r31) = ponteiros
; ============================================================


; ============================================================
; REGISTRADORES DO ATMEGA328P (enderecos de I/O)
; ============================================================

.equ PINB,  0x03
.equ DDRB,  0x04
.equ PORTB, 0x05

.equ SPL, 0x3D
.equ SPH, 0x3E


; ============================================================
; PINOS
; ============================================================

.equ CLK,   5
.equ DIN,   3
.equ CS,    2
.equ BOTAO, 4


; ============================================================
; CONFIGURACOES
; ============================================================

.equ NUM_DEV, 1

; 0 = normal
; 1 = transpoe a matriz (use se a seta aparecer deitada/torta)
.equ ORIENTACAO, 1

; Linhas vazias entre o fim de uma seta e o comeco da proxima
; (minimo 1)
.equ GAP, 4

; Tamanho total do anel de scroll
.equ TAM, 8 + GAP


; ============================================================
; SRAM (enderecos fixos, sem depender do linker)
;
; frame = anel de TAM bytes (as 8 primeiras linhas vao ao display)
; tmp   = 8 bytes (usado so quando ORIENTACAO = 1)
; ============================================================

.equ frame, 0x0200
.equ tmp,   0x0230


; ============================================================
; PROGRAMA
; ============================================================

.section .text
.global main

main:

    ; --------------------------------------------------------
    ; Stack Pointer = 0x08FF
    ; --------------------------------------------------------

    ldi r16, 0x08
    out SPH, r16
    ldi r16, 0xFF
    out SPL, r16


    ; --------------------------------------------------------
    ; Pinos do MAX7219
    ; --------------------------------------------------------

    sbi DDRB, CLK
    sbi DDRB, DIN
    sbi DDRB, CS

    cbi PORTB, CLK
    cbi PORTB, DIN
    sbi PORTB, CS


    ; --------------------------------------------------------
    ; Botao: entrada com pull-up
    ; --------------------------------------------------------

    cbi DDRB, BOTAO
    sbi PORTB, BOTAO


    ; --------------------------------------------------------
    ; Espera o MAX7219 estabilizar
    ; --------------------------------------------------------

    rcall delay


    ; --------------------------------------------------------
    ; Configura MAX7219
    ; --------------------------------------------------------

    ; Display Test OFF
    ldi r18, 0x0F
    ldi r19, 0x00
    rcall send_command

    ; Shutdown
    ldi r18, 0x0C
    ldi r19, 0x00
    rcall send_command

    ; No Decode
    ldi r18, 0x09
    ldi r19, 0x00
    rcall send_command

    ; Intensidade (0x00 = minima, 0x0F = maxima)
    ldi r18, 0x0A
    ldi r19, 0x01
    rcall send_command

    ; Scan limit: 8 linhas
    ldi r18, 0x0B
    ldi r19, 0x07
    rcall send_command


    ; --------------------------------------------------------
    ; Apaga display
    ; --------------------------------------------------------

    ldi r23, 1

apagar:
    mov r18, r23
    ldi r19, 0
    rcall send_command
    inc r23
    cpi r23, 9
    brne apagar


    ; --------------------------------------------------------
    ; Sai do shutdown
    ; --------------------------------------------------------

    ldi r18, 0x0C
    ldi r19, 0x01
    rcall send_command


    ; --------------------------------------------------------
    ; Estado inicial
    ; --------------------------------------------------------

    clr r24                     ; animacao 0 = carinha

    ldi r16, 1
    mov r15, r16                ; botao liberado


; ============================================================
; LOOP PRINCIPAL
; ============================================================

loop:

    in r16, PINB
    andi r16, (1 << BOTAO)
    breq botao_apertado

    ; Botao solto
    ldi r16, 1
    mov r15, r16
    rjmp executar_animacao


; ============================================================
; BOTAO APERTADO
; ============================================================

botao_apertado:

    ; Se r15 = 0, esse clique ja foi processado
    tst r15
    breq executar_animacao

    clr r15

    ; Debounce
    rcall delay_curto

    ; Confirma que continua apertado
    in r16, PINB
    andi r16, (1 << BOTAO)
    brne executar_animacao

    ; Troca animacao
    inc r24
    cpi r24, 3
    brne executar_animacao
    clr r24


; ============================================================
; EXECUTA ANIMACAO
; ============================================================

executar_animacao:

    tst r24
    breq animacao_carinha

    cpi r24, 1
    breq animacao_seta

    ; r24 = 2: ping-pong ainda nao implementado
    rjmp loop


; ============================================================
; CARINHA
; ============================================================

animacao_carinha:

    ldi ZL, lo8(carinha1)
    ldi ZH, hi8(carinha1)
    rcall mostrar_frame
    rcall delay

    ldi ZL, lo8(carinha2)
    ldi ZH, hi8(carinha2)
    rcall mostrar_frame
    rcall delay

    ldi ZL, lo8(carinha3)
    ldi ZH, hi8(carinha3)
    rcall mostrar_frame
    rcall delay

    rjmp loop


; ============================================================
; SETA (scroll circular para baixo, com espaco)
;
; O anel tem TAM = 8 + GAP linhas:
;
;   [ 8 linhas da seta ][ GAP linhas vazias ]
;
; Um ciclo completo = TAM passos. Ao final o anel volta a
; posicao inicial, e entre o fim de uma seta e o comeco da
; proxima sempre passam GAP linhas em branco.
; ============================================================

animacao_seta:

    rcall carregar_seta

    ldi r16, TAM
    mov r14, r16                ; r14 = contador (delay nao mexe nele)

seta_loop:

    rcall mostrar_frame_ram
    rcall delay_curto
    rcall scroll_baixo

    dec r14
    brne seta_loop

    rjmp loop


; ============================================================
; CARREGAR SETA
;
; Flash (Z) -> SRAM (X): 8 bytes da seta
; Depois zera as GAP linhas seguintes (o espaco)
; ============================================================

carregar_seta:

    ldi ZL, lo8(seta)
    ldi ZH, hi8(seta)

    ldi XL, lo8(frame)
    ldi XH, hi8(frame)

    ldi r20, 8

carregar_seta_loop:

    lpm r0, Z+
    st  X+, r0

    dec r20
    brne carregar_seta_loop

    ; Linhas vazias (espaco)
    clr r0
    ldi r20, GAP

carregar_gap_loop:

    st X+, r0

    dec r20
    brne carregar_gap_loop

    ret


; ============================================================
; SCROLL CIRCULAR PARA BAIXO (anel de TAM linhas)
;
; Antes:  A B C D ... Y Z
; Depois: Z A B C D ... Y
;
; Copia de tras para frente para nao sobrescrever dados.
; ============================================================

scroll_baixo:

    ; Guarda a ultima linha do anel (vai voltar no topo)
    lds r23, frame+TAM-1

    ldi XL, lo8(frame+TAM)
    ldi XH, hi8(frame+TAM)

    ldi YL, lo8(frame+TAM-1)
    ldi YH, hi8(frame+TAM-1)

    ldi r20, TAM-1

scroll_loop:

    ld r0, -Y
    st -X, r0

    dec r20
    brne scroll_loop

    ; Ultima linha entra no topo
    sts frame, r23

    ret


; ============================================================
; MOSTRAR FRAME DA SRAM (so as 8 primeiras linhas do anel)
; ============================================================

mostrar_frame_ram:

.if ORIENTACAO == 0

    ; --------------------------------------------------------
    ; Normal: frame[i] -> linha i+1
    ; --------------------------------------------------------

    ldi XL, lo8(frame)
    ldi XH, hi8(frame)

    ldi r23, 1

mfr_loop:

    ld r19, X+
    mov r18, r23
    rcall send_command

    inc r23
    cpi r23, 9
    brne mfr_loop

    ret

.else

    ; --------------------------------------------------------
    ; Transposto: copia 8 linhas -> tmp e monta cada linha de
    ; saida a partir de um bit de cada byte
    ; --------------------------------------------------------

    ldi XL, lo8(frame)
    ldi XH, hi8(frame)
    ldi YL, lo8(tmp)
    ldi YH, hi8(tmp)

    ldi r20, 8

mfr_copia:

    ld r0, X+
    st Y+, r0

    dec r20
    brne mfr_copia

    ldi r23, 1                  ; linha de saida

mfr_linha:

    ldi XL, lo8(tmp)
    ldi XH, hi8(tmp)

    clr r19
    ldi r20, 8

mfr_bit:

    ld  r0, X
    lsl r0                      ; bit 7 -> Carry
    st  X+, r0
    rol r19                     ; Carry -> r19
    dec r20                     ; dec nao altera o Carry
    brne mfr_bit

    mov r18, r23
    rcall send_command

    inc r23
    cpi r23, 9
    brne mfr_linha

    ret

.endif


; ============================================================
; MOSTRAR FRAME DA FLASH
;
; Z aponta para o primeiro byte do frame (8 bytes).
; ============================================================

mostrar_frame:

    ldi r22, 1

mostrar_linha:

    lpm r19, Z+
    mov r18, r22
    rcall send_command

    inc r22
    cpi r22, 9
    brne mostrar_linha

    ret


; ============================================================
; SEND COMMAND
;
; r18 = endereco
; r19 = dado
; ============================================================

send_command:

    cbi PORTB, CS

    ldi r25, NUM_DEV

send_cmd_loop:

    mov r16, r18
    rcall send_byte

    mov r16, r19
    rcall send_byte

    dec r25
    brne send_cmd_loop

    sbi PORTB, CS

    ret


; ============================================================
; SEND BYTE (MSB primeiro)
; ============================================================

send_byte:

    ldi r17, 8

send_loop:

    lsl r16
    brcs bit_one

    cbi PORTB, DIN
    rjmp clock

bit_one:

    sbi PORTB, DIN

clock:

    nop
    nop
    sbi PORTB, CLK
    nop
    nop
    nop
    nop
    cbi PORTB, CLK
    nop
    nop

    dec r17
    brne send_loop

    ret


; ============================================================
; DELAY PRINCIPAL
; ============================================================

delay:

    ldi r20, 30

delay_outer:

    ldi r21, 255

delay_middle:

    ldi r22, 255

delay_inner:

    dec r22
    brne delay_inner

    dec r21
    brne delay_middle

    dec r20
    brne delay_outer

    ret


; ============================================================
; DELAY CURTO (debounce e velocidade da seta)
;
; Para a seta mais rapida, diminua o 12.
; Para mais lenta, aumente.
; ============================================================

delay_curto:

    ldi r20,13

dc1:

    ldi r21, 255

dc2:

    ldi r22, 255

dc3:

    dec r22
    brne dc3

    dec r21
    brne dc2

    dec r20
    brne dc1

    ret


; ============================================================
; TABELAS DE ANIMACAO
; ============================================================

carinha1:
    .byte 0b01111110
    .byte 0b10000001
    .byte 0b10100101
    .byte 0b10000001
    .byte 0b10000001
    .byte 0b10100101
    .byte 0b10011001
    .byte 0b01111110

carinha2:
    .byte 0b01111110
    .byte 0b10000001
    .byte 0b10000001
    .byte 0b10000001
    .byte 0b10000001
    .byte 0b10100101
    .byte 0b10011001
    .byte 0b01111110

carinha3:
    .byte 0b01111110
    .byte 0b10000001
    .byte 0b10100101
    .byte 0b10000001
    .byte 0b10000001
    .byte 0b10011001
    .byte 0b10100101
    .byte 0b01111110

; SETA PARA BAIXO
;
;   00011000
;   00011000
;   00011000
;   00011000
;   11111111
;   01111110
;   00111100
;   00011000

seta:
    .byte 0b00011000
    .byte 0b00011000
    .byte 0b00011000
    .byte 0b00011000
    .byte 0b11111111
    .byte 0b01111110
    .byte 0b00111100
    .byte 0b00011000
