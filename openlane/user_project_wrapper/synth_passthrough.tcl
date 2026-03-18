yosys -import
read_verilog -sv /project/build/wrapper_mapped.v
hierarchy -top user_project_wrapper
write_verilog -noattr $::env(RESULTS_DIR)/synthesis/user_project_wrapper.v
write_json $::env(synthesis_tmpfiles)/user_project_wrapper.json
tee -o $::env(synthesis_tmpfiles)/user_project_wrapper.stat.rep stat
tee -o $::env(REPORTS_DIR)/synthesis/1-synthesis.AREA_0.stat.rpt stat
