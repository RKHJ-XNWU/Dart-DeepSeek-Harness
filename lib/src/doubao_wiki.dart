// ============================================================
// doubao_wiki.dart —— 豆包「联网内容插件」接入（抖音百科等信源）
//
// 为什么必须单独走 Responses API：
//   火山方舟文档（docs.volcengine.com/docs/82379/1756990）明确：
//     1) 抖音百科（sources: ["douyin"]）属于「联网内容插件」，
//        该插件 **仅支持 Responses API**，Chat Completions 不支持；
//     2) Chat API 的 web_search_options 只能启用「豆包搜索 Custom 版」，
//        且 sources 只能是 ["doubao"]，无法指定 douyin；
//     3) doubao 不能与 douyin / toutiao / moji / search_engine 同时配置。
//   因此要拿到抖音百科信源，唯一合规路径是 /api/v3/responses。
//
// 生效范围：
//   仅豆包模式（方舟通道）且用户显式开启信源开关时启用；
//   DeepSeek 通道完全不经过本文件。
// ============================================================

import 'dart:async';
import 'dart:convert';

import 'deepseek_api.dart';
import 'ds_usage.dart';
import 'globals.dart';
import 'net.dart';

/// 允许的信源白名单（来自方舟文档「设置搜索来源」一节）
const List<String> dbWikiAllowedSources = <String>[
  'douyin', // 抖音百科
  'toutiao', // 头条图文
  'moji', // 墨迹天气
  'search_engine', // 全网检索（默认搜索，每月免费两万额度）
];

/// 规整信源列表：去空、去重、只保留白名单内的值。
/// 文档硬约束：'doubao' 不能与其它来源混用，故此处直接剔除 'doubao'。
List<String> dbWikiNormalizeSources(Iterable<String> raw) {
  final out = <String>[];
  for (final s in raw) {
    final v = s.trim().toLowerCase();
    if (v.isEmpty) continue;
    if (v == 'doubao') continue; // 与插件信源互斥，交由 Chat API 通道处理
    if (!dbWikiAllowedSources.contains(v)) continue;
    if (out.contains(v)) continue;
    out.add(v);
  }
  return out;
}

/// Responses API 端点
String dbWikiEndpoint(String baseUrl) {
  var b = baseUrl.trim();
  if (b.isEmpty) b = 'https://ark.cn-beijing.volces.com/api/v3';
  while (b.endsWith('/')) {
    b = b.substring(0, b.length - 1);
  }
  return '$b/responses';
}

/// 判断这批 Chat 风格媒体片段能否在 Responses API 通道里原样使用。
///
/// 现状：
///   · image_url（图片）→ 支持，转成 input_image 后可与 web_search 并存；
///   · input_audio / video_url（音频、视频）→ Responses 的「联网内容插件」
///     通道不保证支持，若强行提交只能二选一：要么丢媒体、要么报错。
///     所以只要出现非图片片段，调用方应回退到原生多模态（Chat API）通道，
///     宁可不接百科，也不能让模型看不见媒体还硬答。
bool dbWikiMediaSupported(Iterable<Map<String, dynamic>> parts) {
  for (final p in parts) {
    final t = (p['type'] ?? '').toString();
    if (t == 'image_url') continue; // 支持
    return false; // 音频 / 视频等一律不支持
  }
  return true;
}

/// 把 Chat 风格的媒体片段转成 Responses API 的 input 片段。
///
/// 差异点（容易踩坑）：
///   Chat API   : {type:'image_url', image_url:{url:'data:...'}}
///   Responses  : {type:'input_image', image_url:'data:...'}
///                        ↑ image_url 是**字符串**，不是对象
List<Map<String, dynamic>> dbWikiMediaToInput(
    Iterable<Map<String, dynamic>> parts) {
  final out = <Map<String, dynamic>>[];
  for (final p in parts) {
    final t = (p['type'] ?? '').toString();
    if (t != 'image_url') continue;
    final img = p['image_url'];
    String url = '';
    if (img is Map) {
      url = '${img['url'] ?? ''}';
    } else if (img is String) {
      url = img;
    }
    if (url.isEmpty) continue;
    out.add({'type': 'input_image', 'image_url': url});
  }
  return out;
}

/// 把 Chat Completions 风格的 messages 转成 Responses API 的
/// `instructions` + `input` 结构。
///
/// · system → instructions（多条时用换行拼接）
/// · user   → {type: "message", role: user, content: [{type: input_text, text}]}
/// · assistant → {type: "message", role: assistant, content: [{type: output_text, text}]}
({String instructions, List<Map<String, dynamic>> input})
    dbWikiBuildInput(
  List<Map<String, dynamic>> messages, {
  /// 需要与「最后一条 user 消息」一起提交的图片片段（已转成 Responses 格式）
  List<Map<String, dynamic>> mediaParts = const <Map<String, dynamic>>[],
}) {
  final sys = <String>[];
  final input = <Map<String, dynamic>>[];
  for (final m in messages) {
    final role = (m['role'] ?? '').toString();
    final rawContent = m['content'];
    // 多模态内容（图片/音频）本通道不支持，只取其中的文本片段
    var text = '';
    if (rawContent is String) {
      text = rawContent;
    } else if (rawContent is List) {
      final buf = <String>[];
      for (final part in rawContent) {
        if (part is Map && (part['type'] == 'text' || part['type'] == 'input_text')) {
          buf.add('${part['text'] ?? ''}');
        }
      }
      text = buf.join('\n');
    }
    if (text.trim().isEmpty) continue;

    if (role == 'system') {
      sys.add(text);
      continue;
    }
    if (role == 'assistant') {
      input.add({
        'type': 'message',
        'role': 'assistant',
        'content': [
          {'type': 'output_text', 'text': text},
        ],
      });
      continue;
    }
    input.add({
      'type': 'message',
      'role': 'user',
      'content': <Map<String, dynamic>>[
        {'type': 'input_text', 'text': text},
      ],
    });
  }

  // 图片与「最后一条 user 消息」合并提交：这样模型的视野里
  // 「这张图」与「围绕这张图的问题」是同一轮的，不会错位到更早的对话。
  if (mediaParts.isNotEmpty) {
    var idx = -1;
    for (var i = input.length - 1; i >= 0; i--) {
      if ((input[i]['role'] ?? '').toString() == 'user') {
        idx = i;
        break;
      }
    }
    if (idx >= 0) {
      final cs = input[idx]['content'];
      if (cs is List) cs.addAll(mediaParts);
    } else {
      // 整个历史里只有 system、没有 user（极少见）：单独补一条
      input.add({
        'type': 'message',
        'role': 'user',
        'content': <Map<String, dynamic>>[
          {'type': 'input_text', 'text': ''},
          ...mediaParts,
        ],
      });
    }
  }
  return (instructions: sys.join('\n\n'), input: input);
}

/// 从 Responses API 的 output item 里抽取联网引用（url_citation）。
///
/// 方舟把引用放在 `output_text.content[].annotations`
/// （{type:'url_citation', url, title, ...}）；部分网关改放在
/// item['results'] 或 item['action']['sources'] 里。三者全部兼容，
/// 统一交给 [dsExtractReferences] 归一化。
List<Map<String, dynamic>> dbWikiCitationsOfItem(Map<dynamic, dynamic> item) {
  final out = <Map<String, dynamic>>[];
  void take(Object? raw) {
    out.addAll(dsExtractReferences(raw));
  }

  final cs = item['content'];
  if (cs is List) {
    for (final c in cs) {
      if (c is! Map) continue;
      take(c['annotations']);
    }
  }
  take(item['results']);
  final act = item['action'];
  if (act is Map) {
    take(act['sources']);
    take(act['results']);
  }
  return out;
}

/// 通过 Responses API 发起流式请求，并接入联网内容插件信源。
///
/// 回调语义与 [callDsMultiRoundStream] 保持一致：
///   onReasoning → 思考过程片段
///   onContent   → 正文片段
Future<void> callDbWikiResponsesStream(
  String apiKey,
  String model,
  List<Map<String, dynamic>> messages,
  int maxTokens,
  List<String> sources,
  void Function(String s) onReasoning,
  void Function(String s) onContent, {
  DsUsageAcc? usageAcc,
  String baseUrl = '',

  /// 与最后一条 user 消息一同提交的图片（Chat 风格片段，内部自动转码）
  List<Map<String, dynamic>> mediaParts = const <Map<String, dynamic>>[],

  /// 联网引用（交互式卡片数据源）：流结束前回调一次
  void Function(List<Map<String, dynamic>> sources)? onSources,
}) async {
  final src = dbWikiNormalizeSources(sources);
  if (src.isEmpty) {
    throw Exception('未选择任何有效的联网内容插件信源');
  }

  final wikiMedia = dbWikiMediaToInput(mediaParts);
  final built = dbWikiBuildInput(messages, mediaParts: wikiMedia);
  if (built.input.isEmpty) {
    throw Exception('输入内容为空');
  }
  if (mediaParts.isNotEmpty) {
    logp('🖼️ 联网内容插件：附帯画像 ${wikiMedia.length} 枚を input_image として送信');
  }

  var mt = maxTokens;
  if (mt <= 0) mt = 8192;
  if (mt > 120000) mt = 120000;

  final body = <String, dynamic>{
    'model': model,
    'stream': true,
    'input': built.input,
    'tools': [
      {
        'type': 'web_search',
        'sources': src,
      }
    ],
    'max_output_tokens': mt,
  };
  if (built.instructions.isNotEmpty) {
    body['instructions'] = built.instructions;
  }

  final url = dbWikiEndpoint(baseUrl);
  logp('🌐 豆包联网内容插件：$url（信源=${src.join(",")}）');

  final client = globalHTTPClient;
  final req = await client.postUrl(Uri.parse(url));
  req.headers.set('Content-Type', 'application/json');
  req.headers.set('Authorization', 'Bearer $apiKey');
  req.headers.set('Accept', 'text/event-stream');
  // ★ 上流圧縮の無効化（思考チェーンが数フレーム分まとめて届くのを防ぐ）
  req.headers.set('Accept-Encoding', 'identity');
  req.add(utf8.encode(jsonEncode(body)));

  final resp = await req.close();
  if (resp.statusCode != 200) {
    final txt = utf8
        .decode(await resp.fold<List<int>>([], (a, b) => a..addAll(b)));
    logp('❌ Responses API HTTP ${resp.statusCode}: $txt');
    String msg = txt;
    try {
      final j = jsonDecode(txt);
      if (j is Map && j['error'] is Map) {
        final e = j['error'] as Map;
        final m = '${e['message'] ?? ''}';
        if (m.isNotEmpty) msg = m;
      }
    } catch (_) {}
    throw Exception('豆包联网内容插件请求失败（HTTP ${resp.statusCode}）：$msg');
  }

  final errBuf = StringBuffer();
  var lastEvent = '';
  var gotDelta = false;

  await for (final line
      in resp.transform(utf8.decoder).transform(const LineSplitter())) {
    final t = line.trim();
    if (t.isEmpty) continue;
    if (t.startsWith(':')) continue; // SSE 注释 / 心跳
    if (t.startsWith('event:')) {
      // 方舟部分网关把事件类型只放在 event: 行，data 里无 type，
      // 这里先记下，作为 data 缺 type 时的兜底。
      lastEvent = t.substring(6).trim();
      continue;
    }
    if (!t.startsWith('data:')) continue;

    final payload = t.substring(5).trim();
    if (payload.isEmpty) continue;
    if (payload == '[DONE]') break;

    Map<String, dynamic> ev;
    try {
      final j = jsonDecode(payload);
      if (j is! Map<String, dynamic>) continue;
      ev = j;
    } catch (_) {
      continue;
    }

    var type = (ev['type'] ?? '').toString();
    if (type.isEmpty) type = lastEvent;

    // ---- 正文增量 ----
    if (type == 'response.output_text.delta' ||
        type == 'response.output_text.done') {
      final d = (ev['delta'] ?? '').toString();
      if (type.endsWith('.delta') && d.isNotEmpty) {
        gotDelta = true;
        onContent(d);
      }
      continue;
    }

    // ---- 思考过程增量 ----
    if (type == 'response.reasoning_summary_text.delta' ||
        type == 'response.reasoning_text.delta') {
      final d = (ev['delta'] ?? '').toString();
      if (d.isNotEmpty) onReasoning(d);
      continue;
    }

    // ---- 联网搜索状态 ----
    if (type == 'response.web_search_call.in_progress' ||
        type == 'response.web_search_call.searching') {
      logp('🔎 联网内容插件：正在检索…');
      continue;
    }
    if (type == 'response.web_search_call.completed') {
      logp('✅ 联网内容插件：检索完成');
      continue;
    }

    // ---- 工具调用出现（兼容 output_item.added 形态）----
    if (type == 'response.output_item.added') {
      final item = ev['item'];
      if (item is Map && (item['type'] ?? '').toString() == 'web_search_call') {
        logp('🔎 联网内容插件：已发起检索');
      }
      continue;
    }

    // ---- 用量 ----
    if (type == 'response.completed' || type == 'response.incomplete') {
      final r = ev['response'];
      // ★ 联网引用（url_citation）→ 前端交互式卡片
      if (onSources != null && r is Map) {
        final acc = <String, Map<String, dynamic>>{};
        final outItems = r['output'];
        if (outItems is List) {
          for (final it in outItems) {
            if (it is! Map) continue;
            for (final c in dbWikiCitationsOfItem(it)) {
              acc['${c['url']}'] = c;
            }
          }
        }
        if (acc.isNotEmpty) onSources(acc.values.toList());
      }
      if (r is Map && usageAcc != null) {
        final u = r['usage'];
        if (u is Map) {
          final inTok = _asInt(u['input_tokens']);
          final outTok = _asInt(u['output_tokens']);
          final total = _asInt(u['total_tokens']);
          var cached = 0;
          final det = u['input_tokens_details'];
          if (det is Map) cached = _asInt(det['cached_tokens']);
          usageAcc.addRaw(RawDsUsage(
            promptTokens: inTok,
            completionTokens: outTok,
            totalTokens: total < inTok + outTok ? inTok + outTok : total,
            cachedTokens: cached,
          ));
        }
      }
      final r2 = ev['response'];
      if (!gotDelta && r2 is Map) {
        // 兜底：部分网关不退增量，只在此刻给完整 output
        final out = r2['output'];
        if (out is List) {
          final buf = StringBuffer();
          for (final item in out) {
            if (item is! Map) continue;
            if ((item['type'] ?? '').toString() != 'message') continue;
            final cs = item['content'];
            if (cs is! List) continue;
            for (final c in cs) {
              if (c is! Map) continue;
              final ct = (c['type'] ?? '').toString();
              if (ct == 'output_text' || ct == 'text') {
                buf.write('${c['text'] ?? ''}');
              }
            }
          }
          if (buf.isNotEmpty) {
            gotDelta = true;
            onContent(buf.toString());
          }
        }
      }
      if (r2 is Map) {
        final toolUse = r2['tool_usage'];
        if (toolUse is Map) {
          final ws = _asInt(toolUse['web_search']);
          if (ws > 0) logp('📊 本次联网检索次数：$ws');
        }
      }
      continue;
    }

    // ---- 失败 ----
    if (type == 'response.failed' || type == 'error') {
      final r = ev['response'];
      String msg = '';
      if (r is Map && r['error'] is Map) {
        msg = '${(r['error'] as Map)['message'] ?? ''}';
      }
      if (msg.isEmpty && ev['error'] is Map) {
        msg = '${(ev['error'] as Map)['message'] ?? ''}';
      }
      if (msg.isEmpty) msg = '${ev['message'] ?? ''}';
      if (msg.isEmpty) msg = '联网内容插件返回失败';
      errBuf.write(msg);
      continue;
    }
  }

  if (errBuf.isNotEmpty) {
    throw Exception(errBuf.toString());
  }
}

int _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}


// ============================================================
// 工具模式 × 联网内容插件：同一请求内混用 web_search 与 function
//
// 方舟客服确认：Responses API 的 `tools` 数组可同时包含
//   {"type":"web_search","sources":["douyin"]}
//   {"type":"function","name":"...","parameters":{...}}
// 由模型自动判断调用哪个工具。
//
// 与 Chat Completions 的三处关键差异（照抄会 400）：
//   1) function 定义是「平铺」的，没有外层 function 包裹；
//   2) 调用结果不是 role:'tool' 消息，而是
//      {"type":"function_call_output","call_id":"..","output":".."} 输入项；
//   3) 无状态多轮必须把上一轮输出的 item 原样塞回 input。
// ============================================================

/// 工具混用通道的执行结果，字段与 [ToolStreamOutcome] 对齐，
/// 便于上层落库逻辑完全复用。
class DbWikiToolOutcome {
  final String content;
  final String reasoning;
  final List<String> toolLogs;
  const DbWikiToolOutcome(this.content, this.reasoning, this.toolLogs);
}

/// 把 Chat Completions 风格的 function 工具定义转成 Responses API 格式。
///
/// Chat      : {type:'function', function:{name, description, parameters}}
/// Responses : {type:'function', name, description, parameters}
List<Map<String, dynamic>> dbWikiToolsFromChat(
    Iterable<Map<String, dynamic>> chatTools) {
  final out = <Map<String, dynamic>>[];
  for (final t in chatTools) {
    if ((t['type'] ?? '').toString() != 'function') continue;
    final fn = t['function'];
    if (fn is! Map) continue;
    final name = '${fn['name'] ?? ''}'.trim();
    if (name.isEmpty) continue;
    final item = <String, dynamic>{'type': 'function', 'name': name};
    final desc = fn['description'];
    if (desc is String && desc.isNotEmpty) item['description'] = desc;
    final params = fn['parameters'];
    if (params is Map) item['parameters'] = params;
    out.add(item);
  }
  return out;
}

/// 单轮 Responses 流式调用结果
class DbWikiRound {
  final String content;
  final String reasoning;

  /// 模型本轮输出、需要原样回传的 item（已清洗为最小字段集）
  final List<Map<String, dynamic>> items;

  /// 本轮需要执行的函数调用
  final List<Map<String, dynamic>> calls;

  /// 本轮联网检索次数（仅用于日志）
  final int searchCount;

  const DbWikiRound(
      this.content, this.reasoning, this.items, this.calls, this.searchCount);
}

/// 从 output item 里抽出纯文本
String _dbWikiTextOfMessage(Map<dynamic, dynamic> item) {
  final cs = item['content'];
  if (cs is! List) return '';
  final buf = StringBuffer();
  for (final c in cs) {
    if (c is! Map) continue;
    final ct = (c['type'] ?? '').toString();
    if (ct == 'output_text' || ct == 'input_text' || ct == 'text') {
      buf.write('${c['text'] ?? ''}');
    }
  }
  return buf.toString();
}

/// 把模型输出的 item 清洗成「可安全回传」的最小结构。
///
/// 原样回传在多数网关可行，但部分实现会因多出的 status / annotations /
/// encrypted_content 等字段报 400，因此这里只保留必要字段。
Map<String, dynamic>? _dbWikiSanitizeItem(Map<dynamic, dynamic> raw) {
  final type = (raw['type'] ?? '').toString();
  if (type == 'function_call') {
    final name = (raw['name'] ?? '').toString();
    final callId = (raw['call_id'] ?? '').toString();
    if (name.isEmpty || callId.isEmpty) return null;
    return {
      'type': 'function_call',
      'call_id': callId,
      'name': name,
      'arguments': (raw['arguments'] ?? '').toString(),
    };
  }
  if (type == 'message') {
    final text = _dbWikiTextOfMessage(raw);
    if (text.trim().isEmpty) return null; // 空 message 回传会被拒
    return {
      'type': 'message',
      'role': 'assistant',
      'content': [
        {'type': 'output_text', 'text': text},
      ],
    };
  }
  // reasoning / web_search_call 等不回传：
  //   · reasoning 需要 encrypted_content，缺了会 400；
  //   · web_search_call 由服务端持有，无需客户端回传。
  return null;
}

/// 发起一轮 Responses 流式请求（带 tools）
Future<DbWikiRound> _dbWikiStreamRound({
  required String apiKey,
  required String model,
  required List<Map<String, dynamic>> input,
  required String instructions,
  required int maxTokens,
  required List<Map<String, dynamic>> tools,
  void Function(String)? onContent,
  void Function(String)? onReasoning,
  DsUsageAcc? usageAcc,
  String baseUrl = '',
  void Function(List<Map<String, dynamic>> sources)? onSources,
}) async {
  var mt = maxTokens;
  if (mt <= 0) mt = 8192;
  if (mt > 120000) mt = 120000;

  final body = <String, dynamic>{
    'model': model,
    'stream': true,
    'input': input,
    'tools': tools,
    'max_output_tokens': mt,
  };
  if (instructions.isNotEmpty) body['instructions'] = instructions;

  final url = dbWikiEndpoint(baseUrl);
  final client = globalHTTPClient;
  final req = await client.postUrl(Uri.parse(url));
  req.headers.set('Content-Type', 'application/json');
  req.headers.set('Authorization', 'Bearer $apiKey');
  req.headers.set('Accept', 'text/event-stream');
  // ★ 上流圧縮の無効化（思考チェーンが数フレーム分まとめて届くのを防ぐ）
  req.headers.set('Accept-Encoding', 'identity');
  req.add(utf8.encode(jsonEncode(body)));

  final resp = await req.close();
  if (resp.statusCode != 200) {
    final txt =
        utf8.decode(await resp.fold<List<int>>([], (a, b) => a..addAll(b)),
            allowMalformed: true);
    logp('❌ Responses API（工具混用）HTTP ${resp.statusCode}: $txt');
    String msg = txt;
    try {
      final j = jsonDecode(txt);
      if (j is Map && j['error'] is Map) {
        final m = '${(j['error'] as Map)['message'] ?? ''}';
        if (m.isNotEmpty) msg = m;
      }
    } catch (_) {}
    throw Exception('豆包联网内容插件请求失败（HTTP ${resp.statusCode}）：$msg');
  }

  final contentBuf = StringBuffer();
  final reasoningBuf = StringBuffer();
  final rawItems = <Map<String, dynamic>>[];
  final doneCalls = <Map<String, dynamic>>[];
  final errBuf = StringBuffer();
  var lastEvent = '';
  var searchCount = 0;
  var sawCompleted = false;

  await for (final line
      in resp.transform(utf8.decoder).transform(const LineSplitter())) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith(':')) continue;
    if (t.startsWith('event:')) {
      lastEvent = t.substring(6).trim();
      continue;
    }
    if (!t.startsWith('data:')) continue;
    final payload = t.substring(5).trim();
    if (payload.isEmpty) continue;
    if (payload == '[DONE]') break;

    Map<String, dynamic> ev;
    try {
      final j = jsonDecode(payload);
      if (j is! Map<String, dynamic>) continue;
      ev = j;
    } catch (_) {
      continue;
    }

    var type = (ev['type'] ?? '').toString();
    if (type.isEmpty) type = lastEvent;

    // ---- 正文增量 ----
    if (type == 'response.output_text.delta') {
      final d = (ev['delta'] ?? '').toString();
      if (d.isNotEmpty) {
        contentBuf.write(d);
        onContent?.call(d);
      }
      continue;
    }

    // ---- 思考增量 ----
    if (type == 'response.reasoning_summary_text.delta' ||
        type == 'response.reasoning_text.delta') {
      final d = (ev['delta'] ?? '').toString();
      if (d.isNotEmpty) {
        reasoningBuf.write(d);
        onReasoning?.call(d);
      }
      continue;
    }

    // ---- 联网检索状态 ----
    if (type.startsWith('response.web_search_call.')) {
      if (type == 'response.web_search_call.searching') {
        logp('🔎 联网内容插件：正在检索…');
      } else if (type == 'response.web_search_call.completed') {
        searchCount++;
        logp('✅ 联网内容插件：检索完成');
      }
      continue;
    }

    // ---- 单个输出项完成 ----
    if (type == 'response.output_item.done') {
      final item = ev['item'];
      if (item is Map) {
        final it = Map<String, dynamic>.from(item);
        final itType = (it['type'] ?? '').toString();
        if (itType == 'function_call') {
          doneCalls.add(it);
        } else if (itType == 'message' && contentBuf.isEmpty) {
          // 网关未退增量时，从完整 item 兜底取正文
          final txt = _dbWikiTextOfMessage(it);
          if (txt.isNotEmpty) {
            contentBuf.write(txt);
            onContent?.call(txt);
          }
        }
      }
      continue;
    }

    // ---- 整轮完成 ----
    if (type == 'response.completed' || type == 'response.incomplete') {
      sawCompleted = true;
      final r = ev['response'];
      // ★ 联网引用（url_citation）→ 前端交互式卡片（工具模式同样上报）
      if (onSources != null && r is Map) {
        final acc = <String, Map<String, dynamic>>{};
        final citList = r['output'];
        if (citList is List) {
          for (final it in citList) {
            if (it is! Map) continue;
            for (final c in dbWikiCitationsOfItem(it)) {
              acc['${c['url']}'] = c;
            }
          }
        }
        if (acc.isNotEmpty) onSources(acc.values.toList());
      }
      if (r is Map) {
        final out = r['output'];
        if (out is List) {
          for (final item in out) {
            if (item is! Map) continue;
            final it = Map<String, dynamic>.from(item);
            final itType = (it['type'] ?? '').toString();
            if (itType == 'web_search_call') searchCount++;
            if (itType == 'message' || itType == 'function_call') {
              rawItems.add(it);
            }
          }
        }
        if (usageAcc != null) {
          final u = r['usage'];
          if (u is Map) {
            final inTok = _asInt(u['input_tokens']);
            final outTok = _asInt(u['output_tokens']);
            final total = _asInt(u['total_tokens']);
            var cached = 0;
            final det = u['input_tokens_details'];
            if (det is Map) cached = _asInt(det['cached_tokens']);
            usageAcc.addRaw(RawDsUsage(
              promptTokens: inTok,
              completionTokens: outTok,
              totalTokens: total < inTok + outTok ? inTok + outTok : total,
              cachedTokens: cached,
            ));
          }
        }
        // 兜底：既没增量、也没 item 正文时，从 output 里拼
        if (contentBuf.isEmpty) {
          final buf = StringBuffer();
          for (final it in rawItems) {
            if ((it['type'] ?? '').toString() != 'message') continue;
            buf.write(_dbWikiTextOfMessage(it));
          }
          if (buf.isNotEmpty) {
            contentBuf.write(buf);
            onContent?.call(buf.toString());
          }
        }
      }
      continue;
    }

    // ---- 失败 ----
    if (type == 'response.failed' || type == 'error') {
      final r = ev['response'];
      String msg = '';
      if (r is Map && r['error'] is Map) {
        msg = '${(r['error'] as Map)['message'] ?? ''}';
      }
      if (msg.isEmpty && ev['error'] is Map) {
        msg = '${(ev['error'] as Map)['message'] ?? ''}';
      }
      if (msg.isEmpty) msg = '${ev['message'] ?? ''}';
      if (msg.isEmpty) msg = '联网内容插件返回失败';
      errBuf.write(msg);
      continue;
    }
  }

  if (errBuf.isNotEmpty) throw Exception(errBuf.toString());
  if (!sawCompleted) {
    logp('⚠️ Responses API 未收到 response.completed，可能被中断');
  }

  // completed 未给 output 时，用 output_item.done 收集到的补齐
  if (rawItems.isEmpty && doneCalls.isNotEmpty) rawItems.addAll(doneCalls);

  final items = <Map<String, dynamic>>[];
  final calls = <Map<String, dynamic>>[];
  for (final raw in rawItems) {
    final s = _dbWikiSanitizeItem(raw);
    if (s == null) continue;
    final isDup = items.any((x) =>
        (x['type'] == s['type']) &&
        ((x['call_id'] ?? '') == (s['call_id'] ?? '')) &&
        ((x['call_id'] ?? '').toString().isNotEmpty ||
            _dbWikiTextOfMessage(x) == _dbWikiTextOfMessage(s)));
    if (!isDup) items.add(s);
    if (s['type'] == 'function_call') calls.add(s);
  }

  return DbWikiRound(contentBuf.toString(), reasoningBuf.toString(), items,
      calls, searchCount);
}

/// 工具模式 × 联网内容插件：多轮循环入口。
///
/// 请求内同时挂载 `web_search`（联网内容插件信源）与自定义 function 工具，
/// 由模型自行决定调用哪一个；每轮把上一轮输出的 item 原样回传，实现无状态多轮。
Future<DbWikiToolOutcome> callDbWikiWithToolsStream(
  String apiKey,
  String model,
  List<Map<String, dynamic>> messages,
  int maxTokens,
  List<String> sources,
  int maxIterations,
  void Function(String)? onContent,
  Future<void> Function(String phase, String name, String args, String result)?
      onToolCall,
  void Function(String)? onReasoning,
  DsUsageAcc? usageAcc, {
  String baseUrl = '',
  List<Map<String, dynamic>> mediaParts = const <Map<String, dynamic>>[],
  void Function(List<Map<String, dynamic>> sources)? onSources,
}) async {
  final src = dbWikiNormalizeSources(sources);
  if (src.isEmpty) throw Exception('未选择任何有效的联网内容插件信源');

  final wikiMedia = dbWikiMediaToInput(mediaParts);
  final built = dbWikiBuildInput(messages, mediaParts: wikiMedia);
  if (built.input.isEmpty) throw Exception('输入内容为空');
  if (wikiMedia.isNotEmpty) {
    logp('🖼️ 工具混用：附帯画像 ${wikiMedia.length} 枚を input_image として送信');
  }

  // 这里只需要「非 DeepSeek 通道」这一信息，故直接传 ark 标记，
  // 避免在 doubao_wiki 里反向依赖 doubao.dart（会造成循环 import）。
  final fnTools = dbWikiToolsFromChat(dsResolveTools(model, 'ark'));
  final tools = <Map<String, dynamic>>[
    {'type': 'web_search', 'sources': src},
    ...fnTools,
  ];
  logp('🔧🌐 ツール混用モード: web_search(${src.join(",")}) + function ${fnTools.length} 個');

  final input = <Map<String, dynamic>>[...built.input];
  final allContent = StringBuffer();
  final allReasoning = StringBuffer();
  final toolLogs = <String>[];

  final maxIter = maxIterations <= 0 ? 5000000000 : maxIterations;

  for (var iter = 0; iter < maxIter; iter++) {
    final r = await _dbWikiStreamRound(
      apiKey: apiKey,
      model: model,
      input: input,
      instructions: built.instructions,
      maxTokens: maxTokens,
      tools: tools,
      onContent: onContent,
      onReasoning: onReasoning,
      usageAcc: usageAcc,
      baseUrl: baseUrl,
      onSources: onSources,
    );

    allContent.write(r.content);
    if (r.reasoning.isNotEmpty) allReasoning.write(r.reasoning);

    if (r.calls.isEmpty) {
      return DbWikiToolOutcome(
          allContent.toString(), allReasoning.toString(), toolLogs);
    }

    // 把本轮模型输出（message / function_call）原样回传，模型才知道
    // 自己刚调用了什么；否则下一轮会重复调用同一个工具。
    input.addAll(r.items);

    for (final c in r.calls) {
      final name = (c['name'] ?? '').toString();
      final args = (c['arguments'] ?? '').toString();
      final callId = (c['call_id'] ?? '').toString();

      await onToolCall?.call('start', name, args, '');
      final result = await dsSafeExecTool(name, args);
      await onToolCall?.call('end', name, args, result);

      final logLine = '🔧 ツール呼び出し: $name\n'
          '参数: ${truncateRunes(args, 60000)}\n'
          '結果: ${truncateRunes(result, 120000)}\n';
      toolLogs.add(logLine);
      allReasoning.write(logLine);
      allReasoning.write('\n');

      input.add({
        'type': 'function_call_output',
        'call_id': callId,
        'output': result,
      });
    }

  }

  return DbWikiToolOutcome(
      allContent.toString(), allReasoning.toString(), toolLogs);
}
