import XCTest
@testable import HyperMetaAI

@MainActor
final class AgentBrainTests: XCTestCase {

  override func setUp() {
    super.setUp()
    UserDefaults.standard.removeObject(forKey: AgentRoutingSettings.customTaskKeywordsKey)
    UserDefaults.standard.removeObject(forKey: AgentRoutingSettings.customChatKeywordsKey)
    CustomAgentStore.clear()
    AgentBrainSettings.selectedCustomAgentID = nil
  }

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: AgentRoutingSettings.customTaskKeywordsKey)
    UserDefaults.standard.removeObject(forKey: AgentRoutingSettings.customChatKeywordsKey)
    CustomAgentStore.clear()
    AgentBrainSettings.selectedCustomAgentID = nil
    super.tearDown()
  }

  func testIsForwardingOnlyForNonQwenBrains() {
    XCTAssertTrue(AgentBrainRouter.isForwarding(to: .auto))
    XCTAssertFalse(AgentBrainRouter.isForwarding(to: .qwen))
    XCTAssertTrue(AgentBrainRouter.isForwarding(to: .hermes))
    XCTAssertTrue(AgentBrainRouter.isForwarding(to: .openclaw))
    XCTAssertTrue(AgentBrainRouter.isForwarding(to: .custom))
  }

  func testOpenClawEventParserSplitsFinal() {
    let partial = AgentBrainEventParser.parseOpenClawEvent("正在查询")
    XCTAssertFalse(partial.isFinal)
    XCTAssertEqual(partial.text, "正在查询")

    let final = AgentBrainEventParser.parseOpenClawEvent("[[FINAL]]查询结果：上海 25 度")
    XCTAssertTrue(final.isFinal)
    XCTAssertEqual(final.text, "查询结果：上海 25 度")
  }

  func testOpenClawEventParserHandlesEmptyFinal() {
    let final = AgentBrainEventParser.parseOpenClawEvent("[[FINAL]]")
    XCTAssertTrue(final.isFinal)
    XCTAssertEqual(final.text, "")
  }

  func testBrainSettingsRoundtrip() {
    let original = AgentBrainSettings.selected
    AgentBrainSettings.selected = .hermes
    XCTAssertEqual(AgentBrainSettings.selected, .hermes)
    AgentBrainSettings.selected = .openclaw
    XCTAssertEqual(AgentBrainSettings.selected, .openclaw)
    AgentBrainSettings.selected = original
    XCTAssertEqual(AgentBrainSettings.selected, original)
  }

  func testBrainDisplayNames() {
    XCTAssertEqual(AgentBrain.auto.displayName, "Auto")
    XCTAssertEqual(AgentBrain.qwen.displayName, "Qwen")
    XCTAssertEqual(AgentBrain.hermes.displayName, "Hermes")
    XCTAssertEqual(AgentBrain.openclaw.displayName, "OpenClaw")
    XCTAssertEqual(AgentBrain.custom.displayName, "Custom Agent")
    XCTAssertEqual(AgentBrain.custom.symbolName, "globe")
  }

  func testResolvedBrainKeepsCustomSelection() {
    XCTAssertEqual(AgentBrainRouter.resolvedBrain("帮我查一下", selection: .custom), .custom)
    XCTAssertEqual(AgentBrainRouter.resolvedBrain("你好", selection: .custom), .custom)
  }

  func testCustomAgentIDSettingsRoundtrip() {
    let id = UUID()
    XCTAssertNil(AgentBrainSettings.selectedCustomAgentID)
    AgentBrainSettings.selectedCustomAgentID = id
    XCTAssertEqual(AgentBrainSettings.selectedCustomAgentID, id)
    AgentBrainSettings.selectedCustomAgentID = nil
    XCTAssertNil(AgentBrainSettings.selectedCustomAgentID)
  }

  func testCustomAgentConfigSelection() {
    XCTAssertNil(AgentBrainRouter.customAgentConfig(), "无配置时返回 nil")
    let first = CustomAgentConfig(name: "A", baseURL: "http://127.0.0.1:1/v1", model: "m")
    let second = CustomAgentConfig(name: "B", baseURL: "http://127.0.0.1:2/v1", model: "m")
    CustomAgentStore.add(first)
    CustomAgentStore.add(second)
    AgentBrainSettings.selectedCustomAgentID = first.id
    XCTAssertEqual(AgentBrainRouter.customAgentConfig()?.id, first.id, "优先用户选择")
    AgentBrainSettings.selectedCustomAgentID = nil
    XCTAssertEqual(AgentBrainRouter.customAgentConfig()?.id, second.id, "未选择时回退列表首个（最新在前）")
    AgentBrainSettings.selectedCustomAgentID = UUID()
    XCTAssertEqual(AgentBrainRouter.customAgentConfig()?.id, second.id, "配置已删除时回退列表首个")
  }

  // MARK: - 意图路由分类

  func testRouteTaskCommandsToOpenClaw() {
    XCTAssertEqual(AgentBrainRouter.route("帮我订一张去上海的机票"), .openclaw)
    XCTAssertEqual(AgentBrainRouter.route("查一下明天的天气"), .openclaw)
    XCTAssertEqual(AgentBrainRouter.route("帮我写一份周报并保存"), .openclaw)
    XCTAssertEqual(AgentBrainRouter.route("设置一个下午三点的提醒"), .openclaw)
    XCTAssertEqual(AgentBrainRouter.route("翻译这段英文并总结"), .openclaw)
  }

  func testRouteShortChatToQwen() {
    XCTAssertEqual(AgentBrainRouter.route("你好"), .qwen)
    XCTAssertEqual(AgentBrainRouter.route("早上好"), .qwen)
    XCTAssertEqual(AgentBrainRouter.route("谢谢"), .qwen)
    XCTAssertEqual(AgentBrainRouter.route("在吗"), .qwen, "短文本默认实时闲聊")
    XCTAssertEqual(AgentBrainRouter.route("   "), .qwen, "空白文本按闲聊处理")
  }

  func testRouteKnowledgeQuestionToHermes() {
    XCTAssertEqual(AgentBrainRouter.route("为什么天空是蓝色的？"), .hermes)
    XCTAssertEqual(AgentBrainRouter.route("解释一下什么是区块链"), .hermes)
  }

  func testResolvedBrainAutoRoutesTaskToOpenClaw() {
    XCTAssertEqual(
      AgentBrainRouter.resolvedBrain("帮我查一下快递到哪里了", selection: .auto),
      .openclaw
    )
  }

  func testResolvedBrainAutoRoutesOtherToHermes() {
    XCTAssertEqual(
      AgentBrainRouter.resolvedBrain("为什么天空是蓝色的？", selection: .auto),
      .hermes
    )
    XCTAssertEqual(
      AgentBrainRouter.resolvedBrain("你好", selection: .auto),
      .hermes,
      "Auto 是转发模式：闲聊也走 Hermes（Qwen 原生需手动选择）"
    )
  }

  func testResolvedBrainNonAutoReturnsSelection() {
    XCTAssertEqual(AgentBrainRouter.resolvedBrain("帮我查天气", selection: .qwen), .qwen)
    XCTAssertEqual(AgentBrainRouter.resolvedBrain("帮我查天气", selection: .hermes), .hermes)
    XCTAssertEqual(AgentBrainRouter.resolvedBrain("你好", selection: .openclaw), .openclaw)
  }

  // MARK: - 自定义路由关键词

  func testRoutingSettingsAddAndRemoveTaskKeyword() {
    XCTAssertTrue(AgentRoutingSettings.addTaskKeyword("帮我订"))
    XCTAssertEqual(AgentRoutingSettings.customTaskKeywords, ["帮我订"])
    XCTAssertFalse(AgentRoutingSettings.addTaskKeyword("帮我订"), "重复词应被拒绝")
    XCTAssertFalse(AgentRoutingSettings.addTaskKeyword("   "), "空白词应被拒绝")
    XCTAssertTrue(AgentRoutingSettings.addTaskKeyword(" 买机票 "), "首尾空白应被去除")
    XCTAssertEqual(AgentRoutingSettings.customTaskKeywords.last, "买机票")
    XCTAssertEqual(AgentRoutingSettings.customTaskKeywords.count, 2)

    XCTAssertTrue(AgentRoutingSettings.removeTaskKeyword("帮我订"))
    XCTAssertFalse(AgentRoutingSettings.removeTaskKeyword("不存在的词"))
    XCTAssertEqual(AgentRoutingSettings.customTaskKeywords.count, 1)
  }

  func testRoutingSettingsAddAndRemoveChatKeyword() {
    XCTAssertTrue(AgentRoutingSettings.addChatKeyword("在吗"))
    XCTAssertEqual(AgentRoutingSettings.customChatKeywords, ["在吗"])
    XCTAssertTrue(AgentRoutingSettings.removeChatKeyword("在吗"))
    XCTAssertTrue(AgentRoutingSettings.customChatKeywords.isEmpty)
  }

  func testRoutingSettingsPersistRoundtrip() {
    AgentRoutingSettings.addTaskKeyword("帮我订")
    AgentRoutingSettings.addChatKeyword("在吗")
    // 从 UserDefaults 重新读取
    XCTAssertEqual(
      UserDefaults.standard.stringArray(forKey: AgentRoutingSettings.customTaskKeywordsKey),
      ["帮我订"]
    )
    XCTAssertEqual(
      UserDefaults.standard.stringArray(forKey: AgentRoutingSettings.customChatKeywordsKey),
      ["在吗"]
    )
  }

  func testRouteUsesCustomTaskKeyword() {
    XCTAssertEqual(AgentBrainRouter.route("申请一笔项目报销"), .hermes, "无自定义词时默认走 Hermes")
    AgentRoutingSettings.addTaskKeyword("申请")
    XCTAssertEqual(AgentBrainRouter.route("申请一笔项目报销"), .openclaw)
  }

  func testRouteUsesCustomChatKeyword() {
    XCTAssertEqual(AgentBrainRouter.route("老铁你今晚在不在呀"), .hermes)
    AgentRoutingSettings.addChatKeyword("在不在")
    XCTAssertEqual(AgentBrainRouter.route("老铁你今晚在不在呀"), .qwen)
  }

  func testRouteIgnoresCustomKeywordAfterRemoval() {
    AgentRoutingSettings.addTaskKeyword("申请")
    AgentRoutingSettings.removeTaskKeyword("申请")
    XCTAssertEqual(AgentBrainRouter.route("申请一笔项目报销"), .hermes, "移除自定义词后不应再路由 OpenClaw")
  }

  // MARK: - 回合错误分类

  func testClassifyVoiceFrontendUnavailable() {
    let error = AgentTurnErrorClassifier.classify(
      connectionState: .failed("Voice front end unavailable")
    )
    XCTAssertEqual(error?.kind, .voiceUnavailable)
    XCTAssertEqual(error?.messageKey, "agent.error.voice.unavailable")
    XCTAssertEqual(error?.recoveryKey, "agent.error.recovery.wake")
  }

  func testClassifyVoiceSleeping() {
    let error = AgentTurnErrorClassifier.classify(
      connectionState: .failed("Voice front end is sleeping")
    )
    XCTAssertEqual(error?.kind, .voiceUnavailable)
  }

  func testClassifyGatewayUnreachable() {
    let error = AgentTurnErrorClassifier.classify(
      connectionState: .failed("Invalid gateway URL")
    )
    XCTAssertEqual(error?.kind, .gatewayUnreachable)
    XCTAssertEqual(error?.messageKey, "agent.error.gateway.unreachable")
    XCTAssertEqual(error?.recoveryKey, "agent.error.recovery.wake")
  }

  func testClassifyNonFailedStatesReturnsNil() {
    XCTAssertNil(AgentTurnErrorClassifier.classify(connectionState: .connected))
    XCTAssertNil(AgentTurnErrorClassifier.classify(connectionState: .connecting))
    XCTAssertNil(AgentTurnErrorClassifier.classify(connectionState: .disconnected))
  }

  func testIdleTimeoutError() {
    let error = AgentTurnErrorClassifier.idleTimeout()
    XCTAssertEqual(error.kind, .idleTimeout)
    XCTAssertEqual(error.messageKey, "agent.error.idle.timeout")
    XCTAssertEqual(error.recoveryKey, "agent.error.recovery.tap")
  }

  func testDeviceDisconnectedError() {
    let error = AgentTurnErrorClassifier.deviceDisconnected()
    XCTAssertEqual(error.kind, .deviceDisconnected)
    XCTAssertEqual(error.messageKey, "agent.error.device.disconnected")
    XCTAssertEqual(error.recoveryKey, "agent.error.recovery.reconnect")
  }

  func testGenericErrorKeepsOriginalMessage() {
    let error = AgentTurnErrorClassifier.generic("上游服务超时")
    XCTAssertEqual(error.kind, .generic)
    XCTAssertEqual(error.messageKey, "上游服务超时")
    XCTAssertNil(error.recoveryKey)
  }

  // MARK: - 语音历史 Agent 标识

  func testVoiceHistoryNamingCustomUsesConfigID() {
    let config = CustomAgentConfig(name: "测试大脑", baseURL: "http://x/v1", model: "m")
    let name = AgentVoiceHistoryNaming.agentName(brain: .custom, customConfig: config)
    XCTAssertEqual(name, "custom." + config.id.uuidString)
  }

  func testVoiceHistoryNamingCustomWithoutConfigFallsBack() {
    let name = AgentVoiceHistoryNaming.agentName(brain: .custom, customConfig: nil)
    XCTAssertEqual(name, "qwen-audio-agent")
  }

  func testVoiceHistoryNamingNonCustomBrainsUseQwenNamespace() {
    for brain in [AgentBrain.qwen, .hermes, .openclaw, .auto] {
      let name = AgentVoiceHistoryNaming.agentName(brain: brain, customConfig: nil)
      XCTAssertEqual(name, "qwen-audio-agent")
    }
  }
}
