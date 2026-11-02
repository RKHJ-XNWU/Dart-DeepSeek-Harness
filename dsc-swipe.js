/* =====================================================================
 * dsc-swipe.js —— 下部ツールバー「任意の位置で横スワイプ」の修正 (v1)
 * ---------------------------------------------------------------------
 * 背景 / 真正根因：
 * index.html に初期のスクリプトがあり、document の capture 段階で監視している
 *   touchstart/touchmove，選択器包含了 .dsc-switch-btn / .dsc-level-btn /
 *   .dsc-plus-btn / .dsc-send-btn 等ボタン。命中后：
 *     1) touchstart で即座に e.preventDefault() → ネイティブの横スクロールは完全にキャンセルされる
 * 2) touchmove が移動量を scroller.scrollTop（縦方向）に割り当てる → 横方向の移動量は捨てられる
 * しかもツールバーはほぼ全体がボタンなので、「ツールバーのどこでも左右スワイプ」がすべて
 * このロジックに奪われて失敗する。CSS の touch-action / overflow-x でも救えない。
 *
 * このファイルでの解決策：
 * - **window の capture 段階**でバインド（window は document より早く捕捉フローに入る）、
 * そのため必ず先にジェスチャを取得できる；
 *   - 指の着地点が .dsc-action-bar 内部の任意の位置（ボタンの上、すき間、空白部分）であれば、
 *     いずれも横方向の移動量を .dsc-switch-group の scrollLeft に一括で対応付ける；
 * - 「明確に横向き」のジェスチャ（|dx| > |dy|）のみ受け取り、縦ジェスチャはそのまま通す、
 * 既存の縦方向の挙動を壊さない；
 *   - 慣性スクロールと「ドラッグ後の誤タップ抑止」を備え、ボタンを押した感触は変わらない；
 * - スクロール可能な内容がないとき（scrollWidth ≈ clientWidth）は何も遮断しない、
 *     保证ボタン点击 100% 正常。
 * ===================================================================== */
(function () {
    'use strict';

    if (window.__dscSwipeInstalled) { return; }
    window.__dscSwipeInstalled = 'v1';

    var BAR_SEL = '.dsc-action-bar';
    var GROUP_SEL = '.dsc-switch-group';
    var AXIS_LOCK = 4;      // 方向判定の最小移動量(px)
    var CLICK_GUARD = 320;  // ドラッグ後にクリックを抑止する時間(ms)
    var MIN_SCROLL = 2;     // 実際に移動が発生したときだけクリックを抑止(px)

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

    /* parentElement のチェーンを辿ってツールバー内部かを判定（closest に依存しない） */
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
        /* 注意：ここでは意図的に preventDefault を呼ばない。
           以免破坏その他已存在的触摸逻辑（如ボタン点击兜底）。 */
    }

    function onMove(e) {
        if (!active) { return; }
        var t = (e.touches && e.touches[0]) || e;
        var dx = t.clientX - startX;
        var dy = t.clientY - startY;

        if (!locked) {
            if (Math.abs(dx) < AXIS_LOCK && Math.abs(dy) < AXIS_LOCK) { return; }
            /* 縦方向の意図（またはスクロール可能な内容なし）→ 即座に諦め、元のロジックに返す */
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

    /* デスクトップ/トラックパッドの横スクロールにも対応 */
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

    /* デバッグ用入口。コンソールで状態を確認できる */
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
