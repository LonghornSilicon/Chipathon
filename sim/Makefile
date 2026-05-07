# Chipathon/sim/Makefile
#
# Verilator driver for the testbenches in ../tb/. Per-TB build artifacts
# and logs land under sim/<TB>/{build,logs}/ so nothing leaks into the
# repo root (no stray obj_dir/).
#
# Usage:
#   make TB=int4_pe run
#   make TB=mac_array_4x4 SEED=42 VERBOSE=1 run
#   make all
#   make TB=int4_pe clean
#   make list
#
# Add a new testbench by writing tb/tb_<name>.sv and adding one line:
#   SRCS_<name> := $(RTL_DIR)/<files>.sv

ROOT     := $(abspath $(CURDIR)/..)
RTL_DIR  := $(ROOT)/rtl
TB_DIR   := $(ROOT)/tb

VERILATOR ?= verilator
VFLAGS    := --binary -sv --assert --trace-fst -Wall -Wno-fatal -Wno-UNUSEDSIGNAL

TB      ?= int4_pe
SEED    ?= 1
VERBOSE ?=

SIMDIR := $(CURDIR)/$(TB)
BUILD  := $(SIMDIR)/build
LOGS   := $(SIMDIR)/logs
WAVES  := $(SIMDIR)/waves
BIN    := $(BUILD)/Vtb_$(TB)

# Per-TB RTL filelists (leaf modules first).
SRCS_int4_pe       := $(RTL_DIR)/int4_pe.sv
SRCS_mac_array_4x4 := $(RTL_DIR)/int4_pe.sv $(RTL_DIR)/mac_array_4x4.sv
SRCS_accum_bank    := $(RTL_DIR)/accum_bank.sv
SRCS_requant_sat   := $(RTL_DIR)/requant_sat.sv
SRCS_act_lut       := $(RTL_DIR)/act_lut.sv
SRCS_weight_rom    := $(RTL_DIR)/weight_rom.sv
SRCS_act_streamer  := $(RTL_DIR)/act_streamer.sv
SRCS_ctrl_io       := $(RTL_DIR)/int4_pe.sv $(RTL_DIR)/mac_array_4x4.sv \
                      $(RTL_DIR)/accum_bank.sv $(RTL_DIR)/weight_rom.sv \
                      $(RTL_DIR)/act_streamer.sv $(RTL_DIR)/requant_sat.sv \
                      $(RTL_DIR)/act_lut.sv $(RTL_DIR)/ctrl_io.sv
SRCS_int4_mac_accel := $(RTL_DIR)/int4_pe.sv $(RTL_DIR)/mac_array_4x4.sv \
                      $(RTL_DIR)/accum_bank.sv $(RTL_DIR)/weight_rom.sv \
                      $(RTL_DIR)/act_streamer.sv $(RTL_DIR)/requant_sat.sv \
                      $(RTL_DIR)/act_lut.sv $(RTL_DIR)/ctrl_io.sv \
                      $(RTL_DIR)/int4_mac_accel.sv

SRCS := $(SRCS_$(TB)) $(TB_DIR)/tb_$(TB).sv

PLUSARGS := +seed=$(SEED) $(if $(VERBOSE),+verbose,)

TB_LIST := $(patsubst SRCS_%,%,$(filter SRCS_%,$(.VARIABLES)))

.PHONY: build run waves view all clean clean-all list help

help:
	@echo "Usage: make TB=<name> [SEED=N] [VERBOSE=1] <target>"
	@echo "Targets:  build  run  waves  view  all  clean  clean-all  list  help"
	@echo "TBs:      $(TB_LIST)"

list:
	@echo $(TB_LIST)

$(BUILD) $(LOGS) $(WAVES):
	@mkdir -p $@

$(BIN): $(SRCS) | $(BUILD) $(LOGS)
	$(VERILATOR) $(VFLAGS) --top-module tb_$(TB) \
	    --Mdir $(BUILD) -o Vtb_$(TB) $(SRCS)

build: $(BIN)

run: build
	@echo "[$(TB)] running with $(PLUSARGS)"
	@$(BIN) $(PLUSARGS) 2>&1 | tee $(LOGS)/run.log

# Run with FST tracing enabled; waveform lands at $(WAVES)/waves.fst
# because we cd into $(WAVES) before invoking the binary.
waves: build | $(WAVES)
	@echo "[$(TB)] running with +trace (FST -> $(WAVES)/waves.fst)"
	@cd $(WAVES) && $(BIN) +trace $(PLUSARGS) 2>&1 | tee $(LOGS)/waves.log

# Open the most recent FST in a viewer. Override with VIEWER=surfer.
VIEWER ?= gtkwave
view:
	@test -f $(WAVES)/waves.fst || { \
	    echo "No waveform yet. Run: make TB=$(TB) waves"; exit 1; }
	$(VIEWER) $(WAVES)/waves.fst &

all:
	@$(MAKE) TB=int4_pe       run
	@$(MAKE) TB=mac_array_4x4 run
	@$(MAKE) TB=accum_bank    run
	@$(MAKE) TB=requant_sat   run
	@$(MAKE) TB=act_lut       run
	@$(MAKE) TB=weight_rom    run
	@$(MAKE) TB=act_streamer  run
	@$(MAKE) TB=ctrl_io       run
	@$(MAKE) TB=int4_mac_accel run

clean:
	rm -rf $(SIMDIR)

clean-all:
	rm -rf $(foreach t,$(TB_LIST),$(CURDIR)/$(t))
