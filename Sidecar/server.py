#!/usr/bin/env python3
"""
Prism Local Sidecar HTTP & SSE Microservice.
Lightweight, zero-framework HTTP server built directly with Python asyncio.
Listens strictly on 127.0.0.1.
"""

import asyncio
import json
import os
import sys
import urllib.parse
from pathlib import Path
from typing import Callable, Dict, Any

# 🔴 必须在导入本工程模块之前设置：禁止写出字节码。
# 安装态下 Python 会在 Contents/Resources/Sidecar/ 生成 __pycache__，
# 破坏代码签名封印（触发 TCC/钥匙串反复授权）。本地模块仅 4 个，
# 每次启动重新编译的代价（数十毫秒）远低于签名失效的代价。
sys.dont_write_bytecode = True

from gemini_engine import (
    GeminiEngine,
    extract_chrome_cookies,
    save_credentials,
    get_credentials,
    OUTPUT_DIR,
    DEFAULT_ENV_FILE,
    USER_ENV_FILE,
    _normalize_polished,
)
from jev import judge_params

PORT = int(os.environ.get("PRISM_PORT", 5188))
HOST = "127.0.0.1"

engine = GeminiEngine()
# 多任务并行：task_id -> 正在跑的生成任务（SSE 处理器）。
# /cancel 带 task_id 只停一个；不带则停全部（向后兼容旧客户端）。
active_generation_tasks: Dict[str, Any] = {}

async def verify_saved_credentials() -> tuple:
    """保存凭据后立即回验登录态，避免把「存进去了但无效」的 Cookie 当成功。"""
    try:
        await engine._build_verified_client(timeout=25, allow_heal=False)
        return True, "凭据已保存，登录态校验通过"
    except Exception as e:
        return False, f"凭据已保存，但登录态校验失败：{e}"

async def parse_request(reader: asyncio.StreamReader):
    """Parse HTTP request line and headers."""
    request_line = await reader.readline()
    if not request_line:
        return None, None, None, None

    parts = request_line.decode("utf-8").strip().split(" ")
    if len(parts) < 2:
        return None, None, None, None

    method, full_path = parts[0], parts[1]
    parsed_url = urllib.parse.urlparse(full_path)
    path = parsed_url.path

    headers = {}
    content_length = 0
    while True:
        line = await reader.readline()
        if not line or line == b"\r\n" or line == b"\n":
            break
        header_text = line.decode("utf-8").strip()
        if ":" in header_text:
            k, v = header_text.split(":", 1)
            k_lower = k.strip().lower()
            headers[k_lower] = v.strip()
            if k_lower == "content-length":
                content_length = int(v.strip())

    body = b""
    if content_length > 0:
        body = await reader.readexactly(content_length)

    return method, path, headers, body

async def send_json(writer: asyncio.StreamWriter, status_code: int, data: Dict[str, Any]):
    body = json.dumps(data, ensure_ascii=False).encode("utf-8")
    status_text = "OK" if status_code == 200 else ("Not Found" if status_code == 404 else "Error")
    resp = (
        f"HTTP/1.1 {status_code} {status_text}\r\n"
        "Content-Type: application/json; charset=utf-8\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "Connection: close\r\n\r\n"
    ).encode("utf-8") + body
    writer.write(resp)
    await writer.drain()
    writer.close()

async def handle_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    try:
        method, path, headers, body = await parse_request(reader)
        if not method:
            writer.close()
            return

        # 1. Health check
        if method == "GET" and path == "/health":
            psid, psidts = get_credentials(auto_extract=False)
            await send_json(writer, 200, {
                "status": "ok",
                "has_auth": bool(psid and psidts),
                "port": PORT
            })
            return

        # 2. Auth status
        if method == "GET" and path == "/auth/status":
            auth_info = await engine.verify_auth()
            await send_json(writer, 200, auth_info)
            return

        # 3. Set cookie manually (from WebKit)
        if method == "POST" and path == "/auth/set-cookie":
            try:
                payload = json.loads(body.decode("utf-8"))
                psid = payload.get("psid", "").strip()
                psidts = payload.get("psidts", "").strip()
                if psid and psidts:
                    save_credentials(psid, psidts)
                    ok, msg = await verify_saved_credentials()
                    await send_json(writer, 200 if ok else 400, {"success": ok, "message": msg})
                else:
                    await send_json(writer, 400, {"success": False, "message": "缺失必要 Cookie 字段"})
            except Exception as e:
                await send_json(writer, 500, {"success": False, "error": str(e)})
            return

        # 4. Sync from Chrome
        if method == "POST" and path == "/auth/sync-chrome":
            psid, psidts = extract_chrome_cookies()
            if psid and psidts:
                save_credentials(psid, psidts)
                ok, msg = await verify_saved_credentials()
                await send_json(writer, 200 if ok else 400, {
                    "success": ok,
                    "message": ("已从 Chrome 同步凭据，" + msg) if ok else msg,
                    "psid_masked": f"{psid[:6]}...{psid[-4:]}"
                })
            else:
                await send_json(writer, 400, {
                    "success": False,
                    "message": "未能从 Chrome 读取有效 Cookie，请确认已在 Chrome 登录 gemini.google.com"
                })
            return

        # 5. Serve static generated image files（新图按 YYYY-MM 子目录存放，
        # 根目录找不到时回退递归查找；旧图仍在根目录）
        if method == "GET" and path.startswith("/outputs/"):
            filename = os.path.basename(path)
            file_path = OUTPUT_DIR / filename
            if not file_path.exists():
                matches = [p for p in OUTPUT_DIR.rglob(filename) if p.is_file()]
                if matches:
                    file_path = matches[0]
            if file_path.exists() and file_path.is_file():
                content = file_path.read_bytes()
                mime = "image/png" if filename.endswith(".png") else "image/jpeg"
                resp = (
                    f"HTTP/1.1 200 OK\r\n"
                    f"Content-Type: {mime}\r\n"
                    f"Content-Length: {len(content)}\r\n"
                    "Access-Control-Allow-Origin: *\r\n"
                    "Connection: close\r\n\r\n"
                ).encode("utf-8") + content
                writer.write(resp)
                await writer.drain()
                writer.close()
                return
            else:
                await send_json(writer, 404, {"error": "Image file not found"})
                return

        # 6. Cancel ongoing generation（带 task_id 只停一个；不带则停全部）
        if method == "POST" and path == "/cancel":
            try:
                cancel_payload = json.loads(body.decode("utf-8")) if body else {}
            except Exception:
                cancel_payload = {}
            tid = (cancel_payload.get("task_id") or "").strip()
            targets = [tid] if tid else list(active_generation_tasks.keys())
            cancelled = []
            for k in targets:
                t = active_generation_tasks.get(k)
                if t is not None and not t.done():
                    t.cancel()
                    cancelled.append(k)
            if tid:
                active_generation_tasks.pop(tid, None)
            if cancelled:
                await send_json(writer, 200, {
                    "success": True,
                    "message": f"已中止 {len(cancelled)} 个生图任务",
                    "cancelled": cancelled,
                })
            else:
                await send_json(writer, 200, {
                    "success": True,
                    "message": "无正在运行的任务",
                    "cancelled": [],
                    "active": list(active_generation_tasks.keys()),
                })
            return

        # 7. Polish Prompt with AI
        if method == "POST" and path == "/polish":
            try:
                payload = json.loads(body.decode("utf-8")) if body else {}
                p_text = payload.get("prompt", "").strip()
                p_style = payload.get("style", "")
                p_mode = (payload.get("mode", "") or "describe").strip() or "describe"
                p_api_key = payload.get("custom_api_key", "").strip()
                p_base_url = payload.get("custom_base_url", "").strip()
                p_model = payload.get("custom_model", "").strip()

                if not p_text:
                    await send_json(writer, 400, {"success": False, "error": "提示词不能为空"})
                    return

                polished = await engine.polish_prompt(
                    prompt=p_text,
                    style=p_style,
                    custom_api_key=p_api_key,
                    custom_base_url=p_base_url,
                    custom_model=p_model,
                    mode=p_mode,
                )
                await send_json(writer, 200, {"success": True, "polished_prompt": polished})
            except Exception as e:
                await send_json(writer, 500, {"success": False, "error": str(e)})
            return

        # 7.5 Polish Prompt with AI（SSE 流式，逐字回吐）
        if method == "POST" and path == "/polish/stream":
            try:
                payload = json.loads(body.decode("utf-8")) if body else {}
            except Exception:
                payload = {}
            p_text = payload.get("prompt", "").strip()
            p_style = payload.get("style", "")
            p_mode = (payload.get("mode", "") or "describe").strip() or "describe"
            p_api_key = payload.get("custom_api_key", "").strip()
            p_base_url = payload.get("custom_base_url", "").strip()
            p_model = payload.get("custom_model", "").strip()

            sse_header = (
                "HTTP/1.1 200 OK\r\n"
                "Content-Type: text/event-stream; charset=utf-8\r\n"
                "Cache-Control: no-cache, no-transform\r\n"
                "Connection: keep-alive\r\n"
                "Access-Control-Allow-Origin: *\r\n\r\n"
            ).encode("utf-8")
            writer.write(sse_header)
            await writer.drain()

            async def sse_callback(event_data: Dict[str, Any]):
                chunk = f"data: {json.dumps(event_data, ensure_ascii=False)}\n\n".encode("utf-8")
                writer.write(chunk)
                await writer.drain()

            try:
                if not p_text:
                    await sse_callback({"stage": "error", "message": "提示词不能为空"})
                else:
                    collected = []
                    async for delta in engine.polish_prompt_stream(
                        prompt=p_text,
                        style=p_style,
                        custom_api_key=p_api_key,
                        custom_base_url=p_base_url,
                        custom_model=p_model,
                        mode=p_mode,
                    ):
                        collected.append(delta)
                        await sse_callback({"stage": "delta", "message": delta})
                    # 全文归一化后作为最终帧，前端以它为准替换打字机过程文本
                    final_text = _normalize_polished("".join(collected))
                    await sse_callback({"stage": "completed", "message": final_text})
            except asyncio.CancelledError:
                pass
            except Exception as e:
                await sse_callback({"stage": "error", "message": str(e)})
            finally:
                try:
                    writer.close()
                    await writer.wait_closed()
                except Exception:
                    pass
            return

        # 8. Test Custom API (fast ping)
        if method == "POST" and path == "/api/test":
            try:
                payload = json.loads(body.decode("utf-8")) if body else {}
                key = payload.get("custom_api_key", "").strip()
                base = payload.get("custom_base_url", "").strip()
                model = payload.get("custom_model", "").strip()
                if not key:
                    await send_json(writer, 400, {"success": False, "message": "API Key 不能为空"})
                    return
                res = await engine.test_custom_api(key, base, model)
                await send_json(writer, 200, res)
            except Exception as e:
                await send_json(writer, 500, {"success": False, "message": str(e)})
            return

        # 9. Clear credentials
        if method == "POST" and path == "/auth/clear":
            try:
                cleared = []
                for env_file in (USER_ENV_FILE, DEFAULT_ENV_FILE):
                    # 运行期缓存一律清除；出厂种子仅在开发目录（非 .app 内）时一并清除，
                    # 避免误删 Bundle 内受签名保护的文件。
                    if env_file.exists() and ".app/" not in str(env_file):
                        env_file.unlink()
                        cleared.append(str(env_file))
                await send_json(writer, 200, {"success": True, "message": "凭据已清除", "cleared": cleared})
            except Exception as e:
                await send_json(writer, 500, {"success": False, "error": str(e)})
            return

        # 9. Generate Images (SSE Stream)
        if method == "POST" and path == "/generate":
            try:
                payload = json.loads(body.decode("utf-8")) if body else {}
            except Exception:
                payload = {}
            # 多任务并行：按 task_id 注册，/cancel 才能只停这一个
            task_id = (payload.get("task_id") or "").strip() or f"auto-{id(asyncio.current_task())}"
            active_generation_tasks[task_id] = asyncio.current_task()

            prompt = payload.get("prompt", "").strip()
            aspect_ratio = payload.get("aspect_ratio", "1:1")
            negative_prompt = payload.get("negative_prompt", "")
            style_context = payload.get("style_context", "")
            max_kb = payload.get("max_kb", 0)

            # Start SSE Headers
            sse_header = (
                "HTTP/1.1 200 OK\r\n"
                "Content-Type: text/event-stream; charset=utf-8\r\n"
                "Cache-Control: no-cache, no-transform\r\n"
                "Connection: keep-alive\r\n"
                "Access-Control-Allow-Origin: *\r\n\r\n"
            ).encode("utf-8")
            writer.write(sse_header)
            await writer.drain()

            async def sse_callback(event_data: Dict[str, Any]):
                chunk = f"data: {json.dumps(event_data, ensure_ascii=False)}\n\n".encode("utf-8")
                writer.write(chunk)
                await writer.drain()

            try:
                if not prompt:
                    await sse_callback({"stage": "error", "message": "提示词不能为空"})
                else:
                    await engine.generate(
                        prompt=prompt,
                        aspect_ratio=aspect_ratio,
                        negative_prompt=negative_prompt,
                        style_context=style_context,
                        max_kb=max_kb,
                        progress_callback=sse_callback
                    )
            except asyncio.CancelledError:
                await sse_callback({"stage": "error", "message": "用户已手动停止生成"})
            except Exception as e:
                await sse_callback({"stage": "error", "message": f"生图异常: {str(e)}"})
            finally:
                active_generation_tasks.pop(task_id, None)
                try:
                    writer.close()
                    await writer.wait_closed()
                except Exception:
                    pass
            return

        # 10. Generate with reference image (SSE Stream)
        if method == "POST" and path == "/generate-with-image":
            try:
                payload = json.loads(body.decode("utf-8")) if body else {}
            except Exception:
                payload = {}
            # 多任务并行：按 task_id 注册，/cancel 才能只停这一个
            task_id = (payload.get("task_id") or "").strip() or f"auto-{id(asyncio.current_task())}"
            active_generation_tasks[task_id] = asyncio.current_task()

            image_path = payload.get("image_path", "").strip()
            prompt = payload.get("prompt", "").strip()
            aspect_ratio = payload.get("aspect_ratio", "1:1")
            style_context = payload.get("style_context", "")
            negative_prompt = payload.get("negative_prompt", "")
            max_kb = payload.get("max_kb", 0)

            # Start SSE Headers
            sse_header = (
                "HTTP/1.1 200 OK\r\n"
                "Content-Type: text/event-stream; charset=utf-8\r\n"
                "Cache-Control: no-cache, no-transform\r\n"
                "Connection: keep-alive\r\n"
                "Access-Control-Allow-Origin: *\r\n\r\n"
            ).encode("utf-8")
            writer.write(sse_header)
            await writer.drain()

            async def sse_callback(event_data: Dict[str, Any]):
                chunk = f"data: {json.dumps(event_data, ensure_ascii=False)}\n\n".encode("utf-8")
                writer.write(chunk)
                await writer.drain()

            try:
                if not image_path:
                    await sse_callback({"stage": "error", "message": "请先选择参考图"})
                elif not prompt:
                    await sse_callback({"stage": "error", "message": "修改描述不能为空"})
                else:
                    await engine.generate_with_image(
                        image_path=image_path,
                        prompt=prompt,
                        aspect_ratio=aspect_ratio,
                        style_context=style_context,
                        negative_prompt=negative_prompt,
                        max_kb=max_kb,
                        progress_callback=sse_callback
                    )
            except asyncio.CancelledError:
                await sse_callback({"stage": "error", "message": "用户已手动停止生成"})
            except Exception as e:
                await sse_callback({"stage": "error", "message": f"参考图生图异常: {str(e)}"})
            finally:
                active_generation_tasks.pop(task_id, None)
                try:
                    writer.close()
                    await writer.wait_closed()
                except Exception:
                    pass
            return

        # 10.5 Multi-turn session edit (SSE Stream)
        if method == "POST" and path == "/session/edit":
            try:
                payload = json.loads(body.decode("utf-8")) if body else {}
            except Exception:
                payload = {}
            # 多任务并行：按 task_id 注册，/cancel 才能只停这一个
            task_id = (payload.get("task_id") or "").strip() or f"auto-{id(asyncio.current_task())}"
            active_generation_tasks[task_id] = asyncio.current_task()

            source_image_path = payload.get("source_image_path", "").strip()
            instruction = payload.get("instruction", "").strip()
            session_id = payload.get("session_id", "").strip()
            aspect_ratio = payload.get("aspect_ratio", "1:1")
            style_context = payload.get("style_context", "")
            negative_prompt = payload.get("negative_prompt", "")
            max_kb = payload.get("max_kb", 0)

            sse_header = (
                "HTTP/1.1 200 OK\r\n"
                "Content-Type: text/event-stream; charset=utf-8\r\n"
                "Cache-Control: no-cache, no-transform\r\n"
                "Connection: keep-alive\r\n"
                "Access-Control-Allow-Origin: *\r\n\r\n"
            ).encode("utf-8")
            writer.write(sse_header)
            await writer.drain()

            async def sse_callback(event_data: Dict[str, Any]):
                chunk = f"data: {json.dumps(event_data, ensure_ascii=False)}\n\n".encode("utf-8")
                writer.write(chunk)
                await writer.drain()

            try:
                if not instruction:
                    await sse_callback({"stage": "error", "message": "修改描述不能为空"})
                else:
                    await engine.edit_image(
                        source_image_path=source_image_path,
                        instruction=instruction,
                        session_id=session_id,
                        aspect_ratio=aspect_ratio,
                        style_context=style_context,
                        negative_prompt=negative_prompt,
                        max_kb=max_kb,
                        progress_callback=sse_callback
                    )
            except asyncio.CancelledError:
                await sse_callback({"stage": "error", "message": "用户已手动停止生成"})
            except Exception as e:
                await sse_callback({"stage": "error", "message": f"改图异常: {str(e)}"})
            finally:
                active_generation_tasks.pop(task_id, None)
                try:
                    writer.close()
                    await writer.wait_closed()
                except Exception:
                    pass
            return

        # 10.6 Close a chat session
        if method == "POST" and path == "/session/close":
            try:
                payload = json.loads(body.decode("utf-8")) if body else {}
                sid = payload.get("session_id", "").strip()
                closed = await engine.close_session(sid)
                await send_json(writer, 200, {"success": True, "closed": closed})
            except Exception as e:
                await send_json(writer, 500, {"success": False, "error": str(e)})
            return

        # 10.7 Suggest negative prompt (自定义文本模型)
        if method == "POST" and path == "/suggest-negative":
            try:
                payload = json.loads(body.decode("utf-8")) if body else {}
                p_text = payload.get("prompt", "").strip()
                p_style = payload.get("style", "")
                api_key = payload.get("custom_api_key", "").strip()
                base_url = payload.get("custom_base_url", "").strip()
                model = payload.get("custom_model", "").strip()

                if not p_text:
                    await send_json(writer, 400, {"success": False, "error": "请先填写主体描述"})
                    return

                negative = await engine.suggest_negative_prompt(
                    prompt=p_text,
                    style=p_style,
                    custom_api_key=api_key,
                    custom_base_url=base_url,
                    custom_model=model
                )
                await send_json(writer, 200, {"success": True, "negative_prompt": negative})
            except Exception as e:
                await send_json(writer, 500, {"success": False, "error": str(e)})
            return

        # 10.8 Suggest style + aspect ratio (TypeSafe Jev 判定层)
        if method == "POST" and path == "/suggest-params":
            try:
                payload = json.loads(body.decode("utf-8")) if body else {}
                description = payload.get("description", "")
                styles = payload.get("styles", {}) or {}
                aspects = payload.get("aspects", {}) or {}
                has_ref = bool(payload.get("has_reference_image", False))

                # 一律 200 返回，由 success 字段表达成败 —— UI 侧统一静默降级
                result = await judge_params(
                    description=description,
                    styles=styles,
                    aspects=aspects,
                    has_reference_image=has_ref,
                )
                await send_json(writer, 200, result)
            except Exception as e:
                await send_json(writer, 200, {"success": False, "error": str(e)})
            return

        # 10.9 一条龙：润色 + 配参 + 负面词（SSE 分阶段汇报）
        if method == "POST" and path == "/optimize-all":
            try:
                payload = json.loads(body.decode("utf-8")) if body else {}
            except Exception:
                payload = {}

            description = payload.get("description", "").strip()
            style = payload.get("style", "")
            styles = payload.get("styles", {}) or {}
            aspects = payload.get("aspects", {}) or {}
            has_ref = bool(payload.get("has_reference_image", False))
            polish_mode = (payload.get("polish_mode", "") or "describe").strip() or "describe"
            analysis_text = (payload.get("analysis_text", "") or "").strip()
            api_key = payload.get("custom_api_key", "").strip()
            base_url = payload.get("custom_base_url", "").strip()
            model = payload.get("custom_model", "").strip()

            sse_header = (
                "HTTP/1.1 200 OK\r\n"
                "Content-Type: text/event-stream; charset=utf-8\r\n"
                "Cache-Control: no-cache, no-transform\r\n"
                "Connection: keep-alive\r\n"
                "Access-Control-Allow-Origin: *\r\n\r\n"
            ).encode("utf-8")
            writer.write(sse_header)
            await writer.drain()

            async def sse_callback(event_data: Dict[str, Any]):
                chunk = f"data: {json.dumps(event_data, ensure_ascii=False)}\n\n".encode("utf-8")
                writer.write(chunk)
                await writer.drain()

            try:
                if not description:
                    await sse_callback({"stage": "error", "message": "请先填写画面描述"})
                else:
                    result = await run_optimize_all(
                        engine, description, style, styles, aspects, has_ref,
                        api_key, base_url, model, sse_callback,
                        polish_mode=polish_mode, analysis_text=analysis_text,
                    )
                    await sse_callback({
                        "stage": "completed",
                        "message": "AI 优化完成",
                        "result": result,
                    })
            except Exception as e:
                await sse_callback({"stage": "error", "message": f"AI 优化失败: {str(e)}"})
            finally:
                try:
                    writer.close()
                    await writer.wait_closed()
                except Exception:
                    pass
            return

        # 11. Describe image
        if method == "POST" and path == "/describe-image":
            try:
                payload = json.loads(body.decode("utf-8")) if body else {}
                image_path = payload.get("image_path", "").strip()
                style = payload.get("style", "")
                api_key = payload.get("custom_api_key", "")
                base_url = payload.get("custom_base_url", "")
                # 图片描述专用模型（与润色/负面词的文本模型分开配置，见偏好设置 → AI 配置）
                vision_model = payload.get("custom_vision_model", "")

                if not image_path:
                    await send_json(writer, 400, {"success": False, "error": "图片路径不能为空"})
                    return

                description = await engine.describe_image(
                    image_path=image_path,
                    style=style,
                    custom_api_key=api_key,
                    custom_base_url=base_url,
                    vision_model=vision_model
                )
                await send_json(writer, 200, {"success": True, "description": description})
            except Exception as e:
                await send_json(writer, 500, {"success": False, "error": str(e)})
            return

        # 11.5 Describe image (SSE stream) —— 描述弹窗逐字显示
        if method == "POST" and path == "/describe-image/stream":
            try:
                payload = json.loads(body.decode("utf-8")) if body else {}
            except Exception:
                payload = {}

            image_path = payload.get("image_path", "").strip()
            style = payload.get("style", "")
            api_key = payload.get("custom_api_key", "")
            base_url = payload.get("custom_base_url", "")
            vision_model = payload.get("custom_vision_model", "")

            sse_header = (
                "HTTP/1.1 200 OK\r\n"
                "Content-Type: text/event-stream; charset=utf-8\r\n"
                "Cache-Control: no-cache, no-transform\r\n"
                "Connection: keep-alive\r\n"
                "Access-Control-Allow-Origin: *\r\n\r\n"
            ).encode("utf-8")
            writer.write(sse_header)
            await writer.drain()

            async def sse_callback(event_data: Dict[str, Any]):
                chunk = f"data: {json.dumps(event_data, ensure_ascii=False)}\n\n".encode("utf-8")
                writer.write(chunk)
                await writer.drain()

            try:
                if not image_path:
                    await sse_callback({"stage": "error", "message": "图片路径不能为空"})
                else:
                    parts: list[str] = []
                    async for delta in engine.describe_image_stream(
                        image_path=image_path,
                        style=style,
                        custom_api_key=api_key,
                        custom_base_url=base_url,
                        vision_model=vision_model,
                    ):
                        parts.append(delta)
                        await sse_callback({"stage": "delta", "message": delta})
                    full = "".join(parts).strip()
                    if not full:
                        await sse_callback({"stage": "error", "message": "AI 未返回描述内容"})
                    else:
                        # completed 帧携带裁齐后的全文，供前端覆盖增量拼接结果
                        await sse_callback({"stage": "completed", "message": full})
            except asyncio.CancelledError:
                await sse_callback({"stage": "error", "message": "描述已取消"})
            except Exception as e:
                await sse_callback({"stage": "error", "message": f"描述失败: {str(e)}"})
            finally:
                try:
                    writer.close()
                    await writer.wait_closed()
                except Exception:
                    pass
            return

        # Unknown route
        await send_json(writer, 404, {"error": "Route not found", "path": path})

    except Exception as e:
        try:
            await send_json(writer, 500, {"error": str(e)})
        except Exception:
            pass
        finally:
            writer.close()

async def run_optimize_all(
    engine: GeminiEngine,
    description: str,
    style: str,
    styles: Dict[str, str],
    aspects: Dict[str, str],
    has_reference_image: bool,
    api_key: str,
    base_url: str,
    model: str,
    report: Callable[[Dict[str, Any]], Any],
    polish_mode: str = "describe",
    analysis_text: str = "",
) -> Dict[str, Any]:
    """一条龙：润色 →（并发）判定画风比例 + 推荐负面提示词。

    参数分工（历史上下文与新画布不同）：
    - `description` + `polish_mode`：**润色对象**。新画布是主体描述（describe），
      历史上下文是修改指令（instruction，保持指令形态）。
    - `analysis_text`：**配参与负面词的依据**，应为「当前画面是什么」的描述。
      为空时沿用润色后的文本（新画布场景）。
    任一步失败都不阻断其余步骤，失败原因随结果一并返回，由 UI 提示。
    """
    # 1) 润色（流式逐字回吐）：失败则沿用原文，继续后续步骤
    await report({"stage": "polishing", "message": "正在丰富画面描述…"})
    polished, polish_error = description, None
    try:
        collected = []
        async for delta in engine.polish_prompt_stream(
            prompt=description,
            style=style,
            custom_api_key=api_key,
            custom_base_url=base_url,
            custom_model=model,
            mode=polish_mode,
        ):
            collected.append(delta)
            await report({"stage": "polish_delta", "message": delta})
        polished = _normalize_polished("".join(collected))
    except Exception as e:
        polish_error = str(e)

    # 配参与负面词看的是「画面长什么样」，与润色对象可以不是同一段文本
    basis = (analysis_text or "").strip() or polished

    # 2) 配参与负面词互不依赖，并发跑（总耗时 ≈ 两者较长者）
    await report({"stage": "analyzing", "message": "正在判定画风与比例、生成负面提示词…"})

    async def _negative():
        try:
            text = await engine.suggest_negative_prompt(
                prompt=basis,
                style=style,
                custom_api_key=api_key,
                custom_base_url=base_url,
                custom_model=model,
            )
            return text, None
        except Exception as e:
            return None, str(e)

    params_res, (negative, negative_error) = await asyncio.gather(
        judge_params(basis, styles, aspects, has_reference_image),
        _negative(),
    )

    result: Dict[str, Any] = {
        "polished_prompt": polished,
        "polish_error": polish_error,
        "negative_prompt": negative,
        "negative_error": negative_error,
        "needs_polish": params_res.get("needs_polish", 0.0),
    }
    if params_res.get("success"):
        result["style"] = params_res.get("style")
        result["aspect_ratio"] = params_res.get("aspect_ratio")
    else:
        result["params_error"] = params_res.get("error")
    return result


async def main():
    server = await asyncio.start_server(handle_client, HOST, PORT)
    print(f"🚀 Gemini Studio Sidecar running on http://{HOST}:{PORT}")
    sys.stdout.flush()
    async with server:
        await server.serve_forever()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n👋 Sidecar gracefully stopped.")
