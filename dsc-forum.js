// ============================================================
// dsc-forum.js —— フォーラム投稿モジュールのフロントエンド
//   1) メイン上部バー「⋯」メニュー → 「フォーラム · 投稿広場」入口
// 2) 全画面のフォーラムページ：投稿一覧 + 投稿 + 一括選択/削除 + すべて削除
//   3) 投稿カード「⋯」メニュー：ピン留め / 注目 / 非表示 / 削除
// 4) 詳細ページで本文をスクロールして全文閲覧。非表示の投稿は本文をプレースホルダ表示
//   5) 削除 / 一括削除 / すべて削除 二次確認
// ============================================================
(function () {
  'use strict';

  var MAX_TITLE = 5000;
  var MAX_CONTENT = 5000000; // 500 万字
  var DETAIL_CHUNK = 200000;

  // ★ i18n：多言語時に日本語が混在しないよう、UI 文言はここを通す
  function T(s) {
    try {
      var a = Array.prototype.slice.call(arguments, 1);
      return (window.I18N && window.I18N.t) ? window.I18N.t.apply(window.I18N, [s].concat(a)) : s;
    } catch (e) { return s; }
  }

  function $(id) { return document.getElementById(id); }

  function escHtml(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function runeLen(s) { return Array.from(s || '').length; }

  function pad(n) { return n < 10 ? '0' + n : '' + n; }

  function fmtTime(rfc) {
    if (!rfc) return '';
    var d = new Date(rfc);
    if (isNaN(d.getTime())) return '';
    var now = new Date();
    var hm = pad(d.getHours()) + ':' + pad(d.getMinutes());
    if (d.getFullYear() === now.getFullYear() &&
        d.getMonth() === now.getMonth() &&
        d.getDate() === now.getDate()) {
      return '今日 ' + hm;
    }
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + hm;
  }

  function showToast(msg, type) {
    var wrap = $('dscToastWrap');
    if (!wrap) { console.log('[FORUM]', msg); return; }
    var el = document.createElement('div');
    el.className = 'dsc-toast ' + (type || '');
    el.textContent = msg;
    wrap.appendChild(el);
    setTimeout(function () { el.remove(); }, 2600);
  }

  // ============ 確認ダイアログ（#dscConfirmOverlay を再利用） ============
  function confirmDialog(title, msg, okText) {
    return new Promise(function (resolve) {
      var overlay = $('dscConfirmOverlay');
      var okBtn = $('dscConfirmOk');
      var cancelBtn = $('dscConfirmCancel');
      if (!overlay || !okBtn || !cancelBtn) {
        resolve(window.confirm(title + '\n\n' + msg));
        return;
      }
      $('dscConfirmTitle').textContent = title;
      $('dscConfirmMsg').textContent = msg;
      okBtn.textContent = okText || 'OK';
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

  // 二次確認（削除系の操作）
  async function confirmDelete(title, msg) {
    var first = await confirmDialog(title, msg, '削除');
    if (!first) return false;
    var second = await confirmDialog('⚠️ 再確認', 'この操作は元に戻せません。続行しますか？', '確認削除');
    return second;
  }

  // ============ 状態 ============
  var state = {
    posts: [],
    broken: 0,
    total: 0,
    hasMore: false,
    loading: false,
    pageSize: 10,
    batchMode: false,
    selected: {},
    currentId: null,
    detailPost: null,
    editingId: null,
    editingAuthor: ''
  };

  // ============ 汎用フローティング操作メニュー ============
  var popmenu = null;

  function closePopmenu() {
    if (popmenu) {
      popmenu.remove();
      popmenu = null;
    }
  }

  function openPopmenu(anchor, items) {
    closePopmenu();
    if (!items || !items.length) return;
    var menu = document.createElement('div');
    menu.className = 'dsc-forum-popmenu';
    menu.style.visibility = 'hidden';
    items.forEach(function (it) {
      var b = document.createElement('button');
      b.className = 'dsc-more-item' + (it.danger ? ' danger' : '');
      var ic = document.createElement('span');
      ic.className = 'ic';
      ic.textContent = it.icon || '';
      var tx = document.createElement('span');
      tx.className = 'tx';
      tx.textContent = it.label;
      b.appendChild(ic);
      b.appendChild(tx);
      b.addEventListener('click', function (e) {
        e.stopPropagation();
        closePopmenu();
        try { it.action(); } catch (err) { console.error('[FORUM]', err); }
      });
      menu.appendChild(b);
    });
    document.body.appendChild(menu);
    popmenu = menu;

    var pw = menu.offsetWidth || 172;
    var ph = menu.offsetHeight || items.length * 38;
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

  function closeMoreMenu() {
    var menu = $('dscMoreMenu');
    var moreBtn = $('dscMoreBtn');
    if (menu) menu.classList.remove('open');
    if (moreBtn) moreBtn.classList.remove('more-active');
  }

  // ============ フォーラムを開く / 閉じる ============
  function openForum() {
    closeMoreMenu();
    closePopmenu();
    setBatchMode(false);
    var overlay = $('dscForumOverlay');
    if (overlay) overlay.classList.add('open');
    loadList();
  }

  function closeForum() {
    closePopmenu();
    ['dscForumOverlay', 'dscForumDetailOverlay', 'dscForumComposeOverlay'].forEach(function (id) {
      var el = $(id);
      if (el) el.classList.remove('open');
    });
  }

  // ============ 列表 ============
  function renderLoading() {
    var listEl = $('dscForumList');
    if (listEl) listEl.innerHTML = '<div class="dsc-forum-empty"><span class="emoji">⏳</span>読み込み中…</div>';
  }

  function renderList() {
    var listEl = $('dscForumList');
    if (!listEl) return;
    listEl.innerHTML = '';

    if (state.broken > 0) {
      var hint = document.createElement('div');
      hint.className = 'dsc-forum-hint';
      hint.textContent = '⚠️ ' + state.broken + ' 件の投稿ファイルに異常があり、隔離してスキップしました。残りの投稿は正常に表示されます。';
      listEl.appendChild(hint);
    }

    if (!state.posts.length) {
      var empty = document.createElement('div');
      empty.className = 'dsc-forum-empty';
      empty.innerHTML = '<span class="emoji">💬</span>まだ投稿がありません。右上の「⋯」から投稿できます';
      listEl.appendChild(empty);
      return;
    }

    state.posts.forEach(function (p) {
      listEl.appendChild(buildCard(p));
    });

    // 「さらに読み込む」プレースホルダ
    var lm = document.createElement('div');
    lm.className = 'dsc-forum-loadmore';
    lm.id = 'dscForumLoadMore';
    listEl.appendChild(lm);

    updateLoadMoreUI();
    updateBatchUI();
  }

  function buildCard(p) {
    var card = document.createElement('div');
    card.className = 'dsc-forum-card';
    if (p.isPinned) card.classList.add('pinned');
    if (state.batchMode) card.classList.add('batch');
    if (state.selected[p.id]) card.classList.add('selected');
    card.setAttribute('data-id', p.id);

    var top = document.createElement('div');
    top.className = 'dsc-forum-card-top';

    var cb = document.createElement('input');
    cb.type = 'checkbox';
    cb.className = 'dsc-forum-check';
    cb.checked = !!state.selected[p.id];
    cb.setAttribute('data-id', p.id);

    var main = document.createElement('div');
    main.className = 'dsc-forum-card-main';

    var titleRow = document.createElement('div');
    titleRow.className = 'dsc-forum-card-title-row';

    var title = document.createElement('span');
    title.className = 'dsc-forum-card-title';
    title.textContent = p.title || '（無題）';

    titleRow.appendChild(title);

    if (p.isPinned) titleRow.appendChild(makeTag('pin', 'ピン留め'));
    if (p.isFeatured) titleRow.appendChild(makeTag('feature', '注目'));
    if (p.isBlocked) titleRow.appendChild(makeTag('block', '非表示中'));

    var moreBtn = document.createElement('button');
    moreBtn.className = 'dsc-forum-card-more';
    moreBtn.textContent = '⋯';
    moreBtn.title = '操作';
    moreBtn.setAttribute('data-id', p.id);
    titleRow.appendChild(moreBtn);

    var meta = document.createElement('div');
    meta.className = 'dsc-forum-card-meta';
    var author = document.createElement('span');
    author.className = 'author';
    author.textContent = p.author || '匿名';
    var time = document.createElement('span');
    time.textContent = fmtTime(p.updatedAt || p.createdAt);
    meta.appendChild(author);
    meta.appendChild(time);

    var summary = document.createElement('div');
    summary.className = 'dsc-forum-card-summary' + (p.isBlocked ? ' blocked' : '');
    if (p.isBlocked) {
      summary.textContent = '🚫 この投稿は非表示です';
    } else if (p.summary) {
      summary.textContent = p.summary;
    } else {
      summary.textContent = '（本文なし）';
    }

    main.appendChild(titleRow);
    main.appendChild(meta);
    main.appendChild(summary);

    top.appendChild(cb);
    top.appendChild(main);
    card.appendChild(top);
    return card;
  }

  function makeTag(cls, text) {
    var t = document.createElement('span');
    t.className = 'dsc-forum-tag ' + cls;
    t.textContent = text;
    return t;
  }

  // 初回表示：リストをリセットし offset=0 から読み込む
  async function loadList() {
    state.posts = [];
    state.broken = 0;
    state.total = 0;
    state.hasMore = false;
    state.loading = false;
    renderLoading();
    await loadMore();
  }

  // 次ページを追加読み込み
  async function loadMore() {
    if (state.loading || (state.posts.length > 0 && !state.hasMore)) return;
    state.loading = true;
    updateLoadMoreUI();
    var sub = $('dscForumSub');
    var offset = state.posts.length;
    try {
      var res = await fetch(
        '/api/forum/posts?offset=' + offset + '&limit=' + state.pageSize,
        { cache: 'no-store' }
      );
      var data = await res.json();
      if (!res.ok) throw new Error(data.error || '読み込みに失敗');
      var newPosts = data.posts || [];
      var existIds = {};
      state.posts.forEach(function (p) { existIds[p.id] = true; });
      newPosts.forEach(function (p) {
        if (!existIds[p.id]) { state.posts.push(p); existIds[p.id] = true; }
      });
      state.broken = data.broken || 0;
      state.total = (typeof data.total === 'number') ? data.total : state.posts.length;
      state.hasMore = !!data.hasMore;
      if (sub) sub.textContent = '全 ' + state.total + ' 件の投稿';
      renderList();
    } catch (e) {
      if (offset === 0) {
        if (sub) sub.textContent = '読み込みに失敗';
        var listEl = $('dscForumList');
        if (listEl) listEl.innerHTML = '<div class="dsc-forum-empty"><span class="emoji">⚠️</span>' + escHtml(e.message || '読み込みに失敗') + '</div>';
      } else {
        showToast('追加読み込みに失敗', 'error');
      }
    } finally {
      state.loading = false;
      updateLoadMoreUI();
    }
  }

  // 「さらに読み込む」領域の状態を更新
  function updateLoadMoreUI() {
    var lm = $('dscForumLoadMore');
    if (!lm) return;
    if (state.posts.length === 0) {
      lm.textContent = '';
      lm.style.display = 'none';
      return;
    }
    lm.style.display = '';
    if (state.loading) {
      lm.textContent = '読み込み中…';
      lm.classList.add('loading');
    } else if (state.hasMore) {
      lm.textContent = 'さらに読み込む（表示中 ' + state.posts.length + ' / ' + state.total + '）';
      lm.classList.remove('loading');
    } else {
      lm.textContent = '—— 全 ' + state.total + ' 件を読み込みました ——';
      lm.classList.remove('loading');
    }
  }

  // ============ 詳細 ============
  async function openDetail(id) {
    closePopmenu();
    var overlay = $('dscForumDetailOverlay');
    var body = $('dscForumDetailBody');
    $('dscForumDetailTitle').textContent = '投稿の詳細';
    $('dscForumDetailMeta').textContent = '';
    if (body) body.innerHTML = '<div class="dsc-forum-empty"><span class="emoji">⏳</span>読み込み中…</div>';
    if (overlay) overlay.classList.add('open');
    state.currentId = id;
    state.detailPost = null;

    try {
      var res = await fetch('/api/forum/posts/detail?id=' + encodeURIComponent(id), { cache: 'no-store' });
      var data = await res.json();
      if (!res.ok) throw new Error(data.error || '読み込みに失敗');
      state.detailPost = data.post;
      renderDetail(data.post);
    } catch (e) {
      if (body) body.innerHTML = '<div class="dsc-forum-empty"><span class="emoji">⚠️</span>' + escHtml(e.message || '読み込みに失敗') + '</div>';
    }
  }

  function renderDetail(post) {
    var body = $('dscForumDetailBody');
    var titleEl = $('dscForumDetailTitle');
    var metaEl = $('dscForumDetailMeta');
    if (titleEl) titleEl.textContent = '投稿の詳細';
    if (metaEl) metaEl.textContent = (post.author || '匿名') + ' · ' + fmtTime(post.updatedAt || post.createdAt);
    if (!body) return;
    body.innerHTML = '';

    // タイトル全体（折り返し表示可、省略しない）
    var titleBlock = document.createElement('div');
    titleBlock.className = 'dsc-forum-detail-title';
    titleBlock.textContent = post.title || '（無題）';
    body.appendChild(titleBlock);

    // 作者 / 日時 / 状態タグ
    var meta = document.createElement('div');
    meta.className = 'dsc-forum-detail-meta';
    meta.appendChild(document.createTextNode((post.author || '匿名') + ' · ' + fmtTime(post.updatedAt || post.createdAt)));
    if (post.isPinned) meta.appendChild(makeTag('pin', 'ピン留め'));
    if (post.isFeatured) meta.appendChild(makeTag('feature', '注目'));
    if (post.isBlocked) meta.appendChild(makeTag('block', '非表示中'));
    body.appendChild(meta);

    if (post.isBlocked) {
      var blocked = document.createElement('div');
      blocked.className = 'dsc-forum-detail-blocked';
      blocked.innerHTML = '<span class="emoji">🚫</span>この投稿は非表示のため、本文は見られません';
      body.appendChild(blocked);
      return;
    }

    if (!post.content) {
      var empty = document.createElement('div');
      empty.className = 'dsc-forum-empty';
      empty.textContent = '（本文なし）';
      body.appendChild(empty);
      return;
    }

    // 長い本文を分割描画：各段 ≤ DETAIL_CHUNK 文字、かつサロゲートペアを分断しない
    appendContentChunks(body, post.content);
  }

  function appendContentChunks(body, content) {
    var i = 0;
    while (i < content.length) {
      var end = Math.min(i + DETAIL_CHUNK, content.length);
      if (end < content.length) {
        var c = content.charCodeAt(end - 1);
        if (c >= 0xD800 && c <= 0xDBFF) end++;
      }
      var p = document.createElement('div');
      p.className = 'dsc-forum-detail-chunk';
      p.textContent = content.slice(i, end);
      body.appendChild(p);
      i = end;
    }
  }

  function closeDetail() {
    closePopmenu();
    var overlay = $('dscForumDetailOverlay');
    if (overlay) overlay.classList.remove('open');
    state.currentId = null;
    state.detailPost = null;
  }

  // ============ 投稿する ============
  function setComposeMode(isEdit) {
    var titleEl = $('dscForumComposeTitle');
    var submitBtn = $('dscForumComposeSubmitBtn');
    if (titleEl) titleEl.textContent = isEdit ? '✏️ 投稿を編集' : '✍️ 投稿する';
    if (submitBtn) submitBtn.textContent = isEdit ? '保存' : '公開';
  }

  function openCompose() {
    closePopmenu();
    state.editingId = null;
    state.editingAuthor = '';
    $('dscForumTitleInput').value = '';
    $('dscForumContentInput').value = '';
    $('dscForumTitleCount').textContent = '0';
    $('dscForumTitleCount').className = 'cnt';
    $('dscForumContentCount').textContent = '0';
    $('dscForumContentCount').className = 'cnt';
    setComposeMode(false);
    var overlay = $('dscForumComposeOverlay');
    if (overlay) overlay.classList.add('open');
    setTimeout(function () {
      var t = $('dscForumTitleInput');
      if (t) t.focus();
    }, 80);
  }

  // 既存の投稿を編集：本文全体を取得して投稿フォームに流し込む
  async function openEdit(post) {
    if (!post || !post.id) return;
    closePopmenu();
    var full = post;
    if (full.content == null) {
      try {
        var res = await fetch('/api/forum/posts/detail?id=' + encodeURIComponent(post.id), { cache: 'no-store' });
        var data = await res.json();
        if (res.ok && data.post) full = data.post;
      } catch (e) {
        console.error('[FORUM] 編集データの読み込みに失敗', e);
      }
    }
    state.editingId = full.id;
    state.editingAuthor = full.author || '匿名';
    $('dscForumTitleInput').value = full.title || '';
    $('dscForumContentInput').value = full.content || '';
    var ti = $('dscForumTitleInput');
    if (ti) ti.dispatchEvent(new Event('input'));
    var ci = $('dscForumContentInput');
    if (ci) ci.dispatchEvent(new Event('input'));
    setComposeMode(true);
    var overlay = $('dscForumComposeOverlay');
    if (overlay) overlay.classList.add('open');
    setTimeout(function () {
      var t = $('dscForumTitleInput');
      if (t) t.focus();
    }, 80);
  }

  function closeCompose() {
    closePopmenu();
    var overlay = $('dscForumComposeOverlay');
    if (overlay) overlay.classList.remove('open');
  }

  async function submitCompose() {
    var title = $('dscForumTitleInput').value.trim();
    var content = $('dscForumContentInput').value;
    if (!title) { showToast('タイトルを入力してください', 'error'); return; }
    var tl = runeLen(title);
    var cl = runeLen(content);
    if (tl > MAX_TITLE) { showToast('タイトルは最大 ' + MAX_TITLE + ' 文字、現在 ' + tl + ' 字', 'error'); return; }
    if (cl > MAX_CONTENT) { showToast('本文は最大 ' + MAX_CONTENT + ' 文字、現在 ' + cl + ' 字', 'error'); return; }

    var payload = { title: title, content: content, author: state.editingAuthor || '匿名' };
    if (state.editingId) payload.id = state.editingId;

    try {
      var res = await fetch('/api/forum/posts', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
      });
      var data = await res.json();
      if (!res.ok) { showToast(data.error || '公開に失敗', 'error'); return; }
      showToast(state.editingId ? '✅ 変更を保存しました' : '✅ 公開しました', 'success');
      closeCompose();
      loadList();
      // 同じ投稿の詳細を表示中なら同時に更新
      if (state.currentId && state.editingId === state.currentId) {
        try {
          var fresh = await fetch('/api/forum/posts/detail?id=' + encodeURIComponent(state.currentId), { cache: 'no-store' });
          var fd = await fresh.json();
          if (fresh.ok && fd.post) { state.detailPost = fd.post; renderDetail(fd.post); }
        } catch (e) {}
      }
      state.editingId = null;
      state.editingAuthor = '';
    } catch (e) {
      showToast('公開に失敗：' + (e.message || e), 'error');
    }
  }

  // ============ 操作 ============
  async function doAction(id, action, value) {
    try {
      var res = await fetch('/api/forum/posts/action', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id: id, action: action, value: value })
      });
      var data = await res.json();
      if (!res.ok) { showToast(data.error || '操作に失敗', 'error'); return; }
      showToast('操作に成功しました', 'success');
      await loadList();
      // 詳細ページの同時更新
      if (state.currentId === id && $('dscForumDetailOverlay').classList.contains('open')) {
        var p = data.post;
        if (p) {
          state.detailPost = p;
          var fresh = await fetch('/api/forum/posts/detail?id=' + encodeURIComponent(id), { cache: 'no-store' });
          var fd = await fresh.json();
          if (fresh.ok && fd.post) { state.detailPost = fd.post; renderDetail(fd.post); }
        }
      }
    } catch (e) {
      showToast('操作に失敗', 'error');
    }
  }

  function togglePin(post) {
    var target = !post.isPinned;
    confirmDialog('📌 ' + (target ? 'ピン留め' : 'ピン留めを解除'),
      'OK要' + (target ? 'ピン留め' : 'ピン留めを解除') + 'この投稿ですか？', target ? 'ピン留め' : 'ピン留めを解除')
      .then(function (ok) { if (ok) doAction(post.id, 'pin', target); });
  }

  function toggleFeature(post) {
    var target = !post.isFeatured;
    confirmDialog('💎 ' + (target ? '注目' : '注目を解除'),
      'OK要' + (target ? '注目' : '注目を解除') + 'この投稿ですか？', target ? '注目' : '注目を解除')
      .then(function (ok) { if (ok) doAction(post.id, 'feature', target); });
  }

  function toggleBlock(post) {
    var target = !post.isBlocked;
    confirmDialog('🚫 ' + (target ? '非表示' : '非表示を解除'),
      'OK要' + (target ? '非表示' : '非表示を解除') + 'この投稿ですか？', target ? '非表示' : '非表示を解除')
      .then(function (ok) { if (ok) doAction(post.id, 'block', target); });
  }

  function deleteSingle(post) {
    confirmDelete(T('🗑️ 投稿を削除'), T('「{0}」を削除しますか？削除後は元に戻せません。', (post.title || post.id)))
      .then(async function (ok) {
        if (!ok) return;
        try {
          var res = await fetch('/api/forum/posts/delete?id=' + encodeURIComponent(post.id), { method: 'DELETE' });
          var data = await res.json();
          if (!res.ok) { showToast(data.error || '削除に失敗しました', 'error'); return; }
          showToast('削除しました', 'success');
          if (state.currentId === post.id) closeDetail();
          delete state.selected[post.id];
          loadList();
        } catch (e) { showToast('削除に失敗しました', 'error'); }
      });
  }

  async function batchDelete() {
    var ids = Object.keys(state.selected);
    if (!ids.length) { showToast('削除する投稿を先に選択してください', 'error'); return; }
    var ok = await confirmDelete('🗑️ 一括削除', '選択した ' + ids.length + ' 件の投稿を削除しますか？削除後は元に戻せません。');
    if (!ok) return;
    try {
      var res = await fetch('/api/forum/posts/delete', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ids: ids })
      });
      var data = await res.json();
      if (!res.ok) { showToast(data.error || '削除に失敗しました', 'error'); return; }
      showToast('削除しました：' + (data.deleted || ids.length) + ' 件の投稿', 'success');
      state.selected = {};
      setBatchMode(false);
      loadList();
    } catch (e) { showToast('削除に失敗しました', 'error'); }
  }

  async function clearAllPosts() {
    var n = state.posts.length;
    if (!n) { showToast('現在投稿はありません', 'info'); return; }
    var ok = await confirmDelete('💣 すべて削除',
      'すべての ' + n + ' 件の投稿を削除しますか？この操作は元に戻せません！');
    if (!ok) return;
    try {
      var res = await fetch('/api/forum/posts/clear', { method: 'POST' });
      var data = await res.json();
      if (!res.ok) { showToast(data.error || '削除に失敗しました', 'error'); return; }
      showToast('すべての投稿を削除しました', 'success');
      state.selected = {};
      setBatchMode(false);
      loadList();
    } catch (e) { showToast('削除に失敗しました', 'error'); }
  }

  // ============ 批量模式 ============
  function setBatchMode(on) {
    state.batchMode = !!on;
    if (!on) state.selected = {};
    var bar = $('dscForumBatchBar');
    if (bar) bar.classList.toggle('open', !!on);
    renderList();
  }

  function updateBatchUI() {
    var sel = Object.keys(state.selected);
    var count = $('dscForumBatchCount');
    if (count) count.textContent = '選択 ' + sel.length;
    var delBtn = $('dscForumBatchDelBtn');
    if (delBtn) delBtn.disabled = sel.length === 0;
    var all = $('dscForumSelectAll');
    if (all) all.checked = state.posts.length > 0 && sel.length === state.posts.length;

    var listEl = $('dscForumList');
    if (!listEl) return;
    listEl.querySelectorAll('.dsc-forum-card').forEach(function (card) {
      var id = card.getAttribute('data-id');
      card.classList.toggle('selected', !!state.selected[id]);
      var cb = card.querySelector('.dsc-forum-check');
      if (cb) cb.checked = !!state.selected[id];
    });
  }

  function toggleSelect(id, checked) {
    if (checked) state.selected[id] = true; else delete state.selected[id];
    updateBatchUI();
  }

  // ============ フォーラムページ上部「⋯」メニュー項目 ============
  function forumMenuItems() {
    var selCount = Object.keys(state.selected).length;
    return [
      { icon: '✍️', label: '投稿する', action: openCompose },
      { icon: '☑️', label: state.batchMode ? '一括選択を終了' : '一括選択', action: function () { setBatchMode(!state.batchMode); } },
      { icon: '🗑️', label: '一括削除（選択 ' + selCount + '）', danger: true, action: batchDelete },
      { icon: '💣', label: 'すべて削除', danger: true, action: clearAllPosts }
    ];
  }

  function cardMenuItems(post) {
    return [
      { icon: '✏️', label: '編集', action: function () { openEdit(post); } },
      { icon: '📌', label: post.isPinned ? 'ピン留めを解除' : 'ピン留め', action: function () { togglePin(post); } },
      { icon: '💎', label: post.isFeatured ? '注目を解除' : '注目', action: function () { toggleFeature(post); } },
      { icon: '🚫', label: post.isBlocked ? '非表示を解除' : '非表示', action: function () { toggleBlock(post); } },
      { icon: '🗑️', label: '削除', danger: true, action: function () { deleteSingle(post); } }
    ];
  }

  function findPost(id) {
    for (var i = 0; i < state.posts.length; i++) {
      if (state.posts[i].id === id) return state.posts[i];
    }
    return state.detailPost && state.detailPost.id === id ? state.detailPost : null;
  }

  // ============ イベントバインド ============
  function bind() {
    // メイン上部バーの入口
    var entry = $('dscForumBtn');
    if (entry) entry.addEventListener('click', function (e) { e.stopPropagation(); openForum(); });

    // フォーラムページ上部
    var moreBtn = $('dscForumMoreBtn');
    if (moreBtn) moreBtn.addEventListener('click', function (e) { e.stopPropagation(); openPopmenu(moreBtn, forumMenuItems()); });
    var closeBtn = $('dscForumCloseBtn');
    if (closeBtn) closeBtn.addEventListener('click', closeForum);

    // 一括操作バー
    var selectAll = $('dscForumSelectAll');
    if (selectAll) selectAll.addEventListener('change', function () {
      state.selected = {};
      if (selectAll.checked) state.posts.forEach(function (p) { state.selected[p.id] = true; });
      updateBatchUI();
    });
    var batchDel = $('dscForumBatchDelBtn');
    if (batchDel) batchDel.addEventListener('click', batchDelete);
    var batchCancel = $('dscForumBatchCancelBtn');
    if (batchCancel) batchCancel.addEventListener('click', function () { setBatchMode(false); });

    // さらに読み込むボタン（イベント委譲、ノードは再生成される）
    var listElForMore = $('dscForumList');
    if (listElForMore) listElForMore.addEventListener('click', function (e) {
      var lm = e.target.closest ? e.target.closest('#dscForumLoadMore') : null;
      if (lm && state.hasMore && !state.loading) {
        e.stopPropagation();
        loadMore();
      }
    });

    // リスト：イベント委譲（カードのタップ → 詳細 / チェック / メニュー）
    var listEl = $('dscForumList');
    if (listEl) listEl.addEventListener('click', function (e) {
      var more = e.target.closest ? e.target.closest('.dsc-forum-card-more') : null;
      var cb = e.target.closest ? e.target.closest('.dsc-forum-check') : null;
      var card = e.target.closest ? e.target.closest('.dsc-forum-card') : null;

      if (more) {
        e.stopPropagation();
        var id = more.getAttribute('data-id');
        var post = findPost(id);
        if (post) openPopmenu(more, cardMenuItems(post));
        return;
      }
      if (cb) {
        e.stopPropagation();
        toggleSelect(cb.getAttribute('data-id'), cb.checked);
        return;
      }
      if (card) {
        var id = card.getAttribute('data-id');
        if (state.batchMode) {
          toggleSelect(id, !state.selected[id]);
        } else {
          openDetail(id);
        }
      }
    });

    // 詳細ページ
    var backBtn = $('dscForumDetailBackBtn');
    if (backBtn) backBtn.addEventListener('click', closeDetail);
    var detailClose = $('dscForumDetailCloseBtn');
    if (detailClose) detailClose.addEventListener('click', function () { closeDetail(); closeForum(); });
    var detailMore = $('dscForumDetailMoreBtn');
    if (detailMore) detailMore.addEventListener('click', function (e) {
      e.stopPropagation();
      var post = state.detailPost || findPost(state.currentId);
      if (post) openPopmenu(detailMore, cardMenuItems(post));
    });

    // 投稿する页
    var composeCancel = $('dscForumComposeCancelBtn');
    if (composeCancel) composeCancel.addEventListener('click', closeCompose);
    var composeSubmit = $('dscForumComposeSubmitBtn');
    if (composeSubmit) composeSubmit.addEventListener('click', submitCompose);

    // 文字数カウント
    var titleInput = $('dscForumTitleInput');
    var contentInput = $('dscForumContentInput');
    if (titleInput) titleInput.addEventListener('input', function () {
      var n = runeLen(titleInput.value);
      var c = $('dscForumTitleCount');
      if (c) { c.textContent = n; c.className = n > MAX_TITLE ? 'cnt over' : 'cnt'; }
    });
    if (contentInput) contentInput.addEventListener('input', function () {
      var n = runeLen(contentInput.value);
      var c = $('dscForumContentCount');
      if (c) { c.textContent = n; c.className = n > MAX_CONTENT ? 'cnt over' : 'cnt'; }
    });

    // 全体：空白をタップでフローティングメニューを閉じる
    document.addEventListener('click', function (e) {
      if (popmenu && !popmenu.contains(e.target)) closePopmenu();
    }, true);
    window.addEventListener('resize', closePopmenu);
    ['dscForumBody', 'dscForumDetailBody'].forEach(function (id) {
      var el = $(id);
      if (el) el.addEventListener('scroll', closePopmenu);
    });

    // リストのスクロールが最下部に近づくと自動で追加読み込み
    var forumBody = $('dscForumBody');
    if (forumBody) forumBody.addEventListener('scroll', function () {
      if (state.loading || !state.hasMore) return;
      if (forumBody.scrollTop + forumBody.clientHeight >= forumBody.scrollHeight - 120) {
        loadMore();
      }
    });
  }

  function start() { bind(); }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }
})();
