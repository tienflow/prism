#!/usr/bin/env python3
"""输出目录布局相关纯函数测试（月份分目录 / 磁盘预检）。

运行：cd Sidecar && python3 -m unittest discover -s tests -v
"""

import pathlib
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import gemini_engine as g  # noqa: E402


class TestMonthOutputDir(unittest.TestCase):
    def test_month_dir_name_and_creation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            with mock.patch.object(g, "OUTPUT_DIR", root):
                target = g._month_output_dir(now=1760000000)
            # 1760000000 -> 2025-10 本地时区（只校验 YYYY-MM 形态与目录已创建）
            self.assertRegex(target.name, r"^\d{4}-\d{2}$")
            self.assertTrue(target.is_dir())
            self.assertEqual(target.parent, root)

    def test_deterministic_within_same_month(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            with mock.patch.object(g, "OUTPUT_DIR", root):
                a = g._month_output_dir(now=1760000000)
                b = g._month_output_dir(now=1760000000 + 86400)
            self.assertEqual(a, b)

    def test_rolls_over_next_month(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            with mock.patch.object(g, "OUTPUT_DIR", root):
                october = g._month_output_dir(now=1760000000)
                november = g._month_output_dir(now=1760000000 + 31 * 86400)
            self.assertNotEqual(october, november)


class TestEnsureDiskSpace(unittest.TestCase):
    def test_enough_space_passes(self):
        import collections
        usage = collections.namedtuple("usage", ["total", "used", "free"])(
            100_000_000_000, 50_000_000_000, 50_000_000_000
        )
        with mock.patch.object(g.shutil, "disk_usage", return_value=usage):
            g._ensure_disk_space(4)  # 不应抛异常

    def test_insufficient_space_raises(self):
        import collections
        usage = collections.namedtuple("usage", ["total", "used", "free"])(
            100_000_000_000, 99_999_900_000, 1_000_000
        )
        with mock.patch.object(g.shutil, "disk_usage", return_value=usage):
            with self.assertRaises(RuntimeError) as ctx:
                g._ensure_disk_space(4)
            self.assertIn("磁盘空间不足", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
