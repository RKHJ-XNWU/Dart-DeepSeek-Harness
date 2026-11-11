// ============================================================
// files.dart —— DeepSeek 文件管理（分片上传 / 下载 / 元数据 .sts）
// 100% 对齐 Go 版 ds-files.go，元数据格式保持不变：
//   metadata: data/ds_files/meta/ds_file_YYYY-MM.sts
//   line: id|name|size|mime|category|createdAt|relPath|source|prompt
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'globals.dart';
import 'httpsrv.dart';

String get DSFilesDir => '$DATA_DIR/ds_files';
String get DSFilesMetaDir => '$DSFilesDir/meta';
String get DSFilesBlobDir => '$DSFilesDir/blob';
String get DSFilesChunksDir => '$DSFilesDir/chunks';

const int DS_MAX_FILE_SIZE = 5 * 1024 * 1024 * 1024; // 5GB
const int DS_CHUNK_SIZE = 64 * 1024 * 1024; // 64MB (OOM fix)
const Duration DS_UPLOAD_SESSION_TTL = Duration(hours: 1);
const Duration DS_ORPHAN_GRACE_PERIOD = Duration(minutes: 30);

Timer? _uploadCleaner;

void initDsFilesDir() {
  for (final d in [DSFilesDir, DSFilesMetaDir, DSFilesBlobDir, DSFilesChunksDir]) {
    ensureDir(d);
  }
  cleanupStaleUploadSessions();
  _uploadCleaner ??= Timer.periodic(
      const Duration(minutes: 10), (_) => cleanupStaleUploadSessions());
}

void cleanupStaleUploadSessions() {
  List<FileSystemEntity> entries;
  try {
    entries = Directory(DSFilesChunksDir).listSync();
  } catch (_) {
    return;
  }
  final cutoff = DateTime.now().subtract(DS_UPLOAD_SESSION_TTL);
  var cleaned = 0;
  for (final e in entries) {
    try {
      final st = FileStat.statSync(e.path);
      if (st.modified.isBefore(cutoff)) {
        if (e is Directory) {
          e.deleteSync(recursive: true);
        } else {
          e.deleteSync();
        }
        cleaned++;
      }
    } catch (_) {}
  }
  if (cleaned > 0) logp('🧹 期限切れのアップロードセッションを $cleaned 件クリーンアップしました');
}

String sanitizeFileName(String name) {
  var n = name.split('/').last.split('\\').last;
  n = n
      .replaceAll('..', '_')
      .replaceAll('/', '_')
      .replaceAll('\\', '_')
      .replaceAll('|', '_')
      .replaceAll('\x00', '_');
  if (n.isEmpty || n == '.') n = 'file';
  if (n.length > 200) n = n.substring(0, 200);
  return n;
}

/// 递归删除空父目录（不越过 rootDir）
void removeEmptyParentDirs(String startPath, String rootDir) {
  String norm(String p) {
    var parts = p.split('/').where((s) => s.isNotEmpty).toList();
    return '/${parts.join('/')}';
  }

  final cleanRoot = norm(rootDir);
  var dir = norm(startPath);
  if (dir == cleanRoot || !dir.startsWith('$cleanRoot/')) return;
  while (dir != cleanRoot && dir.startsWith(cleanRoot)) {
    try {
      Directory(dir).deleteSync(); // 非空会抛异常
      logp('🗑️ 空のディレクトリを削除しました: $dir');
    } catch (_) {
      break;
    }
    final idx = dir.lastIndexOf('/');
    if (idx <= 0) break;
    dir = dir.substring(0, idx);
  }
}

// ------------------------------------------------------------
// 元数据
// ------------------------------------------------------------
class DsFileMeta {
  String id;
  String name;
  int size;
  String mimeType;
  String category;
  String createdAt;
  String relPath;
  String source;
  String prompt;

  DsFileMeta({
    required this.id,
    required this.name,
    required this.size,
    required this.mimeType,
    required this.category,
    required this.createdAt,
    required this.relPath,
    required this.source,
    this.prompt = '',
  });

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'id': id,
      'name': name,
      'size': size,
      'mimeType': mimeType,
      'category': category,
      'createdAt': createdAt,
      'relPath': relPath,
      'source': source,
    };
    if (prompt.isNotEmpty) m['prompt'] = prompt;
    return m;
  }
}

String dsFileMetaFile(DateTime t) => 'ds_file_${fmtYearMonth(t)}.sts';

bool saveDsFileMeta(DsFileMeta m) {
  var t = DateTime.tryParse(m.createdAt);
  if (t == null) t = DateTime.now();
  final fp = '$DSFilesMetaDir/${dsFileMetaFile(t)}';
  final line = '${m.id}|${escF(m.name)}|${m.size}|${m.mimeType}|${m.category}|'
      '${m.createdAt}|${escF(m.relPath)}|${m.source}|${escF(m.prompt)}\n';
  try {
    ensureDir(DSFilesMetaDir);
    File(fp).writeAsStringSync(line, mode: FileMode.append);
    invalidateDsFileMetaCache();
    return true;
  } catch (e) {
    logp('❌ ファイルメタデータの保存に失敗しました: $e');
    return false;
  }
}

List<DsFileMeta> getAllDsFiles() {
  List<FileSystemEntity> files;
  try {
    files = Directory(DSFilesMetaDir).listSync();
  } catch (_) {
    return [];
  }
  final all = <DsFileMeta>[];
  for (final f in files) {
    if (f is! File) continue;
    final name = f.uri.pathSegments.last;
    if (!name.startsWith('ds_file_') || !name.endsWith('.sts')) continue;
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
      if (parts.length < 8) continue;
      all.add(DsFileMeta(
        id: parts[0],
        name: unescF(parts[1]),
        size: int.tryParse(parts[2]) ?? 0,
        mimeType: parts[3],
        category: parts[4],
        createdAt: parts[5],
        relPath: unescF(parts[6]),
        source: parts[7],
        prompt: parts.length >= 9 ? unescF(parts[8]) : '',
      ));
    }
  }
  all.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return all;
}

Map<String, DsFileMeta>? _metaCache;
DateTime _metaCacheTime = DateTime.fromMillisecondsSinceEpoch(0);
const Duration _META_CACHE_TTL = Duration(seconds: 3);

void invalidateDsFileMetaCache() {
  _metaCache = null;
  _metaCacheTime = DateTime.fromMillisecondsSinceEpoch(0);
}

DsFileMeta? getDsFileMeta(String id) {
  if (id.isEmpty) return null;
  final now = DateTime.now();
  if (_metaCache == null || now.difference(_metaCacheTime) > _META_CACHE_TTL) {
    final all = getAllDsFiles();
    final m = <String, DsFileMeta>{};
    for (final f in all) {
      m[f.id] = f;
    }
    _metaCache = m;
    _metaCacheTime = now;
  }
  return _metaCache![id];
}

/// 删除元数据 + 物理文件 + 递归清理空目录
void deleteDsFileMeta(String id) {
  if (id.isEmpty) return;
  List<FileSystemEntity> files;
  try {
    files = Directory(DSFilesMetaDir).listSync();
  } catch (_) {
    return;
  }
  var anyDeleted = false;
  for (final f in files) {
    if (f is! File) continue;
    final name = f.uri.pathSegments.last;
    if (!name.startsWith('ds_file_') || !name.endsWith('.sts')) continue;
    String data;
    try {
      data = f.readAsStringSync();
    } catch (_) {
      continue;
    }
    final lines = data.split('\n');
    final newLines = <String>[];
    var found = false;
    for (var line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final parts = trimmed.split('|');
      if (parts.isNotEmpty && parts[0] == id) {
        found = true;
        if (parts.length >= 7) {
          final relPath = unescF(parts[6]);
          if (relPath.isNotEmpty) {
            final absPath = '$DSFilesBlobDir/$relPath';
            try {
              final file = File(absPath);
              if (file.existsSync()) {
                file.deleteSync();
                logp('🗑️ ファイルを削除しました: $relPath');
              }
            } catch (e) {
              logp('❌ ファイルの削除に失敗しました: $e');
            }
            final dir = absPath.substring(0, absPath.lastIndexOf('/'));
            removeEmptyParentDirs(dir, DSFilesBlobDir);
          }
        }
        continue;
      }
      newLines.add(trimmed);
    }
    if (found) {
      anyDeleted = true;
      try {
        if (newLines.isEmpty) {
          f.deleteSync();
        } else {
          f.writeAsStringSync('${newLines.join('\n')}\n');
        }
      } catch (_) {}
    }
  }
  if (anyDeleted) invalidateDsFileMetaCache();
}

// ------------------------------------------------------------
// 分类
// ------------------------------------------------------------
const Set<String> _codeExts = {
  '.go', '.js', '.ts', '.py', '.java', '.c', '.cpp', '.h', '.hpp', '.cs',
  '.rb', '.php', '.swift', '.kt', '.rs', '.html', '.css', '.scss', '.less',
  '.xml', '.yaml', '.yml', '.toml', '.sh', '.bat', '.ps1', '.sql',
  '.clang', '.cxx', '.cc', '.m', '.mm', '.dart',
};

const Set<String> _docExts = {
  '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.txt', '.md',
  '.csv', '.json', '.rtf', '.odt', '.epub', '.ini', '.conf', '.cfg', '.log',
};

const Set<String> _mcExts = {
  '.litematic', '.nbt', '.schematic', '.mcstructure',
};

String _extOf(String filename) {
  final i = filename.lastIndexOf('.');
  if (i < 0) return '';
  return filename.substring(i).toLowerCase();
}

String categorizeFile(String mimeType, String filename) {
  final ext = _extOf(filename);
  if (mimeType.startsWith('image/')) return 'image';
  if (mimeType.startsWith('video/')) return 'video';
  if (mimeType.startsWith('audio/')) return 'audio';
  if (_codeExts.contains(ext)) return 'code';
  if (_docExts.contains(ext)) return 'document';
  if (_mcExts.contains(ext)) return 'minecraft';
  return 'other';
}

// ------------------------------------------------------------
// HTTP：分片上传
// ------------------------------------------------------------
Future<void> handleDsFileUploadStart(HttpRequest req) async {
  if (req.method != 'POST') {
    await errJson(req.response, 405, 'Method not allowed');
    return;
  }
  Map<String, dynamic> body;
  try {
    body = await readJsonBody(req);
  } catch (_) {
    await errJson(req.response, 400, '無効なリクエストボディです');
    return;
  }
  final fileName = sanitizeFileName(mStr(body, 'fileName'));
  final fileSize = intArgDefault(body, 'fileSize', 0);
  final mimeType = mStr(body, 'mimeType');
  if (fileName.isEmpty) {
    await errJson(req.response, 400, 'ファイル名は必須です');
    return;
  }
  if (fileSize <= 0) {
    await errJson(req.response, 400, '文件大小无效');
    return;
  }
  if (fileSize > DS_MAX_FILE_SIZE) {
    await errJson(req.response, 413,
        'ファイルが 5GB の上限を超えています（現在 ${(fileSize / (1 << 30)).toStringAsFixed(2)} GB）');
    return;
  }

  final uploadID = 'up_${fmtStamp14(DateTime.now())}_${randomHex(6)}';
  var totalChunks = (fileSize + DS_CHUNK_SIZE - 1) ~/ DS_CHUNK_SIZE;
  if (totalChunks < 1) totalChunks = 1;

  final chunkDir = '$DSFilesChunksDir/$uploadID';
  ensureDir(chunkDir);
  final sess = {
    'uploadId': uploadID,
    'fileName': fileName,
    'fileSize': fileSize,
    'mimeType': mimeType,
    'totalChunks': totalChunks,
    'createdAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
  };
  if (!writeTextFile('$DSFilesChunksDir/$uploadID.json', jsonEncode(sess))) {
    try {
      Directory(chunkDir).deleteSync(recursive: true);
    } catch (_) {}
    await errJson(req.response, 500, 'セッションの書き込みに失敗しました');
    return;
  }
  await jsonResponse(req.response, 200, {
    'success': true,
    'uploadId': uploadID,
    'totalChunks': totalChunks,
    'chunkSize': DS_CHUNK_SIZE,
  });
}

Future<void> handleDsFileUploadChunk(HttpRequest req) async {
  if (req.method != 'POST') {
    await errJson(req.response, 405, 'Method not allowed');
    return;
  }
  final uploadID = qp(req, 'uploadId');
  final chunkIdxStr = qp(req, 'chunkIndex');
  if (uploadID.isEmpty || chunkIdxStr.isEmpty) {
    await errJson(req.response, 400, '缺少参数');
    return;
  }
  if (uploadID.contains('/') ||
      uploadID.contains('\\') ||
      uploadID.contains('..') ||
      uploadID.contains('|')) {
    await errJson(req.response, 400, '参数非法');
    return;
  }
  final chunkIdx = int.tryParse(chunkIdxStr);
  if (chunkIdx == null || chunkIdx < 0) {
    await errJson(req.response, 400, '分片索引无效');
    return;
  }

  final sessPath = '$DSFilesChunksDir/$uploadID.json';
  if (!File(sessPath).existsSync()) {
    await errJson(req.response, 404, 'アップロードセッションが存在しません');
    return;
  }
  Map<String, dynamic> sess;
  try {
    sess = asMap(jsonDecode(File(sessPath).readAsStringSync()));
  } catch (_) {
    await errJson(req.response, 500, 'セッションが破損しています');
    return;
  }
  final totalChunks = intArgDefault(sess, 'totalChunks', 0);
  if (chunkIdx >= totalChunks) {
    await errJson(req.response, 400, '分片索引越界');
    return;
  }

  List<int> chunkData;
  try {
    chunkData = await readBodyBytes(req, limit: DS_CHUNK_SIZE + (1 << 16));
  } catch (_) {
    try {
      Directory('$DSFilesChunksDir/$uploadID').deleteSync(recursive: true);
      File(sessPath).deleteSync();
    } catch (_) {}
    await errJson(req.response, 500, 'チャンクの読み込みに失敗しました（サイズ上限超過の可能性）');
    return;
  }
  if (chunkData.isEmpty) {
    await errJson(req.response, 400, 'チャンクが空です');
    return;
  }

  final chunkDir = '$DSFilesChunksDir/$uploadID';
  ensureDir(chunkDir);
  final chunkPath = '$chunkDir/${chunkIdx.toString().padLeft(6, '0')}.part';
  try {
    File(chunkPath).writeAsBytesSync(chunkData);
  } catch (_) {
    await errJson(req.response, 500, 'チャンクの書き込みに失敗しました');
    return;
  }
  await jsonResponse(req.response, 200, {
    'success': true,
    'index': chunkIdx,
    'size': chunkData.length,
  });
}

bool mergeChunks(String absPath, String chunkDir, int totalChunks) {
  // OOM fix: 1MB/chunk streaming copy instead of readAsBytesSync whole file
  RandomAccessFile? outRaf;
  try {
    ensureDir(absPath.substring(0, absPath.lastIndexOf('/')));
    final out = File(absPath).openSync(mode: FileMode.write);
    outRaf = out;
    const blockSize = 1024 * 1024;
    for (var i = 0; i < totalChunks; i++) {
      final partPath = '$chunkDir/${i.toString().padLeft(6, '0')}.part';
      final pf = File(partPath);
      if (!pf.existsSync()) {
        logp('❌ 分片 $i 缺失');
        return false;
      }
      final input = pf.openSync();
      try {
        while (true) {
          final buf = input.readSync(blockSize);
          if (buf.isEmpty) break;
          out.writeFromSync(buf);
        }
      } finally {
        input.closeSync();
      }
    }
    out.flushSync();
    return true;
  } catch (e) {
    logp('❌ チャンクの結合に失敗しました: $e');
    return false;
  } finally {
    try {
      outRaf?.closeSync();
    } catch (_) {}
  }
}

Future<void> handleDsFileUploadComplete(HttpRequest req) async {
  if (req.method != 'POST') {
    await errJson(req.response, 405, 'Method not allowed');
    return;
  }
  Map<String, dynamic> body;
  try {
    body = await readJsonBody(req);
  } catch (_) {
    await errJson(req.response, 400, '無効なリクエストボディです');
    return;
  }
  final uploadID = mStr(body, 'uploadId');
  if (uploadID.isEmpty ||
      uploadID.contains('/') ||
      uploadID.contains('\\') ||
      uploadID.contains('..') ||
      uploadID.contains('|')) {
    await errJson(req.response, 400, '参数非法');
    return;
  }

  final sessPath = '$DSFilesChunksDir/$uploadID.json';
  if (!File(sessPath).existsSync()) {
    await errJson(req.response, 404, 'アップロードセッションが存在しません');
    return;
  }
  Map<String, dynamic> sess;
  try {
    sess = asMap(jsonDecode(File(sessPath).readAsStringSync()));
  } catch (_) {
    try {
      Directory('$DSFilesChunksDir/$uploadID').deleteSync(recursive: true);
      File(sessPath).deleteSync();
    } catch (_) {}
    await errJson(req.response, 400, 'アップロードセッションが破損しています');
    return;
  }

  final chunkDir = '$DSFilesChunksDir/$uploadID';
  final fileName = sanitizeFileName(mStr(sess, 'fileName'));
  final fileSize = intArgDefault(sess, 'fileSize', 0);
  final mimeType = mStr(sess, 'mimeType');
  final totalChunks = intArgDefault(sess, 'totalChunks', 0);

  for (var i = 0; i < totalChunks; i++) {
    final partPath = '$chunkDir/${i.toString().padLeft(6, '0')}.part';
    final pf = File(partPath);
    if (!pf.existsSync()) {
      try {
        Directory(chunkDir).deleteSync(recursive: true);
        File(sessPath).deleteSync();
      } catch (_) {}
      await errJson(req.response, 500, '分片 $i 缺失');
      return;
    }
    if (pf.lengthSync() == 0) {
      try {
        Directory(chunkDir).deleteSync(recursive: true);
        File(sessPath).deleteSync();
      } catch (_) {}
      await errJson(req.response, 500, 'チャンク $i が空です');
      return;
    }
  }

  final fileID = 'f_${fmtStamp14(DateTime.now())}_${randomHex(6)}';
  final relDir = '${fileID.substring(0, 2)}/$fileID';
  final relPath = '$relDir/$fileName';
  final absPath = '$DSFilesBlobDir/$relPath';

  void cleanup() {
    try {
      final f = File(absPath);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    try {
      Directory(chunkDir).deleteSync(recursive: true);
    } catch (_) {}
    try {
      final f = File(sessPath);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  if (!mergeChunks(absPath, chunkDir, totalChunks)) {
    cleanup();
    await errJson(req.response, 500, 'チャンクの結合に失敗しました');
    return;
  }

  final stat = FileStat.statSync(absPath);
  if (stat.size != fileSize) {
    cleanup();
    await errJson(req.response, 500, 'サイズ不一致: 期待値 $fileSize、実際 ${stat.size}');
    return;
  }

  final category = categorizeFile(mimeType, fileName);
  final meta = DsFileMeta(
    id: fileID,
    name: fileName,
    size: fileSize,
    mimeType: mimeType,
    category: category,
    createdAt: rfc3339(DateTime.now()),
    relPath: relPath,
    source: 'upload',
  );
  if (!saveDsFileMeta(meta)) {
    cleanup();
    await errJson(req.response, 500, 'メタデータの保存に失敗しました');
    return;
  }

  try {
    Directory(chunkDir).deleteSync(recursive: true);
    File(sessPath).deleteSync();
  } catch (_) {}
  invalidateDsFileMetaCache();

  await jsonResponse(req.response, 200, {
    'success': true,
    'fileId': fileID,
    'name': fileName,
    'size': fileSize,
    'category': category,
    'mimeType': mimeType,
    'url': '/api/ds-files/download?id=$fileID',
  });
}

// ------------------------------------------------------------
// HTTP：下载 / 列表 / 删除
// ------------------------------------------------------------
Future<void> handleDsFileDownload(HttpRequest req) async {
  final id = qp(req, 'id');
  if (id.isEmpty) {
    await errJson(req.response, 400, '缺少 id');
    return;
  }
  final meta = getDsFileMeta(id);
  if (meta == null) {
    await errJson(req.response, 404, '文件不存在');
    return;
  }
  final absPath = '$DSFilesBlobDir/${meta.relPath}';
  await serveFile(req, File(absPath),
      downloadName: meta.name,
      attachment: req.uri.queryParameters['download'] == '1');
}

Future<void> handleDsFileList(HttpRequest req) async {
  if (req.method != 'GET') {
    await errJson(req.response, 405, 'Method not allowed');
    return;
  }
  final res = req.response;
  res.headers.set('Cache-Control', 'no-cache, no-store, must-revalidate');
  res.headers.set('Pragma', 'no-cache');
  res.headers.set('Expires', '0');

  var files = getAllDsFiles();
  final cat = qp(req, 'category');
  if (cat.isNotEmpty && cat != 'all') {
    files = files.where((f) => f.category == cat).toList();
  }
  await jsonResponse(res, 200, {
    'files': files.map((f) => f.toJson()).toList(),
  });
}

Future<void> handleDsFileDelete(HttpRequest req) async {
  if (req.method != 'DELETE') {
    await errJson(req.response, 405, 'Method not allowed');
    return;
  }
  final id = qp(req, 'id');
  if (id.isEmpty) {
    await errJson(req.response, 400, '缺少 id');
    return;
  }
  deleteDsFileMeta(id);
  await jsonResponse(req.response, 200, {'success': true});
}

Future<void> handleDsFileClearAll(HttpRequest req) async {
  if (req.method != 'DELETE') {
    await errJson(req.response, 405, 'Method not allowed');
    return;
  }
  for (final d in [DSFilesMetaDir, DSFilesBlobDir, DSFilesChunksDir]) {
    try {
      final dir = Directory(d);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
  }
  initDsFilesDir();
  invalidateDsFileMetaCache();
  await jsonResponse(req.response, 200, {'success': true});
}

// ------------------------------------------------------------
// 转 base64（视觉模型用，32MiB 上限）
// ------------------------------------------------------------
({String b64, String mime, String? error}) dsFileToBase64(String fileID) {
  final meta = getDsFileMeta(fileID);
  if (meta == null) return (b64: '', mime: '', error: '文件不存在');
  final absPath = '$DSFilesBlobDir/${meta.relPath}';
  Uint8List data;
  try {
    data = File(absPath).readAsBytesSync();
  } catch (e) {
    return (b64: '', mime: '', error: '$e');
  }
  if (data.length > 32 * 1024 * 1024) {
    return (b64: '', mime: '', error: '画像が 32MiB の上限を超えています（DeepSeek API の制限）');
  }
  final mime = meta.mimeType.isEmpty ? 'image/jpeg' : meta.mimeType;
  return (b64: base64.encode(data), mime: mime, error: null);
}
