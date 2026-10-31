// ============================================================
// announcements.dart —— 公告系统
//   数据格式：与 sessions 同款的明文 .sts（#A 头行 + #C 内容行）
//     #A|id|title|startTime|endTime|priority|forceTop|createdAt
//     #C|content
//   字段转义：复用 globals.escDs / unescDs（| → \p，\ → \\，换行 → \n）
//   约束：标题 ≤500 字、内容 ≤50000 字、总条数 ≤5
// ============================================================

import 'dart:io';

import 'globals.dart';
import 'httpsrv.dart';

String get announcementsDir => '$DATA_DIR/announcements';

const int ANN_MAX_TITLE_RUNES = 500;
const int ANN_MAX_CONTENT_RUNES = 50000;
const int ANN_MAX_COUNT = 5;

class Announcement {
  final String id;
  final String title;
  final String content;
  final String startTime; // RFC3339 或空（空 = 立即生效）
  final String endTime;   // RFC3339 或空（空 = 长期有效）
  final int priority;     // 数值越大越优先
  final bool forceTop;    // 最高级别：无视优先级强制展示
  final String createdAt;

  const Announcement({
    required this.id,
    required this.title,
    required this.content,
    this.startTime = '',
    this.endTime = '',
    this.priority = 0,
    this.forceTop = false,
    this.createdAt = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'content': content,
        'startTime': startTime,
        'endTime': endTime,
        'priority': priority,
        'forceTop': forceTop,
        'createdAt': createdAt,
      };
}

void initAnnouncementsDir() {
  ensureDir(announcementsDir);
}

String annPath(String id) {
  var safe = id
      .replaceAll('/', '_')
      .replaceAll('\\', '_')
      .replaceAll('..', '_')
      .replaceAll('|', '_')
      .replaceAll(':', '_');
  return '$announcementsDir/$safe.sts';
}

// ------------------------------------------------------------
// 读取
// ------------------------------------------------------------
Announcement? readAnnouncement(String path) {
  String data;
  try {
    data = File(path).readAsStringSync();
  } catch (_) {
    return null;
  }
  String? id;
  String? title;
  var content = '';
  var startTime = '';
  var endTime = '';
  var priority = 0;
  var forceTop = false;
  var createdAt = '';
  for (final rawLine in data.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#A|')) {
      final parts = line.substring(3).split('|');
      if (parts.length < 7) continue;
      id = parts[0];
      title = unescDs(parts[1]);
      startTime = parts[2];
      endTime = parts[3];
      priority = int.tryParse(parts[4]) ?? 0;
      forceTop = parts[5] == '1';
      createdAt = parts.length >= 7 ? parts[6] : '';
    } else if (line.startsWith('#C|')) {
      content = unescDs(line.substring(3));
    }
  }
  if (id == null || title == null) return null;
  return Announcement(
    id: id,
    title: title,
    content: content,
    startTime: startTime,
    endTime: endTime,
    priority: priority,
    forceTop: forceTop,
    createdAt: createdAt,
  );
}

Announcement? getAnnouncement(String id) =>
    id.isEmpty ? null : readAnnouncement(annPath(id));

List<Announcement> getAllAnnouncements() {
  List<FileSystemEntity> files;
  try {
    files = Directory(announcementsDir).listSync();
  } catch (_) {
    return [];
  }
  final out = <Announcement>[];
  for (final f in files) {
    if (f is! File || !f.path.endsWith('.sts')) continue;
    final a = readAnnouncement(f.path);
    if (a != null) out.add(a);
  }
  return out;
}

// ------------------------------------------------------------
// 写入
// ------------------------------------------------------------
bool saveAnnouncement(Announcement a) {
  final line = '#A|${a.id}|${escDs(a.title)}|${a.startTime}|${a.endTime}|'
      '${a.priority}|${a.forceTop ? 1 : 0}|${a.createdAt}\n'
      '#C|${escDs(a.content)}\n';
  ensureDir(announcementsDir);
  return writeTextFile(annPath(a.id), line);
}

bool deleteAnnouncement(String id) {
  if (id.isEmpty) return false;
  final path = annPath(id);
  try {
    if (File(path).existsSync()) File(path).deleteSync();
    return true;
  } catch (e) {
    logp('❌ 删除公告失败: $e');
    return false;
  }
}

// ------------------------------------------------------------
// 时间窗口判断
// ------------------------------------------------------------
bool isAnnouncementActive(Announcement a, DateTime now) {
  if (a.startTime.isNotEmpty) {
    final s = DateTime.tryParse(a.startTime);
    if (s != null && now.isBefore(s)) return false;
  }
  if (a.endTime.isNotEmpty) {
    final e = DateTime.tryParse(a.endTime);
    if (e != null && now.isAfter(e)) return false;
  }
  return true;
}

// ------------------------------------------------------------
// /api/announcements  GET(全部) / POST(创建或更新) / DELETE(删除)
// ------------------------------------------------------------
Future<void> handleAnnouncements(HttpRequest req) async {
  final res = req.response;
  switch (req.method) {
    case 'GET':
      final list = getAllAnnouncements();
      list.sort((a, b) {
        if (a.forceTop != b.forceTop) return a.forceTop ? -1 : 1;
        return b.priority.compareTo(a.priority);
      });
      await dsJSONOk(res, 200, {
        'announcements': list.map((a) => a.toJson()).toList(),
      });
      return;

    case 'POST':
      Map<String, dynamic> body;
      try {
        body = await readJsonBody(req);
      } catch (_) {
        await dsJSONErr(res, 400, '无效请求体');
        return;
      }
      final existingId = trimOr(mStr(body, 'id'), '');
      final title = mStr(body, 'title').trim();
      final content = mStr(body, 'content');
      final startTime = mStr(body, 'startTime').trim();
      final endTime = mStr(body, 'endTime').trim();
      final priority = intArgDefault(body, 'priority', 0);
      final forceTop = mBool(body, 'forceTop');

      if (title.isEmpty) {
        await dsJSONErr(res, 400, '标题不能为空');
        return;
      }
      if (runeLen(title) > ANN_MAX_TITLE_RUNES) {
        await dsJSONErr(res, 400, '标题最多 $ANN_MAX_TITLE_RUNES 字');
        return;
      }
      if (runeLen(content) > ANN_MAX_CONTENT_RUNES) {
        await dsJSONErr(res, 400, '内容最多 $ANN_MAX_CONTENT_RUNES 字');
        return;
      }

      final now = DateTime.now();
      if (existingId.isEmpty) {
        final all = getAllAnnouncements();
        if (all.length >= ANN_MAX_COUNT) {
          await dsJSONErr(res, 400, '最多只能存在 $ANN_MAX_COUNT 条公告，请先删除旧公告');
          return;
        }
        final id = 'ann_${fmtStamp14(now)}_${randomHex(6)}';
        final a = Announcement(
          id: id,
          title: title,
          content: content,
          startTime: startTime,
          endTime: endTime,
          priority: priority,
          forceTop: forceTop,
          createdAt: rfc3339(now),
        );
        if (!saveAnnouncement(a)) {
          await dsJSONErr(res, 500, '保存失败');
          return;
        }
        await dsJSONOk(res, 200, {'success': true, 'announcement': a.toJson()});
        return;
      }

      final existing = getAnnouncement(existingId);
      if (existing == null) {
        await dsJSONErr(res, 404, '公告不存在');
        return;
      }
      final a = Announcement(
        id: existingId,
        title: title,
        content: content,
        startTime: startTime,
        endTime: endTime,
        priority: priority,
        forceTop: forceTop,
        createdAt: existing.createdAt,
      );
      if (!saveAnnouncement(a)) {
        await dsJSONErr(res, 500, '保存失败');
        return;
      }
      await dsJSONOk(res, 200, {'success': true, 'announcement': a.toJson()});
      return;

    case 'DELETE':
      final id = qp(req, 'id');
      if (id.isEmpty) {
        await dsJSONErr(res, 400, '缺少 id');
        return;
      }
      deleteAnnouncement(id);
      await dsJSONOk(res, 200, {'success': true});
      return;

    default:
      await dsJSONErr(res, 405, 'Method not allowed');
  }
}

// ------------------------------------------------------------
// /api/announcements/active  GET(当前应展示的公告，按优先级排序)
// ------------------------------------------------------------
Future<void> handleAnnouncementsActive(HttpRequest req) async {
  final res = req.response;
  final now = DateTime.now();
  final list = getAllAnnouncements()
      .where((a) => isAnnouncementActive(a, now))
      .toList();
  list.sort((a, b) {
    if (a.forceTop != b.forceTop) return a.forceTop ? -1 : 1;
    return b.priority.compareTo(a.priority);
  });
  await dsJSONOk(res, 200, {
    'announcements': list.map((a) => a.toJson()).toList(),
  });
}
