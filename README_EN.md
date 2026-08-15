# Hyper Meta AI

<div align="center">

<img src="./rayban.png" width="128" alt="Hyper Meta AI"/>

**Make Ray-Ban Meta glasses a real AI interface.**

[![iOS CI](https://img.shields.io/badge/CI-GitHub_Actions-2088FF?logo=githubactions&logoColor=white)](./.github/workflows/ios-tests.yml)
[![iOS 17+](https://img.shields.io/badge/iOS-17%2B-111111?logo=apple&logoColor=white)](https://www.apple.com/ios/)
[![License](https://img.shields.io/badge/License-MIT-2ea44f.svg)](LICENSE)

</div>

## Acknowledgement

This project is based on [Turbo1123/turbometa-rayban-ai](https://github.com/Turbo1123/turbometa-rayban-ai). Thanks to the original author for the open-source work and the early implementation.

## Product Direction

Hyper Meta AI is an **iOS-only independent AI app** for Ray-Ban Meta glasses. It combines the glasses camera, microphone, speakers, and touch controls into a natural, low-latency, extensible voice interface inspired by continuous assistant experiences such as Jarvis and E.D.I.T.H.

The Android directory remains historical code and is outside active maintenance, CI/CD, and new feature planning.

## Core Directions

- **Voice Agent First**: low-latency, interruptible, full-duplex voice Agent sessions.
- **Open Agent Ecosystem**: a unified Provider layer for OpenClaw, Hermes, and other self-hosted or third-party Agents.
- **Multimodal Context**: voice, live vision, OCR, translation, and environment state with continuous follow-up.
- **Apple Native AI**: as Apple Intelligence and Apple-native AI capabilities evolve, evaluate system intelligence, on-device models, Siri/App Intents, and other capabilities that fit the glasses experience.
- **Live Streaming 2.0**: better capture, encoding, recovery, multi-platform streaming, recording, and AI assistance during live sessions.

See the detailed [ROADMAP.md](ROADMAP.md) or the [English roadmap](ROADMAP_EN.md).

## Development

Active development targets iOS 17+ with SwiftUI, the Meta Wearables DAT SDK, XCTest, and the DAT Mock Device.

```bash
ONLY_TESTING=HyperMetaAITests ./Scripts/run-ios-tests.sh
```

Open `HyperMetaAI.xcodeproj` in Xcode and configure your Apple Developer Team, Meta App ID, and API keys locally. Do not commit sensitive configuration to the public repository.

## CI/CD

- `repository-checks.yml`: documentation, assets, scripts, and commit-format checks.
- `ios-tests.yml`: run iOS unit tests on a macOS simulator and upload `.xcresult`.
- `release.yml`: build an iOS archive and create a GitHub Release for `v*.*.*` tags.
- `testflight.yml`: manual TestFlight upload (requires signing and App Store Connect API key secrets; see `docs/testflight-plan.md`).

Release plans: `docs/testflight-plan.md` (staged TestFlight testing), `docs/app-store-release-plan.md` (App Store submission),
`docs/app-store-metadata.md` (metadata drafts), and privacy policy drafts `docs/privacy-policy-zh.md` / `docs/privacy-policy-en.md`.

## License

This project is licensed under the [MIT License](LICENSE). Third-party SDKs, Agent services, and models remain subject to their own licenses and service terms.
