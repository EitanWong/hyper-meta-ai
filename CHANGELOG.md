# Changelog

版本遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。自 1.4.0 起记录。

## [1.4.0] - 未发布（开发中）

### 新增：Agent 中心（OpenClaw + Hermes + Qwen 统一接入）

- Agent Hub：统一接入 OpenClaw、Hermes 与自定义 Agent（WebSocket/HTTP），任务列表、诊断面板、记忆与规则管理。
- 内置网关（Built-in Gateway）：兼容基线升级到 qwen-audio-agent v1.10.1；保留 spawn_thinking 非阻塞工作队列（受理立即返回、owner FIFO、每 owner 单在飞）、协调协议（state / mode / presentation 解析与规范化、非终态最多重试 2 次、最终语音只来自 presentation.speech）、action-promise 守卫与实时响应生命周期、公告安全插入窗口（用户说话 / 回合挂起 / 音频排队时暂缓播报）；「问 Lucky」Siri 单轮问答走同一内置网关协调执行。
- 后台 Agent 模式：默认仍为 `Auto`；Auto 只在已成功配置且就绪的 OpenClaw / Hermes / 自定义 Agent 中路由，没有任何可用后台时自动进入仅前台模式，不创建后台任务；设置、语音页、Siri 与快捷指令均可明确选择「不使用后台 Agent」。
- Qwen 上游同步门禁：内置 DashScope Realtime 兼容层固定记录 qwen-audio-agent `v1.10.1` / `1dea8779e73d9e1aaebfd8c6a847270cce39572f`，GitHub Actions 每日及每次 push / PR 核对上游最新稳定 tag，发现漂移即阻止仓库检查通过。
- Qwen 任意时刻打断：会话层按 `responseId` 有界记忆已取消响应，丢弃打断竞态中迟到的音频、完成和中断事件，避免残音回弹或旧回复误结束新回复；手动暂停期间不再接受新的播放包。
- Qwen 响应生命周期关联：消费上游 `response.started`，内置 DashScope 适配器保留当前 provider `responseId` 并在本地 interrupt 回传；取消后无 `responseId` 的迟到音频必须等下一次明确 response 生命周期，连接断开 / 重连同时清空播放队列。
- Qwen 重连播放就绪：传输丢失改为 interrupt 清空播放队列但保持 ingress 活跃，重连后的首个有效响应无需重建会话即可播放；响应已知与播放已开始分离，PCM 包只有实际进入播放队列后才发布 speaking 并向上游回执一次 playback.started，拒绝包不再制造“界面在说但扬声器无声”的假状态。
- Qwen 首包播放预热：输入音频会话激活后立即异步创建并启动播放图，把 `AVAudioEngine` 建图 / 启动移出首个 PCM 包路径；新增 receive→schedule 指标及 20 ms 首包调度门禁，预热失败时仍由首包路径自动重试。
- Qwen 播放事件驱动调度：每个成功入队的音频包通过带锁合并唤醒立即驱动播放队列，跨越启动阈值或 underrun 后恢复不再等待 `5 ms` 轮询；轮询改为 `20 ms` 低频安全兜底，活动响应期间理论检查频率由每秒 200 次降至 50 次。确定性阈值跨越基准由 `169.711 ms` 降至 `1.472 ms`（减少 `99.133%`），连续 10 次复测均低于 `1.5 ms`，并加入 `<10 ms` 回归门禁。
- Qwen 入站音频解码：`audio.delta` 的 Base64 PCM 在 Gateway 后台解析队列完成解码，并携带 WebSocket 接收时刻进入播放管线，使 receive→schedule 覆盖真实解析与 MainActor 交付；连续音频包不再重复发布相同的 `isSpeaking=true`，降低播报突发期间的主线程占用与打断调度抖动。
- Qwen 内置事件直通：DashScope 适配器在提供方回调线程直接生成带接收时刻的强类型 Gateway 事件，App 内置模式不再把已解析事件重建成 JSON 后交给服务层二次解析；外部 Gateway 字符串协议与兼容入口保持不变。15,360 字节音频包 200 次基准由平均 `127.638 µs` 降至 `60.626 µs`（减少 `52.501%`），并加入 `<100 µs` 回归门禁。
- Qwen 播放 PCM 向量化：播放队列用 Accelerate 直接把对齐的交错 PCM16 转换并归一化到 `AVAudioPCMBuffer` 的非交错 Float32 声道，避免 320 ms Qwen 音频包逐样本 Swift 循环；未对齐输入保留逐字节兼容路径，并加入有符号极值、多声道顺序与 `<1 ms` 解码门禁。
- Qwen 打断闭环：用户手动打断、自然 barge-in 与视野注入取消均按上游协议先发送 `playback.cancelled(reason=user_interruption)`、再发送 `interrupt`，让公告在 provider 取消竞态前按用户打断结算而非当作播放错误重试；播放器 reset 改为中断返回前完成的串行屏障，避免界面已停而旧音频仍短暂续播。
- Qwen 关键打断交付：内置适配器先立即清理本地 playback / response 状态，再让 `interrupt` completion 等待真实 DashScope `response.cancel` 交付；provider 尚未 ready 时不再把旧 cancel 延迟到下一 session，关键控制交付超过 `150 ms` 会关闭并重连当前 socket，超时后的迟到 completion 由一次性 settlement 丢弃。
- Qwen Provider 重连收敛：Gateway transport 与 realtime provider 生命周期分离；provider unavailable / connecting 期间前台恢复复用现有 WebSocket，不再重复握手或制造第二个 voice owner，并在 provider 恢复后清除旧重连标记、保留上游原始错误信息。
- Qwen 睡眠 / 唤醒生命周期：对齐上游 `voice.sleep` 语义，`enabled` 只表示唤醒能力就绪，不再误报连接失败；`sleeping` / `waking` 成为一等连接状态，休眠同步停止上传、采集和当前播放，唤醒连接期间保持 waking 优先级并忽略迟到的旧睡眠广播；内置适配器按官方 sleep / wake 事件顺序恢复 provider-ready，主界面与 Live Activity 显示正常待命 / 唤醒状态。
- Qwen 连接状态归约：内置上游 `main` 的确定性 realtime 状态聚合器，统一执行 `unavailable > sleeping > waking > connected > connecting > disconnected` 优先级；迟到的 ready / connecting / sleep 事件不再覆盖失败、休眠或唤醒状态，明确 provider connecting / connected 仍可解除旧错误并收敛恢复。
- Qwen 控制面存活：当 `voice.connection=unavailable` 但 Gateway WebSocket 仍存活时，打断、唤醒、静音和播放回执不再被 voice-ready 门禁丢弃；活动播报会回传 `playback.cancelled(reason=playback_error)`，让上游正确释放播放窗口并重试公告。
- Qwen 高置信快速打断：保留普通语音 `0.02 RMS / 120 ms` 的抗误触窗口，同时为连续 `>=0.12 RMS` 的近讲语音增加 `40 ms` 快速路径；普通能量帧会清空快速累计，避免短爆音跨帧误触。
- Qwen 采集侧打断快路径：参考 GPT-Live 的全双工媒体面分离，把本地 RMS 与 barge-in 判定前移到原始采集帧接纳时刻，不再等待前一帧 WebSocket send completion；generation-safe capture token 拒绝停播、重连或新回复后的迟到触发。同一 `48 kHz / 20 ms / 960 samples` 输入且发送故意阻塞的确定性基准由 `83.248 ms` 降至 `0.0110 ms`（减少 `99.987%`，约 `7,568x`），并加入 `<10 ms`、陈旧 token 与 disarm 回归门禁。
- Qwen 音频系统恢复：系统音频中断或媒体服务重置会同步丢弃当前播放、回传 `playback.cancelled(reason=playback_error)` 并销毁失效播放图；保留管线 ingress，使恢复后的下一响应无需重连会话即可重建播放器。
- Qwen 物理音频路由恢复：蓝牙 / 有线 / USB 音频接入、拔出、睡眠唤醒与系统路由重配会立即失效旧播放并回传 `playback.cancelled(reason=playback_error)`，80 ms 合并通知突发后重建采集 tap；App 自己的 category / output override 不触发恢复环，瞬时重建失败保留 Qwen WebSocket 等待下一路由事件。
- Qwen 采集自动恢复：路由切换、媒体服务重置或系统中断后的音频图若因系统尚未稳定而首次建图失败，会在保留 Qwen WebSocket 的前提下按 `100 / 250 / 500 ms` 最多重试三次；成功、停止、休眠、新路由或再次中断均以代次取消迟到任务，建图任意阶段失败都会完整清理 engine / tap / upload 状态。
- Qwen 上行尾延迟约束：WebSocket 音频发送本地交付超过 `250 ms` 即触发当前代失败恢复；内置适配器把 completion 贯通到真实 DashScope send，未 ready 的延迟音频携带单调入队时间，超过 `120 ms` 不再下发 provider，关闭时也以错误释放；发送阻塞期间 mailbox 中超过 `120 ms` 的麦克风帧会在 PCM 编码前丢弃并单独计数，避免弱网恢复后重放陈旧语音，迟到发送回调仍由代次 token 隔离。
- Qwen 上行低延迟：48 kHz→16 kHz PCM16 编码复用输入 / 输出 `AVAudioPCMBuffer`，并在写入 PCM 时同步累计 RMS，去掉每个约 20 ms 音频帧的重复分配和二次扫描；删除启动时无意义的空 drain，避免其与音频 tap try-lock 竞争丢失首帧。新增 capture→sender `20 ms` 预算、重采样每帧 `0.35 ms` 预算、稳态零音频缓冲分配和 50 代立即首帧零丢失门禁。
- App Schema 系统意图：`assistant.activate`（iOS 26.2+）把 Lucky 语音会话接入系统激活场景（侧键 / Siri AI）；reminders 域（iOS 27.0+）`createReminder` / `createList` 对齐 Apple Intelligence Schema（清单 / 提醒 / 分组 / 位置触发实体 + `listType` / `locationTriggerEvent` 枚举，`DateComponents` / `Set<String>` / `Calendar.RecurrenceRule` / `CLPlacemark` 类型与必填属性全对齐）直接落 `AgentReminderStore` / `AgentListStore`（重复规则映射、备注 / 标签 / 链接并入、默认 1 小时后提醒、系统通知调度），Siri 对话给出成功 / 失败明确反馈；业务层存储与调度注入可测。
- Hermes 接入：OpenAI Responses 协议对话（图片携带、流式输出、工具调用回调），网关/密钥配置。
- 长期记忆与规则：随请求注入所有 Agent（`AgentSystemPromptBuilder`），语音/设置页维护。
- 视野连续追问：发送照片后同会话自动携带同一帧（可关闭、一键清除，仅内存）。
- 设备触发：镜腿/屏幕/姿态事件驱动 Agent 动作（规则与权限控制）。
- 提醒完成态：设置页行首圆环一键标记完成（划线过渡 + 触觉 + 撤销窗口），语音/聊天/Siri「完成提醒」直达（单条/批量/无匹配明确话术），锁屏通知「完成」补齐镜片 + TTS 确认。
- 镜片提醒操作：镜片 Reminders 子菜单点选提醒后显示 Done/Delete 操作卡，一键完成或删除并播报结果（与锁屏 Action 同一语义），Cancel 回主菜单。

- 镜片「Today」总览菜单：日程/提醒/任务任一有内容时主菜单动态出现，一键播报今日安排（下一场日程 + 提醒 + 进行中任务数，全空回退「一切就绪」），语音页与聊天页一致。
- 语音「今日安排」口令：「今天有什么安排」「今日安排」等直接播报今日总览（镜片 Today 同一实现，不转发大脑）；主页双卡支持下拉刷新（`.refreshable`）。
- Siri「今日安排」直达：`TodayAppIntent`（`openAppWhenRun = false`）Siri / 快捷指令 / 自动化一键播报今日总览（镜片 Today 同一实现：静默拉取日程 + 提醒 + 进行中任务，全空回退「一切就绪」），前台时同步渲染镜片；`AgentTodayIntentBuilder` 纯逻辑可测。
- 镜片 + 语音「明天安排」总览：主菜单新增「Tomorrow」（明天有日程时动态出现），一键播报明天下一场日程 + 场次数；语音「明天有什么安排」「明天要做什么」等本地组装播报；`AgentTomorrowOverviewBuilder` / `upcomingTomorrow` / `tomorrowEventsForMenu` 纯逻辑可测，明天口令优先于 Today 关键词匹配。
- 镜片任务「选择取消」：任务中心 Cancel 在多个活动任务时弹出编号选择卡，按序号直达取消（单任务仍一键取消）；`AgentTaskCancelFlow`（决策 / 上限 5 / 序号保持 / 截断）纯逻辑可测。
- Siri「明天安排」直达：`TomorrowAppIntent`（`openAppWhenRun = false`）一键播报明天日程（下一场 + 场次数，全空回退「明天暂无安排」），前台时同步渲染镜片；结果类型泛化 `AgentDayOverviewIntentOutcome` 今天 / 明天共用。
- 镜片任务「进度逐条播报」：任务中心 Progress 在多个活动任务时弹出编号选择卡逐条播报进度（单任务仍一键汇总）；选择流泛化 `AgentTaskChoiceFlow` 与 Cancel 共用。
- 任务重试（语音 + 镜片 + 聊天）：失败任务本地重试闭环——语音「重试 / 再试一次 / retry / try again」等口令本地拦截（无失败任务时不拦截转发大脑），任务中心新增「Retry」子菜单（有失败任务时动态出现，多个失败任务弹编号选择卡按序号重试）；重试优先把触发任务的原始口述原样重放给网关（`QwenAgentTask.sourceText` 新建时随 `lastUserText` 捕获，`sendText` 同步更新，复跑任务继承同一来源文本），无原始文本时退化为自然语言重试指令（与取消同构）；本地记录系统提示，回复 / 横幅 / TTS / 镜片结果卡全套反馈；`AgentTaskCommand.retryLatest / retryTask(Int)`、`failedTasks / latestFailedTask / requestTaskRetry`、解析器 `failedTaskCount` 参数与越界话术纯逻辑可测。
- 失败任务通知「重试」Action：任务通知按状态拆分分类——完成类（查看结果 / 追问 / 稍后提醒）与失败类（查看结果 / 重试 / 稍后提醒）；巡检投递在通知 userInfo 携带 taskId 与触发文本（`AgentTaskNotificationUserInfo` 纯逻辑可测，`PersistedAgentTask.sourceText` 持久化兼容旧快照）；点按「重试」跨进程恢复闭环——会话仍持有该失败任务时直接按 taskId 重试（重放原始口述 + TTS / 镜片确认），App 重启后从持久化快照定位并带指令打开语音页（`AgentTaskRetryPlanner` 决策 / `AgentTaskRetryCoordinator` 执行，均可注入可测）；稍后提醒重发沿用原分类（失败通知重发仍带重试）。
- 失败任务锁屏「重试」按钮：任务失败结果 Live Activity 按 `resultKind`（completed / failed / cancelled）渲染「重试」按钮，点按走 App Group 标记跨进程通道，App 前台消费后复用通知「重试」闭环（会话有失败任务直接重试最近一个，否则从持久化快照定位带指令打开语音页）；`AgentLiveActivityStateMapper.resultContent` 结果类型映射、`AgentTaskRetryTapStore` / `AgentTaskRetryCoordinator.consumeIfNeeded`（defaults / apply 注入）可测。
- 语音会话锁屏状态卡：语音会话活跃时 Live Activity（锁屏 / 灵动岛）实时显示「正在聆听 / 思考中 / 正在回复 / 已休眠 / 连接失败」，锁屏「停止」按钮直接结束会话（与 Control Center 同一通道）；优先级 审批 > 语音会话 > 倒计时 > 任务进度，会话结束自动回落任务进度 / 倒计时；`AgentVoiceLiveActivityStatus` 状态文案决策与 `AgentLiveActivityManager` 优先级（语音 / 审批 / 回落）纯逻辑可测。
- 休眠态锁屏「唤醒」按钮：语音会话休眠时锁屏卡显示「唤醒」+「停止」；「唤醒」经 `WakeVoiceSessionControlIntent`（打开 App）写 App Group 标记，前台消费后 `QwenVoiceSession.wake()` 恢复聆听并呈现语音页；状态文案与阶段统一为 `AgentVoiceLiveActivityStatus.phase`（`voicePhase` 结构化字段驱动按钮渲染，旧活动兼容），`VoiceControlRequestStore` 扩展 wake 三态（未知值回退 stop），`VoiceAssistantRouter` 消费 `.wake`（wakeExecutor 注入可测）。
- 语音会话波形动画：锁屏卡与灵动岛按阶段渲染 7 条波形（播报高幅快动 / 聆听中幅 / 思考低幅微动 / 休眠·连接·失败近乎静止）；灵动岛展开区 `TimelineView(.animation)` 持续波动（本地渲染，不消耗 Live Activity 更新预算），锁屏静态波形平滑过渡；`VoiceWaveformPattern` 确定性高度序列（phase 振幅 / 速度表 + 正弦相位错开，值域 0.06-1.0）纯逻辑可测。
- 任务通知「回复 JARVIS」文本输入：任务完成 / 失败通知新增系统原生 `UNTextInputNotificationAction`——锁屏 / 通知中心直接打字交给 JARVIS（无需打开 App），文本作为指令打开语音页自动发送（清单 / 提醒 / 任务等本地指令照常拦截），空输入忽略；完成 / 失败分类各 4 个 Action，解析 / 组装 / Handler 路由（Mock）与真实 Router → 语音页 instruction 通道可测。
- 提醒通知「回复 JARVIS」文本输入：提醒通知分类加入同一系统原生文本输入 Action（文案键与任务通知共用）——锁屏直接打字给 JARVIS（改提醒 / 加清单 / 查天气等），文本去空白后作为指令打开语音页自动发送，空输入忽略；分类动作集抽为 `actions`（稍后提醒 / 完成 / 回复 JARVIS）供注册与测试共用，`replyText` 决策纯逻辑可测；任务与提醒两类通知统一「锁屏打字指挥 JARVIS」入口。
- 问 JARVIS 结果通知「回复 JARVIS」文本输入：后台问答结果通知新增同一系统原生文本输入 Action（文案键与任务 / 提醒共用）——锁屏点按「回复 JARVIS」直接打字追问 JARVIS（无需打开 App），文本去空白后作为指令打开语音页自动发送（本地指令照常拦截），空输入忽略；分类动作集扩为「继续追问 + 回复 JARVIS」，`AgentAskResultNotificationActionParser` 支持 `.reply(text:)`（旧调用不传文本回退空字符串），Handler 经 `AgentAskResultNotificationActionRouter.replyToJARVIS` 路由；解析 / 分类组装 / Handler（Mock）与真实 Router → 语音页 instruction 通道可测，三类通知统一「锁屏打字指挥 JARVIS」入口。
- 问 JARVIS 锁屏回复携带结果上下文（Reply Carries Ask Result）：「问 JARVIS」结果通知的锁屏文本回复与「继续追问」同一语义——路由经 `resolveContext`（测试可注入）从归档记录恢复该条结果上下文，`VoiceAssistantRouter` 同时携带 instruction + followUpContext 打开语音页；语音页先注入结果上下文再发送初始指令，转发大脑时初始指令经 `QwenVoiceSession.followUpMessage` 按「继续追问」包装（无上下文时原样透传，其余初始指令不受影响）；锁屏打字追问即上下文连续对话。
- 问 JARVIS 结果通知「重试」Action（Retry Ask Result）：结果通知新增系统原生「重试」按钮（继续追问 / 重试 / 回复 JARVIS 三动作）——通知 userInfo 携带原始问题与大脑（`AgentAskResultDeepLink` message / brain 载荷，纯逻辑可测），锁屏点按「重试」经 `AgentAskRetryCoordinator` 重新执行同一问题单轮问答（send / storage / notifier / appActive 可注入）：成功归档到 Hub 时间线 + 镜片渲染完整回复，失败在镜片给出与 Siri 一致的明确文案；再按「App 不在前台 + 开关开启」投递结果通知（前台重试不重复打扰，结果经镜片卡反馈）；旧通知无原文载荷时防御性忽略；Parser / Handler 路由（Mock）/ 协调器闭环可测。
- 提醒通知「明天提醒」Action（Remind Me Tomorrow）：提醒到点通知新增系统原生「明天提醒」按钮（动作集 = 稍后提醒 / 明天提醒 / 完成 / 回复 JARVIS）——锁屏一键把提醒重排到明天同一时刻（保留 id / 文本 / 重复规则，日历日加法正确跨越月末 / 年末），后台静默重排（无需打开 App），镜片卡 + TTS 播报「明天同一时间提醒你」确认；`AgentReminderNotificationAction.tomorrow` 纯逻辑（固定 UTC 日期构造跨月断言）与 `Outcome.tomorrow` 决策可测，锁屏与镜片 / 倒计时入口（`AgentReminderTapCoordinator`）两个消费点同语义。
### 新增：Live Streaming 2.0（RTMP 推流）

- 直播场景预设：目的地 + 推流参数一键保存/应用（密钥不落盘）。
- 自适应质量：码率 + 分辨率 + 帧率 + 音频码率六档动态调节，弱网保流畅。
- 自动重连：退避 2s→30s、最多 5 次；服务端拒绝不重试。
- 本地录制 + 事件标记 + 回放（标记时间轴一键跳转）。
- 多目的地并行推流：同一画面推最多 4 个附加平台，推流中动态增删、失败自动重试 1 次。
- 直播场景理解：端侧识别（Apple Vision）+ 场景变化自动标记 + 标题建议 + 存入 Agent 记忆。
- 直播标题 AI 润色：场景卡对模板标题一键调用当前大脑润色（携带场景标签 / 摘要 / 平台上下文），成功后以润色变体替换建议列表（可复制）；`RTMPTitlePolishPrompt`（提示词构造）与 `RTMPTitlePolishParser`（编号/符号/Markdown 剥离、去重、长度封顶、说明行跳过）纯逻辑可测。
- 场景 Agent 分析：场景卡「Agent 分析」把当前直播场景（标签 / 摘要 / 平台）发给当前大脑生成互动建议（讲什么 / 做什么 / 观众可能问什么），结果弹层支持复制、系统分享与「存入 Agent 记忆」（`RTMPSceneAnalysisMemory` 加前缀 + 截断，纯逻辑可测）；`RTMPSceneAnalysisPrompt`（提示词构造，空上下文行省略）纯逻辑可测；动作按钮独立成常驻行（不依赖标题建议存在）。
- 场景 AI 大脑分发：润色 / 分析不再固定 Hermes，按 Hermes → OpenClaw 网关（chat.send 全量文本事件 + `[[FINAL]]` 终态 + 30s 超时）→ 自定义 HTTP/WS Agent（取最近配置）顺序路由，全部不可用时提示「未配置可用的 Agent 网关」；`SceneAssistantBrain` 优先级决策纯逻辑可测。
- 推流诊断：会话指标 + 可分享报告 + .log 日志文件（上限 20 份）。
- 直播预览：连接前实时预览、相机引导、开播合规清单、隐私保护盾（一键隐藏画面）。
- 录制导出分享：回放面板一键分享整段录制视频（ShareLink）；标记时间轴长按「导出片段」，按标记前后窗口（默认前 10s / 后 5s，夹取到录制范围）AVAssetExportSession 裁剪为 MP4 并弹系统分享；`RTMPClipSegment`（时间范围计算 / 文件名清理）纯逻辑可测，临时片段目录逐次清理。
- 片段窗口可配置：设置页新增「标记前 / 标记后」Stepper（0-60s，步进 1s，持久化），导出即时生效；`RTMPClipWindowSettings`（默认值 / 夹取 / UserDefaults 往返）纯逻辑可测，`RTMPClipSegment.timeRange` 参数化前后窗口。
- 直播控制面板：画质锁定 / 隐私盾 / 快捷标记 / 停止推流。
- 端侧离线 AI 兜底：未配置 Agent 网关时，直播标题润色与场景分析改用 Apple Intelligence 端侧模型（Foundation Models，iOS 26+，离线、私密、数据不出设备）；`LocalBrainService`（可用性门控：开关 / 系统版本 / 模型就绪 / 语言支持，单会话复用 + 请求串行）与 `LocalBrainResponder`（超时 / 异常 / 空文本回调语义，每次请求只回调一次）纯逻辑可测；`SceneAssistantBrain` 分发顺序 Hermes → OpenClaw → 自定义 → 端侧，结果弹层展示「端侧 AI」徽标 + 隐私提示，设置页总开关（默认开启）持久化；低版本系统自动降级为原「未配置网关」提示。

### 新增：助手画像与上下文边界（对齐 qwen-audio-agent v1.8）

- 四层上下文：核心规则 → 用户偏好（规则）→ 长期记忆 → 助手画像（`AgentSystemPromptBuilder`
  统一注入顺序，画像为最弱层并自声明「用户规则与记忆优先」）；设置页新增「助手画像」
  （名称 / 关系定位 / 表达风格 / 注入开关，`AgentPersonaStore` 持久化、回退默认画像）。
- 语音身份交互：语音 / 聊天页「你叫什么名字 / 你是谁」播报助手身份（「我是 Hyper，你的
  智能管家。」）；「以后你叫 X / 改名叫 X」本地改名并确认——先于规则解析拦截，避免
  「以后你叫 X」被当成规则；`AgentPersonaCommandParser`（疑问词过滤）可测。
- 记忆语音纠正：`AgentMemoryCommand.forget`（「忘掉 X / 记错了 X / 那条记错了：X」）
  按精确 → 包含顺序删除（`AgentMemoryStore.remove(matching:)`），未命中明确提示；
  不误吞「别忘了提醒我」（裸「忘了 / 忘记」不作为前缀）；语音页 / 聊天页双入口共用
  `AgentProfileCommandReply` 话术。
- 长任务自动进度播报（对齐 v1.8.2）：任务持续运行超 2 分钟主动播报一次进度（每任务一次，
  `AgentTaskProgressCheckIn` 纯决策可测）；镜片进度卡 + TTS（转发模式由 App 播报），
  受播报窗口与静默模式约束、不触发触觉；语音会话层定时轮询，任务清空自动停止。
- 图库直达大脑选择：图库照片 / OCR 文字「发给 Agent」发送前弹出选择（自动（推荐）/
  Hermes / OpenClaw（已连接）/ 自定义（已配置）），按所选大脑直达聊天页；「自动」
  沿用 Hermes → OpenClaw → 自定义 Agent 顺序分发（`GalleryAgentRoute` 纯映射可测），
  全部不可用时回退 Hermes 入口展示配置引导。
- 提醒通知交互 Action：锁屏 / 通知中心点按「稍后提醒」延后 10 分钟（单次顺延、周期
  跳到下一次触发）或「完成」取消提醒（`AgentReminderNotificationDelegate.didReceive`
  重排 / 移除并同步存储）；Action 标识、按 id 匹配与重排计算为纯逻辑可测
  （`AgentReminderNotificationAction`），Category 启动与每次调度时注册（跟随 App 内
  切换语言刷新标题）。
- Siri 本地工具直达：`LocalToolsAppIntent`（`openAppWhenRun = false`，后台可执行）
  不经语音会话直接调用本地工具——长期记忆 / 个人规则 / 命名清单（自动建单）/
  本地提醒（结构化分钟数或中文时间短语，含取消与查询）；副作用与应答文案分离
  （`LocalToolIntentHandler` / `LocalToolIntentFormatter`）纯逻辑可测，通知授权可注入。
- Siri 本地工具新增「日历」：`LocalToolsAppIntent` 工具选项扩展 `calendar`——
  复用语音 / 聊天页同一套 `AgentCalendarCommandParser`（「把明天下午3点产品评审加入
  日历」「今天有什么安排」）+ `AgentCalendarExecutor`（授权 / EventKit 读写 / 查询
  汇总 / 创建确认 / 失败与未授权话术），Siri / 快捷指令 / 自动化后台可离线创建与
  查询日程，回复文案与语音页完全一致；未识别指令明确提示
  （`tools.intent.calendar.unparseable`，中英各一），`AgentLocalTool` /
  `LocalToolIntentOutcome` / `LocalToolIntentFormatter` / `LocalToolIntentHandler`
  （provider 可注入 Mock）纯逻辑可测。
- 设置页「日历」分区：Agent 设置新增日历状态区（`AgentSettingsSection.calendar`，
  支持深链定位）——授权状态明确反馈（已授权 / 未授权 / 受限 / 尚未请求，绿 / 红 /
  橙 / 灰着色），未请求时一键就地请求授权，已拒绝或受限时「前往系统设置」跳转，
  已授权无冗余动作；footer 说明日历在语音 / 聊天 / 镜片 Calendar 菜单 / 主页 HUD /
  小组件 / 锁屏的用途；状态文案与动作决策 `AgentCalendarSettings` /
  `AgentCalendarSettingsAction` 纯逻辑可测。
- 日程提醒通知（Calendar Event Alerts）：设置页日历分区新增「日程提醒」开关与
  「提前提醒」提前量（5 / 10 / 15 / 30 分钟，默认关闭避免与系统日历提醒重复）——
  开启后为未来 7 天内最近的非全天日程按提前量排期本地通知（`UNCalendarNotificationTrigger`，
  触发时间晚于当前才排期，已进入提前窗口的交由 Live Activity 倒计时；单次最多 20 条避免
  占满系统配额），随日历同步（启动 / 回前台 / EventKit 变更）差量增删，关闭即清空；
  开关开启时若通知权限未确定则就地请求；`AgentCalendarEventNotifier`（窗口 / 提前量 /
  排期上限 / 稳定去重 ID）与 `AgentCalendarNotificationSettings`（默认值 / 往返 / 非法值
  回退）纯逻辑可测，调度薄封装 `AgentCalendarNotificationScheduler`（XCTest 跳过）。
- 日程提醒通知交互闭环：日程通知点按（锁屏 / 通知中心）深链到设置页「日历」分区
  （复用 `AppNavigationRouter` 深链 + 分区定位），通知携带身份标记与事件 ID
  （`AgentCalendarNotificationAction` 分类标识 / userInfo 构建与解析 / 点按深链决策
  纯逻辑可测），前台到达仍走 JARVIS 通知播报管家（按隐私策略 TTS 摘要）。
- 设置页「近期日程」列表：日历分区下方新增未来 7 天日程预览（今天 / 明天 / 之后
  分组，组内时间升序，「15:00 标题」/「全天 标题」行，单组 5 行 / 总量 10 行封顶），
  授权后自动拉取、未授权提示引导、加载中与空态明确反馈（日程通知点按落地即可看到
  对应日程）；`AgentCalendarOverviewMapping`（分组 / 行文案 / 窗口过滤 / 截断）纯逻辑可测。
- 日程详情卡：近期日程行点按弹出原生半高 Sheet（标题 / 时间范围 / 日历来源 / 当前状态：
  还有 X 分钟（小时）开始 / 进行中还有 X 结束 / 即将开始（结束）/ 已结束，带状态图标与
  着色，全天日程不显示状态），拖动指示器 +「完成」关闭，返回逻辑与系统一致；
  `AgentCalendarDetailMapping`（状态判定 / 分档文案 / 图标 / 详情组装，全天无状态）纯逻辑可测。
- 日程详情卡「设为提醒」：详情卡新增「提醒我」菜单（5 / 10 / 15 / 30 分钟前，默认 10 分钟），
  一键把日程转成本地提醒（复用提醒存储 / 通知调度 / 倒计时 Live Activity），同源去重
  （标题 + 开始时间相同即显示「已设置提醒」禁用态），提醒已满 20 条或日程临近来不及
  设置时弹窗明确反馈；`AgentCalendarReminderBridge`（提前量 / 去重 / 构建，触发时间已过
  返回 nil）纯逻辑可测。
- 主页「今日日程」卡：注册后主页（默认 Tab）顶部新增今日日程信息卡——静默拉取今天
  未结束日程显示最近一条（「今天 15:00-16:00 产品评审」，全天「全天 出游」），无日程 / 未授权
  明确占位文案，点按经 `AppNavigationRouter` 深链到设置页日历分区（MainTabView 消费自动切
  Tab）；`AgentHomeCalendarCardMapping`（授权分支 / 空态 / 最近一条 / 已结束排除）纯逻辑可测。
- 主页「下次提醒」卡：与今日日程卡并排组成「今日安排」双卡（抽成通用 `HomeInfoCard`：
  图标 + 标题 + 单行内容，占位态弱化显示）——最近一条提醒单次显示相对时间
  （「25 分钟后」），周期显示「每天 HH:mm」「每周 HH:mm」，无提醒占位文案，点按深链到
  设置页提醒分区；`AgentHomeReminderCardMapping`（最近一条 / 单次相对时间 / 周期时钟 / 空态）
  纯逻辑可测。
- 主页双卡数量徽标（日程 / 提醒条数，99+ 封顶）与提醒概览 Sheet：点提醒卡弹出列表，行首圆环一键完成（划线 + 触觉 + 撤销窗口）、左滑删除，操作后双卡即时刷新，右上角「管理全部」直达设置页提醒分区。
- 主页今日日程概览：点日程卡弹出今日日程列表，左滑删除带确认对话框（复用日程删除执行器，成功触觉 + 行移除 + 双卡刷新，失败明确提示），右上角「管理全部」直达设置页日历分区。
- 主页日程详情闭环：概览 Sheet 点按任一条弹出日程详情卡（复用设置页详情卡，含「提醒我」提前量与「删除此日程」），操作后概览与主页双卡即时刷新。
- 主页双卡自动刷新：任何入口改动日程 / 提醒后，主页「今日安排」双卡即时更新——
  `AgentHomeCardRefreshCenter`（NotificationCenter 刷新信号，幂等）在提醒存储任意写入
  （新增 / 删除 / 更新 / 清空）与日历创建 / 删除成功时广播；主页订阅信号并在回到前台
  （scenePhase）、EventKit 外部变更（`EKEventStoreChanged`：系统日历 App / 多端同步）时
  重新拉取；从设置页授权后切回主页 Tab（MainTabView 切回 Tab 0）同样触发刷新，无需重启
  立即看到日程；刷新信号广播与存储 / 执行器触发点纯逻辑可测。
- 日程详情卡「删除此日程」：设置页近期日程行点按的详情卡新增红色删除入口（原生
  confirmationDialog 确认，明确提示「将从日历中删除「%@」，此操作无法撤销」）——确认后
  执行 EventKit 删除，成功关闭详情卡并刷新近期日程列表（主页双卡经刷新信号同步更新），
  失败弹窗明确提示；`AgentCalendarDetailDeleteAction`（确认文案 / 执行 / 失败判定，
  Mock provider）纯逻辑可测。
- 语音 / 聊天 / Siri「删除日程」歧义追问闭环：删除指令匹配多个日程时不再只给一句模糊
  提示——候选暂存（`AgentCalendarDeletePendingStore`）并编号列出（「找到 2 个匹配日程：
  1. … 2. … 请回复序号或更具体的名称。」），下一句回复序号（阿拉伯 / 中文数字、
  「第 X 个 / X 号」）、更具体名称或「取消 / 算了」即完成删除、收窄候选或取消；
  名称仍歧义时自动收窄后再次追问；无关消息不打断（待选保留），新的日历指令自动替换待选；
  聊天页 / 语音页（播报 + 上镜片）/ Siri 快捷指令三入口一致接入；`AgentCalendarDeletePromptBuilder` /
  `AgentCalendarDeleteSelectionParser` / `AgentCalendarDeleteSelectionCoordinator`（Mock provider）
  纯逻辑可测。
- 删除歧义追问镜片按钮选择（JARVIS 式「报选项 + 点选」）：歧义出现时镜片同步显示编号
  选项卡（`AgentDisplayHub.showChoice`，标题超长截断 + 末尾 Cancel，无眼镜静默降级），
  用户直接点镜片按钮即可删除对应日程或取消，与语音报序号 / 说名称并行；镜片回调按
  （标题 + 开始时间）在当前待选中定位，语音已消费后点选静默忽略不误删；
  `AgentDisplayChoiceMapping`（编号 / 截断 / 取消标签）与 `AgentCalendarDeleteSelectionCoordinator`
  select / cancel 入口（Mock provider）纯逻辑可测。
- 镜片日程菜单点选删除闭环：眼镜端「Calendar」菜单点选日程播报详情后，镜片显示
  「Delete / Cancel」确认卡——点 Delete 直接执行 EventKit 删除并播报结果（成功
  「已删除：今天 15:00-16:00 产品评审。」/ 失败明确提示），主页双卡同步刷新；Cancel
  回主菜单；语音页与聊天页一致接入；`AgentDisplayChoiceMapping.deleteLabel` 与
  `AgentCalendarDetailDeleteAction.deletedText`（成功播报文案）纯逻辑可测。
- 设置页提醒列表「稍后提醒」滑动动作：已到点的单次提醒左滑一键重排（+10 分钟，与锁屏
  通知 Action 同一实现与文案），重新调度后行内文案即时从「马上」变为「10 分钟后」并伴随
  成功触觉反馈；周期提醒无需（到点自动再触发）不显示该动作；`AgentReminderSnoozePolicy`
  （可稍后判定 / 重排计算，复用通知 Action 语义）纯逻辑可测。
- 语音 / 聊天 / Siri「删除日程」指令：创建 / 查询之外的第三个能力——「把明天的评审删掉」
  「删除下午3点的会」解析（后缀 / 前缀动词，时间短语或日期范围词 / 日程语境词保守拦截，
  「取消」留给提醒指令），窗口内归一化双向包含匹配，唯一匹配才执行 EventKit 删除并明确
  反馈（「已删除：今天 15:00-16:00 产品评审。」），多个匹配列出提示更具体、零个提示未找到、
  失败明确反馈；`AgentCalendarCommandParser` / `AgentCalendarDeleteMatcher` /
  `AgentCalendarExecutor`（Mock provider）纯逻辑可测。
- 桌面小组件：`AgentHomeWidget`（WidgetKit，小 / 中尺寸，iOS 17+ 交互按钮）——
  展示下次提醒（内容 + 相对时间，周期提醒取最近一次触发）、提醒总数与任务摘要，
  中尺寸一键「开始 / 停止语音会话」（复用 Control Center 跨进程请求通道）；
  快照由 App 侧生成（`AgentWidgetSnapshot` 纯逻辑可测）经 App Group 共享，
  提醒调度 / 语音会话启停 / 任务数变化即时刷新时间线，空态引导设置提醒。
- 锁屏 Widget 配件：`AgentHomeWidget` 新增矩形 / 圆形 / 单行三种锁屏与灵动岛尺寸——
  矩形展示「任务进行中」摘要或「下次提醒」内容 + 相对时间，圆形显示提醒总数环形
  进度（上限 20），单行显示任务摘要或「下次：内容」；配件文案由 App 侧快照生成
  （`AgentWidgetSnapshot` 新增 `accessoryTitle` / `accessoryBody` / `accessoryDetail` /
  `accessoryInlineText` 字段，任务进行中优先展示，纯逻辑可测），扩展镜像字段
  optional 兼容旧快照，无需手动刷新即与桌面小组件同一数据通道。
- 桌面小组件「下次日程」：小 / 中尺寸与锁屏矩形配件新增下次日程展示——中尺寸常驻
  「日历图标 + 时间 标题」行，小尺寸在无提醒时以日程替代空态（图标切换为日历），
  矩形配件在无任务 / 无提醒时回落「下次日程」；窗口为未来 24 小时内最近一个非全天
  日程（`AgentCalendarCountdownPolicy.widgetMaxAhead`），时间文案当天「14:30」、
  明天「明天 09:00」、更远「3月8日 14:30」（`AgentWidgetCalendarFormatter` 纯逻辑
  可测，跟随 App 语言）；`AgentWidgetSnapshot` 新增 `nextCalendarText` /
  `nextCalendarDetail` 字段，快照刷新中心复用 `AgentCalendarCountdownCoordinator`
  最近拉取结果（不请求权限、未授权为空），日历变化（EventKit 监听 / 回前台 /
  新增日程）自动刷新时间线；扩展镜像字段 optional 兼容旧快照。
- 主屏快捷操作（Quick Actions）：长按主屏图标——静态三项（语音会话 / 停止会话 /
  快速识图）+ 动态「下次提醒」（标题 / 相对时间跟随 App 语言，回前台刷新）；点按经
  `UIApplicationDelegate` 桥接（`HomeScreenShortcutActions`：identifier → 路由纯映射
  可测）：语音走 `VoiceAssistantRouter`（与 Siri / 眼镜 tap 同回合语义）、识图走
  `QuickVisionManager`（冷启动排队）、提醒走镜片卡 + TTS 播报（与通知前台播报同话术
  与开关约束）；冷启动（launchOptions）与热启动（performActionFor）双路径覆盖。
- 系统导航深链：`AppNavigationRouter`（@MainActor，请求 / 消费生命周期可测）——
  点按提醒横幅本体经深链自动切到设置 Tab、打开 Agent 设置并滚动定位到提醒区
  （`AgentSettingsSection.reminders` + `ScrollViewReader`，只定位一次），
  形成「提醒通知 → 管理」闭环；后续系统入口（Spotlight 等）可复用同一路由。
- Spotlight 系统搜索：长期记忆 / 个人规则 / 命名清单 / 本地提醒自动进入系统搜索
  （CoreSpotlight 索引，`SpotlightIndexer` 元数据构造与 identifier 解析纯逻辑可测；
  单次提醒触发次日过期、已过期的单次提醒与重复提醒按有效性过滤）；点按搜索结果
  经 `AppNavigationRouter` 深链到 Agent 设置对应分区（记忆 / 规则 / 清单 / 提醒），
  冷启动（launchOptions userActivityDictionary + SwiftUI `onContinueUserActivity`）
  与热启动（`application(_:continue:)`）双路径覆盖；索引在冷启动、回前台、退后台时
  幂等重建（先整域删除再全量写入），保证最新大脑数据可被搜索。
- Spotlight 图库照片：眼镜拍摄照片也进入系统搜索（`spotlight.photo` 域）——有 AI 描述
  时标题为描述、副标题为拍摄时间，无描述时标题为拍摄时间（`spotlight.photo.title` /
  `spotlight.photo.noDescription` 本地化）；搜索结果自动携带本地缩略图
  （`SpotlightIndexer.applyThumbnailIfAvailable` 文件缺失幂等跳过）；点按照片结果经
  `AppNavigationRouter.gallery(uuid)` 切到图库 Tab 并直接弹出该照片详情；
  路由消费改为按目标过滤（`consume(where:)`），设置页与图库页各自只取走属于自己的
  请求，避免多消费者互相误吞。

### 新增：眼镜拍照与图库

- 拍照本地存档：Live AI / 快速识图拍摄的照片自动存入 App 文档目录（`Documents/CapturedPhotos`，上限 50 张滚动，同名文件自动唯一化并清理孤儿文件），图库页网格展示、详情查看（拍摄时间 / AI 描述）、分享与删除；拍摄预览新增「保存到相册」一键存入系统照片库（相册只写权限）。
- 纯逻辑 `CapturedPhotoNaming` / `CapturedPhotoStore` 可测（命名唯一化、排序、上限裁剪、删除、落盘失败回退、往返）。

### 新增：对话导出

- 会话详情页一键导出 / 分享对话记录：导出文本含时间、模型、语言、条数与逐条消息（用户 / 助手分角色、保留多行内容），`ConversationExportBuilder` 纯逻辑可测。

### 新增：图库 AI 描述

- 拍摄照片自动回填端侧 AI 描述：拍照存档后对照片运行 Apple Vision 离线场景识别（画面不出设备），把中文摘要写入图库记录的 `aiDescription`，图库详情页直接展示；`CapturedPhotoStore.updateDescription` 可测（按 id 回填、空内容清除、未知 id 无操作）。

### 新增：图库端侧取词（OCR）

- 图库照片详情页「取词」：对已存档照片运行 Apple Vision 离线文字识别（免费、无网络），结果弹层支持复制、系统分享与 iOS 18+ 端侧翻译（复用 `VisionOCRService` / `OnDeviceTranslationView`，空结果与低版本均有提示）。
- 图库 OCR 结果「发给 Agent」：取词结果弹层一键把识别文字作为用户消息发送给当前聊天 Agent（与照片直达共用同一聊天入口 `GalleryChatPayload`），可继续追问翻译 / 总结；`AgentChatView` 新增 `pendingUserText` 直达注入。
- 图库 OCR 结果「朗读」：取词结果弹层工具栏一键 TTS 朗读识别文字（复用 `TTSService`，与聊天页取词朗读一致）。

### 新增：系统分享（Share Extension）

- 任意 App 内容直达 Hyper：系统分享面板新增「发送给 Hyper」扩展（文本 / 链接 / 网页激活规则），分享预览 + 三目标选择（长期记忆 / 命名清单 / Agent 大脑），确认后经 App Group 队列（`group.com.lunflux.hyper-meta-ai`，上限 20 条滚动）唤起 App 消费。
- 记忆 / 清单目标落本地存储并弹镜片结果卡确认（记忆去重、清单自动创建「分享」清单）；Agent 目标经 `VoiceAssistantRouter` 启动语音会话并把分享内容作为指令发出（与 Siri / 快捷指令同回合语义）；冷启动与回前台自动补消费（`AgentShareProcessor` 纯逻辑可测，扩展侧 `ShareQueueWriter` 与 App 侧队列 JSON 字段镜像一致）。
### 新增：图库照片发给 Agent

- 图库详情页「发给 Agent」：一键把已存档照片作为视野上下文发送给当前聊天 Agent（默认「请看这张照片」，输入栏有文字时优先使用），发送后照片保留为会话级上下文可继续追问，与「拍照发送」同一语义；修复「拍照发送」`isSending` 交接时序导致照片实际未发出的问题（捕获期占用结束后由 `send()` 接管发送期状态，同步交接无并发窗口）。

### 新增：系统日历日程（EventKit）

- 语音 / 聊天双入口直接读写系统日历：创建日程（「把明天下午3点产品评审加入日历」「明天下午3点把会议加入日历」，复用提醒时间解析器：相对 / 绝对时间、默认时长 1 小时）与查询安排（「今天 / 明天 / 这周 / 下周 / 周三 / 最近有什么安排」，按时间排序播报、空态提示）。
- 权限按需请求（拒绝引导去设置），不占后台 Agent 会话；`AgentCalendarExecutor` 统一授权 + EventKit 副作用（provider 可注入 Mock），`AgentCalendarCommandParser` / `AgentCalendarDayRange` / `AgentCalendarFormatter` 纯逻辑可测。
### 新增：每日晨报（Morning Briefing）

- JARVIS 式早安汇报：设置页开启后每天定时送达本地通知，内容融合今日日程（EventKit）、待触发提醒与进行中任务（栏目可单独开关，时间可配置，附「预览今日晨报」）；`AgentBriefingBuilder` 内容构建纯逻辑可测（问候带助手名、日期行随语言、空态回退文案）。
- 晨报体验增强：问候随时段自然变化（早上好 / 下午好 / 晚上好 / 夜深了，`AgentBriefingGreetingPeriod` 分段纯逻辑可测）；日程栏开启时首条日程未来 24 小时内显示「下一场日程 X 分钟 / 小时后开始。」倒计时行（排在日程列表前，已开始 / 超 24 小时 / 栏目关闭时不显示）。
- 内容保鲜：App 冷启动 / 回前台 / 设置变更即时重算（`AgentBriefingScheduler.sync` 幂等：先移除再调度），进后台提交 BGAppRefreshTask 机会式刷新（`AgentBriefingBackgroundTask`，Info.plist 声明后台任务标识）；通知中心与数据源协议化（`AgentBriefingNotificationCentering` / `AgentBriefingDataProviding`）可注入 Mock 测试。
### 新增：健康数据管家（HealthKit）

- 语音 / 聊天双入口直接读写系统健康数据：「记录体重65公斤 / 记一下体重65.5kg / 把体重记为70千克」写体重、「记录步数8000 / 今天走了8000步（昨天同理）」写步数、「记录跑步5公里 / 我跑了3.5公里」写跑步（HKWorkout，按 10km/h 估算时长）；「今天 / 昨天走了多少步」「我体重多少」「昨晚睡了多久 / 睡眠怎么样」查询（昨晚 = 昨天 22:00 → 今天 10:00 窗口）。
- 权限按需请求（拒绝引导去设置），HKHealthStore 走 `AgentHealthProviding` 协议注入（测试用 Mock）；数字解析仅接受 ASCII 数字 + 「65点5」中文小数（避免 CJK 数字属性误吞「千 / 万」），`AgentHealthCommandParser` / `AgentHealthFormatter` / `AgentHealthExecutor` 纯逻辑可测；entitlements 增加 `com.apple.developer.healthkit` + Info.plist 读写用途文案。
### 新增：眼镜 Display 主页 HUD（JARVIS 镜片主页）

- 镜片主页渲染：时间（HH:mm）+ 短日期（M/d 周X）+ 未读通知数 + HomeKit 设备状态摘要（灯 / 插座 / 风扇 / 开关 → 开 / 关，温控 → 温度，门锁 → 已锁 / 未锁，上限 3 行）+ 快捷动作按钮（唤醒 / 拍照识图 / 重听 / 新会话 / 关闭），按钮复用菜单图标目录（无效图标自动跳过）。
- 入口：语音页 / 聊天页眼镜菜单首项「Home」一键渲染到镜片；外设中心新增镜片主页预览卡（时间每秒刷新）+「显示到镜片」按钮。
- 权限感知：通知未授权不计数、HomeKit 未授权不列设备；`AgentDisplayHomeLoader` 数据装载与 `AgentDisplayHomeMapping` 文案 / 布局映射纯逻辑可测（calendar / locale 可注入）。
### 新增：眼镜连接问候（Glasses Connect Greeting）

- JARVIS 戴上眼镜时刻：眼镜变为可用时镜片弹出「系统在线」问候卡 + 触觉反馈 + TTS 语音摘要（日程 / 提醒 / 进行中任务 / 未读通知条数，0 项栏目省略，全空回退「一切正常」）。
- 策略门控：总开关、语音会话中不打扰、两次问候最小间隔 60s（防断连重连风暴反复播报）——`AgentConnectGreetingPolicy` 纯逻辑可测；语音播报尊重静默模式（镜片卡片与触觉始终保留）。
- 接线：`StreamSessionViewModel.onDeviceAvailable` 新回调（App 层经 `AppSessionCoordinator` 挂接 `AgentConnectGreetingAnnouncer`，首次连接即触发）；设置页新增「眼镜连接问候」分区（总开关 + 日程 / 提醒 / 任务 / 未读通知内容开关，直连 UserDefaults）。
- 数据组装 `AgentConnectGreetingAssembler`（晨报数据源 + 通知中心均可注入 Mock）与文案构建 `AgentConnectGreetingBuilder`（助手名注入 / 全空回退）纯逻辑可测。
### 新增：问 JARVIS 结果归档与通知深链（Ask Result Archive + Deep Link）

- 「问 JARVIS」后台成功回答自动归档到 Agent Hub 时间线（独立 `agent-ask` 归类，橙色 sparkles 图标，可搜索 / 过滤 / 点按查看详情）；`AgentAskArchiver`（记录构建：用户问题 + JARVIS 回复，仅成功回复落盘，storage 可注入）纯逻辑可测。
- 结果通知携带记录 ID：锁屏 / 通知中心点按「JARVIS 回答」横幅自动打开 App 直达结果详情（`AgentAskResultDeepLink` userInfo 构建 / 解析纯逻辑可测）；Hub 已打开时实时消费深链，记录已删除时静默忽略。
- 接线：`AgentAskAppIntent.perform` 统一走 `runAsk`（归档 + 镜片渲染）+ `notifyResult`（携带 recordID 投递，Siri 追问路径同样归档）；`AgentReminderNotificationDelegate.didReceive` 新增 `agent.ask.result` 分支 → `AppNavigationRouter.request(.agentAskRecord)`；`HyperMetaAIHomeView` 先开 Hub，`AgentHubView` 再消费并呈现 `ConversationDetailView`。

### 新增：任务 Live Activity 锁屏控制按钮（取消 / 加速）

- 任务进行中时，锁屏 / 灵动岛任务卡新增「取消 / 加速」交互按钮（`Button(intent:)`，iOS 17 Live Activity 交互）：取消 = 请求网关停止最近的任务（与镜片菜单 / 语音指令同一路径），加速 = 向网关发送自然语言催促指令尽快给出结果（`QwenVoiceSession.requestTaskAcceleration` 新增，与取消对称：点名任务、记录系统提示、活动标记）。
- 通道复用 App Group 标记模式：扩展侧 `AgentTaskControlIntent`（AppEnum 参数化：cancel / accelerate）只写标记，App 侧 `AgentTaskControlTapStore` 一次性消费、`AgentTaskControlActionParser` 未知标记忽略、`AgentTaskControlCoordinator`（defaults / apply 注入可测）应用动作并给出确认反馈（TTS + 镜片结果卡）；`MainAppView` 注册跨进程监听 + `applicationDidBecomeActive` 兜底消费。

### 新增：任务结果一键追问（Follow Up）

- 任务完成通知新增「追问」Action（锁屏结果 Live Activity 卡同步加「追问」按钮，iOS 17 交互按钮 + App Group 通道）：点按自动打开语音会话页并注入任务结果上下文，直接开口（如「展开第三条 / 再细一点」）即可基于结果继续追问——无需重述任务背景。
- 上下文恢复 `AgentTaskFollowUpRestorer`（纯逻辑可测）：优先用会话内存已有结果上下文，否则回退到持久化任务快照（`PersistedAgentTask` 新增 `resultText` 字段，旧快照兼容解码）取最近一条带详细结果的已完成任务；`QwenVoiceSession.restoreFollowUpContext` 注入（600 字截断、空白忽略），`VoiceAssistantRequest.followUpContext` 经语音页深链带入会话。
- 接线：`AgentTaskNotificationAction` 新增 `.followUp`（分类第三个 Action，带 `.foreground` 打开 App）→ 路由 `AgentTaskFollowUpCoordinator.requestFollowUp` → `VoiceAssistantRouter.requestVoiceSession` → `QwenVoiceView(initialFollowUpContext:)` 会话启动后注入；`AgentTaskFollowUpTapStore` / `AgentTaskFollowUpCoordinator.consumeIfNeeded`（defaults 注入可测），`MainAppView` 跨进程监听 + `applicationDidBecomeActive` 兜底。

### 新增：对话记录 Spotlight 系统搜索（Conversation Search）

- 对话记录（「问 JARVIS」结果 / 语音历史 / 聊天历史）接入 CoreSpotlight：与记忆 / 规则 / 清单 / 提醒 / 照片并列，系统搜索直达——标题为首条用户消息、描述为最后一条回复（空回复回退标题）、按时间倒序、持久档案不过期；记录删除后下次索引重建自动移除。
- 深链泛化：`AppNavigationDestination.agentAskRecord` 统一为 `.conversation(UUID)`（结果通知与 Spotlight 点按共用），`AgentHubView` 消费后直接呈现 `ConversationDetailView`（Hub 已打开时实时消费）；`SpotlightDestination.conversation` / `SpotlightIdentifierParser` 解析纯逻辑可测。

### 修复：UI 本地化一致性（Localization Consistency）

- 修复用户可见界面中的硬编码文案：记录页 Tab（Live AI / LeanEat / WordLearn）、实时对话页头「AI 实时对话」、输出语言说明、Google API / Gemini API 密钥标题、Agent 网关表单标签（主机 / 端口 / 会话 / 状态 / 网关 / 模型 / 对话，Qwen / OpenClaw / Hermes 表单共用）、推流倒计时、无设备引导页 4 条文案全部接入 `Localizable.strings`（品牌名 Ray-Ban Meta / OpenClaw / Hermes 保留原文）。
- 新增 19 个本地化键（中英一致，现 1386 键）；新增 `LocalizationKeyPresenceTests`（键存在性 + 双语言解析守卫，防键漂移）。

### 新增：问 JARVIS 结果通知继续追问（Ask Result Follow-up）

- 「问 JARVIS」后台结果通知新增「继续追问」按钮：锁屏 / 通知中心一键打开语音页，自动携带该条结果上下文（`AgentAskFollowUpContextResolver` 从归档记录取最后一条助手回复，缺记录时回退最近任务 / 会话上下文）；点按通知正文保持原有「查看详情」深链不变。
- `AgentAskResultNotificationCategory`（分类注册与任务通知同一注册点）、`AgentAskResultNotificationActionParser`（默认点按 → 详情 / 按钮 → 追问 / 未知忽略）、`AgentAskResultNotificationActionHandler`（路由协议注入）纯逻辑可测；结果通知投递时写入分类标识，后台问答 → 结果通知 → 锁屏追问形成完整闭环。

### 新增：任务结果卡聊天追问（Ask in Chat）

- 任务卡长按「在聊天中追问」（语音页 / 聊天页共享任务列表）：已完成且有结果的任务直接进入聊天页继续交流——聊天页就地载入（共享会话注入结果上下文 + 首条消息自动携带 `【任务结果】…【用户继续追问】…` 结构，一次性包装门），语音页则打开对应 Agent 聊天页（OpenClaw 任务 → OpenClaw 聊天，其余 → Hermes）并载入结果上下文；未完成任务 / 无结果任务不显示入口。
- 纯逻辑可测：`AgentTaskFollowUpOffer.isEligible`（仅已完成 + 非空结果）、`TaskFollowUpWrapGate`（一次性消费 / 重新武装）；包装文本复用 `QwenVoiceSession.followUpMessage`（既有 600 字截断）。

### 新增：对话详情聊天页继续追问（Continue in Chat）

- 对话记录详情页新增「在聊天中继续」按钮：以该记录水合到对应 Agent 聊天页继续交流（历史消息完整载入，后续新消息按当前聊天 Agent 落盘）——OpenClaw 记录 → OpenClaw 聊天；custom.* 记录 → 对应配置聊天（配置已删除回退 Hermes）；Hermes / 语音历史 / 问 JARVIS（agent-ask）→ Hermes 聊天。与「继续追问」（语音）并列，同一详情页两种续聊方式。
- 水合不再要求记录 Agent 标识与聊天页一致：`AgentConversationPersister.loadMessages(from:recordID:)` 按 ID 直接恢复（agent-ask 等无对应聊天分类的记录也能载入）；`ConversationChatKindResolver`（kind + 自定义配置映射，配置查询可注入）纯逻辑可测；`ConversationDetailView` 增传 `streamViewModel`，Hub / 记录页 / 系统深链三入口一致（`RecordsView` / `MainTabView` 透传）。

### 新增：对话详情继续追问（Conversation Follow-up）

- 对话记录详情页底部新增「继续追问」主按钮：以该对话最后一条助手回复为追问上下文打开语音会话（提取去首尾空白、不受末尾未回复用户消息影响；无可用回复时 `AgentTaskFollowUpCoordinator` 回退最近任务结果 / 会话上下文，任何情况都可进入语音页自由提问）。进入后语音（如「再展开说说」）经 `followUpMessage` 自动携带记录上下文给大脑，形成「查看记录 → 语音追问」闭环。
- 纯逻辑可测：`ConversationRecord.followUpContext`（最后一条助手回复提取 / 空白忽略 / 无助手回复返回 nil）、协调器注入优先于快照回退；按钮带轻触反馈与无障碍提示（`conversation.followup` / `conversation.followup.hint`）。

### 新增：眼镜端日历日程菜单（Glasses Calendar Menu）

- 镜片动作菜单新增「Calendar」入口（今天有未结束日程时动态出现，语音页 / 聊天页通用）：选中后列出今天日程（「15:00 评审」短标签按钮，标题超长截断加省略号，全天显示「all day / 全天」前缀），点按播报单条日程（镜片结果卡 + TTS，复用语音查询「今天 15:00-16:00 产品评审」文案），无日程提示「今天没有日程安排」，未授权提示开启日历权限；子菜单末尾固定「Back」返回主菜单。
- 纯逻辑可测：`AgentCalendarDisplayMapping`（今天未结束日程筛选 / 排序 / 数量上限、按钮短标签与截断、播报文案复用、菜单动态显隐的静默拉取与授权拉取），`AgentCalendarDayRange.todayRange` 今日半开区间。

### 新增：眼镜主页 HUD 今明日程摘要（Home HUD Calendar Summary）

- 镜片主页 HUD（Home）在未读行与 HomeKit 状态行之间新增今明两天日程摘要（最多 3 行）：今天日程在前、明天在后，按开始时间升序；单行格式「今天 15:00 产品评审」/「明天 全天 出游」（全天走「all day / 全天」前缀）；日历未授权时摘要自动隐藏（静默拉取、不弹权限），HomeKit 状态行与快捷按钮不变。
- 纯逻辑可测：`AgentDisplayHomeMapping.calendarLines / calendarLine`（今明日程筛选与排序 / 行数上限 / 其他日期排除 / 定时与全天格式），`AgentDisplayHomeLoader.state` 授权时拉取今明两天、未授权跳过。

### 新增：眼镜主页 HUD 进行中任务与提醒摘要（Home HUD Task & Reminder Lines）

- 镜片主页 HUD（Home）在未读行前新增两行摘要：进行中任务（1 个显示「任务：上传视频」，多个显示「任务：上传视频 等 2 项」，等待中 / 进行中计入，终态排除）与下一条提醒（「提醒 25分钟后 吃药」，周期提醒显示「每天 HH:mm」，无即将触发提醒自动隐藏）；任务与提醒均为本地数据源（`AgentTaskNotificationStore` / `AgentReminderStore`），加载零副作用。
- 纯逻辑可测：`AgentDisplayHomeMapping.taskLine`（空 / 单任务 / 多任务计数 / 空标题忽略 / 终态排除）、`reminderLine`（取最近一条 / 相对时间复用 / 无提醒隐藏），`AgentDisplayHomeLoader.state` 透传；新增 `agent.display.home.task.running / task.more / reminder` 三个本地化键（中英同步）。

### 修复：对话记录去重统一（Records Dedup）

- 「记录」页与 Hub「最近会话」时间线共用同一存储，但同一逻辑对话（恢复历史后继续 / 在聊天中继续）此前每次落盘都会生成新记录，导致时间线出现多条重叠记录。现统一为覆盖更新：`ConversationStorage.saveConversation` 改为同 ID 覆盖（先移除再置顶），聊天页恢复历史 / 新建会话时记录来源记录 ID（`AgentConversationPersister.latestRecord` + `makeRecord(recordID:)`），后续落盘复用该 ID 原地更新——同一对话在记录页与 Hub 时间线始终只有一条，最新内容置顶。
- 纯逻辑可测：`ConversationStorage` 同 ID 覆盖 / 置顶，`AgentConversationPersister.latestRecord` 最新匹配、`makeRecord(recordID:)` 复用 ID（聊天 / 语音转写两种入口）。

### 修复：移除 Time Sensitive 能力（个人团队 Release 构建可用）

- `com.apple.developer.usernotifications.time-sensitive` 属特殊能力，个人开发团队（自动签名）无法签发，无论 Debug / Release 使用该 entitlement 都会导致真机构建失败（报错 `Provisioning profile doesn't include the Time Sensitive Notifications capability`）。现彻底移除该能力：Release 与 Debug 统一使用 `HyperMetaAI/HyperMetaAI.entitlements`（HealthKit + App Groups），删除 `HyperMetaAI-TimeSensitive.entitlements`；失败任务通知由 `.timeSensitive` 回落普通 `.active` 级别（无 entitlement 时系统本就按普通通知处理），移除「失败任务紧急通知」二级开关与相关设置键；任务通知 Action / 分类 / 巡检闭环保持不变。

### 新增：后台问答结果通知（Ask Result Notification）

- Siri / 快捷指令 / 自动化在后台触发「问 JARVIS」时，结果以本地通知送达（回复截断 180 字；失败 / 超时 / 未配置网关也通知「JARVIS 未能回答」，复用既有文案）——后台问答不再只依赖 Siri 朗读，锁屏也能收到答案。
- 纯逻辑可测：`AgentAskResultPolicy.shouldNotify`（仅 App 不在前台 + 开关开启）、`AgentAskResultSettings`（默认开，defaults 可注入）、`AgentAskResultContent.content`（回复截断 / 空回复与空输入不通知 / 失败类标题与正文）、`AgentAskResultCoordinator.notifyIfNeeded`（notifier 注入：条件不满足不投递、一次性投递）。
- 投递走 `AgentAskResultNotifying` 协议（`SystemAgentAskResultNotifier` 真实实现检查通知授权），`AgentAskAppIntent.perform` 完成处接线（前台问答保持既有镜片渲染 + Siri 朗读，不重复打扰）；设置页「后台问答结果通知」开关（默认开）。

### 新增：管家快捷控制（Control Center 晨报 + Home Widget 语音按钮）

- Control Center 新增「播报晨报」控制（iOS 18+，与语音会话控制同一模式）：点按即写 App Group 请求标记，App 消费后走既有 URL 命令晨报路径——立即朗读今日晨报（日程 / 提醒 / 任务 / 未读通知摘要）并上镜片；`BriefingControl` + `BriefingControlIntent`（扩展侧只写标记），App 侧 `AgentBriefingRequestStore.consume`（defaults 可注入）与 `AgentBriefingControlCoordinator.consumeIfNeeded`（defaults / execute 可注入，一次性消费、跨进程 UserDefaults 监听 + 回前台补消费）。
- Home Widget 小尺寸（systemSmall）补上语音会话快捷按钮（开始 / 停止按会话状态切换，与中尺寸同一 Intent，紧凑图标 + 无障碍标签）。
- 纯逻辑可测：请求标记一次性消费（读到即清除）、协调器接线（标记存在执行一次、无标记不执行）。

### 新增：日程倒计时 Live Activity（Calendar Countdown）

- 系统日历有日程时（「明天下午 3 点评审」等），下一个即将开始的非全天日程在锁屏 / 灵动岛展示红色日历倒计时卡（大计时器系统自动走秒），开始后由系统日历 / 通知接力；与提醒倒计时并存时展示「更早触发」的那个（下一个安排语义），提醒结束后自动回落日程卡。
- 纯逻辑可测：`AgentCalendarCountdownPolicy.nextEvent`（未来 6 小时内最近一个非全天日程，忽略已开始 / 全天 / 超出窗口，边界可测）、`AgentLiveActivityStateMapper.calendarContent`（空标题 / 已开始返回 nil）；管理器新增日程槽位，`refresh` 提醒与日程按 `countdownFireDate` 更早者优先（字段由 `reminderFireDate` 泛化为 `countdownFireDate`）。
- 同步幂等：`AgentCalendarCountdownCoordinator.sync`（events / provider 可注入）——App 回前台重算、`EKEventStoreChanged` 系统通知监听（App 内增删改日程即时更新），未授权日历静默跳过（`AgentCalendarProviding` 拉取返回空）；设置页「任务锁屏显示」开关统一控制。
- 已知边界：后台到点时卡片以 `staleDate` 变暗停留，下次回前台自动清理（Live Activity 平台限制）。

### 新增：提醒倒计时卡锁屏交互按钮（Reminder Live Activity Actions）

- 锁屏提醒倒计时卡新增「稍后提醒 / 完成」两个交互按钮（iOS 17 `Button(intent:)`）：与提醒通知 Action 同一语义——「稍后提醒」在原触发时间基础上 +10 分钟重排，「完成」移除提醒并取消通知。
- 扩展侧 `AgentReminderControlIntent`（AppEnum 参数化 `AgentReminderActionOption`（snooze / complete）+ `AgentReminderRequestStore` 只写 App Group 标记，与审批 / 查看任务同一通道模式）；App 回前台 `applicationDidBecomeActive` 消费并经 `AgentReminderTapCoordinator` 应用到「当前展示的倒计时提醒」（即策略选中的最近一条一次性提醒），同时挂 UserDefaults 跨进程监听（后台存活时即时生效）。
- 纯逻辑可测：`AgentReminderTapHandler.handle`（snooze 延后语义 / complete 目标 / 未知标记忽略 / 无符合条件的提醒忽略 / 周期提醒不受影响）、`AgentReminderTapStore.consume`（一次性消费，defaults 可注入）、`AgentReminderTapCoordinator.consumeIfNeeded`（defaults / apply 注入：消费→处理→应用接线）。
- 无待处理提醒时按钮请求静默忽略；效果在下次回前台时应用（Live Activity 按钮无法从扩展进程直接更新活动，与既有按钮一致）。

### 新增：提醒倒计时 Live Activity（Reminder Countdown）

- 设置提醒（「十分钟后提醒我喝水」）后，最近一条一次性提醒在锁屏 / 灵动岛展示倒计时卡：标题 + 提醒内容 + 大号计时器（`Text(timerInterval:countsDown:)` 由系统自动走秒，对齐系统计时器 App 体验），到点由本地通知接力；周期提醒不占倒计时（通知照常）。
- 纯逻辑可测：`AgentReminderCountdownPolicy.nextReminder`（只选未来 6 小时内最近一条一次性提醒，忽略过期 / 周期 / 超出窗口，边界可测）、`AgentLiveActivityStateMapper.reminderContent`（空文本 / 已过时返回 nil）；管理器缓存化改造后 `AgentLiveActivityManager` 优先级（审批 > 提醒倒计时 > 任务进度 > 结果卡）与回落均可测（`resetStateForTesting`，测试不触碰 ActivityKit）。
- 同步幂等：提醒新增 / 取消 / 稍后提醒 / 完成全部经 `AgentReminderScheduler` 重算（`AgentReminderCountdownCoordinator.sync`），提醒到点（前台 `willPresent`）立即结束倒计时，App 回前台补同步清残留；Live Activity 关闭开关时全部静默降级。
- 设置页「任务锁屏显示」开关说明更新为覆盖提醒倒计时。

### 新增：Live Activity 审批按钮（Approval Live Activity Action）

- 审批待确认时，锁屏 Live Activity 显示「批准 / 拒绝」两个交互按钮（iOS 17 `Button(intent:)`，批准绿色主按钮 / 拒绝红色描边）——镜片审批卡的锁屏版，无需解锁进 App。
- 扩展进程只写 App Group 请求标记（`AgentApprovalControlIntent`，参数化 `AgentApprovalDecisionOption`（allow / deny）AppEnum + `AgentApprovalRequestStore`，与「查看任务」同一通道模式），App 回前台 `applicationDidBecomeActive` 消费标记并经 `QwenVoiceSession.respondToPermission` 提交当前审批决策（一次性，防重复提交；无待处理审批时静默忽略，决策结果由既有网关回发路径反馈到镜片 / Live Activity）。
- 主侧 `AgentApprovalTapStore.consume / consumeDecision`（可注入 defaults）纯逻辑可测：无请求 nil、allow / deny 映射、一次性消费、未知值忽略、键与扩展侧一致。

### 新增：任务 Live Activity 交互按钮（Live Activity Action）

- 任务终态（结果卡）时，锁屏 Live Activity 出现「查看任务」交互按钮（iOS 17 `Button(intent:)`；灵动岛按平台限制不承载交互）：点按打开 App 并深链到 Agent Hub 查看任务进度与结果。
- 扩展进程只写 App Group 请求标记（`AgentTaskViewControlIntent` + `AgentTaskViewRequestStore.requestViewTask`，与 Control Center 语音会话同一通道模式），App 回前台 `applicationDidBecomeActive` 消费标记并 `AppNavigationRouter.request(.agentHub)`（一次性消费，防重复弹窗）。
- 主侧消费 `AgentTaskViewRequestStore.consume`（可注入 defaults）纯逻辑可测：无请求默认 false、有请求消费一次即清除、键与扩展侧一致。

### 新增：JARVIS URL 命令协议（URL Command Router）

- `hypermetaai://` 深链从单一手势触发扩展为完整命令集，快捷指令 / 自动化 / 第三方工具可精确唤起 JARVIS：
  - `hypermetaai://trigger?gesture=wake` 手势触发（兼容既有协议）
  - `hypermetaai://ask?text=…&brain=hermes` 问 JARVIS（后台单轮问答，结果上镜片 + TTS 播报）
  - `hypermetaai://lens?text=…&speak=1` 文本上镜片（可选播报）
  - `hypermetaai://briefing` 立即播报今日晨报
- 纯逻辑可测：`AgentURLCommandParser`（命令矩阵、brain 缺省 / 未知回退 auto、空文本拒绝、百分号编码解码、未知 host / scheme 拒绝）、`AgentURLCommandRouter` 分发（Mock 执行器：trigger / ask / lens / briefing 矩阵，非命令 URL 返回 nil 不动作）。
- 真实执行 `SystemAgentURLCommandExecutor` 分发到既有服务（触发中心 / `AgentAskIntentHandler` / `AgentDisplayHub` / `AgentBriefingScheduler`），TTS 尊重语音回复开关与静默模式（显式触发不受专注静音）；`onOpenURL` 统一走命令路由，非 JARVIS 命令保留原 SDK 兜底。

### 新增：任务通知交互 Action（Task Notification Actions）

- 任务完成 / 失败通知支持两个快捷 Action：「查看结果」（打开 Agent Hub）与「10 分钟后提醒」（`UNTimeIntervalNotificationTrigger` 重发同一通知，可多次稍后提醒）。分类 `agent.task.category` 随后台巡检冷启动注册（`AgentTaskNotificationCategory`），`SystemAgentTaskNotifier` 投递时挂分类。
- 通知点按分发：`AgentReminderNotificationDelegate.didReceive` 先按分类分流任务通知（`AgentTaskNotificationActionParser` 解析：查看 / 稍后提醒 / 点按本体），执行器经 `AgentTaskNotificationActionRouting` / `AgentTaskNotificationScheduling` 协议注入（Mock 测试）。
- 深链：`AppNavigationDestination` 新增 `.agentHub`（任务通知「查看结果」经 `AppNavigationRouter` → 主 Tab 回首页 → `HyperMetaAIHomeView` 消费弹出 Agent Hub）。
- 纯逻辑可测：`AgentTaskNotificationActionParser`（标识符矩阵）、`AgentTaskSnoozeBuilder`（复用标题 / 正文 / userInfo，标识符后缀防冲突，非正间隔拒绝）、`AgentTaskNotificationActionHandler` 闭环（Mock 路由 / Mock 调度）。

### 新增：后台任务巡检（Background Task Inspector）

- JARVIS 后台巡检 Agent 任务：任务状态变化时 App 侧把结构化任务持久化为快照（`AgentTaskNotificationStore`，UserDefaults JSON），进后台提交 `BGAppRefreshTask`（`com.lunflux.hyper-meta-ai.task-inspect`，独立于晨报刷新），系统唤醒时对比「已通知任务」找出新进入终态（完成 / 失败）的任务推送本地通知——同一任务同一终态只通知一次，单次巡检最多 3 条、按更新时间倒序；等待中 / 进行中 / 已取消不打扰。
- 通知文案跟随 App 语言（完成 / 失败标题 + 任务标题正文，空标题回退通用文案），经 `AgentBackgroundNotifying` 协议注入（`SystemAgentTaskNotifier` 真实实现，权限未授权静默跳过）。
- 纯逻辑可测：`AgentBackgroundTaskInspector.pendingNotifications`（去重 / 封顶 / 排序）、`AgentTaskNotificationStore`（快照往返 / 已通知 ID 去重与上限 100 / 巡检时间）、`AgentBackgroundTaskRunner`（Mock 通知器闭环：通知一次、二次巡检去重、失败文案、空任务不打扰）。
- 接线：`QwenVoiceSession.upsertTask` / `start` / `clearTaskFeed` 三处同步快照；App 冷启动注册、进后台提交（`HomeScreenShortcutActions`）；设置页「后台任务通知」分区（开关默认开启，直连 UserDefaults）。

### 新增：专注模式联动（Focus Mode）

- JARVIS 感知系统专注模式（`FocusStatusCenter`，首次使用需授权）：专注中主动打扰自动避让——通知播报整体暂停（含镜片卡 / 触觉，且不写入已播报去重，专注结束后「有什么通知」仍可汇总到），连接问候 / 提醒 / 任务完成等主动语音静音（镜片卡片保留）；你显式询问的回复始终正常播报。
- 纯决策 `AgentFocusPolicy.shouldSuppress`（未知状态 fail-open 不误伤）叠加进 `AgentQuietAnnouncementPolicy.shouldSpeak`（新增 `respectFocus` / `isFocusActive` 参数与 `shouldSpeakProactive()` 快捷入口），9 个主动播报点统一迁移；系统状态经 `AgentFocusProviding` 协议隔离（`SystemFocusService` 真实实现，测试注入 Mock）。
- 设置页「专注模式」分区：尊重专注模式总开关 + 专注时暂停通知播报 / 专注时静音主动语音两个分项（默认全开，直连 UserDefaults），授权状态行（未授权一键授权 / 已拒绝引导系统设置）。

### 新增：问 JARVIS（Agent Ask App Intent）

- Siri / 快捷指令 / 自动化把一句话交给当前大脑：`AgentAskAppIntent`（`openAppWhenRun = false` 后台单轮问答，无需打开 App），可选大脑（自动 / Hermes / OpenClaw / 自定义 Agent），Auto 复用既有任务型指令 → OpenClaw、其余 → Hermes 路由。
- Siri 短语直达（`AppShortcutsProvider`）：对 Siri 说「问 Hyper Meta AI」即可直接触发（中文 / 英文共 4 条短语，`AgentAskAppIntent` 参数化注册，无需配置快捷指令）；短语触发后 Siri 追问「你想让 JARVIS 做什么？」（`$message.requestValue` 取值）再执行问答。
- 回复直达：Siri 对话直接朗读回复（超 500 字截断保护）；眼镜连接且 App 在前台时，完整回复同步渲染到镜片结果卡。
- 执行器 `AgentAskIntentHandler`：空输入拦截、40s 超时保护（`.timedOut`）、首次回调即终态（防重入）；`AgentAskGateway` 按大脑分发（OpenClaw 走 `onChatEvent` 快照 + `[[FINAL]]` 解析、用完恢复原监听；自定义 Agent 本地工具走既有审批链）；结果判定与应答文案 `AgentAskIntentFormatter` 纯逻辑可测。
### 新增：JARVIS 通知播报管家（Notification Butler）

- 前台新通知摘要播报：App 前台收到第三方通知时（`UNUserNotificationCenter` 代理 `willPresent` 拦截，非提醒类通知），按「播报时机」策略（关闭 / 仅语音会话中 / App 前台）TTS 播报 + 镜片结果卡 + 触觉反馈；已播报 ID 进 `AgentNotificationInbox`（上限 50，防重复），尊重静默模式与回复开关。
- 语音 / 聊天双入口「有什么通知 / 未读消息 / 播报通知 / 清空通知」本地拦截：`AgentNotificationCommandParser`（保守关键词，长度上限防误吞）→ `AgentNotificationExecutor`（统一权限流转：未决定先请求、拒绝引导设置）→ 未读汇总播报（条数 / 标题 / 标题+正文三级隐私，`AgentNotificationSummarizer` 截断 + 内部按时间倒序）或清空通知中心（返回清空条数）。
- 隐私分级：`AgentNotificationPrivacy`（仅条数 / 标题 / 标题+正文，正文截断 60 字符），iOS 不向第三方开放通知来源 App 名（`UNNotification.source` 仅 macOS），汇总按内容呈现——设置页说明文案如实标注。
- 设置页「通知播报管家」分区：播报时机与播报内容 Picker（直连 UserDefaults 即时生效）+ 最近一次播报预览；`SystemNotificationService` 走 `AgentNotificationProviding` 协议注入（测试用 Mock）。

### 新增：JARVIS 触发中心（Wearable Trigger Hub）

- 统一触发事件模型与路由：眼镜物理触发（镜腿单击开始/再次单击结束、长按结束，经 DAT 会话状态推断）、镜片菜单（Display onTap）、Mock 模拟镜腿、iPhone 背部轻点 / 操作按钮 / Siri / 快捷指令（App Intent）、通用 URL（`hypermetaai://trigger?gesture=wake`）、App 内演示——全部收敛到 `AgentWearableTriggerCenter` 同一路由与审计日志。
- 去抖防双触发：同一来源同一手势 0.8s 内重复触发自动忽略（防 Back Tap 与镜片双触发）；无活动会话时 endTurn/repeat 返回「已忽略」；双击与物理快门事件记录为 SDK 不支持；`AgentWearableTriggerRouter` 纯逻辑可测。
- 触发日志：每次触发（来源 · 手势 · 结果 · 时间）持久化到 `AgentWearableLogStore`（上限 50 条），外设中心展示相对时间文案，`AgentWearableLogFormatter` 纯逻辑可测。
- 「触发 JARVIS」App Intent（`WearableTriggerAppIntent`）：动作参数化（唤醒 / 打断 / 恢复 / 结束回合 / 拍照识图 / 重听回复），背部轻点与操作按钮绑定快捷指令即可在任何界面唤醒 JARVIS；重听回复经 NotificationCenter 由语音页 / 聊天页消费，与镜片 Repeat 共用实现。
- 外设中心页（设置 → 设备管理）：眼镜连接状态卡、演示触发（与真实触发同路由）、Apple 原生触发源配置引导（背部轻点 / 操作按钮 / Siri / 快捷指令）、触发日志（一键清空）。
- 研究结论沉淀：`docs/MetaRaybanTriggers.md` 记录 DAT SDK v0.9.0 触发事件边界（可拿到：会话状态 / 相机 / Display onTap / Mock captouch；拿不到：原始镜腿、双击与快门事件）与 Apple 原生替代触发映射。

### 新增：智能家居管家（HomeKit）

- 语音 / 聊天双入口直接控制系统家庭配件：「打开客厅灯 / 把客厅灯打开 / 开启卧室灯」开灯、「关掉 / 把…关掉 / 关上」关灯、「把客厅灯调到50% / 亮度调到30 / 调亮 / 调暗」调亮度（相对调节：当前 ±20，无亮度时 100 / 30）、「把空调调到26度 / 空调温度设为24」调温、「关掉所有灯 / 把所有灯关掉 / 全屋的灯打开」全屋动作（灯 / 开关分类，默认跳过门锁与未知类型）、「客厅灯什么状态 / 空调温度多少 / 卧室灯开着吗」状态查询、「家里有什么设备」列表。
- 保守解析防误吞：目标必须含家居关键词（灯 / 开关 / 空调 / 房间名等 24 词），「打开App / 打开微信」不会命中；`AgentHomeKitCommandParser` / `AgentHomeKitTargetMatcher`（设备名 / 房间名 / 尾缀归一模糊匹配，可多设备） / `AgentHomeKitFormatter` / `AgentHomeKitExecutor`（亮暗相对计算、全屋过滤门锁与未知类型）纯逻辑可测。
- HomeKit 自 iOS 11 起无需 entitlement，仅补 Info.plist `NSHomeKitUsageDescription`；`HMHomeManager` 走 `AgentHomeKitProviding` 协议注入（测试用 Mock），`HomeKitHomeService` 映射灯 / 开关 / 空调 / 风扇 / 插座 / 门锁 / 未知七类配件与电源 / 亮度 / 温度 / 锁状态特征。

### 新增：Qwen 语音前端 2.0（内置 qwen-audio-agent v1.10.1 最新稳定实现）

- 实时语音模型档案升级（镜像 `shared/realtime-model-catalog.mjs` v1.10.1）：默认 `qwen-audio-3.0-realtime-plus`，可选 `qwen-audio-3.0-realtime-flash` / `qwen3.5-omni-flash-realtime` / `qwen3.5-omni-plus-realtime`；Audio 默认 `longanqian + smart_turn`，Omni 默认 `Ethan + semantic_vad`，两族音色覆盖独立；适配 Omni 服务端替换客户端 conversation item ID 的确认行为。模型能力保留图像标记，但当前 App Realtime 传输仍只开放文本与音频。
- 网关协议对齐 v1.8：`connect` 携带会话级 `provider` 与 `wakeWordOnly`（仅唤醒模式）、新增客户端 `sleep` / `wake` 事件、解析服务端 `client.state`（sleeping → 进入休眠等待唤醒）；`QwenGatewayService.requestSleep() / requestWake()`。
- 语音唤醒词（JARVIS 常驻）：会话休眠后由 App 原生监听 iPhone 麦克风（Speech framework 中文识别，对应桌面版网关侧 sherpa-onnx 监听），说「你好千问」自动唤醒并恢复聆听；`QwenWakeWordMatcher`（归一化变体匹配）与 `QwenWakeSessionController`（idle→sleeping→listening→waking 状态机，监听启动失败回落）纯逻辑可测，监听器协议化可注入 Mock。
- iOS 原生交互：语音页新增「语音唤醒词」开关与休眠/唤醒状态卡（聆听波形 + 实时转写 + 一键唤醒/休眠），网关配置页新增「Qwen 语音前端」模型选择（Audio 纯语音 / Omni 多模态分组）；Omni 实时直连默认升级到 `qwen3.5-omni-flash-realtime`（用户选 Audio 家族时自动回退 Omni 默认，保住传图能力）。

### 测试与工程

- 单元测试 1167 例全绿（`HyperMetaAITests`）；CI：模拟器测试 / 仓库检查 / 发布工作流。
- `Scripts/run-ios-tests.sh` 默认串行执行（`PARALLEL_TESTING=1` 可开启并行），避免全量负载下模拟器偶发挂起。
- 文档：`docs/interaction-design.md`（眼镜 × Agent HCI 方案）、`docs/privacy-data-flow.md`（隐私/权限/数据流）、`docs/device-regression-baseline.md`（真机回归基线）、`docs/setup-and-troubleshooting.md`（兼容性/安装/排查）。
- 发布准备：`docs/testflight-plan.md`（TestFlight 分阶段测试与放行门禁）、`docs/app-store-release-plan.md`（App Store 提审计划）、`docs/app-store-metadata.md`（提审元数据草稿）、`docs/privacy-policy-zh.md` / `docs/privacy-policy-en.md`（公开隐私政策草稿）、`Scripts/ExportOptions-AppStore.plist` 与 `.github/workflows/testflight.yml`（手动 TestFlight 上传）；补齐本地网络权限文案。
- 会话记录语言元数据改为从 App 语言设置读取（`LanguageManager.languageCode`，zh-CN/en 映射可测），移除 Omni 实时会话硬编码。
- 视图层本地化清零：直播/记录/权限/首页/会话详情/LeanEat/Omni 实时/视觉识别/设置输出语言与画质档位等全部硬编码中文转为键（新增 `leaneat.*` / `omni.*` / `vision.*` / `settings.quality.*` / `common.*` / `stream.step*` 等 40+ 中英键），en/zh 键集合完全一致。
