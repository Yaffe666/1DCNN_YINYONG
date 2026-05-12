read_verilog D:/RICS_V_CNN/1DCNN_ACC/rtl/input_buffer.v
synth_design -top input_buffer -part xcku040-ffva1156-2-i -mode out_of_context
report_utilization -file D:/RICS_V_CNN/1DCNN_ACC/reports/input_buffer_util.rpt
report_timing_summary -file D:/RICS_V_CNN/1DCNN_ACC/reports/input_buffer_timing.rpt
exit
