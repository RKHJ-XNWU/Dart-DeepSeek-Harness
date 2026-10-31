// ============================================================
// forum.dart —— 论坛帖子模块（帖子展示与论坛发帖）
//   目录：$DATA_DIR/dispost  （即 ddsh/data/dispost）
//   一帖一文件：${id}.sts，UTF-8，内容为 JSON 结构
//   字段：id / title / content / author / createdAt / updatedAt /
//         isPinned / isFeatured / isBlocked / isDeleted
//   约束：标题 ≤ 5000 字；正文 ≤ 500 万字（5000000 rune）
//   列表只返回元数据 + 摘要；详情按 id 读取完整正文，
//   避免一次把全部大文件读进内存。
// ============================================================

import 'dart:convert';
import 'dart:io';

import 'globals.dart';
import 'httpsrv.dart';

String get forumDir => '$DATA_DIR/dispost';

const int FORUM_MAX_TITLE_RUNES = 5000;
const int FORUM_MAX_CONTENT_RUNES = 5000000; // 500 万字
const int FORUM_SUMMARY_RUNES = 120;

// 帖子实体（详情 / 写入用，持有完整正文）
class ForumPost {
  final String id;
  final String title;
  final String content;
  final String author;
  final String createdAt;
  final String updatedAt;
  final bool isPinned;
  final bool isFeatured;
  final bool isBlocked;
  final bool isDeleted;

  const ForumPost({
    required this.id,
    required this.title,
    required this.content,
    this.author = '',
    this.createdAt = '',
    this.updatedAt = '',
    this.isPinned = false,
    this.isFeatured = false,
    this.isBlocked = false,
    this.isDeleted = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'content': content,
        'author': author,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'isPinned': isPinned,
        'isFeatured': isFeatured,
        'isBlocked': isBlocked,
        'isDeleted': isDeleted,
      };
}

// 列表摘要：正文折叠为单行短摘要，避免列表携带整篇正文
String _summary(String content) {
  if (content.isEmpty) return '';
  // 只取开头一小段（至多 600 个 code unit）做摘要，避免对超大正文全量折叠
  var head = content;
  if (head.length > 600) {
    head = head.substring(0, 600);
    final last = head.codeUnitAt(head.length - 1);
    // 避免切断 UTF-16 代理对
    if (last >= 0xD800 && last <= 0xDBFF && content.length > head.length) {
      head = content.substring(0, head.length + 1);
    }
  }
  var c = head.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (c.isEmpty) return '';
  final r = c.runes.toList();
  if (r.length <= FORUM_SUMMARY_RUNES) return c;
  return '${String.fromCharCodes(r.sublist(0, FORUM_SUMMARY_RUNES))}…';
}

void initForumDir() {
  ensureDir(forumDir);
}

// 帖子 ID 一律由服务端生成（post_时间戳_随机数），仅允许安全字符，
// 从源头杜绝路径穿越。
final RegExp _safeIdRe = RegExp(r'^[A-Za-z0-9_-]+$');
String sanitizeId(String s) => _safeIdRe.hasMatch(s) ? s : '';

String forumPath(String id) => '$forumDir/$id.sts';

/// 读取单帖完整正文；文件不存在 / JSON 损坏 → null（异常文件隔离）
ForumPost? readForumPost(String path) {
  String data;
  try {
    data = File(path).readAsStringSync();
  } catch (_) {
    return null;
  }
  try {
    final m = asMap(jsonDecode(data));
    final id = mStr(m, 'id').trim();
    if (id.isEmpty) return null;
    return ForumPost(
      id: id,
      title: mStr(m, 'title'),
      content: mStr(m, 'content'),
      author: mStr(m, 'author'),
      createdAt: mStr(m, 'createdAt'),
      updatedAt: mStr(m, 'updatedAt'),
      isPinned: mBool(m, 'isPinned'),
      isFeatured: mBool(m, 'isFeatured'),
      isBlocked: mBool(m, 'isBlocked'),
      isDeleted: mBool(m, 'isDeleted'),
    );
  } catch (_) {
    return null;
  }
}

ForumPost? getForumPost(String id) {
  final sid = sanitizeId(id);
  if (sid.isEmpty) return null;
  return readForumPost(forumPath(sid));
}

/// 列表读取：解析后仅保留元数据 + 摘要，立即丢弃完整正文，
/// 从而不把所有大文件同时驻留内存。
Map<String, dynamic>? _readPostMeta(String path) {
  String data;
  try {
    data = File(path).readAsStringSync();
  } catch (_) {
    return null;
  }
  try {
    final m = asMap(jsonDecode(data));
    final id = mStr(m, 'id').trim();
    if (id.isEmpty) return null;
    return {
      'id': id,
      'title': mStr(m, 'title'),
      'author': mStr(m, 'author'),
      'createdAt': mStr(m, 'createdAt'),
      'updatedAt': mStr(m, 'updatedAt'),
      'isPinned': mBool(m, 'isPinned'),
      'isFeatured': mBool(m, 'isFeatured'),
      'isBlocked': mBool(m, 'isBlocked'),
      'isDeleted': mBool(m, 'isDeleted'),
      'summary': _summary(mStr(m, 'content')),
    };
  } catch (_) {
    return null;
  }
}

int _cmpPostMeta(Map<String, dynamic> a, Map<String, dynamic> b) {
  final ap = a['isPinned'] == true;
  final bp = b['isPinned'] == true;
  if (ap != bp) return ap ? -1 : 1;
  final ta = (a['updatedAt'] ?? '').toString();
  final tb = (b['updatedAt'] ?? '').toString();
  final ua = ta.isNotEmpty ? ta : (a['createdAt'] ?? '').toString();
  final ub = tb.isNotEmpty ? tb : (b['createdAt'] ?? '').toString();
  return ub.compareTo(ua);
}

(List<Map<String, dynamic>>, int, int) listForumPosts({int offset = 0, int limit = 10}) {
  List<FileSystemEntity> files;
  try {
    files = Directory(forumDir).listSync();
  } catch (_) {
    return (<Map<String, dynamic>>[], 0, 0);
  }
  final all = <Map<String, dynamic>>[];
  var broken = 0;
  for (final f in files) {
    if (f is! File || !f.path.endsWith('.sts')) continue;
    final meta = _readPostMeta(f.path);
    if (meta == null) {
      broken++;
      continue;
    }
    all.add(meta);
  }
  all.sort(_cmpPostMeta);
  final total = all.length;
  final start = offset.clamp(0, total);
  final end = (start + limit).clamp(0, total);
  return (all.sublist(start, end), broken, total);
}

bool saveForumPost(ForumPost p) {
  ensureDir(forumDir);
  return writeTextFile(forumPath(p.id), jsonEncode(p.toJson()));
}

bool deleteForumPostFile(String id) {
  final sid = sanitizeId(id);
  if (sid.isEmpty) return false;
  final path = forumPath(sid);
  try {
    if (File(path).existsSync()) {
      File(path).deleteSync();
      return true;
    }
    return false;
  } catch (e) {
    logp('❌ 删除帖子失败: $e');
    return false;
  }
}

int deleteForumPosts(List<String> ids) {
  var n = 0;
  for (final id in ids) {
    if (deleteForumPostFile(id)) n++;
  }
  return n;
}

int clearAllForumPosts() {
  var n = 0;
  List<FileSystemEntity> files;
  try {
    files = Directory(forumDir).listSync();
  } catch (_) {
    return 0;
  }
  for (final f in files) {
    if (f is! File || !f.path.endsWith('.sts')) continue;
    try {
      f.deleteSync();
      n++;
    } catch (e) {
      logp('❌ 清空帖子失败: $e');
    }
  }
  return n;
}

// ------------------------------------------------------------
// GET /api/forum/posts   → 帖子列表（元数据 + 摘要，置顶优先）
// POST /api/forum/posts  → 创建或更新（body: {id?, title, content, author?}）
// ------------------------------------------------------------
Future<void> handleForumPosts(HttpRequest req) async {
  final res = req.response;

  switch (req.method) {
    case 'GET':
      final offset = int.tryParse(qp(req, 'offset')) ?? 0;
      final limit = (int.tryParse(qp(req, 'limit')) ?? 10).clamp(1, 100);
      final (posts, broken, total) = listForumPosts(offset: offset, limit: limit);
      await dsJSONOk(res, 200, {
        'success': true,
        'posts': posts,
        'broken': broken,
        'total': total,
        'offset': offset,
        'limit': limit,
        'hasMore': offset + posts.length < total,
        'dir': forumDir,
      });
      return;

    case 'POST':
      Map<String, dynamic> body;
      try {
        // 正文最大 500 万字，UTF-8 下最多约 20MB，放宽到 64MB 防滥用
        body = await readJsonBody(req, limit: 64 * 1024 * 1024);
      } catch (_) {
        await dsJSONErr(res, 400, '无效请求体');
        return;
      }
      final existingId = trimOr(mStr(body, 'id'), '');
      final title = mStr(body, 'title').trim();
      final content = mStr(body, 'content');
      final author = trimOr(mStr(body, 'author'), '匿名');

      if (title.isEmpty) {
        await dsJSONErr(res, 400, '标题不能为空');
        return;
      }
      if (runeLen(title) > FORUM_MAX_TITLE_RUNES) {
        await dsJSONErr(res, 400, '标题最多 $FORUM_MAX_TITLE_RUNES 字，当前 ${runeLen(title)} 字');
        return;
      }
      if (runeLen(content) > FORUM_MAX_CONTENT_RUNES) {
        await dsJSONErr(res, 400, '正文最多 $FORUM_MAX_CONTENT_RUNES 字，当前 ${runeLen(content)} 字');
        return;
      }

      final now = DateTime.now();

      if (existingId.isEmpty) {
        final id = 'post_${fmtStamp14(now)}_${randomHex(6)}';
        final p = ForumPost(
          id: id,
          title: title,
          content: content,
          author: author,
          createdAt: rfc3339(now),
          updatedAt: rfc3339(now),
        );
        if (!saveForumPost(p)) {
          await dsJSONErr(res, 500, '保存失败');
          return;
        }
        await dsJSONOk(res, 200, {'success': true, 'post': p.toJson()});
        return;
      }

      final sid = sanitizeId(existingId);
      if (sid.isEmpty) {
        await dsJSONErr(res, 400, '非法帖子 ID');
        return;
      }
      final existing = getForumPost(sid);
      if (existing == null) {
        await dsJSONErr(res, 404, '帖子不存在或文件异常');
        return;
      }
      final p = ForumPost(
        id: existing.id,
        title: title,
        content: content,
        author: author,
        createdAt: existing.createdAt,
        updatedAt: rfc3339(now),
        isPinned: existing.isPinned,
        isFeatured: existing.isFeatured,
        isBlocked: existing.isBlocked,
        isDeleted: false,
      );
      if (!saveForumPost(p)) {
        await dsJSONErr(res, 500, '保存失败');
        return;
      }
      await dsJSONOk(res, 200, {'success': true, 'post': p.toJson()});
      return;

    default:
      await dsJSONErr(res, 405, 'Method not allowed');
  }
}

// ------------------------------------------------------------
// GET /api/forum/posts/detail?id=xxx  → 单帖完整正文
// ------------------------------------------------------------
Future<void> handleForumPostDetail(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'GET') {
    await dsJSONErr(res, 405, 'Method not allowed');
    return;
  }
  final id = sanitizeId(qp(req, 'id'));
  if (id.isEmpty) {
    await dsJSONErr(res, 400, '缺少 id');
    return;
  }
  final p = getForumPost(id);
  if (p == null) {
    await dsJSONErr(res, 404, '帖子不存在或文件异常');
    return;
  }
  await dsJSONOk(res, 200, {'success': true, 'post': p.toJson()});
}

// ------------------------------------------------------------
// POST /api/forum/posts/action  → 置顶 / 加精 / 屏蔽
//   body: {id, action: pin|feature|block, value: bool}
// ------------------------------------------------------------
Future<void> handleForumAction(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'POST') {
    await dsJSONErr(res, 405, 'Method not allowed');
    return;
  }
  Map<String, dynamic> body;
  try {
    body = await readJsonBody(req);
  } catch (_) {
    await dsJSONErr(res, 400, '无效请求体');
    return;
  }
  final id = sanitizeId(mStr(body, 'id'));
  if (id.isEmpty) {
    await dsJSONErr(res, 400, '缺少 id');
    return;
  }
  final action = mStr(body, 'action');
  final value = mBool(body, 'value');

  final p = getForumPost(id);
  if (p == null) {
    await dsJSONErr(res, 404, '帖子不存在或文件异常');
    return;
  }

  var pinned = p.isPinned;
  var featured = p.isFeatured;
  var blocked = p.isBlocked;
  switch (action) {
    case 'pin':
      pinned = value;
      break;
    case 'feature':
      featured = value;
      break;
    case 'block':
      blocked = value;
      break;
    default:
      await dsJSONErr(res, 400, '未知操作');
      return;
  }

  // 状态切换不改变 updatedAt（仅内容/标题编辑才更新），避免打乱时间线
  final updated = ForumPost(
    id: p.id,
    title: p.title,
    content: p.content,
    author: p.author,
    createdAt: p.createdAt,
    updatedAt: p.updatedAt,
    isPinned: pinned,
    isFeatured: featured,
    isBlocked: blocked,
    isDeleted: false,
  );
  if (!saveForumPost(updated)) {
    await dsJSONErr(res, 500, '保存失败');
    return;
  }
  // 返回与列表一致的元数据（含摘要）——直接用内存中的 updated 构造，
  // 避免对超大正文文件重复读取
  final meta = <String, dynamic>{
    'id': updated.id,
    'title': updated.title,
    'author': updated.author,
    'createdAt': updated.createdAt,
    'updatedAt': updated.updatedAt,
    'isPinned': updated.isPinned,
    'isFeatured': updated.isFeatured,
    'isBlocked': updated.isBlocked,
    'isDeleted': updated.isDeleted,
    'summary': _summary(updated.content),
  };
  await dsJSONOk(res, 200, {'success': true, 'post': meta});
}

// ------------------------------------------------------------
// 删除：单删 / 批量删除
//   DELETE /api/forum/posts/delete?id=xxx
//   POST   /api/forum/posts/delete  body: {ids:[...]}
// ------------------------------------------------------------
Future<void> handleForumDelete(HttpRequest req) async {
  final res = req.response;

  if (req.method == 'DELETE') {
    final id = sanitizeId(qp(req, 'id'));
    if (id.isEmpty) {
      await dsJSONErr(res, 400, '缺少 id');
      return;
    }
    final ok = deleteForumPostFile(id);
    await dsJSONOk(res, 200, {'success': ok, 'deleted': ok ? 1 : 0});
    return;
  }

  if (req.method == 'POST') {
    Map<String, dynamic> body;
    try {
      body = await readJsonBody(req);
    } catch (_) {
      await dsJSONErr(res, 400, '无效请求体');
      return;
    }
    final ids = asList(body['ids']).map((e) => '$e').toList();
    if (ids.isEmpty) {
      await dsJSONErr(res, 400, '缺少要删除的帖子');
      return;
    }
    final n = deleteForumPosts(ids);
    await dsJSONOk(res, 200, {'success': true, 'deleted': n});
    return;
  }

  await dsJSONErr(res, 405, 'Method not allowed');
}

// ------------------------------------------------------------
// POST /api/forum/posts/clear  → 全部删除（不可恢复）
// ------------------------------------------------------------
Future<void> handleForumClear(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'POST') {
    await dsJSONErr(res, 405, 'Method not allowed');
    return;
  }
  final n = clearAllForumPosts();
  await dsJSONOk(res, 200, {'success': true, 'deleted': n});
}
