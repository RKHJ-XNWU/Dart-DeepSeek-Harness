# -*- coding: utf-8 -*-
# 本次修复生成的临时脚本（任务结束后自行删除）
import io, sys, os

P = 'lib/src/doubao.dart'
src = io.open(P, encoding='utf-8').read()

PAIRS = [
 ('豆包实时语音交付（Doubao-实时语音交互）', '豆包リアルタイム音声対話（Doubao-リアルタイム音声対話）'),
 ('豆包录音文件识别（Doubao-录音文件识别2.0）', '豆包録音ファイル認識（Doubao-録音ファイル認識2.0）'),
 ('Doubao-流式语音识别（流式识别）', 'Doubao-ストリーミング音声認識（ストリーミング認識）'),
 ('Doubao-语音播客（语音播客）', 'Doubao-音声ポッドキャスト（音声ポッドキャスト）'),
 ('Doubao-音频生成-1.0（生成音频）', 'Doubao-音声生成-1.0（音声生成）'),
 ('Doubao-Seedream-4.5（生图模型4K）', 'Doubao-Seedream-4.5（画像生成モデル4K）'),
 ('Doubao-Seedream-5.0-Lite（轻量级生图）', 'Doubao-Seedream-5.0-Lite（軽量画像生成）'),
 ('Doubao-Seedream-5.0-pro（精准生图）', 'Doubao-Seedream-5.0-pro（高精度画像生成）'),
 ('Doubao-Seedance-2.0-mini（生成视频）', 'Doubao-Seedance-2.0-mini（動画生成）'),
 ('Doubao-Seedance-2.0-fast（快速生成视频）', 'Doubao-Seedance-2.0-fast（高速動画生成）'),
 ('Doubao-Seedance-2.0（生成视频）', 'Doubao-Seedance-2.0（動画生成）'),
 ('GLM-5.2（编程模型）', 'GLM-5.2（コーディングモデル）'),
 ('Doubao-Seed-2.0-mini（语言模型）', 'Doubao-Seed-2.0-mini（言語モデル）'),
 ('Doubao-Seed-Evolving（智能体语言模型）', 'Doubao-Seed-Evolving（エージェント言語モデル）'),
 ('Doubao-Seed-2.1-pro（编程语言模型）', 'Doubao-Seed-2.1-pro（コーディング言語モデル）'),
 ('Doubao-Seed-2.1-turbo（语言模型）', 'Doubao-Seed-2.1-turbo（言語モデル）'),
 ('Doubao-Seed-2.0-lite（模态推理模型）', 'Doubao-Seed-2.0-lite（マルチモーダル推論モデル）'),
]

miss = []
for zh, ja in PAIRS:
    if zh not in src:
        miss.append(zh)
        continue
    src = src.replace(zh, ja)

io.open(P, 'w', encoding='utf-8').write(src)
print('替换完成，未命中 %d 条' % len(miss))
for m in miss:
    print('  未命中:', m)
