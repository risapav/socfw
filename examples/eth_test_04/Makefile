include ../../Makefile.common

# -----------------------------------------------------------------------------
# eth_test_04 — ARP / ICMP / UDP echo stack HW helpers
# -----------------------------------------------------------------------------
#
# Current project phase: UZAVRETA (Faza 5, 2026-06-06)
#   Full L2/L3/L4 Ethernet stack: ARP echo, ICMP echo, UDP echo (port 7).
#   Timing: ETH_TX_CLK 85C +0.327 ns clean.
#
# Main HW behavior:
#   ARP:  arping -> FPGA replies with its MAC
#   ICMP: ping   -> FPGA echoes ICMP, TTL=64
#   UDP:  send to port 7 -> FPGA echoes same payload to sender's source port
#
# L2 loopback targets (trace-l2, loopback-test) kept for regression baseline.
# -----------------------------------------------------------------------------

FPGA_IP            ?= 192.168.0.2
FPGA_MAC           ?= 00:0a:35:01:fe:c0
FPGA_UDP_PORT      ?= 8080
FPGA_UDP_ECHO_PORT ?= 7
PC_IFACE           ?= enp0s31f6
PC_IP              ?= 192.168.0.3

# UART raw GMII tap config (CP2102N on board)
TAP_PORT  ?= /dev/ttyUSB0
TAP_BAUD  ?= 115200
TAP_BYTES ?= 32
TAP_PCAP  ?= /tmp/eth_test_04_tap.pcapng

# Trace/capture infrastructure.
#
# Important:
#   TRACE_TOOL selects the capture backend.
#     tcpdump   = non-GUI default, recommended for scripted testing
#     dumpcap   = Wireshark capture backend, non-GUI
#     tshark    = Wireshark CLI
#     wireshark = GUI capture backend, use only explicitly
#     auto      = script decides; not recommended as default while debugging GUI
#
#   TRACE_OPEN controls whether the resulting pcapng is opened after the test.
#     TRACE_OPEN=0 => do not open Wireshark GUI
#     TRACE_OPEN=1 => open resulting pcapng in Wireshark GUI after capture
#
# For current eth_test_04 phase, default to non-GUI tcpdump + L2 loopback.
TRACE_SCRIPT  ?= ./tools/eth_hw_trace.sh
TRACE_DIR     ?= captures
TRACE_TOOL    ?= tcpdump
TRACE_PROFILE ?= l2-loopback
TRACE_OPEN    ?= 0

ifeq ($(TRACE_OPEN),1)
TRACE_OPEN_ARG := --open-wireshark
else
TRACE_OPEN_ARG :=
endif

.PHONY: sim sim-unit sim-integration sim-regression sim-clean
.PHONY: arp-setup arp-show udp-send udp-test tcpdump wire-test tap-test hw-test fpga-test
.PHONY: loopback-test loopback-test-bcast loopback-test-raw loopback-sniff
.PHONY: trace-test trace-l2 trace-l2-bcast trace-l2-raw trace-l2-open
.PHONY: trace-udp trace-udp-diag trace-udp-broad trace-udp-open
.PHONY: trace-vars trace-clean-captures
.PHONY: test-arp test-icmp test-udp-echo test-stack trace-stack

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
# Basic HW helpers
# -----------------------------------------------------------------------------

arp-setup:
	sudo ip neigh replace $(FPGA_IP) lladdr $(FPGA_MAC) nud permanent dev $(PC_IFACE)
	@echo "Static ARP set: $(FPGA_IP) -> $(FPGA_MAC) on $(PC_IFACE)"

arp-show:
	ip neigh show dev $(PC_IFACE)

udp-send:
	echo -n "HELLO" | nc -u -w1 $(FPGA_IP) $(FPGA_UDP_PORT)

udp-test: arp-setup
	@echo "=== UDP traffic generator -> $(FPGA_IP):$(FPGA_UDP_PORT) ==="
	@echo "NOTE: eth_test_04 is currently L2/MAC echo, not UDP/IP echo."
	echo -n "HI"                        | nc -u -w1 $(FPGA_IP) $(FPGA_UDP_PORT)
	echo -n "HELLO"                     | nc -u -w1 $(FPGA_IP) $(FPGA_UDP_PORT)
	echo -n "0123456789ABCDEF"          | nc -u -w1 $(FPGA_IP) $(FPGA_UDP_PORT)
	python3 -c "print('X'*64, end='')"  | nc -u -w1 $(FPGA_IP) $(FPGA_UDP_PORT)
	@echo "=== Done — check tcpdump/Wireshark output ==="

tcpdump:
	sudo tcpdump -i $(PC_IFACE) -e -n -XX \
	  'ether host $(FPGA_MAC) or host $(FPGA_IP) or udp port $(FPGA_UDP_PORT) or arp or ether proto 0x9000'

fpga-test: arp-setup
	@echo "=== UDP socket echo test ==="
	@echo "NOTE: this is expected to fail until IPv4/UDP echo is implemented."
	-python3 tools/test_fpga.py --ip $(FPGA_IP) --port $(FPGA_UDP_PORT) \
	  --mac $(FPGA_MAC) --iface $(PC_IFACE) --no-arp

wire-test: arp-setup
	@echo "=== Wire-level capture: PC-side Ethernet header ==="
	@sudo tcpdump -i $(PC_IFACE) -e -n 'udp port $(FPGA_UDP_PORT)' & \
	DUMP_PID=$$!; \
	sleep 0.5; \
	python3 tools/test_fpga.py --ip $(FPGA_IP) --port $(FPGA_UDP_PORT) \
	  --mac $(FPGA_MAC) --iface $(PC_IFACE) --no-arp || true; \
	sleep 0.5; \
	sudo kill $$DUMP_PID 2>/dev/null; \
	wait $$DUMP_PID 2>/dev/null; \
	true

tap-test: arp-setup
	@echo ""
	@echo "=== raw GMII tap + pcap comparison ==="
	@echo "    pcap -> $(TAP_PCAP)"
	@echo ""
	@sudo tcpdump -i $(PC_IFACE) -w $(TAP_PCAP) -q \
	  'ether dst $(FPGA_MAC) and udp' 2>/dev/null & DUMP_PID=$$!; \
	sleep 0.3; \
	python3 tools/read_tap.py \
	  --port $(TAP_PORT) --baud $(TAP_BAUD) --count $(TAP_BYTES) \
	  --frames 0 --timeout 3 \
	  --pcap $(TAP_PCAP) --fpga-mac $(FPGA_MAC) & TAP_PID=$$!; \
	sleep 0.5; \
	python3 tools/test_fpga.py --ip $(FPGA_IP) --port $(FPGA_UDP_PORT) \
	  --mac $(FPGA_MAC) --iface $(PC_IFACE) --no-arp || true; \
	sleep 0.5; \
	sudo kill $$DUMP_PID 2>/dev/null; wait $$DUMP_PID 2>/dev/null; \
	wait $$TAP_PID; \
	true

# NOTE: loopback-test* targets require Faza A bitstream (raw L2 EtherType 0x9000 echo).
# Current bitstream is Faza B (ARP/ICMP/UDP stack) -- these tests will always timeout.
# Use 'make test-stack' for the current design regression.
loopback-test:
	sudo python3 tools/test_loopback.py --iface $(PC_IFACE) --fpga-mac $(FPGA_MAC) --mode clean

loopback-test-bcast:
	sudo python3 tools/test_loopback.py --iface $(PC_IFACE) --fpga-mac $(FPGA_MAC) --mode clean --broadcast

loopback-test-raw:
	sudo python3 tools/test_loopback.py --iface $(PC_IFACE) --fpga-mac $(FPGA_MAC) --mode raw

loopback-sniff:
	sudo python3 tools/test_loopback.py --iface $(PC_IFACE) --sniff

hw-test: arp-setup
	@echo "Starting tcpdump in background (log: /tmp/eth_test_04_capture.pcapng) ..."
	sudo tcpdump -i $(PC_IFACE) -w /tmp/eth_test_04_capture.pcapng \
	  'ether host $(FPGA_MAC) or host $(FPGA_IP) or udp port $(FPGA_UDP_PORT) or arp or ether proto 0x9000' &
	sleep 1
	@echo "Sending UDP diagnostic packets ..."
	echo -n "HI"               | nc -u -w1 $(FPGA_IP) $(FPGA_UDP_PORT)
	echo -n "HELLO"            | nc -u -w1 $(FPGA_IP) $(FPGA_UDP_PORT)
	echo -n "0123456789ABCDEF" | nc -u -w1 $(FPGA_IP) $(FPGA_UDP_PORT)
	sleep 2
	sudo pkill -f "tcpdump.*eth_test_04" || true
	@echo "Capture saved to /tmp/eth_test_04_capture.pcapng"

# -----------------------------------------------------------------------------
# Refactored trace targets
# -----------------------------------------------------------------------------

# Default HW trace for current eth_test_04 phase.
# This must test L2/MAC echo, not UDP/IP echo.
trace-test: trace-l2
	sudo chown -R $(USER) $(TRACE_DIR)

# Explicit L2/MAC clean echo trace.
# Expected result:
#   test_loopback.py: PASS
#   analysis_summary: L2/MAC echo works
trace-l2: arp-setup
	$(TRACE_SCRIPT) --project eth04 --test loopback-clean \
	  --mac $(FPGA_MAC) --pc-ip $(PC_IP) --iface $(PC_IFACE) \
	  --capture-profile l2-loopback --capture-tool $(TRACE_TOOL) \
	  --out-dir $(TRACE_DIR) $(TRACE_OPEN_ARG)

trace-l2-bcast: arp-setup
	$(TRACE_SCRIPT) --project eth04 --test loopback-bcast \
	  --mac $(FPGA_MAC) --pc-ip $(PC_IP) --iface $(PC_IFACE) \
	  --capture-profile l2-loopback --capture-tool $(TRACE_TOOL) \
	  --out-dir $(TRACE_DIR) $(TRACE_OPEN_ARG)

trace-l2-raw: arp-setup
	$(TRACE_SCRIPT) --project eth04 --test loopback-raw \
	  --mac $(FPGA_MAC) --pc-ip $(PC_IP) --iface $(PC_IFACE) \
	  --capture-profile l2-loopback --capture-tool $(TRACE_TOOL) \
	  --out-dir $(TRACE_DIR) $(TRACE_OPEN_ARG)

trace-l2-open:
	$(MAKE) trace-l2 TRACE_OPEN=1

# UDP diagnostic trace.
# This is intentionally not the default PASS/FAIL target for eth_test_04.
# UDP socket timeout is expected until IPv4/UDP swapper and checksum recompute
# are implemented.  The pcap analysis is still useful: it should identify L2
# echo frames or missing/bad replies.
trace-udp-diag: arp-setup
	-$(TRACE_SCRIPT) --project eth04 --test udp --tap \
	  --ip $(FPGA_IP) --mac $(FPGA_MAC) --port $(FPGA_UDP_PORT) \
	  --pc-ip $(PC_IP) --iface $(PC_IFACE) \
	  --tap-port $(TAP_PORT) --tap-baud $(TAP_BAUD) --tap-bytes $(TAP_BYTES) \
	  --capture-profile udp-strict --capture-tool $(TRACE_TOOL) \
	  --out-dir $(TRACE_DIR) $(TRACE_OPEN_ARG)
	sudo chown -R $(USER) $(TRACE_DIR)

# Backward-compatible alias.
trace-udp: trace-udp-diag

trace-udp-broad: arp-setup
	-$(TRACE_SCRIPT) --project eth04 --test udp --tap \
	  --ip $(FPGA_IP) --mac $(FPGA_MAC) --port $(FPGA_UDP_PORT) \
	  --pc-ip $(PC_IP) --iface $(PC_IFACE) \
	  --tap-port $(TAP_PORT) --tap-baud $(TAP_BAUD) --tap-bytes $(TAP_BYTES) \
	  --capture-profile broad --capture-tool $(TRACE_TOOL) \
	  --out-dir $(TRACE_DIR) $(TRACE_OPEN_ARG)
	sudo chown -R $(USER) $(TRACE_DIR)

trace-udp-open:
	$(MAKE) trace-udp-diag TRACE_OPEN=1

trace-vars:
	@echo "FPGA_IP=$(FPGA_IP)"
	@echo "FPGA_MAC=$(FPGA_MAC)"
	@echo "FPGA_UDP_PORT=$(FPGA_UDP_PORT)"
	@echo "PC_IFACE=$(PC_IFACE)"
	@echo "PC_IP=$(PC_IP)"
	@echo "TAP_PORT=$(TAP_PORT)"
	@echo "TAP_BAUD=$(TAP_BAUD)"
	@echo "TAP_BYTES=$(TAP_BYTES)"
	@echo "TRACE_SCRIPT=$(TRACE_SCRIPT)"
	@echo "TRACE_DIR=$(TRACE_DIR)"
	@echo "TRACE_TOOL=$(TRACE_TOOL)"
	@echo "TRACE_PROFILE=$(TRACE_PROFILE)"
	@echo "TRACE_OPEN=$(TRACE_OPEN)"
	@echo "TRACE_OPEN_ARG=$(TRACE_OPEN_ARG)"

trace-clean-captures:
	rm -rf $(TRACE_DIR)/eth04_*

# -----------------------------------------------------------------------------
# L3/L4 stack tests (Faza 5)
# -----------------------------------------------------------------------------

# ARP echo: verify FPGA replies to ARP with its MAC
test-arp:
	@echo "=== ARP echo test -> $(FPGA_IP) ==="
	arping -I $(PC_IFACE) -c 4 $(FPGA_IP)
	@echo "=== ARP: OK ==="

# ICMP echo: ping test
test-icmp:
	@echo "=== ICMP echo test -> $(FPGA_IP) ==="
	ping -I $(PC_IFACE) -c 6 $(FPGA_IP)
	@echo "=== ICMP: OK ==="

# UDP echo: socket test against RFC 862 port 7
UDP_ECHO_COUNT ?= 10
UDP_ECHO_SIZE  ?= 0      # 0 = auto (variable-length)
UDP_ECHO_VERBOSE ?= -v

test-udp-echo:
	@echo "=== UDP echo test -> $(FPGA_IP):$(FPGA_UDP_ECHO_PORT) count=$(UDP_ECHO_COUNT) ==="
	python3 tools/test_udp_echo.py \
	  --ip $(FPGA_IP) --port $(FPGA_UDP_ECHO_PORT) \
	  --count $(UDP_ECHO_COUNT) \
	  $(if $(filter-out 0,$(UDP_ECHO_SIZE)),--payload-bytes $(UDP_ECHO_SIZE)) \
	  $(UDP_ECHO_VERBOSE)

# UDP echo with large payload (stress test, up to 1464B = 1472 - 8B UDP hdr)
test-udp-echo-large:
	@echo "=== UDP echo stress test (large payload) ==="
	python3 tools/test_udp_echo.py \
	  --ip $(FPGA_IP) --port $(FPGA_UDP_ECHO_PORT) \
	  --count 10 --payload-bytes 1464 $(UDP_ECHO_VERBOSE)

# Full stack test: ARP + ICMP + UDP echo
test-stack:
	@echo ""
	@echo "========================================="
	@echo "  eth_test_04 L3/L4 stack HW test"
	@echo "========================================="
	@echo ""
	@echo "--- ARP ---"
	arping -I $(PC_IFACE) -c 4 $(FPGA_IP)
	@echo ""
	@echo "--- ICMP ---"
	ping -I $(PC_IFACE) -c 6 $(FPGA_IP)
	@echo ""
	@echo "--- UDP echo (port $(FPGA_UDP_ECHO_PORT)) ---"
	python3 tools/test_udp_echo.py \
	  --ip $(FPGA_IP) --port $(FPGA_UDP_ECHO_PORT) \
	  --count $(UDP_ECHO_COUNT) $(UDP_ECHO_VERBOSE)
	@echo ""
	@echo "--- UDP echo large (1464 B) ---"
	python3 tools/test_udp_echo.py \
	  --ip $(FPGA_IP) --port $(FPGA_UDP_ECHO_PORT) \
	  --count 5 --payload-bytes 1464 $(UDP_ECHO_VERBOSE)
	@echo ""
	@echo "========================================="
	@echo "  test-stack COMPLETE"
	@echo "========================================="

# Capture trace while running full stack test
trace-stack: arp-setup
	@echo "Starting tcpdump capture ..."
	@PCAP=/tmp/eth04_stack_$$(date +%Y%m%d_%H%M%S).pcapng; \
	sudo tcpdump -i $(PC_IFACE) -w $$PCAP \
	  'ether host $(FPGA_MAC) or host $(FPGA_IP) or arp or icmp' 2>/dev/null & \
	DUMP_PID=$$!; \
	sleep 0.5; \
	echo "Capture PID=$$DUMP_PID  file=$$PCAP"; \
	arping -I $(PC_IFACE) -c 4 $(FPGA_IP) || true; \
	ping -I $(PC_IFACE) -c 6 $(FPGA_IP) || true; \
	python3 tools/test_udp_echo.py \
	  --ip $(FPGA_IP) --port $(FPGA_UDP_ECHO_PORT) \
	  --count $(UDP_ECHO_COUNT) $(UDP_ECHO_VERBOSE) || true; \
	sleep 0.5; \
	sudo kill $$DUMP_PID 2>/dev/null; wait $$DUMP_PID 2>/dev/null; \
	echo "Capture saved: $$PCAP"; \
	sudo chown $(USER) $$PCAP 2>/dev/null || true
