/* ============================================================
 * dsc-doubao-plugins.js —— 豆包专属「墨迹天气 / 头条图文」开关按钮
 *
 * 【v7 · 2026 用户强制要求，逐条落地】
 *   ✓ 打开墨迹天气 / 头条图文任意插件时，强制关闭工具模式
 *   ✓ 插件开启期间，工具模式按钮完全置灰、禁止点击
 *   ✓ 全链路多语言适配：中文 / 英语 / 日语 / 韩语 / 法语 / 俄语
 *   ✓ 所有残留日语文案全部清理，统一走 I18N 多语言字典
 *   ✓ 不备份、不编译，直接修改源文件
 * ============================================================ */
(function () {
    'use strict';

    var MOJI_ID = 'dscDbMojiBtn';
    var TOUJI_ID = 'dscDbToutiaoBtn';
    var SYNC_MS = 600;
    var SWITCH_KEY = 'dsc_db_plugin_switch';

    /* 多语言字典：覆盖全部提示文案，无任何硬编码日语 */
    var I18N_DICT = {
        'zh-CN': {
            'plugin_only_db': '该插件仅在豆包模式下可用',
            'moji_on': '已开启墨迹天气插件',
            'toutiao_on': '已开启头条图文插件',
            'plugin_off': '已关闭该插件',
            'moji_title': '墨迹天气：点击开启，再点关闭（可与头条图文同时开启）',
            'toutiao_title': '头条图文：点击开启，再点关闭（可与墨迹天气同时开启）',
            'tool_locked': '墨迹天气/头条图文插件已开启，工具模式暂不可用'
        },
        'en-US': {
            'plugin_only_db': 'This plugin is only available in Doubao mode',
            'moji_on': 'Moji Weather plugin enabled',
            'toutiao_on': 'Toutiao Article plugin enabled',
            'plugin_off': 'Plugin disabled',
            'moji_title': 'Moji Weather: click to enable, click again to disable (can run together with Toutiao)',
            'toutiao_title': 'Toutiao Article: click to enable, click again to disable (can run together with Moji)',
            'tool_locked': 'Moji/Toutiao plugin is active, tool mode is locked'
        },
        'ja-JP': {
            'plugin_only_db': 'このプラグインは豆包モードでのみ利用可能です',
            'moji_on': '墨迹天気プラグインを有効化しました',
            'toutiao_on': '頭条記事プラグインを有効化しました',
            'plugin_off': 'プラグインを無効化しました',
            'moji_title': '墨迹天気：クリックで有効化、もう一度クリックで無効化（頭条記事と同時に有効化できます）',
            'toutiao_title': '頭条記事：クリックで有効化、もう一度クリックで無効化（墨迹天気と同時に有効化できます）',
            'tool_locked': '墨迹天気/頭条記事プラグインが有効中のため、ツールモードは利用できません'
        },
        'ko-KR': {
            'plugin_only_db': '이 플러그인은 두바오 모드에서만 사용 가능합니다',
            'moji_on': '墨迹 날씨 플러그인이 켜졌습니다',
            'toutiao_on': '헤드라인 기사 플러그인이 켜졌습니다',
            'plugin_off': '플러그인이 꺼졌습니다',
            'moji_title': '墨迹 날씨: 클릭으로 켜기, 다시 클릭으로 끄기 (헤드라인 기사와 함께 켤 수 있습니다)',
            'toutiao_title': '헤드라인 기사: 클릭으로 켜기, 다시 클릭으로 끄기 (墨迹 날씨와 함께 켤 수 있습니다)',
            'tool_locked': '墨迹 날씨/헤드라인 기사 플러그인이 켜져 있어 도구 모드를 사용할 수 없습니다'
        },
        'fr-FR': {
            'plugin_only_db': 'Ce plugin n\'est disponible qu\'en mode Doubao',
            'moji_on': 'Plugin Moji Weather activé',
            'toutiao_on': 'Plugin Article Toutiao activé',
            'plugin_off': 'Plugin désactivé',
            'moji_title': 'Moji Weather : cliquez pour activer, recliquez pour désactiver (mode outils verrouillé)',
            'toutiao_title': 'Article Toutiao : cliquez pour activer, recliquez pour désactiver (mode outils verrouillé)',
            'tool_locked': 'Plugin Moji/Toutiao actif, mode outils verrouillé'
        },
        'ru-RU': {
            'plugin_only_db': 'Этот плагин доступен только в режиме Doubao',
            'moji_on': 'Плагин погоды Moji включён',
            'toutiao_on': 'Плагин статей Toutiao включён',
            'plugin_off': 'Плагин отключён',
            'moji_title': 'Погода Moji: нажмите для включения, нажмите ещё раз для отключения (режим инструментов заблокирован)',
            'toutiao_title': 'Статьи Toutiao: нажмите для включения, нажмите ещё раз для отключения (режим инструментов заблокирован)',
            'tool_locked': 'Плагин Moji/Toutiao активен, режим инструментов заблокирован'
        }
    };

    function $(id) { return document.getElementById(id); }

    function getLang() {
        try {
            // 优先跟随 i18n 当前语言（用户手动切换的语言），短码映射到带区域格式
            if (window.I18N && typeof window.I18N.getLang === 'function') {
                var c = String(window.I18N.getLang() || '');
                var map = { zh: 'zh-CN', en: 'en-US', ja: 'ja-JP', ko: 'ko-KR', fr: 'fr-FR', ru: 'ru-RU' };
                if (map[c]) return map[c];
                if (/^[a-z]{2}-[A-Z]{2}$/.test(c)) return c;
            }
            var nav = navigator.language || 'zh-CN';
            var m2 = { zh: 'zh-CN', en: 'en-US', ja: 'ja-JP', ko: 'ko-KR', fr: 'fr-FR', ru: 'ru-RU' };
            if (m2[nav]) return m2[nav];
            return nav || 'zh-CN';
        } catch (e) {
            return 'zh-CN';
        }
    }

    function T(key) {
        var lang = getLang();
        var dict = I18N_DICT[lang] || I18N_DICT['zh-CN'];
        return dict[key] || I18N_DICT['zh-CN'][key] || key;
    }

    function toast(msg, type) {
        var wrap = $('dscToastWrap');
        if (!wrap) {
            try { console.log('[DB-PLUGIN]', msg); } catch (e) {}
            return;
        }
        var el = document.createElement('div');
        el.className = 'dsc-toast ' + (type || '');
        el.textContent = msg;
        wrap.appendChild(el);
        setTimeout(function () {
            try { el.remove(); } catch (e) {}
        }, 2600);
    }

    function isDbMode() {
        try {
            if (typeof window.dscDoubaoModeOn === 'function') {
                return !!window.dscDoubaoModeOn();
            }
        } catch (e) {}
        try { return localStorage.getItem('dsc_doubao_mode') === '1'; } catch (e) {}
        return false;
    }

    /* v9 核心修复：由「单选」改为「多选集合」。
       旧实现把 SWITCH_KEY 当成单值，后点的插件直接覆盖先点的，
       所以墨迹天气与头条图文永远只能二选一。
       新实现把 SWITCH_KEY 存成逗号分隔集合，仍用同一个 key，兼容外部读写：
         ''             -> 两个都关
         'moji'         -> 只开墨迹天气
         'toutiao'      -> 只开头条图文
         'moji,toutiao' -> 两个同时开启（本次修复目标）
       两个插件状态彼此独立，互不覆盖、互不挤占。 */
    var KINDS = ['moji', 'toutiao'];

    function parseSet(raw) {
        var set = { moji: false, toutiao: false };
        String(raw || '').split(',').forEach(function (part) {
            part = part.trim();
            if (part === 'moji' || part === 'toutiao') set[part] = true;
        });
        return set;
    }

    function joinSet(set) {
        return KINDS.filter(function (k) { return !!set[k]; }).join(',');
    }

    function getSet() {
        try { return parseSet(localStorage.getItem(SWITCH_KEY)); } catch (e) {}
        return { moji: false, toutiao: false };
    }

    /* 兼容旧调用：返回逗号串，'' 表示全关 */
    function getSwitch() {
        return joinSet(getSet());
    }

    function isOn(kind) {
        return !!getSet()[kind];
    }

    function saveSet(set) {
        var v = joinSet(set);
        try { localStorage.setItem(SWITCH_KEY, v); } catch (e) {}
        try {
            window.dispatchEvent(new CustomEvent('dsc:plugin-switch', { detail: { kind: v, set: set } }));
        } catch (e) {}
        return v;
    }

    /* 兼容旧调用：传入 kind 表示「只开这一个」，传 '' 表示全关 */
    function setSwitch(kind) {
        return saveSet(parseSet(kind));
    }

    /* 按 kind 取反，只改自己那一位，不影响另一个插件 */
    function toggleKind(kind) {
        var set = getSet();
        set[kind] = !set[kind];
        return saveSet(set);
    }

    function applyState() {
        var set = getSet();
        var on = joinSet(set);
        var pairs = [[MOJI_ID, 'moji'], [TOUJI_ID, 'toutiao']];
        for (var i = 0; i < pairs.length; i++) {
            var b = $(pairs[i][0]);
            if (!b) continue;
            var isOn = !!set[pairs[i][1]];
            b.classList.toggle('active', isOn);
            b.classList.toggle('dsc-db-plugin-on', isOn);
            b.setAttribute('aria-pressed', isOn ? 'true' : 'false');
        }
        /* 插件开启时关闭工具模式：只在「用户切换插件」这一刻执行一次。
           v8 修复：不再写 pointer-events:none / aria-disabled，
           否则会与 tools 侧的同步互相覆盖，形成可见的抖闪；
           按钮保持可点，占用期间点击由 click 处理器给出明确提示。 */
        /* v9：插件与工具模式彻底解耦。
           插件开启不再强制关闭工具模式，也不再给按钮加锁定态，
           插件与工具模式可以同时使用。 */
        var toolBtn = $('dscDbToolModeBtn');
        if (toolBtn) {
            toolBtn.classList.remove('db-locked');
            toolBtn.style.pointerEvents = '';
            toolBtn.removeAttribute('aria-disabled');
        }
    }

    function canUse() {
        if (isDbMode()) return true;
        var bs = [$(MOJI_ID), $(TOUJI_ID)];
        for (var i = 0; i < bs.length; i++) {
            var b = bs[i];
            if (!b) continue;
            if (b.classList.contains('dsc-db-hidden')) continue;
            if (b.style.display === 'none') continue;
            return true;
        }
        return false;
    }

    function togglePlugin(kind, btn) {
        if (!canUse()) {
            toast(T('plugin_only_db'), 'error');
            return;
        }
        if (kind !== 'moji' && kind !== 'toutiao') return;

        /* v9：只取反当前点的那一个，另一个保持原状，实现可同时开启 */
        toggleKind(kind);
        applyState();

        if (isOn(kind)) {
            toast(T(kind === 'moji' ? 'moji_on' : 'toutiao_on'), 'success');
        } else {
            toast(T('plugin_off'), 'info');
        }
    }

    var MOJI_SVG = ''
        + '<svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">'
        + '<circle cx="9" cy="8.2" r="3.1" stroke="currentColor" stroke-width="1.7"/>'
        + '<path d="M9 2.6v1.3M9 12.5v1.3M3.4 8.2H2.1M15.9 8.2h1.3M5.3 4.5L4.4 3.6M13.6 3.6l-.9.9"'
        + ' stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>'
        + '<path d="M7.4 18.9h8.2a3.3 3.3 0 0 0 .3-6.58 4.5 4.5 0 0 0-8.6 1.1'
        + ' 3.2 3.2 0 0 0 .1 5.48Z" stroke="currentColor" stroke-width="1.7"'
        + ' stroke-linejoin="round"/>'
        + '</svg>';

    var TOUJIAO_SVG = ''
        + '<svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">'
        + '<rect x="3.2" y="4.4" width="17.6" height="15.2" rx="2.6"'
        + ' stroke="currentColor" stroke-width="1.7"/>'
        + '<path d="M6.4 8.6h6.2M6.4 11.9h4.2" stroke="currentColor" stroke-width="1.6"'
        + ' stroke-linecap="round"/>'
        + '<rect x="13.6" y="8.2" width="3.9" height="3.7" rx="0.9"'
        + ' stroke="currentColor" stroke-width="1.5"/>'
        + '<path d="M6.4 15.2h11.1" stroke="currentColor" stroke-width="1.6"'
        + ' stroke-linecap="round"/>'
        + '</svg>';

    function ensureStyle() {
        if ($('dscDbPluginStyle')) return;
        var st = document.createElement('style');
        st.id = 'dscDbPluginStyle';
        st.textContent = [
            '.dsc-db-plugin-btn{position:relative;flex:0 0 auto;display:inline-flex;align-items:center;justify-content:center;',
            'width:34px;min-width:34px;height:34px;border-radius:10px;border:1px solid rgba(148,163,184,.35);',
            'background:rgba(255,255,255,.72);color:#0f766e;cursor:pointer;padding:0;',
            'transition:transform .14s ease,box-shadow .16s ease,background .16s ease,border-color .16s ease;',
            '-webkit-tap-highlight-color:transparent}',
            '.dsc-db-plugin-btn .ic{display:block;line-height:0}',
            '.dsc-db-plugin-btn .ic svg{display:block;width:18px;height:18px}',
            '.dsc-db-plugin-btn:hover{transform:translateY(-1px);background:#f0fdfa;border-color:#99f6e4;',
            'box-shadow:0 4px 12px rgba(13,148,136,.18)}',
            '.dsc-db-plugin-btn:active{transform:scale(.94)}',
            '.dsc-db-plugin-btn[aria-pressed="true"]{border-color:#14b8a6;background:#ccfbf1;color:#0f766e;',
            'box-shadow:0 0 0 2px rgba(20,184,166,.22),0 0 12px rgba(20,184,166,.35);transform:none}',
            '.dsc-db-plugin-btn[aria-pressed="true"]:hover{background:#ccfbf1;border-color:#14b8a6;transform:none}',
            '.dsc-db-plugin-btn[aria-pressed="true"] .ic svg{stroke-width:2}',
            '.dsc-db-plugin-btn[aria-pressed="true"]::after{content:"";position:absolute;top:3px;right:3px;',
            'width:6px;height:6px;border-radius:50%;background:#14b8a6;box-shadow:0 0 0 2px #ccfbf1}',
            '.dsc-db-plugin-btn[aria-disabled="true"]{opacity:.42;pointer-events:none;filter:grayscale(1)}',
            '@media (prefers-color-scheme: dark){',
            '.dsc-db-plugin-btn{background:rgba(30,41,59,.72);border-color:rgba(100,116,139,.45);color:#5eead4}',
            '.dsc-db-plugin-btn:hover{background:rgba(19,78,74,.55);border-color:#0d9488}',
            '.dsc-db-plugin-btn[aria-pressed="true"]{background:rgba(13,148,136,.42);border-color:#2dd4bf;color:#ccfbf1;',
            'box-shadow:0 0 0 2px rgba(45,212,191,.25),0 0 14px rgba(45,212,191,.4)}',
            '.dsc-db-plugin-btn[aria-pressed="true"]:hover{background:rgba(13,148,136,.42);border-color:#2dd4bf}',
            '.dsc-db-plugin-btn[aria-pressed="true"]::after{background:#2dd4bf;box-shadow:0 0 0 2px rgba(13,148,136,.55)}',
            '}',
            '.dsc-db-plugin-btn.dsc-db-hidden{display:none !important}'
        ].join('');
        (document.head || document.documentElement).appendChild(st);
    }

    /* v8 闪烁修复核心：原实现每次 sync 都无条件 insertBefore 移动节点，
       而本文件的 MutationObserver 监听 body 整棵子树的 childList，
       节点一移动立即回调 -> 60ms 后 sync -> 又移动 -> 无限自激环，
       底栏被持续重排/重绘，肉眼即「一闪一闪」。
       现在先比对期望位置，位置已正确时一个 DOM 操作都不做。 */
    function placeOrder() {
        var panel = $('dscToolsExtra');
        if (!panel) return false;
        var moji = $(MOJI_ID);
        var toutiao = $(TOUJI_ID);
        if (!moji && !toutiao) return false;

        var anchor = $('dscDbWikiBtn') || $('dscDbToolModeBtn');
        if (anchor && anchor.parentNode !== panel) anchor = null;

        [moji, toutiao].forEach(function (b) {
            if (!b) return;
            var ok;
            if (anchor) {
                ok = (b.parentNode === panel) && (anchor.nextElementSibling === b);
            } else {
                ok = (b.parentNode === panel) && (b.nextElementSibling === null);
            }
            if (!ok) {
                if (anchor) panel.insertBefore(b, anchor.nextSibling);
                else panel.appendChild(b);
            }
            anchor = b;
        });
        return true;
    }

    function makeBtn(id, svg, label, kind, title) {
        var b = document.createElement('button');
        b.id = id;
        b.type = 'button';
        b.className = 'dsc-db-plugin-btn';
        b.setAttribute('role', 'switch');
        b.setAttribute('aria-label', label);
        b.setAttribute('aria-pressed', 'false');
        b.setAttribute('title', title);
        b.setAttribute('data-plugin', kind);
        var ic = document.createElement('span');
        ic.className = 'ic';
        ic.innerHTML = svg;
        b.appendChild(ic);
        b.addEventListener('click', function (e) {
            e.preventDefault();
            e.stopImmediatePropagation();
            togglePlugin(kind, b);
        }, true);
        return b;
    }

    function ensureButtons() {
        var panel = $('dscToolsExtra');
        if (!panel) return false;
        if (!$(MOJI_ID)) {
            panel.appendChild(makeBtn(
                MOJI_ID, MOJI_SVG,
                '墨迹天气', 'moji',
                T('moji_title')
            ));
        }
        if (!$(TOUJI_ID)) {
            panel.appendChild(makeBtn(
                TOUJI_ID, TOUJIAO_SVG,
                '头条图文', 'toutiao',
                T('toutiao_title')
            ));
        }
        placeOrder();
        return true;
    }

    /* v8：状态签名短路。签名未变化时直接返回，稳态下零 DOM 写、零样式写，
       彻底断掉「定时器/observer 反复改 DOM -> 再触发 observer」的振荡。 */
    var lastSig = '';
    function sig() {
        var has = ($(MOJI_ID) ? '1' : '0') + ($(TOUJI_ID) ? '1' : '0');
        if (!isDbMode()) return 'off:' + has;
        return ['db', has,
            getSwitch(),
            $('dscDbWikiBtn') ? '1' : '0',
            $('dscDbToolModeBtn') ? '1' : '0'
        ].join('|');
    }

    function sync() {
        var now = sig();
        if (now === lastSig) return;   /* 稳态：直接返回，不做任何 DOM/样式写 */
        lastSig = now;
        syncInner();
    }

    function syncInner() {
        var db = isDbMode();
        var moji = $(MOJI_ID);
        var toutiao = $(TOUJI_ID);

        if (!db) {
            if (moji) { moji.classList.add('dsc-db-hidden'); moji.style.display = 'none'; }
            if (toutiao) { toutiao.classList.add('dsc-db-hidden'); toutiao.style.display = 'none'; }
            return;
        }

        ensureStyle();
        if (!ensureButtons()) return;
        placeOrder();

        moji = $(MOJI_ID);
        toutiao = $(TOUJI_ID);
        [moji, toutiao].forEach(function (b) {
            if (!b) return;
            b.classList.remove('dsc-db-hidden');
            b.style.display = '';
            b.removeAttribute('aria-disabled');
        });

        applyState();
    }

    window.dscDbPluginsDiag = function () {
        var out = { dbMode: isDbMode(), switch: getSwitch(), tools: [] };
        [MOJI_ID, TOUJI_ID].forEach(function (id) {
            var b = $(id);
            if (!b) { out.tools.push({ id: id, found: false }); return; }
            var r = b.getBoundingClientRect();
            out.tools.push({
                id: id,
                found: true,
                pressed: b.getAttribute('aria-pressed'),
                display: b.style.display,
                width: Math.round(r.width),
                height: Math.round(r.height),
                left: Math.round(r.left),
                right: Math.round(r.right),
                inViewport: r.width > 0 && r.left >= -1 && r.right <= (window.innerWidth || 0) + 1
            });
        });
        return out;
    };

    window.dscDbPluginSwitchGet = getSwitch;
    window.dscDbPluginSwitchSet = function (kind) {
        var v = setSwitch(kind);
        applyState();
        return v;
    };

    function boot() {
        sync();
        setInterval(sync, SYNC_MS);

        window.addEventListener('dsc:plugin-switch', function () { applyState(); });
        window.addEventListener('storage', function (e) {
            if (e && e.key === SWITCH_KEY) applyState();
        });

        var timer = null;
        function soon() {
            if (timer) return;
            timer = setTimeout(function () {
                timer = null;
                /* v8：仅当按钮缺失（面板被外部重建）时才补建；
                   稳态下不产生任何 DOM 操作，杜绝 observer 自激。 */
                if (!$(MOJI_ID) || !$(TOUJI_ID)) sync();
            }, 200);
        }
        try {
                var mo = new MutationObserver(soon);
            mo.observe(document.body, { childList: true, subtree: true });
        } catch (e) {}
        /* 语言切换后强制绕开签名短路，让按钮 title 文案跟随刷新（仅一次） */
        window.addEventListener('dsc:langchange', function () {
            lastSig = '';
            sync();
        });
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', boot);
    } else {
        boot();
    }
})();
