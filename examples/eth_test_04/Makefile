include ../../Makefile.common

# FPGA network config
FPGA_IP  := 192.168.0.2
FPGA_MAC := 00:0a:35:01:fe:c0
FPGA_UDP_PORT := 8080
PC_IFACE := enp0s31f6

# UART tap config (CP2102N on board)
TAP_PORT  := /dev/ttyUSB0
TAP_BAUD  := 115200
TAP_BYTES := 20

.PHONY: sim sim-unit sim-integration sim-regression sim-clean
.PHONY: arp-setup arp-show udp-send udp-test tcpdump hw-test fpga-test tap-test wire-test
.PHONY: loopback-test loopback-test-bcast loopback-sniff

# --- Simulation ---

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

# --- HW test helpers ---

arp-setup:
	sudo ip neigh replace $(FPGA_IP) lladdr $(FPGA_MAC) nud permanent dev $(PC_IFACE)
	@echo "Static ARP set: $(FPGA_IP) -> $(FPGA_MAC) on $(PC_IFACE)"

arp-show:
	ip neigh show dev $(PC_IFACE)

udp-send:
	echo -n "HELLO" | nc -u -w1 $(FPGA_IP) $(FPGA_UDP_PORT)

udp-test: arp-setup
	@echo "=== UDP echo test -> $(FPGA_IP):$(FPGA_UDP_PORT) ==="
	echo -n "HI"                        | nc -u -w1 $(FPGA_IP) $(FPGA_UDP_PORT)
	echo -n "HELLO"                     | nc -u -w1 $(FPGA_IP) $(FPGA_UDP_PORT)
	echo -n "0123456789ABCDEF"          | nc -u -w1 $(FPGA_IP) $(FPGA_UDP_PORT)
	python3 -c "print('X'*64, end='')"  | nc -u -w1 $(FPGA_IP) $(FPGA_UDP_PORT)
	@echo "=== Done — check tcpdump output ==="

tcpdump:
	sudo tcpdump -i $(PC_IFACE) -e -n -XX \
	    'ether host $(FPGA_MAC) or udp port $(FPGA_UDP_PORT)'

fpga-test:
	python3 test_fpga.py --ip $(FPGA_IP) --port $(FPGA_UDP_PORT) \
	                     --mac $(FPGA_MAC) --iface $(PC_IFACE)

wire-test: arp-setup
	@echo "=== Wire-level capture: DST MAC on $(PC_IFACE) ==="
	@sudo tcpdump -i $(PC_IFACE) -e -n 'udp port $(FPGA_UDP_PORT)' & \
	 DUMP_PID=$$!; \
	 sleep 0.5; \
	 python3 test_fpga.py --ip $(FPGA_IP) --port $(FPGA_UDP_PORT) \
	                      --mac $(FPGA_MAC) --iface $(PC_IFACE) --no-arp; \
	 sleep 0.5; \
	 sudo kill $$DUMP_PID 2>/dev/null; \
	 wait $$DUMP_PID 2>/dev/null; \
	 true

tap-test: arp-setup
	@echo ""
	@echo "=== UART tap ($(TAP_PORT) @ $(TAP_BAUD)) + UDP echo test ==="
	@echo ""
	@python3 tools/read_tap.py \
	     --port $(TAP_PORT) --baud $(TAP_BAUD) --count $(TAP_BYTES) --frames 0 & \
	 TAP_PID=$$!; \
	 sleep 0.5; \
	 python3 test_fpga.py --ip $(FPGA_IP) --port $(FPGA_UDP_PORT) \
	                      --mac $(FPGA_MAC) --iface $(PC_IFACE) --no-arp; \
	 sleep 2; \
	 kill $$TAP_PID 2>/dev/null; \
	 wait $$TAP_PID 2>/dev/null; \
	 true

loopback-test:
	sudo python3 test_loopback.py --iface $(PC_IFACE) --fpga-mac $(FPGA_MAC) --mode clean

loopback-test-bcast:
	sudo python3 test_loopback.py --iface $(PC_IFACE) --fpga-mac $(FPGA_MAC) --mode clean --broadcast

loopback-test-raw:
	sudo python3 test_loopback.py --iface $(PC_IFACE) --fpga-mac $(FPGA_MAC) --mode raw

loopback-sniff:
	sudo python3 test_loopback.py --iface $(PC_IFACE) --sniff

hw-test: arp-setup
	@echo "Starting tcpdump in background (log: /tmp/eth_test_04_capture.pcap) ..."
	sudo tcpdump -i $(PC_IFACE) -w /tmp/eth_test_04_capture.pcap \
	    'ether host $(FPGA_MAC) or udp port $(FPGA_UDP_PORT)' &
	sleep 1
	@echo "Sending test packets ..."
	echo -n "HI"               | nc -u -w1 $(FPGA_IP) $(FPGA_UDP_PORT)
	echo -n "HELLO"            | nc -u -w1 $(FPGA_IP) $(FPGA_UDP_PORT)
	echo -n "0123456789ABCDEF" | nc -u -w1 $(FPGA_IP) $(FPGA_UDP_PORT)
	sleep 2
	sudo pkill -f "tcpdump.*eth_test_04" || true
	@echo "Capture saved to /tmp/eth_test_04_capture.pcap"
	@echo "Read with: tcpdump -r /tmp/eth_test_04_capture.pcap -e -n -XX"
