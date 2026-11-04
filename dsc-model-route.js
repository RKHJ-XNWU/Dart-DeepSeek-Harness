/* ============================================================
 * dsc-model-route.js —— モデル自動ルーティング（画像 → 視覚モデル）前端
 * 1) 「DeepSeek 設定」ダイアログにルーティング設定カードを追加
 *   2) 暴露 window.dscModelRouteToast(payload)，供 deepseek-chat.js
 * done イベント受信後に「今回のリクエストがルーティングされた」と通知
 * バックエンド：/api/ds-chat/model-router（GET 設定 / POST 保存）
 *   設定ファイル：ddsh/data/deepseek_chat/model_router.sts
 * ============================================================ */
(function () {
    'use strict';

    // ★ i18n ヘルパー：引数付きで辞書を引く（無ければ原文）
    function mrT(s) {
        try {
            if (!(window.I18N && window.I18N.t)) return s;
            var args = [s].concat(Array.prototype.slice.call(arguments, 1));
            return window.I18N.t.apply(null, args);
        } catch (e) { return s; }
    }

    var API = '/api/ds-chat/model-router';
    var cfg = null;
    var caps = null;
    var built = false;

    function $(id) { return document.getElementById(id); }

    function toast(msg, type) {
        var wrap = $('dscToastWrap');
        if (!wrap) { console.log('[MR]', msg); return; }
        var el = document.createElement('div');
        el.className = 'dsc-toast ' + (type || '');
        el.textContent = msg;
        wrap.appendChild(el);
        setTimeout(function () { if (el.parentNode) el.parentNode.removeChild(el); }, 3200);
    }

    // done イベントに modelRoute があり実際にルーティングが起きたら → 1回通知
    window.dscModelRouteToast = function (payload) {
        try {
            if (!payload || !payload.modelRoute) return;
            var r = payload.modelRoute;
            if (!r.routed) return;
            toast(mrT('🔀 今回の画像を含むため自動ルーティング {0} → {1}', r.requested, r.effective), 'info');
        } catch (e) { /* 通知失敗は主フローに影響しない */ }
    };

    function el(tag, className, text) {
        var n = document.createElement(tag);
        if (className) n.className = className;
        if (text !== undefined && text !== null) n.textContent = text;
        return n;
    }

    // カード内のテキスト入力欄
    function makeField(id, label, value, placeholder) {
        var f = el('div', 'dsc-mr-field');
        var lb = el('label', 'dsc-mr-field-label', label);
        lb.htmlFor = id;
        f.appendChild(lb);
        var inp = document.createElement('input');
        inp.type = 'text';
        inp.id = id;
        inp.value = value || '';
        inp.placeholder = placeholder || '';
        inp.autocomplete = 'off';
        f.appendChild(inp);
        return f;
    }

    // スイッチ行（行全体がタップ可能）
    function makeToggle(id, title, desc, checked) {
        var row = el('label', 'dsc-toggle-row');
        var tx = el('div', 'dsc-toggle-tx');
        tx.appendChild(el('div', 'dsc-toggle-title', title));
        if (desc) tx.appendChild(el('div', 'dsc-toggle-desc', desc));
        row.appendChild(tx);

        var sw = el('span', 'dsc-switch');
        var box = document.createElement('input');
        box.type = 'checkbox';
        box.id = id;
        box.checked = !!checked;
        sw.appendChild(box);
        sw.appendChild(el('span', 'dsc-switch-track'));
        row.appendChild(sw);
        return row;
    }

    function buildCard(host, footer, body) {
        if (built) return;
        var card = el('div', 'dsc-mr-card');
        card.id = 'dscMrCard';

        card.appendChild(el('div', 'dsc-settings-sec-title', 'モデル自動ルーティング'));
        card.appendChild(el('div', 'dsc-mr-sub',
            '画像を含むときは画像認識対応のビジョンモデルへ自動切替し、Pro などのテキスト専用モデルでの画像読み取り失敗を防ぎます。'));

        card.appendChild(makeToggle('dscMrEnabled', '自動ルーティングを有効化',
            '画像を含み、かつ現在のモデルが画像認識非対応のときに自動切替', cfg ? cfg.enabled : true));
        card.appendChild(makeToggle('dscMrRouteMain', 'メインリクエストも追従して切替',
            'オフのときは画像抽出のみビジョンモデルを使用し、本文は選択したモデルのまま', cfg ? cfg.routeMain : true));

        card.appendChild(makeField('dscMrVisionModel', 'ビジョン用フォールバックモデル',
            cfg ? cfg.visionModel : 'deepseek-flash', 'deepseek-flash'));
        card.appendChild(makeField('dscMrExtraVision', '追加で画像に対応するモデル',
            cfg && cfg.extraVision ? cfg.extraVision.join(',') : '', 'my-gateway/vision-x, gpt-4o（カンマ区切り、空欄可）'));
        card.appendChild(makeField('dscMrExtraText', '追加で画像に非対応のモデル',
            cfg && cfg.extraText ? cfg.extraText.join(',') : '', 'deepseek-v4-pro（カンマ区切り、空欄可）'));

        var saveRow = el('div', 'dsc-mr-save-row');
        var btn = el('button', 'dsc-btn primary', 'ルーティング設定を保存');
        btn.type = 'button';
        btn.id = 'dscMrSave';
        saveRow.appendChild(btn);
        card.appendChild(saveRow);

        var status = el('div', 'dsc-mr-status');
        status.id = 'dscMrStatus';
        status.textContent = caps && caps.visionModels
            ? '内蔵ビジョンモデル：' + caps.visionModels.slice(0, 6).join('、') + ' …'
            : '';
        card.appendChild(status);

        btn.addEventListener('click', save);

        if (body) {
            body.appendChild(card);
        } else if (footer && footer.parentNode === host) {
            host.insertBefore(card, footer);
        } else {
            host.appendChild(card);
        }
        built = true;
    }

    function splitList(v) {
        return (v || '').split(',').map(function (s) { return s.trim(); })
            .filter(function (s) { return s.length > 0; });
    }

    async function save() {
        var status = $('dscMrStatus');
        var btn = $('dscMrSave');
        var body = {
            enabled: $('dscMrEnabled') ? $('dscMrEnabled').checked : true,
            routeMain: $('dscMrRouteMain') ? $('dscMrRouteMain').checked : true,
            visionModel: $('dscMrVisionModel') ? $('dscMrVisionModel').value.trim() : '',
            extraVision: splitList($('dscMrExtraVision') ? $('dscMrExtraVision').value : ''),
            extraText: splitList($('dscMrExtraText') ? $('dscMrExtraText').value : '')
        };
        if (btn) btn.disabled = true;
        try {
            var res = await fetch(API, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(body)
            });
            var data = await res.json().catch(function () { return {}; });
            if (!res.ok || !data.success) throw new Error(data.error || ('HTTP ' + res.status));
            cfg = data.config || body;
            if (status) {
                status.textContent = '✅ 保存しました · ビジョンモデル=' + cfg.visionModel +
                    (cfg.enabled ? ' · ルーティング有効' : ' · ルーティング無効') +
                    (cfg.routeMain ? ' · メインリクエスト追従' : ' · メインリクエスト非追従');
            }
            toast('✅ モデルルーティング設定を保存しました', 'success');
        } catch (e) {
            if (status) status.textContent = '❌ 保存に失敗：' + e.message;
            toast('ルーティング設定の保存に失敗：' + e.message, 'error');
        } finally {
            if (btn) btn.disabled = false;
        }
    }

    async function load() {
        try {
            var res = await fetch(API, { method: 'GET', cache: 'no-cache' });
            var data = await res.json();
            if (data && data.success) {
                cfg = data.config || null;
                caps = data.capabilities || null;
            }
        } catch (e) {
            console.log('[MR] ルーティング設定の読み込みに失敗: ' + e.message);
        }
        var host = document.querySelector('#dscSettingsOverlay .dsc-modal');
        if (host) {
            var body = host.querySelector('.dsc-settings-body');
            buildCard(host, host.querySelector('.dsc-modal-footer'), body);
        }
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', load);
    } else {
        load();
    }
})();
