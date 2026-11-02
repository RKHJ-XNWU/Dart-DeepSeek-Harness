// ============================================================
// xtweet.dart —— X (Twitter) 推文高速抓取（多后端并发竞速）
// 100% 对齐 Go 版 xtweet.go
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'globals.dart';
import 'httpsrv.dart';
import 'net.dart';

class XTweet {
  String id;
  String url;
  String text;
  String author;
  String authorName;
  String createdAt;
  List<String> media;
  int likes;
  int retweets;
  int replies;

  XTweet({
    this.id = '',
    this.url = '',
    this.text = '',
    this.author = '',
    this.authorName = '',
    this.createdAt = '',
    List<String>? media,
    this.likes = 0,
    this.retweets = 0,
    this.replies = 0,
  }) : media = media ?? [];

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'id': id,
      'url': url,
      'text': text,
      'author': author,
      'author_name': authorName,
    };
    if (createdAt.isNotEmpty) m['created_at'] = createdAt;
    if (media.isNotEmpty) m['media'] = media;
    if (likes != 0) m['likes'] = likes;
    if (retweets != 0) m['retweets'] = retweets;
    if (replies != 0) m['replies'] = replies;
    return m;
  }
}

// ------------------------------------------------------------
// 缓存
// ------------------------------------------------------------
class _XCacheEntry {
  final List<XTweet> tweets;
  final DateTime at;
  _XCacheEntry(this.tweets, this.at);
}

final Map<String, _XCacheEntry> _xCache = {};
const Duration _xCacheTTL = Duration(seconds: 90);

List<XTweet>? xCacheGet(String key) {
  final e = _xCache[key];
  if (e != null && DateTime.now().difference(e.at) < _xCacheTTL) {
    return e.tweets;
  }
  return null;
}

void xCacheSet(String key, List<XTweet> tweets) {
  _xCache[key] = _XCacheEntry(tweets, DateTime.now());
  if (_xCache.length > 4096) _xCache.clear();
}

// ------------------------------------------------------------
// 抓取基础
// ------------------------------------------------------------
const Duration xReqTimeout = Duration(seconds: 8);
const Duration xTotalTimeout = Duration(seconds: 40);
const int xMaxBody = 8 << 20;

Future<List<int>> xFetch(String rawurl,
    {Duration timeout = xReqTimeout}) async {
  final client = globalHTTPClient;
  final req = await client.getUrl(Uri.parse(rawurl)).timeout(timeout);
  req.headers.set('User-Agent', 'Mozilla/5.0 (compatible; jpwords-x/1.0)');
  req.headers
      .set('Accept', 'application/json, text/html;q=0.9, */*;q=0.8');
  final resp = await req.close().timeout(timeout);
  if (resp.statusCode != 200) {
    throw Exception('HTTP ${resp.statusCode}');
  }
  final out = <int>[];
  await for (final chunk in resp.timeout(timeout)) {
    out.addAll(chunk);
    if (out.length > xMaxBody) break;
  }
  return out;
}

class XSource {
  final String url;
  final Future<List<XTweet>> Function(List<int>) parse;
  XSource(this.url, this.parse);
}

/// 多源并发竞速：先到先得
Future<List<XTweet>> xRace(List<XSource> sources) async {
  if (sources.isEmpty) throw Exception('无可用后端');
  final completer = Completer<List<XTweet>>();
  var pending = sources.length;
  Object? lastErr;

  for (final s in sources) {
    () async {
      try {
        final body = await xFetch(s.url);
        final tweets = await s.parse(body);
        if (tweets.isNotEmpty && !completer.isCompleted) {
          completer.complete(tweets);
        }
      } catch (e) {
        lastErr = e;
      } finally {
        pending--;
        if (pending == 0 && !completer.isCompleted) {
          completer.completeError(lastErr ?? Exception('所有后端均未返回数据'));
        }
      }
    }();
  }
  return completer.future.timeout(xTotalTimeout,
      onTimeout: () => throw Exception('取得がタイムアウトしました'));
}

const List<String> xNitterInstances = [
  'https://nitter.net',
  'https://nitter.poast.org',
  'https://nitter.privacyredirect.com',
  'https://lightbrd.com',
];

List<XSource> xTweetSources(String id) => [
      XSource('https://api.fxtwitter.com/i/status/$id', parseFxDoc),
      XSource('https://api.vxtwitter.com/i/status/$id', parseFxDoc),
      XSource('https://api.fixupx.com/tweet/$id', parseFxDoc),
      XSource('https://cdn.syndication.twimg.com/tweet-result?id=$id&lang=ja',
          parseSyndication),
    ];

List<XSource> xTimelineSources(String name) {
  final srcs = <XSource>[
    XSource('https://api.fxtwitter.com/$name', parseFxDoc),
    XSource('https://api.vxtwitter.com/$name', parseFxDoc),
    XSource('https://api.fixupx.com/user/$name', parseFxDoc),
  ];
  for (final inst in xNitterInstances) {
    srcs.add(XSource('$inst/$name', parseNitterTimeline));
  }
  return srcs;
}

// ------------------------------------------------------------
// 解析器
// ------------------------------------------------------------
String jsonStrOf(Map<String, dynamic> m, String key) {
  if (!m.containsKey(key)) return '';
  final v = m[key];
  if (v == null) return '';
  if (v is String) return v;
  if (v is num) {
    if (v == v.roundToDouble()) return '${v.toInt()}';
    return '$v';
  }
  return '$v';
}

Map<String, dynamic>? jsonMapOf(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is Map) return asMap(v);
  return null;
}

List<dynamic> jsonArrOf(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is List) return v;
  return const [];
}

int toInt64(dynamic v) {
  if (v is int) return v;
  if (v is double) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

XTweet tweetFromMap(
    Map<String, dynamic> t, String fallbackAuthor, String fallbackName) {
  final tw = XTweet(
    id: jsonStrOf(t, 'id'),
    url: jsonStrOf(t, 'url'),
    text: jsonStrOf(t, 'text'),
    createdAt: jsonStrOf(t, 'created_at'),
    likes: toInt64(t['likes']),
    retweets: toInt64(t['retweets']),
    replies: toInt64(t['replies']),
  );
  tw.author = fallbackAuthor;
  tw.authorName = fallbackName;

  final a = jsonMapOf(t, 'author');
  if (a != null) {
    final sn = jsonStrOf(a, 'screen_name');
    if (sn.isNotEmpty) tw.author = sn;
    final nm = jsonStrOf(a, 'name');
    if (nm.isNotEmpty) tw.authorName = nm;
  } else {
    final u = jsonMapOf(t, 'user');
    if (u != null) {
      final sn = jsonStrOf(u, 'screen_name');
      if (sn.isNotEmpty) tw.author = sn;
      final nm = jsonStrOf(u, 'name');
      if (nm.isNotEmpty) tw.authorName = nm;
    }
  }

  final media = jsonMapOf(t, 'media');
  if (media != null) {
    for (final p in jsonArrOf(media, 'photos')) {
      if (p is Map) {
        final u = jsonStrOf(asMap(p), 'url');
        if (u.isNotEmpty) tw.media.add(u);
      }
    }
    for (final v in jsonArrOf(media, 'videos')) {
      if (v is Map) {
        final vm = asMap(v);
        final u = jsonStrOf(vm, 'url');
        if (u.isNotEmpty) {
          tw.media.add(u);
        } else {
          final th = jsonStrOf(vm, 'thumbnailUrl');
          if (th.isNotEmpty) tw.media.add(th);
        }
      }
    }
  }
  if (tw.media.isEmpty) {
    final me = jsonMapOf(t, 'media_extended');
    if (me != null) {
      for (final p in jsonArrOf(me, 'media')) {
        if (p is Map) {
          final u = jsonStrOf(asMap(p), 'url');
          if (u.isNotEmpty) tw.media.add(u);
        }
      }
    }
  }

  if (tw.url.isEmpty && tw.id.isNotEmpty) {
    tw.url = tw.author.isNotEmpty
        ? 'https://twitter.com/${tw.author}/status/${tw.id}'
        : 'https://x.com/i/status/${tw.id}';
  }
  return tw;
}

Future<List<XTweet>> parseFxDoc(List<int> body) async {
  final root = asMap(jsonDecode(utf8.decode(body, allowMalformed: true)));
  var fallbackAuthor = '';
  var fallbackName = '';
  final u = jsonMapOf(root, 'user');
  if (u != null) {
    fallbackAuthor = jsonStrOf(u, 'screen_name');
    fallbackName = jsonStrOf(u, 'name');
  }
  final out = <XTweet>[];
  final arr = jsonArrOf(root, 'tweets');
  if (arr.isNotEmpty) {
    for (final item in arr) {
      if (item is Map) {
        out.add(tweetFromMap(asMap(item), fallbackAuthor, fallbackName));
      }
    }
  }
  final t = jsonMapOf(root, 'tweet');
  if (t != null) out.add(tweetFromMap(t, fallbackAuthor, fallbackName));
  if (out.isEmpty) {
    final s = jsonMapOf(root, 'status');
    if (s != null) out.add(tweetFromMap(s, fallbackAuthor, fallbackName));
  }
  if (out.isEmpty) throw Exception('未解析到推文');
  return out;
}

Future<List<XTweet>> parseSyndication(List<int> body) async {
  final root = asMap(jsonDecode(utf8.decode(body, allowMalformed: true)));
  var id = jsonStrOf(root, 'id_str');
  if (id.isEmpty) id = jsonStrOf(root, 'id');
  if (id.isEmpty) throw Exception('syndication 无 id');
  var author = '';
  var authorName = '';
  final u = jsonMapOf(root, 'user');
  if (u != null) {
    author = jsonStrOf(u, 'screen_name');
    authorName = jsonStrOf(u, 'name');
  }
  var text = jsonStrOf(root, 'full_text');
  if (text.isEmpty) text = jsonStrOf(root, 'text');
  if (text.isEmpty) throw Exception('syndication 无正文');
  return [
    XTweet(
      id: id,
      url: 'https://twitter.com/$author/status/$id',
      text: text,
      author: author,
      authorName: authorName,
      createdAt: jsonStrOf(root, 'created_at'),
    )
  ];
}

final RegExp _nitterLinkRe =
    RegExp(r'href="/[^/]+/status/(\d+)(?:#[^"]*)?"');
final RegExp _nitterBodyRe =
    RegExp(r'<div class="tweet-content[^"]*">(.*?)</div>', dotAll: true);
final RegExp _tagRe = RegExp(r'<[^>]+>');

Future<List<XTweet>> parseNitterTimeline(List<int> body) async {
  final html = utf8.decode(body, allowMalformed: true);
  final out = <XTweet>[];
  final seen = <String>{};
  final links = _nitterLinkRe.allMatches(html).toList();
  final bodies = _nitterBodyRe.allMatches(html).toList();
  for (var i = 0; i < links.length; i++) {
    final id = links[i].group(1)!;
    if (seen.contains(id)) continue;
    seen.add(id);
    var text = '';
    if (i < bodies.length) {
      text = bodies[i]
          .group(1)!
          .replaceAll(_tagRe, ' ')
          .trim();
    }
    out.add(XTweet(id: id, url: 'https://twitter.com/i/status/$id', text: text));
  }
  if (out.isEmpty) throw Exception('nitter 未解析到推文');
  return out;
}

// ------------------------------------------------------------
// Handler
// ------------------------------------------------------------
Future<void> handleXTweet(HttpRequest req) async {
  final res = req.response;
  res.headers.contentType =
      ContentType('application', 'json', charset: 'utf-8');
  if (req.method != 'GET') {
    await errJson(res, 405, 'Method not allowed');
    return;
  }
  final id = qp(req, 'id').trim();
  final ids = qp(req, 'ids').trim();

  if (id.isEmpty && ids.isEmpty) {
    await jsonResponse(res, 200, {'code': 400, 'message': 'id または ids パラメータを指定してください'});
    return;
  }

  final targets = <String>[];
  if (ids.isNotEmpty) {
    for (var p in ids.split(',')) {
      p = p.trim();
      if (p.isNotEmpty) targets.add(p);
    }
  } else {
    targets.add(id);
  }
  if (targets.isEmpty) {
    await jsonResponse(res, 200, {'code': 400, 'message': 'id が空です'});
    return;
  }

  if (targets.length == 1) {
    var tweets = xCacheGet('t:${targets[0]}');
    if (tweets == null) {
      try {
        tweets = await xRace(xTweetSources(targets[0]));
      } catch (e) {
        await jsonResponse(res, 200, {'code': 500, 'message': '抓取失败: $e'});
        return;
      }
      xCacheSet('t:${targets[0]}', tweets);
    }
    await jsonResponse(res, 200, {
      'code': 200,
      'tweets': tweets.map((t) => t.toJson()).toList(),
    });
    return;
  }

  final all = await xFetchBatch(targets, 't');
  await jsonResponse(res, 200, {
    'code': 200,
    'tweets': all.map((t) => t.toJson()).toList(),
  });
}

Future<void> handleXTimeline(HttpRequest req) async {
  final res = req.response;
  res.headers.contentType =
      ContentType('application', 'json', charset: 'utf-8');
  if (req.method != 'GET') {
    await errJson(res, 405, 'Method not allowed');
    return;
  }
  var name = (qp(req, 'screen_name')).trim();
  if (name.isEmpty) name = (qp(req, 'user')).trim();
  if (name.isEmpty) {
    await jsonResponse(res, 200, {'code': 400, 'message': 'screen_name パラメータを指定してください'});
    return;
  }
  if (name.startsWith('@')) name = name.substring(1);
  name = name
      .replaceFirst('https://x.com/', '')
      .replaceFirst('https://twitter.com/', '')
      .replaceFirst('http://twitter.com/', '');
  name = name.replaceAll(RegExp(r'^/+|/+$'), '');

  var tweets = xCacheGet('u:$name');
  if (tweets == null) {
    try {
      tweets = await xRace(xTimelineSources(name));
    } catch (e) {
      await jsonResponse(res, 200, {'code': 500, 'message': '抓取失败: $e'});
      return;
    }
    if (tweets.length > 20) tweets = tweets.sublist(0, 20);
    xCacheSet('u:$name', tweets);
  }
  await jsonResponse(res, 200, {
    'code': 200,
    'tweets': tweets.map((t) => t.toJson()).toList(),
  });
}

Future<List<XTweet>> xFetchBatch(
    List<String> ids, String cachePrefix) async {
  final results = <XTweet>[];
  final todo = <String>[];
  for (final id in ids) {
    final cached = xCacheGet('$cachePrefix$id');
    if (cached != null) {
      results.addAll(cached);
    } else {
      todo.add(id);
    }
  }
  const workers = 16;
  for (var i = 0; i < todo.length; i += workers) {
    final batch = todo.sublist(
        i, (i + workers) > todo.length ? todo.length : (i + workers));
    final futures = batch.map((id) async {
      try {
        final tws = await xRace(xTweetSources(id))
            .timeout(xReqTimeout + const Duration(seconds: 2));
        xCacheSet('$cachePrefix$id', tws);
        return tws;
      } catch (_) {
        return <XTweet>[];
      }
    }).toList();
    for (final r in await Future.wait(futures)) {
      results.addAll(r);
    }
  }
  return results;
}
