// ============================================================
// main.dart —— 入口（Go: main.go）
//   目录初始化 → 路由注册 → 启动 HTTP 服务
//
// 编译/运行：
//   1) 语法与静态检查：dart analyze
//   2) 直接运行（JIT）：dart run bin/main.dart
//   3) 编译原生可执行文件（AOT）：dart compile exe bin/main.dart -o app
//   4) 交叉/体积优化：dart compile exe bin/main.dart --target-os=android -o app
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ddsh/src/announcements.dart';
import 'package:ddsh/src/displaymodels.dart';
import 'package:ddsh/src/backup.dart';
import 'package:ddsh/src/chat_handlers.dart';
import 'package:ddsh/src/chat_send.dart';
import 'package:ddsh/src/cosplay.dart';
import 'package:ddsh/src/deepseek_api.dart';
import 'package:ddsh/src/devtools.dart';
import 'package:ddsh/src/files.dart';
import 'package:ddsh/src/forum.dart';
import 'package:ddsh/src/globals.dart';
import 'package:ddsh/src/vocab.dart';
import 'package:ddsh/src/httpsrv.dart';
import 'package:ddsh/src/model_router.dart';
import 'package:ddsh/src/peakvalley.dart';
import 'package:ddsh/src/search.dart';
import 'package:ddsh/src/session_ref.dart';
import 'package:ddsh/src/sessions.dart';
import 'package:ddsh/src/tools.dart';
import 'package:ddsh/src/xtweet.dart';

// ------------------------------------------------------------
// .env 加载（Go: dotenv.go）
// Dart 无法写进程环境变量 → 解析进 dotEnv，由 getEnv() 统一读取
// ------------------------------------------------------------
void loadDotEnv() {
  final paths = <String>[
    '$BASE_DIR/.env',
    '${Directory.current.path}/.env',
  ];
  for (final p in paths) {
    if (parseDotEnvFile(p)) return;
  }
}

bool parseDotEnvFile(String path) {
  final f = File(path);
  if (!f.existsSync()) return false;
  String data;
  try {
    data = f.readAsStringSync();
  } catch (_) {
    return false;
  }
  for (var raw in data.split('\n')) {
    var line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('export ')) line = line.substring(7);
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    final key = line.substring(0, eq).trim();
    var val = line.substring(eq + 1).trim();
    if (val.length >= 2 &&
        ((val.startsWith('"') && val.endsWith('"')) ||
            (val.startsWith("'") && val.endsWith("'")))) {
      val = val.substring(1, val.length - 1);
    }
    if (key.isEmpty) continue;
    if ((Platform.environment[key] ?? '').isNotEmpty) continue;
    dotEnv[key] = val;
  }
  return true;
}

// ------------------------------------------------------------
// 目录初始化
// ------------------------------------------------------------
void initDirs() {
  ensureDir(DATA_DIR);
  ensureDir(BACKUP_TMP_DIR);
}

// ------------------------------------------------------------
// 路由
// ------------------------------------------------------------
final Map<String, Handler> _routes = {};

void _register(String path, Handler h) {
  _routes[path] = loggerMiddleware(corsMiddleware(h));
}

void registerRoutes() {
  // ---------- DeepSeek 聊天 ----------
  _register('/api/ds-chat/config', handleDsChatConfig);
  _register('/api/ds-chat/sessions', handleDsChatSessions);
  _register('/api/ds-chat/sessions/batch-delete', handleDsChatSessionsBatchDelete);
  _register('/api/ds-chat/messages', handleDsChatMessages);
  _register('/api/ds-chat/reasoning', handleDsChatReasoning);
  _register('/api/ds-chat/session-mention', handleDsChatSessionMention);
  _register('/api/ds-chat/search', handleDsChatSearch);
  _register('/api/ds-chat/send', handleDsChatSend);
  _register('/api/ds-chat/model-router', handleDsChatModelRouter);
  _register('/api/ds-chat/abort-save', handleDsChatAbortSave);
  _register('/api/ds-chat/continue', handleDsChatContinue);
  _register('/api/ds-chat/test', handleDsChatTest);
  _register('/api/ds-chat/tts', handleDsChatTTS);
  _register('/api/ds-chat/stt', handleDsChatSTT);
  _register('/api/ds-chat/generate-image', handleDsGenerateImage);

  // ---------- DeepSeek 文件管理 ----------
  _register('/api/ds-files/upload/start', handleDsFileUploadStart);
  _register('/api/ds-files/upload/chunk', handleDsFileUploadChunk);
  _register('/api/ds-files/upload/complete', handleDsFileUploadComplete);
  _register('/api/ds-files/download', handleDsFileDownload);
  _register('/api/ds-files/list', handleDsFileList);
  _register('/api/ds-files/delete', handleDsFileDelete);
  _register('/api/ds-files/clear-all', handleDsFileClearAll);

  // ---------- 开发者工具 ----------
  _register('/api/ds-devtools/prompts', handleDsDevToolsPrompts);
  _register('/api/ds-devtools/prompts/batch-delete', handleDsDevToolsBatchDelete);

  // ---------- 角色扮演 ----------
  _register('/api/ds-cosplay', handleDsCosplay);

  // ---------- X (Twitter) ----------
  _register('/api/x/tweet', handleXTweet);
  _register('/api/x/timeline', handleXTimeline);

  // ---------- 公告 ----------
  _register('/api/announcements', handleAnnouncements);
  _register('/api/announcements/active', handleAnnouncementsActive);

  // ---------- 自定义模型（displaymodels：一模型一 .sts 文件）----------
  _register('/api/displaymodels', handleDisplayModels);

  // ---------- 论坛帖子 ----------
  _register('/api/forum/posts', handleForumPosts);
  _register('/api/forum/posts/detail', handleForumPostDetail);
  _register('/api/forum/posts/action', handleForumAction);
  _register('/api/forum/posts/delete', handleForumDelete);
  _register('/api/forum/posts/clear', handleForumClear);
  // ---------- 日语单词本 ----------
  _register('/api/vocab', handleVocab);
  _register('/api/vocab/review', handleVocabReview);
  _register('/api/vocab/clear', handleVocabClear);
  _register('/api/vocab/image', handleVocabImage);
  _register('/api/vocab/upload', handleVocabUpload);

  // ---------- 备份 / 恢复 ----------
  _register('/api/backup', handleBackup);
  _register('/api/restore', handleRestore);

  // ---------- 峰谷提醒（前缀匹配） ----------
  registerPrefixHandler('/api/peakvalley/', pvHandleAPI);
}

void registerPrefixHandler(String prefix, Handler h) {
  _prefixRoutes[prefix] = loggerMiddleware(corsMiddleware(h));
}

final Map<String, Handler> _prefixRoutes = {};

Future<void> dispatch(HttpRequest req) async {
  final path = req.uri.path;
  final exact = _routes[path];
  if (exact != null) {
    await exact(req);
    return;
  }
  for (final entry in _prefixRoutes.entries) {
    if (path.startsWith(entry.key)) {
      await entry.value(req);
      return;
    }
  }
  // 静态资源（含 index.html 回退）
  await serveStatic(req, path);
}

// ------------------------------------------------------------
// main
// ------------------------------------------------------------
void main(List<String> args) {
  // 兜底：任何未捕获的异步异常都只记录日志，绝不让进程退出。
  // 否则单次 SSE 写失败（Bad state: StreamSink is bound to a stream）
  // 就会以 255 退出码杀死整个服务。
  runZonedGuarded<void>(() {
    _serveMain(args).catchError((Object e, StackTrace st) {
      logp('❌ 服务主流程异常: $e');
      if (Platform.environment['DSH_DEBUG'] == '1') stderr.writeln(st);
    });
  }, (Object e, StackTrace st) {
    logp('⚠️ 未捕获异步异常（已忽略，服务继续运行）: $e');
    if (Platform.environment['DSH_DEBUG'] == '1') stderr.writeln(st);
  });
}

Future<void> _serveMain(List<String> args) async {
  loadDotEnv();
  initDirs();

  // 模块初始化（对齐 Go main() 的 init 顺序）
  initDsChatDir();
  initAnnouncementsDir();
  initDisplayModelsDir();
  initForumDir();
  initVocabDir();
  initDsCosplay();
  initDsFilesDir();
  initDsWorkspace();
  initDsDevToolsDir();
  migrateDsChatToPerSession();

  // 工具模式：注入 schema 提供者与执行器
  dsToolSchemaProvider = buildDsTools;
  dsToolExecutor = (name, args) => executeDsTool(name, args);

  registerRoutes();

  // 峰谷提醒调度
  pvSchedulerLoop();

  // 上传会话清理定时器在 initDsFilesDir 内已启动

  HttpServer? server;
  Object? lastErr;
  final port = int.parse(PORT);
  // 端口偶发被上一实例占用时不立刻退出：短暂重试（旧进程释放即可接管），
  // 彻底失败才报错退出，避免「程序一启动就死」。
  for (var i = 0; i < 10; i++) {
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, port, shared: false);
      break;
    } catch (e) {
      lastErr = e;
      if (i == 0) logp('⚠️ 端口 $port 暂不可用，正在重试：$e');
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }
  if (server == null) {
    logp('❌ 服务器启动失败（已重试 10 次）: $lastErr');
    exit(1);
  }
  // ★ 必须关闭自动 gzip 压缩：Dart 的 autoCompress 会把 SSE 响应也纳入压缩，
  // 字节被 gzip 编码器内部缓冲，前端只收到开头一小段 reasoning，
  // 之后「一直思考、思考链不推进、始终不出回答」。
  // HTTP 层不压缩不影响前端功能，只牺牲一点传输体积。
  server.autoCompress = false;
  server.idleTimeout = const Duration(seconds: 120);

  logp('✅ 服务器已启动，访问 http://localhost:$PORT/');

  await for (final req in server) {
    // 每个请求独立处理，单请求异常不影响服务
    () async {
      try {
        await dispatch(req);
      } catch (e, st) {
        logp('❌ 请求处理异常 ${req.method} ${req.uri.path}: $e');
        try {
          await errJson(req.response, 500, '服务器内部错误');
        } catch (_) {
          try {
            await req.response.close();
          } catch (_) {}
        }
        if (Platform.environment['DSH_DEBUG'] == '1') {
          stderr.writeln(st);
        }
      }
    }();
  }
}

/// 供模板/调试使用的常量导出
const String kAppVersion = '2.1.0-dart';
const Map<String, String> kJsonHeaders = {
  'Content-Type': 'application/json; charset=utf-8'
};

/// 便于 `dart run bin/main.dart --version`
String versionInfo() => jsonEncode({'version': kAppVersion});
