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
        await dsJSONErr(res, 400, '無効なリクエストボディです');
        return;
      }
      final old = getDsConfig();
      final nk = trimOr(mStr(body, 'apiKey'), old.apiKey);
      final nm = trimOr(mStr(body, 'model'), old.model);
      final nik = trimOr(mStr(body, 'imgKey'), old.imgKey);
      if (!saveDsConfig(nk, nm, nik)) {
        await dsJSONErr(res, 500, '保存に失敗しました');
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
      final title = trimOr(mStr(body, 'title'), '新しい会話');
      if (id.trim().isNotEmpty) {
        final sess = getDsSession(id);
        if (sess == null) {
          await dsJSONErr(res, 404, 'セッションが存在しません');
          return;
        }
        if (!updateDsSession(id, title, rfc3339(DateTime.now()))) {
          await dsJSONErr(res, 500, '名前の変更に失敗しました');
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
        await dsJSONErr(res, 500, '作成に失敗しました');
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
    await dsJSONErr(res, 400, '無効なリクエストボディです');
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
      {'role': 'user', 'content': 'こんにちは'}
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
    await dsJSONErr(res, 400, '無効なリクエストボディです');
    return;
  }
  final prompt = mStr(body, 'prompt').trim();
  if (prompt.isEmpty) {
    await dsJSONErr(res, 400, 'プロンプトは必須です');
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
      await dsJSONErr(res, 500, '生成サービスが ${resp.statusCode} を返しました');
      return;
    }
    imgData = await resp.fold<List<int>>([], (a, b) => a..addAll(b));
  } catch (e) {
    await dsJSONErr(res, 500, '画像生成に失敗しました: $e');
    return;
  }

  final filename = 'gen_${fmtStamp14(DateTime.now())}_${randomHex(6)}.jpg';
  final relPath = 'generated/$filename';
  final absPath = '$DSFilesBlobDir/$relPath';
  ensureDir('$DSFilesBlobDir/generated');
  try {
    File(absPath).writeAsBytesSync(imgData);
  } catch (_) {
    await dsJSONErr(res, 500, '保存に失敗しました');
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
    await dsJSONErr(res, 400, '無効なリクエストボディです');
    return;
  }
  final text = mStr(body, 'text').trim();
  if (text.isEmpty) {
    await dsJSONErr(res, 400, 'テキストは必須です');
    return;
  }
  var voice = mStr(body, 'voice');
  // 'fr' / 'fr-FR' / 'ru-RU' のいずれでも受けられるよう先頭 2 文字に正規化する
  final ttsLangRaw = mStr(body, 'lang').toLowerCase();
  final ttsLang = ttsLangRaw.length >= 2 ? ttsLangRaw.substring(0, 2) : ttsLangRaw;
  if (voice.isEmpty) {
    const defVoice = <String, String>{
      'ja': 'ja-JP-NanamiNeural',
      'en': 'en-US-AriaNeural',
      'fr': 'fr-FR-DeniseNeural',
      'ru': 'ru-RU-SvetlanaNeural',
      'ko': 'ko-KR-SunHiNeural',
      'zh': 'zh-CN-XiaoxiaoNeural',
    };
    voice = defVoice[ttsLang] ?? defVoice['zh']!;
  }
  // prosody 白名单校验（防止 SSML 注入 / 非法值）
  String safeProsody(String raw, String unit, String def) {
    final v = raw.trim();
    if (!v.endsWith(unit)) return def;
    final numPart = v.substring(0, v.length - unit.length);
    if (!RegExp(r'^[+-]\d{1,3}$').hasMatch(numPart)) return def;
    return v;
  }

  final pitch = safeProsody(mStr(body, 'pitch'), 'Hz', '+0Hz');
  final rate = safeProsody(mStr(body, 'rate'), '%', '+0%');

  final chunks = splitTextForTTS(text, DS_TTS_CHUNK_RUNES, DS_TTS_CHUNK_HARD_MAX);
  if (chunks.isEmpty) {
    await dsJSONErr(res, 400, 'テキストが空です');
    return;
  }
  final cleaned = <String>[];
  for (final c in chunks) {
    final cc = cleanTTSText(c, ttsLang);
    if (cc.trim().isNotEmpty) cleaned.add(cc);
  }
  if (cleaned.isEmpty) {
    await dsJSONErr(res, 400, 'テキストが空です（クリーニング後）');
    return;
  }

  final totalRunes = runeLen(text);
  logp('🔊 TTS リクエスト: $totalRunes 文字、${cleaned.length} ブロック、音声=$voice pitch=$pitch rate=$rate');

  res.statusCode = 200;
  res.headers.contentType = ContentType('audio', 'mpeg');
  res.headers.set('Cache-Control', 'no-cache');
  res.bufferOutput = false;

  var okChunks = 0;
  for (var i = 0; i < cleaned.length; i++) {
    logp('🎙️ TTS ${i + 1}/${cleaned.length} ブロック目（${runeLen(cleaned[i])} 文字）');
    final ok = await synthesizeEdgeTts(cleaned[i], voice, (audio) async {
      try {
        res.add(audio);
        await res.flush();
      } catch (_) {}
    }, pitch: pitch, rate: rate);
    if (ok) {
      okChunks++;
    } else {
      logp('❌ TTS ${i + 1} ブロック目の合成に失敗しました');
    }
  }
  logp('✅ TTS 完了: $okChunks/${cleaned.length} ブロック成功');
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
    await dsJSONErr(res, 400, '音声の読み込みに失敗しました');
    return;
  }
  // multipart 包装：提取二进制主体（保持 Go 的宽松行为）
  if (audioData.length < 500) {
    await dsJSONErr(res, 400, '音声が短すぎます');
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
      logp('❌ STT 音声変換に失敗しました: ${ff.out}');
      await dsJSONErr(res, 500, '音声変換に失敗しました');
      return;
    }
    final modelPath = '$BASE_DIR/models/ggml-base-q5_1.bin';
    final mainBin = '$BASE_DIR/whisper.cpp/build/bin/whisper-cli';
    final wh = await runProcess(
        mainBin, ['-m', modelPath, '-f', wavFile, '-l', 'zh', '-nt', '-np'],
        timeout: const Duration(seconds: 300));
    if (wh.code != 0) {
      logp('❌ STT 認識に失敗しました: ${wh.out}');
      await dsJSONErr(res, 500, '音声認識に失敗しました');
      return;
    }
    final text = cleanWhisperText(wh.out);
    logp('🎤 STT 認識結果: $text');
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
    await dsJSONErr(res, 400, '無効なリクエストボディです');
    return;
  }
  final sessionID = mStr(body, 'sessionId');
  final content = mStr(body, 'content');
  final fileIDs = asList(body['fileIds']).map((e) => '$e').toList();
  final aiContent = mStr(body, 'aiContent');
  final reasoning = mStr(body, 'reasoning');
  final messageID = mStr(body, 'messageId');

  if (sessionID.trim().isEmpty) {
    await dsJSONErr(res, 400, 'セッション ID がありません');
    return;
  }
  if (!File(dsSessionPath(sessionID)).existsSync()) {
    await dsJSONErr(res, 404, 'セッションが存在しません');
    return;
  }

  DsMessage? userMsg;
  DsMessage? aiMsg;

  if (messageID.trim().isNotEmpty) {
    if (aiContent.trim().isEmpty) {
      await dsJSONErr(res, 400, '内容が空です');
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
      await dsJSONErr(res, 400, '内容は必須です');
      return;
    }
    final now = DateTime.now();
    final savedContent = content.isEmpty ? '[アップロード済みファイル]' : content;
    final u = DsMessage(
      id: 'dsm_${fmtStamp14(now)}_${randomHex(6)}',
      sessionId: sessionID,
      role: 'user',
      content: savedContent,
      createdAt: rfc3339(now),
      attachments: fileIDs.join(','),
    );
    if (!appendDsMessage(u)) {
      await dsJSONErr(res, 500, 'ユーザーメッセージの保存に失敗しました');
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
        await dsJSONErr(res, 500, '回答の保存に失敗しました');
        return;
      }
      aiMsg = a;
    }

    final sess = getDsSession(sessionID);
    if (sess != null) {
      var title = sess.title;
      if (title.isEmpty || title == '新しい会話') {
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
    await dsJSONErr(res, 400, '無効なリクエストボディです');
    return;
  }
  final sessionID = mStr(body, 'sessionId');
  final messageID = mStr(body, 'messageId');
  var base = mStr(body, 'baseContent');
  final deepThink = mBool(body, 'deepThink');
  var level = intArgDefault(body, 'reasoningLevel', 1);

  if (sessionID.trim().isEmpty) {
    await dsJSONErr(res, 400, 'セッション ID がありません');
    return;
  }
  final cfg = getDsConfig();
  if (cfg.apiKey.isEmpty) {
    await dsJSONErr(res, 400, '先に DeepSeek API Key を設定してください');
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
    await dsJSONErr(res, 400, '継続生成できる内容がありません');
    return;
  }
  if (level < 1) level = 1;
  if (level > 50) level = 50;
  final params = levelToParams(level);

  // i18n：継続生成でも UI 言語に一致した言語固定プロンプトを注入
  final uiLang = dsRequestLang(req, body);
  final sysParts = <String>[
    dsLangSystemPrompt(uiLang),
    'あなたは同じ回答の残りを続けて書いています。直前の assistant メッセージの最後の文字に続けて出力してください。既出の内容の繰り返し、書き直し、説明・見出し・まとめの出力は禁止です。'
  ];
  if (deepThink) sysParts.add('深い多段階の推論が可能です。思考プロセスを十分に示してください。');

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
    'content': '（継続指示）中断箇所から続けて書いてください。直前の最後の文字に続け、繰り返しや冒頭の言い直しはしないこと。',
  });

  final sse = Sse(res);
  logp('▶️ 継続生成: session=$sessionID 元テキスト=${runeLen(base)} 文字 model=$model');

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
    logp('⚠️ 継続生成が中断されました: $e');
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

  logp('✅ 継続生成完了: 追加 ${runeLen(addBuf.toString())} 文字、結合後 ${runeLen(merged)} 文字');
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

// ------------------------------------------------------------
// /api/ds-chat/translate（AI 返信を簡体字中国語へ翻訳／履歴には保存しない）
// ------------------------------------------------------------
/// 翻訳結果の Markdown を壊さないための後処理。
/// - モデルが付けた「訳文：」等のラベルを除去
/// - 出力全体を包む ```lang ... ``` を剥がす（本文ではないため）
/// - コードフェンスが奇数個なら閉じる
/// - CRLF 統一・ゼロ幅文字除去・行末空白除去・空行圧縮
String dsSanitizeTranslatedMarkdown(String raw) {
  var s = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  s = s.replaceAll('\u200B', '').replaceAll('\uFEFF', '');
  s = s.trim();

  // 先頭ラベル（「翻訳：」「译文：」「訳文：」…）を除去
  final label = RegExp(
      r'^(?:翻訳|翻譯|訳文|译文|譯文|中文翻译|中文翻譯|翻訳結果|译文如下)\s*[:：]\s*');
  s = s.replaceFirst(label, '').trim();

  // 出力全体が 1 個のコードフェンスで包まれている場合のみ剥がす
  final wrapped = RegExp(r'^```[a-zA-Z0-9_+\-]*[ \t]*\n([\s\S]*?)\n?```$');
  final m = wrapped.firstMatch(s);
  if (m != null) {
    final inner = (m.group(1) ?? '').trim();
    if (inner.isNotEmpty && !inner.contains('```')) {
      // 中身が Markdown 構造を含むなら「包み直された本文」と判断して剥がす
      final mdLike = RegExp(
              r'(^#{1,6}\s)|(^\s*[-*+]\s)|(^\s*\d+\.\s)|(^\s*\|)|(^>)',
              multiLine: true)
          .hasMatch(inner);
      if (mdLike) s = inner;
    }
  }

  // コードフェンスが奇数個なら閉じる（レンダラの閉じ忘れ対策）
  final fences = RegExp(r'```').allMatches(s).length;
  if (fences.isOdd) s = '$s\n```';

  // 行末空白を除去し、3 連以上の空行を 2 連へ圧縮
  s = s
      .split('\n')
      .map((l) => l.replaceAll(RegExp(r'[ \t]+$'), ''))
      .join('\n');
  s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return s.trim();
}

Future<void> handleDsChatTranslate(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'POST') {
    await dsJSONErr(res, 405, 'Method not allowed');
    return;
  }
  Map<String, dynamic> body;
  try {
    body = await readJsonBody(req);
  } catch (_) {
    await dsJSONErr(res, 400, '無効なリクエストボディです');
    return;
  }
  final text = mStr(body, 'text');
  final target = trimOr(mStr(body, 'target'), '簡体字中国語（简体中文）');
  if (text.trim().isEmpty) {
    await dsJSONErr(res, 400, '翻訳するテキストが空です');
    return;
  }
  final cfg = getDsConfig();
  if (cfg.apiKey.isEmpty) {
    await dsJSONErr(res, 400, '先に DeepSeek API Key を設定してください');
    return;
  }
  var model = mStr(body, 'model').trim();
  if (model.isEmpty) model = cfg.model;
  if (model.isEmpty) model = DS_DEFAULT_MODEL;

  // ★ Markdown を 1 文字も壊さないための厳格プロンプト
  const systemPrompt = 'あなたは Markdown に精通した優秀な翻訳者です。入力テキストを指定された言語へ翻訳します。\n'
      '【厳守事項】\n'
      '1. 出力は翻訳後の本文のみ。前置き・解説・注釈・「訳文：」等のラベル・原文の繰り返しは一切禁止。\n'
      '2. Markdown 記法を 1 文字も崩さない：見出しの #、箇条書きの - / * / +、番号付きリストの 1.、'
      '引用の >、表の | と区切り行 |---|、強調の ** / * / ~~、リンク [text](url) はすべて保持する。\n'
      '3. 表は列数・行数を原文と完全に同一に保つ。区切り行（|---|）は翻訳せずそのまま維持する。'
      'セル内の改行やパイプの追加・削除も禁止。\n'
      '4. 段落間の空行を維持し、複数のブロックを 1 行に連結しない。リスト項目を段落に潰さない。\n'
      '5. 入れ子リストのインデント（半角スペース 2 個単位）を維持する。\n'
      '6. コードブロック・インラインコード・コマンド・URL・ファイルパス・API 名・パッケージ名・'
      '変数名・数式（\$...\$ / \$\$...\$\$）は翻訳せず原文のまま残す。\n'
      '7. 出力全体を ``` で囲まない（コードフェンスを付けない）。HTML タグを追加しない。\n'
      '8. 原文が Markdown でない平文なら、平文のまま翻訳する。';

  final messages = <Map<String, dynamic>>[
    {'role': 'system', 'content': systemPrompt},
    {
      'role': 'user',
      'content': '以下の内容を$targetに翻訳してください。'
          'Markdown 記法と行構造・空行・インデントは原文のまま保持し、翻訳後の本文だけを返してください。\n\n$text'
    },
  ];

  // ★ 実際の usage を集計（料金表示用・永続化はしない）
  final usageAcc = DsUsageAcc();
  try {
    String out = '';
    var streamed = false;
    try {
      final r = await callDsChatAPI(cfg.apiKey, model, messages, 300000, 0.2, usageAcc);
      out = r.content;
    } catch (e1) {
      // 非流式呼び出しが失敗した場合はストリーミングへ自動フォールバック
      logp('⚠️ 翻訳（非流式）失敗、ストリーミングで再試行: $e1');
      final buf = StringBuffer();
      await callDsChatAPIStream(
        cfg.apiKey,
        model,
        messages,
        300000,
        0.2,
        null,
        (s) => buf.write(s),
        usageAcc,
      );
      out = buf.toString();
      streamed = true;
    }
    final clean = dsSanitizeTranslatedMarkdown(out);
    if (clean.isEmpty) {
      await dsJSONErr(res, 502, '翻訳結果が空でした');
      return;
    }
    // 壊れ検知：構造カウントがずれたらログに残す（表示側は原文を壊さない）
    try {
      int cnt(String s, String pat) =>
          RegExp(pat, multiLine: true).allMatches(s).length;
      final srcH = cnt(text, r'^#{1,6}\s');
      final dstH = cnt(clean, r'^#{1,6}\s');
      final srcF = cnt(text, r'```');
      final dstF = cnt(clean, r'```');
      final srcT = cnt(text, r'^\s*\|');
      final dstT = cnt(clean, r'^\s*\|');
      if (srcH != dstH || srcF != dstF || srcT != dstT) {
        logp('⚠️ 翻訳後の Markdown 構造差: 見出し $srcH→$dstH / フェンス $srcF→$dstF / 表行 $srcT→$dstT');
      }
    } catch (_) {}
    final usage = usageAcc.snapshot();
    logp('🌐 翻訳完了: ${runeLen(text)} → ${runeLen(clean)} 文字 (model=$model, stream=$streamed)');
    await dsJSONOk(res, 200, {
      'translation': clean,
      'model': model,
      'target': target,
      'streamed': streamed,
      'usage': usage?.toJson(),
    });
  } catch (e) {
    logp('❌ 翻訳失敗: $e');
    await dsJSONErr(res, 502, '翻訳に失敗しました：$e');
  }
}
