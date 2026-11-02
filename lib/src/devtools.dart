// ============================================================
// devtools.dart —— 开发者工具：注入提示词（system 角色注入）
// 存储：DATA_DIR/deepseek_chat/devtools/inject_prompts.sts
// 行格式：id|title|content|createdAt
// ============================================================

import 'dart:io';

import 'ds_crypto.dart';
import 'globals.dart';
import 'httpsrv.dart';
import 'sessions.dart' show initDsChatDir;

String get dsDevToolsDir => '$dsChatDir/devtools';
String get dsInjectPromptsFile => '$dsDevToolsDir/inject_prompts.sts';

class DsInjectPrompt {
  String id;
  String title;
  String content;
  String createdAt;

  DsInjectPrompt({
    required this.id,
    required this.title,
    required this.content,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() =>
      {'id': id, 'title': title, 'content': content, 'createdAt': createdAt};
}

void initDsDevToolsDir() {
  initDsChatDir();
  ensureDir(dsDevToolsDir);
  seedDsInjectPrompts();
}

void seedDsInjectPrompts() {
  if (File(dsInjectPromptsFile).existsSync()) return;
  final now = DateTime.now();
  final list = [
    DsInjectPrompt(
      id: 'dsp_${fmtStamp14(now)}_${randomHex(6)}',
      title: '第 1 項目',
      content: 'こんにちは',
      createdAt: rfc3339(now),
    ),
    DsInjectPrompt(
      id: 'dsp_${fmtStamp14(now.add(const Duration(seconds: 1)))}_${randomHex(6)}',
      title: '第 2 項目',
      content: '大家好',
      createdAt: rfc3339(now.add(const Duration(seconds: 1))),
    ),
  ];
  saveDsInjectPrompts(list);
  logp('🌱 注入プロンプトの初期データを投入しました（第 1 項目=こんにちは / 第 2 項目=みなさんこんにちは）');
}

List<DsInjectPrompt> readDsInjectPrompts() {
  String data;
  try {
    data = File(dsInjectPromptsFile).readAsStringSync();
  } catch (_) {
    return [];
  }
  final list = <DsInjectPrompt>[];
  for (var line in data.split('\n')) {
    line = line.trim();
    if (line.isEmpty) continue;
    final parts = line.split('|');
    if (parts.length < 4) continue;
    list.add(DsInjectPrompt(
      id: parts[0],
      title: unescDs(parts[1]),
      content: unescDs(parts[2]),
      createdAt: parts[3],
    ));
  }
  return list;
}

bool saveDsInjectPrompts(List<DsInjectPrompt> list) {
  final lines = list
      .map((p) => '${p.id}|${escDs(p.title)}|${escDs(p.content)}|${p.createdAt}')
      .toList();
  var content = lines.join('\n');
  if (content.isNotEmpty) content += '\n';
  ensureDir(dsDevToolsDir);
  return writeTextFile(dsInjectPromptsFile, content);
}

/// 供聊天发送时使用：返回所有注入提示词内容（按顺序、已 trim）
List<String> getDsInjectPromptsContents() {
  final out = <String>[];
  for (final p in readDsInjectPrompts()) {
    final c = p.content.trim();
    if (c.isNotEmpty) out.add(c);
  }
  return out;
}

// ------------------------------------------------------------
// HTTP
// ------------------------------------------------------------
Future<void> handleDsDevToolsPrompts(HttpRequest req) async {
  final res = req.response;
  switch (req.method) {
    case 'GET':
      final list = readDsInjectPrompts();
      await jsonResponse(res, 200, {
        'prompts': list.map((p) => p.toJson()).toList(),
        'count': list.length,
      });
      return;

    case 'POST':
      Map<String, dynamic> body;
      try {
        body = await readJsonBody(req);
      } catch (_) {
        await errJson(res, 400, '無効なリクエストボディです');
        return;
      }
      var id = mStr(body, 'id');
      final title = trimOr(mStr(body, 'title'), '未命名');
      final content = mStr(body, 'content').trim();
      if (content.isEmpty) {
        await errJson(res, 400, 'プロンプトの内容は必須です');
        return;
      }
      final list = readDsInjectPrompts();
      if (id.isNotEmpty) {
        var found = false;
        for (final p in list) {
          if (p.id == id) {
            p.title = title;
            p.content = content;
            found = true;
            break;
          }
        }
        if (!found) {
          await errJson(res, 404, 'プロンプトが存在しません');
          return;
        }
      } else {
        id = 'dsp_${fmtStamp14(DateTime.now())}_${randomHex(6)}';
        list.add(DsInjectPrompt(
          id: id,
          title: title,
          content: content,
          createdAt: rfc3339(DateTime.now()),
        ));
      }
      if (!saveDsInjectPrompts(list)) {
        await errJson(res, 500, '保存に失敗しました');
        return;
      }
      await jsonResponse(res, 200, {
        'success': true,
        'id': id,
        'prompts': list.map((p) => p.toJson()).toList(),
      });
      return;

    case 'DELETE':
      if (req.uri.queryParameters['all'] == 'true') {
        if (!saveDsInjectPrompts([])) {
          await errJson(res, 500, 'クリアに失敗しました');
          return;
        }
        await jsonResponse(res, 200, {'success': true});
        return;
      }
      final id = qp(req, 'id');
      if (id.isEmpty) {
        await errJson(res, 400, '缺少 id');
        return;
      }
      final list = readDsInjectPrompts().where((p) => p.id != id).toList();
      if (!saveDsInjectPrompts(list)) {
        await errJson(res, 500, '削除に失敗しました');
        return;
      }
      await jsonResponse(res, 200, {'success': true});
      return;

    default:
      await errJson(res, 405, 'Method not allowed');
  }
}

Future<void> handleDsDevToolsBatchDelete(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'POST') {
    await errJson(res, 405, 'Method not allowed');
    return;
  }
  Map<String, dynamic> body;
  try {
    body = await readJsonBody(req);
  } catch (_) {
    await errJson(res, 400, '無効なリクエストボディです');
    return;
  }
  final ids = asList(body['ids']).map((e) => '$e').toSet();
  if (ids.isEmpty) {
    await errJson(res, 400, '缺少 ids');
    return;
  }
  final list = readDsInjectPrompts();
  final keep = <DsInjectPrompt>[];
  var deleted = 0;
  for (final p in list) {
    if (ids.contains(p.id)) {
      deleted++;
      continue;
    }
    keep.add(p);
  }
  if (!saveDsInjectPrompts(keep)) {
    await errJson(res, 500, '削除に失敗しました');
    return;
  }
  await jsonResponse(res, 200, {'success': true, 'deleted': deleted});
}
