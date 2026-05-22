SHELL      := bash
.SHELLFLAGS := -o pipefail -c

# RTL paths
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

# ── Zdielane skupiny suborov ─────────────────────────────────────────

AXI_COMMON = \
	$(RTL_AXI)/axi_pkg.sv \
	$(RTL_AXI)/axi_interfaces.sv

UART_COMMON = \
	$(RTL_UART)/uart_pkg.sv \
	$(RTL_UART)/uart_baud_gen.sv \
	$(RTL_UART)/uart_core_rx.sv \
	$(RTL_UART)/uart_core_tx.sv \
	$(RTL_UART)/uart.sv

AXIS_UART = \
	$(RTL_AXIS)/axis_uart_rx.sv \
	$(RTL_AXIS)/axis_uart_tx.sv

XFCP_COMMON = \
	$(RTL_XFCP)/xfcp_pkg.sv \
	$(RTL_XFCP)/xfcp_fifo.sv \
	$(RTL_XFCP)/xfcp_rx_parser.sv \
	$(RTL_XFCP)/xfcp_tx_packetizer.sv \
	$(RTL_XFCP)/xfcp_axi_engine.sv \
	$(RTL_XFCP)/xfcp_fabric_endpoint.sv

XFCP_BRIDGE = \
	$(RTL_XFCP)/xfcp_pkg.sv \
	$(RTL_XFCP)/xfcp_fifo.sv \
	$(RTL_XFCP)/xfcp_rx_parser.sv \
	$(RTL_XFCP)/xfcp_tx_packetizer.sv \
	$(RTL_XFCP)/xfcp_axi_engine.sv \
	$(RTL_XFCP)/xfcp_axil_bridge.sv

XFCP_PARSER = \
	$(RTL_XFCP)/xfcp_pkg.sv \
	$(RTL_XFCP)/xfcp_fifo.sv \
	$(RTL_XFCP)/xfcp_rx_parser.sv

AXIL_COMMON = \
	$(RTL_AXIL)/axil_regfile.sv

.PHONY: all unit integration regression report clean \
        axil_regfile axil_sys_ctrl axil_seven_seg_adapter axil_uart_adapter \
        axil_regs uart_core_rx \
        xfcp_rx_parser xfcp_tx_packetizer xfcp_axi_engine \
        xfcp_axil_bridge xfcp_fabric_endpoint xfcp_uart_mmio_top \
        xfcp_backpressure

# ── Defaultny ciel: vsetky testy ─────────────────────────────────────

all: unit integration

unit: axil_regfile axil_sys_ctrl axil_seven_seg_adapter axil_uart_adapter \
      axil_regs uart_core_rx \
      xfcp_rx_parser xfcp_tx_packetizer xfcp_axi_engine

integration: xfcp_axil_bridge xfcp_fabric_endpoint xfcp_uart_mmio_top xfcp_backpressure

$(LOGDIR):
	mkdir -p $(LOGDIR)

# ── Regression ───────────────────────────────────────────────────────

regression: all
	@if grep -ql "FAIL\|\*\* Fatal:" $(LOGDIR)/tb_*.log 2>/dev/null; then \
		echo "======================================"; \
		echo " XFCP_TEST_02 REGRESSION FAILED"; \
		echo "======================================"; \
		exit 1; \
	else \
		echo "======================================"; \
		echo " XFCP_TEST_02 REGRESSION PASSED"; \
		echo "======================================"; \
	fi

report: clean $(LOGDIR)
	$(MAKE) regression 2>&1 | tee $(LOGDIR)/regression_full.log

# ── Unit testy — AXI-Lite periferie ──────────────────────────────────

axil_regfile: $(LOGDIR)
	$(VLOG) $(AXI_COMMON) \
	        $(RTL_AXIL)/axil_regfile.sv \
	        unit/tb_axil_regfile.sv
	$(VSIM) tb_axil_regfile | tee $(LOGDIR)/tb_axil_regfile.log

axil_sys_ctrl: $(LOGDIR)
	$(VLOG) $(AXI_COMMON) \
	        $(AXIL_COMMON) \
	        $(RTL_AXIL)/axil_sys_ctrl.sv \
	        unit/tb_axil_sys_ctrl.sv
	$(VSIM) tb_axil_sys_ctrl | tee $(LOGDIR)/tb_axil_sys_ctrl.log

axil_seven_seg_adapter: $(LOGDIR)
	$(VLOG) $(AXI_COMMON) \
	        $(AXIL_COMMON) \
	        $(RTL_SEG)/seven_seg_mux.sv \
	        $(RTL_SEG)/seven_seg_mux_packed.sv \
	        $(RTL_AXIL)/axil_seven_seg_adapter.sv \
	        unit/tb_axil_seven_seg_adapter.sv
	$(VSIM) tb_axil_seven_seg_adapter | tee $(LOGDIR)/tb_axil_seven_seg_adapter.log

axil_uart_adapter: $(LOGDIR)
	$(VLOG) $(AXI_COMMON) \
	        $(AXIL_COMMON) \
	        $(RTL_AXIL)/axil_uart_adapter.sv \
	        unit/tb_axil_uart_adapter.sv
	$(VSIM) tb_axil_uart_adapter | tee $(LOGDIR)/tb_axil_uart_adapter.log

axil_regs: $(LOGDIR)
	$(VLOG) $(AXI_COMMON) \
	        $(AXIL_COMMON) \
	        $(RTL_AXIL)/axil_regs.sv \
	        unit/tb_axil_regs.sv
	$(VSIM) tb_axil_regs | tee $(LOGDIR)/tb_axil_regs.log

# ── Unit testy — UART ─────────────────────────────────────────────────

uart_core_rx: $(LOGDIR)
	$(VLOG) $(AXI_COMMON) \
	        $(UART_COMMON) \
	        $(RTL_AXIS)/axis_uart_rx.sv \
	        unit/tb_uart_core_rx.sv
	$(VSIM) tb_uart_core_rx | tee $(LOGDIR)/tb_uart_core_rx.log

# ── Unit testy — XFCP stack ───────────────────────────────────────────

xfcp_rx_parser: $(LOGDIR)
	$(VLOG) $(AXI_COMMON) \
	        $(XFCP_PARSER) \
	        unit/tb_xfcp_rx_parser.sv
	$(VSIM) tb_xfcp_rx_parser | tee $(LOGDIR)/tb_xfcp_rx_parser.log

xfcp_tx_packetizer: $(LOGDIR)
	$(VLOG) $(AXI_COMMON) \
	        $(RTL_XFCP)/xfcp_pkg.sv \
	        $(RTL_XFCP)/xfcp_fifo.sv \
	        $(RTL_XFCP)/xfcp_tx_packetizer.sv \
	        unit/tb_xfcp_tx_packetizer.sv
	$(VSIM) tb_xfcp_tx_packetizer | tee $(LOGDIR)/tb_xfcp_tx_packetizer.log

xfcp_axi_engine: $(LOGDIR)
	$(VLOG) $(AXI_COMMON) \
	        $(RTL_XFCP)/xfcp_pkg.sv \
	        $(RTL_XFCP)/xfcp_fifo.sv \
	        $(RTL_XFCP)/xfcp_axi_engine.sv \
	        $(RTL_AXIL)/axil_slave_model.sv \
	        unit/tb_xfcp_axi_engine.sv
	$(VSIM) tb_xfcp_axi_engine | tee $(LOGDIR)/tb_xfcp_axi_engine.log

# ── Integracne testy ──────────────────────────────────────────────────

xfcp_axil_bridge: $(LOGDIR)
	$(VLOG) $(AXI_COMMON) \
	        $(XFCP_BRIDGE) \
	        $(RTL_AXIL)/axil_slave_model.sv \
	        integration/tb_xfcp_axil_bridge.sv
	$(VSIM) tb_xfcp_axil_bridge | tee $(LOGDIR)/tb_xfcp_axil_bridge.log

xfcp_fabric_endpoint: $(LOGDIR)
	$(VLOG) $(AXI_COMMON) \
	        $(XFCP_COMMON) \
	        $(RTL_AXIL)/axil_slave_model.sv \
	        integration/tb_xfcp_fabric_endpoint.sv
	$(VSIM) tb_xfcp_fabric_endpoint | tee $(LOGDIR)/tb_xfcp_fabric_endpoint.log

xfcp_uart_mmio_top: $(LOGDIR)
	$(VLOG) $(AXI_COMMON) \
	        $(UART_COMMON) \
	        $(AXIS_UART) \
	        $(AXIL_COMMON) \
	        $(RTL_AXIL)/axil_sys_ctrl.sv \
	        $(RTL_AXIL)/axil_uart_adapter.sv \
	        $(RTL_AXIL)/axil_regs.sv \
	        $(RTL_AXIL)/axil_seven_seg_adapter.sv \
	        $(RTL_AXIL)/axil_diag_ctrl.sv \
	        $(RTL_SEG)/seven_seg_mux.sv \
	        $(RTL_SEG)/seven_seg_mux_packed.sv \
	        $(XFCP_COMMON) \
	        ../rtl/xfcp_uart_mmio_top.sv \
	        integration/tb_xfcp_uart_mmio_top.sv
	$(VSIM) tb_xfcp_uart_mmio_top | tee $(LOGDIR)/tb_xfcp_uart_mmio_top.log

xfcp_backpressure: $(LOGDIR)
	$(VLOG) $(AXI_COMMON) \
	        $(XFCP_COMMON) \
	        $(RTL_AXIL)/axil_slave_model.sv \
	        integration/tb_xfcp_backpressure.sv
	$(VSIM) tb_xfcp_backpressure | tee $(LOGDIR)/tb_xfcp_backpressure.log

clean:
	rm -rf work transcript *.log $(LOGDIR)
