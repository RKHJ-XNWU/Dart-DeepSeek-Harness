/* ============================================================
 * dsc-duplex.js —— 豆包端到端实时语音（Seeduplex）全双工通话前端
 * ------------------------------------------------------------
 * 链路：
 *   麦克风 → WebAudio 采集 → 降采样到 16k → 20ms 一帧 PCM16
 *        → base64 → WebSocket（本地服务代理）→ 火山引擎
 *   火山引擎 → response.output_audio.delta（PCM16 24k）
 *        → AudioBuffer 队列播放；同时把字幕推到通话面板
 *
 * 关键约束（来自官方文档）：
 *   · 输入采样率只支持 16000，输出只支持 24000
 *   · 每帧建议 20ms（16k / int16 → 640 字节）
 *   · 关麦后必须发 input_audio_mute.commit，否则服务端超时无响应
 *   · 打断用 response.cancel
 *   · model 固定 1.2.6.1（由后端补齐，前端不必传）
 *
 * 本文件不伪造任何成功：连不上、鉴权失败、服务端报错都会原样显示。
 * ============================================================ */
(function () {
    'use strict';

    var CFG_API = '/api/doubao/config';
    var WS_PATH = '/api/doubao/realtime';

    var IN_RATE = 16000;
    var OUT_RATE = 24000;
    var FRAME = 320;          // 16000 * 0.02 = 320 samples = 640 bytes
    var MAX_BUFFERED = 512 * 1024;

    var D = {
        ws: null,
        active: false,
        connecting: false,
        micOn: true,
        stream: null,
        ctx: null,
        src: null,
        proc: null,
        inRate: 48000,
        pend: [],
        playCtx: null,
        nextTime: 0,
        sources: [],
        lang: 'zh',
        voice: '',
        instructions: '',
        sending: 0,
        reopened: 0
    };

    function $(id) { return document.getElementById(id); }

    function T(s) {
        try {
            if (!(window.I18N && window.I18N.t)) return s;
            var args = [s].concat(Array.prototype.slice.call(arguments, 1));
            return window.I18N.t.apply(null, args);
        } catch (e) { return s; }
    }

    function el(tag, cls, text) {
        var n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text !== undefined && text !== null) n.textContent = text;
        return n;
    }

    function toast(msg, type) {
        try {
            if (typeof window.dscToast === 'function') { window.dscToast(msg, type); return; }
        } catch (e) {}
        var wrap = $('dscToastWrap');
        if (!wrap) { console.log('[DUPLEX]', msg); return; }
        var t = el('div', 'dsc-toast ' + (type || ''), msg);
        wrap.appendChild(t);
        setTimeout(function () { if (t.parentNode) t.parentNode.removeChild(t); }, 4000);
    }

    function uiStatus(text, cls) {
        var n = $('dscDbCallStatus');
        if (n) n.textContent = text;
        var orb = $('dscDbCallOrb');
        if (orb) orb.className = 'dsc-db-call-orb' + (cls ? ' ' + cls : '');
    }

    function uiBubble(kind, text) {
        var log = $('dscDbCallLog');
        if (!log) return;
        var b = el('div', 'dsc-db-bubble ' + kind, text);
        log.appendChild(b);
        log.scrollTop = log.scrollHeight;
    }

    function newId() {
        return 'ev_' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
    }

    // ------------------------------------------------------------
    // 编解码
    // ------------------------------------------------------------
    function b64FromBytes(bytes) {
        var bin = '';
        for (var i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
        return btoa(bin);
    }

    function bytesFromB64(b64) {
        var bin = atob(b64);
        var out = new Uint8Array(bin.length);
        for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
        return out;
    }

    /// 线性插值降采样
    function downsample(buf, inRate, outRate) {
        if (outRate >= inRate) return buf;
        var ratio = inRate / outRate;
        var outLen = Math.round(buf.length / ratio);
        var out = new Float32Array(outLen);
        for (var i = 0; i < outLen; i++) {
            var pos = i * ratio;
            var i0 = Math.floor(pos);
            var i1 = Math.min(i0 + 1, buf.length - 1);
            var f = pos - i0;
            out[i] = buf[i0] * (1 - f) + buf[i1] * f;
        }
        return out;
    }

    // ------------------------------------------------------------
    // 发送
    // ------------------------------------------------------------
    function send(obj) {
        if (!D.ws || D.ws.readyState !== 1) return false;
        try {
            D.ws.send(JSON.stringify(obj));
            return true;
        } catch (e) {
            return false;
        }
    }

    function sendPcm(f32) {
        if (!D.ws || D.ws.readyState !== 1) return;
        // 上行拥塞时丢弃本帧，避免内存堆积导致越来越延迟
        if (D.ws.bufferedAmount > MAX_BUFFERED) return;
        var i16 = new Int16Array(f32.length);
        for (var i = 0; i < f32.length; i++) {
            var v = Math.max(-1, Math.min(1, f32[i]));
            i16[i] = v < 0 ? v * 0x8000 : v * 0x7fff;
        }
        var bytes = new Uint8Array(i16.buffer);
        D.sending++;
        send({
            type: 'input_audio_buffer.append',
            event_id: newId(),
            audio: b64FromBytes(bytes)
        });
    }

    // ------------------------------------------------------------
    // 采集
    // ------------------------------------------------------------
    function onAudioProcess(ev) {
        if (!D.active || !D.micOn) return;
        var input = ev.inputBuffer.getChannelData(0);
        var f32 = downsample(input, D.inRate, IN_RATE);
        for (var i = 0; i < f32.length; i++) D.pend.push(f32[i]);
        while (D.pend.length >= FRAME) {
            var chunk = D.pend.slice(0, FRAME);
            D.pend = D.pend.slice(FRAME);
            sendPcm(chunk);
        }
    }

    // ------------------------------------------------------------
    // 播放
    // ------------------------------------------------------------
    function playPcm(b64) {
        var ctx = D.playCtx;
        if (!ctx) return;
        var u8 = bytesFromB64(b64);
        if (u8.length < 2) return;
        var n = u8.length >> 1;
        var buf = ctx.createBuffer(1, n, OUT_RATE);
        var ch = buf.getChannelData(0);
        for (var i = 0; i < n; i++) {
            var v = (u8[2 * i] | (u8[2 * i + 1] << 8));
            if (v >= 0x8000) v -= 0x10000;
            ch[i] = v / 32768;
        }
        var src = ctx.createBufferSource();
        src.buffer = buf;
        src.connect(ctx.destination);
        var t = Math.max(ctx.currentTime + 0.03, D.nextTime || 0);
        try { src.start(t); } catch (e) { return; }
        D.nextTime = t + buf.duration;
        D.sources.push(src);
        src.onended = function () {
            var k = D.sources.indexOf(src);
            if (k >= 0) D.sources.splice(k, 1);
        };
    }

    function stopPlayback() {
        for (var i = 0; i < D.sources.length; i++) {
            try { D.sources[i].stop(); } catch (e) {}
        }
        D.sources = [];
        D.nextTime = 0;
    }

    // ------------------------------------------------------------
    // 下行事件
    // ------------------------------------------------------------
    function onMessage(ev) {
        var m;
        try { m = JSON.parse(ev.data); } catch (e) { return; }
        var t = m.type || '';

        if (t === 'session.created') {
            uiStatus(T('接続済み（全双工）'), 'listening');
            return;
        }
        if (t === 'session.closed') {
            uiStatus(T('セッション終了'), '');
            return;
        }
        if (t === 'conversation.item.input_audio_transcription.started') {
            uiStatus(T('聞き取り中…'), 'listening');
            return;
        }
        if (t === 'conversation.item.input_audio_transcription.delta') {
            var dt = m.delta || m.text || '';
            if (dt) uiStatus(T('聞き取り中…') + ' ' + dt, 'listening');
            return;
        }
        if (t === 'conversation.item.input_audio_transcription.completed') {
            var ut = m.transcript || m.text || '';
            if (ut) uiBubble('user', ut);
            return;
        }
        if (t === 'conversation.item.input_audio_transcription.failed') {
            uiBubble('sys', T('音声認識に失敗しました'));
            return;
        }
        if (t === 'response.output_text.delta') {
            var dl = m.delta || '';
            if (dl) {
                if (!D.curText) D.curText = '';
                D.curText += dl;
                uiStatus(T('応答中…'), 'thinking');
            }
            return;
        }
        if (t === 'response.output_text.done') {
            var tx = m.text || D.curText || '';
            D.curText = '';
            if (tx) uiBubble('ai', tx);
            return;
        }
        if (t === 'response.output_audio.started') {
            uiStatus(T('読み上げ中…'), 'speaking');
            return;
        }
        if (t === 'response.output_audio.delta') {
            if (m.audio) playPcm(m.audio);
            return;
        }
        if (t === 'response.output_audio.done') {
            uiStatus(T('聞き取り中…'), 'listening');
            return;
        }
        if (t === 'response.done') {
            uiStatus(T('聞き取り中…'), 'listening');
            return;
        }
        if (t === 'response.function_call_arguments.done') {
            uiBubble('sys', T('モデルがツール呼び出しを要求しました（未実装のため実行しません）'));
            return;
        }
        if (t === 'error') {
            var msg = m.message || (m.error && (m.error.message || m.error)) || T('不明なエラー');
            var code = m.code || '';
            if (code === 'upstream_connect_failed') {
                uiBubble('sys', T('接続に失敗しました：{0}', msg));
                uiStatus(T('接続失敗'), '');
            } else {
                uiBubble('sys', T('豆包エラー：{0}', msg));
            }
            return;
        }
    }

    // ------------------------------------------------------------
    // 启动 / 停止
    // ------------------------------------------------------------
    async function start() {
        if (D.active) return;
        if (D.connecting) return;
        D.connecting = true;
        D.curText = '';
        uiStatus(T('接続しています…'), 'thinking');

        try {
            var cfg = await fetch(CFG_API, { cache: 'no-store' }).then(function (r) { return r.json(); });
            // Seeduplex 认的是豆包语音控制台的 Key（或旧版 AppId+Token），
            // 方舟的 Key 通常会 401，因此这里不能只看 hasKey。
            var hasVoiceKey = !!(cfg && (cfg.hasDuplexKey || cfg.hasS2s));
            if (!cfg || !hasVoiceKey) {
                uiBubble('sys', T('⚠️ 音声サービス用の Key が未設定です（設定で豆包音声 API Key を入力してください）'));
                uiStatus(T('未設定'), '');
                D.connecting = false;
                return;
            }
            D.lang = cfg.duplexLang || 'zh';
            D.voice = cfg.duplexVoice || '';
            D.instructions = cfg.duplexInstructions || '';
        } catch (e) {
            uiBubble('sys', T('設定の読み込みに失敗しました：{0}', e.message || e));
            D.connecting = false;
            return;
        }

        // ---- 音频采集 ----
        try {
            D.stream = await navigator.mediaDevices.getUserMedia({
                audio: {
                    echoCancellation: true,
                    noiseSuppression: true,
                    autoGainControl: true,
                    channelCount: 1
                }
            });
        } catch (e) {
            uiBubble('sys', T('マイクを使用できません：{0}', e.message || e));
            uiStatus(T('マイク使用不可'), '');
            D.connecting = false;
            return;
        }

        try {
            var AC = window.AudioContext || window.webkitAudioContext;
            D.ctx = new AC();
            D.inRate = D.ctx.sampleRate || 48000;
            D.src = D.ctx.createMediaStreamSource(D.stream);
            D.proc = D.ctx.createScriptProcessor(4096, 1, 1);
            D.proc.onaudioprocess = onAudioProcess;
            D.src.connect(D.proc);
            D.proc.connect(D.ctx.destination);
            D.playCtx = new AC();
            D.nextTime = 0;
            D.sources = [];
        } catch (e) {
            uiBubble('sys', T('音声処理の初期化に失敗しました：{0}', e.message || e));
            cleanup();
            D.connecting = false;
            return;
        }

        // ---- WebSocket ----
        var proto = (location.protocol === 'https:') ? 'wss:' : 'ws:';
        var q = [];
        if (D.lang) q.push('lang=' + encodeURIComponent(D.lang));
        if (D.voice) q.push('voice=' + encodeURIComponent(D.voice));
        if (D.instructions) q.push('instructions=' + encodeURIComponent(D.instructions));
        var url = proto + '//' + location.host + WS_PATH + (q.length ? ('?' + q.join('&')) : '');

        var ws;
        try {
            ws = new WebSocket(url);
        } catch (e) {
            uiBubble('sys', T('WebSocket を作成できません：{0}', e.message || e));
            cleanup();
            D.connecting = false;
            return;
        }
        D.ws = ws;
        ws.binaryType = 'arraybuffer';

        ws.onopen = function () {
            D.active = true;
            D.connecting = false;
            uiStatus(T('接続済み（全双工）'), 'listening');
            uiBubble('sys', T('全双工通話を開始しました。話しかけてください。'));

            // 必ず session.create を送る（model / 采样率 / 音色はバックエンドが補完）
            send({
                type: 'session.create',
                session: {
                    model: '1.2.6.1',
                    audio: {
                        input: { format: { type: 'pcm', rate: IN_RATE } },
                        output: {
                            format: { type: 'pcm_s16le', rate: OUT_RATE },
                            voice: D.voice || undefined
                        }
                    },
                    instructions: D.instructions || undefined
                }
            });
        };

        ws.onmessage = onMessage;

        ws.onerror = function () {
            uiBubble('sys', T('接続でエラーが発生しました（Key やネットワークを確認してください）'));
            uiStatus(T('接続エラー'), '');
        };

        ws.onclose = function (ev) {
            var wasActive = D.active;
            D.active = false;
            D.connecting = false;
            D.ws = null;
            if (wasActive) {
                uiStatus(T('通話を終了しました'), '');
                if (ev && ev.code && ev.code !== 1000) {
                    uiBubble('sys', T('接続が切断されました（code={0}）', ev.code));
                }
            }
        };
    }

    function cleanup() {
        try { if (D.proc) { D.proc.onaudioprocess = null; D.proc.disconnect(); } } catch (e) {}
        D.proc = null;
        try { if (D.src) D.src.disconnect(); } catch (e) {}
        D.src = null;
        try { if (D.ctx && D.ctx.close) D.ctx.close(); } catch (e) {}
        D.ctx = null;
        try { if (D.playCtx && D.playCtx.close) D.playCtx.close(); } catch (e) {}
        D.playCtx = null;
        try { if (D.stream) D.stream.getTracks().forEach(function (t) { t.stop(); }); } catch (e) {}
        D.stream = null;
        D.pend = [];
        stopPlayback();
    }

    function stop() {
        if (D.ws) {
            try { send({ type: 'session.close' }); } catch (e) {}
            try { D.ws.close(1000, 'client close'); } catch (e) {}
        }
        D.ws = null;
        D.active = false;
        D.connecting = false;
        cleanup();
        uiStatus(T('待機中'), '');
    }

    function setMic(on) {
        D.micOn = !!on;
        // 文档要求：关麦后必须显式发送静音事件，否则服务端会超时
        send({ type: on ? 'input_audio_unmute.commit' : 'input_audio_mute.commit', event_id: newId() });
        try {
            if (D.stream) D.stream.getAudioTracks().forEach(function (t) { t.enabled = D.micOn; });
        } catch (e) {}
        uiStatus(D.micOn ? T('聞き取り中…') : T('ミュート中'), D.micOn ? 'listening' : '');
        return D.micOn;
    }

    function cancel() {
        stopPlayback();
        send({ type: 'response.cancel', event_id: newId() });
        uiStatus(T('聞き取り中…'), 'listening');
    }

    function sendText(text) {
        var v = String(text || '').trim();
        if (!v) return false;
        stopPlayback();
        send({
            type: 'speech_text_buffer.commit',
            event_id: newId(),
            text: v
        });
        uiBubble('user', v);
        return true;
    }

    window.dscDuplex = {
        start: start,
        stop: stop,
        cancel: cancel,
        setMic: setMic,
        sendText: sendText,
        isActive: function () { return !!D.active; },
        isConnecting: function () { return !!D.connecting; }
    };

    // ============================================================
    // RTC AI 音视频互动（StartVoiceChat / StopVoiceChat）
    // ------------------------------------------------------------
    // 本模块只做「服务端任务编排」：把 Seeduplex 端到端模型挂到 RTC 房间。
    // 浏览器侧要真正收发音视频，必须用火山引擎官方 RTC Web SDK 加入同一房间，
    // 该 SDK 未随本项目分发——所以这里绝不会假装「已经能通话」。
    // 鉴权用 AccessKey/SecretKey 在 Dart 侧做 V4 签名，前端永远拿不到密钥。
    // ============================================================
    var R = {
        taskId: '',
        roomId: '',
        appId: '',
        busy: false,
        onLog: null,
        onStatus: null
    };

    function rlog(msg, kind) {
        // 回调签名是 addBubble(kind, text)，这里必须按 (kind, text) 传，
        // 否则消息与类名会互换（气泡里只剩 'sys'）。
        if (typeof R.onLog === 'function') {
            try { R.onLog(kind || 'sys', msg); } catch (e) {}
        }
    }

    function rstatus(text, cls) {
        if (typeof R.onStatus === 'function') {
            try { R.onStatus(text, cls || ''); } catch (e) {}
        }
    }

    function bind(logFn, statusFn) {
        R.onLog = (typeof logFn === 'function') ? logFn : null;
        R.onStatus = (typeof statusFn === 'function') ? statusFn : null;
    }

    async function probe() {
        try {
            var r = await fetch('/api/doubao/realtime/status', { cache: 'no-store' });
            var d = await r.json();
            return d || {};
        } catch (e) {
            return { ok: false, error: (e && e.message) || String(e) };
        }
    }

    async function startRtc(opts) {
        opts = opts || {};
        if (R.busy) return { ok: false, error: 'busy' };
        R.busy = true;
        rstatus(T('RTC タスクを起動しています…'), 'thinking');
        var body = {
            roomId: String(opts.roomId || '').trim(),
            userId: String(opts.userId || 'dsc_user').trim(),
            botUserId: String(opts.botUserId || 'dsc_bot').trim(),
            mixedMode: !!opts.mixedMode,
            lang: String(opts.lang || 'zh'),
            voice: String(opts.voice || '').trim(),
            instructions: String(opts.instructions || '').trim(),
            taskId: String(opts.taskId || '').trim(),
            llmModel: String(opts.llmModel || '').trim()
        };
        try {
            var r = await fetch('/api/doubao/rtc/start', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(body)
            });
            var d = null;
            try { d = await r.json(); } catch (e2) { d = null; }
            if (d && d.success) {
                R.taskId = d.taskId || body.taskId || '';
                R.roomId = body.roomId;
                R.appId = d.appId || '';
                rlog(T('✅ RTC タスクを起動しました（TaskId: {0}）', R.taskId), 'ai');
                if (d.requestId) rlog('RequestId: ' + d.requestId, 'sys');
                rstatus(T('RTC 起動済み'), 'listening');
                return { ok: true, taskId: R.taskId, requestId: d.requestId || '' };
            }
            var em = (d && (d.error || d.message)) || T('不明なエラー');
            rlog(T('❌ RTC 起動失敗：{0}', T(String(em))), 'sys');
            rstatus(T('RTC 起動失敗'), '');
            return { ok: false, error: em, raw: d };
        } catch (e) {
            var m2 = (e && e.message) || String(e);
            rlog(T('❌ RTC 起動失敗：{0}', m2), 'sys');
            rstatus(T('RTC 起動失敗'), '');
            return { ok: false, error: m2 };
        } finally {
            R.busy = false;
        }
    }

    async function stopRtc() {
        var taskId = R.taskId;
        if (!taskId) {
            rlog(T('停止する RTC タスクがありません'), 'sys');
            rstatus(T('RTC タスクは起動していません'), '');
            return { ok: false, error: 'no task' };
        }
        try {
            var r = await fetch('/api/doubao/rtc/stop', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ taskId: taskId, roomId: R.roomId })
            });
            var d = null;
            try { d = await r.json(); } catch (e2) { d = null; }
            if (d && d.success) {
                rlog(T('✅ RTC タスクを停止しました'), 'ai');
                rstatus(T('待機中'), '');
                R.taskId = '';
                return { ok: true };
            }
            var em = (d && (d.error || d.message)) || T('不明なエラー');
            rlog(T('❌ RTC 停止失敗：{0}', T(String(em))), 'sys');
            return { ok: false, error: em };
        } catch (e) {
            var m3 = (e && e.message) || String(e);
            rlog(T('❌ RTC 停止失敗：{0}', m3), 'sys');
            return { ok: false, error: m3 };
        }
    }

    window.dscRtc = {
        bind: bind,
        probe: probe,
        start: startRtc,
        stop: stopRtc,
        taskId: function () { return R.taskId; },
        isBusy: function () { return !!R.busy; }
    };
})();
