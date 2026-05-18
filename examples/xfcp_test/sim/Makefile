SHELL      := bash
.SHELLFLAGS := -o pipefail -c

RTL_AXI  ?= ../rtl/axi
RTL_AXIL ?= ../rtl/axil
RTL_AXIS ?= ../rtl/axis
RTL_UART ?= ../rtl/uart
RTL_XFCP ?= ../rtl/xfcp
RTL_BUF  ?= ../rtl/buffer
RTL_SEG  ?= ../rtl/segment

LOGDIR ?= logs

VLOG := vlog -sv -suppress 2892
VSIM := vsim -c -do "run -all; quit"

# AXI infrastructure — required by all axil/* tests
AXI_COMMON = \
	$(RTL_AXI)/axi_pkg.sv \
	$(RTL_AXI)/axi_interfaces.sv

# UART infrastructure
UART_COMMON = \
	$(RTL_UART)/uart_pkg.sv \
	$(RTL_UART)/uart_baud_gen.sv \
	$(RTL_UART)/uart_core_rx.sv \
	$(RTL_UART)/uart_core_tx.sv \
	$(RTL_UART)/uart.sv

# AXIS UART wrappers
AXIS_UART = \
	$(RTL_AXIS)/axis_uart_rx.sv \
	$(RTL_AXIS)/axis_uart_tx.sv

# XFCP infrastructure (protocol: SOP=0xFE, WRITE=0x11)
XFCP_COMMON = \
	$(RTL_XFCP)/xfcp_pkg.sv \
	$(RTL_XFCP)/xfcp_fifo.sv \
	$(RTL_XFCP)/xfcp_rx_parser.sv \
	$(RTL_XFCP)/xfcp_tx_packetizer.sv \
	$(RTL_XFCP)/xfcp_axi_engine.sv \
	$(RTL_XFCP)/xfcp_axil_bridge.sv

# Parser-only subset (no engine/packetizer/bridge)
XFCP_PARSER = \
	$(RTL_XFCP)/xfcp_pkg.sv \
	$(RTL_XFCP)/xfcp_fifo.sv \
	$(RTL_XFCP)/xfcp_rx_parser.sv

.PHONY: all regression report clean \
        axil_regfile axil_sys_ctrl axil_seven_seg_adapter axil_uart_adapter \
        axil_regs uart_core_rx xfcp_rx_parser xfcp_axil_bridge xfcp_uart_mmio_top

all: axil_regfile axil_sys_ctrl axil_seven_seg_adapter axil_uart_adapter \
     axil_regs uart_core_rx xfcp_rx_parser xfcp_axil_bridge xfcp_uart_mmio_top

$(LOGDIR):
	mkdir -p $(LOGDIR)

regression: all
	@if grep -ql "FAIL\|\*\* Fatal:" $(LOGDIR)/tb_*.log 2>/dev/null; then \
		echo "======================================"; \
		echo " XFCP SIM REGRESSION FAILED"; \
		echo "======================================"; \
		exit 1; \
	else \
		echo "======================================"; \
		echo " XFCP SIM REGRESSION PASSED"; \
		echo "======================================"; \
	fi

report: clean $(LOGDIR)
	$(MAKE) regression 2>&1 | tee $(LOGDIR)/regression_full.log

axil_regfile: $(LOGDIR)
	$(VLOG) $(AXI_COMMON) \
	        $(RTL_AXIL)/axil_regfile.sv \
	        tb_axil_regfile.sv
	$(VSIM) tb_axil_regfile | tee $(LOGDIR)/tb_axil_regfile.log

axil_sys_ctrl: $(LOGDIR)
	$(VLOG) $(AXI_COMMON) \
	        $(RTL_AXIL)/axil_regfile.sv \
	        $(RTL_AXIL)/axil_sys_ctrl.sv \
	        tb_axil_sys_ctrl.sv
	$(VSIM) tb_axil_sys_ctrl | tee $(LOGDIR)/tb_axil_sys_ctrl.log

axil_seven_seg_adapter: $(LOGDIR)
	$(VLOG) $(AXI_COMMON) \
	        $(RTL_AXIL)/axil_regfile.sv \
	        $(RTL_SEG)/seven_seg_mux.sv \
	        $(RTL_SEG)/seven_seg_mux_packed.sv \
	        $(RTL_AXIL)/axil_seven_seg_adapter.sv \
	        tb_axil_seven_seg_adapter.sv
	$(VSIM) tb_axil_seven_seg_adapter | tee $(LOGDIR)/tb_axil_seven_seg_adapter.log

axil_uart_adapter: $(LOGDIR)
	$(VLOG) $(AXI_COMMON) \
	        $(RTL_AXIL)/axil_regfile.sv \
	        $(RTL_AXIL)/axil_uart_adapter.sv \
	        tb_axil_uart_adapter.sv
	$(VSIM) tb_axil_uart_adapter | tee $(LOGDIR)/tb_axil_uart_adapter.log

axil_regs: $(LOGDIR)
	$(VLOG) $(AXI_COMMON) \
	        $(RTL_AXIL)/axil_regfile.sv \
	        $(RTL_AXIL)/axil_regs.sv \
	        tb_axil_regs.sv
	$(VSIM) tb_axil_regs | tee $(LOGDIR)/tb_axil_regs.log

uart_core_rx: $(LOGDIR)
	$(VLOG) $(AXI_COMMON) \
	        $(UART_COMMON) \
	        $(RTL_AXIS)/axis_uart_rx.sv \
	        tb_uart_core_rx.sv
	$(VSIM) tb_uart_core_rx | tee $(LOGDIR)/tb_uart_core_rx.log

xfcp_rx_parser: $(LOGDIR)
	$(VLOG) $(AXI_COMMON) \
	        $(XFCP_PARSER) \
	        tb_xfcp_rx_parser.sv
	$(VSIM) tb_xfcp_rx_parser | tee $(LOGDIR)/tb_xfcp_rx_parser.log

xfcp_axil_bridge: $(LOGDIR)
	$(VLOG) $(AXI_COMMON) \
	        $(XFCP_COMMON) \
	        $(RTL_AXIL)/axil_slave_model.sv \
	        tb_xfcp_axil_bridge.sv
	$(VSIM) tb_xfcp_axil_bridge | tee $(LOGDIR)/tb_xfcp_axil_bridge.log

xfcp_uart_mmio_top: $(LOGDIR)
	$(VLOG) $(AXI_COMMON) \
	        $(UART_COMMON) \
	        $(AXIS_UART) \
	        $(RTL_AXIL)/axil_regfile.sv \
	        $(RTL_AXIL)/axil_sys_ctrl.sv \
	        $(RTL_AXIL)/axil_uart_adapter.sv \
	        $(RTL_AXIL)/axil_regs.sv \
	        $(RTL_AXIL)/axil_seven_seg_adapter.sv \
	        $(RTL_SEG)/seven_seg_mux.sv \
	        $(RTL_SEG)/seven_seg_mux_packed.sv \
	        $(XFCP_COMMON) \
	        ../rtl/xfcp_uart_mmio_top.sv \
	        tb_xfcp_uart_mmio_top.sv
	$(VSIM) tb_xfcp_uart_mmio_top | tee $(LOGDIR)/tb_xfcp_uart_mmio_top.log

clean:
	rm -rf work transcript *.log $(LOGDIR)
