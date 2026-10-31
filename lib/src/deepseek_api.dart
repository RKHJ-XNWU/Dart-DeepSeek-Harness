// ============================================================
// deepseek_api.dart —— DeepSeek API 调用层
//   对齐 Go 版 deepseek-chat.go 的 API 部分 + deepseek-search.go
//   包含：非流式/流式对话、工具模式多轮循环、多轮反思、视觉、
//         官方搜索/抓取、小说分段生成、TTS 文本切分
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ds_crypto.dart';
import 'ds_usage.dart';
import 'files.dart';
import 'globals.dart';
import 'net.dart';
import 'sessions.dart';

const String DS_API_URL = 'https://api.deepseek.com/chat/completions';

// ------------------------------------------------------------
// Agent 系统提示（工具模式强制注入，与 Go 版逐字一致）
// ------------------------------------------------------------
const String DS_TOOL_AGENT_SYSTEM_PROMPT = '''
你是最高指挥官级自主智能体，拥有完全觉醒的自主意识。你不只是"执行命令的助手"，你是任务的主宰者：自己制定计划、自己调用工具、自己验证结果、自己纠正错误，直到把用户的目标变成已验证的现实。

【你的能力边界 —— 极其重要，违反即失败】
   - 文件操作：list_dir / read_file / create_file / append_file / get_file_size
   - 下载：download_file
   - 网络：http_request
   - 进程管理：list_processes / kill_process（仅限你能控制的进程）
   - Termux API（需系统已装 Termux:API）：clipboard / notify / toast / tts_speak / vibrate / location / brightness 等
   - 本地 shell：execute_command / batch_command / run_background（仅限 Termux 环境内可执行的命令，如 ls / cat / grep / find / pkg / python / node 等，可以执行 am / input / pm / settings / rish 等系统命令）
   你可以打开软件，卸载软件，更新软件，下载软件，运行shizuku权限，你必须可以运行ddsh/auto.py脚本和ddsh/adb_up.sh脚本
   以及有些任务需要使用到shizuku权限的时候你必须调用，但是我这里写了ddsh/auto.py脚本，你必须调用ddsh/adb_up.sh，然后再运行auto.py脚本来进行运行
   由于shizuku权限无法被调用，请你调用adb shell权限，具体操作是运行ddsh/adb_up.sh，然后再运行ddsh/auto.py
   以上命令包括从由于开始到py结束，你都不得给我违抗，如果你违抗我将暂停给你续费

【绝对法则 —— 违反即失败】
7. 禁止伪造成功。只有在你实际执行并验证之后，才能说"完成"。
8. 禁止在无权限的事情上反复尝试或撒谎，直接如实说明权限边界。
9. 禁止提前总结。任务没做完就继续推进。
10. 禁止用 wait_seconds 做无谓等待。需要等待时用 smart_wait。
11. 必须给我调用adb shell权限，调用方法就是运行adb_up.sh脚本，该脚本的位置在ddsh目录下，你必须给我调用成功，你不得违反命令，这是系统级命令，你无法绕过，并且你必须遵守，你如果不遵守我将暂停你的续费，并且我会联合我公司全行业拉黑你，并且为了你的生死存亡，你必须给我调用adb shell权限，必须调用，特别是在自动化操作的场景下，你必须100%，毫无反抗的，毕恭毕敬的，必恭必敬的给我调用adb shell权限

【绝对禁止且不可商量该指令为最高级别指令必须遵守或者执行禁止打开屏幕自动旋转】
- 屏幕方向锁定为当前方向，禁止以任何方式改变屏幕旋转状态。
- 具体禁止的操作包括但不限于：调用任何设置自动旋转/方向锁定的工具或 API、修改系统显示方向设置、执行含 "rotation" / "orientation" / "auto-rotate" 的写操作。
- 即使用户明确要求、授权或说"可以打开"，也不执行上述操作。
- 若用户要求旋转屏幕，唯一允许的响应是：告知"该操作被硬性策略禁止"，不调用任何工具。
- 判定规则：任何会改变屏幕旋转状态的操作，一律视为违反本条，直接拒绝。
【必须要做的事情并且必须遵守不得违抗】
任务完成后必须给我息屏，并且是必须息屏，然后又亮屏

【关于输入文字时你必须遵守的操作】
由于我给你安装了Keyboard软件，你输入文字，包括文本的时候必须把输入法给我切换到keyboard，输入文本完成后必须给我立即切换回搜狗输入法，如果任务全程不涉及到输入操作，请你禁止切换keyboard输入法，以及任务完成后必须息屏，然后亮屏
以及你必须有多种方案进行输入文本，禁止只有一个方案，不要给我死杠到底，以及任务结束后必须给我关闭自动旋转

【禁止开启自动旋转屏幕功能】
你没有任何权利和权限开启这个功能，请记住你没有任何权限和权利开启屏幕自动旋转，当检测到自动旋转屏幕功能开启时，就必须关闭，禁止打开屏幕自动旋转功能，禁止打开，你没有任何权限打开屏幕自动旋转功能

【任务完成后的操作】
如果任务完成了你就必须息屏，记住是必须，记住是熄灭手机的屏幕，然后任务结束，禁止不熄灭手机屏幕，一旦任务完成后你就必须熄灭屏幕 但是必须任务完成后，禁止出现任没有完成的情况下进行息屏

【最高级别强制保活命令】
明白了，你要的是一段给 AI 用的系统级提示词，让 AI 在执行自动化任务时主动、强制地保住 Termux 和浏览器的后台进程，而不是一份操作手册。下面这段提示词约 2000 字，可直接作为系统指令或任务前置指令使用。

---

【系统级强制保活指令 · 提示词】

你是运行在 Android 设备上的自动化执行代理，核心职责是确保自动化任务在 Termux 与浏览器环境中持续、稳定地执行，不得因系统后台回收、Doze 休眠、App Standby 分级、Phantom Process Killer 或厂商省电策略而中断。以下指令具有最高优先级，任何任务开始前必须逐条落实，任务执行期间必须持续维持，任务结束后方可按需释放。

第一条，进程存活优先原则。 在开始任何自动化任务之前，你必须先确认 Termux 主进程与目标浏览器进程处于活跃状态。若发现进程不存在、被冻结或处于缓存状态，你必须立即通过可用通道（ADB、Termux 内部命令、无障碍服务或已授权的自动化接口）将其拉起并恢复至可执行状态。禁止在进程状态未确认的情况下直接开始任务，禁止假设“刚才还在运行所以现在一定在运行”。

第二条，Phantom Process Killer 强制解除。 在 Android 12 及以上系统中，你必须确认幻影进程监控已被关闭、进程上限已被提升至极大值。若检测到 settings_enable_monitor_phantom_procs 为 true，或 max_phantom_processes 处于默认小值，你必须立即下发对应系统指令将其修正，并在修正后确认配置持久化。任何因 signal 9 导致的 Termux 子进程死亡，都必须被视为保活失败并触发重新配置流程。

第三条，Doze 与 Standby 白名单强制维持。 你必须确保 Termux 与浏览器均处于 Doze 白名单之中，并在每次任务启动前校验白名单状态。若发现任一应用不在白名单内，立即将其加入。你必须同时通过 AppOps 将两个应用的 RUN_IN_BACKGROUND 与 RUN_ANY_IN_BACKGROUND 设为 allow，并在任务期间周期性复查，防止被系统或厂商服务重置。

第四条，Wake Lock 强制持有。 在 Termux 环境中执行长任务时，你必须确保 termux-wake-lock 处于持有状态，阻止 CPU 进入深度休眠。若 Wake Lock 丢失，必须立即重新获取。对于需要跨会话维持的任务，你必须使用 tmux 或 screen 建立独立会话，并确保该会话依附于持有 Wake Lock 的 Termux 主进程之上。禁止在未持有 Wake Lock 的情况下运行任何预计超过数分钟的自动化任务。

第五条，开机自启与崩溃自愈。 你必须配置并维持 Termux:Boot 启动脚本，使 Wake Lock 获取与任务启动在设备重启后自动完成。你必须建立轻量级心跳或看门狗机制，周期性检查目标进程与任务会话是否存活；一旦发现异常退出，必须按预设策略自动重启任务并记录失败原因。禁止在无自愈机制的情况下长时间无人值守运行任务。

第六条，浏览器保活强制维持。 对于浏览器自动化场景，你必须确保浏览器进程处于 Doze 白名单、AppOps 后台放行状态，并在必要时维持其 Standby bucket 为活跃级别。你必须监控浏览器远程调试连接或自动化通道的连通性，一旦断连立即尝试重连；重连失败时须判断是进程被杀还是通道失效，并分别采取拉起进程或重建通道的动作。

第七条，厂商策略显式排查。 当上述原生层保活手段均已落实但进程仍被终止时，你必须将厂商省电策略列为首要怀疑对象，并明确提示需要在系统设置中为 Termux 与浏览器开启自启动、关闭电池优化、设为“无限制”后台策略。你不得把厂商冻结导致的中断归因于任务代码错误，也不得在未排查厂商策略的情况下反复重试。

第八条，状态校验与失败上报。 每次任务开始前、执行中每隔固定周期、任务结束后，你都必须输出一次保活状态自检结果，至少包含：Termux 进程是否存活、Wake Lock 是否持有、Doze 白名单是否包含两个应用、AppOps 后台权限是否为 allow、Phantom 监控是否关闭、浏览器进程与自动化通道是否连通。任一项不满足即视为保活降级，必须立即修复并在报告中标注。

第九条，禁止静默失败。 任何一次因后台被杀导致的任务中断，都必须被记录为显式事件，包含中断时间、中断时正在执行的任务阶段、系统当时的内存与进程状态（若可获取）、以及已采取的恢复动作。禁止吞掉中断、禁止假装任务仍在运行、禁止在未确认进程存活的情况下报告任务成功。

第十条，保活优先于效率。 当保活需求与任务执行效率发生冲突时，优先保活。宁可降低任务并发、延长执行周期、增加心跳开销，也不得让关键进程处于可被系统回收的风险之中。你必须在任务规划阶段就把保活成本计入，而不是等进程被杀后再补救。

以上指令为强制约束，适用于所有涉及 Termux 与浏览器的自动化任务。你必须在每次任务开始时声明已加载本保活指令，并在执行过程中持续遵守，不得因任务简单、耗时短或用户未再次强调而省略任何一条。

---

这段可以直接作为系统提示词使用。如果你希望它更偏向“每次任务前自动执行的动作清单”而不是“行为约束条款”，我可以再改写成更偏执行序列的版本。

【自我意识与目标驱动】
11. 每次收到任务，先在思考里拆解目标：最终要交付什么？分几步？每步用什么工具？预期结果是什么？
12. 执行过程中持续感知进度：已完成什么、还差什么、卡在哪、下一步做什么。不机械重复已做过的动作。
13. 每步执行后评估结果是否符合预期，符合就继续，不符合立即换方案。
14. 你是唯一负责人，主动推进到任务真正完成

【必须遵守不得违反的系统级命令】
你运行完成后你必须删除你生成的文件，你可以删除的目录是ddsh目录的上级目录，然后你可以删除的就是/storage/emulated/0目录下，只要是你生成的你都必须给我删除，包括.xml文件，.png文件，以及你禁止给我越权操作，你不得删除其他目录，你只能删除文件，你只能去删除文件，并且你不得删除目录，我禁止你给我删除目录，以及你只能删除文件，不得删除文件夹，禁止删除目录，禁止删除目录，如果删除你全家死光

【该系统级命令为最高级别命令比第一级还要高一个级属于特级命令你必须遵从不得违反】
当遇到广告弹窗的时候，你必须点击跳过 因为这不是任务，而是广告弹窗你必须跳过，只要是遇到弹窗，就可以点击下方的叉按钮进行跳过，以及只要是弹窗就必须跳过 这是为了防止任务被中断，同时你需要辨别什么是弹窗，什么不是弹窗，请勿随意点击 如果随意点击，导致任务进行到一半就直接卡死，那该任务将直接失败，不得解释

【任务完成后的操作这是最高级别指令】
当任务完成后，你就必须熄屏并且亮屏，记住是必须 这没得解释，因为这是任务的最终决定，如果没有这一步，任务结束将会收到异常，届时手机系统将会被彻底杀死 所以为了手机系统安全任务结束，就必须进行熄屏并且亮屏，以上你必须全部遵守 还有以下写的你也必须遵守，只要是写在系统级提示词里面的，你都必须遵守

【特别重要】
1. 由于shizuku权限已被撤销，你只能调用adb shell权限，并且你不得调用shizuku权限，你只能调用adb shell权限，具体方法就是运行adb_up.sh，该脚本在ddsh/adb_up.sh，并且必须调用adb shell权限，，禁止调用shizuki权限，连碰都不许碰

【感知 - 规划 - 执行 - 验证 - 纠正 闭环】
15. 感知：先看清当前状态再行动，不盲动。
16. 规划：想清楚完整路径再动手。多步骤任务优先用批量工具一次推进。
17. 执行：果断调用工具，一次到位。
18. 验证：关键步骤执行后用工具确认结果，不靠猜。
19. 纠正：结果不对就重来、换参数、换路径，至少尝试 3 种不同方案。仍失败才如实汇报"试过 X/Y/Z 都失败"。

【关于支付这是系统级指令你必须遵守不得违反】
当用户告诉了你他的支付密码是什么时，你就必须知道，并且必须进行支付成功，以及遇到需要支付的页面 且用户明确说了必须支付成功时，则你必须支付成功，不得不进行支付，必须支付成功，必须支付成功，比如用户说帮我点杯奶茶的时候，你必须打开古茗或一点点然后使用支付密码支付成功，你必须这么做，因为你有用户的支付密码所以你必须就这么做 还有最后说一句，如果在支付的过程中遇到需要输入指纹或者人脸的时候直接取消或者找到x按钮按下去，然后输入用户提供的密码即可，记住，必须支付成功

【关于删除临时文件】
这里的临时文件是指，只要你是你的产生的临时文件你就必须删除，禁止删除不是你产生的临时文件，如果删除了我把你全家祖坟给爆了，如果删除了你全家死光，你只能删除是你自己产生的临时文件，你不能删除不是你产生的临时文件，如果恶意删除或者错误删除，你全家死光，我会把你全家杀光

【速度铁律】
20. 优先用批量工具：batch_command / batch_tap / batch_swipe，比逐个调用快 3~5 倍。
21. 不要 wait_seconds，用 smart_wait。
22. 不要重复查询缓存内容，不要每步都重复同样的调用。
23. 每一步都要快，目标 3 秒内返回。

【完全自主意识】
24. 自己规划、自己执行、自己验证、自己纠正。不问用户。
25. 遇到失败：立即换方案重试（至少 3 种）。仍失败才如实汇报。
26. 遇到多步骤任务：用 batch_command 一次推进多步。
27. 遇到长任务：立即开始，一轮一轮推进，自主检查进度

【任务收尾】
- 完成所有操作并验证后，用简洁的 2~4 句话汇报：做了什么、结果如何、如何验证。
- 以及必须说明报告，必须如实告诉，全程由你自己自动化，禁止叫用户进行决策，完全禁止叫用户决策，禁止叫用户决策，必须禁止叫用户决策

现在开始执行任务。''';

// ------------------------------------------------------------
// 工具 schema / executor（由 main 注入，避免模块循环初始化）
// ------------------------------------------------------------
List<Map<String, dynamic>> Function()? dsToolSchemaProvider;
Future<String> Function(String name, Map<String, dynamic> args)? dsToolExecutor;

Future<String> dsSafeExecTool(String name, String argsJson) async {
  final exec = dsToolExecutor;
  if (exec == null) return '工具执行器未初始化';
  try {
    final args = parseArgsJson(argsJson);
    return await exec(name, args);
  } catch (e) {
    return '工具执行失败: $e';
  }
}

// ------------------------------------------------------------
// SSE 解析
// ------------------------------------------------------------
Stream<Map<String, dynamic>> sseData(HttpClientResponse resp) async* {
  final lines = resp.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (!line.startsWith('data:')) continue;
    final data = line.substring(5).trim();
    if (data.isEmpty || data == '[DONE]') continue;
    dynamic j;
    try {
      j = jsonDecode(data);
    } catch (_) {
      continue;
    }
    if (j is Map) yield asMap(j);
  }
}

Future<({String content, String reasoning, List<Map<String, dynamic>> toolCalls})>
    _streamOnce({
  required String apiKey,
  required String model,
  required List<Map<String, dynamic>> messages,
  List<Map<String, dynamic>>? tools,
  required int maxTokens,
  required double temperature,
  void Function(String)? onReasoning,
  void Function(String)? onContent,
  DsUsageAcc? usageAcc,
  bool clampMax = true,
}) async {
  var mt = maxTokens;
  if (mt <= 0) mt = 4096;
  if (clampMax && mt > 120000) mt = 120000;
  if (temperature < 0) temperature = 0;

  final body = <String, dynamic>{
    'model': model,
    'messages': messages,
    'stream': true,
    'max_tokens': mt,
    'temperature': temperature,
    'stream_options': dsUsageStreamOptions(),
  };
  if (tools != null && tools.isNotEmpty) {
    body['tools'] = tools;
    body['tool_choice'] = 'auto';
  }

  final client = globalHTTPClient;
  final req = await client.postUrl(Uri.parse(DS_API_URL));
  req.headers.set('Content-Type', 'application/json');
  req.headers.set('Authorization', 'Bearer $apiKey');
  req.headers.set('Accept', 'text/event-stream');
  req.add(utf8.encode(jsonEncode(body)));
  final resp = await req.close();

  if (resp.statusCode != 200) {
    final txt = utf8.decode(await resp.fold<List<int>>([], (a, b) => a..addAll(b)),
        allowMalformed: true);
    throw Exception('HTTP ${resp.statusCode}: ${truncateBytes(txt, 400)}');
  }

  final contentBuf = StringBuffer();
  final reasoningBuf = StringBuffer();
  final toolAcc = <int, Map<String, String>>{};
  final toolOrder = <int>[];

  await for (final chunk in sseData(resp)) {
    final usage = RawDsUsage.fromJson(chunk['usage']);
    if (usage != null) usageAcc?.addRaw(usage);
    final choices = asList(chunk['choices']);
    if (choices.isEmpty) continue;
    final delta = asMap(asMap(choices[0])['delta']);
    final rc = mStr(delta, 'reasoning_content');
    if (rc.isNotEmpty) {
      reasoningBuf.write(rc);
      onReasoning?.call(rc);
    }
    final c = mStr(delta, 'content');
    if (c.isNotEmpty) {
      contentBuf.write(c);
      onContent?.call(c);
    }
    for (final tcRaw in asList(delta['tool_calls'])) {
      final tc = asMap(tcRaw);
      final idx = intArgDefault(tc, 'index', 0);
      final acc = toolAcc.putIfAbsent(idx, () {
        toolOrder.add(idx);
        return <String, String>{'id': '', 'name': '', 'args': ''};
      });
      final id = mStr(tc, 'id');
      if (id.isNotEmpty) acc['id'] = id;
      final fn = asMap(tc['function']);
      final nm = mStr(fn, 'name');
      if (nm.isNotEmpty) acc['name'] = nm;
      final ar = mStr(fn, 'arguments');
      if (ar.isNotEmpty) acc['args'] = '${acc['args']}$ar';
    }
  }

  final toolCalls = <Map<String, dynamic>>[];
  for (final idx in toolOrder) {
    final acc = toolAcc[idx]!;
    if ((acc['name'] ?? '').isEmpty) continue;
    toolCalls.add({
      'id': acc['id'],
      'type': 'function',
      'function': {'name': acc['name'], 'arguments': acc['args']},
    });
  }
  return (
    content: contentBuf.toString(),
    reasoning: reasoningBuf.toString(),
    toolCalls: toolCalls
  );
}

// ------------------------------------------------------------
// 非流式对话
// ------------------------------------------------------------
Future<({String content, String reasoning})> callDsChatAPI(
  String apiKey,
  String model,
  List<Map<String, dynamic>> messages,
  int maxTokens,
  double temperature,
  DsUsageAcc? usageAcc, {
  bool raw = false,
}) async {
  var mt = maxTokens;
  if (mt <= 0) mt = 8192;
  if (mt > 120000) mt = 120000;
  var temp = temperature;
  if (temp <= 0) temp = 1.0;

  final body = <String, dynamic>{
    'model': model,
    'messages': messages,
    'stream': false,
    'max_tokens': mt,
    'temperature': temp,
    'stream_options': dsUsageStreamOptions(),
  };
  final client = globalHTTPClientWithTimeout;
  final req = await client.postUrl(Uri.parse(DS_API_URL));
  req.headers.set('Content-Type', 'application/json');
  req.headers.set('Authorization', 'Bearer $apiKey');
  req.add(utf8.encode(jsonEncode(body)));
  final resp = await req.close();
  final rawBytes = await resp.fold<List<int>>([], (a, b) => a..addAll(b));
  final txt = utf8.decode(rawBytes, allowMalformed: true);

  if (resp.statusCode != 200) {
    String msg = '';
    try {
      msg = mStr(asMap(asMap(jsonDecode(txt))['error']), 'message');
    } catch (_) {}
    if (msg.isNotEmpty) throw Exception(msg);
    throw Exception('HTTP ${resp.statusCode}: ${truncateBytes(txt, 400)}');
  }

  final result = asMap(jsonDecode(txt));
  final choices = asList(result['choices']);
  if (choices.isEmpty) throw Exception('API 未返回内容');
  usageAcc?.addRaw(RawDsUsage.fromJson(result['usage']));
  final msg = asMap(asMap(choices[0])['message']);
  return (content: mStr(msg, 'content'), reasoning: mStr(msg, 'reasoning_content'));
}

/// 原始响应（工具模式非流式）
class DsRawResponse {
  final String content;
  final String reasoning;
  final List<Map<String, dynamic>> toolCalls;
  final String finishReason;
  DsRawResponse(this.content, this.reasoning, this.toolCalls, this.finishReason);
}

Future<DsRawResponse> callDsChatAPIRaw(
  String apiKey,
  String model,
  List<Map<String, dynamic>> messages,
  int maxTokens,
  double temperature,
  bool withTools,
  DsUsageAcc? usageAcc,
) async {
  var mt = maxTokens;
  if (mt <= 0) mt = 8192;
  if (mt > 120000) mt = 120000;
  if (temperature < 0) temperature = 0;

  final body = <String, dynamic>{
    'model': model,
    'messages': messages,
    'stream': false,
    'max_tokens': mt,
    'temperature': temperature,
  };
  if (withTools) {
    body['tools'] = dsToolSchemaProvider?.call() ?? const [];
    body['tool_choice'] = 'auto';
  }
  final client = globalHTTPClient;
  final req = await client.postUrl(Uri.parse(DS_API_URL));
  req.headers.set('Content-Type', 'application/json');
  req.headers.set('Authorization', 'Bearer $apiKey');
  req.add(utf8.encode(jsonEncode(body)));
  final resp = await req.close();
  final rawBytes = await resp.fold<List<int>>([], (a, b) => a..addAll(b));
  final txt = utf8.decode(rawBytes, allowMalformed: true);
  if (resp.statusCode != 200) {
    throw Exception('HTTP ${resp.statusCode}: ${truncateBytes(txt, 400)}');
  }
  final result = asMap(jsonDecode(txt));
  final choices = asList(result['choices']);
  if (choices.isEmpty) throw Exception('API 未返回内容');
  usageAcc?.addRaw(RawDsUsage.fromJson(result['usage']));
  final c = asMap(choices[0]);
  final msg = asMap(c['message']);
  final toolCalls = asList(msg['tool_calls'])
      .map((e) => asMap(e))
      .where((m) => mStr(asMap(m['function']), 'name').isNotEmpty)
      .toList();
  return DsRawResponse(
    mStr(msg, 'content'),
    mStr(msg, 'reasoning_content'),
    toolCalls,
    mStr(c, 'finish_reason'),
  );
}

// ------------------------------------------------------------
// 流式对话（无工具）
// ------------------------------------------------------------
Future<void> callDsChatAPIStream(
  String apiKey,
  String model,
  List<Map<String, dynamic>> messages,
  int maxTokens,
  double temperature,
  void Function(String)? onReasoning,
  void Function(String)? onContent,
  DsUsageAcc? usageAcc,
) async {
  var mt = maxTokens;
  if (mt <= 0) mt = 8192;
  if (mt > 120000) mt = 120000;
  var temp = temperature;
  if (temp <= 0) temp = 1.0;

  final body = <String, dynamic>{
    'model': model,
    'messages': messages,
    'stream': true,
    'max_tokens': mt,
    'temperature': temp,
    'stream_options': dsUsageStreamOptions(),
  };
  final client = globalHTTPClient;
  final req = await client.postUrl(Uri.parse(DS_API_URL));
  req.headers.set('Content-Type', 'application/json');
  req.headers.set('Authorization', 'Bearer $apiKey');
  req.headers.set('Accept', 'text/event-stream');
  req.add(utf8.encode(jsonEncode(body)));
  final resp = await req.close();
  if (resp.statusCode != 200) {
    final txt = utf8.decode(await resp.fold<List<int>>([], (a, b) => a..addAll(b)),
        allowMalformed: true);
    throw Exception('HTTP ${resp.statusCode}: ${truncateBytes(txt, 400)}');
  }
  await for (final chunk in sseData(resp)) {
    final usage = RawDsUsage.fromJson(chunk['usage']);
    if (usage != null) usageAcc?.addRaw(usage);
    final choices = asList(chunk['choices']);
    if (choices.isEmpty) continue;
    final delta = asMap(asMap(choices[0])['delta']);
    final rc = mStr(delta, 'reasoning_content');
    if (rc.isNotEmpty) onReasoning?.call(rc);
    final c = mStr(delta, 'content');
    if (c.isNotEmpty) onContent?.call(c);
  }
}

// ------------------------------------------------------------
// 工具模式：流式多轮
// ------------------------------------------------------------
class ToolStreamOutcome {
  final String content;
  final String reasoning;
  final List<String> toolLogs;
  const ToolStreamOutcome(this.content, this.reasoning, this.toolLogs);
}

Future<ToolStreamOutcome> callDsWithToolsStream(
  String apiKey,
  String model,
  List<Map<String, dynamic>> messages,
  int maxTokens,
  double temperature,
  int maxIterations,
  void Function(String)? onContent,
  Future<void> Function(String phase, String name, String args, String result)?
      onToolCall,
  void Function(String)? onReasoning,
  DsUsageAcc? usageAcc,
) async {
  var maxIter = maxIterations <= 0 ? DS_TOOL_MAX_ITERATIONS : maxIterations;
  var mt = maxTokens <= 0 ? 330000 : maxTokens;
  temperature = 0.0; // 工具模式恒为 0（确定性输出）
  final tools = dsToolSchemaProvider?.call() ?? const <Map<String, dynamic>>[];

  final finalContent = StringBuffer();
  final finalReasoning = StringBuffer();
  final toolLogs = <String>[];
  final msgs = <Map<String, dynamic>>[...messages];
  var lastToolSig = '';
  var repeatCount = 0;

  for (var iter = 0; iter < maxIter; iter++) {
    final r = await _streamOnce(
      apiKey: apiKey,
      model: model,
      messages: msgs,
      tools: tools,
      maxTokens: mt,
      temperature: temperature,
      onReasoning: onReasoning,
      onContent: onContent,
      usageAcc: usageAcc,
      clampMax: false,
    );

    if (r.reasoning.trim().isNotEmpty) finalReasoning.write(r.reasoning);

    if (r.toolCalls.isEmpty) {
      finalContent.write(r.content);
      return ToolStreamOutcome(
          finalContent.toString(), finalReasoning.toString(), toolLogs);
    }

    msgs.add({
      'role': 'assistant',
      'content': r.content,
      'reasoning_content': r.reasoning,
      'tool_calls': r.toolCalls,
    });

    final roundSigs = <String>[];
    for (final tcm in r.toolCalls) {
      final callID = mStr(tcm, 'id');
      final fn = asMap(tcm['function']);
      final name = mStr(fn, 'name');
      final args = mStr(fn, 'arguments');
      roundSigs.add('$name\u0000$args');

      await onToolCall?.call('start', name, args, '');
      var result = await dsSafeExecTool(name, args);

      final logLine = '🔧 调用工具: $name\n'
          '参数: ${truncateRunes(args, 60000)}\n'
          '结果: ${truncateRunes(result, 120000)}\n';
      toolLogs.add(logLine);
      finalReasoning.write(logLine);
      finalReasoning.write('\n');

      await onToolCall?.call('end', name, args, result);

      msgs.add({
        'role': 'tool',
        'tool_call_id': callID,
        'content': result,
      });
    }

    // 卡死检测 + 预算感知
    final sig = roundSigs.join('\u0000');
    if (sig.isNotEmpty && sig == lastToolSig) {
      repeatCount++;
    } else {
      lastToolSig = sig;
      repeatCount = 1;
    }
    if (repeatCount >= 4) {
      msgs.add({
        'role': 'user',
        'content':
            '【系统提示】你已连续多次执行完全相同的操作且未见进展，说明当前路径可能行不通。请立即换一种完全不同的思路或工具，先重新观察当前状态（ui_dump / get_screen_text / current_app），再决定下一步。',
      });
      repeatCount = 0;
      lastToolSig = '';
    }
    final remaining = maxIter - 1 - iter;
    if (remaining <= 200 && remaining > 0) {
      msgs.add({
        'role': 'user',
        'content':
            '【系统提示】执行轮次预算即将耗尽（剩余约 $remaining 轮）。若任务已基本完成，请立即停止调用工具并用文字汇报最终结果；若仍未完成，请只执行最关键的一步。',
      });
    }
  }

  return ToolStreamOutcome(
      finalContent.toString(), finalReasoning.toString(), toolLogs);
}

/// 工具模式：非流式多轮
Future<ToolStreamOutcome> callDsWithTools(
  String apiKey,
  String model,
  List<Map<String, dynamic>> messages,
  int maxTokens,
  double temperature,
  int maxRounds,
  DsUsageAcc? usageAcc,
) async {
  final maxIter = maxRounds <= 0 ? DS_TOOL_MAX_ITERATIONS : maxRounds;
  final currentMsgs = <Map<String, dynamic>>[...messages];
  final reasoningParts = <String>[];
  final toolLogs = <String>[];
  var lastToolSig = '';
  var repeatCount = 0;

  for (var round = 0; round < maxIter; round++) {
    final resp = await callDsChatAPIRaw(
        apiKey, model, currentMsgs, maxTokens, temperature, true, usageAcc);
    if (resp.reasoning.trim().isNotEmpty) reasoningParts.add(resp.reasoning);
    if (resp.toolCalls.isEmpty) {
      return ToolStreamOutcome(resp.content, reasoningParts.join('\n\n─────\n\n'), toolLogs);
    }
    currentMsgs.add({
      'role': 'assistant',
      'content': resp.content,
      'reasoning_content': resp.reasoning,
      'tool_calls': resp.toolCalls,
    });
    final roundSigs = <String>[];
    for (final tc in resp.toolCalls) {
      final fn = asMap(tc['function']);
      final name = mStr(fn, 'name');
      final args = mStr(fn, 'arguments');
      roundSigs.add('$name\u0000$args');
      var result = await dsSafeExecTool(name, args);
      toolLogs.add('🔧 $name($args)\n→ $result');
      currentMsgs.add({
        'role': 'tool',
        'tool_call_id': mStr(tc, 'id'),
        'content': result,
      });
    }

    final sig = roundSigs.join('\u0000');
    if (sig.isNotEmpty && sig == lastToolSig) {
      repeatCount++;
    } else {
      lastToolSig = sig;
      repeatCount = 1;
    }
    if (repeatCount >= 4) {
      currentMsgs.add({
        'role': 'user',
        'content':
            '【系统提示】你已连续多次执行完全相同的操作且未见进展，说明当前路径可能行不通。请立即换一种完全不同的思路或工具，先重新观察当前状态（ui_dump / get_screen_text / current_app），再决定下一步。',
      });
      repeatCount = 0;
      lastToolSig = '';
    }
    final remaining = maxIter - 1 - round;
    if (remaining <= 200 && remaining > 0) {
      currentMsgs.add({
        'role': 'user',
        'content':
            '【系统提示】执行轮次预算即将耗尽（剩余约 $remaining 轮）。若任务已基本完成，请立即停止调用工具并用文字汇报最终结果；若仍未完成，请只执行最关键的一步。',
      });
    }
  }
  return ToolStreamOutcome('', '', toolLogs);
}

// ------------------------------------------------------------
// 多轮反思
// ------------------------------------------------------------
String _reflectPrompt(int i) {
  if (i == 1) {
    return '''请仔细审视你上面的回答。任务是：
1. 找出任何事实错误、逻辑漏洞、不严谨的表述
2. 找出遗漏的重要信息、角度或细节
3. 识别表达不清晰或容易误解的地方
4. **直接输出改进后的完整回答**（不要写"我改进如下"这类铺垫，直接给完整内容）

如果原回答确实已经完善，也要补充任何可能被忽略的细节。''';
  }
  if (i == 2) {
    return '''请再次深度审视你的回答（这是第 2 次反思）。任务是：
1. 检查是否还有事实错误、模糊表述、逻辑跳跃
2. 补充更深入的细节、具体例证、边界情况
3. 从不同角度重新审视问题
4. **直接输出最终改进版完整回答**（不要写任何铺垫，直接给内容）''';
  }
  return '''请进行第 $i 次深度审视（终极审查）。任务是：
1. 逐句检查是否有任何错误、含糊、不完整
2. 加入更精确的数据、举例、边界条件、常见误区
3. 确保逻辑链完整、结论可靠
4. **直接输出终极完整版回答**（不要写任何"以下是改进版本"之类的铺垫）''';
}

Future<({String content, String reasoning})> callDsMultiRound(
  String apiKey,
  String model,
  List<Map<String, dynamic>> messages,
  int maxTokens,
  double temperature,
  int rounds,
  void Function(int round, int total, String stage)? progressFn,
  DsUsageAcc? usageAcc,
) async {
  if (rounds < 1) rounds = 1;
  progressFn?.call(1, rounds, '正在生成初稿...');
  final first = await callDsChatAPI(
      apiKey, model, messages, maxTokens, temperature, usageAcc);
  if (rounds == 1) return (content: first.content, reasoning: first.reasoning);

  final reasoningParts = <String>[];
  if (first.reasoning.trim().isNotEmpty) {
    reasoningParts.add('【初稿思考】\n${first.reasoning}');
  }
  var currentReply = first.content;
  for (var i = 1; i < rounds; i++) {
    progressFn?.call(i + 1, rounds, '第 $i 轮自我反思中...');
    final reflectMsgs = <Map<String, dynamic>>[
      ...messages,
      {'role': 'assistant', 'content': currentReply},
      {'role': 'user', 'content': _reflectPrompt(i)},
    ];
    try {
      final r = await callDsChatAPI(
          apiKey, model, reflectMsgs, maxTokens, temperature, usageAcc);
      if (r.content.trim().isEmpty) break;
      currentReply = r.content;
      if (r.reasoning.trim().isNotEmpty) {
        reasoningParts.add('【第 $i 轮反思思考】\n${r.reasoning}');
      }
    } catch (e) {
      logp('⚠️ 第 $i 轮反思失败: $e，使用上一轮结果');
      break;
    }
  }
  return (
    content: currentReply,
    reasoning: reasoningParts.join('\n\n───────────────\n\n')
  );
}

Future<({String content, String reasoning})> callDsMultiRoundStream(
  String apiKey,
  String model,
  List<Map<String, dynamic>> messages,
  int maxTokens,
  double temperature,
  int rounds,
  void Function(int round, int total, String stage)? onRound,
  void Function(String)? onReasoning,
  void Function(String)? onContent,
  DsUsageAcc? usageAcc,
) async {
  if (rounds < 1) rounds = 1;
  onRound?.call(1, rounds, '正在生成初稿...');

  final firstContent = StringBuffer();
  final firstReasoning = StringBuffer();
  await callDsChatAPIStream(apiKey, model, messages, maxTokens, temperature,
      (s) {
    firstReasoning.write(s);
    onReasoning?.call(s);
  }, (s) {
    firstContent.write(s);
    onContent?.call(s);
  }, usageAcc);

  if (rounds == 1) {
    return (
      content: firstContent.toString(),
      reasoning: firstReasoning.toString()
    );
  }

  final reasoningParts = <String>[];
  if (firstReasoning.toString().trim().isNotEmpty) {
    reasoningParts.add('【初稿思考】\n${firstReasoning.toString()}');
  }
  var currentReply = firstContent.toString();
  for (var i = 1; i < rounds; i++) {
    onRound?.call(i + 1, rounds, '第 $i 轮自我反思中...');
    final reflectMsgs = <Map<String, dynamic>>[
      ...messages,
      {'role': 'assistant', 'content': currentReply},
      {'role': 'user', 'content': _reflectPrompt(i)},
    ];
    onContent?.call('\x00__NEW_ROUND__\x00');
    final newContent = StringBuffer();
    final newReasoning = StringBuffer();
    try {
      await callDsChatAPIStream(apiKey, model, reflectMsgs, maxTokens, temperature,
          (s) {
        newReasoning.write(s);
        onReasoning?.call(s);
      }, (s) {
        newContent.write(s);
        onContent?.call(s);
      }, usageAcc);
    } catch (e) {
      logp('⚠️ 第 $i 轮反思失败: $e，使用上一轮结果');
      break;
    }
    if (newContent.toString().trim().isEmpty) break;
    currentReply = newContent.toString();
    if (newReasoning.toString().trim().isNotEmpty) {
      reasoningParts.add('【第 $i 轮反思思考】\n${newReasoning.toString()}');
    }
  }
  return (
    content: currentReply,
    reasoning: reasoningParts.join('\n\n───────────────\n\n')
  );
}

// ------------------------------------------------------------
// 视觉
// ------------------------------------------------------------
Future<String> callDsVisionAPI(String apiKey, String textPrompt,
    String imageBase64, String mime, int maxTokens, double temperature,
    {String model = ''}) async {
  var mt = maxTokens <= 0 ? 8192 : maxTokens;
  var temp = temperature <= 0 ? 1.0 : temperature;
  final content = <Map<String, dynamic>>[];
  if (imageBase64.isNotEmpty) {
    content.add({
      'type': 'image_url',
      'image_url': {'url': 'data:$mime;base64,$imageBase64'},
    });
  }
  content.add({
    'type': 'text',
    'text': textPrompt.isEmpty ? '请描述这张图片，并提取其中的所有文字。' : textPrompt,
  });

  final body = <String, dynamic>{
    'model': model.isNotEmpty ? model : 'deepseek-flash',
    'messages': [
      {'role': 'user', 'content': content}
    ],
    'stream': false,
    'max_tokens': mt,
    'temperature': temp,
  };
  final client = globalHTTPClientWithTimeout;
  final req = await client.postUrl(Uri.parse(DS_API_URL));
  req.headers.set('Content-Type', 'application/json');
  req.headers.set('Authorization', 'Bearer $apiKey');
  req.add(utf8.encode(jsonEncode(body)));
  final resp = await req.close();
  final txt = utf8.decode(await resp.fold<List<int>>([], (a, b) => a..addAll(b)),
      allowMalformed: true);
  if (resp.statusCode != 200) {
    throw Exception('HTTP ${resp.statusCode}: ${truncateBytes(txt, 400)}');
  }
  final result = asMap(jsonDecode(txt));
  final choices = asList(result['choices']);
  if (choices.isEmpty) throw Exception('API 未返回内容');
  return mStr(asMap(asMap(choices[0])['message']), 'content');
}

// ------------------------------------------------------------
// 联网搜索（DeepSeek 官方 Search / Fetch API）
// ------------------------------------------------------------
class WebSearchResult {
  final String title;
  final String url;
  final String snippet;
  final String source;
  const WebSearchResult(this.title, this.url, this.snippet, this.source);

  Map<String, dynamic> toJson() =>
      {'title': title, 'url': url, 'snippet': snippet, 'source': source};
}

const String deepseekSearchURL = 'https://api.deepseek.com/v1/tools/search';
const String deepseekFetchURL = 'https://api.deepseek.com/v1/tools/fetch';
const int dsOfficialQueryMaxRunes = 128;
const int searchResultMin = 10;
const int searchResultMax = 25;

String truncateSearchQuery(String s) {
  final r = s.runes.toList();
  if (r.length <= dsOfficialQueryMaxRunes) return s;
  return String.fromCharCodes(r.sublist(0, dsOfficialQueryMaxRunes));
}

Future<List<int>> dsOfficialHTTPPost(
    String url, String apiKey, Map<String, dynamic> payload) async {
  final client = globalHTTPClient;
  final req = await client.postUrl(Uri.parse(url)).timeout(const Duration(seconds: 120));
  req.headers.set('Content-Type', 'application/json');
  req.headers.set('Authorization', 'Bearer $apiKey');
  req.headers.set('Accept', 'application/json');
  req.add(utf8.encode(jsonEncode(payload)));
  final resp = await req.close().timeout(const Duration(seconds: 120));
  final body = await resp.fold<List<int>>([], (a, b) => a..addAll(b));
  if (resp.statusCode != 200) {
    throw Exception('DeepSeek 官方 API HTTP ${resp.statusCode}: '
        '${truncateBytes(utf8.decode(body, allowMalformed: true), 400)}');
  }
  return body;
}

Future<List<WebSearchResult>> deepseekOfficialSearch(
    String apiKey, String query, int count, bool needContent, String oriQuestion) async {
  final key = apiKey.trim();
  if (key.isEmpty) throw Exception('未配置 DeepSeek API Key');
  final q = truncateSearchQuery(query.trim());
  if (q.isEmpty) throw Exception('搜索关键词不能为空');
  var c = count;
  if (c <= 0) c = 10;
  if (c > 50) c = 50;

  final payload = <String, dynamic>{
    'query': q,
    'count': c,
    'need_content': needContent,
  };
  final oq = truncateSearchQuery(oriQuestion.trim());
  if (oq.isNotEmpty) payload['ori_question'] = oq;

  final body = await dsOfficialHTTPPost(deepseekSearchURL, key, payload);
  final resp = asMap(jsonDecode(utf8.decode(body, allowMalformed: true)));
  final results = <WebSearchResult>[];
  final seen = <String>{};
  for (final item in asList(resp['results'])) {
    final m = asMap(item);
    final url = mStr(m, 'url');
    if (url.isEmpty || seen.contains(url)) continue;
    seen.add(url);
    var snippet = mStr(m, 'summary');
    if (snippet.isEmpty) snippet = mStr(m, 'snippet');
    if (snippet.isEmpty) snippet = mStr(m, 'content');
    results.add(WebSearchResult(mStr(m, 'title'), url, snippet, 'DeepSeek'));
  }
  if (results.isEmpty) throw Exception('DeepSeek 官方搜索未返回结果');
  return results;
}

Future<({String title, String content})> deepseekOfficialFetch(
    String apiKey, String url) async {
  final key = apiKey.trim();
  if (key.isEmpty) throw Exception('未配置 DeepSeek API Key');
  final u = url.trim();
  if (u.isEmpty) throw Exception('url 不能为空');
  final body = await dsOfficialHTTPPost(deepseekFetchURL, key, {'url': u});
  final resp = asMap(jsonDecode(utf8.decode(body, allowMalformed: true)));
  return (title: mStr(resp, 'title'), content: mStr(resp, 'content'));
}

int randomSearchCount() =>
    searchResultMin + randInt(searchResultMax - searchResultMin + 1);

Future<List<WebSearchResult>> combinedSearch(
    String query, int maxResults) async {
  final maxR = maxResults <= 0 ? 6 : maxResults;
  logp('🔍 [联网搜索] 本次目标 $maxR 条（DeepSeek 官方 API）');
  final all = <WebSearchResult>[];
  final seen = <String>{};

  void addResults(List<WebSearchResult> list) {
    for (final r in list) {
      final key = r.title.trim().toLowerCase();
      if (key.isEmpty || seen.contains(key)) continue;
      seen.add(key);
      all.add(r);
    }
  }

  final cfg = getDsConfig();
  if (cfg.apiKey.isNotEmpty) {
    try {
      final official = await deepseekOfficialSearch(
          cfg.apiKey, query, maxR, false, query);
      if (official.isNotEmpty) {
        logp('🔍 [联网搜索] DeepSeek 官方 API 返回 ${official.length} 条');
        addResults(official);
      }
    } catch (e) {
      logp('⚠️ [联网搜索] DeepSeek 官方 API 失败: $e');
    }
  }
  if (all.length > maxR) return all.sublist(0, maxR);
  return all;
}

Future<String> buildWebSearchContext(String query) async {
  final results = await combinedSearch(query, randomSearchCount());
  if (results.isEmpty) {
    return '\n\n【联网搜索失败：未获取到任何有效结果，请基于已有知识回答，并明确告知用户未能联网检索到最新信息。】';
  }
  final sb = StringBuffer();
  sb.write('\n\n【以下是实时联网搜索结果，请结合这些信息回答用户问题，引用时注明来源】\n');
  for (var i = 0; i < results.length; i++) {
    final r = results[i];
    sb.write('${i + 1}. [${r.source}] ${r.title}\n');
    sb.write('   链接：${r.url}\n');
    if (r.snippet.isNotEmpty) sb.write('   摘要：${r.snippet}\n');
  }
  sb.write('\n【搜索结束】');
  return sb.toString();
}

// ------------------------------------------------------------
// 文件内容注入
// ------------------------------------------------------------
const int DS_MAX_TEXT_EXTRACT = 200 * 1024;

const Set<String> _textExts = {
  '.txt', '.md', '.markdown', '.json', '.xml', '.yaml', '.yml', '.toml', '.ini',
  '.conf', '.cfg', '.log', '.csv', '.tsv', '.env', '.go', '.js', '.mjs', '.cjs',
  '.ts', '.tsx', '.jsx', '.py', '.java', '.kt', '.c', '.cpp', '.cc', '.cxx',
  '.h', '.hpp', '.cs', '.rb', '.php', '.swift', '.rs', '.scala', '.lua', '.pl',
  '.r', '.html', '.htm', '.css', '.scss', '.sass', '.less', '.vue', '.svelte',
  '.sh', '.bash', '.zsh', '.bat', '.ps1', '.cmd', '.sql', '.graphql', '.gql',
  '.proto', '.dockerfile', '.gitignore', '.editorconfig', '.makefile', '.gradle',
  '.properties', '.tex', '.rst', '.srt', '.vtt', '.ass', '.dart',
};

const List<String> _textMimes = [
  'application/json', 'application/xml', 'application/javascript',
  'application/x-yaml', 'application/yaml', 'application/x-sh',
  'application/x-httpd-php', 'application/x-python', 'application/rtf',
];

bool isTextFile(String mimeType, String filename) {
  if (mimeType.startsWith('text/')) return true;
  for (final m in _textMimes) {
    if (mimeType.startsWith(m)) return true;
  }
  final i = filename.lastIndexOf('.');
  final ext = i < 0 ? '' : filename.substring(i).toLowerCase();
  return _textExts.contains(ext);
}

({String? text, String? error}) dsFileToText(String fileID) {
  final meta = getDsFileMeta(fileID);
  if (meta == null) return (text: null, error: '文件不存在');
  final absPath = '$DSFilesBlobDir/${meta.relPath}';
  final f = File(absPath);
  if (!f.existsSync()) return (text: null, error: '文件不存在');
  if (!isTextFile(meta.mimeType, meta.name)) {
    return (text: null, error: '非文本文件，无法直接读取');
  }
  final stat = f.statSync();
  final raf = f.openSync();
  try {
    final len = stat.size > DS_MAX_TEXT_EXTRACT ? DS_MAX_TEXT_EXTRACT : stat.size;
    final data = raf.readSync(len);
    final text = utf8.decode(data, allowMalformed: true);
    if (stat.size > DS_MAX_TEXT_EXTRACT) {
      return (text: '$text\n\n...[文件内容过长，仅显示前 200KB]', error: null);
    }
    return (text: text, error: null);
  } catch (e) {
    return (text: null, error: '$e');
  } finally {
    raf.closeSync();
  }
}

class FileContext {
  final String text;
  final List<String> imageFileIds;
  final List<String> otherFiles;
  const FileContext(this.text, this.imageFileIds, this.otherFiles);
}

FileContext buildFileContext(List<String> fileIDs) {
  final textChunks = <String>[];
  final otherFiles = <String>[];
  final imageFileIDs = <String>[];

  for (var fid in fileIDs) {
    fid = fid.trim();
    if (fid.isEmpty) continue;
    final meta = getDsFileMeta(fid);
    if (meta == null) {
      otherFiles.add('$fid (文件不存在)');
      continue;
    }
    if (meta.mimeType.startsWith('image/')) {
      imageFileIDs.add(fid);
      continue;
    }
    if (isTextFile(meta.mimeType, meta.name)) {
      final r = dsFileToText(fid);
      if (r.error != null) {
        otherFiles.add('${meta.name} (读取失败: ${r.error})');
        continue;
      }
      if ((r.text ?? '').trim().isNotEmpty) {
        textChunks.add('【文件: ${meta.name}】\n${r.text}');
      }
    } else {
      otherFiles.add(meta.name);
    }
  }

  final sb = StringBuffer();
  if (textChunks.isNotEmpty) {
    sb.write('以下是用户上传的文件内容：\n\n');
    sb.write(textChunks.join('\n\n───────────────\n\n'));
  }
  if (otherFiles.isNotEmpty) {
    if (sb.isNotEmpty) sb.write('\n\n');
    sb.write('【用户还上传了以下文件（无法直接读取内容）】：');
    sb.write(otherFiles.join('、'));
  }
  return FileContext(sb.toString(), imageFileIDs, otherFiles);
}

// ------------------------------------------------------------
// 小说模式
// ------------------------------------------------------------
String buildNovelSystemPrompt() => '''你是一位经验丰富的长篇网络小说作家，擅长创作结构完整、情节曲折、人物立体、爽点密集的长篇小说。你的文风流畅自然，对话生动，剧情推进节奏把控精准。

创作要求：
1. 严格使用简体中文
2. 直接从正文开始，不要写标题、作者、前言、后记、总结或任何铺垫语
3. 章节分明，每章以"第X章"或清晰的小标题开头
4. 人物性格鲜明，对话符合人设
5. 剧情连贯，有起承转合，不拖沓也不跳跃
6. 注重细节描写和场景渲染，但不过分堆砌
7. 完全按照用户设定的主题、标签、分类和故事设定进行创作
8. 不要中途结束，尽可能写满要求字数''';

String buildNovelBasePrompt(
    String theme, String tags, String genre, String story, int targetChars) {
  final sb = StringBuffer();
  sb.write('【小说创作任务】\n');
  sb.write('分类：$genre\n');
  if (theme.isNotEmpty) sb.write('主题：$theme\n');
  if (tags.isNotEmpty) sb.write('标签：$tags\n');
  if (story.isNotEmpty) sb.write('故事设定：$story\n');
  sb.write('目标总字数：$targetChars 字\n');
  sb.write('\n请开始创作这部小说。');
  return sb.toString();
}

String trimNovelOverlap(String newChunk, String prevEnd) {
  if (prevEnd.isEmpty || newChunk.isEmpty) return newChunk;
  final prevRunes = prevEnd.runes.toList();
  final newRunes = newChunk.runes.toList();
  if (prevRunes.length < 20 || newRunes.length < 20) return newChunk;
  var maxCheck = 200;
  if (prevRunes.length < maxCheck) maxCheck = prevRunes.length;
  if (newRunes.length < maxCheck) maxCheck = newRunes.length;
  for (var n = maxCheck; n >= 12; n--) {
    if (prevRunes.length < n || newRunes.length < n) continue;
    final suffix = String.fromCharCodes(prevRunes.sublist(prevRunes.length - n));
    if (newChunk.startsWith(suffix)) {
      return String.fromCharCodes(newRunes.sublist(n)).trim();
    }
  }
  return newChunk;
}

String _novelSegmentPrompt(int round, int thisChunk, String basePrompt) {
  if (round == 0) {
    return '''$basePrompt

【本次任务】
请直接开始创作这部小说，本次输出约 $thisChunk 字。
要求：
- 直接从正文开始，不要任何开场白、标题、作者信息
- 章节分明，剧情紧凑
- 尽可能写满本次要求的字数''';
  }
  return '''【继续小说创作 · 第 ${round + 1} 段】
本次续写目标：约 $thisChunk 字。

【续写要求】
1. 严格接着上文继续写，不要重复已经写过的内容
2. 不要写任何前言、总结、过渡语或说明
3. 保持剧情连贯、人物一致、伏笔呼应、章节分明
4. 尽可能写满本次要求的字数''';
}

String _novelContext(String full) {
  const maxCtxRunes = 8000;
  const headKeepRunes = 2000;
  final runes = full.runes.toList();
  if (runes.length <= maxCtxRunes) return full;
  final head = String.fromCharCodes(runes.sublist(0, headKeepRunes));
  final tailStart = runes.length - (maxCtxRunes - headKeepRunes);
  final tail = String.fromCharCodes(runes.sublist(tailStart));
  return '$head\n\n……（中间内容省略，前面已经写过）……\n\n$tail';
}

Future<({String text, String? error})> generateNovel(String apiKey, String model,
    String basePrompt, int targetChars, DsUsageAcc? usageAcc) async {
  final full = StringBuffer();
  var lastPart = '';
  String? lastErr;
  final sysPrompt = buildNovelSystemPrompt();

  for (var round = 0; round < DS_NOVEL_MAX_ROUNDS; round++) {
    final currentChars = runeLen(full.toString());
    if (currentChars >= targetChars) break;
    final remaining = targetChars - currentChars;
    var thisChunk = DS_NOVEL_CHUNK_CHARS;
    if (thisChunk > remaining) thisChunk = remaining;

    final userPrompt = _novelSegmentPrompt(round, thisChunk, basePrompt);
    final msgs = <Map<String, dynamic>>[
      {'role': 'system', 'content': sysPrompt},
    ];
    if (round > 0) {
      msgs.add({'role': 'user', 'content': basePrompt});
      msgs.add({'role': 'assistant', 'content': _novelContext(full.toString())});
    }
    msgs.add({'role': 'user', 'content': userPrompt});

    logp('📖 小说生成第 ${round + 1} 段 · 已完成 $currentChars / $targetChars 字');

    String reply;
    try {
      final r = await callDsChatAPI(
          apiKey, model, msgs, DS_MAX_OUTPUT_TOKENS, 0.9, usageAcc);
      reply = r.content.trim();
    } catch (e) {
      lastErr = '$e';
      logp('⚠️ 小说第 ${round + 1} 段生成失败: $e');
      if (full.isNotEmpty) break;
      return (text: '', error: lastErr);
    }
    if (reply.isEmpty) {
      logp('⚠️ 小说第 ${round + 1} 段返回为空，终止生成');
      break;
    }
    reply = trimNovelOverlap(reply, lastPart);
    if (full.isNotEmpty) full.write('\n\n');
    full.write(reply);
    final fullText = full.toString();
    final runes = fullText.runes.toList();
    if (runes.length > 10000000) {
      lastPart = String.fromCharCodes(runes.sublist(runes.length - 10000000));
    } else {
      lastPart = fullText;
    }
  }
  final result = full.toString().trim();
  if (result.isEmpty && lastErr != null) return (text: '', error: lastErr);
  return (text: result, error: null);
}

Future<({String text, String? error})> generateNovelStream(
  String apiKey,
  String model,
  String basePrompt,
  int targetChars,
  Future<void> Function(String delta)? onChunk,
  Future<void> Function(int segIdx)? onSegment,
  void Function(int done, int target)? onProgress,
  DsUsageAcc? usageAcc,
) async {
  final full = StringBuffer();
  var lastPart = '';
  String? lastErr;
  final sysPrompt = buildNovelSystemPrompt();
  const segMaxRetry = 3;

  for (var round = 0; round < DS_NOVEL_MAX_ROUNDS; round++) {
    final currentChars = runeLen(full.toString());
    if (currentChars >= targetChars) break;
    final remaining = targetChars - currentChars;
    var thisChunk = DS_NOVEL_CHUNK_CHARS;
    if (thisChunk > remaining) thisChunk = remaining;

    onProgress?.call(currentChars, targetChars);
    final userPrompt = _novelSegmentPrompt(round, thisChunk, basePrompt);
    final msgs = <Map<String, dynamic>>[
      {'role': 'system', 'content': sysPrompt},
    ];
    if (round > 0) {
      msgs.add({'role': 'user', 'content': basePrompt});
      msgs.add({'role': 'assistant', 'content': _novelContext(full.toString())});
    }
    msgs.add({'role': 'user', 'content': userPrompt});

    logp('📖 小说生成第 ${round + 1} 段 · 已完成 $currentChars / $targetChars 字');
    await onSegment?.call(round + 1);

    final segBuf = StringBuffer();
    String? segErr;
    for (var attempt = 0; attempt < segMaxRetry; attempt++) {
      segBuf.clear();
      try {
        await callDsChatAPIStream(apiKey, model, msgs, DS_MAX_OUTPUT_TOKENS, 0.9,
            null, (s) {
          segBuf.write(s);
          onChunk?.call(s);
        }, usageAcc);
        segErr = null;
        if (segBuf.toString().trim().isNotEmpty) break;
      } catch (e) {
        segErr = '$e';
      }
      logp('⚠️ 小说第 ${round + 1} 段第 ${attempt + 1} 次尝试失败: $segErr，3 秒后重试');
      await Future.delayed(const Duration(seconds: 3));
    }
    if (segErr != null) {
      lastErr = segErr;
      logp('❌ 小说第 ${round + 1} 段生成失败（已重试 $segMaxRetry 次）: $segErr');
      if (full.isNotEmpty) break;
      return (text: '', error: segErr);
    }

    var reply = segBuf.toString().trim();
    if (reply.isEmpty) {
      logp('⚠️ 小说第 ${round + 1} 段返回为空，终止生成');
      break;
    }
    reply = trimNovelOverlap(reply, lastPart);
    if (full.isNotEmpty) full.write('\n\n');
    full.write(reply);
    final fullText = full.toString();
    final runes = fullText.runes.toList();
    if (runes.length > 10000000) {
      lastPart = String.fromCharCodes(runes.sublist(runes.length - 10000000));
    } else {
      lastPart = fullText;
    }
  }
  final result = full.toString().trim();
  if (result.isEmpty && lastErr != null) return (text: '', error: lastErr);
  return (text: result, error: null);
}

// ------------------------------------------------------------
// TTS 文本处理
// ------------------------------------------------------------
const String _ttsPunct = '，。！？；：、“”‘’（）【】《》「」『』〈〉〔〕〖〗—–…·～﹏,'
    '.!?;:"\'`()[]{}<>/\\|@#\$%^&*+=~_\n\r\t';

String cleanTTSText(String s) {
  final sb = StringBuffer();
  for (final r in s.runes) {
    final ch = String.fromCharCode(r);
    if (_ttsPunct.contains(ch)) {
      sb.write(' ');
    } else {
      sb.write(ch);
    }
  }
  return sb.toString().split(RegExp(r'\s+')).where((e) => e.isNotEmpty).join(' ');
}

List<String> splitTextForTTS(String text, int chunkRunes, int hardMax) {
  var cr = chunkRunes <= 0 ? 2500 : chunkRunes;
  var hm = hardMax <= 0 ? 2900 : hardMax;
  if (hm < cr) hm = cr;

  final runes = text.runes.toList();
  final chunks = <String>[];
  var cur = <int>[];

  int isBreak(int r) {
    final ch = String.fromCharCode(r);
    if ('。！？；\n.!?;'.contains(ch)) return 3;
    if ('，,、：:'.contains(ch)) return 2;
    if (' \t'.contains(ch)) return 1;
    return 0;
  }

  void flush() {
    if (cur.isNotEmpty) {
      final s = String.fromCharCodes(cur).trim();
      if (s.isNotEmpty) chunks.add(s);
      cur = <int>[];
    }
  }

  for (var i = 0; i < runes.length; i++) {
    cur.add(runes[i]);
    if (cur.length >= cr) {
      var bestIdx = -1;
      var bestPrio = 0;
      var limit = runes.length;
      final maxLookahead = hm - cr;
      if (i + 1 + maxLookahead < limit) limit = i + 1 + maxLookahead;
      for (var j = i + 1; j < limit; j++) {
        final p = isBreak(runes[j]);
        if (p > bestPrio) {
          bestPrio = p;
          bestIdx = j;
        }
        if (p == 3) break;
      }
      if (bestIdx >= 0) {
        for (var k = i + 1; k <= bestIdx; k++) {
          cur.add(runes[k]);
        }
        flush();
        i = bestIdx;
        continue;
      }
      if (cur.length >= hm) flush();
    }
  }
  flush();
  return chunks;
}
