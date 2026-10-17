#!/usr/bin/env python3
"""optimizer.py 纯函数单元测试。

运行：cd Sidecar && python3 -m unittest discover -s tests -v
"""

import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import optimizer  # noqa: E402


class TestResolveOutputFormat(unittest.TestCase):
    def test_jpg_variants(self):
        self.assertEqual(optimizer._resolve_output_format("/tmp/a.jpg"), "JPEG")
        self.assertEqual(optimizer._resolve_output_format("/tmp/a.jpeg"), "JPEG")

    def test_png(self):
        self.assertEqual(optimizer._resolve_output_format("/tmp/a.png"), "PNG")

    def test_webp(self):
        self.assertEqual(optimizer._resolve_output_format("/tmp/a.webp"), "WEBP")

    def test_unknown_suffix_uses_src_format(self):
        self.assertEqual(
            optimizer._resolve_output_format("/tmp/a.avif", "WEBP"), "WEBP"
        )

    def test_unknown_suffix_without_src_defaults_png(self):
        self.assertEqual(optimizer._resolve_output_format("/tmp/a.bin"), "PNG")

    def test_case_insensitive_suffix(self):
        self.assertEqual(optimizer._resolve_output_format("/tmp/A.JPG"), "JPEG")


if __name__ == "__main__":
    unittest.main()
