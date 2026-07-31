# Hyper Meta AI Roadmap

This roadmap describes product direction, not shipped functionality or delivery promises. Priorities will change with the Meta Wearables SDK, Apple platform capabilities, real-device testing, and user feedback.

## Product Principles

- **Voice first**: glasses interaction centers on low latency, interruption, and continuous sessions.
- **Open Agents**: support multiple implementations through Providers, a Router, and a Tool Registry.
- **Native collaboration**: follow Apple Intelligence and Apple-native AI capabilities, preferring system capabilities when privacy, latency, and device support are appropriate.
- **Controlled and observable**: camera, location, network, messaging, and automation tools need explicit permissions, confirmation, and state feedback.
- **Real devices first**: simulators provide automated regression coverage; key experiences are validated on Ray-Ban Meta hardware.

## Phase 0: Foundation

**Status: in progress**

- [x] Adopt the Hyper Meta AI identity.
- [x] Narrow active maintenance to iOS.
- [x] Establish iOS simulator tests, repository checks, and tag releases.
- [ ] Reorganize the App Shell, session state, and dependency boundaries.
- [ ] Define shared Agent, Audio Session, Tool, and Permission protocols.
- [ ] Establish a real-device compatibility matrix and diagnostics baseline.

## Phase 1: Voice Agent Core

**Status: planned**

- [ ] Full-duplex voice sessions and a low-latency audio pipeline.
- [ ] One input layer for wake words, buttons, Siri, headphones, and phone audio.
- [ ] Barge-in, interruption recovery, streaming ASR, and streaming TTS.
- [ ] Session lifecycle, network transitions, error recovery, and offline states.
- [ ] A stable first OpenClaw Agent Adapter.
- [ ] Privacy prompts, permission confirmation, and observable voice-session state.

## Phase 2: Agent Platform

**Status: planned**

- [ ] Hermes Agent Adapter.
- [ ] Custom HTTP/WebSocket Agent protocol.
- [ ] Agent Router, model selection, capability discovery, and failover.
- [ ] Tool Registry, permission confirmation, action audit, and revocation.
- [ ] Agent sessions, preferences, and controllable memory.
- [ ] Shared audio, vision, and tool-context contracts across Agent providers.

## Phase 3: Vision, Context, and Apple Intelligence

**Status: planned**

- [ ] Fuse live visual context with voice sessions.
- [ ] OCR, translation, object and scene understanding, and follow-up questions.
- [ ] Evaluate and integrate future Apple Intelligence capabilities exposed by Apple.
- [ ] Explore on-device models, Siri, App Intents, and system intelligence as OS and hardware support mature.
- [ ] Expose Apple-native capabilities as discoverable, permissioned Agent Providers or Tools.
- [ ] Provide stable Agent or cloud fallbacks on unsupported devices and OS versions.
- [ ] Privacy switches, data lifecycles, and local cleanup for visual input.
- [ ] Accessibility, audio feedback, and state cues designed for glasses.

## Phase 4: Streaming 2.0

**Status: planned**

- [ ] A reliable RTMP core with network recovery.
- [ ] Dynamic bitrate, resolution, frame-rate, and audio policies.
- [ ] Multi-platform, multi-destination profiles, and permission management.
- [ ] Preview, recording, event markers, and stream controls.
- [ ] AI scene understanding and controlled assistance during live streams.
- [ ] Performance metrics, diagnostics, and real-device regression baselines.

## Phase 5: Public Release

**Status: planned**

- [ ] Publish privacy, permission, and data-flow documentation.
- [ ] Complete the device compatibility matrix, onboarding, and troubleshooting guides.
- [ ] Establish public issue, version, changelog, and contribution processes.
- [ ] Run staged TestFlight testing.
- [ ] Plan App Store delivery when signing, review, and operations are ready.

## Roadmap Updates

The roadmap will be updated around verifiable product capabilities. When Apple platform capabilities, the Meta Wearables SDK, or third-party Agent protocols change, compatibility and privacy impact will be recorded before phase ordering is adjusted.
