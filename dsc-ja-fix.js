/* dsc-ja-fix.js —— 中文模式下「日语残留」渲染层修正
 *
 * 背景：i18n.js 的 SKIP_SEL 明确排除了 .dsc-think-body（AI 思考区）、
 *      .dsc-msg-bubble / .dsc-stream-bubble（AI 正文与工具结果卡片），
 *      这些区域里的文案由 Dart 后端硬编码输出，DOM 自动翻译永远覆盖不到。
 *      因此这里在「渲染后」对文本节点做一次定点修正，只替换确切的固定短语，
 *      不改动 AI 生成的中文正文，也不触碰 <pre>/<code>。
 *
 * 生效范围：除日语（源语言）以外的所有界面语言。
 * 优先级：I18N 字典精确匹配（全部语言）→ 内置中文短语表兜底。
 */
;(function () {
  if (window.__dscJaFix) return;
  window.__dscJaFix = true;

  // ---------- 固定短语表（来自 lib/src/*.dart 实际扫描结果） ----------
  var PHRASES = [
    ['第 # ラウンドの自己内省中...', '正在第 # 轮自我反思…'],
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
    ['新しい会話', '新会话'],
    ['セッションが存在しません', '会话不存在'],
    ['作成に失敗しました', '创建失败'],
    ['こんにちは', '你好'],
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
    ['ラウンド', '轮'],
    ['自己内省', '自我反思'],
    ['内省', '反思']
  ];

  var KANA = /[\u3040-\u309f\u30a0-\u30ff]/;
  var TARGETS = '.dsc-think-body,.dsc-think-header,.dsc-msg-bubble,.dsc-stream-bubble';

  function curLang() {
    try {
      if (window.I18N) {
        if (typeof I18N.getLang === 'function') {
          var a = String(I18N.getLang() || '');
          if (a) return a.slice(0, 2).toLowerCase();
        }
        if (typeof I18N.lang === 'string' && I18N.lang) return I18N.lang.slice(0, 2).toLowerCase();
      }
    } catch (e) {}
    try {
      var h = document.documentElement.getAttribute('lang') || '';
      if (h) return h.slice(0, 2).toLowerCase();
      var l = localStorage.getItem('dsc_lang') || localStorage.getItem('lang') || '';
      if (l) return String(l).slice(0, 2).toLowerCase();
    } catch (e) {}
    return 'ja';
  }

  // 把「第 3 ラウンド」这类含数字的短语按实参还原
  function fixText(s) {
    if (!s || !KANA.test(s)) return s;

    // ① 先走 I18N 字典的「整句精确匹配」：自动复用 zh / en / ko / ru / fr
    //    的全部词条（含 zh-extra 的后端串），无需在这里维护第二份短语表。
    //    精确匹配不做片段替换，因此不会破坏 AI 生成的正文。
    try {
      if (window.I18N && typeof window.I18N.tExact === 'function') {
        var exact = window.I18N.tExact(s);
        if (exact !== s && !KANA.test(exact)) return exact;
      }
    } catch (e) {}

    // ② 内置短语表兜底：表内译文为简体中文，仅中文模式使用
    if (curLang() !== 'zh') return s;

    var out = s;
    for (var i = 0; i < PHRASES.length; i++) {
      var src = PHRASES[i][0], dst = PHRASES[i][1];
      if (src.indexOf('#') >= 0) {
        var rxSrc = src.split('#').map(function (p) {
          return p.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        }).join('([0-9][0-9,.]*)');
        out = out.replace(new RegExp(rxSrc, 'g'), function () {
          var args = arguments, d = dst, n = 1;
          return d.replace(/#/g, function () { return args[n++] || ''; });
        });
      } else if (out.indexOf(src) >= 0) {
        out = out.split(src).join(dst);
      }
    }
    return out;
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
    var walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT, null, false);
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
    // 语言切换后重新跑一遍
    document.addEventListener('click', function () { setTimeout(function () { schedule(document.body); }, 120); }, true);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();

  window.dscJaFix = fixText;
})();
