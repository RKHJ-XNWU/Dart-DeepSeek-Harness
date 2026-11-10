/* dsc-ja-fix.js —— 多语言残留修正（SKIP 区域的固定 UI 短语）
 *
 * 【为什么需要这一层】
 *   i18n.js 的 SKIP_SEL 明确排除了 .dsc-think-body（AI 思考）、
 *   .dsc-msg-bubble（AI 正文）、.dsc-msg-translation（翻译结果）等区域，
 *   这些地方由 Dart 后端或前端动态生成，DOM 自动翻译永远覆盖不到。
 *   其中「AI 正文」本来就不该翻译（内容是 AI 输出的自然语言），
 *   但「系统 UI 文案」（思考面板标题、按钮标签、用量提示、翻译块标签等）
 *   必须跟随 UI 语言，否则中文界面里会残留日语。
 *
 * 【这一层的正确职责边界】
 *   ✅ 翻译：固定 UI 文案（按钮、标题、用量单位、翻译块标签、引用卡片头）
 *   ❌ 绝不翻译：AI 生成的正文、用户输入、代码块、外部网页标题
 *
 * 【为什么不能用 i18n.js 的 SKIP_SEL 反过来处理】
 *   SKIP_SEL 里的 .dsc-msg-bubble 同时承载 AI 正文与工具结果卡片，
 *   CSS 无法细分到「只翻工具卡片不翻正文」，只能在渲染后用 JS 定点修复。
 *
 * 【本次修复（2026-11）】
 *   1) 原 PHRASES 表（6 语言）声明了但 fixText 从不引用 —— 典型「AI 删代码删了一半」。
 *      现在 fixText 先走 I18N.tExact，失败再走 PHRASES[lang] 整句匹配。
 *   2) TARGETS 收窄：移除了 .dsc-msg-bubble / .dsc-think-body，
 *      避免误伤 AI 正文与思考内容。
 *   3) curLang() 缓存，避免 MutationObserver 每帧调用产生额外开销。
 *   4) PHRASES 补全 6 语言，不再只有中文。
 */
;(function () {
  if (window.__dscJaFix) return;
  window.__dscJaFix = true;

  // ============ 6 语言兜底短语（仅当 I18N.tExact 未命中时使用） ============
  // 格式：{ lang: [[原文, 译文], ...] }
  // 原则：只收录「系统 UI 固定文案」，绝不收录 AI 可能输出的自然语言短句
  //      （如「こんにちは」这种，因为 AI 正文里出现时不能翻）。
  var PHRASES = {
    zh: [
      ['第 # ラウンドの自己内省中...', '正在第 # 轮自我反思…'],
      ['第 # ラウンドの自己内省中…', '正在第 # 轮自我反思…'],
      ['【第 # ラウンドの内省】', '【第 # 轮反思】'],
      ['第 # ラウンドの内省に失敗しました', '第 # 轮反思失败'],
      ['。前回の結果を使用します', '。将沿用上一轮结果'],
      ['# 回目の深い見直し', '第 # 次深度复审'],
      ['暗号文の長さが不足しています', '密文长度不足'],
      ['GCM タグの検証に失敗しました', 'GCM 标签校验失败'],
      ['アーカイブ作成に失敗しました', '归档创建失败'],
      ['一時ファイルを開けませんでした', '无法打开临时文件'],
      ['ファイルが大きすぎるか、解析に失敗しました', '文件过大或解析失败'],
      ['バックアップファイルをアップロードしてください', '请上传备份文件'],
      ['ファイルの書き込みに失敗しました', '文件写入失败'],
      ['復元に成功しました', '恢复成功'],
      ['セッションが存在しません', '会话不存在'],
      ['作成に失敗しました', '创建失败'],
      ['テキストが空です', '文本为空'],
      ['音声が短すぎます', '语音过短'],
      ['音声変換に失敗しました', '语音转换失败'],
      ['音声認識に失敗しました', '语音识别失败'],
      ['セッション ID がありません', '缺少会话 ID'],
      ['継続生成できる内容がありません', '没有可继续生成的内容'],
      ['翻訳するテキストが空です', '待翻译文本为空'],
      ['[アップロード済みファイル]', '[已上传文件]'],
      ['[ツール対話]', '[工具对话]'],
      ['[ファイル対話]', '[文件对话]'],
      ['【ツール呼び出し記録】', '【工具调用记录】'],
      ['ツール実行器が初期化されていません', '工具执行器尚未初始化'],
      ['テキストファイルではないため、直接読み取れません', '非文本文件，无法直接读取'],
      ['DeepSeek 公式検索は結果を返しませんでした', 'DeepSeek 官方搜索未返回结果'],
      ['AI はこの質問にツール呼び出しが不要と判断し、本文も返しませんでした。',
        'AI 判断此问题无需调用工具，也未返回正文。'],
      ['⛔ 豆包モード：DeepSeek の联网検索は呼び出しません（用量保護）',
        '⛔ 豆包模式：不调用 DeepSeek 联网搜索（用量保护）'],
      ['（継続指示）中断箇所から続けて書いてください。直前の最後の文字に続け、繰り返しや冒頭の言い直しはしないこと。',
        '（继续指示）请从中断处继续书写，紧接上一句的最后一个字，不要重复，也不要重写开头。'],
      ['以下はユーザーがアップロードしたファイルの内容です:', '以下为用户上传文件的内容：'],
      ['...[ファイル内容が長すぎるため、先頭 200KB のみ表示]',
        '...[文件内容过长，仅显示前 200KB]'],
      ['(読み取り失敗: ', '（读取失败：'],
    ],
    en: [
      ['第 # ラウンドの自己内省中...', 'Round # self-reflection in progress…'],
      ['第 # ラウンドの自己内省中…', 'Round # self-reflection in progress…'],
      ['【第 # ラウンドの内省】', '[Round # reflection]'],
      ['第 # ラウンドの内省に失敗しました', 'Round # reflection failed'],
      ['。前回の結果を使用します', '. Using previous result.'],
      ['# 回目の深い見直し', 'Deep review #'],
      ['暗号文の長さが不足しています', 'Ciphertext is too short'],
      ['GCM タグの検証に失敗しました', 'GCM tag verification failed'],
      ['アーカイブ作成に失敗しました', 'Failed to create archive'],
      ['一時ファイルを開けませんでした', 'Could not open temporary file'],
      ['ファイルが大きすぎるか、解析に失敗しました', 'File too large or parse failed'],
      ['バックアップファイルをアップロードしてください', 'Please upload a backup file'],
      ['ファイルの書き込みに失敗しました', 'Failed to write file'],
      ['復元に成功しました', 'Restore succeeded'],
      ['セッションが存在しません', 'Session does not exist'],
      ['作成に失敗しました', 'Failed to create'],
      ['テキストが空です', 'Text is empty'],
      ['音声が短すぎます', 'Audio too short'],
      ['音声変換に失敗しました', 'Audio conversion failed'],
      ['音声認識に失敗しました', 'Speech recognition failed'],
      ['セッション ID がありません', 'Missing session ID'],
      ['継続生成できる内容がありません', 'Nothing to continue'],
      ['翻訳するテキストが空です', 'Text to translate is empty'],
      ['[アップロード済みファイル]', '[Uploaded file]'],
      ['[ツール対話]', '[Tool conversation]'],
      ['[ファイル対話]', '[File conversation]'],
      ['【ツール呼び出し記録】', '[Tool call records]'],
      ['ツール実行器が初期化されていません', 'Tool executor not initialized'],
      ['テキストファイルではないため、直接読み取れません', 'Not a text file, cannot read directly'],
      ['DeepSeek 公式検索は結果を返しませんでした', 'DeepSeek official search returned no results'],
      ['AI はこの質問にツール呼び出しが不要と判断し、本文も返しませんでした。',
        'The AI judged no tool call was needed and returned no body.'],
      ['⛔ 豆包モード：DeepSeek の联网検索は呼び出しません（用量保護）',
        '⛔ Doubao mode: DeepSeek web search not called (usage protection)'],
      ['（継続指示）中断箇所から続けて書いてください。直前の最後の文字に続け、繰り返しや冒頭の言い直しはしないこと。',
        '(Continue) Continue from the interruption point, right after the last character; do not repeat or restart.'],
      ['以下はユーザーがアップロードしたファイルの内容です:', 'The following is the content of the uploaded file:'],
      ['...[ファイル内容が長すぎるため、先頭 200KB のみ表示]',
        '...[File too long, only first 200KB shown]'],
      ['(読み取り失敗: ', '(read failed: '],
    ],
    ko: [
      ['第 # ラウンドの自己内省中...', '#라운드 자기 성찰 진행 중…'],
      ['第 # ラウンドの自己内省中…', '#라운드 자기 성찰 진행 중…'],
      ['【第 # ラウンドの内省】', '[#라운드 성찰]'],
      ['第 # ラウンドの内省に失敗しました', '#라운드 성찰 실패'],
      ['。前回の結果を使用します', '. 이전 결과를 사용합니다.'],
      ['# 回目の深い見直し', '#차 심층 재검토'],
      ['暗号文の長さが不足しています', '암호문 길이 부족'],
      ['GCM タグの検証に失敗しました', 'GCM 태그 검증 실패'],
      ['アーカイブ作成に失敗しました', '아카이브 생성 실패'],
      ['一時ファイルを開けませんでした', '임시 파일을 열 수 없습니다'],
      ['ファイルが大きすぎるか、解析に失敗しました', '파일이 너무 크거나 분석 실패'],
      ['バックアップファイルをアップロードしてください', '백업 파일을 업로드하세요'],
      ['ファイルの書き込みに失敗しました', '파일 쓰기 실패'],
      ['復元に成功しました', '복원 성공'],
      ['セッションが存在しません', '세션이 존재하지 않습니다'],
      ['作成に失敗しました', '생성 실패'],
      ['テキストが空です', '텍스트가 비어 있습니다'],
      ['音声が短すぎます', '음성이 너무 짧습니다'],
      ['音声変換に失敗しました', '음성 변환 실패'],
      ['音声認識に失敗しました', '음성 인식 실패'],
      ['セッション ID がありません', '세션 ID 없음'],
      ['継続生成できる内容がありません', '계속 생성할 내용이 없습니다'],
      ['翻訳するテキストが空です', '번역할 텍스트가 비어 있습니다'],
      ['[アップロード済みファイル]', '[업로드된 파일]'],
      ['[ツール対話]', '[도구 대화]'],
      ['[ファイル対話]', '[파일 대화]'],
      ['【ツール呼び出し記録】', '[도구 호출 기록]'],
      ['ツール実行器が初期化されていません', '도구 실행기 미초기화'],
      ['テキストファイルではないため、直接読み取れません', '텍스트 파일이 아니므로 직접 읽을 수 없습니다'],
      ['DeepSeek 公式検索は結果を返しませんでした', 'DeepSeek 공식 검색이 결과를 반환하지 않았습니다'],
      ['AI はこの質問にツール呼び出しが不要と判断し、本文も返しませんでした。',
        'AI가 도구 호출이 필요 없다고 판단해 본문도 반환하지 않았습니다.'],
      ['⛔ 豆包モード：DeepSeek の联网検索は呼び出しません（用量保護）',
        '⛔ 두바오 모드: DeepSeek 인터넷 검색을 호출하지 않습니다(사용량 보호)'],
      ['（継続指示）中断箇所から続けて書いてください。直前の最後の文字に続け、繰り返しや冒頭の言い直しはしないこと。',
        '(계속 지시) 중단된 지점부터 이어서 작성하세요. 마지막 글자에 바로 이어 쓰고, 반복하거나 처음부터 다시 쓰지 마세요.'],
      ['以下はユーザーがアップロードしたファイルの内容です:', '다음은 사용자가 업로드한 파일의 내용입니다:'],
      ['...[ファイル内容が長すぎるため、先頭 200KB のみ表示]',
        '...[파일 내용이 너무 길어 처음 200KB만 표시]'],
      ['(読み取り失敗: ', '(읽기 실패: '],
    ],
    ru: [
      ['第 # ラウンドの自己内省中...', 'Раунд #: саморефлексия…'],
      ['第 # ラウンドの自己内省中…', 'Раунд #: саморефлексия…'],
      ['【第 # ラウンドの内省】', '[Раунд #: рефлексия]'],
      ['第 # ラウンドの内省に失敗しました', 'Раунд #: рефлексия не удалась'],
      ['。前回の結果を使用します', '. Используется предыдущий результат.'],
      ['# 回目の深い見直し', 'Глубокий пересмотр № #'],
      ['暗号文の長さが不足しています', 'Шифртекст слишком короткий'],
      ['GCM タグの検証に失敗しました', 'Проверка GCM-тега не удалась'],
      ['アーカイブ作成に失敗しました', 'Не удалось создать архив'],
      ['一時ファイルを開けませんでした', 'Не удалось открыть временный файл'],
      ['ファイルが大きすぎるか、解析に失敗しました', 'Файл слишком большой или разбор не удался'],
      ['バックアップファイルをアップロードしてください', 'Загрузите файл резервной копии'],
      ['ファイルの書き込みに失敗しました', 'Не удалось записать файл'],
      ['復元に成功しました', 'Восстановление успешно'],
      ['セッションが存在しません', 'Сессия не существует'],
      ['作成に失敗しました', 'Не удалось создать'],
      ['テキストが空です', 'Текст пуст'],
      ['音声が短すぎます', 'Аудио слишком короткое'],
      ['音声変換に失敗しました', 'Преобразование аудио не удалось'],
      ['音声認識に失敗しました', 'Распознавание речи не удалось'],
      ['セッション ID がありません', 'Отсутствует ID сессии'],
      ['継続生成できる内容がありません', 'Нечего продолжать'],
      ['翻訳するテキストが空です', 'Текст для перевода пуст'],
      ['[アップロード済みファイル]', '[Загруженный файл]'],
      ['[ツール対話]', '[Диалог с инструментами]'],
      ['[ファイル対話]', '[Диалог по файлам]'],
      ['【ツール呼び出し記録】', '[Журнал вызовов инструментов]'],
      ['ツール実行器が初期化されていません', 'Исполнитель инструментов не инициализирован'],
      ['テキストファイルではないため、直接読み取れません', 'Не текстовый файл, прямое чтение невозможно'],
      ['DeepSeek 公式検索は結果を返しませんでした', 'Официальный поиск DeepSeek не вернул результатов'],
      ['AI はこの質問にツール呼び出しが不要と判断し、本文も返しませんでした。',
        'ИИ решил, что вызов инструментов не нужен, и не вернул текст.'],
      ['⛔ 豆包モード：DeepSeek の联网検索は呼び出しません（用量保護）',
        '⛔ Режим Doubao: поиск DeepSeek не вызывается (защита квоты)'],
      ['（継続指示）中断箇所から続けて書いてください。直前の最後の文字に続け、繰り返しや冒頭の言い直しはしないこと。',
        '(Продолжение) Продолжите с места прерывания, сразу после последнего символа; не повторяйте и не переписывайте начало.'],
      ['以下はユーザーがアップロードしたファイルの内容です:', 'Ниже содержимое загруженного пользователем файла:'],
      ['...[ファイル内容が長すぎるため、先頭 200KB のみ表示]',
        '...[Файл слишком длинный, показаны первые 200 КБ]'],
      ['(読み取り失敗: ', '(ошибка чтения: '],
    ],
    fr: [
      ['第 # ラウンドの自己内省中...', 'Round # : auto-réflexion en cours…'],
      ['第 # ラウンドの自己内省中…', 'Round # : auto-réflexion en cours…'],
      ['【第 # ラウンドの内省】', '[Réflexion round #]'],
      ['第 # ラウンドの内省に失敗しました', 'Échec de la réflexion du round #'],
      ['。前回の結果を使用します', '. Utilisation du résultat précédent.'],
      ['# 回目の深い見直し', 'Réexamen approfondi n° #'],
      ['暗号文の長さが不足しています', 'Le texte chiffré est trop court'],
      ['GCM タグの検証に失敗しました', 'Échec de la vérification du tag GCM'],
      ['アーカイブ作成に失敗しました', 'Échec de la création de l’archive'],
      ['一時ファイルを開けませんでした', 'Impossible d’ouvrir le fichier temporaire'],
      ['ファイルが大きすぎるか、解析に失敗しました', 'Fichier trop volumineux ou analyse échouée'],
      ['バックアップファイルをアップロードしてください', 'Veuillez téléverser un fichier de sauvegarde'],
      ['ファイルの書き込みに失敗しました', 'Échec de l’écriture du fichier'],
      ['復元に成功しました', 'Restauration réussie'],
      ['セッションが存在しません', 'La session n’existe pas'],
      ['作成に失敗しました', 'Échec de la création'],
      ['テキストが空です', 'Le texte est vide'],
      ['音声が短すぎます', 'Audio trop court'],
      ['音声変換に失敗しました', 'Échec de la conversion audio'],
      ['音声認識に失敗しました', 'Échec de la reconnaissance vocale'],
      ['セッション ID がありません', 'ID de session manquant'],
      ['継続生成できる内容がありません', 'Rien à continuer'],
      ['翻訳するテキストが空です', 'Le texte à traduire est vide'],
      ['[アップロード済みファイル]', '[Fichier téléversé]'],
      ['[ツール対話]', '[Conversation d’outils]'],
      ['[ファイル対話]', '[Conversation de fichiers]'],
      ['【ツール呼び出し記録】', '[Journal des appels d’outils]'],
      ['ツール実行器が初期化されていません', 'L’exécuteur d’outils n’est pas initialisé'],
      ['テキストファイルではないため、直接読み取れません', 'Fichier non texte, lecture directe impossible'],
      ['DeepSeek 公式検索は結果を返しませんでした', 'La recherche officielle DeepSeek n’a renvoyé aucun résultat'],
      ['AI はこの質問にツール呼び出しが不要と判断し、本文も返しませんでした。',
        'L’IA a jugé qu’aucun appel d’outil n’était nécessaire et n’a renvoyé aucun texte.'],
      ['⛔ 豆包モード：DeepSeek の联网検索は呼び出しません（用量保護）',
        '⛔ Mode Doubao : la recherche web DeepSeek n’est pas appelée (protection du quota)'],
      ['（継続指示）中断箇所から続けて書いてください。直前の最後の文字に続け、繰り返しや冒頭の言い直しはしないこと。',
        '(Consigne de continuation) Continuez à partir du point d’interruption, immédiatement après le dernier caractère ; ne répétez pas et ne réécrivez pas le début.'],
      ['以下はユーザーがアップロードしたファイルの内容です:', 'Voici le contenu du fichier téléversé par l’utilisateur :'],
      ['...[ファイル内容が長すぎるため、先頭 200KB のみ表示]',
        '...[Fichier trop long, seuls les 200 premiers Ko sont affichés]'],
      ['(読み取り失敗: ', '(échec de lecture : '],
    ],
  };

  var KANA = /[\u3040-\u309f\u30a0-\u30ff]/;

  // ★ 只处理「系统 UI 容器」，绝不触碰 AI 正文 / 思考正文。
  //   原来包含 .dsc-msg-bubble / .dsc-think-body，会把 AI 生成的日语正文
  //   当成 UI 文案逐句翻译，造成「回答被篡改」的事故。
  var TARGETS = [
    '.dsc-think-header',      // 「推論過程とツール呼び出しの記録」
    '.dsc-think-load-full',   // 「思考チェーン全体を展開」
    '.dsc-msg-copy-btn',      // 「📋 コピー」
    '.dsc-msg-speak-btn',     // 「🔊 読み上げ」
    '.dsc-msg-translate-btn', // 「🌐 翻訳」
    '.dsc-msg-continue-btn',  // 「▶ 生成を続ける」
    '.dsc-trans-label',       // 「翻訳見出し」
    '.dsc-trans-copy-btn',    // 「📋 コピー」
    '.dsc-trans-speak-btn',   // 「🔊 読み上げ」
    '.dsc-trans-cost-row',    // 「💰 今回の翻訳 …」
    '.dsc-src-head',          // 「🔗 ネット検索ソース · N」
    '.dsc-usage-chip',        // 「入力 · キャッシュ命中 · 未命中 · 出力 · 合計」
    '.dsc-cost-chip',         // 「💰 … 元 · ピーク/アイドル」
  ].join(',');

  // 语言代码缓存（MutationObserver 每帧都会触发，不能每次都查 I18N）
  var _langCache = '';
  var _langCacheAt = 0;
  function curLang() {
    var now = Date.now();
    if (_langCache && now - _langCacheAt < 500) return _langCache;
    var l = 'ja';
    try {
      if (window.I18N) {
        if (typeof I18N.getLang === 'function') {
          var a = String(I18N.getLang() || '');
          if (a) l = a.slice(0, 2).toLowerCase();
        } else if (typeof I18N.lang === 'string' && I18N.lang) {
          l = I18N.lang.slice(0, 2).toLowerCase();
        }
      }
    } catch (e) {}
    if (l === 'ja') {
      try {
        var h = document.documentElement.getAttribute('lang') || '';
        if (h) l = h.slice(0, 2).toLowerCase();
      } catch (e) {}
    }
    _langCache = l;
    _langCacheAt = now;
    return l;
  }

  // 把含数字的短语（如「第 3 ラウンド」）按实际数字还原成译文
  function applyPhraseTpl(tpl, nums) {
    var i = 0;
    return tpl.replace(/#/g, function () {
      return i < nums.length ? nums[i++] : '#';
    });
  }

  function fixText(s) {
    if (!s || !KANA.test(s)) return s;
    var lang = curLang();
    if (lang === 'ja') return s;

    // ① 先走 I18N 字典的「整句精确匹配」：自动复用 zh/en/ko/ru/fr 的全部词条
    //    （含 *-extra.js 的后端串），无需在这里维护第二份短语表。
    //    精确匹配不做片段替换，因此不会破坏 AI 生成的正文。
    try {
      if (window.I18N && typeof window.I18N.tExact === 'function') {
        var exact = window.I18N.tExact(s);
        if (exact !== s && !KANA.test(exact)) return exact;
      }
    } catch (e) {}

    // ② 字典未命中的兜底：按当前语言查 PHRASES 表（整句 + 数字归一化）
    var table = PHRASES[lang];
    if (table && table.length) {
      // 整句精确匹配
      for (var i = 0; i < table.length; i++) {
        if (table[i][0] === s) return table[i][1];
      }
      // 数字归一化匹配（把 3 / 12 之类的数字替换成 # 后再比）
      var key = s.replace(/[0-9][0-9,.\u3000]*/g, '#');
      var nums = s.match(/[0-9][0-9,.\u3000]*/g) || [];
      for (var j = 0; j < table.length; j++) {
        var tk = table[j][0].replace(/[0-9][0-9,.\u3000]*/g, '#');
        if (tk === key) return applyPhraseTpl(table[j][1], nums);
      }
    }

    return s;
  }

  function fixNode(node) {
    if (!node) return;
    if (node.nodeType === 3) {
      var p = node.parentNode;
      if (!p || p.nodeType !== 1) return;
      if (p.closest && p.closest('pre,code,kbd,script,style,[data-no-i18n]')) return;
      if (!p.closest || !p.closest(TARGETS)) return;
      var v = node.nodeValue;
      var nv = fixText(v);
      if (nv !== v) node.nodeValue = nv;
      return;
    }
    if (node.nodeType !== 1) return;
    if (node.closest && node.closest('pre,code,kbd,script,style,[data-no-i18n]')) return;
    // 只修正目标区域内部，避免扫全树
    var scope = (node.closest && node.closest(TARGETS)) ? node : (node.querySelector ? node.querySelector(TARGETS) : null);
    if (!scope) {
      // 元素本身不是目标，但可能是目标的祖先：只在它内部查找
      if (!node.querySelector) return;
      var inner = node.querySelectorAll ? node.querySelectorAll(TARGETS) : [];
      for (var k = 0; k < inner.length; k++) fixNode(inner[k]);
      return;
    }
    var walker = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT, null, false);
    var batch = [], n;
    while ((n = walker.nextNode())) batch.push(n);
    for (var i = 0; i < batch.length; i++) fixNode(batch[i]);
  }

  var scheduled = false, pendingRoots = [];
  function flush() {
    scheduled = false;
    var roots = pendingRoots; pendingRoots = [];
    // 仅日语（源语言）无需修正；其余语言一律兜底，避免非中文模式残留日语
    if (curLang() === 'ja') return;
    for (var i = 0; i < roots.length; i++) {
      try { fixNode(roots[i]); } catch (e) {}
    }
  }
  function schedule(root) {
    if (!root) return;
    if (pendingRoots.length > 300) pendingRoots = [document.body];
    else pendingRoots.push(root);
    if (!scheduled) {
      scheduled = true;
      (window.requestAnimationFrame || function (f) { setTimeout(f, 16); })(flush);
    }
  }

  function start() {
    if (!document.body || !window.MutationObserver) return;
    new MutationObserver(function (muts) {
      if (curLang() === 'ja') return;
      for (var i = 0; i < muts.length; i++) {
        var m = muts[i];
        if (m.type === 'characterData') schedule(m.target.parentNode);
        else if (m.addedNodes && m.addedNodes.length) {
          for (var j = 0; j < m.addedNodes.length; j++) schedule(m.addedNodes[j]);
        }
      }
    }).observe(document.body, {
      childList: true, subtree: true, characterData: true
    });
    schedule(document.body);
    // 语言切换后清缓存并重新跑一遍
    document.addEventListener('dsc:langchange', function () {
      _langCache = '';
      _langCacheAt = 0;
      schedule(document.body);
    });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();

  // 对外暴露：供开发者工具 / 调试使用
  window.dscJaFix = fixText;
  window.dscJaFixDiag = function () {
    return {
      lang: curLang(),
      targets: TARGETS,
      phrases: Object.keys(PHRASES).reduce(function (acc, k) { acc[k] = PHRASES[k].length; return acc; }, {}),
    };
  };
})();