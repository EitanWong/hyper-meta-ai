import Foundation
import AVFAudio
import XCTest

@testable import HyperMetaAI

// Test doubles and the shared fixture for the QwenVoiceSession suites.
// The suites are split across several files in this target, so these are
// internal rather than file-private, and the fixture is a base class each
// suite subclasses. Subclassing keeps XCTest discovery on the ordinary
// class-metadata path and shares one setUp/tearDown pair.
final class VoiceSessionMockSocket: QwenGatewaySocket {
  var sentMessages: [String] = []
  private var pendingReceives: [(Result<String, Error>) -> Void] = []
  private var queuedDeliveries: [Result<String, Error>] = []

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

  func close() {}

  func deliver(_ json: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: json)
    let text = String(data: data, encoding: .utf8)!
    if pendingReceives.isEmpty {
      queuedDeliveries.append(.success(text))
    } else {
      pendingReceives.removeFirst()(.success(text))
    }
  }
}

final class MockPermissionResponder: QwenPermissionResponding {
  var result: Result<QwenPermission, Error> = .failure(URLError(.badServerResponse))
  private(set) var receivedID: String?
  private(set) var receivedDecision: QwenPermissionDecision?

  func respondPermission(
    id: String,
    decision: QwenPermissionDecision
  ) async throws -> QwenPermission {
    receivedID = id
    receivedDecision = decision
    return try result.get()
  }
}

final class MockWakeWordMonitor: QwenWakeWordListening {
  var isMonitoring = false
  var onWakeWord: ((String) -> Void)?
  var onTranscript: ((String) -> Void)?
  var shouldFail = false

  func startMonitoring() async throws {
    if shouldFail { throw QwenWakeWordError.recognizerUnavailable }
    isMonitoring = true
  }

  func stopMonitoring() {
    isMonitoring = false
  }
}

final class VoiceSessionMockPlaybackPipeline: RealtimeAudioPlaybackControlling {
  private(set) var enqueueCallCount = 0
  private(set) var lastReceivedAt: TimeInterval?
  private(set) var interruptCallCount = 0
  private(set) var invalidateAudioSystemCallCount = 0
  private(set) var prepareCallCount = 0
  private(set) var stopCallCount = 0
  var isActive = true

  func start(
    generation: Int,
    onFailure: @escaping RealtimeAudioPlaybackPipeline.FailureHandler,
    onResponsePlaybackComplete: @escaping RealtimeAudioPlaybackPipeline.PlaybackCompletionHandler,
    onAudioLevel: @escaping RealtimeAudioPlaybackPipeline.AudioLevelHandler
  ) {
    isActive = true
  }

  func prepare(generation: Int) {
    prepareCallCount += 1
  }

  func stop() {
    stopCallCount += 1
    isActive = false
  }

  func enqueue(
    _ data: Data,
    generation: Int,
    receivedAt: TimeInterval
  ) -> RealtimeAudioJitterOfferResult {
    enqueueCallCount += 1
    lastReceivedAt = receivedAt
    guard isActive else { return .inactive }
    guard !data.isEmpty, data.count.isMultiple(of: MemoryLayout<Int16>.size) else {
      return .invalidFrameAlignment
    }
    return .accepted
  }

  func finishResponse(generation: Int) {}

  /// Milliseconds the double reports as "already played" on interrupt, so tests
  /// can assert the truncate value forwarded to the gateway.
  var playedMillisecondsOnInterrupt = 0

  @discardableResult
  func interrupt(generation: Int) -> Int {
    interruptCallCount += 1
    return playedMillisecondsOnInterrupt
  }

  @discardableResult
  func invalidateAudioSystem(generation: Int) -> Int {
    invalidateAudioSystemCallCount += 1
    return playedMillisecondsOnInterrupt
  }
}

@MainActor
class QwenVoiceSessionTestCase: XCTestCase {
  var mockSocket: VoiceSessionMockSocket!

  var gateway: QwenGatewayService!

  var session: QwenVoiceSession!

  var permissionResponder: MockPermissionResponder!

  var playbackPipeline: VoiceSessionMockPlaybackPipeline!

  override func setUp() {
    super.setUp()
    mockSocket = VoiceSessionMockSocket()
    gateway = QwenGatewayService(socketFactory: { _ in self.mockSocket })
    gateway.mode = .external
    permissionResponder = MockPermissionResponder()
    playbackPipeline = VoiceSessionMockPlaybackPipeline()
    session = QwenVoiceSession(
      gateway: gateway,
      permissionResponder: permissionResponder,
      audioPlaybackPipeline: playbackPipeline
    )
  }

  override func tearDown() {
    session.stop()
    gateway.disconnect()
    UserDefaults.standard.removeObject(forKey: AgentPermissionSettings.modeKey)
    session = nil
    playbackPipeline = nil
    permissionResponder = nil
    gateway = nil
    mockSocket = nil
    super.tearDown()
  }

  func playbackCancelledMessages() -> [[String: Any]] {
    mockSocket.sentMessages.compactMap { message in
      guard let data = message.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            json["type"] as? String == "playback.cancelled"
      else { return nil }
      return json
    }
  }

  func json(from message: String?) throws -> [String: Any] {
    let text = try XCTUnwrap(message)
    let data = try XCTUnwrap(text.data(using: .utf8))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}
