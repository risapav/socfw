SHELL      := bash
.SHELLFLAGS := -o pipefail -c

# ── RTL cesty ────────────────────────────────────────────────────────────────
SOCFW     ?= ../../../rtl
RTL_AXI   ?= $(SOCFW)/axi
RTL_AXIL  ?= $(SOCFW)/axil
RTL_AXIS  ?= $(SOCFW)/axis
RTL_UART  ?= $(SOCFW)/uart
RTL_BUF   ?= $(SOCFW)/buffer
RTL_STRM  ?= $(SOCFW)/stream
RTL_SEG   ?= $(SOCFW)/segment
RTL_CDC   ?= $(SOCFW)/cdc
RTL_ETH   ?= $(SOCFW)/eth

RTL_XFCP      ?= $(SOCFW)/xfcp
RTL_XFCP_TRAN ?= $(SOCFW)/xfcp/transport
RTL_LCDC  ?= ../rtl/cdc

LOGDIR ?= logs

VLOG := vlog -sv -suppress 2892
VSIM := vsim -c -do "run -all; quit"

# ── Zdielane skupiny suborov ─────────────────────────────────────────────────

AXI_COMMON = \
	$(RTL_AXI)/axi_pkg.sv \
	$(RTL_AXI)/axi_interfaces.sv

UART_COMMON = \
	$(RTL_UART)/uart_pkg.sv \
	$(RTL_UART)/uart_baud_gen.sv \
	$(RTL_UART)/uart_core_rx.sv \
	$(RTL_UART)/uart_core_rx_os.sv \
	$(RTL_UART)/uart_core_tx.sv \
	$(RTL_UART)/uart.sv \
	$(RTL_UART)/uart_os.sv \
	$(RTL_UART)/uart_fifo_os.sv \
	$(RTL_UART)/sync_fifo.sv \
	$(RTL_UART)/uart_fifo.sv

XFCP_COMMON = \
	$(RTL_XFCP)/xfcp_pkg.sv \
	$(RTL_XFCP)/xfcp_fifo.sv \
	$(RTL_XFCP)/xfcp_fifo_reg.sv \
	$(RTL_XFCP)/xfcp_rx_parser.sv \
	$(RTL_XFCP)/xfcp_tx_packetizer.sv \
	$(RTL_XFCP)/xfcp_axi_engine.sv \
	$(RTL_XFCP)/xfcp_axis_adapter.sv \
	$(RTL_XFCP)/xfcp_caps_adapter.sv \
	$(RTL_XFCP)/xfcp_target_info_adapter.sv \
	$(RTL_XFCP)/xfcp_mem_adapter.sv \
	$(RTL_XFCP)/axis_byte_register_slice.sv \
	$(RTL_XFCP)/xfcp_fabric_endpoint.sv

AXIL_COMMON = \
	$(RTL_AXIL)/axil_regfile.sv

ETH_COMMON = \
	$(RTL_ETH)/mac/taxi_lfsr.sv \
	$(RTL_ETH)/mac/eth_crc32_8.sv \
	$(RTL_ETH)/mac/eth_rx_mac.sv \
	$(RTL_ETH)/mac/eth_tx_mac.sv \
	$(RTL_ETH)/util/eth_tx_arb.sv \
	$(RTL_ETH)/util/eth_type_demux.sv \
	$(RTL_ETH)/l2/arp_rx.sv \
	$(RTL_ETH)/l2/arp_tx.sv \
	$(RTL_ETH)/l3/ipv4_rx.sv \
	$(RTL_ETH)/l3/ipv4_tx.sv \
	$(RTL_ETH)/l3/icmp_echo.sv

CDC_COMMON = \
	$(RTL_CDC)/cdc_two_flop_synchronizer.sv \
	$(RTL_LCDC)/async_fifo.sv

.PHONY: all unit integration regression clean

all: unit integration

unit: xfcp_arbiter_2to1 udp_xfcp_server

integration: xfcp_test_12_cpu_mailbox_regs_top

$(LOGDIR):
	mkdir -p $(LOGDIR)

# ── Regression ───────────────────────────────────────────────────────────────

regression: all
	@if grep -ql "FAIL\|\*\* Fatal:" $(LOGDIR)/tb_*.log 2>/dev/null; then \
		echo "======================================"; \
		echo " XFCP_TEST_12 REGRESSION FAILED"; \
		echo "======================================"; \
		exit 1; \
	else \
		echo "======================================"; \
		echo " XFCP_TEST_12 REGRESSION PASSED"; \
		echo "======================================"; \
	fi

# ── Unit testy ───────────────────────────────────────────────────────────────

xfcp_arbiter_2to1: $(LOGDIR)
	$(VLOG) $(AXI_COMMON) \
	        $(RTL_XFCP)/xfcp_pkg.sv \
	        $(RTL_XFCP)/xfcp_arbiter_2to1.sv \
	        unit/tb_xfcp_arbiter_2to1.sv
	$(VSIM) tb_xfcp_arbiter_2to1 | tee $(LOGDIR)/tb_xfcp_arbiter_2to1.log

udp_xfcp_server: $(LOGDIR)
	$(VLOG) $(AXI_COMMON) \
	        $(RTL_XFCP)/xfcp_pkg.sv \
	        $(RTL_XFCP_TRAN)/udp_xfcp_server.sv \
	        unit/tb_udp_xfcp_server.sv
	$(VSIM) tb_udp_xfcp_server | tee $(LOGDIR)/tb_udp_xfcp_server.log

# ── Integracne testy ──────────────────────────────────────────────────────────

xfcp_test_12_cpu_mailbox_regs_top: $(LOGDIR)
	$(VLOG) $(AXI_COMMON) \
	        $(UART_COMMON) \
	        $(AXIL_COMMON) \
	        $(RTL_AXIL)/axil_sys_ctrl.sv \
	        $(RTL_AXIL)/axil_uart_adapter.sv \
	        $(RTL_AXIL)/axil_regs.sv \
	        $(RTL_AXIL)/axil_seven_seg_adapter.sv \
	        $(RTL_AXIL)/axil_diag_ctrl.sv \
	        $(RTL_SEG)/seven_seg_mux.sv \
	        $(RTL_SEG)/seven_seg_mux_packed.sv \
	        $(RTL_BUF)/skid_buffer.sv \
	        $(RTL_STRM)/stream_skid_buffer.sv \
	        $(RTL_STRM)/axis_reg_slice.sv \
	        $(RTL_STRM)/axis_skid_buffer.sv \
	        $(RTL_CDC)/cdc_two_flop_synchronizer.sv \
	        $(RTL_LCDC)/async_fifo.sv \
	        $(ETH_COMMON) \
	        $(XFCP_COMMON) \
	        $(RTL_XFCP_TRAN)/xfcp_udp_rx_adapter.sv \
	        $(RTL_XFCP_TRAN)/xfcp_udp_tx_adapter.sv \
	        $(RTL_XFCP_TRAN)/udp_xfcp_server.sv \
	        $(RTL_XFCP)/xfcp_arbiter_2to1.sv \
	        $(RTL_XFCP)/xfcp_stream_mux.sv \
	        ../rtl/axifull_sram.sv \
	        ../rtl/axil_cpu_mailbox.sv \
	        ../rtl/xfcp_test_12_cpu_mailbox_regs_top.sv \
	        common/tb_eth_pkg.sv \
	        integration/tb_xfcp_test_12_cpu_mailbox_regs_top.sv
	$(VSIM) tb_xfcp_test_12_cpu_mailbox_regs_top | tee $(LOGDIR)/tb_xfcp_test_12_cpu_mailbox_regs_top.log

clean:
	rm -rf work transcript *.log $(LOGDIR)
