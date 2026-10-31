/* ============================================================
   ds-devtools.js
   开发者工具：把提示词注入到「用户消息」里。
   注入后，下次发送消息时后端会把提示词拼在用户输入前面一起发给 DeepSeek。
   聊天窗口 / 会话 .sts 里看不到注入内容。
   ============================================================ */
(function () {
    'use strict';
    console.log('[DSDT] 开发者工具脚本加载中...');

    var API_BASE = '/api/ds-devtools';
    var MENU_ENTRY_ID = 'dsdtMenuEntry';
    var STORAGE_KEY = 'dsdt_active_inject_ids';

    var state = {
        prompts: [],
        activeIds: {},       // id -> true，处于「已注入」状态的提示词
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
                if (!res.ok) throw new Error(data.error || ('请求失败 ' + res.status));
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
    // 注入状态持久化到 localStorage（只存 id，避免服务器知道你的注入）
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

    // 清理已不存在的提示词的注入状态
    function pruneActiveIds() {
        var valid = {};
        state.prompts.forEach(function (p) {
            if (state.activeIds[p.id]) valid[p.id] = true;
        });
        state.activeIds = valid;
        saveActiveIds();
    }

    // ============================================================
    // ★ 对外暴露：拿当前「已注入」的提示词内容列表
    // deepseek-chat.js 发送时会调用，把内容拼到用户输入前面
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
    // 弹窗构建
    // ============================================================
    function ensureModal() {
        if ($('dsdtOverlay')) return;

        var overlay = document.createElement('div');
        overlay.id = 'dsdtOverlay';
        overlay.className = 'dsdt-overlay';
        overlay.innerHTML =
            '<div class="dsdt-modal">' +
                '<div class="dsdt-header">' +
                    '<div class="dsdt-title"><span>🛠️</span><span>开发者工具</span></div>' +
                    '<button class="dsdt-close" id="dsdtClose" type="button" title="关闭">✕</button>' +
                '</div>' +
                '<div class="dsdt-warn">' +
                    '<span class="ic">⚠️</span>' +
                    '<div><b>警告：这是开发者工具，仅可用于开发环境。</b><br>' +
                    '注入的提示词会拼在你发送的消息前面一起发给 DeepSeek，' +
                    '聊天窗口和会话记录中不会显示。</div>' +
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
    // 入口视图
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
                    '<div>当前已注入 <b>' + activeCount + '</b> 条提示词，' +
                    '会在下次发送消息时生效</div>' +
                '</div>';
        }

        body.innerHTML =
            banner +
            '<button class="dsdt-enter-btn" id="dsdtEnterBtn" type="button">' +
                '<span class="ic">💉</span><span>注入提示词</span>' +
            '</button>' +
            '<div class="dsdt-hint">' +
                '进入后点击提示词即可注入 / 再次点击取消注入<br>' +
                '支持自定义新增、编辑、删除、批量删除、全部删除' +
            '</div>';

        var btn = $('dsdtEnterBtn');
        if (btn) btn.addEventListener('click', enterListMode);
    }

    function enterListMode() {
        state.inListMode = true;
        loadPrompts();
    }

    // ============================================================
    // 加载 & 渲染列表
    // ============================================================
    function loadPrompts() {
        var body = $('dsdtBody');
        if (!body) return;
        body.innerHTML = '<div class="dsdt-empty"><span class="emoji">⏳</span>加载中...</div>';

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
                        '<div>已注入 <b>' + activeCount + '</b> 条，会在下次发送消息时生效</div>' +
                    '</div>';
        }

        html += '<div class="dsdt-toolbar">';
        html += '<button class="dsdt-btn primary" id="dsdtAddBtn" type="button">＋ 新增</button>';
        html += '<button class="dsdt-btn" id="dsdtSelectBtn" type="button">' +
                    (state.selectMode ? '✕ 退出多选' : '☑️ 多选') + '</button>';
        if (state.selectMode) {
            html += '<button class="dsdt-btn danger" id="dsdtBatchDelBtn" type="button" ' +
                        (checkedCount === 0 ? 'disabled' : '') +
                    '>🗑️ 删除选中(' + checkedCount + ')</button>';
        }
        html += '<button class="dsdt-btn danger" id="dsdtClearAllBtn" type="button">🧹 全部删除</button>';
        html += '<button class="dsdt-btn ghost" id="dsdtBackBtn" type="button">← 返回</button>';
        html += '</div>';

        if (state.prompts.length === 0) {
            html += '<div class="dsdt-empty">' +
                        '<span class="emoji">📭</span>' +
                        '暂无提示词，点击「＋ 新增」添加' +
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
                                    escapeHtml(p.title || '未命名') + '</div>' +
                                '<div class="dsdt-item-content">' +
                                    escapeHtml(p.content || '') + '</div>' +
                            '</div>';
                } else {
                    html += '<div class="dsdt-item-main">' +
                                '<div class="dsdt-item-title">#' + (i + 1) + ' · ' +
                                    escapeHtml(p.title || '未命名');
                    if (isActive) {
                        html += '<span class="dsdt-badge">💉 已注入</span>';
                    }
                    html += '</div>' +
                            '<div class="dsdt-item-content">' +
                                escapeHtml(p.content || '') + '</div>' +
                            '<div class="dsdt-item-time">' +
                                escapeHtml(formatTime(p.createdAt)) + '</div>' +
                        '</div>' +
                        '<div class="dsdt-item-actions">' +
                            '<button class="dsdt-icon-btn" data-act="edit" title="编辑">✏️</button>' +
                            '<button class="dsdt-icon-btn danger" data-act="del" title="删除">✕</button>' +
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
            if (ids.length === 0) { toast('请先选择提示词', 'info'); return; }
            if (!window.confirm('确定删除选中的 ' + ids.length + ' 条提示词吗？')) return;

            api('POST', API_BASE + '/prompts/batch-delete', { ids: ids })
                .then(function (data) {
                    state.checkedIds = {};
                    toast('✅ 已删除 ' + (data.deleted || ids.length) + ' 条', 'success');
                    loadPrompts();
                })
                .catch(function (e) {
                    toast('批量删除失败: ' + e.message, 'error');
                });
        });

        var clearAll = $('dsdtClearAllBtn');
        if (clearAll) clearAll.addEventListener('click', function () {
            if (state.prompts.length === 0) { toast('暂无提示词', 'info'); return; }
            if (!window.confirm('确定删除全部 ' + state.prompts.length +
                ' 条提示词吗？此操作不可恢复！')) return;

            api('DELETE', API_BASE + '/prompts?all=true')
                .then(function () {
                    state.checkedIds = {};
                    state.selectMode = false;
                    state.activeIds = {};
                    saveActiveIds();
                    toast('✅ 已清空全部提示词', 'success');
                    loadPrompts();
                })
                .catch(function (e) {
                    toast('清空失败: ' + e.message, 'error');
                });
        });

        var items = document.querySelectorAll('#dsdtBody .dsdt-item');
        items.forEach(function (item) {
            var id = item.getAttribute('data-id');

            item.addEventListener('click', function (e) {
                if (e.target.closest('[data-act]')) return;

                // 多选模式：切换勾选
                if (state.selectMode) {
                    if (state.checkedIds[id]) delete state.checkedIds[id];
                    else state.checkedIds[id] = true;
                    renderList();
                    return;
                }

                // 普通模式：切换注入
                var p = state.prompts.find(function (x) { return x.id === id; });
                if (!p) return;

                if (state.activeIds[id]) {
                    delete state.activeIds[id];
                    saveActiveIds();
                    renderList();
                    toast('已取消注入：' + (p.title || '未命名'), 'info');
                } else {
                    state.activeIds[id] = true;
                    saveActiveIds();
                    renderList();
                    toast('💉 已注入：' + (p.title || '未命名'), 'success');
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
                if (!window.confirm('确定删除「' + (p.title || '未命名') + '」吗？')) return;

                api('DELETE', API_BASE + '/prompts?id=' + encodeURIComponent(id))
                    .then(function () {
                        if (state.activeIds[id]) {
                            delete state.activeIds[id];
                            saveActiveIds();
                        }
                        toast('✅ 已删除', 'success');
                        loadPrompts();
                    })
                    .catch(function (err) {
                        toast('删除失败: ' + err.message, 'error');
                    });
            });
        });
    }

    // ============================================================
    // 编辑器
    // ============================================================
    function renderEditor(prompt) {
        var body = $('dsdtBody');
        if (!body) return;

        var isEdit = !!prompt;
        state.editingId = isEdit ? prompt.id : null;

        body.innerHTML =
            '<div class="dsdt-field">' +
                '<label>📌 标题</label>' +
                '<input type="text" id="dsdtEditTitle" maxlength="80" ' +
                    'placeholder="例如：第一项 / 打招呼" ' +
                    'value="' + escapeHtml(isEdit ? (prompt.title || '') : '') + '">' +
            '</div>' +
            '<div class="dsdt-field">' +
                '<label>💬 提示词内容（会拼在你发送的消息前面）</label>' +
                '<textarea id="dsdtEditContent" maxlength="8000" ' +
                    'placeholder="例如：你好 / 大家好">' +
                    escapeHtml(isEdit ? (prompt.content || '') : '') +
                '</textarea>' +
            '</div>' +
            '<div class="dsdt-footer">' +
                '<button class="dsdt-btn ghost" id="dsdtEditCancel" type="button">取消</button>' +
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
                toast('提示词内容不能为空', 'info');
                if (contentEl) contentEl.focus();
                return;
            }

            var payload = { title: title || '未命名', content: content };
            if (state.editingId) payload.id = state.editingId;

            api('POST', API_BASE + '/prompts', payload)
                .then(function () {
                    toast(isEdit ? '✅ 已保存' : '✅ 已新增', 'success');
                    state.editingId = null;
                    loadPrompts();
                })
                .catch(function (e) {
                    toast('保存失败: ' + e.message, 'error');
                });
        });

        setTimeout(function () {
            var el = isEdit ? $('dsdtEditContent') : $('dsdtEditTitle');
            if (el) { el.focus(); if (isEdit && el.select) el.select(); }
        }, 100);
    }

    // ============================================================
    // 弹窗控制
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
    // 注入到 + 菜单
    // ============================================================
    function injectMenuItem() {
        var menu = document.getElementById('dscPlusMenu');
        if (!menu) return false;
        if (menu.querySelector('#' + MENU_ENTRY_ID)) return true;

        var btn = document.createElement('button');
        btn.id = MENU_ENTRY_ID;
        btn.type = 'button';
        btn.className = 'dsc-menu-item';
        // 故意用不会触发文件选择的类型值
        btn.dataset.type = '__devtools__';
        btn.innerHTML =
            '<span class="menu-icon">🛠️</span>' +
            '<div class="menu-info">' +
                '<div class="menu-title">开发者工具</div>' +
                '<div class="menu-desc">注入提示词 · 仅限开发环境</div>' +
            '</div>';

        // 捕获阶段拦截，避免触发文件选择
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
        console.log('[DSDT] ✅ 已在 + 菜单中注入「开发者工具」入口');
        return true;
    }

    // ============================================================
    // 初始化
    // ============================================================
    function bootstrap() {
        state.activeIds = loadActiveIds();

        // 如果有已注入的提示词，提前把提示词列表拉下来，
        // 这样 window.__dsDevToolsGetInjectedContents() 才能拿到内容
        if (Object.keys(state.activeIds).length > 0) {
            api('GET', API_BASE + '/prompts').then(function (data) {
                state.prompts = data.prompts || [];
                state.loaded = true;
                pruneActiveIds();
                console.log('[DSDT] 恢复注入状态 ' +
                    Object.keys(state.activeIds).length + ' 条');
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

        console.log('[DSDT] ✅ 开发者工具初始化完成');
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();