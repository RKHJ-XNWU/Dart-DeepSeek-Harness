/* ============================================================
   ds-devtools.js
   開発者ツール：プロンプトを「ユーザーメッセージ」に注入する。
   注入後、次にメッセージを送信すると、バックエンドがプロンプトをユーザー入力の前に付けて DeepSeek へ送る。
   チャット画面や会話 .sts には注入内容は表示されない。
   ============================================================ */
(function () {
    'use strict';
    console.log('[DSDT] 開発者ツールのスクリプトを読み込み中...');

    var API_BASE = '/api/ds-devtools';

    // ★ i18n：多言語時に日本語が混在しないよう UI 文言はここを通す
    function T(s) {
        try {
            var a = Array.prototype.slice.call(arguments, 1);
            return (window.I18N && window.I18N.t) ? window.I18N.t.apply(window.I18N, [s].concat(a)) : s;
        } catch (e) { return s; }
    }
    var MENU_ENTRY_ID = 'dsdtMenuEntry';
    var STORAGE_KEY = 'dsdt_active_inject_ids';

    var state = {
        prompts: [],
        activeIds: {},       // id -> true。「注入済み」状態のプロンプト
        selectMode: false,
        checkedIds: {},
        editingId: null,
        inListMode: false,
        loaded: false
    };

    function $(id) { return document.getElementById(id); }

    function escapeHtml(s) {
        return String(s == null ? '' : s).replace(/[&<>"']/g, function (m) {
            return {
                '&': '&amp;', '<': '&lt;', '>': '&gt;',
                '"': '&quot;', "'": '&#39;'
            }[m];
        });
    }

    function toast(msg, type) {
        var wrap = document.getElementById('dscToastWrap');
        if (!wrap) { console.log('[DSDT]', msg); return; }
        var el = document.createElement('div');
        el.className = 'dsc-toast ' + (type || '');
        el.textContent = msg;
        wrap.appendChild(el);
        setTimeout(function () { el.remove(); }, 2600);
    }

    function api(method, url, body) {
        var opts = {
            method: method,
            headers: { 'Content-Type': 'application/json' }
        };
        if (body) opts.body = JSON.stringify(body);
        return fetch(url, opts).then(function (res) {
            return res.json().catch(function () { return {}; }).then(function (data) {
                if (!res.ok) throw new Error(data.error || ('リクエスト失敗 ' + res.status));
                return data;
            });
        });
    }

    function formatTime(iso) {
        if (!iso) return '';
        try {
            var d = new Date(iso);
            if (isNaN(d.getTime())) return iso;
            var pad = function (n) { return String(n).padStart(2, '0'); };
            return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) +
                ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
        } catch (e) { return iso; }
    }

    // ============================================================
    // 注入状態を localStorage に永続化（id のみ保存し、サーバーに注入内容を知られないようにする）
    // ============================================================
    function loadActiveIds() {
        try {
            var raw = localStorage.getItem(STORAGE_KEY);
            if (!raw) return {};
            var arr = JSON.parse(raw);
            var map = {};
            if (Array.isArray(arr)) {
                arr.forEach(function (id) { if (id) map[id] = true; });
            }
            return map;
        } catch (e) { return {}; }
    }

    function saveActiveIds() {
        try {
            localStorage.setItem(STORAGE_KEY,
                JSON.stringify(Object.keys(state.activeIds)));
        } catch (e) {}
    }

    // 既に存在しないプロンプトの注入状態を整理
    function pruneActiveIds() {
        var valid = {};
        state.prompts.forEach(function (p) {
            if (state.activeIds[p.id]) valid[p.id] = true;
        });
        state.activeIds = valid;
        saveActiveIds();
    }

    // ============================================================
    // ★ 对外暴露：拿現在「已注入」的プロンプト内容列表
    // deepseek-chat.js の送信時に呼ばれ、内容をユーザー入力の前に連結する
    // ============================================================
    window.__dsDevToolsGetInjectedContents = function () {
        if (!state.prompts || state.prompts.length === 0) return [];
        var out = [];
        state.prompts.forEach(function (p) {
            if (state.activeIds[p.id] && p.content) {
                out.push(p.content);
            }
        });
        return out;
    };

    // ============================================================
    // ダイアログの構築
    // ============================================================
    function ensureModal() {
        if ($('dsdtOverlay')) return;

        var overlay = document.createElement('div');
        overlay.id = 'dsdtOverlay';
        overlay.className = 'dsdt-overlay';
        overlay.innerHTML =
            '<div class="dsdt-modal">' +
                '<div class="dsdt-header">' +
                    '<div class="dsdt-title"><span>🛠️</span><span>開発者ツール</span></div>' +
                    '<button class="dsdt-close" id="dsdtClose" type="button" title="閉じる">✕</button>' +
                '</div>' +
                '<div class="dsdt-warn">' +
                    '<span class="ic">⚠️</span>' +
                    '<div><b>警告：これは開発者ツールであり、開発環境でのみ使用できます。</b><br>' +
                    '注入したプロンプトは送信メッセージの前に付加されて DeepSeek に送られます。' +
                    'チャット画面とセッション履歴には表示されません。</div>' +
                '</div>' +
                '<div class="dsdt-body" id="dsdtBody"></div>' +
            '</div>';

        document.body.appendChild(overlay);

        overlay.addEventListener('click', function (e) {
            if (e.target === overlay) closeModal();
        });
        overlay.querySelector('#dsdtClose').addEventListener('click', closeModal);
    }

    // ============================================================
    // 入口ビュー
    // ============================================================
    function renderEntry() {
        state.inListMode = false;
        state.selectMode = false;
        state.checkedIds = {};
        state.editingId = null;

        var body = $('dsdtBody');
        if (!body) return;

        var activeCount = Object.keys(state.activeIds).length;

        var banner = '';
        if (activeCount > 0) {
            banner =
                '<div class="dsdt-active-banner">' +
                    '<span class="ic">💉</span>' +
                    '<div>現在注入中 <b>' + activeCount + '</b> 件のプロンプト、' +
                    '次回メッセージ送信時に反映されます</div>' +
                '</div>';
        }

        body.innerHTML =
            banner +
            '<button class="dsdt-enter-btn" id="dsdtEnterBtn" type="button">' +
                '<span class="ic">💉</span><span>プロンプトを注入</span>' +
            '</button>' +
            '<div class="dsdt-hint">' +
                '開いたあとプロンプトをタップで注入／もう一度タップで解除<br>' +
                '追加・編集・削除・一括削除・すべて削除に対応' +
            '</div>';

        var btn = $('dsdtEnterBtn');
        if (btn) btn.addEventListener('click', enterListMode);
    }

    function enterListMode() {
        state.inListMode = true;
        loadPrompts();
    }

    // ============================================================
    // 一覧の読み込みと描画
    // ============================================================
    function loadPrompts() {
        var body = $('dsdtBody');
        if (!body) return;
        body.innerHTML = '<div class="dsdt-empty"><span class="emoji">⏳</span>' + T('読み込み中...') + '</div>';

        api('GET', API_BASE + '/prompts').then(function (data) {
            state.prompts = data.prompts || [];
            state.loaded = true;
            pruneActiveIds();
            renderList();
        }).catch(function (e) {
            body.innerHTML =
                '<div class="dsdt-empty"><span class="emoji">❌</span>' +
                escapeHtml(e.message) + '</div>';
        });
    }

    function renderList() {
        var body = $('dsdtBody');
        if (!body) return;

        var checkedCount = Object.keys(state.checkedIds).length;
        var activeCount = Object.keys(state.activeIds).length;

        var html = '';

        if (activeCount > 0) {
            html += '<div class="dsdt-active-banner">' +
                        '<span class="ic">💉</span>' +
                        '<div>注入済み <b>' + activeCount + '</b> 件。次回メッセージ送信時に反映されます</div>' +
                    '</div>';
        }

        html += '<div class="dsdt-toolbar">';
        html += '<button class="dsdt-btn primary" id="dsdtAddBtn" type="button">＋ 追加</button>';
        html += '<button class="dsdt-btn" id="dsdtSelectBtn" type="button">' +
                    (state.selectMode ? '✕ 複数選択を終了' : '☑️ 複数選択') + '</button>';
        if (state.selectMode) {
            html += '<button class="dsdt-btn danger" id="dsdtBatchDelBtn" type="button" ' +
                        (checkedCount === 0 ? 'disabled' : '') +
                    '>🗑️ 選択を削除(' + checkedCount + ')</button>';
        }
        html += '<button class="dsdt-btn danger" id="dsdtClearAllBtn" type="button">🧹 すべて削除</button>';
        html += '<button class="dsdt-btn ghost" id="dsdtBackBtn" type="button">← 戻る</button>';
        html += '</div>';

        if (state.prompts.length === 0) {
            html += '<div class="dsdt-empty">' +
                        '<span class="emoji">📭</span>' +
                        'プロンプトがありません。「＋ 追加」から追加してください' +
                    '</div>';
        } else {
            html += '<div class="dsdt-list">';
            state.prompts.forEach(function (p, i) {
                var isChecked = !!state.checkedIds[p.id];
                var isActive = !!state.activeIds[p.id];

                var cls = 'dsdt-item';
                if (state.selectMode && isChecked) cls += ' checked';
                if (!state.selectMode && isActive) cls += ' injected';

                html += '<div class="' + cls + '" data-id="' + escapeHtml(p.id) + '">';

                if (state.selectMode) {
                    html += '<div class="dsdt-check" data-check="1"></div>';
                    html += '<div class="dsdt-item-main">' +
                                '<div class="dsdt-item-title">#' + (i + 1) + ' · ' +
                                    escapeHtml(p.title || '無題') + '</div>' +
                                '<div class="dsdt-item-content">' +
                                    escapeHtml(p.content || '') + '</div>' +
                            '</div>';
                } else {
                    html += '<div class="dsdt-item-main">' +
                                '<div class="dsdt-item-title">#' + (i + 1) + ' · ' +
                                    escapeHtml(p.title || '無題');
                    if (isActive) {
                        html += '<span class="dsdt-badge">💉 注入済み</span>';
                    }
                    html += '</div>' +
                            '<div class="dsdt-item-content">' +
                                escapeHtml(p.content || '') + '</div>' +
                            '<div class="dsdt-item-time">' +
                                escapeHtml(formatTime(p.createdAt)) + '</div>' +
                        '</div>' +
                        '<div class="dsdt-item-actions">' +
                            '<button class="dsdt-icon-btn" data-act="edit" title="編集">✏️</button>' +
                            '<button class="dsdt-icon-btn danger" data-act="del" title="削除">✕</button>' +
                        '</div>';
                }

                html += '</div>';
            });
            html += '</div>';
        }

        body.innerHTML = html;
        bindListEvents();
    }

    function bindListEvents() {
        var addBtn = $('dsdtAddBtn');
        if (addBtn) addBtn.addEventListener('click', function () { renderEditor(null); });

        var backBtn = $('dsdtBackBtn');
        if (backBtn) backBtn.addEventListener('click', renderEntry);

        var selBtn = $('dsdtSelectBtn');
        if (selBtn) selBtn.addEventListener('click', function () {
            state.selectMode = !state.selectMode;
            if (!state.selectMode) state.checkedIds = {};
            renderList();
        });

        var batchDel = $('dsdtBatchDelBtn');
        if (batchDel) batchDel.addEventListener('click', function () {
            var ids = Object.keys(state.checkedIds);
            if (ids.length === 0) { toast('先にプロンプトを選択してください', 'info'); return; }
            if (!window.confirm('選択した ' + ids.length + ' 件のプロンプトですか？')) return;

            api('POST', API_BASE + '/prompts/batch-delete', { ids: ids })
                .then(function (data) {
                    state.checkedIds = {};
                    toast('✅ 削除しました：' + (data.deleted || ids.length) + ' 件', 'success');
                    loadPrompts();
                })
                .catch(function (e) {
                    toast('一括削除に失敗: ' + e.message, 'error');
                });
        });

        var clearAll = $('dsdtClearAllBtn');
        if (clearAll) clearAll.addEventListener('click', function () {
            if (state.prompts.length === 0) { toast('プロンプトなし', 'info'); return; }
            if (!window.confirm('すべての ' + state.prompts.length +
                ' 件のプロンプトですか？この操作は元に戻せません！')) return;

            api('DELETE', API_BASE + '/prompts?all=true')
                .then(function () {
                    state.checkedIds = {};
                    state.selectMode = false;
                    state.activeIds = {};
                    saveActiveIds();
                    toast('✅ すべてのプロンプトを消去しました', 'success');
                    loadPrompts();
                })
                .catch(function (e) {
                    toast('消去に失敗: ' + e.message, 'error');
                });
        });

        var items = document.querySelectorAll('#dsdtBody .dsdt-item');
        items.forEach(function (item) {
            var id = item.getAttribute('data-id');

            item.addEventListener('click', function (e) {
                if (e.target.closest('[data-act]')) return;

                // 複数選択モード：チェックの切替
                if (state.selectMode) {
                    if (state.checkedIds[id]) delete state.checkedIds[id];
                    else state.checkedIds[id] = true;
                    renderList();
                    return;
                }

                // 通常モード：注入の切替
                var p = state.prompts.find(function (x) { return x.id === id; });
                if (!p) return;

                if (state.activeIds[id]) {
                    delete state.activeIds[id];
                    saveActiveIds();
                    renderList();
                    toast('注入を解除：' + (p.title || '無題'), 'info');
                } else {
                    state.activeIds[id] = true;
                    saveActiveIds();
                    renderList();
                    toast('💉 注入済み：' + (p.title || '無題'), 'success');
                }
            });

            var editBtn = item.querySelector('[data-act="edit"]');
            if (editBtn) editBtn.addEventListener('click', function (e) {
                e.stopPropagation();
                var p = state.prompts.find(function (x) { return x.id === id; });
                if (p) renderEditor(p);
            });

            var delBtn = item.querySelector('[data-act="del"]');
            if (delBtn) delBtn.addEventListener('click', function (e) {
                e.stopPropagation();
                var p = state.prompts.find(function (x) { return x.id === id; });
                if (!p) return;
                if (!window.confirm('「' + (p.title || '無題') + '」を削除しますか？')) return;

                api('DELETE', API_BASE + '/prompts?id=' + encodeURIComponent(id))
                    .then(function () {
                        if (state.activeIds[id]) {
                            delete state.activeIds[id];
                            saveActiveIds();
                        }
                        toast('✅ 削除しました', 'success');
                        loadPrompts();
                    })
                    .catch(function (err) {
                        toast('削除に失敗: ' + err.message, 'error');
                    });
            });
        });
    }

    // ============================================================
    // 編集器
    // ============================================================
    function renderEditor(prompt) {
        var body = $('dsdtBody');
        if (!body) return;

        var isEdit = !!prompt;
        state.editingId = isEdit ? prompt.id : null;

        body.innerHTML =
            '<div class="dsdt-field">' +
                '<label>📌 タイトル</label>' +
                '<input type="text" id="dsdtEditTitle" maxlength="80" ' +
                    'placeholder="例：第一項 / 挨拶" ' +
                    'value="' + escapeHtml(isEdit ? (prompt.title || '') : '') + '">' +
            '</div>' +
            '<div class="dsdt-field">' +
                '<label>💬 プロンプト内容（送信メッセージの前に付加されます）</label>' +
                '<textarea id="dsdtEditContent" maxlength="8000" ' +
                    'placeholder="例：こんにちは / 皆さんこんにちは">' +
                    escapeHtml(isEdit ? (prompt.content || '') : '') +
                '</textarea>' +
            '</div>' +
            '<div class="dsdt-footer">' +
                '<button class="dsdt-btn ghost" id="dsdtEditCancel" type="button">キャンセル</button>' +
                '<button class="dsdt-btn primary" id="dsdtEditSave" type="button">💾 保存</button>' +
            '</div>';

        var cancelBtn = $('dsdtEditCancel');
        if (cancelBtn) cancelBtn.addEventListener('click', function () {
            state.editingId = null;
            renderList();
        });

        var saveBtn = $('dsdtEditSave');
        if (saveBtn) saveBtn.addEventListener('click', function () {
            var titleEl = $('dsdtEditTitle');
            var contentEl = $('dsdtEditContent');
            var title = (titleEl ? titleEl.value : '').trim();
            var content = (contentEl ? contentEl.value : '').trim();

            if (!content) {
                toast('プロンプト内容を入力してください', 'info');
                if (contentEl) contentEl.focus();
                return;
            }

            var payload = { title: title || '無題', content: content };
            if (state.editingId) payload.id = state.editingId;

            api('POST', API_BASE + '/prompts', payload)
                .then(function () {
                    toast(isEdit ? '✅ 保存しました' : '✅ 追加しました', 'success');
                    state.editingId = null;
                    loadPrompts();
                })
                .catch(function (e) {
                    toast('保存に失敗: ' + e.message, 'error');
                });
        });

        setTimeout(function () {
            var el = isEdit ? $('dsdtEditContent') : $('dsdtEditTitle');
            if (el) { el.focus(); if (isEdit && el.select) el.select(); }
        }, 100);
    }

    // ============================================================
    // ダイアログ制御
    // ============================================================
    function openModal() {
        ensureModal();
        var overlay = $('dsdtOverlay');
        if (!overlay) return;
        overlay.classList.add('open');
        if (!state.inListMode) {
            renderEntry();
        } else if (state.loaded) {
            renderList();
        } else {
            loadPrompts();
        }
    }

    function closeModal() {
        var overlay = $('dsdtOverlay');
        if (overlay) overlay.classList.remove('open');
    }

    // ============================================================
    // ＋メニューへ注入
    // ============================================================
    function injectMenuItem() {
        var menu = document.getElementById('dscPlusMenu');
        if (!menu) return false;
        if (menu.querySelector('#' + MENU_ENTRY_ID)) return true;

        var btn = document.createElement('button');
        btn.id = MENU_ENTRY_ID;
        btn.type = 'button';
        btn.className = 'dsc-menu-item';
        // ファイル選択を発火させない種別値を意図的に使う
        btn.dataset.type = '__devtools__';
        btn.innerHTML =
            '<span class="menu-icon">🛠️</span>' +
            '<div class="menu-info">' +
                '<div class="menu-title">開発者ツール</div>' +
                '<div class="menu-desc">プロンプト注入 · 開発環境限定</div>' +
            '</div>';

        // 捕捉段階で遮断し、ファイル選択の発火を防ぐ
        btn.addEventListener('click', function (e) {
            e.stopPropagation();
            e.preventDefault();

            var plusMenu = document.getElementById('dscPlusMenu');
            var plusBtn = document.getElementById('dscPlusBtn');
            if (plusMenu) plusMenu.classList.remove('open');
            if (plusBtn) plusBtn.classList.remove('active');

            openModal();
        }, true);

        menu.insertBefore(btn, menu.firstChild);
        console.log('[DSDT] ✅ + メニューに「開発者ツール」を追加しました');
        return true;
    }

    // ============================================================
    // 初始化
    // ============================================================
    function bootstrap() {
        state.activeIds = loadActiveIds();

        // 注入済みのプロンプトがあれば、先にプロンプト一覧を取得しておき、
        // これにより window.__dsDevToolsGetInjectedContents() が内容を取得できる
        if (Object.keys(state.activeIds).length > 0) {
            api('GET', API_BASE + '/prompts').then(function (data) {
                state.prompts = data.prompts || [];
                state.loaded = true;
                pruneActiveIds();
                console.log('[DSDT] 注入状態を復元 ' +
                    Object.keys(state.activeIds).length + ' 件');
            }).catch(function () {});
        }
    }

    function init() {
        bootstrap();
        injectMenuItem();

        var tries = 0;
        var timer = setInterval(function () {
            tries++;
            if (injectMenuItem() || tries > 60) clearInterval(timer);
        }, 250);

        try {
            var observer = new MutationObserver(function () { injectMenuItem(); });
            observer.observe(document.body, { childList: true, subtree: true });
        } catch (e) {}

        document.addEventListener('keydown', function (e) {
            var ov = $('dsdtOverlay');
            if (!ov || !ov.classList.contains('open')) return;
            if (e.key === 'Escape') {
                if (state.editingId !== null && state.inListMode) {
                    state.editingId = null;
                    renderList();
                } else if (state.selectMode) {
                    state.selectMode = false;
                    state.checkedIds = {};
                    renderList();
                } else {
                    closeModal();
                }
            }
        });

        window.__openDsDevTools = openModal;
        window.__closeDsDevTools = closeModal;

        console.log('[DSDT] ✅ 開発者ツールの初期化が完了しました');
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();