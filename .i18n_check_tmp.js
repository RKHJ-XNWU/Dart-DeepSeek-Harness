// 临时诊断脚本（本次生成，用完即删）
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
  try {
    eval(fs.readFileSync(dir + '/locales/' + f + '.js', 'utf8'));
  } catch (e) {
    console.log('加载失败', f, e.message);
  }
}
for (const code of ['ja', 'zh', 'en', 'ko', 'ru', 'fr']) {
  const d = global.I18N.dict(code);
  console.log(code, '条数=', Object.keys(d || {}).length);
}
// 抽查若干关键界面词是否有译文
const probe = ['設定', 'ファイル管理', 'データ復元', 'フォーラム · 投稿広場', '日本語単語帳'];
for (const code of ['zh', 'en', 'ko', 'ru', 'fr']) {
  const d = global.I18N.dict(code) || {};
  const miss = probe.filter(k => !d[k]);
  console.log(code, '缺失抽查:', miss.join(' / ') || '无');
}
