# Non-project simulation flow using exec xvlog/xelab/xsim
set VIV_BIN "D:/2021.2/Vivado/2021.2/bin"

cd D:/RICS_V_CNN/1DCNN_ACC

puts "=== xvlog ==="
set xvlog_args [list \
  --incr --relax -L uvm \
  --sv \
  D:/RICS_V_CNN/1DCNN_ACC/tb/tb_cnn_accelerator.sv \
  D:/RICS_V_CNN/1DCNN_ACC/rtl/cpu/alu.v \
  D:/RICS_V_CNN/1DCNN_ACC/rtl/axi_lite_addr_decode.v \
  D:/RICS_V_CNN/1DCNN_ACC/rtl/cpu/axi_lite_master.v \
  D:/RICS_V_CNN/1DCNN_ACC/rtl/axi_lite_slave_regs.v \
  D:/RICS_V_CNN/1DCNN_ACC/rtl/cpu/branch_unit.v \
  D:/RICS_V_CNN/1DCNN_ACC/rtl/cnn_accelerator_top.v \
  D:/RICS_V_CNN/1DCNN_ACC/rtl/cpu/ctrl_unit.v \
  D:/RICS_V_CNN/1DCNN_ACC/rtl/cpu/data_ram.v \
  D:/RICS_V_CNN/1DCNN_ACC/rtl/depthwise_conv_engine.v \
  D:/RICS_V_CNN/1DCNN_ACC/rtl/fake_bn_rom.v \
  D:/RICS_V_CNN/1DCNN_ACC/rtl/fake_weight_rom.v \
  D:/RICS_V_CNN/1DCNN_ACC/rtl/feature_buffer.v \
  D:/RICS_V_CNN/1DCNN_ACC/rtl/final_conv_engine.v \
  D:/RICS_V_CNN/1DCNN_ACC/rtl/gap_unit.v \
  D:/RICS_V_CNN/1DCNN_ACC/rtl/cpu/hazard_unit.v \
  D:/RICS_V_CNN/1DCNN_ACC/rtl/cpu/imm_gen.v \
  D:/RICS_V_CNN/1DCNN_ACC/rtl/initial_conv_engine.v \
  D:/RICS_V_CNN/1DCNN_ACC/rtl/input_buffer.v \
  D:/RICS_V_CNN/1DCNN_ACC/rtl/cpu/inst_rom.v \
  D:/RICS_V_CNN/1DCNN_ACC/rtl/maxpool_unit.v \
  D:/RICS_V_CNN/1DCNN_ACC/rtl/pointwise_conv_engine.v \
  D:/RICS_V_CNN/1DCNN_ACC/rtl/cpu/regfile.v \
  D:/RICS_V_CNN/1DCNN_ACC/rtl/requant_relu.v \
  D:/RICS_V_CNN/1DCNN_ACC/rtl/reset_sync.v \
  D:/RICS_V_CNN/1DCNN_ACC/rtl/cpu/riscv_top.v \
  D:/RICS_V_CNN/1DCNN_ACC/rtl/soc_top.v \
  -log D:/RICS_V_CNN/1DCNN_ACC/reports/timing_sweep/xvlog.log]

if {[catch {exec {*}${VIV_BIN}/xvlog {*}$xvlog_args} result]} {
    puts "xvlog FAILED: $result"
    exit 1
}
puts "xvlog PASSED"

puts "=== xelab ==="
if {[catch {exec ${VIV_BIN}/xelab --incr --relax -L xpm -L uvm -L xil_defaultlib \
  -s tb_snapshot \
  work.tb_cnn_accelerator \
  -log D:/RICS_V_CNN/1DCNN_ACC/reports/timing_sweep/xelab.log} result]} {
    puts "xelab FAILED: $result"
    exit 1
}
puts "xelab PASSED"

puts "=== xsim ==="
exec ${VIV_BIN}/xsim tb_snapshot --runall --log D:/RICS_V_CNN/1DCNN_ACC/reports/timing_sweep/xsim.log
puts "xsim done"

exit
