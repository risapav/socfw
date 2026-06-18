SHELL      := bash
.SHELLFLAGS := -o pipefail -c

RTL    ?= ../rtl
LOGDIR ?= logs

VLOG := vlog -sv -suppress 2892
VSIM := vsim -c -do "run -all; quit"

SDRAM_RTL = \
	$(RTL)/sdram/sdram_pkg.sv \
	$(RTL)/sdram/sdram_init.sv \
	$(RTL)/sdram/refresh_manager.sv \
	$(RTL)/sdram/sdram_phy.sv

SDRAM_RTL_M3 = \
	$(RTL)/sdram/sdram_pkg.sv \
	$(RTL)/sdram/sdram_init.sv \
	$(RTL)/sdram/sdram_phy.sv \
	$(RTL)/sdram/timing_manager.sv \
	$(RTL)/sdram/bank_machine.sv \
	$(RTL)/sdram/memory_scheduler.sv

SDRAM_RTL_M4 = \
	$(RTL)/sdram/sdram_pkg.sv \
	$(RTL)/sdram/sdram_init.sv \
	$(RTL)/sdram/refresh_manager.sv \
	$(RTL)/sdram/sdram_phy.sv \
	$(RTL)/sdram/timing_manager.sv \
	$(RTL)/sdram/bank_machine.sv \
	$(RTL)/sdram/memory_scheduler.sv \
	$(RTL)/fifo/sync_fifo.sv \
	$(RTL)/sdram/write_engine.sv \
	$(RTL)/sdram/read_engine.sv \
	$(RTL)/axi/axi_gearbox.sv \
	$(RTL)/axi/axi_frontend.sv \
	$(RTL)/sdram/sdram_system_top.sv

SDRAM_SIM = \
	model/sdram_model_pro.sv \
	sdram_cmd_trace.sv

.PHONY: all init_refresh phy_single_rw scheduler_rw axi_single_rw regression clean

all: init_refresh phy_single_rw scheduler_rw axi_single_rw

$(LOGDIR):
	mkdir -p $(LOGDIR)

# ── Milestone 01: init + refresh ─────────────────────────────────────────────
init_refresh: $(LOGDIR)
	$(VLOG) $(SDRAM_RTL) $(SDRAM_SIM) tb_init_refresh.sv
	$(VSIM) tb_init_refresh | tee $(LOGDIR)/tb_init_refresh.log

# ── Milestone 02: PHY single write/read ──────────────────────────────────────
phy_single_rw: $(LOGDIR)
	$(VLOG) $(SDRAM_RTL) $(SDRAM_SIM) tb_phy_single_rw.sv
	$(VSIM) tb_phy_single_rw | tee $(LOGDIR)/tb_phy_single_rw.log

# ── Milestone 03: Scheduler write/read (no AXI, no FIFO, no refresh) ─────────
scheduler_rw: $(LOGDIR)
	$(VLOG) $(SDRAM_RTL_M3) $(SDRAM_SIM) tb_scheduler_rw.sv
	$(VSIM) tb_scheduler_rw | tee $(LOGDIR)/tb_scheduler_rw.log

# ── Milestone 04: AXI single write/read (full stack) ─────────────────────────
axi_single_rw: $(LOGDIR)
	$(VLOG) $(SDRAM_RTL_M4) $(SDRAM_SIM) tb_axi_single_rw.sv
	$(VSIM) tb_axi_single_rw | tee $(LOGDIR)/tb_axi_single_rw.log

# ── Regression ───────────────────────────────────────────────────────────────
regression: init_refresh phy_single_rw scheduler_rw axi_single_rw
	@if grep -ql "FAIL\|\*\* Fatal:" $(LOGDIR)/tb_*.log 2>/dev/null; then \
		echo "===================================="; \
		echo " SDRAM_TEST_01 REGRESSION FAILED"; \
		echo "===================================="; \
		exit 1; \
	else \
		echo "===================================="; \
		echo " SDRAM_TEST_01 REGRESSION PASSED"; \
		echo "===================================="; \
	fi

clean:
	rm -rf work transcript *.log $(LOGDIR)
