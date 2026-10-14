; ============================================================
; ATmega328P + MAX7219 + MATRIZ 8x8
; MONITOR EXTERNO PARA PC - ICONES ANIMADOS + NUMEROS
;
; Arduino Uno (16 MHz)
;
; CONEXOES DO MAX7219:
;   D13 / PB5 = CLK
;   D11 / PB3 = DIN
;   D10 / PB2 = CS
;
; COMUNICACAO SERIAL (PC -> Arduino):
;   D0  / PD0 = RX  9600 baud 8N1 via cabo USB
;   D1  / PD1 = TX
;
; PROTOCOLO SERIAL (6 bytes enviados pelo pc_monitor.py):
;   [0xFF] [0x55] [CPU%] [RAM%] [TEMP] [DISCO%]
;   (valores de 0 a 100; nunca envie 0xFF como dado)
;
; CICLO VISUAL POR METRICA (CPU, RAM, TEMP, DISCO):
;   1. ICONE animado em 2 frames piscando
;   2. SCROLL para cima suave (anel de 16 linhas)
;   3. NUMERO de 2 digitos 3x5 estavel
;
; SCROLL: anel de 16 bytes
;   scroll_anel[0..7]  = icone (sai pela cima)
;   scroll_anel[8..15] = numero (entra por baixo)
;
; CORRECOES NESTA VERSAO:
;   1. send_command agora preserva r25 (antes zerava o contador
;      de passos do scroll e o loop ficava infinito).
;   2. delay_serial le a serial dentro do laco interno
;      (antes so lia a cada ~12 ms e perdia bytes por overrun).
;   3. .balign 2 antes das tabelas na Flash.
;
; COMPILAR (exemplo):
;   avr-gcc -mmcu=atmega328p -x assembler-with-cpp -o monitor.elf monitor_pc_matrix.S
;   avr-objcopy -O ihex monitor.elf monitor.hex
;   (use o crt padrao: NAO use -nostartfiles)
; ============================================================


; ============================================================
; REGISTRADORES DE I/O DO ATMEGA328P
; ============================================================

.equ PINB,   0x03
.equ DDRB,   0x04
.equ PORTB,  0x05

.equ SPL,    0x3D
.equ SPH,    0x3E

; USART0
.equ UCSR0A, 0xC0
.equ UCSR0B, 0xC1
.equ UCSR0C, 0xC2
.equ UBRR0L, 0xC4
.equ UBRR0H, 0xC5
.equ UDR0,   0xC6


; ============================================================
; PINOS
; ============================================================

.equ CLK,   5       ; PB5 = Arduino D13
.equ DIN,   3       ; PB3 = Arduino D11
.equ CS,    2       ; PB2 = Arduino D10

.equ NUM_DEV, 1

; Baud rate 9600 @ 16 MHz : UBRR = 103
.equ UBRR_VAL, 103

; Tempos de exibicao (cada 'tick' = ~12.2 ms):
.equ TEMPO_ICONE,   30   ; ~0.37s por frame do icone
.equ TEMPO_NUMERO,  190  ; ~2.3s mostrando o numero

; Velocidade do scroll: delay por passo (ticks de ~12.2 ms)
.equ SCROLL_DELAY,  2


; ============================================================
; MAPA DE SRAM (enderecos fixos)
; ============================================================

.equ frame,        0x0200   ; 8 bytes: frame visivel atual
.equ scroll_anel,  0x0210   ; 16 bytes: anel de scroll
.equ val_cpu,      0x0220
.equ val_ram,      0x0221
.equ val_temp,     0x0222
.equ val_disk,     0x0223
.equ rx_state,     0x0224
.equ pc_connected, 0x0225
.equ tela_atual,   0x0226


; ============================================================
; CODIGO PRINCIPAL
; ============================================================

.section .text
.global main

main:

    ; --- 1. Stack Pointer ---
    ldi r16, 0x08
    out SPH, r16
    ldi r16, 0xFF
    out SPL, r16

    ; --- 2. Pinos MAX7219 ---
    sbi DDRB, CLK
    sbi DDRB, DIN
    sbi DDRB, CS

    cbi PORTB, CLK
    cbi PORTB, DIN
    sbi PORTB, CS

    ; --- 3. Valores demo ---
    ldi r16, 42
    sts val_cpu, r16
    ldi r16, 68
    sts val_ram, r16
    ldi r16, 52
    sts val_temp, r16
    ldi r16, 79
    sts val_disk, r16

    clr r16
    sts rx_state, r16
    sts pc_connected, r16
    sts tela_atual, r16

    ; --- 4. USART 9600 baud ---
    ldi r16, hi8(UBRR_VAL)
    sts UBRR0H, r16
    ldi r16, lo8(UBRR_VAL)
    sts UBRR0L, r16
    ldi r16, (1 << 4) | (1 << 3)    ; RXEN0 | TXEN0
    sts UCSR0B, r16
    ldi r16, (1 << 2) | (1 << 1)    ; 8 bits
    sts UCSR0C, r16

    ; --- 5. MAX7219 init ---
    rcall delay_estabilizar

    ldi r18, 0x0F
    ldi r19, 0x00
    rcall send_command          ; Teste OFF

    ldi r18, 0x0C
    ldi r19, 0x00
    rcall send_command          ; Shutdown para configurar

    ldi r18, 0x09
    ldi r19, 0x00
    rcall send_command          ; Sem decode BCD

    ldi r18, 0x0A
    ldi r19, 0x06
    rcall send_command          ; Intensidade

    ldi r18, 0x0B
    ldi r19, 0x07
    rcall send_command          ; Scan Limit (8 linhas)

    rcall apagar_display

    ldi r18, 0x0C
    ldi r19, 0x01
    rcall send_command          ; Modo Normal

    ; --- 6. Boas-vindas pela Serial ---
    ldi ZL, lo8(msg_inicio)
    ldi ZH, hi8(msg_inicio)
    rcall serial_envia_string


; ============================================================
; LOOP PRINCIPAL
; ============================================================

loop:

    rcall simular_demo          ; Oscila valores se o PC nao conectou

    ; ---------------------------------------------------------
    ; FASE 1: ICONE ANIMADO (2 frames piscando, 2 ciclos)
    ; ---------------------------------------------------------

    rcall carregar_icone_a_em_frame
    rcall mostrar_frame
    ldi r24, TEMPO_ICONE
    rcall delay_serial

    rcall carregar_icone_b_em_frame
    rcall mostrar_frame
    ldi r24, TEMPO_ICONE
    rcall delay_serial

    rcall carregar_icone_a_em_frame
    rcall mostrar_frame
    ldi r24, TEMPO_ICONE
    rcall delay_serial

    rcall carregar_icone_b_em_frame
    rcall mostrar_frame
    ldi r24, TEMPO_ICONE
    rcall delay_serial

    ; ---------------------------------------------------------
    ; FASE 2: PREPARA O ANEL DE SCROLL
    ; ---------------------------------------------------------

    rcall copiar_frame_para_anel_saida
    rcall desenhar_numero_na_entrada_do_anel

    ; ---------------------------------------------------------
    ; FASE 3: SCROLL PARA CIMA
    ; ---------------------------------------------------------

    rcall scroll_para_cima

    ; ---------------------------------------------------------
    ; FASE 4: NUMERO ESTAVEL NA TELA
    ; ---------------------------------------------------------

    ldi r24, TEMPO_NUMERO
    rcall delay_serial

    ; ---------------------------------------------------------
    ; Proxima metrica
    ; ---------------------------------------------------------

    lds r16, tela_atual
    inc r16
    cpi r16, 4
    brne loop_salva
    clr r16
loop_salva:
    sts tela_atual, r16
    rjmp loop


; ============================================================
; SCROLL PARA CIMA (9 passos: 0..8)
;
; A cada passo: janela visivel = scroll_anel[passo..passo+7]
; Usa r25 como contador de passo (send_command preserva r25).
; ============================================================

scroll_para_cima:

    clr r25                 ; passo = 0

scroll_passo:

    ; X = scroll_anel + passo
    ldi XL, lo8(scroll_anel)
    ldi XH, hi8(scroll_anel)
    add XL, r25
    brcc scroll_sem_carry
    inc XH
scroll_sem_carry:

    ; Envia as 8 linhas deste passo
    ldi YL, lo8(frame)
    ldi YH, hi8(frame)
    ldi r23, 1

scroll_envia_linha:
    ld r19, X+
    st Y+, r19              ; frame guarda o ultimo estado
    mov r18, r23
    rcall send_command
    inc r23
    cpi r23, 9
    brne scroll_envia_linha

    ; Delay entre passos (le a serial enquanto espera)
    ldi r24, SCROLL_DELAY
    rcall delay_serial

    inc r25
    cpi r25, 9
    brne scroll_passo

    ret


; ============================================================
; COPIAR FRAME -> SCROLL_ANEL[0..7]
; ============================================================

copiar_frame_para_anel_saida:

    ldi XL, lo8(frame)
    ldi XH, hi8(frame)
    ldi YL, lo8(scroll_anel)
    ldi YH, hi8(scroll_anel)
    ldi r20, 8

cfas_loop:
    ld r16, X+
    st Y+, r16
    dec r20
    brne cfas_loop
    ret


; ============================================================
; CARREGAR ICONE A/B NO FRAME
; ============================================================

carregar_icone_a_em_frame:
    rcall apontar_icone_a
    rjmp flash_para_frame

carregar_icone_b_em_frame:
    rcall apontar_icone_b

flash_para_frame:
    ; Z aponta para o icone na Flash; copia 8 bytes -> frame
    ldi XL, lo8(frame)
    ldi XH, hi8(frame)
    ldi r20, 8
ftf_loop:
    lpm r16, Z+
    st X+, r16
    dec r20
    brne ftf_loop
    ret


; ============================================================
; APONTAR Z PARA O ICONE A/B DA METRICA ATUAL
; ============================================================

apontar_icone_a:

    lds r25, tela_atual
    cpi r25, 0
    breq aica_cpu
    cpi r25, 1
    breq aica_ram
    cpi r25, 2
    breq aica_temp
    ldi ZL, lo8(disk_frame_a)
    ldi ZH, hi8(disk_frame_a)
    ret
aica_cpu:
    ldi ZL, lo8(cpu_frame_a)
    ldi ZH, hi8(cpu_frame_a)
    ret
aica_ram:
    ldi ZL, lo8(ram_frame_a)
    ldi ZH, hi8(ram_frame_a)
    ret
aica_temp:
    ldi ZL, lo8(temp_frame_a)
    ldi ZH, hi8(temp_frame_a)
    ret


apontar_icone_b:

    lds r25, tela_atual
    cpi r25, 0
    breq aicb_cpu
    cpi r25, 1
    breq aicb_ram
    cpi r25, 2
    breq aicb_temp
    ldi ZL, lo8(disk_frame_b)
    ldi ZH, hi8(disk_frame_b)
    ret
aicb_cpu:
    ldi ZL, lo8(cpu_frame_b)
    ldi ZH, hi8(cpu_frame_b)
    ret
aicb_ram:
    ldi ZL, lo8(ram_frame_b)
    ldi ZH, hi8(ram_frame_b)
    ret
aicb_temp:
    ldi ZL, lo8(temp_frame_b)
    ldi ZH, hi8(temp_frame_b)
    ret


; ============================================================
; DESENHAR NUMERO (2 DIGITOS 3x5) EM SCROLL_ANEL[8..15]
;
; Layout no display 8x8:
;   Linha 0   : ponto indicador da metrica
;   Linhas 1-5: dois digitos de 3 colunas, 1 coluna de espaco
;   Linhas 6-7: vazias
;
; Colunas (linhas 1-5):
;   bit7 bit6 bit5 | bit4 | bit3 bit2 bit1 | bit0
;     dezena       | sep  |    unidade     | livre
; ============================================================

desenhar_numero_na_entrada_do_anel:

    ; 1. Valor da metrica atual
    lds r25, tela_atual
    cpi r25, 0
    breq dna_cpu
    cpi r25, 1
    breq dna_ram
    cpi r25, 2
    breq dna_temp
    lds r16, val_disk
    rjmp dna_monta

dna_cpu:
    lds r16, val_cpu
    rjmp dna_monta

dna_ram:
    lds r16, val_ram
    rjmp dna_monta

dna_temp:
    lds r16, val_temp

dna_monta:

    ; Limita a 99
    cpi r16, 100
    brcs dna_ok
    ldi r16, 99
dna_ok:

    ; r17 = dezenas, r16 = unidades
    rcall div10
    mov r14, r17            ; r14 = dezena
    mov r15, r16            ; r15 = unidade

    ; 2. Zera scroll_anel[8..15]
    ldi XL, lo8(scroll_anel + 8)
    ldi XH, hi8(scroll_anel + 8)
    ldi r20, 8
    clr r16
dna_zera:
    st X+, r16
    dec r20
    brne dna_zera



    ; 4. Z = font_digits + dezena*5
    ldi ZL, lo8(font_digits)
    ldi ZH, hi8(font_digits)
    mov r18, r14
    lsl r18
    lsl r18
    add r18, r14
    add ZL, r18
    brcc dna_z_ok
    inc ZH
dna_z_ok:

    ; 5. Y = font_digits + unidade*5
    ldi YL, lo8(font_digits)
    ldi YH, hi8(font_digits)
    mov r18, r15
    lsl r18
    lsl r18
    add r18, r15
    add YL, r18
    brcc dna_y_ok
    inc YH
dna_y_ok:

    ; 6. Linhas 1..5 (scroll_anel[9..13])
    movw r12, YL            ; r12:r13 = ponteiro das unidades

    ldi XL, lo8(scroll_anel + 9)
    ldi XH, hi8(scroll_anel + 9)
    ldi r20, 5

dna_linha:

    ; Dezena (via Z) -> bits 7..5
    lpm r16, Z+
    lsl r16
    lsl r16
    lsl r16
    lsl r16
    lsl r16

    ; Unidade: troca Z temporariamente
    push ZL
    push ZH
    movw ZL, r12
    lpm r17, Z+
    movw r12, ZL
    pop ZH
    pop ZL

    lsl r17                 ; bits 3..1

    or r16, r17
    st X+, r16

    dec r20
    brne dna_linha

    ret


; ============================================================
; DIVISAO POR 10
; Entrada: r16 = 0..99 | Saida: r17 = dezenas, r16 = unidades
; ============================================================

div10:

    clr r17

div10_loop:
    cpi r16, 10
    brcs div10_fim
    subi r16, 10
    inc r17
    rjmp div10_loop

div10_fim:
    ret


; ============================================================
; MOSTRAR FRAME
; ============================================================

mostrar_frame:

    ldi XL, lo8(frame)
    ldi XH, hi8(frame)
    ldi r23, 1

mf_loop:
    ld r19, X+
    mov r18, r23
    rcall send_command
    inc r23
    cpi r23, 9
    brne mf_loop
    ret


; ============================================================
; APAGAR DISPLAY
; ============================================================

apagar_display:

    ldi r23, 1

ad_loop:
    mov r18, r23
    ldi r19, 0
    rcall send_command
    inc r23
    cpi r23, 9
    brne ad_loop
    ret


; ============================================================
; DELAY COM LEITURA SERIAL  (CORRIGIDO)
; Entrada: r24 = ciclos de ~12.2 ms
; A serial e drenada a cada ~50 us (dentro do laco ds_mid).
; ============================================================

delay_serial:

    tst r24
    breq ds_fim

ds_outer:
    ldi r21, 255
ds_mid:
    rcall ler_serial        ; <<< leitura frequente
    ldi r22, 255
ds_in:
    dec r22
    brne ds_in
    dec r21
    brne ds_mid

    dec r24
    brne ds_outer

ds_fim:
    ret


; ============================================================
; LER SERIAL (drena buffer de recepcao)
; ============================================================

ler_serial:

    lds r16, UCSR0A
    sbrs r16, 7             ; RXC0
    ret

    lds r16, UDR0
    rcall parse_serial
    rjmp ler_serial


; ============================================================
; PARSER DO PACOTE [0xFF][0x55][CPU][RAM][TEMP][DISCO]
; ============================================================

parse_serial:

    push r17
    push r18

    lds r17, rx_state

    cpi r17, 0
    breq ps_ff
    cpi r17, 1
    breq ps_55
    cpi r17, 2
    breq ps_cpu
    cpi r17, 3
    breq ps_ram
    cpi r17, 4
    breq ps_temp
    cpi r17, 5
    breq ps_disk
    clr r17
    sts rx_state, r17
    rjmp ps_ret

ps_ff:
    cpi r16, 0xFF
    brne ps_ret
    ldi r17, 1
    sts rx_state, r17
    rjmp ps_ret

ps_55:
    cpi r16, 0x55
    breq ps_sinc
    cpi r16, 0xFF
    breq ps_ret             ; continua esperando o 0x55
    clr r17
    sts rx_state, r17
    rjmp ps_ret

ps_sinc:
    ldi r17, 2
    sts rx_state, r17
    rjmp ps_ret

ps_cpu:
    cpi r16, 101
    brcs ps_cpu_ok
    ldi r16, 100
ps_cpu_ok:
    sts val_cpu, r16
    ldi r17, 3
    sts rx_state, r17
    rjmp ps_ret

ps_ram:
    cpi r16, 101
    brcs ps_ram_ok
    ldi r16, 100
ps_ram_ok:
    sts val_ram, r16
    ldi r17, 4
    sts rx_state, r17
    rjmp ps_ret

ps_temp:
    cpi r16, 101
    brcs ps_temp_ok
    ldi r16, 100
ps_temp_ok:
    sts val_temp, r16
    ldi r17, 5
    sts rx_state, r17
    rjmp ps_ret

ps_disk:
    cpi r16, 101
    brcs ps_disk_ok
    ldi r16, 100
ps_disk_ok:
    sts val_disk, r16
    ldi r18, 1
    sts pc_connected, r18
    clr r17
    sts rx_state, r17

ps_ret:
    pop r18
    pop r17
    ret


; ============================================================
; DEMO: OSCILA VALORES ENQUANTO O PC NAO ENVIOU DADOS
; ============================================================

simular_demo:

    lds r16, pc_connected
    tst r16
    brne sd_fim

    lds r16, val_cpu
    subi r16, -14
    cpi r16, 99
    brcs sd_c_ok
    ldi r16, 25
sd_c_ok:
    sts val_cpu, r16

    lds r16, val_ram
    subi r16, -6
    cpi r16, 95
    brcs sd_r_ok
    ldi r16, 42
sd_r_ok:
    sts val_ram, r16

    lds r16, val_temp
    subi r16, -4
    cpi r16, 86
    brcs sd_t_ok
    ldi r16, 39
sd_t_ok:
    sts val_temp, r16

    lds r16, val_disk
    subi r16, -3
    cpi r16, 92
    brcs sd_d_ok
    ldi r16, 65
sd_d_ok:
    sts val_disk, r16

sd_fim:
    ret


; ============================================================
; ENVIO DE COMANDO AO MAX7219  (CORRIGIDO: preserva r25)
; r18 = registrador | r19 = dado
; ============================================================

send_command:

    push r25                ; <<< preserva o contador do scroll
    cbi PORTB, CS
    ldi r25, NUM_DEV

sc_loop:
    mov r16, r18
    rcall send_byte
    mov r16, r19
    rcall send_byte
    dec r25
    brne sc_loop

    sbi PORTB, CS
    pop r25                 ; <<< restaura
    ret


; ============================================================
; ENVIO DE BYTE SPI BIT-BANG
; ============================================================

send_byte:

    ldi r17, 8

sb_loop:
    lsl r16
    brcs sb_bit1
    cbi PORTB, DIN
    rjmp sb_clk

sb_bit1:
    sbi PORTB, DIN

sb_clk:
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
    brne sb_loop
    ret


; ============================================================
; SERIAL TX
; ============================================================

serial_envia_char:

    lds r17, UCSR0A
    sbrs r17, 5             ; UDRE0
    rjmp serial_envia_char
    sts UDR0, r16
    ret

serial_envia_string:

    lpm r16, Z+
    tst r16
    breq ses_fim
    rcall serial_envia_char
    rjmp serial_envia_string

ses_fim:
    ret


; ============================================================
; DELAY DE ESTABILIZACAO INICIAL (~350 ms)
; ============================================================

delay_estabilizar:

    ldi r20, 30
de1:
    ldi r21, 255
de2:
    ldi r22, 255
de3:
    dec r22
    brne de3
    dec r21
    brne de2
    dec r20
    brne de1
    ret


; ============================================================
; TABELAS E FONTES NA FLASH
; ============================================================

msg_inicio:
    .string "MONITOR PC MATRIX 8X8 (9600 BAUD)\r\n"

    .balign 2


; ------------------------------------------------------------
; ICONES ANIMADOS - 2 frames por metrica (8 bytes cada)
; ------------------------------------------------------------

; CPU
cpu_frame_a:
    .byte 0b01010100
    .byte 0b11111110
    .byte 0b10000010
    .byte 0b10111010
    .byte 0b10111010
    .byte 0b10000010
    .byte 0b11111110
    .byte 0b01010100

cpu_frame_b:
    .byte 0b00101010
    .byte 0b11111110
    .byte 0b10101010
    .byte 0b10010010
    .byte 0b10010010
    .byte 0b10101010
    .byte 0b11111110
    .byte 0b00101010

; RAM
ram_frame_a:
    .byte 0b00000000
    .byte 0b11111111
    .byte 0b10101011
    .byte 0b10101011
    .byte 0b10101011
    .byte 0b11111111
    .byte 0b01010100
    .byte 0b00000000

ram_frame_b:
    .byte 0b00000000
    .byte 0b11111111
    .byte 0b11010101
    .byte 0b11010101
    .byte 0b11010101
    .byte 0b11111111
    .byte 0b01010100
    .byte 0b00000000

; TEMP
temp_frame_a:
    .byte 0b00111000
    .byte 0b00101000
    .byte 0b00101000
    .byte 0b00111000
    .byte 0b01111100
    .byte 0b01111100
    .byte 0b00111000
    .byte 0b00000000

temp_frame_b:
    .byte 0b00111000
    .byte 0b00100000
    .byte 0b00100000
    .byte 0b00111000
    .byte 0b01111100
    .byte 0b01111100
    .byte 0b00111000
    .byte 0b00000000

; DISCO
disk_frame_a:
    .byte 0b01111110
    .byte 0b10011001
    .byte 0b10111101
    .byte 0b10011001
    .byte 0b11000011
    .byte 0b10100001
    .byte 0b11111111
    .byte 0b01010101

disk_frame_b:
    .byte 0b01111110
    .byte 0b10100101
    .byte 0b11011011
    .byte 0b10100101
    .byte 0b11000011
    .byte 0b10010001
    .byte 0b11111111
    .byte 0b01010101


; ------------------------------------------------------------
; FONTE NUMERICA 3x5 (digitos 0-9)
; 5 bytes por digito, bits 2..0 = colunas
; ------------------------------------------------------------

font_digits:

    ; 0
    .byte 0b111
    .byte 0b101
    .byte 0b101
    .byte 0b101
    .byte 0b111

    ; 1
    .byte 0b010
    .byte 0b110
    .byte 0b010
    .byte 0b010
    .byte 0b111

    ; 2
    .byte 0b111
    .byte 0b001
    .byte 0b111
    .byte 0b100
    .byte 0b111

    ; 3
    .byte 0b111
    .byte 0b001
    .byte 0b111
    .byte 0b001
    .byte 0b111

    ; 4
    .byte 0b101
    .byte 0b101
    .byte 0b111
    .byte 0b001
    .byte 0b001

    ; 5
    .byte 0b111
    .byte 0b100
    .byte 0b111
    .byte 0b001
    .byte 0b111

    ; 6
    .byte 0b111
    .byte 0b100
    .byte 0b111
    .byte 0b101
    .byte 0b111

    ; 7
    .byte 0b111
    .byte 0b001
    .byte 0b001
    .byte 0b001
    .byte 0b001

    ; 8
    .byte 0b111
    .byte 0b101
    .byte 0b111
    .byte 0b101
    .byte 0b111

    ; 9
    .byte 0b111
    .byte 0b101
    .byte 0b111
    .byte 0b001
    .byte 0b111
