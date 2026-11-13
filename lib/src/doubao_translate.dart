// ============================================================
// doubao_translate.dart —— 火山引擎机器翻译大模型 & 本地术语表管理
//   接口：POST https://openspeech.bytedance.com/api/v3/machine_translation/matx_translate
//   文档：https://docs.volcengine.com/docs/doubao-voice/machine-translation-large-model-api-access-documentation
//
//   术语表本地存储：
//     目录：$BASE_DIR/data/body_text
//     格式：每行一条记录，字段用 | 分隔
//     字段：term_id|source_term|target_term|source_lang|target_lang
//     （source_lang / target_lang 可用于按语言对筛选术语，留空表示通用）
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'globals.dart';
import 'httpsrv.dart';
import 'doubao.dart'; // 引入 dbErrText

// ------------------------------------------------------------
// 常量
// ------------------------------------------------------------
const String DB_TRANSLATE_URL =
    'https://openspeech.bytedance.com/api/v3/machine_translation/matx_translate';
const String DB_TRANSLATE_RESOURCE_ID = 'volc.speech.mt';

String get DB_GLOSSARY_DIR => '$BASE_DIR/data/body_text';

// ------------------------------------------------------------
// 术语表数据模型
// ------------------------------------------------------------
class GlossaryEntry {
  final String id;
  final String source;
  final String target;
  final String sourceLang;
  final String targetLang;

  GlossaryEntry({
    required this.id,
    required this.source,
    required this.target,
    this.sourceLang = '',
    this.targetLang = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'source': source,
        'target': target,
        'sourceLang': sourceLang,
        'targetLang': targetLang,
      };

  /// 序列化为 .sts 的一行：id|source|target|sourceLang|targetLang
  String toStsLine() {
    return '$id|${escF(source)}|${escF(target)}|${escF(sourceLang)}|${escF(targetLang)}';
  }

  /// 从 .sts 一行反序列化
  static GlossaryEntry? fromStsLine(String line) {
    final parts = line.split('|');
    if (parts.length < 3) return null;
    return GlossaryEntry(
      id: parts[0],
      source: unescF(parts[1]),
      target: unescF(parts[2]),
      sourceLang: parts.length > 3 ? unescF(parts[3]) : '',
      targetLang: parts.length > 4 ? unescF(parts[4]) : '',
    );
  }
}

// ------------------------------------------------------------
// 术语表 CRUD
// ------------------------------------------------------------
void ensureGlossaryDir() {
  ensureDir(DB_GLOSSARY_DIR);
}

/// 列出所有术语表文件（返回文件名不含 .sts 后缀）
List<String> listGlossaryTables() {
  ensureGlossaryDir();
  final dir = Directory(DB_GLOSSARY_DIR);
  if (!dir.existsSync()) return [];
  return dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.sts'))
      .map((f) => f.uri.pathSegments.last.replaceAll('.sts', ''))
      .toList()
    ..sort();
}

/// 读取指定术语表的所有条目
List<GlossaryEntry> loadGlossary(String tableName) {
  ensureGlossaryDir();
  final f = File('$DB_GLOSSARY_DIR/$tableName.sts');
  if (!f.existsSync()) return [];
  final entries = <GlossaryEntry>[];
  for (final line in f.readAsLinesSync()) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final entry = GlossaryEntry.fromStsLine(trimmed);
    if (entry != null) entries.add(entry);
  }
  return entries;
}

/// 保存术语表（覆盖）
bool saveGlossary(String tableName, List<GlossaryEntry> entries) {
  ensureGlossaryDir();
  final f = File('$DB_GLOSSARY_DIR/$tableName.sts');
  final sb = StringBuffer();
  for (final e in entries) {
    sb.writeln(e.toStsLine());
  }
  try {
    f.writeAsStringSync(sb.toString());
    return true;
  } catch (e) {
    logp('❌ 保存术语表失败: $e');
    return false;
  }
}

/// 删除术语表
bool deleteGlossary(String tableName) {
  ensureGlossaryDir();
  final f = File('$DB_GLOSSARY_DIR/$tableName.sts');
  if (!f.existsSync()) return false;
  try {
    f.deleteSync();
    return true;
  } catch (e) {
    logp('❌ 删除术语表失败: $e');
    return false;
  }
}

/// 将术语表转换为 API 需要的 glossary_list（Map<String, String>）
/// 可选按源语言/目标语言过滤
Map<String, String> glossaryToList(
  List<GlossaryEntry> entries, {
  String? sourceLang,
  String? targetLang,
}) {
  final map = <String, String>{};
  for (final e in entries) {
    if (sourceLang != null && sourceLang.isNotEmpty) {
      if (e.sourceLang.isNotEmpty && e.sourceLang != sourceLang) continue;
    }
    if (targetLang != null && targetLang.isNotEmpty) {
      if (e.targetLang.isNotEmpty && e.targetLang != targetLang) continue;
    }
    map[e.source] = e.target;
  }
  return map;
}

// ------------------------------------------------------------
// 翻译 API 调用
// ------------------------------------------------------------
Future<Map<String, dynamic>> dbTranslate({
  required String apiKey,
  required String targetLanguage,
  required List<String> textList,
  String sourceLanguage = '',
  Map<String, String>? glossaryList,
  String? glossaryTableId,
  String? glossaryTableName,
  String requestId = '',
}) async {
  if (textList.isEmpty) throw Exception('待翻译文本列表不能为空');
  if (textList.length > 16) throw Exception('待翻译文本列表最多 16 条');
  
  // ★ 强制获取配置里的专用翻译 Key
  final cfg = getDbConfig();
  // ★ 直接强读音频生成 Key（OpenSpeech），因为你的语音和翻译用的是同一个 Key
  var finalKey = cfg.audioGenApiKey.trim();
  if (finalKey.isEmpty) {
    finalKey = cfg.translateApiKey.trim();
  }
  // 如果都没有，才去看看传进来的 apiKey（防报错兜底）
  if (finalKey.isEmpty && !apiKey.startsWith('ark-')) {
    finalKey = apiKey.trim();
  }

  if (finalKey.isEmpty || finalKey.startsWith('ark-')) {
    throw Exception('翻译失败：请在设置中找到“豆包音频生成 Key (OpenSpeech)”，填入你的语音 Key（f 开头）。');
  }

  final rid = requestId.trim().isEmpty
      ? 'dsc_mt_${DateTime.now().microsecondsSinceEpoch}'
      : requestId.trim();

  // ★ 严格按照火山文档要求设置 Header
  // ★ 同时兼容新版(X-Api-Key)与旧版(X-Api-App-Key + X-Api-Access-Key)鉴权
  final headers = <String, String>{
    'X-Api-Key': finalKey, 
    'X-Api-Resource-Id': 'volc.speech.mt',
    'X-Api-Request-Id': rid,
    'Content-Type': 'application/json',
  };
  
  // 如果填入的是非 ark- 开头的长字符串或纯数字，则补充旧版头
  final cleanKey = finalKey.trim();
  if (!cleanKey.startsWith('ark-')) {
    headers['X-Api-App-Key'] = cleanKey; 
    headers['X-Api-Access-Key'] = cleanKey;
    logp('🔑 翻译：已同时注入 X-Api-App-Key / X-Api-Access-Key');
  }

  final corpus = <String, dynamic>{};
  if (glossaryList != null && glossaryList.isNotEmpty) {
    corpus['glossary_list'] = glossaryList;
  }
  if (glossaryTableId != null && glossaryTableId.trim().isNotEmpty) {
    corpus['glossary_table_id'] = glossaryTableId.trim();
  }
  if (glossaryTableName != null && glossaryTableName.trim().isNotEmpty) {
    corpus['glossary_table_name'] = glossaryTableName.trim();
  }

  final body = <String, dynamic>{
    'target_language': targetLanguage,
    'text_list': textList,
    if (sourceLanguage.trim().isNotEmpty) 'source_language': sourceLanguage.trim(),
    if (corpus.isNotEmpty) 'corpus': corpus,
  };

  logp('🌐 豆包翻译请求：使用 Key=${finalKey.substring(0, 4)}••••，共 ${textList.length} 条');

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final req = await client.postUrl(Uri.parse(DB_TRANSLATE_URL));
    headers.forEach((k, v) => req.headers.set(k, v));
    req.add(utf8.encode(jsonEncode(body)));

    final resp = await req.close().timeout(const Duration(seconds: 60));
    final bytes = await resp.fold<List<int>>([], (a, b) => a..addAll(b));
    final txt = utf8.decode(bytes, allowMalformed: true);

    if (resp.statusCode != 200) {
      throw Exception('翻译 API HTTP ${resp.statusCode}：$txt');
    }

    final json = asMap(jsonDecode(txt));
    final code = json['code'];
    if (code is int && code == 20000000) {
      return json;
    }
    final message = mStr(json, 'message', '未知错误');
    throw Exception('翻译失败（code=$code）：$message');
  } finally {
    client.close(force: true);
  }
}

// ------------------------------------------------------------
// HTTP 处理器：翻译
// ------------------------------------------------------------
Future<void> handleDbTranslate(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'POST') {
    await dsJSONErr(res, 405, 'Method not allowed');
    return;
  }

  Map<String, dynamic> body;
  try {
    body = await readJsonBody(req);
  } catch (_) {
    await dsJSONErr(res, 400, '无效的请求体');
    return;
  }

  var apiKey = mStr(body, 'apiKey').trim();
  if (apiKey.isEmpty) { final cfg = getDbConfig(); apiKey = cfg.translateApiKey.trim().isNotEmpty ? cfg.translateApiKey.trim() : cfg.apiKey.trim(); }
  if (apiKey.isEmpty) { final cfg = getDbConfig(); apiKey = cfg.translateApiKey.trim().isNotEmpty ? cfg.translateApiKey.trim() : cfg.apiKey.trim(); }
  if (apiKey.isEmpty) {
    final cfg = getDbConfig();
    apiKey = cfg.apiKey.trim();
  }
  if (apiKey.isEmpty) {
    await dsJSONErr(res, 400, '豆包 API Key 未设置，请先在设置中填写。');
    return;
  }

  final targetLanguage = mStr(body, 'target_language').trim();
  if (targetLanguage.isEmpty) {
    await dsJSONErr(res, 400, 'target_language 是必填字段');
    return;
  }

  final rawList = asList(body['text_list']);
  final textList = rawList.map((e) => '$e').toList();
  if (textList.isEmpty) {
    await dsJSONErr(res, 400, 'text_list 不能为空');
    return;
  }

  final sourceLanguage = mStr(body, 'source_language').trim();
  final glossaryListRaw = body['glossary_list'];
  Map<String, String>? glossaryList;
  if (glossaryListRaw is Map) {
    glossaryList = {};
    glossaryListRaw.forEach((k, v) => glossaryList!['$k'] = '$v');
  }

  final glossaryTableId = mStr(body, 'glossary_table_id').trim();
  final glossaryTableName = mStr(body, 'glossary_table_name').trim();

  try {
    final result = await dbTranslate(
      apiKey: apiKey,
      targetLanguage: targetLanguage,
      textList: textList,
      sourceLanguage: sourceLanguage,
      glossaryList: glossaryList,
      glossaryTableId: glossaryTableId.isEmpty ? null : glossaryTableId,
      glossaryTableName: glossaryTableName.isEmpty ? null : glossaryTableName,
    );

    await dsJSONOk(res, 200, {
      'success': true,
      ...result,
    });
  } catch (e) {
    logp('❌ 豆包翻译失败：$e');
    await dsJSONErr(res, 500, dbErrText(e));
  }
}

// ------------------------------------------------------------
// HTTP 处理器：术语表管理
// ------------------------------------------------------------
Future<void> handleGlossaryList(HttpRequest req) async {
  final tables = listGlossaryTables();
  await dsJSONOk(req.response, 200, {
    'success': true,
    'tables': tables,
  });
}

Future<void> handleGlossaryGet(HttpRequest req) async {
  final name = qp(req, 'name').trim();
  if (name.isEmpty) {
    await dsJSONErr(req.response, 400, '缺少 name 参数');
    return;
  }
  final entries = loadGlossary(name);
  await dsJSONOk(req.response, 200, {
    'success': true,
    'name': name,
    'entries': entries.map((e) => e.toJson()).toList(),
  });
}

Future<void> handleGlossarySave(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'POST') {
    await dsJSONErr(res, 405, 'Method not allowed');
    return;
  }

  Map<String, dynamic> body;
  try {
    body = await readJsonBody(req);
  } catch (_) {
    await dsJSONErr(res, 400, '无效的请求体');
    return;
  }

  final name = mStr(body, 'name').trim();
  if (name.isEmpty) {
    await dsJSONErr(res, 400, '术语表名称不能为空');
    return;
  }

  final rawEntries = asList(body['entries']);
  final entries = <GlossaryEntry>[];
  for (var i = 0; i < rawEntries.length; i++) {
    final e = asMap(rawEntries[i]);
    final source = mStr(e, 'source').trim();
    final target = mStr(e, 'target').trim();
    if (source.isEmpty || target.isEmpty) {
      await dsJSONErr(res, 400, '第 ${i + 1} 条术语的源词或译词为空');
      return;
    }
    entries.add(GlossaryEntry(
      id: mStr(e, 'id').trim().isEmpty
          ? 'g_${DateTime.now().microsecondsSinceEpoch}_$i'
          : mStr(e, 'id').trim(),
      source: source,
      target: target,
      sourceLang: mStr(e, 'sourceLang').trim(),
      targetLang: mStr(e, 'targetLang').trim(),
    ));
  }

  final ok = saveGlossary(name, entries);
  if (!ok) {
    await dsJSONErr(res, 500, '保存术语表失败');
    return;
  }

  await dsJSONOk(res, 200, {
    'success': true,
    'name': name,
    'count': entries.length,
  });
}

Future<void> handleGlossaryDelete(HttpRequest req) async {
  final res = req.response;
  final name = qp(req, 'name').trim();
  if (name.isEmpty) {
    await dsJSONErr(res, 400, '缺少 name 参数');
    return;
  }
  final ok = deleteGlossary(name);
  await dsJSONOk(res, 200, {
    'success': ok,
    'deleted': ok,
  });
}