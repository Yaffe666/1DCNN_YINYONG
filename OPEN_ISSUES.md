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

- Status: Stage 1 2048 functional regression passes after the synthesis-safety rollback, but the `<100000` cycle latency target is not yet met; Vivado synthesis/timing follow-up is running.
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
  - ModelSim SE-64 2020.4 `tb/tb_cnn_accelerator.sv` 2048-only regression passes with `Errors=0, Warnings=0`.
  - Post-rollback 2048-sample checked cases report `cycle_cnt=108598`, about 1.086 ms at 100 MHz.
  - The temporary `PAR_CH=12`/`PAR_OC=12` configuration reached `cycle_cnt=64129` in ModelSim, but was rolled back because synthesis feasibility was not proven.
  - Max-length/16384 regression is now deferred by project scope; current optimization and regression focus is 2048 only.
  - Full SoC after the latency changes has not been re-run yet; previous pre-optimization SoC measurements are stale for performance reporting.
- Current post-rollback summary:
  - InitialConv and Depthwise tap loops now issue consecutive tap reads after a two-cycle fill, consuming one returned tap per cycle instead of returning to `REQ` for every tap.
  - Pointwise now streams consecutive input-channel groups after fill, and top-level `PAR_IC` is raised from 4 to 8.
  - `PAR_CH`/`PAR_OC`, BN ports, and feature-buffer banking are back at 8 lanes/banks for synthesis safety.
  - MaxPool now overlaps the second read request with saving the first sample and writes directly when the second sample returns.
  - `feature_buffer` remains XPM-backed with the default 8-bank BRAM structure.

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

8. **Acceptance criteria for fully closing this issue.**
   - Stage 1 `tb_cnn_accelerator.sv` passes all active 2048 functional cases and golden logits bit-exact. **Met post-rollback: `cycle_cnt=108598`.**
   - 2048 checked cases report `cycle_cnt < 100000` at the current 100 MHz measurement convention. **Not met post-rollback.**
   - 16384/max-length smoke remains deferred unless requirements change.
   - Full SoC `tb_soc.sv` passes and reports B+C+D cycles after CPU config/polling. **Pending re-run after latency changes.**
   - Vivado reports are captured for Stage 1 and Stage 4: BRAM, LUTRAM, DSP, LUT, FF, WNS/TNS at 100 MHz and preferably 150 MHz. **Pending; Stage 1 synthesis is running.**

### Recommended implementation order when this issue is picked up

1. Add per-engine cycle counters/reporting to quantify the real cycle distribution.
2. Pipeline InitialConv tap loop (`REQ/WAIT/ACC` -> one-tap-per-cycle valid pipeline).
3. Pipeline Depthwise tap loop with the same valid-aligned pattern.
4. Pipeline Pointwise input-channel group loop; if `PAR_IC=4` still misses target, then evaluate `PAR_IC=8` with BRAM-bank assertions.
5. Convert requant/writeback to a streaming metadata-aligned path so compute for the next output overlaps requant for the previous output.
6. Re-run Stage 1 regression after each engine change; only then run Stage 4 and synthesis/timing.

- Recommended next revisit point:
  - After synthesis completes, use the post-rollback `108598` cycle result as the baseline. The remaining gap to `<100000` is small enough that requant/writeback overlap or synthesis-safe ROM/feature scheduling should be attempted before reintroducing wider `PAR_CH`/`PAR_OC` banking.

---

## 2026-05-12 — Stage 1 Batch 9 — Pipelining optimization: attempt 1

- Status: **Open — functional regression, latency improved but not yet <100k.**
- Implementation date: 2026-05-12.

### Changes applied (all 6 compute engines)

Converted every engine inner loop from the original 3-cycle `REQ → WAIT → ACC` pattern into a streaming valid-aligned pipeline:

| Engine | Old inner loop | New pipeline | States added |
|--------|---------------|-------------|-------------|
| `initial_conv_engine.v` | S_TAP_REQ→WAIT→ACC (3cy/tap) | S_TAP_PIPE + 3×DRAIN | pipe_cnt, input_rd_d1/d2, weight_d1/d2, tap_valid_d1/d2/d3 |
| `depthwise_conv_engine.v` | S_TAP_REQ→WAIT→ACC (3cy/tap) | S_TAP_PIPE + 3×DRAIN | pipe_cnt, feat_rd_d1/d2, weight_d1/d2, tap_valid_d1/d2/d3 |
| `pointwise_conv_engine.v` | S_IC_REQ→WAIT→ACC (3cy/IC group) | S_IC_PIPE + 3×DRAIN | pipe_cnt, feat_rd_d1/d2, weight_d1/d2, ic_lane_valid_d1/d2/d3, oc_lane_valid_d1/d2/d3 |
| `final_conv_engine.v` | S_IC_REQ→WAIT→ACC (3cy/IC group) | S_IC_PIPE + 2×DRAIN | pipe_cnt, gap_d (1cy delay), ic_lane_valid_d1/d2, class_valid_d1/d2 |
| `maxpool_unit.v` | 7-state pair read (7cy/pos) | S_RD0→RD1→WRITE (3cy/pos) | (val1 removed) |
| `gap_unit.v` | S_RD→WAIT→ACC (3cy/pos) | S_RD_PIPE + 3×DRAIN + S_WRITE | pipe_cnt, feat_rd_d1/d2 |

### Key design challenge: BRAM/ROM data latency

The effective data latency from address issue to engine-visible data is **3 cycles** for BRAM-based feature reads and ROM-based weight reads, not 2 as originally assumed. Root cause:

1. **posedge N**: engine sets address (NBA at end of N). BRAM/ROM module reads address at posedge N+1 (module ordering: BRAM always block runs before engine always block).
2. **posedge N+1**: data arrives at BRAM/ROM output (NBA at end of N+1). Engine reads data at posedge N+2.
3. **posedge N+2**: engine sees valid data on wires. Captures into d1.
4. **posedge N+3**: data shifts d1→d2. Accumulation uses d2.

This 3-cycle pipeline depth means:
- Non-overlapped tap loops: `K + 3` cycles instead of `K + 1` (original estimate).
- Require **3 drain states** after the last issue to flush the pipeline.
- Data validity tracking must be shifted 3-deep (`_d1/_d2/_d3` or `_d1/_d2` depending on data source).

`final_conv_engine` has different timing: GAP data is combinational (from `gap_vec` register array, available same cycle as address) while weight data has 2-cycle ROM latency. Gap data goes through 1 register delay (`gap_d`) to align with weight data at posedge N+2, requiring only 2-deep validity tracking and 2 drain states.

### First simulation result (2026-05-12 run #1)

- `cycle_cnt=115434` — **2.08× improvement** over baseline (240236), expected ~2.5×.
- **TB FAIL** — 40 logit mismatches across all functional cases (`basic/repeat/input_valid_gaps/output_backpressure/post_error_clean`).

**Mismatch pattern** (all cases identical):
```
LOGIT mismatch idx=1 got=7f expected=80
LOGIT mismatch idx=2 got=80 expected=7f
LOGIT mismatch idx=3 got=80 expected=7f
LOGIT mismatch idx=4 got=0f expected=80
LOGIT mismatch idx=6 got=7f expected=80
LOGIT mismatch idx=7 got=80 expected=7f
LOGIT mismatch idx=8 got=80 expected=7f
LOGIT mismatch idx=9 got=0f expected=80
```
- Indices 0 and 5 pass; all others fail.
- Values appear shifted (7f/80 alternating) with some severe outliers (0f=15 where 80=128 expected).
- Error cases (`tlast_error/invalid_config`) still pass correctly.

### Root cause analysis

The initial implementation used `accum_pos = curr_pos + curr_k - 2` (2-cycle offset assumption). The correct offset is **3 cycles** (`curr_k - 3`). The `/2` vs `/3` discrepancy caused:

1. **Tap-level engines** (depthwise, initial_conv): Accumulated wrong kernel tap's data — d2 contained data from tap N-3, but accumulation formula used tap N-2's metadata.
2. **IC-group engines** (pointwise, final_conv): Channel validity check used `curr_ic_base` (current group) instead of the IC group from 3 cycles ago. Valid channels in current group ≠ valid channels in accumulated group.
3. **Drain states**: Only 2 drain states existed; need 3 to flush the 3-deep pipeline for BRAM-based engines.

### Fix applied (2026-05-12 run #2)

1. Changed tap/IC-group accumulation formula from `-2` to `-3` offset for BRAM-based engines.
2. Added 3rd drain state (`S_TAP_DRAIN3` / `S_IC_DRAIN3`) for depthwise, initial_conv, pointwise, gap.
3. Added per-lane validity tracking shift registers (`tap_valid_d1/d2/d3`, `ic_lane_valid_d1/d2/d3`, `oc_lane_valid_d1/d2/d3`) for all engines.
4. Final_conv uses 2-deep tracking (gap=combinational+1reg, weight=ROM+0reg).
5. Maxpool pipelining is correct as-is (uses 1-cycle BRAM read directly, no shift registers needed).

### Awaiting re-verification

- Need to re-run `xvlog → xelab → xsim tb_cnn -R` to check:
  1. TB PASS (no logit mismatches)
  2. `cycle_cnt` value (expected ~115-125k with 3-cycle pipeline vs 115k from buggy 2-cycle version)
  3. If still >100k, next step is requant/writeback overlap (save ~4-5 cycles per output group)

### Note on `final_conv_engine` timing

GAP data path: `gap_rd_addr_flat` (combinational through `gap_vec` array in `cnn_accelerator_top.v`) → available same cycle as address NBA → registered in `gap_d` (1 cycle) → available for accumulation 2 cycles after issue.

Weight data path: ROM address set → ROM reads at posedge+1 → output available at posedge+2 → read directly from wire. Both paths align at 2-cycle total latency.

---

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
