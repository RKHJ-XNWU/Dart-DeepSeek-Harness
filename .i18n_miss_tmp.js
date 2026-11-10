// 临时诊断脚本（本次生成，用完即删）：导出 zh 相对 en 缺失的 key
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
for (const f of ['ja', 'ja-extra', 'zh', 'zh-extra', 'en', 'en-extra']) {
  eval(fs.readFileSync(dir + '/locales/' + f + '.js', 'utf8'));
}
const zh = global.I18N.dict('zh') || {};
const en = global.I18N.dict('en') || {};
const miss = Object.keys(en).filter(k => !zh[k]);
console.log('缺失条数 =', miss.length);
console.log(JSON.stringify(miss.slice(0, 200), null, 1));
