include ../../Makefile.common

# -----------------------------------------------------------------------------
# uart_test_05_axil -- AXI-Lite UART peripheral loopback demo
# -----------------------------------------------------------------------------
#
# Board:   QMTech EP4CE55
# Clock:   125 MHz (PLL: 50 MHz -> 125 MHz)
# UART:    115200 8N1, loopback via AXI-Lite master FSM
#
# Data path:
#   UART RX -> uart_axil RX FIFO -> axil_uart_loopback -> uart_axil TX FIFO -> UART TX
#
# Difference from uart_test_04:
#   uart_test_04 uses direct AXI-Stream loopback (uart_stream_loopback_status)
#   uart_test_05_axil goes through AXI-Lite registers (STATUS poll + RX_DATA + TX_DATA)
#   This verifies uart_axil.sv in a synthesized, hardware-tested context.
# -----------------------------------------------------------------------------

UART_PORT ?= /dev/ttyUSB0
UART_BAUD ?= 115200
HW_COUNT  ?= 256

.PHONY: sim sim-clean hw-test hw-test-quick

sim:
	$(MAKE) -C sim all

sim-clean:
	$(MAKE) -C sim clean

hw-test:
	@echo "[HW] UART axil loopback -- $(UART_PORT) @ $(UART_BAUD) baud, $(HW_COUNT) bajtov"
	python3 ../uart_test_04/tools/test_loopback.py \
	    --port $(UART_PORT) --baud $(UART_BAUD) --count $(HW_COUNT) --verbose

hw-test-quick:
	@echo "[HW] UART axil loopback quick -- $(UART_PORT) @ $(UART_BAUD) baud"
	python3 ../uart_test_04/tools/test_loopback.py \
	    --port $(UART_PORT) --baud $(UART_BAUD) --count 8 --verbose

.PHONY: help
help:
	@echo "uart_test_05_axil -- AXI-Lite UART peripheral loopback demo"
	@echo "============================================================="
	@echo ""
	@echo "Simulacia:"
	@echo "  make sim        Spusti TB (T01-T04, 512B LFSR)"
	@echo "  make sim-clean  Vycisti work/"
	@echo ""
	@echo "HW board test:"
	@echo "  make hw-test        Loopback: $(HW_COUNT)B bulk @ $(UART_PORT):$(UART_BAUD)"
	@echo "  make hw-test-quick  Loopback: 8B smoke test"
	@echo ""
	@echo "Quartus:"
	@echo "  make gen        socfw build (generuj RTL + HAL)"
	@echo "  make compile    Plny Quartus flow"
	@echo "  make program    Naprogramuj FPGA"
	@echo "  make full       gen + compile"
