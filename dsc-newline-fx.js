/* ===================================================================
 * dsc-newline-fx.js  ——  换行ボタン点击反馈
 * -------------------------------------------------------------------
 * なぜ必要か：
 * index.html には document 級の capture スクリプトがあり、それが
 * #dscNewlineBtn も SEL に含め、touchstart 段階で
 * e.preventDefault() を呼んでいる。Chromium は touchstart に preventDefault を行うと
 *   :active 状態機械がキャンセルされる——そのため CSS のあの
 * `.dsc-newline-btn:active { transform: scale(0.94) }` がまったく発火しない。
 *   ボタン押下去まったく変化なし。
 *
 * 做法：
 * 1) window の capture 段階で登録（document より早く捕捉フローに入る）、
 * 必ず先にジェスチャを取得；全体 passive で、絶対に preventDefault しない、
 * そのため元スクリプトの click 送出とスクロール処理をまったく妨げない。
 *   2) 手動でボタンに .is-nl-pressed（押下）/ .is-nl-done（成功パルス）を付与し、
 * 強い視覚フィードバックは CSS が提供し、:active に依存しない。
 *   3) 一旦检测到位移 > 6px（用户其实在横滑工具栏），立刻撤销押す压态，
 * スワイプ時に誤って光るのを防ぐ。
 * =================================================================== */
(function () {
    'use strict';

    var BTN_ID   = 'dscNewlineBtn';
    var CLS_PRESS = 'is-nl-pressed';
    var CLS_DONE  = 'is-nl-done';
    var MOVE_TOL  = 6;      // 移動量の許容差(px)：超えるとクリックではなくスワイプと判定
    var DONE_MS   = 380;    // 成功パルスアニメーションの長さ

    var active = null;      // 現在被押下的ボタン
    var startX = 0, startY = 0, moved = false;
    var doneTimer = null;

    function btn() {
        return document.getElementById(BTN_ID);
    }

    function hit(node) {
        if (!node) return null;
        if (node.nodeType === 3) node = node.parentNode;   // テキストノード
        if (!node || !node.closest) return null;
        return node.closest('#' + BTN_ID);
    }

    function clearPress() {
        if (active) {
            active.classList.remove(CLS_PRESS);
            active = null;
        }
    }

    /* 播放"改行を挿入しました"的成功脉冲 */
    function playDone(b) {
        if (!b) return;
        b.classList.remove(CLS_DONE);
        void b.offsetWidth;                 // 強制的に再レイアウトし、アニメーションの再発火を許可
        b.classList.add(CLS_DONE);
        if (doneTimer) clearTimeout(doneTimer);
        doneTimer = setTimeout(function () {
            doneTimer = null;
            b.classList.remove(CLS_DONE);
        }, DONE_MS);
    }

    /* ---------------- タッチ ---------------- */
    function onStart(e) {
        var b = btn();
        if (!b) return;
        if (!hit(e.target)) return;
        if (e.touches && e.touches.length > 1) return;   // マルチタッチは引き継がない
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
            clearPress();                   // スワイプになる → クリックフィードバックを外す
        }
    }

    function onEnd() {
        if (!active) return;
        var b = active;
        active = null;
        b.classList.remove(CLS_PRESS);
        if (moved) return;                  // スワイプはクリックとみなさない
        playDone(b);
        // 軽い触覚フィードバック（振動モーターや権限がないときは静かに無視）
        try {
            if (navigator.vibrate) navigator.vibrate(12);
        } catch (err) { /* ignore */ }
    }

    /* ---------------- マウス / キーボード（非タッチ環境） ---------------- */
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

    /* click フォールバック：元スクリプトが touchend で合成 click を送出するため、パルスが必ず再生されるようにする */
    function onClickCapture(e) {
        var b = hit(e.target);
        if (!b) return;
        if (!b.classList.contains(CLS_DONE)) playDone(b);
    }

    /* window capture。index.html の document 遮断スクリプトより先 */
    window.addEventListener('touchstart',  onStart, { capture: true, passive: true });
    window.addEventListener('touchmove',   onMove,  { capture: true, passive: true });
    window.addEventListener('touchend',    onEnd,   { capture: true, passive: true });
    window.addEventListener('touchcancel', clearPress, { capture: true, passive: true });

    document.addEventListener('mousedown', onMouseDown, true);
    document.addEventListener('mouseup',   onMouseUp,   true);
    document.addEventListener('click',     onClickCapture, true);

    /* デバッグ入口：コンソールで dscNewlineFx.state() を実行して確認 */
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
