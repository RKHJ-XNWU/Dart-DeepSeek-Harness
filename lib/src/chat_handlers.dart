// ============================================================
// chat_handlers.dart —— 聊天基础接口
//   config / sessions / messages / reasoning / test / image / tts / stt
//   abort-save / continue
// 100% 对齐 Go 版 deepseek-chat.go 对应 handler
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'deepseek_api.dart';
import 'ds_crypto.dart';
import 'ds_usage.dart';
import 'files.dart';
import 'globals.dart';
import 'httpsrv.dart';
import 'sessions.dart';
import 'tools.dart' show runProcess;
import 'tts_edge.dart';

// ------------------------------------------------------------
// /api/ds-chat/config
// ------------------------------------------------------------
Future<void> handleDsChatConfig(HttpRequest req) async {
  final res = req.response;
  switch (req.method) {
    case 'GET':
      final cfg = getDsConfig();
      var masked = '';
      if (cfg.apiKey.length > 8) {
        masked =
            '${cfg.apiKey.substring(0, 4)}••••${cfg.apiKey.substring(cfg.apiKey.length - 4)}';
      } else if (cfg.apiKey.isNotEmpty) {
        masked = '••••••••';
      }
      var imgMasked = '';
      if (cfg.imgKey.length > 8) {
        imgMasked =
            '${cfg.imgKey.substring(0, 4)}••••${cfg.imgKey.substring(cfg.imgKey.length - 4)}';
      } else if (cfg.imgKey.isNotEmpty) {
        imgMasked = '••••••••';
      }
      await dsJSONOk(res, 200, {
        'hasKey': cfg.apiKey.isNotEmpty,
        'maskedKey': masked,
        'model': cfg.model,
        'hasImgKey': cfg.imgKey.isNotEmpty,
        'maskedImgKey': imgMasked,
      });
      return;

    case 'POST':
      Map<String, dynamic> body;
      try {
        body = await readJsonBody(req);
      } catch (_) {
        await dsJSONErr(res, 400, '无效请求体');
        return;
      }
      final old = getDsConfig();
      final nk = trimOr(mStr(body, 'apiKey'), old.apiKey);
      final nm = trimOr(mStr(body, 'model'), old.model);
      final nik = trimOr(mStr(body, 'imgKey'), old.imgKey);
      if (!saveDsConfig(nk, nm, nik)) {
        await dsJSONErr(res, 500, '保存失败');
        return;
      }
      await dsJSONOk(res, 200, {'success': true});
      return;

    default:
      await dsJSONErr(res, 405, 'Method not allowed');
  }
}

// ------------------------------------------------------------
// /api/ds-chat/sessions
// ------------------------------------------------------------
Future<void> handleDsChatSessions(HttpRequest req) async {
  final res = req.response;
  switch (req.method) {
    case 'GET':
      final sessions = getAllDsSessions();
      final etag = '"ds'
          '${sessions.length}-'
          '${sessions.isEmpty ? '0' : sessions.first.updatedAt}"';
      res.headers.set('etag', etag);
      res.headers.set('cache-control', 'no-cache');
      final inm = req.headers.value(HttpHeaders.ifNoneMatchHeader);
      if (inm != null && inm == etag) {
        res.statusCode = 304;
        await res.close();
        return;
      }
      await dsJSONOk(res, 200, {
        'sessions': sessions.map((s) => s.toJson()).toList(),
      });
      return;

    case 'POST':
      Map<String, dynamic> body;
      try {
        body = await readJsonBody(req);
      } catch (_) {
        body = <String, dynamic>{};
      }
      var id = mStr(body, 'id');
      final title = trimOr(mStr(body, 'title'), '新对话');
      if (id.trim().isNotEmpty) {
        final sess = getDsSession(id);
        if (sess == null) {
          await dsJSONErr(res, 404, '会话不存在');
          return;
        }
        if (!updateDsSession(id, title, rfc3339(DateTime.now()))) {
          await dsJSONErr(res, 500, '重命名失败');
          return;
        }
        await dsJSONOk(res, 200, {'success': true, 'id': id, 'title': title});
        return;
      }
      final now = DateTime.now();
      id = 'dsc_${fmtStamp14(now)}_${randomHex(6)}';
      final sess = DsSession(
        id: id,
        title: title,
        createdAt: rfc3339(now),
        updatedAt: rfc3339(now),
      );
      if (!saveDsSession(sess)) {
        await dsJSONErr(res, 500, '创建失败');
        return;
      }
      await dsJSONOk(res, 200, {'success': true, 'session': sess.toJson()});
      return;

    case 'DELETE':
      final id = qp(req, 'id');
      if (id.isEmpty) {
        await dsJSONErr(res, 400, '缺少id');
        return;
      }
      deleteDsSession(id);
      await dsJSONOk(res, 200, {'success': true});
      return;

    default:
      await dsJSONErr(res, 405, 'Method not allowed');
  }
}

Future<void> handleDsChatSessionsBatchDelete(HttpRequest req) async {
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
  final ids = asList(body['ids']).map((e) => '$e').toList();
  final all = mBool(body, 'all');

  if (all) {
    final allAttachments = <String>{};
    for (final f in Directory(dsSessionsDir).listSync()) {
      if (f is! File || !f.path.endsWith('.sts')) continue;
      allAttachments.addAll(collectSessionAttachments(f.path));
    }
    for (final f in Directory(dsSessionsDir).listSync()) {
      if (f is File && f.path.endsWith('.sts')) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    }
    for (final fid in allAttachments) {
      deleteDsFileMeta(fid);
    }
    cleanupOrphanFiles();
    await dsJSONOk(res, 200, {'success': true, 'deleted': -1});
    return;
  }

  if (ids.isEmpty) {
    await dsJSONErr(res, 400, '缺少 ids');
    return;
  }

  final allAttachments = <String>{};
  for (final id in ids) {
    if (id.isEmpty) continue;
    allAttachments.addAll(collectSessionAttachments(dsSessionPath(id)));
  }
  var count = 0;
  for (final id in ids) {
    if (id.isEmpty) continue;
    if (deleteDsSessionRaw(id)) count++;
  }
  final stillUsed = collectAttachmentsInUse();
  for (final fid in allAttachments) {
    if (!stillUsed.contains(fid)) deleteDsFileMeta(fid);
  }
  cleanupOrphanFiles();
  await dsJSONOk(res, 200, {'success': true, 'deleted': count});
}

/// 生成「推理已截断」的消息副本：绝不修改缓存中的原始消息对象，
/// 否则后续把历史发给模型时会拿到被截断的 reasoning。
DsMessage _msgWithReasoningPreview(DsMessage m, String sessionID) {
  final r = truncateReasoning(m.reasoning, DS_REASONING_PREVIEW);
  return DsMessage(
    id: m.id,
    sessionId: sessionID,
    role: m.role,
    content: m.content,
    createdAt: m.createdAt,
    attachments: m.attachments,
    reasoning: r.$1,
    reasoningTruncated: r.$2,
    usage: m.usage,
  );
}

// ------------------------------------------------------------
// /api/ds-chat/messages（尾部优先 + beforeId 分页）
// ------------------------------------------------------------
Future<void> handleDsChatMessages(HttpRequest req) async {
  final res = req.response;
  final sessionID = qp(req, 'sessionId');
  if (sessionID.isEmpty) {
    await dsJSONErr(res, 400, '缺少 sessionId');
    return;
  }
  var limit = DS_MSG_PAGE_SIZE;
  final limitStr = qp(req, 'limit');
  if (limitStr.isNotEmpty) {
    final n = int.tryParse(limitStr);
    if (n != null && n > 0 && n <= 200) limit = n;
  }
  final beforeID = qp(req, 'beforeId');
  final path = dsSessionPath(sessionID);

  if (beforeID.isEmpty) {
    final tail = readDsSessionTailMsgs(path, limit);
    final msgs = tail.messages
        .map((m) => _msgWithReasoningPreview(m, sessionID))
        .toList();
    await dsJSONOk(res, 200, {
      'messages': msgs.map((m) => m.toJson()).toList(),
      'hasMore': tail.hasMore,
      'sessionId': sessionID,
    });
    return;
  }

  final all = getDsMessages(sessionID);
  var idx = -1;
  for (var i = 0; i < all.length; i++) {
    if (all[i].id == beforeID) {
      idx = i;
      break;
    }
  }
  var hasMore = false;
  var page = <DsMessage>[];
  if (idx > 0) {
    var start = 0;
    if (idx > limit) {
      start = idx - limit;
      hasMore = true;
    }
    page = all.sublist(start, idx);
  }
  final pageOut = page
      .map((m) => _msgWithReasoningPreview(m, sessionID))
      .toList();
  await dsJSONOk(res, 200, {
    'messages': pageOut.map((m) => m.toJson()).toList(),
    'hasMore': hasMore,
    'sessionId': sessionID,
  });
}

Future<void> handleDsChatReasoning(HttpRequest req) async {
  final res = req.response;
  final sessionID = qp(req, 'sessionId');
  final id = qp(req, 'id');
  if (sessionID.isEmpty || id.isEmpty) {
    await dsJSONErr(res, 400, '缺少 sessionId 或 id');
    return;
  }
  for (final m in getDsMessages(sessionID)) {
    if (m.id == id) {
      await dsJSONOk(res, 200, {'reasoning': m.reasoning});
      return;
    }
  }
  await dsJSONOk(res, 200, {'reasoning': ''});
}

// ------------------------------------------------------------
// /api/ds-chat/test
// ------------------------------------------------------------
Future<void> handleDsChatTest(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'POST') {
    await dsJSONErr(res, 405, 'Method not allowed');
    return;
  }
  Map<String, dynamic> body;
  try {
    body = await readJsonBody(req);
  } catch (_) {
    body = <String, dynamic>{};
  }
  var apiKey = mStr(body, 'apiKey').trim();
  final cfg = getDsConfig();
  if (apiKey.isEmpty) apiKey = cfg.apiKey;
  if (apiKey.isEmpty) {
    await dsJSONErr(res, 400, '缺少 API Key');
    return;
  }
  var model = mStr(body, 'model').trim();
  if (model.isEmpty) model = cfg.model;
  if (model.isEmpty) model = DS_DEFAULT_MODEL;
  try {
    final r = await callDsChatAPI(apiKey, model, [
      {'role': 'user', 'content': '你好'}
    ], 8192, 1.0, null);
    await dsJSONOk(
        res, 200, {'success': true, 'reply': r.content, 'model': model});
  } catch (e) {
    await dsJSONErr(res, 500, '$e');
  }
}

// ------------------------------------------------------------
// /api/ds-chat/generate-image（pollinations）
// ------------------------------------------------------------
String urlEncodeComponent(String s) {
  final sb = StringBuffer();
  for (final b in utf8.encode(s)) {
    final c = String.fromCharCode(b);
    if (RegExp(r'[A-Za-z0-9\-_.~]').hasMatch(c)) {
      sb.write(c);
    } else {
      sb.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return sb.toString();
}

Future<void> handleDsGenerateImage(HttpRequest req) async {
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
  final prompt = mStr(body, 'prompt').trim();
  if (prompt.isEmpty) {
    await dsJSONErr(res, 400, '提示词不能为空');
    return;
  }
  var width = intArgDefault(body, 'width', 1024);
  var height = intArgDefault(body, 'height', 1024);
  if (width <= 0) width = 1024;
  if (height <= 0) height = 1024;

  final seed = DateTime.now().microsecondsSinceEpoch % 999999;
  final imgURL = 'https://image.pollinations.ai/prompt/${urlEncodeComponent(prompt)}'
      '?width=$width&height=$height&nologo=true&seed=$seed';

  List<int> imgData;
  try {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    final r = await client.getUrl(Uri.parse(imgURL));
    final resp = await r.close();
    if (resp.statusCode != 200) {
      await dsJSONErr(res, 500, '生成服务返回 ${resp.statusCode}');
      return;
    }
    imgData = await resp.fold<List<int>>([], (a, b) => a..addAll(b));
  } catch (e) {
    await dsJSONErr(res, 500, '图片生成失败: $e');
    return;
  }

  final filename = 'gen_${fmtStamp14(DateTime.now())}_${randomHex(6)}.jpg';
  final relPath = 'generated/$filename';
  final absPath = '$DSFilesBlobDir/$relPath';
  ensureDir('$DSFilesBlobDir/generated');
  try {
    File(absPath).writeAsBytesSync(imgData);
  } catch (_) {
    await dsJSONErr(res, 500, '保存失败');
    return;
  }

  final meta = DsFileMeta(
    id: 'f_${fmtStamp14(DateTime.now())}_${randomHex(6)}',
    name: filename,
    size: imgData.length,
    mimeType: 'image/jpeg',
    category: 'image',
    createdAt: rfc3339(DateTime.now()),
    relPath: relPath,
    source: 'ai_generated',
    prompt: prompt,
  );
  saveDsFileMeta(meta);

  await dsJSONOk(res, 200, {
    'success': true,
    'fileId': meta.id,
    'filename': filename,
    'url': '/api/ds-files/download?id=${meta.id}',
  });
}

// ------------------------------------------------------------
// /api/ds-chat/tts（Edge TTS 流式 mp3）
// ------------------------------------------------------------
Future<void> handleDsChatTTS(HttpRequest req) async {
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
  final text = mStr(body, 'text').trim();
  if (text.isEmpty) {
    await dsJSONErr(res, 400, '文本不能为空');
    return;
  }
  var voice = mStr(body, 'voice');
  if (voice.isEmpty) voice = 'zh-CN-XiaoxiaoNeural';

  final chunks = splitTextForTTS(text, DS_TTS_CHUNK_RUNES, DS_TTS_CHUNK_HARD_MAX);
  if (chunks.isEmpty) {
    await dsJSONErr(res, 400, '文本为空');
    return;
  }
  final cleaned = <String>[];
  for (final c in chunks) {
    final cc = cleanTTSText(c);
    if (cc.trim().isNotEmpty) cleaned.add(cc);
  }
  if (cleaned.isEmpty) {
    await dsJSONErr(res, 400, '文本为空（清理后）');
    return;
  }

  final totalRunes = runeLen(text);
  logp('🔊 TTS 请求：$totalRunes 字，分 ${cleaned.length} 块，语音=$voice');

  res.statusCode = 200;
  res.headers.contentType = ContentType('audio', 'mpeg');
  res.headers.set('Cache-Control', 'no-cache');
  res.bufferOutput = false;

  var okChunks = 0;
  for (var i = 0; i < cleaned.length; i++) {
    logp('🎙️ TTS 第 ${i + 1}/${cleaned.length} 块（${runeLen(cleaned[i])} 字）');
    final ok = await synthesizeEdgeTts(cleaned[i], voice, (audio) async {
      try {
        res.add(audio);
        await res.flush();
      } catch (_) {}
    });
    if (ok) {
      okChunks++;
    } else {
      logp('❌ TTS 第 ${i + 1} 块合成失败');
    }
  }
  logp('✅ TTS 完成：$okChunks/${cleaned.length} 块成功');
  try {
    await res.close();
  } catch (_) {}
}

// ------------------------------------------------------------
// /api/ds-chat/stt（本地 ffmpeg + whisper.cpp）
// ------------------------------------------------------------
String cleanWhisperText(String s) {
  var out = s.replaceAll(RegExp(r'\[[^\]]*\]|\([^)]*\)|（[^）]*）'), '');
  final clean = <String>[];
  for (var ln in out.split('\n')) {
    ln = ln.trim();
    if (ln.isEmpty) continue;
    if (ln.startsWith('output_txt:') ||
        ln.startsWith('output_') ||
        ln.startsWith('whisper_')) {
      continue;
    }
    clean.add(ln);
  }
  return clean.join(' ').trim();
}

Future<void> handleDsChatSTT(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'POST') {
    await dsJSONErr(res, 405, 'Method not allowed');
    return;
  }
  List<int> audioData;
  try {
    audioData = await readBodyBytes(req, limit: 20 * 1024 * 1024);
  } catch (_) {
    await dsJSONErr(res, 400, '读取音频失败');
    return;
  }
  // multipart 包装：提取二进制主体（保持 Go 的宽松行为）
  if (audioData.length < 500) {
    await dsJSONErr(res, 400, '音频太短');
    return;
  }

  final tmpDir = Directory.systemTemp.path;
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final inFile = '$tmpDir/stt_in_$stamp.bin';
  final wavFile = '$tmpDir/stt_$stamp.wav';
  try {
    File(inFile).writeAsBytesSync(audioData);
    final ff = await runProcess(
        'ffmpeg', ['-y', '-loglevel', 'error', '-i', inFile, '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le', wavFile],
        timeout: const Duration(seconds: 120));
    if (ff.code != 0) {
      logp('❌ STT 音频转换失败: ${ff.out}');
      await dsJSONErr(res, 500, '音频转换失败');
      return;
    }
    final modelPath = '$BASE_DIR/models/ggml-base-q5_1.bin';
    final mainBin = '$BASE_DIR/whisper.cpp/build/bin/whisper-cli';
    final wh = await runProcess(
        mainBin, ['-m', modelPath, '-f', wavFile, '-l', 'zh', '-nt', '-np'],
        timeout: const Duration(seconds: 300));
    if (wh.code != 0) {
      logp('❌ STT 识别失败: ${wh.out}');
      await dsJSONErr(res, 500, '语音识别失败');
      return;
    }
    final text = cleanWhisperText(wh.out);
    logp('🎤 STT 识别结果: $text');
    await dsJSONOk(res, 200, {'text': text});
  } finally {
    try {
      final f = File(inFile);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    try {
      final f = File(wavFile);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }
}

// ------------------------------------------------------------
// /api/ds-chat/abort-save
// ------------------------------------------------------------
Future<void> handleDsChatAbortSave(HttpRequest req) async {
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
  final content = mStr(body, 'content');
  final fileIDs = asList(body['fileIds']).map((e) => '$e').toList();
  final aiContent = mStr(body, 'aiContent');
  final reasoning = mStr(body, 'reasoning');
  final messageID = mStr(body, 'messageId');

  if (sessionID.trim().isEmpty) {
    await dsJSONErr(res, 400, '缺少会话ID');
    return;
  }
  if (!File(dsSessionPath(sessionID)).existsSync()) {
    await dsJSONErr(res, 404, '会话不存在');
    return;
  }

  DsMessage? userMsg;
  DsMessage? aiMsg;

  if (messageID.trim().isNotEmpty) {
    if (aiContent.trim().isEmpty) {
      await dsJSONErr(res, 400, '内容为空');
      return;
    }
    final upd = updateDsMessageContent(
        sessionID, messageID, aiContent, reasoning, null);
    if (upd == null) {
      await dsJSONErr(res, 500, '未找到要更新的消息');
      return;
    }
    aiMsg = upd;
  } else {
    if (content.trim().isEmpty && fileIDs.isEmpty) {
      await dsJSONErr(res, 400, '内容不能为空');
      return;
    }
    final now = DateTime.now();
    final savedContent = content.isEmpty ? '[已上传文件]' : content;
    final u = DsMessage(
      id: 'dsm_${fmtStamp14(now)}_${randomHex(6)}',
      sessionId: sessionID,
      role: 'user',
      content: savedContent,
      createdAt: rfc3339(now),
      attachments: fileIDs.join(','),
    );
    if (!appendDsMessage(u)) {
      await dsJSONErr(res, 500, '保存用户消息失败');
      return;
    }
    userMsg = u;

    if (aiContent.trim().isNotEmpty) {
      final a = DsMessage(
        id: 'dsm_${fmtStamp14(DateTime.now())}_${randomHex(6)}',
        sessionId: sessionID,
        role: 'assistant',
        content: aiContent,
        createdAt: rfc3339(DateTime.now()),
        reasoning: reasoning,
      );
      if (!appendDsMessage(a)) {
        await dsJSONErr(res, 500, '保存回答失败');
        return;
      }
      aiMsg = a;
    }

    final sess = getDsSession(sessionID);
    if (sess != null) {
      var title = sess.title;
      if (title.isEmpty || title == '新对话') {
        final runes = content.runes.toList();
        if (runes.length > 18) {
          title = '${String.fromCharCodes(runes.sublist(0, 18))}…';
        } else if (runes.isNotEmpty) {
          title = content;
        }
      }
      if (title.trim().isNotEmpty) {
        updateDsSession(sessionID, title, rfc3339(DateTime.now()));
      }
    }
  }

  logp('⏹ 已停止：session=$sessionID ai=${runeLen(aiContent)} 字（messageId=$messageID）');
  await dsJSONOk(res, 200, {
    'stopped': true,
    'userMessage': userMsg?.toJson(),
    'aiMessage': aiMsg?.toJson(),
  });
}

// ------------------------------------------------------------
// /api/ds-chat/continue（续写）
// ------------------------------------------------------------
Future<void> handleDsChatContinue(HttpRequest req) async {
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
  final messageID = mStr(body, 'messageId');
  var base = mStr(body, 'baseContent');
  final deepThink = mBool(body, 'deepThink');
  var level = intArgDefault(body, 'reasoningLevel', 1);

  if (sessionID.trim().isEmpty) {
    await dsJSONErr(res, 400, '缺少会话ID');
    return;
  }
  final cfg = getDsConfig();
  if (cfg.apiKey.isEmpty) {
    await dsJSONErr(res, 400, '请先配置 DeepSeek API Key');
    return;
  }
  final model = trimOr(mStr(body, 'model'), cfg.model.isEmpty ? DS_DEFAULT_MODEL : cfg.model);

  final history = getDsMessages(sessionID);
  var oldReasoning = '';
  if (messageID.isNotEmpty) {
    for (final m in history) {
      if (m.id == messageID) {
        if (runeLen(m.content) >= runeLen(base)) base = m.content;
        oldReasoning = m.reasoning;
        break;
      }
    }
  }
  if (base.trim().isEmpty) {
    await dsJSONErr(res, 400, '没有可继续生成的内容');
    return;
  }
  if (level < 1) level = 1;
  if (level > 50) level = 50;
  final params = levelToParams(level);

  final sysParts = <String>[
    '你正在续写同一段回答的剩余部分：紧接上一条 assistant 消息的最后一个字继续输出。禁止复述已有内容，禁止重新开头，禁止输出任何解释、标题或总结语。'
  ];
  if (deepThink) sysParts.add('你可以进行深度的、多步骤的推理，请充分展示你的思考过程。');

  final apiMessages = <Map<String, dynamic>>[
    {'role': 'system', 'content': sysParts.join('\n')},
  ];
  for (final m in history) {
    if (messageID.isNotEmpty && m.id == messageID) break;
    if (m.role == 'user' || m.role == 'assistant' || m.role == 'system') {
      apiMessages.add({'role': m.role, 'content': m.content});
    }
  }
  apiMessages.add({'role': 'assistant', 'content': base});
  apiMessages.add({
    'role': 'user',
    'content': '（续写指令）请从中断处接着往下写，紧接上文最后一个字，不要重复，不要重述开头。',
  });

  final sse = Sse(res);
  logp('▶️ 继续生成：session=$sessionID 原文=${runeLen(base)} 字 model=$model');

  final addBuf = StringBuffer();
  final reasoningBuf = StringBuffer();
  final usageAcc = DsUsageAcc();
  try {
    await callDsMultiRoundStream(
      cfg.apiKey,
      model,
      apiMessages,
      params.maxTokens,
      params.temperature,
      1,
      (round, total, stage) {},
      (s) {
        reasoningBuf.write(s);
        sse.send('reasoning', {'delta': s});
      },
      (s) {
        addBuf.write(s);
        sse.send('content', {'delta': s});
      },
      usageAcc,
    );
  } catch (e) {
    logp('⚠️ 继续生成中断: $e');
    await sse.send('error', {'message': '$e'});
    await sse.done();
    return;
  }

  final merged = mergeContinuation(base, addBuf.toString());
  var finalReasoning = oldReasoning;
  final rsn = reasoningBuf.toString();
  if (rsn.isNotEmpty) {
    if (finalReasoning.trim().isEmpty) {
      finalReasoning = rsn;
    } else {
      finalReasoning = '${finalReasoning.replaceAll(RegExp(r'\n+$'), '')}\n$rsn';
    }
  }

  DsMessage? aiMsg;
  if (messageID.isNotEmpty) {
    final upd = updateDsMessageContent(
        sessionID, messageID, merged, finalReasoning, usageAcc.snapshot());
    if (upd != null) {
      aiMsg = upd;
      final sess = getDsSession(sessionID);
      if (sess != null && sess.title.trim().isNotEmpty) {
        updateDsSession(sessionID, sess.title, rfc3339(DateTime.now()));
      }
    }
  } else {
    final a = DsMessage(
      id: 'dsm_${fmtStamp14(DateTime.now())}_${randomHex(6)}',
      sessionId: sessionID,
      role: 'assistant',
      content: merged,
      createdAt: rfc3339(DateTime.now()),
      reasoning: finalReasoning,
      usage: usageAcc.snapshot(),
    );
    appendDsMessage(a);
    aiMsg = a;
  }

  logp('✅ 继续生成完成：新增 ${runeLen(addBuf.toString())} 字，合并后 ${runeLen(merged)} 字');
  await sse.send('done', {
    'aiMessage': aiMsg?.toJson(),
    'content': merged,
    'charCount': runeLen(merged),
    'model': model,
    'continued': true,
    'usage': aiMsg?.usage?.toJson(),
  });
  await sse.done();
}
