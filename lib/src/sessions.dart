// ============================================================
// sessions.dart —— DeepSeek 会话 / 消息的 .sts 单文件存储
//
// 文件格式（与 Go 版逐字节一致，保证历史数据 100% 兼容）：
//   #S|id|title|createdAt|updatedAt
//   #M|id|role|content|createdAt|attachments|reasoning|usage
// ============================================================

import 'dart:convert';
import 'dart:io';

import 'ds_crypto.dart';
import 'ds_usage.dart';
import 'files.dart';
import 'globals.dart';

const int DS_MAX_OUTPUT_TOKENS = 120000;
const int DS_NORMAL_OUTPUT_TOKENS = 8192;
const int DS_TARGET_CHARS_5M = 5000000;
const int DS_TTS_MAX_RUNES = 1000000;
const int DS_TTS_CHUNK_RUNES = 2500;
const int DS_TTS_CHUNK_HARD_MAX = 2900;
const int DS_NOVEL_DEFAULT_CHARS = 30000;
const int DS_NOVEL_CHUNK_CHARS = 20000;
const int DS_NOVEL_MAX_ROUNDS = 1000;
const int DS_NOVEL_MIN_CHARS = 10000;
const int DS_NOVEL_MAX_CHARS = 1000000;
const int DS_MAX_HISTORY_MSGS = 1000000;
const int DS_MAX_HISTORY_CHARS = 10000000;
const int DS_MSG_PAGE_SIZE = 40;
const int DS_REASONING_PREVIEW = 2000;
const int DS_TOOL_MAX_ITERATIONS = 5000000000;

class DsSession {
  String id;
  String title;
  String createdAt;
  String updatedAt;

  DsSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };
}

class DsMessage {
  String id;
  String sessionId;
  String role;
  String content;
  String createdAt;
  String attachments;
  String reasoning;
  bool reasoningTruncated;
  DsTokenUsage? usage;

  DsMessage({
    required this.id,
    this.sessionId = '',
    required this.role,
    required this.content,
    required this.createdAt,
    this.attachments = '',
    this.reasoning = '',
    this.reasoningTruncated = false,
    this.usage,
  });

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'id': id,
      'sessionId': sessionId,
      'role': role,
      'content': content,
      'createdAt': createdAt,
    };
    if (attachments.isNotEmpty) m['attachments'] = attachments;
    if (reasoning.isNotEmpty) m['reasoning'] = reasoning;
    if (reasoningTruncated) m['reasoningTruncated'] = true;
    if (usage != null) m['usage'] = usage!.toJson();
    return m;
  }
}

void initDsChatDir() {
  ensureDir(dsChatDir);
  ensureDir(dsSessionsDir);
}

String dsSessionPath(String id) {
  var safe = id
      .replaceAll('/', '_')
      .replaceAll('\\', '_')
      .replaceAll('..', '_')
      .replaceAll('|', '_')
      .replaceAll(':', '_');
  return '$dsSessionsDir/$safe.sts';
}

// ------------------------------------------------------------
// 读取
// ------------------------------------------------------------
class SessionFile {
  final DsSession? session;
  final List<DsMessage> messages;
  const SessionFile(this.session, this.messages);
}

SessionFile readDsSessionFile(String path) {
  String data;
  try {
    data = File(path).readAsStringSync();
  } catch (_) {
    return const SessionFile(null, []);
  }
  DsSession? sess;
  final msgs = <DsMessage>[];
  for (final rawLine in data.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#S|')) {
      final parts = line.substring(3).split('|');
      if (parts.length < 4) continue;
      sess = DsSession(
        id: parts[0],
        title: unescDs(parts[1]),
        createdAt: parts[2],
        updatedAt: parts[3],
      );
    } else if (line.startsWith('#M|')) {
      final parts = line.substring(3).split('|');
      if (parts.length < 4) continue;
      final att = parts.length >= 5 ? parts[4] : '';
      final rea = parts.length >= 6 ? unescDs(parts[5]) : '';
      msgs.add(DsMessage(
        id: parts[0],
        role: parts[1],
        content: unescDs(parts[2]),
        createdAt: parts[3],
        attachments: att,
        reasoning: rea,
        usage: dsParseUsageField(parts),
      ));
    }
  }
  return SessionFile(sess, msgs);
}

DsMessage? parseDsMessageLine(String line) {
  final t = line.trim();
  if (!t.startsWith('#M|')) return null;
  final parts = t.substring(3).split('|');
  if (parts.length < 4) return null;
  return DsMessage(
    id: parts[0],
    role: parts[1],
    content: unescDs(parts[2]),
    createdAt: parts[3],
    attachments: parts.length >= 5 ? parts[4] : '',
    reasoning: parts.length >= 6 ? unescDs(parts[5]) : '',
    usage: dsParseUsageField(parts),
  );
}

/// 从文件末尾高效读取最近 limit 条消息（秒开长会话）
class TailResult {
  final List<DsMessage> messages;
  final bool hasMore;
  const TailResult(this.messages, this.hasMore);
}

TailResult readDsSessionTailMsgs(String path, int limit) {
  RandomAccessFile raf;
  try {
    raf = File(path).openSync();
  } catch (_) {
    return const TailResult([], false);
  }
  try {
    final size = raf.lengthSync();
    if (size == 0) return const TailResult([], false);
    if (limit <= 0) limit = DS_MSG_PAGE_SIZE;

    const blockSize = 64 * 1024;
    var tail = <int>[];
    var offset = size;
    int countNewlines(List<int> b) {
      var n = 0;
      for (final c in b) {
        if (c == 0x0A) n++;
      }
      return n;
    }

    final needLines = limit + 2;
    while (offset > 0 && countNewlines(tail) < needLines) {
      var readSize = blockSize;
      if (offset < readSize) readSize = offset.toInt();
      offset -= readSize;
      raf.setPositionSync(offset);
      final chunk = raf.readSync(readSize);
      tail = [...chunk, ...tail];
    }

    var lines = utf8.decode(tail, allowMalformed: true).split('\n');
    if (offset > 0 && lines.isNotEmpty) {
      lines = lines.sublist(1); // 首行可能被截断
    }
    final msgs = <DsMessage>[];
    for (final ln in lines) {
      final m = parseDsMessageLine(ln);
      if (m != null) msgs.add(m);
    }
    var hasMore = false;
    if (msgs.length > limit) {
      final sliced = msgs.sublist(msgs.length - limit);
      return TailResult(sliced, true);
    }
    return TailResult(msgs, hasMore);
  } finally {
    try {
      raf.closeSync();
    } catch (_) {}
  }
}

(String, bool) truncateReasoning(String s, int max) {
  final r = s.runes.toList();
  if (r.length <= max) return (s, false);
  return (String.fromCharCodes(r.sublist(0, max)), true);
}

// ------------------------------------------------------------
// 写入
// ------------------------------------------------------------
bool saveDsSession(DsSession sess) {
  final path = dsSessionPath(sess.id);
  if (File(path).existsSync()) {
    logp('⚠️ セッションは既に存在します: ${sess.id}');
    return false;
  }
  final line =
      '#S|${sess.id}|${escDs(sess.title)}|${sess.createdAt}|${sess.updatedAt}\n';
  ensureDir(dsSessionsDir);
  return writeTextFile(path, line);
}

bool updateDsSession(String id, String newTitle, String updatedAt) {
  final path = dsSessionPath(id);
  String data;
  try {
    data = File(path).readAsStringSync();
  } catch (_) {
    return false;
  }
  final lines = data.split('\n');
  var changed = false;
  for (var i = 0; i < lines.length; i++) {
    final trimmed = lines[i].trim();
    if (!trimmed.startsWith('#S|')) continue;
    final parts = trimmed.substring(3).split('|');
    if (parts.length < 4) continue;
    if (parts[0] == id) {
      lines[i] = '#S|${parts[0]}|${escDs(newTitle)}|${parts[2]}|$updatedAt';
      changed = true;
      break;
    }
  }
  if (changed) return writeTextFile(path, lines.join('\n'));
  return false;
}

bool appendDsMessage(DsMessage m) {
  final path = dsSessionPath(m.sessionId);
  if (!File(path).existsSync()) {
    logp('⚠️ セッションファイルが存在しません: ${m.sessionId}');
    return false;
  }
  final line = '#M|${m.id}|${m.role}|${escDs(m.content)}|${m.createdAt}|'
      '${m.attachments}|${escDs(m.reasoning)}|${dsEncodeUsageField(m.usage)}\n';
  try {
    File(path).writeAsStringSync(line, mode: FileMode.append);
    invalidateDsSessionCaches(path);
    return true;
  } catch (e) {
    logp('❌ メッセージの追加に失敗しました: $e');
    return false;
  }
}

DsMessage? updateDsMessageContent(String sessionID, String msgID,
    String newContent, String newReasoning, DsTokenUsage? addUsage) {
  if (sessionID.trim().isEmpty || msgID.trim().isEmpty) return null;
  final path = dsSessionPath(sessionID);
  String data;
  try {
    data = File(path).readAsStringSync();
  } catch (_) {
    return null;
  }
  final lines = data.split('\n');
  DsMessage? out;
  for (var i = 0; i < lines.length; i++) {
    final trimmed = lines[i].trim();
    if (!trimmed.startsWith('#M|')) continue;
    final parts = trimmed.substring(3).split('|');
    if (parts.length < 4 || parts[0] != msgID) continue;
    final att = parts.length >= 5 ? parts[4] : '';
    final created = parts[3];
    final mergedUsage = dsMergeUsage(dsParseUsageField(parts), addUsage);
    lines[i] = '#M|${parts[0]}|${parts[1]}|${escDs(newContent)}|$created|$att|'
        '${escDs(newReasoning)}|${dsEncodeUsageField(mergedUsage)}';
    out = DsMessage(
      id: parts[0],
      sessionId: sessionID,
      role: parts[1],
      content: newContent,
      createdAt: created,
      attachments: att,
      reasoning: newReasoning,
      usage: mergedUsage,
    );
    break;
  }
  if (out == null) return null;
  final tmp = '$path.tmp';
  if (!writeTextFile(tmp, lines.join('\n'))) return null;
  try {
    File(tmp).renameSync(path);
    invalidateDsSessionCaches(path);
  } catch (e) {
    logp('❌ 一時ファイルの名前変更に失敗しました: $e');
    return null;
  }
  return out;
}

// ------------------------------------------------------------
// 查询
// ------------------------------------------------------------
List<String> collectSessionAttachments(String path) {
  final f = readDsSessionFile(path);
  final seen = <String>{};
  final out = <String>[];
  for (final m in f.messages) {
    if (m.attachments.isEmpty) continue;
    for (var fid in m.attachments.split(',')) {
      fid = fid.trim();
      if (fid.isNotEmpty && !seen.contains(fid)) {
        seen.add(fid);
        out.add(fid);
      }
    }
  }
  return out;
}

Set<String> collectAttachmentsInUse() {
  final used = <String>{};
  List<FileSystemEntity> files;
  try {
    files = Directory(dsSessionsDir).listSync();
  } catch (_) {
    return used;
  }
  for (final f in files) {
    if (f is! File || !f.path.endsWith('.sts')) continue;
    for (final fid in collectSessionAttachments(f.path)) {
      used.add(fid);
    }
  }
  return used;
}

// ------------------------------------------------------------
// 极速读取层（会话头 + 消息列表的进程内缓存）
//   设计目标：会话条数再多、单个会话文件再大，列表与翻页请求的
//   磁盘开销都恒定为「stat + 首块读取」，不再每次都把整份 .sts
//   读进内存重新解析（旧实现是 O(总字节数)，数据一多必卡）。
//   失效策略：以 (size, mtimeMs) 双校验，外部改写文件立即感知；
//   写路径（追加/更新/删除）主动 invalidate。
// ------------------------------------------------------------
class _DsHeaderEntry {
  final int size;
  final int mtimeMs;
  final DsSession? sess;
  const _DsHeaderEntry(this.size, this.mtimeMs, this.sess);
}

class _DsMsgsEntry {
  final int size;
  final int mtimeMs;
  final List<DsMessage> msgs;
  final int chars;
  const _DsMsgsEntry(this.size, this.mtimeMs, this.msgs, this.chars);
}

final Map<String, _DsHeaderEntry> _dsHeaderCache = <String, _DsHeaderEntry>{};
final Map<String, _DsMsgsEntry> _dsMsgsCache = <String, _DsMsgsEntry>{};
int _dsMsgsCacheChars = 0;
const int _DS_MSGS_CACHE_MAX_ENTRIES = 12;
const int _DS_MSGS_CACHE_MAX_CHARS = 24 * 1024 * 1024;
const int _DS_HEAD_READ_BYTES = 8192;

DsSession? _parseDsSessLine(String line) {
  if (!line.startsWith('#S|')) return null;
  final parts = line.substring(3).split('|');
  if (parts.length < 4) return null;
  return DsSession(
    id: parts[0],
    title: unescDs(parts[1]),
    createdAt: parts[2],
    updatedAt: parts[3],
  );
}

/// 只读文件首块（≤8KB）解析 #S 头行：单文件哪怕几百 MB 也是常数开销
DsSession? readDsSessionHeaderFast(String path) {
  final f = File(path);
  int size;
  int mtimeMs;
  try {
    final st = f.statSync();
    size = st.size;
    mtimeMs = st.modified.millisecondsSinceEpoch;
  } catch (_) {
    _dsHeaderCache.remove(path);
    return null;
  }
  final cached = _dsHeaderCache[path];
  if (cached != null && cached.size == size && cached.mtimeMs == mtimeMs) {
    return cached.sess;
  }
  DsSession? sess;
  try {
    final raf = f.openSync();
    try {
      final head = raf.readSync(size < _DS_HEAD_READ_BYTES ? size : _DS_HEAD_READ_BYTES);
      final text = utf8.decode(head, allowMalformed: true);
      for (final raw in text.split('\n')) {
        final line = raw.trim();
        if (line.startsWith('#S|')) {
          sess = _parseDsSessLine(line);
          break;
        }
        if (line.startsWith('#M|')) break; // 头行必在最前，遇到消息行即停止
      }
    } finally {
      raf.closeSync();
    }
  } catch (_) {}
  _dsHeaderCache[path] = _DsHeaderEntry(size, mtimeMs, sess);
  return sess;
}

void invalidateDsSessionCaches(String path) {
  _dsHeaderCache.remove(path);
  final old = _dsMsgsCache.remove(path);
  if (old != null) _dsMsgsCacheChars -= old.chars;
}

void invalidateAllDsSessionCaches() {
  _dsHeaderCache.clear();
  _dsMsgsCache.clear();
  _dsMsgsCacheChars = 0;
}

void _putDsMsgsCache(String path, int size, int mtimeMs, List<DsMessage> msgs) {
  final old = _dsMsgsCache.remove(path);
  if (old != null) _dsMsgsCacheChars -= old.chars;
  var chars = 0;
  for (final m in msgs) {
    chars += m.content.length + m.reasoning.length + 32;
  }
  _dsMsgsCache[path] = _DsMsgsEntry(size, mtimeMs, msgs, chars);
  _dsMsgsCacheChars += chars;
  while (_dsMsgsCache.length > _DS_MSGS_CACHE_MAX_ENTRIES) {
    final k = _dsMsgsCache.keys.first;
    final removed = _dsMsgsCache.remove(k);
    if (removed != null) _dsMsgsCacheChars -= removed.chars;
  }
  while (_dsMsgsCacheChars > _DS_MSGS_CACHE_MAX_CHARS && _dsMsgsCache.length > 1) {
    final k = _dsMsgsCache.keys.first;
    final removed = _dsMsgsCache.remove(k);
    if (removed != null) _dsMsgsCacheChars -= removed.chars;
  }
}

List<DsSession> getAllDsSessions() {
  List<FileSystemEntity> files;
  try {
    files = Directory(dsSessionsDir).listSync();
  } catch (_) {
    return [];
  }
  final sessions = <DsSession>[];
  for (final f in files) {
    if (f is! File || !f.path.endsWith('.sts')) continue;
    final sess = readDsSessionHeaderFast(f.path);
    if (sess == null) continue;
    sessions.add(sess);
  }
  sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return sessions;
}

DsSession? getDsSession(String id) => readDsSessionHeaderFast(dsSessionPath(id));

/// 返回的消息列表可能是缓存对象，调用方只读、不得就地修改字段
List<DsMessage> getDsMessages(String sessionID) {
  final path = dsSessionPath(sessionID);
  int? size;
  int? mtimeMs;
  try {
    final st = File(path).statSync();
    size = st.size;
    mtimeMs = st.modified.millisecondsSinceEpoch;
  } catch (_) {
    size = null;
    mtimeMs = null;
  }
  if (size != null && mtimeMs != null) {
    final c = _dsMsgsCache[path];
    if (c != null && c.size == size && c.mtimeMs == mtimeMs) return c.msgs;
  }
  final sf = readDsSessionFile(path);
  for (final m in sf.messages) {
    m.sessionId = sessionID;
  }
  if (size != null && mtimeMs != null) {
    _putDsMsgsCache(path, size, mtimeMs, sf.messages);
  }
  return sf.messages;
}

List<DsMessage> pickHistoryWindow(List<DsMessage> history) {
  final selected = <DsMessage>[];
  var totalChars = 0;
  for (var i = history.length - 1; i >= 0; i--) {
    final m = history[i];
    if (m.role != 'user' && m.role != 'assistant' && m.role != 'system') continue;
    final cl = runeLen(m.content);
    if (selected.length >= DS_MAX_HISTORY_MSGS) break;
    if (totalChars + cl > DS_MAX_HISTORY_CHARS && selected.isNotEmpty) break;
    selected.insert(0, m);
    totalChars += cl;
  }
  return selected;
}

bool deleteDsSessionRaw(String id) {
  final path = dsSessionPath(id);
  try {
    if (File(path).existsSync()) File(path).deleteSync();
    invalidateDsSessionCaches(path);
    return true;
  } catch (e) {
    logp('❌ セッションファイルの削除に失敗しました: $e');
    return false;
  }
}

void deleteDsSession(String id) {
  if (id.isEmpty) return;
  final path = dsSessionPath(id);
  final attachments = collectSessionAttachments(path);
  logp('🗑️ セッション $id を削除しました。関連添付 ${attachments.length} 件');
  deleteDsSessionRaw(id);
  if (attachments.isNotEmpty) {
    final stillUsed = collectAttachmentsInUse();
    for (final fid in attachments) {
      if (!stillUsed.contains(fid)) {
        deleteDsFileMeta(fid);
        logp('🗑️ 添付ファイルを削除しました: $fid');
      }
    }
  }
  cleanupOrphanFiles();
}

void cleanupOrphanFiles() {
  final used = collectAttachmentsInUse();
  final all = getAllDsFiles();
  if (all.isEmpty) return;
  final cutoff = DateTime.now().subtract(DS_ORPHAN_GRACE_PERIOD);
  for (final f in all) {
    if (used.contains(f.id)) continue;
    final created = DateTime.tryParse(f.createdAt);
    if (created != null && created.isAfter(cutoff)) continue;
    logp('🗑️ 清理孤立文件: ${f.id} (${f.name})');
    deleteDsFileMeta(f.id);
  }
}

// ------------------------------------------------------------
// 旧版存储迁移（ds_chat_*.sts / ds_msg_*.sts → 单会话文件）
// ------------------------------------------------------------
void migrateDsChatToPerSession() {
  List<FileSystemEntity> files;
  try {
    files = Directory(dsChatDir).listSync();
  } catch (_) {
    return;
  }
  // 注意：ds_chat_config.sts 是「加密配置」，不是旧会话文件，必须排除，
  // 否则首次启动会把配置误当会话迁移并改名（会造成配置丢失）。
  bool isOldChat(String name) =>
      name != 'ds_chat_config.sts' &&
      name.startsWith('ds_chat_') &&
      name.endsWith('.sts') &&
      !name.endsWith('.bak') &&
      !name.endsWith('.migrated_bak');
  bool isOldMsg(String name) =>
      name.startsWith('ds_msg_') &&
      name.endsWith('.sts') &&
      !name.endsWith('.bak') &&
      !name.endsWith('.migrated_bak');

  var hasOldChat = false;
  var hasOldMsg = false;
  for (final f in files) {
    if (f is! File) continue;
    final name = f.uri.pathSegments.last;
    if (isOldChat(name)) hasOldChat = true;
    if (isOldMsg(name)) hasOldMsg = true;
  }
  if (!hasOldChat && !hasOldMsg) return;

  logp('🔄 旧形式のセッション保存を検出しました。単一ファイル方式へ移行を開始します...');
  final oldSessions = <DsSession>[];
  for (final f in files) {
    if (f is! File) continue;
    final name = f.uri.pathSegments.last;
    if (!isOldChat(name)) continue;
    String data;
    try {
      data = f.readAsStringSync();
    } catch (_) {
      continue;
    }
    for (var line in data.split('\n')) {
      line = line.trim();
      if (line.isEmpty) continue;
      final parts = line.split('|');
      if (parts.length < 4) continue;
      if (!parts[0].startsWith('dsc_')) continue;
      oldSessions.add(DsSession(
        id: parts[0],
        title: unescDs(parts[1]),
        createdAt: parts[2],
        updatedAt: parts[3],
      ));
    }
  }

  final oldMessages = <DsMessage>[];
  for (final f in files) {
    if (f is! File) continue;
    final name = f.uri.pathSegments.last;
    if (!isOldMsg(name)) continue;
    String data;
    try {
      data = f.readAsStringSync();
    } catch (_) {
      continue;
    }
    for (var line in data.split('\n')) {
      line = line.trim();
      if (line.isEmpty) continue;
      final parts = line.split('|');
      if (parts.length < 5) continue;
      oldMessages.add(DsMessage(
        id: parts[0],
        sessionId: parts[1],
        role: parts[2],
        content: unescDs(parts[3]),
        createdAt: parts[4],
        attachments: parts.length >= 6 ? parts[5] : '',
        reasoning: parts.length >= 7 ? unescDs(parts[6]) : '',
      ));
    }
  }

  final bySess = <String, List<DsMessage>>{};
  for (final m in oldMessages) {
    bySess.putIfAbsent(m.sessionId, () => []).add(m);
  }
  for (final k in bySess.keys) {
    bySess[k]!.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  var count = 0;
  for (final sess in oldSessions) {
    final path = dsSessionPath(sess.id);
    final lines = <String>[
      '#S|${sess.id}|${escDs(sess.title)}|${sess.createdAt}|${sess.updatedAt}'
    ];
    for (final m in bySess[sess.id] ?? const <DsMessage>[]) {
      lines.add('#M|${m.id}|${m.role}|${escDs(m.content)}|${m.createdAt}|'
          '${m.attachments}|${escDs(m.reasoning)}');
    }
    var content = lines.join('\n');
    if (content.isNotEmpty) content += '\n';
    if (writeTextFile(path, content)) count++;
  }

  for (final f in files) {
    if (f is! File) continue;
    final name = f.uri.pathSegments.last;
    if (isOldChat(name) || isOldMsg(name)) {
      try {
        f.renameSync('${f.path}.migrated_bak');
      } catch (_) {}
    }
  }
  invalidateAllDsSessionCaches();
  logp('✅ 移行完了: 全 $count セッション');
}

// ------------------------------------------------------------
// 推理等级 → 参数
// ------------------------------------------------------------
class LevelParams {
  final int maxTokens;
  final double temperature;
  final int rounds;
  const LevelParams(this.maxTokens, this.temperature, this.rounds);
}

LevelParams levelToParams(int level) {
  var l = level;
  if (l < 1) l = 1;
  if (l > 50) l = 50;
  final maxTokens = DS_NORMAL_OUTPUT_TOKENS +
      (l - 1) * (DS_MAX_OUTPUT_TOKENS - DS_NORMAL_OUTPUT_TOKENS) ~/ 49;
  final temperature = 1.0 - (l - 1) * 0.9 / 49.0;
  int rounds;
  if (l <= 10) {
    rounds = 1;
  } else if (l <= 25) {
    rounds = 2;
  } else if (l <= 40) {
    rounds = 3;
  } else {
    rounds = 4;
  }
  return LevelParams(maxTokens, temperature, rounds);
}

/// 续写合并：削掉重叠衔接部分
String mergeContinuation(String base, String add) {
  if (add.isEmpty) return base;
  final b = base.runes.toList();
  final a = add.runes.toList();
  if (b.isEmpty) return add;
  var maxOverlap = b.length;
  if (maxOverlap > 400) maxOverlap = 400;
  if (a.length < maxOverlap) maxOverlap = a.length;
  for (var n = maxOverlap; n >= 8; n--) {
    final bs = String.fromCharCodes(b.sublist(b.length - n));
    final as = String.fromCharCodes(a.sublist(0, n));
    if (bs == as) {
      return base + String.fromCharCodes(a.sublist(n));
    }
  }
  return base + add;
}
