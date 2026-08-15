# Privacy Policy (Draft)

> Effective date: to be set at release. This is the public privacy policy draft for App Store review,
> based on `docs/privacy-data-flow.md`. Review it against the actual app behavior before hosting.
> Updated: 2026-08-12

## 1. Introduction

Hyper Meta AI (the "App") is an AI voice assistant and live streaming tool for Ray-Ban Meta / Meta smart glasses.
The App follows three principles: **user-configured endpoints, local-first, no built-in cloud**.

The App does not operate any cloud service, does not create accounts, and does not collect advertising identifiers or use data for cross-app tracking. Whether voice, photos, or live video leave your device, and where they go, is determined by **your own configuration and actions**.

## 2. Data We Collect

The App itself does not upload data to a developer-operated server, nor does it collect data on behalf of third-party services:

- No account, phone number, email, or identity information is collected.
- No advertising identifiers (e.g., IDFA) are collected; no cross-app tracking.
- No analytics SDK is embedded. Crash and performance data is only transmitted when you voluntarily share diagnostic logs through a channel you choose.

## 3. Data Processing and Destinations

| Data | Trigger | Destination |
| --- | --- | --- |
| Glasses camera frames | You enter the streaming page / start streaming / attach an image in a chat | On-device preview; sent to the RTMP address you provide when streaming; sent to the Agent gateway you configure when attaching images to a chat |
| Voice | You start a voice session | Sent to the Agent / voice gateway you configure |
| Text messages | You send a message | Sent to the Agent gateway you configure |
| Scene recognition results | Automatic during streaming (can be disabled) | Processed on-device by Apple Vision; only text labels/summaries are shown; after "save to Agent memory", included in subsequent requests to the gateway you configure |
| Streaming platform URLs and keys | You enter them manually | Keys are stored only in Keychain; used to connect to the server you specify |

**Important**: the App contains no built-in cloud endpoints. All data that leaves the device is sent to **addresses you configure yourself** (self-hosted gateways, self-hosted streaming servers, or third-party platforms). Please read the privacy policies and terms of the respective providers before use.

## 4. Local Storage

- Recording files (MP4): stored in the App documents directory `Documents/RTMPRecordings`; deletable at any time.
- Diagnostic logs: `Documents/RTMPDiagnostics`, rolling maximum of 20 files; viewable, shareable, and deletable in Settings.
- Long-term memory, rules, and conversation history: stored locally; clearable in Settings.
- Streaming keys: stored in Keychain only; never written into scenario presets.

## 5. Permissions

| Permission | Purpose |
| --- | --- |
| Bluetooth | Connect to the smart glasses |
| Microphone | Voice conversation and voice commands |
| Photo library (add) | Save photos taken with the glasses |
| Siri | Voice shortcut to trigger quick recognition |
| Local network | Connect to self-hosted RTMP streaming servers and local Agent gateways |

The App does not use the iPhone camera and therefore does not request camera permission; video comes from the smart glasses.

## 6. Data Retention and Deletion

- You can clear memory, rules, conversations, and vision data in Settings with one tap.
- Recording files and diagnostic logs can be deleted directly in the App.
- Uninstalling the App removes all local data in its sandbox (Keychain items depend on system behavior).

## 7. Children's Privacy

The App is not directed at children under 13 and does not collect children's personal information. Users are responsible for their own streaming content.

## 8. Policy Updates

This policy will be updated whenever data flows or permissions change, with a notice in the App release notes.

## 9. Contact

Questions and feedback: GitHub Issues (attaching exported logs from Settings → Diagnostic Logs helps troubleshooting):
https://github.com/Turbo1123/turbometa-rayban-ai/issues
