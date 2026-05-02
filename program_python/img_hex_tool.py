#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
img_hex_tool.py

Tool tạo dữ liệu test cho resize_maxpooling RTL.

Chức năng chính:
  1. Từ ảnh bất kỳ -> ảnh VGA 640x480 PNG
  2. Từ ảnh VGA 640x480 -> file .hex RGB565, mỗi dòng 1 pixel 16-bit
  3. Tạo ảnh expected 224x224 bằng thuật toán resize + maxpool + padding giống RTL
  4. Convert file .hex RGB565 -> ảnh PNG để xem bằng mắt
  5. So sánh expected .hex với RTL capture .hex

Cài thư viện:
  pip install pillow

Ví dụ flow:
  python3 img_hex_tool.py prepare input.jpg --vga-png vga_640x480.png --vga-hex frame_640x480.hex
  python3 img_hex_tool.py ref --in-hex frame_640x480.hex --out-hex expected_224.hex --out-png expected_224.png
  # chạy simulation RTL để tạo rtl_capture_224.hex
  python3 img_hex_tool.py view --in-hex rtl_capture_224.hex --width 224 --height 224 --out-png rtl_capture_224.png
  python3 img_hex_tool.py compare --expected expected_224.hex --actual rtl_capture_224.hex
"""

import argparse
from pathlib import Path
from PIL import Image


IN_W = 640
IN_H = 480
OUT_SIZE = 224
SCALED_H = 168
PAD_TOP = 28
FP = 16
X_STEP = (IN_W << FP) // OUT_SIZE
Y_STEP = (IN_H << FP) // SCALED_H


def rgb888_to_rgb565(r: int, g: int, b: int) -> int:
    r5 = (r >> 3) & 0x1F
    g6 = (g >> 2) & 0x3F
    b5 = (b >> 3) & 0x1F
    return (r5 << 11) | (g6 << 5) | b5


def rgb565_to_rgb888(v: int) -> tuple[int, int, int]:
    r5 = (v >> 11) & 0x1F
    g6 = (v >> 5) & 0x3F
    b5 = v & 0x1F

    # bit replication, giống cách phần cứng thường expand RGB565 -> RGB888
    r8 = (r5 << 3) | (r5 >> 2)
    g8 = (g6 << 2) | (g6 >> 4)
    b8 = (b5 << 3) | (b5 >> 2)
    return r8, g8, b8


def load_hex(path: str | Path) -> list[int]:
    vals: list[int] = []
    with open(path, "r", encoding="utf-8") as f:
        for line_no, line in enumerate(f, 1):
            s = line.strip()
            if not s:
                continue
            if s.startswith("//") or s.startswith("#"):
                continue
            try:
                vals.append(int(s, 16) & 0xFFFF)
            except ValueError as e:
                raise ValueError(f"Invalid hex at {path}:{line_no}: {s!r}") from e
    return vals


def save_hex(vals: list[int], path: str | Path) -> None:
    with open(path, "w", encoding="utf-8") as f:
        for v in vals:
            f.write(f"{v & 0xFFFF:04x}\n")


def image_to_vga(input_image: str | Path, out_png: str | Path, resize_mode: str = "stretch") -> Image.Image:
    """
    resize_mode:
      stretch : resize thẳng về 640x480
      contain : giữ aspect ratio, padding đen vào 640x480
      cover   : giữ aspect ratio, crop giữa cho đầy 640x480
    """
    img = Image.open(input_image).convert("RGB")

    if resize_mode == "stretch":
        vga = img.resize((IN_W, IN_H), Image.Resampling.LANCZOS)

    elif resize_mode == "contain":
        vga = Image.new("RGB", (IN_W, IN_H), (0, 0, 0))
        tmp = img.copy()
        tmp.thumbnail((IN_W, IN_H), Image.Resampling.LANCZOS)
        x0 = (IN_W - tmp.width) // 2
        y0 = (IN_H - tmp.height) // 2
        vga.paste(tmp, (x0, y0))

    elif resize_mode == "cover":
        src_w, src_h = img.size
        scale = max(IN_W / src_w, IN_H / src_h)
        new_w = int(round(src_w * scale))
        new_h = int(round(src_h * scale))
        tmp = img.resize((new_w, new_h), Image.Resampling.LANCZOS)
        x0 = (new_w - IN_W) // 2
        y0 = (new_h - IN_H) // 2
        vga = tmp.crop((x0, y0, x0 + IN_W, y0 + IN_H))

    else:
        raise ValueError("resize_mode must be stretch, contain, or cover")

    vga.save(out_png)
    return vga


def image_to_hex(img: Image.Image, out_hex: str | Path) -> None:
    img = img.convert("RGB")
    if img.size != (IN_W, IN_H):
        raise ValueError(f"image must be {IN_W}x{IN_H}, got {img.size}")

    vals: list[int] = []
    pix = img.load()
    for y in range(IN_H):
        for x in range(IN_W):
            r, g, b = pix[x, y]
            vals.append(rgb888_to_rgb565(r, g, b))

    save_hex(vals, out_hex)


def hex_to_image(in_hex: str | Path, width: int, height: int, out_png: str | Path) -> None:
    vals = load_hex(in_hex)
    need = width * height
    if len(vals) < need:
        raise ValueError(f"hex has only {len(vals)} pixels, need {need}")
    if len(vals) > need:
        print(f"Warning: hex has {len(vals)} pixels, using first {need}")

    img = Image.new("RGB", (width, height))
    out = img.load()

    for y in range(height):
        for x in range(width):
            v = vals[y * width + x]
            out[x, y] = rgb565_to_rgb888(v)

    img.save(out_png)


def maxpool_resize_ref_from_hex(in_hex: str | Path, out_hex: str | Path, out_png: str | Path | None = None) -> None:
    src = load_hex(in_hex)
    need = IN_W * IN_H
    if len(src) < need:
        raise ValueError(f"input hex has {len(src)} pixels, need {need} for {IN_W}x{IN_H}")
    src = src[:need]

    dst: list[int] = []

    for out_y in range(OUT_SIZE):
        for out_x in range(OUT_SIZE):
            # padding top/bottom
            if out_y < PAD_TOP or out_y >= PAD_TOP + SCALED_H:
                dst.append(0x0000)
                continue

            img_y = out_y - PAD_TOP

            src_x0 = (out_x * X_STEP) >> FP
            if out_x == OUT_SIZE - 1:
                src_x1 = IN_W - 1
            else:
                src_x1 = (((out_x + 1) * X_STEP) >> FP) - 1

            src_y0 = (img_y * Y_STEP) >> FP
            if img_y == SCALED_H - 1:
                src_y1 = IN_H - 1
            else:
                src_y1 = (((img_y + 1) * Y_STEP) >> FP) - 1

            max_r = 0
            max_g = 0
            max_b = 0

            for yy in range(src_y0, src_y1 + 1):
                base = yy * IN_W
                for xx in range(src_x0, src_x1 + 1):
                    p = src[base + xx]
                    r = (p >> 11) & 0x1F
                    g = (p >> 5) & 0x3F
                    b = p & 0x1F
                    if r > max_r:
                        max_r = r
                    if g > max_g:
                        max_g = g
                    if b > max_b:
                        max_b = b

            dst.append((max_r << 11) | (max_g << 5) | max_b)

    save_hex(dst, out_hex)

    if out_png is not None:
        hex_to_image(out_hex, OUT_SIZE, OUT_SIZE, out_png)


def print_mapping(out_y: int, out_x: int, max_pixels: int = 200) -> None:
    print("")
    print("=================================================")
    print("MAPPING CHECK")
    print(f"Output pixel: out_x={out_x}, out_y={out_y}")

    if out_x < 0 or out_x >= OUT_SIZE or out_y < 0 or out_y >= OUT_SIZE:
        print("ERROR: output coordinate out of range")
        print("=================================================")
        return

    if out_y < PAD_TOP or out_y >= PAD_TOP + SCALED_H:
        print("This output pixel is in padding area.")
        print("No input pixel from 640x480 is used.")
        print("Output pixel = 0x0000")
        print("=================================================")
        return

    img_y = out_y - PAD_TOP
    src_x0 = (out_x * X_STEP) >> FP
    src_x1 = IN_W - 1 if out_x == OUT_SIZE - 1 else (((out_x + 1) * X_STEP) >> FP) - 1
    src_y0 = (img_y * Y_STEP) >> FP
    src_y1 = IN_H - 1 if img_y == SCALED_H - 1 else (((img_y + 1) * Y_STEP) >> FP) - 1

    print("This output pixel is inside real image area.")
    print(f"img_y = out_y - PAD_TOP = {out_y} - {PAD_TOP} = {img_y}")
    print("Input window:")
    print(f"  src_x0 = {src_x0}")
    print(f"  src_x1 = {src_x1}")
    print(f"  src_y0 = {src_y0}")
    print(f"  src_y1 = {src_y1}")
    print("Window size:")
    print(f"  width  = {src_x1 - src_x0 + 1}")
    print(f"  height = {src_y1 - src_y0 + 1}")
    print(f"  count  = {(src_x1 - src_x0 + 1) * (src_y1 - src_y0 + 1)}")

    count = 0
    print("")
    print("Input pixels used:")
    for yy in range(src_y0, src_y1 + 1):
        for xx in range(src_x0, src_x1 + 1):
            addr = yy * IN_W + xx
            if count < max_pixels:
                print(f"  input_x={xx:3d} input_y={yy:3d} addr={addr:6d}")
            count += 1

    if count > max_pixels:
        print(f"  ... printed only first {max_pixels} / {count} pixels")

    print("=================================================")


def compare_hex(expected_hex: str | Path, actual_hex: str | Path, max_print: int = 50) -> int:
    exp = load_hex(expected_hex)
    act = load_hex(actual_hex)

    n = min(len(exp), len(act))
    errors = 0

    if len(exp) != len(act):
        print(f"Length mismatch: expected has {len(exp)} pixels, actual has {len(act)} pixels")

    for i in range(n):
        if exp[i] != act[i]:
            if errors < max_print:
                y = i // OUT_SIZE
                x = i % OUT_SIZE
                print(f"Mismatch idx={i} x={x} y={y}: expected={exp[i]:04x} actual={act[i]:04x}")
            errors += 1

    errors += abs(len(exp) - len(act))

    if errors == 0:
        print("COMPARE PASSED: files match exactly.")
    else:
        print(f"COMPARE FAILED: {errors} mismatches.")

    return errors


def main() -> None:
    parser = argparse.ArgumentParser(description="RGB565 image/hex helper for resize_maxpooling RTL")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_prepare = sub.add_parser("prepare", help="input image -> 640x480 PNG + RGB565 hex")
    p_prepare.add_argument("input_image")
    p_prepare.add_argument("--vga-png", default="vga_640x480.png")
    p_prepare.add_argument("--vga-hex", default="frame_640x480.hex")
    p_prepare.add_argument("--mode", choices=["stretch", "contain", "cover"], default="stretch")

    p_img2hex = sub.add_parser("img2hex", help="640x480 image -> RGB565 hex")
    p_img2hex.add_argument("input_png")
    p_img2hex.add_argument("--out-hex", default="frame_640x480.hex")

    p_view = sub.add_parser("view", help="RGB565 hex -> PNG")
    p_view.add_argument("--in-hex", required=True)
    p_view.add_argument("--width", type=int, required=True)
    p_view.add_argument("--height", type=int, required=True)
    p_view.add_argument("--out-png", required=True)

    p_ref = sub.add_parser("ref", help="640x480 RGB565 hex -> expected 224x224 RGB565 hex/png")
    p_ref.add_argument("--in-hex", default="frame_640x480.hex")
    p_ref.add_argument("--out-hex", default="expected_224.hex")
    p_ref.add_argument("--out-png", default="expected_224.png")

    p_cmp = sub.add_parser("compare", help="compare expected hex and RTL captured hex")
    p_cmp.add_argument("--expected", required=True)
    p_cmp.add_argument("--actual", required=True)
    p_cmp.add_argument("--max-print", type=int, default=50)

    p_map = sub.add_parser("map", help="print mapping from output coordinate to input pixels")
    p_map.add_argument("--x", type=int, required=True)
    p_map.add_argument("--y", type=int, required=True)

    args = parser.parse_args()

    if args.cmd == "prepare":
        vga = image_to_vga(args.input_image, args.vga_png, args.mode)
        image_to_hex(vga, args.vga_hex)
        print(f"Wrote {args.vga_png}")
        print(f"Wrote {args.vga_hex}")
        print(f"X_STEP={X_STEP}, Y_STEP={Y_STEP}")

    elif args.cmd == "img2hex":
        img = Image.open(args.input_png).convert("RGB")
        image_to_hex(img, args.out_hex)
        print(f"Wrote {args.out_hex}")

    elif args.cmd == "view":
        hex_to_image(args.in_hex, args.width, args.height, args.out_png)
        print(f"Wrote {args.out_png}")

    elif args.cmd == "ref":
        maxpool_resize_ref_from_hex(args.in_hex, args.out_hex, args.out_png)
        print(f"Wrote {args.out_hex}")
        print(f"Wrote {args.out_png}")

    elif args.cmd == "compare":
        raise SystemExit(compare_hex(args.expected, args.actual, args.max_print))

    elif args.cmd == "map":
        print_mapping(args.y, args.x)


if __name__ == "__main__":
    main()
