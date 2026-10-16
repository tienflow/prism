#!/usr/bin/env python3
"""
TypeSafe Jev 判定层：为「画风 + 比例智能配参」提供类型化选择。

Jev 是 System One 判定模型，**不生成文本**：只从调用方给定的选项集合里
返回选中项与完整概率分布，因此无需 JSON 解析容错，也不会改写选项名。

⚠️ 网络硬前提：api.typesafe.ai 按出口地区封锁。中国大陆出口直连稳定返回
   451 `Typesafe is not available in your region`，**必须经海外 HTTP 代理**
   （复用 gemini 同一条 7890 链路）。详见记忆库 lessons/typesafe-region-block-451。
"""

import asyncio
import hashlib
import http.client
import json
import os
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

from gemini_engine import get_proxy

TYPESAFE_HOST = "api.typesafe.ai"
TYPESAFE_PATH = "/v1/systemone"
TYPESAFE_MODEL = "jev-latest"
REQUEST_TIMEOUT = 15
CACHE_LIMIT = 32

CONFIG_FILE = Path.home() / "Pictures/Prism/ai_config.json"

_conn: Optional[http.client.HTTPSConnection] = None
_conn_key: Tuple[str, int] = ("", 0)
_cache: Dict[str, Dict[str, Any]] = {}
# http.client 连接非线程安全，且 judge_params 走 to_thread —— 串行化保护
_LOCK = asyncio.Lock()


def get_typesafe_key() -> str:
    """TypeSafe API Key：环境变量优先，其次 ~/Pictures/Prism/ai_config.json。"""
    key = (os.environ.get("TYPESAFE_API_KEY") or "").strip()
    if key:
        return key
    try:
        data = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
        return str(data.get("typesafe_api_key", "")).strip()
    except Exception:
        return ""


def _proxy_parts() -> Tuple[str, int]:
    raw = (get_proxy() or "").strip()
    if "://" in raw:
        raw = raw.split("://", 1)[1]
    raw = raw.split("/", 1)[0]
    host, _, port = raw.partition(":")
    try:
        return (host or "127.0.0.1", int(port or 7890))
    except ValueError:
        return ("127.0.0.1", 7890)


def _get_conn() -> http.client.HTTPSConnection:
    """复用一条 CONNECT 隧道连接：每次新建连接要多付约 500ms TLS 握手。"""
    global _conn, _conn_key
    host, port = _proxy_parts()
    if _conn is not None and _conn_key == (host, port):
        return _conn
    conn = http.client.HTTPSConnection(host, port, timeout=REQUEST_TIMEOUT)
    conn.set_tunnel(TYPESAFE_HOST, 443)
    _conn, _conn_key = conn, (host, port)
    return conn


def _reset_conn() -> None:
    global _conn
    try:
        if _conn is not None:
            _conn.close()
    except Exception:
        pass
    _conn = None


def _post(payload: Dict[str, Any], api_key: str) -> Dict[str, Any]:
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "Content-Length": str(len(body)),
    }
    last_err: Optional[Exception] = None
    for _attempt in (1, 2):
        conn = _get_conn()
        try:
            conn.request("POST", TYPESAFE_PATH, body=body, headers=headers)
            resp = conn.getresponse()
            raw = resp.read().decode("utf-8")
            if resp.status == 200:
                return json.loads(raw)
            if resp.status == 451:
                raise RuntimeError("TypeSafe 在当前网络出口不可用（451 地区封锁），请确认代理可用")
            if resp.status in (401, 403):
                raise RuntimeError(f"TypeSafe 鉴权失败 (HTTP {resp.status})，请检查 API Key")
            if resp.status in (429, 529):
                last_err = RuntimeError(f"TypeSafe 限流或过载 (HTTP {resp.status})")
                _reset_conn()
                continue
            raise RuntimeError(f"TypeSafe 返回异常 (HTTP {resp.status}): {raw[:120]}")
        except RuntimeError:
            raise
        except Exception as e:  # 连接层异常：重建连接后重试一次
            last_err = e
            _reset_conn()
    raise RuntimeError(f"TypeSafe 请求失败: {last_err}")


def _pick(answer: Any, valid: set) -> Optional[Dict[str, Any]]:
    """从 Choice 答案中取出选中项、置信度与次选（过滤越界选项）。"""
    if not isinstance(answer, dict):
        return None
    probs = {k: float(v) for k, v in (answer.get("probabilities") or {}).items() if k in valid}
    choice = answer.get("choice")
    if choice not in valid:
        if not probs:
            return None
        choice = max(probs, key=lambda k: probs[k])
    ordered = sorted(probs.items(), key=lambda kv: -kv[1])
    runner_up = next(
        ({"choice": name, "probability": p} for name, p in ordered if name != choice),
        None,
    )
    return {
        "choice": choice,
        "confidence": float(answer.get("confidence") or 0.0),
        "runner_up": runner_up,
    }


def _ask(description: str, styles: Dict[str, str], aspects: Dict[str, str],
         has_reference_image: bool, api_key: str) -> Dict[str, Any]:
    questions = {
        "style": {
            "type": "choice",
            "instructions": (
                "根据用户的画面描述，为 AI 生图引擎选择最贴切的画风预设。"
                "只依据描述本身的题材、氛围与视觉期待判断，不要因为描述简短就保守选择。"
            ),
            "criteria": styles,
        },
        "aspect_ratio": {
            "type": "choice",
            "instructions": (
                "根据用户的画面描述，选择最合适的画幅比例。"
                "判断依据是画面的主体形态与用途（横向场景 / 竖向人像 / 方形单品）。"
            ),
            "criteria": aspects,
        },
        "needs_polish": {
            "type": "noul",
            "instructions": "这段描述是否过于简短笼统，缺少足够的画面信息（主体、环境、光影、构图）？",
            "criteria": {
                "true": "只有主体或极少信息，直接生图效果会很随机",
                "false": "已经包含主体与足够的环境或风格信息",
            },
        },
    }

    state: Dict[str, Any] = {
        "description": description,
        "has_reference_image": has_reference_image,
        "note": "用户新画布的主体描述，尚未指定画风与比例",
    }

    res = _post({"state": state, "model": TYPESAFE_MODEL, "questions": questions}, api_key)
    answers = res.get("answers") or {}

    style = _pick(answers.get("style"), set(styles.keys()))
    aspect = _pick(answers.get("aspect_ratio"), set(aspects.keys()))
    if style is None or aspect is None:
        raise RuntimeError("Jev 未返回有效的画风或比例判定")

    polish = answers.get("needs_polish") or {}
    return {
        "style": style,
        "aspect_ratio": aspect,
        "needs_polish": float(polish.get("noul") or 0.0),
        "usage": res.get("usage") or {},
    }


async def judge_params(
    description: str,
    styles: Dict[str, str],
    aspects: Dict[str, str],
    has_reference_image: bool = False,
) -> Dict[str, Any]:
    """对主体描述做画风 / 比例 / 是否需润色的判定。

    永远返回 dict；失败时为 {"success": False, "error": ...}，由 UI 侧静默降级。
    """
    description = (description or "").strip()
    if not description:
        return {"success": False, "error": "请先填写画面描述"}
    if not styles or not aspects:
        return {"success": False, "error": "缺少画风或比例选项定义"}

    api_key = get_typesafe_key()
    if not api_key:
        return {"success": False, "error": "未配置 TypeSafe Jev API Key，请在偏好设置中填写"}

    ck = hashlib.sha1(
        json.dumps([description, sorted(styles.items()), sorted(aspects.items()), has_reference_image],
                   ensure_ascii=False).encode("utf-8")
    ).hexdigest()
    cached = _cache.get(ck)
    if cached is not None:
        return dict(cached, cached=True)

    try:
        async with _LOCK:
            result = await asyncio.to_thread(
                _ask, description, styles, aspects, has_reference_image, api_key
            )
    except Exception as e:
        return {"success": False, "error": str(e)}

    result["success"] = True
    result["model"] = TYPESAFE_MODEL
    result["cached"] = False
    if len(_cache) >= CACHE_LIMIT:
        _cache.pop(next(iter(_cache)))
    _cache[ck] = result
    return result
