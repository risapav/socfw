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

TB_COMMON := common/tb_eth_pkg.sv

# ── Targets ───────────────────────────────────────────────────────────

.PHONY: all unit mac integration \
        crc32 eth_rx_mac eth_tx_mac eth_echo_app loopback \
        regression clean

all: unit mac integration

unit: crc32

mac: eth_rx_mac eth_tx_mac eth_echo_app

integration: loopback

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
