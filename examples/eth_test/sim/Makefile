SHELL      := bash
.SHELLFLAGS := -o pipefail -c

# RTL paths
RTL_AXI  ?= ../../../rtl/axi
RTL_AXIL ?= ../../../rtl/axil
RTL_ETH  ?= ../rtl/eth
RTL_CDC  ?= ../rtl/cdc
RTL_TOP  ?= ../rtl

LOGDIR ?= logs

VLOG := vlog -sv -suppress 2892
VSIM := vsim -c -do "run -all; quit"

# -- Zdielane skupiny suborov ------------------------------------------------

AXI_COMMON = \
	$(RTL_AXI)/axi_pkg.sv \
	$(RTL_AXI)/axi_interfaces.sv

AXIL_COMMON = \
	$(RTL_AXIL)/axil_regfile.sv

ETH_CORE = \
	$(RTL_ETH)/crc.sv \
	$(RTL_ETH)/ipsend.sv \
	$(RTL_ETH)/ipreceive.sv \
	$(RTL_ETH)/udp.sv

ETH_TOP = \
	$(ETH_CORE) \
	$(RTL_ETH)/ram.sv \
	$(RTL_CDC)/cdc_two_flop_synchronizer.sv \
	$(RTL_ETH)/eth_status_leds.sv \
	$(RTL_TOP)/ethernet_test.sv

.PHONY: all unit integration regression report clean \
        tb_crc_smoke tb_ram_latency tb_ipreceive_udp_frame \
        tb_ipsend_static_packet tb_udp_rx_path \
        tb_ethernet_test_top_smoke tb_ipsend_full_frame

# -- Defaultny ciel ----------------------------------------------------------

all: unit integration

unit: tb_crc_smoke tb_ram_latency tb_ipreceive_udp_frame tb_ipsend_static_packet

integration: tb_udp_rx_path tb_ethernet_test_top_smoke tb_ipsend_full_frame

$(LOGDIR):
	mkdir -p $(LOGDIR)

# -- Regression --------------------------------------------------------------

regression: clean all
	@if grep -ql "FAIL\|\*\* Fatal:" $(LOGDIR)/tb_*.log 2>/dev/null; then \
		echo "======================================"; \
		echo " ETH_TEST REGRESSION FAILED"; \
		echo "======================================"; \
		exit 1; \
	else \
		echo "======================================"; \
		echo " ETH_TEST REGRESSION PASSED"; \
		echo "======================================"; \
	fi

report: clean $(LOGDIR)
	$(MAKE) regression 2>&1 | tee $(LOGDIR)/regression_full.log

# -- Unit testy --------------------------------------------------------------

tb_crc_smoke: $(LOGDIR)
	$(VLOG) $(RTL_ETH)/crc.sv \
	        unit/tb_crc_smoke.sv
	$(VSIM) tb_crc_smoke | tee $(LOGDIR)/tb_crc_smoke.log

tb_ram_latency: $(LOGDIR)
	$(VLOG) $(RTL_ETH)/ram.sv \
	        unit/tb_ram_latency.sv
	$(VSIM) tb_ram_latency | tee $(LOGDIR)/tb_ram_latency.log

tb_ipreceive_udp_frame: $(LOGDIR)
	$(VLOG) $(RTL_ETH)/ipreceive.sv \
	        unit/tb_ipreceive_udp_frame.sv
	$(VSIM) tb_ipreceive_udp_frame | tee $(LOGDIR)/tb_ipreceive_udp_frame.log

tb_ipsend_static_packet: $(LOGDIR)
	$(VLOG) $(RTL_ETH)/crc.sv \
	        $(RTL_ETH)/ipsend.sv \
	        unit/tb_ipsend_static_packet.sv
	$(VSIM) tb_ipsend_static_packet | tee $(LOGDIR)/tb_ipsend_static_packet.log

# -- Integracne testy --------------------------------------------------------

tb_udp_rx_path: $(LOGDIR)
	$(VLOG) $(ETH_CORE) \
	        integration/tb_udp_rx_path.sv
	$(VSIM) tb_udp_rx_path | tee $(LOGDIR)/tb_udp_rx_path.log

tb_ethernet_test_top_smoke: $(LOGDIR)
	$(VLOG) $(ETH_TOP) \
	        integration/tb_ethernet_test_top_smoke.sv
	$(VSIM) tb_ethernet_test_top_smoke | tee $(LOGDIR)/tb_ethernet_test_top_smoke.log

tb_ipsend_full_frame: $(LOGDIR)
	$(VLOG) $(RTL_ETH)/crc.sv \
	        $(RTL_ETH)/ipsend.sv \
	        integration/tb_ipsend_full_frame.sv
	$(VSIM) tb_ipsend_full_frame | tee $(LOGDIR)/tb_ipsend_full_frame.log

clean:
	rm -rf work transcript *.log $(LOGDIR)
