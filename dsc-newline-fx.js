/* ===================================================================
 * dsc-newline-fx.js  ——  换行按钮点击反馈
 * -------------------------------------------------------------------
 * 为什么需要它：
 *   index.html 里有一段 document 级 capture 脚本，它把
 *   #dscNewlineBtn 也纳入了 SEL，并在 touchstart 阶段调用
 *   e.preventDefault()。Chromium 对 touchstart 做 preventDefault
 *   会取消后续的 :active 状态机——所以 CSS 里那条
 *   `.dsc-newline-btn:active { transform: scale(0.94) }` 根本不会触发，
 *   按钮按下去毫无变化。
 *
 * 做法：
 *   1) 在 window 的 capture 阶段注册（早于 document 进入捕获流），
 *      必定先拿到手势；全程 passive，绝不 preventDefault，
 *      因此完全不干扰原有脚本的 click 派发与滚动逻辑。
 *   2) 手动给按钮加 .is-nl-pressed（按下）/ .is-nl-done（成功脉冲），
 *      由 CSS 提供强视觉反馈，不依赖 :active。
 *   3) 一旦检测到位移 > 6px（用户其实在横滑工具栏），立刻撤销按压态，
 *      避免滑动时误闪。
 * =================================================================== */
(function () {
    'use strict';

    var BTN_ID   = 'dscNewlineBtn';
    var CLS_PRESS = 'is-nl-pressed';
    var CLS_DONE  = 'is-nl-done';
    var MOVE_TOL  = 6;      // 位移容差(px)：超过即判定为滑动而非点击
    var DONE_MS   = 380;    // 成功脉冲动画时长

    var active = null;      // 当前被按下的按钮
    var startX = 0, startY = 0, moved = false;
    var doneTimer = null;

    function btn() {
        return document.getElementById(BTN_ID);
    }

    function hit(node) {
        if (!node) return null;
        if (node.nodeType === 3) node = node.parentNode;   // 文本节点
        if (!node || !node.closest) return null;
        return node.closest('#' + BTN_ID);
    }

    function clearPress() {
        if (active) {
            active.classList.remove(CLS_PRESS);
            active = null;
        }
    }

    /* 播放"已插入换行"的成功脉冲 */
    function playDone(b) {
        if (!b) return;
        b.classList.remove(CLS_DONE);
        void b.offsetWidth;                 // 强制重排，允许动画重复触发
        b.classList.add(CLS_DONE);
        if (doneTimer) clearTimeout(doneTimer);
        doneTimer = setTimeout(function () {
            doneTimer = null;
            b.classList.remove(CLS_DONE);
        }, DONE_MS);
    }

    /* ---------------- 触摸 ---------------- */
    function onStart(e) {
        var b = btn();
        if (!b) return;
        if (!hit(e.target)) return;
        if (e.touches && e.touches.length > 1) return;   // 多点触控不接管
        var p = (e.touches && e.touches[0]) || e;
        startX = p.clientX;
        startY = p.clientY;
        moved = false;
        active = b;
        if (doneTimer) { clearTimeout(doneTimer); doneTimer = null; }
        b.classList.remove(CLS_DONE);
        b.classList.add(CLS_PRESS);
    }

    function onMove(e) {
        if (!active) return;
        var p = (e.touches && e.touches[0]) || e;
        if (Math.abs(p.clientX - startX) > MOVE_TOL ||
            Math.abs(p.clientY - startY) > MOVE_TOL) {
            moved = true;
            clearPress();                   // 变成滑动 → 撤掉点击反馈
        }
    }

    function onEnd() {
        if (!active) return;
        var b = active;
        active = null;
        b.classList.remove(CLS_PRESS);
        if (moved) return;                  // 滑动不算点击
        playDone(b);
        // 轻触觉反馈（无振动马达或权限时静默忽略）
        try {
            if (navigator.vibrate) navigator.vibrate(12);
        } catch (err) { /* ignore */ }
    }

    /* ---------------- 鼠标 / 键盘（非触摸环境） ---------------- */
    function onMouseDown(e) {
        var b = hit(e.target);
        if (!b) return;
        active = b;
        moved = false;
        if (doneTimer) { clearTimeout(doneTimer); doneTimer = null; }
        b.classList.remove(CLS_DONE);
        b.classList.add(CLS_PRESS);
    }

    function onMouseUp() {
        if (!active) return;
        var b = active;
        active = null;
        b.classList.remove(CLS_PRESS);
        playDone(b);
    }

    /* click 兜底：原脚本在 touchend 里派发合成 click，这里确保脉冲一定播过 */
    function onClickCapture(e) {
        var b = hit(e.target);
        if (!b) return;
        if (!b.classList.contains(CLS_DONE)) playDone(b);
    }

    /* window capture，早于 index.html 中 document 的拦截脚本 */
    window.addEventListener('touchstart',  onStart, { capture: true, passive: true });
    window.addEventListener('touchmove',   onMove,  { capture: true, passive: true });
    window.addEventListener('touchend',    onEnd,   { capture: true, passive: true });
    window.addEventListener('touchcancel', clearPress, { capture: true, passive: true });

    document.addEventListener('mousedown', onMouseDown, true);
    document.addEventListener('mouseup',   onMouseUp,   true);
    document.addEventListener('click',     onClickCapture, true);

    /* 调试入口：控制台可执行 dscNewlineFx.state() 自查 */
    window.dscNewlineFx = {
        press: function () {
            var b = btn();
            if (!b) return false;
            active = b; moved = false;
            b.classList.remove(CLS_DONE);
            b.classList.add(CLS_PRESS);
            return true;
        },
        release: function () {
            if (!active) return false;
            var b = active; active = null;
            b.classList.remove(CLS_PRESS);
            playDone(b);
            return true;
        },
        state: function () {
            var b = btn();
            if (!b) return null;
            var cs = getComputedStyle(b);
            return {
                pressed: b.classList.contains(CLS_PRESS),
                done: b.classList.contains(CLS_DONE),
                bg: cs.backgroundColor,
                color: cs.color,
                borderColor: cs.borderTopColor,
                transform: cs.transform
            };
        }
    };
})();
