# Hyper Meta AI Roadmap

路线图描述产品方向，不代表已经发布的功能或时间承诺。优先级会根据 Meta Wearables SDK、Apple 平台能力、真实设备测试和用户反馈持续调整。

## 产品原则

- **语音优先**：眼镜交互以低延迟、可打断和连续会话为核心。
- **Agent 开放**：不绑定单一 Agent，通过 Provider、Router 和 Tool Registry 支持多种实现。
- **原生协同**：持续关注 Apple Intelligence 与 Apple 原生 AI 能力，在隐私、延迟和设备兼容性满足要求时优先采用系统能力。
- **可控可观察**：相机、位置、网络、消息和自动化等能力都需要明确权限、确认和状态反馈。
- **真实设备优先**：模拟器用于自动化回归，关键体验以 Ray-Ban Meta 真机测试为准。

## Phase 0: Foundation

**状态：进行中**

- [x] 统一项目名称为 Hyper Meta AI。
- [x] 收敛到 iOS-only 的维护范围。
- [x] 建立 iOS simulator tests、文档检查和 tag release 流程。
- [ ] 重组 App Shell、会话状态和依赖注入边界。
- [ ] 建立统一的 Agent、Audio Session、Tool 和 Permission 协议。
- [ ] 建立真实设备兼容性矩阵和诊断日志基线。

## Phase 1: Voice Agent Core

**状态：计划中**

- [ ] 全双工语音会话和低延迟音频管线。
- [ ] 统一唤醒词、按钮、Siri、耳机和手机输入入口。
- [ ] Barge-in、打断恢复、流式 ASR 和流式 TTS。
- [ ] 会话生命周期、网络切换、错误恢复和离线状态处理。
- [ ] 首个稳定的 OpenClaw Agent Adapter。
- [ ] 语音会话的隐私提示、权限确认和可观测状态。

## Phase 2: Agent Platform

**状态：计划中**

- [ ] Hermes Agent Adapter。
- [ ] 自定义 HTTP/WebSocket Agent 接入协议。
- [ ] Agent Router、模型选择、能力发现和故障转移。
- [ ] Tool Registry、权限确认、操作审计和撤销策略。
- [ ] Agent 会话、偏好和可控记忆。
- [ ] 为不同 Agent 建立统一的音频、视觉和工具上下文协议。

## Phase 3: Vision, Context and Apple Intelligence

**状态：计划中**

- [ ] 实时视觉上下文与语音会话融合。
- [ ] OCR、翻译、物体/场景理解和连续追问。
- [ ] 评估并接入 Apple Intelligence 未来开放的原生 AI 能力。
- [ ] 根据设备与系统版本，探索端侧模型、Siri、App Intents 和系统级智能协同。
- [ ] 将 Apple 原生能力封装为可发现、可授权的 Agent Provider 或 Tool。
- [ ] 为不支持新能力的设备提供稳定的 Agent/云端回退路径。
- [ ] 视觉输入的隐私开关、数据生命周期和本地清理。
- [ ] 针对眼镜交互完善可访问性、反馈音和状态提示。

## Phase 4: Streaming 2.0

**状态：计划中**

- [ ] 可靠的 RTMP 推流核心和网络恢复策略。
- [ ] 码率、分辨率、帧率和音频策略的动态调节。
- [ ] 多平台、多目的地、直播场景配置和权限管理。
- [ ] 直播预览、录制、事件标记和直播控制台。
- [ ] 直播中的 AI 场景理解与辅助操作。
- [ ] 性能指标、诊断日志和真实设备回归基线。

## Phase 5: Public Release

**状态：计划中**

- [ ] 完成隐私、权限和数据流说明。
- [ ] 完善设备兼容性矩阵、安装引导和故障排查文档。
- [ ] 建立公开 Issue、版本、变更记录和贡献流程。
- [ ] 通过 TestFlight 进行分阶段测试。
- [ ] 根据签名、审核和运营条件规划 App Store 发布。

## Roadmap 更新规则

路线图会以可验证的产品能力为单位更新。Apple 平台能力、Meta Wearables SDK 或第三方 Agent 协议发生变化时，先记录兼容性和隐私影响，再调整阶段顺序。
