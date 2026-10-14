@echo off
setlocal
chcp 65001 >nul

set "TOOLCHAIN=C:\Users\adils\AppData\Local\Arduino15\packages\arduino\tools\avr-gcc\7.3.0-atmel3.6.1-arduino7\bin"
set "AVRDUDE=C:\Users\adils\AppData\Local\Arduino15\packages\arduino\tools\avrdude\8.0.0-arduino1\bin\avrdude.exe"
set "AVRCONF=C:\Users\adils\AppData\Local\Arduino15\packages\arduino\tools\avrdude\8.0.0-arduino1\etc\avrdude.conf"
set "PORT=COM3"

echo ============================================================
echo   Compilando e Gravando Monitor PC na Matriz 8x8 (Arduino Uno)
echo ============================================================

echo [1/3] Compilando monitor_pc.asm...
"%TOOLCHAIN%\avr-gcc.exe" -mmcu=atmega328p -x assembler-with-cpp -nostdlib monitor_pc.asm -o monitor_pc.elf
if errorlevel 1 (
    echo [ERRO] Falha na compilação do assembly.
    goto erro
)

echo [2/3] Gerando arquivo hexadecimal monitor_pc.hex...
"%TOOLCHAIN%\avr-objcopy.exe" -O ihex -R .eeprom monitor_pc.elf monitor_pc.hex
if errorlevel 1 (
    echo [ERRO] Falha ao gerar o arquivo .hex.
    goto erro
)

echo [3/3] Gravando no Arduino Uno na porta %PORT%...
"%AVRDUDE%" -C "%AVRCONF%" -p atmega328p -c arduino -P %PORT% -b 115200 -D -U flash:w:monitor_pc.hex:i
if errorlevel 1 (
    echo [ERRO] Falha na gravação do firmware. Verifique se o Arduino está na porta %PORT%.
    goto erro
)

echo.
echo ============================================================
echo   GRAVAÇÃO CONCLUÍDA COM SUCESSO!
echo   Agora execute: python pc_monitor.py %PORT%
echo ============================================================
goto fim

:erro
echo.
echo Houve um erro no processo.
pause

:fim
endlocal

