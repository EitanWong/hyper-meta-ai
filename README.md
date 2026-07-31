# Hyper Meta AI

<div align="center">

<img src="./rayban.png" width="128" alt="Hyper Meta AI"/>

**让 Ray-Ban Meta 眼镜成为真正的 AI 入口。**

[![iOS CI](https://img.shields.io/badge/CI-GitHub_Actions-2088FF?logo=githubactions&logoColor=white)](./.github/workflows/ios-tests.yml)
[![iOS 17+](https://img.shields.io/badge/iOS-17%2B-111111?logo=apple&logoColor=white)](https://www.apple.com/ios/)
[![License](https://img.shields.io/badge/License-MIT-2ea44f.svg)](LICENSE)

</div>

## 致谢

本项目基于 [Turbo1123/turbometa-rayban-ai](https://github.com/Turbo1123/turbometa-rayban-ai)。感谢原作者的开源工作和早期实现。

## 项目定位

Hyper Meta AI 是一个面向 Ray-Ban Meta 系列眼镜的 **iOS-only 独立 AI App**。项目希望把眼镜的摄像头、麦克风、扬声器和触控能力，组合成自然、低延迟、可扩展的语音 AI 入口，提供类似 Jarvis 或 E.D.I.T.H. 的连续辅助体验。

Android 目录作为历史代码保留，当前不参与维护、CI/CD 和新功能规划。

## 核心方向

- **Voice Agent First**：优先建设低延迟、可打断、全双工的语音 Agent 体验。
- **开放 Agent 生态**：通过统一 Provider 层接入 OpenClaw、Hermes 以及其他自建或第三方 Agent。
- **多模态上下文**：融合语音、实时视觉、OCR、翻译和环境状态，支持连续追问。
- **Apple 原生 AI**：随着 Apple Intelligence 和 Apple 原生 AI 能力持续发展，逐步评估并接入适用于眼镜场景的系统级智能、端侧模型、Siri/App Intents 等能力。
- **Live Streaming 2.0**：增强采集、编码、网络恢复、多平台推流、录制和直播中的 AI 辅助。

完整路线图见 [ROADMAP.md](ROADMAP.md)，英文版本见 [ROADMAP_EN.md](ROADMAP_EN.md)。

## 开发

当前只维护 iOS 17+，使用 SwiftUI、Meta Wearables DAT SDK、XCTest 和 DAT Mock Device。

```bash
ONLY_TESTING=HyperMetaAITests ./Scripts/run-ios-tests.sh
```

使用 Xcode 打开 `HyperMetaAI.xcodeproj`，并在本地配置 Apple Developer Team、Meta App ID 和 API Key。敏感配置不应提交到公开仓库。

## CI/CD

- `repository-checks.yml`：文档、资源、脚本和提交格式检查。
- `ios-tests.yml`：macOS simulator 上运行 iOS 单元测试并上传 `.xcresult`。
- `release.yml`：推送 `v*.*.*` tag 后生成 iOS archive 并创建 GitHub Release。

App Store 和 TestFlight 发布将在签名、隐私说明与真实设备回归稳定后加入。

## 许可证

本项目采用 [MIT License](LICENSE)。第三方 SDK、Agent 服务和模型按各自许可证及服务条款使用。
