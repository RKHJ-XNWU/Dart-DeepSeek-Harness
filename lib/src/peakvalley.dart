// ============================================================
// peakvalley.dart —— 峰谷提醒（DeepSeek 官方峰谷定价时段）
// 100% 对齐 Go 版 peakvalley.go：
//   阶段判定 / 时段换算 / 模板渲染 / 7 种推送渠道 / 服务端定时调度
//
// 唯一实现差异（如实说明）：Go 用 time.LoadLocation + 内嵌 tzdata 处理 IANA 时区；
// dart:io 的 DateTime 不提供 IANA 数据库，这里内置了本项目支持的 11 个时区的
// 固定偏移 + 欧盟/美国夏令时规则（覆盖 pvTimezones 全集），行为等价。
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'globals.dart';
import 'httpsrv.dart';
import 'sha256.dart';

const String PVPeak = 'peak';
const String PVValley = 'valley';
const int pvMaxBodyBytes = 1 << 20;
const int pvFiredKeep = 2000;
const int pvTickSeconds = 30;
const int pvCatchupMin = 10;

String get pvDir => '$DATA_DIR/peakvalley';
String get pvConfigPath => '$pvDir/config.json';
String get pvFiredPath => '$pvDir/fired.json';

// ------------------------------------------------------------
// 时区
// ------------------------------------------------------------
const List<String> pvTimezones = [
  'Asia/Shanghai', 'Asia/Hong_Kong', 'Asia/Taipei', 'Asia/Tokyo',
  'Asia/Singapore', 'Asia/Seoul', 'UTC',
  'Europe/London', 'Europe/Paris', 'America/New_York', 'America/Los_Angeles',
];

DateTime _nthSunday(int year, int month, int n) {
  final first = DateTime.utc(year, month, 1);
  final firstWeekday = first.weekday % 7; // Sunday=0
  var day = 1 + ((7 - firstWeekday) % 7) + (n - 1) * 7;
  return DateTime.utc(year, month, day);
}

DateTime _lastSunday(int year, int month) {
  final lastDay = DateTime.utc(year, month + 1, 0);
  final back = lastDay.weekday % 7;
  return DateTime.utc(year, month, lastDay.day - back);
}

bool _euDst(DateTime utc) {
  final start = _lastSunday(utc.year, 3).add(const Duration(hours: 1));
  final end = _lastSunday(utc.year, 10).add(const Duration(hours: 1));
  return !utc.isBefore(start) && utc.isBefore(end);
}

bool _usDst(DateTime utc) {
  final start = _nthSunday(utc.year, 3, 2).add(const Duration(hours: 7));
  final end = _nthSunday(utc.year, 11, 1).add(const Duration(hours: 6));
  return !utc.isBefore(start) && utc.isBefore(end);
}

bool pvValidTimezone(String tz) => pvTimezones.contains(tz);

int tzOffsetMinutes(String tz, DateTime utcAny) {
  final utc = utcAny.toUtc();
  switch (tz) {
    case 'Asia/Shanghai':
    case 'Asia/Hong_Kong':
    case 'Asia/Taipei':
    case 'Asia/Singapore':
      return 480;
    case 'Asia/Tokyo':
    case 'Asia/Seoul':
      return 540;
    case 'Europe/London':
      return _euDst(utc) ? 60 : 0;
    case 'Europe/Paris':
      return _euDst(utc) ? 120 : 60;
    case 'America/New_York':
      return _usDst(utc) ? -240 : -300;
    case 'America/Los_Angeles':
      return _usDst(utc) ? -420 : -480;
    case 'UTC':
      return 0;
    default:
      return 480; // 默认 Asia/Shanghai
  }
}

/// 把瞬时时间换成「当地墙钟时间」（返回 UTC DateTime，字段即当地时间）
DateTime pvWall(DateTime t, String tz) {
  final utc = t.toUtc();
  return utc.add(Duration(minutes: tzOffsetMinutes(tz, utc)));
}

/// 由当地墙钟时间构造瞬时时间
DateTime pvZonedUTC(int y, int m, int d, int hh, int mm, String tz) {
  final guess = DateTime.utc(y, m, d, hh, mm);
  final off = tzOffsetMinutes(tz, guess);
  return guess.subtract(Duration(minutes: off));
}

// ------------------------------------------------------------
// 数据结构
// ------------------------------------------------------------
class PVWindow {
  String start;
  String end;
  PVWindow(this.start, this.end);

  Map<String, dynamic> toJson() => {'start': start, 'end': end};
  static PVWindow fromJson(Map<String, dynamic> m) =>
      PVWindow(mStr(m, 'start'), mStr(m, 'end'));
}

class PVVisual {
  bool enabled;
  String peakColor;
  String valleyColor;
  int width;
  String animation;
  double breathingSpeed;
  int glow;
  double opacity;
  String glowDirection;
  bool flow;
  double flowSpeed;

  PVVisual({
    this.enabled = true,
    this.peakColor = '#f97316',
    this.valleyColor = '#38bdf8',
    this.width = 3,
    this.animation = 'breathing',
    this.breathingSpeed = 2.6,
    this.glow = 22,
    this.opacity = 0.4,
    this.glowDirection = 'out',
    this.flow = false,
    this.flowSpeed = 6,
  });

  PVVisual copy() => PVVisual(
        enabled: enabled,
        peakColor: peakColor,
        valleyColor: valleyColor,
        width: width,
        animation: animation,
        breathingSpeed: breathingSpeed,
        glow: glow,
        opacity: opacity,
        glowDirection: glowDirection,
        flow: flow,
        flowSpeed: flowSpeed,
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'peakColor': peakColor,
        'valleyColor': valleyColor,
        'width': width,
        'animation': animation,
        'breathingSpeed': breathingSpeed,
        'glow': glow,
        'opacity': opacity,
        'glowDirection': glowDirection,
        'flow': flow,
        'flowSpeed': flowSpeed,
      };

  static PVVisual fromJson(Map<String, dynamic> m, PVVisual def) {
    double dbl(String k, double fallback) {
      final v = m[k];
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v) ?? fallback;
      return fallback;
    }

    return PVVisual(
      enabled: mBool(m, 'enabled', def.enabled),
      peakColor: mStr(m, 'peakColor', def.peakColor),
      valleyColor: mStr(m, 'valleyColor', def.valleyColor),
      width: intArgDefault(m, 'width', def.width),
      animation: mStr(m, 'animation', def.animation),
      breathingSpeed: dbl('breathingSpeed', def.breathingSpeed),
      glow: intArgDefault(m, 'glow', def.glow),
      opacity: dbl('opacity', def.opacity),
      glowDirection: mStr(m, 'glowDirection', def.glowDirection),
      flow: mBool(m, 'flow', def.flow),
      flowSpeed: dbl('flowSpeed', def.flowSpeed),
    );
  }
}

class PVBadgePos {
  String corner;
  int x;
  int y;
  PVBadgePos(this.corner, this.x, this.y);

  PVBadgePos copy() => PVBadgePos(corner, x, y);

  Map<String, dynamic> toJson() => {'corner': corner, 'x': x, 'y': y};

  static PVBadgePos fromJson(Map<String, dynamic> m, PVBadgePos def) =>
      PVBadgePos(mStr(m, 'corner', def.corner), intArgDefault(m, 'x', def.x),
          intArgDefault(m, 'y', def.y));
}

class PVBadgeCfg {
  bool enabled;
  PVBadgePos desktop;
  PVBadgePos mobile;
  PVBadgeCfg(this.enabled, this.desktop, this.mobile);

  PVBadgeCfg copy() => PVBadgeCfg(enabled, desktop.copy(), mobile.copy());

  Map<String, dynamic> toJson() =>
      {'enabled': enabled, 'desktop': desktop.toJson(), 'mobile': mobile.toJson()};
}

class PVLocalNotify {
  bool enabled;
  bool onTransition;
  bool onReminder;
  PVLocalNotify(this.enabled, this.onTransition, this.onReminder);

  PVLocalNotify copy() => PVLocalNotify(enabled, onTransition, onReminder);

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'onTransition': onTransition,
        'onReminder': onReminder,
      };
}

class PVChannelResult {
  final String channel;
  final String name;
  final bool ok;
  final String error;
  final int status;
  PVChannelResult({
    required this.channel,
    required this.name,
    required this.ok,
    this.error = '',
    this.status = 0,
  });

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'channel': channel,
      'name': name,
      'ok': ok,
    };
    if (error.isNotEmpty) m['error'] = error;
    if (status != 0) m['status'] = status;
    return m;
  }
}

class PVPushResult {
  bool ok;
  int sent;
  int total;
  String error;
  List<PVChannelResult> details;
  PVPushResult({
    this.ok = false,
    this.sent = 0,
    this.total = 0,
    this.error = '',
    List<PVChannelResult>? details,
  }) : details = details ?? [];

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'ok': ok,
      'sent': sent,
      'total': total,
    };
    if (error.isNotEmpty) m['error'] = error;
    if (details.isNotEmpty) m['details'] = details.map((d) => d.toJson()).toList();
    return m;
  }

  static PVPushResult fromJson(Map<String, dynamic> m) => PVPushResult(
        ok: mBool(m, 'ok'),
        sent: intArgDefault(m, 'sent', 0),
        total: intArgDefault(m, 'total', 0),
        error: mStr(m, 'error'),
        details: asList(m['details'])
            .map((e) {
              final d = asMap(e);
              return PVChannelResult(
                channel: mStr(d, 'channel'),
                name: mStr(d, 'name'),
                ok: mBool(d, 'ok'),
                error: mStr(d, 'error'),
                status: intArgDefault(d, 'status', 0),
              );
            })
            .toList(),
      );
}

class PVReminder {
  bool enabled;
  int leadMinutes;
  String channel;
  String times;
  String title;
  String content;
  String lastFiredAt;
  PVPushResult? lastResult;

  PVReminder({
    this.enabled = false,
    this.leadMinutes = 0,
    this.channel = 'all',
    this.times = '',
    this.title = '',
    this.content = '',
    this.lastFiredAt = '',
    this.lastResult,
  });

  PVReminder copy() => PVReminder(
        enabled: enabled,
        leadMinutes: leadMinutes,
        channel: channel,
        times: times,
        title: title,
        content: content,
        lastFiredAt: lastFiredAt,
        lastResult: lastResult,
      );

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'enabled': enabled,
      'leadMinutes': leadMinutes,
      'channel': channel,
      'times': times,
      'title': title,
      'content': content,
    };
    if (lastFiredAt.isNotEmpty) m['lastFiredAt'] = lastFiredAt;
    if (lastResult != null) m['lastResult'] = lastResult!.toJson();
    return m;
  }

  static PVReminder fromJson(Map<String, dynamic> m, PVReminder def) {
    final r = PVReminder(
      enabled: mBool(m, 'enabled', def.enabled),
      leadMinutes: intArgDefault(m, 'leadMinutes', def.leadMinutes),
      channel: mStr(m, 'channel', def.channel),
      times: mStr(m, 'times', def.times),
      title: mStr(m, 'title', def.title),
      content: mStr(m, 'content', def.content),
      lastFiredAt: mStr(m, 'lastFiredAt', def.lastFiredAt),
    );
    final lr = m['lastResult'];
    if (lr is Map) r.lastResult = PVPushResult.fromJson(asMap(lr));
    return r;
  }
}

class PVReminders {
  PVReminder peak;
  PVReminder valley;
  PVReminders(this.peak, this.valley);

  PVReminders copy() => PVReminders(peak.copy(), valley.copy());

  Map<String, dynamic> toJson() =>
      {'peak': peak.toJson(), 'valley': valley.toJson()};
}

class PVChannel {
  String id;
  String type;
  String name;
  bool enabled;
  String key;
  String server;
  String chatId;
  String secret;
  String method;
  String body;

  PVChannel({
    required this.id,
    required this.type,
    this.name = '',
    this.enabled = false,
    this.key = '',
    this.server = '',
    this.chatId = '',
    this.secret = '',
    this.method = '',
    this.body = '',
  });

  PVChannel copy() => PVChannel(
        id: id,
        type: type,
        name: name,
        enabled: enabled,
        key: key,
        server: server,
        chatId: chatId,
        secret: secret,
        method: method,
        body: body,
      );

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'id': id,
      'type': type,
      'name': name,
      'enabled': enabled,
    };
    if (key.isNotEmpty) m['key'] = key;
    if (server.isNotEmpty) m['server'] = server;
    if (chatId.isNotEmpty) m['chatId'] = chatId;
    if (secret.isNotEmpty) m['secret'] = secret;
    if (method.isNotEmpty) m['method'] = method;
    if (body.isNotEmpty) m['body'] = body;
    return m;
  }

  static PVChannel fromJson(Map<String, dynamic> m) => PVChannel(
        id: mStr(m, 'id'),
        type: mStr(m, 'type'),
        name: mStr(m, 'name'),
        enabled: mBool(m, 'enabled'),
        key: mStr(m, 'key'),
        server: mStr(m, 'server'),
        chatId: mStr(m, 'chatId'),
        secret: mStr(m, 'secret'),
        method: mStr(m, 'method'),
        body: mStr(m, 'body'),
      );
}

class PVConfig {
  int version;
  bool enabled;
  String scope;
  String timezone;
  List<PVWindow> windows;
  String override;
  int pollSeconds;
  PVVisual edge;
  PVVisual composer;
  PVBadgeCfg badge;
  PVLocalNotify localNotify;
  PVReminders reminders;
  List<PVChannel> channels;

  PVConfig({
    required this.version,
    required this.enabled,
    required this.scope,
    required this.timezone,
    required this.windows,
    required this.override,
    required this.pollSeconds,
    required this.edge,
    required this.composer,
    required this.badge,
    required this.localNotify,
    required this.reminders,
    required this.channels,
  });

  PVConfig copy() => PVConfig(
        version: version,
        enabled: enabled,
        scope: scope,
        timezone: timezone,
        windows: windows.map((w) => PVWindow(w.start, w.end)).toList(),
        override: override,
        pollSeconds: pollSeconds,
        edge: edge.copy(),
        composer: composer.copy(),
        badge: badge.copy(),
        localNotify: localNotify.copy(),
        reminders: reminders.copy(),
        channels: channels.map((c) => c.copy()).toList(),
      );

  Map<String, dynamic> toJson() => {
        'version': version,
        'enabled': enabled,
        'scope': scope,
        'timezone': timezone,
        'windows': windows.map((w) => w.toJson()).toList(),
        'override': override,
        'pollSeconds': pollSeconds,
        'edge': edge.toJson(),
        'composer': composer.toJson(),
        'badge': badge.toJson(),
        'localNotify': localNotify.toJson(),
        'reminders': reminders.toJson(),
        'channels': channels.map((c) => c.toJson()).toList(),
      };
}

final List<PVWindow> _officialWindows = [
  PVWindow('09:00', '12:00'),
  PVWindow('14:00', '18:00'),
];

const Map<String, Map<String, String>> pvPhaseText = {
  PVPeak: {'zh': '高峰期', 'en': 'Peak hours'},
  PVValley: {'zh': '低峰期', 'en': 'Valley hours'},
};

class _ChannelTypeMeta {
  final String type;
  final String name;
  final String desc;
  final List<String> fields;
  final bool needChatId;
  const _ChannelTypeMeta(this.type, this.name, this.desc, this.fields,
      [this.needChatId = false]);

  Map<String, dynamic> toJson() => {
        'type': type,
        'name': name,
        'desc': desc,
        'fields': fields,
        'needChatId': needChatId,
      };
}

const List<_ChannelTypeMeta> _channelTypes = [
  _ChannelTypeMeta('serverchan', 'Server酱', '微信推送，填写 SendKey', ['key']),
  _ChannelTypeMeta('bark', 'Bark', 'iOS プッシュ。DeviceKey を入力。自前サーバーの指定は任意',
      ['key', 'server']),
  _ChannelTypeMeta('dingtalk', 'DingTalk ボット', 'Webhook アドレスを入力。署名用シークレットは任意',
      ['server', 'secret']),
  _ChannelTypeMeta('wecom', 'WeCom ボット', '填写 Webhook 地址或 key', ['server', 'key']),
  _ChannelTypeMeta('telegram', 'Telegram', '填写 Bot Token 与 Chat ID',
      ['key', 'chatId', 'server'], true),
  _ChannelTypeMeta('feishu', 'Feishu ボット', 'Webhook アドレスを入力。署名用シークレットは任意',
      ['server', 'secret']),
  _ChannelTypeMeta('webhook', 'カスタム Webhook', '任意 URL，支持 {title} {content} 占位',
      ['server', 'method', 'body']),
];

// ------------------------------------------------------------
// 默认配置
// ------------------------------------------------------------
PVVisual pvDefaultVisual(bool composer) {
  if (composer) {
    return PVVisual(
      enabled: true,
      peakColor: '#f97316',
      valleyColor: '#38bdf8',
      width: 2,
      animation: 'breathing',
      breathingSpeed: 2.6,
      glow: 14,
      opacity: 0.4,
      glowDirection: 'out',
      flow: false,
      flowSpeed: 6,
    );
  }
  return PVVisual(
    enabled: true,
    peakColor: '#f97316',
    valleyColor: '#38bdf8',
    width: 3,
    animation: 'breathing',
    breathingSpeed: 2.6,
    glow: 22,
    opacity: 0.4,
    glowDirection: 'out',
    flow: false,
    flowSpeed: 6,
  );
}

PVConfig pvDefaultConfig() => PVConfig(
      version: 1,
      enabled: true,
      scope: 'deepseek',
      timezone: 'Asia/Shanghai',
      windows: _officialWindows.map((w) => PVWindow(w.start, w.end)).toList(),
      override: 'auto',
      pollSeconds: 15,
      edge: pvDefaultVisual(false),
      composer: pvDefaultVisual(true),
      badge: PVBadgeCfg(
        false,
        PVBadgePos('br', 18, 18),
        PVBadgePos('br', 12, 96),
      ),
      localNotify: PVLocalNotify(false, true, false),
      reminders: PVReminders(
        PVReminder(
          enabled: false,
          leadMinutes: 0,
          channel: 'all',
          times: '',
          title: 'DeepSeek ピーク時間の開始',
          content: '{phase}開始: {start}～{end}\n現在時刻: {time}',
        ),
        PVReminder(
          enabled: false,
          leadMinutes: 0,
          channel: 'all',
          times: '',
          title: 'DeepSeek オフピーク時間の開始',
          content: '{phase}開始: {start}～{end}\n現在時刻: {time}',
        ),
      ),
      channels: [],
    );

// ------------------------------------------------------------
// 存储
// ------------------------------------------------------------
PVConfig _pvCfg = pvDefaultConfig();
final Set<String> _pvFired = {};
bool _pvLoaded = false;

void pvInitDir() => ensureDir(pvDir);

void pvLoad() {
  if (_pvLoaded) return;
  pvInitDir();
  var cfg = pvDefaultConfig();
  if (File(pvConfigPath).existsSync()) {
    try {
      final raw = asMap(jsonDecode(File(pvConfigPath).readAsStringSync()));
      final sanitized = pvSanitize(_configFromJson(raw), cfg);
      if (sanitized.error == null) {
        cfg = sanitized.config!;
      } else {
        logp('⚠️ ピーク／オフピーク通知の設定が無効です。既定値を使用します: ${sanitized.error}');
      }
    } catch (e) {
      logp('⚠️ ピーク／オフピーク通知の設定解析に失敗しました: $e');
    }
  }
  _pvCfg = cfg;
  _pvFired.clear();
  if (File(pvFiredPath).existsSync()) {
    try {
      for (final k in asList(jsonDecode(File(pvFiredPath).readAsStringSync()))) {
        _pvFired.add('$k');
      }
    } catch (_) {}
  }
  _pvLoaded = true;
}

PVConfig pvGetConfig() {
  if (!_pvLoaded) pvLoad();
  return _pvCfg.copy();
}

void pvSaveLocked() {
  pvInitDir();
  try {
    final raw = const JsonEncoder.withIndent('  ').convert(_pvCfg.toJson());
    final tmp = '$pvConfigPath.tmp';
    File(tmp).writeAsStringSync(raw);
    File(tmp).renameSync(pvConfigPath);
  } catch (e) {
    logp('⚠️ ピーク／オフピーク通知の設定保存に失敗しました: $e');
  }
}

void pvSaveFiredLocked() {
  pvInitDir();
  final keys = _pvFired.toList()..sort();
  final trimmed = keys.length > pvFiredKeep
      ? keys.sublist(keys.length - pvFiredKeep)
      : keys;
  try {
    final tmp = '$pvFiredPath.tmp';
    File(tmp).writeAsStringSync(jsonEncode(trimmed));
    File(tmp).renameSync(pvFiredPath);
  } catch (_) {}
}

bool pvFiredHas(String key) => _pvFired.contains(key);

void pvFiredAdd(String key) {
  _pvFired.add(key);
  pvSaveFiredLocked();
}

void pvSetConfig(PVConfig cfg) {
  _pvCfg = cfg;
  pvSaveLocked();
}

void pvUpdateReminderResult(String phase, PVPushResult res) {
  final r = phase == PVPeak
      ? _pvCfg.reminders.peak
      : (phase == PVValley ? _pvCfg.reminders.valley : null);
  if (r == null) return;
  r.lastFiredAt = rfc3339(DateTime.now());
  r.lastResult = res;
  pvSaveLocked();
}

// ------------------------------------------------------------
// 时间引擎
// ------------------------------------------------------------
int? pvParseHM(String s) {
  final parts = s.trim().split(':');
  if (parts.length != 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return null;
  if (parts[1].length != 2 || h < 0 || h > 23 || m < 0 || m > 59) return null;
  return h * 60 + m;
}

String pvFormatHM(int min) {
  final v = min < 0 ? 0 : min;
  final h = (v ~/ 60).toString().padLeft(2, '0');
  final m = (v % 60).toString().padLeft(2, '0');
  return '$h:$m';
}

bool pvIsPeakAt(int minutes, List<PVWindow> windows) {
  for (final w in windows) {
    final s = pvParseHM(w.start);
    final e = pvParseHM(w.end);
    if (s == null || e == null || e <= s) continue;
    if (minutes >= s && minutes < e) return true;
  }
  return false;
}

String pvPhaseAt(DateTime t, PVConfig cfg) {
  if (cfg.override == PVPeak) return PVPeak;
  if (cfg.override == PVValley) return PVValley;
  final wall = pvWall(t, cfg.timezone);
  return pvIsPeakAt(wall.hour * 60 + wall.minute, cfg.windows)
      ? PVPeak
      : PVValley;
}

class _PVBoundary {
  final DateTime at;
  final String phase;
  const _PVBoundary(this.at, this.phase);
}

List<_PVBoundary> pvBoundaries(DateTime from, PVConfig cfg, int dayCount) {
  final wall = pvWall(from, cfg.timezone);
  final out = <_PVBoundary>[];
  for (var off = 0; off <= dayCount; off++) {
    final day = DateTime.utc(wall.year, wall.month, wall.day + off);
    for (final w in cfg.windows) {
      final s = pvParseHM(w.start);
      final e = pvParseHM(w.end);
      if (s == null || e == null || e <= s) continue;
      out.add(_PVBoundary(
          pvZonedUTC(day.year, day.month, day.day, s ~/ 60, s % 60, cfg.timezone),
          PVPeak));
      out.add(_PVBoundary(
          pvZonedUTC(day.year, day.month, day.day, e ~/ 60, e % 60, cfg.timezone),
          PVValley));
    }
  }
  out.sort((a, b) => a.at.compareTo(b.at));
  return out;
}

({DateTime? at, String? phase}) pvNextTransition(DateTime now, PVConfig cfg) {
  if (cfg.override != 'auto') return (at: null, phase: null);
  final cur = pvPhaseAt(now, cfg);
  for (final b in pvBoundaries(now, cfg, 2)) {
    if (!b.at.isAfter(now)) continue;
    if (b.phase != cur) return (at: b.at, phase: b.phase);
  }
  return (at: null, phase: null);
}

List<DateTime> pvPhaseStarts(DateTime from, String phase, PVConfig cfg) {
  final out = <DateTime>[];
  for (final b in pvBoundaries(from, cfg, 2)) {
    if (b.phase != phase) continue;
    if (b.at.isAfter(from)) out.add(b.at);
  }
  return out;
}

// ------------------------------------------------------------
// 模板
// ------------------------------------------------------------
const List<String> pvTemplateKeys = [
  'phase', 'phaseEn', 'start', 'end', 'time', 'date', 'hour', 'minute'
];

String pvRenderTemplate(String tpl, Map<String, String> vals) {
  if (tpl.isEmpty) return '';
  var out = tpl;
  for (final k in pvTemplateKeys) {
    final v = vals[k];
    if (v != null) out = out.replaceAll('{$k}', v);
  }
  return out;
}

Map<String, String> pvBuildValues(PVConfig cfg, String phase, DateTime at) {
  final now = pvWall(DateTime.now(), cfg.timezone);
  final atWall = pvWall(at, cfg.timezone);

  final label = pvPhaseText[phase]?['zh'] ?? '';
  final phaseEn = pvPhaseText[phase]?['en'] ?? '';
  final start = pvFormatHM(atWall.hour * 60 + atWall.minute);
  var end = '';

  if (phase == PVPeak) {
    final cur = atWall.hour * 60 + atWall.minute;
    for (final w in cfg.windows) {
      final s = pvParseHM(w.start);
      final e = pvParseHM(w.end);
      if (s == null || e == null || e <= s) continue;
      if (s == cur) {
        end = pvFormatHM(e);
        break;
      }
    }
  } else {
    final nx = pvNextTransition(at, cfg);
    if (nx.at != null && nx.phase == PVPeak) {
      final nl = pvWall(nx.at!, cfg.timezone);
      end = pvFormatHM(nl.hour * 60 + nl.minute);
    }
  }

  return {
    'phase': label,
    'phaseEn': phaseEn,
    'start': start,
    'end': end,
    'time': pvFormatHM(now.hour * 60 + now.minute),
    'date': fmtDate(now),
    'hour': now.hour.toString().padLeft(2, '0'),
    'minute': now.minute.toString().padLeft(2, '0'),
  };
}

// ------------------------------------------------------------
// 校验与钳制
// ------------------------------------------------------------
int pvClampInt(int v, int min, int max) => v < min ? min : (v > max ? max : v);

double pvClampFloat(double v, double min, double max) =>
    v < min ? min : (v > max ? max : v);

String pvValidColor(String s, String fallback) {
  if (s.length == 7 && s.startsWith('#')) {
    if (RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(s)) return s;
  }
  return fallback;
}

PVVisual pvSanitizeVisual(PVVisual input, PVVisual def) {
  final out = def.copy();
  out.enabled = input.enabled;
  out.peakColor = pvValidColor(input.peakColor, def.peakColor);
  out.valleyColor = pvValidColor(input.valleyColor, def.valleyColor);
  out.width = pvClampInt(input.width, 1, 14);
  if (['breathing', 'solid', 'off'].contains(input.animation)) {
    out.animation = input.animation;
  }
  out.breathingSpeed = pvClampFloat(input.breathingSpeed, 0.5, 10);
  out.glow = pvClampInt(input.glow, 0, 80);
  out.opacity = pvClampFloat(input.opacity, 0.2, 1);
  if (input.glowDirection == 'in' || input.glowDirection == 'out') {
    out.glowDirection = input.glowDirection;
  }
  out.flow = input.flow;
  out.flowSpeed = pvClampFloat(input.flowSpeed, 2, 24);
  return out;
}

PVBadgePos pvSanitizeBadgePos(PVBadgePos input, PVBadgePos def) {
  final out = def.copy();
  if (['tl', 'tr', 'bl', 'br'].contains(input.corner)) out.corner = input.corner;
  out.x = pvClampInt(input.x, 0, 400);
  out.y = pvClampInt(input.y, 0, 400);
  return out;
}

({PVConfig? config, String? error}) pvSanitize(PVConfig input, PVConfig def) {
  final out = def.copy();
  out.enabled = input.enabled;
  if (input.scope == 'deepseek' || input.scope == 'global') {
    out.scope = input.scope;
  }
  if (input.timezone.isNotEmpty && pvValidTimezone(input.timezone)) {
    out.timezone = input.timezone;
  }
  final windows = <PVWindow>[];
  for (final w in input.windows) {
    final s = pvParseHM(w.start);
    final e = pvParseHM(w.end);
    if (s == null || e == null || e <= s) continue;
    windows.add(PVWindow(pvFormatHM(s), pvFormatHM(e)));
  }
  if (windows.isEmpty) {
    return (config: out, error: '有効なピーク時間帯が少なくとも 1 つ必要です（開始時刻は終了時刻より前にしてください）');
  }
  out.windows = windows;
  if (['auto', 'peak', 'valley'].contains(input.override)) {
    out.override = input.override;
  }
  out.pollSeconds = pvClampInt(input.pollSeconds, 5, 120);
  out.edge = pvSanitizeVisual(input.edge, def.edge);
  out.composer = pvSanitizeVisual(input.composer, def.composer);
  out.badge.enabled = input.badge.enabled;
  out.badge.desktop = pvSanitizeBadgePos(input.badge.desktop, def.badge.desktop);
  out.badge.mobile = pvSanitizeBadgePos(input.badge.mobile, def.badge.mobile);
  out.localNotify = input.localNotify.copy();
  out.reminders.peak =
      pvSanitizeReminder(input.reminders.peak, def.reminders.peak);
  out.reminders.valley =
      pvSanitizeReminder(input.reminders.valley, def.reminders.valley);

  final chs = <PVChannel>[];
  final seen = <String>{};
  for (final c in input.channels) {
    final id = c.id.trim();
    if (id.isEmpty || seen.contains(id)) continue;
    if (!pvValidChannelType(c.type)) continue;
    seen.add(id);
    c.id = id;
    if (c.name.trim().isEmpty) c.name = pvChannelTypeName(c.type);
    chs.add(c);
  }
  out.channels = chs;
  return (config: out, error: null);
}

PVReminder pvSanitizeReminder(PVReminder input, PVReminder def) {
  final out = def.copy();
  out.enabled = input.enabled;
  out.leadMinutes = pvClampInt(input.leadMinutes, 0, 1440);
  if (input.channel.trim().isNotEmpty) out.channel = input.channel.trim();
  out.times = input.times;
  if (input.title.trim().isNotEmpty) {
    out.title = input.title;
  } else {
    out.title = def.title;
  }
  out.content = input.content;
  return out;
}

bool pvValidChannelType(String t) => _channelTypes.any((m) => m.type == t);

String pvChannelTypeName(String t) {
  for (final m in _channelTypes) {
    if (m.type == t) return m.name;
  }
  return t;
}

// ------------------------------------------------------------
// 密钥掩码
// ------------------------------------------------------------
String pvMaskSecret(String s) {
  if (s.isEmpty) return '';
  final r = s.runes.toList();
  if (r.length <= 4) return '••••';
  return '••${String.fromCharCodes(r.sublist(r.length - 4))}';
}

bool pvIsMasked(String s) => s.startsWith('••');

PVConfig pvMaskConfigForAPI(PVConfig cfg) {
  final out = cfg.copy();
  for (final c in out.channels) {
    c.key = pvMaskSecret(c.key);
    c.secret = pvMaskSecret(c.secret);
  }
  return out;
}

List<PVChannel> pvMergeChannelSecrets(
    List<PVChannel> input, List<PVChannel> old) {
  final byId = <String, PVChannel>{};
  for (final c in old) {
    byId[c.id] = c;
  }
  for (final c in input) {
    final prev = byId[c.id];
    if (prev == null) continue;
    if (pvIsMasked(c.key) || c.key.isEmpty) c.key = prev.key;
    if (pvIsMasked(c.secret) || c.secret.isEmpty) c.secret = prev.secret;
  }
  return input;
}

// ------------------------------------------------------------
// 推送渠道
// ------------------------------------------------------------
Future<({int status, String body})> pvPostJson(
    String url, Map<String, dynamic> payload) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await client.postUrl(Uri.parse(url));
    req.headers.set('Content-Type', 'application/json');
    req.add(utf8.encode(jsonEncode(payload)));
    final resp = await req.close().timeout(const Duration(seconds: 15));
    final data = await resp.fold<List<int>>([], (a, b) => a..addAll(b));
    return (
      status: resp.statusCode,
      body: utf8.decode(data.sublist(0, data.length > 65536 ? 65536 : data.length),
          allowMalformed: true)
    );
  } finally {
    client.close(force: true);
  }
}

Future<({int status, String body})> pvPostForm(
    String url, Map<String, String> form) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await client.postUrl(Uri.parse(url));
    req.headers
        .set('Content-Type', 'application/x-www-form-urlencoded');
    req.add(utf8.encode(form.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&')));
    final resp = await req.close().timeout(const Duration(seconds: 15));
    final data = await resp.fold<List<int>>([], (a, b) => a..addAll(b));
    return (
      status: resp.statusCode,
      body: utf8.decode(data.sublist(0, data.length > 65536 ? 65536 : data.length),
          allowMalformed: true)
    );
  } finally {
    client.close(force: true);
  }
}

String pvTruncate(String s, int n) {
  final r = s.runes.toList();
  if (r.length <= n) return s;
  return String.fromCharCodes(r.sublist(0, n));
}

Future<PVChannelResult> pvSendChannel(
    PVChannel c, String title, String content) async {
  PVChannelResult fail(String msg, int status) => PVChannelResult(
      channel: c.id, name: c.name, ok: false, error: msg, status: status);

  try {
    switch (c.type) {
      case 'serverchan':
        if (c.key.isEmpty) return fail('缺少 SendKey', 0);
        final r = await pvPostForm(
            'https://sctapi.ftqq.com/${c.key}.send', {'title': title, 'desp': content});
        if (r.status < 200 || r.status >= 300) {
          return fail('HTTP ${r.status}: ${pvTruncate(r.body, 120)}', r.status);
        }
        return PVChannelResult(
            channel: c.id, name: c.name, ok: true, status: r.status);

      case 'bark':
        if (c.key.isEmpty) return fail('缺少 DeviceKey', 0);
        var server = c.server.trim().replaceAll(RegExp(r'/+$'), '');
        if (server.isEmpty) server = 'https://api.day.app';
        final r = await pvPostJson('$server/push', {
          'device_key': c.key,
          'title': title,
          'body': content,
          'group': 'DeepSeek',
        });
        if (r.status < 200 || r.status >= 300) {
          return fail('HTTP ${r.status}: ${pvTruncate(r.body, 120)}', r.status);
        }
        return PVChannelResult(
            channel: c.id, name: c.name, ok: true, status: r.status);

      case 'dingtalk':
        var hook = c.server.trim();
        if (hook.isEmpty && c.key.isNotEmpty) {
          hook = 'https://oapi.dingtalk.com/robot/send?access_token=${c.key}';
        }
        if (hook.isEmpty) return fail('缺少 Webhook 地址', 0);
        if (c.secret.isNotEmpty) {
          final ts = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
          final sign = base64.encode(
              hmacSha256(utf8.encode('$ts\n${c.secret}'), utf8.encode('')));
          final sep = hook.contains('?') ? '&' : '?';
          hook = '$hook${sep}timestamp=$ts&sign=${Uri.encodeQueryComponent(sign)}';
        }
        final r = await pvPostJson(hook, {
          'msgtype': 'markdown',
          'markdown': {'title': title, 'text': '### $title\n\n$content'},
        });
        if (r.status < 200 || r.status >= 300) {
          return fail('HTTP ${r.status}: ${pvTruncate(r.body, 120)}', r.status);
        }
        return PVChannelResult(
            channel: c.id, name: c.name, ok: true, status: r.status);

      case 'wecom':
        var hook = c.server.trim();
        if (hook.isEmpty && c.key.isNotEmpty) {
          hook = 'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=${c.key}';
        }
        if (hook.isEmpty) return fail('缺少 Webhook 地址', 0);
        final r = await pvPostJson(hook, {
          'msgtype': 'markdown',
          'markdown': {'content': '### $title\n$content'},
        });
        if (r.status < 200 || r.status >= 300) {
          return fail('HTTP ${r.status}: ${pvTruncate(r.body, 120)}', r.status);
        }
        return PVChannelResult(
            channel: c.id, name: c.name, ok: true, status: r.status);

      case 'telegram':
        if (c.key.isEmpty) return fail('缺少 Bot Token', 0);
        if (c.chatId.isEmpty) return fail('缺少 Chat ID', 0);
        var base = c.server.trim().replaceAll(RegExp(r'/+$'), '');
        if (base.isEmpty) base = 'https://api.telegram.org';
        final r = await pvPostJson('$base/bot${c.key}/sendMessage', {
          'chat_id': c.chatId,
          'text': '$title\n\n$content',
          'disable_web_page_preview': true,
        });
        if (r.status < 200 || r.status >= 300) {
          return fail('HTTP ${r.status}: ${pvTruncate(r.body, 120)}', r.status);
        }
        return PVChannelResult(
            channel: c.id, name: c.name, ok: true, status: r.status);

      case 'feishu':
        var hook = c.server.trim();
        if (hook.isEmpty && c.key.isNotEmpty) {
          hook = 'https://open.feishu.cn/open-apis/bot/v2/hook/${c.key}';
        }
        if (hook.isEmpty) return fail('缺少 Webhook 地址', 0);
        final payload = <String, dynamic>{
          'msg_type': 'text',
          'content': {'text': '$title\n$content'},
        };
        if (c.secret.isNotEmpty) {
          final ts = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
          final sign = base64.encode(
              hmacSha256(utf8.encode('$ts\n${c.secret}'), const []));
          payload['timestamp'] = ts;
          payload['sign'] = sign;
        }
        final r = await pvPostJson(hook, payload);
        if (r.status < 200 || r.status >= 300) {
          return fail('HTTP ${r.status}: ${pvTruncate(r.body, 120)}', r.status);
        }
        return PVChannelResult(
            channel: c.id, name: c.name, ok: true, status: r.status);

      case 'webhook':
        final target = c.server.trim();
        if (target.isEmpty) return fail('缺少 Webhook 地址', 0);
        var method = c.method.trim().toUpperCase();
        if (method.isEmpty) method = 'POST';
        var tpl = c.body;
        if (tpl.trim().isEmpty) tpl = '{"title":"{title}","content":"{content}"}';
        final bodyText = tpl
            .replaceAll('{title}', jsonEscapeInner(title))
            .replaceAll('{content}', jsonEscapeInner(content));
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 15);
        try {
          final req = await client.openUrl(method, Uri.parse(target));
          req.headers.set('Content-Type', 'application/json');
          req.add(utf8.encode(bodyText));
          final resp = await req.close().timeout(const Duration(seconds: 15));
          final data = await resp.fold<List<int>>([], (a, b) => a..addAll(b));
          final text =
              utf8.decode(data, allowMalformed: true);
          if (resp.statusCode < 200 || resp.statusCode >= 300) {
            return fail('HTTP ${resp.statusCode}: ${pvTruncate(text, 120)}',
                resp.statusCode);
          }
          return PVChannelResult(
              channel: c.id, name: c.name, ok: true, status: resp.statusCode);
        } finally {
          client.close(force: true);
        }
    }
  } catch (e) {
    return fail('$e', 0);
  }
  return fail('不明なチャネル種別です: ${c.type}', 0);
}

Future<PVPushResult> pvDispatch(
    PVConfig cfg, String title, String content, String channel) async {
  final ch = channel.trim();
  final targets = <PVChannel>[];
  if (ch.isEmpty || ch == 'all') {
    for (final c in cfg.channels) {
      if (c.enabled) targets.add(c);
    }
  } else if (ch.startsWith('id:')) {
    final id = ch.substring(3);
    for (final c in cfg.channels) {
      if (c.id == id) targets.add(c);
    }
  } else {
    for (final c in cfg.channels) {
      if (c.id == ch) targets.add(c);
    }
  }

  final res = PVPushResult(total: targets.length);
  if (targets.isEmpty) {
    res.error = '有効なプッシュチャネルがありません（先に設定でチャネルを追加し有効化してください）';
    return res;
  }
  for (final c in targets) {
    final r = await pvSendChannel(c, title, content);
    res.details.add(r);
    if (r.ok) res.sent++;
  }
  res.ok = res.sent > 0;
  if (!res.ok && res.error.isEmpty) res.error = 'すべてのチャネルで送信に失敗しました';
  return res;
}

// ------------------------------------------------------------
// 调度
// ------------------------------------------------------------
List<int> pvParseTimesList(String text) {
  final out = <int>[];
  for (final f in text.split(RegExp(r'[,，;；\s、]+'))) {
    if (f.isEmpty) continue;
    final m = pvParseHM(f);
    if (m != null) out.add(m);
  }
  return out;
}

Future<void> pvFireReminder(String phase) async {
  final cfg = pvGetConfig();
  if (!cfg.enabled) return;
  final r = phase == PVPeak
      ? cfg.reminders.peak
      : (phase == PVValley ? cfg.reminders.valley : null);
  if (r == null || !r.enabled) return;

  final now = DateTime.now();

  // 1) 转折提醒
  final starts =
      pvPhaseStarts(now.subtract(const Duration(minutes: pvCatchupMin)), phase, cfg);
  for (final s in starts) {
    final reminderAt = s.subtract(Duration(minutes: r.leadMinutes));
    if (reminderAt.isAfter(now)) continue;
    if (now.difference(reminderAt).inMinutes > pvCatchupMin) continue;
    if (r.leadMinutes > 0 &&
        now.isAfter(s.add(const Duration(minutes: pvCatchupMin)))) {
      continue;
    }
    final key = '$phase:transition:${rfc3339(s.toUtc())}';
    if (pvFiredHas(key)) continue;
    pvFiredAdd(key);
    final vals = pvBuildValues(cfg, phase, s);
    var title = pvRenderTemplate(r.title, vals);
    if (title.trim().isEmpty) title = '${pvPhaseText[phase]?['zh'] ?? ''}提醒';
    final content = pvRenderTemplate(r.content, vals);
    final result = await pvDispatch(cfg, title, content, r.channel);
    pvUpdateReminderResult(phase, result);
    logp('🔔 ピーク／オフピーク通知を発火 [$key] 成功 ${result.sent}/${result.total}');
  }

  // 2) 阶段内固定时间
  final times = pvParseTimesList(r.times);
  if (times.isEmpty) return;
  if (pvPhaseAt(now, cfg) != phase) return;
  final lt = pvWall(now, cfg.timezone);
  final cur = lt.hour * 60 + lt.minute;
  for (final m in times) {
    if (cur != m) continue;
    final key = '$phase:daily:${fmtDate(lt)}:$m';
    if (pvFiredHas(key)) continue;
    pvFiredAdd(key);
    final at =
        pvZonedUTC(lt.year, lt.month, lt.day, m ~/ 60, m % 60, cfg.timezone);
    final vals = pvBuildValues(cfg, phase, at);
    var title = pvRenderTemplate(r.title, vals);
    if (title.trim().isEmpty) title = '${pvPhaseText[phase]?['zh'] ?? ''}提醒';
    final content = pvRenderTemplate(r.content, vals);
    final result = await pvDispatch(cfg, title, content, r.channel);
    pvUpdateReminderResult(phase, result);
    logp('🔔 ピーク／オフピーク定期通知を発火 [$key] 成功 ${result.sent}/${result.total}');
  }
}

Future<void> pvTick() async {
  try {
    await pvFireReminder(PVPeak);
    await pvFireReminder(PVValley);
  } catch (e) {
    logp('⚠️ ピーク／オフピークスケジューラで例外: $e');
  }
}

void pvSchedulerLoop() {
  Timer(const Duration(seconds: 5), () async {
    await pvTick();
    Timer.periodic(
        const Duration(seconds: pvTickSeconds), (_) => pvTick());
  });
}

// ------------------------------------------------------------
// HTTP
// ------------------------------------------------------------
Future<void> pvJSONWrite(HttpResponse res, int code, Object? v) async {
  String body;
  try {
    body = jsonEncode(v);
  } catch (_) {
    body = '{"ok":false,"error":{"code":"ENCODE","message":"シリアライズに失敗しました"}}';
  }
  try {
    res.statusCode = code;
    res.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
    res.headers.set('Cache-Control', 'no-cache');
    res.write(body);
  } catch (_) {
    try {
      await res.close();
    } catch (_) {}
    return;
  }
  try {
    await res.close();
  } catch (_) {}
}

Future<void> pvOk(HttpResponse res, Object? v) =>
    pvJSONWrite(res, 200, {'ok': true, 'value': v});

Future<void> pvFail(HttpResponse res, int code, String errCode, String msg) =>
    pvJSONWrite(res, code, {
      'ok': false,
      'error': {'code': errCode, 'message': msg},
    });

bool pvSameOrigin(HttpRequest r) {
  final origin = r.headers.value('origin');
  if (origin == null || origin.isEmpty) return true;
  try {
    final u = Uri.parse(origin);
    final originHost = u.host.toLowerCase();
    final reqHost = r.headers.host?.split(':').first.toLowerCase() ?? '';
    return originHost.isNotEmpty && originHost == reqHost;
  } catch (_) {
    return false;
  }
}

Map<String, dynamic> pvStatusPayload(PVConfig cfg) {
  final now = DateTime.now();
  final phase = pvPhaseAt(now, cfg);
  final payload = <String, dynamic>{
    'now': rfc3339(now),
    'enabled': cfg.enabled,
    'scope': cfg.scope,
    'timezone': cfg.timezone,
    'windows': cfg.windows.map((w) => w.toJson()).toList(),
    'phase': phase,
    'phaseText': pvPhaseText[phase],
    'override': cfg.override,
    'pollSeconds': cfg.pollSeconds,
    'edge': cfg.edge.toJson(),
    'composer': cfg.composer.toJson(),
    'badge': cfg.badge.toJson(),
    'localNotify': cfg.localNotify.toJson(),
    'reminders': cfg.reminders.toJson(),
    'channelCount': cfg.channels.length,
    'timezones': pvTimezones,
    'channelTypes': _channelTypes.map((t) => t.toJson()).toList(),
  };
  final nx = pvNextTransition(now, cfg);
  if (nx.at != null) {
    payload['nextTransitionAt'] = rfc3339(nx.at!);
    payload['nextPhase'] = nx.phase;
    payload['nextTransitionIn'] = nx.at!.difference(now).inSeconds;
  } else {
    payload['nextTransitionAt'] = null;
    payload['nextPhase'] = null;
  }
  return payload;
}

PVConfig _configFromJson(Map<String, dynamic> m) {
  final def = pvDefaultConfig();
  final windows = asList(m['windows']).isNotEmpty
      ? asList(m['windows']).map((e) => PVWindow.fromJson(asMap(e))).toList()
      : def.windows;
  final badgeRaw = asMap(m['badge']);
  final lnRaw = asMap(m['localNotify']);
  final rmRaw = asMap(m['reminders']);
  return PVConfig(
    version: intArgDefault(m, 'version', def.version),
    enabled: mBool(m, 'enabled', def.enabled),
    scope: mStr(m, 'scope', def.scope),
    timezone: mStr(m, 'timezone', def.timezone),
    windows: windows,
    override: mStr(m, 'override', def.override),
    pollSeconds: intArgDefault(m, 'pollSeconds', def.pollSeconds),
    edge: PVVisual.fromJson(asMap(m['edge']), def.edge),
    composer: PVVisual.fromJson(asMap(m['composer']), def.composer),
    badge: PVBadgeCfg(
      mBool(badgeRaw, 'enabled', def.badge.enabled),
      PVBadgePos.fromJson(asMap(badgeRaw['desktop']), def.badge.desktop),
      PVBadgePos.fromJson(asMap(badgeRaw['mobile']), def.badge.mobile),
    ),
    localNotify: PVLocalNotify(
      mBool(lnRaw, 'enabled', def.localNotify.enabled),
      mBool(lnRaw, 'onTransition', def.localNotify.onTransition),
      mBool(lnRaw, 'onReminder', def.localNotify.onReminder),
    ),
    reminders: PVReminders(
      PVReminder.fromJson(asMap(rmRaw['peak']), def.reminders.peak),
      PVReminder.fromJson(asMap(rmRaw['valley']), def.reminders.valley),
    ),
    channels:
        asList(m['channels']).map((e) => PVChannel.fromJson(asMap(e))).toList(),
  );
}

bool pvChannelConfigured(PVChannel c) {
  switch (c.type) {
    case 'serverchan':
    case 'bark':
      return c.key.isNotEmpty;
    case 'dingtalk':
    case 'wecom':
    case 'feishu':
      return c.server.isNotEmpty || c.key.isNotEmpty;
    case 'telegram':
      return c.key.isNotEmpty && c.chatId.isNotEmpty;
    case 'webhook':
      return c.server.isNotEmpty;
  }
  return false;
}

String pvStr(Map<String, dynamic> m, String key, String def) => mStr(m, key, def);

Future<void> pvHandleAPI(HttpRequest r) async {
  final res = r.response;
  if (r.method != 'POST') {
    await pvFail(res, 405, 'method-error', 'method not allowed');
    return;
  }
  if (!pvSameOrigin(r)) {
    await pvFail(res, 403, 'forbidden', 'forbidden');
    return;
  }
  final method = r.uri.path
      .replaceFirst('/api/peakvalley/', '')
      .replaceAll(RegExp(r'^/+|/+$'), '');
  if (method.isEmpty) {
    await pvFail(res, 404, 'not-found', 'unknown peakvalley API method');
    return;
  }

  Map<String, dynamic> payload;
  try {
    final bytes = await readBodyBytes(r, limit: pvMaxBodyBytes);
    if (bytes.isEmpty) {
      payload = <String, dynamic>{};
    } else {
      payload = asMap(jsonDecode(utf8.decode(bytes, allowMalformed: true)));
    }
  } catch (_) {
    await pvFail(res, 400, 'bad-request', '请求体不是有效 JSON');
    return;
  }
  pvGetConfig();

  switch (method) {
    case 'status':
      await pvOk(res, pvStatusPayload(pvGetConfig()));
      return;

    case 'config':
      final cfg = pvGetConfig();
      await pvOk(res, {
        'config': pvMaskConfigForAPI(cfg).toJson(),
        'defaults': pvDefaultConfig().toJson(),
        'official': _officialWindows.map((w) => w.toJson()).toList(),
        'timezones': pvTimezones,
        'channelTypes': _channelTypes.map((t) => t.toJson()).toList(),
        'dataPath': pvConfigPath,
      });
      return;

    case 'save':
      final rawCfg = payload.containsKey('config') ? payload['config'] : payload;
      PVConfig input;
      try {
        input = _configFromJson(asMap(rawCfg));
      } catch (e) {
        await pvFail(res, 400, 'bad-request', '配置格式无效: $e');
        return;
      }
      final old = pvGetConfig();
      input.channels = pvMergeChannelSecrets(input.channels, old.channels);
      final s = pvSanitize(input, old);
      if (s.error != null) {
        await pvFail(res, 400, 'bad-request', s.error!);
        return;
      }
      final cfg = s.config!;
      cfg.reminders.peak.lastFiredAt = old.reminders.peak.lastFiredAt;
      cfg.reminders.peak.lastResult = old.reminders.peak.lastResult;
      cfg.reminders.valley.lastFiredAt = old.reminders.valley.lastFiredAt;
      cfg.reminders.valley.lastResult = old.reminders.valley.lastResult;
      pvSetConfig(cfg);
      await pvOk(res, {
        'saved': true,
        'config': pvMaskConfigForAPI(pvGetConfig()).toJson(),
        'status': pvStatusPayload(pvGetConfig()),
      });
      return;

    case 'reset':
      final section = pvStr(payload, 'section', '');
      var cfg = pvGetConfig();
      final def = pvDefaultConfig();
      switch (section) {
        case '':
        case 'all':
          cfg = def;
          break;
        case 'edge':
          cfg.edge = def.edge;
          break;
        case 'composer':
          cfg.composer = def.composer;
          break;
        case 'badge':
          cfg.badge = def.badge;
          break;
        case 'localNotify':
          cfg.localNotify = def.localNotify;
          break;
        case 'reminders':
          cfg.reminders.peak = def.reminders.peak.copy();
          cfg.reminders.valley = def.reminders.valley.copy();
          break;
        case 'windows':
          cfg.windows =
              _officialWindows.map((w) => PVWindow(w.start, w.end)).toList();
          break;
        case 'channels':
          cfg.channels = [];
          break;
        default:
          await pvFail(res, 400, 'bad-request', '未知的配置分区 "$section"');
          return;
      }
      pvSetConfig(cfg);
      await pvOk(res, {
        'saved': true,
        'config': pvMaskConfigForAPI(pvGetConfig()).toJson(),
      });
      return;

    case 'channels':
      final cfg = pvGetConfig();
      await pvOk(res, {
        'channels': cfg.channels
            .map((c) => {
                  'id': c.id,
                  'type': c.type,
                  'name': c.name,
                  'enabled': c.enabled,
                  'key': pvMaskSecret(c.key),
                  'secret': pvMaskSecret(c.secret),
                  'server': c.server,
                  'chatId': c.chatId,
                  'method': c.method,
                  'body': c.body,
                  'configured': pvChannelConfigured(c),
                })
            .toList(),
        'types': _channelTypes.map((t) => t.toJson()).toList(),
      });
      return;

    case 'channelSave':
      final rawCh = payload['channel'];
      if (rawCh == null) {
        await pvFail(res, 400, 'bad-request', '缺少 channel 字段');
        return;
      }
      final input = PVChannel.fromJson(asMap(rawCh));
      if (!pvValidChannelType(input.type)) {
        await pvFail(res, 400, 'bad-request', '不明なチャネル種別です');
        return;
      }
      final cfg = pvGetConfig();
      if (input.id.trim().isEmpty) {
        input.id = 'ch_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
      }
      input.key = input.key.trim();
      input.secret = input.secret.trim();
      input.server = input.server.trim();
      input.chatId = input.chatId.trim();
      if (input.name.trim().isEmpty) input.name = pvChannelTypeName(input.type);
      var replaced = false;
      for (var i = 0; i < cfg.channels.length; i++) {
        if (cfg.channels[i].id == input.id) {
          if (pvIsMasked(input.key) || input.key.isEmpty) {
            input.key = cfg.channels[i].key;
          }
          if (pvIsMasked(input.secret) || input.secret.isEmpty) {
            input.secret = cfg.channels[i].secret;
          }
          cfg.channels[i] = input;
          replaced = true;
          break;
        }
      }
      if (!replaced) cfg.channels.add(input);
      pvSetConfig(cfg);
      await pvOk(res, {
        'saved': true,
        'id': input.id,
        'configured': pvChannelConfigured(input),
      });
      return;

    case 'channelDelete':
      final id = pvStr(payload, 'id', '');
      final cfg = pvGetConfig();
      cfg.channels.removeWhere((c) => c.id == id);
      pvSetConfig(cfg);
      await pvOk(res, {'deleted': true});
      return;

    case 'channelTest':
      final id = pvStr(payload, 'id', '');
      final cfg = pvGetConfig();
      PVChannel? target;
      for (final c in cfg.channels) {
        if (c.id == id) {
          target = c;
          break;
        }
      }
      if (target == null) {
        await pvFail(res, 404, 'not-found', '渠道不存在');
        return;
      }
      final now = DateTime.now();
      final res1 = await pvSendChannel(target, 'ピーク／オフピーク通知テスト',
          'これは「ピーク／オフピーク通知」からのテストメッセージです。\n時刻: ${fmtDate(now)} ${fmtClock(now).substring(0, 5)}');
      await pvOk(res, res1.toJson());
      return;

    case 'test':
      final kind = pvStr(payload, 'kind', 'peak');
      final channel = pvStr(payload, 'channel', 'all');
      final cfg = pvGetConfig();
      var phase = kind;
      if (kind == 'custom') phase = PVPeak;
      final vals = pvBuildValues(cfg, phase, DateTime.now());
      String title;
      String content;
      if (kind == 'custom') {
        vals['phase'] = 'カスタムテスト';
        title = pvStr(payload, 'title', 'ピーク／オフピーク通知テスト').trim();
        content = pvStr(payload, 'content', 'これはピーク／オフピーク通知からのテストメッセージです。');
      } else {
        if (phase != PVPeak && phase != PVValley) {
          await pvFail(res, 400, 'bad-request', '不明なテスト種別です "$kind"');
          return;
        }
        final r = phase == PVPeak ? cfg.reminders.peak : cfg.reminders.valley;
        title = pvRenderTemplate(pvStr(payload, 'title', r.title), vals);
        if (title.trim().isEmpty) {
          title = '${pvPhaseText[phase]?['zh'] ?? ''}提醒';
        }
        content = pvRenderTemplate(pvStr(payload, 'content', r.content), vals);
      }
      final result = await pvDispatch(cfg, title, content, channel);
      await pvOk(res, {
        'result': result.toJson(),
        'title': title,
        'content': content,
        'values': vals,
      });
      return;

    case 'fireNow':
      final phase = pvStr(payload, 'phase', 'peak');
      if (phase != PVPeak && phase != PVValley) {
        await pvFail(res, 400, 'bad-request', '不明なフェーズです "$phase"');
        return;
      }
      final cfg = pvGetConfig();
      final r = phase == PVPeak ? cfg.reminders.peak : cfg.reminders.valley;
      if (!r.enabled) {
        await pvOk(res, {'skipped': true, 'reason': 'このフェーズの通知は有効になっていません'});
        return;
      }
      final vals = pvBuildValues(cfg, phase, DateTime.now());
      var title = pvRenderTemplate(r.title, vals);
      if (title.trim().isEmpty) {
        title = '${pvPhaseText[phase]?['zh'] ?? ''}提醒';
      }
      final content = pvRenderTemplate(r.content, vals);
      final result = await pvDispatch(cfg, title, content, r.channel);
      pvUpdateReminderResult(phase, result);
      await pvOk(res, {'result': result.toJson(), 'values': vals});
      return;

    case 'preview':
      final atStr = pvStr(payload, 'at', '');
      final cfg = pvGetConfig();
      var at = DateTime.now();
      if (atStr.isNotEmpty) {
        try {
          at = DateTime.parse(atStr);
        } catch (_) {}
      }
      final phase = pvPhaseAt(at, cfg);
      await pvOk(res, {
        'at': rfc3339(at),
        'phase': phase,
        'values': pvBuildValues(cfg, phase, at),
      });
      return;

    default:
      await pvFail(res, 404, 'not-found',
          'unknown peakvalley API method "$method"');
  }
}
