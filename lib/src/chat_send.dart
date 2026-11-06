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
import 'ds_crypto.dart';
import 'ds_usage.dart';
import 'files.dart';
import 'globals.dart';
import 'httpsrv.dart';
import 'model_router.dart';
import 'sessions.dart';
import 'session_ref.dart';

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
  ModelRouteDecision? route,
  String apiUrl = DS_API_URL,
  /// 方舟专用附加字段（如 thinking）。DeepSeek 通道保持为 null。
  Map<String, dynamic>? extraBody,
}) async {
  final sse = Sse(req.response);

  final contentBuf = StringBuffer();
  final reasoningBuf = StringBuffer();
  final usageAcc = DsUsageAcc();
  final streamStart = DateTime.now();
  DateTime? firstContentAt;

  // ---------- 工具模式 ----------
  if (enableTools) {
    await sse.send('rounds', {'total': 0});
    await sse.send('tool_mode_start', {'start': true});

    final agentMsgs = <Map<String, dynamic>>[
      {'role': 'system', 'content': DS_TOOL_AGENT_SYSTEM_PROMPT},
      ...apiMessages,
    ];
    var maxIter = DS_TOOL_MAX_ITERATIONS;
    if (rounds > maxIter) maxIter = rounds;
    logp('🔧 ツールモード起動: 最大 $maxIter 回の反復（Agent システムプロンプト注入済み）');

    final toolReasoningBuf = StringBuffer();

    ToolStreamOutcome outcome;
    try {
      outcome = await callDsWithToolsStream(
        apiKey,
        model,
        agentMsgs,
        maxTokens,
        temperature,
        maxIter,
        (s) {
          firstContentAt ??= DateTime.now();
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
          sse.send('reasoning', {'delta': s});
        },
        usageAcc,
        apiUrl: apiUrl,
      );
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
      await sse.send('reasoning', {
        'delta': 'AI はこの質問にツール呼び出しが不要と判断し、本文も返しませんでした。\n',
      });
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
    appendDsMessage(userMsg);

    final aiMsg = DsMessage(
      id: 'dsm_${fmtStamp14(DateTime.now())}_${randomHex(6)}',
      sessionId: sessionID,
      role: 'assistant',
      content: contentBuf.toString(),
      createdAt: rfc3339(DateTime.now()),
      reasoning: outcome.reasoning,
      // 豆包経由では usage を保存しない（方舟の消費量を正確に取得できないため）
      usage: apiUrl == DS_API_URL ? usageAcc.snapshot() : null,
    );
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
        sse.send('reasoning', {'delta': s});
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
    );
  } catch (e) {
    await sse.send('error', {'message': '$e'});
    await sse.done();
    return;
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
  appendDsMessage(userMsg);

  final aiMsg = DsMessage(
    id: 'dsm_${fmtStamp14(DateTime.now())}_${randomHex(6)}',
    sessionId: sessionID,
    role: 'assistant',
    content: contentBuf.toString(),
    createdAt: rfc3339(DateTime.now()),
    reasoning: reasoningBuf.toString(),
    usage: apiUrl == DS_API_URL ? usageAcc.snapshot() : null,
  );
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
  final enableTools = mBool(body, 'enableTools');
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

  if (webSearch && content.isNotEmpty) {
    if (useDoubao) {
      // 豆包通道禁止调用 DeepSeek 的 /v1/tools/search，避免消耗 DeepSeek 用量
      logp('⛔ 豆包モード：DeepSeek の联网検索は呼び出しません（用量保護）');
      userPrompt += '\n\n' + dbLocalized(mediaLang, 'searchBlockedNote');
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
  Map<String, dynamic>? dbExtraBody;
  final dbMediaParts = <Map<String, dynamic>>[];
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
    for (final id in fileCtx.videoFileIds) {
      final meta = getDsFileMeta(id);
      if (meta == null) continue;
      final f = File('$DSFilesBlobDir/${meta.relPath}');
      if (!f.existsSync()) continue;
      final raw = f.readAsBytesSync();
      if (raw.length > 40 * 1024 * 1024) {
        await dsJSONErr(
            res, 400, dbLocalized(mediaLang, 'videoTooLarge', [meta.name]));
        return;
      }
      final mime = meta.mimeType.toLowerCase().startsWith('video/')
          ? meta.mimeType
          : 'video/mp4';
      dbMediaParts.add(dbVideoPart(mime, base64Encode(raw)));
      logp('🎬 動画を豆包の動画理解へ直接送信: ${meta.name} ($mime)');
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

  var history = getDsMessages(sessionID);
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
  if (dbMediaParts.isNotEmpty) {
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
        route: route,
        apiUrl: callUrl,
        extraBody: dbExtraBody);
    return;
  }

  // ============ 工具模式（非流式） ============
  if (useTools) {
    logp('🔧 ツールモードを有効化し、マルチターンの function calling を開始します（最大 $DS_TOOL_MAX_ITERATIONS ラウンド）');
    final usageAcc = DsUsageAcc();
    final agentMsgs = <Map<String, dynamic>>[
      {'role': 'system', 'content': DS_TOOL_AGENT_SYSTEM_PROMPT},
      ...apiMessages,
    ];
    ToolStreamOutcome outcome;
    try {
      outcome = await callDsWithTools(callKey, model, agentMsgs, maxTokens,
          temperature, DS_TOOL_MAX_ITERATIONS, usageAcc, apiUrl: callUrl);
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
      usage: useDoubao ? null : usageAcc.snapshot(),
    );
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
  final usageAcc = DsUsageAcc();
  String reply;
  String reasoning;
  try {
    final r = await callDsMultiRound(callKey, model, apiMessages, maxTokens,
        temperature, rounds, null, usageAcc,
        apiUrl: callUrl, extraBody: dbExtraBody);
    reply = r.content;
    reasoning = r.reasoning;
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
  appendDsMessage(userMsg);

  final aiMsg = DsMessage(
    id: 'dsm_${fmtStamp14(DateTime.now())}_${randomHex(6)}',
    sessionId: sessionID,
    role: 'assistant',
    content: reply,
    createdAt: rfc3339(DateTime.now()),
    reasoning: reasoning,
    usage: useDoubao ? null : usageAcc.snapshot(),
  );
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
