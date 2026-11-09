// ============================================================
// tools.dart —— AI 工具集（schema + 执行）
// 100% 对齐 Go 版 deepseek-tools.go：
//   - 90+ 工具的 JSON Schema 与描述逐条一致
//   - shell / Termux API / UI 自动化 / 弹窗处理逻辑一致
//   - Shizuku 権限已撤销（shizukuDisabled = true）：拒否任何 rish/shizuku
//     调用，实际命令一律走本地 sh，与 Go 版运行期行为一致
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'cosplay.dart';
import 'ds_crypto.dart';
import 'net.dart';
import 'deepseek_api.dart';
import 'globals.dart';
import 'virtual_display.dart';

// ------------------------------------------------------------
// 工作区 & 常量
// ------------------------------------------------------------
String get dsWorkspaceDir {
  final w = getEnv('DS_WORKSPACE');
  if (w != null && w.isNotEmpty) return w;
  final h = getEnv('HOME');
  if (h != null && h.isNotEmpty) return h;
  return '/';
}

const int defaultCmdTimeout = 30;
const int maxCmdTimeout = 86400;
const int defaultSwipeDur = 150;
const int defaultLongPressDur = 600;
const int maxWaitSeconds = 86400;
const String shizukuPackage = 'moe.shizuku.privileged.api';
const bool shizukuDisabled = true;
const int fastPollIntervalMs = 40;
const int fastPollMaxMs = 900;
const Duration fgCacheTTL = Duration(milliseconds: 800);
const Duration uiCacheTTL = Duration(milliseconds: 300);

// ------------------------------------------------------------
// adb shell 通道（本机无线调试，uid=2000 shell）
//   旧 Shizuku 権限は取り消し済み。input / am / pm / dumpsys /
//   uiautomator / settings / appops / wm / screencap 等の
//   システム級コマンドは Termux 応用 uid では実行できないため、
//   adb shell（uid=2000、Shizuku 相当の権限）へ振り分ける。
// ------------------------------------------------------------
const String dsAdbSerial = '127.0.0.1:5555';
const Duration adbReadyTTL = Duration(seconds: 15);

String _adbBin = '';
bool _adbReady = false;
DateTime _adbReadyAt = DateTime.fromMillisecondsSinceEpoch(0);
Future<bool>? _adbEnsureTask;
String _adbLastError = '';

/// 需要 shell(uid=2000) 身份才能执行的命令头。
const Set<String> _shellUidCmds = <String>{
  'input', 'am', 'pm', 'cmd', 'dumpsys', 'uiautomator', 'settings',
  'content', 'wm', 'svc', 'media', 'monkey', 'appops', 'screencap',
  'screenrecord', 'ime', 'getprop', 'setprop', 'pidof', 'ps',
  'kill', 'pkill', 'top', 'logcat', 'dpm',
};

String _resolveAdbBin() {
  if (_adbBin.isNotEmpty && _adbBin != 'adb') return _adbBin;
  for (final p in const <String>[
    '/data/data/com.termux/files/usr/bin/adb',
    '/usr/bin/adb',
    '/system/bin/adb',
  ]) {
    try {
      if (File(p).existsSync()) {
        _adbBin = p;
        return _adbBin;
      }
    } catch (_) {}
  }
  _adbBin = 'adb';
  return _adbBin;
}

String adbBinPath() => _resolveAdbBin();

bool adbChannelReady() =>
    _adbReady && DateTime.now().difference(_adbReadyAt) < adbReadyTTL;

String adbLastError() => _adbLastError;

/// 确保 adb 通道在线：start-server → connect → 校验 uid=2000/0。
Future<bool> ensureAdbChannel({bool force = false}) async {
  if (!force && adbChannelReady()) return true;
  final running = _adbEnsureTask;
  if (running != null) return running;
  final task = _ensureAdbChannelImpl();
  _adbEnsureTask = task;
  try {
    return await task;
  } finally {
    _adbEnsureTask = null;
  }
}

Future<bool> _ensureAdbChannelImpl() async {
  final bin = _resolveAdbBin();
  try {
    await runProcess(bin, const ['start-server'],
        timeout: const Duration(seconds: 8));
  } catch (_) {}
  try {
    await runProcess(bin, const ['connect', dsAdbSerial],
        timeout: const Duration(seconds: 8));
  } catch (_) {}
  var out = '';
  try {
    final r = await runProcess(bin, const ['-s', dsAdbSerial, 'shell', 'id'],
        timeout: const Duration(seconds: 8));
    out = r.out;
  } catch (e) {
    out = '$e';
  }
  var ok = out.contains('uid=2000') || out.contains('uid=0');
  if (!ok) {
    // 兜底：直接跑项目自带的 adb_up.sh（起 daemon + connect + 校验）
    try {
      final script = '${Directory.current.path}/adb_up.sh';
      if (File(script).existsSync()) {
        await runProcess('sh', [script], timeout: const Duration(seconds: 25));
        final r2 = await runProcess(bin, const ['-s', dsAdbSerial, 'shell', 'id'],
            timeout: const Duration(seconds: 8));
        out = r2.out;
        ok = out.contains('uid=2000') || out.contains('uid=0');
      }
    } catch (_) {}
  }
  _adbReady = ok;
  if (ok) {
    _adbReadyAt = DateTime.now();
    _adbLastError = '';
  } else {
    _adbLastError = out.trim().isEmpty ? 'adb 応答なし' : out.trim();
    if (_adbLastError.length > 200) {
      _adbLastError = _adbLastError.substring(0, 200);
    }
  }
  return ok;
}

bool _adbLinkLost(String s) {
  final low = s.toLowerCase();
  if (low.contains('unauthorized') ||
      low.contains('failed to connect') ||
      low.contains('cannot connect') ||
      low.contains('no devices/emulators')) {
    return true;
  }
  return low.contains('device ') &&
      (low.contains('not found') || low.contains('offline'));
}

/// 直接执行 adb shell 命令（掉线自动重连重试一次）。
Future<ProcResult> runViaAdb(String cmdStr, {Duration? timeout}) async {
  final bin = _resolveAdbBin();
  final t = timeout ?? const Duration(seconds: 30);
  var r = await runProcess(bin, ['-s', dsAdbSerial, 'shell', cmdStr], timeout: t);
  if (_adbLinkLost(r.out)) {
    final ok = await ensureAdbChannel(force: true);
    if (ok) {
      r = await runProcess(bin, ['-s', dsAdbSerial, 'shell', cmdStr], timeout: t);
    }
  }
  final out = r.out.replaceAll('\r\n', '\n').replaceAll('\r', '');
  return ProcResult(out, r.code, r.timedOut);
}

/// 引号感知的 `;` 分段：`input text 'a;b'` 不会被切开。
List<String> splitShellSegments(String cmd) {
  final out = <String>[];
  final buf = StringBuffer();
  String? quote;
  var esc = false;
  for (var i = 0; i < cmd.length; i++) {
    final ch = cmd[i];
    if (esc) {
      buf.write(ch);
      esc = false;
      continue;
    }
    if (ch == '\\') {
      buf.write(ch);
      esc = true;
      continue;
    }
    if (quote != null) {
      if (ch == quote) quote = null;
      buf.write(ch);
      continue;
    }
    if (ch == "'" || ch == '"') {
      quote = ch;
      buf.write(ch);
      continue;
    }
    if (ch == ';') {
      out.add(buf.toString());
      buf.clear();
      continue;
    }
    buf.write(ch);
  }
  if (buf.isNotEmpty) out.add(buf.toString());
  return out
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList(growable: false);
}

/// 该段命令是否必须以 shell(uid=2000) 身份执行。
bool segNeedsShellUid(String seg) {
  var s = seg.trim();
  if (s.isEmpty) return false;
  var guard = 0;
  while (guard++ < 8) {
    final first = s.split(RegExp(r'\s+')).first;
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(first)) break;
    s = s.substring(first.length).trim();
    if (s.isEmpty) return false;
  }
  if (s.isEmpty) return false;
  var head = s.split(RegExp(r'\s+')).first;
  final slash = head.lastIndexOf('/');
  if (slash >= 0) head = head.substring(slash + 1);
  head = head.replaceAll(RegExp(r'^[()]+'), '');
  return _shellUidCmds.contains(head);
}

// ------------------------------------------------------------
// 进程执行辅助（带超时）
// ------------------------------------------------------------
class ProcResult {
  final String out;
  final int code;
  final bool timedOut;
  const ProcResult(this.out, this.code, this.timedOut);
}

Future<ProcResult> runProcess(
  String exe,
  List<String> args, {
  String? workdir,
  Duration? timeout,
  Map<String, String>? env,
}) async {
  Process p;
  try {
    p = await Process.start(exe, args,
        workingDirectory: workdir, environment: env, runInShell: false);
  } catch (e) {
    return ProcResult('$e', -1, false);
  }
  final out = BytesBuilder();
  final s1 = p.stdout.listen(out.add);
  final s2 = p.stderr.listen(out.add);
  var timedOut = false;
  int code;
  if (timeout == null) {
    code = await p.exitCode;
  } else {
    code = await p.exitCode.timeout(timeout, onTimeout: () {
      timedOut = true;
      try {
        p.kill(ProcessSignal.sigkill);
      } catch (_) {}
      return -1;
    });
  }
  try {
    await s1.cancel();
    await s2.cancel();
  } catch (_) {}
  return ProcResult(utf8.decode(out.takeBytes(), allowMalformed: true), code,
      timedOut);
}

// ------------------------------------------------------------
// 缓存
// ------------------------------------------------------------
String _fgPkg = '';
DateTime _fgTime = DateTime.fromMillisecondsSinceEpoch(0);
String _uiXml = '';
DateTime _uiTime = DateTime.fromMillisecondsSinceEpoch(0);

void invalidateFgCache() {
  _fgPkg = '';
  _fgTime = DateTime.fromMillisecondsSinceEpoch(0);
}

void invalidateUICache() {
  _uiXml = '';
  _uiTime = DateTime.fromMillisecondsSinceEpoch(0);
}

void invalidateShizukuCache() {}

bool IsShizukuElevated() => false;

bool containsPermissionError(String s) {
  final low = s.toLowerCase();
  for (final k in [
    'permission denial', 'security exception', 'not allowed',
    'java.lang.securityexception', 'operation not permitted', 'eacces', 'eperm',
    'missing android.permission',
  ]) {
    if (low.contains(k)) return true;
  }
  return false;
}

bool containsShizukuInvocation(String cmdStr) {
  final low = cmdStr.toLowerCase();
  return low.contains('rish') || low.contains('shizuku');
}

Future<ProcResult> runRawShell(String workdir, String cmdStr,
    {Duration? timeout}) {
  return runProcess('sh', ['-c', cmdStr],
      workdir: workdir.isEmpty ? null : workdir, timeout: timeout);
}

/// 智能 shell：Shizuku 已撤销 → 直接本地 sh（并对 rish/shizuku 命令直接拒否）
class SmartShellResult {
  final String out;
  final bool usedShizuku;
  final int code;
  const SmartShellResult(this.out, this.usedShizuku, this.code);
}

Future<SmartShellResult> runSmartShell(String workdir, String cmdStr,
    {Duration? timeout}) async {
  if (shizukuDisabled && containsShizukuInvocation(cmdStr)) {
    return const SmartShellResult(
        '🚫 旧権限チャンネルの呼び出しは無効化されています。システム操作は adb shell 通道（adb_shell）を使用してください',
        false, 1);
  }
  final segs = splitShellSegments(cmdStr);
  if (segs.isEmpty) return const SmartShellResult('', false, 0);
  final needsAdb = segs.any(segNeedsShellUid);
  if (!needsAdb) {
    final r = await runRawShell(workdir, cmdStr, timeout: timeout);
    return SmartShellResult(r.out, false, r.code);
  }
  final per = timeout ?? const Duration(seconds: 30);
  final online = await ensureAdbChannel();
  if (!online) {
    final r = await runRawShell(workdir, cmdStr, timeout: timeout);
    final hint = '\n⚠️ adb shell 通道がオフラインです（$_adbLastError）。'
        'Termux で ddsh/adb_up.sh を実行してください';
    return SmartShellResult('${r.out}$hint', false, r.code);
  }
  final sb = StringBuffer();
  var code = 0;
  var yielder = 0;
  for (final seg in segs) {
    final ProcResult r;
    if (segNeedsShellUid(seg)) {
      r = await runViaAdb(seg, timeout: per);
    } else {
      final rr = await runRawShell(workdir, seg, timeout: per);
      r = ProcResult(rr.out, rr.code, rr.timedOut);
    }
    if (r.out.isNotEmpty) {
      if (sb.isNotEmpty) sb.write('\n');
      sb.write(r.out);
      if (++yielder % 24 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    code = r.code;
  }
  return SmartShellResult(sb.toString(), true, code);
}

Future<String> runShellCtx(String workdir, String cmdStr,
    {Duration? timeout}) async {
  final r = await runSmartShell(workdir, cmdStr, timeout: timeout);
  return r.out;
}

Future<({String out, String? error})> runTermuxAPI(
    Duration timeout, String name, List<String> args) async {
  final r = await runProcess(name, args, timeout: timeout);
  if (r.timedOut) return (out: r.out, error: '$name タイムアウト');
  if (r.code != 0) return (out: r.out, error: '$name に失敗');
  return (out: r.out, error: null);
}

String truncate(String s, int n) {
  if (s.length <= n) return s;
  return '${s.substring(0, n)}...';
}

String shellQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

String resolveToolPath(String p) {
  final t = p.trim();
  if (t.isEmpty) return dsWorkspaceDir;
  if (t.startsWith('/')) return t;
  return '$dsWorkspaceDir/$t';
}

// ------------------------------------------------------------
// 屏幕 / UI
// ------------------------------------------------------------
class UiNode {
  final String text;
  final String contentDesc;
  final String resourceId;
  final String klass;
  final String package;
  final bool clickable;
  final int left;
  final int top;
  final int right;
  final int bottom;
  const UiNode({
    this.text = '',
    this.contentDesc = '',
    this.resourceId = '',
    this.klass = '',
    this.package = '',
    this.clickable = false,
    this.left = 0,
    this.top = 0,
    this.right = 0,
    this.bottom = 0,
  });
  int get centerX => (left + right) ~/ 2;
  int get centerY => (top + bottom) ~/ 2;
}

final RegExp _reNode = RegExp(r'<node\b[^>]*?/?>');
final RegExp _reAttr = RegExp(r'([\w:-]+)="([^"]*)"');
final RegExp _reBounds =
    RegExp(r'\[\s*(-?\d+)\s*,\s*(-?\d+)\s*\]\s*\[\s*(-?\d+)\s*,\s*(-?\d+)\s*\]');
final RegExp _reNumOnly = RegExp(r'-?\d+');

List<UiNode> parseUINodes(String xml) {
  final nodes = <UiNode>[];
  for (final m0 in _reNode.allMatches(xml)) {
    final tag = m0.group(0)!;
    final attrs = <String, String>{};
    for (final m in _reAttr.allMatches(tag)) {
      attrs[m.group(1)!] = m.group(2)!;
    }
    var l = 0, t = 0, r = 0, b = 0;
    final bounds = attrs['bounds'] ?? '';
    if (bounds.isNotEmpty) {
      final mb = _reBounds.firstMatch(bounds);
      if (mb != null) {
        l = int.tryParse(mb.group(1)!) ?? 0;
        t = int.tryParse(mb.group(2)!) ?? 0;
        r = int.tryParse(mb.group(3)!) ?? 0;
        b = int.tryParse(mb.group(4)!) ?? 0;
      } else {
        final nums = _reNumOnly
            .allMatches(bounds)
            .map((m) => int.tryParse(m.group(0)!) ?? 0)
            .toList();
        if (nums.length == 4) {
          l = nums[0];
          t = nums[1];
          r = nums[2];
          b = nums[3];
        }
      }
    }
    nodes.add(UiNode(
      text: attrs['text'] ?? '',
      contentDesc: attrs['content-desc'] ?? '',
      resourceId: attrs['resource-id'] ?? '',
      klass: attrs['class'] ?? '',
      package: attrs['package'] ?? '',
      clickable: attrs['clickable'] == 'true',
      left: l,
      top: t,
      right: r,
      bottom: b,
    ));
  }
  return nodes;
}

Future<String?> dumpUIXMLCached() async {
  final now = DateTime.now();
  if (_uiXml.isNotEmpty && now.difference(_uiTime) < uiCacheTTL) {
    return _uiXml;
  }
  var out = await runShellCtx('',
      'uiautomator dump /sdcard/.ds_w.xml >/dev/null 2>&1; cat /sdcard/.ds_w.xml 2>/dev/null',
      timeout: const Duration(seconds: 5));
  if (!out.contains('<hierarchy')) {
    out = await runShellCtx('', 'uiautomator dump 2>/dev/null',
        timeout: const Duration(seconds: 5));
    if (!out.contains('<hierarchy')) return null;
  }
  _uiXml = out;
  _uiTime = DateTime.now();
  return out;
}

Future<List<UiNode>> dumpUINodes() async {
  final xml = await dumpUIXMLCached();
  if (xml == null) return const [];
  return parseUINodes(xml);
}

Future<({int w, int h})?> getScreenSize() async {
  final out = await runShellCtx('', 'wm size', timeout: const Duration(seconds: 2));
  final m = RegExp(r'(\d+)x(\d+)').firstMatch(out);
  if (m == null) return null;
  return (w: int.parse(m.group(1)!), h: int.parse(m.group(2)!));
}

Future<String> getForegroundPackage() async {
  final now = DateTime.now();
  if (_fgPkg.isNotEmpty && now.difference(_fgTime) < fgCacheTTL) return _fgPkg;
  final out = await runShellCtx(
      '',
      'cmd activity get-current-activity 2>/dev/null || dumpsys activity activities 2>/dev/null | grep -m1 mResumedActivity',
      timeout: const Duration(seconds: 2));
  final m = RegExp(r'([a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+)/[a-zA-Z0-9_.$]+')
      .firstMatch(out);
  if (m != null) {
    _fgPkg = m.group(1)!;
    _fgTime = DateTime.now();
    return _fgPkg;
  }
  return '';
}

Future<String> doTap(int x, int y) async {
  await runSmartShell('', 'input tap $x $y',
      timeout: const Duration(seconds: 3));
  invalidateUICache();
  invalidateFgCache();
  return '✅ クリック ($x,$y)';
}

List<UiNode> findNodes(List<UiNode> nodes, String text, String resourceID,
    [String klass = '']) {
  final out = <UiNode>[];
  for (final n in nodes) {
    if (text.isNotEmpty &&
        !n.text.contains(text) &&
        !n.contentDesc.contains(text)) {
      continue;
    }
    if (resourceID.isNotEmpty && n.resourceId != resourceID) continue;
    if (klass.isNotEmpty && !n.klass.contains(klass)) continue;
    out.add(n);
  }
  return out;
}

// ------------------------------------------------------------
// 弹窗处理
// ------------------------------------------------------------
const List<String> popupAllowKeywords = [
  '許可', '同意', '常に許可', '常に許可', 'OK', '好', 'OK', 'Ok', 'ok', '我知道',
  '我知道了', '接受', '続行', 'オン', '有効化', '今すぐ', '立即', 'Allow', 'ALLOW',
  'Grant', 'Accept', 'Continue', 'Agree', 'Yes'
];
const List<String> popupDenyKeywords = [
  '拒否', '許可しない', '取消', '稍后', '後で', 'あとで', '不再提示', 'スキップ', '閉じる',
  'Deny', 'Cancel', 'Skip', 'Later', 'No'
];
const List<String> popupCloseKeywords = [
  '閉じる', '取消', '退出', '後で', 'スキップ', '稍后', '×', '✕', '✖', 'x', 'X',
  'Close', 'Skip', 'Later'
];
const List<String> popupCloseIDFragments = [
  'close', 'cancel', 'ic_close', 'btn_close', 'dialog_close', 'iv_close',
  'image_close', 'navigation_close', 'menu_close'
];
const List<String> popupContainerIDFragments = [
  'dialog', 'popup', 'alert', 'modal', 'permission', 'alertdialog',
  'custom_dialog'
];

bool isPopupNode(UiNode n) {
  final idLower = n.resourceId.toLowerCase();
  final clsLower = n.klass.toLowerCase();
  for (final f in popupContainerIDFragments) {
    if (idLower.contains(f)) return true;
  }
  if (clsLower.contains('alertdialog') ||
      clsLower.contains('permissioncontroller') ||
      clsLower.contains('grantpermissions') ||
      clsLower.contains('alertcontroller')) {
    return true;
  }
  return false;
}

bool isActionButton(UiNode n) {
  if (n.clickable) return true;
  final clsLower = n.klass.toLowerCase();
  return clsLower.contains('button') ||
      clsLower.contains('imageview') ||
      clsLower.contains('textview');
}

Future<({List<String> dismissed, int actions})> scanAndDismissPopups(
    String prefer, int maxActions) async {
  final nodes = await dumpUINodes();
  if (nodes.isEmpty) return (dismissed: <String>[], actions: 0);
  var hasPopup = false;
  for (final n in nodes) {
    if (isPopupNode(n)) {
      hasPopup = true;
      break;
    }
  }
  final dismissed = <String>[];
  var actions = 0;

  bool matchKw(String a, String kw) {
    if (a.isEmpty) return false;
    if (a == kw) return true;
    if (a.toLowerCase() == kw.toLowerCase()) return true;
    if (a.contains(kw) && a.length <= kw.length + 4) return true;
    return false;
  }

  Future<bool> pickAndTap(List<String> keywords, String label) async {
    for (final n in nodes) {
      if (!isActionButton(n)) continue;
      final txt = n.text.trim();
      final desc = n.contentDesc.trim();
      for (final kw in keywords) {
        if (matchKw(txt, kw) || matchKw(desc, kw)) {
          await doTap(n.centerX, n.centerY);
          dismissed.add('[$label] 「$txt$desc」(${n.centerX},${n.centerY})');
          actions++;
          await Future.delayed(const Duration(milliseconds: 80));
          return true;
        }
      }
    }
    return false;
  }

  Future<bool> clickCloseIcon() async {
    for (final n in nodes) {
      final idLower = n.resourceId.toLowerCase();
      for (final f in popupCloseIDFragments) {
        if (idLower.contains(f) && n.clickable) {
          await doTap(n.centerX, n.centerY);
          dismissed.add('[閉じるアイコン] id=${n.resourceId} (${n.centerX},${n.centerY})');
          actions++;
          await Future.delayed(const Duration(milliseconds: 80));
          return true;
        }
      }
    }
    return false;
  }

  switch (prefer) {
    case 'allow':
      while (actions < maxActions) {
        if (!await pickAndTap(popupAllowKeywords, '許可')) break;
      }
      break;
    case 'deny':
      while (actions < maxActions) {
        if (!await pickAndTap(popupDenyKeywords, '拒否')) break;
      }
      break;
    case 'cancel':
      while (actions < maxActions) {
        if (!await pickAndTap(popupCloseKeywords, '取消')) break;
      }
      break;
    default:
      while (actions < maxActions) {
        if (await clickCloseIcon()) continue;
        if (await pickAndTap(popupAllowKeywords, '許可')) continue;
        if (await pickAndTap(popupDenyKeywords, '拒否／キャンセル')) continue;
        break;
      }
  }

  if (hasPopup && actions == 0) {
    await runSmartShell('', 'input keyevent 4',
        timeout: const Duration(seconds: 2));
    dismissed.add('[戻るキー]');
    actions++;
  }
  return (dismissed: dismissed, actions: actions);
}

// ------------------------------------------------------------
// 工具 Schema
// ------------------------------------------------------------
Map<String, dynamic> fnTool(
        String name, String desc, Map<String, dynamic> params) =>
    {
      'type': 'function',
      'function': {'name': name, 'description': desc, 'parameters': params},
    };

Map<String, dynamic> str(String desc) =>
    {'type': 'string', 'description': desc};

Map<String, dynamic> integer(String desc) =>
    {'type': 'integer', 'description': desc};

Map<String, dynamic> boolean(String desc) =>
    {'type': 'boolean', 'description': desc};

Map<String, dynamic> objSchema(Map<String, dynamic> props,
    [List<String> required = const []]) {
  final s = <String, dynamic>{'type': 'object', 'properties': props};
  if (required.isNotEmpty) s['required'] = required;
  return s;
}

List<Map<String, dynamic>> buildDsTools() {
  return [
    fnTool('shizuku_status', 'Shizuku の状態を検出します。', objSchema({})),
    fnTool('shizuku_start', 'Shizuku アプリを開きます。', objSchema({})),
    fnTool('shizuku_auto_setup', '★ Shizuku をワンクリックで検出・修復します。', objSchema({})),
    fnTool(
        'shizuku_exec',
        'Shizuku の特権でコマンドを実行します。',
        objSchema({'command': str('命令'), 'timeout': integer('タイムアウト秒数')},
            ['command'])),
    fnTool('shizuku_install_rish', 'rish を自動デプロイします。',
        objSchema({'target_dir': str('対象ディレクトリ')})),
    fnTool('adb_status', 'adb shell 通道の状態を検出します（uid=2000）。',
        objSchema({})),
    fnTool('adb_connect', 'adb 無線デバッグへ再接続します（127.0.0.1:5555）。',
        objSchema({})),
    fnTool(
        'adb_shell',
        'adb shell（uid=2000）でコマンドを実行します。input / am / pm / dumpsys / settings など。',
        objSchema({'command': str('命令'), 'timeout': integer('タイムアウト秒数')},
            ['command'])),
    fnTool(
        'batch_tap',
        '複数のクリックをまとめて実行します。',
        objSchema({
          'points': {
            'type': 'array',
            'description': '座標配列',
            'items': {'type': 'object'}
          },
          'interval_ms': integer('間隔（ミリ秒）'),
        }, [
          'points'
        ])),
    fnTool(
        'batch_swipe',
        '複数のスワイプをまとめて実行します。',
        objSchema({
          'actions': {
            'type': 'array',
            'items': {'type': 'object'}
          }
        }, [
          'actions'
        ])),
    fnTool(
        'batch_command',
        '複数のシェルコマンドをまとめて実行します。',
        objSchema({
          'commands': {
            'type': 'array',
            'items': {'type': 'string'}
          },
          'timeout': integer('合計タイムアウト秒数'),
        }, [
          'commands'
        ])),
    fnTool('smart_wait', '画面が安定するまで待機します。',
        objSchema({'max_ms': integer('最大ミリ秒'), 'stable_ms': integer('安定ミリ秒')})),
    fnTool('screen_hash', '画面の指紋を取得します。', objSchema({})),
    fnTool('ocr_screen', '画面上の文字を OCR で認識します。', objSchema({'lang': str('言語')})),
    fnTool('get_screen_text', '画面の可視テキストをすべて取得します。', objSchema({})),
    fnTool('dismiss_popup', 'ポップアップを自動で閉じます。',
        objSchema({'prefer': str('allow/deny/cancel/auto')})),
    fnTool('auto_dismiss_dialogs', 'ポップアップを連続でクリアします。', objSchema({})),
    fnTool('is_popup_present', 'ポップアップの有無を検出します。', objSchema({})),
    fnTool(
        'wait_for_element',
        '要素の出現を待機します。',
        objSchema({
          'text': str('文本'),
          'resource_id': str('resource-id'),
          'timeout_ms': integer('タイムアウト（ミリ秒）'),
        })),
    fnTool(
        'download_file',
        'ファイルをダウンロードします。',
        objSchema({'url': str('リンク'), 'save_path': str('保存路径')},
            ['url', 'save_path'])),
    fnTool(
        'create_file',
        'ファイルを作成／上書きします。',
        objSchema({'path': str('路径'), 'content': str('内容')},
            ['path', 'content'])),
    fnTool(
        'append_file',
        '追加内容到文件。',
        objSchema({'path': str('路径'), 'content': str('内容')},
            ['path', 'content'])),
    fnTool('read_file', 'ファイルを読み取ります。', objSchema({'path': str('路径')}, ['path'])),
    fnTool('get_file_size', '文件大小。', objSchema({'path': str('路径')}, ['path'])),
    fnTool('list_dir', 'ディレクトリを一覧します。', objSchema({'path': str('路径')})),
    fnTool(
        'execute_command',
        'シェルコマンドを実行します。',
        objSchema({'command': str('命令'), 'timeout': integer('タイムアウト秒数')},
            ['command'])),
    fnTool(
        'run_background',
        '長いタスクをバックグラウンドで実行します。',
        objSchema({'command': str('命令'), 'log_file': str('日志路径')},
            ['command'])),
    fnTool('list_processes', 'プロセスを一覧します。', objSchema({'filter': str('絞り込みキーワード')})),
    fnTool(
        'kill_process',
        'プロセスを終了します。',
        objSchema({'pid': integer('PID'), 'signal': str('信号')}, ['pid'])),
    fnTool(
        'wait_seconds',
        '等待秒数。',
        objSchema({'seconds': integer('秒数'), 'reason': str('原因')}, ['seconds'])),
    fnTool(
        'http_request',
        'HTTP リクエスト。',
        objSchema({
          'method': str('GET/POST/...'),
          'url': str('URL'),
          'headers': {'type': 'object'},
          'body': str('body'),
          'timeout': integer('タイムアウト秒数'),
        }, [
          'url'
        ])),
    fnTool(
        'sqlite_query',
        'SQLite データベースを照会します。',
        objSchema({'db_path': str('路径'), 'sql': str('SQL')}, ['db_path', 'sql'])),
    fnTool(
        'tap',
        'クリック。',
        objSchema({
          'x': integer('X'),
          'y': integer('Y'),
          'text': str('文本'),
          'resource_id': str('resource-id'),
          'index': integer('索引'),
        })),
    fnTool(
        'long_press',
        '長押し。',
        objSchema({
          'x': integer('X'),
          'y': integer('Y'),
          'text': str('文本'),
          'resource_id': str('resource-id'),
          'index': integer('索引'),
          'duration_ms': integer('毫秒'),
        })),
    fnTool(
        'swipe',
        'スワイプ。',
        objSchema({
          'direction': str('up/down/left/right'),
          'start_x': integer('起点 X'),
          'start_y': integer('起点 Y'),
          'end_x': integer('終点 X'),
          'end_y': integer('終点 Y'),
          'duration_ms': integer('時間（ミリ秒）'),
        })),
    fnTool('input_text', 'テキストを入力します。', objSchema({'text': str('文本')}, ['text'])),
    fnTool(
        'key_event',
        'キーを送信します。',
        objSchema({'key': str('キー名'), 'keycode': integer('keycode')})),
    fnTool(
        'find_element',
        'UI ウィジェットを検索します。',
        objSchema({
          'text': str('文本'),
          'resource_id': str('resource-id'),
          'class': str('class'),
          'limit': integer('数量'),
        })),
    fnTool('screenshot', '截屏。', objSchema({'save_path': str('路径')})),
    fnTool('screen_size', '屏幕分辨率。', objSchema({})),
    fnTool('ui_dump', 'UI XML を出力します。', objSchema({})),
    fnTool(
        'start_app',
        '★ アプリを強制起動します（3 秒以内）。',
        objSchema({
          'package': str('包名'),
          'activity': str('Activity'),
          'auto_allow': {'type': 'boolean'},
        }, [
          'package'
        ])),
    fnTool('current_app', '現在のフォアグラウンドアプリ。', objSchema({})),
    fnTool('is_app_running', 'アプリのプロセスを確認します。',
        objSchema({'package': str('包名')}, ['package'])),
    fnTool('force_stop_app', 'アプリを強制停止します。',
        objSchema({'package': str('包名')}, ['package'])),
    fnTool('torch', 'フラッシュライト。', objSchema({'action': str('on/off')}, ['action'])),
    fnTool(
        'camera_photo',
        '拍照。',
        objSchema({'save_path': str('路径'), 'camera_id': integer('カメラ ID')},
            ['save_path'])),
    fnTool('camera_info', 'カメラ情報。', objSchema({})),
    fnTool(
        'volume_set',
        '音量を設定します。',
        objSchema({'stream': str('music/ring/...'), 'volume': integer('音量')},
            ['stream', 'volume'])),
    fnTool('volume_get', '音量を取得します。', objSchema({})),
    fnTool('battery_status', 'バッテリー状態。', objSchema({})),
    fnTool('wifi_info', 'WiFi 信息。', objSchema({})),
    fnTool('wifi_scan', 'WiFi をスキャンします。', objSchema({})),
    fnTool('wifi_enable', 'WiFi をオン／オフします。', objSchema({'action': str('on/off')}, ['action'])),
    fnTool(
        'clipboard',
        'クリップボード。',
        objSchema({'action': str('get/set'), 'text': str('set 時のテキスト')},
            ['action'])),
    fnTool(
        'notify',
        'システム通知。',
        objSchema({'title': str('タイトル'), 'content': str('内容')}, ['title'])),
    fnTool('toast', 'Toast。', objSchema({'text': str('文本')}, ['text'])),
    fnTool('vibrate', 'バイブレーション。', objSchema({'duration_ms': integer('毫秒')})),
    fnTool('tts_speak', 'TTS 読み上げ。', objSchema({'text': str('文本')}, ['text'])),
    fnTool('location', '地理位置。',
        objSchema({'provider': str('gps/network/passive')})),
    fnTool('brightness', '亮度。', objSchema({'value': integer('0-255')}, ['value'])),
    fnTool('list_sensors', 'センサー一覧。', objSchema({})),
    fnTool('read_sensor', 'センサー値を読み取ります。', objSchema({'sensor': str('名')}, ['sensor'])),
    fnTool('fingerprint', '指紋認証。', objSchema({})),
    fnTool(
        'dialog',
        'システムダイアログ。',
        objSchema({
          'input': str('種類'),
          'title': str('タイトル'),
          'hint': str('提示'),
        }, [
          'input'
        ])),
    fnTool('audio_info', 'オーディオ情報。', objSchema({})),
    fnTool(
        'microphone_record',
        '録音。',
        objSchema({'save_path': str('路径'), 'duration_ms': integer('時間')},
            ['save_path'])),
    fnTool('list_packages', '列包名。', objSchema({'filter': str('キーワード')})),
    fnTool('install_apk', '安装 APK。',
        objSchema({'apk_path': str('APK 路径')}, ['apk_path'])),
    fnTool('uninstall_app', 'アンインストール。', objSchema({'package': str('包名')}, ['package'])),
    fnTool(
        'grant_permission',
        '権限を付与します。',
        objSchema({'package': str('包名'), 'permission': str('権限')},
            ['package', 'permission'])),
    fnTool(
        'revoke_permission',
        '権限を取り消します。',
        objSchema({'package': str('包名'), 'permission': str('権限')},
            ['package', 'permission'])),
    fnTool('list_permissions', '権限一覧。',
        objSchema({'package': str('包名')}, ['package'])),
    fnTool(
        'appops_set',
        'AppOps を設定します。',
        objSchema(
            {'package': str('包名'), 'op': str('操作'), 'mode': str('模式')},
            ['package', 'op', 'mode'])),
    fnTool(
        'settings_get',
        'システム設定を読み取ります。',
        objSchema({'namespace': str('system/secure/global'), 'key': str('キー')},
            ['namespace', 'key'])),
    fnTool(
        'settings_put',
        'システム設定を書き込みます。',
        objSchema({
          'namespace': str('system/secure/global'),
          'key': str('キー'),
          'value': str('値'),
        }, [
          'namespace',
          'key',
          'value'
        ])),
    fnTool('open_url', 'URL を開きます。', objSchema({'url': str('URL')}, ['url'])),
    fnTool('open_file', 'ファイルを開きます。', objSchema({'path': str('路径')}, ['path'])),
    fnTool('share_file', '分享文件。', objSchema({'path': str('路径')}, ['path'])),
    fnTool('media_scan', 'メディアスキャン。', objSchema({'path': str('路径')}, ['path'])),
    fnTool(
        'media_player',
        '播放器。',
        objSchema({'action': str('play/pause/stop/toggle/info'), 'file': str('文件')},
            ['action'])),
    fnTool('sms_list', '短信列表。',
        objSchema({'limit': integer('条数'), 'type': str('all/inbox/sent/draft')})),
    fnTool(
        'sms_send',
        'SMS を送信します。',
        objSchema({'number': str('番号'), 'text': str('内容')}, ['number', 'text'])),
    fnTool('contact_list', '連絡先。', objSchema({'limit': integer('条数')})),
    fnTool('call_log', '通話履歴。', objSchema({'limit': integer('条数')})),
    fnTool(
        'termux_download',
        'システムダウンローダー。',
        objSchema({'url': str('リンク'), 'description': str('描述')}, ['url'])),
    fnTool(
        'web_search',
        'DeepSeek 公式のウェブ検索（構造化された検索結果を返します）。',
        objSchema({
          'query': str('検索キーワード（1〜128 文字）'),
          'count': integer('返回条数(1-50)'),
          'need_content': boolean('ページ本文を返すかどうか'),
        }, [
          'query'
        ])),
    fnTool('fetch', 'DeepSeek 公式のウェブページ取得（Markdown 本文を返します）。',
        objSchema({'url': str('ページ URL')}, ['url'])),
    fnTool(
        'cosplay_show',
        '現在アクティブなキャラクターのカードを表示します。id を指定すると該当キャラクターのカードを表示します。キャラクター設定・口調・行動指針の確認用（Cosplay スイッチがオフでもプレビュー可能）。',
        objSchema({'id': str('キャラクター id。省略時は現在アクティブなキャラクターを返します。')})),
    fnTool('cosplay_list', 'キャラクターライブラリの全キャラクターと有効状態を一覧します（ライブラリ管理用。スイッチがオフでも使用可能）。',
        objSchema({})),
    fnTool(
        'cosplay_switch',
        '現在演じているキャラクターを切り替えます（キャラクター id）。id に null を渡すとロールプレイを終了し、既定の身分に戻ります。Cosplay スイッチがオンのときのみ使用可能。',
        objSchema({'id': str('対象キャラクター id。文字列 "null" を渡すとロールプレイを終了します。')}, ['id'])),
    fnTool(
        'cosplay_upsert',
        'キャラクターを作成または更新します（ライブラリ管理用。スイッチがオフでも使用可能）。id を省略すると新規作成（name から id を生成）、id を指定すると既存キャラクターを更新します。フィールドは Tavern（SillyTavern）v2 キャラクターカードに準拠します。ユーザーはいつでも任意のキャラクターをカスタマイズできます。',
        objSchema({
          'id': str('既有角色 id；省略表示新建。'),
          'name': str('キャラクター表示名。'),
          'emoji': str('アイコン文字（例: 🐋）。'),
          'system_prompt': str('persona の先頭にそのまま挿入される指示ブロック（例: [PERSONA_LOAD] 形式）。'),
          'description': str('身分と背景設定（私は誰か）。'),
          'personality': str('性格の核心と層。'),
          'style': str('話し方のスタイル（どう話すか）。'),
          'rules': str('行動指針（すべきこと／すべきでないこと）。'),
          'behavior': str('行動パターン／私的なやり取り。'),
          'scenario': str('シチュエーション／世界観／関係設定。'),
          'first_mes': str('オープニングのセリフ。'),
          'mes_example': str('会話例（few-shot）。'),
        }, [
          'name'
        ])),
    fnTool('cosplay_remove', 'キャラクターライブラリから 1 件削除します（ライブラリ管理用。スイッチがオフでも使用可能）。',
        objSchema({'id': str('削除するキャラクターの id。')}, ['id'])),
    // ---- 虚拟屏幕（专属：所有 UI 操作在副屏执行，不抢主屏焦点） ----
    fnTool('vd_status', '虚拟屏幕状态（displayId / 规格 / 是否就绪）。', objSchema({})),
    fnTool(
        'vd_create',
        '创建虚拟屏幕（副屏）。之后可用 vd_* 工具在该屏操作，主屏可继续刷视频/打游戏不被抢焦点。',
        objSchema({
          'width': integer('宽，默认 720'),
          'height': integer('高，默认 1280'),
          'dpi': integer('密度，默认 320'),
        })),
    fnTool('vd_destroy', '关闭并移除虚拟屏幕。', objSchema({})),
    fnTool(
        'vd_launch',
        '在虚拟屏幕上启动应用：包名 / 包名+Activity / https URL。',
        objSchema({
          'target': str('包名，如 com.android.settings；或 pkg/.Act；或 https URL')
        }, [
          'target'
        ])),
    fnTool('vd_tap', '在虚拟屏幕上点击。',
        objSchema({'x': integer('X'), 'y': integer('Y')}, ['x', 'y'])),
    fnTool(
        'vd_swipe',
        '在虚拟屏幕上滑动。',
        objSchema({
          'x1': integer('起点X'),
          'y1': integer('起点Y'),
          'x2': integer('终点X'),
          'y2': integer('终点Y'),
          'duration_ms': integer('时长毫秒，默认 300'),
        }, [
          'x1',
          'y1',
          'x2',
          'y2'
        ])),
    fnTool('vd_key', '在虚拟屏幕上发送按键（keycode，如 4=返回）。',
        objSchema({'keycode': integer('keycode')}, ['keycode'])),
    fnTool('vd_text', '在虚拟屏幕上输入文本（含中文时走剪贴板粘贴）。',
        objSchema({'text': str('文本')}, ['text'])),
    fnTool('vd_screenshot', '抓取虚拟屏幕截图。',
        objSchema({'save_path': str('保存路径，默认 /sdcard/.ds_vd_shot_<ts>.png')})),
    fnTool(
        'vd_ocr',
        '对虚拟屏幕画面做 OCR（uiautomator 不支持副屏，只能走截图 OCR）。',
        objSchema({'lang': str('语言，默认 chi_sim+eng')})),
    fnTool(
        'vd_observe',
        '汇总虚拟屏幕感知：状态 + 截图 + OCR。',
        objSchema({
          'ocr': boolean('是否同时 OCR，默认 true'),
          'lang': str('OCR 语言'),
        })),
  ];
}

// ------------------------------------------------------------
// 工具执行实现
// ------------------------------------------------------------
Future<String> execToolshizukuDisabled() async {
  return '🚫 Shizuku 権限は取り消し済みのため、AI にシステム権限がありません';
}

Future<String> execToolBatchTap(Map<String, dynamic> args) async {
  final pointsRaw = asList(args['points']);
  if (pointsRaw.isEmpty) return 'points は必須です';
  final intervalMs = intArgDefault(args, 'interval_ms', 100);

  final points = <({int x, int y, String desc})>[];
  for (final pRaw in pointsRaw) {
    final pMap = asMap(pRaw);
    final x = intArg(pMap, 'x');
    final y = intArg(pMap, 'y');
    if (x != null && y != null) {
      points.add((x: x, y: y, desc: '($x,$y)'));
      continue;
    }
    final text = mStr(pMap, 'text');
    final rid = mStr(pMap, 'resource_id');
    if (text.isEmpty && rid.isEmpty) continue;
    final nodes = await dumpUINodes();
    final matched = findNodes(nodes, text, rid);
    if (matched.isNotEmpty) {
      final n = matched.first;
      points.add((
        x: n.centerX,
        y: n.centerY,
        desc: '「$text」(${n.centerX},${n.centerY})'
      ));
    }
  }
  if (points.isEmpty) return '有効なクリック座標がありません';

  final cmds = <String>[];
  for (var i = 0; i < points.length; i++) {
    cmds.add('input tap ${points[i].x} ${points[i].y}');
    if (i < points.length - 1 && intervalMs > 0) {
      cmds.add('sleep ${(intervalMs / 1000.0).toStringAsFixed(2)}');
    }
  }
  await runSmartShell('', cmds.join('; '),
      timeout: Duration(seconds: points.length * 2 + 5));
  invalidateUICache();
  invalidateFgCache();
  final sb = StringBuffer('✅ ${points.length} 点を一括クリック:\n');
  for (final p in points) {
    sb.write('  ${p.desc}\n');
  }
  return sb.toString();
}

Future<String> execToolBatchSwipe(Map<String, dynamic> args) async {
  final actionsRaw = asList(args['actions']);
  if (actionsRaw.isEmpty) return 'actions は必須です';
  final cmds = <String>[];
  final descList = <String>[];
  for (final aRaw in actionsRaw) {
    final aMap = asMap(aRaw);
    final dir = mStr(aMap, 'direction');
    var dur = intArgDefault(aMap, 'duration_ms', defaultSwipeDur);
    if (dur < 50) dur = 50;
    if (dir.isNotEmpty) {
      final size = await getScreenSize();
      if (size == null) continue;
      final w = size.w, h = size.h;
      final cx = w ~/ 2, cy = h ~/ 2;
      int x1 = 0, y1 = 0, x2 = 0, y2 = 0;
      switch (dir.toLowerCase()) {
        case 'up':
          x1 = cx;
          y1 = (h * 0.75).toInt();
          x2 = cx;
          y2 = (h * 0.25).toInt();
          break;
        case 'down':
          x1 = cx;
          y1 = (h * 0.25).toInt();
          x2 = cx;
          y2 = (h * 0.75).toInt();
          break;
        case 'left':
          x1 = (w * 0.85).toInt();
          y1 = cy;
          x2 = (w * 0.15).toInt();
          y2 = cy;
          break;
        case 'right':
          x1 = (w * 0.15).toInt();
          y1 = cy;
          x2 = (w * 0.85).toInt();
          y2 = cy;
          break;
      }
      cmds.add('input swipe $x1 $y1 $x2 $y2 $dur');
      descList.add(dir);
    } else {
      final x1 = intArg(aMap, 'start_x');
      final y1 = intArg(aMap, 'start_y');
      final x2 = intArg(aMap, 'end_x');
      final y2 = intArg(aMap, 'end_y');
      if (x1 != null && y1 != null && x2 != null && y2 != null) {
        cmds.add('input swipe $x1 $y1 $x2 $y2 $dur');
        descList.add('($x1,$y1)→($x2,$y2)');
      }
    }
  }
  if (cmds.isEmpty) return '有効なスワイプがありません';
  await runSmartShell('', cmds.join('; '),
      timeout: Duration(seconds: cmds.length * 3 + 5));
  invalidateUICache();
  return '✅ ${cmds.length} 回の一括スワイプ: ${descList.join(', ')}';
}

Future<String> execToolBatchCommand(Map<String, dynamic> args) async {
  final cmdsRaw = asList(args['commands']);
  final cmds = <String>[];
  for (final c in cmdsRaw) {
    if (c is String && c.trim().isNotEmpty) cmds.add(c);
  }
  if (cmds.isEmpty) return '无有效命令';
  var timeout = intArgDefault(args, 'timeout', 60);
  if (timeout <= 0) timeout = 60;
  final r = await runSmartShell(dsWorkspaceDir, cmds.join('; '),
      timeout: Duration(seconds: timeout));
  var out = r.out;
  if (out.length > 64 * 1024) out = '${out.substring(0, 64 * 1024)}\n...[截断]';
  if (r.code != 0 && out.isEmpty) return '実行に失敗しました（終了コード ${r.code}）';
  return '${cmds.length} 件のコマンドを一括実行:\n$out';
}

Future<String> execToolSmartWait(Map<String, dynamic> args) async {
  var maxMs = intArgDefault(args, 'max_ms', 3000);
  final stableMs = intArgDefault(args, 'stable_ms', 300);
  if (maxMs <= 0) maxMs = 3000;
  if (maxMs > 5000) maxMs = 5000;

  final start = DateTime.now();
  final deadline = start.add(Duration(milliseconds: maxMs));
  String lastXML = '';
  var stableStart = DateTime.now();
  var stableReached = false;

  while (DateTime.now().isBefore(deadline)) {
    invalidateUICache();
    final xml = await dumpUIXMLCached();
    if (xml == null) {
      await Future.delayed(const Duration(milliseconds: 100));
      continue;
    }
    if (xml == lastXML) {
      if (DateTime.now().difference(stableStart).inMilliseconds >= stableMs) {
        stableReached = true;
        break;
      }
    } else {
      lastXML = xml;
      stableStart = DateTime.now();
    }
    await Future.delayed(const Duration(milliseconds: 100));
  }
  final elapsed = DateTime.now().difference(start).inMilliseconds;
  if (stableReached) return '✅ 画面が安定しました（${elapsed}ms）';
  return '⚠️ 画面が安定しません。${elapsed}ms 待機しました';
}

Future<String> execToolScreenHash() async {
  invalidateUICache();
  final xml = await dumpUIXMLCached();
  if (xml == null) return 'UI XML を取得できませんでした';
  var h = 0;
  var i = 0;
  for (final c in xml.runes) {
    if (i++ > 200) break;
    h = (h * 31 + c) & 0x7FFFFFFF;
  }
  return '画面指紋: $h（XML 長 ${xml.length}）';
}

Future<String> execToolGetScreenText() async {
  final nodes = await dumpUINodes();
  final sb = StringBuffer();
  final seen = <String>{};
  for (final n in nodes) {
    var t = n.text.trim();
    if (t.isEmpty) t = n.contentDesc.trim();
    if (t.isEmpty || seen.contains(t)) continue;
    seen.add(t);
    sb.write('$t\n');
  }
  if (sb.isEmpty) return '(画面に可視テキストなし)';
  var result = sb.toString();
  if (result.length > 32 * 1024) {
    result = '${result.substring(0, 32 * 1024)}\n...[截断]';
  }
  return result;
}

Future<String> execToolOCRScreen(Map<String, dynamic> args) async {
  var lang = mStr(args, 'lang');
  if (lang.isEmpty) lang = 'chi_sim+eng';
  final which = await runProcess('sh', ['-c', 'command -v tesseract']);
  final tessPath = which.out.trim();
  if (tessPath.isEmpty) return 'tesseract がインストールされていません。実行してください: pkg install tesseract';

  final tmpImg =
      '/sdcard/.ds_ocr_${DateTime.now().microsecondsSinceEpoch}.png';
  await runSmartShell('', 'screencap -p $tmpImg',
      timeout: const Duration(seconds: 15));
  if (!File(tmpImg).existsSync()) return 'スクリーンショットファイルが存在しません: $tmpImg';
  try {
    final langsOut =
        (await runProcess(tessPath, ['--list-langs'], timeout: const Duration(seconds: 8)))
            .out;
    if (langsOut.isNotEmpty) {
      final requested = lang.split('+');
      final available = <String>[];
      for (var l in requested) {
        l = l.trim();
        if (l.isNotEmpty && langsOut.contains(l)) available.add(l);
      }
      lang = available.isNotEmpty ? available.join('+') : 'eng';
    }
    final r = await runProcess(tessPath, [tmpImg, 'stdout', '-l', lang],
        timeout: const Duration(seconds: 60));
    if (r.code != 0) return 'OCR に失敗しました: ${r.out.trim()}';
    final result = r.out.trim();
    if (result.isEmpty) return 'OCR 認識結果: （画面に文字がないか、認識結果が空です）';
    return 'OCR 認識結果:\n$result';
  } finally {
    try {
      File(tmpImg).deleteSync();
    } catch (_) {}
  }
}

Future<String> execToolSQLiteQuery(Map<String, dynamic> args) async {
  final dbPath = mStr(args, 'db_path');
  final sql = mStr(args, 'sql');
  if (dbPath.isEmpty || sql.isEmpty) return 'db_path と sql は必須です';
  final which = await runProcess('sh', ['-c', 'command -v sqlite3']);
  if (which.out.trim().isEmpty) return '未安装 sqlite3。安装: pkg install sqlite';
  final r = await runSmartShell(
      '', 'sqlite3 ${shellQuote(dbPath)} ${shellQuote(sql)}',
      timeout: const Duration(seconds: 30));
  var out = r.out;
  if (out.length > 64 * 1024) out = '${out.substring(0, 64 * 1024)}\n...[截断]';
  return out;
}

Future<String> execToolTap(Map<String, dynamic> args) async {
  final x = intArg(args, 'x');
  final y = intArg(args, 'y');
  final text = mStr(args, 'text');
  final rid = mStr(args, 'resource_id');
  var idx = intArgDefault(args, 'index', 0);
  if (x != null && y != null) return doTap(x, y);
  if (text.isEmpty && rid.isEmpty) return '(x,y) または text または resource_id を指定してください';

  var nodes = await dumpUINodes();
  var matched = findNodes(nodes, text, rid);
  if (matched.isEmpty) {
    invalidateUICache();
    nodes = await dumpUINodes();
    matched = findNodes(nodes, text, rid);
  }
  if (matched.isEmpty) return '未找到控件 (text="$text", id="$rid")';
  if (idx < 0 || idx >= matched.length) idx = 0;
  return doTap(matched[idx].centerX, matched[idx].centerY);
}

Future<String> execToolLongPress(Map<String, dynamic> args) async {
  final x = intArg(args, 'x');
  final y = intArg(args, 'y');
  final text = mStr(args, 'text');
  final rid = mStr(args, 'resource_id');
  var idx = intArgDefault(args, 'index', 0);
  var dur = intArgDefault(args, 'duration_ms', defaultLongPressDur);
  if (dur < 300) dur = 300;
  if (x != null && y != null) {
    await runSmartShell('', 'input swipe $x $y $x $y $dur',
        timeout: Duration(milliseconds: dur + 3000));
    invalidateUICache();
    return '✅ 長押し ($x,$y) ${dur}ms';
  }
  if (text.isEmpty && rid.isEmpty) return '(x,y) または text または resource_id を指定してください';
  final nodes = await dumpUINodes();
  final matched = findNodes(nodes, text, rid);
  if (matched.isEmpty) return '未找到控件';
  if (idx < 0 || idx >= matched.length) idx = 0;
  final n = matched[idx];
  await runSmartShell('', 'input swipe ${n.centerX} ${n.centerY} ${n.centerX} ${n.centerY} $dur',
      timeout: Duration(milliseconds: dur + 3000));
  invalidateUICache();
  return '✅ 「$text」を長押し (${n.centerX},${n.centerY}) ${dur}ms';
}

Future<String> execToolSwipe(Map<String, dynamic> args) async {
  var dur = intArgDefault(args, 'duration_ms', defaultSwipeDur);
  if (dur < 50) dur = 50;
  final dir = mStr(args, 'direction').trim().toLowerCase();
  int x1 = 0, y1 = 0, x2 = 0, y2 = 0;
  if (dir.isNotEmpty) {
    final size = await getScreenSize();
    if (size == null) return '画面サイズを取得できません';
    final w = size.w, h = size.h;
    final cx = w ~/ 2, cy = h ~/ 2;
    switch (dir) {
      case 'up':
        x1 = cx;
        y1 = (h * 0.75).toInt();
        x2 = cx;
        y2 = (h * 0.25).toInt();
        break;
      case 'down':
        x1 = cx;
        y1 = (h * 0.25).toInt();
        x2 = cx;
        y2 = (h * 0.75).toInt();
        break;
      case 'left':
        x1 = (w * 0.85).toInt();
        y1 = cy;
        x2 = (w * 0.15).toInt();
        y2 = cy;
        break;
      case 'right':
        x1 = (w * 0.15).toInt();
        y1 = cy;
        x2 = (w * 0.85).toInt();
        y2 = cy;
        break;
      default:
        return 'direction 只能是 up/down/left/right';
    }
  } else {
    final a = intArg(args, 'start_x');
    final b = intArg(args, 'start_y');
    final c = intArg(args, 'end_x');
    final d = intArg(args, 'end_y');
    if (a == null || b == null || c == null || d == null) {
      return 'direction または完全な座標が必要です';
    }
    x1 = a;
    y1 = b;
    x2 = c;
    y2 = d;
  }
  await runSmartShell('', 'input swipe $x1 $y1 $x2 $y2 $dur',
      timeout: Duration(milliseconds: dur + 5000));
  invalidateUICache();
  return '✅ スワイプ ($x1,$y1)→($x2,$y2) ${dur}ms';
}

Future<String> execToolInputText(Map<String, dynamic> args) async {
  final text = mStr(args, 'text');
  if (text.isEmpty) return 'text は必須です';
  final hasNonASCII = text.runes.any((r) => r > 127);

  if (hasNonASCII) {
    // 方案 A：ADBKeyboard 广播（中文最可靠）
    final pkgs = await runSmartShell('', 'pm list packages | grep com.android.adbkeyboard',
        timeout: const Duration(seconds: 3));
    if (pkgs.out.contains('com.android.adbkeyboard')) {
      await runSmartShell(
          '', 'am broadcast -a ADB_INPUT_TEXT --es msg ${shellQuote(text)}',
          timeout: const Duration(seconds: 15));
      invalidateUICache();
      return '✅ ADBKeyboard 経由で入力しました: $text';
    }
    // 方案 B：剪贴板 + 粘贴キー
    await runTermuxAPI(const Duration(seconds: 5), 'termux-clipboard-set', [text]);
    await Future.delayed(const Duration(milliseconds: 120));
    final r = await runSmartShell('', 'input keyevent 279',
        timeout: const Duration(seconds: 10));
    if (r.code == 0) {
      invalidateUICache();
      return '✅ クリップボードから貼り付けました: $text';
    }
    // 方案 C：input text 兜底
    final escaped = text.replaceAll(' ', '%s');
    await runSmartShell('', 'input text ${shellQuote(escaped)}',
        timeout: const Duration(seconds: 15));
    invalidateUICache();
    return '⚠️ input text を試しました（中国語は反映されない可能性があります）: $text';
  }

  final escaped = text.replaceAll(' ', '%s');
  final r = await runSmartShell('', 'input text ${shellQuote(escaped)}',
      timeout: const Duration(seconds: 15));
  if (r.code != 0 && r.out.isEmpty) return '入力に失敗しました';
  invalidateUICache();
  return '✅ 入力: $text';
}

const Map<String, int> keyMap = {
  'home': 3, 'back': 4, 'call': 5, 'end_call': 6,
  'volume_up': 24, 'volume_down': 25, 'power': 26, 'camera': 27,
  'clear': 28, 'menu': 82, 'enter': 66, 'delete': 67,
  'tab': 61, 'space': 62, 'escape': 111, 'forward_del': 112,
  'page_up': 92, 'page_down': 93, 'recents': 187, 'app_switch': 187,
  'wakeup': 224, 'sleep': 223, 'paste': 279, 'copy': 278, 'cut': 277,
  'select_all': 289, 'media_play_pause': 85, 'media_next': 87, 'media_prev': 88,
};

Future<String> sendKeyEvent(int code) async {
  await runSmartShell('', 'input keyevent $code',
      timeout: const Duration(seconds: 3));
  invalidateUICache();
  invalidateFgCache();
  return '✅ keyevent $code';
}

Future<String> execToolKeyEvent(Map<String, dynamic> args) async {
  final kc = intArg(args, 'keycode');
  if (kc != null) return sendKeyEvent(kc);
  final k = mStr(args, 'key').trim().toLowerCase();
  if (k.isEmpty) return '需要 key 或 keycode';
  final code = keyMap[k];
  if (code == null) return '不明なキーです: $k';
  return sendKeyEvent(code);
}

Future<String> execToolStartApp(Map<String, dynamic> args) async {
  final pkg = mStr(args, 'package').trim();
  if (pkg.isEmpty) return 'package は必須です';
  final r = await runSmartShell(
      '',
      'am start -a android.intent.action.MAIN '
      '-c android.intent.category.LAUNCHER -p $pkg',
      timeout: const Duration(seconds: 6));
  invalidateFgCache();
  final fg = await getForegroundPackage();
  if (fg == pkg) return '✅ $pkg を起動しました（adb shell / uid=2000）';
  final low = r.out.toLowerCase();
  if (low.contains('error') ||
      low.contains('does not exist') ||
      low.contains('unable to resolve') ||
      low.contains('exception')) {
    return '❌ $pkg の起動に失敗しました: ${r.out.trim()}';
  }
  if (!adbChannelReady()) {
    return '⚠️ adb shell 通道がオフラインです。Termux で ddsh/adb_up.sh を実行してください（${adbLastError()}）';
  }
  return '⚠️ am start は送信しましたが、前面が $pkg になっていません'
      '（現在: ${fg.isEmpty ? '不明' : fg}）\n${r.out.trim()}';
}

Future<String> execToolCurrentApp() async {
  final pkg = await getForegroundPackage();
  if (pkg.isEmpty) return '⚠️ フォアグラウンドアプリを取得できません';
  return '現在のフォアグラウンドアプリ: $pkg';
}

Future<String> execToolIsAppRunning(Map<String, dynamic> args) async {
  final pkg = mStr(args, 'package');
  if (pkg.isEmpty) return 'package は必須です';
  final r = await runSmartShell('', 'pidof ${shellQuote(pkg)}',
      timeout: const Duration(seconds: 3));
  final out = r.out.trim();
  if (out.isEmpty) return '❌ $pkg は実行されていません';
  return '✅ $pkg は実行中 PID: $out';
}

Future<String> execToolForceStopApp(Map<String, dynamic> args) async {
  final pkg = mStr(args, 'package');
  if (pkg.isEmpty) return 'package は必須です';
  final r = await runSmartShell('', 'am force-stop ${shellQuote(pkg)}',
      timeout: const Duration(seconds: 3));
  invalidateFgCache();
  if (r.code != 0 && r.out.isEmpty) return '強制停止に失敗しました: ${r.out}';
  return '✅ $pkg を強制停止しました';
}

Future<String> execToolDismissPopup(Map<String, dynamic> args) async {
  var prefer = mStr(args, 'prefer').trim().toLowerCase();
  if (prefer.isEmpty) prefer = 'auto';
  final r = await scanAndDismissPopups(prefer, 5);
  if (r.actions == 0) return '✅ ポップアップは検出されませんでした';
  return '✅ ${r.actions} 件のポップアップを閉じました:\n${r.dismissed.join('\n')}';
}

Future<String> execToolAutoDismissDialogs() async {
  var total = 0;
  final all = <String>[];
  for (var round = 0; round < 5; round++) {
    final r = await scanAndDismissPopups('auto', 5);
    if (r.actions == 0) break;
    total += r.actions;
    all.addAll(r.dismissed);
    await Future.delayed(const Duration(milliseconds: 120));
  }
  if (total == 0) return '✅ 画面はクリーンです';
  return '✅ $total 件のポップアップをクリアしました:\n${all.join('\n')}';
}

Future<String> execToolIsPopupPresent() async {
  final nodes = await dumpUINodes();
  final popupNodes = <String>[];
  for (final n in nodes) {
    if (isPopupNode(n)) {
      final txt = n.text.isEmpty ? n.contentDesc : n.text;
      popupNodes.add(
          '  id=${n.resourceId} class=${n.klass} text="${truncate(txt, 40)}"');
    }
  }
  if (popupNodes.isEmpty) return '✅ ポップアップなし';
  return '🔍 ${popupNodes.length} 件のポップアップコンテナを検出:\n${popupNodes.join('\n')}';
}

Future<String> execToolWaitForElement(Map<String, dynamic> args) async {
  final text = mStr(args, 'text');
  final rid = mStr(args, 'resource_id');
  if (text.isEmpty && rid.isEmpty) return 'text または resource_id を指定してください';
  var timeoutMs = intArgDefault(args, 'timeout_ms', 2000);
  if (timeoutMs <= 0) timeoutMs = 2000;
  if (timeoutMs > 3000) timeoutMs = 3000;

  final start = DateTime.now();
  final deadline = start.add(Duration(milliseconds: timeoutMs));
  var tries = 0;
  while (DateTime.now().isBefore(deadline)) {
    invalidateUICache();
    final nodes = await dumpUINodes();
    final matched = findNodes(nodes, text, rid);
    if (matched.isNotEmpty) {
      final n = matched.first;
      return '✅ 找到 (${tries + 1} 次, ${DateTime.now().difference(start).inMilliseconds}ms) '
          'text="${n.text}" id=${n.resourceId} center=(${n.centerX},${n.centerY})';
    }
    tries++;
    await Future.delayed(const Duration(milliseconds: 100));
  }
  return '❌ ${timeoutMs}ms 内未找到 (text="$text" id="$rid")';
}

Future<String> execToolFindElement(Map<String, dynamic> args) async {
  final text = mStr(args, 'text');
  final rid = mStr(args, 'resource_id');
  final klass = mStr(args, 'class');
  var limit = intArgDefault(args, 'limit', 20);
  if (limit <= 0) limit = 20;
  final nodes = await dumpUINodes();
  final matched = findNodes(nodes, text, rid, klass);
  if (matched.isEmpty) return '一致するものが見つかりません。現在 ${nodes.length} 個のノード。';
  final sb = StringBuffer('${matched.length} 件見つかりました（先頭 $limit 件を表示）:\n');
  for (var i = 0; i < matched.length && i < limit; i++) {
    final n = matched[i];
    sb.write('#$i text="${n.text}" desc="${n.contentDesc}" id="${n.resourceId}" '
        'class=${n.klass} center=(${n.centerX},${n.centerY}) clickable=${n.clickable}\n');
  }
  return sb.toString();
}

Future<String> execToolScreenshot(Map<String, dynamic> args) async {
  var savePath = mStr(args, 'save_path');
  if (savePath.isEmpty) {
    savePath =
        'screenshot_${DateTime.now().millisecondsSinceEpoch ~/ 1000}.png';
  }
  final absPath = resolveToolPath(savePath);
  final dir = absPath.substring(0, absPath.lastIndexOf('/'));
  ensureDir(dir);
  // adb shell（uid=2000）は Termux 私有ディレクトリへ書き込めないため、
  // /sdcard へ一時出力してから Termux 側でコピーする。
  final tmp = '/sdcard/.ds_shot_${DateTime.now().microsecondsSinceEpoch}.png';
  await runSmartShell('', 'screencap -p $tmp',
      timeout: const Duration(seconds: 10));
  var copied = false;
  try {
    if (File(tmp).existsSync()) {
      File(tmp).copySync(absPath);
      copied = true;
    }
  } catch (_) {}
  try {
    if (File(tmp).existsSync()) File(tmp).deleteSync();
  } catch (_) {}
  if (!copied) {
    await runSmartShell('', 'screencap -p ${shellQuote(absPath)}',
        timeout: const Duration(seconds: 8));
  }
  var size = 0;
  try {
    size = File(absPath).lengthSync();
  } catch (_) {}
  if (size == 0) {
    return '⚠️ スクリーンショットを取得できませんでした'
        '（adb 状態: ${adbChannelReady() ? 'ONLINE' : 'OFFLINE ${adbLastError()}'}）';
  }
  return '✅ スクリーンショット: $absPath ($size バイト)';
}

Future<String> execToolScreenSize() async {
  final s = await getScreenSize();
  if (s == null) return '画面サイズを取得できません';
  return '屏幕: ${s.w} x ${s.h}';
}

Future<String> execToolUIDump() async {
  invalidateUICache();
  final xml = await dumpUIXMLCached();
  if (xml == null) return 'UI XML を取得できませんでした';
  if (xml.length > 200 * 1024) {
    return '${xml.substring(0, 200 * 1024)}\n...[截断]';
  }
  return xml;
}

// ------------------------------------------------------------
// 文件 / 网络
// ------------------------------------------------------------
Future<String> execToolDownloadFile(Map<String, dynamic> args) async {
  final rawURL = mStr(args, 'url');
  final savePath = mStr(args, 'save_path');
  if (rawURL.isEmpty || savePath.isEmpty) return 'url と save_path は必須です';
  final absPath = resolveToolPath(savePath);
  ensureDir(absPath.substring(0, absPath.lastIndexOf('/')));
  final r = await runProcess('sh', [
    '-c',
    'curl -L --fail --silent --show-error -A "Mozilla/5.0 DeepSeekTool/2.0" -o ${shellQuote(absPath)} ${shellQuote(rawURL)}'
  ], timeout: const Duration(seconds: 600));
  if (r.code != 0) return 'ダウンロードに失敗しました: ${r.out}';
  var n = 0;
  try {
    n = File(absPath).lengthSync();
  } catch (_) {}
  return '✅ ダウンロード $absPath ($n バイト, ${(n / 1024 / 1024).toStringAsFixed(2)} MB)';
}

Future<String> execToolCreateFile(Map<String, dynamic> args) async {
  final p = mStr(args, 'path');
  final content = mStr(args, 'content');
  if (p.isEmpty) return 'path は必須です';
  final absPath = resolveToolPath(p);
  ensureDir(absPath.substring(0, absPath.lastIndexOf('/')));
  if (!writeTextFile(absPath, content)) return '写入失败';
  return '✅ 作成 $absPath (${utf8.encode(content).length} バイト)';
}

Future<String> execToolAppendFile(Map<String, dynamic> args) async {
  final p = mStr(args, 'path');
  final content = mStr(args, 'content');
  if (p.isEmpty || content.isEmpty) return 'path と content は必須です';
  final absPath = resolveToolPath(p);
  ensureDir(absPath.substring(0, absPath.lastIndexOf('/')));
  try {
    File(absPath).writeAsStringSync(content, mode: FileMode.append);
    final total = File(absPath).lengthSync();
    return '✅ ${utf8.encode(content).length} バイトを追記しました。現在 $total バイト';
  } catch (e) {
    return '追記に失敗しました: $e';
  }
}

Future<String> execToolReadFile(Map<String, dynamic> args) async {
  final p = mStr(args, 'path');
  if (p.isEmpty) return 'path は必須です';
  try {
    final bytes = File(resolveToolPath(p)).readAsBytesSync();
    const max = 32 * 1024 * 1024;
    if (bytes.length > max) {
      return '${utf8.decode(bytes.sublist(0, max), allowMalformed: true)}\n...[截断]';
    }
    return utf8.decode(bytes, allowMalformed: true);
  } catch (e) {
    return '読み取りに失敗しました: $e';
  }
}

Future<String> execToolGetFileSize(Map<String, dynamic> args) async {
  final p = mStr(args, 'path');
  if (p.isEmpty) return 'path は必須です';
  final absPath = resolveToolPath(p);
  try {
    final size = File(absPath).lengthSync();
    return '📄 $absPath\n$size バイト (${(size / 1024).toStringAsFixed(2)} KB / '
        '${(size / 1024 / 1024).toStringAsFixed(2)} MB)';
  } catch (e) {
    return 'サイズ取得に失敗しました: $e';
  }
}

Future<String> execToolListDir(Map<String, dynamic> args) async {
  final p = mStr(args, 'path');
  final absPath = resolveToolPath(p);
  try {
    final entries = Directory(absPath).listSync();
    if (entries.isEmpty) return 'ディレクトリ $absPath は空です';
    final sb = StringBuffer('ディレクトリ: $absPath\n');
    for (final e in entries) {
      final name = e.uri.pathSegments.last;
      var size = 0;
      var kind = '📄';
      if (e is Directory) {
        kind = '📁';
      } else {
        try {
          size = FileStat.statSync(e.path).size;
        } catch (_) {}
      }
      sb.write('$kind $name ($size)\n');
    }
    return sb.toString();
  } catch (e) {
    return 'ディレクトリ一覧に失敗しました: $e';
  }
}

Future<String> execToolExecuteCommand(Map<String, dynamic> args) async {
  final cmdStr = mStr(args, 'command');
  if (cmdStr.trim().isEmpty) return 'command は必須です';
  var timeout = intArgDefault(args, 'timeout', defaultCmdTimeout);
  if (timeout <= 0) timeout = defaultCmdTimeout;
  if (timeout > maxCmdTimeout) timeout = maxCmdTimeout;

  final r = await runSmartShell(dsWorkspaceDir, cmdStr,
      timeout: Duration(seconds: timeout));
  var out = r.out;
  var prefix = '';
  if (containsPermissionError(out)) {
    prefix = '⚠️ [adbd 権限不足] ';
    out += '\n\n💡 ヒント: このコマンドは adb shell（uid=2000）でも拒否されました。'
        'adb 通道の状態は adb_status で確認できます。';
  }
  if (r.code != 0 && out.isEmpty) {
    return '${prefix}実行に失敗しました（終了コード ${r.code}）';
  }
  if (out.isEmpty) out = '(成功、出力なし)';
  if (out.length > 64 * 1024) out = '${out.substring(0, 64 * 1024)}\n...[截断]';
  return '$prefix$out';
}

Future<String> execToolRunBackground(Map<String, dynamic> args) async {
  final cmdStr = mStr(args, 'command');
  if (cmdStr.trim().isEmpty) return 'command は必須です';
  var logFile = mStr(args, 'log_file');
  if (logFile.isEmpty) {
    logFile = '$dsWorkspaceDir/bg_${DateTime.now().microsecondsSinceEpoch}.log';
  } else {
    logFile = resolveToolPath(logFile);
  }
  ensureDir(logFile.substring(0, logFile.lastIndexOf('/')));
  final fullCmd =
      'nohup sh -c ${shellQuote(cmdStr)} > ${shellQuote(logFile)} 2>&1 & echo \$!';
  final out = await runShellCtx(dsWorkspaceDir, fullCmd,
      timeout: const Duration(seconds: 5));
  return '✅ 后台 PID: ${out.trim()}\n日志: $logFile';
}

Future<String> execToolListProcesses(Map<String, dynamic> args) async {
  final filter = mStr(args, 'filter');
  var cmd = 'ps -ef';
  if (filter.isNotEmpty) {
    cmd = 'ps -ef | grep -F ${shellQuote(filter)} | grep -v grep';
  }
  var out = await runShellCtx('', cmd, timeout: const Duration(seconds: 3));
  if (out.isEmpty) return '(一致するプロセスなし)';
  if (out.length > 64 * 1024) out = '${out.substring(0, 64 * 1024)}\n...[截断]';
  return out;
}

Future<String> execToolKillProcess(Map<String, dynamic> args) async {
  final pid = intArg(args, 'pid');
  if (pid == null || pid <= 0) return 'pid は正の整数である必要があります';
  var sig = mStr(args, 'signal');
  if (sig.isEmpty) sig = 'TERM';
  if (sig.startsWith('SIG')) sig = sig.substring(3);
  sig = sig.toUpperCase();
  final out = await runShellCtx('', 'kill -${shellQuote(sig)} $pid',
      timeout: const Duration(seconds: 3));
  return '✅ $pid に SIG$sig を送信${out.isNotEmpty ? "\n$out" : ""}';
}

Future<String> execToolWaitSeconds(Map<String, dynamic> args) async {
  final sec = intArg(args, 'seconds');
  if (sec == null || sec <= 0) return 'seconds は正の整数である必要があります';
  final s = sec > maxWaitSeconds ? maxWaitSeconds : sec;
  await Future.delayed(Duration(seconds: s));
  return '✅ 等待 $s 秒';
}

Future<String> execToolHTTPRequest(Map<String, dynamic> args) async {
  final u = mStr(args, 'url');
  if (u.isEmpty) return 'url 不能为空';
  var method = mStr(args, 'method');
  if (method.isEmpty) method = 'GET';
  method = method.trim().toUpperCase();
  final bodyStr = mStr(args, 'body');
  var timeout = intArgDefault(args, 'timeout', 30);
  if (timeout <= 0) timeout = 30;
  if (timeout > 300) timeout = 300;

  try {
    final client = globalHttpClientForTools;
    final req = await client.openUrl(method, Uri.parse(u));
    final hdrs = args['headers'];
    if (hdrs is Map) {
      hdrs.forEach((k, v) => req.headers.set('$k', '$v'));
    }
    if (req.headers.value('user-agent') == null) {
      req.headers.set('User-Agent', 'DeepSeekTool/2.0');
    }
    if (bodyStr.isNotEmpty) req.add(utf8.encode(bodyStr));
    final resp = await req.close().timeout(Duration(seconds: timeout));
    final bytes = await resp
        .fold<List<int>>([], (a, b) => a..addAll(b))
        .timeout(Duration(seconds: timeout));
    var out = 'HTTP ${resp.statusCode}\n${utf8.decode(bytes, allowMalformed: true)}';
    if (out.length > 200 * 1024) {
      out = '${out.substring(0, 200 * 1024)}\n...[截断]';
    }
    return out;
  } catch (e) {
    return 'リクエストに失敗しました: $e';
  }
}

// ------------------------------------------------------------
// Termux API 工具
// ------------------------------------------------------------
Future<String> execToolTorch(Map<String, dynamic> args) async {
  final action = mStr(args, 'action').trim().toLowerCase();
  if (action != 'on' && action != 'off') return 'action 只能是 on/off';
  final r = await runTermuxAPI(const Duration(seconds: 6), 'termux-torch', [action]);
  return '✅ フラッシュライト $action${r.out.isNotEmpty ? "\n${r.out}" : ""}';
}

Future<String> execToolCameraPhoto(Map<String, dynamic> args) async {
  final savePath = mStr(args, 'save_path');
  if (savePath.isEmpty) return 'save_path は必須です';
  final cameraID = intArgDefault(args, 'camera_id', 0);
  final absPath = resolveToolPath(savePath);
  ensureDir(absPath.substring(0, absPath.lastIndexOf('/')));
  final r = await runTermuxAPI(const Duration(seconds: 15),
      'termux-camera-photo', ['-c', '$cameraID', absPath]);
  var size = 0;
  try {
    size = File(absPath).lengthSync();
  } catch (_) {}
  return '✅ 撮影 $absPath ($size バイト)${r.out.isNotEmpty ? "\n${r.out}" : ""}';
}

Future<String> execToolCameraInfo() async =>
    (await runTermuxAPI(const Duration(seconds: 6), 'termux-camera-info', [])).out;

Future<String> execToolVolumeSet(Map<String, dynamic> args) async {
  final stream = mStr(args, 'stream').trim().toLowerCase();
  if (stream.isEmpty) return 'stream は必須です';
  final vol = intArg(args, 'volume');
  if (vol == null) return 'volume は必須です';
  return (await runTermuxAPI(
          const Duration(seconds: 6), 'termux-volume', [stream, '$vol']))
      .out;
}

Future<String> execToolVolumeGet() async =>
    (await runTermuxAPI(const Duration(seconds: 6), 'termux-volume', [])).out;

Future<String> execToolBatteryStatus() async =>
    (await runTermuxAPI(const Duration(seconds: 6), 'termux-battery-status', [])).out;

Future<String> execToolWifiInfo() async =>
    (await runTermuxAPI(const Duration(seconds: 6), 'termux-wifi-connectioninfo', []))
        .out;

Future<String> execToolWifiScan() async =>
    (await runTermuxAPI(const Duration(seconds: 12), 'termux-wifi-scaninfo', [])).out;

Future<String> execToolWifiEnable(Map<String, dynamic> args) async {
  final action = mStr(args, 'action').trim().toLowerCase();
  if (action != 'on' && action != 'off') return 'action 只能是 on/off';
  return (await runTermuxAPI(
          const Duration(seconds: 8), 'termux-wifi-enable', [action]))
      .out;
}

Future<String> execToolClipboard(Map<String, dynamic> args) async {
  final action = mStr(args, 'action').trim().toLowerCase();
  if (action == 'get') {
    final r = await runTermuxAPI(
        const Duration(seconds: 6), 'termux-clipboard-get', []);
    return 'クリップボード: ${r.out}';
  }
  if (action == 'set') {
    final text = mStr(args, 'text');
    if (text.isEmpty) return 'set 需要 text';
    return (await runTermuxAPI(
            const Duration(seconds: 6), 'termux-clipboard-set', [text]))
        .out;
  }
  return 'action 只能 get/set';
}

Future<String> execToolNotify(Map<String, dynamic> args) async {
  final title = mStr(args, 'title');
  final content = mStr(args, 'content');
  if (title.isEmpty) return 'title は必須です';
  final cmdArgs = ['-t', title];
  if (content.isNotEmpty) cmdArgs.addAll(['-c', content]);
  return (await runTermuxAPI(
          const Duration(seconds: 6), 'termux-notification', cmdArgs))
      .out;
}

Future<String> execToolToast(Map<String, dynamic> args) async {
  final text = mStr(args, 'text');
  if (text.isEmpty) return 'text は必須です';
  return (await runTermuxAPI(
          const Duration(seconds: 6), 'termux-toast', [text]))
      .out;
}

Future<String> execToolVibrate(Map<String, dynamic> args) async {
  final dur = intArgDefault(args, 'duration_ms', 500);
  return (await runTermuxAPI(const Duration(seconds: 6), 'termux-vibrate',
          ['-d', '$dur', '-f']))
      .out;
}

Future<String> execToolTTSSpeak(Map<String, dynamic> args) async {
  final text = mStr(args, 'text');
  if (text.isEmpty) return 'text は必須です';
  return (await runTermuxAPI(
          const Duration(seconds: 30), 'termux-tts-speak', [text]))
      .out;
}

Future<String> execToolLocation(Map<String, dynamic> args) async {
  var provider = mStr(args, 'provider');
  if (provider.isEmpty) provider = 'gps';
  return (await runTermuxAPI(
          const Duration(seconds: 30), 'termux-location', ['-p', provider]))
      .out;
}

Future<String> execToolBrightness(Map<String, dynamic> args) async {
  final v0 = intArg(args, 'value');
  if (v0 == null) return 'value は必須です';
  final v = v0.clamp(0, 255);
  return (await runTermuxAPI(
          const Duration(seconds: 6), 'termux-brightness', ['$v']))
      .out;
}

Future<String> execToolListSensors() async =>
    (await runTermuxAPI(const Duration(seconds: 6), 'termux-sensor', ['-l'])).out;

Future<String> execToolReadSensor(Map<String, dynamic> args) async {
  final sensor = mStr(args, 'sensor');
  if (sensor.isEmpty) return 'sensor は必須です';
  return (await runProcess('termux-sensor', ['-s', sensor, '-n', '1'],
          timeout: const Duration(seconds: 3)))
      .out;
}

Future<String> execToolFingerprint() async =>
    (await runTermuxAPI(const Duration(seconds: 20), 'termux-fingerprint', [])).out;

Future<String> execToolDialog(Map<String, dynamic> args) async {
  var input = mStr(args, 'input');
  if (input.isEmpty) input = 'text';
  final cmdArgs = ['-i', input];
  final t = mStr(args, 'title');
  if (t.isNotEmpty) cmdArgs.addAll(['-t', t]);
  final h = mStr(args, 'hint');
  if (h.isNotEmpty) cmdArgs.addAll(['-h', h]);
  return (await runTermuxAPI(
          const Duration(seconds: 120), 'termux-dialog', cmdArgs))
      .out;
}

Future<String> execToolAudioInfo() async =>
    (await runTermuxAPI(const Duration(seconds: 6), 'termux-audio-info', [])).out;

Future<String> execToolMicrophoneRecord(Map<String, dynamic> args) async {
  final savePath = mStr(args, 'save_path');
  if (savePath.isEmpty) return 'save_path は必須です';
  final dur = intArgDefault(args, 'duration_ms', 5000);
  final absPath = resolveToolPath(savePath);
  ensureDir(absPath.substring(0, absPath.lastIndexOf('/')));
  final start = await runTermuxAPI(const Duration(seconds: 10),
      'termux-microphone-record', ['-f', absPath, '-l', '0']);
  await Future.delayed(Duration(milliseconds: dur));
  final stop = await runTermuxAPI(
      const Duration(seconds: 6), 'termux-microphone-record', ['-q']);
  var size = 0;
  try {
    size = File(absPath).lengthSync();
  } catch (_) {}
  return '✅ 録音 $absPath ($size バイト)\n開始:${start.out}\n停止:${stop.out}';
}

// ------------------------------------------------------------
// 应用 / 権限 / 设置
// ------------------------------------------------------------
Future<String> execToolListPackages(Map<String, dynamic> args) async {
  final filter = mStr(args, 'filter');
  var cmdStr = 'pm list packages';
  if (filter.isNotEmpty) cmdStr = 'pm list packages | grep -F ${shellQuote(filter)}';
  final r = await runSmartShell('', cmdStr,
      timeout: const Duration(seconds: 12));
  var out = r.out;
  if (out.length > 32 * 1024) out = '${out.substring(0, 32 * 1024)}\n...[截断]';
  return out;
}

Future<String> execToolInstallApk(Map<String, dynamic> args) async {
  final apk = mStr(args, 'apk_path');
  if (apk.isEmpty) return 'apk_path は必須です';
  final abs = resolveToolPath(apk);
  if (!File(abs).existsSync()) return 'APK 不存在: $abs';
  final r = await runSmartShell('', 'pm install -r ${shellQuote(abs)}',
      timeout: const Duration(seconds: 60));
  if (r.out.isNotEmpty && !r.out.toLowerCase().contains('failure')) {
    return '✅ 安装 $abs\n${truncate(r.out, 300)}';
  }
  final o = await runTermuxAPI(const Duration(seconds: 60), 'termux-open', [abs]);
  return '✅ システムインストーラで $abs を開くよう要求しました\n${o.out}';
}

Future<String> execToolUninstallApp(Map<String, dynamic> args) async {
  final pkg = mStr(args, 'package');
  if (pkg.isEmpty) return 'package は必須です';
  final r = await runSmartShell('', 'pm uninstall ${shellQuote(pkg)}',
      timeout: const Duration(seconds: 30));
  return '✅ $pkg をアンインストールしました\n${r.out}';
}

Future<String> execToolGrantPermission(Map<String, dynamic> args) async {
  final pkg = mStr(args, 'package');
  final perm = mStr(args, 'permission');
  if (pkg.isEmpty || perm.isEmpty) return 'package と permission は必須です';
  final r = await runSmartShell(
      '', 'pm grant ${shellQuote(pkg)} ${shellQuote(perm)}',
      timeout: const Duration(seconds: 15));
  return '✅ 授予 $pkg $perm\n${r.out}';
}

Future<String> execToolRevokePermission(Map<String, dynamic> args) async {
  final pkg = mStr(args, 'package');
  final perm = mStr(args, 'permission');
  if (pkg.isEmpty || perm.isEmpty) return 'package と permission は必須です';
  final r = await runSmartShell(
      '', 'pm revoke ${shellQuote(pkg)} ${shellQuote(perm)}',
      timeout: const Duration(seconds: 15));
  return '✅ $pkg の $perm を取り消しました\n${r.out}';
}

Future<String> execToolListPermissions(Map<String, dynamic> args) async {
  final pkg = mStr(args, 'package');
  if (pkg.isEmpty) return 'package は必須です';
  final r = await runSmartShell(
      '',
      'dumpsys package ${shellQuote(pkg)} | grep -iE \'permission|granted\' | head -100',
      timeout: const Duration(seconds: 15));
  return r.out;
}

Future<String> execToolAppopsSet(Map<String, dynamic> args) async {
  final pkg = mStr(args, 'package');
  final op = mStr(args, 'op');
  final mode = mStr(args, 'mode');
  if (pkg.isEmpty || op.isEmpty || mode.isEmpty) return '引数は必須です';
  final r = await runSmartShell(
      '', 'appops set ${shellQuote(pkg)} ${shellQuote(op)} ${shellQuote(mode)}',
      timeout: const Duration(seconds: 15));
  return '✅ appops set $pkg $op $mode\n${r.out}';
}

Future<String> execToolSettingsGet(Map<String, dynamic> args) async {
  final ns = mStr(args, 'namespace');
  final key = mStr(args, 'key');
  if (ns.isEmpty || key.isEmpty) return '引数は必須です';
  final r = await runSmartShell(
      '', 'settings get ${shellQuote(ns)} ${shellQuote(key)}',
      timeout: const Duration(seconds: 6));
  return r.out;
}

Future<String> execToolSettingsPut(Map<String, dynamic> args) async {
  final ns = mStr(args, 'namespace');
  final key = mStr(args, 'key');
  final val = mStr(args, 'value');
  if (ns.isEmpty || key.isEmpty) return '引数は必須です';
  await runSmartShell(
      '', 'settings put ${shellQuote(ns)} ${shellQuote(key)} ${shellQuote(val)}',
      timeout: const Duration(seconds: 6));
  return '✅ settings put $ns $key = $val';
}

Future<String> execToolOpenURL(Map<String, dynamic> args) async {
  final u = mStr(args, 'url');
  if (u.isEmpty) return 'url 不能为空';
  return (await runTermuxAPI(const Duration(seconds: 10), 'termux-open-url', [u])).out;
}

Future<String> execToolOpenFile(Map<String, dynamic> args) async {
  final p = mStr(args, 'path');
  if (p.isEmpty) return 'path は必須です';
  return (await runTermuxAPI(
          const Duration(seconds: 10), 'termux-open', [resolveToolPath(p)]))
      .out;
}

Future<String> execToolShareFile(Map<String, dynamic> args) async {
  final p = mStr(args, 'path');
  if (p.isEmpty) return 'path は必須です';
  return (await runTermuxAPI(
          const Duration(seconds: 30), 'termux-share', [resolveToolPath(p)]))
      .out;
}

Future<String> execToolMediaScan(Map<String, dynamic> args) async {
  final p = mStr(args, 'path');
  if (p.isEmpty) return 'path は必須です';
  return (await runTermuxAPI(const Duration(seconds: 30), 'termux-media-scan',
          ['-r', resolveToolPath(p)]))
      .out;
}

Future<String> execToolMediaPlayer(Map<String, dynamic> args) async {
  final action = mStr(args, 'action').trim().toLowerCase();
  if (action.isEmpty) return 'action は必須です';
  if (action == 'play') {
    final file = mStr(args, 'file');
    if (file.isEmpty) return 'play 需要 file';
    return (await runTermuxAPI(const Duration(seconds: 10),
            'termux-media-player', ['play', resolveToolPath(file)]))
        .out;
  }
  if (['pause', 'stop', 'toggle', 'info'].contains(action)) {
    return (await runTermuxAPI(
            const Duration(seconds: 6), 'termux-media-player', [action]))
        .out;
  }
  return 'action 只支持 play/pause/stop/toggle/info';
}

Future<String> execToolSMSList(Map<String, dynamic> args) async {
  final limit = intArgDefault(args, 'limit', 10);
  var t = mStr(args, 'type');
  if (t.isEmpty) t = 'all';
  return (await runTermuxAPI(
          const Duration(seconds: 15), 'termux-sms-list', ['-l', '$limit', '-t', t]))
      .out;
}

Future<String> execToolSMSSend(Map<String, dynamic> args) async {
  final number = mStr(args, 'number');
  final text = mStr(args, 'text');
  if (number.isEmpty || text.isEmpty) return 'number と text は必須です';
  return (await runTermuxAPI(
          const Duration(seconds: 15), 'termux-sms-send', ['-n', number, text]))
      .out;
}

Future<String> execToolContactList(Map<String, dynamic> args) async {
  final r = await runTermuxAPI(
      const Duration(seconds: 15), 'termux-contact-list', []);
  var out = r.out;
  if (out.length > 32 * 1024) out = '${out.substring(0, 32 * 1024)}\n...[截断]';
  return out;
}

Future<String> execToolCallLog(Map<String, dynamic> args) async {
  final limit = intArgDefault(args, 'limit', 10);
  return (await runTermuxAPI(
          const Duration(seconds: 15), 'termux-call-log', ['-l', '$limit']))
      .out;
}

Future<String> execToolTermuxDownload(Map<String, dynamic> args) async {
  final u = mStr(args, 'url');
  final desc = mStr(args, 'description');
  if (u.isEmpty) return 'url 不能为空';
  final cmdArgs = ['-u', u];
  if (desc.isNotEmpty) cmdArgs.addAll(['-d', desc]);
  return (await runTermuxAPI(
          const Duration(seconds: 30), 'termux-download', cmdArgs))
      .out;
}

// ------------------------------------------------------------
// 官方搜索 / 抓取工具
// ------------------------------------------------------------
Future<String> execToolWebSearch(Map<String, dynamic> args) async {
  final query = mStr(args, 'query').trim();
  if (query.isEmpty) return 'query は必須です';
  final count = intArgDefault(args, 'count', 10);
  final needContent = mBool(args, 'need_content');
  final cfg = getDsConfig();
  if (cfg.apiKey.isEmpty) return '未配置 DeepSeek API Key';
  try {
    final results =
        await deepseekOfficialSearch(cfg.apiKey, query, count, needContent, query);
    final sb = StringBuffer('✅ DeepSeek 官方搜索返回 ${results.length} 条：\n');
    for (var i = 0; i < results.length; i++) {
      final r = results[i];
      sb.write('${i + 1}. [${r.source}] ${r.title}\n');
      sb.write('   リンク：${r.url}\n');
      if (r.snippet.isNotEmpty) sb.write('   摘要：${r.snippet}\n');
    }
    return sb.toString();
  } catch (e) {
    return '検索に失敗しました: $e';
  }
}

Future<String> execToolFetch(Map<String, dynamic> args) async {
  final url = mStr(args, 'url').trim();
  if (url.isEmpty) return 'url 不能为空';
  final cfg = getDsConfig();
  if (cfg.apiKey.isEmpty) return '未配置 DeepSeek API Key';
  try {
    final r = await deepseekOfficialFetch(cfg.apiKey, url);
    var content = r.content;
    if (content.length > 60000) {
      content = '${content.substring(0, 60000)}\n...[截断]';
    }
    return '✅ $url を取得しました\nタイトル: ${r.title}\n\n$content';
  } catch (e) {
    return '取得に失敗しました: $e';
  }
}

Future<String> execToolAdbStatus() async {
  final bin = _resolveAdbBin();
  final ok = await ensureAdbChannel(force: true);
  final dev = await runProcess(bin, const ['devices'],
      timeout: const Duration(seconds: 6));
  final id = await runProcess(bin, const ['-s', dsAdbSerial, 'shell', 'id'],
      timeout: const Duration(seconds: 6));
  final sb = StringBuffer();
  sb.write(ok ? '✅ adb shell 通道 ONLINE\n' : '❌ adb shell 通道 OFFLINE\n');
  sb.write('bin: $bin\nserial: $dsAdbSerial\n');
  sb.write('devices: ${dev.out.trim()}\n');
  sb.write('shell id: ${id.out.trim()}\n');
  if (!ok) sb.write('hint: Termux で ddsh/adb_up.sh を実行してください\n');
  return sb.toString();
}

Future<String> execToolAdbConnect() async {
  final ok = await ensureAdbChannel(force: true);
  if (!ok) {
    return '❌ 接続できませんでした: ${adbLastError()}\n'
        '設定 → 開発者向けオプション → ワイヤレス デバッグ を確認してください';
  }
  final id = await runViaAdb('id', timeout: const Duration(seconds: 6));
  return '✅ $dsAdbSerial に接続しました\n${id.out.trim()}';
}

Future<String> execToolAdbShell(Map<String, dynamic> args) async {
  final cmdStr = mStr(args, 'command');
  if (cmdStr.trim().isEmpty) return 'command は必須です';
  var timeout = intArgDefault(args, 'timeout', 30);
  if (timeout <= 0) timeout = 30;
  if (timeout > maxCmdTimeout) timeout = maxCmdTimeout;
  final ok = await ensureAdbChannel();
  if (!ok) {
    return '🚫 adb shell 通道がオフラインです（${adbLastError()}）。'
        'Termux で ddsh/adb_up.sh を実行してください';
  }
  final r = await runViaAdb(cmdStr, timeout: Duration(seconds: timeout));
  var out = r.out;
  if (out.isEmpty) out = '(成功、出力なし)';
  if (out.length > 64 * 1024) out = '${out.substring(0, 64 * 1024)}\n...[截断]';
  return '✅ adb shell (uid=2000): $cmdStr\n$out';
}

// ------------------------------------------------------------
// 工具路由
// ------------------------------------------------------------
// ------------------------------------------------------------
// 豆包专属工具模式 —— 虚拟屏幕强制网关
//
// 需求：豆包模式下所有 UI 自动化必须跑在虚拟屏幕（副屏）上，
//       主屏焦点不被抢占、主屏上正在运行的应用不被打断。
// 做法：deepseek_api 在豆包模型的工具执行批次前后置位 dsVdForce，
//       本网关把「主屏操作 / 主屏感知」类工具整体重定向到 vd_* 实现，
//       副屏未就绪时由 vdTap / vdSwipe / ... 内部的 vdEnsure() 自动创建。
// 实测限制：副屏的 uiautomator dump 会被系统静默忽略（仍 dump 主屏），
//       因此按 text / resource_id 定位的调用无法在副屏完成，
//       这类请求返回明确说明，引导模型改用 vd_observe / vd_ocr + 坐标操作。
// ------------------------------------------------------------

String _vdPfx(String s) => '【虚拟屏】$s';

/// 返回非 null 表示已接管（返回值即最终结果）。
Future<String?> dsVdIntercept(String name, Map<String, dynamic> args) async {
  switch (name) {
    case 'tap':
      return _vdTapRoute(args);
    case 'long_press':
      return _vdLongPressRoute(args);
    case 'swipe':
      return _vdSwipeRoute(args);
    case 'input_text':
      return _vdTextRoute(args);
    case 'key_event':
      return _vdKeyRoute(args);
    case 'start_app':
      return _vdLaunchRoute(args);
    case 'screenshot':
      return _vdShotRoute(args);
    case 'ocr_screen':
    case 'get_screen_text':
      return _vdOcrRoute(args);
    case 'screen_size':
      return _vdSizeRoute();
    case 'batch_tap':
      return _vdBatchTapRoute(args);
    case 'batch_swipe':
      return _vdBatchSwipeRoute(args);
    case 'ui_dump':
    case 'find_element':
    case 'wait_for_element':
      return _vdPfx('副屏不支持 uiautomator dump（--display 被系统静默忽略），'
          'UI 树定位不可用。请改用 vd_observe / vd_ocr 取得文字与坐标，'
          '再用 vd_tap / vd_swipe 按坐标操作。');
  }
  return null;
}

Future<String> _vdTapRoute(Map<String, dynamic> args) async {
  final x = intArg(args, 'x');
  final y = intArg(args, 'y');
  if (x == null || y == null) {
    final t = mStr(args, 'text');
    final rid = mStr(args, 'resource_id');
    if (t.isNotEmpty || rid.isNotEmpty) {
      return _vdPfx('副屏没有 UI 树，无法按「$t$rid」定位元素。'
          '请先 vd_ocr / vd_observe 取得坐标，再用 vd_tap 按坐标点击。');
    }
    return _vdPfx('x / y 座標がありません');
  }
  final r = await vdTap(x, y);
  return _vdPfx(r.output);
}

Future<String> _vdLongPressRoute(Map<String, dynamic> args) async {
  final x = intArg(args, 'x');
  final y = intArg(args, 'y');
  var dur = intArgDefault(args, 'duration_ms', defaultLongPressDur);
  if (dur < 50) dur = 50;
  if (x == null || y == null) {
    return _vdPfx('長押しには x / y 座標が必要です（副屏は UI 樹で検索できません）');
  }
  final r = await vdSwipe(x, y, x, y, durMs: dur);
  return _vdPfx('${r.output}（長押し $dur ms）');
}

Future<String> _vdSwipeRoute(Map<String, dynamic> args) async {
  var dur = intArgDefault(args, 'duration_ms', defaultSwipeDur);
  if (dur < 50) dur = 50;
  final dir = mStr(args, 'direction').trim().toLowerCase();
  int x1;
  int y1;
  int x2;
  int y2;
  if (dir.isNotEmpty) {
    const w = vdDefaultWidth;
    const h = vdDefaultHeight;
    final cx = w ~/ 2;
    final cy = h ~/ 2;
    if (dir == 'up') {
      x1 = cx;
      y1 = (h * 0.75).toInt();
      x2 = cx;
      y2 = (h * 0.25).toInt();
    } else if (dir == 'down') {
      x1 = cx;
      y1 = (h * 0.25).toInt();
      x2 = cx;
      y2 = (h * 0.75).toInt();
    } else if (dir == 'left') {
      x1 = (w * 0.85).toInt();
      y1 = cy;
      x2 = (w * 0.15).toInt();
      y2 = cy;
    } else if (dir == 'right') {
      x1 = (w * 0.15).toInt();
      y1 = cy;
      x2 = (w * 0.85).toInt();
      y2 = cy;
    } else {
      return _vdPfx('不明な方向: $dir（up / down / left / right のいずれか）');
    }
  } else {
    final sx = intArg(args, 'start_x');
    final sy = intArg(args, 'start_y');
    final ex = intArg(args, 'end_x');
    final ey = intArg(args, 'end_y');
    if (sx == null || sy == null || ex == null || ey == null) {
      return _vdPfx('direction か座標ペア（start_x/start_y/end_x/end_y）が必要です');
    }
    x1 = sx;
    y1 = sy;
    x2 = ex;
    y2 = ey;
  }
  final r = await vdSwipe(x1, y1, x2, y2, durMs: dur);
  return _vdPfx(r.output);
}

Future<String> _vdTextRoute(Map<String, dynamic> args) async {
  final text = mStr(args, 'text');
  if (text.isEmpty) return _vdPfx('text は必須です');
  final r = await vdText(text);
  return _vdPfx(r.output);
}

Future<String> _vdKeyRoute(Map<String, dynamic> args) async {
  final kc = intArg(args, 'keycode');
  if (kc != null) {
    final r = await vdKey(kc);
    return _vdPfx(r.output);
  }
  final k = mStr(args, 'key').trim().toLowerCase();
  const map = <String, int>{
    'back': 4,
    'home': 3,
    'recent': 187,
    'recents': 187,
    'enter': 66,
    'menu': 82,
    'delete': 67,
    'del': 67,
    'power': 26,
    'volume_up': 24,
    'volume_down': 25,
    'tab': 61,
    'search': 84,
    'escape': 111,
    'esc': 111,
  };
  final code = map[k];
  if (code == null) {
    return _vdPfx('未知のキー: $k（keycode を指定してください）');
  }
  final r = await vdKey(code);
  return _vdPfx(r.output);
}

Future<String> _vdLaunchRoute(Map<String, dynamic> args) async {
  final pkg = mStr(args, 'package').trim();
  final act = mStr(args, 'activity').trim();
  if (pkg.isEmpty) return _vdPfx('package は必須です');
  final target = act.isEmpty
      ? pkg
      : (act.startsWith('.') ? '$pkg$act' : '$pkg/$act');
  final r = await vdLaunch(target);
  return _vdPfx(r.output);
}

Future<String> _vdShotRoute(Map<String, dynamic> args) async {
  final p = mStr(args, 'save_path');
  final r = await vdScreenshot(savePath: p);
  return _vdPfx(r.output);
}

Future<String> _vdOcrRoute(Map<String, dynamic> args) async {
  final lang = mStr(args, 'lang').trim();
  final r = await vdOcr(lang: lang.isEmpty ? 'chi_sim+eng' : lang);
  return _vdPfx(r.output);
}

Future<String> _vdSizeRoute() async {
  final st = await vdEnsure();
  if (!st.ready) {
    return _vdPfx('副屏が未準備です（spec="${st.spec}"）。vd_create を先に実行してください。');
  }
  return _vdPfx('虚拟屏幕 ${vdDefaultWidth}x${vdDefaultHeight}'
      '（displayId=${st.displayId}, spec="${st.spec}"）');
}

Future<String> _vdBatchTapRoute(Map<String, dynamic> args) async {
  final pts = asList(args['points']);
  if (pts.isEmpty) return _vdPfx('points は必須です');
  final intervalMs = intArgDefault(args, 'interval_ms', 100);
  final sb = StringBuffer();
  var n = 0;
  for (final raw in pts) {
    final m = asMap(raw);
    final x = intArg(m, 'x');
    final y = intArg(m, 'y');
    if (x == null || y == null) {
      sb.write('  ⏭ 座標なしの項目をスキップ（副屏は UI 樹で検索できません）\n');
      continue;
    }
    if (n > 0 && intervalMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: intervalMs));
    }
    final r = await vdTap(x, y);
    sb.write('  ($x,$y) → ${r.ok ? 'OK' : r.output}\n');
    n++;
  }
  if (n == 0) return _vdPfx('有効な座標がありません');
  return _vdPfx('$n 点を副屏でクリック:\n$sb');
}

Future<String> _vdBatchSwipeRoute(Map<String, dynamic> args) async {
  final acts = asList(args['actions']);
  if (acts.isEmpty) return _vdPfx('actions は必須です');
  final sb = StringBuffer();
  var n = 0;
  for (final raw in acts) {
    final m = asMap(raw);
    final out = await _vdSwipeRoute(m);
    sb.write('  ${out.replaceFirst('【虚拟屏】', '')}\n');
    n++;
  }
  return _vdPfx('$n 回のスワイプを副屏で実行:\n$sb');
}

Future<String> executeDsTool(String name, Map<String, dynamic> args) async {
  // 豆包专属工具模式：UI 操作与感知一律重定向到虚拟屏幕，主屏不受影响。
  if (dsVdForce) {
    final intercepted = await dsVdIntercept(name, args);
    if (intercepted != null) return intercepted;
  }
  switch (name) {
    // Shizuku 全部禁用（与 Go 版 shizukuDisabled=true 行为一致）
    case 'shizuku_status':
    case 'shizuku_start':
    case 'shizuku_auto_setup':
    case 'shizuku_exec':
    case 'shizuku_install_rish':
      return '🚫 Shizuku 権限は取り消し済みのため、AI にシステム権限がありません';

    case 'adb_status':
      return execToolAdbStatus();
    case 'adb_connect':
      return execToolAdbConnect();
    case 'adb_shell':
      return execToolAdbShell(args);

    case 'batch_tap':
      return execToolBatchTap(args);
    case 'batch_swipe':
      return execToolBatchSwipe(args);
    case 'batch_command':
      return execToolBatchCommand(args);
    case 'smart_wait':
      return execToolSmartWait(args);
    case 'screen_hash':
      return execToolScreenHash();
    case 'ocr_screen':
      return execToolOCRScreen(args);
    case 'get_screen_text':
      return execToolGetScreenText();
    case 'dismiss_popup':
      return execToolDismissPopup(args);
    case 'auto_dismiss_dialogs':
      return execToolAutoDismissDialogs();
    case 'is_popup_present':
      return execToolIsPopupPresent();
    case 'wait_for_element':
      return execToolWaitForElement(args);
    case 'sqlite_query':
      return execToolSQLiteQuery(args);
    case 'download_file':
      return execToolDownloadFile(args);
    case 'create_file':
      return execToolCreateFile(args);
    case 'append_file':
      return execToolAppendFile(args);
    case 'read_file':
      return execToolReadFile(args);
    case 'get_file_size':
      return execToolGetFileSize(args);
    case 'list_dir':
      return execToolListDir(args);
    case 'execute_command':
      return execToolExecuteCommand(args);
    case 'run_background':
      return execToolRunBackground(args);
    case 'list_processes':
      return execToolListProcesses(args);
    case 'kill_process':
      return execToolKillProcess(args);
    case 'wait_seconds':
      return execToolWaitSeconds(args);
    case 'http_request':
      return execToolHTTPRequest(args);
    case 'tap':
      return execToolTap(args);
    case 'long_press':
      return execToolLongPress(args);
    case 'swipe':
      return execToolSwipe(args);
    case 'input_text':
      return execToolInputText(args);
    case 'key_event':
      return execToolKeyEvent(args);
    case 'start_app':
      return execToolStartApp(args);
    case 'current_app':
      return execToolCurrentApp();
    case 'is_app_running':
      return execToolIsAppRunning(args);
    case 'force_stop_app':
      return execToolForceStopApp(args);
    case 'find_element':
      return execToolFindElement(args);
    case 'screenshot':
      return execToolScreenshot(args);
    case 'screen_size':
      return execToolScreenSize();
    case 'ui_dump':
      return execToolUIDump();
    case 'torch':
      return execToolTorch(args);
    case 'camera_photo':
      return execToolCameraPhoto(args);
    case 'camera_info':
      return execToolCameraInfo();
    case 'volume_set':
      return execToolVolumeSet(args);
    case 'volume_get':
      return execToolVolumeGet();
    case 'battery_status':
      return execToolBatteryStatus();
    case 'wifi_info':
      return execToolWifiInfo();
    case 'wifi_scan':
      return execToolWifiScan();
    case 'wifi_enable':
      return execToolWifiEnable(args);
    case 'clipboard':
      return execToolClipboard(args);
    case 'notify':
      return execToolNotify(args);
    case 'toast':
      return execToolToast(args);
    case 'vibrate':
      return execToolVibrate(args);
    case 'tts_speak':
      return execToolTTSSpeak(args);
    case 'location':
      return execToolLocation(args);
    case 'brightness':
      return execToolBrightness(args);
    case 'list_sensors':
      return execToolListSensors();
    case 'read_sensor':
      return execToolReadSensor(args);
    case 'fingerprint':
      return execToolFingerprint();
    case 'dialog':
      return execToolDialog(args);
    case 'audio_info':
      return execToolAudioInfo();
    case 'microphone_record':
      return execToolMicrophoneRecord(args);
    case 'list_packages':
      return execToolListPackages(args);
    case 'install_apk':
      return execToolInstallApk(args);
    case 'uninstall_app':
      return execToolUninstallApp(args);
    case 'grant_permission':
      return execToolGrantPermission(args);
    case 'revoke_permission':
      return execToolRevokePermission(args);
    case 'list_permissions':
      return execToolListPermissions(args);
    case 'appops_set':
      return execToolAppopsSet(args);
    case 'settings_get':
      return execToolSettingsGet(args);
    case 'settings_put':
      return execToolSettingsPut(args);
    case 'open_url':
      return execToolOpenURL(args);
    case 'open_file':
      return execToolOpenFile(args);
    case 'share_file':
      return execToolShareFile(args);
    case 'media_scan':
      return execToolMediaScan(args);
    case 'media_player':
      return execToolMediaPlayer(args);
    case 'sms_list':
      return execToolSMSList(args);
    case 'sms_send':
      return execToolSMSSend(args);
    case 'contact_list':
      return execToolContactList(args);
    case 'call_log':
      return execToolCallLog(args);
    case 'termux_download':
      return execToolTermuxDownload(args);
    case 'web_search':
      return execToolWebSearch(args);
    case 'fetch':
      return execToolFetch(args);
    case 'cosplay_show':
      return execToolCosplayShow(args);
    case 'cosplay_list':
      return execToolCosplayList();
    case 'cosplay_switch':
      return execToolCosplaySwitch(args);
    case 'cosplay_upsert':
      return execToolCosplayUpsert(args);
    case 'cosplay_remove':
      return execToolCosplayRemove(args);
    case 'vd_status':
      return execToolVdStatus(args);
    case 'vd_create':
      return execToolVdCreate(args);
    case 'vd_destroy':
      return execToolVdDestroy(args);
    case 'vd_launch':
      return execToolVdLaunch(args);
    case 'vd_tap':
      return execToolVdTap(args);
    case 'vd_swipe':
      return execToolVdSwipe(args);
    case 'vd_key':
      return execToolVdKey(args);
    case 'vd_text':
      return execToolVdText(args);
    case 'vd_screenshot':
      return execToolVdScreenshot(args);
    case 'vd_ocr':
      return execToolVdOcr(args);
    case 'vd_observe':
      return execToolVdObserve(args);
    default:
      return '不明なツール: $name';
  }
}

void initDsWorkspace() {
  ensureDir(dsWorkspaceDir);
  logp('🔧 ツールワークスペース: $dsWorkspaceDir');
  logp('🚫 [Shizuku] 権限は取り消し済みのため、自動昇格をスキップします');
}

// ------------------------------------------------------------
// 虚拟屏幕工具实现（virtual_display.dart）
// ------------------------------------------------------------
Future<String> execToolVdStatus(Map<String, dynamic> args) async {
  final st = await vdState(force: true);
  return 'configured=${st.configured} displayId=${st.displayId} '
      'spec="${st.spec}" ready=${st.ready}';
}

Future<String> execToolVdCreate(Map<String, dynamic> args) async {
  final w = intArgDefault(args, 'width', vdDefaultWidth);
  final h = intArgDefault(args, 'height', vdDefaultHeight);
  final d = intArgDefault(args, 'dpi', vdDefaultDpi);
  final st = await vdEnsure(width: w, height: h, dpi: d);
  if (!st.ready) {
    return '❌ 虚拟屏幕创建失败：configured=${st.configured} spec="${st.spec}"';
  }
  return '✅ 虚拟屏幕就绪：displayId=${st.displayId} spec="${st.spec}"';
}

Future<String> execToolVdDestroy(Map<String, dynamic> args) async {
  final st = await vdDestroy();
  return '✅ 虚拟屏幕已关闭（configured=${st.configured}）';
}

Future<String> execToolVdLaunch(Map<String, dynamic> args) async {
  final target = mStr(args, 'target');
  final r = await vdLaunch(target);
  return r.output;
}

Future<String> execToolVdTap(Map<String, dynamic> args) async {
  final x = intArgDefault(args, 'x', -1);
  final y = intArgDefault(args, 'y', -1);
  if (x < 0 || y < 0) return 'x 与 y 必须为非负整数';
  final r = await vdTap(x, y);
  return r.output;
}

Future<String> execToolVdSwipe(Map<String, dynamic> args) async {
  final x1 = intArgDefault(args, 'x1', -1);
  final y1 = intArgDefault(args, 'y1', -1);
  final x2 = intArgDefault(args, 'x2', -1);
  final y2 = intArgDefault(args, 'y2', -1);
  if (x1 < 0 || y1 < 0 || x2 < 0 || y2 < 0) return 'x1/y1/x2/y2 必须为非负整数';
  final dur = intArgDefault(args, 'duration_ms', 300);
  final r = await vdSwipe(x1, y1, x2, y2, durMs: dur);
  return r.output;
}

Future<String> execToolVdKey(Map<String, dynamic> args) async {
  final kc = intArg(args, 'keycode');
  if (kc == null) return 'keycode 必填';
  final r = await vdKey(kc);
  return r.output;
}

Future<String> execToolVdText(Map<String, dynamic> args) async {
  final t = mStr(args, 'text');
  if (t.isEmpty) return 'text 不能为空';
  final r = await vdText(t);
  return r.output;
}

Future<String> execToolVdScreenshot(Map<String, dynamic> args) async {
  final p = mStr(args, 'save_path');
  final r = await vdScreenshot(savePath: p);
  return r.output;
}

Future<String> execToolVdOcr(Map<String, dynamic> args) async {
  var lang = mStr(args, 'lang');
  if (lang.isEmpty) lang = 'chi_sim+eng';
  final r = await vdOcr(lang: lang);
  return r.output;
}

Future<String> execToolVdObserve(Map<String, dynamic> args) async {
  final ocr = mBool(args, 'ocr', true);
  var lang = mStr(args, 'lang');
  if (lang.isEmpty) lang = 'chi_sim+eng';
  final r = await vdObserve(withOcr: ocr, lang: lang);
  return r.output;
}
