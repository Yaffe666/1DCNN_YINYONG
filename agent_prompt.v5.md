# 1D-CNN SoC RTL 生成提示词 v5（低延迟 FPGA 架构规格）

你是一个资深 FPGA 设计工程师、RTL 架构师和计算机体系结构专家。请根据本规格生成 **Verilog-2001 可综合 RTL** 和 **SystemVerilog testbench**。目标是：先让 CNN accelerator standalone 可综合、可仿真，再逐步集成 SoC shell、RISC-V CPU，最终形成可上板的完整 SoC。

本文件在 v4 基础上进一步明确低延迟 FPGA 落地要求：

- 真实 1D-CNN layer schedule 和默认/最大输入长度；
- `<1 ms` 延迟统计口径、cycle budget 和频率目标；
- 受控高并行计算架构与 BRAM/DSP-friendly 流水；
- feature/weight/BN/zero-point 的物理 banking 布局；
- Python fake model/golden 数据生成；
- 每个阶段的仿真、综合、资源和时序验证方法。

## 0. 已确认设计选择

```text
target_fpga              = xcku040-ffva1156-2-i
bringup_clock_target     = 100 MHz first target
optimized_clock_target   = 150 MHz expected, 200 MHz stretch if timing closure permits
latency_target           = < 1 ms for B/C/D phases: CNN compute + output logits + CPU/AXI-Lite config; AXI-Stream input loading is excluded
rtl_language             = Verilog-2001
tb_language              = SystemVerilog
first_goal               = Vivado synthesizable
final_goal               = board-ready
cnn_parallel_style       = controlled high parallelism with BRAM/DSP-friendly pipelining
input_data_type          = signed int8
weight_data_type         = signed int8
feature_data_type        = signed int8
output_logits            = signed int8
s_axis_tdata             = 8-bit, one sample per beat
m_axis_tdata             = 8-bit, one logit per beat
default_input_len        = 2048
max_input_len            = 16384
default_classes          = 10
max_classes              = 16
interrupt                = disabled in v5
cpu_control              = polling STATUS.done
weights                  = ROM-fixed deterministic weights first; real weights exported later, no runtime weight loading
bn_requant               = offline folded into scale/bias/zero-point parameters
mac_resource_sharing     = disabled in v5; engines use independent MAC datapaths
resource_priority        = performance first; xcku040 resources are considered sufficient for BRAM banking/DSP use
stage2_axi_lite          = exposed at soc_top for testbench/external master
firmware                 = RV32I assembly or direct ROM hex
cpu_axi_master           = AXI4-Lite single-outstanding transaction master
```

---

# Part A. 全局接口与编码规则

## A1. 全局时钟复位

所有 RTL 模块使用同一个 `clk`。

外部复位：

```verilog
input wire rst_n_async
```

内部复位：

```verilog
wire rst_n
```

`rst_n_async` 必须经过 `reset_sync.v` 同步释放。除 `reset_sync.v` 外，其他模块内部统一使用同步释放后的 `rst_n`。

## A2. RTL 编码规则

所有 `.v` 文件必须：

```verilog
`timescale 1ns / 1ps
`default_nettype none
...
`default_nettype wire
```

规则：

- Verilog-2001，不使用 SystemVerilog RTL 语法。
- 时序逻辑用 `<=`。
- 组合逻辑用 `=`。
- `case` 必须有 `default`。
- FSM 使用二进制编码 `localparam` + `case(state)`。
- 禁止 one-hot attribute + `case(1'b1)`。
- 所有 `wire/reg` 声明必须在模块实例化之前。
- 不允许隐式 wire。
- RTL 中不使用 `$random`。
- RTL 中不使用 `#delay`。
- `$display` 只能在 `` `ifndef SYNTHESIS `` 内使用。

## A3. 面向低延迟的受控高并行 CNN 风格

CNN accelerator 采用**受控高并行**，目标是在实际 BRAM/DSP/布线可收敛的前提下，把单次完整推理延迟压到 1 ms 以内。优化指标是：

```text
inference_latency = cycle_count / fclk
```

不能只追求更少 cycle，也不能只追求更高 MHz。提高并行度必须同时提供可实现的 feature/weight/buffer 带宽。

推荐第一版低延迟并行度：

```text
initial_conv_engine:   8 个输出通道并行，kernel tap 串行或分组流水
DepthwiseConv:         8 个 channel 并行，kernel tap 用窗口寄存器/流水处理
PointwiseConv:         8 个输出通道并行，4 个输入通道并行累加
MaxPool:               8 个 channel 并行
GAP:                   8 个 channel 并行
FinalConv:             8 个 class 并行，4 个输入通道并行累加
```

默认参数：

```verilog
parameter PAR_CH = 8;
parameter PAR_OC = 8;
parameter PAR_IC = 4;
parameter PAR_CLASS = 8;
```

如果资源或 timing 不足，优先降低 `PAR_IC`，再降低 `PAR_OC/PAR_CH`。如果资源和 timing 余量充足，可以探索 `PAR_CH=16` 或 `PAR_CLASS=16`，但必须同步更新 BRAM banking 和 weight bandwidth。

## A4. 固定网络结构与 layer schedule

当前真实模型默认输入长度为 2048，硬件必须支持 `INPUT_LEN` 最大 16384。下表给出默认 2048 输入时的固定 layer schedule；当 `INPUT_LEN` 变化时，各层 length 必须按同一卷积/池化公式动态计算，最大长度不得超过 buffer 设计能力。模型包含 InitialConv、5 个 DSC block、AdaptiveAvgPool1d 和最终 1x1 Conv 分类层。除非用户后续明确修改，RTL 主 FSM、权重地址、buffer 调度和 cycle budget 必须按该结构实现。

```text
Layer/Block              Op                  in_ch  out_ch  in_len  out_len  kernel  stride  padding  ReLU  Pool
initial_conv             Conv1d                  1      12    2048      256      64       8       28    yes   no
DSC0 depthwise           DW Conv1d              12      12     256      256       7       1        3    yes   no
DSC0 pointwise           PW Conv1d              12      24     256      256       1       1        0    yes   no
DSC0 maxpool             MaxPool1d              24      24     256      128       2       2        0     no   yes
DSC1 depthwise           DW Conv1d              24      24     128      128       7       1        3    yes   no
DSC1 pointwise           PW Conv1d              24      48     128      128       1       1        0    yes   no
DSC1 maxpool             MaxPool1d              48      48     128       64       2       2        0     no   yes
DSC2 depthwise           DW Conv1d              48      48      64       64       7       1        3    yes   no
DSC2 pointwise           PW Conv1d              48      60      64       64       1       1        0    yes   no
DSC2 maxpool             MaxPool1d              60      60      64       32       2       2        0     no   yes
DSC3 depthwise           DW Conv1d              60      60      32       32       7       1        3    yes   no
DSC3 pointwise           PW Conv1d              60      72      32       32       1       1        0    yes   no
DSC3 maxpool             MaxPool1d              72      72      32       16       2       2        0     no   yes
DSC4 depthwise           DW Conv1d              72      72      16       16       7       1        3    yes   no
DSC4 pointwise           PW Conv1d              72      72      16       16       1       1        0    yes   no
DSC4 maxpool             MaxPool1d              72      72      16        8       2       2        0     no   yes
GAP                      AdaptiveAvgPool1d      72      72       8        1       -       -        -     no   yes
FinalConv                Conv1d                 72      10       1        1       1       1        0     no   no
```

DSC block 汇总：

```text
block_idx | in_ch | dw_out_ch | pw_out_ch | in_len | after_dw_len | after_pw_len | after_pool_len
0         | 12    | 12        | 24        | 256    | 256          | 256          | 128
1         | 24    | 24        | 48        | 128    | 128          | 128          | 64
2         | 48    | 48        | 60        | 64     | 64           | 64           | 32
3         | 60    | 60        | 72        | 32     | 32           | 32           | 16
4         | 72    | 72        | 72        | 16     | 16           | 16           | 8
```

主 FSM 必须使用该 schedule 更新 `current_block/current_in_ch/current_out_ch/current_len`。`LAYER_CFG` 可以限制实际执行的 DSC block 数量，但默认必须执行 5 个 block。

## A5. 数值规则

数据类型：

```text
input sample    = signed int8
weight          = signed int8
feature/act     = signed int8
output logits   = signed int8
accumulator     = signed int32
```

量化模型允许 zero point。默认第一版可以先使用 zero point = 0 进行 bring-up；真实权重接入时必须支持从参数 ROM 读取 zero point。

卷积累加规则：

```text
input_centered  = input_int8  - input_zero_point
weight_centered = weight_int8 - weight_zero_point
acc = sum(input_centered * weight_centered)  // signed int32
```

统一 requant：

```text
scaled  = (acc * scale) >>> 8  // arithmetic right shift, truncation (no rounding; bring-up only)
biased  = scaled + bias
shifted = biased + output_zero_point
clipped = saturate_int8(shifted)
```

其中：

```text
scale             = signed int16 Q8.8 unless real quant export says otherwise
bias              = signed int32
input_zero_point  = signed int8, default 0
weight_zero_point = signed int8, default 0
output_zero_point = signed int8, default 0
```

zero point 粒度：

```text
真实模型 zero-point 粒度暂未最终确认。
bring-up 版本默认按每层一组 zero point 处理：input/output/weight zero point 均为 layer-level。
ROM 地址和接口命名必须预留 per-output-channel 扩展空间，不允许把 zero point 常量写死在 compute engine 内部。
如果后续真实量化导出为 per-output-channel、per-tensor 或 per-layer，需要只更新参数 ROM 内容/地址布局，尽量不重写 compute datapath。
```

除 FinalConv 外，卷积后接 ReLU：

```text
relu_out = clipped < 0 ? 0 : clipped
```

FinalConv 不接 ReLU，直接输出 signed int8 logits。

## A6. 输入/输出协议

输入 AXI-Stream：

```verilog
input  wire        s_axis_tvalid,
output wire        s_axis_tready,
input  wire [7:0]  s_axis_tdata,
input  wire        s_axis_tlast
```

规则：

- 每个 beat 是 1 个 signed int8 sample。
- `INPUT_LEN=2048` 时输入 2048 个有效 beat。
- `s_axis_tlast` 必须与最后一个数据 beat 同拍有效（`tvalid=1, tlast=1, tdata=last_sample`），标准 AXI-Stream 惯例。
- `s_axis_tlast` 提前或延后，置 `STATUS.error=1`。

输出 AXI-Stream：

```verilog
output wire        m_axis_tvalid,
input  wire        m_axis_tready,
output wire [7:0]  m_axis_tdata,
output wire        m_axis_tlast
```

规则：

- 每个 beat 是 1 个 signed int8 logit。
- 共输出 `NUM_CLASSES` 个 beat。
- 最后一个 beat 上 `m_axis_tlast=1`。
- `m_axis_tready=0` 时必须保持 `tvalid/tdata/tlast` 不变。

延迟统计口径：

```text
B phase: CNN compute after input samples are already accepted/stored
C phase: AXI-Stream output of logits
D phase: CPU/AXI4-Lite register configuration and polling overhead
```

`latency_target < 1 ms` 默认覆盖 B+C+D，不覆盖 A phase 的 AXI-Stream 输入加载时间。`cycle_cnt` 应主要统计 CNN compute/output 相关周期；SoC 级 testbench 可额外统计 CPU config/polling 周期。

`cycle_cnt` 暂停规则：当 `m_axis_tready=0` 导致输出背压阻塞时，`cycle_cnt` 必须暂停递增，保证 B+C 阶段延迟测量对外部下游 ready 行为不敏感、可复现。`s_axis_tvalid=0` 的输入间隙期内（A 阶段），`cycle_cnt` 不计入（尚未开始 B/C 阶段），因此也不涉及暂停问题。

## A7. AXI4-Lite 寄存器映射

CNN accelerator AXI4-Lite base address：`0x1000_0000`。

| Offset | Name | R/W | Bits |
|--------|------|-----|------|
| 0x00 | CTRL | W/R | [0] start pulse, [1] soft_reset pulse |
| 0x04 | STATUS | R | [0] busy, [1] done, [2] error |
| 0x08 | INPUT_LEN | R/W | 1~16384 |
| 0x0C | LAYER_CFG | R/W | [3:0] num_dsc_blocks, 1~5 |
| 0x10 | NUM_CLASSES | R/W | 1~16, default 10 |
| 0x14 | CLEAR | W | [0] clear done/error |
| 0x18 | CYCLE_CNT | R | inference cycle counter |
| 0x1C | VERSION | R | 32'h0000_0400 |

`CTRL.start` 和 `CTRL.soft_reset` 都是 write-one-pulse，不是保持型 bit。

`soft_reset` 行为：
- 立即将主 FSM 强制回 `S_IDLE`，各 engine 的 `busy/done/error` 清零。
- `STATUS.busy/done/error` 清零。
- `CYCLE_CNT` 清零。
- 流水线模块（`requant_relu` 等）内部 flush，丢弃未完成的数据。
- `input_buffer`/`feature_buffer`/`logit buffer` 内容不清零（下次推理自然覆盖）。
- soft_reset 脉冲宽度至少 1 拍；主 FSM 在 soft_reset 后回到 IDLE 等待下次 start。

## A8. FPGA 资源映射、BRAM banking 与高频流水规则

本设计必须面向真实 FPGA 落地，不能生成理论多端口 RAM 或过宽 memory。所有大容量存储必须优先映射到 Xilinx hard BRAM/Block RAM；小容量、低带宽、短深度结构才允许使用 LUTRAM/SRL/寄存器。

资源划分原则：

```text
input_buffer:      Block RAM，同步读，一拍延迟
feature_buffer:    Block RAM，ping-pong + banking，禁止单体多读端口 RAM
weight_rom:        Block RAM 优先，按并行度 banking 或适度复制
bn/requant ROM:    小表可 LUTROM，大表用 Block RAM
GAP vector:        LUTRAM 或寄存器
logit buffer:      寄存器或 LUTRAM
短 FIFO/skid:      LUTRAM/SRL
CPU inst_rom:      Block RAM
CPU data_ram:      Block RAM 或 LUTRAM，取决于深度
```

BRAM 端口限制必须显式处理：

```text
Xilinx BRAM 只有两个物理端口。
禁止从同一个 RAM array 同周期读出 4/8/16 个独立地址。
禁止用一个超宽 RAM word 盲目承载所有 lane。
高并行读写必须通过 banking、replication、ping-pong 或数据复用解决。
```

feature buffer 默认采用 channel banking：

```text
BANKS = PAR_CH
bank_id   = channel % BANKS
bank_addr = (channel / BANKS) * MAX_FEATURE_LEN + position
```

每个 bank 使用窄宽度 BRAM，推荐 8-bit 或 16-bit 数据宽度。不要为了方便写成 128/256-bit 超宽 RAM；如果需要更高带宽，优先增加 bank 数，而不是无限加宽单个 memory。

若 Vivado 2021.2 无法从纯 RTL template 推断出 `input_buffer`/`feature_buffer` 所需的 Block RAM banking，允许并优先使用 Xilinx XPM memory macro 强制映射到 hard BRAM。最终可交付实现不得把大容量 feature storage 留在 LUTRAM/Distributed RAM 中。

高频设计规则：

```text
BRAM read address 与 BRAM read data 必须分拍处理。
BRAM read data 必须寄存后再进入 DSP/MAC 阵列。
DSP multiply、adder tree、accumulator、requant 必须流水化。
大 fanout 控制信号需要局部寄存。
禁止为了减少 cycle 写长组合路径。
```

推荐优化目标：

```text
first target:   100 MHz
optimized:      150 MHz expected
stretch:        200 MHz if timing/resource reports allow
latency target: <1 ms for B+C+D phases = cycles / fclk
```

资源策略：

```text
performance first for v5 optimized implementation
xcku040-ffva1156-2-i resources are considered sufficient for BRAM banking and DSP use
engines execute sequentially but do not share MAC datapaths in v5
use independent MAC datapaths per engine to reduce control complexity and schedule risk
```

## A9. Cycle/Latency Budget

默认 `INPUT_LEN=2048` 时，低延迟目标按 B+C+D 阶段统计：CNN compute、logits output、CPU/AXI-Lite config/polling。A 阶段 AXI-Stream 输入加载不计入 `<1 ms` 指标。

周期估算公式：

```text
InitialConv cycles ~= ceil(12 / PAR_OC) * init_out_len * 64
Depthwise cycles   ~= ceil(ch / PAR_CH) * len * 7
Pointwise cycles   ~= ceil(out_ch / PAR_OC) * len * ceil(in_ch / PAR_IC)
MaxPool cycles     ~= ceil(ch / PAR_CH) * out_len * 2
GAP cycles         ~= ceil(ch / PAR_CH) * len
FinalConv cycles   ~= ceil(num_classes / PAR_CLASS) * ceil(ch / PAR_IC)
Output cycles      ~= num_classes
```

默认并行度：

```text
PAR_CH    = 8
PAR_OC    = 8
PAR_IC    = 4
PAR_CLASS = 8
```

`INPUT_LEN=2048` 粗略预算：

```text
InitialConv       ~= 32,768 cycles
Depthwise total   ~= 11,760 cycles
Pointwise total   ~= 19,968 cycles
MaxPool total     ~=  2,480 cycles
GAP               ~=     72 cycles
FinalConv         ~=     36 cycles
Output logits     ~=     10 cycles
------------------------------------------------
raw compute total ~= 67,094 cycles
```

实现允许有 BRAM latency、requant pipeline、engine start/done、AXI polling、FSM 调度等 overhead。Stage 1 先用 `cycle_cnt` 检查 accelerator-only 的 B+C；Stage 4 还必须额外统计 CPU config/polling 的 D phase，并报告最终 B+C+D。默认 2048 case 的目标：

```text
100 MHz: target total B+C+D < 100,000 cycles
150 MHz: target total B+C+D < 150,000 cycles
200 MHz: target total B+C+D < 200,000 cycles
```

`INPUT_LEN=16384` 必须功能支持，粗略预算约为默认 case 的 8 倍：

```text
InitialConv       ~= 262,144 cycles
Depthwise total   ~=  94,080 cycles
Pointwise total   ~= 159,744 cycles
MaxPool total     ~=  19,840 cycles
GAP               ~=     576 cycles
FinalConv         ~=      36 cycles
Output logits     ~=      10 cycles
------------------------------------------------
raw compute total ~= 536,430 cycles
```

除非用户后续明确要求，`INPUT_LEN=16384` case 只强制功能正确和协议正确，不强制 `<1 ms`。

如果默认 2048 case 综合/仿真后无法满足 `<1 ms`，优化优先级：

```text
1. 提高 Fmax 到 150 MHz
2. InitialConv 增加 PAR_K=2 或 PAR_K=4
3. PointwiseConv 将 PAR_IC 从 4 提升到 8
4. 重新评估 weight banking 和 DSP pipeline
5. 最后再考虑更激进的 PAR_OC/PAR_CH=16
```

## A10. Weight/BN/Zero-point Physical Banking Layout

feature buffer 已按 channel banking 实现。weight/BN/zero-point 参数也必须有物理 banking 方案，禁止从一个 ROM array 同拍读取多个独立地址。

权重逻辑顺序：

```text
InitialConv: initial_weight[oc][k]
Depthwise:   dw_weight[block][channel][k]
Pointwise:   pw_weight[block][out_channel][in_channel]
FinalConv:   fc_weight[class][in_channel]
```

InitialConv weight banking：

```text
parallel demand: PAR_OC weights per tap
bank_id   = oc % PAR_OC
bank_addr = initial_base + (oc / PAR_OC) * 64 + k
```

Depthwise weight banking：

```text
parallel demand: PAR_CH weights per tap
bank_id   = channel % PAR_CH
bank_addr = dw_base[block] + (channel / PAR_CH) * 7 + k
```

Pointwise weight banking：

```text
parallel demand: PAR_OC * PAR_IC weights per cycle
bank_oc = oc % PAR_OC
bank_ic = ic % PAR_IC
bank_id = bank_oc * PAR_IC + bank_ic
bank_addr = pw_base[block]
          + (oc / PAR_OC) * ceil(in_ch / PAR_IC)
          + (ic / PAR_IC)
```

FinalConv weight banking：

```text
parallel demand: PAR_CLASS * PAR_IC weights per cycle
bank_class = class % PAR_CLASS
bank_ic    = ch % PAR_IC
bank_id    = bank_class * PAR_IC + bank_ic
bank_addr  = fc_base + (class / PAR_CLASS) * ceil(channels / PAR_IC) + (ch / PAR_IC)
```

BN/requant/zero-point 参数布局：

```text
scale/bias/output_zero_point are indexed by output channel or class.
input_zero_point and weight_zero_point default to layer-level for bring-up.
ROM/interface layout must reserve per-output-channel extension.
```

参数 ROM 端口要求：

```text
InitialConv: PORTS >= PAR_OC
Depthwise:   PORTS >= PAR_CH
Pointwise:   PORTS >= PAR_OC for requant params; weight ROM needs PAR_OC*PAR_IC banks/ports
FinalConv:   PORTS >= PAR_CLASS for requant params; weight ROM needs PAR_CLASS*PAR_IC banks/ports
```

实现注意：

```text
Weights 总容量较小，允许 synthesis 在小 bank 上使用 LUTROM；但 feature/input buffer 必须使用 BRAM。
若纯 RTL 推断无法满足 `feature_buffer` BRAM banking，优先改用 XPM memory macro，而不是接受 LUTRAM 映射。
若强制 BRAM 导致大量碎片浪费，可采用 packed ROM + registered unpacking，但不能形成过宽 critical path。
所有 ROM 输出必须寄存后进入 MAC/DSP pipeline。
```

## A11. Verification Strategy

验证必须分三层：Python golden、RTL simulation、Vivado synthesis/timing/resource report。

Python golden：

```text
scripts/gen_fake_model_data.py must generate fake_input_2048.mem, fake_weights.mem,
fake_bn_params.mem, golden_logits.mem, and optional per-layer dumps.
The Python model must use integer arithmetic matching A5 quantization rules.
```

RTL simulation minimum checks：

```text
1. AXI4-Lite register reset/default/read/write behavior
2. INPUT_LEN=2048, LAYER_CFG=5, NUM_CLASSES=10 normal inference
3. final logits match golden_logits.mem
4. m_axis_tlast appears exactly on final logit
5. STATUS.done=1 and STATUS.error=0 after success
6. CLEAR clears done/error
7. repeated inference works
8. input valid gaps and output ready backpressure
9. tlast early/late error handling
10. INPUT_LEN=0 and LAYER_CFG=0 error handling
11. INPUT_LEN=16384 functional/protocol smoke test
```

Recommended debug checks：

```text
optional per-layer feature dump compare
bank conflict assertion or scheduling assertion
cycle_cnt nonzero and within expected budget
requant pipeline latency alignment assertion
BRAM read latency alignment assertion
```

Vivado synthesis checks after memory-heavy batches：

```text
input_buffer inferred as Block RAM
feature_buffer inferred as banked Block RAM, not giant LUTRAM
if inferred RTL maps feature_buffer/input_buffer to LUTRAM, replace with XPM BRAM or revise template before final closure
ROM banking/replication is explicit and does not infer illegal multi-port RAM
no unintended latch inference
no asynchronous large RAM read
resource report records BRAM/LUTRAM/DSP/LUT/FF usage and top memory primitives
```

Vivado implementation/timing checks after compute-heavy batches：

```text
100 MHz must close first
150 MHz should be attempted after functional closure
200 MHz is stretch target after pipelining cleanup
DSP inference report must be reviewed for MAC and requant paths
worst negative slack and top failing paths must be recorded before changing parallelism
Stage 1 and Stage 4 timing/resource summaries must both be kept for comparison
```

Regression matrix：

```text
After CNN RTL changes: run tb_cnn_accelerator.sv and relevant synthesis checks
After Stage 2 shell changes: run tb_soc_shell.sv against soc_shell_top
After CPU/hazard/firmware changes: run tb_riscv_core.sv with delayed AXI responses
After full SoC/top/decoder changes: run tb_soc.sv and report B+C+D cycles
Before final closure: rerun Stage 1, Stage 3, Stage 4 simulations plus Vivado resource/timing reports
```

---

# Part B. Stage 1：CNN accelerator standalone 详细规格

Stage 1 目标：不实现 CPU，只实现 CNN accelerator + AXI4-Lite slave + AXI-Stream input/output。testbench 使用 AXI4-Lite BFM 配置寄存器。

## B1. Stage 1 文件清单

必须生成：

```text
rtl/reset_sync.v
rtl/saturate_int8.v
rtl/requant_relu.v
rtl/fake_weight_rom.v
rtl/fake_bn_rom.v
rtl/axi_lite_slave_regs.v
rtl/input_buffer.v
rtl/feature_buffer.v
rtl/initial_conv_engine.v
rtl/depthwise_conv_engine.v
rtl/pointwise_conv_engine.v
rtl/maxpool_unit.v
rtl/gap_unit.v
rtl/final_conv_engine.v
rtl/cnn_accelerator_top.v
tb/tb_cnn_accelerator.sv
scripts/gen_fake_model_data.py
mem/fake_weights.mem
mem/fake_bn_params.mem
mem/fake_input_2048.mem
mem/golden_logits.mem
```

## B2. `reset_sync.v`

职责：

- 将异步低有效复位 `rst_n_async` 同步释放到 `clk` 域。
- 只做复位同步，不做其他逻辑。

接口：

```verilog
module reset_sync (
    input  wire clk,
    input  wire rst_n_async,
    output wire rst_n
);
```

实现要求：

- 使用 2 级触发器。
- 触发器加 `(* ASYNC_REG = "TRUE" *)`。
- 异步拉低，同步释放。

## B3. `saturate_int8.v`

职责：

- 将 signed int32 裁剪为 signed int8。
- 纯组合逻辑。

接口：

```verilog
module saturate_int8 (
    input  wire signed [31:0] in_data,
    output reg  signed [7:0]  out_data
);
```

规则：

```text
in_data > 127  -> 127
in_data < -128 -> -128
else           -> in_data[7:0]
```

不负责：

- 不做 ReLU。
- 不做 scale/bias。

## B4. `requant_relu.v`

职责：

- 对 int32 accumulator 执行 scale、bias、saturate。
- 可选执行 ReLU。
- 必须采用 DSP-friendly 流水，不允许把 multiply、shift、bias、saturate、ReLU 全放在一拍长组合路径中。

推荐采用 3~4 级流水，便于 200 MHz 级别 timing closure。

接口：

```verilog
module requant_relu (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              in_valid,
    input  wire signed [31:0] acc_in,
    input  wire signed [15:0] scale_q8_8,
    input  wire signed [31:0] bias,
    input  wire signed [7:0]  output_zero_point,
    input  wire              relu_en,
    output reg               out_valid,
    output reg  signed [7:0]  out_data
);
```

时序：

- `in_valid=1` 时采样输入。
- 固定 `PIPE_STAGES` 拍后输出 `out_valid=1`。
- `out_data` 为处理后的 int8。
- `PIPE_STAGES` 必须由参数或 localparam 明确，testbench 按该延迟检查。

不负责：

- 不访问 ROM。
- 不管理卷积 FSM。

## B5. `fake_weight_rom.v`

职责：

- 提供 deterministic fake int8 权重。
- ROM 结构必须从第一版开始保持 `$readmemh` 兼容，便于未来替换真实权重。
- 第一版可以用 mem 文件初始化假权重；若使用地址函数生成固定 pattern，只能作为 bring-up 版本。
- 面向高并行 engine 时，weight ROM 必须按并行访问需求 banking、packing 或复制，不能假设单 ROM 同拍提供多个独立地址。

接口：

```verilog
module fake_weight_rom #(
    parameter ADDR_WIDTH = 16,
    parameter PORTS = 1
) (
    input  wire                          clk,
    input  wire [PORTS*ADDR_WIDTH-1:0]   addr_flat,
    output reg  [PORTS*8-1:0]            data_flat
);
```

时序与资源：

- 同步 ROM。
- `addr_flat` 输入后一拍 `data_flat` 有效。
- 默认推断 Block RAM 或 ROM-on-BRAM。
- `PORTS>1` 时必须通过多个 BRAM bank/ROM replica 实现，不允许从同一个 memory array 构造伪多读端口。
- 并行读取多个 weight 时，优先使用 output-channel banking；小型权重表允许复制 ROM。

权重 pattern：

```text
addr % 5 == 0 -> -2
addr % 5 == 1 -> -1
addr % 5 == 2 ->  0
addr % 5 == 3 ->  1
addr % 5 == 4 ->  2
```

逻辑地址布局：

```text
InitialConv: initial_weight[oc][k]
Depthwise:   dw_weight[layer][channel][k]
Pointwise:   pw_weight[layer][out_channel][in_channel]
FinalConv:   fc_weight[class][in_channel]
```

本 ROM 不负责解释层语义，只根据线性地址返回权重。

## B6. `fake_bn_rom.v`

职责：

- 提供 deterministic scale/bias/zero-point 参数。
- 第一版所有 scale=256，bias=0，input/weight/output zero point=0。

接口：

```verilog
module fake_bn_rom #(
    parameter ADDR_WIDTH = 12,
    parameter PORTS = 1
) (
    input  wire                        clk,
    input  wire [PORTS*ADDR_WIDTH-1:0] addr_flat,
    output reg  [PORTS*16-1:0]         scale_q8_8_flat,
    output reg  [PORTS*32-1:0]         bias_flat,
    output reg  [PORTS*8-1:0]          input_zp_flat,
    output reg  [PORTS*8-1:0]          weight_zp_flat,
    output reg  [PORTS*8-1:0]          output_zp_flat
);
```

时序与资源：

- 同步 ROM。
- 输入地址后一拍参数有效。
- `PORTS>1` 时必须通过 banking 或复制实现。
- 参数表较小时允许 LUTROM；参数表变大或需要多路读取时，应使用 BRAM banking 或复制。

不负责：

- 不做 BN 计算。
- 不做 ReLU。

## B7. `axi_lite_slave_regs.v`

职责：

- 实现 CNN accelerator 的 AXI4-Lite slave 寄存器。
- 提供内部控制信号给 `cnn_accelerator_top`。
- 接收 accelerator 状态更新。

接口：

```verilog
module axi_lite_slave_regs (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,
    output reg  [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,

    input  wire [31:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output reg  [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    output reg         start_pulse,
    output reg         soft_reset_pulse,
    output reg         clear_pulse,
    output reg  [15:0] cfg_input_len,
    output reg  [3:0]  cfg_num_blocks,
    output reg  [4:0]  cfg_num_classes,

    input  wire        status_busy,
    input  wire        status_done,
    input  wire        status_error,
    input  wire [31:0] cycle_cnt
);
```

AXI 行为：

- 支持单 outstanding transaction。
- 写地址和写数据可以同拍到达，也可以不同拍到达。
- 写响应 `BRESP=OKAY`。
- 读响应 `RRESP=OKAY`。
- 未定义地址返回 `SLVERR` 或读 0，推荐 `SLVERR`。
- `WSTRB` 至少支持 full word `4'b1111`；若部分写，实现 byte enable。

内部默认值：

```text
cfg_input_len   = 2048
cfg_num_blocks  = 5
cfg_num_classes = 10
```

不负责：

- 不执行 CNN 计算。
- 不直接控制 AXI-Stream。

## B8. `input_buffer.v`

职责：

- 存储原始输入样本。
- 写端由 `cnn_accelerator_top` 的输入接收 FSM 控制。
- 读端由 `initial_conv_engine` 使用。

接口：

```verilog
module input_buffer #(
    parameter ADDR_WIDTH = 14,
    parameter DEPTH = 16384
) (
    input  wire              clk,

    input  wire              wr_en,
    input  wire [ADDR_WIDTH-1:0] wr_addr,
    input  wire signed [7:0] wr_data,

    input  wire              rd_en,
    input  wire [ADDR_WIDTH-1:0] rd_addr,
    output reg  signed [7:0] rd_data
);
```

时序与资源：

- 单写单读同步 RAM。
- 读地址后一拍 `rd_data` 有效。
- 必须推断为 Block RAM，不允许异步读。
- 推荐在存储数组上使用 `(* ram_style = "block" *)`。

不负责：

- 不处理 AXI-Stream valid/ready。
- 不检查 `tlast`。

## B9. `feature_buffer.v`

职责：

- 实现两个 ping-pong feature buffer。
- 存储中间 int8 feature map。
- 提供多路并行读写支持，默认支持 8 通道并行算子。
- 必须使用 BRAM banking 解决多 lane 带宽，禁止生成理论多端口 RAM。

推荐接口采用 8-lane 读写：

```verilog
module feature_buffer #(
    parameter ADDR_WIDTH = 18,
    parameter LANES = 8,
    parameter BANKS = 8,
    parameter MAX_FEATURE_LEN = 2048,
    parameter MAX_CHANNELS = 72
) (
    input  wire clk,

    input  wire [LANES-1:0] wr_en,
    input  wire             wr_buf_sel,
    input  wire [LANES*ADDR_WIDTH-1:0] wr_addr_flat,
    input  wire [LANES*8-1:0]          wr_data_flat,

    input  wire [LANES-1:0] rd_en,
    input  wire             rd_buf_sel,
    input  wire [LANES*ADDR_WIDTH-1:0] rd_addr_flat,
    output reg  [LANES*8-1:0]          rd_data_flat
);
```

逻辑地址仍使用：

```text
logical_addr = channel * MAX_FEATURE_LEN + position
MAX_FEATURE_LEN = 2048
MAX_CHANNELS    = 72
```

物理 BRAM banking 必须使用：

```text
bank_id   = channel % BANKS
bank_addr = (channel / BANKS) * MAX_FEATURE_LEN + position
```

buffer 选择：

```text
buf_sel = 0 -> buffer A
buf_sel = 1 -> buffer B
```

资源与时序：

- 每个 ping-pong buffer 包含 `BANKS` 个独立 BRAM bank。
- 每个 bank 推荐 8-bit 或 16-bit 窄宽度，不要使用单个 128/256-bit 超宽 RAM 承载全部 lane。
- 同步读，一拍延迟；BRAM 输出必须寄存。
- 同步写。
- 4/8/16 lane 并行访问必须映射到不同 bank 或通过调度分拍完成。

限制：

- 同一拍同一 buffer 同一 bank 同一地址同时读写时，行为不依赖 read-during-write，顶层 FSM 必须避免冲突。
- 各 compute engine 的地址生成 FSM 负责保证同拍不会有两个 lane 访问同一 bank 的不同地址。`feature_buffer` 自身不做 bank conflict 仲裁/分拍，只提供纯 banking 存储。若 engine 不可避免需要同 bank 多地址访问，由 engine 内部 FSM 分拍调度解决。
- 禁止从同一个 Verilog memory array 同周期读取多个独立地址。

## B10. `initial_conv_engine.v`

职责：

- 执行 InitialConv：`1 -> 12`，kernel=64，stride=8，padding=28。
- 从 `input_buffer` 读取原始样本。
- 从 `fake_weight_rom` 读取 initial weights。
- 从 `fake_bn_rom` 读取 scale/bias/zero-point 参数。
- 将输出 feature 写入 `feature_buffer`。
- 默认采用 8 个 output channel 并行。
- weight/BN 参数必须能每拍提供 `PAR_OC` 路，推荐按 output channel banking。

接口：

```verilog
module initial_conv_engine #(
    parameter PAR_OC = 8
) (
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    output reg  busy,
    output reg  done,
    output reg  error,

    input  wire [15:0] input_len,
    output reg  [15:0] output_len,

    output reg         input_rd_en,
    output reg  [13:0] input_rd_addr,
    input  wire signed [7:0] input_rd_data,

    output reg  [PAR_OC*16-1:0] weight_addr_flat,
    input  wire [PAR_OC*8-1:0]  weight_data_flat,
    output reg  [PAR_OC*12-1:0] bn_addr_flat,
    input  wire [PAR_OC*16-1:0] bn_scale_q8_8_flat,
    input  wire [PAR_OC*32-1:0] bn_bias_flat,
    input  wire [PAR_OC*8-1:0]  input_zp_flat,
    input  wire [PAR_OC*8-1:0]  weight_zp_flat,
    input  wire [PAR_OC*8-1:0]  output_zp_flat,

    output reg  [PAR_OC-1:0] feat_wr_en,
    output reg               feat_wr_buf_sel,
    output reg  [PAR_OC*18-1:0] feat_wr_addr_flat,
    output reg  [PAR_OC*8-1:0]  feat_wr_data_flat,
    input  wire              out_buf_sel
);
```

计算规则：

```text
output_len = floor((input_len + 2*28 - 64) / 8) + 1
for oc in 0..11:
  for pos in 0..output_len-1:
    acc = sum_{k=0..63} input[pos*8 + k - 28] * weight[oc][k]
    padding index outside [0, input_len-1] -> 0
    output = ReLU(requant(acc))
```

握手：

- `start` 为单拍脉冲。
- `busy` 从接受 start 到完成期间为 1。
- `done` 完成后拉高 1 拍。
- `error` 参数非法时拉高并结束。

不负责：

- 不处理 AXI-Stream 输入。
- 不处理 AXI4-Lite。
- 不管理多个 DSC block。

## B11. `depthwise_conv_engine.v`

职责：

- 执行 DSC block 的 depthwise conv。
- kernel=7，stride=1，padding=3。
- 输入/输出 channel 数相同。
- 默认 8 个 channel 并行。
- 推荐每个 lane 使用 7-tap shift/window register，避免每个 tap 都重复访问 BRAM。

接口：

```verilog
module depthwise_conv_engine #(
    parameter PAR_CH = 8
) (
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    output reg  busy,
    output reg  done,
    output reg  error,

    input  wire [2:0]  block_idx,
    input  wire [7:0]  channels,
    input  wire [15:0] length,
    input  wire        in_buf_sel,
    input  wire        out_buf_sel,

    output reg  [PAR_CH-1:0] feat_rd_en,
    output reg               feat_rd_buf_sel,
    output reg  [PAR_CH*18-1:0] feat_rd_addr_flat,
    input  wire [PAR_CH*8-1:0]  feat_rd_data_flat,

    output reg  [PAR_CH-1:0] feat_wr_en,
    output reg               feat_wr_buf_sel,
    output reg  [PAR_CH*18-1:0] feat_wr_addr_flat,
    output reg  [PAR_CH*8-1:0]  feat_wr_data_flat,

    output reg  [PAR_CH*16-1:0] weight_addr_flat,
    input  wire [PAR_CH*8-1:0]  weight_data_flat,
    output reg  [PAR_CH*12-1:0] bn_addr_flat,
    input  wire [PAR_CH*16-1:0] bn_scale_q8_8_flat,
    input  wire [PAR_CH*32-1:0] bn_bias_flat,
    input  wire [PAR_CH*8-1:0]  input_zp_flat,
    input  wire [PAR_CH*8-1:0]  weight_zp_flat,
    input  wire [PAR_CH*8-1:0]  output_zp_flat
);
```

计算：

```text
for ch in 0..channels-1:
  for pos in 0..length-1:
    acc = sum_{k=0..6} input[ch][pos+k-3] * dw_weight[block_idx][ch][k]
    padding outside [0,length-1] -> 0
    output = ReLU(requant(acc))
```

## B12. `pointwise_conv_engine.v`

职责：

- 执行 1x1 pointwise conv。
- 对输入通道按 `PAR_IC` 分组并行累加，而不是完全串行。
- 默认 8 个 output channel 并行、4 个 input channel 并行。
- 使用流水 adder tree 和 accumulator，避免长组合加法链。

接口：

```verilog
module pointwise_conv_engine #(
    parameter PAR_OC = 8,
    parameter PAR_IC = 4
) (
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    output reg  busy,
    output reg  done,
    output reg  error,

    input  wire [2:0]  block_idx,
    input  wire [7:0]  in_channels,
    input  wire [7:0]  out_channels,
    input  wire [15:0] length,
    input  wire        in_buf_sel,
    input  wire        out_buf_sel,

    output reg  [PAR_IC-1:0] feat_rd_en,
    output reg               feat_rd_buf_sel,
    output reg  [PAR_IC*18-1:0] feat_rd_addr_flat,
    input  wire [PAR_IC*8-1:0]  feat_rd_data_flat,

    output reg  [PAR_OC-1:0] feat_wr_en,
    output reg               feat_wr_buf_sel,
    output reg  [PAR_OC*18-1:0] feat_wr_addr_flat,
    output reg  [PAR_OC*8-1:0]  feat_wr_data_flat,

    output reg  [PAR_OC*PAR_IC*16-1:0] weight_addr_flat,
    input  wire [PAR_OC*PAR_IC*8-1:0]  weight_data_flat,
    output reg  [PAR_OC*12-1:0]        bn_addr_flat,
    input  wire [PAR_OC*16-1:0]        bn_scale_q8_8_flat,
    input  wire [PAR_OC*32-1:0]        bn_bias_flat,
    input  wire [PAR_OC*8-1:0]         input_zp_flat,
    input  wire [PAR_OC*8-1:0]         weight_zp_flat,
    input  wire [PAR_OC*8-1:0]         output_zp_flat
);
```

说明：

- 每个 pos、每组 `PAR_OC` 个 output channel，对 `PAR_IC` 个 input channel 分组累加。
- feature 读必须来自不同 BRAM bank；若发生 bank conflict，调度必须分拍处理。
- weight ROM 推荐按 output channel 和 input-channel group banking，保证每拍提供 `PAR_OC*PAR_IC` 个 int8 weight。
- `PAR_IC` 个乘积求和必须使用流水 adder tree，再进入 int32 accumulator。

计算：

```text
for oc_group in groups(out_channels, PAR_OC):
  for pos in 0..length-1:
    acc[PAR_OC] = 0
    for ic_group in groups(in_channels, PAR_IC):
      acc[oc] += sum_{i=0..PAR_IC-1} input[ic_group+i][pos] * pw_weight[block_idx][oc][ic_group+i]
    output = ReLU(requant(acc))
```

## B13. `maxpool_unit.v`

职责：

- 执行 MaxPool1d kernel=2 stride=2。
- 默认 8 个 channel 并行。

接口：

```verilog
module maxpool_unit #(
    parameter PAR_CH = 8
) (
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    output reg  busy,
    output reg  done,
    output reg  error,

    input  wire [7:0]  channels,
    input  wire [15:0] input_len,
    output reg  [15:0] output_len,
    input  wire        in_buf_sel,
    input  wire        out_buf_sel,

    output reg  [PAR_CH-1:0] feat_rd_en,
    output reg               feat_rd_buf_sel,
    output reg  [PAR_CH*18-1:0] feat_rd_addr_flat,
    input  wire [PAR_CH*8-1:0]  feat_rd_data_flat,

    output reg  [PAR_CH-1:0] feat_wr_en,
    output reg               feat_wr_buf_sel,
    output reg  [PAR_CH*18-1:0] feat_wr_addr_flat,
    output reg  [PAR_CH*8-1:0]  feat_wr_data_flat
);
```

计算：

```text
output_len = floor(input_len / 2)
out[ch][pos] = max(in[ch][2*pos], in[ch][2*pos+1])
```

若 `input_len < 2`，置 error。

## B14. `gap_unit.v`

职责：

- 对每个 channel 沿 length 求平均。
- 默认 8 个 channel 并行。
- 输出 72 项以内的 int8 GAP 向量。

接口：

```verilog
module gap_unit #(
    parameter PAR_CH = 8,
    parameter MAX_CHANNELS = 72
) (
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    output reg  busy,
    output reg  done,
    output reg  error,

    input  wire [7:0]  channels,
    input  wire [15:0] length,
    input  wire        in_buf_sel,

    output reg  [PAR_CH-1:0] feat_rd_en,
    output reg               feat_rd_buf_sel,
    output reg  [PAR_CH*18-1:0] feat_rd_addr_flat,
    input  wire [PAR_CH*8-1:0]  feat_rd_data_flat,

    output reg                 gap_wr_en,
    output reg  [6:0]          gap_wr_addr,
    output reg  signed [7:0]   gap_wr_data
);
```

实现：

```text
sum signed int32
avg = sum / length
out = saturate_int8(avg)
```

第一版允许使用可综合 `/` 进行 bring-up；低延迟/高频优化版本应替换为 reciprocal LUT 或乘法近似，避免动态除法器成为时序和资源瓶颈。

## B15. `final_conv_engine.v`

职责：

- 对 GAP 向量执行 FinalConv：`channels -> NUM_CLASSES`。
- 默认 8 个 class 并行、4 个 input channel 并行累加。
- 输出 signed int8 logits 到内部 logit buffer。
- GAP vector 很小，建议放在寄存器或 LUTRAM 中，便于多路并行读。

接口：

```verilog
module final_conv_engine #(
    parameter PAR_CLASS = 8,
    parameter PAR_IC = 4,
    parameter MAX_CHANNELS = 72,
    parameter MAX_CLASSES = 16
) (
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    output reg  busy,
    output reg  done,
    output reg  error,

    input  wire [7:0] channels,
    input  wire [4:0] num_classes,

    output reg  [PAR_IC*7-1:0] gap_rd_addr_flat,
    input  wire [PAR_IC*8-1:0] gap_rd_data_flat,

    output reg  [PAR_CLASS*PAR_IC*16-1:0] weight_addr_flat,
    input  wire [PAR_CLASS*PAR_IC*8-1:0]  weight_data_flat,
    output reg  [PAR_CLASS*12-1:0]        bn_addr_flat,
    input  wire [PAR_CLASS*16-1:0]        bn_scale_q8_8_flat,
    input  wire [PAR_CLASS*32-1:0]        bn_bias_flat,
    input  wire [PAR_CLASS*8-1:0]         input_zp_flat,
    input  wire [PAR_CLASS*8-1:0]         weight_zp_flat,
    input  wire [PAR_CLASS*8-1:0]         output_zp_flat,

    output reg                 logit_wr_en,
    output reg  [4:0]          logit_wr_addr,
    output reg  signed [7:0]   logit_wr_data
);
```

计算：

```text
for class_group in groups(num_classes, PAR_CLASS):
  acc[PAR_CLASS] = 0
  for ch_group in groups(channels, PAR_IC):
    acc[class] += sum_{i=0..PAR_IC-1} gap[ch_group+i] * fc_weight[class][ch_group+i]
  logit = requant(acc), no ReLU
```

## B16. `cnn_accelerator_top.v`

职责：

- Stage 1 顶层。
- 实例化 AXI4-Lite slave registers。
- 实例化 input buffer、feature buffer、ROM、各 compute engine。
- 管理主 FSM。
- 管理 AXI-Stream 输入接收和输出发送。

接口：

```verilog
module cnn_accelerator_top (
    input  wire        clk,
    input  wire        rst_n_async,

    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [31:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,

    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire [7:0]  s_axis_tdata,
    input  wire        s_axis_tlast,

    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire [7:0]  m_axis_tdata,
    output wire        m_axis_tlast
);
```

主 FSM：

```text
S_IDLE
S_WAIT_INPUT
S_INIT_CONV_START
S_INIT_CONV_WAIT
S_DW_START
S_DW_WAIT
S_PW_START
S_PW_WAIT
S_MP_START
S_MP_WAIT
S_GAP_START
S_GAP_WAIT
S_FC_START
S_FC_WAIT
S_OUTPUT
S_DONE
S_ERROR
```

主 FSM 职责：

- 校验配置：`INPUT_LEN in [1,16384]`，`LAYER_CFG in [1,5]`，`NUM_CLASSES in [1,16]`。
- 接收 AXI-Stream 输入到 `input_buffer`。
- 顺序启动各 compute engine。
- 管理 `current_block/current_in_ch/current_out_ch/current_len`。
- 管理 ping-pong buffer `read_buf_sel/write_buf_sel`。
- 维护 `busy/done/error/cycle_cnt`。
- `cycle_cnt` 默认统计 B+C 阶段：CNN compute + logits output；SoC 级 testbench 额外统计 CPU/AXI-Lite config/polling 周期以验证 B+C+D 延迟。
- 将 final logits 通过 AXI-Stream 输出。

不负责：

- 不在主 FSM 内展开所有卷积细节。
- 不绕过子模块直接写 feature buffer，除了输入接收和输出发送。

## B17. Stage 1 testbench：`tb_cnn_accelerator.sv`

职责：

- 生成 clock/reset。
- 提供 AXI4-Lite BFM task。
- 提供 AXI-Stream input driver。
- 提供 AXI-Stream output monitor。
- 检查 PASS/FAIL。

必须包含 task：

```systemverilog
task axi_write(input logic [31:0] addr, input logic [31:0] data);
task axi_read(input logic [31:0] addr, output logic [31:0] data);
task send_stream_samples(input int n, input bit correct_tlast);
task collect_logits(input int n);
```

基本测试：

```text
1. reset
2. wait 5 cycles after reset release
3. write INPUT_LEN=2048
4. write LAYER_CFG=5
5. write NUM_CLASSES=10
6. write CTRL.start=1
7. send 2048 samples: sample[i]=(i%17)-8
8. collect 10 logits
9. check tlast on final logit
10. poll STATUS: done=1,error=0
11. check cycle_cnt>0
12. CLEAR
13. repeat inference once
```

Backpressure 测试：

- 输入 valid 插空。
- 输出 ready 随机拉低。
- DUT 必须保持协议。

错误测试：

- `INPUT_LEN=0` start -> error。
- `LAYER_CFG=0` start -> error。
- `tlast` 提前 -> error。

性能测试：

- 默认 `INPUT_LEN=2048` 必须检查 Stage 1 accelerator-only B+C 阶段 `cycle_cnt / fclk < 1 ms`。
- Stage 4 full SoC 还必须单独报告包含 CPU 配置/轮询开销的 B+C+D 总周期；最终 `<1 ms` 指标以 B+C+D 口径为准。
- 还必须至少运行一次 `INPUT_LEN=16384`，验证 buffer 地址、length 递推、tlast 检查和输出协议正确；除非用户后续要求，`16384` case 可先不强制满足 `<1 ms`。

## B18. Python fake model data generator：`scripts/gen_fake_model_data.py`

职责：

- 在没有真实训练权重和 golden 数据前，生成 deterministic fake model data。
- 生成 RTL ROM/TB 可直接读取的 `.mem` 文件。
- 用同一份 Python 参考模型计算 fake golden logits，供 testbench 比对。

必须生成：

```text
mem/fake_weights.mem
mem/fake_bn_params.mem
mem/fake_input_2048.mem
mem/golden_logits.mem
```

生成规则：

```text
input[i] = signed int8 pattern, e.g. (i % 17) - 8
weight pattern deterministic, e.g. addr % 5 -> -2,-1,0,1,2
scale = 256
bias = 0
input_zero_point = 0
weight_zero_point = 0
output_zero_point = 0
```

Python golden model 必须按 A4 layer schedule、A5 量化规则和真实 length 递推执行：InitialConv -> 5x DSC(depthwise, pointwise, maxpool) -> GAP -> FinalConv。第一版允许只对 fake weights 做 bit-exact int arithmetic golden，不要求浮点模型。

---

# Part C. Stage 2：SoC shell 详细规格

Stage 2 目标：建立 SoC 顶层壳，不加入 CPU。`soc_shell_top` 暴露 AXI4-Lite 配置口和 AXI-Stream 数据口，内部实例化 `cnn_accelerator_top`。这一步用于验证顶层端口、约束、外部连接方式，为上板和后续 CPU 集成准备。

Stage 2 必须使用独立的 shell 顶层文件/模块，不能占用 `rtl/soc_top.v`。`rtl/soc_top.v` 保留给 Stage 4 full SoC，这样 Stage 4 集成后仍能保留 Stage 2 shell regression。

## C1. Stage 2 文件清单

新增：

```text
rtl/soc_shell_top.v
tb/tb_soc_shell.sv
constraints/soc_shell_top.xdc
```

复用 Stage 1 全部 RTL。

## C2. `soc_shell_top.v`

职责：

- FPGA 顶层 wrapper。
- 实例化 `cnn_accelerator_top`。
- 暴露 AXI4-Lite slave 配置口。
- 暴露 AXI-Stream 输入/输出口。
- 暴露基础 debug/status 信号，便于 testbench 或上板 ILA 观察。

接口：

```verilog
module soc_shell_top (
    input  wire        clk,
    input  wire        rst_n_async,

    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [31:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,

    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire [7:0]  s_axis_tdata,
    input  wire        s_axis_tlast,

    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire [7:0]  m_axis_tdata,
    output wire        m_axis_tlast,

    output wire        dbg_busy,
    output wire        dbg_done,
    output wire        dbg_error
);
```

说明：

- Stage 2 的 `soc_shell_top` 不包含 CPU。
- AXI4-Lite 配置口直接连到内部 `cnn_accelerator_top`。
- `dbg_busy/done/error` 可以通过内部状态寄存器导出；若不想增加 accelerator 端口，也可以通过 AXI 读 STATUS 验证，不强制导出。
- Stage 2 shell regression 必须在 Stage 4 `soc_top` 集成后仍可单独编译/仿真。

不负责：

- 不实现 RISC-V。
- 不实现外部 DDR。
- 不实现 AXI interconnect。
- 不实现 interrupt。

## C3. `constraints/soc_shell_top.xdc`

职责：

- 提供可综合/实现的基础时钟约束。
- 不要求真实板卡 pin 绑定，除非用户后续提供板卡原理图。

最低要求：

```tcl
# bring-up constraint
create_clock -period 10.000 [get_ports clk]

# optimized timing target; enable this when low-latency implementation is ready
# create_clock -period 5.000 [get_ports clk]
```

如果没有确定引脚，不要随意编造 FPGA pin。只写时钟约束和必要 false path/reset path 建议。不要随意使用 `CLOCK_DEDICATED_ROUTE FALSE` 掩盖时钟布线问题；只有在明确板卡时钟路径且用户确认后才允许使用。

## C4. `tb_soc_shell.sv`

职责：

- 复用 Stage 1 的 AXI4-Lite BFM 和 stream driver。
- DUT 换成 `soc_shell_top`。
- 验证 wrapper 不改变 Stage 1 行为。

测试：

- 与 `tb_cnn_accelerator.sv` 基本流程一致。
- 确认所有 AXI/Stream 信号经过 `soc_top` 后仍正确。

---

# Part D. Stage 3：RISC-V CPU standalone 详细规格

Stage 3 目标：单独实现和验证 RV32I 五级流水线 CPU，不接 CNN。CPU 需要支持 memory-mapped I/O，并实现一个单 outstanding AXI4-Lite master，用于后续 Stage 4 配置 CNN。

## D1. Stage 3 文件清单

新增：

```text
rtl/cpu/regfile.v
rtl/cpu/alu.v
rtl/cpu/imm_gen.v
rtl/cpu/ctrl_unit.v
rtl/cpu/hazard_unit.v
rtl/cpu/branch_unit.v
rtl/cpu/axi_lite_master.v
rtl/cpu/inst_rom.v
rtl/cpu/data_ram.v
rtl/cpu/riscv_top.v
tb/tb_riscv_core.sv
firmware/cpu_test.S
firmware/cpu_test.hex
```

## D2. CPU 顶层 `riscv_top.v`

职责：

- 实现 RV32I 五级流水线。
- 包含或实例化 instruction ROM、data RAM。
- 对 `0x1000_0000` 地址段发起 AXI4-Lite master transaction。
- 对 `0x1000_0020` test output 地址写出 magic value。
- 输出 debug/halt 信号给 testbench。

接口：

```verilog
module riscv_top #(
    parameter INST_MEM_FILE = "firmware/cpu_test.hex"
) (
    input  wire        clk,
    input  wire        rst_n,

    output wire [31:0] m_axi_awaddr,
    output wire        m_axi_awvalid,
    input  wire        m_axi_awready,
    output wire [31:0] m_axi_wdata,
    output wire [3:0]  m_axi_wstrb,
    output wire        m_axi_wvalid,
    input  wire        m_axi_wready,
    input  wire [1:0]  m_axi_bresp,
    input  wire        m_axi_bvalid,
    output wire        m_axi_bready,

    output wire [31:0] m_axi_araddr,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [31:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready,

    output reg         test_done,
    output reg  [31:0] test_value,
    output reg         halted,
    output wire [31:0] dbg_pc
);
```

说明：

- `rst_n` 已经是同步释放复位，不在 CPU 内部再同步。
- AXI master 为单 outstanding transaction。
- `halted` 可由 EBREAK 或固定 halt loop 检测产生。
- `INST_MEM_FILE` 用于在 Stage 3 CPU firmware 与 Stage 4 SoC firmware 之间切换 instruction ROM 初始化文件。

CPU 地址映射：

```text
0x0000_0000 ~ 0x0FFF_FFFF  → 本地 data_ram（inst_rom 使用独立的 PC 地址空间）
0x1000_0000 ~ 0x1000_FFFF  → AXI4-Lite master（外设段：CNN registers + test output）
其余地址                      → SLVERR（AXI master 返回 error）
```

`riscv_top` 内部负责在 MEM 阶段根据地址决定走 `data_ram` 还是 `axi_lite_master`。`inst_rom` 由 PC 直接寻址，不参与此地址解码。

## D3. 指令集

必须支持：

```text
ADD, SUB, ADDI,
SLTI, SLTIU, SLT, SLTU,
XORI, ORI, ANDI, XOR, OR, AND,
SLLI, SRLI, SRAI, SLL, SRL, SRA,
BEQ, BNE, BLT, BGE, BLTU, BGEU,
JAL, JALR,
LW, SW,
LUI, AUIPC,
ECALL, EBREAK,
FENCE as NOP
```

可以不支持：

- M extension。
- compressed instruction。
- CSR。
- interrupt/trap。
- misaligned load/store。

非法指令行为：

- 可置 `halted=1` 或进入 trap-like halt 状态。
- testbench 中不应生成非法指令。

## D4. `regfile.v`

职责：

- 32 个 32-bit 通用寄存器。
- x0 恒为 0。
- 双读单写。

接口：

```verilog
module regfile (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [4:0]  rs1_addr,
    input  wire [4:0]  rs2_addr,
    output wire [31:0] rs1_data,
    output wire [31:0] rs2_data,
    input  wire        rd_we,
    input  wire [4:0]  rd_addr,
    input  wire [31:0] rd_data
);
```

规则：

- 写 x0 被忽略。
- 读 x0 永远 0。
- 同周期写后读同一寄存器可以通过外部 forwarding 解决，不强制 regfile write-first。

## D5. `alu.v`

职责：

- 执行 RV32I ALU 操作。

接口：

```verilog
module alu (
    input  wire [3:0]  alu_op,
    input  wire [31:0] src_a,
    input  wire [31:0] src_b,
    output reg  [31:0] result
);
```

操作：

```text
ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND
```

## D6. `imm_gen.v`

职责：

- 根据 instruction 生成 I/S/B/U/J immediate。

接口：

```verilog
module imm_gen (
    input  wire [31:0] instr,
    output reg  [31:0] imm_i,
    output reg  [31:0] imm_s,
    output reg  [31:0] imm_b,
    output reg  [31:0] imm_u,
    output reg  [31:0] imm_j
);
```

## D7. `ctrl_unit.v`

职责：

- 解码 instruction。
- 产生 ALU、branch、load/store、reg write、mem-to-reg、jump 等控制信号。

接口可以根据实现调整，但必须至少输出：

```text
alu_op
alu_src_a_sel
alu_src_b_sel
reg_write
mem_read
mem_write
mem_to_reg
branch_type
jump_type
load_type
store_type
is_ecall
is_ebreak
is_fence
illegal_instr
```

## D8. `hazard_unit.v`

职责：

- 检测 load-use hazard。
- 产生 forwarding 选择。
- 产生 pipeline stall/flush。

必须处理：

```text
EX/MEM -> EX forwarding
MEM/WB -> EX forwarding
store rs2 data forwarding
load-use one-cycle stall
branch/jump flush IF/ID
```

接口建议：

```verilog
module hazard_unit (
    input  wire [4:0] id_rs1,
    input  wire [4:0] id_rs2,
    input  wire [4:0] ex_rs1,
    input  wire [4:0] ex_rs2,
    input  wire [4:0] ex_rd,
    input  wire       ex_mem_read,
    input  wire [4:0] mem_rd,
    input  wire       mem_reg_write,
    input  wire [4:0] wb_rd,
    input  wire       wb_reg_write,
    input  wire       branch_taken,
    input  wire       axi_stall,
    output reg        stall_f,
    output reg        stall_d,
    output reg        flush_d,
    output reg        flush_e,
    output reg  [1:0] fwd_a_sel,
    output reg  [1:0] fwd_b_sel
);
```

## D9. `branch_unit.v`

职责：

- 根据 branch_type 比较 rs1/rs2。
- 生成 `branch_taken`。

支持：

```text
BEQ, BNE, BLT, BGE, BLTU, BGEU
```

## D10. `axi_lite_master.v`

职责：

- 将 CPU 的 memory-mapped load/store 请求转换为 AXI4-Lite master transaction。
- 单 outstanding。
- 支持 32-bit word read/write。
- 用于访问 `0x1000_0000` CNN 寄存器空间。

接口：

```verilog
module axi_lite_master (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        req_valid,
    output wire        req_ready,
    input  wire        req_write,
    input  wire [31:0] req_addr,
    input  wire [31:0] req_wdata,
    input  wire [3:0]  req_wstrb,

    output reg         resp_valid,
    input  wire        resp_ready,
    output reg  [31:0] resp_rdata,
    output reg         resp_error,

    output reg  [31:0] m_axi_awaddr,
    output reg         m_axi_awvalid,
    input  wire        m_axi_awready,
    output reg  [31:0] m_axi_wdata,
    output reg  [3:0]  m_axi_wstrb,
    output reg         m_axi_wvalid,
    input  wire        m_axi_wready,
    input  wire [1:0]  m_axi_bresp,
    input  wire        m_axi_bvalid,
    output reg         m_axi_bready,

    output reg  [31:0] m_axi_araddr,
    output reg         m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [31:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rvalid,
    output reg         m_axi_rready
);
```

FSM：

```text
M_IDLE
M_WRITE_ADDR_DATA
M_WRITE_RESP
M_READ_ADDR
M_READ_DATA
M_RESP
```

要求：

- 写地址和写数据 channel 可同时发出。
- 等待 `AWREADY` 和 `WREADY` 都完成后，再等 `BVALID`。
- 读请求等 `ARREADY` 后，再等 `RVALID`。
- `resp_valid` 保持到 `resp_ready`。
- `BRESP/RRESP != OKAY` 时 `resp_error=1`。

## D11. `inst_rom.v`

职责：

- 存储 instruction memory。
- 从 `firmware/*.hex` 初始化。

接口：

```verilog
module inst_rom #(
    parameter ADDR_WIDTH = 12,
    parameter MEM_FILE = "firmware/cpu_test.hex"
) (
    input  wire        clk,
    input  wire [31:0] addr,
    output reg  [31:0] instr
);
```

规则：

- word addressed internally：`addr[ADDR_WIDTH+1:2]`。
- 同步读，一拍延迟。
- reset vector = `0x0000_0000`。

## D12. `data_ram.v`

职责：

- 实现 CPU 本地 data RAM。

接口：

```verilog
module data_ram #(
    parameter ADDR_WIDTH = 12
) (
    input  wire        clk,
    input  wire        mem_we,
    input  wire [3:0]  mem_wstrb,
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata
);
```

支持：

- LW/SW word access。
- byte strobe for SW。

不支持：

- misaligned load/store。
- byte/halfword load/store，除非后续扩展。

## D13. CPU pipeline 关键规则

### D13.1 Pipeline register

必须有明确 pipeline register：

```text
IF/ID:  pc, instr, valid
ID/EX:  pc, rs1, rs2, rd, imm, control, rs1_val, rs2_val, valid
EX/MEM: alu_result, store_data, rd, control, branch info, valid
MEM/WB: wb_data, alu_result, rd, control, valid
```

### D13.2 Branch PC 更新

- branch/jump target 在 EX 阶段确定。
- taken 时 PC 立即更新到 target。
- flush IF/ID。
- EX/MEM 和 MEM/WB 正常推进。

### D13.3 Load-use stall

当 ID 阶段使用 EX 阶段 load 的 rd：

- stall PC 和 IF/ID。
- ID/EX 插入 bubble。
- EX 中已有 load 正常进入 MEM。

### D13.4 同步 inst_rom stall/IF skid

`inst_rom` 是同步一拍读。若 PC/IF 已发出取指请求后 pipeline 因 load-use、AXI stall 或 branch flush 暂停，返回的 instruction 不允许丢失或错配 PC。实现必须满足以下之一：

- IF/ID 可在同拍接收返回 instruction 且 PC/instr 对齐。
- 使用 IF skid buffer 保存返回的 `pc/instr/valid`，直到 IF/ID 可接收。
- 或采用等效机制，确保 stall 后恢复执行时不会跳过已取回的指令。

### D13.5 AXI stall

当 MEM 阶段发起 AXI transaction 且未完成：

- stall pipeline。
- MEM-stage external request 的 address、write data、write strobe、read/write 类型、rd/destination metadata 必须在请求发出时锁存，并保持到 AXI response 完成。
- AXI master FSM 独立运行直到 response。
- 后续 ID/EX/EX/MEM 更新不得覆盖 in-flight MMIO transaction。
- 紧邻 MMIO store、重复使用同一个源寄存器、或后续指令修改该源寄存器时，也必须保证已发出的 AXI write address/data/strobe 不变。

## D14. Stage 3 firmware：assembly/hex

必须提供 `firmware/cpu_test.S`，并可导出 `cpu_test.hex`。`.S` 与 `.hex` 必须保持一致；若手工编码 `.hex`，必须在注释、脚本或说明中保留可复核的编码来源。

测试程序应依次覆盖：

```text
ALU arithmetic
ALU logic
load/store local RAM
EX/MEM forwarding
MEM/WB forwarding
load-use stall
branch taken
branch not taken
JAL
JALR
memory-mapped write to test output
back-to-back external MMIO stores with distinct addresses/data
back-to-back external MMIO stores that reuse and then modify the same source register
external MMIO read after delayed RVALID
EBREAK or halt loop
```

建议 magic value：

```text
0xCAFE_BABE -> all CPU tests passed
```

## D15. `tb_riscv_core.sv`

职责：

- 实例化 `riscv_top`。
- 提供 AXI4-Lite dummy slave，响应 CPU 对 `0x1000_0000` 空间的读写。
- dummy slave 必须支持可配置 `AWREADY/WREADY/BVALID/ARREADY/RVALID` 延迟，覆盖 AXI stall 场景。
- 检查 `test_done` 和 `test_value`。
- 记录并校验观察到的 AXI write 地址、数据和 strobe 顺序，特别是 back-to-back MMIO store。
- 超时失败。

通过条件：

```text
test_done == 1
test_value == 32'hCAFE_BABE
halted == 1 or PC enters halt loop
no timeout
```

---

# Part E. Stage 4：Full SoC 详细规格

Stage 4 目标：集成 RISC-V CPU 和 CNN accelerator。CPU 通过 AXI4-Lite master 配置 CNN，外部 testbench 通过 AXI-Stream 提供样本，CNN 输出 logits，CPU polling `STATUS.done` 后写出 test magic。

## E1. Stage 4 文件清单

新增或修改：

```text
rtl/soc_top.v
rtl/axi_lite_addr_decode.v
firmware/soc_firmware.S
firmware/soc_firmware.hex
tb/tb_soc.sv
```

复用：

```text
Stage 1 CNN accelerator
Stage 3 RISC-V CPU
```

## E2. Full `soc_top.v`

职责：

- 实例化 `riscv_top`。
- 实例化 `cnn_accelerator_top`。
- 将 CPU AXI4-Lite master 连接到 CNN AXI4-Lite slave。
- 暴露 AXI-Stream 输入/输出。
- 暴露 test/debug 信号。

接口：

```verilog
module soc_top (
    input  wire        clk,
    input  wire        rst_n_async,

    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire [7:0]  s_axis_tdata,
    input  wire        s_axis_tlast,

    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire [7:0]  m_axis_tdata,
    output wire        m_axis_tlast,

    output wire        test_done,
    output wire [31:0] test_value,
    output wire        cpu_halted,
    output wire [31:0] dbg_pc,
    output wire        dbg_cnn_busy,
    output wire        dbg_cnn_done,
    output wire        dbg_cnn_error
);
```

注意：

- Stage 4 的 `soc_top` 不再暴露外部 AXI4-Lite 配置口，配置由 CPU 内部完成。
- Stage 4 full `soc_top` 独占 `rtl/soc_top.v`；不得替换或删除 Stage 2 的 `rtl/soc_shell_top.v`。
- 如果希望同时保留外部 AXI4-Lite debug port，必须加仲裁器；v5 暂不实现，避免复杂化。

## E3. `axi_lite_addr_decode.v`

职责：

- 解码 CPU AXI master 地址。
- 将 `0x1000_0000 ~ 0x1000_001F` 转发到 CNN accelerator。
- 将 `0x1000_0020` test output 作为 SoC 内部 test register。

接口可按实际调整，但必须支持：

```text
CPU master input AXI4-Lite
CNN slave output AXI4-Lite
internal test output write capture
```

地址表：

| 地址 | 行为 |
|------|------|
| 0x1000_0000 ~ 0x1000_001F | CNN registers |
| 0x1000_0020 | test output write-only |
| others | SLVERR |

对 `0x1000_0020` 写：

```text
test_value <= WDATA
test_done  <= 1
BRESP      <= OKAY
```

对 `0x1000_0020` 读：

```text
RDATA <= test_value
RRESP <= OKAY
```

## E4. CPU firmware `soc_firmware.S`

使用 RV32I assembly 或直接生成 hex。`soc_firmware.S` 与 `soc_firmware.hex` 必须保持一致；若手工编码 `.hex`，必须保留可复核的编码说明或生成脚本。

固件逻辑：

```asm
# base addresses
CNN_BASE      = 0x10000000
CTRL          = 0x00
STATUS        = 0x04
INPUT_LEN     = 0x08
LAYER_CFG     = 0x0C
NUM_CLASSES   = 0x10
CLEAR         = 0x14
CYCLE_CNT     = 0x18
TEST_OUTPUT   = 0x10000020

# sequence
write INPUT_LEN   = 2048
write LAYER_CFG   = 5
write NUM_CLASSES = 10
write CTRL        = 1
poll STATUS until bit[1] done == 1
read CYCLE_CNT
write TEST_OUTPUT = 0xA5A50000 | low16(CYCLE_CNT)  # or fixed magic if easier
halt_loop: beq x0, x0, halt_loop
```

如果实现位操作复杂，可以写固定 magic：

```text
0xA5A5_0001 -> SoC firmware reached done
```

禁止：

- 不使用 CSR。
- 不使用 interrupt。
- 不依赖 stack。
- 不依赖 C runtime。
- 不把 NOP 间隔作为 CPU/AXI 正确性的必要条件；即使固件为了调试插入 NOP，最终 CPU 仍必须满足 D13.5 的紧邻 MMIO store 保持规则。

## E5. Full SoC 数据流

```text
CPU reset -> CPU executes firmware from inst_rom
CPU AXI write CNN config
CPU AXI write CNN start
CNN enters WAIT_INPUT
TB sends AXI-Stream samples
CNN computes and outputs logits
CPU polls CNN STATUS.done
CPU writes TEST_OUTPUT
tb_soc observes test_done and stream logits
```

关键点：

- CPU 不发送样本数据。
- CPU 不读取 logits。
- logits 只通过 `m_axis` 输出给外部。
- testbench 要在 CPU start CNN 后及时发送 stream 样本。
- 如果 testbench 太晚发送，CNN 会保持 `s_axis_tready=1` 等待，不应超时。

## E6. `tb_soc.sv`

职责：

- 实例化 full `soc_top`。
- 产生 clock/reset。
- 不直接写 CNN AXI registers；这些由 CPU 完成。
- 观察 `s_axis_tready`，当 CNN ready 后发送样本。
- 收集 logits。
- 观察 `test_done/test_value`。

流程：

```text
1. reset
2. wait reset sync
3. wait until s_axis_tready==1 or dbg_cnn_busy==1
4. send INPUT_LEN samples with valid/ready handshake
5. collect NUM_CLASSES logits
6. wait test_done==1
7. check test_value magic
8. check dbg_cnn_error==0
9. PASS
```

必须有超时：

```text
if simulation cycles > MAX_CYCLES -> FAIL
```

建议 `MAX_CYCLES` 初始设大，例如 `20_000_000` cycles；低延迟优化版本还必须检查 B+C+D 阶段总延迟 `< 1 ms`。A 阶段 AXI-Stream 输入加载不计入该指标。

## E7. Stage 4 验证通过条件

```text
CPU starts from PC=0
CPU writes CNN config through AXI4-Lite
CNN accepts stream input
CNN outputs NUM_CLASSES logits
m_axis_tlast appears exactly on final logit
CNN STATUS.done becomes 1
CNN STATUS.error remains 0
CPU observes done through polling
CPU writes TEST_OUTPUT magic
test_done == 1
simulation exits before timeout
```

---

# Part F. 生成顺序强制要求

不要一次生成所有文件。必须按阶段、按批次生成。

## F1. Stage 1 推荐批次

```text
Batch 0: scripts/gen_fake_model_data.py + mem/*.mem fake data
Batch 1: reset_sync, saturate_int8, requant_relu
Batch 2: fake_weight_rom, fake_bn_rom, input_buffer, feature_buffer
Batch 3: axi_lite_slave_regs
Batch 4: initial_conv_engine
Batch 5: depthwise_conv_engine, pointwise_conv_engine
Batch 6: maxpool_unit, gap_unit, final_conv_engine
Batch 7: cnn_accelerator_top
Batch 8: tb_cnn_accelerator
```

每个 batch 后：

```text
run syntax check
fix compile errors
for memory-heavy modules, run Vivado synthesis check for BRAM/LUTRAM inference
for compute-heavy modules, check estimated Fmax and DSP inference
continue
```

## F2. Stage 2 推荐批次

```text
Batch 1: soc_shell_top shell
Batch 2: tb_soc_shell
Batch 3: soc_shell_top xdc skeleton
```

## F3. Stage 3 推荐批次

```text
Batch 1: regfile, alu, imm_gen, branch_unit
Batch 2: ctrl_unit, hazard_unit
Batch 3: inst_rom, data_ram
Batch 4: axi_lite_master
Batch 5: riscv_top pipeline
Batch 6: cpu_test.S / cpu_test.hex
Batch 7: tb_riscv_core
```

## F4. Stage 4 推荐批次

```text
Batch 1: axi_lite_addr_decode
Batch 2: full soc_top integration
Batch 3: soc_firmware.S / soc_firmware.hex
Batch 4: tb_soc
```

---

# Part G. 不允许做的事

为了保证设计可控，禁止加入以下内容：

```text
DDR controller
AXI DMA
AXI interconnect with multiple masters
cache
RISC-V CSR/interrupt/trap
M extension multiplier/divider
compressed instruction
external UART/SPI/I2C
floating point
training logic
runtime weight loading
clock domain crossing beyond reset sync
```

除非用户后续明确要求，否则不要扩展这些功能。

---

# Part H. 后续接入真实权重的预留规范

当前 v5 使用 Python 生成的 deterministic fake weights，并固化到 ROM/BRAM 初始化文件中。v5 不支持 runtime weight loading。未来用户导出真实权重时，必须替换：

```text
fake_weight_rom.v -> weight_rom.v + weights.mem
fake_bn_rom.v     -> bn_rom.v + bn_params.mem
```

真实权重必须遵守 v5 中定义的线性地址顺序：

```text
InitialConv: initial_weight[oc][k]
Depthwise:   dw_weight[layer][channel][k]
Pointwise:   pw_weight[layer][out_channel][in_channel]
FinalConv:   fc_weight[class][in_channel]
```

真实 BN/requant/zero-point 参数必须遵守：

```text
scale:             signed int16 Q8.8 unless export says otherwise
bias:              signed int32
input_zero_point:  signed int8
weight_zero_point: signed int8
output_zero_point: signed int8
```

如果真实模型量化采用其他 Q 格式、zero-point 粒度或 per-channel 参数布局，必须先更新本规格的量化章节和 ROM 地址布局，再生成 RTL。
