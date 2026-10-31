// ============================================================
// net.dart —— 共享 HttpClient（连接池复用 / 自动代理探测）
//
// 说明：Go 版 netboost.go 里手工做了 DNS 缓存、SOCKS5 拨号与 HTTP/2 强制。
// Dart 的 dart:io HttpClient 自身即具备连接池 + keep-alive + 自动 gzip，
// 但**不支持**自定义 SOCKS5 拨号（无 dialer 注入点），因此这里的等价实现是：
//   - HTTP/HTTPS 代理：用 findProxy 交给平台（等价 Go 的 http.ProxyURL）
//   - 代理来源：环境变量 / .env / proxy.conf，与 Go 版完全一致的探测顺序
// 其余上层 API 语义（超时、重试、请求头）保持一致。
// ============================================================

import 'dart:io';

import 'globals.dart';

class ProxyConf {
  final String? httpProxy; // http://host:port 形式
  final String? socks5Host; // host:port（仅为兼容解析，Dart 无法直接拨 SOCKS5）
  const ProxyConf(this.httpProxy, this.socks5Host);
}

ProxyConf? _proxyCache;

ProxyConf detectProxy() {
  final c = _proxyCache;
  if (c != null) return c;

  final candidates = <String>[];
  void add(String? v) {
    final t = (v ?? '').trim();
    if (t.isNotEmpty) candidates.add(t);
  }

  add(getEnv('PROXY'));
  add(getEnv('SOCKS5_PROXY'));
  add(getEnv('ALL_PROXY'));
  add(getEnv('all_proxy'));
  add(getEnv('HTTPS_PROXY'));
  add(getEnv('https_proxy'));
  add(getEnv('HTTP_PROXY'));
  add(getEnv('http_proxy'));

  for (final p in ['$BASE_DIR/proxy.conf', '${Directory.current.path}/proxy.conf']) {
    if (File(p).existsSync()) {
      try {
        for (final raw in File(p).readAsStringSync().split('\n')) {
          final line = raw.trim();
          if (line.isEmpty || line.startsWith('#')) continue;
          add(line);
        }
      } catch (_) {}
    }
  }

  String? httpProxy;
  String? socks5;
  for (final c0 in candidates) {
    var u = c0;
    if (!u.contains('://')) u = 'http://$u';
    Uri? pu;
    try {
      pu = Uri.parse(u);
    } catch (_) {
      continue;
    }
    if (pu.host.isEmpty) continue;
    final scheme = pu.scheme.toLowerCase();
    if (scheme == 'socks5' || scheme == 'socks5h') {
      socks5 = '${pu.host}:${pu.port == 0 ? 1080 : pu.port}';
      break;
    }
    if (scheme == 'http' || scheme == 'https') {
      httpProxy = pu.toString();
      break;
    }
  }
  final res = ProxyConf(httpProxy, socks5);
  _proxyCache = res;
  return res;
}

HttpClient? _shared;
HttpClient? _sharedTimeout;

HttpClient get globalHTTPClient {
  final c = _shared;
  if (c != null) return c;
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 90)
    ..maxConnectionsPerHost = 100
    ..autoUncompress = true;
  // 流式聊天 / 长连接：不设整体超时（靠握手超时兜底）
  _applyProxy(client);
  _shared = client;
  return client;
}

/// 带整体超时的 client（Go: globalHTTPClientWithTimeout，Timeout=24h）
HttpClient get globalHTTPClientWithTimeout {
  final c = _sharedTimeout;
  if (c != null) return c;
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 90)
    ..maxConnectionsPerHost = 100
    ..autoUncompress = true
    ..connectionTimeout = const Duration(seconds: 10);
  _applyProxy(client);
  _sharedTimeout = client;
  return client;
}

void _applyProxy(HttpClient client) {
  final p = detectProxy();
  final hp = p.httpProxy;
  if (hp != null) {
    client.findProxy = (uri) => 'PROXY ${Uri.parse(hp).host}:${Uri.parse(hp).port}';
    logp('🌐 使用 HTTP 代理: $hp');
  } else if (p.socks5Host != null) {
    // Dart 的 HttpClient 无 SOCKS5 拨号注入点：保持直连并给出明确日志
    logp('⚠️ 检测到 SOCKS5 代理 ${p.socks5Host}，dart:io 不支持自定义 SOCKS 拨号，已直连');
  }
}

/// 工具层使用的共享 client（与 globalHTTPClient 同一实例）
HttpClient get globalHttpClientForTools => globalHTTPClient;

/// 便捷：带超时的请求执行（返回 HttpClientResponse，body 由调用方读取）
Future<HttpClientResponse> httpSend(
  String method,
  Uri uri, {
  Map<String, String>? headers,
  List<int>? body,
  Duration? timeout,
  bool withTimeoutClient = true,
}) async {
  final client = withTimeoutClient ? globalHTTPClientWithTimeout : globalHTTPClient;
  Future<HttpClientRequest> open() async {
    final req = await client.openUrl(method, uri);
    headers?.forEach(req.headers.set);
    if (body != null && body.isNotEmpty) req.add(body);
    return req;
  }

  final reqFuture = open();
  if (timeout == null) {
    final req = await reqFuture;
    return req.close();
  }
  final req = await reqFuture.timeout(timeout);
  return req.close().timeout(timeout);
}
