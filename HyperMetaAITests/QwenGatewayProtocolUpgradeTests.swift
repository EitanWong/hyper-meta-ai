import Foundation
import XCTest

@testable import HyperMetaAI

/// 镜像 qwen-audio-agent v1.8.x 网关协议升级：
///   - connect 携带 provider / wakeWordOnly（会话级前端选择、仅唤醒模式）
///   - 客户端 sleep / wake 事件
///   - 服务端 client.state 事件
final class QwenGatewayProtocolUpgradeTests: XCTestCase {
  func testConnectCarriesProviderWhenGiven() {
    let payload = QwenGatewayClientEvent.connect(
      timeZone: "Asia/Shanghai",
      locale: "zh-Hans",
      clientType: "ios",
      clientLabel: "HyperMetaAI",
      clientInstanceId: "abc",
      provider: "dashscope"
    )
    XCTAssertEqual(payload["provider"] as? String, "dashscope")
    XCTAssertNil(payload["wakeWordOnly"])
  }

  func testConnectOmitsProviderByDefault() {
    let payload = QwenGatewayClientEvent.connect(
      timeZone: "Asia/Shanghai",
      locale: "zh-Hans",
      clientType: "ios",
      clientLabel: "HyperMetaAI",
      clientInstanceId: "abc"
    )
    XCTAssertNil(payload["provider"])
    XCTAssertNil(payload["wakeWordOnly"])
  }

  func testConnectWakeWordOnlyMode() {
    let payload = QwenGatewayClientEvent.connect(
      timeZone: "Asia/Shanghai",
      locale: "zh-Hans",
      clientType: "ios",
      clientLabel: "HyperMetaAI",
      clientInstanceId: "abc",
      wakeWordOnly: true
    )
    XCTAssertEqual(payload["wakeWordOnly"] as? Bool, true)
  }

  func testSleepAndWakeClientEvents() {
    XCTAssertEqual(QwenGatewayClientEvent.sleep()["type"] as? String, "sleep")
    XCTAssertEqual(QwenGatewayClientEvent.wake()["type"] as? String, "wake")
  }

  func testParseClientStateSleeping() {
    let event = QwenGatewayEventParser.parse(["type": "client.state", "state": "sleeping"])
    XCTAssertEqual(event, .clientState(state: "sleeping"))
  }

  func testParseClientStateUnknownStateStillParses() {
    let event = QwenGatewayEventParser.parse(["type": "client.state", "state": "awake"])
    XCTAssertEqual(event, .clientState(state: "awake"))
  }
}
