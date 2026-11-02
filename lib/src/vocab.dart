// ============================================================
// vocab.dart —— 日语单词本（首字分片存储 + 256 图片分桶 + 删除清理）
//   目录：
//     $DATA_DIR/vocab/words/<首字>.sts
//     $DATA_DIR/vocab/images/b_XX/<name>  XX: 00 ~ ff
//
//   特性：
//     1. 严格按单词第一个字符建立分片文件
//     2. 自动按哈希分入 256 个桶
//     3. 删单词/换图时，如果图片所在桶目录空了，自动把目录删掉
// ============================================================

import 'dart:convert';
import 'dart:io';

import 'globals.dart';
import 'httpsrv.dart';

String get vocabDir => '$DATA_DIR/vocab';
String get vocabWordsDir => '$vocabDir/words';
String get vocabImagesDir => '$vocabDir/images';

const int VOCAB_MAX_WORD_LEN = 200;
const int VOCAB_MAX_MEANING_LEN = 2000;
const int VOCAB_MAX_EXAMPLE_LEN = 5000;

// ===== 256 桶 =====
const int VOCAB_IMAGE_BUCKETS = 256;

// ============ 首字分片逻辑 ============
String firstCharOfWord(String word) {
  if (word.isEmpty) return '其他';
  final firstRune = word.runes.first;
  final char = String.fromCharCode(firstRune);
  
  // 过滤掉文件名非法字符
  const illegalChars = ['/', '\\', ':', '*', '?', '"', '<', '>', '|'];
  for (final ic in illegalChars) {
    if (char.contains(ic)) return '其他';
  }
  return char;
}

String vocabPathOfRow(String row) => '$vocabWordsDir/$row.sts';

String rowOfWord(String word) {
  return firstCharOfWord(word);
}

// ============ 256 桶哈希 ============
int _imageBucket(String name) {
  if (name.isEmpty) return 0;
  var h = 0;
  for (var i = 0; i < name.length; i++) {
    h = (h * 31 + name.codeUnitAt(i)) & 0x7fffffff;
  }
  return h % VOCAB_IMAGE_BUCKETS;
}

String _bucketDirName(int b) => 'b_${b.toRadixString(16).padLeft(2, '0')}';
String _bucketDir(int b) => '$vocabImagesDir/${_bucketDirName(b)}';

/// 删除桶目录（仅当目录为空时）
void _removeBucketDirIfEmpty(int b) {
  final dir = Directory(_bucketDir(b));
  if (!dir.existsSync()) return;
  try {
    final files = dir.listSync();
    if (files.isEmpty) {
      dir.deleteSync();
    }
  } catch (_) {}
}

String? findImagePath(String name) {
  if (name.isEmpty || name.contains('..') || name.contains('/') || name.contains('\\')) {
    return null;
  }
  final b = _imageBucket(name);
  final primary = File('${_bucketDir(b)}/$name');
  if (primary.existsSync()) return primary.path;
  
  final fallback = File('$vocabImagesDir/$name');
  if (fallback.existsSync()) return fallback.path;
  
  for (var i = 0; i < VOCAB_IMAGE_BUCKETS; i++) {
    final f = File('${_bucketDir(i)}/$name');
    if (f.existsSync()) return f.path;
  }
  return null;
}

void deleteImageFile(String name) {
  if (name.isEmpty || name.contains('..') || name.contains('/') || name.contains('\\')) {
    return;
  }
  final b = _imageBucket(name);
  final targets = <int>[b];
  
  final primary = File('${_bucketDir(b)}/$name');
  if (primary.existsSync()) {
    try { primary.deleteSync(); } catch (_) {}
  }
  
  final rootFile = File('$vocabImagesDir/$name');
  if (rootFile.existsSync()) {
    try { rootFile.deleteSync(); } catch (_) {}
  }
  
  for (var i = 0; i < VOCAB_IMAGE_BUCKETS; i++) {
    if (i == b) continue;
    final f = File('${_bucketDir(i)}/$name');
    if (f.existsSync()) {
      try {
        f.deleteSync();
        targets.add(i);
      } catch (_) {}
    }
  }

  for (final idx in targets) {
    _removeBucketDirIfEmpty(idx);
  }
}

Future<String?> saveImageBytes(String name, List<int> bytes) async {
  if (name.isEmpty || name.contains('..') || name.contains('/') || name.contains('\\')) {
    return null;
  }
  final b = _imageBucket(name);
  final dir = Directory(_bucketDir(b));
  try {
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final f = File('${_bucketDir(b)}/$name');
    await f.writeAsBytes(bytes);
    return name;
  } catch (_) {
    return null;
  }
}

// ============ 数据模型 ============
class VocabWord {
  final String id;
  final String word;
  final String reading;
  final String pitch;
  final String meaning;
  final String pos;
  final String level;
  final List<String> tags;
  final String example;
  final String image;
  final String createdAt;
  final String updatedAt;
  final int reviewCount;
  final int correctCount;
  final String lastReviewedAt;
  final String nextReviewAt;
  final int intervalDays;
  final double ease;
  final bool mastered;

  const VocabWord({
    required this.id,
    required this.word,
    this.reading = '',
    this.pitch = '',
    this.meaning = '',
    this.pos = '',
    this.level = '',
    this.tags = const [],
    this.example = '',
    this.image = '',
    this.createdAt = '',
    this.updatedAt = '',
    this.reviewCount = 0,
    this.correctCount = 0,
    this.lastReviewedAt = '',
    this.nextReviewAt = '',
    this.intervalDays = 0,
    this.ease = 2.5,
    this.mastered = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'word': word,
        'reading': reading,
        'pitch': pitch,
        'meaning': meaning,
        'pos': pos,
        'level': level,
        'tags': tags,
        'example': example,
        'image': image,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'reviewCount': reviewCount,
        'correctCount': correctCount,
        'lastReviewedAt': lastReviewedAt,
        'nextReviewAt': nextReviewAt,
        'intervalDays': intervalDays,
        'ease': ease,
        'mastered': mastered,
        'imageUrl': image.isEmpty ? '' : '/api/vocab/image?name=$image',
        'row': rowOfWord(word),
      };

  factory VocabWord.fromJson(Map<String, dynamic> m) {
    int toInt(dynamic v) {
      if (v is num) return v.toInt();
      return int.tryParse('$v') ?? 0;
    }
    double toDouble(dynamic v, double def) {
      if (v is num) return v.toDouble();
      return double.tryParse('$v') ?? def;
    }
    return VocabWord(
      id: mStr(m, 'id'),
      word: mStr(m, 'word'),
      reading: mStr(m, 'reading'),
      pitch: mStr(m, 'pitch'),
      meaning: mStr(m, 'meaning'),
      pos: mStr(m, 'pos'),
      level: mStr(m, 'level'),
      tags: asList(m['tags']).map((e) => '$e').toList(),
      example: mStr(m, 'example'),
      image: mStr(m, 'image'),
      createdAt: mStr(m, 'createdAt'),
      updatedAt: mStr(m, 'updatedAt'),
      reviewCount: toInt(m['reviewCount']),
      correctCount: toInt(m['correctCount']),
      lastReviewedAt: mStr(m, 'lastReviewedAt'),
      nextReviewAt: mStr(m, 'nextReviewAt'),
      intervalDays: toInt(m['intervalDays']),
      ease: toDouble(m['ease'], 2.5),
      mastered: mBool(m, 'mastered'),
    );
  }

  String toStsLine() {
    final esc = escDs;
    return [
      id,
      esc(word),
      esc(reading),
      esc(pitch),
      esc(meaning),
      esc(pos),
      esc(level),
      esc(tags.join(',')),
      esc(example),
      esc(image),
      esc(createdAt),
      esc(updatedAt),
      '$reviewCount',
      '$correctCount',
      esc(lastReviewedAt),
      esc(nextReviewAt),
      '$intervalDays',
      '$ease',
      mastered ? '1' : '0',
    ].join('|');
  }

  static VocabWord? fromStsLine(String line) {
    if (line.trim().isEmpty) return null;
    final parts = line.split('|');
    if (parts.length < 19) return null;
    try {
      final un = unescDs;
      return VocabWord(
        id: parts[0],
        word: un(parts[1]),
        reading: un(parts[2]),
        pitch: un(parts[3]),
        meaning: un(parts[4]),
        pos: un(parts[5]),
        level: un(parts[6]),
        tags: un(parts[7]).split(',').where((e) => e.isNotEmpty).toList(),
        example: un(parts[8]),
        image: un(parts[9]),
        createdAt: un(parts[10]),
        updatedAt: un(parts[11]),
        reviewCount: int.tryParse(parts[12]) ?? 0,
        correctCount: int.tryParse(parts[13]) ?? 0,
        lastReviewedAt: un(parts[14]),
        nextReviewAt: un(parts[15]),
        intervalDays: int.tryParse(parts[16]) ?? 0,
        ease: double.tryParse(parts[17]) ?? 2.5,
        mastered: parts[18] == '1',
      );
    } catch (_) {
      return null;
    }
  }
}

// ============ 分片读写 ============
void initVocabDir() {
  ensureDir(vocabWordsDir);
  ensureDir(vocabImagesDir);
}

List<VocabWord> _readRow(String row) {
  final f = File(vocabPathOfRow(row));
  if (!f.existsSync()) return [];
  final out = <VocabWord>[];
  try {
    for (final line in f.readAsLinesSync()) {
      final w = VocabWord.fromStsLine(line);
      if (w != null) out.add(w);
    }
  } catch (_) {}
  return out;
}

bool _writeRow(String row, List<VocabWord> words) {
  ensureDir(vocabWordsDir);
  final sb = StringBuffer();
  for (final w in words) {
    sb.writeln(w.toStsLine());
  }
  return writeTextFile(vocabPathOfRow(row), sb.toString());
}

List<VocabWord> readAllVocab() {
  final out = <VocabWord>[];
  final dir = Directory(vocabWordsDir);
  if (!dir.existsSync()) return out;
  for (final f in dir.listSync()) {
    if (f is File && f.path.endsWith('.sts')) {
      final fileName = f.path.split(Platform.pathSeparator).last;
      final row = fileName.replaceAll('.sts', '');
      out.addAll(_readRow(row));
    }
  }
  return out;
}

bool _removeWordFromRow(String row, String id) {
  final words = _readRow(row);
  final before = words.length;
  words.removeWhere((w) => w.id == id);
  if (words.length == before) return false;
  return _writeRow(row, words);
}

String _newVocabId() {
  final now = DateTime.now();
  return 'w_${fmtStamp14(now)}_${randomHex(6)}';
}

VocabWord applyReview(VocabWord w, bool correct) {
  final now = DateTime.now();
  int interval = w.intervalDays;
  double ease = w.ease <= 0 ? 2.5 : w.ease;
  int correctCount = w.correctCount;

  if (correct) {
    correctCount++;
    if (interval <= 0) {
      interval = 1;
    } else if (interval == 1) {
      interval = 3;
    } else {
      interval = (interval * ease).round();
      if (interval > 365) interval = 365;
    }
    ease = ((ease + 0.1).clamp(1.3, 3.0)).toDouble();
  } else {
    interval = 1;
    ease = ((ease - 0.2).clamp(1.3, 3.0)).toDouble();
  }
  final next = now.add(Duration(days: interval));
  final mastered = w.mastered || (correct && interval >= 30 && correctCount >= 4);
  return VocabWord(
    id: w.id,
    word: w.word,
    reading: w.reading,
    pitch: w.pitch,
    meaning: w.meaning,
    pos: w.pos,
    level: w.level,
    tags: w.tags,
    example: w.example,
    image: w.image,
    createdAt: w.createdAt,
    updatedAt: w.updatedAt,
    reviewCount: w.reviewCount + 1,
    correctCount: correctCount,
    lastReviewedAt: rfc3339(now),
    nextReviewAt: rfc3339(next),
    intervalDays: interval,
    ease: ease,
    mastered: mastered,
  );
}

// ============ API ============
Future<void> handleVocab(HttpRequest req) async {
  final res = req.response;

  if (req.method == 'GET') {
    final all = readAllVocab();
    final q = qp(req, 'q').trim().toLowerCase();
    final level = qp(req, 'level').trim();
    final dueOnly = qp(req, 'dueOnly') == '1';
    final row = qp(req, 'row').trim();
    final nowIso = rfc3339(DateTime.now());

    var filtered = all;
    if (row.isNotEmpty && row != '全部') {
      filtered = filtered.where((w) => rowOfWord(w.word) == row).toList();
    }
    if (q.isNotEmpty) {
      filtered = filtered.where((w) =>
          w.word.toLowerCase().contains(q) ||
          w.reading.toLowerCase().contains(q) ||
          w.meaning.toLowerCase().contains(q) ||
          w.pos.toLowerCase().contains(q) ||
          w.tags.any((t) => t.toLowerCase().contains(q))).toList();
    }
    if (level.isNotEmpty) {
      filtered = filtered.where((w) => w.level == level).toList();
    }
    if (dueOnly) {
      filtered = filtered.where((w) =>
          !w.mastered &&
          (w.nextReviewAt.isEmpty || w.nextReviewAt.compareTo(nowIso) <= 0)).toList();
    }

    filtered.sort((a, b) {
      final ad = !a.mastered && (a.nextReviewAt.isEmpty || a.nextReviewAt.compareTo(nowIso) <= 0);
      final bd = !b.mastered && (b.nextReviewAt.isEmpty || b.nextReviewAt.compareTo(nowIso) <= 0);
      if (ad != bd) return ad ? -1 : 1;
      if (a.mastered != b.mastered) return a.mastered ? 1 : -1;
      final an = a.nextReviewAt.isEmpty ? a.createdAt : a.nextReviewAt;
      final bn = b.nextReviewAt.isEmpty ? b.createdAt : b.nextReviewAt;
      return an.compareTo(bn);
    });

    final offset = int.tryParse(qp(req, 'offset')) ?? 0;
    final limit = (int.tryParse(qp(req, 'limit')) ?? 30).clamp(1, 500);
    final total = filtered.length;
    final start = offset.clamp(0, total);
    final end = (start + limit).clamp(0, total);
    final page = filtered.sublist(start, end);

    final rowStats = <String, int>{};
    for (final w in all) {
      final r = rowOfWord(w.word);
      rowStats[r] = (rowStats[r] ?? 0) + 1;
    }

    final dueCount = all.where((w) =>
        !w.mastered &&
        (w.nextReviewAt.isEmpty || w.nextReviewAt.compareTo(nowIso) <= 0)).length;
    final masteredCount = all.where((w) => w.mastered).length;

    await dsJSONOk(res, 200, {
      'success': true,
      'words': page.map((w) => w.toJson()).toList(),
      'total': total,
      'totalAll': all.length,
      'due': dueCount,
      'mastered': masteredCount,
      'rowStats': rowStats,
      'offset': offset,
      'limit': limit,
      'hasMore': start + page.length < total,
    });
    return;
  }

  if (req.method == 'POST') {
    Map<String, dynamic> body;
    try {
      body = await readJsonBody(req);
    } catch (_) {
      await dsJSONErr(res, 400, '無効なリクエストボディです');
      return;
    }
    final word = mStr(body, 'word').trim();
    if (word.isEmpty) {
      await dsJSONErr(res, 400, '単語は必須です');
      return;
    }
    if (runeLen(word) > VOCAB_MAX_WORD_LEN) {
      await dsJSONErr(res, 400, '単語が長すぎます');
      return;
    }
    final meaning = mStr(body, 'meaning');
    if (runeLen(meaning) > VOCAB_MAX_MEANING_LEN) {
      await dsJSONErr(res, 400, '語義が長すぎます');
      return;
    }
    final example = mStr(body, 'example');
    if (runeLen(example) > VOCAB_MAX_EXAMPLE_LEN) {
      await dsJSONErr(res, 400, '例文が長すぎます');
      return;
    }
    final tags = asList(body['tags'])
        .map((e) => '$e'.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    final now = DateTime.now();
    final existingId = trimOr(mStr(body, 'id'), '');
    final newRow = rowOfWord(word);
    final newImage = mStr(body, 'image').trim();

    if (existingId.isEmpty) {
      final w = VocabWord(
        id: _newVocabId(),
        word: word,
        reading: mStr(body, 'reading').trim(),
        pitch: mStr(body, 'pitch').trim(),
        meaning: meaning,
        pos: mStr(body, 'pos').trim(),
        level: mStr(body, 'level').trim(),
        tags: tags,
        example: example,
        image: newImage,
        createdAt: rfc3339(now),
        updatedAt: rfc3339(now),
      );
      final rowWords = _readRow(newRow)..add(w);
      if (!_writeRow(newRow, rowWords)) {
        await dsJSONErr(res, 500, '保存に失敗しました');
        return;
      }
      await dsJSONOk(res, 200, {'success': true, 'word': w.toJson()});
      return;
    }

    VocabWord? old;
    String oldRow = '';
    final allWords = readAllVocab();
    for (final w in allWords) {
      if (w.id == existingId) {
        old = w;
        oldRow = rowOfWord(w.word);
        break;
      }
    }
    if (old == null) {
      await dsJSONErr(res, 404, '単語が存在しません');
      return;
    }
    final newMastered = body.containsKey('mastered') ? mBool(body, 'mastered') : old.mastered;
    final updated = VocabWord(
      id: old.id,
      word: word,
      reading: mStr(body, 'reading').trim(),
      pitch: mStr(body, 'pitch').trim(),
      meaning: meaning,
      pos: mStr(body, 'pos').trim(),
      level: mStr(body, 'level').trim(),
      tags: tags,
      example: example,
      image: newImage,
      createdAt: old.createdAt,
      updatedAt: rfc3339(now),
      reviewCount: old.reviewCount,
      correctCount: old.correctCount,
      lastReviewedAt: old.lastReviewedAt,
      nextReviewAt: old.nextReviewAt,
      intervalDays: old.intervalDays,
      ease: old.ease,
      mastered: newMastered,
    );

    if (old.image.isNotEmpty && old.image != newImage) {
      deleteImageFile(old.image);
    }
    _removeWordFromRow(oldRow, old.id);
    final newRowWords = _readRow(newRow)..add(updated);
    if (!_writeRow(newRow, newRowWords)) {
      await dsJSONErr(res, 500, '保存に失敗しました');
      return;
    }
    await dsJSONOk(res, 200, {'success': true, 'word': updated.toJson()});
    return;
  }

  if (req.method == 'DELETE') {
    final id = qp(req, 'id').trim();
    final idsRaw = qp(req, 'ids').trim();
    final ids = <String>[];
    if (id.isNotEmpty) ids.add(id);
    if (idsRaw.isNotEmpty) {
      ids.addAll(idsRaw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty));
    }
    if (ids.isEmpty) {
      await dsJSONErr(res, 400, '缺少 id');
      return;
    }
    var deleted = 0;
    final dir = Directory(vocabWordsDir);
    if (dir.existsSync()) {
      for (final f in dir.listSync()) {
        if (f is File && f.path.endsWith('.sts')) {
          final fileName = f.path.split(Platform.pathSeparator).last;
          final row = fileName.replaceAll('.sts', '');
          final ws = _readRow(row);
          final before = ws.length;
          final removedImages = <String>[];
          final kept = <VocabWord>[];
          for (final w in ws) {
            if (ids.contains(w.id)) {
              if (w.image.isNotEmpty) removedImages.add(w.image);
            } else {
              kept.add(w);
            }
          }
          if (kept.length < before) {
            _writeRow(row, kept);
            deleted += before - kept.length;
            for (final img in removedImages) {
              deleteImageFile(img);
            }
          }
        }
      }
    }
    await dsJSONOk(res, 200, {'success': true, 'deleted': deleted});
    return;
  }

  await dsJSONErr(res, 405, 'Method not allowed');
}

Future<void> handleVocabImage(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'GET') {
    await dsJSONErr(res, 405, 'Method not allowed');
    return;
  }
  final name = qp(req, 'name').trim();
  if (name.isEmpty || name.contains('..') || name.contains('/') || name.contains('\\')) {
    res.statusCode = 400;
    await res.close();
    return;
  }
  final path = findImagePath(name);
  if (path == null) {
    res.statusCode = 404;
    await res.close();
    return;
  }
  final lower = name.toLowerCase();
  if (lower.endsWith('.png')) {
    res.headers.contentType = ContentType('image', 'png');
  } else if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
    res.headers.contentType = ContentType('image', 'jpeg');
  } else if (lower.endsWith('.gif')) {
    res.headers.contentType = ContentType('image', 'gif');
  } else if (lower.endsWith('.webp')) {
    res.headers.contentType = ContentType('image', 'webp');
  } else {
    res.headers.contentType = ContentType.binary;
  }
  res.headers.set('Cache-Control', 'public, max-age=86400');
  await res.addStream(File(path).openRead());
  await res.close();
}

Future<void> handleVocabUpload(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'POST') {
    await dsJSONErr(res, 405, 'Method not allowed');
    return;
  }
  try {
    ensureDir(vocabImagesDir);
    final boundary = req.headers.contentType?.parameters['boundary'];
    if (boundary == null || boundary.isEmpty) {
      await dsJSONErr(res, 400, '缺少 boundary');
      return;
    }
    final bytes = await req.fold<List<int>>(<int>[], (p, e) => p..addAll(e));
    final bodyStr = String.fromCharCodes(bytes);
    final startMarker = 'Content-Disposition: form-data; name="file"; filename="';
    final idx = bodyStr.indexOf(startMarker);
    if (idx < 0) {
      await dsJSONErr(res, 400, '未找到 file 字段');
      return;
    }
    final fnStart = idx + startMarker.length;
    final fnEnd = bodyStr.indexOf('"', fnStart);
    final originalName = bodyStr.substring(fnStart, fnEnd);
    final ext = _safeExt(originalName);
    final headerEnd = bodyStr.indexOf('\r\n\r\n', fnEnd);
    if (headerEnd < 0) {
      await dsJSONErr(res, 400, '无效 multipart');
      return;
    }
    final contentStart = headerEnd + 4;
    final nextBoundary = '\r\n--$boundary';
    final contentEnd = bodyStr.indexOf(nextBoundary, contentStart);
    if (contentEnd < 0) {
      await dsJSONErr(res, 400, '無効な multipart 終端です');
      return;
    }
    final fileBytes = bytes.sublist(contentStart, contentEnd);
    final name = 'img_${fmtStamp14(DateTime.now())}_${randomHex(6)}$ext';
    final saved = await saveImageBytes(name, fileBytes);
    if (saved == null) {
      await dsJSONErr(res, 500, '画像の書き込みに失敗しました');
      return;
    }
    await dsJSONOk(res, 200, {'success': true, 'name': name});
  } catch (e) {
    await dsJSONErr(res, 500, 'アップロードに失敗しました: $e');
  }
}

String _safeExt(String filename) {
  final i = filename.lastIndexOf('.');
  if (i < 0) return '.jpg';
  final ext = filename.substring(i).toLowerCase();
  const allowed = ['.jpg', '.jpeg', '.png', '.gif', '.webp'];
  return allowed.contains(ext) ? ext : '.jpg';
}

Future<void> handleVocabReview(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'POST') {
    await dsJSONErr(res, 405, 'Method not allowed');
    return;
  }
  Map<String, dynamic> body;
  try {
    body = await readJsonBody(req);
  } catch (_) {
    await dsJSONErr(res, 400, '無効なリクエストボディです');
    return;
  }
  final id = mStr(body, 'id').trim();
  if (id.isEmpty) {
    await dsJSONErr(res, 400, '缺少 id');
    return;
  }
  final correct = mBool(body, 'correct');

  final allWords = readAllVocab();
  for (final w in allWords) {
    if (w.id == id) {
      final r = rowOfWord(w.word);
      final ws = _readRow(r);
      final idx = ws.indexWhere((x) => x.id == id);
      if (idx >= 0) {
        ws[idx] = applyReview(ws[idx], correct);
        if (!_writeRow(r, ws)) {
          await dsJSONErr(res, 500, '保存に失敗しました');
          return;
        }
        await dsJSONOk(res, 200, {'success': true, 'word': ws[idx].toJson()});
        return;
      }
    }
  }
  await dsJSONErr(res, 404, '単語が存在しません');
}

Future<void> handleVocabClear(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'POST') {
    await dsJSONErr(res, 405, 'Method not allowed');
    return;
  }
  final dir = Directory(vocabWordsDir);
  if (dir.existsSync()) {
    for (final f in dir.listSync()) {
      if (f is File && f.path.endsWith('.sts')) {
        try { f.deleteSync(); } catch (_) {}
      }
    }
  }
  for (var i = 0; i < VOCAB_IMAGE_BUCKETS; i++) {
    final dir = Directory(_bucketDir(i));
    if (dir.existsSync()) {
      try { dir.deleteSync(recursive: true); } catch (_) {}
    }
  }
  final root = Directory(vocabImagesDir);
  if (root.existsSync()) {
    try {
      for (final e in root.listSync()) {
        if (e is File) {
          final name = e.path.split('/').last;
          final lower = name.toLowerCase();
          if (lower.endsWith('.jpg') || lower.endsWith('.jpeg') ||
              lower.endsWith('.png') || lower.endsWith('.gif') ||
              lower.endsWith('.webp')) {
            try { e.deleteSync(); } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }
  await dsJSONOk(res, 200, {'success': true});
}