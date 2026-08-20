import Foundation
import XCTest

@testable import HyperMetaAI

private final class MockQwenGatewaySocket: QwenGatewaySocket {
  var sentMessages: [String] = []
  var holdsSendCompletions = false
  private var pendingReceives: [(Result<String, Error>) -> Void] = []
  private var queuedDeliveries: [Result<String, Error>] = []
  private var pendingSendCompletions: [(Error?) -> Void] = []
  private(set) var closeCount = 0
  private(set) var pingCount = 0
  var pingError: Error?

  func send(_ string: String, completion: @escaping (Error?) -> Void) {
    sentMessages.append(string)
    if holdsSendCompletions {
      pendingSendCompletions.append(completion)
    } else {
      completion(nil)
    }
  }

  func receive(completion: @escaping (Result<String, Error>) -> Void) {
    if queuedDeliveries.isEmpty {
      pendingReceives.append(completion)
    } else {
      completion(queuedDeliveries.removeFirst())
    }
  }

  func sendPing(completion: @escaping (Error?) -> Void) {
    pingCount += 1
    completion(pingError)
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

  func completeNextSend(with error: Error? = nil) {
    precondition(!pendingSendCompletions.isEmpty)
    pendingSendCompletions.removeFirst()(error)
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
      },
      criticalControlTimeout: 0.04
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

  func testAudioDeltaIsDecodedBeforeDeliveryAndPreservesSocketReceiveTime() async throws {
    let expectedPCM = Data(repeating: 7, count: 1_920)
    var deliveredEvent: QwenGatewayEvent?
    var deliveredAt: TimeInterval?
    service.onEvent = { event in
      if case .audioChunk = event {
        deliveredEvent = event
        deliveredAt = ProcessInfo.processInfo.systemUptime
      }
    }
    service.connect()

    let sentAt = ProcessInfo.processInfo.systemUptime
    mockSocket.deliver([
      "type": "audio.delta",
      "audio": expectedPCM.base64EncodedString(),
      "sampleRate": 24_000,
      "responseId": "r1"
    ])
    await waitUntil { deliveredEvent != nil }

    guard case .audioChunk(let pcmData, let sampleRate, let responseId, let receivedAt) = deliveredEvent,
          let deliveredAt else {
      return XCTFail("decoded PCM event should reach the listener")
    }
    XCTAssertEqual(pcmData, expectedPCM)
    XCTAssertEqual(sampleRate, 24_000)
    XCTAssertEqual(responseId, "r1")
    XCTAssertGreaterThanOrEqual(receivedAt, sentAt)
    XCTAssertLessThanOrEqual(receivedAt, deliveredAt)

    let deliveryMilliseconds = (deliveredAt - receivedAt) * 1_000
    let attachment = XCTAttachment(
      string: "gatewayReceiveToDecodedEventMs=\(deliveryMilliseconds)"
    )
    attachment.name = "Qwen ingress decode and delivery latency"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTAssertLessThan(deliveryMilliseconds, 20)
  }

  func testBuiltInTransportUsesDecodedEventFastPathAndPreservesIngressTime() async throws {
    let ingressTime = 42.25
    let embeddedSocket = QwenEmbeddedGatewaySocket(
      configuration: QwenEmbeddedGatewayConfiguration(
        apiKey: "test-key",
        baseURL: "wss://dashscope.example/realtime",
        model: "qwen-audio-3.0-realtime-plus",
        voice: "longanqian"
      ),
      providerSocket: mockSocket,
      now: { ingressTime }
    )
    let builtInService = QwenGatewayService(
      preferences: preferences,
      socketFactory: { _ in
        XCTFail("the built-in transport should not use the external socket")
        return self.mockSocket
      },
      embeddedSocketFactory: { _ in embeddedSocket },
      embeddedConfigurationProvider: {
        QwenEmbeddedGatewayConfiguration(
          apiKey: "test-key",
          baseURL: "wss://dashscope.example/realtime",
          model: "qwen-audio-3.0-realtime-plus",
          voice: "longanqian"
        )
      }
    )
    builtInService.mode = .builtIn
    defer { builtInService.disconnect() }
    var deliveredEvent: QwenGatewayEvent?
    builtInService.onEvent = { event in
      if case .audioChunk = event { deliveredEvent = event }
    }
    builtInService.connect()

    mockSocket.deliver(["type": "session.created"])
    mockSocket.deliver(["type": "session.updated"])
    await waitUntil { builtInService.connectionState == .connected }
    XCTAssertEqual(builtInService.connectionState, .connected)

    let expectedPCM = Data(repeating: 3, count: 1_920)
    mockSocket.deliver([
      "type": "response.audio.delta",
      "response_id": "r-fast",
      "delta": expectedPCM.base64EncodedString()
    ])
    await waitUntil { deliveredEvent != nil }

    guard case .audioChunk(let pcmData, _, let responseID, let receivedAt) = deliveredEvent else {
      return XCTFail("the embedded socket should deliver a decoded audio event")
    }
    XCTAssertEqual(pcmData, expectedPCM)
    XCTAssertEqual(responseID, "r-fast")
    XCTAssertEqual(receivedAt, ingressTime)
  }

  func testAudioTransportUsesAttachedSocketAndRejectsAfterDetach() throws {
    let transport = QwenGatewayAudioTransport()
    transport.attach(mockSocket)

    var sendError: Error?
    transport.send(.string("audio-message")) { sendError = $0 }
    XCTAssertNil(sendError)
    XCTAssertEqual(mockSocket.sentMessages.last, "audio-message")

    transport.detach(mockSocket)
    transport.send(.string("stale-message")) { sendError = $0 }
    XCTAssertNotNil(sendError)
    XCTAssertNotEqual(mockSocket.sentMessages.last, "stale-message")
  }

  func testAudioTransportRejectsNonTextWebSocketMessages() {
    let transport = QwenGatewayAudioTransport()
    transport.attach(mockSocket)

    var sendError: Error?
    transport.send(.data(Data([0x01]))) { sendError = $0 }

    XCTAssertNotNil(sendError)
    XCTAssertTrue(mockSocket.sentMessages.isEmpty)
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

  func testInterruptDeadlineClosesAStalledSocketAndIgnoresLateCompletion() async {
    service.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitForState(.connected)
    mockSocket.holdsSendCompletions = true
    let startedAt = ProcessInfo.processInfo.systemUptime

    service.interrupt()

    await waitUntil { self.mockSocket.closeCount == 1 }
    let elapsedMilliseconds = (
      ProcessInfo.processInfo.systemUptime - startedAt
    ) * 1_000
    print("[QwenInterruptLatency] criticalControlTimeoutMs=\(elapsedMilliseconds)")
    let latencyAttachment = XCTAttachment(
      string: "configuredCriticalControlTimeoutMs=40\n"
        + "criticalControlTimeoutMs=\(elapsedMilliseconds)"
    )
    latencyAttachment.name = "Qwen critical interrupt control timeout"
    latencyAttachment.lifetime = .keepAlways
    add(latencyAttachment)
    XCTAssertGreaterThanOrEqual(elapsedMilliseconds, 30)
    XCTAssertLessThan(elapsedMilliseconds, 250)
    guard case .failed(let message) = service.connectionState else {
      return XCTFail("A stalled critical interrupt must fail the transport")
    }
    XCTAssertFalse(message.isEmpty)

    mockSocket.completeNextSend()
    try? await Task.sleep(nanoseconds: 50_000_000)

    XCTAssertEqual(mockSocket.closeCount, 1)
    guard case .failed = service.connectionState else {
      return XCTFail("A late interrupt completion must not revive the stale socket")
    }
  }

  func testControlEventsUseLiveSocketWhenVoiceFrontendIsUnavailable() async throws {
    service.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitForState(.connected)
    mockSocket.deliver([
      "type": "voice.connection",
      "state": "unavailable",
      "message": "provider unavailable"
    ])
    await waitUntil {
      if case .failed = self.service.connectionState { return true }
      return false
    }

    let sentBeforeControls = mockSocket.sentMessages.count
    service.sendText("content must remain gated")
    service.interrupt()
    service.requestWake()
    service.notifyPlaybackCancelled(responseId: "r1", reason: "playback_error")

    let controls = try mockSocket.sentMessages.dropFirst(sentBeforeControls).map {
      try json(from: $0)
    }
    XCTAssertEqual(
      controls.compactMap { $0["type"] as? String },
      ["interrupt", "wake", "playback.cancelled"]
    )
    XCTAssertEqual(controls.last?["responseId"] as? String, "r1")
    XCTAssertEqual(controls.last?["reason"] as? String, "playback_error")
  }

  func testForegroundReconnectReusesLiveGatewayTransportWhileProviderUnavailable() async throws {
    service.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitForState(.connected)
    mockSocket.deliver([
      "type": "voice.connection",
      "state": "unavailable",
      "message": "provider temporarily unavailable"
    ])
    await waitUntil {
      if case .failed = self.service.connectionState { return true }
      return false
    }
    let requestCount = receivedRequests.count
    let messageCount = mockSocket.sentMessages.count
    let startedAt = ProcessInfo.processInfo.systemUptime

    service.connect()

    let elapsedMilliseconds = (
      ProcessInfo.processInfo.systemUptime - startedAt
    ) * 1_000
    print("[QwenReconnectLatency] foregroundTransportReuseMs=\(elapsedMilliseconds)")
    let latencyAttachment = XCTAttachment(
      string: "foregroundTransportReuseMs=\(elapsedMilliseconds)"
    )
    latencyAttachment.name = "Qwen foreground transport reuse latency"
    latencyAttachment.lifetime = .keepAlways
    add(latencyAttachment)
    XCTAssertLessThan(elapsedMilliseconds, 10)
    XCTAssertEqual(receivedRequests.count, requestCount)
    XCTAssertEqual(mockSocket.sentMessages.count, messageCount)
    XCTAssertEqual(mockSocket.closeCount, 0)
  }

  func testProviderConnectingTransitionsOutOfUnavailableOnExistingTransport() async throws {
    service.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitForState(.connected)
    mockSocket.deliver([
      "type": "voice.connection",
      "state": "unavailable",
      "message": "provider temporarily unavailable"
    ])
    await waitUntil {
      if case .failed = self.service.connectionState { return true }
      return false
    }
    guard case .failed(let message) = service.connectionState else {
      return XCTFail("Provider unavailability must be surfaced")
    }
    XCTAssertEqual(message, "provider temporarily unavailable")

    mockSocket.deliver(["type": "voice.connection", "state": "connecting"])
    await waitUntil(timeout: 0.25) { self.service.connectionState == .connecting }

    XCTAssertEqual(service.connectionState, .connecting)
    XCTAssertEqual(receivedRequests.count, 1)

    mockSocket.deliver(["type": "voice.connection", "state": "connected"])
    await waitForState(.connected)
    XCTAssertEqual(receivedRequests.count, 1)
  }

  func testSleepWakeLifecycleKeepsCapabilityAndRuntimeStatesDistinct() async throws {
    service.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitForState(.connected)

    mockSocket.deliver(["type": "voice.sleep", "state": "enabled"])
    try? await Task.sleep(nanoseconds: 20_000_000)
    XCTAssertEqual(service.connectionState, .connected)

    mockSocket.deliver(["type": "voice.connection", "state": "sleeping"])
    await waitUntil {
      String(describing: self.service.connectionState) == "sleeping"
    }
    XCTAssertEqual(String(describing: service.connectionState), "sleeping")
    XCTAssertEqual(
      AgentVoiceLiveActivityStatus.phase(
        isActive: true,
        isSleeping: false,
        isSpeaking: false,
        isInputActive: false,
        connectionState: service.connectionState
      ),
      .sleeping
    )
    let startedAt = ProcessInfo.processInfo.systemUptime

    service.requestWake()

    let elapsedMilliseconds = (
      ProcessInfo.processInfo.systemUptime - startedAt
    ) * 1_000
    print("[QwenWakeLatency] wakeStatePublicationMs=\(elapsedMilliseconds)")
    let latencyAttachment = XCTAttachment(
      string: "wakeStatePublicationMs=\(elapsedMilliseconds)"
    )
    latencyAttachment.name = "Qwen wake state publication latency"
    latencyAttachment.lifetime = .keepAlways
    add(latencyAttachment)
    XCTAssertLessThan(elapsedMilliseconds, 10)
    XCTAssertEqual(String(describing: service.connectionState), "waking")
    XCTAssertEqual(
      AgentVoiceLiveActivityStatus.phase(
        isActive: true,
        isSleeping: false,
        isSpeaking: false,
        isInputActive: false,
        connectionState: service.connectionState
      ),
      .connecting
    )

    mockSocket.deliver(["type": "client.state", "state": "sleeping"])
    mockSocket.deliver(["type": "voice.connection", "state": "sleeping"])
    mockSocket.deliver(["type": "voice.sleep", "state": "sleeping"])
    mockSocket.deliver(["type": "client.state", "state": "awake"])
    mockSocket.deliver(["type": "voice.sleep", "state": "awake"])
    try? await Task.sleep(nanoseconds: 20_000_000)
    XCTAssertEqual(String(describing: service.connectionState), "waking")

    mockSocket.deliver(["type": "voice.connection", "state": "connecting"])
    try? await Task.sleep(nanoseconds: 20_000_000)
    XCTAssertEqual(String(describing: service.connectionState), "waking")

    mockSocket.deliver(["type": "voice.connection", "state": "connected"])
    await waitForState(.connected)

    mockSocket.deliver(["type": "voice.connection", "state": "sleeping"])
    await waitUntil {
      String(describing: self.service.connectionState) == "sleeping"
    }
    service.requestWake()
    mockSocket.deliver([
      "type": "voice.connection",
      "state": "sleeping",
      "message": "wake provider unavailable"
    ])
    await waitUntil {
      String(describing: self.service.connectionState) == "sleeping"
    }
  }

  func testRealtimeLifecycleKeepsUpstreamStatusPrecedenceAcrossLateEvents() async throws {
    service.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitForState(.connected)

    mockSocket.deliver([
      "type": "voice.connection",
      "state": "unavailable",
      "message": "credential missing"
    ])
    await waitUntil {
      if case .failed = self.service.connectionState { return true }
      return false
    }

    mockSocket.deliver(["type": "voice.sleep", "state": "detected"])
    mockSocket.deliver(["type": "client.state", "state": "sleeping"])
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    try? await Task.sleep(nanoseconds: 20_000_000)
    guard case .failed(let message) = service.connectionState else {
      return XCTFail("unavailable must outrank waking, sleeping, and ready")
    }
    XCTAssertEqual(message, "credential missing")

    mockSocket.deliver(["type": "voice.connection", "state": "connecting"])
    try? await Task.sleep(nanoseconds: 20_000_000)
    XCTAssertEqual(String(describing: service.connectionState), "waking")

    mockSocket.deliver(["type": "voice.connection", "state": "connected"])
    await waitForState(.connected)

    mockSocket.deliver(["type": "voice.connection", "state": "sleeping"])
    await waitUntil { self.service.connectionState == .sleeping }
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    mockSocket.deliver(["type": "voice.connection", "state": "connecting"])
    try? await Task.sleep(nanoseconds: 20_000_000)
    XCTAssertEqual(service.connectionState, .sleeping)

    mockSocket.deliver(["type": "voice.connection", "state": "sleeping"])
    await waitUntil { self.service.connectionState == .sleeping }
    service.requestWake()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    try? await Task.sleep(nanoseconds: 20_000_000)
    XCTAssertEqual(String(describing: service.connectionState), "waking")

    mockSocket.deliver(["type": "voice.connection", "state": "connected"])
    await waitForState(.connected)
  }

  func testRealtimeStatusReducerMatchesUpstreamPrecedenceWithinBudget() {
    var status = QwenRealtimeConnectionStatus()
    XCTAssertEqual(status.connectionState, .disconnected)

    status.beginConnecting(resetLifecycle: true)
    XCTAssertEqual(status.connectionState, .connecting)
    status.markReady()
    XCTAssertEqual(status.connectionState, .connected)
    status.markWaking()
    XCTAssertEqual(status.connectionState, .waking)
    status.markReady()
    XCTAssertEqual(status.connectionState, .waking)
    status.markSleeping()
    XCTAssertEqual(status.connectionState, .sleeping)
    status.markUnavailable("credential missing")
    XCTAssertEqual(status.connectionState, .failed("credential missing"))
    status.beginConnecting(resetLifecycle: false)
    XCTAssertEqual(status.connectionState, .sleeping)
    status.markWaking()
    XCTAssertEqual(status.connectionState, .waking)
    status.markConnected()
    XCTAssertEqual(status.connectionState, .connected)

    let iterations = 100_000
    var connectedCount = 0
    let startedAt = ProcessInfo.processInfo.systemUptime
    for _ in 0..<iterations {
      status.beginConnecting(resetLifecycle: true)
      status.markReady()
      status.markWaking()
      status.markSleeping()
      status.markUnavailable("credential missing")
      status.beginConnecting(resetLifecycle: false)
      status.markConnected()
      if status.connectionState == .connected {
        connectedCount += 1
      }
    }
    let operationCount = Double(iterations * 7)
    let averageMicroseconds = (
      ProcessInfo.processInfo.systemUptime - startedAt
    ) * 1_000_000 / operationCount
    print("[QwenStatusLatency] statusReductionAverageUs=\(averageMicroseconds)")
    let attachment = XCTAttachment(
      string: "statusReductionAverageUs=\(averageMicroseconds)"
    )
    attachment.name = "Qwen realtime status reduction latency"
    attachment.lifetime = .keepAlways
    add(attachment)

    XCTAssertEqual(connectedCount, iterations)
    XCTAssertLessThan(averageMicroseconds, 5)
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

  func testHeartbeatFailureClosesHalfOpenSocketAndStartsReconnect() async {
    let heartbeatService = QwenGatewayService(
      preferences: preferences,
      socketFactory: { _ in self.mockSocket },
      embeddedSocketFactory: { _ in self.mockSocket },
      embeddedConfigurationProvider: { nil },
      heartbeatInterval: 0.01,
      heartbeatTimeout: 0.05
    )
    heartbeatService.mode = .external
    mockSocket.pingError = URLError(.networkConnectionLost)
    var reconnecting = false
    heartbeatService.onEvent = { event in
      if case .gatewayReconnecting = event { reconnecting = true }
    }

    heartbeatService.connect()
    mockSocket.deliver(["type": "voice.ready", "inputSampleRate": 16_000])
    await waitUntil(timeout: 1) { reconnecting }

    XCTAssertGreaterThanOrEqual(mockSocket.pingCount, 1)
    XCTAssertGreaterThanOrEqual(mockSocket.closeCount, 1)
    heartbeatService.disconnect()
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
