#!/usr/bin/env python3
from pathlib import Path

INPUT_LEN = 2048
NUM_BLOCKS = 5
NUM_CLASSES = 10

INITIAL_IN_CH = 1
INITIAL_OUT_CH = 12
INITIAL_KERNEL = 64
INITIAL_STRIDE = 8
INITIAL_PAD = 28

DSC_CFG = [
    (12, 24),
    (24, 48),
    (48, 60),
    (60, 72),
    (72, 72),
]
DW_KERNEL = 7
DW_PAD = 3
DW_STRIDE = 1
POOL_KERNEL = 2
POOL_STRIDE = 2

SCALE_Q8_8 = 256
BIAS = 0
INPUT_ZP = 0
WEIGHT_ZP = 0
OUTPUT_ZP = 0


def to_int8(x: int) -> int:
    if x > 127:
        return 127
    if x < -128:
        return -128
    return int(x)


def int8_to_hex(x: int) -> str:
    return f"{(x + 256) & 0xFF:02x}"


def int16_to_hex(x: int) -> str:
    return f"{x & 0xFFFF:04x}"


def int32_to_hex(x: int) -> str:
    return f"{x & 0xFFFFFFFF:08x}"


def conv1d_out_len(in_len: int, kernel: int, stride: int, padding: int) -> int:
    return ((in_len + 2 * padding - kernel) // stride) + 1


def requant(acc: int, relu_en: bool) -> int:
    scaled = (acc * SCALE_Q8_8) >> 8
    biased = scaled + BIAS
    shifted = biased + OUTPUT_ZP
    clipped = to_int8(shifted)
    if relu_en and clipped < 0:
        return 0
    return clipped


def build_input(length: int):
    return [(i % 17) - 8 for i in range(length)]


def fake_weight_by_addr(addr: int) -> int:
    m = addr % 5
    if m == 0:
        return -2
    if m == 1:
        return -1
    if m == 2:
        return 0
    if m == 3:
        return 1
    return 2


def build_weight_blob():
    weights = []
    base = {}
    addr = 0

    base["initial"] = addr
    for oc in range(INITIAL_OUT_CH):
        for k in range(INITIAL_KERNEL):
            weights.append(fake_weight_by_addr(addr))
            addr += 1

    base["dw"] = []
    base["pw"] = []

    for blk in range(NUM_BLOCKS):
        in_ch, out_ch = DSC_CFG[blk]

        dw_base = addr
        base["dw"].append(dw_base)
        for ch in range(in_ch):
            for k in range(DW_KERNEL):
                weights.append(fake_weight_by_addr(addr))
                addr += 1

        pw_base = addr
        base["pw"].append(pw_base)
        for oc in range(out_ch):
            for ic in range(in_ch):
                weights.append(fake_weight_by_addr(addr))
                addr += 1

    final_in_ch = DSC_CFG[-1][1]
    base["final"] = addr
    for cls in range(NUM_CLASSES):
        for ch in range(final_in_ch):
            weights.append(fake_weight_by_addr(addr))
            addr += 1

    return weights, base


def build_bn_blob(total_entries: int):
    lines = []
    for _ in range(total_entries):
        packed = (
            ((SCALE_Q8_8 & 0xFFFF) << 56)
            | ((BIAS & 0xFFFFFFFF) << 24)
            | (((INPUT_ZP + 256) & 0xFF) << 16)
            | (((WEIGHT_ZP + 256) & 0xFF) << 8)
            | ((OUTPUT_ZP + 256) & 0xFF)
        )
        lines.append(f"{packed:018x}")
    return lines


def initial_conv(x, w, base):
    out_len = conv1d_out_len(len(x), INITIAL_KERNEL, INITIAL_STRIDE, INITIAL_PAD)
    out = [[0 for _ in range(out_len)] for _ in range(INITIAL_OUT_CH)]

    for oc in range(INITIAL_OUT_CH):
        for pos in range(out_len):
            acc = 0
            center = pos * INITIAL_STRIDE
            for k in range(INITIAL_KERNEL):
                idx = center + k - INITIAL_PAD
                inp = x[idx] if 0 <= idx < len(x) else 0
                addr = base["initial"] + oc * INITIAL_KERNEL + k
                wt = w[addr]
                acc += (inp - INPUT_ZP) * (wt - WEIGHT_ZP)
            out[oc][pos] = requant(acc, relu_en=True)
    return out


def depthwise_conv(feat, channels, length, block_idx, w, base):
    out = [[0 for _ in range(length)] for _ in range(channels)]
    blk_base = base["dw"][block_idx]

    for ch in range(channels):
        for pos in range(length):
            acc = 0
            for k in range(DW_KERNEL):
                idx = pos + k - DW_PAD
                inp = feat[ch][idx] if 0 <= idx < length else 0
                addr = blk_base + ch * DW_KERNEL + k
                wt = w[addr]
                acc += (inp - INPUT_ZP) * (wt - WEIGHT_ZP)
            out[ch][pos] = requant(acc, relu_en=True)
    return out


def pointwise_conv(feat, in_channels, out_channels, length, block_idx, w, base):
    out = [[0 for _ in range(length)] for _ in range(out_channels)]
    blk_base = base["pw"][block_idx]

    for oc in range(out_channels):
        for pos in range(length):
            acc = 0
            row_base = blk_base + oc * in_channels
            for ic in range(in_channels):
                inp = feat[ic][pos]
                wt = w[row_base + ic]
                acc += (inp - INPUT_ZP) * (wt - WEIGHT_ZP)
            out[oc][pos] = requant(acc, relu_en=True)
    return out


def maxpool(feat, channels, in_len):
    out_len = in_len // 2
    out = [[0 for _ in range(out_len)] for _ in range(channels)]
    for ch in range(channels):
        for pos in range(out_len):
            a = feat[ch][2 * pos]
            b = feat[ch][2 * pos + 1]
            out[ch][pos] = a if a >= b else b
    return out


def gap(feat, channels, length):
    vec = [0 for _ in range(channels)]
    for ch in range(channels):
        s = 0
        for pos in range(length):
            s += feat[ch][pos]
        vec[ch] = to_int8(s // length)
    return vec


def final_conv(gap_vec, channels, num_classes, w, base):
    logits = [0 for _ in range(num_classes)]
    fc_base = base["final"]
    for cls in range(num_classes):
        acc = 0
        row_base = fc_base + cls * channels
        for ch in range(channels):
            inp = gap_vec[ch]
            wt = w[row_base + ch]
            acc += (inp - INPUT_ZP) * (wt - WEIGHT_ZP)
        logits[cls] = requant(acc, relu_en=False)
    return logits


def run_model(input_signal, weights, base):
    feat = initial_conv(input_signal, weights, base)

    curr_channels = INITIAL_OUT_CH
    curr_len = len(feat[0])

    for blk in range(NUM_BLOCKS):
        in_ch, out_ch = DSC_CFG[blk]
        if in_ch != curr_channels:
            raise RuntimeError(f"channel mismatch at block {blk}: {curr_channels} vs {in_ch}")

        feat = depthwise_conv(feat, in_ch, curr_len, blk, weights, base)
        feat = pointwise_conv(feat, in_ch, out_ch, curr_len, blk, weights, base)
        feat = maxpool(feat, out_ch, curr_len)

        curr_channels = out_ch
        curr_len = curr_len // 2

    gap_vec = gap(feat, curr_channels, curr_len)
    return final_conv(gap_vec, curr_channels, NUM_CLASSES, weights, base)


def main():
    root = Path(__file__).resolve().parents[1]
    mem_dir = root / "mem"
    mem_dir.mkdir(parents=True, exist_ok=True)

    x = build_input(INPUT_LEN)
    weights, base = build_weight_blob()
    logits = run_model(x, weights, base)

    bn_total = INITIAL_OUT_CH
    for in_ch, out_ch in DSC_CFG:
        bn_total += in_ch
        bn_total += out_ch
    bn_total += NUM_CLASSES

    (mem_dir / "fake_input_2048.mem").write_text(
        "\n".join(int8_to_hex(v) for v in x) + "\n",
        encoding="utf-8",
    )

    (mem_dir / "fake_weights.mem").write_text(
        "\n".join(int8_to_hex(v) for v in weights) + "\n",
        encoding="utf-8",
    )

    (mem_dir / "fake_bn_params.mem").write_text(
        "\n".join(build_bn_blob(bn_total)) + "\n",
        encoding="utf-8",
    )

    (mem_dir / "golden_logits.mem").write_text(
        "\n".join(int8_to_hex(v) for v in logits) + "\n",
        encoding="utf-8",
    )

    print(f"generated fake_input_2048.mem lines={len(x)}")
    print(f"generated fake_weights.mem lines={len(weights)}")
    print(f"generated fake_bn_params.mem lines={bn_total}")
    print(f"generated golden_logits.mem lines={len(logits)} logits={logits}")


if __name__ == "__main__":
    main()
