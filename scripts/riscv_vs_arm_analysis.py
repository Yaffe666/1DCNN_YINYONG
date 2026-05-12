"""
RISC-V vs ARM vs RISC-V+Custom ISA 推理周期数对比实验
纯计算，基于 DSCNN 逐层 MAC 数 × 各架构每 MAC 所需周期
"""
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker

# ── 风格 ──
plt.rcParams.update({
    "font.family": "serif", "font.serif": ["Times New Roman", "Times"],
    "font.size": 13, "axes.titlesize": 15, "axes.labelsize": 14,
    "xtick.labelsize": 11, "ytick.labelsize": 11, "legend.fontsize": 11,
    "axes.labelweight": "bold", "axes.titleweight": "bold",
    "savefig.dpi": 600, "savefig.bbox": "tight",
})

# ── 你的 DSCNN 逐层 MAC（来自之前手动计算结果）──
LAYER_NAMES = [
    "FFT\n(pre)", "Initial\nConv",
    "DSC\nBlock 0", "DSC\nBlock 1", "DSC\nBlock 2",
    "DSC\nBlock 3", "DSC\nBlock 4", "Classifier"
]
LAYER_MACS = np.array([49200, 196608, 95232, 168960, 205824, 151680, 90976, 720])
LAYER_PARAMS = np.array([0, 768, 384, 1344, 3264, 4800, 5760, 730])

# ── 每 MAC 等效周期数（含 load/store/add 等 ──
# 来源：CMSIS-NN paper / RISC-V spec / 典型 DSP MAC 单元
# ARM Cortex-M4 (CMSIS-NN, 16-bit SIMD): ~0.35 cycles/MAC
# RISC-V RV32IMC (软件乘法):          ~2.5  cycles/MAC
# RISC-V + custom MAC instruction:     ~0.25 cycles/MAC
CYCLES_PER_MAC = {
    "ARM Cortex-M4\n(CMSIS-NN)":          0.35,
    "RISC-V RV32IMC\n(software mul)":      2.50,
    "RISC-V + Custom\nMAC instruction":    0.25,
}

CLOCK_MHZ = 200  # 典型 MCU 主频

# ── 每层参数内存占用 ──
# FP32 = 4B, INT8 = 1B
MEM_FP32_BYTES = LAYER_PARAMS * 4
MEM_INT8_BYTES = LAYER_PARAMS * 1

# ── 柱状图：逐层延迟 ──
fig, axes = plt.subplots(1, 2, figsize=(18, 7))

# (a) 逐层推理延迟 (μs)
x = np.arange(len(LAYER_NAMES))
width = 0.25
colors = ["#F5C6A0", "#A0C0E0", "#A0E0C0"]
edge_c = ["#C0392B", "#2471A3", "#27AE60"]
line_styles = ["solid", "dashed", "dotted"]

ax = axes[0]
for j, (name, cpm) in enumerate(CYCLES_PER_MAC.items()):
    cycles = LAYER_MACS * cpm
    latency_us = cycles / CLOCK_MHZ
    bars = ax.bar(x + (j - 1) * width, latency_us, width,
                  color=colors[j], edgecolor=edge_c[j], linewidth=1.0,
                  zorder=3, label=name)
    for bar, val in zip(bars, latency_us):
        if val > 0.5:
            ax.text(bar.get_x() + bar.get_width() / 2., bar.get_height() + 2,
                    f'{val:.0f}', ha='center', va='bottom', fontsize=7,
                    fontweight='bold', color=edge_c[j])

ax.set_xticks(x)
ax.set_xticklabels(LAYER_NAMES, fontsize=9)
ax.set_ylabel("Latency  (μs)", weight="bold", fontsize=14)
ax.set_title(f"Per-layer Inference Latency @ {CLOCK_MHZ} MHz", fontsize=15, weight="bold")
ax.legend(loc="upper left", framealpha=0.93, fontsize=9,
          edgecolor="#444", borderpad=0.4).get_frame().set_linewidth(0.8)
ax.grid(axis="y", linestyle="--", alpha=0.3, color="#CCC", zorder=0)
ax.set_axisbelow(True)
for spine in ax.spines.values():
    spine.set_linewidth(1.2)

# (b) 总延迟 + 能耗估算
ax2 = axes[1]
total_cycles = {k: sum(LAYER_MACS * v) for k, v in CYCLES_PER_MAC.items()}
total_latency = {k: v / CLOCK_MHZ for k, v in total_cycles.items()}

# 能耗粗略估算: pJ/MAC × total_MACs
# ARM M4 ~10 pJ/MAC, RISC-V ~8 pJ/MAC (软件), RISC-V+custom ~5 pJ/MAC
PJ_PER_MAC = {"ARM Cortex-M4\n(CMSIS-NN)": 10, "RISC-V RV32IMC\n(software mul)": 8,
              "RISC-V + Custom\nMAC instruction": 5}
energy = {k: sum(LAYER_MACS) * v / 1e6 for k, v in PJ_PER_MAC.items()}  # nJ

labels_bar = list(CYCLES_PER_MAC.keys())
xb2 = np.arange(len(labels_bar))

for idx, (metric, unit, title) in enumerate([
    (total_latency, "μs", "Total Inference Latency"),
    (energy, "nJ", "Estimated Energy per Inference"),
]):
    offset = idx * 1.25
    val_list = [metric[k] for k in labels_bar]
    bars2 = ax2.bar(xb2 + offset * width, val_list, width,
                    color=colors, edgecolor=edge_c, linewidth=1.0, zorder=3)
    for bar, val in zip(bars2, val_list):
        ax2.text(bar.get_x() + bar.get_width() / 2., bar.get_height() + max(val_list) * 0.02,
                 f'{val:.1f}', ha='center', va='bottom', fontsize=9,
                 fontweight='bold', color="#444")

ax2.set_xticks(xb2 + 0.625 * width)
ax2.set_xticklabels([l.replace("\n", " ") for l in labels_bar], fontsize=9, rotation=15)
ax2.set_ylabel("Latency (μs) / Energy (nJ)", weight="bold", fontsize=14)
ax2.set_title("End-to-End Comparison", fontsize=15, weight="bold")
ax2.legend([plt.Rectangle((0, 0), 1, 1, color=c, edgecolor=ec)
            for c, ec in zip(colors, edge_c)],
           ["Latency (μs)", "Energy (nJ)"],
           loc="upper right", framealpha=0.93, fontsize=9).get_frame().set_linewidth(0.8)
ax2.grid(axis="y", linestyle="--", alpha=0.3, color="#CCC", zorder=0)
ax2.set_axisbelow(True)
for spine in ax2.spines.values():
    spine.set_linewidth(1.2)

fig.suptitle("RISC-V Custom ISA vs ARM CMSIS-NN — Inference Efficiency",
             fontsize=16, weight="bold", y=1.01)
plt.tight_layout()
plt.savefig("riscv_vs_arm_comparison.jpg")
plt.close()

# ── Console summary ──
print("=" * 70)
print(f"Total MACs : {sum(LAYER_MACS):,}  ({sum(LAYER_MACS)/1e6:.2f} M)")
print(f"Clock      : {CLOCK_MHZ} MHz")
print(f"Params     : {sum(LAYER_PARAMS):,}  (FP32={sum(MEM_FP32_BYTES):,} B  INT8={sum(MEM_INT8_BYTES):,} B)")
print("-" * 70)
for name, cpm in CYCLES_PER_MAC.items():
    cyc = total_cycles[name]
    lat = total_latency[name]
    en = energy[name]
    fps = 1e6 / lat if lat > 0 else float("inf")
    print(f"{name:<30s}  cycles={cyc:>10,.0f}  lat={lat:>8.1f} μs  "
          f"energy={en:>6.2f} nJ  FPS={fps:>8.0f}")
print("-" * 70)
arm_lat = total_latency[list(CYCLES_PER_MAC.keys())[0]]
rv_lat = total_latency[list(CYCLES_PER_MAC.keys())[1]]
rvcu_lat = total_latency[list(CYCLES_PER_MAC.keys())[2]]
print(f"RISC-V custom vs ARM    : {arm_lat/rvcu_lat:.1f}× speedup")
print(f"RISC-V custom vs RISC-V : {rv_lat/rvcu_lat:.1f}× speedup")
print(f"RISC-V software vs ARM  : {arm_lat/rv_lat:.2f}× (slower — needs custom ISA)")
print("=" * 70)
print("Chart saved → riscv_vs_arm_comparison.jpg")
