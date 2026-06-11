include ../../Makefile.common

# -----------------------------------------------------------------------------
# uart_test_04 -- 16x oversampled UART FIFO loopback demo
# -----------------------------------------------------------------------------
#
# Board: QMTech EP4CE55
# Takt: 125 MHz (PLL: 50 MHz -> 125 MHz)
# Nove oproti uart_test_03:
#   uart_core_rx_os.sv -- 16x oversampled RX, majority vote (ticks 6,7,8)
#   uart_os.sv         -- UART wrapper: OS RX + standard TX
#   uart_fifo_os.sv    -- FIFO wrapper pouzivajuci uart_os
#
# RX baud gen: PRESCALE_OS = round(125 MHz / (115200 * 16)) = 68
# Sample center: OS tick 8 z 16 (~544 clk po falling edge, odchylka 1.5 clk)
# Glitch filter: false start odmietnuty ak RXD==1 v strede start bitu
#
# UART:  115200 8N1, echo loopback cez FIFO
# LEDs:  RX/TX pulse, RX/TX busy, error latch, heartbeat (~1 Hz)
# -----------------------------------------------------------------------------

UART_PORT ?= /dev/ttyUSB0
UART_BAUD ?= 115200
HW_COUNT  ?= 256

.PHONY: sim sim-unit sim-integration sim-regression sim-clean
.PHONY: hw-test hw-test-quick hw-sweep

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
# HW board test
# -----------------------------------------------------------------------------

hw-test:
	@echo "[HW] UART OS loopback test -- $(UART_PORT) @ $(UART_BAUD) baud, $(HW_COUNT) bajtov"
	python3 tools/test_loopback.py \
	    --port $(UART_PORT) --baud $(UART_BAUD) --count $(HW_COUNT) --verbose

hw-test-quick:
	@echo "[HW] UART OS loopback quick test -- $(UART_PORT) @ $(UART_BAUD) baud"
	python3 tools/test_loopback.py \
	    --port $(UART_PORT) --baud $(UART_BAUD) --count 8 --verbose

hw-sweep:
	@echo "[HW] UART OS sweep test -- cs=1,8,16,24,25,26,32,64 x5 -- $(UART_PORT)"
	python3 tools/test_loopback.py \
	    --port $(UART_PORT) --baud $(UART_BAUD) --count $(HW_COUNT) \
	    --sweep-chunks 1,8,16,24,25,26,32,64 --repeat 5

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------

.PHONY: help
help:
	@echo "uart_test_04 -- 16x oversampled UART FIFO loopback demo"
	@echo "========================================================"
	@echo ""
	@echo "Simulacia (Questa):"
	@echo "  make sim              Plna regresia (unit + integration)"
	@echo "  make sim-unit         Unit testy (tb_uart_core_rx_os)"
	@echo "  make sim-integration  Integracny test (tb_uart_fifo_loopback_os)"
	@echo "  make sim-clean        Vycisti work/ a logy"
	@echo ""
	@echo "HW board test (QMTech EP4CE55):"
	@echo "  make hw-test          Loopback: $(HW_COUNT) bajtov bulk @ $(UART_PORT):$(UART_BAUD)"
	@echo "  make hw-test-quick    Loopback: 8 bajtov (rychly smoke test)"
	@echo "  make hw-sweep         Sweep cs=1..64 x5 (CP2102 boundary diagnostika)"
	@echo "  UART_PORT, UART_BAUD, HW_COUNT su konfigurovatelne"
	@echo ""
	@echo "Quartus:"
	@echo "  make gen              socfw build (generuj RTL + HAL)"
	@echo "  make compile          Plny flow: syn -> fit -> asm -> sta"
	@echo "  make timing           Zobraz Fmax z posledneho STA reportu"
	@echo "  make program          Naprogramuj FPGA (USB-Blaster)"
	@echo "  make full             gen + compile"
	@echo ""
	@echo "Ostatne:"
	@echo "  make lint             svlint na RTL (vyzaduje make gen)"
	@echo "  make clean            Vymazat build/ a Quartus artefakty"
