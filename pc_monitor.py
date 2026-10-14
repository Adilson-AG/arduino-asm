"""
Monitor de Recursos do PC -> Arduino Matriz LED 8x8
Envia métricas de CPU, Memória RAM, Temperatura e Disco via Porta Serial.

Requisitos:
    pip install pyserial psutil
"""

import time
import sys
import psutil
import serial
import serial.tools.list_ports

BAUD_RATE = 9600
INTERVALO_SEGUNDOS = 1.0  # Frequência de envio de dados para o Arduino


def encontrar_porta_arduino():
    """Detecta automaticamente a porta COM do Arduino Uno."""
    portas = list(serial.tools.list_ports.comports())
    for p in portas:
        desc = (p.description or "").lower()
        if "arduino" in desc or "ch340" in desc or "usb serial" in desc:
            return p.device
    
    # Se não achou pelo nome mas existe COM3 (padrão comum), sugere
    for p in portas:
        if "com" in p.device.lower() and "bluetooth" not in (p.description or "").lower():
            return p.device
    
    return None


def obter_temperatura_cpu(cpu_pct):
    """
    Tenta ler sensores de temperatura físicos via psutil.
    No Windows (onde muitos drivers bloqueiam acesso direto sem admin),
    faz uma estimativa térmica coerente com a carga da CPU caso não haja sensor exposto.
    """
    try:
        if hasattr(psutil, "sensors_temperatures"):
            sensores = psutil.sensors_temperatures()
            if sensores:
                for chave in ["coretemp", "cpu_thermal", "k10temp", "acpitz"]:
                    if chave in sensores and len(sensores[chave]) > 0:
                        return int(sensores[chave][0].current)
                # Pega o primeiro sensor disponível
                for lista in sensores.values():
                    if lista:
                        return int(lista[0].current)
    except Exception:
        pass

    # Estimativa realista em repouso vs carga (ex: 38°C idle até ~85°C sob 100% de uso)
    temp_estimada = int(38 + (cpu_pct * 0.47))
    return min(100, max(20, temp_estimada))


def main():
    porta = None
    if len(sys.argv) > 1:
        porta = sys.argv[1].upper()
    else:
        porta = encontrar_porta_arduino()

    if not porta:
        print("[ERRO] Nenhuma porta COM do Arduino foi encontrada automaticamente.")
        print("Especifique a porta manualmente ao rodar, exemplo:")
        print("    python pc_monitor.py COM3")
        sys.exit(1)

    print("=" * 60)
    print(f" Conectando ao Arduino na porta: {porta} ({BAUD_RATE} baud)...")
    print("=" * 60)

    try:
        ser = serial.Serial(porta, BAUD_RATE, timeout=1)
        # O Arduino Uno reinicia ao abrir a serial (DTR reset). Aguarda 2 segundos:
        time.sleep(2.0)
        ser.reset_input_buffer()
    except Exception as e:
        print(f"[ERRO] Nao foi possivel abrir a porta {porta}: {e}")
        sys.exit(1)

    print("\n Conexao estabelecida com sucesso!")
    print(" Enviando telemetria em tempo real para a Matriz 8x8.")
    print(" Pressione Ctrl+C para encerrar.\n")

    try:
        while True:
            # Coleta métricas do computador
            cpu_pct = int(psutil.cpu_percent(interval=INTERVALO_SEGUNDOS))
            ram_pct = int(psutil.virtual_memory().percent)
            disco_pct = int(psutil.disk_usage('C:').percent)
            temp_c = obter_temperatura_cpu(cpu_pct)

            # Garante limites de 0 a 100
            cpu_pct = min(100, max(0, cpu_pct))
            ram_pct = min(100, max(0, ram_pct))
            temp_c = min(100, max(0, temp_c))
            disco_pct = min(100, max(0, disco_pct))

            # Monta o pacote de 6 bytes: [0xFF, 0x55, CPU, RAM, TEMP, DISCO]
            pacote = bytes([0xFF, 0x55, cpu_pct, ram_pct, temp_c, disco_pct])
            ser.write(pacote)
            ser.flush()

            # Mostra no console um mini dashboard
            barra_cpu = "#" * (cpu_pct // 10) + "." * (10 - (cpu_pct // 10))
            barra_ram = "#" * (ram_pct // 10) + "." * (10 - (ram_pct // 10))
            
            print(f"\r [PC MONITOR] CPU: {cpu_pct:3d}% [{barra_cpu}] | "
                  f"RAM: {ram_pct:3d}% [{barra_ram}] | "
                  f"TEMP: {temp_c:3d}°C | "
                  f"DISCO: {disco_pct:3d}%", end="", flush=True)

    except KeyboardInterrupt:
        print("\n\n[INFO] Monitoramento encerrado pelo usuario.")
    finally:
        try:
            ser.close()
        except Exception:
            pass


if __name__ == "__main__":
    main()

