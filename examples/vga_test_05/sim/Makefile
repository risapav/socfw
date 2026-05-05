RTL := ../rtl/hdmi

VLOG := vlog -sv -suppress 2892
VSIM := vsim -c -do "run -all; quit"

.PHONY: all bch_ecc data_island clean

all: bch_ecc data_island

bch_ecc:
	$(VLOG) $(RTL)/hdmi_bch_ecc.sv tb_hdmi_bch_ecc.sv
	$(VSIM) tb_hdmi_bch_ecc

data_island:
	$(VLOG) $(RTL)/hdmi_pkg.sv \
	        $(RTL)/hdmi_bch_ecc.sv \
	        $(RTL)/data_island_formatter.sv \
	        tb_data_island_formatter.sv
	$(VSIM) tb_data_island_formatter

clean:
	rm -rf work transcript *.log
