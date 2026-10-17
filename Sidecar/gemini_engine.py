#!/usr/bin/env python3
"""
Gemini Web Image Generation Engine.
Interfaces with gemini.google.com via session cookies and reverse-engineered API.
"""

import asyncio
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
from typing import Callable, Optional, List, Dict, Any

from gemini_webapi import GeminiClient
from gemini_webapi.constants import AccountStatus
from optimizer import compress_image

SIDECAR_DIR = Path(__file__).resolve().parent
# 出厂种子文件（随 Bundle 分发，只读兜底，绝不在此写回）
DEFAULT_ENV_FILE = SIDECAR_DIR / ".env"
USER_DIR = Path.home() / "Pictures/Prism"
# 运行期凭据缓存：写用户目录而非 App Bundle。
# 写 Bundle 会破坏代码签名（TCC/钥匙串反复授权），且分发包会带出现实时 Cookie。
USER_ENV_FILE = USER_DIR / "credentials.env"
OUTPUT_DIR = USER_DIR
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

REQUEST_TIMEOUT = 120
RETRY_BACKOFF_SEC = 3

# 单张全尺寸 PNG 的保守落盘估算（MB），用于生成前磁盘空间预检
_DISK_MB_PER_IMAGE = 30
_DISK_MIN_FREE_MB = 150


def _month_output_dir(now: Optional[float] = None) -> Path:
    """新图按生成月份分目录：~/Pictures/Prism/YYYY-MM/。

    旧文件保持原地平铺不动；Swift 侧以递归扫描发现全部图片。
    """
    month = time.strftime("%Y-%m", time.localtime(now or time.time()))
    target = OUTPUT_DIR / month
    target.mkdir(parents=True, exist_ok=True)
    return target


def _ensure_disk_space(image_count: int = 1) -> None:
    """下载/落盘前预检剩余空间，不足时直接失败（避免存了半批残图）。"""
    required_mb = _DISK_MIN_FREE_MB + _DISK_MB_PER_IMAGE * max(1, image_count)
    free_mb = shutil.disk_usage(str(OUTPUT_DIR)).free // (1024 * 1024)
    if free_mb < required_mb:
        raise RuntimeError(
            f"磁盘空间不足：当前仅剩 {free_mb}MB 可用，本次生图至少需要 {required_mb}MB，请清理后重试"
        )

# 多轮会话池：session_id -> {"client", "chat", "created_at", "updated_at", "turns"}
# 会话内保持上下文，用于「继续修改」式对话改图；超时或超量自动回收。
#
# 🔴 会话必须跨 Sidecar 重启存活：多轮改图的语义是「在同一条会话里继续」，
# 而 Sidecar 每次打包/重启都会清空本内存池——若只存内存，用户的「继续修改」
# 会在不知情中新开会话（模型不记得上一轮）。因此把远端会话标识
# （cid / rid / rcid）持久化到磁盘，重启后用它们重新附着同一条远端会话线。
_SESSIONS: Dict[str, Dict[str, Any]] = {}
SESSION_TTL_SEC = 8 * 60 * 60   # 内存池窗口 8 小时；磁盘记录无 TTL，能否续由远端会话有效性决定
MAX_LIVE_SESSIONS = 16
# 磁盘上保留的会话标识条数（无 TTL，按最后活跃时间裁剪）——只裁剪磁盘账本，
# 不影响内存池；目的是「隔天再改也能续上同一条远端会话」。
MAX_PERSISTED_SESSIONS = 100
_SESSIONS_FILE = Path.home() / "Pictures" / "Prism" / ".edit_sessions.json"


def _session_fingerprint(chat: Any) -> Dict[str, str]:
    return {
        "cid": getattr(chat, "cid", "") or "",
        "rid": getattr(chat, "rid", "") or "",
        "rcid": getattr(chat, "rcid", "") or "",
    }


def _persist_sessions() -> None:
    """把存活会话的远端标识落盘（原子写，供 Sidecar 重启后重新附着）。

    🔴 必须与磁盘既有记录**合并**，不能整体覆盖：内存池按 TTL / 上限淘汰会话，
    整体覆盖会把被淘汰会话的 cid/rid/rcid 永久抹掉——远端会话还活在 Gemini 里，
    本地却再也续不上，用户下次改图只能新开一条（表现为 Gemini 侧又一条会话）。
    """
    existing = _load_session_meta()
    out: Dict[str, Any] = {}
    for sid, s in _SESSIONS.items():
        fp = _session_fingerprint(s.get("chat"))
        if not fp["cid"]:
            continue
        fp["turns"] = int(s.get("turns", 0))
        fp["updated_at"] = s.get("updated_at", time.time())
        out[sid] = fp

    # 内存池已淘汰、但磁盘上仍可续接的旧会话：保留，不删除
    for sid, meta in existing.items():
        if sid not in out and isinstance(meta, dict) and meta.get("cid"):
            out[sid] = meta

    # 磁盘记录无 TTL，但不能无限增长：按最后活跃时间保留最近若干条
    if len(out) > MAX_PERSISTED_SESSIONS:
        kept = sorted(
            out.items(),
            key=lambda kv: float((kv[1] or {}).get("updated_at") or 0),
            reverse=True,
        )[:MAX_PERSISTED_SESSIONS]
        out = dict(kept)

    try:
        _SESSIONS_FILE.parent.mkdir(parents=True, exist_ok=True)
        tmp = _SESSIONS_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8")
        tmp.replace(_SESSIONS_FILE)
    except Exception:
        pass


def _load_session_meta() -> Dict[str, Any]:
    try:
        return json.loads(_SESSIONS_FILE.read_text(encoding="utf-8")) or {}
    except Exception:
        return {}


def _drop_session_meta(session_id: str) -> None:
    meta = _load_session_meta()
    if meta.pop(session_id or "", None) is not None:
        try:
            _SESSIONS_FILE.write_text(json.dumps(meta, ensure_ascii=False, indent=1), encoding="utf-8")
        except Exception:
            pass

def extract_chrome_cookies():
    """Extract and decrypt __Secure-1PSID and __Secure-1PSIDTS from Chrome on macOS."""
    if sys.platform != "darwin":
        return None, None

    cookie_db = Path.home() / "Library/Application Support/Google/Chrome/Default/Cookies"
    if not cookie_db.exists():
        alt_db = Path.home() / "Library/Application Support/Google/Chrome/Profile 1/Cookies"
        if alt_db.exists():
            cookie_db = alt_db
        else:
            return None, None

    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        from cryptography.hazmat.backends import default_backend
    except ImportError:
        return None, None

    try:
        cmd = ["security", "find-generic-password", "-w", "-s", "Chrome Safe Storage"]
        res = subprocess.run(cmd, capture_output=True, text=True, check=True)
        password = res.stdout.strip().encode("utf-8")
    except Exception:
        return None, None

    key = hashlib.pbkdf2_hmac("sha1", password, b"saltysalt", 1003, 16)

    with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as tmp_file:
        tmp_path = tmp_file.name

    try:
        shutil.copy2(str(cookie_db), tmp_path)
        conn = sqlite3.connect(tmp_path)
        c = conn.cursor()
        c.execute("""
            SELECT name, encrypted_value 
            FROM cookies 
            WHERE host_key LIKE '%google.com' 
              AND name IN ('__Secure-1PSID', '__Secure-1PSIDTS')
        """)
        rows = c.fetchall()
        conn.close()
    except Exception:
        return None, None
    finally:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)

    cookies = {}
    for name, enc_val in rows:
        if not enc_val.startswith(b"v10") or len(enc_val) <= 3:
            continue
        try:
            data = enc_val[3:]
            cipher = Cipher(algorithms.AES(key), modes.CBC(b" " * 16), backend=default_backend())
            decryptor = cipher.decryptor()
            dec = decryptor.update(data) + decryptor.finalize()
            pad_len = dec[-1]
            if 1 <= pad_len <= 16:
                dec = dec[:-pad_len]
            if len(dec) > 32:
                dec = dec[32:]
            val = dec.decode("utf-8", errors="ignore")
            if val:
                cookies[name] = val
        except Exception:
            pass

    return cookies.get("__Secure-1PSID"), cookies.get("__Secure-1PSIDTS")

def save_credentials(psid: str, psidts: str) -> bool:
    """运行期凭据缓存落到用户目录（原子写 + 0600），不触碰 App Bundle。"""
    try:
        USER_DIR.mkdir(parents=True, exist_ok=True)
        content = (
            "# Prism 运行期 Google 凭据缓存（自动生成，可安全删除）\n"
            f'GEMINI_SECURE_1PSID="{psid}"\n'
            f'GEMINI_SECURE_1PSIDTS="{psidts}"\n'
        )
        tmp_file = USER_ENV_FILE.with_name(USER_ENV_FILE.name + ".tmp")
        with open(tmp_file, "w", encoding="utf-8") as f:
            f.write(content)
        os.chmod(tmp_file, 0o600)
        os.replace(tmp_file, USER_ENV_FILE)
        return True
    except Exception:
        return False

def _read_env_file(path: Path):
    """从 .env 风格文件读取一对凭据。"""
    psid = psidts = None
    try:
        if not path.exists():
            return None, None
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("GEMINI_SECURE_1PSID="):
                    psid = line.split("=", 1)[1].strip().strip('"').strip("'")
                elif line.startswith("GEMINI_SECURE_1PSIDTS="):
                    psidts = line.split("=", 1)[1].strip().strip('"').strip("'")
    except Exception:
        return None, None
    return (psid or None), (psidts or None)

def get_credentials(auto_extract: bool = True):
    """凭据读取优先级：环境变量 → 用户目录缓存 → Bundle 出厂种子 → Chrome 实时 Cookie。

    注意：缓存只做「读取优先」，不再无条件信任——调用方须用
    `GeminiEngine._build_verified_client()` 校验登录态，失效时回退 Chrome。
    """
    psid = os.environ.get("GEMINI_SECURE_1PSID")
    psidts = os.environ.get("GEMINI_SECURE_1PSIDTS")

    if not psid or not psidts:
        cached_psid, cached_psidts = _read_env_file(USER_ENV_FILE)
        if cached_psid and cached_psidts:
            psid, psidts = cached_psid, cached_psidts

    if not psid or not psidts:
        seed_psid, seed_psidts = _read_env_file(DEFAULT_ENV_FILE)
        if seed_psid and seed_psidts:
            psid, psidts = seed_psid, seed_psidts

    if (not psid or not psidts) and auto_extract:
        chrome_psid, chrome_psidts = extract_chrome_cookies()
        if chrome_psid and chrome_psidts:
            psid, psidts = chrome_psid, chrome_psidts
            save_credentials(psid, psidts)

    return psid, psidts

def get_proxy():
    return (
        os.environ.get("HTTPS_PROXY")
        or os.environ.get("HTTP_PROXY")
        or os.environ.get("ALL_PROXY")
        or "http://127.0.0.1:7890"
    )

AUTH_EXPIRED_MESSAGE = (
    "Google 登录凭据已失效（网页端返回未认证）。请在「偏好设置 → AI 配置」重新登录，"
    "或先在 Chrome 登录 gemini.google.com 后点「从 Chrome 同步凭据」再重试。"
)

# 网页端在「已登录但当前账号/地区无生图能力」时返回的文本应答特征
NO_IMAGE_HINTS = (
    "您登录了吗", "登录了吗", "无法为您创建任何图片", "尚未开通图片创建功能",
    "can't create images", "cannot create images", "unable to create images",
)


def _status_reason(status: int) -> str:
    try:
        st = AccountStatus(status)
    except ValueError:
        return f"Google 账号状态异常（{status}）"
    if st == AccountStatus.UNAUTHENTICATED:
        return AUTH_EXPIRED_MESSAGE
    if st == AccountStatus.LOCATION_REJECTED:
        return "当前出口 IP 所在地区被 Google 拒绝（生图不可用），请切换代理节点后重试。"
    if st in (AccountStatus.ACCOUNT_REJECTED, AccountStatus.ACCOUNT_REJECTED_BY_GUARDIAN,
              AccountStatus.ACCOUNT_UNTRUSTED):
        return "该 Google 账号被限制使用（可能需要人工申诉或更换账号）。"
    if st in (AccountStatus.TOS_PENDING, AccountStatus.TOS_OUT_OF_DATE):
        return "该 Google 账号需先在网页端同意最新服务条款。"
    return f"Google 账号暂不可用（{st.name}），请稍后重试。"


def _explain_no_image(text: str) -> str:
    """把网页端「无法生图」的文本应答翻译成可执行的诊断信息。"""
    if any(h in text for h in NO_IMAGE_HINTS):
        return (
            "网页端拒绝执行生图（登录态失效或该账号/地区未开通图片创建能力）。"
            "请先尝试「从 Chrome 同步凭据」；若仍失败，多为代理出口地区不受支持，请更换节点。"
        )
    return ""


def _strip_think(text: str) -> str:
    """剥掉思考型模型输出里的 <think>…</think> 段与思考前后缀。

    网关若忽略 enable_thinking 参数，思考内容会混进正文并污染提示词——
    请求侧关思考 + 响应侧剥除，双保险。
    """
    import re
    t = (text or "")
    # 成对的 <think>…</think>（可能多个，取最后一个之后的内容即可——思考总在最前）
    if "</think>" in t:
        t = t.split("</think>")[-1]
    t = re.sub(r"<think>\s*$", "", t.strip())
    return t.strip()


def _normalize_polished(text: str) -> str:
    """润色结果归一化：剥思考段、去网页端尾注、合成单段、去首尾引号与多余空白。"""
    import re
    t = _strip_think(text)
    t = re.sub(r"[\r\n]+_\w+.*$", "", t)
    t = re.sub(r"[\r\n]+", " ", t)
    t = t.strip().strip('"').strip("“”").strip()
    t = re.sub(r"\s{2,}", " ", t)
    return t


# 轻量文本任务（润色 / 负面词 / 配参）的默认模型。
# 2026-10 官方模型页：Gemini 2.5 系列仅对存量用户开放，新项目官方推荐
# 3.5 Flash-Lite 或 3.8 Flash；润色这类高吞吐短文本任务取 Lite。
DEFAULT_TEXT_MODEL = "gemini-3.5-flash-lite"


def _build_openai_chat_endpoint(base_url: str) -> str:
    """把用户填的 base_url 归一化为 OpenAI 兼容的 chat/completions 端点。

    兼容：已写到 /chat/completions、停在 /v1、阿里 /compatible-mode、裸域名四种形态。
    """
    clean_base = (base_url or "").strip().rstrip("/")
    if clean_base.endswith("/chat/completions"):
        return clean_base
    if clean_base.endswith("/v1"):
        return f"{clean_base}/chat/completions"
    if "/compatible-mode" in clean_base and not clean_base.endswith("/v1"):
        return f"{clean_base}/v1/chat/completions"
    return f"{clean_base}/v1/chat/completions"


def _candidate_text_models(model_name: str) -> List[str]:
    """404 候选：部分网关上 qwen3-vl-flash 型号不存在，自动回退到同系 plus。"""
    candidates = [model_name]
    if "qwen3-vl-flash" in model_name:
        candidates.append("qwen3-vl-plus")
    elif "qwen3-vl" in model_name and not model_name.endswith("-plus"):
        candidates.append("qwen3-vl-plus")
    return candidates


def _extract_http_error_message(err: Any, fallback: str) -> str:
    """从 HTTPError 响应体里提取人类可读的错误信息（OpenAI 风格 {error:{message}}）。"""
    try:
        raw = err.read().decode("utf-8")
    except Exception:
        return f"{fallback} (HTTP {getattr(err, 'code', '?')})"
    try:
        j = json.loads(raw)
        e = j.get("error")
        msg = e.get("message", raw[:160]) if isinstance(e, dict) else raw[:160]
    except Exception:
        msg = raw[:160]
    return f"{fallback} (HTTP {getattr(err, 'code', '?')}): {msg}"


# —— 文本对话统一通道（同步阻塞实现，调用方经 run_in_executor 包装）——
# 全工程四份调用（润色 / 负面词 / 连接测试 / 图像描述）共用端点归一化、
# 候选模型 404 自适应与错误体解析，避免逻辑漂移。

def _post_openai_chat_blocking(
    api_key: str,
    req_url: str,
    messages: List[Dict[str, Any]],
    model_candidates: List[str],
    *,
    timeout: int,
    temperature: Optional[float] = 0.7,
    extra_body: Optional[Dict[str, Any]] = None,
    max_tokens: Optional[int] = None,
) -> tuple:
    """单次或候选模型序列的 OpenAI 兼容 chat/completions 调用（阻塞）。

    返回 (content, 实际命中的模型名)；404 自动切换候选；思考型模型输出经 _strip_think。
    必须在线程池执行（urllib 阻塞）。
    """
    import urllib.request
    import urllib.error

    last_err = None
    for m in model_candidates:
        body: Dict[str, Any] = {"model": m, "messages": messages}
        if temperature is not None:
            body["temperature"] = temperature
        if max_tokens is not None:
            body["max_tokens"] = max_tokens
        if extra_body:
            body.update(extra_body)
        post_body = json.dumps(body).encode("utf-8")
        req = urllib.request.Request(req_url, data=post_body, headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        })
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                res = json.loads(resp.read().decode("utf-8"))
                return _strip_think(res["choices"][0]["message"]["content"]), m
        except urllib.error.HTTPError as e:
            last_err = e
            if e.code == 404 and m != model_candidates[-1]:
                continue
            raise RuntimeError(_extract_http_error_message(e, "自定义 API 报错"))
        except urllib.error.URLError as e:
            raise RuntimeError(f"自定义 API 连接失败: {e.reason}")
    if last_err is not None:
        raise RuntimeError(_extract_http_error_message(last_err, "自定义 API 报错"))
    raise RuntimeError("自定义 API 未返回有效内容")


def _post_gemini_native_blocking(
    api_key: str,
    base_url: str,
    model_name: str,
    text: str,
    *,
    timeout: int,
    extra_body: Optional[Dict[str, Any]] = None,
) -> str:
    """Gemini 原生 v1beta generateContent 单次调用（阻塞）。必须在线程池执行。"""
    import urllib.request
    import urllib.error

    req_url = (
        f"{base_url.rstrip('/')}/v1beta/models/{model_name}"
        f":generateContent?key={api_key}"
    )
    body: Dict[str, Any] = {"contents": [{"parts": [{"text": text}]}]}
    if extra_body:
        body.update(extra_body)
    req = urllib.request.Request(
        req_url,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            res = json.loads(resp.read().decode("utf-8"))
            return res["candidates"][0]["content"]["parts"][0]["text"].strip()
    except urllib.error.HTTPError as e:
        raise RuntimeError(_extract_http_error_message(e, "Gemini API 错误"))
    except Exception as e:
        raise RuntimeError(f"Gemini API 请求失败: {e}")


# —— 润色指令（2026-10-16）——
# mode="describe"     把简短描述扩写成**完整画面描述**（新画布的主体描述用）
# mode="instruction"  把「基于现有画面的修改指令」写得更精确、更可执行（历史上下文用）
#
# 两种模式的产出形态完全不同，混用会出错：把修改指令当完整描述扩写，
# 会凭空编造出与原画面无关的整幅场景。
# ⚠️ few-shot 必须配防泄漏护栏：输入过于简略或语义不明时，模型会直接照抄示例内容
#    （2026-10-16 实测：输入"改成夜景"得到柴犬示例的原文）。

# 共同禁令：只写看得见的东西
_POLISH_BAN = (
    "【只写看得见的东西】允许且仅允许描述：主体（外形、姿态、表情、服饰、材质）、动作、"
    "所在环境与其中的具体物件、光源方向与光比、色相与色调、表面质感、镜头景别/焦距/景深、视角。\n\n"
    "【禁止】\n"
    "1. 评价词与空词：「大师级、完美、高级、极致、极具张力、电影级、艺术感、震撼、精致、"
    "细腻丰富、唯美、逼真、高画质、8k、超清」——这些不给画面任何新信息，只稀释主体权重。\n"
    "2. 情绪与氛围词：「温馨、宁静、壮丽、诗意、哀愁、梦幻、氛围感、高级感、…感、…气息」。"
    "若想表达暖意，就写「暖黄灯光从左侧照入」；想表达梦幻，就写「柔光溢出、边缘发亮」——"
    "把感受翻译成可见的光与物。\n"
    "3. 比喻与拟人：禁止「宛如、仿佛、犹如、像…一样」。\n"
    "4. 元陈述：禁止「画面采用…构图」「色彩以…为基调」「光影勾勒出…」「镜头采用…」这类影评语气，"
    "直接写画面内容本身（写「中景，浅景深，85mm」，不要写「镜头采用中景构图」）。\n"
    "5. 整体画风：画风由外部参数单独控制，**不要在提示词里复述风格名称或同类风格形容词**。\n"
    "6. 负面约束与水印提示：禁止在正文里出现「不要出现…」「严禁…」「无水印」「无文字」等句子，"
    "负面排除由外部参数单独控制。\n\n"
)

# 防示例泄漏护栏（两种模式都挂）
_POLISH_GUARD = (
    "\n【示例的作用 —— 最高优先级，必须遵守】下面的示例**只用来说明写法与格式**。"
    "严禁输出示例中的主体、场景或任何词句，严禁照抄示例内容。"
    "你的输出必须**完全以用户描述为准**。\n\n"
    "特别注意——若输入**不是一段完整的画面描述**（例如：修改指令「改成夜晚」、"
    "单个词「猫」、碎片化词组、或语义不明的文字），**绝不能输出示例中的内容**，"
    "也绝不能引入新的主体或场景：\n"
    "· 只围绕输入里**明确出现**的名词组织画面；\n"
    "· 输入里没有可识别的主体时，只做最小改写，或原样返回输入，不要补全、不要猜测；\n"
    "· 判断标准很简单：你写的每一句，都应该能反向指出它来自输入的哪个词。\n"
)

_POLISH_DESCRIBE_SYSTEM = (
    "你是文生图提示词工程师。把用户的简短描述扩写成**直接喂给图像生成模型**的中文提示词。\n\n"
    + _POLISH_BAN +
    "【结构】第一句必须是「主体 + 动作 + 所在环境」（主体优先，先立住再修饰）；"
    "第二句起只放视觉参数（光、色、质感、镜头、景深），不要回头再补主体。\n\n"
    "【长度】整段 60~140 字。密度优先于长度：只保留能改变画面的信息，不堆同义词。\n"
    "【输出】只输出提示词正文，单段，无换行、无标题、无编号、无引号、无任何解释。\n\n"
    "示例——\n"
    "用户描述：一只戴着复古飞行员墨镜的柴犬，漂浮在浩瀚星空的霓虹气泡中\n"
    "输出：一只戴着复古飞行员墨镜的柴犬漂浮在深蓝色星空中，四肢舒展，毛发根根分明，"
    "周围环绕大小不一的霓虹气泡，气泡表面泛出粉蓝渐变反光。中景、浅景深，"
    "霓虹光自下方打在犬只腹部，冷蓝与品红强对比，胶片颗粒。"
    + _POLISH_GUARD
)

_POLISH_INSTRUCTION_SYSTEM = (
    "你是文生图的改图指令工程师。用户给的是一条**基于现有画面的修改指令**，"
    "**不是**完整画面描述——你手上有原图，只需要把这条改动写清楚。\n\n"
    + _POLISH_BAN +
    "【指令形态（本模式特有，优先于上表的结构要求）】\n"
    "1. 保持指令形态：用改动导向的短句（「把…改为…」「增加…」「移除…」「调整…」），"
    "**严禁**扩写成完整画面描述（不要写成一整幅画）。\n"
    "2. 只描述**要改动的部分**及其随之变化的视觉后果（光、色、质感），"
    "**不要复述未改动的主体**（那是原图里已有的，写了会被当成要重画）。\n"
    "3. 不得引入与本次改动无关的新主体、新场景、新人物。\n"
    "4. 长度 30~80 字，单段，无换行、无标题、无编号、无引号、无解释。\n\n"
    "示例——\n"
    "用户指令：改成夜晚\n"
    "输出：把环境改为夜景，天空换成深蓝色，光线改为人造光源从右侧打入，地面出现暖黄灯光反射，整体色温转冷。\n\n"
    "用户指令：加一顶帽子\n"
    "输出：给主体戴上一顶宽檐草帽，帽檐在额头投下浅浅阴影，帽身材质为编织草纹。\n"
    + _POLISH_GUARD
)


_DESCRIBE_SYSTEM_INSTRUCTION = (
    "你是一位专业的图像描述专家。"
    "请为这张图片生成详细描述，所有内容必须使用中文输出，包括：主体内容、构图方式、色彩基调、光影效果、艺术风格、氛围情感。"
    "最后给出一段可以直接用于 AI 生图的中文提示词。"
    "输出格式：\n【图像描述】\n[中文详细描述]\n\n【生图提示词】\n[中文提示词]"
)


class GeminiEngine:
    def __init__(self):
        self.client: Optional[GeminiClient] = None

    async def _new_client(self, psid: str, psidts: str, timeout: int = REQUEST_TIMEOUT) -> GeminiClient:
        """创建客户端：先走代理，代理不通时回退直连。"""
        client = GeminiClient(
            secure_1psid=psid, secure_1psidts=psidts, proxy=get_proxy(), timeout=timeout,
        )
        try:
            await client.init()
        except Exception:
            client = GeminiClient(
                secure_1psid=psid, secure_1psidts=psidts, proxy=None, timeout=timeout,
            )
            await client.init()
        return client

    @staticmethod
    def _account_status(client: GeminiClient) -> int:
        try:
            return int(client.account_status)
        except Exception:
            return -1

    async def _build_verified_client(self, timeout: int = REQUEST_TIMEOUT,
                                     allow_heal: bool = True) -> GeminiClient:
        """建连并**校验登录态**；缓存凭据失效时自动用 Chrome 实时 Cookie 自愈。

        这是修复「缓存 Cookie 过期后静默退化为文本应答」的关键路径：
        凭据存在 ≠ 凭据有效，必须看 account_status。
        `allow_heal=False` 用于「刚写入一对凭据、只想验证它本身」的场景（登录/同步回验），
        避免自愈逻辑用另一来源的 Cookie 掩盖用户刚提交的那一对。
        """
        psid, psidts = get_credentials(auto_extract=True)
        if not psid or not psidts:
            raise RuntimeError("未找到有效 Google 登录凭据，请在 App 中登录或从 Chrome 同步")

        client = await self._new_client(psid, psidts, timeout)
        status = self._account_status(client)
        if status == int(AccountStatus.AVAILABLE):
            return client

        if not allow_heal:
            raise RuntimeError(_status_reason(status))

        # 缓存失效 → 试 Chrome 实时 Cookie（用户可能在 Chrome 重新登录过）
        chrome_psid, chrome_psidts = extract_chrome_cookies()
        if chrome_psid and chrome_psidts and (chrome_psid, chrome_psidts) != (psid, psidts):
            retry = await self._new_client(chrome_psid, chrome_psidts, timeout)
            if self._account_status(retry) == int(AccountStatus.AVAILABLE):
                save_credentials(chrome_psid, chrome_psidts)
                return retry

        raise RuntimeError(_status_reason(status))

    async def verify_auth(self) -> Dict[str, Any]:
        """真实校验登录态（而非仅检查凭据是否存在）。"""
        psid, psidts = get_credentials(auto_extract=True)
        if not psid or not psidts:
            return {"valid": False, "authenticated": False,
                    "reason": "未找到 Google 登录凭据（环境变量 / 用户缓存 / Chrome 均无）"}
        stored = (psid, psidts)
        try:
            client = await self._build_verified_client(timeout=30)
        except Exception as e:
            return {"valid": False, "authenticated": False, "reason": str(e)}
        # 自愈命中时凭据已落盘到用户缓存，回读以确保展示的是实际生效值
        eff_psid, _ = _read_env_file(USER_ENV_FILE)
        eff_psid = eff_psid or stored[0]
        return {
            "valid": True,
            "authenticated": True,
            "account_status": self._account_status(client),
            "psid_masked": f"{eff_psid[:6]}...{eff_psid[-4:]}" if eff_psid else "",
        }

    async def generate(
        self,
        prompt: str,
        aspect_ratio: str = "1:1",
        negative_prompt: str = "",
        style_context: str = "",
        max_kb: int = 0,
        progress_callback: Optional[Callable[[Dict[str, Any]], Any]] = None,
    ) -> List[str]:
        async def report(stage: str, message: str, extra: Optional[Dict[str, Any]] = None):
            payload = {"stage": stage, "message": message}
            if extra:
                payload.update(extra)
            if progress_callback:
                if asyncio.iscoroutinefunction(progress_callback):
                    await progress_callback(payload)
                else:
                    progress_callback(payload)

        psid, psidts = get_credentials(auto_extract=True)
        if not psid or not psidts:
            await report("error", "未找到有效 Google 登录凭据，请在 App 中登录或同步 Chrome")
            raise RuntimeError("未找到有效 Google 登录凭据，请在 App 中登录或从 Chrome 同步")

        await report("connecting", "正在连接 Google Gemini...")

        try:
            client = await self._build_verified_client()
        except Exception as e:
            await report("error", str(e))
            raise RuntimeError(str(e))

        await report("session_ready", "会话连接成功")

        # 比例与修饰词构造 (必须对 1:1, 16:9, 9:16, 4:3, 3:4 给出强约束)
        clean_prompt = prompt.strip()
        for prefix in ["please generate an image:", "please generate image:", "generate an image:", "create an image:", "生成一张图片：", "生成图片："]:
            if clean_prompt.lower().startswith(prefix):
                clean_prompt = clean_prompt[len(prefix):].strip()

        aspect_directive = ""
        if aspect_ratio == "1:1":
            aspect_directive = "in strict 1:1 square aspect ratio (square composition, equal width and height 1:1, width=height)"
        elif aspect_ratio == "16:9":
            aspect_directive = "in 16:9 wide landscape aspect ratio (cinematic horizontal 16:9 widescreen format)"
        elif aspect_ratio == "9:16":
            aspect_directive = "in 9:16 vertical aspect ratio (tall mobile wallpaper portrait orientation 9:16)"
        elif aspect_ratio == "4:3":
            aspect_directive = "in 4:3 aspect ratio (standard landscape 4:3 format)"
        elif aspect_ratio == "3:4":
            aspect_directive = "in 3:4 aspect ratio (vertical portrait 3:4 format)"
        else:
            aspect_directive = f"in {aspect_ratio} aspect ratio"

        # 风格与负面约束一律用中文自然语言句拼接。
        # 此前的 "Visual style and aesthetic: X" / "(avoid elements: X)" 是
        # Stable Diffusion 系的括号/权重语法，Imagen 网页端不认，等同于噪声。
        full_prompt = clean_prompt.strip().rstrip("。.；;，,")
        if style_context:
            full_prompt = f"{full_prompt}。画面风格：{style_context}"
        if negative_prompt:
            full_prompt = f"{full_prompt}。画面中不要出现：{negative_prompt}"
        full_prompt = f"{full_prompt}。"

        formatted_prompt = f"Please generate an image {aspect_directive}: {full_prompt}"

        await report("submitting", f"已提交提示词，准备渲染...")
        await report("generating", "等待 Imagen 3 原生渲染（通常需 20~50 秒）...")

        output = await client.generate_content(formatted_prompt)

        if not output.candidates:
            await report("error", "Gemini 网页端未返回有效候选结果")
            raise RuntimeError("No candidates returned from Gemini")

        candidate = output.candidates[0]
        if not candidate.generated_images:
            raw_text = (candidate.text or "").strip()
            hint = _explain_no_image(raw_text)
            if hint:
                msg = f"生图异常：{hint}"
            else:
                msg = f"生图异常：网页端未返回图片（可能触发安全审核或文本应答）：{raw_text[:200] or '无详细说明'}"
            await report("error", msg)
            raise RuntimeError(msg)

        total_images = len(candidate.generated_images)
        _ensure_disk_space(total_images)
        await report("downloading", f"已生成 {total_images} 张图片，正在下载全尺寸超清 CDN 原图...", {"total": total_images})

        saved_files = []
        batch_id = hashlib.md5(f"{prompt}_{asyncio.get_event_loop().time()}".encode()).hexdigest()[:8]
        # 新图按生成月份分目录（旧图保留原地）
        target_dir = _month_output_dir()

        with tempfile.TemporaryDirectory() as tmp_dir:
            for idx, img in enumerate(candidate.generated_images, start=1):
                file_name = f"gemini_{batch_id}_{idx}.png"
                file_path = target_dir / file_name

                # 正确调用 save，指定临时目录并拉取 full_size 超清原画
                saved_temp_path = await img.save(path=tmp_dir, full_size=True)
                shutil.copyfile(saved_temp_path, str(file_path))

                if max_kb > 0:
                    compress_image(str(file_path), max_kb=max_kb)

                # 伴生写入元数据，确保任何情况下（即使主 json 丢失）都能 100% 还原提示词
                meta_path = target_dir / f"gemini_{batch_id}_{idx}.json"
                try:
                    meta_path.write_text(json.dumps({
                        "prompt": prompt,
                        "negative_prompt": negative_prompt,
                        "aspect_ratio": aspect_ratio,
                        "style_context": style_context,
                        "created_at": time.time()
                    }, ensure_ascii=False, indent=2), encoding="utf-8")
                except Exception:
                    pass

                saved_files.append(str(file_path.resolve()))
                await report("downloading", f"已保存第 {idx}/{total_images} 张", {"current": idx, "total": total_images, "path": str(file_path)})

        await report("completed", "生图已全部完成", {"files": saved_files, "total": len(saved_files)})
        return saved_files

    async def polish_prompt(
        self,
        prompt: str,
        style: str = "",
        custom_api_key: str = "",
        custom_base_url: str = "",
        custom_model: str = "",
        mode: str = "describe",
    ) -> str:
        """把输入润色成可直接使用的生图文本。

        目标读者是生图模型，不是人类：只允许写「镜头里看得见的东西」，
        禁止评价词、情绪词、比喻与元陈述——后者是噪声，且会与引擎另行拼接的
        `style_context` / `aspect_ratio` 槽位冲突。

        mode="describe"     简短描述 → 完整画面描述（新画布的主体描述）
        mode="instruction"  修改指令 → 更精确的**指令**（历史上下文；切勿当描述扩写）
        """
        system_instruction = (
            _POLISH_INSTRUCTION_SYSTEM if mode == "instruction" else _POLISH_DESCRIBE_SYSTEM
        )

        user_content = prompt.strip()
        if style and style != "无预设":
            user_content += (
                f"（外部已指定的画面风格：{style}。请让整体视觉倾向与之吻合，"
                "但不要把风格名称或同类形容词写进提示词。）"
            )
        user_content += "\n\n（再次提醒：只输出改写后的正文，不得出现示例中的任何主体或内容；输入里没有的主体不要写。）"

        # 1. 自定义 API 优先（统一走 _call_text_api：Google 原生 / OpenAI 兼容）
        if custom_api_key:
            result = await self._call_text_api(
                system_instruction,
                user_content,
                custom_api_key,
                custom_base_url,
                custom_model,
                timeout=15,
                temperature=0.7,
            )
            return _normalize_polished(result)

        # 2. 内置 Gemini Web 凭据兜底 (仅在未配置自定义 API 时使用)
        psid, psidts = get_credentials(auto_extract=True)
        if not psid or not psidts:
            raise RuntimeError("未登录 Google 凭据且未配置自定义 API Key")

        client = await self._build_verified_client(timeout=25)

        instruction = f"{system_instruction}\n\n用户描述：{user_content}"
        output = await client.generate_content(instruction)
        if output and output.candidates:
            c = output.candidates[0]
            if c.text:
                return _normalize_polished(c.text)
        raise RuntimeError("Gemini 未返回有效的润色文本")

    async def polish_prompt_stream(
        self,
        prompt: str,
        style: str = "",
        custom_api_key: str = "",
        custom_base_url: str = "",
        custom_model: str = "",
        mode: str = "describe",
    ):
        """流式润色：异步生成器，逐块 yield 模型原文增量（未做 _normalize_polished）。

        调用方拼齐全文后自行调用 `_normalize_polished`，
        以保证「打字机过程」与「最终落框文本」一致。
        三条链路：自定义 Gemini 原生 SSE / 自定义 OpenAI 兼容 SSE / 内置 webapi 流。
        """
        system_instruction = (
            _POLISH_INSTRUCTION_SYSTEM if mode == "instruction" else _POLISH_DESCRIBE_SYSTEM
        )
        user_content = prompt.strip()
        if style and style != "无预设":
            user_content += (
                f"（外部已指定的画面风格：{style}。请让整体视觉倾向与之吻合，"
                "但不要把风格名称或同类形容词写进提示词。）"
            )
        user_content += "\n\n（再次提醒：只输出改写后的正文，不得出现示例中的任何主体或内容；输入里没有的主体不要写。）"

        # 1. 自定义 API 优先
        if custom_api_key:
            import urllib.request
            import urllib.error
            base_url = (custom_base_url or "").strip() or "https://generativelanguage.googleapis.com"
            model_name = (custom_model or "").strip() or DEFAULT_TEXT_MODEL

            if "googleapis.com" in base_url:
                req_url = (
                    f"{base_url.rstrip('/')}/v1beta/models/{model_name}"
                    f":streamGenerateContent?alt=sse&key={custom_api_key}"
                )
                post_body = json.dumps({
                    "contents": [{"parts": [{"text": f"{system_instruction}\n\n用户描述: {user_content}"}]}]
                }).encode("utf-8")
                req = urllib.request.Request(
                    req_url, data=post_body, headers={"Content-Type": "application/json"}
                )

                def _parse_gemini_sse(line: str):
                    payload = line[5:].strip() if line.startswith("data:") else line.strip()
                    if not payload:
                        return ""
                    obj = json.loads(payload)
                    texts = []
                    for part in obj.get("candidates", [{}])[0].get("content", {}).get("parts", []):
                        t = part.get("text")
                        if t:
                            texts.append(t)
                    return "".join(texts)

                async for delta in self._pump_blocking_sse(
                    req, _parse_gemini_sse, timeout=60, error_label="Gemini API"
                ):
                    yield delta
            else:
                req_url = _build_openai_chat_endpoint(base_url)
                messages = [
                    {"role": "system", "content": system_instruction},
                    {"role": "user", "content": user_content},
                ]

                def _build_request(m: str):
                    post_body = json.dumps({
                        "model": m,
                        "messages": messages,
                        "temperature": 0.7,
                        # Qwen3 系：显式关思考，避免思考内容混入正文
                        "enable_thinking": False,
                        "stream": True,
                    }).encode("utf-8")
                    return urllib.request.Request(req_url, data=post_body, headers={
                        "Content-Type": "application/json",
                        "Authorization": f"Bearer {custom_api_key}",
                    })

                def _parse_openai_sse(line: str):
                    payload = line[5:].strip() if line.startswith("data:") else line.strip()
                    if not payload or payload == "[DONE]":
                        return ""
                    obj = json.loads(payload)
                    return obj.get("choices", [{}])[0].get("delta", {}).get("content") or ""

                async for delta in self._pump_blocking_sse(
                    _build_request,
                    _parse_openai_sse,
                    timeout=60,
                    error_label="自定义 API",
                    candidates=_candidate_text_models(model_name),
                ):
                    yield delta
            return

        # 2. 内置 Gemini Web 凭据兜底
        psid, psidts = get_credentials(auto_extract=True)
        if not psid or not psidts:
            raise RuntimeError("未登录 Google 凭据且未配置自定义 API Key")

        client = await self._build_verified_client(timeout=25)
        instruction = f"{system_instruction}\n\n用户描述：{user_content}"
        got_any = False
        async for chunk in client.generate_content_stream(instruction):
            delta = getattr(chunk, "text_delta", None)
            if delta:
                got_any = True
                yield delta
        if not got_any:
            raise RuntimeError("Gemini 未返回有效的润色文本")

    async def _pump_blocking_sse(
        self,
        request_or_builder,
        line_parser,
        timeout: int = 60,
        error_label: str = "API",
        candidates: Optional[List[str]] = None,
    ):
        """把阻塞式 urllib SSE 流桥接成 async 生成器。

        - request_or_builder：urllib.request.Request，或 `(model) -> Request` 的构造器
          （后者配合 candidates 做 404 候选自适应）；
        - line_parser：单行 SSE 文本 -> 增量字符串（解析失败应抛异常，连接被关闭）。
        """
        import queue as queue_module
        import urllib.request
        import urllib.error

        q: "queue_module.Queue" = queue_module.Queue()
        SENTINEL = object()

        def _worker():
            try:
                reqs = (
                    [request_or_builder]
                    if not callable(request_or_builder)
                    else [request_or_builder(m) for m in (candidates or [""])]
                )
                last_err = None
                for idx, req in enumerate(reqs):
                    try:
                        with urllib.request.urlopen(req, timeout=timeout) as resp:
                            for raw_line in resp:
                                line = raw_line.decode("utf-8", "ignore").strip()
                                if not line:
                                    continue
                                try:
                                    delta = line_parser(line)
                                except Exception:
                                    # 个别心跳/注释行解析失败直接跳过，不中断整条流
                                    continue
                                if delta:
                                    q.put(delta)
                                # OpenAI SSE 的结束标记
                                if line[5:].strip() == "[DONE]":
                                    break
                        return
                    except urllib.error.HTTPError as e:
                        last_err = e
                        if e.code == 404 and idx < len(reqs) - 1:
                            continue
                        q.put(RuntimeError(_extract_http_error_message(e, f"{error_label} 报错")))
                        return
                    except Exception as e:
                        q.put(RuntimeError(f"{error_label} 请求失败: {e}"))
                        return
                if last_err is not None:
                    q.put(RuntimeError(_extract_http_error_message(last_err, f"{error_label} 报错")))
            finally:
                q.put(SENTINEL)

        loop = asyncio.get_running_loop()
        worker_fut = loop.run_in_executor(None, _worker)
        try:
            while True:
                item = await loop.run_in_executor(None, q.get)
                if item is SENTINEL:
                    break
                if isinstance(item, BaseException):
                    raise item
                yield item
        finally:
            await worker_fut

    async def _call_text_api(
        self,
        system_instruction: str,
        user_content: str,
        api_key: str,
        base_url: str = "",
        model: str = "",
        timeout: int = 20,
        temperature: float = 0.7,
    ) -> str:
        """统一文本对话：Google 原生 API 与 OpenAI 兼容端点（含候选模型 404 自适应）。"""
        base = (base_url or "").strip() or "https://generativelanguage.googleapis.com"
        model_name = (model or "").strip() or DEFAULT_TEXT_MODEL
        loop = asyncio.get_event_loop()

        if "googleapis.com" in base:
            text = f"{system_instruction}\n\n{user_content}"
            return await loop.run_in_executor(
                None,
                lambda: _post_gemini_native_blocking(
                    api_key, base, model_name, text, timeout=timeout
                )
            )

        req_url = _build_openai_chat_endpoint(base)
        messages = [
            {"role": "system", "content": system_instruction},
            {"role": "user", "content": user_content},
        ]
        content, _used_model = await loop.run_in_executor(
            None,
            lambda: _post_openai_chat_blocking(
                api_key,
                req_url,
                messages,
                _candidate_text_models(model_name),
                timeout=timeout,
                temperature=temperature,
                extra_body={"enable_thinking": False},
            )
        )
        return content

    async def suggest_negative_prompt(
        self,
        prompt: str,
        style: str = "",
        custom_api_key: str = "",
        custom_base_url: str = "",
        custom_model: str = ""
    ) -> str:
        """按画面类型生成针对性负面提示词（走自定义文本模型）。

        2026-10-16 重写：旧指令把「肢体畸变、多余手指、五官错位」当示例，
        结果**纯景物图也照抄这三个词**——示例权重远高于「按画面类型取舍」这句软约束。
        新指令改为「先判画面类型 → 只从该类型的缺陷库取词」，并给多类型对照范例。
        """
        if not custom_api_key:
            raise RuntimeError("未配置自定义 AI，无法生成负面提示词。请在偏好设置中填写 API Key 并开启「使用自定义 AI」。")

        system_instruction = (
            "你是资深的 AI 生图提示词工程师。任务：针对用户给出的画面描述，输出**与该画面类型真正相关**的中文负面提示词。\n\n"
            "【第一步：判断画面类型】先在心里判断这属于哪一类："
            "人物/人像 · 风景/自然 · 静物/产品 · 建筑/室内 · 插画/抽象。\n\n"
            "【第二步：只从该类型的缺陷库取词】不同类型的缺陷完全不同，**严禁把人物的缺陷写进非人物画面**：\n"
            "· 人物/人像：多余手指、肢体畸变、五官错位、表情僵硬、牙齿畸变、发丝粘连、皮肤塑料感、服饰褶皱穿帮\n"
            "· 风景/自然：地平线倾斜、透视畸变、山体穿帮、水面反射错误、天空断层、植被死板复制、色调发灰、高光过曝\n"
            "· 静物/产品：透视畸变、边缘畸变、材质塑料感、反光穿帮、比例失调、背景杂乱、阴影方向矛盾\n"
            "· 建筑/室内：线条不直、透视畸变、门窗错位、家具比例失调、灯光不均、天花板穿帮\n"
            "· 插画/抽象：笔触脏乱、色块溢出、边缘锯齿、线稿断裂、风格漂移、元素粘连\n\n"
            "【通用词】水印、文字乱码、低分辨率 —— 最多取 3 个。\n\n"
            "【硬性要求】\n"
            "1. 数量 4~8 个，**宁缺毋滥**。不够就少，绝不要为凑数加与画面无关的词。\n"
            "2. 中文逗号分隔的短语；只输出负面词本身，无解释、无编号、无引号、无换行、无句末标点。\n"
            "3. 若描述信息不足以判断类型，只输出通用词。\n\n"
            "示例——\n"
            "输入：暮春时节，一池静水倒映着飘零的粉白花瓣，微风拂过水面\n"
            "输出：水面反射错误，色调发灰，高光过曝，植被死板复制，地平线倾斜，水印\n"
            "（风景类：一个手指/五官类的词都不该出现）\n\n"
            "输入：一位穿旗袍的女子撑油纸伞走在青石板路上\n"
            "输出：多余手指，肢体畸变，五官错位，表情僵硬，服饰褶皱穿帮，水印\n\n"
            "输入：白色陶瓷马克杯产品图\n"
            "输出：透视畸变，材质塑料感，反光穿帮，比例失调，背景杂乱，水印\n"
        )

        user_content = prompt.strip()
        if style and style != "无预设":
            user_content += f"（画面风格：{style}）"

        result = await self._call_text_api(
            system_instruction, user_content,
            custom_api_key, custom_base_url, custom_model,
            timeout=35, temperature=0.5
        )
        # 归一化：去换行、编号、引号与句末标点（便于下游按「画面中不要出现：X」拼接）
        import re
        text = result.strip().strip('"').strip('“”')
        text = re.sub(r"[\r\n]+", " ", text)
        text = re.sub(r"^\s*\d+[.、)]\s*", "", text)
        text = re.sub(r"[，,]{2,}", "，", text)
        text = re.sub(r"\s{2,}", " ", text)
        return text.strip().rstrip("。.；;，,、").strip()

    async def test_custom_api(
        self,
        custom_api_key: str,
        custom_base_url: str = "",
        custom_model: str = ""
    ) -> Dict[str, Any]:
        """Test connectivity and latency of custom API with minimal token request."""
        import time

        base_url = (custom_base_url or "").strip()
        model_name = (custom_model or "").strip()
        start_time = time.time()
        loop = asyncio.get_event_loop()

        try:
            if "googleapis.com" in base_url:
                base = base_url or "https://generativelanguage.googleapis.com"
                used_model = model_name or DEFAULT_TEXT_MODEL
                await loop.run_in_executor(
                    None,
                    lambda: _post_gemini_native_blocking(
                        custom_api_key, base, used_model, "hi",
                        timeout=6,
                        extra_body={"generationConfig": {"maxOutputTokens": 3}},
                    )
                )
            else:
                # 未填模型时沿用历史兜底 qwen3-vl-plus
                requested = model_name or "qwen3-vl-plus"
                req_url = _build_openai_chat_endpoint(base_url)
                _content, used_model = await loop.run_in_executor(
                    None,
                    lambda: _post_openai_chat_blocking(
                        custom_api_key,
                        req_url,
                        [{"role": "user", "content": "hi"}],
                        _candidate_text_models(requested),
                        timeout=6,
                        temperature=None,
                        max_tokens=3,
                    )
                )

            elapsed_ms = int((time.time() - start_time) * 1000)
            extra = f" (自动适配: {used_model})" if used_model != model_name and model_name else ""
            return {"success": True, "latency_ms": elapsed_ms,
                    "message": f"连接成功 (耗时: {elapsed_ms}ms{extra})"}
        except Exception as e:
            return {"success": False, "message": str(e)}

    # ================================================================
    #  多模态 AI 功能：参考图生图 / 自动描述标注 / 多轮创作 / 风格提取
    # ================================================================

    async def _init_client(self) -> GeminiClient:
        """返回已校验登录态的客户端（含代理回退与凭据自愈）。"""
        return await self._build_verified_client()

    async def generate_with_image(
        self,
        image_path: str,
        prompt: str,
        aspect_ratio: str = "1:1",
        style_context: str = "",
        negative_prompt: str = "",
        max_kb: int = 0,
        progress_callback: Optional[Callable[[Dict[str, Any]], Any]] = None,
    ) -> List[str]:
        """参考图生图：用户上传一张参考图 + 描述，生成新图"""
        async def report(stage: str, message: str, extra: Optional[Dict[str, Any]] = None):
            payload = {"stage": stage, "message": message}
            if extra:
                payload.update(extra)
            if progress_callback:
                if asyncio.iscoroutinefunction(progress_callback):
                    await progress_callback(payload)
                else:
                    progress_callback(payload)

        if not os.path.exists(image_path):
            raise RuntimeError(f"参考图不存在: {image_path}")

        client = await self._init_client()
        await report("session_ready", "会话就绪，正在分析参考图...")

        aspect_directive = self._aspect_directive(aspect_ratio)
        extra_directives = ""
        if style_context:
            extra_directives += f" 画面风格：{style_context}。"
        if negative_prompt:
            extra_directives += f" 画面中不要出现：{negative_prompt}。"
        full_prompt = (
            f"请参考这张图片的构图、色彩和风格，{aspect_directive}生成新图。"
            f"用户的修改描述：{prompt}"
            f"要求保持参考图的核心风格和构图，同时按照用户描述进行修改。{extra_directives}"
        )

        await report("generating", "正在基于参考图生成新图（约 20~50 秒）...")

        # gemini_webapi 的 files 参数支持图片路径
        output = await client.generate_content(full_prompt, files=[image_path])

        if not output.candidates:
            raise RuntimeError("Gemini 未返回有效候选结果")

        candidate = output.candidates[0]
        if not candidate.generated_images:
            raw_text = (candidate.text or "").strip()
            hint = _explain_no_image(raw_text)
            raise RuntimeError(hint or f"生图异常：网页端未返回图片（可能触发安全审核）：{raw_text[:200] or '无详细说明'}")

        saved_files = await self._save_generated_images(
            candidate.generated_images, prompt, aspect_ratio, "", max_kb,
            extra_meta={"reference_image": image_path}
        )
        await report("completed", "参考图生图完成", {"files": saved_files, "total": len(saved_files)})
        return saved_files

    # ================================================================
    #  多轮会话改图（同一会话内连续修改，上下文不丢）
    # ================================================================

    def _prune_sessions(self):
        """回收超时会话，并在超出上限时淘汰最久未使用的会话。"""
        now = time.time()
        expired = [sid for sid, s in _SESSIONS.items() if now - s["updated_at"] > SESSION_TTL_SEC]
        for sid in expired:
            _SESSIONS.pop(sid, None)

        while len(_SESSIONS) >= MAX_LIVE_SESSIONS:
            oldest = min(_SESSIONS.items(), key=lambda kv: kv[1]["updated_at"])[0]
            _SESSIONS.pop(oldest, None)

    async def close_session(self, session_id: str) -> bool:
        """关闭并移除指定会话（内存 + 磁盘记录）。"""
        sess = _SESSIONS.pop(session_id or "", None)
        _drop_session_meta(session_id or "")
        if not sess:
            return False
        try:
            await sess["client"].close()
        except Exception:
            pass
        return True

    def session_count(self) -> int:
        return len(_SESSIONS)

    async def edit_image(
        self,
        source_image_path: str,
        instruction: str,
        session_id: str = "",
        aspect_ratio: str = "1:1",
        style_context: str = "",
        negative_prompt: str = "",
        max_kb: int = 0,
        progress_callback: Optional[Callable[[Dict[str, Any]], Any]] = None,
    ) -> Dict[str, Any]:
        """多轮会话改图。

        - 会话存在且未过期 → 在既有会话内继续对话，模型保留上一轮画面上下文；
        - 会话不存在（首次、Sidecar 重启或已过期）→ 新建会话，并自动把 source_image_path
          作为参考图附着，重新播种上下文（无缝降级，用户无感）。
        """
        async def report(stage: str, message: str, extra: Optional[Dict[str, Any]] = None):
            payload = {"stage": stage, "message": message}
            if extra:
                payload.update(extra)
            if progress_callback:
                if asyncio.iscoroutinefunction(progress_callback):
                    await progress_callback(payload)
                else:
                    progress_callback(payload)

        clean_instruction = (instruction or "").strip()
        if not clean_instruction:
            raise RuntimeError("修改描述不能为空")

        self._prune_sessions()
        sess = _SESSIONS.get(session_id) if session_id else None
        resumed = sess is not None

        # 内存池没有但磁盘上有（Sidecar 重启过 / 内存池淘汰）→ 用远端会话标识
        # 重新附着同一条会话线：模型仍记得上一轮画面上下文，用户无感续改。
        if not resumed and session_id:
            meta = _load_session_meta().get(session_id)
            if meta and meta.get("cid"):
                try:
                    client = await self._init_client()
                    chat = client.start_chat(
                        cid=meta["cid"],
                        rid=meta.get("rid", "") or "",
                        rcid=meta.get("rcid", "") or "",
                    )
                    sess = {
                        "client": client,
                        "chat": chat,
                        "created_at": meta.get("updated_at", time.time()),
                        "updated_at": time.time(),
                        "turns": int(meta.get("turns", 0) or 0),
                    }
                    _SESSIONS[session_id] = sess
                    resumed = True
                except Exception:
                    sess = None
                    resumed = False

        aspect_directive = self._aspect_directive(aspect_ratio)

        # 画风与负面词：与首轮生图保持一致，作为附加指令随每轮修改下发
        extra_directives = ""
        if style_context:
            extra_directives += f" 画面风格保持：{style_context}。"
        if negative_prompt:
            extra_directives += f" 画面中不要出现：{negative_prompt}。"

        if resumed:
            await report("session_ready", f"已接入会话（第 {sess['turns'] + 1} 轮），正在修改...")
            prompt_text = (
                f"请基于上一轮的图片继续修改：{clean_instruction}。"
                f"保持原图的主体与整体构图，仅按上述要求调整；输出仍为 {aspect_directive}。{extra_directives}"
            )
            try:
                output = await sess["chat"].send_message(prompt_text)
            except Exception:
                # 会话失效（Cookie 刷新 / 远端回收）→ 回收后用参考图重新播种
                _SESSIONS.pop(session_id, None)
                await report("session_ready", "会话已失效，正在以当前画面重新建立会话...")
                resumed = False
                sess = None
                output = None

        if not resumed:
            client = await self._init_client()
            await report("session_ready", "会话就绪，正在基于当前画面建立改图上下文...")
            chat = client.start_chat()
            files = None
            if source_image_path and os.path.exists(source_image_path):
                files = [source_image_path]
            prompt_text = (
                f"请以这张图为基础进行修改：{clean_instruction}。"
                f"保持原图主体与整体构图不变，仅按上述要求调整；输出 {aspect_directive}。{extra_directives}"
            )
            output = await chat.send_message(prompt_text, files=files)
            sess = {"client": client, "chat": chat, "created_at": time.time(),
                    "updated_at": time.time(), "turns": 0}

        if not output.candidates:
            raise RuntimeError("Gemini 未返回有效候选结果")

        candidate = output.candidates[0]
        if not candidate.generated_images:
            raw_text = (candidate.text or "").strip()
            hint = _explain_no_image(raw_text)
            raise RuntimeError(hint or f"生图异常：网页端未返回图片（可能触发安全审核）：{raw_text[:200] or '无详细说明'}")

        await report("downloading", f"已生成 {len(candidate.generated_images)} 张，正在下载超清原图...",
                     {"total": len(candidate.generated_images)})

        saved_files = await self._save_generated_images(
            candidate.generated_images, clean_instruction, aspect_ratio, "", max_kb,
            extra_meta={"source_image": source_image_path, "edit_round": sess["turns"] + 1}
        )

        sess["updated_at"] = time.time()
        sess["turns"] += 1
        sid = session_id if (resumed and session_id) else uuid.uuid4().hex[:12]
        _SESSIONS[sid] = sess
        _persist_sessions()   # 落盘远端标识，Sidecar 重启后可续同一条会话

        await report("completed", "修改完成", {"files": saved_files, "total": len(saved_files), "session_id": sid})
        return {"files": saved_files, "session_id": sid, "resumed": resumed}

    async def describe_image(
        self,
        image_path: str,
        style: str = "",
        custom_api_key: str = "",
        custom_base_url: str = "",
        vision_model: str = ""
    ) -> str:
        """图像自动描述/标注：输入一张图片，生成详细描述或标签

        「图片描述模型」配置即契约：填写了模型名（且启用了自定义 API）就直接用
        该模型识图——这是用户的明确选择，不再按模型名猜它能否处理图片（名字
        判定永远追不上新模型族，qwen3.7-flash 即教训）；留空则走内置 Gemini。
        """
        if not os.path.exists(image_path):
            raise RuntimeError(f"图片不存在: {image_path}")

        system_instruction = _DESCRIBE_SYSTEM_INSTRUCTION
        user_content = self._describe_user_content(style)

        # 1. 已配置图片描述模型：按用户选择直接走自定义 Vision API
        if custom_api_key and (vision_model or "").strip():
            return await self._call_custom_vision_api(
                image_path, system_instruction, user_content,
                custom_api_key, custom_base_url, vision_model
            )

        # 2. 未配置图片描述模型，或未启用自定义 API：走内置 Gemini Web 凭据
        return await self._describe_with_builtin(
            image_path, system_instruction, user_content
        )

    async def describe_image_stream(
        self,
        image_path: str,
        style: str = "",
        custom_api_key: str = "",
        custom_base_url: str = "",
        vision_model: str = "",
    ):
        """流式图像描述：异步生成器，逐块 yield 文本增量。

        路由规则与 `describe_image` 完全一致（图片描述模型配置即契约），
        只是把一次性返回换成增量；调用方拼齐全文后自行裁剪与缓存。
        """
        if not os.path.exists(image_path):
            raise RuntimeError(f"图片不存在: {image_path}")

        system_instruction = _DESCRIBE_SYSTEM_INSTRUCTION
        user_content = self._describe_user_content(style)

        if custom_api_key and (vision_model or "").strip():
            async for delta in self._stream_custom_vision_api(
                image_path, system_instruction, user_content,
                custom_api_key, custom_base_url, vision_model
            ):
                yield delta
            return

        async for delta in self._stream_describe_builtin(
            image_path, system_instruction, user_content
        ):
            yield delta

    @staticmethod
    def _describe_user_content(style: str) -> str:
        """描述请求的用户侧文案（同步/流式共用，避免两处措辞漂移）"""
        content = "请用中文详细描述这张图片"
        if style and style != "无预设":
            content += f"（重点关注其{style}风格特点）"
        return content

    async def _stream_describe_builtin(
        self,
        image_path: str,
        system_instruction: str,
        user_content: str,
    ):
        """内置 Gemini Web 凭据的流式图像描述"""
        client = await self._init_client()
        web_prompt = f"{system_instruction}\n\n{user_content}"
        got_any = False
        async for chunk in client.generate_content_stream(web_prompt, files=[image_path]):
            delta = getattr(chunk, "text_delta", None)
            if delta:
                got_any = True
                yield delta
        if not got_any:
            raise RuntimeError("Gemini 未返回有效描述")

    async def _stream_custom_vision_api(
        self,
        image_path: str,
        system_instruction: str,
        user_content: str,
        api_key: str,
        base_url: str,
        model: str,
    ):
        """自定义 Vision API 的流式描述（Gemini 原生 SSE / OpenAI 兼容 SSE 两路）"""
        import base64
        import urllib.request

        image_data, mime_type = self._prepare_image_for_vision(image_path)
        image_b64 = base64.b64encode(image_data).decode("utf-8")

        base = (base_url or "").strip() or "https://generativelanguage.googleapis.com"
        model_name = (model or "").strip() or DEFAULT_TEXT_MODEL

        if "googleapis.com" in base:
            req_url = (
                f"{base.rstrip('/')}/v1beta/models/{model_name}"
                f":streamGenerateContent?alt=sse&key={api_key}"
            )
            parts = []
            if system_instruction:
                parts.append({"text": system_instruction})
            parts.append({"inline_data": {"mime_type": mime_type, "data": image_b64}})
            parts.append({"text": user_content})
            req = urllib.request.Request(
                req_url,
                data=json.dumps({"contents": [{"parts": parts}]}).encode("utf-8"),
                headers={"Content-Type": "application/json"},
            )

            def _parse_gemini(line: str):
                payload = line[5:].strip() if line.startswith("data:") else line.strip()
                if not payload:
                    return ""
                obj = json.loads(payload)
                texts = []
                for part in obj.get("candidates", [{}])[0].get("content", {}).get("parts", []):
                    t = part.get("text")
                    if t:
                        texts.append(t)
                return "".join(texts)

            async for delta in self._pump_blocking_sse(
                req, _parse_gemini, timeout=90, error_label="Vision API"
            ):
                yield delta
            return

        req_url = _build_openai_chat_endpoint(base)
        messages = []
        if system_instruction:
            messages.append({"role": "system", "content": system_instruction})
        messages.append({
            "role": "user",
            "content": [
                {"type": "text", "text": user_content},
                {"type": "image_url", "image_url": {"url": f"data:{mime_type};base64,{image_b64}"}},
            ],
        })

        def _build_request(m: str):
            return urllib.request.Request(
                req_url,
                data=json.dumps({
                    "model": m,
                    "messages": messages,
                    "temperature": 0.7,
                    "enable_thinking": False,
                    "stream": True,
                }).encode("utf-8"),
                headers={
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {api_key}",
                },
            )

        def _parse_openai(line: str):
            payload = line[5:].strip() if line.startswith("data:") else line.strip()
            if not payload or payload == "[DONE]":
                return ""
            obj = json.loads(payload)
            return obj.get("choices", [{}])[0].get("delta", {}).get("content") or ""

        async for delta in self._pump_blocking_sse(
            _build_request,
            _parse_openai,
            timeout=90,
            error_label="Vision API",
            candidates=_candidate_text_models(model_name),
        ):
            yield delta

    async def _describe_with_builtin(
        self,
        image_path: str,
        system_instruction: str,
        user_content: str
    ) -> str:
        """内置 Gemini Web 凭据的图像描述（指令合并进用户消息，确保中文输出约束生效）"""
        client = await self._init_client()
        web_prompt = f"{system_instruction}\n\n{user_content}"
        output = await client.generate_content(web_prompt, files=[image_path])
        if not output.candidates:
            raise RuntimeError("Gemini 未返回有效描述")
        return output.candidates[0].text or "描述生成失败"

    async def _save_generated_images(
        self,
        generated_images: List,
        prompt: str,
        aspect_ratio: str,
        style_context: str,
        max_kb: int,
        extra_meta: Optional[Dict[str, Any]] = None
    ) -> List[str]:
        """保存生成的图片并写入元数据"""
        saved_files = []
        batch_id = hashlib.md5(f"{prompt}_{asyncio.get_event_loop().time()}".encode()).hexdigest()[:8]

        total_images = len(generated_images)
        _ensure_disk_space(total_images)
        # 新图按生成月份分目录（旧图保留原地）
        target_dir = _month_output_dir()
        with tempfile.TemporaryDirectory() as tmp_dir:
            for idx, img in enumerate(generated_images, start=1):
                file_name = f"gemini_{batch_id}_{idx}.png"
                file_path = target_dir / file_name

                saved_temp_path = await img.save(path=tmp_dir, full_size=True)
                shutil.copyfile(saved_temp_path, str(file_path))

                if max_kb > 0:
                    compress_image(str(file_path), max_kb=max_kb)

                # 写入元数据
                meta_path = target_dir / f"gemini_{batch_id}_{idx}.json"
                meta_data = {
                    "prompt": prompt,
                    "aspect_ratio": aspect_ratio,
                    "style_context": style_context,
                    "created_at": time.time()
                }
                if extra_meta:
                    meta_data.update(extra_meta)
                try:
                    meta_path.write_text(json.dumps(meta_data, ensure_ascii=False, indent=2), encoding="utf-8")
                except Exception:
                    pass

                saved_files.append(str(file_path.resolve()))

        return saved_files

    def _aspect_directive(self, aspect_ratio: str) -> str:
        """生成比例约束指令"""
        directives = {
            "1:1": "in strict 1:1 square aspect ratio (square composition, equal width and height 1:1, width=height)",
            "16:9": "in 16:9 wide landscape aspect ratio (cinematic horizontal 16:9 widescreen format)",
            "9:16": "in 9:16 vertical aspect ratio (tall mobile wallpaper portrait orientation 9:16)",
            "4:3": "in 4:3 aspect ratio (standard landscape 4:3 format)",
            "3:4": "in 3:4 aspect ratio (vertical portrait 3:4 format)",
        }
        return directives.get(aspect_ratio, f"in {aspect_ratio} aspect ratio")

    async def _call_custom_vision_api(
        self,
        image_path: str,
        system_instruction: str,
        user_content: str,
        api_key: str,
        base_url: str,
        model: str
    ) -> str:
        """调用自定义 Vision API（支持 Gemini API 与 OpenAI 兼容接口，图片先压缩再上传）"""
        import base64
        import urllib.request
        import urllib.error

        image_data, mime_type = self._prepare_image_for_vision(image_path)
        image_b64 = base64.b64encode(image_data).decode("utf-8")

        base = (base_url or "").strip() or "https://generativelanguage.googleapis.com"
        model_name = (model or "").strip() or DEFAULT_TEXT_MODEL
        loop = asyncio.get_event_loop()

        if "googleapis.com" in base:
            # Gemini 原生多模态：多 part 结构（system 文本 + inline_data + 用户文本），
            # 与纯文本 helper 的单 text 入参不同，保留内联请求，错误体仍走统一解析。
            req_url = f"{base.rstrip('/')}/v1beta/models/{model_name}:generateContent?key={api_key}"
            parts = []
            if system_instruction:
                parts.append({"text": system_instruction})
            parts.append({"inline_data": {"mime_type": mime_type, "data": image_b64}})
            parts.append({"text": user_content})
            post_body = json.dumps({"contents": [{"parts": parts}]}).encode("utf-8")
            req = urllib.request.Request(req_url, data=post_body,
                                         headers={"Content-Type": "application/json"})

            def _do_api():
                with urllib.request.urlopen(req, timeout=90) as resp:
                    res = json.loads(resp.read().decode("utf-8"))
                    return res["candidates"][0]["content"]["parts"][0]["text"].strip()

            try:
                return await loop.run_in_executor(None, _do_api)
            except urllib.error.HTTPError as e:
                raise RuntimeError(_extract_http_error_message(e, "Vision API 错误"))

        # OpenAI 兼容 Vision：端点归一化 / 候选模型 / 错误解析复用文本通道 helper
        req_url = _build_openai_chat_endpoint(base)
        messages = []
        if system_instruction:
            messages.append({"role": "system", "content": system_instruction})
        messages.append({
            "role": "user",
            "content": [
                {"type": "text", "text": user_content},
                {"type": "image_url", "image_url": {"url": f"data:{mime_type};base64,{image_b64}"}}
            ]
        })
        content, _used = await loop.run_in_executor(
            None,
            lambda: _post_openai_chat_blocking(
                api_key,
                req_url,
                messages,
                _candidate_text_models(model_name),
                timeout=90,
                temperature=0.7,
                extra_body={"enable_thinking": False},
            )
        )
        return content

    def _prepare_image_for_vision(self, image_path: str, max_pixel: int = 1536) -> tuple:
        """压缩图片用于 Vision 上传：最长边限制 1536px，转 JPEG（约 200KB），大幅提升兼容性与速度"""
        import io
        try:
            from PIL import Image
            with Image.open(image_path) as img:
                img = self._flatten_for_vision(img)
                w, h = img.size
                scale = max_pixel / float(max(w, h))
                if scale < 1.0:
                    img = img.resize((int(w * scale), int(h * scale)), Image.LANCZOS)
                buf = io.BytesIO()
                img.save(buf, format="JPEG", quality=88)
                return buf.getvalue(), "image/jpeg"
        except Exception:
            # PIL 处理失败时回退原图
            with open(image_path, "rb") as f:
                data = f.read()
            ext = os.path.splitext(image_path)[1].lower()
            mime_map = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
                        ".webp": "image/webp", ".gif": "image/gif", ".heic": "image/heic"}
            return data, mime_map.get(ext, "image/png")

    @staticmethod
    def _flatten_for_vision(img):
        """拍平透明通道，JPEG 不支持 alpha"""
        from PIL import Image
        if img.mode in ("RGBA", "LA", "P"):
            rgba = img.convert("RGBA")
            bg = Image.new("RGB", rgba.size, (255, 255, 255))
            bg.paste(rgba, mask=rgba.split()[-1])
            return bg
        if img.mode != "RGB":
            return img.convert("RGB")
        return img

