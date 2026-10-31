// ============================================================
// dsc-announcements.js —— 公告系统前端
//   1) 入口按钮在右上角「⋯」菜单 → 打开公告管理面板
//   2) 用户端：页面加载后拉取 active 公告，按优先级依次弹窗
//   3) 今日内不再提示（localStorage，forceTop 最高级别除外）
// ============================================================
(function () {
  'use strict';

  function $(id) { return document.getElementById(id); }

  function showToast(msg, type) {
    var wrap = $('dscToastWrap');
    if (!wrap) { console.log('[ANN]', msg); return; }
    var el = document.createElement('div');
    el.className = 'dsc-toast ' + (type || '');
    el.textContent = msg;
    wrap.appendChild(el);
    setTimeout(function () { el.remove(); }, 2600);
  }

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
  function todayStr() {
    var d = new Date();
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());
  }
  function dismissKey(id) { return 'ann_dismissed_' + id; }

  // datetime-local 展示用转换
  function rfcToLocal(rfc) {
    if (!rfc) return '';
    var d = new Date(rfc);
    if (isNaN(d.getTime())) return '';
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) +
      'T' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  function closeMoreMenu() {
    var menu = $('dscMoreMenu');
    var moreBtn = $('dscMoreBtn');
    if (menu) menu.classList.remove('open');
    if (moreBtn) moreBtn.classList.remove('more-active');
  }

  // ============ 管理面板 ============
  var editingId = '';

  function openAdmin() {
    closeMoreMenu();
    var overlay = $('dscAnnAdminOverlay');
    if (overlay) overlay.classList.add('open');
    hideEditor();
    loadList();
  }

  function closeAdmin() {
    var overlay = $('dscAnnAdminOverlay');
    if (overlay) overlay.classList.remove('open');
  }

  function hideEditor() {
    var ed = $('dscAnnEditor');
    var list = $('dscAnnList');
    var addBtn = $('dscAnnAddBtn');
    if (ed) ed.style.display = 'none';
    if (list) list.style.display = '';
    if (addBtn) addBtn.style.display = '';
    editingId = '';
  }

  function showEditor(a) {
    editingId = a ? a.id : '';
    $('dscAnnTitle').value = a ? a.title : '';
    $('dscAnnContent').value = a ? a.content : '';
    $('dscAnnStart').value = a ? rfcToLocal(a.startTime) : '';
    $('dscAnnEnd').value = a ? rfcToLocal(a.endTime) : '';
    $('dscAnnPriority').value = a ? a.priority : 0;
    $('dscAnnForce').checked = a ? !!a.forceTop : false;
    var ed = $('dscAnnEditor');
    var list = $('dscAnnList');
    var addBtn = $('dscAnnAddBtn');
    if (ed) ed.style.display = '';
    if (list) list.style.display = 'none';
    if (addBtn) addBtn.style.display = 'none';
  }

  async function loadList() {
    var listEl = $('dscAnnList');
    if (!listEl) return;
    listEl.innerHTML = '<div class="dsc-ann-empty">加载中…</div>';
    var list = [];
    try {
      var res = await fetch('/api/announcements', { cache: 'no-store' });
      var data = await res.json();
      list = data.announcements || [];
    } catch (e) {
      listEl.innerHTML = '<div class="dsc-ann-empty">加载失败</div>';
      return;
    }
    if (!list.length) {
      listEl.innerHTML = '<div class="dsc-ann-empty">暂无公告</div>';
      return;
    }
    var now = new Date();
    var html = '';
    list.forEach(function (a) {
      var st = a.startTime ? new Date(a.startTime) : null;
      var en = a.endTime ? new Date(a.endTime) : null;
      var state = '生效中', stateCls = 'on';
      if (st && now < st) { state = '未开始'; stateCls = 'wait'; }
      else if (en && now > en) { state = '已结束'; stateCls = 'off'; }
      var force = a.forceTop ? '<span class="dsc-ann-tag force">最高级别</span>' : '';
      html += '<div class="dsc-ann-item">' +
        '<div class="dsc-ann-item-head">' +
          '<span class="dsc-ann-item-title">' + escHtml(a.title) + '</span>' +
          force +
          '<span class="dsc-ann-tag ' + stateCls + '">' + state + '</span>' +
          '<span class="dsc-ann-tag">优先级 ' + a.priority + '</span>' +
        '</div>' +
        '<div class="dsc-ann-item-ops">' +
          '<button class="dsc-btn ghost dsc-ann-edit" data-id="' + escHtml(a.id) + '">编辑</button>' +
          '<button class="dsc-btn danger dsc-ann-del" data-id="' + escHtml(a.id) + '">删除</button>' +
        '</div>' +
      '</div>';
    });
    listEl.innerHTML = html;

    listEl.querySelectorAll('.dsc-ann-edit').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var id = btn.getAttribute('data-id');
        var a = list.find(function (x) { return x.id === id; });
        if (a) showEditor(a);
      });
    });
    listEl.querySelectorAll('.dsc-ann-del').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var id = btn.getAttribute('data-id');
        if (btn.getAttribute('data-confirm') === '1') {
          doDelete(id);
          return;
        }
        btn.setAttribute('data-confirm', '1');
        btn.textContent = '确认删除?';
        btn.classList.add('confirming');
        setTimeout(function () {
          btn.removeAttribute('data-confirm');
          btn.textContent = '删除';
          btn.classList.remove('confirming');
        }, 2500);
      });
    });
  }

  async function doDelete(id) {
    try {
      var res = await fetch('/api/announcements?id=' + encodeURIComponent(id), { method: 'DELETE' });
      var data = await res.json();
      if (!res.ok) { showToast(data.error || '删除失败', 'error'); return; }
      showToast('已删除', 'success');
      loadList();
    } catch (e) {
      showToast('删除失败', 'error');
    }
  }

  async function saveCurrent() {
    var title = $('dscAnnTitle').value.trim();
    var content = $('dscAnnContent').value;
    if (!title) { showToast('标题不能为空', 'error'); return; }
    if (runeLen(title) > 500) { showToast('标题最多 500 字', 'error'); return; }
    if (runeLen(content) > 50000) { showToast('内容最多 50000 字', 'error'); return; }
    var startTime = $('dscAnnStart').value;
    var endTime = $('dscAnnEnd').value;
    var priority = parseInt($('dscAnnPriority').value, 10) || 0;
    var forceTop = $('dscAnnForce').checked;

    var payload = {
      id: editingId,
      title: title,
      content: content,
      startTime: startTime,
      endTime: endTime,
      priority: priority,
      forceTop: forceTop
    };
    try {
      var res = await fetch('/api/announcements', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
      });
      var data = await res.json();
      if (!res.ok) { showToast(data.error || '保存失败', 'error'); return; }
      showToast('已保存', 'success');
      hideEditor();
      loadList();
    } catch (e) {
      showToast('保存失败', 'error');
    }
  }

  // ============ 用户端全屏弹窗 ============
  function buildPopup(a, onClose) {
    var overlay = document.createElement('div');
    overlay.className = 'dsc-modal-overlay dsc-ann-popup';
    overlay.style.display = 'flex';
    overlay.style.zIndex = '300000';
    var force = !!a.forceTop;
    var meta = '';
    if (a.startTime || a.endTime) {
      meta = '<div class="dsc-ann-popup-meta">' +
        (a.startTime ? '开始：' + escHtml(a.startTime) : '') +
        (a.endTime ? '　结束：' + escHtml(a.endTime) : '') +
        '</div>';
    }
    var forceTag = force ? '<span class="dsc-ann-tag force">最高级别</span>' : '';
    overlay.innerHTML =
      '<div class="dsc-modal dsc-ann-popup-modal">' +
        '<div class="dsc-ann-popup-head">' +
          '<div class="dsc-ann-popup-title">📢 ' + escHtml(a.title) + ' ' + forceTag + '</div>' +
          '<button class="dsc-ann-popup-close" title="关闭">✕</button>' +
        '</div>' +
        '<div class="dsc-ann-popup-body">' +
          meta +
          '<div class="dsc-ann-popup-content">' + escHtml(a.content) + '</div>' +
        '</div>' +
        '<div class="dsc-ann-popup-footer">' +
          (force ? '' : '<label class="dsc-ann-dismiss"><input type="checkbox"> 今日内不再提示</label>') +
          '<button class="dsc-btn primary dsc-ann-ok">我知道了</button>' +
        '</div>' +
      '</div>';
    document.body.appendChild(overlay);
    var okBtn = overlay.querySelector('.dsc-ann-ok');
    var closeBtn = overlay.querySelector('.dsc-ann-popup-close');
    var dismissBox = overlay.querySelector('.dsc-ann-dismiss input');
    function done() {
      if (dismissBox && dismissBox.checked) {
        localStorage.setItem(dismissKey(a.id), todayStr());
      }
      overlay.remove();
      onClose();
    }
    okBtn.addEventListener('click', done);
    closeBtn.addEventListener('click', done);
  }

  async function showActiveAnnouncements() {
    try {
      var res = await fetch('/api/announcements/active', { cache: 'no-store' });
      var data = await res.json();
      var list = data.announcements || [];
      var toShow = list.filter(function (a) {
        if (a.forceTop) return true;
        return localStorage.getItem(dismissKey(a.id)) !== todayStr();
      });
      var i = 0;
      function next() {
        if (i >= toShow.length) return;
        buildPopup(toShow[i], function () { i++; next(); });
      }
      next();
    } catch (e) {
      console.error('[ANN] 拉取公告失败', e);
    }
  }

  // ============ 绑定 ============
  function bind() {
    var btn = $('dscAnnounceBtn');
    if (btn) btn.addEventListener('click', function (e) {
      e.stopPropagation();
      openAdmin();
    });
    var addBtn = $('dscAnnAddBtn');
    if (addBtn) addBtn.addEventListener('click', function () { showEditor(null); });
    var cancelBtn = $('dscAnnEditCancel');
    if (cancelBtn) cancelBtn.addEventListener('click', hideEditor);
    var saveBtn = $('dscAnnSave');
    if (saveBtn) saveBtn.addEventListener('click', saveCurrent);
    var closeBtn = $('dscAnnClose');
    if (closeBtn) closeBtn.addEventListener('click', closeAdmin);
    var overlay = $('dscAnnAdminOverlay');
    if (overlay) overlay.addEventListener('click', function (e) {
      if (e.target === overlay) closeAdmin();
    });
  }

  function start() {
    bind();
    setTimeout(showActiveAnnouncements, 900);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }
})();
