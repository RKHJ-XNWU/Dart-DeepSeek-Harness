// ============================================================
// backup.dart —— 备份（tar.gz 打包下载）/ 恢复（multipart 上传解压）
// 100% 对齐 Go 版 main.go 的 handleBackup / handleRestore
//   tar 写入/解析与 Go archive/tar 兼容（ustar 格式）
// ============================================================

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'globals.dart';
import 'httpsrv.dart';

// ------------------------------------------------------------
// tar 写入
// ------------------------------------------------------------
Uint8List _header({
  required String name,
  required int mode,
  required int size,
  required int mtime,
  required String typeflag,
}) {
  final h = Uint8List(512);
  void writeStr(int off, String s, int len) {
    final b = utf8.encode(s);
    for (var i = 0; i < len && i < b.length; i++) {
      h[off + i] = b[i];
    }
  }

  void writeOctal(int off, int value, int len) {
    final s = value.toRadixString(8).padLeft(len - 1, '0');
    writeStr(off, s, len - 1);
    h[off + len - 1] = 0;
  }

  writeStr(0, name, 100);
  writeOctal(100, mode, 8);
  writeOctal(108, 0, 8); // uid
  writeOctal(116, 0, 8); // gid
  writeOctal(124, size, 12);
  writeOctal(136, mtime, 12);
  writeStr(148, '        ', 8); // checksum 占位
  writeStr(156, typeflag, 1);
  writeStr(257, 'ustar', 5);
  h[262] = 0;
  writeStr(263, '00', 2);
  writeStr(265, 'root', 32);
  writeStr(297, 'root', 32);

  var sum = 0;
  for (final b in h) {
    sum += b;
  }
  final chk = sum.toRadixString(8).padLeft(6, '0');
  writeStr(148, chk, 6);
  h[154] = 0;
  h[155] = 0x20;
  return h;
}

class TarWriter {
  final Sink<List<int>> _sink;
  TarWriter(this._sink);

  Future<void> addDir(String name, DateTime mtime) async {
    _sink.add(_header(
      name: name.endsWith('/') ? name : '$name/',
      mode: 0x1ED, // 0755
      size: 0,
      mtime: mtime.millisecondsSinceEpoch ~/ 1000,
      typeflag: '5',
    ));
  }

  Future<void> addFile(String name, List<int> data, DateTime mtime) async {
    _sink.add(_header(
      name: name,
      mode: 0x1A4, // 0644
      size: data.length,
      mtime: mtime.millisecondsSinceEpoch ~/ 1000,
      typeflag: '0',
    ));
    _sink.add(data);
    final pad = (512 - (data.length % 512)) % 512;
    if (pad > 0) _sink.add(Uint8List(pad));
  }

  Future<void> close() async {
    _sink.add(Uint8List(1024)); // 两个全零块
    _sink.close();
  }
}

// ------------------------------------------------------------
// tar 解析
// ------------------------------------------------------------
class TarEntry {
  final String name;
  final String typeflag;
  final Uint8List data;
  TarEntry(this.name, this.typeflag, this.data);
}

List<TarEntry> parseTar(Uint8List buf) {
  final out = <TarEntry>[];
  var off = 0;
  String readStr(int start, int len) {
    var end = start;
    while (end < start + len && buf[end] != 0) {
      end++;
    }
    return utf8.decode(buf.sublist(start, end), allowMalformed: true);
  }

  int readOctal(int start, int len) {
    final s = readStr(start, len).trim();
    if (s.isEmpty) return 0;
    return int.tryParse(s, radix: 8) ?? 0;
  }

  while (off + 512 <= buf.length) {
    final name = readStr(off, 100);
    if (name.isEmpty) break; // 结束块
    final typeflag = readStr(off + 156, 1);
    final size = readOctal(off + 124, 12);
    var fullName = name;
    final prefix = readStr(off + 345, 155);
    if (prefix.isNotEmpty) fullName = '$prefix/$name';
    off += 512;
    final dataLen = size > 0 ? size : 0;
    if (off + dataLen > buf.length) break;
    final data = Uint8List.sublistView(buf, off, off + dataLen);
    out.add(TarEntry(fullName, typeflag.isEmpty ? '0' : typeflag, data));
    off += dataLen;
    final pad = (512 - (dataLen % 512)) % 512;
    off += pad;
  }
  return out;
}

// ------------------------------------------------------------
// 备份
// ------------------------------------------------------------
Future<void> handleBackup(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'GET') {
    await errJson(res, 405, 'Method not allowed');
    return;
  }
  final timestamp = fmtFileStamp(DateTime.now());
  final type = qp(req, 'type');

  List<String> dirs;
  String namePrefix;
  switch (type) {
    case 'config':
      dirs = ['models', 'whisper.cpp'];
      namePrefix = 'config_backup';
      break;
    case 'data':
      dirs = ['data', 'imgs'];
      namePrefix = 'data_backup';
      break;
    default:
      dirs = ['data', 'imgs', 'models', 'whisper.cpp'];
      namePrefix = 'wordbook_backup';
  }
  final filename = '${namePrefix}_$timestamp.tar.gz';

  ensureDir(BACKUP_TMP_DIR);
  final tmpPath =
      '$BACKUP_TMP_DIR/backup_${DateTime.now().microsecondsSinceEpoch}.tar.gz';

  try {
    final file = File(tmpPath).openSync(mode: FileMode.write);
    final gz = gzip.encoder.startChunkedConversion(_FileSink(file));
    final tar = TarWriter(gz);

    for (final dirName in dirs) {
      final dirPath = '$BASE_DIR/$dirName';
      if (!Directory(dirPath).existsSync()) continue;
      final entries = Directory(dirPath).listSync(recursive: true);
      // 先父后子，保证解压顺序合理
      entries.sort((a, b) => a.path.compareTo(b.path));
      for (final e in entries) {
        final rel = e.path.substring(BASE_DIR.length + 1);
        final stat = FileStat.statSync(e.path);
        if (e is Directory) {
          await tar.addDir(rel, stat.modified);
        } else if (e is File) {
          try {
            await tar.addFile(rel, e.readAsBytesSync(), stat.modified);
          } catch (err) {
            logp('⚠️ 备份跳过 ${e.path}: $err');
          }
        }
      }
    }
    await tar.close();
    try {
      file.flushSync();
      file.closeSync();
    } catch (_) {}
  } catch (e) {
    try {
      final f = File(tmpPath);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    await errJson(res, 500, '打包失败: $e');
    return;
  }

  final f = File(tmpPath);
  if (!f.existsSync()) {
    await errJson(res, 500, '打开临时文件失败');
    return;
  }
  logp('✅ 备份完成: $filename (${f.lengthSync()} 字节)');
  await serveFile(req, f, downloadName: filename, attachment: true);
  try {
    f.deleteSync();
  } catch (_) {}
}

class _FileSink implements Sink<List<int>> {
  final RandomAccessFile raf;
  _FileSink(this.raf);

  @override
  void add(List<int> data) => raf.writeFromSync(data);

  @override
  void close() {
    try {
      raf.flushSync();
    } catch (_) {}
  }
}

// ------------------------------------------------------------
// 恢复
// ------------------------------------------------------------
/// 从 multipart/form-data body 中提取第一个文件 part 的字节
Uint8List? extractMultipartFile(Uint8List body, String boundary) {
  final delim = utf8.encode('--$boundary');
  final indexes = <int>[];
  for (var i = 0; i + delim.length <= body.length; i++) {
    var match = true;
    for (var j = 0; j < delim.length; j++) {
      if (body[i + j] != delim[j]) {
        match = false;
        break;
      }
    }
    if (match) indexes.add(i);
  }
  if (indexes.length < 2) return null;
  for (var k = 0; k + 1 < indexes.length; k++) {
    final start = indexes[k] + delim.length;
    final end = indexes[k + 1];
    if (start >= end) continue;
    // 跳过 CRLF
    var p = start;
    while (p < end && (body[p] == 0x0D || body[p] == 0x0A)) {
      p++;
    }
    // 找 header 结束（\r\n\r\n）
    var headerEnd = -1;
    for (var i = p; i + 3 < end; i++) {
      if (body[i] == 0x0D &&
          body[i + 1] == 0x0A &&
          body[i + 2] == 0x0D &&
          body[i + 3] == 0x0A) {
        headerEnd = i + 4;
        break;
      }
    }
    if (headerEnd < 0) continue;
    final headers =
        utf8.decode(body.sublist(p, headerEnd), allowMalformed: true);
    if (!headers.toLowerCase().contains('filename')) continue;
    var dataEnd = end;
    // 去掉尾部 CRLF
    while (dataEnd > headerEnd &&
        (body[dataEnd - 1] == 0x0A || body[dataEnd - 1] == 0x0D)) {
      dataEnd--;
    }
    return Uint8List.sublistView(body, headerEnd, dataEnd);
  }
  return null;
}

Future<void> handleRestore(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'POST') {
    await errJson(res, 405, 'Method not allowed');
    return;
  }

  Uint8List body;
  try {
    body = Uint8List.fromList(await readBodyBytes(req, limit: MAX_UPLOAD_SIZE));
  } catch (_) {
    await errJson(res, 400, '文件太大或解析失败');
    return;
  }

  Uint8List? archive;
  final contentType = req.headers.contentType;
  if (contentType != null &&
      contentType.mimeType == 'multipart/form-data' &&
      contentType.parameters['boundary'] != null) {
    archive = extractMultipartFile(body, contentType.parameters['boundary']!);
  } else {
    archive = body;
  }
  if (archive == null || archive.isEmpty) {
    await errJson(res, 400, '请上传备份文件');
    return;
  }

  // 清空 data/ 与 imgs/
  for (final d in ['$BASE_DIR/data', '$BASE_DIR/imgs']) {
    final dir = Directory(d);
    if (!dir.existsSync()) continue;
    for (final e in dir.listSync()) {
      try {
        if (e is Directory) {
          e.deleteSync(recursive: true);
        } else {
          e.deleteSync();
        }
      } catch (_) {}
    }
  }

  List<TarEntry> entries;
  try {
    final raw = gzip.decoder.convert(archive);
    entries = parseTar(Uint8List.fromList(raw));
  } catch (e) {
    await errJson(res, 400, '无效的gzip文件: $e');
    return;
  }

  var extracted = 0;
  for (final e in entries) {
    var name = e.name;
    if (name.startsWith('/')) continue;
    final parts = <String>[];
    var bad = false;
    for (final seg in name.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        bad = true;
        break;
      }
      parts.add(seg);
    }
    if (bad || parts.isEmpty) {
      logp('⚠️ 跳过非法路径: $name');
      continue;
    }
    name = parts.join('/');
    final target = '$BASE_DIR/$name';
    try {
      if (e.typeflag == '5') {
        Directory(target).createSync(recursive: true);
      } else if (e.typeflag == '0' || e.typeflag == '') {
        final idx = target.lastIndexOf('/');
        if (idx > 0) ensureDir(target.substring(0, idx));
        File(target).writeAsBytesSync(e.data);
        extracted++;
      }
    } catch (err) {
      await errJson(res, 500, '写入文件失败: $err');
      return;
    }
  }

  logp('✅ 恢复成功: 解压 $extracted 个文件');
  await dsJSONOk(res, 200, {
    'success': true,
    'message': '恢复成功',
    'extracted': extracted,
  });
}
