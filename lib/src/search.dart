// ============================================================
// search.dart —— 会话全文搜索（内存缓存 + 游标分页）
// 100% 对齐 Go 版 ds-search.go
// ============================================================

import 'dart:io';

import 'ds_crypto.dart';
import 'globals.dart';
import 'httpsrv.dart';
import 'sessions.dart';

const int DsSearchSnippetMax = 300;
const int DsSearchQueryMax = 500;
const int DsSearchLimitMax = 200;
const int DsSearchLimitDef = 50;

class DsSearchHit {
  final String sessionId;
  final String title;
  final String messageId;
  final String role;
  final String snippet;
  final bool truncated;
  final String time;

  DsSearchHit({
    required this.sessionId,
    required this.title,
    required this.messageId,
    required this.role,
    required this.snippet,
    required this.truncated,
    required this.time,
  });

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'title': title,
        'messageId': messageId,
        'role': role,
        'snippet': snippet,
        'truncated': truncated,
        'time': time,
      };
}

class _CacheEntry {
  final DateTime modTime;
  final int size;
  final DsSession sess;
  final List<DsMessage> msgs;
  _CacheEntry(this.modTime, this.size, this.sess, this.msgs);
}

final Map<String, _CacheEntry> _searchCache = {};

List<_CacheEntry> _loadSessions() {
  List<FileSystemEntity> files;
  try {
    files = Directory(dsSessionsDir).listSync();
  } catch (_) {
    return [];
  }
  final currentPaths = <String>{};
  final entries = <_CacheEntry>[];
  for (final f in files) {
    if (f is! File || !f.path.endsWith('.sts')) continue;
    final path = f.path;
    currentPaths.add(path);
    FileStat st;
    try {
      st = f.statSync();
    } catch (_) {
      continue;
    }
    final cached = _searchCache[path];
    if (cached != null &&
        cached.modTime == st.modified &&
        cached.size == st.size) {
      entries.add(cached);
      continue;
    }
    final sf = readDsSessionFile(path);
    if (sf.session == null) continue;
    final entry = _CacheEntry(st.modified, st.size, sf.session!, sf.messages);
    _searchCache[path] = entry;
    entries.add(entry);
  }
  _searchCache.removeWhere((k, _) => !currentPaths.contains(k));
  return entries;
}

void invalidateDsSearchCache() => _searchCache.clear();

({String snippet, bool truncated}) dsSnippetOf(String text, String ql) {
  final runes = text.runes.toList();
  if (runes.length <= DsSearchSnippetMax) return (snippet: text, truncated: false);
  final lower = text.toLowerCase();
  final byteIdx = lower.indexOf(ql);
  if (byteIdx < 0) {
    return (
      snippet: String.fromCharCodes(runes.sublist(0, DsSearchSnippetMax)),
      truncated: true
    );
  }
  final runeIdx = text.substring(0, byteIdx).runes.length;
  final half = DsSearchSnippetMax ~/ 2;
  var start = runeIdx - half;
  if (start < 0) start = 0;
  var end = start + DsSearchSnippetMax;
  if (end > runes.length) {
    end = runes.length;
    start = end - DsSearchSnippetMax;
    if (start < 0) start = 0;
  }
  final prefix = start > 0 ? '…' : '';
  final suffix = end < runes.length ? '…' : '';
  return (
    snippet:
        '$prefix${String.fromCharCodes(runes.sublist(start, end))}$suffix',
    truncated: true
  );
}

int _parseIntDefault(String s, int def) {
  if (s.isEmpty) return def;
  final n = int.tryParse(s);
  return n ?? def;
}

Future<void> handleDsChatSearch(HttpRequest req) async {
  final res = req.response;
  res.headers.set('Content-Type', 'application/json; charset=utf-8');
  res.headers.set('Cache-Control', 'no-store');
  if (req.method != 'GET') {
    await dsJSONErr(res, 405, 'Method not allowed');
    return;
  }

  var q = (qp(req, 'q')).trim();
  if (runeLen(q) > DsSearchQueryMax) {
    q = String.fromCharCodes(q.runes.toList().sublist(0, DsSearchQueryMax));
  }
  var party = qp(req, 'party');
  if (party != 'user' && party != 'assistant') party = 'all';

  var offset = _parseIntDefault(qp(req, 'offset'), 0);
  var limit =
      _parseIntDefault(qp(req, 'limit'), DsSearchLimitDef);
  if (limit <= 0) limit = DsSearchLimitDef;
  if (limit > DsSearchLimitMax) limit = DsSearchLimitMax;
  if (offset < 0) offset = 0;

  if (q.isEmpty) {
    await dsJSONOk(res, 200, {
      'ok': true,
      'query': '',
      'hits': <dynamic>[],
      'total': 0,
      'offset': 0,
      'limit': limit,
      'hasMore': false,
    });
    return;
  }

  final ql = q.toLowerCase();
  final entries = _loadSessions();
  final allHits = <DsSearchHit>[];

  for (final e in entries) {
    for (final m in e.msgs) {
      if (m.role != 'user' && m.role != 'assistant') continue;
      if (party == 'user' && m.role != 'user') continue;
      if (party == 'assistant' && m.role != 'assistant') continue;
      final content = m.content;
      if (content.isEmpty) continue;
      if (!content.toLowerCase().contains(ql)) continue;
      final sn = dsSnippetOf(content, ql);
      allHits.add(DsSearchHit(
        sessionId: e.sess.id,
        title: e.sess.title,
        messageId: m.id,
        role: m.role,
        snippet: sn.snippet,
        truncated: sn.truncated,
        time: m.createdAt,
      ));
    }
  }

  allHits.sort((a, b) => b.time.compareTo(a.time));

  final total = allHits.length;
  var start = offset;
  var end = offset + limit;
  if (start > total) start = total;
  if (end > total) end = total;
  final page = start <= end ? allHits.sublist(start, end) : <DsSearchHit>[];

  await dsJSONOk(res, 200, {
    'ok': true,
    'query': q,
    'hits': page.map((h) => h.toJson()).toList(),
    'total': total,
    'offset': offset,
    'limit': limit,
    'hasMore': end < total,
  });
}
