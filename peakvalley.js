// peakvalley.js — 峰谷提醒前端（移植自 chicheng-peak 插件）
//
// 职责：
//   1. 页面边缘呼吸边框（高峰橙 / 低峰蓝）、光晕方向、流光彗星
//   2. 输入框光效：跟随 DeepSeek 聊天的输入框控件，参数与页面边框完全独立
//   3. 状态角标：PC / 手机端各自四角定位
//   4. 浏览器本地通知
//   5. 设置面板：状态 / 时段 / 边框 / 输入框 / 角标 / 通知 / 推送提醒 / 关于
//
// 后端：/api/peakvalley/*（peakvalley.go）
// 时段（北京时间）：高峰 09:00–12:00、14:00–18:00，其余为低峰。

(function () {
    'use strict';

    var API_BASE = '/api/peakvalley/';

    // 运行期状态
    var cfg = null;          // 已保存配置
    var status = null;       // 最近一次 status 载荷
    var defaults = null;     // 服务端默认值
    var channelTypes = [];   // 渠道类型元数据
    var timezones = [];
    var dataPath = '';
    var work = null;         // 编辑中的配置副本

    var pollTimer = null;
    var posTimer = null;
    var rafId = null;
    var lastFrame = 0;
    var flowPhase = 0;

    var lastPhase = null;
    var lastPeakFired = '';
    var lastValleyFired = '';

    var modal = null;        // 设置面板根节点
    var modalBody = null;
    var countdownTimer = null;
    var editingChannel = null;   // 正在编辑的渠道
    var channelMsg = '';

    // ============================================================ 基础工具

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
                var msg = body && body.error && body.error.message ? body.error.message : '请求失败';
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

    // ============================================================ 阶段本地计算
    // 用于设置面板的即时预览：不依赖服务端往返

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
        } catch (e) { /* 回退到本地时区 */ }
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
        return phase === 'peak' ? '高峰期' : '低峰期';
    }

    // ============================================================ 覆盖层

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

        // 流光：用 SVG 描边虚线实现，沿边框匀速跑光
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
        badge.title = '峰谷提醒（点击打开设置）';
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

    /** 生效范围：默认只在 DeepSeek 聊天打开时生效 */
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

    /** 把配色/尺寸/动画套到页面边框图层 */
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

        // 光晕：呼吸动画只改 opacity（走合成层，不触发重排）
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

    /** 输入框光效图层 */
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

        // ---- 页面边缘
        var edge = s.edge || {};
        if (edge.enabled !== false) {
            applyEdgeLayer(edge, phase);
        } else {
            ov.ring.style.border = 'none';
            ov.ring.style.opacity = '0';
            ov.glow.style.opacity = '0';
            ov.svg.style.display = 'none';
            ov.root.style.display = 'block'; // 角标/输入框仍可能独立开启
        }

        // ---- 输入框光效
        var comp = s.composer || {};
        if (comp.enabled !== false) {
            applyComposerLayer(comp, phase);
            positionComposer();
        } else {
            ov.composer.style.display = 'none';
        }

        // ---- 状态角标
        var bd = s.badge || {};
        if (bd.enabled !== false) {
            applyBadge(bd, phase);
        } else {
            ov.badge.style.display = 'none';
        }

        // 页面边缘全关且无角标/输入框时彻底隐藏
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

    /** 找到 DeepSeek 聊天的输入框容器（优先 .dsc-input-wrap） */
    function composerEl() {
        var input = $('dscInput');
        if (input) {
            if (input.closest) {
                var box = input.closest('.dsc-input-wrap');
                if (box) { return box; }
            }
            return input;
        }
        // 兜底：可见的 textarea（排除弹窗内的输入框）
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
        } catch (e) { /* 保留默认 */ }

        ov.composer.style.display = 'block';
        ov.composer.style.left = Math.round(r.left) + 'px';
        ov.composer.style.top = Math.round(r.top) + 'px';
        ov.composer.style.width = Math.round(r.width) + 'px';
        ov.composer.style.height = Math.round(r.height) + 'px';
        ov.composer.style.borderRadius = radius;
        ov.cglow.style.borderRadius = radius;

        // 流光路径尺寸
        ov.crect.setAttribute('width', String(Math.max(0, Math.round(r.width) - 2)));
        ov.crect.setAttribute('height', String(Math.max(0, Math.round(r.height) - 2)));
        ov.crect.setAttribute('rx', String(parseFloat(radius) || 10));
    }

    /** 流光动画：用 stroke-dashoffset 沿矩形匀速跑光（兼容性最好） */
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

    // ============================================================ 本地通知

    function notifySupported() {
        return typeof window !== 'undefined' && 'Notification' in window;
    }

    function notify(title, body) {
        if (!notifySupported()) { return; }
        if (Notification.permission !== 'granted') { return; }
        try {
            new Notification(String(title), { body: String(body), tag: 'peakvalley' });
        } catch (e) { /* 部分移动浏览器不允许直接构造 */ }
    }

    function detectNotify(s) {
        if (!s || !s.localNotify || !s.localNotify.enabled) { return; }
        var title = '';
        var body = '';
        if (s.localNotify.onTransition !== false && s.phase && lastPhase !== null && s.phase !== lastPhase) {
            var peakNow = s.phase === 'peak';
            title = peakNow ? 'DeepSeek 高峰期开始' : 'DeepSeek 低峰期开始';
            body = peakNow ? '当前为高峰期（09:00–12:00 / 14:00–18:00）' : '当前为低峰期（空闲时段，价格约为高峰一半）';
        } else if (s.localNotify.onReminder === true && s.reminders) {
            var pk = s.reminders.peak ? s.reminders.peak.lastFiredAt : '';
            var vl = s.reminders.valley ? s.reminders.valley.lastFiredAt : '';
            if (pk && pk !== lastPeakFired) {
                title = (s.reminders.peak.title || '高峰期提醒');
                body = '已通过推送渠道发送高峰期提醒';
            } else if (vl && vl !== lastValleyFired) {
                title = (s.reminders.valley.title || '低峰期提醒');
                body = '已通过推送渠道发送低峰期提醒';
            }
            lastPeakFired = pk || '';
            lastValleyFired = vl || '';
        }
        lastPhase = s.phase;
        if (title) { notify(title, body); }
    }

    // ============================================================ 轮询

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
            // 服务端不可用：隐藏覆盖层，避免残留旧状态误导
            hideAll();
        });
    }

    // ============================================================ 设置面板

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

    // ---- 通用控件

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

    /** 一行：左标签 + 右控件 */
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
        headText.appendChild(ce('div', 'pv-head-title', '峰谷提醒'));
        headText.appendChild(ce('div', 'pv-head-sub', 'DeepSeek 峰谷时段 · 边框光效 · 推送提醒'));
        head.appendChild(headText);
        var closeBtn = ce('button', 'pv-close', '✕');
        closeBtn.type = 'button';
        closeBtn.title = '关闭';
        closeBtn.addEventListener('click', function () { closeSettings(); });
        head.appendChild(closeBtn);

        var body = ce('div', 'pv-body');

        var foot = ce('div', 'pv-foot');
        var resetAll = btn('恢复全部默认', 'pv-btn-ghost pv-btn-sm', function () {
            if (!confirm('将把所有外观与提醒设置恢复为默认值（推送渠道保留），确定吗？')) { return; }
            api('reset', { section: 'all' }).then(function (v) {
                cfg = v.config;
                work = clone(cfg);
                renderBody();
                refreshPreview();
                toast('已恢复默认');
            }).catch(function (e) { toast('恢复失败：' + e.message); });
        });
        foot.appendChild(resetAll);
        foot.appendChild(ce('div', 'pv-foot-spacer'));
        foot.appendChild(btn('关闭', '', function () { closeSettings(); }));
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

        // 真实可见高度变化时（浏览器工具栏收放、横竖屏切换、软键盘弹出）同步给 CSS
        var sync = function () { syncViewportVar(); };
        window.addEventListener('resize', sync);
        window.addEventListener('orientationchange', sync);
        if (window.visualViewport) {
            window.visualViewport.addEventListener('resize', sync);
            window.visualViewport.addEventListener('scroll', sync);
        }
    }

    // 把"实际可见高度"写进 --pv-vh，让面板永远不超过可见区域
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
        modalBody.appendChild(ce('div', 'pv-empty', '加载中…'));
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
            // 打开面板时刷新一次状态，保证阶段与倒计时是最新的
            poll();
        }).catch(function (e) {
            modalBody.innerHTML = '';
            var err = ce('div', 'pv-empty', '加载失败：' + e.message + '（请确认服务已启动）');
            modalBody.appendChild(err);
        });
    }

    function closeSettings() {
        if (modal) { modal.classList.remove('pv-open'); }
        stopCountdown();
        editingChannel = null;
        // 放弃未保存的改动，回到已保存状态
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
            toast('已保存');
        }).catch(function (e) {
            toast('保存失败：' + e.message);
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

    // ---- 状态卡

    var statusCardRefs = {};

    function buildStatusCard() {
        var c = card('当前状态', '实时阶段、下一转折倒计时与手动覆盖。');
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

        c.appendChild(row('启用峰谷提醒', '总开关，关闭后边框、光效、角标与推送提醒全部停止。',
            mkSwitch(work.enabled, function (v) {
                work.enabled = v;
                refreshPreview();
            })));

        c.appendChild(row('生效范围', '默认只在 DeepSeek 聊天界面生效，避免影响其他页面。',
            mkSelect([
                { value: 'deepseek', label: '仅 DeepSeek 聊天' },
                { value: 'global', label: '全部页面' }
            ], work.scope, function (v) {
                work.scope = v;
                refreshPreview();
                positionComposer();
            })));

        c.appendChild(row('判定模式', '自动判定按下方时段计算；强制模式用于预览效果。',
            mkSelect([
                { value: 'auto', label: '自动判定' },
                { value: 'peak', label: '强制高峰' },
                { value: 'valley', label: '强制低峰' }
            ], work.override, function (v) {
                work.override = v;
                refreshPreview();
                updateStatusCard();
            })));

        c.appendChild(row('状态刷新间隔', '页面打开时向服务端查询阶段的频率（秒）。',
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
            statusCardRefs.nextText.textContent = '强制模式下不计算转折';
            return;
        }
        var nextAt = status && status.nextTransitionAt ? new Date(status.nextTransitionAt) : null;
        if (!nextAt || isNaN(nextAt.getTime())) {
            statusCardRefs.nextText.textContent = '下一转折：—';
            return;
        }
        var diff = Math.max(0, Math.round((nextAt.getTime() - Date.now()) / 1000));
        var hh = Math.floor(diff / 3600);
        var mm = Math.floor((diff % 3600) / 60);
        var ss = diff % 60;
        var cd = hh > 0 ? (hh + ' 小时 ' + mm + ' 分') : (mm + ' 分 ' + pad2(ss) + ' 秒');
        var nextPhase = status && status.nextPhase === 'peak' ? '高峰期' : '低峰期';
        var t = new Date(nextAt.getTime());
        var hm = pad2(t.getHours()) + ':' + pad2(t.getMinutes());
        statusCardRefs.nextText.textContent = '下一转折：' + hm + ' → ' + nextPhase + '（' + cd + '后）';
    }

    // ---- 高峰时段卡

    function buildWindowsCard() {
        var c = card('高峰时段设置', '默认官方时段（北京时间，2026-08-17 起生效）。其余时间自动视为低峰期。');
        var list = ce('div', 'pv-row-col');
        list.id = 'pvWindowList';

        function renderWindows() {
            list.innerHTML = '';
            if (!work.windows.length) {
                list.appendChild(ce('div', 'pv-empty', '还没有时段，请添加至少一个'));
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
                var del = btn('移除', 'pv-btn-danger pv-btn-sm', function () {
                    if (work.windows.length <= 1) {
                        toast('至少保留一个高峰时段');
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
        actions.appendChild(btn('＋ 添加时段', '', function () {
            work.windows.push({ start: '09:00', end: '12:00' });
            renderWindows();
            refreshPreview();
        }));
        actions.appendChild(btn('恢复官方默认', '', function () {
            work.windows = [
                { start: '09:00', end: '12:00' },
                { start: '14:00', end: '18:00' }
            ];
            renderWindows();
            refreshPreview();
        }));
        c.appendChild(actions);

        c.appendChild(row('时区', '时段按此时区换算；官方时段为北京时间。',
            mkSelect(timezones.map(function (tz) { return { value: tz, label: tz }; }),
                work.timezone, function (v) {
                    work.timezone = v;
                    refreshPreview();
                    updateStatusCard();
                })));

        return c;
    }

    // ---- 视觉参数卡（边框 / 输入框共用）

    function buildVisualControls(target, prefix) {
        var frag = document.createDocumentFragment();

        frag.appendChild(row('高峰颜色', '高峰期使用的颜色。',
            mkColor(target.peakColor, function (v) {
                target.peakColor = v;
                refreshPreview();
            })));

        frag.appendChild(row('低峰颜色', '低峰期使用的颜色。',
            mkColor(target.valleyColor, function (v) {
                target.valleyColor = v;
                refreshPreview();
            })));

        frag.appendChild(row('边框宽度', '1～14 像素。',
            mkRange(1, 14, 1, target.width, ' px', function (v) {
                target.width = Math.round(v);
                refreshPreview();
            })));

        frag.appendChild(row('光晕强度', '0 为无光晕。',
            mkRange(0, 80, 1, target.glow, ' px', function (v) {
                target.glow = Math.round(v);
                refreshPreview();
            })));

        frag.appendChild(row('不透明度', '整体透明度，0.2～1。',
            mkRange(0.2, 1, 0.05, target.opacity, '', function (v) {
                target.opacity = v;
                refreshPreview();
            })));

        frag.appendChild(row('呼吸动画', '呼吸 / 常亮 / 关闭。',
            mkSelect([
                { value: 'breathing', label: '呼吸' },
                { value: 'solid', label: '常亮' },
                { value: 'off', label: '关闭' }
            ], target.animation, function (v) {
                target.animation = v;
                refreshPreview();
            })));

        frag.appendChild(row('呼吸频率', '一个呼吸周期的秒数。',
            mkRange(0.5, 10, 0.1, target.breathingSpeed, ' s', function (v) {
                target.breathingSpeed = v;
                refreshPreview();
            })));

        frag.appendChild(row('光效方向', '光晕向外扩散或向内收拢。',
            mkSelect([
                { value: 'out', label: '向外' },
                { value: 'in', label: '向内' }
            ], target.glowDirection, function (v) {
                target.glowDirection = v;
                refreshPreview();
            })));

        frag.appendChild(row('流光彗星', '沿边框循环跑动的光点。',
            mkSwitch(target.flow, function (v) {
                target.flow = v;
                refreshPreview();
                ensureFlowLoop();
            })));

        frag.appendChild(row('流光速度', '跑完一圈的秒数（2～24）。',
            mkRange(2, 24, 1, target.flowSpeed, ' s', function (v) {
                target.flowSpeed = v;
                ensureFlowLoop();
            })));

        return frag;
    }

    function buildEdgeCard() {
        var c = card('页面边框', '页面边缘的呼吸边框：高峰橙、低峰蓝，颜色与呼吸均可调。');
        c.appendChild(row('启用边框', '关闭后页面边缘不再显示，输入框与角标独立生效。',
            mkSwitch(work.edge.enabled, function (v) {
                work.edge.enabled = v;
                refreshPreview();
            })));
        c.appendChild(buildVisualControls(work.edge, 'edge'));
        var actions = ce('div', 'pv-btn-row');
        actions.appendChild(btn('恢复边框默认', 'pv-btn-sm', function () {
            work.edge = clone(defaults.edge);
            renderBody();
            refreshPreview();
        }));
        c.appendChild(actions);
        return c;
    }

    function buildComposerCard() {
        var c = card('输入框光效', '给 DeepSeek 聊天的输入框加一层独立光效，参数与页面边框完全分开。');
        c.appendChild(row('启用输入框光效', '跟随聊天输入框控件定位，滚动与键盘弹出时自动贴合。',
            mkSwitch(work.composer.enabled, function (v) {
                work.composer.enabled = v;
                refreshPreview();
                positionComposer();
            })));
        c.appendChild(buildVisualControls(work.composer, 'composer'));
        var actions = ce('div', 'pv-btn-row');
        actions.appendChild(btn('恢复输入框默认', 'pv-btn-sm', function () {
            work.composer = clone(defaults.composer);
            renderBody();
            refreshPreview();
        }));
        c.appendChild(actions);
        return c;
    }

    // ---- 角标卡

    function cornerSelect(value, onChange) {
        return mkSelect([
            { value: 'tl', label: '左上' },
            { value: 'tr', label: '右上' },
            { value: 'bl', label: '左下' },
            { value: 'br', label: '右下' }
        ], value, onChange);
    }

    function buildBadgeCard() {
        var c = card('状态角标', '独立的阶段角标，不随边框开关联动；PC 与手机端可分别设置位置。');
        c.appendChild(row('启用角标', '点击角标可直接打开本设置面板。',
            mkSwitch(work.badge.enabled, function (v) {
                work.badge.enabled = v;
                refreshPreview();
                updateBadgePositionOnly();
            })));

        ['desktop', 'mobile'].forEach(function (key) {
            var pos = work.badge[key];
            var title = key === 'desktop' ? 'PC 端' : '手机端';
            var sub = ce('div', 'pv-card-desc', title);
            sub.style.marginTop = '2px';
            c.appendChild(sub);
            c.appendChild(row('所在角落', '', cornerSelect(pos.corner, function (v) {
                pos.corner = v;
                refreshPreview();
                updateBadgePositionOnly();
            })));
            c.appendChild(row('水平偏移', '', mkRange(0, 240, 1, pos.x, ' px', function (v) {
                pos.x = Math.round(v);
                updateBadgePositionOnly();
            })));
            c.appendChild(row('垂直偏移', '', mkRange(0, 400, 1, pos.y, ' px', function (v) {
                pos.y = Math.round(v);
                updateBadgePositionOnly();
            })));
        });

        var actions = ce('div', 'pv-btn-row');
        actions.appendChild(btn('恢复角标默认', 'pv-btn-sm', function () {
            work.badge = clone(defaults.badge);
            renderBody();
            refreshPreview();
        }));
        c.appendChild(actions);
        return c;
    }

    // ---- 本地通知卡

    function buildNotifyCard() {
        var c = card('本地通知', '浏览器系统通知：页面打开时，阶段转折或托管提醒触发时弹窗提醒。');

        var pText = ce('div', 'pv-msg pv-msg-muted', permissionText());
        c.appendChild(pText);

        c.appendChild(row('启用本地通知', '',
            mkSwitch(work.localNotify.enabled, function (v) {
                work.localNotify.enabled = v;
            })));

        c.appendChild(row('阶段转折时通知', '高峰期 / 低峰期切换时提醒。',
            mkSwitch(work.localNotify.onTransition, function (v) {
                work.localNotify.onTransition = v;
            })));

        c.appendChild(row('托管提醒触发时通知', '服务端通过推送渠道发出提醒时同步通知。',
            mkSwitch(work.localNotify.onReminder, function (v) {
                work.localNotify.onReminder = v;
            })));

        var actions = ce('div', 'pv-btn-row');
        actions.appendChild(btn('请求通知权限', 'pv-btn-sm', function () {
            if (!notifySupported()) {
                toast('当前浏览器不支持通知');
                return;
            }
            Notification.requestPermission().then(function (p) {
                pText.textContent = permissionText();
                toast(p === 'granted' ? '已获得通知权限' : '未获得权限：' + p);
            });
        }));
        actions.appendChild(btn('发送测试通知', 'pv-btn-sm', function () {
            if (!notifySupported() || Notification.permission !== 'granted') {
                toast('请先授权通知');
                return;
            }
            notify('峰谷提醒测试', '如果你看到这条通知，说明本地通知可用。');
        }));
        c.appendChild(actions);
        return c;
    }

    function permissionText() {
        if (!notifySupported()) { return '当前浏览器不支持 Notification API'; }
        var p = Notification.permission;
        if (p === 'granted') { return '通知权限：已授权'; }
        if (p === 'denied') { return '通知权限：已被拒绝（需在浏览器站点设置中开启）'; }
        return '通知权限：尚未授权';
    }

    // ---- 推送渠道卡

    function buildChannelCard() {
        var c = card('推送渠道', '提醒通过以下渠道发送。密钥保存在服务端配置文件（权限 0600），接口返回时自动打码。');

        if (channelMsg) {
            var m = ce('div', 'pv-msg ' + (channelMsg.indexOf('✅') === 0 ? 'pv-msg-ok' : 'pv-msg-err'), channelMsg);
            c.appendChild(m);
        }

        var list = ce('div', 'pv-row-col');
        if (!work.channels.length) {
            list.appendChild(ce('div', 'pv-empty', '还没有推送渠道。添加一个后，提醒才能送达手机。'));
        }
        work.channels.forEach(function (ch) {
            var item = ce('div', 'pv-channel');
            var info = ce('div', 'pv-channel-info');
            info.appendChild(ce('div', 'pv-channel-name', ch.name || ch.type));
            var configured = channelConfigured(ch);
            var subText = ch.type + ' · ' + (configured ? '已配置' : '未填写完整');
            info.appendChild(ce('div', 'pv-channel-sub', subText));
            item.appendChild(info);

            var tagCls = 'pv-tag';
            var tagText = '已启用';
            if (!ch.enabled) { tagCls += ' pv-tag-off'; tagText = '已停用'; }
            else if (!configured) { tagCls += ' pv-tag-warn'; tagText = '待完善'; }
            item.appendChild(ce('span', tagCls, tagText));

            item.appendChild(btn('编辑', 'pv-btn-sm', function () {
                editingChannel = clone(ch);
                renderBody();
            }));
            item.appendChild(btn('测试', 'pv-btn-sm', function () {
                channelMsg = '发送中…';
                renderBody();
                api('channelTest', { id: ch.id }).then(function (r) {
                    channelMsg = r.ok ? '✅ 发送成功：' + (r.name || ch.name) : '❌ 发送失败：' + (r.error || '未知错误');
                    renderBody();
                }).catch(function (e) {
                    channelMsg = '❌ 发送失败：' + e.message;
                    renderBody();
                });
            }));
            item.appendChild(btn('删除', 'pv-btn-danger pv-btn-sm', function () {
                if (!confirm('删除渠道「' + (ch.name || ch.type) + '」？')) { return; }
                api('channelDelete', { id: ch.id }).then(function () {
                    return api('config');
                }).then(function (v) {
                    cfg = v.config;
                    work.channels = clone(cfg.channels);
                    channelMsg = '✅ 已删除';
                    renderBody();
                }).catch(function (e) { toast('删除失败：' + e.message); });
            }));

            list.appendChild(item);
        });
        c.appendChild(list);

        // 渠道编辑表单
        if (editingChannel) {
            c.appendChild(buildChannelForm());
        } else {
            var actions = ce('div', 'pv-btn-row');
            actions.appendChild(btn('＋ 添加渠道', 'pv-btn-primary pv-btn-sm', function () {
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
        box.appendChild(ce('div', 'pv-card-title', editingChannel.id ? '编辑渠道' : '添加渠道'));

        // 类型
        var typeOpts = channelTypes.map(function (t) { return { value: t.type, label: t.name }; });
        if (!typeOpts.length) {
            typeOpts = [{ value: 'serverchan', label: 'Server酱' }];
        }
        box.appendChild(row('渠道类型', '', mkSelect(typeOpts, editingChannel.type, function (v) {
            editingChannel.type = v;
            var meta = findChannelType(v);
            if (!editingChannel.id && meta) { editingChannel.name = meta.name; }
            renderBody();
        })));

        box.appendChild(row('名称', '仅用于列表展示。',
            mkText(editingChannel.name, '例如：我的手机', function (v) { editingChannel.name = v; })));

        var meta = findChannelType(editingChannel.type);
        var fields = meta ? meta.fields : ['key'];

        if (fields.indexOf('key') >= 0) {
            var keyLabel = editingChannel.type === 'telegram' ? 'Bot Token' : (editingChannel.type === 'bark' ? 'DeviceKey' : '密钥 / SendKey');
            box.appendChild(row(keyLabel, '已保存的密钥会显示为打码形式，不修改则保留原值。',
                mkText(editingChannel.key, '在此填写', function (v) { editingChannel.key = v; })));
        }
        if (fields.indexOf('server') >= 0) {
            var srvLabel = editingChannel.type === 'webhook' ? 'Webhook 地址' : 'Webhook / 服务器地址';
            box.appendChild(row(srvLabel, editingChannel.type === 'bark' ? '留空使用 https://api.day.app' : '完整 URL',
                mkText(editingChannel.server, 'https://', function (v) { editingChannel.server = v; })));
        }
        if (fields.indexOf('chatId') >= 0) {
            box.appendChild(row('Chat ID', 'Telegram 会话 ID。',
                mkText(editingChannel.chatId, '例如 123456789', function (v) { editingChannel.chatId = v; })));
        }
        if (fields.indexOf('secret') >= 0) {
            box.appendChild(row('加签密钥', '钉钉 / 飞书的 secret，可选。',
                mkText(editingChannel.secret, '可选', function (v) { editingChannel.secret = v; })));
        }
        if (fields.indexOf('method') >= 0) {
            box.appendChild(row('请求方法', '',
                mkSelect([{ value: 'POST', label: 'POST' }, { value: 'GET', label: 'GET' }],
                    editingChannel.method || 'POST', function (v) { editingChannel.method = v; })));
        }
        if (fields.indexOf('body') >= 0) {
            box.appendChild(row('请求体模板', '支持 {title} 与 {content} 占位。',
                mkTextarea(editingChannel.body, '{"title":"{title}","content":"{content}"}',
                    function (v) { editingChannel.body = v; })));
        }

        box.appendChild(row('启用该渠道', '',
            mkSwitch(editingChannel.enabled, function (v) { editingChannel.enabled = v; })));

        var actions = ce('div', 'pv-btn-row');
        actions.appendChild(btn('保存渠道', 'pv-btn-primary pv-btn-sm', function () {
            var payload = clone(editingChannel);
            api('channelSave', { channel: payload }).then(function () {
                return api('config');
            }).then(function (v) {
                cfg = v.config;
                work.channels = clone(cfg.channels);
                editingChannel = null;
                channelMsg = '✅ 渠道已保存';
                renderBody();
            }).catch(function (e) {
                channelMsg = '❌ ' + e.message;
                renderBody();
            });
        }));
        actions.appendChild(btn('取消', 'pv-btn-sm', function () {
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
        var c = card(isPeak ? '高峰期提醒' : '低峰期提醒',
            '到达' + (isPeak ? '高峰' : '低峰') + '前（或到达时）通过推送渠道发送提醒。调度在服务端执行，页面关闭也会送达。');

        c.appendChild(row('启用提醒', '',
            mkSwitch(r.enabled, function (v) { r.enabled = v; })));

        c.appendChild(row('提前提醒', '0 表示准时在阶段开始的那一刻发送。',
            mkSelect([
                { value: '0', label: '准时（到达时）' },
                { value: '5', label: '提前 5 分钟' },
                { value: '10', label: '提前 10 分钟' },
                { value: '15', label: '提前 15 分钟' },
                { value: '30', label: '提前 30 分钟' },
                { value: '60', label: '提前 60 分钟' }
            ], String(r.leadMinutes), function (v) { r.leadMinutes = parseInt(v, 10) || 0; })));

        var chOpts = [{ value: 'all', label: '全部启用渠道' }];
        work.channels.forEach(function (ch) {
            chOpts.push({ value: 'id:' + ch.id, label: (ch.name || ch.type) });
        });
        if (r.channel && r.channel !== 'all' && r.channel.indexOf('id:') !== 0 && !findChannel(r.channel)) {
            chOpts.push({ value: r.channel, label: r.channel });
        }
        c.appendChild(row('推送渠道', '',
            mkSelect(chOpts, r.channel || 'all', function (v) { r.channel = v; })));

        c.appendChild(row('标题模板', '可用变量：{phase} {start} {end} {time} {date}',
            mkText(r.title, 'DeepSeek 高峰期开始', function (v) { r.title = v; })));

        c.appendChild(row('内容模板', '同样支持上述变量。',
            mkTextarea(r.content, '{phase}开始：{start}～{end}', function (v) { r.content = v; })));

        c.appendChild(row('额外固定时间', 'HH:MM，多个用逗号分隔；仅在该阶段进行中触发。',
            mkText(r.times, '例如 10:30,15:00', function (v) { r.times = v; })));

        var actions = ce('div', 'pv-btn-row');
        actions.appendChild(btn('发送测试', 'pv-btn-sm', function () {
            var info = ce('div', 'pv-msg pv-msg-muted', '发送中…');
            c.appendChild(info);
            api('test', { kind: phase, channel: r.channel, title: r.title, content: r.content })
                .then(function (v) {
                    var ok = v.result && v.result.ok;
                    info.className = 'pv-msg ' + (ok ? 'pv-msg-ok' : 'pv-msg-err');
                    info.textContent = ok
                        ? '✅ 已发送（' + v.result.sent + '/' + v.result.total + '）\n' + v.title
                        : '❌ ' + ((v.result && v.result.error) || '发送失败');
                }).catch(function (e) {
                    info.className = 'pv-msg pv-msg-err';
                    info.textContent = '❌ ' + e.message;
                });
        }));
        actions.appendChild(btn('立即触发一次', 'pv-btn-sm', function () {
            api('fireNow', { phase: phase }).then(function (v) {
                if (v.skipped) {
                    toast('该阶段提醒未启用');
                    return;
                }
                var ok = v.result && v.result.ok;
                toast(ok ? '已触发并发送' : '触发失败：' + ((v.result && v.result.error) || '未知错误'));
            }).catch(function (e) { toast('触发失败：' + e.message); });
        }));
        c.appendChild(actions);

        if (r.lastFiredAt) {
            var res = r.lastResult;
            var text = '最近触发：' + formatTime(r.lastFiredAt);
            if (res) {
                text += res.ok ? ' · 成功 ' + res.sent + '/' + res.total : ' · 失败：' + (res.error || '');
            }
            c.appendChild(ce('div', 'pv-msg ' + (res && res.ok ? 'pv-msg-ok' : 'pv-msg-err'), text));
        } else {
            c.appendChild(ce('div', 'pv-msg pv-msg-muted', '尚未触发过'));
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

    // ---- 关于卡

    function buildAboutCard() {
        var c = card('关于', '');
        var lines = [
            '官方时段（北京时间）：高峰 09:00–12:00、14:00–18:00；其余为低峰（空闲）时段，API 价格约为高峰一半。',
            '生效日期：2026-08-17 起。',
            '配置文件：' + (dataPath || 'data/peakvalley/config.json'),
            '调度：服务端每 30 秒检查一次；服务重启后会补发 10 分钟内到期的提醒。'
        ];
        lines.forEach(function (t) {
            c.appendChild(ce('div', 'pv-card-desc', t));
        });
        return c;
    }

    // ============================================================ 启动

    function bindEntryButtons() {
        var sbBtn = $('sidebarPeakValleyBtn');
        if (sbBtn) {
            sbBtn.addEventListener('click', function () {
                // 关闭侧边栏后再打开面板
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

        // 聊天界面开关会影响「仅在 DeepSeek 聊天生效」的判定
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
            // 服务端未就绪时静默重试，不打扰页面
            setTimeout(boot, 3000);
        });
    }

    // 对外接口（便于调试与外部调用）
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
