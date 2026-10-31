/* dsc-menu-scroll.js — 顶栏「⋯」展开的工具菜单：任意位置上下滑动
 * ---------------------------------------------------------------------------
 * 背景（为什么单靠 CSS 不行）：
 *   index.html 里有一段 document 级 capture 脚本，选择器 SEL 命中
 *   .dsc-more-item 等按钮后会 e.preventDefault()，然后把位移只映射到
 *   scrollParent() 的 scrollTop。而 .dsc-more-menu 原本没有 overflow-y
 *   也没有 max-height，scrollParent() 找不到它，位移被丢给了 document，
 *   同时超出屏幕的部分被 #deepseekChatApp 的 overflow-x:clip 裁掉，
 *   于是菜单“既滚不动、也看不见”。
 *
 * 本脚本的做法：
 *   1) 展开时按菜单实际位置精算 max-height，保证全部内容都在视口内；
 *   2) 在 window 的 capture 阶段接管 .dsc-more-menu 内的纵向手势
 *      （window 比 document 更早进入捕获流，因此必定先拿到事件），
 *      统一驱动 menu.scrollTop，并带惯性；
 *   3) 横向手势直接放行，不影响其它逻辑；
 *   4) 点按（位移 < 6px）完全不拦截，菜单项的点击照常触发；
 *   5) 拖动结束后拦截一次 click，避免滑动时误触菜单项。
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
  /* 显式钳制，不依赖浏览器对 scrollTop 赋值的隐式 clamp */
  function setScroll(m, v) {
    var max = maxScroll(m);
    if (v < 0) v = 0;
    if (v > max) v = max;
    m.scrollTop = v;
    updateHint(m);      /* 手势/惯性滚动的每一步都刷新底部提示 */
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

  /* 最多只露出 7 项。读第 7 项的**真实底边**来算，而不是硬编码像素：
     纵向 overflow 不会改变子元素的布局位置（只裁剪），所以即便当前
     max-height 已经生效、菜单处于滚动状态，这个量值依然稳定准确。
     返回 0 表示项数 <= 7、无需限制。 */
  var VISIBLE_MAX = 7;
  function sevenHeight(m) {
    var items = m.querySelectorAll('.dsc-more-item');
    if (!items || items.length <= VISIBLE_MAX) return 0;
    var mr = m.getBoundingClientRect();
    var r7 = items[VISIBLE_MAX - 1].getBoundingClientRect();
    /* 关键：加上 scrollTop 换算回「内容坐标系」。
       菜单已经滚动时，第 7 项的视口位置会随之上移，若不补偿，
       每滚动一次再 fit() 就会把上限越算越小（实测会从 278 掉到 232）。 */
    var h = r7.bottom - mr.top + (m.scrollTop || 0);
    return h > 0 ? h : 0;
  }

  /* 可滚动且还没滑到底时，给底部画一层内阴影暗示「还有更多」。
     注意：这里必须用 data 属性，**绝不能用 class** ——
     watch() 的 MutationObserver 监听的正是 class 属性，一旦这里切 class，
     observer 会被再次唤醒 -> fit() 重跑 -> 又切 class，形成抖动，
     并导致每次 fit 都把 scrollTop 复位成 0（用户滑不动）。 */
  function updateHint(m) {
    if (!m || !m.setAttribute) return;
    var max = maxScroll(m);
    var more = max > 2 && m.scrollTop < max - 1;
    if (more === (m.getAttribute('data-has-more') === '1')) return;  /* 未变化就不碰 DOM */
    if (more) m.setAttribute('data-has-more', '1');
    else m.removeAttribute('data-has-more');
  }

  /* 按菜单在屏幕上的真实位置算可用高度，保证不出屏、不被裁切，
     并且最多只露出 VISIBLE_MAX 项。 */
  function fit(m) {
    if (!m) return;
    var r = m.getBoundingClientRect();
    var vh = window.innerHeight || document.documentElement.clientHeight;
    var avail = vh - r.top - 12;
    if (avail < 120) avail = 120;
    var seven = sevenHeight(m);
    if (seven > 0 && seven < avail) {
      /* 用 ceil 而不是 floor：floor 会把第 7 项底部裁掉不足 1px；
         ceil 最多多出 0.99px，仍小于 2px 的 gap，第 8 项不会被露出。 */
      avail = Math.ceil(seven);
    }
    m.style.maxHeight = Math.floor(avail) + 'px';
    updateHint(m);
  }

  /* 展开时精算一次高度。
     [回归修复] 用户反馈「上滑成功却立刻被弹回」的根因就在这里：
     observer 监听的是 class 属性，而滚动过程中本脚本会加/减
     SCROLLING（.dsc-menu-scrolling）——这同样是 class 变更，会把
     observer 唤醒。原实现在回调里**无条件**执行 m.scrollTop = 0，
     于是 touchend 里 remove(SCROLLING) 又一次唤醒 observer，
     下一帧就把 scrollTop 强行归零（延迟约 16ms，正是用户感知的
     「滑上去了又马上弹回」）。
     修法：只在「open 由关→开」这一个真正的展开时刻做初始化，
     滚动引起的 class 变化一律忽略。 */
  function watch(m) {
    if (!m || m.__dscMenuWatch) return;
    m.__dscMenuWatch = true;
    if (typeof MutationObserver !== 'function') return;
    var lastOpen = m.classList.contains('open');
    new MutationObserver(function () {
      var isOpen = m.classList.contains('open');
      if (isOpen === lastOpen) return;   /* SCROLLING 等 class 变化：非展开/收起，直接忽略 */
      lastOpen = isOpen;
      if (!isOpen) return;               /* 收起：不做任何事 */
      requestAnimationFrame(function () {
        fit(m);
        m.scrollTop = 0;                 /* 仅「刚展开」这一刻归顶 */
        updateHint(m);
      });
    }).observe(m, { attributes: true, attributeFilter: ['class'] });
    /* 元素级 scroll 监听：比 document 捕获更直接可靠 */
    m.addEventListener('scroll', function () { updateHint(m); }, { passive: true });
  }

  function init() {
    var nodes = document.querySelectorAll(MENU);
    for (var i = 0; i < nodes.length; i++) watch(nodes[i]);

    /* 兜底触发：点「⋯」后下一帧补一次 fit。
       MutationObserver 在部分 WebView/无头环境下不保证按时回调，
       这里保证「只要菜单被点开，上限就一定算过一遍」。 */
    document.addEventListener('click', function (e) {
      var t = e.target;
      if (!t || !t.closest || !t.closest('.dsc-more-wrap')) return;
      requestAnimationFrame(function () {
        var m = document.querySelector(MENU);
        if (m && m.classList.contains('open')) fit(m);
      });
    }, true);
  }

  /* ---- 手势：window 捕获阶段，先于 document 级拦截脚本 ---- */

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
    /* 不 stopPropagation：让原脚本继续做 preventDefault 与点击派发 */
  }, { passive: true, capture: true });

  window.addEventListener('touchmove', function (e) {
    if (!st.menu) return;
    if (e.touches.length !== 1) { st.menu = null; return; }
    var t = e.touches[0];
    var dy = t.clientY - st.y;
    var dx = t.clientX - st.x;

    if (!st.drag) {
      if (Math.abs(dy) < THRESH && Math.abs(dx) < THRESH) return;      /* 还看不出方向 */
      if (Math.abs(dx) > Math.abs(dy)) { st.menu = null; return; }     /* 横向：放行 */
      st.drag = true;
      /* 注意：不重置 lastY —— 保留手指起点，否则这第一段位移会被丢掉 */
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
      if (after === before) st.vel = 0;   /* 已经到顶/到底 */
    } else if (m.scrollTop !== 0) {
      m.scrollTop = 0;
    }

    /* 接管本次手势：既避免原脚本再算一遍位移（双滚/反向），
       也避免原生滚动与 JS 同时生效导致速度翻倍 */
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

    if (!wasDrag) return;   /* 点按：完全放行，菜单项点击照常 */

    /* 拖动结束：不让原脚本派发合成 click，避免滑动误触 */
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
        if (after === before) { st.raf = 0; return; }   /* 到边界停住 */
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

  /* 拖动后的 click 一律拦掉（双保险） */
  window.addEventListener('click', function (e) {
    if (suppressClick) {
      suppressClick = false;
      e.stopPropagation();
      e.preventDefault();
    }
  }, { passive: false, capture: true });

  /* 菜单自身滚动时刷新底部提示（scroll 不冒泡，用 capture 捕获） */
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

  /* 调试入口 */
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
