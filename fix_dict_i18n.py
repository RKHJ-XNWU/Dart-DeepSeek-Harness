# -*- coding: utf-8 -*-
# 本次修复生成的临时脚本（任务结束后自行删除）
import io

ROWS = [
 ('豆包リアルタイム音声対話（Doubao-リアルタイム音声対話）',
  '豆包实时语音对话（Doubao-实时语音交互）',
  'Doubao Realtime Voice (Doubao realtime voice interaction)',
  'Doubao Voix en temps réel (interaction vocale temps réel)',
  '더우바오 실시간 음성 대화 (Doubao 실시간 음성 상호작용)',
  'Doubao голос в реальном времени (голосовое взаимодействие)'),
 ('豆包録音ファイル認識（Doubao-録音ファイル認識2.0）',
  '豆包录音文件识别（Doubao-录音文件识别2.0）',
  'Doubao Audio File Recognition (Doubao audio file recognition 2.0)',
  'Doubao Reconnaissance de fichiers audio (reconnaissance audio 2.0)',
  '더우바오 녹음 파일 인식 (Doubao 녹음 파일 인식 2.0)',
  'Doubao распознавание аудиофайлов (распознавание аудио 2.0)'),
 ('Doubao-ストリーミング音声認識（ストリーミング認識）',
  'Doubao-流式语音识别（流式识别）',
  'Doubao Streaming Speech Recognition (streaming recognition)',
  'Doubao Reconnaissance vocale en flux (reconnaissance en flux)',
  'Doubao 스트리밍 음성 인식 (스트리밍 인식)',
  'Doubao потоковое распознавание речи (потоковое распознавание)'),
 ('Doubao-音声ポッドキャスト（音声ポッドキャスト）',
  'Doubao-语音播客（语音播客）',
  'Doubao Podcast Voice (podcast voice)',
  'Doubao Podcast vocal (podcast vocal)',
  'Doubao 음성 팟캐스트 (음성 팟캐스트)',
  'Doubao голосовой подкаст (голосовой подкаст)'),
 ('Doubao-音声生成-1.0（音声生成）',
  'Doubao-音频生成-1.0（生成音频）',
  'Doubao Audio Generation 1.0 (audio generation)',
  'Doubao Génération audio 1.0 (génération audio)',
  'Doubao 오디오 생성 1.0 (오디오 생성)',
  'Doubao генерация аудио 1.0 (генерация аудио)'),
 ('Doubao-Seedream-4.5（画像生成モデル4K）',
  'Doubao-Seedream-4.5（生图模型4K）',
  'Doubao-Seedream-4.5 (image model 4K)',
  "Doubao-Seedream-4.5 (modèle d'image 4K)",
  'Doubao-Seedream-4.5 (이미지 생성 모델 4K)',
  'Doubao-Seedream-4.5 (модель изображений 4K)'),
 ('Doubao-Seedream-5.0-Lite（軽量画像生成）',
  'Doubao-Seedream-5.0-Lite（轻量级生图）',
  'Doubao-Seedream-5.0-Lite (lightweight image generation)',
  "Doubao-Seedream-5.0-Lite (génération d'image légère)",
  'Doubao-Seedream-5.0-Lite (경량 이미지 생성)',
  'Doubao-Seedream-5.0-Lite (лёгкая генерация изображений)'),
 ('Doubao-Seedream-5.0-pro（高精度画像生成）',
  'Doubao-Seedream-5.0-pro（精准生图）',
  'Doubao-Seedream-5.0-pro (precision image generation)',
  "Doubao-Seedream-5.0-pro (génération d'image de précision)",
  'Doubao-Seedream-5.0-pro (정밀 이미지 생성)',
  'Doubao-Seedream-5.0-pro (точная генерация изображений)'),
 ('Doubao-Seedance-2.0-mini（動画生成）',
  'Doubao-Seedance-2.0-mini（生成视频）',
  'Doubao-Seedance-2.0-mini (video generation)',
  'Doubao-Seedance-2.0-mini (génération vidéo)',
  'Doubao-Seedance-2.0-mini (동영상 생성)',
  'Doubao-Seedance-2.0-mini (генерация видео)'),
 ('Doubao-Seedance-2.0-fast（高速動画生成）',
  'Doubao-Seedance-2.0-fast（快速生成视频）',
  'Doubao-Seedance-2.0-fast (fast video generation)',
  'Doubao-Seedance-2.0-fast (génération vidéo rapide)',
  'Doubao-Seedance-2.0-fast (고속 동영상 생성)',
  'Doubao-Seedance-2.0-fast (быстрая генерация видео)'),
 ('Doubao-Seedance-2.0（動画生成）',
  'Doubao-Seedance-2.0（生成视频）',
  'Doubao-Seedance-2.0 (video generation)',
  'Doubao-Seedance-2.0 (génération vidéo)',
  'Doubao-Seedance-2.0 (동영상 생성)',
  'Doubao-Seedance-2.0 (генерация видео)'),
 ('GLM-5.2（コーディングモデル）',
  'GLM-5.2（编程模型）',
  'GLM-5.2 (coding model)',
  'GLM-5.2 (modèle de code)',
  'GLM-5.2 (코딩 모델)',
  'GLM-5.2 (модель для кодирования)'),
 ('Doubao-Seed-2.0-mini（言語モデル）',
  'Doubao-Seed-2.0-mini（语言模型）',
  'Doubao-Seed-2.0-mini (language model)',
  'Doubao-Seed-2.0-mini (modèle linguistique)',
  'Doubao-Seed-2.0-mini (언어 모델)',
  'Doubao-Seed-2.0-mini (языковая модель)'),
 ('Doubao-Seed-Evolving（エージェント言語モデル）',
  'Doubao-Seed-Evolving（智能体语言模型）',
  'Doubao-Seed-Evolving (agent language model)',
  'Doubao-Seed-Evolving (modèle linguistique agentique)',
  'Doubao-Seed-Evolving (에이전트 언어 모델)',
  'Doubao-Seed-Evolving (агентная языковая модель)'),
 ('Doubao-Seed-2.1-pro（コーディング言語モデル）',
  'Doubao-Seed-2.1-pro（编程语言模型）',
  'Doubao-Seed-2.1-pro (coding language model)',
  'Doubao-Seed-2.1-pro (modèle linguistique de code)',
  'Doubao-Seed-2.1-pro (코딩 언어 모델)',
  'Doubao-Seed-2.1-pro (языковая модель для кодирования)'),
 ('Doubao-Seed-2.1-turbo（言語モデル）',
  'Doubao-Seed-2.1-turbo（语言模型）',
  'Doubao-Seed-2.1-turbo (language model)',
  'Doubao-Seed-2.1-turbo (modèle linguistique)',
  'Doubao-Seed-2.1-turbo (언어 모델)',
  'Doubao-Seed-2.1-turbo (языковая модель)'),
 ('Doubao-Seed-2.0-lite（マルチモーダル推論モデル）',
  'Doubao-Seed-2.0-lite（模态推理模型）',
  'Doubao-Seed-2.0-lite (multimodal reasoning model)',
  'Doubao-Seed-2.0-lite (modèle de raisonnement multimodal)',
  'Doubao-Seed-2.0-lite (멀티모달 추론 모델)',
  'Doubao-Seed-2.0-lite (мультимодальная модель рассуждений)'),
]

LANGS = [('zh', 1), ('en', 2), ('fr', 3), ('ko', 4), ('ru', 5)]

for code, idx in LANGS:
    p = 'i18n/locales/%s.js' % code
    src = io.open(p, encoding='utf-8').read()
    tail = '`);'
    assert src.rstrip().endswith(tail), p + ' 尾部格式异常'
    lines = []
    added = 0
    for r in ROWS:
        ja = r[0]
        if ja in src:
            continue          # 已存在则不重复追加
        lines.append('%s|%s' % (ja, r[idx]))
        added += 1
    if not lines:
        print(code, '无需追加')
        continue
    pos = src.rstrip().rfind(tail)
    body = src[:pos]
    if not body.endswith('\n'):
        body += '\n'
    body += '\n'.join(lines) + '\n'
    body += src[pos:]
    io.open(p, 'w', encoding='utf-8').write(body)
    print(code, '追加', added, '条')
