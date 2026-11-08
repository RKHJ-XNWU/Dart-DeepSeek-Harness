<div align="center">

# 🐋 Dart · DeepSeek Harness

**把整台安卓手机变成你的Harness工作站**

100% 纯 Dart 重写 · 零第三方依赖 · 单文件可执行 · 原生 Web UI

[![Dart](https://img.shields.io/badge/Dart-3.0%2B-0175C2?logo=dart&logoColor=white)](https://dart.dev)
[![Dependencies](https://img.shields.io/badge/dependencies-0-brightgreen)](#-技术架构)
[![Platform](https://img.shields.io/badge/platform-Android%20%2F%20Termux-3DDC84?logo=android&logoColor=white)](#-环境要求)
[![Version](https://img.shields.io/badge/version-2.1.0-blue)](#)
[![i18n](https://img.shields.io/badge/i18n-6%20languages-orange)](#-多语言支持)

</div>

---

## 📖 目录

- [项目简介](#-项目简介)
- [核心特性](#-核心特性)
- [模型使用指南](#-模型使用指南)
- [多语言支持](#-多语言支持)
- [环境要求](#-环境要求)
- [快速开始](#-快速开始)
- [使用教程](#-使用教程)
- [自动化操作引擎](#-自动化操作引擎)
- [配置项说明](#-配置项说明)
- [目录结构](#-目录结构)
- [技术架构](#-技术架构)
- [常见问题](#-常见问题)
- [版权声明与二次分发](#-版权声明与二次分发)
- [免责声明](#-免责声明)

---

## 🌟 项目简介

**Dart · DeepSeek Harness**（简称 ddsh）是一个运行在 Android 手机（Termux 环境）上的本地 AI 网关 + 网页客户端。

它在本机启动一个 HTTP 服务（默认端口 `9999`），你在浏览器打开 `http://127.0.0.1:9999/` 就能得到一套完整的 AI 工作站界面：

- **前端**：原生 HTML / CSS / JavaScript，无框架、无构建步骤、无 CDN 依赖
- **后端**：由 Go 版 14,080 行代码 100% 重写为纯 Dart，`pubspec.yaml` 中 `dependencies: {}` 为空，HTTP 服务、AES-256-GCM 加密、tar.gz 打包全部手写实现
- **一键编译**：`dart compile exe` 生成单文件二进制，不依赖任何运行时库
- **多模型接入**：同时支持 DeepSeek 官方 API 与火山方舟豆包全家桶（17 个预置模型）
- **全自动化**：内置 90+ 工具，模型可自主规划并调用，真正实现「说一句话，手机自己动」

| 维度 | 说明 |
| :--- | :--- |
| 🎯 定位 | 手机上的一体化 AI 控制台 |
| 🧩 模型 | DeepSeek 官方 API + 火山方舟豆包全家桶 |
| 🖥 形态 | 本地 Web 服务 + 浏览器 UI（无 App 安装） |
| 🤖 能力 | 聊天 + 识图 + 识音 + 识影 + 文生图 + 文生视频 + 90+ 工具自动化 |
| 🌐 语言 | 日本語 / 简体中文 / English / 한국어 / Русский / Français |

---

## ✨ 核心特性

### 🧠 DeepSeek 核心对话

| 功能 | 说明 |
| :--- | :--- |
| 💬 多会话管理 | 会话列表、单条/批量删除、全部清除、会话内引用（`session-mention`） |
| ⚡ SSE 流式输出 | 逐字流式渲染，思考链（reasoning）与实际回答分离显示 |
| 🔍 全文搜索 | 跨会话内容搜索，游标分页，命中片段高亮（摘要上限 300 字） |
| 🧾 长文本模式 | 单次上下文默认放宽至 150,000 字符 |
| 📝 小说模式 | 分段续写生成，避免单次输出截断 |
| 🌐 联网搜索 | 调用 DeepSeek 官方 `tools/search` 与 `tools/fetch` 接口（仅 DeepSeek 模式） |
| 💰 用量计费 | 每次对话/翻译按官方单价折算实际费用 |
| 🔊 朗读（TTS） | Edge TTS 流式合成，按文本语种自动切换音色（日→Nanami、中→Xiaoxiao 等） |
| 🎤 语音输入（STT） | 录音转文字后直接入框 |
| 🌏 一键翻译 | 对任意回复生成译文，可复制、可朗读，并单独计费 |

### 🎨 豆包（火山方舟）全家桶

> 与 DeepSeek Key 分开保存，互不覆盖；模型可单独指定，也可交由自动路由。

| 模块 | 能力 | 可选模型 |
| :--- | :--- | :--- |
| 🖼 文生图 | 提示词生成图片，自动落盘 | Seedream 4.5 / 5.0 Lite / 5.0 pro |
| 🖌 P 图 | 携带参考图做图像编辑 | SeedEdit 3.0、Seedream 5.0 pro |
| 🎬 视频生成 | 异步任务创建 + 状态轮询 + 任务历史列表 | Seedance 2.0 / 2.0 fast / 2.0 mini |
| 🔊 音频生成 | 文本转语音，产物存入 `ds_files/blob` | SeedAudio 1.0 |
| 🎧 播客 | 台本生成 → 语音合成，输出完整音频 | 播客模型 + TTS 模型组合 |
| 🎤 录音识别 | 上传录音文件做 ASR 转写 | Seed ASR 2.0 / Streaming 2.0 |
| 📞 语音通话 | 多轮语音会话（voice/turn） | 实时语音模型 |
| 📊 音频分析 | 对音频内容做理解与摘要 | 多模态模型 |
| 🔄 实时语音 | Seeduplex 全双工，WebSocket 由本地服务代理并注入鉴权头 | 端到端实时语音模型 |
| 📹 RTC 互动 | 服务端编排 `StartVoiceChat` / `StopVoiceChat` 任务 | RTC 音视频智能体 |

### 📱 手机实操能力（工具模式）

内置 90+ 工具的 JSON Schema 与执行器，模型可自主规划并调用：

```text
📂 文件系统   list_dir · read_file · create_file · append_file · get_file_size
🌐 网络       http_request · download_file
⚙️ 进程       list_processes · kill_process
🖥 Shell      execute_command · batch_command · run_background
👆 界面控制   tap · long_press · swipe · batch_tap · batch_swipe · input_text · key_event
🔎 控件识别   find_element · wait_for_element · ui_dump · get_screen_text · ocr_screen
🧹 弹窗处理   is_popup_present · dismiss_popup · auto_dismiss_dialogs
📦 应用管理   start_app · force_stop_app · list_packages · install_apk · uninstall_app
🔐 权限设置   grant_permission · appops_set · settings_get / settings_put
📶 系统状态   battery_status · wifi_info · wifi_scan · volume_set · brightness
🎙 Termux API clipboard · notify · toast · tts_speak · vibrate · location · camera_photo
```

单次任务支持最多 50,000 轮工具调用循环。

### 🗂 附加模块

| 模块 | 说明 |
| :--- | :--- |
| 📁 文件管理 | 分片上传（断点续传）、下载、按分类检索、按月归档元数据，单文件上限 5GB |
| 📚 日语单词本 | 单词按首字分片存储，图片按哈希分入 256 个桶，删词自动清理空桶 |
| 💬 论坛 · 帖子广场 | 发帖、置顶、精选、屏蔽、批量删除；标题 ≤ 5000 字，正文 ≤ 500 万字 |
| 📢 公告系统 | 定时生效、强制置顶、优先级排序，最多同时 5 条 |
| ⏰ 峰谷提醒 | DeepSeek 官方峰谷定价时段判定，内置 11 个时区与夏令时规则，支持 7 种推送渠道 |
| 🎭 角色扮演 | 兼容 Tavern v2 字段，可随时开关 |
| 🐦 X（Twitter） | 发布推文、拉取时间线 |
| 🛠 开发者工具 | Prompt 模板的集中管理与批量删除 |

---

## 🧩 模型使用指南

本项目接入两大模型平台，根据不同场景选择最合适的模型：

### 模型选择对照表

| 使用场景 | 推荐模型 | 模型值 | 平台 | 说明 |
| :--- | :--- | :--- | :--- | :--- |
| 💬 日常对话 | Doubao-Seed-2.0-lite | `doubao-seed-2-0-lite-260428` | 火山方舟 | 默认模型，支持识图、识音、识影，响应快、成本低 |
| 🤖 自动化任务 | Doubao-Seed-2.1-pro | `doubao-seed-2-1-pro-260628` | 火山方舟 | 推理能力强，适合工具调用与复杂自动化操作 |
| 💻 编程开发 | Doubao-Seed-Evolving | `doubao-seed-evolving-latest-version` | 火山方舟 | 专为编程优化，代码生成与调试能力突出 |
| 📖 文学创作 | GLM-5.2 | `glm-5-2-260617` | 火山方舟 | 文学性强，适合小说、散文、诗歌等创意写作 |
| 🌏 翻译 | DeepSeek API | `deepseek-chat` 等 | DeepSeek | 翻译功能始终调用 DeepSeek API，不走豆包通道 |

### 模型详细说明

#### Doubao-Seed-2.0-lite（默认模型）

- **适用场景**：日常对话、图片识别、音频识别、视频识别
- **能力**：多模态理解（text + image + audio + video），响应速度快
- **特点**：轻量级模型，适合高频日常使用，成本最低
- **设置方式**：在设置页面选择该模型，或在豆包配置中将对话模型设为此值

#### Doubao-Seed-2.1-pro（自动化任务）

- **适用场景**：工具模式自动化操作、复杂推理任务、多步骤规划
- **能力**：强大的推理与规划能力，能稳定调用 90+ 工具完成复杂操作链
- **特点**：在工具循环中表现最佳，能自主纠错与重试
- **设置方式**：执行自动化任务前，在模型选择中切换为此模型

#### Doubao-Seed-Evolving（编程）

- **适用场景**：代码编写、代码审查、Bug 修复、技术方案设计
- **能力**：对多种编程语言有深度理解，代码生成质量高
- **特点**：持续迭代版本，始终使用最新能力
- **设置方式**：在设置页面将对话模型切换为此值

#### GLM-5.2（文学创作）

- **适用场景**：小说创作、散文、诗歌、剧本、创意文案
- **能力**：文学表达力强，语言优美，适合长篇创作
- **特点**：配合小说模式使用效果最佳，支持分段续写
- **设置方式**：在设置页面将对话模型切换为此值

#### DeepSeek API（翻译）

- **适用场景**：所有翻译需求
- **能力**：多语言互译，翻译质量高
- **特点**：翻译功能始终走 DeepSeek API 通道，独立计费，不消耗豆包配额
- **设置方式**：无需额外设置，点击消息气泡下方的 🌐 翻译按钮即可

### 豆包模式与 DeepSeek 模式

| 对比项 | 豆包模式 | DeepSeek 模式 |
| :--- | :--- | :--- |
| 联网搜索 | 不支持，界面会提示切换模式 | 支持，调用官方检索接口 |
| 翻译 | 翻译始终走 DeepSeek API | 翻译走 DeepSeek API |
| 推荐用途 | 对话、识图、识音、识影、生成类任务 | 需要联网搜索、实时数据时使用 |

> **重要**：需要联网搜索时，请关闭豆包模式，切换回 DeepSeek 模式后再使用搜索功能。

---

## 🌐 多语言支持

界面语种以日文为源语言，其余语种通过 `i18n/locales/*.js` 的「原文|译文」对照表覆盖：

| 代码 | 语言 | 文件 |
| :--- | :--- | :--- |
| `ja` | 日本語（源语言） | 内置 |
| `zh` | 简体中文 | `i18n/locales/zh.js` |
| `en` | English | `i18n/locales/en.js` |
| `ko` | 한국어 | `i18n/locales/ko.js` |
| `ru` | Русский | `i18n/locales/ru.js` |
| `fr` | Français | `i18n/locales/fr.js` |

**多语言特性：**

- 切换方式：URL 参数 `?lang=zh`、浏览器语言、或页面内的语言选择（记住到本地存储）
- 切换后页面自动重载，确保所有文案一致
- AI 回复的语言也会跟随界面语种自动切换（通过系统提示词注入）
- 每种语言模式下只显示该语言的界面文案，不会出现跨语言混显
- 数字会在匹配前统一归一化为 `#`，避免动态文案漏翻
- 新增语种只需按同样格式追加一个文件，无须改动逻辑代码

---

## 📦 环境要求

| 项目 | 要求 |
| :--- | :--- |
| 系统 | Android（Termux），其他 Linux 亦可运行 |
| 运行时 | **Dart SDK ≥ 3.0.0**（`pkg install dart`） |
| Python | Python 3（用于 `st.py` 一键脚本与 `auto.py` 自动化引擎） |
| 可选 | Termux:API 应用（启用通知、剪贴板、震动等系统级工具） |
| 可选 | ADB 无线调试（启用自动化操作引擎） |
| 磁盘 | 建议 ≥ 200MB（含编译产物） |
| 网络 | 可访问 `api.deepseek.com` 与 `ark.cn-beijing.volces.com` |

---

## 🚀 快速开始

### 方式一：一键脚本（推荐）

```bash
# 进入项目目录
cd ~/ddsh

# 前台运行（需要时自动 AOT 编译）
python3 st.py

# 后台守护运行（关闭 Termux 窗口也不退出，自动持锁防休眠）
python3 st.py --daemon

# 注册为 termux-services 服务（崩溃自动拉起 + 开机自启）
python3 st.py --install-service
```

**常用子命令：**

| 命令 | 作用 |
| :--- | :--- |
| `python3 st.py` | 编译（必要时）并前台运行 |
| `python3 st.py --daemon` | 编译后后台运行 + wake-lock |
| `python3 st.py --status` | 查看后台进程是否存活 |
| `python3 st.py --logs` | 实时查看运行日志 |
| `python3 st.py --restart` | 停止并重新后台启动 |
| `python3 st.py --stop` | 停止后台进程 |
| `python3 st.py --rebuild` | 强制重新编译 |
| `python3 st.py --skip-build` | 跳过编译直接运行 |
| `python3 st.py --no-aot` | 跳过 AOT，直接 `dart run`（省编译时间） |
| `python3 st.py --install-service` | 注册守护服务 |
| `python3 st.py --remove-service` | 卸载守护服务 |

### 方式二：手动编译

```bash
# 1) 静态检查
dart analyze

# 2) 直接运行（JIT，调试用）
dart run bin/main.dart

# 3) 编译原生可执行文件（AOT，推荐）
dart compile exe bin/main.dart -o app

# 4) 运行
./app
```

### 方式三：跳过编译直接 JIT 运行

```bash
# 不生成二进制，直接用 Dart VM 运行（适合开发调试）
dart run bin/main.dart
```

### 访问服务

```
http://127.0.0.1:9999/
```

> 端口被修改过？请以启动日志中的 `✅ サーバーが起動しました。http://localhost:XXXX/` 为准。

---

## 📘 使用教程

### 1. 首次配置 API Key

打开页面后，点击右上角 **⚙ 设定（设置）**：

**DeepSeek 配置：**
- DeepSeek API Key：从 [DeepSeek 开放平台](https://platform.deepseek.com/) 获取
- 模型：默认 `deepseek-chat`，可根据需要切换
- 图片 API Key：可选，用于视觉模型独立计费

**豆包（火山方舟）配置：**
- ARK API Key：从 [火山引擎控制台](https://console.volcengine.com/ark) 获取，与 DeepSeek Key 分开保存
- Base URL：默认 `https://ark.cn-beijing.volces.com/api/v3`
- 对话模型：推荐 `doubao-seed-2-0-lite-260428`（日常使用）
- 图片/视频/音频/播客/ASR 模型：按需配置

保存后，状态栏会显示 `✅ Key 已设置 · 対話モデル：xxx`。

> 🔐 Key 用 `POST /api/ds-chat/config` 写入本地，界面上只回显掩码（前 4 位 + 后 4 位）。

### 2. 聊天主界面

| 位置 | 操作 |
| :--- | :--- |
| 左上角标题 | 点按 → 打开会话列表，切换 / 新建 / 删除会话 |
| 输入框左侧 📎 | 附加图片、文档、视频、任意文件 |
| 输入框上方开关 | 深度思考、联网搜索、长文本、小说模式 |
| 推理等级按钮 | 点按打开滑杆，普通模式默认 15 级，高级模式默认 30 级 |
| 消息气泡下方 | 朗读 🔊、翻译 🌐、复制、重新生成 |
| 顶栏搜索图标 | 跨会话全文搜索 |

### 3. 深度思考 · 联网搜索 · 推理等级

- **深度思考**：开启后展示模型的思维链（reasoning），与最终答案分区渲染
- **联网搜索**：调用 DeepSeek 官方检索与抓取接口，结果自动拼入上下文；仅在 DeepSeek 模式下可用
- **推理等级**：等级越高，模型内部推理预算越大，响应更慢但更严谨
- **长文本模式**：把单次上下文上限抬到 150,000 字符，适合整本资料投喂
- **小说模式**：分段续写生成，配合 GLM-5.2 模型使用效果最佳

### 4. 附件与图片自动路由

你选中的模型如果是纯文本模型（例如 `deepseek-chat`），直接让它读图必然失败。系统会通过模型能力判定 → 自动路由改用视觉模型先提取图片内容，再拼进 prompt 交给主模型。

路由结果由三层决定：内置型号能力表 → 第三方型号模式匹配 → 用户自定义白/黑名单。

### 5. 豆包模块使用

配置好 ARK Key 后，底部工具栏会出现入口：

```text
🔊 音频生成   🎨 生图   🎬 视频   🎧 播客   📞 语音通话   🎤 录音识别   🖌 P图
```

**P 图（图像编辑）示例：**
1. 点击 🖌 豆包P图
2. 上传一张参考图
3. 填写编辑指令，例如「把背景换成海边黄昏，保留人物」
4. 默认使用 Seedream 5.0 pro，点击生成
5. 产物自动保存到 `data/ds_files/blob/`

**实时语音（Seeduplex）：**
浏览器无法给 WebSocket 附加自定义请求头，因此本项目用本地 Dart 服务做代理，由服务端注入 `X-Api-Key` 后转发到火山引擎。端到端语音必须使用豆包语音控制台的 Key，方舟的 Key 会返回 401。

#### 5.1 大视频理解（上限 2GB）

附件里挂一个视频，切到豆包模式并选择支持视频理解的模型（`doubao-seed-2.x` 系列均可），
豆包就能直接看视频内容回答问题。

**体积上限从 40MB 提升到 2GB**，实现方式分两条路（全程不把整段视频读进内存）：

| 视频体积 | 处理方式 | 说明 |
| :--- | :--- | :--- |
| ≤ 45MB | 直接以 `data:video/mp4;base64,...` 作为 `video_url` 随主请求发送 | 模型自己看整段视频作答，体验最好 |
| > 45MB（含 2GB） | `ffmpeg` 无损切片（`-c copy`，不重编码）成若干 ≤45MB 的段 → 逐段理解 → 汇总 | 每段得到带时间轴的客观描述，最后并入用户提示词由主模型综合回答 |

**依赖**：超过 45MB 的视频需要本机有 `ffmpeg`：

```bash
pkg install -y ffmpeg
```

**配置文件**：`data/deepseek_chat/doubao_video_ark.json`（首次使用时自动生成）

| 字段 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `maxBytes` | `2147483648` | 视频上限（2GB），超过直接报错，不做静默截断 |
| `fps` | `1.0` | 方舟抽帧密度（0.2~5），长视频调小可省 token |
| `segmentMaxBytes` | `47185920` | 单片上限（45MB），必须小于 50MB 的 base64 硬限制 |
| `useFilesApi` | `false` | 是否优先走 Files API（`file_id`）。见下方说明 |
| `tosBucket` / `tosPrefix` | 空 | 仅 Files API 通道使用，填了才启用 TOS 的 2GB 直传 |
| `autoCompact` | `true` | Files API 通道下 >512MB 时用 ffmpeg 压缩再上传 |
| `preprocessModel` | 空 | Files API 通道的 `preprocess_configs[video][model]` |

**关于 Files API**：方舟官方的大文件通道是 Files API + `file_id`（托管 512MB / TOS 2GB）。
本机实测该 Key 的 `file_id` 在 `/chat/completions` 与 `/responses` 中引用会返回
`404 The specified resource file is not found`，上传时带 `preprocess_configs[video][model]`
还会返回 `400 Project is invalid`（说明该 Key 未绑定 project / TOS 授权）。
因此默认走「本地切片 + base64」这条路——它在任何 Key 上都能用。
若你在控制台开通了 project 级 Key 与 TOS 授权，可把 `useFilesApi` 设为 `true`。

**进度提示**：上传/切片/逐段理解期间，前端思考面板会实时显示
`☁️ 方舟へアップロード中 42%`、`✂️ 分割完了`、`🎬 第 3/46 段` 等阶段，
不会出现「点了发送却像卡住」的表现。

**注意**：分段理解会发起多次模型调用，2GB 视频通常是几十段，耗时可能几十分钟；
若账号欠费，方舟会返回 `403 AccountOverdueError`，此时任何豆包请求都会失败，充值后恢复。

### 6. 智能体工具模式

当模型判断需要操作手机时，会进入工具循环：**规划 → 调用工具 → 读取结果 → 自我修正**，直到任务达成。

**推荐使用 Doubao-Seed-2.1-pro 模型执行自动化任务。**

典型用法：

```text
「帮我打开微信，搜索联系人张三并发送消息」
「把当前屏幕截图保存到 Downloads 目录」
「每天 9 点给我发一条提醒通知」
「读取剪贴板内容并整理成表格」
「帮我打开哔哩哔哩」
```

### 7. 角色扮演（Cosplay）

点击 🎭 进入角色面板，可创建多个角色，字段与 Tavern v2 对齐：

| 字段 | 含义 |
| :--- | :--- |
| `name` / `emoji` | 角色名与图标 |
| `personality` | 性格内核 |
| `style` | 说话风格 |
| `rules` | 行为准则（该做 / 不该做） |
| `scenario` | 世界观与关系设定 |
| `first_mes` | 开场白 |

角色数据保存在 `data/cosplay/cos_<时间戳>_<随机>.sts`，开关状态在 `cosplay_state.sts`。

### 8. 数据备份与恢复

| 操作 | 位置 | 行为 |
| :--- | :--- | :--- |
| 📦 数据备份 | 设置 → 数据备份 | 打包 `data/` 与 `imgs/` 为 `.tar.gz` 下载 |
| ♻️ 从备份恢复 | 设置 → 数据恢复 | 上传 `.tar.gz`，覆盖现有全部数据 |

> ⚠️ 恢复操作不可撤销。请务必先执行一次备份。

---

## 🤖 自动化操作引擎

本项目包含两个自动化操作核心脚本，位于 `ddsh/` 目录下：

### adb_up.sh — ADB 连接建立

```bash
bash ddsh/adb_up.sh
```

- 通过本机无线调试端口 `127.0.0.1:5555` 建立 `uid=2000(shell)` 连接
- 等同于 Shizuku 权限，无需 root
- 前置条件：**设置 → 开发者选项 → 无线调试** 已开启
- 自动启动脱离终端的 adb server，避免随 shell 退出而亡

### auto.py — 安卓全自动操作引擎

```bash
python3 ddsh/auto.py <命令> [参数]
```

**能力清单：**

| 类别 | 命令 | 说明 |
| :--- | :--- | :--- |
| 点击 | `tap <x> <y>` | 点击指定坐标 |
| 点击 | `tap-text <文本>` | 点击包含指定文字的控件 |
| 点击 | `tap-id <resource-id>` | 点击指定 resource-id 的控件 |
| 长按 | `long <x> <y> [--ms N]` | 长按指定坐标 |
| 滑动 | `swipe <x1> <y1> <x2> <y2> [--ms N]` | 滑动 |
| 按键 | `key <keycode>` | 发送按键事件 |
| 屏幕 | `on` / `off` | 点亮/熄灭屏幕 |
| 解锁 | `unlock [--pin XXXX]` | 点亮屏幕并滑动解锁 |
| 文本 | `type <文本>` | 输入任意文本（中文/emoji 全支持） |
| 文本 | `type-into <文本>` | 找输入框并输入 |
| 剪贴板 | `copy` / `cut` / `paste` / `clip-get` | 剪贴板操作 |
| 编辑 | `select-all` / `clear` / `edit-text` | 全选/清空/读取输入框 |
| 应用 | `start <包名> [--activity X]` | 启动应用 |
| 应用 | `stop <包名>` | 强制停止应用 |
| 应用 | `uninstall <包名>` | 卸载应用 |
| 应用 | `installed <包名>` | 检查是否已安装 |
| 应用 | `current` | 获取当前前台应用 |
| 截图 | `shot [--path X] [--ocr]` | 截图，可选 OCR 识别 |
| 弹窗 | `kill-popup [--rounds N] [--allow]` | 自动清理弹窗广告 |
| 等待 | `wait <文本> [--timeout N]` | 等待文字出现 |
| 等待 | `wait-gone <文本> [--timeout N]` | 等待文字消失 |
| 稳定 | `stable` | 等待界面稳定 |
| 通知 | `notify <标题> <内容>` | 发送系统通知 |
| 状态 | `status` | 查看设备连接状态 |

**特性：**
- 掉线自动重连、失败自动重试、超时保护
- 中文/emoji 输入全支持（通过 AdbKeyboard 输入法）
- 弹窗广告自动识别与清理
- UI XML 解析，支持按文字/resource-id/class 查找控件

### 在工具模式中使用

工具模式下，AI 会自动调用 `adb_up.sh` 获取 adb shell 权限，然后通过 `auto.py` 执行具体操作。用户只需用自然语言描述任务即可。

---

## ⚙️ 配置项说明

服务启动时会依次尝试读取 `$BASE_DIR/.env` 及 `./.env`。

| 变量 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `DSH_BASE` | `/data/data/com.termux/files/home/ddsh` | 项目根目录，数据存放位置 |
| `DSH_PORT` | `9999` | HTTP 服务端口 |
| `DS_MASTER_KEY` | 自动生成 | AES-256-GCM 主密钥（64 位十六进制），用于加密聊天记录 |
| `DS_WORKSPACE` | `$HOME` | 工具的默认工作目录 |
| `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` / `PROXY` / `SOCKS5_PROXY` | 空 | 出站代理 |
| `DSH_DEBUG` | 空 | 设为 `1` 时打印异常堆栈 |

示例：

```bash
cat > ~/ddsh/.env <<'EOF'
DSH_PORT=9999
DSH_BASE=/data/data/com.termux/files/home/ddsh
DSH_DEBUG=0
EOF
```

---

## 🗂 目录结构

```text
ddsh/
├── bin/main.dart              # 入口：目录初始化 → 路由注册 → 启动 HTTP 服务
├── lib/src/                   # 后端全部实现（纯 Dart，无第三方包）
│   ├── globals.dart           #   全局常量 / 环境变量 / 日志 / 文本转义
│   ├── httpsrv.dart           #   HTTP 工具、CORS、静态资源、JSON 响应、SSE
│   ├── deepseek_api.dart      #   DeepSeek 调用层（流式 / 工具循环 / 搜索 / 视觉）
│   ├── chat_send.dart         #   发送、SSE 流式、小说模式
│   ├── chat_handlers.dart     #   会话、配置、消息、推理、翻译、TTS/STT
│   ├── sessions.dart          #   会话存取（.sts 明文格式）
│   ├── tools.dart             #   90+ 工具的 Schema 与执行器
│   ├── model_router.dart      #   模型能力判定与自动路由
│   ├── doubao.dart            #   火山方舟：生图 / P图 / 视频 / TTS / 播客 / ASR
│   ├── doubao_video_ark.dart  #   大视频（≤2GB）理解：切片 / 分段 / Files API
│   ├── doubao_realtime.dart   #   Seeduplex 全双工 + RTC 编排
│   ├── cosplay.dart           #   角色扮演
│   ├── files.dart             #   分片上传 / 下载 / 元数据
│   ├── backup.dart            #   tar.gz 打包与解包（手写 ustar 实现）
│   ├── ds_crypto.dart         #   主密钥 + AES-256-GCM 加解密 + 配置读写
│   ├── aes_gcm.dart           #   纯 Dart AES-256-GCM（NIST SP 800-38D）
│   ├── sha256.dart            #   纯 Dart SHA-256 / HMAC-SHA256
│   ├── tts_edge.dart          #   Edge TTS 流式合成（WebSocket）
│   ├── tts_drm.dart           #   Sec-MS-GEC v2 签名
│   ├── peakvalley.dart        #   峰谷提醒（时区 + 7 通道推送 + 定时调度）
│   ├── vocab.dart             #   日语单词本（首字分片 + 256 图片桶）
│   ├── forum.dart             #   论坛帖子
│   ├── announcements.dart     #   公告系统
│   ├── search.dart            #   全文搜索
│   ├── xtweet.dart            #   X（Twitter）推文抓取
│   ├── devtools.dart          #   开发者工具（Prompt 注入）
│   ├── displaymodels.dart     #   自定义模型存储
│   ├── session_ref.dart       #   跨会话引用（mention）
│   ├── ds_usage.dart          #   Token 用量统计
│   ├── net.dart               #   共享 HttpClient（连接池 / 代理探测）
│   └── ...
├── index.html                 # 主页面
├── deepseek-chat.js / .css    # 聊天前端核心
├── dsc-doubao.js / .css       # 豆包模块前端
├── dsc-model-route.js         # 模型路由前端
├── dsc-forum.js / .css        # 论坛前端
├── dsc-vocab.js / .css        # 单词本前端
├── dsc-announcements.js       # 公告前端
├── dsc-duplex.js              # 实时语音前端
├── dsc-ja-fix.js              # 多语言日语残留修正
├── dsc-menu-scroll.js         # 菜单滚动
├── dsc-newline-fx.js          # 换行效果
├── dsc-swipe.js               # 滑动手势
├── ds-devtools.js / .css      # 开发者工具前端
├── ds-files.js / .css         # 文件管理前端
├── peakvalley.js / .css       # 峰谷提醒前端
├── tex-chtml-full-speech.js   # MathJax 数学公式渲染
├── i18n/                      # 多语言系统
│   ├── i18n.js                #   i18n 核心（MutationObserver 自动翻译）
│   ├── ai-prompts.js          #   AI 应答语言强制提示词（6 语言）
│   └── locales/               #   语言包
│       ├── ja.js / ja-extra.js    # 日语（源语言）
│       ├── zh.js / zh-extra.js    # 简体中文
│       ├── en.js / en-extra.js    # 英语
│       ├── ko.js / ko-extra.js    # 韩语
│       ├── ru.js / ru-extra.js    # 俄语
│       └── fr.js / fr-extra.js    # 法语
├── st.py                      # 一键脚本：编译 / 前台 / 后台 / 守护服务
├── adb_up.sh                  # ADB 连接建立脚本
├── auto.py                    # 安卓全自动操作引擎
├── ha.py                      # 聊天记录优化外挂（思考链代码折叠）
├── pubspec.yaml               # Dart 项目配置（dependencies 为空）
├── .gitignore                 # Git 忽略规则
├── favicon.png                # 网站图标
├── sw.png                     # Service Worker 图标
├── app                        # AOT 编译产物（已被 .gitignore 排除）
└── data/                      # 运行数据（已被 .gitignore 排除）
    ├── deepseek_chat/         #   会话与消息
    ├── ds_files/              #   上传文件与生成产物
    ├── cosplay/               #   角色扮演数据
    ├── vocab/                 #   单词本数据
    ├── dispost/               #   论坛帖子
    ├── announcements/         #   公告
    ├── displaymodels/         #   自定义模型
    └── peakvalley/            #   峰谷提醒配置
```

---

## 🏗 技术架构

```text
┌───────────────────────────────────────────────────────┐
│  浏览器 UI（原生 HTML / CSS / JS，无框架）              │
│  ├── deepseek-chat.js    聊天核心                       │
│  ├── dsc-doubao.js       豆包模块                       │
│  ├── i18n/i18n.js        多语言自动翻译                 │
│  └── dsc-*.js            各功能模块                     │
└───────────────────────┬───────────────────────────────┘
                        │ HTTP + SSE / WebSocket
┌───────────────────────▼───────────────────────────────┐
│  Dart HTTP 服务（dart:io HttpServer，默认 :9999）      │
│                                                        │
│   精确路由表  _routes[path]                            │
│   前缀路由    _prefixRoutes（/api/peakvalley/）        │
│   中间件      loggerMiddleware → corsMiddleware        │
│   静态资源    命中失败时回退 index.html                │
│                                                        │
│   API 路由：                                           │
│   /api/ds-chat/*     DeepSeek 聊天 / 翻译 / TTS        │
│   /api/doubao/*      豆包生图 / 视频 / 语音 / ASR      │
│   /api/ds-files/*    文件管理                          │
│   /api/ds-cosplay    角色扮演                          │
│   /api/forum/*       论坛                              │
│   /api/vocab/*       单词本                            │
│   /api/peakvalley/*  峰谷提醒                          │
│   /api/backup        备份 / 恢复                       │
└───────────────────────┬───────────────────────────────┘
                        │
        ┌───────────────┼───────────────┐
        ▼               ▼               ▼
   DeepSeek API    火山方舟 API    手机本体
   chat/completions images/video    shell / am / input
   tools/search     duplex(wss)     Termux API
   tools/fetch      rtc             auto.py / adb_up.sh
```

**关键实现细节：**

- **零依赖**：`pubspec.yaml` 的 `dependencies` 为空，AES-256-GCM、SHA-256、tar/ustar 打包全部手写
- **强制关闭 gzip**：`server.autoCompress = false`，避免 SSE 字节被编码器缓冲导致「一直思考、不出回答」
- **单请求异常隔离**：每个请求独立 `try/catch`，配合 `runZonedGuarded`，任何未捕获异常只记日志、绝不退出进程
- **端口占用重试**：启动时最多重试 10 次（间隔 300ms），避免旧实例未释放就启动失败
- **原子编译替换**：AOT 编译先写入临时文件再 `os.replace`，避免运行中的旧进程导致 `ETXTBSY`
- **SSE 心跳**：`server.idleTimeout` 设为 120 秒
- **加密存储**：API Key 用 AES-256-GCM 加密后存储，主密钥自动生成并独立保存

---

## ❓ 常见问题

<details>
<summary><b>启动后浏览器打不开页面？</b></summary>

1. 看启动日志里的端口号是否为预期值（`DSH_PORT` 可覆盖）
2. `curl -I http://127.0.0.1:9999/` 检查是否有响应
3. 若进程存在但端口无监听，通常是残留实例占位，执行 `python3 st.py --restart`
</details>

<details>
<summary><b>豆包接口返回 404 InvalidEndpointOrModel.NotFound？</b></summary>

这是模型名与端点不匹配。例如把播客模型发给 `/chat/completions` 就会 404。本项目已在代码层做了收敛：台本生成只接受 `chat` 类模型，语音合成只接受 `tts` 类模型，非法模型名会自动回退到默认值。
</details>

<details>
<summary><b>端到端语音一直 401？</b></summary>

Seeduplex 需要豆包语音控制台的 API Key，用方舟（ARK）的 Key 一定 401。请在设置中单独填写「豆包音声 API Key（Seeduplex 用）」。
</details>

<details>
<summary><b>朗读没有声音？</b></summary>

Edge TTS 依赖微软的签名机制（Sec-MS-GEC v2），且对 User-Agent 敏感。本项目已用自定义 WebSocket 客户端规避。若仍失败，请检查网络出口是否能访问 `speech.platform.bing.com`。
</details>

<details>
<summary><b>后台运行一段时间就断了？</b></summary>

安卓省电策略会回收后台进程。建议：
1. 用 `python3 st.py --daemon` 启动（自动持 wake-lock）
2. 用 `python3 st.py --install-service` 注册守护服务（崩溃自动拉起 + 开机自启）
3. 在系统设置中把 Termux 加入电池优化白名单
</details>

<details>
<summary><b>自动化操作失败？</b></summary>

1. 确认无线调试已开启：设置 → 开发者选项 → 无线调试
2. 运行 `bash ddsh/adb_up.sh` 检查连接状态
3. 运行 `python3 ddsh/auto.py status` 检查设备在线状态
4. 自动化任务推荐使用 Doubao-Seed-2.1-pro 模型
</details>

<details>
<summary><b>我想改端口 / 迁移目录？</b></summary>

改 `.env` 里的 `DSH_PORT` 与 `DSH_BASE`，然后重启服务。注意 `DSH_BASE` 同时也是数据的存放位置，迁移前请先做一次备份。
</details>

<details>
<summary><b>前端改动不生效？</b></summary>

`.js` / `.css` / `.html` 是静态文件，刷新页面即生效；`lib/src/*.dart` 属于后端，必须重新 `dart compile exe` 或 `dart run` 才会生效。
</details>

---

## 📄 版权声明与二次分发

### 版权归属

本项目 **Dart · DeepSeek Harness（ddsh）** 的版权归项目开发者所有。

### 二次分发声明

1. **禁止未经授权的商业分发**：在权利人明确授权前，任何个人或组织不得将本项目用于商业目的的分发、销售或捆绑销售。

2. **个人使用许可**：本项目允许个人用户在非商业目的下自由使用、修改和运行。

3. **修改与衍生**：
   - 允许基于学习目的对本项目进行修改
   - 衍生项目必须保留原始版权声明
   - 衍生项目不得以原项目名称进行公开分发

4. **API Key 与凭证**：
   - 本项目不包含任何 API Key 或访问凭证
   - 用户自行注册并管理的 API Key 的使用权归用户所有
   - API Key 的使用需遵守对应平台（DeepSeek、火山引擎等）的服务条款

5. **第三方服务依赖**：
   - 本项目调用 DeepSeek API、火山方舟 API、Microsoft Edge TTS 等第三方服务
   - 这些服务的使用权受对应平台的服务条款约束
   - 本项目不对第三方服务的可用性、价格或政策变更负责

6. **开源组件**：
   - 本项目后端为 100% 纯 Dart 实现，不依赖任何第三方 Dart 包
   - 前端为原生 HTML/CSS/JavaScript，不依赖任何前端框架或 CDN
   - 自动化引擎（`auto.py`）为独立 Python 脚本，仅依赖 Python 标准库

7. **未包含 LICENSE 文件**：本仓库目前未包含正式的 LICENSE 文件。在权利人明确授权前，请勿用于商业分发。

---

## ⚠️ 免责声明

> **以下每一条都来自实际踩过的坑，请务必阅读。**

**1. API Key 为本地存储**
- 豆包 ARK Key 以明文写入 `.sts` 文件
- 聊天记录的加密依赖 `DS_MASTER_KEY`，该密钥一旦丢失，历史会话将无法解密
- `.env`、`*.key`、`data/` 均已在 `.gitignore` 中排除，请勿强行提交到公开仓库

**2. 恢复备份会覆盖全部数据**
「从备份恢复」会用上传的 `.tar.gz` 覆盖当前 `data/` 与 `imgs/` 全部内容，不可撤销。操作前请先备份。

**3. 工具模式会真实操作你的手机**
`execute_command`、`tap`、`uninstall_app`、`settings_put`、`kill_process` 等工具是真实执行的，没有沙箱。请：
- 不要在无人看管时让它执行删除、卸载、转账类指令
- 涉及支付、删除、卸载的操作，务必人工确认

**4. 界面自动旋转相关设置请勿改动**
本项目运行期间不修改系统屏幕方向配置，避免自动化点击坐标错位。

**5. 关于 adb 权限**
`adb_up.sh` 通过本机无线调试端口 `127.0.0.1:5555` 建立 `uid=2000(shell)` 连接，`auto.py` 在此权限下工作。前置条件：设置 → 开发者选项 → 无线调试已开启。项目内部已移除对 Shizuku 的依赖。

**6. RTC 功能需要额外 SDK**
服务端可以正常创建 `StartVoiceChat` 任务，但浏览器端要真正收发音视频，需要自行引入官方 RTC Web SDK 并加入同一房间（本仓库未内置）。

---

<div align="center">

**🐋 Dart · DeepSeek Harness v2.1.0**

从 14,080 行 Go 到 100% 纯 Dart · 零依赖 · 一个浏览器窗口控制整台手机

```bash
dart compile exe bin/main.dart -o app
```

</div>
