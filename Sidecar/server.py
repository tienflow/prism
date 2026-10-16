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
from typing import Dict, Any

from gemini_engine import GeminiEngine, extract_chrome_cookies, save_credentials, get_credentials, OUTPUT_DIR

PORT = int(os.environ.get("PRISM_PORT", 5188))
HOST = "127.0.0.1"

engine = GeminiEngine()
active_generation_task = None

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
    global active_generation_task
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
                    await send_json(writer, 200, {"success": True, "message": "凭据已保存"})
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
                await send_json(writer, 200, {
                    "success": True,
                    "message": "已从 Chrome 提取并同步凭据",
                    "psid_masked": f"{psid[:6]}...{psid[-4:]}"
                })
            else:
                await send_json(writer, 400, {
                    "success": False,
                    "message": "未能从 Chrome 读取有效 Cookie，请确认已在 Chrome 登录 gemini.google.com"
                })
            return

        # 5. Serve static generated image files
        if method == "GET" and path.startswith("/outputs/"):
            filename = os.path.basename(path)
            file_path = OUTPUT_DIR / filename
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

        # 6. Cancel ongoing generation
        if method == "POST" and path == "/cancel":
            if active_generation_task and not active_generation_task.done():
                active_generation_task.cancel()
                active_generation_task = None
                await send_json(writer, 200, {"success": True, "message": "已中止生图任务"})
            else:
                await send_json(writer, 200, {"success": True, "message": "无正在运行的任务"})
            return

        # 7. Polish Prompt with AI
        if method == "POST" and path == "/polish":
            try:
                payload = json.loads(body.decode("utf-8")) if body else {}
                p_text = payload.get("prompt", "").strip()
                p_style = payload.get("style", "")
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
                    custom_model=p_model
                )
                await send_json(writer, 200, {"success": True, "polished_prompt": polished})
            except Exception as e:
                await send_json(writer, 500, {"success": False, "error": str(e)})
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
                env_file = DEFAULT_ENV_FILE
                if env_file.exists():
                    env_file.unlink()
                await send_json(writer, 200, {"success": True, "message": "凭据已清除"})
            except Exception as e:
                await send_json(writer, 500, {"success": False, "error": str(e)})
            return

        # 9. Generate Images (SSE Stream)
        if method == "POST" and path == "/generate":
            active_generation_task = asyncio.current_task()

            try:
                payload = json.loads(body.decode("utf-8")) if body else {}
            except Exception:
                payload = {}

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
                active_generation_task = None
                try:
                    writer.close()
                    await writer.wait_closed()
                except Exception:
                    pass
            return

        # 10. Generate with reference image (SSE Stream)
        if method == "POST" and path == "/generate-with-image":
            active_generation_task = asyncio.current_task()

            try:
                payload = json.loads(body.decode("utf-8")) if body else {}
            except Exception:
                payload = {}

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
                active_generation_task = None
                try:
                    writer.close()
                    await writer.wait_closed()
                except Exception:
                    pass
            return

        # 10.5 Multi-turn session edit (SSE Stream)
        if method == "POST" and path == "/session/edit":
            active_generation_task = asyncio.current_task()

            try:
                payload = json.loads(body.decode("utf-8")) if body else {}
            except Exception:
                payload = {}

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
                active_generation_task = None
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

        # 11. Describe image
        if method == "POST" and path == "/describe-image":
            try:
                payload = json.loads(body.decode("utf-8")) if body else {}
                image_path = payload.get("image_path", "").strip()
                style = payload.get("style", "")
                api_key = payload.get("custom_api_key", "")
                base_url = payload.get("custom_base_url", "")
                model = payload.get("custom_model", "")

                if not image_path:
                    await send_json(writer, 400, {"success": False, "error": "图片路径不能为空"})
                    return

                description = await engine.describe_image(
                    image_path=image_path,
                    style=style,
                    custom_api_key=api_key,
                    custom_base_url=base_url,
                    custom_model=model
                )
                await send_json(writer, 200, {"success": True, "description": description})
            except Exception as e:
                await send_json(writer, 500, {"success": False, "error": str(e)})
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
