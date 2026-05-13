# Multi-frequency implementation sweep with timing analysis

set proj_dir "D:/RICS_V_CNN/1DCNN_ACC"
set report_dir "${proj_dir}/reports/timing_sweep"
file mkdir $report_dir

set freq_list {100MHz 150MHz 200MHz}
set period_list {10.000 6.667 5.000}

foreach freq $freq_list period $period_list {
  puts "============================================"
  puts " Implementation: $freq (period=${period}ns)"
  puts "============================================"

  create_project -in_memory -part xcku040-ffva1156-2-i
  set_property target_language Verilog [current_project]
  set_property XPM_LIBRARIES XPM_MEMORY [current_project]

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

  set xdc_path "${report_dir}/clk_${freq}.xdc"
  read_xdc $xdc_path

  set_param general.maxThreads 16

  set TIME_start [clock seconds]

  puts "  synth_design..."
  synth_design -top soc_top -part xcku040-ffva1156-2-i
  set synth_elapsed [expr {[clock seconds] - $TIME_start}]
  puts "  synth_design done: ${synth_elapsed}s"

  puts "  opt_design..."
  opt_design
  puts "  place_design..."
  place_design
  puts "  phys_opt_design..."
  phys_opt_design
  puts "  route_design..."
  route_design

  set impl_elapsed [expr {[clock seconds] - $TIME_start}]
  set impl_min [expr {$impl_elapsed / 60}]
  set impl_sec [expr {$impl_elapsed % 60}]

  puts "  Writing timing report..."
  report_timing_summary -file "${report_dir}/${freq}_timing.rpt"
  report_utilization -file "${report_dir}/${freq}_impl_utilization.rpt"
  write_checkpoint -force "${report_dir}/${freq}_impl.dcp"

  puts "  $freq done in ${impl_min}m${impl_sec}s"
  puts ""

  close_project
}

puts "============================================"
puts " All implementation sweeps complete."
puts " Reports: $report_dir"
puts "============================================"
