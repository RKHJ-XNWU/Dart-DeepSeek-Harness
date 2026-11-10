# -*- coding: utf-8 -*-
# 本次生成的临时补丁脚本（用完即删）
import io

p = '/data/data/com.termux/files/home/ddsh/lib/src/virtual_display.dart'
s = io.open(p, encoding='utf-8').read()
orig = s

# ---------- 1) 缓存 8 秒 → 2 秒（副屏会被系统静默清掉，长缓存会把操作打到不存在的屏） ----------
old = """  if (!force &&
      _vdCachedId >= 0 &&
      DateTime.now().difference(_vdCachedAt) < const Duration(seconds: 8)) {"""
new = """  // 缓存只留 2 秒：实测 overlay_display_devices 会被系统静默清空
  // （例如切后台、息屏、厂商省电策略），旧实现缓存 8 秒，
  // 期间所有 input -d / am start --display 都会打到一个已经不存在的屏，
  // 轻则全部失败，重则 am start 回退主屏 —— 这正是「抢主屏焦点」的根源。
  if (!force &&
      _vdCachedId >= 0 &&
      DateTime.now().difference(_vdCachedAt) < const Duration(seconds: 2)) {"""
assert s.count(old) == 1
s = s.replace(old, new)

# ---------- 2) vdEnsure：配置残留（spec 在、实体没了）时强制重建 ----------
old_ensure = """Future<VdState> vdEnsure({
  int width = vdDefaultWidth,
  int height = vdDefaultHeight,
  int dpi = vdDefaultDpi,
}) async {
  var st = await vdState();
  if (st.ready) return st;
  final spec = '${width}x${height}/$dpi';
  await _vdRun('settings put global $vdOverlayKey "$spec"');
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 350));
    st = await vdState(force: true);
    if (st.ready) return st;
  }
  return st;
}"""
new_ensure = """Future<VdState> vdEnsure({
  int width = vdDefaultWidth,
  int height = vdDefaultHeight,
  int dpi = vdDefaultDpi,
}) async {
  // 这里必须强制刷新：不能吃缓存，否则会把「刚被系统清掉的副屏」当成可用。
  var st = await vdState(force: true);
  if (st.ready) return st;
  final spec = '${width}x${height}/$dpi';
  if (st.configured) {
    // 残留态：设置里还写着规格，但 OverlayDisplayAdapter 已经没有实体。
    // 直接重写同值不会触发重建，必须先清空再写入（实测有效）。
    await _vdRun('settings put global $vdOverlayKey ""');
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  await _vdRun('settings put global $vdOverlayKey "$spec"');
  for (var i = 0; i < 16; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 350));
    st = await vdState(force: true);
    if (st.ready) return st;
  }
  return st;
}

/// 自愈：把「已配置但不可用」的副屏拉回可用态。
/// 供上层在每次豆包工具批次开始前调用，返回修复后的状态。
Future<VdState> vdSelfHeal() async {
  var st = await vdState(force: true);
  if (st.ready) return st;
  st = await vdEnsure();
  return st;
}"""
assert s.count(old_ensure) == 1
s = s.replace(old_ensure, new_ensure)

# ---------- 3) vdLaunch：启动后校验副屏真的出画面，避免「假装成功」 ----------
old_launch = """  final out = await _vdRun(cmd, timeoutSec: 40);
  final low = out.toLowerCase();
  final bad = low.contains('error') ||
      low.contains('exception') ||
      low.contains('does not exist');
  return VdOpResult(!bad, out.trim(), id);
}"""
new_launch = """  final out = await _vdRun(cmd, timeoutSec: 40);
  final low = out.toLowerCase();
  final bad = low.contains('error') ||
      low.contains('exception') ||
      low.contains('does not exist');
  if (bad) {
    return VdOpResult(false, '❌ 副屏启动失败：${out.trim()}\\n'
        '提示：先 vd_create 确认副屏就绪，再重试 vd_launch。', id);
  }
  // 启动成功只是命令成功，副屏是否真的出画面要单独验证：
  // 副屏无窗口时 screencap 会产出 0 字节，据此判断，不假装成功。
  await Future<void>.delayed(const Duration(milliseconds: 700));
  final has = await vdHasContent();
  if (!has) {
    return VdOpResult(
        false,
        '⚠️ 命令已发送，但副屏仍无画面（screencap 为空）。\\n'
        '可能原因：① 副屏被系统清掉（先 vd_create / vd_status 复查）；'
        '② 目标应用不支持在多显示器上启动；③ 应用启动较慢，可稍后 vd_observe 复查。\\n'
        '输出：${out.trim()}',
        id);
  }
  return VdOpResult(true, '✅ 已在副屏启动：${t}（displayId=$id，画面已出现）', id);
}"""
assert s.count(old_launch) == 1
s = s.replace(old_launch, new_launch)

io.open(p, 'w', encoding='utf-8').write(s)
print('virtual_display.dart 已写入，%d → %d' % (len(orig), len(s)))
