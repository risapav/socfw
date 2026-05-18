import time
import sys
import threading
import queue
from colorama import Fore, Style, init

from bus.xfcp import XFCPBus
from core.scanner import DynamicScanner

init(autoreset=True)

cmd_queue         = queue.Queue()
stop_input_thread = threading.Event()


def input_handler():
    """Non-blocking keyboard input thread for monitor mode."""
    import tty, termios
    fd = sys.stdin.fileno()
    if not sys.stdin.isatty():
        return
    old_settings = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        while not stop_input_thread.is_set():
            char = sys.stdin.read(1)
            if char:
                cmd_queue.put(char)
            if char.lower() == 'q' or char == '\x03':
                break
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)


def run_monitor(soc):
    """Live monitor — updates status line every 100 ms."""
    print(f"\n{Fore.CYAN}>>> LIVE MONITOR AKTÍVNY")
    print(f"{Fore.WHITE}Skratky: [c] Clear Errors | [r] SW Reset | [q] Návrat do menu")
    print(f"{Style.DIM}{'-' * 80}")

    stop_input_thread.clear()
    thread = threading.Thread(target=input_handler, daemon=True)
    thread.start()

    try:
        while not stop_input_thread.is_set():
            if not cmd_queue.empty():
                cmd = cmd_queue.get().lower()
                if cmd == 'q':
                    break
                if cmd == 'c':
                    if 'SYSC' in soc:
                        soc['SYSC'].clear_faults = 1
                    if 'UART' in soc:
                        soc['UART'].clear_errors = 1
                    if 'INP_' in soc:
                        soc['INP_'].clear_all_edges()
                    print(f"\n{Fore.YELLOW}[ACK] Registre vyčistené.")
                if cmd == 'r':
                    if 'SYSC' in soc:
                        soc['SYSC'].sw_reset = 1
                    print(f"\n{Fore.RED}[ACK] Odoslaný System Reset!")

            try:
                status_msg = ""
                if 'SYSC' in soc and soc['SYSC'].ic_timeout:
                    status_msg = (f"{Fore.RED}!! BUS FAULT @ "
                                  f"{hex(soc['SYSC'].fault_addr)} !! {Fore.RESET}")

                metrics = []
                for name, dev in soc.items():
                    try:
                        m = dev.get_live_metrics()
                    except Exception:
                        m = {"err": f"{Fore.RED}ERR{Fore.RESET}"}
                    if m:
                        fmt = " ".join(f"{k}:{v}" for k, v in m.items())
                        metrics.append(f"{Fore.GREEN}{name}{Fore.RESET}[{fmt}]")

                sys.stdout.write(f"\r\x1b[K{status_msg}{' | '.join(metrics)}")
                sys.stdout.flush()
            except ConnectionError as e:
                print(f"\n{Fore.RED}[ERR] Spojenie prerušené: {e}")
                break

            time.sleep(0.1)
    finally:
        stop_input_thread.set()
        print(f"\n{Fore.CYAN}[*] Monitor ukončený.")


def run_diagnostics_menu(soc):
    """Interactive diagnostics menu."""
    sorted_devs = sorted(soc.items(), key=lambda x: x[1].base)

    while True:
        print(f"\n{Fore.YELLOW}--- DIAGNOSTIKA PERIFÉRIÍ ---")
        for i, (name, dev) in enumerate(sorted_devs):
            print(f"  [{i}] {name.ljust(6)} @ {hex(dev.base)}")
        print(f"  [a] Spustiť VŠETKY testy")
        print(f"  [q] Návrat do hlavného menu")

        choice = input(f"\nVyberte slot/akciu: ").lower().strip()

        if choice == 'q':
            break
        elif choice == 'a':
            for name, dev in sorted_devs:
                dev.run_test()
        elif choice.isdigit() and int(choice) < len(sorted_devs):
            name, dev = sorted_devs[int(choice)]
            dev.run_test()
        else:
            print(f"{Fore.RED}Neplatná voľba.")


def main():
    print(f"{Fore.LIGHTWHITE_EX}=== FPGA SoC Development Framework v1.0 ===")
    PORT = '/dev/ttyUSB0'

    try:
        with XFCPBus(port=PORT) as bus:
            scanner = DynamicScanner(bus)
            soc = scanner.scan()

            if not soc:
                print(f"{Fore.RED}[!] SoC neodpovedá alebo žiadne periférie nenájdené.")
                return

            while True:
                print(f"\n{Fore.MAGENTA}{'='*15} HLAVNÉ MENU {'='*15}")
                print(f"  [1] Live Monitor (Real-time sledovanie)")
                print(f"  [2] Diagnostika (Manuálne testy modulov)")
                print(f"  [3] Reskenovať zbernicu")
                print(f"  [q] Ukončiť aplikáciu")

                mode = input(f"\nVoľba: ").lower().strip()

                if mode == '1':
                    run_monitor(soc)
                elif mode == '2':
                    run_diagnostics_menu(soc)
                elif mode == '3':
                    soc = scanner.scan()
                elif mode == 'q':
                    print(f"{Fore.CYAN}Ukončujem...")
                    break
                else:
                    print(f"{Fore.RED}Neplatný výber.")

    except ConnectionError as e:
        print(f"{Fore.RED}[FATAL] {e}")
    except Exception as e:
        print(f"{Fore.RED}[FATAL] {type(e).__name__}: {e}")


if __name__ == "__main__":
    main()
