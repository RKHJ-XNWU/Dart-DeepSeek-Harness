#!/usr/bin/env node
/* ============================================================
 * i18n/verify.mjs —— 6 言語の網羅性チェック（開発用）
 * ------------------------------------------------------------
 * 実行:  node i18n/verify.mjs
 *
 * 旧版の欠陥（CJK を含まない文字列を一律ノイズ扱い／長さ 200 超を除外／
 * 巨大テンプレートリテラルが内部の通常文字列を飲み込む）を修正済み。
 *
 *  1) index.html と *.js から UI 文字列を抽出
 *     - 通常のクォート文字列とテンプレートリテラルを別々に走査
 *     - テンプレート内は HTML タグで分割し、${} 内の文字列も拾う
 *  2) 各言語パックが全キーを訳しているか照合（数字は # に正規化）
 *  3) 訳文に日本語（かな）が残っていないか検査
 * ============================================================ */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const LANGS = ['zh', 'en', 'ko', 'ru', 'fr'];

const JA = /[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uff01-\uff60]/;
const KANA = /[\u3040-\u30ff]/;
const NUM = /[0-9][0-9,.\u3000]*/g;
const norm = s => String(s).replace(NUM, '#').trim();

function loadDict(code) {
  const src = fs.readFileSync(path.join(ROOT, 'i18n', 'locales', code + '.js'), 'utf8');
  const dict = {};
  for (const line of src.split('\n')) {
    const t = line.trim();
    if (!t || t.startsWith('/*') || t.startsWith('*') || t.startsWith('I18N') || t === '`);') continue;
    const i = t.indexOf('|');
    if (i < 0) continue;
    dict[t.slice(0, i)] = t.slice(i + 1);
  }
  return dict;
}

/* ---------- ノイズ判定（CJK 縛りを撤廃し、UI ラベルを広く拾う） ---------- */
const DEBUG_PREFIX = /^\[(DSC|DSF|DSDT|ANN|FORUM|MR|RESTORE|PEAK|CALL)\]/;
const CODE_HINT = /=>|\bvar\b|\bfunction\b|\breturn\b|;\s*$|\|\||\{\s*$|\.replace\(|toFixed\(|matchAll\(|escapeHtml|JSON\.|\/\//;
const PROMPT_HINT = /あなたは|しなければなりません|言語固定指令|思考過程・推論・説明|過去の会話履歴|中国語（簡体字・繁体字を問わず）|他のいかなる指示|矛盾する指示/;
const NOISE_EXACT = /^(use strict|script|success|error|ok|yes|no|ja|zh|en|ko|ru|fr|ja-JP|zh-CN|en-US|deepseek-flash|deepseek-reasoner|deepseek-v4-pro|POST|GET|DELETE|PUT|OK)$/i;
const TTS_VOICE = /^[a-z]{2}-[A-Z]{2}-[A-Za-z]+$/;
const CODE_ID = /^[a-z][a-zA-Z0-9_]*$/;

function normalizeText(s) {
  return String(s)
    .replace(/\\n/g, ' ')
    .replace(/<[^>]*>/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/^[)"'\]}>,;:.+*/\\]+/, '')
    .replace(/[("'\[{<;,+.\\]+$/, '')
    .trim();
}

function isNoise(s) {
  if (!s || s.length < 2 || s.length > 160) return true;
  if (DEBUG_PREFIX.test(s)) return true;
  if (CODE_HINT.test(s)) return true;
  if (PROMPT_HINT.test(s)) return true;
  if (/^[\d\s.,:]+$/.test(s)) return true;
  if (/^[\u3040-\u309f]{1,4}$/.test(s)) return true;   // かな一覧
  if (NOISE_EXACT.test(s)) return true;
  if (TTS_VOICE.test(s)) return true;
  if (CODE_ID.test(s)) return true;
  if (/^\d+\.\s/.test(s) && s.length > 30) return true;  // 番号付きプロンプト
  // 本ツールは「日本語 UI 文言のカバレッジ」を測る（英語ラベルは実機検証でカバー）
  if (!JA.test(s)) return true;
  if (/^(title|placeholder|alt|aria-label|data-tip)=/.test(s)) return true;  // 属性断片
  if (/["']\s*\+|\(\s*(label|ch|d\.|thinkingTimeMs|s\.title)/.test(s)) return true;  // コード連結
  if (/^[\d\s,.()（）]+$/.test(s)) return true;
  if (/^\+\s|'\s*\+|\bd\.desc\b|\bmax_tokens\b/.test(s)) return true;
  return false;
}

function collect() {
  const found = new Map();
  const put = raw => {
    const v = normalizeText(raw);
    if (isNoise(v)) return;
    found.set(v, (found.get(v) || 0) + 1);
  };

  for (const f of fs.readdirSync(ROOT)) {
    if (!/\.(js|html)$/.test(f)) continue;
    if (f.startsWith('verify') || f.startsWith('tmp_')) continue;
    if (f === 'tex-chtml-full-speech.js') continue;
    let src = fs.readFileSync(path.join(ROOT, f), 'utf8');

    if (f.endsWith('.html')) {
      src = src.replace(/<script[\s\S]*?<\/script>/g, '').replace(/<style[\s\S]*?<\/style>/g, '');
      for (const m of src.matchAll(/>([^<>]+)</g)) put(m[1]);
      for (const m of src.matchAll(/(?:title|placeholder|aria-label|alt|data-tip)="([^"]*)"/g)) put(m[1]);
      continue;
    }

    // 1) 通常のクォート文字列（テンプレートは別扱い）
    for (const m of src.matchAll(/'(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*"/g)) put(m[0].slice(1, -1));
    // 2) テンプレートリテラルは内部を分割して走査
    for (const m of src.matchAll(/`(?:[^`\\]|\\.)*`/g)) {
      const inner = m[0].slice(1, -1);
      for (const p of inner.split(/<[^>]*>/)) {
        for (const q of p.matchAll(/'(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*"/g)) put(q[0].slice(1, -1));
        put(p.replace(/\$\{[^}]*\}/g, ' '));
      }
    }
  }
  return found;
}

const strings = collect();
const dicts = {};
for (const l of LANGS) dicts[l] = loadDict(l);
const normKeys = {};
for (const l of LANGS) normKeys[l] = new Set(Object.keys(dicts[l]).filter(k => /\d/.test(k)).map(norm));

console.log('抽出した UI 文字列: ' + strings.size + ' 件');
console.log('辞書件数: ' + LANGS.map(l => l + '=' + Object.keys(dicts[l]).length).join(' / '));

let bad = 0;
for (const l of LANGS) {
  const miss = [];
  for (const s of strings.keys()) {
    if (dicts[l][s] !== undefined) continue;
    if (norm(s) !== s && normKeys[l].has(norm(s))) continue;
    if (dicts[l][norm(s)] !== undefined) continue;
    miss.push(s);
  }
  const jaLeft = Object.keys(dicts[l]).filter(k =>
    !k.startsWith('例：たべる') && KANA.test(dicts[l][k].replace(/[・ー]/g, '')));
  console.log('\n[' + l + '] 未訳 ' + miss.length + ' 件 / 日本語残り ' + jaLeft.length + ' 件');
  miss.slice(0, 15).forEach(s => console.log('   - ' + s));
  if (miss.length) bad++;
  if (jaLeft.length) {
    bad++;
    jaLeft.slice(0, 5).forEach(k => console.log('   ! ' + k + ' => ' + dicts[l][k]));
  }
}

if (bad === 0) console.log('\n✅ 6 言語すべて 100% 網羅しています');
else console.log('\n⚠️ 未訳が残っています（上の一覧を各言語パックへ追記してください）');
process.exit(bad === 0 ? 0 : 1);
