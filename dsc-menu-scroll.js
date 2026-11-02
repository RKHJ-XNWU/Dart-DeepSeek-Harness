/* dsc-menu-scroll.js — 上部バー「⋯」で展開するツールメニュー：任意の位置で上下スワイプ
 * ---------------------------------------------------------------------------
 * 背景（なぜ CSS だけでは足りないか）：
 * index.html に document レベルの capture スクリプトがあり、セレクタ SEL が
 *   .dsc-more-item 等ボタン后会 e.preventDefault()，然后把位移只映射到
 * scrollParent() の scrollTop。ところが .dsc-more-menu には元々 overflow-y も
 * max-height もなく、scrollParent() が見つけられないため、移動量は document に渡され、
 * 同時に画面を超えた部分が #deepseekChatApp の overflow-x:clip で切り取られ、
 * その結果、メニューは「スクロールもできず、見えもしない」状態になる。
 *
 * 本スクリプトの方式：
 *   1) 展開時にメニューの実際の位置から max-height を精算し、すべての内容がビューポート内に収まるようにする；
 * 2) window の capture 段階で .dsc-more-menu 内の縦ジェスチャを受け取り、
 * （window は document より早く捕捉フローに入るため、必ず先にイベントを取得できる）、
 * menu.scrollTop を一括で駆動し、慣性も付ける；
 * 3) 横方向のジェスチャーはそのまま通し、他のロジックに影響しない；
 *   4) タップ（移動 < 6px）はまったく遮断せず、メニュー項目のクリックは通常どおり発火する；
 * 5) ドラッグ終了後に click を1回遮断し、スワイプ時の誤タップを防ぐ。
 */
(function () {
  'use strict';

  var MENU = '.dsc-more-menu';
  var SCROLLING = 'dsc-menu-scrolling';
  var THRESH = 6;

  var st = { menu: null, y: 0, x: 0, lastY: 0, lastT: 0, vel: 0, drag: false, raf: 0 };
  var suppressClick = false;
  var suppressTimer = 0;

  function now() {
    return (window.performance && performance.now) ? performance.now() : Date.now();
  }
  function menuOf(el) {
    return (el && el.closest) ? el.closest(MENU) : null;
  }
  function maxScroll(m) {
    var v = m.scrollHeight - m.clientHeight;
    return v > 0 ? v : 0;
  }
  function canScroll(m) {
    return !!m && maxScroll(m) > 2;
  }
  /* 明示的にクランプし、scrollTop 代入時のブラウザの暗黙クランプに依存しない */
  function setScroll(m, v) {
    var max = maxScroll(m);
    if (v < 0) v = 0;
    if (v > max) v = max;
    m.scrollTop = v;
    updateHint(m);      /* ジェスチャ/慣性スクロールの各ステップで下部ヒントを更新 */
    return v;
  }
  function stopInertia() {
    if (st.raf) { cancelAnimationFrame(st.raf); st.raf = 0; }
  }
  function suppressNextClick() {
    suppressClick = true;
    if (suppressTimer) clearTimeout(suppressTimer);
    suppressTimer = setTimeout(function () { suppressClick = false; }, 400);
  }

  /* 最大で7項目までしか表示しない。第7項の**実際の下端**を読んで計算し、ピクセルをハードコードしない：
     縦方向の overflow は子要素のレイアウト位置を変えない（切り取るだけ）ため、たとえ現在
     max-height が有効でメニューがスクロール状態でも、この値は安定して正確である。
     戻る 0 表示项数 <= 7、不要限制。 */
  var VISIBLE_MAX = 7;
  function sevenHeight(m) {
    var items = m.querySelectorAll('.dsc-more-item');
    if (!items || items.length <= VISIBLE_MAX) return 0;
    var mr = m.getBoundingClientRect();
    var r7 = items[VISIBLE_MAX - 1].getBoundingClientRect();
    /* 重要：scrollTop を足して「内容座標系」に換算する。
       メニューがスクロール済みだと第7項のビューポート位置が上にずれる。補正しないと、
       スクロールするたびに fit() で上限が小さくなっていく（実測で 278 から 232 に低下）。 */
    var h = r7.bottom - mr.top + (m.scrollTop || 0);
    return h > 0 ? h : 0;
  }

  /* スクロール可能でまだ下端に達していないとき、下端に内側の影を描いて「まだ続きがある」ことを示す。
     注意：ここは必ず data 属性を使い、**class は絶対に使わない** ——
     watch() の MutationObserver が監視しているのはまさに class 属性であり、ここで class を切り替えると、
     observer が再び起動 -> fit() が再実行 -> また class を切替、という揺れが生じ、
     さらに fit のたびに scrollTop が 0 に戻ってしまう（ユーザーがスクロールできない）。 */
  function updateHint(m) {
    if (!m || !m.setAttribute) return;
    var max = maxScroll(m);
    var more = max > 2 && m.scrollTop < max - 1;
    if (more === (m.getAttribute('data-has-more') === '1')) return;  /* 変化がなければ DOM に触れない */
    if (more) m.setAttribute('data-has-more', '1');
    else m.removeAttribute('data-has-more');
  }

  /* 押す菜单在屏幕上的真实位置算可用高度，保证不出屏、不被裁切，
     かつ最大で VISIBLE_MAX 項目までしか表示しない。 */
  function fit(m) {
    if (!m) return;
    var r = m.getBoundingClientRect();
    var vh = window.innerHeight || document.documentElement.clientHeight;
    var avail = vh - r.top - 12;
    if (avail < 120) avail = 120;
    var seven = sevenHeight(m);
    if (seven > 0 && seven < avail) {
      /* floor ではなく ceil を使う：floor だと第7項の下端が1px未満切り取られる；
         ceil なら最大 0.99px の余りで、2px の gap より小さいため第8項は表示されない。 */
      avail = Math.ceil(seven);
    }
    m.style.maxHeight = Math.floor(avail) + 'px';
    updateHint(m);
  }

  /* 展開時に高さを一度精算する。
     [リグレッション修正] ユーザー報告「上スワイプできたのにすぐ弾き戻される」の根本原因はここにある：
     observer が監視しているのは class 属性で、スクロール中に本スクリプトが
     SCROLLING（.dsc-menu-scrolling）を付け外しする——これも class の変更であり、
     observer を起動してしまう。元の実装はコールバックで**無条件に** m.scrollTop = 0 を実行し、
     そのため touchend の remove(SCROLLING) が再び observer を起動し、
     次のフレームで scrollTop を強制的にゼロにする（遅延約 16ms。まさにユーザーが感じる
     「上にスワイプしたのにすぐ戻る」現象）。
     修正法：「open が閉→開」になる本当の展開の瞬間にだけ初期化し、
     スクロールによる class 変化は一律無視する。 */
  function watch(m) {
    if (!m || m.__dscMenuWatch) return;
    m.__dscMenuWatch = true;
    if (typeof MutationObserver !== 'function') return;
    var lastOpen = m.classList.contains('open');
    new MutationObserver(function () {
      var isOpen = m.classList.contains('open');
      if (isOpen === lastOpen) return;   /* SCROLLING などの class 変化：展開/収納ではないので無視 */
      lastOpen = isOpen;
      if (!isOpen) return;               /* 收起：不做任何事 */
      requestAnimationFrame(function () {
        fit(m);
        m.scrollTop = 0;                 /* 「展開直後」のこの瞬間だけ先頭へ */
        updateHint(m);
      });
    }).observe(m, { attributes: true, attributeFilter: ['class'] });
    /* 要素レベルの scroll 監視：document 捕捉より直接的で確実 */
    m.addEventListener('scroll', function () { updateHint(m); }, { passive: true });
  }

  function init() {
    var nodes = document.querySelectorAll(MENU);
    for (var i = 0; i < nodes.length; i++) watch(nodes[i]);

    /* フォールバック発火：「⋯」タップ後の次フレームで fit を1回補う。
       MutationObserver は一部の WebView/ヘッドレス環境ではタップ時にコールバックを保証しない。
       これにより「メニューが開かれたら必ず上限を一度計算する」ことを保証する。 */
    document.addEventListener('click', function (e) {
      var t = e.target;
      if (!t || !t.closest || !t.closest('.dsc-more-wrap')) return;
      requestAnimationFrame(function () {
        var m = document.querySelector(MENU);
        if (m && m.classList.contains('open')) fit(m);
      });
    }, true);
  }

  /* ---- ジェスチャ：window の捕捉段階、document 級の遮断スクリプトより先 ---- */

  window.addEventListener('touchstart', function (e) {
    stopInertia();
    if (e.touches.length !== 1) { st.menu = null; return; }
    var m = menuOf(e.target);
    if (!m) { st.menu = null; return; }
    st.menu = m;
    st.drag = false;
    st.vel = 0;
    st.y = st.lastY = e.touches[0].clientY;
    st.x = e.touches[0].clientX;
    st.lastT = now();
    /* stopPropagation しない：元スクリプトに preventDefault とクリック送出を続けさせる */
  }, { passive: true, capture: true });

  window.addEventListener('touchmove', function (e) {
    if (!st.menu) return;
    if (e.touches.length !== 1) { st.menu = null; return; }
    var t = e.touches[0];
    var dy = t.clientY - st.y;
    var dx = t.clientX - st.x;

    if (!st.drag) {
      if (Math.abs(dy) < THRESH && Math.abs(dx) < THRESH) return;      /* まだ方向が判別できない */
      if (Math.abs(dx) > Math.abs(dy)) { st.menu = null; return; }     /* 横向き：通過させる */
      st.drag = true;
      /* 注意：lastY をリセットしない —— 指の起点を保持する。さもないと最初の移動量が失われる */
      st.lastT = now();
      st.menu.classList.add(SCROLLING);
    }

    var d = t.clientY - st.lastY;
    var dt = Math.max(1, now() - st.lastT);
    st.vel = d / dt;
    st.lastY = t.clientY;
    st.lastT = now();

    var m = st.menu;
    if (canScroll(m)) {
      var before = m.scrollTop;
      var after = setScroll(m, before - d);
      if (after === before) st.vel = 0;   /* すでに上端/下端 */
    } else if (m.scrollTop !== 0) {
      m.scrollTop = 0;
    }

    /* このジェスチャを受け取る：元スクリプトが移動量を再計算するのを防ぎ（二重スクロール/逆方向）、
       ネイティブスクロールと JS が同時に効いて速度が倍になるのも防ぐ */
    if (e.cancelable) e.preventDefault();
    e.stopPropagation();
  }, { passive: false, capture: true });

  window.addEventListener('touchend', function (e) {
    var m = st.menu;
    if (!m) return;
    var wasDrag = st.drag;
    st.menu = null;
    st.drag = false;
    m.classList.remove(SCROLLING);

    if (!wasDrag) return;   /* 点押す：完全放行，菜单项点击照常 */

    /* ドラッグ終了：元スクリプトに合成 click を送出させず、スワイプの誤タップを防ぐ */
    suppressNextClick();
    if (e.cancelable) e.preventDefault();
    e.stopPropagation();

    var v = st.vel * 16;
    if (Math.abs(v) > 2 && canScroll(m)) {
      (function tick() {
        v *= 0.94;
        if (Math.abs(v) < 0.6) { st.raf = 0; return; }
        var before = m.scrollTop;
        var after = setScroll(m, before - v);
        if (after === before) { st.raf = 0; return; }   /* 境界で停止 */
        st.raf = requestAnimationFrame(tick);
      })();
    }
  }, { passive: false, capture: true });

  window.addEventListener('touchcancel', function () {
    stopInertia();
    if (st.menu) st.menu.classList.remove(SCROLLING);
    st.menu = null;
    st.drag = false;
  }, { capture: true });

  /* ドラッグ後の click は一律遮断（二重の保険） */
  window.addEventListener('click', function (e) {
    if (suppressClick) {
      suppressClick = false;
      e.stopPropagation();
      e.preventDefault();
    }
  }, { passive: false, capture: true });

  /* メニュー自身のスクロール時に下部ヒントを更新（scroll はバブルしないため capture で捕捉） */
  document.addEventListener('scroll', function (e) {
    var t = e.target;
    if (t && t.classList && t.classList.contains('dsc-more-menu')) updateHint(t);
  }, true);

  window.addEventListener('resize', function () {
    var m = document.querySelector(MENU + '.open');
    if (m) fit(m);
  });

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

  /* デバッグ入口 */
  window.dscMenuScroll = {
    state: function () {
      var m = document.querySelector(MENU);
      if (!m) return null;
      return {
        scrollTop: m.scrollTop,
        scrollHeight: m.scrollHeight,
        clientHeight: m.clientHeight,
        maxScroll: maxScroll(m),
        canScroll: canScroll(m),
        maxHeight: m.style.maxHeight || '',
        visibleMax: VISIBLE_MAX,
        sevenHeight: sevenHeight(m),
        hasMore: m.getAttribute('data-has-more') === '1'
      };
    },
    fit: function () { fit(document.querySelector(MENU + '.open') || document.querySelector(MENU)); },
    measure: function () {
      var m = document.querySelector(MENU + '.open') || document.querySelector(MENU);
      if (!m) return null;
      return { sevenHeight: sevenHeight(m), visibleMax: VISIBLE_MAX };
    }
  };
})();
