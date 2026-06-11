SHELL      := bash
.SHELLFLAGS := -o pipefail -c

# -- RTL paths ----------------------------------------------------------------
RTL      := ../rtl
RTL_LIB  := ../../../rtl

LOGDIR ?= logs

VLOG := vlog -sv -suppress 2892
VSIM := vsim -c -do "run -all; quit"

# -- Source groups ------------------------------------------------------------
AXI_SRCS := \
  $(RTL_LIB)/axi/axi_pkg.sv \
  $(RTL_LIB)/axi/axi_interfaces.sv

UART_SRCS := \
  $(RTL_LIB)/uart/uart_pkg.sv \
  $(RTL_LIB)/uart/uart_baud_gen.sv \
  $(RTL_LIB)/uart/uart_core_rx.sv \
  $(RTL_LIB)/uart/uart_core_rx_os.sv \
  $(RTL_LIB)/uart/uart_core_tx.sv \
  $(RTL_LIB)/uart/uart.sv \
  $(RTL_LIB)/uart/uart_os.sv \
  $(RTL_LIB)/uart/sync_fifo.sv \
  $(RTL_LIB)/uart/uart_fifo.sv \
  $(RTL_LIB)/uart/uart_fifo_os.sv \
  $(RTL_LIB)/uart/uart_axil.sv

TOP_SRCS := \
  $(RTL)/axil_uart_loopback.sv \
  $(RTL)/uart_test_05_axil_top.sv

.PHONY: all sim clean

all: sim

$(LOGDIR):
	mkdir -p $(LOGDIR)

sim: $(LOGDIR)
	$(VLOG) $(AXI_SRCS) $(UART_SRCS) $(TOP_SRCS) \
	        unit/tb_uart_test_05_axil_top.sv
	$(VSIM) tb_uart_test_05_axil_top | tee $(LOGDIR)/tb_uart_test_05_axil_top.log
	@if grep -q "^# FAIL\|^FAIL\|\*\* Fatal:" $(LOGDIR)/tb_uart_test_05_axil_top.log; then \
		echo "FAIL: tb_uart_test_05_axil_top"; exit 1; \
	else \
		echo "PASS: tb_uart_test_05_axil_top"; \
	fi

clean:
	rm -rf work transcript *.log $(LOGDIR)
