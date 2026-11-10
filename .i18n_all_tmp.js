// 临时诊断脚本（本次生成，用完即删）：各语言相对 en 的缺口
global.window = global;
global.document = {
  readyState: 'loading', addEventListener: () => {},
  documentElement: {}, head: { appendChild: () => {} },
  querySelectorAll: () => [], createTreeWalker: () => ({ nextNode: () => null }),
  body: null, createElement: () => ({ style: {}, setAttribute(){}, appendChild(){} })
};
global.navigator = { language: 'zh-CN' };
global.localStorage = { getItem: () => null, setItem: () => {}, removeItem: () => {} };
const fs = require('fs');
const dir = '/data/data/com.termux/files/home/ddsh/i18n';
eval(fs.readFileSync(dir + '/i18n.js', 'utf8'));
for (const f of ['ja', 'ja-extra', 'zh', 'zh-extra', 'en', 'en-extra', 'ko', 'ko-extra', 'ru', 'ru-extra', 'fr', 'fr-extra']) {
  eval(fs.readFileSync(dir + '/locales/' + f + '.js', 'utf8'));
}
const en = global.I18N.dict('en') || {};
for (const code of ['zh', 'ko', 'ru', 'fr']) {
  const d = global.I18N.dict(code) || {};
  const miss = Object.keys(en).filter(k => !d[k]);
  console.log(code, '条数=', Object.keys(d).length, '缺失=', miss.length, miss.slice(0, 5).join(' / '));
}
