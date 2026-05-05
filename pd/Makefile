# Chipathon/pd/Makefile
#
# Wrapper around `openlane` for the per-design configs in pd/<design>/.
# Mirrors sim/Makefile's TB=<name> convention; here it is DESIGN=<name>.
#
# Usage:
#   make check                       # verify openlane + PDK_ROOT + config
#   make harden                      # default DESIGN=mac_array_4x4
#   make DESIGN=mac_array_4x4 harden # explicit
#   make summary
#   make view-gds
#   make clean
#   make list

ROOT     := $(abspath $(CURDIR)/..)
DESIGN   ?= mac_array_4x4

OPENLANE   ?= openlane
KLAYOUT    ?= klayout

# Run OpenLane inside the official Docker image (which bundles yosys,
# openroad, magic, netgen, klayout). Set DOCKERIZED=0 to use native tools.
DOCKERIZED ?= 1
DOCKER_FLAG := $(if $(filter 1,$(DOCKERIZED)),--dockerized,)

CONFIG   := $(CURDIR)/$(DESIGN)/config.json
RUNS_DIR := $(CURDIR)/$(DESIGN)/runs

DESIGNS  := $(notdir $(patsubst %/,%,$(dir $(wildcard $(CURDIR)/*/config.json))))

# Latest run by mtime; empty if no runs yet.
LATEST_RUN = $(shell ls -1dt $(RUNS_DIR)/RUN_* 2>/dev/null | head -1)

.PHONY: help list check harden latest summary view-gds clean clean-all

help:
	@echo "Usage: make DESIGN=<name> [DOCKERIZED=0|1] <target>"
	@echo "Targets: check  harden  latest  summary  view-gds  clean  clean-all  list  help"
	@echo "Designs: $(DESIGNS)"
	@echo "DOCKERIZED=$(DOCKERIZED)  (1 = run openlane in container; 0 = use native tools)"

list:
	@echo $(DESIGNS)

check:
	@command -v $(OPENLANE) >/dev/null 2>&1 \
	    || { echo "ERROR: '$(OPENLANE)' not on PATH"; exit 1; }
	@test -n "$$PDK_ROOT" \
	    || { echo "ERROR: PDK_ROOT is not set"; exit 1; }
	@test -f $(CONFIG) \
	    || { echo "ERROR: config not found: $(CONFIG)"; exit 1; }
	@echo "OK  openlane=$$(command -v $(OPENLANE))"
	@echo "OK  PDK_ROOT=$$PDK_ROOT"
	@echo "OK  design  =$(DESIGN) ($(CONFIG))"

harden: check
	$(OPENLANE) $(DOCKER_FLAG) $(CONFIG)

latest:
	@test -n "$(LATEST_RUN)" \
	    || { echo "No runs yet for $(DESIGN). Run: make DESIGN=$(DESIGN) harden"; exit 1; }
	@echo $(LATEST_RUN)

summary:
	@LATEST="$(LATEST_RUN)"; \
	test -n "$$LATEST" \
	    || { echo "No runs yet for $(DESIGN)."; exit 1; }; \
	echo "=== $(DESIGN): $$LATEST ==="; \
	METRICS=$$(find "$$LATEST" -name metrics.csv -type f | head -1); \
	if [ -n "$$METRICS" ]; then \
	    echo "metrics: $$METRICS"; \
	    head -1 "$$METRICS"; \
	    tail -1 "$$METRICS"; \
	else \
	    echo "(no metrics.csv yet)"; \
	fi; \
	echo; echo "Reports:"; \
	find "$$LATEST" -path '*/reports/signoff/*' -name '*.rpt' | head -10

view-gds:
	@LATEST="$(LATEST_RUN)"; \
	test -n "$$LATEST" || { echo "No runs yet for $(DESIGN)."; exit 1; }; \
	GDS=$$(find "$$LATEST" -name "$(DESIGN).gds" -type f | head -1); \
	test -n "$$GDS" || { echo "No GDS found under $$LATEST."; exit 1; }; \
	echo "Opening $$GDS in $(KLAYOUT)"; \
	$(KLAYOUT) "$$GDS" &

clean:
	rm -rf $(RUNS_DIR)

clean-all:
	@for d in $(DESIGNS); do \
	    echo "Cleaning $$d/runs/"; \
	    rm -rf $(CURDIR)/$$d/runs; \
	done
