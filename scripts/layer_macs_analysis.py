"""
层级别 MAC 分析脚本
为 DSCNN 模型绘制学术风格逐层 MAC 分布柱状图
"""
import time
import torch
import torch.nn as nn
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import numpy as np
import warnings
# ---- 学术绘图参数 ----
plt.rcParams.update({
    "font.family": "serif",
    "font.size": 11,
    "axes.titlesize": 14,
    "axes.labelsize": 13,
    "xtick.labelsize": 9,
    "ytick.labelsize": 11,
    "legend.fontsize": 10,
    "figure.dpi": 150,
    "savefig.dpi": 600,
    "savefig.bbox": "tight",
})
# =========================================================
# FFT helper
# =========================================================
def fft_half_feature_torch(x, norm="forward", take="second_half"):
    x_fft = torch.abs(torch.fft.fft(x, dim=-1, norm=norm))
    if take == "second_half":
        _, x_fft = x_fft.chunk(2, dim=-1)
    elif take == "first_half":
        x_fft, _ = x_fft.chunk(2, dim=-1)
    elif take == "rfft":
        x_fft = torch.abs(torch.fft.rfft(x, dim=-1, norm=norm))
    else:
        raise ValueError(f"Unknown FFT take mode: {take}")
    return x_fft
# =========================================================
# MobileMQA1D
# =========================================================
class MobileMQA1D(nn.Module):
    def __init__(self, in_channels, num_heads=4):
        super().__init__()
        if in_channels % num_heads != 0:
            raise ValueError(f"in_channels must be divisible by num_heads")
        self.num_heads = num_heads
        self.head_dim = in_channels // num_heads
        self.scale = self.head_dim ** -0.5
        self.q_proj = nn.Linear(in_channels, in_channels)
        self.k_proj = nn.Linear(in_channels, in_channels)
        self.v_proj = nn.Linear(in_channels, in_channels)
        self.out_proj = nn.Linear(in_channels, in_channels)
    def forward(self, x):
        batch, channels, length = x.size()
        x_perm = x.permute(0, 2, 1)
        q = self.q_proj(x_perm).view(batch, length, self.num_heads, self.head_dim).transpose(1, 2)
        k = self.k_proj(x_perm).view(batch, length, self.num_heads, self.head_dim).transpose(1, 2)
        v = self.v_proj(x_perm).view(batch, length, self.num_heads, self.head_dim).transpose(1, 2)
        attn = (q @ k.transpose(-2, -1)) * self.scale
        attn = torch.softmax(attn, dim=-1)
        out = attn @ v
        out = out.transpose(1, 2).contiguous().view(batch, length, channels)
        out = self.out_proj(out)
        out = out.permute(0, 2, 1)
        return x + out
# =========================================================
# DSCBlock
# =========================================================
class DSCBlock(nn.Module):
    def __init__(self, in_channels, out_channels, kernel_size=7, padding=3, use_attention=False):
        super().__init__()
        self.depthwise = nn.Conv1d(in_channels, in_channels, kernel_size, padding=padding,
                                   groups=in_channels, bias=False)
        self.bn_depth = nn.BatchNorm1d(in_channels)
        self.relu1 = nn.ReLU(inplace=False)
        self.pointwise = nn.Conv1d(in_channels, out_channels, 1, bias=False)
        self.bn_point = nn.BatchNorm1d(out_channels)
        self.relu2 = nn.ReLU(inplace=False)
        self.use_attention = use_attention
        if use_attention:
            self.attention = MobileMQA1D(out_channels, num_heads=2)
        self.pool = nn.MaxPool1d(kernel_size=2, stride=2)
    def forward(self, x):
        x = self.depthwise(x)
        x = self.bn_depth(x)
        x = self.relu1(x)
        x = self.pointwise(x)
        x = self.bn_point(x)
        x = self.relu2(x)
        if self.use_attention:
            x = self.attention(x)
        x = self.pool(x)
        return x
# =========================================================
# DSCNN backbone
# =========================================================
class DSCNN(nn.Module):
    def __init__(self, num_classes=10, do_fft_in_model=True,
                 fft_norm="forward", fft_take="second_half",
                 attention_flags=None):
        super().__init__()
        if attention_flags is None:
            attention_flags = [False, False, False, False, False]
        self.do_fft_in_model = do_fft_in_model
        self.fft_norm = fft_norm
        self.fft_take = fft_take
        self.initial_conv = nn.Sequential(
            nn.Conv1d(1, 12, kernel_size=64, stride=8, padding=28, bias=False),
            nn.BatchNorm1d(12),
            nn.ReLU(inplace=False)
        )
        self.dsc_layers = nn.Sequential(
            DSCBlock(12, 24, use_attention=attention_flags[0]),
            DSCBlock(24, 48, use_attention=attention_flags[1]),
            DSCBlock(48, 60, use_attention=attention_flags[2]),
            DSCBlock(60, 72, use_attention=attention_flags[3]),
            DSCBlock(72, 72, use_attention=attention_flags[4]),
        )
        self.gap = nn.AdaptiveAvgPool1d(1)
        self.final_conv = nn.Conv1d(72, num_classes, kernel_size=1, bias=True)
    def forward(self, x, return_feat=False, already_fft=False):
        if self.do_fft_in_model and not already_fft:
            x = fft_half_feature_torch(x, norm=self.fft_norm, take=self.fft_take)
        x = self.initial_conv(x)
        x = self.dsc_layers(x)
        x = self.gap(x)
        feat = x.squeeze(-1)
        x = self.final_conv(x)
        logits = x.squeeze(-1)
        if return_feat:
            return logits, feat
        return logits
# =========================================================
# 整洁的逐层 MAC 计算
# =========================================================
def _block_index(name):
    """从完整模块名提取 DSC block 编号，非 DSC 返回 -1"""
    if name.startswith("dsc_layers."):
        parts = name.split(".")
        if len(parts) >= 2:
            try:
                return int(parts[1])
            except ValueError:
                return -1
    return -1


def _layer_category(name, module):
    """返回层类别用于着色"""
    t = type(module).__name__
    if name == "initial_conv.0":
        return "Initial Conv"
    if name == "final_conv":
        return "Classifier"
    if _block_index(name) >= 0:
        return "DSC Block"
    return "Other"


_CAT_COLORS = {
    "Initial Conv": "#2C3E50",
    "DSC Block":    "#3498DB",
    "Classifier":   "#E74C3C",
    "Other":        "#95A5A6",
}
def _manual_macs_conv1d(layer, in_shape):
    """Conv1d MACs: Cout * (Cin/groups) * kernel_size * Lout"""
    Cout = layer.out_channels
    Cin_per_g = layer.in_channels // layer.groups
    K = layer.kernel_size[0]
    S = layer.stride[0]
    P = layer.padding[0]
    D = layer.dilation[0]
    Lin = in_shape[-1]
    Lout = (Lin + 2 * P - D * (K - 1) - 1) // S + 1
    return Cout * Cin_per_g * K * Lout


def _manual_macs_linear(layer, in_shape):
    """Linear MACs: in_features * out_features (matmul)"""
    return layer.in_features * layer.out_features


def _manual_macs_rfft(in_shape):
    """RFFT MACs ~ N * log2(N) per real signal"""
    N = in_shape[-1]
    return N * np.log2(N)


def _manual_macs_fft(in_shape):
    """Full FFT (complex→complex) ~ N * log2(N)"""
    N = in_shape[-1]
    return N * np.log2(N)


def _manual_macs_maxpool1d(layer, in_shape):
    """MaxPool1d: 0 MACs (only comparisons)"""
    return 0


def _manual_macs_adaptive_avg_pool1d(layer, in_shape):
    """AdaptiveAvgPool1d: 0 MACs (only adds, no mult)"""
    return 0


def compute_layer_macs(model, input_tensor):
    """
    返回 (labels, macs, categories) 三个列表
    每个 DSC block (DW+PW+Attn) 聚合成一个整体
    """
    hooks = []
    layer_shapes = {}
    layer_names = {}

    def _fw_hook(name):
        def hook(m, inp, out):
            if isinstance(m, (nn.Conv1d, nn.Linear, nn.MaxPool1d, nn.AdaptiveAvgPool1d)):
                layer_shapes[m] = inp[0].shape
                layer_names[m] = name
        return hook

    for n, m in model.named_modules():
        if not isinstance(m, nn.Sequential) and not isinstance(m, nn.ModuleList):
            hooks.append(m.register_forward_hook(_fw_hook(n)))

    _ = model(input_tensor)

    for h in hooks:
        h.remove()

    # 按聚合 key 累加 MAC
    from collections import defaultdict
    agg_macs = defaultdict(int)
    agg_cats = {}

    for name, mod in model.named_modules():
        blk_idx = _block_index(name)

        if isinstance(mod, nn.Conv1d):
            if mod not in layer_shapes:
                continue
            in_shape = layer_shapes[mod]
            mac = _manual_macs_conv1d(mod, in_shape)
            if mac <= 0:
                continue
            if blk_idx >= 0:
                key = f"DSC [{blk_idx}]"
                agg_macs[key] += mac
                agg_cats[key] = "DSC Block"
            elif name == "initial_conv.0":
                agg_macs["Initial Conv"] += mac
                agg_cats["Initial Conv"] = "Initial Conv"
            elif name == "final_conv":
                agg_macs["Classifier"] += mac
                agg_cats["Classifier"] = "Classifier"
            else:
                agg_macs[name] += mac
                agg_cats[name] = "Other"

        elif isinstance(mod, nn.Linear):
            if mod not in layer_shapes:
                continue
            mac = _manual_macs_linear(mod, mod.weight.shape)
            if mac <= 0:
                continue
            if blk_idx >= 0:
                key = f"DSC [{blk_idx}]"
                agg_macs[key] += mac
                agg_cats[key] = "DSC Block"
            else:
                agg_macs[name] += mac
                agg_cats[name] = "Other"

    # FFT
    if getattr(model, 'do_fft_in_model', False):
        in_shape = input_tensor.shape
        fft_take = getattr(model, 'fft_take', 'second_half')
        if fft_take == 'rfft':
            mac = _manual_macs_rfft(in_shape)
        else:
            mac = _manual_macs_fft(in_shape)
        agg_macs["FFT (preprocess)"] = int(mac)
        agg_cats["FFT (preprocess)"] = "Other"

    labels = list(agg_macs.keys())
    macs = [agg_macs[k] for k in labels]
    cats = [agg_cats[k] for k in labels]

    order = np.argsort(macs)[::-1]
    labels = [labels[i] for i in order]
    macs = [macs[i] for i in order]
    cats = [cats[i] for i in order]
    return labels, macs, cats
def plot_layer_macs(labels, macs, categories,
                    save_path="layer_macs.jpg",
                    horizontal=False):
    """
    学术风格柱状图（默认垂直，可切换水平）
    - categories: 与 labels 等长的类别列表，用于着色
    """
    macs_m = np.array(macs, dtype=float) / 1e6
    colors = [_CAT_COLORS.get(c, "#95A5A6") for c in categories]
    if horizontal:
        fig, ax = plt.subplots(figsize=(10, 1.2 + 0.35 * len(labels)))
        y_pos = range(len(labels))
        bars = ax.barh(y_pos, macs_m, height=0.65, color=colors,
                       edgecolor='black', linewidth=0.5, zorder=3)
        ax.set_yticks(y_pos)
        ax.set_yticklabels(labels, fontsize=9)
        ax.invert_yaxis()
        ax.set_xlabel("MACs (M)")
        ax.set_title("Per‑layer MAC Distribution — DSCNN")
        for bar, val in zip(bars, macs_m):
            if val > 0.005:
                ax.text(bar.get_width() + 0.02 * max(macs_m), bar.get_y() + bar.get_height() / 2,
                        f'{val:.3f}', va='center', fontsize=7)
    else:
        fig, ax = plt.subplots(figsize=(14, 5))
        x_pos = range(len(labels))
        bars = ax.bar(x_pos, macs_m, color=colors,
                      edgecolor='black', linewidth=0.6, zorder=3)
        ax.set_xticks(x_pos)
        ax.set_xticklabels(labels, rotation=45, ha='right', fontsize=8)
        ax.set_ylabel("MACs (M)")
        ax.set_title("Per‑layer MAC Distribution — DSCNN")
        for bar, val in zip(bars, macs_m):
            if val > 0.005:
                ax.text(bar.get_x() + bar.get_width() / 2.,
                        bar.get_height() + 0.015 * max(macs_m),
                        f'{val:.3f}', ha='center', va='bottom', fontsize=7)
    ax.yaxis.set_major_formatter(ticker.FormatStrFormatter('%.2f'))
    ax.grid(axis='y' if not horizontal else 'x', linestyle='--', alpha=0.4, zorder=0)
    # 图例
    from matplotlib.patches import Patch
    legend_entries = [Patch(color=c, label=k) for k, c in _CAT_COLORS.items()
                      if k in set(categories)]
    if legend_entries:
        ax.legend(handles=legend_entries, loc='upper right', framealpha=0.9, fontsize=8)
    plt.tight_layout()
    plt.savefig(save_path)
    if matplotlib.get_backend() != 'Agg':
        plt.show()
    plt.close(fig)
    print(f"Chart saved to {save_path}")
# =========================================================
# 推理延时基准
# =========================================================
@torch.no_grad()
def benchmark_ms(model, x, warmup=20, iters=100):
    model.eval()
    device = x.device
    for _ in range(warmup):
        _ = model(x)
    if device.type == "cuda":
        torch.cuda.synchronize()
    t0 = time.time()
    for _ in range(iters):
        _ = model(x)
    if device.type == "cuda":
        torch.cuda.synchronize()
    t1 = time.time()
    return (t1 - t0) * 1000.0 / iters
# =========================================================
# 主程序
# =========================================================
if __name__ == '__main__':
    device = torch.device("cuda:0" if torch.cuda.is_available() else "cpu")
    model = DSCNN(
        num_classes=10,
        do_fft_in_model=True,
        fft_norm="forward",
        fft_take="second_half",
        attention_flags=[False, False, False, False, False]
    ).to(device)
    ckpt_path = r'D:\Code\prune_then_dkd_dia\Pth\DSCNNDSCNN-6_0HP_0.9673630987575186.pth'
    state = torch.load(ckpt_path, map_location=device)
    model.load_state_dict(state, strict=True)
    x = torch.randn(1, 1, 4096).to(device)
    ms = benchmark_ms(model, x, warmup=20, iters=100)
    y = model(x)
    print("FP32 output shape:", tuple(y.shape))
    print(f"FP32 avg latency: {ms:.4f} ms")
    # ---- 逐层 MAC ----
    labels, macs, cats = compute_layer_macs(model, x)
    print("\nPer‑layer MAC breakdown:")
    print(f"{'Layer':<22s}  {'MACs (M)':>10s}  Category")
    print("-" * 55)
    total = 0.0
    for lb, m, ct in zip(labels, macs, cats):
        total += m / 1e6
        print(f"{lb:<22s}  {m/1e6:10.4f}  {ct}")
    print("-" * 55)
    print(f"{'TOTAL':<22s}  {total:10.4f} M MACs")
    print("Note: MaxPool / GAP contribute 0 MACs (no multiplications).")
    # ---- 画图（垂直版 + 水平版各一张） ----
    plot_layer_macs(labels, macs, cats,
                    save_path="dscnn_layer_macs_vertical.jpg",
                    horizontal=False)

    plot_layer_macs(labels, macs, cats,
                    save_path="dscnn_layer_macs_horizontal.jpg",
                    horizontal=True)
