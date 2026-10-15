#!/usr/bin/env python3
"""
Image optimization and compression utility for Gemini Studio.
Supports format-preserving compression (PNG palette quantization, JPEG quality ladder)
and WeChat Official Account 1MB safe size optimization.
"""

import os
from pathlib import Path
from PIL import Image

DEFAULT_MAX_KB = 0  # 0 means lossless original

def _resolve_output_format(path: str, src_format: str = "") -> str:
    suffix = Path(path).suffix.lower()
    if suffix in (".jpg", ".jpeg"):
        return "JPEG"
    if suffix == ".png":
        return "PNG"
    if suffix == ".webp":
        return "WEBP"
    return src_format or "PNG"

def _flatten_alpha(img: Image.Image) -> Image.Image:
    if img.mode in ("RGBA", "LA", "P"):
        rgba = img.convert("RGBA")
        bg = Image.new("RGB", rgba.size, (255, 255, 255))
        bg.paste(rgba, mask=rgba.split()[-1])
        return bg
    if img.mode != "RGB":
        return img.convert("RGB")
    return img

def compress_image(path: str, max_kb: int = DEFAULT_MAX_KB) -> float:
    """
    Compress image if exceeds max_kb. If max_kb <= 0, skip.
    Returns final file size in KB.
    """
    if not max_kb or max_kb <= 0 or not os.path.exists(path):
        return os.path.getsize(path) / 1024 if os.path.exists(path) else 0

    orig_kb = os.path.getsize(path) / 1024
    if orig_kb <= max_kb:
        return orig_kb

    try:
        img = Image.open(path)
        out_format = _resolve_output_format(path, img.format or "")
        is_lossy = out_format in ("JPEG", "WEBP")
        if is_lossy:
            img = _flatten_alpha(img)

        def _save(im, quality=None):
            if quality is not None and is_lossy:
                im.save(path, out_format, quality=quality, optimize=True)
            else:
                im.save(path, out_format, optimize=True)

        if is_lossy:
            # 1. 质量阶梯
            quality = 85
            while quality >= 30:
                _save(img, quality)
                new_kb = os.path.getsize(path) / 1024
                if new_kb <= max_kb:
                    return new_kb
                quality -= 10
        else:
            # 2. PNG 调色板量化
            try:
                quantized = img.convert("RGB").quantize(colors=256, method=Image.MEDIANCUT)
                quantized.save(path, out_format, optimize=True)
                new_kb = os.path.getsize(path) / 1024
                if new_kb <= max_kb:
                    return new_kb
            except Exception:
                pass

        # 3. 尺寸阶梯缩放
        scale = 0.9
        while scale >= 0.5:
            w = max(1, int(img.width * scale))
            h = max(1, int(img.height * scale))
            resized = img.resize((w, h), Image.Resampling.LANCZOS)
            if is_lossy:
                _save(resized, 75)
            else:
                try:
                    quantized = resized.convert("RGB").quantize(colors=256, method=Image.MEDIANCUT)
                    quantized.save(path, out_format, optimize=True)
                except Exception:
                    resized.save(path, out_format, optimize=True)
            new_kb = os.path.getsize(path) / 1024
            if new_kb <= max_kb:
                return new_kb
            scale -= 0.1

        return os.path.getsize(path) / 1024
    except Exception as e:
        print(f"Warning: Compression failed: {e}")
        return os.path.getsize(path) / 1024
