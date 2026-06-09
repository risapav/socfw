include ../../Makefile.common

# -----------------------------------------------------------------------------
# xfcp_test_05 — Dual-transport XFCP (UART + ETH-UDP)
# -----------------------------------------------------------------------------
#
# Board: QMTech EP4CE55
# Takt: 125 MHz (PLL: 50 MHz sys_clk -> 125 MHz clk125)
#
# Faza A (UZAVRETA 2026-06-08): UART XFCP + arbiter + endpoint
# Faza B (UZAVRETA 2026-06-09): ETH-UDP XFCP, regression 12/12 PASS
# Faza C (UZAVRETA 2026-06-09): Python dual-transport tools
#
# XFCP over UART:  python3 tools/main.py  -> [1] UART /dev/ttyUSB0
# XFCP over UDP:   python3 tools/main.py  -> [2] UDP 192.168.0.5:50000
#
# ARP:  arping -I $(PC_IFACE) $(FPGA_IP)
# ICMP: ping -I $(PC_IFACE) $(FPGA_IP)
# UDP XFCP: make xfcp-udp
# -----------------------------------------------------------------------------

CLOCK_HZ ?= 125000000
BAUD     ?= 115200
BAUD_DIV  = $(shell python3 -c "print(round($(CLOCK_HZ)/$(BAUD)))")

FPGA_IP        ?= 192.168.0.5
FPGA_MAC       ?= 00:0a:35:01:fe:c5
XFCP_UDP_PORT  ?= 50000
PC_IFACE       ?= enp0s31f6
PC_IP          ?= 192.168.0.3

UART_PORT ?= /dev/ttyUSB0
UART_BAUD ?= 115200

TOOLS_DIR := tools

.PHONY: sim sim-unit sim-integration sim-regression sim-clean
.PHONY: compile-baud
.PHONY: arp-setup arp-show tcpdump
.PHONY: xfcp-uart xfcp-udp
.PHONY: test-arp test-icmp hw-test
.PHONY: vars

# -----------------------------------------------------------------------------
# Simulation
# -----------------------------------------------------------------------------

sim:
	$(MAKE) -C sim regression

sim-unit:
	$(MAKE) -C sim unit

sim-integration:
	$(MAKE) -C sim integration

sim-regression:
	$(MAKE) -C sim regression

sim-clean:
	$(MAKE) -C sim clean

# -----------------------------------------------------------------------------
# Build helpers
# -----------------------------------------------------------------------------

compile-baud:
	@echo "=== Static baud bitstream: $(BAUD) baud (BAUD_DIV=$(BAUD_DIV)) ==="
	@test -f build/rtl/soc_top.sv || (echo "Run 'make gen' first" && false)
	sed -i 's/UART_DEFAULT_BAUD_DIV([0-9]*)/UART_DEFAULT_BAUD_DIV($(BAUD_DIV))/' build/rtl/soc_top.sv
	$(MAKE) compile
	cp output_files/soc_top.sof output_files/soc_top_$(BAUD)baud.sof
	@echo "=== Restoring default baud ==="
	sed -i 's/UART_DEFAULT_BAUD_DIV([0-9]*)/UART_DEFAULT_BAUD_DIV(1085)/' build/rtl/soc_top.sv
	@echo "=== Done: output_files/soc_top_$(BAUD)baud.sof ==="

# -----------------------------------------------------------------------------
# Network setup
# -----------------------------------------------------------------------------

arp-setup:
	sudo ip neigh replace $(FPGA_IP) lladdr $(FPGA_MAC) nud permanent dev $(PC_IFACE)
	@echo "Static ARP set: $(FPGA_IP) -> $(FPGA_MAC) on $(PC_IFACE)"

arp-show:
	ip neigh show dev $(PC_IFACE)

tcpdump:
	sudo tcpdump -i $(PC_IFACE) -e -n -XX \
	  'ether host $(FPGA_MAC) or host $(FPGA_IP) or udp port $(XFCP_UDP_PORT) or arp or icmp'

# -----------------------------------------------------------------------------
# XFCP tools
# -----------------------------------------------------------------------------

xfcp-uart:
	@echo "=== XFCP cez UART: $(UART_PORT) @ $(UART_BAUD) ==="
	cd $(TOOLS_DIR) && python3 main.py

xfcp-udp: arp-setup
	@echo "=== XFCP cez UDP: $(FPGA_IP):$(XFCP_UDP_PORT) ==="
	cd $(TOOLS_DIR) && python3 main.py

# -----------------------------------------------------------------------------
# HW testy
# -----------------------------------------------------------------------------

test-arp:
	@echo "=== ARP echo test -> $(FPGA_IP) ==="
	arping -I $(PC_IFACE) -c 4 $(FPGA_IP)
	@echo "=== ARP: OK ==="

test-icmp:
	@echo "=== ICMP echo test -> $(FPGA_IP) ==="
	ping -I $(PC_IFACE) -c 6 $(FPGA_IP)
	@echo "=== ICMP: OK ==="

hw-test: arp-setup
	@echo ""
	@echo "======================================="
	@echo "  xfcp_test_05 HW test"
	@echo "======================================="
	@echo ""
	@echo "--- ARP ---"
	arping -I $(PC_IFACE) -c 4 $(FPGA_IP)
	@echo ""
	@echo "--- ICMP ---"
	ping -I $(PC_IFACE) -c 4 $(FPGA_IP)
	@echo ""
	@echo "--- XFCP over UART (interaktivny) ---"
	@echo "Spusti manualne: make xfcp-uart"
	@echo ""
	@echo "--- XFCP over UDP (interaktivny) ---"
	@echo "Spusti manualne: make xfcp-udp"
	@echo ""
	@echo "======================================="
	@echo "  hw-test network checks COMPLETE"
	@echo "======================================="

# -----------------------------------------------------------------------------
# Debug
# -----------------------------------------------------------------------------

vars:
	@echo "FPGA_IP=$(FPGA_IP)"
	@echo "FPGA_MAC=$(FPGA_MAC)"
	@echo "XFCP_UDP_PORT=$(XFCP_UDP_PORT)"
	@echo "PC_IFACE=$(PC_IFACE)"
	@echo "PC_IP=$(PC_IP)"
	@echo "UART_PORT=$(UART_PORT)"
	@echo "UART_BAUD=$(UART_BAUD)"
	@echo "CLOCK_HZ=$(CLOCK_HZ)"
	@echo "BAUD_DIV=$(BAUD_DIV)"
