RTL  := ../rtl/hdmi
VRTL := ../rtl/video

VLOG := vlog -sv -suppress 2892
VSIM := vsim -c -do "run -all; quit"

.PHONY: all bch_ecc data_island scheduler acr_packet audio_sample_pkt tx_core_32x10 clean

all: bch_ecc data_island scheduler acr_packet audio_sample_pkt tx_core_32x10

bch_ecc:
	$(VLOG) $(RTL)/hdmi_bch_ecc.sv tb_hdmi_bch_ecc.sv
	$(VSIM) tb_hdmi_bch_ecc

data_island:
	$(VLOG) $(RTL)/hdmi_pkg.sv \
	        $(RTL)/hdmi_bch_ecc.sv \
	        $(RTL)/data_island_formatter.sv \
	        tb_data_island_formatter.sv
	$(VSIM) tb_data_island_formatter

scheduler:
	$(VLOG) $(RTL)/hdmi_pkg.sv \
	        $(RTL)/hdmi_period_scheduler.sv \
	        tb_hdmi_period_scheduler.sv
	$(VSIM) tb_hdmi_period_scheduler

acr_packet:
	$(VLOG) $(RTL)/acr_packet_builder.sv tb_acr_packet_builder.sv
	$(VSIM) tb_acr_packet_builder

audio_sample_pkt:
	$(VLOG) $(RTL)/audio_sample_packet_builder.sv tb_audio_sample_packet_builder.sv
	$(VSIM) tb_audio_sample_packet_builder

tx_core_32x10:
	$(VLOG) \
	        $(RTL)/hdmi_pkg.sv \
	        $(VRTL)/video_pkg.sv \
	        $(VRTL)/video_timing_generator.sv \
	        $(RTL)/tmds_video_encoder.sv \
	        $(RTL)/tmds_control_encoder.sv \
	        $(RTL)/terc4_encoder.sv \
	        $(RTL)/hdmi_period_scheduler.sv \
	        $(RTL)/hdmi_channel_mux.sv \
	        $(RTL)/infoframe_builder.sv \
	        $(RTL)/hdmi_bch_ecc.sv \
	        $(RTL)/data_island_formatter.sv \
	        $(RTL)/gcp_packet_builder.sv \
	        $(RTL)/acr_packet_builder.sv \
	        $(RTL)/audio_sample_packet_builder.sv \
	        $(RTL)/hdmi_audio_test_src.sv \
	        $(RTL)/hdmi_packet_arbiter.sv \
	        $(RTL)/hdmi_tx_core.sv \
	        tb_hdmi_tx_core_32x10.sv
	$(VSIM) tb_hdmi_tx_core_32x10

clean:
	rm -rf work transcript *.log
