SHELL      := bash
.SHELLFLAGS := -o pipefail -c

# ── RTL paths ─────────────────────────────────────────────────────────────────
RTL      := ../rtl
RTL_UART := $(RTL)/uart

LOGDIR ?= logs

VLOG := vlog -sv -suppress 2892
VSIM := vsim -c -do "run -all; quit"

# ── Shared file groups ────────────────────────────────────────────────────────
UART_SRCS := \
  $(RTL_UART)/uart_pkg.sv \
  $(RTL_UART)/uart_baud_gen.sv \
  $(RTL_UART)/uart_core_rx.sv \
  $(RTL_UART)/uart_core_tx.sv \
  $(RTL_UART)/uart.sv

.PHONY: all unit integration regression clean

all: unit integration

unit: uart_baud_gen uart_core_tx uart_core_rx

integration: uart_loopback

$(LOGDIR):
	mkdir -p $(LOGDIR)

# ── Unit tests ────────────────────────────────────────────────────────────────

uart_baud_gen: $(LOGDIR)
	$(VLOG) $(RTL_UART)/uart_baud_gen.sv unit/tb_uart_baud_gen.sv
	$(VSIM) tb_uart_baud_gen | tee $(LOGDIR)/tb_uart_baud_gen.log

uart_core_tx: $(LOGDIR)
	$(VLOG) $(UART_SRCS) unit/tb_uart_core_tx.sv
	$(VSIM) tb_uart_core_tx | tee $(LOGDIR)/tb_uart_core_tx.log

uart_core_rx: $(LOGDIR)
	$(VLOG) $(UART_SRCS) unit/tb_uart_core_rx.sv
	$(VSIM) tb_uart_core_rx | tee $(LOGDIR)/tb_uart_core_rx.log

# ── Integration tests ─────────────────────────────────────────────────────────

uart_loopback: $(LOGDIR)
	$(VLOG) $(UART_SRCS) \
	        $(RTL)/uart_stream_loopback_status.sv \
	        integration/tb_uart_loopback.sv
	$(VSIM) tb_uart_loopback | tee $(LOGDIR)/tb_uart_loopback.log

# ── Regression ────────────────────────────────────────────────────────────────

regression: all
	@if grep -ql "^# FAIL\|\*\* Fatal:" $(LOGDIR)/tb_*.log 2>/dev/null; then \
		echo "============================================"; \
		echo " UART_TEST_02 REGRESSION FAILED"; \
		echo "============================================"; \
		grep -h "^# FAIL\|\*\* Fatal:" $(LOGDIR)/tb_*.log 2>/dev/null || true; \
		exit 1; \
	else \
		echo "============================================"; \
		echo " UART_TEST_02 REGRESSION PASSED"; \
		echo "============================================"; \
	fi

clean:
	rm -rf work transcript *.log $(LOGDIR)
