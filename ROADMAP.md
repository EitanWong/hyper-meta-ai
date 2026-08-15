# Hyper Meta AI Roadmap

路线图描述产品方向，不代表已经发布的功能或时间承诺。优先级会根据 Meta Wearables SDK、Apple 平台能力、真实设备测试和用户反馈持续调整。

## 产品原则

- **语音优先**：眼镜交互以低延迟、可打断和连续会话为核心。
- **Agent 开放**：不绑定单一 Agent，通过 Provider、Router 和 Tool Registry 支持多种实现。
- **原生协同**：持续关注 Apple Intelligence 与 Apple 原生 AI 能力，在隐私、延迟和设备兼容性满足要求时优先采用系统能力。
- **可控可观察**：相机、位置、网络、消息和自动化等能力都需要明确权限、确认和状态反馈。
- **真实设备优先**：模拟器用于自动化回归，关键体验以 Ray-Ban Meta 真机测试为准。

## Phase 0: Foundation

**状态：进行中**

- [x] 统一项目名称为 Hyper Meta AI。
- [x] 收敛到 iOS-only 的维护范围。
- [x] 建立 iOS simulator tests、文档检查和 tag release 流程。
- [ ] 重组 App Shell、会话状态和依赖注入边界。
- [ ] 建立统一的 Agent、Audio Session、Tool 和 Permission 协议。
- [x] 建立真实设备兼容性矩阵和诊断日志基线：`docs/setup-and-troubleshooting.md`（设备/平台/网络兼容矩阵）与 `docs/device-regression-baseline.md`（真机验收清单 + 执行记录表）。

## Phase 1: Voice Agent Core

**状态：核心完成**

- [x] 全双工语音会话和低延迟音频管线。
- [x] 统一唤醒词、按钮、Siri、耳机和手机输入入口：Siri 短语 / 快捷指令 / Spotlight / Action Button 一键进入语音会话（耳机经 Siri 短语间接到达）。
- [x] Control Center 语音会话控制组件（Widget 扩展，iOS 18+：开始 / 停止两个 Control，App Group 跨进程通信）。
- [x] Barge-in、打断恢复、流式 ASR 和流式 TTS。
- [x] 会话生命周期、网络切换、错误恢复和离线状态处理。
- [x] 首个稳定的 OpenClaw Agent Adapter。
- [x] 语音会话的隐私提示、权限确认和可观测状态。

## Phase 2: Agent Platform

**状态：进行中**

- [x] Hermes Agent Adapter。
- [x] 自定义 HTTP/WebSocket Agent 接入协议：HTTP 走 OpenAI 兼容 SSE；WebSocket 走事件流协议（chat / delta / done / tool_call / tool_result / error / ping），配置表单可选协议并做对应健康检查，聊天页统一路由，旧配置默认 HTTP 兼容解码。
- [x] Agent Router、模型选择、能力发现和故障转移。
- [x] 任务双轨交互：语音追问进度 / 请求取消（大脑模式本地拦截）。
- [x] 任务三档时间轴状态（等待中 / 进行中 / 已结束）。
- [x] 眼镜端任务菜单动作：有后台任务时镜片菜单出现「Task」，一键播报进度。
- [x] 聊天页任务列表：与语音页共用共享组件，状态实时同步。
- [x] 语音本地指令扩展：重听最近回复 / 开始新会话（大脑模式本地拦截）。
- [x] 眼镜端审批快捷动作：镜片审批卡 Allow / Deny 直接提交决策。
- [x] 审批体验增强：审批到达 TTS 语音提醒，Allow / Deny 决策后镜片即时反馈（Done / Denied）。
- [x] 审批卡「稍后处理」入口：镜片 Later 收起不发送决策（网关稍后再问）；审批语音提醒可配置开关。
- [x] 审批超时倒计时：审批卡出现时记录截止时间（`permissionExpiresAt`，随收起/决策/超时清除），手机审批卡每秒刷新显示「N 秒后自动跳过」，剩余 ≤10 秒变红；纯计算 `AgentPermissionCountdown`（向上取整 + 进度 0-1）独立可测。
- [x] 审批弹卡避让：会话忙碌（用户说话 / 网关或本地播报 / speaking / interrupted）时审批卡延迟到空闲再弹，超时计时同步暂停（`pausePermissionTimeout` / `resumePermissionTimeout`），避免打断正在进行的回合；thinking → approval 正常路径不延迟。
- [x] 语音结果追问链：任务完成带详细结果（timeline.inline）时记录为追问上下文，大脑转发模式下用户下一条语音（「展开第三条 / 再说细一点」）自动把最新任务结果前置给大脑（`followUpMessage`，600 字截断，`【任务结果】…【用户继续追问】…` 结构），连续追问可叠加；新任务结果覆盖旧结果，清任务 feed 时一并清空。
- [x] 个性化规则（USER.md 风格）：语音「以后汇报先说结论 / 从现在开始回复要简洁 / 规则：用中文回答」与设置页共同维护恒定行为约束（上限 10 条，区别于事实类记忆），随 Hermes / 自定义 Agent 请求注入 system（`AgentSystemPromptBuilder` 合并记忆+规则），语音转发大脑每条消息携带「我的规则」紧凑前缀（120 字截断、放不下时截断第一条保证携带），语音可查询 / 删除 / 清空；OpenClaw 协议暂不支持注入；诊断报告含规则数。
- [x] Hub 最近会话统一时间线：OpenClaw / Hermes / Qwen 语音会话同一列表，点击直接恢复对应会话。
- [x] Hub 时间线过滤与搜索：最近会话支持按 Agent 过滤（全部 / OpenClaw / Hermes / Qwen / 自定义，菜单只列实际存在的类别）与关键字搜索（标题 / 摘要，大小写不敏感），过滤逻辑 `AgentHubRecentFilter` 纯函数可测；无匹配时明确提示。
- [x] Hub 自定义 Agent 历史按配置名展示：自定义 Agent 会话在时间线第一行显示配置名（配置删除 / 空名回退记录标题），第二行显示「记录标题 · 日期」；内置 Agent 保持标题 + 日期。多个自定义配置并存时一眼区分归属，显示逻辑 `AgentHubRecentDisplay` 纯函数可测。
- [x] Hub 时间线搜索支持配置名命中：关键字搜索除标题 / 摘要外，自定义 Agent 记录额外按配置名匹配（大小写不敏感，`AgentHubRecentFilter.search` 增加 `configNames` 参数）；按「助手 / 生活 / custom 名称」即可定位对应配置的会话。
- [x] Tool Registry 雏形：统一登记 App 内可授权工具（拍照 / 代发消息 / 任务控制 / 语音播报），权限决策写入审计日志。
- [x] 最近审计展示：设置页列出审计记录（动作 / 工具 / 详情 / 相对时间），支持一键清空。
- [x] 撤销策略：工具列表支持撤销 / 恢复单个工具（持久化），撤销后的拍照能力在调用点被拦截，撤销 / 恢复写入审计。
- [x] 眼镜端审计入口：语音页 / 聊天页镜片菜单新增「Audit」，展示最近一条审计记录（工具 · 动作 · 详情 · 相对时间）。
- [x] 会话偏好与可控记忆：语音会话记忆开关（关闭后不自动恢复历史）+ 一键清除该 Agent 全部会话记录。
- [x] 聊天会话记忆：聊天页（OpenClaw / Hermes）历史恢复同样受开关控制，语音 / 聊天记忆可分别配置。
- [x] 聊天页视觉发送补齐：镜片菜单 Vision 在聊天页真正拍照发送（OpenClaw / Hermes 直接收图），并受撤销策略约束。
- [x] 视野连续追问：聊天页发送照片后保留为会话视野上下文，后续追问自动携带同一帧（OpenClaw / Hermes / 自定义 Agent 统一生效），输入栏可一键清除，设置页可关闭。
- [x] 语音页视野上下文携带：语音转发大脑（Hermes / OpenClaw / 自定义）时，开关开启且本会话有最近画面帧（拍照 / 取词 / 场景识别后保留）则自动携带同一帧，无需重拍；与聊天页共用 `AgentVisionContextPolicy` 决策，同一设置开关控制。
- [x] 端侧视野 OCR：聊天页 / 语音页「取词」一键识别眼镜画面文字（Apple Vision 准确模式，中英双语，离线免费）；结果同步上镜片、可朗读、可发给 Agent 追问或复制；语音页取词先朗读再作为上下文转发给当前大脑；无文字 / 抓帧失败均有提示。
- [x] 端侧翻译：OCR 结果页一键翻译（Apple Translation，iOS 18+，离线可用），自动判断语言方向（东亚文字 → 英文，其他 → 中文），译文可朗读；旧系统降级提示。
- [x] 端侧场景识别：语音「看看这是什么 / 识别场景」或镜片「Scene」动作，Apple Vision 离线场景分类 + 动物识别，结果上镜片、可朗读，语音页作为上下文转发给当前大脑、聊天页作为用户消息发出可继续追问。
- [x] 端侧物体识别：语音「识别物体 / 有什么东西」或镜片「Scene」动作（同一管线），Apple Vision 离线物体识别，结果并入总结播报（「还看到了水杯」）；`vision.objects` 注册进 Tool Registry（自定义 Agent / Hermes / 语音转发大脑可调用）并同步 OpenClaw 网关命令；iOS Vision 无通用物体检测请求（VNRecognizeObjectsRequest 仅 macOS），复用 ImageNet 分类法剔除场景 / 动物词后即物体名，纯函数 `objectCandidates` 可测。
- [x] 镜片 OCR / Translate Quick Actions：回合菜单新增「OCR」（取词并朗读）与「Translate」（翻译最近取词并语音播报）动作，语音页 / 聊天页通用；最近取词结果跨页复用。
- [x] 自定义 HTTP Agent 接入协议核心：OpenAI 兼容 /v1/chat/completions 流式客户端（配置存储 + SSE 解析 + 健康检查 + 错误透出）。
- [x] 自定义 Agent Hub 接入：配置表单（添加 / 编辑 / 删除 + 连接测试）、Hub 列表入口、聊天页 SSE 流式对话（含图片多模态发送与打断）、最近会话统一时间线归类与恢复。
- [x] 自定义 Agent 工具调用：配置支持 OpenAI 工具声明 JSON（function calling），请求携带 tools，流式解析 tool_calls 增量并上报工具进度（与 Hermes 对齐）。
- [x] 自定义 Agent 多轮上下文：聊天页携带最近 20 轮历史（图片/空文本除外）随请求发送，新建对话即重置上下文。
- [x] 自定义 Agent 本地工具执行闭环：自动多轮循环（tool_calls 累积 → 本地执行 → tool 结果回传 → 继续生成），支持 voice.reply 播报与 task.control 进度摘要，轮数上限 4。
- [x] Hermes 工具生命周期可视化：解析 /v1/responses 流式与批量 JSON 的 function_call / function_call_output（嵌套与扁平兼容），工具进度上报修复嵌套 item 解析，工具执行结果上镜片（聊天页 / 语音页）。
- [x] 自定义 Agent 敏感工具审批链：vision.capture 走镜片审批卡（Allow / Deny / Later + 60s 超时跳过），撤销拦截，请求与决策写入审计，批准后拍照并展示到聊天记录。
- [x] 自定义 Agent 纳入语音大脑模式：语音页 / 设置页可选自定义 Agent 大脑并指定配置，听写转发 + 工具调用 + TTS 播报（与 Hermes / OpenClaw 一致）。
- [x] 自定义 Agent 语音历史按配置 ID 归类：语音页自定义大脑历史独立落盘（custom.<UUID>）并进入 Hub 统一时间线，其余大脑统一归实时语音。
- [x] 聊天页工具执行结果上镜片：自定义 Agent 工具执行后，非空结果通过 AgentDisplayHub 透出到眼镜端显示。
- [x] 持续在场（Presence）模式：语音页开关，空闲不再自动结束会话，Agent 保持聆听；长按或语音指令「结束对话」显式退出。
- [x] 任务锁屏与灵动岛（Live Activity）：后台任务进行中 / 审批待确认实时展示在锁屏与灵动岛（任务数、最新步骤、审批倒计时、终态结果短暂展示后自动结束）；纯映射 `AgentLiveActivityStateMapper`（任务 / 审批 / 终态内容构造）可测，ActivityKit 调用全部容错（系统未授权 / 模拟器 / 开关关闭静默降级，XCTest 环境不触碰）；设置页开关（默认开启）；Widget 扩展新增 ActivityConfiguration 渲染（文案由 App 生成，与 App 语言一致）。
- [x] 佩戴恢复提示：摘镜/折合导致的会话意外结束后，眼镜重连时提示单击恢复交互并在镜片给出恢复入口。
- [x] 权限分级模式：设置页选择审批策略（始终询问 / 单次放行 / 会话内放行 / 始终放行 / 全部拒绝），自动处理写审计，网关失败回退弹卡。
- [x] 镜片快捷指令：设置页配置常用指令（最多 8 条），语音页 / 聊天页镜片菜单「Shortcuts」子菜单一键触发。
- [x] 长期记忆：设置页维护偏好/要点（最多 20 条），开启后随 Hermes / 自定义 Agent 请求注入 system 上下文，跨会话生效；语音「帮我记住 X」直接存入并播报确认，会话结束自动提炼「我喜欢…」等候选、设置页审阅采纳。
- [x] 记忆语音查询：语音「我记住了什么 / 我的记忆有哪些 / 有什么记忆」直接播报全部记忆条目（「、」连接，空时引导「帮我记住 X」），不转发大脑；与存入指令同一解析器（`AgentMemoryCommand`：remember / query）。
- [x] 前端自有工具（命名清单）：购物单 / 待办等用户命名清单由前台直接维护（语音添加 / 查询 / 删除 / 清空 + 设置页管理），不占后台 Agent 会话；自定义 Agent 可通过 list.manage 工具读写清单（无需授权）。
- [x] 本地提醒：语音直接设置本地提醒（「十分钟后提醒我喝水」「明天早上八点提醒我开会」），本地解析相对 / 绝对中文时间、授权后走 UNUserNotificationCenter 本地通知，不占后台 Agent 会话；支持语音取消 / 查询，设置页列表左滑删除（同步取消通知）与清空全部。
- [x] 提醒完成态（Reminder Completion）：设置页提醒行首圆环按钮一键标记完成——行内划线过渡 + 绿色对勾 + 成功触觉反馈，1.5 秒窗口内可点「撤销」恢复，到时移除存储并取消通知调度；语音 / 聊天 / Siri「完成提醒」「标记完成」直达（`AgentReminderCommand.complete` 解析 + `LocalToolIntentHandler` 执行，单条播报「已完成：xxx」、批量 / 全部「已完成 N 条提醒」、无匹配明确提示）；锁屏通知 Action「完成」与 Live Activity 完成按钮补齐镜片结果卡 + TTS 确认（与「稍后提醒」反馈一致）；`AgentReminderCompletion`（文案）纯逻辑可测。
- [x] 镜片提醒点选完成 / 删除（Lens Reminder Actions）：眼镜端 Reminders 子菜单点选提醒播报详情后，镜片显示「Done / Delete / Cancel」操作卡——点 Done 完成（移除 + 取消调度 + 播报「已完成：xxx」），点 Delete 删除（移除 + 取消调度 + 播报「已删除提醒：xxx」），Cancel 回主菜单；语音页与聊天页一致；`AgentReminderLensAction`（执行 + 文案，已移除返回 nil 防重复点按）纯逻辑可测，`AgentDisplayChoiceMapping.completeLabel` 可测。
- [x] 提醒前台播报：提醒到点 App 在前台时镜片结果卡 + TTS 播报（可随语音播报开关关闭），系统横幅兜底；非提醒通知照常横幅。
- [x] 镜片 Reminders 子菜单：有即将触发的提醒（周期提醒永远有效）时语音页 / 聊天页镜片菜单动态出现「Reminders」，子菜单列出最近 5 条（内容截断为按钮标签），选中后镜片结果卡 + TTS 播报 + 手机横幅，Back 返回主菜单；无提醒时镜片给出明确提示。
- [x] 镜片「Today」总览菜单（Lens Today Overview）：日程 / 提醒 / 进行中任务任一有内容时镜片主菜单动态出现「Today」（时钟图标，排在 Task 之后 Ask 之前）——选中一键播报今日安排（下一场日程 + 下一条提醒 + 进行中任务数，全空回退「一切就绪，暂无安排。」），镜片结果卡 + TTS + 手机横幅，语音页与聊天页一致；`AgentTodayOverviewBuilder`（栏目组装 / 空白过滤 / 全空回退）纯逻辑可测，菜单动态显隐 / 标题 / 图标可测。
- [x] 语音「今日安排」口令（Voice Today Overview Command）：直接说「今天有什么安排」「今日安排」「今天要做什么」「汇报今日安排」（中英关键词，保守匹配不吞普通对话）即本地组装并播报今日总览（镜片 Today 同一实现：下一场日程 + 提醒 + 任务，全空回退），不转发大脑、无网络依赖；`AgentLocalCommandParser` 关键词矩阵纯逻辑可测（命中 / 反例）。
- [x] 主页下拉刷新（Home Pull-to-Refresh）：主页「今日安排」双卡支持 Apple 原生下拉刷新手势（`.refreshable`）——重新拉取今日日程与提醒并即时更新，与信号驱动刷新（回前台 / 数据变更 / EventKit 外部变更）并行，双卡刷新逻辑收敛为单一 async 入口。
- [x] Siri「今日安排」直达（Today App Intent）：Siri / 快捷指令 / 自动化一键播报今日安排（`TodayAppIntent`，`openAppWhenRun = false`，本地组装、无需网络与 Agent）——复用镜片 Today 同一总览（静默拉取今天未结束日程不请求权限；提醒最近一条；任务取进行中 / 等待中，完成 / 失败 / 取消不参与），Siri 直接朗读，全空回退「一切就绪，暂无安排。」；App 在前台且眼镜连接时同步渲染镜片；`AgentTodayIntentBuilder`（栏目组装 / 活动任务过滤 / 全空回退）纯逻辑可测。
- [x] 镜片 + 语音「明天安排」总览（Tomorrow Overview）：主菜单「Today」后新增「Tomorrow」（明天有日程时动态出现）——一键播报明天下一场日程 + 场次数（>1 场补充「明天共 N 场日程」，全空回退「明天暂无安排。」）；语音口令「明天有什么安排」「明天要做什么」「汇报明天安排」等本地组装播报（不转发大脑），英文 `What's on my schedule tomorrow?` 优先于 Today 关键词匹配（更具体的时间词先命中）；`AgentCalendarDisplayMapping.upcomingTomorrow` / `tomorrowEventsForMenu`（静默拉取、未授权为空）与 `AgentTomorrowOverviewBuilder`（单场 / 多场计数 / 全天 / 全空回退）纯逻辑可测。
- [x] 镜片任务「选择取消」（Task Cancel Choice）：任务中心「Cancel」在多个活动任务时弹出编号选择卡（`showChoice` 同一选择交互：编号 + 标题截断 + Cancel 返回），选中按原始任务序号直达取消（语音页复用语音取消闭环话术，聊天页与取消最近任务同一反馈）；单个活动任务保持一键直接取消、无任务不响应；`AgentTaskCancelFlow`（0 / 1 / 多任务决策、上限 5 个、序号保持、标题截断 / 空标题容错）纯逻辑可测。
- [x] Siri「明天安排」直达（Tomorrow App Intent）：`TomorrowAppIntent`（`openAppWhenRun = false`，本地组装、无需网络与 Agent）Siri / 快捷指令 / 自动化一键播报明天日程（下一场 + 场次数，全空回退「明天暂无安排。」），App 在前台且眼镜连接时同步渲染镜片；结果类型泛化为 `AgentDayOverviewIntentOutcome`（今天 / 明天共用）；`AgentTomorrowIntentBuilder`（单场 / 多场计数 / 全空回退）纯逻辑可测。
- [x] 镜片任务「进度逐条播报」（Task Progress Choice）：任务中心「Progress」在多个活动任务时弹出编号选择卡（与 Cancel 选择同一交互），选中即播报该任务进度（等待中 / 进行中步骤）；单个活动任务保持一键汇总播报；选择流逻辑泛化为 `AgentTaskChoiceFlow`（Cancel / Progress 共用：0 / 1 / 多任务决策、上限 5、序号保持、标题截断 / 空标题容错），`taskProgressSummary(for:)` 逐条与越界回退既有可测。
- [x] 静默模式：设置页开关，抑制主动打扰类播报（任务完成回归 / 审批到达 / 思考超时 / 提醒到点），直接回复与本地指令即时反馈不受影响，镜片卡片与手机触觉保留。
- [x] 诊断报告基线：设置页「诊断报告」一键生成 App / 系统 / Agent 设置（含记忆条数、清单数）/ 连接 / 工具权限 / 审计与提醒的文本报告，支持复制与系统分享；API Key / Token 一律掩码，不落原文。
- [x] 聊天页任务透出：后台任务完成/失败/取消在聊天页同样触发镜片结果卡 + TTS 播报 + 手机触觉（尊重静默模式与播报窗口），受理回执同步播报；任务进行中进度与分步消息（`runningTaskCount` / `taskMessage`）实时透出镜片，与语音页一致；触觉映射抽为纯逻辑 `AgentDisplayResultMapping.haptic` 供双入口共用。
- [x] 周期提醒：语音设置每天 / 每周重复提醒（「每天八点提醒我吃药」「每周三下午三点提醒我汇报」，支持周X / 礼拜X / 星期X），时间已过自动顺延到下一次触发，通知按系统重复日历触发；设置页显示周期徽标。
- [x] 眼镜端任务中心子菜单：进度播报 / 取消最近任务 / 返回。
- [x] 多任务语音点名：支持「任务二进度 / 取消第三个任务 / 停掉任务十」等序号指令（中文数字与阿拉伯数字，1-19），越界给出明确提示；取消时按序号点名对应任务。
- [x] 镜片 Ask 追问动作：有任务结果追问上下文时镜片菜单动态出现「Ask」，一键把任务结果上下文 + 追问转发给当前大脑（语音页）或自动发送（聊天页），无上下文时镜片提示；与语音追问链共用同一上下文（600 字截断）。
- [x] 聊天页任务指令本地拦截：聊天页输入「任务二进度 / 取消第三个任务」同样本地处理（进度摘要播报、按序号取消、越界提示），不发给大脑；回复保留在对话记录并可播报；与语音页共用 `AgentTaskCommandResponseBuilder`（语音页重构为同一实现）。
- [x] 语音页镜片「New chat」：语音页菜单新增 New chat（与聊天页一致），一键开始新会话（记忆提炼、落盘当前会话、清空转写与任务）；与语音指令「开始新会话」同一实现。
- [x] 镜片 Prefs 子菜单：有长期记忆或个性化规则时语音页 / 聊天页镜片菜单动态出现「Prefs」，子菜单混合列出最近 6 条（图标区分记忆/规则，按钮标签内容截断），选中后镜片结果卡 + TTS 播报（带「记忆：/规则：」前缀）+ 手机横幅，Back 返回；无内容时镜片明确提示。
- [x] 镜片 Lists 子菜单：有用户命名清单（购物单 / 待办）时语音页 / 聊天页镜片菜单动态出现「Lists」，子菜单列出最近 5 个清单（按钮标签 = 清单名截断），选中即播报条目内容（空清单播报「名称（空）」）+ 镜片结果卡 + 手机横幅，Back 返回；无清单时镜片引导「说『把牛奶加到购物单』即可创建」。清单查看补全「语音查询 / 设置页列表」之外的眼镜直查入口。
- [x] 清单序号语音点名：语音「第 2 个清单里有什么 / 第二个清单 / 清单三」（中文数字与阿拉伯数字，1-19）按最近更新顺序点名播报对应清单内容（空清单播报「名称还是空的」），越界提示当前清单数量；「第 X 个清单」整体解析不回溯，与镜片 Lists 子菜单同一排序基准。
- [x] 聊天页清单指令本地拦截：聊天页输入「把牛奶加到购物单 / 购物单里有什么 / 第 2 个清单 / 清空购物单」同样本地处理（添加 / 查询 / 序号点名 / 删除 / 清空），不发给大脑；回复作为 assistant 消息保留在对话记录并可播报；与语音页共用 `AgentListResponseText` 纯构造（消息文本双入口一致），镜片结果卡同步展示。
- [x] 清单条目逐条播报：镜片 Lists 子菜单选中清单后，条目 >3 条时进入「逐条听」子菜单（按钮标签 = 序号 + 条目截断，单屏最多 8 条），选中播报「清单名第 N 条：内容」+ 镜片结果卡 + 手机横幅，Back 返回；小清单（≤3 条）保持整体播报低摩擦。
- [x] 清单单条语音点名：「购物单第 2 条是什么 / 购物单第二条」本地拦截播报该条内容（与镜片逐条播报共用 `agent.list.item.result` 话术），越界提示「第 N 条不存在，当前共 M 条」；名称须含清单关键词避免误吞普通对话，「第 X 条」整体解析超范围不回溯；语音页 / 聊天页双入口一致。
- [x] 清单重命名：设置页清单行新增「重命名」（铅笔按钮 + 弹窗，预填当前名，保存失败提示空名/重名）；语音 / 聊天页「把购物单改名为生活清单 / 待办改成周计划」（改名为 / 改名成 / 更名为 / 重命名为 / 改成 / 改为）本地拦截重命名并播报确认；`AgentListStore.renameList` 保留 id / 条目 / 更新时间不变，重名与空名拒绝。
- [x] 清单 × 条目双层组合点名：「第 2 个清单第 3 条是什么 / 第二个清单第三条」直接播报对应条目（各序号 1-19，整体解析不回溯）；清单越界 / 条目越界分别提示；任一序号超范围时降级为单层点名（按名单条 / 清单序号点名，最终都有明确播报而非转发大脑）；排序基准与镜片 Lists 子菜单一致。
- [x] Tool Registry、权限确认、操作审计和撤销策略（分解完成：Tool Registry 统一登记拍照 / 代发消息 / 任务控制 / 语音播报 / 清单管理 / OCR / 场景识别；权限分级模式 + 敏感工具审批链；撤销 / 恢复持久化并写审计；设置页审计列表 + 镜片 Audit 入口）。
- [x] Agent 会话、偏好和可控记忆（分解完成：语音 / 聊天历史恢复开关、一键清除会话记录、长期记忆存 / 查 / 注入、会话结束自动提炼记忆候选）。
- [x] 为不同 Agent 建立统一的音频、视觉和工具上下文协议（分解完成：任务生命周期呈现统一 `AgentTaskLensPresenter`；视觉上下文统一 `AgentVisionContextPolicy`（聊天页 + 语音页同一开关）；音频统一回合语义与大脑转发；工具统一 Tool Registry 登记与授权、执行闭环）。

## Phase 3: Vision, Context and Apple Intelligence

**状态：进行中**

- [x] 实时视觉上下文与语音会话融合。
- [x] OCR、翻译、物体/场景理解和连续追问。
- [ ] 评估并接入 Apple Intelligence 未来开放的原生 AI 能力。
- [ ] 根据设备与系统版本，探索端侧模型、Siri、App Intents 和系统级智能协同。
  - [x] 端侧模型首个落地：直播场景 AI（标题润色 / 场景分析）在未配置 Agent 网关时兜底 Apple Intelligence 端侧模型（Foundation Models，iOS 26+，离线、私密、数据不出设备）；可用性门控（开关 / 系统版本 / 模型就绪 / 语言支持）自动降级为原「未配置网关」提示，设置页开关（默认开启）持久化；结果弹层展示「端侧 AI」徽标；`LocalBrainService` / `LocalBrainResponder` 纯逻辑可测（回调语义 / 超时 / 异常 / 设置往返）。
  - [x] 内置网关（Built-in Gateway）：对齐 qwen-audio-agent v1.8.3 服务端核心——非阻塞工作受理（spawn_thinking 语义：受理立即返回、owner FIFO、每 owner 单在飞）、协调协议（qwen_audio_agent_protocol：state / mode / presentation 解析与规范化、围栏与花括号窗口回退、非终态最多重试 2 次、最终语音只来自 presentation.speech）、action-promise 响应守卫与实时响应生命周期、公告安全插入窗口（用户说话 / 回合挂起 / 音频排队时暂缓播报）；「问 Lucky」单轮问答改走内置网关协调执行（协议提示词 + 重试 + 最终语音抽取，纯文本后端自动回退）；默认 AI 名称改为 Lucky；`AgentGatewayService` 后端执行与取消注入可测，协调解析 / 队列 / 守卫 / 窗口纯逻辑可测。
  - [x] App Schema 系统意图（iOS 26.2 / 27.0）：`@AppIntent(schema: .assistant.activate)` 把 Lucky 语音会话注册为系统级「激活语音助手」意图（iPhone 侧键 / Siri AI 可直达，唤醒 + 请求语音会话同一语义）；reminders 域接入 Apple Intelligence——`@AppEntity(schema:)` 清单 / 提醒 / 分组 / 位置触发实体 + `listType` / `locationTriggerEvent` 枚举（严格按 schema 校验：必填属性 / 可选性 / `DateComponents` / `Set<String>` / `Calendar.RecurrenceRule` / `CLPlacemark` 全对齐），`@AppIntent(schema: .reminders.createReminder)` / `.createList` 直接写 `AgentReminderStore` / `AgentListStore`（重复规则映射 daily / weekly、备注 / 标签 / 链接并入提醒内容、未给时间默认 1 小时后、调度系统通知），成功 Siri 朗读确认、失败按空内容 / 重名 / 达上限分别话术；`ReminderSchemaService` / `ReminderListSchemaService` 存储与调度注入可测。
- [x] Apple 原生能力封装为可发现工具：端侧 OCR（vision.ocr）与场景识别（vision.scene）注册进 Tool Registry，自定义 Agent / Hermes / 语音转发大脑均可调用，在最近一帧上离线执行（免费、无 API Key），结果回传并可继续追问；无画面帧时返回引导文案。OpenClaw 网关同步支持 `vision.ocr` / `vision.scene` 命令（广告进 commands，撤销 vision.capture 后返回 REVOKED）。
- [x] 无眼镜/无画面帧回退：聊天页与语音页的端侧 OCR / 场景识别在抓不到眼镜帧时自动回退到相册选图，同一套端侧管线（Apple Vision 离线）继续执行；iOS 17 无端侧翻译时已有升级提示文案。
- [x] 视觉数据隐私与本地清理：画面帧仅内存持有、不落盘；设置页「视觉隐私」一键清除全部视觉数据（保留帧 + 取词/场景结果，广播事件让各视图即时丢弃），会话显式结束自动丢弃画面帧；对话历史不保存图片。
- [x] 针对眼镜交互完善可访问性、反馈音和状态提示。
- [x] 智能家居管家（HomeKit）：语音 / 聊天直接控制系统家庭配件——开灯 / 关灯 / 调亮度（相对 ±20）/ 调温 / 全屋动作（灯 / 开关分类、跳过门锁与未知类型）/ 状态查询 / 设备列表；保守解析防误吞（目标须含家居关键词），设备名 / 房间名 / 尾缀归一模糊匹配可多设备，`AgentHomeKitCommandParser` / `AgentHomeKitTargetMatcher` / `AgentHomeKitExecutor` 纯逻辑可测，HMHomeManager 走协议注入（Mock 测试）。
- [x] 眼镜 Display 主页 HUD（JARVIS 镜片主页）：镜片渲染时间 / 短日期 / 未读通知数 / HomeKit 设备状态摘要（开 / 关 / 温度 / 锁态，上限 3 行）+ 快捷动作按钮（唤醒 / 拍照识图 / 重听 / 新会话 / 关闭），语音 / 聊天眼镜菜单首项「Home」直达，外设中心预览卡 +「显示到镜片」；权限感知（通知 / HomeKit 未授权自动降级），`AgentDisplayHomeMapping` / `AgentDisplayHomeLoader` 纯逻辑可测。
- [x] 眼镜连接问候（Glasses Connect Greeting）：戴上眼镜时镜片问候卡 + 触觉 + TTS 语音摘要（日程 / 提醒 / 进行中任务 / 未读通知条数，全空回退）；策略门控（总开关 / 会话中不打扰 / 最小间隔 60s 防重连风暴），语音尊重静默模式；`StreamSessionViewModel.onDeviceAvailable` 新回调经 `AppSessionCoordinator` 挂接，设置页「眼镜连接问候」分区；`AgentConnectGreetingPolicy` / `AgentConnectGreetingBuilder` / `AgentConnectGreetingAssembler` 纯逻辑可测（数据源可注入 Mock）。
- [x] 眼镜端日历日程菜单（Glasses Calendar Menu）：镜片动作菜单「Calendar」动态入口（今天有未结束日程时出现，语音页 / 聊天页通用），子菜单短标签「15:00 评审」、点按播报单条日程（复用语音查询文案）、无日程 / 未授权明确提示、末尾 Back 返回；`AgentCalendarDisplayMapping` / `AgentCalendarDayRange.todayRange` 纯逻辑可测。
- [x] 眼镜主页 HUD 今明日程摘要（Home HUD Calendar Summary）：镜片 Home 主页在未读行后显示今明两天日程（今天优先、时间升序、最多 3 行，「今天 15:00 评审」/「明天 全天 出游」），日历未授权自动隐藏；`AgentDisplayHomeMapping.calendarLines` / `AgentDisplayHomeLoader` 纯逻辑可测。
- [x] 眼镜主页 HUD 任务与提醒摘要（Home HUD Task & Reminder Lines）：未读行前显示进行中任务（「任务：上传视频」，多个「等 N 项」）与下一条提醒（「提醒 25分钟后 吃药」，周期显示「每天 HH:mm」），无内容自动隐藏；`AgentDisplayHomeMapping.taskLine` / `reminderLine` 纯逻辑可测。
- [x] 对话记录去重统一（Records Dedup）：记录页与 Hub 时间线共用存储但继续同一对话会生成重叠记录，现 `ConversationStorage.saveConversation` 同 ID 覆盖更新、聊天页落盘复用来源记录 ID（`AgentConversationPersister.latestRecord` / `makeRecord(recordID:)`），同一对话始终一条记录；纯逻辑可测。
- [x] 「问 JARVIS」App Intent：Siri / 快捷指令 / 自动化后台单轮问答（`AgentAskAppIntent`，`openAppWhenRun = false`），可选大脑（自动 / Hermes / OpenClaw / 自定义），Auto 按任务型 / 问答路由；回复经 Siri 对话朗读（长文截断），眼镜连接且前台时同步渲染到镜片；`AgentAskIntentHandler`（空输入 / 超时 / 防重入）与 `AgentAskIntentFormatter` 纯逻辑可测。
- [x] Siri 短语直达：`HyperMetaAIShortcuts` 注册「问 JARVIS」AppShortcut（中英 4 短语，总数控制在 10 个上限内；「百科识别」与「快速识图」重叠故从快捷短语移除，Intent 保留仍可手动添加）；短语无参触发时 `$message.requestValue` 让 Siri 追问具体任务，问答结果直接朗读。
- [x] Siri 本地工具「日历」（Local Tools Calendar）：`LocalToolsAppIntent` 工具选项新增 `calendar`，复用 `AgentCalendarCommandParser` / `AgentCalendarExecutor`（与语音 / 聊天页同一套解析与话术——授权 / EventKit 读写 / 创建确认 / 查询汇总 / 失败与未授权反馈），Siri / 快捷指令 / 自动化后台离线创建与查询日程，回复文案与语音页完全一致；未识别指令明确提示（`tools.intent.calendar.unparseable` 中英各一），`LocalToolIntentHandler`（provider 可注入 Mock）与 `LocalToolIntentFormatter` 纯逻辑可测。
- [x] 设置页「日历」分区（Calendar Settings Section）：Agent 设置新增日历状态区（`AgentSettingsSection.calendar` 支持深链定位）——授权状态明确反馈（已授权 / 未授权 / 受限 / 尚未请求，绿 / 红 / 橙 / 灰着色），尚未请求一键就地授权，已拒绝 / 受限「前往系统设置」跳转，已授权无冗余动作；footer 说明日历在各入口用途；`AgentCalendarSettings` 状态文案与 `AgentCalendarSettingsAction` 动作决策纯逻辑可测。
- [x] 日程提醒通知（Calendar Event Alerts）：设置页日历分区新增「日程提醒」开关与提前量（5 / 10 / 15 / 30 分钟，默认关闭避免与系统日历提醒重复）——开启后为未来 7 天内最近的非全天日程按提前量排期本地通知（`UNCalendarNotificationTrigger`，触发时间晚于当前才排期，已进入提前窗口的交由 Live Activity 倒计时；单次最多 20 条避免占满系统配额），随日历同步（启动 / 回前台 / EventKit 变更）差量增删，关闭即清空；开关开启时若通知权限未确定则就地请求；`AgentCalendarEventNotifier`（窗口 / 提前量 / 排期上限 / 稳定去重 ID）与 `AgentCalendarNotificationSettings`（默认值 / 往返 / 非法值回退）纯逻辑可测，调度薄封装 `AgentCalendarNotificationScheduler`（XCTest 跳过）。 点按通知深链到设置页日历分区（`AgentCalendarNotificationAction` 分类 / userInfo / 深链决策纯逻辑可测）。

- [x] 设置页「近期日程」列表（Upcoming Events List）：日历分区下方展示未来 7 天日程（今天 / 明天 / 之后分组、时间升序、「15:00 标题」/「全天 标题」、单组 5 行 / 总量 10 行封顶），授权后自动拉取、未授权引导、加载中与空态明确反馈，日程通知点按深链落地即有内容可看；`AgentCalendarOverviewMapping`（分组 / 行文案 / 窗口过滤 / 截断）纯逻辑可测。

- [x] 日程详情卡（Event Detail Sheet）：近期日程行点按弹出原生半高 Sheet（标题 / 时间范围 / 日历来源 / 当前状态分档文案与图标着色，全天无状态），拖动指示器 +「完成」关闭；`AgentCalendarDetailMapping`（状态判定 / 文案 / 图标 / 组装）纯逻辑可测。- [x] 对话记录 Spotlight 系统搜索（Conversation Search）：「问 JARVIS」结果 / 语音历史 / 聊天历史接入 CoreSpotlight（标题 = 首条用户消息，描述 = 最后回复，按时间倒序，不过期），点按搜索结果经 `SpotlightDestination.conversation` → `AppNavigationDestination.conversation` 打开 Hub 并呈现 `ConversationDetailView`（与结果通知深链统一；`SpotlightIndexer.conversationMetadata` / 解析纯逻辑可测），记录删除后重建索引自动移除。

- [x] 日程详情卡「设为提醒」（Event Detail Remind Me）：详情卡「提醒我」菜单（5 / 10 / 15 / 30 分钟前，默认 10 分钟）一键把日程转成本地提醒（复用提醒存储 / 通知调度 / 倒计时 Live Activity），同源去重（标题 + 开始时间相同显示「已设置提醒」禁用态），提醒已满或日程临近弹窗明确反馈；`AgentCalendarReminderBridge`（提前量 / 去重 / 构建，触发时间已过返回 nil）纯逻辑可测。

- [x] 主页「今日日程」卡（Home Today Schedule Card）：注册后主页（默认 Tab）顶部今日日程信息卡——静默拉取今天未结束日程显示最近一条（「今天 15:00-16:00 产品评审」，全天「全天 出游」），无日程 / 未授权占位文案，点按深链到设置页日历分区（MainTabView 消费自动切 Tab）；`AgentHomeCalendarCardMapping`（授权分支 / 空态 / 最近一条 / 已结束排除）纯逻辑可测。- [x] 语音 / 聊天 / Siri「删除日程」（Delete Event Command）：创建 / 查询之外第三个能力——「把明天的评审删掉」「删除下午3点的会」解析（后缀 / 前缀动词，时间短语或日期范围词 / 日程语境词保守拦截，「取消」留给提醒指令），窗口内归一化双向包含匹配，唯一匹配才删除并明确反馈（「已删除：今天 15:00-16:00 产品评审。」），多个列出提示更具体、零个未找到、失败明确反馈；`AgentCalendarCommandParser` / `AgentCalendarDeleteMatcher` / `AgentCalendarExecutor`（Mock provider）纯逻辑可测。- [x] 对话详情继续追问（Conversation Follow-up）：对话记录详情页「继续追问」主按钮，以该对话最后一条助手回复为上下文打开语音页（`ConversationRecord.followUpContext` 提取纯逻辑可测；无可用回复时 `AgentTaskFollowUpCoordinator` 回退最近任务结果 / 会话上下文），语音「再展开说说」自动携带记录上下文给大脑，形成「查看记录 → 语音追问」闭环。

- [x] 主页「下次提醒」卡（Home Next Reminder Card）：与今日日程卡并排组成「今日安排」双卡（通用 `HomeInfoCard`：图标 + 标题 + 单行内容，占位弱化）——最近一条提醒单次相对时间（「25 分钟后」）、周期「每天 HH:mm」「每周 HH:mm」、无提醒占位，点按深链到设置页提醒分区；`AgentHomeReminderCardMapping`（最近一条 / 单次 / 周期 / 空态）纯逻辑可测。
- [x] 主页双卡数量徽标 + 提醒概览（Home Card Badges & Reminder Overview）：日程卡 / 提醒卡右上角数量徽标（今天未结束日程数、待触发提醒数，>99 显示 99+，空态不显示），信息密度与无障碍标签齐备；点提醒卡直接弹出提醒概览 Sheet（medium/large detents + 拖拽指示）——列表内行首圆环一键完成（划线过渡 + 触觉 + 撤销窗口，与设置页同一语义与交互）、左滑删除，操作后主页双卡即时刷新，右上角「管理全部」深链设置页提醒分区，空态深链保持原行为；`AgentHomeCalendarCardMapping.count` / `AgentHomeReminderCardMapping.count` 纯逻辑可测。
- [x] 主页今日日程概览（Home Calendar Overview Sheet）：点日程卡弹出今日日程列表（时间 + 标题，`AgentCalendarFormatter.eventLine` 复用）——左滑删除带确认对话框（复用 `AgentCalendarDetailDeleteAction` 确认 / 失败 / 成功文案与 EventKit 执行，成功触觉反馈 + 行移除 + 主页双卡即时刷新，失败明确提示），右上角「管理全部」深链设置页日历分区，空态 / 未授权显示引导文案；与提醒概览 Sheet 对称（同一 medium/large detents + 拖拽指示），空态深链保持原行为。
- [x] 主页日程详情闭环（Home Calendar Detail）：今日日程概览 Sheet 点按任一条弹出日程详情卡（复用设置页 `CalendarEventDetailSheet`：标题 / 时间 / 状态 / 日历来源，「提醒我」提前量菜单一键设本地提醒、「删除此日程」红色按钮 + 确认对话框）——详情卡内操作后概览列表与主页双卡即时刷新，主页 → 概览 → 详情三级导航与设置页完全一致。
- [x] 主页双卡自动刷新（Home Cards Auto Refresh）：任何入口（语音 / 设置页 / 通知 Action / 外部日历变更）改动日程或提醒后，主页「今日安排」双卡即时刷新——`AgentHomeCardRefreshCenter`（NotificationCenter 信号，幂等）在提醒存储写入（新增 / 删除 / 更新 / 清空）与日历创建 / 删除成功时广播，主页订阅信号并在回前台（scenePhase）、EventKit 外部变更（`EKEventStoreChanged`）时重新拉取，切回主页 Tab 亦触发；授权后无需重启立即看到日程；广播 / 触发点纯逻辑可测。
- [x] 日程详情卡「删除此日程」（Delete Event from Detail Card）：设置页近期日程行点按的详情卡新增红色删除入口（原生 confirmationDialog 确认，明确提示不可撤销）——确认后执行 EventKit 删除，成功关闭详情卡并刷新近期日程列表（主页双卡经刷新信号同步更新），失败弹窗明确提示；`AgentCalendarDetailDeleteAction`（确认文案 / 执行 / 失败判定，Mock provider）纯逻辑可测。
- [x] 删除歧义语音追问闭环（Ambiguous Delete Follow-up）：删除指令匹配多个日程时候选暂存并编号列出（「找到 2 个匹配日程：1. … 2. … 请回复序号或更具体的名称。」），下一句回复序号（阿拉伯 / 中文数字、「第 X 个 / X 号」）、更具体名称或「取消 / 算了」即完成删除 / 收窄候选 / 取消；名称仍歧义自动收窄再追问；无关消息不打断，新日历指令自动替换待选；聊天页 / 语音页 / Siri 三入口一致；`AgentCalendarDeletePromptBuilder` / `AgentCalendarDeleteSelectionParser` / `AgentCalendarDeleteSelectionCoordinator`（Mock provider）纯逻辑可测。
- [x] 删除歧义镜片按钮选择（Lens Choice Card）：歧义出现时镜片同步显示编号选项卡（`AgentDisplayHub.showChoice`，标题超长截断 + 末尾 Cancel，无眼镜静默降级），点镜片按钮直接删除 / 取消，与语音报序号 / 说名称并行；镜片回调按（标题 + 开始时间）定位，语音已消费后点选静默忽略不误删；`AgentDisplayChoiceMapping`（编号 / 截断 / 取消标签）与 Coordinator select / cancel 入口纯逻辑可测。
- [x] 镜片日程菜单点选删除闭环（Lens Calendar Delete Flow）：眼镜端「Calendar」菜单点选日程播报详情后，镜片显示「Delete / Cancel」确认卡——点 Delete 直接执行 EventKit 删除并播报结果（成功 / 失败明确提示），主页双卡同步刷新；Cancel 回主菜单；语音页与聊天页一致；`AgentDisplayChoiceMapping.deleteLabel` 与 `AgentCalendarDetailDeleteAction.deletedText` 纯逻辑可测。- [x] 设置页提醒「稍后提醒」滑动动作（Swipe to Snooze）：已到点的单次提醒左滑一键重排（+10 分钟，与锁屏通知 Action 同一实现与文案），重新调度后行内文案即时变为「10 分钟后」并伴随成功触觉反馈；周期提醒不显示该动作；`AgentReminderSnoozePolicy`（可稍后判定 / 重排计算）纯逻辑可测。- [x] 对话详情聊天页继续追问（Continue in Chat）：记录详情页「在聊天中继续」把该记录水合到对应 Agent 聊天页（`AgentConversationPersister.loadMessages(from:recordID:)` 按 ID 恢复、不再要求 Agent 标识一致，agent-ask 等记录也可载入；`ConversationChatKindResolver` 记录 → OpenClaw / Hermes / 自定义配置聊天映射纯逻辑可测），与语音「继续追问」并列；Hub / 记录页 / 系统深链入口一致。
- [x] 任务结果卡聊天追问（Ask in Chat）：语音页 / 聊天页任务卡长按「在聊天中追问」（仅已完成且有结果的任务，`AgentTaskFollowUpOffer.isEligible` 可测），聊天页就地载入任务结果上下文（共享会话注入 + `TaskFollowUpWrapGate` 首条消息一次性携带 `【任务结果】` 前缀，可测），语音页打开对应 Agent 聊天页继续交流。
- [x] 问 JARVIS 结果通知继续追问（Ask Result Follow-up）：后台问答结果通知新增「继续追问」Action，锁屏 / 通知中心一键带该条结果上下文打开语音页（`AgentAskFollowUpContextResolver` 从归档记录恢复上下文、`AgentAskResultNotificationActionParser` / `AgentAskResultNotificationActionHandler` 纯逻辑可测），正文点按保持结果详情深链。





- [x] 任务结果一键追问（Follow Up）：任务完成通知「追问」Action + 锁屏结果 Live Activity「追问」按钮，点按打开语音页并注入任务结果上下文（`AgentTaskFollowUpRestorer` 会话内存优先 / 快照回退取最近带结果已完成任务，`PersistedAgentTask.resultText` 持久化兼容旧数据；`QwenVoiceSession.restoreFollowUpContext` 截断 600 字；`VoiceAssistantRequest.followUpContext` 深链带入；`AgentTaskFollowUpTapStore` / `AgentTaskFollowUpCoordinator` 注入可测，跨进程监听 + 回前台兜底）。

- [x] 任务 Live Activity 锁屏控制按钮（Task Control Actions）：任务进行中锁屏任务卡「取消 / 加速」交互按钮（`Button(intent:)` 参数化 + App Group 请求标记，与提醒倒计时卡同一通道）；取消走既有网关取消指令，加速为新增自然语言催促指令（`QwenVoiceSession.requestTaskAcceleration`，与取消对称）；`AgentTaskControlTapStore` / `AgentTaskControlActionParser` / `AgentTaskControlCoordinator`（defaults / apply 注入）可测，`MainAppView` 跨进程监听 + 回前台兜底消费，应用后 TTS + 镜片确认。

- [x] 任务重试闭环（Retry）：失败任务本地重试——语音口令（「重试 / 再试一次 / 重新做 / retry / try again」等，无失败任务不拦截）与镜片任务中心「Retry」子菜单（有失败任务时动态出现，多个弹编号选择卡）双入口；重试优先重放任务原始触发文本（`QwenAgentTask.sourceText`，`sendText` 同步更新 `lastUserText` 保证任务事件前捕获，复跑任务继承同一来源），缺失时退化为自然语言重试指令；`AgentTaskCommand.retryLatest / retryTask(Int)`、`failedTasks / latestFailedTask / requestTaskRetry / requestTaskRetry(index:)`、解析器 `failedTaskCount` 与重试越界话术纯逻辑可测，语音页 / 聊天页回复 + 横幅 + TTS + 镜片结果卡一致。

- [x] 失败任务通知「重试」Action（Retry from Notification）：任务通知按状态拆分分类（完成 = 查看 / 追问 / 稍后提醒，失败 = 查看 / 重试 / 稍后提醒），巡检投递在 userInfo 携带 taskId + 触发文本（`AgentTaskNotificationUserInfo`），`PersistedAgentTask.sourceText` 持久化（旧快照兼容解码）；点按「重试」→ 会话持有任务时按 taskId 直接重试（重放原始口述，TTS + 镜片确认），App 重启后从持久化快照定位最近失败任务并带指令打开语音页；`AgentTaskRetryPlanner`（会话内 / 语音页 / 忽略三态决策，通知文本优先于快照）与 `AgentTaskRetryCoordinator`（session 注入可测）纯逻辑可测；稍后提醒重发沿用原分类。

- [x] 失败任务锁屏「重试」按钮（Retry from Live Activity）：任务失败结果卡按 `resultKind`（completed / failed / cancelled，旧活动 nil 兼容）渲染「重试」按钮（`AgentTaskRetryControlIntent` + App Group 标记，与「查看任务 / 追问」同一通道）；App 前台跨进程监听 + 回前台兜底消费后复用通知「重试」闭环——无 taskId 时 `AgentTaskRetryPlanner` 会话有失败任务重试最近一个，否则从持久化快照定位最近失败任务带指令打开语音页；`ContentState.resultKind` 映射（`AgentLiveActivityStateMapper.resultContent`）与 `AgentTaskRetryTapStore` / `AgentTaskRetryCoordinator.consumeIfNeeded`（defaults / apply 注入）可测。

- [x] 语音会话锁屏状态卡（Voice Session Live Activity）：语音会话活跃时锁屏 / 灵动岛展示实时状态（聆听 / 思考 / 回复 / 休眠 / 连接失败），并带「停止」按钮（`StopVoiceSessionControlIntent`，与 Control Center 同一跨进程通道）；优先级 审批 > 语音会话 > 提醒/日程倒计时 > 任务进度，会话结束自动回落；`AgentLiveActivityStateMapper.voiceContent`、`AgentVoiceLiveActivityStatus`（休眠 > 连接 > 播报 > 聆听 > 思考 文案决策，纯逻辑）与 `AgentLiveActivityManager` 优先级（语音压任务 / 审批压语音 / nil 回落）可测；设置页 Live Activity 开关统一控制。

- [x] 休眠态锁屏「唤醒」按钮（Wake from Live Activity）：语音会话休眠时锁屏卡显示「唤醒」+「停止」——「唤醒」经 `WakeVoiceSessionControlIntent`（`openAppWhenRun = true`）写 App Group 标记，App 前台消费后 `QwenVoiceSession.wake()` 恢复聆听并呈现语音页（会话不活跃时退化为新会话）；状态文案与阶段决策统一为 `AgentVoiceLiveActivityStatus.phase`（结构化 `voicePhase` 字段，扩展据此渲染按钮，旧活动 nil 兼容），`VoiceControlRequestStore` 支持 start / stop / wake 三态（未知原始值回退 stop）；`phase` 映射 / `text(for:)` 一致性 / store 往返 / router `.wake` 消费（wakeExecutor 注入可测）纯逻辑可测。

- [x] 语音会话波形动画（Voice Waveform）：锁屏卡与灵动岛按会话阶段渲染 7 条波形竖条——播报高幅快动、聆听中幅、思考低幅微动、休眠 / 连接 / 失败近乎静止；灵动岛展开区用 `TimelineView(.animation)` 持续波动（本地渲染不消耗 Live Activity 更新预算），锁屏卡静态（t=0 高度）配 `.animation` 平滑过渡；`AgentLiveActivityAttributes.VoiceWaveformPattern`（确定性高度序列：同 phase/t/seed 恒定、振幅与速度按阶段区分、值域 0.06-1.0）纯逻辑可测，扩展按 `voicePhase` 字段驱动渲染。

- [x] 任务通知「回复 JARVIS」文本输入（Reply from Notification）：任务完成 / 失败通知新增系统原生文本输入 Action（`UNTextInputNotificationAction`，锁屏 / 通知中心直接打字交给 JARVIS）——输入文本经 `AgentTaskNotificationActionParser` 解析为 `.reply(text:)`，Handler 去空白后经 `AgentTaskNotificationActionRouter.replyToJARVIS` 打开语音页并作为指令自动发送（本地指令由语音页照常拦截），空输入忽略；完成 / 失败分类各 4 个 Action（查看 / 追问或重试 / 稍后提醒 / 回复 JARVIS），中英文案键 3 个；解析 / 分类组装 / Handler 路由（Mock 注入）与真实 Router → 语音页指令通道（instruction 断言）纯逻辑可测。

- [x] 提醒通知「回复 JARVIS」文本输入（Reply from Reminder）：提醒通知分类新增同一系统原生文本输入 Action（文案键与任务通知共用，`AgentReminderNotificationAction.replyAction`）——锁屏点按「回复 JARVIS」直接打字交给 JARVIS（如「把这个提醒改到明天」「把牛奶加到购物单」），文本去空白后经 `AgentTaskNotificationActionRouter.replyToJARVIS` 打开语音页作为指令自动发送（本地指令照常拦截），空输入忽略；分类动作集抽为 `actions`（稍后提醒 / 完成 / 回复 JARVIS，register 与测试共用）；`replyText` 决策与动作集组装纯逻辑可测，任务与提醒两类通知统一「锁屏打字指挥 JARVIS」入口。

- [x] 问 JARVIS 结果通知「回复 JARVIS」文本输入（Reply from Ask Result）：后台问答结果通知新增同一系统原生文本输入 Action（`AgentAskResultNotificationCategory.replyAction`，文案键与任务 / 提醒共用）——锁屏直接打字追问 JARVIS（如「把这个提醒改到明天」「把牛奶加到购物单」），文本经 `AgentAskResultNotificationActionParser` 解析为 `.reply(text:)`（旧调用不传文本回退空字符串），Handler 去空白后经 `AgentAskResultNotificationActionRouter.replyToJARVIS` 打开语音页作为指令自动发送（本地指令照常拦截），空输入忽略；分类动作集扩为「继续追问 + 回复 JARVIS」；解析 / 分类组装 / Handler 路由（Mock 注入）与真实 Router → 语音页指令通道（instruction 断言）纯逻辑可测，任务 / 提醒 / 问 JARVIS 三类通知统一「锁屏打字指挥 JARVIS」入口。

- [x] 问 JARVIS 锁屏回复携带结果上下文（Reply Carries Ask Result）：「问 JARVIS」结果通知的锁屏回复与「继续追问」同一语义——`AgentAskResultNotificationActionRouter.replyToJARVIS(text:recordID:)` 经 `resolveContext`（测试注入闭包，默认从归档记录恢复）取该条结果上下文，`VoiceAssistantRouter` 同时携带 instruction + followUpContext 打开语音页；`QwenVoiceView` 先 `restoreFollowUpContext` 再发送初始指令，转发大脑时初始指令经 `QwenVoiceSession.followUpMessage` 按「继续追问」包装（无上下文原样透传，不影响普通初始指令 / 任务重试）；锁屏打字追问即上下文连续对话，Handler 记录 ID 透传（无记录时文本照常作为指令）。

- [x] 问 JARVIS 结果通知「重试」Action（Retry Ask Result）：结果通知新增「重试」按钮（分类动作集 = 继续追问 / 重试 / 回复 JARVIS）——通知 userInfo 携带原始问题与大脑（`AgentAskResultDeepLink.message / brain` 载荷构建解析纯逻辑可测），锁屏点按经 `AgentAskRetryCoordinator.retry` 重新执行同一问题单轮问答（`send` / `storage` / `notifier` / `appActive` 全注入可测）：成功归档到 Hub 时间线 + 镜片渲染完整回复，失败经镜片给出与 Siri 一致的明确文案（状态反馈）；随后按「App 不在前台 + 开关开启」投递结果通知（前台重试结果经镜片卡反馈不重复打扰）；`AgentAskResultNotificationActionHandler` 异步化（`.retry` 路由 message + brain，旧通知无原文防御性忽略）；Parser / Handler（Mock）/ 协调器闭环 / 通知载荷透传可测。

- [x] 提醒通知「明天提醒」Action（Remind Me Tomorrow）：提醒到点通知新增「明天提醒」按钮（动作集 = 稍后提醒 / 明天提醒 / 完成 / 回复 JARVIS）——锁屏一键把提醒重排到明天同一时刻（`AgentReminderNotificationAction.tomorrow` 日历日加法，保留 id / 文本 / 重复规则，跨月 / 年末正确，固定 UTC 日期构造可测），后台静默重排无需打开 App，镜片卡 + TTS 播报「明天同一时间提醒你」确认；`Outcome.tomorrow` 决策纯逻辑可测，锁屏 didReceive 与镜片 / 倒计时入口（`AgentReminderTapCoordinator.apply`）两个消费点同语义，动作集组装（4 Action 顺序 / tomorrow 无 foreground）可测。

- [x] 移除 Time Sensitive 能力（个人团队构建可用）：`com.apple.developer.usernotifications.time-sensitive` 个人团队无法签发（无论 Debug / Release 都会导致真机构建失败），Release / Debug 统一基础 entitlements（HealthKit + App Groups），删除专用 entitlements 文件；失败任务通知回落 `.active`，移除「失败任务紧急通知」二级开关；任务通知 Action / 分类 / 巡检闭环不变。

- [x] 问 JARVIS 结果归档与通知深链（Ask Result Archive + Deep Link）：后台成功回答自动归档到 Hub 时间线（独立 `agent-ask` 归类 + 过滤标签，可搜索 / 查看详情），结果通知携带记录 ID，点按直达结果详情（`AgentAskArchiver` 记录构建 / 仅成功落盘 / storage 注入可测，`AgentAskResultDeepLink` userInfo 构建 / 解析可测，`AppNavigationDestination.agentAskRecord` 经 Home → Hub 分级消费）。

- [x] 后台问答结果通知（Ask Result Notification）：Siri / 快捷指令后台「问 JARVIS」完成时以本地通知送达（回复截断 / 失败超时也提醒），仅 App 不在前台时投递（开关默认开）；`AgentAskResultPolicy` / `AgentAskResultSettings` / `AgentAskResultContent` 纯逻辑可测，`AgentAskResultCoordinator.notifyIfNeeded`（notifier 注入）接线可测，投递检查通知授权。

- [x] 管家快捷控制（Control Center 晨报 + Home Widget 语音按钮）：Control Center「播报晨报」一键触发今日晨报朗读 + 上镜片（App Group 标记通道 + 回前台消费，`AgentBriefingRequestStore` / `AgentBriefingControlCoordinator` 可注入可测）；Home Widget 小尺寸补语音会话开始 / 停止按钮（与中尺寸同 Intent）。
- [x] 晨报体验增强（Briefing Polish）：问候随时段自然变化——早上好 / 下午好 / 晚上好 / 夜深了（`AgentBriefingGreetingPeriod` 分段纯逻辑可测，沿用助手名与回退名）；日程栏开启时首条日程未来 24 小时内显示「下一场日程 X 分钟 / 小时后开始。」倒计时行（排在日程列表前，已开始 / 超 24 小时 / 栏目关闭时不显示）；`AgentBriefingContent.nextEventLine` 与 fullText 顺序纯逻辑可测。

- [x] 桌面小组件「下次日程」（Widget Next Event）：小 / 中尺寸与锁屏矩形配件展示未来 24 小时内最近一个非全天日程（`AgentCalendarCountdownPolicy.widgetMaxAhead`），中尺寸常驻「日历 + 时间 标题」行、小尺寸无提醒时以日程替代空态、矩形配件回落「下次日程」；`AgentWidgetSnapshot` 新增 `nextCalendarText` / `nextCalendarDetail`（`AgentWidgetCalendarFormatter` 时间文案纯逻辑可测，跟随 App 语言），刷新中心复用 `AgentCalendarCountdownCoordinator.lastFetchedEvents`（不请求权限、未授权为空），EventKit 监听 / 回前台 / 提醒与语音刷新点即时同步；扩展镜像字段 optional 兼容旧快照。

- [x] 日程倒计时 Live Activity（Calendar Countdown）：下一个即将开始的非全天日程在锁屏 / 灵动岛红色日历倒计时卡（系统计时器自动走秒），与提醒倒计时并存时「更早者优先」（下一个安排语义）；`AgentCalendarCountdownPolicy` / `AgentLiveActivityStateMapper.calendarContent` 纯逻辑可测，`AgentCalendarCountdownCoordinator.sync`（events / provider 注入）幂等，回前台与 `EKEventStoreChanged` 事件即时重算，未授权静默跳过。

- [x] 提醒倒计时卡锁屏交互按钮（Reminder Live Activity Actions）：倒计时卡「稍后提醒 / 完成」交互按钮（`Button(intent:)`，AppEnum 参数化 + App Group 请求标记，与审批 / 查看任务同一通道），App 前台消费应用到当前展示的提醒（snooze 延后 10 分钟 / complete 移除并取消通知）；`AgentReminderTapHandler`（纯逻辑：snooze 语义 / 目标选择 / 未知与无目标忽略 / 周期不受影响）与 `AgentReminderTapCoordinator`（defaults / apply 注入）可测。

- [x] 提醒倒计时 Live Activity（Reminder Countdown）：设置提醒后最近一条一次性提醒在锁屏 / 灵动岛显示倒计时（系统计时器自动走秒，到点本地通知接力）；`AgentReminderCountdownPolicy`（未来 6 小时内最近一条一次性提醒）纯逻辑可测，管理器缓存化（审批 > 倒计时 > 任务进度 > 结果卡优先级，回落可测）；提醒新增 / 取消 / 稍后提醒 / 完成 / 到点 / 回前台全部幂等重算。

- [x] 任务失败紧急通知（Time Sensitive）→ 已移除：个人团队无法签发该能力（真机构建失败），失败任务通知回落普通 `.active` 级别；保留任务完成 / 失败通知、快捷 Action 与巡检闭环。

- [x] Live Activity 审批按钮（Approval Live Activity Action）：审批待确认时锁屏 Live Activity 显示「批准 / 拒绝」交互按钮（`Button(intent:)`），经 App Group 请求标记 + `applicationDidBecomeActive` 消费提交当前审批决策（`QwenVoiceSession.respondToPermission`，一次性防重复）；扩展侧 `AgentApprovalControlIntent`（AppEnum 参数化）+ `AgentApprovalRequestStore`，主侧 `AgentApprovalTapStore.consume / consumeDecision`（可注入 defaults）纯逻辑可测；无待处理审批静默忽略，反馈走既有网关回发路径。

- [x] 任务 Live Activity 交互按钮（Live Activity Action）：任务终态时锁屏 Live Activity 显示「查看任务」交互按钮（iOS 17 `Button(intent:)`），点按经 App Group 请求标记 + `applicationDidBecomeActive` 消费深链 Agent Hub（一次性）；扩展侧 `AgentTaskViewControlIntent` / 请求标记与 Control Center 语音会话同一通道模式，主侧消费 `AgentTaskViewRequestStore.consume`（可注入 defaults）纯逻辑可测。

- [x] JARVIS URL 命令协议（URL Command Router）：`hypermetaai://` 深链扩展为完整命令集——`trigger`（手势触发，兼容既有协议）/ `ask`（后台单轮问答，结果上镜片 + 播报）/ `lens`（文本上镜片，可选播报）/ `briefing`（立即播报晨报）；`AgentURLCommandParser` 纯逻辑（命令矩阵 / brain 缺省与未知回退 / 空文本拒绝 / 百分号编码 / 未知 host 拒绝）、`AgentURLCommandRouter` 分发经 `AgentURLCommandExecuting` 协议注入（Mock 测试）；`onOpenURL` 统一路由，非 JARVIS 命令保留 SDK 兜底；TTS 尊重回复开关与静默模式。

- [x] 任务通知交互 Action（Task Notification Actions）：任务完成 / 失败通知带「查看结果」（深链打开 Agent Hub）与「10 分钟后提醒」（时间触发器重发，可多次）两个快捷 Action，分类随冷启动注册、投递挂分类、`AgentReminderNotificationDelegate.didReceive` 按分类分流；`AgentTaskNotificationActionParser` / `AgentTaskSnoozeBuilder` 纯逻辑，执行闭环经 `AgentTaskNotificationActionRouting` / `AgentTaskNotificationScheduling` 协议注入（Mock 测试）；`AppNavigationDestination.agentHub` 深链（主 Tab 回首页 → HomeView 消费弹出 Agent Hub）。

- [x] 后台任务巡检（Background Task Inspector）：任务状态变化持久化快照（`AgentTaskNotificationStore`），进后台提交 `BGAppRefreshTask`（`com.lunflux.hyper-meta-ai.task-inspect`），系统唤醒时对新进入终态（完成 / 失败）的任务推送本地通知（同一任务同一终态只通知一次、单次最多 3 条、倒序）；等待中 / 进行中 / 已取消不打扰；`AgentBackgroundTaskInspector` 纯决策（去重 / 封顶 / 排序 / 文案回退）、`AgentBackgroundTaskRunner` 经 `AgentBackgroundNotifying` 协议注入（Mock 测试）；`QwenVoiceSession` 三处变更点同步快照；设置页「后台任务通知」开关（默认开启）。

- [x] 专注模式联动（Focus Mode）：JARVIS 感知系统专注状态（`FocusStatusCenter`，授权后读取），专注中主动打扰自动避让——通知播报整体暂停（不写入已播报去重，专注结束后可被「有什么通知」汇总）、连接问候 / 提醒 / 任务完成等主动语音静音（镜片卡片保留）、显式询问回复不受影响；`AgentFocusPolicy` 纯决策（未知状态 fail-open）叠加进 `AgentQuietAnnouncementPolicy.shouldSpeak`（9 个主动播报点统一经 `shouldSpeakProactive()` 迁移），`AgentFocusProviding` 协议隔离系统状态（`SystemFocusService` 真实实现）；设置页「专注模式」分区（总开关 + 通知播报 / 主动语音分项 + 授权状态行），`AgentFocusSettings` 直连 UserDefaults 可注入测试。

- [x] JARVIS 通知播报管家（Notification Butler）：前台新通知按策略 TTS 摘要播报（关闭 / 语音会话中 / App 前台，尊重静默模式）+ 镜片结果卡 + 触觉反馈，已播报 ID 去重（上限 50）；语音 / 聊天「有什么通知 / 清空通知」本地拦截——`AgentNotificationCommandParser` 保守关键词解析、`AgentNotificationExecutor` 统一权限流转、`AgentNotificationSummarizer` 三级隐私（仅条数 / 标题 / 标题+正文截断）与内部时间倒序、`AgentNotificationInbox` 持久化去重，`SystemNotificationService` 走协议注入（Mock 测试）；iOS 无公开 API 取通知来源 App 名，汇总按内容呈现。
- [x] JARVIS 触发中心（Wearable Trigger Hub）：眼镜触发（镜腿会话状态 / 镜片 onTap / Mock captouch）× Apple 原生触发源（背部轻点 / 操作按钮 / Siri / 快捷指令 / `hypermetaai://trigger` URL / App 内演示）统一收敛到 `AgentWearableTriggerCenter` 同一路由与审计日志；同源同手势 0.8s 去抖防双触发，无活动会话时回合类手势返回「已忽略」；触发日志持久化（上限 50 条）并在外设中心展示；「触发 JARVIS」App Intent 动作参数化（唤醒 / 打断 / 恢复 / 结束回合 / 拍照识图 / 重听回复），重听经 NotificationCenter 双入口消费；`AgentWearableTriggerRouter` / `AgentWearableLogStore` / `AgentWearableLogFormatter` / `AgentWearableURLTrigger` 纯逻辑可测；研究结论沉淀于 `docs/MetaRaybanTriggers.md`。

## Phase 4: Streaming 2.0

**状态：核心完成（待真机回归验证）**

- [x] 可靠的 RTMP 推流核心和网络恢复策略。
  - [x] 自动重连（网络恢复策略）：断线 / 连接失败 / 推流中断后按退避间隔（2s → 4s → 8s → 16s → 30s，最多 5 次）自动重连并恢复推流；服务端明确拒绝（connectRejected / 推流名错误）不重试；同一断线的多个状态事件只调度一次；用户主动停止立即取消重连；重连等待中状态透出「第 N 次，M 秒后」，超限后报错停止；设置页开关（默认开启）+ 开关持久化；纯逻辑 `RTMPReconnectPolicy` 可测（退避序列、表长封顶、最大次数、空表、越界）。
- [x] 码率、分辨率、帧率和音频策略的动态调节。
  - [x] 自适应码率（动态码率调节）：推流中每 3 秒按丢帧率在 1/1.5/2/2.5/3/4 Mbps 档位间升降（丢帧率 > 5% 且冷却 ≥8s 降一档，零丢帧且冷却 ≥20s 升一档，升档比降档更保守），HaishinKit 推流中动态更新 `videoSettings.bitRate`；纯逻辑 `RTMPAdaptiveBitrateController` 可测（档位归一、冷却、阈值、上下界、空周期不动作）；设置页开关（默认开启）+ 统计区实时码率显示，开关与码率状态持久化；`onBitrateChanged` 回调供 UI 展示。
  - [x] 自适应质量（码率 + 分辨率 + 帧率动态调节）：质量档位表（4Mbps@504×504@30 → 1Mbps@288×288@15，共 6 档）同时调节码率、编码分辨率与帧率，弱网时整体降质、恢复后逐级回升；决策规则与码率自适应一致（丢帧率 > 5% 且冷却 ≥8s 降一档，零丢帧且冷却 ≥20s 升一档，空周期不动作）；帧率档位经独立入流节流静默丢帧（不进入丢帧统计，避免自激）；HaishinKit 推流中动态更新 `videoSettings.videoSize / bitRate / maximumFramesPerSecond`；纯逻辑 `RTMPAdaptiveQualityController` 可测（档位归一、初始档位、冷却、阈值、上下界、空周期、走底回升、空表安全）；「自适应码率」开关升级为「自适应质量」（设置键迁移兼容旧键），统计区新增实时画质档位显示（如 504×504@24）；`onQualityChanged` 回调供 UI 展示。
  - [x] 自适应音频码率（音频策略动态调节）：音频码率跟随质量档位同步调节（128/128/96/96/64/64 kbps 映射 6 档画质，弱网时控制总带宽并优先保住语音清晰度）；推流初始即写入 `AudioCodecSettings`，画质档位变化时经 `setAudioSettings` 动态更新，仅变化时更新；纯逻辑 `RTMPAudioBitratePolicy` 可测（默认映射、越界 clamp、自定义表、空表安全）；设置页开关（默认开启）+ 开关持久化；`onAudioBitrateChanged` 回调供 UI 展示。
- [x] 多平台、多目的地、直播场景配置和权限管理。
  - [x] 直播场景配置：命名场景把「目的地（平台 / RTMP URL）+ 推流参数（码率 / 自适应质量 / 自动重连 / 自适应音频）」打包保存（UserDefaults JSON，上限 10 个，按更新时间降序）；推流页场景 chips 一键应用，设置页场景管理（保存当前 / 点击应用 / 左滑重命名删除）；推流密钥保持在钥匙串不写入场景；纯逻辑 `RTMPScenarioStore` 可测（新增/更新去重、空名拒绝、上限、删除、重命名空名/重名拒绝、排序、持久化往返）。多目的地并行推流：设置页管理最多 4 个附加目的地（名称 + 完整 RTMP 地址，密钥内嵌 URL 路径，上限 4 个、重复地址拒绝、可单独停用），启用的目的地随主推流自动启动——`RTMPParallelStreamer` 每路一个 HaishinKit 连接/流（固定码率 1.5Mbps、独立连接与发布、失败单独上报不拖累主路），主路推流中把每帧拷贝分发到所有活跃目的地；推流页实时显示每路状态胶囊（推流中/连接中/失败）+ 聚合摘要；推流中可动态管理目的地：设置页新增/删除/停用/改地址即时作用到附加路（增删重建该路），失败胶囊点击重试（附加路失败后自动重试 1 次，策略 `RTMPParallelRetryPolicy` 可配）；纯逻辑 `RTMPDestinationStore`（增删改/去重/上限/停用）、`RTMPParallelSessionState`（各路状态机、聚合、全量成功、动态增删/重试）与 `RTMPParallelRetryPolicy` 可测。直播权限管理：开播前合规清单（内容使用权 / 评论管理 / 他人隐私三条，全部确认才能开播，可「记住选择」下次跳过，`RTMPGoLiveGate` 门控）；推流中隐私保护盾（一键隐藏画面——服务层停止发送/编码/录制/场景识别，画面黑屏提示，停止推流自动复位）；纯逻辑 `RTMPChecklistStore`（默认条目/全确认/持久化往返）、`RTMPGoLiveGate`（记住与确认组合）与 `RTMPPrivacyShield`（toggle）可测。
- [x] 直播预览、录制、事件标记和直播控制台。
  - [x] 直播预览：推流页有相机帧即显示实时预览（连接前 / 推流中一致），连接中在预览上叠加「正在连接」提示而不黑屏，相机未就绪（无权限 / 掉线）显示引导卡片 + 「打开设置」直达系统设置，相机启动中显示等待态，未推流时左上角「预览中」状态胶囊。
  - [x] 推流中本地录制、事件标记与录制回放：推流中一键录制（AVAssetWriter 实时编码 H.264 MP4，仅视频轨，帧时间戳自动归零基准），录制中「精彩瞬间」一键标记（相对录制开始计时，标签裁剪 16 字符、按时间排序）；停止推流自动结束录制并保存；设置页录制列表点击「回放」弹出回放面板（AVPlayer 播放 + 录制信息 + 标记时间轴横向滚动，点击标记 seek 跳转，无标记 / 文件缺失均有提示）；录制记录（时长 / 标记数 / 文件名）落盘（UserDefaults，上限 20 条）并在设置页展示、左滑删除；录制文件存 Documents/RTMPRecordings；纯逻辑 `RTMPRecordingNaming`（文件名 / 时长格式）、`RTMPMarkerTimeline`（标签裁剪 / 排序 / 空标签拒绝）、`RTMPRecordingStore`（排序 / 上限 / 删除 / 往返）、`RTMPRecordingPlayback`（文件定位 / 存在性 / 标记时间轴排序与进度夹取 0~1）可测。
  - [x] 推流中控制面板：推流中一键展开「直播控制面板」——画质锁定（暂停自适应档位调整并展示当前档位，`RTMPQualityLockPolicy` 纯逻辑可测）、隐私保护盾、录制/快捷标记、停止推流，聚合在底部快捷按钮行的入口中。
- [x] 直播中的 AI 场景理解与辅助操作。
  - [x] 直播场景理解：推流中每 10 秒对眼镜视野帧做端侧场景识别（Apple Vision，离线免费，复用 `VisionSceneService`，新增 `CVPixelBuffer` 直通入口避免 CGImage 转换），推流页展示当前场景标签与摘要；场景变化时若在录制自动打标记（「精彩瞬间」）；识别任务防堆积（in-flight 门控），采样调度与标签提取为纯逻辑 `RTMPLiveSceneScheduler` / `RTMPLiveSceneProcessor` 可测（采样间隔门控、reset、变化检测、置信度阈值）；设置页开关（默认开启）+ 持久化。直播 AI 辅助操作（场景 → 标题建议 / Agent 上下文）：场景识别后按模板生成最多 3 条直播标题建议（常见场景配主题 emoji、空场景回退摘要、长度封顶去重），推流页一键复制；「存入 Agent 记忆」把当前场景（标签 + 摘要 + 平台）构造成长期记忆条目（`AgentMemoryStore`），后续 Hermes / 自定义 Agent 请求经 `AgentSystemPromptBuilder` 自动携带；设置页开关（默认开启）+ 持久化；纯逻辑 `RTMPSceneTitleSuggester` / `RTMPLiveSceneContextBuilder` 可测（建议数量 / emoji 映射 / 空场景回退 / 长度封顶去重 / 记忆文本组合 / 空场景不入记忆）。
- [x] 性能指标、诊断日志和真实设备回归基线。
  - [x] 推流诊断（性能指标）：会话级采集连接次数 / 重连次数 / 画质升降档与档位历史 / 帧数与丢帧率（每 3s 采样）/ 录制标记数 / 场景变化数；停止推流生成诊断快照与可分享文本报告（设置页「推流诊断」，ShareLink 分享，摘要含时长/重连/画质调整）；纯逻辑 `RTMPDiagnosticsCollector`（begin/end、计数、丢帧率、历史）与 `RTMPDiagnosticsReport`（报告文本注入格式化）可测。
  - [x] 诊断日志文件：停止推流自动把会话快照落盘 Documents/RTMPDiagnostics/*.log（文件名内嵌开始时间，正文含起止时间行 + 完整指标报告，上限 20 份按时间滚动裁剪）；设置页「诊断日志」列表（文件名 / 时间 / 大小）点击查看全文（等宽字体）、右上角分享文件、左滑删除；纯逻辑 `RTMPDiagnosticsLog` 可测（文件名格式、写入内容、倒序列表、上限裁剪、删除、无效目录返回 nil、目录名）。真实设备回归基线：`docs/device-regression-baseline.md` 真机验收清单（眼镜连接/推流/自适应/重连/录制回放/多目的地/场景辅助/诊断日志/隐私合规/30 分钟长跑稳定性，每项含步骤、预期与通过标准，附执行记录表）。

## Phase 5: Public Release

**状态：发布就绪（待执行签名、提审与运营）**

- [x] 完成隐私、权限和数据流说明：`docs/privacy-data-flow.md`（相机帧去向按用户行为触发、语音/端点/本地存储/权限清单、发布承诺；原则：用户自配端点、本地优先、无内置云端）。
- [x] 完善设备兼容性矩阵、安装引导和故障排查文档：`docs/setup-and-troubleshooting.md`（兼容矩阵 / 首次使用与自建网关安装引导 / 眼镜、推流、录制、Agent、诊断故障排查 / 隐私速览）。
- [x] 建立公开 Issue、版本、变更记录和贡献流程：`CHANGELOG.md`（自 1.4.0 归档 Agent 中心与 Live Streaming 2.0）、`CONTRIBUTING.md`（分支/测试/本地化/文档/PR 规则）、`.github/ISSUE_TEMPLATE/`（Bug 与功能请求模板，含诊断日志要求）。
- [x] 通过 TestFlight 进行分阶段测试：`docs/testflight-plan.md`（构建导出配置、App Store Connect 内/外部测试组、三阶段放量与验收门禁、反馈渠道、可选 CI 草案）。
- [x] 根据签名、审核和运营条件规划 App Store 发布：`docs/app-store-release-plan.md`（签名/证书、元数据素材清单、隐私营养标签与出口合规、直播平台合规、审核备注模板、分阶段发布与回滚策略、发布前 Checklist）。

- [x] UI 本地化一致性：设置页 / Agent 网关表单 / 实时对话页 / 记录页 Tab / 推流倒计时 / 无设备引导的硬编码文案全部接入 `Localizable.strings`（19 键中英一致），`LocalizationKeyPresenceTests` 守卫键存在与双语言解析。

## Roadmap 更新规则

路线图会以可验证的产品能力为单位更新。Apple 平台能力、Meta Wearables SDK 或第三方 Agent 协议发生变化时，先记录兼容性和隐私影响，再调整阶段顺序。
