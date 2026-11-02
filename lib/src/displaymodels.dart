// ============================================================
// displaymodels.dart —— 自定义模型（displaymodels）存储
//   目录：$DATA_DIR/displaymodels  （即 ddsh/data/displaymodels）
//   格式：与 sessions / announcements 同系的明文 .sts
//     每个模型 ⇔ 一个独立文件，互不混存
//     #M|modelId|createdAt
//   id 转义复用 globals.escDs / unescDs（| → \p，\ → \\）
// ============================================================

import 'dart:io';

import 'globals.dart';
import 'httpsrv.dart';

String get displayModelsDir => '$DATA_DIR/displaymodels';

const int DM_MAX_NAME_RUNES = 120;
const int DM_MAX_FILE_RUNES = 80;

class DisplayModel {
  final String id;
  final String createdAt;
  final String fileName;

  const DisplayModel({
    required this.id,
    this.createdAt = '',
    this.fileName = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt,
        'file': fileName,
      };
}

void initDisplayModelsDir() {
  ensureDir(displayModelsDir);
}

// ------------------------------------------------------------
// 模型名 → 安全文件名（不含 .sts 后缀）
// ------------------------------------------------------------
String safeModelFileBase(String id) {
  var safe = id.trim();
  const bad = <String>[
    '/', '\\', ':', '*', '?', '"', '<', '>', '|', '\n', '\r', '\t', '\u0000'
  ];
  for (final c in bad) {
    safe = safe.replaceAll(c, '_');
  }
  safe = safe.replaceAll('..', '_');
  while (safe.startsWith('.')) {
    safe = '_${safe.substring(1)}';
  }
  if (safe.isEmpty) safe = 'model';
  if (safe.runes.length > DM_MAX_FILE_RUNES) {
    safe = String.fromCharCodes(safe.runes.take(DM_MAX_FILE_RUNES));
  }
  return safe;
}

/// 稳定的短哈希（FNV-1a 32bit），仅用于文件名碰撞消歧
String _shortHash(String s) {
  var h = 0x811C9DC5;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h.toRadixString(16);
}

/// 常规路径（按模型名安全化）
String displayModelPath(String id) =>
    '$displayModelsDir/${safeModelFileBase(id)}.sts';

/// 写入用路径：若同名文件已被「另一个模型」占用，则追加短哈希避免互相覆盖
String displayModelPathForSave(String id) {
  final base = safeModelFileBase(id);
  final p = '$displayModelsDir/$base.sts';
  final f = File(p);
  if (!f.existsSync()) return p;
  final exist = readDisplayModel(p);
  if (exist != null && exist.id == id) return p; // 同一模型 → 原地覆盖
  final h = _shortHash(id);
  final alt = '$displayModelsDir/${base}_$h.sts';
  final af = File(alt);
  if (!af.existsSync()) return alt;
  final aexist = readDisplayModel(alt);
  if (aexist != null && aexist.id == id) return alt;
  return '$displayModelsDir/${base}_${h}_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}.sts';
}

// ------------------------------------------------------------
// 读取
// ------------------------------------------------------------
DisplayModel? readDisplayModel(String path) {
  String data;
  try {
    data = File(path).readAsStringSync();
  } catch (_) {
    return null;
  }
  String? id;
  var createdAt = '';
  for (final rawLine in data.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#M|')) {
      final parts = line.substring(3).split('|');
      if (parts.isEmpty) continue;
      id = unescDs(parts[0]).trim();
      if (parts.length >= 2) createdAt = parts[1].trim();
      break;
    }
  }
  if (id == null || id.isEmpty) return null;
  final name = path.split('/').last;
  return DisplayModel(id: id, createdAt: createdAt, fileName: name);
}

DisplayModel? getDisplayModel(String id) {
  if (id.trim().isEmpty) return null;
  // 先试常规路径，再全目录匹配（兼容哈希后缀文件）
  final direct = displayModelPath(id);
  if (File(direct).existsSync()) {
    final m = readDisplayModel(direct);
    if (m != null && m.id == id) return m;
  }
  for (final m in getAllDisplayModels()) {
    if (m.id == id) return m;
  }
  return null;
}

List<DisplayModel> getAllDisplayModels() {
  List<FileSystemEntity> files;
  try {
    files = Directory(displayModelsDir).listSync();
  } catch (_) {
    return [];
  }
  final out = <DisplayModel>[];
  final seen = <String>{};
  for (final f in files) {
    if (f is! File || !f.path.endsWith('.sts')) continue;
    final m = readDisplayModel(f.path);
    if (m == null) continue;
    if (!seen.add(m.id)) continue; // 重复 id 只保留第一个
    out.add(m);
  }
  out.sort((a, b) => a.id.compareTo(b.id));
  return out;
}

// ------------------------------------------------------------
// 写入 / 删除
// ------------------------------------------------------------
bool saveDisplayModel(String id, {String createdAt = ''}) {
  ensureDir(displayModelsDir);
  final line = '#M|${escDs(id)}|$createdAt\n';
  return writeTextFile(displayModelPathForSave(id), line);
}

bool deleteDisplayModel(String id) {
  final target = getDisplayModel(id);
  if (target == null) return false;
  try {
    final f = File('$displayModelsDir/${target.fileName}');
    if (!f.existsSync()) return false;
    f.deleteSync();
    return true;
  } catch (e) {
    logp('❌ カスタムモデルの削除に失敗しました: $e');
    return false;
  }
}

// ------------------------------------------------------------
// /api/displaymodels
//   GET                 → { success, models:[{id,createdAt,file}], dir }
//   POST   {id}         → 新增（幂等）一个 .sts 文件
//   DELETE ?id=xxx      → 删除对应 .sts 文件
// ------------------------------------------------------------
Future<void> handleDisplayModels(HttpRequest req) async {
  final res = req.response;

  switch (req.method) {
    case 'GET':
      final list = getAllDisplayModels();
      await dsJSONOk(res, 200, {
        'success': true,
        'models': list.map((m) => m.toJson()).toList(),
        'dir': displayModelsDir,
      });
      return;

    case 'POST':
      Map<String, dynamic> body;
      try {
        body = await readJsonBody(req);
      } catch (_) {
        await dsJSONErr(res, 400, '無効なリクエストボディです');
        return;
      }
      final raw = mStr(body, 'id').trim();
      if (raw.isEmpty) {
        await dsJSONErr(res, 400, 'モデル名は必須です');
        return;
      }
      if (runeLen(raw) > DM_MAX_NAME_RUNES) {
        await dsJSONErr(res, 400, '模型名最多 $DM_MAX_NAME_RUNES 字');
        return;
      }
      if (raw.contains(RegExp(r'\s'))) {
        await dsJSONErr(res, 400, '模型名不能包含空格');
        return;
      }

      final existed = getDisplayModel(raw);
      final createdAt = (existed != null && existed.createdAt.isNotEmpty)
          ? existed.createdAt
          : rfc3339(DateTime.now());
      final path = displayModelPathForSave(raw);
      if (!writeTextFile(path, '#M|${escDs(raw)}|$createdAt\n')) {
        await dsJSONErr(res, 500, '書き込みに失敗しました');
        return;
      }
      await dsJSONOk(res, 200, {
        'success': true,
        'existed': existed != null,
        'model': DisplayModel(
          id: raw,
          createdAt: createdAt,
          fileName: path.split('/').last,
        ).toJson(),
      });
      return;

    case 'DELETE':
      var id = qp(req, 'id').trim();
      if (id.isEmpty) {
        try {
          final body = await readJsonBody(req);
          id = mStr(body, 'id').trim();
        } catch (_) {}
      }
      if (id.isEmpty) {
        await dsJSONErr(res, 400, '缺少 id');
        return;
      }
      final ok = deleteDisplayModel(id);
      await dsJSONOk(res, 200, {'success': ok, 'deleted': id});
      return;

    default:
      await dsJSONErr(res, 405, 'Method not allowed');
  }
}
