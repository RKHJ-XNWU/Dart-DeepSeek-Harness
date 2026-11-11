// ============================================================
// chat_send.dart —— /api/ds-chat/send（发送）、SSE 流式、小说模式
// 100% 对齐 Go 版 handleDsChatSend / handleDsChatSendStream /
//        handleDsNovelGeneration(Stream)
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cosplay.dart';
import 'deepseek_api.dart';
import 'doubao.dart';
import 'doubao_video_ark.dart';
import 'doubao_wiki.dart';
import 'doubao_intent.dart';
import 'doubao_thinking.dart';
import 'doubao_tools.dart';
import 'ds_crypto.dart';
import 'ds_usage.dart';
import 'files.dart';
import 'globals.dart';
import 'httpsrv.dart';
import 'model_router.dart';
import 'sessions.dart';
import 'session_ref.dart';
import 'tool_gate.dart';

// ------------------------------------------------------------
// 工具模式系统提示 / 轮次上限：按通道分流
//   · 豆包通道 → doubao_tools.dart 的专属提示词与档位轮次
//   · DeepSeek 通道 → 原有全量提示词与 DS_TOOL_MAX_ITERATIONS
//   专项适配的好处：lite 档不会被灌进 85 条工具约定的长提示，
//   首包更快；pro/evolving 档则拿到「可长程编排」的更强约束。
// ------------------------------------------------------------
/// 本次请求真正生效的插件信源。
///
/// 【为什么不能再直接调 dbResolveSources】
///   doubao_intent.dart 已被停用，dbResolveSources 恒返回 configSources，
///   导致「按钮强制调用某插件」的意图被丢弃。这里把显式强制源放最前，
///   再与配置源去重合并；没有强制源时行为与旧实现完全一致。
List<String> dbEffectiveSources(List<String> forcedSources) {
  final cfg = dbWikiEffectiveSources();
  if (forcedSources.isEmpty) return cfg;
  final forced = dbWikiNormalizeSources(forcedSources);
  if (forced.isEmpty) return cfg;
  final out = <String>[...forced];
  for (final s in cfg) {
    if (!out.contains(s)) out.add(s);
  }
  return out;
}

String dbToolSystemPromptFor(String model, String apiUrl, String lang) {
  if (apiUrl != DS_API_URL) {
    final p = dbToolAgentPrompt(model, lang);
    if (p.trim().isNotEmpty) return p;
  }
  return dsToolAgentPrompt(lang, DS_TOOL_AGENT_SYSTEM_PROMPT);
}

int dbToolMaxIterFor(String model, String apiUrl, int rounds) {
  var maxIter = apiUrl != DS_API_URL ? dbToolMaxRounds(model) : DS_TOOL_MAX_ITERATIONS;
  if (maxIter <= 0) maxIter = DS_TOOL_MAX_ITERATIONS;
  if (rounds > maxIter) maxIter = rounds;
  return maxIter;
}

// ------------------------------------------------------------
// SSE：流式发送
// ------------------------------------------------------------
Future<void> handleDsChatSendStream(
  HttpRequest req,
  String apiKey,
  String model,
  List<Map<String, dynamic>> apiMessages,
  int maxTokens,
  double temperature,
  int rounds,
  String sessionID,
  String content,
  List<String> fileIDs,
  bool enableTools, {
  /// 用户是否在 UI 上开启了「联网搜索」。
  /// 抖音百科（方舟联网内容插件）只在确实要联网时才启用：
  /// 否则每一句普通聊天都会先跑一轮检索，首包被拖到数秒之后，
  /// 表现就是「豆包模式不是流式、非常慢」。
  bool webSearch = false,
  ModelRouteDecision? route,
  String apiUrl = DS_API_URL,
  /// UI 言語（拒否禁令の選択に使用）
  String lang = '',
  /// 方舟专用附加字段（如 thinking）。DeepSeek 通道保持为 null。
  Map<String, dynamic>? extraBody,

  /// 待与媒体片段一起提交的 user 文本（含视频时才使用）
  String userPrompt = '',

  /// 已就绪的媒体片段（图片 / 音频）
  List<Map<String, dynamic>> mediaParts = const <Map<String, dynamic>>[],

  /// 尚未准备的大视频 id（在 SSE 建连后走 Files API 上传）
  List<String> pendingVideoIds = const <String>[],

  /// 前缀强制信源（doubao_intent.dart）。
  /// 非空时无视「抖音百科总闸」与「信源开关」的当前状态：
  /// 用户在有消息里写了「抖音百科：/百科：/墨迹天气：/天气：」，
  /// 就必须真的去检索，不允许因为开关关着而静默跳过。
  List<String> forcedSources = const <String>[],
}) async {
  final sse = Sse(req.response);

  // ★ 豆包思考链泵（见 doubao_thinking.dart）
  //   summary 型模型的 reasoning 是「大块突发 + 长空档」，
  //   这里在服务端就重排成一字级 micro-delta，前端每帧都有新字进来。
  //   DeepSeek 通道 isArk=false，pump 退化为直通，行为零变化。
  final reasoningPump = DbReasoningPump(
    model: model,
    isArkChannel: apiUrl != DS_API_URL,
    emit: (String d) {
      sse.send('reasoning', {'delta': d});
    },
  );

  // ---------- 大视频：SSE 已建连，后续上传期间由心跳保活 ----------
  if (pendingVideoIds.isNotEmpty) {
    try {
      await sse.send('media_progress', {
        'stage': 'begin',
        'count': pendingVideoIds.length,
      });
      final vid = await dbVideoContentForChat(
        videoFileIds: pendingVideoIds,
        model: model,
        apiKey: apiKey,
        onProgress: (info) {
          sse.send('media_progress', info);
        },
      );
      final promptOut =
          vid.text.isEmpty ? userPrompt : '$userPrompt\n\n${vid.text}';
      apiMessages.add({
        'role': 'user',
        'content': <Map<String, dynamic>>[
          {'type': 'text', 'text': promptOut},
          ...mediaParts,
          ...vid.parts,
        ],
      });
      await sse.send('media_progress', {
        'stage': 'ready',
        'parts': vid.parts.length,
        'segments': vid.text.isEmpty ? 0 : 1,
      });
    } on DbVideoArkException catch (e) {
      logp('❌ 動画の準備に失敗（ストリーミング）: ${e.message}');
      await sse.send('error', {'message': e.message});
      await sse.done();
      return;
    } catch (e) {
      logp('❌ 動画の準備に失敗（ストリーミング・想定外）: $e');
      await sse.send('error', {'message': '视频准备失败：$e'});
      await sse.done();
      return;
    }
  }

  final contentBuf = StringBuffer();
  final reasoningBuf = StringBuffer();
  final usageAcc = DsUsageAcc();
  final streamStart = DateTime.now();
  DateTime? firstContentAt;

  // ---------- 工具模式 ----------
  if (enableTools) {
    // 工具模式 × 联网内容插件：方舟客服确认 Responses API 的 tools
    // 数组可同时放置 web_search 与 function，由模型自动选择调用，故不再互斥。
    // 仅在豆包通道 + 已开信源 + 无音视频时混用，其余退回原有工具链。
    final toolWikiSources = (apiUrl != DS_API_URL &&
            (webSearch || forcedSources.isNotEmpty))
        ? dbEffectiveSources(forcedSources)
        : const <String>[];
    final useWikiTools = toolWikiSources.isNotEmpty &&
        pendingVideoIds.isEmpty &&
        dbWikiMediaSupported(mediaParts);
    if (!useWikiTools && apiUrl != DS_API_URL && toolWikiSources.isNotEmpty) {
      logp('ℹ️ 音声・動画入力を含むため、ツールモードでは联网内容插件を併用しません');
      await sse.send('notice', {
        'message': '当前输入含音频/视频，联网内容插件通道不支持，本次未启用百科检索',
      });
    }
    await sse.send('rounds', {'total': 0});
    await sse.send('tool_mode_start', {'start': true});

    final agentMsgs = <Map<String, dynamic>>[
      {'role': 'system', 'content': dbToolSystemPromptFor(model, apiUrl, lang)},
      ...apiMessages,
    ];
    final maxIter = dbToolMaxIterFor(model, apiUrl, rounds);
    if (apiUrl != DS_API_URL) {
      logp('🫘 豆包専用ツールモード: ${dbToolProfileOf(model)} '
          '／ツール ${dbToolCountOf(model)} 件');
    }
    logp('🔧 ツールモード起動: 最大 $maxIter 回の反復（Agent システムプロンプト注入済み）');

    final toolReasoningBuf = StringBuffer();

    ToolStreamOutcome outcome;
    try {
      if (useWikiTools) {
        final w = await callDbWikiWithToolsStream(
          apiKey,
          model,
          agentMsgs,
          maxTokens,
          toolWikiSources,
          maxIter,
          (s) {
            firstContentAt ??= DateTime.now();
            reasoningPump.hurry();
            contentBuf.write(s);
            sse.send('content', {'delta': s});
          },
          (phase, name, args, result) async {
            await sse.send('tool_call', {
              'phase': phase,
              'name': name,
              'args': args,
              'result': result,
            });
          },
          (s) {
            toolReasoningBuf.write(s);
            reasoningPump.push(s);
          },
          usageAcc,
          mediaParts: mediaParts,
          onSources: (list) {
            sse.send('sources', {'items': list, 'channel': 'wiki'});
          },
        );
        outcome = ToolStreamOutcome(w.content, w.reasoning, w.toolLogs);
      } else {
        outcome = await callDsWithToolsStream(
          apiKey,
          model,
          agentMsgs,
          maxTokens,
          temperature,
          maxIter,
          (s) {
            firstContentAt ??= DateTime.now();
            reasoningPump.hurry();
            contentBuf.write(s);
            sse.send('content', {'delta': s});
          },
          (phase, name, args, result) async {
            await sse.send('tool_call', {
              'phase': phase,
              'name': name,
              'args': args,
              'result': result,
            });
          },
          (s) {
            toolReasoningBuf.write(s);
            reasoningPump.push(s);
          },
          usageAcc,
          apiUrl: apiUrl,
        );
      }
    } catch (e) {
      await sse.send('error', {'message': '$e'});
      await sse.done();
      return;
    }
    final toolLogs = outcome.toolLogs;

    // content 为空时回退使用纯 reasoning（剔除工具日志）
    if (contentBuf.toString().trim().isEmpty) {
      final cleaned = StringBuffer();
      for (final line in toolReasoningBuf.toString().split('\n')) {
        final t = line.trim();
        if (t.startsWith('🔧') ||
            t.startsWith('参数:') ||
            t.startsWith('結果:') ||
            t.startsWith('✅')) {
          continue;
        }
        cleaned.write(line);
        cleaned.write('\n');
      }
      final r = cleaned.toString().trim();
      if (r.isNotEmpty) {
        logp('⚠️ ツールモードの content が空です。純粋な reasoning にフォールバックします（${runeLen(r)} 文字）');
        firstContentAt ??= DateTime.now();
        contentBuf.clear();
        contentBuf.write(r);
        await sse.send('content', {'delta': r});
      }
    }

    logp('🔧 ツールモード完了: content=${runeLen(contentBuf.toString())} 字, '
        'reasoning=${runeLen(toolReasoningBuf.toString())} 字, toolLogs=${toolLogs.length} 条');

    if (toolLogs.isEmpty && contentBuf.toString().trim().isEmpty) {
      reasoningPump.push(
          'AI はこの質問にツール呼び出しが不要と判断し、本文も返しませんでした。\n');
    }

    final now = DateTime.now();
    final savedContent = content.isEmpty ? '[工具模式]' : content;
    final userMsg = DsMessage(
      id: 'dsm_${fmtStamp14(now)}_${randomHex(6)}',
      sessionId: sessionID,
      role: 'user',
      content: savedContent,
      createdAt: rfc3339(now),
      attachments: fileIDs.join(','),
    );
    userMsg.dim = dbIsChatModel(model) ? DS_DIM_DB : DS_DIM_DS;
    appendDsMessage(userMsg);

    final aiMsg = DsMessage(
      id: 'dsm_${fmtStamp14(DateTime.now())}_${randomHex(6)}',
      sessionId: sessionID,
      role: 'assistant',
      content: contentBuf.toString(),
      createdAt: rfc3339(DateTime.now()),
      reasoning: outcome.reasoning,
      // 豆包経由では usage を保存しない（方舟の消費量を正確に取得できないため）
      usage: usageAcc.snapshot(),
    );
    aiMsg.dim = dbIsChatModel(model) ? DS_DIM_DB : DS_DIM_DS;
    appendDsMessage(aiMsg);

    final sess = getDsSession(sessionID);
    var title = '新对话';
    if (sess != null) {
      title = sess.title;
      if (title.isEmpty || title == '新对话') {
        final runes = content.runes.toList();
        if (runes.isEmpty) {
          title = '[ツール対話]';
        } else if (runes.length > 18) {
          title = '${String.fromCharCodes(runes.sublist(0, 18))}…';
        } else {
          title = content;
        }
      }
    }
    updateDsSession(sessionID, title, rfc3339(DateTime.now()));

    var thinkingTimeMs = 0;
    if (firstContentAt != null) {
      thinkingTimeMs = firstContentAt!.difference(streamStart).inMilliseconds;
    }
    await sse.send('done', {
      'userMessage': userMsg.toJson(),
      'aiMessage': aiMsg.toJson(),
      'title': title,
      'charCount': runeLen(contentBuf.toString()),
      'model': model,
      'modelRoute': route?.toJson(),
      'toolMode': true,
      'thinkingTimeMs': thinkingTimeMs,
      'totalTimeMs': DateTime.now().difference(streamStart).inMilliseconds,
      'usage': aiMsg.usage?.toJson(),
    });
    await sse.done();
    return;
  }

  // ---------- 普通 / 多轮反思 ----------
  await sse.send('rounds', {'total': rounds});
  DateTime? reasoningStart;
  var reasoningTotalMs = 0;

  // ---------- 豆包联网内容插件（抖音百科等）----------
  // 方舟文档硬约束：sources=[douyin] 等属于「联网内容插件」，
  // 仅 Responses API 支持，Chat Completions 无法指定；因此这里分流。
  // 仅豆包通道 + 用户显式开启信源 + 纯文本输入时启用。
  final wikiSources =
      apiUrl != DS_API_URL ? dbEffectiveSources(forcedSources) : const <String>[];
  // 图片（image_url）可随 input_image 一起提交，与 web_search 并存；
  // 音频 / 视频在插件通道不保证可用，出现时回退原生多模态。
  final canUseWiki = (webSearch || forcedSources.isNotEmpty) &&
      wikiSources.isNotEmpty &&
      pendingVideoIds.isEmpty &&
      dbWikiMediaSupported(mediaParts);

  if (canUseWiki) {
    logp('豆包联网内容插件モード: 信源=${wikiSources.join(",")}');
    try {
      await callDbWikiResponsesStream(
        apiKey,
        model,
        apiMessages,
        maxTokens,
        wikiSources,
        (s) {
          reasoningBuf.write(s);
          reasoningStart ??= DateTime.now();
          reasoningPump.push(s);
        },
        (s) {
          if (reasoningStart != null) {
            reasoningTotalMs +=
                DateTime.now().difference(reasoningStart!).inMilliseconds;
            reasoningStart = null;
          }
          firstContentAt ??= DateTime.now();
          contentBuf.write(s);
          sse.send('content', {'delta': s});
        },
        usageAcc: usageAcc,
        baseUrl: dbBaseUrl(null),
        mediaParts: mediaParts,
        onSources: (list) {
          sse.send('sources', {'items': list, 'channel': 'wiki'});
        },
      );
    } catch (e) {
      logp('豆包联网内容插件の呼び出しに失敗: $e');
      await sse.send('error', {'message': '$e'});
      await sse.done();
      return;
    }
  } else {
  try {
    await callDsMultiRoundStream(
      apiKey,
      model,
      apiMessages,
      maxTokens,
      temperature,
      rounds,
      (round, total, stage) {
        sse.send('round', {'round': round, 'total': total, 'stage': stage});
      },
      (s) {
        reasoningBuf.write(s);
        reasoningStart ??= DateTime.now();
        reasoningPump.push(s);
      },
      (s) {
        if (s == '\x00__NEW_ROUND__\x00') {
          contentBuf.clear();
          sse.send('new_round', {'reset': true});
          return;
        }
        if (reasoningStart != null) {
          reasoningTotalMs += DateTime.now().difference(reasoningStart!).inMilliseconds;
          reasoningStart = null;
        }
        firstContentAt ??= DateTime.now();
        contentBuf.write(s);
        sse.send('content', {'delta': s});
      },
      usageAcc,
      apiUrl: apiUrl,
      extraBody: extraBody,
      onReferences: (list) {
        // 豆包自带联网搜索的信源：仅在方舟通道出现，DeepSeek 恒为空。
        sse.send('sources', {'items': list, 'channel': 'doubao'});
      },
    );
  } catch (e) {
    await sse.send('error', {'message': '$e'});
    await sse.done();
    return;
  }
  }

  if (reasoningStart != null) {
    reasoningTotalMs += DateTime.now().difference(reasoningStart!).inMilliseconds;
    reasoningStart = null;
  }

  final now = DateTime.now();
  final savedContent = content.isEmpty ? '[已上传文件]' : content;
  final userMsg = DsMessage(
    id: 'dsm_${fmtStamp14(now)}_${randomHex(6)}',
    sessionId: sessionID,
    role: 'user',
    content: savedContent,
    createdAt: rfc3339(now),
    attachments: fileIDs.join(','),
  );
  userMsg.dim = dbIsChatModel(model) ? DS_DIM_DB : DS_DIM_DS;
  appendDsMessage(userMsg);

  final aiMsg = DsMessage(
    id: 'dsm_${fmtStamp14(DateTime.now())}_${randomHex(6)}',
    sessionId: sessionID,
    role: 'assistant',
    content: contentBuf.toString(),
    createdAt: rfc3339(DateTime.now()),
    reasoning: reasoningBuf.toString(),
    usage: usageAcc.snapshot(),
  );
  aiMsg.dim = dbIsChatModel(model) ? DS_DIM_DB : DS_DIM_DS;
  appendDsMessage(aiMsg);

  final sess = getDsSession(sessionID);
  var title = '新对话';
  if (sess != null) {
    title = sess.title;
    if (title.isEmpty || title == '新对话') {
      final runes = content.runes.toList();
      if (runes.isEmpty) {
        title = '[ファイル対話]';
      } else if (runes.length > 18) {
        title = '${String.fromCharCodes(runes.sublist(0, 18))}…';
      } else {
        title = content;
      }
    }
  }
  updateDsSession(sessionID, title, rfc3339(DateTime.now()));

  var thinkingTimeMs = 0;
  if (reasoningTotalMs > 0) {
    thinkingTimeMs = reasoningTotalMs;
  } else if (firstContentAt != null) {
    thinkingTimeMs = firstContentAt!.difference(streamStart).inMilliseconds;
  }

  // ★ 收尾：先把思考链泵里剩余的字全部吐完，再发 done。
  //   否则最后一段思考会被 done 截断，前端表现为「思考链少了一截」。
  await reasoningPump.finish();
  if (reasoningPump.smoothed) {
    logp('🧠 思考链平滑: ${reasoningPump.chars} 字已按 micro-delta 重排下发');
  }

  await sse.send('done', {
    'userMessage': userMsg.toJson(),
    'aiMessage': aiMsg.toJson(),
    'title': title,
    'charCount': runeLen(contentBuf.toString()),
    'model': model,
    'modelRoute': route?.toJson(),
    'thinkingTimeMs': thinkingTimeMs,
    'totalTimeMs': DateTime.now().difference(streamStart).inMilliseconds,
    'usage': aiMsg.usage?.toJson(),
  });
  await sse.done();
}

// ------------------------------------------------------------
// 小说模式（非流式）
// ------------------------------------------------------------
Future<void> handleDsNovelGeneration(
  HttpRequest req,
  String sessionID,
  String apiKey,
  String model,
  String theme,
  String tags,
  String genre,
  String story,
  int targetChars,
) async {
  final res = req.response;
  var target = targetChars;
  if (target <= 0) target = DS_NOVEL_DEFAULT_CHARS;
  if (target < DS_NOVEL_MIN_CHARS) target = DS_NOVEL_MIN_CHARS;
  if (target > DS_NOVEL_MAX_CHARS) target = DS_NOVEL_MAX_CHARS;
  var g = genre.trim();
  if (g.isEmpty) g = '都市';
  final th = theme.trim();
  final tg = tags.trim();
  final st = story.trim();

  logp('📖 小説モード起動: 分類=$g テーマ=$th タグ=$tg 目標=$target 文字');

  var userContent = '📖 小説創作\n分類: $g\nテーマ: $th\nタグ: $tg\n目標文字数: $target';
  if (st.isNotEmpty) userContent += '\nストーリー設定: $st';

  final userMsg = DsMessage(
    id: 'dsm_${fmtStamp14(DateTime.now())}_${randomHex(6)}',
    sessionId: sessionID,
    role: 'user',
    content: userContent,
    createdAt: rfc3339(DateTime.now()),
  );
  userMsg.dim = dbIsChatModel(model) ? DS_DIM_DB : DS_DIM_DS;
  appendDsMessage(userMsg);

  final basePrompt = buildNovelBasePrompt(th, tg, g, st, target);
  final usageAcc = DsUsageAcc();
  final gen = await generateNovel(apiKey, model, basePrompt, target, usageAcc);
  if (gen.error != null && gen.text.trim().isEmpty) {
    await dsJSONErr(res, 500, '小説の生成に失敗しました: ${gen.error}');
    return;
  }

  final aiMsg = DsMessage(
    id: 'dsm_${fmtStamp14(DateTime.now())}_${randomHex(6)}',
    sessionId: sessionID,
    role: 'assistant',
    content: gen.text,
    createdAt: rfc3339(DateTime.now()),
    usage: usageAcc.snapshot(),
  );
  aiMsg.dim = dbIsChatModel(model) ? DS_DIM_DB : DS_DIM_DS;
  appendDsMessage(aiMsg);

  var title = '小説創作';
  if (th.isNotEmpty) {
    final runes = th.runes.toList();
    title = runes.length > 15
        ? '${String.fromCharCodes(runes.sublist(0, 15))}…'
        : th;
  }
  final sess = getDsSession(sessionID);
  if (sess != null &&
      sess.title.isNotEmpty &&
      sess.title != '新对话' &&
      sess.title != '小説創作') {
    title = sess.title;
  }
  updateDsSession(sessionID, title, rfc3339(DateTime.now()));

  logp('✅ 小説の生成が完了しました。計 ${runeLen(gen.text)} 文字');
  await dsJSONOk(res, 200, {
    'success': true,
    'userMessage': userMsg.toJson(),
    'aiMessage': aiMsg.toJson(),
    'title': title,
    'charCount': runeLen(gen.text),
    'model': model,
    'novelMode': true,
    'usage': aiMsg.usage?.toJson(),
  });
}

// ------------------------------------------------------------
// 小说模式（流式）
// ------------------------------------------------------------
Future<void> handleDsNovelGenerationStream(
  HttpRequest req,
  String sessionID,
  String apiKey,
  String model,
  String theme,
  String tags,
  String genre,
  String story,
  int targetChars,
) async {
  var target = targetChars;
  if (target <= 0) target = DS_NOVEL_DEFAULT_CHARS;
  if (target < DS_NOVEL_MIN_CHARS) target = DS_NOVEL_MIN_CHARS;
  if (target > DS_NOVEL_MAX_CHARS) target = DS_NOVEL_MAX_CHARS;
  var g = genre.trim();
  if (g.isEmpty) g = '都市';
  final th = theme.trim();
  final tg = tags.trim();
  final st = story.trim();

  final sse = Sse(req.response);

  var userContent = '📖 小説創作\n分類: $g\nテーマ: $th\nタグ: $tg\n目標文字数: $target';
  if (st.isNotEmpty) userContent += '\nストーリー設定: $st';
  final userMsg = DsMessage(
    id: 'dsm_${fmtStamp14(DateTime.now())}_${randomHex(6)}',
    sessionId: sessionID,
    role: 'user',
    content: userContent,
    createdAt: rfc3339(DateTime.now()),
  );
  userMsg.dim = dbIsChatModel(model) ? DS_DIM_DB : DS_DIM_DS;
  appendDsMessage(userMsg);
  await sse.send('user_message', userMsg.toJson());

  logp('📖 小説モード（ストリーミング）起動: 分類=$g テーマ=$th タグ=$tg 目標=$target 文字');

  final basePrompt = buildNovelBasePrompt(th, tg, g, st, target);
  final usageAcc = DsUsageAcc();

  final gen = await generateNovelStream(
    apiKey,
    model,
    basePrompt,
    target,
    (delta) async => sse.send('content', {'delta': delta}),
    (segIdx) async => sse.send('novel_segment', {'index': segIdx}),
    (done, tgt) => sse.send('novel_progress', {'done': done, 'target': tgt}),
    usageAcc,
  );
  if (gen.error != null && gen.text.trim().isEmpty) {
    await sse.send('error', {'message': gen.error});
    await sse.done();
    return;
  }

  final aiMsg = DsMessage(
    id: 'dsm_${fmtStamp14(DateTime.now())}_${randomHex(6)}',
    sessionId: sessionID,
    role: 'assistant',
    content: gen.text,
    createdAt: rfc3339(DateTime.now()),
    usage: usageAcc.snapshot(),
  );
  aiMsg.dim = dbIsChatModel(model) ? DS_DIM_DB : DS_DIM_DS;
  appendDsMessage(aiMsg);

  var title = '小説創作';
  if (th.isNotEmpty) {
    final runes = th.runes.toList();
    title = runes.length > 15
        ? '${String.fromCharCodes(runes.sublist(0, 15))}…'
        : th;
  }
  final sess = getDsSession(sessionID);
  if (sess != null &&
      sess.title.isNotEmpty &&
      sess.title != '新对话' &&
      sess.title != '小説創作') {
    title = sess.title;
  }
  updateDsSession(sessionID, title, rfc3339(DateTime.now()));

  await sse.send('done', {
    'userMessage': userMsg.toJson(),
    'aiMessage': aiMsg.toJson(),
    'title': title,
    'charCount': runeLen(gen.text),
    'model': model,
    'novelMode': true,
    'usage': aiMsg.usage?.toJson(),
  });
  await sse.done();
}

// ------------------------------------------------------------
// /api/ds-chat/send
// ------------------------------------------------------------
Future<void> handleDsChatSend(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'POST') {
    await dsJSONErr(res, 405, 'Method not allowed');
    return;
  }
  Map<String, dynamic> body;
  try {
    body = await readJsonBody(req);
  } catch (_) {
    await dsJSONErr(res, 400, '无效请求体');
    return;
  }

  final sessionID = mStr(body, 'sessionId');
  var content = mStr(body, 'content').trim();
  final fileIDs = asList(body['fileIds']).map((e) => '$e').toList();
  final webSearch = mBool(body, 'webSearch');
  final deepThink = mBool(body, 'deepThink');
  var level = intArgDefault(body, 'reasoningLevel', 1);
  final longTextMode = mBool(body, 'longTextMode');
  final targetChars = intArgDefault(body, 'targetChars', 0);
  final novelMode = mBool(body, 'novelMode');
  final novelTheme = mStr(body, 'novelTheme');
  final novelTags = mStr(body, 'novelTags');
  final novelGenre = mStr(body, 'novelGenre');
  final novelStory = mStr(body, 'novelStory');
  final novelChars = intArgDefault(body, 'novelChars', 0);
  var enableTools = mBool(body, 'enableTools');
  // ★ 双保险（严重 Bug 修复）：前端 UI 的真实开关状态随请求一起上报。
  //   enableTools 与 toolModeUI 必须同时为 true 才算开启；
  //   只要前端明确表示「UI 上工具模式是关的」，服务端就不下发 tools 定义，
  //   DsToolGate 也会同步为 OFF —— 从根上避免「UI 关着但模型照跑工具」。
  if (body.containsKey('toolModeUI') && !mBool(body, 'toolModeUI')) {
    enableTools = false;
  }
  // ★ 显式按钮（墨迹天气 / 头条图文）触发的插件调用。
  //   白名单制：只认下面这两种，其它值一律视为无效，避免变成通用绕过开关。
  var explicitPlugin = mStr(body, 'explicitPlugin').trim().toLowerCase();
  if (!const <String>['moji', 'toutiao'].contains(explicitPlugin)) {
    explicitPlugin = '';
  }
  final injectedPrompts = asList(body['injectedPrompts']).map((e) => '$e').toList();
  final stream = mBool(body, 'stream');

  if (content.isEmpty && fileIDs.isEmpty && !novelMode) {
    await dsJSONErr(res, 400, '内容不能为空');
    return;
  }
  if (sessionID.isEmpty) {
    await dsJSONErr(res, 400, '缺少会话ID');
    return;
  }

  final cfg = getDsConfig();
  var model = mStr(body, 'model').trim();
  if (model.isEmpty) model = cfg.model;
  if (model.isEmpty) model = DS_DEFAULT_MODEL;

  // ========== 豆包（火山方舟）通道判定 ==========
  // 选中的模型属于豆包目录时，鉴权与终点全部切到方舟，
  // 绝不把豆包模型名发往 DeepSeek（否则返回 400 invalid_request_error）。
  final dbCfg = getDbConfig();
  final useDoubao = dbIsChatModel(model);
  if (useDoubao) {
    if (dbCfg.apiKey.isEmpty) {
      await dsJSONErr(res, 400, '已选择豆包模型，但豆包 API Key 未填写（设置 → 豆包设定）');
      return;
    }
  } else if (cfg.apiKey.isEmpty) {
    await dsJSONErr(res, 400, '请先配置 DeepSeek API Key');
    return;
  }
  final callKey = useDoubao ? dbCfg.apiKey : cfg.apiKey;
  final callUrl = useDoubao ? dbChatEndpoint() : DS_API_URL;
  logp('🚀 使用モデル: $model (リクエスト=${mStr(body, 'model')}, 設定=${cfg.model}, '
      '経路=${useDoubao ? '豆包/方舟' : 'DeepSeek'})');

  // ★★ 显式插件按钮通道（墨迹天气 / 头条图文）
  //   用户需求：
  //     ① 点击按钮后「关闭工具模式」——function calling 全部禁用；
  //     ② 但「必须真的调用该联网内容插件」，并把结果按 Markdown 返回。
  //   实现要点：
  //     · explicitPlugin 只用于「强制信源」，绝不开启工具模式；
  //     · 本请求 enableTools 被硬性置为 false，并同步 DsToolGate 为 OFF；
  //     · 插件走 Responses API 的 web_search(sources=[moji|toutiao])，
  //       与 function calling 是两条完全独立的通道。
  final List<String> explicitSources = explicitPlugin.isEmpty
      ? const <String>[]
      : <String>[explicitPlugin];
  if (explicitPlugin.isNotEmpty) {
    if (!useDoubao) {
      await dsJSONErr(res, 400, '墨迹天气 / 头条图文插件仅支持豆包模型，请先切换到豆包模式');
      return;
    }
    enableTools = false;
    DsToolGate.syncMode(sessionID, false);
    logp('🎯 明示プラグイン: $explicitPlugin（ツールモードは強制 OFF・該当插件のみ呼び出す）');
  }

  // ★★ 前缀强制信源（doubao_intent.dart）
  //   「抖音百科：」「抖音百科搜索：」「百科：」→ 强制 douyin
  //   「墨迹天气：」「天气：」            → 强制 moji
  //   判定范围是消息任意位置；前缀本身从正文里剥掉，不进入模型与标题。
  //   DeepSeek 通道不解析（那套插件只存在于方舟），行为零变化。
  var dbIntent = useDoubao ? dbParseIntent(content) : DbIntent.none;
  final List<String> forcedSources = explicitSources.isNotEmpty
      ? explicitSources
      : (dbIntent.forced ? dbIntent.sources : const <String>[]);
  if (explicitSources.isNotEmpty) {
    logp('📌 明示プラグインの強制信源: ' + explicitSources.join(','));
  }
  if (dbIntent.forced) {
    content = dbIntent.cleaned;
    logp('📌 信源プレフィックスを検出: ${dbIntent.hits.join(' / ')} '
        '→ 強制 sources=${forcedSources.join(',')}');
  }

  // ========== 小说模式分流 ==========
  if (novelMode) {
    if (stream) {
      await handleDsNovelGenerationStream(req, sessionID, cfg.apiKey, model,
          novelTheme, novelTags, novelGenre, novelStory, novelChars);
      return;
    }
    await handleDsNovelGeneration(req, sessionID, cfg.apiKey, model,
        novelTheme, novelTags, novelGenre, novelStory, novelChars);
    return;
  }

  if (level < 1) level = 1;
  if (level > 50) level = 50;
  var params = levelToParams(level);
  var maxTokens = params.maxTokens;
  var temperature = params.temperature;
  var rounds = params.rounds;

  if (longTextMode) {
    maxTokens = DS_MAX_OUTPUT_TOKENS;
    rounds = 1;
    temperature = 1.0;
    logp('📚 超長文モード有効: maxTokens=$maxTokens, 目標文字数=$targetChars');
  }
  if (enableTools) temperature = 0.0;

  // ========== 豆包模式 × 抖音百科：职责单一，绝不叠加 ==========
  // 1) 豆包通道一律单轮：推論レベル只抬高 max_tokens，不再触发多轮自我反思。
  // 2) 抖音百科（联网内容插件，仅 Responses API）生效期间强制关闭工具模式：
  //    否则 Chat Completions 的 function calling 与插件的 web_search 会在同一轮
  //    互相抢占，表现为「豆包模式搜索抖音百科时突然调用工具」的严重 bug。
  if (useDoubao && !longTextMode) {
    if (rounds != 1) {
      logp('🫘 豆包モード: 多輪反思を無効化（rounds=$rounds → 1、max_tokens=$maxTokens は維持）');
    }
    rounds = 1;
  }
  // 抖音百科生效（含前缀强制）时工具模式必须让路：
  // 用户在豆包专属工具模式下打开百科，开关一开就自动关闭工具模式，
  // 且按钮置灰不可点——这里再做一次服务端强制，防止前端状态不同步。
  final dbWikiActiveNow =
      useDoubao && dbEffectiveSources(forcedSources).isNotEmpty;
  if (useDoubao && enableTools && dbWikiActiveNow) {
    enableTools = false;
    DsToolGate.syncMode(sessionID, false);
    logp('🛑 抖音百科が有効なためツールモードを自動解除（検索とツール呼び出しの衝突を根本回避）');
  }
  // ★ 单一可信来源：本请求最终的 enableTools 就是服务端闸门的模式状态。
  //   之后所有工具执行（含插件混用通道）都以这里为准，前端状态不再能「带私货」。
  DsToolGate.bind(sessionID);
  // ★ 请求租约：只有处在正在处理的聊天请求里，工具才可能被执行。
  //   请求外 / 租约过期后，任何残留绑定一律 fail-closed。
  DsToolGate.beginRequest(sessionID, enableTools);
  DsToolGate.syncMode(sessionID, enableTools);

  // 注入提示词（system 角色）
  // 本机开发者工具（devtools）功能，按所有者要求恢复启用。
  final injected = injectedPrompts
      .map((e) => '$e'.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  if (injected.isNotEmpty) {
    logp('🧩 外部注入プロンプトを適用: ${injected.length} 件（system ロール）');
  }

  final fileCtx = buildFileContext(fileIDs);

  // ========== 豆包通道：音频 / 视频理解能力校验 ==========
  // 豆包模式下媒体附件必须由具备对应能力的豆包模型直接理解：
  //   · 绝不把音视频降级成「文件名」文本偷偷送去 DeepSeek（会消耗 DeepSeek 用量）
  //   · 模型不具备该能力时如实报错，并列出可切换的模型
  final mediaLang = dsRequestLang(req, body);
  if (useDoubao) {
    if (fileCtx.audioFileIds.isNotEmpty && !dbSupportsAudioInput(model)) {
      await dsJSONErr(
          res,
          400,
          dbLocalized(mediaLang, 'audioUnsupported',
              [model, dbAudioCapableModels.join(' / ')]));
      return;
    }
    if (fileCtx.videoFileIds.isNotEmpty && !dbSupportsVideoInput(model)) {
      await dsJSONErr(
          res,
          400,
          dbLocalized(mediaLang, 'videoUnsupported',
              [model, dbVideoCapableModels.join(' / ')]));
      return;
    }
  }

  // ============ 模型自动路由（本轮含图片 → 视觉模型）============
  // 改造前：图片提取直接传 model，选 pro 就等于用纯文本模型读图，
  // 结果是「图片内容提取失败」这种静默降级。现在统一由 model_router 判定：
  //   - 所选模型本身支持图片 → 原样使用；
  //   - 所选模型不支持（如 deepseek-v4-pro）→ 路由到视觉兜底模型。
  final routeSettings = getModelRouteSettings();
  // 豆包模型不参与 DeepSeek 的视觉路由（否则会被改名为 deepseek-flash）
  final route = useDoubao
      ? ModelRouteDecision(
          requested: model,
          effective: model,
          visionModel: model,
          reason: 'doubao-direct',
          routed: false,
          hasImage: fileCtx.imageFileIds.isNotEmpty,
          requestedSupportsVision: fileCtx.imageFileIds.isNotEmpty,
        )
      : resolveModelRoute(model,
          hasImage: fileCtx.imageFileIds.isNotEmpty, settings: routeSettings);
  if (route.hasImage || route.routed || route.reason == 'router-disabled') {
    recordModelRoute(route);
    logp('🔀 モデルルーティング: ${route.summary} · 視覚抽出モデル=${route.visionModel}');
  }
  if (route.routed) {
    logp('🔀 メインリクエストのモデルを ${route.effective} に切替（元の選択 ${route.requested}）');
    model = route.effective;
  }

  var userPrompt = content;
  if (fileCtx.text.isNotEmpty) {
    if (userPrompt.isNotEmpty) userPrompt += '\n\n';
    userPrompt += fileCtx.text;
  }

  // ★ 联网检索的归属（三条互斥通道，绝不同时触发）
  //   ① 抖音百科（联网内容插件）开启 → Responses API 自带检索
  //   ② 百科关闭、仅开「联网搜索」→ 豆包自带联网搜索（web_search_options，
  //      方舟豆包搜索 Custom 版，每月 2 万次免费额度）
  //   ③ DeepSeek 通道 → DeepSeek 官方 /v1/tools/search
  //   旧实现里 ② 走的却是 DeepSeek 官方搜索（用 DeepSeek Key 计费），
  //   豆包模式白白多打一次国外请求，首包也被拖慢数秒。
  var dbNativeSearch = false;
  if ((webSearch || forcedSources.isNotEmpty) && content.isNotEmpty) {
    final wikiOn = useDoubao && dbWikiActiveNow;
    if (wikiOn) {
      // 插件自己会检索；再叠一次官方搜索就是「两次联网」，首包被拖后数秒。
      logp('🔍 豆包モード：联网内容プラグインが検索を担当するため、公式検索は省略（二重検索回避）');
    } else if (useDoubao) {
      dbNativeSearch = true;
      logp('🔍 豆包モード：豆包ネイティブ検索（web_search_options / 月2万回無料枠）を使用');
    } else {
      final ctx = await buildWebSearchContext(content);
      if (ctx.isNotEmpty) userPrompt += ctx;
    }
  }
  if (userPrompt.trim().isEmpty) userPrompt = 'アップロードしたファイルを確認してください。';

  if (longTextMode) {
    final target = targetChars <= 0 ? DS_TARGET_CHARS_5M : targetChars;
    userPrompt += '''\n\n【重要指令 · 超長文モード】\n完全な長文をそのまま出力してください。目標文字数は $target 文字（約 $target 文字相当）。\n要件:\n1. 「これから...」「以下は...」「まとめ」といった前置きや結びは一切書かないこと\n2. 本文から直接始め、章立てを明確にし、内容を充実させること\n3. 長さ制限を理由に早く終わらせず、可能な限り書き切ること\n4. 内容の質を保ち、繰り返しの水増しを避けること''';
  }

  // 图片内容提取（仅 DeepSeek 通道需要：先让视觉模型转述，再交给文本模型）
  // 豆包通道不转述：原图直接交给模型本人看，由它自己回答并思考。
  if (!useDoubao && fileCtx.imageFileIds.isNotEmpty) {
    final visionDescs = <String>[];
    for (var i = 0; i < fileCtx.imageFileIds.length; i++) {
      final imgID = fileCtx.imageFileIds[i];
      final b64 = dsFileToBase64(imgID);
      if (b64.error == null && b64.b64.isNotEmpty) {
        logp('🖼️ ${i + 1}/${fileCtx.imageFileIds.length} 枚目の画像を検出しました。内容を抽出します...');
        final visionPrompt =
            '${i + 1} 枚目の画像の内容を詳しく説明し、含まれるすべての文字を抽出し、要点をまとめてください。';
        try {
          final desc = await callDsVisionAPI(
              callKey, visionPrompt, b64.b64, b64.mime, 4096, 1.0,
              model: route.visionModel, apiUrl: callUrl);
          if (desc.trim().isNotEmpty) {
            visionDescs.add('【${i + 1} 枚目の画像の内容抽出結果】\n$desc');
            logp('✅ ${i + 1} 枚目の画像の内容抽出に成功しました');
          } else {
            visionDescs.add('【${i + 1} 枚目の画像の内容抽出結果は空です】');
          }
        } catch (e) {
          logp('⚠️ ${i + 1} 枚目の画像の抽出に失敗しました: $e');
          visionDescs.add('【${i + 1} 枚目の画像の内容抽出に失敗しました】');
        }
      } else {
        logp('⚠️ ${i + 1} 枚目の画像の読み込みに失敗しました: ${b64.error}');
        visionDescs.add('【${i + 1} 枚目の画像を読み込めません】');
      }
    }
    if (visionDescs.isNotEmpty) {
      userPrompt += '\n\n【画像内容の抽出結果（視覚モデルが生成）】\n'
          '${visionDescs.join('\n\n')}';
      logp('✅ すべての画像の内容抽出が完了し、プロンプトに結合しました');
    }
  }

  // ========== 豆包通道：媒体附件以原生多模态形式提交 ==========
  // 图片 → image_url、音频 → input_audio、视频 → video_url，
  // 全部原样交给豆包本人理解；同时开启深度思考（thinking）。
  var useTools = enableTools;
  // ★ 修复严重 Bug：这里原先在检测到「设备操作意图」时直接把 useTools 置为 true，
  //   等于在用户看不见的服务端绕过工具模式开关（UI 显示已关闭，实际照跑）。
  //   现在不再自动开启：开关关着就是关着，模型拿不到 tools 定义，
  //   即使它自己写出 function call，执行层（DsToolGate）也会直接拒绝。
  if (!useTools && dsIsDeviceIntent(content)) {
    logp('⛔ 設備操作意図を検出したが、ツールモードは OFF のため自動有効化しません');
  }
  Map<String, dynamic>? dbExtraBody;
  // ★ 豆包通道：把「深い思考」开关直接映射到方舟的 thinking 字段。
  //   不传时方舟按模型默认开启深度思考，首包会被拖到 60 秒以上，
  //   前端看到的就是「不是流式、非常慢」。关闭时不思考，立刻逐字出流。
  //   含媒体时由下面的 dbThinkingEnableParam 覆盖为 enabled（先看再想）。
  if (useDoubao) {
    dbExtraBody = deepThink
        ? dbThinkingEnableParam(model)
        : dbThinkingDisableParam(model);
    // ★ 思考长度旋钮（方舟 reasoning_effort）
    //   「思考链卡」的第一因是 summary 块间延迟，与思维链总长正相关。
    //   这里按 UI 推理等级把默认 high 降下来，配合服务端 micro-delta
    //   重排（DbReasoningPump），两者叠加才是真正不卡的组合。
    final effort = dbReasoningEffortParam(model,
        level: level, mode: deepThink ? 'on' : 'auto');
    if (effort != null) {
      dbExtraBody = <String, dynamic>{
        ...?dbExtraBody,
        'reasoning_effort': effort,
      };
      logp('🧠 豆包の思考長を調整: reasoning_effort=$effort'
          '（推論レベル $level / ${dbThinkingProfileOf(model)}）');
    }
  }
  // ★ 豆包自带联网搜索（百科关闭 + 联网开启）：Chat Completions 的
  //   web_search_options 直接由方舟执行检索，消耗豆包搜索免费额度。
  //   工具模式与它互斥（同时出现会被方舟拒绝），故工具模式下不附加。
  if (dbNativeSearch && !useTools) {
    dbExtraBody = <String, dynamic>{
      ...(dbExtraBody ?? const <String, dynamic>{}),
      'web_search_options': dbWebSearchOptions(),
    };
    logp('🌐 豆包ネイティブ検索を有効化（web_search_options, 月2万回無料枠）');
  }
  final dbMediaParts = <Map<String, dynamic>>[];
  // 视频统一由 doubao_video_ark 处理：≤45MB 直接作为 video_url 片段，
  // >45MB 用 ffmpeg 无损切片后逐段理解（2GB 也能看完）。
  // 切片 + 逐段理解可能持续几分钟到几十分钟，而本机 HttpServer 的
  // idleTimeout 是 120 秒：流式模式下若等到主函数末尾才建立 SSE，
  // 等待期间连接会被掐断。因此「流式 + 含视频」时把媒体准备挪到 SSE 建连之后
  // （SSE 自带 15 秒心跳负责保活）。
  final deferVideoPrepare = useDoubao &&
      stream &&
      !longTextMode &&
      fileCtx.videoFileIds.isNotEmpty;
  if (useDoubao && fileCtx.hasMedia) {
    for (final id in fileCtx.imageFileIds) {
      final b64 = dsFileToBase64(id);
      if (b64.error == null && b64.b64.isNotEmpty) {
        dbMediaParts.add(dbImagePart(b64.mime, b64.b64));
      } else {
        logp('⚠️ 画像の読み込みに失敗しました（豆包へは送信しません）: ${b64.error}');
      }
    }
    for (final id in fileCtx.audioFileIds) {
      final meta = getDsFileMeta(id);
      if (meta == null) continue;
      final f = File('$DSFilesBlobDir/${meta.relPath}');
      if (!f.existsSync()) continue;
      final raw = f.readAsBytesSync();
      if (raw.length > 40 * 1024 * 1024) {
        await dsJSONErr(
            res, 400, dbLocalized(mediaLang, 'audioTooLarge', [meta.name]));
        return;
      }
      final prepared = await dbPrepareAudioForArk(raw, meta.name);
      dbMediaParts.add(dbAudioPart(prepared.format, base64Encode(prepared.bytes)));
      logp('🎧 音声を豆包の音声理解へ直接送信: ${meta.name} (${prepared.format})');
    }
    // 视频：不再 readAsBytesSync + base64（2GB 走那条路必然 OOM）。
    // 现在交给 doubao_video_ark：≤45MB 直接作为 video_url 片段，
    // >45MB 用 ffmpeg 无损切片后逐段理解，结论并入 userPrompt。
    if (!deferVideoPrepare) {
      try {
        final vid = await dbVideoContentForChat(
          videoFileIds: fileCtx.videoFileIds,
          model: model,
          apiKey: callKey,
        );
        dbMediaParts.addAll(vid.parts);
        if (vid.text.isNotEmpty) {
          // 大视频：分段理解结果以文本形式并入用户提示词
          userPrompt = '$userPrompt\n\n${vid.text}';
          logp('🧾 動画の分段理解結果をプロンプトへ結合（${runeLen(vid.text)} 文字）');
        }
      } on DbVideoArkException catch (e) {
        logp('❌ 動画の準備に失敗: ${e.message}');
        await dsJSONErr(res, 400, e.message);
        return;
      }
    } else {
      logp('🎬 動画 ${fileCtx.videoFileIds.length} 件は SSE 接続後に '
          '分割・準備します');
    }
    // 画像 / 音声 / 動画を見たうえで、まず考えてから答える
    dbExtraBody = dbThinkingEnableParam(model);
    if (dbExtraBody != null) {
      logp('🧠 豆包の深度思考を有効化（メディア理解後に思考して回答）');
    }
    // ツールモードのリクエスト形式は thinking と併用できないため、
    // メディア添付時のみ自動解除する（黙って無視はしない）。
    if (useTools) {
      useTools = false;
      // 工具模式曾把 temperature 压到 0，这里恢复默认采样温度
      temperature = 1.0;
      logp('ℹ️ メディア添付のためツールモードを自動解除しました（思考を優先）');
    }
  }
  // DeepSeek 通道不具备音视频理解能力，如实告知而不是假装已读
  if (!useDoubao &&
      (fileCtx.audioFileIds.isNotEmpty || fileCtx.videoFileIds.isNotEmpty)) {
    final names = <String>[
      ...fileCtx.audioFileIds.map((id) => getDsFileMeta(id)?.name ?? id),
      ...fileCtx.videoFileIds.map((id) => getDsFileMeta(id)?.name ?? id),
    ];
    logp('⚠️ DeepSeek 通道は音声・動画理解に非対応: ${names.join('、')}');
    userPrompt +=
        '\n\n' + dbLocalized(mediaLang, 'noMediaNote', [names.join('、')]);
  }

  // 跨会话引用
  final refs = resolveCrossSessionRefs(userPrompt, sessionID);
  if (refs.injected) userPrompt = refs.rewritten;

  // ★ 维度隔離：只把「同一维度」の履歴をモデルへ渡す。
  //   豆包(dim=db) と DeepSeek(dim=ds) は互いのメッセージを一切見ない。
  final chatDim = dbIsChatModel(model) ? DS_DIM_DB : DS_DIM_DS;
  logp('🧭 送信维度=$chatDim (model=$model)');
  var history = getDsMessages(sessionID, dim: chatDim);
  history = pickHistoryWindow(history);

  final apiMessages = <Map<String, dynamic>>[];
  // i18n：UI 言語に一致した言語固定プロンプトを注入
  final uiLang = dsRequestLang(req, body);
  final sysParts = <String>[];
  sysParts.add(dsLangSystemPrompt(uiLang));
  if (deepThink) {
    sysParts.add('深い多段階の推論が可能です。思考プロセスを十分に示してください。');
  }
  if (longTextMode) {
    sysParts.add('あなたは長文執筆を得意とするプロの作家です。前置きやまとめを一切入れず、完成した長文を直接出力してください。');
  }
  // ★ 显式插件按钮（墨迹天气 / 头条图文）：强制模型真的调用插件 + Markdown 结构化输出。
  //   工具模式在这条请求里恒为 OFF，因此这里只做「信源使用」与「输出格式」约束。
  if (explicitPlugin == 'moji') {
    sysParts.add('【插件强制指令 · 墨迹天气】本次回答必须基于「墨迹天气」联网内容插件返回的真实数据。'
        '禁止凭记忆编造天气。请给出：当前实况（天气现象、气温、体感、湿度、风力风向）、'
        '未来 24 小时趋势、以及出行/穿衣建议。信息不足时明确说明，不要虚构。');
  } else if (explicitPlugin == 'toutiao') {
    sysParts.add('【插件强制指令 · 头条图文】本次回答必须基于「头条图文」联网内容插件返回的真实图文内容，'
        '禁止编造新闻事实。请严格按 Markdown 结构输出：# 标题、## 要点速览（无序列表）、'
        '## 正文综述（分段，可用 **加粗** 强调关键信息）、## 信息来源（列表附链接）。'
        '代码 / 命令 / 数据片段必须放进 ``` 围栏代码块，长内容可用 '
        '<details><summary>展开查看</summary>…</details> 折叠，绝不直接裸露 Markdown 标记。');
  }

  sysParts.addAll(injected);
  final cp = renderActiveCosplayPersona();
  if (cp.isNotEmpty) sysParts.add(cp);
  if (sysParts.isNotEmpty) {
    apiMessages.add({'role': 'system', 'content': sysParts.join('\n')});
  }
  for (final m in history) {
    if (m.role == 'user' || m.role == 'assistant' || m.role == 'system') {
      apiMessages.add({'role': m.role, 'content': m.content});
    }
  }
  if (refs.injected) {
    for (final snap in refs.snapshots) {
      apiMessages.add({'role': 'user', 'content': snap});
    }
  }
  if (deferVideoPrepare) {
    // 含视频的流式请求：本条 user message 由 handleDsChatSendStream 在
    // SSE 建连、且视频 file_id 准备好之后追加（避免 120 秒空闲断连）。
    logp('⏸️ 動画付きリクエスト: user メッセージの追加を SSE 側へ委譲');
  } else if (dbMediaParts.isNotEmpty) {
    apiMessages.add({
      'role': 'user',
      'content': <Map<String, dynamic>>[
        {'type': 'text', 'text': userPrompt},
        ...dbMediaParts,
      ],
    });
  } else {
    apiMessages.add({'role': 'user', 'content': userPrompt});
  }

  // ============ 流式分支 ============
  if (stream && !longTextMode) {
    await handleDsChatSendStream(req, callKey, model, apiMessages,
        maxTokens, temperature, rounds, sessionID, content, fileIDs, useTools,
        webSearch: webSearch || forcedSources.isNotEmpty,
        route: route,
        apiUrl: callUrl,
        extraBody: dbExtraBody,
        lang: uiLang,
        forcedSources: forcedSources,
        userPrompt: deferVideoPrepare ? userPrompt : '',
        mediaParts: dbMediaParts,
        pendingVideoIds:
            deferVideoPrepare ? fileCtx.videoFileIds : const <String>[]);
    return;
  }

  // ============ 工具模式（非流式） ============
  if (useTools) {
    logp('🔧 ツールモードを有効化し、マルチターンの function calling を開始します（最大 $DS_TOOL_MAX_ITERATIONS ラウンド）');
    final usageAcc = DsUsageAcc();
    final agentMsgs = <Map<String, dynamic>>[
      {'role': 'system', 'content': dbToolSystemPromptFor(model, callUrl, uiLang)},
      ...apiMessages,
    ];
    ToolStreamOutcome outcome;
    try {
      outcome = await callDsWithTools(callKey, model, agentMsgs, maxTokens,
          temperature, dbToolMaxIterFor(model, callUrl, rounds), usageAcc,
          apiUrl: callUrl);
    } catch (e) {
      await dsJSONErr(res, 500, 'ツール呼び出しに失敗しました: $e');
      return;
    }

    final now = DateTime.now();
    final savedContent = content.isEmpty ? '[工具模式]' : content;
    final userMsg = DsMessage(
      id: 'dsm_${fmtStamp14(now)}_${randomHex(6)}',
      sessionId: sessionID,
      role: 'user',
      content: savedContent,
      createdAt: rfc3339(now),
      attachments: fileIDs.join(','),
    );
    userMsg.dim = dbIsChatModel(model) ? DS_DIM_DB : DS_DIM_DS;
    appendDsMessage(userMsg);

    var fullReasoning = outcome.reasoning;
    if (outcome.toolLogs.isNotEmpty) {
      fullReasoning =
          '【ツール呼び出し記録】\n${outcome.toolLogs.join('\n\n───────────────\n\n')}';
      if (outcome.reasoning.isNotEmpty) {
        fullReasoning += '\n\n【モデルの思考プロセス】\n${outcome.reasoning}';
      }
    }

    final aiMsg = DsMessage(
      id: 'dsm_${fmtStamp14(DateTime.now())}_${randomHex(6)}',
      sessionId: sessionID,
      role: 'assistant',
      content: outcome.content,
      createdAt: rfc3339(DateTime.now()),
      reasoning: fullReasoning,
      // 豆包额度无法从方舟精确取得，故不落库 usage，避免误导
      usage: usageAcc.snapshot(),
    );
    aiMsg.dim = dbIsChatModel(model) ? DS_DIM_DB : DS_DIM_DS;
    appendDsMessage(aiMsg);

    final sess = getDsSession(sessionID);
    var title = '新对话';
    if (sess != null) {
      title = sess.title;
      if (title.isEmpty || title == '新对话') {
        final runes = content.runes.toList();
        if (runes.length > 18) {
          title = '${String.fromCharCodes(runes.sublist(0, 18))}…';
        } else if (runes.isNotEmpty) {
          title = content;
        }
      }
    }
    updateDsSession(sessionID, title, rfc3339(DateTime.now()));

    await dsJSONOk(res, 200, {
      'success': true,
      'userMessage': userMsg.toJson(),
      'aiMessage': aiMsg.toJson(),
      'title': title,
      'charCount': runeLen(outcome.content),
      'model': model,
      'modelRoute': route.toJson(),
      'toolLogs': outcome.toolLogs,
      'toolRounds': outcome.toolLogs.length,
      'usage': aiMsg.usage?.toJson(),
    });
    return;
  }

  // ============ 非流式兜底 ============
  // 豆包联网内容插件（抖音百科等）在非流式路径同样生效：
  // Responses API 本身仍是流式，这里把增量累积成完整文本后返回。
  final usageAcc = DsUsageAcc();
  String reply;
  String reasoning;
  final wikiSrcFallback =
      useDoubao ? dbEffectiveSources(forcedSources) : const <String>[];
  final wikiOkFallback = (webSearch || forcedSources.isNotEmpty) &&
      wikiSrcFallback.isNotEmpty &&
      fileCtx.videoFileIds.isEmpty &&
      dbWikiMediaSupported(dbMediaParts);
  try {
    if (wikiOkFallback) {
      final rb = StringBuffer();
      final cb = StringBuffer();
      await callDbWikiResponsesStream(
        callKey,
        model,
        apiMessages,
        maxTokens,
        wikiSrcFallback,
        (s) => rb.write(s),
        (s) => cb.write(s),
        usageAcc: usageAcc,
        baseUrl: dbBaseUrl(null),
        mediaParts: dbMediaParts,
      );
      reply = cb.toString();
      reasoning = rb.toString();
    } else {
      final r = await callDsMultiRound(callKey, model, apiMessages, maxTokens,
          temperature, rounds, null, usageAcc,
          apiUrl: callUrl, extraBody: dbExtraBody);
      reply = r.content;
      reasoning = r.reasoning;
    }
  } catch (e) {
    await dsJSONErr(res, 500, 'API 呼び出しに失敗しました: $e');
    return;
  }

  final now = DateTime.now();
  final savedContent = content.isEmpty ? '[已上传文件]' : content;
  final userMsg = DsMessage(
    id: 'dsm_${fmtStamp14(now)}_${randomHex(6)}',
    sessionId: sessionID,
    role: 'user',
    content: savedContent,
    createdAt: rfc3339(now),
    attachments: fileIDs.join(','),
  );
  userMsg.dim = dbIsChatModel(model) ? DS_DIM_DB : DS_DIM_DS;
  appendDsMessage(userMsg);

  final aiMsg = DsMessage(
    id: 'dsm_${fmtStamp14(DateTime.now())}_${randomHex(6)}',
    sessionId: sessionID,
    role: 'assistant',
    content: reply,
    createdAt: rfc3339(DateTime.now()),
    reasoning: reasoning,
    usage: usageAcc.snapshot(),
  );
  aiMsg.dim = dbIsChatModel(model) ? DS_DIM_DB : DS_DIM_DS;
  appendDsMessage(aiMsg);

  final sess = getDsSession(sessionID);
  var title = '新对话';
  if (sess != null) {
    title = sess.title;
    if (title.isEmpty || title == '新对话') {
      final runes = content.runes.toList();
      if (runes.isEmpty) {
        title = '[ファイル対話]';
      } else if (runes.length > 18) {
        title = '${String.fromCharCodes(runes.sublist(0, 18))}…';
      } else {
        title = content;
      }
    }
  }
  updateDsSession(sessionID, title, rfc3339(DateTime.now()));

  await dsJSONOk(res, 200, {
    'success': true,
    'userMessage': userMsg.toJson(),
    'aiMessage': aiMsg.toJson(),
    'title': title,
    'level': level,
    'rounds': rounds,
    'maxTokens': maxTokens,
    'charCount': runeLen(reply),
    'model': model,
    'modelRoute': route.toJson(),
    'usage': aiMsg.usage?.toJson(),
  });
}
