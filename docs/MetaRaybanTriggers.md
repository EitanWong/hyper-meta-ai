# Meta Ray-Ban 眼镜触发事件研究（DAT SDK v0.8.0）

> 结论先行：**Meta 官方 Wearables DAT SDK 不向第三方 App 暴露「镜腿轻点 / 快门键」这类原始硬件事件**。
> 第三方 App 能拿到的是：会话状态变化（单击 = 暂停/恢复、长按 = 停止的**间接呈现**）、相机拍照/视频流、
> Display 眼镜上自绘 UI 的点击回调（onTap）、以及设备连接/热/电池状态。
> 因此 JARVIS 的「触发」由**统一触发中心**承接：眼镜间接事件 + Apple 原生触发源（背部轻点 / 操作按钮 / Siri / 快捷指令 / URL）走同一条路由与审计日志。

## 一、SDK 能拿到什么（依据官方 `meta-wearables-dat-ios` 0.8.0 接口）

| 能力 | API | 说明 |
| --- | --- | --- |
| 设备发现 / 注册 | `Wearables` / `WearablesInterface`、`RegistrationState` | 注册、设备列表流（`devicesStream`） |
| 连接 / 兼容状态 | `Device.linkState` / `addLinkStateListener`、`Compatibility` | 连接、固件 / SDK 兼容 |
| 设备会话状态 | `DeviceSession.stateStream`（idle/starting/started/paused/stopping/stopped） | **镜腿单击/长按的间接呈现**：单击 = paused/resumed，长按 = stopped |
| 会话错误 | `DeviceSession.errorStream`（thermal / battery / peakPower / hinges 等） | 热降级、低电量、折叠等异常 |
| 相机拍照 | `DeviceSession.addStream` → `Stream.capturePhoto` → `photoDataPublisher` | 眼镜相机拍照（HEIC/JPEG），本 App 已接入 |
| 视频流 | `Stream.videoFramePublisher`（`CMSampleBuffer` / `UIImage`） | 实时预览帧，本 App 已接入（lease 机制） |
| 眼镜屏幕渲染 | `MWDATDisplay`：`FlexBox` / `Text` / `Button` / `Image` / `Icon` / `VideoPlayer` | 在 Display 眼镜上渲染 JARVIS 状态卡 / 菜单 / 结果卡 |
| **渲染内容点击** | `FlexBox.onTap`（含 ObjC 桥） | **Display 眼镜上按钮点击回调**——本 App 的镜片菜单（Talk/Repeat/Vision…）即基于此 |
| 设备热状态 | `Wearables.deviceStateStream(for:)` → `DeviceState.thermalLevel` | 热状态监控 |
| **模拟镜腿（Mock）** | `MockCaptouchKit.tap()` / `tapAndHold()` | 仅 Mock 设备可用，用于开发 / 演示 / UI 测试 |

## 二、SDK 拿不到什么（硬边界）

- 真实眼镜的**原始 captouch 手势事件**（单击 / 双击 / 长按 / 滑动）不会回调给第三方 App——只有 Meta View / Meta AI 应用与系统级体验可用。
- **快门键（拍照键）**按下事件不开放；第三方只能主动调用 `capturePhoto`。
- 麦克风音频流不开放（本 App 的语音输入走 iPhone 麦克风）。

## 三、本 App 的触发中心（本轮实现）

统一触发模型 `AgentWearableTrigger`（`AgentWearableTriggerService.swift`）：

```
触发源（Source）                        手势（Gesture）                    路由结果（Outcome）
├─ glassesSession（会话状态推断）   ├─ wake（空闲唤醒 / 活跃恢复）    ├─ turn(AgentTurnCommand)
├─ glassesDisplay（镜片 onTap）    ├─ interrupt / resume / endTurn ├─ captureVision（眼镜拍照识图）
├─ mockCaptouch（Mock 模拟）       ├─ captureVision                ├─ repeatLastReply（重听回复）
├─ backTap（背部轻点）             ├─ repeatLastReply              └─ ignored(防抖 / 无会话)
├─ actionButton（操作按钮）        └─ mockTap / mockTapAndHold
├─ shortcut（Siri / 快捷指令）
├─ urlScheme（hypermetaai://trigger?gesture=wake）
└─ inApp（演示按钮）
```

- **去抖**：同一来源同一手势 0.8s 内重复触发 → 忽略（防 Back Tap 与镜片双触发）。
- **审计**：每次触发写入 `AgentWearableLogStore`（上限 50 条，UserDefaults 持久化），外设中心展示。
- **副作用**：wake → `QwenVoiceSession.wake()` + 请 Home 页呈现语音会话；captureVision → `QuickVisionManager` 眼镜拍照识图；repeat → 通知语音页 / 聊天页重听；interrupt/resume/endTurn → 会话控制；全部带触觉反馈。

## 四、Apple 原生触发源配置指南

### 背部轻点（iPhone 8 及以后，最接近「轻点镜腿」）

1. 设置 → 辅助功能 → 触控 → **背部轻点**
2. 选择「轻点两下」或「轻点三下」→ 向下滚动选「**快捷指令**」
3. 在快捷指令 App 中新建：搜索并添加「HyperMeta AI → **触发 JARVIS**」，把「动作」参数设为「唤醒 JARVIS」（或打断 / 拍照识图 / 重听回复 / 结束回合）
4. 之后在任意界面轻点手机背部两次 = 唤醒 JARVIS

### 操作按钮（iPhone 15 Pro / 16 系列）

设置 → 操作按钮 → 选择「快捷指令」→ 选「触发 JARVIS」（动作参数同上）。

### Siri / 快捷指令

App 注册的 App Intent 会自动出现在快捷指令 App 的「HyperMeta AI」分类中，可自由组合（例如「收到提醒时 → 触发 JARVIS 重听回复」）。

### 通用 URL

`hypermetaai://trigger?gesture=wake`（gesture 取值：`wake` / `interrupt` / `resume` / `endTurn` / `captureVision` / `repeatLastReply` / `mockTap` / `mockTapAndHold`），可被任何支持 URL Scheme 的自动化调用。

### Mock 模拟（开发 / 演示）

Debug 菜单的 MockDeviceKit 可配对模拟眼镜，`MockCaptouchKit.tap()` / `tapAndHold()` 走与真实触发完全相同的路由；外设中心也有演示按钮（来源标记为「App 内」与「模拟镜腿」）。

## 五、JARVIS 体验闭环

```
轻点镜腿 / 轻点手机背部 / 按操作按钮 / 说「嘿 Siri」
        ↓
AgentWearableTriggerCenter（去抖 + 审计）
        ↓
wake → 语音会话聆听     captureVision → 眼镜拍照 + 识图 + 播报
repeat → 重听回复       interrupt/resume/endTurn → 回合控制
        ↓
镜片状态卡（MWDATDisplay）+ TTS 播报 + 手机触觉反馈
```
