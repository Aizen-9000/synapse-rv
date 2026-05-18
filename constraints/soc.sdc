# =============================================================================
#  SDC Constraints — synapse_rv_soc  (Sky130, 50 MHz ref → 200 MHz CPU/NPU)
# =============================================================================
# Reference clock (crystal input)
create_clock -name clk_ref -period 20.000 [get_ports clk_ref]

# In real design, CPU/NPU clocks come from PLL hard macros.
# For synthesis purposes, declare them as generated clocks from ref:
create_generated_clock -name clk_cpu  -source [get_ports clk_ref] \
    -multiply_by 4 [get_pins u_pmu/clk_cpu]
create_generated_clock -name clk_npu  -source [get_ports clk_ref] \
    -multiply_by 4 [get_pins u_pmu/clk_npu]
create_generated_clock -name clk_peri -source [get_ports clk_ref] \
    -multiply_by 1 [get_pins u_pmu/clk_peri]

# Cross-domain false paths (properly handled by reset synchronizers in RTL)
set_false_path -from [get_clocks clk_cpu]  -to [get_clocks clk_npu]
set_false_path -from [get_clocks clk_npu]  -to [get_clocks clk_cpu]
set_false_path -from [get_clocks clk_cpu]  -to [get_clocks clk_peri]
set_false_path -from [get_clocks clk_peri] -to [get_clocks clk_cpu]

# Async resets
set_false_path -from [get_ports rst_por_n]

# I/O constraints relative to clk_ref
set_input_delay  -clock clk_ref -max 5.0 [all_inputs]
set_input_delay  -clock clk_ref -min 1.0 [all_inputs]
set_output_delay -clock clk_ref -max 5.0 [all_outputs]
set_output_delay -clock clk_ref -min 1.0 [all_outputs]

set_max_transition 2.0 [current_design]
set_max_capacitance 1.0 [current_design]
set_driving_cell -lib_cell sky130_fd_sc_hd__buf_8 [all_inputs]
set_load 0.2 [all_outputs]
