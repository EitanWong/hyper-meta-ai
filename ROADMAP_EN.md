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
- [x] Establish a real-device compatibility matrix and diagnostics baseline.

## Phase 1: Voice Agent Core

**Status: core complete**

- [x] Full-duplex voice sessions and a low-latency audio pipeline.
- [x] One input layer for wake words, buttons, Siri, headphones, and phone audio: Siri phrases / Shortcuts / Spotlight / Action Button start the voice session (headphones reach it indirectly via Siri).
- [x] Control Center controls for the voice session (widget extension, iOS 18+: start / stop controls, App Group cross-process communication).
- [x] Barge-in, interruption recovery, streaming ASR, and streaming TTS.
- [x] Session lifecycle, network transitions, error recovery, and offline states.
- [x] A stable first OpenClaw Agent Adapter.
- [x] Privacy prompts, permission confirmation, and observable voice-session state.

## Phase 2: Agent Platform

**Status: in progress**

- [x] Hermes Agent Adapter.
- [x] Custom HTTP/WebSocket Agent protocol: HTTP uses OpenAI-compatible SSE; WebSocket uses an event-stream protocol (chat / delta / done / tool_call / tool_result / error / ping). The config form selects the transport and runs the matching health check; chat routes uniformly; legacy configs decode with HTTP as the default.
- [x] Agent Router, model selection, capability discovery, and failover.
- [x] Dual-track task interaction: voice progress queries / cancellation requests (local interception in brain mode).
- [x] Three-stage task timeline states (queued / running / finished).
- [x] On-glasses task menu action: "Task" item appears while background tasks are active for one-tap progress announcements.
- [x] Task list in chat page: shared component with the voice page, state stays in sync.
- [x] Extended local voice commands: repeat last reply / start new chat (local interception in brain mode).
- [x] On-glasses approval shortcuts: Allow / Deny buttons on the glasses approval card submit decisions directly.
- [x] Approval experience: TTS voice prompt when an approval arrives; instant on-glasses feedback (Done / Denied) after Allow / Deny decisions.
- [x] Approval card "Later" action: dismiss without deciding so the gateway can ask again; approval voice alert is configurable.
- [x] Unified Recent timeline in Agent Hub: OpenClaw / Hermes / Qwen voice sessions in one list, tap to resume the matching session.
- [x] Tool Registry seed: unified declaration of in-app authorizable tools (vision capture / messaging / task control / voice reply); permission decisions are written to an audit log.
- [x] Recent audit UI: the settings page lists audit entries (action / tool / detail / relative time) with one-tap clear.
- [x] Revocation policy: per-tool revoke / restore (persisted); a revoked vision-capture capability is blocked at the invocation point, and revoke / restore events are audited.
- [x] On-glasses audit entry: the voice and chat glasses menus gain an "Audit" item showing the latest audit entry (tool · action · detail · relative time).
- [x] Session preferences & controllable memory: a voice-session memory toggle (no auto-resume when off) plus one-tap deletion of all records for that agent.
- [x] Chat session memory: history auto-resume on chat pages (OpenClaw / Hermes) is governed by the same setting family, with separate voice / chat toggles.
- [x] Chat vision sending: the on-glasses Vision menu item now captures and sends a photo in chat (OpenClaw / Hermes receive the image directly), gated by the revocation policy.
- [x] Vision follow-up: after sending a photo in chat, the frame stays as the session's vision context and follow-up questions automatically carry it (applies uniformly to OpenClaw / Hermes / custom agents); clearable from the input bar and toggleable in Settings.
- [x] On-device vision OCR: a one-tap "OCR" action on both chat and voice pages recognizes text in the glasses frame (Apple Vision accurate mode, zh/en, offline and free); results are mirrored to the glasses display, can be read aloud, sent to the agent for follow-ups, or copied. On the voice page the text is read aloud first, then forwarded as context to the current brain.
- [x] On-device translation: one-tap translation on the OCR result sheet (Apple Translation, iOS 18+, offline); language direction is auto-detected (CJK → English, otherwise → Simplified Chinese) and the translation can be read aloud; older systems get a graceful downgrade hint.
- [x] On-device scene understanding: say "看看这是什么 / 识别场景" or use the lenses' "Scene" action to run Apple Vision scene classification plus animal detection offline on the glasses frame; the result is shown on the lenses and read aloud, forwarded as context to the current brain in voice mode, and sent as a user message for follow-up in chat.
- [x] On-glasses OCR / Translate quick actions: the turn menu now has "OCR" (capture + read text aloud) and "Translate" (send the latest captured text to the current agent and speak the translation), available on both voice and chat pages; the latest OCR text is shared across pages.
- [x] Custom HTTP agent protocol core: OpenAI-compatible /v1/chat/completions streaming client (config store + SSE parsing + health check + error surfacing).
- [x] Custom agent Hub integration: config sheet (add / edit / delete + connectivity test), Hub list entry, streaming chat on the chat page (multimodal image sending + interrupt), and unified Recent timeline classification with resume.
- [x] Custom agent tool calling: config supports OpenAI tool declaration JSON (function calling), the request carries `tools`, streaming parses `tool_calls` deltas and surfaces tool progress (parity with Hermes).
- [x] Custom agent multi-turn context: the chat page sends the recent 20 turns (excluding images/empty text) with each request; starting a new chat resets the context.
- [x] Custom agent local tool execution loop: automatic multi-round loop (accumulate tool_calls → execute locally → return tool results → continue), supporting voice.reply narration and task.control progress summaries, capped at 4 rounds.
- [x] Hermes tool lifecycle visualization: parses function_call / function_call_output from both streamed and batch /v1/responses payloads (nested and flat formats), fixes nested-item tool-name reporting, and shows tool results on the glasses (chat and voice pages).
- [x] Custom agent sensitive tool approval chain: vision.capture goes through the on-glasses approval card (Allow / Deny / Later + 60s timeout skip), revoked tools are intercepted, requests and decisions are written to the audit log, and the approved capture is shown in chat.
- [x] Custom agent as a voice brain: selectable in the voice page and Settings with a specific config; dictation is forwarded with tool calling and TTS replies (parity with Hermes / OpenClaw).
- [x] Custom agent voice history grouped by config ID: voice-page history for custom brains is persisted under custom.<UUID> and enters the unified Hub timeline; other brains share the realtime voice namespace.
- [x] Tool execution results on the glasses: after a custom agent executes a tool in chat, non-empty results are surfaced on the glasses display via AgentDisplayHub.
- [x] Presence mode: a voice-page toggle keeps the agent listening after each turn (no idle auto-end); long-press or the voice command "end conversation" exits explicitly.
- [x] Wear-recovery hint: after a session ends unexpectedly from take-off or folding, reconnecting glasses prompts "tap to resume" and shows a resume entry on the display.
- [x] Permission modes: pick an approval policy in Settings (always ask / ask once / allow for session / always allow / deny all); auto-handled requests are audited and fall back to the approval card if the gateway fails.
- [x] Glasses shortcuts: configure quick commands in Settings (up to 8); the Shortcuts submenu on the on-glasses menu triggers them with one tap on both voice and chat pages.
- [x] Long-term memory: maintain preference entries in Settings (max 20); when enabled, they are injected as system context with Hermes / custom agent requests and persist across sessions. Voice "remember X" commands are stored immediately with a spoken confirmation, and statement-style suggestions ("I like…") are auto-extracted at session end for review and adoption in Settings.
- [x] Front-end owned tools (named lists): user-named lists such as shopping lists / to-dos are maintained locally by the app — voice commands add / query / remove / clear items with immediate spoken confirmation, plus full management in Settings. Custom agents can read/write lists via the list.manage tool without approval. No agent session is consumed.
- [x] Local reminders: voice sets local notifications directly ("remind me to drink water in 10 minutes" / "remind me to meet at 8 tomorrow morning"). Relative and absolute Chinese time phrases are parsed locally (12-hour clock conversion for "下午", auto-rollover to tomorrow when the time has passed), scheduled via UNUserNotificationCenter without consuming an agent session; voice can cancel or query reminders, and Settings lists them with swipe-to-delete (cancels the pending notification) and clear-all, capped at 20.
- [x] Foreground reminder announcement: when a reminder fires while the app is in the foreground, show a lens result card plus TTS announcement (toggleable with the voice-reply setting), with the system banner as fallback; non-reminder notifications keep the normal banner.
- [x] Quiet Mode: a Settings toggle that suppresses proactive announcements (task completion regression, approval arrival, thinking hints, reminder firing) while direct replies and instant local-command feedback still speak; lens cards and phone haptics are always kept.
- [x] Diagnostics report baseline: Settings → "Diagnostics Report" generates a text report covering app/system, agent settings, connections, tools & permissions, audit and reminders, with copy and system share support; API keys and tokens are always masked.
- [x] Chat-page task visibility: task completion/failure/cancellation now triggers the lens result card, TTS announcement and phone haptic on the chat page too (respecting Quiet Mode and the announcement window), along with task acknowledgment receipts; running-task progress and step messages (`runningTaskCount` / `taskMessage`) stream to the lens in real time, matching the voice page; the haptic mapping is pure logic (`AgentDisplayResultMapping.haptic`) shared by both entry points.
- [x] Repeating reminders: voice sets daily / weekly recurring reminders ("remind me to take medicine at 8 every day" / "remind me to report every Wednesday at 3pm", with 周X / 礼拜X / 星期X weekday forms); when the time has passed the next occurrence is auto-computed and the notification repeats on the system calendar trigger; Settings shows a repeat badge.
- [x] On-glasses task center submenu: progress announce / cancel latest task / back.
- [x] Tool Registry, permission confirmation, action audit, and revocation.
- [x] Agent sessions, preferences, and controllable memory.
- [ ] Shared audio, vision, and tool-context contracts across Agent providers.

## Phase 3: Vision, Context, and Apple Intelligence

**Status: in progress**

- [x] Fuse live visual context with voice sessions.
- [x] OCR, translation, object and scene understanding, and follow-up questions.
- [ ] Evaluate and integrate future Apple Intelligence capabilities exposed by Apple.
- [ ] Explore on-device models, Siri, App Intents, and system intelligence as OS and hardware support mature.
  - [x] First on-device model integration: when no agent gateway is configured, live title polish and scene analysis fall back to Apple Intelligence on-device models (Foundation Models, iOS 26+, offline, private, data never leaves the device); availability gating (toggle / OS version / model readiness / language support) degrades gracefully to the existing "no gateway" prompt, with a persisted settings toggle (on by default) and an "On-Device AI" badge on the result sheet; `LocalBrainService` / `LocalBrainResponder` are pure-logic testable.
  - [x] Built-in Gateway: ports the qwen-audio-agent v1.8.3 server core — nonblocking work acceptance (spawn_thinking semantics: accept immediately, per-owner FIFO, one in-flight per owner), the coordination protocol (qwen_audio_agent_protocol: state / mode / presentation parsing and normalization, fenced-code and brace-window fallback, up to two retries for non-final states, final speech only from presentation.speech), the action-promise response guard and realtime response lifecycle, and a safe announcement insertion window (held while the user speaks, a turn is pending, or audio is queued); the "Ask Lucky" single-turn path now runs through the built-in gateway coordinator (protocol prompt + retry + final-speech extraction, with automatic plain-text fallback for non-protocol backends); the default AI name is now Lucky; `AgentGatewayService` uses injectable backend execution/cancellation, and parsing / queue / guards / window are pure-logic testable.
  - [x] App Schema system intents (iOS 26.2 / 27.0): `@AppIntent(schema: .assistant.activate)` registers the Lucky voice session as the system "activate voice assistant" action (reachable from the iPhone side button / Siri AI; wake + voice-session request share one semantic); the reminders domain joins Apple Intelligence — `@AppEntity(schema:)` list / reminder / section / location-trigger entities plus `listType` / `locationTriggerEvent` enums strictly follow the schema validation (required properties, optionality, `DateComponents`, `Set<String>`, `Calendar.RecurrenceRule`, `CLPlacemark`), and `@AppIntent(schema: .reminders.createReminder)` / `.createList` write straight into `AgentReminderStore` / `AgentListStore` (recurrence maps to daily / weekly, note / tags / URLs merge into the reminder text, missing due date defaults to one hour out, system notification scheduling); Siri confirms success aloud and reports empty-content / duplicate / limit failures distinctly; `ReminderSchemaService` / `ReminderListSchemaService` have injectable storage and scheduling.
- [x] Apple-native capabilities as discoverable tools: on-device OCR (vision.ocr) and scene recognition (vision.scene) are registered in the Tool Registry so custom agents, Hermes and voice-forwarding brains can invoke them; they run offline on the latest captured frame (free, no API key) and return results for follow-ups, with guidance text when no frame is available. OpenClaw gateways can also invoke `vision.ocr` / `vision.scene` commands (advertised in `commands`; revoked vision.capture returns REVOKED).
- [x] No-glasses / no-frame fallback: when the chat or voice page cannot grab a glasses frame, on-device OCR and scene recognition fall back to a photo picked from the photo library and run through the same offline Apple Vision pipeline; on iOS 17 (no on-device translation) the UI already shows an upgrade hint.
- [x] Vision data privacy and local cleanup: captured frames live only in memory and never touch disk; Settings offers a "Vision Privacy" one-tap clear-all (retained frames plus OCR/scene results, broadcasting an event so views drop frames immediately), frames are dropped automatically when a session ends explicitly, and chat history never stores photos.
- [x] Accessibility, audio feedback, and state cues designed for glasses.

## Phase 4: Streaming 2.0

**Status: core complete (pending real-device regression)**

- [x] A reliable RTMP core with network recovery.
- [x] Dynamic bitrate, resolution, frame-rate, and audio policies.
- [x] Multi-platform, multi-destination profiles, and permission management.
- [x] Preview, recording, event markers, and stream controls.
- [x] AI scene understanding and controlled assistance during live streams.
- [x] Performance metrics, diagnostics, and real-device regression baselines.

## Phase 5: Public Release

**Status: release-ready (pending signing, review, and operations)**

- [x] Publish privacy, permission, and data-flow documentation.
- [x] Complete the device compatibility matrix, onboarding, and troubleshooting guides.
- [x] Establish public issue, version, changelog, and contribution processes.
- [x] Run staged TestFlight testing.
- [x] Plan App Store delivery when signing, review, and operations are ready.

## Roadmap Updates

The roadmap will be updated around verifiable product capabilities. When Apple platform capabilities, the Meta Wearables SDK, or third-party Agent protocols change, compatibility and privacy impact will be recorded before phase ordering is adjusted.
