/* =====================================================================
 * dsc-swipe.js —— 底部工具栏「任意位置横向滑动」修复 (v1)
 * ---------------------------------------------------------------------
 * 背景 / 真正根因：
 *   index.html 里有一段早期脚本，在 document 的 capture 阶段监听
 *   touchstart/touchmove，选择器包含了 .dsc-switch-btn / .dsc-level-btn /
 *   .dsc-plus-btn / .dsc-send-btn 等按钮。命中后：
 *     1) touchstart 立刻 e.preventDefault()  → 原生横向滚动被彻底取消
 *     2) touchmove 把位移映射到 scroller.scrollTop（纵向）→ 横向位移被丢弃
 *   而工具栏几乎整条都是按钮，所以「在工具栏任何位置左右滑动」全部被
 *   这段逻辑接管并失败，CSS 的 touch-action / overflow-x 都救不回来。
 *
 * 本文件的解决办法：
 *   - 在 **window 的 capture 阶段**绑定（window 早于 document 进入捕获流），
 *     因此一定能先拿到手势；
 *   - 手指落点只要在 .dsc-action-bar 内部任意位置（按钮上、空隙、空白处），
 *     都统一把横向位移映射到 .dsc-switch-group 的 scrollLeft；
 *   - 只接管「明确横向」的手势（|dx| > |dy|），纵向手势原样放行，
 *     不破坏原有的纵向行为；
 *   - 带惯性滑动与「拖动后抑制误点击」，点按钮的手感不变；
 *   - 没有可滚内容时（scrollWidth ≈ clientWidth）不做任何拦截，
 *     保证按钮点击 100% 正常。
 * ===================================================================== */
(function () {
    'use strict';

    if (window.__dscSwipeInstalled) { return; }
    window.__dscSwipeInstalled = 'v1';

    var BAR_SEL = '.dsc-action-bar';
    var GROUP_SEL = '.dsc-switch-group';
    var AXIS_LOCK = 4;      // 方向判定最小位移(px)
    var CLICK_GUARD = 320;  // 拖动后抑制点击的时长(ms)
    var MIN_SCROLL = 2;     // 真正产生位移才抑制点击(px)

    var bar = null;
    var group = null;
    var active = false;
    var locked = false;
    var armClickGuard = false;
    var startX = 0, startY = 0, lastX = 0, lastT = 0;
    var baseScroll = 0, vel = 0;
    var suppressUntil = 0, rafId = 0;

    function raf(cb) {
        if (window.requestAnimationFrame) { return window.requestAnimationFrame(cb); }
        return setTimeout(cb, 16);
    }
    function caf(id) {
        if (window.cancelAnimationFrame) { window.cancelAnimationFrame(id); }
        else { clearTimeout(id); }
    }

    function refresh() {
        var b = document.querySelector(BAR_SEL);
        if (!b) { bar = null; group = null; return false; }
        bar = b;
        group = b.querySelector(GROUP_SEL);
        return !!group;
    }

    /* 向上走 parentElement 链判断是否落在工具栏内部（不依赖 closest） */
    function inBar(node) {
        var n = node;
        var guard = 0;
        while (n && guard++ < 40) {
            if (n === bar) { return true; }
            n = n.parentElement;
        }
        return false;
    }

    function cls(node, name, on) {
        if (node && node.classList) {
            if (on) { node.classList.add(name); } else { node.classList.remove(name); }
        }
    }

    function maxScroll() {
        if (!group) { return 0; }
        var sw = group.scrollWidth || 0;
        var cw = group.clientWidth || 0;
        return sw > cw ? (sw - cw) : 0;
    }

    function stopMomentum() {
        if (rafId) { caf(rafId); rafId = 0; }
    }

    function startMomentum() {
        if (!group) { return; }
        if (Math.abs(vel) < 0.15) { return; }
        if (maxScroll() <= 0) { return; }
        var v = vel;
        var frames = 0;
        function step() {
            v *= 0.94;
            frames += 1;
            if (Math.abs(v) < 0.02 || frames > 50) { rafId = 0; return; }
            group.scrollLeft = (group.scrollLeft || 0) - v * 16;
            rafId = raf(step);
        }
        rafId = raf(step);
    }

    function onStart(e) {
        if (!refresh()) { return; }
        var touches = e.touches;
        if (touches && touches.length > 1) { active = false; return; }
        var t = (touches && touches[0]) || e;
        if (!inBar(e.target)) { active = false; return; }

        stopMomentum();
        active = true;
        locked = false;
        armClickGuard = false;
        startX = lastX = t.clientX;
        startY = t.clientY;
        baseScroll = group.scrollLeft || 0;
        lastT = Date.now();
        vel = 0;
        /* 注意：这里刻意不调用 preventDefault，
           以免破坏其他已存在的触摸逻辑（如按钮点击兜底）。 */
    }

    function onMove(e) {
        if (!active) { return; }
        var t = (e.touches && e.touches[0]) || e;
        var dx = t.clientX - startX;
        var dy = t.clientY - startY;

        if (!locked) {
            if (Math.abs(dx) < AXIS_LOCK && Math.abs(dy) < AXIS_LOCK) { return; }
            /* 纵向意图（或无可滚内容）→ 立刻放弃，交还原有逻辑 */
            if (Math.abs(dy) > Math.abs(dx) || maxScroll() <= 0) {
                active = false;
                return;
            }
            locked = true;
            armClickGuard = true;
            cls(bar, 'dsc-swiping', true);
        }

        if (e.cancelable !== false && e.preventDefault) { e.preventDefault(); }

        var now = Date.now();
        var dt = now - lastT;
        if (dt > 0) { vel = (t.clientX - lastX) / dt; }
        lastX = t.clientX;
        lastT = now;

        group.scrollLeft = baseScroll - dx;
    }

    function onEnd() {
        if (!active) { return; }
        active = false;
        cls(bar, 'dsc-swiping', false);
        if (!locked) { return; }
        locked = false;

        var moved = Math.abs((group ? (group.scrollLeft || 0) : 0) - baseScroll);
        if (armClickGuard && moved >= MIN_SCROLL) {
            suppressUntil = Date.now() + CLICK_GUARD;
            startMomentum();
        }
        armClickGuard = false;
    }

    function onClickCapture(e) {
        if (!suppressUntil) { return; }
        if (Date.now() > suppressUntil) { suppressUntil = 0; return; }
        if (!inBarTarget(e.target)) { return; }
        if (e.stopImmediatePropagation) { e.stopImmediatePropagation(); }
        e.stopPropagation();
        if (e.preventDefault) { e.preventDefault(); }
    }

    function inBarTarget(node) {
        var n = node;
        var guard = 0;
        while (n && guard++ < 40) {
            if (n.classList && n.classList.contains('dsc-action-bar')) { return true; }
            n = n.parentElement;
        }
        return false;
    }

    /* 桌面/触控板横向滚轮也支持 */
    function onWheel(e) {
        if (!refresh()) { return; }
        if (Math.abs(e.deltaX) <= Math.abs(e.deltaY || 0)) { return; }
        if (!inBarTarget(e.target) || maxScroll() <= 0) { return; }
        group.scrollLeft = (group.scrollLeft || 0) + e.deltaX;
    }

    window.addEventListener('touchstart', onStart, { capture: true, passive: false });
    window.addEventListener('touchmove', onMove, { capture: true, passive: false });
    window.addEventListener('touchend', onEnd, { capture: true, passive: false });
    window.addEventListener('touchcancel', onEnd, { capture: true, passive: false });
    window.addEventListener('click', onClickCapture, true);
    window.addEventListener('wheel', onWheel, { capture: true, passive: true });

    /* 调试用入口，便于在控制台核对状态 */
    window.dscSwipe = {
        version: 'v1',
        refresh: refresh,
        scrollState: function () {
            if (!refresh()) { return null; }
            return {
                clientWidth: group.clientWidth,
                scrollWidth: group.scrollWidth,
                scrollLeft: group.scrollLeft,
                maxScroll: maxScroll()
            };
        }
    };
})();
