include ../../Makefile.common

# -----------------------------------------------------------------------------
# xfcp_test_11_cpu_mailbox -- XFCP v1.3+MEM+MAILBOX (2-stream CPU mailbox)
# -----------------------------------------------------------------------------
#
# Board: QMTech EP4CE55
# Takt: 125 MHz (PLL: 50 MHz sys_clk -> 125 MHz clk125)
#
# Protokol: XFCP v1.3+MEM+MAILBOX
#   stream_id=0 (STR0): loopback FIFO 256B
#   stream_id=1 (CPU0): CPU mailbox loopback FIFO 256B
#   GET_CAPS: num_stream=2
#   GET_TARGET_INFO: index 9 = CPU0 STREAM sid=1
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
.PHONY: xfcp xfcp-ping xfcp-caps xfcp-targets xfcp-read32 xfcp-write32
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
	@echo "  xfcp_test_11_cpu_mailbox HW test"
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

test-uart:
	cd tools && python3 test_hw.py \
	  --uart $(UART_PORT) --baud $(UART_BAUD) \
	  --caps --targets --rw --stream --mem --diag --repeat $(TEST_REPEAT)

test-udp:
	cd tools && python3 test_hw.py \
	  --udp $(FPGA_IP):$(XFCP_UDP_PORT) \
	  --caps --targets --rw --stream --mem --diag --repeat $(TEST_REPEAT)

hw-regression: arp-setup test-uart test-udp

# -----------------------------------------------------------------------------
# XFCP CLI shortcuts
# -----------------------------------------------------------------------------

XFCP_UART ?= $(UART_PORT)
XFCP_UDP  ?=
XFCP_CLI   = cd tools && python3 xfcp_cli.py

_xfcp_transport = $(if $(XFCP_UDP),--udp $(XFCP_UDP),--uart $(XFCP_UART))

ADDR ?= 0xFF020000
VAL  ?= 0x00000000
CMD  ?= ping

xfcp:
	$(XFCP_CLI) $(_xfcp_transport) $(CMD)

xfcp-ping:
	$(XFCP_CLI) $(_xfcp_transport) ping

xfcp-caps:
	$(XFCP_CLI) $(_xfcp_transport) caps

xfcp-targets:
	$(XFCP_CLI) $(_xfcp_transport) targets

xfcp-read32:
	$(XFCP_CLI) $(_xfcp_transport) read32 $(ADDR)

xfcp-write32:
	$(XFCP_CLI) $(_xfcp_transport) write32 $(ADDR) $(VAL)

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
