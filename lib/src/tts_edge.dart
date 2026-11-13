// ============================================================
// tts_edge.dart —— Microsoft Edge TTS（WebSocket 流式合成）
// 对齐 Go 版使用的 github.com/difyz9/edge-tts-go（communicate.Stream）
//   - 24kHz/48kbps mono mp3 输出
//   - 文本分块后逐块合成、边收边写，客户端可渐进播放
// 说明：edge-tts-go 的 chunk 类型只区分 "audio"，这里等价实现为
//       二进制帧（Path:audio）→ 音频数据；Path:turn.end → 结束本块。
//
// 2026 修复两处导致朗读无声的问题：
//   1) 微软把 Sec-MS-GEC 从 v1（仅 SHA256）升级为 v2（CS64 + SHA256
//      双摘要），旧签名返回 403 → 签名算法见 tts_drm.dart。
//   2) Dart 的 WebSocket.connect 默认在 User-Agent 前拼接
//      "Dart/3.x (dart:io)"，被 speech.platform.bing.com 判定为非浏览器
//      客户端而返回 403 → 用 customClient（userAgent=null）规避，
//      只发送真实的浏览器 UA。
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'tts_drm.dart';

const String _trustedToken = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
const String _outputFormat = 'audio-24khz-48kbitrate-mono-mp3';
const String _wsBase =
    'wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1';

final math.Random _rnd = math.Random.secure();

/// 共享 HttpClient：userAgent 置空，避免 Dart 默认在 UA 前拼接
/// "Dart/3.x (dart:io)"（会被 Edge TTS 服务 403 拒绝）。
final HttpClient _ttsHttpClient = HttpClient()..userAgent = null;

String _hex(int n) {
  final sb = StringBuffer();
  for (var i = 0; i < n; i++) {
    sb.write(_rnd.nextInt(16).toRadixString(16));
  }
  return sb.toString();
}

String _uuid() =>
    '${_hex(8)}-${_hex(4)}-${_hex(4)}-${_hex(4)}-${_hex(12)}';

/// 随机 MUID（32 位大写 hex，对齐 edge-tts 的 Cookie: muid=）
String _muid() => _hex(32).toUpperCase();

String _ts() {
  // Edge 要求 JS 风格时间戳：EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'
  final now = DateTime.now().toUtc();
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  final d = days[now.weekday - 1];
  final m = months[now.month - 1];
  String p2(int v) => v < 10 ? '0$v' : '$v';
  return '$d $m ${p2(now.day)} ${now.year} '
      '${p2(now.hour)}:${p2(now.minute)}:${p2(now.second)} '
      'GMT+0000 (Coordinated Universal Time)';
}

String _xmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// 合成单块文本，音频字节通过 onAudio 回调流出。
/// 带有最多 3 次自动重试机制，防止网络波动导致无声。
/// 返回是否成功收到音频。
Future<bool> synthesizeEdgeTts(
  String text,
  String voice,
  Future<void> Function(List<int> audio) onAudio, {
  Duration timeout = const Duration(seconds: 60),
  String pitch = '+0Hz',
  String rate = '+0%',
  String volume = '+0%',
}) async {
  for (var attempt = 0; attempt < 3; attempt++) {
    final ok = await _synthesizeEdgeTtsOnce(
      text,
      voice,
      onAudio,
      timeout: timeout,
      pitch: pitch,
      rate: rate,
      volume: volume,
    );
    if (ok) return true;
    if (attempt < 2) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }
  return false;
}

/// 实际的单次 WebSocket 合成逻辑
Future<bool> _synthesizeEdgeTtsOnce(
  String text,
  String voice,
  Future<void> Function(List<int> audio) onAudio, {
  Duration timeout = const Duration(seconds: 60),
  String pitch = '+0Hz',
  String rate = '+0%',
  String volume = '+0%',
}) async {
  final connectionId = _uuid();
  final gec = ttsSecMsGecV2();
  final url = '$_wsBase?TrustedClientToken=$_trustedToken'
      '&Sec-MS-GEC=$gec&Sec-MS-GEC-Version=$ttsGecVersion'
      '&ConnectionId=$connectionId';
  WebSocket ws;
  try {
    ws = await WebSocket.connect(
      url,
      headers: {
        'Pragma': 'no-cache',
        'Cache-Control': 'no-cache',
        'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
        'Accept-Encoding': 'gzip, deflate, br, zstd',
        'Accept-Language': 'en-US,en;q=0.9',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0',
        'Cookie': 'muid=${_muid()};',
      },
      customClient: _ttsHttpClient,
    ).timeout(const Duration(seconds: 15));
  } catch (e) {
    return false;
  }

  final done = Completer<bool>();
  var gotAudio = false;

  final sub = ws.listen(
    (dynamic frame) {
      if (frame is String) {
        if (frame.contains('Path:turn.end')) {
          if (!done.isCompleted) done.complete(gotAudio);
        }
        return;
      }
      if (frame is List<int>) {
        final bytes = frame is Uint8List ? frame : Uint8List.fromList(frame);
        if (bytes.length < 2) return;
        final headerLen = (bytes[0] << 8) | bytes[1];
        final audioStart = 2 + headerLen;
        if (audioStart >= bytes.length) return;
        final header =
            utf8.decode(bytes.sublist(2, audioStart), allowMalformed: true);
        if (!header.contains('Path:audio')) return;
        gotAudio = true;
        final audio = bytes.sublist(audioStart);
        onAudio(audio);
      }
    },
    onError: (Object e) {
      if (!done.isCompleted) done.complete(gotAudio);
    },
    onDone: () {
      if (!done.isCompleted) done.complete(gotAudio);
    },
    cancelOnError: false,
  );

  final config = 'X-Timestamp:${_ts()}\r\n'
      'Content-Type:application/json; charset=utf-8\r\n'
      'Path:speech.config\r\n\r\n'
      '{"context":{"synthesis":{"audio":{"metadataoptions":'
      '{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},'
      '"outputFormat":"$_outputFormat"}}}}\r\n';

  // xml:lang 跟随音色（ja-JP-* → ja-JP），否则默认 en-US
  final ssmlLang = voice.length >= 5 ? voice.substring(0, 5) : 'en-US';
  final ssml = "<speak version='1.0' "
      "xmlns='http://www.w3.org/2001/10/synthesis' "
      "xml:lang='${_xmlEscape(ssmlLang)}'>"
      "<voice name='${_xmlEscape(voice)}'>"
      "<prosody pitch='${_xmlEscape(pitch)}' rate='${_xmlEscape(rate)}' "
      "volume='${_xmlEscape(volume)}'>"
      '${_xmlEscape(text)}'
      "</prosody></voice></speak>";

  final reqId = _uuid();
  final ssmlFrame = 'X-RequestId:$reqId\r\n'
      'Content-Type:application/ssml+xml\r\n'
      'X-Timestamp:${_ts()}Z\r\n'
      'Path:ssml\r\n\r\n'
      '$ssml';

  try {
    ws.add(config);
    ws.add(ssmlFrame);
    final ok = await done.future.timeout(timeout, onTimeout: () => gotAudio);
    return ok;
  } catch (_) {
    return gotAudio;
  } finally {
    try {
      await sub.cancel();
    } catch (_) {}
    try {
      await ws.close();
    } catch (_) {}
  }
}