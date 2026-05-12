# 1DCNN_ACC 阶段实现工作总结与遗留问题记录

日期：2026-05-12  
项目路径：`D:/RICS_V_CNN/1DCNN_ACC`  
验证工具链：Vivado 2021.2 (`D:/2021.2/Vivado/2021.2`)  
验证方式：优先 Vivado `xvlog` / `xelab` / `xsim`，先功能闭环，后性能优化。

## 1. 总体目标

本轮工作依据 `agent_prompt.v5.md` 逐步实现一个 1D-CNN 加速器 SoC 工程，按规格分为四个阶段：

1. Stage 1：独立 CNN accelerator。
2. Stage 2：CNN accelerator 的 SoC shell wrapper。
3. Stage 3：独立 RV32I RISC-V CPU。
4. Stage 4：CPU + CNN accelerator 的 full SoC 集成。

用户确认的关键实施策略：

- 使用 Vivado xsim/Vivado 2021.2 作为主要仿真检查流程。
- 先保证功能正确，再处理性能和资源优化。
- 初始 golden 数据先只覆盖 2048 输入长度。
- 遇到长期卡住或需要后续处理的问题，要写入项目 Markdown 文件记录，便于后续解决。

## 2. 当前总体状态

当前 RTL 已经完成 Stage 1 到 Stage 4 的功能实现和 xsim 仿真闭环。

已通过的关键仿真结果：

```text
Stage 1 CNN accelerator: TB PASS
Stage 2 SoC shell:       SOC SHELL TB PASS
Stage 3 RISC-V core:     RISC-V CORE TB PASS pc=000000e8 cycles=84
Stage 4 Full SoC:        FULL SOC TB PASS pc=00000048 cycles=242346 test_value=a5a50001
```

当前仍未关闭的主要问题：

1. CNN 2048 case 当前 B+C cycle count 为 `240236`，尚未满足 `<1ms` 目标。

已关闭问题：
- `feature_buffer` BRAM 映射（2026-05-12）：改用 `xpm_memory_sdpram`，OOC synth 从 0 BRAM / 46080 LUTRAM 变为 80 RAMB36E2 / 0 LUTRAM。tb_cnn_accelerator 与 tb_soc 功能/周期 bit-exact。
- CPU `inst_rom` / IF 对齐导致的 MMIO store hazard（2026-05-12）：给 `inst_rom` 增加 `ce=!stall_f`，移除 `soc_firmware.S` 中的 NOP 和多寄存器预载，新增 `tb_riscv_stress.sv` 回归。详见 §9.3。

## 3. 新增和修改的主要文件

### 3.1 数据和脚本

- `scripts/gen_fake_model_data.py`
- `mem/fake_weights.mem`
- `mem/fake_bn_params.mem`
- `mem/fake_input_2048.mem`
- `mem/golden_logits.mem`

### 3.2 Stage 1 CNN accelerator RTL

- `rtl/reset_sync.v`
- `rtl/saturate_int8.v`
- `rtl/requant_relu.v`
- `rtl/fake_weight_rom.v`
- `rtl/fake_bn_rom.v`
- `rtl/input_buffer.v`
- `rtl/feature_buffer.v`
- `rtl/axi_lite_slave_regs.v`
- `rtl/initial_conv_engine.v`
- `rtl/depthwise_conv_engine.v`
- `rtl/pointwise_conv_engine.v`
- `rtl/maxpool_unit.v`
- `rtl/gap_unit.v`
- `rtl/final_conv_engine.v`
- `rtl/cnn_accelerator_top.v`

### 3.3 Stage 1/2/3/4 testbench

- `tb/tb_cnn_accelerator.sv`
- `tb/tb_soc_shell.sv`
- `tb/tb_riscv_core.sv`
- `tb/tb_soc.sv`

### 3.4 Stage 2/4 top and constraints

- `rtl/soc_top.v`
- `rtl/axi_lite_addr_decode.v`
- `constraints/soc_top.xdc`

注意：`rtl/soc_top.v` 当前已经从 Stage 2 shell 版本替换为 Stage 4 full SoC 顶层。因此，当前 HEAD 下如果直接重新运行 `tb/tb_soc_shell.sv`，需要恢复 Stage 2 shell 顶层或另建独立 Stage 2 wrapper；Stage 2 shell 已在被替换前通过验证。

### 3.5 Stage 3 CPU RTL

- `rtl/cpu/regfile.v`
- `rtl/cpu/alu.v`
- `rtl/cpu/imm_gen.v`
- `rtl/cpu/ctrl_unit.v`
- `rtl/cpu/hazard_unit.v`
- `rtl/cpu/branch_unit.v`
- `rtl/cpu/axi_lite_master.v`
- `rtl/cpu/inst_rom.v`
- `rtl/cpu/data_ram.v`
- `rtl/cpu/riscv_top.v`

### 3.6 Firmware

- `firmware/cpu_test.S`
- `firmware/cpu_test.hex`
- `firmware/soc_firmware.S`
- `firmware/soc_firmware.hex`

### 3.7 问题记录

- `OPEN_ISSUES.md`
- `OPRN_ISSUE.MD`（本文件）

## 4. Stage 1：CNN accelerator 实现总结

### 4.1 Batch 0：fake model/golden 数据生成

实现了 `scripts/gen_fake_model_data.py`，用于生成确定性的 fake 输入、fake 权重、BN 参数和 golden logits。

关键约定：

- 输入长度：`2048`
- 输入样本：`(i % 17) - 8`
- fake weight pattern：`addr % 5 -> -2, -1, 0, 1, 2`
- BN/requant 参数：
  - `scale_q8_8 = 256`
  - `bias = 0`
  - `input_zp = 0`
  - `weight_zp = 0`
  - `output_zp = 0`
- 输出类别数：`10`
- golden logits：

```text
7f 80 7f 7f 80 7f 80 7f 7f 80
```

### 4.2 Batch 1：基础单元

实现文件：

- `reset_sync.v`
- `saturate_int8.v`
- `requant_relu.v`

功能：

- 异步复位同步释放。
- int32 到 int8 饱和。
- Q8.8 scale + bias + output zero point 的 requant pipeline。

### 4.3 Batch 2：ROM/RAM/buffer

实现文件：

- `fake_weight_rom.v`
- `fake_bn_rom.v`
- `input_buffer.v`
- `feature_buffer.v`

当前状态：

- `input_buffer` 已可综合并推断为 BRAM。
- `feature_buffer` 功能通过，但 Vivado 2021.2 仍映射到 LUTRAM/distributed RAM。
- `feature_buffer` 的 BRAM 映射问题已记录为未关闭问题。

### 4.4 Batch 3：AXI4-Lite 寄存器

实现 `rtl/axi_lite_slave_regs.v`。

寄存器映射：

| 地址 | 名称 | 功能 |
|---|---|---|
| `0x00` | CTRL | start / soft reset |
| `0x04` | STATUS | busy/done/error |
| `0x08` | INPUT_LEN | 输入长度 |
| `0x0C` | LAYER_CFG | block 数 |
| `0x10` | NUM_CLASSES | 类别数 |
| `0x14` | CLEAR | 清除 done/error |
| `0x18` | CYCLE_CNT | B+C cycle count |
| `0x1C` | VERSION | `32'h0000_0400` |

### 4.5 Batch 4/5/6：CNN engines

实现文件：

- `initial_conv_engine.v`
- `depthwise_conv_engine.v`
- `pointwise_conv_engine.v`
- `maxpool_unit.v`
- `gap_unit.v`
- `final_conv_engine.v`

实现内容：

- InitialConv。
- 5 个 DSC block 的 depthwise + pointwise + maxpool。
- GAP。
- FinalConv 输出 logits。

关键修复：

- 修正 initial/depthwise/pointwise/final conv 的全局 weight 地址计算。
- 给同步 ROM/BRAM 访问补 wait state。
- 给 requant 输出补寄存器锁存，避免写出上一拍或未稳定数据。
- 修复 pointwise 内层循环中多次 nonblocking assignment 只保留最后一次贡献的问题。
- 修复 final conv 在等待 weight ROM 时 GAP 地址被清零导致所有通道读 `gap[0]` 的问题。

### 4.6 Batch 7：accelerator top

实现 `rtl/cnn_accelerator_top.v`。

功能：

- AXI4-Lite 配置。
- AXI-Stream 输入。
- CNN engine 调度。
- AXI-Stream logits 输出。
- busy/done/error/debug。
- cycle count 统计。

关键调度状态：

```text
IDLE -> WAIT_INPUT -> INIT_CONV -> DSC blocks -> GAP -> FC -> OUTPUT -> DONE/ERROR
```

关键修复：

- feature-buffer 读数据 bank/lane 对齐补一拍寄存器。
- top-level mux 保留 engine 最后一拍 write pulse，避免 `busy` 拉低同时 write 被丢。
- cycle count 只统计 compute/output 阶段，排除输入加载阶段。
- output backpressure 时暂停 cycle count。
- 新增 `dbg_busy/dbg_done/dbg_error` 真实状态输出。

### 4.7 Batch 8：Stage 1 testbench

实现 `tb/tb_cnn_accelerator.sv`。

覆盖场景：

- basic 2048 golden。
- repeat inference。
- input valid gaps。
- output backpressure。
- early TLAST error。
- missing TLAST error。
- invalid input length。
- invalid layer config。
- post-error clean run。
- 16384 max length smoke。

通过结果：

```text
basic cycle_cnt=240236
repeat cycle_cnt=240236
input_valid_gaps cycle_cnt=240236
output_backpressure cycle_cnt=240236
early_tlast observed expected error status
missing_tlast observed expected error status
invalid_input_len observed expected error status
invalid_layer_cfg observed expected error status
post_error_clean cycle_cnt=240236
max_len_smoke cycle_cnt=1918556
TB PASS
```

## 5. Stage 2：SoC shell 实现总结

### 5.1 实现内容

创建 Stage 2 shell 版本的 `soc_top.v`，直接 wrap `cnn_accelerator_top`，外部仍暴露 AXI4-Lite 配置口和 AXI-Stream 数据口。

同时新增：

- `tb/tb_soc_shell.sv`
- `constraints/soc_top.xdc`

约束文件内容：

```tcl
create_clock -period 10.000 [get_ports clk]

# Optimized timing target; enable after low-latency implementation is ready.
# create_clock -period 5.000 [get_ports clk]
```

### 5.2 验证结果

Stage 2 shell xsim 通过：

```text
soc_shell_basic cycle_cnt=240236
soc_shell_backpressure cycle_cnt=240236
SOC SHELL TB PASS
```

### 5.3 当前注意事项

当前 `rtl/soc_top.v` 已经被 Stage 4 full SoC 顶层覆盖。Stage 2 shell 验证结果有效，但当前文件状态不再是 Stage 2 shell 接口。

## 6. Stage 3：RISC-V CPU standalone 实现总结

### 6.1 实现模块

实现了一个 RV32I 五级流水线 CPU：

- IF
- ID
- EX
- MEM
- WB

新增文件：

- `rtl/cpu/regfile.v`
- `rtl/cpu/alu.v`
- `rtl/cpu/imm_gen.v`
- `rtl/cpu/ctrl_unit.v`
- `rtl/cpu/hazard_unit.v`
- `rtl/cpu/branch_unit.v`
- `rtl/cpu/axi_lite_master.v`
- `rtl/cpu/inst_rom.v`
- `rtl/cpu/data_ram.v`
- `rtl/cpu/riscv_top.v`

支持指令覆盖：

- `ADD/SUB/ADDI`
- `SLT/SLTU/SLTI/SLTIU`
- `XOR/OR/AND/XORI/ORI/ANDI`
- `SLL/SRL/SRA/SLLI/SRLI/SRAI`
- `BEQ/BNE/BLT/BGE/BLTU/BGEU`
- `JAL/JALR`
- `LW/SW`
- `LUI/AUIPC`
- `FENCE` as NOP
- `ECALL/EBREAK` halt-like behavior

### 6.2 CPU memory map

- `0x0000_0000 ~ 0x0FFF_FFFF`：本地 data RAM。
- `0x1000_0000 ~ 0x1000_FFFF`：AXI4-Lite master 外设空间。

### 6.3 CPU 测试固件

新增：

- `firmware/cpu_test.S`
- `firmware/cpu_test.hex`

覆盖内容：

- ALU arithmetic。
- ALU logic。
- local RAM load/store。
- EX/MEM forwarding。
- MEM/WB forwarding。
- load-use stall。
- branch taken/not taken。
- JAL/JALR。
- memory-mapped write to test output。
- EBREAK halt。

### 6.4 CPU testbench

新增 `tb/tb_riscv_core.sv`。

功能：

- 实例化 `riscv_top`。
- 提供 AXI4-Lite dummy slave。
- 检查 `test_done`、`test_value`、`halted`。

### 6.5 关键修复

1. 增加 WB -> ID bypass，避免 ID 阶段分支/比较读到尚未回写的旧值。
2. 增加 IF skid buffer，修复同步 instruction ROM 在 load-use stall 期间返回下一条指令但 IF/ID 未接收导致指令丢失的问题。
3. 修正 CPU test firmware 的 JALR 目标地址。
4. `riscv_top` 增加 `INST_MEM_FILE` 参数，便于 Stage 3 使用 `cpu_test.hex`，Stage 4 使用 `soc_firmware.hex`。

### 6.6 验证结果

Stage 3 xsim 通过：

```text
RISC-V CORE TB PASS pc=000000e8 cycles=84
```

## 7. Stage 4：Full SoC 实现总结

### 7.1 实现目标

Stage 4 将 Stage 3 CPU 和 Stage 1 CNN accelerator 集成。CPU 通过 AXI4-Lite master 配置 CNN，外部 testbench 只负责 AXI-Stream 输入样本和收集 logits。

### 7.2 新增 AXI-Lite 地址解码器

新增 `rtl/axi_lite_addr_decode.v`。

功能：

- CPU AXI master input。
- CNN AXI slave output。
- 内部 TEST_OUTPUT capture。

地址表：

| 地址 | 行为 |
|---|---|
| `0x1000_0000 ~ 0x1000_001F` | 转发到 CNN registers |
| `0x1000_0020` | 内部 test output register |
| 其它 | SLVERR |

对 `0x1000_0020` 写：

- `test_value <= WDATA`
- `test_done <= 1`
- `BRESP = OKAY`

对 `0x1000_0020` 读：

- `RDATA = test_value`
- `RRESP = OKAY`

### 7.3 Full SoC 顶层

当前 `rtl/soc_top.v` 是 Stage 4 full SoC 顶层。

接口：

- 外部 AXI-Stream input/output。
- `test_done`
- `test_value`
- `cpu_halted`
- `dbg_pc`
- `dbg_cnn_busy`
- `dbg_cnn_done`
- `dbg_cnn_error`

内部连接：

```text
riscv_top AXI master
    -> axi_lite_addr_decode
        -> cnn_accelerator_top AXI-Lite slave
        -> internal TEST_OUTPUT register
```

### 7.4 SoC firmware

新增：

- `firmware/soc_firmware.S`
- `firmware/soc_firmware.hex`

固件流程：

1. 设置 `CNN_BASE = 0x1000_0000`。
2. 写 `INPUT_LEN = 2048`。
3. 写 `LAYER_CFG = 5`。
4. 写 `NUM_CLASSES = 10`。
5. 写 `CTRL.start = 1`。
6. 轮询 `STATUS.done`。
7. 读取 `CYCLE_CNT`。
8. 写 `TEST_OUTPUT = 0xA5A5_0001`。
9. 进入固定 halt loop。

当前固件使用紧凑风格：x2 作为工作寄存器在 back-to-back MMIO store 之间直接复用，无 NOP 间隔。这是 `inst_rom` 加 `ce=!stall_f` 修复后的正确行为。

### 7.5 Full SoC testbench

新增 `tb/tb_soc.sv`。

验证流程：

1. reset。
2. 等待 CNN `s_axis_tready`。
3. 发送 2048 输入样本。
4. 收集 10 个 logits。
5. 检查 logits 与 golden 匹配。
6. 等待 `test_done`。
7. 检查 `test_value == 32'hA5A5_0001`。
8. 检查 `dbg_cnn_error == 0`。
9. 检查 `dbg_cnn_done == 1`。
10. 超时失败。

### 7.6 Stage 4 验证结果

Full SoC xsim 通过：

```text
FULL SOC TB PASS pc=00000048 cycles=242346 test_value=a5a50001
```

这表示：

- CPU 从 PC=0 启动。
- CPU 通过 AXI4-Lite 配置 CNN。
- CNN 接收 AXI-Stream 输入。
- CNN 输出 logits。
- logits 与 golden 匹配。
- CNN done 置位。
- CPU polling 到 done。
- CPU 写 TEST_OUTPUT magic。
- testbench 观察到 `test_done` 和正确 `test_value`。

## 8. 调试过程中解决的主要问题

### 8.1 Vivado Verilog 表达式兼容性

Vivado 2021.2 对部分函数返回值 bit-select 和表达式切片不兼容。

处理方式：

- 避免 `function(...)[bit]` 形式。
- 避免 `(expr)[range]` 形式。
- 改为直接赋给目标窄位宽信号或使用临时变量。

### 8.2 AXI4-Lite BFM race

早期 testbench AXI read/write BFM 会错过同周期 `ARREADY/RVALID` 或 `AWREADY/WREADY`。

处理方式：

- AXI BFM 在 posedge 后 `#1` 采样 ready/valid。
- read BFM 同一循环同时检查 `ARREADY` 和 `RVALID`。

### 8.3 AXI-Stream handshake race

AXI-Stream input/output 如果在 `#1` 后采样，可能看到 DUT 下一拍状态导致误判。

处理方式：

- Stream input 和 output collector 在真实 posedge 采样 handshake。

### 8.4 同步 ROM/BRAM 读延迟

多个 engine 最初未考虑同步 ROM/BRAM 一拍延迟，导致 all-zero logits 或错位数据。

处理方式：

- 给 BN/weight/input/feature-buffer 读访问补 wait state。
- 在 requant 输出后补寄存器锁存。

### 8.5 Feature buffer bank/lane 对齐

feature buffer 多 lane 读时，bank data 与 lane mapping 未打一拍对齐。

处理方式：

- 增加 `rd_bank_valid_r` 和 `rd_bank_lane_flat_r`，让返回数据与 lane 选择同步。

### 8.6 Top mux 丢最后一拍写

engine 最后一拍写出时，`busy` 同时拉低，top-level mux 可能不再选择该 engine，导致 write pulse 丢失。

处理方式：

- mux 条件从只看 `*_busy` 改为 `*_busy || |*_feat_wr_en`。

### 8.7 FinalConv GAP 数据错位

final conv 在等待 weight ROM 时清零了 GAP 地址，导致使用错误 GAP 数据。

处理方式：

- 增加 `gap_data_reg` 保存 GAP 返回数据，再与 weight 数据一起参与累加。

### 8.8 CPU load-use stall 下指令丢失

同步 instruction ROM 在 load-use stall 时仍返回下一条指令，但 IF/ID 因 stall 未接收，导致后一条指令丢失。

处理方式：

- 增加 IF skid buffer 保存 stall 期间返回的 instruction。

### 8.9 CPU 分支读旧寄存器值

ID 阶段分支比较可能读到 WB 尚未写入 regfile 的旧值。

处理方式：

- 增加 WB -> ID bypass。

### 8.10 Stage 4 固件连续 MMIO store hazard

紧凑 firmware 重复使用一个寄存器连续写多个 MMIO 地址时，`inst_rom` 在 `pipeline_hold` 期间继续无条件采样，导致 stall 解除后 PC 与指令错位一个 word，造成 store data/address 损坏（详见 §9.3）。

最终修复（2026-05-12）：

- `inst_rom.v` 增加 `ce` 输入，`riscv_top.v` 连接 `ce=!stall_f`。
- `soc_firmware.S` 改为紧凑风格（x2 复用，无 NOP），验证通过。

## 9. 当前未关闭问题

### 9.1 `feature_buffer` BRAM inference gap

状态：已解决（2026-05-12）。

修复：`feature_buffer_bank_ram` 改用两个 `xpm_memory_sdpram`（ping-pong 两半各一个），强制 `MEMORY_PRIMITIVE="block"`，1 拍读延迟与原行为一致。

综合/仿真结果（2026-05-12）：

- OOC synth（xcku040-ffva1156-2-i）：80 RAMB36E2（13.33%），0 LUT as Distributed RAM（之前 0 BRAM / 46080 LUTRAM）。
- `tb/tb_cnn_accelerator.sv`：TB PASS，全部 checked `cycle_cnt` 与修复前 bit-identical。
- `tb/tb_soc.sv`：FULL SOC TB PASS `cycles=242348 test_value=a5a50001`。
- xsim 命令必须加 `-L xpm` 给 `xelab` 以链接 XPM 库。

### 9.2 `<1ms` latency target 未满足

状态：未解决，已延期。

当前测量：

```text
2048 case cycle_cnt = 240236
16384 smoke cycle_cnt = 1918556
```

在 100 MHz 下：

- 2048 case 约 2.40 ms。
- `<1ms` 目标要求 B+C 阶段小于 100000 cycles。

原因：

- 当前实现优先功能正确。
- 为同步 BRAM/ROM 和 pipeline valid 对齐加入了较多保守 wait state。
- channel/class 并行度和访问调度还没有进行性能收敛。

候选优化方向：

1. 将地址生成和数据消费改为流水化，而不是插入空等周期。
2. 提高 channel/class 并行度利用率。
3. 先解决 feature buffer BRAM/XPM banking，再基于真实 BRAM port/width 做调度优化。
4. 对 compute-heavy engine 做综合资源和 Fmax 分析。

建议优先级：高，但应在 BRAM 资源结构稳定后进行。

### 9.3 CPU 紧凑 MMIO store hazard —— 实为 inst_rom / IF 对齐问题

状态：已修复（2026-05-12）。

修复内容：
- `rtl/cpu/inst_rom.v`：增加 `ce` 输入，stall 期间不采样 ROM。
- `rtl/cpu/riscv_top.v`：`inst_rom` 实例化时 `ce` 连接 `!stall_f`。
- `firmware/soc_firmware.S`：移除 NOP 间隔和多寄存器预载，现在紧凑重用 x2 进行 back-to-back MMIO store。
- `firmware/soc_firmware.hex`：重新生成。
- `tb/tb_riscv_stress.sv`：新增专用回归 testbench，支持可配置 B_DELAY 和 golden write 对比。
- `firmware/cpu_stress_mmio.{S,hex}`：新增独立 CPU back-to-back store 测试固件。

验证结果（2026-05-12）：
- `tb_riscv_core` (cpu_test.hex)：`RISC-V CORE TB PASS pc=000000e8 cycles=84`
- `tb_riscv_stress` (cpu_stress_mmio.hex, B_DELAY=3)：`RISC-V STRESS TB PASS` — 5 个 back-to-back MMIO write 全部匹配 golden
- `tb_soc` (新 soc_firmware.hex, 无 NOP, x2 复用)：`FULL SOC TB PASS pc=00000048 cycles=242346 test_value=a5a50001`

保留：
- `firmware/soc_firmware_stress.{S,hex}` 作为回归样例。

## 10. 建议的下一步工作顺序

建议后续按以下顺序推进（`feature_buffer` BRAM 和 CPU MMIO hazard 已关闭）：

1. 做 Stage 1/4 综合资源和时序检查。
2. 做 CNN 性能优化，将 2048 case 从 `240236` cycles 降到 `<100000` cycles（§9.2）。
3. 对 full SoC 运行更多场景：
   - 输入 valid gaps。
   - 输出 backpressure。
   - CPU polling 更长等待。
   - CNN error path。
4. 如果需要保留 Stage 2 shell 回归，应将 Stage 2 shell 顶层另存为独立模块，例如 `soc_shell_top.v`，避免和 Stage 4 `soc_top.v` 接口冲突。

## 11. 当前可复用验证命令

### 11.1 Stage 3 RISC-V CPU

```bash
"D:/2021.2/Vivado/2021.2/bin/xvlog.bat" -sv \
  rtl/cpu/regfile.v rtl/cpu/alu.v rtl/cpu/imm_gen.v rtl/cpu/ctrl_unit.v \
  rtl/cpu/hazard_unit.v rtl/cpu/branch_unit.v rtl/cpu/axi_lite_master.v \
  rtl/cpu/inst_rom.v rtl/cpu/data_ram.v rtl/cpu/riscv_top.v tb/tb_riscv_core.sv && \
"D:/2021.2/Vivado/2021.2/bin/xelab.bat" tb_riscv_core -s tb_riscv_core_sim && \
"D:/2021.2/Vivado/2021.2/bin/xsim.bat" tb_riscv_core_sim -runall
```

期望结果：

```text
RISC-V CORE TB PASS pc=000000e8 cycles=84
```

### 11.2 Stage 4 Full SoC

```bash
"D:/2021.2/Vivado/2021.2/bin/xvlog.bat" -sv \
  rtl/reset_sync.v \
  rtl/cpu/regfile.v rtl/cpu/alu.v rtl/cpu/imm_gen.v rtl/cpu/ctrl_unit.v \
  rtl/cpu/hazard_unit.v rtl/cpu/branch_unit.v rtl/cpu/axi_lite_master.v \
  rtl/cpu/inst_rom.v rtl/cpu/data_ram.v rtl/cpu/riscv_top.v \
  rtl/axi_lite_addr_decode.v \
  rtl/saturate_int8.v rtl/requant_relu.v rtl/fake_weight_rom.v rtl/fake_bn_rom.v \
  rtl/input_buffer.v rtl/feature_buffer.v rtl/axi_lite_slave_regs.v \
  rtl/initial_conv_engine.v rtl/depthwise_conv_engine.v rtl/pointwise_conv_engine.v \
  rtl/maxpool_unit.v rtl/gap_unit.v rtl/final_conv_engine.v \
  rtl/cnn_accelerator_top.v rtl/soc_top.v tb/tb_soc.sv && \
"D:/2021.2/Vivado/2021.2/bin/xelab.bat" -L xpm tb_soc -s tb_soc_sim && \
"D:/2021.2/Vivado/2021.2/bin/xsim.bat" tb_soc_sim -runall
```

期望结果：

```text
FULL SOC TB PASS pc=00000048 cycles=242346 test_value=a5a50001
```

注意：因 `rtl/feature_buffer.v` 使用 `xpm_memory_sdpram`，`xelab` 必须带 `-L xpm` 才能链接 XPM 库。

### 11.3 Stage 1 CNN accelerator

```bash
"D:/2021.2/Vivado/2021.2/bin/xvlog.bat" -sv \
  rtl/reset_sync.v \
  rtl/saturate_int8.v rtl/requant_relu.v rtl/fake_weight_rom.v rtl/fake_bn_rom.v \
  rtl/input_buffer.v rtl/feature_buffer.v rtl/axi_lite_slave_regs.v \
  rtl/initial_conv_engine.v rtl/depthwise_conv_engine.v rtl/pointwise_conv_engine.v \
  rtl/maxpool_unit.v rtl/gap_unit.v rtl/final_conv_engine.v \
  rtl/cnn_accelerator_top.v tb/tb_cnn_accelerator.sv && \
"D:/2021.2/Vivado/2021.2/bin/xelab.bat" -L xpm tb_cnn_accelerator -s tb_cnn_accelerator_sim && \
"D:/2021.2/Vivado/2021.2/bin/xsim.bat" tb_cnn_accelerator_sim -runall
```

期望结果（关键行）：

```text
basic cycle_cnt=240236
max_len_smoke cycle_cnt=1918556
TB PASS
```

### 11.4 feature_buffer OOC 综合

```bash
"D:/2021.2/Vivado/2021.2/bin/vivado.bat" -mode batch -nojournal -nolog -source scripts/synth_feature_buffer.tcl
```

期望结果（关键行，见 reports/feature_buffer_util.rpt）：

```text
RAMB36E2 = 80
LUT as Distributed RAM = 0
```

## 12. 结论

本轮工作已经完成从 CNN accelerator 到 CPU-controlled full SoC 的功能闭环。当前工程可以完成以下端到端流程：

```text
CPU reset -> firmware executes -> CPU configures CNN through AXI4-Lite ->
CNN waits for AXI-Stream input -> testbench sends 2048 samples ->
CNN computes logits -> CPU polls STATUS.done -> CPU writes TEST_OUTPUT ->
testbench checks logits and magic -> PASS
```

目前最重要的后续工作是 CNN 性能优化：

1. 将 CNN 2048 case 延迟从 `240236` cycles 优化到 `<100000` cycles（§9.2），达成 `<1ms` 目标。BRAM 和 CPU 基础设施问题已全部关闭，可直接基于真实 BRAM port/width 做调度和流式化优化。
