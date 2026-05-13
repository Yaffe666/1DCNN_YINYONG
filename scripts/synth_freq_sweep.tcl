# Multi-frequency synthesis sweep
# Runs synth_design at 100MHz, 150MHz, 200MHz, saves reports per frequency

set proj_dir "D:/RICS_V_CNN/1DCNN_ACC"
set report_dir "${proj_dir}/reports/timing_sweep"
file mkdir $report_dir

set rtl_dir "${proj_dir}/rtl"
set cpu_dir "${rtl_dir}/cpu"

# Original constraint file (will be modified per frequency)
set xdc_template "${proj_dir}/constraints/soc_top.xdc"

# Clock periods to sweep
set freq_list {100MHz 150MHz 200MHz}
set period_list {10.000 6.667 5.000}

foreach freq $freq_list period $period_list {
  puts "============================================"
  puts " Starting synthesis: $freq (period=${period}ns)"
  puts "============================================"

  # Create project
  create_project -in_memory -part xcku040-ffva1156-2-i
  set_property target_language Verilog [current_project]
  set_property XPM_LIBRARIES XPM_MEMORY [current_project]

  # Add source files
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

  # Create and apply constraint
  set xdc_path "${report_dir}/clk_${freq}.xdc"
  set fh [open $xdc_path w]
  puts $fh "create_clock -period ${period} \[get_ports clk\]"
  close $fh
  read_xdc $xdc_path

  set TIME_start [clock seconds]

  # Run synthesis
  synth_design -top soc_top -part xcku040-ffva1156-2-i

  set elapsed [expr {[clock seconds] - $TIME_start}]
  set elapsed_min [expr {$elapsed / 60}]
  set elapsed_sec [expr {$elapsed % 60}]
  puts "Synthesis $freq completed in ${elapsed_min}m${elapsed_sec}s"

  # Save reports
  report_utilization -file "${report_dir}/${freq}_utilization.rpt"
  write_checkpoint -force "${report_dir}/${freq}_soc_top.dcp"

  # Close project for clean next run
  close_project
}

puts ""
puts "============================================"
puts " All frequency sweeps complete."
puts " Reports saved to: $report_dir"
puts "============================================"
