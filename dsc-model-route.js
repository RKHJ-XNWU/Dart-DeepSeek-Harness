/* ============================================================
 * dsc-model-route.js —— 模型自动路由（图片 → 视觉模型）前端
 *   1) 在「DeepSeek 设置」弹层里追加一块路由设置卡片
 *   2) 暴露 window.dscModelRouteToast(payload)，供 deepseek-chat.js
 *      在收到 done 事件后提示「本次请求被路由了」
 *   后端：/api/ds-chat/model-router（GET 配置 / POST 保存）
 *   配置文件：ddsh/data/deepseek_chat/model_router.sts
 * ============================================================ */
(function () {
    'use strict';

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

    // done 事件里若带 modelRoute 且确实发生了路由 → 提示一次
    window.dscModelRouteToast = function (payload) {
        try {
            if (!payload || !payload.modelRoute) return;
            var r = payload.modelRoute;
            if (!r.routed) return;
            toast('🔀 本轮含图片，已自动路由 ' + r.requested + ' → ' + r.effective, 'info');
        } catch (e) { /* 提示失败不影响主流程 */ }
    };

    function el(tag, className, text) {
        var n = document.createElement(tag);
        if (className) n.className = className;
        if (text !== undefined && text !== null) n.textContent = text;
        return n;
    }

    // 卡片内文本输入字段
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

    // 开关行（整行可点）
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

        card.appendChild(el('div', 'dsc-settings-sec-title', '模型自动路由'));
        card.appendChild(el('div', 'dsc-mr-sub',
            '含图片时自动切换到支持识图的视觉模型，避免 Pro 等纯文本模型读图失败。'));

        card.appendChild(makeToggle('dscMrEnabled', '启用自动路由',
            '含图片且当前模型不支持识图时，自动切换', cfg ? cfg.enabled : true));
        card.appendChild(makeToggle('dscMrRouteMain', '主请求也跟随切换',
            '关闭时仅图片提取用视觉模型，正文仍用所选模型', cfg ? cfg.routeMain : true));

        card.appendChild(makeField('dscMrVisionModel', '视觉兜底模型',
            cfg ? cfg.visionModel : 'deepseek-flash', 'deepseek-flash'));
        card.appendChild(makeField('dscMrExtraVision', '额外支持图片的模型',
            cfg && cfg.extraVision ? cfg.extraVision.join(',') : '', 'my-gateway/vision-x, gpt-4o（逗号分隔，可留空）'));
        card.appendChild(makeField('dscMrExtraText', '额外不支持图片的模型',
            cfg && cfg.extraText ? cfg.extraText.join(',') : '', 'deepseek-v4-pro（逗号分隔，可留空）'));

        var saveRow = el('div', 'dsc-mr-save-row');
        var btn = el('button', 'dsc-btn primary', '保存路由设置');
        btn.type = 'button';
        btn.id = 'dscMrSave';
        saveRow.appendChild(btn);
        card.appendChild(saveRow);

        var status = el('div', 'dsc-mr-status');
        status.id = 'dscMrStatus';
        status.textContent = caps && caps.visionModels
            ? '内置视觉型号：' + caps.visionModels.slice(0, 6).join('、') + ' …'
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
                status.textContent = '✅ 已保存 · 视觉模型=' + cfg.visionModel +
                    (cfg.enabled ? ' · 路由已启用' : ' · 路由已关闭') +
                    (cfg.routeMain ? ' · 主请求跟随' : ' · 主请求不跟随');
            }
            toast('✅ 模型路由设置已保存', 'success');
        } catch (e) {
            if (status) status.textContent = '❌ 保存失败：' + e.message;
            toast('保存路由设置失败：' + e.message, 'error');
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
            console.log('[MR] 读取路由配置失败: ' + e.message);
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
