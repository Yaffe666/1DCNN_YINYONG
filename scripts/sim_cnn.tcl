# CNN accelerator simulation — batch mode
create_project -in_memory -part xcku040-ffva1156-2-i
set_property target_language Verilog [current_project]
set_property XPM_LIBRARIES XPM_MEMORY [current_project]

set RTL_DIR "D:/RICS_V_CNN/1DCNN_ACC/rtl"
set TB_DIR  "D:/RICS_V_CNN/1DCNN_ACC/tb"

# Add all sources
add_files -fileset sim_1 -sv ${TB_DIR}/tb_cnn_accelerator.sv

add_files -fileset sim_1 \
  ${RTL_DIR}/cpu/alu.v \
  ${RTL_DIR}/axi_lite_addr_decode.v \
  ${RTL_DIR}/cpu/axi_lite_master.v \
  ${RTL_DIR}/axi_lite_slave_regs.v \
  ${RTL_DIR}/cpu/branch_unit.v \
  ${RTL_DIR}/cnn_accelerator_top.v \
  ${RTL_DIR}/cpu/ctrl_unit.v \
  ${RTL_DIR}/cpu/data_ram.v \
  ${RTL_DIR}/depthwise_conv_engine.v \
  ${RTL_DIR}/fake_bn_rom.v \
  ${RTL_DIR}/fake_weight_rom.v \
  ${RTL_DIR}/feature_buffer.v \
  ${RTL_DIR}/final_conv_engine.v \
  ${RTL_DIR}/gap_unit.v \
  ${RTL_DIR}/cpu/hazard_unit.v \
  ${RTL_DIR}/cpu/imm_gen.v \
  ${RTL_DIR}/initial_conv_engine.v \
  ${RTL_DIR}/input_buffer.v \
  ${RTL_DIR}/cpu/inst_rom.v \
  ${RTL_DIR}/maxpool_unit.v \
  ${RTL_DIR}/pointwise_conv_engine.v \
  ${RTL_DIR}/cpu/regfile.v \
  ${RTL_DIR}/requant_relu.v \
  ${RTL_DIR}/reset_sync.v \
  ${RTL_DIR}/cpu/riscv_top.v \
  ${RTL_DIR}/soc_top.v

set_property top tb_cnn_accelerator [get_filesets sim_1]

puts "Starting simulation..."
launch_simulation

run all

puts "Simulation finished."
close_sim
close_project
exit
