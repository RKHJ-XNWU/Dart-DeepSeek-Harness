/* ============================================================
 * i18n/i18n.js —— 自前 i18n コア（依存なし）
 * ------------------------------------------------------------
 * ・源語言（ソース）は日本語。日本語の文字列をキーとして各国語辞書を引く
 * ・DOM のテキストノード / placeholder / title / aria-label / alt を
 *   MutationObserver で自動翻訳（動的生成 UI も漏れなく対象）
 * ・言語切替は即時（リロード不要）。localStorage に永続化
 * ・AI 応答言語は fetch フックで lang を全リクエストへ注入し、
 *   サーバ側（Dart）がシステムプロンプトを組む
 * ============================================================ */
(function (global) {
    'use strict';

    // ---------- 基本定義 ----------
    var STORAGE_KEY = 'dsc_ui_lang';
    // 言語切替が成立したらページを再読込する（辞書適用漏れを確実に消す）
    var RELOAD_ON_LANG_CHANGE = true;
    var DEFAULT_LANG = 'ja';
    var LANGS = ['ja', 'zh', 'en', 'ko', 'ru', 'fr'];
    var LANG_LABEL = {
        ja: '日本語', zh: '中文', en: 'English',
        ko: '한국어', ru: 'Русский', fr: 'Français'
    };
    var LANG_FLAG = { ja: '🇯🇵', zh: '🇨🇳', en: '🇬🇧', ko: '🇰🇷', ru: '🇷🇺', fr: '🇫🇷' };
    // AI 応答言語の指定名（システムプロンプト用）
    var AI_LANG_NAME = {
        ja: '日本語', zh: '简体中文', en: 'English', ko: '한국어',
        ru: 'русский', fr: 'français'
    };

    var CJK_RE = /[\u3000-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\uff01-\uff60]/;
    // 翻訳してはいけない領域（AI 本文・ユーザー入力・コード等）
    var SKIP_SEL = [
        'pre', 'code', 'kbd', 'samp', 'script', 'style', 'noscript',
        'textarea', 'svg', 'math',
        '[data-no-i18n]',
        '.dsc-msg-bubble',      // AI / ユーザーの本文（Markdown レンダリング結果）
        '.dsc-msg-translation', // 翻訳結果表示
        '.dsc-ann-content',     // お知らせ本文（ユーザー生成コンテンツ）
        '.dsc-forum-content',   // フォーラム本文
        '.dsc-stream-bubble',
        '#dscInput',
        '.dsc-s-title',        // セッション名（ユーザー生成コンテンツ）
        '.dsc-s-time',         // 時刻表示
        '.dsc-msg-time',       // メッセージ時刻
        '.dsc-think-body',     // AI の思考ログ
        '.dsc-db-bubble',      // 豆包音声通話の発話ログ（ユーザー/AI 本文）
        '.dsc-db-script',      // 豆包ポッドキャストの台本（生成コンテンツ）
    ].join(',');

    // SKIP 領域のうち、アプリ自身の UI 文言は翻訳対象に戻す
    // （翻訳ブロック内の料金行・token 行など。AI 本文は引き続き対象外）
    var ALLOW_SEL = [
        '.dsc-trans-cost-row',
        '.dsc-trans-tok',
        '.dsc-trans-cost-amt',
        '.dsc-trans-cost-tag',
        '.dsc-trans-cost-unknown'
    ].join(',');

    var dicts = {};                 // code -> { src: dst }
    var dictCache = {};             // code -> 正規化キー索引
    var partialIndex = {};          // code -> [[原文, 訳文]] 長さ降順（部分一致用）
    var memo = Object.create(null);// 同一文字列の再変換を省く
    var current = DEFAULT_LANG;
    var missing = Object.create(null);   // src -> 出現回数
    var translatedNodes = [];            // 翻訳済みテキストノード（原文復元用）
    var translatedAttrs = [];            // 翻訳済み属性（原値復元用）
    var ATTRS = ['placeholder', 'title', 'aria-label', 'alt', 'data-tip'];

    // ---------- ユーティリティ ----------
    function normalize(s) {
        // 数字・カンマ区切り数値を # に潰して辞書引きを可能にする
        return String(s).replace(/[0-9][0-9,.\u3000]*/g, '#');
    }
    function hasDigit(s) { return /[0-9]/.test(s); }

    /**
     * t(src) —— 現在言語へ翻訳
     * 1) 完全一致 → 2) 数字を # に潰して一致 → 3) 原文のまま
     */
    /**
     * t(src, ...args) —— 現在言語へ翻訳
     * ・第 2 引数以降は {0} {1} … のプレースホルダに差し込む
     *   （ユーザー入力・セッション名などを文に埋め込む場合、
     *     部分一致による混在翻訳を避けるためこの形を使うこと）
     */
    function t(src) {
        if (src == null) return '';
        var s = String(src);
        var args = arguments.length > 1 ? Array.prototype.slice.call(arguments, 1) : null;
        var res = tCore(s);
        if (args && args.length && res.indexOf('{') >= 0) {
            res = res.replace(/\{(\d+)\}/g, function (m, i) {
                var v = args[Number(i)];
                return (v === undefined || v === null) ? m : String(v);
            });
        }
        return res;
    }

    /**
     * tExact(src) —— 只做「整句精确匹配」的翻译
     * 与 t() 的区别：不做部分一致替换，也不做破坏性片段替换。
     * 用途：AI 正文 / 思考区等 SKIP 区域内的**固定 UI 短语**兜底，
     *       确保不会因为某个短片段命中而破坏 AI 生成的正文。
     */
    function tExact(s) {
        if (s == null) return '';
        var str = String(s);
        if (current === 'ja') return str;
        var d = dicts[current];
        if (!d) return str;
        if (Object.prototype.hasOwnProperty.call(d, str)) return d[str];
        var tr = str.replace(/^\s+|\s+$/g, '');
        if (tr !== str && Object.prototype.hasOwnProperty.call(d, tr)) {
            var w = /^(\s*)([\s\S]*?)(\s*)$/.exec(str);
            return (w ? w[1] : '') + d[tr] + (w ? w[3] : '');
        }
        // 数字归一化后的精确匹配（如「件の〜:」+ 运行时数字）
        if (/[0-9]/.test(str)) {
            var key = tr.replace(/[0-9][0-9,.\u3000]*/g, '#');
            var cache = dictCache[current] || buildCache(current);
            if (Object.prototype.hasOwnProperty.call(cache, key)) return cache[key];
        }
        return str;
    }

    function tCore(s) {
        if (current === 'ja') return s;
        var d = dicts[current];
        if (!d) return s;

        var hit = memo[s];
        if (hit !== undefined) return hit;
        var res = translateCore(s, d, current);
        memo[s] = res;
        return res;
    }

    function translateCore(s, d, code) {
        // 1) 完全一致
        if (Object.prototype.hasOwnProperty.call(d, s)) return d[s];

        var trimmed = s.replace(/^\s+|\s+$/g, '');
        if (trimmed !== s && Object.prototype.hasOwnProperty.call(d, trimmed)) {
            var w = /^(\s*)([\s\S]*?)(\s*)$/.exec(s);
            return (w ? w[1] : '') + d[trimmed] + (w ? w[3] : '');
        }

        // 2) 数字を # に潰して照合
        if (hasDigit(s)) {
            var key = normalize(trimmed);
            var cache = dictCache[code] || buildCache(code);
            if (Object.prototype.hasOwnProperty.call(cache, key)) {
                var tpl = cache[key];
                var nums = trimmed.match(/[0-9][0-9,.\u3000]*/g) || [];
                if (/#/.test(tpl)) {
                    var idx = 0;
                    return tpl.replace(/#/g, function () {
                        return idx < nums.length ? nums[idx++] : '#';
                    });
                }
                var idx2 = 0;
                return tpl.replace(/[0-9][0-9,.\u3000]*/g, function (m) {
                    return idx2 < nums.length ? nums[idx2++] : m;
                });
            }
        }

        // 3) 部分一致（動的に連結された文言の断片を消す）
        if (s.length <= 160 && CJK_RE.test(s)) {
            var arr = partialIndex[code] || buildPartial(code);
            var out = s;
            var any = false;
            for (var i = 0; i < arr.length; i++) {
                if (out.indexOf(arr[i][0]) >= 0) {
                    out = out.split(arr[i][0]).join(arr[i][1]);
                    any = true;
                }
            }
            if (any) return out;
        }
        return s;
    }

    function buildCache(code) {
        var d = dicts[code] || {};
        var c = Object.create(null);
        for (var k in d) {
            if (!Object.prototype.hasOwnProperty.call(d, k)) continue;
            if (hasDigit(k)) {
                c[normalize(k)] = d[k];
            } else if (k.indexOf('#') >= 0) {
                // 辞書側が最初から # プレースホルダで書かれている条目
                // （例「全 # 件ヒット|# hits total」）は数字を含まないため
                // 上の分岐に入らず、実行時の数字正規化と一致できなかった。
                c[k] = d[k];
            }
        }
        dictCache[code] = c;
        return c;
    }

    /** 部分一致用の索引（長いキーから順に置換して語順破壊を最小化） */
    function buildPartial(code) {
        var d = dicts[code] || {};
        var arr = [];
        for (var k in d) {
            if (!Object.prototype.hasOwnProperty.call(d, k)) continue;
            if (k.length < 2) continue;
            arr.push([k, d[k]]);
        }
        arr.sort(function (a, b) { return b[0].length - a[0].length; });
        partialIndex[code] = arr;
        return arr;
    }

    // ---------- 辞書登録 ----------
    /**
     * I18N.add(code, data)
     * data は { "日本語": "訳文" } 形式、または
     * 「日本語|訳文」を 1 行ずつ並べた文字列のどちらでもよい。
     */
    function add(code, data) {
        if (!dicts[code]) dicts[code] = {};
        if (typeof data === 'string') {
            data.split('\n').forEach(function (line) {
                var ln = line.replace(/^\s+|\s+$/g, '');
                if (!ln || ln.charAt(0) === '#') return;
                var i = ln.indexOf('|');
                if (i < 0) return;
                dicts[code][ln.slice(0, i)] = ln.slice(i + 1);
            });
        } else if (data && typeof data === 'object') {
            for (var k in data) {
                if (Object.prototype.hasOwnProperty.call(data, k)) dicts[code][k] = data[k];
            }
        }
        dictCache[code] = null;
        partialIndex[code] = null;
        memo = Object.create(null);
        return I18N;
    }

    // ---------- テキストノード翻訳 ----------
    function inSkipped(el) {
        if (!el) return true;
        try {
            if (el.closest && el.closest(ALLOW_SEL)) return false;
            return !!el.closest(SKIP_SEL);
        } catch (e) { return false; }
    }

    function translateTextNode(node) {
        var parent = node.parentNode;
        if (!parent || parent.nodeType !== 1) return;
        if (inSkipped(parent)) return;
        var src = node.__i18nSrc !== undefined ? node.__i18nSrc : node.nodeValue;
        if (src == null) return;
        if (!String(src).replace(/\s+/g, ' ').trim()) return;
        var dst = t(src);
        if (dst === src) {
            if (CJK_RE.test(src)) missing[src] = (missing[src] || 0) + 1;
            if (node.__i18nSrc !== undefined && node.nodeValue !== src) node.nodeValue = src;
            return;
        }
        if (node.__i18nSrc === undefined) node.__i18nSrc = src;
        if (translatedNodes.indexOf(node) < 0) translatedNodes.push(node);
        if (node.nodeValue !== dst) { node.__i18nOwn = dst; node.nodeValue = dst; }
    }

    function translateElementAttrs(el) {
        if (!el || el.nodeType !== 1) return;
        if (inSkipped(el)) {
            // 入力欄の本文・値は翻訳しないが、placeholder / title などの UI 文言は翻訳する
            var tag = el.tagName;
            if (tag !== 'TEXTAREA' && tag !== 'INPUT') return;
        }
        for (var i = 0; i < ATTRS.length; i++) {
            var name = ATTRS[i];
            if (!el.hasAttribute || !el.hasAttribute(name)) continue;
            var storeKey = '__i18nAttr_' + name.replace(/[^a-z]/gi, '');
            var src = el[storeKey] !== undefined ? el[storeKey] : el.getAttribute(name);
            if (src == null || !String(src).trim()) continue;
            var dst = t(src);
            if (dst === src) {
                if (el[storeKey] !== undefined && el.getAttribute(name) !== src) el.setAttribute(name, src);
                continue;
            }
            if (el[storeKey] === undefined) {
                el[storeKey] = src;
                translatedAttrs.push({ el: el, name: name, key: storeKey });
            }
            if (el.getAttribute(name) !== dst) el.setAttribute(name, dst);
        }
    }

    function translateTree(root) {
        if (!root || root.nodeType !== 1) return;
        // 属性
        if (root.hasAttribute) translateElementAttrs(root);
        var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
            acceptNode: function (n) {
                var v = (n.__i18nSrc !== undefined) ? n.__i18nSrc : n.nodeValue;
                if (!v || !String(v).replace(/\s+/g, ' ').trim()) return NodeFilter.FILTER_REJECT;
                if (inSkipped(n.parentNode)) return NodeFilter.FILTER_REJECT;
                return NodeFilter.FILTER_ACCEPT;
            }
        });
        var n;
        while ((n = walker.nextNode())) translateTextNode(n);
        var els = root.querySelectorAll ? root.querySelectorAll('[placeholder],[title],[aria-label],[alt],[data-tip]') : [];
        for (var i = 0; i < els.length; i++) translateElementAttrs(els[i]);
    }

    // ---------- ページタイトル ----------
    function translateTitle() {
        if (!document.title) return;
        if (document.__i18nTitle === undefined) document.__i18nTitle = document.title;
        var dst = t(document.__i18nTitle);
        if (document.title !== dst) document.title = dst;
    }

    // ---------- 原文復元 ----------
    function restoreAll() {
        var i;
        for (i = 0; i < translatedNodes.length; i++) {
            var n = translatedNodes[i];
            if (!n) continue;
            if (n.__i18nSrc !== undefined) { n.__i18nOwn = n.__i18nSrc; n.nodeValue = n.__i18nSrc; }
        }
        translatedNodes.length = 0;
        for (i = 0; i < translatedAttrs.length; i++) {
            var a = translatedAttrs[i];
            if (!a || !a.el) continue;
            if (a.el[a.key] !== undefined) a.el.setAttribute(a.name, a.el[a.key]);
        }
        translatedAttrs.length = 0;
    }

    // ---------- 監視（動的 DOM 対応） ----------
    var observer = null;
    var pending = [];
    var scheduled = false;

    function flush() {
        scheduled = false;
        var roots = pending; pending = [];
        for (var i = 0; i < roots.length; i++) {
            var r = roots[i];
            if (r && r.isConnected !== false) translateTree(r);
        }
    }
    function schedule(root) {
        if (!root) return;
        if (pending.length > 400) { pending = [document.body]; }
        else pending.push(root);
        if (!scheduled) {
            scheduled = true;
            (global.requestAnimationFrame || function (f) { setTimeout(f, 16); })(flush);
        }
    }

    // 属性名 → 原文保存用の内部キー
    function attrStoreKey(name) { return '__i18nAttr_' + name.replace(/[^a-z]/gi, ''); }

    function startObserver() {
        if (observer || !global.MutationObserver || !document.body) return;
        observer = new MutationObserver(function (muts) {
            for (var i = 0; i < muts.length; i++) {
                var m = muts[i];

                if (m.type === 'characterData') {
                    var tn = m.target;
                    if (!tn || !tn.parentNode || tn.parentNode.nodeType !== 1) continue;
                    if (tn.__i18nSrc === undefined) {
                        // 未翻訳ノードへの書き込み → 通常の翻訳対象
                        schedule(tn.parentNode);
                        continue;
                    }
                    // 自分で書き込んだ翻訳結果は無視する
                    if (tn.__i18nOwn !== undefined && tn.nodeValue === tn.__i18nOwn) continue;
                    // 原文へ戻された場合も無視
                    if (tn.nodeValue === tn.__i18nSrc) continue;
                    // 外部（JS）が新しい原文を書いた → 原文を更新して再翻訳
                    tn.__i18nSrc = tn.nodeValue;
                    tn.__i18nOwn = undefined;
                    schedule(tn.parentNode);
                    continue;
                }

                if (m.type === 'attributes') {
                    var el = m.target;
                    if (!el || el.nodeType !== 1) continue;
                    var name = m.attributeName;
                    if (!name) continue;
                    var key = attrStoreKey(name);
                    var orig = el[key];
                    var now = el.getAttribute(name);
                    if (orig !== undefined) {
                        if (now === orig) continue;                 // 原文のまま
                        if (now === t(orig)) continue;              // 自分の翻訳書き込み
                        // 外部が新しい原文を書いた
                        el[key] = undefined;
                        delete el[key];
                    }
                    schedule(el);
                    continue;
                }

                if (m.type === 'childList') {
                    var added = m.addedNodes || [];
                    for (var j = 0; j < added.length; j++) {
                        var nd = added[j];
                        if (nd.nodeType === 1) schedule(nd);
                        else if (nd.nodeType === 3 && nd.parentNode) schedule(nd.parentNode);
                    }
                }
            }
        });
        observer.observe(document.body, {
            childList: true, subtree: true, characterData: true,
            attributes: true, attributeFilter: ATTRS
        });
    }

    // ---------- ネイティブダイアログの翻訳 ----------
    function patchNativeDialogs() {
        var _alert = global.alert, _confirm = global.confirm, _prompt = global.prompt;
        global.alert = function (msg) { return _alert.call(global, t(msg)); };
        global.confirm = function (msg) { return _confirm.call(global, t(msg)); };
        global.prompt = function (msg, def) { return _prompt.call(global, t(msg), def); };
    }

    // ---------- AI 応答言語プロンプト ----------
    function aiPrompt(code) {
        code = code || current;
        return global.DSC_I18N_PROMPTS && global.DSC_I18N_PROMPTS[code]
            ? global.DSC_I18N_PROMPTS[code] : '';
    }

    // ---------- 言語切替 ----------
    function setLang(code, opt) {
        if (LANGS.indexOf(code) < 0) code = DEFAULT_LANG;
        var prev = current;
        current = code;
        try { localStorage.setItem(STORAGE_KEY, code); } catch (e) { }
        if (document.documentElement) {
            document.documentElement.setAttribute('lang', code);
            document.documentElement.setAttribute('data-dsc-lang', code);
        }
        memo = Object.create(null);
        restoreAll();
        translateTree(document.body);
        translateTitle();
        updateLangUI();
        // UI の再描画が必要なモジュールへ通知
        try {
            global.dispatchEvent(new CustomEvent('dsc:langchange', { detail: { lang: code, prev: prev } }));
        } catch (e) { }
        if (!opt || opt.silent !== true) {
            if (typeof global.dscToast === 'function') {
                global.dscToast(LANG_FLAG[code] + ' ' + LANG_LABEL[code]);
            }
        }

        // ---------- 言語切替後の自動リロード ----------
        // 切替が成立したとき（同一言語の再選択は除く）は、その場でページを再読込する。
        // 辞書適用漏れ・動的 DOM の取りこぼし・各モジュールの再描画漏れを
        // 一度の再読込で確実に解消するため。opt.reload === false でのみ無効化できる。
        if (code !== prev && RELOAD_ON_LANG_CHANGE && (!opt || opt.reload !== false)) {
            // ?lang= 付きの URL は initialLang() で最優先されるため、
            // 再読込で選択が巻き戻らないよう、先に新しい言語へ書き換えておく
            try {
                var u = new URL(global.location.href);
                if (u.searchParams.has('lang')) {
                    u.searchParams.set('lang', code);
                    if (global.history && global.history.replaceState) {
                        global.history.replaceState(null, '', u.pathname + u.search + u.hash);
                    }
                }
            } catch (e6) { }
            try { global.location.reload(); } catch (e7) { }
            // reload が無視される WebView 向けの保険（reload 成功時は到達しない）
            try { setTimeout(function () { global.location.reload(); }, 0); } catch (e8) { }
            return code;
        }

        return code;
    }

    function getLang() { return current; }

    // ---------- 言語メニュー（⋯ メニュー内） ----------
    function updateLangUI() {
        var cur = document.getElementById('dscLangCur');
        if (cur) cur.textContent = LANG_FLAG[current] + ' ' + LANG_LABEL[current];
        var items = document.querySelectorAll('.dsc-lang-item');
        for (var i = 0; i < items.length; i++) {
            var on = items[i].getAttribute('data-lang') === current;
            items[i].classList.toggle('active', on);
            items[i].setAttribute('aria-checked', on ? 'true' : 'false');
        }
    }

    function buildLangMenu() {
        var menu = document.getElementById('dscMoreMenu');
        if (!menu || document.getElementById('dscLangBtn')) return;

        var btn = document.createElement('button');
        btn.className = 'dsc-more-item';
        btn.id = 'dscLangBtn';
        btn.setAttribute('title', '言語を切り替え');

        var ic = document.createElement('span');
        ic.className = 'ic';
        ic.textContent = '🌏';
        btn.appendChild(ic);

        var tx = document.createElement('span');
        tx.className = 'tx';
        tx.textContent = '言語';
        btn.appendChild(tx);

        var cur = document.createElement('span');
        cur.className = 'dsc-lang-cur';
        cur.id = 'dscLangCur';
        btn.appendChild(cur);

        var panel = document.createElement('div');
        panel.className = 'dsc-lang-panel';
        panel.id = 'dscLangPanel';
        for (var i = 0; i < LANGS.length; i++) {
            var c = LANGS[i];
            var item = document.createElement('button');
            item.type = 'button';
            item.className = 'dsc-lang-item';
            item.setAttribute('role', 'menuitemradio');
            item.setAttribute('data-lang', c);
            item.setAttribute('aria-checked', 'false');

            var lf = document.createElement('span');
            lf.className = 'lf';
            lf.textContent = LANG_FLAG[c];
            item.appendChild(lf);

            var ln = document.createElement('span');
            ln.className = 'ln';
            ln.textContent = LANG_LABEL[c];
            item.appendChild(ln);

            var lk = document.createElement('span');
            lk.className = 'lk';
            lk.textContent = c.toUpperCase();
            item.appendChild(lk);

            panel.appendChild(item);
        }
        // <button> の内部にボタンを入れ子にできないため、パネルは兄弟要素として直後に置く
        btn.setAttribute('aria-haspopup', 'true');
        btn.setAttribute('aria-expanded', 'false');

        btn.addEventListener('click', function (e) {
            e.preventDefault();
            e.stopPropagation();
            var open = panel.classList.toggle('open');
            btn.setAttribute('aria-expanded', open ? 'true' : 'false');
        });
        panel.addEventListener('click', function (e) {
            e.preventDefault();
            e.stopPropagation();
            var b = e.target && e.target.closest ? e.target.closest('.dsc-lang-item') : null;
            if (!b) return;
            var code = b.getAttribute('data-lang');
            panel.classList.remove('open');
            btn.setAttribute('aria-expanded', 'false');
            setLang(code);
        });
        document.addEventListener('click', function (e) {
            if (!panel.classList.contains('open')) return;
            if (e.target === btn || (btn.contains && btn.contains(e.target))) return;
            if (panel.contains && panel.contains(e.target)) return;
            panel.classList.remove('open');
            btn.setAttribute('aria-expanded', 'false');
        }, true);

        // ⋯ メニューは 8 項目以上でスクロール制限されるため、先頭に置いて即座に見えるようにする
        if (menu.firstChild && menu.insertBefore) menu.insertBefore(btn, menu.firstChild);
        else menu.appendChild(btn);
        if (menu.insertBefore && btn.nextSibling) menu.insertBefore(panel, btn.nextSibling);
        else menu.appendChild(panel);
        updateLangUI();
    }

    // ---------- fetch フック（AI 言語の伝播） ----------
    function patchFetch() {
        if (!global.fetch || global.fetch.__i18nPatched) return;
        var orig = global.fetch;
        var wrapped = function (input, init) {
            try {
                var url = typeof input === 'string' ? input : (input && input.url) || '';
                init = init || {};
                var headers = init.headers;
                if (headers instanceof global.Headers) {
                    headers.set('X-DSC-Lang', current);
                } else if (Array.isArray(headers)) {
                    headers.push(['X-DSC-Lang', current]);
                } else {
                    headers = headers || {};
                    headers['X-DSC-Lang'] = current;
                    init.headers = headers;
                }
                // チャット系は本文にも lang を注入
                if (/\/api\/ds-chat\/(send|continue|chat)/.test(url) && typeof init.body === 'string') {
                    try {
                        var obj = JSON.parse(init.body);
                        if (obj && typeof obj === 'object') {
                            obj.lang = current;
                            obj.uiLang = current;
                            init.body = JSON.stringify(obj);
                        }
                    } catch (e2) { /* JSON 以外はそのまま */ }
                }
            } catch (e) { }
            return orig.call(global, input, init);
        };
        wrapped.__i18nPatched = true;
        global.fetch = wrapped;
    }

    // ---------- 初期化 ----------
    function initialLang() {
        // ?lang=xx が付いていれば最優先（検証・共有用）
        try {
            var q = new URLSearchParams(global.location.search).get('lang');
            if (q && LANGS.indexOf(q) >= 0) return q;
        } catch (e0) { }
        try {
            var saved = localStorage.getItem(STORAGE_KEY);
            if (saved && LANGS.indexOf(saved) >= 0) return saved;
        } catch (e) { }
        var htmlLang = (document.documentElement && document.documentElement.getAttribute('lang')) || '';
        if (htmlLang && LANGS.indexOf(htmlLang) >= 0 && htmlLang !== DEFAULT_LANG) return htmlLang;
        return DEFAULT_LANG;
    }

    function init() {
        current = initialLang();
        try { localStorage.setItem(STORAGE_KEY, current); } catch (e) { }
        patchNativeDialogs();
        patchFetch();
        if (document.documentElement) {
            document.documentElement.setAttribute('lang', current);
            document.documentElement.setAttribute('data-dsc-lang', current);
        }
        translateTree(document.body);
        translateTitle();
        startObserver();
        buildLangMenu();
        updateLangUI();
        // 後発で生成されるメニューにも追随
        var tries = 0;
        var timer = setInterval(function () {
            if (document.getElementById('dscLangBtn') || ++tries > 40) { clearInterval(timer); return; }
            buildLangMenu();
        }, 250);
    }

    var I18N = {
        LANGS: LANGS,
        LABEL: LANG_LABEL,
        FLAG: LANG_FLAG,
        DEFAULT_LANG: DEFAULT_LANG,
        add: add,
        t: t,
        tExact: tExact,
        getLang: getLang,
        setLang: setLang,
        translateTree: translateTree,
        refresh: function () { restoreAll(); translateTree(document.body); updateLangUI(); },
        aiPrompt: aiPrompt,
        aiLangName: function (c) { return AI_LANG_NAME[c || current] || '日本語'; },
        // 非 ja 言語で「まだ日本語（かな）が残っている」文字列を一覧化する
        residualReport: function (code) {
            code = code || current;
            if (code === 'ja') return [];
            var out = [];
            var seenEl = {};
            if (document.body) {
                var w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
                var n;
                while ((n = w.nextNode())) {
                    var v = (n.__i18nSrc !== undefined) ? n.nodeValue : n.nodeValue;
                    if (!v) continue;
                    if (!/[\u3040-\u309f\u30a0-\u30ff]/.test(v)) continue;
                    if (inSkipped(n.parentNode)) continue;
                    var s2 = String(v).trim();
                    if (s2 && !seenEl[s2]) { seenEl[s2] = 1; out.push(s2); }
                }
            }
            return out;
        },
        missingReport: function () {
            var out = [];
            for (var k in missing) out.push({ text: k, count: missing[k] });
            out.sort(function (a, b) { return b.count - a.count; });
            return out;
        },
        coverage: function (code) {
            return Object.keys(dicts[code] || {}).length;
        },
        dict: function (code) { return dicts[code] || {}; }
    };

    global.I18N = I18N;
    global.t = t;

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})(window);
