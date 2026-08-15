# 贡献指南

## 环境

- Xcode 15+（iOS 17.0 SDK+），macOS 适配版本见 CI。
- 仓库含 Meta Wearables DAT 依赖与自建 Agent 服务示例；默认 scheme 为 `HyperMetaAI`。

## 开发流程

1. **分支**：从 `main` 拉分支，命名 `feat/xxx`、`fix/xxx`、`docs/xxx`。
2. **改动**：最小可验证；新能力按仓库惯例拆「纯逻辑（可测）+ 服务 + VM + UI + 本地化 + 文档」。
3. **测试**：所有纯逻辑必须有单元测试；改动后运行全量：
   ```sh
   xcodebuild test -project HyperMetaAI.xcodeproj -scheme HyperMetaAI \
     -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:HyperMetaAITests
   ```
4. **本地化**：`en.lproj` / `zh-Hans.lproj` 同步新增 key；key 命名 `模块.用途`（如 `rtmp.xxx`、`agent.xxx`）。
5. **文档**：功能落地同步更新 `README.md` 与 `ROADMAP.md`；涉及数据/权限更新 `docs/privacy-data-flow.md`。
6. **PR**：描述改动、验证结果与真机影响面；CI 全绿后合入。

## 规则

- 不提交凭据/密钥；密钥只走钥匙串与环境变量。
- 新增主 target 源文件需同步接线 `project.pbxproj`（4 处），并保持组归属正确。
- 行为类改动默认需要回归测试；涉及第三方协议（DAT / HaishinKit / Agent 协议）先记录兼容性与隐私影响（见 ROADMAP 更新规则）。

## Issue

- Bug：使用 `.github/ISSUE_TEMPLATE/bug_report.md` 模板（含复现步骤、日志、设备信息）。
- 功能：使用 `.github/ISSUE_TEMPLATE/feature_request.md` 模板（含动机与验收标准）。
