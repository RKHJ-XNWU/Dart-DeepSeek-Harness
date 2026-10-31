// ============================================================
// dsc-forum.js —— 论坛帖子模块前端
//   1) 主顶栏「⋯」菜单 → 「论坛 · 帖子广场」入口
//   2) 全屏论坛页：帖子列表 + 发帖 + 批量选择/删除 + 全部删除
//   3) 帖子卡片「⋯」菜单：置顶 / 加精 / 屏蔽 / 删除
//   4) 详情页完整滚动阅读正文；屏蔽帖正文以占位展示
//   5) 删除 / 批量删除 / 全部删除 二次确认
// ============================================================
(function () {
  'use strict';

  var MAX_TITLE = 5000;
  var MAX_CONTENT = 5000000; // 500 万字
  var DETAIL_CHUNK = 200000;

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
      return '今天 ' + hm;
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

  // ============ 确认弹层（复用 #dscConfirmOverlay） ============
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
      okBtn.textContent = okText || '确定';
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

  // 二次确认（删除类操作）
  async function confirmDelete(title, msg) {
    var first = await confirmDialog(title, msg, '删除');
    if (!first) return false;
    var second = await confirmDialog('⚠️ 二次确认', '此操作不可恢复，确定要继续吗？', '确认删除');
    return second;
  }

  // ============ 状态 ============
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

  // ============ 通用悬浮操作菜单 ============
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

  // ============ 打开 / 关闭论坛 ============
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
    if (listEl) listEl.innerHTML = '<div class="dsc-forum-empty"><span class="emoji">⏳</span>加载中…</div>';
  }

  function renderList() {
    var listEl = $('dscForumList');
    if (!listEl) return;
    listEl.innerHTML = '';

    if (state.broken > 0) {
      var hint = document.createElement('div');
      hint.className = 'dsc-forum-hint';
      hint.textContent = '⚠️ 有 ' + state.broken + ' 个帖子文件异常，已隔离跳过，其余帖子正常展示。';
      listEl.appendChild(hint);
    }

    if (!state.posts.length) {
      var empty = document.createElement('div');
      empty.className = 'dsc-forum-empty';
      empty.innerHTML = '<span class="emoji">💬</span>还没有帖子，点击右上角「⋯」发帖';
      listEl.appendChild(empty);
      return;
    }

    state.posts.forEach(function (p) {
      listEl.appendChild(buildCard(p));
    });

    // 「加载更多」占位
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
    title.textContent = p.title || '（无标题）';

    titleRow.appendChild(title);

    if (p.isPinned) titleRow.appendChild(makeTag('pin', '置顶'));
    if (p.isFeatured) titleRow.appendChild(makeTag('feature', '精华'));
    if (p.isBlocked) titleRow.appendChild(makeTag('block', '已屏蔽'));

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
      summary.textContent = '🚫 该帖子已被屏蔽';
    } else if (p.summary) {
      summary.textContent = p.summary;
    } else {
      summary.textContent = '（无正文）';
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

  // 首屏：重置列表并从 offset=0 加载
  async function loadList() {
    state.posts = [];
    state.broken = 0;
    state.total = 0;
    state.hasMore = false;
    state.loading = false;
    renderLoading();
    await loadMore();
  }

  // 追加加载下一页
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
      if (!res.ok) throw new Error(data.error || '加载失败');
      var newPosts = data.posts || [];
      var existIds = {};
      state.posts.forEach(function (p) { existIds[p.id] = true; });
      newPosts.forEach(function (p) {
        if (!existIds[p.id]) { state.posts.push(p); existIds[p.id] = true; }
      });
      state.broken = data.broken || 0;
      state.total = (typeof data.total === 'number') ? data.total : state.posts.length;
      state.hasMore = !!data.hasMore;
      if (sub) sub.textContent = '共 ' + state.total + ' 篇帖子';
      renderList();
    } catch (e) {
      if (offset === 0) {
        if (sub) sub.textContent = '加载失败';
        var listEl = $('dscForumList');
        if (listEl) listEl.innerHTML = '<div class="dsc-forum-empty"><span class="emoji">⚠️</span>' + escHtml(e.message || '加载失败') + '</div>';
      } else {
        showToast('加载更多失败', 'error');
      }
    } finally {
      state.loading = false;
      updateLoadMoreUI();
    }
  }

  // 刷新「加载更多」区域的状态
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
      lm.textContent = '加载中…';
      lm.classList.add('loading');
    } else if (state.hasMore) {
      lm.textContent = '加载更多（已显示 ' + state.posts.length + ' / ' + state.total + '）';
      lm.classList.remove('loading');
    } else {
      lm.textContent = '—— 已加载全部 ' + state.total + ' 篇 ——';
      lm.classList.remove('loading');
    }
  }

  // ============ 详情 ============
  async function openDetail(id) {
    closePopmenu();
    var overlay = $('dscForumDetailOverlay');
    var body = $('dscForumDetailBody');
    $('dscForumDetailTitle').textContent = '帖子详情';
    $('dscForumDetailMeta').textContent = '';
    if (body) body.innerHTML = '<div class="dsc-forum-empty"><span class="emoji">⏳</span>加载中…</div>';
    if (overlay) overlay.classList.add('open');
    state.currentId = id;
    state.detailPost = null;

    try {
      var res = await fetch('/api/forum/posts/detail?id=' + encodeURIComponent(id), { cache: 'no-store' });
      var data = await res.json();
      if (!res.ok) throw new Error(data.error || '加载失败');
      state.detailPost = data.post;
      renderDetail(data.post);
    } catch (e) {
      if (body) body.innerHTML = '<div class="dsc-forum-empty"><span class="emoji">⚠️</span>' + escHtml(e.message || '加载失败') + '</div>';
    }
  }

  function renderDetail(post) {
    var body = $('dscForumDetailBody');
    var titleEl = $('dscForumDetailTitle');
    var metaEl = $('dscForumDetailMeta');
    if (titleEl) titleEl.textContent = '帖子详情';
    if (metaEl) metaEl.textContent = (post.author || '匿名') + ' · ' + fmtTime(post.updatedAt || post.createdAt);
    if (!body) return;
    body.innerHTML = '';

    // 完整标题（可换行展示，不省略）
    var titleBlock = document.createElement('div');
    titleBlock.className = 'dsc-forum-detail-title';
    titleBlock.textContent = post.title || '（无标题）';
    body.appendChild(titleBlock);

    // 作者 / 时间 / 状态标签
    var meta = document.createElement('div');
    meta.className = 'dsc-forum-detail-meta';
    meta.appendChild(document.createTextNode((post.author || '匿名') + ' · ' + fmtTime(post.updatedAt || post.createdAt)));
    if (post.isPinned) meta.appendChild(makeTag('pin', '置顶'));
    if (post.isFeatured) meta.appendChild(makeTag('feature', '精华'));
    if (post.isBlocked) meta.appendChild(makeTag('block', '已屏蔽'));
    body.appendChild(meta);

    if (post.isBlocked) {
      var blocked = document.createElement('div');
      blocked.className = 'dsc-forum-detail-blocked';
      blocked.innerHTML = '<span class="emoji">🚫</span>该帖子已被屏蔽，正文不可见';
      body.appendChild(blocked);
      return;
    }

    if (!post.content) {
      var empty = document.createElement('div');
      empty.className = 'dsc-forum-empty';
      empty.textContent = '（无正文）';
      body.appendChild(empty);
      return;
    }

    // 分段渲染长正文：每段 ≤ DETAIL_CHUNK 字符，且不切断代理对
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

  // ============ 发帖 ============
  function setComposeMode(isEdit) {
    var titleEl = $('dscForumComposeTitle');
    var submitBtn = $('dscForumComposeSubmitBtn');
    if (titleEl) titleEl.textContent = isEdit ? '✏️ 编辑帖子' : '✍️ 发帖';
    if (submitBtn) submitBtn.textContent = isEdit ? '保存' : '发布';
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

  // 编辑已有帖子：拉取完整正文后填充到发帖表单
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
        console.error('[FORUM] 编辑加载失败', e);
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
    if (!title) { showToast('标题不能为空', 'error'); return; }
    var tl = runeLen(title);
    var cl = runeLen(content);
    if (tl > MAX_TITLE) { showToast('标题最多 ' + MAX_TITLE + ' 字，当前 ' + tl + ' 字', 'error'); return; }
    if (cl > MAX_CONTENT) { showToast('正文最多 ' + MAX_CONTENT + ' 字，当前 ' + cl + ' 字', 'error'); return; }

    var payload = { title: title, content: content, author: state.editingAuthor || '匿名' };
    if (state.editingId) payload.id = state.editingId;

    try {
      var res = await fetch('/api/forum/posts', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
      });
      var data = await res.json();
      if (!res.ok) { showToast(data.error || '发布失败', 'error'); return; }
      showToast(state.editingId ? '✅ 已保存修改' : '✅ 发布成功', 'success');
      closeCompose();
      loadList();
      // 若正在查看同一帖子的详情，同步刷新
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
      showToast('发布失败：' + (e.message || e), 'error');
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
      if (!res.ok) { showToast(data.error || '操作失败', 'error'); return; }
      showToast('操作成功', 'success');
      await loadList();
      // 详情页同步刷新
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
      showToast('操作失败', 'error');
    }
  }

  function togglePin(post) {
    var target = !post.isPinned;
    confirmDialog('📌 ' + (target ? '置顶' : '取消置顶'),
      '确定要' + (target ? '置顶' : '取消置顶') + '这篇帖子吗？', target ? '置顶' : '取消置顶')
      .then(function (ok) { if (ok) doAction(post.id, 'pin', target); });
  }

  function toggleFeature(post) {
    var target = !post.isFeatured;
    confirmDialog('💎 ' + (target ? '加精' : '取消加精'),
      '确定要' + (target ? '加精' : '取消加精') + '这篇帖子吗？', target ? '加精' : '取消加精')
      .then(function (ok) { if (ok) doAction(post.id, 'feature', target); });
  }

  function toggleBlock(post) {
    var target = !post.isBlocked;
    confirmDialog('🚫 ' + (target ? '屏蔽' : '取消屏蔽'),
      '确定要' + (target ? '屏蔽' : '取消屏蔽') + '这篇帖子吗？', target ? '屏蔽' : '取消屏蔽')
      .then(function (ok) { if (ok) doAction(post.id, 'block', target); });
  }

  function deleteSingle(post) {
    confirmDelete('🗑️ 删除帖子', '确定要删除《' + (post.title || post.id) + '》吗？删除后不可恢复。')
      .then(async function (ok) {
        if (!ok) return;
        try {
          var res = await fetch('/api/forum/posts/delete?id=' + encodeURIComponent(post.id), { method: 'DELETE' });
          var data = await res.json();
          if (!res.ok) { showToast(data.error || '删除失败', 'error'); return; }
          showToast('已删除', 'success');
          if (state.currentId === post.id) closeDetail();
          delete state.selected[post.id];
          loadList();
        } catch (e) { showToast('删除失败', 'error'); }
      });
  }

  async function batchDelete() {
    var ids = Object.keys(state.selected);
    if (!ids.length) { showToast('请先勾选要删除的帖子', 'error'); return; }
    var ok = await confirmDelete('🗑️ 批量删除', '确定要删除选中的 ' + ids.length + ' 篇帖子吗？删除后不可恢复。');
    if (!ok) return;
    try {
      var res = await fetch('/api/forum/posts/delete', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ids: ids })
      });
      var data = await res.json();
      if (!res.ok) { showToast(data.error || '删除失败', 'error'); return; }
      showToast('已删除 ' + (data.deleted || ids.length) + ' 篇帖子', 'success');
      state.selected = {};
      setBatchMode(false);
      loadList();
    } catch (e) { showToast('删除失败', 'error'); }
  }

  async function clearAllPosts() {
    var n = state.posts.length;
    if (!n) { showToast('当前没有帖子', 'info'); return; }
    var ok = await confirmDelete('💣 全部删除',
      '确定要删除全部 ' + n + ' 篇帖子吗？此操作不可恢复！');
    if (!ok) return;
    try {
      var res = await fetch('/api/forum/posts/clear', { method: 'POST' });
      var data = await res.json();
      if (!res.ok) { showToast(data.error || '删除失败', 'error'); return; }
      showToast('已删除全部帖子', 'success');
      state.selected = {};
      setBatchMode(false);
      loadList();
    } catch (e) { showToast('删除失败', 'error'); }
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
    if (count) count.textContent = '已选 ' + sel.length;
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

  // ============ 论坛页头部「⋯」菜单项 ============
  function forumMenuItems() {
    var selCount = Object.keys(state.selected).length;
    return [
      { icon: '✍️', label: '发帖', action: openCompose },
      { icon: '☑️', label: state.batchMode ? '退出批量选择' : '批量选择', action: function () { setBatchMode(!state.batchMode); } },
      { icon: '🗑️', label: '批量删除（已选 ' + selCount + '）', danger: true, action: batchDelete },
      { icon: '💣', label: '全部删除', danger: true, action: clearAllPosts }
    ];
  }

  function cardMenuItems(post) {
    return [
      { icon: '✏️', label: '编辑', action: function () { openEdit(post); } },
      { icon: '📌', label: post.isPinned ? '取消置顶' : '置顶', action: function () { togglePin(post); } },
      { icon: '💎', label: post.isFeatured ? '取消加精' : '加精', action: function () { toggleFeature(post); } },
      { icon: '🚫', label: post.isBlocked ? '取消屏蔽' : '屏蔽', action: function () { toggleBlock(post); } },
      { icon: '🗑️', label: '删除', danger: true, action: function () { deleteSingle(post); } }
    ];
  }

  function findPost(id) {
    for (var i = 0; i < state.posts.length; i++) {
      if (state.posts[i].id === id) return state.posts[i];
    }
    return state.detailPost && state.detailPost.id === id ? state.detailPost : null;
  }

  // ============ 事件绑定 ============
  function bind() {
    // 主顶栏入口
    var entry = $('dscForumBtn');
    if (entry) entry.addEventListener('click', function (e) { e.stopPropagation(); openForum(); });

    // 论坛页头部
    var moreBtn = $('dscForumMoreBtn');
    if (moreBtn) moreBtn.addEventListener('click', function (e) { e.stopPropagation(); openPopmenu(moreBtn, forumMenuItems()); });
    var closeBtn = $('dscForumCloseBtn');
    if (closeBtn) closeBtn.addEventListener('click', closeForum);

    // 批量操作条
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

    // 加载更多按钮（事件委托，节点会被重建）
    var listElForMore = $('dscForumList');
    if (listElForMore) listElForMore.addEventListener('click', function (e) {
      var lm = e.target.closest ? e.target.closest('#dscForumLoadMore') : null;
      if (lm && state.hasMore && !state.loading) {
        e.stopPropagation();
        loadMore();
      }
    });

    // 列表：事件委托（卡片点击 → 详情 / 勾选 / 菜单）
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

    // 详情页
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

    // 发帖页
    var composeCancel = $('dscForumComposeCancelBtn');
    if (composeCancel) composeCancel.addEventListener('click', closeCompose);
    var composeSubmit = $('dscForumComposeSubmitBtn');
    if (composeSubmit) composeSubmit.addEventListener('click', submitCompose);

    // 字数统计
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

    // 全局：点击空白关闭悬浮菜单
    document.addEventListener('click', function (e) {
      if (popmenu && !popmenu.contains(e.target)) closePopmenu();
    }, true);
    window.addEventListener('resize', closePopmenu);
    ['dscForumBody', 'dscForumDetailBody'].forEach(function (id) {
      var el = $(id);
      if (el) el.addEventListener('scroll', closePopmenu);
    });

    // 列表滚动接近底部时自动加载更多
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
