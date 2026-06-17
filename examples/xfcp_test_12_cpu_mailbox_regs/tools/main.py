import time
import sys
import threading
import queue
from colorama import Fore, Style, init

from xfcp.bus import XfcpBus
from xfcp.timeouts import XfcpTimeouts
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


def run_monitor(soc, transport_label):
    """Live monitor — updates status line every 100 ms."""
    print(f"\n{Fore.CYAN}>>> LIVE MONITOR AKTÍVNY  [{transport_label}]")
    print(f"{Fore.WHITE}Skratky: [c] Clear Errors | [r] SW Reset | [d] DIAG Snapshot | [q] Návrat do menu")
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
                if cmd == 'd':
                    if 'DIAG' in soc:
                        soc['DIAG'].snapshot()
                    print(f"\n{Fore.CYAN}[ACK] DIAG snapshot vykonaný.")

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


def select_transport():
    """Prompt user to choose and configure a transport. Returns (XfcpBus, label)."""
    print(f"\n{Fore.CYAN}Vyberte transport:")
    print(f"  [1] UART  (sériová linka)")
    print(f"  [2] UDP   (Ethernet)")

    while True:
        choice = input("Voľba [1/2]: ").strip()
        if choice == '1':
            port = input(f"Serial port [{Fore.YELLOW}/dev/ttyUSB0{Fore.RESET}]: ").strip()
            if not port:
                port = '/dev/ttyUSB0'
            baud_raw = input(f"Baudrate [{Fore.YELLOW}115200{Fore.RESET}]: ").strip()
            baud = int(baud_raw) if baud_raw.isdigit() else 115200
            bus = XfcpBus.uart(port=port, baudrate=baud)
            return bus, f"UART {port}@{baud}"

        elif choice == '2':
            host_raw = input(f"IP adresa [{Fore.YELLOW}192.168.0.5{Fore.RESET}]: ").strip()
            host = host_raw if host_raw else '192.168.0.5'
            port_raw = input(f"UDP port  [{Fore.YELLOW}50000{Fore.RESET}]: ").strip()
            udp_port = int(port_raw) if port_raw.isdigit() else 50000
            bus = XfcpBus.udp(host=host, port=udp_port)
            return bus, f"UDP {host}:{udp_port}"

        else:
            print(f"{Fore.RED}Neplatná voľba.")


def main():
    print(f"{Fore.LIGHTWHITE_EX}=== FPGA SoC Development Framework v1.0  [xfcp_test_05] ===")

    bus, transport_label = select_transport()

    try:
        with bus:
            print(f"\n{Fore.CYAN}Pripájam sa cez {transport_label}...")
            if not bus.ping():
                print(f"{Fore.RED}[!] SoC neodpovedá. Skontroluj spojenie.")
                return

            scanner = DynamicScanner(bus, num_slots=7)
            soc = scanner.scan()

            if not soc:
                print(f"{Fore.RED}[!] Žiadne periférie nenájdené.")
                return

            while True:
                print(f"\n{Fore.MAGENTA}{'='*15} HLAVNÉ MENU {'='*15}")
                print(f"  Transport: {Fore.CYAN}{transport_label}{Style.RESET_ALL}")
                print(f"  [1] Live Monitor (Real-time sledovanie)")
                print(f"  [2] Diagnostika (Manuálne testy modulov)")
                print(f"  [3] Reskenovať zbernicu")
                print(f"  [4] Zmeniť transport")
                print(f"  [q] Ukončiť aplikáciu")

                mode = input(f"\nVoľba: ").lower().strip()

                if mode == '1':
                    run_monitor(soc, transport_label)
                elif mode == '2':
                    run_diagnostics_menu(soc)
                elif mode == '3':
                    soc = scanner.scan()
                elif mode == '4':
                    break
                elif mode == 'q':
                    print(f"{Fore.CYAN}Ukončujem...")
                    return
                else:
                    print(f"{Fore.RED}Neplatný výber.")

    except ConnectionError as e:
        print(f"{Fore.RED}[FATAL] {e}")
        return
    except Exception as e:
        print(f"{Fore.RED}[FATAL] {type(e).__name__}: {e}")
        return

    # Transport switch — recurse back into main
    main()


if __name__ == "__main__":
    main()
