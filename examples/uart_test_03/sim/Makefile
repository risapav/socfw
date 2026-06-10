SHELL      := bash
.SHELLFLAGS := -o pipefail -c

# -- RTL paths ----------------------------------------------------------------
RTL      := ../rtl
RTL_UART := $(RTL)/uart

LOGDIR ?= logs

VLOG := vlog -sv -suppress 2892
VSIM := vsim -c -do "run -all; quit"

# -- Shared file groups -------------------------------------------------------
UART_SRCS := \
  $(RTL_UART)/uart_pkg.sv \
  $(RTL_UART)/uart_baud_gen.sv \
  $(RTL_UART)/uart_core_rx.sv \
  $(RTL_UART)/uart_core_tx.sv \
  $(RTL_UART)/uart.sv

FIFO_SRCS := \
  $(RTL_UART)/sync_fifo.sv \
  $(RTL_UART)/uart_fifo.sv

.PHONY: all unit integration regression clean

all: unit integration

unit: sync_fifo

integration: uart_fifo_loopback

$(LOGDIR):
	mkdir -p $(LOGDIR)

# -- Unit tests ---------------------------------------------------------------

sync_fifo: $(LOGDIR)
	$(VLOG) $(RTL_UART)/sync_fifo.sv unit/tb_sync_fifo.sv
	$(VSIM) tb_sync_fifo | tee $(LOGDIR)/tb_sync_fifo.log

# -- Integration tests --------------------------------------------------------

uart_fifo_loopback: $(LOGDIR)
	$(VLOG) $(UART_SRCS) $(FIFO_SRCS) \
	        $(RTL)/uart_stream_loopback_status.sv \
	        integration/tb_uart_fifo_loopback.sv
	$(VSIM) tb_uart_fifo_loopback | tee $(LOGDIR)/tb_uart_fifo_loopback.log

# -- Regression ---------------------------------------------------------------

regression: all
	@if grep -ql "^# FAIL\|\*\* Fatal:" $(LOGDIR)/tb_*.log 2>/dev/null; then \
		echo "============================================"; \
		echo " UART_TEST_03 REGRESSION FAILED"; \
		echo "============================================"; \
		grep -h "^# FAIL\|\*\* Fatal:" $(LOGDIR)/tb_*.log 2>/dev/null || true; \
		exit 1; \
	else \
		echo "============================================"; \
		echo " UART_TEST_03 REGRESSION PASSED"; \
		echo "============================================"; \
	fi

clean:
	rm -rf work transcript *.log $(LOGDIR)
