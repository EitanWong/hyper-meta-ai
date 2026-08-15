import Foundation
import XCTest

@testable import HyperMetaAI

private final class MockQwenGatewaySocket: QwenGatewaySocket {
  var sentMessages: [String] = []
  private var pendingReceives: [(Result<String, Error>) -> Void] = []
  private var queuedDeliveries: [Result<String, Error>] = []
  private(set) var closeCount = 0

  func send(_ string: String, completion: @escaping (Error?) -> Void) {
    sentMessages.append(string)
    completion(nil)
  }

  func receive(completion: @escaping (Result<String, Error>) -> Void) {
    if queuedDeliveries.isEmpty {
      pendingReceives.append(completion)
    } else {
      completion(queuedDeliveries.removeFirst())
    }
  }

  func close() {
    closeCount += 1
  }

  func deliver(_ json: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: json)
    let text = String(data: data, encoding: .utf8)!
    if pendingReceives.isEmpty {
      queuedDeliveries.append(.success(text))
    } else {
      pendingReceives.removeFirst()(.success(text))
    }
  }

  func failNextReceive() {
    if pendingReceives.isEmpty {
      queuedDeliveries.append(.failure(URLError(.networkConnectionLost)))
    } else {
      pendingReceives.removeFirst()(.failure(URLError(.networkConnectionLost)))
    }
  }
}

@MainActor
final class QwenGatewayServiceTests: XCTestCase {
  private static let modeKey = "qwen_gateway_mode"
  private var mockSocket: MockQwenGatewaySocket!
  private var receivedRequests: [URLRequest] = []
  private var receivedEmbeddedConfigurations: [QwenEmbeddedGatewayConfiguration] = []
  private var preferencesSuiteName: String!
  private var preferences: UserDefaults!
  private var service: QwenGatewayService!

  override func setUp() {
    super.setUp()
    preferencesSuiteName = "QwenGatewayServiceTests.\(UUID().uuidString)"
    preferences = UserDefaults(suiteName: preferencesSuiteName)!
    mockSocket = MockQwenGatewaySocket()
    receivedRequests = []
    receivedEmbeddedConfigurations = []
    let factory: (URLRequest) -> QwenGatewaySocket = { [weak self] request in
      self?.receivedRequests.append(request)
      return self!.mockSocket
    }
    service = QwenGatewayService(
      preferences: preferences,
      socketFactory: factory,
      embeddedSocketFactory: { [weak self] configuration in
        self?.receivedEmbeddedConfigurations.append(configuration)
        return self!.mockSocket
      },
      embeddedConfigurationProvider: {
        QwenEmbeddedGatewayConfiguration(
          apiKey: "test-key",
          baseURL: "wss://dashscope.example/realtime",
          model: "qwen-audio-3.0-realtime-plus",
          voice: "longanqian"
        )
      }
    )
    service.mode = .external
    service.gatewayHost = "192.168.1.10"
    service.gatewayPort = 3101
    service.sessionName = "test-session"
  }

  override func tearDown() {
    service.disconnect()
    service = nil
    mockSocket = nil
    preferences.removePersistentDomain(forName: preferencesSuiteName)
    preferences = nil
    preferencesSuiteName = nil
    super.tearDown()
  }

  func testConnectSendsHandshakeWithSessionURL() async {
    service.connect()
    XCTAssertEqual(service.connectionState, .connecting)

    let request = try! XCTUnwrap(receivedRequests.first)
    XCTAssertEqual(request.url?.scheme, "ws")
    XCTAssertEqual(request.url?.host, "192.168.1.10")
    XCTAssertEqual(request.url?.port, 3101)
    XCTAssertTrue(request.url?.path == "/api/realtime")
    XCTAssertEqual(request.url?.query, "sessionId=test-session")

    let payload = try! json(from: mockSocket.sentMessages.first)
    XCTAssertEqual(payload["type"] as? String, "connect")
    XCTAssertEqual(payload["clientType"] as? String, "ios")
    XCTAssertEqual(payload["voiceEnabled"] as? Bool, true)
  }

  func testBuiltInModeUsesEmbeddedTransportWithoutExternalRequest() async throws {
    service.mode = .builtIn
    service.connect()

    XCTAssertTrue(receivedRequests.isEmpty)
    let configuration = try XCTUnwrap(receivedEmbeddedConfigurations.first)
    XCTAssertEqual(configuration.model, "qwen-audio-3.0-realtime-plus")
    XCTAssertEqual(configuration.voice, "longanqian")
    let payload = try json(from: mockSocket.sentMessages.first)
    XCTAssertEqual(payload["type"] as? String, "connect")
  }

  func testBuiltInModeReportsMissingAPIKeyWithoutOpeningSocket() {
    let missingKeyService = QwenGatewayService(
      socketFactory: { _ in XCTFail("external transport should not be used"); return self.mockSocket },
      embeddedSocketFactory: { _ in XCTFail("embedded transport should not open without a key"); return self.mockSocket },
      embeddedConfigurationProvider: { nil }
    )
    missingKeyService.mode = .builtIn

    missingKeyService.connect()

    guard case .failed(let message) = missingKeyService.connectionState else {
      return XCTFail("missing API key should fail before opening a socket")
    }
    XCTAssertFalse(message.isEmpty)
  }

  func testModeDefaultsToBuiltInWhenPreferenceIsMissing() {
    let defaultService = QwenGatewayService(
      preferences: preferences,
      socketFactory: { _ in self.mockSocket },
      embeddedSocketFactory: { _ in self.mockSocket },
      embeddedConfigurationProvider: { nil }
    )

    XCTAssertEqual(defaultService.mode, .builtIn)
  }

  func testInvalidSavedModeFallsBackToBuiltIn() {
    preferences.set("legacy_gateway", forKey: Self.modeKey)

    let defaultService = QwenGatewayService(
      preferences: preferences,
      socketFactory: { _ in self.mockSocket },
      embeddedSocketFactory: { _ in self.mockSocket },
      embeddedConfigurationProvider: { nil }
    )

    XCTAssertEqual(defaultService.mode, QwenGatewayMode.defaultMode)
  }

  func testSaveSettingsPersistsGatewayMode() {
    service.mode = .external
    service.saveSettings()

    XCTAssertEqual(preferences.string(forKey: Self.modeKey), QwenGatewayMode.external.rawValue)
  }

  func testSavedExternalModeIsRestored() {
    preferences.set(QwenGatewayMode.external.rawValue, forKey: Self.modeKey)

    let restoredService = QwenGatewayService(
      preferences: preferences,
      socketFactory: { _ in self.mockSocket },
      embeddedSocketFactory: { _ in self.mockSocket },
      embeddedConfigurationProvider: { nil }
    )

    XCTAssertEqual(restoredService.mode, .external)
  }

  func testBuiltInPermissionDecisionResolvesLocally() async throws {
    service.mode = .builtIn

    let permission = try await service.respondPermission(id: "vision.capture", decision: .allow)

    XCTAssertEqual(permission.id, "vision.capture")
    XCTAssertEqual(permission.status, .approved)
  }

  func testConnectWithOutputDisabledPropagatesToPayload() async {
    service.outputEnabled = false
    service.connect()

    let payload = try! json(from: mockSocket.sentMessages.first)
    XCTAssertEqual(payload["type"] as? String, "connect")
    XCTAssertEqual(payload["outputEnabled"] as? Bool, false)
    XCTAssertEqual(payload["voiceEnabled"] as? Bool, false)
    XCTAssertEqual(payload["inputEnabled"] as? Bool, true)
  }

  func testVoiceReadyMovesToConnected() async throws {
    service.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitForState(.connected)
    XCTAssertEqual(service.voiceState, "idle")
  }

  func testVoiceStateIsPublished() async throws {
    service.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitForState(.connected)
    mockSocket.deliver(["type": "voice.state", "state": "listening", "turnId": "t1"])
    await waitUntil { self.service.voiceState == "listening" }
  }

  func testSendAudioAppendsBase64PCM() async throws {
    service.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitForState(.connected)

    let pcm = Data([0x01, 0x02, 0x03])
    service.sendAudio(pcmData: pcm)
    await waitUntil { self.mockSocket.sentMessages.count >= 2 }

    let payload = try json(from: mockSocket.sentMessages.last)
    XCTAssertEqual(payload["type"] as? String, "audio.append")
    XCTAssertEqual(payload["audio"] as? String, pcm.base64EncodedString())
  }

  func testInterruptAndMuteAreForwarded() async throws {
    service.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitForState(.connected)

    service.interrupt()
    service.setInputMuted(true)
    await waitUntil { self.mockSocket.sentMessages.count >= 3 }

    let types = mockSocket.sentMessages.dropFirst().compactMap { message -> String? in
      try? json(from: message)["type"] as? String
    }
    XCTAssertEqual(types, ["interrupt", "input.mute"])
  }

  func testTaskEventIsForwardedToListener() async throws {
    service.connect()
    var received: [QwenGatewayEvent] = []
    service.onEvent = { received.append($0) }
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitForState(.connected)

    mockSocket.deliver([
      "type": "task.delegated",
      "task": ["id": "task-1", "delegation": ["presentation": ["speech": "好的"]]]
    ])
    await waitUntil { received.contains(where: { if case .task = $0 { return true }; return false }) }

    XCTAssertTrue(received.contains(.task(type: "task.delegated", taskId: "task-1", title: "好的")))
  }

  func testDisconnectClosesSocket() async {
    service.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitForState(.connected)

    service.disconnect()
    XCTAssertEqual(mockSocket.closeCount, 1)
    XCTAssertEqual(service.connectionState, .disconnected)
  }

  func testSocketCloseTriggersGatewayDisconnectedEvent() async throws {
    service.connect()
    var disconnected = false
    service.onEvent = { event in
      if event == .gatewayDisconnected { disconnected = true }
    }
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitForState(.connected)

    mockSocket.failNextReceive()
    await waitUntil { disconnected }
    XCTAssertEqual(service.connectionState, .disconnected)
  }

  func testSocketCloseEmitsReconnectingEvent() async throws {
    service.connect()
    var events: [QwenGatewayEvent] = []
    service.onEvent = { events.append($0) }
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitForState(.connected)

    mockSocket.failNextReceive()
    await waitUntil {
      events.contains { event in
        if case .gatewayReconnecting = event { return true }
        return false
      }
    }
    guard case .gatewayReconnecting(let attempt, let maxAttempts) = events.first(where: { event in
      if case .gatewayReconnecting = event { return true }
      return false
    }) else {
      return XCTFail("未收到 gatewayReconnecting 事件")
    }
    XCTAssertEqual(attempt, 1)
    XCTAssertEqual(maxAttempts, 5)
  }

  func testReconnectLimitEmitsFailedEvent() async throws {
    let limitedService = QwenGatewayService(
      socketFactory: { [weak self] _ in self!.mockSocket },
      maxReconnectAttempts: 2
    )
    limitedService.mode = .external
    var failed = false
    limitedService.onEvent = { event in
      if event == .gatewayReconnectFailed { failed = true }
    }
    limitedService.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil { limitedService.connectionState == .connected }

    mockSocket.failNextReceive()
    await waitUntil(timeout: 1) { self.receivedRequests.count == 2 }
    mockSocket.failNextReceive()
    await waitUntil(timeout: 1) { failed }
    XCTAssertTrue(failed)
    guard case .failed = limitedService.connectionState else {
      return XCTFail("重连达到上限后应为 failed 状态")
    }
  }

  // MARK: - Reconnect Policy

  func testReconnectPolicyBacksOffAndStopsAfterLimit() {
    var policy = QwenReconnectPolicy(maxConsecutiveFailures: 3)
    XCTAssertEqual(policy.nextDelay, 0.5)
    XCTAssertTrue(policy.recordFailure())
    XCTAssertEqual(policy.nextDelay, 1.0)
    XCTAssertTrue(policy.recordFailure())
    XCTAssertEqual(policy.nextDelay, 2.0)
    XCTAssertFalse(policy.recordFailure(), "第 3 次失败达到上限，不再重连")
    XCTAssertEqual(policy.nextDelay, 2.0, "达到上限后不再翻倍")
    XCTAssertEqual(policy.consecutiveFailures, 3)
  }

  func testReconnectPolicyResetsOnSuccess() {
    var policy = QwenReconnectPolicy(maxConsecutiveFailures: 3)
    _ = policy.recordFailure()
    policy.recordSuccess()
    XCTAssertEqual(policy.consecutiveFailures, 0)
    XCTAssertEqual(policy.nextDelay, 0.5)
  }

  func testReconnectPolicyReset() {
    var policy = QwenReconnectPolicy(maxConsecutiveFailures: 3)
    _ = policy.recordFailure()
    policy.reset()
    XCTAssertEqual(policy.consecutiveFailures, 0)
    XCTAssertEqual(policy.nextDelay, 0.5)
  }

  // MARK: - 权限审批端点

  func testPermissionEndpointURL() {
    let url = QwenGatewayService.permissionEndpoint(
      host: "192.168.1.10",
      port: 3101,
      usesTLS: false,
      id: "auth_1"
    )
    XCTAssertEqual(url.scheme, "http")
    XCTAssertEqual(url.host, "192.168.1.10")
    XCTAssertEqual(url.port, 3101)
    XCTAssertEqual(url.path, "/api/permissions/auth_1")

    let tlsURL = QwenGatewayService.permissionEndpoint(
      host: "gw.example.com",
      port: 8443,
      usesTLS: true,
      id: "auth 2"
    )
    XCTAssertEqual(tlsURL.scheme, "https")
    XCTAssertEqual(tlsURL.port, 8443)
    XCTAssertTrue(tlsURL.absoluteString.contains("auth%202"), "ID 需要 URL 编码: \(tlsURL)")
  }

  // MARK: - Helpers

  private func waitForState(_ expected: QwenGatewayConnectionState) async {
    await waitUntil { self.service.connectionState == expected }
  }

  private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  private func json(from message: String?) throws -> [String: Any] {
    let text = try XCTUnwrap(message)
    let data = try XCTUnwrap(text.data(using: .utf8))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}
