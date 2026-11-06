// ds-files.js - DeepSeek ファイル管理前端（修复版）
// 修正内容：
// 1. ファイル一覧APIにタイムスタンプ + no-store を付与し、キャッシュでアップロード後に表示されないのを防ぐ
// 2. renderAttachBar が dsFiles に強依存しないようにし、chip が描画されないのを防ぐ
// 3. アップロードキューを堅牢にし、固まるのを防ぐ
// 4. dscFileInput* の change イベントを一元処理（deepseek-chat.js 側の重複バインドは削除済み）
(function () {
    'use strict';
    console.log('[DSF] スクリプトの読み込みを開始');

    var dsFiles = [];
    var dsSearchQ = '';
    var dsUseRegex = false;
    var dsFilterCat = 'all';
    var attachedFileIds = [];

    // Promise キューでアップロードを直列化し、並行競合を防ぐ
    var uploadQueue = Promise.resolve();

    function $(id) { return document.getElementById(id); }

    function dsEsc(s) {
        return String(s == null ? '' : s).replace(/[&<>"']/g, function (m) {
            return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[m];
        });
    }

    function dsToast(msg, type) {
        var wrap = $('dscToastWrap');
        if (!wrap) { console.log('[DSF]', msg); return; }
        var el = document.createElement('div');
        el.className = 'dsc-toast ' + (type || '');
        el.textContent = msg;
        wrap.appendChild(el);
        setTimeout(function () { el.remove(); }, 2600);
    }

    function fmtSize(bytes) {
        if (bytes < 1024) return bytes + ' B';
        if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
        if (bytes < 1024 * 1024 * 1024) return (bytes / 1024 / 1024).toFixed(1) + ' MB';
        return (bytes / 1024 / 1024 / 1024).toFixed(2) + ' GB';
    }

    function fmtTime(iso) {
        if (!iso) return '';
        try {
            var d = new Date(iso);
            var pad = function (n) { return String(n).padStart(2, '0'); };
            return (d.getMonth() + 1) + '/' + d.getDate() + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
        } catch (e) { return ''; }
    }

    function catIcon(cat) {
        switch (cat) {
            case 'image': return '🖼️';
            case 'video': return '🎬';
            case 'document': return '📄';
            case 'code': return '💻';
            case 'minecraft': return '🧱';
            case 'audio': return '🎵';
            default: return '📦';
        }
    }

    // 【修正】タイムスタンプ + no-store を付与し、ブラウザキャッシュを防ぐ
    async function loadDsFiles() {
        try {
            var url = '/api/ds-files/list?category=' + encodeURIComponent(dsFilterCat) + '&_t=' + Date.now();
            var res = await fetch(url, { cache: 'no-store' });
            var data = await res.json();
            dsFiles = data.files || [];
            renderDsFiles();
        } catch (e) {
            dsToast('ファイル一覧の読み込みに失敗', 'error');
        }
    }

    function getFilteredDsFiles() {
        if (!dsSearchQ) return dsFiles;
        if (dsUseRegex) {
            var re;
            try { re = new RegExp(dsSearchQ, 'i'); }
            catch (e) { return []; }
            return dsFiles.filter(function (f) {
                return re.test(f.name || '') || re.test(f.prompt || '') || re.test(f.category || '');
            });
        }
        var q = dsSearchQ.toLowerCase();
        return dsFiles.filter(function (f) {
            return (f.name || '').toLowerCase().indexOf(q) !== -1 ||
                (f.prompt || '').toLowerCase().indexOf(q) !== -1 ||
                (f.category || '').toLowerCase().indexOf(q) !== -1;
        });
    }

    function renderDsFiles() {
        var list = $('dscFilesList');
        if (!list) return;
        var filtered = getFilteredDsFiles();
        list.innerHTML = '';
        if (filtered.length === 0) {
            list.innerHTML = '<div class="dsc-files-empty"><span class="emoji">📭</span><p>' +
                (dsSearchQ ? '一致するファイルがありません' : 'ファイルがまだありません') + '</p></div>';
            return;
        }
        var frag = document.createDocumentFragment();
        filtered.forEach(function (f) {
            var el = document.createElement('div');
            el.className = 'dsc-file-item';
            el.dataset.id = f.id;
            el.innerHTML =
                '<div class="dsc-file-icon ' + f.category + '">' + catIcon(f.category) + '</div>' +
                '<div class="dsc-file-info">' +
                '<div class="dsc-file-name">' + dsEsc(f.name) + '</div>' +
                '<div class="dsc-file-meta">' +
                '<span>' + fmtSize(f.size) + '</span>' +
                '<span>' + fmtTime(f.createdAt) + '</span>' +
                (f.source === 'ai_generated' ? '<span style="color:#f0b8c8;">AI 生成</span>' : '') +
                '</div></div>' +
                '<div class="dsc-file-actions">' +
                '<button class="dsc-file-act-btn" data-act="attach" title="添付">📎</button>' +
                '<button class="dsc-file-act-btn" data-act="download" title="ダウンロード">⬇️</button>' +
                '<button class="dsc-file-act-btn del" data-act="delete" title="削除">🗑️</button>' +
                '</div>';
            frag.appendChild(el);
        });
        list.appendChild(frag);
    }

    function attachFile(fileId) {
        if (attachedFileIds.indexOf(fileId) !== -1) { dsToast('このファイルを添付しました', 'info'); return; }
        if (attachedFileIds.length >= 50) { dsToast('添付は最大 50 ファイルまで', 'info'); return; }
        attachedFileIds.push(fileId);
        renderAttachBar();
        dsToast('メッセージに添付しました', 'success');
    }

    function removeAttach(fileId) {
        attachedFileIds = attachedFileIds.filter(function (id) { return id !== fileId; });
        renderAttachBar();
    }

    // 【修正】dsFiles にファイルがあるかに依存せず、一覧未読み込みでも chip を表示
    function renderAttachBar() {
        var bar = $('dscAttachBar');
        if (!bar) return;
        if (attachedFileIds.length === 0) {
            bar.classList.remove('visible');
            bar.innerHTML = '';
            return;
        }
        bar.classList.add('visible');
        bar.innerHTML = '';
        attachedFileIds.forEach(function (id) {
            var f = dsFiles.find(function (x) { return x.id === id; });
            var chip = document.createElement('div');
            chip.className = 'dsc-attach-chip';
            var icon = f ? catIcon(f.category) : '📎';
            var name = f ? f.name : ('ファイル ' + String(id).slice(-8));
            chip.innerHTML =
                '<span>' + icon + '</span>' +
                '<span class="nm">' + dsEsc(name) + '</span>' +
                '<button class="rm" data-id="' + id + '">✕</button>';
            bar.appendChild(chip);
        });
    }

    function downloadFile(fileId) {
        var url = '/api/ds-files/download?id=' + encodeURIComponent(fileId) + '&download=1';
        var a = document.createElement('a');
        a.href = url;
        var meta = dsFiles.find(function (f) { return f.id === fileId; });
        a.download = meta ? meta.name : 'file';
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        dsToast('ダウンロードを開始...', 'info');
    }

    async function deleteFile(fileId) {
        var meta = dsFiles.find(function (f) { return f.id === fileId; });
        if (!meta) return;
        try {
            var res = await fetch('/api/ds-files/delete?id=' + encodeURIComponent(fileId), { method: 'DELETE' });
            if (!res.ok) throw new Error('削除に失敗しました');
            dsFiles = dsFiles.filter(function (f) { return f.id !== fileId; });
            attachedFileIds = attachedFileIds.filter(function (id) { return id !== fileId; });
            renderDsFiles();
            renderAttachBar();
            dsToast('削除しました', 'success');
        } catch (e) {
            dsToast('削除に失敗: ' + e.message, 'error');
        }
    }

    async function doUploadFile(file) {
        if (file.size > 5 * 1024 * 1024 * 1024) {
            dsToast('ファイルが 5GB の上限を超えています', 'error');
            return;
        }
        var prog = $('dscUploadProgress');
        var fill = $('dscUpFill');
        var nameEl = $('dscUpName');
        var statEl = $('dscUpStat');
        if (prog) prog.style.display = 'block';
        if (nameEl) nameEl.textContent = file.name;

        try {
            var startRes = await fetch('/api/ds-files/upload/start', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    fileName: file.name,
                    fileSize: file.size,
                    mimeType: file.type || 'application/octet-stream'
                })
            });
            var startData;
            try {
                startData = await startRes.json();
            } catch (e) {
                throw new Error('アップロード開始に失敗（サーバーが無効な応答を返しました）');
            }
            if (!startRes.ok) throw new Error(startData.error || 'アップロード開始に失敗');
            var uploadId = startData.uploadId;
            var totalChunks = startData.totalChunks;
            var chunkSize = startData.chunkSize;

            for (var i = 0; i < totalChunks; i++) {
                var start = i * chunkSize;
                var end = Math.min(start + chunkSize, file.size);
                var blob = file.slice(start, end);
                var chunkRes = await fetch(
                    '/api/ds-files/upload/chunk?uploadId=' + encodeURIComponent(uploadId) + '&chunkIndex=' + i,
                    { method: 'POST', body: blob }
                );
                if (!chunkRes.ok) {
                    var err = await chunkRes.json().catch(function () { return {}; });
                    throw new Error(err.error || ('分割 ' + i + ' のアップロードに失敗'));
                }
                var pct = Math.round(((i + 1) / totalChunks) * 100);
                if (fill) fill.style.width = pct + '%';
                if (statEl) statEl.innerHTML = '<span>' + pct + '%</span><span>' + fmtSize(end) + ' / ' + fmtSize(file.size) + '</span>';
            }

            var doneRes = await fetch('/api/ds-files/upload/complete', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ uploadId: uploadId })
            });
            var doneData = await doneRes.json();
            if (!doneRes.ok) throw new Error(doneData.error || '結合に失敗');
            dsToast('アップロード成功: ' + file.name, 'success');

            // メッセージ欄へ即座に添付し、一覧の更新を待たない
            if (doneData.fileId) {
                attachFile(doneData.fileId);
                // dsFiles にまだ記録がなければ、まずプレースホルダを置き renderAttachBar に名前を表示させる
                if (!dsFiles.find(function (x) { return x.id === doneData.fileId; })) {
                    dsFiles.unshift({
                        id: doneData.fileId,
                        name: doneData.name || file.name,
                        size: doneData.size || file.size,
                        mimeType: doneData.mimeType || file.type || 'application/octet-stream',
                        category: doneData.category || 'other',
                        createdAt: new Date().toISOString(),
                        source: 'upload'
                    });
                    renderDsFiles();
                }
            }

            // サーバー一覧をもう一度取得し、データの一致を保証
            await loadDsFiles();

            setTimeout(function () {
                if (prog) prog.style.display = 'none';
                if (fill) fill.style.width = '0%';
            }, 1500);
        } catch (e) {
            dsToast('アップロードに失敗: ' + e.message, 'error');
            if (prog) prog.style.display = 'none';
        }
    }

    function uploadFile(file) {
        uploadQueue = uploadQueue.then(function () {
            return doUploadFile(file);
        }).catch(function (e) {
            console.error('[DSF] アップロードキューのエラー:', e);
            return Promise.resolve();
        });
        return uploadQueue;
    }

    async function generateImage() {
        var input = $('dscGenPrompt');
        var btn = $('dscGenBtn');
        if (!input || !btn) return;
        var prompt = input.value.trim();
        if (!prompt) { dsToast('画像の説明を入力してください', 'info'); return; }
        btn.disabled = true;
        btn.textContent = '生成中...';
        try {
            var res = await fetch('/api/ds-chat/generate-image', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ prompt: prompt, width: 1024, height: 1024 })
            });
            var data = await res.json();
            if (!res.ok) throw new Error(data.error || '生成に失敗');
            dsToast('画像の生成に成功しました！', 'success');
            input.value = '';
            await loadDsFiles();
            if (data.fileId) attachFile(data.fileId);
        } catch (e) {
            dsToast('生成に失敗: ' + e.message, 'error');
        } finally {
            btn.disabled = false;
            btn.textContent = '🎨 生成';
        }
    }

    function initDsFiles() {
        console.log('[DSF] 初期化');
        var panel = $('dscFilesPanel');
        if (!panel) { console.warn('[DSF] #dscFilesPanel が見つかりません'); return; }

        var openBtn = $('dscFilesToggle');
        var closeBtn = $('dscFilesClose');
        if (openBtn) {
            openBtn.addEventListener('click', function () {
                panel.classList.toggle('open');
                if (panel.classList.contains('open')) loadDsFiles();
            });
        }
        if (closeBtn) closeBtn.addEventListener('click', function () { panel.classList.remove('open'); });

        var zone = $('dscUploadZone');
        var fileInput = $('dscFileInput');
        if (zone && fileInput) {
            fileInput.multiple = true;
            zone.addEventListener('click', function () { fileInput.click(); });
            zone.addEventListener('dragover', function (e) { e.preventDefault(); zone.classList.add('dragover'); });
            zone.addEventListener('dragleave', function () { zone.classList.remove('dragover'); });

            zone.addEventListener('drop', function (e) {
                e.preventDefault();
                zone.classList.remove('dragover');
                if (e.dataTransfer.files.length > 0) {
                    for (var i = 0; i < e.dataTransfer.files.length; i++) {
                        uploadFile(e.dataTransfer.files[i]);
                    }
                }
            });

            fileInput.addEventListener('change', function (e) {
                if (e.target.files.length > 0) {
                    var files = Array.prototype.slice.call(e.target.files);
                    e.target.value = '';
                    for (var i = 0; i < files.length; i++) {
                        uploadFile(files[i]);
                    }
                }
            });
        }

        document.querySelectorAll('.dsc-filter-chip').forEach(function (chip) {
            chip.addEventListener('click', function () {
                document.querySelectorAll('.dsc-filter-chip').forEach(function (c) { c.classList.remove('active'); });
                chip.classList.add('active');
                dsFilterCat = chip.dataset.cat;
                loadDsFiles();
            });
        });

        var searchInput = $('dscFilesSearch');
        var searchClear = $('dscFilesSearchClear');
        var regexCb = $('dscFilesRegexCheckbox');
        var regexToggle = $('dscFilesRegexToggle');
        if (searchInput) {
            searchInput.addEventListener('input', function () {
                dsSearchQ = searchInput.value.trim();
                dsUseRegex = regexCb ? regexCb.checked : false;
                if (regexToggle) regexToggle.classList.toggle('active', dsUseRegex);
                if (searchClear) searchClear.classList.toggle('visible', dsSearchQ.length > 0);
                renderDsFiles();
            });
        }
        if (searchClear) {
            searchClear.addEventListener('click', function () {
                if (searchInput) searchInput.value = '';
                dsSearchQ = '';
                searchClear.classList.remove('visible');
                renderDsFiles();
            });
        }
        if (regexCb) {
            regexCb.addEventListener('change', function () {
                dsUseRegex = regexCb.checked;
                if (regexToggle) regexToggle.classList.toggle('active', dsUseRegex);
                renderDsFiles();
            });
        }

        var list = $('dscFilesList');
        if (list) {
            list.addEventListener('click', function (e) {
                var item = e.target.closest('.dsc-file-item');
                if (!item) return;
                var fileId = item.dataset.id;
                var actBtn = e.target.closest('[data-act]');
                if (actBtn) {
                    var act = actBtn.dataset.act;
                    if (act === 'attach') attachFile(fileId);
                    else if (act === 'download') downloadFile(fileId);
                    else if (act === 'delete') deleteFile(fileId);
                    return;
                }
                var f = dsFiles.find(function (x) { return x.id === fileId; });
                if (f) {
                    if (f.category === 'image') {
                        window.open('/api/ds-files/download?id=' + encodeURIComponent(fileId), '_blank');
                    } else {
                        downloadFile(fileId);
                    }
                }
            });
        }

        var attachBar = $('dscAttachBar');
        if (attachBar) {
            attachBar.addEventListener('click', function (e) {
                var rm = e.target.closest('.rm');
                if (rm) removeAttach(rm.dataset.id);
            });
        }

        var genBtn = $('dscGenBtn');
        if (genBtn) genBtn.addEventListener('click', generateImage);

        // dscFileInput* の複数選択アップロードを一元処理（deepseek-chat.js 側の重複バインドは削除済み）
        ['dscFileInputImage', 'dscFileInputDoc', 'dscFileInputVideo', 'dscFileInputAny'].forEach(function (id) {
            var inp = $(id);
            if (!inp) return;
            inp.multiple = true;
            inp.addEventListener('change', function (e) {
                if (e.target.files.length > 0) {
                    // まず全ファイル参照を取り出してから input をクリア（ファイル消失を防ぐ）
                    var files = Array.prototype.slice.call(e.target.files);
                    e.target.value = '';
                    for (var i = 0; i < files.length; i++) {
                        uploadFile(files[i]);
                    }
                }
            });
        });

        window.dsGetAttachedFileIds = function () { return attachedFileIds.slice(); };
        window.dsClearAttach = function () { attachedFileIds = []; renderAttachBar(); };
        window.dsLoadFiles = loadDsFiles;
        window.dsUploadFileDirectly = uploadFile;
        console.log('[DSF] ✅ 初期化完了');
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', initDsFiles);
    } else {
        initDsFiles();
    }
})();