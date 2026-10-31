// ds-files.js - DeepSeek 文件管理前端（修复版）
// 修复内容：
// 1. 文件列表接口加时间戳 + no-store，防止缓存导致上传后不显示
// 2. renderAttachBar 不再强依赖 dsFiles，避免 chip 不渲染
// 3. 上传队列更健壮，避免卡死
// 4. 统一处理 dscFileInput* 的 change 事件（已在 deepseek-chat.js 中移除重复绑定）
(function () {
    'use strict';
    console.log('[DSF] 脚本开始加载');

    var dsFiles = [];
    var dsSearchQ = '';
    var dsUseRegex = false;
    var dsFilterCat = 'all';
    var attachedFileIds = [];

    // Promise 队列，串行化上传，避免并发冲突
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
            default: return '📦';
        }
    }

    // 【修复】加时间戳 + no-store，防止浏览器缓存
    async function loadDsFiles() {
        try {
            var url = '/api/ds-files/list?category=' + encodeURIComponent(dsFilterCat) + '&_t=' + Date.now();
            var res = await fetch(url, { cache: 'no-store' });
            var data = await res.json();
            dsFiles = data.files || [];
            renderDsFiles();
        } catch (e) {
            dsToast('加载文件列表失败', 'error');
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
                (dsSearchQ ? '没有匹配的文件' : '还没有文件') + '</p></div>';
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
                '<button class="dsc-file-act-btn" data-act="attach" title="附加">📎</button>' +
                '<button class="dsc-file-act-btn" data-act="download" title="下载">⬇️</button>' +
                '<button class="dsc-file-act-btn del" data-act="delete" title="删除">🗑️</button>' +
                '</div>';
            frag.appendChild(el);
        });
        list.appendChild(frag);
    }

    function attachFile(fileId) {
        if (attachedFileIds.indexOf(fileId) !== -1) { dsToast('已附加该文件', 'info'); return; }
        if (attachedFileIds.length >= 50) { dsToast('最多附加 50 个文件', 'info'); return; }
        attachedFileIds.push(fileId);
        renderAttachBar();
        dsToast('已附加到消息', 'success');
    }

    function removeAttach(fileId) {
        attachedFileIds = attachedFileIds.filter(function (id) { return id !== fileId; });
        renderAttachBar();
    }

    // 【修复】不依赖 dsFiles 是否存在该文件，即使列表未加载也显示 chip
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
            var name = f ? f.name : ('文件 ' + String(id).slice(-8));
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
        dsToast('开始下载...', 'info');
    }

    async function deleteFile(fileId) {
        var meta = dsFiles.find(function (f) { return f.id === fileId; });
        if (!meta) return;
        try {
            var res = await fetch('/api/ds-files/delete?id=' + encodeURIComponent(fileId), { method: 'DELETE' });
            if (!res.ok) throw new Error('删除失败');
            dsFiles = dsFiles.filter(function (f) { return f.id !== fileId; });
            attachedFileIds = attachedFileIds.filter(function (id) { return id !== fileId; });
            renderDsFiles();
            renderAttachBar();
            dsToast('已删除', 'success');
        } catch (e) {
            dsToast('删除失败: ' + e.message, 'error');
        }
    }

    async function doUploadFile(file) {
        if (file.size > 5 * 1024 * 1024 * 1024) {
            dsToast('文件超过 5GB 限制', 'error');
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
                throw new Error('开始上传失败（服务器返回无效响应）');
            }
            if (!startRes.ok) throw new Error(startData.error || '开始上传失败');
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
                    throw new Error(err.error || ('分片 ' + i + ' 上传失败'));
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
            if (!doneRes.ok) throw new Error(doneData.error || '合并失败');
            dsToast('上传成功: ' + file.name, 'success');

            // 立即附加到消息栏，无需等待列表刷新
            if (doneData.fileId) {
                attachFile(doneData.fileId);
                // 如果 dsFiles 里还没有这条记录，先放个占位，让 renderAttachBar 显示名字
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

            // 再拉一次服务端列表，保证数据一致
            await loadDsFiles();

            setTimeout(function () {
                if (prog) prog.style.display = 'none';
                if (fill) fill.style.width = '0%';
            }, 1500);
        } catch (e) {
            dsToast('上传失败: ' + e.message, 'error');
            if (prog) prog.style.display = 'none';
        }
    }

    function uploadFile(file) {
        uploadQueue = uploadQueue.then(function () {
            return doUploadFile(file);
        }).catch(function (e) {
            console.error('[DSF] 上传队列错误:', e);
            return Promise.resolve();
        });
        return uploadQueue;
    }

    async function generateImage() {
        var input = $('dscGenPrompt');
        var btn = $('dscGenBtn');
        if (!input || !btn) return;
        var prompt = input.value.trim();
        if (!prompt) { dsToast('请输入图片描述', 'info'); return; }
        btn.disabled = true;
        btn.textContent = '生成中...';
        try {
            var res = await fetch('/api/ds-chat/generate-image', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ prompt: prompt, width: 1024, height: 1024 })
            });
            var data = await res.json();
            if (!res.ok) throw new Error(data.error || '生成失败');
            dsToast('图片生成成功！', 'success');
            input.value = '';
            await loadDsFiles();
            if (data.fileId) attachFile(data.fileId);
        } catch (e) {
            dsToast('生成失败: ' + e.message, 'error');
        } finally {
            btn.disabled = false;
            btn.textContent = '🎨 生成';
        }
    }

    function initDsFiles() {
        console.log('[DSF] 初始化');
        var panel = $('dscFilesPanel');
        if (!panel) { console.warn('[DSF] 找不到 #dscFilesPanel'); return; }

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

        // 统一处理 dscFileInput* 多选上传（deepseek-chat.js 中已移除重复绑定）
        ['dscFileInputImage', 'dscFileInputDoc', 'dscFileInputVideo', 'dscFileInputAny'].forEach(function (id) {
            var inp = $(id);
            if (!inp) return;
            inp.multiple = true;
            inp.addEventListener('change', function (e) {
                if (e.target.files.length > 0) {
                    // 先取出所有文件引用，再清空 input（避免文件丢失）
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
        console.log('[DSF] ✅ 初始化完成');
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', initDsFiles);
    } else {
        initDsFiles();
    }
})();