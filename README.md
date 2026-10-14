# arduino-asm

Exemplos práticos de programação bare-metal em **Assembly AVR puro** para o microcontrolador ATmega328P (Arduino Uno). 

A proposta do repositório é sair da camada de abstração do Arduino (C/C++, `digitalWrite`, bibliotecas prontas) e controlar o hardware direto nos registradores de I/O, portas, temporização por laços de instrução e periféricos internos como a USART.

---

## Hardware Utilizado

* **Placa:** Arduino Uno (ATmega328P @ 16 MHz)
* **Display:** Módulo Matriz de LED 8x8 com driver MAX7219
* **Botão (opcional em matriz2):** Push-button entre D12 e GND (usando pull-up interno)

### Conexões da Matriz com o Arduino

| Pino MAX7219 | Pino Arduino | Registrador / I/O | Função |
| :--- | :--- | :--- | :--- |
| **VCC** | 5V | — | Alimentação |
| **GND** | GND | — | Terra |
| **DIN** | D11 | PB3 | Dados SPI (bit-bang) |
| **CS** | D10 | PB2 | Chip Select (Load) |
| **CLK** | D13 | PB5 | Clock SPI |

---

## O que tem no repositório

### 1. `blink.asm`
O "hello world" do baixo nível. Configura o pino PB5 (LED onboard / D13) como saída e faz o LED piscar usando laços aninhados de decremento para criar o atraso de tempo, sem uso de timers ou interrupções.

### 2. `matriz_8x8.asm`
Primeiro passo controlando o driver MAX7219 por SPI via software (bit-bang). Envia os comandos de inicialização do chip (desligar decode, ajustar brilho, scan limit) e executa uma animação de "cobrinha" percorrendo os 64 LEDs da matriz, buscando os padrões armazenados na memória Flash com a instrução `lpm` através do ponteiro Z.

### 3. `matriz2.asm`
Evolução do controle da matriz com interação física e manipulação de memória RAM:
* Leitura de botão no pino D12 (PB4) com debouncing e detecção de borda.
* Troca entre modos de animação (carinha estática e seta com scroll contínuo).
* Implementação de scroll circular usando um anel de linhas alocado na SRAM (`0x0200`) e rotina para transposição de orientação da matriz caso o módulo físico esteja rotacionado.

### 4. `monitor_pc.asm` + `pc_monitor.py`
O projeto principal da pasta: transforma a matriz 8x8 em um **monitor externo de telemetria do PC** via cabo USB.

* **No Arduino (`monitor_pc.asm`):**
  * Configura o hardware da USART0 nativa em 9600 baud (8N1).
  * Faz leitura contínua dos dados por polling durante os laços de exibição (sem bloquear o ciclo de animação).
  * Exibe ciclicamente quatro métricas do sistema: **CPU**, **RAM**, **Temperatura** e **Disco**.
  * Para cada métrica, o ciclo visual tem três fases:
    1. **Ícone animado 8x8** com efeito de clock/pulso (microchip piscando pinos para CPU, pente DIMM transferindo dados para RAM, termômetro oscilando mercúrio para Temperatura, HD com prato girando e braço atuador para Disco) durante ~0.8s.
    2. **Scroll vertical suave**: a tela de 16 linhas desloca o ícone para cima e sobe o número de baixo para cima pixel por pixel.
    3. **Número de 2 dígitos**: renderiza o valor exato (de 00 a 99) usando uma fonte compacta de 3x5 colunas centralizada, ficando estável por ~2.3s para facilitar a leitura.
  * **Modo demo autônomo:** se o script do PC não estiver rodando ou o cabo serial estiver desconectado, o próprio código simula variações de números para que a tela nunca fique estática ou apagada.

* **No computador (`pc_monitor.py`):**
  * Script em Python que coleta o uso real de CPU, memória RAM, temperatura e uso de disco do Windows através da biblioteca `psutil`.
  * Detecta a porta COM do Arduino e envia pacotes de 6 bytes serialmente a cada 1 segundo:
    `[0xFF] [0x55] [CPU_PCT] [RAM_PCT] [TEMP_C] [DISCO_PCT]`
  * Exibe um dashboard no próprio terminal enquanto envia os dados.

---

## Como compilar e gravar

O projeto foi construído usando o toolchain do `avr-gcc` e o gravador `avrdude` (que já vêm inclusos na instalação da Arduino IDE, dispensando instalar pacotes extras).

### Método rápido (Windows)

O arquivo `upload_monitor.bat` automatiza o processo em um comando só:

```cmd
.\upload_monitor.bat
```

Ele compila o assembly, gera o arquivo `.hex` e chama o `avrdude` para gravar no Arduino na porta `COM3` (ajuste a porta dentro do `.bat` se o seu Arduino estiver em outra).

### Método manual (linha de comando)

Se quiser compilar e gravar manualmente passo a passo:

```bash
# 1. Compila o assembly para objeto ELF sem libc
avr-gcc -mmcu=atmega328p -x assembler-with-cpp -nostdlib monitor_pc.asm -o monitor_pc.elf

# 2. Extrai o binário para formato Intel HEX
avr-objcopy -O ihex -R .eeprom monitor_pc.elf monitor_pc.hex

# 3. Grava na placa via bootloader do Arduino (exemplo porta COM3)
avrdude -C avrdude.conf -p atmega328p -c arduino -P COM3 -b 115200 -D -U flash:w:monitor_pc.hex:i
```

---

## Rodando o monitor do PC

1. Grave o código no Arduino com o `upload_monitor.bat`.
2. Instale as dependências do script Python no computador:

```bash
pip install psutil pyserial
```

3. Inicie o monitor (passe a porta COM caso não detecte automaticamente):

```bash
python pc_monitor.py COM3
```

O terminal vai abrir o dashboard com as barras de uso do PC e a matriz de LED vai alternar entre os ícones animados e as porcentagens em tempo real. Pressione `Ctrl + C` no terminal quando quiser parar o monitoramento.