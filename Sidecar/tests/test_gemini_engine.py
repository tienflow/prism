#!/usr/bin/env python3
"""gemini_engine.py 纯函数单元测试（不触网、不读凭据）。

运行：cd Sidecar && python3 -m unittest discover -s tests -v
"""

import io
import json
import pathlib
import sys
import unittest
import urllib.error

# 让 tests 从任意工作目录运行都能找到 Sidecar 模块
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import gemini_engine as g  # noqa: E402


class TestStripThink(unittest.TestCase):
    def test_paired_think_tag_removed(self):
        text = "<think>先想一下\n多行了\n</think>真正的正文"
        self.assertEqual(g._strip_think(text), "真正的正文")

    def test_multiple_think_segments_use_last(self):
        text = "<think>一</think>中间文本<think>二</think>最终答案"
        self.assertEqual(g._strip_think(text), "最终答案")

    def test_unclosed_think_at_tail_stripped(self):
        # 被截断的思考流：<think> 一直挂到结尾
        self.assertEqual(g._strip_think("正文末尾挂着思考 <think>   "), "正文末尾挂着思考")
        self.assertEqual(g._strip_think("正文末尾挂着思考 <think>"), "正文末尾挂着思考")

    def test_unclosed_think_with_following_text_kept(self):
        # 现有行为：<think> 后仍有非空白内容时不做猜测，整段保留
        self.assertEqual(
            g._strip_think("正文末尾挂着思考 <think>还在想"),
            "正文末尾挂着思考 <think>还在想",
        )

    def test_plain_text_unchanged(self):
        self.assertEqual(g._strip_think("一只猫坐在窗台上"), "一只猫坐在窗台上")

    def test_empty_input(self):
        self.assertEqual(g._strip_think(""), "")
        self.assertEqual(g._strip_think(None), "")


class TestNormalizePolished(unittest.TestCase):
    def test_collapses_newlines_into_single_line(self):
        out = g._normalize_polished("第一行\n第二行\r\n第三行")
        self.assertEqual(out, "第一行 第二行 第三行")

    def test_strips_web_footer_signature(self):
        out = g._normalize_polished("正文描述\n_1234567890")
        self.assertEqual(out, "正文描述")

    def test_strips_wrapping_quotes(self):
        self.assertEqual(g._normalize_polished("“一只猫”"), "一只猫")
        self.assertEqual(g._normalize_polished('"一只猫"'), "一只猫")

    def test_collapses_repeated_spaces(self):
        self.assertEqual(g._normalize_polished("一只    猫   坐"), "一只 猫 坐")

    def test_think_plus_normalize_combined(self):
        out = g._normalize_polished("<think>思考</think>正文\n_abc123")
        self.assertEqual(out, "正文")

    def test_footer_signature_requires_newline(self):
        # 行内下划线不算尾注签名，不应被误删
        out = g._normalize_polished("变量名是 _config_value")
        self.assertEqual(out, "变量名是 _config_value")


class TestBuildOpenAIChatEndpoint(unittest.TestCase):
    def test_v1_suffix(self):
        self.assertEqual(
            g._build_openai_chat_endpoint("https://x.com/v1"),
            "https://x.com/v1/chat/completions",
        )

    def test_trailing_slash_normalized(self):
        self.assertEqual(
            g._build_openai_chat_endpoint("https://x.com/v1/"),
            "https://x.com/v1/chat/completions",
        )

    def test_full_chat_completions_passthrough(self):
        url = "https://x.com/custom/chat/completions"
        self.assertEqual(g._build_openai_chat_endpoint(url), url)

    def test_dashscope_compatible_mode_without_v1(self):
        self.assertEqual(
            g._build_openai_chat_endpoint("https://dashscope.aliyuncs.com/compatible-mode"),
            "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
        )

    def test_dashscope_compatible_mode_with_v1(self):
        self.assertEqual(
            g._build_openai_chat_endpoint(
                "https://dashscope.aliyuncs.com/compatible-mode/v1"
            ),
            "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
        )

    def test_bare_domain_gets_v1(self):
        self.assertEqual(
            g._build_openai_chat_endpoint("https://x.com"),
            "https://x.com/v1/chat/completions",
        )

    def test_blank_input(self):
        self.assertEqual(g._build_openai_chat_endpoint(""), "/v1/chat/completions")


class TestCandidateTextModels(unittest.TestCase):
    def test_qwen_vl_flash_falls_back_to_plus(self):
        self.assertEqual(
            g._candidate_text_models("qwen3-vl-flash"),
            ["qwen3-vl-flash", "qwen3-vl-plus"],
        )

    def test_qwen_vl_named_variant_falls_back_to_plus(self):
        self.assertEqual(
            g._candidate_text_models("qwen3-vl-235b"),
            ["qwen3-vl-235b", "qwen3-vl-plus"],
        )

    def test_plus_has_no_duplicate_fallback(self):
        self.assertEqual(g._candidate_text_models("qwen3-vl-plus"), ["qwen3-vl-plus"])

    def test_unrelated_model_single_candidate(self):
        self.assertEqual(g._candidate_text_models("gpt-4o-mini"), ["gpt-4o-mini"])
        self.assertEqual(g._candidate_text_models("gemini-3.5-flash-lite"),
                         ["gemini-3.5-flash-lite"])


class TestExtractHttpErrorMessage(unittest.TestCase):
    def _make_error(self, status: int, body: bytes):
        return urllib.error.HTTPError(
            "https://example.com/x", status, "Status", {}, io.BytesIO(body)
        )

    def test_openai_style_error_json(self):
        err = self._make_error(401, json.dumps({"error": {"message": "API key invalid"}}).encode())
        msg = g._extract_http_error_message(err, "自定义 API 报错")
        self.assertIn("401", msg)
        self.assertIn("API key invalid", msg)

    def test_google_style_error_json(self):
        err = self._make_error(400, json.dumps({"error": {"message": "model not found"}}).encode())
        msg = g._extract_http_error_message(err, "Gemini API 错误")
        self.assertIn("model not found", msg)

    def test_non_json_body_kept_raw(self):
        err = self._make_error(500, b"gateway exploded")
        msg = g._extract_http_error_message(err, "X")
        self.assertIn("500", msg)
        self.assertIn("gateway exploded", msg)

    def test_error_field_as_string(self):
        err = self._make_error(429, json.dumps({"error": "rate limited"}).encode())
        msg = g._extract_http_error_message(err, "X")
        self.assertIn("rate limited", msg)


if __name__ == "__main__":
    unittest.main()
