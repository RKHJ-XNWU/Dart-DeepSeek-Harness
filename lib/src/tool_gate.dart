// ============================================================
// tool_gate.dart —— 工具模式统一闸门（单一可信来源）+ 显式授权通道
//
// 【为什么需要这个文件】
//   修复的严重 Bug：工具模式（Tool Mode）关闭后，豆包仍然能调用工具。
//   旧实现里存在多处「自动打开」通道，绕过了用户的开关语义：
//     1) 前端 deepseek-chat.js 发送体：
//          enableTools: state.enableTools || window.__dscDeviceIntent(content)
//     2) 后端 chat_send.dart：
//          if (!useTools && dsIsDeviceIntent(content)) useTools = true;
//   只要消息里出现「打开应用 / 点击 / 截图 / adb」等词，开关关着也照跑，
//   用户看到的却是「工具模式已关闭」——这是状态与执行层脱节的典型表现。
//
// 【本文件的做法】
//   · 把「当前会话的工具模式」收敛到服务端唯一位置（_modeBySession）；
//     前端传的 enableTools / toolModeUI 只是「同步输入」，不是执行的充分条件。
//   · 【本次加固】引入「请求租约」（request scope）：
//     只有处在一个正在处理的聊天请求生命周期内，工具才可能被放行。
//     请求结束、或租约过期后，任何残留的绑定会话都不再具备执行资格。
//     这堵死了「上一个请求未解绑 → 后续任意调用沿用旧 ON 状态」的泄漏路径。
//   · 每次真正执行工具前，都必须调用 [DsToolGate.check]；
//     未通过就直接返回拒绝文本，绝不进入工具实现，绝不产生副作用。
//   · 用户显式点击按钮（墨迹天气 / 头条图文）触发的插件调用，
//     走联网内容插件（web_search），不属于 function calling，
//     因此必须先把工具模式置为 OFF，再只开该信源。
//   · 工具执行是「两层校验」（dsSafeExecTool → executeDsTool）。
//     两层属于同一次调用，内层必须走 [DsToolGate.checkInner]，
//     否则一次性授权会被外层消费掉、内层再判一次就变成「拒绝」。
// ============================================================

import 'globals.dart';

/// 一次性授权：谁、允许什么、什么时候过期、还能用几次。
class DsToolGrant {
  final String sessionId;

  /// 白名单：只允许这些工具名/插件名。禁止 '*' 通配。
  final Set<String> allow;

  /// 授权来源（moji / toutiao / 其它显式按钮 id），仅用于日志与自检
  final String kind;

  final DateTime expireAt;

  /// 剩余可用次数：用户点一次按钮，只够触发一次插件调用
  int remainingUses;

  DsToolGrant({
    required this.sessionId,
    required this.allow,
    required this.kind,
    required this.expireAt,
    required this.remainingUses,
  });

  bool get alive => remainingUses > 0 && DateTime.now().isBefore(expireAt);

  @override
  String toString() =>
      'DsToolGrant(kind=$kind, allow=${allow.join(",")}, '
      'uses=$remainingUses, expire=${expireAt.toIso8601String()})';
}

/// 工具执行闸门。全进程单例（本 App 是单用户本地服务，无需多租户隔离）。
class DsToolGate {
  DsToolGate._();

  /// 会话 → 工具模式开关。这是执行的唯一可信来源。
  static final Map<String, bool> _modeBySession = <String, bool>{};

  /// 一次性显式授权（按钮触发）
  static final List<DsToolGrant> _grants = <DsToolGrant>[];

  /// 当前正在处理工具调用的会话（由 chat_send 在执行前绑定）
  static String _boundSession = '';

  /// 被拦截次数与最近一次拦截记录（供自检与告警日志使用）
  static int deniedCount = 0;
  static String lastDenied = '';
  static String lastDeniedReason = '';

  /// ------------------------------------------------------------
  /// 【请求租约】工具执行只允许发生在「正在处理中的聊天请求」里。
  ///
  /// 这是一个非常重要的 fail-closed 设计：
  ///   · 请求到期 / 被显式结束后，_activeUntilMs 归零；
  ///   · 此时 check() 一律拒绝，哪怕 _boundSession 还残留着旧值；
  ///   · 默认租约 30 分钟，每次放行都会续租（长任务不会中途被掐）。
  /// ------------------------------------------------------------
  static int _activeUntilMs = 0;
  static String _activeSession = '';
  static bool _activeToolsOn = false;
  static int _activeSeq = 0;
  static const int _defaultLeaseMs = 30 * 60 * 1000;

  /// 启动一个请求租约。返回序号，可用于 [endRequest] 精确结束。
  static int beginRequest(String sessionId, bool toolsOn,
      {int ttlMs = _defaultLeaseMs}) {
    _activeSeq++;
    _activeSession = sessionId;
    _activeToolsOn = toolsOn;
    _activeUntilMs = DateTime.now().millisecondsSinceEpoch + ttlMs;
    logp('🔓 [TOOL-GATE] リクエスト開始: session=$sessionId '
        'tools=${toolsOn ? "ON" : "OFF"} lease=${ttlMs}ms');
    return _activeSeq;
  }

  /// 结束请求租约。传入序号时只有「当前请求」才能结束，避免并发互相踩踏。
  static void endRequest([int? seq]) {
    if (seq != null && seq != _activeSeq) return;
    if (_activeUntilMs == 0) return;
    _activeUntilMs = 0;
    _activeSession = '';
    _activeToolsOn = false;
    logp('🔒 [TOOL-GATE] リクエスト終了（以降のツール実行は一律拒否）');
  }

  /// 续租：长时间工具调用期间保持租约有效。
  static void touchRequest() {
    if (_activeUntilMs > 0) {
      _activeUntilMs = DateTime.now().millisecondsSinceEpoch + _defaultLeaseMs;
    }
  }

  /// 是否存在有效的请求租约。
  static bool get hasActiveRequest =>
      _activeUntilMs > 0 &&
      DateTime.now().millisecondsSinceEpoch < _activeUntilMs;

  /// 当前请求是否声明了工具模式（仅用于自检/日志，放行仍以 modeOf 为准）。
  static bool get activeToolsOn => hasActiveRequest && _activeToolsOn;

  /// 【重复消费防护】外层刚放行过的一次调用签名（会话|工具名）。
  static String _lastPassSig = '';
  static int _lastPassAtMs = 0;
  static const int _reentryWindowMs = 5000;

  /// 【入口一】同步模式：每个聊天请求进来时调用一次。
  /// 服务端以这里为准，前端只能通过这个入口改变它。
  static void syncMode(String sessionId, bool enabled) {
    if (sessionId.isEmpty) return;
    final old = _modeBySession[sessionId];
    _modeBySession[sessionId] = enabled;
    if (old != enabled) {
      logp('🔐 [TOOL-GATE] 会话 $sessionId 的工具模式: '
          '${old == null ? "(未设置)" : (old ? "ON" : "OFF")} → ${enabled ? "ON" : "OFF"}');
    }
  }

  /// 读取某会话的工具模式（未记录即视为关闭：默认拒绝，最安全）
  static bool modeOf(String sessionId) => _modeBySession[sessionId] == true;

  /// 【入口二】执行前绑定当前会话，工具执行结束后解绑。
  static void bind(String sessionId) {
    _boundSession = sessionId;
  }

  static void unbind() {
    _boundSession = '';
  }

  static String get boundSession => _boundSession;

  /// 【入口三】签发一次性授权（用户显式点击按钮时）。
  static String issueGrant({
    required String sessionId,
    required String kind,
    required List<String> allow,
    int ttlMs = 120000,
    int uses = 1,
  }) {
    final set = allow
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && e != '*')
        .toSet();
    if (sessionId.isEmpty || set.isEmpty) return '';
    final token = 'g_${DateTime.now().microsecondsSinceEpoch}_${set.length}';
    _grants.add(DsToolGrant(
      sessionId: sessionId,
      allow: set,
      kind: kind,
      expireAt: DateTime.now().add(Duration(milliseconds: ttlMs)),
      remainingUses: uses,
    ));
    logp('🎫 [TOOL-GATE] 明示授权を発行: kind=$kind allow=${set.join(",")} '
        'uses=$uses token=$token');
    _sweep();
    return token;
  }

  static void _sweep() {
    _grants.removeWhere((g) => !g.alive);
  }

  /// 记录「这一次调用已经被放行」，供内层 [checkInner] 复用。
  static void _markPass(String sid, String toolName) {
    _lastPassSig = '$sid|$toolName';
    _lastPassAtMs = DateTime.now().millisecondsSinceEpoch;
    touchRequest();
  }

  static bool _deny(String tool, String sid, String reason) {
    deniedCount++;
    lastDenied = DateTime.now().toIso8601String();
    lastDeniedReason = reason;
    logp('⛔ [TOOL-GATE] ツール実行を拒否: tool=$tool '
        'session=${sid.isEmpty ? "(未绑定)" : sid} reason=$reason');
    return false;
  }

  /// 【核心】执行前校验 + 消费一次性授权。
  ///
  /// 返回 true 才允许真正执行工具。任何异常一律拒绝（fail-closed）。
  static bool check(String toolName, {String? sessionId}) {
    try {
      _sweep();

      // ★ 第一道：必须存在有效的请求租约。
      //   没有正在处理的聊天请求 = 没有用户授权上下文 = 一律拒绝。
      if (!hasActiveRequest) {
        return _deny(toolName, sessionId ?? _boundSession, 'no-active-request');
      }

      final sid = (sessionId ?? '').isNotEmpty
          ? sessionId!
          : (_activeSession.isNotEmpty ? _activeSession : _boundSession);

      // 通道一：正常工具模式（服务端权威状态）
      if (sid.isNotEmpty && modeOf(sid)) {
        _markPass(sid, toolName);
        return true;
      }

      // 通道二：用户显式按钮触发的一次性授权（白名单 + 一次性）
      for (final g in _grants) {
        if (g.sessionId != sid) continue;
        if (!g.allow.contains(toolName)) continue;
        if (!g.alive) continue;
        g.remainingUses -= 1;
        _markPass(sid, toolName);
        logp('✅ [TOOL-GATE] 明示授权で実行を許可: $toolName（kind=${g.kind}）');
        return true;
      }

      // 其余一律拒绝
      return _deny(toolName, sid,
          modeOf(sid) ? 'no-grant' : 'tool-mode-off');
    } catch (e) {
      deniedCount++;
      lastDeniedReason = 'exception';
      logp('⛔ [TOOL-GATE] 判定中に例外 → 拒否（fail-closed）: $e');
      return false;
    }
  }

  /// 【内层校验】工具执行器的第二次校验。
  static bool checkInner(String toolName, {String? sessionId}) {
    try {
      final sid = (sessionId ?? '').isNotEmpty
          ? sessionId!
          : (_activeSession.isNotEmpty ? _activeSession : _boundSession);
      final sig = '$sid|$toolName';
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (_lastPassSig == sig && (nowMs - _lastPassAtMs) <= _reentryWindowMs) {
        return true;
      }
      return check(toolName, sessionId: sessionId);
    } catch (e) {
      deniedCount++;
      lastDeniedReason = 'exception-inner';
      logp('⛔ [TOOL-GATE] 内层判定中に例外 → 拒否（fail-closed）: $e');
      return false;
    }
  }

  /// 拒绝时返回给模型的文本：说明语义，并提示用户如何重新开启。
  static String denyText(String toolName) =>
      '🚫 工具模式已关闭，工具「$toolName」未被执行。'
      '（执行层已拦截 · 无任何副作用。只有用户开启工具模式后才会执行）';

  /// 自检：前端 / 运维可通过该结构确认闸门状态
  static Map<String, dynamic> diag() => <String, dynamic>{
        'boundSession': _boundSession,
        'mode': _boundSession.isEmpty ? null : modeOf(_boundSession),
        'activeRequest': hasActiveRequest,
        'activeSession': _activeSession,
        'activeToolsOn': _activeToolsOn,
        'sessions': _modeBySession.length,
        'grants': _grants
            .where((g) => g.alive)
            .map((g) => {
                  'kind': g.kind,
                  'session': g.sessionId,
                  'allow': g.allow.toList(),
                  'uses': g.remainingUses,
                  'expireAt': g.expireAt.toIso8601String(),
                })
            .toList(),
        'deniedCount': deniedCount,
        'lastDenied': lastDenied,
        'lastDeniedReason': lastDeniedReason,
        'lastPassSig': _lastPassSig,
        'lastPassAtMs': _lastPassAtMs,
      };
}
