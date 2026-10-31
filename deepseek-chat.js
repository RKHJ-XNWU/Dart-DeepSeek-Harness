// deepseek-chat.js - DeepSeek 聊天前端 v8（极速打字 / 弹窗可视化 / 5万轮工具模式）
(function () {
    'use strict';
    console.log('[DSC] 脚本加载中 v8');

    var DEFAULT_LEVEL = 15;
    var ADVANCED_DEFAULT_LEVEL = 30;
    var LONG_TEXT_DEFAULT_CHARS = 150000;
    var TTS_CHUNK_SIZE = 3000;
    var NOVEL_DEFAULT_CHARS = 30000;
    var NOVEL_MAX_CHARS = 1000000;

    var MSG_RENDER_WINDOW = 10;
    var MSG_LOAD_STEP = 10;
    var MSG_PAGE_SIZE = 40;
    var SCROLL_TOP_THRESHOLD = 80;
    var NEAR_BOTTOM_THRESHOLD = 160;

    var state = {
        sessions: [],
        currentSessionId: null,
        messages: [],
        isSending: false,
        abortCtrl: null,
        stopRequested: false,
        searchQuery: '',
        useRegex: false,
        confirmCb: null,
        renameSaveCb: null,
        webSearch: false,
        deepThink: false,
        reasoningLevel: DEFAULT_LEVEL,
        tempLevel: DEFAULT_LEVEL,
        advancedMode: false,
        advancedLevel: ADVANCED_DEFAULT_LEVEL,
        selectMode: false,
        checkedIds: {},
        currentAudio: null,
        currentSpeakBtn: null,
        ttsCancelled: false,
        longTextMode: false,
        longTextTargetChars: LONG_TEXT_DEFAULT_CHARS,
        currentModel: 'deepseek-flash', // 安全默认；启动后由 syncModelFromConfig() 用后端配置覆盖
        enableTools: false,
        renderedStart: 0,
        hasMore: false,
        loadingOlder: false,
        keepScroll: false,
        pendingScrollTop: 0,
        pendingScrollHeight: 0,
        scrollTick: false,
        typer: {
            contentBuf: '',
            contentShown: '',
            reasoningBuf: '',
            reasoningShown: '',
            rafId: null,
            bubbleEl: null,
            thinkBodyEl: null,
            thinkPanelEl: null,
            thinkLabelEl: null,
            msgEl: null,
            done: false,
            lastRenderTs: 0,
            lastScrollTs: 0,
        },
    };

    function loadMathJax() {
        if (window.MathJax) return;
        window.MathJax = {
            tex: {
                inlineMath: [['$', '$'], ['\\(', '\\)']],
                displayMath: [['$$', '$$'], ['\\[', '\\]']],
                processEscapes: true
            },
            options: {
                skipHtmlTags: ['script', 'noscript', 'style', 'textarea', 'pre', 'code']
            }
        };
        var script = document.createElement('script');
        script.src = '/tex-chtml-full-speech.js';
        script.async = true;
        document.head.appendChild(script);
    }

    function renderMath(container) {
        if (!container) return;
        if (!window.MathJax || !window.MathJax.typesetPromise) return;
        var txt = container.textContent || '';
        if (txt.indexOf('$') === -1 && txt.indexOf('\\(') === -1 && txt.indexOf('\\[') === -1) return;
        window.MathJax.typesetPromise([container]).catch(function (err) {
            console.warn('[DSC] MathJax 失败:', err);
        });
    }

    function $(id) { return document.getElementById(id); }

    function escapeHtml(s) {
        return String(s == null ? '' : s).replace(/[&<>"']/g, function (m) {
            return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[m];
        });
    }

    function toast(msg, type) {
        var wrap = $('dscToastWrap');
        if (!wrap) { console.log('[DSC]', msg); return; }
        var el = document.createElement('div');
        el.className = 'dsc-toast ' + (type || '');
        el.textContent = msg;
        wrap.appendChild(el);
        setTimeout(function () { el.remove(); }, 2600);
    }

    function showCenterError(msg) {
        var old = document.getElementById('dscCenterError');
        if (old) old.remove();
        var el = document.createElement('div');
        el.id = 'dscCenterError';
        el.textContent = msg;
        el.style.cssText =
            'position:fixed;top:50%;left:50%;transform:translate(-50%,-50%);' +
            'background:#4a4a4a;color:#ffffff;padding:14px 22px;border-radius:12px;' +
            'font-size:0.95rem;font-weight:500;line-height:1.5;letter-spacing:0.02em;' +
            'z-index:200000;box-shadow:0 4px 16px rgba(0,0,0,0.2);pointer-events:none;' +
            'text-align:center;white-space:nowrap;';
        document.body.appendChild(el);
        setTimeout(function () { if (el.parentNode) el.remove(); }, 3000);
    }

    function copyToClipboard(text) {
        if (text == null) { toast('内容为空', 'info'); return; }
        var str = String(text);
        if (str.length === 0) { toast('内容为空', 'info'); return; }
        if (navigator.clipboard && window.isSecureContext) {
            navigator.clipboard.writeText(str).then(function () {
                toast('✅ 已复制', 'success');
            }).catch(function () { fallbackCopy(str); });
        } else {
            fallbackCopy(str);
        }
    }

    function fallbackCopy(text) {
        var ta = document.createElement('textarea');
        ta.value = text;
        ta.style.position = 'fixed';
        ta.style.left = '-9999px';
        ta.setAttribute('readonly', '');
        document.body.appendChild(ta);
        try {
            ta.select();
            ta.setSelectionRange(0, ta.value.length);
            var ok = document.execCommand('copy');
            toast(ok ? '✅ 已复制' : '复制失败', ok ? 'success' : 'error');
        } catch (e) {
            toast('复制失败：' + e.message, 'error');
        }
        document.body.removeChild(ta);
    }

    function simpleConfirm(title, msg) {
        return new Promise(function (resolve) {
            var overlay = $('dscConfirmOverlay');
            if (!overlay) { resolve(window.confirm(title + '\n' + msg)); return; }
            $('dscConfirmTitle').textContent = title;
            $('dscConfirmMsg').textContent = msg;
            overlay.classList.add('open');
            state.confirmCb = function (ok) {
                overlay.classList.remove('open');
                state.confirmCb = null;
                resolve(ok);
            };
        });
    }

    function formatTime(iso) {
        if (!iso) return '';
        try {
            var d = new Date(iso);
            var now = new Date();
            var sameDay = d.toDateString() === now.toDateString();
            var pad = function (n) { return String(n).padStart(2, '0'); };
            if (sameDay) return pad(d.getHours()) + ':' + pad(d.getMinutes());
            return (d.getMonth() + 1) + '/' + d.getDate() + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
        } catch (e) { return ''; }
    }

    // ============================================================
    // ★ 单条回复的真实 token 消耗（provider usage 计费口径，不估算）
    // ============================================================
    function fmtTokNum(n) {
        n = Number(n) || 0;
        return n.toLocaleString('en-US');
    }

    function dsUsageChipHtml(u) {
        if (!u) return '';
        var hit = Number(u.promptCacheHitTokens) || 0;
        var miss = Number(u.promptCacheMissTokens) || 0;
        var prompt = Number(u.promptTokens) || (hit + miss);
        var outTok = Number(u.completionTokens) || 0;
        var total = Number(u.totalTokens) || (prompt + outTok);
        if (!total && !prompt && !outTok) return '';
        var calls = Number(u.apiCalls) || 1;

        var html = '<span class="dsc-usage-chip" title="本条回复的真实 token 消耗：来自模型 API 返回的 usage（计费口径），不是本地估算">';
        html += '<span class="ic">⛁</span>';
        html += '<span>输入 <b>' + fmtTokNum(prompt) + '</b></span>';
        html += '<span class="dsc-usage-sep">·</span>';
        html += '<span>缓存命中 <b class="dsc-usage-hit">' + fmtTokNum(hit) + '</b></span>';
        html += '<span class="dsc-usage-sep">·</span>';
        html += '<span>未命中 <b class="dsc-usage-miss">' + fmtTokNum(miss) + '</b></span>';
        html += '<span class="dsc-usage-sep">·</span>';
        html += '<span>输出 <b class="dsc-usage-out">' + fmtTokNum(outTok) + '</b></span>';
        html += '<span class="dsc-usage-sep">·</span>';
        html += '<span>合计 <b>' + fmtTokNum(total) + '</b></span>';
        if (calls > 1) {
            html += '<span class="dsc-usage-sep">·</span><span>' + calls + ' 次调用</span>';
        }
        html += '</span>';
        return html;
    }

    // ============================================================
    // ★ 费用计算 v2（模型单价 + 高峰/空闲时段）
    //   高峰：北京时间 周一~周五（不含法定节假日）09:00-12:00、14:00-18:00
    //   空闲：其余全部时段（含午休 12:00-14:00、夜间、周末、法定节假日全天）
    //   空闲单价 = 高峰单价的一半，故高峰 factor=2，空闲 factor=1
    //   单价单位：元 / 百万 tokens
    // ============================================================
    var DSC_PRICE = {
        'deepseek-flash': { hit: 0.02, miss: 1.0, out: 4.0 },
        'deepseek-v4-flash': { hit: 0.02, miss: 1.0, out: 4.0 },
        'deepseek-v4.1-flash': { hit: 0.02, miss: 1.0, out: 4.0 },
        'deepseek-v4.1-flash-1017': { hit: 0.02, miss: 1.0, out: 4.0 },
        'deepseek-v4-pro': { hit: 0.15, miss: 4.5, out: 13.5 },
        'deepseek-v4-pro-0813': { hit: 0.15, miss: 4.5, out: 13.5 },
        'deepseek-chat': { hit: 0.15, miss: 4.5, out: 13.5 },
        'deepseek-reasoner': { hit: 0.15, miss: 4.5, out: 13.5 }
    };
    
    // 中国法定节假日（含调休放假日）——按年维护；未列出的年份仅按周末判断
    var DSC_HOLIDAYS = {
        '2025-01-01': 1,
        '2025-01-28': 1, '2025-01-29': 1, '2025-01-30': 1, '2025-01-31': 1,
        '2025-02-01': 1, '2025-02-02': 1, '2025-02-03': 1, '2025-02-04': 1,
        '2025-04-04': 1, '2025-04-05': 1, '2025-04-06': 1,
        '2025-05-01': 1, '2025-05-02': 1, '2025-05-03': 1, '2025-05-04': 1, '2025-05-05': 1,
        '2025-05-31': 1, '2025-06-01': 1, '2025-06-02': 1,
        '2025-10-01': 1, '2025-10-02': 1, '2025-10-03': 1, '2025-10-04': 1,
        '2025-10-05': 1, '2025-10-06': 1, '2025-10-07': 1, '2025-10-08': 1,
        '2026-01-01': 1, '2026-01-02': 1, '2026-01-03': 1,
        '2026-02-15': 1, '2026-02-16': 1, '2026-02-17': 1, '2026-02-18': 1,
        '2026-02-19': 1, '2026-02-20': 1, '2026-02-21': 1, '2026-02-22': 1, '2026-02-23': 1,
        '2026-04-04': 1, '2026-04-05': 1, '2026-04-06': 1,
        '2026-05-01': 1, '2026-05-02': 1, '2026-05-03': 1, '2026-05-04': 1, '2026-05-05': 1,
        '2026-06-19': 1, '2026-06-20': 1, '2026-06-21': 1,
        '2026-09-25': 1, '2026-09-26': 1, '2026-09-27': 1,
        '2026-10-01': 1, '2026-10-02': 1, '2026-10-03': 1, '2026-10-04': 1,
        '2026-10-05': 1, '2026-10-06': 1, '2026-10-07': 1
    };
    
    function dscBjNow() {
        var now = new Date();
        // 统一换算到北京时间（UTC+8）
        return new Date(now.getTime() + (now.getTimezoneOffset() + 480) * 60000);
    }
    
    function dscYmd(d) {
        var p = function (n) { return n < 10 ? '0' + n : '' + n; };
        return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
    }
    
    // 是否高峰时段：周一~周五（非法定节假日）09:00-12:00、14:00-18:00
    function dscIsPeakHour() {
        try {
            var bj = dscBjNow();
            var day = bj.getDay();                 // 0=周日 6=周六
            if (day === 0 || day === 6) return false;      // 周末全天空闲
            if (DSC_HOLIDAYS[dscYmd(bj)]) return false;    // 法定节假日全天空闲
    
            var mins = bj.getHours() * 60 + bj.getMinutes();
            var morning = (mins >= 9 * 60 && mins < 12 * 60);   // 09:00-12:00
            var afternoon = (mins >= 14 * 60 && mins < 18 * 60); // 14:00-18:00
            return morning || afternoon;
        } catch (e) {
            return false;
        }
    }
    
    function dscPriceForModel(model) {
        var m = String(model || '').toLowerCase().trim();
        if (DSC_PRICE[m]) return DSC_PRICE[m];
        if (m.indexOf('pro') >= 0) return DSC_PRICE['deepseek-v4-pro'];
        return DSC_PRICE['deepseek-flash'];
    }
    
    function dscCalcCost(u, model) {
        if (!u) return null;
        var hit = Number(u.promptCacheHitTokens) || 0;
        var miss = Number(u.promptCacheMissTokens) || 0;
        var prompt = Number(u.promptTokens) || (hit + miss);
        if (!miss && prompt && !hit) miss = prompt;
        var out = Number(u.completionTokens) || 0;
        if (!hit && !miss && !out) return null;
    
        var price = dscPriceForModel(model);
        var peak = dscIsPeakHour();
        var factor = peak ? 2 : 1;   // 空闲 = 高峰的一半
    
        var cost =
            hit  * price.hit  * factor / 1e6 +
            miss * price.miss * factor / 1e6 +
            out  * price.out  * factor / 1e6;
    
        return { cost: cost, peak: peak, hit: hit, miss: miss, out: out, total: hit + miss + out };
    }
    
    function dscFmtCost(cost) {
        if (cost == null || isNaN(cost)) return '';
        if (cost === 0) return '0 元';
        if (cost < 0.0001) return cost.toFixed(6) + ' 元';
        if (cost < 0.01) return cost.toFixed(4) + ' 元';
        if (cost < 1) return cost.toFixed(3) + ' 元';
        return cost.toFixed(2) + ' 元';
    }
    
    function dscCostChipHtml(u, model) {
        var r = dscCalcCost(u, model);
        if (!r) return '';
        var tip = '按' + (r.peak ? '高峰' : '空闲') + '时段单价计算（空闲=高峰一半）：' +
            '命中 ' + fmtTokNum(r.hit) + ' / 未命中 ' + fmtTokNum(r.miss) +
            ' / 输出 ' + fmtTokNum(r.out);
        return '<span class="dsc-cost-chip" title="' + escapeHtml(tip) + '">' +
            '<span class="ic">💰</span>' +
            '<span>' + dscFmtCost(r.cost) + '</span>' +
            '<span class="dsc-cost-tag">' + (r.peak ? '高峰' : '空闲') + '</span>' +
            '</span>';
    }

        function dsUsageBlockHtml(u, model) {
        var chip = dsUsageChipHtml(u);
        if (!chip) return '';
        var costChip = dscCostChipHtml(u, model);
        return '<div class="dsc-msg-usage">' + chip + costChip + '</div>';
    }

    function b64EncodeUnicode(str) {
        try { return btoa(unescape(encodeURIComponent(str))); }
        catch (e) { return ''; }
    }
    function b64DecodeUnicode(str) {
        try { return decodeURIComponent(escape(atob(str))); }
        catch (e) { return ''; }
    }

    function isNearBottom(el, threshold) {
        if (!el) return true;
        var th = threshold || NEAR_BOTTOM_THRESHOLD;
        return (el.scrollHeight - el.scrollTop - el.clientHeight) < th;
    }

    function scrollToBottom(force) {
        var wrap = $('dscMessages');
        if (!wrap) return;
        if (!force && !isNearBottom(wrap, NEAR_BOTTOM_THRESHOLD)) return;

        function doScroll() {
            if (!wrap) return;
            var last = wrap.lastElementChild;
            if (last && last.classList && last.classList.contains('dsc-msg')) {
                var wr = wrap.getBoundingClientRect();
                var lr = last.getBoundingClientRect();
                wrap.scrollTop += (lr.bottom - wr.bottom);
            } else {
                wrap.scrollTop = wrap.scrollHeight;
            }
        }

        if (force) {
            doScroll();
            requestAnimationFrame(function () {
                doScroll();
                requestAnimationFrame(doScroll);
            });
            setTimeout(doScroll, 60);
            setTimeout(doScroll, 200);
        } else {
            requestAnimationFrame(function () {
                if (isNearBottom(wrap, NEAR_BOTTOM_THRESHOLD + 40)) {
                    doScroll();
                }
            });
        }
    }

    // ================= renderMarkdown =================
    function renderMarkdown(text) {
        if (!text) return '';
        var html = escapeHtml(text);
        var codeBlocks = [];
        var mathBlocks = [];

        html = html.replace(/```([a-zA-Z0-9_+\-]*)\n?([\s\S]*?)```/g, function (m, lang, code) {
            var raw = code
                .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
                .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/\n$/, '');
            codeBlocks.push(raw);
            return '\u0000CB' + (codeBlocks.length - 1) + '\u0000';
        });

        html = html.replace(/\$\$([\s\S]*?)\$\$/g, function (m) {
            mathBlocks.push(m);
            return '\u0000MATH' + (mathBlocks.length - 1) + '\u0000';
        });
        html = html.replace(/\$([^\$\n]+?)\$/g, function (m) {
            mathBlocks.push(m);
            return '\u0000MATH' + (mathBlocks.length - 1) + '\u0000';
        });

        html = html.replace(/(^\|[^\n]+\|\s*\n\|[\s\-:|]+\|\s*\n(?:\|[^\n]+\|\s*\n?)+)/gm, function (tbl) {
            var lines = tbl.trim().split('\n');
            if (lines.length < 3) return tbl;
            var header = lines[0].split('|').map(function (c) { return c.trim(); }).filter(function (c, i, a) { return i > 0 && i < a.length - 1; });
            var rows = lines.slice(2).map(function (l) {
                return l.split('|').map(function (c) { return c.trim(); }).filter(function (c, i, a) { return i > 0 && i < a.length - 1; });
            });
            var out = '<table><thead><tr>';
            header.forEach(function (h) { out += '<th>' + h + '</th>'; });
            out += '</tr></thead><tbody>';
            rows.forEach(function (r) {
                out += '<tr>';
                r.forEach(function (c) { out += '<td>' + c + '</td>'; });
                out += '</tr>';
            });
            out += '</tbody></table>';
            return out;
        });

        html = html.replace(/^#### (.+)$/gm, '<h4>$1</h4>');
        html = html.replace(/^### (.+)$/gm, '<h3>$1</h3>');
        html = html.replace(/^## (.+)$/gm, '<h2>$1</h2>');
        html = html.replace(/^# (.+)$/gm, '<h1>$1</h1>');
        html = html.replace(/^&gt; ?(.*)$/gm, '<blockquote>$1</blockquote>');
        html = html.replace(/<\/blockquote>\n<blockquote>/g, '\n');
        html = html.replace(/^---+$/gm, '<hr>');
        html = html.replace(/^\*\*\*+$/gm, '<hr>');
        html = html.replace(/^[\-\*] (.+)$/gm, '<li-ul>$1</li-ul>');
        html = html.replace(/^\d+\. (.+)$/gm, '<li-ol>$1</li-ol>');
        html = html.replace(/`([^`\n]+)`/g, '<code>$1</code>');
        html = html.replace(/\*\*([^*\n]+?)\*\*/g, '<strong>$1</strong>');
        html = html.replace(/__([^_\n]+?)__/g, '<strong>$1</strong>');
        html = html.replace(/(^|[^*\d\s])\*([^*\n]+?)\*/g, '$1<em>$2</em>');
        html = html.replace(/\[([^\]]+)\]\((https?:\/\/[^\s\)]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
        html = html.replace(/(^|[^"'>])(https?:\/\/[^\s<>"）\)]+)/g, function (m, pre, url) {
            return pre + '<a href="' + url + '" target="_blank" rel="noopener">' + url + '</a>';
        });

        html = html.replace(/\n\n+/g, '</p><p>');
        html = html.replace(/\n/g, '<br>');
        html = '<p>' + html + '</p>';
        html = html.replace(/<p>(<h[1-4]>)/g, '$1');
        html = html.replace(/(<\/h[1-4]>)<\/p>/g, '$1');
        html = html.replace(/<p>(<table>)/g, '$1');
        html = html.replace(/(<\/table>)<\/p>/g, '$1');
        html = html.replace(/<p>(<hr>)<\/p>/g, '$1');
        html = html.replace(/<p>(<blockquote>)/g, '$1');
        html = html.replace(/(<\/blockquote>)<\/p>/g, '$1');
        html = html.replace(/<p><\/p>/g, '');
        html = html.replace(/<p>(<br>)+/g, '<p>');
        html = html.replace(/(<li-ul>[\s\S]*?<\/li-ul>)+/g, function (m) {
            var items = m.replace(/<li-ul>/g, '<li>').replace(/<\/li-ul>/g, '</li>');
            return '<ul>' + items + '</ul>';
        });
        html = html.replace(/(<li-ol>[\s\S]*?<\/li-ol>)+/g, function (m) {
            var items = m.replace(/<li-ol>/g, '<li>').replace(/<\/li-ol>/g, '</li>');
            return '<ol>' + items + '</ol>';
        });
        html = html.replace(/\u0000CB(\d+)\u0000/g, function (m, i) {
            var raw = codeBlocks[+i];
            var b64 = b64EncodeUnicode(raw);
            return '<div class="dsc-code-block">' +
                '<button class="dsc-code-copy" type="button" data-raw="' + b64 + '">📋 复制</button>' +
                '<pre><code>' + escapeHtml(raw) + '</code></pre>' +
                '</div>';
        });
        html = html.replace(/\u0000MATH(\d+)\u0000/g, function (m, i) { return mathBlocks[+i]; });
        return html;
    }

    // ================= 首屏快照（本地缓存 → 打开即见内容） =================
    // 思路：上一次的会话列表 / 最近一页消息留一份快照在 localStorage，
    // 面板打开瞬间先同步渲染快照（0 网络等待），随后再向服务端校真，
    // 数据没变就零重绘，数据变了只做增量替换 —— 会话再多也不会"白屏等加载"。
    var DSC_SNAP_SESSIONS = 'dsc_snap_sessions_v1';
    var DSC_SNAP_MSGS = 'dsc_snap_msgs_v1';
    var DSC_SNAP_LAST = 'dsc_snap_lastSession_v1';
    var _snapTimer = null;

    function dscReadSnap(key) {
        try { var raw = localStorage.getItem(key); return raw ? JSON.parse(raw) : null; } catch (e) { return null; }
    }
    function dscWriteSnap(key, val) {
        try { localStorage.setItem(key, JSON.stringify(val)); } catch (e) {}
    }
    function dscSaveSessionsSnap() {
        dscWriteSnap(DSC_SNAP_SESSIONS, { t: Date.now(), sessions: state.sessions });
        if (state.currentSessionId) dscWriteSnap(DSC_SNAP_LAST, state.currentSessionId);
    }
    function dscSaveMsgsSnap() {
        if (!state.currentSessionId || !state.messages) return;
        dscWriteSnap(DSC_SNAP_MSGS, {
            t: Date.now(),
            sid: state.currentSessionId,
            messages: state.messages.slice(-MSG_PAGE_SIZE),
            hasMore: !!state.hasMore
        });
    }
    function dscScheduleMsgsSnap() {
        if (_snapTimer) return;
        _snapTimer = setTimeout(function () {
            _snapTimer = null;
            try { dscSaveMsgsSnap(); } catch (e) {}
        }, 1200);
    }
    // 用快照立即上屏；返回 true 表示已经画出了内容
    function paintFromSnapshot() {
        var snap = dscReadSnap(DSC_SNAP_SESSIONS);
        if (!snap || !snap.sessions || !snap.sessions.length) return false;
        state.sessions = snap.sessions;
        if (!state.currentSessionId) {
            // 修复：打开时始终恢复"最新会话"(snap.sessions[0])，
            // 不再用上次的当前会话(DSC_SNAP_LAST)恢复到最早的旧对话。
            state.currentSessionId = snap.sessions[0].id;
        }
        try { renderSessions(); } catch (e) {}
        try { updateTitle(); } catch (e) {}
        var ms = dscReadSnap(DSC_SNAP_MSGS);
        if (ms && ms.sid === state.currentSessionId && ms.messages && ms.messages.length) {
            state.messages = ms.messages;
            state.hasMore = !!ms.hasMore;
            try { renderMessages(); } catch (e) {}
        }
        return true;
    }

    // ================= 会话列表 =================
    async function loadSessions() {
        try {
            var res = await fetch('/api/ds-chat/sessions', { cache: 'no-cache' });
            var data = await res.json();
            state.sessions = data.sessions || [];
            renderSessions();
            dscSaveSessionsSnap();
        } catch (e) { toast('加载会话失败', 'error'); }
    }

    function getFilteredSessions() {
        if (!state.searchQuery) return state.sessions;
        if (state.useRegex) {
            var re;
            try { re = new RegExp(state.searchQuery, 'i'); } catch (e) { return []; }
            return state.sessions.filter(function (s) { return re.test(s.title || ''); });
        }
        var q = state.searchQuery.toLowerCase();
        return state.sessions.filter(function (s) { return (s.title || '').toLowerCase().indexOf(q) !== -1; });
    }

    // ================= 会话列表虚拟滚动 =================
    // 只渲染可视区 + 缓冲区的会话项，DOM 节点数恒定（≈ 可视行数 + 2×缓冲），
    // 会话数量再多也不会卡顿。结构采用"占位层撑高度 + 绝对定位窗口"的标准虚拟列表模式。
    var sessionVS = {
        el: null, spacer: null, viewport: null,
        items: [],
        itemHeight: 54,
        rowGap: 4,
        buffer: 8,
        raf: null, measured: false,

        rowH: function () { return this.itemHeight + this.rowGap; },

        init: function (list) {
            if (this.el === list) return;
            this.el = list;
            this.spacer = document.createElement('div');
            this.spacer.className = 'dsc-session-spacer';
            this.viewport = document.createElement('div');
            this.viewport.className = 'dsc-session-viewport';
            this.el.appendChild(this.spacer);
            this.el.appendChild(this.viewport);
            this.el.addEventListener('scroll', this.onScroll.bind(this));
            var self = this;
            if (window.ResizeObserver) {
                this.ro = new ResizeObserver(function () { self.render(); });
                this.ro.observe(this.el);
            }
        },

        measure: function () {
            if (this.measured || !this.viewport) return;
            var probe = document.createElement('div');
            probe.className = 'dsc-session-item';
            probe.style.cssText = 'position:absolute;top:0;left:0;right:0;visibility:hidden;';
            probe.innerHTML =
                '<div class="dsc-s-checkbox"></div>' +
                '<div class="dsc-s-info">' +
                '<div class="dsc-s-title">测</div>' +
                '<div class="dsc-s-time">测</div>' +
                '</div>' +
                '<button class="dsc-s-ref" data-ref="1">🔗</button>' +
                '<button class="dsc-s-del" data-del="1">✕</button>';
            this.viewport.appendChild(probe);
            var h = probe.offsetHeight;
            probe.remove();
            if (h > 0) this.itemHeight = h;
            this.measured = true;
        },

        setItems: function (items) {
            this.items = items || [];
            this.measure();
            if (!this.items.length) {
                if (this.viewport) this.viewport.innerHTML = '';
                if (this.spacer) this.spacer.style.height = '0px';
                return;
            }
            var rh = this.rowH();
            var total = this.items.length * rh - this.rowGap;
            var maxScroll = Math.max(0, total - this.el.clientHeight);
            if (this.el.scrollTop > maxScroll) this.el.scrollTop = maxScroll;
            this.render();
        },

        onScroll: function () {
            var self = this;
            if (this.raf) return;
            this.raf = requestAnimationFrame(function () {
                self.raf = null;
                self.render();
            });
        },

        range: function () {
            var st = this.el.scrollTop;
            var vh = this.el.clientHeight;
            var rh = this.rowH() || 58;
            var first = Math.floor(st / rh);
            var visible = Math.ceil(vh / rh) + 1;
            var start = Math.max(0, first - this.buffer);
            var end = Math.min(this.items.length, first + visible + this.buffer);
            return { start: start, end: end };
        },

        buildItem: function (s, index) {
            var item = document.createElement('div');
            var isChecked = !!state.checkedIds[s.id];
            item.className = 'dsc-session-item' +
                (s.id === state.currentSessionId ? ' active' : '') +
                (isChecked ? ' checked' : '');
            item.dataset.id = s.id;
            item.style.cssText = 'position:absolute;top:' + (index * this.rowH()) + 'px;left:0;right:0;';
            item.innerHTML =
                '<div class="dsc-s-checkbox"></div>' +
                '<div class="dsc-s-info">' +
                '<div class="dsc-s-title">' + escapeHtml(s.title || '未命名') + '</div>' +
                '<div class="dsc-s-time">' + formatTime(s.updatedAt || s.createdAt) + '</div>' +
                '</div>' +
                '<button class="dsc-s-ref" data-ref="1" title="复制引用">🔗</button>' +
                '<button class="dsc-s-del" data-del="1">✕</button>';
            return item;
        },

        render: function () {
            if (!this.viewport || !this.el) return;
            if (!this.items.length) return;
            var r = this.range();
            var frag = document.createDocumentFragment();
            for (var i = r.start; i < r.end; i++) {
                frag.appendChild(this.buildItem(this.items[i], i));
            }
            this.viewport.innerHTML = '';
            this.viewport.appendChild(frag);
            this.spacer.style.height = (this.items.length * this.rowH() - this.rowGap) + 'px';
        }
    };

    function renderSessions() {
        var list = $('dscSessionList');
        var empty = $('dscSessionEmpty');
        var sidebar = $('dscSidebar');
        if (!list) return;
        var filtered = getFilteredSessions();
        sessionVS.init(list);
        sessionVS.setItems(filtered);
        if (filtered.length === 0) {
            if (empty) {
                empty.style.display = 'block';
                var p = empty.querySelector('p');
                if (p) p.textContent = state.searchQuery ? '没有匹配的会话' : '还没有会话';
            }
        } else if (empty) {
            empty.style.display = 'none';
        }
        if (sidebar) sidebar.classList.toggle('select-mode', state.selectMode);
        updateBatchUI();
    }

    function updateBatchUI() {
        var batchBar = $('dscSessionBatch');
        var countEl = $('dscBatchCount');
        var selectAll = $('dscBatchSelectAll');
        var selBtn = $('dscSelectModeBtn');
        if (batchBar) batchBar.classList.toggle('show', state.selectMode);
        if (selBtn) selBtn.textContent = state.selectMode ? '✕ 退出多选' : '☑️ 多选';
        var count = Object.keys(state.checkedIds).length;
        if (countEl) countEl.textContent = '已选 ' + count;
        var filtered = getFilteredSessions();
        if (selectAll) {
            selectAll.checked = filtered.length > 0 && filtered.every(function (s) { return state.checkedIds[s.id]; });
        }
    }

    async function createSession() {
        try {
            var res = await fetch('/api/ds-chat/sessions', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ title: '新对话' })
            });
            var data = await res.json();
            state.sessions.unshift(data.session);
            state.currentSessionId = data.session.id;
            state.messages = [];
            state.hasMore = false;
            renderSessions();
            renderMessages();
            updateTitle();
            dscSaveSessionsSnap();
            closeSidebar();
        } catch (e) { toast('新建会话失败', 'error'); }
    }

    async function selectSession(id) {
        if (state.selectMode) { toggleCheck(id); return; }
        if (id === state.currentSessionId) { closeSidebar(); return; }
        state.currentSessionId = id;
        renderSessions();
        await loadMessages();
        updateTitle();
        dscSaveSessionsSnap();
        closeSidebar();
    }

    function toggleCheck(id) {
        if (state.checkedIds[id]) delete state.checkedIds[id];
        else state.checkedIds[id] = true;
        renderSessions();
    }

    function openRenameDialog(initialTitle, onSave) {
        var overlay = $('dscRenameOverlay');
        var input = $('dscRenameInput');
        if (!overlay || !input) {
            var t = window.prompt('重命名会话', initialTitle || '');
            if (t !== null && onSave) onSave(t);
            return;
        }
        input.value = initialTitle || '';
        overlay.classList.add('open');
        state.renameSaveCb = onSave || null;
        setTimeout(function () { input.focus(); try { input.select(); } catch (e) {} }, 120);
    }

    function closeRenameDialog() {
        var overlay = $('dscRenameOverlay');
        if (overlay) overlay.classList.remove('open');
        state.renameSaveCb = null;
    }

    function saveRenameDialog() {
        var input = $('dscRenameInput');
        if (!input) return;
        var newTitle = input.value.trim();
        if (!newTitle) { toast('标题不能为空', 'info'); input.focus(); return; }
        var cb = state.renameSaveCb;
        state.renameSaveCb = null;
        closeRenameDialog();
        if (cb) cb(newTitle);
    }

    async function renameSession(id) {
        var sess = state.sessions.find(function (s) { return s.id === id; });
        if (!sess) return;
        openRenameDialog(sess.title || '', async function (newTitle) {
            try {
                var res = await fetch('/api/ds-chat/sessions', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ id: id, title: newTitle })
                });
                var data = await res.json();
                if (!res.ok) throw new Error(data.error || '重命名失败');
                sess.title = newTitle;
                sess.updatedAt = new Date().toISOString();
                renderSessions();
                updateTitle();
                toast('已重命名', 'success');
            } catch (e) { toast('重命名失败：' + e.message, 'error'); }
        });
    }

    async function deleteSession(id, e) {
        if (e) e.stopPropagation();
        var sess = state.sessions.find(function (s) { return s.id === id; });
        if (!sess) return;
        var ok = await simpleConfirm('删除会话', '确定删除「' + sess.title + '」及其所有消息吗？');
        if (!ok) return;
        try {
            await fetch('/api/ds-chat/sessions?id=' + encodeURIComponent(id), { method: 'DELETE' });
            state.sessions = state.sessions.filter(function (s) { return s.id !== id; });
            delete state.checkedIds[id];
            if (state.currentSessionId === id) {
                state.currentSessionId = state.sessions.length > 0 ? state.sessions[0].id : null;
                if (state.currentSessionId) await loadMessages();
                else { state.messages = []; state.hasMore = false; renderMessages(); }
                updateTitle();
            }
            renderSessions();
            if (typeof window.dsLoadFiles === 'function') window.dsLoadFiles();
            toast('已删除', 'success');
        } catch (e2) { toast('删除失败', 'error'); }
    }

    async function copySessionReference(id, btn, e) {
        if (e) e.stopPropagation();
        try {
            var res = await fetch('/api/ds-chat/session-mention?sessionId=' + encodeURIComponent(id));
            var data = await res.json();
            if (!res.ok) throw new Error(data.error || '获取引用失败');
            copyToClipboard(data.mention);
            if (btn) {
                var orig = btn.textContent;
                btn.textContent = '✓';
                btn.classList.add('copied');
                setTimeout(function () { btn.textContent = orig; btn.classList.remove('copied'); }, 1500);
            }
        } catch (err) {
            toast('复制引用失败：' + err.message, 'error');
        }
    }

    async function batchDeleteSessions() {
        var ids = Object.keys(state.checkedIds);
        if (ids.length === 0) { toast('请先选择会话', 'info'); return; }
        var ok = await simpleConfirm('批量删除', '确定删除选中的 ' + ids.length + ' 个会话吗？');
        if (!ok) return;
        try {
            var res = await fetch('/api/ds-chat/sessions/batch-delete', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ ids: ids })
            });
            var data = await res.json();
            if (!res.ok) throw new Error(data.error || '删除失败');
            state.sessions = state.sessions.filter(function (s) { return !state.checkedIds[s.id]; });
            if (state.checkedIds[state.currentSessionId]) {
                state.currentSessionId = state.sessions.length > 0 ? state.sessions[0].id : null;
                if (state.currentSessionId) await loadMessages();
                else { state.messages = []; state.hasMore = false; renderMessages(); }
                updateTitle();
            }
            state.checkedIds = {};
            state.selectMode = false;
            renderSessions();
            if (typeof window.dsLoadFiles === 'function') window.dsLoadFiles();
            toast('已删除 ' + data.deleted + ' 个会话', 'success');
        } catch (e) { toast('批量删除失败: ' + e.message, 'error'); }
    }

    async function clearAllSessions() {
        if (state.sessions.length === 0) { toast('没有会话', 'info'); return; }
        var ok = await simpleConfirm('清空全部', '确定删除全部 ' + state.sessions.length + ' 个会话及其所有消息吗？此操作不可恢复！');
        if (!ok) return;
        try {
            var res = await fetch('/api/ds-chat/sessions/batch-delete', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ all: true })
            });
            if (!res.ok) throw new Error('清空失败');
            state.sessions = [];
            state.currentSessionId = null;
            state.messages = [];
            state.hasMore = false;
            state.checkedIds = {};
            state.selectMode = false;
            renderSessions();
            renderMessages();
            updateTitle();
            if (typeof window.dsLoadFiles === 'function') window.dsLoadFiles();
            toast('已清空全部会话', 'success');
        } catch (e) { toast('清空失败: ' + e.message, 'error'); }
    }

    function updateTitle() {
        var sess = state.sessions.find(function (s) { return s.id === state.currentSessionId; });
        var titleEl = $('dscChatTitle');
        var subEl = $('dscChatSub');
        // ★ 顶部固定显示「探索未至之境」，会话信息下移到副标题行
        if (titleEl) titleEl.textContent = '探索未至之境';
        if (sess) {
            if (subEl) subEl.textContent = (sess.title || '未命名') + ' · 共 ' + state.sessions.length + ' 个会话 · ' + state.currentModel;
        } else {
            if (subEl) subEl.textContent = 'DeepSeek 聊天 · 模型: ' + state.currentModel;
        }
    }

    async function loadMessages() {
        if (!state.currentSessionId) { state.messages = []; state.hasMore = false; renderMessages(); return; }
        try {
            var res = await fetch('/api/ds-chat/messages?sessionId=' + encodeURIComponent(state.currentSessionId) + '&limit=' + MSG_PAGE_SIZE);
            var data = await res.json();
            state.messages = data.messages || [];
            state.hasMore = !!data.hasMore;
            renderMessages();
            dscSaveMsgsSnap();
        } catch (e) { toast('加载消息失败', 'error'); }
    }

    function renderMessages() {
        var wrap = $('dscMessages');
        if (!wrap) return;
        wrap.innerHTML = '';

        if (state.messages.length === 0) {
            state.renderedStart = 0;
            var welcomeTexts = [
                "你好，让我们开始聊天吧", "欢迎回来，有什么需要吗？", "嗨，今天过得怎么样？",
                "好久不见，想聊点什么？", "又见面啦，今天有什么新鲜事？", "今天想聊点什么？",
                "有什么我可以帮你的吗？", "需要我做点什么吗？", "有什么想问的，尽管说",
                "想聊什么话题？我都在", "我在这里，随时准备帮助你", "无论大事小事，都可以和我说说",
                "我在听，慢慢讲", "别急，我一直都在", "有什么心事，可以说给我听",
                "今天也是元气满满的一天呢", "要不要一起想个有趣的点子？", "来，我们聊点有意思的",
                "今天有什么好玩的想分享吗？", "无聊的时候，找我准没错", "有什么难题，我们一起想办法",
                "有我在，别怕", "让我们一起把问题解决掉", "相信自己，你可以的",
                "今天也要加油哦！", "小鲸鱼已就位，等待指令 🐳", "咦？你来了，我正等着呢",
                "悄悄告诉你，我什么都能聊", "别客气，把这里当自己家", "来都来了，聊两句再走呗",
                "夜深了，想聊点心里话吗？", "安静的夜晚，适合慢慢聊", "有什么想说又说不出口的，这里可以说",
                "睡不着的话，我陪你聊聊", "说吧，我在听", "我在呢", "嗯，然后呢？",
                "开始吧", "开始啦", "我喜欢你", "我将竭诚为您解答问题", "想聊什么？"
            ];
            var randomText = welcomeTexts[Math.floor(Math.random() * welcomeTexts.length)];
            wrap.innerHTML =
                '<div class="dsc-msg-empty">' +
                '<img src="/sw.png" class="dsc-big-icon" alt="小鲸鱼">' +
                '<h3>' + randomText + '</h3>' +
                '</div>';
            return;
        }

        dscScheduleMsgsSnap();
        var total = state.messages.length;
        var start = Math.max(0, total - MSG_RENDER_WINDOW);
        state.renderedStart = start;

        var frag = document.createDocumentFragment();

        if (start > 0 || state.hasMore) {
            frag.appendChild(createLoadMoreSentinel());
        }

        for (var i = start; i < total; i++) {
            frag.appendChild(createMsgEl(state.messages[i], i));
        }

        wrap.appendChild(frag);

        if (state.keepScroll) {
            var delta = wrap.scrollHeight - state.pendingScrollHeight;
            wrap.scrollTop = state.pendingScrollTop + delta;
            requestAnimationFrame(function () { renderMath(wrap); });
            state.keepScroll = false;
        } else {
            void wrap.scrollHeight;
            var lastMsg = wrap.lastElementChild;
            if (lastMsg && lastMsg.classList && lastMsg.classList.contains('dsc-msg')) {
                var wr0 = wrap.getBoundingClientRect();
                var lr0 = lastMsg.getBoundingClientRect();
                wrap.scrollTop += (lr0.bottom - wr0.bottom);
            }
            wrap.scrollTop = wrap.scrollHeight;
            scrollToBottom(true);
            requestAnimationFrame(function () {
                renderMath(wrap);
                scrollToBottom(true);
            });
            setTimeout(function () { scrollToBottom(true); }, 120);
            setTimeout(function () { scrollToBottom(true); }, 320);
            setTimeout(function () { scrollToBottom(true); }, 650);
        }

        decorateContinueButton();
    }

    function createLoadMoreSentinel() {
        var sentinel = document.createElement('div');
        sentinel.id = 'dscLoadMoreSentinel';
        sentinel.className = 'dsc-load-more-sentinel';
        sentinel.textContent = state.loadingOlder ? '加载中…' : '↑ 加载更早的消息';
        sentinel.addEventListener('click', loadOlderMessages);
        return sentinel;
    }

    function prependMsgs(fromIdx, toIdx) {
        var wrap = $('dscMessages');
        if (!wrap) return;
        var frag = document.createDocumentFragment();
        for (var i = fromIdx; i < toIdx; i++) {
            frag.appendChild(createMsgEl(state.messages[i], i));
        }
        var sentinel = $('dscLoadMoreSentinel');
        if (sentinel) sentinel.remove();
        var oldScrollHeight = wrap.scrollHeight;
        var oldScrollTop = wrap.scrollTop;
        wrap.insertBefore(frag, wrap.firstChild);
        if (fromIdx > 0 || state.hasMore) {
            wrap.insertBefore(createLoadMoreSentinel(), wrap.firstChild);
        }
        var newScrollHeight = wrap.scrollHeight;
        wrap.scrollTop = oldScrollTop + (newScrollHeight - oldScrollHeight);
        requestAnimationFrame(function () { renderMath(wrap); });
    }

    async function loadOlderMessages() {
        var wrap = $('dscMessages');
        if (!wrap) return;
        if (state.loadingOlder) return;

        var start = state.renderedStart;

        // 1) 内存中还有已加载的更早消息，直接前插渲染
        if (start > 0) {
            var newStart = Math.max(0, start - MSG_LOAD_STEP);
            prependMsgs(newStart, start);
            state.renderedStart = newStart;
            return;
        }

        // 2) 向后端请求更早消息
        if (!state.hasMore || !state.messages.length) return;
        state.loadingOlder = true;
        var s0 = $('dscLoadMoreSentinel');
        if (s0) s0.textContent = '加载中…';
        try {
            var first = state.messages[0];
            var res = await fetch('/api/ds-chat/messages?sessionId=' + encodeURIComponent(state.currentSessionId) +
                '&beforeId=' + encodeURIComponent(first.id) + '&limit=' + MSG_PAGE_SIZE);
            var data = await res.json();
            var older = data.messages || [];
            state.hasMore = !!data.hasMore;
            if (older.length) {
                state.pendingScrollTop = wrap.scrollTop;
                state.pendingScrollHeight = wrap.scrollHeight;
                state.messages = older.concat(state.messages);
                state.keepScroll = true;
                renderMessages();
            }
        } catch (e) {
            toast('加载更早消息失败', 'error');
        } finally {
            state.loadingOlder = false;
            var s1 = $('dscLoadMoreSentinel');
            if (s1) s1.textContent = '↑ 加载更早的消息';
        }
    }

    async function loadFullReasoning(btn) {
        var body = btn.closest('.dsc-think-body');
        var panel = btn.closest('.dsc-think-panel');
        if (!body) return;
        var msgId = btn.getAttribute('data-msg-id');
        var sid = state.currentSessionId;
        if (!msgId || !sid) return;
        btn.textContent = '加载中…';
        btn.disabled = true;
        try {
            var res = await fetch('/api/ds-chat/reasoning?sessionId=' + encodeURIComponent(sid) + '&id=' + encodeURIComponent(msgId));
            var data = await res.json();
            var full = (data && data.reasoning) || '';
            if (full) {
                body.innerHTML = escapeHtml(full);
                if (panel) panel.classList.add('open');
            } else {
                btn.textContent = '（无内容）';
            }
        } catch (err) {
            btn.textContent = '加载失败，点击重试';
            btn.disabled = false;
        }
    }

    function createMsgEl(m, idx) {
        var wrap = document.createElement('div');
        wrap.className = 'dsc-msg ' + (m.role === 'user' ? 'user' : 'assistant');
        if (typeof idx === 'number') wrap.dataset.idx = idx;
        var isUser = m.role === 'user';

        var attachHtml = '';
        if (m.attachments) {
            var ids = m.attachments.split(',').filter(Boolean);
            ids.forEach(function (fid) {
                attachHtml += '<div class="dsc-msg-attach" data-fid="' + fid + '" onclick="window.open(\'/api/ds-files/download?id=' + fid + '\',\'_blank\')">' +
                    '<span class="ic">📎</span><span class="nm">附件</span></div>';
            });
        }

        var thinkHtml = '';
        if (!isUser && m.reasoning && String(m.reasoning).trim()) {
            var loadFullBtn = '';
            if (m.reasoningTruncated) {
                loadFullBtn = '<button class="dsc-think-load-full" type="button" data-msg-id="' + escapeHtml(m.id) + '">展开完整思考链</button>';
            }
            thinkHtml =
                '<div class="dsc-think-panel">' +
                '<div class="dsc-think-header">' +
                '<span class="icon">🧠</span>' +
                '<span class="label">推理过程与工具调用记录</span>' +
                '<span class="arrow">›</span>' +
                '</div>' +
                '<div class="dsc-think-body">' + escapeHtml(m.reasoning) + loadFullBtn + '</div>' +
                '</div>';
        }

        var copyBtnHtml = '';
        if (typeof idx === 'number') {
            copyBtnHtml = '<button class="dsc-msg-copy-btn" data-idx="' + idx + '" title="复制此条消息">📋 复制</button>';
        }
        var speakBtnHtml = '';
        if (!isUser && typeof idx === 'number') {
            speakBtnHtml = '<button class="dsc-msg-speak-btn" data-idx="' + idx + '" title="朗读此条消息">🔊 朗读</button>';
        }

        var usageHtml = (!isUser && m.usage) ? dsUsageBlockHtml(m.usage, m.model || state.currentModel) : '';

        wrap.innerHTML =
            '<div class="dsc-msg-avatar">' + (isUser ? '🧑' : '🤖') + '</div>' +
            '<div class="dsc-msg-content">' +
            thinkHtml +
            '<div class="dsc-msg-bubble">' + renderMarkdown(m.content) + attachHtml + '</div>' +
            usageHtml +
            '<div class="dsc-msg-meta">' +
            '<span class="dsc-msg-time">' + formatTime(m.createdAt) + '</span>' +
            copyBtnHtml + speakBtnHtml +
            '</div>' +
            '</div>';
        return wrap;
    }

    function appendMessageEl(m) {
        var wrap = $('dscMessages');
        if (!wrap) return;
        var empty = wrap.querySelector('.dsc-msg-empty');
        if (empty) empty.remove();
        var idx = state.messages.length;
        var el = createMsgEl(m, idx);
        wrap.appendChild(el);
        scrollToBottom(true);
        requestAnimationFrame(function () { renderMath(el); });
    }

    function showTyping(label) {
        var wrap = $('dscMessages');
        if (!wrap) return;
        var el = document.createElement('div');
        el.className = 'dsc-msg assistant';
        el.id = 'dscTypingIndicator';
        el.innerHTML =
            '<div class="dsc-msg-avatar">🤖</div>' +
            '<div class="dsc-msg-content">' +
            '<div class="dsc-msg-bubble">' +
            '<div style="font-size:0.75rem;color:#9ca3af;margin-bottom:6px;">' + (label || '正在生成...') + '</div>' +
            '<div class="dsc-typing"><span></span><span></span><span></span></div>' +
            '</div>' +
            '</div>';
        wrap.appendChild(el);
        scrollToBottom(true);
    }

    function hideTyping() {
        var el = $('dscTypingIndicator');
        if (el) el.remove();
    }

    function createStreamingMsgEl() {
        var wrap = document.createElement('div');
        wrap.className = 'dsc-msg assistant';
        wrap.id = 'dscStreamingMsg';

        wrap.innerHTML =
            '<div class="dsc-msg-avatar">🤖</div>' +
            '<div class="dsc-msg-content">' +
                '<div class="dsc-think-panel open" id="dscStreamThinkPanel" style="display:none;">' +
                    '<div class="dsc-think-header">' +
                        '<span class="icon">🧠</span>' +
                        '<span class="label" id="dscStreamThinkLabel">正在思考…</span>' +
                        '<span class="arrow">›</span>' +
                    '</div>' +
                    '<div class="dsc-think-body" id="dscStreamThinkBody" style="max-height:300px;overflow-y:auto;"></div>' +
                '</div>' +
                '<div class="dsc-msg-bubble" id="dscStreamBubble"></div>' +
                '<div class="dsc-msg-usage" id="dscStreamUsage" style="display:none;"></div>' +
                '<div class="dsc-msg-meta">' +
                    '<span class="dsc-msg-time"></span>' +
                '</div>' +
            '</div>';

        var wrapMsg = $('dscMessages');
        if (wrapMsg) {
            var empty = wrapMsg.querySelector('.dsc-msg-empty');
            if (empty) empty.remove();
            wrapMsg.appendChild(wrap);
        }
        return wrap;
    }

    // ============================================================
    // ★ 加速版打字机：首字快速出现 + 大步长
    // ============================================================
    function startTyper() {
        var t = state.typer;
        if (t.rafId) return;

        function tick(ts) {
            t.rafId = null;
            var needRender = false;

            if (t.contentShown.length < t.contentBuf.length) {
                var remain = t.contentBuf.length - t.contentShown.length;
                // ★ 加速：步长从 2~120 提升到 8~400
                var step = Math.max(8, Math.min(400, Math.ceil(remain / 3)));
                t.contentShown = t.contentBuf.slice(0, t.contentShown.length + step);
                needRender = true;
            }
            if (t.reasoningShown.length < t.reasoningBuf.length) {
                var remainR = t.reasoningBuf.length - t.reasoningShown.length;
                // ★ 加速：思考链步长从 4~300 提升到 15~800
                var stepR = Math.max(15, Math.min(800, Math.ceil(remainR / 2)));
                t.reasoningShown = t.reasoningBuf.slice(0, t.reasoningShown.length + stepR);
                needRender = true;
            }

            // ★ 渲染频率：70ms → 45ms
            if (needRender && (!t.lastRenderTs || ts - t.lastRenderTs > 45)) {
                t.lastRenderTs = ts;
                if (t.bubbleEl) t.bubbleEl.innerHTML = renderMarkdown(t.contentShown);
                if (t.thinkBodyEl) {
                    t.thinkBodyEl.textContent = t.reasoningShown;
                    if (t.thinkPanelEl && t.thinkPanelEl.classList.contains('open')) {
                        t.thinkBodyEl.scrollTop = t.thinkBodyEl.scrollHeight;
                    }
                }
                // ★ 滚动频率：120ms → 80ms
                if (!t.lastScrollTs || ts - t.lastScrollTs > 80) {
                    t.lastScrollTs = ts;
                    var wrap = $('dscMessages');
                    if (wrap && isNearBottom(wrap, NEAR_BOTTOM_THRESHOLD)) {
                        wrap.scrollTop = wrap.scrollHeight;
                    }
                }
            }

            var stillWriting =
                t.contentShown.length < t.contentBuf.length ||
                t.reasoningShown.length < t.reasoningBuf.length;

            if (stillWriting || !t.done) {
                t.rafId = requestAnimationFrame(tick);
            } else {
                if (t.bubbleEl) t.bubbleEl.innerHTML = renderMarkdown(t.contentBuf);
                if (t.thinkBodyEl) t.thinkBodyEl.textContent = t.reasoningBuf;
                if (t.msgEl) requestAnimationFrame(function () { renderMath(t.msgEl); });
            }
        }
        t.rafId = requestAnimationFrame(tick);
    }

    // ============================================================
    // ★ 工具可视化辅助
    // ============================================================
    var TOOL_ICONS = {
        // 弹窗类
        'dismiss_popup': '🚫',
        'auto_dismiss_dialogs': '🧹',
        'is_popup_present': '🔍',
        'wait_for_element': '⏳',
        // Shizuku
        'shizuku_status': '🔷',
        'shizuku_start': '🔷',
        'shizuku_exec': '⚡',
        'shizuku_install_rish': '🔷',
        // 应用控制
        'start_app': '🚀',
        'current_app': '📱',
        'is_app_running': '📱',
        'force_stop_app': '⛔',
        // 文件
        'append_file': '📝',
        'create_file': '📄',
        'read_file': '📖',
        'get_file_size': '📊',
        'list_dir': '📁',
        'download_file': '⬇️',
        // 命令
        'execute_command': '💻',
        'run_background': '🔧',
        'list_processes': '📋',
        'kill_process': '🔪',
        'wait_seconds': '⏱️',
        'http_request': '🌐',
        // UI
        'tap': '👆',
        'long_press': '👇',
        'swipe': '👉',
        'input_text': '⌨️',
        'key_event': '⌨️',
        'find_element': '🔍',
        'screenshot': '📸',
        'ui_dump': '📋',
    };

    function toolIcon(name) {
        return TOOL_ICONS[name] || '🔧';
    }

    // ============================================================
    // 通用 SSE 流式请求
    // ============================================================
    async function sendMessageStream(payload, aiMsgEl, opts) {
        opts = opts || {};
        var onEvent = opts.onEvent || null;

        var t = state.typer;
        t.contentBuf = '';
        t.contentShown = '';
        t.reasoningBuf = '';
        t.reasoningShown = '';
        t.done = false;
        t.lastRenderTs = 0;
        t.lastScrollTs = 0;

        var ctrl = new AbortController();
        state.abortCtrl = ctrl;

        var response;
        try {
            response = await fetch('/api/ds-chat/send', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload),
                signal: ctrl.signal,
            });
        } catch (eFetch) {
            if (isStopAbort(eFetch) || state.stopRequested) throw makeStopError();
            throw eFetch;
        }

        if (!response.ok || !response.body) {
            var data0 = await response.json().catch(function () { return {}; });
            throw new Error(data0.error || ('HTTP ' + response.status));
        }

        var ct = response.headers.get('content-type') || '';
        if (ct.indexOf('text/event-stream') === -1) {
            var dataJ = await response.json().catch(function () { return {}; });
            if (dataJ.error) throw new Error(dataJ.error);
            return dataJ;
        }

        var reader = response.body.getReader();
        var decoder = new TextDecoder('utf-8');
        var buffer = '';
        var currentEvent = '';
        var donePayload = null;

        var thinkPanel = aiMsgEl ? aiMsgEl.querySelector('#dscStreamThinkPanel') : null;
        var thinkBody = aiMsgEl ? aiMsgEl.querySelector('#dscStreamThinkBody') : null;
        var thinkLabel = aiMsgEl ? aiMsgEl.querySelector('#dscStreamThinkLabel') : null;
        t.bubbleEl = aiMsgEl ? aiMsgEl.querySelector('#dscStreamBubble') : null;
        t.thinkBodyEl = thinkBody;
        t.thinkPanelEl = thinkPanel;
        t.thinkLabelEl = thinkLabel;
        t.msgEl = aiMsgEl;

        hideTyping();
        if (aiMsgEl) startTyper();

        // 工具轮次计数
        var toolRound = 0;
        var toolModeActive = false;

        while (true) {
            if (state.stopRequested) throw makeStopError();
            var r;
            try {
                r = await reader.read();
            } catch (eRead) {
                if (isStopAbort(eRead) || state.stopRequested) throw makeStopError();
                throw eRead;
            }
            if (r.done) break;
            if (state.stopRequested) throw makeStopError();
            buffer += decoder.decode(r.value, { stream: true });

            var lines = buffer.split('\n');
            buffer = lines.pop();

            for (var i = 0; i < lines.length; i++) {
                var line = lines[i];
                if (line.startsWith('event: ')) {
                    currentEvent = line.slice(7).trim();
                } else if (line.startsWith('data: ')) {
                    var raw = line.slice(6);
                    if (!raw) continue;
                    var obj;
                    try { obj = JSON.parse(raw); } catch (e) { continue; }

                    if (onEvent) {
                        try { onEvent(currentEvent, obj); } catch (e) {}
                    }

                    // ★ 桌宠状态感知（dsh-pet 移植：把 SSE 阶段映射到宠物动画）
                    if (typeof window.DscPetSetPhase === 'function') {
                        if (currentEvent === 'reasoning') window.DscPetSetPhase('thinking');
                        else if (currentEvent === 'tool_mode_start' || currentEvent === 'tool_call') window.DscPetSetPhase('tool');
                        else if (currentEvent === 'content') window.DscPetSetPhase('review');
                        else if (currentEvent === 'done') window.DscPetSetPhase('done');
                        else if (currentEvent === 'error') window.DscPetSetPhase('failed');
                    }

                    if (currentEvent === 'reasoning') {
                        t.reasoningBuf += obj.delta || '';
                        if (thinkPanel && thinkPanel.style.display === 'none') {
                            thinkPanel.style.display = '';
                        }

                    } else if (currentEvent === 'content') {
                        t.contentBuf += obj.delta || '';

                    } else if (currentEvent === 'new_round') {
                        t.contentBuf = '';
                        t.contentShown = '';
                        if (t.bubbleEl) t.bubbleEl.innerHTML = '';

                    } else if (currentEvent === 'round') {
                        if (thinkLabel && obj.stage) {
                            thinkLabel.textContent = '🧠 ' + obj.stage;
                        }

                    } else if (currentEvent === 'tool_mode_start') {
                        toolModeActive = true;
                        if (thinkPanel && thinkPanel.style.display === 'none') {
                            thinkPanel.style.display = '';
                        }
                        if (thinkLabel) {
                            thinkLabel.textContent = '🤖 自主智能体已激活（最多 50 亿轮）';
                        }

                    } else if (currentEvent === 'tool_call') {
                        if (thinkPanel && thinkPanel.style.display === 'none') {
                            thinkPanel.style.display = '';
                        }
                        var phase = obj.phase || '';
                        var name = obj.name || '';
                        var args = obj.args || '';
                        var result = obj.result || '';
                        var icon = toolIcon(name);

                        if (phase === 'start') {
                            toolRound++;
                            if (thinkLabel) {
                                thinkLabel.textContent = '🤖 第 ' + toolRound + ' 轮 · ' + icon + ' ' + name;
                            }
                            var argsPreview = args.length > 300 ? args.slice(0, 300) + '…' : args;
                            t.reasoningBuf += '\n' + icon + ' [' + toolRound + '] ' + name + '\n';
                            if (argsPreview) {
                                t.reasoningBuf += '   ▸ ' + argsPreview + '\n';
                            }
                        } else if (phase === 'end') {
                            t.reasoningBuf += '   ✓ 完成\n';
                            if (result) {
                                var resultPreview = result.length > 400 ? result.slice(0, 400) + '…' : result;
                                t.reasoningBuf += '   ' + resultPreview.replace(/\n/g, '\n   ') + '\n';
                            }
                        }

                    } else if (currentEvent === 'error') {
                        throw new Error(obj.message || '流式错误');

                    } else if (currentEvent === 'done') {
                        donePayload = obj;
                    }
                }
            }
        }

        t.done = true;
        await new Promise(function (resolve) {
            function wait() {
                if (t.contentShown.length >= t.contentBuf.length &&
                    t.reasoningShown.length >= t.reasoningBuf.length) {
                    resolve();
                } else {
                    setTimeout(wait, 30);
                }
            }
            wait();
        });

        if (thinkPanel && t.reasoningBuf.trim() !== '') {
            if (thinkLabel) {
                if (toolModeActive) {
                    thinkLabel.textContent = '🤖 思考链与工具调用记录（共 ' + toolRound + ' 轮）';
                } else {
                    thinkLabel.textContent = '推理过程与工具调用记录';
                }
            }
            // ★ 工具模式：结束后思考链保持展开可见；普通模式折叠
            if (!toolModeActive) {
                thinkPanel.classList.remove('open');
            }
        }

        return donePayload;
    }

    function finalizeStreamingMsg(aiMsgEl, aiMessage, idx, thinkingTimeMs) {
        if (!aiMsgEl || !aiMessage) return;
        aiMsgEl.removeAttribute('id');

        var bubble = aiMsgEl.querySelector('.dsc-msg-bubble');
        if (bubble) {
            bubble.removeAttribute('id');
            bubble.innerHTML = renderMarkdown(aiMessage.content || '');
        }

        var thinkPanel = aiMsgEl.querySelector('.dsc-think-panel');
        var thinkBody = aiMsgEl.querySelector('.dsc-think-body');
        if (thinkPanel && thinkBody) {
            thinkPanel.removeAttribute('id');
            thinkBody.removeAttribute('id');
            thinkBody.style.maxHeight = '';
            thinkBody.style.overflowY = '';
            var finalReasoning = (aiMessage.reasoning && aiMessage.reasoning.trim())
                ? aiMessage.reasoning
                : (state.typer.reasoningBuf && state.typer.reasoningBuf.trim() ? state.typer.reasoningBuf : '');
            if (finalReasoning) {
                thinkBody.textContent = finalReasoning;
                aiMessage.reasoning = finalReasoning;
            } else {
                thinkPanel.remove();
            }
        }

        // ★ 把后端返回的真实 usage 渲染到气泡下方（距消息 0.2em）
        var usageBox = aiMsgEl.querySelector('.dsc-msg-usage');
        if (usageBox) {
            var usageChip = dsUsageChipHtml(aiMessage.usage);
            if (usageChip) {
                usageBox.innerHTML = usageChip + dscCostChipHtml(aiMessage.usage, aiMessage.model || state.currentModel);
                usageBox.style.display = '';
            } else {
                usageBox.remove();
            }
        }

        var meta = aiMsgEl.querySelector('.dsc-msg-meta');
        if (meta && typeof idx === 'number' && idx >= 0) {
            var thinkTimeHtml = '';
            if (thinkingTimeMs != null && thinkingTimeMs >= 0) {
                thinkTimeHtml = '<span class="dsc-think-time" title="模型思考(reasoning)总耗时（多轮反思为全部轮次累加，工具模式为首次正文前耗时）">⏱ 思考 ' + (thinkingTimeMs / 1000).toFixed(1) + 's</span>';
            }
            meta.innerHTML =
                '<span class="dsc-msg-time">' + formatTime(aiMessage.createdAt) + '</span>' +
                thinkTimeHtml +
                '<button class="dsc-msg-copy-btn" data-idx="' + idx + '" title="复制此条消息">📋 复制</button>' +
                '<button class="dsc-msg-speak-btn" data-idx="' + idx + '" title="朗读此条消息">🔊 朗读</button>';
        }

        aiMsgEl.dataset.idx = String(idx);
        requestAnimationFrame(function () { renderMath(aiMsgEl); });
    }

    // ============================================================
    // ★ 终止生成 / 继续生成（DeepSeek 官方交互：圆形按钮 + 方块）
    //   1) 生成期间发送按钮不禁用，改为"停止"形态（圆形内一个方块）
    //   2) 再次点击该按钮 = 立即终止本轮生成，且不再继续接收后续内容
    //   3) 终止后把已生成的部分落库（后端流被中断时不会自己保存）
    //   4) 最新一条回答下方提供"继续生成"，原地续写同一条消息
    // ============================================================
    var SEND_ICON_ARROW = '<svg class="dsc-send-icon" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">' +
        '<path d="M12 19V5M12 5L5 12M12 5L19 12" stroke="#ffffff" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></svg>';
    var SEND_ICON_STOP = '<svg class="dsc-send-icon" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">' +
        '<rect x="7.2" y="7.2" width="9.6" height="9.6" rx="2.2" fill="#ffffff"/></svg>';

    function makeStopError() {
        var err = new Error('STOPPED');
        err.name = 'StopAbort';
        return err;
    }

    function isStopAbort(e) {
        if (!e) return false;
        if (e.name === 'StopAbort' || e.name === 'AbortError') return true;
        return e.message === 'STOPPED';
    }

    // 切换发送按钮形态：idle=向上箭头发送；sending=圆形内方块（停止）
    function setSendBtnMode(mode) {
        var btn = $('dscSendBtn');
        if (!btn) return;
        var stopping = (mode === 'sending');
        btn.innerHTML = stopping ? SEND_ICON_STOP : SEND_ICON_ARROW;
        if (stopping) btn.classList.add('is-stopping');
        else btn.classList.remove('is-stopping');
        btn.setAttribute('title', stopping ? '停止生成' : '发送');
        btn.setAttribute('aria-label', stopping ? '停止生成' : '发送');
        // ★ 关键：生成中不能 disabled，否则再次点击无法触发终止
        btn.disabled = false;
    }

    // 请求终止：立刻中断取流，并锁死后续事件处理
    function requestStop() {
        if (!state.isSending) return;
        if (state.stopRequested) return;
        state.stopRequested = true;
        if (state.abortCtrl) {
            try { state.abortCtrl.abort(); } catch (e) {}
        }
        if (typeof window.DscPetSetPhase === 'function') window.DscPetSetPhase('idle');
        var btn = $('dscSendBtn');
        if (btn) btn.setAttribute('title', '正在停止…');
        hideTyping();
    }

    // 发送按钮唯一入口：生成中=终止，空闲=发送
    function onSendBtnClick() {
        if (state.isSending) { requestStop(); return; }
        sendMessage();
    }

    // 把被中断的这一轮落库（user + 已生成的部分内容），或更新某条已续写的消息
    async function saveStoppedTurn(ctx) {
        // ★ 必须新建 AbortController，绝不能复用已 abort 的 signal
        var ctrl = new AbortController();
        try {
            var res = await fetch('/api/ds-chat/abort-save', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    sessionId: ctx.sessionId || '',
                    content: ctx.content || '',
                    fileIds: ctx.fileIds || [],
                    aiContent: ctx.aiContent || '',
                    reasoning: ctx.reasoning || '',
                    messageId: ctx.messageId || ''
                }),
                signal: ctrl.signal
            });
            if (!res.ok) return null;
            return await res.json();
        } catch (e) {
            return null;
        }
    }

    // 终止后的收尾：保住已生成内容 + 落库 + 渲染"继续生成"
    async function finalizeStoppedStream(aiMsgEl, ctx) {
        var t = state.typer;
        t.done = true;
        t.contentShown = t.contentBuf || t.contentShown;
        t.reasoningShown = t.reasoningBuf || t.reasoningShown;
        if (t.rafId) { try { cancelAnimationFrame(t.rafId); } catch (e) {} t.rafId = null; }
        hideTyping();

        var partial = t.contentBuf || '';
        var partialReasoning = t.reasoningBuf || '';

        // 清掉本轮遗留的临时消息（临时 id 从未入库，避免下一轮重复）
        for (var k = state.messages.length - 1; k >= 0; k--) {
            var tm = state.messages[k];
            if (tm && tm.id && String(tm.id).indexOf('tmp_') === 0) state.messages.splice(k, 1);
        }

        var saved = await saveStoppedTurn({
            sessionId: ctx.sessionId || state.currentSessionId,
            content: ctx.content || '',
            fileIds: ctx.fileIds || [],
            aiContent: partial,
            reasoning: partialReasoning,
            messageId: ctx.messageId || ''
        });

        if (saved && saved.userMessage) {
            var uIdx = state.messages.findIndex(function (m) { return m.id === saved.userMessage.id; });
            if (uIdx === -1) state.messages.push(saved.userMessage);
            else state.messages[uIdx] = saved.userMessage;
        }
        if (saved && saved.aiMessage) {
            var aiMessage = saved.aiMessage;
            var aIdx = state.messages.findIndex(function (m) { return m.id === aiMessage.id; });
            if (aIdx === -1) state.messages.push(aiMessage);
            else state.messages[aIdx] = aiMessage;
            toast('已停止生成，已保留 ' + (partial ? String(partial.length) : '0') + ' 字', 'info');
        } else if (partial.trim() !== '') {
            // 落库失败：保住界面内容，但如实说明未写入历史
            state.messages.push({
                id: 'local_stop_' + Date.now(),
                sessionId: ctx.sessionId || state.currentSessionId,
                role: 'assistant',
                content: partial,
                createdAt: new Date().toISOString(),
                reasoning: partialReasoning
            });
            toast('已停止生成（本地保留，未写入历史）', 'info');
        } else {
            toast('已停止生成', 'info');
        }

        // 统一重渲染：保证 state.messages 与 DOM 的 data-idx 一致（复制/朗读不会指错）
        if (aiMsgEl && aiMsgEl.parentNode) aiMsgEl.remove();
        renderMessages();
        decorateContinueButton();
    }

    // 只在"最新一条回答"下方挂"继续生成"按钮（与 DeepSeek 一致）
    function decorateContinueButton() {
        var wrap = $('dscMessages');
        if (!wrap) return;
        var olds = wrap.querySelectorAll('.dsc-msg-continue-btn');
        for (var i = 0; i < olds.length; i++) {
            if (olds[i].parentNode) olds[i].parentNode.removeChild(olds[i]);
        }
        var lastAi = -1;
        for (var j = state.messages.length - 1; j >= 0; j--) {
            var mm = state.messages[j];
            if (!mm || !mm.id) continue;
            if (String(mm.id).indexOf('tmp_') === 0) continue;
            if (mm.role === 'user') return;          // 最后一条是用户消息，无需续写
            if (mm.role === 'assistant') { lastAi = j; break; }
        }
        if (lastAi < 0) return;
        var el = wrap.querySelector('.dsc-msg.assistant[data-idx="' + lastAi + '"]');
        if (!el) return;
        var meta = el.querySelector('.dsc-msg-meta');
        if (!meta) return;
        var btn = document.createElement('button');
        btn.className = 'dsc-msg-continue-btn';
        btn.setAttribute('data-idx', String(lastAi));
        btn.setAttribute('title', '继续生成');
        btn.textContent = '▶ 继续生成';
        meta.appendChild(btn);
    }

    // 继续生成：原地把同一条回答接下去写
    async function continueGeneration(idx) {
        if (state.isSending) { toast('正在生成中，请稍候', 'info'); return; }
        var m = state.messages[idx];
        if (!m || m.role !== 'assistant') return;

        state.isSending = true;
        state.stopRequested = false;
        setSendBtnMode('sending');

        var wrapEl = $('dscMessages');
        var msgEl = wrapEl ? wrapEl.querySelector('.dsc-msg.assistant[data-idx="' + idx + '"]') : null;
        var bubble = msgEl ? msgEl.querySelector('.dsc-msg-bubble') : null;
        var baseContent = m.content || '';
        var addBuf = '';
        var reasoningAdd = '';
        var lastRender = 0;
        var ctrl = new AbortController();
        state.abortCtrl = ctrl;
        if (typeof window.DscPetSetPhase === 'function') window.DscPetSetPhase('review', '正在继续生成…');

        try {
            var res = await fetch('/api/ds-chat/continue', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    sessionId: state.currentSessionId,
                    messageId: m.id,
                    baseContent: baseContent,
                    model: state.currentModel,
                    deepThink: state.deepThink,
                    reasoningLevel: state.reasoningLevel
                }),
                signal: ctrl.signal
            });

            if (!res.ok || !res.body) {
                var e0 = await res.json().catch(function () { return {}; });
                throw new Error(e0.error || ('HTTP ' + res.status));
            }

            var ct2 = res.headers.get('content-type') || '';
            if (ct2.indexOf('text/event-stream') === -1) {
                var dj = await res.json().catch(function () { return {}; });
                if (dj && dj.aiMessage) {
                    m.content = dj.aiMessage.content || m.content;
                    m.reasoning = dj.aiMessage.reasoning || m.reasoning;
                }
                renderMessages();
                decorateContinueButton();
                return;
            }

            var reader = res.body.getReader();
            var decoder = new TextDecoder('utf-8');
            var buf = '';
            var ev = '';
            var doneObj = null;

            while (true) {
                if (state.stopRequested) throw makeStopError();
                var r;
                try {
                    r = await reader.read();
                } catch (eRead) {
                    if (isStopAbort(eRead) || state.stopRequested) throw makeStopError();
                    throw eRead;
                }
                if (r.done) break;
                if (state.stopRequested) throw makeStopError();
                buf += decoder.decode(r.value, { stream: true });

                var lines = buf.split('\n');
                buf = lines.pop();
                for (var i = 0; i < lines.length; i++) {
                    var line = lines[i];
                    if (line.indexOf('event: ') === 0) {
                        ev = line.slice(7).trim();
                    } else if (line.indexOf('data: ') === 0) {
                        var raw = line.slice(6);
                        if (!raw) continue;
                        var obj;
                        try { obj = JSON.parse(raw); } catch (e2) { continue; }
                        if (ev === 'content') {
                            addBuf += obj.delta || '';
                            var nowTs = Date.now();
                            if (bubble && nowTs - lastRender > 60) {
                                lastRender = nowTs;
                                bubble.innerHTML = renderMarkdown(baseContent + addBuf);
                                var wrapS = $('dscMessages');
                                if (wrapS && isNearBottom(wrapS, NEAR_BOTTOM_THRESHOLD)) wrapS.scrollTop = wrapS.scrollHeight;
                            }
                        } else if (ev === 'reasoning') {
                            reasoningAdd += obj.delta || '';
                        } else if (ev === 'error') {
                            throw new Error(obj.message || '续写失败');
                        } else if (ev === 'done') {
                            doneObj = obj;
                        }
                    }
                }
            }

            if (bubble) bubble.innerHTML = renderMarkdown(baseContent + addBuf);

            if (doneObj && doneObj.aiMessage) {
                m.content = doneObj.aiMessage.content || (baseContent + addBuf);
                m.reasoning = doneObj.aiMessage.reasoning || (m.reasoning || '');
                if (doneObj.aiMessage.usage) m.usage = doneObj.aiMessage.usage;
            } else {
                m.content = baseContent + addBuf;
            }
            renderMessages();
            decorateContinueButton();
            toast('✅ 已继续生成 ' + addBuf.length + ' 字', 'success');

        } catch (err) {
            if (state.stopRequested || isStopAbort(err)) {
                var merged = baseContent + addBuf;
                var rs = await saveStoppedTurn({
                    sessionId: state.currentSessionId,
                    content: '',
                    fileIds: [],
                    aiContent: merged,
                    reasoning: (m.reasoning || '') + reasoningAdd,
                    messageId: m.id
                });
                m.content = (rs && rs.aiMessage && rs.aiMessage.content) ? rs.aiMessage.content : merged;
                renderMessages();
                decorateContinueButton();
                toast('已停止生成', 'info');
            } else {
                toast('继续生成失败：' + err.message, 'error');
                renderMessages();
                decorateContinueButton();
            }
        } finally {
            if (state.abortCtrl === ctrl) state.abortCtrl = null;
            state.isSending = false;
            state.stopRequested = false;
            setSendBtnMode('idle');
            if (typeof window.DscPetSetPhase === 'function') window.DscPetSetPhase('idle');
        }
    }

    async function sendMessage() {
        if (state.isSending) { requestStop(); return; }
        var inputEl = $('dscInput');
        var sendBtn = $('dscSendBtn');
        if (!inputEl) return;
        var content = inputEl.value.trim();
        var fileIds = (typeof window.dsGetAttachedFileIds === 'function') ? window.dsGetAttachedFileIds() : [];
        if (!content && fileIds.length === 0) { toast('请输入消息或附加文件', 'info'); return; }

        if (!state.currentSessionId) {
            try {
                var res0 = await fetch('/api/ds-chat/sessions', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ title: '新对话' })
                });
                var data0 = await res0.json();
                state.sessions.unshift(data0.session);
                state.currentSessionId = data0.session.id;
                renderSessions();
                updateTitle();
            } catch (e) { toast('创建会话失败', 'error'); return; }
        }

        state.isSending = true;
        state.stopRequested = false;
        setSendBtnMode('sending');
        if (typeof window.DscPetSetPhase === 'function') window.DscPetSetPhase('waiting', '正在思考…');
        var originalInput = inputEl.value;
        inputEl.value = '';
        autoResize();
        closePlusMenu();

        var nowIso = new Date().toISOString();
        var userMsg = {
            id: 'tmp_u_' + Date.now(),
            sessionId: state.currentSessionId,
            role: 'user',
            content: content || '[已上传文件]',
            createdAt: nowIso,
            attachments: fileIds.join(',')
        };
        appendMessageEl(userMsg);

        var effectiveLevel = state.reasoningLevel;
        if (!state.advancedMode) {
            effectiveLevel = state.deepThink ? (DEFAULT_LEVEL + 5) : DEFAULT_LEVEL;
        }

        var tipMsg = '正在通过 ' + state.currentModel + ' 思考...';
        if (state.enableTools) tipMsg = '🤖 自主智能体已激活...';
        showTyping(tipMsg);

        var aiMsgElRef = null;

        try {
            var canStream = !state.longTextMode;

            if (canStream) {
                var aiMsgEl = createStreamingMsgEl();
                aiMsgElRef = aiMsgEl;
                var dataStream;
                try {
                    dataStream = await sendMessageStream({
                        sessionId: state.currentSessionId,
                        content: content,
                        model: state.currentModel,
                        fileIds: fileIds,
                        webSearch: state.webSearch,
                        deepThink: state.deepThink,
                        reasoningLevel: effectiveLevel,
                        longTextMode: false,
                        targetChars: state.longTextTargetChars,
                        enableTools: state.enableTools,
                        stream: true,
                        injectedPrompts: (typeof window.__dsDevToolsGetInjectedContents === 'function')
                            ? window.__dsDevToolsGetInjectedContents()
                            : []
                    }, aiMsgEl);
                } catch (errStream) {
                    // ★ 主动停止时保留元素，交给 finalizeStoppedStream 固化内容
                    if (state.stopRequested || isStopAbort(errStream)) throw errStream;
                    if (aiMsgEl && aiMsgEl.parentNode) aiMsgEl.remove();
                    throw errStream;
                }

                var idxTmp = state.messages.findIndex(function (m) { return m.id === userMsg.id; });
                if (idxTmp !== -1) state.messages.splice(idxTmp, 1);

                if (dataStream && dataStream.userMessage) state.messages.push(dataStream.userMessage);

                var newIdx = -1;
                if (dataStream && dataStream.aiMessage) {
                    state.messages.push(dataStream.aiMessage);
                    newIdx = state.messages.length - 1;
                }

                if (aiMsgEl && dataStream && dataStream.aiMessage) {
                    finalizeStreamingMsg(aiMsgEl, dataStream.aiMessage, newIdx,
                        dataStream && dataStream.thinkingTimeMs != null ? dataStream.thinkingTimeMs : null);
                } else if (aiMsgEl && aiMsgEl.parentNode) {
                    aiMsgEl.remove();
                }

                var sessS = state.sessions.find(function (s) { return s.id === state.currentSessionId; });
                if (sessS && dataStream && dataStream.title) {
                    sessS.title = dataStream.title;
                    sessS.updatedAt = new Date().toISOString();
                    renderSessions();
                    updateTitle();
                    dscSaveSessionsSnap();
                }

                if (typeof window.dsClearAttach === 'function') window.dsClearAttach();
                decorateContinueButton();
                if (typeof window.dscModelRouteToast === 'function') window.dscModelRouteToast(dataStream);
                toast('✅ 已生成 ' + ((dataStream && dataStream.charCount) || 0).toLocaleString() + ' 字（' + ((dataStream && dataStream.model) || state.currentModel) + '）', 'success');
            } else {
                var response = await fetch('/api/ds-chat/send', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        sessionId: state.currentSessionId,
                        content: content,
                        model: state.currentModel,
                        fileIds: fileIds,
                        webSearch: state.webSearch,
                        deepThink: state.deepThink,
                        reasoningLevel: effectiveLevel,
                        longTextMode: state.longTextMode,
                        targetChars: state.longTextTargetChars,
                        enableTools: state.enableTools,
                        stream: false,
                        injectedPrompts: (typeof window.__dsDevToolsGetInjectedContents === 'function')
                            ? window.__dsDevToolsGetInjectedContents() : []
                    })
                });
                var data = await response.json();
                if (!response.ok) throw new Error(data.error || 'API 调用失败');
                hideTyping();
                var idx = state.messages.findIndex(function (m) { return m.id === userMsg.id; });
                if (idx !== -1) state.messages.splice(idx, 1);
                if (data.userMessage) state.messages.push(data.userMessage);
                if (data.aiMessage) state.messages.push(data.aiMessage);
                renderMessages();
                var sess = state.sessions.find(function (s) { return s.id === state.currentSessionId; });
                if (sess && data.title) {
                    sess.title = data.title;
                    sess.updatedAt = new Date().toISOString();
                    renderSessions();
                    updateTitle();
                    dscSaveSessionsSnap();
                }
                if (typeof window.dsClearAttach === 'function') window.dsClearAttach();
                if (typeof window.dscModelRouteToast === 'function') window.dscModelRouteToast(data);
                toast('✅ 已生成 ' + (data.charCount || 0).toLocaleString() + ' 字', 'success');
            }
        } catch (e) {
            if (state.stopRequested || isStopAbort(e)) {
                // ★ 用户主动终止：不是错误，不弹错误提示、不丢弃已生成内容
                await finalizeStoppedStream(aiMsgElRef, {
                    sessionId: state.currentSessionId,
                    content: content,
                    fileIds: fileIds,
                    messageId: ''
                });
            } else {
                hideTyping();
                if (typeof window.DscPetSetPhase === 'function') window.DscPetSetPhase('failed');
                showCenterError('API调用失败，请检查账户余额');
                var idx2 = state.messages.findIndex(function (m) { return m.id === userMsg.id; });
                if (idx2 !== -1) state.messages.splice(idx2, 1);
                renderMessages();
                inputEl.value = originalInput;
                autoResize();
            }
        } finally {
            state.isSending = false;
            state.stopRequested = false;
            state.abortCtrl = null;
            setSendBtnMode('idle');
            if (typeof window.DscPetSetPhase === 'function') window.DscPetSetPhase('idle');
        }
    }

    // ============================================================
    // 小说模式：流式
    // ============================================================
    async function startNovelGeneration() {
        if (state.isSending) { toast('正在生成中，请稍候', 'info'); return; }

        var theme = $('dscNovelTheme') ? $('dscNovelTheme').value.trim() : '';
        var tags = $('dscNovelTags') ? $('dscNovelTags').value.trim() : '';
        var story = $('dscNovelStory') ? $('dscNovelStory').value.trim() : '';
        var chars = parseInt($('dscNovelChars') ? $('dscNovelChars').value : '30000', 10) || NOVEL_DEFAULT_CHARS;
        if (chars < 5000) chars = 5000;
        if (chars > NOVEL_MAX_CHARS) chars = NOVEL_MAX_CHARS;

        var genre = '都市';
        var genreLabelEl = $('dscNovelGenreLabel');
        if (genreLabelEl && genreLabelEl.textContent.trim()) genre = genreLabelEl.textContent.trim();

        if (!theme && !story) { toast('请至少填写主题或故事设定', 'info'); return; }

        var overlay = $('dscNovelOverlay');
        if (overlay) overlay.classList.remove('open');

        if (!state.currentSessionId) {
            try {
                var res0 = await fetch('/api/ds-chat/sessions', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ title: '小说创作' })
                });
                var data0 = await res0.json();
                state.sessions.unshift(data0.session);
                state.currentSessionId = data0.session.id;
                renderSessions();
                updateTitle();
            } catch (e) { toast('创建会话失败', 'error'); return; }
        }

        state.isSending = true;
        state.stopRequested = false;
        setSendBtnMode('sending');

        var nowIso = new Date().toISOString();
        var content = '📖 小说创作\n分类：' + genre + '\n主题：' + (theme || '自由发挥') + '\n标签：' + (tags || '无') + '\n目标字数：' + chars;
        var userMsg = {
            id: 'tmp_novel_' + Date.now(),
            sessionId: state.currentSessionId,
            role: 'user',
            content: content,
            createdAt: nowIso
        };
        appendMessageEl(userMsg);

        hideTyping();
        var aiMsgEl = createStreamingMsgEl();
        var thinkPanel = aiMsgEl.querySelector('#dscStreamThinkPanel');
        if (thinkPanel) thinkPanel.style.display = 'none';

        var tipEl = document.createElement('div');
        tipEl.style.cssText = 'font-size:0.75rem;color:#9ca3af;margin-bottom:6px;';
        tipEl.textContent = '📖 正在创作小说，预计需要几分钟...';
        var bubble = aiMsgEl.querySelector('#dscStreamBubble');
        if (bubble && bubble.parentNode) bubble.parentNode.insertBefore(tipEl, bubble);

        try {
            var dataStream = await sendMessageStream({
                sessionId: state.currentSessionId,
                content: content,
                model: state.currentModel,
                novelMode: true,
                novelTheme: theme,
                novelTags: tags,
                novelGenre: genre,
                novelStory: story,
                novelChars: chars,
                stream: true
            }, aiMsgEl, {
                onEvent: function (ev, obj) {
                    if (ev === 'novel_progress') {
                        tipEl.textContent = '📖 已创作 ' + obj.done.toLocaleString() + ' / ' + obj.target.toLocaleString() + ' 字';
                    } else if (ev === 'novel_segment') {
                        tipEl.textContent = '📖 正在创作第 ' + obj.index + ' 段...';
                    }
                }
            });

            if (tipEl && tipEl.parentNode) tipEl.remove();

            var idxTmp = state.messages.findIndex(function (m) { return m.id === userMsg.id; });
            if (idxTmp !== -1) state.messages.splice(idxTmp, 1);
            if (dataStream && dataStream.userMessage) state.messages.push(dataStream.userMessage);

            var newIdx = -1;
            if (dataStream && dataStream.aiMessage) {
                state.messages.push(dataStream.aiMessage);
                newIdx = state.messages.length - 1;
            }

            if (aiMsgEl && dataStream && dataStream.aiMessage) {
                finalizeStreamingMsg(aiMsgEl, dataStream.aiMessage, newIdx, null);
            }

            var sess = state.sessions.find(function (s) { return s.id === state.currentSessionId; });
            if (sess && dataStream && dataStream.title) {
                sess.title = dataStream.title;
                sess.updatedAt = new Date().toISOString();
                renderSessions();
                updateTitle();
            }
            toast('✅ 小说已生成 ' + ((dataStream && dataStream.charCount) || 0).toLocaleString() + ' 字', 'success');
        } catch (e) {
            if (tipEl && tipEl.parentNode) tipEl.remove();
            if (state.stopRequested || isStopAbort(e)) {
                toast('已停止生成', 'info');
            } else {
                toast('生成失败: ' + e.message, 'error');
                var idx2 = state.messages.findIndex(function (m) { return m.id === userMsg.id; });
                if (idx2 !== -1) state.messages.splice(idx2, 1);
                if (aiMsgEl && aiMsgEl.parentNode) aiMsgEl.remove();
                renderMessages();
            }
        } finally {
            state.isSending = false;
            state.stopRequested = false;
            state.abortCtrl = null;
            setSendBtnMode('idle');
        }
    }

    function openSidebar() {
        var s = $('dscSidebar'), o = $('dscSidebarOverlay');
        if (s) s.classList.add('open');
        if (o) o.classList.add('open');
    }
    function closeSidebar() {
        var s = $('dscSidebar'), o = $('dscSidebarOverlay');
        if (s) s.classList.remove('open');
        if (o) o.classList.remove('open');
    }
    function toggleSidebar() {
        var s = $('dscSidebar');
        if (!s) return;
        if (s.classList.contains('open')) closeSidebar();
        else openSidebar();
    }

    function openPlusMenu() {
        var m = $('dscPlusMenu'), b = $('dscPlusBtn');
        if (!m) return;
        m.classList.add('open');
        if (b) b.classList.add('active');
    }
    function closePlusMenu() {
        var m = $('dscPlusMenu'), b = $('dscPlusBtn');
        if (m) m.classList.remove('open');
        if (b) b.classList.remove('active');
    }
    function togglePlusMenu() {
        var m = $('dscPlusMenu');
        if (!m) return;
        if (m.classList.contains('open')) closePlusMenu();
        else openPlusMenu();
    }

    function triggerFileInput(type) {
        closePlusMenu();
        var inputId = 'dscFileInputAny';
        if (type === 'image') inputId = 'dscFileInputImage';
        else if (type === 'document') inputId = 'dscFileInputDoc';
        else if (type === 'video') inputId = 'dscFileInputVideo';
        var input = $(inputId);
        if (input) input.click();
    }

    function ensureAdvancedBtn() {
        if ($('dscAdvancedBtn')) return;
        var panel = $('dscToolsExtra');
        var levelBtn = $('dscLevelBtn');
        var btn = document.createElement('button');
        btn.id = 'dscAdvancedBtn';
        btn.type = 'button';
        btn.className = 'dsc-advanced-btn';
        btn.title = '高级模式';
        btn.innerHTML = '<span class="ic">🔒</span>';
        if (panel) panel.appendChild(btn);
        else if (levelBtn && levelBtn.parentNode) levelBtn.parentNode.insertBefore(btn, levelBtn.nextSibling);
    }

    // ============================================================
    // 📞 deepseek 打电话（语音·视频通话 · 本地 whisper 识别）
    // 大肥鱼 AI 形象（用户照片抠图）· 实时字幕（无前缀·简体中文）· 本地 STT · TTS
    // ============================================================
    var CALL_STYLE_PROMPT = '【实时通话模式】你现在正在进行实时语音通话，你叫 deepseek，是一只胖乎乎、可爱的大肥鱼。请严格遵守：1. 用口语化、自然、简短的中文回答，像真人打电话一样；2. 必须多使用语气词，例如：嗯、啊、啦、哦、哈、呀、嘿嘿、哇、哎哟、嘛、呢、吧、哦豁；3. 每条回复控制在 1 到 3 句话，不要长篇大论；4. 绝对不要使用 Markdown 标题、列表、代码块、表格，直接说人话；5. 可以自然表达情绪和表情，比如开心、好奇、惊讶；6. 每句话尽量短，用句号、感叹号、问号结尾，方便实时语音逐句播报，不要用逗号把句子拖长；7. 回答要生动、亲切、有画面感；8. 所有文字和字幕必须使用简体中文，绝对禁止使用繁体中文。';

    var T2S_MAP = {"說":"说","話":"话","這":"这","個":"个","麼":"么","會":"会","時":"时","來":"来","聽":"听","見":"见","覺":"觉","還":"还","嗎":"吗","體":"体","樣":"样","讓":"让","點":"点","對":"对","現":"现","實":"实","愛":"爱","們":"们","沒":"没","無":"无","過":"过","開":"开","關":"关","問":"问","幾":"几","學":"学","認":"认","識":"识","講":"讲","語":"语","誰":"谁","為":"为","從":"从","裡":"里","裏":"里","後":"后","東":"东","車":"车","馬":"马","魚":"鱼","鳥":"鸟","龍":"龙","風":"风","雲":"云","電":"电","腦":"脑","機":"机","臉":"脸","頭":"头","發":"发","髮":"发","聲":"声","樂":"乐","圖":"图","書":"书","寫":"写","讀":"读","當":"当","鐘":"钟","週":"周","禮":"礼","謝":"谢","請":"请","氣":"气","係":"系","歡":"欢","難":"难","傷":"伤","餓":"饿","飽":"饱","熱":"热","閒":"闲","煩":"烦","悶":"闷","視":"视","頻":"频","師":"师","爺":"爷","應":"应","該":"该","須":"须","壞":"坏","錯":"错","雖":"虽","較":"较","幹":"干","囉":"啰","喲":"哟","唄":"呗","吶":"呐","嘍":"喽","國":"国","經":"经","離":"离","邊":"边","進":"进","遠":"远","連":"连","萬":"万","塊":"块","錢":"钱","買":"买","賣":"卖","貴":"贵","價":"价","處":"处","號":"号","記":"记","紀":"纪","約":"约","結":"结","給":"给","統":"统","網":"网","線":"线","總":"总","組":"组","細":"细","終":"终","紅":"红","綠":"绿","藍":"蓝","黃":"黄","長":"长","張":"张","將":"将","強":"强","導":"导","層":"层","屬":"属","歲":"岁","島":"岛","帶":"带","幫":"帮","幣":"币","戲":"戏","戶":"户","掃":"扫","掛":"挂","擋":"挡","擇":"择","擁":"拥","據":"据","擔":"担","換":"换","搶":"抢","搖":"摇","擺":"摆","數":"数","敵":"敌","斷":"断","於":"于","舊":"旧","曬":"晒","條":"条","業":"业","樓":"楼","樹":"树","檢":"检","櫃":"柜","檔":"档","歸":"归","殺":"杀","決":"决","況":"况","準":"准","測":"测","滿":"满","滅":"灭","濃":"浓","溫":"温","遊":"游","漢":"汉","燈":"灯","營":"营","爭":"争","獨":"独","獲":"获","環":"环","產":"产","畫":"画","異":"异","監":"监","盤":"盘","確":"确","種":"种","稱":"称","競":"竞","節":"节","簡":"简","類":"类","粉":"粉","級":"级","紙":"纸","紋":"纹","純":"纯","納":"纳","紛":"纷","絕":"绝","絡":"络","絲":"丝","緊":"紧","練":"练","紹":"绍","罪":"罪","置":"置","義":"义","習":"习","翻":"翻","聖":"圣","聯":"联","肅":"肃","腳":"脚","臺":"台","與":"与","興":"兴","舉":"举","舍":"舍","著":"着","菜":"菜","華":"华","虛":"虚","蟲":"虫","裝":"装","補":"补","觀":"观","規":"规","計":"计","訂":"订","討":"讨","訓":"训","訊":"讯","設":"设","訪":"访","評":"评","詞":"词","誤":"误","課":"课","論":"论","談":"谈","諾":"诺","證":"证","議":"议","變":"变","讚":"赞","貝":"贝","財":"财","責":"责","貨":"货","費":"费","貸":"贷","貿":"贸","賀":"贺","資":"资","賓":"宾","賞":"赏","賢":"贤","賬":"账","賠":"赔","賴":"赖","購":"购","贈":"赠","贏":"赢","越":"越","趣":"趣","軍":"军","軌":"轨","軟":"软","載":"载","輕":"轻","輪":"轮","轉":"转","辦":"办","農":"农","運":"运","達":"达","違":"违","適":"适","選":"选","邏":"逻","醫":"医","釋":"释","鐵":"铁","銀":"银","鍵":"键","門":"门","閉":"闭","間":"间","聞":"闻","隊":"队","陣":"阵","陰":"阴","陽":"阳","階":"阶","際":"际","隨":"随","險":"险","隱":"隐","靜":"静","頂":"顶","順":"顺","預":"预","領":"领","題":"题","額":"额","願":"愿","飛":"飞","飯":"饭","養":"养","餘":"余","駕":"驾","驗":"验","驚":"惊","鬥":"斗","鹼":"碱","鹽":"盐","麥":"麦","齊":"齐","龜":"龟"};
    function t2s(s) {
        if (!s) return s;
        for (var k in T2S_MAP) {
            if (s.indexOf(k) >= 0) s = s.split(k).join(T2S_MAP[k]);
        }
        return s;
    }

    var callState = {
        active: false,
        micOn: true,
        camOn: false,
        speaking: false,
        thinking: false,
        listening: false,
        stream: null,
        videoStream: null,
        mediaRecorder: null,
        audioChunks: [],
        audioCtx: null,
        analyser: null,
        sessionId: null,
        silenceTimer: null,
        voiceFrames: 0,
        liveSubtitleEl: null,
        srBroken: false,
        recording: false,
        hasSpoken: false,
        abortCtrl: null,
        ttsAudio: null,
        ttsQueue: [],
        ttsPlaying: false,
        ttsPending: ''
    };

    var CALL_SILENCE_MS = 3000;
    var CALL_VOLUME_THRESHOLD = 0.05;
    var CALL_VOICE_FRAMES = 2;
    var CALL_MIN_SENTENCE = 3;
    var CALL_MAX_SENTENCE = 30;

    function ensureCallBtn() {
        // 📞 电话按钮已按需求删除（不再创建）
        return;
    }

    function toggleCall() {
        if (callState.active) stopCall();
        else startCall();
    }

    function bigFishImg() {
        return '<div class="dsc-call-fish-blinkwrap">' +
            '<img class="dsc-fish-img" src="/imgs/9/2/fwyu_fish.png" alt="大肥鱼 deepseek" draggable="false">' +
            '</div>';
    }

    function buildCallOverlay() {
        if ($('dscCallOverlay')) return;
        var overlay = document.createElement('div');
        overlay.id = 'dscCallOverlay';
        overlay.className = 'dsc-call-overlay';
        overlay.innerHTML =
            '<div class="dsc-call-stage">' +
                '<div id="dscCallFishWrap" class="dsc-call-fish-wrap">' + bigFishImg() + '</div>' +
                '<div id="dscCallStatus" class="dsc-call-status">📶 连接中…</div>' +
                '<div class="dsc-call-name">🐟 deepseek</div>' +
            '</div>' +
            '<div id="dscCallSubtitles" class="dsc-call-subtitles"></div>' +
            '<div id="dscCallInputBar" class="dsc-call-inputbar" style="display:none">' +
                '<input id="dscCallTextInput" class="dsc-call-textinput" type="text" placeholder="语音不可用？直接打字发送…" autocomplete="off">' +
                '<button id="dscCallSendBtn" class="dsc-call-sendbtn" type="button">发送</button>' +
            '</div>' +
            '<div class="dsc-call-controls">' +
                '<button id="dscCallMicBtn" class="dsc-call-ctl" type="button" title="开关麦克风">🎙️</button>' +
                '<button id="dscCallEndBtn" class="dsc-call-ctl dsc-call-end" type="button">📵 挂断</button>' +
            '</div>';
        document.body.appendChild(overlay);

        $('dscCallEndBtn').addEventListener('click', stopCall);
        $('dscCallMicBtn').addEventListener('click', toggleCallMic);
        $('dscCallSendBtn').addEventListener('click', function () { callSendTextInput(); });
        $('dscCallTextInput').addEventListener('keydown', function (e) {
            if (e.key === 'Enter') { e.preventDefault(); callSendTextInput(); }
        });
    }

    function updateFishMood(mood) {
        var wrap = $('dscCallFishWrap');
        if (wrap) {
            wrap.innerHTML = bigFishImg();
            wrap.className = 'dsc-call-fish-wrap mood-' + mood;
        }
    }

    function updateCallStatus(s) {
        var el = $('dscCallStatus');
        if (!el) return;
        var map = {
            listening: '🔊 聆听中…',
            thinking: '🐟 deepseek 正在想…',
            speaking: '🐟 deepseek 正在说…',
            muted: '🔇 已静音',
            error: '⚠️ 出错了',
            connecting: '📶 连接中…'
        };
        el.textContent = map[s] || s;
    }

    function appendCallSubtitle(type, text) {
        var box = $('dscCallSubtitles');
        if (!box) return;
        var item = document.createElement('div');
        item.className = 'dsc-call-sub ' + type;
        var avatar = type === 'user' ? '🧑' : '🐟';
        item.innerHTML = '<span class="dsc-call-sub-avatar">' + avatar + '</span><span class="dsc-call-sub-text"></span>';
        var txt = item.querySelector('.dsc-call-sub-text');
        txt.textContent = text;
        box.appendChild(item);
        box.scrollTop = box.scrollHeight;
        return txt;
    }

    function updateCallSubtitleLive(text) {
        var box = $('dscCallSubtitles');
        if (!box) return;
        if (!callState.liveSubtitleEl || !callState.liveSubtitleEl.parentNode) {
            var item = document.createElement('div');
            item.className = 'dsc-call-sub user live';
            item.innerHTML = '<span class="dsc-call-sub-avatar">🧑</span><span class="dsc-call-sub-text"></span>';
            box.appendChild(item);
            callState.liveSubtitleEl = item.querySelector('.dsc-call-sub-text');
        }
        callState.liveSubtitleEl.textContent = text;
        box.scrollTop = box.scrollHeight;
    }

    function commitLiveSubtitle() {
        if (callState.liveSubtitleEl && callState.liveSubtitleEl.parentNode) {
            callState.liveSubtitleEl.parentNode.classList.remove('live');
        }
        callState.liveSubtitleEl = null;
    }

    async function ensureCallSession() {
        if (callState.sessionId) return;
        if (state.currentSessionId) {
            callState.sessionId = state.currentSessionId;
            return;
        }
        try {
            var res = await fetch('/api/ds-chat/sessions', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ title: '📞 通话' })
            });
            var data = await res.json();
            if (data && data.session && data.session.id) {
                state.sessions.unshift(data.session);
                state.currentSessionId = data.session.id;
                callState.sessionId = data.session.id;
                renderSessions();
            }
        } catch (e) {
            /* 会话创建失败不阻断通话 */
        }
    }

    function enterCallFullscreen() {
        var overlay = $('dscCallOverlay');
        if (!overlay) return;
        try {
            if (overlay.requestFullscreen) {
                overlay.requestFullscreen().catch(function () {});
            } else if (overlay.webkitRequestFullscreen) {
                overlay.webkitRequestFullscreen();
            }
        } catch (e) {}
        lockPortrait();
    }

    function lockPortrait() {
        try {
            if (screen.orientation && screen.orientation.lock) {
                screen.orientation.lock('portrait').catch(function () {});
            }
        } catch (e) {}
    }

    function unlockOrientation() {
        try {
            if (screen.orientation && screen.orientation.unlock) {
                screen.orientation.unlock();
            }
        } catch (e) {}
    }

    async function startCall() {
        if (callState.active) return;
        buildCallOverlay();
        var overlay = $('dscCallOverlay');
        overlay.classList.add('show');
        overlay.classList.add('voice-only');
        callState.active = true;
        callState.micOn = true;
        callState.camOn = false;
        callState.thinking = false;
        callState.speaking = false;
        callState.recording = false;
        callState.hasSpoken = false;
        callState.voiceFrames = 0;
        callState.srBroken = false;
        callState.sessionId = null;
        callState.abortCtrl = null;
        callState.ttsAudio = null;
        callState.ttsQueue = [];
        callState.ttsPlaying = false;
        callState.ttsPending = '';
        $('dscCallSubtitles').innerHTML = '';
        var inputBar = $('dscCallInputBar');
        if (inputBar) inputBar.style.display = 'none';
        $('dscCallMicBtn').classList.remove('off');
        updateCallStatus('connecting');

        enterCallFullscreen();

        if (!window.isSecureContext) {
            appendCallSubtitle('ai', '当前地址不是安全环境，麦克风会被浏览器禁用。请改用 http://localhost:9999 访问哦～');
        }

        await ensureCallSession();

        // 1) 纯语音通话（不调用摄像头，大肥鱼主画面完全可见）
        callState.camOn = false;
        callState.videoStream = null;
        overlay.classList.add('voice-only');

        // 2) 麦克风（本地 whisper 识别）
        var gotMic = false;
        if (navigator.mediaDevices && navigator.mediaDevices.getUserMedia) {
            try {
                callState.stream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
                gotMic = true;
            } catch (e) {
                callState.stream = null;
            }
        }

        if (!gotMic) {
            callState.srBroken = true;
            appendCallSubtitle('ai', '麦克风没打开，我先打开输入框，打字也能聊哦～');
            showCallInput();
        } else {
            initCallRecorder();
        }

        appendCallSubtitle('ai', '现在是语音通话，大肥鱼 deepseek 上线啦～');

        updateCallStatus('listening');
        updateFishMood('listen');
        toast('📞 通话已接通（大肥鱼 deepseek 上线啦）', 'success');
    }

    function initCallRecorder() {
        var AudioCtx = window.AudioContext || window.webkitAudioContext;
        if (!callState.stream || typeof MediaRecorder === 'undefined') {
            callState.srBroken = true;
            appendCallSubtitle('ai', '这个浏览器不支持录音，我先把输入框打开，打字也能聊哦～');
            showCallInput();
            return;
        }
        try {
            callState.audioCtx = new AudioCtx();
            var source = callState.audioCtx.createMediaStreamSource(callState.stream);
            callState.analyser = callState.audioCtx.createAnalyser();
            callState.analyser.fftSize = 1024;
            source.connect(callState.analyser);
            var dataArray = new Uint8Array(callState.analyser.fftSize);

            var silenceStart = null;
            var checkTimer = setInterval(function () {
                if (!callState.active) { clearInterval(checkTimer); return; }
                if (callState.thinking || callState.speaking) return; // AI 说话时不录音
                callState.analyser.getByteTimeDomainData(dataArray);
                var sum = 0;
                for (var i = 0; i < dataArray.length; i++) {
                    var v = (dataArray[i] - 128) / 128;
                    sum += v * v;
                }
                var rms = Math.sqrt(sum / dataArray.length);
                var isVoice = rms > CALL_VOLUME_THRESHOLD;
                if (isVoice) {
                    callState.voiceFrames = (callState.voiceFrames || 0) + 1;
                    silenceStart = null;
                    if (!callState.recording && callState.voiceFrames >= CALL_VOICE_FRAMES) {
                        callState.hasSpoken = true;
                        startRecording();
                    }
                } else {
                    callState.voiceFrames = 0;
                    if (callState.recording) {
                        if (silenceStart === null) silenceStart = Date.now();
                        if (Date.now() - silenceStart >= CALL_SILENCE_MS) {
                            stopRecording();
                            silenceStart = null;
                        }
                    }
                }
            }, 140);
            callState.silenceTimer = checkTimer;
        } catch (e) {
            callState.srBroken = true;
            appendCallSubtitle('ai', '录音初始化失败：' + (e && e.message ? e.message : e) + '，我先打开输入框～');
            showCallInput();
        }
    }

    function startRecording() {
        if (!callState.stream || callState.recording) return;
        var options = {};
        if (typeof MediaRecorder !== 'undefined') {
            var mimes = ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4', 'audio/ogg;codecs=opus'];
            for (var i = 0; i < mimes.length; i++) {
                try {
                    if (MediaRecorder.isTypeSupported && MediaRecorder.isTypeSupported(mimes[i])) {
                        options.mimeType = mimes[i];
                        break;
                    }
                } catch (e) {}
            }
        }
        try {
            callState.mediaRecorder = new MediaRecorder(callState.stream, options);
        } catch (e) {
            callState.mediaRecorder = new MediaRecorder(callState.stream);
        }
        callState.audioChunks = [];
        callState.mediaRecorder.ondataavailable = function (e) {
            if (e.data && e.data.size > 0) callState.audioChunks.push(e.data);
        };
        callState.mediaRecorder.onstop = function () {
            var mime = (callState.mediaRecorder && callState.mediaRecorder.mimeType) || 'audio/webm';
            var blob = new Blob(callState.audioChunks, { type: mime });
            callState.audioChunks = [];
            callState.recording = false;
            if (blob.size > 1000 && callState.hasSpoken && callState.active) {
                callSendAudio(blob);
            }
        };
        callState.mediaRecorder.start(200);
        callState.recording = true;
    }

    function stopRecording() {
        if (callState.mediaRecorder && callState.recording) {
            try { callState.mediaRecorder.stop(); } catch (e) {}
        }
    }

    function callSendAudio(blob) {
        if (!blob || blob.size < 1000) return;
        updateCallStatus('thinking');
        updateFishMood('listen');
        var form = new FormData();
        form.append('audio', blob, 'audio.webm');
        fetch('/api/ds-chat/stt', {
            method: 'POST',
            body: form
        }).then(function (res) {
            if (!res.ok) throw new Error('STT ' + res.status);
            return res.json();
        }).then(function (data) {
            var text = cleanCallText(data && data.text ? data.text : '');
            if (!text) { updateCallStatus('listening'); return; }
            text = t2s(text);
            callHandleFinalText(text);
        }).catch(function (e) {
            console.warn('[CALL] STT 失败', e);
            appendCallSubtitle('ai', '哎哟，语音识别出了点小问题，你打字发给我也行哦～');
            updateCallStatus('listening');
            showCallInput();
        });
    }

    function cleanCallText(s) {
        if (!s) return '';
        s = String(s).replace(/\[[^\]]*\]/g, '').replace(/\([^)]*\)/g, '').replace(/（[^）]*）/g, '');
        s = s.replace(/output_[a-z_]*:[^\n]*/gi, '');
        s = s.replace(/\s+/g, ' ').trim();
        return s;
    }

    function showCallInput() {
        var bar = $('dscCallInputBar');
        if (bar) bar.style.display = 'flex';
    }

    function callSendTextInput() {
        var input = $('dscCallTextInput');
        if (!input) return;
        var text = t2s((input.value || '').trim());
        if (!text) return;
        input.value = '';
        callHandleFinalText(text);
    }

    function toggleCallMic() {
        callState.micOn = !callState.micOn;
        var btn = $('dscCallMicBtn');
        if (btn) btn.classList.toggle('off', !callState.micOn);
        if (callState.stream) {
            callState.stream.getAudioTracks().forEach(function (t) { t.enabled = callState.micOn; });
        }
        if (callState.micOn) {
            updateCallStatus('listening');
        } else {
            if (callState.recording) stopRecording();
            updateCallStatus('muted');
        }
        toast(callState.micOn ? '🎙️ 麦克风已开启' : '🔇 麦克风已静音', 'info');
    }

    async function callHandleFinalText(text) {
        appendCallSubtitle('user', text);
        callState.thinking = true;
        callState.speaking = false;
        updateCallStatus('thinking');
        updateFishMood('listen');
        var full = '';
        try {
            full = await callSendAI(text);
        } catch (e) {
            if (!callState.active) return;
            appendCallSubtitle('ai', '哎哟，通话出了点小问题：' + (e && e.message ? e.message : '网络错误') + '，再试一次嘛～');
            updateCallStatus('listening');
            callState.thinking = false;
            return;
        }
        callState.thinking = false;
        if (!callState.active) return; // 挂断后不再播报
        var nothingToSpeak = !full && callState.ttsQueue.length === 0 && !callState.ttsPlaying;
        if (nothingToSpeak) {
            updateCallStatus('listening');
            return;
        }
        // 边生成边播报：等待逐句 TTS 队列播放完毕
        try {
            await callWaitTTSQueue();
        } catch (e) {}
        callState.speaking = false;
        if (callState.active) {
            updateCallStatus('listening');
            updateFishMood('listen');
        }
    }

    function callSendAI(text) {
        return new Promise(function (resolve, reject) {
            callState.abortCtrl = new AbortController();
            callState.ttsPending = '';
            var payload = {
                sessionId: callState.sessionId,
                content: text,
                model: state.currentModel || 'deepseek-flash',
                reasoningLevel: 8,
                deepThink: false,
                webSearch: false,
                longTextMode: false,
                enableTools: false,
                stream: true,
                injectedPrompts: [CALL_STYLE_PROMPT]
            };
            fetch('/api/ds-chat/send', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload),
                signal: callState.abortCtrl.signal
            }).then(function (res) {
                if (!res.ok || !res.body) {
                    return res.json().catch(function () { return {}; }).then(function (d) {
                        reject(new Error(d.error || ('HTTP ' + res.status)));
                    });
                }
                var reader = res.body.getReader();
                var decoder = new TextDecoder('utf-8');
                var buffer = '';
                var currentEvent = '';
                var full = '';
                var aiTextEl = appendCallSubtitle('ai', '');

                function pump() {
                    if (!callState.active) {
                        try { reader.cancel(); } catch (e) {}
                        callFlushTTS(full);
                        resolve(full);
                        return;
                    }
                    reader.read().then(function (r) {
                        if (r.done) {
                            callFlushTTS(full);
                            resolve(full);
                            return;
                        }
                        buffer += decoder.decode(r.value, { stream: true });
                        var lines = buffer.split('\n');
                        buffer = lines.pop();
                        for (var i = 0; i < lines.length; i++) {
                            var line = lines[i];
                            if (line.startsWith('event: ')) {
                                currentEvent = line.slice(7).trim();
                            } else if (line.startsWith('data: ')) {
                                var raw = line.slice(6);
                                if (!raw) continue;
                                var obj;
                                try { obj = JSON.parse(raw); } catch (e) { continue; }
                                if (currentEvent === 'content') {
                                    var delta = obj.delta || '';
                                    full += delta;
                                    if (aiTextEl) aiTextEl.textContent = full;
                                    var box = $('dscCallSubtitles');
                                    if (box) box.scrollTop = box.scrollHeight;
                                } else if (currentEvent === 'error') {
                                    reject(new Error(obj.message || '流式错误'));
                                    return;
                                }
                            }
                        }
                        pump();
                    }).catch(function (e) { reject(e); });
                }
                pump();
            }).catch(function (e) {
                if (e && e.name === 'AbortError') { resolve(''); return; }
                reject(e);
            });
        });
    }

    function callTTS(text) {
        return new Promise(function (resolve, reject) {
            fetch('/api/ds-chat/tts', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ text: text, voice: 'zh-CN-XiaoxiaoNeural' })
            }).then(function (res) {
                if (!res.ok) throw new Error('TTS 返回 ' + res.status);
                return res.blob();
            }).then(function (blob) {
                var url = URL.createObjectURL(blob);
                var audio = new Audio(url);
                callState.ttsAudio = audio;
                var done = false;
                function cleanup() {
                    if (done) return;
                    done = true;
                    try { URL.revokeObjectURL(url); } catch (e) {}
                    if (callState.ttsAudio === audio) callState.ttsAudio = null;
                }
                audio.onended = function () { cleanup(); resolve(); };
                audio.onpause = function () { cleanup(); resolve(); };
                audio.onerror = function () { cleanup(); reject(new Error('音频播放失败')); };
                audio.play().catch(function (e) { cleanup(); reject(e); });
            }).catch(reject);
        });
    }

    // ★ 实时通话核心：AI 流式输出时逐句切分，边生成边合成边播放（流水线，大幅降低首句延迟）
    function callFeedTTS(delta) {
        if (!delta) return;
        callState.ttsPending += delta;
        var pend = callState.ttsPending;
        var out = [];
        var idx = 0;
        var segStart = 0;
        while (idx < pend.length) {
            var ch = pend.charAt(idx);
            if (ch === '。' || ch === '！' || ch === '？' || ch === '!' || ch === '?' || ch === '；' || ch === ';' || ch === '\n') {
                var seg = pend.slice(segStart, idx + 1);
                if (seg.length >= CALL_MIN_SENTENCE) {
                    out.push(seg.trim());
                    segStart = idx + 1;
                }
            }
            idx++;
        }
        callState.ttsPending = pend.slice(segStart);
        // 兜底：AI 长时间不写句末标点时，在逗号/空格处强制切分，避免首句等太久
        if (callState.ttsPending.length >= CALL_MAX_SENTENCE) {
            var cut = -1;
            for (var k = CALL_MIN_SENTENCE; k < callState.ttsPending.length; k++) {
                var c2 = callState.ttsPending.charAt(k);
                if (c2 === '，' || c2 === ',' || c2 === '、' || c2 === ' ') {
                    cut = k;
                    break;
                }
            }
            if (cut > 0) {
                var head = callState.ttsPending.slice(0, cut + 1);
                callState.ttsPending = callState.ttsPending.slice(cut + 1);
                out.push(head.trim());
            }
        }
        for (var j = 0; j < out.length; j++) {
            callEnqueueTTS(out[j]);
        }
    }

    function callEnqueueTTS(text) {
        text = (text || '').trim();
        if (!text || !callState.active) return;
        callState.ttsQueue.push(text);
        callState.speaking = true;
        updateCallStatus('speaking');
        updateFishMood('talk');
        callDrainTTSQueue();
    }

    function callDrainTTSQueue() {
        if (callState.ttsPlaying) return;
        if (!callState.active) { callState.ttsQueue = []; return; }
        if (callState.ttsQueue.length === 0) return;
        callState.ttsPlaying = true;
        var text = callState.ttsQueue.shift();
        callTTS(text).then(function () {
            callState.ttsPlaying = false;
            callDrainTTSQueue();
        }).catch(function (e) {
            callState.ttsPlaying = false;
            console.warn('[CALL] TTS 块失败', e);
            callDrainTTSQueue();
        });
    }

    function callFlushTTS(text) {
        text = (text || '').trim();
        if (text && callState.active) {
            callEnqueueTTS(text);
        }
        callState.ttsPending = '';
    }

    function callWaitTTSQueue() {
        return new Promise(function (resolve) {
            function check() {
                if (callState.active && (callState.ttsPlaying || callState.ttsQueue.length > 0)) {
                    setTimeout(check, 100);
                } else {
                    resolve();
                }
            }
            check();
        });
    }

    function stopCall() {
        if (!callState.active) return;
        callState.active = false;
        callState.listening = false;
        if (callState.abortCtrl) { try { callState.abortCtrl.abort(); } catch (e) {} callState.abortCtrl = null; }
        if (callState.silenceTimer) { clearInterval(callState.silenceTimer); callState.silenceTimer = null; }
        if (callState.recording) stopRecording();
        callState.mediaRecorder = null;
        if (callState.stream) {
            callState.stream.getTracks().forEach(function (t) { try { t.stop(); } catch (e) {} });
            callState.stream = null;
        }
        if (callState.audioCtx) { try { callState.audioCtx.close(); } catch (e) {} callState.audioCtx = null; }
        callState.ttsQueue = [];
        callState.ttsPlaying = false;
        callState.ttsPending = '';
        if (callState.ttsAudio) { try { callState.ttsAudio.pause(); } catch (e) {} callState.ttsAudio = null; }
        var overlay = $('dscCallOverlay');
        if (overlay) overlay.classList.remove('show');
        callState.thinking = false;
        callState.speaking = false;
        callState.srBroken = false;
        unlockOrientation();
        try { if (document.fullscreenElement) { document.exitFullscreen().catch(function () {}); } } catch (e) {}
        toast('📵 通话已结束', 'info');
    }
    function applyAdvancedMode(enabled) {
        state.advancedMode = enabled;
        if (enabled) {
            state.reasoningLevel = state.advancedLevel || ADVANCED_DEFAULT_LEVEL;
        } else {
            state.reasoningLevel = state.deepThink ? (DEFAULT_LEVEL + 5) : DEFAULT_LEVEL;
            state.tempLevel = state.reasoningLevel;
        }
        try { localStorage.setItem('dsc_advancedMode', enabled ? '1' : '0'); } catch (e) {}
        updateAdvancedUI();
        updateLevelUI(state.reasoningLevel);
    }

    function toggleAdvancedMode() {
        if (state.advancedMode) {
            simpleConfirm('关闭高级模式',
                '关闭后推理等级将恢复为默认 Lv.' + (state.deepThink ? (DEFAULT_LEVEL + 5) : DEFAULT_LEVEL) + '，无法自定义。确定关闭吗？'
            ).then(function (ok) {
                if (!ok) return;
                applyAdvancedMode(false);
                toast('已关闭高级模式 · 推理等级 Lv.' + state.reasoningLevel, 'info');
            });
        } else {
            simpleConfirm('⚠️ 开启高级模式',
                '高级模式允许自定义推理等级（Lv.1-50）。等级影响 max_tokens 和 temperature，所有对话都走流式打字机输出。'
            ).then(function (ok) {
                if (!ok) return;
                applyAdvancedMode(true);
                toast('🔒 高级模式已开启 · 推理等级 Lv.' + state.reasoningLevel, 'success');
            });
        }
    }

    function updateAdvancedUI() {
        var btn = $('dscAdvancedBtn');
        if (btn) {
            btn.classList.toggle('active', state.advancedMode);
            var ic = btn.querySelector('.ic');
            if (ic) ic.textContent = state.advancedMode ? '🔓' : '🔒';
        }
        var levelBtn = $('dscLevelBtn');
        if (levelBtn) levelBtn.style.display = state.advancedMode ? '' : 'none';
    }

    function ensureLongTextBtn() { return; }

    function toggleLongTextMode() {
        state.longTextMode = !state.longTextMode;
        try { localStorage.setItem('dsc_longTextMode', state.longTextMode ? '1' : '0'); } catch (e) {}
        updateLongTextUI();
        toast(state.longTextMode
            ? ('📚 超长文本已开启（目标 ' + (state.longTextTargetChars / 10000).toFixed(0) + ' 万字）')
            : '📚 超长文本已关闭', state.longTextMode ? 'success' : 'info');
    }

    function updateLongTextUI() {
        var btn = $('dscLongTextBtn');
        if (!btn) return;
        btn.classList.toggle('active', state.longTextMode);
        var ic = btn.querySelector('.ic');
        if (ic) ic.textContent = state.longTextMode ? '📖' : '📚';
    }

    function ensureNovelBtn() {
        if ($('dscNovelModeBtn')) return;
        var panel = $('dscToolsExtra');
        var refNode = $('dscLongTextBtn') || $('dscLevelBtn');
        var btn = document.createElement('button');
        btn.id = 'dscNovelModeBtn';
        btn.type = 'button';
        btn.className = 'dsc-novel-btn';
        btn.title = '小说模式（一键生成最长 100 万字小说）';
        btn.innerHTML = '<span class="ic">📖</span>';
        if (panel) panel.appendChild(btn);
        else if (refNode && refNode.parentNode) refNode.parentNode.insertBefore(btn, refNode.nextSibling);
    }

    function openNovelDialog() {
        var overlay = $('dscNovelOverlay');
        if (!overlay) {
            overlay = document.createElement('div');
            overlay.id = 'dscNovelOverlay';
            overlay.className = 'dsc-novel-popup-overlay';
            overlay.innerHTML =
                '<div class="dsc-modal">' +
                '<div class="dsc-modal-title">📖 小说模式</div>' +
                '<div class="dsc-modal-sub">一键生成完整小说 · 最长 100 万字/篇 · 流式输出</div>' +
                '<div class="dsc-novel-grid">' +
                '<div class="dsc-field"><label>主题</label><input id="dscNovelTheme" placeholder="例如：爱情小说"></div>' +
                '<div class="dsc-field"><label>标签</label><input id="dscNovelTags" placeholder="例如：爱情"></div>' +
                '<div class="dsc-field"><label>分类</label>' +
                '<div class="dsc-custom-select">' +
                '<button type="button" class="dsc-custom-select-btn" id="dscNovelGenreBtn">' +
                '<span class="dsc-custom-select-label" id="dscNovelGenreLabel">都市</span>' +
                '<span class="dsc-custom-select-arrow">▾</span>' +
                '</button>' +
                '<div class="dsc-custom-select-menu" id="dscNovelGenreMenu">' +
                ['玄幻','仙侠','都市','历史','科幻','悬疑','言情','爱情','百合','少女','短文','微恐','暴恐','色情','虐恋','其他','爽文','女女','二人','情话','科技','语料','校园','教程','教学','美女','生活','大学','单人','异世','动漫','恐怖','黑暗','军事','游戏','其他']
                    .map(function (v) {
                        return '<div class="dsc-custom-select-item' + (v === '都市' ? ' selected' : '') + '" data-value="' + v + '">' + v + '</div>';
                    }).join('') +
                '</div></div></div>' +
                '<div class="dsc-field"><label>目标字数</label><input id="dscNovelChars" type="number" value="30000" min="5000" max="1000000" step="1000"></div>' +
                '<div class="dsc-field full"><label>故事设定</label><textarea id="dscNovelStory" rows="3" placeholder="详细描述故事背景、主要人物、核心冲突、想要的结局走向等"></textarea></div>' +
                '</div>' +
                '<div class="dsc-modal-footer">' +
                '<button class="dsc-btn ghost" id="dscNovelCancel">取消</button>' +
                '<button class="dsc-btn primary" id="dscNovelStart">🚀 开始创作</button>' +
                '</div></div>';
            document.body.appendChild(overlay);

            overlay.addEventListener('click', function (e) {
                if (e.target === overlay) overlay.classList.remove('open');
            });
            var cancelBtn = overlay.querySelector('#dscNovelCancel');
            if (cancelBtn) cancelBtn.addEventListener('click', function () { overlay.classList.remove('open'); });
            var startBtn = overlay.querySelector('#dscNovelStart');
            if (startBtn) startBtn.addEventListener('click', startNovelGeneration);

            var genreBtn = overlay.querySelector('#dscNovelGenreBtn');
            var genreMenu = overlay.querySelector('#dscNovelGenreMenu');
            var genreLabel = overlay.querySelector('#dscNovelGenreLabel');

            if (genreBtn && genreMenu && genreLabel) {
                genreBtn.addEventListener('click', function (e) {
                    e.stopPropagation();
                    genreMenu.classList.toggle('open');
                });
                genreMenu.addEventListener('click', function (e) {
                    var item = e.target.closest('.dsc-custom-select-item');
                    if (!item) return;
                    e.stopPropagation();
                    genreMenu.querySelectorAll('.dsc-custom-select-item').forEach(function (el) { el.classList.remove('selected'); });
                    item.classList.add('selected');
                    genreLabel.textContent = item.dataset.value;
                    genreMenu.classList.remove('open');
                });
                document.addEventListener('click', function (e) {
                    if (!genreMenu.classList.contains('open')) return;
                    if (genreMenu.contains(e.target) || genreBtn.contains(e.target)) return;
                    genreMenu.classList.remove('open');
                });
            }
        }
        overlay.classList.add('open');
    }

    function ensureToolModeBtn() {
        if ($('dscToolModeBtn')) return;
        var panel = $('dscToolsExtra');
        var refNode = $('dscNovelModeBtn') || $('dscLongTextBtn') || $('dscLevelBtn');
        var btn = document.createElement('button');
        btn.id = 'dscToolModeBtn';
        btn.type = 'button';
        btn.className = 'dsc-switch-btn';
        btn.title = '工具模式：AI 自主调用工具完成复杂任务（最多 50 亿轮）';
        btn.innerHTML = '<span class="ic">🔧</span>';
        if (panel) panel.appendChild(btn);
        else if (refNode && refNode.parentNode) refNode.parentNode.insertBefore(btn, refNode.nextSibling);
    }

    function levelDetail(level) {
        if (level <= 10) return { name: '单轮', rounds: 1, cost: '1x', desc: '直接回答' };
        if (level <= 25) return { name: '双轮', rounds: 2, cost: '~2.5x', desc: '回答 + 1 次反思' };
        if (level <= 40) return { name: '三轮', rounds: 3, cost: '~4x', desc: '回答 + 2 次反思' };
        return { name: '四轮', rounds: 4, cost: '~6x', desc: '回答 + 3 次反思' };
    }
    function levelTokens(level) {
        var maxTok = 8192 + (level - 1) * (120000 - 8192) / 49;
        return Math.round(maxTok);
    }

    function updateLevelUI(level) {
        var num = $('dscLevelNum');
        var tag = $('dscLevelTag');
        var info = $('dscLevelInfo');
        var d = levelDetail(level);
        if (num) num.textContent = level;
        if (tag) tag.textContent = String(level);
        if (info) {
            var tok = levelTokens(level);
            info.innerHTML =
                '<div style="margin-bottom:4px;">🧠 ' + d.rounds + ' 轮 · max_tokens ≈ <span class="hl">' + tok.toLocaleString() + '</span></div>' +
                '<div style="font-size:0.7rem;opacity:0.75;">' + d.desc + ' · 流式打字机输出</div>';
        }
        var btn = $('dscLevelBtn');
        if (btn) {
            btn.classList.toggle('active', level > 1);
            var ic = btn.querySelector('.ic');
            if (ic) ic.style.display = 'none';
            var txtSpan = btn.querySelector('.lvl-num');
            if (!txtSpan) {
                txtSpan = document.createElement('span');
                txtSpan.className = 'lvl-num';
                btn.appendChild(txtSpan);
            }
            txtSpan.textContent = String(level);
        }
    }

    function openLevelDialog() {
        if (!state.advancedMode) { toast('请先开启高级模式', 'info'); return; }
        var overlay = $('dscLevelOverlay'), range = $('dscLevelRange');
        if (!overlay || !range) return;
        state.tempLevel = state.reasoningLevel;
        range.value = state.tempLevel;
        updateLevelUI(state.tempLevel);
        overlay.classList.add('open');
    }
    function closeLevelDialog() {
        var overlay = $('dscLevelOverlay');
        if (overlay) overlay.classList.remove('open');
    }
    function saveLevelDialog() {
        if (!state.advancedMode) { closeLevelDialog(); return; }
        state.reasoningLevel = state.tempLevel;
        state.advancedLevel = state.tempLevel;
        try { localStorage.setItem('dsc_reasoningLevel', String(state.advancedLevel)); } catch (e) {}
        updateLevelUI(state.reasoningLevel);
        closeLevelDialog();
        toast('🧩 推理等级 Lv.' + state.reasoningLevel, 'success');
    }

    async function openSettings() {
        try {
            var res = await fetch('/api/ds-chat/config');
            var data = await res.json();
            var ak = $('dscApiKeyInput'), ms = $('dscModelSelect'),
                ik = $('dscImgKeyInput'), st = $('dscApiStatus');
            if (ak) { ak.value = ''; ak.placeholder = data.hasKey ? '已保存，留空不修改' : 'sk-...'; }
            if (ms) {
                var wantModel = data.model || 'deepseek-flash';
                ms.value = wantModel;
                if (ms.value !== wantModel) {
                    var opt = document.createElement('option');
                    opt.value = wantModel;
                    opt.textContent = wantModel + ' (来自配置)';
                    ms.appendChild(opt);
                    ms.value = wantModel;
                }
                state.currentModel = ms.value || wantModel;
            }
            if (ik) { ik.value = ''; ik.placeholder = data.hasImgKey ? '已保存，留空不修改' : '（可选）'; }
            if (st) {
                st.textContent = data.hasKey ? '✅ API Key 已配置 · 当前模型: ' + (data.model || 'deepseek-flash') : '⚠️ 未配置 API Key';
                st.className = 'dsc-status ' + (data.hasKey ? 'ok' : '');
            }
        } catch (e) {
            var st2 = $('dscApiStatus');
            if (st2) { st2.textContent = '读取配置失败'; st2.className = 'dsc-status err'; }
        }
        var overlay = $('dscSettingsOverlay');
        if (overlay) overlay.classList.add('open');
    }
    function closeSettings() {
        var o = $('dscSettingsOverlay');
        if (o) o.classList.remove('open');
    }
    async function saveSettings() {
        var apiKey = $('dscApiKeyInput') ? $('dscApiKeyInput').value.trim() : '';
        var model = $('dscModelSelect') ? $('dscModelSelect').value : 'deepseek-flash';
        var imgKey = $('dscImgKeyInput') ? $('dscImgKeyInput').value.trim() : '';
        try {
            var res = await fetch('/api/ds-chat/config', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ apiKey: apiKey, model: model, imgKey: imgKey })
            });
            var data = await res.json();
            if (!res.ok) throw new Error(data.error || '保存失败');
            state.currentModel = model;
            toast('设置已保存 · 模型: ' + model, 'success');
            updateTitle();
            closeSettings();
        } catch (e) { toast('保存失败: ' + e.message, 'error'); }
    }

    function autoResize() {
        var inputEl = $('dscInput');
        if (!inputEl) return;
        inputEl.style.height = 'auto';
        inputEl.style.height = Math.min(inputEl.scrollHeight, 140) + 'px';
    }

    function loadToolState() {
        try {
            state.webSearch = localStorage.getItem('dsc_webSearch') === '1';
            state.deepThink = localStorage.getItem('dsc_deepThink') === '1';
            state.advancedMode = localStorage.getItem('dsc_advancedMode') === '1';
            state.longTextMode = localStorage.getItem('dsc_longTextMode') === '1';
            state.enableTools = localStorage.getItem('dsc_enableTools') === '1';
            var savedModel = localStorage.getItem('dsc_currentModel');
            if (savedModel) state.currentModel = savedModel;
            var lv = parseInt(localStorage.getItem('dsc_reasoningLevel') || String(ADVANCED_DEFAULT_LEVEL), 10);
            if (isNaN(lv) || lv < 1) lv = ADVANCED_DEFAULT_LEVEL;
            if (lv > 50) lv = 50;
            state.advancedLevel = lv;
            var lt = parseInt(localStorage.getItem('dsc_longTextTargetChars') || String(LONG_TEXT_DEFAULT_CHARS), 10);
            if (isNaN(lt) || lt < 1000) lt = LONG_TEXT_DEFAULT_CHARS;
            if (lt > 500000) lt = 500000;
            state.longTextTargetChars = lt;
            if (state.advancedMode) state.reasoningLevel = lv;
            else state.reasoningLevel = state.deepThink ? (DEFAULT_LEVEL + 5) : DEFAULT_LEVEL;
            state.tempLevel = state.reasoningLevel;
        } catch (e) {
            state.advancedMode = false;
            state.advancedLevel = ADVANCED_DEFAULT_LEVEL;
            state.deepThink = false;
            state.reasoningLevel = DEFAULT_LEVEL;
            state.tempLevel = DEFAULT_LEVEL;
            state.longTextMode = false;
            state.longTextTargetChars = LONG_TEXT_DEFAULT_CHARS;
        }
        updateToolUI();
        updateLevelUI(state.reasoningLevel);
        updateAdvancedUI();
        updateLongTextUI();
    }
    // ★ 修复：启动时以「后端配置文件」为唯一真值同步模型
    // 旧逻辑只从 localStorage 读模型（默认 deepseek-v4-pro），从不与配置文件对齐，
    // 导致配置里写 deepseek-flash、实际请求却发 deepseek-v4-pro。
    var _modelSynced = false;
    async function syncModelFromConfig() {
        try {
            var res = await fetch('/api/ds-chat/config', { cache: 'no-cache' });
            if (!res.ok) return;
            var data = await res.json();
            var cfgModel = (data && data.model ? String(data.model) : '').trim();
            if (!cfgModel) return;
            var before = state.currentModel;
            state.currentModel = cfgModel;
            _modelSynced = true;
            try { localStorage.setItem('dsc_currentModel', cfgModel); } catch (e) {}
            var ms = $('dscModelSelect');
            if (ms) {
                ms.value = cfgModel;
                if (ms.value !== cfgModel) {
                    var opt = document.createElement('option');
                    opt.value = cfgModel;
                    opt.textContent = cfgModel + ' (来自配置)';
                    ms.appendChild(opt);
                    ms.value = cfgModel;
                }
            }
            updateTitle();
            if (before !== cfgModel) {
                console.log('[DSC] 模型已对齐配置: ' + before + ' -> ' + cfgModel);
            }
        } catch (e) { console.log('[DSC] 同步模型配置失败:', e); }
    }

    // ============================================================
    // 自定义模型管理
    //   持久化：后端 ddsh/data/displaymodels/<模型名>.sts（一个模型一个文件）
    //   浏览器 localStorage 仅作镜像缓存 / 后端不可用时的离线降级
    // ============================================================
    var CUSTOM_MODELS_KEY = 'dsc_custom_models';
    var customModelsCache = null;      // null = 尚未初始化
    var customModelsFromServer = false; // 后端是否已成功同步

    function readCustomModelsLocal() {
        try {
            var raw = localStorage.getItem(CUSTOM_MODELS_KEY);
            if (!raw) return [];
            var arr = JSON.parse(raw);
            if (!Array.isArray(arr)) return [];
            var out = [];
            for (var i = 0; i < arr.length; i++) {
                if (typeof arr[i] === 'string' && arr[i].trim()) out.push(arr[i].trim());
            }
            return out;
        } catch (e) { return []; }
    }
    function writeCustomModelsLocal(arr) {
        try { localStorage.setItem(CUSTOM_MODELS_KEY, JSON.stringify(arr)); } catch (e) {}
    }
    function getCustomModels() {
        if (customModelsCache === null) customModelsCache = readCustomModelsLocal();
        return customModelsCache.slice();
    }
    function setCustomModels(arr) {
        customModelsCache = arr.slice();
        writeCustomModelsLocal(customModelsCache);
    }
    function hasModelOption(name) {
        var ms = $('dscModelSelect');
        if (!ms) return false;
        for (var i = 0; i < ms.options.length; i++) {
            if (ms.options[i].value === name) return true;
        }
        return false;
    }
    function addModelOption(name, isCustom) {
        var ms = $('dscModelSelect');
        if (!ms || !name || hasModelOption(name)) return false;
        var opt = document.createElement('option');
        opt.value = name;
        opt.textContent = name + (isCustom ? '（自定义）' : '（来自配置）');
        ms.appendChild(opt);
        return true;
    }
    function clearCustomOptions() {
        var ms = $('dscModelSelect');
        if (!ms) return;
        for (var i = ms.options.length - 1; i >= 0; i--) {
            if (ms.options[i].textContent.indexOf('（自定义）') >= 0) ms.remove(i);
        }
    }
    function renderModelHint() {
        var h = $('dscModelHint');
        if (!h) return;
        var arr = getCustomModels();
        if (!arr.length) { h.textContent = ''; h.style.display = 'none'; return; }
        h.style.display = 'flex';
        h.innerHTML = '';
        var label = document.createElement('span');
        label.className = 'dsc-model-hint-label';
        label.textContent = '已添加 ' + arr.length + ' 个：';
        h.appendChild(label);
        for (var i = 0; i < arr.length; i++) {
            (function (name) {
                var chip = document.createElement('span');
                chip.className = 'dsc-model-chip';
                chip.appendChild(document.createTextNode(name));
                var x = document.createElement('b');
                x.textContent = '\u00d7';
                x.title = '删除 ' + name;
                x.onclick = function (ev) { if (ev) { ev.preventDefault(); ev.stopPropagation(); } removeCustomModel(name); };
                chip.appendChild(x);
                h.appendChild(chip);
            })(arr[i]);
        }
        var tip = document.createElement('span');
        tip.className = 'dsc-model-hint-label';
        tip.style.opacity = '0.6';
        tip.title = customModelsFromServer ? '数据目录：ddsh/data/displaymodels' : '后端未同步，当前仅本地缓存';
        tip.textContent = customModelsFromServer ? '（已存入 data/displaymodels/*.sts）' : '（本地缓存，后端未同步）';
        h.appendChild(tip);
    }
    function injectCustomModels() {
        var arr = getCustomModels();
        for (var i = 0; i < arr.length; i++) addModelOption(arr[i], true);
        renderModelHint();
    }
    function refreshCustomModelsUI() {
        clearCustomOptions();
        injectCustomModels();
    }
    // 从后端拉取权威清单（ddsh/data/displaymodels/*.sts）
    function loadCustomModelsFromServer() {
        return fetch('/api/displaymodels', { method: 'GET', cache: 'no-cache' })
            .then(function (r) { return r.json(); })
            .then(function (d) {
                if (!d || !d.success || !Array.isArray(d.models)) {
                    customModelsFromServer = false;
                    renderModelHint();
                    return getCustomModels();
                }
                var arr = [];
                for (var i = 0; i < d.models.length; i++) {
                    var m = d.models[i];
                    if (m && typeof m.id === 'string' && m.id.trim()) arr.push(m.id.trim());
                }
                setCustomModels(arr);
                customModelsFromServer = true;
                console.log('[DSC] 自定义模型已从后端同步: ' + arr.length + ' 个 @ ' + (d.dir || 'data/displaymodels'));
                refreshCustomModelsUI();
                return arr;
            })
            .catch(function (e) {
                customModelsFromServer = false;
                console.log('[DSC] 后端同步自定义模型失败，使用本地缓存:', e);
                renderModelHint();
                return getCustomModels();
            });
    }
    function removeCustomModel(name) {
        var arr = getCustomModels().filter(function (x) { return x !== name; });
        setCustomModels(arr);
        var ms = $('dscModelSelect');
        if (ms) {
            for (var i = ms.options.length - 1; i >= 0; i--) {
                if (ms.options[i].value === name && ms.options[i].textContent.indexOf('（自定义）') >= 0) ms.remove(i);
            }
        }
        renderModelHint();
        toast('已移除自定义模型: ' + name, 'success');
        fetch('/api/displaymodels?id=' + encodeURIComponent(name), { method: 'DELETE' })
            .then(function (r) { return r.json(); })
            .then(function (d) {
                if (d && d.success) console.log('[DSC] 已删除模型文件: ' + name);
                else toast('界面已移除，但删除 .sts 文件失败', 'error');
            })
            .catch(function (e) { console.log('[DSC] 删除模型文件失败:', e); });
    }
    function openModelAdd() {
        var row = $('dscModelAddRow'), inp = $('dscModelNewInput');
        if (!row) return;
        row.classList.add('open');
        if (inp) { inp.value = ''; inp.focus(); }
    }
    function closeModelAdd() {
        var row = $('dscModelAddRow');
        if (row) row.classList.remove('open');
    }
    function confirmModelAdd() {
        var inp = $('dscModelNewInput'), ms = $('dscModelSelect');
        if (!inp || !ms) return;
        var name = inp.value.trim();
        if (!name) { toast('请输入模型名称', 'error'); return; }
        if (name.length > 120) { toast('模型名过长（最多 120 字）', 'error'); return; }
        if (/\s/.test(name)) { toast('模型名不能包含空格', 'error'); return; }
        if (hasModelOption(name)) { ms.value = name; closeModelAdd(); toast('该模型已在列表中，已选中', 'success'); return; }
        // 先本地生效，UI 不阻塞
        var arr = getCustomModels();
        if (arr.indexOf(name) < 0) { arr.push(name); setCustomModels(arr); }
        addModelOption(name, true);
        ms.value = name;
        renderModelHint();
        closeModelAdd();
        // 再写入后端 .sts 文件（一个模型一个文件）
        fetch('/api/displaymodels', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ id: name })
        }).then(function (r) { return r.json(); })
          .then(function (d) {
              if (d && d.success) {
                  var f = (d.model && d.model.file) ? d.model.file : (name + '.sts');
                  customModelsFromServer = true;
                  renderModelHint();
                  toast('已保存 ' + name + ' → data/displaymodels/' + f, 'success');
              } else {
                  toast('已加入界面，但写入文件失败：' + ((d && d.error) || '未知错误'), 'error');
              }
          })
          .catch(function (e) {
              toast('已加入界面，但写入 .sts 失败（后端未编译？）', 'error');
              console.log('[DSC] 保存模型失败:', e);
          });
    }
    function bindModelAddUI() {
        var btn = $('dscModelAddBtn');
        if (btn) btn.onclick = function (ev) { if (ev) { ev.preventDefault(); ev.stopPropagation(); } openModelAdd(); };
        var okb = $('dscModelNewOk');
        if (okb) okb.onclick = function (ev) { if (ev) ev.preventDefault(); confirmModelAdd(); };
        var cb = $('dscModelNewCancel');
        if (cb) cb.onclick = function (ev) { if (ev) ev.preventDefault(); closeModelAdd(); };
        var inp = $('dscModelNewInput');
        if (inp) inp.onkeydown = function (ev) {
            if (ev.key === 'Enter') { ev.preventDefault(); confirmModelAdd(); }
            else if (ev.key === 'Escape') { ev.preventDefault(); closeModelAdd(); }
        };
    }

    function saveToolState() {
        try {
            localStorage.setItem('dsc_webSearch', state.webSearch ? '1' : '0');
            localStorage.setItem('dsc_deepThink', state.deepThink ? '1' : '0');
            localStorage.setItem('dsc_enableTools', state.enableTools ? '1' : '0');
            localStorage.setItem('dsc_currentModel', state.currentModel);
        } catch (e) {}
    }
    function updateSwitchBtn(btn, isOn) { if (btn) btn.classList.toggle('active', isOn); }
    function updateToolUI() {
        updateSwitchBtn($('dscWebSearchBtn'), state.webSearch);
        updateSwitchBtn($('dscDeepThinkBtn'), state.deepThink);
        updateSwitchBtn($('dscToolModeBtn'), state.enableTools);
    }

    function cleanTextForTTS(text) {
        if (!text) return '';
        text = text.replace(/```[\s\S]*?```/g, ' ');
        text = text.replace(/`[^`\n]*`/g, ' ');
        text = text.replace(/\[([^\]]+)\]\([^)]+\)/g, '$1');
        text = text.replace(/https?:\/\/[^\s<>"]+/g, ' ');
        text = text.replace(/^#{1,6}\s+/gm, '');
        text = text.replace(/[*_~]{1,3}/g, '');
        text = text.replace(/^>\s*/gm, '');
        text = text.replace(/^[\-\+]\s+/gm, '');
        text = text.replace(/^\d+\.\s+/gm, '');
        text = text.replace(/^[-*=]{3,}\s*$/gm, ' ');
        text = text.replace(/^\|.*\|$/gm, ' ');
        text = text.replace(/[\u3000-\u303F\u2018\u2019\u201C\u201D\u2014\u2013\u2026\u00B7]/g, ' ');
        text = text.replace(/[\uFF01-\uFF0F\uFF1A-\uFF20\uFF3B-\uFF40\uFF5B-\uFF65]/g, ' ');
        text = text.replace(/[!-\/:-@\[-`{-~]/g, ' ');
        return text.replace(/\s+/g, ' ').trim();
    }

    function splitTextIntoChunks(text, maxLen) {
        var chunks = [];
        var chars = Array.from(text);
        for (var i = 0; i < chars.length; i += maxLen) {
            chunks.push(chars.slice(i, i + maxLen).join(''));
        }
        return chunks;
    }

    async function playTTSChunks(text, btnElement, originalText) {
        var chunks = splitTextIntoChunks(text, TTS_CHUNK_SIZE);
        var total = chunks.length;
        if (total === 0) { toast('没有可朗读的内容', 'info'); return; }

        for (var i = 0; i < total; i++) {
            if (state.ttsCancelled) break;
            if (btnElement) {
                btnElement.textContent = total > 1 ? ('⏸ 播放中 ' + (i + 1) + '/' + total) : '⏸ 播放中';
            }
            var res = await fetch('/api/ds-chat/tts', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ text: chunks[i], voice: 'zh-CN-XiaoxiaoNeural' })
            });
            if (!res.ok) {
                var errData = await res.json().catch(function () { return {}; });
                throw new Error(errData.error || 'TTS 服务返回 ' + res.status);
            }
            var blob = await res.blob();
            var url = URL.createObjectURL(blob);
            if (state.ttsCancelled) { URL.revokeObjectURL(url); break; }
            await new Promise(function (resolve, reject) {
                var audio = new Audio(url);
                state.currentAudio = audio;
                audio.onended = function () { URL.revokeObjectURL(url); state.currentAudio = null; resolve(); };
                audio.onerror = function () { URL.revokeObjectURL(url); state.currentAudio = null; reject(new Error('音频播放失败')); };
                audio.play().catch(function (e) { URL.revokeObjectURL(url); state.currentAudio = null; reject(e); });
            });
        }
    }

    async function speakMessage(text, btnElement) {
        if (state.currentSpeakBtn === btnElement) {
            state.ttsCancelled = true;
            if (state.currentAudio) { try { state.currentAudio.pause(); } catch (e) {} state.currentAudio = null; }
            if (btnElement) { btnElement.textContent = '🔊 朗读'; btnElement.classList.remove('speaking'); }
            state.currentSpeakBtn = null;
            return;
        }
        if (state.currentSpeakBtn) {
            state.ttsCancelled = true;
            if (state.currentAudio) { try { state.currentAudio.pause(); } catch (e) {} state.currentAudio = null; }
            state.currentSpeakBtn.textContent = '🔊 朗读';
            state.currentSpeakBtn.classList.remove('speaking');
            state.currentSpeakBtn = null;
        }
        var cleanedText = cleanTextForTTS(text);
        if (!cleanedText) { toast('没有可朗读的内容', 'info'); return; }
        state.ttsCancelled = false;
        state.currentSpeakBtn = btnElement;
        var originalText = btnElement ? (btnElement.textContent || '🔊 朗读') : '🔊 朗读';
        if (btnElement) { btnElement.textContent = '⏳ 加载...'; btnElement.classList.add('speaking'); }
        try {
            await playTTSChunks(cleanedText, btnElement, originalText);
        } catch (err) {
            console.error('[DSC] TTS 失败:', err);
            toast('朗读失败: ' + err.message, 'error');
        } finally {
            if (btnElement) {
                btnElement.textContent = originalText;
                btnElement.classList.remove('speaking');
            }
            state.currentAudio = null;
            state.currentSpeakBtn = null;
            state.ttsCancelled = false;
        }
    }

    async function openApp() {
        var app = $('deepseekChatApp');
        if (!app) return;
        app.classList.add('open');
        document.body.style.overflow = 'hidden';
        updateAdvancedUI();
        updateLevelUI(state.reasoningLevel);
        updateLongTextUI();
        // ① 快照先上屏：同步渲染上一次的会话列表 + 最近一页消息（无需等网络）
        paintFromSnapshot();
        try {
            // ② 后台校真：先拉真实会话列表(后端已按 updatedAt 降序，最新在前)
            await loadSessions();
            // ③ 修复：打开时始终切换到"最新会话"，不再停留在旧/最早的当前会话
            if (state.sessions.length > 0) {
                state.currentSessionId = state.sessions[0].id;
                await loadMessages();
            } else {
                await createSession();
            }
            renderSessions();
            updateTitle();
            if (typeof window.dsLoadFiles === 'function') window.dsLoadFiles();
        } catch (e) { console.error('[DSC] openApp 出错:', e); }
        /* 不再自动聚焦，避免未点击就弹出输入法 */
    }

    function closeApp() {
        var app = $('deepseekChatApp');
        if (app) app.classList.remove('open');
        document.body.style.overflow = '';
        state.ttsCancelled = true;
        if (state.currentAudio) { try { state.currentAudio.pause(); } catch (e) {} state.currentAudio = null; }
        if (state.currentSpeakBtn) {
            state.currentSpeakBtn.textContent = '🔊 朗读';
            state.currentSpeakBtn.classList.remove('speaking');
            state.currentSpeakBtn = null;
        }
        closeSidebar();
        closeSettings();
        closePlusMenu();
        closeRenameDialog();
        closeLevelDialog();
        closeGlobalSearch();
        var novelOverlay = $('dscNovelOverlay');
        if (novelOverlay) novelOverlay.classList.remove('open');
        var fp = $('dscFilesPanel');
        if (fp) fp.classList.remove('open');
    }

    function bindMessagesScroll() {
        var wrap = $('dscMessages');
        if (!wrap) return;
        wrap.addEventListener('scroll', function () {
            if (state.scrollTick) return;
            state.scrollTick = true;
            requestAnimationFrame(function () {
                state.scrollTick = false;
                if (wrap.scrollTop < SCROLL_TOP_THRESHOLD && state.renderedStart > 0) {
                    loadOlderMessages();
                }
            });
        }, { passive: true });
    }

    function bindEvents() {
        function bind(id, event, fn) {
            var el = $(id);
            if (el) el.addEventListener(event, fn);
            else console.warn('[DSC] 未找到 #' + id);
        }

        ensureAdvancedBtn();
        ensureLongTextBtn();
        ensureNovelBtn();
        ensureToolModeBtn();

        // 顶栏「更多」菜单（集成次要功能按钮）
        var moreBtn = $('dscMoreBtn');
        var moreMenu = $('dscMoreMenu');
        if (moreBtn && moreMenu) {
            moreBtn.addEventListener('click', function (e) {
                e.stopPropagation();
                var open = moreMenu.classList.toggle('open');
                moreBtn.classList.toggle('more-active', open);
            });
            moreMenu.addEventListener('click', function (e) {
                if (e.target.closest('.dsc-more-item')) {
                    moreMenu.classList.remove('open');
                    moreBtn.classList.remove('more-active');
                }
            });
            document.addEventListener('click', function (e) {
                if (!moreMenu.classList.contains('open')) return;
                if (moreMenu.contains(e.target) || moreBtn.contains(e.target)) return;
                moreMenu.classList.remove('open');
                moreBtn.classList.remove('more-active');
            });
        }

        bind('dscAdvancedBtn', 'click', toggleAdvancedMode);

        var ltBtn = $('dscLongTextBtn');
        var ltDialogOpening = false;
        if (ltBtn) {
            ltBtn.addEventListener('click', function (e) {
                e.preventDefault(); e.stopPropagation();
                if (ltDialogOpening) return;
                ltDialogOpening = true;
                simpleConfirm('📚 长文模式已下线', '因服务商限制，长文模式已下线，感谢理解。您可以使用「📖 小说模式」生成约 3 万字的长篇内容。').then(function () {
                    ltDialogOpening = false;
                });
            });
        }

        bind('dscNovelModeBtn', 'click', function (e) {
            e.preventDefault(); e.stopPropagation(); openNovelDialog();
        });

        bind('dscToolModeBtn', 'click', function () {
            state.enableTools = !state.enableTools;
            updateToolUI();
            saveToolState();
            toast(state.enableTools ? '🤖 自主智能体已开启（最多 50 亿轮）' : '🤖 自主智能体已关闭', 'info');
        });

        bind('dscCloseBtn', 'click', closeApp);
        bind('dscNewBtn', 'click', createSession);
        bind('dscSettingsBtn', 'click', openSettings);
        bindCosplayEvents();

        bind('dscBackupBtn', 'click', function () {
            if (state.backupRunning) {
                toast('⏳ 备份正在进行，请稍候', 'info');
                return;
            }
            state.backupRunning = true;
            toast('📦 正在打包 data 与 imgs，请稍候…', 'info');
            var url = '/api/backup?type=data&_t=' + Date.now();
            var a = document.createElement('a');
            a.href = url;
            a.download = '';
            a.style.display = 'none';
            document.body.appendChild(a);
            a.click();
            setTimeout(function () {
                if (a.parentNode) { a.parentNode.removeChild(a); }
                state.backupRunning = false;
                toast('✅ 备份已发起，请查看下载目录', 'success');
            }, 1500);
        });
        bind('dscSidebarToggle', 'click', toggleSidebar);
        bind('dscSidebarOverlay', 'click', closeSidebar);

        bind('dscWebSearchBtn', 'click', function () {
            state.webSearch = !state.webSearch;
            updateToolUI();
            saveToolState();
            toast(state.webSearch ? '🌐 已开启联网搜索' : '🌐 已关闭联网搜索', 'info');
        });

        bind('dscDeepThinkBtn', 'click', function () {
            state.deepThink = !state.deepThink;
            if (!state.advancedMode) {
                state.reasoningLevel = state.deepThink ? (DEFAULT_LEVEL + 5) : DEFAULT_LEVEL;
                state.tempLevel = state.reasoningLevel;
                updateLevelUI(state.reasoningLevel);
            }
            updateToolUI();
            saveToolState();
            toast(state.deepThink ? '🧠 已开启深度思考' : '🧠 已关闭深度思考', 'info');
        });

        bind('dscLevelBtn', 'click', openLevelDialog);
        bind('dscLevelCancel', 'click', closeLevelDialog);
        bind('dscLevelSave', 'click', saveLevelDialog);
        var lvRange = $('dscLevelRange');
        if (lvRange) {
            lvRange.addEventListener('input', function (e) {
                state.tempLevel = parseInt(e.target.value, 10);
                updateLevelUI(state.tempLevel);
            });
        }
        var lvOverlay = $('dscLevelOverlay');
        if (lvOverlay) {
            lvOverlay.addEventListener('click', function (e) {
                if (e.target === lvOverlay) closeLevelDialog();
            });
        }

        bind('dscNewlineBtn', 'click', function () {
            var ta = $('dscInput');
            if (!ta) return;
            var start = ta.selectionStart, end = ta.selectionEnd, val = ta.value;
            ta.value = val.substring(0, start) + '\n' + val.substring(end);
            ta.selectionStart = ta.selectionEnd = start + 1;
            ta.focus(); autoResize();
        });

        bind('dscRenameCancel', 'click', closeRenameDialog);
        bind('dscRenameSave', 'click', saveRenameDialog);
        var ro = $('dscRenameOverlay');
        if (ro) ro.addEventListener('click', function (e) { if (e.target === ro) closeRenameDialog(); });
        var ri = $('dscRenameInput');
        if (ri) {
            ri.addEventListener('keydown', function (e) {
                if (e.key === 'Enter' && !e.isComposing) { e.preventDefault(); saveRenameDialog(); }
                else if (e.key === 'Escape') closeRenameDialog();
            });
        }

        bind('dscPlusBtn', 'click', function (e) { e.stopPropagation(); togglePlusMenu(); });
        var pm = $('dscPlusMenu');
        if (pm) {
            pm.addEventListener('click', function (e) {
                var item = e.target.closest('.dsc-menu-item');
                if (!item) return;
                e.stopPropagation();
                triggerFileInput(item.dataset.type);
            });
        }
        document.addEventListener('click', function (e) {
            var pm2 = $('dscPlusMenu'), pb = $('dscPlusBtn');
            if (!pm2 || !pm2.classList.contains('open')) return;
            if (pm2.contains(e.target) || (pb && pb.contains(e.target))) return;
            closePlusMenu();
        });

        var msgsWrap = $('dscMessages');
        if (msgsWrap) {
            msgsWrap.addEventListener('click', function (e) {
                var sentinel = e.target.closest('.dsc-load-more-sentinel');
                if (sentinel) { e.stopPropagation(); loadOlderMessages(); return; }

                var codeBtn = e.target.closest('.dsc-code-copy');
                if (codeBtn) {
                    e.stopPropagation();
                    var b64 = codeBtn.getAttribute('data-raw') || '';
                    var rawCode = b64 ? b64DecodeUnicode(b64) : '';
                    if (!rawCode) {
                        var block0 = codeBtn.closest('.dsc-code-block');
                        var codeEl0 = block0 ? block0.querySelector('code') : null;
                        rawCode = codeEl0 ? codeEl0.textContent : '';
                    }
                    copyToClipboard(rawCode);
                    var orig = codeBtn.textContent;
                    codeBtn.textContent = '✅ 已复制';
                    codeBtn.classList.add('copied');
                    setTimeout(function () { codeBtn.textContent = orig; codeBtn.classList.remove('copied'); }, 1600);
                    return;
                }
                var continueBtn = e.target.closest('.dsc-msg-continue-btn');
                if (continueBtn) {
                    e.stopPropagation();
                    var cIdx = parseInt(continueBtn.dataset.idx, 10);
                    if (!isNaN(cIdx)) continueGeneration(cIdx);
                    return;
                }
                var copyBtn = e.target.closest('.dsc-msg-copy-btn');
                if (copyBtn) {
                    e.stopPropagation();
                    var idx = parseInt(copyBtn.dataset.idx, 10);
                    var m = state.messages[idx];
                    if (m) {
                        copyToClipboard(m.content || '');
                        var orig2 = copyBtn.textContent;
                        copyBtn.textContent = '✅ 已复制';
                        copyBtn.classList.add('copied');
                        setTimeout(function () { copyBtn.textContent = orig2; copyBtn.classList.remove('copied'); }, 1600);
                    }
                    return;
                }
                var speakBtn = e.target.closest('.dsc-msg-speak-btn');
                if (speakBtn) {
                    e.stopPropagation();
                    var sIdx = parseInt(speakBtn.dataset.idx, 10);
                    var sMsg = state.messages[sIdx];
                    if (sMsg && sMsg.content) speakMessage(sMsg.content, speakBtn);
                    return;
                }
                var loadFull = e.target.closest('.dsc-think-load-full');
                if (loadFull) {
                    e.stopPropagation();
                    loadFullReasoning(loadFull);
                    return;
                }
                var header = e.target.closest('.dsc-think-header');
                if (header) {
                    var panel = header.closest('.dsc-think-panel');
                    if (panel) panel.classList.toggle('open');
                    return;
                }
            });
            bindMessagesScroll();
        }

        var sl = $('dscSessionList');
        if (sl) {
            sl.addEventListener('click', function (e) {
                var refBtn = e.target.closest('[data-ref]');
                var del = e.target.closest('[data-del]');
                var item = e.target.closest('.dsc-session-item');
                if (!item) return;
                var id = item.dataset.id;
                if (refBtn && !state.selectMode) { copySessionReference(id, refBtn, e); return; }
                if (del && !state.selectMode) deleteSession(id, e);
                else selectSession(id);
            });
            sl.addEventListener('dblclick', function (e) {
                if (state.selectMode) return;
                if (e.target.closest('[data-del]')) return;
                var item = e.target.closest('.dsc-session-item');
                if (!item) return;
                renameSession(item.dataset.id);
            });
            var pressTimer = null, pressStartY = 0, pressStartX = 0;
            sl.addEventListener('touchstart', function (e) {
                if (state.selectMode) return;
                if (e.target.closest('[data-del]')) return;
                var item = e.target.closest('.dsc-session-item');
                if (!item) return;
                pressStartY = e.touches[0].clientY;
                pressStartX = e.touches[0].clientX;
                pressTimer = setTimeout(function () {
                    pressTimer = null;
                    if (navigator.vibrate) { try { navigator.vibrate(20); } catch (er) {} }
                    renameSession(item.dataset.id);
                }, 600);
            }, { passive: true });
            sl.addEventListener('touchend', function () { if (pressTimer) { clearTimeout(pressTimer); pressTimer = null; } });
            sl.addEventListener('touchmove', function (e) {
                if (pressTimer) {
                    var dy = Math.abs(e.touches[0].clientY - pressStartY);
                    var dx = Math.abs(e.touches[0].clientX - pressStartX);
                    if (dy > 10 || dx > 10) { clearTimeout(pressTimer); pressTimer = null; }
                }
            });
        }

        bind('dscSelectModeBtn', 'click', function () {
            state.selectMode = !state.selectMode;
            if (!state.selectMode) state.checkedIds = {};
            renderSessions();
        });
        bind('dscBatchSelectAll', 'change', function (e) {
            var filtered = getFilteredSessions();
            if (e.target.checked) filtered.forEach(function (s) { state.checkedIds[s.id] = true; });
            else filtered.forEach(function (s) { delete state.checkedIds[s.id]; });
            renderSessions();
        });
        bind('dscBatchCancelBtn', 'click', function () {
            state.selectMode = false; state.checkedIds = {}; renderSessions();
        });
        bind('dscBatchDeleteBtn', 'click', batchDeleteSessions);
        bind('dscClearAllSessionsBtn', 'click', clearAllSessions);

        var ss = $('dscSessionSearch');
        if (ss) {
            ss.addEventListener('input', function () {
                state.searchQuery = ss.value.trim();
                var rc = $('dscRegexCheckbox');
                state.useRegex = rc ? rc.checked : false;
                var rt = $('dscRegexToggle');
                if (rt) rt.classList.toggle('active', state.useRegex);
                var sc = $('dscSessionSearchClear');
                if (sc) sc.classList.toggle('visible', state.searchQuery.length > 0);
                renderSessions();
            });
        }
        bind('dscSessionSearchClear', 'click', function () {
            var ss2 = $('dscSessionSearch');
            if (ss2) ss2.value = '';
            state.searchQuery = '';
            var sc = $('dscSessionSearchClear');
            if (sc) sc.classList.remove('visible');
            renderSessions();
        });
        var rc2 = $('dscRegexCheckbox');
        if (rc2) {
            rc2.addEventListener('change', function () {
                state.useRegex = rc2.checked;
                var rt = $('dscRegexToggle');
                if (rt) rt.classList.toggle('active', state.useRegex);
                renderSessions();
            });
        }

        bind('dscSendBtn', 'click', onSendBtnClick);
        var inputEl = $('dscInput');
        if (inputEl) {
            inputEl.addEventListener('input', autoResize);
            inputEl.addEventListener('focus', function () { inputEl.placeholder = '发消息'; });
            inputEl.addEventListener('blur', function () {
                if (inputEl.value.trim() === '') inputEl.placeholder = '发消息或按住说话';
            });
            inputEl.addEventListener('keydown', function (e) {
                if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) {
                    e.preventDefault();
                    if (state.isSending) return;   // 生成中回车不重复发送，终止请点按钮
                    sendMessage();
                }
            });
        }

        bind('dscSettingsClose', 'click', closeSettings);
        bind('dscSettingsCancel', 'click', closeSettings);
        bind('dscSettingsSave', 'click', saveSettings);
        var so = $('dscSettingsOverlay');
        if (so) so.addEventListener('click', function (e) { if (e.target === so) closeSettings(); });

        bind('dscConfirmOk', 'click', function () { if (state.confirmCb) state.confirmCb(true); });
        bind('dscConfirmCancel', 'click', function () { if (state.confirmCb) state.confirmCb(false); });
        var co = $('dscConfirmOverlay');
        if (co) co.addEventListener('click', function (e) {
            if (e.target === co && state.confirmCb) state.confirmCb(false);
        });

        document.addEventListener('keydown', function (e) {
            var app = $('deepseekChatApp');
            if (!app || !app.classList.contains('open')) return;
            if (e.key === 'Escape') {
                var novOverlay = $('dscNovelOverlay');
                if (novOverlay && novOverlay.classList.contains('open')) { novOverlay.classList.remove('open'); return; }
                var so2 = $('dscSettingsOverlay'), co2 = $('dscConfirmOverlay'),
                    ro2 = $('dscRenameOverlay'), lo2 = $('dscLevelOverlay'),
                    sb = $('dscSidebar'), pm2 = $('dscPlusMenu');
                if (so2 && so2.classList.contains('open')) closeSettings();
                else if (ro2 && ro2.classList.contains('open')) closeRenameDialog();
                else if (lo2 && lo2.classList.contains('open')) closeLevelDialog();
                else if (co2 && co2.classList.contains('open')) { if (state.confirmCb) state.confirmCb(false); }
                else if (pm2 && pm2.classList.contains('open')) closePlusMenu();
                else if (sb && sb.classList.contains('open')) closeSidebar();
            }
        });
    }
    
// ============================================================
// 全局会话全文搜索（内存缓存 + 游标分页 + 滚动加载）
// ============================================================

var searchState = {
    overlay: null,
    input: null,
    body: null,
    party: 'all',
    query: '',
    timer: null,
    offset: 0,
    limit: 50,
    total: 0,
    hasMore: false,
    loading: false,
    groupsOrder: [],
    groupsMap: {},   // sessionId -> { title, sessionId, hits, listEl }
};

function buildSearchOverlay() {
    if (searchState.overlay) return;
    var ov = document.createElement('div');
    ov.id = 'dscSearchOverlay';
    ov.className = 'dsc-search-overlay';
    ov.innerHTML =
        '<div class="dsc-search-card">' +
            '<div class="dsc-search-head">' +
                '<div class="dsc-search-input-wrap">' +
                    '<span class="dsc-search-icon">🔍</span>' +
                    '<input type="text" id="dscGlobalSearchInput" placeholder="搜索所有会话的消息内容…" autocomplete="off">' +
                    '<button class="dsc-search-clear" id="dscGlobalSearchClear" type="button">✕</button>' +
                '</div>' +
                '<button class="dsc-search-close" id="dscGlobalSearchClose" type="button" title="关闭">✕</button>' +
            '</div>' +
            '<div class="dsc-search-party">' +
                '<button class="dsc-search-party-btn active" data-party="all">全部</button>' +
                '<button class="dsc-search-party-btn" data-party="user">User</button>' +
                '<button class="dsc-search-party-btn" data-party="assistant">DeepSeek</button>' +
            '</div>' +
            '<div class="dsc-search-body" id="dscGlobalSearchBody">' +
                '<div class="dsc-search-hint">输入关键词，搜索你的所有历史会话</div>' +
            '</div>' +
        '</div>';
    document.body.appendChild(ov);
    searchState.overlay = ov;
    searchState.input = ov.querySelector('#dscGlobalSearchInput');
    searchState.body = ov.querySelector('#dscGlobalSearchBody');

    ov.addEventListener('click', function (e) {
        if (e.target === ov) closeGlobalSearch();
    });
    ov.querySelector('#dscGlobalSearchClose').addEventListener('click', closeGlobalSearch);

    ov.querySelector('#dscGlobalSearchClear').addEventListener('click', function () {
        searchState.input.value = '';
        searchState.query = '';
        resetSearchState();
        searchState.body.innerHTML = '<div class="dsc-search-hint">输入关键词，搜索你的所有历史会话</div>';
        searchState.input.focus();
    });

    ov.querySelectorAll('.dsc-search-party-btn').forEach(function (btn) {
        btn.addEventListener('click', function () {
            ov.querySelectorAll('.dsc-search-party-btn').forEach(function (b) { b.classList.remove('active'); });
            btn.classList.add('active');
            searchState.party = btn.dataset.party;
            if (searchState.query) {
                resetSearchState();
                doGlobalSearch(searchState.query, false);
            }
        });
    });

    searchState.input.addEventListener('input', function () {
        var v = searchState.input.value.trim();
        searchState.query = v;
        clearTimeout(searchState.timer);
        if (!v) {
            resetSearchState();
            searchState.body.innerHTML = '<div class="dsc-search-hint">输入关键词，搜索你的所有历史会话</div>';
            return;
        }
        searchState.timer = setTimeout(function () {
            resetSearchState();
            doGlobalSearch(v, false);
        }, 280);
    });

    searchState.input.addEventListener('keydown', function (e) {
        if (e.key === 'Escape') closeGlobalSearch();
    });

    // 滚动到底自动加载下一页
    searchState.body.addEventListener('scroll', function () {
        if (!searchState.hasMore || searchState.loading) return;
        var b = searchState.body;
        if (b.scrollTop + b.clientHeight >= b.scrollHeight - 80) {
            doGlobalSearch(searchState.query, true);
        }
    });
}

function resetSearchState() {
    searchState.offset = 0;
    searchState.total = 0;
    searchState.hasMore = false;
    searchState.loading = false;
    searchState.groupsOrder = [];
    searchState.groupsMap = {};
}

function ensureGlobalSearchBtn() {
    var btn = document.getElementById('dscGlobalSearchBtn');
    if (!btn) return;
    if (btn.__bound) return;
    btn.__bound = true;
    btn.addEventListener('click', openGlobalSearch);
}

function openGlobalSearch() {
    buildSearchOverlay();
    searchState.overlay.classList.add('open');
    setTimeout(function () { searchState.input.focus(); }, 80);
}

function closeGlobalSearch() {
    if (searchState.overlay) searchState.overlay.classList.remove('open');
}

async function doGlobalSearch(q, append) {
    if (searchState.loading) return;
    searchState.loading = true;

    if (!append) {
        searchState.body.innerHTML = '<div class="dsc-search-hint">搜索中…</div>';
    } else {
        var more = document.getElementById('dscSearchMore');
        if (more) more.textContent = '加载中…';
    }

    try {
        var url = '/api/ds-chat/search?q=' + encodeURIComponent(q) +
                  '&party=' + encodeURIComponent(searchState.party) +
                  '&offset=' + searchState.offset +
                  '&limit=' + searchState.limit;
        var res = await fetch(url, { cache: 'no-store' });
        var data = await res.json();
        if (!data.ok) throw new Error(data.error || '搜索失败');

        searchState.total = data.total || 0;
        searchState.hasMore = !!data.hasMore;
        searchState.offset += (data.hits || []).length;

        renderSearchHits(data, q, append);
    } catch (e) {
        if (!append) {
            searchState.body.innerHTML =
                '<div class="dsc-search-hint" style="color:#ef4444;">搜索失败：' +
                escapeHtml(e.message || String(e)) + '</div>';
        } else {
            var more = document.getElementById('dscSearchMore');
            if (more) more.textContent = '加载失败，滚动可重试';
        }
    } finally {
        searchState.loading = false;
    }
}

function renderSearchHits(data, q, append) {
    var hits = data.hits || [];

    if (!append) {
        searchState.groupsOrder = [];
        searchState.groupsMap = {};
        searchState.body.innerHTML = '';

        if (searchState.total === 0) {
            searchState.body.innerHTML = '<div class="dsc-search-hint">没有找到匹配的消息</div>';
            return;
        }

        var totalEl = document.createElement('div');
        totalEl.className = 'dsc-search-total';
        totalEl.textContent = '共 ' + searchState.total + ' 条命中' +
            (searchState.total > searchState.limit ? '（滚动加载更多）' : '');
        searchState.body.appendChild(totalEl);
    }

    hits.forEach(function (h) {
        var g = searchState.groupsMap[h.sessionId];
        if (!g) {
            var gEl = document.createElement('div');
            gEl.className = 'dsc-search-group';

            var titleEl = document.createElement('div');
            titleEl.className = 'dsc-search-group-title';
            titleEl.textContent = h.title || h.sessionId || '未命名会话';
            gEl.appendChild(titleEl);

            var listEl = document.createElement('div');
            listEl.className = 'dsc-search-group-list';
            gEl.appendChild(listEl);

            searchState.body.appendChild(gEl);

            g = {
                title: h.title,
                sessionId: h.sessionId,
                hits: [],
                listEl: listEl,
            };
            searchState.groupsMap[h.sessionId] = g;
            searchState.groupsOrder.push(h.sessionId);
        }

        g.hits.push(h);

        var hitEl = document.createElement('a');
        hitEl.className = 'dsc-search-hit';
        hitEl.href = '#';

        var roleLabel = h.role === 'user' ? 'User' : 'DeepSeek';
        var roleClass = h.role === 'user' ? 'user' : 'ds';
        var timeStr = formatSearchTime(h.time);

        var roleEl = document.createElement('span');
        roleEl.className = 'dsc-search-role ' + roleClass;
        roleEl.textContent = roleLabel;
        hitEl.appendChild(roleEl);

        if (timeStr) {
            var timeEl = document.createElement('span');
            timeEl.className = 'dsc-search-time';
            timeEl.textContent = timeStr;
            hitEl.appendChild(timeEl);
        }

        var snippetEl = document.createElement('div');
        snippetEl.className = 'dsc-search-snippet';
        snippetEl.innerHTML = highlightSnippet(h.snippet || '', q);
        hitEl.appendChild(snippetEl);

        (function (sessionId, messageId) {
            hitEl.addEventListener('click', function (e) {
                e.preventDefault();
                closeGlobalSearch();
                locateMessage(sessionId, messageId, q);
            });
        })(h.sessionId, h.messageId);

        g.listEl.appendChild(hitEl);
    });

    updateSearchMoreIndicator();
}

function updateSearchMoreIndicator() {
    var old = document.getElementById('dscSearchMore');
    if (old) old.remove();
    var oldEnd = document.getElementById('dscSearchEnd');
    if (oldEnd) oldEnd.remove();

    if (searchState.hasMore) {
        var more = document.createElement('div');
        more.id = 'dscSearchMore';
        more.className = 'dsc-search-more';
        more.textContent = searchState.loading ? '加载中…' : '滚动加载更多…';
        searchState.body.appendChild(more);
    } else if (searchState.total > 0) {
        var endEl = document.createElement('div');
        endEl.id = 'dscSearchEnd';
        endEl.className = 'dsc-search-end';
        endEl.textContent = '— 已经到底了 —';
        searchState.body.appendChild(endEl);
    }
}

function formatSearchTime(iso) {
    if (!iso) return '';
    try {
        var d = new Date(iso);
        if (isNaN(d.getTime())) return '';
        var pad = function (n) { return String(n).padStart(2, '0'); };
        return (d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' +
               pad(d.getHours()) + ':' + pad(d.getMinutes());
    } catch (e) { return ''; }
}

function highlightSnippet(snippet, q) {
    var escaped = escapeHtml(snippet);
    if (!q) return escaped;
    var escapedQ = escapeHtml(q);
    try {
        var re = new RegExp('(' + escapedQ.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + ')', 'gi');
        return escaped.replace(re, '<mark class="dsc-search-mark">$1</mark>');
    } catch (e) {
        return escaped;
    }
}

// 点击命中 → 打开会话 → 滚动到目标消息 → 高亮
async function locateMessage(sessionId, messageId, keyword) {
    try {
        if (state.currentSessionId !== sessionId) {
            await selectSession(sessionId);
        }

        var idx = -1;
        for (var i = 0; i < state.messages.length; i++) {
            if (state.messages[i].id === messageId) { idx = i; break; }
        }
        if (idx === -1) {
            showCenterError('无法在当前会话中找到这条消息');
            return;
        }

        if (idx < state.renderedStart) {
            state.renderedStart = Math.max(0, idx - 3);
            renderMessages();
        }

        await new Promise(function (r) {
            requestAnimationFrame(function () { requestAnimationFrame(r); });
        });

        var el = document.querySelector('.dsc-msg[data-idx="' + idx + '"]');
        if (!el) {
            showCenterError('定位失败：目标消息尚未渲染');
            return;
        }

        // 清除上一次高亮
        document.querySelectorAll('.dsc-msg-highlight').forEach(function (n) {
            n.classList.remove('dsc-msg-highlight');
        });
        document.querySelectorAll('.dsc-kw-mark').forEach(function (m) {
            var p = m.parentNode;
            if (p) {
                p.replaceChild(document.createTextNode(m.textContent || ''), m);
                p.normalize();
            }
        });

        el.scrollIntoView({ block: 'center', behavior: 'smooth' });
        el.classList.add('dsc-msg-highlight');
        setTimeout(function () { el.classList.remove('dsc-msg-highlight'); }, 3200);
        if (keyword) highlightInElement(el, keyword);
    } catch (e) {
        console.error('[DSC] locateMessage 失败:', e);
        showCenterError('定位异常：' + (e.message || e));
    }
}

function highlightInElement(root, keyword) {
    if (!keyword) return;
    var ql = keyword.toLowerCase();
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
    var targets = [];
    var node;
    while ((node = walker.nextNode())) {
        if (node.nodeValue && node.nodeValue.toLowerCase().indexOf(ql) !== -1) {
            targets.push(node);
        }
    }
    for (var i = 0; i < targets.length; i++) {
        var tn = targets[i];
        var text = tn.nodeValue;
        var lower = text.toLowerCase();
        var frag = document.createDocumentFragment();
        var cursor = 0;
        var p = lower.indexOf(ql);
        while (p >= 0) {
            if (p > cursor) frag.appendChild(document.createTextNode(text.slice(cursor, p)));
            var mark = document.createElement('span');
            mark.className = 'dsc-kw-mark';
            mark.textContent = text.slice(p, p + ql.length);
            frag.appendChild(mark);
            cursor = p + ql.length;
            p = lower.indexOf(ql, cursor);
        }
        if (cursor < text.length) frag.appendChild(document.createTextNode(text.slice(cursor)));
        if (tn.parentNode) tn.parentNode.replaceChild(frag, tn);
    }
}


    // ==================== 角色扮演（Cosplay）====================
    var cosplayState = { enabled: false, thinkingStyle: 'neutral', activeRole: '', roles: [] };
    var cosplayEditingId = '';

    function cosplayVal(id) {
        var el = $(id);
        return el && typeof el.value === 'string' ? el.value.trim() : '';
    }
    function cosplaySetVal(id, v) {
        var el = $(id);
        if (el) el.value = v == null ? '' : String(v);
    }

    function cosplayApplyState(st) {
        if (!st) return;
        cosplayState = {
            enabled: !!st.enabled,
            thinkingStyle: st.thinkingStyle === 'role' ? 'role' : 'neutral',
            activeRole: st.activeRole || '',
            roles: Array.isArray(st.roles) ? st.roles : []
        };
        var en = $('dscCosplayEnabled');
        if (en) en.checked = cosplayState.enabled;
        var sty = $('dscCosplayStyle');
        if (sty) sty.value = cosplayState.thinkingStyle;
        renderCosplayList();
        updateCosplayStatus();
    }

    function cosplayFindRole(id) {
        for (var i = 0; i < cosplayState.roles.length; i++) {
            if (cosplayState.roles[i].id === id) return cosplayState.roles[i];
        }
        return null;
    }

    function updateCosplayStatus() {
        var el = $('dscCosplayStatus');
        if (!el) return;
        var role = cosplayFindRole(cosplayState.activeRole);
        if (!role) {
            el.textContent = '未选择角色';
            el.className = 'dsc-cosplay-status';
            return;
        }
        el.textContent = (cosplayState.enabled ? '✅ 正在扮演：' : '⏸ 已暂停（未启用）：') +
            (role.emoji || '🎭') + ' ' + role.name;
        el.className = 'dsc-cosplay-status' + (cosplayState.enabled ? ' on' : '');
    }

    function renderCosplayList() {
        var box = $('dscCosplayList');
        if (!box) return;
        box.innerHTML = '';
        if (!cosplayState.roles.length) {
            var empty = document.createElement('div');
            empty.className = 'dsc-cosplay-empty';
            empty.textContent = '角色库是空的，点「＋ 新建角色」创建一个吧';
            box.appendChild(empty);
            return;
        }
        cosplayState.roles.forEach(function (r) {
            var row = document.createElement('div');
            row.className = 'dsc-cosplay-role' + (r.id === cosplayState.activeRole ? ' active' : '');

            var main = document.createElement('div');
            main.className = 'dsc-cosplay-role-main';
            var nameEl = document.createElement('div');
            nameEl.className = 'dsc-cosplay-role-name';
            nameEl.textContent = (r.emoji || '🎭') + ' ' + r.name;
            if (r.id === cosplayState.activeRole) {
                var badge = document.createElement('span');
                badge.className = 'dsc-cosplay-badge';
                badge.textContent = '当前';
                nameEl.appendChild(badge);
            }
            var descEl = document.createElement('div');
            descEl.className = 'dsc-cosplay-role-desc';
            var desc = r.description || r.personality || '';
            descEl.textContent = desc.length > 90 ? desc.slice(0, 90) + '…' : desc;
            main.appendChild(nameEl);
            main.appendChild(descEl);

            var acts = document.createElement('div');
            acts.className = 'dsc-cosplay-role-actions';

            var bUse = document.createElement('button');
            bUse.className = 'dsc-btn ghost dsc-cosplay-mini';
            bUse.textContent = r.id === cosplayState.activeRole ? '✓ 已选' : '选择';
            bUse.disabled = (r.id === cosplayState.activeRole);
            bUse.onclick = function () { cosplaySetActive(r.id); };

            var bEdit = document.createElement('button');
            bEdit.className = 'dsc-btn ghost dsc-cosplay-mini';
            bEdit.textContent = '编辑';
            bEdit.onclick = function () { cosplayOpenEditor(r.id); };

            var bDel = document.createElement('button');
            bDel.className = 'dsc-btn ghost dsc-cosplay-mini danger';
            bDel.textContent = '删除';
            bDel.onclick = function () { cosplayRemove(r.id, r.name); };

            acts.appendChild(bUse);
            acts.appendChild(bEdit);
            acts.appendChild(bDel);
            row.appendChild(main);
            row.appendChild(acts);
            box.appendChild(row);
        });
    }

    async function cosplayRequest(action, extra) {
        var payload = { action: action };
        if (extra) {
            for (var k in extra) {
                if (Object.prototype.hasOwnProperty.call(extra, k)) payload[k] = extra[k];
            }
        }
        var res = await fetch('/api/ds-cosplay', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });
        var data = {};
        try { data = await res.json(); } catch (e) { data = {}; }
        if (!res.ok) throw new Error(data.error || ('请求失败 ' + res.status));
        if (data.state) cosplayApplyState(data.state);
        return data;
    }

    async function openCosplayDialog() {
        var overlay = $('dscCosplayOverlay');
        if (!overlay) { toast('角色扮演面板未加载', 'error'); return; }
        closeCosplayEditor();
        overlay.classList.add('open');
        var st = $('dscCosplayStatus');
        if (st) { st.textContent = '加载中…'; st.className = 'dsc-cosplay-status'; }
        try {
            var res = await fetch('/api/ds-cosplay?_t=' + Date.now());
            var data = await res.json();
            if (!res.ok) throw new Error(data.error || ('HTTP ' + res.status));
            cosplayApplyState(data.state);
        } catch (e) {
            if (st) {
                st.textContent = '⚠️ 读取角色库失败：' + e.message;
                st.className = 'dsc-cosplay-status err';
            }
            toast('读取角色库失败：' + e.message, 'error');
        }
    }

    function closeCosplayDialog() {
        var o = $('dscCosplayOverlay');
        if (o) o.classList.remove('open');
        closeCosplayEditor();
    }

    function cosplayOpenEditor(id) {
        var r = id ? cosplayFindRole(id) : null;
        cosplayEditingId = id || '';
        cosplaySetVal('dscCosplayName', r ? r.name : '');
        cosplaySetVal('dscCosplayEmoji', r ? (r.emoji || '') : '');
        cosplaySetVal('dscCosplayDesc', r ? (r.description || '') : '');
        cosplaySetVal('dscCosplayPersonality', r ? (r.personality || '') : '');
        cosplaySetVal('dscCosplayStyleText', r ? (r.style || '') : '');
        cosplaySetVal('dscCosplayRules', r ? (r.rules || '') : '');
        cosplaySetVal('dscCosplayScenario', r ? (r.scenario || '') : '');
        cosplaySetVal('dscCosplayFirstMes', r ? (r.first_mes || '') : '');
        var ed = $('dscCosplayEditor');
        if (ed) ed.classList.add('open');
        var nm = $('dscCosplayName');
        if (nm) { try { nm.focus(); } catch (e) {} }
    }

    function closeCosplayEditor() {
        var ed = $('dscCosplayEditor');
        if (ed) ed.classList.remove('open');
        cosplayEditingId = '';
    }

    async function cosplaySetActive(id) {
        try {
            await cosplayRequest('setActiveRole', { id: id });
            var r = cosplayFindRole(id);
            toast('🎭 已选择角色：' + (r ? r.name : id), 'success');
        } catch (e) {
            toast('切换角色失败：' + e.message, 'error');
        }
    }

    async function cosplayToggleEnabled(on) {
        try {
            await cosplayRequest('setEnabled', { enabled: !!on });
            toast(on ? '🎭 角色扮演已开启' : '⏸ 角色扮演已关闭', on ? 'success' : 'info');
        } catch (e) {
            toast('切换失败：' + e.message, 'error');
            var en = $('dscCosplayEnabled');
            if (en) en.checked = !on;
        }
    }

    async function cosplaySetStyle(style) {
        try {
            await cosplayRequest('setThinkingStyle', { style: style === 'role' ? 'role' : 'neutral' });
            toast(style === 'role' ? '🎭 思考风格：角色沉浸' : '🧠 思考风格：中性', 'info');
        } catch (e) {
            toast('保存思考风格失败：' + e.message, 'error');
        }
    }

    async function cosplaySaveRole() {
        var name = cosplayVal('dscCosplayName');
        if (!name) { toast('请先填写角色名', 'error'); return; }
        var card = {
            name: name,
            emoji: cosplayVal('dscCosplayEmoji'),
            description: cosplayVal('dscCosplayDesc'),
            personality: cosplayVal('dscCosplayPersonality'),
            style: cosplayVal('dscCosplayStyleText'),
            rules: cosplayVal('dscCosplayRules'),
            scenario: cosplayVal('dscCosplayScenario'),
            first_mes: cosplayVal('dscCosplayFirstMes')
        };
        if (cosplayEditingId) card.id = cosplayEditingId;
        try {
            await cosplayRequest('upsertRole', { card: card });
            toast('✅ 角色已保存', 'success');
            closeCosplayEditor();
        } catch (e) {
            toast('保存角色失败：' + e.message, 'error');
        }
    }

    async function cosplayRemove(id, name) {
        var ok = await simpleConfirm('删除角色', '确定删除「' + (name || id) + '」吗？此操作不可恢复。');
        if (!ok) return;
        try {
            await cosplayRequest('removeRole', { id: id });
            toast('🗑 角色已删除', 'success');
        } catch (e) {
            toast('删除失败：' + e.message, 'error');
        }
    }

    function bindCosplayEvents() {
        function on(id, ev, fn) {
            var el = $(id);
            if (el) el.addEventListener(ev, fn);
            else console.warn('[DSC] 未找到 #' + id);
        }
        on('dscCosplayBtn', 'click', function (e) {
            e.preventDefault();
            e.stopPropagation();
            openCosplayDialog();
        });
        on('dscCosplayDone', 'click', closeCosplayDialog);
        on('dscCosplayAddBtn', 'click', function () { cosplayOpenEditor(''); });
        on('dscCosplayEditCancel', 'click', closeCosplayEditor);
        on('dscCosplaySaveRole', 'click', cosplaySaveRole);
        var en = $('dscCosplayEnabled');
        if (en) {
            en.addEventListener('change', function () { cosplayToggleEnabled(en.checked); });
        }
        var sty = $('dscCosplayStyle');
        if (sty) {
            sty.addEventListener('change', function () { cosplaySetStyle(sty.value); });
        }
        var overlay = $('dscCosplayOverlay');
        if (overlay) {
            overlay.addEventListener('click', function (e) {
                if (e.target === overlay) closeCosplayDialog();
            });
        }
    }
    // ==================== 角色扮演（Cosplay）结束 ====================

    function init() {
        var app = $('deepseekChatApp');
        if (!app) { console.error('[DSC] 找不到容器'); return; }
        try {
            loadMathJax();
            ensureAdvancedBtn();
            ensureCallBtn();
            ensureLongTextBtn();
            ensureNovelBtn();
            ensureToolModeBtn();
            ensureGlobalSearchBtn();
            bindEvents();
            loadToolState();
            bindModelAddUI();
            injectCustomModels(); // 先用本地缓存即时注入（避免闪烁）
            loadCustomModelsFromServer().then(function () {
                // 后端 data/displaymodels/*.sts 是权威来源，回来后刷新下拉与提示
                syncModelFromConfig();
            });
            window.openDeepSeekChat = openApp;
            window.closeDeepSeekChat = closeApp;
            // 空闲预热：提前打热服务端会话缓存与浏览器缓存，点开时首包更小更快
            var warm = function () {
                try { fetch('/api/ds-chat/sessions', { cache: 'no-cache' }).catch(function () {}); } catch (e) {}
            };
            if (window.requestIdleCallback) { requestIdleCallback(warm, { timeout: 2000 }); }
            else { setTimeout(warm, 800); }
            console.log('[DSC] ✅ v8 初始化完成（快照秒开 / 极速打字 / 弹窗可视化 / 5万轮工具模式）');
        } catch (e) { console.error('[DSC] 初始化失败:', e); }
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();