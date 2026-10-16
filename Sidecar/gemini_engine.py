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
from optimizer import compress_image

SIDECAR_DIR = Path(__file__).resolve().parent
DEFAULT_ENV_FILE = SIDECAR_DIR / ".env"
OUTPUT_DIR = Path.home() / "Pictures/Prism"
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

REQUEST_TIMEOUT = 120
RETRY_BACKOFF_SEC = 3

# 多轮会话池：session_id -> {"client", "chat", "created_at", "updated_at", "turns"}
# 会话内保持上下文，用于「继续修改」式对话改图；超时或超量自动回收。
_SESSIONS: Dict[str, Dict[str, Any]] = {}
SESSION_TTL_SEC = 30 * 60
MAX_LIVE_SESSIONS = 8

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
    try:
        DEFAULT_ENV_FILE.parent.mkdir(parents=True, exist_ok=True)
        content = (
            "# Gemini Studio Credentials\n"
            f'GEMINI_SECURE_1PSID="{psid}"\n'
            f'GEMINI_SECURE_1PSIDTS="{psidts}"\n'
        )
        with open(DEFAULT_ENV_FILE, "w", encoding="utf-8") as f:
            f.write(content)
        os.chmod(DEFAULT_ENV_FILE, 0o600)
        return True
    except Exception:
        return False

def get_credentials(auto_extract: bool = True):
    psid = os.environ.get("GEMINI_SECURE_1PSID")
    psidts = os.environ.get("GEMINI_SECURE_1PSIDTS")

    if not psid or not psidts:
        if DEFAULT_ENV_FILE.exists():
            with open(DEFAULT_ENV_FILE, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    if line.startswith("GEMINI_SECURE_1PSID="):
                        psid = line.split("=", 1)[1].strip().strip('"').strip("'")
                    elif line.startswith("GEMINI_SECURE_1PSIDTS="):
                        psidts = line.split("=", 1)[1].strip().strip('"').strip("'")

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

class GeminiEngine:
    def __init__(self):
        self.client: Optional[GeminiClient] = None

    async def verify_auth(self) -> Dict[str, Any]:
        psid, psidts = get_credentials(auto_extract=True)
        if not psid or not psidts:
            return {"valid": False, "reason": "No credentials found"}
        return {"valid": True, "psid_masked": f"{psid[:6]}...{psid[-4:]}" if psid else ""}

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
            raise RuntimeError("Missing Gemini session cookies")

        proxy = get_proxy()

        await report("connecting", "正在连接 Google Gemini...")

        client = GeminiClient(
            secure_1psid=psid,
            secure_1psidts=psidts,
            proxy=proxy,
            timeout=REQUEST_TIMEOUT,
        )
        try:
            await client.init()
        except Exception:
            # 代理不通回退直连
            client = GeminiClient(
                secure_1psid=psid,
                secure_1psidts=psidts,
                proxy=None,
                timeout=REQUEST_TIMEOUT,
            )
            await client.init()

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

        full_prompt = clean_prompt
        if style_context:
            full_prompt = f"{full_prompt}. Visual style and aesthetic: {style_context}"
        if negative_prompt:
            full_prompt = f"{full_prompt} (avoid elements: {negative_prompt})"

        formatted_prompt = f"Please generate an image {aspect_directive}: {full_prompt}"

        await report("submitting", f"已提交提示词，准备渲染...")
        await report("generating", "等待 Imagen 3 原生渲染（通常需 20~50 秒）...")

        output = await client.generate_content(formatted_prompt)

        if not output.candidates:
            await report("error", "Gemini 网页端未返回有效候选结果")
            raise RuntimeError("No candidates returned from Gemini")

        candidate = output.candidates[0]
        if not candidate.generated_images:
            txt = candidate.text[:200] if candidate.text else "无详细说明"
            await report("error", f"未返回图片（可能触发安全审核或文本应答）：{txt}")
            raise RuntimeError(f"No images generated: {txt}")

        total_images = len(candidate.generated_images)
        await report("downloading", f"已生成 {total_images} 张图片，正在下载全尺寸超清 CDN 原图...", {"total": total_images})

        saved_files = []
        batch_id = hashlib.md5(f"{prompt}_{asyncio.get_event_loop().time()}".encode()).hexdigest()[:8]

        with tempfile.TemporaryDirectory() as tmp_dir:
            for idx, img in enumerate(candidate.generated_images, start=1):
                file_name = f"gemini_{batch_id}_{idx}.png"
                file_path = OUTPUT_DIR / file_name
                
                # 正确调用 save，指定临时目录并拉取 full_size 超清原画
                saved_temp_path = await img.save(path=tmp_dir, full_size=True)
                shutil.copyfile(saved_temp_path, str(file_path))

                if max_kb > 0:
                    compress_image(str(file_path), max_kb=max_kb)

                # 伴生写入元数据，确保任何情况下（即使主 json 丢失）都能 100% 还原提示词
                meta_path = OUTPUT_DIR / f"gemini_{batch_id}_{idx}.json"
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
        custom_model: str = ""
    ) -> str:
        """Polish prompt into rich, evocative image generation prompt."""
        system_instruction = (
            "你是一位顶尖的 AI 生图提示词大师（Prompt Specialist）。"
            "请根据用户输入的一句话或简略描述，润色并扩写为一段画面细节细腻丰富、光影与色彩极富张力、构图优秀的中文生图提示词。"
            "要求：1. 保持用户原意核心主体；2. 增加环境、光影质感、色彩基调与大师级细节描述；"
            "3. 只输出润色后的提示词正文，严禁输出任何前后缀解释、问候或多余标点标记。"
        )

        user_content = prompt.strip()
        if style and style != "无预设":
            user_content += f"（画面期望风格：{style}）"

        # 1. 自定义 API 优先
        if custom_api_key:
            import urllib.request
            import urllib.error
            base_url = (custom_base_url or "").strip() or "https://generativelanguage.googleapis.com"
            model_name = (custom_model or "").strip() or "gemini-1.5-flash"

            if "googleapis.com" in base_url:
                req_url = f"{base_url.rstrip('/')}/v1beta/models/{model_name}:generateContent?key={custom_api_key}"
                post_body = json.dumps({
                    "contents": [{"parts": [{"text": f"{system_instruction}\n\n用户描述: {user_content}"}]}]
                }).encode("utf-8")
                req = urllib.request.Request(req_url, data=post_body, headers={"Content-Type": "application/json"})
                loop = asyncio.get_event_loop()
                def _do_gemini_api():
                    with urllib.request.urlopen(req, timeout=12) as resp:
                        res = json.loads(resp.read().decode("utf-8"))
                        return res["candidates"][0]["content"]["parts"][0]["text"].strip()
                try:
                    return await loop.run_in_executor(None, _do_gemini_api)
                except urllib.error.HTTPError as e:
                    err = e.read().decode("utf-8")
                    raise RuntimeError(f"Gemini API 错误 (HTTP {e.code}): {err[:150]}")
                except Exception as e:
                    raise RuntimeError(f"Gemini API 请求失败: {str(e)}")
            else:
                # 智能构建 OpenAI 兼容接口端点 (自动兼容通义千问等服务)
                clean_base = base_url.rstrip('/')
                if clean_base.endswith("/chat/completions"):
                    req_url = clean_base
                elif clean_base.endswith("/v1"):
                    req_url = f"{clean_base}/chat/completions"
                elif "/compatible-mode" in clean_base and not clean_base.endswith("/v1"):
                    req_url = f"{clean_base}/v1/chat/completions"
                else:
                    req_url = f"{clean_base}/v1/chat/completions"

                candidate_models = [model_name]
                if "qwen3-vl-flash" in model_name:
                    candidate_models.append("qwen3-vl-plus")
                elif "qwen3-vl" in model_name and not model_name.endswith("-plus"):
                    candidate_models.append("qwen3-vl-plus")

                loop = asyncio.get_event_loop()
                def _do_openai_api():
                    last_err = None
                    for m in candidate_models:
                        post_body = json.dumps({
                            "model": m,
                            "messages": [
                                {"role": "system", "content": system_instruction},
                                {"role": "user", "content": user_content}
                            ],
                            "temperature": 0.7
                        }).encode("utf-8")
                        req = urllib.request.Request(req_url, data=post_body, headers={
                            "Content-Type": "application/json",
                            "Authorization": f"Bearer {custom_api_key}"
                        })
                        try:
                            with urllib.request.urlopen(req, timeout=15) as resp:
                                res = json.loads(resp.read().decode("utf-8"))
                                return res["choices"][0]["message"]["content"].strip()
                        except urllib.error.HTTPError as e:
                            last_err = e
                            if e.code == 404:
                                continue
                            raise
                    if last_err:
                        raw = last_err.read().decode("utf-8")
                        try:
                            j = json.loads(raw)
                            msg = j.get("error", {}).get("message", raw[:120]) if isinstance(j.get("error"), dict) else raw[:120]
                        except Exception:
                            msg = raw[:120]
                        raise RuntimeError(f"自定义 API 报错 (HTTP {last_err.code}): {msg}")
                    raise RuntimeError("自定义 API 未返回有效内容")

                try:
                    return await loop.run_in_executor(None, _do_openai_api)
                except Exception as e:
                    raise RuntimeError(f"{str(e)}")

        # 2. 内置 Gemini Web 凭据兜底 (仅在未配置自定义 API 时使用)
        psid, psidts = get_credentials(auto_extract=True)
        if not psid or not psidts:
            raise RuntimeError("未登录 Google 凭据且未配置自定义 API Key")

        client = GeminiClient(
            secure_1psid=psid,
            secure_1psidts=psidts,
            proxy=get_proxy(),
            timeout=25,
        )
        try:
            await client.init()
        except Exception:
            client = GeminiClient(secure_1psid=psid, secure_1psidts=psidts, proxy=None, timeout=25)
            await client.init()

        instruction = f"{system_instruction}\n\n请润色以下生图描述：\n{user_content}"
        output = await client.generate_content(instruction)
        if output and output.candidates:
            c = output.candidates[0]
            if c.text:
                import re
                res_text = c.text.strip().strip('"').strip('“').strip('”')
                res_text = re.sub(r'[\r\n]+_\w+.*$', '', res_text).strip()
                return res_text
        raise RuntimeError("Gemini 未返回有效的润色文本")

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
        """调用自定义文本模型（支持 Gemini 原生 API 与 OpenAI 兼容端点，含候选模型 404 自适应）。"""
        import urllib.request
        import urllib.error

        base_url = (base_url or "").strip() or "https://generativelanguage.googleapis.com"
        model_name = (model or "").strip() or "gemini-1.5-flash"
        loop = asyncio.get_event_loop()

        if "googleapis.com" in base_url:
            req_url = f"{base_url.rstrip('/')}/v1beta/models/{model_name}:generateContent?key={api_key}"
            post_body = json.dumps({
                "contents": [{"parts": [{"text": f"{system_instruction}\n\n{user_content}"}]}]
            }).encode("utf-8")
            req = urllib.request.Request(req_url, data=post_body, headers={"Content-Type": "application/json"})

            def _do_gemini_api():
                with urllib.request.urlopen(req, timeout=timeout) as resp:
                    res = json.loads(resp.read().decode("utf-8"))
                    return res["candidates"][0]["content"]["parts"][0]["text"].strip()

            try:
                return await loop.run_in_executor(None, _do_gemini_api)
            except urllib.error.HTTPError as e:
                err = e.read().decode("utf-8")
                raise RuntimeError(f"Gemini API 错误 (HTTP {e.code}): {err[:150]}")
            except Exception as e:
                raise RuntimeError(f"Gemini API 请求失败: {str(e)}")

        clean_base = base_url.rstrip('/')
        if clean_base.endswith("/chat/completions"):
            req_url = clean_base
        elif clean_base.endswith("/v1"):
            req_url = f"{clean_base}/chat/completions"
        elif "/compatible-mode" in clean_base and not clean_base.endswith("/v1"):
            req_url = f"{clean_base}/v1/chat/completions"
        else:
            req_url = f"{clean_base}/v1/chat/completions"

        candidate_models = [model_name]
        if "qwen3-vl-flash" in model_name:
            candidate_models.append("qwen3-vl-plus")
        elif "qwen3-vl" in model_name and not model_name.endswith("-plus"):
            candidate_models.append("qwen3-vl-plus")

        def _do_openai_api():
            last_err = None
            for m in candidate_models:
                post_body = json.dumps({
                    "model": m,
                    "messages": [
                        {"role": "system", "content": system_instruction},
                        {"role": "user", "content": user_content}
                    ],
                    "temperature": temperature
                }).encode("utf-8")
                req = urllib.request.Request(req_url, data=post_body, headers={
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {api_key}"
                })
                try:
                    with urllib.request.urlopen(req, timeout=timeout) as resp:
                        res = json.loads(resp.read().decode("utf-8"))
                        return res["choices"][0]["message"]["content"].strip()
                except urllib.error.HTTPError as e:
                    last_err = e
                    if e.code == 404:
                        continue
                    raise
            if last_err:
                raw = last_err.read().decode("utf-8")
                try:
                    j = json.loads(raw)
                    msg = j.get("error", {}).get("message", raw[:120]) if isinstance(j.get("error"), dict) else raw[:120]
                except Exception:
                    msg = raw[:120]
                raise RuntimeError(f"自定义 API 报错 (HTTP {last_err.code}): {msg}")
            raise RuntimeError("自定义 API 未返回有效内容")

        try:
            return await loop.run_in_executor(None, _do_openai_api)
        except Exception as e:
            raise RuntimeError(f"{str(e)}")

    async def suggest_negative_prompt(
        self,
        prompt: str,
        style: str = "",
        custom_api_key: str = "",
        custom_base_url: str = "",
        custom_model: str = ""
    ) -> str:
        """根据主体描述生成针对性负面提示词（走自定义文本模型，不受网页端限制）。"""
        if not custom_api_key:
            raise RuntimeError("未配置自定义 AI，无法生成负面提示词。请在偏好设置中填写 API Key 并开启「使用自定义 AI」。")

        system_instruction = (
            "你是资深的 AI 生图提示词工程师。请针对用户给出的画面描述，输出一段可直接拼接的**中文负面提示词**，"
            "只覆盖该画面最容易出现的缺陷（例如：肢体畸变、多余手指、五官错位、文字乱码、水印、低分辨率、"
            "构图倾斜、呆板打光、过曝等，按画面类型取舍）。"
            "硬性要求：1. 用中文逗号分隔的短语，数量 8~14 个；2. 只输出负面词本身，"
            "严禁任何解释、前后缀、编号、引号或换行。"
        )

        user_content = prompt.strip()
        if style and style != "无预设":
            user_content += f"（画面风格：{style}）"

        result = await self._call_text_api(
            system_instruction, user_content,
            custom_api_key, custom_base_url, custom_model,
            timeout=20, temperature=0.5
        )
        # 归一化：去掉换行、编号与多余符号
        import re
        text = result.strip().strip('"').strip('“”')
        text = re.sub(r"[\r\n]+", "", text)
        text = re.sub(r"^\s*\d+[.、)]\s*", "", text)
        return text.strip()

    async def test_custom_api(
        self,
        custom_api_key: str,
        custom_base_url: str = "",
        custom_model: str = ""
    ) -> Dict[str, Any]:
        """Test connectivity and latency of custom API with minimal token request."""
        import urllib.request
        import urllib.error
        import time

        base_url = (custom_base_url or "").strip()
        model_name = (custom_model or "").strip()
        start_time = time.time()

        if "googleapis.com" in base_url:
            model = model_name or "gemini-1.5-flash"
            req_url = f"{base_url.rstrip('/')}/v1beta/models/{model}:generateContent?key={custom_api_key}"
            post_body = json.dumps({
                "contents": [{"parts": [{"text": "hi"}]}],
                "generationConfig": {"maxOutputTokens": 3}
            }).encode("utf-8")
        else:
            clean_base = base_url.rstrip('/')
            if clean_base.endswith("/chat/completions"):
                req_url = clean_base
            elif clean_base.endswith("/v1"):
                req_url = f"{clean_base}/chat/completions"
            elif "/compatible-mode" in clean_base and not clean_base.endswith("/v1"):
                req_url = f"{clean_base}/v1/chat/completions"
            else:
                req_url = f"{clean_base}/v1/chat/completions"

            candidate_models = [model_name or "qwen3-vl-plus"]
            if "qwen3-vl-flash" in candidate_models[0]:
                candidate_models.append("qwen3-vl-plus")
            elif "qwen3-vl" in candidate_models[0] and not candidate_models[0].endswith("-plus"):
                candidate_models.append("qwen3-vl-plus")

            loop = asyncio.get_event_loop()
            def _ping():
                last_err = None
                for m in candidate_models:
                    post_body = json.dumps({
                        "model": m,
                        "messages": [{"role": "user", "content": "hi"}],
                        "max_tokens": 3
                    }).encode("utf-8")
                    req = urllib.request.Request(req_url, data=post_body, headers={
                        "Content-Type": "application/json",
                        "Authorization": f"Bearer {custom_api_key}"
                    })
                    try:
                        with urllib.request.urlopen(req, timeout=6) as resp:
                            _ = resp.read()
                            return (resp.status, m)
                    except urllib.error.HTTPError as e:
                        last_err = e
                        if e.code == 404:
                            continue
                        raise
                if last_err:
                    raise last_err
                return (200, candidate_models[0])

        try:
            status, used_model = await loop.run_in_executor(None, _ping)
            elapsed_ms = int((time.time() - start_time) * 1000)
            extra = f" (自动适配: {used_model})" if used_model != model_name and model_name else ""
            return {"success": True, "latency_ms": elapsed_ms, "message": f"连接成功 (耗时: {elapsed_ms}ms{extra})"}
        except urllib.error.HTTPError as e:
            err_msg = ""
            try:
                raw = e.read().decode("utf-8")
                j = json.loads(raw)
                err_msg = j.get("error", {}).get("message", raw[:120]) if isinstance(j.get("error"), dict) else raw[:120]
            except Exception:
                err_msg = e.reason
            return {"success": False, "message": f"HTTP {e.code}: {err_msg}"}
        except Exception as e:
            return {"success": False, "message": str(e)}

    # ================================================================
    #  多模态 AI 功能：参考图生图 / 自动描述标注 / 多轮创作 / 风格提取
    # ================================================================

    async def _init_client(self) -> GeminiClient:
        """创建并初始化 GeminiClient（含代理回退）"""
        psid, psidts = get_credentials(auto_extract=True)
        if not psid or not psidts:
            raise RuntimeError("未找到有效 Google 登录凭据，请在 App 中登录或同步 Chrome")

        client = GeminiClient(
            secure_1psid=psid,
            secure_1psidts=psidts,
            proxy=get_proxy(),
            timeout=REQUEST_TIMEOUT,
        )
        try:
            await client.init()
        except Exception:
            # 代理不通回退直连
            client = GeminiClient(
                secure_1psid=psid,
                secure_1psidts=psidts,
                proxy=None,
                timeout=REQUEST_TIMEOUT,
            )
            await client.init()
        return client

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
            extra_directives += f" 避免出现以下元素：{negative_prompt}。"
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
            txt = candidate.text[:200] if candidate.text else "无详细说明"
            raise RuntimeError(f"未返回图片（可能触发安全审核）：{txt}")

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
        """关闭并移除指定会话。"""
        sess = _SESSIONS.pop(session_id or "", None)
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

        aspect_directive = self._aspect_directive(aspect_ratio)

        # 画风与负面词：与首轮生图保持一致，作为附加指令随每轮修改下发
        extra_directives = ""
        if style_context:
            extra_directives += f" 画面风格保持：{style_context}。"
        if negative_prompt:
            extra_directives += f" 避免出现以下元素：{negative_prompt}。"

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
            txt = candidate.text[:200] if candidate.text else "无详细说明"
            raise RuntimeError(f"未返回图片（可能触发安全审核）：{txt}")

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

        await report("completed", "修改完成", {"files": saved_files, "total": len(saved_files), "session_id": sid})
        return {"files": saved_files, "session_id": sid, "resumed": resumed}

    async def describe_image(
        self,
        image_path: str,
        style: str = "",
        custom_api_key: str = "",
        custom_base_url: str = "",
        custom_model: str = ""
    ) -> str:
        """图像自动描述/标注：输入一张图片，生成详细描述或标签"""
        if not os.path.exists(image_path):
            raise RuntimeError(f"图片不存在: {image_path}")

        system_instruction = (
            "你是一位专业的图像描述专家。"
            "请为这张图片生成详细描述，所有内容必须使用中文输出，包括：主体内容、构图方式、色彩基调、光影效果、艺术风格、氛围情感。"
            "最后给出一段可以直接用于 AI 生图的中文提示词。"
            "输出格式：\n【图像描述】\n[中文详细描述]\n\n【生图提示词】\n[中文提示词]"
        )

        user_content = "请用中文详细描述这张图片"
        if style and style != "无预设":
            user_content += f"（重点关注其{style}风格特点）"

        # 1. 自定义 API 优先
        if custom_api_key:
            result = await self._call_custom_vision_api(
                image_path, system_instruction, user_content,
                custom_api_key, custom_base_url, custom_model
            )
            return result

        # 2. 内置 Gemini Web 凭据（指令合并进用户消息，确保中文输出约束生效）
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
        with tempfile.TemporaryDirectory() as tmp_dir:
            for idx, img in enumerate(generated_images, start=1):
                file_name = f"gemini_{batch_id}_{idx}.png"
                file_path = OUTPUT_DIR / file_name

                saved_temp_path = await img.save(path=tmp_dir, full_size=True)
                shutil.copyfile(saved_temp_path, str(file_path))

                if max_kb > 0:
                    compress_image(str(file_path), max_kb=max_kb)

                # 写入元数据
                meta_path = OUTPUT_DIR / f"gemini_{batch_id}_{idx}.json"
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
        import io
        import urllib.request
        import urllib.error

        image_data, mime_type = self._prepare_image_for_vision(image_path)
        image_b64 = base64.b64encode(image_data).decode("utf-8")

        base_url = (base_url or "").strip() or "https://generativelanguage.googleapis.com"
        model_name = (model or "").strip() or "gemini-1.5-flash"

        if "googleapis.com" in base_url:
            req_url = f"{base_url.rstrip('/')}/v1beta/models/{model_name}:generateContent?key={api_key}"
            parts = []
            if system_instruction:
                parts.append({"text": system_instruction})
            parts.append({"inline_data": {"mime_type": mime_type, "data": image_b64}})
            parts.append({"text": user_content})
            post_body = json.dumps({"contents": [{"parts": parts}]}).encode("utf-8")

            req = urllib.request.Request(req_url, data=post_body, headers={"Content-Type": "application/json"})
            loop = asyncio.get_event_loop()

            def _do_api():
                with urllib.request.urlopen(req, timeout=90) as resp:
                    res = json.loads(resp.read().decode("utf-8"))
                    return res["candidates"][0]["content"]["parts"][0]["text"].strip()

            try:
                return await loop.run_in_executor(None, _do_api)
            except urllib.error.HTTPError as e:
                err = e.read().decode("utf-8")
                raise RuntimeError(f"Vision API 错误 (HTTP {e.code}): {err[:150]}")
        else:
            # OpenAI 兼容 Vision 接口（智能构建端点，兼容通义千问等服务）
            clean_base = base_url.rstrip('/')
            if clean_base.endswith("/chat/completions"):
                req_url = clean_base
            elif clean_base.endswith("/v1"):
                req_url = f"{clean_base}/chat/completions"
            elif "/compatible-mode" in clean_base and not clean_base.endswith("/v1"):
                req_url = f"{clean_base}/v1/chat/completions"
            else:
                req_url = f"{clean_base}/v1/chat/completions"

            candidate_models = [model_name]
            if "qwen3-vl-flash" in model_name:
                candidate_models.append("qwen3-vl-plus")
            elif "qwen3-vl" in model_name and not model_name.endswith("-plus"):
                candidate_models.append("qwen3-vl-plus")

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

            loop = asyncio.get_event_loop()

            def _do_openai_vision():
                last_err = None
                for m in candidate_models:
                    post_body = json.dumps({
                        "model": m,
                        "messages": messages,
                        "temperature": 0.7
                    }).encode("utf-8")
                    req = urllib.request.Request(req_url, data=post_body, headers={
                        "Content-Type": "application/json",
                        "Authorization": f"Bearer {api_key}"
                    })
                    try:
                        with urllib.request.urlopen(req, timeout=90) as resp:
                            res = json.loads(resp.read().decode("utf-8"))
                            return res["choices"][0]["message"]["content"].strip()
                    except urllib.error.HTTPError as e:
                        last_err = e
                        if e.code == 404:
                            continue
                        raise
                if last_err:
                    raw = last_err.read().decode("utf-8")
                    try:
                        j = json.loads(raw)
                        msg = j.get("error", {}).get("message", raw[:120]) if isinstance(j.get("error"), dict) else raw[:120]
                    except Exception:
                        msg = raw[:120]
                    raise RuntimeError(f"自定义 Vision API 报错 (HTTP {last_err.code}): {msg}")
                raise RuntimeError("自定义 Vision API 未返回有效内容")

            try:
                return await loop.run_in_executor(None, _do_openai_vision)
            except urllib.error.HTTPError as e:
                raw = e.read().decode("utf-8")
                raise RuntimeError(f"自定义 Vision API 错误 (HTTP {e.code}): {raw[:150]}")

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

