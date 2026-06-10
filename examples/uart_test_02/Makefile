include ../../Makefile.common

# -----------------------------------------------------------------------------
# uart_test_02 -- Enhanced UART loopback demo
# -----------------------------------------------------------------------------
#
# Board: QMTech EP4CE55
# Takt: 125 MHz (PLL: 50 MHz -> 125 MHz)
# Fazy: 1 RTL, 2A integracne opravy, 2B sim BFM, 2C uart_03.md cleanup
#
# UART:  115200 8N1, echo loopback
# LEDs:  RX/TX pulse, RX/TX busy, error latch, heartbeat (~1 Hz)
# -----------------------------------------------------------------------------

UART_PORT ?= /dev/ttyUSB0
UART_BAUD ?= 115200
HW_COUNT  ?= 64

.PHONY: sim sim-unit sim-integration sim-regression sim-clean
.PHONY: hw-test hw-test-quick

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
	@echo "[HW] UART loopback test -- $(UART_PORT) @ $(UART_BAUD) baud, $(HW_COUNT) bajtov"
	python3 tools/test_loopback.py \
	    --port $(UART_PORT) --baud $(UART_BAUD) --count $(HW_COUNT) --verbose

hw-test-quick:
	@echo "[HW] UART loopback quick test -- $(UART_PORT) @ $(UART_BAUD) baud"
	python3 tools/test_loopback.py \
	    --port $(UART_PORT) --baud $(UART_BAUD) --count 8 --verbose

# -----------------------------------------------------------------------------
# Help (override Makefile.common)
# -----------------------------------------------------------------------------

.PHONY: help
help:
	@echo "uart_test_02 — Enhanced UART loopback demo"
	@echo "==========================================="
	@echo ""
	@echo "Simulacia (Questa):"
	@echo "  make sim              Plna regresia (unit + integration)"
	@echo "  make sim-unit         Unit testy (tb_uart_core_tx, tb_uart_core_rx)"
	@echo "  make sim-integration  Integracny test (tb_uart_loopback)"
	@echo "  make sim-clean        Vycisti work/ a logy"
	@echo ""
	@echo "HW board test (QMTech EP4CE55):"
	@echo "  make hw-test          Loopback: $(HW_COUNT) bajtov @ $(UART_PORT):$(UART_BAUD)"
	@echo "  make hw-test-quick    Loopback: 8 bajtov (rychly smoke test)"
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
