# 150MHz v9 — final_conv S_IC_PREPROC + feat_buf wr reg + AggressiveExplore
set proj_dir "D:/RICS_V_CNN/1DCNN_ACC"
set report_dir "${proj_dir}/reports/timing_sweep"
file mkdir $report_dir

create_project -in_memory -part xcku040-ffva1156-2-i
set_property target_language Verilog [current_project]
set_property XPM_LIBRARIES XPM_MEMORY [current_project]
set_param general.maxThreads 16

read_verilog -library xil_defaultlib {
  D:/RICS_V_CNN/1DCNN_ACC/rtl/cpu/alu.v
  D:/RICS_V_CNN/1DCNN_ACC/rtl/axi_lite_addr_decode.v
  D:/RICS_V_CNN/1DCNN_ACC/rtl/cpu/axi_lite_master.v
  D:/RICS_V_CNN/1DCNN_ACC/rtl/axi_lite_slave_regs.v
  D:/RICS_V_CNN/1DCNN_ACC/rtl/cpu/branch_unit.v
  D:/RICS_V_CNN/1DCNN_ACC/rtl/cnn_accelerator_top.v
  D:/RICS_V_CNN/1DCNN_ACC/rtl/cpu/ctrl_unit.v
  D:/RICS_V_CNN/1DCNN_ACC/rtl/cpu/data_ram.v
  D:/RICS_V_CNN/1DCNN_ACC/rtl/depthwise_conv_engine.v
  D:/RICS_V_CNN/1DCNN_ACC/rtl/fake_bn_rom.v
  D:/RICS_V_CNN/1DCNN_ACC/rtl/fake_weight_rom.v
  D:/RICS_V_CNN/1DCNN_ACC/rtl/feature_buffer.v
  D:/RICS_V_CNN/1DCNN_ACC/rtl/final_conv_engine.v
  D:/RICS_V_CNN/1DCNN_ACC/rtl/gap_unit.v
  D:/RICS_V_CNN/1DCNN_ACC/rtl/cpu/hazard_unit.v
  D:/RICS_V_CNN/1DCNN_ACC/rtl/cpu/imm_gen.v
  D:/RICS_V_CNN/1DCNN_ACC/rtl/initial_conv_engine.v
  D:/RICS_V_CNN/1DCNN_ACC/rtl/input_buffer.v
  D:/RICS_V_CNN/1DCNN_ACC/rtl/cpu/inst_rom.v
  D:/RICS_V_CNN/1DCNN_ACC/rtl/maxpool_unit.v
  D:/RICS_V_CNN/1DCNN_ACC/rtl/pointwise_conv_engine.v
  D:/RICS_V_CNN/1DCNN_ACC/rtl/cpu/regfile.v
  D:/RICS_V_CNN/1DCNN_ACC/rtl/requant_relu.v
  D:/RICS_V_CNN/1DCNN_ACC/rtl/reset_sync.v
  D:/RICS_V_CNN/1DCNN_ACC/rtl/cpu/riscv_top.v
  D:/RICS_V_CNN/1DCNN_ACC/rtl/soc_top.v
}

set xdc_fh [open "${report_dir}/clk_150MHz_v9.xdc" w]
puts $xdc_fh "create_clock -period 6.667 \[get_ports clk\]"
close $xdc_fh
read_xdc "${report_dir}/clk_150MHz_v9.xdc"

set TIME_start [clock seconds]

puts "============================================================"
puts "  150MHz v9 — AggressiveExplore"
puts "============================================================"
synth_design -top soc_top -part xcku040-ffva1156-2-i
puts "  synth_design: [expr {[clock seconds] - $TIME_start}]s"

opt_design
place_design -directive ExtraTimingOpt
phys_opt_design -directive AggressiveExplore
route_design -directive AggressiveExplore

set elapsed [expr {[clock seconds] - $TIME_start}]
puts "  150MHz_v9 done in [expr {$elapsed/60}]m[expr {$elapsed%60}]s"

report_timing_summary -file "${report_dir}/150MHz_v9_timing.rpt"
report_utilization -file "${report_dir}/150MHz_v9_utilization.rpt"
write_checkpoint -force "${report_dir}/150MHz_v9_impl.dcp"

close_project
puts "All done."
