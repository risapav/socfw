SHELL      := bash
.SHELLFLAGS := -o pipefail -c

# -- RTL paths ----------------------------------------------------------------
RTL      := ../rtl
RTL_UART := $(RTL)/uart

LOGDIR ?= logs

VLOG := vlog -sv -suppress 2892
VSIM := vsim -c -do "run -all; quit"

# -- Shared file groups -------------------------------------------------------
UART_BASE_SRCS := \
  $(RTL_UART)/uart_pkg.sv \
  $(RTL_UART)/uart_baud_gen.sv \
  $(RTL_UART)/uart_core_rx.sv \
  $(RTL_UART)/uart_core_rx_os.sv \
  $(RTL_UART)/uart_core_tx.sv \
  $(RTL_UART)/uart.sv \
  $(RTL_UART)/uart_os.sv

FIFO_SRCS := \
  $(RTL_UART)/sync_fifo.sv \
  $(RTL_UART)/uart_fifo.sv \
  $(RTL_UART)/uart_fifo_os.sv

.PHONY: all unit integration regression clean

all: unit integration

unit: uart_core_rx_os

integration: uart_fifo_loopback_os

$(LOGDIR):
	mkdir -p $(LOGDIR)

# -- Unit tests ---------------------------------------------------------------

uart_core_rx_os: $(LOGDIR)
	$(VLOG) $(RTL_UART)/uart_pkg.sv \
	        $(RTL_UART)/uart_baud_gen.sv \
	        $(RTL_UART)/uart_core_rx_os.sv \
	        unit/tb_uart_core_rx_os.sv
	$(VSIM) tb_uart_core_rx_os | tee $(LOGDIR)/tb_uart_core_rx_os.log

# -- Integration tests --------------------------------------------------------

uart_fifo_loopback_os: $(LOGDIR)
	$(VLOG) $(UART_BASE_SRCS) $(FIFO_SRCS) \
	        $(RTL)/uart_stream_loopback_status.sv \
	        integration/tb_uart_fifo_loopback_os.sv
	$(VSIM) tb_uart_fifo_loopback_os | tee $(LOGDIR)/tb_uart_fifo_loopback_os.log

# -- Regression ---------------------------------------------------------------

regression: all
	@if grep -ql "^# FAIL\|^FAIL\|\*\* Fatal:" $(LOGDIR)/tb_*.log 2>/dev/null; then \
		echo "============================================"; \
		echo " UART_TEST_04 REGRESSION FAILED"; \
		echo "============================================"; \
		grep -h "^# FAIL\|^FAIL\|\*\* Fatal:" $(LOGDIR)/tb_*.log 2>/dev/null || true; \
		exit 1; \
	else \
		echo "============================================"; \
		echo " UART_TEST_04 REGRESSION PASSED"; \
		echo "============================================"; \
	fi

clean:
	rm -rf work transcript *.log $(LOGDIR)
