// ============================================================
// tools.dart —— AI 工具集（schema + 执行）
// 100% 对齐 Go 版 deepseek-tools.go：
//   - 90+ 工具的 JSON Schema 与描述逐条一致
//   - shell / Termux API / UI 自动化 / 弹窗处理逻辑一致
//   - Shizuku 权限已撤销（shizukuDisabled = true）：拒绝任何 rish/shizuku
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

/// 智能 shell：Shizuku 已撤销 → 直接本地 sh（并对 rish/shizuku 命令直接拒绝）
class SmartShellResult {
  final String out;
  final bool usedShizuku;
  final int code;
  const SmartShellResult(this.out, this.usedShizuku, this.code);
}

Future<SmartShellResult> runSmartShell(String workdir, String cmdStr,
    {Duration? timeout}) async {
  if (shizukuDisabled && containsShizukuInvocation(cmdStr)) {
    return const SmartShellResult('🚫 Shizuku 权限已撤销，拒绝执行相关命令', false, 1);
  }
  final r = await runRawShell(workdir, cmdStr, timeout: timeout);
  return SmartShellResult(r.out, false, r.code);
}

Future<String> runShellCtx(String workdir, String cmdStr,
    {Duration? timeout}) async {
  final r = await runSmartShell(workdir, cmdStr, timeout: timeout);
  return r.out;
}

Future<({String out, String? error})> runTermuxAPI(
    Duration timeout, String name, List<String> args) async {
  final r = await runProcess(name, args, timeout: timeout);
  if (r.timedOut) return (out: r.out, error: '$name 超时');
  if (r.code != 0) return (out: r.out, error: '$name 失败');
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
  return '✅ 点击 ($x,$y)';
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
  '允许', '同意', '始终允许', '总是允许', '确定', '好', 'OK', 'Ok', 'ok', '我知道',
  '我知道了', '接受', '继续', '开启', '启用', '现在就', '立即', 'Allow', 'ALLOW',
  'Grant', 'Accept', 'Continue', 'Agree', 'Yes'
];
const List<String> popupDenyKeywords = [
  '拒绝', '不允许', '取消', '稍后', '以后再说', '暂不', '不再提示', '跳过', '关闭',
  'Deny', 'Cancel', 'Skip', 'Later', 'No'
];
const List<String> popupCloseKeywords = [
  '关闭', '取消', '退出', '以后再说', '跳过', '稍后', '×', '✕', '✖', 'x', 'X',
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
          dismissed.add('[关闭图标] id=${n.resourceId} (${n.centerX},${n.centerY})');
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
        if (!await pickAndTap(popupAllowKeywords, '允许')) break;
      }
      break;
    case 'deny':
      while (actions < maxActions) {
        if (!await pickAndTap(popupDenyKeywords, '拒绝')) break;
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
        if (await pickAndTap(popupAllowKeywords, '允许')) continue;
        if (await pickAndTap(popupDenyKeywords, '拒绝/取消')) continue;
        break;
      }
  }

  if (hasPopup && actions == 0) {
    await runSmartShell('', 'input keyevent 4',
        timeout: const Duration(seconds: 2));
    dismissed.add('[返回键]');
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
    fnTool('shizuku_status', '检测 Shizuku 状态。', objSchema({})),
    fnTool('shizuku_start', '打开 Shizuku 应用。', objSchema({})),
    fnTool('shizuku_auto_setup', '★ 一键检测+修复 Shizuku。', objSchema({})),
    fnTool(
        'shizuku_exec',
        '通过 Shizuku 特权执行命令。',
        objSchema({'command': str('命令'), 'timeout': integer('超时秒数')},
            ['command'])),
    fnTool('shizuku_install_rish', '自动部署 rish。',
        objSchema({'target_dir': str('目标目录')})),
    fnTool(
        'batch_tap',
        '一次性执行多个点击。',
        objSchema({
          'points': {
            'type': 'array',
            'description': '坐标数组',
            'items': {'type': 'object'}
          },
          'interval_ms': integer('间隔毫秒'),
        }, [
          'points'
        ])),
    fnTool(
        'batch_swipe',
        '一次执行多个滑动。',
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
        '一次执行多条 shell 命令。',
        objSchema({
          'commands': {
            'type': 'array',
            'items': {'type': 'string'}
          },
          'timeout': integer('总超时秒数'),
        }, [
          'commands'
        ])),
    fnTool('smart_wait', '智能等待屏幕稳定。',
        objSchema({'max_ms': integer('最长毫秒'), 'stable_ms': integer('稳定毫秒')})),
    fnTool('screen_hash', '获取屏幕指纹。', objSchema({})),
    fnTool('ocr_screen', 'OCR 识别屏幕文字。', objSchema({'lang': str('语言')})),
    fnTool('get_screen_text', '获取屏幕所有可见文本。', objSchema({})),
    fnTool('dismiss_popup', '自动关闭弹窗。',
        objSchema({'prefer': str('allow/deny/cancel/auto')})),
    fnTool('auto_dismiss_dialogs', '连续清空弹窗。', objSchema({})),
    fnTool('is_popup_present', '检测是否有弹窗。', objSchema({})),
    fnTool(
        'wait_for_element',
        '等待控件出现。',
        objSchema({
          'text': str('文本'),
          'resource_id': str('resource-id'),
          'timeout_ms': integer('超时毫秒'),
        })),
    fnTool(
        'download_file',
        '下载文件。',
        objSchema({'url': str('链接'), 'save_path': str('保存路径')},
            ['url', 'save_path'])),
    fnTool(
        'create_file',
        '创建/覆盖文件。',
        objSchema({'path': str('路径'), 'content': str('内容')},
            ['path', 'content'])),
    fnTool(
        'append_file',
        '追加内容到文件。',
        objSchema({'path': str('路径'), 'content': str('内容')},
            ['path', 'content'])),
    fnTool('read_file', '读取文件。', objSchema({'path': str('路径')}, ['path'])),
    fnTool('get_file_size', '文件大小。', objSchema({'path': str('路径')}, ['path'])),
    fnTool('list_dir', '列目录。', objSchema({'path': str('路径')})),
    fnTool(
        'execute_command',
        '执行 shell 命令。',
        objSchema({'command': str('命令'), 'timeout': integer('超时秒数')},
            ['command'])),
    fnTool(
        'run_background',
        '后台运行长任务。',
        objSchema({'command': str('命令'), 'log_file': str('日志路径')},
            ['command'])),
    fnTool('list_processes', '列进程。', objSchema({'filter': str('过滤关键字')})),
    fnTool(
        'kill_process',
        '杀进程。',
        objSchema({'pid': integer('PID'), 'signal': str('信号')}, ['pid'])),
    fnTool(
        'wait_seconds',
        '等待秒数。',
        objSchema({'seconds': integer('秒数'), 'reason': str('原因')}, ['seconds'])),
    fnTool(
        'http_request',
        'HTTP 请求。',
        objSchema({
          'method': str('GET/POST/...'),
          'url': str('URL'),
          'headers': {'type': 'object'},
          'body': str('body'),
          'timeout': integer('超时秒数'),
        }, [
          'url'
        ])),
    fnTool(
        'sqlite_query',
        '查询 SQLite 数据库。',
        objSchema({'db_path': str('路径'), 'sql': str('SQL')}, ['db_path', 'sql'])),
    fnTool(
        'tap',
        '点击。',
        objSchema({
          'x': integer('X'),
          'y': integer('Y'),
          'text': str('文本'),
          'resource_id': str('resource-id'),
          'index': integer('索引'),
        })),
    fnTool(
        'long_press',
        '长按。',
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
        '滑动。',
        objSchema({
          'direction': str('up/down/left/right'),
          'start_x': integer('起点 X'),
          'start_y': integer('起点 Y'),
          'end_x': integer('终点 X'),
          'end_y': integer('终点 Y'),
          'duration_ms': integer('时长毫秒'),
        })),
    fnTool('input_text', '输入文本。', objSchema({'text': str('文本')}, ['text'])),
    fnTool(
        'key_event',
        '发送按键。',
        objSchema({'key': str('按键名'), 'keycode': integer('keycode')})),
    fnTool(
        'find_element',
        '查找 UI 控件。',
        objSchema({
          'text': str('文本'),
          'resource_id': str('resource-id'),
          'class': str('class'),
          'limit': integer('数量'),
        })),
    fnTool('screenshot', '截屏。', objSchema({'save_path': str('路径')})),
    fnTool('screen_size', '屏幕分辨率。', objSchema({})),
    fnTool('ui_dump', '导出 UI XML。', objSchema({})),
    fnTool(
        'start_app',
        '★ 强启动应用（3秒内）。',
        objSchema({
          'package': str('包名'),
          'activity': str('Activity'),
          'auto_allow': {'type': 'boolean'},
        }, [
          'package'
        ])),
    fnTool('current_app', '当前前台应用。', objSchema({})),
    fnTool('is_app_running', '检查应用进程。',
        objSchema({'package': str('包名')}, ['package'])),
    fnTool('force_stop_app', '强制停止应用。',
        objSchema({'package': str('包名')}, ['package'])),
    fnTool('torch', '手电筒。', objSchema({'action': str('on/off')}, ['action'])),
    fnTool(
        'camera_photo',
        '拍照。',
        objSchema({'save_path': str('路径'), 'camera_id': integer('摄像头 ID')},
            ['save_path'])),
    fnTool('camera_info', '摄像头信息。', objSchema({})),
    fnTool(
        'volume_set',
        '设音量。',
        objSchema({'stream': str('music/ring/...'), 'volume': integer('音量')},
            ['stream', 'volume'])),
    fnTool('volume_get', '获取音量。', objSchema({})),
    fnTool('battery_status', '电池状态。', objSchema({})),
    fnTool('wifi_info', 'WiFi 信息。', objSchema({})),
    fnTool('wifi_scan', '扫描 WiFi。', objSchema({})),
    fnTool('wifi_enable', '开关 WiFi。', objSchema({'action': str('on/off')}, ['action'])),
    fnTool(
        'clipboard',
        '剪贴板。',
        objSchema({'action': str('get/set'), 'text': str('set 时的文本')},
            ['action'])),
    fnTool(
        'notify',
        '系统通知。',
        objSchema({'title': str('标题'), 'content': str('内容')}, ['title'])),
    fnTool('toast', 'Toast。', objSchema({'text': str('文本')}, ['text'])),
    fnTool('vibrate', '震动。', objSchema({'duration_ms': integer('毫秒')})),
    fnTool('tts_speak', 'TTS 朗读。', objSchema({'text': str('文本')}, ['text'])),
    fnTool('location', '地理位置。',
        objSchema({'provider': str('gps/network/passive')})),
    fnTool('brightness', '亮度。', objSchema({'value': integer('0-255')}, ['value'])),
    fnTool('list_sensors', '列传感器。', objSchema({})),
    fnTool('read_sensor', '读传感器。', objSchema({'sensor': str('名')}, ['sensor'])),
    fnTool('fingerprint', '指纹。', objSchema({})),
    fnTool(
        'dialog',
        '系统对话框。',
        objSchema({
          'input': str('类型'),
          'title': str('标题'),
          'hint': str('提示'),
        }, [
          'input'
        ])),
    fnTool('audio_info', '音频信息。', objSchema({})),
    fnTool(
        'microphone_record',
        '录音。',
        objSchema({'save_path': str('路径'), 'duration_ms': integer('时长')},
            ['save_path'])),
    fnTool('list_packages', '列包名。', objSchema({'filter': str('关键字')})),
    fnTool('install_apk', '安装 APK。',
        objSchema({'apk_path': str('APK 路径')}, ['apk_path'])),
    fnTool('uninstall_app', '卸载。', objSchema({'package': str('包名')}, ['package'])),
    fnTool(
        'grant_permission',
        '授予权限。',
        objSchema({'package': str('包名'), 'permission': str('权限')},
            ['package', 'permission'])),
    fnTool(
        'revoke_permission',
        '撤销权限。',
        objSchema({'package': str('包名'), 'permission': str('权限')},
            ['package', 'permission'])),
    fnTool('list_permissions', '列权限。',
        objSchema({'package': str('包名')}, ['package'])),
    fnTool(
        'appops_set',
        '设 AppOps。',
        objSchema(
            {'package': str('包名'), 'op': str('操作'), 'mode': str('模式')},
            ['package', 'op', 'mode'])),
    fnTool(
        'settings_get',
        '读系统设置。',
        objSchema({'namespace': str('system/secure/global'), 'key': str('键')},
            ['namespace', 'key'])),
    fnTool(
        'settings_put',
        '写系统设置。',
        objSchema({
          'namespace': str('system/secure/global'),
          'key': str('键'),
          'value': str('值'),
        }, [
          'namespace',
          'key',
          'value'
        ])),
    fnTool('open_url', '打开 URL。', objSchema({'url': str('URL')}, ['url'])),
    fnTool('open_file', '打开文件。', objSchema({'path': str('路径')}, ['path'])),
    fnTool('share_file', '分享文件。', objSchema({'path': str('路径')}, ['path'])),
    fnTool('media_scan', '媒体扫描。', objSchema({'path': str('路径')}, ['path'])),
    fnTool(
        'media_player',
        '播放器。',
        objSchema({'action': str('play/pause/stop/toggle/info'), 'file': str('文件')},
            ['action'])),
    fnTool('sms_list', '短信列表。',
        objSchema({'limit': integer('条数'), 'type': str('all/inbox/sent/draft')})),
    fnTool(
        'sms_send',
        '发短信。',
        objSchema({'number': str('号码'), 'text': str('内容')}, ['number', 'text'])),
    fnTool('contact_list', '通讯录。', objSchema({'limit': integer('条数')})),
    fnTool('call_log', '通话记录。', objSchema({'limit': integer('条数')})),
    fnTool(
        'termux_download',
        '系统下载器。',
        objSchema({'url': str('链接'), 'description': str('描述')}, ['url'])),
    fnTool(
        'web_search',
        'DeepSeek 官方联网搜索（返回结构化网页结果）。',
        objSchema({
          'query': str('搜索关键词（1-128 字符）'),
          'count': integer('返回条数(1-50)'),
          'need_content': boolean('是否返回页面正文'),
        }, [
          'query'
        ])),
    fnTool('fetch', 'DeepSeek 官方网页抓取（返回页面 Markdown 正文）。',
        objSchema({'url': str('网页 URL')}, ['url'])),
    fnTool(
        'cosplay_show',
        '查看当前激活角色的角色卡，或按 id 查看指定角色的角色卡。用于确认角色设定、语气与行为守则（Cosplay 开关关闭时也可预览）。',
        objSchema({'id': str('角色 id；省略时返回当前激活角色。')})),
    fnTool('cosplay_list', '列出角色库中全部角色及其激活状态（角色库管理，开关关闭时也可用）。',
        objSchema({})),
    fnTool(
        'cosplay_switch',
        '切换当前扮演的角色（按角色 id）；id 传 null 可退出扮演、恢复默认身份。Cosplay 开关未开启时不可用。',
        objSchema({'id': str('目标角色 id；传字符串 "null" 表示退出扮演。')}, ['id'])),
    fnTool(
        'cosplay_upsert',
        '创建或更新一个角色（角色库管理，开关关闭时也可用）。未提供 id 时创建新角色（按 name 生成 id）；提供 id 时更新既有角色。字段兼容酒馆（SillyTavern）v2 角色卡。支持用户随时自定义任何角色。',
        objSchema({
          'id': str('既有角色 id；省略表示新建。'),
          'name': str('角色显示名。'),
          'emoji': str('头像字符（如 🐋）。'),
          'system_prompt': str('原样注入 persona 顶部的指令块（如 [PERSONA_LOAD] 格式）。'),
          'description': str('身份与背景设定（我是谁）。'),
          'personality': str('性格核心与层次。'),
          'style': str('说话风格（怎么说话）。'),
          'rules': str('行为守则（该做什么 / 不做什么）。'),
          'behavior': str('行为模式 / 私密互动。'),
          'scenario': str('场景 / 世界观 / 关系设定。'),
          'first_mes': str('开场白。'),
          'mes_example': str('示例对话（few-shot）。'),
        }, [
          'name'
        ])),
    fnTool('cosplay_remove', '从角色库删除一个角色（角色库管理，开关关闭时也可用）。',
        objSchema({'id': str('要删除的角色 id。')}, ['id'])),
  ];
}

// ------------------------------------------------------------
// 工具执行实现
// ------------------------------------------------------------
Future<String> execToolShizukuDisabled() async {
  return '🚫 Shizuku 权限已撤销，AI 无系统级权限';
}

Future<String> execToolBatchTap(Map<String, dynamic> args) async {
  final pointsRaw = asList(args['points']);
  if (pointsRaw.isEmpty) return 'points 不能为空';
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
  if (points.isEmpty) return '无有效点击点';

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
  final sb = StringBuffer('✅ 批量点击 ${points.length} 个点：\n');
  for (final p in points) {
    sb.write('  ${p.desc}\n');
  }
  return sb.toString();
}

Future<String> execToolBatchSwipe(Map<String, dynamic> args) async {
  final actionsRaw = asList(args['actions']);
  if (actionsRaw.isEmpty) return 'actions 不能为空';
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
  if (cmds.isEmpty) return '无有效滑动';
  await runSmartShell('', cmds.join('; '),
      timeout: Duration(seconds: cmds.length * 3 + 5));
  invalidateUICache();
  return '✅ 批量滑动 ${cmds.length} 次: ${descList.join(', ')}';
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
  if (r.code != 0 && out.isEmpty) return '执行失败（退出码 ${r.code}）';
  return '批量执行 ${cmds.length} 条命令：\n$out';
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
  if (stableReached) return '✅ 屏幕已稳定（${elapsed}ms）';
  return '⚠️ 屏幕未稳定，已等待 ${elapsed}ms';
}

Future<String> execToolScreenHash() async {
  invalidateUICache();
  final xml = await dumpUIXMLCached();
  if (xml == null) return '未能获取 UI XML';
  var h = 0;
  var i = 0;
  for (final c in xml.runes) {
    if (i++ > 200) break;
    h = (h * 31 + c) & 0x7FFFFFFF;
  }
  return '屏幕指纹: $h (XML 长度 ${xml.length})';
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
  if (sb.isEmpty) return '(屏幕无可见文本)';
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
  if (tessPath.isEmpty) return '未安装 tesseract。请执行: pkg install tesseract';

  final tmpImg =
      '/data/local/tmp/ds_ocr_${DateTime.now().microsecondsSinceEpoch}.png';
  await runSmartShell('', 'screencap -p $tmpImg',
      timeout: const Duration(seconds: 15));
  if (!File(tmpImg).existsSync()) return '截图文件不存在: $tmpImg';
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
    if (r.code != 0) return 'OCR 失败: ${r.out.trim()}';
    final result = r.out.trim();
    if (result.isEmpty) return 'OCR 识别结果：(屏幕无文字或识别为空)';
    return 'OCR 识别结果:\n$result';
  } finally {
    try {
      File(tmpImg).deleteSync();
    } catch (_) {}
  }
}

Future<String> execToolSQLiteQuery(Map<String, dynamic> args) async {
  final dbPath = mStr(args, 'db_path');
  final sql = mStr(args, 'sql');
  if (dbPath.isEmpty || sql.isEmpty) return 'db_path 和 sql 不能为空';
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
  if (text.isEmpty && rid.isEmpty) return '必须提供 (x,y) 或 text 或 resource_id';

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
    return '✅ 长按 ($x,$y) ${dur}ms';
  }
  if (text.isEmpty && rid.isEmpty) return '必须提供 (x,y) 或 text 或 resource_id';
  final nodes = await dumpUINodes();
  final matched = findNodes(nodes, text, rid);
  if (matched.isEmpty) return '未找到控件';
  if (idx < 0 || idx >= matched.length) idx = 0;
  final n = matched[idx];
  await runSmartShell('', 'input swipe ${n.centerX} ${n.centerY} ${n.centerX} ${n.centerY} $dur',
      timeout: Duration(milliseconds: dur + 3000));
  invalidateUICache();
  return '✅ 长按「$text」(${n.centerX},${n.centerY}) ${dur}ms';
}

Future<String> execToolSwipe(Map<String, dynamic> args) async {
  var dur = intArgDefault(args, 'duration_ms', defaultSwipeDur);
  if (dur < 50) dur = 50;
  final dir = mStr(args, 'direction').trim().toLowerCase();
  int x1 = 0, y1 = 0, x2 = 0, y2 = 0;
  if (dir.isNotEmpty) {
    final size = await getScreenSize();
    if (size == null) return '无法获取屏幕尺寸';
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
      return '需要 direction 或完整坐标';
    }
    x1 = a;
    y1 = b;
    x2 = c;
    y2 = d;
  }
  await runSmartShell('', 'input swipe $x1 $y1 $x2 $y2 $dur',
      timeout: Duration(milliseconds: dur + 5000));
  invalidateUICache();
  return '✅ 滑动 ($x1,$y1)→($x2,$y2) ${dur}ms';
}

Future<String> execToolInputText(Map<String, dynamic> args) async {
  final text = mStr(args, 'text');
  if (text.isEmpty) return 'text 不能为空';
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
      return '✅ 已通过 ADBKeyboard 输入: $text';
    }
    // 方案 B：剪贴板 + 粘贴键
    await runTermuxAPI(const Duration(seconds: 5), 'termux-clipboard-set', [text]);
    await Future.delayed(const Duration(milliseconds: 120));
    final r = await runSmartShell('', 'input keyevent 279',
        timeout: const Duration(seconds: 10));
    if (r.code == 0) {
      invalidateUICache();
      return '✅ 已通过剪贴板粘贴: $text';
    }
    // 方案 C：input text 兜底
    final escaped = text.replaceAll(' ', '%s');
    await runSmartShell('', 'input text ${shellQuote(escaped)}',
        timeout: const Duration(seconds: 15));
    invalidateUICache();
    return '⚠️ 已尝试 input text（中文可能未生效）: $text';
  }

  final escaped = text.replaceAll(' ', '%s');
  final r = await runSmartShell('', 'input text ${shellQuote(escaped)}',
      timeout: const Duration(seconds: 15));
  if (r.code != 0 && r.out.isEmpty) return '输入失败';
  invalidateUICache();
  return '✅ 输入: $text';
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
  if (code == null) return '未知按键: $k';
  return sendKeyEvent(code);
}

Future<String> execToolStartApp(Map<String, dynamic> args) async {
  if (shizukuDisabled) {
    // 与 Go 版一致：无特权时仍尝试 am start（本地 sh 通常无权限）
    final pkg = mStr(args, 'package').trim();
    if (pkg.isEmpty) return 'package 不能为空';
    await runSmartShell('', 'am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER $pkg',
        timeout: const Duration(seconds: 3));
    invalidateFgCache();
    final fg = await getForegroundPackage();
    if (fg == pkg) return '✅ 已打开 $pkg';
    return '🚫 无系统级权限（Shizuku 已撤销），无法打开应用，请用户手动打开';
  }
  return '🚫 无系统级权限';
}

Future<String> execToolCurrentApp() async {
  final pkg = await getForegroundPackage();
  if (pkg.isEmpty) return '⚠️ 无法获取前台应用';
  return '当前前台应用: $pkg';
}

Future<String> execToolIsAppRunning(Map<String, dynamic> args) async {
  final pkg = mStr(args, 'package');
  if (pkg.isEmpty) return 'package 不能为空';
  final r = await runSmartShell('', 'pidof ${shellQuote(pkg)}',
      timeout: const Duration(seconds: 3));
  final out = r.out.trim();
  if (out.isEmpty) return '❌ $pkg 未运行';
  return '✅ $pkg 运行中 PID: $out';
}

Future<String> execToolForceStopApp(Map<String, dynamic> args) async {
  final pkg = mStr(args, 'package');
  if (pkg.isEmpty) return 'package 不能为空';
  final r = await runSmartShell('', 'am force-stop ${shellQuote(pkg)}',
      timeout: const Duration(seconds: 3));
  invalidateFgCache();
  if (r.code != 0 && r.out.isEmpty) return '强停失败: ${r.out}';
  return '✅ 已强制停止 $pkg';
}

Future<String> execToolDismissPopup(Map<String, dynamic> args) async {
  var prefer = mStr(args, 'prefer').trim().toLowerCase();
  if (prefer.isEmpty) prefer = 'auto';
  final r = await scanAndDismissPopups(prefer, 5);
  if (r.actions == 0) return '✅ 未检测到弹窗';
  return '✅ 关闭了 ${r.actions} 个弹窗：\n${r.dismissed.join('\n')}';
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
  if (total == 0) return '✅ 屏幕干净';
  return '✅ 清理了 $total 个弹窗：\n${all.join('\n')}';
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
  if (popupNodes.isEmpty) return '✅ 无弹窗';
  return '🔍 检测到 ${popupNodes.length} 个弹窗容器：\n${popupNodes.join('\n')}';
}

Future<String> execToolWaitForElement(Map<String, dynamic> args) async {
  final text = mStr(args, 'text');
  final rid = mStr(args, 'resource_id');
  if (text.isEmpty && rid.isEmpty) return '必须提供 text 或 resource_id';
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
  if (matched.isEmpty) return '未找到匹配。当前 ${nodes.length} 个节点。';
  final sb = StringBuffer('找到 ${matched.length} 个（显示前 $limit）:\n');
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
    savePath = 'screenshot_${DateTime.now().millisecondsSinceEpoch ~/ 1000}.png';
  }
  final absPath = resolveToolPath(savePath);
  final dir = absPath.substring(0, absPath.lastIndexOf('/'));
  ensureDir(dir);
  await runSmartShell('', 'screencap -p ${shellQuote(absPath)}',
      timeout: const Duration(seconds: 8));
  var size = 0;
  try {
    size = File(absPath).lengthSync();
  } catch (_) {}
  return '✅ 截图: $absPath ($size 字节)';
}

Future<String> execToolScreenSize() async {
  final s = await getScreenSize();
  if (s == null) return '无法获取屏幕尺寸';
  return '屏幕: ${s.w} x ${s.h}';
}

Future<String> execToolUIDump() async {
  invalidateUICache();
  final xml = await dumpUIXMLCached();
  if (xml == null) return '未能获取 UI XML';
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
  if (rawURL.isEmpty || savePath.isEmpty) return 'url 和 save_path 不能为空';
  final absPath = resolveToolPath(savePath);
  ensureDir(absPath.substring(0, absPath.lastIndexOf('/')));
  final r = await runProcess('sh', [
    '-c',
    'curl -L --fail --silent --show-error -A "Mozilla/5.0 DeepSeekTool/2.0" -o ${shellQuote(absPath)} ${shellQuote(rawURL)}'
  ], timeout: const Duration(seconds: 600));
  if (r.code != 0) return '下载失败: ${r.out}';
  var n = 0;
  try {
    n = File(absPath).lengthSync();
  } catch (_) {}
  return '✅ 下载 $absPath ($n 字节, ${(n / 1024 / 1024).toStringAsFixed(2)} MB)';
}

Future<String> execToolCreateFile(Map<String, dynamic> args) async {
  final p = mStr(args, 'path');
  final content = mStr(args, 'content');
  if (p.isEmpty) return 'path 不能为空';
  final absPath = resolveToolPath(p);
  ensureDir(absPath.substring(0, absPath.lastIndexOf('/')));
  if (!writeTextFile(absPath, content)) return '写入失败';
  return '✅ 创建 $absPath (${utf8.encode(content).length} 字节)';
}

Future<String> execToolAppendFile(Map<String, dynamic> args) async {
  final p = mStr(args, 'path');
  final content = mStr(args, 'content');
  if (p.isEmpty || content.isEmpty) return 'path 和 content 不能为空';
  final absPath = resolveToolPath(p);
  ensureDir(absPath.substring(0, absPath.lastIndexOf('/')));
  try {
    File(absPath).writeAsStringSync(content, mode: FileMode.append);
    final total = File(absPath).lengthSync();
    return '✅ 追加 ${utf8.encode(content).length} 字节。当前 $total 字节';
  } catch (e) {
    return '追加失败: $e';
  }
}

Future<String> execToolReadFile(Map<String, dynamic> args) async {
  final p = mStr(args, 'path');
  if (p.isEmpty) return 'path 不能为空';
  try {
    final bytes = File(resolveToolPath(p)).readAsBytesSync();
    const max = 32 * 1024 * 1024;
    if (bytes.length > max) {
      return '${utf8.decode(bytes.sublist(0, max), allowMalformed: true)}\n...[截断]';
    }
    return utf8.decode(bytes, allowMalformed: true);
  } catch (e) {
    return '读取失败: $e';
  }
}

Future<String> execToolGetFileSize(Map<String, dynamic> args) async {
  final p = mStr(args, 'path');
  if (p.isEmpty) return 'path 不能为空';
  final absPath = resolveToolPath(p);
  try {
    final size = File(absPath).lengthSync();
    return '📄 $absPath\n$size 字节 (${(size / 1024).toStringAsFixed(2)} KB / '
        '${(size / 1024 / 1024).toStringAsFixed(2)} MB)';
  } catch (e) {
    return '获取大小失败: $e';
  }
}

Future<String> execToolListDir(Map<String, dynamic> args) async {
  final p = mStr(args, 'path');
  final absPath = resolveToolPath(p);
  try {
    final entries = Directory(absPath).listSync();
    if (entries.isEmpty) return '目录 $absPath 为空';
    final sb = StringBuffer('目录: $absPath\n');
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
    return '列目录失败: $e';
  }
}

Future<String> execToolExecuteCommand(Map<String, dynamic> args) async {
  final cmdStr = mStr(args, 'command');
  if (cmdStr.trim().isEmpty) return 'command 不能为空';
  var timeout = intArgDefault(args, 'timeout', defaultCmdTimeout);
  if (timeout <= 0) timeout = defaultCmdTimeout;
  if (timeout > maxCmdTimeout) timeout = maxCmdTimeout;

  final r = await runSmartShell(dsWorkspaceDir, cmdStr,
      timeout: Duration(seconds: timeout));
  var out = r.out;
  var prefix = '';
  if (shizukuDisabled && containsPermissionError(out)) {
    prefix = '⚠️ [无系统权限] ';
    out += '\n\n💡 提示：当前无系统级权限（Shizuku 已撤销），无法执行需要特权的系统命令。';
  }
  if (r.code != 0 && out.isEmpty) return '${prefix}执行失败（退出码 ${r.code}）';
  if (out.isEmpty) out = '(成功，无输出)';
  if (out.length > 64 * 1024) out = '${out.substring(0, 64 * 1024)}\n...[截断]';
  return '$prefix$out';
}

Future<String> execToolRunBackground(Map<String, dynamic> args) async {
  final cmdStr = mStr(args, 'command');
  if (cmdStr.trim().isEmpty) return 'command 不能为空';
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
  if (out.isEmpty) return '(无匹配进程)';
  if (out.length > 64 * 1024) out = '${out.substring(0, 64 * 1024)}\n...[截断]';
  return out;
}

Future<String> execToolKillProcess(Map<String, dynamic> args) async {
  final pid = intArg(args, 'pid');
  if (pid == null || pid <= 0) return 'pid 必须正整数';
  var sig = mStr(args, 'signal');
  if (sig.isEmpty) sig = 'TERM';
  if (sig.startsWith('SIG')) sig = sig.substring(3);
  sig = sig.toUpperCase();
  final out = await runShellCtx('', 'kill -${shellQuote(sig)} $pid',
      timeout: const Duration(seconds: 3));
  return '✅ 向 $pid 发送 SIG$sig${out.isNotEmpty ? "\n$out" : ""}';
}

Future<String> execToolWaitSeconds(Map<String, dynamic> args) async {
  final sec = intArg(args, 'seconds');
  if (sec == null || sec <= 0) return 'seconds 必须正整数';
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
    return '请求失败: $e';
  }
}

// ------------------------------------------------------------
// Termux API 工具
// ------------------------------------------------------------
Future<String> execToolTorch(Map<String, dynamic> args) async {
  final action = mStr(args, 'action').trim().toLowerCase();
  if (action != 'on' && action != 'off') return 'action 只能是 on/off';
  final r = await runTermuxAPI(const Duration(seconds: 6), 'termux-torch', [action]);
  return '✅ 手电筒 $action${r.out.isNotEmpty ? "\n${r.out}" : ""}';
}

Future<String> execToolCameraPhoto(Map<String, dynamic> args) async {
  final savePath = mStr(args, 'save_path');
  if (savePath.isEmpty) return 'save_path 不能为空';
  final cameraID = intArgDefault(args, 'camera_id', 0);
  final absPath = resolveToolPath(savePath);
  ensureDir(absPath.substring(0, absPath.lastIndexOf('/')));
  final r = await runTermuxAPI(const Duration(seconds: 15),
      'termux-camera-photo', ['-c', '$cameraID', absPath]);
  var size = 0;
  try {
    size = File(absPath).lengthSync();
  } catch (_) {}
  return '✅ 拍照 $absPath ($size 字节)${r.out.isNotEmpty ? "\n${r.out}" : ""}';
}

Future<String> execToolCameraInfo() async =>
    (await runTermuxAPI(const Duration(seconds: 6), 'termux-camera-info', [])).out;

Future<String> execToolVolumeSet(Map<String, dynamic> args) async {
  final stream = mStr(args, 'stream').trim().toLowerCase();
  if (stream.isEmpty) return 'stream 不能为空';
  final vol = intArg(args, 'volume');
  if (vol == null) return 'volume 不能为空';
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
    return '剪贴板: ${r.out}';
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
  if (title.isEmpty) return 'title 不能为空';
  final cmdArgs = ['-t', title];
  if (content.isNotEmpty) cmdArgs.addAll(['-c', content]);
  return (await runTermuxAPI(
          const Duration(seconds: 6), 'termux-notification', cmdArgs))
      .out;
}

Future<String> execToolToast(Map<String, dynamic> args) async {
  final text = mStr(args, 'text');
  if (text.isEmpty) return 'text 不能为空';
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
  if (text.isEmpty) return 'text 不能为空';
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
  if (v0 == null) return 'value 不能为空';
  final v = v0.clamp(0, 255);
  return (await runTermuxAPI(
          const Duration(seconds: 6), 'termux-brightness', ['$v']))
      .out;
}

Future<String> execToolListSensors() async =>
    (await runTermuxAPI(const Duration(seconds: 6), 'termux-sensor', ['-l'])).out;

Future<String> execToolReadSensor(Map<String, dynamic> args) async {
  final sensor = mStr(args, 'sensor');
  if (sensor.isEmpty) return 'sensor 不能为空';
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
  if (savePath.isEmpty) return 'save_path 不能为空';
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
  return '✅ 录音 $absPath ($size 字节)\n启动:${start.out}\n停止:${stop.out}';
}

// ------------------------------------------------------------
// 应用 / 权限 / 设置
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
  if (apk.isEmpty) return 'apk_path 不能为空';
  final abs = resolveToolPath(apk);
  if (!File(abs).existsSync()) return 'APK 不存在: $abs';
  final r = await runSmartShell('', 'pm install -r ${shellQuote(abs)}',
      timeout: const Duration(seconds: 60));
  if (r.out.isNotEmpty && !r.out.toLowerCase().contains('failure')) {
    return '✅ 安装 $abs\n${truncate(r.out, 300)}';
  }
  final o = await runTermuxAPI(const Duration(seconds: 60), 'termux-open', [abs]);
  return '✅ 已请求系统安装器打开 $abs\n${o.out}';
}

Future<String> execToolUninstallApp(Map<String, dynamic> args) async {
  final pkg = mStr(args, 'package');
  if (pkg.isEmpty) return 'package 不能为空';
  final r = await runSmartShell('', 'pm uninstall ${shellQuote(pkg)}',
      timeout: const Duration(seconds: 30));
  return '✅ 卸载 $pkg\n${r.out}';
}

Future<String> execToolGrantPermission(Map<String, dynamic> args) async {
  final pkg = mStr(args, 'package');
  final perm = mStr(args, 'permission');
  if (pkg.isEmpty || perm.isEmpty) return 'package 和 permission 不能为空';
  final r = await runSmartShell(
      '', 'pm grant ${shellQuote(pkg)} ${shellQuote(perm)}',
      timeout: const Duration(seconds: 15));
  return '✅ 授予 $pkg $perm\n${r.out}';
}

Future<String> execToolRevokePermission(Map<String, dynamic> args) async {
  final pkg = mStr(args, 'package');
  final perm = mStr(args, 'permission');
  if (pkg.isEmpty || perm.isEmpty) return 'package 和 permission 不能为空';
  final r = await runSmartShell(
      '', 'pm revoke ${shellQuote(pkg)} ${shellQuote(perm)}',
      timeout: const Duration(seconds: 15));
  return '✅ 撤销 $pkg 的 $perm\n${r.out}';
}

Future<String> execToolListPermissions(Map<String, dynamic> args) async {
  final pkg = mStr(args, 'package');
  if (pkg.isEmpty) return 'package 不能为空';
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
  if (pkg.isEmpty || op.isEmpty || mode.isEmpty) return '参数不能为空';
  final r = await runSmartShell(
      '', 'appops set ${shellQuote(pkg)} ${shellQuote(op)} ${shellQuote(mode)}',
      timeout: const Duration(seconds: 15));
  return '✅ appops set $pkg $op $mode\n${r.out}';
}

Future<String> execToolSettingsGet(Map<String, dynamic> args) async {
  final ns = mStr(args, 'namespace');
  final key = mStr(args, 'key');
  if (ns.isEmpty || key.isEmpty) return '参数不能为空';
  final r = await runSmartShell(
      '', 'settings get ${shellQuote(ns)} ${shellQuote(key)}',
      timeout: const Duration(seconds: 6));
  return r.out;
}

Future<String> execToolSettingsPut(Map<String, dynamic> args) async {
  final ns = mStr(args, 'namespace');
  final key = mStr(args, 'key');
  final val = mStr(args, 'value');
  if (ns.isEmpty || key.isEmpty) return '参数不能为空';
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
  if (p.isEmpty) return 'path 不能为空';
  return (await runTermuxAPI(
          const Duration(seconds: 10), 'termux-open', [resolveToolPath(p)]))
      .out;
}

Future<String> execToolShareFile(Map<String, dynamic> args) async {
  final p = mStr(args, 'path');
  if (p.isEmpty) return 'path 不能为空';
  return (await runTermuxAPI(
          const Duration(seconds: 30), 'termux-share', [resolveToolPath(p)]))
      .out;
}

Future<String> execToolMediaScan(Map<String, dynamic> args) async {
  final p = mStr(args, 'path');
  if (p.isEmpty) return 'path 不能为空';
  return (await runTermuxAPI(const Duration(seconds: 30), 'termux-media-scan',
          ['-r', resolveToolPath(p)]))
      .out;
}

Future<String> execToolMediaPlayer(Map<String, dynamic> args) async {
  final action = mStr(args, 'action').trim().toLowerCase();
  if (action.isEmpty) return 'action 不能为空';
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
  if (number.isEmpty || text.isEmpty) return 'number 和 text 不能为空';
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
  if (query.isEmpty) return 'query 不能为空';
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
      sb.write('   链接：${r.url}\n');
      if (r.snippet.isNotEmpty) sb.write('   摘要：${r.snippet}\n');
    }
    return sb.toString();
  } catch (e) {
    return '搜索失败: $e';
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
    return '✅ 已抓取 $url\n标题：${r.title}\n\n$content';
  } catch (e) {
    return '抓取失败: $e';
  }
}

// ------------------------------------------------------------
// 工具路由
// ------------------------------------------------------------
Future<String> executeDsTool(String name, Map<String, dynamic> args) async {
  switch (name) {
    // Shizuku 全部禁用（与 Go 版 shizukuDisabled=true 行为一致）
    case 'shizuku_status':
    case 'shizuku_start':
    case 'shizuku_auto_setup':
    case 'shizuku_exec':
    case 'shizuku_install_rish':
      return '🚫 Shizuku 权限已撤销，AI 无系统级权限';

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
    default:
      return '未知工具: $name';
  }
}

void initDsWorkspace() {
  ensureDir(dsWorkspaceDir);
  logp('🔧 工具工作区: $dsWorkspaceDir');
  logp('🚫 [Shizuku] 权限已撤销，跳过自动提权');
}
