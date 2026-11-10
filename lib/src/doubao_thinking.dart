// ============================================================
// doubao_thinking.dart —— 豆包「深度思考」输出优化引擎
//
// 依据：火山方舟《深度思考》官方文档
//       https://docs.volcengine.com/docs/ark/deep-thinking
//
// 文档中的三条硬事实（本文件全部围绕它们设计）：
//   ① thinking.type 仅 enabled / disabled 两值；
//   ② reasoning_effort 可调思维链长度，7 档：
//      none / minimal / low / medium / high / xhigh / max，
//      豆包 seed-2.1 系默认 high，seed-2.0 系默认 medium；
//      minimal 等价于关闭思考，none 会被映射为 minimal；
//   ③ 部分模型默认开启 thinking summary：
//      「默认开启 thinking summary 能力后，可能会有较高的包间延迟，
//        请调大请求超时时间（timeout），并做好兼容适配。」
//      summary 模型只返回「思考摘要」，块与块之间天然有空档，
//      这就是「豆包思考链一卡一卡」的真实成因（不是前端 bug）。
//
// 本文件的解法由三层组成：
//   第 1 层 参数层：按模型能力表下发 thinking + reasoning_effort，
//            把「思考多久」先压下来（文档第 ② 条）。
//   第 2 层 传输层：DbThinkSmoother 把上游的「大块摘要突发」切成一字
//            级别的 micro-delta，按固定节拍下发，把包间空档填平。
//   第 3 层 自适应层：DbThinkPacer 记录每次突发间隔，动态调整节拍与
//            单拍字数——上游安静时慢而稳，上游猛灌时快速追赶，
//            视觉上始终是恒速滚动，不出现「停 0.8 秒再蹦 20 字」。
//
// 另外：summary 模型的思考内容由 encrypted_content 承载原始推理，
// 工具多轮场景必须原样回传（文档「回传思考内容加密原文」一节），
// 否则「将导致模型推理效果下降」。本文件提供 DbThinkLedger 负责缓存与回传。
// ============================================================

import 'dart:async';

// ------------------------------------------------------------
// 模型能力档案
// ------------------------------------------------------------

/// 单个豆包（方舟）模型的深度思考能力描述。
class DbThinkingProfile {
  /// 规范化后的模型 id（小写，去空格）
  final String model;

  /// 是否接受 thinking 字段。第三方模型（部分 glm / kimi）不接受，
  /// 传入会被网关 400，故必须为 false。
  final bool acceptsThinking;

  /// 是否默认开启 thinking summary。
  /// true  → 只回「思考摘要」，块间空档大，必须走平滑补偿；
  /// false → 回原始思考内容，本身已经比较连续。
  final bool summaryModel;

  /// 是否支持 reasoning_effort 调节思维链长度。
  final bool supportsEffort;

  /// 该模型 reasoning_effort 的默认档（文档表格原值）。
  final String defaultEffort;

  /// 是否支持回传 encrypted_content（summary 模型才有该字段）。
  final bool supportsEncrypted;

  /// 是否为「始终开启思考、不接受 thinking 字段」的模型
  /// （文档：glm-5-3-flash-260828「始终启用思考，不再支持禁用思考」）。
  final bool alwaysThinking;

  const DbThinkingProfile({
    required this.model,
    required this.acceptsThinking,
    required this.summaryModel,
    required this.supportsEffort,
    required this.defaultEffort,
    required this.supportsEncrypted,
    this.alwaysThinking = false,
  });

  /// 该档案是否完全没有可调项（第三方模型、且无 effort 支持）
  bool get isPlain => !acceptsThinking && !supportsEffort;

  @override
  String toString() => 'DbThinkingProfile($model, summary=$summaryModel, '
      'effort=$defaultEffort/$supportsEffort, enc=$supportsEncrypted)';
}

/// 文档「支持 thinking → enabled/disabled」的豆包系模型前缀表。
/// 未列入者按「不接受 thinking」处理，宁可少传也不要 400。
const List<String> _dbThinkingCapablePrefixes = <String>[
  'doubao-seed-evolving',
  'doubao-seed-2-1',
  'doubao-seed-2-0',
  'doubao-seed-character',
  'doubao-seed-1-8',
  'doubao-seed-1-6',
  'doubao-seed-1',
  'doubao-pro',
  'doubao-lite',
  'deepseek-v4',
  'glm-5-2',
  'glm-5-3',
];

/// 文档「默认开启 thinking summary」清单（逐条对应，含 260915 / 260628 等版本）。
/// 这里以「模型族 + 版本号」双条件匹配，既能拦住已列版本，
/// 也能覆盖同族后续小版本（版本号不同但机制一致）。
const List<String> _dbSummaryFamilies = <String>[
  'doubao-seed-evolving',
  'doubao-seed-2-1-pro',
  'doubao-seed-2-1-lite',
  'doubao-seed-2-1-turbo',
  'doubao-seed-2-0-lite-260428',
  'doubao-seed-2-0-mini-260428',
];

/// 文档「支持 reasoning_effort」清单的模型族。
const List<String> _dbEffortFamilies = <String>[
  'doubao-seed-evolving',
  'doubao-seed-2-1',
  'doubao-seed-2-0',
  'doubao-seed-character',
  'glm-5-3-flash',
  'glm-5-3',
  'glm-5-2',
  'doubao-seed-translation',
  'kimi-k3',
  'deepseek-v4',
];

/// 生成模型能力档案。
///
/// 关键点：`doubao-seed-2-1-lite`（用户点名要专门适配的 lite 档）与
/// `doubao-seed-2-1-pro`、`doubao-seed-2-0-turbo` 等全部走同一套判定，
/// 因此新增模型 id 时无需改这里，只要族名命中文档清单即可。
DbThinkingProfile dbThinkingProfileOf(String rawModel) {
  final m = rawModel.trim().toLowerCase();
  if (m.isEmpty) {
    // 空模型 = 用配置里的默认对话模型，交给上层再解析一次
    return const DbThinkingProfile(
      model: '',
      acceptsThinking: true,
      summaryModel: false,
      supportsEffort: false,
      defaultEffort: 'medium',
      supportsEncrypted: false,
    );
  }

  var accepts = false;
  for (final p in _dbThinkingCapablePrefixes) {
    if (m.startsWith(p)) {
      accepts = true;
      break;
    }
  }

  var summary = false;
  for (final p in _dbSummaryFamilies) {
    if (m.startsWith(p)) {
      summary = true;
      break;
    }
  }
  // 2.0 系的 lite/mini 260428 之后的版本同样是 summary 机制：
  // 文档只写了 260428，但同族新版本未变更机制，这里按族放宽。
  if (!summary &&
      (m.startsWith('doubao-seed-2-0-lite-2604') ||
          m.startsWith('doubao-seed-2-0-mini-2604'))) {
    summary = true;
  }

  var effort = false;
  for (final p in _dbEffortFamilies) {
    if (m.startsWith(p)) {
      effort = true;
      break;
    }
  }

  // 文档表格：2.1 系（含 evolving）默认 high；2.0 系与 character 默认 medium；
  // glm-5-3 / kimi-k3 默认 max（始终思考）；deepseek-v4 默认 high。
  var def = 'medium';
  if (m.startsWith('doubao-seed-evolving') || m.startsWith('doubao-seed-2-1')) {
    def = 'high';
  } else if (m.startsWith('glm-5-3') || m.startsWith('kimi-k3')) {
    def = 'max';
  } else if (m.startsWith('glm-5-2')) {
    def = 'high';
  } else if (m.startsWith('deepseek-v4')) {
    def = 'high';
  }

  final always = m.startsWith('glm-5-3-flash') || m.startsWith('kimi-k3');

  return DbThinkingProfile(
    model: m,
    acceptsThinking: accepts,
    summaryModel: summary,
    supportsEffort: effort,
    defaultEffort: def,
    // 文档：thinking summary 模型才返回 encrypted_content
    supportsEncrypted: summary,
    alwaysThinking: always,
  );
}

// ------------------------------------------------------------
// 思考档位
// ------------------------------------------------------------

/// UI 侧的「推理等级」映射到的方舟档位。
///
/// 项目里已有 1–50 的推理等级（dscLevelBtn），这里把它压到文档的 7 档上，
/// 保证「用户调等级 → 真的改变思维链长度」，而不是只改个数字。
String dbEffortFromLevel(int level, DbThinkingProfile prof) {
  if (!prof.supportsEffort) return '';
  var lv = level;
  if (lv <= 0) lv = 30;
  if (lv > 50) lv = 50;

  final String want;
  if (lv <= 4) {
    want = 'minimal';
  } else if (lv <= 12) {
    want = 'low';
  } else if (lv <= 26) {
    want = 'medium';
  } else if (lv <= 38) {
    want = 'high';
  } else if (lv <= 46) {
    want = 'xhigh';
  } else {
    want = 'max';
  }

  // glm-5-3 / kimi-k3 的映射规则与豆包不同（文档兼容映射表），
  // 这里只在明显越界时收敛，避免下发无效档位。
  if (prof.alwaysThinking) {
    if (want == 'none' || want == 'minimal') return 'low';
  }
  return want;
}

/// 组装一次请求要附加到 body 的思考参数。
///
/// [mode] 语义：
///   · auto   —— 交给默认策略（普通聊天：优先响应速度）
///   · on     —— 强制开启（识图 / 识音 / 识影 / 工具多轮）
///   · off    —— 强制关闭（快速模式）
///
/// 返回值直接 `body.addAll(...)`，不含 thinking 以外的键。
Map<String, dynamic> dbThinkingBody(
  String model, {
  String mode = 'auto',
  int level = 30,
  bool fastMode = false,
}) {
  final prof = dbThinkingProfileOf(model);
  final out = <String, dynamic>{};

  // ① thinking.type
  if (prof.acceptsThinking && !prof.alwaysThinking) {
    if (mode == 'off' || (mode == 'auto' && fastMode)) {
      out['thinking'] = <String, dynamic>{'type': 'disabled'};
    } else if (mode == 'on') {
      out['thinking'] = <String, dynamic>{'type': 'enabled'};
    }
    // mode == auto 且非快速模式：不传，保留模型默认（文档：默认 enabled）
  }

  // ② reasoning_effort：这是真正能缩短思维链、降低包间延迟的旋钮。
  //    快速模式直接 minimal（文档：minimal = 关闭思考、直接回答）；
  //    否则按推理等级映射。
  // 已经下发 thinking.disabled 时不再写 reasoning_effort：
  // 两个「关闭思考」的字段同时出现没有额外收益，却多一次网关校验机会
  // （部分网关对 disabled + effort 的组合返回 400）。语义上 disabled 更强。
  final alreadyDisabled = out['thinking'] is Map &&
      '${(out['thinking'] as Map)['type']}' == 'disabled';
  if (prof.supportsEffort && !alreadyDisabled) {
    final e = dbEffortFromLevel(level, prof);
    if (e.isNotEmpty) out['reasoning_effort'] = e;
  }
  return out;
}

/// 该模型是否属于「思考链一定会卡」的 summary 型。
/// 前端据此决定是否开启「节拍平滑」以及是否显示「摘要」角标。
bool dbModelIsSummaryThinking(String model) =>
    dbThinkingProfileOf(model).summaryModel;

// ------------------------------------------------------------
// 第 2 层：micro-delta 平滑器
// ------------------------------------------------------------

/// 把上游「大块突发」重排成「小口匀速」的思考链转发器。
///
/// 为什么需要它：
///   summary 模型的一次回调可能一次给 60–200 字，然后静默 0.5–1.2 秒。
///   前端即使有时间驱动播放，也会因为「一次收到一大坨」而出现
///   「瞬间冲出十几行 → 停住 → 再冲出十几行」的机械感。
///   本类在服务端就把这一坨切成 2–4 字的微片，按 12–24ms 的节拍下发，
///   前端每个渲染帧都有新字符进来，观感即为连续打字。
///
/// 线程模型：单线程事件循环 + 单个 Timer，无锁、无 Future 链，开销可忽略。
class DbThinkSmoother {
  /// 下游出口（通常是 sse.send('reasoning', ...)）
  final void Function(String delta) sink;

  /// 基础节拍（毫秒）。越小越顺滑，但帧开销越大。
  final int baseIntervalMs;

  /// 单拍最少 / 最多吐出的字符数
  final int minPerTick;
  final int maxPerTick;

  final StringBuffer _queue = StringBuffer();
  Timer? _timer;

  /// 统计：上游来了多少字、已经吐出多少字
  int _inChars = 0;
  int _outChars = 0;

  /// 上游最近一次 push 的时刻（用于计算空档长度）
  int _lastPushMs = 0;

  /// 最近一次实测的上游突发间隔（毫秒）
  int _lastGapMs = 0;

  /// 当前追赶系数：1.0 = 正常，>1.0 = 积压较多，加速吐出
  double _boost = 1.0;

  /// 上游平均速率（字/秒，EWMA 平滑）。
  ///
  /// summary 模型的包间延迟不是常数（实测 0.2–1.2 秒都有），
  /// 固定节拍只有两种结局：要么吐得太快提前空等，要么吐得太慢越积越多。
  /// 这里用 EWMA 估计「上游每秒给多少字」，再把吐出速率对齐到它，
  /// 使积压稳定在一个很薄的缓冲区里，观感即恒速。
  double _rateCharsPerSec = 0;
  int _rateSamples = 0;

  /// 慢吐相位（库存策略用：偶数拍才吐 1 字，等效把吐速减半）
  int _slowPhase = 0;

  bool _closed = false;

  DbThinkSmoother(
    this.sink, {
    this.baseIntervalMs = 16,
    this.minPerTick = 2,
    this.maxPerTick = 6,
  });

  /// 当前积压字符数
  int get backlog => _queue.length;

  /// 已吐出的总字符数
  int get emittedChars => _outChars;

  /// 最近一次上游突发间隔（毫秒），0 表示还没测到
  int get lastGapMs => _lastGapMs;

  /// 上游推入一段思考内容。可在任意时刻、任意频率调用。
  void push(String s) {
    if (_closed || s.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastPushMs > 0) {
      final gap = now - _lastPushMs;
      // 只统计「有意义」的空档：同一批次内的连续回调不算
      if (gap > 40) _lastGapMs = gap;
    }
    if (_lastGapMs > 0) {
      // 单次批量的瞬时速率，用 EWMA（α=0.35）抑制抖动
      final inst = s.length * 1000.0 / _lastGapMs;
      if (_rateSamples == 0) {
        _rateCharsPerSec = inst;
      } else {
        _rateCharsPerSec = _rateCharsPerSec * 0.65 + inst * 0.35;
      }
      if (_rateCharsPerSec > 0) _rateSamples++;
    }
    _lastPushMs = now;
    _queue.write(s);
    _inChars += s.length;
    _retune();
    _ensureTimer();
  }

  /// 上游已经结束：把剩下的内容一次性吐完并停止定时器。
  /// 必须先 await 它，再发 content / done，保证思考链顺序正确。
  Future<void> flushAll() async {
    if (_closed) return;
    _timer?.cancel();
    _timer = null;
    _drainFast();
    _closed = true;
  }

  /// 上游正文已经开始输出时调用：思考链不必再慢慢磨，
  /// 立即把积压全部吐掉，避免「正文都出完了思考还在爬」。
  void hurry() {
    if (_closed) return;
    _timer?.cancel();
    _timer = null;
    _drainFast();
  }

  /// 把积压一次性排空。
  ///
  /// 不做成「一个字一个包」：收尾阶段（正文已开始 / 流已结束）用户要的是
  /// 立刻看到完整思考，而不是继续匀速爬。但也不直接把几万字砸成一个包——
  /// 按 40 字切片，既不给前端制造超长单帧，也不会产生大片空档。
  void _drainFast() {
    if (_queue.length == 0) return;
    final rest = _queue.toString();
    _queue.clear();
    _outChars += rest.length;
    const slice = 40;
    if (rest.length <= slice) {
      sink(rest);
      return;
    }
    for (var i = 0; i < rest.length; i += slice) {
      final end = (i + slice < rest.length) ? i + slice : rest.length;
      sink(rest.substring(i, end));
    }
  }

  /// 立即终止（异常路径）
  void dispose() {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    _queue.clear();
  }

  // ---- 内部 ----

  /// 依据实测空档与积压量调整节拍与追赶系数。
  ///
  /// 空档越长，说明上游「攒包」越严重，恢复后必须加速，
  /// 否则积压会持续增长（旧实现正是因此越到后面越卡）。
  void _retune() {
    final backlog = _queue.length;
    // 积压超过 200 字：视为严重落后，系数线性抬到 4.0 封顶
    if (backlog > 200) {
      _boost = 4.0;
    } else if (backlog > 80) {
      _boost = 2.2;
    } else if (backlog > 24) {
      _boost = 1.5;
    } else {
      _boost = 1.0;
    }
    // 上游刚给过一个超长空档（>600ms）：下一段稍微加快，抹平观感断层
    if (_lastGapMs > 600 && _boost < 1.5) _boost = 1.5;
  }

  /// 目标库存：上游约 1 秒的字数。
  /// 积压低于它时进入「慢吐」，把手里这点字摊开来放，
  /// 用来填补上游下一段断流；积压一旦超过它就恢复正常速率，
  /// 因此不会无限滞后（滞留量稳定在 ~1 秒上游产出附近）。
  /// 还没测到上游节奏时用一个保守默认值（120 字 ≈ 1 秒量），
  /// 这样「第一块就遇到长断流」的场景同样有库存可摊，
  /// 而不是第一块就按最大速率冲完、然后干等。
  double get _holdBackChars =>
      _rateSamples == 0 ? 120.0 : _rateCharsPerSec * 1.0;

  int get _perTick {
    if (_rateSamples == 0 || _rateCharsPerSec <= 0) {
      // 还没测到上游节奏：用最小节拍先动起来，避免第一块就大面积空等
      var n0 = minPerTick;
      if (n0 > maxPerTick) n0 = maxPerTick;
      return n0;
    }
    // 本拍该吐多少字 = 上游速率 × 拍长
    var n = (_rateCharsPerSec * baseIntervalMs / 1000.0).round();
    if (n < 1) n = 1;
    // 积压明显高于「上游 1.2 秒的量」时加速追赶，防止越拖越远
    final targetBacklog = _rateCharsPerSec * 1.2;
    if (_queue.length > targetBacklog * 2) {
      n = (n * _boost).round();
    }
    if (n > maxPerTick) n = maxPerTick;
    return n;
  }

  void _ensureTimer() {
    if (_timer != null || _closed) return;
    _timer = Timer.periodic(Duration(milliseconds: baseIntervalMs), (_) {
      if (_closed) return;
      if (_queue.length == 0) {
        _timer?.cancel();
        _timer = null;
        return;
      }
      // ★ 库存策略：积压不足「上游 1 秒的量」时，隔拍吐 1 字。
      //   作用是把已有内容摊薄，填掉上游下一次断流造成的空档。
      //   上游一给新的批量，积压超过阈值，立刻恢复正常速率。
      if (_queue.length <= _holdBackChars) {
        _slowPhase = (_slowPhase + 1) % 2;
        if (_slowPhase != 0) return;
        final one = _queue.toString().substring(0, 1);
        final restOne = _queue.toString().substring(1);
        _queue
          ..clear()
          ..write(restOne);
        _outChars += one.length;
        sink(one);
        return;
      }
      final n = _perTick;
      final len = _queue.length;
      final take = n > len ? len : n;
      final piece = _queue.toString().substring(0, take);
      // StringBuffer 不支持前向删除，直接重建剩余部分。
      // 思考链单片很小（≤ 数十 KB），重建开销可忽略。
      final rest = _queue.toString().substring(take);
      _queue
        ..clear()
        ..write(rest);
      _outChars += piece.length;
      sink(piece);
      if (_queue.length == 0) {
        _timer?.cancel();
        _timer = null;
      }
    });
  }

  /// 诊断用：一行摘要
  String debugSummary() =>
      'in=$_inChars out=$_outChars backlog=${_queue.length} '
      'gap=${_lastGapMs}ms rate=${_rateCharsPerSec.toStringAsFixed(0)}字/秒 '
      'boost=${_boost.toStringAsFixed(1)}';
}

// ------------------------------------------------------------
// 第 3 层：encrypted_content 账本（工具多轮必须回传）
// ------------------------------------------------------------

/// 记录每轮 assistant 的思考摘要与加密原文，供下一轮回传。
///
/// 文档原文：
///   「在多轮工具调用场景（如 agent 场景），必须原样回传思考内容加密原文」
///   「如果没有回传 encrypted_content 字段，将导致模型推理效果下降」
/// 方舟要求：encrypted_content 优先级高于 reasoning_content，
/// 且被篡改则无法还原 —— 因此这里只做「原样存放 + 原样取回」，不解析、不改写。
class DbThinkLedger {
  /// 本轮（一次用户提问引发的整条工具链）内的所有思考快照
  final List<DbThinkSnapshot> _items = <DbThinkSnapshot>[];

  List<DbThinkSnapshot> get items => List.unmodifiable(_items);
  bool get isEmpty => _items.isEmpty;

  /// 记录一次 assistant 轮次的思考内容。
  void record({required String reasoning, required String encrypted}) {
    if (reasoning.trim().isEmpty && encrypted.trim().isEmpty) return;
    _items.add(DbThinkSnapshot(reasoning: reasoning, encrypted: encrypted));
  }

  /// 把第 [index] 轮的思考字段写进消息体（供下一轮 messages 使用）。
  /// 返回是否真的写入了字段。
  bool applyTo(Map<String, dynamic> message, int index) {
    if (index < 0 || index >= _items.length) return false;
    final s = _items[index];
    var wrote = false;
    if (s.encrypted.trim().isNotEmpty) {
      message['encrypted_content'] = s.encrypted;
      wrote = true;
    }
    // 即使有 encrypted，也把摘要带上：不同网关对字段支持度不同，
    // 多带一个不会报错（文档：未回传思考内容相关字段不会报错）。
    if (s.reasoning.trim().isNotEmpty) {
      message['reasoning_content'] = s.reasoning;
      wrote = true;
    }
    return wrote;
  }

  void clear() => _items.clear();
}

/// 单轮思考快照
class DbThinkSnapshot {
  final String reasoning;
  final String encrypted;
  const DbThinkSnapshot({required this.reasoning, required this.encrypted});
}

/// 从方舟响应里取出 encrypted_content。
/// 兼容三种落点：delta.encrypted_content、message.encrypted_content、
/// 以及 Responses API 的 output[].encrypted_content。
String dbExtractEncryptedContent(Map<String, dynamic> chunk) {
  final choices = chunk['choices'];
  if (choices is List && choices.isNotEmpty) {
    final c0 = choices.first;
    if (c0 is Map) {
      final d = c0['delta'];
      if (d is Map) {
        final v = d['encrypted_content'];
        if (v is String && v.isNotEmpty) return v;
      }
      final m = c0['message'];
      if (m is Map) {
        final v = m['encrypted_content'];
        if (v is String && v.isNotEmpty) return v;
      }
    }
  }
  final direct = chunk['encrypted_content'];
  if (direct is String && direct.isNotEmpty) return direct;
  final output = chunk['output'];
  if (output is List) {
    final buf = StringBuffer();
    for (final it in output) {
      if (it is! Map) continue;
      if ('${it['type'] ?? ''}' != 'reasoning') continue;
      final v = it['encrypted_content'];
      if (v is String && v.isNotEmpty) buf.write(v);
    }
    if (buf.length > 0) return buf.toString();
  }
  return '';
}

// ------------------------------------------------------------
// SSE 出口封装：一句话决定「直通」还是「平滑」
// ------------------------------------------------------------

/// 思考链下发泵。
///
/// 用法（chat_send.dart）：
///   final pump = DbReasoningPump(model: model, isArkChannel: ..., emit: ...);
///   pump.push(chunk);      // 上游来一段就推一段
///   pump.hurry();          // 正文开始时调用：把积压吐完
///   await pump.finish();   // 发 done 之前必须调用
///
/// 设计要点：
///   · 只有「豆包通道 + summary 型模型」才启用平滑；
///   · 其它情况（DeepSeek、非 summary 豆包模型）完全直通，
///     字节序列与旧实现一模一样，不可能引入回归；
///   · 平滑器自身兜底：异常路径不会让思考链永久卡住（flushAll 强制吐完）。
class DbReasoningPump {
  /// 最终出口（一般是 sse.send('reasoning', ...)）
  final void Function(String delta) emit;

  /// 是否启用平滑
  final bool smoothed;

  DbThinkSmoother? _smoother;
  final StringBuffer _raw = StringBuffer();
  bool _finished = false;

  DbReasoningPump({
    required String model,
    required bool isArkChannel,
    required this.emit,
  }) : smoothed = isArkChannel && dbThinkingProfileOf(model).summaryModel {
    if (smoothed) {
      _smoother = DbThinkSmoother(emit);
    }
  }

  /// 已收到的思考原文总字数（诊断/日志用）
  int get chars => _raw.length;

  /// 上游推入一段思考内容
  void push(String s) {
    if (_finished || s.isEmpty) return;
    _raw.write(s);
    final sm = _smoother;
    if (sm != null) {
      sm.push(s);
    } else {
      emit(s);
    }
  }

  /// 正文已经开始：思考不必再慢慢磨，立即吐完积压
  void hurry() {
    _smoother?.hurry();
  }

  /// 收尾：吐完剩余内容并停止定时器。可安全重复调用。
  Future<void> finish() async {
    if (_finished) return;
    _finished = true;
    final sm = _smoother;
    if (sm != null) await sm.flushAll();
  }

  /// 异常路径：立即终止，不等定时器
  void abort() {
    if (_finished) return;
    _finished = true;
    _smoother?.dispose();
  }
}
