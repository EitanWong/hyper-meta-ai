# App Store 发布计划

> 适用：Phase 5 第 5 项。规划签名、审核材料、隐私合规与运营条件，供 1.4.0 提审执行。
> 前提：先完成 `docs/testflight-plan.md` 的阶段测试并满足放行标准。
> 更新：2026-08-12

## 1. 目标与范围

- 首次发布 1.4.0：Agent 中心（OpenClaw / Hermes / 自定义 Agent）、实时语音（qwen-audio-agent）、RTMP 直播 2.0、眼镜交互。
- 本计划覆盖：签名、元数据、隐私合规、审核备注、提交流程与发布后运营。

## 2. 签名与证书

| 项 | 要求 |
| --- | --- |
| 证书 | Apple Distribution（Xcode 自动管理，Team `FYWDVBBN6N`） |
| Profile | App Store 分发 Profile（自动签名自动生成） |
| 提审构建 | 必须真签名；`CODE_SIGNING_ALLOWED=NO` 的 GitHub Release 包仅用于侧载 |
| 构建号 | `CURRENT_PROJECT_VERSION` 每次递增；`MARKETING_VERSION=1.4.0` 与仓库 tag 一致 |

建议在 Xcode 完成一次「Archive → Distribute App → App Store Connect」全流程，确认自动签名与 Team 匹配；
CI 自动提审（需证书 secrets）在 TestFlight CI 稳定后再评估，见 `docs/testflight-plan.md` 第 7 节。

## 3. 元数据与素材清单

| 项 | 要求 | 状态/来源 |
| --- | --- | --- |
| 名称 / 副标题 | 名称 `Hyper Meta AI`；副标题候选见 `docs/app-store-metadata.md` | 草稿就绪，待定稿 |
| 描述 | 中英文草稿见 `docs/app-store-metadata.md`（含功能说明与自配端点提示） | 草稿就绪，待定稿 |
| 关键词 | 中英文草稿见 `docs/app-store-metadata.md`（≤100 字符） | 草稿就绪，待定稿 |
| 类别 | 建议「工具」；如侧重内容分享可选「摄影与录像」 | 待定稿 |
| 年龄分级 | 如实完成问卷：直播内容为用户生成且未过滤、位置/蓝牙权限、无账号社交 | 预计 12+ 或 17+，以问卷结果为准 |
| App 图标 | 1024×1024 无透明通道 | 待设计 |
| 截图 | ≥1 套 6.7″（iPhone 17 Pro Max / 16 Pro Max）；另备 6.5″/5.5″ 一套；分辨率按 App Store Connect 提示导出 | 待制作 |
| App 预览视频 | 可选；建议 15-30s 展示眼镜对话与直播控制面板 | 可选 |
| 隐私政策 URL | 必须可公开访问；草稿见 `docs/privacy-policy-zh.md` / `docs/privacy-policy-en.md`（以 `docs/privacy-data-flow.md` 为底稿） | 草稿就绪，待托管 |
| 支持 URL | 指向仓库 README（含安装引导 `docs/setup-and-troubleshooting.md`） | 待托管 |
| 审核联系信息 | 姓名 + 邮箱/电话 | 待填写 |

## 4. 隐私与合规

### 4.1 App Store 隐私营养标签

如实填写（与 `docs/privacy-data-flow.md` 对齐，原则：**用户自配端点、本地优先、无内置云端**）：

- 用户内容：语音/文本/图片仅在用户发起对话或推流时发送至**用户自配的端点**；直播画面由用户主动发起。
- 不收集广告数据、不做追踪 → 无需 App Tracking Transparency 弹窗。
- 若后续接入崩溃/分析 SDK 采集标识符，须同步更新标签并重新评估。

### 4.2 权限与系统能力

- 蓝牙（眼镜连接）、麦克风（语音对话）、相册写入（保存照片）、Siri（快捷指令）——文案已在 Info.plist。
- 本地网络权限：访问自建 RTMP 服务器 / 局域网网关需要 `NSLocalNetworkUsageDescription`（发布前补齐，见第 7 节）。
- App 不使用 iPhone 相机（画面来自眼镜帧），无需 `NSCameraUsageDescription`。
- 后台音频模式（推流）在审核备注中说明用途。

### 4.3 出口合规

App 仅使用系统标准 TLS（HTTPS/WSS），无自定义加密 → 加密合规问卷选择「否」并走豁免；如实填写，不得默认。

### 4.4 直播平台合规

- App 不内置平台 SDK、不代用户登录、不抓取平台数据；RTMP 地址与密钥由用户自行配置（密钥存钥匙串）。
- 用户须遵守目标平台服务条款：Bilibili / Douyin（中国大陆实名与内容审核）、YouTube / Twitch / TikTok / Facebook Live（年龄、版权、直播规则）。
- App 已内置「开播合规清单」（`docs/device-regression-baseline.md` 第 7 组），内容责任由用户承担。
- 审核备注中说明：App 是通用 RTMP 推流工具，可指向自建服务器（MediaMTX/nginx-rtmp），不依赖特定平台。

### 4.5 用户生成内容（UGC）

- 直播画面由用户主动发起，提供隐私盾一键停止推流/编码/录制。
- 无内置内容社区、无账号体系、无他人内容分发。

## 5. 审核备注模板

```
Hyper Meta AI 是智能眼镜（Ray-Ban Meta / Meta 智能眼镜）配套工具，提供：
1) 眼镜语音对话：连接眼镜后语音唤醒/按钮对话，接入用户自配的 Agent 端点（OpenClaw / Hermes / 自定义 OpenAI 兼容服务）。
2) Agent 中心：文字/语音对话、工具调用、长期记忆与规则，端点与密钥由用户配置，App 无内置云端服务。
3) RTMP 直播：用户填写自己的推流地址与密钥后开播，支持多目的地、录制与端侧场景识别（Apple Vision）。
说明：
- App 不使用 iPhone 相机；画面来自眼镜帧（通过 Meta 官方 SDK 授权传输）。
- 无眼镜也可使用聊天、设置与文档引导功能（Agent 对话需自配端点）。
- 无内购、无账号注册、无广告追踪。
- 需要蓝牙、麦克风、相册写入、本地网络权限，均已在权限文案中说明。
- 后台音频模式用于直播推流期间保持编码与重连。
如需要视频演示，请联系（联系方式）。
```

## 6. 提交与发布流程

1. 完成 TestFlight 放行标准（`docs/testflight-plan.md` 第 8 节）。
2. 归档 → Distribute App → App Store Connect → 按 `docs/app-store-metadata.md` 填写元数据、截图、隐私标签、审核备注。
3. 提交审核（App Review 首次一般 24-48 小时，实际以 Apple 为准；提前准备回复补充问题）。
4. 审核通过后选择**手动发布 + 分阶段发布（Phased Release）**：约 7 天按 1% → 10% → 25% → 50% → 100% 放量，
   任一阶段发现问题可暂停放量。
5. 全量发布后关注崩溃与评分，按第 7 节运营。

## 7. 发布前 Checklist

- [ ] 签名：Team `FYWDVBBN6N`、Distribution 证书、真机 archive + export 全流程跑通。
- [ ] 权限：Info.plist 含 `NSLocalNetworkUsageDescription`；蓝牙/麦克风/相册/Siri 文案与功能一致。
- [ ] 隐私：隐私政策 URL 可访问（草稿 `docs/privacy-policy-zh.md` / `docs/privacy-policy-en.md`）；营养标签如实；无追踪声明；出口合规问卷「否 + 豁免」。
- [ ] 素材：图标、6.7″ 截图（+6.5″/5.5″）、描述/关键词/副标题（`docs/app-store-metadata.md`）、类别、年龄分级。
- [ ] 审核备注：按第 5 节模板填写，含联系方式与演示说明。
- [ ] 真机回归：`docs/device-regression-baseline.md` 第 1-8 组通过，执行记录已填写。
- [ ] 版本：`MARKETING_VERSION=1.4.0`、构建号递增、CHANGELOG 与 tag 一致。
- [ ] 直播合规：README/描述中说明用户责任；自建服务器冒烟通过。

## 8. 发布后运营

- 崩溃监控：Xcode Organizer（dSYM 已上传）持续观察前 48 小时崩溃率；阻断性崩溃立即评估「暂停分阶段发布」。
- 反馈：Issue 模板 + 诊断日志流程继续；App Store 评论与 TestFlight 反馈合并到同一 backlog。
- 版本节奏：首发后 1-2 周评估 1.5.0（修复 + 高优反馈）；修复版走相同 TestFlight 门禁。
- 回滚：分阶段发布可暂停/停止；已全量发布无法回滚二进制，只能「移除销售」并发布修复版。
- 合规复查：权限或数据流变更时同步更新隐私政策、营养标签与 `docs/privacy-data-flow.md`。
