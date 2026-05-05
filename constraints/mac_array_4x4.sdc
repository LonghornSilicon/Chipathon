# mac_array_4x4.sdc
#
# Block-level timing constraints for mac_array_4x4 (rtl/mac_array_4x4.sv).
# Single core clock; 25% input/output delay budgets; synchronous active-low
# reset is treated as a false path until a reset synchronizer exists in RTL.
#
# Parameterized via Tcl variables so the same SDC can be retargeted by
# editing CLK_PERIOD only.

set CLK_PORT   clk
set CLK_NAME   core_clk
set CLK_PERIOD 25.0
set IO_DELAY   [expr {0.25 * $CLK_PERIOD}]

create_clock -name $CLK_NAME -period $CLK_PERIOD [get_ports $CLK_PORT]

set_clock_uncertainty 0.25 [get_clocks $CLK_NAME]
set_clock_transition  0.15 [get_clocks $CLK_NAME]

# OpenSTA does not ship `remove_from_collection`, so build the data-input
# port list with a Tcl `lsearch` exclusion of the clock port. Same idiom
# used by the upstream OpenLane example SDCs.
set data_inputs [lsearch -inline -all -not -exact \
    [all_inputs] [get_ports $CLK_PORT]]

set_input_delay  -clock $CLK_NAME $IO_DELAY $data_inputs
set_output_delay -clock $CLK_NAME $IO_DELAY [all_outputs]

set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 $data_inputs
set_load 0.05 [all_outputs]

# TODO: replace with a proper reset-synchronizer constraint once one
# exists in RTL. For now rst_n is treated as async w.r.t. core_clk.
set_false_path -from [get_ports rst_n]
