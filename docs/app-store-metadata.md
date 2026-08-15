# App Store 元数据与素材草稿

> 用途：Phase 5 提审素材草稿，可直接复制进 App Store Connect；正式提交前请按最终产品定位微调。
> 更新：2026-08-12

## 1. 名称与副标题

- 名称：`Hyper Meta AI`
- 副标题候选（≤30 字符，三选一）：
  1. 眼镜 AI 语音助手与直播工具
  2. 智能眼镜语音助手与直播工具
  3. 眼镜语音 AI 与多平台直播

建议选 1；副标题与关键词、描述互补，避免重复堆砌。

## 2. 描述（中文，≤4000 字符）

```
Hyper Meta AI 是 Ray-Ban Meta / Meta 智能眼镜的 AI 语音助手与直播工具，把语音对话、多 Agent 协作与 RTMP 直播统一在眼镜端完成。

• 眼镜触发语音会话：单击打断、再单击恢复、长按结束；会话状态实时同步到镜片菜单。
• 多 Agent 统一接入（Agent 中心）：支持 OpenClaw、Hermes（OpenAI Responses 协议）与自定义 OpenAI 兼容 / WebSocket 网关，统一路由、记忆与规则注入。
• 实时语音对话：全双工流式语音（需在电脑端运行 qwen-audio-agent 网关）。
• 直播 2.0：RTMP 多平台推流（YouTube、Twitch、Bilibili、抖音、TikTok、Facebook Live 或自建服务器），自适应画质、断线自动重连、推流中本地录制与精彩瞬间标记、回放。
• 端侧 AI 辅助：Apple Vision 离线场景识别（免费、画面不出端），直播标题建议、一键存入 Agent 记忆；端侧 OCR 与翻译。
• 隐私优先：无内置云端、无账号、无广告追踪；端点与密钥全部由用户自配；直播隐私盾一键停止推流与录制。

注意：App 不使用 iPhone 相机，画面来自智能眼镜（需 Meta View App 完成配网）；无眼镜也可使用聊天与设置功能。
```

## 3. 关键词（≤100 字符）

```
眼镜,AI助手,语音助手,智能眼镜,直播,RTMP,推流,录制,场景识别,OCR,翻译
```

（约 40 字符，留有余量；可加 `Meta Ray-Ban` 英文词。）

## 4. 类别与年龄分级

- 类别：建议「工具」；如强调内容分享可选「摄影与录像」。
- 年龄分级问卷要点（如实回答）：
  - 直播画面为**用户生成内容且未过滤** → 该项通常指向 12+ 或 17+，以问卷实际选项为准。
  - 含位置权限声明（非核心功能）与蓝牙（连接硬件）。
  - 无账号、无社交互动、无购买 → 相关项选「否」。

## 5. 截图文案建议（每张一行说明）

| 截图 | 说明 |
| --- | --- |
| 1. 眼镜连接/语音会话 | 「单击镜腿，随时打断，随时恢复」 |
| 2. Agent 中心 | 「OpenClaw / Hermes / 自定义 Agent 统一接入」 |
| 3. 实时语音 | 「全双工流式语音对话」 |
| 4. 直播控制面板 | 「自适应画质 · 隐私盾 · 录制与标记」 |
| 5. 录制回放 | 「精彩瞬间标记，一键跳转」 |

## 6. 英文元数据（次要语言）

- Name: `Hyper Meta AI`
- Subtitle: `AI Voice Assistant & Live Streaming for Smart Glasses`
- Description:

```
Hyper Meta AI turns Ray-Ban Meta smart glasses into an AI voice assistant and live streaming studio.

• Temple-triggered voice sessions with barge-in and resume.
• Unified Agent Hub: OpenClaw, Hermes (OpenAI Responses), or any OpenAI-compatible / WebSocket gateway you host.
• Real-time duplex voice chat (qwen-audio-agent gateway).
• RTMP streaming to YouTube, Twitch, Bilibili, Douyin, TikTok, Facebook Live or your own server, with adaptive quality, auto-reconnect, local recording and highlight markers.
• On-device Apple Vision scene recognition, OCR and translation — free and offline.
• Privacy first: no built-in cloud, no account, no ads tracking; endpoints and keys are configured by you.

Note: the app does not use the iPhone camera; video comes from the glasses. Chat and settings work without glasses.
```

- Keywords: `glasses, AI assistant, voice, live stream, RTMP, Ray-Ban Meta, smart glasses, recording`

## 7. 素材清单状态

| 素材 | 状态 |
| --- | --- |
| App 图标 1024×1024 | 工程已含 `icon_1024x1024.png`，发布前复核无透明通道 |
| 截图 | 待制作（6.7″ 一套 + 6.5″/5.5″ 一套） |
| 隐私政策 URL | 草稿见 `docs/privacy-policy-zh.md` / `docs/privacy-policy-en.md`，待托管 |
| 支持 URL | 建议指向仓库 README |
