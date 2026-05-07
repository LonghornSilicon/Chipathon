# ctrl_io.sdc
#
# Block-level timing constraints for ctrl_io (rtl/ctrl_io.sv).
# This is a relatively wide-port leaf during standalone hardening
# (all data-plane signals are exposed); the same 25 ns clock and 25%
# I/O delay budget is used so it composes cleanly with the data-plane
# blocks at int4_mac_accel-top time.

set CLK_PORT   clk
set CLK_NAME   core_clk
set CLK_PERIOD 25.0
set IO_DELAY   [expr {0.25 * $CLK_PERIOD}]

create_clock -name $CLK_NAME -period $CLK_PERIOD [get_ports $CLK_PORT]

set_clock_uncertainty 0.25 [get_clocks $CLK_NAME]
set_clock_transition  0.15 [get_clocks $CLK_NAME]

set data_inputs [lsearch -inline -all -not -exact \
    [all_inputs] [get_ports $CLK_PORT]]

set_input_delay  -clock $CLK_NAME $IO_DELAY $data_inputs
set_output_delay -clock $CLK_NAME $IO_DELAY [all_outputs]

set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 $data_inputs
set_load 0.05 [all_outputs]

set_false_path -from [get_ports rst_n]
