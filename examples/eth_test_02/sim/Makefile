SHELL      := bash
.SHELLFLAGS := -o pipefail -c

RTL_AXI  ?= ../../../rtl/axi
RTL_AXIL ?= ../../../rtl/axil
RTL_CDC  ?= ../../../rtl/cdc
RTL_ETH  ?= ../rtl/eth
RTL_TOP  ?= ../rtl

LOGDIR ?= logs

VLOG := vlog -sv -suppress 2892
VSIM := vsim -c -do "run -all; quit"

AXI_COMMON = \
	$(RTL_AXI)/axi_pkg.sv \
	$(RTL_AXI)/axi_interfaces.sv

AXIL_COMMON = \
	$(RTL_AXIL)/axil_regfile.sv

ETH_CORE = \
	$(RTL_ETH)/crc.sv \
	$(RTL_ETH)/ipsend.sv \
	$(RTL_ETH)/ipreceive.sv \
	$(RTL_ETH)/ram.sv \
	$(RTL_CDC)/cdc_two_flop_synchronizer.sv \
	$(RTL_ETH)/udp_rx_ram_to_stream.sv \
	$(RTL_ETH)/udp_tx_stream_to_ram.sv

ETH_ECHO = \
	$(ETH_CORE) \
	$(AXI_COMMON) \
	$(AXIL_COMMON) \
	$(RTL_TOP)/eth_udp_echo_test.sv \
	$(RTL_ETH)/eth_status_leds.sv \
	$(RTL_TOP)/ethernet_test_echo.sv

.PHONY: all unit integration regression clean \
        tb_udp_echo_path tb_rx_stream tb_tx_stream \
        tb_ipreceive_data_receive_pulse tb_ethernet_test_echo_gmii_packet \
        tb_ethernet_test_echo_gmii_no_preamble

all: unit integration

unit: tb_rx_stream tb_tx_stream tb_ipreceive_data_receive_pulse

integration: tb_udp_echo_path tb_ethernet_test_echo_gmii_packet \
             tb_ethernet_test_echo_gmii_no_preamble

$(LOGDIR):
	mkdir -p $(LOGDIR)

regression: clean all
	@if grep -ql "FAIL\|\*\* Fatal:" $(LOGDIR)/tb_*.log 2>/dev/null; then \
		echo "======================================"; \
		echo " ETH_TEST_02 REGRESSION FAILED"; \
		echo "======================================"; \
		exit 1; \
	else \
		echo "======================================"; \
		echo " ETH_TEST_02 REGRESSION PASSED"; \
		echo "======================================"; \
	fi

# -- Unit testy ----------------------------------------------------------------

tb_rx_stream: $(LOGDIR)
	$(VLOG) $(RTL_ETH)/crc.sv \
	        $(RTL_ETH)/ram.sv \
	        $(RTL_CDC)/cdc_two_flop_synchronizer.sv \
	        $(RTL_ETH)/udp_rx_ram_to_stream.sv \
	        unit/tb_rx_stream.sv
	$(VSIM) tb_rx_stream | tee $(LOGDIR)/tb_rx_stream.log

tb_tx_stream: $(LOGDIR)
	$(VLOG) $(RTL_ETH)/udp_tx_stream_to_ram.sv \
	        unit/tb_tx_stream.sv
	$(VSIM) tb_tx_stream | tee $(LOGDIR)/tb_tx_stream.log

# -- Unit test: ipreceive pulse -----------------------------------------------

tb_ipreceive_data_receive_pulse: $(LOGDIR)
	$(VLOG) $(RTL_ETH)/ipreceive.sv \
	        unit/tb_ipreceive_data_receive_pulse.sv
	$(VSIM) tb_ipreceive_data_receive_pulse | tee $(LOGDIR)/tb_ipreceive_data_receive_pulse.log

# -- Integracne testy ----------------------------------------------------------

tb_udp_echo_path: $(LOGDIR)
	$(VLOG) $(ETH_ECHO) \
	        integration/tb_udp_echo_path.sv
	$(VSIM) tb_udp_echo_path | tee $(LOGDIR)/tb_udp_echo_path.log

tb_ethernet_test_echo_gmii_packet: $(LOGDIR)
	$(VLOG) $(ETH_ECHO) \
	        integration/tb_ethernet_test_echo_gmii_packet.sv
	$(VSIM) tb_ethernet_test_echo_gmii_packet | tee $(LOGDIR)/tb_ethernet_test_echo_gmii_packet.log

tb_ethernet_test_echo_gmii_no_preamble: $(LOGDIR)
	$(VLOG) $(ETH_ECHO) \
	        integration/tb_ethernet_test_echo_gmii_no_preamble.sv
	$(VSIM) tb_ethernet_test_echo_gmii_no_preamble | tee $(LOGDIR)/tb_ethernet_test_echo_gmii_no_preamble.log

clean:
	rm -rf work transcript *.log $(LOGDIR)
