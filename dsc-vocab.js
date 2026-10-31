// ============================================================
// dsc-vocab.js —— 日语单词本 v2
//   分片行标签 / 搜索 / 批量选择 / 图片上传 / 4:3 缩略图
// ============================================================
(function () {
  'use strict';

  var KANA_ROWS = ['全部', '其他'];
  // [FIX] 假名栏全量显示

  var state = {
    words: [],
    total: 0, totalAll: 0, due: 0, mastered: 0,
    hasMore: false, loading: false, offset: 0, pageSize: 30,
    rowStats: {},
    currentRow: '全部',
    filter: { q: '', level: '', dueOnly: false },
    batchMode: false, selected: {},
    editingId: null,
    pendingImage: '', // 正在编辑的图片名
    reviewQueue: [], reviewIdx: 0, reviewShowAnswer: false,
    reviewStats: { correct: 0, wrong: 0 }
  };

  
  // ============ 统一的精美确认弹窗 ============
  function showConfirmDialog(title, msg) {
    return new Promise(function(resolve) {
      var overlay = document.getElementById('dscConfirmOverlay');
      var titleEl = document.getElementById('dscConfirmTitle');
      var msgEl = document.getElementById('dscConfirmMsg');
      var okBtn = document.getElementById('dscConfirmOk');
      var cancelBtn = document.getElementById('dscConfirmCancel');
      
      if (!overlay || !okBtn || !cancelBtn) {
        resolve(window.confirm(title + '\n\n' + msg));
        return;
      }
      
      titleEl.textContent = title;
      msgEl.textContent = msg;
      overlay.classList.add('open');
      
      function cleanup(result) {
        overlay.classList.remove('open');
        okBtn.removeEventListener('click', onOk);
        cancelBtn.removeEventListener('click', onCancel);
        overlay.removeEventListener('click', onOverlay);
        resolve(result);
      }
      function onOk() { cleanup(true); }
      function onCancel() { cleanup(false); }
      function onOverlay(e) { if (e.target === overlay) cleanup(false); }
      
      okBtn.addEventListener('click', onOk);
      cancelBtn.addEventListener('click', onCancel);
      overlay.addEventListener('click', onOverlay);
    });
  }

  function $(id) { return document.getElementById(id); }

  function escHtml(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }
  function showToast(msg, type) {
    var wrap = $('dscToastWrap');
    if (!wrap) { console.log('[VOCAB]', msg); return; }
    var el = document.createElement('div');
    el.className = 'dsc-toast ' + (type || '');
    el.textContent = msg;
    wrap.appendChild(el);
    setTimeout(function () { el.remove(); }, 2600);
  }
  function isDue(w) {
    if (w.mastered) return false;
    if (!w.nextReviewAt) return true;
    return w.nextReviewAt <= new Date().toISOString();
  }
  function fmtNextReview(iso) {
    if (!iso) return '';
    var d = new Date(iso);
    if (isNaN(d.getTime())) return '';
    var diff = d.getTime() - Date.now();
    var days = Math.round(diff / 86400000);
    if (days < 0) return '已到期';
    if (days === 0) return '今天';
    if (days === 1) return '明天';
    if (days < 30) return days + ' 天后';
    return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
  }

  // ============ 打开/关闭 ============
  function openVocab() {
    rearrangeToolbar();
    var overlay = $('dscVocabOverlay');
    if (!overlay) { showToast('单词本界面未加载', 'error'); return; }
    overlay.classList.add('open');
    renderRowTabs();
    loadList(true);
  }
  function closeVocab() {
    var overlay = $('dscVocabOverlay');
    if (overlay) overlay.classList.remove('open');
    setBatchMode(false);
  }

  // ============ 分片行标签 ============
      function renderRowTabs() {
    var wrap = $('dscVocabRowTabs');
    if (!wrap) return;
    wrap.innerHTML = '';
    KANA_ROWS.forEach(function (row) {
      var btn = document.createElement('button');
      btn.className = 'dsc-vocab-row-tab' + (state.currentRow === row ? ' active' : '');
      var cnt = row === '全部' ? state.totalAll : (state.rowStats[row] || 0);
      btn.innerHTML = escHtml(row) + '<span class="cnt">' + cnt + '</span>';
      btn.addEventListener('click', function () {
        state.currentRow = row;
        renderRowTabs();
        loadList(true);
      });
      wrap.appendChild(btn);
    });

    // [ULTIMATE_KANA_UI_FIX]
    var fullBtn = document.createElement('button');
    fullBtn.className = 'dsc-vocab-row-tab';
    fullBtn.style.cssText = 'background:#eef2ff; border-color:#c7d2fe; color:#4f46e5; font-weight:700;';
    fullBtn.textContent = '🔍 查假名';
    fullBtn.title = '打开假名大全，点击直接筛选包含该假名的单词';
    fullBtn.addEventListener('click', function() { showPerfectKanaTable(); });
    wrap.appendChild(fullBtn);
    // [/ULTIMATE_KANA_UI_FIX]
  }

  function showPerfectKanaTable() {
    var old = document.getElementById('dscPerfectKanaOverlay');
    if (old) old.remove();

    var overlay = document.createElement('div');
    overlay.id = 'dscPerfectKanaOverlay';
    overlay.style.cssText = 'position:fixed;inset:0;z-index:500000;background:rgba(15,23,42,0.6);display:flex;align-items:flex-end;justify-content:center;backdrop-filter:blur(2px);-webkit-backdrop-filter:blur(2px);';
    overlay.addEventListener('click', function(e) { if (e.target === overlay) overlay.remove(); });

    var box = document.createElement('div');
    box.style.cssText = 'background:#fff;border-radius:24px 24px 0 0;width:100%;max-width:800px;max-height:85vh;display:flex;flex-direction:column;box-shadow:0 -10px 40px rgba(0,0,0,0.15);animation:dscVocabMenuIn 0.2s ease-out;';
    
    var header = document.createElement('div');
    header.style.cssText = 'padding:20px;border-bottom:1px solid #ececf1;display:flex;align-items:center;justify-content:space-between;flex-shrink:0;';
    header.innerHTML = '<div style="font-size:1.15rem;font-weight:800;color:#1f2937;">🔍 日语假名大全</div>' +
                       '<button id="dscKanaCloseBtn" style="background:#f3f4f6;border:none;border-radius:50%;width:32px;height:32px;font-size:1rem;cursor:pointer;color:#6b7280;display:flex;align-items:center;justify-content:center;">✕</button>';
    box.appendChild(header);

    var scrollArea = document.createElement('div');
    scrollArea.style.cssText = 'padding:20px;overflow-y:auto;-webkit-overflow-scrolling:touch;flex:1;';
    box.appendChild(scrollArea);

    function onKanaClick(ch) {
      overlay.remove();
      state.currentRow = ch;
      renderRowTabs(); 
      loadList(true);
      var sub = document.getElementById('dscVocabSub');
      if (sub) sub.textContent = '正在筛选：包含「' + ch + '」';
    }

    function buildSection(title, rows, cols) {
      var sec = document.createElement('div');
      sec.style.marginBottom = '24px';
      var t = document.createElement('div');
      t.textContent = title;
      t.style.cssText = 'font-size:0.9rem;font-weight:700;color:#4f46e5;margin-bottom:12px;border-left:4px solid #4f46e5;padding-left:8px;';
      sec.appendChild(t);

      var grid = document.createElement('div');
      grid.style.cssText = 'display:grid;grid-template-columns:repeat(' + (cols || 5) + ', 1fr);gap:10px;';
      
      rows.forEach(function(row) {
        row.forEach(function(ch) {
          var cell = document.createElement('div');
          cell.textContent = ch || '';
          if (ch) {
            cell.style.cssText = 'text-align:center;font-size:1.4rem;font-weight:700;color:#374151;padding:12px 0;border-radius:12px;background:#f9fafb;border:1px solid #f3f4f6;cursor:pointer;transition:all 0.15s;user-select:none;';
            cell.addEventListener('touchstart', function() { cell.style.background = '#e0e7ff'; cell.style.transform = 'scale(0.95)'; }, {passive: true});
            cell.addEventListener('touchend', function() { cell.style.background = '#f9fafb'; cell.style.transform = 'scale(1)'; }, {passive: true});
            cell.addEventListener('click', function() { onKanaClick(ch); });
          } else {
            cell.style.cssText = 'padding:12px 0;'; 
          }
          grid.appendChild(cell);
        });
      });
      sec.appendChild(grid);
      return sec;
    }

    scrollArea.appendChild(buildSection('清音 (46)', [
      ['あ', 'い', 'う', 'え', 'お'], ['か', 'き', 'く', 'け', 'こ'], ['さ', 'し', 'す', 'せ', 'そ'], ['た', 'ち', 'つ', 'て', 'と'], ['な', 'に', 'ぬ', 'ね', 'の'], ['は', 'ひ', 'ふ', 'へ', 'ほ'], ['ま', 'み', 'む', 'め', 'も'], ['や', '', 'ゆ', '', 'よ'], ['ら', 'り', 'る', 'れ', 'ろ'], ['わ', '', '', '', 'を'], ['ん', '', '', '', '']
    ], 5));

    scrollArea.appendChild(buildSection('浊音 / 半浊音', [
      ['が', 'ぎ', 'ぐ', 'げ', 'ご'], ['ざ', 'じ', 'ず', 'ぜ', 'ぞ'], ['だ', 'ぢ', 'づ', 'で', 'ど'], ['ば', 'び', 'ぶ', 'べ', 'ぼ'], ['ぱ', 'ぴ', 'ぷ', 'ぺ', 'ぽ']
    ], 5));

    scrollArea.appendChild(buildSection('拗音 (清)', [
      ['きゃ', 'きゅ', 'きょ'], ['しゃ', 'しゅ', 'しょ'], ['ちゃ', 'ちゅ', 'ちょ'], ['にゃ', 'にゅ', 'にょ'], ['ひゃ', 'ひゅ', 'ひょ'], ['みゃ', 'みゅ', 'みょ'], ['りゃ', 'りゅ', 'りょ']
    ], 3));

    scrollArea.appendChild(buildSection('拗音 (浊/半浊)', [
      ['ぎゃ', 'ぎゅ', 'ぎょ'], ['じゃ', 'じゅ', 'じょ'], ['びゃ', 'びゅ', 'びょ'], ['ぴゃ', 'ぴゅ', 'ぴょ']
    ], 3));

    scrollArea.appendChild(buildSection('特殊 / 小写', [
      ['っ', 'ゃ', 'ゅ', 'ょ', 'ゎ'], ['ぁ', 'ぃ', 'ぅ', 'ぇ', 'ぉ'], ['ゔ', 'ゐ', 'ゑ', 'ゕ', 'ゖ'], ['ー', '・', '～', '', '']
    ], 5));

    overlay.appendChild(box);
    document.body.appendChild(overlay);
    document.getElementById('dscKanaCloseBtn').addEventListener('click', function() { overlay.remove(); });
  }

async function loadList(reset) {
    if (state.loading) return;
    if (reset) { state.offset = 0; state.words = []; }
    state.loading = true;
    try {
      var qs = new URLSearchParams();
      qs.set('offset', state.offset);
      qs.set('limit', state.pageSize);
      if (state.filter.q) qs.set('q', state.filter.q);
      if (state.filter.level) qs.set('level', state.filter.level);
      if (state.filter.dueOnly) qs.set('dueOnly', '1');
      if (state.currentRow !== '全部') qs.set('row', state.currentRow);
      var res = await fetch('/api/vocab?' + qs.toString(), { cache: 'no-store' });
      var data = await res.json();
      if (!res.ok) throw new Error(data.error || '加载失败');
      state.words = state.words.concat(data.words || []);
      state.total = data.total || 0;
      state.totalAll = data.totalAll || 0;
      state.due = data.due || 0;
      state.mastered = data.mastered || 0;
      state.rowStats = data.rowStats || {};
      state.hasMore = !!data.hasMore;
      state.offset = state.words.length;
      renderList();
      renderRowTabs();
      updateSub();
      updateBatchUI();
    } catch (e) {
      showToast(e.message, 'error');
    } finally {
      state.loading = false;
    }
  }

  function updateSub() {
    var sub = $('dscVocabSub');
    if (sub) {
      var parts = ['共 ' + state.totalAll + ' 词'];
      if (state.due > 0) parts.push('待复习 ' + state.due);
      if (state.mastered > 0) parts.push('已掌握 ' + state.mastered);
      sub.textContent = parts.join(' · ');
    }
    var reviewBtn = $('dscVocabReviewBtn');
    if (reviewBtn) {
      reviewBtn.classList.toggle('primary', state.due > 0);
      reviewBtn.title = state.due > 0 ? ('开始复习（' + state.due + '）') : '暂无待复习';
    }
  }

  function renderList() {
    var list = $('dscVocabList');
    if (!list) return;
    list.innerHTML = '';
    if (!state.words.length) {
      var empty = document.createElement('div');
      empty.className = 'dsc-vocab-empty';
      var hint = (state.filter.q || state.filter.level || state.filter.dueOnly || state.currentRow !== '全部')
        ? '没有符合条件的单词' : '还没有单词，点右上角 ＋ 添加';
      empty.innerHTML = '<span class="emoji">📖</span>' + hint;
      list.appendChild(empty);
      return;
    }
    state.words.forEach(function (w) { list.appendChild(buildCard(w)); });
    if (state.hasMore) {
      var lm = document.createElement('div');
      lm.className = 'dsc-vocab-loadmore';
      lm.textContent = '加载更多（已显示 ' + state.words.length + ' / ' + state.total + '）';
      lm.addEventListener('click', function () { loadList(false); });
      list.appendChild(lm);
    }
  }

  function buildCard(w) {
    var card = document.createElement('div');
    card.className = 'dsc-vocab-card';
    if (isDue(w)) card.classList.add('due');
    if (w.mastered) card.classList.add('mastered');
    if (state.batchMode) card.classList.add('batch');
    if (state.selected[w.id]) card.classList.add('selected');
    card.setAttribute('data-id', w.id);

    var cb = document.createElement('input');
    cb.type = 'checkbox';
    cb.className = 'dsc-vocab-card-check';
    cb.checked = !!state.selected[w.id];
    cb.setAttribute('data-id', w.id);
    card.appendChild(cb);

    // 恢复大图展示，没图就彻底不显示
    if (w.imageUrl) {
      var thumb = document.createElement('div');
      thumb.className = 'dsc-vocab-thumb';
      var img = document.createElement('img');
      img.src = w.imageUrl;
      img.alt = w.word || '';
      img.loading = 'lazy';
      thumb.appendChild(img);
      card.appendChild(thumb);
    }

    var body = document.createElement('div');
    body.className = 'dsc-vocab-card-body';
    var top = document.createElement('div');
    top.className = 'dsc-vocab-card-top';
    var main = document.createElement('div');
    main.className = 'dsc-vocab-card-main';

    var wordRow = document.createElement('div');
    wordRow.className = 'dsc-vocab-card-word-row';
    var wordEl = document.createElement('span');
    wordEl.className = 'dsc-vocab-card-word';
    wordEl.textContent = w.word || '';
    wordRow.appendChild(wordEl);
    if (w.reading) {
      var r = document.createElement('span');
      r.className = 'dsc-vocab-card-reading';
      r.textContent = w.reading;
      if (w.pitch) {
        r.textContent += ' [' + w.pitch + ']';
      }
      wordRow.appendChild(r);
    } else if (w.pitch) {
      var p = document.createElement('span');
      p.className = 'dsc-vocab-card-reading';
      p.textContent = '[' + w.pitch + ']';
      wordRow.appendChild(p);
    }
    if (w.pos) {
      var p = document.createElement('span');
      p.className = 'dsc-vocab-card-reading';
      p.textContent = '【' + w.pos + '】';
      wordRow.appendChild(p);
    }
    main.appendChild(wordRow);

    var meaning = document.createElement('div');
    meaning.className = 'dsc-vocab-card-meaning';
    meaning.textContent = w.meaning || '（无释义）';
    main.appendChild(meaning);

    var meta = document.createElement('div');
    meta.className = 'dsc-vocab-card-meta';
    if (w.level) {
      var lt = document.createElement('span'); lt.className = 'tag level'; lt.textContent = w.level; meta.appendChild(lt);
    }
    if (w.mastered) {
      var mt = document.createElement('span'); mt.className = 'tag mastered'; mt.textContent = '已掌握'; meta.appendChild(mt);
    } else if (isDue(w)) {
      var dt = document.createElement('span'); dt.className = 'tag due'; dt.textContent = '待复习'; meta.appendChild(dt);
    } else if (w.nextReviewAt) {
      var nt = document.createElement('span'); nt.textContent = '下次 ' + fmtNextReview(w.nextReviewAt); meta.appendChild(nt);
    }
    if (w.reviewCount > 0) {
      var rt = document.createElement('span'); rt.textContent = '复习 ' + w.reviewCount + ' 次'; meta.appendChild(rt);
    }
    (w.tags || []).forEach(function (t) {
      var tg = document.createElement('span'); tg.className = 'tag'; tg.textContent = '#' + t; meta.appendChild(tg);
    });
    main.appendChild(meta);
    top.appendChild(main);

    var moreBtn = document.createElement('button');
    moreBtn.className = 'dsc-vocab-card-more';
    moreBtn.textContent = '⋯';
    moreBtn.title = '操作';
    moreBtn.setAttribute('data-id', w.id);
    top.appendChild(moreBtn);

    body.appendChild(top);
    card.appendChild(body);
    return card;
  }

  // ============ 悬浮菜单 ============
  var popmenu = null;
  function closePopmenu() { if (popmenu) { popmenu.remove(); popmenu = null; } }
  function openPopmenu(anchor, items) {
    closePopmenu();
    if (!items || !items.length) return;
    var menu = document.createElement('div');
    menu.className = 'dsc-vocab-popmenu';
    menu.style.visibility = 'hidden';
    items.forEach(function (it) {
      var b = document.createElement('button');
      if (it.danger) b.className = 'danger';
      b.textContent = (it.icon ? it.icon + ' ' : '') + it.label;
      b.addEventListener('click', function (e) {
        e.stopPropagation(); closePopmenu();
        try { it.action(); } catch (err) { console.error(err); }
      });
      menu.appendChild(b);
    });
    document.body.appendChild(menu); popmenu = menu;
    var pw = menu.offsetWidth || 172;
    var ph = menu.offsetHeight || items.length * 36;
    var r = anchor.getBoundingClientRect();
    var left = r.right - pw;
    if (left < 8) left = 8;
    if (left + pw > window.innerWidth - 8) left = window.innerWidth - pw - 8;
    var top = r.bottom + 6;
    if (top + ph > window.innerHeight - 8) top = r.top - ph - 6;
    if (top < 8) top = 8;
    menu.style.left = Math.round(left) + 'px';
    menu.style.top = Math.round(top) + 'px';
    menu.style.visibility = 'visible';
  }

  function findWord(id) {
    for (var i = 0; i < state.words.length; i++) if (state.words[i].id === id) return state.words[i];
    return null;
  }

  function cardMenuItems(w) {
    return [
      { icon: '✏️', label: '编辑', action: function () { openEditor(w); } },
      { icon: w.mastered ? '↩️' : '✅', label: w.mastered ? '取消掌握' : '标记掌握', action: function () { toggleMastered(w); } },
      { icon: '🗑️', label: '删除', danger: true, action: function () { deleteWord(w); } }
    ];
  }

  // ============ 批量 ============
  function setBatchMode(on) {
    state.batchMode = !!on;
    if (!on) state.selected = {};
    var bar = $('dscVocabBatchBar');
    if (bar) bar.classList.toggle('open', !!on);
    renderList();
    updateBatchUI();
  }
  function updateBatchUI() {
    var sel = Object.keys(state.selected);
    var cnt = $('dscVocabBatchCount');
    if (cnt) cnt.textContent = '已选 ' + sel.length;
    var del = $('dscVocabBatchDelBtn');
    if (del) del.disabled = sel.length === 0;
    var all = $('dscVocabSelectAll');
    if (all) all.checked = state.words.length > 0 && sel.length === state.words.length;
    var list = $('dscVocabList');
    if (!list) return;
    list.querySelectorAll('.dsc-vocab-card').forEach(function (card) {
      var id = card.getAttribute('data-id');
      card.classList.toggle('selected', !!state.selected[id]);
      var cb = card.querySelector('.dsc-vocab-card-check');
      if (cb) cb.checked = !!state.selected[id];
    });
  }
  function toggleSelect(id, checked) {
    if (checked) state.selected[id] = true; else delete state.selected[id];
    updateBatchUI();
  }
  async function batchDelete() {
    var ids = Object.keys(state.selected);
    if (!ids.length) { showToast('请先勾选要删除的单词', 'error'); return; }
    var ok = await showConfirmDialog('🗑️ 批量删除', '确定删除选中的 ' + ids.length + ' 个单词吗？不可恢复！');
    if (!ok) return;
    try {
      var res = await fetch('/api/vocab?ids=' + encodeURIComponent(ids.join(',')), { method: 'DELETE' });
      var data = await res.json();
      if (!res.ok) { showToast(data.error || '删除失败', 'error'); return; }
      showToast('已删除 ' + (data.deleted || ids.length) + ' 个', 'success');
      state.selected = {};
      setBatchMode(false);
      loadList(true);
    } catch (e) { showToast('删除失败', 'error'); }
  }

  // ============ 编辑（含图片） ============
  function openEditor(word) {
    state.editingId = word ? word.id : null;
    state.pendingImage = word ? (word.image || '') : '';
    var t = $('dscVocabEditorTitle');
    if (t) t.textContent = word ? '✏️ 编辑单词' : '✍️ 添加单词';
    $('dscVocabWordInput').value = word ? (word.word || '') : '';
    $('dscVocabReadingInput').value = word ? (word.reading || '') : '';
    $('dscVocabPitchInput').value = word ? (word.pitch || '') : '';
    $('dscVocabMeaningInput').value = word ? (word.meaning || '') : '';
    $('dscVocabPosInput').value = word ? (word.pos || '') : '';
    $('dscVocabLevelInput').value = word ? (word.level || '') : '';
    $('dscVocabTagsInput').value = word ? (word.tags || []).join(',') : '';
    $('dscVocabExampleInput').value = word ? (word.example || '') : '';
    renderImagePreview();
    var overlay = $('dscVocabEditorOverlay');
    if (overlay) overlay.classList.add('open');
    setTimeout(function () { var w = $('dscVocabWordInput'); if (w) w.focus(); }, 80);
  }
  function closeEditor() {
    var overlay = $('dscVocabEditorOverlay');
    if (overlay) overlay.classList.remove('open');
    state.editingId = null;
    state.pendingImage = '';
  }
  function renderImagePreview() {
    var wrap = $('dscVocabImagePreview');
    if (!wrap) return;
    wrap.innerHTML = '';
    if (state.pendingImage) {
      var img = document.createElement('img');
      img.src = '/api/vocab/image?name=' + encodeURIComponent(state.pendingImage);
      img.alt = '';
      wrap.appendChild(img);
    } else {
      wrap.textContent = '🖼️';
    }
  }
  async function uploadImage(file) {
    if (!file) return;
    if (file.size > 10 * 1024 * 1024) { showToast('图片不能超过 10MB', 'error'); return; }
    var form = new FormData();
    form.append('file', file, file.name);
    try {
      showToast('⏳ 上传图片…', 'info');
      var res = await fetch('/api/vocab/upload', { method: 'POST', body: form });
      var data = await res.json();
      if (!res.ok) { showToast(data.error || '上传失败', 'error'); return; }
      state.pendingImage = data.name;
      renderImagePreview();
      showToast('✅ 图片已上传', 'success');
    } catch (e) { showToast('上传失败：' + e.message, 'error'); }
  }
  function removeImage() {
    state.pendingImage = '';
    renderImagePreview();
  }

  async function submitEditor() {
    var word = $('dscVocabWordInput').value.trim();
    if (!word) { showToast('单词不能为空', 'error'); return; }
    var tags = $('dscVocabTagsInput').value.split(/[,，\s]+/).map(function (s) { return s.trim(); }).filter(function (s) { return s; });
    var payload = {
      word: word,
      reading: $('dscVocabReadingInput').value.trim(),
      pitch: $('dscVocabPitchInput').value.trim(),
      meaning: $('dscVocabMeaningInput').value.trim(),
      pos: $('dscVocabPosInput').value.trim(),
      level: $('dscVocabLevelInput').value,
      tags: tags,
      example: $('dscVocabExampleInput').value,
      image: state.pendingImage || ''
    };
    if (state.editingId) payload.id = state.editingId;
    try {
      var res = await fetch('/api/vocab', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
      });
      var data = await res.json();
      if (!res.ok) { showToast(data.error || '保存失败', 'error'); return; }
      showToast(state.editingId ? '✅ 已保存' : '✅ 已添加', 'success');
      closeEditor();
      loadList(true);
    } catch (e) { showToast('保存失败：' + e.message, 'error'); }
  }

  // ============ 删除/掌握 ============
  async function deleteWord(w) {
    var ok = await showConfirmDialog('🗑️ 删除单词', '确定删除「' + w.word + '」吗？删除后不可恢复。');
    if (!ok) return;
    try {
      var res = await fetch('/api/vocab?id=' + encodeURIComponent(w.id), { method: 'DELETE' });
      var data = await res.json();
      if (!res.ok) { showToast(data.error || '删除失败', 'error'); return; }
      showToast('已删除', 'success');
      loadList(true);
    } catch (e) { showToast('删除失败', 'error'); }
  }
  async function toggleMastered(w) {
    var payload = {
      id: w.id, word: w.word, reading: w.reading || '', pitch: w.pitch || '', meaning: w.meaning || '',
      pos: w.pos || '', level: w.level || '', tags: w.tags || [],
      example: w.example || '', image: w.image || '',
      mastered: !w.mastered
    };
    try {
      var res = await fetch('/api/vocab', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
      });
      var data = await res.json();
      if (!res.ok) { showToast(data.error || '操作失败', 'error'); return; }
      showToast(w.mastered ? '已取消掌握' : '已标记掌握', 'success');
      loadList(true);
    } catch (e) { showToast('操作失败', 'error'); }
  }

  // ============ 复习 ============
  async function startReview() {
    try {
      var res = await fetch('/api/vocab?dueOnly=1&limit=500', { cache: 'no-store' });
      var data = await res.json();
      if (!res.ok) throw new Error(data.error || '加载失败');
      var q = data.words || [];
      if (!q.length) { showToast('暂无待复习单词', 'info'); return; }
      state.reviewQueue = q; state.reviewIdx = 0;
      state.reviewShowAnswer = false; state.reviewStats = { correct: 0, wrong: 0 };
      var overlay = $('dscVocabReviewOverlay');
      if (overlay) overlay.classList.add('open');
      renderReview();
    } catch (e) { showToast(e.message, 'error'); }
  }
  function closeReview() {
    var o = $('dscVocabReviewOverlay'); if (o) o.classList.remove('open');
  }
  function renderReview() {
    var body = $('dscVocabReviewBody');
    var prog = $('dscVocabReviewProgress');
    var actions = $('dscVocabReviewActions');
    if (!body) return;
    body.innerHTML = ''; if (actions) actions.innerHTML = '';

    if (state.reviewIdx >= state.reviewQueue.length) {
      var done = document.createElement('div');
      done.className = 'dsc-vocab-review-empty';
      done.innerHTML = '<span class="emoji">🎉</span>本轮复习完成！<br>答对 ' + state.reviewStats.correct + ' · 答错 ' + state.reviewStats.wrong;
      body.appendChild(done);
      if (prog) prog.textContent = '';
      if (actions) {
        var btn = document.createElement('button');
        btn.className = 'dsc-vocab-btn primary'; btn.textContent = '完成';
        btn.addEventListener('click', function () { closeReview(); loadList(true); });
        actions.appendChild(btn);
      }
      return;
    }
    var w = state.reviewQueue[state.reviewIdx];
    var card = document.createElement('div');
    card.className = 'dsc-vocab-review-card';
    var wordEl = document.createElement('div');
    wordEl.className = 'dsc-vocab-review-word';
    wordEl.textContent = w.word || '';
    card.appendChild(wordEl);
    if (w.imageUrl) {
      var wrap = document.createElement('div');
      wrap.style.cssText = 'width:100%;max-width:320px;margin:12px auto 0;aspect-ratio:4/3;border-radius:10px;overflow:hidden;background:#f3f4f6;';
      var img = document.createElement('img');
      img.src = w.imageUrl; img.style.cssText = 'width:100%;height:100%;object-fit:cover;display:block;';
      wrap.appendChild(img); card.appendChild(wrap);
    }
    if (w.reading || w.pitch) {
      var r = document.createElement('div');
      r.className = 'dsc-vocab-review-reading'; 
      r.textContent = w.reading || '';
      if (w.pitch) r.textContent += ' [' + w.pitch + ']';
      card.appendChild(r);
    }
    if (state.reviewShowAnswer) {
      var ans = document.createElement('div');
      ans.className = 'dsc-vocab-review-answer';
      var lbl = document.createElement('div'); lbl.className = 'lbl'; lbl.textContent = '释义';
      var val = document.createElement('div'); val.className = 'val'; val.textContent = w.meaning || '（无释义）';
      ans.appendChild(lbl); ans.appendChild(val);
      if (w.example) {
        var l2 = document.createElement('div'); l2.className = 'lbl'; l2.textContent = '例句';
        var v2 = document.createElement('div'); v2.className = 'val'; v2.textContent = w.example;
        ans.appendChild(l2); ans.appendChild(v2);
      }
      card.appendChild(ans);
    } else {
      var hint = document.createElement('div');
      hint.className = 'dsc-vocab-review-hint';
      hint.textContent = '想一想它的意思，然后点击下方按钮';
      card.appendChild(hint);
    }
    body.appendChild(card);
    if (prog) prog.textContent = '第 ' + (state.reviewIdx + 1) + ' / ' + state.reviewQueue.length + ' 个';
    if (!actions) return;
    if (!state.reviewShowAnswer) {
      var showBtn = document.createElement('button');
      showBtn.className = 'dsc-vocab-btn primary'; showBtn.textContent = '显示答案';
      showBtn.addEventListener('click', function () { state.reviewShowAnswer = true; renderReview(); });
      actions.appendChild(showBtn);
    } else {
      var wb = document.createElement('button');
      wb.className = 'dsc-vocab-btn wrong'; wb.textContent = '❌ 不认识';
      wb.addEventListener('click', function () { answerReview(false); });
      var cb = document.createElement('button');
      cb.className = 'dsc-vocab-btn correct'; cb.textContent = '✅ 认识';
      cb.addEventListener('click', function () { answerReview(true); });
      actions.appendChild(wb); actions.appendChild(cb);
    }
  }
  async function answerReview(correct) {
    var w = state.reviewQueue[state.reviewIdx];
    if (!w) return;
    try {
      var res = await fetch('/api/vocab/review', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id: w.id, correct: correct })
      });
      var data = await res.json();
      if (!res.ok) { showToast(data.error || '提交失败', 'error'); return; }
      if (correct) state.reviewStats.correct++; else state.reviewStats.wrong++;
      state.reviewIdx++; state.reviewShowAnswer = false;
      renderReview();
    } catch (e) { showToast('提交失败：' + e.message, 'error'); }
  }

  // ============ 事件 ============
  function rearrangeToolbar() {
    var toolbar = document.querySelector('.dsc-vocab-toolbar');
    if (!toolbar || toolbar.dataset.rearranged) return;
    toolbar.dataset.rearranged = '1';

    var search = $('dscVocabSearch');
    var level = $('dscVocabLevelFilter');
    var dueLabel = document.querySelector('.dsc-vocab-due-toggle');
    
    // 如果还没有批量按钮，补一个
    var batchBtn = document.createElement('button');
    batchBtn.className = 'dsc-vocab-icon-btn';
    batchBtn.id = 'dscVocabBatchToggleBtn';
    batchBtn.title = '批量选择';
    batchBtn.textContent = '☑️';
    batchBtn.style.cssText = 'border-radius:10px; padding:8px 12px; font-size:1rem; height:auto;';
    var headRight = document.querySelector('.dsc-vocab-head-right');
    if (headRight && !$('dscVocabBatchToggleBtn')) {
      // 插在 ＋ 号的前面
      var addBtn = $('dscVocabAddBtn');
      if (addBtn) headRight.insertBefore(batchBtn, addBtn);
      else headRight.appendChild(batchBtn);
      
      batchBtn.addEventListener('click', function() {
        // 调用全局的 batch 切换（由于在同一个闭包，直接用）
        state.batchMode = !state.batchMode;
        state.selected = {};
        renderList();
        updateBatchUI();
        var bar = document.querySelector('.dsc-vocab-batch-bar');
        if (bar) bar.classList.toggle('open', state.batchMode);
        batchBtn.style.background = state.batchMode ? '#eef2ff' : '#fff';
        batchBtn.style.color = state.batchMode ? '#4f46e5' : '#6b7280';
      });
    }

    // 重构工具栏
    toolbar.innerHTML = '';
    
    var row1 = document.createElement('div');
    row1.className = 'dsc-vocab-toolbar-row';
    row1.appendChild(search);
    
    var row2 = document.createElement('div');
    row2.className = 'dsc-vocab-toolbar-row';
    
    var rightWrap = document.createElement('div');
    rightWrap.style.cssText = 'display:flex; align-items:center; gap:12px; width:100%; justify-content: space-between;';
    rightWrap.appendChild(level);
    if (dueLabel) rightWrap.appendChild(dueLabel);
    
    row2.appendChild(rightWrap);
    
    toolbar.appendChild(row1);
    toolbar.appendChild(row2);
  }

  function bind() {
    var menuBtn = $('dscVocabBtn');
    if (menuBtn) {
      menuBtn.addEventListener('click', function (e) {
        e.stopPropagation();
        var mm = $('dscMoreMenu'), mb = $('dscMoreBtn');
        if (mm) mm.classList.remove('open');
        if (mb) mb.classList.remove('more-active');
        openVocab();
      });
    }
    var closeBtn = $('dscVocabCloseBtn');
    if (closeBtn) closeBtn.addEventListener('click', closeVocab);
    var addBtn = $('dscVocabAddBtn');
    if (addBtn) addBtn.addEventListener('click', function () { openEditor(null); });
    var reviewBtn = $('dscVocabReviewBtn');
    if (reviewBtn) reviewBtn.addEventListener('click', startReview);

    // 更多菜单
    var moreBtn = $('dscVocabMoreBtn');
    if (moreBtn) moreBtn.addEventListener('click', function (e) {
      e.stopPropagation();
      openPopmenu(moreBtn, [
        { icon: '☑️', label: state.batchMode ? '退出批量选择' : '批量选择', action: function () { setBatchMode(!state.batchMode); } },
        { icon: '🔄', label: '刷新列表', action: function () { loadList(true); } },
        { icon: '🗑️', label: '清空全部', danger: true, action: async function () {
          var ok = await showConfirmDialog('💣 清空全部', '确定清空所有单词吗？此操作不可恢复！');
          if (!ok) return;
          try {
            var res = await fetch('/api/vocab/clear', { method: 'POST' });
            var data = await res.json();
            if (!res.ok) { showToast(data.error || '清空失败', 'error'); return; }
            showToast('已清空全部单词', 'success');
            loadList(true);
          } catch (err) { showToast('清空失败', 'error'); }
        }}
      ]);
    });

    // 搜索
    var search = $('dscVocabSearch');
    if (search) {
      var timer = null;
      search.addEventListener('input', function () {
        clearTimeout(timer);
        timer = setTimeout(function () {
          state.filter.q = search.value.trim();
          loadList(true);
        }, 250);
      });
    }
    var levelSel = $('dscVocabLevelFilter');
    if (levelSel) {
      levelSel.addEventListener('change', function () {
        state.filter.level = levelSel.value;
        loadList(true);
      });
    }
    var dueCb = $('dscVocabDueOnly');
    if (dueCb) {
      dueCb.addEventListener('change', function () {
        state.filter.dueOnly = dueCb.checked;
        loadList(true);
      });
    }

    // 列表：勾选 / 更多 / 批量点卡片
    var list = $('dscVocabList');
    if (list) {
      list.addEventListener('click', function (e) {
        var more = e.target.closest ? e.target.closest('.dsc-vocab-card-more') : null;
        var cb = e.target.closest ? e.target.closest('.dsc-vocab-card-check') : null;
        var card = e.target.closest ? e.target.closest('.dsc-vocab-card') : null;
        if (more) {
          e.stopPropagation();
          var id = more.getAttribute('data-id');
          var w = findWord(id);
          if (w) openPopmenu(more, cardMenuItems(w));
          return;
        }
        if (cb) {
          e.stopPropagation();
          toggleSelect(cb.getAttribute('data-id'), cb.checked);
          return;
        }
        if (card && state.batchMode) {
          var cid = card.getAttribute('data-id');
          toggleSelect(cid, !state.selected[cid]);
        }
      });
    }

    // 批量条
    var selAll = $('dscVocabSelectAll');
    if (selAll) {
      selAll.addEventListener('change', function () {
        state.selected = {};
        if (selAll.checked) state.words.forEach(function (w) { state.selected[w.id] = true; });
        updateBatchUI();
      });
    }
    var bdel = $('dscVocabBatchDelBtn');
    if (bdel) bdel.addEventListener('click', batchDelete);
    var bcancel = $('dscVocabBatchCancelBtn');
    if (bcancel) bcancel.addEventListener('click', function () { setBatchMode(false); });

    // 编辑
    var ec = $('dscVocabEditorCancel');
    if (ec) ec.addEventListener('click', closeEditor);
    var es = $('dscVocabEditorSubmit');
    if (es) es.addEventListener('click', submitEditor);
    var eclose = $('dscVocabEditorClose');
    if (eclose) eclose.addEventListener('click', closeEditor);

    // 图片上传
    var imgInput = $('dscVocabImageInput');
    if (imgInput) imgInput.addEventListener('change', function (e) {
      var f = e.target.files && e.target.files[0];
      if (f) uploadImage(f);
      e.target.value = '';
    });
    var imgPick = $('dscVocabImagePickBtn');
    if (imgPick) imgPick.addEventListener('click', function () { if (imgInput) imgInput.click(); });
    var imgDel = $('dscVocabImageDelBtn');
    if (imgDel) imgDel.addEventListener('click', removeImage);

    // 复习
    var rc = $('dscVocabReviewClose');
    if (rc) rc.addEventListener('click', function () { closeReview(); loadList(true); });

    // 全局
    document.addEventListener('click', function (e) {
      if (popmenu && !popmenu.contains(e.target)) closePopmenu();
    }, true);
    window.addEventListener('resize', closePopmenu);

    var body = $('dscVocabBody');
    if (body) {
      body.addEventListener('scroll', function () {
        if (state.loading || !state.hasMore) return;
        if (body.scrollTop + body.clientHeight >= body.scrollHeight - 100) loadList(false);
      });
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', bind);
  } else { bind(); }
})();
