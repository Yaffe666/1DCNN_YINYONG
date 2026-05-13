# CNN Accelerator — 工作交接文档

## 项目概览

1D-CNN 加速器 SoC (RISC-V RV32I + CNN)，目标 FPGA: **xcku040-ffva1156-2-i**，输入长度 2048 样本，10 分类输出。

## 已完成的工作

### 1. 流式写回优化（TB PASS, cycle_cnt=71,362）

三个引擎的写回流水线化，去除等待 requant 的空泡周期：
- `rtl/initial_conv_engine.v` — WB_PIPE=6
- `rtl/depthwise_conv_engine.v` — WB_PIPE=6
- `rtl/pointwise_conv_engine.v` — WB_PIPE=6

原理：requant_relu 从 `rq_in_valid` 到 `rq_out_valid` 实际延迟为 6 周期（PIPE_STAGES=4 + 寄存器输出级），WB_PIPE 需匹配此延迟。

### 2. 综合时间优化（10h → 9min）

- `rtl/fake_weight_rom.v` — 单 64 端口 ROM → 64 独立单端口 ROM (generate)
- `rtl/fake_bn_rom.v` — 单 8 端口 ROM → 8 独立单端口 ROM (generate)

原 64 端口内存推断导致 Vivado 做 O(n²) 端口冲突分析，改为独立 BRAM 后直接映射。

### 3. GAP 单元时序优化（进行中，3 轮迭代）

**当前文件状态：** `rtl/gap_unit.v` 已修改为 LUT 查表倒数（最新 V4 版本）

关键路径演变：
| 版本 | 方法 | WNS (100MHz) | 关键路径 |
|------|------|:-----------:|---------|
| 原始 | `sum_reg / length` (32÷16 除法) | -20.082ns | gap_unit S_WRITE |
| V2 | `sum_reg × recip >> 24` (DSP48 乘法) | -12.868ns | gap_unit S_RECIP 倒数除法 |
| V3 | + 倒数流水线化 S_RECIP→S_RECIP2 | -12.973ns | 同样是 S_RECIP 除法 |
| **V4** | **LUT 查表代替倒数除法** | **待仿真+实现** | ? |

V4 策略：CNN 中 GAP 的 length 始终是 2 的幂（输入 2048 ÷ 初始 stride 8 ÷ 5 次 maxpool stride 2 = 8），用 case 映射 12 种 power-of-2 值到预计算倒数，消除除法器。非 2 的幂 fallback 到除法器（罕见路径）。

**⚠️ V4 版本的 gap_unit.v 尚未通过 ModelSim 仿真验证，也未跑 Vivado 实现！**

## 报告文件索引

### 综合报告
- `reports/prev_synth/` — 原始 10 小时综合报告 (100MHz)
- `reports/timing_sweep/100MHz_utilization.rpt` — 综合利用率
- `reports/timing_sweep/150MHz_utilization.rpt`
- `reports/timing_sweep/200MHz_utilization.rpt`

### 实现报告（布局布线后时序）
- `reports/timing_sweep/100MHz_timing.rpt` — **原始**（gap_unit 除法，WNS=-20.082ns）
- `reports/timing_sweep/100MHz_v2_timing.rpt` — **V2**（倒数乘法，WNS=-12.868ns）
- `reports/timing_sweep/100MHz_v3_timing.rpt` — **V3**（倒数流水线化，WNS=-12.973ns）
- `reports/timing_sweep/150MHz_timing.rpt` — 原始 WNS=-22.915ns
- `reports/timing_sweep/200MHz_timing.rpt` — 原始 WNS=-24.778ns

### 实现日志（含 route_design 中间时序）
- `reports/timing_sweep/impl_sweep.log` — 第一次三频率全实现
- `reports/timing_sweep/impl_gap_fix.log` — V2 100MHz
- `reports/timing_sweep/impl_100_v3.log` — V3 100MHz（含新关键路径详情）

## 待办任务

### 优先级 1：验证 gap_unit V4 并跑实现
1. 运行 ModelSim 仿真验证 V4 gap_unit 功能：
```
D:/software/modsim/win64/vsim -c -do "run -all; exit" tb_cnn_accelerator
```
（需先 vlog 编译所有 RTL，参考 `scripts/synth_soc_top.tcl` 中的文件列表）

2. 若 TB PASS，运行 100MHz 实现：
```
D:/2021.2/Vivado/2021.2/bin/vivado -mode batch -source scripts/impl_100_v2.tcl
```
（需修改脚本中的报告前缀为 V4）

3. 若 WNS 仍为负，V4 的 fallback 除法器可能仍是瓶颈。方案：
   - 移除 default 分支的除法器，非 power-of-2 长度直接报 error
   - 或添加 multi-cycle path 约束让 Vivado 放宽该单次触发路径

### 优先级 2：布线拥塞优化
路由报告显示 "256+ CLBs have high pin utilization"，来自 64 weight ROM BRAM 密集互联：
- `rtl/fake_weight_rom.v` — 64 个 BRAM 各存完整权重副本
- 可优化为按 output channel 分区（每 bank 存 1/8 数据），减少 BRAM 深度和布线压力
- 需要修改 `rtl/cnn_accelerator_top.v` 中的 weight 地址路由

### 优先级 3：跑通 150MHz 和 200MHz
修改 `scripts/impl_freq_sweep.tcl`（需更新 gap_unit 状态），跑三频率全实现。

## 关键文件修改清单

| 文件 | 状态 | 说明 |
|------|------|------|
| `rtl/gap_unit.v` | **已改，待验证** | V4 LUT 查表倒数，消除除法器 |
| `rtl/initial_conv_engine.v` | 已验证 | WB_PIPE=6 流式写回 |
| `rtl/depthwise_conv_engine.v` | 已验证 | WB_PIPE=6 流式写回 |
| `rtl/pointwise_conv_engine.v` | 已验证 | WB_PIPE=6 流式写回 |
| `rtl/fake_weight_rom.v` | 已验证 | 64 独立单端口 ROM |
| `rtl/fake_bn_rom.v` | 已验证 | 8 独立单端口 ROM |
| `rtl/xpm_memory_sdpram_sim.sv` | 已验证 | ModelSim XPM 存根 |

## 工具路径

- ModelSim: `D:/software/modsim/win64/` (vsim, vlog)
- Vivado 2021.2: `D:/2021.2/Vivado/2021.2/bin/` (vivado)
- 仿真 TB: `tb/tb_cnn_accelerator.sv` (Stage 1，CNN standalone)
- 约束: `constraints/soc_top.xdc` (时钟 100MHz = 10ns)

## 编译命令参考

ModelSim 编译（所有 RTL + TB）：
```
vlog -sv -work work \
  rtl/xpm_memory_sdpram_sim.sv \
  rtl/requant_relu.v rtl/saturate_int8.v rtl/reset_sync.v \
  rtl/feature_buffer.v rtl/fake_weight_rom.v rtl/fake_bn_rom.v \
  rtl/input_buffer.v rtl/initial_conv_engine.v rtl/depthwise_conv_engine.v \
  rtl/pointwise_conv_engine.v rtl/maxpool_unit.v rtl/gap_unit.v \
  rtl/final_conv_engine.v rtl/axi_lite_addr_decode.v rtl/axi_lite_slave_regs.v \
  rtl/cnn_accelerator_top.v tb/tb_cnn_accelerator.sv
```

Vivado 批处理实现：
```
vivado -mode batch -source scripts/impl_100_v2.tcl -notrace -nojournal -log reports/timing_sweep/impl_100_v4.log
```

## 当前分支与远端

- Branch: `main`
- Remote: `git@github.com:Yaffe666/1DCNN_YINYONG.git`
- 最新 commit: `ab6b8a6` (Update .gitignore)
- ⚠️ gap_unit.v V4 未提交
