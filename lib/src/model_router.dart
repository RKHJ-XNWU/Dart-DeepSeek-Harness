// ============================================================
// model_router.dart —— 模型自动路由（图片 → 视觉模型）
//
// 解决的真实问题：
//   /api/ds-chat/send 里图片是通过「视觉模型先提取成文字」再拼进 prompt 的
//   （见 chat_send.dart 的 callDsVisionAPI 段落）。改造前该调用把
//   model: model 原样透传，也就是「你选 pro，就用 pro 去读图」——
//   pro 是纯文本模型，必然提取失败（日志会出现「图片内容提取失败」）。
//
// 本模块提供三层能力：
//   1) 能力判定 modelSupportsVision()：内置 DeepSeek 型号表 + 常见第三方
//      视觉型号模式 + ユーザー自定义白/黑名单（配置文件里可覆盖）；
//   2) 路由决策 resolveModelRoute()：纯函数，输入「ユーザー所选模型 + 本轮是否
//      含图片」，输出「主请求实际模型 / 图片提取用模型 / 决策原因」；
//   3) 配置与可观测性：设置持久化到 data/deepseek_chat/model_router.sts，
//      路由记录进内存环（最多 40 条），并暴露 /api/ds-chat/model-router。
//
// 设计取向：未知型号按「纯文本」保守处理 —— 含图时一律改走视觉兜底模型，
// 宁可多路由一次，也不要把图交给看不见图的模型（那样只会得到
// 「图片内容提取失败」而不是报错，属于静默降级，最难排查）。
// ============================================================

import 'dart:convert';
import 'dart:io';

import 'ds_crypto.dart';
import 'globals.dart';
import 'httpsrv.dart';

// ------------------------------------------------------------
// 常量
// ------------------------------------------------------------
const String MR_VERSION = 'mr1';

/// 默认视觉兜底模型：DeepSeek V4.1 Flash 在官方目录里声明了 text + image
const String MR_DEFAULT_VISION_MODEL = 'deepseek-flash';

String get modelRouterFile => '$dsChatDir/model_router.sts';

/// 内置：确认支持图片输入的型号
const Set<String> _builtinVisionModels = <String>{
  'deepseek-flash', // V4.1 Flash：目录 inputModalities = text,image
  'deepseek-v4.1-flash',
  'deepseek-v4-flash-vision-exp', // 旧视觉实验别名
  'deepseek-vision',
};

/// 内置：确认**不**支持图片输入的型号（纯文本，含旧别名陷阱）
const Set<String> _builtinTextModels = <String>{
  'deepseek-v4-pro',
  'deepseek-pro',
  'deepseek-v4-flash', // 旧别名：DSH/兼容层按纯文本处理，不要当成 flash 视觉能力
  'deepseek-chat',
  'deepseek-reasoner',
  'deepseek-coder',
  'deepseek-v3',
};

/// 第三方型号：名字命中即视为支持图片（下划线/连字符/大小写不敏感）
const List<String> _visionPatterns = <String>[
  'vision', 'vl-', '-vl', 'gpt-4o', 'gpt-4.1', 'gpt-5', 'o3', 'o4-mini',
  'claude-3', 'claude-4', 'claude-sonnet', 'claude-opus',
  'gemini', 'qwen-vl', 'qwen2-vl', 'qwen3-vl', 'glm-4v', 'glm-4.5v',
  'mimo-v2', 'internvl', 'llava', 'pixtral', 'doubao-vision', 'step-1v',
  'grok-4', 'ernie-4.5-vl',
];

String _norm(String model) => model.trim().toLowerCase().replaceAll('_', '-');

// ------------------------------------------------------------
// 配置
// ------------------------------------------------------------
class ModelRouteSettings {
  /// 总开关：关闭后不做任何路由（图片仍会用 visionModel 提取，但主请求保持所选）
  final bool enabled;

  /// 含图时是否把「主请求」也切到视觉模型。
  /// true  = 整轮都交给视觉模型（默认，行为最接近「自动切到 flash」）
  /// false = 只用视觉模型提取图片文字，正文仍由ユーザー所选模型作答
  final bool routeMain;

  /// 视觉兜底模型（图片提取 + 主请求路由目标）
  final String visionModel;

  /// 额外声明「支持图片」的自定义模型名（逗号分隔存储，判定优先级最高）
  final List<String> extraVision;

  /// 额外声明「不支持图片」的模型名（优先于内置视觉表）
  final List<String> extraText;

  const ModelRouteSettings({
    required this.enabled,
    required this.routeMain,
    required this.visionModel,
    required this.extraVision,
    required this.extraText,
  });

  static const ModelRouteSettings defaults = ModelRouteSettings(
    enabled: true,
    routeMain: true,
    visionModel: MR_DEFAULT_VISION_MODEL,
    extraVision: <String>[],
    extraText: <String>[],
  );

  ModelRouteSettings copyWith({
    bool? enabled,
    bool? routeMain,
    String? visionModel,
    List<String>? extraVision,
    List<String>? extraText,
  }) =>
      ModelRouteSettings(
        enabled: enabled ?? this.enabled,
        routeMain: routeMain ?? this.routeMain,
        visionModel: visionModel ?? this.visionModel,
        extraVision: extraVision ?? this.extraVision,
        extraText: extraText ?? this.extraText,
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'routeMain': routeMain,
        'visionModel': visionModel,
        'extraVision': extraVision,
        'extraText': extraText,
      };
}

// ------------------------------------------------------------
// 读写（明文 .sts，与 displaymodels / sessions 同系转义规则）
//   行格式： #MR|版本|enabled|routeMain|visionModel|extraVision|extraText
// ------------------------------------------------------------
ModelRouteSettings _parseSettingsLine(String line) {
  // 容错：允许旧格式只有 3 段
  final parts = line.split('|');
  bool parseBool(String s, bool def) {
    final t = s.trim().toLowerCase();
    if (t == '1' || t == 'true' || t == 'on') return true;
    if (t == '0' || t == 'false' || t == 'off') return false;
    return def;
  }

  List<String> parseList(String s) => s
      .split(',')
      .map((e) => unescDs(e).trim())
      .where((e) => e.isNotEmpty)
      .toList();

  if (parts.length < 4) return ModelRouteSettings.defaults;
  final enabled = parseBool(parts[2], true);
  final routeMain = parseBool(parts[3], true);
  final vision = parts.length >= 5 ? unescDs(parts[4]).trim() : '';
  final extraVision = parts.length >= 6 ? parseList(parts[5]) : <String>[];
  final extraText = parts.length >= 7 ? parseList(parts[6]) : <String>[];
  return ModelRouteSettings(
    enabled: enabled,
    routeMain: routeMain,
    visionModel: vision.isEmpty ? MR_DEFAULT_VISION_MODEL : vision,
    extraVision: extraVision,
    extraText: extraText,
  );
}

ModelRouteSettings getModelRouteSettings() {
  final f = File(modelRouterFile);
  if (!f.existsSync()) return ModelRouteSettings.defaults;
  String data;
  try {
    data = f.readAsStringSync();
  } catch (_) {
    return ModelRouteSettings.defaults;
  }
  for (final raw in data.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#MR|')) return _parseSettingsLine(line);
  }
  return ModelRouteSettings.defaults;
}

bool saveModelRouteSettings(ModelRouteSettings s) {
  var vision = s.visionModel.trim();
  if (vision.isEmpty) vision = MR_DEFAULT_VISION_MODEL;
  String encList(List<String> v) => v.map(escDs).join(',');
  final line = '#MR|$MR_VERSION|${s.enabled ? 1 : 0}|${s.routeMain ? 1 : 0}|'
      '${escDs(vision)}|${encList(s.extraVision)}|${encList(s.extraText)}\n';
  try {
    ensureDir(dsChatDir);
    final tmp = File('$modelRouterFile.tmp');
    tmp.writeAsStringSync(line);
    tmp.renameSync(modelRouterFile);
    Process.runSync('chmod', ['600', modelRouterFile]);
    return true;
  } catch (e) {
    logp('❌ モデルルーティング設定の保存に失敗しました: $e');
    return false;
  }
}

// ------------------------------------------------------------
// 能力判定
// ------------------------------------------------------------
bool modelSupportsVision(String model, {ModelRouteSettings? settings}) {
  final m = _norm(model);
  if (m.isEmpty) return false;
  final s = settings ?? getModelRouteSettings();

  // 1) ユーザー显式声明优先（黑名单 > 白名单 > 内置）
  for (final t in s.extraText) {
    if (_norm(t) == m) return false;
  }
  for (final v in s.extraVision) {
    if (_norm(v) == m) return true;
  }

  // 2) 内置精确表
  if (_builtinTextModels.contains(m)) return false;
  if (_builtinVisionModels.contains(m)) return true;

  // 3) 模式匹配（第三方型号）
  for (final p in _visionPatterns) {
    if (m.contains(p)) return true;
  }

  // 4) 未知型号 → 保守按纯文本处理
  return false;
}

/// 视觉兜底模型是否真的可用（配置写错时纠正为默认值）
String _resolveVisionModel(ModelRouteSettings s) {
  final want = s.visionModel.trim();
  if (want.isEmpty) return MR_DEFAULT_VISION_MODEL;
  if (modelSupportsVision(want, settings: s)) return want;
  logp('⚠️ 設定されたビジョンモデル「$want」が能力判定に通らなかったため、$MR_DEFAULT_VISION_MODEL を使用します');
  return MR_DEFAULT_VISION_MODEL;
}

// ------------------------------------------------------------
// 路由决策（纯函数）
// ------------------------------------------------------------
class ModelRouteDecision {
  /// ユーザー/前端所选的模型
  final String requested;

  /// 主请求实际使用的模型
  final String effective;

  /// 图片内容提取使用的模型
  final String visionModel;

  /// selected-supports-vision / image-route / router-disabled /
  /// no-image / empty-requested
  final String reason;

  /// effective != requested
  final bool routed;

  /// 本轮是否含图片
  final bool hasImage;

  /// 所选模型自身是否支持图片
  final bool requestedSupportsVision;

  const ModelRouteDecision({
    required this.requested,
    required this.effective,
    required this.visionModel,
    required this.reason,
    required this.routed,
    required this.hasImage,
    required this.requestedSupportsVision,
  });

  Map<String, dynamic> toJson() => {
        'requested': requested,
        'effective': effective,
        'visionModel': visionModel,
        'reason': reason,
        'routed': routed,
        'hasImage': hasImage,
        'requestedSupportsVision': requestedSupportsVision,
      };

  String get summary =>
      routed ? '$requested → $effective（$reason）' : '$requested（$reason）';
}

ModelRouteDecision resolveModelRoute(
  String requested, {
  required bool hasImage,
  ModelRouteSettings? settings,
}) {
  final s = settings ?? getModelRouteSettings();
  final req = requested.trim();
  final vision = _resolveVisionModel(s);

  if (req.isEmpty) {
    final eff = hasImage ? vision : DS_DEFAULT_MODEL;
    return ModelRouteDecision(
      requested: req,
      effective: eff,
      visionModel: vision,
      reason: 'empty-requested',
      routed: false,
      hasImage: hasImage,
      requestedSupportsVision: false,
    );
  }

  final supports = modelSupportsVision(req, settings: s);

  if (!hasImage) {
    return ModelRouteDecision(
      requested: req,
      effective: req,
      visionModel: supports ? req : vision,
      reason: 'no-image',
      routed: false,
      hasImage: false,
      requestedSupportsVision: supports,
    );
  }

  if (supports) {
    return ModelRouteDecision(
      requested: req,
      effective: req,
      visionModel: req,
      reason: 'selected-supports-vision',
      routed: false,
      hasImage: true,
      requestedSupportsVision: true,
    );
  }

  if (!s.enabled) {
    return ModelRouteDecision(
      requested: req,
      effective: req,
      visionModel: vision,
      reason: 'router-disabled',
      routed: false,
      hasImage: true,
      requestedSupportsVision: false,
    );
  }

  return ModelRouteDecision(
    requested: req,
    effective: s.routeMain ? vision : req,
    visionModel: vision,
    reason: 'image-route',
    routed: s.routeMain && vision != req,
    hasImage: true,
    requestedSupportsVision: false,
  );
}

// ------------------------------------------------------------
// 内存路由记录（最多 40 条，进程重启即清空）
// ------------------------------------------------------------
final List<Map<String, dynamic>> _routeLog = <Map<String, dynamic>>[];
const int MR_LOG_MAX = 40;

void recordModelRoute(ModelRouteDecision d) {
  // 同一次发送会经过 send/stream 多处逻辑，这里只记录首个决策点即可，
  // 但为了排查方便仍然去重：5 秒内完全相同的决策不重复入列。
  final now = DateTime.now();
  if (_routeLog.isNotEmpty) {
    final last = _routeLog.first;
    final lastAt = DateTime.tryParse('${last['at']}');
    if (lastAt != null &&
        now.difference(lastAt).inSeconds < 5 &&
        last['requested'] == d.requested &&
        last['effective'] == d.effective &&
        last['reason'] == d.reason) {
      return;
    }
  }
  _routeLog.insert(0, {
    ...d.toJson(),
    'at': rfc3339(now),
  });
  while (_routeLog.length > MR_LOG_MAX) {
    _routeLog.removeLast();
  }
}

List<Map<String, dynamic>> getModelRouteLog() =>
    _routeLog.map((e) => Map<String, dynamic>.from(e)).toList();

// ------------------------------------------------------------
// /api/ds-chat/model-router
//   GET                       → 当前配置 + 能力表 + 最近路由记录
//   GET ?model=x&hasImage=1   → 附带一次试算 preview
//   POST {enabled,routeMain,visionModel,extraVision,extraText}
//                              → 保存（未提供的字段保持原值）
// ------------------------------------------------------------
Future<void> handleDsChatModelRouter(HttpRequest req) async {
  final res = req.response;

  switch (req.method) {
    case 'GET':
      final s = getModelRouteSettings();
      final probeRaw = qp(req, 'model').trim();
      final probe = probeRaw.isEmpty ? DS_DEFAULT_MODEL : probeRaw;
      final hasImageRaw = qp(req, 'hasImage').toLowerCase();
      final hasImage = hasImageRaw == '1' || hasImageRaw == 'true';
      final preview = resolveModelRoute(probe, hasImage: hasImage, settings: s);
      await dsJSONOk(res, 200, {
        'success': true,
        'config': s.toJson(),
        'defaultVisionModel': MR_DEFAULT_VISION_MODEL,
        'capabilities': {
          'visionModels': _builtinVisionModels.toList(),
          'textOnlyModels': _builtinTextModels.toList(),
          'visionPatterns': _visionPatterns,
        },
        'preview': preview.toJson(),
        'recent': getModelRouteLog(),
        'file': modelRouterFile,
      });
      return;

    case 'POST':
      Map<String, dynamic> body;
      try {
        body = await readJsonBody(req);
      } catch (_) {
        await dsJSONErr(res, 400, '無効なリクエストボディです');
        return;
      }
      final old = getModelRouteSettings();
      List<String> listArg(String key, List<String> def) {
        final v = body[key];
        if (v == null) return def;
        if (v is List) {
          return v.map((e) => '$e'.trim()).where((e) => e.isNotEmpty).toList();
        }
        return '$v'
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
      }

      final next = ModelRouteSettings(
        enabled: body.containsKey('enabled')
            ? mBool(body, 'enabled', old.enabled)
            : old.enabled,
        routeMain: body.containsKey('routeMain')
            ? mBool(body, 'routeMain', old.routeMain)
            : old.routeMain,
        visionModel: trimOr(mStr(body, 'visionModel'), old.visionModel),
        extraVision: listArg('extraVision', old.extraVision),
        extraText: listArg('extraText', old.extraText),
      );
      if (!saveModelRouteSettings(next)) {
        await dsJSONErr(res, 500, '保存に失敗しました');
        return;
      }
      logp('✅ モデル自動ルーティング設定を更新しました: enabled=${next.enabled}'
          'routeMain=${next.routeMain} vision=${next.visionModel}');
      await dsJSONOk(res, 200, {
        'success': true,
        'config': next.toJson(),
        'file': modelRouterFile,
      });
      return;

    default:
      await dsJSONErr(res, 405, 'Method not allowed');
  }
}

/// 供调试/自检使用：把当前判定结果序列化成一行文本
String describeModelRoute(String model, {required bool hasImage}) {
  final d = resolveModelRoute(model, hasImage: hasImage);
  return jsonEncode(d.toJson());
}
