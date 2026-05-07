# act_lut.sdc
#
# Block-level timing constraints for act_lut (rtl/act_lut.sv).
# Single core clock; 25% input/output delay budgets; synchronous
# active-low reset is treated as a false path.

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
