/* ============================================================
 * dsc-doubao-tools.js —— 豆包专属工具模式按钮（前端）  v2
 *
 * 【v2 修复「看不见 UI」的真因】
 *   旧实现：panel.appendChild(b) —— 把按钮追加到 #dscToolsExtra 末尾。
 *   而 #dscToolsExtra 位于 .dsc-switch-group 内，该容器
 *   overflow-x:auto（deepseek-chat.css:1953）。手机窄屏下，
 *   switch-group 内已有 🌐 / 🧠 / 🧩 + novel + longtext + 工具模式 + 百科
 *   共 7 个按钮（每个 min-width:36px + gap:6px ≈ 288px），
 *   再叠加 .dsc-right-group 约 120px，总宽已超过 360dp 视口。
 *   结论：追加到末尾的专属按钮必然被推到横向滚动区可视范围之外，
 *         用户必须手动横滑才可能看到 —— 表现就是「完全看不见 UI」。
 *   修复：insertBefore(panel.firstChild)，排在最左端，必然落在首屏内。
 *
 * 【v2 其它改动】
 *   · 图标由 emoji 🫘 改为内联 SVG（stroke=currentColor），
 *     不依赖 emoji 字体，也不被 .ic 的 grayscale 滤镜糊成灰块。
 *   · 三类提示全部补齐（多语言）：
 *       ① 进入豆包模式、按钮首次可用  ② 开启成功  ③ 关闭成功
 *     抖音百科开启时仍严格静默：pointer-events:none + 捕获阶段拦截，
 *     不弹任何 toast、不改任何状态（需求原文：点击后没有反应即可）。
 *   · 取消分档：与后端 lib/src/doubao_tools.dart 完全一致 ——
 *     全模型 99 工具 · 5000000000 轮，不再显示 lite/turbo/pro 档位。
 *   · 新增 window.dscDbToolDiag()，可在控制台一键自检
 *     按钮是否存在、是否真的在视口内（getBoundingClientRect 实测）。
 * ============================================================ */
(function () {
    'use strict';

    var BTN_ID = 'dscDbToolModeBtn';
    var SYNC_MS = 600;

    /* 与后端保持一致：禁止分档，全模型统一 99 工具 / 50 亿轮（含 vd_* 虚拟屏幕 11 个）*/
    var DB_TOOLS = 99;
    var DB_ROUNDS = 5000000000;

    var announcedDb = false;   // 本次页面加载是否已提示过「专属工具模式可用」

    function $(id) { return document.getElementById(id); }

    function T(s) {
        try {
            if (window.I18N && window.I18N.t) return window.I18N.t(s);
        } catch (e) {}
        return s;
    }

    /* ---------- 轻量 toast：复用 #dscToastWrap 与 .dsc-toast 样式 ---------- */
    function toast(msg, type) {
        var wrap = $('dscToastWrap');
        if (!wrap) {
            try { console.log('[DB-TOOLS]', msg); } catch (e) {}
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

    /* ---------- 豆包模式判定 ---------- */
    function isDbMode() {
        try {
            if (typeof window.dscDoubaoModeOn === 'function') {
                return !!window.dscDoubaoModeOn();
            }
        } catch (e) {}
        try { return localStorage.getItem('dsc_doubao_mode') === '1'; } catch (e) {}
        return false;
    }

    function dbModel() {
        try {
            if (typeof window.dscDoubaoChatModel === 'function') {
                return String(window.dscDoubaoChatModel() || '');
            }
        } catch (e) {}
        return '';
    }

    /* ---------- 百科是否开启（开启 = 专属按钮必须失效且静默） ---------- */
    function wikiOn() {
        try {
            if (typeof window.dscWikiEffectiveOn === 'function') {
                return !!window.dscWikiEffectiveOn();
            }
        } catch (e) {}
        return false;
    }

    function toolModeOn() {
        try {
            if (typeof window.dscGetToolMode === 'function') {
                return !!window.dscGetToolMode();
            }
        } catch (e) {}
        return false;
    }

    /* ---------- 纯 SVG 图标：豆形轮廓 + 执行闪电 ---------- */
    var ICON_SVG = ''
        + '<svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">'
        + '<ellipse cx="12" cy="12" rx="7.1" ry="8.5" transform="rotate(-18 12 12)"'
        + ' stroke="currentColor" stroke-width="1.7"/>'
        + '<path d="M13.4 8.1 L10.6 12.1 H12.9 L10.9 15.9"'
        + ' stroke="currentColor" stroke-width="1.7"'
        + ' stroke-linecap="round" stroke-linejoin="round"/>'
        + '</svg>';

    /* ---------- 样式（只注入一次） ---------- */
    function ensureStyle() {
        if ($('dscDbToolStyle')) return;
        var st = document.createElement('style');
        st.id = 'dscDbToolStyle';
        st.textContent = [
            /* 纯 SVG：尺寸固定，避免 emoji + 文字把按钮撑宽后又被挤出视口 */
            '#dscDbToolModeBtn{flex:0 0 auto}',
            '#dscDbToolModeBtn .ic{display:block;line-height:0;color:#b45309}',
            '#dscDbToolModeBtn .ic svg{display:block;width:18px;height:18px}',
            '#dscDbToolModeBtn.active{border-color:#f59e0b;',
            'background:#fffbeb;box-shadow:0 0 12px rgba(245,158,11,.30)}',
            '#dscDbToolModeBtn.active .ic{filter:none;opacity:1;color:#b45309}',
            /* 百科开启：不可点、无 hover、无指针事件 → 点击彻底无反应 */
            '#dscDbToolModeBtn.db-locked{opacity:.38;cursor:default;',
            'pointer-events:none;filter:grayscale(1)}',
            '#dscToolModeBtn.dsc-db-hidden{display:none !important}',
            /* 首次注入时轻微脉冲，确保一眼能看到 */
            '@keyframes dscDbPulse{0%{box-shadow:0 0 0 0 rgba(245,158,11,.55)}',
            '70%{box-shadow:0 0 0 10px rgba(245,158,11,0)}',
            '100%{box-shadow:0 0 0 0 rgba(245,158,11,0)}}',
            '#dscDbToolModeBtn.db-pulse{animation:dscDbPulse 1.05s ease-out 2}'
        ].join('');
        (document.head || document.documentElement).appendChild(st);
    }

    /* ---------- 创建按钮：插到最左，保证首屏可见 ---------- */
    function ensureBtn() {
        var b = $(BTN_ID);
        if (b) return b;

        var panel = $('dscToolsExtra');
        var old = $('dscToolModeBtn');
        var ref = $('dscNovelModeBtn') || $('dscLongTextBtn') || $('dscLevelBtn');

        b = document.createElement('button');
        b.id = BTN_ID;
        b.type = 'button';
        b.className = 'dsc-switch-btn';
        b.innerHTML = '<span class="ic">' + ICON_SVG + '</span>';
        b.setAttribute('data-tools', String(DB_TOOLS));
        b.setAttribute('data-rounds', String(DB_ROUNDS));

        if (panel) {
            /* ★ 关键修复：排到最左端（旧实现 appendChild 到末尾 → 被挤出可视区） */
            panel.insertBefore(b, panel.firstChild);
        } else if (old && old.parentNode) {
            old.parentNode.insertBefore(b, old);
        } else if (ref && ref.parentNode) {
            ref.parentNode.insertBefore(b, ref);
        } else {
            return null;
        }

        /* 首次注入：脉冲 + 尽量滚到可见（nearest 不打断用户已滚位置） */
        b.classList.add('db-pulse');
        setTimeout(function () { b.classList.remove('db-pulse'); }, 2400);
        try {
            if (b.scrollIntoView) {
                b.scrollIntoView({ block: 'nearest', inline: 'nearest' });
            }
        } catch (e) {}

        b.addEventListener('click', function (e) {
            e.preventDefault();
            e.stopImmediatePropagation();

            /* 百科开启：彻底静默（不弹提示、不改状态） */
            if (wikiOn()) return;

            var next = !toolModeOn();
            if (typeof window.dscSetToolMode === 'function') {
                window.dscSetToolMode(next);
            }
            if (next) {
                toast(T('豆包専用ツールモードをオンにしました（99 ツール・ラウンド無制限）'), 'success');
            } else {
                toast(T('豆包専用ツールモードをオフにしました'), 'info');
            }
            sync();
        }, true);

        return b;
    }

    /* ---------- 状态同步 ---------- */
    function sync() {
        var db = isDbMode();
        var oldBtn = $('dscToolModeBtn');
        var b = $(BTN_ID);

        /* 非豆包模式：专属按钮隐藏，原按钮恢复 */
        if (!db) {
            if (b) b.style.display = 'none';
            if (oldBtn) oldBtn.classList.remove('dsc-db-hidden');
            announcedDb = false;
            return;
        }

        ensureStyle();
        b = b || ensureBtn();
        if (oldBtn) oldBtn.classList.add('dsc-db-hidden');
        if (!b) return;

        var on = toolModeOn();
        var locked = wikiOn();

        b.style.display = '';
        b.classList.toggle('active', on && !locked);
        b.classList.toggle('db-locked', locked);
        b.setAttribute('data-model', dbModel());
        b.setAttribute('data-tools', String(DB_TOOLS));
        b.setAttribute('data-rounds', String(DB_ROUNDS));
        b.setAttribute('data-locked', locked ? '1' : '0');

        if (locked) {
            b.setAttribute('aria-disabled', 'true');
            b.title = T('抖音百科が開いているため、豆包ツールモードは使用できません');
        } else {
            b.removeAttribute('aria-disabled');
            b.title = on
                ? T('豆包専用ツールモード：オン（クリックでオフ）')
                : T('豆包専用ツールモード：オフ（クリックでオン）');
        }

        /* 进入豆包模式后首次可用 → 提示一次（需求：打开时必须有提示） */
        if (!announcedDb) {
            announcedDb = true;
            toast(T('豆包専用ツールモードが利用可能です（99 ツール・ラウンド無制限）'), 'info');
        }
    }

    /* ---------- 对外 API ---------- */
    window.dscDbToolModeOn = function () {
        try {
            return isDbMode() && toolModeOn();
        } catch (e) { return false; }
    };
    window.dscDbToolSync = sync;
    window.dscDbToolLocked = function () { return isDbMode() && wikiOn(); };
    window.dscDbToolTier = function () {
        return { code: 'unified', tools: DB_TOOLS, rounds: DB_ROUNDS };
    };

    /* 自检：确认按钮真的存在且落在视口内（排查「看不见」专用） */
    window.dscDbToolDiag = function () {
        var b = $(BTN_ID);
        var group = document.querySelector('.dsc-switch-group');
        if (!b) return { found: false, hint: '按钮尚未创建（未处于豆包模式？）' };
        var r = b.getBoundingClientRect();
        var gr = group ? group.getBoundingClientRect() : null;
        var vw = window.innerWidth || document.documentElement.clientWidth;
        var inViewport = r.width > 0 && r.height > 0 &&
            r.left >= -1 && r.right <= vw + 1;
        return {
            found: true,
            display: b.style.display,
            width: Math.round(r.width),
            height: Math.round(r.height),
            left: Math.round(r.left),
            right: Math.round(r.right),
            viewportWidth: vw,
            groupScrollLeft: group ? Math.round(group.scrollLeft) : null,
            groupClientWidth: gr ? Math.round(gr.clientWidth) : null,
            inViewport: inViewport
        };
    };

    /* ---------- 启动 ---------- */
    function boot() {
        sync();
        setInterval(sync, SYNC_MS);

        /* 工具栏会被 deepseek-chat.js 多次整体重建（ensureToolModeBtn），
           原按钮一被重建就可能露出来；用 MutationObserver 立即补回。
           50ms 防抖避免流式渲染时每个气泡都触发一次 sync。 */
        var timer = null;
        function soon() {
            if (timer) return;
            timer = setTimeout(function () {
                timer = null;
                sync();
            }, 50);
        }
        try {
            var mo = new MutationObserver(soon);
            mo.observe(document.body, { childList: true, subtree: true });
        } catch (e) {}
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', boot);
    } else {
        boot();
    }
})();
