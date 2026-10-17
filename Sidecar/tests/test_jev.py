#!/usr/bin/env python3
"""jev.py 纯函数单元测试（不触网）。

运行：cd Sidecar && python3 -m unittest discover -s tests -v
"""

import pathlib
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import jev  # noqa: E402


class TestPick(unittest.TestCase):
    VALID = {"anime", "realistic", "watercolor"}

    def test_normal_choice_with_runner_up(self):
        answer = {
            "choice": "anime",
            "confidence": 0.8,
            "probabilities": {"anime": 0.8, "realistic": 0.15, "watercolor": 0.05},
        }
        result = jev._pick(answer, self.VALID)
        self.assertIsNotNone(result)
        self.assertEqual(result["choice"], "anime")
        self.assertEqual(result["confidence"], 0.8)
        self.assertEqual(result["runner_up"],
                         {"choice": "realistic", "probability": 0.15})

    def test_out_of_range_choice_falls_back_to_probabilities(self):
        answer = {
            "choice": "__hack_option__",
            "confidence": 0.0,
            "probabilities": {"anime": 0.1, "realistic": 0.7, "watercolor": 0.2},
        }
        result = jev._pick(answer, self.VALID)
        self.assertEqual(result["choice"], "realistic")
        self.assertEqual(result["runner_up"],
                         {"choice": "watercolor", "probability": 0.2})

    def test_all_probabilities_out_of_range_returns_none(self):
        answer = {
            "choice": "bogus",
            "probabilities": {"unknown_a": 0.5, "unknown_b": 0.5},
        }
        self.assertIsNone(jev._pick(answer, self.VALID))

    def test_non_dict_answer_returns_none(self):
        self.assertIsNone(jev._pick(None, self.VALID))
        self.assertIsNone(jev._pick("anime", self.VALID))
        self.assertIsNone(jev._pick([], self.VALID))

    def test_missing_probabilities_with_valid_choice(self):
        result = jev._pick({"choice": "anime"}, self.VALID)
        self.assertIsNotNone(result)
        self.assertEqual(result["choice"], "anime")
        self.assertEqual(result["confidence"], 0.0)
        self.assertIsNone(result["runner_up"])

    def test_probability_string_values_coerced(self):
        answer = {
            "choice": "anime",
            "confidence": "0.6",
            "probabilities": {"anime": "0.6", "realistic": "0.4"},
        }
        result = jev._pick(answer, self.VALID)
        self.assertEqual(result["confidence"], 0.6)
        self.assertEqual(result["runner_up"]["probability"], 0.4)


class TestProxyParts(unittest.TestCase):
    def test_full_proxy_url(self):
        with mock.patch.object(jev, "get_proxy", return_value="http://127.0.0.1:7890"):
            self.assertEqual(jev._proxy_parts(), ("127.0.0.1", 7890))

    def test_socks_scheme_and_path_stripped(self):
        with mock.patch.object(jev, "get_proxy",
                               return_value="socks5://192.168.1.10:1080/path"):
            self.assertEqual(jev._proxy_parts(), ("192.168.1.10", 1080))

    def test_missing_port_defaults_to_7890(self):
        with mock.patch.object(jev, "get_proxy", return_value="http://127.0.0.1"):
            self.assertEqual(jev._proxy_parts(), ("127.0.0.1", 7890))

    def test_empty_proxy_defaults(self):
        with mock.patch.object(jev, "get_proxy", return_value=""):
            self.assertEqual(jev._proxy_parts(), ("127.0.0.1", 7890))

    def test_bad_port_defaults(self):
        with mock.patch.object(jev, "get_proxy", return_value="http://127.0.0.1:abc"):
            self.assertEqual(jev._proxy_parts(), ("127.0.0.1", 7890))


if __name__ == "__main__":
    unittest.main()
