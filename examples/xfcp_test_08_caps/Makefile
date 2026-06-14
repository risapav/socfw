include ../../Makefile.common

# -----------------------------------------------------------------------------
# xfcp_test_08_caps -- XFCP v1.1+CAPS (GET_CAPS extension)
# -----------------------------------------------------------------------------
#
# Board: QMTech EP4CE55
# Takt: 125 MHz (PLL: 50 MHz sys_clk -> 125 MHz clk125)
#
# Protokol: XFCP v1.1+CAPS
#   Response header: SOP(1)+TYPE(1)+SEQ(1)+STATUS(1) = 4 bajty
#   AXI BRESP/RRESP -> STATUS, STREAM_WRITE/READ -> loopback FIFO
#   GET_CAPS (0x01) -> staticka 8-bajtova odpoved
#
# XFCP over UART:  python3 tools/main.py  -> [1] UART /dev/ttyUSB0
# XFCP over UDP:   python3 tools/main.py  -> [2] UDP 192.168.0.5:50000
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

TEST_REPEAT  ?= 3

.PHONY: sim sim-unit sim-integration sim-regression sim-clean
.PHONY: arp-setup arp-show tcpdump
.PHONY: test-arp test-icmp test-uart test-udp hw-test hw-regression
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
# Network / HW testy
# -----------------------------------------------------------------------------

test-arp:
	arping -I $(PC_IFACE) -c 4 $(FPGA_IP)

test-icmp:
	ping -I $(PC_IFACE) -c 6 $(FPGA_IP)

hw-test: arp-setup
	@echo ""
	@echo "======================================="
	@echo "  xfcp_test_08_caps HW test (full)"
	@echo "======================================="
	@echo ""
	@echo "--- ARP ---"
	arping -I $(PC_IFACE) -c 4 $(FPGA_IP)
	@echo ""
	@echo "--- ICMP ---"
	ping -I $(PC_IFACE) -c 4 $(FPGA_IP)
	@echo ""
	@echo "======================================="
	@echo "  hw-test COMPLETE"
	@echo "======================================="

# -----------------------------------------------------------------------------
# Debug
# -----------------------------------------------------------------------------

vars:
	@echo "FPGA_IP=$(FPGA_IP)"
	@echo "FPGA_MAC=$(FPGA_MAC)"
	@echo "XFCP_UDP_PORT=$(XFCP_UDP_PORT)"
	@echo "PC_IFACE=$(PC_IFACE)"
	@echo "UART_PORT=$(UART_PORT)"
	@echo "UART_BAUD=$(UART_BAUD)"
	@echo "CLOCK_HZ=$(CLOCK_HZ)"
	@echo "BAUD_DIV=$(BAUD_DIV)"
