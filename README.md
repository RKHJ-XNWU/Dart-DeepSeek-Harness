<div align="center">

# 🐋 Dart · DeepSeek Harness

**把整台安卓手机变成你的 AI 工作站**

100% 纯 Dart 重写 · 零第三方依赖 · 单文件可执行 · 原生 Web UI

[![Dart](https://img.shields.io/badge/Dart-3.0%2B-0175C2?logo=dart&logoColor=white)](https://dart.dev)
[![Dependencies](https://img.shields.io/badge/dependencies-0-brightgreen)](#-技术架构)
[![Platform](https://img.shields.io/badge/platform-Android%20%2F%20Termux-3DDC84?logo=android&logoColor=white)](#-环境要求)
[![Version](https://img.shields.io/badge/version-2.1.0-blue)](#)
[![i18n](https://img.shields.io/badge/i18n-6%20languages-orange)](#-多语言支持)
[![License](https://img.shields.io/badge/license-未声明-lightgrey)](#-注意事项)

</div>

---

## 📖 目录

- [这是什么](#-这是什么)
- [豆包模式不支持联网搜索](#豆包模式不支持联网搜索)
- [功能总览](#-功能总览)
- [多语言支持](#-多语言支持)
- [环境要求](#-环境要求)
- [快速开始](#-快速开始)
- [使用教程](#-使用教程)
  - [1. 首次配置 API Key](#1-首次配置-api-key)
  - [2. DeepSeek 聊天主界面](#2-deepseek-聊天主界面)
  - [3. 深度思考 · 联网搜索 · 推理等级](#3-深度思考--联网搜索--推理等级)
  - [4. 附件与图片自动路由](#4-附件与图片自动路由)
  - [5. 豆包（火山方舟）模块](#5-豆包火山方舟模块)
  - [6. 智能体工具模式](#6-智能体工具模式)
  - [7. 角色扮演（Cosplay）](#7-角色扮演cosplay)
  - [8. 数据备份与恢复](#8-数据备份与恢复)
- [配置项说明](#-配置项说明)
- [目录结构](#-目录结构)
- [技术架构](#-技术架构)
- [常见问题](#-常见问题)
- [注意事项](#-注意事项)

---

## 豆包模式不支持联网搜索

> [!IMPORTANT]
> **本网站在豆包模式下不提供联网搜索，也没有必要额外支持豆包搜索。**
> 需要联网搜索时，请**关闭豆包模式**，切换回 **DeepSeek 模式**后再使用搜索。

原因很直接：本项目已有的联网搜索是 DeepSeek 官方的 `tools/search` 与 `tools/fetch`，链路稳定、结果结构化；再给豆包单独接一套搜索插件既无必要，也会带来额外的开通成本与维护负担。因此在豆包模式下，即使打开了「联网搜索」开关，请求也**不会调用任何 DeepSeek 搜索接口**（DeepSeek 用量为 0），界面会直接返回一段说明，提示你切换模式。

| 对比项 | 豆包模式 | DeepSeek 模式 |
| :--- | :--- | :--- |
| 联网搜索开关 | 只显示提示，不执行搜索 | 正常检索并自动拼入上下文 |
| DeepSeek 搜索用量 | **0** | 按实际调用计费 |
| 推荐用途 | 报告写作、识图、音频 / 视频理解、生成类任务 | 需要最新资讯、实时数据时使用 |

---

## 🌟 这是什么

**Dart · DeepSeek Harness** 是一个运行在 Android 手机（Termux 环境）上的本地 AI 网关 + 网页客户端。

它在本机启动一个 HTTP 服务（默认端口 `9999`），你在浏览器打开 `http://127.0.0.1:9999/` 就能得到一套完整的 AI 工作站界面：

- 前端：原生 HTML / CSS / JavaScript，**无框架、无构建步骤、无 CDN 依赖**
- 后端：由 Go 版 14,080 行代码 **100% 重写为纯 Dart**，`pubspec.yaml` 中 `dependencies: {}` 为空，HTTP 服务、AES-256-GCM 加密、tar.gz 打包全部手写实现
- 一键 `dart compile exe` 生成单文件二进制，不依赖任何运行时库

| 维度 | 说明 |
| :--- | :--- |
| 🎯 定位 | 手机上的一体化 AI 控制台 |
| 🧩 模型 | DeepSeek 官方 API + 火山方舟豆包全家桶（17 个模型） |
| 🖥 形态 | 本地 Web 服务 + 浏览器 UI（无 App 安装） |
| 🤖 能力 | 除了聊天，还能调用 **90+ 工具** 真实操作手机 |
| 🌐 语言 | 日本語 / 简体中文 / English / 한국어 / Русский / Français |

---

## ✨ 功能总览

### 🧠 DeepSeek 核心对话

| 功能 | 说明 |
| :--- | :--- |
| 💬 多会话管理 | 会话列表、单条/批量删除、全部清除、会话内引用（`session-mention`） |
| ⚡ SSE 流式输出 | 逐字流式渲染，思考链（reasoning）与实际回答分离显示 |
| 🔍 全文搜索 | 跨会话内容搜索，游标分页，命中片段高亮（摘要上限 300 字） |
| 🧾 长文本模式 | 单次上下文默认放宽至 **150,000 字符** |
| 📝 小说模式 | 分段续写生成，避免单次输出截断 |
| 🌐 联网搜索 | 调用 DeepSeek 官方 `tools/search` 与 `tools/fetch` 接口（**仅 DeepSeek 模式**，豆包模式不提供） |
| 💰 用量计费 | 每次对话/翻译按官方单价折算实际费用 |
| 🔊 朗读（TTS） | Edge TTS 流式合成，按文本语种自动切换音色（日→Nanami、中→Xiaoxiao 等） |
| 🎤 语音输入（STT） | 录音转文字后直接入框 |
| 🌏 一键翻译 | 对任意回复生成译文，可复制、可朗读，并单独计费 |

### 🎨 豆包（火山方舟）全家桶

> 与 DeepSeek Key **分开保存**，互不覆盖；模型可单独指定，也可交由自动路由。

| 模块 | 能力 | 可选模型 |
| :--- | :--- | :--- |
| 🖼 文生图 | 提示词生成图片，自动落盘 | Seedream 4.5 / 5.0 Lite / 5.0 pro |
| 🖌 P 图 | 携带参考图做图像编辑（默认 `Seedream 5.0 pro`） | SeedEdit 3.0、Seedream 5.0 pro |
| 🎬 视频生成 | 异步任务创建 + 状态轮询 + 任务历史列表 | Seedance 2.0 / 2.0 fast |
| 🔊 音频生成 | 文本转语音，产物存入 `ds_files/blob` | SeedAudio 1.0 |
| 🎧 播客 | 台本生成 → 语音合成，输出完整音频 | 播客模型 + TTS 模型组合 |
| 🎤 录音识别 | 上传录音文件做 ASR 转写 | Seed ASR 2.0 / Streaming 2.0 |
| 📞 语音通话 | 多轮语音会话（voice/turn） | 实时语音模型 |
| 📊 音频分析 | 对音频内容做理解与摘要 | 多模态模型 |
| 🔄 实时语音 | **Seeduplex 全双工**，WebSocket 由本地服务代理并注入鉴权头 | 端到端实时语音模型 |
| 📹 RTC 互动 | 服务端编排 `StartVoiceChat` / `StopVoiceChat` 任务 | RTC 音视频智能体 |

### 📱 手机实操能力（工具模式）

内置 **90+ 工具的 JSON Schema 与执行器**，模型可自主规划并调用：

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

单次任务支持最多 **50,000 轮**工具调用循环，真正把「说一句话，手机自己动」变成现实。

### 🗂 附加模块

<table>
<tr><td width="50%" valign="top">

**📁 文件管理**
分片上传（断点续传）、下载、按分类检索、按月归档元数据，单文件上限 5GB。

**📚 日语单词本**
单词按首字分片存储，图片按哈希分入 256 个桶，删词自动清理空桶。

**💬 论坛 · 帖子广场**
发帖、置顶、精选、屏蔽、批量删除；标题 ≤ 5000 字，正文 ≤ 500 万字。

**📢 公告系统**
定时生效、强制置顶、优先级排序，最多同时 5 条。

</td><td width="50%" valign="top">

**⏰ 峰谷提醒**
DeepSeek 官方峰谷定价时段判定，内置 11 个时区与夏令时规则，支持 7 种推送渠道：
Server酱 · Bark · DingTalk · WeCom · Telegram · Feishu · 自定义 Webhook。

**🎭 角色扮演**
兼容 Tavern v2 字段（personality / style / rules / scenario / first_mes …），可随时开关。

**🐦 X（Twitter）**
发布推文、拉取时间线。

**🛠 开发者工具**
Prompt 模板的集中管理与批量删除。

</td></tr>
</table>

---

## 🌐 多语言支持

界面语种以**日文为源语言**，其余语种通过 `i18n/locales/*.js` 的「原文|译文」对照表覆盖：

| 代码 | 语言 | 文件 |
| :--- | :--- | :--- |
| `ja` | 日本語（源语言） | 内置 |
| `zh` | 简体中文 | `i18n/locales/zh.js` |
| `en` | English | `i18n/locales/en.js` |
| `ko` | 한국어 | `i18n/locales/ko.js` |
| `ru` | Русский | `i18n/locales/ru.js` |
| `fr` | Français | `i18n/locales/fr.js` |

- 切换方式：URL 参数 `?lang=zh`、浏览器语言、或页面内的语言选择（记住到本地存储）
- 数字会在匹配前统一归一化为 `#`，避免「剩余 5 条」这类动态文案漏翻
- 新增语种只需按同样格式追加一个文件，无须改动逻辑代码
- 语言功能可能不兼容及出现其他语音残留，因为有些语言是硬编码的，无法被变量给影响，敬请谅解
- AI 回复的语言也会跟随界面语种自动切换

---

## 📦 环境要求

| 项目 | 要求 |
| :--- | :--- |
| 系统 | Android（Termux），其他 Linux 亦可运行 |
| 运行时 | **Dart SDK ≥ 3.0.0**（`pkg install dart`） |
| 可选 | Python 3（仅用于 `st.py` 一键脚本） |
| 可选 | Termux:API 应用（启用通知、剪贴板、震动等系统级工具） |
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

常用子命令：

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

### 访问服务

```
http://127.0.0.1:9999/
```

> 端口被修改过？请以启动日志中的 `✅ サーバーが起動しました。http://localhost:XXXX/` 为准。

---

## 📘 使用教程

### 1. 首次配置 API Key

打开页面后，点击右上角 **⚙ 設定（设置）**：

```text
┌─ 連接情報 ─────────────────────────────┐
│  DeepSeek API Key   [ sk-•••••••• ]    │
│  モデル              [ deepseek-chat ]  │
│  画像 API Key       [ 可选，独立计费 ]   │
└────────────────────────────────────────┘

┌─ 豆包（火山方舟）──────────────────────┐
│  ARK API Key        [ 与 DeepSeek 分开保存 ] │
│  ベース URL          [ https://ark.cn-beijing.volces.com/api/v3 ] │
│  対話 / 画像 / 動画 / 音声 / 播客 / ASR モデル │
└────────────────────────────────────────┘
```

保存后，状态栏会显示 `✅ Key 已设置 · 対話モデル：xxx`。

> 🔐 Key 用 `POST /api/ds-chat/config` 写入本地，界面上只回显掩码（前 4 位 + 后 4 位）。

### 2. DeepSeek 聊天主界面

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
- **联网搜索**：调用官方检索与抓取接口，结果自动拼入上下文；**该功能仅在 DeepSeek 模式下可用，豆包模式不支持也不会调用**，需要搜索请关闭豆包模式（详见 [豆包模式不支持联网搜索](#豆包模式不支持联网搜索)）
- **推理等级**：等级越高，模型内部推理预算越大，响应更慢但更严谨
- **长文本模式**：把单次上下文上限抬到 150,000 字符，适合整本资料投喂

### 4. 附件与图片自动路由

这是本项目一个容易被忽视但很关键的机制：

> 你选中的模型如果是纯文本模型（例如 `deepseek-chat`），直接让它读图必然失败。
> 系统会通过 **模型能力判定 → 自动路由** 改用视觉模型先提取图片内容，再拼进 prompt 交给主模型。

路由结果由三层决定：内置型号能力表 → 第三方型号模式匹配 → 用户自定义白/黑名单。

### 5. 豆包（火山方舟）模块

> [!NOTE]
> 豆包模式**不提供联网搜索**。需要联网搜索请关闭豆包模式、改用 DeepSeek 模式，详见 [豆包模式不支持联网搜索](#豆包模式不支持联网搜索)。

配置好 ARK Key 后，底部工具栏会出现 7 个入口：

```text
🔊 音频生成   🎨 生图   🎬 视频   🎧 播客   📞 语音通话   🎤 录音识别   🖌 P图
```

**P 图（图像编辑）示例：**

1. 点击 **🖌 豆包P图**
2. 上传一张参考图
3. 填写编辑指令，例如「把背景换成海边黄昏，保留人物」
4. 默认使用 `Seedream 5.0 pro`，点击生成
5. 产物自动保存到 `data/ds_files/blob/`

**实时语音（Seeduplex）：**

浏览器无法给 WebSocket 附加自定义请求头，因此本项目用本地 Dart 服务做代理，由服务端注入 `X-Api-Key` 后转发到火山引擎。请注意：**端到端语音必须使用豆包语音控制台的 Key，方舟的 Key 会返回 401。**

### 6. 智能体工具模式

当模型判断需要操作手机时，会进入工具循环：**规划 → 调用工具 → 读取结果 → 自我修正**，直到任务达成。

典型用法：

```text
「帮我打开微信，搜索联系人张三并发送消息」
「把当前屏幕截图保存到 Downloads 目录」
「每天 9 点给我发一条提醒通知」
「读取剪贴板内容并整理成表格」
```

安全提醒见 [注意事项](#-注意事项) 第 6 条。

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
| ♻️ 从备份恢复 | 设置 → 数据恢复 | 上传 `.tar.gz`，**覆盖现有全部数据** |

> ⚠️ 恢复操作不可撤销。请务必先执行一次备份。

---

## ⚙️ 配置项说明

服务启动时会依次尝试读取 `$BASE_DIR/.env` 与 `./.env`。

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
├── bin/main.dart            # 入口：目录初始化 → 路由注册 → 启动 HTTP 服务
├── lib/src/                 # 后端全部实现（纯 Dart，无第三方包）
│   ├── globals.dart         #   全局常量 / 环境变量 / 日志
│   ├── httpsrv.dart         #   HTTP 工具、CORS、静态资源、JSON 响应
│   ├── deepseek_api.dart    #   DeepSeek 调用层（流式 / 工具循环 / 搜索 / 视觉）
│   ├── chat_send.dart       #   发送、SSE 流式、小说模式
│   ├── chat_handlers.dart   #   会话、配置、消息、推理、翻译、TTS/STT
│   ├── sessions.dart        #   会话存取（.sts 明文格式）
│   ├── tools.dart           #   90+ 工具的 Schema 与执行器
│   ├── model_router.dart    #   模型能力判定与自动路由
│   ├── doubao.dart          #   火山方舟：生图 / P图 / 视频 / TTS / 播客 / ASR
│   ├── doubao_realtime.dart #   Seeduplex 全双工 + RTC 编排
│   ├── cosplay.dart         #   角色扮演
│   ├── files.dart           #   分片上传 / 下载 / 元数据
│   ├── backup.dart          #   tar.gz 打包与解包（手写 ustar 实现）
│   ├── ds_crypto.dart       #   AES-256-GCM + SHA-256
│   ├── tts_edge.dart        #   Edge TTS 流式合成
│   ├── tts_drm.dart         #   Sec-MS-GEC v2 签名
│   ├── peakvalley.dart      #   峰谷提醒（时区 + 7 通道推送 + 定时调度）
│   ├── vocab.dart           #   日语单词本
│   ├── forum.dart           #   论坛
│   ├── announcements.dart   #   公告
│   ├── search.dart          #   全文搜索
│   ├── xtweet.dart          #   X（Twitter）
│   └── ...                  #   devtools / net / displaymodels / session_ref
├── index.html               # 主页面
├── deepseek-chat.js/.css    # 聊天前端核心
├── dsc-doubao.js/.css       # 豆包模块前端
├── dsc-cosplay / vocab / forum / devtools / ...   # 各功能模块前端
├── i18n/                    # 多语言（locales: ja zh en ko ru fr）
├── data/                    # 运行数据（已被 .gitignore 排除）
│   ├── deepseek_chat/       #   会话与消息
│   ├── ds_files/            #   上传文件与生成产物
│   ├── cosplay/  vocab/  forum/  dispost/  announcements/
├── st.py                    # 一键：编译 / 前台 / 后台 / 守护服务
├── adb_up.sh                # 建立本机 adb 连接（127.0.0.1:5555）
├── auto.py                  # 安卓全自动操作引擎（adb shell 权限）
└── app                      # AOT 编译产物（已被 .gitignore 排除）
```

---

## 🏗 技术架构

```text
┌───────────────────────────────────────────────────────┐
│  浏览器 UI（原生 HTML / CSS / JS，无框架）              │
└───────────────────────┬───────────────────────────────┘
                        │ HTTP + SSE / WebSocket
┌───────────────────────▼───────────────────────────────┐
│  Dart HTTP 服务（dart:io HttpServer，默认 :9999）      │
│                                                        │
│   精确路由表  _routes[path]                            │
│   前缀路由    _prefixRoutes（/api/peakvalley/）        │
│   中间件      loggerMiddleware → corsMiddleware        │
│   静态资源    命中失败时回退 index.html                │
└───────────────────────┬───────────────────────────────┘
                        │
        ┌───────────────┼───────────────┐
        ▼               ▼               ▼
   DeepSeek API    火山方舟 API    手机本体
   chat/completions images/video    shell / am / input
   tools/search     duplex(wss)     Termux API
```

**几个值得一说的实现细节：**

- **零依赖**：`pubspec.yaml` 的 `dependencies` 为空，AES-256-GCM、SHA-256、tar/ustar 打包全部手写
- **强制关闭 gzip**：`server.autoCompress = false`。Dart 默认会把 SSE 也纳入压缩，字节被编码器内部缓冲，导致「一直思考、不出回答」
- **单请求异常隔离**：每个请求独立 `try/catch`，配合 `runZonedGuarded`，任何未捕获异常只记日志、绝不退出进程
- **端口占用重试**：启动时最多重试 10 次（间隔 300ms），避免旧实例未释放就启动失败
- **SSE 心跳**：`server.idleTimeout` 设为 120 秒

---

## ❓ 常见问题

<details>
<summary><b>启动后浏览器打不开页面？</b></summary>

1. 看启动日志里的端口号是否为预期值（`DSH_PORT` 可覆盖）
2. `curl -I http://127.0.0.1:9999/` 检查是否有响应
3. 若进程存在但端口无监听，通常是残留实例占位，执行 `python3 st.py --restart`
</details>

<details>
<summary><b>豆包接口返回 404 <code>InvalidEndpointOrModel.NotFound</code>？</b></summary>

这是**模型名与端点不匹配**，不是权限问题。例如把播客模型 `Doubao_scene_SLM_Doubao_Podcast_model` 发给 `/chat/completions` 就会 404。本项目已在代码层做了收敛：台本生成只接受 `chat` 类模型，语音合成只接受 `tts` 类模型，非法模型名会自动回退到默认值。
</details>

<details>
<summary><b>端到端语音一直 401？</b></summary>

Seeduplex 需要**豆包语音控制台**的 API Key，用方舟（ARK）的 Key 一定 401。请在设置中单独填写「豆包音声 API Key（Seeduplex 用）」。
</details>

<details>
<summary><b>朗读没有声音？</b></summary>

Edge TTS 依赖微软的签名机制（`Sec-MS-GEC` v2），且对 `User-Agent` 敏感。本项目已用自定义 WebSocket 客户端规避。若仍失败，请检查网络出口是否能访问 `speech.platform.bing.com`。
</details>

<details>
<summary><b>后台运行一段时间就断了？</b></summary>

安卓省电策略会回收后台进程。建议：
1. 用 `python3 st.py --daemon` 启动（自动持 wake-lock）
2. 用 `python3 st.py --install-service` 注册守护服务（崩溃自动拉起 + 开机自启）
3. 在系统设置中把 Termux 加入电池优化白名单
</details>

<details>
<summary><b>我想改端口 / 迁移目录？</b></summary>

改 `.env` 里的 `DSH_PORT` 与 `DSH_BASE`，然后重启服务。注意 `DSH_BASE` 同时也是数据的存放位置，迁移前请先做一次备份。
</details>

---

## ⚠️ 注意事项

> **以下每一条都来自实际踩过的坑，请务必阅读。**

**1. API Key 为本地明文存储**

- 豆包 ARK Key 以明文写入 `.sts` 文件（界面已如实标注）
- 聊天记录的加密依赖 `DS_MASTER_KEY`，**该密钥一旦丢失，历史会话将无法解密**
- `.env`、`*.key`、`data/` 均已在 `.gitignore` 中排除，请勿强行提交到公开仓库

**2. 恢复备份会覆盖全部数据**

「从备份恢复」会用上传的 `.tar.gz` 覆盖当前 `data/` 与 `imgs/` 全部内容，**不可撤销**。操作前请先备份。

**3. 端口默认 9999，不是 9998**

服务默认端口由 `DSH_PORT` 决定，未设置时为 `9999`。请以启动日志为准。

**4. 前端改动即时生效，后端改动必须重新编译**

`.js` / `.css` / `.html` 是静态文件，刷新页面即生效；`lib/src/*.dart` 属于后端，必须重新 `dart compile exe` 或 `dart run` 才会生效。

**5. 豆包模型必须与端点匹配**

| 端点 | 只能接受 |
| :--- | :--- |
| `/chat/completions` | `chat` 类模型 |
| `/images/generations` | `image` / `imageedit` 类模型 |
| `/audio/speech` | `tts` 类模型 |

混用会直接 404，且不会消耗配额。项目内已做兜底收敛。

**6. 工具模式会真实操作你的手机**

`execute_command`、`tap`、`uninstall_app`、`settings_put`、`kill_process` 等工具是**真实执行**的，没有沙箱。请：

- 不要在无人看管时让它执行删除、卸载、转账类指令
- 涉及支付、删除、卸载的操作，务必人工确认

**7. 界面自动旋转相关设置请勿改动**

本项目运行期间不修改系统屏幕方向配置，避免自动化点击坐标错位。

**8. 关于 adb 权限**

`adb_up.sh` 通过本机无线调试端口 `127.0.0.1:5555` 建立 `uid=2000(shell)` 连接，`auto.py` 在此权限下工作。前置条件：**设置 → 开发者选项 → 无线调试** 已开启。Project 内部已移除对 Shizuku 的依赖。

**9. RTC 功能需要额外 SDK**

服务端可以正常创建 `StartVoiceChat` 任务，但浏览器端要真正收发音视频，需要自行引入官方 **RTC Web SDK** 并加入同一房间（本仓库未内置）。

**10. 许可证**

本仓库目前**未包含 LICENSE 文件**。在权利人明确授权前，请勿用于商业分发。

---

<div align="center">

**🐋 Dart · DeepSeek Harness v2.1.0**

从 14,080 行 Go 到 100% 纯 Dart · 零依赖 · 一个浏览器窗口控制整台手机

`dart compile exe bin/main.dart -o app`

</div>
