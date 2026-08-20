import Foundation
import XCTest

@testable import HyperMetaAI

private final class MockDashScopeSocket: QwenGatewaySocket {
  var sentMessages: [String] = []
  var holdsSendCompletions = false
  private var receiveCompletion: ((Result<String, Error>) -> Void)?
  private var queuedMessages: [String] = []
  private var pendingSendCompletions: [(Error?) -> Void] = []
  private(set) var closeCount = 0

  func send(_ string: String, completion: @escaping (Error?) -> Void) {
    sentMessages.append(string)
    if holdsSendCompletions {
      pendingSendCompletions.append(completion)
    } else {
      completion(nil)
    }
  }

  func receive(completion: @escaping (Result<String, Error>) -> Void) {
    if queuedMessages.isEmpty {
      receiveCompletion = completion
    } else {
      completion(.success(queuedMessages.removeFirst()))
    }
  }

  func close() {
    closeCount += 1
  }

  func deliver(_ json: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: json)
    let text = String(data: data, encoding: .utf8)!
    if let receiveCompletion {
      self.receiveCompletion = nil
      receiveCompletion(.success(text))
    } else {
      queuedMessages.append(text)
    }
  }

  func completeNextSend(with error: Error? = nil) {
    precondition(!pendingSendCompletions.isEmpty)
    pendingSendCompletions.removeFirst()(error)
  }
}

final class QwenEmbeddedGatewaySocketTests: XCTestCase {
  private var provider: MockDashScopeSocket!
  private var socket: QwenEmbeddedGatewaySocket!

  override func setUp() {
    super.setUp()
    provider = MockDashScopeSocket()
    socket = QwenEmbeddedGatewaySocket(
      configuration: QwenEmbeddedGatewayConfiguration(
        apiKey: "secret",
        baseURL: "wss://dashscope.example/api-ws/v1/realtime",
        model: "qwen-audio-3.0-realtime-plus",
        voice: "longanqian"
      ),
      providerSocket: provider
    )
    socket.send(connectPayload(outputEnabled: true)) { XCTAssertNil($0) }
  }

  override func tearDown() {
    socket.close()
    socket = nil
    provider = nil
    super.tearDown()
  }

  func testSessionCreatedConfiguresDashScopeAndReadyReturnsAfterAcknowledgement() throws {
    provider.deliver(["type": "session.created"])

    let update = try json(provider.sentMessages.first)
    XCTAssertEqual(update["type"] as? String, "session.update")
    let session = try XCTUnwrap(update["session"] as? [String: Any])
    XCTAssertEqual(session["modalities"] as? [String], ["text", "audio"])
    XCTAssertEqual(session["voice"] as? String, "longanqian")
    XCTAssertEqual(session["input_audio_format"] as? String, "pcm")
    XCTAssertEqual((session["turn_detection"] as? [String: Any])?["type"] as? String, "smart_turn")

    var ready: [String: Any]?
    socket.receive { result in ready = try? self.json(try? result.get()) }
    provider.deliver(["type": "session.updated"])

    XCTAssertEqual(ready?["type"] as? String, "voice.ready")
    XCTAssertEqual((ready?["inputSampleRate"] as? NSNumber)?.doubleValue, 16_000)
  }

  func testAudioAppendMapsToProviderProtocolAfterReady() throws {
    makeReady()
    provider.sentMessages.removeAll()

    socket.send(jsonString(["type": "audio.append", "audio": "AQID"])) { XCTAssertNil($0) }

    let event = try json(provider.sentMessages.first)
    XCTAssertEqual(event["type"] as? String, "input_audio_buffer.append")
    XCTAssertEqual(event["audio"] as? String, "AQID")
  }

  func testSleepWakeMirrorsOfficialGatewayLifecycleAndBlocksSleepingAudio() throws {
    makeReady()
    drainGatewayMessages()
    provider.sentMessages.removeAll()

    socket.send(jsonString(["type": "sleep"])) { XCTAssertNil($0) }
    socket.send(jsonString(["type": "audio.append", "audio": "AQID"])) {
      XCTAssertNil($0)
    }

    let sleepEvents = try receiveGatewayMessages(count: 4)
    XCTAssertEqual(
      sleepEvents.compactMap { $0["type"] as? String },
      ["client.state", "voice.connection", "voice.sleep", "voice.state"]
    )
    XCTAssertEqual(
      sleepEvents.compactMap { $0["state"] as? String },
      ["sleeping", "sleeping", "sleeping", "idle"]
    )
    XCTAssertFalse(provider.sentMessages.contains { message in
      (try? self.json(message)["type"] as? String) == "input_audio_buffer.append"
    })

    socket.send(jsonString(["type": "wake"])) { XCTAssertNil($0) }

    let wakeEvents = try receiveGatewayMessages(count: 6)
    XCTAssertEqual(
      wakeEvents.compactMap { $0["type"] as? String },
      [
        "voice.sleep",
        "voice.connection",
        "voice.connection",
        "voice.ready",
        "voice.sleep",
        "voice.state"
      ]
    )
    XCTAssertEqual(wakeEvents[0]["state"] as? String, "detected")
    XCTAssertEqual(wakeEvents[1]["state"] as? String, "connecting")
    XCTAssertEqual(wakeEvents[2]["state"] as? String, "connected")
    XCTAssertEqual(wakeEvents[4]["state"] as? String, "awake")
    XCTAssertEqual(wakeEvents[5]["state"] as? String, "listening")
  }

  func testAudioAppendCompletionWaitsForProviderTransportHandoff() throws {
    makeReady()
    provider.sentMessages.removeAll()
    provider.holdsSendCompletions = true
    var completionError: Error?
    var didComplete = false

    socket.send(jsonString(["type": "audio.append", "audio": "AQID"])) { error in
      completionError = error
      didComplete = true
    }

    XCTAssertEqual(
      try json(provider.sentMessages.first)["type"] as? String,
      "input_audio_buffer.append"
    )
    XCTAssertFalse(didComplete)

    provider.completeNextSend()

    XCTAssertTrue(didComplete)
    XCTAssertNil(completionError)
  }

  func testDeferredAudioCompletionFailsWhenSocketClosesBeforeReady() {
    var completionError: Error?
    var didComplete = false
    socket.send(jsonString(["type": "audio.append", "audio": "AQID"])) { error in
      completionError = error
      didComplete = true
    }

    XCTAssertFalse(didComplete)
    socket.close()

    XCTAssertTrue(didComplete)
    XCTAssertNotNil(completionError)
  }

  func testDeferredAudioExpiresBeforeProviderTransportHandoff() throws {
    socket.close()
    provider = MockDashScopeSocket()
    var uptime = 10.0
    socket = QwenEmbeddedGatewaySocket(
      configuration: QwenEmbeddedGatewayConfiguration(
        apiKey: "secret",
        baseURL: "wss://dashscope.example/api-ws/v1/realtime",
        model: "qwen-audio-3.0-realtime-plus",
        voice: "longanqian"
      ),
      providerSocket: provider,
      now: { uptime }
    )
    socket.send(connectPayload(outputEnabled: true)) { XCTAssertNil($0) }
    var completionError: Error?
    var didComplete = false
    socket.send(jsonString(["type": "audio.append", "audio": "AQID"])) { error in
      completionError = error
      didComplete = true
    }
    XCTAssertFalse(didComplete)

    uptime += RealtimeProviderAudioProfiles.qwen.maximumQueuedInputAge + 0.001
    makeReady()

    XCTAssertTrue(didComplete)
    XCTAssertEqual((completionError as? URLError)?.code, .timedOut)
    XCTAssertFalse(provider.sentMessages.contains { message in
      (try? self.json(message)["type"] as? String) == "input_audio_buffer.append"
    })
  }

  func testTextWaitsForItemAcknowledgementBeforeCreatingResponse() throws {
    makeReady()
    provider.sentMessages.removeAll()

    socket.send(jsonString(["type": "text.message", "text": "hello"])) { XCTAssertNil($0) }

    let itemEvent = try json(provider.sentMessages.first)
    XCTAssertEqual(itemEvent["type"] as? String, "conversation.item.create")
    XCTAssertEqual(provider.sentMessages.count, 1)
    let item = try XCTUnwrap(itemEvent["item"] as? [String: Any])
    provider.deliver(["type": "conversation.item.created", "item": ["id": item["id"] as! String]])

    XCTAssertEqual(try json(provider.sentMessages.last)["type"] as? String, "response.create")
  }

  func testOmniUsesFamilyDefaultsAndAcceptsProviderReplacementItemID() throws {
    socket.close()
    provider = MockDashScopeSocket()
    socket = QwenEmbeddedGatewaySocket(
      configuration: QwenEmbeddedGatewayConfiguration(
        apiKey: "secret",
        baseURL: "wss://dashscope.example/realtime",
        model: "qwen3.5-omni-flash-realtime",
        voice: ""
      ),
      providerSocket: provider
    )
    socket.send(connectPayload(outputEnabled: true)) { XCTAssertNil($0) }

    provider.deliver(["type": "session.created"])
    let update = try json(provider.sentMessages.first)
    let session = try XCTUnwrap(update["session"] as? [String: Any])
    XCTAssertEqual(session["voice"] as? String, "Ethan")
    XCTAssertEqual(
      (session["turn_detection"] as? [String: Any])?["type"] as? String,
      "semantic_vad"
    )
    provider.deliver(["type": "session.updated"])
    provider.sentMessages.removeAll()

    socket.send(jsonString(["type": "image.append", "image": "AQID"])) { XCTAssertNil($0) }
    let imageEvent = try json(provider.sentMessages.first)
    XCTAssertEqual(imageEvent["type"] as? String, "input_image_buffer.append")
    XCTAssertEqual(imageEvent["image"] as? String, "AQID")
    provider.sentMessages.removeAll()

    socket.send(jsonString(["type": "text.message", "text": "hello omni"])) { XCTAssertNil($0) }
    XCTAssertEqual(
      try json(provider.sentMessages.first)["type"] as? String,
      "conversation.item.create"
    )
    provider.deliver([
      "type": "conversation.item.created",
      "item": ["id": "provider_replacement_id"]
    ])

    XCTAssertEqual(try json(provider.sentMessages.last)["type"] as? String, "response.create")
  }

  func testProviderAudioDecodedBridgeLatency() throws {
    makeReady()
    drainGatewayMessages()

    let expectedPCM = Data(repeating: 7, count: 15_360)
    let audioBase64 = expectedPCM.base64EncodedString()
    let iterations = 200
    var lastEvent: QwenGatewayEvent?
    let startedAt = ProcessInfo.processInfo.systemUptime

    for _ in 0..<iterations {
      socket.receiveEvent { result in
        lastEvent = try? result.get()
      }
      provider.deliver([
        "type": "response.audio.delta",
        "response_id": "response-1",
        "delta": audioBase64
      ])
    }

    let averageMicroseconds = (
      ProcessInfo.processInfo.systemUptime - startedAt
    ) * 1_000_000 / Double(iterations)
    print("[QwenEmbeddedIngressLatency] decodedAverageUs=\(averageMicroseconds)")
    let attachment = XCTAttachment(
      string: "decodedAverageUs=\(averageMicroseconds)\n"
        + "iterations=\(iterations)\n"
        + "pcmBytes=\(expectedPCM.count)"
    )
    attachment.name = "Qwen embedded decoded ingress latency"
    attachment.lifetime = .keepAlways
    add(attachment)

    guard case .audioChunk(let pcmData, let sampleRate, let responseID, let receivedAt) = lastEvent else {
      return XCTFail("Expected the final embedded event to decode as audio")
    }
    XCTAssertEqual(pcmData, expectedPCM)
    XCTAssertEqual(sampleRate, 24_000)
    XCTAssertEqual(responseID, "response-1")
    XCTAssertGreaterThan(receivedAt, 0)
    XCTAssertLessThan(averageMicroseconds, 100)
  }

  func testProviderAudioAndTranscriptMapToGatewayProtocol() throws {
    makeReady()
    drainGatewayMessages()

    var mapped: [[String: Any]] = []
    socket.receive { result in mapped.append((try? self.json(try? result.get())) ?? [:]) }
    provider.deliver([
      "type": "response.audio.delta",
      "response_id": "response-1",
      "delta": "AQID"
    ])
    socket.receive { result in mapped.append((try? self.json(try? result.get())) ?? [:]) }
    provider.deliver([
      "type": "conversation.item.input_audio_transcription.completed",
      "transcript": "你好"
    ])

    XCTAssertEqual(mapped.first?["type"] as? String, "audio.delta")
    XCTAssertEqual(mapped.first?["responseId"] as? String, "response-1")
    XCTAssertEqual(mapped.first?["audio"] as? String, "AQID")
    XCTAssertEqual(mapped.last?["type"] as? String, "transcript.final")
    XCTAssertEqual(mapped.last?["role"] as? String, "user")
    XCTAssertEqual(mapped.last?["content"] as? String, "你好")
  }

  func testProviderResponseIDIsRetainedForUncorrelatedAudioAndInterrupts() throws {
    makeReady()
    drainGatewayMessages()

    var started: [String: Any]?
    socket.receive { result in started = try? self.json(try? result.get()) }
    provider.deliver([
      "type": "response.created",
      "response": ["id": "response-1"]
    ])
    XCTAssertEqual(started?["type"] as? String, "response.started")
    XCTAssertEqual(started?["responseId"] as? String, "response-1")

    var mappedAudio: [String: Any]?
    socket.receive { result in mappedAudio = try? self.json(try? result.get()) }
    provider.deliver([
      "type": "response.audio.delta",
      "delta": "AQID"
    ])
    XCTAssertEqual(mappedAudio?["responseId"] as? String, "response-1")

    var completionEvents: [[String: Any]] = []
    socket.receive { result in completionEvents.append((try? self.json(try? result.get())) ?? [:]) }
    socket.receive { result in completionEvents.append((try? self.json(try? result.get())) ?? [:]) }
    provider.deliver([
      "type": "response.done",
      "response": ["id": "response-1", "status": "completed"]
    ])
    XCTAssertEqual(completionEvents[0]["type"] as? String, "audio.done")
    XCTAssertEqual(completionEvents[0]["responseId"] as? String, "response-1")

    var mappedInterrupt: [[String: Any]] = []
    socket.receive { result in mappedInterrupt.append((try? self.json(try? result.get())) ?? [:]) }
    socket.receive { result in mappedInterrupt.append((try? self.json(try? result.get())) ?? [:]) }
    socket.send(jsonString(["type": "interrupt"])) { XCTAssertNil($0) }

    XCTAssertEqual(mappedInterrupt[0]["type"] as? String, "playback.clear")
    XCTAssertEqual(mappedInterrupt[0]["reason"] as? String, "client_interrupt")
    XCTAssertEqual(mappedInterrupt[1]["type"] as? String, "response.interrupted")
    XCTAssertEqual(mappedInterrupt[1]["responseId"] as? String, "response-1")
    XCTAssertEqual(try json(provider.sentMessages.last)["type"] as? String, "response.cancel")

    var secondStarted: [String: Any]?
    socket.receive { result in secondStarted = try? self.json(try? result.get()) }
    provider.deliver([
      "type": "response.created",
      "response": ["id": "response-2"]
    ])
    XCTAssertEqual(secondStarted?["responseId"] as? String, "response-2")
    socket.send(jsonString(["type": "playback.ended", "responseId": "response-2"])) {
      XCTAssertNil($0)
    }

    var interruptAfterPlaybackEnd: [[String: Any]] = []
    socket.receive {
      interruptAfterPlaybackEnd.append((try? self.json(try? $0.get())) ?? [:])
    }
    socket.receive {
      interruptAfterPlaybackEnd.append((try? self.json(try? $0.get())) ?? [:])
    }
    socket.send(jsonString(["type": "interrupt"])) { XCTAssertNil($0) }
    XCTAssertNil(interruptAfterPlaybackEnd[1]["responseId"])
  }

  func testInterruptCompletionWaitsForProviderCancelWhileLocalClearIsImmediate() throws {
    makeReady()
    drainGatewayMessages()
    provider.deliver([
      "type": "response.created",
      "response": ["id": "response-1"]
    ])
    socket.receive { _ in }
    provider.sentMessages.removeAll()
    provider.holdsSendCompletions = true
    var localEvents: [[String: Any]] = []
    socket.receive { result in
      localEvents.append((try? self.json(try? result.get())) ?? [:])
    }
    socket.receive { result in
      localEvents.append((try? self.json(try? result.get())) ?? [:])
    }
    var completionError: Error?
    var didComplete = false

    socket.send(jsonString(["type": "interrupt"])) { error in
      completionError = error
      didComplete = true
    }

    XCTAssertEqual(localEvents.map { $0["type"] as? String }, [
      "playback.clear",
      "response.interrupted"
    ])
    XCTAssertEqual(localEvents.last?["responseId"] as? String, "response-1")
    XCTAssertEqual(
      try json(provider.sentMessages.last)["type"] as? String,
      "response.cancel"
    )
    XCTAssertFalse(didComplete)

    provider.completeNextSend()

    XCTAssertTrue(didComplete)
    XCTAssertNil(completionError)
  }

  func testDecodedEventFastPathPreservesImmediateInterruptOrder() throws {
    makeReady()
    drainGatewayMessages()
    provider.deliver([
      "type": "response.created",
      "response": ["id": "response-typed"]
    ])
    socket.receiveEvent { _ in }
    var events: [QwenGatewayEvent] = []
    socket.receiveEvent { result in
      if let event = try? result.get() { events.append(event) }
    }
    socket.receiveEvent { result in
      if let event = try? result.get() { events.append(event) }
    }

    socket.send(jsonString(["type": "interrupt"])) { XCTAssertNil($0) }

    XCTAssertEqual(events, [
      .playbackClear(reason: "client_interrupt"),
      .responseInterrupted(responseId: "response-typed")
    ])
    XCTAssertEqual(try json(provider.sentMessages.last)["type"] as? String, "response.cancel")
  }

  func testInterruptBeforeProviderReadyDoesNotCancelTheNextSession() throws {
    var didComplete = false
    socket.send(jsonString(["type": "interrupt"])) { error in
      XCTAssertNil(error)
      didComplete = true
    }

    XCTAssertTrue(didComplete)
    makeReady()

    XCTAssertFalse(provider.sentMessages.contains { message in
      (try? self.json(message)["type"] as? String) == "response.cancel"
    })
  }

  func testOutputDisabledKeepsUserTranscriptionAndSuppressesAssistantOutput() throws {
    socket.close()
    provider = MockDashScopeSocket()
    socket = QwenEmbeddedGatewaySocket(
      configuration: QwenEmbeddedGatewayConfiguration(
        apiKey: "secret",
        baseURL: "wss://dashscope.example/realtime",
        model: "qwen-audio-3.0-realtime-plus",
        voice: "longanqian"
      ),
      providerSocket: provider
    )
    socket.send(connectPayload(outputEnabled: false)) { XCTAssertNil($0) }
    makeReady()
    drainGatewayMessages()

    var userTranscript: [String: Any]?
    socket.receive { result in userTranscript = try? self.json(try? result.get()) }
    provider.deliver([
      "type": "conversation.item.input_audio_transcription.completed",
      "transcript": "转发给大脑"
    ])
    provider.deliver([
      "type": "response.audio.delta",
      "response_id": "response-1",
      "delta": "AQID"
    ])

    var turnEnd: [String: Any]?
    socket.receive { result in turnEnd = try? self.json(try? result.get()) }
    provider.deliver([
      "type": "response.done",
      "response": ["id": "response-1", "status": "completed"]
    ])

    XCTAssertEqual(userTranscript?["type"] as? String, "transcript.final")
    XCTAssertEqual(userTranscript?["content"] as? String, "转发给大脑")
    XCTAssertEqual(turnEnd?["type"] as? String, "voice.state")
    XCTAssertEqual(turnEnd?["state"] as? String, "idle")
    XCTAssertFalse(provider.sentMessages.contains { message in
      (try? self.json(message)["type"] as? String) == "response.cancel"
    })
  }

  func testSpeechTurnWithoutResponseRecoversInsteadOfListeningForever() throws {
    socket.close()
    provider = MockDashScopeSocket()
    socket = QwenEmbeddedGatewaySocket(
      configuration: QwenEmbeddedGatewayConfiguration(
        apiKey: "secret",
        baseURL: "wss://dashscope.example/realtime",
        model: "qwen-audio-3.0-realtime-plus",
        voice: "longanqian"
      ),
      providerSocket: provider,
      responseStartTimeout: 0.03
    )
    socket.send(connectPayload(outputEnabled: true)) { XCTAssertNil($0) }
    makeReady()
    drainGatewayMessages()

    provider.deliver(["type": "input_audio_buffer.speech_started", "item_id": "turn-1"])
    provider.deliver(["type": "input_audio_buffer.speech_stopped", "item_id": "turn-1"])
    _ = try receiveGatewayMessages(count: 3)

    let errorReceived = expectation(description: "response start timeout error")
    let idleReceived = expectation(description: "provider state returns to idle")
    var errorEvent: [String: Any]?
    var idleEvent: [String: Any]?
    socket.receive { result in
      errorEvent = try? self.json(try? result.get())
      errorReceived.fulfill()
    }
    socket.receive { result in
      idleEvent = try? self.json(try? result.get())
      idleReceived.fulfill()
    }

    wait(for: [errorReceived, idleReceived], timeout: 1)
    XCTAssertEqual(errorEvent?["type"] as? String, "error")
    XCTAssertEqual(idleEvent?["type"] as? String, "voice.state")
    XCTAssertEqual(idleEvent?["state"] as? String, "idle")
    XCTAssertEqual(provider.closeCount, 1)
  }

  func testResponseActivityCancelsResponseStartRecovery() throws {
    socket.close()
    provider = MockDashScopeSocket()
    socket = QwenEmbeddedGatewaySocket(
      configuration: QwenEmbeddedGatewayConfiguration(
        apiKey: "secret",
        baseURL: "wss://dashscope.example/realtime",
        model: "qwen-audio-3.0-realtime-plus",
        voice: "longanqian"
      ),
      providerSocket: provider,
      responseStartTimeout: 0.03
    )
    socket.send(connectPayload(outputEnabled: true)) { XCTAssertNil($0) }
    makeReady()
    drainGatewayMessages()

    provider.deliver(["type": "input_audio_buffer.speech_stopped", "item_id": "turn-1"])
    _ = try receiveGatewayMessages(count: 1)
    provider.deliver(["type": "response.created", "response": ["id": "response-1"]])
    _ = try receiveGatewayMessages(count: 1)

    let recoveryWindowElapsed = expectation(description: "recovery window elapsed")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) {
      recoveryWindowElapsed.fulfill()
    }
    wait(for: [recoveryWindowElapsed], timeout: 1)
    XCTAssertEqual(provider.closeCount, 0)
  }

  func testTranscriptionFailureCancelsResponseStartRecovery() throws {
    socket.close()
    provider = MockDashScopeSocket()
    socket = QwenEmbeddedGatewaySocket(
      configuration: QwenEmbeddedGatewayConfiguration(
        apiKey: "secret",
        baseURL: "wss://dashscope.example/realtime",
        model: "qwen-audio-3.0-realtime-plus",
        voice: "longanqian"
      ),
      providerSocket: provider,
      responseStartTimeout: 0.03
    )
    socket.send(connectPayload(outputEnabled: true)) { XCTAssertNil($0) }
    makeReady()
    drainGatewayMessages()

    provider.deliver(["type": "input_audio_buffer.speech_stopped", "item_id": "turn-1"])
    _ = try receiveGatewayMessages(count: 1)
    provider.deliver(["type": "conversation.item.input_audio_transcription.failed"])
    let failureEvents = try receiveGatewayMessages(count: 2)

    let recoveryWindowElapsed = expectation(description: "recovery window elapsed")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) {
      recoveryWindowElapsed.fulfill()
    }
    wait(for: [recoveryWindowElapsed], timeout: 1)
    XCTAssertEqual(failureEvents.map { $0["type"] as? String }, ["transcript.discard", "voice.state"])
    XCTAssertEqual(failureEvents.last?["state"] as? String, "idle")
    XCTAssertEqual(provider.closeCount, 0)
  }

  func testInterruptTruncatesAssistantAudioBeforeCancellingSoServerContextMatchesWhatWasHeard()
    throws
  {
    makeReady()
    drainGatewayMessages()
    provider.deliver([
      "type": "response.created",
      "response": ["id": "response-1"]
    ])
    socket.receive { _ in }
    provider.deliver([
      "type": "response.audio.delta",
      "response_id": "response-1",
      "item_id": "item-7",
      "content_index": 2,
      "delta": "AQID"
    ])
    socket.receive { _ in }
    provider.sentMessages.removeAll()

    socket.receive { _ in }
    socket.receive { _ in }
    socket.send(jsonString(["type": "interrupt", "playedMs": 640])) { XCTAssertNil($0) }

    let events = try provider.sentMessages.map { try json($0) }
    XCTAssertEqual(
      events.compactMap { $0["type"] as? String },
      ["conversation.item.truncate", "response.cancel"],
      "truncate 必须在 cancel 之前发出，否则该 item 已不接受截断"
    )
    XCTAssertEqual(events[0]["item_id"] as? String, "item-7")
    XCTAssertEqual(events[0]["content_index"] as? Int, 2)
    XCTAssertEqual(events[0]["audio_end_ms"] as? Int, 640)
  }

  func testInterruptWithoutPlayedMillisecondsOnlyCancels() throws {
    makeReady()
    drainGatewayMessages()
    provider.deliver([
      "type": "response.audio.delta",
      "response_id": "response-1",
      "item_id": "item-7",
      "delta": "AQID"
    ])
    socket.receive { _ in }
    provider.sentMessages.removeAll()

    socket.receive { _ in }
    socket.receive { _ in }
    socket.send(jsonString(["type": "interrupt"])) { XCTAssertNil($0) }

    XCTAssertEqual(
      try provider.sentMessages.map { try json($0)["type"] as? String },
      ["response.cancel"],
      "播放进度未知时只取消，不截断"
    )
  }

  func testInterruptAfterResponseDoneDoesNotTruncateAStaleItem() throws {
    makeReady()
    drainGatewayMessages()
    provider.deliver([
      "type": "response.audio.delta",
      "response_id": "response-1",
      "item_id": "item-7",
      "delta": "AQID"
    ])
    socket.receive { _ in }
    provider.deliver([
      "type": "response.done",
      "response": ["id": "response-1", "status": "completed"]
    ])
    socket.receive { _ in }
    provider.sentMessages.removeAll()

    socket.receive { _ in }
    socket.receive { _ in }
    socket.send(jsonString(["type": "interrupt", "playedMs": 400])) { XCTAssertNil($0) }

    XCTAssertFalse(
      try provider.sentMessages.contains { try json($0)["type"] as? String == "conversation.item.truncate" },
      "response.done 之后 item 已定稿，不应再截断"
    )
  }

  func testRealtimeURLIncludesSelectedModel() {
    let url = QwenEmbeddedGatewaySocket.realtimeURL(
      baseURL: "wss://dashscope.example/realtime",
      model: "qwen audio"
    )

    XCTAssertEqual(url.scheme, "wss")
    XCTAssertEqual(url.query, "model=qwen%20audio")
  }

  private func makeReady() {
    provider.deliver(["type": "session.created"])
    provider.deliver(["type": "session.updated"])
  }

  private func drainGatewayMessages() {
    for _ in 0..<2 {
      socket.receive { _ in }
    }
  }

  private func receiveGatewayMessages(count: Int) throws -> [[String: Any]] {
    try (0..<count).map { _ in
      var message: String?
      socket.receive { result in message = try? result.get() }
      return try json(message)
    }
  }

  private func connectPayload(outputEnabled: Bool) -> String {
    jsonString([
      "type": "connect",
      "inputEnabled": true,
      "outputEnabled": outputEnabled,
      "voiceEnabled": outputEnabled
    ])
  }

  private func jsonString(_ value: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: value)
    return String(data: data, encoding: .utf8)!
  }

  private func json(_ value: String?) throws -> [String: Any] {
    let text = try XCTUnwrap(value)
    let data = try XCTUnwrap(text.data(using: .utf8))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}
