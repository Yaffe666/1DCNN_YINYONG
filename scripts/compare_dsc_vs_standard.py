"""
DSCNN vs Standard CNN 对比图 — MAC + 参数量双轴组合图
"""
import torch
import torch.nn as nn
import numpy as np
from collections import defaultdict
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker

# =========================================================
# 学术风格
# =========================================================
plt.rcParams.update({
    "font.family": "serif",
    "font.size": 13,
    "axes.titlesize": 16,
    "axes.labelsize": 15,
    "xtick.labelsize": 11,
    "ytick.labelsize": 11,
    "legend.fontsize": 11,
    "figure.dpi": 150,
    "savefig.dpi": 600,
    "savefig.bbox": "tight",
    "font.weight": "normal",
    "axes.labelweight": "bold",
    "axes.titleweight": "bold",
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
# DSC Block（你的模型）
# =========================================================
class DSCBlock(nn.Module):
    def __init__(self, in_channels, out_channels, kernel_size=7, padding=3):
        super().__init__()
        self.depthwise = nn.Conv1d(in_channels, in_channels, kernel_size,
                                   padding=padding, groups=in_channels, bias=False)
        self.bn_depth = nn.BatchNorm1d(in_channels)
        self.relu1 = nn.ReLU(inplace=False)
        self.pointwise = nn.Conv1d(in_channels, out_channels, 1, bias=False)
        self.bn_point = nn.BatchNorm1d(out_channels)
        self.relu2 = nn.ReLU(inplace=False)
        self.pool = nn.MaxPool1d(kernel_size=2, stride=2)

    def forward(self, x):
        x = self.relu1(self.bn_depth(self.depthwise(x)))
        x = self.relu2(self.bn_point(self.pointwise(x)))
        return self.pool(x)


class DSCNN(nn.Module):
    def __init__(self, num_classes=10):
        super().__init__()
        self.initial_conv = nn.Sequential(
            nn.Conv1d(1, 12, 64, stride=8, padding=28, bias=False),
            nn.BatchNorm1d(12),
            nn.ReLU(inplace=False),
        )
        self.dsc_layers = nn.Sequential(
            DSCBlock(12, 24),
            DSCBlock(24, 48),
            DSCBlock(48, 60),
            DSCBlock(60, 72),
            DSCBlock(72, 72),
        )
        self.gap = nn.AdaptiveAvgPool1d(1)
        self.final_conv = nn.Conv1d(72, num_classes, 1, bias=True)

    def forward(self, x, already_fft=False):
        if not already_fft:
            x = fft_half_feature_torch(x, take="second_half")
        x = self.initial_conv(x)
        x = self.dsc_layers(x)
        x = self.gap(x)
        return self.final_conv(x).squeeze(-1)


# =========================================================
# 标准 Conv Block（对照组）
# =========================================================
class StdConvBlock(nn.Module):
    def __init__(self, in_channels, out_channels, kernel_size=7, padding=3):
        super().__init__()
        self.conv1 = nn.Conv1d(in_channels, out_channels, kernel_size,
                               padding=padding, bias=False)
        self.bn1 = nn.BatchNorm1d(out_channels)
        self.relu1 = nn.ReLU(inplace=False)
        self.conv2 = nn.Conv1d(out_channels, out_channels, 1, bias=False)
        self.bn2 = nn.BatchNorm1d(out_channels)
        self.relu2 = nn.ReLU(inplace=False)
        self.pool = nn.MaxPool1d(kernel_size=2, stride=2)

    def forward(self, x):
        x = self.relu1(self.bn1(self.conv1(x)))
        x = self.relu2(self.bn2(self.conv2(x)))
        return self.pool(x)


class StandardCNN(nn.Module):
    def __init__(self, num_classes=10):
        super().__init__()
        self.initial_conv = nn.Sequential(
            nn.Conv1d(1, 12, 64, stride=8, padding=28, bias=False),
            nn.BatchNorm1d(12),
            nn.ReLU(inplace=False),
        )
        self.std_layers = nn.Sequential(
            StdConvBlock(12, 24),
            StdConvBlock(24, 48),
            StdConvBlock(48, 60),
            StdConvBlock(60, 72),
            StdConvBlock(72, 72),
        )
        self.gap = nn.AdaptiveAvgPool1d(1)
        self.final_conv = nn.Conv1d(72, num_classes, 1, bias=True)

    def forward(self, x, already_fft=False):
        if not already_fft:
            x = fft_half_feature_torch(x, take="second_half")
        x = self.initial_conv(x)
        x = self.std_layers(x)
        x = self.gap(x)
        return self.final_conv(x).squeeze(-1)


# =========================================================
# MAC & Params 计算
# =========================================================
def _macs_conv1d(layer, in_shape):
    Cout = layer.out_channels
    Cin_per_g = layer.in_channels // layer.groups
    K = layer.kernel_size[0]
    S = layer.stride[0]
    P = layer.padding[0]
    D = layer.dilation[0]
    Lin = in_shape[-1]
    Lout = (Lin + 2 * P - D * (K - 1) - 1) // S + 1
    return Cout * Cin_per_g * K * Lout


def _macs_linear(layer):
    return layer.in_features * layer.out_features


def _macs_fft(in_shape):
    N = in_shape[-1]
    return N * np.log2(N)


def compute_block_stats(model, input_tensor, block_attr):
    """
    跑一次前向，按 block 统计参数量和 MACs。
    block_attr: DSCNN 用 'dsc_layers', StandardCNN 用 'std_layers'
    """
    hooks = []
    shapes = {}

    def _hook(name):
        def h(m, inp, out):
            if isinstance(m, (nn.Conv1d, nn.Linear)):
                shapes[m] = (name, inp[0].shape)
        return h

    for n, m in model.named_modules():
        if not isinstance(m, (nn.Sequential, nn.ModuleList)):
            hooks.append(m.register_forward_hook(_hook(n)))

    model.eval()
    with torch.no_grad():
        _ = model(input_tensor)
    for h in hooks:
        h.remove()

    # 聚合到 blocks
    blocks = []
    block_names = []

    def add(key, mac, param):
        for i in range(len(blocks)):
            if blocks[i][0] == key:
                blocks[i] = (key, blocks[i][1] + mac, blocks[i][2] + param)
                return
        blocks.append((key, mac, param))

    for name, mod in model.named_modules():
        if mod not in shapes:
            continue
        full_name, in_shape = shapes[mod]

        if isinstance(mod, nn.Conv1d):
            mac = _macs_conv1d(mod, in_shape)
        elif isinstance(mod, nn.Linear):
            mac = _macs_linear(mod)
        else:
            mac = 0
        param = sum(p.numel() for p in mod.parameters())

        # 分类到 block
        if full_name == "initial_conv.0":
            add("Initial Conv", mac, param)
        elif full_name == "final_conv":
            add("Classifier", mac, param)
        else:
            # 找它属于哪个 block
            found = False
            for b_idx in range(10):
                prefix = f"{block_attr}.{b_idx}."
                if full_name.startswith(prefix):
                    add(f"Block [{b_idx}]", mac, param)
                    found = True
                    break
            if not found:
                add(full_name, mac, param)

    return blocks


def get_stats(dscnn, stdcnn, x):
    raw_dsc = compute_block_stats(dscnn, x, "dsc_layers")
    raw_std = compute_block_stats(stdcnn, x, "std_layers")

    # 只保留卷积块
    desired = ["Initial Conv"] + [f"Block [{i}]" for i in range(5)]
    d_map = {k: (m, p) for (k, m, p) in raw_dsc}
    s_map = {k: (m, p) for (k, m, p) in raw_std}

    dsc_mac, dsc_param, std_mac, std_param = [], [], [], []
    for k in desired:
        dm = d_map.get(k, (0, 0))
        sm = s_map.get(k, (0, 0))
        dsc_mac.append(dm[0]);    dsc_param.append(dm[1])
        std_mac.append(sm[0]);    std_param.append(sm[1])

    return desired, dsc_mac, dsc_param, std_mac, std_param


# =========================================================
# 双轴组合图
# =========================================================
def plot_comparison(names, dsc_mac, dsc_param, std_mac, std_param,
                    save_path="comparison.jpg"):
    mac_dsc = np.array(dsc_mac) / 1e6
    mac_std = np.array(std_mac) / 1e6
    param_dsc = np.array(dsc_param) / 1e3
    param_std = np.array(std_param) / 1e3

    x = np.arange(len(names))
    width = 0.30

    fig, ax1 = plt.subplots(figsize=(14, 6.5))

    # 配色 — 淡色柱 + 深色折线，对比度拉满
    C_BAR_DSC   = "#F5C6A0"   # 浅暖杏
    C_BAR_STD   = "#A0C0E0"   # 浅钢蓝
    C_LINE_DSC  = "#B03A2E"   # 深砖红
    C_LINE_STD  = "#1B4F72"   # 深海蓝
    EDGE_COLOR  = "#444444"
    GRID_COLOR  = "#CCCCCC"

    # ===== 柱状图 (参数量, 左轴) =====
    bars1 = ax1.bar(x - width / 2, param_dsc, width,
                    color=C_BAR_DSC, edgecolor=EDGE_COLOR, linewidth=0.9,
                    zorder=3, label="DSCNN  Params")
    bars2 = ax1.bar(x + width / 2, param_std, width,
                    color=C_BAR_STD, edgecolor=EDGE_COLOR, linewidth=0.9,
                    zorder=3, label="Standard CNN  Params")

    ax1.set_ylabel("Parameters  (K)", weight='bold', fontsize=18, labelpad=8)
    y1_max = max(max(param_dsc), max(param_std)) * 1.38
    ax1.set_ylim(0, y1_max)
    ax1.set_yticks(np.linspace(0, y1_max, 6))
    ax1.yaxis.set_major_formatter(ticker.FormatStrFormatter('%.0f'))
    ax1.tick_params(axis='y', labelsize=13, width=1.5, length=5)

    for bar in bars1:
        h = bar.get_height()
        if h > 0.05:
            ax1.text(bar.get_x() + bar.get_width() / 2., h + y1_max * 0.012,
                     f'{h:.1f}', ha='center', va='bottom', fontsize=9.5,
                     fontweight='bold', color=C_LINE_DSC)
    for bar in bars2:
        h = bar.get_height()
        if h > 0.05:
            ax1.text(bar.get_x() + bar.get_width() / 2., h + y1_max * 0.012,
                     f'{h:.1f}', ha='center', va='bottom', fontsize=9.5,
                     fontweight='bold', color=C_LINE_STD)

    # ===== 折线图 (MAC, 右轴) =====
    ax2 = ax1.twinx()
    (line1,) = ax2.plot(x, mac_dsc, 'D-', color=C_LINE_DSC, linewidth=3.0,
                        markersize=10, markerfacecolor='white',
                        markeredgewidth=2.5, markeredgecolor=C_LINE_DSC,
                        zorder=5, label="DSCNN  MACs")
    (line2,) = ax2.plot(x, mac_std, '^--', color=C_LINE_STD, linewidth=3.0,
                        markersize=10, markerfacecolor='white',
                        markeredgewidth=2.5, markeredgecolor=C_LINE_STD,
                        zorder=5, label="Standard CNN  MACs")

    ax2.set_ylabel("MACs  (M)", weight='bold', fontsize=18, labelpad=8)
    y2_max = max(max(mac_dsc), max(mac_std)) * 1.28
    ax2.set_ylim(0, y2_max)
    ax2.set_yticks(np.linspace(0, y2_max, 6))
    ax2.yaxis.set_major_formatter(ticker.FormatStrFormatter('%.1f'))
    ax2.tick_params(axis='y', labelsize=13, width=1.5, length=5)

    for i, v in enumerate(mac_dsc):
        ax2.annotate(f'{v:.2f}', (x[i], v), textcoords="offset points",
                     xytext=(0, 13), ha='center', fontsize=10,
                     fontweight='bold', color=C_LINE_DSC)
    for i, v in enumerate(mac_std):
        ax2.annotate(f'{v:.2f}', (x[i], v), textcoords="offset points",
                     xytext=(0, -17), ha='center', fontsize=10,
                     fontweight='bold', color=C_LINE_STD)

    # ===== x 轴 =====
    ax1.set_xticks(x)
    ax1.set_xticklabels(names, rotation=20, ha='right', fontsize=13)
    ax1.set_xlim(-0.6, len(names) - 0.4)
    ax1.tick_params(axis='x', width=1.5, length=5)

    # ===== 脊柱 =====
    for spine in ax1.spines.values():
        spine.set_linewidth(1.5)
    for spine in ax2.spines.values():
        spine.set_linewidth(1.5)

    # ===== 图例 =====
    lines1, labels1 = ax1.get_legend_handles_labels()
    lines2, labels2 = ax2.get_legend_handles_labels()
    legend = ax1.legend(lines1 + lines2, labels1 + labels2,
                        loc='upper left', framealpha=0.93, fontsize=12,
                        ncol=2, edgecolor=EDGE_COLOR,
                        borderpad=0.7, handlelength=2.0)
    legend.get_frame().set_linewidth(1.0)

    # ===== 网格 =====
    ax1.grid(axis='y', linestyle='--', alpha=0.30, color=GRID_COLOR, linewidth=0.8, zorder=0)
    ax1.set_axisbelow(True)

    ax1.set_title("DSCNN  vs  Standard CNN  —  Per-block MACs & Parameters",
                  fontsize=18, weight='bold', pad=14)

    plt.tight_layout()
    plt.savefig(save_path, dpi=600)
    plt.close(fig)
    print(f"Chart saved to {save_path}")


# =========================================================
# 主程序
# =========================================================
if __name__ == '__main__':
    ckpt_path = r'D:\Code\prune_then_dkd_dia\Pth\DSCNNDSCNN-6_0HP_0.9673630987575186.pth'

    dscnn = DSCNN(num_classes=10)
    state = torch.load(ckpt_path, map_location='cpu')
    dscnn.load_state_dict(state, strict=True)

    stdcnn = StandardCNN(num_classes=10)
    # StandardCNN 不加载权重，只看架构层面的 MAC/Params

    x = torch.randn(1, 1, 4096)

    names, dsc_mac, dsc_param, std_mac, std_param = get_stats(dscnn, stdcnn, x)

    print("\n═══════════════════════════════════════════════════════════")
    print(f"{'Block':<20s} {'DSC MAC(M)':>11s} {'Std MAC(M)':>11s} {'DSC Param(K)':>13s} {'Std Param(K)':>13s}")
    print("─" * 72)
    for i, n in enumerate(names):
        print(f"{n:<20s} {dsc_mac[i]/1e6:>11.4f} {std_mac[i]/1e6:>11.4f} "
              f"{dsc_param[i]/1e3:>13.2f} {std_param[i]/1e3:>13.2f}")
    print("─" * 72)
    print(f"{'TOTAL':<20s} {sum(dsc_mac)/1e6:>11.4f} {sum(std_mac)/1e6:>11.4f} "
          f"{sum(dsc_param)/1e3:>13.2f} {sum(std_param)/1e3:>13.2f}")
    print(f"\nDSC MAC reduction: {sum(std_mac)/sum(dsc_mac):.1f}×")
    print(f"DSC Param reduction: {sum(std_param)/sum(dsc_param):.1f}×")

    plot_comparison(names, dsc_mac, dsc_param, std_mac, std_param,
                    save_path="dsc_vs_standard_comparison.jpg")
