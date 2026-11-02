// ============================================================
// dsc-vocab.js —— 日本語単語帳 v2
// 分割行タブ / 検索 / 一括選択 / 画像アップロード / 4:3 サムネイル
// ============================================================
(function () {
  'use strict';

  var KANA_ROWS = ['すべて', 'その他'];
  // [FIX] 仮名欄を全件表示

  var state = {
    words: [],
    total: 0, totalAll: 0, due: 0, mastered: 0,
    hasMore: false, loading: false, offset: 0, pageSize: 30,
    rowStats: {},
    currentRow: 'すべて',
    filter: { q: '', level: '', dueOnly: false },
    batchMode: false, selected: {},
    editingId: null,
    pendingImage: '', // 編集中の画像名
    reviewQueue: [], reviewIdx: 0, reviewShowAnswer: false,
    reviewStats: { correct: 0, wrong: 0 }
  };

  
  // ============ 統一された美しい確認ダイアログ ============
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
    if (days < 0) return '期限が到来';
    if (days === 0) return '今日';
    if (days === 1) return '明日';
    if (days < 30) return days + ' 日後';
    return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
  }

  // ============ 開く / 閉じる ============
  function openVocab() {
    rearrangeToolbar();
    var overlay = $('dscVocabOverlay');
    if (!overlay) { showToast('単語帳の画面が未読み込み', 'error'); return; }
    overlay.classList.add('open');
    renderRowTabs();
    loadList(true);
  }
  function closeVocab() {
    var overlay = $('dscVocabOverlay');
    if (overlay) overlay.classList.remove('open');
    setBatchMode(false);
  }

  // ============ 分片行タグ ============
      function renderRowTabs() {
    var wrap = $('dscVocabRowTabs');
    if (!wrap) return;
    wrap.innerHTML = '';
    KANA_ROWS.forEach(function (row) {
      var btn = document.createElement('button');
      btn.className = 'dsc-vocab-row-tab' + (state.currentRow === row ? ' active' : '');
      var cnt = row === 'すべて' ? state.totalAll : (state.rowStats[row] || 0);
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
    fullBtn.textContent = '🔍 かな検索';
    fullBtn.title = 'かな一覧を開き、クリックでその仮名を含む単語に絞り込み';
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
    header.innerHTML = '<div style="font-size:1.15rem;font-weight:800;color:#1f2937;">🔍 日本語かな一覧</div>' +
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
      if (sub) sub.textContent = '絞り込み中：含む「' + ch + '」';
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

    scrollArea.appendChild(buildSection('濁音 / 半濁音', [
      ['が', 'ぎ', 'ぐ', 'げ', 'ご'], ['ざ', 'じ', 'ず', 'ぜ', 'ぞ'], ['だ', 'ぢ', 'づ', 'で', 'ど'], ['ば', 'び', 'ぶ', 'べ', 'ぼ'], ['ぱ', 'ぴ', 'ぷ', 'ぺ', 'ぽ']
    ], 5));

    scrollArea.appendChild(buildSection('拗音（清）', [
      ['きゃ', 'きゅ', 'きょ'], ['しゃ', 'しゅ', 'しょ'], ['ちゃ', 'ちゅ', 'ちょ'], ['にゃ', 'にゅ', 'にょ'], ['ひゃ', 'ひゅ', 'ひょ'], ['みゃ', 'みゅ', 'みょ'], ['りゃ', 'りゅ', 'りょ']
    ], 3));

    scrollArea.appendChild(buildSection('拗音（濁／半濁）', [
      ['ぎゃ', 'ぎゅ', 'ぎょ'], ['じゃ', 'じゅ', 'じょ'], ['びゃ', 'びゅ', 'びょ'], ['ぴゃ', 'ぴゅ', 'ぴょ']
    ], 3));

    scrollArea.appendChild(buildSection('特殊 / 小文字', [
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
      if (state.currentRow !== 'すべて') qs.set('row', state.currentRow);
      var res = await fetch('/api/vocab?' + qs.toString(), { cache: 'no-store' });
      var data = await res.json();
      if (!res.ok) throw new Error(data.error || '読み込みに失敗');
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
      var parts = ['全 ' + state.totalAll + ' 語'];
      if (state.due > 0) parts.push('復習待ち ' + state.due);
      if (state.mastered > 0) parts.push('習得済み ' + state.mastered);
      sub.textContent = parts.join(' · ');
    }
    var reviewBtn = $('dscVocabReviewBtn');
    if (reviewBtn) {
      reviewBtn.classList.toggle('primary', state.due > 0);
      reviewBtn.title = state.due > 0 ? ('復習を開始（' + state.due + '）') : '復習待ちなし';
    }
  }

  function renderList() {
    var list = $('dscVocabList');
    if (!list) return;
    list.innerHTML = '';
    if (!state.words.length) {
      var empty = document.createElement('div');
      empty.className = 'dsc-vocab-empty';
      var hint = (state.filter.q || state.filter.level || state.filter.dueOnly || state.currentRow !== 'すべて')
        ? '条件に合う単語がありません' : '単語がまだありません。右上をタップ ＋ 追加';
      empty.innerHTML = '<span class="emoji">📖</span>' + hint;
      list.appendChild(empty);
      return;
    }
    state.words.forEach(function (w) { list.appendChild(buildCard(w)); });
    if (state.hasMore) {
      var lm = document.createElement('div');
      lm.className = 'dsc-vocab-loadmore';
      lm.textContent = 'さらに読み込む（表示中 ' + state.words.length + ' / ' + state.total + '）';
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

    // 大きな画像表示に戻し、画像がなければ完全に非表示
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
    meaning.textContent = w.meaning || '（意味なし）';
    main.appendChild(meaning);

    var meta = document.createElement('div');
    meta.className = 'dsc-vocab-card-meta';
    if (w.level) {
      var lt = document.createElement('span'); lt.className = 'tag level'; lt.textContent = w.level; meta.appendChild(lt);
    }
    if (w.mastered) {
      var mt = document.createElement('span'); mt.className = 'tag mastered'; mt.textContent = '習得済み'; meta.appendChild(mt);
    } else if (isDue(w)) {
      var dt = document.createElement('span'); dt.className = 'tag due'; dt.textContent = '復習待ち'; meta.appendChild(dt);
    } else if (w.nextReviewAt) {
      var nt = document.createElement('span'); nt.textContent = '次回 ' + fmtNextReview(w.nextReviewAt); meta.appendChild(nt);
    }
    if (w.reviewCount > 0) {
      var rt = document.createElement('span'); rt.textContent = '復習 ' + w.reviewCount + ' 回'; meta.appendChild(rt);
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

  // ============ フローティングメニュー ============
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
      { icon: '✏️', label: '編集', action: function () { openEditor(w); } },
      { icon: w.mastered ? '↩️' : '✅', label: w.mastered ? '習得済みを解除' : '習得済みにする', action: function () { toggleMastered(w); } },
      { icon: '🗑️', label: '削除', danger: true, action: function () { deleteWord(w); } }
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
    if (cnt) cnt.textContent = '選択 ' + sel.length;
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
    if (!ids.length) { showToast('削除する単語を先に選択してください', 'error'); return; }
    var ok = await showConfirmDialog('🗑️ 一括削除', '選択した ' + ids.length + ' 語を削除しますか？元に戻せません！');
    if (!ok) return;
    try {
      var res = await fetch('/api/vocab?ids=' + encodeURIComponent(ids.join(',')), { method: 'DELETE' });
      var data = await res.json();
      if (!res.ok) { showToast(data.error || '削除に失敗しました', 'error'); return; }
      showToast('削除しました：' + (data.deleted || ids.length) + ' 件', 'success');
      state.selected = {};
      setBatchMode(false);
      loadList(true);
    } catch (e) { showToast('削除に失敗しました', 'error'); }
  }

  // ============ 編集（画像を含む） ============
  function openEditor(word) {
    state.editingId = word ? word.id : null;
    state.pendingImage = word ? (word.image || '') : '';
    var t = $('dscVocabEditorTitle');
    if (t) t.textContent = word ? '✏️ 単語を編集' : '✍️ 単語を追加';
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
    if (file.size > 10 * 1024 * 1024) { showToast('画像は 10MB を超えられません', 'error'); return; }
    var form = new FormData();
    form.append('file', file, file.name);
    try {
      showToast('⏳ 画像をアップロード中…', 'info');
      var res = await fetch('/api/vocab/upload', { method: 'POST', body: form });
      var data = await res.json();
      if (!res.ok) { showToast(data.error || 'アップロードに失敗', 'error'); return; }
      state.pendingImage = data.name;
      renderImagePreview();
      showToast('✅ 画像をアップロードしました', 'success');
    } catch (e) { showToast('アップロードに失敗：' + e.message, 'error'); }
  }
  function removeImage() {
    state.pendingImage = '';
    renderImagePreview();
  }

  async function submitEditor() {
    var word = $('dscVocabWordInput').value.trim();
    if (!word) { showToast('単語を入力してください', 'error'); return; }
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
      if (!res.ok) { showToast(data.error || '保存に失敗しました', 'error'); return; }
      showToast(state.editingId ? '✅ 保存しました' : '✅ 追加しました', 'success');
      closeEditor();
      loadList(true);
    } catch (e) { showToast('保存に失敗：' + e.message, 'error'); }
  }

  // ============ 削除/掌握 ============
  async function deleteWord(w) {
    var ok = await showConfirmDialog('🗑️ 単語を削除', '「' + w.word + '」を削除しますか？削除後は元に戻せません。');
    if (!ok) return;
    try {
      var res = await fetch('/api/vocab?id=' + encodeURIComponent(w.id), { method: 'DELETE' });
      var data = await res.json();
      if (!res.ok) { showToast(data.error || '削除に失敗しました', 'error'); return; }
      showToast('削除しました', 'success');
      loadList(true);
    } catch (e) { showToast('削除に失敗しました', 'error'); }
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
      if (!res.ok) { showToast(data.error || '操作に失敗', 'error'); return; }
      showToast(w.mastered ? '習得済みを解除しました' : '習得済みにしました', 'success');
      loadList(true);
    } catch (e) { showToast('操作に失敗', 'error'); }
  }

  // ============ 復習 ============
  async function startReview() {
    try {
      var res = await fetch('/api/vocab?dueOnly=1&limit=500', { cache: 'no-store' });
      var data = await res.json();
      if (!res.ok) throw new Error(data.error || '読み込みに失敗');
      var q = data.words || [];
      if (!q.length) { showToast('復習待ちの単語はありません', 'info'); return; }
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
      done.innerHTML = '<span class="emoji">🎉</span>今回の復習は完了！<br>正解 ' + state.reviewStats.correct + ' · 不正解 ' + state.reviewStats.wrong;
      body.appendChild(done);
      if (prog) prog.textContent = '';
      if (actions) {
        var btn = document.createElement('button');
        btn.className = 'dsc-vocab-btn primary'; btn.textContent = '完了';
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
      var lbl = document.createElement('div'); lbl.className = 'lbl'; lbl.textContent = '意味';
      var val = document.createElement('div'); val.className = 'val'; val.textContent = w.meaning || '（意味なし）';
      ans.appendChild(lbl); ans.appendChild(val);
      if (w.example) {
        var l2 = document.createElement('div'); l2.className = 'lbl'; l2.textContent = '例文';
        var v2 = document.createElement('div'); v2.className = 'val'; v2.textContent = w.example;
        ans.appendChild(l2); ans.appendChild(v2);
      }
      card.appendChild(ans);
    } else {
      var hint = document.createElement('div');
      hint.className = 'dsc-vocab-review-hint';
      hint.textContent = '意味を考えてから、下のボタンをタップしてください';
      card.appendChild(hint);
    }
    body.appendChild(card);
    if (prog) prog.textContent = '第 ' + (state.reviewIdx + 1) + ' / ' + state.reviewQueue.length + ' 件';
    if (!actions) return;
    if (!state.reviewShowAnswer) {
      var showBtn = document.createElement('button');
      showBtn.className = 'dsc-vocab-btn primary'; showBtn.textContent = '答えを表示';
      showBtn.addEventListener('click', function () { state.reviewShowAnswer = true; renderReview(); });
      actions.appendChild(showBtn);
    } else {
      var wb = document.createElement('button');
      wb.className = 'dsc-vocab-btn wrong'; wb.textContent = '❌ わからない';
      wb.addEventListener('click', function () { answerReview(false); });
      var cb = document.createElement('button');
      cb.className = 'dsc-vocab-btn correct'; cb.textContent = '✅ わかる';
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
      if (!res.ok) { showToast(data.error || '送信に失敗', 'error'); return; }
      if (correct) state.reviewStats.correct++; else state.reviewStats.wrong++;
      state.reviewIdx++; state.reviewShowAnswer = false;
      renderReview();
    } catch (e) { showToast('送信に失敗：' + e.message, 'error'); }
  }

  // ============ 事件 ============
  function rearrangeToolbar() {
    var toolbar = document.querySelector('.dsc-vocab-toolbar');
    if (!toolbar || toolbar.dataset.rearranged) return;
    toolbar.dataset.rearranged = '1';

    var search = $('dscVocabSearch');
    var level = $('dscVocabLevelFilter');
    var dueLabel = document.querySelector('.dsc-vocab-due-toggle');
    
    // 一括ボタンがまだなければ 1 つ追加する
    var batchBtn = document.createElement('button');
    batchBtn.className = 'dsc-vocab-icon-btn';
    batchBtn.id = 'dscVocabBatchToggleBtn';
    batchBtn.title = '一括選択';
    batchBtn.textContent = '☑️';
    batchBtn.style.cssText = 'border-radius:10px; padding:8px 12px; font-size:1rem; height:auto;';
    var headRight = document.querySelector('.dsc-vocab-head-right');
    if (headRight && !$('dscVocabBatchToggleBtn')) {
      // ＋ 記号の前に挿入
      var addBtn = $('dscVocabAddBtn');
      if (addBtn) headRight.insertBefore(batchBtn, addBtn);
      else headRight.appendChild(batchBtn);
      
      batchBtn.addEventListener('click', function() {
        // グローバルの batch 切替を呼ぶ（同じクロージャ内なので直接使う）
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

    // ツールバーを再構築
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

    // その他メニュー
    var moreBtn = $('dscVocabMoreBtn');
    if (moreBtn) moreBtn.addEventListener('click', function (e) {
      e.stopPropagation();
      openPopmenu(moreBtn, [
        { icon: '☑️', label: state.batchMode ? '一括選択を終了' : '一括選択', action: function () { setBatchMode(!state.batchMode); } },
        { icon: '🔄', label: '一覧を更新', action: function () { loadList(true); } },
        { icon: '🗑️', label: 'すべて消去', danger: true, action: async function () {
          var ok = await showConfirmDialog('💣 すべて消去', 'すべての単語を消去しますか？この操作は元に戻せません！');
          if (!ok) return;
          try {
            var res = await fetch('/api/vocab/clear', { method: 'POST' });
            var data = await res.json();
            if (!res.ok) { showToast(data.error || '消去に失敗', 'error'); return; }
            showToast('すべての単語を消去しました', 'success');
            loadList(true);
          } catch (err) { showToast('消去に失敗', 'error'); }
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

    // リスト：チェック / その他 / 一括でカードをタップ
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

    // 一括バー
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

    // 編集
    var ec = $('dscVocabEditorCancel');
    if (ec) ec.addEventListener('click', closeEditor);
    var es = $('dscVocabEditorSubmit');
    if (es) es.addEventListener('click', submitEditor);
    var eclose = $('dscVocabEditorClose');
    if (eclose) eclose.addEventListener('click', closeEditor);

    // 画像アップロード
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

    // 復習
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
