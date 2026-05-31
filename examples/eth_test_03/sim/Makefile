SHELL      := bash
.SHELLFLAGS := -o pipefail -c

QUESTA := /home/palo/altera_lite/25.1std/questa_fse/bin
VLOG   := $(QUESTA)/vlog -sv -suppress 2892
VSIM   := $(QUESTA)/vsim -c -do "run -all; quit"

RTL    := ../rtl/eth

LOGDIR ?= logs

ETH_COMMON := \
	$(RTL)/eth_pkg.sv \
	$(RTL)/l2/eth_header_builder.sv

MAC_COMMON := \
	$(ETH_COMMON) \
	$(RTL)/mac/crc32_eth.sv

TB_COMMON := \
	common/tb_eth_pkg.sv

.PHONY: all unit integration crc32 gmii_tx gmii_rx gmii_rx_sfd mac_stream gmii_rx_l2_align eth_hdr_builder eth_hdr_parser ipv4_checksum ipv4_hdr_parser udp_hdr_parser udp_tx_builder rx_path echo_path echo_path_dc regression clean

unit: crc32 gmii_tx gmii_rx gmii_rx_sfd mac_stream gmii_rx_l2_align eth_hdr_builder eth_hdr_parser ipv4_checksum ipv4_hdr_parser udp_hdr_parser udp_tx_builder

integration: rx_path echo_path echo_path_dc

all: unit integration

$(LOGDIR):
	mkdir -p $(LOGDIR)

# ── Unit tests ────────────────────────────────────────────────────────

crc32: $(LOGDIR)
	$(VLOG) $(MAC_COMMON) \
	        $(TB_COMMON) \
	        unit/tb_crc32_eth.sv
	$(VSIM) tb_crc32_eth | tee $(LOGDIR)/tb_crc32_eth.log
	@grep -E "PASS|FAIL|Error" $(LOGDIR)/tb_crc32_eth.log

# ── MAC tests ─────────────────────────────────────────────────────────

gmii_tx: $(LOGDIR)
	$(VLOG) $(MAC_COMMON) \
	        $(RTL)/mac/gmii_tx_mac.sv \
	        $(TB_COMMON) \
	        mac/tb_gmii_tx_mac.sv
	$(VSIM) tb_gmii_tx_mac | tee $(LOGDIR)/tb_gmii_tx_mac.log
	@grep -E "PASS|FAIL|Error" $(LOGDIR)/tb_gmii_tx_mac.log

gmii_rx: $(LOGDIR)
	$(VLOG) $(MAC_COMMON) \
	        $(RTL)/mac/gmii_rx_mac.sv \
	        $(TB_COMMON) \
	        mac/tb_gmii_rx_mac.sv
	$(VSIM) tb_gmii_rx_mac | tee $(LOGDIR)/tb_gmii_rx_mac.log
	@grep -E "PASS|FAIL|Error" $(LOGDIR)/tb_gmii_rx_mac.log

gmii_rx_sfd: $(LOGDIR)
	$(VLOG) $(MAC_COMMON) \
	        $(RTL)/mac/gmii_rx_mac.sv \
	        $(TB_COMMON) \
	        mac/tb_gmii_rx_mac_sfd_boundary.sv
	$(VSIM) tb_gmii_rx_mac_sfd_boundary | tee $(LOGDIR)/tb_gmii_rx_mac_sfd_boundary.log
	@grep -E "PASS|FAIL|Error" $(LOGDIR)/tb_gmii_rx_mac_sfd_boundary.log

mac_stream: $(LOGDIR)
	$(VLOG) $(MAC_COMMON) \
	        $(RTL)/mac/gmii_tx_mac.sv \
	        $(RTL)/mac/gmii_rx_mac.sv \
	        $(TB_COMMON) \
	        mac/tb_mac_stream_tx_rx_stream.sv
	$(VSIM) tb_mac_stream_tx_rx_stream | tee $(LOGDIR)/tb_mac_stream_tx_rx_stream.log
	@grep -E "PASS|FAIL|Error" $(LOGDIR)/tb_mac_stream_tx_rx_stream.log

gmii_rx_l2_align: $(LOGDIR)
	$(VLOG) $(MAC_COMMON) \
	        $(RTL)/mac/gmii_rx_mac.sv \
	        $(RTL)/l2/eth_header_parser.sv \
	        $(TB_COMMON) \
	        mac/tb_gmii_rx_eth_align.sv
	$(VSIM) tb_gmii_rx_eth_align | tee $(LOGDIR)/tb_gmii_rx_eth_align.log
	@grep -E "PASS|FAIL|Error" $(LOGDIR)/tb_gmii_rx_eth_align.log

# ── L2 tests ──────────────────────────────────────────────────────────

eth_hdr_builder: $(LOGDIR)
	$(VLOG) $(ETH_COMMON) \
	        l2/tb_eth_header_builder.sv
	$(VSIM) tb_eth_header_builder | tee $(LOGDIR)/tb_eth_header_builder.log
	@grep -E "PASS|FAIL|Error" $(LOGDIR)/tb_eth_header_builder.log

eth_hdr_parser: $(LOGDIR)
	$(VLOG) $(ETH_COMMON) \
	        $(RTL)/l2/eth_header_parser.sv \
	        $(TB_COMMON) \
	        l2/tb_eth_header_parser.sv
	$(VSIM) tb_eth_header_parser | tee $(LOGDIR)/tb_eth_header_parser.log
	@grep -E "PASS|FAIL|Error" $(LOGDIR)/tb_eth_header_parser.log

ipv4_checksum: $(LOGDIR)
	$(VLOG) $(RTL)/l3/ipv4_checksum.sv \
	        l3/tb_ipv4_checksum.sv
	$(VSIM) tb_ipv4_checksum | tee $(LOGDIR)/tb_ipv4_checksum.log
	@grep -E "PASS|FAIL|Error" $(LOGDIR)/tb_ipv4_checksum.log

ipv4_hdr_parser: $(LOGDIR)
	$(VLOG) $(ETH_COMMON) \
	        $(RTL)/l3/ipv4_header_parser.sv \
	        $(TB_COMMON) \
	        l3/tb_ipv4_header_parser.sv
	$(VSIM) tb_ipv4_header_parser | tee $(LOGDIR)/tb_ipv4_header_parser.log
	@grep -E "PASS|FAIL|Error" $(LOGDIR)/tb_ipv4_header_parser.log

udp_hdr_parser: $(LOGDIR)
	$(VLOG) $(ETH_COMMON) \
	        $(RTL)/l4/udp_header_parser.sv \
	        $(TB_COMMON) \
	        l4/tb_udp_header_parser.sv
	$(VSIM) tb_udp_header_parser | tee $(LOGDIR)/tb_udp_header_parser.log
	@grep -E "PASS|FAIL|Error" $(LOGDIR)/tb_udp_header_parser.log

udp_tx_builder: $(LOGDIR)
	$(VLOG) $(RTL)/eth_pkg.sv \
	        $(RTL)/l3/ipv4_checksum.sv \
	        $(RTL)/l4/udp_ipv4_tx_builder.sv \
	        $(TB_COMMON) \
	        l4/tb_udp_ipv4_tx_builder.sv
	$(VSIM) tb_udp_ipv4_tx_builder | tee $(LOGDIR)/tb_udp_ipv4_tx_builder.log
	@grep -E "PASS|FAIL|Error" $(LOGDIR)/tb_udp_ipv4_tx_builder.log

VLDIR      := obj_rx_path
VLDIR_ECHO := obj_echo_path
VLDIR_DC   := obj_echo_path_dc

rx_path: $(LOGDIR)
	verilator -sv --cc --exe --build \
	    --top-module rx_path_top \
	    --Mdir $(VLDIR) \
	    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
	    $(RTL)/eth_pkg.sv \
	    $(RTL)/mac/gmii_rx_mac.sv \
	    $(RTL)/l2/eth_header_parser.sv \
	    $(RTL)/l3/ipv4_header_parser.sv \
	    $(RTL)/l4/udp_header_parser.sv \
	    verilator/rx_path_top.sv \
	    verilator/tb_rx_path.cpp
	./$(VLDIR)/Vrx_path_top | tee $(LOGDIR)/tb_rx_path.log
	@grep -E "PASS|FAIL" $(LOGDIR)/tb_rx_path.log

echo_path: $(LOGDIR)
	verilator -sv --cc --exe --build \
	    --top-module echo_path_top \
	    --Mdir $(VLDIR_ECHO) \
	    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
	    $(RTL)/eth_pkg.sv \
	    $(RTL)/mac/crc32_eth.sv \
	    $(RTL)/mac/gmii_rx_mac.sv \
	    $(RTL)/mac/gmii_tx_mac.sv \
	    $(RTL)/l2/eth_header_builder.sv \
	    $(RTL)/l2/eth_header_parser.sv \
	    $(RTL)/l3/ipv4_checksum.sv \
	    $(RTL)/l3/ipv4_header_parser.sv \
	    $(RTL)/l4/udp_header_parser.sv \
	    $(RTL)/l4/udp_rx_meta_assembler.sv \
	    $(RTL)/l4/udp_echo_app.sv \
	    $(RTL)/l4/udp_ipv4_tx_builder.sv \
	    verilator/echo_path_top.sv \
	    verilator/tb_echo_path.cpp
	./$(VLDIR_ECHO)/Vecho_path_top | tee $(LOGDIR)/tb_echo_path.log
	@grep -E "PASS|FAIL" $(LOGDIR)/tb_echo_path.log

echo_path_dc: $(LOGDIR)
	verilator -sv --cc --exe --build \
	    --top-module echo_path_dual_clock_top \
	    --Mdir $(VLDIR_DC) \
	    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SYNCASYNCNET \
	    $(RTL)/eth_pkg.sv \
	    $(RTL)/cdc/async_fifo.sv \
	    $(RTL)/mac/crc32_eth.sv \
	    $(RTL)/mac/gmii_rx_mac.sv \
	    $(RTL)/mac/gmii_tx_mac.sv \
	    $(RTL)/l2/eth_header_builder.sv \
	    $(RTL)/l2/eth_header_parser.sv \
	    $(RTL)/l3/ipv4_checksum.sv \
	    $(RTL)/l3/ipv4_header_parser.sv \
	    $(RTL)/l4/udp_header_parser.sv \
	    $(RTL)/l4/udp_rx_meta_assembler.sv \
	    $(RTL)/l4/udp_echo_app.sv \
	    $(RTL)/l4/udp_ipv4_tx_builder.sv \
	    verilator/echo_path_dual_clock_top.sv \
	    verilator/tb_echo_path_dual_clock.cpp
	./$(VLDIR_DC)/Vecho_path_dual_clock_top | tee $(LOGDIR)/tb_echo_path_dual_clock.log
	@grep -E "PASS|FAIL" $(LOGDIR)/tb_echo_path_dual_clock.log

regression: clean unit integration

clean:
	rm -rf work transcript *.log $(LOGDIR) $(VLDIR) $(VLDIR_ECHO) $(VLDIR_DC)
