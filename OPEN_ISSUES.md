# Open Implementation Issues

This file records implementation/synthesis issues that are discovered during staged bring-up but deferred for later resolution.

## 2026-05-11 — Stage 1 Batch 2 — `feature_buffer` BRAM inference gap

- Status: Resolved on 2026-05-12.
- Affected file: `rtl/feature_buffer.v`
- Spec impact:
  - `agent_prompt.v5.md:A8` requires feature storage to prefer Xilinx Block RAM.
  - `agent_prompt.v5.md:B9` requires `feature_buffer` to use BRAM banking rather than theoretical multi-port RAM.
- Original result:
  - `xvlog` passed but Vivado mapped the per-bank ping-pong memories to distributed RAM/LUTRAM.
  - Synthesis utilization: 0 BRAM, 46080 LUT as Distributed RAM.
  - Warning pattern: `Synth 8-6849 Infeasible attribute ram_style = "block" ... trying to implement using LUTRAM`.
- Resolution:
  - `feature_buffer_bank_ram` now instantiates two `xpm_memory_sdpram` macros per bank (one per ping-pong half), explicitly forcing `MEMORY_PRIMITIVE="block"` and `READ_LATENCY_B=1`.
  - External timing of `feature_buffer` (1-cycle read latency, write/read ping-pong semantics, lane-mux behavior) unchanged — outer lane selection still masks invalid banks via `rd_bank_valid_r`.
- Post-fix verification on 2026-05-12:
  - OOC synthesis of `feature_buffer` on `xcku040-ffva1156-2-i`: 80 RAMB36E2 (13.33% of 600), 0 LUT as Distributed RAM.
  - `tb/tb_cnn_accelerator.sv`: TB PASS, all checked `cycle_cnt` values bit-identical to pre-fix run (`basic/repeat/input_valid_gaps/output_backpressure/post_error_clean`=240236, `max_len_smoke`=1918556).
  - `tb/tb_soc.sv`: FULL SOC TB PASS `pc=0000008c cycles=242348 test_value=a5a50001`.
- Downstream impact:
  - Unblocks feature-buffer resource/port estimates for the CNN latency-optimization pass.
  - xsim now requires `-L xpm` on `xelab` to link the XPM library.

## 2026-05-11 — Stage 1 Batch 7 — Top-level functional alignment requires TB validation

- Status: Resolved for the covered Stage 1 Batch 8 tests.
- Affected files:
  - `rtl/cnn_accelerator_top.v`
  - `rtl/*_engine.v`
- Current result:
  - Full Stage 1 RTL passes `xvlog`.
  - `cnn_accelerator_top` passes `xelab` elaboration.
- Functional risk:
  - The top-level schedule, ROM mux timing, BRAM read latency alignment, and requant pipeline handoff have only been syntax/elaboration checked so far.
  - Bit-exact alignment against `mem/golden_logits.mem` still requires the Stage 1 testbench.
- Why this matters:
  - Engine interfaces are sequentially connected through muxed ROM/buffer ports; one-cycle read latencies and pipeline valid timing must be proven by simulation, not just compilation.
- Recommended next revisit point:
  - Validate and fix during Batch 8 with `tb/tb_cnn_accelerator.sv` using the generated 2048-vector golden data.
- Resolution update:
  - Stage 1 Batch 8 xsim now passes the 2048-vector repeated-inference, input-valid-gap, output-backpressure, TLAST error, invalid-config error, post-error clean-run, and 16384-length smoke tests.
  - The 2048-vector checked cases are bit-exact against `mem/golden_logits.mem`.

## 2026-05-11 — Stage 1 Batch 8 — latency target not yet met

- Status: Open; this is now the only known unclosed architectural issue after the BRAM and CPU MMIO fixes.
- Affected files:
  - `rtl/initial_conv_engine.v`
  - `rtl/depthwise_conv_engine.v`
  - `rtl/pointwise_conv_engine.v`
  - `rtl/maxpool_unit.v`
  - `rtl/gap_unit.v`
  - `rtl/final_conv_engine.v`
  - `rtl/cnn_accelerator_top.v`
  - `rtl/fake_weight_rom.v` / `rtl/fake_bn_rom.v` if memory banking/porting is changed.
- Spec impact:
  - `agent_prompt.v5.md` targets `<1ms` inference for B+C+D; Stage 1 accelerator-only B+C should be below 100,000 cycles at 100 MHz.
  - `agent_prompt.v5.md:A9` estimates the intended raw compute budget at about 67,094 cycles for the default 2048 case with `PAR_CH=8`, `PAR_OC=8`, `PAR_IC=4`, `PAR_CLASS=8`.
- Current result:
  - `tb/tb_cnn_accelerator.sv` passes functionally.
  - 2048-sample checked cases report `cycle_cnt=240236`, about 2.40 ms at 100 MHz.
  - 16384-sample smoke reports `cycle_cnt=1918556`.
  - Full SoC after CPU MMIO fix reports about `cycles=242346`, so CPU config/polling overhead is small relative to CNN compute; the bottleneck is the CNN engine schedule.
- Current root cause assessment:
  - The current engine RTL is function-first and uses a conservative three-state memory access pattern for most inner loops: `REQ -> WAIT -> ACC`.
  - InitialConv and Depthwise spend roughly 3 cycles per kernel tap instead of the A9 budget assumption of about 1 useful tap/group per cycle.
  - Pointwise spends roughly 3 cycles per `PAR_IC` group (`S_IC_REQ -> S_IC_WAIT -> S_IC_ACC`) instead of one useful input-channel group per cycle.
  - Requant is pipelined internally, but each engine currently launches one output group, waits for the 4-stage requant pipe to drain, then writes, instead of overlapping requant/writeback for position N with address/MAC work for position N+1.
  - BN/zero-point loads are functionally correct but not always amortized optimally; they should be treated as per-channel/per-output-channel context and hidden behind compute wherever possible.
  - `feature_buffer` is now real BRAM/XPM (80 RAMB36E2, 0 LUTRAM), so the remaining latency issue should be solved by scheduling/pipelining first, not by accepting unrealistic multi-port RAM.

### Recommended optimization strategy

1. **First add profiling, not blind rewrites.**
   - Add temporary or permanent debug counters for per-engine cycles: InitialConv, each DW/PW/MP block, GAP, FC, output.
   - Record expected-vs-actual per layer against the A9 budget. This will identify whether the dominant excess is InitialConv, Pointwise, or repeated requant/write overhead.
   - Keep the existing top-level `cycle_cnt` as the end-to-end acceptance metric.

2. **Primary fix: convert inner loops from request/wait/accumulate FSMs into streaming pipelines.**
   - For InitialConv: issue one input/weight address per cycle for each tap; register the tap metadata (`valid`, `padding`, `curr_k`, `curr_pos`, `oc_base`) and consume returned input/weight data one cycle later.
   - For Depthwise: same idea for `PAR_CH` lanes; address generation advances every cycle, returned BRAM/ROM data is consumed through a valid-aligned tap pipeline.
   - For Pointwise: issue `PAR_IC` feature reads and `PAR_OC*PAR_IC` weight reads every cycle; consume the previous cycle's returned feature/weight group through a small adder tree and accumulate into `acc_reg[PAR_OC]`.
   - This should reduce the dominant loop cost from about 3 cycles per tap/group to about 1 cycle per tap/group plus a small fill/drain penalty.
   - This change alone should move the design much closer to the A9 raw budget (~67k cycles) while preserving the current parallelism.

3. **Overlap requant/writeback with the next output position or channel group.**
   - Current engines use `S_RQ_START -> S_RQ_WAIT -> S_WRITE_OUT`, which inserts a 4+ cycle bubble per output group.
   - Instead, treat `requant_relu` as a streaming output pipe: when an accumulator completes, push `(addr, buf_sel, lane_mask, acc, params)` into a small metadata shift register matching `PIPE_STAGES`.
   - While requant output for position N is in flight, the MAC pipeline should already start position N+1 or the next channel/output group.
   - Writeback occurs when the delayed metadata and `rq_out_valid` return together.
   - This is especially important for Pointwise and InitialConv because their output group count is large.

4. **Keep the first performance pass at the existing parallelism before increasing `PAR_*`.**
   - The spec's default parallelism is already sufficient on paper: A9 estimates ~67k raw cycles, comfortably below 100k at 100 MHz if scheduling overhead is controlled.
   - Increasing `PAR_CH/PAR_OC/PAR_IC` before removing 3-cycle wait-state loops risks spending BRAM/DSP/LUT routing resources without fixing the main inefficiency.
   - Only consider `PAR_IC=8` or `PAR_K=2/4` after the pipelined schedule is measured and still misses target.

5. **Second-pass parallelism if needed.**
   - If the pipelined schedule lands above ~100k cycles but below ~150k, first attempt timing closure at 150 MHz, because the spec lists 150 MHz as the expected optimized target.
   - If 100 MHz <100k remains mandatory, the most targeted parallelism changes are:
     1. InitialConv: add `PAR_K=2` or `PAR_K=4` for kernel taps, because InitialConv has 64 taps and is a large fixed cost.
     2. Pointwise: raise `PAR_IC` from 4 to 8, because Pointwise total work is substantial and maps naturally to more feature/weight lanes.
     3. Only then consider `PAR_CH=16` or `PAR_OC=16`, because that requires revisiting feature-buffer bank count/width and ROM banking.

6. **Memory/BRAM constraints for any performance rewrite.**
   - Do not create theoretical multi-read RAMs. All added bandwidth must be matched by banked/replicated BRAM or by deterministic multi-cycle scheduling.
   - Feature buffer currently has 8 channel banks; `PAR_CH=8` and current `PAR_IC=4` are safe if lane-to-bank scheduling remains conflict-free.
   - `PAR_IC=8` consumes all 8 feature banks in Pointwise, so every cycle must read channels with distinct `channel % 8`; the existing channel-group pattern naturally does this for aligned groups but should still be asserted in TB.
   - Weight ROM may need explicit banking/replication if Vivado does not implement `PORTS=32` efficiently for Pointwise/FinalConv.

7. **Timing/Fmax work should follow, not precede, scheduling cleanup.**
   - The current `pointwise_conv_engine` uses a combinational sum over `PAR_IC` inside one always block. For `PAR_IC=4` this may close at 100 MHz, but for `PAR_IC=8` it should become a registered adder tree.
   - DSP multiply, adder tree, accumulator update, and requant should stay pipelined per A8.
   - GAP's synthesizable division is not the main cycle bottleneck for 2048 (GAP length is only 8 after DSC4), but it may become a timing/resource issue; replace with reciprocal multiply only if timing reports identify it.

8. **Acceptance criteria for closing this issue.**
   - Stage 1 `tb_cnn_accelerator.sv` still passes all functional cases and golden logits bit-exact.
   - 2048 checked cases report `cycle_cnt < 100000` at the current 100 MHz measurement convention, or a clearly documented Fmax-based pass if the project accepts 150 MHz/200 MHz target interpretation.
   - 16384 smoke still passes functionally; it does not need `<1ms` unless requirements change.
   - Full SoC `tb_soc.sv` passes and reports B+C+D cycles after CPU config/polling.
   - Vivado reports are captured for Stage 1 and Stage 4: BRAM, LUTRAM, DSP, LUT, FF, WNS/TNS at 100 MHz and preferably 150 MHz.

### Recommended implementation order when this issue is picked up

1. Add per-engine cycle counters/reporting to quantify the real cycle distribution.
2. Pipeline InitialConv tap loop (`REQ/WAIT/ACC` -> one-tap-per-cycle valid pipeline).
3. Pipeline Depthwise tap loop with the same valid-aligned pattern.
4. Pipeline Pointwise input-channel group loop; if `PAR_IC=4` still misses target, then evaluate `PAR_IC=8` with BRAM-bank assertions.
5. Convert requant/writeback to a streaming metadata-aligned path so compute for the next output overlaps requant for the previous output.
6. Re-run Stage 1 regression after each engine change; only then run Stage 4 and synthesis/timing.

- Recommended next revisit point:
  - Start with profiling and schedule pipelining, not with wider parallelism. The current 240236 cycles is roughly 3.6x the A9 raw budget, matching the visible 3-state memory-access FSM overhead; removing that overhead is the highest-leverage path to `<100000`.

## 2026-05-12 — Stage 4 — CPU consecutive MMIO store hazard

- Status: **Resolved on 2026-05-12.**

### Resolution

Applied the recommended `inst_rom` clock-enable fix:

- `rtl/cpu/inst_rom.v`: added `ce` input; `instr` only updates when `ce=1`.
- `rtl/cpu/riscv_top.v`: wired `ce` to `!stall_f` in the `inst_rom` instantiation.

Post-fix verification:

- `tb_riscv_core` (cpu_test.hex): `RISC-V CORE TB PASS pc=000000e8 cycles=84`
- `tb_riscv_stress` (cpu_stress_mmio.hex, B_DELAY=3): `RISC-V STRESS TB PASS` — all 5 back-to-back MMIO writes match golden (awaddr=0x00→0x04→0x08→0x0C→0x20, wdata=0x123→0x456→0x789→0x321→0xCAFEBABE)
- `tb_soc` (soc_firmware.hex with NOPs removed, x2 reused across stores): `FULL SOC TB PASS pc=00000048 cycles=242346 test_value=a5a50001`

Related cleanup applied:

- `firmware/soc_firmware.S`: removed NOP spacing and multi-register preload; back-to-back stores now reuse x2.
- `firmware/soc_firmware.hex`: regenerated.
- `firmware/soc_firmware_stress.{S,hex}`: retained as regression sample.
- `tb/tb_riscv_stress.sv`: new dedicated stress testbench with configurable B_DELAY and golden write comparison.
- `firmware/cpu_stress_mmio.{S,hex}`: new standalone CPU stress firmware with back-to-back stores.
