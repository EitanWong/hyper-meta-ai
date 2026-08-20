import XCTest
@testable import HyperMetaAI

@MainActor
final class VoiceAssistantRouterTests: XCTestCase {

  override func setUp() {
    super.setUp()
    // 避免测试触发真实网关 / 音频副作用
    VoiceAssistantRouter.shared.wakeExecutor = {}
  }

  override func tearDown() {
    VoiceAssistantRouter.shared.wakeExecutor = { QwenVoiceSession.shared.wake() }
    VoiceAssistantRouter.shared.consumeVoiceSessionRequest()
    VoiceControlRequestStore.clear()
    super.tearDown()
  }

  func testRequestThenConsume() {
    let router = VoiceAssistantRouter.shared
    XCTAssertFalse(router.isVoiceSessionRequested)

    router.requestVoiceSession()
    XCTAssertTrue(router.isVoiceSessionRequested)

    let request = router.consumeVoiceSessionRequest()
    XCTAssertNil(request?.brain)
    XCTAssertNil(request?.instruction)
    XCTAssertFalse(router.isVoiceSessionRequested)
  }

  func testConsumeIsIdempotent() {
    let router = VoiceAssistantRouter.shared
    XCTAssertNil(router.consumeVoiceSessionRequest())
    XCTAssertFalse(router.isVoiceSessionRequested)
  }

  func testRequestWithBrainAndInstruction() {
    let router = VoiceAssistantRouter.shared
    router.requestVoiceSession(brain: .hermes, instruction: "帮我查一下航班")

    let request = router.consumeVoiceSessionRequest()
    XCTAssertEqual(request?.brain, .hermes)
    XCTAssertEqual(request?.instruction, "帮我查一下航班")
    XCTAssertFalse(router.isVoiceSessionRequested)
  }

  func testRepeatedRequestOverwritesPending() {
    let router = VoiceAssistantRouter.shared
    router.requestVoiceSession(brain: .qwen, instruction: "第一条")
    router.requestVoiceSession(brain: .openclaw, instruction: "第二条")

    let request = router.consumeVoiceSessionRequest()
    XCTAssertEqual(request?.brain, .openclaw)
    XCTAssertEqual(request?.instruction, "第二条")
  }

  func testIntentRequestRoutesToRouter() async throws {
    XCTAssertFalse(VoiceAssistantRouter.shared.isVoiceSessionRequested)

    var intent = VoiceAssistantAppIntent()
    intent.brain = .hermes
    intent.instruction = "查一下航班"
    _ = try await intent.perform()

    XCTAssertTrue(VoiceAssistantRouter.shared.isVoiceSessionRequested)
    XCTAssertEqual(VoiceAssistantRouter.shared.pendingRequest?.brain, .hermes)
    XCTAssertEqual(VoiceAssistantRouter.shared.pendingRequest?.instruction, "查一下航班")
    VoiceAssistantRouter.shared.consumeVoiceSessionRequest()
    XCTAssertFalse(VoiceAssistantRouter.shared.isVoiceSessionRequested)
  }

  func testIntentCanExplicitlyDisableBackendAgent() async throws {
    var intent = VoiceAssistantAppIntent()
    intent.brain = .none
    intent.instruction = "只用语音前台回答"

    _ = try await intent.perform()

    XCTAssertEqual(VoiceAssistantRouter.shared.pendingRequest?.brain, .none)
    XCTAssertEqual(VoiceAssistantRouter.shared.pendingRequest?.instruction, "只用语音前台回答")
  }

  func testIntentWithoutParametersKeepsDefaults() async throws {
    let intent = VoiceAssistantAppIntent()
    _ = try await intent.perform()

    XCTAssertTrue(VoiceAssistantRouter.shared.isVoiceSessionRequested)
    XCTAssertNil(VoiceAssistantRouter.shared.pendingRequest?.brain)
    XCTAssertNil(VoiceAssistantRouter.shared.pendingRequest?.instruction)
    VoiceAssistantRouter.shared.consumeVoiceSessionRequest()
  }

  func testStopIntentWhenSessionIdle() async throws {
    // 测试环境会话未激活：停止 intent 应正常返回且不崩溃
    let intent = StopVoiceAssistantAppIntent()
    _ = try await intent.perform()
  }

  func testTaskStatusFormatterPrefersSummary() {
    let summary = "任务「查航班」进行中：已查询 3 家航司"
    XCTAssertEqual(
      VoiceTaskStatusFormatter.dialog(summary: summary, runningCount: 2),
      summary
    )
  }

  func testTaskStatusFormatterFallsBackToCount() {
    XCTAssertEqual(
      VoiceTaskStatusFormatter.dialog(summary: nil, runningCount: 3),
      String(format: "voice.intent.task.active".localized, 3)
    )
  }

  func testTaskStatusFormatterWhenIdle() {
    XCTAssertEqual(
      VoiceTaskStatusFormatter.dialog(summary: nil, runningCount: 0),
      "voice.intent.task.none".localized
    )
  }

  func testTaskStatusIntentWhenSessionIdle() async throws {
    // 测试环境会话未激活：后台查询 intent 应正常返回且不崩溃
    let intent = VoiceTaskStatusIntent()
    _ = try await intent.perform()
  }

  func testControlStoreRequestThenConsume() {
    XCTAssertNil(VoiceControlRequestStore.consume())

    VoiceControlRequestStore.request(.start)
    XCTAssertEqual(VoiceControlRequestStore.consume(), .start)
    XCTAssertNil(VoiceControlRequestStore.consume())

    VoiceControlRequestStore.request(.stop)
    XCTAssertEqual(VoiceControlRequestStore.consume(), .stop)
  }

  func testControlStoreWakeRoundTrip() {
    XCTAssertNil(VoiceControlRequestStore.consume())
    VoiceControlRequestStore.request(.wake)
    XCTAssertEqual(VoiceControlRequestStore.consume(), .wake)
    XCTAssertNil(VoiceControlRequestStore.consume())
    // 未知原始值回退停止（旧扩展写死的旧值兼容）
    let defaults = VoiceControlRequestStore.defaults
    defaults.set("unknown-action", forKey: VoiceControlRequestStore.requestKey)
    XCTAssertEqual(VoiceControlRequestStore.consume(), .stop)
  }

  func testTaskReplyRoutesVoiceSessionWithInstruction() {
    XCTAssertFalse(VoiceAssistantRouter.shared.isVoiceSessionRequested)
    AgentTaskNotificationActionRouter.shared.replyToJARVIS(text: "帮我把牛奶加到购物单")
    let request = VoiceAssistantRouter.shared.consumeVoiceSessionRequest()
    XCTAssertEqual(request?.instruction, "帮我把牛奶加到购物单")
    XCTAssertNil(request?.brain)
    XCTAssertFalse(VoiceAssistantRouter.shared.isVoiceSessionRequested)
  }

  func testAskResultReplyRoutesVoiceSessionWithContext() {
    XCTAssertFalse(VoiceAssistantRouter.shared.isVoiceSessionRequested)
    let original = AgentAskResultNotificationActionRouter.shared.resolveContext
    defer { AgentAskResultNotificationActionRouter.shared.resolveContext = original }
    AgentAskResultNotificationActionRouter.shared.resolveContext = { _ in "这是一株健康的绿萝。" }
    AgentAskResultNotificationActionRouter.shared.replyToJARVIS(
        text: "那它多久浇一次水？",
        recordID: UUID()
    )
    let request = VoiceAssistantRouter.shared.consumeVoiceSessionRequest()
    XCTAssertEqual(request?.instruction, "那它多久浇一次水？")
    XCTAssertEqual(request?.followUpContext, "这是一株健康的绿萝。", "回复携带结果上下文（继续追问语义）")
    XCTAssertNil(request?.brain)
    XCTAssertFalse(VoiceAssistantRouter.shared.isVoiceSessionRequested)
  }

  func testAskResultReplyWithoutContextStillRoutesInstruction() {
    XCTAssertFalse(VoiceAssistantRouter.shared.isVoiceSessionRequested)
    let original = AgentAskResultNotificationActionRouter.shared.resolveContext
    defer { AgentAskResultNotificationActionRouter.shared.resolveContext = original }
    AgentAskResultNotificationActionRouter.shared.resolveContext = { _ in nil }
    AgentAskResultNotificationActionRouter.shared.replyToJARVIS(
        text: "把牛奶加到购物单",
        recordID: nil
    )
    let request = VoiceAssistantRouter.shared.consumeVoiceSessionRequest()
    XCTAssertEqual(request?.instruction, "把牛奶加到购物单")
    XCTAssertNil(request?.followUpContext)
    XCTAssertFalse(VoiceAssistantRouter.shared.isVoiceSessionRequested)
  }

  func testControlWakeMapsToVoiceSession() {
    XCTAssertFalse(VoiceAssistantRouter.shared.isVoiceSessionRequested)
    VoiceControlRequestStore.request(.wake)
    VoiceAssistantRouter.shared.consumeControlRequestIfNeeded()
    // wake 需要 App 前台呈现语音页（与 start 同一路由语义）
    XCTAssertTrue(VoiceAssistantRouter.shared.isVoiceSessionRequested)
    VoiceAssistantRouter.shared.consumeVoiceSessionRequest()
    XCTAssertFalse(VoiceAssistantRouter.shared.isVoiceSessionRequested)
  }

  func testControlRequestMapsToVoiceSession() {
    XCTAssertFalse(VoiceAssistantRouter.shared.isVoiceSessionRequested)

    VoiceControlRequestStore.request(.start)
    VoiceAssistantRouter.shared.consumeControlRequestIfNeeded()
    XCTAssertTrue(VoiceAssistantRouter.shared.isVoiceSessionRequested)

    VoiceAssistantRouter.shared.consumeVoiceSessionRequest()
    XCTAssertFalse(VoiceAssistantRouter.shared.isVoiceSessionRequested)
  }

  func testControlStopWithoutActiveSessionIsSafe() {
    VoiceControlRequestStore.request(.stop)
    VoiceAssistantRouter.shared.consumeControlRequestIfNeeded()
    XCTAssertFalse(VoiceAssistantRouter.shared.isVoiceSessionRequested)
  }
}
