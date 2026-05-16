SHELL        := bash
.SHELLFLAGS  := -o pipefail -c

RTL  ?= ../rtl/hdmi
VRTL ?= ../rtl/video

LOGDIR ?= logs

VLOG := vlog -sv -suppress 2892
VSIM := vsim -c -do "run -all; quit"

# RTL source list shared by tx_core_32x10 and audio_scenarios
TX_CORE_SRCS = \
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
        $(RTL)/hdmi_tx_core.sv

.PHONY: all regression report clean \
        bch_ecc terc4_encoder data_island scheduler \
        acr_packet audio_sample_pkt tx_core_32x10 audio_scenarios \
        di_isolation tmds_decode phy_loopback dvi_vs_2a

all: bch_ecc terc4_encoder data_island scheduler acr_packet audio_sample_pkt \
     tx_core_32x10 di_isolation audio_scenarios tmds_decode phy_loopback dvi_vs_2a

$(LOGDIR):
	mkdir -p $(LOGDIR)

regression: all
	@if grep -ql "FAIL\|\*\* Fatal:" $(LOGDIR)/tb_*.log 2>/dev/null; then \
		echo "======================================"; \
		echo " HDMI SIM REGRESSION FAILED"; \
		echo "======================================"; \
		exit 1; \
	else \
		echo "======================================"; \
		echo " HDMI SIM REGRESSION PASSED"; \
		echo "======================================"; \
	fi

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
	$(VLOG) $(TX_CORE_SRCS) tb_hdmi_tx_core_32x10.sv
	$(VSIM) tb_hdmi_tx_core_32x10 | tee $(LOGDIR)/tb_hdmi_tx_core_32x10.log

# audio_scenarios: compile once, run vsim 4 times with different -G parameter overrides.
# Scenarios: ACR-only, AudioIF-only, Sample-only, full (all enabled).
audio_scenarios: $(LOGDIR)
	$(VLOG) $(TX_CORE_SRCS) tb_hdmi_tx_core_audio.sv
	vsim -G ENABLE_ACR_PACKET=1 -G ENABLE_AUDIO_INFOFRAME=0 -G ENABLE_AUDIO_SAMPLE=0 \
	     -c -do "run -all; quit" tb_hdmi_tx_core_audio \
	     | tee $(LOGDIR)/tb_audio_acr_only.log
	vsim -G ENABLE_ACR_PACKET=0 -G ENABLE_AUDIO_INFOFRAME=1 -G ENABLE_AUDIO_SAMPLE=0 \
	     -c -do "run -all; quit" tb_hdmi_tx_core_audio \
	     | tee $(LOGDIR)/tb_audio_if_only.log
	vsim -G ENABLE_ACR_PACKET=0 -G ENABLE_AUDIO_INFOFRAME=0 -G ENABLE_AUDIO_SAMPLE=1 \
	     -c -do "run -all; quit" tb_hdmi_tx_core_audio \
	     | tee $(LOGDIR)/tb_audio_sample_only.log
	vsim -c -do "run -all; quit" tb_hdmi_tx_core_audio \
	     | tee $(LOGDIR)/tb_audio_full.log

# di_isolation: compile once, run vsim 4x with GCP/AVI isolation flags.
# 2A=no packets, 2B=GCP-only, 2C=AVI-only, 2D=both (mirrors hardware debug sub-matrix).
di_isolation: $(LOGDIR)
	$(VLOG) $(TX_CORE_SRCS) tb_hdmi_tx_core_32x10.sv
	vsim -G ENABLE_GCP_PACKET=0 -G ENABLE_AVI_PACKET=0 \
	     -c -do "run -all; quit" tb_hdmi_tx_core_32x10 \
	     | tee $(LOGDIR)/tb_di_2a.log
	vsim -G ENABLE_GCP_PACKET=1 -G ENABLE_AVI_PACKET=0 \
	     -c -do "run -all; quit" tb_hdmi_tx_core_32x10 \
	     | tee $(LOGDIR)/tb_di_2b.log
	vsim -G ENABLE_GCP_PACKET=0 -G ENABLE_AVI_PACKET=1 \
	     -c -do "run -all; quit" tb_hdmi_tx_core_32x10 \
	     | tee $(LOGDIR)/tb_di_2c.log
	vsim -G ENABLE_GCP_PACKET=1 -G ENABLE_AVI_PACKET=1 \
	     -c -do "run -all; quit" tb_hdmi_tx_core_32x10 \
	     | tee $(LOGDIR)/tb_di_2d.log

tmds_decode: $(LOGDIR)
	$(VLOG) $(TX_CORE_SRCS) tb_hdmi_tmds_decode.sv
	$(VSIM) tb_hdmi_tmds_decode | tee $(LOGDIR)/tb_hdmi_tmds_decode.log

# phy_loopback: behavioral ddio_out model compiled first (replaces Quartus megafunction),
# then PHY module and testbench.  Verifies 10-bit symbol serialization end-to-end.
phy_loopback: $(LOGDIR)
	$(VLOG) $(RTL)/hdmi_pkg.sv \
	        ddio_out_sim.sv \
	        $(RTL)/tmds_phy_ddr_aligned.sv \
	        tb_tmds_phy_loopback.sv
	$(VSIM) tb_tmds_phy_loopback | tee $(LOGDIR)/tb_tmds_phy_loopback.log

dvi_vs_2a: $(LOGDIR)
	$(VLOG) $(TX_CORE_SRCS) tb_dvi_vs_2a.sv
	$(VSIM) tb_dvi_vs_2a | tee $(LOGDIR)/tb_dvi_vs_2a.log

clean:
	rm -rf work transcript *.log $(LOGDIR)
