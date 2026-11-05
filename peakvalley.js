// peakvalley.js — ピーク／オフピーク通知前端（移植自 chicheng-peak 插件）
//
// 役割：
// 1. ページ端の呼吸する枠線（ピークはオレンジ / オフピークはブルー）、グローの方向、流れる光（コメット）
// 2. 入力欄の光効果：DeepSeek チャットの入力欄コントロールに追従し、設定はページ枠と完全に独立
//   3. 状態バッジ：PC / スマホ各自四角定位
//   4. 浏览器ローカル通知
// 5. 設定パネル：状態 / 時間帯 / 枠 / 入力欄 / バッジ / 通知 / プッシュ通知 / この機能について
//
// バックエンド：/api/peakvalley/*（peakvalley.go）
// 時間帯（北京時間）：ピーク 09:00–12:00、14:00–18:00、それ以外はオフピーク。

(function () {
    'use strict';

    // ★ i18n ヘルパー：引数付きで辞書を引く（無ければ原文）
    function pvT(s) {
        try {
            if (!(window.I18N && window.I18N.t)) return s;
            var args = [s].concat(Array.prototype.slice.call(arguments, 1));
            return window.I18N.t.apply(null, args);
        } catch (e) { return s; }
    }

    var API_BASE = '/api/peakvalley/';

    // 実行時の状態
    var cfg = null;          // 保存済み配置
    var status = null;       // 直近の status ペイロード
    var defaults = null;     // サーバー側の既定値
    var channelTypes = [];   // チャネルの種類元数据
    var timezones = [];
    var dataPath = '';
    var work = null;         // 編集中的配置副本

    var pollTimer = null;
    var posTimer = null;
    var rafId = null;
    var lastFrame = 0;
    var flowPhase = 0;

    var lastPhase = null;
    var lastPeakFired = '';
    var lastValleyFired = '';

    var modal = null;        // 設定パネルのルートノード
    var modalBody = null;
    var countdownTimer = null;
    var editingChannel = null;   // 正在編集的渠道
    var channelMsg = '';

    // ============================================================ 基本ユーティリティ

    function $(id) {
        return document.getElementById(id);
    }

    function ce(tag, cls, text) {
        var e = document.createElement(tag);
        if (cls) { e.className = cls; }
        if (text !== undefined && text !== null) { e.textContent = text; }
        return e;
    }

    function clone(o) {
        return JSON.parse(JSON.stringify(o));
    }

    function pad2(n) {
        return (n < 10 ? '0' : '') + n;
    }

    function clamp(v, lo, hi) {
        v = Number(v);
        if (isNaN(v)) { return lo; }
        return Math.min(hi, Math.max(lo, v));
    }

    /** #rrggbb → rgba(...) */
    function rgba(hex, a) {
        var m = /^#?([0-9a-f]{6})$/i.exec(String(hex || ''));
        if (!m) { return String(hex || '#f97316'); }
        var n = parseInt(m[1], 16);
        return 'rgba(' + ((n >> 16) & 255) + ',' + ((n >> 8) & 255) + ',' + (n & 255) + ',' + a + ')';
    }

    function api(method, payload) {
        return fetch(API_BASE + method, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload || {}),
            credentials: 'same-origin'
        }).then(function (res) {
            return res.json();
        }).then(function (body) {
            if (!body || body.ok !== true) {
                var msg = body && body.error && body.error.message ? body.error.message : 'リクエストに失敗';
                var err = new Error(msg);
                err.code = body && body.error ? body.error.code : 'api-error';
                throw err;
            }
            return body.value;
        });
    }

    var toastEl = null;
    var toastTimer = null;
    function toast(msg) {
        if (!toastEl) {
            toastEl = ce('div', 'pv-toast');
            document.body.appendChild(toastEl);
        }
        toastEl.textContent = msg;
        toastEl.className = 'pv-toast pv-toast-show';
        if (toastTimer) { clearTimeout(toastTimer); }
        toastTimer = setTimeout(function () {
            toastEl.className = 'pv-toast';
        }, 2400);
    }

    // ============================================================ 段階のローカル計算
    // 設定パネルの即時プレビュー用：サーバー往復に依存しない

    function parseHM(s) {
        var m = /^(\d{1,2}):([0-5]\d)$/.exec(String(s || '').trim());
        if (!m) { return -1; }
        var h = parseInt(m[1], 10);
        if (h > 23) { return -1; }
        return h * 60 + parseInt(m[2], 10);
    }

    function localNowMinutes(tz) {
        var d = new Date();
        try {
            var fmt = new Intl.DateTimeFormat('en-CA', {
                timeZone: tz, hour12: false,
                year: 'numeric', month: '2-digit', day: '2-digit',
                hour: '2-digit', minute: '2-digit'
            });
            var parts = {};
            var arr = fmt.formatToParts ? fmt.formatToParts(d) : [];
            for (var i = 0; i < arr.length; i += 1) { parts[arr[i].type] = arr[i].value; }
            var h = parseInt(parts.hour, 10);
            var mi = parseInt(parts.minute, 10);
            if (!isNaN(h) && !isNaN(mi)) {
                if (h === 24) { h = 0; }
                return h * 60 + mi;
            }
        } catch (e) { /* 回退到本地タイムゾーン */ }
        return d.getHours() * 60 + d.getMinutes();
    }

    function isPeakAt(min, windows) {
        if (!windows) { return false; }
        for (var i = 0; i < windows.length; i += 1) {
            var s = parseHM(windows[i].start);
            var e = parseHM(windows[i].end);
            if (s < 0 || e < 0 || e <= s) { continue; }
            if (min >= s && min < e) { return true; }
        }
        return false;
    }

    function localPhase(override, windows, tz) {
        if (override === 'peak') { return 'peak'; }
        if (override === 'valley') { return 'valley'; }
        return isPeakAt(localNowMinutes(tz || (cfg && cfg.timezone) || 'Asia/Shanghai'), windows) ? 'peak' : 'valley';
    }

    function phaseLabel(phase) {
        return phase === 'peak' ? 'ピーク時間帯' : 'オフピーク時間帯';
    }

    // ============================================================ オーバーレイ

    var ov = {
        root: null, ring: null, glow: null, svg: null, rect: null,
        composer: null, cglow: null, csvg: null, crect: null
    };

    function ensureOverlay() {
        if (ov.root && document.body.contains(ov.root)) { return; }

        var root = ce('div');
        root.id = 'pv-root';

        var ring = ce('div');
        ring.id = 'pv-ring';

        var glow = ce('div');
        glow.id = 'pv-glow';

        // 流光：SVG のストローク破線で実装し、枠に沿って等速で光が走る
        var svgNS = 'http://www.w3.org/2000/svg';
        var svg = document.createElementNS(svgNS, 'svg');
        svg.id = 'pv-svg';
        svg.setAttribute('preserveAspectRatio', 'none');
        var rect = document.createElementNS(svgNS, 'rect');
        rect.setAttribute('fill', 'none');
        rect.setAttribute('x', '1');
        rect.setAttribute('y', '1');
        rect.setAttribute('rx', '4');
        rect.setAttribute('stroke-linecap', 'round');
        svg.appendChild(rect);

        root.appendChild(ring);
        root.appendChild(glow);
        root.appendChild(svg);
        document.body.appendChild(root);

        var comp = ce('div');
        comp.id = 'pv-composer';
        var cglow = ce('div');
        cglow.id = 'pv-composer-glow';
        var csvg = document.createElementNS(svgNS, 'svg');
        csvg.id = 'pv-composer-svg';
        csvg.setAttribute('preserveAspectRatio', 'none');
        var crect = document.createElementNS(svgNS, 'rect');
        crect.setAttribute('fill', 'none');
        crect.setAttribute('x', '1');
        crect.setAttribute('y', '1');
        crect.setAttribute('stroke-linecap', 'round');
        csvg.appendChild(crect);
        comp.appendChild(cglow);
        comp.appendChild(csvg);
        document.body.appendChild(comp);

        var badge = ce('div');
        badge.id = 'pv-badge';
        badge.title = 'ピーク／オフピーク通知（タップで設定を開く）';
        badge.addEventListener('click', function () { openSettings(); });
        document.body.appendChild(badge);

        ov.root = root;
        ov.ring = ring;
        ov.glow = glow;
        ov.svg = svg;
        ov.rect = rect;
        ov.composer = comp;
        ov.cglow = cglow;
        ov.csvg = csvg;
        ov.crect = crect;
        ov.badge = badge;
    }

    /** 適用範囲：既定では DeepSeek チャットを開いたときに有効 */
    function scopeActive() {
        var scope = (work && work.scope) || (cfg && cfg.scope) || 'deepseek';
        if (scope === 'global') { return true; }
        var app = $('deepseekChatApp');
        if (!app) { return false; }
        return app.classList && app.classList.contains('open');
    }

    function hideAll() {
        if (!ov.root) { return; }
        ov.root.style.display = 'none';
        ov.composer.style.display = 'none';
        ov.badge.style.display = 'none';
    }

    /** 配色/サイズ/アニメーションをページ枠レイヤーに適用する */
    function applyEdgeLayer(edge, phase) {
        var color = phase === 'peak' ? edge.peakColor : edge.valleyColor;
        var width = clamp(edge.width, 1, 14);
        var glow = clamp(edge.glow, 0, 80);
        var opacity = clamp(edge.opacity, 0.2, 1);
        var speed = clamp(edge.breathingSpeed, 0.5, 10);
        var dirIn = edge.glowDirection === 'in';

        ov.root.style.display = 'block';
        ov.ring.style.border = width + 'px solid ' + color;
        ov.ring.style.opacity = String(opacity);

        // グロー：呼吸アニメーションは opacity のみ変更（コンポジット層で処理し、リフローを起こさない）
        ov.glow.style.boxShadow = (dirIn ? 'inset ' : '') + '0 0 ' + glow + 'px ' + color;
        if (edge.animation === 'breathing' && glow > 0) {
            ov.glow.className = 'pv-anim-breathing';
            ov.glow.style.animationDuration = speed + 's';
            ov.glow.style.opacity = '';
        } else if (edge.animation === 'solid' && glow > 0) {
            ov.glow.className = '';
            ov.glow.style.animationDuration = '';
            ov.glow.style.opacity = String(opacity);
        } else {
            ov.glow.className = '';
            ov.glow.style.animationDuration = '';
            ov.glow.style.opacity = '0';
        }

        // 流光
        if (edge.flow) {
            ov.svg.style.display = 'block';
            ov.rect.setAttribute('stroke', color);
            ov.rect.setAttribute('stroke-width', String(Math.max(2, width)));
            ov.rect.setAttribute('opacity', String(Math.min(1, opacity + 0.35)));
        } else {
            ov.svg.style.display = 'none';
        }
        return speed;
    }

    /** 入力欄の光効果图层 */
    function applyComposerLayer(comp, phase) {
        var color = phase === 'peak' ? comp.peakColor : comp.valleyColor;
        var width = clamp(comp.width, 1, 14);
        var glow = clamp(comp.glow, 0, 80);
        var opacity = clamp(comp.opacity, 0.2, 1);
        var speed = clamp(comp.breathingSpeed, 0.5, 10);
        var dirIn = comp.glowDirection === 'in';

        ov.composer.style.border = width + 'px solid ' + color;
        ov.composer.style.opacity = String(opacity);
        ov.cglow.style.boxShadow = (dirIn ? 'inset ' : '') + '0 0 ' + glow + 'px ' + color;

        if (comp.animation === 'breathing' && glow > 0) {
            ov.cglow.className = 'pv-anim-breathing';
            ov.cglow.style.animationDuration = speed + 's';
        } else if (comp.animation === 'solid' && glow > 0) {
            ov.cglow.className = '';
            ov.cglow.style.opacity = String(opacity);
        } else {
            ov.cglow.className = '';
            ov.cglow.style.opacity = '0';
        }

        if (comp.flow) {
            ov.csvg.style.display = 'block';
            ov.crect.setAttribute('stroke', color);
            ov.crect.setAttribute('stroke-width', String(Math.max(2, width)));
            ov.crect.setAttribute('opacity', String(Math.min(1, opacity + 0.35)));
        } else {
            ov.csvg.style.display = 'none';
        }
    }

    function applyOverlay(s) {
        ensureOverlay();
        if (!s || !s.enabled || !scopeActive()) {
            hideAll();
            return;
        }
        var phase = s.phase || 'valley';

        // ---- ページ端
        var edge = s.edge || {};
        if (edge.enabled !== false) {
            applyEdgeLayer(edge, phase);
        } else {
            ov.ring.style.border = 'none';
            ov.ring.style.opacity = '0';
            ov.glow.style.opacity = '0';
            ov.svg.style.display = 'none';
            ov.root.style.display = 'block'; // バッジ/入力欄は独立して有効になる場合があります
        }

        // ---- 入力欄の光効果
        var comp = s.composer || {};
        if (comp.enabled !== false) {
            applyComposerLayer(comp, phase);
            positionComposer();
        } else {
            ov.composer.style.display = 'none';
        }

        // ---- 状態バッジ
        var bd = s.badge || {};
        if (bd.enabled !== false) {
            applyBadge(bd, phase);
        } else {
            ov.badge.style.display = 'none';
        }

        // ページ端をすべてオフかつバッジ/入力欄なしのとき完全に非表示
        var anyEdge = edge.enabled !== false;
        var anyComp = comp.enabled !== false;
        var anyBadge = bd.enabled !== false;
        if (!anyEdge && !anyComp && !anyBadge) {
            hideAll();
        }
    }

    function isMobileish() {
        try {
            if (typeof window.matchMedia !== 'function') { return window.innerWidth <= 768; }
            return window.matchMedia('(max-width: 768px)').matches ||
                window.matchMedia('(hover: none) and (pointer: coarse)').matches;
        } catch (e) {
            return window.innerWidth <= 768;
        }
    }

    function applyBadge(bd, phase) {
        var p = (isMobileish() ? bd.mobile : bd.desktop) || { corner: 'br', x: 18, y: 18 };
        var corner = p.corner || 'br';
        var x = Math.max(0, Math.round(Number(p.x) || 0));
        var y = Math.max(0, Math.round(Number(p.y) || 0));
        var edge = (status && status.edge) || (work && work.edge) || {};
        var color = phase === 'peak'
            ? (edge.peakColor || '#f97316')
            : (edge.valleyColor || '#38bdf8');

        var badge = ov.badge;
        badge.style.display = 'inline-flex';
        badge.style.background = color;
        badge.style.left = (corner === 'tl' || corner === 'bl') ? x + 'px' : '';
        badge.style.right = (corner === 'tr' || corner === 'br') ? x + 'px' : '';
        badge.style.top = (corner === 'tl' || corner === 'tr') ? y + 'px' : '';
        badge.style.bottom = (corner === 'bl' || corner === 'br') ? y + 'px' : '';

        if (badge.getAttribute('data-phase') !== phase) {
            badge.textContent = '';
            badge.appendChild(ce('span', 'pv-dot pv-dot-live'));
            badge.appendChild(ce('span', '', phaseLabel(phase)));
            badge.setAttribute('data-phase', phase);
        }
    }

    /** DeepSeek チャットの入力欄コンテナを取得（.dsc-input-wrap を優先） */
    function composerEl() {
        var input = $('dscInput');
        if (input) {
            if (input.closest) {
                var box = input.closest('.dsc-input-wrap');
                if (box) { return box; }
            }
            return input;
        }
        // フォールバック：可視の textarea（ダイアログ内の入力欄を除く）
        var nodes = document.querySelectorAll('textarea');
        for (var i = 0; i < nodes.length; i += 1) {
            var n = nodes[i];
            if (n.closest && n.closest('.pv-overlay')) { continue; }
            if (n.closest && n.closest('.dsc-modal-overlay')) { continue; }
            var r = n.getBoundingClientRect();
            if (r.width >= 80 && r.height >= 16) { return n; }
        }
        return null;
    }

    function positionComposer() {
        if (!ov.composer) { return; }
        var comp = (work && work.composer) || (cfg && cfg.composer) || {};
        if (comp.enabled === false || !scopeActive() || !status && !work) {
            ov.composer.style.display = 'none';
            return;
        }
        var el = composerEl();
        if (!el) {
            ov.composer.style.display = 'none';
            return;
        }
        var r = el.getBoundingClientRect();
        if (!r || r.width < 40 || r.height < 12) {
            ov.composer.style.display = 'none';
            return;
        }
        var radius = '12px';
        try {
            var cs = window.getComputedStyle ? window.getComputedStyle(el).borderRadius : '';
            if (cs && cs !== '0px' && cs !== '') { radius = cs; }
        } catch (e) { /* 既定値を保持 */ }

        ov.composer.style.display = 'block';
        ov.composer.style.left = Math.round(r.left) + 'px';
        ov.composer.style.top = Math.round(r.top) + 'px';
        ov.composer.style.width = Math.round(r.width) + 'px';
        ov.composer.style.height = Math.round(r.height) + 'px';
        ov.composer.style.borderRadius = radius;
        ov.cglow.style.borderRadius = radius;

        // 流れる光のパス寸法
        ov.crect.setAttribute('width', String(Math.max(0, Math.round(r.width) - 2)));
        ov.crect.setAttribute('height', String(Math.max(0, Math.round(r.height) - 2)));
        ov.crect.setAttribute('rx', String(parseFloat(radius) || 10));
    }

    /** 流れる光のアニメーション：stroke-dashoffset で矩形に沿って等速で光を走らせる（互換性が最良） */
    function flowFrame(ts) {
        rafId = null;
        var now = ts || Date.now();
        var dt = lastFrame ? Math.min(64, now - lastFrame) : 16;
        lastFrame = now;

        var edge = (work && work.edge) || (status && status.edge) || {};
        var comp = (work && work.composer) || (status && status.composer) || {};
        var need = (edge.flow === true) || (comp.flow === true);
        if (!need || !scopeActive()) {
            lastFrame = 0;
            return;
        }

        flowPhase += dt / 1000;

        if (edge.flow === true && ov.svg.style.display !== 'none') {
            var W = ov.root.clientWidth || window.innerWidth;
            var H = ov.root.clientHeight || window.innerHeight;
            var per = 2 * (W + H);
            var dash = Math.max(40, Math.min(140, Math.round(per * 0.08)));
            var speed = clamp(edge.flowSpeed, 2, 24);
            var off = -flowPhase * (per / speed);
            ov.rect.setAttribute('stroke-dasharray', dash + ' ' + Math.max(1, per - dash));
            ov.rect.setAttribute('stroke-dashoffset', String(off % per));
        }
        if (comp.flow === true && ov.csvg.style.display !== 'none') {
            var w = parseInt(ov.composer.style.width, 10) || 0;
            var h = parseInt(ov.composer.style.height, 10) || 0;
            var per2 = 2 * (w + h);
            if (per2 > 0) {
                var dash2 = Math.max(18, Math.min(70, Math.round(per2 * 0.16)));
                var speed2 = clamp(comp.flowSpeed, 2, 24);
                var off2 = -flowPhase * (per2 / speed2);
                ov.crect.setAttribute('stroke-dasharray', dash2 + ' ' + Math.max(1, per2 - dash2));
                ov.crect.setAttribute('stroke-dashoffset', String(off2 % per2));
            }
        }
        rafId = requestAnimationFrame(flowFrame);
    }

    function ensureFlowLoop() {
        if (rafId !== null) { return; }
        if (typeof requestAnimationFrame !== 'function') { return; }
        lastFrame = 0;
        rafId = requestAnimationFrame(flowFrame);
    }

    function startTracking() {
        if (posTimer !== null) { return; }
        positionComposer();
        ensureFlowLoop();
        posTimer = setInterval(function () {
            positionComposer();
            updateBadgePositionOnly();
        }, 250);
        window.addEventListener('resize', positionComposer);
        window.addEventListener('scroll', positionComposer, true);
        document.addEventListener('focusin', positionComposer);
        document.addEventListener('focusout', positionComposer);
        document.addEventListener('input', positionComposer, true);
        try {
            if (window.visualViewport) {
                window.visualViewport.addEventListener('resize', positionComposer);
                window.visualViewport.addEventListener('scroll', positionComposer);
            }
        } catch (e) { /* ignore */ }
    }

    function updateBadgePositionOnly() {
        var bd = (work && work.badge) || (status && status.badge);
        if (!bd || bd.enabled === false) { return; }
        var phase = (status && status.phase) || localPhase(
            (work && work.override) || 'auto',
            (work && work.windows) || (cfg && cfg.windows),
            (work && work.timezone) || (cfg && cfg.timezone)
        );
        applyBadge(bd, phase);
    }

    // ============================================================ ローカル通知

    function notifySupported() {
        return typeof window !== 'undefined' && 'Notification' in window;
    }

    function notify(title, body) {
        if (!notifySupported()) { return; }
        if (Notification.permission !== 'granted') { return; }
        try {
            new Notification(String(title), { body: String(body), tag: 'peakvalley' });
        } catch (e) { /* 一部のモバイルブラウザは直接構築を許可しない */ }
    }

    function detectNotify(s) {
        if (!s || !s.localNotify || !s.localNotify.enabled) { return; }
        var title = '';
        var body = '';
        if (s.localNotify.onTransition !== false && s.phase && lastPhase !== null && s.phase !== lastPhase) {
            var peakNow = s.phase === 'peak';
            title = peakNow ? 'DeepSeek ピーク時間帯が開始' : 'DeepSeek オフピーク時間帯が開始';
            body = peakNow ? '現在はピーク時間帯（09:00–12:00 / 14:00–18:00）' : '現在はオフピーク時間帯（アイドル時間、料金はピークの約半額）';
        } else if (s.localNotify.onReminder === true && s.reminders) {
            var pk = s.reminders.peak ? s.reminders.peak.lastFiredAt : '';
            var vl = s.reminders.valley ? s.reminders.valley.lastFiredAt : '';
            if (pk && pk !== lastPeakFired) {
                title = (s.reminders.peak.title || 'ピーク時間帯の通知');
                body = 'プッシュチャネルでピーク時間帯の通知を送信しました';
            } else if (vl && vl !== lastValleyFired) {
                title = (s.reminders.valley.title || 'オフピーク時間帯の通知');
                body = 'プッシュチャネルでオフピーク時間帯の通知を送信しました';
            }
            lastPeakFired = pk || '';
            lastValleyFired = vl || '';
        }
        lastPhase = s.phase;
        if (title) { notify(title, body); }
    }

    // ============================================================ ポーリング

    function startPolling(seconds) {
        stopPolling();
        var secs = clamp(seconds || 15, 5, 120);
        pollTimer = setInterval(poll, secs * 1000);
    }

    function stopPolling() {
        if (pollTimer !== null) {
            clearInterval(pollTimer);
            pollTimer = null;
        }
    }

    function poll() {
        api('status').then(function (s) {
            status = s;
            if (!work) { applyOverlay(s); } else { applyOverlay(previewStatus()); }
            detectNotify(s);
            if (modal && modal.classList.contains('pv-open')) {
                updateStatusCard();
            }
        }).catch(function (e) {
            // サーバー不通：オーバーレイを隠し、古い状態の残像で誤解させない
            hideAll();
        });
    }

    // ============================================================ 設定面板

    function previewStatus() {
        var w = work || cfg;
        if (!w) { return null; }
        return {
            enabled: w.enabled,
            scope: w.scope,
            phase: localPhase(w.override, w.windows, w.timezone),
            edge: w.edge,
            composer: w.composer,
            badge: w.badge
        };
    }

    function refreshPreview() {
        applyOverlay(previewStatus());
        ensureFlowLoop();
    }

    // ---- 汎用コントロール

    function mkSwitch(checked, onChange) {
        var wrap = ce('label', 'pv-switch');
        var input = document.createElement('input');
        input.type = 'checkbox';
        input.checked = !!checked;
        input.addEventListener('change', function () { onChange(input.checked); });
        wrap.appendChild(input);
        wrap.appendChild(ce('span', 'pv-switch-track'));
        return wrap;
    }

    function mkRange(min, max, step, value, unit, onChange) {
        var box = ce('div', 'pv-row');
        box.style.flex = 'none';
        var input = ce('input', 'pv-range');
        input.type = 'range';
        input.min = String(min);
        input.max = String(max);
        input.step = String(step);
        input.value = String(value);
        var tag = ce('span', 'pv-val', fmtNum(value) + (unit || ''));
        input.addEventListener('input', function () {
            var v = parseFloat(input.value);
            tag.textContent = fmtNum(v) + (unit || '');
            onChange(v);
        });
        box.appendChild(input);
        box.appendChild(tag);
        return box;
    }

    function fmtNum(v) {
        var n = Number(v);
        if (isNaN(n)) { return '0'; }
        return Math.abs(n - Math.round(n)) < 0.001 ? String(Math.round(n)) : n.toFixed(2).replace(/0$/, '');
    }

    function mkSelect(options, value, onChange) {
        var sel = ce('select', 'pv-select');
        sel.style.width = 'auto';
        sel.style.minWidth = '110px';
        for (var i = 0; i < options.length; i += 1) {
            var o = document.createElement('option');
            o.value = options[i].value;
            o.textContent = options[i].label;
            if (String(options[i].value) === String(value)) { o.selected = true; }
            sel.appendChild(o);
        }
        sel.addEventListener('change', function () { onChange(sel.value); });
        return sel;
    }

    function mkColor(value, onChange) {
        var box = ce('div', 'pv-row');
        box.style.flex = 'none';
        box.style.gap = '6px';
        var input = ce('input', 'pv-color');
        input.type = 'color';
        input.value = value || '#f97316';
        var text = ce('input', 'pv-input pv-input-sm');
        text.type = 'text';
        text.value = (value || '#f97316').toUpperCase();
        input.addEventListener('input', function () {
            text.value = input.value.toUpperCase();
            onChange(input.value);
        });
        text.addEventListener('change', function () {
            var v = text.value.trim();
            if (/^#[0-9a-fA-F]{6}$/.test(v)) {
                input.value = v;
                onChange(v);
            } else {
                text.value = input.value.toUpperCase();
            }
        });
        box.appendChild(input);
        box.appendChild(text);
        return box;
    }

    function mkText(value, placeholder, onChange) {
        var input = ce('input', 'pv-input');
        input.type = 'text';
        input.value = value || '';
        input.placeholder = placeholder || '';
        input.addEventListener('input', function () { onChange(input.value); });
        return input;
    }

    function mkTextarea(value, placeholder, onChange) {
        var ta = ce('textarea', 'pv-textarea');
        ta.value = value || '';
        ta.placeholder = placeholder || '';
        ta.addEventListener('input', function () { onChange(ta.value); });
        return ta;
    }

    /** 一行：左タグ + 右控件 */
    function row(name, help, ctrl) {
        var wrap = ce('div', 'pv-row');
        var lab = ce('div', 'pv-label');
        lab.appendChild(ce('div', 'pv-label-name', name));
        if (help) { lab.appendChild(ce('div', 'pv-label-help', help)); }
        wrap.appendChild(lab);
        wrap.appendChild(ctrl);
        return wrap;
    }

    function card(title, desc) {
        var c = ce('div', 'pv-card');
        var head = ce('div', 'pv-card-head');
        head.appendChild(ce('div', 'pv-card-title', title));
        if (desc) { head.appendChild(ce('div', 'pv-card-desc', desc)); }
        c.appendChild(head);
        return c;
    }

    function btn(label, cls, onClick) {
        var b = ce('button', 'pv-btn' + (cls ? ' ' + cls : ''), label);
        b.type = 'button';
        b.addEventListener('click', onClick);
        return b;
    }

    // ---- 面板骨架

    function ensureModal() {
        if (modal && document.body.contains(modal)) { return; }
        var overlay = ce('div', 'pv-overlay');
        overlay.id = 'pvOverlay';

        var sheet = ce('div', 'pv-sheet');

        var head = ce('div', 'pv-head');
        head.appendChild(ce('div', 'pv-head-icon', '🏔️'));
        var headText = ce('div', 'pv-head-text');
        headText.appendChild(ce('div', 'pv-head-title', 'ピーク／オフピーク通知'));
        headText.appendChild(ce('div', 'pv-head-sub', 'DeepSeek ピーク／オフピーク時間帯 · 枠の光効果 · プッシュ通知'));
        head.appendChild(headText);
        var closeBtn = ce('button', 'pv-close', '✕');
        closeBtn.type = 'button';
        closeBtn.title = '閉じる';
        closeBtn.addEventListener('click', function () { closeSettings(); });
        head.appendChild(closeBtn);

        var body = ce('div', 'pv-body');

        var foot = ce('div', 'pv-foot');
        var resetAll = btn('すべて既定に戻す', 'pv-btn-ghost pv-btn-sm', function () {
            if (!confirm('すべての外観と通知の設定を既定値に戻します（プッシュチャネルは保持）。よろしいですか？')) { return; }
            api('reset', { section: 'all' }).then(function (v) {
                cfg = v.config;
                work = clone(cfg);
                renderBody();
                refreshPreview();
                toast('既定に戻しました');
            }).catch(function (e) { toast('復元に失敗：' + e.message); });
        });
        foot.appendChild(resetAll);
        foot.appendChild(ce('div', 'pv-foot-spacer'));
        foot.appendChild(btn('閉じる', '', function () { closeSettings(); }));
        foot.appendChild(btn('保存', 'pv-btn-primary', saveConfig));

        sheet.appendChild(head);
        sheet.appendChild(body);
        sheet.appendChild(foot);
        overlay.appendChild(sheet);
        document.body.appendChild(overlay);

        overlay.addEventListener('click', function (e) {
            if (e.target === overlay) { closeSettings(); }
        });

        modal = overlay;
        modalBody = body;

        // 実際の可視高さが変わったとき（ブラウザツールバーの出入り、縦横切替、ソフトキーボード表示）に CSS へ同期
        var sync = function () { syncViewportVar(); };
        window.addEventListener('resize', sync);
        window.addEventListener('orientationchange', sync);
        if (window.visualViewport) {
            window.visualViewport.addEventListener('resize', sync);
            window.visualViewport.addEventListener('scroll', sync);
        }
    }

    // 「実際の可視高さ」を --pv-vh に書き込み、パネルが可視領域を超えないようにする
    function syncViewportVar() {
        if (!modal) { return; }
        var vh = (window.visualViewport && window.visualViewport.height) || window.innerHeight || 0;
        var cap = window.innerHeight || vh;
        var h = Math.min(vh, cap);
        if (h > 0) { modal.style.setProperty('--pv-vh', Math.round(h) + 'px'); }
    }

    function openSettings() {
        ensureModal();
        syncViewportVar();
        modalBody.innerHTML = '';
        modalBody.appendChild(ce('div', 'pv-empty', '読み込み中…'));
        modal.classList.add('pv-open');

        api('config').then(function (v) {
            cfg = v.config;
            defaults = v.defaults;
            channelTypes = v.channelTypes || [];
            timezones = v.timezones || [];
            dataPath = v.dataPath || '';
            work = clone(cfg);
            editingChannel = null;
            renderBody();
            refreshPreview();
            startCountdown();
            // パネルを開いたときに状態を 1 回更新し、段階とカウントダウンを最新に保つ
            poll();
        }).catch(function (e) {
            modalBody.innerHTML = '';
            var err = ce('div', 'pv-empty', pvT('読み込みに失敗：{0}（サービスが起動しているか確認してください）', e.message));
            modalBody.appendChild(err);
        });
    }

    function closeSettings() {
        if (modal) { modal.classList.remove('pv-open'); }
        stopCountdown();
        editingChannel = null;
        // 放弃未保存的改动，回到保存済み状态
        work = null;
        applyOverlay(status);
    }

    function startCountdown() {
        stopCountdown();
        countdownTimer = setInterval(function () {
            updateStatusCard();
        }, 1000);
    }

    function stopCountdown() {
        if (countdownTimer !== null) {
            clearInterval(countdownTimer);
            countdownTimer = null;
        }
    }

    function saveConfig() {
        if (!work) { return; }
        api('save', { config: work }).then(function (v) {
            cfg = v.config;
            status = v.status;
            work = clone(cfg);
            renderBody();
            applyOverlay(status);
            ensureFlowLoop();
            startPolling(cfg.pollSeconds);
            toast((window.I18N&&window.I18N.t)?window.I18N.t('保存済み'):'保存済み');
        }).catch(function (e) {
            toast('保存に失敗：' + e.message);
        });
    }

    // ---- 面板渲染

    function renderBody() {
        if (!modalBody) { return; }
        modalBody.innerHTML = '';
        modalBody.appendChild(buildStatusCard());
        modalBody.appendChild(buildWindowsCard());
        modalBody.appendChild(buildEdgeCard());
        modalBody.appendChild(buildComposerCard());
        modalBody.appendChild(buildBadgeCard());
        modalBody.appendChild(buildNotifyCard());
        modalBody.appendChild(buildChannelCard());
        modalBody.appendChild(buildReminderCard('peak'));
        modalBody.appendChild(buildReminderCard('valley'));
        modalBody.appendChild(buildAboutCard());
    }

    // ---- 状態カード

    var statusCardRefs = {};

    function buildStatusCard() {
        var c = card('現在の状態', '現在の時間帯、次の切替までのカウントダウン、手動上書き。');
        var line = ce('div', 'pv-row');

        var pill = ce('span', 'pv-pill');
        pill.appendChild(ce('span', 'pv-pill-dot'));
        var pillText = ce('span', '', '—');
        pill.appendChild(pillText);
        line.appendChild(pill);

        var info = ce('div', 'pv-stat-line');
        var nextText = ce('span', 'pv-mono', '—');
        info.appendChild(nextText);
        line.appendChild(info);
        c.appendChild(line);

        statusCardRefs = { pill: pill, pillText: pillText, nextText: nextText };
        updateStatusCard();

        c.appendChild(row('ピーク／オフピーク通知を有効化', 'メインスイッチ。オフにすると枠・光効果・バッジ・プッシュ通知がすべて停止します。',
            mkSwitch(work.enabled, function (v) {
                work.enabled = v;
                refreshPreview();
            })));

        c.appendChild(row('適用範囲', '既定では DeepSeek チャット画面のみで有効になり、他のページに影響しません。',
            mkSelect([
                { value: 'deepseek', label: 'DeepSeek チャットのみ' },
                { value: 'global', label: 'すべてのページ' }
            ], work.scope, function (v) {
                work.scope = v;
                refreshPreview();
                positionComposer();
            })));

        c.appendChild(row('判定モード', '自動判定は下記の時間帯で計算します。強制モードは見た目の確認用です。',
            mkSelect([
                { value: 'auto', label: '自動判定' },
                { value: 'peak', label: 'ピークを強制' },
                { value: 'valley', label: 'オフピークを強制' }
            ], work.override, function (v) {
                work.override = v;
                refreshPreview();
                updateStatusCard();
            })));

        c.appendChild(row('状態更新の間隔', 'ページを開いている間にサーバーへ段階を問い合わせる頻度（秒）。',
            mkRange(5, 60, 1, work.pollSeconds, ' 秒', function (v) {
                work.pollSeconds = Math.round(v);
            })));

        return c;
    }

    function updateStatusCard() {
        if (!statusCardRefs.pill) { return; }
        if (!work) { return; }
        var phase = localPhase(work.override, work.windows, work.timezone);
        var color = phase === 'peak'
            ? (work.edge && work.edge.peakColor) || '#f97316'
            : (work.edge && work.edge.valleyColor) || '#38bdf8';
        statusCardRefs.pill.style.background = color;
        statusCardRefs.pillText.textContent = phaseLabel(phase);

        if (!statusCardRefs.nextText) { return; }
        if (work.override !== 'auto') {
            statusCardRefs.nextText.textContent = '強制モードでは切替を計算しません';
            return;
        }
        var nextAt = status && status.nextTransitionAt ? new Date(status.nextTransitionAt) : null;
        if (!nextAt || isNaN(nextAt.getTime())) {
            statusCardRefs.nextText.textContent = '次の切替：—';
            return;
        }
        var diff = Math.max(0, Math.round((nextAt.getTime() - Date.now()) / 1000));
        var hh = Math.floor(diff / 3600);
        var mm = Math.floor((diff % 3600) / 60);
        var ss = diff % 60;
        var cd = hh > 0 ? pvT('{0} 時間 {1} 分', hh, mm) : pvT('{0} 分 {1} 秒', mm, pad2(ss));
        var nextPhase = status && status.nextPhase === 'peak' ? 'ピーク時間帯' : 'オフピーク時間帯';
        var t = new Date(nextAt.getTime());
        var hm = pad2(t.getHours()) + ':' + pad2(t.getMinutes());
        statusCardRefs.nextText.textContent = pvT('次の切替：{0} → {1}（{2}後）', hm, nextPhase, cd);
    }

    // ---- ピーク時間帯カード

    function buildWindowsCard() {
        var c = card('ピーク時間帯の設定', '既定の公式時間帯（北京時間、2026-08-17 から有効）。それ以外の時間は自動的にオフピーク時間帯とみなされます。');
        var list = ce('div', 'pv-row-col');
        list.id = 'pvWindowList';

        function renderWindows() {
            list.innerHTML = '';
            if (!work.windows.length) {
                list.appendChild(ce('div', 'pv-empty', '時間帯がありません。少なくとも 1 つ追加してください'));
            }
            work.windows.forEach(function (w, idx) {
                var line = ce('div', 'pv-window-row');
                var st = ce('input', 'pv-input');
                st.type = 'time';
                st.value = w.start;
                st.addEventListener('change', function () {
                    work.windows[idx].start = st.value;
                    refreshPreview();
                });
                var ar = ce('span', 'pv-window-arrow', '→');
                var en = ce('input', 'pv-input');
                en.type = 'time';
                en.value = w.end;
                en.addEventListener('change', function () {
                    work.windows[idx].end = en.value;
                    refreshPreview();
                });
                var del = btn('削除', 'pv-btn-danger pv-btn-sm', function () {
                    if (work.windows.length <= 1) {
                        toast('ピーク時間帯を少なくとも 1 つ残してください');
                        return;
                    }
                    work.windows.splice(idx, 1);
                    renderWindows();
                    refreshPreview();
                });
                line.appendChild(st);
                line.appendChild(ar);
                line.appendChild(en);
                line.appendChild(del);
                list.appendChild(line);
            });
        }

        c.appendChild(list);
        renderWindows();

        var actions = ce('div', 'pv-btn-row');
        actions.appendChild(btn('＋ 時間帯を追加', '', function () {
            work.windows.push({ start: '09:00', end: '12:00' });
            renderWindows();
            refreshPreview();
        }));
        actions.appendChild(btn('公式の既定に戻す', '', function () {
            work.windows = [
                { start: '09:00', end: '12:00' },
                { start: '14:00', end: '18:00' }
            ];
            renderWindows();
            refreshPreview();
        }));
        c.appendChild(actions);

        c.appendChild(row('タイムゾーン', '時間帯はこのタイムゾーンで換算されます。公式時間帯は北京時間です。',
            mkSelect(timezones.map(function (tz) { return { value: tz, label: tz }; }),
                work.timezone, function (v) {
                    work.timezone = v;
                    refreshPreview();
                    updateStatusCard();
                })));

        return c;
    }

    // ---- 見た目のパラメータカード（枠 / 入力欄で共用）

    function buildVisualControls(target, prefix) {
        var frag = document.createDocumentFragment();

        frag.appendChild(row('ピーク時の色', 'ピーク時間帯に使用する色。',
            mkColor(target.peakColor, function (v) {
                target.peakColor = v;
                refreshPreview();
            })));

        frag.appendChild(row('オフピーク時の色', 'オフピーク時間帯に使用する色。',
            mkColor(target.valleyColor, function (v) {
                target.valleyColor = v;
                refreshPreview();
            })));

        frag.appendChild(row('枠の幅', '1～14 ピクセル。',
            mkRange(1, 14, 1, target.width, ' px', function (v) {
                target.width = Math.round(v);
                refreshPreview();
            })));

        frag.appendChild(row('グロー強度', '0 でグローなし。',
            mkRange(0, 80, 1, target.glow, ' px', function (v) {
                target.glow = Math.round(v);
                refreshPreview();
            })));

        frag.appendChild(row('不透明度', '全体の透明度、0.2～1。',
            mkRange(0.2, 1, 0.05, target.opacity, '', function (v) {
                target.opacity = v;
                refreshPreview();
            })));

        frag.appendChild(row('呼吸アニメーション', '呼吸 / 常時点灯 / オフ。',
            mkSelect([
                { value: 'breathing', label: '呼吸' },
                { value: 'solid', label: '常時点灯' },
                { value: 'off', label: '閉じる' }
            ], target.animation, function (v) {
                target.animation = v;
                refreshPreview();
            })));

        frag.appendChild(row('呼吸の周期', '呼吸 1 周期の秒数。',
            mkRange(0.5, 10, 0.1, target.breathingSpeed, ' s', function (v) {
                target.breathingSpeed = v;
                refreshPreview();
            })));

        frag.appendChild(row('光効果の方向', 'グローが外向きに広がるか内向きに収まるか。',
            mkSelect([
                { value: 'out', label: '外向き' },
                { value: 'in', label: '内向き' }
            ], target.glowDirection, function (v) {
                target.glowDirection = v;
                refreshPreview();
            })));

        frag.appendChild(row('流れる光（コメット）', '枠に沿って周回する光点。',
            mkSwitch(target.flow, function (v) {
                target.flow = v;
                refreshPreview();
                ensureFlowLoop();
            })));

        frag.appendChild(row('光の速さ', '1 周にかかる秒数（2～24）。',
            mkRange(2, 24, 1, target.flowSpeed, ' s', function (v) {
                target.flowSpeed = v;
                ensureFlowLoop();
            })));

        return frag;
    }

    function buildEdgeCard() {
        var c = card('ページ枠', 'ページ端の呼吸する枠線：ピークはオレンジ、オフピークはブルー。色と呼吸は調整できます。');
        c.appendChild(row('枠を有効化', 'オフにするとページ端は表示されません。入力欄とバッジは独立して機能します。',
            mkSwitch(work.edge.enabled, function (v) {
                work.edge.enabled = v;
                refreshPreview();
            })));
        c.appendChild(buildVisualControls(work.edge, 'edge'));
        var actions = ce('div', 'pv-btn-row');
        actions.appendChild(btn('枠を既定に戻す', 'pv-btn-sm', function () {
            work.edge = clone(defaults.edge);
            renderBody();
            refreshPreview();
        }));
        c.appendChild(actions);
        return c;
    }

    function buildComposerCard() {
        var c = card('入力欄の光効果', 'DeepSeek チャットの入力欄に独立した光効果を追加します。設定はページ枠と完全に分離されています。');
        c.appendChild(row('入力欄の光効果を有効化', 'チャット入力欄のコントロールに追従して配置。スクロールやキーボード表示時も自動で追従します。',
            mkSwitch(work.composer.enabled, function (v) {
                work.composer.enabled = v;
                refreshPreview();
                positionComposer();
            })));
        c.appendChild(buildVisualControls(work.composer, 'composer'));
        var actions = ce('div', 'pv-btn-row');
        actions.appendChild(btn('入力欄を既定に戻す', 'pv-btn-sm', function () {
            work.composer = clone(defaults.composer);
            renderBody();
            refreshPreview();
        }));
        c.appendChild(actions);
        return c;
    }

    // ---- バッジカード

    function cornerSelect(value, onChange) {
        return mkSelect([
            { value: 'tl', label: '左上' },
            { value: 'tr', label: '右上' },
            { value: 'bl', label: '左下' },
            { value: 'br', label: '右下' }
        ], value, onChange);
    }

    function buildBadgeCard() {
        var c = card('状態バッジ', '独立した時間帯バッジ。枠のスイッチとは連動しません。PC とスマホで位置を別々に設定できます。');
        c.appendChild(row('バッジを有効化', 'バッジをタップするとこの設定パネルを直接開けます。',
            mkSwitch(work.badge.enabled, function (v) {
                work.badge.enabled = v;
                refreshPreview();
                updateBadgePositionOnly();
            })));

        ['desktop', 'mobile'].forEach(function (key) {
            var pos = work.badge[key];
            var title = key === 'desktop' ? 'PC' : 'スマホ';
            var sub = ce('div', 'pv-card-desc', title);
            sub.style.marginTop = '2px';
            c.appendChild(sub);
            c.appendChild(row('表示位置', '', cornerSelect(pos.corner, function (v) {
                pos.corner = v;
                refreshPreview();
                updateBadgePositionOnly();
            })));
            c.appendChild(row('水平オフセット', '', mkRange(0, 240, 1, pos.x, ' px', function (v) {
                pos.x = Math.round(v);
                updateBadgePositionOnly();
            })));
            c.appendChild(row('垂直オフセット', '', mkRange(0, 400, 1, pos.y, ' px', function (v) {
                pos.y = Math.round(v);
                updateBadgePositionOnly();
            })));
        });

        var actions = ce('div', 'pv-btn-row');
        actions.appendChild(btn('バッジを既定に戻す', 'pv-btn-sm', function () {
            work.badge = clone(defaults.badge);
            renderBody();
            refreshPreview();
        }));
        c.appendChild(actions);
        return c;
    }

    // ---- ローカル通知卡

    function buildNotifyCard() {
        var c = card('ローカル通知', 'ブラウザのシステム通知：ページを開いている間に、時間帯の切替や予約リマインダーの発火時に通知します。');

        var pText = ce('div', 'pv-msg pv-msg-muted', permissionText());
        c.appendChild(pText);

        c.appendChild(row('ローカル通知を有効化', '',
            mkSwitch(work.localNotify.enabled, function (v) {
                work.localNotify.enabled = v;
            })));

        c.appendChild(row('フェーズ転換時に通知', 'ピーク／オフピークの切替時に通知します。',
            mkSwitch(work.localNotify.onTransition, function (v) {
                work.localNotify.onTransition = v;
            })));

        c.appendChild(row('予約リマインダーの発火時に通知', 'サーバーがプッシュチャネルで通知を送るときに同期して通知します。',
            mkSwitch(work.localNotify.onReminder, function (v) {
                work.localNotify.onReminder = v;
            })));

        var actions = ce('div', 'pv-btn-row');
        actions.appendChild(btn('通知権限をリクエスト', 'pv-btn-sm', function () {
            if (!notifySupported()) {
                toast('このブラウザは通知に対応していません');
                return;
            }
            Notification.requestPermission().then(function (p) {
                pText.textContent = permissionText();
                toast(p === 'granted' ? '通知権限を取得しました' : '権限を取得できませんでした：' + p);
            });
        }));
        actions.appendChild(btn('テスト通知を送信', 'pv-btn-sm', function () {
            if (!notifySupported() || Notification.permission !== 'granted') {
                toast('先に通知を許可してください');
                return;
            }
            notify('ピーク／オフピーク通知テスト', 'この通知が見えていれば、ローカル通知は利用可能です。');
        }));
        c.appendChild(actions);
        return c;
    }

    function permissionText() {
        if (!notifySupported()) { return 'このブラウザは Notification API に対応していません'; }
        var p = Notification.permission;
        if (p === 'granted') { return '通知権限：許可済み'; }
        if (p === 'denied') { return '通知権限：拒否されています（ブラウザのサイト設定で有効にしてください）'; }
        return '通知権限：未許可';
    }

    // ---- プッシュチャネル卡

    function buildChannelCard() {
        var c = card('プッシュチャネル', 'リマインダーは以下のチャネルで送信されます。キーはサーバー側の設定ファイル（権限 0600）に保存され、API 応答時は自動でマスクされます。');

        if (channelMsg) {
            var m = ce('div', 'pv-msg ' + (channelMsg.indexOf('✅') === 0 ? 'pv-msg-ok' : 'pv-msg-err'), channelMsg);
            c.appendChild(m);
        }

        var list = ce('div', 'pv-row-col');
        if (!work.channels.length) {
            list.appendChild(ce('div', 'pv-empty', 'プッシュチャネルがまだありません。1 つ追加すると、リマインダーがスマホに届きます。'));
        }
        work.channels.forEach(function (ch) {
            var item = ce('div', 'pv-channel');
            var info = ce('div', 'pv-channel-info');
            info.appendChild(ce('div', 'pv-channel-name', ch.name || ch.type));
            var configured = channelConfigured(ch);
            var subText = ch.type + ' · ' + (configured ? '設定済み' : '未入力の項目があります');
            info.appendChild(ce('div', 'pv-channel-sub', subText));
            item.appendChild(info);

            var tagCls = 'pv-tag';
            var tagText = '有効';
            if (!ch.enabled) { tagCls += ' pv-tag-off'; tagText = '無効'; }
            else if (!configured) { tagCls += ' pv-tag-warn'; tagText = '未設定'; }
            item.appendChild(ce('span', tagCls, tagText));

            item.appendChild(btn('編集', 'pv-btn-sm', function () {
                editingChannel = clone(ch);
                renderBody();
            }));
            item.appendChild(btn('テスト', 'pv-btn-sm', function () {
                channelMsg = '送信中…';
                renderBody();
                api('channelTest', { id: ch.id }).then(function (r) {
                    channelMsg = r.ok ? '✅ 送信成功：' + (r.name || ch.name) : '❌ 送信失敗：' + (r.error || '不明なエラー');
                    renderBody();
                }).catch(function (e) {
                    channelMsg = '❌ 送信失敗：' + e.message;
                    renderBody();
                });
            }));
            item.appendChild(btn('削除', 'pv-btn-danger pv-btn-sm', function () {
                if (!confirm(pvT('チャネル「{0}」？', (ch.name || ch.type)))) { return; }
                api('channelDelete', { id: ch.id }).then(function () {
                    return api('config');
                }).then(function (v) {
                    cfg = v.config;
                    work.channels = clone(cfg.channels);
                    channelMsg = '✅ 削除しました';
                    renderBody();
                }).catch(function (e) { toast('削除に失敗しました：' + e.message); });
            }));

            list.appendChild(item);
        });
        c.appendChild(list);

        // チャネル編集フォーム
        if (editingChannel) {
            c.appendChild(buildChannelForm());
        } else {
            var actions = ce('div', 'pv-btn-row');
            actions.appendChild(btn('＋ チャネルを追加', 'pv-btn-primary pv-btn-sm', function () {
                editingChannel = {
                    id: '', type: 'serverchan', name: 'Server酱', enabled: true,
                    key: '', server: '', chatId: '', secret: '', method: 'POST', body: ''
                };
                channelMsg = '';
                renderBody();
            }));
            c.appendChild(actions);
        }

        return c;
    }

    function channelConfigured(ch) {
        if (!ch) { return false; }
        if (ch.type === 'serverchan' || ch.type === 'bark') { return !!ch.key; }
        if (ch.type === 'telegram') { return !!ch.key && !!ch.chatId; }
        if (ch.type === 'dingtalk' || ch.type === 'wecom' || ch.type === 'feishu') {
            return !!ch.server || !!ch.key;
        }
        if (ch.type === 'webhook') { return !!ch.server; }
        return false;
    }

    function buildChannelForm() {
        var box = ce('div', 'pv-card');
        box.style.border = '1px solid #c7d2fe';
        box.style.background = '#f8faff';
        box.appendChild(ce('div', 'pv-card-title', editingChannel.id ? 'チャネルを編集' : 'チャネルを追加'));

        // 種類
        var typeOpts = channelTypes.map(function (t) { return { value: t.type, label: t.name }; });
        if (!typeOpts.length) {
            typeOpts = [{ value: 'serverchan', label: 'Server酱' }];
        }
        box.appendChild(row('チャネルの種類', '', mkSelect(typeOpts, editingChannel.type, function (v) {
            editingChannel.type = v;
            var meta = findChannelType(v);
            if (!editingChannel.id && meta) { editingChannel.name = meta.name; }
            renderBody();
        })));

        box.appendChild(row('名前', 'リスト表示専用です。',
            mkText(editingChannel.name, '例：私のスマホ', function (v) { editingChannel.name = v; })));

        var meta = findChannelType(editingChannel.type);
        var fields = meta ? meta.fields : ['key'];

        if (fields.indexOf('key') >= 0) {
            var keyLabel = editingChannel.type === 'telegram' ? 'Bot Token' : (editingChannel.type === 'bark' ? 'DeviceKey' : 'キー / SendKey');
            box.appendChild(row(keyLabel, (window.I18N&&window.I18N.t)?window.I18N.t('保存済みのキーはマスク表示されます。変更しなければ元の値が保持されます。'):'保存済みのキーはマスク表示されます。変更しなければ元の値が保持されます。',
                mkText(editingChannel.key, 'ここに入力', function (v) { editingChannel.key = v; })));
        }
        if (fields.indexOf('server') >= 0) {
            var srvLabel = editingChannel.type === 'webhook' ? 'Webhook アドレス' : 'Webhook / サーバーアドレス';
            box.appendChild(row(srvLabel, editingChannel.type === 'bark' ? '空欄なら https://api.day.app を使用' : '完全な URL',
                mkText(editingChannel.server, 'https://', function (v) { editingChannel.server = v; })));
        }
        if (fields.indexOf('chatId') >= 0) {
            box.appendChild(row('Chat ID', 'Telegram のチャット ID。',
                mkText(editingChannel.chatId, '例：123456789', function (v) { editingChannel.chatId = v; })));
        }
        if (fields.indexOf('secret') >= 0) {
            box.appendChild(row('署名キー', 'DingTalk / Feishu の secret（任意）。',
                mkText(editingChannel.secret, '任意', function (v) { editingChannel.secret = v; })));
        }
        if (fields.indexOf('method') >= 0) {
            box.appendChild(row('リクエスト方法', '',
                mkSelect([{ value: 'POST', label: 'POST' }, { value: 'GET', label: 'GET' }],
                    editingChannel.method || 'POST', function (v) { editingChannel.method = v; })));
        }
        if (fields.indexOf('body') >= 0) {
            box.appendChild(row('リクエスト本文のテンプレート', '{title} と {content} のプレースホルダに対応。',
                mkTextarea(editingChannel.body, '{"title":"{title}","content":"{content}"}',
                    function (v) { editingChannel.body = v; })));
        }

        box.appendChild(row('このチャネルを有効化', '',
            mkSwitch(editingChannel.enabled, function (v) { editingChannel.enabled = v; })));

        var actions = ce('div', 'pv-btn-row');
        actions.appendChild(btn('チャネルを保存', 'pv-btn-primary pv-btn-sm', function () {
            var payload = clone(editingChannel);
            api('channelSave', { channel: payload }).then(function () {
                return api('config');
            }).then(function (v) {
                cfg = v.config;
                work.channels = clone(cfg.channels);
                editingChannel = null;
                channelMsg = '✅ チャネルを保存しました';
                renderBody();
            }).catch(function (e) {
                channelMsg = '❌ ' + e.message;
                renderBody();
            });
        }));
        actions.appendChild(btn('キャンセル', 'pv-btn-sm', function () {
            editingChannel = null;
            renderBody();
        }));
        box.appendChild(actions);
        return box;
    }

    function findChannelType(t) {
        for (var i = 0; i < channelTypes.length; i += 1) {
            if (channelTypes[i].type === t) { return channelTypes[i]; }
        }
        return null;
    }

    // ---- 提醒卡

    function buildReminderCard(phase) {
        var r = work.reminders[phase];
        var isPeak = phase === 'peak';
        var c = card(isPeak ? 'ピーク時間帯の通知' : 'オフピーク時間帯の通知',
            '到達' + (isPeak ? 'ピーク' : 'オフピーク') + '前に（または到達時に）プッシュチャネルでリマインダーを送信します。スケジューリングはサーバー側で実行されるため、ページを閉じても届きます。');

        c.appendChild(row('通知を有効化', '',
            mkSwitch(r.enabled, function (v) { r.enabled = v; })));

        c.appendChild(row('事前通知', '0 は時間帯が始まる瞬間に送信することを意味します。',
            mkSelect([
                { value: '0', label: '定刻（到達時）' },
                { value: '5', label: '5 分前' },
                { value: '10', label: '10 分前' },
                { value: '15', label: '15 分前' },
                { value: '30', label: '30 分前' },
                { value: '60', label: '60 分前' }
            ], String(r.leadMinutes), function (v) { r.leadMinutes = parseInt(v, 10) || 0; })));

        var chOpts = [{ value: 'all', label: 'すべてのチャネルを有効化' }];
        work.channels.forEach(function (ch) {
            chOpts.push({ value: 'id:' + ch.id, label: (ch.name || ch.type) });
        });
        if (r.channel && r.channel !== 'all' && r.channel.indexOf('id:') !== 0 && !findChannel(r.channel)) {
            chOpts.push({ value: r.channel, label: r.channel });
        }
        c.appendChild(row('プッシュチャネル', '',
            mkSelect(chOpts, r.channel || 'all', function (v) { r.channel = v; })));

        c.appendChild(row('タイトルテンプレート', '使用可能な変数：{phase} {start} {end} {time} {date}',
            mkText(r.title, 'DeepSeek ピーク時間帯が開始', function (v) { r.title = v; })));

        c.appendChild(row('本文テンプレート', '上記の変数も同様に使用できます。',
            mkTextarea(r.content, '{phase}開始：{start}～{end}', function (v) { r.content = v; })));

        c.appendChild(row('追加の固定時刻', 'HH:MM。複数はカンマ区切り。その段階の進行中のみ発火します。',
            mkText(r.times, '例：10:30,15:00', function (v) { r.times = v; })));

        var actions = ce('div', 'pv-btn-row');
        actions.appendChild(btn('テスト送信', 'pv-btn-sm', function () {
            var info = ce('div', 'pv-msg pv-msg-muted', '送信中…');
            c.appendChild(info);
            api('test', { kind: phase, channel: r.channel, title: r.title, content: r.content })
                .then(function (v) {
                    var ok = v.result && v.result.ok;
                    info.className = 'pv-msg ' + (ok ? 'pv-msg-ok' : 'pv-msg-err');
                    info.textContent = ok
                        ? pvT('✅ 送信しました（{0}/{1}）', v.result.sent, v.result.total) + '\n' + v.title
                        : '❌ ' + ((v.result && v.result.error) || '送信に失敗');
                }).catch(function (e) {
                    info.className = 'pv-msg pv-msg-err';
                    info.textContent = '❌ ' + e.message;
                });
        }));
        actions.appendChild(btn('今すぐ 1 回発火', 'pv-btn-sm', function () {
            api('fireNow', { phase: phase }).then(function (v) {
                if (v.skipped) {
                    toast('この段階の通知は有効になっていません');
                    return;
                }
                var ok = v.result && v.result.ok;
                toast(ok ? '発火して送信しました' : '発火に失敗：' + ((v.result && v.result.error) || '不明なエラー'));
            }).catch(function (e) { toast('発火に失敗：' + e.message); });
        }));
        c.appendChild(actions);

        if (r.lastFiredAt) {
            var res = r.lastResult;
            var text = '最近の発火：' + formatTime(r.lastFiredAt);
            if (res) {
                text += res.ok ? pvT(' · 成功 {0}/{1}', res.sent, res.total) : pvT(' · 失敗：{0}', (res.error || ''));
            }
            c.appendChild(ce('div', 'pv-msg ' + (res && res.ok ? 'pv-msg-ok' : 'pv-msg-err'), text));
        } else {
            c.appendChild(ce('div', 'pv-msg pv-msg-muted', 'まだ発火していません'));
        }

        return c;
    }

    function findChannel(id) {
        for (var i = 0; i < work.channels.length; i += 1) {
            if (work.channels[i].id === id) { return work.channels[i]; }
        }
        return null;
    }

    function formatTime(iso) {
        var d = new Date(iso);
        if (isNaN(d.getTime())) { return iso; }
        return d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate()) +
            ' ' + pad2(d.getHours()) + ':' + pad2(d.getMinutes());
    }

    // ---- この機能について卡

    function buildAboutCard() {
        var c = card('この機能について', '');
        var lines = [
            '公式の時間帯（北京時間）：ピークは 09:00–12:00、14:00–18:00。それ以外はオフピーク（アイドル）時間帯で、API 料金はピークの約半額です。',
            '有効開始日：2026-08-17 より。',
            '設定ファイル：' + (dataPath || 'data/peakvalley/config.json'),
            'スケジューラ：サーバーが 30 秒ごとに確認します。サービス再起動後、10 分以内に期限が来るリマインダーは再送されます。'
        ];
        lines.forEach(function (t) {
            c.appendChild(ce('div', 'pv-card-desc', t));
        });
        return c;
    }

    // ============================================================ 起動

    function bindEntryButtons() {
        var sbBtn = $('sidebarPeakValleyBtn');
        if (sbBtn) {
            sbBtn.addEventListener('click', function () {
                // サイドバーを閉じてからパネルを開く
                var menu = $('sidebarMenu');
                var ovl = $('menuOverlay');
                if (menu) { menu.classList.remove('open'); }
                if (ovl) { ovl.classList.remove('open'); }
                document.body.style.overflow = '';
                openSettings();
            });
        }
        var topBtn = $('dscPeakValleyBtn');
        if (topBtn) {
            topBtn.addEventListener('click', function () { openSettings(); });
        }
    }

    function boot() {
        ensureOverlay();
        bindEntryButtons();
        startTracking();

        // チャット画面のスイッチが「DeepSeek チャットのみで有効」の判定に影響する
        var app = $('deepseekChatApp');
        if (app && typeof MutationObserver !== 'undefined') {
            try {
                var mo = new MutationObserver(function () {
                    if (!work) { applyOverlay(status); }
                });
                mo.observe(app, { attributes: true, attributeFilter: ['class'] });
            } catch (e) { /* ignore */ }
        }

        document.addEventListener('visibilitychange', function () {
            if (document.visibilityState === 'visible') { poll(); }
        });

        api('config').then(function (v) {
            cfg = v.config;
            defaults = v.defaults;
            channelTypes = v.channelTypes || [];
            timezones = v.timezones || [];
            dataPath = v.dataPath || '';
            startPolling(cfg.pollSeconds);
            poll();
        }).catch(function () {
            // サーバー未準備のときは静かに再試行し、ページを邪魔しない
            setTimeout(boot, 3000);
        });
    }

    // 公開インターフェース（デバッグと外部呼び出し用）
    window.PeakValley = {
        open: openSettings,
        close: closeSettings,
        refresh: poll,
        status: function () { return status; },
        config: function () { return cfg; }
    };

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', boot);
    } else {
        boot();
    }
})();
