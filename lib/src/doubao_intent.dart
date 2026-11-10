// ============================================================
// doubao_intent.dart —— 【已停用 / DISABLED】
//
// 原「前缀强制信源路由（████百科 / 墨迹天气）」逻辑已整体关闭。
//
// 本文件仅保留对外 API 的形状（类 / 字段 / 函数签名 / 常量），
// 以保证 doubao_wiki.dart、聊天主链路、i18n 提示等调用方无需改动。
//
// 停用语义：
//   · dbParseIntent     → 恒返回 forced=false，正文原样透传，永不高亮前缀
//   · dbResolveSources  → 恒返回 configSources（用户开关完全生效）
//   · dbIntentSystemRule→ 恒返回 ''（不注入任何强制检索条款）
//   · dbIntentToastKey  → 恒返回 ''（前端不弹"已强制应用"提示）
//
// 回滚：用原文件覆盖本文件即可，无需改动其它任何文件。
// ============================================================

/// 一次请求被识别出的强制意图。
/// 【已停用】结构保留，但 forced 恒为 false。
class DbIntent {
  /// 是否被前缀强制（停用后恒为 false）
  final bool forced;

  /// 本次必须启用的信源（停用后恒为空）
  final List<String> sources;

  /// 剥掉前缀后的正文（停用后即原始正文）
  final String cleaned;

  /// 命中的触发词（停用后恒为空）
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

/// 解析用户正文，得出强制意图。
/// 【已停用】恒返回 forced=false，正文原样透传，不剥离任何前缀。
DbIntent dbParseIntent(String raw) {
  return DbIntent(
    forced: false,
    sources: const <String>[],
    cleaned: raw,
    hits: const <String>[],
  );
}

/// 本次请求生效的信源。
/// 【已停用】强制信源不再生效，完全回落到配置结果（用户开关生效）。
List<String> dbResolveSources({
  required List<String> forcedSources,
  required List<String> configSources,
}) {
  return configSources;
}

/// 前缀强制的系统约束。
/// 【已停用】不注入任何强制条款，恒返回空串。
String dbIntentSystemRule(DbIntent intent, String lang) => '';

/// 前端提示用文案键。
/// 【已停用】不弹强制提示，恒返回空串。
String dbIntentToastKey(DbIntent intent) => '';