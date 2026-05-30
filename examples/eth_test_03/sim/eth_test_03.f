// eth_test_03 RTL filelist — compile order matters: eth_pkg.sv must be first.
// Usage:
//   vlog -sv -f sim/eth_test_03.f
//   verilator -sv --lint-only -f sim/eth_test_03.f
//   svls, verible, etc.: point IDE to this file

../rtl/eth/eth_pkg.sv

../rtl/eth/mac/crc32_eth.sv
../rtl/eth/mac/gmii_rx_mac.sv
../rtl/eth/mac/gmii_tx_mac.sv

../rtl/eth/l2/eth_header_builder.sv
../rtl/eth/l2/eth_header_parser.sv

../rtl/eth/l3/ipv4_checksum.sv
../rtl/eth/l3/ipv4_header_parser.sv

../rtl/eth/l4/udp_header_parser.sv
../rtl/eth/l4/udp_rx_meta_assembler.sv
../rtl/eth/l4/udp_echo_app.sv
../rtl/eth/l4/udp_ipv4_tx_builder.sv

../rtl/eth/cdc/async_fifo.sv
../rtl/eth/cdc/cdc_two_flop_synchronizer.sv
../rtl/eth/util/eth_debug_leds.sv
../rtl/eth/ethernet_test_03_top.sv
