# Chipathon/sim/Makefile
#
# Per-block simulation driver for the testbenches in ../tb/. Supports
# both Icarus Verilog (default; fast bring-up) and Verilator (for
# heavier runs and FST waveforms). Per-TB build artifacts and logs land
# under sim/<TB>/{build,logs}/ so nothing leaks into the repo root.
#
# Usage:
#   make TB=sign_lfsr run
#   make TB=tq_top SEED=3 VEC=1 VERBOSE=1 run
#   make all
#   make TB=sign_lfsr clean
#   make list
#   make goldens                 # regenerate ../tb/golden/out/*.{mem,hex}
#   make TB=tq_top SIM=verilator run    # use verilator instead of iverilog
#
# Add a new testbench by writing tb/tb_<name>.sv and adding one line:
#   SRCS_<name> := $(RTL_DIR)/<files>.sv

# Use relative paths everywhere — GNU make can't handle the space in
# the parent directory name ("Longhorn Silicon"), and quoting only
# helps for shell commands, not target names.
RTL_DIR    := ../rtl
TB_DIR     := ../tb
GOLDEN_OUT := ../tb/golden/out

# Default simulator: iverilog (faster install/build, good SV2012 coverage).
# Override with SIM=verilator to use verilator.
SIM ?= iverilog

IVERILOG ?= iverilog
VVP      ?= vvp
IFLAGS   := -g2012 -Wall -Wno-portbind

VERILATOR ?= verilator
VFLAGS    := --binary -sv --assert --trace-fst -Wall -Wno-fatal -Wno-UNUSEDSIGNAL

# Python interpreter for golden-vector generation. Override on the command
# line if numpy lives under a different prefix.
PYTHON ?= /opt/homebrew/Caskroom/miniforge/base/envs/lhs/bin/python

TB      ?= sign_lfsr
SEED    ?= 1
VERBOSE ?=
VEC     ?= 0

SIMDIR := $(TB)
BUILD  := $(SIMDIR)/build
LOGS   := $(SIMDIR)/logs
WAVES  := $(SIMDIR)/waves

# Per-TB RTL filelists (leaf modules first).
SRCS_sign_lfsr     := $(RTL_DIR)/sign_lfsr.sv
SRCS_codebook_rom  := $(RTL_DIR)/codebook_rom.sv
SRCS_bit_packer    := $(RTL_DIR)/bit_packer.sv
SRCS_wht64         := $(RTL_DIR)/wht64.sv
SRCS_norm2_acc     := $(RTL_DIR)/norm2_acc.sv
SRCS_rsqrt_unit    := $(RTL_DIR)/rsqrt_unit.sv
SRCS_quant_unit    := $(RTL_DIR)/quant_unit.sv $(RTL_DIR)/codebook_rom.sv
SRCS_tq_top        := $(RTL_DIR)/sign_lfsr.sv  $(RTL_DIR)/wht64.sv \
                      $(RTL_DIR)/norm2_acc.sv  $(RTL_DIR)/rsqrt_unit.sv \
                      $(RTL_DIR)/codebook_rom.sv $(RTL_DIR)/quant_unit.sv \
                      $(RTL_DIR)/bit_packer.sv $(RTL_DIR)/tq_ctrl.sv \
                      $(RTL_DIR)/tq_top.sv

SRCS := $(SRCS_$(TB)) $(TB_DIR)/tb_$(TB).sv

PLUSARGS := +seed=$(SEED) +vec=$(VEC) $(if $(VERBOSE),+verbose,)

TB_LIST := $(patsubst SRCS_%,%,$(filter SRCS_%,$(.VARIABLES)))

# iverilog produces a .vvp; verilator produces a binary.
# BIN     : path from the sim/ root (for the build rule)
# BIN_REL : path inside SIMDIR (for the run command which cd's first)
ifeq ($(SIM),iverilog)
  BIN     := $(BUILD)/tb_$(TB).vvp
  BIN_REL := build/tb_$(TB).vvp
  RUN     := $(VVP) -N $(BIN_REL)
else ifeq ($(SIM),verilator)
  # Verilator spawns its own GNU make in --Mdir; that nested make cannot
  # handle the space in the parent path ("Longhorn Silicon"). Build under
  # /tmp/<TB>/ instead and have the run target reach into it via symlink.
  VBUILD  := /tmp/tq_$(TB)/build
  BIN     := $(VBUILD)/Vtb_$(TB)
  BIN_REL := build/Vtb_$(TB)
  RUN     := ./$(BIN_REL)
else
  $(error Unknown SIM=$(SIM); use iverilog or verilator)
endif

.PHONY: build run waves view all clean clean-all list help goldens

help:
	@echo "Usage: make TB=<name> [SIM=iverilog|verilator] [SEED=N] [VEC=N] [VERBOSE=1] <target>"
	@echo "Targets:  build  run  waves  view  all  clean  clean-all  list  goldens  help"
	@echo "TBs:      $(TB_LIST)"
	@echo "SIM=$(SIM)"

list:
	@echo $(TB_LIST)

# Regenerate golden vectors.
goldens:
	@cd .. && $(PYTHON) -m tb.golden.gen_vectors --n 8

$(BUILD) $(LOGS) $(WAVES):
	@mkdir -p $@

ifeq ($(SIM),iverilog)
$(BIN): $(SRCS) | $(BUILD) $(LOGS)
	$(IVERILOG) $(IFLAGS) -s tb_$(TB) -o $@ $(SRCS)
else
$(BIN): $(SRCS) | $(LOGS)
	@mkdir -p $(VBUILD)
	@rm -rf $(BUILD)
	@mkdir -p $(SIMDIR)
	@ln -sfn $(VBUILD) $(BUILD)
	$(VERILATOR) $(VFLAGS) --top-module tb_$(TB) \
	    --Mdir $(VBUILD) -o Vtb_$(TB) $(SRCS)
endif

build: $(BIN)

# Most TBs read .mem/.hex via paths relative to sim/<TB>/.
run: build $(GOLDEN_OUT)/signs.mem | $(LOGS)
	@echo "[$(TB) sim=$(SIM)] running with $(PLUSARGS)"
	@cd $(SIMDIR) && $(RUN) $(PLUSARGS) 2>&1 | tee logs/run.log

# Run with FST/VCD tracing enabled.
waves: build | $(WAVES) $(LOGS)
	@echo "[$(TB)] running with +trace"
	@cd $(WAVES) && ../../$(RUN) +trace $(PLUSARGS) 2>&1 | tee ../logs/waves.log

VIEWER ?= gtkwave
view:
	@test -f $(WAVES)/waves.fst || test -f $(WAVES)/waves.vcd || { \
	    echo "No waveform yet. Run: make TB=$(TB) waves"; exit 1; }
	@WV=$$(ls -1t $(WAVES)/waves.fst $(WAVES)/waves.vcd 2>/dev/null | head -1); \
	$(VIEWER) "$$WV" &

$(GOLDEN_OUT)/signs.mem:
	@$(MAKE) goldens

all: $(GOLDEN_OUT)/signs.mem
	@$(MAKE) TB=sign_lfsr     run
	@$(MAKE) TB=codebook_rom  run
	@$(MAKE) TB=bit_packer    run
	@$(MAKE) TB=wht64         run
	@$(MAKE) TB=norm2_acc     run
	@$(MAKE) TB=rsqrt_unit    run
	@$(MAKE) TB=quant_unit    run
	@$(MAKE) TB=tq_top        run

clean:
	rm -rf $(SIMDIR)

clean-all:
	rm -rf $(foreach t,$(TB_LIST),$(CURDIR)/$(t))
