# Vivado 2021.2 project script
# =============================================================================
# Usage: vivado -mode batch -source scripts/synth_soc_top.tcl
# Or:    vivado -mode tcl   -> source scripts/synth_soc_top.tcl
# =============================================================================

set PROJECT_DIR   "D:/RICS_V_CNN/1DCNN_ACC/vivado_project"
set PROJECT_NAME  "cnn_accelerator_soc"
set PART          "xcku040-ffva1156-2-i"
set TOP_MODULE    "soc_top"
set RTL_DIR       "D:/RICS_V_CNN/1DCNN_ACC/rtl"
set CONSTRS_DIR   "D:/RICS_V_CNN/1DCNN_ACC/constraints"
set REPORTS_DIR   "D:/RICS_V_CNN/1DCNN_ACC/reports"

# ---- create project ----
file delete -force ${PROJECT_DIR}

create_project ${PROJECT_NAME} ${PROJECT_DIR} -part ${PART}

# ---- source files (Verilog) ----
set_property target_language Verilog [current_project]

# Top-level & accelerator RTL
add_files [glob -nocomplain ${RTL_DIR}/*.v]

# CPU core RTL
add_files [glob -nocomplain ${RTL_DIR}/cpu/*.v]

# ---- constraints ----
add_files -fileset constrs_1 [glob -nocomplain ${CONSTRS_DIR}/*.xdc]

# ---- set top module ----
set_property top ${TOP_MODULE} [current_fileset]

puts "======================================================================"
puts "  Project created. You can now open it and run synthesis manually."
puts "  Project: ${PROJECT_DIR}/${PROJECT_NAME}.xpr"
puts "======================================================================"

exit
