import Foundation
import XCTest

@testable import HyperMetaAI

private final class MockDashScopeSocket: QwenGatewaySocket {
  var sentMessages: [String] = []
  private var receiveCompletion: ((Result<String, Error>) -> Void)?
  private var queuedMessages: [String] = []
  private(set) var closeCount = 0

  func send(_ string: String, completion: @escaping (Error?) -> Void) {
    sentMessages.append(string)
    completion(nil)
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

    XCTAssertEqual(userTranscript?["type"] as? String, "transcript.final")
    XCTAssertEqual(userTranscript?["content"] as? String, "转发给大脑")
    XCTAssertFalse(provider.sentMessages.contains { message in
      (try? self.json(message)["type"] as? String) == "response.cancel"
    })
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
