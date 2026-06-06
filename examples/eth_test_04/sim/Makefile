SHELL      := bash
.SHELLFLAGS := -o pipefail -c

QUESTA := /home/palo/altera_lite/25.1std/questa_fse/bin
VLOG   := $(QUESTA)/vlog -sv -suppress 2892
VSIM   := $(QUESTA)/vsim -c -do "run -all; quit"

RTL    := ../rtl

LOGDIR ?= logs

# ── RTL source groups ─────────────────────────────────────────────────

CRC_SRCS := \
	$(RTL)/eth/mac/taxi_lfsr.sv \
	$(RTL)/eth/mac/eth_crc32_8.sv

MAC_SRCS := \
	$(CRC_SRCS) \
	$(RTL)/eth/mac/eth_rx_mac.sv \
	$(RTL)/eth/mac/eth_tx_mac.sv

ECHO_SRCS := \
	$(MAC_SRCS) \
	$(RTL)/eth/eth_echo_app.sv

INT_SRCS := \
	$(ECHO_SRCS) \
	$(RTL)/cdc/async_fifo.sv

L2_SRCS := \
	$(RTL)/pkg/eth_pkg.sv \
	$(CRC_SRCS) \
	$(RTL)/eth/mac/eth_rx_mac.sv \
	$(RTL)/eth/mac/eth_tx_mac.sv \
	$(RTL)/eth/util/eth_type_demux.sv \
	$(RTL)/eth/l2/arp_rx.sv \
	$(RTL)/eth/l2/arp_tx.sv

L3_SRCS := \
	$(RTL)/pkg/eth_pkg.sv \
	$(CRC_SRCS) \
	$(RTL)/eth/mac/eth_rx_mac.sv \
	$(RTL)/eth/mac/eth_tx_mac.sv \
	$(RTL)/eth/util/eth_type_demux.sv \
	$(RTL)/eth/l3/ipv4_rx.sv \
	$(RTL)/eth/l3/ipv4_tx.sv \
	$(RTL)/eth/l3/icmp_echo.sv

L4_SRCS := \
	$(RTL)/pkg/eth_pkg.sv \
	$(CRC_SRCS) \
	$(RTL)/eth/mac/eth_rx_mac.sv \
	$(RTL)/eth/mac/eth_tx_mac.sv \
	$(RTL)/eth/util/eth_type_demux.sv \
	$(RTL)/eth/l3/ipv4_rx.sv \
	$(RTL)/eth/l3/ipv4_tx.sv \
	$(RTL)/eth/l4/udp_echo.sv

TB_COMMON := common/tb_eth_pkg.sv

# ── Targets ───────────────────────────────────────────────────────────

.PHONY: all unit mac integration l2 l3 l4 \
        crc32 eth_rx_mac eth_tx_mac eth_echo_app loopback \
        arp icmp udp \
        regression clean

all: unit mac integration l2 l3 l4

unit: crc32

mac: eth_rx_mac eth_tx_mac eth_echo_app

integration: loopback

l2: arp

l3: icmp

l4: udp

$(LOGDIR):
	mkdir -p $(LOGDIR)

# ── Unit tests ────────────────────────────────────────────────────────

crc32: $(LOGDIR)
	$(VLOG) $(CRC_SRCS) \
	        $(TB_COMMON) \
	        unit/tb_eth_crc32_8.sv
	$(VSIM) tb_eth_crc32_8 | tee $(LOGDIR)/tb_eth_crc32_8.log
	@grep -E "PASS|FAIL|Error" $(LOGDIR)/tb_eth_crc32_8.log

# ── MAC tests ─────────────────────────────────────────────────────────

eth_rx_mac: $(LOGDIR)
	$(VLOG) $(MAC_SRCS) \
	        $(TB_COMMON) \
	        mac/tb_eth_rx_mac.sv
	$(VSIM) tb_eth_rx_mac | tee $(LOGDIR)/tb_eth_rx_mac.log
	@grep -E "PASS|FAIL|Error" $(LOGDIR)/tb_eth_rx_mac.log

eth_tx_mac: $(LOGDIR)
	$(VLOG) $(MAC_SRCS) \
	        $(TB_COMMON) \
	        mac/tb_eth_tx_mac.sv
	$(VSIM) tb_eth_tx_mac | tee $(LOGDIR)/tb_eth_tx_mac.log
	@grep -E "PASS|FAIL|Error" $(LOGDIR)/tb_eth_tx_mac.log

eth_echo_app: $(LOGDIR)
	$(VLOG) $(ECHO_SRCS) \
	        $(TB_COMMON) \
	        mac/tb_eth_echo_app.sv
	$(VSIM) tb_eth_echo_app | tee $(LOGDIR)/tb_eth_echo_app.log
	@grep -E "PASS|FAIL|Error" $(LOGDIR)/tb_eth_echo_app.log

# ── L2 tests ──────────────────────────────────────────────────────────

arp: $(LOGDIR)
	$(VLOG) $(L2_SRCS) \
	        $(TB_COMMON) \
	        l2/tb_arp.sv
	$(VSIM) tb_arp | tee $(LOGDIR)/tb_arp.log
	@grep -E "PASS|FAIL|Error" $(LOGDIR)/tb_arp.log

# ── L3 tests ──────────────────────────────────────────────────────────

icmp: $(LOGDIR)
	$(VLOG) $(L3_SRCS) \
	        $(TB_COMMON) \
	        l3/tb_icmp_echo.sv
	$(VSIM) tb_icmp_echo | tee $(LOGDIR)/tb_icmp_echo.log
	@grep -E "PASS|FAIL|Error" $(LOGDIR)/tb_icmp_echo.log

# ── L4 tests ──────────────────────────────────────────────────────────

udp: $(LOGDIR)
	$(VLOG) $(L4_SRCS) \
	        $(TB_COMMON) \
	        l4/tb_udp_echo.sv
	$(VSIM) tb_udp_echo | tee $(LOGDIR)/tb_udp_echo.log
	@grep -E "PASS|FAIL|Error" $(LOGDIR)/tb_udp_echo.log

# ── Integration tests ─────────────────────────────────────────────────

loopback: $(LOGDIR)
	$(VLOG) $(INT_SRCS) \
	        $(TB_COMMON) \
	        integration/tb_rx_tx_loopback.sv
	$(VSIM) tb_rx_tx_loopback | tee $(LOGDIR)/tb_rx_tx_loopback.log
	@grep -E "PASS|FAIL|Error" $(LOGDIR)/tb_rx_tx_loopback.log

# ── Regression ────────────────────────────────────────────────────────

regression: clean all

clean:
	rm -rf work transcript *.log $(LOGDIR)
