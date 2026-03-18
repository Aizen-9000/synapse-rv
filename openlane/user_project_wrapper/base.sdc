create_clock -name wb_clk_i -period 25.0 [get_ports wb_clk_i]
set_input_delay  5.0 -clock wb_clk_i [all_inputs]
set_output_delay 5.0 -clock wb_clk_i [all_outputs]
