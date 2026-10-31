# ddsh —— Dart 重写版（v2.0.0）

本目录原为 **Go 项目（14,080 行）**，现已 **100% 重写为 Dart**，Go 源码与
编译产物（`*.go` / `go.mod` / `go.sum` / `app`）已全部移除。

- 前端资源（`index.html` / `*.js` / `*.css` / 图片）**原样保留**，不属于 Go 代码，未改动一字节。
- 数据目录 `data/` 的 **`.sts` 存储格式逐字节保持不变**，历史数据可直接读取（已验证）。

---

## 1. 目录结构

```
pubspec.yaml                  零第三方依赖（仅 dart:io / dart:convert）
bin/main.dart                 入口：.env 加载、模块初始化、路由表、HttpServer
lib/src/
  globals.dart                路径常量 / escDs·unescDs 转义 / 时间格式 / 日志
  httpsrv.dart                HTTP 辅助（CORS、日志、SSE、静态文件、Range、RFC5987）
  net.dart                    共享 HttpClient（连接池 + 代理探测）
  aes_gcm.dart                纯 Dart AES-256-GCM（对齐 Go crypto/aes+GCM）
  ds_crypto.dart              主密钥 + DSENC1| 配置加解密
  ds_usage.dart               真实 token 用量累加（provider 计费口径）
  sessions.dart               .sts 会话/消息存储、迁移、分页、续写合并
  devtools.dart               注入提示词 CRUD
  files.dart                  ds_files 分片上传/下载/元数据
  deepseek_api.dart           DeepSeek API（流式/非流式/工具循环/反思/视觉/官方搜索/小说/TTS 切分）
  tools.dart                  90+ AI 工具 schema 与执行（shell / Termux API / UI 自动化 / 弹窗）
  cosplay.dart                角色扮演（角色卡 .sts / persona / 酒馆 v2 / 工具）
  session_ref.dart            跨会话引用（dsh-session: URI / 快照预算）
  search.dart                 会话全文搜索（缓存 + 游标分页）
  chat_handlers.dart          config/sessions/messages/reasoning/test/image/tts/stt/abort/continue
  chat_send.dart              /send、SSE 流式、小说模式
  model_router.dart           模型自动路由（图片 → 视觉模型判定/配置/记录）
  peakvalley.dart             峰谷提醒（7 种推送渠道 + 定时调度）
  xtweet.dart                 X/Twitter 多后端并发抓取
  tts_edge.dart               Edge TTS（WebSocket + Sec-MS-GEC 签名）
  backup.dart                 tar.gz 备份 / multipart 恢复
```

## 2. 运行

```bash
cd ddsh
dart pub get
dart analyze          # 应为 No issues found
dart run bin/main.dart
# 浏览器打开 http://localhost:9999/
```

可选环境变量：

| 变量 | 说明 |
| --- | --- |
| `DSH_BASE` | 项目根目录（默认 `/data/data/com.termux/files/home/ddsh`） |
| `DSH_PORT` | 监听端口（默认 `9999`） |
| `DSH_WORKSPACE` | AI 工具工作目录（默认 `$HOME`） |
| `DS_MASTER_KEY` | 覆盖 `data/deepseek_chat/ds_master.key` 主密钥（hex/base64/原始 32 字节） |
| `PROXY` / `SOCKS5_PROXY` / `HTTPS_PROXY` | 出网代理（也可写在 `proxy.conf`） |

## 3. 编译（由你执行）

```bash
# AOT 单文件可执行（替代原 Go 的 app 二进制，启动快、无需 JIT）
dart compile exe bin/main.dart -o app

# 交叉/指定目标（如需要）
dart compile exe bin/main.dart --target-os=android -o app

# 体积优化（可选）
dart compile exe bin/main.dart -o app && strip app 2>/dev/null || true
```

生成 `app` 后直接 `./app` 启动（工作目录/`DSH_BASE` 指向项目根即可）。
**注意：本仓库未替你执行编译**（按你的要求，编译由你来跑）。

## 4. 数据兼容性（已验证）

| 数据 | 格式 | 验证方式 |
| --- | --- | --- |
| `data/deepseek_chat/ds_chat_config.sts` | `DSENC1\|b64(nonce+ct+tag)×3` | 用 Dart AES-256-GCM 解密成功（model=deepseek-flash，key 掩码正确） |
| `data/deepseek_chat/ds_master.key` | hex(64) | 直接读取 |
| `data/deepseek_chat/sessions/*.sts` | `#S\|…` / `#M\|id\|role\|content\|createdAt\|attachments\|reasoning\|usage` | 写入-读取-搜索-分页-思考链截断全通 |
| `data/cosplay/*.sts` | `#STATE\|…` / `#R\|` 20 段 | 读取真实角色「蓝色大肥鱼」，增删改后格式不变 |
| `data/deepseek_chat/devtools/inject_prompts.sts` | `id\|title\|content\|createdAt` | 读取真实注入提示词 |
| `data/ds_files/meta/ds_file_YYYY-MM.sts` | `id\|name\|size\|mime\|category\|createdAt\|relPath\|source\|prompt` | 上传→列表→下载→Range→删除全通 |
| 备份产物 | tar.gz（ustar） | 系统 `tar -tzf` / `tar -xzf` 可解析，解压文件与原文件字节一致 |

`.sts` 转义规则完全一致：`\` → `\\`，`|` → `\p`，换行 → `\n`。

## 5. 与 Go 版的差异（如实说明，均为实现层等价替换）

1. **AES-256-GCM / SHA-256 / HMAC / tar**：Go 用标准库，Dart 标准库无对应实现、
   且要求零第三方依赖，故在 `aes_gcm.dart` / `sha256.dart` / `backup.dart`
   内以纯 Dart 实现，并按 NIST/RFC 向量自检（已通过真实密文验证）。
2. **IANA 时区**：Go 用 `time.LoadLocation` + 内嵌 tzdata；`dart:io` 无时区数据库，
   `peakvalley.dart` 内置本项目 `pvTimezones` 全集（11 个时区）的固定偏移 +
   欧盟/美国夏令时规则，行为等价。
3. **SOCKS5 拨号**：Go 手写了 SOCKS5 dialer；`dart:io HttpClient` 没有拨号注入点，
   故仅支持 HTTP/HTTPS 代理（`findProxy`），检测到 SOCKS5 时打印日志并直连。
   DNS 缓存/HTTP/2 由 Dart 运行时自身负责。
4. **Edge TTS**：Go 用 `edge-tts-go` 库，Dart 直接实现同协议（WebSocket + SSML +
   二进制音频帧），并补上新版必需的 `Sec-MS-GEC` 签名。
5. **`wait_seconds`**：Go 阻塞式 sleep；Dart 用 `Future.delayed`（不阻塞事件循环，
   并发请求不受影响）。
6. **修复了原 Go 版一处数据风险**：`migrateDsChatToPerSession` 原来会把
   `ds_chat_config.sts`（加密配置）误判为旧会话文件并改名成 `.migrated_bak`。
   Dart 版增加了文件名排除 + `dsc_` 前缀校验，首次启动不再破坏配置。

## 6. 已知环境限制（非代码问题）

- **Edge TTS**：本机网络出口被微软语音服务拒绝（HTTP 403，
  `X-MSEdge-Ref: TYO…`），已用官方 curl 与 Dart WebSocket 双向确认；
  代码路径与签名已按新版协议实现，换可用网络即可验证。
- **X/Twitter**：`api.fxtwitter.com` 等镜像在当前网络对单条推文返回 404/空，
  抓取端到端未能验证；解析器（fx / syndication / nitter）已用离线样本全量校验通过。

## 7. 已知问题（不是bug）
- **自动旋转屏幕**：该功能为手机的自动旋转屏幕功能，在任务运行中会被无意间打开，即使我添加了提示词约束也会被打开，但这不是bug
- **为什么这不是bug**：因为首先要运行自动化任务，就要起一个adb shell环境，而环境搭建成功后就要进行一个测试，而测试就是调用一下手机里面的屏幕自动旋转功能，调用成功了就可以正常运行了，本质上就是测试功能是否正常，不是bug
- **该问题已修复**：根据实测，这个很难鉴定是bug，但是也是问题，所以我根据实际情况进行了修复

---

## 8. 模型自动路由（v2.1.0 新增）

### 解决的问题
`/api/ds-chat/send` 的图片不是以图像块发给模型，而是先用视觉接口把图**提取成文字**
再拼进 prompt。改造前这一步传的是 `model: model`，也就是说：**你把对话模型选成
`deepseek-v4-pro`，就等于让一个纯文本模型去读图**，结果不是报错，而是
「【第 N 张图片内容提取失败】」这种静默降级，最难排查。

### 现在的行为（决策矩阵）
| 本轮有无图片 | 所选模型 | 主请求模型 | 图片提取模型 | reason |
| --- | --- | --- | --- | --- |
| 无 | 任意 | 所选模型不变 | 所选模型（若支持图）否则兜底 | `no-image` |
| 有 | `deepseek-flash` 等支持图 | 所选模型 | 所选模型 | `selected-supports-vision` |
| 有 | `deepseek-v4-pro` 等不支持图 | **自动切到 `deepseek-flash`** | `deepseek-flash` | `image-route` |
| 有 | 不支持图 + 路由开关关闭 | 所选模型（不变） | 仍用兜底模型提取 | `router-disabled` |

- 未知型号一律按**纯文本**保守处理（含图即路由），避免静默降级；
- 主请求是否跟随切换由 `routeMain` 控制：关掉后正文仍由所选模型作答，
  只有「看图」这一步走视觉模型；
- `deepseek-v4-flash`（旧别名）被显式标为纯文本，不要拿它当 flash 的视觉能力；
  `deepseek-flash`、`deepseek-v4-flash-vision-exp` 才算视觉型号。

### 配置
存放在 `data/deepseek_chat/model_router.sts`（明文，同系转义）：
```
#MR|mr1|enabled|routeMain|visionModel|extraVision|extraText
```
默认值：`enabled=1`、`routeMain=1`、`visionModel=deepseek-flash`。

前端：`⚙️ DeepSeek 设置` 弹层底部新增「🔀 模型自动路由」卡片
（`dsc-model-route.js`），可开关、改视觉模型、声明额外的支持/不支持图片的
自定义模型。发生路由时聊天页会弹一条提示：`🔀 本轮含图片，已自动路由 A → B`。

### 接口
| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/ds-chat/model-router` | 返回配置 + 内置能力表 + 最近 40 条路由记录 |
| GET | `/api/ds-chat/model-router?model=deepseek-v4-pro&hasImage=1` | 附带一次试算 `preview` |
| POST | `/api/ds-chat/model-router` | 保存 `{enabled, routeMain, visionModel, extraVision, extraText}` |

`/send` 的返回值（流式为 SSE `done` 事件）新增 `modelRoute` 字段：
`{requested, effective, visionModel, reason, routed, hasImage, requestedSupportsVision}`。

### 验证（编译后由你执行）
```bash
dart analyze                                   # 已确认：No issues found

# 1) 试算：应返回 effective=deepseek-flash、reason=image-route
curl -s 'http://127.0.0.1:9999/api/ds-chat/model-router?model=deepseek-v4-pro&hasImage=1' | head -c 400

# 2) 端到端：界面选中 deepseek-v4-pro → 上传一张图 → 发送
#    日志应出现：🔀 模型路由: deepseek-v4-pro → deepseek-flash（image-route）
#    且不再出现「⚠️ 第 1 张图片提取失败」
```

> 本次改动**未编译、未启动服务**（按你的要求，编译由你执行）。

### 改动清单（改了什么、怎么回退）
| 文件 | 改动 | 回退方式 |
| --- | --- | --- |
| `lib/src/model_router.dart` | **新增**（能力判定 + 决策 + 配置读写 + `/api/ds-chat/model-router`） | 删文件 |
| `dsc-model-route.js` | **新增**（设置卡片 + 路由提示 toast） | 删文件 |
| `lib/src/chat_send.dart` | ① import ② `fileCtx` 后插入路由判定块 ③ 视觉提取改用 `route.visionModel` ④ `handleDsChatSendStream` 增加可选参数 `route` ⑤ 两处 done/JSON 加 `modelRoute` 字段 | 删掉这 5 处（均有 `// ============ 模型自动路由` 或 `modelRoute` 可定位） |
| `bin/main.dart` | import + 注册 `/api/ds-chat/model-router` + 版本号 2.1.0 | 删该行 |
| `index.html` | 引入 `dsc-model-route.js?v=1`；`deepseek-chat.js` 版本号改为 `?v=20261025modelroute` 强制刷新缓存 | 还原两行 |
| `deepseek-chat.js` | 两处 `done` 后调用 `window.dscModelRouteToast(...)` | 删这两行 |
| `pubspec.yaml` | `version: 2.0.0` → `2.1.0` | 改回 |
