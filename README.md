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
- **工程与发布**：CI（模拟器测试 / 仓库检查 / 发布 / TestFlight 手动上传）、`CHANGELOG.md`、`CONTRIBUTING.md`、Issue 模板、兼容性/安装/故障排查文档；发布计划见 `docs/testflight-plan.md`（TestFlight 分阶段测试）与 `docs/app-store-release-plan.md`（App Store 提审），提审素材草稿见 `docs/app-store-metadata.md`。
- **隐私与文档**：发布级隐私/权限/数据流说明（`docs/privacy-data-flow.md`）、公开隐私政策草稿（`docs/privacy-policy-zh.md` / `docs/privacy-policy-en.md`）与真机回归基线（`docs/device-regression-baseline.md`）。
- **Live Streaming 2.0**：增强采集、编码、网络恢复、多平台并行推流、录制和直播中的 AI 辅助。RTMP 推流支持直播场景预设（目的地 + 码率 + 自适应开关一键保存/切换）、自适应质量（默认开启，码率 + 分辨率 + 帧率 + 音频码率同步调节）、断线自动重连（退避 2s→30s，最多 5 次）、推流中本地录制 + 精彩瞬间标记（MP4 存 App 文档目录）+ 录制回放（标记时间轴一键跳转）与直播场景理解（端侧识别视野场景，场景变化自动标记；场景 → 标题建议一键复制、场景一键存入 Agent 记忆）及推流诊断（会话性能指标 + 可分享报告 + 会话日志自动落盘 .log 文件，可查看 / 分享 / 删除）；支持多目的地并行推流（同一画面同时推到最多 4 个附加平台，独立状态展示，失败不拖累主路），弱网环境自动降质保流畅、恢复后逐级回升并自动恢复推流；推流页提供连接前实时预览（相机未就绪有引导与设置入口）；开播前合规清单 + 推流中隐私保护盾（一键隐藏画面）与直播控制面板（画质锁定 / 快捷标记 / 停止推流）。
- **眼镜拍照与图库**：拍摄照片自动本地存档（`Documents/CapturedPhotos`，上限 50 张滚动），图库网格查看 / 详情 / 分享 / 删除，拍摄预览可一键存入系统相册。

完整路线图见 [ROADMAP.md](ROADMAP.md)，英文版本见 [ROADMAP_EN.md](ROADMAP_EN.md)。

## Agent 集成

App 内「AI Agents」统一承载多类 Agent 交互，全部支持镜腿触发（单击打断 / 再单击恢复 / 长按结束，空闲时单击唤醒新回合）。回合结束后眼镜端会显示可点动作菜单（唤醒 / 拍照注入视野 / 新建会话），支持在镜片上直接操作：

- **OpenClaw**：连接自建 OpenClaw Gateway（Host / Port / Token）。
- **Hermes**：Nous Research Hermes Agent，OpenAI 兼容 `/v1/responses`，支持流式输出、工具生命周期与图片——服务端工具调用（`function_call` / `function_call_output`）流式解析后上报进度，工具执行结果在聊天页与语音页同步上镜片展示。
- **自定义 Agent**：任意 OpenAI 兼容 `/v1/chat/completions` 服务（本地 LLM、Hermes / OpenClaw 网关、自研 Agent 等），或自定义 WebSocket 事件流网关，Hub 中直接添加、测试连接并对话。
- **实时语音（Qwen Gateway）**：全双工语音默认使用 App 内置 Gateway，复用设置中保存的 DashScope API Key，无需在电脑上启动服务。也可切换到外部 qwen-audio-agent 网关：

  ```bash
  # 电脑端（与手机同一局域网）
  python realtime/app.py --host 0.0.0.0 --port 3101
  ```

  在 Agent 设置中将「网关来源」切换为「外部地址」，填写电脑局域网 IP 与端口（默认 3101）即可使用。
- **任务锁屏与灵动岛（Live Activity）**：后台任务进行中 / 审批待确认时，锁屏与灵动岛实时展示（任务数 + 最新步骤 + 审批倒计时），任务完成短暂展示结果后自动结束；设置页可关闭（`AgentLiveActivityManager`，纯映射 `AgentLiveActivityStateMapper` 可测；Widget 扩展渲染，文案由 App 生成与语言一致）。
- **统一输入入口（App Intents + Control Center）**：Siri 短语（如「跟 Hyper Meta AI 说话」「Talk to Hyper Meta AI」）、快捷指令、Spotlight、Action Button 与 Control Center（iOS 18+「开始 / 停止语音会话」控件）均可一键进入 / 退出语音会话；快捷指令可指定 Agent 大脑（Auto / Qwen / Hermes / OpenClaw）与直接指令文本（如「用 Hermes 查一下航班」）；另有「停止语音对话」与「查询任务进度」后台指令（Siri 直接播报，无需打开 App）；与眼镜 tap、App 内按钮共用同一套回合语义（单击打断 / 恢复、长按结束）。

语音会话支持**视野注入**：开启后可用眼镜拍照，把场景描述通过视觉模型（Dashscope / OpenRouter）发送给语音 Agent。聊天页同样支持拍照发送（手机相机按钮或镜片菜单 Vision），OpenClaw / Hermes 直接接收图片，自定义 Agent 按 OpenAI 多模态 content 数组发送；若「拍照注入视野」能力已被撤销，聊天页会提示先恢复再发送。聊天与语音会话的历史会自动落盘到「记录」页，再次进入自动恢复；Agent Hub 的「最近会话」是 OpenClaw / Hermes / 自定义 Agent / 实时语音的统一时间线，支持直接点开任意历史会话继续对话（语音会话点开即恢复对应记录），左滑可删除单条会话。
聊天页支持**视野连续追问**：发送照片后画面保留为当前会话的视野上下文，后续直接追问（如「这个多少钱？」）会自动携带同一张照片，无需重拍；输入栏显示「视野上下文」标记，可一键清除，设置页可关闭该行为。
视觉数据遵守**隐私生命周期**：画面帧仅保存在内存、不落盘，对话历史不保存图片；设置页「视觉隐私」可一键清除全部视觉数据（画面帧 + 取词/场景识别结果），语音会话显式结束时自动丢弃画面帧。
聊天页支持**端侧取词 OCR**：一键识别眼镜画面中的文字（Apple Vision，离线免费、无网络、无 API Key），识别结果同步显示到镜片、可朗读、可一键发给 Agent 继续追问（翻译 / 总结 / 提炼要点）或复制；结果页还提供**端侧一键翻译**（Apple Translation，iOS 18+，离线可用，自动判断语言方向：东亚文字 → 英文，其他 → 中文），译文可朗读。语音页同样提供取词入口——识别文字先朗读出来，再作为上下文转发给当前大脑（Qwen / Hermes / OpenClaw / 自定义 Agent），可直接追问「帮我翻译这段」。镜片回合菜单新增 **OCR / Translate** 动作：点「OCR」直接取词并朗读（全程无需掏手机），点「Translate」把最近一次取词结果发给当前 Agent 翻译并以语音播报。
聊天页与语音页的 OCR / 场景识别在**抓不到眼镜画面帧时自动回退到相册选图**（模拟器 / 无眼镜 / 未连接均可测试），同一套端侧 Apple Vision 管线继续执行。

同时支持**端侧场景与物体识别**：语音说「看看这是什么 / 识别场景 / 识别物体」或镜片「Scene」动作，对眼镜画面运行 Apple Vision 离线场景分类 + 动物识别 + 物体识别——结果上镜片、TTS 播报，语音页作为上下文转发给当前大脑、聊天页作为用户消息发出可继续追问（离线免费、无网络、无 API Key；iOS Vision 无通用物体检测请求，物体识别复用 ImageNet 分类法，剔除场景 / 动物词后即物体名）。

语音页支持**大脑模式**：默认 Qwen 原生实时语音；切换到 Hermes / OpenClaw / 自定义 Agent 后，Qwen 仅作听写（ASR），每段语音转写自动转发给所选大脑，回复通过 TTS 播报并写入历史；视野描述同样会转发给大脑作为上下文。自定义 Agent 大脑支持工具调用（语音播报 / 任务进度 / 拍照审批），具体配置可在语音页或设置页选择。

### 人机交互细节（免看屏、可打断、状态透明、失败可恢复）

- **回合状态透出**：镜片实时显示 聆听 / 思考 / 播报 / 打断 / 审批 五种状态图标；回合结束显示可点动作菜单（Talk / Repeat / Vision / New chat / Close），支持重听最后一条回复或任务结果；有后台任务进行时菜单动态出现「Task」项，进入任务中心（Progress / Cancel / Back），可一键播报进度或取消最近任务。
- **思考超时安抚**：大脑 8 秒无回复时自动语音提示；后台任务或 Hermes 工具执行中，提示语改为播报其最新状态（如"正在查询附近餐厅"），不再干等。
- **后台任务可观察**：任务进度（`task.progress` / `timeline.inline`）实时透出到镜片，语音页与聊天页一致；完成/失败/取消时触觉 + 眼镜结果摘要 + TTS 语音确认（受静默模式约束）。
- **统一任务呈现层**：任务进度卡 / 分步消息透出 / 终态回归（TTS + 镜片结果卡 + 触觉）/ 受理回执由 `AgentTaskLensPresenter` 统一执行，语音页与聊天页共用同一套决策（进度可见性、分步透出时机、播报窗口与静默模式），消除双入口行为漂移。
- **任务终态回归双入口**：后台任务完成/失败/取消时，语音页与聊天页均触发镜片结果卡 + TTS 播报 + 手机触觉（受静默模式约束）；任务创建即时回「收到」受理回执，迟到结果只入历史不播报。
- **任务三档状态**：任务列表以「等待中（已委派未开始）/ 进行中 / 已完成·失败·已取消」徽标 + 相对时间呈现，一眼区分任务所处阶段；语音页与聊天页共用同一任务列表组件，状态实时同步。
- **语音本地指令**：大脑模式下说"进度如何 / 还有多久 / 取消那个任务"会被本地拦截（大脑没有任务上下文），直接播报活动任务进度或向网关请求取消；"再说一遍 / 没听清"直接重听最近回复，"新会话"先落盘记录再清空——均不转发给大脑。
- **权限审批**：任务请求权限时镜片显示审批卡（任务摘要 + Allow / Deny / Later 按钮，显式导航点击提交决策），审批到达有 TTS 语音提醒（可在设置中关闭）、决策后镜片即时反馈（Done / Denied）、Later 收起不决策；手机端审批卡同步可用；60 秒未处理自动跳过（网关可稍后再问），避免会话卡死。
- **工具与权限**：统一 Tool Registry 声明 App 内可授权能力（拍照注入视野 / 代发消息 / 任务控制 / 语音播报），敏感工具需明确授权；支持**撤销 / 恢复**单个工具（已撤销的拍照能力即使已授权也不会执行），所有权限决策与撤销操作（允许 / 拒绝 / 稍后 / 超时跳过 / 撤销 / 恢复）写入本地审计日志（最多保留 50 条），设置页「最近审计」可查看与清空，镜片菜单「Audit」可查看最近一条审计。
- **权限分级模式**：设置页可选审批策略——始终询问（默认）/ 单次放行（同一权限首次批准后本会话自动放行）/ 会话内放行（本会话全部自动放行）/ 始终放行（仍受撤销策略约束）/ 全部拒绝；自动处理同样写入审计，网关失败自动回退为弹卡人工审批。
- **静默模式**：设置页可开启静默模式，抑制 Agent 主动打扰类播报（任务完成回归、审批到达、思考超时、提醒到点）；直接回复与本地指令即时反馈仍正常播报，镜片结果卡与手机触觉始终保留。
- **镜片快捷指令**：设置页可配置常用指令（标题 + 指令内容，最多 8 条），语音页 / 聊天页回合结束菜单新增「Shortcuts」子菜单，镜片上一键触发（大脑模式转发 / 原生模式直接发送）。
- **长期记忆**：设置页维护长期记忆条目（最多 20 条，可增删/清空），开启后随 Hermes / 自定义 Agent 请求以 system 指令注入，让 Agent 跨会话记住你的偏好（OpenClaw 协议暂不支持注入）。语音中说「帮我记住 X」直接存入并播报确认；会话结束时自动从转写提炼「我喜欢… / 我住在…」等陈述候选（最多 10 条），在设置页审阅后采纳。
- **命名清单（前端自有工具）**：购物单 / 待办等用户命名清单由前台直接维护、不占 Agent 会话——语音说「把牛奶加到购物单」「购物单里有什么」「清空购物单」即可添加 / 查询 / 删除 / 清空并立即播报确认；设置页可新建清单、添加与删除条目；自定义 Agent 可通过 `list.manage` 工具（`action=query/add/remove/clear`，`list=清单名`，`item=条目`）读写清单，无需授权。
- **本地提醒**：语音直接设置本地提醒（「十分钟后提醒我喝水」「明天早上八点提醒我开会」），本地解析相对 / 绝对时间、不占后台 Agent 会话，到点由系统本地通知触发；支持**周期提醒**（「每天八点提醒我吃药」「每周三下午三点提醒我汇报」），到点重复通知；支持「取消提醒 / 清空提醒」「有什么提醒」语音管理，设置页可查看（周期徽标）、左滑删除（同步取消通知）与清空全部；**App 在前台时到点直接镜片结果卡 + TTS 播报，系统横幅兜底**。
- **会话记忆**：设置页可分别关闭语音 / 聊天会话记忆（进入语音页或聊天页不再自动恢复上次会话，Hub 明确点开的历史仍恢复），并支持一键清除全部实时语音会话记录（带确认）。
- **自定义 Agent 协议**：双传输协议接入——HTTP 走 OpenAI 兼容 `/v1/chat/completions`（SSE 流式），WebSocket 走事件流协议（`chat` / `delta` / `done` / `tool_call` / `tool_result` / `error` / `ping`，适合自有网关）；配置存储（名称 / 协议 / 地址 / API Key / 模型 / 工具定义）与连接测试、Hub 自定义 Agent 列表（长按编辑 / 删除，配置有效即在线）、聊天页流式对话（支持眼镜拍照多模态发送、打断、TTS 播报），历史落盘「记录」并进入 Hub 最近会话统一时间线。
- **自定义 Agent 工具调用**：配置可选填 OpenAI 格式工具声明 JSON（function calling），请求自动携带 `tools`；流式解析 `tool_calls` 增量（名称/参数分片），Agent 调用工具时聊天页显示「正在使用工具 X」进度，与 Hermes 一致。
- **自定义 Agent 多轮上下文**：聊天页把历史消息（最近 20 轮，图片/空文本除外）随请求发送，Agent 具备会话内记忆；新建对话即清空上下文。
- **自定义 Agent 本地工具执行**：收到完整 `tool_calls` 后自动执行本地工具（`voice.reply` 眼镜播报、`task.control` 任务进度摘要，工具名含注册 ID 即匹配），结果以 `tool` 消息回传并继续生成；工具调用轮数上限 4 轮防失控，未启用的工具返回说明文本。
- **端侧视觉工具**：`vision.ocr`（取词）、`vision.scene`（场景识别）与 `vision.objects`（物体识别）注册为可发现工具——自定义 Agent / Hermes / 语音转发大脑可直接调用，在 App 最近一帧画面上用 Apple Vision 离线执行（免费、无网络、无 API Key），结果回传 Agent 可继续追问；无画面帧时返回引导文案（先拍一张），无需授权（本地处理，不上云）。
- **OpenClaw 端侧视觉命令**：自建 OpenClaw 网关可直接调用 `vision.ocr` / `vision.scene` / `vision.objects` 命令（已广告进协议 commands），在眼镜画面上离线执行取词 / 场景识别 / 物体识别并返回文本；撤销「拍照」能力后返回 `REVOKED`。
- **自定义 Agent 敏感工具审批**：`vision.capture` 拍照注入视野走统一审批链——撤销中的工具直接拦截；调用前请求审批（镜片审批卡 Allow / Deny / Later，60 秒超时自动跳过），请求与决策（允许 / 拒绝 / 稍后 / 超时跳过）全部写入审计日志；批准后拍摄眼镜当前视野并展示到聊天记录。
- **自定义 Agent 历史归类**：语音页自定义 Agent 大脑的会话历史按配置 ID 落盘（`custom.<UUID>`），不同配置各自独立归类并进入 Hub 最近会话统一时间线；其余大脑（Qwen / Hermes / OpenClaw / Auto）统一归实时语音时间线。
- **工具结果上镜片**：聊天页自定义 Agent 执行工具后，非空执行结果实时透出到眼镜端显示（与任务结果一致），随后正常返回给 Agent 继续生成。
- **持续在场（Presence）**：语音页可开启持续在场模式——回合结束不退出，Agent 保持在场聆听；长按镜腿或说「结束对话 / 先不聊了」显式退出。开启后空闲不再自动结束会话（可在网关设置中另行调整）。
- **佩戴恢复提示**：会话因摘镜/折合意外结束后，眼镜重新连接时提示「单击恢复交互」，并在镜片给出恢复入口。
- **可打断**：说话即 barge-in 打断播报；单击镜腿打断大脑回复，打断期间迟到的回复只入历史不播报，恢复后可在菜单重听。
- **错误恢复**：网关不可达 / 语音不可用 / 静默超时 / 眼镜断开 / 未知错误五类分类，附明确恢复动作提示；网关自动重连并透出进度。
- **上手引导**：首次进入语音页展示镜腿手势引导卡（单击开始/打断、长按结束）。
- **诊断报告**：设置页「关于 → 诊断报告」一键生成 App / 系统 / Agent 设置 / 连接 / 工具与权限 / 审计 / 提醒的文本报告，支持复制与系统分享，便于真机排障；API Key / Token 一律掩码输出，不泄露原文。

### 真机联调清单

以下能力依赖真机 + 眼镜验证（模拟器无法覆盖）：

1. **网关连接**：默认内置模式需配置 DashScope API Key；外部模式下 Mac 与手机需在同一局域网并运行 `python realtime/app.py --host 0.0.0.0 --port 3101`，手机填写 Mac 局域网 IP 后语音页显示 connected。
2. **镜腿触发**：语音/聊天页保持打开，单击 = 打断/唤醒，再单击 = 恢复，长按 = 结束回合；空闲时单击应显示「已唤醒」横幅。
3. **眼镜端状态与菜单**：回合进行中镜片显示状态图标（聆听/思考/播报/打断）；长按结束后显示动作菜单（Talk / Vision / New chat / Close），点击与 back 手势应生效。
4. **视野注入**：语音页点相机按钮，拍到的画面描述应作为上下文进入会话。
5. **大脑模式**：语音页切换到 Hermes/OpenClaw 后，说话应只见转写、无 Qwen 语音回复，随后大脑回复经 TTS 播报；确认 `outputEnabled=false` 的 connect 载荷被网关正确接受。
6. **多会话**：Agent Hub「最近会话」点击旧会话应恢复对应历史；新建对话后回到 Hub 应出现新记录。
7. **多设备**：配多副眼镜时，Agent Hub 左上角眼镜图标可指定使用哪一副（持久化，自动选择为默认）。

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
- `testflight.yml`：手动触发上传 TestFlight（需配置签名与 App Store Connect API 密钥 Secrets，见 `docs/testflight-plan.md` 第 7 节）。

- `docs/testflight-plan.md`：TestFlight 分阶段测试（构建/导出/上传、内外部测试组、放行门禁与反馈渠道）。
- `docs/app-store-release-plan.md`：App Store 提审计划（签名、元数据、隐私合规、审核备注、分阶段发布与运营）。

## 许可证

本项目采用 [MIT License](LICENSE)。第三方 SDK、Agent 服务和模型按各自许可证及服务条款使用。
