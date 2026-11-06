# -*- coding: utf-8 -*-
# 本次修复生成的临时脚本（任务结束后自行删除）
import io

P = 'dsc-doubao.js'
src = io.open(P, encoding='utf-8').read()

# 1) 下拉框：模型名走翻译字典
a = "            o.textContent = m.label + ' · ' + m.value;"
b = "            o.textContent = T(m.label) + ' · ' + m.value;"
assert a in src, 'fillSelect 目标未命中'
src = src.replace(a, b, 1)

# 2) 通用 select()：label 走翻译字典
c = "            else { op.value = o.value; op.textContent = o.label; }"
d = "            else { op.value = o.value; op.textContent = T(o.label); }"
assert c in src, 'select() 目标未命中'
src = src.replace(c, d, 1)

# 3) 菜单 tip 原本是中文，作为日语字典 key 永远查不到 → 改为日语源串
tips = [
 ("'豆包生图'", "'豆包画像生成'"),
 ("'豆包生成视频'", "'豆包動画生成'"),
 ("'豆包播客'", "'豆包ポッドキャスト'"),
 ("'豆包语音通话'", "'豆包音声通話'"),
]
for x, y in tips:
    assert x in src, 'tip 未命中: ' + x
    src = src.replace(x, y, 1)

io.open(P, 'w', encoding='utf-8').write(src)
print('dsc-doubao.js 修复完成')
