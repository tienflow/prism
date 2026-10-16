# Prism

macOS 原生 AI 绘画与提示词工作室桌面应用。UI 基于 AppKit + SwiftUI 的 macOS 26 Liquid Glass 质感系统；生图通过本地 Python Sidecar 调用 Google Imagen 3 网页端管线，提示词润色支持 OpenAI 兼容第三方端点与内置 Gemini 会话双引擎。

## 功能

- **文生图 / 图生图**：中文提示词 + 画幅比例 + 15 种画风预设，可挂一张参考图走图生图
- **多轮会话改图**：「继续修改当前画面」在**同一条记录**内持续迭代（模型保留上一轮画面上下文），每次产出一「稿」，可左右切换并回看每轮的修改指令与参数
- **负面提示词**：手动填写或「AI 推荐」按主体描述自动生成；画风 / 比例 / 负面词在生图、图生图、改图三条链路上一致生效
- **提示词 AI 润色**：OpenAI 兼容端点 + 内置 Gemini 会话双引擎，均支持一键撤回
- **画面元数据弹窗**：提示词、负面词、比例、画风、画幅尺寸与体积、生成时间，以及完整改图轮次
- **画作处置**：复制原图 / 另存为 / 按目标体积压缩导出 / 访达定位；删除记录时清理全部伴生资源
- **键盘流**：`←` `→` 切换稿件、`空格` Quick Look 预览、`I` 画面元数据、`⌘↩` 开始生图、`⌘⇧↩` 继续修改

## 安装

从 [Releases](https://github.com/tienflow/prism/releases) 下载最新的 `Prism-v1.1.0.dmg`，拖入「应用程序」即可（首次打开若被拦截，在「系统设置 → 隐私与安全性」中放行）。

## 架构

| 层 | 技术 | 说明 |
|---|---|---|
| UI 层 | Swift 6.0 + AppKit + SwiftUI | 原生 `NSGlassEffectView` 双层材质衬底 + `LiquidGlassCard` 卡片体系 |
| Sidecar | Python 3.14（asyncio，零框架） | 仅监听 `127.0.0.1:5188`，提供 SSE 流式生图、提示词润色、连通性探测 |
| 生图引擎 | Imagen 3 网页端管线 | 支持从 Chrome 钥匙串提取 Cookie 或内置 WebKit 手动登录 |
| 润色引擎 | OpenAI 兼容 API | 端点自动适配 + 候选模型无感重试；报错直抛，不静默降级 |

## 环境要求

- macOS 14+（Liquid Glass 效果需 macOS 26）
- Swift 6.0 / Xcode Command Line Tools
- Python 3.14（Homebrew：`/opt/homebrew/bin/python3`）

## 构建与运行

⚠️ **macOS 26+ CLT（SDK 27）缺 `libSwiftUIMacros.dylib`**，构建前必须显式锁定 SDK：

```zsh
export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
```

编译并直接运行：

```zsh
./run.sh
```

完整打包（编译 → 组装 `.app` → 签名 → 生成 DMG → 安装至 `/Applications` 并平滑重启）：

```zsh
./package_dmg.sh
```

## 配置凭据

首次运行在偏好设置中配置，或手动创建 `.env`：

```zsh
cp Sidecar/.env.example Sidecar/.env
```

`.env` 已被 `.gitignore` 排除，**绝不提交**。Cookie 失效后重新提取即可。第三方润色端点的 Base URL / API Key 在 App 偏好设置内填写，保存在本机，不随源码分发。

## 目录结构

```
Sources/Prism/          # 主 library：Design / Models / Services / Views
Sources/PrismApp/       # 可执行入口（App 生命周期、窗口与菜单）
Sidecar/                # Python 异步服务（server.py / gemini_engine.py / optimizer.py）
package_dmg.sh          # 打包与部署脚本
run.sh                  # 一键编译启动
Info.plist              # Bundle 元数据
```

本地数据与产出统一存放于 `~/Pictures/Prism/`（生图、`history.json` 历史批次、`.ai_analysis.json` 图像描述缓存、`.thumbnails` 缩略图）。

## 说明

- 生图管线走 Google 网页端逆向会话协议，**仅供个人学习与研究使用**，请自行遵守目标服务的条款。
- 凭据完全存放于本机（`.env` 或系统钥匙串），不经过任何第三方服务器。
