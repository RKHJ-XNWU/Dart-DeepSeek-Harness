# -*- coding: utf-8 -*-
# 本次生成的临时补丁脚本（用完即删）
import io

p = '/data/data/com.termux/files/home/ddsh/lib/src/deepseek_api.dart'
s = io.open(p, encoding='utf-8').read()
orig = s

# ---------- 1) 声明 dbSkipSigs（两处循环前） ----------
decl_old = "  var lastToolSig = '';\n  var repeatCount = 0;\n  final sigSeen = <String, int>{};\n"
decl_new = ("  var lastToolSig = '';\n  var repeatCount = 0;\n  final sigSeen = <String, int>{};\n"
            "  // 豆包通道：被判为「原地打转」的签名，下一轮跳过执行，只回一句换路提示\n"
            "  final dbSkipSigs = <String>{};\n"
            "  var dbSkipTotal = 0;\n")
print('decl 出现次数 =', s.count(decl_old))
s = s.replace(decl_old, decl_new)

# ---------- 2) 流式版工具执行：跳过死循环签名 ----------
old_stream = """      roundSigs.add('$name\\u0000$args');

      await onToolCall?.call('start', name, args, '');
      var result = await dsSafeExecTool(name, args);
"""
new_stream = """      roundSigs.add('$name\\u0000$args');

      await onToolCall?.call('start', name, args, '');
      // 豆包通道 · 死循环签名：不再重复执行同一条命令，直接回一句换路提示
      final sigKey = '$name\\u0000$args';
      var result = dbSkipSigs.contains(sigKey)
          ? ('\\u26d4 该操作已连续多次执行且画面没有变化，本轮已跳过执行。'
              '请先 vd_observe / current_app 重新观察当前状态，'
              '然后换工具、换坐标、换滚动方向或换执行路径，不要在同一个位置继续重试。')
          : await dsSafeExecTool(name, args);
"""
print('stream 锚点 =', s.count(old_stream))
assert s.count(old_stream) == 1
s = s.replace(old_stream, new_stream)

# ---------- 3) 非流式版工具执行：跳过死循环签名 ----------
old_sync = """      roundSigs.add('$name\\u0000$args');
      var result = await dsSafeExecTool(name, args);
"""
new_sync = """      roundSigs.add('$name\\u0000$args');
      // 豆包通道 · 死循环签名：不再重复执行同一条命令，直接回一句换路提示
      final sigKey = '$name\\u0000$args';
      var result = dbSkipSigs.contains(sigKey)
          ? ('\\u26d4 该操作已连续多次执行且画面没有变化，本轮已跳过执行。'
              '请先 vd_observe / current_app 重新观察当前状态，'
              '然后换工具、换坐标、换滚动方向或换执行路径，不要在同一个位置继续重试。')
          : await dsSafeExecTool(name, args);
"""
print('sync 锚点 =', s.count(old_sync))
assert s.count(old_sync) == 1
s = s.replace(old_sync, new_sync)

# ---------- 4) 两处「豆包通道跳过一切检测」改为「豆包通道防原地打转」 ----------
db_block = """    // ★ 豆包通道 · 防原地打转（不拒绝、不硬停任务，只强制换路）
    //   旧实现完全跳过卡死检测，导致豆包把同一条命令反复执行（典型表现：
    //   「一直扫描同一个文件」），既不动也不停，白白烧配额。
    //   新口径（三步，全部是「换路」而不是「拒绝」）：
    //     1) 同一签名连续 2 次 → 注入换路提示；
    //     2) 连续 5 次 / 累计 12 次 → 加入跳过表，下一轮不再真正执行；
    //     3) 累计 30 次 → 跳出循环（保护用户额度），已有日志照常回传。
    if (isDb) {
      final sig = roundSigs.join('\\u0000');
      if (sig.isNotEmpty) {
        if (sig == lastToolSig) {
          repeatCount++;
        } else {
          lastToolSig = sig;
          repeatCount = 1;
        }
        final seen = (sigSeen[sig] = (sigSeen[sig] ?? 0) + 1);
        if (repeatCount == 2) {
          currentMsgs.add({
            'role': 'user',
            'content':
                '【系统提示 · 换路】你刚才执行的操作和上一轮完全相同，画面没有变化。'
                    '不要再用同样的参数重试。下一步请二选一：'
                    '① 先用 vd_observe 或 vd_screenshot 看清当前画面；'
                    '② 换一个工具（改坐标、滚动、返回键、重新启动应用）。'
                    '目标不变，路径必须变。',
          });
        }
        if (repeatCount >= 5 || seen >= 12) {
          dbSkipSigs.add(sig);
          currentMsgs.add({
            'role': 'user',
            'content':
                '【系统提示 · 已跳过该重复操作】同一操作已连续 $repeatCount 次 / 累计 $seen 次，'
                    '画面始终没有变化。该操作已被系统跳过，必须改走别的路径：'
                    '① 重新 vd_observe 读取画面文字与坐标；'
                    '② 用 vd_swipe 滚动或用 vd_key 4 返回上一层；'
                    '③ 用 vd_launch 重新启动目标应用；'
                    '④ 文件扫描类任务改用 execute_command 一次性列出目录，不要逐个文件反复读。',
          });
        }
        if (dbSkipSigs.contains(sig)) dbSkipTotal++;
        if (dbSkipTotal >= 30) {
          logp('\\ud83d\\uded1 [豆包] 同一操作が累計 30 回繰り返されました。'
              'これ以上の空回りを防ぐため、ツール呼び出しを打ち切ります。');
          break;
        }
      }
    }

"""
note = "    // 豆包通道：跳过一切续跑提示 / 累计同签名硬停 / 轮次预算提示。\n"
print('旧注释出现次数 =', s.count(note))
assert s.count(note) == 2
s = s.replace(note, db_block)

io.open(p, 'w', encoding='utf-8').write(s)
print('deepseek_api.dart 已写入，长度 %d → %d' % (len(orig), len(s)))
