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

import 'doubao_wiki.dart';
import 'ds_crypto.dart';
import 'files.dart';
import 'globals.dart';
import 'httpsrv.dart';
import 'net.dart';
import 'tts_edge.dart';

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
  DbModelSpec('doubao-seededit-3-0-i2i-250628',
      '豆包 SeedEdit 3.0（画像編集・P图モデル）', 'imageedit'),
  DbModelSpec('doubao-seedance-2-0-mini-260615', 'Doubao-Seedance-2.0-mini（動画生成）',
      'video'),
  DbModelSpec('doubao-seedance-2-0-fast-260128',
      'Doubao-Seedance-2.0-fast（高速動画生成）', 'video'),
  DbModelSpec('doubao-seedance-2-0-260128', 'Doubao-Seedance-2.0（動画生成）', 'video'),
  DbModelSpec('glm-5-2-260617', 'GLM-5.2（コーディングモデル）', 'chat'),
  DbModelSpec('doubao-seed-2-0-mini-260428', 'Doubao-Seed-2.0-mini', 'chat'),
  DbModelSpec('doubao-seed-evolving-latest-version', 'Doubao-Seed-Evolving', 'chat'),
  DbModelSpec('doubao-seed-2-1-pro-260628', 'Doubao-Seed-2.1-pro', 'chat'),
  DbModelSpec('doubao-seed-2-1-turbo-260628', 'Doubao-Seed-2.1-turbo', 'chat'),
  DbModelSpec('doubao-seed-2-0-lite-260428', 'Doubao-Seed-2.0-lite', 'chat'),
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
const String DB_DEFAULT_IMAGEEDIT_MODEL = 'doubao-seedream-5-0-pro-260628';
const String DB_DEFAULT_VIDEO_MODEL = 'doubao-seedance-2-0-260128';
const String DB_DEFAULT_TTS_MODEL = 'SeedAudio1.0';
const String DB_DEFAULT_PODCAST_MODEL = 'Doubao_scene_SLM_Doubao_Podcast_model';
const String DB_DEFAULT_ASR_MODEL = 'Doubao_Seed_ASR_AUC_2.0';
const String DB_DEFAULT_REALTIME_MODEL = 'Doubao_scene_SLM_Doubao_realtime_voice_model';
const String DB_DEFAULT_VOICE = 'zh_female_xiaohe_uranus_bigtts';
const String DB_DEFAULT_VOICE_B = 'zh_male_qingshuangnanda_mars_bigtts';

// ------------------------------------------------------------
// 多言語メッセージ（6 言語）
//   UI 言語に合わせて直接その言語で返すため、前端の二次翻訳に依存しない。
//   key ごとに ja / zh / en / ko / ru / fr を必ず揃える。
// ------------------------------------------------------------
const Map<String, Map<String, String>> _dbMsgTable = <String, Map<String, String>>{
  'audioUnsupported': <String, String>{
    'ja': '選択中の豆包モデル（{0}）は音声理解に対応していません。'
        '音声理解対応モデル（{1}）に切り替えてください。'
        '音声を DeepSeek へ送信することはありません。',
    'zh': '当前所选豆包模型（{0}）不支持音频理解。'
        '请切换到支持音频理解的模型（{1}）。音频不会发送给 DeepSeek。',
    'en': 'The selected Doubao model ({0}) does not support audio understanding. '
        'Switch to an audio-capable model ({1}). '
        'Your audio is never sent to DeepSeek.',
    'ko': '선택한 더우바오 모델({0})은 오디오 이해를 지원하지 않습니다. '
        '오디오 이해 지원 모델({1})로 전환해 주세요. '
        '오디오는 DeepSeek으로 전송되지 않습니다.',
    'ru': 'Выбранная модель Doubao ({0}) не поддерживает понимание аудио. '
        'Переключитесь на модель с поддержкой аудио ({1}). '
        'Аудио не отправляется в DeepSeek.',
    'fr': 'Le modèle Doubao sélectionné ({0}) ne prend pas en charge la compréhension audio. '
        'Passez à un modèle compatible ({1}). '
        'Votre audio n’est jamais envoyé à DeepSeek.',
  },
  'videoUnsupported': <String, String>{
    'ja': '選択中の豆包モデル（{0}）は動画理解に対応していません。'
        '動画理解対応モデル（{1}）に切り替えてください。'
        '動画を DeepSeek へ送信することはありません。',
    'zh': '当前所选豆包模型（{0}）不支持视频理解。'
        '请切换到支持视频理解的模型（{1}）。视频不会发送给 DeepSeek。',
    'en': 'The selected Doubao model ({0}) does not support video understanding. '
        'Switch to a video-capable model ({1}). '
        'Your video is never sent to DeepSeek.',
    'ko': '선택한 더우바오 모델({0})은 동영상 이해를 지원하지 않습니다. '
        '동영상 이해 지원 모델({1})로 전환해 주세요. '
        '동영상은 DeepSeek으로 전송되지 않습니다.',
    'ru': 'Выбранная модель Doubao ({0}) не поддерживает понимание видео. '
        'Переключитесь на модель с поддержкой видео ({1}). '
        'Видео не отправляется в DeepSeek.',
    'fr': 'Le modèle Doubao sélectionné ({0}) ne prend pas en charge la compréhension vidéo. '
        'Passez à un modèle compatible ({1}). '
        'Votre vidéo n’est jamais envoyée à DeepSeek.',
  },
  'audioTooLarge': <String, String>{
    'ja': '音声ファイルが大きすぎます（上限 40MB）：{0}',
    'zh': '音频文件过大（上限 40MB）：{0}',
    'en': 'Audio file is too large (limit 40MB): {0}',
    'ko': '오디오 파일이 너무 큽니다(최대 40MB): {0}',
    'ru': 'Аудиофайл слишком большой (лимит 40MB): {0}',
    'fr': 'Fichier audio trop volumineux (limite 40 Mo) : {0}',
  },
  'videoTooLarge': <String, String>{
    // 视频上限从 40MB 提升到 2GB：45MB 以内直传 video_url，
    // 超过则用 ffmpeg 无损切片后逐段理解再汇总（见 doubao_video_ark.dart）。
    'ja': '動画ファイルが大きすぎます（上限 2GB）：{0}',
    'zh': '视频文件过大（上限 2GB）：{0}',
    'en': 'Video file is too large (limit 2GB): {0}',
    'ko': '동영상 파일이 너무 큽니다(최대 2GB): {0}',
    'ru': 'Видеофайл слишком большой (лимит 2GB): {0}',
    'fr': 'Fichier vidéo trop volumineux (limite 2 Go) : {0}',
  },
  'keyMissingForModel': <String, String>{
    'ja': '豆包モデルを選択中ですが、豆包 API Key が未設定です',
    'zh': '已选择豆包模型，但豆包 API Key 未填写',
    'en': 'A Doubao model is selected, but the Doubao API Key is not set.',
    'ko': '더우바오 모델을 선택했지만 더우바오 API Key가 설정되지 않았습니다.',
    'ru': 'Выбрана модель Doubao, но API-ключ Doubao не задан.',
    'fr': 'Un modèle Doubao est sélectionné, mais la clé API Doubao n’est pas définie.',
  },
  'searchBlockedNote': <String, String>{
    'ja': '【联网検索について】本サイトは豆包モードでのウェブ検索に対応していません。'
        '豆包の検索機能を別途追加する必要もありません。'
        'ウェブ検索が必要な場合は、豆包モードをオフにして、DeepSeek モードで検索してください。',
    'zh': '【关于联网搜索】本网站不支持豆包模式下的联网搜索，也没有必要额外支持豆包搜索。'
        '如需联网搜索，请关闭豆包模式，改用 DeepSeek 模式进行搜索。',
    'en': '[About web search] This site does not support web search in Doubao mode, '
        'and there is no need to add Doubao search separately. '
        'If you need web search, turn off Doubao mode and search in DeepSeek mode instead.',
    'ko': '[웹 검색 안내] 본 사이트는 더우바오 모드에서의 웹 검색을 지원하지 않으며, '
        '더우바오 검색을 별도로 추가할 필요도 없습니다. '
        '웹 검색이 필요하면 더우바오 모드를 끄고 DeepSeek 모드에서 검색해 주세요.',
    'ru': '[О веб-поиске] Этот сайт не поддерживает веб-поиск в режиме Doubao, '
        'и отдельно добавлять поиск Doubao не требуется. '
        'Если нужен веб-поиск, отключите режим Doubao и выполняйте поиск в режиме DeepSeek.',
    'fr': '[À propos de la recherche web] Ce site ne prend pas en charge la recherche web '
        'en mode Doubao, et il n’est pas nécessaire d’ajouter une recherche Doubao. '
        'Si vous avez besoin d’une recherche web, désactivez le mode Doubao '
        'et utilisez la recherche en mode DeepSeek.',
  },
  'noMediaNote': <String, String>{
    'ja': '【重要】この経路（DeepSeek）は音声・動画の内容理解に対応していません。'
        '対象ファイル（{0}）の中身は読まれていません。'
        '音声・動画を理解させたい場合は、豆包モードに切り替えて'
        '音声理解・動画理解対応モデルを選んでください。',
    'zh': '【重要】当前通道（DeepSeek）不支持音频、视频内容理解。'
        '目标文件（{0}）的内容并未被读取。'
        '如需理解音频、视频，请切换到豆包模式，并选择支持音频理解、视频理解的模型。',
    'en': '[Important] This route (DeepSeek) does not support understanding audio or video. '
        'The contents of these files ({0}) were not read. '
        'To let a model understand audio or video, switch to Doubao mode and pick '
        'an audio/video capable model.',
    'ko': '[중요] 현재 경로(DeepSeek)는 오디오·동영상 내용 이해를 지원하지 않습니다. '
        '대상 파일({0})의 내용은 읽히지 않았습니다. '
        '오디오·동영상을 이해시키려면 더우바오 모드로 전환하고 '
        '오디오·동영상 이해 지원 모델을 선택해 주세요.',
    'ru': '[Важно] Этот канал (DeepSeek) не поддерживает понимание аудио и видео. '
        'Содержимое файлов ({0}) не было прочитано. '
        'Чтобы модель поняла аудио или видео, переключитесь в режим Doubao и выберите '
        'модель с поддержкой аудио/видео.',
    'fr': '[Important] Cette voie (DeepSeek) ne prend pas en charge la compréhension '
        'de l’audio ni de la vidéo. Le contenu de ces fichiers ({0}) n’a pas été lu. '
        'Pour faire comprendre un audio ou une vidéo, passez en mode Doubao et choisissez '
        'un modèle compatible audio/vidéo.',
  },
  'transcribeNote': <String, String>{
    'ja': '選択モデルは音声理解に非対応のため、文字起こし後に分析しました',
    'zh': '所选模型不支持音频理解，因此先转写文字再进行分析',
    'en': 'The selected model lacks audio understanding, so the audio was transcribed first '
        'and then analyzed.',
    'ko': '선택한 모델이 오디오 이해를 지원하지 않아 먼저 텍스트로 변환한 뒤 분석했습니다.',
    'ru': 'Выбранная модель не поддерживает понимание аудио, поэтому сначала выполнена '
        'расшифровка, затем анализ.',
    'fr': 'Le modèle sélectionné ne comprend pas l’audio : une transcription a été faite '
        'avant l’analyse.',
  },
};

/// 取得指定语言的文案；args 依次替换 {0} {1} …
String dbLocalized(String lang, String key, [List<String> args = const <String>[]]) {
  final raw = lang.trim().toLowerCase();
  // 'zh-CN' / 'en-US' 这类带地区的写法也要能命中（取前两位）
  final code = raw.length >= 2 ? raw.substring(0, 2) : raw;
  final row = _dbMsgTable[key];
  if (row == null) return key;
  var text = row[code] ?? row['ja'] ?? key;
  for (var i = 0; i < args.length; i++) {
    text = text.replaceAll('{$i}', args[i]);
  }
  return text;
}

// ------------------------------------------------------------
// 模型能力表（音频理解 / 视频理解）
//   只有下表列出的模型才能直接接收原始音频 / 视频。
//   表外模型（含 2.1 系列）不具备音频理解，传入音频会 400，
//   因此必须在请求前拦截并如实告知，绝不静默丢弃。
// ------------------------------------------------------------

/// 支持「音频理解」的模型：可直接把音频字节作为 input_audio 送入对话。
const Set<String> dbAudioUnderstandModels = <String>{
  'doubao-seed-2-0-mini-260428',
  'doubao-seed-2-0-lite-260428',
  'doubao-seed-2-1-lite-260915',
};

/// 支持「视频理解」的模型：可直接把视频字节作为 video_url 送入对话。
/// 注意：2.1 系列（turbo / pro / evolving）只支持视频理解，不支持音频理解。
const Set<String> dbVideoUnderstandModels = <String>{
  'doubao-seed-2-0-mini-260428',
  'doubao-seed-2-0-lite-260428',
  'doubao-seed-2-1-lite-260915',
  'doubao-seed-2-1-turbo-260628',
  'doubao-seed-2-1-pro-260628',
  'doubao-seed-evolving-latest-version',
};

/// 该模型能否直接理解原始音频
bool dbSupportsAudioInput(String model) =>
    dbAudioUnderstandModels.contains(model.trim().toLowerCase());

/// 该模型能否直接理解原始视频
///
/// 判定分两层：
///   1) 白名单（上面 dbVideoUnderstandModels，含前端展示用的清单）；
///   2) doubao-seed-2.x 系列前缀兜底 —— 实测 doubao-seed-2-1-lite-260915
///      等未列入白名单的版本同样能理解视频，硬白名单会误拦真实可用的模型。
bool dbSupportsVideoInput(String model) {
  final m = model.trim().toLowerCase();
  if (m.isEmpty) return false;
  if (dbVideoUnderstandModels.contains(m)) return true;
  if (m.startsWith('doubao-seed-evolving')) return true;
  return RegExp(r'^doubao-seed-2-[0-9a-z]').hasMatch(m);
}

/// 具备音频理解能力的模型清单（用于前端提示与错误话术）
List<String> get dbAudioCapableModels =>
    dbAudioUnderstandModels.toList(growable: false);

/// 具备视频理解能力的模型清单（用于前端提示与错误话术）
List<String> get dbVideoCapableModels =>
    dbVideoUnderstandModels.toList(growable: false);

/// 构造「开启深度思考」参数：让豆包在理解图片 / 音频 / 视频后
/// 先思考再回答。仅 doubao-seed 系列接受该字段。
Map<String, dynamic>? dbThinkingEnableParam(String model) {
  final m = model.trim().toLowerCase();
  if (m.isEmpty) return null;
  if (!m.startsWith('doubao-seed')) return null;
  return <String, dynamic>{
    'thinking': <String, dynamic>{'type': 'enabled'},
  };
}

/// 明确关闭深度思考（仅 doubao-seed 系列接受该字段）。
/// 与 dbThinkingParam 的区别：不受 fastMode 开关约束，由调用方按需决定。
Map<String, dynamic>? dbThinkingDisableParam(String model) {
  final m = model.trim().toLowerCase();
  if (m.isEmpty) return null;
  if (!m.startsWith('doubao-seed')) return null;
  return <String, dynamic>{
    'thinking': <String, dynamic>{'type': 'disabled'},
  };
}

/// 豆包自带联网搜索（Chat Completions 的 web_search_options）。
///
/// 与「联网内容插件」（Responses API，sources=douyin 等）是两条不同通道：
///   · 插件：仅 Responses API 支持，可指定抖音百科等信源，按次计费；
///   · 豆包搜索 Custom 版：Chat Completions 即可用，信源固定为豆包搜索，
///     每月 2 万次免费额度。
/// 用户关掉抖音百科、只开「联网搜索」时走这一条，不再调用 DeepSeek 官方
/// /v1/tools/search（那是另一套计费通道，与豆包模式无关）。
/// 方舟文档（docs.volcengine.com/docs/ark/web-search）明确：
///   「web_search_options：联网搜索开关。传入 {} 或包含任意子字段的 object
///     都会触发搜索准入判定」→ 这里直接给空对象，最不容易被网关拒绝。
/// 另外：tools 与 web_search_options 同时传入时，方舟只执行自定义工具、
/// 联网搜索不生效 —— 所以工具模式下必须二选一（见 chat_send.dart）。
Map<String, dynamic> dbWebSearchOptions() => <String, dynamic>{};

/// 图片内容片段（data URL 直传，模型自己看原图，不做二次转述）
Map<String, dynamic> dbImagePart(String mime, String base64) => <String, dynamic>{
      'type': 'image_url',
      'image_url': <String, dynamic>{
        'url': 'data:${mime.isEmpty ? 'image/png' : mime};base64,$base64',
      },
    };

/// 音频内容片段（方舟原生音频理解输入）
Map<String, dynamic> dbAudioPart(String format, String base64) => <String, dynamic>{
      'type': 'input_audio',
      'input_audio': <String, dynamic>{
        'data': base64,
        'format': format.isEmpty ? 'mp3' : format,
      },
    };

/// 视频内容片段（方舟原生视频理解输入）
Map<String, dynamic> dbVideoPart(String mime, String base64) => <String, dynamic>{
      'type': 'video_url',
      'video_url': <String, dynamic>{
        'url': 'data:${mime.isEmpty ? 'video/mp4' : mime};base64,$base64',
      },
    };

/// 音频字节直接送方舟理解时的格式名（与 _audioFormatOf 保持一致的取值域）
String dbAudioFormatOf(String fileName) => _audioFormatOf(fileName);

/// 把任意来源音频规范成方舟可接受的 mp3；无法转换时原样返回并给出真实格式名。
/// 聊天链路（chat_send）需要它，因此以公开函数暴露。
Future<({List<int> bytes, String format})> dbPrepareAudioForArk(
    List<int> audio, String fileName) async {
  final converted = await _ensureMp3Bytes(audio, fileName);
  if (!identical(converted, audio) && converted.isNotEmpty) {
    return (bytes: converted, format: 'mp3');
  }
  return (bytes: audio, format: _audioFormatOf(fileName));
}

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

  /// 联网内容插件信源（抖音百科 / 头条图文 / 墨迹天气 / 全网检索）。
  /// 仅豆包模式生效，且仅走 Responses API（插件不支持 Chat Completions）。
  /// 留空 = 不启用联网内容插件，保持原有 Chat API 行为。
  List<String> webSources;

  /// 抖音百科搜索「总开关」（工具栏豆包按钮控制）。
  /// 关闭时即使 [webSources] 里还留着 douyin，也一律视为未启用 ——
  /// 总闸拔了，空调（信源开关）就打不开。
  bool wikiEnabled;

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
    List<String>? webSources,
    this.wikiEnabled = false,
  })  : customModels = customModels ?? <String>[],
        webSources = webSources ?? <String>[];

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
        'webSources': webSources,
        'wikiEnabled': wikiEnabled,
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
        webSources: dbWikiNormalizeSources(
            asList(j['webSources']).map((e) => '$e')),
        wikiEnabled: mBool(j, 'wikiEnabled'),
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

/// 抖音百科「总开关 × 信源开关」串联后的有效信源。
/// 总闸关闭时返回空列表：设置里的抖音百科信源开关即便还勾着也一律失效。
List<String> dbWikiEffectiveSources() {
  final cfg = getDbConfig();
  if (!cfg.wikiEnabled) return const <String>[];
  return dbWikiNormalizeSources(cfg.webSources);
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
    throw Exception('豆包 API Key 未设置，请先在设置中填写。');
  }
}

// ------------------------------------------------------------
// 聊天（非流式，内部使用：剧本生成 / 语音通话回复）
// ------------------------------------------------------------
Future<String> dbChatText(
  String systemPrompt,
  List<Map<String, dynamic>> messages, {
  String? model,
  int maxTokens = 8192,
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
  if (choices.isEmpty) throw Exception('豆包 API 返回了空响应');
  final msg = asMap(asMap(choices[0])['message']);
  final c = mStr(msg, 'content');
  if (c.trim().isEmpty) {
    final rc = mStr(msg, 'reasoning_content');
    if (rc.trim().isNotEmpty) return rc;
  }
  return c;
}

/// 单轮直连方舟：支持多模态 content（图片 / 音频 / 视频）与深度思考开关。
/// 该函数只访问豆包（火山方舟），任何时候都不会触及 DeepSeek 接口。
Future<String> _dbChatRawOnce(
  DbConfig cfg,
  String model,
  List<Map<String, dynamic>> messages, {
  int maxTokens = 8192,
  double temperature = 0.8,
  bool thinking = false,
  String systemPrompt = '',
  Duration timeout = const Duration(seconds: 180),
}) async {
  _requireKey(cfg);
  final msgs = <Map<String, dynamic>>[];
  if (systemPrompt.trim().isNotEmpty) {
    msgs.add({'role': 'system', 'content': systemPrompt});
  }
  msgs.addAll(messages);
  final body = <String, dynamic>{
    'model': model,
    'messages': msgs,
    'stream': false,
    'max_tokens': maxTokens,
    'temperature': temperature,
    if (thinking) 'thinking': <String, dynamic>{'type': 'enabled'},
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
  if (choices.isEmpty) throw Exception('豆包 API 返回了空响应');
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

/// 该图片模型是否支持 sequential_image_generation（组图参数）。
/// Seedream 4.0 系列支持；4.5 / 5.x 携带该参数会直接返回 HTTP 400。
bool dbSupportsSequentialImage(String model) {
  final m = model.toLowerCase();
  return m.contains('seedream-4-0') || m.contains('seedream-4.0');
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
  if (p.isEmpty) throw Exception('图片描述（提示词）为空');
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

  // 各模型对请求体的接受度不同：
  //   · Seedream 5.x（含 5.0-pro / 5.0-lite）与 4.5 不认识 sequential_image_generation，
  //     一旦携带就直接返回 HTTP 400（the parameter ... is not supported by the current model）；
  //   · 只有 Seedream 4.0 系列支持组图参数，且单图场景本来就不需要它。
  // 因此默认绝不携带该参数，仅对白名单模型附加，其余按「较全 → 最简」逐级降级重试。
  final preset = resolution.toUpperCase() == '4K' ? '4K' : '2K';
  // 首选组合＝实测已被方舟接受的最小参数集（像素 size + url + watermark），
  // 确保第一次请求就不会因多余字段被拒。
  List<Map<String, dynamic>> buildCandidates(String m) {
    final b = <String, dynamic>{'model': m, 'prompt': fullPrompt};
    final cs = <Map<String, dynamic>>[
      {...b, 'size': size, 'response_format': 'url', 'watermark': cfg.watermark},
      {...b, 'size': size, 'response_format': 'b64_json', 'watermark': cfg.watermark},
      {...b, 'size': preset, 'response_format': 'url', 'watermark': cfg.watermark},
      {...b, 'size': preset, 'watermark': cfg.watermark},
      {...b, 'size': preset},
      {...b},
    ];
    if (dbSupportsSequentialImage(m)) {
      cs.insert(0, {
        ...b,
        'size': size,
        'response_format': 'b64_json',
        'watermark': cfg.watermark,
        'sequential_image_generation': 'disabled',
      });
    }
    return cs;
  }

  // 模型可用性回退：账号未开通或模型已下线时方舟返回 HTTP 404
  // （the model or endpoint ... does not exist or you do not have access to it），
  // 此时按目录顺序换用其他图像模型，避免整次生图直接失败。
  final modelSeq = <String>[useModel];
  for (final spec in dbModelCatalog) {
    if (spec.cat == 'image' && !modelSeq.contains(spec.value)) {
      modelSeq.add(spec.value);
    }
  }
  var r = (code: 0, bytes: <int>[]);
  var lastErr = '';
  var usedModel = useModel;
  for (var mi = 0; mi < modelSeq.length; mi++) {
    final m = modelSeq[mi];
    if (mi > 0) logp('↩️ 豆包画像生成：$useModel 利用不可 → $m にフォールバック');
    final cs = buildCandidates(m);
    for (var i = 0; i < cs.length; i++) {
      try {
        final rr = await _httpRaw('POST', '${dbBaseUrl(cfg)}/images/generations',
            headers: _jsonHeaders(cfg.apiKey),
            body: utf8.encode(jsonEncode(cs[i])),
            timeout: const Duration(seconds: 240));
        r = rr;
        if (rr.code == 200) {
          usedModel = m;
          break;
        }
        lastErr = _errFromBytes(rr.bytes);
        logp('⚠️ 豆包画像生成 試行 ${i + 1}/${cs.length} [$m] 失敗（HTTP ${rr.code}）: $lastErr');
        // 404＝模型不可用，换参数无用；鉴权/额度/限流类同理
        if (rr.code != 400 && rr.code != 422) break;
      } catch (e) {
        lastErr = '$e';
        logp('⚠️ 豆包画像生成 試行 ${i + 1} [$m] 例外: $e');
      }
    }
    if (r.code == 200) break;
    // 仅「模型不存在/无权限」才换下一个模型，其余错误换模型同样无意义
    if (r.code != 404) break;
  }
  if (r.code != 200) {
    throw Exception('豆包图片生成失败（HTTP ${r.code}）：$lastErr');
  }
  final j = asMap(jsonDecode(utf8.decode(r.bytes, allowMalformed: true)));
  final data = asList(j['data']);
  if (data.isEmpty) throw Exception('豆包图片生成：未返回图片数据');
  final first = asMap(data[0]);
  final b64 = mStr(first, 'b64_json');
  final url = mStr(first, 'url');
  List<int>? bytes;
  if (b64.isNotEmpty) {
    try {
      bytes = base64.decode(b64);
    } catch (e) {
      throw Exception('图片 base64 解码失败：$e');
    }
  } else if (url.isNotEmpty) {
    final dl = await _httpRaw('GET', url,
        timeout: const Duration(seconds: 180));
    if (dl.code != 200 || dl.bytes.isEmpty) {
      throw Exception('生成图片下载失败（HTTP ${dl.code}）');
    }
    bytes = dl.bytes;
  }
  if (bytes == null || bytes.isEmpty) {
    throw Exception('豆包图片生成：没有取到图片本体');
  }
  final outName = name.trim().isEmpty
      ? 'doubao_image_${fmtStamp14(DateTime.now())}'
      : name.trim();
  final meta = saveDbBlob(bytes, outName, _mimeByExtName(outName, 'image/png'),
      'image',
      source: 'doubao-image', prompt: p);
  if (meta == null) throw Exception('生成图片保存失败');
  return {
    'success': true,
    'file': _fileJson(meta),
    'model': usedModel,
    'fallbackFrom': usedModel == useModel ? '' : useModel,
    'size': '$size',
    'ratio': rt,
    'style': st,
    'revisedPrompt': mStr(first, 'revised_prompt'),
  };
}

// ------------------------------------------------------------
// 图片编辑（豆包P图）：本地图片 + 指令 → 豆包修改 → 存回 ds_files/blob
//   走方舟 /images/generations 的 image 字段（参考图），默认用 Seedream 5.0 pro，
//   未开通时按目录顺序回退到其它图像模型；参数按「较全 → 最简」逐级降级。
// ------------------------------------------------------------
Future<Map<String, dynamic>> dbEditImage({
  required List<int> image,
  required String fileName,
  required String prompt,
  String model = '',
  String resolution = '2K',
}) async {
  final cfg = getDbConfig();
  _requireKey(cfg);
  if (image.length < 256) throw Exception('图片数据为空或过小，请重新选择图片');
  final p = prompt.trim();
  if (p.isEmpty) throw Exception('请填写P图要求（例如：把背景换成海边）');
  final useModel = trimOr(model, DB_DEFAULT_IMAGEEDIT_MODEL);
  final mime = _mimeByExtName(fileName, 'image/png');
  final dataUrl = 'data:$mime;base64,${base64.encode(image)}';
  final preset = resolution.toUpperCase() == '4K' ? '4K' : '2K';

  final modelSeq = <String>[useModel];
  for (final spec in dbModelCatalog) {
    if (spec.cat == 'imageedit' || spec.cat == 'image') {
      if (!modelSeq.contains(spec.value)) modelSeq.add(spec.value);
    }
  }

  var code = 0;
  var lastErr = '';
  var usedModel = useModel;
  var outBytes = <int>[];
  for (var mi = 0; mi < modelSeq.length; mi++) {
    final m = modelSeq[mi];
    if (mi > 0) logp('↩️ 豆包P图：$useModel 不可用 → 回退 $m');
    final base = <String, dynamic>{'model': m, 'prompt': p, 'image': dataUrl};
    // 首选组合＝实测已被方舟 5.0-pro 接受的最小参数集（preset + url 默认行为），
    // 确保第一次请求就不会因多余字段被拒；其余按「较全 → 最简」逐级降级。
    final candidates = <Map<String, dynamic>>[
      {...base, 'size': preset},
      {...base, 'size': preset, 'response_format': 'url'},
      {...base, 'size': preset, 'response_format': 'url', 'watermark': cfg.watermark},
      {...base, 'size': preset, 'watermark': cfg.watermark},
      {...base},
    ];
    for (var i = 0; i < candidates.length; i++) {
      try {
        final r = await _httpRaw('POST', '${dbBaseUrl(cfg)}/images/generations',
            headers: _jsonHeaders(cfg.apiKey),
            body: utf8.encode(jsonEncode(candidates[i])),
            timeout: const Duration(seconds: 300));
        code = r.code;
        if (r.code == 200) {
          final j = asMap(jsonDecode(utf8.decode(r.bytes, allowMalformed: true)));
          final data = asList(j['data']);
          if (data.isEmpty) {
            lastErr = '豆包P图未返回图片数据';
            continue;
          }
          final first = asMap(data[0]);
          final b64 = mStr(first, 'b64_json');
          final url = mStr(first, 'url');
          var ob = <int>[];
          if (b64.isNotEmpty) {
            try {
              ob = base64.decode(b64);
            } catch (_) {
              ob = <int>[];
            }
          } else if (url.isNotEmpty) {
            final dl = await _httpRaw('GET', url,
                timeout: const Duration(seconds: 180));
            if (dl.code == 200) ob = dl.bytes;
          }
          if (ob.isEmpty) {
            lastErr = '豆包P图没有取到图片本体';
            continue;
          }
          outBytes = ob;
          usedModel = m;
          break;
        }
        lastErr = _errFromBytes(r.bytes);
        logp('⚠️ 豆包P图 第 ${i + 1}/${candidates.length} 次尝试 [$m] 失败（HTTP ${r.code}）：$lastErr');
        if (r.code != 400 && r.code != 422) break;
      } catch (e) {
        lastErr = '$e';
        logp('⚠️ 豆包P图 第 ${i + 1} 次尝试异常：$e');
      }
    }
    if (outBytes.isNotEmpty) break;
    if (code != 404) break;
  }
  if (outBytes.isEmpty) throw Exception('豆包P图失败（HTTP $code）：$lastErr');

  final outName = 'doubao_edit_${fmtStamp14(DateTime.now())}.png';
  final meta = saveDbBlob(outBytes, outName, 'image/png', 'image',
      source: 'doubao-image-edit', prompt: p);
  if (meta == null) throw Exception('P图结果保存失败');
  return {
    'success': true,
    'file': _fileJson(meta),
    'model': usedModel,
    'fallbackFrom': usedModel == useModel ? '' : useModel,
    'prompt': p,
    'size': preset,
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
  if (p.isEmpty) throw Exception('视频描述（提示词）为空');
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
    throw Exception('豆包视频任务创建失败（HTTP ${r.code}）：${_errFromBytes(r.bytes)}');
  }
  final j = asMap(jsonDecode(utf8.decode(r.bytes, allowMalformed: true)));
  final taskID = mStr(j, 'id');
  if (taskID.isEmpty) {
    throw Exception('豆包视频任务：未返回任务 ID：${truncateBytes(jsonEncode(j), 300)}');
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
  if (taskID.trim().isEmpty) throw Exception('任务 ID 为空');
  final r = await _httpRaw(
      'GET', '${dbBaseUrl(cfg)}/contents/generations/tasks/${Uri.encodeComponent(taskID)}',
      headers: _jsonHeaders(cfg.apiKey),
      timeout: const Duration(seconds: 90));
  if (r.code != 200) {
    throw Exception('豆包视频任务查询失败（HTTP ${r.code}）：${_errFromBytes(r.bytes)}');
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
// ------------------------------------------------------------
// 语音合成：Edge TTS 主通道 + 豆包回退
//   豆包 /audio/speech 在部分区域返回 404（端点不可用），
//   因此以 Edge TTS（Neural，免密钥）为主通道，豆包仅作回退。
// ------------------------------------------------------------
String _edgeLangOf(String text) {
  if (RegExp(r'[\u3040-\u30ff]').hasMatch(text)) return 'ja';
  if (RegExp(r'[\uac00-\ud7af]').hasMatch(text)) return 'ko';
  if (RegExp(r'[\u0400-\u04ff]').hasMatch(text)) return 'ru';
  if (RegExp(r'[\u4e00-\u9fff]').hasMatch(text)) return 'zh';
  return 'en';
}

String _edgeDefaultVoice(String lang) {
  switch (lang) {
    case 'ja':
      return 'ja-JP-NanamiNeural';
    case 'ko':
      return 'ko-KR-SunHiNeural';
    case 'ru':
      return 'ru-RU-SvetlanaNeural';
    case 'fr':
      return 'fr-FR-DeniseNeural';
    case 'de':
      return 'de-DE-KatjaNeural';
    case 'en':
      return 'en-US-AriaNeural';
    default:
      return 'zh-CN-XiaoxiaoNeural';
  }
}

bool isNeuralVoice(String v) =>
    RegExp(r'^[a-z]{2}-[A-Z]{2}-\w+Neural$').hasMatch(v.trim());

/// 豆包音色（zh_female_xiaohe_uranus_bigtts 等）→ Edge Neural 音色
String edgeVoiceFor(String voice, {String lang = 'zh'}) {
  final v = voice.trim();
  if (isNeuralVoice(v)) return v;
  if (v.isEmpty) return _edgeDefaultVoice(lang);
  final low = v.toLowerCase();
  final male = low.contains('male') || low.contains('_m_') || v.contains('男');
  final l = lang.toLowerCase().split(RegExp(r'[-_]')).first;
  if (male) {
    switch (l) {
      case 'ja':
        return 'ja-JP-KeitaNeural';
      case 'ko':
        return 'ko-KR-InJoonNeural';
      case 'ru':
        return 'ru-RU-DmitryNeural';
      case 'en':
        return 'en-US-GuyNeural';
      case 'fr':
        return 'fr-FR-HenriNeural';
      default:
        return 'zh-CN-YunxiNeural';
    }
  }
  return _edgeDefaultVoice(l);
}

/// 按句末标点 / 长度切块（Edge TTS 单次不宜过长）
List<String> _edgeSpeechChunks(String text, [int maxRunes = 1200]) {
  final out = <String>[];
  var buf = StringBuffer();
  var n = 0;
  void flush() {
    final t = buf.toString().trim();
    if (t.isNotEmpty) out.add(t);
    buf = StringBuffer();
    n = 0;
  }

  for (final r in text.runes) {
    final ch = String.fromCharCode(r);
    buf.write(ch);
    n++;
    final stop = '。！？!?；;\n'.contains(ch);
    if (n >= 160 && stop) {
      flush();
    } else if (n >= maxRunes) {
      flush();
    }
  }
  flush();
  return out;
}

/// Edge TTS 合成；成功返回 mp3 字节，失败返回空
Future<List<int>> edgeSpeechBytes(
  String text, {
  String voice = 'zh-CN-XiaoxiaoNeural',
  double speed = 1.0,
  String? lang,
}) async {
  final t = text.trim();
  if (t.isEmpty) return <int>[];
  final l = lang ?? _edgeLangOf(t);
  final useVoice = edgeVoiceFor(voice, lang: l);
  var pct = (((speed.clamp(0.5, 2.0)) - 1.0) * 100).round();
  if (pct < -50) pct = -50;
  if (pct > 100) pct = 100;
  final rate = pct >= 0 ? '+$pct%' : '$pct%';
  final chunks = _edgeSpeechChunks(t);
  final out = <int>[];
  for (var i = 0; i < chunks.length; i++) {
    final buf = <int>[];
    var ok = false;
    try {
      ok = await synthesizeEdgeTts(chunks[i], useVoice, (a) async {
        buf.addAll(a);
      }, rate: rate);
    } catch (e) {
      logp('⚠️ Edge TTS ${i + 1}/${chunks.length} 例外: $e');
    }
    if (!ok || buf.isEmpty) {
      logp('⚠️ Edge TTS ${i + 1}/${chunks.length} 塊の合成に失敗（voice=$useVoice）');
      return <int>[];
    }
    out.addAll(buf);
  }
  logp('🔊 Edge TTS 完了: $useVoice / ${out.length} bytes');
  return out;
}

/// 豆包原生 TTS（回退通道；不可用时返回空而不抛错）
Future<List<int>> _dbSpeechArk(
  String text, {
  String? voice,
  String? model,
  String format = 'mp3',
  double speed = 1.0,
}) async {
  final cfg = getDbConfig();
  if (cfg.apiKey.trim().isEmpty) return <int>[];
  final t = text.trim();
  if (t.isEmpty) return <int>[];
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
  try {
    final r = await _httpRaw('POST', '${dbBaseUrl(cfg)}/audio/speech',
        headers: _jsonHeaders(cfg.apiKey, extra: extra.isEmpty ? null : extra),
        body: utf8.encode(jsonEncode(body)),
        timeout: const Duration(seconds: 120));
    if (r.code != 200) {
      logp('⚠️ 豆包 TTS 回退失敗（HTTP ${r.code}）: ${_errFromBytes(r.bytes)}');
      return <int>[];
    }
    if (r.bytes.length > 4 && r.bytes[0] == 0x7B) {
      logp('⚠️ 豆包 TTS 回退返回错误体: ${_errFromBytes(r.bytes)}');
      return <int>[];
    }
    return r.bytes;
  } catch (e) {
    logp('⚠️ 豆包 TTS 回退例外: $e');
    return <int>[];
  }
}

Future<List<int>> dbSpeech(
  String text, {
  String? voice,
  String? model,
  String format = 'mp3',
  double speed = 1.0,
}) async {
  final cfg = getDbConfig();
  final t = text.trim();
  if (t.isEmpty) throw Exception('要朗读的文本为空');
  final lang = _edgeLangOf(t);
  final edgeVoice = edgeVoiceFor(trimOr(voice, cfg.voice), lang: lang);

  final edge =
      await edgeSpeechBytes(t, voice: edgeVoice, speed: speed, lang: lang);
  if (edge.isNotEmpty) return edge;

  final ark = await _dbSpeechArk(t,
      voice: voice, model: model, format: format, speed: speed);
  if (ark.isNotEmpty) return ark;

  throw Exception(
      '语音合成失败（Edge TTS 与豆包 TTS 均不可用，请检查网络）');
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

/// 音声ファイル名から方舟に申告する形式名を決める（未対応拡張子は mp3 扱い）。
String _audioFormatOf(String fileName) {
  final lower = fileName.toLowerCase();
  const ok = ['mp3', 'wav', 'aac', 'flac', 'opus', 'pcm', 'ogg'];
  final dot = lower.lastIndexOf('.');
  if (dot < 0 || dot == lower.length - 1) return 'mp3';
  final ext = lower.substring(dot + 1);
  if (ok.contains(ext)) return ext == 'ogg' ? 'opus' : ext;
  return 'mp3';
}

/// 任意形式の音声を mp3（16kHz / モノラル）へ揃える。
/// 方舟の input_audio は形式指定が厳しく、m4a / amr をそのまま渡すと 400 になるため、
/// ffmpeg があれば mp3 に変換し、無ければ元のバイト列をそのまま返す。
Future<List<int>> _ensureMp3Bytes(List<int> audio, String fileName) async {
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.mp3')) return audio;
  final tmp = Directory.systemTemp.path;
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final inFile = '$tmp/db_chat_in_$stamp.bin';
  final outFile = '$tmp/db_chat_out_$stamp.mp3';
  try {
    File(inFile).writeAsBytesSync(audio);
    final r = await Process.run('ffmpeg', [
      '-y',
      '-loglevel',
      'error',
      '-i',
      inFile,
      '-ac',
      '1',
      '-ar',
      '16000',
      '-b:a',
      '64k',
      outFile
    ]);
    if (r.exitCode == 0 && File(outFile).existsSync()) {
      final out = File(outFile).readAsBytesSync();
      if (out.length > 200) return out;
    }
    logp('⚠️ ffmpeg で mp3 へ変換できませんでした: ${r.stderr}');
  } catch (e) {
    logp('⚠️ ffmpeg の実行に失敗: $e');
  } finally {
    for (final p in [inFile, outFile]) {
      try {
        final f = File(p);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }
  return audio;
}

/// 方舟のマルチモーダル音声理解（/chat/completions + input_audio）で文字起こしする。
/// このアカウントでは /audio/transcriptions が 404 を返すため、こちらを主経路にする。
/// 使うのは豆包の言語モデルのみで、DeepSeek の API は一切呼ばない（用量を消費しない）。
Future<String> _dbTranscribeViaChatAudio(
    List<int> audio, String fileName, DbConfig cfg) async {
  final model = _dbPickChatModel('', cfg);
  final mp3 = await _ensureMp3Bytes(audio, fileName);
  // 変換されなかった（同一インスタンスが返った）場合は元の形式をそのまま申告する。
  // format を mp3 と偽ると方舟側で 400 になるため、ここは実体に合わせる。
  final fmt = identical(mp3, audio) ? _audioFormatOf(fileName) : 'mp3';
  final b64 = base64.encode(mp3);
  final payload = {
    'model': model,
    'temperature': 0,
    'messages': [
      {
        'role': 'user',
        'content': [
          {
            'type': 'input_audio',
            'input_audio': {'data': b64, 'format': fmt}
          },
          {
            'type': 'text',
            'text': '请把这段音频逐字转写成纯文本。不要添加标题、解释或说话人标签；'
                '听不清的部分写[不明]；只输出转写文本本身。'
          }
        ]
      }
    ],
  };
  final r = await _httpRaw('POST', '${dbBaseUrl(cfg)}/chat/completions',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${cfg.apiKey.trim()}',
      },
      body: utf8.encode(jsonEncode(payload)),
      timeout: const Duration(seconds: 240));
  if (r.code != 200) {
    throw Exception('HTTP ${r.code}: ${_errFromBytes(r.bytes)}');
  }
  final j = asMap(jsonDecode(utf8.decode(r.bytes, allowMalformed: true)));
  final choices = asList(j['choices']);
  if (choices.isEmpty) throw Exception('豆包返回了空响应');
  final msg = asMap(asMap(choices[0])['message']);
  var text = mStr(msg, 'content').trim();
  if (text.isEmpty) throw Exception('豆包返回了空的识别结果');
  text = text
      .replaceAll(RegExp(r'^```[a-zA-Z]*\n?'), '')
      .replaceAll(RegExp(r'\n?```$'), '')
      .trim();
  return text;
}

Future<String> dbTranscribeBytes(
  List<int> audio,
  String fileName, {
  String? model,
  void Function(String model, String endpoint)? onRoute,
}) async {
  if (audio.length < 200) throw Exception('音频太短');
  final cfg = getDbConfig();
  var lastErr = '';
  if (cfg.apiKey.trim().isNotEmpty) {
    // ① 方舟のマルチモーダル音声理解（主経路・豆包のみ／DeepSeek は呼ばない）
    try {
      final t = await _dbTranscribeViaChatAudio(audio, fileName, cfg);
      if (t.trim().isNotEmpty) {
        logp('🎤 豆包の音声理解で認識しました（${t.runes.length} 文字）');
        onRoute?.call(_dbPickChatModel('', cfg), '/chat/completions (input_audio)');
        return t.trim();
      }
    } catch (e) {
      lastErr = '$e';
      logp('⚠️ 豆包の音声理解に失敗（次の経路へ）: $e');
    }
    // ② 方舟の音声認識エンドポイント（環境により 404 を返す）
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
          if (t.trim().isNotEmpty) {
            onRoute?.call(useModel, '/audio/transcriptions');
            return t.trim();
          }
          final data = asList(j['data']);
          if (data.isNotEmpty) {
            final t2 = mStr(asMap(data[0]), 'text');
            if (t2.trim().isNotEmpty) {
              onRoute?.call(useModel, '/audio/transcriptions');
              return t2.trim();
            }
          }
        } catch (_) {
          if (txt.trim().isNotEmpty && !txt.trim().startsWith('{')) {
            onRoute?.call(useModel, '/audio/transcriptions');
            return txt.trim();
          }
        }
        lastErr = '豆包 ASR 返回了空结果';
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
  if (local.isNotEmpty) {
    onRoute?.call('whisper.cpp (本地)', 'local');
    return local;
  }
  throw Exception('语音识别失败：$lastErr');
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
  if (meta == null) throw Exception('找不到音频文件：$fileID');
  final f = File('$DSFilesBlobDir/${meta.relPath}');
  if (!f.existsSync()) throw Exception('找不到音频文件本体：${meta.name}');
  final bytes = f.readAsBytesSync();
  if (bytes.length > 40 * 1024 * 1024) {
    throw Exception('音频文件过大（上限 40MB）');
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

/// 播客台本生成用的对话模型：只接受真正的对话模型。
/// 方舟的播客场景模型（Doubao_scene_SLM_Doubao_Podcast_model）没有
/// /chat/completions 端点，直接使用会 404，因此必须纠正。
String _dbPickChatModel(String model, DbConfig cfg) {
  final m = model.trim();
  if (m.isNotEmpty && dbIsChatModel(m)) return m;
  final c = cfg.chatModel.trim();
  if (c.isNotEmpty && dbIsChatModel(c)) return c;
  return DB_DEFAULT_CHAT_MODEL;
}

/// 播客语音合成用的 TTS 模型：只接受 tts 目录内的模型，
/// 否则回退到配置的 TTS 模型 / 内置默认 TTS 模型。
String _dbPickTtsModel(String model, DbConfig cfg) {
  final m = model.trim();
  for (final s in dbModelCatalog) {
    if (s.value == m && s.cat == 'tts') return m;
  }
  final t = cfg.ttsModel.trim();
  if (t.isNotEmpty) return t;
  return DB_DEFAULT_TTS_MODEL;
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
  if (t.isEmpty) throw Exception('播客主题为空');
  var mins = minutes;
  if (mins < 1) mins = 1;
  if (mins > 20) mins = 20;
  final sys = dbPodcastSystemPrompt(lang, mins);
  final user = StringBuffer()
    ..writeln('テーマ: $t');
  if (style.trim().isNotEmpty) user.writeln('雰囲気・スタイル: ${style.trim()}');
  user.writeln('想定尺: 約 $mins 分');
  user.writeln('上記条件で JSON 配列の台本を出力してください。');

  // 台本生成只能用对话模型：前端可能把ポッドキャストモデル一起传进来，
  // 该模型在方舟上没有 chat 端点（HTTP 404），这里强制纠正。
  final scriptModel = _dbPickChatModel(model, cfg);
  final raw = await dbChatText(sys, [
    {'role': 'user', 'content': user.toString()}
  ], model: scriptModel, maxTokens: 8192, temperature: 0.9);
  final script = dbParsePodcastScript(raw);
  if (script.isEmpty) throw Exception('台本生成失败（空响应）');

  // 语音合成模型：播客场景模型名仅供 UI 展示，方舟 /audio/speech 与
  // /chat/completions 均不接受（HTTP 404），合成一律使用 TTS 模型。
  final usePodModel = _dbPickTtsModel(model, cfg);
  final vA = trimOr(voiceA, cfg.voice);
  var vB = trimOr(voiceB, cfg.voiceB);
  // Edge 音色映射后若 A/B 撞音色，强制给 B 换一个异性音色
  final edgeA = edgeVoiceFor(vA, lang: lang);
  if (edgeVoiceFor(vB, lang: lang) == edgeA) {
    if (lang == 'en') {
      vB = edgeA.contains('Female') ? 'en-US-GuyNeural' : 'en-US-AriaNeural';
    } else if (lang == 'ja') {
      vB = edgeA.contains('Female') ? 'ja-JP-KeitaNeural' : 'ja-JP-NanamiNeural';
    } else {
      vB = edgeA.contains('Female') ? 'zh-CN-YunxiNeural' : 'zh-CN-XiaoxiaoNeural';
    }
  }
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
    throw Exception('语音合成失败（全部 ${script.length} 行），请检查模型或音色。');
  }
  final outName = name.trim().isEmpty
      ? 'doubao_podcast_${fmtStamp14(DateTime.now())}'
      : name.trim();
  final meta = saveDbBlob(audio, outName, 'audio/mpeg', 'audio',
      source: 'doubao-podcast', prompt: t);
  if (meta == null) throw Exception('播客音频保存失败');
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
      {
        'value': m.value,
        'label': m.label,
        'category': m.cat,
        'custom': false,
        // 能力标记：前端据此显示「音声理解」「動画理解」，避免用户误判
        if (m.cat == 'chat') ...{
          'audioInput': dbSupportsAudioInput(m.value),
          'videoInput': dbSupportsVideoInput(m.value),
        },
      }
  ];
  for (final c in cfg.customModels) {
    final v = c.trim();
    if (v.isEmpty) continue;
    if (list.any((e) => e['value'] == v)) continue;
    list.add({'value': v, 'label': v, 'category': 'chat', 'custom': true});
  }
  return {
    'models': list,
    'styles': dbImageStyles,
    'audioCapableModels': dbAudioCapableModels,
    'videoCapableModels': dbVideoCapableModels,
  };
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
    'webSources': cfg.webSources,
    'webSourcesAllowed': dbWikiAllowedSources,
    'wikiEnabled': cfg.wikiEnabled,
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
    await dsJSONErr(res, 400, '无效的请求体');
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
    webSources: body.containsKey('webSources')
        ? dbWikiNormalizeSources(asList(body['webSources']).map((e) => '${e}'))
        : old.webSources,
    wikiEnabled: body.containsKey('wikiEnabled')
        ? mBool(body, 'wikiEnabled')
        : old.wikiEnabled,
  );
  // 允许显式清空 Key（clearKey=1）
  if (mBool(body, 'clearKey')) cfg.apiKey = '';
  if (!saveDbConfig(cfg)) {
    await dsJSONErr(res, 500, '配置保存失败');
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
    await dsJSONErr(res, 400, '无效的请求体');
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

/// POST /api/doubao/image-edit —— 豆包P图（本地图片 base64 + 指令）
Future<void> handleDbImageEdit(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'POST') {
    await dsJSONErr(res, 405, 'Method not allowed');
    return;
  }
  Map<String, dynamic> body;
  try {
    body = await readJsonBody(req, limit: 32 * 1024 * 1024);
  } catch (_) {
    await dsJSONErr(res, 400, '无效的请求体');
    return;
  }
  try {
    final raw = mStr(body, 'imageBase64').trim();
    if (raw.isEmpty) {
      await dsJSONErr(res, 400, 'imageBase64 为空');
      return;
    }
    final pure = raw.contains(',') ? raw.substring(raw.indexOf(',') + 1) : raw;
    List<int> img;
    try {
      img = base64.decode(pure);
    } catch (_) {
      await dsJSONErr(res, 400, '图片数据不是有效的 base64');
      return;
    }
    final out = await dbEditImage(
      image: img,
      fileName: trimOr(mStr(body, 'fileName'), 'image.png'),
      prompt: mStr(body, 'prompt'),
      model: mStr(body, 'model'),
      resolution: trimOr(mStr(body, 'resolution'), '2K'),
    );
    await dsJSONOk(res, 200, out);
  } catch (e) {
    logp('❌ 豆包P图错误: $e');
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
    await dsJSONErr(res, 400, '无效的请求体');
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
    await dsJSONErr(res, 400, '无效的请求体');
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
    await dsJSONErr(res, 400, '无效的请求体');
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
    await dsJSONErr(res, 400, '音频读取失败');
    return;
  }
  try {
    List<int> audio;
    var name = 'audio.webm';
    if (ct.contains('application/json')) {
      final j = asMap(jsonDecode(utf8.decode(raw, allowMalformed: true)));
      final b64 = mStr(j, 'audioBase64');
      if (b64.isEmpty) {
        await dsJSONErr(res, 400, 'audioBase64 为空');
        return;
      }
      audio = base64.decode(b64);
      name = trimOr(mStr(j, 'fileName'), 'audio.webm');
    } else {
      audio = extractAudioPayload(raw);
      name = _fileNameFromMultipart(raw, 'audio.webm');
    }
    var usedModel = '';
    var usedEndpoint = '';
    final text = await dbTranscribeBytes(audio, name, onRoute: (m, e) {
      usedModel = m;
      usedEndpoint = e;
    });
    await dsJSONOk(res, 200, {
      'success': true,
      'text': text,
      'model': usedModel,
      'endpoint': usedEndpoint,
    });
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
    await dsJSONErr(res, 400, '音频读取失败');
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
        await dsJSONErr(res, 400, 'audioBase64 为空');
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
    await dsJSONErr(res, 400, '无效的请求体');
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
      await dsJSONErr(res, 400, '消息为空');
      return;
    }
    final text = await dbChatText(system, msgs,
        model: mStr(body, 'model'),
        maxTokens: intArgDefault(body, 'maxTokens', 8192),
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
    await dsJSONErr(res, 400, '无效的请求体');
    return;
  }
  final fileID = mStr(body, 'fileId');
  final cfg = getDbConfig();
  final prompt = mStr(body, 'prompt');
  final wantModel = trimOr(mStr(body, 'model'), cfg.chatModel);
  try {
    final meta = getDsFileMeta(fileID);
    if (meta == null) throw Exception('找不到音频文件：$fileID');
    final f = File('$DSFilesBlobDir/${meta.relPath}');
    if (!f.existsSync()) throw Exception('找不到音频文件本体：${meta.name}');
    final bytes = f.readAsBytesSync();
    if (bytes.length > 40 * 1024 * 1024) {
      throw Exception('音频文件过大（上限 40MB）');
    }

    // ① 主路径：模型本身支持音频理解 → 音频原文直接送入方舟，
    //    由豆包自己听、自己总结，并先思考再作答（不做二次转述）。
    if (dbSupportsAudioInput(wantModel)) {
      final prepared = await dbPrepareAudioForArk(bytes, meta.name);
      final question = prompt.trim().isEmpty
          ? 'この音声の内容を詳しく教えてください。何が話されていますか。'
              '要点を整理してまとめてください。'
          : prompt.trim();
      final content = <Map<String, dynamic>>[
        dbAudioPart(prepared.format, base64Encode(prepared.bytes)),
        {'type': 'text', 'text': question},
      ];
      final answer = await _dbChatRawOnce(
        cfg,
        wantModel,
        <Map<String, dynamic>>[
          {'role': 'user', 'content': content}
        ],
        maxTokens: intArgDefault(body, 'maxTokens', 8192),
        temperature: 0.6,
        thinking: true,
      );
      await dsJSONOk(res, 200, {
        'success': true,
        'text': answer,
        'analysis': answer,
        'nativeAudio': true,
        'model': wantModel,
      });
      return;
    }

    // ② 回退：模型不支持音频理解 → 用豆包做文字转写，再让豆包文本模型分析。
    //    这条路径消耗的同样是豆包（方舟）用量，不涉及 DeepSeek。
    final text = await dbTranscribeFile(fileID);
    var analysis = '';
    if (prompt.trim().isNotEmpty) {
      analysis = await _dbChatRawOnce(
        cfg,
        _dbPickChatModel(wantModel, cfg),
        <Map<String, dynamic>>[
          {'role': 'user', 'content': '音声の書き起こし:\n$text\n\n依頼: $prompt'}
        ],
        maxTokens: 8192,
        temperature: 0.7,
        thinking: false,
        systemPrompt: '你是音频内容分析专家。请依据给定的转写文本作答，'
            '不要编造转写中不存在的内容。',
      );
    }
    await dsJSONOk(res, 200, {
      'success': true,
      'text': text,
      'analysis': analysis,
      'nativeAudio': false,
      'model': _dbPickChatModel(wantModel, cfg),
      'note': dbLocalized(dsRequestLang(req, body), 'transcribeNote'),
    });
  } catch (e) {
    await dsJSONErr(res, 500, dbErrText(e));
  }
}
