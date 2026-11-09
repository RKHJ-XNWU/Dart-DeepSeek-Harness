// ============================================================
// doubao_intent.dart —— 前缀强制信源路由（抖音百科 / 墨迹天气）
//
// 需求（硬性）：
//   · 消息中出现「抖音百科：」「抖音百科搜索：」「百科：」前缀
//     → 必须调用抖音百科插件（方舟 sources: ["douyin"]），不得拒绝；
//   · 消息中出现「墨迹天气：」「天气：」前缀
//     → 必须调用墨迹天气源（方舟 sources: ["moji"]），不得拒绝；
//   · 判定范围是「消息中的任何位置」，不限于句首；
//   · 前缀本身不属于提问内容，必须从送入模型的正文里剥掉。
//
// 实现取向：
//   前缀只是「触发器」，真正决定走哪条通道的仍是 doubao_wiki.dart 的
//   Responses API（该插件仅 Responses API 支持，Chat Completions 不支持
//   sources，这一点在 doubao_wiki.dart 头部有文档出处）。
//   本文件只做三件事：识别 → 收敛信源 → 产出「必须执行」的系统约束。
// ============================================================

/// 一次请求被识别出的强制意图。
class DbIntent {
  /// 是否被前缀强制（true 时忽略用户对信源开关的关闭状态）
  final bool forced;

  /// 本次必须启用的信源（已按 dbWikiAllowedSources 口径给出）
  final List<String> sources;

  /// 剥掉前缀后的正文（送模型的 content）
  final String cleaned;

  /// 命中的触发词，便于日志与前端提示（如「抖音百科：」）
  final List<String> hits;

  const DbIntent({
    required this.forced,
    required this.sources,
    required this.cleaned,
    required this.hits,
  });

  static const DbIntent none = DbIntent(
    forced: false,
    sources: <String>[],
    cleaned: '',
    hits: <String>[],
  );

  bool get hasWiki => sources.contains('douyin');
  bool get hasWeather => sources.contains('moji');

  /// 是否只要求百科（不含天气）
  bool get wikiOnly => hasWiki && !hasWeather;

  /// 是否只要求天气
  bool get weatherOnly => hasWeather && !hasWiki;

  @override
  String toString() => forced
      ? 'DbIntent(forced, sources=$sources, hits=$hits)'
      : 'DbIntent(none)';
}

/// 触发词表：前缀 → 信源。
///
/// 顺序即优先级：长词必须排在短词前面，否则「抖音百科搜索：」会被
/// 「百科：」先命中，导致只剥离一部分前缀、正文里残留「抖音百科搜索」。
const List<({String prefix, String source, String label})> _dbIntentPrefixes =
    <({String prefix, String source, String label})>[
  // —— 抖音百科（douyin）——
  (prefix: '抖音百科搜索：', source: 'douyin', label: '抖音百科搜索：'),
  (prefix: '抖音百科搜索:', source: 'douyin', label: '抖音百科搜索:'),
  (prefix: '抖音百科：', source: 'douyin', label: '抖音百科：'),
  (prefix: '抖音百科:', source: 'douyin', label: '抖音百科:'),
  (prefix: '百科：', source: 'douyin', label: '百科：'),
  (prefix: '百科:', source: 'douyin', label: '百科:'),
  // —— 墨迹天气（moji）——
  (prefix: '墨迹天气：', source: 'moji', label: '墨迹天气：'),
  (prefix: '墨迹天气:', source: 'moji', label: '墨迹天气:'),
  (prefix: '天气：', source: 'moji', label: '天气：'),
  (prefix: '天气:', source: 'moji', label: '天气:'),
  // —— 繁体 / 全角兼容 ——
  (prefix: '抖音百科：', source: 'douyin', label: '抖音百科：'),
  (prefix: '墨跡天氣：', source: 'moji', label: '墨跡天氣：'),
];

/// 解析用户正文，得出强制意图。
///
/// 不修改入参；不抛异常；任何异常路径都退化为「无强制意图」，
/// 保证聊天主链路不因前缀解析失败而中断。
DbIntent dbParseIntent(String raw) {
  try {
    final text = raw;
    if (text.trim().isEmpty) return DbIntent.none;

    final sources = <String>[];
    final hits = <String>[];
    var cleaned = text;

    // 逐个触发词扫描「任意位置」，命中即剥离。
    // 用 replaceAll 而不是「只剥开头」，因为需求明确要求任意位置生效。
    for (final p in _dbIntentPrefixes) {
      if (!cleaned.contains(p.prefix)) continue;
      if (!sources.contains(p.source)) sources.add(p.source);
      hits.add(p.label);
      // 剥离时连带去掉前缀后紧跟的一个空格，避免正文以空格开头
      cleaned = cleaned.replaceAll(p.prefix, '');
      cleaned = cleaned.replaceAll('${p.prefix} ', '');
    }

    if (sources.isEmpty) {
      return DbIntent(
        forced: false,
        sources: const <String>[],
        cleaned: text,
        hits: const <String>[],
      );
    }

    // 剥离后可能留下首尾空白与多余空行，做一次温和清理。
    cleaned = cleaned
        .replaceAll(RegExp(r'[ \t]+\n'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();

    // 正文被前缀吃空：说明用户只打了触发词。此时不能让空正文进模型，
    // 否则方舟会直接 400（messages 内容为空）。补一句「默认查询」意图。
    if (cleaned.isEmpty) {
      final wantWeather = sources.contains('moji');
      final wantWiki = sources.contains('douyin');
      if (wantWeather && wantWiki) {
        cleaned = '帮我查一下当前天气，并补充相关百科资料。';
      } else if (wantWeather) {
        cleaned = '现在天气怎么样？';
      } else {
        cleaned = '帮我查一下相关资料。';
      }
    }

    return DbIntent(
      forced: true,
      sources: List<String>.unmodifiable(sources),
      cleaned: cleaned,
      hits: List<String>.unmodifiable(hits),
    );
  } catch (_) {
    return DbIntent.none;
  }
}

/// 本次请求生效的信源。
///
/// [forcedSources] 非空时直接采用（前缀强制优先，不受用户开关影响）；
/// 否则回落到豆包设置里的「总闸 × 信源」串联结果。
List<String> dbResolveSources({
  required List<String> forcedSources,
  required List<String> configSources,
}) {
  if (forcedSources.isNotEmpty) return forcedSources;
  return configSources;
}

/// 前缀强制的系统约束：写给模型的「必须执行」条款。
///
/// 三件事必须同时成立，缺一即视为本次前缀未生效：
///   ① 必须真的调用检索（禁止凭记忆作答）；
///   ② 必须标注来源（抖音百科 / 墨迹天气）；
///   ③ 检索失败时如实说明失败原因，禁止改口「我无法查询」。
String dbIntentSystemRule(DbIntent intent, String lang) {
  if (!intent.forced) return '';
  final zh = <String>[
    '【强制检索规则】',
    '用户消息中出现了信源前缀指令（${intent.hits.join('、')}），本次必须执行以下条款：',
    '1. 必须先使用联网内容插件检索，再作答；禁止跳过检索直接凭记忆回答。',
    '2. 回答中必须标明信息来源。',
    '3. 若检索返回为空或失败，必须如实说明「检索无结果／检索失败」及具体原因，'
        '禁止改口为「我无法查询」或「我无法联网」。',
    '4. 禁止向用户索要链接或要求用户自行搜索。',
  ].join('\n');
  final c = (lang).trim().toLowerCase();
  if (c.isEmpty || c == 'ja') return zh;
  if (c == 'zh') return zh;
  if (c == 'en') {
    return <String>[
      '[MANDATORY RETRIEVAL RULE]',
      'The user message carried a source prefix instruction '
          '(${intent.hits.join(', ')}). For this request you MUST:',
      '1. Call the web content plugin BEFORE answering; '
          'answering from memory is forbidden.',
      '2. State the information source in the answer.',
      '3. If retrieval returns nothing or fails, report the empty result or '
          'failure with its actual cause. Never claim you cannot search.',
      '4. Never ask the user for links or ask the user to search manually.',
    ].join('\n');
  }
  // 其余语言沿用中文条款（条款是给模型的行为约束，语义一致性优先），
  // 但补一行语言声明，保证回复语言跟随界面。
  return '$zh\n（回答语言请使用 ${_langName(c)}）';
}

String _langName(String code) {
  switch (code) {
    case 'en':
      return 'English';
    case 'ko':
      return '한국어';
    case 'fr':
      return 'français';
    case 'ru':
      return 'русский';
    case 'zh':
      return '简体中文';
    default:
      return '日本語';
  }
}

/// 前端提示用文案键（日语原文即 i18n key，见 i18n/locales/*-extra.js）
String dbIntentToastKey(DbIntent intent) {
  if (!intent.forced) return '';
  if (intent.hasWiki && intent.hasWeather) return '百科と天気の情報源を強制適用しました';
  if (intent.hasWiki) return '抖音百科を強制適用しました';
  if (intent.hasWeather) return '墨迹天気を強制適用しました';
  return '情報源を強制適用しました';
}
