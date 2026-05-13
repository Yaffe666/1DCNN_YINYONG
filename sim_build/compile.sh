#!/bin/bash
set -e
BIN="D:/2021.2/Vivado/2021.2/bin"
RTL="D:/RICS_V_CNN/1DCNN_ACC/rtl"
TB="D:/RICS_V_CNN/1DCNN_ACC/tb"
BUILD="D:/RICS_V_CNN/1DCNN_ACC/sim_build"
cd $BUILD

echo "=== Compiling Verilog sources ==="
"$BIN/xvlog" -sv "$TB/tb_cnn_accelerator.sv" \
  "$RTL/cpu/alu.v" "$RTL/axi_lite_addr_decode.v" "$RTL/cpu/axi_lite_master.v" \
  "$RTL/axi_lite_slave_regs.v" "$RTL/cpu/branch_unit.v" "$RTL/cnn_accelerator_top.v" \
  "$RTL/cpu/ctrl_unit.v" "$RTL/cpu/data_ram.v" "$RTL/depthwise_conv_engine.v" \
  "$RTL/fake_bn_rom.v" "$RTL/fake_weight_rom.v" "$RTL/feature_buffer.v" \
  "$RTL/final_conv_engine.v" "$RTL/gap_unit.v" "$RTL/cpu/hazard_unit.v" \
  "$RTL/cpu/imm_gen.v" "$RTL/initial_conv_engine.v" "$RTL/input_buffer.v" \
  "$RTL/cpu/inst_rom.v" "$RTL/maxpool_unit.v" "$RTL/pointwise_conv_engine.v" \
  "$RTL/cpu/regfile.v" "$RTL/requant_relu.v" "$RTL/reset_sync.v" \
  "$RTL/cpu/riscv_top.v" "$RTL/soc_top.v"

echo "=== Elaborating ==="
"$BIN/xelab" tb_cnn_accelerator -L xpm -s tb_cnn_top

echo "=== Running simulation ==="
"$BIN/xsim" tb_cnn_top --runall
