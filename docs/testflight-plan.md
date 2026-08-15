# TestFlight 分阶段测试计划

> 适用：Phase 5 第 4 项。目标是把 1.4.0 通过 TestFlight 分阶段送达内测 → 种子用户 → 公开链接，
> 用真实设备回归基线作为每阶段放行门禁，收集可复现反馈后再进入 App Store 提审。
> 更新：2026-08-12

## 1. 目标与范围

- 在 App Store 提审前完成真实设备验证：眼镜连接、语音会话、Agent 对话、RTMP 推流、录制回放、隐私盾、30 分钟长跑。
- 用「内部 → 外部种子 → 公开链接」三阶段放量，避免未验证问题扩散。
- 每个 TestFlight 构建附带「测试内容说明」（What to Test），反馈统一走 GitHub Issues（模板已含诊断日志要求）。

App 不使用 iPhone 相机（画面来自眼镜帧），因此不申请相机权限；需要蓝牙、麦克风、相册写入与本地网络权限。

## 2. 前置条件

| 项 | 要求 | 现状 |
| --- | --- | --- |
| Apple Developer Program | 付费账号，Team ID `FYWDVBBN6N` | 项目已配置 |
| Bundle ID | `com.lunflux.hyper-meta-ai` | 已在工程中 |
| App Store Connect | 创建 App 记录（见第 4 节） | 待执行 |
| 签名 | 本机 Xcode 自动签名（Apple Development + Distribution） | 本地可签；CI 未配置证书 |
| 真机 | ≥3 台 iPhone（覆盖 iOS 17 / 18 / 最新），Ray-Ban Meta 眼镜 | 按基线执行 |
| 推流目标 | 自建 MediaMTX/nginx-rtmp + 至少 1 个真实平台账号 | 按基线执行 |

> 注意：`.github/workflows/release.yml` 产出的是 `CODE_SIGNING_ALLOWED=NO` 的**未签名** archive，
> 仅用于 GitHub Release 侧载，**不能**上传 TestFlight。TestFlight 必须用真签名构建。

## 3. 本地构建与导出

### 3.1 归档（真签名）

每次上传前递增 `CURRENT_PROJECT_VERSION`（必须大于 App Store Connect 上已有构建号，否则被拒）。

```bash
xcodebuild archive \
  -project HyperMetaAI.xcodeproj \
  -scheme HyperMetaAI \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "build/TestFlight/HyperMetaAI.xcarchive" \
  -derivedDataPath build/TestFlight/DerivedData \
  MARKETING_VERSION=1.4.0 \
  CURRENT_PROJECT_VERSION=<递增构建号>
```

### 3.2 导出（ExportOptions）

把以下内容保存为 `Scripts/ExportOptions-AppStore.plist`（`teamID` 非敏感信息）：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>upload</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>FYWDVBBN6N</string>
    <key>uploadSymbols</key>
    <true/>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>uploadBitcode</key>
    <false/>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
</dict>
</plist>
```

```bash
xcodebuild -exportArchive \
  -archivePath build/TestFlight/HyperMetaAI.xcarchive \
  -exportOptionsPlist Scripts/ExportOptions-AppStore.plist \
  -exportPath build/TestFlight/export
```

### 3.3 上传

三选一：

1. Xcode Organizer → Distribute App → App Store Connect（最直观）。
2. Transporter 拖入 `build/TestFlight/export/HyperMetaAI.ipa`。
3. 命令行（需 App Store Connect API Key，`.p8` 放 `~/.private_keys/AuthKey_<KEY_ID>.p8`）：

```bash
xcrun altool --upload-app \
  -f build/TestFlight/export/HyperMetaAI.ipa \
  -t ios \
  --apiKey <KEY_ID> \
  --apiIssuer <ISSUER_ID>
```

上传后构建在 App Store Connect「TestFlight」页处理，一般 1 小时左右可用。

## 4. App Store Connect 配置

1. 创建 App 记录：平台 iOS、名称 Hyper Meta AI、主要语言中文（简体）、Bundle ID `com.lunflux.hyper-meta-ai`。
2. TestFlight → 「App 内测试」（Internal Testing）：添加开发/测试成员（上限 100 人，无需 Beta 审核，自动接受）。
3. 外部测试（External Testing）：
   - 首次构建需 Beta App Review（同版本号后续构建无需重复审核）；审核材料复用 App Store 审核备注（见 `docs/app-store-release-plan.md` 第 5 节）。
   - 外部测试者上限 10,000 人/年（滚动 365 天）；构建有效期 90 天。
4. 加密合规问卷（Export Compliance）：App 仅使用系统标准 TLS（HTTPS/WSS）与用户自配端点通信，无自定义加密，
   如实选择「否」并走豁免（ITAR 类标准加密豁免）。如后续引入自有加密算法需重新评估。
5. 每个构建填写「What to Test」：

```
1.4.0 测试重点：
1) 眼镜连接与会话（单击打断/恢复、长按结束）；
2) Agent 中心：OpenClaw / Hermes / 自定义 Agent 对话与工具调用（需自配端点）；
3) 实时语音（qwen-audio-agent 网关，需电脑端运行）；
4) RTMP 直播：主路 + 多目的地、自适应质量、断线重连、录制与标记回放、隐私盾；
5) 直播场景理解（标题建议 / 存入 Agent 记忆）；
6) 已知限制：无眼镜时无法验证镜头画面相关流程。
反馈请附带「设置 → 诊断日志」导出的 .log 文件。
```

## 5. 分阶段测试方案

| 阶段 | 对象 | 放行门禁 | 时长 |
| --- | --- | --- | --- |
| 1. 内部组 | 开发者/核心测试成员（≤100 人） | 无（先自测冒烟：连接、推流、录制各一次） | 1-2 天 |
| 2. 外部-种子用户 | 封闭测试组（5-20 名早期用户） | 内部组通过 `docs/device-regression-baseline.md` 第 1-7 组 + 第 8 组（30 分钟长跑）≥1 次，执行记录表（第 9 节）已填写 | ≥7 天 |
| 3. 公开链接 | 任意 Apple ID（上限 10,000/年） | 种子用户无阻断性反馈；崩溃率无异常 | 直到提审 |

种子用户聚焦：眼镜连接、语音会话、Agent 对话、直播推流与隐私盾、录制回放。每阶段结束按 Issue 模板汇总
（含诊断日志），阻断性问题（崩溃、数据泄露、无法连接）必须清零才进入下一阶段。

## 6. 反馈渠道与迭代节奏

- 反馈统一入口：GitHub Issues（`bug_report.md` / `feature_request.md` 模板，含诊断日志要求）；README 与 TestFlight 测试说明中放同一入口。
- 崩溃监控：`uploadSymbols=true` 上传 dSYM 后，App Store Connect → Xcode Organizer 可看崩溃符号化。
- 节奏建议：周一内部构建 → 周三外部组 → 周五汇总评估；同版本号修复构建无需重新 Beta 审核，版本号变更需重新审核。
- 每个构建保留「What to Test」与已知问题清单，避免测试者重复报告已知项。

## 7. 可选：CI 自动上传（暂不启用）

工作流文件已就绪：`.github/workflows/testflight.yml`（仅 `workflow_dispatch` 手动触发，不影响 push/PR 流程）。
启用前先在 GitHub 仓库配置 Secrets：

- `DISTRIBUTION_CERT_BASE64`：Distribution 证书 `.p12` 的 base64。
- `DISTRIBUTION_CERT_PASSWORD`：证书密码。
- `ASC_API_KEY_ID` / `ASC_API_ISSUER_ID` / `ASC_API_KEY`：App Store Connect API Key（`.p8` 内容）。

流程：checkout → 导入证书（`apple-actions/import-codesigning-certs`）→ `xcodebuild archive`（Distribution 签名）→
`exportArchive`（复用 `Scripts/ExportOptions-AppStore.plist`）→ `altool` 上传。

要点：

- 凭据只放 GitHub Secrets，绝不提交仓库；启用前先在本地跑通第 3 节手动流程。
- 现有 `release.yml` 保持未签名 GitHub Release 不变，两者互不影响。

## 8. 放行 App Store 的标准

- 内部组：基线第 1-7 组全过，第 8 组（30 分钟长跑）≥1 次通过。
- 外部组：≥5 名种子用户、≥7 天、无阻断性反馈；无隐私相关投诉。
- 文档复核：权限文案、隐私政策、营养标签与 `docs/privacy-data-flow.md` 一致。
- 满足上述条件后执行 `docs/app-store-release-plan.md`。
