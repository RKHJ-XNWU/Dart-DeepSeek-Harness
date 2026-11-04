// ============================================================
// ds_usage.dart —— 每条回复的真实 token 用量（provider billing 口径）
// 100% 对齐 Go 版 ds-token-usage.go，绝不估算
// ============================================================

import 'dart:convert';

import 'globals.dart';

class DsTokenUsage {
  int promptTokens;
  int promptCacheHitTokens;
  int promptCacheMissTokens;
  int completionTokens;
  int reasoningTokens;
  int totalTokens;
  int apiCalls;

  DsTokenUsage({
    this.promptTokens = 0,
    this.promptCacheHitTokens = 0,
    this.promptCacheMissTokens = 0,
    this.completionTokens = 0,
    this.reasoningTokens = 0,
    this.totalTokens = 0,
    this.apiCalls = 0,
  });

  DsTokenUsage clone() => DsTokenUsage(
        promptTokens: promptTokens,
        promptCacheHitTokens: promptCacheHitTokens,
        promptCacheMissTokens: promptCacheMissTokens,
        completionTokens: completionTokens,
        reasoningTokens: reasoningTokens,
        totalTokens: totalTokens,
        apiCalls: apiCalls,
      );

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'promptTokens': promptTokens,
      'promptCacheHitTokens': promptCacheHitTokens,
      'promptCacheMissTokens': promptCacheMissTokens,
      'completionTokens': completionTokens,
      'totalTokens': totalTokens,
      'apiCalls': apiCalls,
    };
    if (reasoningTokens != 0) m['reasoningTokens'] = reasoningTokens;
    return m;
  }

  static DsTokenUsage fromJson(Map<String, dynamic> m) => DsTokenUsage(
        promptTokens: intArgDefault(m, 'promptTokens', 0),
        promptCacheHitTokens: intArgDefault(m, 'promptCacheHitTokens', 0),
        promptCacheMissTokens: intArgDefault(m, 'promptCacheMissTokens', 0),
        completionTokens: intArgDefault(m, 'completionTokens', 0),
        reasoningTokens: intArgDefault(m, 'reasoningTokens', 0),
        totalTokens: intArgDefault(m, 'totalTokens', 0),
        apiCalls: intArgDefault(m, 'apiCalls', 0),
      );
}

/// API 响应里的原始 usage（DeepSeek 官方字段名）
class RawDsUsage {
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;
  final int promptCacheHitTokens;
  final int promptCacheMissTokens;
  final int cachedTokens; // prompt_tokens_details.cached_tokens
  final int reasoningTokens; // completion_tokens_details.reasoning_tokens

  const RawDsUsage({
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.totalTokens = 0,
    this.promptCacheHitTokens = 0,
    this.promptCacheMissTokens = 0,
    this.cachedTokens = 0,
    this.reasoningTokens = 0,
  });

  static RawDsUsage? fromJson(dynamic v) {
    if (v == null || v is! Map) return null;
    final m = asMap(v);
    final pd = asMap(m['prompt_tokens_details']);
    final cd = asMap(m['completion_tokens_details']);
    return RawDsUsage(
      promptTokens: intArgDefault(m, 'prompt_tokens', 0),
      completionTokens: intArgDefault(m, 'completion_tokens', 0),
      totalTokens: intArgDefault(m, 'total_tokens', 0),
      promptCacheHitTokens: intArgDefault(m, 'prompt_cache_hit_tokens', 0),
      promptCacheMissTokens: intArgDefault(m, 'prompt_cache_miss_tokens', 0),
      cachedTokens: intArgDefault(pd, 'cached_tokens', 0),
      reasoningTokens: intArgDefault(cd, 'reasoning_tokens', 0),
    );
  }
}

class DsUsageAcc {
  bool _used = false;
  final DsTokenUsage _total = DsTokenUsage();

  bool get used => _used;

  void addRaw(RawDsUsage? r) {
    if (r == null) return;
    // ① 命中：公式フィールドを優先し、無ければ prompt_tokens_details.cached_tokens へ回落
    var hit = r.promptCacheHitTokens;
    if (hit == 0) hit = r.cachedTokens;
    var miss = r.promptCacheMissTokens;
    // ② 入力総量：prompt_tokens が欠けていれば「命中 + 未命中」で補う
    var prompt = r.promptTokens;
    if (prompt == 0) prompt = hit + miss;
    if (hit < 0) hit = 0;
    if (miss < 0) miss = 0;
    if (prompt < 0) prompt = 0;
    // ③ 不変条件 hit + miss == prompt を強制する。
    //    未命中が 0 や欠損で返る実装があり、そのまま加算すると過少計上になる
    //    （単価は 未命中 > 出力 > 命中 の順に高く、取りこぼしの影響が最も大きい）
    if (hit > prompt) hit = prompt;
    if (prompt > 0) {
      miss = prompt - hit;
    } else if (miss > 0) {
      prompt = hit + miss;
    }
    // ④ 出力：completion に reasoning が含まれない実装があるため大きい方を採る
    var outTok = r.completionTokens;
    if (outTok < r.reasoningTokens) outTok = r.reasoningTokens;
    var total = r.totalTokens;
    if (total < prompt + outTok) total = prompt + outTok;

    _used = true;
    _total.promptTokens += prompt;
    _total.promptCacheHitTokens += hit;
    _total.promptCacheMissTokens += miss;
    _total.completionTokens += outTok;
    _total.reasoningTokens += r.reasoningTokens;
    _total.totalTokens += total;
    _total.apiCalls += 1;
  }

  void addUsage(DsTokenUsage? u) {
    if (u == null) return;
    _used = true;
    _total.promptTokens += u.promptTokens;
    _total.promptCacheHitTokens += u.promptCacheHitTokens;
    _total.promptCacheMissTokens += u.promptCacheMissTokens;
    _total.completionTokens += u.completionTokens;
    _total.reasoningTokens += u.reasoningTokens;
    _total.totalTokens += u.totalTokens;
    final calls = u.apiCalls <= 0 ? 1 : u.apiCalls;
    _total.apiCalls += calls;
  }

  /// 一次 API 调用都没发生（或都没拿到 usage）时返回 null —— 宁可不显示，绝不编造
  DsTokenUsage? snapshot() {
    if (!_used) return null;
    final u = _total.clone();
    if (u.totalTokens == 0) u.totalTokens = u.promptTokens + u.completionTokens;
    return u;
  }
}

DsTokenUsage? dsMergeUsage(DsTokenUsage? base, DsTokenUsage? extra) {
  if (base == null) return extra?.clone();
  if (extra == null) return base.clone();
  final acc = DsUsageAcc();
  acc.addUsage(base);
  acc.addUsage(extra);
  return acc.snapshot();
}

/// 会话文件单行字段编码（不含 '|'）
String dsEncodeUsageField(DsTokenUsage? u) {
  if (u == null) return '';
  try {
    return escDs(jsonEncode(u.toJson()));
  } catch (_) {
    return '';
  }
}

/// 会话行格式：#M|id|role|content|createdAt|attachments|reasoning|usage
DsTokenUsage? dsParseUsageField(List<String> parts) {
  if (parts.length < 7) return null;
  final raw = unescDs(parts[6]);
  if (raw.isEmpty) return null;
  DsTokenUsage u;
  try {
    u = DsTokenUsage.fromJson(asMap(jsonDecode(raw)));
  } catch (_) {
    return null;
  }
  if (u.totalTokens == 0 && u.promptTokens == 0 && u.completionTokens == 0) {
    return null;
  }
  if (u.totalTokens == 0) u.totalTokens = u.promptTokens + u.completionTokens;
  if (u.apiCalls <= 0) u.apiCalls = 1;
  return u;
}

Map<String, dynamic> dsUsageStreamOptions() => {'include_usage': true};
