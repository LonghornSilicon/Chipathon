# int4_mac_accel.sdc
#
# Top-level timing constraints for int4_mac_accel. Targets the Tiny
# Tapeout pinout (clk, rst_n, ena, ui_in[7:0], uo_out[7:0],
# uio_in[7:0], uio_out[7:0], uio_oe[7:0]). The clock period mirrors
# the per-block constraints (25 ns / 40 MHz) so block-level STA
# results compose with the full chip.

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
set_false_path -from [get_ports ena]
