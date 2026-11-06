// ============================================================
// doubao.dart —— 火山方舟（豆包）接入层
//   能力：语言模型聊天 / Seedream 文生图 / Seedance 文生视频 /
//         SeedAudio·播客 TTS / 录音文件识别（ASR）/ 实时语音通话回合
//
// 设计原则：
//   1) 零第三方依赖（与整个项目一致，仅 dart:io / dart:convert）
//   2) 豆包 API Key 独立保存（与 DeepSeek Key 分离），按要求明文存储
//   3) 生成的图片 / 视频 / 音频统一落盘到 data/ds_files/blob，
//      并写入 ds_files 元数据，前端可按 fileId 播放与下载
//   4) 所有失败都如实返回错误，绝不伪造成功
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'ds_crypto.dart';
import 'files.dart';
import 'globals.dart';
import 'httpsrv.dart';
import 'net.dart';

// ------------------------------------------------------------
// 模型目录（17 个预置模型，前端显示名与模型值严格对应）
// cat: chat / image / video / tts / podcast / asr / realtime
// ------------------------------------------------------------
class DbModelSpec {
  final String value;
  final String label;
  final String cat;
  const DbModelSpec(this.value, this.label, this.cat);
}

const List<DbModelSpec> dbModelCatalog = <DbModelSpec>[
  DbModelSpec('Doubao_scene_SLM_Doubao_realtime_voice_model',
      '豆包リアルタイム音声対話（Doubao-リアルタイム音声対話）', 'realtime'),
  DbModelSpec('Doubao_Seed_ASR_AUC_2.0', '豆包録音ファイル認識（Doubao-録音ファイル認識2.0）', 'asr'),
  DbModelSpec(
      'Doubao_Seed_ASR_Streaming_2.0', 'Doubao-ストリーミング音声認識（ストリーミング認識）', 'asr'),
  DbModelSpec('Doubao_scene_SLM_Doubao_Podcast_model',
      'Doubao-音声ポッドキャスト（音声ポッドキャスト）', 'podcast'),
  DbModelSpec('SeedAudio1.0', 'Doubao-音声生成-1.0（音声生成）', 'tts'),
  DbModelSpec('doubao-seedream-4-5-251128', 'Doubao-Seedream-4.5（画像生成モデル4K）', 'image'),
  DbModelSpec(
      'doubao-seedream-5-0-260128', 'Doubao-Seedream-5.0-Lite（軽量画像生成）', 'image'),
  DbModelSpec(
      'doubao-seedream-5-0-pro-260628', 'Doubao-Seedream-5.0-pro（高精度画像生成）', 'image'),
  DbModelSpec('doubao-seedance-2-0-mini-260615', 'Doubao-Seedance-2.0-mini（動画生成）',
      'video'),
  DbModelSpec('doubao-seedance-2-0-fast-260128',
      'Doubao-Seedance-2.0-fast（高速動画生成）', 'video'),
  DbModelSpec('doubao-seedance-2-0-260128', 'Doubao-Seedance-2.0（動画生成）', 'video'),
  DbModelSpec('glm-5-2-260617', 'GLM-5.2（コーディングモデル）', 'chat'),
  DbModelSpec('doubao-seed-2-0-mini-260428', 'Doubao-Seed-2.0-mini（言語モデル）', 'chat'),
  DbModelSpec('doubao-seed-evolving-latest-version',
      'Doubao-Seed-Evolving（エージェント言語モデル）', 'chat'),
  DbModelSpec(
      'doubao-seed-2-1-pro-260628', 'Doubao-Seed-2.1-pro（コーディング言語モデル）', 'chat'),
  DbModelSpec('doubao-seed-2-1-turbo-260628', 'Doubao-Seed-2.1-turbo（言語モデル）', 'chat'),
  DbModelSpec(
      'doubao-seed-2-0-lite-260428', 'Doubao-Seed-2.0-lite（マルチモーダル推論モデル）', 'chat'),
];

/// 图片风格预置（前端展示，选中后拼进提示词；也允许自定义）
const List<String> dbImageStyles = <String>[
  'アニメ',
  '二次元',
  '日本アニメ風',
  'ピクセル',
  'シネマティック',
  '特撮風',
  '中国アニメ風',
  '田野風',
];

const String DB_DEFAULT_BASE = 'https://ark.cn-beijing.volces.com/api/v3';
const String DB_DEFAULT_CHAT_MODEL = 'doubao-seed-2-1-pro-260628';
const String DB_DEFAULT_IMAGE_MODEL = 'doubao-seedream-4-5-251128';
const String DB_DEFAULT_VIDEO_MODEL = 'doubao-seedance-2-0-260128';
const String DB_DEFAULT_TTS_MODEL = 'SeedAudio1.0';
const String DB_DEFAULT_PODCAST_MODEL = 'Doubao_scene_SLM_Doubao_Podcast_model';
const String DB_DEFAULT_ASR_MODEL = 'Doubao_Seed_ASR_AUC_2.0';
const String DB_DEFAULT_REALTIME_MODEL = 'Doubao_scene_SLM_Doubao_realtime_voice_model';
const String DB_DEFAULT_VOICE = 'zh_female_xiaohe_uranus_bigtts';
const String DB_DEFAULT_VOICE_B = 'zh_male_qingshuangnanda_mars_bigtts';

// ------------------------------------------------------------
// 配置（明文 JSON，存放在 .sts 内）
// ------------------------------------------------------------
String get dbConfigFile => '$dsChatDir/doubao_config.sts';
String get dbVideoTasksFile => '$dsChatDir/doubao_video_tasks.sts';

class DbConfig {
  String apiKey;
  String baseUrl;
  String chatModel;
  String imageModel;
  String videoModel;
  String ttsModel;
  String podcastModel;
  String asrModel;
  String realtimeModel;
  String voice;
  String voiceB;
  String ttsResourceId;
  bool watermark;
  bool autoRouteAudio;
  /// 快速模式：为 true 时对豆包语言模型关闭深度思考
  /// （实测可把首字正文从 16.8s 降到 0.86s）
  bool fastMode;
  List<String> customModels;

  // ---- 端到端实时语音（Seeduplex）----
  /// 全双工通话音色；留空则沿用 [voice]
  String duplexVoice;
  /// 全双工通话系统提示词；留空则使用内置提示词
  String duplexInstructions;
  /// 全双工通话输出语言（zh/ja/en/ko/ru/fr）
  String duplexLang;
  /// Seeduplex 专用 API Key（豆包语音控制台，非方舟 Key）
  String duplexApiKey;

  // ---- RTC AI 音视频互动 ----
  /// RTC 应用 AppId（控制台 > 实时音视频）
  String rtcAppId;
  /// 火山引擎 AK / SK（用于 RTC OpenAPI V4 签名）
  String rtcAccessKey;
  String rtcSecretKey;
  /// 默认房间号
  String rtcRoomId;
  /// 端到端语音服务的 APP ID / Access Token（RTC 侧 app 鉴权）
  String s2sAppId;
  String s2sToken;

  DbConfig({
    this.apiKey = '',
    this.baseUrl = DB_DEFAULT_BASE,
    this.chatModel = DB_DEFAULT_CHAT_MODEL,
    this.imageModel = DB_DEFAULT_IMAGE_MODEL,
    this.videoModel = DB_DEFAULT_VIDEO_MODEL,
    this.ttsModel = DB_DEFAULT_TTS_MODEL,
    this.podcastModel = DB_DEFAULT_PODCAST_MODEL,
    this.asrModel = DB_DEFAULT_ASR_MODEL,
    this.realtimeModel = DB_DEFAULT_REALTIME_MODEL,
    this.voice = DB_DEFAULT_VOICE,
    this.voiceB = DB_DEFAULT_VOICE_B,
    this.ttsResourceId = '',
    this.watermark = false,
    this.autoRouteAudio = true,
    this.fastMode = true,
    this.duplexVoice = '',
    this.duplexInstructions = '',
    this.duplexLang = 'zh',
    this.duplexApiKey = '',
    this.rtcAppId = '',
    this.rtcAccessKey = '',
    this.rtcSecretKey = '',
    this.rtcRoomId = '',
    this.s2sAppId = '',
    this.s2sToken = '',
    List<String>? customModels,
  }) : customModels = customModels ?? <String>[];

  Map<String, dynamic> toJson() => <String, dynamic>{
        'apiKey': apiKey,
        'baseUrl': baseUrl,
        'chatModel': chatModel,
        'imageModel': imageModel,
        'videoModel': videoModel,
        'ttsModel': ttsModel,
        'podcastModel': podcastModel,
        'asrModel': asrModel,
        'realtimeModel': realtimeModel,
        'voice': voice,
        'voiceB': voiceB,
        'ttsResourceId': ttsResourceId,
        'watermark': watermark,
        'autoRouteAudio': autoRouteAudio,
        'fastMode': fastMode,
        'duplexVoice': duplexVoice,
        'duplexInstructions': duplexInstructions,
        'duplexLang': duplexLang,
        'duplexApiKey': duplexApiKey,
        'rtcAppId': rtcAppId,
        'rtcAccessKey': rtcAccessKey,
        'rtcSecretKey': rtcSecretKey,
        'rtcRoomId': rtcRoomId,
        's2sAppId': s2sAppId,
        's2sToken': s2sToken,
        'customModels': customModels,
      };

  factory DbConfig.fromJson(Map<String, dynamic> j) => DbConfig(
        apiKey: mStr(j, 'apiKey'),
        baseUrl: trimOr(mStr(j, 'baseUrl'), DB_DEFAULT_BASE),
        chatModel: trimOr(mStr(j, 'chatModel'), DB_DEFAULT_CHAT_MODEL),
        imageModel: trimOr(mStr(j, 'imageModel'), DB_DEFAULT_IMAGE_MODEL),
        videoModel: trimOr(mStr(j, 'videoModel'), DB_DEFAULT_VIDEO_MODEL),
        ttsModel: trimOr(mStr(j, 'ttsModel'), DB_DEFAULT_TTS_MODEL),
        podcastModel: trimOr(mStr(j, 'podcastModel'), DB_DEFAULT_PODCAST_MODEL),
        asrModel: trimOr(mStr(j, 'asrModel'), DB_DEFAULT_ASR_MODEL),
        realtimeModel:
            trimOr(mStr(j, 'realtimeModel'), DB_DEFAULT_REALTIME_MODEL),
        voice: trimOr(mStr(j, 'voice'), DB_DEFAULT_VOICE),
        voiceB: trimOr(mStr(j, 'voiceB'), DB_DEFAULT_VOICE_B),
        ttsResourceId: mStr(j, 'ttsResourceId'),
        watermark: mBool(j, 'watermark'),
        autoRouteAudio: mBool(j, 'autoRouteAudio', true),
        fastMode: mBool(j, 'fastMode', true),
        duplexVoice: mStr(j, 'duplexVoice'),
        duplexInstructions: mStr(j, 'duplexInstructions'),
        duplexLang: trimOr(mStr(j, 'duplexLang'), 'zh'),
        duplexApiKey: mStr(j, 'duplexApiKey'),
        rtcAppId: mStr(j, 'rtcAppId'),
        rtcAccessKey: mStr(j, 'rtcAccessKey'),
        rtcSecretKey: mStr(j, 'rtcSecretKey'),
        rtcRoomId: mStr(j, 'rtcRoomId'),
        s2sAppId: mStr(j, 's2sAppId'),
        s2sToken: mStr(j, 's2sToken'),
        customModels: asList(j['customModels']).map((e) => '$e').toList(),
      );
}

DbConfig? _dbCfgCache;
String _dbCfgCacheRaw = '';

DbConfig getDbConfig() {
  try {
    final f = File(dbConfigFile);
    if (!f.existsSync()) {
      return _dbCfgCache ?? DbConfig();
    }
    final raw = f.readAsStringSync();
    if (_dbCfgCache != null && raw == _dbCfgCacheRaw) return _dbCfgCache!;
    final cfg = DbConfig.fromJson(asMap(jsonDecode(raw)));
    _dbCfgCache = cfg;
    _dbCfgCacheRaw = raw;
    return cfg;
  } catch (e) {
    logp('⚠️ 豆包設定の読み込みに失敗しました: $e');
    return DbConfig();
  }
}

bool saveDbConfig(DbConfig cfg) {
  try {
    ensureDir(dsChatDir);
    final raw = const JsonEncoder.withIndent('  ').convert(cfg.toJson());
    File(dbConfigFile).writeAsStringSync(raw);
    Process.runSync('chmod', ['600', dbConfigFile]);
    _dbCfgCache = cfg;
    _dbCfgCacheRaw = raw;
    return true;
  } catch (e) {
    logp('❌ 豆包設定の保存に失敗しました: $e');
    return false;
  }
}

String dbBaseUrl(DbConfig? c) {
  var b = (c ?? getDbConfig()).baseUrl.trim();
  if (b.isEmpty) b = DB_DEFAULT_BASE;
  while (b.endsWith('/')) {
    b = b.substring(0, b.length - 1);
  }
  return b;
}

String dbChatEndpoint() => '${dbBaseUrl(null)}/chat/completions';

/// 快速模式参数：返回需要附加到方舟请求体里的 thinking 字段。
///  · fastMode 关闭 → 返回 null（保留模型默认的深度思考）
///  · 仅对 doubao-seed 系列附加（方舟部分第三方模型不接受该字段）
Map<String, dynamic>? dbThinkingParam(String model) {
  final cfg = getDbConfig();
  if (!cfg.fastMode) return null;
  final m = model.toLowerCase();
  if (!m.startsWith('doubao-seed')) return null;
  return <String, dynamic>{'type': 'disabled'};
}

/// 该模型是否属于豆包（方舟）目录 —— 用于普通聊天里的自动路由判定
bool dbIsChatModel(String model) {
  final m = model.trim();
  if (m.isEmpty) return false;
  final cfg = getDbConfig();
  for (final s in dbModelCatalog) {
    if (s.value == m) return s.cat == 'chat';
  }
  for (final custom in cfg.customModels) {
    if (custom.trim() == m) return true;
  }
  // 常见方舟语言模型前缀兜底（自定义接入时无需逐个登记）
  if (m.startsWith('glm-') ||
      m.startsWith('doubao-seed') ||
      m.startsWith('doubao-1') ||
      m.startsWith('doubao-pro') ||
      m.startsWith('doubao-lite')) {
    return true;
  }
  return false;
}

// ------------------------------------------------------------
// HTTP 基础
// ------------------------------------------------------------
Future<({int code, List<int> bytes})> _httpRaw(
  String method,
  String url, {
  Map<String, String>? headers,
  List<int>? body,
  Duration timeout = const Duration(seconds: 180),
}) async {
  final client = globalHTTPClientWithTimeout;
  final req = await client.openUrl(method, Uri.parse(url)).timeout(timeout);
  headers?.forEach((k, v) => req.headers.set(k, v));
  if (body != null && body.isNotEmpty) req.add(body);
  final resp = await req.close().timeout(timeout);
  final bytes = await resp.fold<List<int>>([], (a, b) => a..addAll(b));
  return (code: resp.statusCode, bytes: bytes);
}

String _errFromBytes(List<int> bytes) {
  final txt = utf8.decode(bytes, allowMalformed: true);
  try {
    final j = asMap(jsonDecode(txt));
    final e = asMap(j['error']);
    final msg = mStr(e, 'message');
    if (msg.isNotEmpty) return msg;
    final m2 = mStr(j, 'message');
    if (m2.isNotEmpty) return m2;
    final code = mStr(j, 'code');
    if (code.isNotEmpty) return '$code ${mStr(j, 'msg')}'.trim();
  } catch (_) {}
  return truncateBytes(txt, 400);
}

Map<String, String> _jsonHeaders(String key, {Map<String, String>? extra}) {
  final h = <String, String>{
    'Content-Type': 'application/json',
    'Authorization': 'Bearer ${key.trim()}',
  };
  if (extra != null) h.addAll(extra);
  return h;
}

/// 统一错误文本（去掉 Exception: 前缀，前端直接展示）
String dbErrText(Object e) {
  var s = '$e';
  const p = 'Exception: ';
  if (s.startsWith(p)) s = s.substring(p.length);
  return s;
}

void _requireKey(DbConfig cfg) {
  if (cfg.apiKey.trim().isEmpty) {
    throw Exception('豆包 API Key が未設定です。設定画面で入力してください。');
  }
}

// ------------------------------------------------------------
// 聊天（非流式，内部使用：剧本生成 / 语音通话回复）
// ------------------------------------------------------------
Future<String> dbChatText(
  String systemPrompt,
  List<Map<String, dynamic>> messages, {
  String? model,
  int maxTokens = 4096,
  double temperature = 0.8,
  Duration timeout = const Duration(seconds: 120),
}) async {
  final cfg = getDbConfig();
  _requireKey(cfg);
  final useModel = trimOr(model, cfg.chatModel);
  final msgs = <Map<String, dynamic>>[];
  if (systemPrompt.trim().isNotEmpty) {
    msgs.add({'role': 'system', 'content': systemPrompt});
  }
  msgs.addAll(messages);
  final body = <String, dynamic>{
    'model': useModel,
    'messages': msgs,
    'stream': false,
    'max_tokens': maxTokens,
    'temperature': temperature,
  };
  final r = await _httpRaw('POST', dbChatEndpoint(),
      headers: _jsonHeaders(cfg.apiKey),
      body: utf8.encode(jsonEncode(body)),
      timeout: timeout);
  if (r.code != 200) {
    throw Exception('豆包 API HTTP ${r.code}: ${_errFromBytes(r.bytes)}');
  }
  final j = asMap(jsonDecode(utf8.decode(r.bytes, allowMalformed: true)));
  final choices = asList(j['choices']);
  if (choices.isEmpty) throw Exception('豆包 API が空の応答を返しました');
  final msg = asMap(asMap(choices[0])['message']);
  final c = mStr(msg, 'content');
  if (c.trim().isEmpty) {
    final rc = mStr(msg, 'reasoning_content');
    if (rc.trim().isNotEmpty) return rc;
  }
  return c;
}

// ------------------------------------------------------------
// 生成物落盘（统一进 ds_files/blob + 元数据）
// ------------------------------------------------------------
String _pickExt(String name, String fallback) {
  final i = name.lastIndexOf('.');
  if (i > 0 && i < name.length - 1) {
    final ext = name.substring(i + 1).toLowerCase();
    if (RegExp(r'^[a-z0-9]{1,6}$').hasMatch(ext)) return ext;
  }
  return fallback;
}

DsFileMeta? saveDbBlob(
  List<int> bytes,
  String name,
  String mime,
  String category, {
  String source = 'doubao',
  String prompt = '',
}) {
  if (bytes.isEmpty) return null;
  try {
    final ext = _pickExt(name, _extByMime(mime));
    var fileName = sanitizeFileName(name.trim());
    if (fileName.isEmpty) fileName = 'doubao_${DateTime.now().millisecondsSinceEpoch}';
    if (!fileName.toLowerCase().endsWith('.$ext')) fileName = '$fileName.$ext';
    final fileID = 'f_${fmtStamp14(DateTime.now())}_${randomHex(6)}';
    final relDir = '${fileID.substring(0, 2)}/$fileID';
    final relPath = '$relDir/$fileName';
    final absPath = '$DSFilesBlobDir/$relPath';
    ensureDir('$DSFilesBlobDir/$relDir');
    File(absPath).writeAsBytesSync(bytes);
    final meta = DsFileMeta(
      id: fileID,
      name: fileName,
      size: bytes.length,
      mimeType: mime,
      category: category,
      createdAt: rfc3339(DateTime.now()),
      relPath: relPath,
      source: source,
      prompt: prompt,
    );
    if (!saveDsFileMeta(meta)) {
      try {
        File(absPath).deleteSync();
      } catch (_) {}
      return null;
    }
    logp('💾 豆包生成物を保存しました: $relPath (${bytes.length} bytes, $mime)');
    return meta;
  } catch (e) {
    logp('❌ 豆包生成物の保存に失敗しました: $e');
    return null;
  }
}

String _extByMime(String mime) {
  final m = mime.toLowerCase();
  if (m.contains('png')) return 'png';
  if (m.contains('jpeg') || m.contains('jpg')) return 'jpg';
  if (m.contains('webp')) return 'webp';
  if (m.contains('mp4')) return 'mp4';
  if (m.contains('webm')) return 'webm';
  if (m.contains('mpeg') || m.contains('mp3')) return 'mp3';
  if (m.contains('wav')) return 'wav';
  if (m.contains('ogg')) return 'ogg';
  return 'bin';
}

String _mimeByExtName(String name, String fallback) {
  final e = name.toLowerCase();
  if (e.endsWith('.png')) return 'image/png';
  if (e.endsWith('.jpg') || e.endsWith('.jpeg')) return 'image/jpeg';
  if (e.endsWith('.webp')) return 'image/webp';
  if (e.endsWith('.mp4')) return 'video/mp4';
  if (e.endsWith('.mp3')) return 'audio/mpeg';
  if (e.endsWith('.wav')) return 'audio/wav';
  return fallback;
}

Map<String, dynamic>? _fileJson(DsFileMeta? m) {
  if (m == null) return null;
  final j = m.toJson();
  j['url'] = '/api/ds-files/download?id=${m.id}';
  j['rawUrl'] = '/api/ds-files/download?id=${m.id}';
  return j;
}

// ------------------------------------------------------------
// 图片尺寸：按比例计算合法像素（Seedream 显式尺寸模式）
// ------------------------------------------------------------
({int w, int h}) dbSizeForRatio(String ratio, String resolution) {
  var a = 1.0;
  var b = 1.0;
  final m = RegExp(r'^\s*(\d+(?:\.\d+)?)\s*[:：/xX*]\s*(\d+(?:\.\d+)?)\s*$')
      .firstMatch(ratio);
  if (m != null) {
    a = double.tryParse(m.group(1)!) ?? 1;
    b = double.tryParse(m.group(2)!) ?? 1;
  }
  if (a <= 0 || b <= 0) {
    a = 1;
    b = 1;
  }
  final r = (a / b).clamp(1 / 16, 16.0).toDouble();
  // 目标总像素：2K ≈ 2048²，4K ≈ 4096²（落在 Seedream 允许区间内）
  final target = resolution.toUpperCase() == '4K' ? 4096.0 * 4096.0 : 2048.0 * 2048.0;
  var w = math.sqrt(target * r);
  var h = w / r;
  int rnd(double v) => math.max(256, (v / 8).round() * 8);
  var wi = rnd(w);
  var hi = rnd(h);
  var px = wi * hi;
  const minPx = 3686400;
  const maxPx = 16777216;
  var guard = 0;
  while (px < minPx && guard++ < 64) {
    wi = rnd(wi * 1.08);
    hi = rnd(hi * 1.08);
    px = wi * hi;
  }
  guard = 0;
  while (px > maxPx && guard++ < 64) {
    wi = rnd(wi * 0.94);
    hi = rnd(hi * 0.94);
    px = wi * hi;
  }
  return (w: wi, h: hi);
}

String _ratioLabel(String ratio) {
  final m = RegExp(r'^\s*(\d+(?:\.\d+)?)\s*[:：/xX*]\s*(\d+(?:\.\d+)?)\s*$')
      .firstMatch(ratio);
  if (m == null) return '1:1';
  return '${m.group(1)}:${m.group(2)}';
}

// ------------------------------------------------------------
// 图片生成
// ------------------------------------------------------------
Future<Map<String, dynamic>> dbGenerateImage({
  required String prompt,
  required String name,
  required String ratio,
  String style = '',
  String customStyle = '',
  String model = '',
  String resolution = '2K',
  bool useRatio = true,
}) async {
  final cfg = getDbConfig();
  _requireKey(cfg);
  final p = prompt.trim();
  if (p.isEmpty) throw Exception('画像の説明が空です');
  final useModel = trimOr(model, cfg.imageModel);
  var fullPrompt = p;
  final st = customStyle.trim().isNotEmpty ? customStyle.trim() : style.trim();
  if (st.isNotEmpty) fullPrompt = '$p\n\n【スタイル】$st';
  final rt = _ratioLabel(ratio);
  fullPrompt = '$fullPrompt\n\n【アスペクト比】$rt';

  Object size = resolution.toUpperCase() == '4K' ? '4K' : '2K';
  if (useRatio) {
    final s = dbSizeForRatio(rt, resolution);
    size = '${s.w}x${s.h}';
  }

  final body = <String, dynamic>{
    'model': useModel,
    'prompt': fullPrompt,
    'size': size,
    'response_format': 'b64_json',
    'watermark': cfg.watermark,
    'sequential_image_generation': 'disabled',
  };
  logp('🎨 豆包画像生成: model=$useModel size=$size ratio=$rt');
  Future<({int code, List<int> bytes})> attempt(Object sz, String fmt) {
    final b = Map<String, dynamic>.from(body);
    b['size'] = sz;
    b['response_format'] = fmt;
    return _httpRaw('POST', '${dbBaseUrl(cfg)}/images/generations',
        headers: _jsonHeaders(cfg.apiKey),
        body: utf8.encode(jsonEncode(b)),
        timeout: const Duration(seconds: 240));
  }

  bool retryable(int code) => code == 400 || code == 422;
  var r = await attempt(size, 'b64_json');
  if (retryable(r.code)) {
    // 一部モデルは b64_json 非対応 → url モードで再試行
    r = await attempt(size, 'url');
  }
  if (retryable(r.code) && size is String && size != resolution) {
    // 明示ピクセル指定を受け付けないモデル（例：5.0-pro）→ プリセット解像度で再試行
    logp('⚠️ 明示サイズ $size が拒否されました。解像度プリセット $resolution で再試行します');
    final preset = resolution.toUpperCase() == '4K' ? '4K' : '2K';
    r = await attempt(preset, 'b64_json');
    if (retryable(r.code)) r = await attempt(preset, 'url');
  }
  if (r.code != 200) {
    throw Exception('豆包画像生成に失敗しました（HTTP ${r.code}）: ${_errFromBytes(r.bytes)}');
  }
  final j = asMap(jsonDecode(utf8.decode(r.bytes, allowMalformed: true)));
  final data = asList(j['data']);
  if (data.isEmpty) throw Exception('豆包画像生成: 画像データが返されませんでした');
  final first = asMap(data[0]);
  final b64 = mStr(first, 'b64_json');
  final url = mStr(first, 'url');
  List<int>? bytes;
  if (b64.isNotEmpty) {
    try {
      bytes = base64.decode(b64);
    } catch (e) {
      throw Exception('画像 base64 のデコードに失敗: $e');
    }
  } else if (url.isNotEmpty) {
    final dl = await _httpRaw('GET', url,
        timeout: const Duration(seconds: 180));
    if (dl.code != 200 || dl.bytes.isEmpty) {
      throw Exception('生成画像のダウンロードに失敗しました（HTTP ${dl.code}）');
    }
    bytes = dl.bytes;
  }
  if (bytes == null || bytes.isEmpty) {
    throw Exception('豆包画像生成: 画像本体が取得できませんでした');
  }
  final outName = name.trim().isEmpty
      ? 'doubao_image_${fmtStamp14(DateTime.now())}'
      : name.trim();
  final meta = saveDbBlob(bytes, outName, _mimeByExtName(outName, 'image/png'),
      'image',
      source: 'doubao-image', prompt: p);
  if (meta == null) throw Exception('生成画像の保存に失敗しました');
  return {
    'success': true,
    'file': _fileJson(meta),
    'model': useModel,
    'size': '$size',
    'ratio': rt,
    'style': st,
    'revisedPrompt': mStr(first, 'revised_prompt'),
  };
}

// ------------------------------------------------------------
// 视频生成（异步任务）
// ------------------------------------------------------------
List<Map<String, dynamic>> _loadVideoTasks() {
  try {
    final f = File(dbVideoTasksFile);
    if (!f.existsSync()) return <Map<String, dynamic>>[];
    final out = <Map<String, dynamic>>[];
    for (final line in f.readAsStringSync().split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      out.add(asMap(jsonDecode(t)));
    }
    return out;
  } catch (_) {
    return <Map<String, dynamic>>[];
  }
}

void _saveVideoTasks(List<Map<String, dynamic>> tasks) {
  try {
    ensureDir(dsChatDir);
    final sb = StringBuffer();
    for (final t in tasks) {
      sb.writeln(jsonEncode(t));
    }
    File(dbVideoTasksFile).writeAsStringSync(sb.toString());
  } catch (e) {
    logp('❌ 豆包動画タスクの保存に失敗しました: $e');
  }
}

Map<String, dynamic> _upsertVideoTask(String id, Map<String, dynamic> patch) {
  final tasks = _loadVideoTasks();
  Map<String, dynamic>? found;
  for (final t in tasks) {
    if (mStr(t, 'id') == id) {
      t.addAll(patch);
      found = t;
      break;
    }
  }
  if (found == null) {
    found = <String, dynamic>{'id': id, ...patch};
    tasks.insert(0, found);
  }
  while (tasks.length > 60) {
    tasks.removeLast();
  }
  _saveVideoTasks(tasks);
  return found;
}

Future<Map<String, dynamic>> dbCreateVideoTask({
  required String prompt,
  required String name,
  String ratio = '16:9',
  String resolution = '720p',
  int duration = 5,
  bool generateAudio = true,
  String model = '',
}) async {
  final cfg = getDbConfig();
  _requireKey(cfg);
  final p = prompt.trim();
  if (p.isEmpty) throw Exception('動画の説明が空です');
  final useModel = trimOr(model, cfg.videoModel);
  var res = resolution.trim().toLowerCase();
  if (res == '480p' || res == '720p' || res == '1080p' || res == '4k') {
    // ok
  } else {
    res = '720p';
  }
  var dur = duration;
  if (dur < 4) dur = 4;
  if (dur > 15) dur = 15;
  final body = <String, dynamic>{
    'model': useModel,
    'content': [
      {'type': 'text', 'text': p}
    ],
    'ratio': _ratioLabel(ratio),
    'resolution': res,
    'duration': dur,
    'generate_audio': generateAudio,
    'watermark': cfg.watermark,
  };
  logp('🎬 豆包動画生成: model=$useModel ratio=${body['ratio']} res=$res dur=$dur');
  final r = await _httpRaw('POST', '${dbBaseUrl(cfg)}/contents/generations/tasks',
      headers: _jsonHeaders(cfg.apiKey),
      body: utf8.encode(jsonEncode(body)),
      timeout: const Duration(seconds: 120));
  if (r.code != 200) {
    throw Exception('豆包動画タスク作成に失敗（HTTP ${r.code}）: ${_errFromBytes(r.bytes)}');
  }
  final j = asMap(jsonDecode(utf8.decode(r.bytes, allowMalformed: true)));
  final taskID = mStr(j, 'id');
  if (taskID.isEmpty) {
    throw Exception('豆包動画タスク: タスク ID が返されませんでした: ${truncateBytes(jsonEncode(j), 300)}');
  }
  final nameOut = name.trim().isEmpty
      ? 'doubao_video_${fmtStamp14(DateTime.now())}'
      : name.trim();
  final task = _upsertVideoTask(taskID, {
    'status': 'queued',
    'name': nameOut,
    'prompt': p,
    'model': useModel,
    'ratio': body['ratio'],
    'resolution': res,
    'duration': dur,
    'createdAt': rfc3339(DateTime.now()),
    'fileId': '',
    'videoUrl': '',
  });
  return {'success': true, 'task': task};
}

Future<Map<String, dynamic>> dbPollVideoTask(String taskID) async {
  final cfg = getDbConfig();
  _requireKey(cfg);
  if (taskID.trim().isEmpty) throw Exception('タスク ID が空です');
  final r = await _httpRaw(
      'GET', '${dbBaseUrl(cfg)}/contents/generations/tasks/${Uri.encodeComponent(taskID)}',
      headers: _jsonHeaders(cfg.apiKey),
      timeout: const Duration(seconds: 90));
  if (r.code != 200) {
    throw Exception('豆包動画タスク照会に失敗（HTTP ${r.code}）: ${_errFromBytes(r.bytes)}');
  }
  final j = asMap(jsonDecode(utf8.decode(r.bytes, allowMalformed: true)));
  final status = mStr(j, 'status');
  final content = asMap(j['content']);
  final videoUrl = mStr(content, 'video_url');
  final errMsg = asMap(j['error']);

  final tasks = _loadVideoTasks();
  Map<String, dynamic>? local;
  for (final t in tasks) {
    if (mStr(t, 'id') == taskID) {
      local = t;
      break;
    }
  }

  // 完成后下载落盘（只做一次）
  if (status == 'succeeded' &&
      videoUrl.isNotEmpty &&
      (local == null || mStr(local, 'fileId').isEmpty)) {
    final nm = local == null ? '' : mStr(local, 'name');
    final outName =
        nm.isEmpty ? 'doubao_video_${fmtStamp14(DateTime.now())}' : nm;
    final dl = await _httpRaw('GET', videoUrl,
        timeout: const Duration(seconds: 600));
    if (dl.code == 200 && dl.bytes.isNotEmpty) {
      final meta = saveDbBlob(
        dl.bytes,
        outName,
        'video/mp4',
        'video',
        source: 'doubao-video',
        prompt: local == null ? '' : mStr(local, 'prompt'),
      );
      if (meta != null) {
        local = _upsertVideoTask(taskID, {
          'status': status,
          'videoUrl': videoUrl,
          'fileId': meta.id,
          'file': _fileJson(meta),
          'updatedAt': rfc3339(DateTime.now()),
        });
      }
    } else {
      logp('⚠️ 豆包動画のダウンロードに失敗しました（HTTP ${dl.code}）');
    }
  }
  final updated = _upsertVideoTask(taskID, {
    'status': status.isEmpty ? mStr(local ?? {}, 'status') : status,
    'videoUrl': videoUrl.isEmpty ? mStr(local ?? {}, 'videoUrl') : videoUrl,
    'error': errMsg.isEmpty ? '' : _errFromBytes(utf8.encode(jsonEncode(errMsg))),
    'updatedAt': rfc3339(DateTime.now()),
  });
  return {
    'success': true,
    'task': {
      ...updated,
      if (mStr(updated, 'fileId').isEmpty && videoUrl.isNotEmpty) ...{
        'remoteUrl': videoUrl,
      },
    },
    'status': status,
  };
}

// ------------------------------------------------------------
// 语音合成（TTS / 播客 / 音频生成）
// ------------------------------------------------------------
Future<List<int>> dbSpeech(
  String text, {
  String? voice,
  String? model,
  String format = 'mp3',
  double speed = 1.0,
}) async {
  final cfg = getDbConfig();
  _requireKey(cfg);
  final t = text.trim();
  if (t.isEmpty) throw Exception('読み上げるテキストが空です');
  final useModel = trimOr(model, cfg.ttsModel);
  final useVoice = trimOr(voice, cfg.voice);
  final body = <String, dynamic>{
    'model': useModel,
    'input': t,
    'voice': useVoice,
    'response_format': format,
    'speed': speed,
  };
  final extra = <String, String>{};
  if (cfg.ttsResourceId.trim().isNotEmpty) {
    extra['X-Api-Resource-Id'] = cfg.ttsResourceId.trim();
  }
  final r = await _httpRaw('POST', '${dbBaseUrl(cfg)}/audio/speech',
      headers: _jsonHeaders(cfg.apiKey, extra: extra.isEmpty ? null : extra),
      body: utf8.encode(jsonEncode(body)),
      timeout: const Duration(seconds: 180));
  if (r.code != 200) {
    throw Exception('豆包音声合成に失敗（HTTP ${r.code}）: ${_errFromBytes(r.bytes)}');
  }
  final ct = r.bytes.length > 4 && r.bytes[0] == 0x7B; // JSON 错误体
  if (ct) {
    throw Exception('豆包音声合成: ${_errFromBytes(r.bytes)}');
  }
  if (r.bytes.isEmpty) throw Exception('豆包音声合成: 音声データが空です');
  return r.bytes;
}

// ------------------------------------------------------------
// 录音文件识别（ASR）
//   优先走方舟 /audio/transcriptions；失败时回退本地 whisper.cpp（若已安装）
// ------------------------------------------------------------
List<int> _multipartBody(
  List<({String name, String value})> fields,
  String fileField,
  String fileName,
  String fileMime,
  List<int> fileBytes,
) {
  final boundary =
      '----dsh${DateTime.now().microsecondsSinceEpoch}${randomHex(6)}';
  final out = <int>[];
  void addStr(String s) => out.addAll(utf8.encode(s));
  for (final f in fields) {
    addStr('--$boundary\r\n');
    addStr('Content-Disposition: form-data; name="${f.name}"\r\n\r\n');
    addStr('${f.value}\r\n');
  }
  addStr('--$boundary\r\n');
  addStr('Content-Disposition: form-data; name="$fileField"; filename="$fileName"\r\n');
  addStr('Content-Type: $fileMime\r\n\r\n');
  out.addAll(fileBytes);
  addStr('\r\n--$boundary--\r\n');
  return out;
}

Future<String> dbTranscribeBytes(
  List<int> audio,
  String fileName, {
  String? model,
}) async {
  if (audio.length < 200) throw Exception('音声が短すぎます');
  final cfg = getDbConfig();
  var lastErr = '';
  if (cfg.apiKey.trim().isNotEmpty) {
    try {
      final useModel = trimOr(model, cfg.asrModel);
      final mime = _mimeByExtName(fileName, 'audio/webm');
      final boundary =
          '----dsh${DateTime.now().microsecondsSinceEpoch}${randomHex(6)}';
      final body = _multipartBody(
        [(name: 'model', value: useModel), (name: 'response_format', value: 'json')],
        'file',
        sanitizeFileName(fileName.isEmpty ? 'audio.webm' : fileName),
        mime,
        audio,
      );
      final r = await _httpRaw('POST', '${dbBaseUrl(cfg)}/audio/transcriptions',
          headers: {
            'Content-Type': 'multipart/form-data; boundary=$boundary',
            'Authorization': 'Bearer ${cfg.apiKey.trim()}',
          },
          body: body,
          timeout: const Duration(seconds: 180));
      if (r.code == 200) {
        final txt = utf8.decode(r.bytes, allowMalformed: true);
        try {
          final j = asMap(jsonDecode(txt));
          final t = mStr(j, 'text');
          if (t.trim().isNotEmpty) return t.trim();
          final data = asList(j['data']);
          if (data.isNotEmpty) {
            final t2 = mStr(asMap(data[0]), 'text');
            if (t2.trim().isNotEmpty) return t2.trim();
          }
        } catch (_) {
          if (txt.trim().isNotEmpty && !txt.trim().startsWith('{')) {
            return txt.trim();
          }
        }
        lastErr = '豆包 ASR が空の結果を返しました';
      } else {
        lastErr = 'HTTP ${r.code}: ${_errFromBytes(r.bytes)}';
      }
    } catch (e) {
      lastErr = '$e';
    }
    logp('⚠️ 豆包 ASR に失敗しました（ローカル認識へフォールバック）: $lastErr');
  } else {
    lastErr = '豆包 API Key 未設定';
  }

  final local = await _whisperTranscribe(audio, fileName);
  if (local.isNotEmpty) return local;
  throw Exception('音声認識に失敗しました: $lastErr');
}

Future<String> _whisperTranscribe(List<int> audio, String fileName) async {
  final model = File('$BASE_DIR/models/ggml-base-q5_1.bin');
  final bin = File('$BASE_DIR/whisper.cpp/build/bin/whisper-cli');
  if (!model.existsSync() || !bin.existsSync()) return '';
  final tmpDir = Directory.systemTemp.path;
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final inFile = '$tmpDir/db_asr_in_$stamp.bin';
  final wavFile = '$tmpDir/db_asr_$stamp.wav';
  try {
    File(inFile).writeAsBytesSync(audio);
    final ff = await Process.run(
        'ffmpeg', ['-y', '-loglevel', 'error', '-i', inFile, '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le', wavFile]);
    if (ff.exitCode != 0) {
      logp('⚠️ ローカル ASR の ffmpeg 変換に失敗: ${ff.stderr}');
      return '';
    }
    final wh = await Process.run(bin.path,
        ['-m', model.path, '-f', wavFile, '-l', 'zh', '-nt', '-np']);
    if (wh.exitCode != 0) {
      logp('⚠️ ローカル whisper の実行に失敗: ${wh.stderr}');
      return '';
    }
    var out = '${wh.stdout}';
    out = out.replaceAll(RegExp(r'\[[^\]]*\]|\([^)]*\)|（[^）]*）'), '');
    final lines = <String>[];
    for (var ln in out.split('\n')) {
      ln = ln.trim();
      if (ln.isEmpty || ln.startsWith('output_')) continue;
      lines.add(ln);
    }
    final text = lines.join(' ').trim();
    if (text.isNotEmpty) logp('🎤 ローカル ASR 結果: $text');
    return text;
  } catch (e) {
    logp('⚠️ ローカル ASR 例外: $e');
    return '';
  } finally {
    for (final p in [inFile, wavFile]) {
      try {
        final f = File(p);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }
}

/// 对已上传到 ds_files 的音频做识别（普通聊天自动路由使用）
Future<String> dbTranscribeFile(String fileID) async {
  final meta = getDsFileMeta(fileID);
  if (meta == null) throw Exception('音声ファイルが見つかりません: $fileID');
  final f = File('$DSFilesBlobDir/${meta.relPath}');
  if (!f.existsSync()) throw Exception('音声ファイル本体が見つかりません: ${meta.name}');
  final bytes = f.readAsBytesSync();
  if (bytes.length > 40 * 1024 * 1024) {
    throw Exception('音声ファイルが大きすぎます（40MB 上限）');
  }
  return dbTranscribeBytes(bytes, meta.name);
}

bool dbIsAudioFile(String fileID) {
  final meta = getDsFileMeta(fileID);
  if (meta == null) return false;
  final mime = meta.mimeType.toLowerCase();
  if (mime.startsWith('audio/')) return true;
  final n = meta.name.toLowerCase();
  const exts = [
    '.mp3', '.wav', '.m4a', '.aac', '.ogg', '.opus', '.flac', '.amr', '.caf', '.wma'
  ];
  for (final e in exts) {
    if (n.endsWith(e)) return true;
  }
  return false;
}

// ------------------------------------------------------------
// 播客：剧本生成 + 多音色合成 + MP3 拼接
// ------------------------------------------------------------
String dbPodcastSystemPrompt(String lang, int minutes) {
  final langName = const {
        'zh': '简体中文',
        'en': 'English',
        'ja': '日本語',
        'ko': '한국어',
        'ru': 'русский',
        'fr': 'français',
      }[lang] ??
      '简体中文';
  return '''あなたは音声番組（ポッドキャスト）の構成作家です。以下の条件で台本を書いてください。
1. 言語は必ず $langName で書くこと。
2. 2 人のパーソナリティ（A と B）の自然会話にすること。相づち・ツッコミ・具体例を入れる。
3. 全体で約 $minutes 分の読み上げ量（目安として日本語 350 文字/分）。
4. 出力は厳密な JSON 配列のみ。前後に説明文・コードフェンスを一切付けない。
5. 各要素は {"speaker":"A"|"B","text":"セリフ"} の形式。1 セリフは 120 文字以内。
6. 事実と異なる断定を避け、誇張しすぎない。''';
}

List<Map<String, String>> dbParsePodcastScript(String raw) {
  var s = raw.trim();
  if (s.startsWith('```')) {
    s = s.replaceFirst(RegExp(r'^```[a-zA-Z]*\s*'), '');
    s = s.replaceFirst(RegExp(r'```\s*$'), '');
  }
  final out = <Map<String, String>>[];
  final start = s.indexOf('[');
  final end = s.lastIndexOf(']');
  if (start >= 0 && end > start) {
    try {
      final arr = asList(jsonDecode(s.substring(start, end + 1)));
      for (final e in arr) {
        final m = asMap(e);
        final t = mStr(m, 'text').trim();
        if (t.isEmpty) continue;
        final sp = mStr(m, 'speaker').trim().toUpperCase();
        out.add({'speaker': sp == 'B' ? 'B' : 'A', 'text': t});
      }
    } catch (_) {}
  }
  if (out.isNotEmpty) return out;
  // 兜底：按「A:」「B:」行解析
  for (var line in s.split('\n')) {
    line = line.trim();
    if (line.isEmpty) continue;
    final m = RegExp(r'^(A|B)\s*[:：]\s*(.+)$').firstMatch(line);
    if (m != null) {
      out.add({'speaker': m.group(1)!, 'text': m.group(2)!.trim()});
    }
  }
  if (out.isEmpty && s.isNotEmpty) {
    out.add({'speaker': 'A', 'text': s});
  }
  return out;
}

Future<Map<String, dynamic>> dbGeneratePodcast({
  required String topic,
  String style = '',
  int minutes = 3,
  String name = '',
  String lang = 'zh',
  String voiceA = '',
  String voiceB = '',
  String model = '',
}) async {
  final cfg = getDbConfig();
  _requireKey(cfg);
  final t = topic.trim();
  if (t.isEmpty) throw Exception('ポッドキャストのテーマが空です');
  var mins = minutes;
  if (mins < 1) mins = 1;
  if (mins > 20) mins = 20;
  final sys = dbPodcastSystemPrompt(lang, mins);
  final user = StringBuffer()
    ..writeln('テーマ: $t');
  if (style.trim().isNotEmpty) user.writeln('雰囲気・スタイル: ${style.trim()}');
  user.writeln('想定尺: 約 $mins 分');
  user.writeln('上記条件で JSON 配列の台本を出力してください。');

  final raw = await dbChatText(sys, [
    {'role': 'user', 'content': user.toString()}
  ], model: model.isEmpty ? cfg.chatModel : model, maxTokens: 6000, temperature: 0.9);
  final script = dbParsePodcastScript(raw);
  if (script.isEmpty) throw Exception('台本の生成に失敗しました（空の応答）');

  final usePodModel = trimOr(model, cfg.podcastModel);
  final vA = trimOr(voiceA, cfg.voice);
  final vB = trimOr(voiceB, cfg.voiceB);
  final audio = <int>[];
  final failLines = <String>[];
  for (var i = 0; i < script.length; i++) {
    final line = script[i];
    final text = line['text'] ?? '';
    if (text.trim().isEmpty) continue;
    try {
      final bytes = await dbSpeech(text,
          voice: line['speaker'] == 'B' ? vB : vA,
          model: usePodModel,
          format: 'mp3');
      audio.addAll(bytes);
    } catch (e) {
      logp('⚠️ ポッドキャスト ${i + 1}/${script.length} 行目の合成に失敗: $e');
      failLines.add(text);
    }
  }
  if (audio.isEmpty) {
    throw Exception('音声合成に失敗しました（全 ${script.length} 行）。モデルまたは音色をご確認ください。');
  }
  final outName = name.trim().isEmpty
      ? 'doubao_podcast_${fmtStamp14(DateTime.now())}'
      : name.trim();
  final meta = saveDbBlob(audio, outName, 'audio/mpeg', 'audio',
      source: 'doubao-podcast', prompt: t);
  if (meta == null) throw Exception('ポッドキャスト音声の保存に失敗しました');
  return {
    'success': true,
    'file': _fileJson(meta),
    'script': script,
    'scriptText': script
        .map((e) => '${e['speaker']}: ${e['text']}')
        .join('\n'),
    'lines': script.length,
    'failedLines': failLines.length,
    'model': usePodModel,
    'voices': {'A': vA, 'B': vB},
  };
}

// ------------------------------------------------------------
// 语音通话回合：录音 → 识别 → 回复 → 合成
// ------------------------------------------------------------
Future<Map<String, dynamic>> dbVoiceTurn({
  required List<int> audio,
  required String fileName,
  List<Map<String, dynamic>> history = const [],
  String lang = 'zh',
  String voice = '',
  String model = '',
  String text = '',
}) async {
  final cfg = getDbConfig();
  final heard = text.trim().isNotEmpty
      ? text.trim()
      : await dbTranscribeBytes(audio, fileName, model: cfg.asrModel);
  final langRule = dsLangSystemPrompt(lang);
  final sys = '''あなたは音声通話の相手です。$langRule
音声で読み上げられるため、次の制約を厳守してください：
1. 返答は 2〜4 文、120 文字以内。前置き・箇条書き・記号過多を避ける。
2. 自然な話し言葉で、聞き取りやすい短文にする。
3. 不明な点は 1 つだけ短く質問する。''';
  final msgs = <Map<String, dynamic>>[];
  for (final h in history.take(20)) {
    final role = mStr(h, 'role');
    final c = mStr(h, 'content');
    if ((role == 'user' || role == 'assistant') && c.trim().isNotEmpty) {
      msgs.add({'role': role, 'content': c});
    }
  }
  msgs.add({'role': 'user', 'content': heard});
  final reply = await dbChatText(sys, msgs,
      model: model.isEmpty ? cfg.chatModel : model,
      maxTokens: 800,
      temperature: 0.8);
  final audioBytes = await dbSpeech(reply, voice: voice, model: cfg.ttsModel);
  final meta = saveDbBlob(audioBytes,
      'doubao_voice_${fmtStamp14(DateTime.now())}', 'audio/mpeg', 'audio',
      source: 'doubao-voice', prompt: heard);
  return {
    'success': true,
    'userText': heard,
    'reply': reply,
    'file': _fileJson(meta),
    'audioUrl': meta == null ? '' : '/api/ds-files/download?id=${meta.id}',
  };
}

// ------------------------------------------------------------
// HTTP 处理器
// ------------------------------------------------------------
Map<String, dynamic> _modelListJson() {
  final cfg = getDbConfig();
  final list = <Map<String, dynamic>>[
    for (final m in dbModelCatalog)
      {'value': m.value, 'label': m.label, 'category': m.cat, 'custom': false}
  ];
  for (final c in cfg.customModels) {
    final v = c.trim();
    if (v.isEmpty) continue;
    if (list.any((e) => e['value'] == v)) continue;
    list.add({'value': v, 'label': v, 'category': 'chat', 'custom': true});
  }
  return {'models': list, 'styles': dbImageStyles};
}

Map<String, dynamic> _configJson() {
  final cfg = getDbConfig();
  var masked = '';
  final k = cfg.apiKey.trim();
  if (k.length > 8) {
    masked = '${k.substring(0, 4)}••••${k.substring(k.length - 4)}';
  } else if (k.isNotEmpty) {
    masked = '••••••••';
  }
  return {
    'hasKey': k.isNotEmpty,
    'maskedKey': masked,
    'baseUrl': cfg.baseUrl,
    'chatModel': cfg.chatModel,
    'imageModel': cfg.imageModel,
    'videoModel': cfg.videoModel,
    'ttsModel': cfg.ttsModel,
    'podcastModel': cfg.podcastModel,
    'asrModel': cfg.asrModel,
    'realtimeModel': cfg.realtimeModel,
    'voice': cfg.voice,
    'voiceB': cfg.voiceB,
    'ttsResourceId': cfg.ttsResourceId,
    'watermark': cfg.watermark,
    'autoRouteAudio': cfg.autoRouteAudio,
    'fastMode': cfg.fastMode,
    'duplexVoice': cfg.duplexVoice,
    'duplexInstructions': cfg.duplexInstructions,
    'duplexLang': cfg.duplexLang,
    'hasDuplexKey': cfg.duplexApiKey.trim().isNotEmpty,
    'rtcAppId': cfg.rtcAppId,
    'rtcRoomId': cfg.rtcRoomId,
    'hasRtcKeys': cfg.rtcAccessKey.trim().isNotEmpty &&
        cfg.rtcSecretKey.trim().isNotEmpty,
    'hasS2s': cfg.s2sAppId.trim().isNotEmpty && cfg.s2sToken.trim().isNotEmpty,
    's2sAppId': cfg.s2sAppId,
    'customModels': cfg.customModels,
    'catalog': _modelListJson(),
  };
}

Future<void> handleDbConfig(HttpRequest req) async {
  final res = req.response;
  if (req.method == 'GET') {
    await dsJSONOk(res, 200, {'success': true, ..._configJson()});
    return;
  }
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
  final old = getDbConfig();
  final cfg = DbConfig(
    apiKey: mStr(body, 'apiKey').trim().isEmpty
        ? old.apiKey
        : mStr(body, 'apiKey').trim(),
    baseUrl: trimOr(mStr(body, 'baseUrl'), old.baseUrl),
    chatModel: trimOr(mStr(body, 'chatModel'), old.chatModel),
    imageModel: trimOr(mStr(body, 'imageModel'), old.imageModel),
    videoModel: trimOr(mStr(body, 'videoModel'), old.videoModel),
    ttsModel: trimOr(mStr(body, 'ttsModel'), old.ttsModel),
    podcastModel: trimOr(mStr(body, 'podcastModel'), old.podcastModel),
    asrModel: trimOr(mStr(body, 'asrModel'), old.asrModel),
    realtimeModel: trimOr(mStr(body, 'realtimeModel'), old.realtimeModel),
    voice: trimOr(mStr(body, 'voice'), old.voice),
    voiceB: trimOr(mStr(body, 'voiceB'), old.voiceB),
    ttsResourceId: body.containsKey('ttsResourceId')
        ? mStr(body, 'ttsResourceId').trim()
        : old.ttsResourceId,
    watermark: body.containsKey('watermark')
        ? mBool(body, 'watermark')
        : old.watermark,
    autoRouteAudio: body.containsKey('autoRouteAudio')
        ? mBool(body, 'autoRouteAudio', true)
        : old.autoRouteAudio,
    fastMode: body.containsKey('fastMode')
        ? mBool(body, 'fastMode', true)
        : old.fastMode,
    duplexVoice: body.containsKey('duplexVoice')
        ? mStr(body, 'duplexVoice').trim()
        : old.duplexVoice,
    duplexInstructions: body.containsKey('duplexInstructions')
        ? mStr(body, 'duplexInstructions').trim()
        : old.duplexInstructions,
    duplexLang: body.containsKey('duplexLang')
        ? trimOr(mStr(body, 'duplexLang'), old.duplexLang)
        : old.duplexLang,
    duplexApiKey: body.containsKey('duplexApiKey')
        ? mStr(body, 'duplexApiKey').trim()
        : old.duplexApiKey,
    rtcAppId: body.containsKey('rtcAppId')
        ? mStr(body, 'rtcAppId').trim()
        : old.rtcAppId,
    rtcAccessKey: body.containsKey('rtcAccessKey')
        ? mStr(body, 'rtcAccessKey').trim()
        : old.rtcAccessKey,
    rtcSecretKey: body.containsKey('rtcSecretKey')
        ? mStr(body, 'rtcSecretKey').trim()
        : old.rtcSecretKey,
    rtcRoomId: body.containsKey('rtcRoomId')
        ? mStr(body, 'rtcRoomId').trim()
        : old.rtcRoomId,
    s2sAppId: body.containsKey('s2sAppId')
        ? mStr(body, 's2sAppId').trim()
        : old.s2sAppId,
    s2sToken: body.containsKey('s2sToken')
        ? mStr(body, 's2sToken').trim()
        : old.s2sToken,
    customModels: body.containsKey('customModels')
        ? asList(body['customModels'])
            .map((e) => '$e'.trim())
            .where((e) => e.isNotEmpty)
            .toList()
        : old.customModels,
  );
  // 允许显式清空 Key（clearKey=1）
  if (mBool(body, 'clearKey')) cfg.apiKey = '';
  if (!saveDbConfig(cfg)) {
    await dsJSONErr(res, 500, '設定の保存に失敗しました');
    return;
  }
  await dsJSONOk(res, 200, {'success': true, ..._configJson()});
}

Future<void> handleDbModels(HttpRequest req) async {
  await dsJSONOk(req.response, 200, {'success': true, ..._modelListJson()});
}

Future<void> handleDbImage(HttpRequest req) async {
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
  try {
    final out = await dbGenerateImage(
      prompt: mStr(body, 'prompt'),
      name: mStr(body, 'name'),
      ratio: trimOr(mStr(body, 'ratio'), '1:1'),
      style: mStr(body, 'style'),
      customStyle: mStr(body, 'customStyle'),
      model: mStr(body, 'model'),
      resolution: trimOr(mStr(body, 'resolution'), '2K'),
      useRatio: mBool(body, 'useRatio', true),
    );
    await dsJSONOk(res, 200, out);
  } catch (e) {
    logp('❌ 豆包画像生成エラー: $e');
    await dsJSONErr(res, 500, dbErrText(e));
  }
}

Future<void> handleDbVideoCreate(HttpRequest req) async {
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
  try {
    final out = await dbCreateVideoTask(
      prompt: mStr(body, 'prompt'),
      name: mStr(body, 'name'),
      ratio: trimOr(mStr(body, 'ratio'), '16:9'),
      resolution: trimOr(mStr(body, 'resolution'), '720p'),
      duration: intArgDefault(body, 'duration', 5),
      generateAudio: mBool(body, 'generateAudio', true),
      model: mStr(body, 'model'),
    );
    await dsJSONOk(res, 200, out);
  } catch (e) {
    logp('❌ 豆包動画生成エラー: $e');
    await dsJSONErr(res, 500, dbErrText(e));
  }
}

Future<void> handleDbVideoStatus(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'GET') {
    await dsJSONErr(res, 405, 'Method not allowed');
    return;
  }
  final id = qp(req, 'taskId');
  try {
    final out = await dbPollVideoTask(id);
    await dsJSONOk(res, 200, out);
  } catch (e) {
    logp('❌ 豆包動画照会エラー: $e');
    await dsJSONErr(res, 500, dbErrText(e));
  }
}

Future<void> handleDbVideoTasks(HttpRequest req) async {
  final res = req.response;
  if (req.method == 'DELETE') {
    final id = qp(req, 'id');
    final tasks = _loadVideoTasks();
    final kept = tasks.where((t) => mStr(t, 'id') != id).toList();
    _saveVideoTasks(kept);
    await dsJSONOk(res, 200, {'success': true, 'removed': tasks.length - kept.length});
    return;
  }
  await dsJSONOk(res, 200, {'success': true, 'tasks': _loadVideoTasks()});
}

Future<void> handleDbTts(HttpRequest req) async {
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
  try {
    final text = mStr(body, 'text');
    final bytes = await dbSpeech(
      text,
      voice: mStr(body, 'voice'),
      model: mStr(body, 'model'),
      format: trimOr(mStr(body, 'format'), 'mp3'),
      speed: double.tryParse(mStr(body, 'speed')) ?? 1.0,
    );
    final name = trimOr(mStr(body, 'name'), 'doubao_tts_${fmtStamp14(DateTime.now())}');
    final meta = saveDbBlob(bytes, name, 'audio/mpeg', 'audio',
        source: 'doubao-tts', prompt: truncateRunes(text, 120));
    await dsJSONOk(res, 200, {
      'success': true,
      'file': _fileJson(meta),
      'audioUrl': meta == null ? '' : '/api/ds-files/download?id=${meta.id}',
    });
  } catch (e) {
    logp('❌ 豆包音声合成エラー: $e');
    await dsJSONErr(res, 500, dbErrText(e));
  }
}

Future<void> handleDbPodcast(HttpRequest req) async {
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
  try {
    final out = await dbGeneratePodcast(
      topic: mStr(body, 'topic'),
      style: mStr(body, 'style'),
      minutes: intArgDefault(body, 'minutes', 3),
      name: mStr(body, 'name'),
      lang: trimOr(mStr(body, 'lang'), 'zh'),
      voiceA: mStr(body, 'voiceA'),
      voiceB: mStr(body, 'voiceB'),
      model: mStr(body, 'model'),
    );
    await dsJSONOk(res, 200, out);
  } catch (e) {
    logp('❌ 豆包ポッドキャスト生成エラー: $e');
    await dsJSONErr(res, 500, dbErrText(e));
  }
}

/// 从 multipart / 原始 body 中取出音频字节
List<int> extractAudioPayload(List<int> raw) {
  // 找第一个 \r\n\r\n 作为头结束，再找最后一个 \r\n--boundary
  final headEnd = _indexOfSeq(raw, [13, 10, 13, 10], 0);
  if (headEnd < 0) return raw;
  final head = latin1.decode(raw.sublist(0, headEnd), allowInvalid: true);
  if (!head.toLowerCase().contains('content-disposition')) return raw;
  final start = headEnd + 4;
  // 尾部：\r\n--boundary
  var tailStart = raw.length;
  for (var i = raw.length - 4; i >= start; i--) {
    if (raw[i] == 13 && raw[i + 1] == 10 && raw[i + 2] == 45 && raw[i + 3] == 45) {
      tailStart = i;
      break;
    }
  }
  if (tailStart <= start) return raw.sublist(start);
  return raw.sublist(start, tailStart);
}

int _indexOfSeq(List<int> hay, List<int> needle, int from) {
  outer:
  for (var i = from; i <= hay.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

String _fileNameFromMultipart(List<int> raw, String fallback) {
  final headEnd = _indexOfSeq(raw, [13, 10, 13, 10], 0);
  if (headEnd < 0) return fallback;
  final head = latin1.decode(raw.sublist(0, headEnd), allowInvalid: true);
  final m = RegExp(r'filename="([^"]+)"').firstMatch(head);
  if (m != null && m.group(1)!.trim().isNotEmpty) {
    return sanitizeFileName(m.group(1)!);
  }
  final ct = RegExp(r'Content-Type:\s*(audio/[a-zA-Z0-9.+-]+)').firstMatch(head);
  if (ct != null) {
    final sub = ct.group(1)!.split('/').last.toLowerCase();
    return 'audio.$sub';
  }
  return fallback;
}

Future<void> handleDbAsr(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'POST') {
    await dsJSONErr(res, 405, 'Method not allowed');
    return;
  }
  final ct = (req.headers.contentType?.mimeType ?? '').toLowerCase();
  List<int> raw;
  try {
    raw = await readBodyBytes(req, limit: 60 * 1024 * 1024);
  } catch (_) {
    await dsJSONErr(res, 400, '音声の読み込みに失敗しました');
    return;
  }
  try {
    List<int> audio;
    var name = 'audio.webm';
    if (ct.contains('application/json')) {
      final j = asMap(jsonDecode(utf8.decode(raw, allowMalformed: true)));
      final b64 = mStr(j, 'audioBase64');
      if (b64.isEmpty) {
        await dsJSONErr(res, 400, 'audioBase64 が空です');
        return;
      }
      audio = base64.decode(b64);
      name = trimOr(mStr(j, 'fileName'), 'audio.webm');
    } else {
      audio = extractAudioPayload(raw);
      name = _fileNameFromMultipart(raw, 'audio.webm');
    }
    final text = await dbTranscribeBytes(audio, name);
    await dsJSONOk(res, 200, {'success': true, 'text': text});
  } catch (e) {
    logp('❌ 豆包 ASR エラー: $e');
    await dsJSONErr(res, 500, dbErrText(e));
  }
}

Future<void> handleDbVoiceTurn(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'POST') {
    await dsJSONErr(res, 405, 'Method not allowed');
    return;
  }
  final ct = (req.headers.contentType?.mimeType ?? '').toLowerCase();
  List<int> raw;
  try {
    raw = await readBodyBytes(req, limit: 60 * 1024 * 1024);
  } catch (_) {
    await dsJSONErr(res, 400, '音声の読み込みに失敗しました');
    return;
  }
  try {
    var audio = <int>[];
    var name = 'audio.webm';
    var history = <Map<String, dynamic>>[];
    var lang = req.headers.value('x-dsc-lang') ?? 'zh';
    var voice = req.headers.value('x-db-voice') ?? '';
    var model = req.headers.value('x-db-model') ?? '';
    var textInput = '';
    if (ct.contains('application/json')) {
      final j = asMap(jsonDecode(utf8.decode(raw, allowMalformed: true)));
      final b64 = mStr(j, 'audioBase64');
      textInput = mStr(j, 'text');
      if (b64.isEmpty && textInput.trim().isEmpty) {
        await dsJSONErr(res, 400, 'audioBase64 が空です');
        return;
      }
      if (b64.isNotEmpty) audio = base64.decode(b64);
      name = trimOr(mStr(j, 'fileName'), 'audio.webm');
      history = asList(j['history']).map((e) => asMap(e)).toList();
      lang = trimOr(mStr(j, 'lang'), lang);
      voice = trimOr(mStr(j, 'voice'), voice);
      model = trimOr(mStr(j, 'model'), model);
    } else {
      audio = extractAudioPayload(raw);
      name = _fileNameFromMultipart(raw, 'audio.webm');
    }
    final out = await dbVoiceTurn(
      audio: audio,
      fileName: name,
      history: history,
      lang: lang,
      voice: voice,
      model: model,
      text: textInput,
    );
    await dsJSONOk(res, 200, out);
  } catch (e) {
    logp('❌ 豆包音声通話エラー: $e');
    await dsJSONErr(res, 500, dbErrText(e));
  }
}

Future<void> handleDbChat(HttpRequest req) async {
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
  try {
    final system = mStr(body, 'system');
    final msgs = asList(body['messages'])
        .map((e) => asMap(e))
        .map((m) => <String, dynamic>{
              'role': mStr(m, 'role', 'user'),
              'content': mStr(m, 'content'),
            })
        .toList();
    if (msgs.isEmpty) {
      final p = mStr(body, 'prompt');
      if (p.trim().isNotEmpty) msgs.add({'role': 'user', 'content': p});
    }
    if (msgs.isEmpty) {
      await dsJSONErr(res, 400, 'メッセージが空です');
      return;
    }
    final text = await dbChatText(system, msgs,
        model: mStr(body, 'model'),
        maxTokens: intArgDefault(body, 'maxTokens', 4096),
        temperature: double.tryParse(mStr(body, 'temperature')) ?? 0.8);
    await dsJSONOk(res, 200, {'success': true, 'text': text});
  } catch (e) {
    logp('❌ 豆包チャットエラー: $e');
    await dsJSONErr(res, 500, dbErrText(e));
  }
}

Future<void> handleDbAudioAnalyze(HttpRequest req) async {
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
  final fileID = mStr(body, 'fileId');
  try {
    final text = await dbTranscribeFile(fileID);
    final prompt = mStr(body, 'prompt');
    String analysis = '';
    if (prompt.trim().isNotEmpty) {
      analysis = await dbChatText(
          'あなたは音声ファイルの内容を分析する専門家です。日本語で簡潔に分析してください。',
          [
            {'role': 'user', 'content': '音声の書き起こし:\n$text\n\n依頼: $prompt'}
          ],
          model: mStr(body, 'model'));
    }
    await dsJSONOk(res, 200, {'success': true, 'text': text, 'analysis': analysis});
  } catch (e) {
    await dsJSONErr(res, 500, dbErrText(e));
  }
}
