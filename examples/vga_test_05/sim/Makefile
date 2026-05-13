SHELL        := bash
.SHELLFLAGS  := -o pipefail -c

RTL  ?= ../rtl/hdmi
VRTL ?= ../rtl/video

LOGDIR ?= logs

VLOG := vlog -sv -suppress 2892
VSIM := vsim -c -do "run -all; quit"

.PHONY: all regression report clean \
        bch_ecc terc4_encoder data_island scheduler \
        acr_packet audio_sample_pkt tx_core_32x10

all: bch_ecc terc4_encoder data_island scheduler acr_packet audio_sample_pkt tx_core_32x10

$(LOGDIR):
	mkdir -p $(LOGDIR)

regression: all
	@echo "======================================"
	@echo " HDMI SIM REGRESSION PASSED"
	@echo "======================================"

report: clean $(LOGDIR)
	$(MAKE) regression 2>&1 | tee $(LOGDIR)/regression_full.log

bch_ecc: $(LOGDIR)
	$(VLOG) $(RTL)/hdmi_bch_ecc.sv tb_hdmi_bch_ecc.sv
	$(VSIM) tb_hdmi_bch_ecc | tee $(LOGDIR)/tb_hdmi_bch_ecc.log

terc4_encoder: $(LOGDIR)
	$(VLOG) $(RTL)/hdmi_pkg.sv \
	        $(RTL)/terc4_encoder.sv \
	        tb_terc4_encoder.sv
	$(VSIM) tb_terc4_encoder | tee $(LOGDIR)/tb_terc4_encoder.log

data_island: $(LOGDIR)
	$(VLOG) $(RTL)/hdmi_pkg.sv \
	        $(RTL)/hdmi_bch_ecc.sv \
	        $(RTL)/data_island_formatter.sv \
	        tb_data_island_formatter.sv
	$(VSIM) tb_data_island_formatter | tee $(LOGDIR)/tb_data_island_formatter.log

scheduler: $(LOGDIR)
	$(VLOG) $(RTL)/hdmi_pkg.sv \
	        $(RTL)/hdmi_period_scheduler.sv \
	        tb_hdmi_period_scheduler.sv
	$(VSIM) tb_hdmi_period_scheduler | tee $(LOGDIR)/tb_hdmi_period_scheduler.log

acr_packet: $(LOGDIR)
	$(VLOG) $(RTL)/acr_packet_builder.sv tb_acr_packet_builder.sv
	$(VSIM) tb_acr_packet_builder | tee $(LOGDIR)/tb_acr_packet_builder.log

audio_sample_pkt: $(LOGDIR)
	$(VLOG) $(RTL)/audio_sample_packet_builder.sv tb_audio_sample_packet_builder.sv
	$(VSIM) tb_audio_sample_packet_builder | tee $(LOGDIR)/tb_audio_sample_packet_builder.log

tx_core_32x10: $(LOGDIR)
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
	$(VSIM) tb_hdmi_tx_core_32x10 | tee $(LOGDIR)/tb_hdmi_tx_core_32x10.log

clean:
	rm -rf work transcript *.log $(LOGDIR)
