/* ============================================================
 * dsc-doubao.js —— 豆包（火山方舟）前端
 *   1) 「⋯」メニューに 4 つの機能を追加
 *      豆包で画像生成 / 豆包で動画生成 / 豆包ポッドキャスト / 豆包音声通話
 *   2) 設定ダイアログに豆包専用カード（API Key・モデル・音色・自動ルーティング）
 *   3) 生成物はすべて ds_files/blob に保存され、そのまま再生・DL できる
 *   4) 失敗は必ずそのまま表示する（成功の捏造はしない）
 *
 * バックエンド: /api/doubao/*
 *   config / models / image / video / video/status / video/tasks /
 *   tts / podcast / asr / voice/turn / chat / analyze-audio
 * ============================================================ */
(function () {
    'use strict';

    var API = '/api/doubao';
    var S = {
        cfg: null,
        catalog: [],
        styles: [],
        imgBusy: false,
        vidBusy: false,
        podBusy: false,
        ttsBusy: false,
        pollTimer: null,
        call: null,
        asrBusy: false,
        editBusy: false
    };

    var RATIOS = ['16:9', '3:4', '4:3', '19:6', '21:9', '1:1', '9:16'];
    var IMG_STYLES_JA = ['アニメ', '二次元', '日本アニメ風', 'ピクセル', 'シネマティック', '特撮風', '中国アニメ風', '田野風'];

    function $(id) { return document.getElementById(id); }

    function T(s) {
        try {
            if (!(window.I18N && window.I18N.t)) return s;
            var args = [s].concat(Array.prototype.slice.call(arguments, 1));
            return window.I18N.t.apply(null, args);
        } catch (e) { return s; }
    }

    function lang() {
        try { return (window.I18N && window.I18N.getLang()) || 'ja'; } catch (e) { return 'ja'; }
    }

    function el(tag, cls, text) {
        var n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text !== undefined && text !== null) n.textContent = text;
        return n;
    }

    function toast(msg, type) {
        var wrap = $('dscToastWrap');
        if (!wrap) { console.log('[DB]', msg); return; }
        var t = el('div', 'dsc-toast ' + (type || ''), msg);
        wrap.appendChild(t);
        setTimeout(function () { if (t.parentNode) t.parentNode.removeChild(t); }, 3600);
    }

    function setStatus(node, msg, kind) {
        if (!node) return;
        node.textContent = msg || '';
        node.className = 'dsc-db-status' + (kind ? ' ' + kind : '');
    }

    function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

    async function api(path, opts) {
        var o = opts || {};
        var res = await fetch(API + path, {
            method: o.method || 'GET',
            headers: o.body ? Object.assign({ 'Content-Type': 'application/json' }, o.headers || {}) : (o.headers || {}),
            body: o.body ? JSON.stringify(o.body) : undefined,
            cache: 'no-store'
        });
        var data = {};
        try { data = await res.json(); } catch (e) { data = {}; }
        if (!res.ok) {
            throw new Error((data && (data.error || data.message)) || ('HTTP ' + res.status));
        }
        return data;
    }

    function fileUrl(file) {
        if (!file) return '';
        return '/api/ds-files/download?id=' + encodeURIComponent(file.id);
    }

    function downloadUrl(file) {
        return fileUrl(file) + '&download=1';
    }

    function openExternal(url) {
        try { window.open(url, '_blank'); } catch (e) { location.href = url; }
    }

    function refreshFiles() {
        try { if (typeof window.dsLoadFiles === 'function') window.dsLoadFiles(); } catch (e) {}
    }

    // ------------------------------------------------------------
    // 設定 / モデル
    // ------------------------------------------------------------
    function modelsByCat(cat) {
        return (S.catalog || []).filter(function (m) { return !cat || m.category === cat; });
    }

    // 模型能力标签：模型名保持语言无关（拉丁字母/数字），
    // 能力说明由后端 audioInput / videoInput 布尔字段驱动并走字典本地化，
    // 这样新增模型不会再出现「日语残留」或半日半中混排。
    function capSuffix(m) {
        if (!m) return '';
        var a = !!m.audioInput;
        var v = !!m.videoInput;
        var txt = '';
        if (a && v) txt = T('（音声理解・動画理解）');
        else if (v) txt = T('（動画理解）');
        else if (a) txt = T('（音声理解）');
        if (!txt) return '';
        // 中日文用全角括号，前面不再补空格；其他语言补一个空格更易读
        var lg = lang();
        return (lg === 'zh' || lg === 'ja') ? txt : ' ' + txt;
    }

    function fillSelect(sel, items, selected) {
        if (!sel) return;
        sel.innerHTML = '';
        items.forEach(function (m) {
            var o = document.createElement('option');
            o.value = m.value;
            o.textContent = T(m.label) + capSuffix(m) + ' · ' + m.value;
            if (selected && selected === m.value) o.selected = true;
            sel.appendChild(o);
        });
        if (selected) {
            var has = items.some(function (m) { return m.value === selected; });
            if (!has) {
                var o2 = document.createElement('option');
                o2.value = selected;
                o2.textContent = selected;
                sel.appendChild(o2);
                sel.value = selected;
            }
        }
    }

    async function loadConfig(force) {
        if (S.cfg && !force) return S.cfg;
        var d = await api('/config');
        S.cfg = d;
        S.catalog = (d.catalog && d.catalog.models) || [];
        S.styles = (d.catalog && d.catalog.styles) || IMG_STYLES_JA;
        return d;
    }

    // 通常チャットのモデル選択は DeepSeek 専用（豆包モデルはここに出さない）。
    // 旧版が注入した豆包モデル群が残っていれば必ず撤去する。
    var DB_CHAT_VALUES = [
        'doubao-seed-2-0-mini-260428', 'doubao-seed-evolving-latest-version',
        'doubao-seed-2-1-pro-260628', 'doubao-seed-2-1-turbo-260628',
        'doubao-seed-2-0-lite-260428', 'glm-5-2-260617'
    ];

    function isDbModelValue(v) {
        v = String(v || '').trim();
        if (!v) return false;
        if (DB_CHAT_VALUES.indexOf(v) >= 0) return true;
        if (S.catalog && S.catalog.some(function (m) { return m.value === v && m.category === 'chat'; })) return true;
        if (S.cfg && (S.cfg.customModels || []).indexOf(v) >= 0) return true;
        return /^(doubao-seed|doubao-1|doubao-pro|doubao-lite|glm-)/.test(v);
    }

    function purgeLegacyChatModels() {
        var sel = $('dscModelSelect');
        if (!sel) return;
        var g = $('dscDbModelGroup');
        if (g && g.parentNode) g.parentNode.removeChild(g);
        // 旧版が動的に追加した豆包モデルの option も 1 件ずつ撤去する
        for (var i = sel.options.length - 1; i >= 0; i--) {
            var v = sel.options[i].value;
            if (!isDbModelValue(v)) continue;
            var wasSelected = (sel.value === v);
            sel.remove(i);
            if (wasSelected) sel.value = 'deepseek-flash';
        }
        // 旧版で豆包モデルが選ばれたまま残っている場合は DeepSeek 既定値へ戻す
        if (isDbModelValue(sel.value)) {
            sel.value = 'deepseek-flash';
            try { localStorage.setItem('dsc_currentModel', 'deepseek-flash'); } catch (e) {}
        }
    }

    // ------------------------------------------------------------
    // 「⋯」メニューへのボタン追加
    // ------------------------------------------------------------
    // メニュー項目は「日本語キー＋実行関数」で保持し、言語切替時はラベルだけ貼り替える。
    // 再読込なしで言語を変えても、以前の言語の文言が残らないようにするため。
    var MENU_ITEMS = [
        { id: 'dscDbTtsBtn', ic: '🔊', label: '豆包で音声生成', tip: '豆包音声生成', open: function () { openTtsModal(); } },
        { id: 'dscDbImageBtn', ic: '🎨', label: '豆包で画像生成', tip: '豆包画像生成', open: function () { openImageModal(); } },
        { id: 'dscDbVideoBtn', ic: '🎬', label: '豆包で動画生成', tip: '豆包動画生成', open: function () { openVideoModal(); } },
        { id: 'dscDbPodcastBtn', ic: '🎧', label: '豆包ポッドキャスト', tip: '豆包ポッドキャスト', open: function () { openPodcastModal(); } },
        { id: 'dscDbCallBtn', ic: '📞', label: '豆包音声通話', tip: '豆包音声通話', open: function () { openCallModal(); } },
        { id: 'dscDbAsrBtn', ic: '🎤', label: '録音ファイルを豆包で認識', tip: '豆包録音ファイル認識', open: function () { openAsrModal(); } },
        { id: 'dscDbEditBtn', ic: '🖌️', label: '豆包P图', tip: '豆包P图', open: function () { openEditModal(); } }
    ];

    function applyMenuLabels() {
        MENU_ITEMS.forEach(function (it) {
            var b = $(it.id);
            if (!b) return;
            b.title = T(it.tip);
            var tx = b.querySelector('.tx');
            if (tx) tx.textContent = T(it.label);
        });
    }

    function injectMenu() {
        var menu = $('dscMoreMenu');
        if (!menu) return;
        var first = menu.firstChild;
        // 既存ボタンは飛ばし、欠けている項目だけを個別に補う
        // （旧版が 1 度でも描画したページでも、新規項目が必ず出るようにする）
        MENU_ITEMS.forEach(function (it) {
            if ($(it.id)) return;
            var b = el('button', 'dsc-more-item');
            b.id = it.id;
            b.title = T(it.tip);
            b.appendChild(el('span', 'ic', it.ic));
            b.appendChild(el('span', 'tx', T(it.label)));
            b.addEventListener('click', function () { closeMoreMenu(); it.open(); });
            menu.insertBefore(b, first);
        });
        applyMenuLabels();
    }

    function closeMoreMenu() {
        var m = $('dscMoreMenu');
        var b = $('dscMoreBtn');
        if (m) m.classList.remove('open');
        if (b) b.classList.remove('more-active');
    }

    // ------------------------------------------------------------
    // モーダル基盤
    // ------------------------------------------------------------
    function buildModal(id, icon, title, sub) {
        var ov = el('div', 'dsc-db-overlay');
        ov.id = id;
        ov.setAttribute('data-lang', lang());   // 言語切替後の作り直し判定に使う
        var md = el('div', 'dsc-db-modal');
        var head = el('div', 'dsc-db-modal-head');
        head.appendChild(el('div', 'dsc-db-modal-ic', icon));
        head.appendChild(el('div', 'dsc-db-modal-title', T(title)));
        var close = el('button', 'dsc-db-close', '×');
        close.type = 'button';
        close.title = T('閉じる');
        head.appendChild(close);
        md.appendChild(head);
        if (sub) md.appendChild(el('div', 'dsc-db-modal-sub', T(sub)));
        ov.appendChild(md);
        document.body.appendChild(ov);
        close.addEventListener('click', function () { closeModal(id); });
        ov.addEventListener('click', function (e) { if (e.target === ov) closeModal(id); });
        return md;
    }

    // 言語切替後に開き直したとき、以前の言語で組んだ DOM が残っていれば作り直す。
    // busy が true の間（生成・通話中）は状態を壊さないため何もしない。
    function ensureModal(id, builder, busy) {
        var old = $(id);
        if (old && old.getAttribute('data-lang') === lang()) return;
        if (old) {
            if (busy) return;
            if (old.parentNode) old.parentNode.removeChild(old);
        }
        builder();
        var made = $(id);
        if (made) made.setAttribute('data-lang', lang());
    }

    function openModal(id) {
        var ov = $(id);
        if (!ov) return;
        ov.classList.add('open');
    }

    function closeModal(id) {
        var ov = $(id);
        if (ov) ov.classList.remove('open');
        if (id === 'dscDbCallOverlay') stopCall();
        if (id === 'dscDbVideoOverlay' && S.pollTimer) {
            clearTimeout(S.pollTimer);
            S.pollTimer = null;
        }
    }

    function field(labelText, inputEl, hint) {
        var f = el('div', 'dsc-db-field');
        if (labelText) {
            var lb = document.createElement('label');
            lb.textContent = T(labelText);
            f.appendChild(lb);
        }
        if (inputEl) f.appendChild(inputEl);
        if (hint) f.appendChild(el('div', 'dsc-db-hint', T(hint)));
        return f;
    }

    function input(id, type, placeholder, value) {
        var i = document.createElement('input');
        i.id = id;
        i.type = type || 'text';
        i.placeholder = placeholder ? T(placeholder) : '';
        i.value = value === undefined || value === null ? '' : value;
        i.autocomplete = 'off';
        return i;
    }

    function textarea(id, placeholder, value) {
        var t = document.createElement('textarea');
        t.id = id;
        t.placeholder = placeholder ? T(placeholder) : '';
        t.value = value || '';
        return t;
    }

    function select(id, options, selected) {
        var s = document.createElement('select');
        s.id = id;
        options.forEach(function (o) {
            var op = document.createElement('option');
            if (typeof o === 'string') { op.value = o; op.textContent = o; }
            else { op.value = o.value; op.textContent = T(o.label) + capSuffix(o); }
            if (selected && selected === op.value) op.selected = true;
            s.appendChild(op);
        });
        return s;
    }

    function switchRow(id, title, desc, checked) {
        var row = el('label', 'dsc-toggle-row');
        var tx = el('div', 'dsc-toggle-tx');
        tx.appendChild(el('div', 'dsc-toggle-title', T(title)));
        if (desc) tx.appendChild(el('div', 'dsc-toggle-desc', T(desc)));
        row.appendChild(tx);
        var sw = el('span', 'dsc-switch');
        var box = document.createElement('input');
        box.type = 'checkbox';
        box.id = id;
        box.checked = !!checked;
        sw.appendChild(box);
        sw.appendChild(el('span', 'dsc-switch-track'));
        row.appendChild(sw);
        return row;
    }

    // ------------------------------------------------------------
    // 設定カード（DeepSeek 設定ダイアログ内）
    // ------------------------------------------------------------
    function buildSettingsCard() {
        var host = document.querySelector('#dscSettingsOverlay .dsc-modal');
        if (!host) return;
        var exist = $('dscDbCard');
        if (exist) {
            // 自癒：過去に modal 直下へ挿入されたカードをスクロール領域へ戻す
            var body0 = host.querySelector('.dsc-settings-body');
            if (body0 && exist.parentNode !== body0) body0.appendChild(exist);
            return;
        }
        var body = host.querySelector('.dsc-settings-body') || host;
        var footer = host.querySelector('.dsc-modal-footer');

        var card = el('div', 'dsc-db-card');
        card.id = 'dscDbCard';

        var head = el('div', 'dsc-db-head');
        head.appendChild(el('div', 'dsc-settings-sec-title', T('豆包（火山方舟）設定')));
        head.appendChild(el('span', 'dsc-db-badge', 'Doubao'));
        card.appendChild(head);
        card.appendChild(el('div', 'dsc-db-sub',
            T('豆包の API Key は DeepSeek の Key とは別に保存します。現状は平文保存です（.sts）。')));

        var keyInput = input('dscDbApiKey', 'password', 'ARK API Key を入力');
        card.appendChild(field('豆包 API Key', keyInput, '保存済みの場合、空欄なら変更しません'));
        card.appendChild(field('ベース URL', input('dscDbBaseUrl', 'text', DB_BASE_PH(), ''), '既定：https://ark.cn-beijing.volces.com/api/v3'));

        var grid = el('div', 'dsc-db-grid');
        grid.appendChild(field('対話モデル', select('dscDbChatModel', modelsByCat('chat'))));
        card.appendChild(el('div', 'dsc-db-sub',
            T('音声理解に対応：doubao-seed-2-0-mini / doubao-seed-2-0-lite。動画理解に対応：上記 2 モデルに加え doubao-seed-2-1-turbo / doubao-seed-2-1-pro / doubao-seed-evolving。2.1 系は動画理解のみで音声理解には非対応です。')));
        grid.appendChild(field('画像モデル', select('dscDbImageModel', modelsByCat('image'))));
        grid.appendChild(field('動画モデル', select('dscDbVideoModel', modelsByCat('video'))));
        grid.appendChild(field('音声合成モデル', select('dscDbTtsModel', modelsByCat('tts'))));
        grid.appendChild(field('ポッドキャストモデル', select('dscDbPodcastModel', modelsByCat('podcast'))));
        grid.appendChild(field('音声認識モデル', select('dscDbAsrModel', modelsByCat('asr'))));
        grid.appendChild(field('リアルタイム音声モデル', select('dscDbRealtimeModel', modelsByCat('realtime'))));
        grid.appendChild(field('TTS リソース ID（任意）', input('dscDbTtsRes', 'text', '例：seed-tts-2.0', '')));
        card.appendChild(grid);

        var grid2 = el('div', 'dsc-db-grid');
        grid2.appendChild(field('音色 A（話者 1）', input('dscDbVoiceA', 'text', 'zh_female_xiaohe_uranus_bigtts', '')));
        grid2.appendChild(field('音色 B（話者 2）', input('dscDbVoiceB', 'text', 'zh_male_qingshuangnanda_mars_bigtts', '')));
        card.appendChild(grid2);

        // ---- 端到端实时语音（Seeduplex）----
        card.appendChild(el('div', 'dsc-settings-sec-title', T('エンドツーエンドリアルタイム音声（Seeduplex）')));
        card.appendChild(el('div', 'dsc-db-sub',
            T('全双工のリアルタイム通話。ブラウザは独自ヘッダーを付けられないため、ローカルサービスが X-Api-Key を付けて wss へプロキシします。')));
        var grid3 = el('div', 'dsc-db-grid');
        grid3.appendChild(field('全双工の音色（任意）',
            input('dscDbDuplexVoice', 'text', '空欄なら音色 A を使用', '')));
        grid3.appendChild(field('全双工の言語',
            select('dscDbDuplexLang', [
                { value: 'zh', label: '中文' }, { value: 'ja', label: '日本語' },
                { value: 'en', label: 'English' }, { value: 'ko', label: '한국어' },
                { value: 'ru', label: 'Русский' }, { value: 'fr', label: 'Français' }
            ])));
        card.appendChild(grid3);
        card.appendChild(field('全双工の人設プロンプト（任意）',
            input('dscDbDuplexInstr', 'text', '空欄なら既定の短文プロンプト', '')));
        card.appendChild(field('豆包音声 API Key（Seeduplex 用）',
            input('dscDbDuplexKey', 'password', '変更しない場合は空欄'),
            '方舟の API Key では 401 になります。豆包音声コンソールの API Key を入力してください。'));

        // ---- RTC AI 音视频互动 ----
        card.appendChild(el('div', 'dsc-settings-sec-title', T('RTC AI 音声・映像インタラクション')));
        card.appendChild(el('div', 'dsc-db-sub',
            T('RTC 側はサーバー API（StartVoiceChat）でタスクを作成します。ブラウザで実際に音声・映像を送受信するには、公式 RTC Web SDK の導入が別途必要です。')));
        var grid4 = el('div', 'dsc-db-grid');
        grid4.appendChild(field('RTC AppId', input('dscDbRtcAppId', 'text', 'RTC アプリの AppId', '')));
        grid4.appendChild(field('RoomId', input('dscDbRtcRoomId', 'text', '既定のルーム ID', '')));
        card.appendChild(grid4);
        var grid5 = el('div', 'dsc-db-grid');
        grid5.appendChild(field('AccessKey', input('dscDbRtcAk', 'password', '変更しない場合は空欄')));
        grid5.appendChild(field('SecretKey', input('dscDbRtcSk', 'password', '変更しない場合は空欄')));
        card.appendChild(grid5);
        var grid6 = el('div', 'dsc-db-grid');
        grid6.appendChild(field('S2S AppId', input('dscDbS2sAppId', 'text', 'エンドツーエンド音声サービスの AppId', '')));
        grid6.appendChild(field('S2S Token', input('dscDbS2sToken', 'password', '変更しない場合は空欄')));
        card.appendChild(grid6);

        card.appendChild(switchRow('dscDbFastMode', '高速モード（深い思考をオフ）',
            '豆包の言語モデルで深い思考を無効化し、最初の一文字が届くまでの待ち時間を大幅に短縮します（実測 16.8 秒 → 0.9 秒）', true));
        card.appendChild(switchRow('dscDbAutoRoute', '録音ファイルを豆包へ自動ルーティング',
            '豆包以外のモデルを選んでいても、録音を送ると豆包で認識・分析します', true));
        card.appendChild(switchRow('dscDbWatermark', '生成物に透かしを入れる',
            '画像・動画の「AI 生成」透かし（既定はオフ）', false));

        var row = el('div', 'dsc-db-row');
        var save = el('button', 'dsc-db-btn primary', T('豆包設定を保存'));
        save.type = 'button';
        save.id = 'dscDbSaveCfg';
        var clear = el('button', 'dsc-db-btn danger', T('Key を消去'));
        clear.type = 'button';
        clear.id = 'dscDbClearKey';
        row.appendChild(save);
        row.appendChild(clear);
        card.appendChild(row);

        var st = el('div', 'dsc-db-status');
        st.id = 'dscDbCfgStatus';
        card.appendChild(st);

        card.appendChild(el('div', 'dsc-settings-sec-title', T('豆包モデル一覧（17 種）')));
        var list = el('div', 'dsc-db-models');
        list.id = 'dscDbModelList';
        card.appendChild(list);

        var addRow = el('div', 'dsc-db-row');
        addRow.style.marginTop = '8px';
        var addInput = input('dscDbCustomModel', 'text', 'カスタムモデル値（例：doubao-seed-2-2-pro）');
        var addBtn = el('button', 'dsc-db-btn', T('追加'));
        addBtn.type = 'button';
        addBtn.id = 'dscDbAddModel';
        addRow.appendChild(addInput);
        addRow.appendChild(addBtn);
        card.appendChild(addRow);

        // 重要：豆包カードは必ずスクロール領域（.dsc-settings-body）の末尾へ入れる。
        // modal 直下（footer の直前）へ挿入すると flex レイアウトで本文領域が潰れ、
        // DeepSeek の接続情報（API Key 入力欄）が見えなくなる。
        if (body && body !== host) {
            body.appendChild(card);
        } else if (footer && footer.parentNode === host) {
            host.insertBefore(card, footer);
        } else {
            host.appendChild(card);
        }

        save.addEventListener('click', saveCfg);
        clear.addEventListener('click', clearKey);
        addBtn.addEventListener('click', addCustomModel);
    }

    function DB_BASE_PH() { return 'https://ark.cn-beijing.volces.com/api/v3'; }

    function renderModelList() {
        var list = $('dscDbModelList');
        if (!list) return;
        list.innerHTML = '';
        (S.catalog || []).forEach(function (m) {
            var r = el('div', 'dsc-db-model-row');
            r.appendChild(el('span', 'dsc-db-model-name', T(m.label)));
            r.appendChild(el('span', 'dsc-db-model-val', m.value));
            list.appendChild(r);
        });
    }

    function fillCfgForm() {
        var c = S.cfg;
        if (!c) return;
        // モデル選択はカタログ到着後に populate する（空の select を残さない）
        var catMap = {
            dscDbChatModel: ['chat', 'chatModel'],
            dscDbImageModel: ['image', 'imageModel'],
            dscDbVideoModel: ['video', 'videoModel'],
            dscDbTtsModel: ['tts', 'ttsModel'],
            dscDbPodcastModel: ['podcast', 'podcastModel'],
            dscDbAsrModel: ['asr', 'asrModel'],
            dscDbRealtimeModel: ['realtime', 'realtimeModel']
        };
        Object.keys(catMap).forEach(function (id) {
            var sel = $(id);
            if (!sel) return;
            var cat = catMap[id][0];
            var key = catMap[id][1];
            var items = modelsByCat(cat);
            if (items.length === 0) return;
            fillSelect(sel, items, c[key]);
        });
        var map = {
            dscDbBaseUrl: c.baseUrl,
            dscDbChatModel: c.chatModel,
            dscDbImageModel: c.imageModel,
            dscDbVideoModel: c.videoModel,
            dscDbTtsModel: c.ttsModel,
            dscDbPodcastModel: c.podcastModel,
            dscDbAsrModel: c.asrModel,
            dscDbRealtimeModel: c.realtimeModel,
            dscDbTtsRes: c.ttsResourceId,
            dscDbVoiceA: c.voice,
            dscDbVoiceB: c.voiceB,
            dscDbDuplexVoice: c.duplexVoice,
            dscDbDuplexInstr: c.duplexInstructions,
            dscDbDuplexLang: (c.duplexLang || 'zh'),
            dscDbRtcAppId: c.rtcAppId,
            dscDbRtcRoomId: c.rtcRoomId,
            dscDbS2sAppId: c.s2sAppId
        };
        Object.keys(map).forEach(function (id) {
            var n = $(id);
            if (n) n.value = map[id] || '';
        });
        var k = $('dscDbApiKey');
        if (k) {
            k.value = '';
            k.placeholder = c.hasKey ? T('保存済み（{0}）。空欄なら変更しません', c.maskedKey) : T('ARK API Key を入力');
        }
        var fm = $('dscDbFastMode');
        if (fm) fm.checked = (c.fastMode !== false);
        var ar = $('dscDbAutoRoute');
        if (ar) ar.checked = !!c.autoRouteAudio;
        var wm = $('dscDbWatermark');
        if (wm) wm.checked = !!c.watermark;
        renderModelList();
        var st = $('dscDbCfgStatus');
        if (st) {
            setStatus(st, c.hasKey
                ? T('✅ 豆包 Key 設定済み · 対話モデル：{0}', c.chatModel)
                : T('⚠️ 豆包 Key 未設定'), c.hasKey ? 'ok' : 'err');
        }
    }

    async function saveCfg() {
        var st = $('dscDbCfgStatus');
        var btn = $('dscDbSaveCfg');
        var body = {
            apiKey: ($('dscDbApiKey') || {}).value || '',
            baseUrl: ($('dscDbBaseUrl') || {}).value || '',
            chatModel: ($('dscDbChatModel') || {}).value || '',
            imageModel: ($('dscDbImageModel') || {}).value || '',
            videoModel: ($('dscDbVideoModel') || {}).value || '',
            ttsModel: ($('dscDbTtsModel') || {}).value || '',
            podcastModel: ($('dscDbPodcastModel') || {}).value || '',
            asrModel: ($('dscDbAsrModel') || {}).value || '',
            realtimeModel: ($('dscDbRealtimeModel') || {}).value || '',
            ttsResourceId: ($('dscDbTtsRes') || {}).value || '',
            voice: ($('dscDbVoiceA') || {}).value || '',
            voiceB: ($('dscDbVoiceB') || {}).value || '',
            fastMode: !!(($('dscDbFastMode') || {}).checked),
            autoRouteAudio: !!(($('dscDbAutoRoute') || {}).checked),
            watermark: !!(($('dscDbWatermark') || {}).checked),
            duplexVoice: ($('dscDbDuplexVoice') || {}).value || '',
            duplexInstructions: ($('dscDbDuplexInstr') || {}).value || '',
            duplexLang: ($('dscDbDuplexLang') || {}).value || 'zh',
            rtcAppId: ($('dscDbRtcAppId') || {}).value || '',
            rtcRoomId: ($('dscDbRtcRoomId') || {}).value || '',
            s2sAppId: ($('dscDbS2sAppId') || {}).value || ''
        };
        // センシティブ値は空欄なら送らない（既存の保存値を保持する）
        var dk = (($('dscDbDuplexKey') || {}).value || '').trim();
        if (dk) body.duplexApiKey = dk;
        var rk = (($('dscDbRtcAk') || {}).value || '').trim();
        var rs = (($('dscDbRtcSk') || {}).value || '').trim();
        var st2 = (($('dscDbS2sToken') || {}).value || '').trim();
        if (rk) body.rtcAccessKey = rk;
        if (rs) body.rtcSecretKey = rs;
        if (st2) body.s2sToken = st2;
        if (btn) btn.disabled = true;
        setStatus(st, T('保存中…'), 'busy');
        try {
            var d = await api('/config', { method: 'POST', body: body });
            S.cfg = d;
            S.catalog = (d.catalog && d.catalog.models) || S.catalog;
            fillCfgForm();
            purgeLegacyChatModels();
            syncDbModeUI();   // 対話モデルを変えたらボタンの title も即時追従
            toast(T('✅ 豆包設定を保存しました'), 'success');
        } catch (e) {
            setStatus(st, T('❌ 保存に失敗：{0}', e.message), 'err');
            toast(T('豆包設定の保存に失敗：{0}', e.message), 'error');
        } finally {
            if (btn) btn.disabled = false;
        }
    }

    async function clearKey() {
        if (!window.confirm(T('豆包 API Key を消去しますか？'))) return;
        var st = $('dscDbCfgStatus');
        try {
            var d = await api('/config', { method: 'POST', body: { clearKey: true } });
            S.cfg = d;
            fillCfgForm();
            setStatus(st, T('豆包 Key を消去しました'), 'err');
            toast(T('豆包 Key を消去しました'), 'info');
        } catch (e) {
            setStatus(st, T('❌ 消去に失敗：{0}', e.message), 'err');
        }
    }

    async function addCustomModel() {
        var inp = $('dscDbCustomModel');
        var v = inp ? inp.value.trim() : '';
        if (!v) { toast(T('モデル値を入力してください'), 'info'); return; }
        var cur = (S.cfg && S.cfg.customModels) || [];
        if (cur.indexOf(v) < 0) cur.push(v);
        try {
            var d = await api('/config', { method: 'POST', body: { customModels: cur } });
            S.cfg = d;
            S.catalog = (d.catalog && d.catalog.models) || S.catalog;
            renderModelList();
            purgeLegacyChatModels();
            syncDbModeUI();
            if (inp) inp.value = '';
            toast(T('カスタムモデルを追加しました：{0}', v), 'success');
        } catch (e) {
            toast(T('追加に失敗：{0}', e.message), 'error');
        }
    }

    // ------------------------------------------------------------
    // 音声生成（TTS）
    // ------------------------------------------------------------
    function openTtsModal() {
        ensureModal('dscDbTtsOverlay', buildTtsModal, S.ttsBusy);
        loadConfig().then(function (c) {
            var v = $('dscDbTtsVoice');
            if (v && !v.value) v.value = c.voice || '';
            return loadTtsModels();
        }).catch(function (e) {
            setStatus($('dscDbTtsStatus'), '❌ ' + T('設定の読み込みに失敗：{0}', e.message), 'err');
        });
        openModal('dscDbTtsOverlay');
    }

    function buildTtsModal() {
        var md = buildModal('dscDbTtsOverlay', '🔊', '豆包で音声生成',
            'テキストから音声を合成します。生成物は ds_files/blob に保存されます。');
        md.appendChild(field('読み上げるテキスト', textarea('dscDbTtsText', '例：こんにちは。今日はいい天気ですね。')));

        var grid = el('div', 'dsc-db-grid');
        grid.appendChild(field('音声のファイル名', input('dscDbTtsName', 'text', '例：ナレーション1')));
        grid.appendChild(field('話速', select('dscDbTtsSpeed', ['0.5', '0.75', '1.0', '1.25', '1.5', '2.0'], '1.0')));
        md.appendChild(grid);

        var grid2 = el('div', 'dsc-db-grid');
        grid2.appendChild(field('音色', input('dscDbTtsVoice', 'text', 'zh_female_xiaohe_uranus_bigtts')));
        grid2.appendChild(field('音声合成モデル', select('dscDbTtsPick', [])));
        md.appendChild(grid2);

        var st = el('div', 'dsc-db-status');
        st.id = 'dscDbTtsStatus';
        md.appendChild(st);
        var res = el('div', 'dsc-db-result');
        res.id = 'dscDbTtsResult';
        md.appendChild(res);

        var foot = el('div', 'dsc-db-footer');
        var close = el('button', 'dsc-db-btn', T('閉じる'));
        close.type = 'button';
        var go = el('button', 'dsc-db-btn primary', T('音声を生成する'));
        go.type = 'button';
        go.id = 'dscDbTtsGo';
        foot.appendChild(close);
        foot.appendChild(go);
        md.appendChild(foot);
        close.addEventListener('click', function () { closeModal('dscDbTtsOverlay'); });
        go.addEventListener('click', generateTts);
    }

    // 音声生成パネル専用のモデル選択。
    // 設定パネルにも「音声合成モデル」があり、以前は同じ id を使っていたため
    // document.getElementById が設定パネル側を返し、このパネルの select が
    // 空のまま残っていた。パネル内スコープで引くことで衝突を断つ。
    function ttsModelSel() {
        var ov = $('dscDbTtsOverlay');
        return ov ? ov.querySelector('#dscDbTtsPick') : null;
    }

    function fillTtsModels() {
        var sel = ttsModelSel();
        if (!sel) return;
        var items = modelsByCat('tts');
        // カタログが空でも選択肢をゼロにしない（必ず 1 件は選べる状態にする）
        if (!items.length) {
            items = [{ value: 'SeedAudio1.0', label: 'Doubao-音声生成-1.0（音声生成）' }];
        }
        var want = (S.cfg && S.cfg.ttsModel) || '';
        if (want && !items.some(function (m) { return m.value === want; })) {
            items.push({ value: want, label: want });
        }
        fillSelect(sel, items, want || items[0].value);
        if (!sel.value) sel.value = items[0].value;
    }

    // カタログ未取得のまま開かれた場合に備え、/models を取り直してから埋める
    function loadTtsModels() {
        fillTtsModels();
        if ((S.catalog || []).length) return Promise.resolve();
        return api('/models').then(function (d) {
            S.catalog = (d && d.models) || [];
            fillTtsModels();
        }).catch(function () {});
    }

    async function generateTts() {
        if (S.ttsBusy) return;
        var st = $('dscDbTtsStatus');
        var btn = $('dscDbTtsGo');
        var text = ($('dscDbTtsText') || {}).value || '';
        if (!text.trim()) { setStatus(st, '⚠️ ' + T('テキストを入力してください'), 'err'); return; }
        var body = {
            text: text,
            voice: (($('dscDbTtsVoice') || {}).value || '').trim(),
            model: (ttsModelSel() || {}).value || '',
            speed: (($('dscDbTtsSpeed') || {}).value || '1.0'),
            format: 'mp3',
            name: (($('dscDbTtsName') || {}).value || '').trim(),
            lang: lang()
        };
        S.ttsBusy = true;
        if (btn) btn.disabled = true;
        setStatus(st, T('合成中…'), 'busy');
        try {
            var d = await api('/tts', { method: 'POST', body: body });
            var f = d.file || {};
            var box = $('dscDbTtsResult');
            box.innerHTML = '';
            var au = document.createElement('audio');
            au.src = fileUrl(f) + '&_t=' + Date.now();
            au.controls = true;
            au.style.width = '100%';
            box.appendChild(au);
            box.appendChild(el('div', 'dsc-db-filename', T('ファイル名：{0}', f.name || '')));
            var row = el('div', 'dsc-db-row');
            var dl = el('button', 'dsc-db-btn primary', T('音声をダウンロード'));
            dl.type = 'button';
            dl.addEventListener('click', function () { openExternal(downloadUrl(f)); });
            var again = el('button', 'dsc-db-btn ghost', T('もう一度生成'));
            again.type = 'button';
            again.addEventListener('click', function () { generateTts(); });
            row.appendChild(dl);
            row.appendChild(again);
            box.appendChild(row);
            setStatus(st, T('✅ 音声を生成しました：{0}', f.name || ''), 'ok');
            toast(T('✅ 音声を生成しました：{0}', f.name || ''), 'success');
            refreshFiles();
        } catch (e) {
            setStatus(st, '❌ ' + T('音声生成に失敗：{0}', e.message), 'err');
            toast(T('音声生成に失敗：{0}', e.message), 'error');
        } finally {
            S.ttsBusy = false;
            if (btn) btn.disabled = false;
        }
    }

    // ------------------------------------------------------------
    // 録音ファイル認識（ASR）
    //   豆包の音声認識で文字起こしし、結果をそのまま現在の対話へ差し込む。
    //   ★ 認識は豆包（方舟の音声理解 → /audio/transcriptions → 失敗時ローカル whisper）、
    //     差し込みは既存のユーザーメッセージ保存端点のみを使う。
    //     ★ 認識は豆包（方舟）の用量を消費する。DeepSeek の用量は消費しない。
    // ------------------------------------------------------------
    function fmtSize(n) {
        n = Number(n) || 0;
        if (n < 1024) return n + ' B';
        if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
        return (n / (1024 * 1024)).toFixed(1) + ' MB';
    }

    function openAsrModal() {
        ensureModal('dscDbAsrOverlay', buildAsrModal, S.asrBusy);
        loadConfig().then(function (c) {
            var st = $('dscDbAsrStatus');
            if (st && !st.textContent) {
                setStatus(st, T('文字起こしに使うモデル：{0}（音声理解）／{1}（音声認識）。豆包の用量を消費し、DeepSeek の用量は消費しません。',
                    (c && c.chatModel) || 'doubao-seed', (c && c.asrModel) || 'Doubao_Seed_ASR_AUC_2.0'), '');
            }
        }).catch(function () {});
        openModal('dscDbAsrOverlay');
    }

    function buildAsrModal() {
        var md = buildModal('dscDbAsrOverlay', '🎤', '録音ファイルを豆包で認識',
            '録音ファイルを豆包で文字起こしします。結果は下の欄に表示されるので、そのままコピーできます。対話へは自動送信しません。');

        var pick = el('div', 'dsc-db-filepick');
        var file = document.createElement('input');
        file.type = 'file';
        file.id = 'dscDbAsrFile';
        file.className = 'dsc-db-file';
        file.accept = 'audio/*,.m4a,.amr,.mp3,.wav,.ogg,.aac,.flac,.webm,.opus';
        var pickBtn = el('button', 'dsc-db-btn', T('録音ファイルを選択'));
        pickBtn.type = 'button';
        pickBtn.id = 'dscDbAsrPick';
        var info = el('span', 'dsc-db-filename', T('まだ選択されていません'));
        info.id = 'dscDbAsrFileInfo';
        pickBtn.addEventListener('click', function () { file.click(); });
        file.addEventListener('change', function () {
            var f = file.files && file.files[0];
            info.textContent = f ? (f.name + ' · ' + fmtSize(f.size)) : T('まだ選択されていません');
        });
        pick.appendChild(file);
        pick.appendChild(pickBtn);
        pick.appendChild(info);
        md.appendChild(pick);

        md.appendChild(field('認識結果（そのままコピーできます。必要なら編集してください）',
            textarea('dscDbAsrText', '録音ファイルを選び「豆包で認識」を押してください')));

        var metaLine = el('div', 'dsc-db-hint');
        metaLine.id = 'dscDbAsrMeta';
        md.appendChild(metaLine);

        var st = el('div', 'dsc-db-status');
        st.id = 'dscDbAsrStatus';
        md.appendChild(st);

        var foot = el('div', 'dsc-db-footer');
        var close = el('button', 'dsc-db-btn', T('閉じる'));
        close.type = 'button';
        var copy = el('button', 'dsc-db-btn', T('結果をコピー'));
        copy.type = 'button';
        copy.id = 'dscDbAsrCopy';
        var ins = el('button', 'dsc-db-btn ghost', T('対話に差し込む'));
        ins.type = 'button';
        ins.id = 'dscDbAsrInsert';
        var go = el('button', 'dsc-db-btn primary', T('豆包で認識'));
        go.type = 'button';
        go.id = 'dscDbAsrGo';
        foot.appendChild(copy);
        foot.appendChild(ins);
        foot.appendChild(close);
        foot.appendChild(go);
        md.appendChild(foot);
        close.addEventListener('click', function () { closeModal('dscDbAsrOverlay'); });
        copy.addEventListener('click', function () { copyAsrText(false); });
        ins.addEventListener('click', function () {
            var box = $('dscDbAsrText');
            deliverAsrToChat(box ? box.value : '', $('dscDbAsrStatus'));
        });
        go.addEventListener('click', recognizeAsrFile);
    }

    async function recognizeAsrFile() {
        if (S.asrBusy) return;
        var st = $('dscDbAsrStatus');
        var btn = $('dscDbAsrGo');
        var inp = $('dscDbAsrFile');
        var out = $('dscDbAsrText');
        var f = inp && inp.files && inp.files[0];
        if (!f) { setStatus(st, '⚠️ ' + T('録音ファイルを選択してください'), 'err'); return; }
        if (f.size < 200) { setStatus(st, '⚠️ ' + T('音声が短すぎます'), 'err'); return; }
        S.asrBusy = true;
        if (btn) btn.disabled = true;
        setStatus(st, T('豆包で認識中…（{0}）', fmtSize(f.size)), 'busy');
        try {
            var fd = new FormData();
            fd.append('audio', f, f.name || 'audio.m4a');
            var res = await fetch(API + '/asr', { method: 'POST', body: fd, cache: 'no-store' });
            var data = {};
            try { data = await res.json(); } catch (e) { data = {}; }
            if (!res.ok) throw new Error((data && (data.error || data.message)) || ('HTTP ' + res.status));
            var text = String((data && data.text) || '').trim();
            if (!text) throw new Error(T('豆包が空の認識結果を返しました'));
            if (out) out.value = text;
            var m = String((data && data.model) || '');
            var ep = String((data && data.endpoint) || '');
            var mt = $('dscDbAsrMeta');
            if (mt) mt.textContent = T('認識モデル：{0} · 端点：{1}', m || '-', ep || '-');
            setStatus(st, T('✅ 認識しました（{0} 文字）。下の欄からコピーできます（対話へは自動送信しません）', text.length), 'ok');
            toast(T('✅ 認識結果を表示しました（{0} 文字）', text.length), 'success');
            copyAsrText(true);
        } catch (e) {
            setStatus(st, '❌ ' + T('認識に失敗：{0}', e.message), 'err');
            toast(T('認識に失敗：{0}', e.message), 'error');
        } finally {
            S.asrBusy = false;
            if (btn) btn.disabled = false;
        }
    }

    // 認識結果をクリップボードへコピー（自動送信はしない。失敗時は選択コピーへ退避）
    async function copyAsrText(silent) {
        var out = $('dscDbAsrText');
        var st = $('dscDbAsrStatus');
        var txt = out ? String(out.value || '') : '';
        if (!txt.trim()) {
            if (!silent) setStatus(st, '⚠️ ' + T('先に認識してください'), 'err');
            return false;
        }
        var ok = false;
        try {
            if (navigator.clipboard && navigator.clipboard.writeText) {
                await navigator.clipboard.writeText(txt);
                ok = true;
            }
        } catch (e) { ok = false; }
        if (!ok) {
            try {
                out.focus();
                out.select();
                ok = document.execCommand('copy');
            } catch (e) { ok = false; }
        }
        if (!silent) {
            setStatus(st, ok ? T('📋 結果をコピーしました（{0} 文字）', txt.length)
                : '⚠️ ' + T('コピーに失敗しました。長押しで選択してコピーしてください'),
                ok ? 'ok' : 'err');
        }
        return ok;
    }

    async function deliverAsrToChat(text, st) {
        var t = String(text || '').trim();
        if (!t) return;
        // 本命：現在の対話へユーザーメッセージとして差し込む（モデル呼び出しなし）
        if (typeof window.dscInjectUserMessage === 'function') {
            var r = await window.dscInjectUserMessage(t);
            if (r && r.ok) {
                setStatus(st, T('✅ 対話に差し込みました（{0} 文字）', t.length), 'ok');
                toast(T('✅ 認識結果を対話に差し込みました'), 'success');
                setTimeout(function () { closeModal('dscDbAsrOverlay'); }, 900);
                return;
            }
            setStatus(st, '⚠️ ' + T('対話への差し込みに失敗：{0}', (r && r.error) || 'unknown'), 'err');
        }
        // 代替：入力欄へ入れる（失敗を隠さない）
        var box = document.getElementById('dscInput');
        if (box) {
            box.value = box.value ? (box.value + '\n' + t) : t;
            try { box.dispatchEvent(new Event('input', { bubbles: true })); } catch (e) {}
            setStatus(st, '⚠️ ' + T('自動差し込みに失敗したため入力欄へ入れました。送信は手動で行ってください'), 'err');
        } else {
            setStatus(st, '❌ ' + T('対話画面が見つかりません'), 'err');
        }
    }

    // ------------------------------------------------------------
    // 画像生成
    // ------------------------------------------------------------
    function openImageModal() {
        ensureModal('dscDbImageOverlay', buildImageModal, S.imgBusy);
        loadConfig().then(function () {
            fillImageModels();
        }).catch(function (e) {
            setStatus($('dscDbImgStatus'), T('❌ 設定の読み込みに失敗：{0}', e.message), 'err');
        });
        openModal('dscDbImageOverlay');
    }

    function buildImageModal() {
        var md = buildModal('dscDbImageOverlay', '🎨', '豆包で画像を生成',
            'ファイル名・説明・比率・スタイルを指定して生成します。生成物は ds_files/blob に保存されます。');
        md.appendChild(field('画像のファイル名', input('dscDbImgName', 'text', '例：夏の夜景')));
        md.appendChild(field('画像の説明（プロンプト）', textarea('dscDbImgPrompt', '例：夕暮れの海辺を歩く少女、逆光、フィルムグレイン')));

        var ratioSel = select('dscDbImgRatio', RATIOS.concat([{ value: '__custom__', label: T('カスタム比率') }]), '16:9');
        md.appendChild(field('アスペクト比', ratioSel));
        var ratioCustom = input('dscDbImgRatioCustom', 'text', '例：7:5');
        ratioCustom.style.display = 'none';
        md.appendChild(field('', ratioCustom));
        ratioSel.addEventListener('change', function () {
            ratioCustom.style.display = ratioSel.value === '__custom__' ? 'block' : 'none';
        });

        // 表示名だけを翻訳する（value はモデルへ渡すプロンプト用の識別子なので日本語のまま）
        var styleSel = select('dscDbImgStyle', IMG_STYLES_JA.map(function (s) { return { value: s, label: T(s) }; })
            .concat([{ value: '__custom__', label: T('カスタムスタイル') }]), '日本アニメ風');
        md.appendChild(field('スタイル', styleSel));
        var styleCustom = input('dscDbImgStyleCustom', 'text', '例：水彩画風、柔らかい光');
        styleCustom.style.display = 'none';
        md.appendChild(field('', styleCustom));
        styleSel.addEventListener('change', function () {
            styleCustom.style.display = styleSel.value === '__custom__' ? 'block' : 'none';
        });

        var grid = el('div', 'dsc-db-grid');
        grid.appendChild(field('モデル', select('dscDbImgModel', [])));
        grid.appendChild(field('解像度', select('dscDbImgRes', ['2K', '4K'], '2K')));
        md.appendChild(grid);

        var st = el('div', 'dsc-db-status');
        st.id = 'dscDbImgStatus';
        md.appendChild(st);

        var res = el('div', 'dsc-db-result');
        res.id = 'dscDbImgResult';
        md.appendChild(res);

        var foot = el('div', 'dsc-db-footer');
        var go = el('button', 'dsc-db-btn primary', T('生成する'));
        go.type = 'button';
        go.id = 'dscDbImgGo';
        var open = el('button', 'dsc-db-btn ghost', T('ファイル管理を開く'));
        open.type = 'button';
        var close = el('button', 'dsc-db-btn', T('閉じる'));
        close.type = 'button';
        foot.appendChild(open);
        foot.appendChild(close);
        foot.appendChild(go);
        md.appendChild(foot);

        close.addEventListener('click', function () { closeModal('dscDbImageOverlay'); });
        open.addEventListener('click', function () {
            closeModal('dscDbImageOverlay');
            var b = $('dscFilesToggle');
            if (b) b.click();
        });
        go.addEventListener('click', generateImage);
    }

    function fillImageModels() {
        var sel = $('dscDbImgModel');
        if (!sel) return;
        var items = modelsByCat('image');
        fillSelect(sel, items, S.cfg ? S.cfg.imageModel : '');
    }

    async function generateImage() {
        if (S.imgBusy) return;
        var st = $('dscDbImgStatus');
        var btn = $('dscDbImgGo');
        var prompt = ($('dscDbImgPrompt') || {}).value || '';
        if (!prompt.trim()) { setStatus(st, T('⚠️ 画像の説明を入力してください'), 'err'); return; }
        var ratio = ($('dscDbImgRatio') || {}).value || '16:9';
        if (ratio === '__custom__') {
            ratio = (($('dscDbImgRatioCustom') || {}).value || '').trim() || '1:1';
        }
        var style = ($('dscDbImgStyle') || {}).value || '';
        var customStyle = '';
        if (style === '__custom__') {
            customStyle = (($('dscDbImgStyleCustom') || {}).value || '').trim();
            style = '';
        }
        var body = {
            prompt: prompt.trim(),
            name: (($('dscDbImgName') || {}).value || '').trim(),
            ratio: ratio,
            style: style,
            customStyle: customStyle,
            model: ($('dscDbImgModel') || {}).value || '',
            resolution: ($('dscDbImgRes') || {}).value || '2K'
        };
        S.imgBusy = true;
        if (btn) btn.disabled = true;
        setStatus(st, T('生成中…（最大 1〜2 分かかります）'), 'busy');
        try {
            var d;
            try {
                d = await api('/image', { method: 'POST', body: body });
            } catch (e) {
                var em = (e && e.message) || '';
                var fb = (S.cfg && S.cfg.imageModel) ? S.cfg.imageModel : '';
                if (fb && body.model && body.model !== fb && /404|does not exist|not have access/i.test(em)) {
                    setStatus(st, T('⚠️ このモデルは未開通のため、{0} に自動切替して生成します…', fb), 'busy');
                    d = await api('/image', { method: 'POST', body: Object.assign({}, body, { model: fb }) });
                    toast(T('⚠️ このモデルは未開通のため、{0} で生成しました', fb), 'info');
                } else {
                    throw e;
                }
            }
            if (d && d.fallbackFrom) {
                toast(T('ℹ️ {0} は利用不可のため {1} で生成しました', d.fallbackFrom, d.model || ''), 'info');
            }
            var f = d.file || {};
            var box = $('dscDbImgResult');
            box.innerHTML = '';
            var img = document.createElement('img');
            img.src = fileUrl(f) + '&_t=' + Date.now();
            img.alt = f.name || 'doubao image';
            box.appendChild(img);
            box.appendChild(el('div', 'dsc-db-filename', T('ファイル名：{0}', f.name || '')));
            var row = el('div', 'dsc-db-row');
            var dl = el('button', 'dsc-db-btn primary', T('ダウンロード'));
            dl.type = 'button';
            dl.addEventListener('click', function () { openExternal(downloadUrl(f)); });
            var again = el('button', 'dsc-db-btn', T('もう一度生成'));
            again.type = 'button';
            again.addEventListener('click', function () { generateImage(); });
            row.appendChild(dl);
            row.appendChild(again);
            box.appendChild(row);
            setStatus(st, T('✅ 生成しました · 比率 {0} · サイズ {1}', d.ratio || ratio, d.size || ''), 'ok');
            toast(T('✅ 画像を生成しました：{0}', f.name || ''), 'success');
            refreshFiles();
        } catch (e) {
            setStatus(st, T('❌ 生成に失敗：{0}', e.message), 'err');
            toast(T('画像生成に失敗：{0}', e.message), 'error');
        } finally {
            S.imgBusy = false;
            if (btn) btn.disabled = false;
        }
    }

    // ------------------------------------------------------------
    // 豆包P图（画像編集）
    //   ローカル画像を豆包へ渡し、指示どおりに修正させる。
    //   ブラウザ側で長辺 2048 / JPEG 92% に縮小してから送る（大きすぎる画像で失敗しないように）。
    // ------------------------------------------------------------
    function openEditModal() {
        ensureModal('dscDbEditOverlay', buildEditModal, S.editBusy);
        loadConfig().then(fillEditModels).catch(function (e) {
            setStatus($('dscDbEditStatus'), T('❌ 設定の読み込みに失敗：{0}', e.message), 'err');
        });
        openModal('dscDbEditOverlay');
    }

    function buildEditModal() {
        var md = buildModal('dscDbEditOverlay', '🖌️', '豆包P图',
            '画像をアップロードし、どう直すかを伝えると豆包が修正します。結果は ds_files/blob に保存されます。');

        var pick = el('div', 'dsc-db-filepick');
        var file = document.createElement('input');
        file.type = 'file';
        file.id = 'dscDbEditFile';
        file.className = 'dsc-db-file';
        file.accept = 'image/*';
        var pickBtn = el('button', 'dsc-db-btn', T('画像を選択'));
        pickBtn.type = 'button';
        pickBtn.id = 'dscDbEditPick';
        var info = el('span', 'dsc-db-filename', T('まだ選択されていません'));
        info.id = 'dscDbEditFileInfo';
        pickBtn.addEventListener('click', function () { file.click(); });
        file.addEventListener('change', function () {
            var f = file.files && file.files[0];
            info.textContent = f ? (f.name + ' · ' + fmtSize(f.size)) : T('まだ選択されていません');
            var box = $('dscDbEditPreview');
            if (box) {
                box.innerHTML = '';
                if (f) {
                    var im = document.createElement('img');
                    im.src = URL.createObjectURL(f);
                    box.appendChild(im);
                }
            }
        });
        pick.appendChild(file);
        pick.appendChild(pickBtn);
        pick.appendChild(info);
        md.appendChild(pick);

        var prev = el('div', 'dsc-db-preview');
        prev.id = 'dscDbEditPreview';
        md.appendChild(prev);

        md.appendChild(field('P图要求（どこをどう直すか）',
            textarea('dscDbEditPrompt', '例：背景を海辺に変える／人物をそのままに髪色を黒へ／服を白いシャツに')));

        var grid = el('div', 'dsc-db-grid');
        grid.appendChild(field('モデル', select('dscDbEditModel', [])));
        grid.appendChild(field('出力サイズ', select('dscDbEditRes', ['2K', '4K'], '2K')));
        md.appendChild(grid);

        var st = el('div', 'dsc-db-status');
        st.id = 'dscDbEditStatus';
        md.appendChild(st);

        var res = el('div', 'dsc-db-result');
        res.id = 'dscDbEditResult';
        md.appendChild(res);

        var foot = el('div', 'dsc-db-footer');
        var open = el('button', 'dsc-db-btn ghost', T('ファイル管理を開く'));
        open.type = 'button';
        var close = el('button', 'dsc-db-btn', T('閉じる'));
        close.type = 'button';
        var go = el('button', 'dsc-db-btn primary', T('豆包にP图してもらう'));
        go.type = 'button';
        go.id = 'dscDbEditGo';
        foot.appendChild(open);
        foot.appendChild(close);
        foot.appendChild(go);
        md.appendChild(foot);

        close.addEventListener('click', function () { closeModal('dscDbEditOverlay'); });
        open.addEventListener('click', function () {
            closeModal('dscDbEditOverlay');
            var b = $('dscFilesToggle');
            if (b) b.click();
        });
        go.addEventListener('click', editImage);
    }

    function fillEditModels() {
        var sel = $('dscDbEditModel');
        if (!sel) return;
        var EDIT_DEFAULT = 'doubao-seedream-5-0-pro-260628';
        var all = modelsByCat('imageedit').concat(modelsByCat('image'));
        var head = all.filter(function (m) { return m.value === EDIT_DEFAULT; });
        var rest = all.filter(function (m) { return m.value !== EDIT_DEFAULT; });
        var items = head.concat(rest);
        if (!items.length) items = [{ value: '', label: T('既定（Seedream 5.0 pro）') }];
        var pick = items.some(function (m) { return m.value === EDIT_DEFAULT; }) ? EDIT_DEFAULT : items[0].value;
        fillSelect(sel, items, pick);
    }

    // 画像を長辺 maxSide に縮小して dataURL 化（縮小不要なら元の dataURL をそのまま返す）
    function readImageDataUrl(file, maxSide, quality) {
        return new Promise(function (resolve, reject) {
            var fr = new FileReader();
            fr.onerror = function () { reject(new Error(T('画像の読み込みに失敗しました'))); };
            fr.onload = function () {
                var src = String(fr.result || '');
                if (!src) { reject(new Error(T('画像の読み込みに失敗しました'))); return; }
                var img = new Image();
                img.onerror = function () { resolve(src); };
                img.onload = function () {
                    try {
                        var w = img.naturalWidth || img.width || 0;
                        var h = img.naturalHeight || img.height || 0;
                        var scale = (w > 0 && h > 0) ? Math.min(1, maxSide / Math.max(w, h)) : 1;
                        if (scale >= 1 && src.length <= 3.5 * 1024 * 1024) { resolve(src); return; }
                        var cv = document.createElement('canvas');
                        cv.width = Math.max(1, Math.round(w * scale));
                        cv.height = Math.max(1, Math.round(h * scale));
                        var ctx = cv.getContext('2d');
                        ctx.fillStyle = '#ffffff';
                        ctx.fillRect(0, 0, cv.width, cv.height);
                        ctx.drawImage(img, 0, 0, cv.width, cv.height);
                        resolve(cv.toDataURL('image/jpeg', quality || 0.92));
                    } catch (e) { resolve(src); }
                };
                img.src = src;
            };
            fr.readAsDataURL(file);
        });
    }

    async function editImage() {
        if (S.editBusy) return;
        var st = $('dscDbEditStatus');
        var btn = $('dscDbEditGo');
        var inp = $('dscDbEditFile');
        var f = inp && inp.files && inp.files[0];
        if (!f) { setStatus(st, '⚠️ ' + T('先に画像を選択してください'), 'err'); return; }
        var prompt = (($('dscDbEditPrompt') || {}).value || '').trim();
        if (!prompt) { setStatus(st, '⚠️ ' + T('P图要求を入力してください'), 'err'); return; }
        if (f.size > 12 * 1024 * 1024) { setStatus(st, '⚠️ ' + T('画像が大きすぎます（上限 12MB）'), 'err'); return; }
        S.editBusy = true;
        if (btn) btn.disabled = true;
        setStatus(st, T('豆包がP图中…（最大 1〜2 分かかります）'), 'busy');
        try {
            var dataUrl = await readImageDataUrl(f, 2048, 0.92);
            var d = await api('/image-edit', {
                method: 'POST',
                body: {
                    imageBase64: dataUrl,
                    fileName: f.name || 'image.png',
                    prompt: prompt,
                    model: ($('dscDbEditModel') || {}).value || '',
                    resolution: ($('dscDbEditRes') || {}).value || '2K'
                }
            });
            if (d && d.fallbackFrom) {
                toast(T('ℹ️ {0} は利用不可のため {1} で生成しました', d.fallbackFrom, d.model || ''), 'info');
            }
            var meta = d.file || {};
            var box = $('dscDbEditResult');
            box.innerHTML = '';
            var img = document.createElement('img');
            img.src = fileUrl(meta) + '&_t=' + Date.now();
            img.alt = meta.name || 'doubao edit';
            box.appendChild(img);
            box.appendChild(el('div', 'dsc-db-filename', T('ファイル名：{0}', meta.name || '')));
            var row = el('div', 'dsc-db-row');
            var dl = el('button', 'dsc-db-btn primary', T('ダウンロード'));
            dl.type = 'button';
            dl.addEventListener('click', function () { openExternal(downloadUrl(meta)); });
            var again = el('button', 'dsc-db-btn', T('もう一度P图'));
            again.type = 'button';
            again.addEventListener('click', function () { editImage(); });
            row.appendChild(dl);
            row.appendChild(again);
            box.appendChild(row);
            setStatus(st, T('✅ P图が完成しました：{0}', meta.name || ''), 'ok');
            toast(T('✅ P图が完成しました：{0}', meta.name || ''), 'success');
            refreshFiles();
        } catch (e) {
            setStatus(st, '❌ ' + T('P图に失敗：{0}', e.message), 'err');
            toast(T('P图に失敗：{0}', e.message), 'error');
        } finally {
            S.editBusy = false;
            if (btn) btn.disabled = false;
        }
    }

    // ------------------------------------------------------------
    // 動画生成
    // ------------------------------------------------------------
    function openVideoModal() {
        ensureModal('dscDbVideoOverlay', buildVideoModal, S.vidBusy);
        loadConfig().then(fillVideoModels).catch(function (e) {
            setStatus($('dscDbVidStatus'), T('❌ 設定の読み込みに失敗：{0}', e.message), 'err');
        });
        openModal('dscDbVideoOverlay');
    }

    function buildVideoModal() {
        var md = buildModal('dscDbVideoOverlay', '🎬', '豆包で動画を生成',
            'Seedance によるテキスト→動画。完了まで数十秒〜数分かかり、生成物は ds_files/blob に保存されます。');
        md.appendChild(field('動画のファイル名', input('dscDbVidName', 'text', '例：海辺の夕日')));
        md.appendChild(field('動画の説明（プロンプト）', textarea('dscDbVidPrompt', '例：夕暮れの海辺をゆっくり歩く少女、カメラは背後から追従')));

        var grid = el('div', 'dsc-db-grid');
        grid.appendChild(field('アスペクト比', select('dscDbVidRatio', RATIOS, '16:9')));
        grid.appendChild(field('解像度', select('dscDbVidRes', ['480p', '720p', '1080p', '4K'], '720p')));
        grid.appendChild(field('長さ（秒）', select('dscDbVidDur', ['4', '5', '6', '8', '10', '12', '15'], '5')));
        grid.appendChild(field('モデル', select('dscDbVidModel', [])));
        md.appendChild(grid);
        md.appendChild(switchRow('dscDbVidAudio', '音声も生成する', 'セリフ・効果音つきの動画を生成（対応モデルのみ）', true));

        var st = el('div', 'dsc-db-status');
        st.id = 'dscDbVidStatus';
        md.appendChild(st);
        var prog = el('div', 'dsc-db-progress');
        prog.innerHTML = '<i></i>';
        md.appendChild(prog);
        var res = el('div', 'dsc-db-result');
        res.id = 'dscDbVidResult';
        md.appendChild(res);

        var foot = el('div', 'dsc-db-footer');
        var cancel = el('button', 'dsc-db-btn ghost', T('ポーリング停止'));
        cancel.type = 'button';
        var close = el('button', 'dsc-db-btn', T('閉じる'));
        close.type = 'button';
        var go = el('button', 'dsc-db-btn primary', T('生成する'));
        go.type = 'button';
        go.id = 'dscDbVidGo';
        foot.appendChild(cancel);
        foot.appendChild(close);
        foot.appendChild(go);
        md.appendChild(foot);

        close.addEventListener('click', function () { closeModal('dscDbVideoOverlay'); });
        cancel.addEventListener('click', function () {
            if (S.pollTimer) { clearTimeout(S.pollTimer); S.pollTimer = null; }
            setStatus($('dscDbVidStatus'), T('ポーリングを停止しました（タスクはサーバー側で継続）'), 'busy');
        });
        go.addEventListener('click', createVideo);
    }

    function fillVideoModels() {
        var sel = $('dscDbVidModel');
        if (!sel) return;
        fillSelect(sel, modelsByCat('video'),
            S.cfg ? S.cfg.videoModel : '');
    }

    function setProgress(pct) {
        var bar = document.querySelector('#dscDbVideoOverlay .dsc-db-progress > i');
        if (bar) bar.style.width = Math.max(0, Math.min(100, pct)) + '%';
    }

    async function createVideo() {
        if (S.vidBusy) return;
        var st = $('dscDbVidStatus');
        var btn = $('dscDbVidGo');
        var prompt = ($('dscDbVidPrompt') || {}).value || '';
        if (!prompt.trim()) { setStatus(st, T('⚠️ 動画の説明を入力してください'), 'err'); return; }
        var body = {
            prompt: prompt.trim(),
            name: (($('dscDbVidName') || {}).value || '').trim(),
            ratio: ($('dscDbVidRatio') || {}).value || '16:9',
            resolution: ($('dscDbVidRes') || {}).value || '720p',
            duration: parseInt((($('dscDbVidDur') || {}).value || '5'), 10),
            generateAudio: !!(($('dscDbVidAudio') || {}).checked),
            model: ($('dscDbVidModel') || {}).value || ''
        };
        S.vidBusy = true;
        if (btn) btn.disabled = true;
        setStatus(st, T('タスクを作成中…'), 'busy');
        setProgress(6);
        try {
            var d = await api('/video', { method: 'POST', body: body });
            var task = d.task || {};
            setStatus(st, T('生成中… タスク {0}', task.id || ''), 'busy');
            pollVideo(task.id, 0);
        } catch (e) {
            setStatus(st, T('❌ 生成に失敗：{0}', e.message), 'err');
            toast(T('動画生成に失敗：{0}', e.message), 'error');
            S.vidBusy = false;
            if (btn) btn.disabled = false;
            setProgress(0);
        }
    }

    async function pollVideo(taskId, tries) {
        var st = $('dscDbVidStatus');
        var btn = $('dscDbVidGo');
        if (!taskId) return;
        if (tries > 150) {
            setStatus(st, T('⚠️ タイムアウトしました。タスクはサーバー側で継続中です：{0}', taskId), 'err');
            S.vidBusy = false;
            if (btn) btn.disabled = false;
            return;
        }
        try {
            var d = await api('/video/status?taskId=' + encodeURIComponent(taskId));
            var task = d.task || {};
            var status = d.status || task.status || '';
            setProgress(Math.min(94, 8 + tries * 3));
            setStatus(st, T('状態：{0} · 経過 {1} 秒', status || 'queued', tries * 5), 'busy');
            if (status === 'succeeded') {
                setProgress(100);
                var f = task.file || null;
                var box = $('dscDbVidResult');
                box.innerHTML = '';
                if (f && f.id) {
                    var v = document.createElement('video');
                    v.src = fileUrl(f);
                    v.controls = true;
                    v.playsInline = true;
                    v.preload = 'metadata';
                    box.appendChild(v);
                    box.appendChild(el('div', 'dsc-db-filename', T('ファイル名：{0}', f.name || '')));
                    var row = el('div', 'dsc-db-row');
                    var dl = el('button', 'dsc-db-btn primary', T('ダウンロード'));
                    dl.type = 'button';
                    dl.addEventListener('click', function () { openExternal(downloadUrl(f)); });
                    row.appendChild(dl);
                    box.appendChild(row);
                    setStatus(st, T('✅ 生成しました：{0}', f.name || ''), 'ok');
                    toast(T('✅ 動画を生成しました'), 'success');
                    refreshFiles();
                } else if (task.remoteUrl) {
                    // サーバー側の保存に失敗した場合はリモート URL を明示
                    box.innerHTML = '';
                    var a = document.createElement('a');
                    a.href = task.remoteUrl;
                    a.target = '_blank';
                    a.textContent = T('生成された動画を開く（保存に失敗したため一時 URL）');
                    a.style.fontSize = '0.8rem';
                    box.appendChild(a);
                    setStatus(st, T('⚠️ 生成は成功しましたが、保存に失敗しました'), 'err');
                } else {
                    setStatus(st, T('⚠️ 生成は成功しましたが、ファイル情報がありません'), 'err');
                }
                S.vidBusy = false;
                if (btn) btn.disabled = false;
                return;
            }
            if (status === 'failed') {
                setStatus(st, T('❌ 生成に失敗：{0}', task.error || 'failed'), 'err');
                S.vidBusy = false;
                if (btn) btn.disabled = false;
                setProgress(0);
                return;
            }
            S.pollTimer = setTimeout(function () { pollVideo(taskId, tries + 1); }, 5000);
        } catch (e) {
            setStatus(st, T('⚠️ 照会に失敗（再試行します）：{0}', e.message), 'err');
            S.pollTimer = setTimeout(function () { pollVideo(taskId, tries + 1); }, 7000);
        }
    }

    // ------------------------------------------------------------
    // ポッドキャスト
    // ------------------------------------------------------------
    function openPodcastModal() {
        ensureModal('dscDbPodcastOverlay', buildPodcastModal, S.podBusy);
        loadConfig().then(function (c) {
            var va = $('dscDbPodVoiceA'), vb = $('dscDbPodVoiceB');
            if (va && !va.value) va.value = c.voice || '';
            if (vb && !vb.value) vb.value = c.voiceB || '';
            fillPodcastModels();
        }).catch(function (e) {
            setStatus($('dscDbPodStatus'), T('❌ 設定の読み込みに失敗：{0}', e.message), 'err');
        });
        openModal('dscDbPodcastOverlay');
    }

    function buildPodcastModal() {
        var md = buildModal('dscDbPodcastOverlay', '🎧', '豆包ポッドキャスト',
            'テーマから 2 人の掛け合い台本を生成し、音声に合成します。音声は ds_files/blob に保存されます。');
        md.appendChild(field('テーマ', textarea('dscDbPodTopic', '例：秋の読書におすすめの小説 3 冊')));
        md.appendChild(field('雰囲気・スタイル（任意）', input('dscDbPodStyle', 'text', '例：ゆるい雑談、テンポよく')));

        var grid = el('div', 'dsc-db-grid');
        grid.appendChild(field('長さ（分）', select('dscDbPodMin', ['1', '2', '3', '5', '8', '10'], '3')));
        grid.appendChild(field('ファイル名', input('dscDbPodName', 'text', '例：秋の読書ポッドキャスト')));
        grid.appendChild(field('音色 A', input('dscDbPodVoiceA', 'text', 'zh_female_xiaohe_uranus_bigtts')));
        grid.appendChild(field('音色 B', input('dscDbPodVoiceB', 'text', 'zh_male_qingshuangnanda_mars_bigtts')));
        grid.appendChild(field('台本生成モデル', select('dscDbPodModel', [])));
        md.appendChild(grid);

        var st = el('div', 'dsc-db-status');
        st.id = 'dscDbPodStatus';
        md.appendChild(st);
        var res = el('div', 'dsc-db-result');
        res.id = 'dscDbPodResult';
        md.appendChild(res);

        var foot = el('div', 'dsc-db-footer');
        var close = el('button', 'dsc-db-btn', T('閉じる'));
        close.type = 'button';
        var go = el('button', 'dsc-db-btn primary', T('生成する'));
        go.type = 'button';
        go.id = 'dscDbPodGo';
        foot.appendChild(close);
        foot.appendChild(go);
        md.appendChild(foot);
        close.addEventListener('click', function () { closeModal('dscDbPodcastOverlay'); });
        go.addEventListener('click', generatePodcast);
    }

    function fillPodcastModels() {
        var sel = $('dscDbPodModel');
        if (!sel) return;
        // 台本の生成は対話モデルで行う。ポッドキャストモデルを model として
        // 送ると方舟 /chat/completions が 404（model does not exist）を返すため、
        // ここでは対話モデルを列挙し、既定値も対話モデルにする。
        fillSelect(sel, modelsByCat('chat'),
            S.cfg ? S.cfg.chatModel : '');
    }

    async function generatePodcast() {
        if (S.podBusy) return;
        var st = $('dscDbPodStatus');
        var btn = $('dscDbPodGo');
        var topic = ($('dscDbPodTopic') || {}).value || '';
        if (!topic.trim()) { setStatus(st, T('⚠️ テーマを入力してください'), 'err'); return; }
        var body = {
            topic: topic.trim(),
            style: (($('dscDbPodStyle') || {}).value || '').trim(),
            minutes: parseInt((($('dscDbPodMin') || {}).value || '3'), 10),
            name: (($('dscDbPodName') || {}).value || '').trim(),
            voiceA: (($('dscDbPodVoiceA') || {}).value || '').trim(),
            voiceB: (($('dscDbPodVoiceB') || {}).value || '').trim(),
            model: ($('dscDbPodModel') || {}).value || '',
            lang: lang()
        };
        S.podBusy = true;
        if (btn) btn.disabled = true;
        setStatus(st, T('台本を生成して音声合成中…（行数が多いと数分かかります）'), 'busy');
        try {
            var d = await api('/podcast', { method: 'POST', body: body });
            var f = d.file || {};
            var box = $('dscDbPodResult');
            box.innerHTML = '';
            var au = document.createElement('audio');
            au.src = fileUrl(f);
            au.controls = true;
            box.appendChild(au);
            box.appendChild(el('div', 'dsc-db-filename', T('ファイル名：{0}', f.name || '')));
            var row = el('div', 'dsc-db-row');
            var dl = el('button', 'dsc-db-btn primary', T('音声をダウンロード'));
            dl.type = 'button';
            dl.addEventListener('click', function () { openExternal(downloadUrl(f)); });
            var dls = el('button', 'dsc-db-btn', T('台本をダウンロード'));
            dls.type = 'button';
            dls.addEventListener('click', function () {
                var text = d.scriptText || '';
                try {
                    var blob = new Blob([text], { type: 'text/plain;charset=utf-8' });
                    var url = URL.createObjectURL(blob);
                    var a = document.createElement('a');
                    a.href = url;
                    a.download = ((f.name || 'podcast').replace(/\.[^.]+$/, '')) + '_script.txt';
                    document.body.appendChild(a);
                    a.click();
                    document.body.removeChild(a);
                    setTimeout(function () { URL.revokeObjectURL(url); }, 4000);
                } catch (e) { toast(T('台本の保存に失敗：{0}', e.message), 'error'); }
            });
            var again = el('button', 'dsc-db-btn ghost', T('もう一度生成'));
            again.type = 'button';
            again.addEventListener('click', function () { generatePodcast(); });
            row.appendChild(dl);
            row.appendChild(dls);
            row.appendChild(again);
            box.appendChild(row);
            box.appendChild(el('div', 'dsc-db-script', d.scriptText || ''));
            setStatus(st, d.failedLines > 0
                ? T('✅ 生成しました（{0} 行中 {1} 行は合成失敗）', d.lines, d.failedLines)
                : T('✅ 生成しました · {0} 行', d.lines), d.failedLines > 0 ? 'err' : 'ok');
            toast(T('✅ ポッドキャストを生成しました'), 'success');
            refreshFiles();
        } catch (e) {
            setStatus(st, T('❌ 生成に失敗：{0}', e.message), 'err');
            toast(T('ポッドキャスト生成に失敗：{0}', e.message), 'error');
        } finally {
            S.podBusy = false;
            if (btn) btn.disabled = false;
        }
    }

    // ------------------------------------------------------------
    // 音声通話
    // ------------------------------------------------------------
    function openCallModal() {
        ensureModal('dscDbCallOverlay', buildCallModal, !!(S.call && S.call.active));
        try { renderCallExtra(); } catch (e) {}
        loadConfig().then(function (c) {
            var info = $('dscDbCallInfo');
            if (info) {
                info.textContent = c.hasKey
                    ? T('対話：{0} · 認識：{1} · 合成：{2}', c.chatModel, c.asrModel, c.ttsModel)
                    : T('⚠️ 先に設定で豆包 API Key を入力してください');
            }
        }).catch(function () {});
        openModal('dscDbCallOverlay');
    }

    // ---- 通话模式专属面板：RTC 走服务端任务编排 ----
    function renderCallExtra(mode) {
        var box = $('dscDbCallExtra');
        if (!box) return;
        var sel = $('dscDbCallMode');
        var m = mode || (sel && sel.value) || readCallMode();
        while (box.firstChild) box.removeChild(box.firstChild);
        if (m !== 'rtc') return;

        var cfg = S.cfg || {};
        var hint = el('div', 'dsc-db-hint');
        hint.textContent = T('RTC はサーバー側で音声エージェントを起動します。ブラウザで実際に通話するには公式 RTC Web SDK で同じルームに参加してください（本アプリには同梱していません）。');
        box.appendChild(hint);

        var row1 = el('div', 'dsc-db-call-textrow');
        row1.appendChild(field(T('ルーム ID'), input('dscDbRtcRoom', 'text', 'RTC のルーム ID', cfg.rtcRoomId || '')));
        row1.appendChild(field(T('ユーザー ID'), input('dscDbRtcUser', 'text', '例：dsc_user', 'dsc_user')));
        box.appendChild(row1);

        var row2 = el('div', 'dsc-db-call-textrow');
        var mixWrap = el('label', 'dsc-db-check');
        var mix = document.createElement('input');
        mix.type = 'checkbox';
        mix.id = 'dscDbRtcMixed';
        mixWrap.appendChild(mix);
        mixWrap.appendChild(document.createTextNode(' ' + T('混合編成（外掛け LLM でツール／視覚を担当）')));
        row1.appendChild(mixWrap);
        row2.appendChild(field(T('音色 ID'), input('dscDbRtcVoice', 'text', '空欄なら既定', cfg.duplexVoice || cfg.voice || '')));
        box.appendChild(row2);

        var acts = el('div', 'dsc-db-call-actions');
        var bStart = el('button', 'dsc-db-btn primary', T('RTC タスクを起動'));
        bStart.type = 'button';
        bStart.id = 'dscDbRtcStart';
        var bStop = el('button', 'dsc-db-btn danger', T('RTC タスクを停止'));
        bStop.type = 'button';
        bStop.id = 'dscDbRtcStop';
        var bProbe = el('button', 'dsc-db-btn', T('状態を確認'));
        bProbe.type = 'button';
        bProbe.id = 'dscDbRtcProbe';
        acts.appendChild(bStart);
        acts.appendChild(bStop);
        acts.appendChild(bProbe);
        box.appendChild(acts);

        var out = el('div', 'dsc-db-hint');
        out.id = 'dscDbRtcOut';
        out.textContent = T('未起動');
        box.appendChild(out);

        if (window.dscRtc) window.dscRtc.bind(addBubble, setCallStatus);

        function val(id) {
            var n = $(id);
            return n ? String(n.value || '').trim() : '';
        }

        bStart.addEventListener('click', async function () {
            if (!window.dscRtc) { addBubble('sys', T('RTC モジュールが読み込まれていません')); return; }
            if (!val('dscDbRtcRoom')) { addBubble('sys', T('ルーム ID を入力してください')); return; }
            bStart.disabled = true;
            try {
                var r = await window.dscRtc.start({
                    roomId: val('dscDbRtcRoom'),
                    userId: val('dscDbRtcUser') || 'dsc_user',
                    mixedMode: !!(mix && mix.checked),
                    voice: val('dscDbRtcVoice'),
                    lang: cfg.duplexLang || 'zh',
                    llmModel: cfg.chatModel || ''
                });
                if (out) out.textContent = (r && r.ok) ? ('TaskId: ' + r.taskId) : T('起動失敗');
            } finally {
                bStart.disabled = false;
            }
        });

        bStop.addEventListener('click', async function () {
            if (!window.dscRtc) return;
            var r = await window.dscRtc.stop();
            if (out) out.textContent = (r && r.ok) ? T('待機中') : T('停止する RTC タスクがありません');
        });

        bProbe.addEventListener('click', async function () {
            if (!window.dscRtc) return;
            var d = await window.dscRtc.probe();
            var info = (d && d.rtc) || {};
            if (info.available) {
                addBubble('sys', T('RTC 設定は就緒しています（AppId: {0}）', info.appId || '-'));
            } else {
                // 服务端给的是「未設定：A / B」形式，去掉日文前缀后按当前语言显示
                var rs = String(info.reason || '').replace(/^未設定：/, '');
                addBubble('sys', T('RTC 設定が不足しています：{0}',
                    rs || T('不明なエラー')));
            }
            var dp = (d && d.duplex) || {};
            addBubble('sys', dp.available
                ? T('Seeduplex は就緒しています')
                : T('Seeduplex 未設定：{0}', T(String(dp.reason || '')) || T('不明なエラー')));
        });
    }

    function buildCallModal() {
        var md = buildModal('dscDbCallOverlay', '📞', '豆包音声通話',
            'マイクに向かって話すと、豆包が認識→応答→読み上げまで行います。');
        var info = el('div', 'dsc-db-hint');
        info.id = 'dscDbCallInfo';
        md.appendChild(info);

        var bodyEl = el('div', 'dsc-db-call-body');
        var orb = el('div', 'dsc-db-call-orb', '🎙️');
        orb.id = 'dscDbCallOrb';
        bodyEl.appendChild(orb);
        var status = el('div', 'dsc-db-call-status', T('待機中'));
        status.id = 'dscDbCallStatus';
        bodyEl.appendChild(status);
        var log = el('div', 'dsc-db-call-log');
        log.id = 'dscDbCallLog';
        bodyEl.appendChild(log);

        var modeRow = el('div', 'dsc-db-call-textrow');
        modeRow.appendChild(field('通話モード', select('dscDbCallMode', [
            { value: 'turn', label: T('ターン制（録音→認識→応答）') },
            { value: 'duplex', label: T('全双工 Seeduplex（低遅延）') },
            { value: 'rtc', label: T('RTC ルーム（サーバー起動）') }
        ], readCallMode())));
        bodyEl.appendChild(modeRow);
        var extra = el('div', 'dsc-db-call-extra');
        extra.id = 'dscDbCallExtra';
        bodyEl.appendChild(extra);
        renderCallExtra();

        // 弹窗每次打开都会重建 DOM，因此用事件委托挂在 bodyEl 上，
        // 并以 select 的当前值为准渲染，避免监听器随重建丢失。
        bodyEl.addEventListener('change', function (ev) {
            var t = ev.target;
            if (!t || t.id !== 'dscDbCallMode') return;
            writeCallMode(t.value);
            renderCallExtra(t.value);
            if (t.value === 'duplex') {
                addBubble('sys', T('全双工モードに切り替えました。開始を押すとそのまま繋がります。'));
            } else if (t.value === 'rtc') {
                addBubble('sys', T('RTC モードに切り替えました。ルーム ID を入れて起動してください。'));
            } else {
                addBubble('sys', T('ターン制モードに切り替えました。'));
            }
        });

        var actions = el('div', 'dsc-db-call-actions');
        var start = el('button', 'dsc-db-btn primary', T('通話を開始'));
        start.type = 'button';
        start.id = 'dscDbCallStart';
        var mic = el('button', 'dsc-db-btn', T('マイク ON'));
        mic.type = 'button';
        mic.id = 'dscDbCallMic';
        var hang = el('button', 'dsc-db-btn danger', T('通話を終了'));
        hang.type = 'button';
        hang.id = 'dscDbCallHang';
        var cxl = el('button', 'dsc-db-btn', T('割り込み'));
        cxl.type = 'button';
        cxl.id = 'dscDbCallCancel';
        actions.appendChild(start);
        actions.appendChild(mic);
        actions.appendChild(cxl);
        actions.appendChild(hang);
        bodyEl.appendChild(actions);

        var textRow = el('div', 'dsc-db-call-textrow');
        var ti = input('dscDbCallText', 'text', '音声が使えない場合はここに入力');
        var tb = el('button', 'dsc-db-btn', T('送信'));
        tb.type = 'button';
        tb.id = 'dscDbCallSend';
        textRow.appendChild(ti);
        textRow.appendChild(tb);
        bodyEl.appendChild(textRow);
        md.appendChild(bodyEl);

        var foot = el('div', 'dsc-db-footer');
        var close = el('button', 'dsc-db-btn', T('閉じる'));
        close.type = 'button';
        foot.appendChild(close);
        md.appendChild(foot);
        close.addEventListener('click', function () { closeModal('dscDbCallOverlay'); });

        start.addEventListener('click', startCall);
        hang.addEventListener('click', function () {
            stopCall();
            addBubble('sys', T('通話を終了しました'));
            setCallStatus(T('待機中'), '');
        });
        mic.addEventListener('click', toggleMic);
        cxl.addEventListener('click', function () {
            if (S.call && S.call.duplex && window.dscDuplex) {
                window.dscDuplex.cancel();
                addBubble('sys', T('応答を割り込みました'));
            } else {
                toast(T('全双工モードでのみ使用できます'), 'info');
            }
        });
        tb.addEventListener('click', function () {
            var v = (($('dscDbCallText') || {}).value || '').trim();
            if (!v) return;
            $('dscDbCallText').value = '';
            if (S.call && S.call.duplex && window.dscDuplex) {
                window.dscDuplex.sendText(v);
                return;
            }
            sendCallTurn(null, v);
        });
    }

    function setCallStatus(text, cls) {
        var n = $('dscDbCallStatus');
        if (n) n.textContent = text;
        var orb = $('dscDbCallOrb');
        if (orb) {
            orb.className = 'dsc-db-call-orb' + (cls ? ' ' + cls : '');
        }
    }

    function addBubble(kind, text) {
        var log = $('dscDbCallLog');
        if (!log) return;
        var b = el('div', 'dsc-db-bubble ' + kind, text);
        log.appendChild(b);
        log.scrollTop = log.scrollHeight;
    }

    var CALL_MODE_KEY = 'dsc_doubao_call_mode';

    function readCallMode() {
        try {
            var v = localStorage.getItem(CALL_MODE_KEY);
            return (v === 'duplex' || v === 'rtc') ? v : 'turn';
        } catch (e) { return 'turn'; }
    }

    function writeCallMode(m) {
        try { localStorage.setItem(CALL_MODE_KEY, (m === 'duplex' || m === 'rtc') ? m : 'turn'); } catch (e) {}
    }

    function newCallState() {
        return {
            active: false,
            duplex: false,
            rtc: false,
            stream: null,
            ctx: null,
            analyser: null,
            recorder: null,
            chunks: [],
            recording: false,
            voiceFrames: 0,
            silenceMs: 0,
            loopTimer: null,
            audio: null,
            playing: false,
            thinking: false,
            micOn: true,
            history: []
        };
    }

    async function startCall() {
        if (S.call && S.call.active) return;
        var modeNow = (($('dscDbCallMode') || {}).value) || readCallMode();
        if (modeNow === 'rtc') {
            if (!window.dscRtc) {
                addBubble('sys', T('RTC モジュールが読み込まれていません'));
                return;
            }
            var room0 = (($('dscDbRtcRoom') || {}).value || '').trim();
            if (!room0) {
                addBubble('sys', T('ルーム ID を入力してください'));
                return;
            }
            S.call = newCallState();
            S.call.active = true;
            S.call.rtc = true;
            window.dscRtc.bind(addBubble, setCallStatus);
            var r0 = await window.dscRtc.start({
                roomId: room0,
                userId: (($('dscDbRtcUser') || {}).value || 'dsc_user').trim(),
                mixedMode: !!((($('dscDbRtcMixed') || {}).checked)),
                voice: (($('dscDbRtcVoice') || {}).value || '').trim(),
                lang: ((S.cfg || {}).duplexLang || 'zh'),
                llmModel: ((S.cfg || {}).chatModel || '')
            });
            var out0 = $('dscDbRtcOut');
            if (out0) out0.textContent = (r0 && r0.ok) ? ('TaskId: ' + r0.taskId) : T('起動失敗');
            return;
        }
        if (modeNow === 'duplex') {
            if (!window.dscDuplex) {
                toast(T('全双工モジュールが読み込まれていません'), 'error');
                return;
            }
            S.call = newCallState();
            S.call.active = true;
            S.call.duplex = true;
            S.call.micOn = true;
            S.call.history = [];
            await window.dscDuplex.start();
            return;
        }
        S.call = newCallState();
        var c = S.call;
        addBubble('sys', T('マイクへのアクセスを要求しています…'));
        try {
            c.stream = await navigator.mediaDevices.getUserMedia({ audio: true });
        } catch (e) {
            addBubble('sys', T('マイクを使用できません：{0}。下の入力欄から送信できます。', e.message || e));
            setCallStatus(T('マイク使用不可'), '');
            c.active = true;
            return;
        }
        try {
            var AC = window.AudioContext || window.webkitAudioContext;
            c.ctx = new AC();
            var src = c.ctx.createMediaStreamSource(c.stream);
            c.analyser = c.ctx.createAnalyser();
            c.analyser.fftSize = 1024;
            src.connect(c.analyser);
        } catch (e) { /* VAD なしでも録音は可能 */ }
        c.active = true;
        c.micOn = true;
        addBubble('sys', T('通話を開始しました。話しかけてください。'));
        setCallStatus(T('聞き取り中…'), 'listening');
        c.loopTimer = setInterval(callLoop, 300);
    }

    function stopCall() {
        var c = S.call;
        if (!c) return;
        if (c.rtc && window.dscRtc) {
            try { window.dscRtc.stop(); } catch (e) {}
        }
        if (c.duplex && window.dscDuplex) {
            try { window.dscDuplex.stop(); } catch (e) {}
        }
        c.duplex = false;
        c.active = false;
        if (c.loopTimer) { clearInterval(c.loopTimer); c.loopTimer = null; }
        try { if (c.recorder && c.recording) c.recorder.stop(); } catch (e) {}
        c.recording = false;
        try { if (c.stream) c.stream.getTracks().forEach(function (t) { t.stop(); }); } catch (e) {}
        c.stream = null;
        try { if (c.ctx && c.ctx.close) c.ctx.close(); } catch (e) {}
        c.ctx = null;
        try { if (c.audio) { c.audio.pause(); c.audio.src = ''; } } catch (e) {}
        c.audio = null;
        c.playing = false;
        c.thinking = false;
    }

    function toggleMic() {
        var c = S.call;
        if (c && c.duplex && window.dscDuplex) {
            var on = window.dscDuplex.setMic(!c.micOn);
            c.micOn = on;
            var mb = $('dscDbCallMic');
            if (mb) {
                mb.textContent = on ? T('マイク ON') : T('マイク OFF');
                mb.classList.toggle('dsc-db-mic-off', !on);
            }
            return;
        }
        if (!c || !c.stream) { toast(T('通話を開始してください'), 'info'); return; }
        c.micOn = !c.micOn;
        try { c.stream.getAudioTracks().forEach(function (t) { t.enabled = c.micOn; }); } catch (e) {}
        if (!c.micOn && c.recording) { try { c.recorder.stop(); } catch (e) {} }
        var b = $('dscDbCallMic');
        if (b) {
            b.textContent = c.micOn ? T('マイク ON') : T('マイク OFF');
            b.classList.toggle('dsc-db-mic-off', !c.micOn);
        }
        setCallStatus(c.micOn ? T('聞き取り中…') : T('ミュート中'), c.micOn ? 'listening' : '');
    }

    function callLoop() {
        var c = S.call;
        if (!c || !c.active) return;
        if (c.playing || c.thinking || !c.micOn || !c.analyser || c.recording) return;
        var buf = new Uint8Array(c.analyser.fftSize);
        c.analyser.getByteTimeDomainData(buf);
        var sum = 0;
        for (var i = 0; i < buf.length; i++) {
            var v = (buf[i] - 128) / 128;
            sum += v * v;
        }
        var rms = Math.sqrt(sum / buf.length);
        if (rms > 0.055) {
            c.voiceFrames++;
            if (c.voiceFrames >= 2 && !c.recording) {
                startRec();
            }
        } else {
            c.voiceFrames = 0;
            if (c.recording) {
                c.silenceMs += 300;
                if (c.silenceMs >= 900) stopRec();
            }
        }
    }

    function startRec() {
        var c = S.call;
        if (!c || !c.stream || c.recording) return;
        var options = {};
        try {
            var mimes = ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4', 'audio/ogg;codecs=opus'];
            for (var i = 0; i < mimes.length; i++) {
                if (window.MediaRecorder && MediaRecorder.isTypeSupported && MediaRecorder.isTypeSupported(mimes[i])) {
                    options.mimeType = mimes[i];
                    break;
                }
            }
            c.recorder = new MediaRecorder(c.stream, options);
        } catch (e) {
            try { c.recorder = new MediaRecorder(c.stream); } catch (e2) { return; }
        }
        c.chunks = [];
        c.silenceMs = 0;
        c.recorder.ondataavailable = function (ev) {
            if (ev.data && ev.data.size > 0) c.chunks.push(ev.data);
        };
        c.recorder.onstop = function () {
            var mime = (c.recorder && c.recorder.mimeType) || 'audio/webm';
            var blob = new Blob(c.chunks, { type: mime });
            c.chunks = [];
            c.recording = false;
            c.silenceMs = 0;
            if (blob.size > 1200 && c.active) sendCallTurn(blob, '');
        };
        try {
            c.recorder.start(200);
            c.recording = true;
            setCallStatus(T('聞き取り中…'), 'listening');
        } catch (e) {
            c.recording = false;
        }
    }

    function stopRec() {
        var c = S.call;
        if (!c || !c.recorder || !c.recording) return;
        try { c.recorder.stop(); } catch (e) { c.recording = false; }
    }

    function blobToBase64(blob) {
        return new Promise(function (resolve, reject) {
            var r = new FileReader();
            r.onload = function () {
                var s = String(r.result || '');
                var i = s.indexOf(',');
                resolve(i >= 0 ? s.slice(i + 1) : '');
            };
            r.onerror = function () { reject(new Error('read error')); };
            r.readAsDataURL(blob);
        });
    }

    async function sendCallTurn(blob, text) {
        var c = S.call;
        if (!c || !c.active) return;
        if (c.thinking) return;
        c.thinking = true;
        setCallStatus(T('考えています…'), 'thinking');
        var body = {
            fileName: 'audio.webm',
            lang: lang(),
            voice: (S.cfg && S.cfg.voice) || '',
            model: (S.cfg && S.cfg.chatModel) || '',
            history: c.history.slice(-12)
        };
        try {
            if (blob) {
                var b64 = await blobToBase64(blob);
                if (!b64) throw new Error('音声の読み取りに失敗しました');
                body.audioBase64 = b64;
            } else {
                body.text = text;
            }
            var d = await api('/voice/turn', { method: 'POST', body: body });
            if (!c.active) return;
            if (d.userText) addBubble('user', d.userText);
            if (d.reply) addBubble('ai', d.reply);
            c.history.push({ role: 'user', content: d.userText || text || '' });
            c.history.push({ role: 'assistant', content: d.reply || '' });
            if (d.audioUrl) {
                playCallAudio(d.audioUrl);
            } else {
                setCallStatus(T('聞き取り中…'), 'listening');
            }
        } catch (e) {
            addBubble('sys', T('通話でエラー：{0}', e.message));
            setCallStatus(T('聞き取り中…'), 'listening');
        } finally {
            c.thinking = false;
        }
    }

    function playCallAudio(url) {
        var c = S.call;
        if (!c) return;
        try {
            if (c.audio) { c.audio.pause(); }
            c.audio = new Audio(url);
            c.playing = true;
            setCallStatus(T('読み上げ中…'), 'speaking');
            c.audio.onended = function () {
                c.playing = false;
                if (c.active) setCallStatus(T('聞き取り中…'), 'listening');
            };
            c.audio.onerror = function () {
                c.playing = false;
                addBubble('sys', T('音声の再生に失敗しました'));
                if (c.active) setCallStatus(T('聞き取り中…'), 'listening');
            };
            var p = c.audio.play();
            if (p && p.catch) {
                p.catch(function (e) {
                    c.playing = false;
                    addBubble('sys', T('自動再生がブロックされました：{0}', e.message || e));
                    setCallStatus(T('聞き取り中…'), 'listening');
                });
            }
        } catch (e) {
            c.playing = false;
            setCallStatus(T('聞き取り中…'), 'listening');
        }
    }

    // ------------------------------------------------------------
    // 豆包モード：左上の「＋」の左側に置くトグル
    //   ON  → 送信・続き生成のモデルを豆包の会話モデルへ差し替え（豆包 API のトークンを消費）
    //   OFF → 従来どおり DeepSeek API（モデルは設定の DeepSeek モデル）
    // ------------------------------------------------------------
    var DB_MODE_KEY = 'dsc_doubao_mode';

    function isDbMode() {
        try { return localStorage.getItem(DB_MODE_KEY) === '1'; } catch (e) { return false; }
    }

    function dbChatModel() {
        var m = (S.cfg && S.cfg.chatModel) ? String(S.cfg.chatModel).trim() : '';
        return m || 'doubao-seed-2-1-pro-260628';
    }

    // 他モジュール（deepseek-chat.js）から参照する公開 API
    //   ・豆包モード中か ・この値が豆包系モデルか
    window.dscDoubaoModeOn = function () { return isDbMode(); };
    window.dscIsDoubaoModelId = function (v) {
        v = String(v || '').trim();
        if (!v) return false;
        if (isDbModelValue(v)) return true;
        if (S.catalog && S.catalog.some(function (m) { return m.value === v; })) return true;
        return /^(doubao|glm|seed|volc)/i.test(v);
    };

    function syncDbModeUI() {
        var b = $('dscDbModeBtn');
        if (!b) return;
        var on = isDbMode();
        if (on) b.classList.add('active'); else b.classList.remove('active');
        b.setAttribute('aria-pressed', on ? 'true' : 'false');
        var lbl = b.querySelector('.dsc-db-mode-lbl');
        ensureDbModeIcon(lbl);
        // title は静的な文だけを翻訳対象にし、モデル値は識別子として連結する
        b.title = on
            ? T('豆包モード：オン（送信は豆包モデル）') + ' · ' + dbChatModel()
            : T('豆包モード：オフ（送信は DeepSeek）');
        b.setAttribute('aria-label', b.title);
    }

    function openDbSettings() {
        var sb = $('dscSettingsBtn');
        if (sb) sb.click();
        setTimeout(function () {
            var card = $('dscDbCard');
            if (card && card.scrollIntoView) {
                try { card.scrollIntoView({ block: 'center', behavior: 'smooth' }); }
                catch (e) { card.scrollIntoView(); }
            }
        }, 280);
    }

    function setDbMode(on, silent) {
        try { localStorage.setItem(DB_MODE_KEY, on ? '1' : '0'); } catch (e) {}
        syncDbModeUI();
        if (silent) return;
        if (on) {
            if (S.cfg && S.cfg.hasKey === false) {
                toast(T('⚠️ 豆包 API Key が未設定です。設定 → 豆包から入力してください'), 'error');
                openDbSettings();
            } else {
                toast(T('豆包モードをオンにしました（モデル：{0}）', dbChatModel()), 'success');
            }
        } else {
            toast(T('豆包モードをオフにしました（DeepSeek に戻ります）'), 'info');
        }
    }

    // 豆包モードのアイコン：絵文字に依存せず必ず表示されるようインライン SVG を使う
    //   （U+1FAD8 は Emoji 13.0 以降。古い端末フォントでは豆腐になるため使用しない）
    var DB_MODE_ICON_SVG =
        '<svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true" focusable="false">' +
        '<ellipse cx="12" cy="12" rx="8.4" ry="5.5" transform="rotate(-35 12 12)" fill="currentColor"/>' +
        '<path d="M8.4 8.2c1.3-1.8 3.7-2.5 5.9-1.9" stroke="#ffffff" stroke-width="1.7" ' +
        'stroke-linecap="round" stroke-linejoin="round" fill="none" opacity="0.9"/>' +
        '</svg>';

    function ensureDbModeIcon(lbl) {
        if (!lbl) return;
        if (lbl.querySelector('svg')) return;
        lbl.textContent = '';
        lbl.innerHTML = DB_MODE_ICON_SVG;
    }

    function injectDbModeButton() {
        var nb = $('dscNewBtn');
        if ($('dscDbModeBtn')) { syncDbModeUI(); return; }
        if (!nb || !nb.parentNode) return;
        var b = el('button', 'dsc-icon-btn dsc-db-mode-btn');
        b.id = 'dscDbModeBtn';
        b.type = 'button';
        var lbl0 = el('span', 'dsc-db-mode-lbl');
        ensureDbModeIcon(lbl0);
        b.appendChild(lbl0);
        b.addEventListener('click', function () { setDbMode(!isDbMode()); });
        nb.parentNode.insertBefore(b, nb);
        syncDbModeUI();
    }

    // 送信・続き生成のモデルだけを豆包へ差し替える（既存の送信実装は変更しない）
    function installFetchHook() {
        if (window.__dscDbFetchHooked) return;
        window.__dscDbFetchHooked = true;
        var orig = window.fetch;
        if (typeof orig !== 'function') return;
        window.fetch = function (input, init) {
            try {
                var url = (typeof input === 'string') ? input : ((input && input.url) || '');
                if (init && typeof init.body === 'string' &&
                    /\/api\/ds-chat\/(send|continue)(\?|$)/.test(url)) {
                    var body = JSON.parse(init.body);
                    if (body && typeof body === 'object') {
                        var cur = String(body.model || '');
                        if (isDbMode()) {
                            var want = dbChatModel();
                            if (cur !== want) {
                                body.__dscClientModel = cur;
                                body.model = want;
                                init = Object.assign({}, init, { body: JSON.stringify(body) });
                                console.log('[DB] 豆包モード送信: ' + (cur || '(なし)') + ' → ' + want);
                            }
                        } else if (isDbModelValue(cur)) {
                            // 豆包モードがオフなのに豆包モデルが残っている → DeepSeek へ戻す
                            var sel = $('dscModelSelect');
                            var fb = (sel && sel.value && !isDbModelValue(sel.value)) ? sel.value : 'deepseek-flash';
                            body.model = fb;
                            init = Object.assign({}, init, { body: JSON.stringify(body) });
                            console.log('[DB] 豆包モデルの残留を検出 → ' + fb + ' に戻しました');
                        }
                    }
                }
            } catch (e) { console.log('[DB] fetch hook error: ' + (e && e.message)); }
            return orig.call(this, input, init);
        };
    }

    // 旧版がバックエンド設定へ豆包モデルを保存していた場合の移行
    async function migrateLegacyModel() {
        try {
            var r = await fetch('/api/ds-chat/config', { cache: 'no-cache' });
            if (!r.ok) return;
            var d = await r.json();
            var m = (d && d.model) ? String(d.model) : '';
            if (!isDbModelValue(m)) return;
            await fetch('/api/ds-chat/config', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ model: 'deepseek-flash' })
            });
            try { localStorage.setItem('dsc_currentModel', 'deepseek-flash'); } catch (e) {}
            var sel = $('dscModelSelect');
            if (sel) sel.value = 'deepseek-flash';
            purgeLegacyChatModels();
            if (!isDbMode()) setDbMode(true, true);
            console.log('[DB] 旧設定の豆包モデル「' + m + '」を豆包モードへ移行しました');
        } catch (e) {}
    }

    // ------------------------------------------------------------
    // 起動処理
    // ------------------------------------------------------------
    function boot() {
        injectMenu();
        buildSettingsCard();
        injectDbModeButton();
        installFetchHook();
        // 言語切替時（再読込が無効化されている場合も）ボタンの title を追従させる
        document.addEventListener('dsc:langchange', function () {
            applyMenuLabels();   // メニュー文言の残留防止
            syncDbModeUI();      // 豆包モードボタンの title 追従
        });
        purgeLegacyChatModels();
        loadConfig().then(function () {
            renderModelList();
            fillCfgForm();
            purgeLegacyChatModels();
            syncDbModeUI();
            migrateLegacyModel();
        }).catch(function (e) {
            console.log('[DB] config load failed:', e.message);
            migrateLegacyModel();
        });
        // 設定を開くたびに最新化
        var sbtn = $('dscSettingsBtn');
        if (sbtn) {
            sbtn.addEventListener('click', function () {
                buildSettingsCard();
                loadConfig(true).then(function () {
                    fillCfgForm();
                    purgeLegacyChatModels();
                    syncDbModeUI();
                }).catch(function () {});
            });
        }
        // 送信完了時に豆包ルーティングを通知（deepseek-chat.js から呼ばれる）
        window.dscDoubaoRouteToast = function (payload) {
            try {
                if (!payload || !payload.doubaoRoute) return;
                var r = payload.doubaoRoute;
                if (!r.routed) return;
                toast(T('🔀 録音ファイルを検出したため豆包へ自動ルーティングしました（{0}）', r.to || ''), 'info');
            } catch (e) {}
        };
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', boot);
    } else {
        boot();
    }
})();
