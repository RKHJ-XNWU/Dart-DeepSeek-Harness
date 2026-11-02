// ============================================================
// httpsrv.dart —— HTTP 服务辅助层（对齐 Go net/http 常用语义）
//   CORS / 访问日志 / body 读取 / JSON 响应 / SSE / 静态文件 / Range 下载
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'globals.dart';

typedef Handler = Future<void> Function(HttpRequest req);

// ------------------------------------------------------------
// 中间件
// ------------------------------------------------------------
Handler corsMiddleware(Handler next) {
  return (HttpRequest req) async {
    final res = req.response;
    res.headers.set('Access-Control-Allow-Origin', '*');
    res.headers.set('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS');
    res.headers.set('Access-Control-Allow-Headers', 'Content-Type');
    if (req.method == 'OPTIONS') {
      res.statusCode = 200;
      await res.close();
      return;
    }
    await next(req);
  };
}

Handler loggerMiddleware(Handler next) {
  return (HttpRequest req) async {
    final start = DateTime.now();
    try {
      await next(req);
    } finally {
      final ms = DateTime.now().difference(start).inMilliseconds;
      logp('${req.method} ${req.uri.path} ${ms}ms');
    }
  };
}

/// 读取 query 参数（自动修正非 ASCII 编码）
String qp(HttpRequest req, String key) =>
    decodeQueryValue(req.uri.queryParameters[key]);

// ------------------------------------------------------------
// Body 读取
// ------------------------------------------------------------
Future<List<int>> readBodyBytes(HttpRequest req, {int? limit}) async {
  final b = <int>[];
  await for (final chunk in req) {
    b.addAll(chunk);
    if (limit != null && b.length > limit) {
      throw const FormatException('リクエストボディがサイズ上限を超えています');
    }
  }
  return b;
}

Future<String> readBodyText(HttpRequest req, {int? limit}) async {
  final bytes = await readBodyBytes(req, limit: limit);
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return latin1.decode(bytes);
  }
}

Future<Map<String, dynamic>> readJsonBody(HttpRequest req, {int? limit}) async {
  final text = await readBodyText(req, limit: limit);
  if (text.trim().isEmpty) return <String, dynamic>{};
  try {
    return asMap(jsonDecode(text));
  } catch (_) {
    throw const FormatException('リクエストボディが有効な JSON ではありません');
  }
}

// ------------------------------------------------------------
// 响应
// ------------------------------------------------------------
Future<void> jsonResponse(HttpResponse res, int code, Object? data) async {
  String body;
  try {
    body = jsonEncode(data);
  } catch (_) {
    body = '{"error":"シリアライズに失敗しました"}';
  }
  await _writeJsonRaw(res, code, body);
}

/// 写入 JSON 文本：客户端已断开时静默结束，不向上抛异常
Future<void> _writeJsonRaw(HttpResponse res, int code, String body) async {
  try {
    res.statusCode = code;
    res.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
    res.write(body);
  } catch (_) {
    try {
      await res.close();
    } catch (_) {}
    return;
  }
  try {
    await res.close();
  } catch (_) {}
}

Future<void> jsonRaw(HttpResponse res, int code, String body) async {
  await _writeJsonRaw(res, code, body);
}

Future<void> errJson(HttpResponse res, int code, String msg) =>
    jsonResponse(res, code, {'error': msg});

// Go 版 dsJSON / dsErr 的等价命名
Future<void> dsJSONOk(HttpResponse res, int code, Object? v) =>
    jsonResponse(res, code, v);

Future<void> dsJSONErr(HttpResponse res, int code, String msg) =>
    errJson(res, code, msg);

Future<void> textResponse(HttpResponse res, int code, String body,
    {String mime = 'text/plain'}) async {
  try {
    res.statusCode = code;
    res.headers.contentType = ContentType.parse('$mime; charset=utf-8');
    res.write(body);
  } catch (_) {
    try {
      await res.close();
    } catch (_) {}
    return;
  }
  try {
    await res.close();
  } catch (_) {}
}

// ------------------------------------------------------------
// SSE（Server-Sent Events）
// ------------------------------------------------------------
class Sse {
  final HttpResponse res;

  /// 客户端断开 / 响应已彻底关闭：此后所有写入静默丢弃
  bool _closedOver = false;

  /// 已调用 done()，流结束
  bool _ended = false;

  /// 写入串行队列：保证 write/flush 严格按入队顺序执行。
  /// 并发 flush 同一个 HttpResponse 会互相等待（表现为思考链停在首包），
  /// 必须串行化。
  Future<void> _tail = Future<void>.value();
  final StringBuffer _pending = StringBuffer();
  Timer? _heartbeat;

  Sse(this.res) {
    // ★ 关键修复：SSE 响应必须关闭自动 gzip 压缩。
    // 开着 autoCompress 时 Dart 把字节塞进 gzip 编码器，编码器有内部缓冲，
    // 只有攒够一块才真正下发，前端于是只收到开头一小段 reasoning，
    // 之后「一直思考、思考链不再推进、始终不出回答」。
    // HttpResponse 无公开 autoCompress setter（仅 HttpServer 有），
    // 这里用 dynamic 兜底：部分 SDK 版本支持则直接关掉，
    // 不支持时由 HttpServer 层统一关闭（见 bin/main.dart）。
    try {
      (res as dynamic).autoCompress = false;
    } catch (_) {}
    res.statusCode = 200;
    res.headers.contentType =
        ContentType.parse('text/event-stream; charset=utf-8');
    res.headers.set('Cache-Control', 'no-cache, no-transform');
    res.headers.set('Connection', 'keep-alive');
    res.headers.set('X-Accel-Buffering', 'no');
    // 不缓存输出：每次 write 立刻走 socket
    res.bufferOutput = false;
    // 客户端断开时立即标记，避免后续写入已关闭的响应
    res.done.then<void>((_) {
      _closedOver = true;
    }).catchError((Object _) {
      _closedOver = true;
    });
    // 心跳：15 秒一个 SSE 注释帧，防止代理/前端把空闲连接判死
    _heartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_closedOver || _ended) return;
      _write(': ping\n\n');
    });
  }

  bool get isClosed => _closedOver || _ended;

  Future<void> send(String event, Object? payload) {
    if (_closedOver || _ended) return Future<void>.value();
    String data;
    try {
      data = jsonEncode(payload);
    } catch (_) {
      data = '{"error":"payload のシリアライズに失敗しました"}';
    }
    return _write('event: $event\ndata: $data\n\n');
  }

  Future<void> sendRaw(String chunk) {
    if (_closedOver || _ended) return Future<void>.value();
    return _write(chunk);
  }

  /// 入队写入；返回的 Future 在本批数据真正写完后完成。
  /// 任何异常只吞掉不外抛（SSE 回调多为 fire-and-forget，
  /// 抛出会成为未捕获异步异常并杀死进程）。
  Future<void> _write(String s) {
    if (_closedOver || _ended) return Future<void>.value();
    _pending.write(s);
    _tail = _tail.then<void>((_) => _drain()).catchError((Object _) {});
    return _tail;
  }

  Future<void> _drain() async {
    if (_closedOver) return;
    if (_pending.isEmpty) return;
    final data = _pending.toString();
    _pending.clear();
    try {
      res.write(data);
    } catch (_) {
      // write 抛异常才是真正的「响应已关闭」
      // （Bad state: StreamSink is bound to a stream）
      _closedOver = true;
      return;
    }
    try {
      await res.flush();
    } catch (_) {
      // flush 失败不判死：可能只是连接瞬态抖动。
      // 真断开由 res.done 与后续 write 异常兜底。
      // 之前此处一旦置 closed，就会把后续所有思考链/回答全部丢弃。
    }
  }

  Future<void> done() async {
    if (_ended) return;
    _ended = true;
    _heartbeat?.cancel();
    _heartbeat = null;
    try {
      await _tail;
    } catch (_) {}
    // 兜底：把残留数据刷出去
    if (!_closedOver && _pending.isNotEmpty) {
      final data = _pending.toString();
      _pending.clear();
      try {
        res.write(data);
      } catch (_) {
        _closedOver = true;
      }
    }
    if (!_closedOver) {
      try {
        await res.flush();
      } catch (_) {}
    }
    try {
      await res.close();
    } catch (_) {}
    _closedOver = true;
  }
}

// ------------------------------------------------------------
// 静态文件 MIME
// ------------------------------------------------------------
const Map<String, String> _mimeMap = {
  'html': 'text/html',
  'htm': 'text/html',
  'css': 'text/css',
  'js': 'text/javascript',
  'mjs': 'text/javascript',
  'json': 'application/json',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'svg': 'image/svg+xml',
  'webp': 'image/webp',
  'ico': 'image/x-icon',
  'woff': 'font/woff',
  'woff2': 'font/woff2',
  'ttf': 'font/ttf',
  'otf': 'font/otf',
  'wasm': 'application/wasm',
  'mp3': 'audio/mpeg',
  'wav': 'audio/wav',
  'mp4': 'video/mp4',
  'webm': 'video/webm',
  'pdf': 'application/pdf',
  'txt': 'text/plain',
  'md': 'text/markdown',
  'csv': 'text/csv',
  'xml': 'application/xml',
  'zip': 'application/zip',
  'gz': 'application/gzip',
  'tar': 'application/x-tar',
};

String mimeByExt(String name) {
  final i = name.lastIndexOf('.');
  if (i < 0 || i == name.length - 1) return 'application/octet-stream';
  return _mimeMap[name.substring(i + 1).toLowerCase()] ??
      'application/octet-stream';
}

// ------------------------------------------------------------
// 静态文件 + Range（等价 Go http.ServeFile/ServeContent）
// ------------------------------------------------------------
Future<void> serveFile(HttpRequest req, File file,
    {String? downloadName, bool attachment = false}) async {
  final res = req.response;
  if (!file.existsSync()) {
    await errJson(res, 404, '文件不存在');
    return;
  }
  final stat = file.statSync();
  final total = stat.size;
  final mime = mimeByExt(file.path);

  res.headers.set(HttpHeaders.contentTypeHeader, mime);
  res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
  if (downloadName != null) {
    final safe = downloadName
        .replaceAll('"', '')
        .replaceAll('\n', '')
        .replaceAll('\r', '');
    final dispo = attachment ? 'attachment' : 'inline';
    final isAscii = safe.codeUnits.every((c) => c < 128);
    if (isAscii) {
      // HTTP header 只能是 ASCII（Go 允许原始字节，Dart 严格校验）
      res.headers.set('content-disposition', '$dispo; filename="$safe"');
    } else {
      // RFC 5987：filename 用 ASCII 占位，filename* 给 UTF-8 真实名
      final fallback = String.fromCharCodes(
          safe.codeUnits.map((c) => c < 128 ? c : 0x5F));
      final encoded = Uri.encodeComponent(safe);
      res.headers.set('content-disposition',
          '$dispo; filename="$fallback"; filename*=UTF-8\'\'$encoded');
    }
  }

  // If-Modified-Since（秒级）
  final ims = req.headers.value(HttpHeaders.ifModifiedSinceHeader);
  if (ims != null && !_isRangeReq(req)) {
    try {
      final since = HttpDate.parse(ims);
      final mtime = stat.modified.toUtc();
      if (!mtime.isAfter(since.add(const Duration(seconds: 1)))) {
        res.statusCode = 304;
        await res.close();
        return;
      }
    } catch (_) {}
  }

  var start = 0;
  var end = total - 1;
  final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
  if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
    final spec = rangeHeader.substring(6).split(',').first.trim();
    final dash = spec.indexOf('-');
    if (dash >= 0) {
      final a = spec.substring(0, dash);
      final b = spec.substring(dash + 1);
      if (a.isEmpty) {
        final suffix = int.tryParse(b);
        if (suffix != null && suffix > 0) {
          start = total - suffix;
          if (start < 0) start = 0;
        }
      } else {
        final s = int.tryParse(a);
        if (s != null) start = s;
        if (b.isNotEmpty) {
          final e = int.tryParse(b);
          if (e != null) end = e;
        }
      }
      if (start < 0) start = 0;
      if (end >= total) end = total - 1;
      if (start > end || total == 0) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        await res.close();
        return;
      }
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
      res.headers.contentLength = end - start + 1;
    }
  } else {
    res.headers.contentLength = total;
  }

  if (req.method == 'HEAD' || total == 0) {
    await res.close();
    return;
  }

  try {
    final raf = await file.open();
    await raf.setPosition(start);
    final remain = end - start + 1;
    var sent = 0;
    const blockSize = 256 * 1024;
    while (sent < remain) {
      final want = (remain - sent) < blockSize ? (remain - sent) : blockSize;
      final chunk = await raf.read(want);
      if (chunk.isEmpty) break;
      res.add(chunk);
      sent += chunk.length;
    }
    await raf.close();
    await res.flush();
  } catch (e) {
    logp('⚠️ ファイル送信に失敗しました ${file.path}: $e');
  } finally {
    try {
      await res.close();
    } catch (_) {}
  }
}

bool _isRangeReq(HttpRequest req) =>
    req.headers.value(HttpHeaders.rangeHeader) != null;

/// 静态资源 handler（对齐 Go staticHandler：不存在则回退 index.html）
Future<void> serveStatic(HttpRequest req, String path) async {
  var rel = path;
  if (rel == '/') rel = '/index.html';
  final normalized = _safeJoin(BASE_DIR, rel);
  if (normalized == null) {
    await errJson(req.response, 403, '非法路径');
    return;
  }
  final f = File(normalized);
  if (!f.existsSync() || FileSystemEntity.isDirectorySync(normalized)) {
    await serveFile(req, File('$BASE_DIR/index.html'));
    return;
  }
  await serveFile(req, f);
}

/// 防目录穿越的路径拼接；越界返回 null
String? _safeJoin(String root, String rel) {
  final parts = <String>[];
  for (final seg in rel.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (parts.isNotEmpty) parts.removeLast();
      continue;
    }
    parts.add(seg);
  }
  final p = '$root/${parts.join('/')}';
  return p;
}
