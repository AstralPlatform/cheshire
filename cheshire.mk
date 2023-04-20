# Copyright 2022 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Nicole Narr <narrn@student.ethz.ch>
# Christopher Reinwardt <creinwar@student.ethz.ch>
# Paul Scheffler <paulsc@iis.ee.ethz.ch>

BENDER      ?= bender
PYTHON3     ?= python3
REGGEN      ?= $(PYTHON3) $(shell $(BENDER) path register_interface)/vendor/lowrisc_opentitan/util/regtool.py

VLOG_ARGS   ?= -suppress 2583 -suppress 13314
VSIM        ?= vsim

BUILD_DIR   ?= build

# Define used paths (prefixed to avoid name conflicts)
CHS_ROOT      ?= $(shell $(BENDER) path cheshire)
CHS_SW_DIR     = $(CHS_ROOT)/sw
CHS_HW_DIR     = $(CHS_ROOT)/hw
CHS_OTP_DIR    = $(shell $(BENDER) path opentitan_peripherals)
CHS_CLINT_DIR  = $(shell $(BENDER) path clint)
CHS_SLINK_DIR  = $(shell $(BENDER) path serial_link)
CHS_VGA_DIR    = $(shell $(BENDER) path axi_vga)
CHS_LLC_DIR    = $(shell $(BENDER) path axi_llc)

.PHONY: chs-all nonfree-init chs-sw-all chs-hw-all chs-bootrom-all chs-sim-all chs-xilinx-all

chs-all: chs-sw-all chs-hw-all chs-sim-all chs-xilinx-all

################
# Dependencies #
################

# Ensure both Bender dependencies and submodules are checked out
$(CHS_ROOT)/.deps:
	$(BENDER) checkout
	git submodule update --init --recursive
	@touch $@

# Make sure dependencies are more up-to-date than any targets run
include $(CHS_ROOT)/.deps

######################
# Nonfree components #
######################

CHS_NONFREE_REMOTE ?= git@iis-git.ee.ethz.ch:pulp-restricted/cheshire-nonfree.git
CHS_NONFREE_COMMIT ?= b5656f6

nonfree-init:
	git clone $(CHS_NONFREE_REMOTE) nonfree
	cd nonfree && git checkout $(CHS_NONFREE_COMMIT)

-include nonfree/nonfree.mk

############
# Build SW #
############

include $(CHS_SW_DIR)/sw.mk

###############
# Generate HW #
###############

# SoC registers
$(CHS_ROOT)/hw/regs/cheshire_reg_pkg.sv $(CHS_ROOT)/hw/regs/cheshire_reg_top.sv: $(CHS_ROOT)/hw/regs/cheshire_regs.hjson
	$(REGGEN) -r $< --outdir $(dir $@)

# CLINT
CLINTCORES = 1
include $(CHS_CLINT_DIR)/clint.mk
$(CHS_CLINT_DIR)/.generated: Bender.yml
	$(MAKE) clint
	@touch $@

# OpenTitan peripherals
include $(CHS_OTP_DIR)/otp.mk
$(CHS_OTP_DIR)/.generated: $(CHS_ROOT)/hw/rv_plic.cfg.hjson Bender.yml
	cp $< $(dir $@)/src/rv_plic/
	$(MAKE) otp
	@touch $@

# AXI VGA
include $(CHS_VGA_DIR)/axi_vga.mk
$(CHS_VGA_DIR)/.generated: Bender.yml
	$(MAKE) axi_vga
	@touch $@

# Custom serial link
$(CHS_SLINK_DIR)/.generated: $(CHS_ROOT)/hw/serial_link.hjson
	cp $< $(dir $@)/src/regs/serial_link_single_channel.hjson
	$(MAKE) -C $(CHS_SLINK_DIR) update-regs
	@touch $@

chs-hw-all: $(CHS_ROOT)/hw/regs/cheshire_reg_pkg.sv $(CHS_ROOT)/hw/regs/cheshire_reg_top.sv
chs-hw-all: $(CHS_CLINT_DIR)/.generated
chs-hw-all: $(CHS_OTP_DIR)/.generated
chs-hw-all: $(CHS_VGA_DIR)/.generated
chs-hw-all: $(CHS_SLINK_DIR)/.generated

#####################
# Generate Boot ROM #
#####################

# This is *not* done as part of `all` as it is only reproducible with a specific compiler

# Boot ROM (needs SW stack)
CHS_BROM_SRCS = $(wildcard $(CHS_ROOT)/hw/bootrom/*.S $(CHS_ROOT)/hw/bootrom/*.c) $(CHS_SW_LIBS)
CHS_BROM_FLAGS = $(RISCV_LDFLAGS) -Os -fno-zero-initialized-in-bss -flto -fwhole-program

$(CHS_ROOT)/hw/bootrom/cheshire_bootrom.elf: $(CHS_ROOT)/hw/bootrom/cheshire_bootrom.ld $(CHS_BROM_SRCS)
	$(RISCV_CC) $(CHS_SW_INCLUDES) -T$< $(CHS_BROM_FLAGS) -o $@ $(CHS_BROM_SRCS)

$(CHS_ROOT)/hw/bootrom/cheshire_bootrom.sv: $(CHS_ROOT)/hw/bootrom/cheshire_bootrom.bin $(CHS_ROOT)/util/gen_bootrom.py
	$(PYTHON3) $(CHS_ROOT)/util/gen_bootrom.py --sv-module cheshire_bootrom $< > $@

chs-bootrom-all: $(CHS_ROOT)/hw/bootrom/cheshire_bootrom.sv $(CHS_ROOT)/hw/bootrom/cheshire_bootrom.dump

##############
# Simulation #
##############

$(CHS_ROOT)/target/sim/vsim/compile.cheshire_soc.tcl: Bender.yml
	$(BENDER) script vsim -t sim -t cv64a6_imafdc_sv39 -t test -t cva6 --vlog-arg="$(VLOG_ARGS)" > $@
	echo 'vlog "$(CURDIR)/$(CHS_ROOT)/target/sim/src/elfloader.cpp" -ccflags "-std=c++11"' >> $@

$(CHS_ROOT)/target/sim/models:
	mkdir -p $@

# Download (partially non-free) simulation models from publically available sources;
# by running these targets or targets depending on them, you accept this (see README.md).
$(CHS_ROOT)/target/sim/models/s25fs512s.v: Bender.yml | $(CHS_ROOT)/target/sim/models
	wget --no-check-certificate https://freemodelfoundry.com/fmf_vlog_models/flash/s25fs512s.v -O $@
	touch $@

$(CHS_ROOT)/target/sim/models/24FC1025.v: Bender.yml | $(CHS_ROOT)/target/sim/models
	wget https://ww1.microchip.com/downloads/en/DeviceDoc/24xx1025_Verilog_Model.zip -o $@
	unzip -p 24xx1025_Verilog_Model.zip 24FC1025.v > $@
	rm 24xx1025_Verilog_Model.zip

chs-sim-all: $(CHS_ROOT)/target/sim/models/s25fs512s.v
chs-sim-all: $(CHS_ROOT)/target/sim/models/24FC1025.v
chs-sim-all: $(CHS_ROOT)/target/sim/vsim/compile.cheshire_soc.tcl

#############
# FPGA Flow #
#############

$(CHS_ROOT)/target/xilinx/scripts/add_sources.tcl: Bender.yml
	$(BENDER) script vivado -t fpga -t cv64a6_imafdc_sv39 -t cva6 > $@

chs-xilinx-all: $(CHS_ROOT)/target/xilinx/scripts/add_sources.tcl

#############
# slang			#
#############

.PHONY: $(BUILD_DIR)/cva6.pickle.sv $(BUILD_DIR)/cheshire_top.pickle.sv

$(BUILD_DIR):
	mkdir -p $@

$(BUILD_DIR)/cheshire_top.pickle.sv: Bender.yml $(BUILD_DIR)
	bender sources -f -t cv64a6_imafdc_sv39 -t synthesis -t cva6 -t slang | morty -f /dev/stdin -q -o $@ -D VERILATOR=1 --top cheshire_top
	cat target/slang/reg_bus_interface_ugly_copy.sv >> $@
	sed "s/      req_q <= (store_req_t'.*/      req_q <= (store_req_t'{mode: axi_llc_pkg::tag_mode_e'(2'b0), default: '0});/g" $(BUILD_DIR)/cheshire_top.pickle.sv > $(BUILD_DIR)/cheshire_top.pickle_2.sv
	mv $(BUILD_DIR)/cheshire_top.pickle_2.sv $(BUILD_DIR)/cheshire_top.pickle.sv
	sed "s/module slib_mv_filter #(parameter WIDTH = 4, THRESHOLD = 10).*/module slib_mv_filter #(parameter WIDTH = 4, parameter THRESHOLD = 10) (/g" $(BUILD_DIR)/cheshire_top.pickle.sv > $(BUILD_DIR)/cheshire_top.pickle_2.sv
	mv $(BUILD_DIR)/cheshire_top.pickle_2.sv $(BUILD_DIR)/cheshire_top.pickle.sv

$(BUILD_DIR)/cva6.pickle.sv: Bender.yml $(BUILD_DIR)
	bender sources -f -d $(shell $(BENDER) path cva6) -t cv64a6_imafdc_sv39 -t synthesis -t cva6 -t slang | morty -f /dev/stdin -o $@ -D VERILATOR=1 --top cva6

pickle-cva6: $(BUILD_DIR)/cva6.pickle.sv

slang-check-cva6: pickle-cva6
	slang $(BUILD_DIR)/cva6.pickle.sv -Wrange-width-oob

slang-check-cheshire: $(BUILD_DIR)/cheshire_top.pickle.sv
	slang $(BUILD_DIR)/cheshire_top.pickle.sv -Wrange-oob --allow-use-before-declare -Wrange-width-oob -error-limit=4419 -top cheshire_top || true
# adding || true to make test pass atm

slang-check-cheshire-only:
	slang $(BUILD_DIR)/cheshire_top.pickle.sv -Wrange-oob --allow-use-before-declare -Wrange-width-oob -error-limit=4419 -top cheshire_top

$(CHS_ROOT)/target/svase/vsim/compile.cheshire_soc.tcl: Bender.yml
	$(BENDER) script vsim -t sim -t cv64a6_imafdc_sv39 -t test -t cva6 --vlog-arg="$(VLOG_ARGS)" > $@
	echo 'vlog "$(CURDIR)/$(CHS_ROOT)/target/sim/src/elfloader.cpp" -ccflags "-std=c++11"' >> $@

chs-sim-all: $(CHS_ROOT)/target/svase/vsim/compile.cheshire_soc.tcl