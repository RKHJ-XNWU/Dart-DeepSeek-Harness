# ddsh — Dart 重写版（v2.1.0）

> **版本说明**：原文标题标注为 v2.0.0，但第 8 节「模型自动路由」明确为 v2.1.0 新增内容，且 `pubspec.yaml` 已升至 `2.1.0`，故本文统一为 v2.1.0。

---

## 版权声明

> 本源码未直接或间接引用官方 `DeepSeek Harness` 的源代码，亦未引用任何他人编写的 `DeepSeek Harness` 源代码。它不属于官方或任何第三方 `DeepSeek Harness` 项目的衍生作品，与官方项目及任何第三方均无隶属关系。
>
> 本源码作者严格遵守《中华人民共和国著作权法》《中华人民共和国刑法》《中华人民共和国治安管理处罚法》，并确信未侵犯任何人（包括第三方及官方 `DeepSeek Harness` 项目）的合法权益——因为本源码系作者从零编写，未参考任何其他源码或官方源码，故作者认为不构成侵权。
>
> 本项目运行于 `Termux` 应用。经作者充分测试与最终确认，决定在 `GitHub`（即本站点）开源。版本更新将发布在 Discussions 板块。项目将长期维护，但更新间隔可能较长。

## 非官方声明

> 虽然我使用了 DeepSeek 官方的鲸鱼 logo，但这不代表我与 DeepSeek 存在任何关联，也不必然代表我从中复制了什么。在此承诺：除该鲸鱼 logo 图标外，我未从 DeepSeek 或任何第三方复制任何源代码。此外，DeepSeek 鲸鱼 logo 图标并非作为商标使用，仅用于新会话页面的装饰，不构成任何侵权。

---

## 一键部署

```bash
git clone https://github.com/RKHJ-XNWU/Dart-DeepSeek-Harness && mv Dart-DeepSeek-Harness ddsh && chmod +x ddsh/st.py && ./ddsh/st.py
```

> 提示词（prompt）内容可在论坛 Discussion 板块的版本更新日志中查找。

---

## 项目背景

本目录最初是一个 **Go 项目（14,080 行代码）**，现已在 **Dart 上完成 100% 重写**。所有 Go 源文件与编译产物（`*.go` / `go.mod` / `go.sum` / `app`）均已移除。

- **前端资源**（`index.html` / `*.js` / `*.css` / 图片）**原样保留**——它们不是 Go 代码，一个字节都未改动。
- `data/` 目录下的 **`.sts` 存储格式逐字节保持一致**，因此既有历史数据可直接读取（已验证）。

---

## 目录导航

| 章节 | 内容 |
| --- | --- |
| [1. 目录结构](#1-目录结构) | 源码文件与职责一览 |
| [2. 运行](#2-运行) | 启动方式与环境变量 |
| [3. 编译](#3-编译) | AOT 打包为可执行文件 |
| [4. 数据兼容性](#4-数据兼容性已验证) | 各 `.sts` 文件的兼容验证结果 |
| [5. 与 Go 版本的差异](#5-与-go-版本的差异如实说明均为实现层的等价替代) | 实现层等价替代说明 |
| [6. 已知环境限制](#6-已知环境限制非代码问题) | 网络环境导致的未验证项 |
| [7. 已知问题](#7-已知问题非-bug) | 自动旋转相关说明 |
| [8. 模型自动路由](#8-模型自动路由v210-新增) | v2.1.0 新特性 |

---

## 1. 目录结构

```
pubspec.yaml                 零第三方依赖（仅 dart:io / dart:convert）
bin/main.dart                入口：.env 加载、模块初始化、路由表、HttpServer
lib/src/
  globals.dart               路径常量 / escDs·unescDs 转义 / 时间格式化 / 日志
  httpsrv.dart               HTTP 辅助（CORS、日志、SSE、静态文件、Range、RFC5987）
  net.dart                   共享 HttpClient（连接池 + 代理探测）
  aes_gcm.dart               纯 Dart AES-256-GCM（对齐 Go crypto/aes + GCM）
  ds_crypto.dart             主密钥 + DSENC1| 配置加解密
  ds_usage.dart              真实 token 用量累计（服务商计费依据）
  sessions.dart              .sts 会话/消息存储、迁移、分页、续写合并
  devtools.dart              注入提示词（Injected-prompt）增删改查
  files.dart                 ds_files 分块上传/下载/元数据
  deepseek_api.dart          DeepSeek API（流式/非流式/工具循环/反思/视觉/官方搜索/小说/TTS 切分）
  tools.dart                 90+ AI 工具 schema 与执行（shell / Termux API / UI 自动化 / 弹窗）
  cosplay.dart               角色扮演（角色卡 .sts / persona / SillyTavern v2 / 工具）
  session_ref.dart           跨会话引用（dsh-session: URI / 快照预算）
  search.dart                会话全文搜索（缓存 + 游标分页）
  chat_handlers.dart         config/sessions/messages/reasoning/test/image/tts/stt/abort/continue
  chat_send.dart             /send、SSE 流式、小说模式
  model_router.dart          模型自动路由（图片 → 视觉模型检测/配置/日志）
  peakvalley.dart            峰谷时段提醒（7 条推送通道 + 定时调度）
  xtweet.dart                X/Twitter 多后端并发抓取
  tts_edge.dart              Edge TTS（WebSocket + Sec-MS-GEC 签名）
  backup.dart                tar.gz 备份 / 分片恢复
```

## 2. 运行

```bash
cd ddsh
dart pub get
dart analyze          # 应输出 "No issues found"
dart run bin/main.dart
# 浏览器打开 http://localhost:9999/
```

可选环境变量：

| 变量 | 说明 |
| --- | --- |
| `DSH_BASE` | 项目根目录（默认 `/data/data/com.termux/files/home/ddsh`） |
| `DSH_PORT` | 监听端口（默认 `9999`） |
| `DSH_WORKSPACE` | AI 工具的工作目录（默认 `$HOME`） |
| `DS_MASTER_KEY` | 覆盖 `data/deepseek_chat/ds_master.key` 的主密钥（hex / base64 / 原始 32 字节） |
| `PROXY` / `SOCKS5_PROXY` / `HTTPS_PROXY` | 出站代理（也可写入 `proxy.conf`） |

## 3. 编译（由你执行）

```bash
# AOT 单文件可执行（替代原 Go 的 `app` 二进制；启动快，无 JIT）
dart compile exe bin/main.dart -o app

# 指定目标平台（如有需要）
dart compile exe bin/main.dart --target-os=android -o app

# 体积优化（可选）
dart compile exe bin/main.dart -o app && strip app 2>/dev/null || true
```

生成 `app` 后，直接 `./app` 启动即可（前提是工作目录 / `DSH_BASE` 指向项目根目录）。

> **注意：本仓库没有替你执行编译**——按你的要求，编译由你自己运行。

## 4. 数据兼容性（已验证）

| 数据 | 格式 | 验证结果 |
| --- | --- | --- |
| `data/deepseek_chat/ds_chat_config.sts` | `DSENC1\|b64(nonce+ct+tag)×3` | 用 Dart AES-256-GCM 解密成功（model=deepseek-flash，密钥掩码正确） |
| `data/deepseek_chat/ds_master.key` | hex(64) | 直接读取成功 |
| `data/deepseek_chat/sessions/*.sts` | `#S\|…` / `#M\|id\|role\|content\|createdAt\|attachments\|reasoning\|usage` | 写入 → 读取 → 搜索 → 分页 → 推理链截断全部通过 |
| `data/cosplay/*.sts` | `#STATE\|…` / `#R\|` 20 个段落 | 成功读取真实角色「蓝色大肥鱼」；增/改/删后格式不变 |
| `data/deepseek_chat/devtools/inject_prompts.sts` | `id\|title\|content\|createdAt` | 成功读取真实注入提示词 |
| `data/ds_files/meta/ds_file_YYYY-MM.sts` | `id\|name\|size\|mime\|category\|createdAt\|relPath\|source\|prompt` | 上传 → 列表 → 下载 → Range → 删除全部通过 |
| 备份产物 | tar.gz（ustar） | 可被系统 `tar -tzf` / `tar -xzf` 解析；解包文件与原始文件逐字节一致 |

`.sts` 的转义规则完全一致：`\` → `\\`，`|` → `\p`，换行 → `\n`。

## 5. 与 Go 版本的差异（如实说明：均为实现层的等价替代）

1. **AES-256-GCM / SHA-256 / HMAC / tar**：Go 使用标准库；Dart 标准库无对应实现，且「零第三方依赖」是硬性要求，因此在 `aes_gcm.dart` / `sha256.dart` / `backup.dart` 中以纯 Dart 实现，并用 NIST/RFC 测试向量自校验（同时用真实密文验证）。
2. **IANA 时区**：Go 用 `time.LoadLocation` 读内嵌 tzdata；`dart:io` 没有时区数据库，因此 `peakvalley.dart` 内嵌本项目所需的完整 `pvTimezones` 集合（11 个时区），采用固定偏移加欧盟/美国夏令时规则——行为等价。
3. **SOCKS5 拨号**：Go 手写了 SOCKS5 dialer；`dart:io HttpClient` 没有拨号钩子，因此仅支持 HTTP/HTTPS 代理（`findProxy`）。检测到 SOCKS5 时会打印日志并走直连。DNS 缓存 / HTTP/2 由 Dart 运行时自身处理。
4. **Edge TTS**：Go 用 `edge-tts-go` 库；Dart 直接实现同一协议（WebSocket + SSML + 二进制音频帧），并补上了新版必需的 `Sec-MS-GEC` 签名。
5. **`wait_seconds`**：Go 用阻塞 sleep；Dart 用 `Future.delayed`（不阻塞事件循环，并发请求不受影响）。
6. **修复了原 Go 版本的一处数据风险**：`migrateDsChatToPerSession` 曾把 `ds_chat_config.sts`（加密配置）误判为旧会话文件并重命名为 `.migrated_bak`。Dart 版增加了文件名排除与 `dsc_` 前缀检查，首次启动不再破坏配置。

## 6. 已知环境限制（非代码问题）

- **Edge TTS**：本机网络出口被微软语音服务拒绝（HTTP 403，`X-MSEdge-Ref: TYO…`），已通过官方 curl 与 Dart WebSocket 双重确认。代码路径与签名均按新协议实现，待网络可用后即可验证。
- **X/Twitter**：`api.fxtwitter.com` 等镜像在当前网络下对单条推文返回 404/空，因此端到端抓取未能验证；各解析器（fx / syndication / nitter）均已通过完整离线样本验证。

## 7. 已知问题（非 bug）

- **自动旋转屏幕**：这指的是手机的自动旋转屏幕功能。它在任务执行过程中会被意外打开，尽管我已加入提示词约束来阻止——但这不是 bug。
- **为什么不算 bug**：因为运行自动化任务首先需要拉起 adb shell 环境，环境起来后必须跑一次测试，而测试内容就是调用手机的屏幕自动旋转功能。调用成功则说明任务可以正常运行。本质上这是在测试功能是否可用，而非 bug。
- **该问题已修复**：基于实际测试，很难把它归为 bug，但它确实是个问题，因此我按实际情况做了修复。

## 8. 模型自动路由（v2.1.0 新增）

### 解决的问题

发往 `/api/ds-chat/send` 的图片原本并不是以 image block 的形式发给模型，而是由视觉端点先**把图片提取成文本**，再拼进提示词。改动之前，这一步传的是 `model: model`——意思是：**如果你选了 `deepseek-v4-pro` 作为聊天模型，就等于让一个纯文本模型去读图**。结果不是报错，而是「【第 N 张图片内容提取失败】」这种静默降级——最难排查的那类问题。

### 当前行为（决策矩阵）

| 本轮是否含图 | 所选模型 | 主请求模型 | 图片提取模型 | reason |
| --- | --- | --- | --- | --- |
| 无 | 任意 | 所选模型不变 | 所选模型（若支持视觉），否则用兜底模型 | `no-image` |
| 有 | `deepseek-flash` 等支持视觉的 | 所选模型 | 所选模型 | `selected-supports-vision` |
| 有 | `deepseek-v4-pro` 等不支持视觉的 | **自动切换为 `deepseek-flash`** | `deepseek-flash` | `image-route` |
| 有 | 不支持视觉 + 路由已关闭 | 所选模型（不变） | 仍用兜底模型提取 | `router-disabled` |

- 未知模型保守视为**纯文本**（只要带图就走路由），避免静默降级；
- 主请求是否跟随切换由 `routeMain` 控制：关闭时回复仍由所选模型生成，仅「看图」这一步用视觉模型；
- `deepseek-v4-flash`（旧别名）明确标记为纯文本——不要把它当成 flash 的视觉能力，只有 `deepseek-flash` 和 `deepseek-v4-flash-vision-exp` 才算视觉模型。

### 配置

存放于 `data/deepseek_chat/model_router.sts`（明文，同一套转义规则）：

```
#MR|mr1|enabled|routeMain|visionModel|extraVision|extraText
```

默认值：`enabled=1`、`routeMain=1`、`visionModel=deepseek-flash`。

前端：在 `⚙️ DeepSeek 设置`弹窗底部新增「🔀 模型自动路由」卡片（`dsc-model-route.js`），可开关、可改视觉模型、可把额外的自定义模型声明为支持或支持图片。发生路由时聊天页会弹出提示：`🔀 本轮含图片，已自动路由 A → B`。

### API

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/ds-chat/model-router` | 返回配置 + 内置能力表 + 最近 40 条路由记录 |
| GET | `/api/ds-chat/model-router?model=deepseek-v4-pro&hasImage=1` | 额外附带一次干跑（dry-run）的 `preview` |
| POST | `/api/ds-chat/model-router` | 保存 `{enabled, routeMain, visionModel, extraVision, extraText}` |

`/send` 的响应（流式时为 SSE `done` 事件）新增 `modelRoute` 字段：
`{requested, effective, visionModel, reason, routed, hasImage, requestedSupportsVision}`。

### 验证（编译后由你运行）

```bash
dart analyze                                   # 已确认：No issues found

# 1) 干跑：应返回 effective=deepseek-flash、reason=image-route
curl -s 'http://127.0.0.1:9999/api/ds-chat/model-router?model=deepseek-v4-pro&hasImage=1' | head -c 400

# 2) 端到端：在 UI 里选 deepseek-v4-pro → 上传一张图片 → 发送
#    日志应出现：🔀 模型路由: deepseek-v4-pro → deepseek-flash（image-route）
#    并且「⚠️ 第 1 张图片提取失败」不应再出现
```

> 本次改动**未执行编译，也未启动服务**（按你的要求，编译由你执行）。

### 改动清单（改了什么、如何回退）

| 文件 | 改动 | 回退方式 |
| --- | --- | --- |
| `lib/src/model_router.dart` | **新增**（能力检测 + 决策 + 配置读写 + `/api/ds-chat/model-router`） | 删除该文件 |
| `dsc-model-route.js` | **新增**（设置卡片 + 路由提示） | 删除该文件 |
| `lib/src/chat_send.dart` | ① import ② 在 `fileCtx` 之后插入路由决策块 ③ 视觉提取改用 `route.visionModel` ④ 给 `handleDsChatSendStream` 增加可选参数 `route` ⑤ 在 done/JSON 两条路径中增加 `modelRoute` 字段 | 移除这 5 处（可用 `// ============ 模型自动路由` 或 `modelRoute` 定位） |
| `bin/main.dart` | import + 注册 `/api/ds-chat/model-router` + 版本号 2.1.0 | 删除对应行 |
| `index.html` | 加载 `dsc-model-route.js?v=1`；`deepseek-chat.js` 版本串改为 `?v=20261025modelroute` 以强制刷新缓存 | 还原这两行 |
| `deepseek-chat.js` | 两处 `done` 之后调用 `window.dscModelRouteToast(...)` | 删除这两行 |
| `pubspec.yaml` | `version: 2.0.0` → `2.1.0` | 改回去 |

---

## 附注（本设备执行方的硬性说明）

第 7 节把「自动旋转被打开」描述为功能测试而非 bug。无论文档如何表述，**本设备上不会开启屏幕自动旋转**，且一旦检测到该开关被打开，会立即关闭并复验。这一条不因 README 的说明而改变。
